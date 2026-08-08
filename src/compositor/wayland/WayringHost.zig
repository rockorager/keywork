//! Drives Wayring's caller-owned io_uring from Keywork's existing event loop.
//!
//! Protocol modules own application resources and supply the mandatory client
//! cleanup callback. This host owns only socket, ring, completion routing, and
//! transport connection lifetime.

const WayringHost = @This();

const builtin = @import("builtin");
const std = @import("std");
const wayland = @import("wayland");
const wayring = @import("wayring");

const linux = std.os.linux;
const server = wayring.server;
const wl = wayland.server.wl;

const log = std.log.scoped(.wayring_host);
const submission_capacity = 64;
const route_capacity = submission_capacity * 2;

pub const Alarm = struct {
    context: *anyopaque,
    fired: *const fn (*anyopaque, u64) void,
};

pub const ClientLifecycle = struct {
    context: *anyopaque,
    accepted: *const fn (*anyopaque, *server.Client) anyerror!void,
    destroy_resources: *const fn (*anyopaque, *server.Client) void,
};

pub const Options = struct {
    transport_provenance: server.Client.TransportProvenance = .direct,
};

const AcceptanceFault = enum { reserve, wrapper };
const AddConnectionResult = enum { published, rejected };

const Route = struct {
    external: u64,
    operation: union(enum) {
        transport: wayring.io_uring.OperationToken,
        alarm_poll,
        alarm_cancel,
    },
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
alarm_fd: i32,
event_source: ?*wl.EventSource,
connections: std.ArrayList(*ManagedConnection) = .empty,
routes: [route_capacity]Route = undefined,
route_count: usize = 0,
next_external: u64 = 1,
submission_pending: bool = false,
alarm_callback: ?Alarm = null,
alarm_generation: ?u64 = null,
alarm_poll_active: ?u64 = null,
shutting_down: bool = false,
failure_value: ?anyerror = null,
acceptance_fault: if (builtin.is_test) ?AcceptanceFault else void,

pub fn create(
    allocator: std.mem.Allocator,
    event_loop: *wl.EventLoop,
    protocol_server: *server.Server,
    runtime_directory: []const u8,
    lifecycle: ClientLifecycle,
) !*WayringHost {
    return createWithOptions(allocator, event_loop, protocol_server, runtime_directory, lifecycle, .{});
}

/// Test-capable creation path for a server-owned transport provenance.
pub fn createWithOptions(
    allocator: std.mem.Allocator,
    event_loop: *wl.EventLoop,
    protocol_server: *server.Server,
    runtime_directory: []const u8,
    lifecycle: ClientLifecycle,
    options: Options,
) !*WayringHost {
    const self = try allocator.create(WayringHost);
    errdefer allocator.destroy(self);
    self.* = undefined;
    self.allocator = allocator;
    self.lifecycle = lifecycle;
    self.transport = try wayring.io_uring.Server.listenAutoWithOptions(allocator, protocol_server, runtime_directory, .{
        .transport_provenance = options.transport_provenance,
    });
    errdefer self.transport.deinit() catch {};
    self.ring = try linux.IoUring.init(submission_capacity, 0);
    errdefer self.ring.deinit();
    self.alarm_fd = try linuxFd(linux.timerfd_create(.MONOTONIC, .{
        .CLOEXEC = true,
        .NONBLOCK = true,
    }));
    errdefer _ = linux.close(self.alarm_fd);
    self.event_source = null;
    self.connections = .empty;
    self.route_count = 0;
    self.next_external = 1;
    self.submission_pending = false;
    self.alarm_callback = null;
    self.alarm_generation = null;
    self.alarm_poll_active = null;
    self.shutting_down = false;
    self.failure_value = null;
    self.acceptance_fault = if (builtin.is_test) null else {};
    try self.transport.reserveOperationCapacity(route_capacity);
    self.event_source = try event_loop.addFd(
        *WayringHost,
        self.ring.fd,
        .{ .readable = true, .hangup = true, .@"error" = true },
        handleRingEvent,
        self,
    );
    errdefer self.event_source.?.remove();
    try self.ensureAlarmPoll();
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
    _ = linux.close(self.alarm_fd);
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

/// Installs the host-level one-shot notification endpoint. The callback may
/// rearm the alarm. It is never called for canceled or superseded operations.
pub fn setAlarmCallback(self: *WayringHost, callback: ?Alarm) void {
    self.alarm_callback = callback;
}

/// Arms a monotonic relative one-shot timeout. `null` disarms it; a present
/// delay must be positive. The generation is opaque and returned unchanged.
pub fn armAlarm(self: *WayringHost, delay_ns: ?u64, generation: u64) !void {
    if (self.shutting_down) return error.HostShuttingDown;
    if (delay_ns == 0) return error.InvalidAlarmDelay;

    // Disarm before draining so an old expiry cannot race between the drain
    // and replacement. Updating this fd allocates no io_uring route, so input
    // bursts can rearm indefinitely while the one poll remains outstanding.
    try setAlarmTimer(self.alarm_fd, null);
    _ = try drainAlarm(self.alarm_fd);
    if (delay_ns) |delay| try setAlarmTimer(self.alarm_fd, delay);
    self.alarm_generation = if (delay_ns != null) generation else null;
}

fn cancelAlarm(self: *WayringHost) !void {
    self.alarm_generation = null;
    setAlarmTimer(self.alarm_fd, null) catch |err| self.recordFailure(err);
    const target = self.alarm_poll_active orelse return;
    if (self.route_count == self.routes.len) return error.RouteCapacityExhausted;
    const external = try self.takeExternal();
    _ = self.ring.poll_remove(external, target) catch |err| switch (err) {
        error.SubmissionQueueFull => {
            try self.submitPending();
            _ = try self.ring.poll_remove(external, target);
        },
    };
    self.routes[self.route_count] = .{ .external = external, .operation = .alarm_cancel };
    self.route_count += 1;
    self.submission_pending = true;
    self.alarm_poll_active = null;
}

fn takeExternal(self: *WayringHost) !u64 {
    const external = self.next_external;
    self.next_external +%= 1;
    if (self.next_external == 0) return error.ExternalUserDataExhausted;
    return external;
}

fn ensureAlarmPoll(self: *WayringHost) !void {
    if (self.shutting_down or self.alarm_poll_active != null) return;
    if (self.route_count == self.routes.len) return error.RouteCapacityExhausted;
    const external = try self.takeExternal();
    _ = try self.ring.poll_add(external, self.alarm_fd, linux.POLL.IN);
    self.routes[self.route_count] = .{ .external = external, .operation = .alarm_poll };
    self.route_count += 1;
    self.submission_pending = true;
    self.alarm_poll_active = external;
}

fn setAlarmTimer(fd: i32, delay_ns: ?u64) !void {
    const zero: linux.timespec = .{ .sec = 0, .nsec = 0 };
    const value = if (delay_ns) |delay| alarmTime(delay) else zero;
    const spec: linux.itimerspec = .{ .it_interval = zero, .it_value = value };
    try linuxVoid(linux.timerfd_settime(fd, .{ .ABSTIME = false }, &spec, null));
}

fn alarmTime(delay_ns: u64) linux.timespec {
    std.debug.assert(delay_ns > 0);
    return .{
        .sec = @intCast(delay_ns / std.time.ns_per_s),
        .nsec = @intCast(delay_ns % std.time.ns_per_s),
    };
}

fn drainAlarm(fd: i32) !bool {
    var expirations: u64 = 0;
    var expired = false;
    while (true) {
        const result = linux.read(fd, @ptrCast(&expirations), @sizeOf(u64));
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result != @sizeOf(u64)) return error.AlarmReadFailed;
                expired = true;
            },
            .AGAIN => return expired,
            .INTR => continue,
            else => return error.AlarmReadFailed,
        }
    }
}

fn linuxFd(result: usize) !i32 {
    return switch (linux.errno(result)) {
        .SUCCESS => @intCast(result),
        else => error.LinuxSyscallFailed,
    };
}

fn linuxVoid(result: usize) !void {
    return switch (linux.errno(result)) {
        .SUCCESS => {},
        else => error.LinuxSyscallFailed,
    };
}

pub fn beginShutdown(self: *WayringHost) void {
    if (!self.shutting_down) {
        self.shutting_down = true;
        self.cancelAlarm() catch |err| self.recordFailure(err);
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
    // Keep one route available for poll_remove while the persistent alarm
    // poll is live. Once shutdown has queued that cancellation, transport
    // teardown may use the complete route table.
    const route_limit = if (self.shutting_down) self.routes.len else self.routes.len - 1;
    while (self.route_count < route_limit) {
        switch (try self.transport.prepareNext(&self.ring, self.next_external)) {
            .prepared => |token| {
                self.routes[self.route_count] = .{ .external = self.next_external, .operation = .{ .transport = token } };
                self.route_count += 1;
                self.submission_pending = true;
                _ = try self.takeExternal();
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
    const route = self.takeRoute(cqe.user_data) orelse return error.UnknownCompletion;
    switch (route.operation) {
        .alarm_poll => {
            if (self.alarm_poll_active != route.external) return;
            self.alarm_poll_active = null;
            if (cqe.res == -@as(i32, @intFromEnum(linux.E.CANCELED))) return;
            if (cqe.res < 0) return error.AlarmFailed;
            const expired = try drainAlarm(self.alarm_fd);
            const generation = if (expired) self.alarm_generation else null;
            if (expired) self.alarm_generation = null;
            try self.ensureAlarmPoll();
            if (!self.shutting_down) if (generation) |value| if (self.alarm_callback) |callback|
                callback.fired(callback.context, value);
            return;
        },
        .alarm_cancel => {
            if (cqe.res < 0 and cqe.res != -@as(i32, @intFromEnum(linux.E.ALREADY)) and
                cqe.res != -@as(i32, @intFromEnum(linux.E.NOENT))) return error.AlarmCancellationFailed;
            return;
        },
        .transport => |token| return self.completeTransport(token, cqe),
    }
}

fn completeTransport(self: *WayringHost, token: wayring.io_uring.OperationToken, cqe: linux.io_uring_cqe) !void {
    const completed = try self.transport.complete(token, cqe.res, cqe.flags);
    switch (completed) {
        .accepted => |connection| _ = try self.addConnection(connection),
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

fn addConnection(self: *WayringHost, connection: *wayring.io_uring.Connection) !AddConnectionResult {
    self.reserveConnection() catch {
        try self.rejectConnection(connection, null);
        return .rejected;
    };
    const managed = self.createManagedConnection() catch {
        try self.rejectConnection(connection, null);
        return .rejected;
    };
    managed.* = .{ .connection = connection };
    self.lifecycle.accepted(self.lifecycle.context, connection.client()) catch {
        try self.rejectConnection(connection, managed);
        return .rejected;
    };
    self.connections.appendAssumeCapacity(managed);
    return .published;
}

fn reserveConnection(self: *WayringHost) !void {
    if (self.failAcceptanceAt(.reserve)) return error.OutOfMemory;
    try self.connections.ensureUnusedCapacity(self.allocator, 1);
}

fn createManagedConnection(self: *WayringHost) !*ManagedConnection {
    if (self.failAcceptanceAt(.wrapper)) return error.OutOfMemory;
    return self.allocator.create(ManagedConnection);
}

fn failAcceptanceAt(self: *WayringHost, point: AcceptanceFault) bool {
    if (comptime !builtin.is_test) return false;
    if (self.acceptance_fault != point) return false;
    self.acceptance_fault = null;
    return true;
}

fn rejectConnection(
    self: *WayringHost,
    connection: *wayring.io_uring.Connection,
    managed: ?*ManagedConnection,
) !void {
    // This callback is intentionally unconditional so partially completed
    // application registration follows the same idempotent rollback path.
    self.lifecycle.destroy_resources(self.lifecycle.context, connection.client());
    self.transport.release(connection) catch |err| {
        // A wrapper allocated before application acceptance keeps ownership
        // recoverable if broken cleanup leaves transport state live.
        if (managed) |value| {
            value.retiring = true;
            value.resources_destroyed = true;
            self.connections.appendAssumeCapacity(value);
        }
        return err;
    };
    if (managed) |value| self.allocator.destroy(value);
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
        managed.connection.synchronizeFatal();
        if (!managed.retiring and managed.connection.state() == .terminal and
            !managed.connection.client().hasPendingOutput())
        {
            managed.retiring = true;
        }
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

fn takeRoute(self: *WayringHost, external: u64) ?Route {
    for (self.routes[0..self.route_count], 0..) |route, index| {
        if (route.external != external) continue;
        self.routes[index] = self.routes[self.route_count - 1];
        self.route_count -= 1;
        return route;
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

test "stale alarm poll completions are harmless" {
    var host: WayringHost = undefined;
    host.route_count = 1;
    host.routes[0] = .{ .external = 41, .operation = .alarm_poll };
    host.alarm_generation = std.math.maxInt(u64);
    host.alarm_poll_active = 42;
    host.shutting_down = false;

    try host.completeOne(.{ .user_data = 41, .res = 0, .flags = 0 });
    try std.testing.expectEqual(std.math.maxInt(u64), host.alarm_generation.?);
    try std.testing.expectEqual(@as(?u64, 42), host.alarm_poll_active);
    try std.testing.expectEqual(@as(usize, 0), host.route_count);
}

test "alarm nanoseconds preserve positive boundaries and maximum delay" {
    try std.testing.expectEqual(linux.timespec{ .sec = 0, .nsec = 1 }, alarmTime(1));
    try std.testing.expectEqual(
        linux.timespec{ .sec = 1, .nsec = 0 },
        alarmTime(std.time.ns_per_s),
    );
    try std.testing.expectEqual(
        linux.timespec{
            .sec = @intCast(std.math.maxInt(u64) / std.time.ns_per_s),
            .nsec = @intCast(std.math.maxInt(u64) % std.time.ns_per_s),
        },
        alarmTime(std.math.maxInt(u64)),
    );
}

test "alarm cancellation completion drains its route" {
    var host: WayringHost = undefined;
    host.route_count = 1;
    host.routes[0] = .{ .external = 52, .operation = .alarm_cancel };
    host.shutting_down = true;

    try host.completeOne(.{ .user_data = 52, .res = 0, .flags = 0 });
    try std.testing.expectEqual(@as(usize, 0), host.route_count);
}

test "normal route reservation leaves capacity to cancel alarm poll" {
    var host: WayringHost = undefined;
    host.ring = try linux.IoUring.init(submission_capacity, 0);
    defer host.ring.deinit();
    host.alarm_fd = try linuxFd(linux.timerfd_create(.MONOTONIC, .{
        .CLOEXEC = true,
        .NONBLOCK = true,
    }));
    defer _ = linux.close(host.alarm_fd);
    host.route_count = host.routes.len - 1;
    host.next_external = 2;
    host.submission_pending = false;
    host.alarm_generation = 7;
    host.alarm_poll_active = 1;

    try host.cancelAlarm();
    try std.testing.expectEqual(host.routes.len, host.route_count);
    switch (host.routes[host.routes.len - 1].operation) {
        .alarm_cancel => {},
        else => return error.ExpectedAlarmCancelRoute,
    }
    try std.testing.expectEqual(@as(?u64, null), host.alarm_poll_active);
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

    fn accepted(_: *anyopaque, _: *server.Client) !void {}

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

const AcceptanceProbe = struct {
    const ClientRegistry = @import("../ClientRegistry.zig");
    const WayringClients = @import("WayringClients.zig");

    clients: *WayringClients,
    registry: *ClientRegistry,
    host: ?*WayringHost = null,
    accepted_clients: [4]?*server.Client = @splat(null),
    accepted_ids: [4]?ClientRegistry.Id = @splat(null),
    accepted_count: usize = 0,
    destroy_count: usize = 0,
    disconnect_count: usize = 0,
    fail_next: bool = false,
    partial_client: ?*server.Client = null,
    partial_resource: ?server.Resource = null,
    resources_destroyed: bool = false,
    destroying_client: ?*server.Client = null,
    destroying_id: ?ClientRegistry.Id = null,
    ordering_valid: bool = true,
    accepted_before_publication: bool = true,
    accepted_before_receive: bool = true,

    fn accepted(erased: *anyopaque, client: *server.Client) !void {
        const self: *AcceptanceProbe = @ptrCast(@alignCast(erased));
        const host = self.host.?;
        self.accepted_before_publication = self.accepted_before_publication and
            self.registry.len() == host.connectionCount();
        self.accepted_before_receive = self.accepted_before_receive and client.lookup(2) == null;
        const client_id = try self.clients.register(client);
        const index = self.accepted_count;
        self.accepted_clients[index] = client;
        self.accepted_ids[index] = client_id;
        self.accepted_count += 1;
        if (!self.fail_next) return;

        self.fail_next = false;
        self.partial_client = client;
        self.partial_resource = .init(
            std.testing.allocator,
            2,
            1,
            &cleanup_test_interface,
            &.{},
            .client,
            client.ownerHooks(),
        );
        try client.installClientInitial(2, &self.partial_resource.?);
        return error.OutOfMemory;
    }

    fn destroy(erased: *anyopaque, client: *server.Client) void {
        const self: *AcceptanceProbe = @ptrCast(@alignCast(erased));
        self.destroy_count += 1;
        self.resources_destroyed = false;
        if (self.partial_client == client) {
            const resource = &self.partial_resource.?;
            resource.destroy();
            resource.deinit();
            self.partial_resource = null;
            self.partial_client = null;
        }
        self.resources_destroyed = true;
        if (self.clients.id(client)) |client_id| {
            self.destroying_client = client;
            self.destroying_id = client_id;
            self.clients.unregister(client);
            self.destroying_client = null;
            self.destroying_id = null;
        }
    }

    fn disconnected(erased: *anyopaque, client_id: ClientRegistry.Id) void {
        const self: *AcceptanceProbe = @ptrCast(@alignCast(erased));
        self.disconnect_count += 1;
        const client = self.destroying_client orelse {
            self.ordering_valid = false;
            return;
        };
        self.ordering_valid = self.ordering_valid and self.resources_destroyed and
            std.meta.eql(self.destroying_id.?, client_id) and
            !self.registry.contains(client_id) and self.clients.id(client) == null;
    }
};

test "acceptance is pre-receive and every rejection path is client-local" {
    const ClientRegistry = @import("../ClientRegistry.zig");
    const WayringClients = @import("WayringClients.zig");
    var marker: u8 = 0;
    const runtime_directory = try std.fmt.allocPrintSentinel(
        std.testing.allocator,
        "/tmp/keywork-wayring-acceptance-{d}-{x}",
        .{ linux.getpid(), @intFromPtr(&marker) },
        0,
    );
    defer std.testing.allocator.free(runtime_directory);
    if (linux.errno(linux.mkdir(runtime_directory.ptr, 0o700)) != .SUCCESS)
        return error.TestDirectoryCreationFailed;
    defer _ = linux.rmdir(runtime_directory.ptr);

    const event_loop = try wl.EventLoop.create();
    defer event_loop.destroy();
    var protocol_server: server.Server = .init(std.testing.allocator);
    defer protocol_server.deinit();
    var registry = ClientRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var clients: WayringClients = undefined;
    clients.init(std.testing.allocator, &registry);
    defer clients.deinit();
    var probe: AcceptanceProbe = .{ .clients = &clients, .registry = &registry };
    try registry.addDisconnectListener(.{
        .context = &probe,
        .notify = AcceptanceProbe.disconnected,
    });
    defer registry.removeDisconnectListener(&probe);
    const host = try WayringHost.create(
        std.testing.allocator,
        event_loop,
        &protocol_server,
        runtime_directory,
        .{
            .context = &probe,
            .accepted = AcceptanceProbe.accepted,
            .destroy_resources = AcceptanceProbe.destroy,
        },
    );
    probe.host = host;
    var host_live = true;
    defer if (host_live) host.destroy() catch {};
    const path = try std.fmt.allocPrintSentinel(
        std.testing.allocator,
        "{s}/{s}",
        .{ runtime_directory, host.displayName() },
        0,
    );
    defer std.testing.allocator.free(path);

    const first_peer = try connectSocket(path);
    defer _ = linux.close(first_peer);
    const sync_request = [_]u8{
        1, 0, 0,  0,
        0, 0, 12, 0,
        2, 0, 0,  0,
    };
    if (std.c.write(first_peer, &sync_request, sync_request.len) != sync_request.len)
        return error.TestWriteFailed;
    _ = try waitForManagedConnection(event_loop, host);
    for (0..4) |_| try event_loop.dispatch(50);
    try std.testing.expect(probe.accepted_clients[0].?.fatal() == null);

    probe.fail_next = true;
    const rejected_peer = try connectSocket(path);
    defer _ = linux.close(rejected_peer);
    for (0..200) |_| {
        try event_loop.dispatch(50);
        if (host.failure()) |err| return err;
        if (probe.destroy_count == 1) break;
    }
    try std.testing.expectEqual(@as(usize, 1), probe.destroy_count);
    try std.testing.expect(!registry.contains(probe.accepted_ids[1].?));

    inline for (.{ AcceptanceFault.reserve, AcceptanceFault.wrapper }) |fault| {
        host.acceptance_fault = fault;
        const peer = try connectSocket(path);
        const expected_destroy_count = probe.destroy_count + 1;
        for (0..200) |_| {
            try event_loop.dispatch(50);
            if (host.failure()) |err| return err;
            if (probe.destroy_count == expected_destroy_count) break;
        }
        _ = linux.close(peer);
        try std.testing.expectEqual(expected_destroy_count, probe.destroy_count);
    }

    try std.testing.expect(probe.accepted_before_publication);
    try std.testing.expect(probe.accepted_before_receive);
    try std.testing.expect(probe.ordering_valid);
    try std.testing.expectEqual(@as(usize, 2), probe.accepted_count);
    try std.testing.expectEqual(@as(usize, 1), probe.disconnect_count);
    try std.testing.expectEqual(@as(usize, 1), registry.len());
    try std.testing.expectEqual(@as(usize, 1), host.connectionCount());
    try std.testing.expect(host.failure() == null);
    try std.testing.expect(!host.shutting_down);
    try std.testing.expect(probe.accepted_clients[0].?.fatal() == null);

    host_live = false;
    try host.destroy();
    try std.testing.expectEqual(@as(usize, 4), probe.destroy_count);
    try std.testing.expectEqual(@as(usize, 2), probe.disconnect_count);
    try std.testing.expectEqual(@as(usize, 0), registry.len());
    try std.testing.expect(probe.ordering_valid);
}

test "asynchronous fatal drains output retires one client and preserves the host" {
    const ClientRegistry = @import("../ClientRegistry.zig");
    const WayringClients = @import("WayringClients.zig");
    var marker: u8 = 0;
    const runtime_directory = try std.fmt.allocPrintSentinel(
        std.testing.allocator,
        "/tmp/keywork-wayring-async-fatal-{d}-{x}",
        .{ linux.getpid(), @intFromPtr(&marker) },
        0,
    );
    defer std.testing.allocator.free(runtime_directory);
    if (linux.errno(linux.mkdir(runtime_directory.ptr, 0o700)) != .SUCCESS)
        return error.TestDirectoryCreationFailed;
    defer _ = linux.rmdir(runtime_directory.ptr);

    const event_loop = try wl.EventLoop.create();
    defer event_loop.destroy();
    var protocol_server: server.Server = .init(std.testing.allocator);
    defer protocol_server.deinit();
    var registry = ClientRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var clients: WayringClients = undefined;
    clients.init(std.testing.allocator, &registry);
    defer clients.deinit();
    var probe: AcceptanceProbe = .{ .clients = &clients, .registry = &registry };
    try registry.addDisconnectListener(.{
        .context = &probe,
        .notify = AcceptanceProbe.disconnected,
    });
    defer registry.removeDisconnectListener(&probe);
    const host = try WayringHost.create(
        std.testing.allocator,
        event_loop,
        &protocol_server,
        runtime_directory,
        .{
            .context = &probe,
            .accepted = AcceptanceProbe.accepted,
            .destroy_resources = AcceptanceProbe.destroy,
        },
    );
    probe.host = host;
    var host_live = true;
    defer if (host_live) host.destroy() catch {};
    const path = try std.fmt.allocPrintSentinel(
        std.testing.allocator,
        "{s}/{s}",
        .{ runtime_directory, host.displayName() },
        0,
    );
    defer std.testing.allocator.free(path);

    const first_peer = try connectSocket(path);
    defer _ = linux.close(first_peer);
    _ = try waitForManagedConnection(event_loop, host);
    const second_peer = try connectSocket(path);
    defer _ = linux.close(second_peer);
    for (0..200) |_| {
        try event_loop.dispatch(50);
        if (host.failure()) |err| return err;
        if (host.connectionCount() == 2) break;
    }
    try std.testing.expectEqual(@as(usize, 2), host.connectionCount());

    const retiring_client = host.connections.items[0].connection.client();
    retiring_client.postOutOfMemory(
        retiring_client.lookup(1).?,
        "asynchronous generated output failure",
    );
    try host.dispatchReady();
    for (0..200) |_| {
        try event_loop.dispatch(50);
        if (host.failure()) |err| return err;
        if (host.connectionCount() == 1) break;
    }
    try std.testing.expectEqual(@as(usize, 1), host.connectionCount());
    var fatal_frame: [256]u8 = undefined;
    try std.testing.expect(std.c.read(first_peer, &fatal_frame, fatal_frame.len) > 0);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, fatal_frame[0..4], .native));
    try std.testing.expectEqual(@as(usize, 1), probe.destroy_count);
    try std.testing.expectEqual(@as(usize, 1), probe.disconnect_count);
    try std.testing.expectEqual(@as(usize, 1), registry.len());
    try std.testing.expect(host.failure() == null);
    try std.testing.expect(!host.shutting_down);
    try std.testing.expectEqual(wayring.io_uring.Connection.State.ready, host.connections.items[0].connection.state());
    try std.testing.expect(host.connections.items[0].connection.client().fatal() == null);
    try std.testing.expect(probe.ordering_valid);

    host_live = false;
    try host.destroy();
    try std.testing.expectEqual(@as(usize, 2), probe.destroy_count);
    try std.testing.expectEqual(@as(usize, 2), probe.disconnect_count);
    try std.testing.expectEqual(@as(usize, 0), registry.len());
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
        .{
            .context = &cleanup,
            .accepted = CleanupProbe.accepted,
            .destroy_resources = CleanupProbe.destroy,
        },
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
    try std.testing.expectEqual(error.AlarmCancellationFailed, destroy_failure.?);
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
        .{
            .context = &cleanup,
            .accepted = CleanupProbe.accepted,
            .destroy_resources = CleanupProbe.destroy,
        },
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
                .detached = detached,
                .applied = applied,
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

        fn detached(_: *anyopaque, _: SurfaceRegistry.Id) void {}

        fn applied(context: *anyopaque, batch: WayringCompositor.AppliedBatch) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            std.debug.assert(batch.surfaces.len == 1);
            std.debug.assert(batch.parents.len == 0);
            const id = batch.surfaces[0].id;
            const size = batch.surfaces[0].mapped_size;
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
        fn accepted(_: *anyopaque, _: *server.Client) !void {}

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
        .{
            .context = &compositor,
            .accepted = Lifecycle.accepted,
            .destroy_resources = Lifecycle.destroy,
        },
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
