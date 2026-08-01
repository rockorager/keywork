//! Native `wp_tearing_control_manager_v1` surface hints.

const TearingControlGlobal = @This();

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
control_count: usize = 0,

const Control = struct {
    owner: *TearingControlGlobal,
    surface: ?*CompositorGlobal.Surface,

    fn surfaceDestroyed(context: *anyopaque) void {
        const self: *Control = @ptrCast(@alignCast(context));
        self.surface = null;
    }
};

pub fn init(
    self: *TearingControlGlobal,
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
        &generated.wp_tearing_control_manager_v1,
        advertised_version,
        .{ .context = self, .bind = bind },
    );
}

pub fn deinit(self: *TearingControlGlobal) void {
    std.debug.assert(self.control_count == 0);
    self.server.removeGlobal(self.global_name) catch unreachable;
    self.* = undefined;
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *TearingControlGlobal = @ptrCast(@alignCast(context));
    _ = client.createResource(id, &generated.wp_tearing_control_manager_v1, version, .{
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
    const self: *TearingControlGlobal = @ptrCast(@alignCast(context));
    switch (try generated.wp_tearing_control_manager_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .get_tearing_control => |request| {
            const object = client.connection.object(request.surface) orelse
                return error.UnknownSurface;
            const surface = try CompositorGlobal.surfaceFor(client, .{
                .id = request.surface,
                .generation = object.generation,
            });
            if (surface.owner != self.compositor) return error.WrongSurface;
            if (surface.tearing_control_handler != null) return client.postError(
                resource,
                @intFromEnum(
                    generated.wp_tearing_control_manager_v1_types.@"error".tearing_control_exists,
                ),
                "wl_surface already has a tearing control object",
            );
            const control = self.allocator.create(Control) catch
                return client.postNoMemory();
            errdefer self.allocator.destroy(control);
            const version = try client.resourceVersion(
                resource,
                &generated.wp_tearing_control_manager_v1,
            );
            _ = client.createResource(
                request.id,
                &generated.wp_tearing_control_v1,
                version,
                .{
                    .context = control,
                    .dispatch = dispatchControl,
                    .destroy = destroyControl,
                },
            ) catch return client.postNoMemory();
            control.* = .{ .owner = self, .surface = surface };
            surface.setTearingControlHandler(.{
                .context = control,
                .surface_destroyed = Control.surfaceDestroyed,
            }) catch unreachable;
            self.control_count += 1;
        },
    }
}

fn dispatchControl(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const self: *Control = @ptrCast(@alignCast(context));
    switch (try generated.wp_tearing_control_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .set_presentation_hint => |request| {
            const surface = self.surface orelse return;
            surface.pending_presentation_hint = normalizeHint(request.hint);
        },
    }
}

fn destroyControl(
    context: *anyopaque,
    _: *Server.Client,
    _: wayring.ObjectHandle,
) void {
    const self: *Control = @ptrCast(@alignCast(context));
    if (self.surface) |surface| surface.resetTearingControl(self);
    const owner = self.owner;
    owner.control_count -= 1;
    owner.allocator.destroy(self);
}

fn normalizeHint(value: u32) CompositorGlobal.PresentationHint {
    return if (value == @intFromEnum(CompositorGlobal.PresentationHint.async))
        .async
    else
        .vsync;
}

test "native tearing hints are double buffered and object scoped" {
    const core = @import("wayring-core");
    try std.testing.expectEqual(CompositorGlobal.PresentationHint.vsync, normalizeHint(99));
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var compositor: CompositorGlobal = undefined;
    try compositor.init(std.testing.allocator, &server);
    defer compositor.deinit();
    var tearing: TearingControlGlobal = undefined;
    try tearing.init(std.testing.allocator, &server, &compositor);
    defer tearing.deinit();
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
        if (std.mem.eql(u8, global.interface, generated.wp_tearing_control_manager_v1.name))
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
            generated.wp_tearing_control_manager_v1.name,
            advertised_version,
            4,
            &generated.wp_tearing_control_manager_v1,
        ),
    };
    try transferToServer(&peer, client);
    const surface = try generated.wl_compositor_types.requests.create_surface(
        &peer,
        compositor_resource,
    );
    const control = try generated.wp_tearing_control_manager_v1_types.requests
        .get_tearing_control(&peer, manager_resource, surface);
    try generated.wp_tearing_control_v1_types.requests.set_presentation_hint(
        &peer,
        control,
        @intFromEnum(CompositorGlobal.PresentationHint.async),
    );
    try generated.wl_surface_types.requests.commit(&peer, surface);
    try generated.wl_surface_types.requests.commit(&peer, surface);
    try transferToServer(&peer, client);
    var first = compositor.popTransaction() orelse return error.MissingCommit;
    defer first.deinit();
    var second = compositor.popTransaction() orelse return error.MissingCommit;
    defer second.deinit();
    try std.testing.expectEqual(
        CompositorGlobal.PresentationHint.async,
        first.entries[0].presentation_hint,
    );
    try std.testing.expectEqual(
        first.entries[0].presentation_hint,
        second.entries[0].presentation_hint,
    );

    try generated.wp_tearing_control_v1_types.requests.destroy(&peer, control);
    try generated.wl_surface_types.requests.commit(&peer, surface);
    try transferToServer(&peer, client);
    var reset = compositor.popTransaction() orelse return error.MissingCommit;
    defer reset.deinit();
    try std.testing.expectEqual(
        CompositorGlobal.PresentationHint.vsync,
        reset.entries[0].presentation_hint,
    );

    const inert = try generated.wp_tearing_control_manager_v1_types.requests
        .get_tearing_control(&peer, manager_resource, surface);
    try generated.wl_surface_types.requests.destroy(&peer, surface);
    try generated.wp_tearing_control_v1_types.requests.set_presentation_hint(
        &peer,
        inert,
        @intFromEnum(CompositorGlobal.PresentationHint.async),
    );
    try generated.wp_tearing_control_v1_types.requests.destroy(&peer, inert);
    try transferToServer(&peer, client);
    try std.testing.expectEqual(Server.ClientState.active, client.state);

    const duplicate_surface = try generated.wl_compositor_types.requests.create_surface(
        &peer,
        compositor_resource,
    );
    _ = try generated.wp_tearing_control_manager_v1_types.requests.get_tearing_control(
        &peer,
        manager_resource,
        duplicate_surface,
    );
    _ = try generated.wp_tearing_control_manager_v1_types.requests.get_tearing_control(
        &peer,
        manager_resource,
        duplicate_surface,
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
