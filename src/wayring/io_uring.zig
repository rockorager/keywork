//! Linux io_uring transport state for a caller-owned ring.
//!
//! The host owns the ring and ring-wide external `user_data` values. Those
//! values must be monotonic or generation-bearing and must not be reused while
//! any live operation or cancellation target still references them. Before a
//! future `prepareNext`, the host reserves both route-map capacity and the
//! external value. After `commitPrepared`, installing the route must therefore
//! be infallible. Installed routes survive submission errors. Wayring never
//! submits, waits on, or drains the host's ring.
//!
//! Tokens are generation-checked table references and are deliberately not
//! packed into kernel `user_data`.

const std = @import("std");
const wire = @import("wire.zig");
const server = @import("server.zig");
const linux = std.os.linux;

const LinuxCredentials = extern struct {
    pid: linux.pid_t,
    uid: linux.uid_t,
    gid: linux.gid_t,
};

pub const OperationToken = struct { slot: u32, generation: u32 };

pub const PrepareResult = union(enum) {
    prepared: OperationToken,
    idle,
    submission_queue_full,
};

const OperationRequest = struct {
    const Value = union(enum) {
        accept: *anyopaque,
        recv: *anyopaque,
        send: struct { owner: *anyopaque, batch: wire.BatchToken },
    };

    value: Value,

    fn accept(owner: *anyopaque) OperationRequest {
        return .{ .value = .{ .accept = owner } };
    }

    fn recv(owner: *anyopaque) OperationRequest {
        return .{ .value = .{ .recv = owner } };
    }

    fn send(owner: *anyopaque, batch: wire.BatchToken) OperationRequest {
        return .{ .value = .{ .send = .{ .owner = owner, .batch = batch } } };
    }
};

const CancelState = enum { none, preparing, queued };

const StoredOperation = union(enum) {
    accept: struct { owner: *anyopaque, external_user_data: u64, cancel: CancelState = .none },
    recv: struct { owner: *anyopaque, external_user_data: u64, cancel: CancelState = .none },
    send: struct { owner: *anyopaque, external_user_data: u64, batch: wire.BatchToken, cancel: CancelState = .none },
    cancel: struct { owner: *anyopaque, external_user_data: u64, target_user_data: u64, target: OperationToken },

    fn fromRequest(request: OperationRequest, external_user_data: u64) StoredOperation {
        return switch (request.value) {
            .accept => |request_owner| .{ .accept = .{ .owner = request_owner, .external_user_data = external_user_data } },
            .recv => |request_owner| .{ .recv = .{ .owner = request_owner, .external_user_data = external_user_data } },
            .send => |send_request| .{ .send = .{
                .owner = send_request.owner,
                .external_user_data = external_user_data,
                .batch = send_request.batch,
            } },
        };
    }

    fn external(self: StoredOperation) u64 {
        return switch (self) {
            inline else => |value| value.external_user_data,
        };
    }

    fn targetExternal(self: StoredOperation) ?u64 {
        return switch (self) {
            .cancel => |value| value.target_user_data,
            else => null,
        };
    }
};

const OperationTable = struct {
    const Slot = struct {
        generation: u32 = 1,
        operation: ?StoredOperation = null,
        retired: bool = false,
    };

    const Prepared = struct {
        slot: u32,
        operation: StoredOperation,
        cancel_target: ?OperationToken = null,
    };

    allocator: std.mem.Allocator,
    slots: std.ArrayList(Slot) = .empty,
    live_count: usize = 0,
    prepared: ?Prepared = null,

    fn init(allocator: std.mem.Allocator) OperationTable {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *OperationTable) void {
        std.debug.assert(self.live_count == 0);
        std.debug.assert(self.prepared == null);
        self.slots.deinit(self.allocator);
        self.* = undefined;
    }

    fn prepare(self: *OperationTable, request: OperationRequest, external_user_data: u64) !void {
        if (self.prepared != null) return error.PrepareAlreadyPending;
        if (self.referencesExternal(external_user_data)) return error.DuplicateExternalUserData;
        const slot = try self.reserveSlot();
        self.prepared = .{ .slot = slot, .operation = .fromRequest(request, external_user_data) };
    }

    fn prepareCancel(self: *OperationTable, target: OperationToken, owner: *anyopaque, external_user_data: u64) !void {
        if (self.prepared != null) return error.PrepareAlreadyPending;
        if (self.referencesExternal(external_user_data)) return error.DuplicateExternalUserData;
        const original = try self.operationPtr(target);
        const target_user_data = switch (original.*) {
            .cancel => return error.CannotCancelCancellation,
            inline else => |*value| blk: {
                if (value.cancel != .none) return error.CancelAlreadyQueued;
                break :blk value.external_user_data;
            },
        };
        const slot = try self.reserveSlot();
        // No fallible work may follow this state transition.
        const reserved_original = self.operationPtr(target) catch unreachable;
        switch (reserved_original.*) {
            inline .accept, .recv, .send => |*value| value.cancel = .preparing,
            .cancel => unreachable,
        }
        self.prepared = .{
            .slot = slot,
            .operation = .{ .cancel = .{
                .owner = owner,
                .external_user_data = external_user_data,
                .target_user_data = target_user_data,
                .target = target,
            } },
            .cancel_target = target,
        };
    }

    fn commitPrepared(self: *OperationTable) OperationToken {
        const prepared = self.prepared.?;
        self.prepared = null;
        if (prepared.cancel_target) |target| {
            const original = self.operationPtr(target) catch unreachable;
            switch (original.*) {
                inline .accept, .recv, .send => |*value| value.cancel = .queued,
                .cancel => unreachable,
            }
        }
        const slot = &self.slots.items[prepared.slot];
        std.debug.assert(slot.operation == null and !slot.retired);
        slot.operation = prepared.operation;
        self.live_count += 1;
        return .{ .slot = prepared.slot, .generation = slot.generation };
    }

    /// Aborting without a pending reservation is an explicit error.
    fn abortPrepared(self: *OperationTable) !void {
        const prepared = self.prepared orelse return error.NoPreparedOperation;
        self.prepared = null;
        if (prepared.cancel_target) |target| {
            if (self.operationPtr(target)) |original| switch (original.*) {
                inline .accept, .recv, .send => |*value| if (value.cancel == .preparing) {
                    value.cancel = .none;
                },
                .cancel => {},
            } else |_| {}
        }
    }

    fn lookup(self: *const OperationTable, token: OperationToken) !StoredOperation {
        return (try self.operationPtrConst(token)).*;
    }

    fn take(self: *OperationTable, token: OperationToken) !StoredOperation {
        if (self.prepared != null) return error.PreparePending;
        const slot = try self.slotFor(token);
        const operation = slot.operation orelse return error.OperationAlreadyCompleted;
        slot.operation = null;
        self.live_count -= 1;
        if (slot.generation == std.math.maxInt(u32)) slot.retired = true else slot.generation += 1;
        return operation;
    }

    fn reserveSlot(self: *OperationTable) !u32 {
        for (self.slots.items, 0..) |slot, index| {
            if (slot.operation == null and !slot.retired) return @intCast(index);
        }
        if (self.slots.items.len > std.math.maxInt(u32)) return error.SlotExhausted;
        try self.slots.append(self.allocator, .{});
        return @intCast(self.slots.items.len - 1);
    }

    fn referencesExternal(self: *const OperationTable, external: u64) bool {
        for (self.slots.items) |slot| if (slot.operation) |operation| {
            if (operation.external() == external or operation.targetExternal() == external) return true;
        };
        if (self.prepared) |prepared| {
            if (prepared.operation.external() == external or prepared.operation.targetExternal() == external) return true;
        }
        return false;
    }

    fn nextCancelable(self: *const OperationTable) ?OperationToken {
        for (self.slots.items, 0..) |slot, index| if (slot.operation) |operation| {
            const eligible = switch (operation) {
                inline .accept, .recv, .send => |value| value.cancel == .none,
                .cancel => false,
            };
            if (eligible) return .{ .slot = @intCast(index), .generation = slot.generation };
        };
        return null;
    }

    fn cancelableRecvFor(self: *const OperationTable, owner: *Connection) ?OperationToken {
        for (self.slots.items, 0..) |slot, index| if (slot.operation) |operation| switch (operation) {
            .recv => |value| if (value.owner == @as(*anyopaque, @ptrCast(owner)) and value.cancel == .none)
                return .{ .slot = @intCast(index), .generation = slot.generation },
            else => {},
        };
        return null;
    }

    fn slotFor(self: *OperationTable, token: OperationToken) !*Slot {
        if (token.slot >= self.slots.items.len) return error.ForeignToken;
        const slot = &self.slots.items[token.slot];
        if (slot.generation != token.generation) return error.StaleToken;
        return slot;
    }

    fn operationPtr(self: *OperationTable, token: OperationToken) !*StoredOperation {
        const slot = try self.slotFor(token);
        return &(slot.operation orelse return error.OperationAlreadyCompleted);
    }

    fn operationPtrConst(self: *const OperationTable, token: OperationToken) !*const StoredOperation {
        if (token.slot >= self.slots.items.len) return error.ForeignToken;
        const slot = &self.slots.items[token.slot];
        if (slot.generation != token.generation) return error.StaleToken;
        return &(slot.operation orelse return error.OperationAlreadyCompleted);
    }

    fn forceGenerationForTest(self: *OperationTable, token: OperationToken, generation: u32) void {
        self.slots.items[token.slot].generation = generation;
    }
};

/// A heap-stable transport connection. Fields are private so an outstanding
/// recvmsg can safely retain pointers into this record.
pub const Connection = struct {
    /// This is an adapter resource bound, not a Wayland protocol limit.
    pub const max_received_fds = 32;
    pub const State = enum { ready, peer_disconnected, terminal };

    fd: linux.fd_t,
    core: *server.CoreClient,
    state_value: State = .ready,
    recv_pending: bool = false,
    send_pending: bool = false,
    send_control: ?[]align(@alignOf(linux.cmsghdr)) u8 = null,
    send_iov: std.posix.iovec_const = undefined,
    send_msg: linux.msghdr_const = undefined,
    data: [wire.max_message_size]u8 = undefined,
    control: [cmsgSpace(max_received_fds * @sizeOf(wire.FileDescriptor))]u8 align(@alignOf(linux.cmsghdr)) = undefined,
    iov: std.posix.iovec = undefined,
    msg: linux.msghdr = undefined,
    fd_scratch: [max_received_fds]wire.FileDescriptor = undefined,

    pub fn client(self: *Connection) *server.Client {
        return self.core.client();
    }

    pub fn state(self: *const Connection) State {
        return self.state_value;
    }

    /// Synchronizes protocol-fatal state into transport scheduling. Once
    /// terminal, a connection may only drain output or cancel in-flight work.
    pub fn synchronizeFatal(self: *Connection) void {
        if (self.state_value == .ready and self.client().fatal() != null)
            self.state_value = .terminal;
    }

    fn resetMessage(self: *Connection) void {
        self.iov = .{ .base = &self.data, .len = self.data.len };
        self.msg = .{
            .name = null,
            .namelen = 0,
            .iov = @ptrCast(&self.iov),
            .iovlen = 1,
            .control = &self.control,
            .controllen = self.control.len,
            .flags = 0,
        };
    }
};

pub const CompleteResult = union(enum) {
    accepted: *Connection,
    received: *Connection,
    sent: *Connection,
    peer_disconnected: *Connection,
    terminal: *Connection,
    listener_error: linux.E,
    cancellation,
    retry,
};

pub const Server = struct {
    const max_auto_socket_number = 31;

    allocator: std.mem.Allocator,
    sans_io: *server.Server,
    listener_fd: linux.fd_t,
    owned_socket_path: ?[:0]u8 = null,
    owned_socket_name: ?[]const u8 = null,
    operations: OperationTable,
    connections: std.ArrayList(*Connection) = .empty,
    accept_pending: bool = false,
    prefer_accept: bool = true,
    prefer_send: bool = true,
    connection_cursor: usize = 0,
    shutting_down: bool = false,
    transport_provenance: server.Client.TransportProvenance = .unknown,

    pub const Options = struct {
        transport_provenance: server.Client.TransportProvenance = .unknown,
    };

    /// Takes ownership of an already-bound, listening Unix socket descriptor.
    pub fn init(allocator: std.mem.Allocator, sans_io: *server.Server, listener_fd: linux.fd_t) !Server {
        return initWithOptions(allocator, sans_io, listener_fd, .{});
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, sans_io: *server.Server, listener_fd: linux.fd_t, options: Options) !Server {
        if (listener_fd < 0) return error.InvalidListener;
        return .{
            .allocator = allocator,
            .sans_io = sans_io,
            .listener_fd = listener_fd,
            .operations = .init(allocator),
            .transport_provenance = options.transport_provenance,
        };
    }

    /// Creates and owns the first available `wayland-N` listener in an
    /// explicit runtime directory. Existing paths are never removed.
    pub fn listenAuto(allocator: std.mem.Allocator, sans_io: *server.Server, runtime_directory: []const u8) !Server {
        return listenAutoWithOptions(allocator, sans_io, runtime_directory, .{});
    }

    pub fn listenAutoWithOptions(allocator: std.mem.Allocator, sans_io: *server.Server, runtime_directory: []const u8, options: Options) !Server {
        if (!std.fs.path.isAbsolute(runtime_directory)) return error.InvalidRuntimeDirectory;
        var name_buffer: ["wayland-".len + 10]u8 = undefined;
        for (0..max_auto_socket_number + 1) |number| {
            const name = std.fmt.bufPrint(&name_buffer, "wayland-{d}", .{number}) catch unreachable;
            const path = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ runtime_directory, name }, 0);
            const listener_fd = openListener(path) catch |err| {
                allocator.free(path);
                if (err == error.AddressInUse) continue;
                return err;
            };
            return .{
                .allocator = allocator,
                .sans_io = sans_io,
                .listener_fd = listener_fd,
                .owned_socket_path = path,
                .owned_socket_name = path[path.len - name.len ..],
                .operations = .init(allocator),
                .transport_provenance = options.transport_provenance,
            };
        }
        return error.NoAvailableSocketName;
    }

    pub fn socketName(self: *const Server) ?[]const u8 {
        return self.owned_socket_name;
    }

    pub fn deinit(self: *Server) !void {
        if (self.operations.live_count != 0 or self.operations.prepared != null) return error.OperationsInFlight;
        if (self.connections.items.len != 0) return error.ConnectionsLive;
        _ = linux.close(self.listener_fd);
        var socket_cleanup_failed = false;
        if (self.owned_socket_path) |path| {
            removeSocketPath(path) catch {
                socket_cleanup_failed = true;
            };
            self.allocator.free(path);
        }
        self.connections.deinit(self.allocator);
        self.operations.deinit();
        self.* = undefined;
        if (socket_cleanup_failed) return error.SocketCleanupFailed;
    }

    /// Stops new transport work. Kernel-owned operation storage remains alive
    /// until the corresponding CQEs are completed.
    pub fn beginShutdown(self: *Server) void {
        if (self.shutting_down) return;
        self.shutting_down = true;
        for (self.connections.items) |connection| {
            if (connection.state_value != .terminal) {
                connection.state_value = .peer_disconnected;
                connection.client().peerDisconnected();
            }
        }
    }

    pub fn isDrained(self: *const Server) bool {
        if (!self.shutting_down or self.operations.live_count != 0 or self.operations.prepared != null) return false;
        for (self.connections.items) |connection| {
            if (connection.recv_pending or connection.send_pending) return false;
        }
        return !self.accept_pending;
    }

    /// Reserves operation slots so shutdown cancellation does not allocate.
    pub fn reserveOperationCapacity(self: *Server, capacity: usize) !void {
        try self.operations.slots.ensureTotalCapacity(self.allocator, capacity);
    }

    /// Destroys transport/core storage only at an explicit application
    /// boundary. All application resources must already have been destroyed.
    pub fn release(self: *Server, connection: *Connection) !void {
        for (self.connections.items, 0..) |candidate, index| if (candidate == connection) {
            if (connection.recv_pending or connection.send_pending or connection.send_control != null) return error.OperationInFlight;
            if (!connection.core.canDestroy()) return error.ApplicationResourcesLive;
            _ = linux.close(connection.fd);
            connection.core.destroy();
            _ = self.connections.orderedRemove(index);
            if (self.connections.items.len == 0) {
                self.connection_cursor = 0;
            } else {
                if (index < self.connection_cursor) self.connection_cursor -= 1;
                if (self.connection_cursor >= self.connections.items.len) self.connection_cursor = 0;
            }
            self.allocator.destroy(connection);
            return;
        };
        return error.ForeignConnection;
    }

    /// Reserves all fallible operation-table state before acquiring an SQE.
    /// Successful SQE preparation is followed only by infallible commit.
    pub fn prepareNext(self: *Server, ring: *linux.IoUring, external_user_data: u64) !PrepareResult {
        if (self.shutting_down) {
            const target = self.operations.nextCancelable() orelse return .idle;
            try self.operations.prepareCancel(target, self, external_user_data);
            const original = self.operations.lookup(target) catch unreachable;
            _ = ring.cancel(external_user_data, original.external(), 0) catch |err| switch (err) {
                error.SubmissionQueueFull => {
                    self.operations.abortPrepared() catch unreachable;
                    return .submission_queue_full;
                },
            };
            return .{ .prepared = self.operations.commitPrepared() };
        }
        for (self.connections.items) |connection| connection.synchronizeFatal();
        if (self.nextTerminalRecvCancellation()) |target|
            return self.prepareCancellation(ring, target, external_user_data);
        const connection = self.nextConnection();
        const choose_accept = !self.accept_pending and (connection == null or self.prefer_accept);
        if (!choose_accept and connection == null) {
            if (self.accept_pending) return .idle;
            return self.prepareAccept(ring, external_user_data);
        }
        if (choose_accept) return self.prepareAccept(ring, external_user_data);
        const selected = connection.?;
        const can_send = !selected.send_pending and selected.client().hasPendingOutput();
        const can_recv = selected.state_value == .ready and !selected.recv_pending;
        if (can_send and (!can_recv or self.prefer_send)) return self.prepareSend(ring, selected, external_user_data);
        return self.prepareRecv(ring, selected, external_user_data);
    }

    fn nextTerminalRecvCancellation(self: *const Server) ?OperationToken {
        for (self.connections.items) |connection| {
            if (connection.state_value != .terminal or !connection.recv_pending) continue;
            if (self.operations.cancelableRecvFor(connection)) |target| return target;
        }
        return null;
    }

    fn prepareCancellation(
        self: *Server,
        ring: *linux.IoUring,
        target: OperationToken,
        external_user_data: u64,
    ) !PrepareResult {
        try self.operations.prepareCancel(target, self, external_user_data);
        const original = self.operations.lookup(target) catch unreachable;
        _ = ring.cancel(external_user_data, original.external(), 0) catch |err| switch (err) {
            error.SubmissionQueueFull => {
                self.operations.abortPrepared() catch unreachable;
                return .submission_queue_full;
            },
        };
        return .{ .prepared = self.operations.commitPrepared() };
    }

    fn prepareAccept(self: *Server, ring: *linux.IoUring, external: u64) !PrepareResult {
        try self.operations.prepare(.accept(self), external);
        _ = ring.accept(external, self.listener_fd, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC) catch |err| switch (err) {
            error.SubmissionQueueFull => {
                self.operations.abortPrepared() catch unreachable;
                return .submission_queue_full;
            },
        };
        const token = self.operations.commitPrepared();
        self.accept_pending = true;
        self.prefer_accept = false;
        return .{ .prepared = token };
    }

    fn prepareRecv(self: *Server, ring: *linux.IoUring, connection: *Connection, ring_external: u64) !PrepareResult {
        connection.resetMessage();
        try self.operations.prepare(.recv(connection), ring_external);
        _ = ring.recvmsg(ring_external, connection.fd, &connection.msg, linux.MSG.CMSG_CLOEXEC) catch |err| switch (err) {
            error.SubmissionQueueFull => {
                self.operations.abortPrepared() catch unreachable;
                return .submission_queue_full;
            },
        };
        const token = self.operations.commitPrepared();
        connection.recv_pending = true;
        self.prefer_accept = true;
        self.prefer_send = true;
        return .{ .prepared = token };
    }

    fn prepareSend(self: *Server, ring: *linux.IoUring, connection: *Connection, external: u64) !PrepareResult {
        const batch = (try connection.client().beginSend()) orelse unreachable;
        errdefer connection.client().completeSend(batch.token, 0) catch unreachable;

        const control_len = if (batch.fds.len == 0) 0 else cmsgSpace(batch.fds.len * @sizeOf(wire.FileDescriptor));
        const control = if (control_len == 0) null else try self.allocator.alignedAlloc(u8, .of(linux.cmsghdr), control_len);
        errdefer if (control) |owned| self.allocator.free(owned);
        if (control) |owned| encodeRights(owned, batch.fds);

        connection.send_control = control;
        connection.send_iov = .{ .base = batch.bytes.ptr, .len = batch.bytes.len };
        connection.send_msg = .{
            .name = null,
            .namelen = 0,
            .iov = @ptrCast(&connection.send_iov),
            .iovlen = 1,
            .control = if (control) |owned| owned.ptr else null,
            .controllen = control_len,
            .flags = 0,
        };
        errdefer connection.send_control = null;
        try self.operations.prepare(.send(connection, batch.token), external);
        errdefer self.operations.abortPrepared() catch unreachable;
        _ = ring.sendmsg(external, connection.fd, &connection.send_msg, linux.MSG.NOSIGNAL) catch |err| switch (err) {
            error.SubmissionQueueFull => {
                self.operations.abortPrepared() catch unreachable;
                connection.send_control = null;
                if (control) |owned| self.allocator.free(owned);
                connection.client().completeSend(batch.token, 0) catch unreachable;
                return .submission_queue_full;
            },
        };
        const token = self.operations.commitPrepared();
        connection.send_pending = true;
        self.prefer_send = false;
        self.prefer_accept = true;
        return .{ .prepared = token };
    }

    pub fn complete(self: *Server, token: OperationToken, res: i32, flags: u32) !CompleteResult {
        _ = flags;
        const operation = try self.operations.take(token);
        return switch (operation) {
            .accept => self.completeAccept(res),
            .recv => |value| self.completeRecv(@ptrCast(@alignCast(value.owner)), res),
            .send => |value| self.completeSend(@ptrCast(@alignCast(value.owner)), value.batch, res),
            .cancel => {
                if (completionError(res)) |err| switch (err) {
                    .ALREADY, .NOENT => {},
                    else => return error.UnexpectedCancellationResult,
                };
                return .cancellation;
            },
        };
    }

    fn completeAccept(self: *Server, res: i32) !CompleteResult {
        self.accept_pending = false;
        if (self.shutting_down) {
            if (res >= 0) _ = linux.close(@as(linux.fd_t, @intCast(res)));
            return .cancellation;
        }
        if (completionError(res)) |err| return switch (err) {
            .INTR, .AGAIN, .CONNABORTED => .retry,
            else => .{ .listener_error = err },
        };
        const fd: linux.fd_t = @intCast(res);
        return self.acceptConnection(fd) catch .retry;
    }

    fn acceptConnection(self: *Server, fd: linux.fd_t) !CompleteResult {
        errdefer _ = linux.close(fd);
        const credentials = try peerCredentials(fd);
        const connection = try self.allocator.create(Connection);
        errdefer self.allocator.destroy(connection);
        const core = try server.CoreClient.create(self.allocator, self.sans_io, .{
            .credentials = credentials,
            .transport_provenance = self.transport_provenance,
        });
        errdefer core.destroy();
        connection.* = .{ .fd = fd, .core = core };
        try self.connections.append(self.allocator, connection);
        return .{ .accepted = connection };
    }

    fn completeRecv(self: *Server, connection: *Connection, res: i32) !CompleteResult {
        defer connection.recv_pending = false;
        if (self.shutting_down and completionError(res) == .CANCELED) return .{ .peer_disconnected = connection };
        if (connection.state_value == .terminal) {
            if (res > 0) {
                const received: usize = @intCast(res);
                if (received > connection.data.len) return error.InvalidCompletionResult;
                const count = parseRights(connection, connection.msg.controllen, connection.msg.flags) catch
                    return .{ .terminal = connection };
                closeFds(connection.fd_scratch[0..count]);
            }
            return .{ .terminal = connection };
        }
        if (connection.state_value == .peer_disconnected) {
            if (res > 0) {
                const received: usize = @intCast(res);
                if (received > connection.data.len) return error.InvalidCompletionResult;
                const count = parseRights(connection, connection.msg.controllen, connection.msg.flags) catch return .{ .peer_disconnected = connection };
                closeFds(connection.fd_scratch[0..count]);
            }
            return .{ .peer_disconnected = connection };
        }
        if (completionError(res)) |err| return switch (err) {
            .INTR, .AGAIN => .retry,
            else => self.disconnect(connection),
        };
        if (res == 0) {
            return self.disconnect(connection);
        }
        const received: usize = @intCast(res);
        if (received > connection.data.len) return error.InvalidCompletionResult;
        const count = parseRights(connection, connection.msg.controllen, connection.msg.flags) catch {
            connection.state_value = .terminal;
            connection.client().transportMalformed();
            return .{ .terminal = connection };
        };
        connection.client().receive(connection.data[0..received], connection.fd_scratch[0..count]) catch {
            closeFds(connection.fd_scratch[0..count]);
            connection.state_value = .terminal;
            connection.client().transportOutOfMemory();
            return .{ .terminal = connection };
        };
        connection.client().dispatch() catch {
            connection.state_value = .terminal;
            return .{ .terminal = connection };
        };
        if (connection.client().fatal() != null) connection.state_value = .terminal;
        return if (connection.state_value == .terminal) .{ .terminal = connection } else .{ .received = connection };
    }

    fn completeSend(self: *Server, connection: *Connection, token: wire.BatchToken, res: i32) !CompleteResult {
        defer connection.send_pending = false;
        defer if (connection.send_control) |control| {
            self.allocator.free(control);
            connection.send_control = null;
        };
        if (self.shutting_down and completionError(res) == .CANCELED) {
            try connection.client().completeSend(token, 0);
            return .{ .peer_disconnected = connection };
        }
        if (completionError(res)) |err| switch (err) {
            .INTR, .AGAIN => {
                try connection.client().completeSend(token, 0);
                self.prefer_send = true;
                if (connection.state_value == .peer_disconnected) return .{ .peer_disconnected = connection };
                return .retry;
            },
            else => {
                try connection.client().completeSend(token, 0);
                return self.disconnect(connection);
            },
        };
        const written: usize = @intCast(res);
        if (written > connection.send_iov.len) {
            try connection.client().completeSend(token, 0);
            return error.InvalidCompletionResult;
        }
        try connection.client().completeSend(token, written);
        self.prefer_send = true;
        if (connection.state_value == .peer_disconnected) return .{ .peer_disconnected = connection };
        connection.synchronizeFatal();
        return if (written == 0) .retry else .{ .sent = connection };
    }

    fn disconnect(_: *Server, connection: *Connection) CompleteResult {
        connection.state_value = .peer_disconnected;
        connection.client().peerDisconnected();
        return .{ .peer_disconnected = connection };
    }

    fn nextConnection(self: *Server) ?*Connection {
        for (0..self.connections.items.len) |offset| {
            const index = (self.connection_cursor + offset) % self.connections.items.len;
            const connection = self.connections.items[index];
            connection.synchronizeFatal();
            if (connection.state_value == .peer_disconnected) continue;
            const can_recv = connection.state_value == .ready and !connection.recv_pending;
            const can_send = !connection.send_pending and connection.client().hasPendingOutput();
            if (can_recv or can_send) {
                self.connection_cursor = (index + 1) % self.connections.items.len;
                return connection;
            }
        }
        return null;
    }
};

fn cmsgAlign(value: usize) usize {
    return std.mem.alignForward(usize, value, @sizeOf(usize));
}

fn cmsgSpace(data_len: usize) usize {
    return cmsgAlign(@sizeOf(linux.cmsghdr)) + cmsgAlign(data_len);
}

fn closeFds(fds: []const wire.FileDescriptor) void {
    for (fds) |fd| _ = linux.close(fd);
}

fn completionError(res: i32) ?linux.E {
    if (res >= 0) return null;
    if (res <= -4096) return .IO;
    return @enumFromInt(@as(u16, @intCast(-@as(i64, res))));
}

fn socketAddress(path: []const u8) !struct { linux.sockaddr.un, linux.socklen_t } {
    var address: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = @splat(0) };
    if (path.len == 0 or path.len >= address.path.len) return error.InvalidSocketPath;
    @memcpy(address.path[0..path.len], path);
    return .{ address, @intCast(@offsetOf(linux.sockaddr.un, "path") + path.len + 1) };
}

fn openListener(path: [:0]const u8) !linux.fd_t {
    const address, const address_len = try socketAddress(path);
    const raw_fd = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(raw_fd) != .SUCCESS) return error.SocketFailed;
    const fd: linux.fd_t = @intCast(raw_fd);
    errdefer _ = linux.close(fd);
    const bind_result = linux.bind(fd, @ptrCast(&address), address_len);
    switch (linux.errno(bind_result)) {
        .SUCCESS => {},
        .ADDRINUSE => return error.AddressInUse,
        else => return error.BindFailed,
    }
    errdefer _ = linux.unlink(path.ptr);
    if (linux.errno(linux.listen(fd, linux.SOMAXCONN)) != .SUCCESS) return error.ListenFailed;
    return fd;
}

fn removeSocketPath(path: [:0]const u8) !void {
    var status: linux.Statx = undefined;
    const stat_result = linux.statx(linux.AT.FDCWD, path.ptr, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &status);
    switch (linux.errno(stat_result)) {
        .NOENT => return,
        .SUCCESS => if (status.mode & linux.S.IFMT != linux.S.IFSOCK) return error.SocketPathOccupied,
        else => return error.SocketPathInspectionFailed,
    }
    switch (linux.errno(linux.unlink(path.ptr))) {
        .SUCCESS, .NOENT => {},
        else => return error.UnlinkFailed,
    }
}

fn peerCredentials(fd: linux.fd_t) !server.Client.Credentials {
    var credentials: LinuxCredentials = undefined;
    var size: linux.socklen_t = @sizeOf(LinuxCredentials);
    const result = linux.getsockopt(
        fd,
        linux.SOL.SOCKET,
        linux.SO.PEERCRED,
        std.mem.asBytes(&credentials).ptr,
        &size,
    );
    if (linux.errno(result) != .SUCCESS) return error.PeerCredentialsUnavailable;
    if (size != @sizeOf(LinuxCredentials)) return error.InvalidPeerCredentials;
    return .{ .pid = credentials.pid, .uid = credentials.uid, .gid = credentials.gid };
}

fn parseRights(connection: *Connection, control_len: usize, message_flags: u32) !usize {
    var count: usize = 0;
    errdefer closeFds(connection.fd_scratch[0..count]);
    const control_overflow = control_len > connection.control.len;
    const bytes = connection.control[0..@min(control_len, connection.control.len)];
    var offset: usize = 0;
    while (offset < bytes.len) {
        if (bytes.len - offset < @sizeOf(linux.cmsghdr)) return error.MalformedControl;
        const header: *align(1) const linux.cmsghdr = @ptrCast(bytes[offset..].ptr);
        if (header.len < @sizeOf(linux.cmsghdr) or header.len > bytes.len - offset) return error.MalformedControl;
        const payload_start = offset + cmsgAlign(@sizeOf(linux.cmsghdr));
        if (payload_start > offset + header.len) return error.MalformedControl;
        const payload = bytes[payload_start .. offset + header.len];
        if (header.level == linux.SOL.SOCKET and header.type == linux.SCM.RIGHTS) {
            const fd_count = payload.len / @sizeOf(wire.FileDescriptor);
            const overflow = fd_count > connection.fd_scratch.len - count;
            for (0..fd_count) |index| {
                const start = index * @sizeOf(wire.FileDescriptor);
                const fd = std.mem.bytesToValue(wire.FileDescriptor, payload[start..][0..@sizeOf(wire.FileDescriptor)]);
                if (count == connection.fd_scratch.len) {
                    _ = linux.close(fd);
                } else {
                    connection.fd_scratch[count] = fd;
                    count += 1;
                }
            }
            if (overflow or payload.len % @sizeOf(wire.FileDescriptor) != 0)
                return error.MalformedControl;
        }
        const next = cmsgAlign(offset + header.len);
        if (next <= offset) return error.MalformedControl;
        if (next > bytes.len) {
            if (offset + header.len != bytes.len) return error.MalformedControl;
            offset = bytes.len;
        } else offset = next;
    }
    if (control_overflow or (message_flags & linux.MSG.CTRUNC) != 0) return error.TruncatedControl;
    return count;
}

fn writeControlHeader(bytes: []u8, len: usize, level: i32, kind: i32) void {
    const header: *align(1) linux.cmsghdr = @ptrCast(bytes.ptr);
    header.* = .{ .len = len, .level = level, .type = kind };
}

fn encodeRights(control: []u8, fds: []const wire.FileDescriptor) void {
    @memset(control, 0);
    const header_len = cmsgAlign(@sizeOf(linux.cmsghdr));
    const payload_len = fds.len * @sizeOf(wire.FileDescriptor);
    std.debug.assert(control.len == cmsgSpace(payload_len));
    writeControlHeader(control, header_len + payload_len, linux.SOL.SOCKET, linux.SCM.RIGHTS);
    for (fds, 0..) |fd, index| {
        const start = header_len + index * @sizeOf(wire.FileDescriptor);
        @memcpy(control[start..][0..@sizeOf(wire.FileDescriptor)], std.mem.asBytes(&fd));
    }
}

fn testPeerSocket() !linux.fd_t {
    var sockets: [2]linux.fd_t = undefined;
    const result = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets);
    if (linux.errno(result) != .SUCCESS) return error.SocketPairFailed;
    _ = linux.close(sockets[1]);
    return sockets[0];
}

test "automatic listener chooses the next name and removes owned socket paths" {
    var unique_marker: u8 = 0;
    const directory = try std.fmt.allocPrintSentinel(
        std.testing.allocator,
        "/tmp/keywork-wayring-{d}-{x}",
        .{ linux.getpid(), @intFromPtr(&unique_marker) },
        0,
    );
    defer std.testing.allocator.free(directory);
    if (linux.errno(linux.mkdir(directory.ptr, 0o700)) != .SUCCESS) return error.TestDirectoryCreationFailed;
    defer _ = linux.rmdir(directory.ptr);

    const occupied = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/wayland-0", .{directory}, 0);
    defer std.testing.allocator.free(occupied);
    const occupied_fd = try openListener(occupied);
    defer {
        _ = linux.close(occupied_fd);
        _ = linux.unlink(occupied.ptr);
    }

    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var transport = try Server.listenAuto(std.testing.allocator, &host, directory);
    try std.testing.expectEqualStrings("wayland-1", transport.socketName().?);
    const owned_path = try std.testing.allocator.dupeZ(u8, transport.owned_socket_path.?);
    defer std.testing.allocator.free(owned_path);
    try transport.deinit();

    var status: linux.Statx = undefined;
    const stat_result = linux.statx(linux.AT.FDCWD, owned_path.ptr, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &status);
    try std.testing.expectEqual(linux.E.NOENT, linux.errno(stat_result));
}

test "SCM_RIGHTS encoder emits one ordered descriptor message" {
    const fds = [_]wire.FileDescriptor{ 19, 7, 42 };
    var control: [cmsgSpace(fds.len * @sizeOf(wire.FileDescriptor))]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    encodeRights(&control, &fds);

    const header: *const linux.cmsghdr = @ptrCast(&control);
    const payload_start = cmsgAlign(@sizeOf(linux.cmsghdr));
    try std.testing.expectEqual(linux.SOL.SOCKET, header.level);
    try std.testing.expectEqual(linux.SCM.RIGHTS, header.type);
    try std.testing.expectEqual(payload_start + fds.len * @sizeOf(wire.FileDescriptor), header.len);
    for (fds, 0..) |expected, index| {
        const start = payload_start + index * @sizeOf(wire.FileDescriptor);
        try std.testing.expectEqual(expected, std.mem.bytesToValue(wire.FileDescriptor, control[start..][0..@sizeOf(wire.FileDescriptor)]));
    }
}

test "SCM_RIGHTS parser preserves order and closes parsed descriptors on truncation" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    const core = try server.CoreClient.create(std.testing.allocator, &host, .{});
    defer core.destroy();
    var connection: Connection = .{ .fd = -1, .core = core };

    var fds = [_]wire.FileDescriptor{ @intCast(linux.dup(0)), @intCast(linux.dup(0)) };
    var fds_owned = true;
    defer if (fds_owned) closeFds(&fds);
    const header_len = cmsgAlign(@sizeOf(linux.cmsghdr));
    const payload_len = fds.len * @sizeOf(wire.FileDescriptor);
    writeControlHeader(&connection.control, header_len + payload_len, linux.SOL.SOCKET, linux.SCM.RIGHTS);
    for (&fds, 0..) |*fd, index| {
        const start = header_len + index * @sizeOf(wire.FileDescriptor);
        @memcpy(connection.control[start..][0..@sizeOf(wire.FileDescriptor)], std.mem.asBytes(fd));
    }
    const count = try parseRights(&connection, header_len + payload_len, 0);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(fds[0], connection.fd_scratch[0]);
    try std.testing.expectEqual(fds[1], connection.fd_scratch[1]);

    try std.testing.expectError(error.TruncatedControl, parseRights(&connection, header_len + payload_len, linux.MSG.CTRUNC));
    fds_owned = false;
    for (fds) |fd| try std.testing.expect(linux.fcntl(fd, linux.F.GETFD, 0) > std.math.maxInt(isize));
}

test "SCM_RIGHTS parser rejects malformed control after closing earlier rights" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    const core = try server.CoreClient.create(std.testing.allocator, &host, .{});
    defer core.destroy();
    var connection: Connection = .{ .fd = -1, .core = core };
    var fd: wire.FileDescriptor = @intCast(linux.dup(0));
    var fd_owned = true;
    defer if (fd_owned) {
        _ = linux.close(fd);
    };
    const header_len = cmsgAlign(@sizeOf(linux.cmsghdr));
    const first_len = header_len + @sizeOf(wire.FileDescriptor);
    writeControlHeader(&connection.control, first_len, linux.SOL.SOCKET, linux.SCM.RIGHTS);
    @memcpy(connection.control[header_len..][0..@sizeOf(wire.FileDescriptor)], std.mem.asBytes(&fd));
    const second = cmsgAlign(first_len);
    writeControlHeader(connection.control[second..], 1, linux.SOL.SOCKET, linux.SCM.RIGHTS);
    try std.testing.expectError(error.MalformedControl, parseRights(&connection, second + @sizeOf(linux.cmsghdr), 0));
    fd_owned = false;
    try std.testing.expect(linux.fcntl(fd, linux.F.GETFD, 0) > std.math.maxInt(isize));
}

test "accepted connection is stable and requires explicit release" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    const listener: linux.fd_t = @intCast(linux.dup(0));
    var transport = try Server.init(std.testing.allocator, &host, listener);
    const accepted = try testPeerSocket();
    const result = try transport.completeAccept(accepted);
    const connection = result.accepted;
    try std.testing.expect(connection.client() == connection.core.client());
    const credentials = connection.client().credentials().?;
    try std.testing.expectEqual(linux.getpid(), credentials.pid);
    try std.testing.expectEqual(linux.getuid(), credentials.uid);
    try std.testing.expectEqual(linux.getgid(), credentials.gid);
    try std.testing.expectEqual(server.Client.TransportProvenance.unknown, connection.client().transportProvenance());
    try std.testing.expectError(error.ConnectionsLive, transport.deinit());
    const interface: wire.Interface = .{ .name = "test_application", .version = 1 };
    var resource: server.Resource = .init(std.testing.allocator, 2, 1, &interface, &.{}, .client, connection.client().ownerHooks());
    try connection.client().installClientInitial(2, &resource);
    try std.testing.expectError(error.ApplicationResourcesLive, transport.release(connection));
    try std.testing.expect(linux.fcntl(accepted, linux.F.GETFD, 0) <= std.math.maxInt(isize));
    resource.destroy();
    resource.deinit();
    try transport.release(connection);
    try transport.deinit();
}

test "accepted connections snapshot server-assigned security provenance" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    const listener: linux.fd_t = @intCast(linux.dup(0));
    var transport = try Server.initWithOptions(std.testing.allocator, &host, listener, .{
        .transport_provenance = .security_context,
    });
    const connection = (try transport.completeAccept(try testPeerSocket())).accepted;
    try std.testing.expectEqual(
        server.Client.TransportProvenance.security_context,
        connection.client().transportProvenance(),
    );
    try std.testing.expectEqual(linux.getuid(), connection.client().credentials().?.uid);
    try transport.release(connection);
    try transport.deinit();
}

test "pre-lifecycle acceptance OOM rejects one peer without disturbing existing clients" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    const listener: linux.fd_t = @intCast(linux.dup(0));
    var transport = try Server.init(failing.allocator(), &host, listener);
    const existing = (try transport.completeAccept(try testPeerSocket())).accepted;

    failing.fail_index = failing.alloc_index;
    const rejected_fd = try testPeerSocket();
    try std.testing.expect((try transport.completeAccept(rejected_fd)) == .retry);
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(linux.fcntl(rejected_fd, linux.F.GETFD, 0) > std.math.maxInt(isize));
    try std.testing.expectEqual(@as(usize, 1), transport.connections.items.len);
    try std.testing.expectEqual(Connection.State.ready, existing.state());
    try std.testing.expect(existing.client().fatal() == null);

    failing.fail_index = std.math.maxInt(usize);
    try transport.release(existing);
    try transport.deinit();
}

test "asynchronous fatal selects output not receive and leaves peers active" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    const listener: linux.fd_t = @intCast(linux.dup(0));
    var transport = try Server.init(std.testing.allocator, &host, listener);
    const connection = (try transport.completeAccept(try testPeerSocket())).accepted;
    const peer = (try transport.completeAccept(try testPeerSocket())).accepted;
    var ring = try linux.IoUring.init(8, 0);
    defer ring.deinit();

    const display = connection.client().lookup(1).?;
    connection.client().postOutOfMemory(display, "asynchronous generated event failure");
    transport.accept_pending = true;
    const prepared = try transport.prepareNext(&ring, 100);
    const token = prepared.prepared;
    try std.testing.expect((try transport.operations.lookup(token)) == .send);
    try std.testing.expectEqual(Connection.State.terminal, connection.state());
    const send_len = connection.send_iov.len;
    const completed = try transport.complete(token, @intCast(send_len), 0);
    try std.testing.expect(completed == .sent);
    try std.testing.expect(!connection.client().hasPendingOutput());
    try std.testing.expectEqual(Connection.State.ready, peer.state());
    try std.testing.expect(peer.client().fatal() == null);

    transport.accept_pending = false;
    try transport.release(connection);
    try transport.release(peer);
    try transport.deinit();
}

test "terminal receive is canceled and raced input is never dispatched" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    const listener: linux.fd_t = @intCast(linux.dup(0));
    var transport = try Server.init(std.testing.allocator, &host, listener);
    const connection = (try transport.completeAccept(try testPeerSocket())).accepted;
    var ring = try linux.IoUring.init(8, 0);
    defer ring.deinit();

    connection.resetMessage();
    try transport.operations.prepare(.recv(connection), 200);
    const recv_token = transport.operations.commitPrepared();
    connection.recv_pending = true;
    connection.client().postImplementationError(
        connection.client().lookup(1).?,
        "fatal outside dispatch",
    );
    transport.accept_pending = true;
    const cancellation = (try transport.prepareNext(&ring, 201)).prepared;
    const cancel_operation = (try transport.operations.lookup(cancellation)).cancel;
    try std.testing.expectEqual(recv_token, cancel_operation.target);
    try std.testing.expectEqual(Connection.State.terminal, connection.state());

    connection.data[0..12].* = .{
        1, 0, 0,  0,
        0, 0, 12, 0,
        2, 0, 0,  0,
    };
    connection.msg.controllen = 0;
    connection.msg.flags = 0;
    const raced = try transport.complete(recv_token, 12, 0);
    try std.testing.expect(raced == .terminal);
    try std.testing.expect(connection.client().lookup(2) == null);
    try std.testing.expect(!connection.recv_pending);
    try std.testing.expect((try transport.complete(
        cancellation,
        -@as(i32, @intFromEnum(linux.E.NOENT)),
        0,
    )) == .cancellation);

    while (try connection.client().beginSend()) |batch|
        try connection.client().completeSend(batch.token, batch.bytes.len);
    transport.accept_pending = false;
    try transport.release(connection);
    try transport.deinit();
}

test "recv completion transfers SCM_RIGHTS ownership into the core" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    const listener: linux.fd_t = @intCast(linux.dup(0));
    var transport = try Server.init(std.testing.allocator, &host, listener);
    const accepted = try testPeerSocket();
    const connection = (try transport.completeAccept(accepted)).accepted;

    var received_fd: wire.FileDescriptor = @intCast(linux.dup(0));
    const header_len = cmsgAlign(@sizeOf(linux.cmsghdr));
    const control_len = header_len + @sizeOf(wire.FileDescriptor);
    writeControlHeader(&connection.control, control_len, linux.SOL.SOCKET, linux.SCM.RIGHTS);
    @memcpy(connection.control[header_len..][0..@sizeOf(wire.FileDescriptor)], std.mem.asBytes(&received_fd));
    connection.msg.controllen = control_len;
    connection.msg.flags = 0;
    connection.data[0..4].* = .{ 1, 0, 0, 0 };
    connection.recv_pending = true;
    try std.testing.expect((try transport.completeRecv(connection, 4)) == .received);
    try std.testing.expect(!connection.recv_pending);
    try transport.release(connection);
    try std.testing.expect(linux.fcntl(received_fd, linux.F.GETFD, 0) > std.math.maxInt(isize));
    try transport.deinit();
}

test "retryable send completion reports an earlier peer disconnect" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    const listener: linux.fd_t = @intCast(linux.dup(0));
    var transport = try Server.init(std.testing.allocator, &host, listener);
    const accepted = try testPeerSocket();
    const connection = (try transport.completeAccept(accepted)).accepted;

    try connection.client().receive(&.{
        1, 0, 0, 0, 0, 0, 12, 0,
        2, 0, 0, 0,
    }, &.{});
    try connection.client().dispatch();
    const batch = (try connection.client().beginSend()).?;
    connection.send_pending = true;
    _ = transport.disconnect(connection);
    const result = try transport.completeSend(connection, batch.token, -@as(i32, @intFromEnum(linux.E.AGAIN)));
    try std.testing.expect(result == .peer_disconnected);
    try std.testing.expect(!connection.send_pending);

    try transport.release(connection);
    try transport.deinit();
}

test "canceled send completion unwinds the wire batch" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    const listener: linux.fd_t = @intCast(linux.dup(0));
    var transport = try Server.init(std.testing.allocator, &host, listener);
    const accepted = try testPeerSocket();
    const connection = (try transport.completeAccept(accepted)).accepted;

    try connection.client().receive(&.{
        1, 0, 0, 0, 0, 0, 12, 0,
        2, 0, 0, 0,
    }, &.{});
    try connection.client().dispatch();
    const batch = (try connection.client().beginSend()).?;
    connection.send_pending = true;
    transport.beginShutdown();
    const result = try transport.completeSend(connection, batch.token, -@as(i32, @intFromEnum(linux.E.CANCELED)));
    try std.testing.expect(result == .peer_disconnected);
    try std.testing.expect(!connection.send_pending);
    try std.testing.expect(connection.send_control == null);

    try transport.release(connection);
    try transport.deinit();
}

fn testOwner(value: *u8) *anyopaque {
    return value;
}

test "prepare commit take rejects stale token and reuses slot" {
    var table: OperationTable = .init(std.testing.allocator);
    defer table.deinit();
    var byte: u8 = 0;
    try table.prepare(.recv(testOwner(&byte)), 9);
    const first = table.commitPrepared();
    _ = try table.take(first);
    try table.prepare(.accept(testOwner(&byte)), 10);
    const second = table.commitPrepared();
    try std.testing.expectEqual(first.slot, second.slot);
    try std.testing.expect(first.generation != second.generation);
    try std.testing.expectError(error.StaleToken, table.take(first));
    _ = try table.take(second);
}

test "abort consumes no generation external is reusable and models SQ full" {
    var table: OperationTable = .init(std.testing.allocator);
    defer table.deinit();
    var byte: u8 = 0;
    try table.prepare(.recv(testOwner(&byte)), 4);
    try std.testing.expectError(error.PrepareAlreadyPending, table.prepare(.accept(testOwner(&byte)), 5));
    try table.abortPrepared();
    try std.testing.expectError(error.NoPreparedOperation, table.abortPrepared());
    try table.prepare(.accept(testOwner(&byte)), 4);
    const token = table.commitPrepared();
    try std.testing.expectEqual(@as(u32, 1), token.generation);
    _ = try table.take(token);
}

test "commit take and cancel commit allocate nothing after prepare" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var table: OperationTable = .init(failing.allocator());
    defer table.deinit();
    var byte: u8 = 0;
    try table.prepare(.send(testOwner(&byte), .{ .value = 7 }), 20);
    failing.fail_index = failing.alloc_index;
    const original = table.commitPrepared();
    _ = try table.lookup(original);
    failing.fail_index = std.math.maxInt(usize);
    try table.prepareCancel(original, testOwner(&byte), 21);
    failing.fail_index = failing.alloc_index;
    const cancel = table.commitPrepared();
    _ = try table.take(cancel);
    _ = try table.take(original);
    try std.testing.expect(!failing.has_induced_failure);
}

test "cancel completion orders preserve references and abort restores intent" {
    var byte: u8 = 0;
    inline for (.{ false, true }) |cancel_first| {
        var table: OperationTable = .init(std.testing.allocator);
        defer table.deinit();
        try table.prepare(.recv(testOwner(&byte)), 30);
        const original = table.commitPrepared();
        try table.prepareCancel(original, testOwner(&byte), 31);
        try table.abortPrepared();
        try table.prepareCancel(original, testOwner(&byte), 31);
        const cancel = table.commitPrepared();
        try std.testing.expectError(error.CancelAlreadyQueued, table.prepareCancel(original, testOwner(&byte), 32));
        try std.testing.expectError(error.CannotCancelCancellation, table.prepareCancel(cancel, testOwner(&byte), 32));
        _ = try table.take(if (cancel_first) cancel else original);
        try std.testing.expectError(error.DuplicateExternalUserData, table.prepare(.accept(testOwner(&byte)), 30));
        _ = try table.take(if (cancel_first) original else cancel);
        try table.prepare(.accept(testOwner(&byte)), 30);
        const reused = table.commitPrepared();
        _ = try table.take(reused);
    }
}

test "shutdown with no operations is immediately drained" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    const listener: linux.fd_t = @intCast(linux.dup(0));
    var transport = try Server.init(std.testing.allocator, &host, listener);
    try std.testing.expect(!transport.isDrained());
    transport.beginShutdown();
    transport.beginShutdown();
    try std.testing.expect(transport.isDrained());
    const raced_accept: linux.fd_t = @intCast(linux.dup(0));
    try std.testing.expect((try transport.completeAccept(raced_accept)) == .cancellation);
    try std.testing.expect(linux.fcntl(raced_accept, linux.F.GETFD, 0) > std.math.maxInt(isize));
    try transport.deinit();
}

test "shutdown drain requires original and cancellation CQEs in either order" {
    inline for (.{ false, true }) |cancel_first| {
        var host: server.Server = .init(std.testing.allocator);
        defer host.deinit();
        const listener: linux.fd_t = @intCast(linux.dup(0));
        var transport = try Server.init(std.testing.allocator, &host, listener);
        transport.beginShutdown();

        try transport.operations.prepare(.accept(&transport), 40);
        const original = transport.operations.commitPrepared();
        transport.accept_pending = true;
        try transport.operations.prepareCancel(original, &transport, 41);
        const cancellation = transport.operations.commitPrepared();
        try std.testing.expect(!transport.isDrained());

        const first = if (cancel_first) cancellation else original;
        const first_res: i32 = if (cancel_first) -@as(i32, @intFromEnum(linux.E.NOENT)) else -@as(i32, @intFromEnum(linux.E.CANCELED));
        _ = try transport.complete(first, first_res, 0);
        try std.testing.expect(!transport.isDrained());
        const second = if (cancel_first) original else cancellation;
        const second_res: i32 = if (cancel_first) -@as(i32, @intFromEnum(linux.E.CANCELED)) else 0;
        _ = try transport.complete(second, second_res, 0);
        try std.testing.expect(transport.isDrained());
        try transport.deinit();
    }
}

test "request variants make illegal batch states unrepresentable" {
    var table: OperationTable = .init(std.testing.allocator);
    defer table.deinit();
    var byte: u8 = 0;
    try table.prepare(.send(testOwner(&byte), .{ .value = 99 }), 1);
    const send_token = table.commitPrepared();
    try std.testing.expectEqual(@as(u64, 99), (try table.lookup(send_token)).send.batch.value);
    _ = try table.take(send_token);
    try table.prepare(.accept(testOwner(&byte)), 2);
    const accept_token = table.commitPrepared();
    try std.testing.expect((try table.lookup(accept_token)) == .accept);
    _ = try table.take(accept_token);
    try table.prepare(.recv(testOwner(&byte)), 3);
    const recv_token = table.commitPrepared();
    try std.testing.expect((try table.lookup(recv_token)) == .recv);
    _ = try table.take(recv_token);
}

test "generation wrap retires slot" {
    var table: OperationTable = .init(std.testing.allocator);
    defer table.deinit();
    var byte: u8 = 0;
    try table.prepare(.recv(testOwner(&byte)), 1);
    var token = table.commitPrepared();
    table.forceGenerationForTest(token, std.math.maxInt(u32));
    token.generation = std.math.maxInt(u32);
    _ = try table.take(token);
    try table.prepare(.recv(testOwner(&byte)), 2);
    const next = table.commitPrepared();
    try std.testing.expect(next.slot != token.slot);
    try std.testing.expectError(error.OperationAlreadyCompleted, table.take(token));
    _ = try table.take(next);
}
