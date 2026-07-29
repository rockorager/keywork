//! Physical damage propagation for backdrop blur captures.

const std = @import("std");
const damage_geometry = @import("damage_geometry.zig");
const Region = @import("region.zig");
const blur_geometry = @import("render/blur_geometry.zig");
const render = @import("render/types.zig");

pub const Area = struct {
    rect: render.Rect,
    radius: u32,
    downsample_level: ?u8,
};

/// Converts an output-local logical effect rectangle and radius to physical pixels.
pub fn areaForOutput(
    logical_rect: render.Rect,
    output_rect: render.Rect,
    scale: render.Scale,
    output_size: render.Size,
    radius: u32,
    downsample_level: ?u8,
) ?Area {
    if (radius == 0) return null;
    const logical = logical_rect.intersection(output_rect) orelse return null;
    const physical = damage_geometry.scaleRect(.{
        .x = logical.x -| output_rect.x,
        .y = logical.y -| output_rect.y,
        .width = logical.width,
        .height = logical.height,
    }, scale, output_size) orelse return null;
    const scaled_radius = (@as(u64, radius) * scale.numerator +
        render.Scale.denominator / 2) / render.Scale.denominator;
    if (scaled_radius == 0) return null;
    return .{
        .rect = physical,
        .radius = @intCast(scaled_radius),
        .downsample_level = downsample_level,
    };
}

/// Adds the complete affected capture area when `damage` intersects its sample area.
/// Returns whether the region changed.
pub fn propagate(
    damage: *Region,
    area: Area,
    output_size: render.Size,
) Region.Error!bool {
    const output_rect: render.Rect = .{
        .x = 0,
        .y = 0,
        .width = output_size.width,
        .height = output_size.height,
    };
    const footprint = blur_geometry.footprint(area.radius, area.downsample_level);
    const affected = damage_geometry.expandRect(area.rect, footprint)
        .intersection(output_rect) orelse return false;
    var rectangles = damage.rectangleIterator();
    while (rectangles.next()) |rectangle| {
        if (affected.intersection(.{
            .x = rectangle.x,
            .y = rectangle.y,
            .width = rectangle.width,
            .height = rectangle.height,
        }) != null) break;
    } else return false;
    if (damage.coversRectangle(affected.x, affected.y, affected.width, affected.height)) {
        return false;
    }
    try damage.add(affected.x, affected.y, @intCast(affected.width), @intCast(affected.height));
    return true;
}

test "logical blur area converts to output physical coordinates" {
    const area = areaForOutput(
        .{ .x = 12, .y = 23, .width = 5, .height = 7 },
        .{ .x = 10, .y = 20, .width = 100, .height = 80 },
        .{ .numerator = 240 },
        .{ .width = 200, .height = 160 },
        4,
        1,
    ).?;
    try std.testing.expectEqual(
        render.Rect{ .x = 4, .y = 6, .width = 10, .height = 14 },
        area.rect,
    );
    try std.testing.expectEqual(@as(u32, 8), area.radius);
    try std.testing.expectEqual(@as(?u8, 1), area.downsample_level);
    try std.testing.expectEqual(
        @as(?Area, null),
        areaForOutput(
            .{ .x = 12, .y = 23, .width = 5, .height = 7 },
            .{ .x = 10, .y = 20, .width = 100, .height = 80 },
            .{ .numerator = 240 },
            .{ .width = 200, .height = 160 },
            0,
            null,
        ),
    );
}

test "damage includes the whole blur and sample area" {
    var damage = Region.init();
    defer damage.deinit();
    damage.setRectangle(10, 10, 2, 2);
    const area: Area = .{
        .rect = .{ .x = 8, .y = 8, .width = 10, .height = 10 },
        .radius = 1,
        .downsample_level = null,
    };

    try std.testing.expect(try propagate(&damage, area, .{ .width = 20, .height = 20 }));
    try std.testing.expect(damage.coversRectangle(4, 4, 16, 16));
    try std.testing.expect(!try propagate(&damage, area, .{ .width = 20, .height = 20 }));

    var distant = Region.init();
    defer distant.deinit();
    distant.setRectangle(0, 0, 2, 2);
    try std.testing.expect(!try propagate(&distant, area, .{ .width = 20, .height = 20 }));
}

test "damage expands transitively across overlapping effects" {
    var damage = Region.init();
    defer damage.deinit();
    damage.setRectangle(5, 5, 1, 1);
    const areas = [_]Area{
        .{ .rect = .{ .x = 5, .y = 4, .width = 8, .height = 8 }, .radius = 1, .downsample_level = null },
        .{ .rect = .{ .x = 14, .y = 4, .width = 8, .height = 8 }, .radius = 1, .downsample_level = null },
    };
    var changed = true;
    while (changed) {
        changed = false;
        for (areas) |area| {
            changed = try propagate(&damage, area, .{ .width = 30, .height = 20 }) or changed;
        }
    }
    try std.testing.expect(damage.coversRectangle(1, 0, 16, 16));
    try std.testing.expect(damage.coversRectangle(10, 0, 16, 16));
}
