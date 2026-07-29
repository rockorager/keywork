//! Backend-independent operations over sets of rectangles.

const std = @import("std");
const render = @import("types.zig");

/// Returns the bounding box of `damage` clipped to `visible`. Null damage
/// represents the entire visible rectangle.
pub fn damageBounds(damage: ?[]const render.Rect, visible: render.Rect) ?render.Rect {
    const rectangles = damage orelse return visible;
    var bounds: ?render.Rect = null;
    for (rectangles) |rectangle| {
        const clipped = visible.intersection(rectangle) orelse continue;
        bounds = if (bounds) |current| current.unionWith(clipped) else clipped;
    }
    return bounds;
}

pub fn intersects(rectangles: []const render.Rect, rect: render.Rect) bool {
    for (rectangles) |rectangle| {
        if (rectangle.intersection(rect) != null) return true;
    }
    return false;
}

pub fn covers(
    allocator: std.mem.Allocator,
    rectangles: []const render.Rect,
    rect: render.Rect,
) error{OutOfMemory}!bool {
    var uncovered: std.ArrayList(render.Rect) = .empty;
    defer uncovered.deinit(allocator);
    var next: std.ArrayList(render.Rect) = .empty;
    defer next.deinit(allocator);
    try uncovered.append(allocator, rect);

    for (rectangles) |rectangle| {
        next.clearRetainingCapacity();
        for (uncovered.items) |fragment| {
            for (differenceStrips(fragment, rectangle)) |strip| {
                if (strip) |remaining| try next.append(allocator, remaining);
            }
        }
        std.mem.swap(std.ArrayList(render.Rect), &uncovered, &next);
        if (uncovered.items.len == 0) return true;
    }
    return false;
}

/// Returns non-overlapping top, bottom, left, and right strips of `outer`
/// after removing its intersection with `removed`.
pub fn differenceStrips(outer: render.Rect, removed: render.Rect) [4]?render.Rect {
    var result: [4]?render.Rect = @splat(null);
    const interior = outer.intersection(removed) orelse {
        result[0] = outer;
        return result;
    };
    const outer_right = @as(i64, outer.x) + outer.width;
    const outer_bottom = @as(i64, outer.y) + outer.height;
    const interior_right = @as(i64, interior.x) + interior.width;
    const interior_bottom = @as(i64, interior.y) + interior.height;
    if (interior.y > outer.y) result[0] = .{
        .x = outer.x,
        .y = outer.y,
        .width = outer.width,
        .height = @intCast(@as(i64, interior.y) - outer.y),
    };
    if (interior_bottom < outer_bottom) result[1] = .{
        .x = outer.x,
        .y = @intCast(interior_bottom),
        .width = outer.width,
        .height = @intCast(outer_bottom - interior_bottom),
    };
    if (interior.x > outer.x) result[2] = .{
        .x = outer.x,
        .y = interior.y,
        .width = @intCast(@as(i64, interior.x) - outer.x),
        .height = interior.height,
    };
    if (interior_right < outer_right) result[3] = .{
        .x = @intCast(interior_right),
        .y = interior.y,
        .width = @intCast(outer_right - interior_right),
        .height = interior.height,
    };
    return result;
}

/// Returns the largest axis-aligned rectangle wholly inside the rounded
/// rectangle described by `rect` and `radius`, or null when the rounding
/// leaves no such rectangle. Every pixel of the result lies inside the
/// rounded shape, so an opaque rounded draw covers it completely.
///
/// Asserts `radius` is already clamped to half the shorter side.
pub fn roundedRectInterior(rect: render.Rect, radius: u32) ?render.Rect {
    std.debug.assert(radius <= @min(rect.width, rect.height) / 2);
    const inset = radius * 2;
    if (rect.width <= inset or rect.height <= inset) return null;
    return .{
        .x = @intCast(@as(i64, rect.x) + radius),
        .y = @intCast(@as(i64, rect.y) + radius),
        .width = rect.width - inset,
        .height = rect.height - inset,
    };
}

test "rounded rectangle interior insets by the corner radius" {
    try std.testing.expectEqual(
        render.Rect{ .x = 22, .y = 32, .width = 76, .height = 56 },
        roundedRectInterior(.{ .x = 10, .y = 20, .width = 100, .height = 80 }, 12).?,
    );
    try std.testing.expectEqual(
        render.Rect{ .x = 10, .y = 20, .width = 100, .height = 80 },
        roundedRectInterior(.{ .x = 10, .y = 20, .width = 100, .height = 80 }, 0).?,
    );
    try std.testing.expectEqual(
        @as(?render.Rect, null),
        roundedRectInterior(.{ .x = 10, .y = 20, .width = 24, .height = 24 }, 12),
    );
}

test "damage bounds cover only damaged visible pixels" {
    const visible: render.Rect = .{ .x = 10, .y = 10, .width = 100, .height = 80 };
    try std.testing.expectEqual(visible, damageBounds(null, visible).?);
    try std.testing.expectEqual(
        render.Rect{ .x = 12, .y = 15, .width = 88, .height = 55 },
        damageBounds(&.{
            .{ .x = 12, .y = 15, .width = 8, .height = 5 },
            .{ .x = 90, .y = 60, .width = 10, .height = 10 },
        }, visible).?,
    );
    try std.testing.expectEqual(
        null,
        damageBounds(&.{.{ .x = 0, .y = 0, .width = 5, .height = 5 }}, visible),
    );
}

test "rectangle difference returns non-overlapping edge strips" {
    try std.testing.expectEqualSlices(
        ?render.Rect,
        &.{
            .{ .x = 10, .y = 20, .width = 100, .height = 15 },
            .{ .x = 10, .y = 65, .width = 100, .height = 35 },
            .{ .x = 10, .y = 35, .width = 20, .height = 30 },
            .{ .x = 70, .y = 35, .width = 40, .height = 30 },
        },
        &differenceStrips(
            .{ .x = 10, .y = 20, .width = 100, .height = 80 },
            .{ .x = 30, .y = 35, .width = 40, .height = 30 },
        ),
    );
    try std.testing.expectEqualSlices(
        ?render.Rect,
        &.{ .{ .x = 10, .y = 20, .width = 100, .height = 80 }, null, null, null },
        &differenceStrips(
            .{ .x = 10, .y = 20, .width = 100, .height = 80 },
            .{ .x = -20, .y = -20, .width = 10, .height = 10 },
        ),
    );
}

test "rectangle coverage combines disjoint rectangles without accepting holes" {
    const target: render.Rect = .{ .x = 2, .y = 3, .width = 6, .height = 4 };
    try std.testing.expect(try covers(std.testing.allocator, &.{
        .{ .x = 2, .y = 3, .width = 3, .height = 4 },
        .{ .x = 5, .y = 3, .width = 3, .height = 4 },
    }, target));
    try std.testing.expect(!try covers(std.testing.allocator, &.{
        .{ .x = 2, .y = 3, .width = 3, .height = 4 },
        .{ .x = 6, .y = 3, .width = 2, .height = 4 },
    }, target));
    try std.testing.expect(intersects(&.{.{ .x = 0, .y = 0, .width = 3, .height = 4 }}, target));
    try std.testing.expect(!intersects(&.{.{ .x = -2, .y = -2, .width = 2, .height = 2 }}, target));
}
