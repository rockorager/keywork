//! Scanner-backed relative-pointer unstable-v1 adapter.

const Self = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayring = @import("wayring");
const ClientRegistry = @import("../ClientRegistry.zig");
const CompositorServer = @import("../server.zig");
const WayringSeatAdapter = @import("WayringSeatAdapter.zig");

const server = wayring.server;

const Manager = struct { owner: *Self, client: *server.Client, resource: protocol.zwp_relative_pointer_manager_v1.Resource };
const Pointer = struct {
    owner: *Self,
    client: *server.Client,
    resource: protocol.zwp_relative_pointer_v1.Resource,
    pointer_object_id: u32,
    identity: WayringSeatAdapter.PointerIdentity,
};

allocator: std.mem.Allocator,
protocol_server: *server.Server,
seat: *WayringSeatAdapter,
global: ?*const server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
pointers: std.ArrayList(*Pointer) = .empty,

pub fn init(self: *Self, allocator: std.mem.Allocator, protocol_server: *server.Server, seat: *WayringSeatAdapter) void {
    self.* = .{ .allocator = allocator, .protocol_server = protocol_server, .seat = seat };
}

pub fn publish(self: *Self) !void {
    self.global = try self.protocol_server.addGlobal(protocol.zwp_relative_pointer_manager_v1, 1, Self, self, bind);
}
pub fn unpublish(self: *Self) void {
    self.protocol_server.removeGlobal(self.global orelse unreachable) catch {};
    self.global = null;
}
pub fn deinit(self: *Self) void {
    std.debug.assert(self.global == null and self.managers.items.len == 0 and self.pointers.items.len == 0);
    self.pointers.deinit(self.allocator);
    self.managers.deinit(self.allocator);
    self.* = undefined;
}

pub fn observer(self: *Self) CompositorServer.GeneratedRelativePointerObserver {
    return .{ .context = self, .motion = motion };
}

fn bind(client: *server.Client, id: u32, version: u32, self: *Self) !void {
    if (version != 1) return error.InvalidVersion;
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

fn managerRequest(_: *protocol.zwp_relative_pointer_manager_v1.Resource, request: protocol.zwp_relative_pointer_manager_v1.Request, value: *Manager) !void {
    switch (request) {
        .destroy => value.owner.destroyManager(value),
        .get_relative_pointer => |args| try value.owner.createPointer(value, args.id, args.pointer),
    }
}

fn createPointer(self: *Self, manager: *Manager, id: u32, pointer_object_id: u32) !void {
    const identity = self.seat.pointerIdentityIncludingInactive(manager.client, pointer_object_id) orelse {
        manager.client.postImplementationError(&manager.resource.runtime, "relative pointer requires the exact live same-client generated wl_pointer");
        return;
    };
    try self.pointers.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Pointer);
    errdefer self.allocator.destroy(value);
    value.* = .{ .owner = self, .client = manager.client, .resource = .init(self.allocator, id, 1, .client, manager.client.ownerHooks()), .pointer_object_id = pointer_object_id, .identity = identity };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Pointer, value, pointerRequest, null);
    try manager.client.materialize(&value.resource.runtime);
    self.pointers.appendAssumeCapacity(value);
}

fn pointerRequest(_: *protocol.zwp_relative_pointer_v1.Resource, request: protocol.zwp_relative_pointer_v1.Request, value: *Pointer) !void {
    switch (request) {
        .destroy => value.owner.destroyPointer(value),
    }
}

fn motion(context: *anyopaque, focused_client: ClientRegistry.Id, time_usec: u64, dx: f64, dy: f64, dx_unaccelerated: f64, dy_unaccelerated: f64) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const time = timestampParts(time_usec);
    for (self.pointers.items) |value| {
        if (!std.meta.eql(value.identity.client, focused_client)) continue;
        const current = self.seat.pointerIdentity(value.client, value.pointer_object_id) orelse continue;
        if (!std.meta.eql(current, value.identity)) continue;
        protocol.zwp_relative_pointer_v1.@"send:relative_motion"(&value.resource, time.high, time.low, fixed(dx), fixed(dy), fixed(dx_unaccelerated), fixed(dy_unaccelerated)) catch {
            value.client.postOutOfMemory(&value.resource.runtime, "sending relative pointer motion");
        };
    }
}

pub fn destroyClientResources(self: *Self, client: *server.Client) void {
    var i = self.pointers.items.len;
    while (i > 0) {
        i -= 1;
        if (self.pointers.items[i].client == client) self.destroyPointer(self.pointers.items[i]);
    }
    i = self.managers.items.len;
    while (i > 0) {
        i -= 1;
        if (self.managers.items[i].client == client) self.destroyManager(self.managers.items[i]);
    }
}
fn destroyPointer(self: *Self, value: *Pointer) void {
    remove(Pointer, &self.pointers, value);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}
fn destroyManager(self: *Self, value: *Manager) void {
    remove(Manager, &self.managers, value);
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

fn timestampParts(time_usec: u64) struct { high: u32, low: u32 } {
    return .{ .high = @truncate(time_usec >> 32), .low = @truncate(time_usec) };
}
fn fixed(value: f64) i32 {
    const minimum = @as(f64, @floatFromInt(std.math.minInt(i32))) / 256.0;
    const maximum = @as(f64, @floatFromInt(std.math.maxInt(i32))) / 256.0;
    return @intFromFloat(std.math.clamp(value, minimum, maximum) * 256.0);
}

test "relative pointer descriptors and wire conversions pin unstable v1" {
    try std.testing.expectEqual(@as(u32, 1), protocol.zwp_relative_pointer_manager_v1.interface.version);
    try std.testing.expectEqualStrings("get_relative_pointer", protocol.zwp_relative_pointer_manager_v1.request_messages[1].name);
    const parts = timestampParts(0x0123_4567_89ab_cdef);
    try std.testing.expectEqual(@as(u32, 0x0123_4567), parts.high);
    try std.testing.expectEqual(@as(u32, 0x89ab_cdef), parts.low);
    try std.testing.expectEqual(@as(i32, std.math.maxInt(i32)), fixed(std.math.inf(f64)));
}
