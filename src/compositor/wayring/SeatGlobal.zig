//! Native `wl_seat` policy and transport-independent input delivery.

const SeatGlobal = @This();

const std = @import("std");
const linux = std.os.linux;
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const CompositorGlobal = @import("CompositorGlobal.zig");

const advertised_version: u32 = 10;

allocator: std.mem.Allocator,
server: *Server,
global_name: u32,
name: []const u8,
capabilities: u32,
bindings: std.ArrayList(*Binding) = .empty,
children: std.ArrayList(*Child) = .empty,
pointer_focus: ?*CompositorGlobal.Surface = null,
keyboard_focus: ?*CompositorGlobal.Surface = null,
touch_focus: ?*CompositorGlobal.Surface = null,
cursor_handler: ?CursorHandler = null,

pub const Capability = generated.wl_seat_types.capability;

pub const CursorIntent = struct {
    client: *Server.Client,
    pointer: wayring.ObjectHandle,
    serial: u32,
    surface: ?*CompositorGlobal.Surface,
    hotspot_x: i32,
    hotspot_y: i32,
};

pub const CursorHandler = struct {
    context: *anyopaque,
    handle: *const fn (*anyopaque, CursorIntent) anyerror!void,
};

pub const AxisFrame = struct {
    time_milliseconds: u32,
    axis: u32,
    value: ?i32 = null,
    source: ?u32 = null,
    stopped: bool = false,
    discrete: ?i32 = null,
    value120: ?i32 = null,
};

const Binding = struct {
    owner: *SeatGlobal,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
};

const ChildKind = enum { pointer, keyboard, touch };

const Child = struct {
    owner: *SeatGlobal,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    kind: ChildKind,
};

pub fn init(
    self: *SeatGlobal,
    allocator: std.mem.Allocator,
    server: *Server,
    name: []const u8,
    capabilities: u32,
    cursor_handler: ?CursorHandler,
) !void {
    self.* = .{
        .allocator = allocator,
        .server = server,
        .global_name = undefined,
        .name = name,
        .capabilities = capabilities,
        .cursor_handler = cursor_handler,
    };
    self.global_name = try server.createGlobal(&generated.wl_seat, advertised_version, .{
        .context = self,
        .bind = bind,
    });
}

pub fn deinit(self: *SeatGlobal) void {
    std.debug.assert(self.bindings.items.len == 0);
    std.debug.assert(self.children.items.len == 0);
    clearFocus(&self.pointer_focus);
    clearFocus(&self.keyboard_focus);
    clearFocus(&self.touch_focus);
    self.server.removeGlobal(self.global_name) catch unreachable;
    self.children.deinit(self.allocator);
    self.bindings.deinit(self.allocator);
    self.* = undefined;
}

pub fn setCapabilities(self: *SeatGlobal, capabilities: u32) !void {
    if (self.capabilities == capabilities) return;
    const removed = self.capabilities & ~capabilities;
    if (removed & Capability.pointer != 0) _ = try self.pointerLeave();
    if (removed & Capability.keyboard != 0) _ = try self.keyboardLeave();
    if (removed & Capability.touch != 0) try self.touchCancel();
    self.capabilities = capabilities;
    for (self.bindings.items) |binding| try generated.wl_seat_types.events.capabilities(
        &binding.client.connection,
        binding.resource,
        capabilities,
    );
}

pub fn pointerEnter(self: *SeatGlobal, surface: *CompositorGlobal.Surface, x: i32, y: i32) !u32 {
    if (self.pointer_focus != null and self.pointer_focus != surface)
        _ = try self.pointerLeave();
    try setFocus(&self.pointer_focus, surface);
    const serial = self.server.nextSerial();
    for (self.children.items) |child| if (matches(child, .pointer, surface))
        try generated.wl_pointer_types.events.enter(&child.client.connection, child.resource, serial, surface.resource, x, y);
    return serial;
}

pub fn pointerLeave(self: *SeatGlobal) !?u32 {
    const surface = self.pointer_focus orelse return null;
    const serial = self.server.nextSerial();
    for (self.children.items) |child| if (matches(child, .pointer, surface))
        try generated.wl_pointer_types.events.leave(&child.client.connection, child.resource, serial, surface.resource);
    clearFocus(&self.pointer_focus);
    return serial;
}

pub fn pointerMotion(self: *SeatGlobal, time: u32, x: i32, y: i32) !void {
    const surface = self.pointer_focus orelse return;
    for (self.children.items) |child| if (matches(child, .pointer, surface))
        try generated.wl_pointer_types.events.motion(&child.client.connection, child.resource, time, x, y);
}

pub fn pointerButton(self: *SeatGlobal, time: u32, button: u32, state: u32) !?u32 {
    const surface = self.pointer_focus orelse return null;
    const serial = self.server.nextSerial();
    for (self.children.items) |child| if (matches(child, .pointer, surface))
        try generated.wl_pointer_types.events.button(&child.client.connection, child.resource, serial, time, button, state);
    return serial;
}

/// Delivers one logical axis frame. Fixed-point values use Wayland's 24.8 representation.
pub fn pointerAxisFrame(self: *SeatGlobal, frame: AxisFrame) !void {
    const surface = self.pointer_focus orelse return;
    for (self.children.items) |child| {
        if (!matches(child, .pointer, surface)) continue;
        const version = try child.client.resourceVersion(child.resource, &generated.wl_pointer);
        if (version >= 5) {
            if (frame.source) |source| try generated.wl_pointer_types.events.axis_source(&child.client.connection, child.resource, source);
        }
        if (frame.value) |value| try generated.wl_pointer_types.events.axis(&child.client.connection, child.resource, frame.time_milliseconds, frame.axis, value);
        if (version >= 5) {
            if (frame.discrete) |value| try generated.wl_pointer_types.events.axis_discrete(&child.client.connection, child.resource, frame.axis, value);
            if (frame.stopped) try generated.wl_pointer_types.events.axis_stop(&child.client.connection, child.resource, frame.time_milliseconds, frame.axis);
        }
        if (version >= 8) if (frame.value120) |value| try generated.wl_pointer_types.events.axis_value120(&child.client.connection, child.resource, frame.axis, value);
        if (version >= 5) try generated.wl_pointer_types.events.frame(&child.client.connection, child.resource);
    }
}

/// Queues a keymap for every keyboard resource. On each successful queue call,
/// Wayring owns that descriptor and closes it after the output batch is acknowledged.
/// Callers must therefore pass a separately duplicated descriptor for each resource.
pub fn keyboardKeymap(self: *SeatGlobal, format: u32, fd_for: *const fn (*Server.Client) anyerror!i32, size: u32) !void {
    for (self.children.items) |child| {
        if (child.kind != .keyboard) continue;
        const fd = try fd_for(child.client);
        var fd_owned = true;
        defer if (fd_owned) {
            _ = linux.close(fd);
        };
        try generated.wl_keyboard_types.events.keymap(&child.client.connection, child.resource, format, fd, size);
        fd_owned = false;
    }
}

pub fn keyboardEnter(self: *SeatGlobal, surface: *CompositorGlobal.Surface, keys: []const u8) !u32 {
    if (self.keyboard_focus != null and self.keyboard_focus != surface)
        _ = try self.keyboardLeave();
    try setFocus(&self.keyboard_focus, surface);
    const serial = self.server.nextSerial();
    for (self.children.items) |child| if (matches(child, .keyboard, surface))
        try generated.wl_keyboard_types.events.enter(&child.client.connection, child.resource, serial, surface.resource, keys);
    return serial;
}

pub fn keyboardLeave(self: *SeatGlobal) !?u32 {
    const surface = self.keyboard_focus orelse return null;
    const serial = self.server.nextSerial();
    for (self.children.items) |child| if (matches(child, .keyboard, surface))
        try generated.wl_keyboard_types.events.leave(&child.client.connection, child.resource, serial, surface.resource);
    clearFocus(&self.keyboard_focus);
    return serial;
}

pub fn keyboardKey(self: *SeatGlobal, time: u32, key: u32, state: u32) !?u32 {
    const surface = self.keyboard_focus orelse return null;
    const serial = self.server.nextSerial();
    for (self.children.items) |child| if (matches(child, .keyboard, surface))
        try generated.wl_keyboard_types.events.key(&child.client.connection, child.resource, serial, time, key, state);
    return serial;
}

pub fn keyboardModifiers(self: *SeatGlobal, serial: u32, depressed: u32, latched: u32, locked: u32, group: u32) !void {
    const surface = self.keyboard_focus orelse return;
    for (self.children.items) |child| if (matches(child, .keyboard, surface))
        try generated.wl_keyboard_types.events.modifiers(&child.client.connection, child.resource, serial, depressed, latched, locked, group);
}

pub fn keyboardRepeatInfo(self: *SeatGlobal, rate: i32, delay: i32) !void {
    for (self.children.items) |child| {
        if (child.kind != .keyboard) continue;
        if (try child.client.resourceVersion(child.resource, &generated.wl_keyboard) >= 4)
            try generated.wl_keyboard_types.events.repeat_info(&child.client.connection, child.resource, rate, delay);
    }
}

pub fn touchDown(self: *SeatGlobal, surface: *CompositorGlobal.Surface, time: u32, id: i32, x: i32, y: i32) !u32 {
    if (self.touch_focus != null and self.touch_focus != surface)
        try self.touchCancel();
    try setFocus(&self.touch_focus, surface);
    const serial = self.server.nextSerial();
    for (self.children.items) |child| if (matches(child, .touch, surface))
        try generated.wl_touch_types.events.down(&child.client.connection, child.resource, serial, time, surface.resource, id, x, y);
    return serial;
}

pub fn touchUp(self: *SeatGlobal, time: u32, id: i32) !?u32 {
    const surface = self.touch_focus orelse return null;
    const serial = self.server.nextSerial();
    for (self.children.items) |child| if (matches(child, .touch, surface))
        try generated.wl_touch_types.events.up(&child.client.connection, child.resource, serial, time, id);
    return serial;
}

pub fn touchMotion(self: *SeatGlobal, time: u32, id: i32, x: i32, y: i32) !void {
    const surface = self.touch_focus orelse return;
    for (self.children.items) |child| if (matches(child, .touch, surface))
        try generated.wl_touch_types.events.motion(&child.client.connection, child.resource, time, id, x, y);
}

pub fn touchFrame(self: *SeatGlobal) !void {
    try touchSimple(self, .frame);
}
pub fn touchCancel(self: *SeatGlobal) !void {
    try touchSimple(self, .cancel);
    clearFocus(&self.touch_focus);
}

pub fn touchShape(self: *SeatGlobal, id: i32, major: i32, minor: i32) !void {
    const surface = self.touch_focus orelse return;
    for (self.children.items) |child| if (matches(child, .touch, surface) and
        try child.client.resourceVersion(child.resource, &generated.wl_touch) >= 6)
        try generated.wl_touch_types.events.shape(&child.client.connection, child.resource, id, major, minor);
}

pub fn touchOrientation(self: *SeatGlobal, id: i32, orientation: i32) !void {
    const surface = self.touch_focus orelse return;
    for (self.children.items) |child| if (matches(child, .touch, surface) and
        try child.client.resourceVersion(child.resource, &generated.wl_touch) >= 6)
        try generated.wl_touch_types.events.orientation(&child.client.connection, child.resource, id, orientation);
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *SeatGlobal = @ptrCast(@alignCast(context));
    const binding = self.allocator.create(Binding) catch return client.postNoMemory();
    errdefer self.allocator.destroy(binding);
    self.bindings.ensureUnusedCapacity(self.allocator, 1) catch return client.postNoMemory();
    binding.* = .{ .owner = self, .client = client, .resource = undefined };
    binding.resource = client.createResource(id, &generated.wl_seat, version, .{
        .context = binding,
        .dispatch = dispatchSeat,
        .destroy = destroyBinding,
    }) catch return client.postNoMemory();
    self.bindings.appendAssumeCapacity(binding);
    try generated.wl_seat_types.events.capabilities(&client.connection, binding.resource, self.capabilities);
    if (version >= 2) try generated.wl_seat_types.events.name(&client.connection, binding.resource, self.name);
}

fn dispatchSeat(context: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    const binding: *Binding = @ptrCast(@alignCast(context));
    switch (try generated.wl_seat_types.decodeRequest(&client.connection, resource, message)) {
        .get_pointer => |r| try binding.owner.createChild(client, resource, r.id, .pointer),
        .get_keyboard => |r| try binding.owner.createChild(client, resource, r.id, .keyboard),
        .get_touch => |r| try binding.owner.createChild(client, resource, r.id, .touch),
        .release => {},
    }
}

fn createChild(self: *SeatGlobal, client: *Server.Client, seat: wayring.ObjectHandle, id: u32, kind: ChildKind) !void {
    const capability: u32 = switch (kind) {
        .pointer => Capability.pointer,
        .keyboard => Capability.keyboard,
        .touch => Capability.touch,
    };
    if (self.capabilities & capability == 0) return client.postError(seat, @intFromEnum(generated.wl_seat_types.@"error".missing_capability), "requested wl_seat capability is unavailable");
    const child = self.allocator.create(Child) catch return client.postNoMemory();
    errdefer self.allocator.destroy(child);
    self.children.ensureUnusedCapacity(self.allocator, 1) catch return client.postNoMemory();
    const interface = switch (kind) {
        .pointer => &generated.wl_pointer,
        .keyboard => &generated.wl_keyboard,
        .touch => &generated.wl_touch,
    };
    const version = @min(try client.resourceVersion(seat, &generated.wl_seat), interface.version);
    child.* = .{ .owner = self, .client = client, .resource = undefined, .kind = kind };
    child.resource = client.createResource(id, interface, version, .{
        .context = child,
        .dispatch = switch (kind) {
            .pointer => dispatchPointer,
            .keyboard => dispatchKeyboard,
            .touch => dispatchTouch,
        },
        .destroy = destroyChild,
    }) catch return client.postNoMemory();
    self.children.appendAssumeCapacity(child);
}

fn dispatchPointer(context: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    const child: *Child = @ptrCast(@alignCast(context));
    switch (try generated.wl_pointer_types.decodeRequest(&client.connection, resource, message)) {
        .set_cursor => |r| {
            const surface = if (r.surface) |id| blk: {
                const object = client.connection.object(id) orelse return error.UnknownSurface;
                break :blk try CompositorGlobal.surfaceFor(client, .{ .id = id, .generation = object.generation });
            } else null;
            if (child.owner.cursor_handler) |handler| try handler.handle(handler.context, .{
                .client = client,
                .pointer = resource,
                .serial = r.serial,
                .surface = surface,
                .hotspot_x = r.hotspot_x,
                .hotspot_y = r.hotspot_y,
            });
        },
        .release => {},
    }
}

fn dispatchKeyboard(_: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    _ = try generated.wl_keyboard_types.decodeRequest(&client.connection, resource, message);
}
fn dispatchTouch(_: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    _ = try generated.wl_touch_types.decodeRequest(&client.connection, resource, message);
}

fn destroyBinding(context: *anyopaque, _: *Server.Client, _: wayring.ObjectHandle) void {
    const binding: *Binding = @ptrCast(@alignCast(context));
    removeOwned(Binding, binding.owner.allocator, &binding.owner.bindings, binding);
}
fn destroyChild(context: *anyopaque, _: *Server.Client, _: wayring.ObjectHandle) void {
    const child: *Child = @ptrCast(@alignCast(context));
    removeOwned(Child, child.owner.allocator, &child.owner.children, child);
}

fn removeOwned(comptime T: type, allocator: std.mem.Allocator, list: *std.ArrayList(*T), item: *T) void {
    for (list.items, 0..) |candidate, index| if (candidate == item) {
        _ = list.orderedRemove(index);
        allocator.destroy(item);
        return;
    };
    unreachable;
}

fn matches(child: *const Child, kind: ChildKind, surface: *const CompositorGlobal.Surface) bool {
    return child.kind == kind and child.client == surface.client and surface.resource_alive;
}

fn setFocus(slot: *?*CompositorGlobal.Surface, surface: *CompositorGlobal.Surface) !void {
    if (slot.* == surface) return;
    try surface.reference();
    clearFocus(slot);
    slot.* = surface;
}
fn clearFocus(slot: *?*CompositorGlobal.Surface) void {
    if (slot.*) |surface| surface.unreference();
    slot.* = null;
}

const TouchSimple = enum { frame, cancel };
fn touchSimple(self: *SeatGlobal, event: TouchSimple) !void {
    const surface = self.touch_focus orelse return;
    for (self.children.items) |child| if (matches(child, .touch, surface)) switch (event) {
        .frame => try generated.wl_touch_types.events.frame(&child.client.connection, child.resource),
        .cancel => try generated.wl_touch_types.events.cancel(&child.client.connection, child.resource),
    };
}

test "seat capability constants match core protocol" {
    try std.testing.expectEqual(@as(u32, 1), Capability.pointer);
    try std.testing.expectEqual(@as(u32, 2), Capability.keyboard);
    try std.testing.expectEqual(@as(u32, 4), Capability.touch);
}

test "native seat binds child resources and routes focused input" {
    const core = @import("wayring-core");
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var compositor: CompositorGlobal = undefined;
    try compositor.init(std.testing.allocator, &server);
    defer compositor.deinit();
    var seat: SeatGlobal = undefined;
    try seat.init(
        std.testing.allocator,
        &server,
        "default",
        Capability.pointer | Capability.keyboard,
        null,
    );
    defer seat.deinit();
    const client = try server.createClient();
    defer server.destroyClient(client) catch unreachable;

    var peer = wayring.Connection.init(
        std.testing.allocator,
        .client,
        wayring.default_max_frame_size,
    );
    defer peer.deinit();
    _ = try core.bootstrapDisplay(&peer);
    const registry: wayring.ObjectHandle = .{
        .id = 2,
        .generation = try core.getRegistry(&peer, 2),
    };
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    var compositor_name: u32 = 0;
    var seat_name: u32 = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const event = try core.decodeRegistryEvent(&message, registry.id);
        if (event != .global) continue;
        if (std.mem.eql(u8, event.global.interface, generated.wl_compositor.name))
            compositor_name = event.global.name;
        if (std.mem.eql(u8, event.global.interface, generated.wl_seat.name))
            seat_name = event.global.name;
    }
    const compositor_resource: wayring.ObjectHandle = .{
        .id = 3,
        .generation = try core.bind(
            &peer,
            registry.id,
            compositor_name,
            generated.wl_compositor.name,
            6,
            3,
            &generated.wl_compositor,
        ),
    };
    const seat_resource: wayring.ObjectHandle = .{
        .id = 4,
        .generation = try core.bind(
            &peer,
            registry.id,
            seat_name,
            generated.wl_seat.name,
            10,
            4,
            &generated.wl_seat,
        ),
    };
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    var got_capabilities = false;
    var got_name = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        switch (try generated.wl_seat_types.decodeEvent(&peer, seat_resource, &message)) {
            .capabilities => |event| got_capabilities = event.capabilities ==
                Capability.pointer | Capability.keyboard,
            .name => |event| got_name = std.mem.eql(u8, event.name, "default"),
        }
    }
    try std.testing.expect(got_capabilities);
    try std.testing.expect(got_name);

    const surface_handle = try generated.wl_compositor_types.requests.create_surface(
        &peer,
        compositor_resource,
    );
    const pointer = try generated.wl_seat_types.requests.get_pointer(&peer, seat_resource);
    const keyboard = try generated.wl_seat_types.requests.get_keyboard(&peer, seat_resource);
    try transferToServer(&peer, client);
    const surface = try CompositorGlobal.surfaceFor(client, .{
        .id = surface_handle.id,
        .generation = client.connection.object(surface_handle.id).?.generation,
    });
    _ = try seat.pointerEnter(surface, 3 * 256, 4 * 256);
    try seat.pointerMotion(11, 5 * 256, 6 * 256);
    _ = try seat.pointerButton(
        12,
        0x110,
        @intFromEnum(generated.wl_pointer_types.button_state.pressed),
    );
    _ = try seat.keyboardEnter(surface, &.{});
    _ = try seat.keyboardKey(
        13,
        30,
        @intFromEnum(generated.wl_keyboard_types.key_state.pressed),
    );
    try transferFromServer(&peer, client);

    var pointer_events: usize = 0;
    var keyboard_events: usize = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == pointer.id) {
            _ = try generated.wl_pointer_types.decodeEvent(&peer, pointer, &message);
            pointer_events += 1;
        } else if (message.object_id == keyboard.id) {
            _ = try generated.wl_keyboard_types.decodeEvent(&peer, keyboard, &message);
            keyboard_events += 1;
        } else return error.UnexpectedSeatEvent;
    }
    try std.testing.expectEqual(@as(usize, 3), pointer_events);
    try std.testing.expectEqual(@as(usize, 2), keyboard_events);
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
