//! Native background-effect objects with truthful unsupported capabilities.

const BackgroundEffectGlobal = @This();

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
effect_count: usize = 0,

const Effect = struct {
    owner: *BackgroundEffectGlobal,
    surface: ?*CompositorGlobal.Surface,

    fn surfaceDestroyed(context: *anyopaque) void {
        const self: *Effect = @ptrCast(@alignCast(context));
        self.surface = null;
    }
};

pub fn init(
    self: *BackgroundEffectGlobal,
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
        &generated.ext_background_effect_manager_v1,
        advertised_version,
        .{ .context = self, .bind = bind },
    );
}

pub fn deinit(self: *BackgroundEffectGlobal) void {
    std.debug.assert(self.effect_count == 0);
    self.server.removeGlobal(self.global_name) catch unreachable;
    self.* = undefined;
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *BackgroundEffectGlobal = @ptrCast(@alignCast(context));
    const resource = client.createResource(
        id,
        &generated.ext_background_effect_manager_v1,
        version,
        .{ .context = self, .dispatch = dispatchManager },
    ) catch return client.postNoMemory();
    // Native rendering has no background blur. The protocol explicitly uses
    // capabilities to distinguish an unsupported effect from its object API.
    generated.ext_background_effect_manager_v1_types.events.capabilities(
        &client.connection,
        resource,
        0,
    ) catch return client.postNoMemory();
}

fn dispatchManager(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const self: *BackgroundEffectGlobal = @ptrCast(@alignCast(context));
    switch (try generated.ext_background_effect_manager_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .get_background_effect => |request| {
            const object = client.connection.object(request.surface) orelse
                return error.UnknownSurface;
            const surface = try CompositorGlobal.surfaceFor(client, .{
                .id = request.surface,
                .generation = object.generation,
            });
            if (surface.owner != self.compositor) return error.WrongSurface;
            if (surface.background_effect_handler != null) return client.postError(
                resource,
                @intFromEnum(
                    generated.ext_background_effect_manager_v1_types.@"error".background_effect_exists,
                ),
                "wl_surface already has a background effect object",
            );
            const effect = self.allocator.create(Effect) catch
                return client.postNoMemory();
            errdefer self.allocator.destroy(effect);
            effect.* = .{ .owner = self, .surface = surface };
            const version = try client.resourceVersion(
                resource,
                &generated.ext_background_effect_manager_v1,
            );
            _ = client.createResource(
                request.id,
                &generated.ext_background_effect_surface_v1,
                version,
                .{
                    .context = effect,
                    .dispatch = dispatchEffect,
                    .destroy = destroyEffect,
                },
            ) catch return client.postNoMemory();
            surface.setBackgroundEffectHandler(.{
                .context = effect,
                .surface_destroyed = Effect.surfaceDestroyed,
            }) catch unreachable;
            self.effect_count += 1;
        },
    }
}

fn dispatchEffect(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const self: *Effect = @ptrCast(@alignCast(context));
    switch (try generated.ext_background_effect_surface_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .set_blur_region => {
            if (self.surface == null) return client.postError(
                resource,
                @intFromEnum(
                    generated.ext_background_effect_surface_v1_types.@"error".surface_destroyed,
                ),
                "wl_surface has been destroyed",
            );
            // With blur permanently unsupported, the region is unobservable.
            // Add double-buffered state before ever advertising the capability.
        },
    }
}

fn destroyEffect(
    context: *anyopaque,
    _: *Server.Client,
    _: wayring.ObjectHandle,
) void {
    const self: *Effect = @ptrCast(@alignCast(context));
    if (self.surface) |surface| surface.clearBackgroundEffectHandler(self);
    const owner = self.owner;
    owner.effect_count -= 1;
    owner.allocator.destroy(self);
}

test "native background effects advertise no blur and preserve object lifetimes" {
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var compositor: CompositorGlobal = undefined;
    try compositor.init(std.testing.allocator, &server);
    defer compositor.deinit();
    var effects: BackgroundEffectGlobal = undefined;
    try effects.init(std.testing.allocator, &server, &compositor);
    defer effects.deinit();

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
        const region = try generated.wl_compositor_types.requests.create_region(
            &peer,
            globals.compositor,
        );
        const effect = try generated.ext_background_effect_manager_v1_types.requests
            .get_background_effect(&peer, globals.manager, surface);
        try generated.ext_background_effect_manager_v1_types.requests.destroy(
            &peer,
            globals.manager,
        );
        try generated.ext_background_effect_surface_v1_types.requests.set_blur_region(
            &peer,
            effect,
            region,
        );
        try generated.ext_background_effect_surface_v1_types.requests.set_blur_region(
            &peer,
            effect,
            null,
        );
        try generated.ext_background_effect_surface_v1_types.requests.destroy(&peer, effect);
        try generated.wl_region_types.requests.destroy(&peer, region);
        try generated.wl_surface_types.requests.destroy(&peer, surface);
        try transferToServer(&peer, client);
        try std.testing.expectEqual(Server.ClientState.active, client.state);
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
        _ = try generated.ext_background_effect_manager_v1_types.requests
            .get_background_effect(&peer, globals.manager, surface);
        _ = try generated.ext_background_effect_manager_v1_types.requests
            .get_background_effect(&peer, globals.manager, surface);
        try std.testing.expectError(error.ProtocolError, transferToServer(&peer, client));
        try transferFromServer(&peer, client);
        try expectDisplayError(
            &peer,
            globals.manager.id,
            @intFromEnum(
                generated.ext_background_effect_manager_v1_types.@"error".background_effect_exists,
            ),
        );
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
        const effect = try generated.ext_background_effect_manager_v1_types.requests
            .get_background_effect(&peer, globals.manager, surface);
        try generated.wl_surface_types.requests.destroy(&peer, surface);
        try generated.ext_background_effect_surface_v1_types.requests.set_blur_region(
            &peer,
            effect,
            null,
        );
        try std.testing.expectError(error.ProtocolError, transferToServer(&peer, client));
        try transferFromServer(&peer, client);
        try expectDisplayError(
            &peer,
            effect.id,
            @intFromEnum(
                generated.ext_background_effect_surface_v1_types.@"error".surface_destroyed,
            ),
        );
    }
}

const BoundGlobals = struct {
    compositor: wayring.ObjectHandle,
    manager: wayring.ObjectHandle,
};

fn bindGlobals(
    connection: *wayring.Connection,
    client: *Server.Client,
) !BoundGlobals {
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
        if (std.mem.eql(
            u8,
            global.interface,
            generated.ext_background_effect_manager_v1.name,
        )) {
            try std.testing.expectEqual(advertised_version, global.version);
            manager_name = global.name;
        }
    }
    try std.testing.expect(compositor_name != 0);
    try std.testing.expect(manager_name != 0);
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
            generated.ext_background_effect_manager_v1.name,
            advertised_version,
            4,
            &generated.ext_background_effect_manager_v1,
        ),
    };
    try transferToServer(connection, client);
    try transferFromServer(connection, client);
    var found_capabilities = false;
    while (connection.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id != manager.id) continue;
        const event = try generated.ext_background_effect_manager_v1_types.decodeEvent(
            connection,
            manager,
            &message,
        );
        try std.testing.expectEqual(@as(u32, 0), event.capabilities.flags);
        found_capabilities = true;
    }
    try std.testing.expect(found_capabilities);
    return .{ .compositor = compositor, .manager = manager };
}

fn expectDisplayError(peer: *wayring.Connection, object_id: u32, code: u32) !void {
    const core = @import("wayring-core");
    var found = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id != 1) continue;
        switch (try core.decodeDisplayEvent(&message)) {
            .error_event => |event| if (event.object_id == object_id and event.code == code) {
                found = true;
            },
            .delete_id => {},
        }
    }
    try std.testing.expect(found);
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
