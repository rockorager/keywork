//! Protocol-neutral owned copy of a shared-memory surface buffer.

const CopiedBufferSnapshot = @This();

const std = @import("std");
const render = @import("../render/types.zig");
const Region = @import("../region.zig");

pub const Format = enum { argb8888, xrgb8888 };

pub const Source = struct {
    bytes: []const u8,
    size: render.Size,
    stride_bytes: usize,
    format: Format,
};

pub const Error = error{ OutOfMemory, InvalidBuffer };

allocator: std.mem.Allocator,
size: render.Size,
format: Format,
pixels: []u32,
source_cache: render.SourceCache,
source_damage: ?[]const render.Rect,

pub fn copy(
    allocator: std.mem.Allocator,
    source: Source,
    reusable: ?*CopiedBufferSnapshot,
    damage: ?*const Region,
    source_cache: render.SourceCache,
) Error!CopiedBufferSnapshot {
    const row_bytes = std.math.mul(usize, source.size.width, @sizeOf(u32)) catch
        return error.InvalidBuffer;
    if (source.size.width == 0 or source.size.height == 0 or source.stride_bytes < row_bytes)
        return error.InvalidBuffer;
    const preceding_rows = std.math.mul(usize, source.size.height - 1, source.stride_bytes) catch
        return error.InvalidBuffer;
    const required_bytes = std.math.add(usize, preceding_rows, row_bytes) catch
        return error.InvalidBuffer;
    if (source.bytes.len < required_bytes) return error.InvalidBuffer;
    const pixel_count = source.size.pixelCount() catch return error.InvalidBuffer;

    const compatible = if (reusable) |snapshot|
        sameAllocator(snapshot.allocator, allocator) and
            snapshot.pixels.len == pixel_count and
            std.meta.eql(snapshot.size, source.size) and
            snapshot.format == source.format and
            snapshot.source_cache.id == source_cache.id
    else
        false;
    const effective_damage = if (compatible) damage else null;
    const source_damage = if (effective_damage) |region|
        try copyDamage(allocator, region, source.size)
    else
        null;
    errdefer if (source_damage) |owned| if (owned.len > 0) allocator.free(owned);

    const pixels = if (compatible)
        reusable.?.takePixels()
    else
        allocator.alloc(u32, pixel_count) catch return error.OutOfMemory;
    copyPixels(pixels, source, effective_damage);
    return .{
        .allocator = allocator,
        .size = source.size,
        .format = source.format,
        .pixels = pixels,
        .source_cache = source_cache,
        .source_damage = source_damage,
    };
}

fn sameAllocator(a: std.mem.Allocator, b: std.mem.Allocator) bool {
    return a.ptr == b.ptr and a.vtable == b.vtable;
}

pub fn deinit(self: *CopiedBufferSnapshot) void {
    if (self.pixels.len > 0) self.allocator.free(self.pixels);
    if (self.source_damage) |damage| if (damage.len > 0) self.allocator.free(damage);
    self.* = undefined;
}

pub fn forceOpaque(self: *const CopiedBufferSnapshot) bool {
    return self.format == .xrgb8888;
}

pub fn pixelBuffer(
    self: *CopiedBufferSnapshot,
    color_description: render.ColorDescription,
    color_representation: render.ColorRepresentation,
) render.PixelBuffer {
    return .{
        .size = self.size,
        .stride_pixels = self.size.width,
        .pixels = self.pixels,
        .color_description = color_description,
        .color_representation = color_representation,
        .source_cache = self.source_cache,
        .source_damage = self.source_damage,
    };
}

fn takePixels(self: *CopiedBufferSnapshot) []u32 {
    const pixels = self.pixels;
    self.pixels = &.{};
    return pixels;
}

fn copyDamage(
    allocator: std.mem.Allocator,
    damage: *const Region,
    size: render.Size,
) error{OutOfMemory}![]const render.Rect {
    var rectangles: std.ArrayList(render.Rect) = .empty;
    defer rectangles.deinit(allocator);
    var iterator = damage.rectangleIterator();
    while (iterator.next()) |rectangle| {
        const clipped = (render.Rect{
            .x = rectangle.x,
            .y = rectangle.y,
            .width = rectangle.width,
            .height = rectangle.height,
        }).clipTo(size) orelse continue;
        rectangles.append(allocator, clipped) catch return error.OutOfMemory;
    }
    return rectangles.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn copyPixels(destination: []u32, source: Source, damage: ?*const Region) void {
    if (damage) |region| {
        var rectangles = region.rectangleIterator();
        while (rectangles.next()) |rectangle| {
            const clipped = (render.Rect{
                .x = rectangle.x,
                .y = rectangle.y,
                .width = rectangle.width,
                .height = rectangle.height,
            }).clipTo(source.size) orelse continue;
            copyRectangle(destination, source, clipped);
        }
        return;
    }
    copyRectangle(destination, source, .{
        .x = 0,
        .y = 0,
        .width = source.size.width,
        .height = source.size.height,
    });
}

fn copyRectangle(destination: []u32, source: Source, rectangle: render.Rect) void {
    std.debug.assert(rectangle.x >= 0 and rectangle.y >= 0);
    const x: usize = @intCast(rectangle.x);
    const y: usize = @intCast(rectangle.y);
    const copy_bytes = @as(usize, rectangle.width) * @sizeOf(u32);
    for (0..rectangle.height) |row| {
        const source_offset = (y + row) * source.stride_bytes + x * @sizeOf(u32);
        const destination_offset = (y + row) * source.size.width + x;
        @memcpy(
            std.mem.sliceAsBytes(destination[destination_offset..][0..rectangle.width]),
            source.bytes[source_offset..][0..copy_bytes],
        );
        if (source.format == .xrgb8888) {
            for (destination[destination_offset..][0..rectangle.width]) |*pixel| pixel.* |= 0xff00_0000;
        }
    }
}

test "copy normalizes padded XRGB and preserves ARGB alpha" {
    const xrgb = [_]u32{ 0x0011_2233, 0x0044_5566, 0xdead_beef, 0x0077_8899, 0x00aa_bbcc, 0xdead_beef };
    var xrgb_snapshot = try copy(std.testing.allocator, .{
        .bytes = std.mem.sliceAsBytes(&xrgb),
        .size = .{ .width = 2, .height = 2 },
        .stride_bytes = 3 * @sizeOf(u32),
        .format = .xrgb8888,
    }, null, null, .{ .id = 1, .version = 1 });
    defer xrgb_snapshot.deinit();
    try std.testing.expectEqualSlices(u32, &.{ 0xff11_2233, 0xff44_5566, 0xff77_8899, 0xffaa_bbcc }, xrgb_snapshot.pixels);

    const argb = [_]u32{0x8011_2233};
    var argb_snapshot = try copy(std.testing.allocator, .{
        .bytes = std.mem.sliceAsBytes(&argb),
        .size = .{ .width = 1, .height = 1 },
        .stride_bytes = @sizeOf(u32),
        .format = .argb8888,
    }, null, null, .{ .id = 2, .version = 1 });
    defer argb_snapshot.deinit();
    try std.testing.expectEqual(@as(u32, 0x8011_2233), argb_snapshot.pixels[0]);
}

test "compatible partial copy clips damage and reuses storage" {
    const initial = [_]u32{ 1, 2, 3, 4, 5, 6 };
    var first = try copy(std.testing.allocator, .{
        .bytes = std.mem.sliceAsBytes(&initial),
        .size = .{ .width = 3, .height = 2 },
        .stride_bytes = 3 * @sizeOf(u32),
        .format = .argb8888,
    }, null, null, .{ .id = 1, .version = 1 });
    defer first.deinit();
    const original_pointer = first.pixels.ptr;
    const updated = [_]u32{ 10, 20, 30, 40, 50, 60 };
    var damage = Region.init();
    defer damage.deinit();
    try damage.add(1, -1, 1, 4);
    var second = try copy(std.testing.allocator, .{
        .bytes = std.mem.sliceAsBytes(&updated),
        .size = .{ .width = 3, .height = 2 },
        .stride_bytes = 3 * @sizeOf(u32),
        .format = .argb8888,
    }, &first, &damage, .{ .id = 1, .version = 2 });
    defer second.deinit();
    try std.testing.expectEqual(original_pointer, second.pixels.ptr);
    try std.testing.expectEqualSlices(u32, &.{ 1, 20, 3, 4, 50, 6 }, second.pixels);
    try std.testing.expectEqualSlices(render.Rect, &.{.{ .x = 1, .y = 0, .width = 1, .height = 2 }}, second.source_damage.?);
}

test "format transition forces a full copy" {
    const initial = [_]u32{ 0x0011_2233, 0x0044_5566 };
    var first = try copy(std.testing.allocator, .{
        .bytes = std.mem.sliceAsBytes(&initial),
        .size = .{ .width = 2, .height = 1 },
        .stride_bytes = 2 * @sizeOf(u32),
        .format = .argb8888,
    }, null, null, .{ .id = 1, .version = 1 });
    defer first.deinit();
    var empty_damage = Region.init();
    defer empty_damage.deinit();
    var second = try copy(std.testing.allocator, .{
        .bytes = std.mem.sliceAsBytes(&initial),
        .size = .{ .width = 2, .height = 1 },
        .stride_bytes = 2 * @sizeOf(u32),
        .format = .xrgb8888,
    }, &first, &empty_damage, .{ .id = 1, .version = 2 });
    defer second.deinit();
    try std.testing.expectEqualSlices(u32, &.{ 0xff11_2233, 0xff44_5566 }, second.pixels);
    try std.testing.expectEqual(@as(?[]const render.Rect, null), second.source_damage);
}

test "copy rejects truncated and invalid source geometry" {
    const bytes = [_]u8{0} ** 7;
    try std.testing.expectError(error.InvalidBuffer, copy(std.testing.allocator, .{
        .bytes = &bytes,
        .size = .{ .width = 2, .height = 1 },
        .stride_bytes = 8,
        .format = .argb8888,
    }, null, null, .{ .id = 1, .version = 1 }));
    try std.testing.expectError(error.InvalidBuffer, copy(std.testing.allocator, .{
        .bytes = &bytes,
        .size = .{ .width = 0, .height = 1 },
        .stride_bytes = 8,
        .format = .argb8888,
    }, null, null, .{ .id = 1, .version = 1 }));
    try std.testing.expectError(error.InvalidBuffer, copy(std.testing.allocator, .{
        .bytes = &bytes,
        .size = .{ .width = 1, .height = 2 },
        .stride_bytes = std.math.maxInt(usize),
        .format = .argb8888,
    }, null, null, .{ .id = 1, .version = 1 }));
}

test "empty compatible damage remains precise" {
    const pixels = [_]u32{ 1, 2 };
    var first = try copy(std.testing.allocator, .{
        .bytes = std.mem.sliceAsBytes(&pixels),
        .size = .{ .width = 2, .height = 1 },
        .stride_bytes = 2 * @sizeOf(u32),
        .format = .argb8888,
    }, null, null, .{ .id = 1, .version = 1 });
    defer first.deinit();
    var damage = Region.init();
    defer damage.deinit();
    var second = try copy(std.testing.allocator, .{
        .bytes = std.mem.sliceAsBytes(&pixels),
        .size = .{ .width = 2, .height = 1 },
        .stride_bytes = 2 * @sizeOf(u32),
        .format = .argb8888,
    }, &first, &damage, .{ .id = 1, .version = 2 });
    defer second.deinit();
    try std.testing.expect(second.source_damage != null);
    try std.testing.expectEqual(@as(usize, 0), second.source_damage.?.len);
}

test "reuse never transfers storage between allocators" {
    const pixels = [_]u32{ 1, 2 };
    const source: Source = .{
        .bytes = std.mem.sliceAsBytes(&pixels),
        .size = .{ .width = 2, .height = 1 },
        .stride_bytes = 2 * @sizeOf(u32),
        .format = .argb8888,
    };
    var first = try copy(std.testing.allocator, source, null, null, .{ .id = 1, .version = 1 });
    defer first.deinit();
    const first_pointer = first.pixels.ptr;
    var storage: [256]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var second = try copy(fixed.allocator(), source, &first, null, .{ .id = 1, .version = 2 });
    defer second.deinit();
    try std.testing.expectEqual(first_pointer, first.pixels.ptr);
    try std.testing.expect(first_pointer != second.pixels.ptr);
}
