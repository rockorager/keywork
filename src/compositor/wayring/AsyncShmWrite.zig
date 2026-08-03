//! io_uring owner for one tight Wayring SHM buffer write.
//!
//! Source bytes are borrowed. The owner and source must remain live until the
//! terminal callback, including while cancellation is pending.

const AsyncShmWrite = @This();

const std = @import("std");
const linux = std.os.linux;
const IoUringLoop = @import("keywork-loop").IoUringLoop;
const shm = @import("shm.zig");

allocator: std.mem.Allocator,
loop: *IoUringLoop,
buffer: shm.Buffer,
bytes: []const u8,
written: usize = 0,
handle: ?IoUringLoop.Handle = null,
failure: ?anyerror = null,
started: bool = false,
terminal: bool = false,
notified: bool = false,
completion_context: ?*anyopaque,
completion_callback: CompletionCallback,

pub const CompletionCallback = *const fn (?*anyopaque, *AsyncShmWrite) void;

const Progress = enum { requeue, finished, failed };

pub fn create(
    allocator: std.mem.Allocator,
    loop: *IoUringLoop,
    buffer: shm.Buffer,
    bytes: []const u8,
    completion_context: ?*anyopaque,
    completion_callback: CompletionCallback,
) !*AsyncShmWrite {
    const row_bytes = std.math.mul(usize, buffer.width, @sizeOf(u32)) catch
        return error.InvalidBufferGeometry;
    if (buffer.stride != row_bytes) return error.InvalidBufferGeometry;
    const byte_count = std.math.mul(usize, buffer.height, buffer.stride) catch
        return error.InvalidBufferGeometry;
    const end = std.math.add(usize, buffer.offset, byte_count) catch
        return error.InvalidBufferGeometry;
    if (bytes.len != byte_count or end > buffer.pool.size)
        return error.InvalidBufferGeometry;

    const self = try allocator.create(AsyncShmWrite);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .loop = loop,
        .buffer = try buffer.clone(),
        .bytes = bytes,
        .completion_context = completion_context,
        .completion_callback = completion_callback,
    };
    return self;
}

pub fn start(self: *AsyncShmWrite) !void {
    if (self.started) return error.AlreadyStarted;
    self.started = true;
    self.queueTail() catch |err| {
        self.fail(err);
        self.finish();
        return err;
    };
}

/// Requests cancellation without suppressing the target's terminal callback.
pub fn cancel(self: *AsyncShmWrite) !void {
    if (!self.started or self.terminal) return;
    self.fail(error.Canceled);
    if (self.handle) |handle| try self.loop.cancel(handle);
}

pub fn isTerminal(self: *const AsyncShmWrite) bool {
    return self.terminal;
}

pub fn result(self: *const AsyncShmWrite) !void {
    if (!self.terminal) return error.NotComplete;
    if (self.failure) |err| return err;
}

pub fn deinit(self: *AsyncShmWrite) void {
    std.debug.assert(!self.started or self.terminal);
    self.buffer.deinit();
    const allocator = self.allocator;
    self.* = undefined;
    allocator.destroy(self);
}

fn prepare(context: *anyopaque, sqe: *linux.io_uring_sqe) void {
    const self: *AsyncShmWrite = @ptrCast(@alignCast(context));
    sqe.prep_write(
        self.buffer.pool.fd,
        self.bytes[self.written..],
        @intCast(self.buffer.offset + self.written),
    );
}

fn complete(
    context: *anyopaque,
    _: *IoUringLoop,
    completion: IoUringLoop.Completion,
) !void {
    const self: *AsyncShmWrite = @ptrCast(@alignCast(context));
    self.handle = null;
    switch (self.advance(completion.result)) {
        .requeue => self.queueTail() catch |err| {
            self.fail(err);
            self.finish();
        },
        .finished, .failed => self.finish(),
    }
}

fn queueTail(self: *AsyncShmWrite) !void {
    std.debug.assert(self.handle == null and self.written < self.bytes.len);
    self.handle = try self.loop.queue(self, complete, self, prepare);
}

fn advance(self: *AsyncShmWrite, completion_result: i32) Progress {
    if (completion_result < 0) {
        self.fail(error.WriteFailed);
        return .failed;
    }
    const count: usize = @intCast(completion_result);
    const remaining = self.bytes.len - self.written;
    if (count == 0 or count > remaining) {
        self.fail(error.ShortWrite);
        return .failed;
    }
    self.written += count;
    return if (self.written == self.bytes.len) .finished else .requeue;
}

fn fail(self: *AsyncShmWrite, err: anyerror) void {
    if (self.failure == null) self.failure = err;
}

fn finish(self: *AsyncShmWrite) void {
    std.debug.assert(self.handle == null);
    if (self.terminal) return;
    self.terminal = true;
    if (!self.notified) {
        self.notified = true;
        self.completion_callback(self.completion_context, self);
    }
}

fn ignoreCompletion(_: ?*anyopaque, _: *AsyncShmWrite) void {}

fn testBuffer(fd: i32, size: i32) !struct { pool: *shm.Pool, buffer: shm.Buffer } {
    const pool = try shm.Pool.create(std.testing.allocator, fd, size, .{});
    errdefer pool.unreference();
    return .{
        .pool = pool,
        .buffer = try shm.Buffer.create(pool, 0, 2, 2, 8, @intFromEnum(shm.Format.argb8888)),
    };
}

test "writes the complete tight buffer" {
    var loop = try IoUringLoop.init(std.testing.allocator);
    defer loop.deinit();
    const fd = try std.posix.memfd_create("async-shm-write", linux.MFD.CLOEXEC);
    var destination = try testBuffer(fd, 16);
    defer destination.pool.unreference();
    defer destination.buffer.deinit();
    const source = [_]u32{ 1, 2, 3, 4 };
    const write = try AsyncShmWrite.create(std.testing.allocator, &loop, destination.buffer, std.mem.sliceAsBytes(&source), null, ignoreCompletion);
    defer write.deinit();
    try write.start();
    try loop.run();
    try write.result();
    var actual: [16]u8 = undefined;
    const count = linux.pread(fd, &actual, actual.len, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(count));
    try std.testing.expectEqual(source.len * @sizeOf(u32), count);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&source), &actual);
}

test "partial completions advance the unwritten tail" {
    var owner: AsyncShmWrite = undefined;
    owner.bytes = "abcdefgh";
    owner.written = 0;
    owner.failure = null;
    try std.testing.expectEqual(Progress.requeue, owner.advance(3));
    try std.testing.expectEqual(@as(usize, 3), owner.written);
    try std.testing.expectEqual(Progress.finished, owner.advance(5));
}

test "cancel preserves callback delivery until terminal completion" {
    const Counter = struct {
        fn complete(context: ?*anyopaque, _: *AsyncShmWrite) void {
            const count: *usize = @ptrCast(@alignCast(context.?));
            count.* += 1;
        }
    };
    var loop = try IoUringLoop.init(std.testing.allocator);
    defer loop.deinit();
    const fd = try std.posix.memfd_create("async-shm-cancel", linux.MFD.CLOEXEC);
    var destination = try testBuffer(fd, 16);
    defer destination.pool.unreference();
    defer destination.buffer.deinit();
    const source = [_]u32{ 1, 2, 3, 4 };
    var callbacks: usize = 0;
    const write = try AsyncShmWrite.create(std.testing.allocator, &loop, destination.buffer, std.mem.sliceAsBytes(&source), &callbacks, Counter.complete);
    defer write.deinit();
    try write.start();
    try write.cancel();
    try loop.run();
    try std.testing.expect(write.isTerminal());
    try std.testing.expectEqual(@as(usize, 1), callbacks);
    try std.testing.expectError(error.Canceled, write.result());
}

test "rejects invalid source geometry" {
    var loop = try IoUringLoop.init(std.testing.allocator);
    defer loop.deinit();
    const fd = try std.posix.memfd_create("async-shm-invalid", linux.MFD.CLOEXEC);
    var destination = try testBuffer(fd, 16);
    defer destination.pool.unreference();
    defer destination.buffer.deinit();
    try std.testing.expectError(error.InvalidBufferGeometry, AsyncShmWrite.create(std.testing.allocator, &loop, destination.buffer, "short", null, ignoreCompletion));
    destination.buffer.stride = 12;
    try std.testing.expectError(error.InvalidBufferGeometry, AsyncShmWrite.create(std.testing.allocator, &loop, destination.buffer, &([_]u8{0} ** 24), null, ignoreCompletion));
}

test "sealed destination fails without accessing mapped memory" {
    var loop = try IoUringLoop.init(std.testing.allocator);
    defer loop.deinit();
    const fd = try std.posix.memfd_create("async-shm-sealed", linux.MFD.CLOEXEC | linux.MFD.ALLOW_SEALING);
    var destination = try testBuffer(fd, 16);
    defer destination.pool.unreference();
    defer destination.buffer.deinit();
    const seal_result = linux.fcntl(fd, linux.F.ADD_SEALS, linux.F.SEAL_WRITE);
    if (linux.errno(seal_result) != .SUCCESS) return error.SealFailed;
    const source = [_]u32{ 1, 2, 3, 4 };
    const write = try AsyncShmWrite.create(std.testing.allocator, &loop, destination.buffer, std.mem.sliceAsBytes(&source), null, ignoreCompletion);
    defer write.deinit();
    try write.start();
    try loop.run();
    try std.testing.expectError(error.WriteFailed, write.result());
}
