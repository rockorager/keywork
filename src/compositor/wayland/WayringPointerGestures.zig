//! Scanner-backed pointer-gestures unstable-v1 adapter.

const Self = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayring = @import("wayring");
const ClientRegistry = @import("../ClientRegistry.zig");
const CompositorServer = @import("../server.zig");
const SurfaceRegistry = @import("../SurfaceRegistry.zig");
const WayringCompositor = @import("WayringCompositor.zig");
const WayringSeatAdapter = @import("WayringSeatAdapter.zig");

const server = wayring.server;

const Manager = struct { owner: *Self, client: *server.Client, resource: protocol.zwp_pointer_gestures_v1.Resource };
const Binding = struct {
    client: *server.Client,
    pointer_object_id: u32,
    identity: WayringSeatAdapter.PointerIdentity,
    active: bool = false,
};
const Swipe = struct { owner: *Self, binding: Binding, resource: protocol.zwp_pointer_gesture_swipe_v1.Resource };
const Pinch = struct { owner: *Self, binding: Binding, resource: protocol.zwp_pointer_gesture_pinch_v1.Resource };
const Hold = struct { owner: *Self, binding: Binding, resource: protocol.zwp_pointer_gesture_hold_v1.Resource };

allocator: std.mem.Allocator,
protocol_server: *server.Server,
seat: *WayringSeatAdapter,
compositor: *WayringCompositor,
global: ?*const server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
swipes: std.ArrayList(*Swipe) = .empty,
pinches: std.ArrayList(*Pinch) = .empty,
holds: std.ArrayList(*Hold) = .empty,

pub fn init(self: *Self, allocator: std.mem.Allocator, protocol_server: *server.Server, seat: *WayringSeatAdapter, compositor: *WayringCompositor) void {
    self.* = .{ .allocator = allocator, .protocol_server = protocol_server, .seat = seat, .compositor = compositor };
}
pub fn publish(self: *Self) !void {
    self.global = try self.protocol_server.addGlobal(protocol.zwp_pointer_gestures_v1, 3, Self, self, bind);
}
pub fn unpublish(self: *Self) void {
    self.protocol_server.removeGlobal(self.global orelse unreachable) catch {};
    self.global = null;
}
pub fn deinit(self: *Self) void {
    std.debug.assert(self.global == null and self.managers.items.len == 0 and self.swipes.items.len == 0 and self.pinches.items.len == 0 and self.holds.items.len == 0);
    self.holds.deinit(self.allocator);
    self.pinches.deinit(self.allocator);
    self.swipes.deinit(self.allocator);
    self.managers.deinit(self.allocator);
    self.* = undefined;
}
pub fn observer(self: *Self) CompositorServer.GeneratedPointerGestureObserver {
    return .{ .context = self, .begin = begin, .update = update, .end = end };
}

fn bind(client: *server.Client, id: u32, version: u32, self: *Self) !void {
    if (version == 0 or version > 3) return error.InvalidVersion;
    try self.managers.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Manager);
    errdefer self.allocator.destroy(value);
    value.* = .{ .owner = self, .client = client, .resource = .init(self.allocator, id, version, .client, client.ownerHooks()) };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Manager, value, managerRequest, null);
    try client.materialize(&value.resource.runtime);
    self.managers.appendAssumeCapacity(value);
}
fn managerRequest(_: *protocol.zwp_pointer_gestures_v1.Resource, request: protocol.zwp_pointer_gestures_v1.Request, manager: *Manager) !void {
    switch (request) {
        .release => manager.owner.destroyManager(manager),
        .get_swipe_gesture => |args| try manager.owner.createSwipe(manager, args.id, args.pointer),
        .get_pinch_gesture => |args| try manager.owner.createPinch(manager, args.id, args.pointer),
        .get_hold_gesture => |args| try manager.owner.createHold(manager, args.id, args.pointer),
    }
}
fn binding(self: *Self, manager: *Manager, pointer: u32) ?Binding {
    const identity = self.seat.pointerIdentityIncludingInactive(manager.client, pointer) orelse {
        manager.client.postImplementationError(&manager.resource.runtime, "pointer gesture requires the exact live same-client generated wl_pointer");
        return null;
    };
    return .{ .client = manager.client, .pointer_object_id = pointer, .identity = identity };
}
fn createSwipe(self: *Self, manager: *Manager, id: u32, pointer: u32) !void {
    const linked = self.binding(manager, pointer) orelse return;
    try self.swipes.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Swipe);
    errdefer self.allocator.destroy(value);
    value.* = .{ .owner = self, .binding = linked, .resource = .init(self.allocator, id, manager.resource.version(), .client, manager.client.ownerHooks()) };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Swipe, value, swipeRequest, null);
    try manager.client.materialize(&value.resource.runtime);
    self.swipes.appendAssumeCapacity(value);
}
fn createPinch(self: *Self, manager: *Manager, id: u32, pointer: u32) !void {
    const linked = self.binding(manager, pointer) orelse return;
    try self.pinches.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Pinch);
    errdefer self.allocator.destroy(value);
    value.* = .{ .owner = self, .binding = linked, .resource = .init(self.allocator, id, manager.resource.version(), .client, manager.client.ownerHooks()) };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Pinch, value, pinchRequest, null);
    try manager.client.materialize(&value.resource.runtime);
    self.pinches.appendAssumeCapacity(value);
}
fn createHold(self: *Self, manager: *Manager, id: u32, pointer: u32) !void {
    const linked = self.binding(manager, pointer) orelse return;
    try self.holds.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Hold);
    errdefer self.allocator.destroy(value);
    value.* = .{ .owner = self, .binding = linked, .resource = .init(self.allocator, id, manager.resource.version(), .client, manager.client.ownerHooks()) };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Hold, value, holdRequest, null);
    try manager.client.materialize(&value.resource.runtime);
    self.holds.appendAssumeCapacity(value);
}
fn swipeRequest(_: *protocol.zwp_pointer_gesture_swipe_v1.Resource, _: protocol.zwp_pointer_gesture_swipe_v1.Request, value: *Swipe) !void {
    value.owner.destroySwipe(value);
}
fn pinchRequest(_: *protocol.zwp_pointer_gesture_pinch_v1.Resource, _: protocol.zwp_pointer_gesture_pinch_v1.Request, value: *Pinch) !void {
    value.owner.destroyPinch(value);
}
fn holdRequest(_: *protocol.zwp_pointer_gesture_hold_v1.Resource, _: protocol.zwp_pointer_gesture_hold_v1.Request, value: *Hold) !void {
    value.owner.destroyHold(value);
}

fn active(self: *Self, value: *const Binding) bool {
    const current = self.seat.pointerIdentity(value.client, value.pointer_object_id) orelse return false;
    return std.meta.eql(current, value.identity);
}
fn begin(context: *anyopaque, kind: CompositorServer.GestureKind, client: ClientRegistry.Id, surface: SurfaceRegistry.Id, time: u32, fingers: u32) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const endpoint = self.compositor.surfaceEndpoint(surface) orelse return;
    const serial = self.protocol_server.nextSerial() catch {
        self.beginSerialExhausted(kind, client, endpoint.client);
        return;
    };
    switch (kind) {
        .swipe => for (self.swipes.items) |value| if (std.meta.eql(value.binding.identity.client, client) and value.binding.client == endpoint.client and self.active(&value.binding)) {
            if (value.binding.active) protocol.zwp_pointer_gesture_swipe_v1.@"send:end"(&value.resource, serial, time, 1) catch |err| eventFailure(&value.binding, &value.resource.runtime, err);
            value.binding.active = true;
            protocol.zwp_pointer_gesture_swipe_v1.@"send:begin"(&value.resource, serial, time, endpoint.resource.id(), fingers) catch |err| eventFailure(&value.binding, &value.resource.runtime, err);
        },
        .pinch => for (self.pinches.items) |value| if (std.meta.eql(value.binding.identity.client, client) and value.binding.client == endpoint.client and self.active(&value.binding)) {
            if (value.binding.active) protocol.zwp_pointer_gesture_pinch_v1.@"send:end"(&value.resource, serial, time, 1) catch |err| eventFailure(&value.binding, &value.resource.runtime, err);
            value.binding.active = true;
            protocol.zwp_pointer_gesture_pinch_v1.@"send:begin"(&value.resource, serial, time, endpoint.resource.id(), fingers) catch |err| eventFailure(&value.binding, &value.resource.runtime, err);
        },
        .hold => for (self.holds.items) |value| if (std.meta.eql(value.binding.identity.client, client) and value.binding.client == endpoint.client and self.active(&value.binding)) {
            if (value.binding.active) protocol.zwp_pointer_gesture_hold_v1.@"send:end"(&value.resource, serial, time, 1) catch |err| eventFailure(&value.binding, &value.resource.runtime, err);
            value.binding.active = true;
            protocol.zwp_pointer_gesture_hold_v1.@"send:begin"(&value.resource, serial, time, endpoint.resource.id(), fingers) catch |err| eventFailure(&value.binding, &value.resource.runtime, err);
        },
    }
}
fn update(context: *anyopaque, kind: CompositorServer.GestureKind, time: u32, dx: f64, dy: f64, scale: f64, rotation: f64) void {
    const self: *Self = @ptrCast(@alignCast(context));
    switch (kind) {
        .swipe => for (self.swipes.items) |value| if (value.binding.active and self.active(&value.binding)) protocol.zwp_pointer_gesture_swipe_v1.@"send:update"(&value.resource, time, fixed(dx), fixed(dy)) catch |err| eventFailure(&value.binding, &value.resource.runtime, err),
        .pinch => for (self.pinches.items) |value| if (value.binding.active and self.active(&value.binding)) protocol.zwp_pointer_gesture_pinch_v1.@"send:update"(&value.resource, time, fixed(dx), fixed(dy), fixed(scale), fixed(rotation)) catch |err| eventFailure(&value.binding, &value.resource.runtime, err),
        .hold => {},
    }
}
fn end(context: *anyopaque, kind: CompositorServer.GestureKind, time: u32, cancelled: bool) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const serial = self.protocol_server.nextSerial() catch {
        self.endSerialExhausted(kind);
        return;
    };
    switch (kind) {
        .swipe => for (self.swipes.items) |value| if (value.binding.active and self.active(&value.binding)) {
            value.binding.active = false;
            protocol.zwp_pointer_gesture_swipe_v1.@"send:end"(&value.resource, serial, time, @intFromBool(cancelled)) catch |err| eventFailure(&value.binding, &value.resource.runtime, err);
        },
        .pinch => for (self.pinches.items) |value| if (value.binding.active and self.active(&value.binding)) {
            value.binding.active = false;
            protocol.zwp_pointer_gesture_pinch_v1.@"send:end"(&value.resource, serial, time, @intFromBool(cancelled)) catch |err| eventFailure(&value.binding, &value.resource.runtime, err);
        },
        .hold => for (self.holds.items) |value| if (value.binding.active and self.active(&value.binding)) {
            value.binding.active = false;
            protocol.zwp_pointer_gesture_hold_v1.@"send:end"(&value.resource, serial, time, @intFromBool(cancelled)) catch |err| eventFailure(&value.binding, &value.resource.runtime, err);
        },
    }
}

fn beginSerialExhausted(self: *Self, kind: CompositorServer.GestureKind, client: ClientRegistry.Id, raw_client: *server.Client) void {
    switch (kind) {
        .swipe => for (self.swipes.items) |value| if (value.binding.client == raw_client and std.meta.eql(value.binding.identity.client, client) and self.active(&value.binding)) {
            value.binding.active = false;
            value.binding.client.postImplementationError(&value.resource.runtime, "generated pointer gesture serial exhausted");
        },
        .pinch => for (self.pinches.items) |value| if (value.binding.client == raw_client and std.meta.eql(value.binding.identity.client, client) and self.active(&value.binding)) {
            value.binding.active = false;
            value.binding.client.postImplementationError(&value.resource.runtime, "generated pointer gesture serial exhausted");
        },
        .hold => for (self.holds.items) |value| if (value.binding.client == raw_client and std.meta.eql(value.binding.identity.client, client) and self.active(&value.binding)) {
            value.binding.active = false;
            value.binding.client.postImplementationError(&value.resource.runtime, "generated pointer gesture serial exhausted");
        },
    }
}

fn endSerialExhausted(self: *Self, kind: CompositorServer.GestureKind) void {
    switch (kind) {
        .swipe => for (self.swipes.items) |value| if (value.binding.active and self.active(&value.binding)) {
            value.binding.active = false;
            value.binding.client.postImplementationError(&value.resource.runtime, "generated pointer gesture serial exhausted");
        },
        .pinch => for (self.pinches.items) |value| if (value.binding.active and self.active(&value.binding)) {
            value.binding.active = false;
            value.binding.client.postImplementationError(&value.resource.runtime, "generated pointer gesture serial exhausted");
        },
        .hold => for (self.holds.items) |value| if (value.binding.active and self.active(&value.binding)) {
            value.binding.active = false;
            value.binding.client.postImplementationError(&value.resource.runtime, "generated pointer gesture serial exhausted");
        },
    }
}

fn eventFailure(binding_value: *const Binding, resource: *server.Resource, err: anyerror) void {
    switch (err) {
        error.OutOfMemory, error.WriteFailed => binding_value.client.postOutOfMemory(resource, "sending pointer gesture event"),
        error.OutputSealed, error.ClientFatal => {},
        else => binding_value.client.postImplementationError(resource, "sending pointer gesture event"),
    }
}

pub fn destroyClientResources(self: *Self, client: *server.Client) void {
    var i = self.swipes.items.len;
    while (i > 0) {
        i -= 1;
        if (self.swipes.items[i].binding.client == client) self.destroySwipe(self.swipes.items[i]);
    }
    i = self.pinches.items.len;
    while (i > 0) {
        i -= 1;
        if (self.pinches.items[i].binding.client == client) self.destroyPinch(self.pinches.items[i]);
    }
    i = self.holds.items.len;
    while (i > 0) {
        i -= 1;
        if (self.holds.items[i].binding.client == client) self.destroyHold(self.holds.items[i]);
    }
    i = self.managers.items.len;
    while (i > 0) {
        i -= 1;
        if (self.managers.items[i].client == client) self.destroyManager(self.managers.items[i]);
    }
}
fn destroyManager(self: *Self, value: *Manager) void {
    remove(Manager, &self.managers, value);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}
fn destroySwipe(self: *Self, value: *Swipe) void {
    remove(Swipe, &self.swipes, value);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}
fn destroyPinch(self: *Self, value: *Pinch) void {
    remove(Pinch, &self.pinches, value);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}
fn destroyHold(self: *Self, value: *Hold) void {
    remove(Hold, &self.holds, value);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}
fn remove(comptime T: type, list: *std.ArrayList(*T), value: *T) void {
    for (list.items, 0..) |candidate, i| if (candidate == value) {
        _ = list.swapRemove(i);
        return;
    };
    unreachable;
}
fn fixed(value: f64) i32 {
    std.debug.assert(std.math.isFinite(value));
    const minimum = @as(f64, @floatFromInt(std.math.minInt(i32))) / 256.0;
    const maximum = @as(f64, @floatFromInt(std.math.maxInt(i32))) / 256.0;
    return @intFromFloat(std.math.clamp(value, minimum, maximum) * 256.0);
}

test "pointer gesture descriptors and fixed clamp pin unstable v1" {
    try std.testing.expectEqual(@as(u32, 3), protocol.zwp_pointer_gestures_v1.interface.version);
    try std.testing.expectEqual(@as(u32, 2), protocol.zwp_pointer_gestures_v1.request_messages[2].since);
    try std.testing.expectEqual(@as(u32, 3), protocol.zwp_pointer_gestures_v1.request_messages[3].since);
    try std.testing.expectEqual(std.math.maxInt(i32), fixed(1.0e20));
    try std.testing.expectEqual(std.math.minInt(i32), fixed(-1.0e20));
}
