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

/// One owned listener-level template that creates independent client values.
pub const ProvenanceTemplate = struct {
    context: *anyopaque,
    cloneForClient: *const fn (*anyopaque) anyerror!Server.OwnedProvenance,
    destroy: *const fn (*anyopaque) void,
};

/// Owned descriptors and optional provenance for one listening socket.
pub const ListenerSpec = struct {
    listen_fd: i32,
    lifetime_fd: ?i32 = null,
    provenance: ?ProvenanceTemplate = null,
};

const Listener = struct {
    owner: *IoUringServer,
    listen_fd: i32,
    lifetime_fd: ?i32,
    provenance: ?ProvenanceTemplate,
    accept_handle: ?IoUringLoop.Handle = null,
    lifetime_handle: ?IoUringLoop.Handle = null,
    accept_cancel_requested: bool = false,
    lifetime_cancel_requested: bool = false,
    multishot_accept: bool = true,
    draining: bool = false,
};

allocator: std.mem.Allocator,
loop: *IoUringLoop,
server: *Server,
max_pending_output_bytes: usize,
listeners: std.ArrayList(*Listener) = .empty,
clients: std.ArrayList(*Peer) = .empty,
pending: std.ArrayList(Pending) = .empty,
closing: bool = false,

/// Takes ownership of an already bound and listening Unix stream socket,
/// including when post-adoption initialization fails.
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
        .max_pending_output_bytes = max_pending_output_bytes,
    };
    errdefer self.listeners.deinit(allocator);
    try self.adoptListener(.{ .listen_fd = listener_fd });
}

/// Takes ownership of every member of `spec` on every return path. If setup
/// fails after an operation is queued, cleanup continues asynchronously while
/// the caller keeps dispatching or shuts the server down.
pub fn adoptListener(self: *IoUringServer, spec: ListenerSpec) !void {
    var listener = self.allocator.create(Listener) catch |err| {
        destroySpec(spec);
        return err;
    };
    listener.* = .{
        .owner = self,
        .listen_fd = spec.listen_fd,
        .lifetime_fd = spec.lifetime_fd,
        .provenance = spec.provenance,
    };
    if (self.closing) {
        self.destroyListener(listener);
        return error.ServerClosing;
    }
    self.listeners.append(self.allocator, listener) catch |err| {
        self.destroyListener(listener);
        return err;
    };
    listener.accept_handle = self.loop.queue(listener, acceptComplete, listener, prepareAccept) catch |err| {
        _ = self.listeners.pop();
        self.destroyListener(listener);
        return err;
    };
    if (listener.lifetime_fd != null) {
        listener.lifetime_handle = self.loop.queue(listener, lifetimeComplete, listener, prepareLifetime) catch |err| {
            listener.draining = true;
            self.requestListenerCancellation(listener) catch {};
            return err;
        };
    }
}

fn destroySpec(spec: ListenerSpec) void {
    _ = linux.close(spec.listen_fd);
    if (spec.lifetime_fd) |fd| _ = linux.close(fd);
    if (spec.provenance) |template| template.destroy(template.context);
}

/// Dispatches transport notifications in CQ order. This must run after each
/// outer ring drain and before policy-owned end-of-turn work.
pub fn dispatch(self: *IoUringServer) !void {
    self.retryListenerCancellations();
    self.retryPeerCancellations();
    var index: usize = 0;
    var completed = false;
    defer {
        if (index != 0) self.pending.replaceRangeAssumeCapacity(0, index, &.{});
        self.retryPeerCancellations();
        if (completed) self.reapClients();
        self.reapListeners();
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
    for (self.listeners.items) |listener| {
        listener.draining = true;
        self.requestListenerCancellation(listener) catch |err| if (first_error == null) {
            first_error = err;
        };
    }
    for (self.clients.items) |peer| {
        peer.terminal = true;
        peer.transport.shutdown() catch |err| {
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
    self.retryPeerCancellations();
    self.reapClients();
    self.retryListenerCancellations();
    self.reapListeners();
    if (self.listeners.items.len != 0) return false;
    if (self.clients.items.len != 0) return false;
    return true;
}

pub fn clientCount(self: *const IoUringServer) usize {
    return self.clients.items.len;
}

pub fn listenerCount(self: *const IoUringServer) usize {
    return self.listeners.items.len;
}

pub fn deinit(self: *IoUringServer) void {
    std.debug.assert(self.closing);
    std.debug.assert(self.pending.items.len == 0);
    std.debug.assert(self.readyToDeinit());
    self.pending.deinit(self.allocator);
    self.clients.deinit(self.allocator);
    self.listeners.deinit(self.allocator);
    self.* = undefined;
}

fn armAccept(listener: *Listener) !void {
    if (listener.draining or listener.accept_handle != null) return;
    listener.accept_handle = try listener.owner.loop.queue(listener, acceptComplete, listener, prepareAccept);
}

fn prepareAccept(context: *anyopaque, sqe: *linux.io_uring_sqe) void {
    const listener: *Listener = @ptrCast(@alignCast(context));
    if (listener.multishot_accept)
        sqe.prep_multishot_accept(
            listener.listen_fd,
            null,
            null,
            linux.SOCK.CLOEXEC,
        )
    else
        sqe.prep_accept(listener.listen_fd, null, null, linux.SOCK.CLOEXEC);
}

fn acceptComplete(
    context: *anyopaque,
    _: *IoUringLoop,
    completion: IoUringLoop.Completion,
) !void {
    const listener: *Listener = @ptrCast(@alignCast(context));
    const self = listener.owner;
    if (!completion.more()) {
        listener.accept_handle = null;
        listener.accept_cancel_requested = false;
    }
    if (completion.result >= 0) {
        const fd: i32 = @intCast(completion.result);
        if (listener.draining)
            _ = linux.close(fd)
        else
            // A rejected client is isolated to its accepted descriptor. The
            // listener remains authoritative and available to later clients.
            self.addClient(fd, listener.provenance) catch {};
    } else if (!listener.draining and
        completion.result == -@as(i32, @intFromEnum(linux.E.INVAL)) and
        listener.multishot_accept)
    {
        listener.multishot_accept = false;
    } else if (!listener.draining and completion.result != -@as(i32, @intFromEnum(linux.E.CANCELED)) and !transientAccept(completion.result)) {
        listener.draining = true;
        self.requestListenerCancellation(listener) catch {};
    }
    if (!listener.draining and !completion.more()) armAccept(listener) catch {
        listener.draining = true;
        self.requestListenerCancellation(listener) catch {};
    };
}

fn prepareLifetime(context: *anyopaque, sqe: *linux.io_uring_sqe) void {
    const listener: *Listener = @ptrCast(@alignCast(context));
    sqe.prep_poll_add(listener.lifetime_fd.?, linux.POLL.HUP | linux.POLL.ERR);
}

fn lifetimeComplete(
    context: *anyopaque,
    _: *IoUringLoop,
    _: IoUringLoop.Completion,
) !void {
    const listener: *Listener = @ptrCast(@alignCast(context));
    listener.lifetime_handle = null;
    listener.lifetime_cancel_requested = false;
    listener.draining = true;
    listener.owner.requestListenerCancellation(listener) catch {};
}

fn transientAccept(result: i32) bool {
    return result == -@as(i32, @intFromEnum(linux.E.INTR)) or
        result == -@as(i32, @intFromEnum(linux.E.AGAIN)) or
        result == -@as(i32, @intFromEnum(linux.E.CONNABORTED)) or
        result == -@as(i32, @intFromEnum(linux.E.PROTO)) or
        result == -@as(i32, @intFromEnum(linux.E.MFILE)) or
        result == -@as(i32, @intFromEnum(linux.E.NFILE)) or
        result == -@as(i32, @intFromEnum(linux.E.NOBUFS)) or
        result == -@as(i32, @intFromEnum(linux.E.NOMEM));
}

fn requestListenerCancellation(self: *IoUringServer, listener: *Listener) !void {
    var first_error: ?anyerror = null;
    if (listener.accept_handle) |handle| if (!listener.accept_cancel_requested) {
        self.loop.cancel(handle) catch |err| {
            first_error = err;
        };
        if (first_error == null) listener.accept_cancel_requested = true;
    };
    if (listener.lifetime_handle) |handle| if (!listener.lifetime_cancel_requested) {
        var lifetime_error: ?anyerror = null;
        self.loop.cancel(handle) catch |err| {
            lifetime_error = err;
            if (first_error == null) first_error = err;
        };
        if (lifetime_error == null) listener.lifetime_cancel_requested = true;
    };
    if (first_error) |err| return err;
}

fn retryListenerCancellations(self: *IoUringServer) void {
    for (self.listeners.items) |listener| if (listener.draining)
        self.requestListenerCancellation(listener) catch {};
}

fn retryPeerCancellations(self: *IoUringServer) void {
    for (self.clients.items) |peer| {
        if (!peer.terminal and !peer.transport.closing) continue;
        peer.terminal = true;
        peer.transport.shutdown() catch {};
    }
}

fn reapListeners(self: *IoUringServer) void {
    var index: usize = 0;
    while (index < self.listeners.items.len) {
        const listener = self.listeners.items[index];
        if (!listener.draining or
            (listener.accept_handle != null and self.loop.isActive(listener.accept_handle.?)) or
            (listener.lifetime_handle != null and self.loop.isActive(listener.lifetime_handle.?)))
        {
            index += 1;
            continue;
        }
        self.destroyListener(listener);
        _ = self.listeners.swapRemove(index);
    }
}

fn destroyListener(self: *IoUringServer, listener: *Listener) void {
    _ = linux.close(listener.listen_fd);
    if (listener.lifetime_fd) |fd| _ = linux.close(fd);
    if (listener.provenance) |template| template.destroy(template.context);
    self.allocator.destroy(listener);
}

fn addClient(self: *IoUringServer, fd: i32, template: ?ProvenanceTemplate) !void {
    var fd_owned = true;
    errdefer if (fd_owned) {
        _ = linux.close(fd);
    };
    try self.clients.ensureUnusedCapacity(self.allocator, 1);
    const peer = try self.allocator.create(Peer);
    errdefer self.allocator.destroy(peer);
    const provenance = if (template) |value| try value.cloneForClient(value.context) else null;
    const client = try self.server.createClientWithProvenance(provenance);
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

var test_provenance_key: u8 = 0;

const TestClientProvenance = struct {
    allocator: std.mem.Allocator,
    destroy_count: *usize,
    value: u32,

    fn destroy(context: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.destroy_count.* += 1;
        self.allocator.destroy(self);
    }
};

const TestProvenanceTemplate = struct {
    allocator: std.mem.Allocator,
    template_destroyed: *bool,
    client_destroy_count: *usize,
    clone_failures: *usize,
    value: u32,

    fn cloneForClient(context: *anyopaque) !Server.OwnedProvenance {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.clone_failures.* != 0) {
            self.clone_failures.* -= 1;
            return error.TestCloneFailed;
        }
        const provenance = try self.allocator.create(TestClientProvenance);
        provenance.* = .{
            .allocator = self.allocator,
            .destroy_count = self.client_destroy_count,
            .value = self.value,
        };
        return .{
            .key = &test_provenance_key,
            .data = provenance,
            .destroy = TestClientProvenance.destroy,
        };
    }

    fn destroy(context: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.template_destroyed.* = true;
        self.allocator.destroy(self);
    }
};

fn createTestListener(path: []const u8) !i32 {
    var address: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = undefined };
    if (path.len >= address.path.len) return error.NameTooLong;
    @memset(&address.path, 0);
    @memcpy(address.path[0..path.len], path);
    const result = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(result) != .SUCCESS) return error.SocketFailed;
    const fd: i32 = @intCast(result);
    errdefer _ = linux.close(fd);
    const address_length: linux.socklen_t = @intCast(
        @offsetOf(linux.sockaddr.un, "path") + path.len + 1,
    );
    if (linux.errno(linux.bind(fd, @ptrCast(&address), address_length)) != .SUCCESS)
        return error.BindFailed;
    if (linux.errno(linux.listen(fd, 8)) != .SUCCESS) return error.ListenFailed;
    return fd;
}

fn connectTestClient(path: []const u8) !i32 {
    var address: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = undefined };
    if (path.len >= address.path.len) return error.NameTooLong;
    @memset(&address.path, 0);
    @memcpy(address.path[0..path.len], path);
    const result = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(result) != .SUCCESS) return error.SocketFailed;
    const fd: i32 = @intCast(result);
    errdefer _ = linux.close(fd);
    const address_length: linux.socklen_t = @intCast(
        @offsetOf(linux.sockaddr.un, "path") + path.len + 1,
    );
    if (linux.errno(linux.connect(fd, @ptrCast(&address), address_length)) != .SUCCESS)
        return error.ConnectFailed;
    return fd;
}

test "dynamic listeners isolate lifetime and clone client provenance" {
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    var main_path_buffer: [@sizeOf(@FieldType(linux.sockaddr.un, "path"))]u8 = undefined;
    const main_path = try std.fmt.bufPrint(
        &main_path_buffer,
        ".zig-cache/tmp/{s}/main",
        .{temporary.sub_path},
    );
    const main_listener = try createTestListener(main_path);
    var main_listener_owned = true;
    defer if (main_listener_owned) {
        _ = linux.close(main_listener);
    };

    var loop = try IoUringLoop.init(allocator);
    defer loop.deinit();
    var native_server = Server.init(allocator);
    defer native_server.deinit();
    var transport_server: IoUringServer = undefined;
    main_listener_owned = false;
    try transport_server.init(allocator, &loop, &native_server, main_listener);

    var dynamic_path_buffer: [@sizeOf(@FieldType(linux.sockaddr.un, "path"))]u8 = undefined;
    const dynamic_path = try std.fmt.bufPrint(
        &dynamic_path_buffer,
        ".zig-cache/tmp/{s}/contextual",
        .{temporary.sub_path},
    );
    const dynamic_listener = try createTestListener(dynamic_path);
    var dynamic_listener_owned = true;
    defer if (dynamic_listener_owned) {
        _ = linux.close(dynamic_listener);
    };
    var lifetime: [2]i32 = undefined;
    if (linux.errno(linux.socketpair(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
        0,
        &lifetime,
    )) != .SUCCESS) return error.SocketPairFailed;
    var lifetime_listener_owned = true;
    defer if (lifetime_listener_owned) {
        _ = linux.close(lifetime[0]);
    };
    var lifetime_peer_owned = true;
    defer if (lifetime_peer_owned) {
        _ = linux.close(lifetime[1]);
    };
    var template_destroyed = false;
    var client_provenance_destroy_count: usize = 0;
    var clone_failures: usize = 1;
    const template = try allocator.create(TestProvenanceTemplate);
    var template_owned = true;
    defer if (template_owned) {
        TestProvenanceTemplate.destroy(template);
    };
    template.* = .{
        .allocator = allocator,
        .template_destroyed = &template_destroyed,
        .client_destroy_count = &client_provenance_destroy_count,
        .clone_failures = &clone_failures,
        .value = 42,
    };
    dynamic_listener_owned = false;
    lifetime_listener_owned = false;
    template_owned = false;
    try transport_server.adoptListener(.{
        .listen_fd = dynamic_listener,
        .lifetime_fd = lifetime[0],
        .provenance = .{
            .context = template,
            .cloneForClient = TestProvenanceTemplate.cloneForClient,
            .destroy = TestProvenanceTemplate.destroy,
        },
    });

    // Grow the pointer array after operation callbacks retain listener records.
    const extra_listener_count = 6;
    var extra_path_buffers: [extra_listener_count][@sizeOf(@FieldType(linux.sockaddr.un, "path"))]u8 = undefined;
    for (&extra_path_buffers, 0..) |*path_buffer, index| {
        const path = try std.fmt.bufPrint(
            path_buffer,
            ".zig-cache/tmp/{s}/extra-{d}",
            .{ temporary.sub_path, index },
        );
        try transport_server.adoptListener(.{ .listen_fd = try createTestListener(path) });
    }
    const initial_listener_count = 2 + extra_listener_count;
    try std.testing.expectEqual(initial_listener_count, transport_server.listenerCount());

    // One rejected contextual client does not retire its authoritative
    // listener; the next client can still connect with cloned provenance.
    const rejected_contextual_client = try connectTestClient(dynamic_path);
    var rejected_contextual_client_owned = true;
    defer if (rejected_contextual_client_owned) {
        _ = linux.close(rejected_contextual_client);
    };
    var turns: usize = 0;
    while (clone_failures != 0 and turns < 32) : (turns += 1) {
        try loop.runOnce();
        try transport_server.dispatch();
    }
    try std.testing.expectEqual(@as(usize, 0), clone_failures);
    try std.testing.expectEqual(@as(usize, 0), transport_server.clientCount());
    try std.testing.expectEqual(initial_listener_count, transport_server.listenerCount());
    _ = linux.close(rejected_contextual_client);
    rejected_contextual_client_owned = false;

    const main_client_one = try connectTestClient(main_path);
    var main_client_one_owned = true;
    defer if (main_client_one_owned) {
        _ = linux.close(main_client_one);
    };
    const contextual_client = try connectTestClient(dynamic_path);
    var contextual_client_owned = true;
    defer if (contextual_client_owned) {
        _ = linux.close(contextual_client);
    };
    turns = 0;
    while (transport_server.clientCount() < 2 and turns < 32) : (turns += 1) {
        try loop.runOnce();
        try transport_server.dispatch();
    }
    try std.testing.expectEqual(@as(usize, 2), transport_server.clientCount());

    var contextual_clients: usize = 0;
    for (transport_server.clients.items) |peer| {
        const raw = peer.client.provenance(&test_provenance_key) orelse continue;
        const provenance: *const TestClientProvenance = @ptrCast(@alignCast(raw));
        try std.testing.expectEqual(@as(u32, 42), provenance.value);
        contextual_clients += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), contextual_clients);

    // Readable lifetime data is ignored; peer closure alone drains this listener.
    const lifetime_data = "still alive";
    const written = linux.write(lifetime[1], lifetime_data.ptr, lifetime_data.len);
    if (linux.errno(written) != .SUCCESS) return error.WriteFailed;
    try std.testing.expectEqual(lifetime_data.len, written);
    try loop.pollOnce();
    try transport_server.dispatch();
    try std.testing.expectEqual(initial_listener_count, transport_server.listenerCount());
    try std.testing.expect(!template_destroyed);

    _ = linux.close(lifetime[1]);
    lifetime_peer_owned = false;
    turns = 0;
    while (transport_server.listenerCount() == initial_listener_count and turns < 32) : (turns += 1) {
        try loop.runOnce();
        try transport_server.dispatch();
    }
    try std.testing.expectEqual(initial_listener_count - 1, transport_server.listenerCount());
    try std.testing.expect(template_destroyed);
    try std.testing.expectEqual(@as(usize, 2), transport_server.clientCount());
    try std.testing.expectEqual(@as(usize, 0), client_provenance_destroy_count);

    const main_client_two = try connectTestClient(main_path);
    var main_client_two_owned = true;
    defer if (main_client_two_owned) {
        _ = linux.close(main_client_two);
    };
    turns = 0;
    while (transport_server.clientCount() < 3 and turns < 32) : (turns += 1) {
        try loop.runOnce();
        try transport_server.dispatch();
    }
    try std.testing.expectEqual(@as(usize, 3), transport_server.clientCount());
    contextual_clients = 0;
    for (transport_server.clients.items) |peer| {
        if (peer.client.provenance(&test_provenance_key) != null) contextual_clients += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), contextual_clients);

    _ = linux.close(main_client_one);
    main_client_one_owned = false;
    _ = linux.close(contextual_client);
    contextual_client_owned = false;
    _ = linux.close(main_client_two);
    main_client_two_owned = false;
    turns = 0;
    while (transport_server.clientCount() != 0 and turns < 64) : (turns += 1) {
        try loop.runOnce();
        try transport_server.dispatch();
    }
    try std.testing.expectEqual(@as(usize, 0), transport_server.clientCount());
    try std.testing.expectEqual(@as(usize, 1), client_provenance_destroy_count);

    try transport_server.shutdown();
    while (loop.hasActiveOperations()) {
        try loop.runOnce();
        try transport_server.dispatch();
    }
    try transport_server.dispatch();
    try std.testing.expect(transport_server.readyToDeinit());
    try std.testing.expectEqual(@as(usize, 0), transport_server.listenerCount());
    transport_server.deinit();
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
    listener_owned = false;
    try transport_server.init(
        std.testing.allocator,
        &loop,
        &native_server,
        listener,
    );

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

    // Model an earlier shutdown attempt that set closing before cancellation
    // submission failed. Server dispatch must retry the still-active receive.
    const accepted_peer = transport_server.clients.items[0];
    try std.testing.expect(accepted_peer.transport.receive_handle != null);
    try std.testing.expect(!accepted_peer.transport.receive_cancel_requested);
    accepted_peer.transport.closing = true;
    try transport_server.dispatch();
    try std.testing.expect(accepted_peer.terminal);
    try std.testing.expect(accepted_peer.transport.receive_cancel_requested);
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
