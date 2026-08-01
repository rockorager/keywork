//! Compositor-owned native `wl_shm` policy for Wayring clients.

const ShmGlobal = @This();

const std = @import("std");
const linux = std.os.linux;
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const shm = @import("shm.zig");
const BufferResource = @import("BufferResource.zig");

const advertised_version: u32 = 2;

allocator: std.mem.Allocator,
server: *Server,
global_name: u32,

const PoolResource = struct {
    allocator: std.mem.Allocator,
    shm_resource: wayring.ObjectHandle,
    pool: *shm.Pool,
};

pub fn init(self: *ShmGlobal, allocator: std.mem.Allocator, server: *Server) !void {
    self.* = .{
        .allocator = allocator,
        .server = server,
        .global_name = undefined,
    };
    self.global_name = try server.createGlobal(&generated.wl_shm, advertised_version, .{
        .context = self,
        .bind = bind,
    });
}

pub fn deinit(self: *ShmGlobal) void {
    self.server.removeGlobal(self.global_name) catch unreachable;
    self.* = undefined;
}

pub fn cloneBufferResource(
    client: *const Server.Client,
    handle: wayring.ObjectHandle,
) !*BufferResource {
    const resource: *BufferResource = @ptrCast(@alignCast(
        try client.resourceContext(handle, &generated.wl_buffer),
    ));
    try resource.reference();
    return resource;
}

pub fn releaseBuffer(
    client: *Server.Client,
    handle: wayring.ObjectHandle,
) !void {
    _ = try client.resourceContext(handle, &generated.wl_buffer);
    try generated.wl_buffer_types.events.release(&client.connection, handle);
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *ShmGlobal = @ptrCast(@alignCast(context));
    const resource = client.createResource(id, &generated.wl_shm, version, .{
        .context = self,
        .dispatch = dispatchShm,
    }) catch return client.postNoMemory();
    generated.wl_shm_types.events.format(
        &client.connection,
        resource,
        @intFromEnum(shm.Format.argb8888),
    ) catch return client.postNoMemory();
    generated.wl_shm_types.events.format(
        &client.connection,
        resource,
        @intFromEnum(shm.Format.xrgb8888),
    ) catch return client.postNoMemory();
}

fn dispatchShm(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const self: *ShmGlobal = @ptrCast(@alignCast(context));
    switch (try generated.wl_shm_types.decodeRequest(&client.connection, resource, message)) {
        .create_pool => |request| {
            const fd = try message.takeFd(request.fd);
            var fd_owned = true;
            defer if (fd_owned) {
                _ = linux.close(fd);
            };
            const pool = shm.Pool.create(self.allocator, fd, request.size, .{}) catch |err| switch (err) {
                error.InvalidPool => return client.postError(
                    resource,
                    @intFromEnum(generated.wl_shm_types.@"error".invalid_fd),
                    "invalid shared-memory pool",
                ),
                error.OutOfMemory => return client.postNoMemory(),
            };
            fd_owned = false;
            errdefer pool.unreference();
            const pool_resource = self.allocator.create(PoolResource) catch
                return client.postNoMemory();
            errdefer self.allocator.destroy(pool_resource);
            pool_resource.* = .{
                .allocator = self.allocator,
                .shm_resource = resource,
                .pool = pool,
            };
            const version = @min(
                try client.resourceVersion(resource, &generated.wl_shm),
                generated.wl_shm_pool.version,
            );
            _ = client.createResource(request.id, &generated.wl_shm_pool, version, .{
                .context = pool_resource,
                .dispatch = dispatchPool,
                .destroy = destroyPool,
            }) catch return client.postNoMemory();
        },
        .release => {},
    }
}

fn dispatchPool(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const pool_resource: *PoolResource = @ptrCast(@alignCast(context));
    switch (try generated.wl_shm_pool_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .create_buffer => |request| {
            var buffer = shm.Buffer.create(
                pool_resource.pool,
                request.offset,
                request.width,
                request.height,
                request.stride,
                request.format,
            ) catch |err| switch (err) {
                error.InvalidFormat => return client.postError(
                    resource,
                    @intFromEnum(generated.wl_shm_pool_types.@"error".invalid_format),
                    "unsupported shared-memory format",
                ),
                error.InvalidStride, error.InvalidBuffer => return client.postError(
                    resource,
                    @intFromEnum(generated.wl_shm_pool_types.@"error".invalid_stride),
                    "invalid shared-memory buffer geometry",
                ),
                error.ReferenceOverflow => return client.postNoMemory(),
            };
            errdefer buffer.deinit();
            const buffer_resource = pool_resource.allocator.create(BufferResource) catch
                return client.postNoMemory();
            errdefer pool_resource.allocator.destroy(buffer_resource);
            buffer_resource.* = .{
                .allocator = pool_resource.allocator,
                .content = .{ .shm = buffer },
            };
            _ = client.createResource(request.id, &generated.wl_buffer, 1, .{
                .context = buffer_resource,
                .dispatch = dispatchBuffer,
                .destroy = destroyBuffer,
            }) catch return client.postNoMemory();
        },
        .destroy => {},
        .resize => |request| pool_resource.pool.resize(request.size) catch
            return client.postError(
                pool_resource.shm_resource,
                @intFromEnum(generated.wl_shm_types.@"error".invalid_fd),
                "shared-memory pools may only grow",
            ),
    }
}

fn destroyPool(
    context: *anyopaque,
    _: *Server.Client,
    _: wayring.ObjectHandle,
) void {
    const resource: *PoolResource = @ptrCast(@alignCast(context));
    resource.pool.unreference();
    resource.allocator.destroy(resource);
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
    const resource: *BufferResource = @ptrCast(@alignCast(context));
    resource.unreference();
}

const TestPeer = struct {
    connection: wayring.Connection,
    display: wayring.ObjectHandle,
    registry: wayring.ObjectHandle,

    fn init(allocator: std.mem.Allocator) !TestPeer {
        const core = @import("wayring-core");
        var connection = wayring.Connection.init(
            allocator,
            .client,
            wayring.default_max_frame_size,
        );
        errdefer connection.deinit();
        const display: wayring.ObjectHandle = .{
            .id = 1,
            .generation = try core.bootstrapDisplay(&connection),
        };
        const registry: wayring.ObjectHandle = .{
            .id = 2,
            .generation = try core.getRegistry(&connection, 2),
        };
        return .{ .connection = connection, .display = display, .registry = registry };
    }

    fn deinit(self: *TestPeer) void {
        self.connection.deinit();
    }

    fn toServer(self: *TestPeer, client: *Server.Client) !void {
        while (self.connection.nextBatch()) |batch| {
            try client.receive(batch.bytes, batch.fds);
            try self.connection.acknowledge(batch.token, batch.bytes.len);
        }
    }

    fn fromServer(self: *TestPeer, client: *Server.Client) !void {
        while (client.connection.nextBatch()) |batch| {
            try self.connection.feed(batch.bytes, batch.fds);
            try client.connection.acknowledge(batch.token, batch.bytes.len);
        }
        try client.outputDrained();
    }
};

test "native wl_shm binds, creates buffers, and survives pool destruction" {
    const core = @import("wayring-core");
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var global: ShmGlobal = undefined;
    try global.init(std.testing.allocator, &server);
    defer global.deinit();
    const client = try server.createClient();
    var peer = try TestPeer.init(std.testing.allocator);
    defer peer.deinit();
    try peer.toServer(client);
    try peer.fromServer(client);
    var global_message = peer.connection.popMessage() orelse return error.MissingGlobal;
    defer global_message.deinit();
    const advertised = (try core.decodeRegistryEvent(&global_message, peer.registry.id)).global;
    try std.testing.expectEqualStrings(generated.wl_shm.name, advertised.interface);

    const shm_resource: wayring.ObjectHandle = .{
        .id = 3,
        .generation = try core.bind(
            &peer.connection,
            peer.registry.id,
            advertised.name,
            generated.wl_shm.name,
            advertised.version,
            3,
            &generated.wl_shm,
        ),
    };
    try peer.toServer(client);
    try peer.fromServer(client);
    var format_count: usize = 0;
    while (peer.connection.popMessage()) |popped| {
        var format_message = popped;
        defer format_message.deinit();
        _ = try generated.wl_shm_types.decodeEvent(
            &peer.connection,
            shm_resource,
            &format_message,
        );
        format_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), format_count);

    const fd = try std.posix.memfd_create("keywork-native-shm-test", linux.MFD.CLOEXEC);
    var fd_owned = true;
    defer if (fd_owned) {
        _ = linux.close(fd);
    };
    if (linux.errno(linux.ftruncate(fd, 64)) != .SUCCESS) return error.TruncateFailed;
    const pool = try generated.wl_shm_types.requests.create_pool(
        &peer.connection,
        shm_resource,
        fd,
        64,
    );
    fd_owned = false;
    try peer.toServer(client);
    const buffer = try generated.wl_shm_pool_types.requests.create_buffer(
        &peer.connection,
        pool,
        0,
        2,
        2,
        8,
        @intFromEnum(shm.Format.argb8888),
    );
    try peer.toServer(client);
    const retained = try cloneBufferResource(client, buffer);
    try generated.wl_shm_pool_types.requests.destroy(&peer.connection, pool);
    try peer.toServer(client);
    retained.unreference();
    try generated.wl_buffer_types.requests.destroy(&peer.connection, buffer);
    try peer.toServer(client);
}
