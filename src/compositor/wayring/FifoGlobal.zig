//! Native `wp_fifo_manager_v1` display-refresh constraints.

const FifoGlobal = @This();

const std = @import("std");
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const CompositorGlobal = @import("CompositorGlobal.zig");

const advertised_version: u32 = 1;

allocator: std.mem.Allocator,
server: *Server,
compositor: *CompositorGlobal,
global_name: u32,
fifo_count: usize = 0,

const Fifo = struct {
    owner: *FifoGlobal,
    surface: ?*CompositorGlobal.Surface,

    fn surfaceDestroyed(context: *anyopaque) void {
        const self: *Fifo = @ptrCast(@alignCast(context));
        self.surface = null;
    }
};

pub fn init(
    self: *FifoGlobal,
    allocator: std.mem.Allocator,
    server: *Server,
    compositor: *CompositorGlobal,
) !void {
    self.* = .{
        .allocator = allocator,
        .server = server,
        .compositor = compositor,
        .global_name = undefined,
    };
    self.global_name = try server.createGlobal(
        &generated.wp_fifo_manager_v1,
        advertised_version,
        .{ .context = self, .bind = bind },
    );
}

pub fn deinit(self: *FifoGlobal) void {
    std.debug.assert(self.fifo_count == 0);
    self.server.removeGlobal(self.global_name) catch unreachable;
    self.* = undefined;
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *FifoGlobal = @ptrCast(@alignCast(context));
    _ = client.createResource(id, &generated.wp_fifo_manager_v1, version, .{
        .context = self,
        .dispatch = dispatchManager,
    }) catch return client.postNoMemory();
}

fn dispatchManager(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const self: *FifoGlobal = @ptrCast(@alignCast(context));
    switch (try generated.wp_fifo_manager_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .get_fifo => |request| {
            const object = client.connection.object(request.surface) orelse
                return error.UnknownSurface;
            const surface = try CompositorGlobal.surfaceFor(client, .{
                .id = request.surface,
                .generation = object.generation,
            });
            if (surface.owner != self.compositor) return error.WrongSurface;
            if (surface.fifo_handler != null) return client.postError(
                resource,
                @intFromEnum(generated.wp_fifo_manager_v1_types.@"error".already_exists),
                "wl_surface already has a FIFO object",
            );
            const fifo = self.allocator.create(Fifo) catch
                return client.postNoMemory();
            errdefer self.allocator.destroy(fifo);
            const version = try client.resourceVersion(resource, &generated.wp_fifo_manager_v1);
            _ = client.createResource(
                request.id,
                &generated.wp_fifo_v1,
                version,
                .{
                    .context = fifo,
                    .dispatch = dispatchFifo,
                    .destroy = destroyFifo,
                },
            ) catch return client.postNoMemory();
            fifo.* = .{ .owner = self, .surface = surface };
            surface.setFifoHandler(.{
                .context = fifo,
                .surface_destroyed = Fifo.surfaceDestroyed,
            }) catch unreachable;
            self.fifo_count += 1;
        },
    }
}

fn dispatchFifo(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const self: *Fifo = @ptrCast(@alignCast(context));
    switch (try generated.wp_fifo_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .set_barrier => {
            const surface = self.surface orelse
                return postSurfaceDestroyed(client, resource);
            surface.setPendingFifoBarrier();
        },
        .wait_barrier => {
            const surface = self.surface orelse
                return postSurfaceDestroyed(client, resource);
            surface.setPendingFifoWait();
        },
    }
}

fn destroyFifo(
    context: *anyopaque,
    _: *Server.Client,
    _: wayring.ObjectHandle,
) void {
    const self: *Fifo = @ptrCast(@alignCast(context));
    if (self.surface) |surface| surface.clearFifoHandler(self);
    const owner = self.owner;
    owner.fifo_count -= 1;
    owner.allocator.destroy(self);
}

fn postSurfaceDestroyed(
    client: *Server.Client,
    resource: wayring.ObjectHandle,
) !void {
    return client.postError(
        resource,
        @intFromEnum(generated.wp_fifo_v1_types.@"error".surface_destroyed),
        "wl_surface has been destroyed",
    );
}

test "native FIFO state is one-shot and object scoped" {
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var compositor: CompositorGlobal = undefined;
    try compositor.init(std.testing.allocator, &server);
    defer compositor.deinit();
    var fifo_global: FifoGlobal = undefined;
    try fifo_global.init(std.testing.allocator, &server, &compositor);
    defer fifo_global.deinit();

    {
        const client = try server.createClient();
        defer server.destroyClient(client) catch unreachable;
        var peer = wayring.Connection.init(
            std.testing.allocator,
            .client,
            wayring.default_max_frame_size,
        );
        defer peer.deinit();
        const globals = try bindGlobals(&peer, client);
        const surface = try generated.wl_compositor_types.requests.create_surface(
            &peer,
            globals.compositor,
        );
        const fifo = try generated.wp_fifo_manager_v1_types.requests.get_fifo(
            &peer,
            globals.manager,
            surface,
        );
        try generated.wp_fifo_v1_types.requests.set_barrier(&peer, fifo);
        try generated.wp_fifo_v1_types.requests.wait_barrier(&peer, fifo);
        try generated.wp_fifo_v1_types.requests.destroy(&peer, fifo);
        try generated.wl_surface_types.requests.commit(&peer, surface);
        try generated.wl_surface_types.requests.commit(&peer, surface);
        try transferToServer(&peer, client);

        var first = compositor.popTransaction() orelse return error.MissingCommit;
        defer first.deinit();
        var second = compositor.popTransaction() orelse return error.MissingCommit;
        defer second.deinit();
        try std.testing.expect(first.entries[0].fifo_set);
        try std.testing.expect(first.entries[0].fifo_wait);
        try std.testing.expect(!second.entries[0].fifo_set);
        try std.testing.expect(!second.entries[0].fifo_wait);

        const inert = try generated.wp_fifo_manager_v1_types.requests.get_fifo(
            &peer,
            globals.manager,
            surface,
        );
        try generated.wl_surface_types.requests.destroy(&peer, surface);
        try generated.wp_fifo_v1_types.requests.set_barrier(&peer, inert);
        try std.testing.expectError(error.ProtocolError, transferToServer(&peer, client));
    }

    {
        const client = try server.createClient();
        defer server.destroyClient(client) catch unreachable;
        var peer = wayring.Connection.init(
            std.testing.allocator,
            .client,
            wayring.default_max_frame_size,
        );
        defer peer.deinit();
        const globals = try bindGlobals(&peer, client);
        const surface = try generated.wl_compositor_types.requests.create_surface(
            &peer,
            globals.compositor,
        );
        _ = try generated.wp_fifo_manager_v1_types.requests.get_fifo(
            &peer,
            globals.manager,
            surface,
        );
        _ = try generated.wp_fifo_manager_v1_types.requests.get_fifo(
            &peer,
            globals.manager,
            surface,
        );
        try std.testing.expectError(error.ProtocolError, transferToServer(&peer, client));
    }
}

const BoundGlobals = struct {
    compositor: wayring.ObjectHandle,
    manager: wayring.ObjectHandle,
};

fn bindGlobals(connection: *wayring.Connection, client: *Server.Client) !BoundGlobals {
    const core = @import("wayring-core");
    _ = try core.bootstrapDisplay(connection);
    const registry: wayring.ObjectHandle = .{
        .id = 2,
        .generation = try core.getRegistry(connection, 2),
    };
    try transferToServer(connection, client);
    try transferFromServer(connection, client);
    var compositor_name: u32 = 0;
    var manager_name: u32 = 0;
    while (connection.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const global = (try core.decodeRegistryEvent(&message, registry.id)).global;
        if (std.mem.eql(u8, global.interface, generated.wl_compositor.name))
            compositor_name = global.name;
        if (std.mem.eql(u8, global.interface, generated.wp_fifo_manager_v1.name))
            manager_name = global.name;
    }
    const compositor: wayring.ObjectHandle = .{
        .id = 3,
        .generation = try core.bind(
            connection,
            registry.id,
            compositor_name,
            generated.wl_compositor.name,
            6,
            3,
            &generated.wl_compositor,
        ),
    };
    const manager: wayring.ObjectHandle = .{
        .id = 4,
        .generation = try core.bind(
            connection,
            registry.id,
            manager_name,
            generated.wp_fifo_manager_v1.name,
            advertised_version,
            4,
            &generated.wp_fifo_manager_v1,
        ),
    };
    try transferToServer(connection, client);
    return .{ .compositor = compositor, .manager = manager };
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
