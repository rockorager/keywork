//! io_uring owner for one damage-aware Wayring SHM snapshot copy.
//!
//! The object, including its stable per-read contexts, remains caller-owned
//! until `isTerminal` becomes true. A completion callback may then consume the
//! snapshot and destroy the object.

const AsyncShmCopy = @This();

const std = @import("std");
const linux = std.os.linux;
const keywork_loop = @import("keywork-loop");
const IoUringLoop = keywork_loop.IoUringLoop;
const render = @import("../render/types.zig");
const shm = @import("shm.zig");

allocator: std.mem.Allocator,
loop: *IoUringLoop,
plan: shm.CopyPlan,
operations: []Operation,
remaining: usize = 0,
failure: ?anyerror = null,
started: bool = false,
terminal: bool = false,
notified: bool = false,
completion_context: ?*anyopaque,
completion_callback: CompletionCallback,

pub const CompletionCallback = *const fn (?*anyopaque, *AsyncShmCopy) void;

const Operation = struct {
    owner: *AsyncShmCopy,
    read: shm.CopyPlan.Read,
    handle: ?IoUringLoop.Handle = null,

    fn prepare(context: *anyopaque, sqe: *linux.io_uring_sqe) void {
        const self: *Operation = @ptrCast(@alignCast(context));
        sqe.prep_read(self.owner.plan.buffer.pool.fd, self.read.destination, self.read.offset);
    }

    fn complete(
        context: *anyopaque,
        _: *IoUringLoop,
        completion: IoUringLoop.Completion,
    ) !void {
        const self: *Operation = @ptrCast(@alignCast(context));
        self.handle = null;
        if (completion.result < 0) {
            self.owner.fail(error.ReadFailed);
        } else if (@as(usize, @intCast(completion.result)) != self.read.destination.len) {
            self.owner.fail(error.ShortRead);
        }
        std.debug.assert(self.owner.remaining > 0);
        self.owner.remaining -= 1;
        self.owner.maybeFinish();
    }
};

pub fn create(
    allocator: std.mem.Allocator,
    loop: *IoUringLoop,
    buffer: shm.Buffer,
    damage: ?[]const render.Rect,
    reuse: ?*shm.Snapshot,
    completion_context: ?*anyopaque,
    completion_callback: CompletionCallback,
) !*AsyncShmCopy {
    const self = try allocator.create(AsyncShmCopy);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .loop = loop,
        .plan = try shm.CopyPlan.init(allocator, buffer, damage, reuse),
        .operations = &.{},
        .completion_context = completion_context,
        .completion_callback = completion_callback,
    };
    errdefer self.plan.deinit();
    self.operations = try allocator.alloc(Operation, self.plan.reads.len);
    for (self.operations, self.plan.reads) |*operation, read|
        operation.* = .{ .owner = self, .read = read };
    return self;
}

/// Queues all positional reads. On queue failure already-queued reads are
/// canceled where possible and still retain this owner until their CQEs.
pub fn start(self: *AsyncShmCopy) !void {
    if (self.started) return error.AlreadyStarted;
    self.started = true;
    for (self.operations) |*operation| {
        const handle = self.loop.queue(
            operation,
            Operation.complete,
            operation,
            Operation.prepare,
        ) catch |err| {
            self.fail(err);
            self.cancelQueued();
            self.maybeFinish();
            return err;
        };
        operation.handle = handle;
        self.remaining += 1;
    }
    self.maybeFinish();
}

/// Requests cancellation without suppressing terminal callbacks.
pub fn cancel(self: *AsyncShmCopy) !void {
    if (!self.started or self.terminal) return;
    self.fail(error.Canceled);
    var first_error: ?anyerror = null;
    for (self.operations) |operation| if (operation.handle) |handle|
        self.loop.cancel(handle) catch |err| {
            if (first_error == null) first_error = err;
        };
    if (first_error) |err| return err;
}

pub fn isTerminal(self: *const AsyncShmCopy) bool {
    return self.terminal;
}

/// Publishes the snapshot only after every exact-length read succeeded.
pub fn takeSnapshot(self: *AsyncShmCopy) !shm.Snapshot {
    if (!self.terminal) return error.NotComplete;
    if (self.failure) |err| return err;
    if (self.plan.finished) return error.SnapshotAlreadyTaken;
    return self.plan.finish();
}

pub fn deinit(self: *AsyncShmCopy) void {
    std.debug.assert(!self.started or self.terminal);
    self.plan.deinit();
    self.allocator.free(self.operations);
    const allocator = self.allocator;
    self.* = undefined;
    allocator.destroy(self);
}

fn fail(self: *AsyncShmCopy, err: anyerror) void {
    if (self.failure == null) self.failure = err;
}

fn cancelQueued(self: *AsyncShmCopy) void {
    for (self.operations) |operation| if (operation.handle) |handle|
        self.loop.cancel(handle) catch {};
}

fn maybeFinish(self: *AsyncShmCopy) void {
    if (!self.started or self.remaining != 0 or self.terminal) return;
    self.terminal = true;
    if (!self.notified) {
        self.notified = true;
        self.completion_callback(self.completion_context, self);
    }
}

fn ignoreCompletion(_: ?*anyopaque, _: *AsyncShmCopy) void {}

fn writeAll(fd: i32, bytes: []const u8) !void {
    const result = linux.pwrite(fd, bytes.ptr, bytes.len, 0);
    if (linux.errno(result) != .SUCCESS or result != bytes.len) return error.WriteFailed;
}

test "asynchronous full and damage-reuse copies" {
    var loop = try IoUringLoop.init(std.testing.allocator);
    defer loop.deinit();
    const fd = try std.posix.memfd_create("async-shm-copy", linux.MFD.CLOEXEC);
    var fd_owned = true;
    defer if (fd_owned) {
        _ = linux.close(fd);
    };
    var source = [_]u32{ 1, 2, 3, 4, 5, 6 };
    try writeAll(fd, std.mem.sliceAsBytes(&source));
    const pool = try shm.Pool.create(std.testing.allocator, fd, @sizeOf(@TypeOf(source)), .{});
    fd_owned = false;
    defer pool.unreference();
    var buffer = try shm.Buffer.create(pool, 0, 3, 2, 12, @intFromEnum(shm.Format.argb8888));
    defer buffer.deinit();

    var copy = try AsyncShmCopy.create(
        std.testing.allocator,
        &loop,
        buffer,
        null,
        null,
        null,
        ignoreCompletion,
    );
    try copy.start();
    try loop.run();
    var snapshot = try copy.takeSnapshot();
    copy.deinit();
    try std.testing.expectEqualSlices(u32, &source, snapshot.pixels);

    source[1] = 20;
    source[4] = 50;
    try writeAll(fd, std.mem.sliceAsBytes(&source));
    const damage = [_]render.Rect{.{ .x = 1, .y = 0, .width = 1, .height = 2 }};
    copy = try AsyncShmCopy.create(
        std.testing.allocator,
        &loop,
        buffer,
        &damage,
        &snapshot,
        null,
        ignoreCompletion,
    );
    try copy.start();
    try loop.run();
    var updated = try copy.takeSnapshot();
    defer updated.deinit();
    copy.deinit();
    try std.testing.expectEqualSlices(u32, &source, updated.pixels);
    try std.testing.expectEqualSlices(render.Rect, &damage, updated.source_damage.?);
}

test "asynchronous short read never publishes a snapshot" {
    var loop = try IoUringLoop.init(std.testing.allocator);
    defer loop.deinit();
    const fd = try std.posix.memfd_create("async-shm-short", linux.MFD.CLOEXEC);
    var fd_owned = true;
    defer if (fd_owned) {
        _ = linux.close(fd);
    };
    if (linux.errno(linux.ftruncate(fd, 8)) != .SUCCESS) return error.TruncateFailed;
    const pool = try shm.Pool.create(std.testing.allocator, fd, 16, .{});
    fd_owned = false;
    defer pool.unreference();
    var buffer = try shm.Buffer.create(pool, 0, 2, 2, 8, @intFromEnum(shm.Format.argb8888));
    defer buffer.deinit();
    const copy = try AsyncShmCopy.create(
        std.testing.allocator,
        &loop,
        buffer,
        null,
        null,
        null,
        ignoreCompletion,
    );
    defer copy.deinit();
    try copy.start();
    try loop.run();
    try std.testing.expectError(error.ShortRead, copy.takeSnapshot());
}
