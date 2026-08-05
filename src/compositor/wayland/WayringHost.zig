//! Drives Wayring's caller-owned io_uring from Keywork's existing event loop.
//!
//! Protocol modules own application resources and supply the mandatory client
//! cleanup callback. This host owns only socket, ring, completion routing, and
//! transport connection lifetime.

const WayringHost = @This();

const std = @import("std");
const wayland = @import("wayland");
const wayring = @import("wayring");

const linux = std.os.linux;
const server = wayring.server;
const wl = wayland.server.wl;

const log = std.log.scoped(.wayring_host);
const submission_capacity = 64;
const route_capacity = submission_capacity * 2;

pub const ClientLifecycle = struct {
    context: *anyopaque,
    destroy_resources: *const fn (*anyopaque, *server.Client) void,
};

const Route = struct {
    external: u64,
    token: wayring.io_uring.OperationToken,
};

const ManagedConnection = struct {
    connection: *wayring.io_uring.Connection,
    retiring: bool = false,
    resources_destroyed: bool = false,
};

const CompletionSource = struct {
    context: *anyopaque,
    copy: *const fn (*anyopaque, *linux.IoUring, []linux.io_uring_cqe, u32) anyerror!u32,

    fn fromRing(host: *WayringHost) CompletionSource {
        return .{ .context = host, .copy = copyFromRing };
    }

    fn copyFromRing(_: *anyopaque, ring: *linux.IoUring, cqes: []linux.io_uring_cqe, wait_nr: u32) !u32 {
        return ring.copy_cqes(cqes, wait_nr);
    }
};

const DrainResult = union(enum) {
    complete,
    undrainable: anyerror,
};

allocator: std.mem.Allocator,
lifecycle: ClientLifecycle,
transport: wayring.io_uring.Server,
ring: linux.IoUring,
event_source: ?*wl.EventSource,
connections: std.ArrayList(*ManagedConnection) = .empty,
routes: [route_capacity]Route = undefined,
route_count: usize = 0,
next_external: u64 = 1,
submission_pending: bool = false,
shutting_down: bool = false,
failure_value: ?anyerror = null,

pub fn create(
    allocator: std.mem.Allocator,
    event_loop: *wl.EventLoop,
    protocol_server: *server.Server,
    runtime_directory: []const u8,
    lifecycle: ClientLifecycle,
) !*WayringHost {
    const self = try allocator.create(WayringHost);
    errdefer allocator.destroy(self);
    self.* = undefined;
    self.allocator = allocator;
    self.lifecycle = lifecycle;
    self.transport = try wayring.io_uring.Server.listenAuto(allocator, protocol_server, runtime_directory);
    errdefer self.transport.deinit() catch {};
    self.ring = try linux.IoUring.init(submission_capacity, 0);
    errdefer self.ring.deinit();
    self.event_source = null;
    self.connections = .empty;
    self.route_count = 0;
    self.next_external = 1;
    self.submission_pending = false;
    self.shutting_down = false;
    self.failure_value = null;
    try self.transport.reserveOperationCapacity(route_capacity);
    self.event_source = try event_loop.addFd(
        *WayringHost,
        self.ring.fd,
        .{ .readable = true, .hangup = true, .@"error" = true },
        handleRingEvent,
        self,
    );
    errdefer self.event_source.?.remove();
    self.prepareAndSubmit() catch |err| self.fail(err);
    return self;
}

/// Returns only after every client resource and transport operation is gone
/// and all host-owned storage has been freed. Kernel failures that make that
/// guarantee impossible terminate the process instead of returning to owners
/// borrowed by lifecycle callbacks. A lifecycle callback that leaves
/// application resources live is likewise fatal because its connection cannot
/// be released safely.
pub fn destroy(self: *WayringHost) !void {
    self.beginDestroy();
    switch (self.drainForDestroy(.fromRing(self))) {
        .complete => {},
        .undrainable => |err| fatalDestroy(err),
    }
    return self.finishDestroy();
}

fn beginDestroy(self: *WayringHost) void {
    if (self.event_source) |source| {
        source.remove();
        self.event_source = null;
    }
    self.beginShutdown();
}

fn drainForDestroy(self: *WayringHost, completions: CompletionSource) DrainResult {
    var cqes: [route_capacity]linux.io_uring_cqe = undefined;
    while (!self.transport.isDrained() or self.route_count != 0 or self.connections.items.len != 0) {
        self.releaseReady(true) catch |err| self.recordFailure(err);
        self.prepareAndSubmit() catch |err| {
            self.recordFailure(err);
            return .{ .undrainable = err };
        };
        std.debug.assert(!self.submission_pending);
        if (self.route_count == 0) {
            if (self.transport.isDrained() and self.connections.items.len == 0) break;
            self.recordFailure(error.TransportCleanupStalled);
            return .{ .undrainable = error.TransportCleanupStalled };
        }
        const count = completions.copy(completions.context, &self.ring, &cqes, 1) catch |err| switch (err) {
            error.SignalInterrupt => continue,
            else => {
                self.recordFailure(err);
                return .{ .undrainable = err };
            },
        };
        self.completeBatch(cqes[0..count]) catch |err| self.recordFailure(err);
    }
    return .complete;
}

fn finishDestroy(self: *WayringHost) !void {
    std.debug.assert(self.transport.isDrained());
    std.debug.assert(self.route_count == 0);
    std.debug.assert(self.connections.items.len == 0);
    var transport_failure: ?anyerror = null;
    self.transport.deinit() catch |err| {
        if (err != error.SocketCleanupFailed) fatalDestroy(err);
        transport_failure = error.SocketCleanupFailed;
    };
    self.ring.deinit();
    self.connections.deinit(self.allocator);
    const host_failure = self.failure_value;
    const allocator = self.allocator;
    self.* = undefined;
    allocator.destroy(self);
    if (host_failure) |err| return err;
    if (transport_failure) |err| return err;
}

fn fatalDestroy(err: anyerror) noreturn {
    log.err("cannot safely destroy Wayring host because kernel cleanup is undrainable: {t}", .{err});
    std.process.abort();
}

pub fn displayName(self: *const WayringHost) []const u8 {
    return self.transport.socketName().?;
}

pub fn connectionCount(self: *const WayringHost) usize {
    return self.connections.items.len;
}

pub fn failure(self: *const WayringHost) ?anyerror {
    return self.failure_value;
}

pub fn beginShutdown(self: *WayringHost) void {
    if (!self.shutting_down) {
        self.shutting_down = true;
        self.transport.beginShutdown();
    }
    self.releaseReady(true) catch |err| self.recordFailure(err);
    self.prepareAndSubmit() catch |err| self.recordFailure(err);
}

fn handleRingEvent(_: c_int, mask: wl.EventMask, self: *WayringHost) c_int {
    if (mask.hangup or mask.@"error") {
        self.fail(error.IoUringEventSourceFailed);
        return 0;
    }
    self.dispatchReady() catch |err| self.fail(err);
    return 0;
}

fn dispatchReady(self: *WayringHost) !void {
    var cqes: [route_capacity]linux.io_uring_cqe = undefined;
    var first_failure: ?anyerror = null;
    while (true) {
        const count = try self.ring.copy_cqes(&cqes, 0);
        if (count == 0) break;
        self.completeBatch(cqes[0..count]) catch |err| if (first_failure == null) {
            first_failure = err;
        };
    }
    self.releaseReady(self.shutting_down) catch |err| if (first_failure == null) {
        first_failure = err;
    };
    self.prepareAndSubmit() catch |err| if (first_failure == null) {
        first_failure = err;
    };
    if (first_failure) |err| return err;
}

fn prepareAndSubmit(self: *WayringHost) !void {
    try self.submitPending();
    while (self.route_count < self.routes.len) {
        switch (try self.transport.prepareNext(&self.ring, self.next_external)) {
            .prepared => |token| {
                self.routes[self.route_count] = .{ .external = self.next_external, .token = token };
                self.route_count += 1;
                self.submission_pending = true;
                self.next_external +%= 1;
                if (self.next_external == 0) return error.ExternalUserDataExhausted;
            },
            .idle => break,
            .submission_queue_full => {
                try self.submitPending();
                continue;
            },
        }
    }
    try self.submitPending();
}

fn submitPending(self: *WayringHost) !void {
    while (self.submission_pending or self.ring.sq_ready() != 0) {
        _ = self.ring.submit() catch |err| switch (err) {
            error.SignalInterrupt => continue,
            else => return err,
        };
        self.submission_pending = false;
    }
}

fn completeBatch(self: *WayringHost, cqes: []const linux.io_uring_cqe) !void {
    var first_failure: ?anyerror = null;
    for (cqes) |cqe| {
        self.completeOne(cqe) catch |err| if (first_failure == null) {
            first_failure = err;
        };
    }
    if (first_failure) |err| return err;
}

fn completeOne(self: *WayringHost, cqe: linux.io_uring_cqe) !void {
    const token = self.takeRoute(cqe.user_data) orelse return error.UnknownCompletion;
    const completed = try self.transport.complete(token, cqe.res, cqe.flags);
    switch (completed) {
        .accepted => |connection| try self.addConnection(connection),
        .peer_disconnected => |connection| self.retire(connection),
        .terminal => |connection| {
            if (!connection.client().hasPendingOutput()) self.retire(connection);
        },
        .sent => |connection| {
            if (connection.state() == .terminal and !connection.client().hasPendingOutput()) self.retire(connection);
        },
        .listener_error => return error.ListenerFailed,
        .received, .cancellation, .retry => {},
    }
}

fn addConnection(self: *WayringHost, connection: *wayring.io_uring.Connection) !void {
    self.connections.ensureUnusedCapacity(self.allocator, 1) catch |err| {
        self.lifecycle.destroy_resources(self.lifecycle.context, connection.client());
        try self.transport.release(connection);
        return err;
    };
    const managed = self.allocator.create(ManagedConnection) catch |err| {
        self.lifecycle.destroy_resources(self.lifecycle.context, connection.client());
        try self.transport.release(connection);
        return err;
    };
    managed.* = .{ .connection = connection };
    self.connections.appendAssumeCapacity(managed);
}

fn retire(self: *WayringHost, connection: *wayring.io_uring.Connection) void {
    for (self.connections.items) |managed| {
        if (managed.connection == connection) {
            managed.retiring = true;
            return;
        }
    }
}

fn releaseReady(self: *WayringHost, release_all: bool) !void {
    var index: usize = 0;
    var first_failure: ?anyerror = null;
    while (index < self.connections.items.len) {
        const managed = self.connections.items[index];
        if (!release_all and !managed.retiring) {
            index += 1;
            continue;
        }
        if (!managed.resources_destroyed) {
            self.lifecycle.destroy_resources(self.lifecycle.context, managed.connection.client());
            managed.resources_destroyed = true;
        }
        self.transport.release(managed.connection) catch |err| switch (err) {
            error.OperationInFlight => {
                index += 1;
                continue;
            },
            else => {
                if (first_failure == null) first_failure = err;
                index += 1;
                continue;
            },
        };
        self.allocator.destroy(managed);
        _ = self.connections.orderedRemove(index);
    }
    if (first_failure) |err| return err;
}

fn takeRoute(self: *WayringHost, external: u64) ?wayring.io_uring.OperationToken {
    for (self.routes[0..self.route_count], 0..) |route, index| {
        if (route.external != external) continue;
        const token = route.token;
        self.routes[index] = self.routes[self.route_count - 1];
        self.route_count -= 1;
        return token;
    }
    return null;
}

fn fail(self: *WayringHost, err: anyerror) void {
    self.recordFailure(err);
    self.beginShutdown();
}

fn recordFailure(self: *WayringHost, err: anyerror) void {
    if (self.failure_value == null) self.failure_value = err;
}

const TestClient = struct {
    const Status = enum(u8) { running, success, failed };

    runtime_directory: []const u8,
    display_name: []const u8,
    status: std.atomic.Value(u8) = .init(@intFromEnum(Status.running)),
    compositor: ?*wayland.client.wl.Compositor = null,
    shm: ?*wayland.client.wl.Shm = null,

    fn run(self: *TestClient) void {
        self.runFallible() catch {
            self.status.store(@intFromEnum(Status.failed), .release);
            return;
        };
        self.status.store(@intFromEnum(Status.success), .release);
    }

    fn runFallible(self: *TestClient) !void {
        const path = try std.fmt.allocPrintSentinel(std.heap.page_allocator, "{s}/{s}", .{ self.runtime_directory, self.display_name }, 0);
        defer std.heap.page_allocator.free(path);
        const fd = try connectSocket(path);
        var fd_owned = true;
        defer if (fd_owned) {
            _ = linux.close(fd);
        };
        const display = try wayland.client.wl.Display.connectToFd(fd);
        fd_owned = false;
        defer display.disconnect();
        const registry = try display.getRegistry();
        defer registry.destroy();
        registry.setListener(*TestClient, registryEvent, self);
        if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
        const compositor = self.compositor orelse return error.CompositorMissing;
        const shm = self.shm orelse return error.ShmMissing;
        const surface = try compositor.createSurface();
        const pixels = [_]u32{ 0x8011_2233, 0xff44_5566 };
        const bytes = std.mem.sliceAsBytes(&pixels);
        const shm_fd = try std.posix.memfd_create("keywork-wayring-host", linux.MFD.CLOEXEC);
        defer _ = linux.close(shm_fd);
        if (linux.errno(linux.ftruncate(shm_fd, @intCast(bytes.len))) != .SUCCESS) return error.ShmResizeFailed;
        if (std.c.write(shm_fd, bytes.ptr, bytes.len) != bytes.len) return error.ShmWriteFailed;
        const pool = try shm.createPool(shm_fd, @intCast(bytes.len));
        const buffer = try pool.createBuffer(0, pixels.len, 1, @intCast(bytes.len), .argb8888);
        surface.attach(buffer, 0, 0);
        surface.damage(0, 0, pixels.len, 1);
        surface.commit();
        if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
        buffer.destroy();
        pool.destroy();
    }

    fn registryEvent(registry: *wayland.client.wl.Registry, event: wayland.client.wl.Registry.Event, self: *TestClient) void {
        switch (event) {
            .global => |global| {
                const interface = std.mem.span(global.interface);
                if (std.mem.eql(u8, interface, "wl_compositor") and self.compositor == null) {
                    self.compositor = registry.bind(
                        global.name,
                        wayland.client.wl.Compositor,
                        global.version,
                    ) catch null;
                } else if (std.mem.eql(u8, interface, "wl_shm") and self.shm == null) {
                    self.shm = registry.bind(
                        global.name,
                        wayland.client.wl.Shm,
                        global.version,
                    ) catch null;
                }
            },
            .global_remove => {},
        }
    }
};

fn connectSocket(path: [:0]const u8) !linux.fd_t {
    var address: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = @splat(0) };
    if (path.len >= address.path.len) return error.InvalidSocketPath;
    @memcpy(address.path[0..path.len], path);
    const raw_fd = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(raw_fd) != .SUCCESS) return error.SocketFailed;
    const fd: linux.fd_t = @intCast(raw_fd);
    errdefer _ = linux.close(fd);
    const length: linux.socklen_t = @intCast(@offsetOf(linux.sockaddr.un, "path") + path.len + 1);
    if (linux.errno(linux.connect(fd, @ptrCast(&address), length)) != .SUCCESS) return error.ConnectFailed;
    return fd;
}

const CleanupProbe = struct {
    callback_count: usize = 0,
    callback_client: ?*server.Client = null,
    resource: ?*server.Resource = null,
    destroy_on_callback: bool = true,

    fn destroy(erased: *anyopaque, client: *server.Client) void {
        const self: *CleanupProbe = @ptrCast(@alignCast(erased));
        self.callback_count += 1;
        self.callback_client = client;
        if (self.destroy_on_callback) self.destroyResource();
    }

    fn destroyResource(self: *CleanupProbe) void {
        const resource = self.resource orelse return;
        resource.destroy();
        resource.deinit();
        self.resource = null;
    }
};

const cleanup_test_interface: wayring.wire.Interface = .{
    .name = "keywork_cleanup_test",
    .version = 1,
};

fn waitForManagedConnection(event_loop: *wl.EventLoop, host: *WayringHost) !*ManagedConnection {
    for (0..200) |_| {
        try event_loop.dispatch(50);
        if (host.failure()) |err| return err;
        if (host.connections.items.len != 0) return host.connections.items[0];
    }
    return error.HostBridgeTimedOut;
}

const CompletionErrorInjector = struct {
    injected: bool = false,

    fn copy(erased: *anyopaque, ring: *linux.IoUring, cqes: []linux.io_uring_cqe, wait_nr: u32) !u32 {
        const self: *CompletionErrorInjector = @ptrCast(@alignCast(erased));
        const count = try ring.copy_cqes(cqes, wait_nr);
        if (!self.injected) for (cqes[0..count]) |*cqe| {
            const cancellation_result = cqe.res == 0 or
                cqe.res == -@as(i32, @intFromEnum(linux.E.ALREADY)) or
                cqe.res == -@as(i32, @intFromEnum(linux.E.NOENT));
            if (!cancellation_result) continue;
            cqe.res = -@as(i32, @intFromEnum(linux.E.IO));
            self.injected = true;
            break;
        };
        return count;
    }
};

const CompletionReadErrorInjector = struct {
    injected: bool = false,

    fn copy(erased: *anyopaque, _: *linux.IoUring, _: []linux.io_uring_cqe, _: u32) !u32 {
        const self: *CompletionReadErrorInjector = @ptrCast(@alignCast(erased));
        self.injected = true;
        return error.FileDescriptorInvalid;
    }
};

test "destroy drains resources and routes after a completion error" {
    var marker: u8 = 0;
    const runtime_directory = try std.fmt.allocPrintSentinel(
        std.testing.allocator,
        "/tmp/keywork-wayring-host-completion-{d}-{x}",
        .{ linux.getpid(), @intFromPtr(&marker) },
        0,
    );
    defer std.testing.allocator.free(runtime_directory);
    if (linux.errno(linux.mkdir(runtime_directory.ptr, 0o700)) != .SUCCESS) return error.TestDirectoryCreationFailed;
    defer _ = linux.rmdir(runtime_directory.ptr);

    const event_loop = try wl.EventLoop.create();
    defer event_loop.destroy();
    var protocol_server: server.Server = .init(std.testing.allocator);
    defer protocol_server.deinit();
    var cleanup: CleanupProbe = .{};
    const host = try WayringHost.create(
        std.testing.allocator,
        event_loop,
        &protocol_server,
        runtime_directory,
        .{ .context = &cleanup, .destroy_resources = CleanupProbe.destroy },
    );
    var host_live = true;
    defer if (host_live) host.destroy() catch {};

    const path = try std.fmt.allocPrintSentinel(
        std.testing.allocator,
        "{s}/{s}",
        .{ runtime_directory, host.displayName() },
        0,
    );
    defer std.testing.allocator.free(path);
    const peer_fd = try connectSocket(path);
    defer _ = linux.close(peer_fd);
    const managed = try waitForManagedConnection(event_loop, host);
    const client = managed.connection.client();
    var resource: server.Resource = .init(
        std.testing.allocator,
        2,
        1,
        &cleanup_test_interface,
        &.{},
        .client,
        client.ownerHooks(),
    );
    try client.installClientInitial(2, &resource);
    cleanup.resource = &resource;

    host.beginDestroy();
    var injector: CompletionErrorInjector = .{};
    const drain_result = host.drainForDestroy(.{ .context = &injector, .copy = CompletionErrorInjector.copy });
    const drained = drain_result == .complete;
    const routes_before_return = host.route_count;
    const connections_before_return = host.connections.items.len;
    const transport_drained_before_return = host.transport.isDrained();
    host_live = false;
    var destroy_failure: ?anyerror = null;
    host.finishDestroy() catch |err| {
        destroy_failure = err;
    };

    try std.testing.expect(injector.injected);
    try std.testing.expect(drained);
    try std.testing.expectEqual(@as(usize, 1), cleanup.callback_count);
    try std.testing.expectEqual(client, cleanup.callback_client.?);
    try std.testing.expect(cleanup.resource == null);
    try std.testing.expectEqual(@as(usize, 0), routes_before_return);
    try std.testing.expectEqual(@as(usize, 0), connections_before_return);
    try std.testing.expect(transport_drained_before_return);
    try std.testing.expectEqual(error.UnexpectedCancellationResult, destroy_failure.?);
}

test "completion read failure and stalled destroy are undrainable without repeated callbacks" {
    var marker: u8 = 0;
    const runtime_directory = try std.fmt.allocPrintSentinel(
        std.testing.allocator,
        "/tmp/keywork-wayring-host-stall-{d}-{x}",
        .{ linux.getpid(), @intFromPtr(&marker) },
        0,
    );
    defer std.testing.allocator.free(runtime_directory);
    if (linux.errno(linux.mkdir(runtime_directory.ptr, 0o700)) != .SUCCESS) return error.TestDirectoryCreationFailed;
    defer _ = linux.rmdir(runtime_directory.ptr);

    const event_loop = try wl.EventLoop.create();
    defer event_loop.destroy();
    var protocol_server: server.Server = .init(std.testing.allocator);
    defer protocol_server.deinit();
    var cleanup: CleanupProbe = .{ .destroy_on_callback = false };
    const host = try WayringHost.create(
        std.testing.allocator,
        event_loop,
        &protocol_server,
        runtime_directory,
        .{ .context = &cleanup, .destroy_resources = CleanupProbe.destroy },
    );
    var host_live = true;
    defer if (host_live) host.destroy() catch {};

    const path = try std.fmt.allocPrintSentinel(
        std.testing.allocator,
        "{s}/{s}",
        .{ runtime_directory, host.displayName() },
        0,
    );
    defer std.testing.allocator.free(path);
    const peer_fd = try connectSocket(path);
    defer _ = linux.close(peer_fd);
    const managed = try waitForManagedConnection(event_loop, host);
    const client = managed.connection.client();
    var resource: server.Resource = .init(
        std.testing.allocator,
        2,
        1,
        &cleanup_test_interface,
        &.{},
        .client,
        client.ownerHooks(),
    );
    try client.installClientInitial(2, &resource);
    cleanup.resource = &resource;

    host.beginDestroy();
    var read_error: CompletionReadErrorInjector = .{};
    const read_error_result = host.drainForDestroy(.{ .context = &read_error, .copy = CompletionReadErrorInjector.copy });
    const read_failure: ?anyerror = switch (read_error_result) {
        .complete => null,
        .undrainable => |err| err,
    };
    const routes_after_read_failure = host.route_count;
    const connections_after_read_failure = host.connections.items.len;
    const stalled_result = host.drainForDestroy(.fromRing(host));
    const stalled_failure: ?anyerror = switch (stalled_result) {
        .complete => null,
        .undrainable => |err| err,
    };
    const routes_at_stall = host.route_count;
    const connections_at_stall = host.connections.items.len;
    cleanup.destroyResource();
    const resumed_result = host.drainForDestroy(.fromRing(host));
    const resumed = resumed_result == .complete;
    const callback_count_after_resume = cleanup.callback_count;
    const routes_before_return = host.route_count;
    const connections_before_return = host.connections.items.len;
    const transport_drained_before_return = host.transport.isDrained();
    host_live = false;
    var destroy_failure: ?anyerror = null;
    host.finishDestroy() catch |err| {
        destroy_failure = err;
    };

    try std.testing.expect(read_error.injected);
    try std.testing.expectEqual(error.FileDescriptorInvalid, read_failure.?);
    try std.testing.expect(routes_after_read_failure > 0);
    try std.testing.expectEqual(@as(usize, 1), connections_after_read_failure);
    try std.testing.expectEqual(error.TransportCleanupStalled, stalled_failure.?);
    try std.testing.expectEqual(@as(usize, 0), routes_at_stall);
    try std.testing.expectEqual(@as(usize, 1), connections_at_stall);
    try std.testing.expect(resumed);
    try std.testing.expectEqual(@as(usize, 1), callback_count_after_resume);
    try std.testing.expectEqual(client, cleanup.callback_client.?);
    try std.testing.expectEqual(@as(usize, 0), routes_before_return);
    try std.testing.expectEqual(@as(usize, 0), connections_before_return);
    try std.testing.expect(transport_drained_before_return);
    try std.testing.expectEqual(error.FileDescriptorInvalid, destroy_failure.?);
}

test "existing event loop drives scanner-backed Wayring client lifecycle" {
    const WayringCompositor = @import("WayringCompositor.zig");
    const SurfaceRegistry = @import("../SurfaceRegistry.zig");
    const render = @import("../render/types.zig");
    var marker: u8 = 0;
    const runtime_directory = try std.fmt.allocPrintSentinel(
        std.testing.allocator,
        "/tmp/keywork-wayring-host-{d}-{x}",
        .{ linux.getpid(), @intFromPtr(&marker) },
        0,
    );
    defer std.testing.allocator.free(runtime_directory);
    if (linux.errno(linux.mkdir(runtime_directory.ptr, 0o700)) != .SUCCESS) return error.TestDirectoryCreationFailed;
    defer _ = linux.rmdir(runtime_directory.ptr);

    const event_loop = try wl.EventLoop.create();
    defer event_loop.destroy();
    var protocol_server: server.Server = .init(std.testing.allocator);
    defer protocol_server.deinit();
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    const PresentationProbe = struct {
        registry: *SurfaceRegistry,
        added_count: usize = 0,
        committed_count: usize = 0,
        removing_count: usize = 0,

        fn listener(self: *@This()) WayringCompositor.PresentationListener {
            return .{
                .context = self,
                .added = added,
                .committed = committed,
                .removing = removing,
            };
        }

        fn added(
            context: *anyopaque,
            id: SurfaceRegistry.Id,
            _: WayringCompositor.FrameCompletion,
        ) error{OutOfMemory}!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            std.debug.assert(self.registry.contains(id));
            std.debug.assert(self.registry.renderState(id) == null);
            self.added_count += 1;
        }

        fn committed(
            context: *anyopaque,
            id: SurfaceRegistry.Id,
            size: ?render.Size,
            _: bool,
        ) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            std.debug.assert(self.registry.contains(id));
            std.debug.assert(size != null and self.registry.renderState(id) != null);
            self.committed_count += 1;
        }

        fn removing(context: *anyopaque, id: SurfaceRegistry.Id) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            std.debug.assert(self.registry.contains(id));
            std.debug.assert(self.registry.renderState(id) != null);
            self.removing_count += 1;
        }
    };
    var presentation_probe: PresentationProbe = .{ .registry = &surface_registry };
    var compositor: WayringCompositor = undefined;
    try compositor.init(
        std.testing.allocator,
        &protocol_server,
        &surface_registry,
        presentation_probe.listener(),
    );
    defer compositor.deinit();
    const Lifecycle = struct {
        fn destroy(erased: *anyopaque, client: *server.Client) void {
            const owner: *WayringCompositor = @ptrCast(@alignCast(erased));
            owner.destroyClientResources(client);
        }
    };
    const host = try WayringHost.create(
        std.testing.allocator,
        event_loop,
        &protocol_server,
        runtime_directory,
        .{ .context = &compositor, .destroy_resources = Lifecycle.destroy },
    );
    var host_live = true;

    var client: TestClient = .{ .runtime_directory = runtime_directory, .display_name = host.displayName() };
    const thread = try std.Thread.spawn(.{}, TestClient.run, .{&client});
    var joined = false;
    defer {
        if (host_live) host.destroy() catch {};
        if (!joined) thread.join();
    }
    var iterations: usize = 0;
    while (true) {
        iterations += 1;
        if (iterations > 200) return error.HostBridgeTimedOut;
        try event_loop.dispatch(50);
        if (host.failure()) |err| return err;
        const status: TestClient.Status = @enumFromInt(client.status.load(.acquire));
        if (status != .running and host.connectionCount() == 0) {
            thread.join();
            joined = true;
            try std.testing.expectEqual(TestClient.Status.success, status);
            break;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), compositor.surfaceCount());
    try std.testing.expectEqual(@as(usize, 1), presentation_probe.added_count);
    try std.testing.expectEqual(@as(usize, 1), presentation_probe.committed_count);
    try std.testing.expectEqual(@as(usize, 1), presentation_probe.removing_count);
    host_live = false;
    try host.destroy();
}
