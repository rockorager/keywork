//! Maps libwayland clients onto frontend-neutral compositor client identities.

const MatureClients = @This();

const std = @import("std");
const wl = @import("wayland").server.wl;
const ClientRegistry = @import("../ClientRegistry.zig");

const ClientState = struct {
    owner: *MatureClients,
    client: *wl.Client,
    id: ClientRegistry.Id,
    destroy_listener: wl.Listener(*wl.Client),
};

allocator: std.mem.Allocator,
registry: *ClientRegistry,
clients: std.AutoHashMapUnmanaged(usize, *ClientState) = .empty,
client_created_listener: wl.Listener(*wl.Client),
initialized: bool,

pub fn init(
    self: *MatureClients,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    registry: *ClientRegistry,
) void {
    self.* = .{
        .allocator = allocator,
        .registry = registry,
        .client_created_listener = .init(handleClientCreated),
        .initialized = true,
    };
    display.addClientCreatedListener(&self.client_created_listener);
}

pub fn deinit(self: *MatureClients) void {
    std.debug.assert(self.initialized);
    std.debug.assert(self.clients.count() == 0);
    self.client_created_listener.link.remove();
    self.clients.deinit(self.allocator);
    self.initialized = false;
}

/// Returns null once destruction has begun, including from disconnect callbacks.
pub fn id(self: *const MatureClients, client: *wl.Client) ?ClientRegistry.Id {
    std.debug.assert(self.initialized);
    const state = self.clients.get(@intFromPtr(client)) orelse return null;
    return state.id;
}

fn handleClientCreated(listener: *wl.Listener(*wl.Client), client: *wl.Client) void {
    const self: *MatureClients = @fieldParentPtr("client_created_listener", listener);
    _ = self.registerMapping(client, true) catch |err| switch (err) {
        error.OutOfMemory => client.postNoMemory(),
        error.DuplicateMapping => unreachable,
    };
}

fn registerMapping(
    self: *MatureClients,
    client: *wl.Client,
    install_listener: bool,
) error{ OutOfMemory, DuplicateMapping }!ClientRegistry.Id {
    const key = @intFromPtr(client);
    if (self.clients.contains(key)) return error.DuplicateMapping;

    const state = try self.allocator.create(ClientState);
    errdefer self.allocator.destroy(state);
    const client_id = try self.registry.register(.mature_display);
    errdefer self.registry.unregister(client_id);
    state.* = .{
        .owner = self,
        .client = client,
        .id = client_id,
        .destroy_listener = .init(handleClientDestroyed),
    };
    try self.clients.putNoClobber(self.allocator, key, state);
    if (install_listener) client.addDestroyListener(&state.destroy_listener);
    return client_id;
}

fn handleClientDestroyed(listener: *wl.Listener(*wl.Client), client: *wl.Client) void {
    const state: *ClientState = @fieldParentPtr("destroy_listener", listener);
    std.debug.assert(state.client == client);
    state.owner.removeMapping(state, true);
}

fn removeMapping(self: *MatureClients, state: *ClientState, unlink_listener: bool) void {
    const removed = self.clients.fetchRemove(@intFromPtr(state.client)) orelse unreachable;
    std.debug.assert(removed.value == state);
    if (unlink_listener) state.destroy_listener.link.remove();
    self.registry.unregister(state.id);
    self.allocator.destroy(state);
}

test "raw address reuse does not revive stale neutral authority" {
    var registry = ClientRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var clients: MatureClients = .{
        .allocator = std.testing.allocator,
        .registry = &registry,
        .client_created_listener = undefined,
        .initialized = true,
    };
    defer clients.clients.deinit(std.testing.allocator);
    const raw: *wl.Client = @ptrFromInt(0x1000);

    const stale = try clients.registerMapping(raw, false);
    try std.testing.expect(std.meta.eql(stale, clients.id(raw).?));
    clients.removeMapping(clients.clients.get(@intFromPtr(raw)).?, false);
    try std.testing.expect(clients.id(raw) == null);
    try std.testing.expect(!registry.contains(stale));

    const current = try clients.registerMapping(raw, false);
    try std.testing.expectEqual(stale.index, current.index);
    try std.testing.expect(stale.generation != current.generation);
    try std.testing.expect(!registry.contains(stale));
    clients.removeMapping(clients.clients.get(@intFromPtr(raw)).?, false);
}

test "registration is atomic across every allocation failure" {
    for (0..3) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        failing.fail_index = fail_index;
        var registry = ClientRegistry.init(failing.allocator());
        defer registry.deinit();
        var clients: MatureClients = .{
            .allocator = failing.allocator(),
            .registry = &registry,
            .client_created_listener = undefined,
            .initialized = true,
        };
        defer clients.clients.deinit(failing.allocator());

        try std.testing.expectError(
            error.OutOfMemory,
            clients.registerMapping(@ptrFromInt(0x2000), false),
        );
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(@as(usize, 0), clients.clients.count());
        try std.testing.expectEqual(@as(usize, 0), registry.len());
    }
}

test "client-created OOM leaves no mature mapping or neutral identity" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    failing.fail_index = 0;
    var registry = ClientRegistry.init(failing.allocator());
    defer registry.deinit();

    const display = try wl.Server.create();
    defer display.destroy();
    var clients: MatureClients = undefined;
    clients.init(failing.allocator(), display, &registry);
    defer clients.deinit();

    var sockets: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM | std.c.SOCK.CLOEXEC, 0, &sockets),
    );
    defer _ = std.c.close(sockets[1]);
    const client = wl.Client.create(display, sockets[0]) orelse return error.OutOfMemory;
    defer client.destroy();

    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(clients.id(client) == null);
    try std.testing.expectEqual(@as(usize, 0), registry.len());
}

test "duplicate raw mapping is rejected without changing authority" {
    var registry = ClientRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var clients: MatureClients = .{
        .allocator = std.testing.allocator,
        .registry = &registry,
        .client_created_listener = undefined,
        .initialized = true,
    };
    defer clients.clients.deinit(std.testing.allocator);
    const raw: *wl.Client = @ptrFromInt(0x3000);
    const original = try clients.registerMapping(raw, false);
    try std.testing.expectError(error.DuplicateMapping, clients.registerMapping(raw, false));
    try std.testing.expectEqual(@as(usize, 1), clients.clients.count());
    try std.testing.expectEqual(@as(usize, 1), registry.len());
    try std.testing.expect(std.meta.eql(original, clients.id(raw).?));
    clients.removeMapping(clients.clients.get(@intFromPtr(raw)).?, false);
}

test "client destruction invalidates identity before resource teardown" {
    const Observer = struct {
        registry: *ClientRegistry,
        clients: *MatureClients,
        client: *wl.Client,
        id: ClientRegistry.Id,
        disconnect_notified: bool = false,
        resource_destroyed: bool = false,
        dead_before_resources: bool = false,

        fn disconnected(context: *anyopaque, client_id: ClientRegistry.Id) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            std.debug.assert(std.meta.eql(self.id, client_id));
            self.disconnect_notified = true;
            self.dead_before_resources = !self.registry.contains(client_id) and
                self.clients.id(self.client) == null;
        }

        fn request(resource: *wl.Output, request_value: wl.Output.Request, _: *@This()) void {
            switch (request_value) {
                .release => resource.destroy(),
            }
        }

        fn resourceDestroyed(_: *wl.Output, self: *@This()) void {
            self.resource_destroyed = true;
            self.dead_before_resources = self.dead_before_resources and self.disconnect_notified and
                !self.registry.contains(self.id) and self.clients.id(self.client) == null;
        }
    };

    const display = try wl.Server.create();
    defer display.destroy();
    var registry = ClientRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var clients: MatureClients = undefined;
    clients.init(std.testing.allocator, display, &registry);
    defer clients.deinit();

    var sockets: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM | std.c.SOCK.CLOEXEC, 0, &sockets),
    );
    defer _ = std.c.close(sockets[1]);
    const client = wl.Client.create(display, sockets[0]) orelse return error.OutOfMemory;
    const client_id = clients.id(client) orelse return error.TestUnexpectedResult;
    var observer: Observer = .{
        .registry = &registry,
        .clients = &clients,
        .client = client,
        .id = client_id,
    };
    try registry.addDisconnectListener(.{
        .context = &observer,
        .notify = Observer.disconnected,
    });
    defer registry.removeDisconnectListener(&observer);
    const resource = try wl.Output.create(client, 4, 0);
    resource.setHandler(*Observer, Observer.request, Observer.resourceDestroyed, &observer);

    client.destroy();
    try std.testing.expect(observer.disconnect_notified);
    try std.testing.expect(observer.resource_destroyed);
    try std.testing.expect(observer.dead_before_resources);
    try std.testing.expectEqual(@as(usize, 0), registry.len());
}
