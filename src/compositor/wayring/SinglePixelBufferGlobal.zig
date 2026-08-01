//! Native `wp_single_pixel_buffer_manager_v1` immutable buffers.

const SinglePixelBufferGlobal = @This();

const std = @import("std");
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const BufferResource = @import("BufferResource.zig");
const CompositorGlobal = @import("CompositorGlobal.zig");

const advertised_version: u32 = 1;

allocator: std.mem.Allocator,
server: *Server,
global_name: u32,

pub fn init(
    self: *SinglePixelBufferGlobal,
    allocator: std.mem.Allocator,
    server: *Server,
) !void {
    self.* = .{
        .allocator = allocator,
        .server = server,
        .global_name = undefined,
    };
    self.global_name = try server.createGlobal(
        &generated.wp_single_pixel_buffer_manager_v1,
        advertised_version,
        .{ .context = self, .bind = bind },
    );
}

pub fn deinit(self: *SinglePixelBufferGlobal) void {
    self.server.removeGlobal(self.global_name) catch unreachable;
    self.* = undefined;
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *SinglePixelBufferGlobal = @ptrCast(@alignCast(context));
    _ = client.createResource(id, &generated.wp_single_pixel_buffer_manager_v1, version, .{
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
    const self: *SinglePixelBufferGlobal = @ptrCast(@alignCast(context));
    switch (try generated.wp_single_pixel_buffer_manager_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .create_u32_rgba_buffer => |request| {
            const buffer = self.allocator.create(BufferResource) catch
                return client.postNoMemory();
            errdefer self.allocator.destroy(buffer);
            buffer.* = .{
                .allocator = self.allocator,
                .content = .{ .single_pixel = pixelFromComponents(
                    request.r,
                    request.g,
                    request.b,
                    request.a,
                ) },
            };
            _ = client.createResource(request.id, &generated.wl_buffer, 1, .{
                .context = buffer,
                .dispatch = dispatchBuffer,
                .destroy = destroyBuffer,
            }) catch return client.postNoMemory();
        },
    }
}

fn dispatchBuffer(
    _: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    _ = try generated.wl_buffer_types.decodeRequest(&client.connection, resource, message);
}

fn destroyBuffer(
    context: *anyopaque,
    _: *Server.Client,
    _: wayring.ObjectHandle,
) void {
    const buffer: *BufferResource = @ptrCast(@alignCast(context));
    buffer.unreference();
}

fn pixelFromComponents(red: u32, green: u32, blue: u32, alpha: u32) u32 {
    // The protocol channels are already premultiplied and map directly to
    // the ARGB8888 snapshot layout consumed by the renderer.
    return @as(u32, component(alpha)) << 24 |
        @as(u32, component(red)) << 16 |
        @as(u32, component(green)) << 8 |
        component(blue);
}

fn component(value: u32) u8 {
    const maximum = std.math.maxInt(u32);
    return @intCast((@as(u64, value) * 255 + maximum / 2) / maximum);
}

test "native single pixel buffers survive manager destruction and can be reused" {
    const core = @import("wayring-core");
    try std.testing.expectEqual(@as(u32, 0), pixelFromComponents(0, 0, 0, 0));
    try std.testing.expectEqual(
        @as(u32, 0xffff_ffff),
        pixelFromComponents(
            std.math.maxInt(u32),
            std.math.maxInt(u32),
            std.math.maxInt(u32),
            std.math.maxInt(u32),
        ),
    );
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var compositor: CompositorGlobal = undefined;
    try compositor.init(std.testing.allocator, &server);
    defer compositor.deinit();
    var buffers: SinglePixelBufferGlobal = undefined;
    try buffers.init(std.testing.allocator, &server);
    defer buffers.deinit();
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
            generated.wp_single_pixel_buffer_manager_v1.name,
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
            generated.wp_single_pixel_buffer_manager_v1.name,
            advertised_version,
            4,
            &generated.wp_single_pixel_buffer_manager_v1,
        ),
    };
    try transferToServer(&peer, client);

    const surface = try generated.wl_compositor_types.requests.create_surface(
        &peer,
        compositor_resource,
    );
    const buffer = try generated.wp_single_pixel_buffer_manager_v1_types.requests
        .create_u32_rgba_buffer(
        &peer,
        manager_resource,
        0x8000_0000,
        0x8000_0000,
        0,
        0x8000_0000,
    );
    try generated.wp_single_pixel_buffer_manager_v1_types.requests.destroy(
        &peer,
        manager_resource,
    );
    try generated.wl_surface_types.requests.attach(&peer, surface, buffer, 0, 0);
    try generated.wl_surface_types.requests.commit(&peer, surface);
    try transferToServer(&peer, client);

    var first = compositor.popTransaction() orelse return error.MissingCommit;
    var first_owned = true;
    defer if (first_owned) first.deinit();
    const first_attachment = switch (first.entries[0].attachment) {
        .buffer => |attachment| attachment,
        .unchanged, .removed => return error.MissingAttachment,
    };
    try std.testing.expectEqual(
        @as(u32, 0x8080_8000),
        first_attachment.buffer.content.single_pixel,
    );
    first.releaseBuffers();
    first.deinit();
    first_owned = false;
    try transferFromServer(&peer, client);
    try expectOneRelease(&peer, buffer);

    try generated.wl_surface_types.requests.attach(&peer, surface, buffer, 0, 0);
    try generated.wl_surface_types.requests.commit(&peer, surface);
    try transferToServer(&peer, client);
    var reused = compositor.popTransaction() orelse return error.MissingCommit;
    var reused_owned = true;
    defer if (reused_owned) reused.deinit();
    reused.releaseBuffers();
    reused.deinit();
    reused_owned = false;
    try transferFromServer(&peer, client);
    try expectOneRelease(&peer, buffer);

    try generated.wl_buffer_types.requests.destroy(&peer, buffer);
    try generated.wl_surface_types.requests.destroy(&peer, surface);
    try transferToServer(&peer, client);
}

fn expectOneRelease(
    peer: *wayring.Connection,
    buffer: wayring.ObjectHandle,
) !void {
    const core = @import("wayring-core");
    var release_count: usize = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == buffer.id) {
            switch (try generated.wl_buffer_types.decodeEvent(peer, buffer, &message)) {
                .release => release_count += 1,
            }
        } else {
            _ = try core.decodeDisplayEvent(&message);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), release_count);
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
