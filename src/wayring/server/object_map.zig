//! Sparse, bounded object-ID namespace for one Wayland client connection.
//!
//! Resource pointers are borrowed. Deinitialization never destroys resources,
//! and entries may still be present when the map is deinitialized.

const ObjectMap = @This();

const std = @import("std");

pub const first_server_id: u32 = 0xff000000;
pub const last_client_id: u32 = first_server_id - 1;

pub const Origin = enum { client, server };
pub const State = enum { vacant, reserved_client, live_client, live_server };

pub const LiveObject = struct {
    resource: *anyopaque,
    origin: Origin,
};

const Entry = union(enum) {
    reserved_client,
    live: LiveObject,
};

pub const Config = struct {
    /// Maximum combined number of reserved and live IDs for this client.
    max_objects: usize = 4096,
};

allocator: std.mem.Allocator,
entries: std.AutoHashMapUnmanaged(u32, Entry) = .empty,
free_server_ids: std.ArrayList(u32) = .empty,
max_objects: usize,
next_server_id: u32 = first_server_id,

pub fn init(allocator: std.mem.Allocator, config: Config) ObjectMap {
    return .{
        .allocator = allocator,
        .max_objects = config.max_objects,
    };
}

pub fn deinit(self: *ObjectMap) void {
    self.entries.deinit(self.allocator);
    self.free_server_ids.deinit(self.allocator);
    self.* = undefined;
}

/// Atomically reserves all client-created IDs carried by one request.
pub fn reserveClientIds(self: *ObjectMap, ids: []const u32) !void {
    for (ids, 0..) |id, index| {
        if (id == 0 or id > last_client_id) return error.InvalidClientId;
        if (self.entries.contains(id)) return error.IdInUse;
        for (ids[0..index]) |previous| {
            if (id == previous) return error.DuplicateId;
        }
    }
    if (ids.len > self.max_objects -| self.entries.count()) return error.ObjectLimitReached;

    // Capacity is acquired before mutation, making OOM transactional.
    try self.entries.ensureUnusedCapacity(self.allocator, @intCast(ids.len));
    for (ids) |id| self.entries.putAssumeCapacityNoClobber(id, .reserved_client);
}

/// Converts a reservation made by `reserveClientIds` into a live object.
pub fn materializeClient(self: *ObjectMap, id: u32, resource: *anyopaque) !void {
    const entry = self.entries.getPtr(id) orelse return error.NotReserved;
    if (entry.* != .reserved_client) return error.NotReserved;
    entry.* = .{ .live = .{ .resource = resource, .origin = .client } };
}

/// Removes reservations when setup fails before request dispatch.
pub fn rollbackClientReservations(self: *ObjectMap, ids: []const u32) void {
    for (ids) |id| {
        const entry = self.entries.get(id) orelse continue;
        if (entry == .reserved_client) _ = self.entries.remove(id);
    }
}

pub fn lookup(self: *const ObjectMap, id: u32) ?LiveObject {
    const entry = self.entries.get(id) orelse return null;
    return switch (entry) {
        .reserved_client => null,
        .live => |live| live,
    };
}

pub fn state(self: *const ObjectMap, id: u32) State {
    const entry = self.entries.get(id) orelse return .vacant;
    return switch (entry) {
        .reserved_client => .reserved_client,
        .live => |live| if (live.origin == .client) .live_client else .live_server,
    };
}

/// Call only after `wl_display.delete_id` for this ID has been successfully
/// queued. Removing it makes the client-created ID immediately reusable.
pub fn retireClientAfterDeleteIdQueued(self: *ObjectMap, id: u32) !void {
    const live = self.lookup(id) orelse return error.NotLiveClientObject;
    if (live.origin != .client) return error.NotLiveClientObject;
    _ = self.entries.remove(id);
}

/// Allocates and materializes a server-created ID. Freed IDs are preferred;
/// otherwise at most the current bounded entry count plus one is examined.
pub fn allocateServer(self: *ObjectMap, resource: *anyopaque) !u32 {
    if (self.entries.count() >= self.max_objects) return error.ObjectLimitReached;
    try self.entries.ensureUnusedCapacity(self.allocator, 1);

    if (self.free_server_ids.pop()) |id| {
        std.debug.assert(!self.entries.contains(id));
        self.entries.putAssumeCapacityNoClobber(id, .{ .live = .{ .resource = resource, .origin = .server } });
        return id;
    }

    var id = self.next_server_id;
    var remaining = self.entries.count() + 1;
    while (remaining != 0) : (remaining -= 1) {
        if (!self.entries.contains(id)) {
            self.entries.putAssumeCapacityNoClobber(id, .{ .live = .{ .resource = resource, .origin = .server } });
            self.next_server_id = nextServerId(id);
            return id;
        }
        id = nextServerId(id);
    }
    return error.ServerIdExhausted;
}

/// Server IDs require no delete_id event and become reusable immediately.
pub fn retireServer(self: *ObjectMap, id: u32) !void {
    const live = self.lookup(id) orelse return error.NotLiveServerObject;
    if (live.origin != .server) return error.NotLiveServerObject;
    try self.free_server_ids.append(self.allocator, id);
    _ = self.entries.remove(id);
}

fn nextServerId(id: u32) u32 {
    return if (id == std.math.maxInt(u32)) first_server_id else id + 1;
}

test "sparse client reservations validate and remain transactional" {
    var map = init(std.testing.allocator, .{ .max_objects = 3 });
    defer map.deinit();

    try map.reserveClientIds(&.{ 3, 0x00f00000 });
    try std.testing.expectEqual(State.reserved_client, map.state(0x00f00000));
    try std.testing.expectError(error.InvalidClientId, map.reserveClientIds(&.{0}));
    try std.testing.expectError(error.InvalidClientId, map.reserveClientIds(&.{first_server_id}));
    try std.testing.expectError(error.DuplicateId, map.reserveClientIds(&.{ 9, 9 }));
    try std.testing.expectError(error.IdInUse, map.reserveClientIds(&.{3}));
    try std.testing.expectError(error.ObjectLimitReached, map.reserveClientIds(&.{ 10, 11 }));
    try std.testing.expectEqual(State.vacant, map.state(10));
}

test "materialize lookup rollback and client retirement" {
    var map = init(std.testing.allocator, .{});
    defer map.deinit();
    var byte: u8 = 0;
    const resource: *anyopaque = @ptrCast(&byte);

    try map.reserveClientIds(&.{ 41, 42 });
    try map.materializeClient(41, resource);
    try std.testing.expectError(error.IdInUse, map.reserveClientIds(&.{41}));
    const found = map.lookup(41).?;
    try std.testing.expectEqual(resource, found.resource);
    try std.testing.expectEqual(Origin.client, found.origin);
    map.rollbackClientReservations(&.{ 41, 42 });
    try std.testing.expectEqual(State.live_client, map.state(41));
    try std.testing.expectEqual(State.vacant, map.state(42));
    try map.retireClientAfterDeleteIdQueued(41);
    try map.reserveClientIds(&.{41});
}

test "reservation allocation failure has no partial state" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var map = init(failing.allocator(), .{});
    defer map.deinit();
    try std.testing.expectError(error.OutOfMemory, map.reserveClientIds(&.{ 7, 200000 }));
    try std.testing.expectEqual(State.vacant, map.state(7));
    try std.testing.expectEqual(State.vacant, map.state(200000));
}

test "server IDs are distinct reusable and wrap" {
    var map = init(std.testing.allocator, .{});
    defer map.deinit();
    map.next_server_id = std.math.maxInt(u32);
    var first: u8 = 0;
    var second: u8 = 0;
    const first_id = try map.allocateServer(@ptrCast(&first));
    const second_id = try map.allocateServer(@ptrCast(&second));
    try std.testing.expectEqual(std.math.maxInt(u32), first_id);
    try std.testing.expectEqual(first_server_id, second_id);
    try std.testing.expect(first_id != second_id);
    try map.retireServer(first_id);
    try std.testing.expectEqual(first_id, try map.allocateServer(@ptrCast(&first)));
}
