//! Privileged input-method-v2 core edit relay; grabs and popups are inert.

const InputMethodGlobal = @This();
const std = @import("std");
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const CompositorGlobal = @import("CompositorGlobal.zig");
const SecurityContextGlobal = @import("SecurityContextGlobal.zig");
const SeatGlobal = @import("SeatGlobal.zig");
const TextInputGlobal = @import("TextInputGlobal.zig");

const maximum_text_size = 4000;
allocator: std.mem.Allocator,
server: *Server,
seat: *SeatGlobal,
text_input: *TextInputGlobal,
global_name: u32,
methods: std.ArrayList(*Method) = .empty,
available: ?*Method = null,

const OwnedPreedit = struct { text: []u8, begin: i32, end: i32 };
const Method = struct {
    owner: *InputMethodGlobal,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    available: bool,
    active: bool = false,
    done_serial: u32 = 0,
    preedit: ?OwnedPreedit = null,
    commit_text: ?[]u8 = null,
    delete_before: u32 = 0,
    delete_after: u32 = 0,
    children: std.ArrayList(*Child) = .empty,
};
const Child = struct {
    allocator: std.mem.Allocator,
    method: ?*Method,
    resource: wayring.ObjectHandle,
    surface: ?*CompositorGlobal.Surface = null,
    surface_alive: bool = false,
};

pub fn init(self: *InputMethodGlobal, allocator: std.mem.Allocator, server: *Server, seat: *SeatGlobal, text_input: *TextInputGlobal, security: *SecurityContextGlobal) !void {
    self.* = .{ .allocator = allocator, .server = server, .seat = seat, .text_input = text_input, .global_name = undefined };
    self.global_name = try server.createGlobal(&generated.zwp_input_method_manager_v2, 1, .{ .context = self, .bind = bind, .filter_context = security, .filter = SecurityContextGlobal.allowUnconfined });
    errdefer server.removeGlobal(self.global_name) catch unreachable;
    text_input.setListener(.{ .context = self, .changed = textChanged });
}
pub fn deinit(self: *InputMethodGlobal) void {
    self.text_input.clearListener();
    self.server.removeGlobal(self.global_name) catch unreachable;
    std.debug.assert(self.methods.items.len == 0);
    self.methods.deinit(self.allocator);
}
fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *InputMethodGlobal = @ptrCast(@alignCast(context));
    _ = client.createResource(id, &generated.zwp_input_method_manager_v2, version, .{ .context = self, .dispatch = dispatchManager }) catch return client.postNoMemory();
}
fn dispatchManager(context: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    const self: *InputMethodGlobal = @ptrCast(@alignCast(context));
    switch (try generated.zwp_input_method_manager_v2_types.decodeRequest(&client.connection, resource, message)) {
        .destroy => {},
        .get_input_method => |r| try self.createMethod(client, r.input_method, !self.seat.ownsResource(client, r.seat)),
    }
}
fn createMethod(self: *InputMethodGlobal, client: *Server.Client, id: u32, wrong_seat: bool) !void {
    self.methods.ensureUnusedCapacity(self.allocator, 1) catch return client.postNoMemory();
    const method = self.allocator.create(Method) catch return client.postNoMemory();
    var method_owned = true;
    errdefer if (method_owned) self.allocator.destroy(method);
    method.* = .{ .owner = self, .client = client, .resource = undefined, .available = !wrong_seat and self.available == null };
    method.resource = client.createResource(id, &generated.zwp_input_method_v2, 1, .{ .context = method, .dispatch = dispatchMethod, .destroy = destroyMethod }) catch return client.postNoMemory();
    self.methods.appendAssumeCapacity(method);
    method_owned = false;
    errdefer client.destroyResource(method.resource) catch {};
    if (!method.available) return generated.zwp_input_method_v2_types.events.unavailable(&client.connection, method.resource) catch client.postNoMemory();
    self.available = method;
    sync(method) catch return client.postNoMemory();
}
fn dispatchMethod(context: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    const method: *Method = @ptrCast(@alignCast(context));
    const request = try generated.zwp_input_method_v2_types.decodeRequest(&client.connection, resource, message);
    if (!method.available) return;
    switch (request) {
        .destroy => {},
        .commit_string => |r| try setText(method, &method.commit_text, r.text),
        .set_preedit_string => |r| if (validText(r.text) and validCursor(r.text, r.cursor_begin, r.cursor_end)) {
            const copy = method.owner.allocator.dupe(u8, r.text) catch return client.postNoMemory();
            if (method.preedit) |old| method.owner.allocator.free(old.text);
            method.preedit = .{ .text = copy, .begin = r.cursor_begin, .end = r.cursor_end };
        },
        .delete_surrounding_text => |r| {
            method.delete_before = r.before_length;
            method.delete_after = r.after_length;
        },
        .commit => |r| relay(method, r.serial),
        .get_input_popup_surface => |r| try createPopup(method, resource, r.id, r.surface),
        .grab_keyboard => |r| try createGrab(method, r.keyboard),
    }
}
fn setText(method: *Method, slot: *?[]u8, text: []const u8) !void {
    if (!validText(text)) return;
    const copy = method.owner.allocator.dupe(u8, text) catch return method.client.postNoMemory();
    if (slot.*) |old| method.owner.allocator.free(old);
    slot.* = copy;
}
fn relay(method: *Method, serial: u32) void {
    defer reset(method);
    if (!method.active or serial != method.done_serial) return;
    const state = method.owner.text_input.activeState() orelse return;
    var before = method.delete_before;
    var after = method.delete_after;
    if (!validDelete(state.surrounding, before, after)) {
        before = 0;
        after = 0;
    }
    _ = method.owner.text_input.sendEdit(.{ .preedit = if (method.preedit) |p| .{ .text = p.text, .begin = p.begin, .end = p.end } else null, .commit = method.commit_text, .delete_before = before, .delete_after = after });
}
fn sync(method: *Method) !void {
    const state = method.owner.text_input.activeState();
    const active = state != null;
    if (!active and !method.active) return;
    if (active != method.active) {
        reset(method);
        if (active) try generated.zwp_input_method_v2_types.events.activate(&method.client.connection, method.resource) else try generated.zwp_input_method_v2_types.events.deactivate(&method.client.connection, method.resource);
        method.active = active;
    }
    if (state) |s| {
        if (s.surrounding) |v| try generated.zwp_input_method_v2_types.events.surrounding_text(&method.client.connection, method.resource, v.text, v.cursor, v.anchor);
        try generated.zwp_input_method_v2_types.events.text_change_cause(&method.client.connection, method.resource, s.cause);
        try generated.zwp_input_method_v2_types.events.content_type(&method.client.connection, method.resource, s.hint, s.purpose);
    }
    try generated.zwp_input_method_v2_types.events.done(&method.client.connection, method.resource);
    method.done_serial +%= 1;
}
fn textChanged(context: *anyopaque) void {
    const self: *InputMethodGlobal = @ptrCast(@alignCast(context));
    if (self.available) |method| sync(method) catch method.client.postNoMemory() catch {};
}
fn createChild(method: *Method, id: u32, interface: *const wayring.Interface) !*Child {
    method.children.ensureUnusedCapacity(method.owner.allocator, 1) catch {
        try method.client.postNoMemory();
        return error.OutOfMemory;
    };
    const child = method.owner.allocator.create(Child) catch {
        try method.client.postNoMemory();
        return error.OutOfMemory;
    };
    errdefer method.owner.allocator.destroy(child);
    child.* = .{ .allocator = method.owner.allocator, .method = method, .resource = undefined };
    child.resource = method.client.createResource(id, interface, 1, .{ .context = child, .dispatch = dispatchChild, .destroy = destroyChild }) catch {
        try method.client.postNoMemory();
        return error.OutOfMemory;
    };
    errdefer method.client.destroyResource(child.resource) catch {};
    method.children.appendAssumeCapacity(child);
    return child;
}
fn createGrab(method: *Method, id: u32) !void {
    const child = try createChild(method, id, &generated.zwp_input_method_keyboard_grab_v2);
    const repeat = method.owner.seat.currentKeyboardRepeatInfo();
    generated.zwp_input_method_keyboard_grab_v2_types.events.repeat_info(
        &method.client.connection,
        child.resource,
        repeat.rate,
        repeat.delay,
    ) catch return method.client.postNoMemory();
}
fn createPopup(method: *Method, method_resource: wayring.ObjectHandle, id: u32, surface_id: u32) !void {
    const object = method.client.connection.object(surface_id) orelse return error.UnknownSurface;
    const surface = try CompositorGlobal.surfaceFor(method.client, .{ .id = surface_id, .generation = object.generation });
    const child = try createChild(method, id, &generated.zwp_input_popup_surface_v2);
    surface.reference() catch return method.client.postNoMemory();
    child.surface = surface;
    child.surface_alive = true;
    surface.setRole(method.owner, child, popupSurfaceDestroyed) catch return method.client.postError(
        method_resource,
        @intFromEnum(generated.zwp_input_method_v2_types.@"error".role),
        "wl_surface already has a role",
    );
}
fn dispatchChild(_: *anyopaque, _: *Server.Client, _: wayring.ObjectHandle, _: *wayring.Message) !void {}
fn destroyChild(context: *anyopaque, _: *Server.Client, _: wayring.ObjectHandle) void {
    const child: *Child = @ptrCast(@alignCast(context));
    if (child.method) |method| for (method.children.items, 0..) |item, i| if (item == child) {
        _ = method.children.orderedRemove(i);
        break;
    };
    if (child.surface) |surface| {
        if (surface.role_context == @as(*anyopaque, @ptrCast(child))) surface.clearRole(child);
        surface.unreference();
    }
    child.allocator.destroy(child);
}
fn popupSurfaceDestroyed(context: *anyopaque) void {
    const child: *Child = @ptrCast(@alignCast(context));
    child.surface_alive = false;
}
fn destroyMethod(context: *anyopaque, _: *Server.Client, _: wayring.ObjectHandle) void {
    const method: *Method = @ptrCast(@alignCast(context));
    if (method.owner.available == method) method.owner.available = null;
    reset(method);
    while (method.children.items.len != 0) {
        const child = method.children.pop().?;
        child.method = null;
        method.client.deferResourceDestroy(child.resource) catch method.client.postNoMemory() catch {};
    }
    finalizeMethod(method);
}
fn finalizeMethod(method: *Method) void {
    const owner = method.owner;
    for (owner.methods.items, 0..) |item, i| if (item == method) {
        _ = owner.methods.orderedRemove(i);
        break;
    };
    method.children.deinit(owner.allocator);
    owner.allocator.destroy(method);
}
fn reset(method: *Method) void {
    if (method.preedit) |p| method.owner.allocator.free(p.text);
    if (method.commit_text) |text| method.owner.allocator.free(text);
    method.preedit = null;
    method.commit_text = null;
    method.delete_before = 0;
    method.delete_after = 0;
}
fn validText(text: []const u8) bool {
    return text.len <= maximum_text_size and std.unicode.utf8ValidateSlice(text);
}
fn validIndex(text: []const u8, index: usize) bool {
    return index <= text.len and (index == text.len or text[index] & 0xc0 != 0x80);
}
fn validCursor(text: []const u8, begin: i32, end: i32) bool {
    if (begin == -1 or end == -1) return begin == -1 and end == -1;
    return begin >= 0 and end >= 0 and validIndex(text, @intCast(begin)) and validIndex(text, @intCast(end));
}
fn validDelete(surrounding: ?TextInputGlobal.Surrounding, before: u32, after: u32) bool {
    if (before == 0 and after == 0) return true;
    const s = surrounding orelse return false;
    return before <= s.cursor and after <= s.text.len - s.cursor and validIndex(s.text, s.cursor - before) and validIndex(s.text, s.cursor + after);
}

test "input method validates UTF-8 and edit bounds" {
    try std.testing.expect(validText("hé"));
    try std.testing.expect(validCursor("hé", 0, 3));
    try std.testing.expect(!validCursor("hé", 2, 3));
    try std.testing.expect(!validText(&[_]u8{0xff}));
    try std.testing.expect(!validDelete(.{ .text = "hé", .cursor = 3, .anchor = 3 }, 1, 0));
}

test "input method relays a focused text input stream and isolates lifetimes" {
    const core = @import("wayring-core");
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var compositor: CompositorGlobal = undefined;
    try compositor.init(std.testing.allocator, &server);
    defer compositor.deinit();
    var seat: SeatGlobal = undefined;
    try seat.init(std.testing.allocator, &server, "default", SeatGlobal.Capability.keyboard, null);
    defer seat.deinit();
    var other_seat: SeatGlobal = undefined;
    try other_seat.init(std.testing.allocator, &server, "other", 0, null);
    defer other_seat.deinit();
    var text_inputs: TextInputGlobal = undefined;
    try text_inputs.init(std.testing.allocator, &server, &seat);
    defer text_inputs.deinit();
    var security: SecurityContextGlobal = undefined;
    var input_methods: InputMethodGlobal = undefined;
    try input_methods.init(std.testing.allocator, &server, &seat, &text_inputs, &security);
    defer input_methods.deinit();

    const app = try server.createClient();
    defer server.destroyClient(app) catch {};
    const ime = try server.createClient();
    defer server.destroyClient(ime) catch {};
    var app_peer = wayring.Connection.init(std.testing.allocator, .client, wayring.default_max_frame_size);
    defer app_peer.deinit();
    var ime_peer = wayring.Connection.init(std.testing.allocator, .client, wayring.default_max_frame_size);
    defer ime_peer.deinit();

    const AppGlobals = struct { registry: wayring.ObjectHandle, compositor: u32, seat: u32, text: u32 };
    const ImeGlobals = struct { registry: wayring.ObjectHandle, compositor: u32, seat: u32, other_seat: u32, method: u32 };
    const app_registry: wayring.ObjectHandle = .{ .id = 2, .generation = blk: {
        _ = try core.bootstrapDisplay(&app_peer);
        break :blk try core.getRegistry(&app_peer, 2);
    } };
    try transferToServer(&app_peer, app);
    try transferFromServer(&app_peer, app);
    var app_globals: AppGlobals = .{ .registry = app_registry, .compositor = 0, .seat = 0, .text = 0 };
    while (app_peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const event = try core.decodeRegistryEvent(&message, app_registry.id);
        if (event != .global) continue;
        if (std.mem.eql(u8, event.global.interface, generated.wl_compositor.name)) app_globals.compositor = event.global.name;
        if (event.global.name == seat.globalName()) app_globals.seat = event.global.name;
        if (std.mem.eql(u8, event.global.interface, generated.zwp_text_input_manager_v3.name)) app_globals.text = event.global.name;
    }
    const ime_registry: wayring.ObjectHandle = .{ .id = 2, .generation = blk: {
        _ = try core.bootstrapDisplay(&ime_peer);
        break :blk try core.getRegistry(&ime_peer, 2);
    } };
    try transferToServer(&ime_peer, ime);
    try transferFromServer(&ime_peer, ime);
    var ime_globals: ImeGlobals = .{ .registry = ime_registry, .compositor = 0, .seat = 0, .other_seat = 0, .method = 0 };
    while (ime_peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const event = try core.decodeRegistryEvent(&message, ime_registry.id);
        if (event != .global) continue;
        if (std.mem.eql(u8, event.global.interface, generated.wl_compositor.name)) ime_globals.compositor = event.global.name;
        if (event.global.name == seat.globalName()) ime_globals.seat = event.global.name;
        if (event.global.name == other_seat.globalName()) ime_globals.other_seat = event.global.name;
        if (std.mem.eql(u8, event.global.interface, generated.zwp_input_method_manager_v2.name)) ime_globals.method = event.global.name;
    }
    try std.testing.expect(app_globals.compositor != 0 and app_globals.seat != 0 and app_globals.text != 0);
    try std.testing.expect(ime_globals.compositor != 0 and ime_globals.seat != 0 and ime_globals.other_seat != 0 and ime_globals.method != 0);

    const app_compositor = try bindGlobal(core, &app_peer, app_registry, app_globals.compositor, &generated.wl_compositor, 3);
    const app_seat = try bindGlobal(core, &app_peer, app_registry, app_globals.seat, &generated.wl_seat, 4);
    const text_manager = try bindGlobal(core, &app_peer, app_registry, app_globals.text, &generated.zwp_text_input_manager_v3, 5);
    const surface_handle = try generated.wl_compositor_types.requests.create_surface(&app_peer, app_compositor);
    const text_input = try generated.zwp_text_input_manager_v3_types.requests.get_text_input(&app_peer, text_manager, app_seat);
    try transferToServer(&app_peer, app);
    const surface = try CompositorGlobal.surfaceFor(app, .{ .id = surface_handle.id, .generation = app.connection.object(surface_handle.id).?.generation });
    _ = try seat.keyboardEnter(surface, &.{});
    try transferFromServer(&app_peer, app);
    var entered = false;
    while (app_peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == text_input.id) entered = (try generated.zwp_text_input_v3_types.decodeEvent(&app_peer, text_input, &message)) == .enter;
    }
    try std.testing.expect(entered);

    const ime_compositor = try bindGlobal(core, &ime_peer, ime_registry, ime_globals.compositor, &generated.wl_compositor, 6);
    const ime_seat = try bindGlobal(core, &ime_peer, ime_registry, ime_globals.seat, &generated.wl_seat, 3);
    const method_manager = try bindGlobal(core, &ime_peer, ime_registry, ime_globals.method, &generated.zwp_input_method_manager_v2, 4);
    const ime_other_seat = try bindGlobal(core, &ime_peer, ime_registry, ime_globals.other_seat, &generated.wl_seat, 5);
    const method = try generated.zwp_input_method_manager_v2_types.requests.get_input_method(&ime_peer, method_manager, ime_seat);
    // A second producer and a producer for another client's seat resource are inert.
    const duplicate = try generated.zwp_input_method_manager_v2_types.requests.get_input_method(&ime_peer, method_manager, ime_seat);
    const wrong_seat = try generated.zwp_input_method_manager_v2_types.requests.get_input_method(&ime_peer, method_manager, ime_other_seat);
    try transferToServer(&ime_peer, ime);
    try generated.zwp_text_input_v3_types.requests.set_surrounding_text(&app_peer, text_input, "secret", 6, 6);
    try generated.zwp_text_input_v3_types.requests.enable(&app_peer, text_input);
    try generated.zwp_text_input_v3_types.requests.commit(&app_peer, text_input);
    try transferToServer(&app_peer, app);
    try transferFromServer(&ime_peer, ime);
    var activated = false;
    var done_count: usize = 0;
    var unavailable: usize = 0;
    while (ime_peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == method.id) switch (try generated.zwp_input_method_v2_types.decodeEvent(&ime_peer, method, &message)) {
            .activate => activated = true,
            .done => done_count += 1,
            else => {},
        } else if (message.object_id == duplicate.id or message.object_id == wrong_seat.id) {
            const handle = if (message.object_id == duplicate.id) duplicate else wrong_seat;
            if ((try generated.zwp_input_method_v2_types.decodeEvent(&ime_peer, handle, &message)) == .unavailable) unavailable += 1;
        }
    }
    try std.testing.expect(activated);
    try std.testing.expectEqual(@as(usize, 1), done_count);
    try std.testing.expectEqual(@as(usize, 2), unavailable);

    // Ordinary text-input updates advance done without discarding staged edits.
    try generated.zwp_input_method_v2_types.requests.set_preedit_string(&ime_peer, method, "pre", 3, 3);
    try transferToServer(&ime_peer, ime);
    try generated.zwp_text_input_v3_types.requests.set_content_type(&app_peer, text_input, 0, 0);
    try generated.zwp_text_input_v3_types.requests.commit(&app_peer, text_input);
    try transferToServer(&app_peer, app);
    try transferFromServer(&ime_peer, ime);
    var update_done = false;
    while (ime_peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == method.id)
            update_done = (try generated.zwp_input_method_v2_types.decodeEvent(&ime_peer, method, &message)) == .done or update_done;
    }
    try std.testing.expect(update_done);
    try generated.zwp_input_method_v2_types.requests.commit(&ime_peer, method, 2);
    try transferToServer(&ime_peer, ime);
    try transferFromServer(&app_peer, app);
    var preedit = false;
    var text_done: usize = 0;
    while (app_peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        switch (try generated.zwp_text_input_v3_types.decodeEvent(&app_peer, text_input, &message)) {
            .preedit_string => |event| preedit = std.mem.eql(u8, event.text.?, "pre"),
            .done => text_done += 1,
            else => {},
        }
    }
    try std.testing.expect(preedit);
    try std.testing.expectEqual(@as(usize, 1), text_done);

    // A stale serial emits nothing. A current commit clears preedit before committing text.
    try generated.zwp_input_method_v2_types.requests.commit_string(&ime_peer, method, "ignored");
    try generated.zwp_input_method_v2_types.requests.commit(&ime_peer, method, 0);
    try generated.zwp_input_method_v2_types.requests.set_preedit_string(&ime_peer, method, "", 0, 0);
    try generated.zwp_input_method_v2_types.requests.commit_string(&ime_peer, method, "ok");
    try generated.zwp_input_method_v2_types.requests.commit(&ime_peer, method, 2);
    try transferToServer(&ime_peer, ime);
    try transferFromServer(&app_peer, app);
    var order: [3]u8 = undefined;
    var order_len: usize = 0;
    while (app_peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        switch (try generated.zwp_text_input_v3_types.decodeEvent(&app_peer, text_input, &message)) {
            .preedit_string => order[order_len] = 'p',
            .commit_string => |event| {
                try std.testing.expectEqualStrings("ok", event.text.?);
                order[order_len] = 'c';
            },
            .done => order[order_len] = 'd',
            else => continue,
        }
        order_len += 1;
    }
    try std.testing.expectEqualStrings("pcd", order[0..order_len]);

    _ = try seat.keyboardLeave();
    // Commits remain serial-bearing while unfocused, but pending surrounding text is discarded.
    try generated.zwp_text_input_v3_types.requests.set_surrounding_text(&app_peer, text_input, "must-not-leak", 13, 13);
    try generated.zwp_text_input_v3_types.requests.commit(&app_peer, text_input);
    try transferToServer(&app_peer, app);
    try std.testing.expectEqual(@as(u32, 3), text_inputs.inputs.items[0].serial);
    _ = try seat.keyboardEnter(surface, &.{});
    try generated.zwp_text_input_v3_types.requests.enable(&app_peer, text_input);
    try generated.zwp_text_input_v3_types.requests.commit(&app_peer, text_input);
    try transferToServer(&app_peer, app);
    try std.testing.expect(text_inputs.activeState().?.surrounding == null);
    try transferFromServer(&ime_peer, ime);
    var deactivated = false;
    var reactivated_without_surrounding = false;
    while (ime_peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        switch (try generated.zwp_input_method_v2_types.decodeEvent(&ime_peer, method, &message)) {
            .deactivate => deactivated = true,
            .activate => reactivated_without_surrounding = true,
            .surrounding_text => return error.SurroundingTextLeaked,
            else => {},
        }
    }
    try std.testing.expect(deactivated and reactivated_without_surrounding);

    // Destroying the focused surface skips an impossible leave event but still deactivates.
    try generated.wl_surface_types.requests.destroy(&app_peer, surface_handle);
    try transferToServer(&app_peer, app);
    _ = try seat.keyboardLeave();
    try std.testing.expect(app.state == .active);
    try transferFromServer(&ime_peer, ime);
    var destroyed_surface_deactivated = false;
    while (ime_peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == method.id)
            destroyed_surface_deactivated = (try generated.zwp_input_method_v2_types.decodeEvent(&ime_peer, method, &message)) == .deactivate or destroyed_surface_deactivated;
    }
    try std.testing.expect(destroyed_surface_deactivated);

    // Inert grabs still receive their mandatory initialization, and popup
    // surfaces retain their role until the parent method destroys its children.
    try seat.keyboardRepeatInfo(25, 600);
    const grab = try generated.zwp_input_method_v2_types.requests.grab_keyboard(&ime_peer, method);
    const popup_surface = try generated.wl_compositor_types.requests.create_surface(&ime_peer, ime_compositor);
    const popup = try generated.zwp_input_method_v2_types.requests.get_input_popup_surface(&ime_peer, method, popup_surface);
    try transferToServer(&ime_peer, ime);
    try transferFromServer(&ime_peer, ime);
    var got_repeat = false;
    while (ime_peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id != grab.id) continue;
        switch (try generated.zwp_input_method_keyboard_grab_v2_types.decodeEvent(&ime_peer, grab, &message)) {
            .repeat_info => |event| got_repeat = event.rate == 25 and event.delay == 600,
            else => {},
        }
    }
    try std.testing.expect(got_repeat);
    const popup_surface_context = try CompositorGlobal.surfaceFor(ime, .{
        .id = popup_surface.id,
        .generation = ime.connection.object(popup_surface.id).?.generation,
    });
    try std.testing.expect(popup_surface_context.role_context != null);

    // Managers, products, and text inputs have independent protocol lifetimes.
    try generated.zwp_input_method_manager_v2_types.requests.destroy(&ime_peer, method_manager);
    try generated.zwp_text_input_manager_v3_types.requests.destroy(&app_peer, text_manager);
    try generated.zwp_input_method_v2_types.requests.destroy(&ime_peer, duplicate);
    try generated.zwp_input_method_v2_types.requests.destroy(&ime_peer, wrong_seat);
    try generated.zwp_input_method_v2_types.requests.destroy(&ime_peer, method);
    try generated.zwp_text_input_v3_types.requests.destroy(&app_peer, text_input);
    try transferToServer(&ime_peer, ime);
    try transferToServer(&app_peer, app);
    try std.testing.expectError(error.UnknownResource, ime.resourceContext(grab, &generated.zwp_input_method_keyboard_grab_v2));
    try std.testing.expectError(error.UnknownResource, ime.resourceContext(popup, &generated.zwp_input_popup_surface_v2));
    try std.testing.expect(popup_surface_context.role_context == null);
    try std.testing.expectEqual(@as(usize, 0), input_methods.methods.items.len);
    try std.testing.expectEqual(@as(usize, 0), text_inputs.inputs.items.len);
}

test "input method parent teardown keeps children valid when deferral allocation fails" {
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    const client = try server.createClient();
    var client_owned = true;
    defer if (client_owned) server.destroyClient(client) catch unreachable;

    var owner: InputMethodGlobal = .{
        .allocator = std.testing.allocator,
        .server = &server,
        .seat = undefined,
        .text_input = undefined,
        .global_name = 0,
    };
    defer owner.methods.deinit(std.testing.allocator);
    const method = try std.testing.allocator.create(Method);
    method.* = .{
        .owner = &owner,
        .client = client,
        .resource = undefined,
        .available = true,
    };
    method.resource = try client.createResource(
        100,
        &generated.zwp_input_method_v2,
        1,
        .{ .context = method, .dispatch = dispatchMethod, .destroy = destroyMethod },
    );
    try owner.methods.append(std.testing.allocator, method);
    owner.available = method;

    const child = try std.testing.allocator.create(Child);
    child.* = .{
        .allocator = std.testing.allocator,
        .method = method,
        .resource = try client.createResource(
            101,
            &generated.zwp_input_method_keyboard_grab_v2,
            1,
            .{ .context = undefined, .dispatch = dispatchChild, .destroy = destroyChild },
        ),
    };
    const registered_child = client.resources.getPtr(child.resource.id).?;
    registered_child.implementation.context = child;
    try method.children.append(std.testing.allocator, child);
    try client.retired_ids.ensureUnusedCapacity(std.testing.allocator, 2);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    client.allocator = failing.allocator();
    try client.destroyResource(method.resource);
    client.allocator = std.testing.allocator;

    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(Server.ClientState.protocol_error, client.state);
    try std.testing.expectEqual(@as(usize, 0), owner.methods.items.len);
    try std.testing.expect(child.method == null);
    try std.testing.expect((try client.resourceContext(child.resource, &generated.zwp_input_method_keyboard_grab_v2)) == @as(*anyopaque, @ptrCast(child)));

    try server.destroyClient(client);
    client_owned = false;
}

test "input method global rejects confined and guessed binds" {
    const core = @import("wayring-core");
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var seat: SeatGlobal = undefined;
    try seat.init(std.testing.allocator, &server, "default", 0, null);
    defer seat.deinit();
    var text_inputs: TextInputGlobal = undefined;
    try text_inputs.init(std.testing.allocator, &server, &seat);
    defer text_inputs.deinit();
    var security: SecurityContextGlobal = undefined;
    var input_methods: InputMethodGlobal = undefined;
    try input_methods.init(std.testing.allocator, &server, &seat, &text_inputs, &security);
    defer input_methods.deinit();
    const client = try server.createClientWithProvenance(try SecurityContextGlobal.Testing.confinedProvenance(std.testing.allocator));
    defer server.destroyClient(client) catch {};
    var peer = wayring.Connection.init(std.testing.allocator, .client, wayring.default_max_frame_size);
    defer peer.deinit();
    _ = try core.bootstrapDisplay(&peer);
    const registry: wayring.ObjectHandle = .{ .id = 2, .generation = try core.getRegistry(&peer, 2) };
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const event = try core.decodeRegistryEvent(&message, registry.id);
        if (event == .global)
            try std.testing.expect(!std.mem.eql(u8, event.global.interface, generated.zwp_input_method_manager_v2.name));
    }
    _ = try core.bind(&peer, registry.id, input_methods.global_name, generated.zwp_input_method_manager_v2.name, 1, 3, &generated.zwp_input_method_manager_v2);
    try std.testing.expectError(error.ProtocolError, transferToServer(&peer, client));
}

fn bindGlobal(
    core: type,
    connection: *wayring.Connection,
    registry: wayring.ObjectHandle,
    name: u32,
    interface: *const wayring.Interface,
    id: u32,
) !wayring.ObjectHandle {
    return .{ .id = id, .generation = try core.bind(connection, registry.id, name, interface.name, 1, id, interface) };
}

fn transferToServer(connection: *wayring.Connection, client: *Server.Client) !void {
    while (connection.nextBatch()) |batch| {
        try client.receive(batch.bytes, batch.fds);
        try connection.acknowledge(batch.token, batch.bytes.len);
    }
}

fn transferFromServer(connection: *wayring.Connection, client: *Server.Client) !void {
    while (client.connection.nextBatch()) |batch| {
        try connection.feed(batch.bytes, batch.fds);
        try client.connection.acknowledge(batch.token, batch.bytes.len);
    }
    try client.outputDrained();
}
