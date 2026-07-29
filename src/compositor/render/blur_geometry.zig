//! Backend-independent geometry for dual-Kawase backdrop blur.

const std = @import("std");
const render = @import("types.zig");

pub const level_count = render.maximum_blur_downsample_level + 1;

pub fn levelForRadius(radius: u32) u8 {
    var level: u8 = 0;
    while (level < level_count - 1 and ceilDiv(radius, levelScale(level)) > 2) {
        level += 1;
    }
    return level;
}

/// The configured level, when present, must be less than `level_count`.
pub fn configuredLevel(radius: u32, configured: ?u8) u8 {
    std.debug.assert(configured == null or configured.? < level_count);
    return configured orelse levelForRadius(radius);
}

/// The configured level, when present, must be less than `level_count`.
pub fn footprint(radius: u32, configured_level: ?u8) u32 {
    if (radius == 0) return 0;
    const scale = levelScale(configuredLevel(radius, configured_level));
    return (ceilDiv(radius, scale) +| 3) *| scale;
}

/// `level` must be less than `level_count`.
pub fn levelSize(size: render.Size, level: u8) render.Size {
    const scale = levelScale(level);
    return .{
        .width = ceilDiv(size.width, scale),
        .height = ceilDiv(size.height, scale),
    };
}

/// `level` must be less than `level_count`.
pub fn sampleOffset(radius: u32, level: u8) f32 {
    return @as(f32, @floatFromInt(radius)) /
        @as(f32, @floatFromInt(kernelExtent(level)));
}

/// `level` must be less than `level_count`.
pub fn sourceExpansion(radius: u32, level: u8) u32 {
    // Include one texel for the linear sampler's footprint around each tap.
    return ceilDiv(radius, kernelExtent(level)) + 1;
}

/// `level` must be less than `level_count`.
pub fn scaledRect(rect: render.Rect, level: u8) render.Rect {
    const scale: i64 = levelScale(level);
    const left = @divFloor(@as(i64, rect.x), scale);
    const top = @divFloor(@as(i64, rect.y), scale);
    const right = @divFloor(@as(i64, rect.x) + rect.width + scale - 1, scale);
    const bottom = @divFloor(@as(i64, rect.y) + rect.height + scale - 1, scale);
    return .{
        .x = @intCast(left),
        .y = @intCast(top),
        .width = @intCast(right - left),
        .height = @intCast(bottom - top),
    };
}

/// `rect` must be clipped to `frame_size`; `level` must be valid.
pub fn sampleRect(
    rect: render.Rect,
    radius: u32,
    level: u8,
    frame_size: render.Size,
) render.Rect {
    const alignment: i64 = levelScale(level);
    const left = @max(@divFloor(@as(i64, rect.x) - radius, alignment) * alignment, 0);
    const top = @max(@divFloor(@as(i64, rect.y) - radius, alignment) * alignment, 0);
    const raw_right = @as(i64, rect.x) + rect.width + radius;
    const raw_bottom = @as(i64, rect.y) + rect.height + radius;
    const right = @min(
        @divFloor(raw_right + alignment - 1, alignment) * alignment,
        frame_size.width,
    );
    const bottom = @min(
        @divFloor(raw_bottom + alignment - 1, alignment) * alignment,
        frame_size.height,
    );
    return .{
        .x = @intCast(left),
        .y = @intCast(top),
        .width = @intCast(right - left),
        .height = @intCast(bottom - top),
    };
}

/// The expanded rectangle must intersect `bounds`.
pub fn expandWithin(rect: render.Rect, amount: u32, bounds: render.Rect) render.Rect {
    const left = @max(@as(i64, rect.x) - amount, bounds.x);
    const top = @max(@as(i64, rect.y) - amount, bounds.y);
    const right = @min(
        @as(i64, rect.x) + rect.width + amount,
        @as(i64, bounds.x) + bounds.width,
    );
    const bottom = @min(
        @as(i64, rect.y) + rect.height + amount,
        @as(i64, bounds.y) + bounds.height,
    );
    std.debug.assert(left < right and top < bottom);
    return .{
        .x = @intCast(left),
        .y = @intCast(top),
        .width = @intCast(right - left),
        .height = @intCast(bottom - top),
    };
}

fn levelScale(level: u8) u32 {
    std.debug.assert(level < level_count);
    return @as(u32, 1) << @intCast(level);
}

fn kernelExtent(level: u8) u32 {
    if (level == 0) return 2;
    return 3 * levelScale(level) - 3;
}

fn ceilDiv(value: u32, divisor: u32) u32 {
    return value / divisor + @intFromBool(value % divisor != 0);
}

test "blur level keeps the low-resolution radius bounded" {
    const cases = [_]struct { radius: u32, level: u8 }{
        .{ .radius = 1, .level = 0 },
        .{ .radius = 2, .level = 0 },
        .{ .radius = 3, .level = 1 },
        .{ .radius = 4, .level = 1 },
        .{ .radius = 5, .level = 2 },
        .{ .radius = 8, .level = 2 },
        .{ .radius = 9, .level = 3 },
        .{ .radius = 16, .level = 3 },
        .{ .radius = 17, .level = 4 },
        .{ .radius = 32, .level = 4 },
        .{ .radius = 64, .level = 5 },
        .{ .radius = 128, .level = 5 },
        .{ .radius = 256, .level = 5 },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.level, levelForRadius(case.radius));
        try std.testing.expect(ceilDiv(case.radius, levelScale(case.level)) <= 2 or
            case.level == level_count - 1);
    }

    try std.testing.expectEqual(@as(u8, 3), configuredLevel(16, null));
    try std.testing.expectEqual(@as(u8, 0), configuredLevel(16, 0));
    try std.testing.expectEqual(@as(u8, 5), configuredLevel(16, 5));
}

test "blur footprint conservatively covers every configured level" {
    try std.testing.expectEqual(@as(u32, 0), footprint(0, null));
    try std.testing.expectEqual(@as(u32, 4), footprint(1, null));
    try std.testing.expectEqual(@as(u32, 10), footprint(3, null));
    try std.testing.expectEqual(@as(u32, 40), footprint(16, null));
    try std.testing.expectEqual(@as(u32, 192), footprint(65, null));
    try std.testing.expectEqual(@as(u32, 19), footprint(16, 0));
    try std.testing.expectEqual(@as(u32, 128), footprint(16, 5));
    try std.testing.expectEqual(std.math.maxInt(u32), footprint(std.math.maxInt(u32), null));

    for (0..level_count) |level_index| {
        const level: u8 = @intCast(level_index);
        const scale = levelScale(level);
        for (1..257) |radius_index| {
            const radius: u32 = @intCast(radius_index);
            const expected = (ceilDiv(radius, scale) + 3) * scale;
            try std.testing.expectEqual(expected, footprint(radius, level));
        }
    }
}

test "blur sampling parameters follow the pyramid geometry" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), sampleOffset(1, 0), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), sampleOffset(3, 1), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 16.0 / 21.0), sampleOffset(16, 3), 0.0001);
    try std.testing.expectEqual(@as(u32, 2), sourceExpansion(1, 0));
    try std.testing.expectEqual(@as(u32, 2), sourceExpansion(16, 3));
}

test "blur geometry scales odd rectangles and clips aligned edges" {
    try std.testing.expectEqual(
        render.Size{ .width = 5, .height = 4 },
        levelSize(.{ .width = 17, .height = 13 }, 2),
    );
    try std.testing.expectEqual(
        render.Rect{ .x = 0, .y = 0, .width = 5, .height = 4 },
        scaledRect(.{ .x = 1, .y = 3, .width = 16, .height = 10 }, 2),
    );
    try std.testing.expectEqual(
        render.Rect{ .x = 0, .y = 0, .width = 17, .height = 13 },
        sampleRect(
            .{ .x = 1, .y = 3, .width = 15, .height = 9 },
            9,
            1,
            .{ .width = 17, .height = 13 },
        ),
    );
    try std.testing.expectEqual(
        render.Rect{ .x = 8, .y = 4, .width = 16, .height = 16 },
        sampleRect(
            .{ .x = 13, .y = 9, .width = 5, .height = 5 },
            3,
            2,
            .{ .width = 31, .height = 23 },
        ),
    );
    try std.testing.expectEqual(
        render.Rect{ .x = 4, .y = 0, .width = 27, .height = 23 },
        sampleRect(
            .{ .x = 17, .y = 9, .width = 1, .height = 1 },
            12,
            2,
            .{ .width = 31, .height = 23 },
        ),
    );
    try std.testing.expectEqual(
        render.Rect{ .x = 3, .y = 2, .width = 4, .height = 5 },
        expandWithin(
            .{ .x = 4, .y = 4, .width = 2, .height = 2 },
            3,
            .{ .x = 3, .y = 2, .width = 4, .height = 5 },
        ),
    );
}
