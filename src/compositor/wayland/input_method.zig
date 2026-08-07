//! Privileged input-method relay, keyboard grab, and popup surfaces.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const render = @import("../render/types.zig");
const SecurityContext = @import("security_context.zig");
const Seat = @import("seat.zig");
const Surface = @import("surface.zig");
const NeutralTextInput = @import("../TextInput.zig");

const wl = wayland.server.wl;
const zwp = wayland.server.zwp;

allocator: std.mem.Allocator,
display: *wl.Server,
global: *wl.Global,
security_context: *SecurityContext,
seat: *Seat,
surfaces: *Surface.Store,
owner: *NeutralTextInput,
layout: Layout,
methods: std.ArrayList(*Method),
active_method: ?*Method,
popups: std.ArrayList(*Popup),
next_grab_token: u64,
inhibited: bool,

pub const Position = struct {
    x: i32 = 0,
    y: i32 = 0,
};

pub const Layout = struct {
    context: *anyopaque,
    surface_position: *const fn (*anyopaque, Surface.Id) ?Position,
    output_size: *const fn (*anyopaque) render.Size,
    repaint: *const fn (*anyopaque) void,
};

pub const PopupInfo = struct {
    surface_id: Surface.Id,
    position: Position,
};

pub const PopupIterator = struct {
    manager: *Self,
    index: usize = 0,

    pub fn next(self: *PopupIterator) ?PopupInfo {
        while (self.index < self.manager.popups.items.len) {
            const popup = self.manager.popups.items[self.index];
            self.index += 1;
            if (!popup.mapped or popup.surface == null) continue;
            return .{
                .surface_id = popup.surface_id,
                .position = popup.position,
            };
        }
        return null;
    }
};

pub const ReversePopupIterator = struct {
    manager: *Self,
    index: usize,

    pub fn next(self: *ReversePopupIterator) ?PopupInfo {
        while (self.index > 0) {
            self.index -= 1;
            const popup = self.manager.popups.items[self.index];
            if (!popup.mapped or popup.surface == null) continue;
            return .{
                .surface_id = popup.surface_id,
                .position = popup.position,
            };
        }
        return null;
    }
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    security_context: *SecurityContext,
    seat: *Seat,
    surfaces: *Surface.Store,
    owner: *NeutralTextInput,
    layout: Layout,
) !void {
    self.* = .{
        .allocator = allocator,
        .display = display,
        .global = undefined,
        .security_context = security_context,
        .seat = seat,
        .surfaces = surfaces,
        .owner = owner,
        .layout = layout,
        .methods = .empty,
        .active_method = null,
        .popups = .empty,
        .next_grab_token = 1,
        .inhibited = false,
    };
    errdefer self.methods.deinit(allocator);
    errdefer self.popups.deinit(allocator);
    self.global = try wl.Global.create(display, zwp.InputMethodManagerV2, 1, *Self, self, bind);
    errdefer self.global.destroy();
    try security_context.restrictGlobal(self.global);
    errdefer security_context.unrestrictGlobal(self.global);
}

pub fn deinit(self: *Self) void {
    self.security_context.unrestrictGlobal(self.global);
    self.global.destroy();
    std.debug.assert(self.active_method == null);
    std.debug.assert(self.methods.items.len == 0);
    std.debug.assert(self.popups.items.len == 0);
    self.popups.deinit(self.allocator);
    self.methods.deinit(self.allocator);
    self.* = undefined;
}

pub fn popupIterator(self: *Self) PopupIterator {
    return .{ .manager = self };
}

pub fn reversePopupIterator(self: *Self) ReversePopupIterator {
    return .{ .manager = self, .index = self.popups.items.len };
}

pub fn refreshPopups(self: *Self) void {
    self.updatePopups();
}

pub fn setInhibited(self: *Self, inhibited: bool) void {
    if (self.inhibited == inhibited) return;
    self.inhibited = inhibited;
    self.owner.setInhibited(inhibited);
    if (inhibited) {
        if (self.active_method) |method| if (method.active_grab) |grab| {
            grab.active = false;
            method.active_grab = null;
            self.seat.clearKeyboardGrab(grab, false);
        };
    }
    if (!inhibited) {
        const method = self.active_method orelse return;
        if (!method.available or method.active_grab != null or method.grabs.items.len == 0) return;
        const grab = method.grabs.items[method.grabs.items.len - 1];
        grab.active = true;
        grab.activate();
    }
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = zwp.InputMethodManagerV2.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleManagerRequest, null, self);
}

fn handleManagerRequest(
    resource: *zwp.InputMethodManagerV2,
    request: zwp.InputMethodManagerV2.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .get_input_method => |get| {
            Method.create(
                self,
                resource.getClient(),
                resource.getVersion(),
                get.input_method,
                !self.seat.ownsResource(get.seat),
            ) catch resource.postNoMemory();
        },
    }
}

const Method = struct {
    allocator: std.mem.Allocator,
    manager: *Self,
    resource: *zwp.InputMethodV2,
    neutral_id: NeutralTextInput.MethodId,
    available: bool,
    grabs: std.ArrayList(*KeyboardGrab) = .empty,
    active_grab: ?*KeyboardGrab = null,
    inert_popups: std.ArrayList(*InertPopup) = .empty,

    fn create(
        manager: *Self,
        client: *wl.Client,
        version: u32,
        id: u32,
        force_inert: bool,
    ) error{ OutOfMemory, ResourceCreateFailed }!void {
        const resource = try zwp.InputMethodV2.create(client, version, id);
        errdefer resource.destroy();
        const self = manager.allocator.create(Method) catch return error.OutOfMemory;
        errdefer manager.allocator.destroy(self);
        manager.methods.append(manager.allocator, self) catch return error.OutOfMemory;
        errdefer _ = manager.methods.pop();
        self.* = .{
            .allocator = manager.allocator,
            .manager = manager,
            .resource = resource,
            .neutral_id = undefined,
            .available = !force_inert and manager.active_method == null,
        };
        const client_id = manager.seat.matureClientId(client) orelse return error.ResourceCreateFailed;
        self.neutral_id = manager.owner.createMethodWithAvailability(client_id, .{
            .context = self,
            .activate = activate,
            .deactivate = deactivate,
            .state = state,
            .done = done,
            .unavailable = unavailable,
        }, !force_inert) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ResourceCreateFailed,
        };
        errdefer manager.owner.destroyMethod(self.neutral_id);
        resource.setHandler(*Method, handleRequest, handleDestroy, self);
        if (!self.available) return;
        manager.active_method = self;
    }

    fn activate(context: *anyopaque) void {
        const self: *Method = @ptrCast(@alignCast(context));
        self.resource.sendActivate();
    }
    fn deactivate(context: *anyopaque) void {
        const self: *Method = @ptrCast(@alignCast(context));
        self.resource.sendDeactivate();
    }
    fn state(context: *anyopaque, snapshot: NeutralTextInput.Snapshot) void {
        const self: *Method = @ptrCast(@alignCast(context));
        if (snapshot.surrounding_text) |text| self.resource.sendSurroundingText(text.ptr, snapshot.cursor, snapshot.anchor);
        self.resource.sendTextChangeCause(@enumFromInt(@intFromEnum(snapshot.change_cause)));
        self.resource.sendContentType(@bitCast(snapshot.content_hint), @enumFromInt(@intFromEnum(snapshot.content_purpose)));
    }
    fn done(context: *anyopaque, _: u32) void {
        const self: *Method = @ptrCast(@alignCast(context));
        self.resource.sendDone();
        self.manager.updatePopups();
    }
    fn unavailable(context: *anyopaque) void {
        const self: *Method = @ptrCast(@alignCast(context));
        self.available = false;
        self.resource.sendUnavailable();
    }

    fn handleRequest(
        resource: *zwp.InputMethodV2,
        request: zwp.InputMethodV2.Request,
        self: *Method,
    ) void {
        if (!self.available) {
            switch (request) {
                .destroy => resource.destroy(),
                .get_input_popup_surface => |get| InertPopup.create(self, get.id) catch
                    resource.postNoMemory(),
                .grab_keyboard => |grab| KeyboardGrab.create(self, grab.keyboard, false) catch
                    resource.postNoMemory(),
                else => {},
            }
            return;
        }
        switch (request) {
            .destroy => resource.destroy(),
            .commit_string => |set| self.setCommitString(resource, set.text),
            .set_preedit_string => |set| self.setPreedit(
                resource,
                set.text,
                set.cursor_begin,
                set.cursor_end,
            ),
            .delete_surrounding_text => |set| self.manager.owner.deleteSurrounding(self.neutral_id, .{
                .before_length = set.before_length,
                .after_length = set.after_length,
            }) catch {},
            .commit => |request_commit| self.manager.owner.commitEdit(self.neutral_id, request_commit.serial) catch {},
            .get_input_popup_surface => |get| Popup.create(
                self,
                Surface.fromResource(get.surface),
                get.id,
            ) catch |err| switch (err) {
                error.Role => resource.postError(.role, "wl_surface already has a role"),
                error.OutOfMemory, error.ResourceCreateFailed => resource.postNoMemory(),
            },
            .grab_keyboard => |grab| KeyboardGrab.create(self, grab.keyboard, true) catch
                resource.postNoMemory(),
        }
    }

    fn setCommitString(
        self: *Method,
        resource: *zwp.InputMethodV2,
        text_ptr: [*:0]const u8,
    ) void {
        const text = std.mem.span(text_ptr);
        if (!validText(text)) return;
        self.manager.owner.setCommitString(self.neutral_id, text) catch |err| if (err == error.OutOfMemory) resource.postNoMemory();
    }

    fn setPreedit(
        self: *Method,
        resource: *zwp.InputMethodV2,
        text_ptr: [*:0]const u8,
        cursor_begin: i32,
        cursor_end: i32,
    ) void {
        const text = std.mem.span(text_ptr);
        if (!validText(text) or !validPreeditCursor(text, cursor_begin, cursor_end)) return;
        self.manager.owner.setPreedit(self.neutral_id, text, cursor_begin, cursor_end) catch |err| if (err == error.OutOfMemory) resource.postNoMemory();
    }

    fn handleDestroy(_: *zwp.InputMethodV2, self: *Method) void {
        self.available = false;
        if (self.manager.active_method == self) self.manager.active_method = null;
        while (self.grabs.items.len > 0) {
            self.grabs.items[self.grabs.items.len - 1].resource.destroy();
        }
        while (self.inert_popups.items.len > 0) {
            self.inert_popups.items[self.inert_popups.items.len - 1].resource.destroy();
        }
        var popup_index = self.manager.popups.items.len;
        while (popup_index > 0) {
            popup_index -= 1;
            const popup = self.manager.popups.items[popup_index];
            if (popup.method == self) popup.resource.destroy();
        }
        for (self.manager.methods.items, 0..) |candidate, index| {
            if (candidate != self) continue;
            _ = self.manager.methods.orderedRemove(index);
            break;
        }
        self.manager.owner.destroyMethod(self.neutral_id);
        self.inert_popups.deinit(self.allocator);
        self.grabs.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

const KeyboardGrab = struct {
    method: *Method,
    resource: *zwp.InputMethodKeyboardGrabV2,
    neutral_id: NeutralTextInput.KeyboardGrabId,
    active: bool,
    token: u64,

    fn create(
        method: *Method,
        id: u32,
        usable: bool,
    ) error{ OutOfMemory, ResourceCreateFailed }!void {
        const resource = try zwp.InputMethodKeyboardGrabV2.create(
            method.resource.getClient(),
            method.resource.getVersion(),
            id,
        );
        errdefer resource.destroy();
        const self = method.allocator.create(KeyboardGrab) catch return error.OutOfMemory;
        errdefer method.allocator.destroy(self);
        method.grabs.append(method.allocator, self) catch return error.OutOfMemory;
        errdefer _ = method.grabs.pop();
        const neutral_id = method.manager.owner.createKeyboardGrab(method.neutral_id) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ResourceCreateFailed,
        };
        errdefer method.manager.owner.destroyKeyboardGrab(neutral_id);
        self.* = .{
            .method = method,
            .resource = resource,
            .neutral_id = neutral_id,
            .active = usable and !method.manager.inhibited and method.active_grab == null,
            .token = method.manager.next_grab_token,
        };
        method.manager.next_grab_token +%= 1;
        if (method.manager.next_grab_token == 0) method.manager.next_grab_token = 1;
        resource.setHandler(*KeyboardGrab, handleRequest, handleDestroy, self);
        if (self.active) self.activate();
    }

    fn handleRequest(
        resource: *zwp.InputMethodKeyboardGrabV2,
        request: zwp.InputMethodKeyboardGrabV2.Request,
        _: *KeyboardGrab,
    ) void {
        switch (request) {
            .release => resource.destroy(),
        }
    }

    fn handleDestroy(_: *zwp.InputMethodKeyboardGrabV2, self: *KeyboardGrab) void {
        const method = self.method;
        if (self.active) {
            method.active_grab = null;
        }
        for (method.grabs.items, 0..) |candidate, index| {
            if (candidate != self) continue;
            _ = method.grabs.orderedRemove(index);
            break;
        }
        const replacement = if (self.active and !method.manager.inhibited and method.available and
            method.manager.active_method == method and method.grabs.items.len > 0)
            method.grabs.items[method.grabs.items.len - 1]
        else
            null;
        if (self.active) method.manager.seat.clearKeyboardGrab(self, replacement == null);
        method.manager.owner.destroyKeyboardGrab(self.neutral_id);
        method.allocator.destroy(self);
        if (replacement) |grab| {
            grab.active = true;
            grab.activate();
        }
    }

    fn activate(self: *KeyboardGrab) void {
        self.method.active_grab = self;
        const installed = self.method.manager.seat.setKeyboardGrab(.{
            .context = self,
            .token = self.token,
            .cancel = cancel,
            .keymap = sendKeymap,
            .key = sendKey,
            .modifiers = sendModifiers,
            .repeat_info = sendRepeatInfo,
        });
        std.debug.assert(installed);
    }

    fn cancel(context: *anyopaque) void {
        const self: *KeyboardGrab = @ptrCast(@alignCast(context));
        std.debug.assert(self.active);
        std.debug.assert(self.method.active_grab == self);
        self.active = false;
        self.method.active_grab = null;
        self.method.manager.seat.clearKeyboardGrab(self, false);
    }

    fn sendKeymap(
        context: *anyopaque,
        format: wl.Keyboard.KeymapFormat,
        fd: std.posix.fd_t,
        size: u32,
    ) void {
        const self: *KeyboardGrab = @ptrCast(@alignCast(context));
        self.resource.sendKeymap(format, fd, size);
    }

    fn sendKey(
        context: *anyopaque,
        serial: u32,
        time: u32,
        key: u32,
        state: wl.Keyboard.KeyState,
    ) void {
        const self: *KeyboardGrab = @ptrCast(@alignCast(context));
        self.resource.sendKey(serial, time, key, state);
    }

    fn sendModifiers(
        context: *anyopaque,
        serial: u32,
        depressed: u32,
        latched: u32,
        locked: u32,
        group: u32,
    ) void {
        const self: *KeyboardGrab = @ptrCast(@alignCast(context));
        self.resource.sendModifiers(
            serial,
            depressed,
            latched,
            locked,
            group,
        );
    }

    fn sendRepeatInfo(context: *anyopaque, rate: i32, delay: i32) void {
        const self: *KeyboardGrab = @ptrCast(@alignCast(context));
        self.resource.sendRepeatInfo(rate, delay);
    }
};

const InertPopup = struct {
    method: *Method,
    resource: *zwp.InputPopupSurfaceV2,

    fn create(method: *Method, id: u32) error{ OutOfMemory, ResourceCreateFailed }!void {
        const resource = try zwp.InputPopupSurfaceV2.create(
            method.resource.getClient(),
            method.resource.getVersion(),
            id,
        );
        errdefer resource.destroy();
        const self = method.allocator.create(InertPopup) catch return error.OutOfMemory;
        errdefer method.allocator.destroy(self);
        method.inert_popups.append(method.allocator, self) catch return error.OutOfMemory;
        errdefer _ = method.inert_popups.pop();
        self.* = .{ .method = method, .resource = resource };
        resource.setHandler(*InertPopup, handleRequest, handleDestroy, self);
    }

    fn handleRequest(
        resource: *zwp.InputPopupSurfaceV2,
        request: zwp.InputPopupSurfaceV2.Request,
        _: *InertPopup,
    ) void {
        switch (request) {
            .destroy => resource.destroy(),
        }
    }

    fn handleDestroy(_: *zwp.InputPopupSurfaceV2, self: *InertPopup) void {
        for (self.method.inert_popups.items, 0..) |candidate, index| {
            if (candidate != self) continue;
            _ = self.method.inert_popups.orderedRemove(index);
            break;
        }
        self.method.allocator.destroy(self);
    }
};

const Popup = struct {
    method: *Method,
    resource: *zwp.InputPopupSurfaceV2,
    neutral_id: NeutralTextInput.PopupId,
    surface_id: Surface.Id,
    surface: ?*Surface,
    mapped: bool = false,
    position: Position = .{},

    const CreateError = error{ OutOfMemory, ResourceCreateFailed, Role };

    fn create(method: *Method, surface: *Surface, id: u32) CreateError!void {
        if (surface.assignedRole() != null) return error.Role;
        const resource = try zwp.InputPopupSurfaceV2.create(
            method.resource.getClient(),
            method.resource.getVersion(),
            id,
        );
        errdefer resource.destroy();
        const self = method.allocator.create(Popup) catch return error.OutOfMemory;
        errdefer method.allocator.destroy(self);
        surface.reserveRole(.input_popup, .{
            .context = self,
            .before_commit = beforeCommit,
            .after_commit = afterCommit,
            .surface_destroyed = surfaceDestroyed,
        }) catch return error.Role;
        errdefer surface.releaseRole(self);
        const neutral_id = method.manager.owner.createPopup(method.neutral_id, surface.handle()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ResourceCreateFailed,
        };
        errdefer method.manager.owner.destroyPopup(neutral_id);
        method.manager.popups.append(method.allocator, self) catch return error.OutOfMemory;
        errdefer _ = method.manager.popups.pop();
        self.* = .{
            .method = method,
            .resource = resource,
            .neutral_id = neutral_id,
            .surface_id = surface.handle(),
            .surface = surface,
        };
        surface.assignReservedRole(.input_popup, self) catch unreachable;
        resource.setHandler(*Popup, handleRequest, handleDestroy, self);
        self.update(false);
    }

    fn handleRequest(
        resource: *zwp.InputPopupSurfaceV2,
        request: zwp.InputPopupSurfaceV2.Request,
        _: *Popup,
    ) void {
        switch (request) {
            .destroy => resource.destroy(),
        }
    }

    fn handleDestroy(_: *zwp.InputPopupSurfaceV2, self: *Popup) void {
        const manager = self.method.manager;
        const was_mapped = self.mapped;
        if (self.surface) |surface| surface.releaseRole(self);
        manager.owner.destroyPopup(self.neutral_id);
        for (manager.popups.items, 0..) |candidate, index| {
            if (candidate != self) continue;
            _ = manager.popups.orderedRemove(index);
            break;
        }
        self.method.allocator.destroy(self);
        if (was_mapped) manager.layout.repaint(manager.layout.context);
    }

    fn beforeCommit(_: *anyopaque, _: Surface.CommitInfo) Surface.CommitAction {
        return .apply;
    }

    fn afterCommit(context: *anyopaque, _: Surface.CommitInfo) void {
        const self: *Popup = @ptrCast(@alignCast(context));
        self.update(true);
    }

    fn surfaceDestroyed(context: *anyopaque) void {
        const self: *Popup = @ptrCast(@alignCast(context));
        const was_mapped = self.mapped;
        self.surface = null;
        self.mapped = false;
        self.method.manager.owner.destroyPopup(self.neutral_id);
        if (was_mapped) {
            const manager = self.method.manager;
            manager.layout.repaint(manager.layout.context);
        }
    }

    fn update(self: *Popup, content_changed: bool) void {
        const manager = self.method.manager;
        const old_mapped = self.mapped;
        const old_position = self.position;
        if (self.surface == null) {
            self.mapped = false;
            if (old_mapped) manager.layout.repaint(manager.layout.context);
            return;
        }
        const active = manager.owner.activeMethodSnapshot(self.method.neutral_id);
        self.mapped = active != null and
            Surface.currentBuffer(manager.surfaces, self.surface_id) != null;
        if (active) |state| {
            const focus_position = manager.layout.surface_position(
                manager.layout.context,
                state.surface,
            ) orelse Position{};
            const popup_size = Surface.currentLogicalSize(
                manager.surfaces,
                self.surface_id,
            ) orelse render.Size{ .width = 0, .height = 0 };
            const placement = placePopup(
                manager.layout.output_size(manager.layout.context),
                focus_position,
                state.cursor_rectangle,
                popup_size,
            );
            self.position = placement.position;
            self.resource.sendTextInputRectangle(
                placement.rectangle.x,
                placement.rectangle.y,
                placement.rectangle.width,
                placement.rectangle.height,
            );
        }
        if (old_mapped != self.mapped or
            (self.mapped and (!std.meta.eql(old_position, self.position) or content_changed)))
        {
            manager.layout.repaint(manager.layout.context);
        }
    }
};

fn updatePopups(self: *Self) void {
    for (self.popups.items) |popup| popup.update(false);
}

const Placement = struct {
    position: Position,
    rectangle: NeutralTextInput.Rectangle,
};

fn placePopup(
    output: render.Size,
    focus: Position,
    maybe_rectangle: ?NeutralTextInput.Rectangle,
    popup: render.Size,
) Placement {
    const rectangle = maybe_rectangle orelse NeutralTextInput.Rectangle{
        .x = 0,
        .y = 0,
        .width = 0,
        .height = 0,
    };
    const left = @as(i64, focus.x) + rectangle.x;
    const top = @as(i64, focus.y) + rectangle.y;
    const right = left + rectangle.width;
    const bottom = top + rectangle.height;
    const output_width: i64 = output.width;
    const output_height: i64 = output.height;
    const popup_width: i64 = popup.width;
    const popup_height: i64 = popup.height;
    const max_x = @max(output_width - popup_width, 0);
    const max_y = @max(output_height - popup_height, 0);
    const desired_x = if (left + popup_width <= output_width) left else right - popup_width;
    const desired_y = if (bottom + popup_height <= output_height) bottom else top - popup_height;
    const x: i32 = @intCast(std.math.clamp(desired_x, 0, max_x));
    const y: i32 = @intCast(std.math.clamp(desired_y, 0, max_y));
    return .{
        .position = .{ .x = x, .y = y },
        .rectangle = .{
            .x = saturatingI32(left - x),
            .y = saturatingI32(top - y),
            .width = rectangle.width,
            .height = rectangle.height,
        },
    };
}

fn saturatingI32(value: i64) i32 {
    return @intCast(std.math.clamp(value, std.math.minInt(i32), std.math.maxInt(i32)));
}

fn validText(text: []const u8) bool {
    return text.len <= 4000 and std.unicode.utf8ValidateSlice(text);
}

fn validPreeditCursor(text: []const u8, begin: i32, end: i32) bool {
    if (begin == -1 or end == -1) return begin == -1 and end == -1;
    if (begin < 0 or end < 0) return false;
    return validUtf8Index(text, @intCast(begin)) and validUtf8Index(text, @intCast(end));
}

fn validUtf8Index(text: []const u8, index: usize) bool {
    if (index > text.len) return false;
    return index == text.len or text[index] & 0xc0 != 0x80;
}

test "popup placement flips at output edges and reports popup-local cursor" {
    const placement = placePopup(
        .{ .width = 800, .height = 600 },
        .{ .x = 700, .y = 500 },
        .{ .x = 10, .y = 10, .width = 20, .height = 20 },
        .{ .width = 200, .height = 100 },
    );
    try std.testing.expectEqual(Position{ .x = 530, .y = 410 }, placement.position);
    try std.testing.expectEqual(NeutralTextInput.Rectangle{
        .x = 180,
        .y = 100,
        .width = 20,
        .height = 20,
    }, placement.rectangle);
}

test "input method validates UTF-8 edit boundaries" {
    const text = "aéz";
    try std.testing.expect(validPreeditCursor(text, 1, 3));
    try std.testing.expect(!validPreeditCursor(text, 2, 3));
    try std.testing.expect(validPreeditCursor(text, -1, -1));
    try std.testing.expect(!validPreeditCursor(text, -1, 0));
}
