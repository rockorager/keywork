//! Pure buffer transform, scale, and viewporter geometry policy for surfaces.

const std = @import("std");
const render = @import("../render/types.zig");

pub const ViewportSource = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const ViewportState = struct {
    source: ?ViewportSource = null,
    destination: ?render.Size = null,
};

pub const Geometry = struct {
    logical_size: render.Size,
    source: ?render.SourceRect,
};

pub const Error = error{
    InvalidSize,
    BadViewportSize,
    ViewportOutOfBuffer,
};

fn logicalSize(
    buffer_size: render.Size,
    scale: i32,
    transform: render.BufferTransform,
    allow_non_divisible_scale: bool,
) error{InvalidSize}!render.Size {
    if (scale <= 0) return error.InvalidSize;

    const transformed = transform.applyToSize(buffer_size);
    const unsigned_scale: u32 = @intCast(scale);
    // Cursor themes and CSS cursors can provide odd-sized buffers at an
    // integer scale. Established compositors accept those once the cursor role
    // is assigned rather than disconnecting the client. Ceiling division keeps
    // the complete image covered and avoids a zero-sized logical extent.
    if (!allow_non_divisible_scale and
        (transformed.width % unsigned_scale != 0 or
            transformed.height % unsigned_scale != 0)) return error.InvalidSize;

    return .{
        .width = std.math.divCeil(u32, transformed.width, unsigned_scale) catch
            return error.InvalidSize,
        .height = std.math.divCeil(u32, transformed.height, unsigned_scale) catch
            return error.InvalidSize,
    };
}

pub fn calculate(
    buffer_size: render.Size,
    scale: i32,
    transform: render.BufferTransform,
    viewport: ViewportState,
    allow_non_divisible_scale: bool,
) Error!Geometry {
    const base_size = logicalSize(
        buffer_size,
        scale,
        transform,
        allow_non_divisible_scale,
    ) catch
        return error.InvalidSize;
    const source = viewport.source orelse return .{
        .logical_size = viewport.destination orelse base_size,
        .source = null,
    };

    const right = @as(i64, source.x) + source.width;
    const bottom = @as(i64, source.y) + source.height;
    const transformed = transform.applyToSize(buffer_size);
    if (source.x < 0 or source.y < 0 or source.width <= 0 or source.height <= 0 or
        right * scale > @as(i64, transformed.width) * 256 or
        bottom * scale > @as(i64, transformed.height) * 256)
    {
        return error.ViewportOutOfBuffer;
    }

    const logical_size = viewport.destination orelse size: {
        if (@mod(source.width, 256) != 0 or @mod(source.height, 256) != 0) {
            return error.BadViewportSize;
        }
        const source_size: render.Size = .{
            .width = @as(u32, @intCast(@divExact(source.width, 256))),
            .height = @as(u32, @intCast(@divExact(source.height, 256))),
        };
        break :size source_size;
    };
    // Viewport source coordinates are post-transform, so preserve that coordinate
    // space for the renderer to map back to buffer pixels.
    const buffer_scale: f64 = @floatFromInt(scale);
    return .{
        .logical_size = logical_size,
        .source = .{
            .x = @as(f64, @floatFromInt(source.x)) / 256.0 * buffer_scale,
            .y = @as(f64, @floatFromInt(source.y)) / 256.0 * buffer_scale,
            .width = @as(f64, @floatFromInt(source.width)) / 256.0 * buffer_scale,
            .height = @as(f64, @floatFromInt(source.height)) / 256.0 * buffer_scale,
        },
    };
}

test "all buffer transforms apply renderer axis rules to logical size" {
    const Case = struct {
        transform: render.BufferTransform,
        expected: render.Size,
    };
    const cases = [_]Case{
        .{ .transform = .normal, .expected = .{ .width = 6, .height = 4 } },
        .{ .transform = .rotate_90, .expected = .{ .width = 4, .height = 6 } },
        .{ .transform = .rotate_180, .expected = .{ .width = 6, .height = 4 } },
        .{ .transform = .rotate_270, .expected = .{ .width = 4, .height = 6 } },
        .{ .transform = .flipped, .expected = .{ .width = 6, .height = 4 } },
        .{ .transform = .flipped_90, .expected = .{ .width = 4, .height = 6 } },
        .{ .transform = .flipped_180, .expected = .{ .width = 6, .height = 4 } },
        .{ .transform = .flipped_270, .expected = .{ .width = 4, .height = 6 } },
    };
    for (cases) |case| {
        try std.testing.expectEqual(
            case.expected,
            try logicalSize(.{ .width = 12, .height = 8 }, 2, case.transform, false),
        );
    }
}

test "logical size requires exact transformed dimensions at integer scale" {
    inline for (std.meta.tags(render.BufferTransform)) |transform| {
        try std.testing.expectError(
            error.InvalidSize,
            logicalSize(.{ .width = 13, .height = 8 }, 2, transform, false),
        );
    }
}

test "cursor compatibility covers non-divisible buffer scale" {
    const geometry = try calculate(
        .{ .width = 31, .height = 17 },
        2,
        .normal,
        .{},
        true,
    );
    try std.testing.expectEqual(
        render.Size{ .width = 16, .height = 9 },
        geometry.logical_size,
    );
    try std.testing.expectError(
        error.ViewportOutOfBuffer,
        calculate(
            .{ .width = 31, .height = 17 },
            2,
            .normal,
            .{
                .source = .{ .x = 0, .y = 0, .width = 16 * 256, .height = 8 * 256 },
                .destination = .{ .width = 16, .height = 8 },
            },
            true,
        ),
    );
}

test "viewport destination defines logical surface size" {
    const geometry = try calculate(
        .{ .width = 1200, .height = 900 },
        1,
        .normal,
        .{ .destination = .{ .width = 800, .height = 600 } },
        false,
    );
    try std.testing.expectEqual(
        render.Size{ .width = 800, .height = 600 },
        geometry.logical_size,
    );
    try std.testing.expectEqual(@as(?render.SourceRect, null), geometry.source);
}

test "viewport source is validated and converted to buffer coordinates" {
    const geometry = try calculate(
        .{ .width = 8, .height = 8 },
        2,
        .normal,
        .{
            .source = .{ .x = 256, .y = 512, .width = 512, .height = 256 },
            .destination = .{ .width = 4, .height = 2 },
        },
        false,
    );
    try std.testing.expectEqual(
        render.Size{ .width = 4, .height = 2 },
        geometry.logical_size,
    );
    try std.testing.expectEqual(@as(f64, 2), geometry.source.?.x);
    try std.testing.expectEqual(@as(f64, 4), geometry.source.?.y);
    try std.testing.expectEqual(@as(f64, 4), geometry.source.?.width);
    try std.testing.expectEqual(@as(f64, 2), geometry.source.?.height);
    try std.testing.expectError(
        error.ViewportOutOfBuffer,
        calculate(
            .{ .width = 8, .height = 8 },
            2,
            .normal,
            .{ .source = .{ .x = 768, .y = 0, .width = 512, .height = 256 } },
            false,
        ),
    );
    try std.testing.expectError(
        error.BadViewportSize,
        calculate(
            .{ .width = 8, .height = 8 },
            2,
            .normal,
            .{ .source = .{ .x = 0, .y = 0, .width = 128, .height = 256 } },
            false,
        ),
    );
}

test "viewport source bounds use post-transform axes" {
    const viewport: ViewportState = .{
        .source = .{ .x = 0, .y = 0, .width = 4 * 256, .height = 8 * 256 },
    };
    const geometry = try calculate(
        .{ .width = 8, .height = 4 },
        1,
        .rotate_90,
        viewport,
        false,
    );
    try std.testing.expectEqual(
        render.Size{ .width = 4, .height = 8 },
        geometry.logical_size,
    );
    try std.testing.expectEqual(@as(f64, 4), geometry.source.?.width);
    try std.testing.expectEqual(@as(f64, 8), geometry.source.?.height);
    try std.testing.expectError(
        error.ViewportOutOfBuffer,
        calculate(
            .{ .width = 8, .height = 4 },
            1,
            .normal,
            viewport,
            false,
        ),
    );
}
