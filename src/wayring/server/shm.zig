//! Protocol-independent storage for the standard Wayland shared-memory model.
//!
//! This module owns descriptors and mappings, but not protocol resources or
//! events. Access is intentionally mediated by `Buffer.Access`. A backing file
//! truncated after it is mapped is guarded while an Access is active. The
//! process-global SIGBUS handler is installed once and coexists conservatively:
//! another subsystem replacing it afterward disables this protection, while an
//! unrelated SIGBUS restores and redelivers to the action captured at install.
//! The fault-recovery model follows the MIT-licensed Wayland 1.26 reference;
//! its provenance and license notice are recorded in `licenses/wayland.txt`.
//!
//! Pool and buffer state is externally serialized. Pins are owning lifetime
//! references and may cross threads only under host synchronization. An Access
//! and every borrowed copy of its byte slice remain on one thread and become
//! invalid when `end` consumes the guard. Owning Pin and Access values must not
//! be copied.

const std = @import("std");
const linux = std.os.linux;

var handler_mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER;
var handler_installed = false;
var previous_sigbus: linux.Sigaction = .{
    .handler = .{ .handler = std.posix.SIG.DFL },
    .mask = std.mem.zeroes(linux.sigset_t),
    .flags = 0,
};

threadlocal var active_pool_address: std.atomic.Value(usize) = .init(0);
threadlocal var access_depth: usize = 0;
threadlocal var backing_faulted: std.atomic.Value(bool) = .init(false);

fn ensureHandler() error{SignalSetupFailed}!void {
    std.debug.assert(std.c.pthread_mutex_lock(&handler_mutex) == .SUCCESS);
    defer std.debug.assert(std.c.pthread_mutex_unlock(&handler_mutex) == .SUCCESS);
    if (handler_installed) return;

    const action: linux.Sigaction = .{
        .handler = .{ .sigaction = handleSigbus },
        .mask = std.mem.zeroes(linux.sigset_t),
        .flags = linux.SA.SIGINFO | linux.SA.NODEFER,
    };
    var old_action: linux.Sigaction = undefined;
    if (linux.errno(linux.sigaction(.BUS, null, &old_action)) != .SUCCESS)
        return error.SignalSetupFailed;
    previous_sigbus = old_action;
    if (linux.errno(linux.sigaction(.BUS, &action, null)) != .SUCCESS)
        return error.SignalSetupFailed;
    handler_installed = true;
}

fn handleSigbus(_: linux.SIG, info: *const linux.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    const pool_address = active_pool_address.load(.acquire);
    if (pool_address != 0) {
        const pool: *Pool = @ptrFromInt(pool_address);
        const address = @intFromPtr(info.fields.sigfault.addr);
        const start = @intFromPtr(pool.mapping.ptr);
        const end = std.math.add(usize, start, pool.mapping.len) catch 0;
        if (end != 0 and address >= start and address < end) {
            backing_faulted.store(true, .release);
            const result = linux.mmap(pool.mapping.ptr, pool.mapping.len, .{ .READ = true, .WRITE = true }, .{
                .TYPE = .PRIVATE,
                .FIXED = true,
                .ANONYMOUS = true,
            }, -1, 0);
            if (linux.errno(result) == .SUCCESS and result == start) return;
        }
    }

    // The handler cannot safely interpret this fault. Restore process state
    // and ask the kernel to deliver it again to this exact thread.
    _ = linux.sigaction(.BUS, &previous_sigbus, null);
    _ = linux.tkill(linux.gettid(), .BUS);
}

pub const Format = enum(u32) {
    argb8888 = 0,
    xrgb8888 = 1,

    pub fn fromRaw(raw: u32) error{UnsupportedFormat}!Format {
        return switch (raw) {
            0 => .argb8888,
            1 => .xrgb8888,
            else => error.UnsupportedFormat,
        };
    }
};

pub const Geometry = struct {
    offset: usize,
    width: usize,
    height: usize,
    stride: usize,
    format: Format,
    byte_len: usize,
};

pub const Pool = struct {
    allocator: std.mem.Allocator,
    fd: std.posix.fd_t,
    mapping: []align(std.heap.page_size_min) u8,
    logical_size: usize,
    refs: usize = 1,
    stability_refs: usize = 0,
    pending_mapping: ?[]align(std.heap.page_size_min) u8 = null,
    resource_live: bool = true,
    invalid_backing: bool = false,

    /// On success the pool adopts `fd`. On every error the caller retains it.
    /// `size` must be positive and the backing file must already be at least
    /// that large. Final release unmaps the storage and closes the descriptor.
    pub fn create(allocator: std.mem.Allocator, fd: std.posix.fd_t, size: i64) !*Pool {
        if (size <= 0) return error.InvalidPoolSize;
        const map_size: usize = std.math.cast(usize, size) orelse return error.InvalidPoolSize;
        try requireFileSize(fd, map_size);
        const mapping = try std.posix.mmap(null, map_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
        errdefer std.posix.munmap(mapping);
        const self = try allocator.create(Pool);
        self.* = .{ .allocator = allocator, .fd = fd, .mapping = mapping, .logical_size = map_size };
        return self;
    }

    pub fn dropResource(self: *Pool) void {
        std.debug.assert(self.resource_live);
        self.resource_live = false;
        self.release();
    }

    pub fn createBuffer(self: *Pool, offset: i64, width: i64, height: i64, stride: i64, raw_format: u32) !*Buffer {
        const geometry = try validateGeometry(self.logical_size, offset, width, height, stride, raw_format);
        const buffer = try self.allocator.create(Buffer);
        self.retain();
        buffer.* = .{ .pool = self, .geometry = geometry };
        return buffer;
    }

    /// Requests a grow-only logical size. The file must already be large
    /// enough. With stable pointers outstanding, remapping is deferred until
    /// the final Access ends; new buffers may be described meanwhile,
    /// but Access returns `ResizePending` if their bytes are not mapped yet.
    pub fn resize(self: *Pool, new_size_value: i64) !void {
        if (new_size_value <= 0) return error.InvalidPoolSize;
        const new_size: usize = std.math.cast(usize, new_size_value) orelse return error.InvalidPoolSize;
        if (new_size <= self.logical_size) return error.NotGrowing;
        try requireFileSize(self.fd, new_size);
        const replacement = try self.map(new_size);
        self.logical_size = new_size;
        if (self.stability_refs != 0) {
            if (self.pending_mapping) |pending| std.posix.munmap(pending);
            self.pending_mapping = replacement;
            return;
        }
        self.installMapping(replacement);
    }

    pub fn mappedSize(self: *const Pool) usize {
        return self.mapping.len;
    }

    pub fn logicalSize(self: *const Pool) usize {
        return self.logical_size;
    }

    fn map(self: *Pool, size: usize) ![]align(std.heap.page_size_min) u8 {
        return std.posix.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, self.fd, 0);
    }

    fn installMapping(self: *Pool, replacement: []align(std.heap.page_size_min) u8) void {
        std.posix.munmap(self.mapping);
        self.mapping = replacement;
        self.pending_mapping = null;
    }

    fn retain(self: *Pool) void {
        std.debug.assert(self.refs != std.math.maxInt(usize));
        self.refs += 1;
    }

    fn release(self: *Pool) void {
        std.debug.assert(self.refs > 0);
        self.refs -= 1;
        if (self.refs != 0) return;
        std.debug.assert(self.stability_refs == 0);
        std.posix.munmap(self.mapping);
        _ = std.c.close(self.fd);
        self.allocator.destroy(self);
    }

    fn acquireStability(self: *Pool) void {
        self.stability_refs += 1;
    }

    fn releaseStability(self: *Pool) void {
        std.debug.assert(self.stability_refs > 0);
        self.stability_refs -= 1;
        if (self.stability_refs == 0) {
            if (self.pending_mapping) |replacement| self.installMapping(replacement);
        }
    }
};

pub const Buffer = struct {
    pool: *Pool,
    geometry: Geometry,
    refs: usize = 1,
    resource_live: bool = true,

    pub const Pin = struct {
        buffer: ?*Buffer,

        /// Begins scoped access after the protocol resource has been
        /// destroyed. The pin must remain live until the returned guard ends.
        pub fn access(self: *Pin) AccessError!Access {
            const buffer = self.buffer orelse @panic("Buffer.Pin used after deinit");
            return buffer.beginAccess();
        }

        pub fn deinit(self: *Pin) void {
            const buffer = self.buffer orelse @panic("Buffer.Pin deinitialized twice");
            self.buffer = null;
            buffer.release();
        }
    };

    pub const Access = struct {
        buffer: ?*Buffer,
        bytes: []u8,
        geometry: Geometry,

        /// Ends access and invalidates `bytes`. A guarded fault is reported
        /// only after releasing all owned state, allowing a protocol wrapper
        /// to post the client error.
        pub fn end(self: *Access) error{InvalidBacking}!void {
            const buffer = self.buffer orelse @panic("Buffer.Access deinitialized twice");
            std.debug.assert(active_pool_address.load(.acquire) == @intFromPtr(buffer.pool) and access_depth > 0);
            access_depth -= 1;
            const outermost = access_depth == 0;
            var faulted = false;
            if (outermost) {
                // The sequentially consistent RMWs delimit all mapped access
                // before retiring the handler context and sampling its mark.
                _ = active_pool_address.swap(0, .seq_cst);
                faulted = backing_faulted.swap(false, .seq_cst);
                if (faulted) buffer.pool.invalid_backing = true;
            }
            self.buffer = null;
            self.bytes = &.{};
            buffer.pool.releaseStability();
            buffer.release();
            if (faulted) return error.InvalidBacking;
        }
    };

    pub fn dropResource(self: *Buffer) void {
        std.debug.assert(self.resource_live);
        self.resource_live = false;
        self.release();
    }

    pub fn pin(self: *Buffer) Pin {
        self.retain();
        return .{ .buffer = self };
    }

    pub const AccessError = error{ ResizePending, AccessConflict, InvalidBacking, SignalSetupFailed };

    pub fn access(self: *Buffer) AccessError!Access {
        return self.beginAccess();
    }

    fn beginAccess(self: *Buffer) AccessError!Access {
        if (self.pool.invalid_backing) return error.InvalidBacking;
        const pool_address = active_pool_address.load(.acquire);
        if (pool_address != 0) {
            const pool: *Pool = @ptrFromInt(pool_address);
            if (pool != self.pool) return error.AccessConflict;
        } else {
            try ensureHandler();
        }
        const end = self.geometry.offset + self.geometry.byte_len;
        if (end > self.pool.mapping.len) return error.ResizePending;
        self.retain();
        self.pool.acquireStability();
        if (pool_address == 0) {
            backing_faulted.store(false, .seq_cst);
            // Publish the handler context before callers can touch bytes.
            _ = active_pool_address.swap(@intFromPtr(self.pool), .seq_cst);
        }
        access_depth += 1;
        return .{
            .buffer = self,
            .bytes = self.pool.mapping[self.geometry.offset..end],
            .geometry = self.geometry,
        };
    }

    fn retain(self: *Buffer) void {
        std.debug.assert(self.refs != std.math.maxInt(usize));
        self.refs += 1;
    }

    fn release(self: *Buffer) void {
        std.debug.assert(self.refs > 0);
        self.refs -= 1;
        if (self.refs != 0) return;
        const pool = self.pool;
        pool.allocator.destroy(self);
        pool.release();
    }
};

pub fn validateGeometry(pool_size: usize, offset_value: i64, width_value: i64, height_value: i64, stride_value: i64, raw_format: u32) !Geometry {
    const format = try Format.fromRaw(raw_format);
    if (offset_value < 0 or width_value <= 0 or height_value <= 0 or stride_value <= 0) return error.InvalidGeometry;
    const offset = std.math.cast(usize, offset_value) orelse return error.InvalidGeometry;
    const width = std.math.cast(usize, width_value) orelse return error.InvalidGeometry;
    const height = std.math.cast(usize, height_value) orelse return error.InvalidGeometry;
    const stride = std.math.cast(usize, stride_value) orelse return error.InvalidGeometry;
    const row_bytes = std.math.mul(usize, width, 4) catch return error.InvalidGeometry;
    if (stride < row_bytes) return error.InvalidGeometry;
    const preceding_rows = std.math.mul(usize, height - 1, stride) catch return error.InvalidGeometry;
    const byte_len = std.math.add(usize, preceding_rows, row_bytes) catch return error.InvalidGeometry;
    const end = std.math.add(usize, offset, byte_len) catch return error.InvalidGeometry;
    if (end > pool_size) return error.OutOfBounds;
    return .{ .offset = offset, .width = width, .height = height, .stride = stride, .format = format, .byte_len = byte_len };
}

fn requireFileSize(fd: std.posix.fd_t, required: usize) !void {
    var stat: std.os.linux.Statx = undefined;
    const result = std.os.linux.statx(fd, "", std.os.linux.AT.EMPTY_PATH, .{ .SIZE = true }, &stat);
    if (std.os.linux.errno(result) != .SUCCESS) return error.StatFailed;
    if (stat.size < required) return error.BackingFileTooSmall;
}

fn testFd(size: usize) !std.posix.fd_t {
    const fd = try std.posix.memfd_create("wayring-shm-test", std.os.linux.MFD.CLOEXEC);
    errdefer _ = std.c.close(fd);
    if (std.os.linux.errno(std.os.linux.ftruncate(fd, @intCast(size))) != .SUCCESS) return error.Unexpected;
    return fd;
}

test "formats and geometry are checked without packed-stride restriction" {
    try std.testing.expectEqual(Format.argb8888, try Format.fromRaw(0));
    try std.testing.expectEqual(Format.xrgb8888, try Format.fromRaw(1));
    try std.testing.expectError(error.UnsupportedFormat, Format.fromRaw(2));
    try std.testing.expectError(error.InvalidGeometry, validateGeometry(64, -1, 1, 1, 4, 0));
    try std.testing.expectError(error.InvalidGeometry, validateGeometry(64, 0, 0, 1, 4, 0));
    try std.testing.expectError(error.InvalidGeometry, validateGeometry(64, 0, 2, 1, 7, 0));
    try std.testing.expectError(error.InvalidGeometry, validateGeometry(std.math.maxInt(usize), 0, std.math.maxInt(i64), 2, std.math.maxInt(i64), 0));
    try std.testing.expectError(error.OutOfBounds, validateGeometry(15, 0, 2, 2, 8, 0));
    const padded = try validateGeometry(20, 0, 2, 2, 12, 1);
    try std.testing.expectEqual(@as(usize, 20), padded.byte_len);
}

test "pool and buffer resources are independent from buffers and guards" {
    const fd = try testFd(64);
    const pool = try Pool.create(std.testing.allocator, fd, 64);
    const buffer = try pool.createBuffer(0, 2, 2, 12, 0);
    var pin = buffer.pin();
    pool.dropResource();
    buffer.dropResource();
    var access = try pin.access();
    access.bytes[0] = 42;
    try std.testing.expectEqual(@as(u8, 42), access.bytes[0]);
    try access.end();
    pin.deinit();
    try std.testing.expect(std.c.fcntl(fd, std.c.F.GETFD) < 0);
}

test "resize is immediate or deferred until final stable guard" {
    const fd = try testFd(256);
    const pool = try Pool.create(std.testing.allocator, fd, 32);
    try pool.resize(64);
    try std.testing.expectEqual(@as(usize, 64), pool.mappedSize());
    const old = try pool.createBuffer(0, 1, 1, 4, 0);
    var access = try old.access();
    access.bytes[0] = 91;
    try pool.resize(128);
    try std.testing.expectEqual(@as(usize, 64), pool.mappedSize());
    const future = try pool.createBuffer(96, 1, 1, 4, 0);
    var future_pin = future.pin();
    future.dropResource();
    try std.testing.expectError(error.ResizePending, future_pin.access());
    try std.testing.expectEqual(@as(usize, 64), pool.mappedSize());
    try access.end();
    try std.testing.expectEqual(@as(usize, 128), pool.mappedSize());
    var old_access = try old.access();
    try std.testing.expectEqual(@as(u8, 91), old_access.bytes[0]);
    try old_access.end();
    var future_access = try future_pin.access();
    try future_access.end();
    future_pin.deinit();
    old.dropResource();
    pool.dropResource();
}

test "latest deferred resize wins while an old access remains stable" {
    const fd = try testFd(256);
    const pool = try Pool.create(std.testing.allocator, fd, 32);
    const buffer = try pool.createBuffer(0, 1, 1, 4, 1);
    var access = try buffer.access();
    const old_pointer = access.bytes.ptr;
    access.bytes[0] = 17;
    try pool.resize(64);
    try pool.resize(128);
    try std.testing.expectEqual(@as(usize, 32), pool.mappedSize());
    try std.testing.expectEqual(old_pointer, access.bytes.ptr);
    try std.testing.expectEqual(@as(u8, 17), access.bytes[0]);
    try std.testing.expectError(error.BackingFileTooSmall, pool.resize(512));
    try std.testing.expectEqual(@as(usize, 128), pool.logicalSize());
    try access.end();
    try std.testing.expectEqual(@as(usize, 128), pool.mappedSize());
    var replacement_access = try buffer.access();
    try std.testing.expectEqual(@as(u8, 17), replacement_access.bytes[0]);
    try replacement_access.end();
    buffer.dropResource();
    pool.dropResource();
}

test "truncated backing is replaced and invalidates future access" {
    const page_size = std.heap.page_size_min;
    const pool_size = page_size * 3;
    const fd = try testFd(pool_size);
    const pool = try Pool.create(std.testing.allocator, fd, @intCast(pool_size));
    const buffer = try pool.createBuffer(0, 1, 3, @intCast(page_size), 0);
    var access = try buffer.access();
    const original_pointer = access.bytes.ptr;
    const first: *volatile u8 = @ptrCast(&access.bytes[0]);
    first.* = 23;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.ftruncate(fd, @intCast(page_size))));
    const faulting: *volatile u8 = @ptrCast(&access.bytes[page_size]);
    faulting.* = 42;
    try std.testing.expectEqual(original_pointer, access.bytes.ptr);
    try std.testing.expectEqual(@as(u8, 0), first.*);
    try std.testing.expectEqual(@as(u8, 42), faulting.*);
    try std.testing.expectError(error.InvalidBacking, access.end());
    try std.testing.expectError(error.InvalidBacking, buffer.access());
    buffer.dropResource();
    pool.dropResource();
}

test "nested guards defer backing failure until the outermost end" {
    const fd = try testFd(64);
    const pool = try Pool.create(std.testing.allocator, fd, 64);
    const buffer = try pool.createBuffer(0, 1, 1, 4, 0);
    var outer = try buffer.access();
    var inner = try buffer.access();
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.ftruncate(fd, 0)));
    inner.bytes[0] = 1;
    try inner.end();
    try std.testing.expectError(error.InvalidBacking, outer.end());
    buffer.dropResource();
    pool.dropResource();
}

test "nested access to another pool conflicts without disturbing guards" {
    const first_fd = try testFd(64);
    const first_pool = try Pool.create(std.testing.allocator, first_fd, 64);
    const first = try first_pool.createBuffer(0, 1, 1, 4, 0);
    const second_fd = try testFd(64);
    const second_pool = try Pool.create(std.testing.allocator, second_fd, 64);
    const second = try second_pool.createBuffer(0, 1, 1, 4, 0);

    var first_access = try first.access();
    try std.testing.expectError(error.AccessConflict, second.access());
    first_access.bytes[0] = 7;
    try first_access.end();
    var second_access = try second.access();
    second_access.bytes[0] = 9;
    try second_access.end();

    first.dropResource();
    first_pool.dropResource();
    second.dropResource();
    second_pool.dropResource();
}

test "guard state is isolated between threads accessing different pools" {
    const Context = struct {
        ready: *std.atomic.Value(u32),
        buffer: *Buffer,
        fd: std.posix.fd_t,
        recovered: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            var access = self.buffer.access() catch return;
            _ = self.ready.fetchAdd(1, .acq_rel);
            while (self.ready.load(.acquire) != 2) std.atomic.spinLoopHint();
            if (linux.errno(linux.ftruncate(self.fd, 0)) != .SUCCESS) return;
            const faulting: *volatile u8 = @ptrCast(&access.bytes[0]);
            faulting.* = 1;
            access.end() catch |err| {
                if (err == error.InvalidBacking) self.recovered.store(true, .release);
                return;
            };
        }
    };

    const first_fd = try testFd(std.heap.page_size_min);
    const first_pool = try Pool.create(std.testing.allocator, first_fd, std.heap.page_size_min);
    const first = try first_pool.createBuffer(0, 1, 1, 4, 0);
    const second_fd = try testFd(std.heap.page_size_min);
    const second_pool = try Pool.create(std.testing.allocator, second_fd, std.heap.page_size_min);
    const second = try second_pool.createBuffer(0, 1, 1, 4, 0);
    var ready: std.atomic.Value(u32) = .init(0);
    var first_context: Context = .{ .ready = &ready, .buffer = first, .fd = first_fd };
    var second_context: Context = .{ .ready = &ready, .buffer = second, .fd = second_fd };
    const first_thread = try std.Thread.spawn(.{}, Context.run, .{&first_context});
    const second_thread = try std.Thread.spawn(.{}, Context.run, .{&second_context});
    first_thread.join();
    second_thread.join();
    try std.testing.expect(first_context.recovered.load(.acquire));
    try std.testing.expect(second_context.recovered.load(.acquire));

    first.dropResource();
    first_pool.dropResource();
    second.dropResource();
    second_pool.dropResource();
}

test "initial undersized file is rejected without adopting fd" {
    const fd = try testFd(8);
    defer _ = std.c.close(fd);
    try std.testing.expectError(error.BackingFileTooSmall, Pool.create(std.testing.allocator, fd, 16));
    try requireFileSize(fd, 8);
}

test "pool allocation failure unmaps storage and leaves fd with caller" {
    const fd = try testFd(8);
    defer _ = std.c.close(fd);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, Pool.create(failing.allocator(), fd, 8));
    try requireFileSize(fd, 8);
}
