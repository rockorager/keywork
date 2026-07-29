//! Pure cursor image resizing into caller-owned pixel storage.

const std = @import("std");
const render = @import("../render/types.zig");

/// Resizes a non-empty source into a non-empty destination image and clears
/// all destination storage outside the image, including row padding.
pub fn resample(
    source: render.PixelBuffer,
    size: render.Size,
    destination: []u32,
    destination_stride: u32,
) void {
    std.debug.assert(source.size.width > 0 and source.size.height > 0);
    std.debug.assert(size.width > 0 and size.height > 0);
    std.debug.assert(source.stride_pixels >= source.size.width);
    std.debug.assert(destination_stride >= size.width);
    const source_required = (@as(usize, source.size.height) - 1) * source.stride_pixels +
        source.size.width;
    const destination_required = (@as(usize, size.height) - 1) * destination_stride +
        size.width;
    std.debug.assert(source.pixels.len >= source_required);
    std.debug.assert(destination.len >= destination_required);
    @memset(destination, 0);
    if (std.meta.eql(source.size, size)) {
        for (0..size.height) |y| {
            @memcpy(
                destination[y * destination_stride ..][0..size.width],
                source.pixels[y * source.stride_pixels ..][0..size.width],
            );
        }
        return;
    }
    for (0..size.height) |y| {
        const vertical = sample(y, source.size.height, size.height);
        for (0..size.width) |x| {
            const horizontal = sample(x, source.size.width, size.width);
            const top_left = source.pixels[vertical.first * source.stride_pixels + horizontal.first];
            const top_right = source.pixels[vertical.first * source.stride_pixels + horizontal.second];
            const bottom_left = source.pixels[vertical.second * source.stride_pixels + horizontal.first];
            const bottom_right = source.pixels[vertical.second * source.stride_pixels + horizontal.second];
            destination[y * destination_stride + x] = interpolatePixel(
                top_left,
                top_right,
                bottom_left,
                bottom_right,
                horizontal.weight,
                vertical.weight,
            );
        }
    }
}

const Sample = struct {
    first: usize,
    second: usize,
    weight: f64,
};

fn sample(destination: usize, source_size: u32, destination_size: u32) Sample {
    std.debug.assert(source_size > 0 and destination_size > 0);
    const position = (@as(f64, @floatFromInt(destination)) + 0.5) *
        @as(f64, @floatFromInt(source_size)) / @as(f64, @floatFromInt(destination_size)) - 0.5;
    const first_unclamped: i64 = @intFromFloat(@floor(position));
    const maximum: i64 = source_size - 1;
    return .{
        .first = @intCast(std.math.clamp(first_unclamped, 0, maximum)),
        .second = @intCast(std.math.clamp(first_unclamped + 1, 0, maximum)),
        .weight = position - @floor(position),
    };
}

fn interpolatePixel(
    top_left: u32,
    top_right: u32,
    bottom_left: u32,
    bottom_right: u32,
    horizontal: f64,
    vertical: f64,
) u32 {
    var result: u32 = 0;
    inline for (0..4) |component| {
        const shift: u5 = @intCast(component * 8);
        const top = @as(f64, @floatFromInt(@as(u8, @truncate(top_left >> shift)))) *
            (1.0 - horizontal) +
            @as(f64, @floatFromInt(@as(u8, @truncate(top_right >> shift)))) * horizontal;
        const bottom = @as(f64, @floatFromInt(@as(u8, @truncate(bottom_left >> shift)))) *
            (1.0 - horizontal) +
            @as(f64, @floatFromInt(@as(u8, @truncate(bottom_right >> shift)))) * horizontal;
        const value: u32 = @intFromFloat(@round(top * (1.0 - vertical) + bottom * vertical));
        result |= value << shift;
    }
    return result;
}

test "cursor rescale interpolates pixels and clears destination padding" {
    const source_pixels = [_]u32{ 1, 2, 3, 4 };
    var destination_pixels = [_]u32{9} ** 12;
    resample(.{
        .size = .{ .width = 2, .height = 2 },
        .stride_pixels = 2,
        .pixels = @constCast(&source_pixels),
    }, .{ .width = 3, .height = 3 }, &destination_pixels, 4);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 2, 0 }, destination_pixels[0..4]);
    try std.testing.expectEqualSlices(u32, &.{ 2, 3, 3, 0 }, destination_pixels[4..8]);
    try std.testing.expectEqualSlices(u32, &.{ 3, 4, 4, 0 }, destination_pixels[8..12]);

    @memset(&destination_pixels, 9);
    resample(.{
        .size = .{ .width = 2, .height = 2 },
        .stride_pixels = 2,
        .pixels = @constCast(&source_pixels),
    }, .{ .width = 2, .height = 2 }, &destination_pixels, 4);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 0, 0 }, destination_pixels[0..4]);
    try std.testing.expectEqualSlices(u32, &.{ 3, 4, 0, 0 }, destination_pixels[4..8]);
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 0, 0 }, destination_pixels[8..12]);
}
