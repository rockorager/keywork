const std = @import("std");
const core = @import("core_protocol");
const wayring = @import("wayring");
const linux = std.os.linux;
const c = @cImport({
    @cInclude("wayland-client.h");
});

const ClientStatus = enum(u8) { running, success, connect_failed, registry_failed, shm_failed, roundtrip_failed };
const no_wake_fd: i32 = -1;
const shutdown_requested: i32 = -2;

const ClientContext = struct {
    address: linux.sockaddr.un,
    address_len: linux.socklen_t,
    status: std.atomic.Value(u8) = .init(@intFromEnum(ClientStatus.running)),
    wake_fd: std.atomic.Value(i32) = .init(no_wake_fd),
    saw_compositor: bool = false,
    shm: ?*c.wl_shm = null,
    saw_argb8888: bool = false,
    saw_xrgb8888: bool = false,
};

fn registryGlobal(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32, interface: [*c]const u8, _: u32) callconv(.c) void {
    const context: *ClientContext = @ptrCast(@alignCast(data.?));
    if (std.mem.eql(u8, std.mem.span(interface), "wl_compositor")) context.saw_compositor = true;
    if (std.mem.eql(u8, std.mem.span(interface), "wl_shm"))
        context.shm = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_shm_interface, 1));
}

fn registryRemove(_: ?*anyopaque, _: ?*c.wl_registry, _: u32) callconv(.c) void {}

const registry_listener: c.wl_registry_listener = .{
    .global = registryGlobal,
    .global_remove = registryRemove,
};

fn shmFormat(data: ?*anyopaque, _: ?*c.wl_shm, format: u32) callconv(.c) void {
    const context: *ClientContext = @ptrCast(@alignCast(data.?));
    if (format == c.WL_SHM_FORMAT_ARGB8888) context.saw_argb8888 = true;
    if (format == c.WL_SHM_FORMAT_XRGB8888) context.saw_xrgb8888 = true;
}

const shm_listener: c.wl_shm_listener = .{ .format = shmFormat };

fn clientMain(context: *ClientContext) void {
    const raw_fd = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(raw_fd) != .SUCCESS) return finish(context, .connect_failed);
    const fd: linux.fd_t = @intCast(raw_fd);
    var owns_fd = true;
    defer if (owns_fd) {
        _ = linux.close(fd);
    };
    const raw_wake_fd = linux.dup(fd);
    if (linux.errno(raw_wake_fd) != .SUCCESS) return finish(context, .connect_failed);
    const wake_fd: i32 = @intCast(raw_wake_fd);
    if (context.wake_fd.cmpxchgStrong(no_wake_fd, wake_fd, .acq_rel, .acquire)) |state| {
        _ = linux.close(wake_fd);
        std.debug.assert(state == shutdown_requested);
        return finish(context, .connect_failed);
    }
    const result = linux.connect(fd, @ptrCast(&context.address), context.address_len);
    if (linux.errno(result) != .SUCCESS) return finish(context, .connect_failed);

    const display = c.wl_display_connect_to_fd(fd) orelse return finish(context, .connect_failed);
    owns_fd = false;
    defer c.wl_display_disconnect(display);
    const registry = c.wl_display_get_registry(display) orelse return finish(context, .registry_failed);
    defer c.wl_registry_destroy(registry);
    if (c.wl_registry_add_listener(registry, &registry_listener, context) != 0)
        return finish(context, .registry_failed);
    if (c.wl_display_roundtrip(display) < 0) return finish(context, .roundtrip_failed);
    const shm = context.shm orelse return finish(context, .registry_failed);
    defer c.wl_shm_destroy(shm);
    if (c.wl_shm_add_listener(shm, &shm_listener, context) != 0) return finish(context, .shm_failed);
    if (c.wl_display_roundtrip(display) < 0) return finish(context, .roundtrip_failed);
    if (!context.saw_compositor or !context.saw_argb8888 or !context.saw_xrgb8888)
        return finish(context, .registry_failed);

    const shm_fd = std.posix.memfd_create("wayring-libwayland-shm", std.os.linux.MFD.CLOEXEC) catch
        return finish(context, .shm_failed);
    defer _ = linux.close(shm_fd);
    if (linux.errno(linux.ftruncate(shm_fd, 64)) != .SUCCESS) return finish(context, .shm_failed);
    const pool = c.wl_shm_create_pool(shm, shm_fd, 64) orelse return finish(context, .shm_failed);
    const buffer = c.wl_shm_pool_create_buffer(pool, 0, 2, 2, 8, c.WL_SHM_FORMAT_ARGB8888) orelse {
        c.wl_shm_pool_destroy(pool);
        return finish(context, .shm_failed);
    };
    c.wl_shm_pool_destroy(pool);
    if (c.wl_display_roundtrip(display) < 0) {
        c.wl_buffer_destroy(buffer);
        return finish(context, .roundtrip_failed);
    }
    c.wl_buffer_destroy(buffer);
    if (c.wl_display_roundtrip(display) < 0) return finish(context, .roundtrip_failed);
    finish(context, .success);
}

fn finish(context: *ClientContext, status: ClientStatus) void {
    context.status.store(@intFromEnum(status), .release);
}

fn compositorBind(_: *wayring.server.Client, _: u32, _: u32, _: *u8) !void {}

const Route = struct {
    external: u64,
    token: wayring.io_uring.OperationToken,
};

fn socketAddress() linux.sockaddr.un {
    var address: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = @splat(0) };
    const name = "keywork-wayring-checkpoint4";
    @memcpy(address.path[1 .. name.len + 1], name);
    const pid = linux.getpid();
    @memcpy(address.path[1 + name.len ..][0..@sizeOf(@TypeOf(pid))], std.mem.asBytes(&pid));
    return address;
}

fn addressLength() linux.socklen_t {
    return @intCast(@offsetOf(linux.sockaddr.un, "path") + 1 + "keywork-wayring-checkpoint4".len + @sizeOf(@TypeOf(linux.getpid())));
}

fn closeClientWake(context: *ClientContext, shutdown: bool) void {
    const fd = context.wake_fd.swap(if (shutdown) shutdown_requested else no_wake_fd, .acq_rel);
    if (fd < 0) return;
    if (shutdown) _ = linux.shutdown(fd, linux.SHUT.RDWR);
    _ = linux.close(fd);
}

fn shortSleep() void {
    const duration: linux.timespec = .{ .sec = 0, .nsec = std.time.ns_per_ms };
    _ = linux.nanosleep(&duration, null);
}

test "system libwayland creates and destroys shared memory through caller-owned io_uring" {
    var host: wayring.server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var binder_context: u8 = 0;
    _ = try host.addGlobal(core.wl_compositor, 1, u8, &binder_context, compositorBind);
    var shm: wayring.server.shm.Protocol(core) = .init(std.testing.allocator);
    defer shm.deinit();
    _ = try shm.publish(&host, core.wl_shm.interface.version);

    const address = socketAddress();
    const address_len = addressLength();
    const raw_listener = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(raw_listener));
    const listener: linux.fd_t = @intCast(raw_listener);
    var listener_owned = true;
    defer if (listener_owned) {
        _ = linux.close(listener);
    };
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.bind(listener, @ptrCast(&address), address_len)));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.listen(listener, 4)));

    var transport = try wayring.io_uring.Server.init(std.testing.allocator, &host, listener);
    listener_owned = false;
    var transport_live = true;
    defer if (transport_live) transport.deinit() catch {};
    var ring = try linux.IoUring.init(16, 0);
    defer ring.deinit();

    var context: ClientContext = .{ .address = address, .address_len = address_len };
    const thread = try std.Thread.spawn(.{}, clientMain, .{&context});
    var joined = false;
    defer if (!joined) {
        closeClientWake(&context, true);
        thread.join();
    };

    var routes: [16]Route = undefined;
    var route_count: usize = 0;
    var next_external: u64 = 1;
    var accepted: ?*wayring.io_uring.Connection = null;
    var disconnected = false;
    var shutting_down = false;
    var timed_out = false;
    var received = false;
    var sent = false;
    var cancellation_count: usize = 0;
    var cqes: [16]linux.io_uring_cqe = undefined;
    var iterations: usize = 0;

    while (true) {
        iterations += 1;
        if (iterations == 10_000) {
            timed_out = true;
            closeClientWake(&context, true);
            transport.beginShutdown();
            shutting_down = true;
        }
        if (iterations > 20_000) return error.Checkpoint4CleanupTimedOut;
        if (route_count < routes.len) switch (try transport.prepareNext(&ring, next_external)) {
            .prepared => |token| {
                routes[route_count] = .{ .external = next_external, .token = token };
                route_count += 1;
                next_external += 1;
            },
            .idle, .submission_queue_full => {},
        };
        _ = try ring.submit();
        const count = try ring.copy_cqes(&cqes, 0);
        for (cqes[0..count]) |cqe| {
            var route_index: ?usize = null;
            for (routes[0..route_count], 0..) |route, index| if (route.external == cqe.user_data) {
                route_index = index;
                break;
            };
            const index = route_index orelse return error.UnknownExternalUserData;
            const token = routes[index].token;
            routes[index] = routes[route_count - 1];
            route_count -= 1;
            switch (try transport.complete(token, cqe.res, cqe.flags)) {
                .accepted => |connection| accepted = connection,
                .peer_disconnected => |connection| {
                    if (accepted != connection) return error.UnexpectedDisconnectedConnection;
                    disconnected = true;
                },
                .listener_error, .terminal => return error.UnexpectedTransportFailure,
                .received => received = true,
                .sent => sent = true,
                .cancellation => cancellation_count += 1,
                .retry => {},
            }
        }

        const status: ClientStatus = @enumFromInt(context.status.load(.acquire));
        if (status != .running and !joined) {
            closeClientWake(&context, false);
            thread.join();
            joined = true;
            if (!timed_out) try std.testing.expectEqual(ClientStatus.success, status);
        }
        if (joined and accepted != null and (disconnected or timed_out)) {
            shm.destroyClientResources(accepted.?.client());
            var released = true;
            transport.release(accepted.?) catch |err| switch (err) {
                error.OperationInFlight => released = false,
                else => return err,
            };
            if (released) accepted = null;
        }
        if (joined and disconnected and accepted == null and !shutting_down) {
            transport.beginShutdown();
            shutting_down = true;
        }
        if (shutting_down and transport.isDrained() and joined and accepted == null) break;
        shortSleep();
    }

    if (timed_out) return error.Checkpoint4TimedOut;
    try std.testing.expect(disconnected);
    try std.testing.expect(received);
    try std.testing.expect(sent);
    try std.testing.expectEqual(@as(usize, 2), cancellation_count);
    try std.testing.expectEqual(@as(usize, 0), route_count);
    try transport.deinit();
    transport_live = false;
}
