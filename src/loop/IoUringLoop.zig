//! Linux io_uring completion reactor with generation-checked operation storage.
//!
//! Callback contexts and all memory referenced by an SQE are caller-owned.
//! That memory must remain valid until the operation's terminal CQE, including
//! after `remove` suppresses its callback and requests asynchronous cancel.

const IoUringLoop = @This();

const std = @import("std");
const linux = std.os.linux;

allocator: std.mem.Allocator,
ring: linux.IoUring,
slots: std.ArrayList(Slot) = .empty,
free_slots: std.ArrayList(u32) = .empty,
active_count: usize = 0,
running: bool = false,

pub const default_queue_depth: u16 = 64;

pub const Completion = struct {
    result: i32,
    flags: u32,

    pub fn more(self: Completion) bool {
        return self.flags & linux.IORING_CQE_F_MORE != 0;
    }
};

pub const Handle = struct {
    index: u32,
    generation: u32,
};

pub const Callback = *const fn (context: *anyopaque, loop: *IoUringLoop, completion: Completion) anyerror!void;
pub const Prepare = *const fn (context: *anyopaque, sqe: *linux.io_uring_sqe) void;

const Slot = struct {
    generation: u32 = 0,
    operation: ?Operation = null,
};

const Operation = struct {
    context: *anyopaque,
    callback: Callback,
    removed: bool = false,
};

pub fn init(allocator: std.mem.Allocator) !IoUringLoop {
    return initWithDepth(allocator, default_queue_depth);
}

pub fn initWithDepth(allocator: std.mem.Allocator, queue_depth: u16) !IoUringLoop {
    return .{
        .allocator = allocator,
        .ring = try linux.IoUring.init(queue_depth, 0),
    };
}

/// All operations must have delivered a terminal CQE before deinitialization.
/// Callback contexts remain owned by callers and are never destroyed here.
pub fn deinit(self: *IoUringLoop) void {
    std.debug.assert(self.active_count == 0);
    self.slots.deinit(self.allocator);
    self.free_slots.deinit(self.allocator);
    self.ring.deinit();
}

/// Queues one operation. `prepare` may initialize every SQE field, but this
/// reactor always replaces `user_data`; the SQE pointer is invalid on return.
pub fn queue(
    self: *IoUringLoop,
    context: *anyopaque,
    callback: Callback,
    prepare_context: *anyopaque,
    prepare: Prepare,
) !Handle {
    const handle = try self.allocate(context, callback);
    errdefer self.release(handle);

    const sqe = try self.getSqe();
    prepare(prepare_context, sqe);
    sqe.user_data = token(handle);
    return handle;
}

/// Suppresses future callback dispatch and requests cancellation. The slot,
/// SQE-referenced buffers, and callback context remain live until the target's
/// terminal CQE. Calling remove repeatedly or with a stale handle is harmless.
pub fn remove(self: *IoUringLoop, handle: Handle) !void {
    const operation_value = self.operation(handle) orelse return;
    if (operation_value.removed) return;
    try self.queueCancellation(handle);
    // allocate may have moved slot storage, so resolve the target again.
    self.operation(handle).?.removed = true;
}

/// Requests cancellation while preserving the target callback. The target's
/// terminal CQE, usually `-ECANCELED`, remains observable so an owner can
/// release fd and callback storage only after the kernel is finished with it.
pub fn cancel(self: *IoUringLoop, handle: Handle) !void {
    if (self.operation(handle) == null) return;
    try self.queueCancellation(handle);
}

/// Reports whether an operation still owns a slot. A removed operation stays
/// active until its terminal CQE, so callers can safely retain SQE buffers.
pub fn isActive(self: *IoUringLoop, handle: Handle) bool {
    return self.operation(handle) != null;
}

pub fn hasActiveOperations(self: *const IoUringLoop) bool {
    return self.active_count != 0;
}

/// Submits pending SQEs without waiting for or dispatching completions. Most
/// consumers should use `runOnce`; this is for code that must make queued I/O
/// visible before it performs a bounded synchronous operation.
pub fn submit(self: *IoUringLoop) !u32 {
    return self.ring.submit();
}

pub fn quit(self: *IoUringLoop) void {
    self.running = false;
}

pub fn run(self: *IoUringLoop) !void {
    self.running = true;
    defer self.running = false;
    while (self.running and self.active_count != 0) try self.runOnce();
}

/// Submits pending SQEs, waits when no completion is already available, and
/// drains the CQ. Consumers never need to coordinate ring entry themselves.
pub fn runOnce(self: *IoUringLoop) !void {
    return self.runOnceWait(true);
}

/// Submits and drains completions without waiting when none are ready.
pub fn pollOnce(self: *IoUringLoop) !void {
    return self.runOnceWait(false);
}

fn runOnceWait(self: *IoUringLoop, wait: bool) !void {
    if (self.active_count == 0) return;
    _ = try self.ring.submit_and_wait(if (wait and self.ring.cq_ready() == 0) 1 else 0);

    var cqes: [32]linux.io_uring_cqe = undefined;
    while (true) {
        const count = try self.ring.copy_cqes(&cqes, 0);
        if (count == 0) return;
        for (cqes[0..count]) |cqe| try self.dispatch(cqe.user_data, .{
            .result = cqe.res,
            .flags = cqe.flags,
        });
    }
}

fn queueCancellation(self: *IoUringLoop, handle: Handle) !void {
    const cancel_handle = try self.allocate(self, cancellationComplete);
    errdefer self.release(cancel_handle);
    const sqe = try self.getSqe();
    sqe.prep_cancel(token(handle), 0);
    sqe.user_data = token(cancel_handle);
}

fn allocate(self: *IoUringLoop, context: *anyopaque, callback: Callback) !Handle {
    const index: u32 = if (self.free_slots.pop()) |index| index else blk: {
        const index: u32 = @intCast(self.slots.items.len);
        try self.slots.append(self.allocator, .{});
        break :blk index;
    };
    const slot = &self.slots.items[index];
    std.debug.assert(slot.operation == null);
    slot.operation = .{ .context = context, .callback = callback };
    self.active_count += 1;
    return .{ .index = index, .generation = slot.generation };
}

fn release(self: *IoUringLoop, handle: Handle) void {
    const slot = &self.slots.items[handle.index];
    std.debug.assert(slot.generation == handle.generation and slot.operation != null);
    slot.operation = null;
    slot.generation +%= 1;
    self.active_count -= 1;
    self.free_slots.append(self.allocator, handle.index) catch {
        // Retaining an unused slot is safe under OOM; it simply cannot be reused.
    };
}

fn operation(self: *IoUringLoop, handle: Handle) ?*Operation {
    if (handle.index >= self.slots.items.len) return null;
    const slot = &self.slots.items[handle.index];
    if (slot.generation != handle.generation) return null;
    return if (slot.operation) |*operation_value| operation_value else null;
}

fn getSqe(self: *IoUringLoop) !*linux.io_uring_sqe {
    return self.ring.get_sqe() catch |err| switch (err) {
        error.SubmissionQueueFull => {
            _ = try self.ring.submit();
            return try self.ring.get_sqe();
        },
    };
}

fn dispatch(self: *IoUringLoop, user_data: u64, completion: Completion) !void {
    const handle = handleFromToken(user_data);
    const operation_value = self.operation(handle) orelse return;
    const callback = operation_value.callback;
    const context = operation_value.context;
    const removed = operation_value.removed;

    if (!removed) callback(context, self, completion) catch |err| {
        if (!completion.more() and self.operation(handle) != null) self.release(handle);
        return err;
    };
    if (!completion.more() and self.operation(handle) != null) self.release(handle);
}

fn cancellationComplete(_: *anyopaque, _: *IoUringLoop, _: Completion) !void {}

fn token(handle: Handle) u64 {
    return (@as(u64, handle.generation) << 32) | handle.index;
}

fn handleFromToken(value: u64) Handle {
    return .{ .index = @truncate(value), .generation = @truncate(value >> 32) };
}

fn prepareNop(_: *anyopaque, sqe: *linux.io_uring_sqe) void {
    sqe.prep_nop();
}

test "NOP completion dispatches its signed result" {
    const Context = struct {
        called: bool = false,
        result: i32 = -1,

        fn complete(context: *anyopaque, _: *IoUringLoop, completion: Completion) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.called = true;
            self.result = completion.result;
        }
    };

    var loop = try IoUringLoop.init(std.testing.allocator);
    defer loop.deinit();
    var context: Context = .{};
    _ = try loop.queue(&context, Context.complete, &context, prepareNop);
    try loop.run();
    try std.testing.expect(context.called);
    try std.testing.expectEqual(@as(i32, 0), context.result);
}

test "submit makes queued operations visible without dispatching callbacks" {
    const Context = struct {
        called: bool = false,

        fn complete(context: *anyopaque, _: *IoUringLoop, _: Completion) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.called = true;
        }
    };

    var loop = try IoUringLoop.init(std.testing.allocator);
    defer loop.deinit();
    var context: Context = .{};
    _ = try loop.queue(&context, Context.complete, &context, prepareNop);
    try std.testing.expectEqual(@as(u32, 1), try loop.submit());
    try std.testing.expect(!context.called);
    try loop.runOnce();
    try std.testing.expect(context.called);
}

test "callback queues a second NOP and quits" {
    const Context = struct {
        count: usize = 0,

        fn complete(context: *anyopaque, loop: *IoUringLoop, _: Completion) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
            if (self.count == 1) {
                _ = try loop.queue(self, complete, self, prepareNop);
            } else {
                loop.quit();
            }
        }
    };

    var loop = try IoUringLoop.init(std.testing.allocator);
    defer loop.deinit();
    var context: Context = .{};
    _ = try loop.queue(&context, Context.complete, &context, prepareNop);
    try loop.run();
    try std.testing.expectEqual(@as(usize, 2), context.count);
}

test "removed pending poll is suppressed and retained until terminal CQE" {
    const Context = struct {
        fd: i32,
        called: bool = false,

        fn prepare(context: *anyopaque, sqe: *linux.io_uring_sqe) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            sqe.prep_poll_add(self.fd, linux.POLL.IN);
        }

        fn complete(context: *anyopaque, _: *IoUringLoop, _: Completion) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.called = true;
        }
    };

    var pipe: [2]i32 = undefined;
    const pipe_result = linux.pipe2(&pipe, .{ .CLOEXEC = true, .NONBLOCK = true });
    if (linux.errno(pipe_result) != .SUCCESS) return error.PipeFailed;
    defer for (pipe) |fd| {
        _ = linux.close(fd);
    };

    var loop = try IoUringLoop.init(std.testing.allocator);
    defer loop.deinit();
    var context: Context = .{ .fd = pipe[0] };
    const handle = try loop.queue(&context, Context.complete, &context, Context.prepare);
    try loop.remove(handle);
    try std.testing.expect(loop.operation(handle) != null);
    while (loop.active_count != 0) try loop.runOnce();
    try std.testing.expect(!context.called);
    try std.testing.expect(loop.operation(handle) == null);
}

test "cancel preserves the target terminal completion" {
    const Context = struct {
        fd: i32,
        called: bool = false,
        result: i32 = 0,

        fn prepare(context: *anyopaque, sqe: *linux.io_uring_sqe) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            sqe.prep_poll_add(self.fd, linux.POLL.IN);
        }

        fn complete(context: *anyopaque, _: *IoUringLoop, completion: Completion) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.called = true;
            self.result = completion.result;
        }
    };

    var pipe: [2]i32 = undefined;
    const pipe_result = linux.pipe2(&pipe, .{ .CLOEXEC = true, .NONBLOCK = true });
    if (linux.errno(pipe_result) != .SUCCESS) return error.PipeFailed;
    defer for (pipe) |fd| {
        _ = linux.close(fd);
    };

    var loop = try IoUringLoop.init(std.testing.allocator);
    defer loop.deinit();
    var context: Context = .{ .fd = pipe[0] };
    const handle = try loop.queue(&context, Context.complete, &context, Context.prepare);
    try loop.cancel(handle);
    while (loop.hasActiveOperations()) try loop.runOnce();
    try std.testing.expect(context.called);
    try std.testing.expectEqual(-@as(i32, @intFromEnum(linux.E.CANCELED)), context.result);
}

test "pollOnce submits without waiting for an incomplete operation" {
    const Context = struct {
        fd: i32,

        fn prepare(context: *anyopaque, sqe: *linux.io_uring_sqe) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            sqe.prep_poll_add(self.fd, linux.POLL.IN);
        }

        fn complete(_: *anyopaque, _: *IoUringLoop, _: Completion) !void {}
    };

    var pipe: [2]i32 = undefined;
    const pipe_result = linux.pipe2(&pipe, .{ .CLOEXEC = true, .NONBLOCK = true });
    if (linux.errno(pipe_result) != .SUCCESS) return error.PipeFailed;
    defer for (pipe) |fd| {
        _ = linux.close(fd);
    };

    var loop = try IoUringLoop.init(std.testing.allocator);
    defer loop.deinit();
    var context: Context = .{ .fd = pipe[0] };
    const handle = try loop.queue(&context, Context.complete, &context, Context.prepare);
    try loop.pollOnce();
    try std.testing.expect(loop.isActive(handle));
    try loop.remove(handle);
    while (loop.hasActiveOperations()) try loop.runOnce();
}

test "tokens reject stale generations" {
    const first: Handle = .{ .index = 7, .generation = 9 };
    try std.testing.expectEqual(first, handleFromToken(token(first)));
    try std.testing.expect(token(first) != token(.{ .index = 7, .generation = 10 }));
}

test "multishot completion retains slot until terminal completion" {
    const Context = struct {
        count: usize = 0,
        fn complete(context: *anyopaque, _: *IoUringLoop, _: Completion) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
        }
    };

    var loop = try IoUringLoop.init(std.testing.allocator);
    defer loop.deinit();
    var context: Context = .{};
    const handle = try loop.allocate(&context, Context.complete);
    try loop.dispatch(token(handle), .{ .result = 1, .flags = linux.IORING_CQE_F_MORE });
    try std.testing.expect(loop.operation(handle) != null);
    try loop.dispatch(token(handle), .{ .result = 0, .flags = 0 });
    try std.testing.expect(loop.operation(handle) == null);
    try std.testing.expectEqual(@as(usize, 2), context.count);
}
