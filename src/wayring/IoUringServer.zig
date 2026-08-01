//! io_uring listener and multi-client transport for the sans-I/O Wayring server.
//!
//! Completion callbacks only record ordered transport events. `dispatch`
//! applies them after the caller drains a CQ turn, runs protocol policy, starts
//! queued sends, and reaps clients whose terminal completions have arrived.

const IoUringServer = @This();

const std = @import("std");
const linux = std.os.linux;
const keywork_loop = @import("keywork-loop");
const IoUringTransport = @import("wayring-uring");
const Server = @import("wayring-server");

const IoUringLoop = keywork_loop.IoUringLoop;
const EventLoop = keywork_loop.EventLoop;

pub const default_max_pending_output_bytes: usize = 4 * 1024 * 1024;

const Peer = struct {
    owner: *IoUringServer,
    client: *Server.Client,
    transport: IoUringTransport,
    terminal: bool = false,
};

const Pending = struct {
    peer: *Peer,
    notification: IoUringTransport.Notification,
};

allocator: std.mem.Allocator,
loop: *IoUringLoop,
server: *Server,
listener_fd: i32,
max_pending_output_bytes: usize,
accept_handle: ?IoUringLoop.Handle = null,
accept_cancel_requested: bool = false,
clients: std.ArrayList(*Peer) = .empty,
pending: std.ArrayList(Pending) = .empty,
multishot_accept: bool = true,
closing: bool = false,
listener_closed: bool = false,

/// Takes ownership of an already bound and listening Unix stream socket.
pub fn init(
    self: *IoUringServer,
    allocator: std.mem.Allocator,
    loop: *IoUringLoop,
    server: *Server,
    listener_fd: i32,
) !void {
    return self.initWithLimit(
        allocator,
        loop,
        server,
        listener_fd,
        default_max_pending_output_bytes,
    );
}

pub fn initWithLimit(
    self: *IoUringServer,
    allocator: std.mem.Allocator,
    loop: *IoUringLoop,
    server: *Server,
    listener_fd: i32,
    max_pending_output_bytes: usize,
) !void {
    if (max_pending_output_bytes == 0) return error.InvalidOutputLimit;
    self.* = .{
        .allocator = allocator,
        .loop = loop,
        .server = server,
        .listener_fd = listener_fd,
        .max_pending_output_bytes = max_pending_output_bytes,
    };
    errdefer _ = linux.close(listener_fd);
    try self.armAccept();
}

/// Dispatches transport notifications in CQ order. This must run after each
/// outer ring drain and before policy-owned end-of-turn work.
pub fn dispatch(self: *IoUringServer) !void {
    var index: usize = 0;
    var completed = false;
    defer {
        if (index != 0) self.pending.replaceRangeAssumeCapacity(0, index, &.{});
        if (completed) self.reapClients();
    }
    while (index < self.pending.items.len) {
        const item = self.pending.items[index];
        index += 1;
        const peer = item.peer;
        switch (item.notification) {
            .connected => unreachable,
            .messages => {
                if (!peer.terminal and peer.client.state == .active) {
                    peer.client.dispatchPending() catch |err| switch (err) {
                        error.ProtocolError, error.ProtocolErrorWithoutEvent => {},
                        else => {
                            peer.terminal = true;
                            try peer.transport.shutdown();
                        },
                    };
                }
                try self.flushPeer(peer);
            },
            .output_drained => {
                peer.client.outputDrained() catch {
                    peer.terminal = true;
                    try peer.transport.shutdown();
                };
            },
            .eof, .fatal => peer.terminal = true,
        }
        if (!peer.terminal and peer.client.shouldDisconnect()) {
            peer.terminal = true;
            try peer.transport.shutdown();
        } else if (peer.terminal and !peer.transport.closing) {
            try peer.transport.shutdown();
        }
    }
    try self.flush();
    completed = true;
}

/// Starts pending sends for events queued outside request dispatch, including
/// timer, renderer, and global-catalog updates.
pub fn flush(self: *IoUringServer) !void {
    for (self.clients.items) |peer| try self.flushPeer(peer);
}

/// EventLoop phase adapter that dispatches protocol work after CQ draining.
pub fn afterPlatformHook(context: *anyopaque, _: *EventLoop) !void {
    const self: *IoUringServer = @ptrCast(@alignCast(context));
    try self.dispatch();
}

/// EventLoop phase adapter that flushes events queued by later turn phases.
pub fn endTurnHook(context: *anyopaque, _: *EventLoop) !void {
    const self: *IoUringServer = @ptrCast(@alignCast(context));
    try self.flush();
}

pub fn shutdown(self: *IoUringServer) !void {
    self.closing = true;
    var first_error: ?anyerror = null;
    if (self.accept_handle) |handle| if (!self.accept_cancel_requested) {
        self.loop.cancel(handle) catch |err| {
            first_error = err;
        };
        if (first_error == null) self.accept_cancel_requested = true;
    };
    for (self.clients.items) |peer| {
        peer.terminal = true;
        if (!peer.transport.closing) peer.transport.shutdown() catch |err| {
            if (first_error == null) first_error = err;
        };
    }
    if (first_error) |err| return err;
}

/// Reports readiness only after listener and client operations have delivered
/// terminal CQEs. Calls may close the listener once cancellation is complete.
pub fn readyToDeinit(self: *IoUringServer) bool {
    if (!self.closing) return false;
    if (self.pending.items.len != 0) return false;
    self.reapClients();
    if (self.accept_handle) |handle| {
        if (self.loop.isActive(handle)) return false;
        self.accept_handle = null;
    }
    if (self.clients.items.len != 0) return false;
    if (!self.listener_closed) {
        _ = linux.close(self.listener_fd);
        self.listener_closed = true;
    }
    return true;
}

pub fn clientCount(self: *const IoUringServer) usize {
    return self.clients.items.len;
}

pub fn deinit(self: *IoUringServer) void {
    std.debug.assert(self.closing);
    std.debug.assert(self.pending.items.len == 0);
    std.debug.assert(self.readyToDeinit());
    self.pending.deinit(self.allocator);
    self.clients.deinit(self.allocator);
    self.* = undefined;
}

fn armAccept(self: *IoUringServer) !void {
    if (self.closing or self.accept_handle != null) return;
    self.accept_handle = try self.loop.queue(self, acceptComplete, self, prepareAccept);
}

fn prepareAccept(context: *anyopaque, sqe: *linux.io_uring_sqe) void {
    const self: *IoUringServer = @ptrCast(@alignCast(context));
    if (self.multishot_accept)
        sqe.prep_multishot_accept(
            self.listener_fd,
            null,
            null,
            linux.SOCK.CLOEXEC,
        )
    else
        sqe.prep_accept(self.listener_fd, null, null, linux.SOCK.CLOEXEC);
}

fn acceptComplete(
    context: *anyopaque,
    _: *IoUringLoop,
    completion: IoUringLoop.Completion,
) !void {
    const self: *IoUringServer = @ptrCast(@alignCast(context));
    if (!completion.more()) self.accept_handle = null;
    if (completion.result >= 0) {
        const fd: i32 = @intCast(completion.result);
        if (self.closing)
            _ = linux.close(fd)
        else
            try self.addClient(fd);
    } else if (!self.closing and
        completion.result == -@as(i32, @intFromEnum(linux.E.INVAL)) and
        self.multishot_accept)
    {
        self.multishot_accept = false;
    } else if (!self.closing and completion.result != -@as(i32, @intFromEnum(linux.E.CANCELED))) {
        // A failed accept consumes no connection state. Re-arming below keeps
        // transient per-connection errors from stopping the listener.
    }
    if (!self.closing and !completion.more()) try self.armAccept();
}

fn addClient(self: *IoUringServer, fd: i32) !void {
    var fd_owned = true;
    errdefer if (fd_owned) {
        _ = linux.close(fd);
    };
    try self.clients.ensureUnusedCapacity(self.allocator, 1);
    const peer = try self.allocator.create(Peer);
    errdefer self.allocator.destroy(peer);
    const client = try self.server.createClient();
    errdefer self.server.destroyClient(client) catch unreachable;
    peer.* = .{
        .owner = self,
        .client = client,
        .transport = undefined,
    };
    // IoUringTransport owns and closes the descriptor on both success and
    // initialization failure after this point.
    fd_owned = false;
    try peer.transport.init(
        fd,
        self.loop,
        &client.connection,
        peer,
        transportNotify,
    );
    self.clients.appendAssumeCapacity(peer);
}

fn transportNotify(
    context: *anyopaque,
    _: *IoUringTransport,
    notification: IoUringTransport.Notification,
) !void {
    const peer: *Peer = @ptrCast(@alignCast(context));
    try peer.owner.pending.append(peer.owner.allocator, .{
        .peer = peer,
        .notification = notification,
    });
}

fn flushPeer(self: *IoUringServer, peer: *Peer) !void {
    if (peer.terminal) return;
    if (peer.client.connection.pendingOutputBytes() > self.max_pending_output_bytes) {
        peer.terminal = true;
        try peer.transport.shutdown();
        return;
    }
    peer.transport.flush() catch |err| {
        peer.terminal = true;
        peer.transport.shutdown() catch {};
        return err;
    };
}

fn reapClients(self: *IoUringServer) void {
    var index: usize = 0;
    while (index < self.clients.items.len) {
        const peer = self.clients.items[index];
        if (!peer.transport.readyToDeinit()) {
            index += 1;
            continue;
        }
        peer.transport.deinit();
        self.server.destroyClient(peer.client) catch unreachable;
        self.allocator.destroy(peer);
        _ = self.clients.swapRemove(index);
    }
}

test "listener accepts a client and completes native display sync" {
    const wayring = @import("wayring");
    const core = @import("wayring-core");

    const ClientContext = struct {
        connection: *wayring.Connection,
        callback_id: u32,
        got_done: bool = false,
        got_delete: bool = false,
        fatal: bool = false,

        fn notify(
            context: *anyopaque,
            transport: *IoUringTransport,
            notification: IoUringTransport.Notification,
        ) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (notification) {
                .connected => try transport.flush(),
                .messages => while (self.connection.popMessage()) |popped| {
                    var message = popped;
                    defer message.deinit();
                    if (message.object_id == self.callback_id) {
                        _ = try core.decodeCallbackEvent(&message, self.callback_id);
                        self.got_done = true;
                    } else {
                        try std.testing.expectEqual(
                            self.callback_id,
                            (try core.decodeDisplayEvent(&message)).delete_id,
                        );
                        self.got_delete = true;
                        try transport.shutdown();
                    }
                },
                .output_drained, .eof => {},
                .fatal => self.fatal = true,
            }
        }
    };

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [@sizeOf(@FieldType(linux.sockaddr.un, "path"))]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/wayring-server",
        .{temporary.sub_path},
    );
    var address: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = undefined };
    @memset(&address.path, 0);
    @memcpy(address.path[0..path.len], path);
    const listener_result = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(listener_result) != .SUCCESS) return error.SocketFailed;
    const listener: i32 = @intCast(listener_result);
    var listener_owned = true;
    defer if (listener_owned) {
        _ = linux.close(listener);
    };
    const address_length: linux.socklen_t = @intCast(
        @offsetOf(linux.sockaddr.un, "path") + path.len + 1,
    );
    if (linux.errno(linux.bind(listener, @ptrCast(&address), address_length)) != .SUCCESS)
        return error.BindFailed;
    if (linux.errno(linux.listen(listener, 8)) != .SUCCESS) return error.ListenFailed;

    var loop = try IoUringLoop.init(std.testing.allocator);
    defer loop.deinit();
    var native_server = Server.init(std.testing.allocator);
    defer native_server.deinit();
    var transport_server: IoUringServer = undefined;
    try transport_server.init(
        std.testing.allocator,
        &loop,
        &native_server,
        listener,
    );
    listener_owned = false;

    var connection = wayring.Connection.init(
        std.testing.allocator,
        .client,
        wayring.default_max_frame_size,
    );
    defer connection.deinit();
    _ = try core.bootstrapDisplay(&connection);
    const callback_id: u32 = 2;
    _ = try core.sync(&connection, callback_id);
    var client_context: ClientContext = .{
        .connection = &connection,
        .callback_id = callback_id,
    };
    var client_transport: IoUringTransport = undefined;
    try client_transport.initConnect(
        path,
        &loop,
        &connection,
        &client_context,
        ClientContext.notify,
    );

    var turns: usize = 0;
    while (!client_context.got_delete and turns < 32) : (turns += 1) {
        try loop.runOnce();
        try transport_server.dispatch();
    }
    try std.testing.expect(client_context.got_done);
    try std.testing.expect(client_context.got_delete);
    try std.testing.expect(!client_context.fatal);

    try transport_server.shutdown();
    while (loop.hasActiveOperations()) {
        try loop.runOnce();
        try transport_server.dispatch();
    }
    try transport_server.dispatch();
    try std.testing.expect(transport_server.readyToDeinit());
    try std.testing.expect(client_transport.readyToDeinit());
    transport_server.deinit();
    client_transport.deinit();
}
