//! Native `wp_color_representation_manager_v1` buffer interpretation metadata.

const ColorRepresentationGlobal = @This();

const std = @import("std");
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const CompositorGlobal = @import("CompositorGlobal.zig");
const render = @import("../render/types.zig");

const advertised_version: u32 = 1;
const SurfaceProtocol = generated.wp_color_representation_surface_v1_types;
const AlphaMode = SurfaceProtocol.alpha_mode;
const Coefficients = SurfaceProtocol.coefficients;
const Range = SurfaceProtocol.range;
const ChromaLocation = SurfaceProtocol.chroma_location;

allocator: std.mem.Allocator,
server: *Server,
compositor: *CompositorGlobal,
global_name: u32,
object_count: usize = 0,

const Representation = struct {
    owner: *ColorRepresentationGlobal,
    surface: ?*CompositorGlobal.Surface,
    resource: wayring.ObjectHandle,
    state: CompositorGlobal.ColorRepresentationState,

    fn surfaceDestroyed(context: *anyopaque) void {
        const self: *Representation = @ptrCast(@alignCast(context));
        self.surface = null;
    }
};

pub fn init(
    self: *ColorRepresentationGlobal,
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
        &generated.wp_color_representation_manager_v1,
        advertised_version,
        .{ .context = self, .bind = bind },
    );
}

pub fn deinit(self: *ColorRepresentationGlobal) void {
    std.debug.assert(self.object_count == 0);
    self.server.removeGlobal(self.global_name) catch unreachable;
    self.* = undefined;
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *ColorRepresentationGlobal = @ptrCast(@alignCast(context));
    const resource = client.createResource(
        id,
        &generated.wp_color_representation_manager_v1,
        version,
        .{ .context = self, .dispatch = dispatchManager },
    ) catch return client.postNoMemory();
    try generated.wp_color_representation_manager_v1_types.events.supported_alpha_mode(
        &client.connection,
        resource,
        @intFromEnum(AlphaMode.premultiplied_electrical),
    );
    try sendCoefficients(client, resource, .identity, .full);
    inline for (.{ Coefficients.bt601, .bt709, .bt2020 }) |coefficients| {
        try sendCoefficients(client, resource, coefficients, .full);
        try sendCoefficients(client, resource, coefficients, .limited);
    }
    try generated.wp_color_representation_manager_v1_types.events.done(
        &client.connection,
        resource,
    );
}

fn sendCoefficients(
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    coefficients: Coefficients,
    range: Range,
) !void {
    try generated.wp_color_representation_manager_v1_types.events
        .supported_coefficients_and_ranges(
        &client.connection,
        resource,
        @intFromEnum(coefficients),
        @intFromEnum(range),
    );
}

fn dispatchManager(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const self: *ColorRepresentationGlobal = @ptrCast(@alignCast(context));
    switch (try generated.wp_color_representation_manager_v1_types.decodeRequest(
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
            if (surface.color_representation_handler != null) return client.postError(
                resource,
                @intFromEnum(
                    generated.wp_color_representation_manager_v1_types.@"error".surface_exists,
                ),
                "wl_surface already has a color representation object",
            );
            const representation = self.allocator.create(Representation) catch
                return client.postNoMemory();
            errdefer self.allocator.destroy(representation);
            const version = try client.resourceVersion(
                resource,
                &generated.wp_color_representation_manager_v1,
            );
            const child_resource = client.createResource(
                request.id,
                &generated.wp_color_representation_surface_v1,
                version,
                .{
                    .context = representation,
                    .dispatch = dispatchRepresentation,
                    .destroy = destroyRepresentation,
                },
            ) catch return client.postNoMemory();
            representation.* = .{
                .owner = self,
                .surface = surface,
                .resource = child_resource,
                .state = surface.pending_color_representation,
            };
            surface.setColorRepresentationHandler(.{
                .context = representation,
                .surface_destroyed = Representation.surfaceDestroyed,
                .validate_commit = validateCommit,
            }) catch unreachable;
            self.object_count += 1;
        },
    }
}

fn dispatchRepresentation(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const self: *Representation = @ptrCast(@alignCast(context));
    switch (try SurfaceProtocol.decodeRequest(&client.connection, resource, message)) {
        .destroy => {},
        .set_alpha_mode => |request| {
            const surface = self.surface orelse return client.postError(
                resource,
                @intFromEnum(SurfaceProtocol.@"error".inert),
                "wl_surface has been destroyed",
            );
            const alpha_mode: AlphaMode = @enumFromInt(request.alpha_mode);
            if (!supportedAlpha(alpha_mode)) return client.postError(
                resource,
                @intFromEnum(SurfaceProtocol.@"error".alpha_mode),
                "unsupported alpha mode",
            );
            self.state.alpha_mode = alpha_mode;
            surface.pending_color_representation = self.state;
        },
        .set_coefficients_and_range => |request| {
            const surface = self.surface orelse return client.postError(
                resource,
                @intFromEnum(SurfaceProtocol.@"error".inert),
                "wl_surface has been destroyed",
            );
            const coefficients: Coefficients = @enumFromInt(request.coefficients);
            const range: Range = @enumFromInt(request.range);
            if (!supportedCoefficients(coefficients, range)) return client.postError(
                resource,
                @intFromEnum(SurfaceProtocol.@"error".coefficients),
                "unsupported coefficients and range",
            );
            self.state.coefficients = coefficients;
            self.state.range = range;
            surface.pending_color_representation = self.state;
        },
        .set_chroma_location => |request| {
            const surface = self.surface orelse return client.postError(
                resource,
                @intFromEnum(SurfaceProtocol.@"error".inert),
                "wl_surface has been destroyed",
            );
            const chroma_location: ChromaLocation = @enumFromInt(request.chroma_location);
            if (!validChroma(chroma_location)) return client.postError(
                resource,
                @intFromEnum(SurfaceProtocol.@"error".chroma_location),
                "invalid chroma location",
            );
            self.state.chroma_location = chroma_location;
            surface.pending_color_representation = self.state;
        },
    }
}

fn destroyRepresentation(
    context: *anyopaque,
    _: *Server.Client,
    _: wayring.ObjectHandle,
) void {
    const self: *Representation = @ptrCast(@alignCast(context));
    if (self.surface) |surface| surface.clearColorRepresentationHandler(self);
    const owner = self.owner;
    owner.object_count -= 1;
    owner.allocator.destroy(self);
}

fn validateCommit(
    context: *anyopaque,
    state: CompositorGlobal.ColorRepresentationState,
    format: ?render.DmabufFormat,
) bool {
    const self: *Representation = @ptrCast(@alignCast(context));
    if (commitCompatible(state, format)) return true;
    self.surface.?.client.postError(
        self.resource,
        @intFromEnum(SurfaceProtocol.@"error".pixel_format),
        "color representation is incompatible with the buffer format",
    ) catch {};
    return false;
}

fn supportedAlpha(alpha_mode: AlphaMode) bool {
    return alpha_mode == .premultiplied_electrical;
}

fn supportedCoefficients(coefficients: Coefficients, range: Range) bool {
    return switch (coefficients) {
        .identity => range == .full,
        .bt601, .bt709, .bt2020 => range == .full or range == .limited,
        else => false,
    };
}

fn validChroma(chroma_location: ChromaLocation) bool {
    return switch (chroma_location) {
        .type_0, .type_1, .type_2, .type_3, .type_4, .type_5 => true,
        else => false,
    };
}

fn commitCompatible(
    state: CompositorGlobal.ColorRepresentationState,
    format: ?render.DmabufFormat,
) bool {
    const buffer_format = format orelse return true;
    if ((state.coefficients == null) != (state.range == null)) return false;
    if (buffer_format.isPackedRgb()) {
        return state.chroma_location == null and
            (state.coefficients == null or
                (state.coefficients == .identity and state.range == .full));
    }
    return state.coefficients == null or
        (state.coefficients != .identity and
            supportedCoefficients(state.coefficients.?, state.range.?));
}

test "native color representation capabilities, state, and lifecycle" {
    const core = @import("wayring-core");
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var compositor: CompositorGlobal = undefined;
    try compositor.init(std.testing.allocator, &server);
    defer compositor.deinit();
    var representations: ColorRepresentationGlobal = undefined;
    try representations.init(std.testing.allocator, &server, &compositor);
    defer representations.deinit();
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
        if (std.mem.eql(
            u8,
            global.interface,
            generated.wp_color_representation_manager_v1.name,
        )) manager_name = global.name;
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
            generated.wp_color_representation_manager_v1.name,
            advertised_version,
            4,
            &generated.wp_color_representation_manager_v1,
        ),
    };
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    var alpha_count: usize = 0;
    var coefficients_count: usize = 0;
    var done_count: usize = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        switch (try generated.wp_color_representation_manager_v1_types.decodeEvent(
            &peer,
            manager_resource,
            &message,
        )) {
            .supported_alpha_mode => |event| {
                try std.testing.expectEqual(
                    @intFromEnum(AlphaMode.premultiplied_electrical),
                    event.alpha_mode,
                );
                alpha_count += 1;
            },
            .supported_coefficients_and_ranges => coefficients_count += 1,
            .done => done_count += 1,
        }
    }
    try std.testing.expectEqual(@as(usize, 1), alpha_count);
    try std.testing.expectEqual(@as(usize, 7), coefficients_count);
    try std.testing.expectEqual(@as(usize, 1), done_count);

    const surface = try generated.wl_compositor_types.requests.create_surface(
        &peer,
        compositor_resource,
    );
    const representation = try generated.wp_color_representation_manager_v1_types.requests
        .get_surface(&peer, manager_resource, surface);
    try generated.wp_color_representation_manager_v1_types.requests.destroy(
        &peer,
        manager_resource,
    );
    try SurfaceProtocol.requests.set_alpha_mode(
        &peer,
        representation,
        @intFromEnum(AlphaMode.premultiplied_electrical),
    );
    try SurfaceProtocol.requests.set_coefficients_and_range(
        &peer,
        representation,
        @intFromEnum(Coefficients.bt2020),
        @intFromEnum(Range.full),
    );
    try SurfaceProtocol.requests.set_chroma_location(
        &peer,
        representation,
        @intFromEnum(ChromaLocation.type_3),
    );
    try generated.wl_surface_types.requests.commit(&peer, surface);
    try generated.wl_surface_types.requests.commit(&peer, surface);
    try transferToServer(&peer, client);
    var first = compositor.popTransaction() orelse return error.MissingCommit;
    defer first.deinit();
    var second = compositor.popTransaction() orelse return error.MissingCommit;
    defer second.deinit();
    const expected: CompositorGlobal.ColorRepresentationState = .{
        .alpha_mode = .premultiplied_electrical,
        .coefficients = .bt2020,
        .range = .full,
        .chroma_location = .type_3,
    };
    try std.testing.expectEqual(expected, first.entries[0].color_representation);
    try std.testing.expectEqual(expected, second.entries[0].color_representation);

    try SurfaceProtocol.requests.destroy(&peer, representation);
    try generated.wl_surface_types.requests.commit(&peer, surface);
    try transferToServer(&peer, client);
    var reset = compositor.popTransaction() orelse return error.MissingCommit;
    defer reset.deinit();
    try std.testing.expectEqual(
        CompositorGlobal.ColorRepresentationState{},
        reset.entries[0].color_representation,
    );

    const second_manager: wayring.ObjectHandle = .{
        .id = 20,
        .generation = try core.bind(
            &peer,
            registry.id,
            manager_name,
            generated.wp_color_representation_manager_v1.name,
            advertised_version,
            20,
            &generated.wp_color_representation_manager_v1,
        ),
    };
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    while (peer.popMessage()) |popped| {
        var message = popped;
        message.deinit();
    }
    const inert = try generated.wp_color_representation_manager_v1_types.requests
        .get_surface(&peer, second_manager, surface);
    try generated.wl_surface_types.requests.destroy(&peer, surface);
    try SurfaceProtocol.requests.set_chroma_location(
        &peer,
        inert,
        @intFromEnum(ChromaLocation.type_0),
    );
    try std.testing.expectError(error.ProtocolError, transferToServer(&peer, client));
}

test "color representation validation matches RGB and YCbCr formats" {
    try std.testing.expect(supportedAlpha(.premultiplied_electrical));
    try std.testing.expect(!supportedAlpha(.premultiplied_optical));
    try std.testing.expect(supportedCoefficients(.identity, .full));
    try std.testing.expect(!supportedCoefficients(.identity, .limited));
    try std.testing.expect(supportedCoefficients(.bt709, .limited));
    try std.testing.expect(!supportedCoefficients(.bt2020_cl, .limited));
    inline for (.{
        ChromaLocation.type_0,
        .type_1,
        .type_2,
        .type_3,
        .type_4,
        .type_5,
    }) |chroma_location| try std.testing.expect(validChroma(chroma_location));

    var state: CompositorGlobal.ColorRepresentationState = .{ .chroma_location = .type_3 };
    try std.testing.expect(commitCompatible(state, null));
    try std.testing.expect(!commitCompatible(state, .argb8888));
    try std.testing.expect(commitCompatible(state, .nv12));
    state.chroma_location = null;
    state.coefficients = .bt709;
    state.range = .limited;
    try std.testing.expect(!commitCompatible(state, .argb8888));
    try std.testing.expect(commitCompatible(state, .p010));
    state.coefficients = .identity;
    state.range = .full;
    try std.testing.expect(commitCompatible(state, .argb8888));
    try std.testing.expect(!commitCompatible(state, .nv12));

    const default_video = (CompositorGlobal.ColorRepresentationState{}).toRender(.nv12);
    try std.testing.expectEqual(render.ColorCoefficients.bt709, default_video.coefficients);
    try std.testing.expectEqual(render.ColorRange.limited, default_video.range);
    try std.testing.expectEqual(render.ChromaLocation.type_0, default_video.chroma_location.?);
    const explicit_video: CompositorGlobal.ColorRepresentationState = .{
        .coefficients = .bt2020,
        .range = .full,
        .chroma_location = .type_3,
    };
    try std.testing.expectEqual(
        render.ColorRepresentation{
            .coefficients = .bt2020,
            .range = .full,
            .chroma_location = .type_3,
        },
        explicit_video.toRender(.p010),
    );
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
