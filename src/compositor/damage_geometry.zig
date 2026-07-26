//! Conservative rectangle policy for compositor damage propagation.

const std = @import("std");
const render = @import("render/types.zig");
const Scene = @import("scene.zig");

pub fn scaleRect(
    logical: render.Rect,
    scale: render.Scale,
    target_size: render.Size,
) ?render.Rect {
    std.debug.assert(logical.x >= 0 and logical.y >= 0);
    const denominator: i128 = render.Scale.denominator;
    const left_product = @as(i128, logical.x) * scale.numerator;
    const top_product = @as(i128, logical.y) * scale.numerator;
    const right_product = (@as(i128, logical.x) + logical.width) * scale.numerator;
    const bottom_product = (@as(i128, logical.y) + logical.height) * scale.numerator;
    var left: i64 = @intCast(@divTrunc(left_product, denominator));
    var top: i64 = @intCast(@divTrunc(top_product, denominator));
    var right: i64 = @intCast(@divTrunc(right_product + denominator - 1, denominator));
    var bottom: i64 = @intCast(@divTrunc(bottom_product + denominator - 1, denominator));
    if (scale.numerator % render.Scale.denominator != 0) {
        left -= 1;
        top -= 1;
        right += 1;
        bottom += 1;
    }
    left = std.math.clamp(left, 0, target_size.width);
    top = std.math.clamp(top, 0, target_size.height);
    right = std.math.clamp(right, 0, target_size.width);
    bottom = std.math.clamp(bottom, 0, target_size.height);
    if (right <= left or bottom <= top) return null;
    return .{
        .x = @intCast(left),
        .y = @intCast(top),
        .width = @intCast(right - left),
        .height = @intCast(bottom - top),
    };
}

pub fn expandRect(rectangle: render.Rect, amount: u32) render.Rect {
    const left = @as(i64, rectangle.x) - amount;
    const top = @as(i64, rectangle.y) - amount;
    const right = @as(i64, rectangle.x) + rectangle.width + amount;
    const bottom = @as(i64, rectangle.y) + rectangle.height + amount;
    return .{
        .x = @intCast(std.math.clamp(left, std.math.minInt(i32), std.math.maxInt(i32))),
        .y = @intCast(std.math.clamp(top, std.math.minInt(i32), std.math.maxInt(i32))),
        .width = @intCast(@min(right - left, std.math.maxInt(u32))),
        .height = @intCast(@min(bottom - top, std.math.maxInt(u32))),
    };
}

pub fn shadowRect(rectangle: render.Rect, shadow: Scene.Shadow) render.Rect {
    return expandRect(rectangle, shadowExtent(shadow));
}

fn shadowExtent(shadow: Scene.Shadow) u32 {
    const spread: u32 = if (shadow.spread > 0) @intCast(shadow.spread) else 0;
    const offset_x: u32 = if (shadow.offset.x < 0)
        @intCast(-@as(i64, shadow.offset.x))
    else
        @intCast(shadow.offset.x);
    const offset_y: u32 = if (shadow.offset.y < 0)
        @intCast(-@as(i64, shadow.offset.y))
    else
        @intCast(shadow.offset.y);
    return render.shadowBlurExtent(shadow.blur_radius) +|
        spread +| @max(offset_x, offset_y);
}

pub fn effectsRect(rectangle: render.Rect, effects: Scene.Effects) render.Rect {
    var amount: u32 = 0;
    if (effects.ambient_shadow) |shadow| {
        amount = @max(amount, shadowExtent(shadow));
    }
    if (effects.key_shadow) |shadow| {
        amount = @max(amount, shadowExtent(shadow));
    }
    return expandRect(rectangle, amount);
}

test "damage scaling covers fractional sampling edges" {
    try std.testing.expectEqual(
        render.Rect{ .x = 0, .y = 0, .width = 4, .height = 4 },
        scaleRect(
            .{ .x = 1, .y = 1, .width = 1, .height = 1 },
            .{ .numerator = 180 },
            .{ .width = 10, .height = 10 },
        ).?,
    );
    try std.testing.expectEqual(
        render.Rect{ .x = 2, .y = 2, .width = 2, .height = 2 },
        scaleRect(
            .{ .x = 1, .y = 1, .width = 1, .height = 1 },
            .{ .numerator = 240 },
            .{ .width = 10, .height = 10 },
        ).?,
    );
}

test "shadow damage includes blur spread and offset" {
    try std.testing.expectEqual(
        render.Rect{ .x = -14, .y = -4, .width = 78, .height = 88 },
        shadowRect(
            .{ .x = 10, .y = 20, .width = 30, .height = 40 },
            .{
                .offset = .{ .x = 3, .y = -2 },
                .blur_radius = 12,
                .spread = 3,
                .color = render.Color.rgba(0, 0, 0, 128),
            },
        ),
    );
}

test "effect damage includes every shadow layer" {
    try std.testing.expectEqual(
        render.Rect{ .x = -8, .y = 2, .width = 66, .height = 76 },
        effectsRect(
            .{ .x = 10, .y = 20, .width = 30, .height = 40 },
            .{
                .ambient_shadow = .{
                    .offset = .{ .y = 1 },
                    .blur_radius = 2,
                    .color = render.Color.rgba(0, 0, 0, 128),
                },
                .key_shadow = .{
                    .offset = .{ .y = 3 },
                    .blur_radius = 10,
                    .color = render.Color.rgba(0, 0, 0, 128),
                },
            },
        ),
    );
}
