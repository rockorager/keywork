//! Pure coordinate and bounds policy shared by compositor capture paths.

const std = @import("std");
const render = @import("render/types.zig");

pub fn floorToI32(value: f64) i32 {
    const floored = @floor(value);
    if (floored <= std.math.minInt(i32)) return std.math.minInt(i32);
    if (floored >= std.math.maxInt(i32)) return std.math.maxInt(i32);
    return @intFromFloat(floored);
}

pub fn scaleCoordinate(value: i64, scale: render.Scale) i32 {
    const product = @as(i128, value) * scale.numerator;
    const rounded = if (product >= 0)
        @divTrunc(product + render.Scale.denominator / 2, render.Scale.denominator)
    else
        -@divTrunc(-product + render.Scale.denominator / 2, render.Scale.denominator);
    return @intCast(std.math.clamp(
        rounded,
        std.math.minInt(i32),
        std.math.maxInt(i32),
    ));
}

pub fn scaledRegion(
    logical: render.Rect,
    scale: render.Scale,
    output_size: render.Size,
) ?render.Rect {
    const left = scaleCoordinate(logical.x, scale);
    const top = scaleCoordinate(logical.y, scale);
    const right = scaleCoordinate(@as(i64, logical.x) + logical.width, scale);
    const bottom = scaleCoordinate(@as(i64, logical.y) + logical.height, scale);
    if (left < 0 or top < 0 or right <= left or bottom <= top or
        right > output_size.width or bottom > output_size.height) return null;
    return .{
        .x = left,
        .y = top,
        .width = @intCast(right - left),
        .height = @intCast(bottom - top),
    };
}

pub fn logicalRect(output_rect: render.Rect, local_region: ?render.Rect) render.Rect {
    const region = local_region orelse return output_rect;
    return .{
        .x = output_rect.x +| region.x,
        .y = output_rect.y +| region.y,
        .width = region.width,
        .height = region.height,
    };
}

pub fn cursorMismatchAffects(
    source_painted: bool,
    capture_paints: bool,
    cursor_bounds: ?render.Rect,
    capture_rect: render.Rect,
) bool {
    if (source_painted == capture_paints) return false;
    const bounds = cursor_bounds orelse return true;
    return bounds.intersection(capture_rect) != null;
}

pub fn unionBounds(a: render.Rect, b: render.Rect) error{Overflow}!render.Rect {
    const left = @min(a.x, b.x);
    const top = @min(a.y, b.y);
    const right = @max(
        @as(i64, a.x) + a.width,
        @as(i64, b.x) + b.width,
    );
    const bottom = @max(
        @as(i64, a.y) + a.height,
        @as(i64, b.y) + b.height,
    );
    const width = right - left;
    const height = bottom - top;
    if (width <= 0 or height <= 0 or
        width > std.math.maxInt(u32) or height > std.math.maxInt(u32)) return error.Overflow;
    return .{
        .x = left,
        .y = top,
        .width = @intCast(width),
        .height = @intCast(height),
    };
}

test "capture coordinates preserve fractional image placement" {
    const scale: render.Scale = .{ .numerator = 180 };
    const position = scaleCoordinate(8, scale);
    const image_origin = scaleCoordinate(3, scale);
    const hotspot = position -| image_origin;
    try std.testing.expectEqual(@as(i32, 12), position);
    try std.testing.expectEqual(@as(i32, 5), image_origin);
    try std.testing.expectEqual(image_origin, position -| hotspot);
    try std.testing.expectEqual(@as(i32, -5), scaleCoordinate(-3, scale));
}

test "scaled region follows fractional output pixel boundaries" {
    try std.testing.expectEqual(
        render.Rect{ .x = 2, .y = 0, .width = 1, .height = 3 },
        scaledRegion(
            .{ .x = 1, .y = 0, .width = 1, .height = 2 },
            .{ .numerator = 180 },
            .{ .width = 6, .height = 6 },
        ).?,
    );
    try std.testing.expectEqual(
        render.Rect{ .x = 9, .y = 6, .width = 3, .height = 6 },
        scaledRegion(
            .{ .x = 6, .y = 4, .width = 2, .height = 4 },
            .{ .numerator = 180 },
            .{ .width = 12, .height = 12 },
        ).?,
    );
}

test "cursor mismatch ignores cursors outside the capture region" {
    const output_rect: render.Rect = .{ .x = 1000, .y = 500, .width = 800, .height = 600 };
    const capture_rect = logicalRect(output_rect, .{
        .x = 100,
        .y = 50,
        .width = 200,
        .height = 100,
    });
    try std.testing.expectEqual(
        render.Rect{ .x = 1100, .y = 550, .width = 200, .height = 100 },
        capture_rect,
    );
    try std.testing.expect(cursorMismatchAffects(
        false,
        true,
        .{ .x = 1200, .y = 600, .width = 32, .height = 32 },
        capture_rect,
    ));
    try std.testing.expect(!cursorMismatchAffects(
        false,
        true,
        .{ .x = 1500, .y = 900, .width = 32, .height = 32 },
        capture_rect,
    ));
    try std.testing.expect(!cursorMismatchAffects(
        false,
        false,
        .{ .x = 1200, .y = 600, .width = 32, .height = 32 },
        capture_rect,
    ));
    try std.testing.expect(cursorMismatchAffects(false, true, null, capture_rect));
}

test "capture bounds include negative child offsets" {
    try std.testing.expectEqual(
        render.Rect{ .x = -20, .y = 5, .width = 120, .height = 70 },
        try unionBounds(
            .{ .x = 0, .y = 10, .width = 100, .height = 50 },
            .{ .x = -20, .y = 5, .width = 30, .height = 70 },
        ),
    );
}
