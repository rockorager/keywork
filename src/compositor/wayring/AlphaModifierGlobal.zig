//! Native `wp_alpha_modifier_v1` per-surface opacity.

const AlphaModifierGlobal = @This();

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
object_count: usize = 0,

const Modifier = struct {
    owner: *AlphaModifierGlobal,
    surface: ?*CompositorGlobal.Surface,

    fn surfaceDestroyed(context: *anyopaque) void {
        const self: *Modifier = @ptrCast(@alignCast(context));
        self.surface = null;
    }
};

pub fn init(
    self: *AlphaModifierGlobal,
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
        &generated.wp_alpha_modifier_v1,
        advertised_version,
        .{ .context = self, .bind = bind },
    );
}

pub fn deinit(self: *AlphaModifierGlobal) void {
    std.debug.assert(self.object_count == 0);
    self.server.removeGlobal(self.global_name) catch unreachable;
    self.* = undefined;
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *AlphaModifierGlobal = @ptrCast(@alignCast(context));
    _ = client.createResource(id, &generated.wp_alpha_modifier_v1, version, .{
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
    const self: *AlphaModifierGlobal = @ptrCast(@alignCast(context));
    switch (try generated.wp_alpha_modifier_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .get_surface => |request| {
            const object = client.connection.object(request.surface) orelse
                return error.UnknownSurface;
            const surface = try CompositorGlobal.surfaceFor(client, .{
                .id = request.surface,
                .generation = object.generation,
            });
            if (surface.owner != self.compositor) return error.WrongSurface;
            if (surface.alpha_modifier_handler != null) return client.postError(
                resource,
                @intFromEnum(
                    generated.wp_alpha_modifier_v1_types.@"error".already_constructed,
                ),
                "wl_surface already has an alpha modifier object",
            );
            const modifier = self.allocator.create(Modifier) catch
                return client.postNoMemory();
            errdefer self.allocator.destroy(modifier);
            const version = try client.resourceVersion(resource, &generated.wp_alpha_modifier_v1);
            _ = client.createResource(
                request.id,
                &generated.wp_alpha_modifier_surface_v1,
                version,
                .{
                    .context = modifier,
                    .dispatch = dispatchModifier,
                    .destroy = destroyModifier,
                },
            ) catch return client.postNoMemory();
            modifier.* = .{ .owner = self, .surface = surface };
            surface.setAlphaModifierHandler(.{
                .context = modifier,
                .surface_destroyed = Modifier.surfaceDestroyed,
            }) catch unreachable;
            self.object_count += 1;
        },
    }
}

fn dispatchModifier(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const self: *Modifier = @ptrCast(@alignCast(context));
    switch (try generated.wp_alpha_modifier_surface_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .set_multiplier => |request| {
            const surface = self.surface orelse return client.postError(
                resource,
                @intFromEnum(
                    generated.wp_alpha_modifier_surface_v1_types.@"error".no_surface,
                ),
                "wl_surface has been destroyed",
            );
            surface.pending_alpha_multiplier = request.factor;
        },
    }
}

fn destroyModifier(
    context: *anyopaque,
    _: *Server.Client,
    _: wayring.ObjectHandle,
) void {
    const self: *Modifier = @ptrCast(@alignCast(context));
    if (self.surface) |surface| surface.clearAlphaModifierHandler(self);
    const owner = self.owner;
    owner.object_count -= 1;
    owner.allocator.destroy(self);
}

test "native alpha modifier is double buffered and object scoped" {
    const core = @import("wayring-core");
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var compositor: CompositorGlobal = undefined;
    try compositor.init(std.testing.allocator, &server);
    defer compositor.deinit();
    var alpha_modifiers: AlphaModifierGlobal = undefined;
    try alpha_modifiers.init(std.testing.allocator, &server, &compositor);
    defer alpha_modifiers.deinit();
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
    var manager_name: u32 = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const global = (try core.decodeRegistryEvent(&message, registry.id)).global;
        if (std.mem.eql(u8, global.interface, generated.wl_compositor.name))
            compositor_name = global.name;
        if (std.mem.eql(u8, global.interface, generated.wp_alpha_modifier_v1.name))
            manager_name = global.name;
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
    const manager_resource: wayring.ObjectHandle = .{
        .id = 4,
        .generation = try core.bind(
            &peer,
            registry.id,
            manager_name,
            generated.wp_alpha_modifier_v1.name,
            1,
            4,
            &generated.wp_alpha_modifier_v1,
        ),
    };
    try transferToServer(&peer, client);
    const surface = try generated.wl_compositor_types.requests.create_surface(
        &peer,
        compositor_resource,
    );
    const modifier = try generated.wp_alpha_modifier_v1_types.requests.get_surface(
        &peer,
        manager_resource,
        surface,
    );
    try generated.wp_alpha_modifier_surface_v1_types.requests.set_multiplier(
        &peer,
        modifier,
        0x8000_0000,
    );
    try generated.wl_surface_types.requests.commit(&peer, surface);
    try generated.wl_surface_types.requests.commit(&peer, surface);
    try transferToServer(&peer, client);
    var first = compositor.popTransaction() orelse return error.MissingCommit;
    defer first.deinit();
    var second = compositor.popTransaction() orelse return error.MissingCommit;
    defer second.deinit();
    try std.testing.expectEqual(@as(u32, 0x8000_0000), first.entries[0].alpha_multiplier);
    try std.testing.expectEqual(first.entries[0].alpha_multiplier, second.entries[0].alpha_multiplier);

    try generated.wp_alpha_modifier_surface_v1_types.requests.destroy(&peer, modifier);
    try generated.wl_surface_types.requests.commit(&peer, surface);
    try transferToServer(&peer, client);
    var reset = compositor.popTransaction() orelse return error.MissingCommit;
    defer reset.deinit();
    try std.testing.expectEqual(std.math.maxInt(u32), reset.entries[0].alpha_multiplier);

    const inert = try generated.wp_alpha_modifier_v1_types.requests.get_surface(
        &peer,
        manager_resource,
        surface,
    );
    try generated.wl_surface_types.requests.destroy(&peer, surface);
    try generated.wp_alpha_modifier_surface_v1_types.requests.set_multiplier(
        &peer,
        inert,
        0,
    );
    try std.testing.expectError(error.ProtocolError, transferToServer(&peer, client));
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
