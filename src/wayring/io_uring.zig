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
    retry,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    sans_io: *server.Server,
    listener_fd: linux.fd_t,
    operations: OperationTable,
    connections: std.ArrayList(*Connection) = .empty,
    accept_pending: bool = false,
    prefer_accept: bool = true,
    prefer_send: bool = true,
    connection_cursor: usize = 0,

    /// Takes ownership of an already-bound, listening Unix socket descriptor.
    pub fn init(allocator: std.mem.Allocator, sans_io: *server.Server, listener_fd: linux.fd_t) !Server {
        if (listener_fd < 0) return error.InvalidListener;
        return .{
            .allocator = allocator,
            .sans_io = sans_io,
            .listener_fd = listener_fd,
            .operations = .init(allocator),
        };
    }

    /// Shutdown cancellation is deliberately not simulated: the host must
    /// complete all operations and explicitly release all connections first.
    pub fn deinit(self: *Server) !void {
        if (self.operations.live_count != 0 or self.operations.prepared != null) return error.OperationsInFlight;
        if (self.connections.items.len != 0) return error.ConnectionsLive;
        _ = linux.close(self.listener_fd);
        self.connections.deinit(self.allocator);
        self.operations.deinit();
        self.* = undefined;
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
            .cancel => error.UnsupportedOperation,
        };
    }

    fn completeAccept(self: *Server, res: i32) !CompleteResult {
        self.accept_pending = false;
        if (completionError(res)) |err| return switch (err) {
            .INTR, .AGAIN, .CONNABORTED => .retry,
            else => .{ .listener_error = err },
        };
        const fd: linux.fd_t = @intCast(res);
        errdefer _ = linux.close(fd);
        const connection = try self.allocator.create(Connection);
        errdefer self.allocator.destroy(connection);
        const core = try server.CoreClient.create(self.allocator, self.sans_io, .{});
        errdefer core.destroy();
        connection.* = .{ .fd = fd, .core = core };
        try self.connections.append(self.allocator, connection);
        return .{ .accepted = connection };
    }

    fn completeRecv(self: *Server, connection: *Connection, res: i32) !CompleteResult {
        defer connection.recv_pending = false;
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
    const accepted: linux.fd_t = @intCast(linux.dup(0));
    const result = try transport.completeAccept(accepted);
    const connection = result.accepted;
    try std.testing.expect(connection.client() == connection.core.client());
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

test "recv completion transfers SCM_RIGHTS ownership into the core" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    const listener: linux.fd_t = @intCast(linux.dup(0));
    var transport = try Server.init(std.testing.allocator, &host, listener);
    const accepted: linux.fd_t = @intCast(linux.dup(0));
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
    const accepted: linux.fd_t = @intCast(linux.dup(0));
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
