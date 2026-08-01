//! Native Wayring shared-memory buffers and damage-aware CPU snapshots.
//!
//! Protocol handlers own `Pool` and `Buffer` resources, while these values
//! only model descriptor ownership, validated geometry, and reads. The caller
//! supplies positional I/O so copying can be driven by the compositor's
//! io_uring without coupling protocol state to an event loop.

const std = @import("std");
const linux = std.os.linux;
const render = @import("../render/types.zig");

pub const Format = enum(u32) {
    argb8888 = 0,
    xrgb8888 = 1,
};

pub const Close = struct {
    context: ?*anyopaque = null,
    callback: *const fn (?*anyopaque, i32) void = closeFd,
};

pub const Reader = struct {
    context: *anyopaque,
    read: *const fn (*anyopaque, i32, u64, []u8) anyerror!void,
};

pub const Pool = struct {
    allocator: std.mem.Allocator,
    fd: i32,
    size: usize,
    references: usize = 1,
    close: Close,

    /// Takes ownership of `fd` on success.
    pub fn create(
        allocator: std.mem.Allocator,
        fd: i32,
        size: i32,
        close: Close,
    ) !*Pool {
        if (fd < 0 or size <= 0) return error.InvalidPool;
        const self = try allocator.create(Pool);
        self.* = .{
            .allocator = allocator,
            .fd = fd,
            .size = @intCast(size),
            .close = close,
        };
        return self;
    }

    pub fn reference(self: *Pool) !void {
        if (self.references == std.math.maxInt(usize)) return error.ReferenceOverflow;
        self.references += 1;
    }

    pub fn unreference(self: *Pool) void {
        std.debug.assert(self.references > 0);
        self.references -= 1;
        if (self.references != 0) return;
        self.close.callback(self.close.context, self.fd);
        self.allocator.destroy(self);
    }

    pub fn resize(self: *Pool, size: i32) !void {
        if (size <= 0) return error.InvalidPool;
        const new_size: usize = @intCast(size);
        if (new_size <= self.size) return error.InvalidPool;
        self.size = new_size;
    }
};

pub const Buffer = struct {
    pool: *Pool,
    offset: usize,
    width: u32,
    height: u32,
    stride: usize,
    format: Format,

    pub fn create(
        pool: *Pool,
        offset: i32,
        width: i32,
        height: i32,
        stride: i32,
        format_value: u32,
    ) !Buffer {
        if (offset < 0 or width <= 0 or height <= 0 or stride <= 0)
            return error.InvalidBuffer;
        const format: Format = switch (format_value) {
            @intFromEnum(Format.argb8888) => .argb8888,
            @intFromEnum(Format.xrgb8888) => .xrgb8888,
            else => return error.InvalidFormat,
        };
        const width_value: u32 = @intCast(width);
        const height_value: u32 = @intCast(height);
        const stride_value: usize = @intCast(stride);
        const row_bytes = std.math.mul(usize, width_value, @sizeOf(u32)) catch
            return error.InvalidBuffer;
        if (stride_value < row_bytes) return error.InvalidStride;
        const final_row = std.math.mul(usize, height_value - 1, stride_value) catch
            return error.InvalidBuffer;
        const byte_count = std.math.add(usize, final_row, row_bytes) catch
            return error.InvalidBuffer;
        const end = std.math.add(usize, @intCast(offset), byte_count) catch
            return error.InvalidBuffer;
        if (end > pool.size) return error.InvalidBuffer;
        try pool.reference();
        return .{
            .pool = pool,
            .offset = @intCast(offset),
            .width = width_value,
            .height = height_value,
            .stride = stride_value,
            .format = format,
        };
    }

    pub fn deinit(self: *Buffer) void {
        self.pool.unreference();
        self.* = undefined;
    }

    pub fn clone(self: Buffer) !Buffer {
        try self.pool.reference();
        return self;
    }

    pub fn size(self: Buffer) render.Size {
        return .{ .width = self.width, .height = self.height };
    }

    /// Copies all pixels, or only clipped `damage` when `reuse` has matching
    /// geometry. Every requested range must be read completely; a truncated
    /// or otherwise hostile backing file becomes an ordinary copy error and
    /// cannot raise SIGBUS in the compositor.
    pub fn copy(
        self: Buffer,
        allocator: std.mem.Allocator,
        reader: Reader,
        damage: ?[]const render.Rect,
        reuse: ?*Snapshot,
    ) !Snapshot {
        var plan = try CopyPlan.init(allocator, self, damage, reuse);
        defer plan.deinit();
        for (plan.reads) |range|
            try reader.read(reader.context, plan.buffer.pool.fd, range.offset, range.destination);
        return plan.finish();
    }
};

/// Owns a validated destination and the positional byte ranges needed to
/// produce one snapshot. Adapters may submit every range independently, but
/// must call `finish` only after each range was read in full.
pub const CopyPlan = struct {
    allocator: std.mem.Allocator,
    buffer: Buffer,
    pixels: []u32,
    source_damage: ?[]render.Rect,
    reads: []Read,
    finished: bool = false,

    pub const Read = struct {
        offset: u64,
        destination: []u8,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        buffer: Buffer,
        damage: ?[]const render.Rect,
        reuse: ?*Snapshot,
    ) !CopyPlan {
        const self = buffer;
        const pixel_count = std.math.mul(usize, self.width, self.height) catch
            return error.InvalidBuffer;
        const partial = reuse != null and damage != null and
            std.meta.eql(reuse.?.size, self.size()) and
            reuse.?.pixels.len == pixel_count and
            reuse.?.force_opaque == (self.format == .xrgb8888);
        const pixels = if (reuse) |snapshot|
            snapshot.takePixels(pixel_count) orelse try allocator.alloc(u32, pixel_count)
        else
            try allocator.alloc(u32, pixel_count);
        errdefer allocator.free(pixels);

        var source_damage: ?[]render.Rect = null;
        errdefer if (source_damage) |rectangles| allocator.free(rectangles);
        if (partial) source_damage = try clippedDamage(allocator, damage.?, self.size());

        const read_count: usize = if (partial) blk: {
            var count: usize = 0;
            for (source_damage.?) |rectangle|
                count = std.math.add(usize, count, rectangle.height) catch
                    return error.InvalidBuffer;
            break :blk count;
        } else self.height;
        const reads = try allocator.alloc(Read, read_count);
        errdefer allocator.free(reads);
        var index: usize = 0;
        if (partial) {
            for (source_damage.?) |rectangle| {
                index = try appendRectangleReads(self, pixels, rectangle, reads, index);
            }
        } else {
            index = try appendRectangleReads(self, pixels, .{
                .x = 0,
                .y = 0,
                .width = self.width,
                .height = self.height,
            }, reads, index);
        }
        std.debug.assert(index == reads.len);
        return .{
            .allocator = allocator,
            .buffer = try self.clone(),
            .pixels = pixels,
            .source_damage = source_damage,
            .reads = reads,
        };
    }

    pub fn deinit(self: *CopyPlan) void {
        self.buffer.deinit();
        self.allocator.free(self.reads);
        if (!self.finished) {
            self.allocator.free(self.pixels);
            if (self.source_damage) |damage| self.allocator.free(damage);
        }
        self.* = undefined;
    }

    pub fn finish(self: *CopyPlan) Snapshot {
        std.debug.assert(!self.finished);
        const buffer = self.buffer;
        const partial = self.source_damage != null;
        const pixels = self.pixels;
        if (buffer.format == .xrgb8888) {
            if (partial) {
                for (self.source_damage.?) |rectangle| forceOpaque(pixels, buffer.width, rectangle);
            } else {
                for (pixels) |*pixel| pixel.* |= 0xff000000;
            }
        }
        self.finished = true;
        return .{
            .allocator = self.allocator,
            .size = buffer.size(),
            .pixels = pixels,
            .force_opaque = buffer.format == .xrgb8888,
            .source_damage = self.source_damage,
        };
    }
};

fn appendRectangleReads(
    buffer: Buffer,
    pixels: []u32,
    rectangle: render.Rect,
    reads: []CopyPlan.Read,
    start_index: usize,
) !usize {
    std.debug.assert(rectangle.x >= 0 and rectangle.y >= 0);
    const x: usize = @intCast(rectangle.x);
    const y: usize = @intCast(rectangle.y);
    var index = start_index;
    for (0..rectangle.height) |row| {
        const source_row = std.math.mul(usize, y + row, buffer.stride) catch
            return error.InvalidBuffer;
        const source_offset = std.math.add(
            usize,
            buffer.offset,
            std.math.add(usize, source_row, x * @sizeOf(u32)) catch
                return error.InvalidBuffer,
        ) catch return error.InvalidBuffer;
        const destination_offset = (y + row) * buffer.width + x;
        reads[index] = .{
            .offset = source_offset,
            .destination = std.mem.sliceAsBytes(
                pixels[destination_offset..][0..rectangle.width],
            ),
        };
        index += 1;
    }
    return index;
}

pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    size: render.Size,
    pixels: []u32,
    force_opaque: bool,
    source_damage: ?[]render.Rect,

    pub fn deinit(self: *Snapshot) void {
        if (self.pixels.len != 0) self.allocator.free(self.pixels);
        if (self.source_damage) |damage| self.allocator.free(damage);
        self.* = undefined;
    }

    pub fn pixelBuffer(self: *Snapshot) render.PixelBuffer {
        return .{
            .size = self.size,
            .stride_pixels = self.size.width,
            .pixels = self.pixels,
            .source_damage = self.source_damage,
        };
    }

    fn takePixels(self: *Snapshot, pixel_count: usize) ?[]u32 {
        if (self.pixels.len != pixel_count) return null;
        const pixels = self.pixels;
        self.pixels = &.{};
        return pixels;
    }
};

fn clippedDamage(
    allocator: std.mem.Allocator,
    damage: []const render.Rect,
    size: render.Size,
) ![]render.Rect {
    var rectangles: std.ArrayList(render.Rect) = .empty;
    defer rectangles.deinit(allocator);
    for (damage) |rectangle| {
        const clipped = rectangle.clipTo(size) orelse continue;
        try rectangles.append(allocator, clipped);
    }
    return rectangles.toOwnedSlice(allocator);
}

fn forceOpaque(pixels: []u32, stride: u32, rectangle: render.Rect) void {
    const x: usize = @intCast(rectangle.x);
    const y: usize = @intCast(rectangle.y);
    for (0..rectangle.height) |row| {
        const offset = (y + row) * stride + x;
        for (pixels[offset..][0..rectangle.width]) |*pixel| pixel.* |= 0xff000000;
    }
}

fn closeFd(_: ?*anyopaque, fd: i32) void {
    _ = linux.close(fd);
}

test "pool remains alive until its buffers are destroyed" {
    const CloseContext = struct {
        calls: usize = 0,

        fn close(context: ?*anyopaque, _: i32) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
        }
    };
    var close_context: CloseContext = .{};
    const pool = try Pool.create(std.testing.allocator, 10, 64, .{
        .context = &close_context,
        .callback = CloseContext.close,
    });
    var buffer = try Buffer.create(pool, 0, 2, 2, 8, @intFromEnum(Format.argb8888));
    pool.unreference();
    try std.testing.expectEqual(@as(usize, 0), close_context.calls);
    buffer.deinit();
    try std.testing.expectEqual(@as(usize, 1), close_context.calls);
}

test "buffer geometry and pool growth are validated" {
    const CloseContext = struct {
        fn close(_: ?*anyopaque, _: i32) void {}
    };
    const pool = try Pool.create(std.testing.allocator, 10, 64, .{
        .callback = CloseContext.close,
    });
    defer pool.unreference();
    try std.testing.expectError(
        error.InvalidStride,
        Buffer.create(pool, 0, 4, 2, 12, @intFromEnum(Format.argb8888)),
    );
    try std.testing.expectError(
        error.InvalidBuffer,
        Buffer.create(pool, 60, 2, 1, 8, @intFromEnum(Format.argb8888)),
    );
    try std.testing.expectError(
        error.InvalidFormat,
        Buffer.create(pool, 0, 1, 1, 4, 99),
    );
    try std.testing.expectError(error.InvalidPool, pool.resize(64));
    try pool.resize(128);
    try std.testing.expectEqual(@as(usize, 128), pool.size);
}

test "copy updates only damaged pixels and reports source damage" {
    const ReadContext = struct {
        bytes: []const u8,
        calls: usize = 0,

        fn read(context: *anyopaque, _: i32, offset: u64, destination: []u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            const start: usize = @intCast(offset);
            if (start > self.bytes.len or destination.len > self.bytes.len - start)
                return error.ShortRead;
            @memcpy(destination, self.bytes[start..][0..destination.len]);
        }
    };
    const CloseContext = struct {
        fn close(_: ?*anyopaque, _: i32) void {}
    };
    var source = [_]u32{
        0x01020304, 0x11121314, 0x21222324,
        0x31323334, 0x41424344, 0x51525354,
    };
    var reader_context: ReadContext = .{ .bytes = std.mem.sliceAsBytes(&source) };
    const pool = try Pool.create(std.testing.allocator, 10, @sizeOf(@TypeOf(source)), .{
        .callback = CloseContext.close,
    });
    defer pool.unreference();
    var buffer = try Buffer.create(pool, 0, 3, 2, 12, @intFromEnum(Format.argb8888));
    defer buffer.deinit();
    var snapshot = try buffer.copy(std.testing.allocator, .{
        .context = &reader_context,
        .read = ReadContext.read,
    }, null, null);
    defer snapshot.deinit();
    try std.testing.expectEqualSlices(u32, &source, snapshot.pixels);

    source[1] = 0xaabbccdd;
    source[4] = 0xeeff0011;
    const damage = [_]render.Rect{.{ .x = 1, .y = 0, .width = 1, .height = 2 }};
    var updated = try buffer.copy(std.testing.allocator, .{
        .context = &reader_context,
        .read = ReadContext.read,
    }, &damage, &snapshot);
    defer updated.deinit();
    try std.testing.expectEqualSlices(u32, &source, updated.pixels);
    try std.testing.expectEqualSlices(render.Rect, &damage, updated.source_damage.?);
    try std.testing.expectEqual(@as(usize, 4), reader_context.calls);
}

test "short backing reads fail without memory mapping" {
    const ReadContext = struct {
        fn read(_: *anyopaque, _: i32, _: u64, _: []u8) !void {
            return error.ShortRead;
        }
    };
    const CloseContext = struct {
        fn close(_: ?*anyopaque, _: i32) void {}
    };
    var read_context: u8 = 0;
    const pool = try Pool.create(std.testing.allocator, 10, 16, .{
        .callback = CloseContext.close,
    });
    defer pool.unreference();
    var buffer = try Buffer.create(pool, 0, 2, 2, 8, @intFromEnum(Format.xrgb8888));
    defer buffer.deinit();
    try std.testing.expectError(error.ShortRead, buffer.copy(std.testing.allocator, .{
        .context = &read_context,
        .read = ReadContext.read,
    }, null, null));
}
