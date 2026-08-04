//! Sparse, bounded object-ID namespace for one Wayland client connection.
//!
//! Resource pointers are borrowed. Deinitialization never destroys resources,
//! and entries may still be present when the map is deinitialized.

const ObjectMap = @This();

const std = @import("std");

pub const first_server_id: u32 = 0xff000000;
pub const last_client_id: u32 = first_server_id - 1;

pub const Origin = enum { client, server };
pub const State = enum { vacant, reserved_client, reserved_server, live_client, live_server };

pub const LiveObject = struct {
    resource: *anyopaque,
    origin: Origin,
};

const Entry = union(enum) {
    reserved_client,
    reserved_server,
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
client_high_water: u32 = 1,
/// One recycle-list slot is claimed by every reserved or live server ID.
server_recycle_claims: usize = 0,

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
    var high_water = self.client_high_water;
    for (ids, 0..) |id, index| {
        if (id == 0 or id > last_client_id) return error.InvalidClientId;
        if (self.entries.contains(id)) return error.IdInUse;
        for (ids[0..index]) |previous| {
            if (id == previous) return error.DuplicateId;
        }
        if (id > high_water) {
            if (id != high_water + 1) return error.ClientIdGap;
            high_water = id;
        }
    }
    if (ids.len > self.max_objects -| self.entries.count()) return error.ObjectLimitReached;

    // Capacity is acquired before mutation, making OOM transactional.
    try self.entries.ensureUnusedCapacity(self.allocator, @intCast(ids.len));
    for (ids) |id| self.entries.putAssumeCapacityNoClobber(id, .reserved_client);
    self.client_high_water = high_water;
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
        .reserved_client, .reserved_server => null,
        .live => |live| live,
    };
}

pub fn state(self: *const ObjectMap, id: u32) State {
    const entry = self.entries.get(id) orelse return .vacant;
    return switch (entry) {
        .reserved_client => .reserved_client,
        .reserved_server => .reserved_server,
        .live => |live| if (live.origin == .client) .live_client else .live_server,
    };
}

/// Call only after `wl_display.delete_id` for this ID has been successfully
/// queued. Removing it makes the client-created ID immediately reusable.
pub fn retireClientAfterDeleteIdQueued(self: *ObjectMap, id: u32, resource: *anyopaque) !void {
    const live = self.lookup(id) orelse return error.NotLiveClientObject;
    if (live.origin != .client or live.resource != resource) return error.NotLiveClientObject;
    _ = self.entries.remove(id);
}

pub fn reserveServerId(self: *ObjectMap) !u32 {
    if (self.entries.count() >= self.max_objects) return error.ObjectLimitReached;
    try self.entries.ensureUnusedCapacity(self.allocator, 1);
    if (self.free_server_ids.pop()) |id| {
        self.server_recycle_claims += 1;
        self.entries.putAssumeCapacityNoClobber(id, .reserved_server);
        return id;
    }
    // Every outstanding server ID claims enough spare capacity to retire or
    // roll back later without allocation. Claims do not change list length,
    // so account for all of them explicitly.
    try self.free_server_ids.ensureUnusedCapacity(self.allocator, self.server_recycle_claims + 1);
    var id = self.next_server_id;
    var remaining = self.entries.count() + 1;
    while (remaining != 0) : (remaining -= 1) {
        if (!self.entries.contains(id)) {
            self.server_recycle_claims += 1;
            self.entries.putAssumeCapacityNoClobber(id, .reserved_server);
            self.next_server_id = nextServerId(id);
            return id;
        }
        id = nextServerId(id);
    }
    return error.ServerIdExhausted;
}

pub fn materializeServer(self: *ObjectMap, id: u32, resource: *anyopaque) !void {
    const entry = self.entries.getPtr(id) orelse return error.NotReserved;
    if (entry.* != .reserved_server) return error.NotReserved;
    entry.* = .{ .live = .{ .resource = resource, .origin = .server } };
}

pub fn rollbackServerId(self: *ObjectMap, id: u32) void {
    const entry = self.entries.get(id) orelse return;
    if (entry != .reserved_server) return;
    _ = self.entries.remove(id);
    self.free_server_ids.appendAssumeCapacity(id);
    std.debug.assert(self.server_recycle_claims > 0);
    self.server_recycle_claims -= 1;
}

/// Allocates and materializes a server-created ID. Freed IDs are preferred;
/// otherwise at most the current bounded entry count plus one is examined.
pub fn allocateServer(self: *ObjectMap, resource: *anyopaque) !u32 {
    const id = try self.reserveServerId();
    errdefer self.rollbackServerId(id);
    try self.materializeServer(id, resource);
    return id;
}

/// Server IDs require no delete_id event and become reusable immediately.
pub fn retireServer(self: *ObjectMap, id: u32, resource: *anyopaque) !void {
    const live = self.lookup(id) orelse return error.NotLiveServerObject;
    if (live.origin != .server or live.resource != resource) return error.NotLiveServerObject;
    self.free_server_ids.appendAssumeCapacity(id);
    std.debug.assert(self.server_recycle_claims > 0);
    self.server_recycle_claims -= 1;
    _ = self.entries.remove(id);
}

/// Removes a live pointer after terminal connection failure. This operation
/// deliberately does not make a server ID reusable.
pub fn discardLive(self: *ObjectMap, id: u32, resource: *anyopaque) void {
    const live = self.lookup(id) orelse return;
    if (live.resource != resource) return;
    if (live.origin == .server) {
        std.debug.assert(self.server_recycle_claims > 0);
        self.server_recycle_claims -= 1;
    }
    _ = self.entries.remove(id);
}

fn nextServerId(id: u32) u32 {
    return if (id == std.math.maxInt(u32)) first_server_id else id + 1;
}

test "dense client reservations reject gaps and accept sequential and retired reuse" {
    var map = init(std.testing.allocator, .{ .max_objects = 3 });
    defer map.deinit();

    try std.testing.expectError(error.ClientIdGap, map.reserveClientIds(&.{3}));
    try map.reserveClientIds(&.{ 2, 3 });
    try std.testing.expectEqual(State.reserved_client, map.state(3));
    try std.testing.expectError(error.InvalidClientId, map.reserveClientIds(&.{0}));
    try std.testing.expectError(error.InvalidClientId, map.reserveClientIds(&.{first_server_id}));
    map.rollbackClientReservations(&.{ 2, 3 });
    try std.testing.expectError(error.DuplicateId, map.reserveClientIds(&.{ 4, 4 }));
    try map.reserveClientIds(&.{ 2, 4 });
    try std.testing.expectEqual(State.reserved_client, map.state(2));
}

test "materialize lookup rollback and client retirement" {
    var map = init(std.testing.allocator, .{});
    defer map.deinit();
    var byte: u8 = 0;
    const resource: *anyopaque = @ptrCast(&byte);

    try map.reserveClientIds(&.{ 2, 3 });
    try map.materializeClient(2, resource);
    try std.testing.expectError(error.IdInUse, map.reserveClientIds(&.{2}));
    const found = map.lookup(2).?;
    try std.testing.expectEqual(resource, found.resource);
    try std.testing.expectEqual(Origin.client, found.origin);
    map.rollbackClientReservations(&.{ 2, 3 });
    try std.testing.expectEqual(State.live_client, map.state(2));
    try std.testing.expectEqual(State.vacant, map.state(3));
    try map.retireClientAfterDeleteIdQueued(2, resource);
    try map.reserveClientIds(&.{2});
}

test "reservation allocation failure has no partial state" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var map = init(failing.allocator(), .{});
    defer map.deinit();
    try std.testing.expectError(error.OutOfMemory, map.reserveClientIds(&.{2}));
    try std.testing.expectEqual(State.vacant, map.state(2));
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
    try map.retireServer(first_id, @ptrCast(&first));
    try std.testing.expectEqual(first_id, try map.allocateServer(@ptrCast(&first)));
}

test "server reservation rollback materialization retirement and identity are transactional" {
    var map = init(std.testing.allocator, .{});
    defer map.deinit();
    var first: u8 = 0;
    var impostor: u8 = 0;

    const rolled_back = try map.reserveServerId();
    try std.testing.expectEqual(State.reserved_server, map.state(rolled_back));
    map.rollbackServerId(rolled_back);
    try std.testing.expectEqual(rolled_back, try map.reserveServerId());
    try map.materializeServer(rolled_back, @ptrCast(&first));
    try std.testing.expectError(error.NotLiveServerObject, map.retireServer(rolled_back, @ptrCast(&impostor)));
    try std.testing.expectEqual(State.live_server, map.state(rolled_back));
    try map.retireServer(rolled_back, @ptrCast(&first));
    try std.testing.expectEqual(rolled_back, try map.reserveServerId());
}

test "all outstanding server IDs have allocation-free recycle capacity" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var map = init(failing.allocator(), .{ .max_objects = 128 });
    defer map.deinit();

    var ids: [64]u32 = undefined;
    var resources: [32]u8 = @splat(0);
    for (&ids) |*id| id.* = try map.reserveServerId();
    for (ids[0..resources.len], &resources) |id, *resource| try map.materializeServer(id, resource);

    // Retirement and rollback must consume capacity claimed during reserve,
    // even after enough outstanding IDs exceeded the list's initial capacity.
    failing.fail_index = failing.alloc_index;
    for (ids[0..resources.len], &resources) |id, *resource| try map.retireServer(id, resource);
    for (ids[resources.len..]) |id| map.rollbackServerId(id);
    try std.testing.expect(!failing.has_induced_failure);
}
