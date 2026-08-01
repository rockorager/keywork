//! Unix stream transport for Wayring using io_uring.
//!
//! The transport either takes ownership of a connected fd or creates a socket
//! and connects it asynchronously. Its address must remain stable until
//! `readyToDeinit` becomes true; shutdown cancellation does not release buffers
//! referenced by the kernel before terminal CQEs arrive.

const IoUringTransport = @This();

const std = @import("std");
const wayring = @import("wayring");
const keywork_loop = @import("keywork-loop");
const linux = std.os.linux;

const IoUringLoop = keywork_loop.IoUringLoop;
const control_alignment = @alignOf(linux.cmsghdr);
const fd_bytes = wayring.max_fds_per_batch * @sizeOf(i32);
const control_size = std.mem.alignForward(usize, @sizeOf(linux.cmsghdr), control_alignment) +
    std.mem.alignForward(usize, fd_bytes, control_alignment);

pub const Notification = enum { connected, messages, output_drained, eof, fatal };
pub const Notify = *const fn (context: *anyopaque, transport: *IoUringTransport, notification: Notification) anyerror!void;

loop: *IoUringLoop,
connection: *wayring.Connection,
fd: i32,
notify_context: *anyopaque,
notify: Notify,
connect_handle: ?IoUringLoop.Handle = null,
receive_handle: ?IoUringLoop.Handle = null,
send_handle: ?IoUringLoop.Handle = null,
connected: bool = false,
closing: bool = false,
terminal_notified: bool = false,
fd_closed: bool = false,

connect_address: linux.sockaddr.un = undefined,
connect_address_length: linux.socklen_t = 0,

receive_bytes: [64 * 1024]u8 = undefined,
receive_control: [control_size]u8 align(control_alignment) = undefined,
receive_iov: std.posix.iovec = undefined,
receive_msg: linux.msghdr = undefined,

send_iov: std.posix.iovec_const = undefined,
send_msg: linux.msghdr_const = undefined,
send_control: [control_size]u8 align(control_alignment) = undefined,
send_token: u64 = 0,

pub fn init(
    self: *IoUringTransport,
    fd: i32,
    loop: *IoUringLoop,
    connection: *wayring.Connection,
    notify_context: *anyopaque,
    notify: Notify,
) !void {
    self.* = .{
        .loop = loop,
        .connection = connection,
        .fd = fd,
        .notify_context = notify_context,
        .notify = notify,
        .connected = true,
    };
    errdefer _ = linux.close(fd);
    try self.armReceive();
}

/// Creates a Unix socket and submits its connect operation. Queued outbound
/// messages remain buffered until the `.connected` completion.
pub fn initConnect(
    self: *IoUringTransport,
    path: []const u8,
    loop: *IoUringLoop,
    connection: *wayring.Connection,
    notify_context: *anyopaque,
    notify: Notify,
) !void {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidSocketPath;
    var address: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = undefined };
    if (path.len >= address.path.len) return error.SocketPathTooLong;
    @memset(&address.path, 0);
    @memcpy(address.path[0..path.len], path);

    const socket_result = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(socket_result) != .SUCCESS) return error.SocketFailed;
    const fd: i32 = @intCast(socket_result);
    self.* = .{
        .loop = loop,
        .connection = connection,
        .fd = fd,
        .notify_context = notify_context,
        .notify = notify,
        .connect_address = address,
        .connect_address_length = @intCast(@offsetOf(linux.sockaddr.un, "path") + path.len + 1),
    };
    errdefer _ = linux.close(fd);
    self.connect_handle = try self.loop.queue(self, connectComplete, self, prepareConnect);
}

/// Resolves the standard Wayland display environment to an owned socket path.
/// An absolute `WAYLAND_DISPLAY` does not require `XDG_RUNTIME_DIR`.
pub fn waylandSocketPath(allocator: std.mem.Allocator, environ: std.process.Environ) ![]u8 {
    const display: []const u8 = environ.getPosix("WAYLAND_DISPLAY") orelse "wayland-0";
    const runtime_dir = environ.getPosix("XDG_RUNTIME_DIR");
    return waylandSocketPathFrom(allocator, runtime_dir, display);
}

pub fn waylandSocketPathFrom(
    allocator: std.mem.Allocator,
    runtime_dir: ?[]const u8,
    display: []const u8,
) ![]u8 {
    return composeSocketPath(allocator, runtime_dir, display);
}

/// Opens and submits the next Wayring batch when no send is in flight.
pub fn flush(self: *IoUringTransport) !void {
    if (!self.connected or self.closing or self.send_handle != null) return;
    const batch = self.connection.nextBatch() orelse return;
    self.send_token = batch.token;
    self.send_iov = .{ .base = batch.bytes.ptr, .len = batch.bytes.len };
    var control_len: usize = 0;
    if (batch.fds.len != 0) {
        std.debug.assert(batch.fds.len <= wayring.max_fds_per_batch);
        const header: *linux.cmsghdr = @ptrCast(&self.send_control);
        header.* = .{
            .len = @sizeOf(linux.cmsghdr) + batch.fds.len * @sizeOf(i32),
            .level = linux.SOL.SOCKET,
            .type = linux.SCM.RIGHTS,
        };
        const data = self.send_control[std.mem.alignForward(usize, @sizeOf(linux.cmsghdr), control_alignment)..];
        @memcpy(data[0 .. batch.fds.len * @sizeOf(i32)], std.mem.sliceAsBytes(batch.fds));
        control_len = std.mem.alignForward(usize, header.len, control_alignment);
    }
    self.send_msg = .{
        .name = null,
        .namelen = 0,
        .iov = @ptrCast(&self.send_iov),
        .iovlen = 1,
        .control = if (control_len == 0) null else &self.send_control,
        .controllen = control_len,
        .flags = 0,
    };
    self.send_handle = self.loop.queue(self, sendComplete, self, prepareSend) catch |err| {
        try self.connection.acknowledge(batch.token, null);
        return err;
    };
}

pub fn canStartSend(self: *const IoUringTransport) bool {
    return self.connected and !self.closing and self.send_handle == null;
}

pub fn shutdown(self: *IoUringTransport) !void {
    self.closing = true;
    if (self.connect_handle) |handle| try self.loop.remove(handle);
    if (self.receive_handle) |handle| try self.loop.remove(handle);
    if (self.send_handle) |handle| try self.loop.remove(handle);
}

/// Also performs the deferred close once cancellation/completions have drained.
pub fn readyToDeinit(self: *IoUringTransport) bool {
    if (!self.closing) return false;
    if (self.connect_handle) |handle| if (self.loop.isActive(handle)) return false;
    if (self.receive_handle) |handle| if (self.loop.isActive(handle)) return false;
    if (self.send_handle) |handle| if (self.loop.isActive(handle)) return false;
    self.connect_handle = null;
    self.receive_handle = null;
    self.send_handle = null;
    if (!self.fd_closed) {
        _ = linux.close(self.fd);
        self.fd_closed = true;
    }
    return true;
}

fn composeSocketPath(allocator: std.mem.Allocator, runtime_dir: ?[]const u8, display: []const u8) ![]u8 {
    if (display.len == 0 or std.mem.indexOfScalar(u8, display, 0) != null) return error.InvalidDisplay;
    if (display[0] == '/') return allocator.dupe(u8, display);
    const runtime = runtime_dir orelse return error.MissingRuntimeDirectory;
    if (runtime.len == 0 or std.mem.indexOfScalar(u8, runtime, 0) != null) return error.InvalidRuntimeDirectory;
    const separator: []const u8 = if (runtime[runtime.len - 1] == '/') "" else "/";
    return std.mem.concat(allocator, u8, &.{ runtime, separator, display });
}

fn prepareConnect(context: *anyopaque, sqe: *linux.io_uring_sqe) void {
    const self: *IoUringTransport = @ptrCast(@alignCast(context));
    sqe.prep_connect(self.fd, @ptrCast(&self.connect_address), self.connect_address_length);
}

pub fn deinit(self: *IoUringTransport) void {
    std.debug.assert(self.closing);
    std.debug.assert(self.readyToDeinit());
    self.* = undefined;
}

fn armReceive(self: *IoUringTransport) !void {
    std.debug.assert(self.receive_handle == null);
    self.receive_iov = .{ .base = &self.receive_bytes, .len = self.receive_bytes.len };
    self.receive_msg = .{
        .name = null,
        .namelen = 0,
        .iov = @ptrCast(&self.receive_iov),
        .iovlen = 1,
        .control = &self.receive_control,
        .controllen = self.receive_control.len,
        .flags = 0,
    };
    self.receive_handle = try self.loop.queue(self, receiveComplete, self, prepareReceive);
}

fn prepareReceive(context: *anyopaque, sqe: *linux.io_uring_sqe) void {
    const self: *IoUringTransport = @ptrCast(@alignCast(context));
    sqe.prep_recvmsg(self.fd, &self.receive_msg, linux.MSG.CMSG_CLOEXEC);
}

fn prepareSend(context: *anyopaque, sqe: *linux.io_uring_sqe) void {
    const self: *IoUringTransport = @ptrCast(@alignCast(context));
    sqe.prep_sendmsg(self.fd, &self.send_msg, linux.MSG.NOSIGNAL);
}

fn connectComplete(context: *anyopaque, _: *IoUringLoop, completion: IoUringLoop.Completion) !void {
    const self: *IoUringTransport = @ptrCast(@alignCast(context));
    self.connect_handle = null;
    if (completion.result < 0) return self.fail();
    self.connected = true;
    self.armReceive() catch return self.fail();
    self.notify(self.notify_context, self, .connected) catch return self.fail();
    if (!self.closing) self.flush() catch return self.fail();
}

fn receiveComplete(context: *anyopaque, _: *IoUringLoop, completion: IoUringLoop.Completion) !void {
    const self: *IoUringTransport = @ptrCast(@alignCast(context));
    self.receive_handle = null;
    if (completion.result < 0) return self.fail();
    if (completion.result == 0) return self.terminal(.eof);

    var fds: [wayring.max_fds_per_batch]i32 = undefined;
    var fd_count: usize = 0;
    parseControl(self.receive_control[0..self.receive_msg.controllen], &fds, &fd_count) catch {
        closeAll(fds[0..fd_count]);
        return self.fail();
    };
    if (self.receive_msg.flags & linux.MSG.CTRUNC != 0) {
        closeAll(fds[0..fd_count]);
        return self.fail();
    }
    self.connection.feed(self.receive_bytes[0..@intCast(completion.result)], fds[0..fd_count]) catch {
        // feed consumes every descriptor even on failure.
        return self.fail();
    };
    self.notify(self.notify_context, self, .messages) catch return self.fail();
    if (!self.closing) self.armReceive() catch return self.fail();
}

fn sendComplete(context: *anyopaque, _: *IoUringLoop, completion: IoUringLoop.Completion) !void {
    const self: *IoUringTransport = @ptrCast(@alignCast(context));
    self.send_handle = null;
    if (completion.result < 0) {
        try self.connection.acknowledge(self.send_token, null);
        return self.fail();
    }
    try self.connection.acknowledge(self.send_token, @intCast(completion.result));
    if (!self.connection.hasPendingOutput())
        self.notify(self.notify_context, self, .output_drained) catch return self.fail();
    if (!self.closing) self.flush() catch return self.fail();
}

fn fail(self: *IoUringTransport) !void {
    try self.terminal(.fatal);
}

fn terminal(self: *IoUringTransport, notification: Notification) !void {
    if (!self.closing) try self.shutdown();
    if (self.terminal_notified) return;
    self.terminal_notified = true;
    try self.notify(self.notify_context, self, notification);
}

fn parseControl(control: []align(control_alignment) const u8, fds: *[wayring.max_fds_per_batch]i32, count: *usize) !void {
    var offset: usize = 0;
    while (offset < control.len) {
        if (control.len - offset < @sizeOf(linux.cmsghdr)) return error.MalformedControl;
        const header: *align(1) const linux.cmsghdr = @ptrCast(control.ptr + offset);
        if (header.len < @sizeOf(linux.cmsghdr) or header.len > control.len - offset) return error.MalformedControl;
        if (header.level != linux.SOL.SOCKET or header.type != linux.SCM.RIGHTS) return error.UnsupportedControl;
        const payload_len = header.len - @sizeOf(linux.cmsghdr);
        if (payload_len == 0 or payload_len % @sizeOf(i32) != 0) return error.MalformedControl;
        const descriptor_count = payload_len / @sizeOf(i32);
        if (descriptor_count > fds.len - count.*) return error.TooManyDescriptors;
        const data_offset = offset + @sizeOf(linux.cmsghdr);
        @memcpy(std.mem.sliceAsBytes(fds[count.* .. count.* + descriptor_count]), control[data_offset .. data_offset + payload_len]);
        count.* += descriptor_count;
        const next = std.mem.alignForward(usize, offset + header.len, control_alignment);
        if (next <= offset or next > control.len) return error.MalformedControl;
        offset = next;
    }
}

fn closeAll(fds: []const i32) void {
    for (fds) |fd| {
        if (fd >= 0) _ = linux.close(fd);
    }
}

test "connected transports exchange a descriptor and response then cancel" {
    const request_args = [_]wayring.ArgumentSpec{ .{ .kind = .uint }, .{ .kind = .fd } };
    const response_args = [_]wayring.ArgumentSpec{.{ .kind = .uint }};
    const requests = [_]wayring.MessageDescriptor{.{ .name = "request", .opcode = 0, .args = &request_args }};
    const events = [_]wayring.MessageDescriptor{.{ .name = "response", .opcode = 0, .args = &response_args }};
    const interface: wayring.Interface = .{ .name = "transport_test", .version = 1, .requests = &requests, .events = &events };

    const Context = struct {
        client: *IoUringTransport,
        server: *IoUringTransport,
        got_request: bool = false,
        got_response: bool = false,

        fn clientNotify(context: *anyopaque, _: *IoUringTransport, notification: Notification) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (notification != .messages) return;
            var message = self.client.connection.popMessage() orelse return;
            defer message.deinit();
            try std.testing.expectEqual(@as(u32, 42), message.values[0].uint);
            self.got_response = true;
            try self.client.shutdown();
            try self.server.shutdown();
        }

        fn serverNotify(context: *anyopaque, _: *IoUringTransport, notification: Notification) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (notification != .messages) return;
            var message = self.server.connection.popMessage() orelse return;
            defer message.deinit();
            try std.testing.expectEqual(@as(u32, 7), message.values[0].uint);
            const received_fd = try message.takeFd(1);
            defer _ = linux.close(received_fd);
            try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fcntl(received_fd, linux.F.GETFD, 0)));
            self.got_request = true;
            try self.server.connection.queue(1, 0, &.{.{ .uint = 42 }});
            try self.server.flush();
        }
    };

    var sockets: [2]i32 = undefined;
    if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets)) != .SUCCESS)
        return error.SocketPairFailed;
    var sockets_owned = true;
    defer if (sockets_owned) for (sockets) |fd| {
        _ = linux.close(fd);
    };

    var pipe: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) != .SUCCESS) return error.PipeFailed;
    defer _ = linux.close(pipe[1]);
    var pipe_read_owned = true;
    defer if (pipe_read_owned) {
        _ = linux.close(pipe[0]);
    };

    var loop = try IoUringLoop.init(std.testing.allocator);
    defer loop.deinit();
    var client_connection = wayring.Connection.init(std.testing.allocator, .client, 4096);
    defer client_connection.deinit();
    var server_connection = wayring.Connection.init(std.testing.allocator, .server, 4096);
    defer server_connection.deinit();
    _ = try client_connection.registerObject(1, &interface, 1);
    _ = try server_connection.registerObject(1, &interface, 1);

    var client: IoUringTransport = undefined;
    var server: IoUringTransport = undefined;
    var context: Context = .{ .client = &client, .server = &server };
    try client.init(sockets[0], &loop, &client_connection, &context, Context.clientNotify);
    errdefer {
        client.shutdown() catch {};
        while (loop.hasActiveOperations()) loop.runOnce() catch {};
        client.deinit();
    }
    try server.init(sockets[1], &loop, &server_connection, &context, Context.serverNotify);
    sockets_owned = false;

    try client_connection.queue(1, 0, &.{ .{ .uint = 7 }, .{ .fd = pipe[0] } });
    pipe_read_owned = false;
    try client.flush();
    while (loop.hasActiveOperations()) try loop.runOnce();

    try std.testing.expect(context.got_request);
    try std.testing.expect(context.got_response);
    try std.testing.expect(client.readyToDeinit());
    try std.testing.expect(server.readyToDeinit());
    client.deinit();
    server.deinit();
}

test "peer closure reports EOF and drains receive" {
    const Context = struct {
        eof: bool = false,

        fn notify(context: *anyopaque, _: *IoUringTransport, notification: Notification) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (notification == .eof) self.eof = true;
        }
    };

    var sockets: [2]i32 = undefined;
    if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets)) != .SUCCESS)
        return error.SocketPairFailed;
    var transport_fd_owned = true;
    defer if (transport_fd_owned) {
        _ = linux.close(sockets[0]);
    };
    var peer_fd_owned = true;
    defer if (peer_fd_owned) {
        _ = linux.close(sockets[1]);
    };

    var loop = try IoUringLoop.init(std.testing.allocator);
    defer loop.deinit();
    var connection = wayring.Connection.init(std.testing.allocator, .client, 4096);
    defer connection.deinit();
    var context: Context = .{};
    var transport: IoUringTransport = undefined;
    try transport.init(sockets[0], &loop, &connection, &context, Context.notify);
    transport_fd_owned = false;
    _ = linux.close(sockets[1]);
    peer_fd_owned = false;

    while (loop.hasActiveOperations()) try loop.runOnce();
    try std.testing.expect(context.eof);
    try std.testing.expect(transport.readyToDeinit());
    transport.deinit();
}

test "Wayland socket paths and asynchronous connect" {
    const Context = struct {
        connected: bool = false,

        fn notify(context: *anyopaque, transport: *IoUringTransport, notification: Notification) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (notification != .connected) return;
            self.connected = true;
            try transport.shutdown();
        }
    };

    const default_path = try composeSocketPath(std.testing.allocator, "/run/user/1000", "wayland-0");
    defer std.testing.allocator.free(default_path);
    try std.testing.expectEqualStrings("/run/user/1000/wayland-0", default_path);
    const absolute_path = try composeSocketPath(std.testing.allocator, null, "/tmp/wayland-test");
    defer std.testing.allocator.free(absolute_path);
    try std.testing.expectEqualStrings("/tmp/wayland-test", absolute_path);
    try std.testing.expectError(error.MissingRuntimeDirectory, composeSocketPath(std.testing.allocator, null, "wayland-0"));
    try std.testing.expectError(error.MissingRuntimeDirectory, waylandSocketPath(std.testing.allocator, .empty));

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [@sizeOf(@FieldType(linux.sockaddr.un, "path"))]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/wayland-0", .{temporary.sub_path});
    var address: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = undefined };
    @memset(&address.path, 0);
    @memcpy(address.path[0..path.len], path);
    const listener_result = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(listener_result) != .SUCCESS) return error.SocketFailed;
    const listener: i32 = @intCast(listener_result);
    defer _ = linux.close(listener);
    const address_length: linux.socklen_t = @intCast(@offsetOf(linux.sockaddr.un, "path") + path.len + 1);
    if (linux.errno(linux.bind(listener, @ptrCast(&address), address_length)) != .SUCCESS) return error.BindFailed;
    if (linux.errno(linux.listen(listener, 1)) != .SUCCESS) return error.ListenFailed;

    var loop = try IoUringLoop.init(std.testing.allocator);
    defer loop.deinit();
    var connection = wayring.Connection.init(std.testing.allocator, .client, 4096);
    defer connection.deinit();
    var context: Context = .{};
    var transport: IoUringTransport = undefined;
    try transport.initConnect(path, &loop, &connection, &context, Context.notify);
    while (loop.hasActiveOperations()) try loop.runOnce();
    try std.testing.expect(context.connected);
    try std.testing.expect(transport.readyToDeinit());
    transport.deinit();
}
