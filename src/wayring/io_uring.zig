//! Host-boundary state for a future Linux io_uring transport adapter.
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
//! packed into kernel `user_data`. The table is currently private: this module
//! exposes no socket or ring adapter yet.

const std = @import("std");
const wire = @import("wire.zig");

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
