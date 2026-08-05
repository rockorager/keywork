//! Maps stable generated-server clients onto frontend-neutral identities.
//!
//! The host explicitly owns teardown: all generated application resources are
//! destroyed first, then this mapping is removed and its neutral identity is
//! synchronously invalidated, and only then may transport free the raw client.

const WayringClients = @This();

const std = @import("std");
const wayring = @import("wayring");
const ClientRegistry = @import("../ClientRegistry.zig");

const ClientState = struct {
    client: *wayring.server.Client,
    id: ClientRegistry.Id,
};

allocator: std.mem.Allocator,
registry: *ClientRegistry,
clients: std.AutoHashMapUnmanaged(usize, *ClientState) = .empty,
initialized: bool,

pub fn init(
    self: *WayringClients,
    allocator: std.mem.Allocator,
    registry: *ClientRegistry,
) void {
    self.* = .{
        .allocator = allocator,
        .registry = registry,
        .initialized = true,
    };
}

pub fn deinit(self: *WayringClients) void {
    std.debug.assert(self.initialized);
    std.debug.assert(self.clients.count() == 0);
    self.clients.deinit(self.allocator);
    self.initialized = false;
}

/// Atomically installs one raw mapping and one generated-server identity.
pub fn register(
    self: *WayringClients,
    client: *wayring.server.Client,
) error{ OutOfMemory, DuplicateMapping }!ClientRegistry.Id {
    std.debug.assert(self.initialized);
    const key = @intFromPtr(client);
    if (self.clients.contains(key)) return error.DuplicateMapping;

    const state = try self.allocator.create(ClientState);
    errdefer self.allocator.destroy(state);
    const client_id = try self.registry.register(.wayring_server);
    errdefer self.registry.unregister(client_id);
    state.* = .{ .client = client, .id = client_id };
    try self.clients.putNoClobber(self.allocator, key, state);
    return client_id;
}

/// Allocation-free lookup. Null also means explicit destruction has begun.
pub fn id(
    self: *const WayringClients,
    client: *const wayring.server.Client,
) ?ClientRegistry.Id {
    std.debug.assert(self.initialized);
    const client_id = (self.clients.get(@intFromPtr(client)) orelse return null).id;
    if (self.registry.domainOf(client_id) != .wayring_server) return null;
    return client_id;
}

/// Allocation-free generational registration check used by generated
/// adapters before issuing serials for a retained neutral identity.
pub fn contains(self: *const WayringClients, client: ClientRegistry.Id) bool {
    std.debug.assert(self.initialized);
    if (self.registry.domainOf(client) != .wayring_server) return false;
    var iterator = self.clients.valueIterator();
    while (iterator.next()) |state| {
        if (std.meta.eql(state.*.id, client)) return true;
    }
    return false;
}

/// Allocation-free reverse lookup for terminalizing one generated client
/// after a canonical operation identified it only by neutral ID.
pub fn rawClient(
    self: *const WayringClients,
    client_id: ClientRegistry.Id,
) ?*wayring.server.Client {
    std.debug.assert(self.initialized);
    if (self.registry.domainOf(client_id) != .wayring_server) return null;
    var iterator = self.clients.valueIterator();
    while (iterator.next()) |state| {
        if (std.meta.eql(state.*.id, client_id)) return state.*.client;
    }
    return null;
}

/// Requires every generated application resource for `client` to be gone.
/// The raw lookup is removed before the neutral registry notifies listeners,
/// matching MatureClients: listeners observe both a dead ID and absent raw
/// lookup, while ClientState storage remains alive until notification returns.
pub fn unregister(self: *WayringClients, client: *wayring.server.Client) void {
    std.debug.assert(self.initialized);
    const removed = self.clients.fetchRemove(@intFromPtr(client)) orelse unreachable;
    std.debug.assert(removed.value.client == client);
    self.registry.unregister(removed.value.id);
    self.allocator.destroy(removed.value);
}

test "raw address reuse receives a new generated-server generation" {
    var registry = ClientRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var clients: WayringClients = undefined;
    clients.init(std.testing.allocator, &registry);
    defer clients.deinit();
    const raw: *wayring.server.Client = @ptrFromInt(0x1000);

    const stale = try clients.register(raw);
    try std.testing.expectEqual(ClientRegistry.SerialDomain.wayring_server, registry.domainOf(stale).?);
    try std.testing.expect(clients.rawClient(stale) == raw);
    clients.unregister(raw);
    try std.testing.expect(clients.id(raw) == null);
    try std.testing.expect(clients.rawClient(stale) == null);
    try std.testing.expect(!registry.contains(stale));

    const current = try clients.register(raw);
    try std.testing.expectEqual(stale.index, current.index);
    try std.testing.expect(stale.generation != current.generation);
    try std.testing.expect(!registry.contains(stale));
    try std.testing.expect(!clients.contains(stale));
    try std.testing.expect(clients.rawClient(current) == raw);
    try std.testing.expect(clients.contains(current));
    clients.unregister(raw);
}

test "registration is atomic at state registry and map allocation points" {
    for (0..3) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        failing.fail_index = fail_index;
        var registry = ClientRegistry.init(failing.allocator());
        defer registry.deinit();
        var clients: WayringClients = undefined;
        clients.init(failing.allocator(), &registry);
        defer clients.deinit();

        try std.testing.expectError(
            error.OutOfMemory,
            clients.register(@ptrFromInt(0x2000)),
        );
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(@as(usize, 0), clients.clients.count());
        try std.testing.expectEqual(@as(usize, 0), registry.len());
    }
}

test "duplicate mapping is rejected without changing generated authority" {
    var registry = ClientRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var clients: WayringClients = undefined;
    clients.init(std.testing.allocator, &registry);
    defer clients.deinit();
    const raw: *wayring.server.Client = @ptrFromInt(0x3000);

    const original = try clients.register(raw);
    try std.testing.expectError(error.DuplicateMapping, clients.register(raw));
    try std.testing.expectEqual(@as(usize, 1), clients.clients.count());
    try std.testing.expectEqual(@as(usize, 1), registry.len());
    try std.testing.expect(std.meta.eql(original, clients.id(raw).?));
    clients.unregister(raw);
}

test "resource teardown precedes neutral purge and raw state release" {
    const Observer = struct {
        registry: *ClientRegistry,
        clients: *WayringClients,
        client: *wayring.server.Client,
        id_value: ClientRegistry.Id,
        resources_destroyed: bool = false,
        notified: bool = false,

        fn disconnected(context: *anyopaque, id_value: ClientRegistry.Id) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            std.debug.assert(std.meta.eql(self.id_value, id_value));
            self.notified = self.resources_destroyed and
                !self.registry.contains(id_value) and self.clients.id(self.client) == null;
        }
    };

    var registry = ClientRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var clients: WayringClients = undefined;
    clients.init(std.testing.allocator, &registry);
    defer clients.deinit();
    const raw: *wayring.server.Client = @ptrFromInt(0x4000);
    const client_id = try clients.register(raw);
    var observer: Observer = .{
        .registry = &registry,
        .clients = &clients,
        .client = raw,
        .id_value = client_id,
    };
    try registry.addDisconnectListener(.{
        .context = &observer,
        .notify = Observer.disconnected,
    });
    defer registry.removeDisconnectListener(&observer);

    observer.resources_destroyed = true;
    clients.unregister(raw);
    try std.testing.expect(observer.notified);
}
