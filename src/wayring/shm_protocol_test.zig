const std = @import("std");
const core = @import("core_protocol");
const wayring = @import("wayring");

const server = wayring.server;
const wire = wayring.wire;
const Shm = server.shm.Protocol(core);

fn send(client: *server.Client, object: u32, opcode: u16, descriptor: *const wire.MessageDescriptor, values: []const wire.Value) !void {
    var output: wire.Output = .init(std.testing.allocator);
    defer output.deinit();
    try output.enqueue(object, opcode, descriptor, values);
    const batch = (try output.beginSend()).?;
    var receiver_fds: std.ArrayList(wire.FileDescriptor) = .empty;
    defer receiver_fds.deinit(std.testing.allocator);
    try receiver_fds.ensureUnusedCapacity(std.testing.allocator, batch.fds.len);
    errdefer {
        for (receiver_fds.items) |fd| _ = std.c.close(fd);
    }
    for (batch.fds) |fd| {
        const duplicate = std.c.fcntl(fd, std.c.F.DUPFD_CLOEXEC, @as(c_int, 0));
        if (duplicate < 0) return error.Unexpected;
        receiver_fds.appendAssumeCapacity(duplicate);
    }
    try client.receive(batch.bytes, receiver_fds.items);
    receiver_fds.clearRetainingCapacity(); // Client input now owns these descriptors.
    try output.completeSend(batch.token, batch.bytes.len);
    try client.dispatch();
}

fn drain(client: *server.Client) !void {
    while (try client.beginSend()) |batch| try client.completeSend(batch.token, batch.bytes.len);
}

fn bindClient(host: *server.Server, global: *const server.Server.Global) !*server.CoreClient {
    const managed = try server.CoreClient.create(std.testing.allocator, host, .{});
    errdefer managed.destroy();
    const client = managed.client();
    try send(client, 1, 1, &core.wl_display.request_messages[1], &.{.{ .new_id = .{ .typed = 2 } }});
    try drain(client);
    try send(client, 2, 0, &core.wl_registry.request_messages[0], &.{
        .{ .uint = global.name() },
        .{ .new_id = .{ .generic = .{ .interface = "wl_shm", .version = global.version(), .id = 3 } } },
    });
    return managed;
}

const Fixture = struct {
    host: server.Server,
    shm: Shm,
    managed: *server.CoreClient,
    global: *const server.Server.Global,

    fn init(self: *Fixture) !void {
        self.host = .init(std.testing.allocator);
        errdefer self.host.deinit();
        self.shm = .init(std.testing.allocator);
        self.global = try self.shm.publish(&self.host, 99);
        errdefer self.shm.deinit();
        self.managed = try bindClient(&self.host, self.global);
    }

    fn deinit(self: *Fixture) void {
        self.shm.deinit();
        self.managed.destroy();
        self.host.deinit();
    }
};

fn memfd(size: usize) !std.posix.fd_t {
    const fd = try std.posix.memfd_create("wayring-protocol-shm", std.os.linux.MFD.CLOEXEC);
    errdefer _ = std.c.close(fd);
    if (std.os.linux.errno(std.os.linux.ftruncate(fd, @intCast(size))) != .SUCCESS) return error.Unexpected;
    return fd;
}

test "generated shm adapter publishes and advertises deterministic formats" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var shm: Shm = .init(std.testing.allocator);
    const global = try shm.publish(&host, 99);
    try std.testing.expectEqual(core.wl_shm.interface.version, global.version());

    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    try send(client, 1, 1, &core.wl_display.request_messages[1], &.{.{ .new_id = .{ .typed = 2 } }});
    // Discard registry publication, then bind through the normal generic path.
    while (try client.beginSend()) |batch| try client.completeSend(batch.token, batch.bytes.len);
    try send(client, 2, 0, &core.wl_registry.request_messages[0], &.{
        .{ .uint = global.name() },
        .{ .new_id = .{ .generic = .{ .interface = "wl_shm", .version = global.version(), .id = 3 } } },
    });
    var formats: [2]u32 = undefined;
    var index: usize = 0;
    while (try client.beginSend()) |batch| {
        var offset: usize = 0;
        while (offset < batch.bytes.len) {
            try std.testing.expect(index < formats.len);
            try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, batch.bytes[offset..][0..4], .little));
            formats[index] = std.mem.readInt(u32, batch.bytes[offset + 8 ..][0..4], .little);
            index += 1;
            offset += 12;
        }
        try client.completeSend(batch.token, batch.bytes.len);
    }
    try std.testing.expectEqual([2]u32{ 0, 1 }, formats);
    shm.deinit();
    managed.destroy();
}

test "unpublishing adapter rejects later binds before invalidating context" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var shm: Shm = .init(std.testing.allocator);
    const global = try shm.publish(&host, 3);
    const global_name = global.name();
    try shm.unpublish();
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    defer managed.destroy();
    const client = managed.client();
    try send(client, 1, 1, &core.wl_display.request_messages[1], &.{.{ .new_id = .{ .typed = 2 } }});
    try drain(client);
    try send(client, 2, 0, &core.wl_registry.request_messages[0], &.{
        .{ .uint = global_name },
        .{ .new_id = .{ .generic = .{ .interface = "wl_shm", .version = 3, .id = 3 } } },
    });
    try std.testing.expectEqual(server.Fatal.Kind.protocol, client.fatal().?.kind);
    try std.testing.expect(client.lookup(3) == null);
    shm.deinit();
}

test "shared adapter tears down one client without disturbing another" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var shm: Shm = .init(std.testing.allocator);
    const global = try shm.publish(&host, 3);
    const first = try bindClient(&host, global);
    const second = try bindClient(&host, global);
    try drain(first.client());
    try drain(second.client());
    const first_fd = try memfd(64);
    defer _ = std.c.close(first_fd);
    const second_fd = try memfd(64);
    defer _ = std.c.close(second_fd);
    try send(first.client(), 3, 0, &core.wl_shm.request_messages[0], &.{ .{ .new_id = .{ .typed = 4 } }, .{ .fd = first_fd }, .{ .int = 64 } });
    try send(second.client(), 3, 0, &core.wl_shm.request_messages[0], &.{ .{ .new_id = .{ .typed = 4 } }, .{ .fd = second_fd }, .{ .int = 64 } });

    shm.destroyClientResources(first.client());
    try std.testing.expect(first.canDestroy());
    try std.testing.expect(first.client().lookup(3) == null);
    try std.testing.expect(first.client().lookup(4) == null);
    first.destroy();

    try std.testing.expect(second.client().lookup(4) != null);
    try send(second.client(), 4, 0, &core.wl_shm_pool.request_messages[0], &.{
        .{ .new_id = .{ .typed = 5 } }, .{ .int = 0 }, .{ .int = 1 }, .{ .int = 1 }, .{ .int = 4 }, .{ .uint = 0 },
    });
    var pin = shm.pin(second.client().lookup(5).?).?;
    pin.deinit();
    shm.destroyClientResources(second.client());
    try std.testing.expect(second.canDestroy());
    second.destroy();
    shm.deinit();
}

test "shm protocol pool and padded buffer preserve pinned storage lifetimes" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const client = fixture.managed.client();
    try drain(client);

    const fd = try memfd(64);
    defer _ = std.c.close(fd);
    try send(client, 3, 0, &core.wl_shm.request_messages[0], &.{ .{ .new_id = .{ .typed = 4 } }, .{ .fd = fd }, .{ .int = 64 } });
    try send(client, 4, 0, &core.wl_shm_pool.request_messages[0], &.{
        .{ .new_id = .{ .typed = 5 } }, .{ .int = 4 }, .{ .int = 2 }, .{ .int = 2 }, .{ .int = 12 }, .{ .uint = 1 },
    });
    const buffer_resource = client.lookup(5).?;
    var pin = fixture.shm.pin(buffer_resource).?;
    defer pin.deinit();
    var access = try pin.access();
    try std.testing.expectEqual(@as(usize, 4), access.geometry.offset);
    try std.testing.expectEqual(@as(usize, 2), access.geometry.width);
    try std.testing.expectEqual(@as(usize, 2), access.geometry.height);
    try std.testing.expectEqual(@as(usize, 12), access.geometry.stride);
    try std.testing.expectEqual(@as(usize, 20), access.bytes.len);
    access.bytes[0] = 91;
    try access.end();

    try send(client, 4, 1, &core.wl_shm_pool.request_messages[1], &.{});
    try std.testing.expect(client.lookup(4) == null);
    try drain(client);
    var after_pool = try pin.access();
    try std.testing.expectEqual(@as(u8, 91), after_pool.bytes[0]);
    try after_pool.end();

    try fixture.shm.sendRelease(buffer_resource);
    const release = (try client.beginSend()).?;
    try std.testing.expectEqual(@as(usize, 8), release.bytes.len);
    try std.testing.expectEqual(@as(u32, 5), std.mem.readInt(u32, release.bytes[0..4], .native));
    try std.testing.expectEqual(@as(u16, 0), @as(u16, @truncate(std.mem.readInt(u32, release.bytes[4..8], .native))));
    try client.completeSend(release.token, release.bytes.len);

    try send(client, 5, 0, &core.wl_buffer.request_messages[0], &.{});
    try std.testing.expect(client.lookup(5) == null);
    var after_buffer = try pin.access();
    try std.testing.expectEqual(@as(u8, 91), after_buffer.bytes[0]);
    try after_buffer.end();
}

fn expectPoolFatal(size: i32, backing_size: usize, expected_code: i64) !void {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const client = fixture.managed.client();
    try drain(client);
    const fd = try memfd(backing_size);
    defer _ = std.c.close(fd);
    try send(client, 3, 0, &core.wl_shm.request_messages[0], &.{ .{ .new_id = .{ .typed = 4 } }, .{ .fd = fd }, .{ .int = size } });
    try std.testing.expectEqual(server.Fatal.Kind.protocol, client.fatal().?.kind);
    try std.testing.expectEqual(@as(?u32, @intCast(expected_code)), client.fatal().?.protocol_code);
    try std.testing.expect(client.lookup(4) == null);
}

test "malformed shm create_pool reports invalid_fd and rolls back id" {
    try expectPoolFatal(64, 8, core.wl_shm.@"error".invalid_fd);
    try expectPoolFatal(0, 8, core.wl_shm.@"error".invalid_stride);
}

test "read-only shm backing reports invalid_fd rather than implementation failure" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try drain(fixture.managed.client());
    const writable = try memfd(64);
    defer _ = std.c.close(writable);
    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buffer, "/proc/self/fd/{d}", .{writable});
    const read_only = std.c.open(path.ptr, std.c.O{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (read_only < 0) return error.Unexpected;
    defer _ = std.c.close(read_only);
    try send(fixture.managed.client(), 3, 0, &core.wl_shm.request_messages[0], &.{
        .{ .new_id = .{ .typed = 4 } }, .{ .fd = read_only }, .{ .int = 64 },
    });
    try std.testing.expectEqual(server.Fatal.Kind.protocol, fixture.managed.client().fatal().?.kind);
    try std.testing.expectEqual(@as(?u32, @intCast(core.wl_shm.@"error".invalid_fd)), fixture.managed.client().fatal().?.protocol_code);
    try std.testing.expect(fixture.managed.client().lookup(4) == null);
}

fn expectBufferFatal(format: u32, offset: i32, width: i32, height: i32, stride: i32, expected_code: i64) !void {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const client = fixture.managed.client();
    try drain(client);
    const fd = try memfd(64);
    defer _ = std.c.close(fd);
    try send(client, 3, 0, &core.wl_shm.request_messages[0], &.{ .{ .new_id = .{ .typed = 4 } }, .{ .fd = fd }, .{ .int = 64 } });
    try send(client, 4, 0, &core.wl_shm_pool.request_messages[0], &.{
        .{ .new_id = .{ .typed = 5 } }, .{ .int = offset }, .{ .int = width }, .{ .int = height }, .{ .int = stride }, .{ .uint = format },
    });
    try std.testing.expectEqual(server.Fatal.Kind.protocol, client.fatal().?.kind);
    try std.testing.expectEqual(@as(?u32, @intCast(expected_code)), client.fatal().?.protocol_code);
    try std.testing.expect(client.lookup(5) == null);
}

test "malformed shm create_buffer reports precise errors and rolls back id" {
    try expectBufferFatal(99, 0, 1, 1, 4, core.wl_shm_pool.@"error".invalid_format);
    try expectBufferFatal(0, 0, 2, 2, 7, core.wl_shm_pool.@"error".invalid_stride);
    try expectBufferFatal(0, 60, 2, 2, 8, core.wl_shm_pool.@"error".invalid_stride);
}
