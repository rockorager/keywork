//! Scanner-backed input-method-v2 frontend and canonical keyboard grab bridge.

const WayringInputMethod = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayland = @import("wayland");
const wayring = @import("wayring");
const TextInput = @import("../TextInput.zig");
const Seat = @import("seat.zig");
const WayringClients = @import("WayringClients.zig");
const WayringSeatAdapter = @import("WayringSeatAdapter.zig");
const WayringCompositor = @import("WayringCompositor.zig");

const wl = wayland.server.wl;

pub const Authorization = union(enum) {
    expected_uid: std.os.linux.uid_t,
    callback: Callback,

    pub const Callback = struct {
        context: *anyopaque,
        authorize: *const fn (*anyopaque, wayring.server.Client.Credentials) bool,
    };
};

pub const Layout = struct {
    context: *anyopaque,
    popup_created: *const fn (*anyopaque, TextInput.PopupId, TextInput.MethodId, WayringCompositor.SurfaceId) error{OutOfMemory}!void,
    popup_changed: *const fn (*anyopaque, TextInput.PopupId) void,
    popup_destroyed: *const fn (*anyopaque, TextInput.PopupId) void,
};

pub const Position = struct { x: i32 = 0, y: i32 = 0 };

const Manager = struct { owner: *WayringInputMethod, client: *wayring.server.Client, resource: protocol.zwp_input_method_manager_v2.Resource };
const Method = struct {
    owner: *WayringInputMethod,
    client: *wayring.server.Client,
    resource: protocol.zwp_input_method_v2.Resource,
    neutral_id: TextInput.MethodId,
    available: bool,
    grabs: std.ArrayList(*Grab) = .empty,
    active_grab: ?*Grab = null,
    popups: std.ArrayList(*Popup) = .empty,
};
const Grab = struct {
    method: *Method,
    resource: protocol.zwp_input_method_keyboard_grab_v2.Resource,
    neutral_id: ?TextInput.KeyboardGrabId,
    token: u64,
    active: bool,
};
const Popup = struct {
    method: *Method,
    resource: protocol.zwp_input_popup_surface_v2.Resource,
    neutral_id: ?TextInput.PopupId,
    reservation: ?WayringCompositor.InputPopupReservation,
    surface_id: ?WayringCompositor.SurfaceId,
};

allocator: std.mem.Allocator,
protocol_server: *wayring.server.Server,
clients: *WayringClients,
seat_adapter: *WayringSeatAdapter,
seat: *Seat,
owner: *TextInput,
authorization: Authorization,
compositor: *WayringCompositor,
layout: Layout,
global: ?*const wayring.server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
methods: std.ArrayList(*Method) = .empty,
active_method: ?*Method = null,
next_grab_token: ?u64 = 1,
inhibited: bool = false,

pub fn init(self: *WayringInputMethod, allocator: std.mem.Allocator, protocol_server: *wayring.server.Server, clients: *WayringClients, seat_adapter: *WayringSeatAdapter, seat: *Seat, owner: *TextInput, compositor: *WayringCompositor, authorization: Authorization, layout: Layout) void {
    self.* = .{ .allocator = allocator, .protocol_server = protocol_server, .clients = clients, .seat_adapter = seat_adapter, .seat = seat, .owner = owner, .compositor = compositor, .authorization = authorization, .layout = layout };
    compositor.setInputPopupListener(.{ .context = self, .committed = popupCommitted, .removed = popupRemoved });
}

pub fn deinit(self: *WayringInputMethod) void {
    std.debug.assert(self.global == null and self.managers.items.len == 0 and self.methods.items.len == 0);
    self.compositor.setInputPopupListener(null);
    self.managers.deinit(self.allocator);
    self.methods.deinit(self.allocator);
    self.* = undefined;
}

pub fn publish(self: *WayringInputMethod) !void {
    self.global = try self.protocol_server.addGlobalWithOptions(protocol.zwp_input_method_manager_v2, 1, WayringInputMethod, self, bind, .{
        .visibility = .restricted,
    });
}

pub fn unpublish(self: *WayringInputMethod) void {
    self.protocol_server.removeGlobal(self.global.?) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}

fn authorized(policy: Authorization, credentials: ?wayring.server.Client.Credentials) bool {
    const value = credentials orelse return false;
    return switch (policy) {
        .expected_uid => |uid| value.uid == uid,
        .callback => |callback| callback.authorize(callback.context, value),
    };
}

fn bind(client: *wayring.server.Client, id: u32, version: u32, self: *WayringInputMethod) !void {
    if (version != 1) return error.InvalidVersion;
    if (!authorized(self.authorization, client.credentials())) {
        // No manager resource exists yet. Returning from the global bind lets
        // the server terminalize this client without attributing the failure
        // to another object.
        return error.Unauthorized;
    }
    try self.managers.ensureUnusedCapacity(self.allocator, 1);
    const manager = try self.allocator.create(Manager);
    errdefer self.allocator.destroy(manager);
    manager.* = .{ .owner = self, .client = client, .resource = .init(self.allocator, id, 1, .client, client.ownerHooks()) };
    errdefer {
        manager.resource.destroy();
        manager.resource.deinit();
    }
    try manager.resource.setHandler(Manager, manager, managerRequest, null);
    try client.materialize(&manager.resource.runtime);
    self.managers.appendAssumeCapacity(manager);
}

fn managerRequest(_: *protocol.zwp_input_method_manager_v2.Resource, request: protocol.zwp_input_method_manager_v2.Request, manager: *Manager) !void {
    switch (request) {
        .destroy => manager.owner.destroyManager(manager),
        .get_input_method => |args| try manager.owner.createMethod(manager, args.input_method, manager.owner.seat_adapter.seatClientIdentity(manager.client, args.seat) == null),
    }
}

fn createMethod(self: *WayringInputMethod, manager: *Manager, id: u32, force_inert: bool) !void {
    try self.methods.ensureUnusedCapacity(self.allocator, 1);
    const method = try self.allocator.create(Method);
    errdefer self.allocator.destroy(method);
    method.* = .{ .owner = self, .client = manager.client, .resource = .init(self.allocator, id, 1, .client, manager.client.ownerHooks()), .neutral_id = undefined, .available = !force_inert and self.active_method == null };
    errdefer {
        method.resource.destroy();
        method.resource.deinit();
        method.grabs.deinit(self.allocator);
        method.popups.deinit(self.allocator);
    }
    try method.resource.setHandler(Method, method, methodRequest, null);
    try manager.client.materialize(&method.resource.runtime);
    method.neutral_id = try self.owner.createMethodWithAvailability(self.clients.id(manager.client) orelse return error.InvalidClient, .{ .context = method, .activate = endpointActivate, .deactivate = endpointDeactivate, .state = endpointState, .done = endpointDone, .unavailable = endpointUnavailable }, !force_inert);
    errdefer self.owner.destroyMethod(method.neutral_id);
    self.methods.appendAssumeCapacity(method);
    if (method.available) self.active_method = method;
}

fn methodRequest(_: *protocol.zwp_input_method_v2.Resource, request: protocol.zwp_input_method_v2.Request, method: *Method) !void {
    if (!method.available) return switch (request) {
        .destroy => method.owner.destroyMethod(method),
        .grab_keyboard => |args| method.owner.createGrab(method, args.keyboard, false),
        .get_input_popup_surface => |args| method.owner.createPopup(method, args.id, args.surface, false),
        else => {},
    };
    switch (request) {
        .destroy => method.owner.destroyMethod(method),
        .commit_string => |args| if (validText(args.text)) method.owner.owner.setCommitString(method.neutral_id, args.text) catch |err| if (err == error.OutOfMemory) method.client.postOutOfMemory(&method.resource.runtime, "staging input-method commit string"),
        .set_preedit_string => |args| if (validText(args.text) and validPreeditCursor(args.text, args.cursor_begin, args.cursor_end)) method.owner.owner.setPreedit(method.neutral_id, args.text, args.cursor_begin, args.cursor_end) catch |err| if (err == error.OutOfMemory) method.client.postOutOfMemory(&method.resource.runtime, "staging input-method preedit"),
        .delete_surrounding_text => |args| method.owner.owner.deleteSurrounding(method.neutral_id, .{ .before_length = args.before_length, .after_length = args.after_length }) catch {},
        .commit => |args| method.owner.owner.commitEdit(method.neutral_id, args.serial) catch {},
        .grab_keyboard => |args| try method.owner.createGrab(method, args.keyboard, true),
        .get_input_popup_surface => |args| try method.owner.createPopup(method, args.id, args.surface, true),
    }
}

fn createGrab(self: *WayringInputMethod, method: *Method, id: u32, usable: bool) !void {
    try method.grabs.ensureUnusedCapacity(self.allocator, 1);
    const grab = try self.allocator.create(Grab);
    errdefer self.allocator.destroy(grab);
    const token = self.next_grab_token orelse return error.GenerationExhausted;
    self.next_grab_token = if (token == std.math.maxInt(u64)) null else token + 1;
    const neutral_id = if (usable) try self.owner.createKeyboardGrab(method.neutral_id) else null;
    errdefer if (neutral_id) |value| self.owner.destroyKeyboardGrab(value);
    grab.* = .{ .method = method, .resource = .init(self.allocator, id, 1, .client, method.client.ownerHooks()), .neutral_id = neutral_id, .token = token, .active = usable and !self.inhibited and method.active_grab == null };
    errdefer {
        grab.resource.destroy();
        grab.resource.deinit();
    }
    try grab.resource.setHandler(Grab, grab, grabRequest, null);
    try method.client.materialize(&grab.resource.runtime);
    method.grabs.appendAssumeCapacity(grab);
    if (grab.active) activateGrab(grab);
}

fn grabRequest(_: *protocol.zwp_input_method_keyboard_grab_v2.Resource, request: protocol.zwp_input_method_keyboard_grab_v2.Request, grab: *Grab) !void {
    switch (request) {
        .release => grab.method.owner.destroyGrab(grab),
    }
}

fn activateGrab(grab: *Grab) void {
    grab.method.active_grab = grab;
    if (!grab.method.owner.seat.setKeyboardGrab(.{
        .context = grab,
        .token = grab.token,
        .generated_client = grab.method.owner.clients.id(grab.method.client) orelse unreachable,
        .cancel = cancelGrab,
        .keymap = sendKeymap,
        .key = sendKey,
        .modifiers = sendModifiers,
        .repeat_info = sendRepeatInfo,
    })) {
        grab.active = false;
        grab.method.active_grab = null;
        grab.method.client.postImplementationError(&grab.resource.runtime, "installing input-method keyboard grab");
    }
}

fn cancelGrab(context: *anyopaque) void {
    const grab: *Grab = @ptrCast(@alignCast(context));
    grab.active = false;
    grab.method.active_grab = null;
    grab.method.owner.seat.clearKeyboardGrab(grab, false);
}
fn sendKeymap(context: *anyopaque, format: wl.Keyboard.KeymapFormat, fd: std.posix.fd_t, size: u32) void {
    const grab: *Grab = @ptrCast(@alignCast(context));
    protocol.zwp_input_method_keyboard_grab_v2.@"send:keymap"(&grab.resource, @intCast(@intFromEnum(format)), fd, size) catch clientFailure(grab, "sending input-method keymap");
}
fn sendKey(context: *anyopaque, serial: u32, time: u32, key: u32, state: wl.Keyboard.KeyState) void {
    const grab: *Grab = @ptrCast(@alignCast(context));
    protocol.zwp_input_method_keyboard_grab_v2.@"send:key"(&grab.resource, serial, time, key, @intCast(@intFromEnum(state))) catch clientFailure(grab, "sending input-method key");
}
fn sendModifiers(context: *anyopaque, serial: u32, depressed: u32, latched: u32, locked: u32, group: u32) void {
    const grab: *Grab = @ptrCast(@alignCast(context));
    protocol.zwp_input_method_keyboard_grab_v2.@"send:modifiers"(&grab.resource, serial, depressed, latched, locked, group) catch clientFailure(grab, "sending input-method modifiers");
}
fn sendRepeatInfo(context: *anyopaque, rate: i32, delay: i32) void {
    const grab: *Grab = @ptrCast(@alignCast(context));
    protocol.zwp_input_method_keyboard_grab_v2.@"send:repeat_info"(&grab.resource, rate, delay) catch clientFailure(grab, "sending input-method repeat info");
}
fn clientFailure(grab: *Grab, message: []const u8) void {
    grab.method.client.postOutOfMemory(&grab.resource.runtime, message);
}

fn createPopup(self: *WayringInputMethod, method: *Method, id: u32, surface: u32, usable: bool) !void {
    try method.popups.ensureUnusedCapacity(self.allocator, 1);
    const popup = try self.allocator.create(Popup);
    popup.* = .{ .method = method, .resource = .init(self.allocator, id, 1, .client, method.client.ownerHooks()), .neutral_id = null, .reservation = null, .surface_id = null };
    var published = false;
    defer if (!published) {
        if (popup.neutral_id) |neutral_id| {
            self.layout.popup_destroyed(self.layout.context, neutral_id);
            self.owner.destroyPopup(neutral_id);
        }
        if (popup.reservation) |reservation| self.compositor.abortInputPopup(reservation) catch {};
        popup.resource.destroy();
        popup.resource.deinit();
        self.allocator.destroy(popup);
    };
    if (usable) {
        const surface_id = self.compositor.surfaceId(method.client, surface) orelse {
            method.client.postProtocolError(&method.resource.runtime, @intCast(protocol.zwp_input_method_v2.@"error".role), "wl_surface is not a live same-client generated surface");
            return;
        };
        popup.reservation = self.compositor.reserveInputPopup(method.client, surface_id) catch |err| switch (err) {
            error.NotLive, error.WrongClient, error.RoleConflict => {
                method.client.postProtocolError(&method.resource.runtime, @intCast(protocol.zwp_input_method_v2.@"error".role), "wl_surface already has a role");
                return;
            },
            error.GenerationExhausted => {
                method.client.postImplementationError(&method.resource.runtime, "reserving input popup role generation");
                return;
            },
            error.StaleReservation => unreachable,
        };
        popup.surface_id = surface_id;
        popup.neutral_id = try self.owner.createPopup(method.neutral_id, surface_id);
        try self.layout.popup_created(self.layout.context, popup.neutral_id.?, method.neutral_id, surface_id);
    }
    try popup.resource.setHandler(Popup, popup, popupRequest, null);
    try method.client.materialize(&popup.resource.runtime);
    method.popups.appendAssumeCapacity(popup);
    published = true;
    if (popup.neutral_id) |neutral_id| self.layout.popup_changed(self.layout.context, neutral_id);
}
fn popupRequest(_: *protocol.zwp_input_popup_surface_v2.Resource, request: protocol.zwp_input_popup_surface_v2.Request, popup: *Popup) !void {
    switch (request) {
        .destroy => popup.method.owner.destroyPopup(popup),
    }
}

pub fn sendPopupRectangle(_: *WayringInputMethod, popup: *Popup, rectangle: TextInput.Rectangle) void {
    protocol.zwp_input_popup_surface_v2.@"send:text_input_rectangle"(&popup.resource, rectangle.x, rectangle.y, rectangle.width, rectangle.height) catch popup.method.client.postOutOfMemory(&popup.resource.runtime, "sending input popup rectangle");
}

pub fn observerSendPopupRectangle(context: *anyopaque, id: TextInput.PopupId, rectangle: TextInput.Rectangle) void {
    const self: *WayringInputMethod = @ptrCast(@alignCast(context));
    for (self.methods.items) |method| for (method.popups.items) |popup|
        if (popup.neutral_id != null and std.meta.eql(popup.neutral_id.?, id)) return self.sendPopupRectangle(popup, rectangle);
}

pub fn refreshPopups(self: *WayringInputMethod) void {
    for (self.methods.items) |method| for (method.popups.items) |popup|
        if (popup.neutral_id) |neutral_id| self.layout.popup_changed(self.layout.context, neutral_id);
}

fn popupCommitted(context: *anyopaque, surface: WayringCompositor.SurfaceId) void {
    const self: *WayringInputMethod = @ptrCast(@alignCast(context));
    for (self.methods.items) |method| for (method.popups.items) |popup|
        if (popup.surface_id != null and std.meta.eql(popup.surface_id.?, surface))
            if (popup.neutral_id) |neutral_id| self.layout.popup_changed(self.layout.context, neutral_id);
}

fn popupRemoved(context: *anyopaque, surface: WayringCompositor.SurfaceId) void {
    const self: *WayringInputMethod = @ptrCast(@alignCast(context));
    for (self.methods.items) |method| {
        var i = method.popups.items.len;
        while (i > 0) : (i -= 1) {
            const popup = method.popups.items[i - 1];
            if (popup.surface_id != null and std.meta.eql(popup.surface_id.?, surface)) {
                popup.reservation = null;
                self.destroyPopup(popup);
            }
        }
    }
}

pub fn setInhibited(self: *WayringInputMethod, inhibited: bool) void {
    if (self.inhibited == inhibited) return;
    self.inhibited = inhibited;
    refreshPopups(self);
    const method = self.active_method orelse return;
    if (inhibited) {
        if (method.active_grab) |grab| {
            grab.active = false;
            method.active_grab = null;
            self.seat.clearKeyboardGrab(grab, false);
        }
    } else if (method.available and method.active_grab == null and method.grabs.items.len > 0) {
        const grab = method.grabs.items[method.grabs.items.len - 1];
        grab.active = true;
        activateGrab(grab);
    }
}

pub fn destroyClientResources(self: *WayringInputMethod, client: *wayring.server.Client) void {
    var i = self.methods.items.len;
    while (i > 0) : (i -= 1) if (self.methods.items[i - 1].client == client) self.destroyMethod(self.methods.items[i - 1]);
    i = self.managers.items.len;
    while (i > 0) : (i -= 1) if (self.managers.items[i - 1].client == client) self.destroyManager(self.managers.items[i - 1]);
}
fn destroyManager(self: *WayringInputMethod, manager: *Manager) void {
    remove(Manager, &self.managers, manager);
    manager.resource.destroy();
    manager.resource.deinit();
    self.allocator.destroy(manager);
}
fn destroyMethod(self: *WayringInputMethod, method: *Method) void {
    method.available = false;
    if (self.active_method == method) self.active_method = null;
    while (method.grabs.items.len > 0) self.destroyGrab(method.grabs.items[method.grabs.items.len - 1]);
    while (method.popups.items.len > 0) self.destroyPopup(method.popups.items[method.popups.items.len - 1]);
    remove(Method, &self.methods, method);
    self.owner.destroyMethod(method.neutral_id);
    method.resource.destroy();
    method.resource.deinit();
    method.grabs.deinit(self.allocator);
    method.popups.deinit(self.allocator);
    self.allocator.destroy(method);
}
fn destroyGrab(self: *WayringInputMethod, grab: *Grab) void {
    const method = grab.method;
    const was_active = grab.active;
    if (was_active) method.active_grab = null;
    remove(Grab, &method.grabs, grab);
    const replacement = if (was_active and !self.inhibited and method.available and method.grabs.items.len > 0) method.grabs.items[method.grabs.items.len - 1] else null;
    if (was_active) self.seat.clearKeyboardGrab(grab, replacement == null);
    if (grab.neutral_id) |neutral_id| self.owner.destroyKeyboardGrab(neutral_id);
    grab.resource.destroy();
    grab.resource.deinit();
    self.allocator.destroy(grab);
    if (replacement) |value| {
        value.active = true;
        activateGrab(value);
    }
}
fn destroyPopup(self: *WayringInputMethod, popup: *Popup) void {
    remove(Popup, &popup.method.popups, popup);
    if (popup.reservation) |reservation| self.compositor.releaseInputPopup(reservation) catch {};
    if (popup.neutral_id) |neutral_id| {
        self.layout.popup_destroyed(self.layout.context, neutral_id);
        self.owner.destroyPopup(neutral_id);
    }
    popup.resource.destroy();
    popup.resource.deinit();
    self.allocator.destroy(popup);
}
fn remove(comptime T: type, list: *std.ArrayList(*T), value: *T) void {
    for (list.items, 0..) |item, index| if (item == value) {
        _ = list.orderedRemove(index);
        return;
    };
}

fn endpointActivate(context: *anyopaque) void {
    const method: *Method = @ptrCast(@alignCast(context));
    protocol.zwp_input_method_v2.@"send:activate"(&method.resource) catch method.client.postOutOfMemory(&method.resource.runtime, "sending input-method activate");
}
fn endpointDeactivate(context: *anyopaque) void {
    const method: *Method = @ptrCast(@alignCast(context));
    protocol.zwp_input_method_v2.@"send:deactivate"(&method.resource) catch method.client.postOutOfMemory(&method.resource.runtime, "sending input-method deactivate");
}
fn endpointState(context: *anyopaque, snapshot: TextInput.Snapshot) void {
    const method: *Method = @ptrCast(@alignCast(context));
    if (snapshot.surrounding_text) |text| protocol.zwp_input_method_v2.@"send:surrounding_text"(&method.resource, text, snapshot.cursor, snapshot.anchor) catch return method.client.postOutOfMemory(&method.resource.runtime, "sending input-method state");
    protocol.zwp_input_method_v2.@"send:text_change_cause"(&method.resource, @intFromEnum(snapshot.change_cause)) catch return method.client.postOutOfMemory(&method.resource.runtime, "sending input-method state");
    protocol.zwp_input_method_v2.@"send:content_type"(&method.resource, @bitCast(snapshot.content_hint), @intFromEnum(snapshot.content_purpose)) catch method.client.postOutOfMemory(&method.resource.runtime, "sending input-method state");
}
fn endpointDone(context: *anyopaque, _: u32) void {
    const method: *Method = @ptrCast(@alignCast(context));
    protocol.zwp_input_method_v2.@"send:done"(&method.resource) catch method.client.postOutOfMemory(&method.resource.runtime, "sending input-method done");
    refreshPopups(method.owner);
}
fn endpointUnavailable(context: *anyopaque) void {
    const method: *Method = @ptrCast(@alignCast(context));
    method.available = false;
    protocol.zwp_input_method_v2.@"send:unavailable"(&method.resource) catch method.client.postOutOfMemory(&method.resource.runtime, "sending input-method unavailable");
}

fn validText(text: []const u8) bool {
    return text.len <= TextInput.max_text_bytes and std.unicode.utf8ValidateSlice(text);
}
fn validPreeditCursor(text: []const u8, begin: i32, end: i32) bool {
    if ((begin == -1) != (end == -1)) return false;
    return validCursor(text, begin) and validCursor(text, end);
}

pub fn observerSetInhibited(context: *anyopaque, inhibited: bool) void {
    const self: *WayringInputMethod = @ptrCast(@alignCast(context));
    self.setInhibited(inhibited);
}

pub fn observerRefreshPopups(context: *anyopaque) void {
    const self: *WayringInputMethod = @ptrCast(@alignCast(context));
    self.refreshPopups();
}
fn validCursor(text: []const u8, cursor: i32) bool {
    if (cursor < 0) return cursor == -1;
    const index: usize = @intCast(cursor);
    return index <= text.len and (index == text.len or text[index] & 0xc0 != 0x80);
}

test "input method descriptors remain v1" {
    try std.testing.expectEqual(@as(u32, 1), protocol.zwp_input_method_manager_v2.interface.version);
    try std.testing.expectEqual(@as(usize, 2), protocol.zwp_input_method_manager_v2.request_messages.len);
}
test "authorization requires credentials and exact uid" {
    const credentials: wayring.server.Client.Credentials = .{ .pid = 1, .uid = 42, .gid = 2 };
    try std.testing.expect(!authorized(.{ .expected_uid = 42 }, null));
    try std.testing.expect(authorized(.{ .expected_uid = 42 }, credentials));
    try std.testing.expect(!authorized(.{ .expected_uid = 41 }, credentials));
}

pub const TestPublicGlobal = struct {
    pub const interface: wayring.wire.Interface = .{ .name = "kw_test_public", .version = 1 };
};

const test_display_get_registry: wayring.wire.MessageDescriptor = .{
    .name = "get_registry",
    .arguments = &.{.{ .name = "registry", .kind = .{ .new_id = &.{ .name = "wl_registry", .version = 1 } } }},
};
const test_registry_bind: wayring.wire.MessageDescriptor = .{ .name = "bind", .arguments = &.{
    .{ .name = "name", .kind = .uint },
    .{ .name = "id", .kind = .{ .new_id = null } },
} };

fn testSend(client: *wayring.server.Client, object_id: u32, opcode: u16, descriptor: *const wayring.wire.MessageDescriptor, values: []const wayring.wire.Value) !void {
    var output: wayring.wire.Output = .init(std.testing.allocator);
    defer output.deinit();
    try output.enqueue(object_id, opcode, descriptor, values);
    const batch = (try output.beginSend()).?;
    try client.receive(batch.bytes, &.{});
    try output.completeSend(batch.token, batch.bytes.len);
    try client.dispatch();
}

fn expectRegistryGlobals(managed: *wayring.server.CoreClient, expected: []const *const wayring.server.Server.Global) !void {
    var index: usize = 0;
    while (try managed.client().beginSend()) |batch| {
        var offset: usize = 0;
        while (offset < batch.bytes.len) {
            const header = std.mem.readInt(u32, batch.bytes[offset + 4 ..][0..4], .little);
            const size: usize = @intCast(header >> 16);
            try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, batch.bytes[offset..][0..4], .little));
            try std.testing.expectEqual(@as(u16, 0), @as(u16, @truncate(header)));
            const string_length: usize = @intCast(std.mem.readInt(u32, batch.bytes[offset + 12 ..][0..4], .little));
            try std.testing.expect(index < expected.len);
            try std.testing.expectEqual(expected[index].name(), std.mem.readInt(u32, batch.bytes[offset + 8 ..][0..4], .little));
            try std.testing.expectEqualStrings(expected[index].interface().name, batch.bytes[offset + 16 ..][0 .. string_length - 1]);
            index += 1;
            offset += size;
        }
        try managed.client().completeSend(batch.token, batch.bytes.len);
    }
    try std.testing.expectEqual(expected.len, index);
}

test "generated input method registry authorization and forged bind isolate offender" {
    const Fixture = struct {
        expected_uid: std.os.linux.uid_t = 42,
        public_bind_count: usize = 0,

        fn visible(self: *@This(), client: *const wayring.server.Client, global: *const wayring.server.Server.Global) bool {
            if (!std.mem.eql(u8, global.interface().name, protocol.zwp_input_method_manager_v2.interface.name)) return true;
            const credentials = client.credentials() orelse return false;
            return credentials.uid == self.expected_uid;
        }

        fn bindPublic(_: *wayring.server.Client, _: u32, _: u32, self: *@This()) !void {
            self.public_bind_count += 1;
        }
    };

    var host: wayring.server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var fixture: Fixture = .{};
    const public_global = try host.addGlobal(TestPublicGlobal, 1, Fixture, &fixture, Fixture.bindPublic);
    var adapter: WayringInputMethod = undefined;
    adapter.allocator = std.testing.allocator;
    adapter.protocol_server = &host;
    adapter.authorization = .{ .expected_uid = fixture.expected_uid };
    adapter.managers = .empty;
    adapter.methods = .empty;
    const input_method_global = try host.addGlobal(protocol.zwp_input_method_manager_v2, 1, WayringInputMethod, &adapter, bind);
    host.setGlobalFilter(Fixture, &fixture, Fixture.visible);

    const expected = try wayring.server.CoreClient.create(std.testing.allocator, &host, .{ .credentials = .{ .pid = 1, .uid = 42, .gid = 1 } });
    defer expected.destroy();
    const wrong = try wayring.server.CoreClient.create(std.testing.allocator, &host, .{ .credentials = .{ .pid = 2, .uid = 41, .gid = 1 } });
    defer wrong.destroy();
    const missing = try wayring.server.CoreClient.create(std.testing.allocator, &host, .{});
    defer missing.destroy();

    for ([_]*wayring.server.CoreClient{ expected, wrong, missing }) |managed|
        try testSend(managed.client(), 1, 1, &test_display_get_registry, &.{.{ .new_id = .{ .typed = 2 } }});
    try expectRegistryGlobals(expected, &.{ public_global, input_method_global });
    try expectRegistryGlobals(wrong, &.{public_global});
    try expectRegistryGlobals(missing, &.{public_global});

    try testSend(wrong.client(), 2, 0, &test_registry_bind, &.{
        .{ .uint = input_method_global.name() },
        .{ .new_id = .{ .generic = .{ .interface = protocol.zwp_input_method_manager_v2.interface.name, .version = 1, .id = 3 } } },
    });
    try std.testing.expectEqual(wayring.server.Fatal.Kind.protocol, wrong.client().fatal().?.kind);
    try std.testing.expectEqualStrings("invalid wl_registry.bind", wrong.client().fatal().?.detail());
    try std.testing.expectEqual(@as(usize, 0), adapter.managers.items.len);
    try std.testing.expectEqual(@as(usize, 0), fixture.public_bind_count);
    try std.testing.expect(wrong.canDestroy());

    try testSend(expected.client(), 2, 0, &test_registry_bind, &.{
        .{ .uint = input_method_global.name() },
        .{ .new_id = .{ .generic = .{ .interface = protocol.zwp_input_method_manager_v2.interface.name, .version = 1, .id = 3 } } },
    });
    try std.testing.expect(expected.client().fatal() == null);
    try std.testing.expectEqual(@as(usize, 1), adapter.managers.items.len);
    try std.testing.expect(missing.client().fatal() == null);

    adapter.destroyClientResources(expected.client());
    try std.testing.expect(expected.canDestroy());
    adapter.managers.deinit(std.testing.allocator);
    adapter.methods.deinit(std.testing.allocator);
}
test "preedit validation uses UTF-8 byte boundaries" {
    try std.testing.expect(validPreeditCursor("hé", -1, -1));
    try std.testing.expect(!validPreeditCursor("hé", -1, 3));
    try std.testing.expect(!validPreeditCursor("hé", 2, 3));
    try std.testing.expect(!validText("\xff"));
}
