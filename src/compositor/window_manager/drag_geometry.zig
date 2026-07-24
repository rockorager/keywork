//! Pointer geometry for moving floating windows and targeting tiled drops.

const std = @import("std");
const Scene = @import("../scene.zig");
const layout_mod = @import("layout.zig");
const types = @import("types.zig");

const center_radius: f64 = 0.25;

/// Applies the grab offset and clamps the resulting origin to scene coordinates.
pub fn toplevelPosition(x: f64, y: f64, grab_x: f64, grab_y: f64) Scene.Position {
    return .{
        .x = dragCoordinate(x - grab_x),
        .y = dragCoordinate(y - grab_y),
    };
}

/// Returns the clipped visible target rectangle when the point lies within its
/// half-open bounds.
pub fn hitTest(x: f64, y: f64, plan: types.LayoutPlan) ?types.Rect {
    const rect = visibleRect(plan) orelse return null;
    if (!(x >= @as(f64, @floatFromInt(rect.x)) and
        y >= @as(f64, @floatFromInt(rect.y)) and
        x < @as(f64, @floatFromInt(@as(i64, rect.x) + rect.size.width)) and
        y < @as(f64, @floatFromInt(@as(i64, rect.y) + rect.size.height)))) return null;
    return rect;
}

/// Selects the center or nearest cardinal drop zone within the target.
pub fn dropPosition(x: f64, y: f64, rect: types.Rect) layout_mod.DropPosition {
    const relative_x = std.math.clamp(
        (x - @as(f64, @floatFromInt(rect.x))) /
            @as(f64, @floatFromInt(rect.size.width)),
        0,
        1,
    );
    const relative_y = std.math.clamp(
        (y - @as(f64, @floatFromInt(rect.y))) /
            @as(f64, @floatFromInt(rect.size.height)),
        0,
        1,
    );
    const horizontal_distance = @abs(relative_x - 0.5);
    const vertical_distance = @abs(relative_y - 0.5);
    if (horizontal_distance <= center_radius and vertical_distance <= center_radius) {
        return .center;
    }
    if (horizontal_distance > vertical_distance) {
        return if (relative_x < 0.5) .left else .right;
    }
    return if (relative_y < 0.5) .top else .bottom;
}

/// Selects the nearest horizontal output edge within `threshold`.
pub fn outputEdgePosition(
    x: f64,
    y: f64,
    bounds: types.Rect,
    threshold: f64,
) ?layout_mod.DropPosition {
    std.debug.assert(threshold >= 0);
    const left: f64 = @floatFromInt(bounds.x);
    const top: f64 = @floatFromInt(bounds.y);
    const right: f64 = @floatFromInt(@as(i64, bounds.x) + bounds.size.width);
    const bottom: f64 = @floatFromInt(@as(i64, bounds.y) + bounds.size.height);
    if (x < left or x >= right or y < top or y >= bottom) return null;
    const left_distance = x - left;
    const right_distance = right - x;
    if (@min(left_distance, right_distance) > threshold) return null;
    return if (left_distance <= right_distance) .left else .right;
}

/// Returns the whole target for center drops and the corresponding half for an edge.
pub fn dropPreview(rect: types.Rect, position: layout_mod.DropPosition) types.Rect {
    return switch (position) {
        .center => rect,
        .left, .right => if (rect.size.width < 2)
            rect
        else preview: {
            const first_width = rect.size.width / 2;
            break :preview if (position == .left) .{
                .x = rect.x,
                .y = rect.y,
                .size = types.Size.init(first_width, rect.size.height),
            } else .{
                .x = rect.x + @as(i32, @intCast(first_width)),
                .y = rect.y,
                .size = types.Size.init(rect.size.width - first_width, rect.size.height),
            };
        },
        .top, .bottom => if (rect.size.height < 2)
            rect
        else preview: {
            const first_height = rect.size.height / 2;
            break :preview if (position == .top) .{
                .x = rect.x,
                .y = rect.y,
                .size = types.Size.init(rect.size.width, first_height),
            } else .{
                .x = rect.x,
                .y = rect.y + @as(i32, @intCast(first_height)),
                .size = types.Size.init(rect.size.width, rect.size.height - first_height),
            };
        },
    };
}

/// Intersects a visible layout plan with its optional clip.
pub fn visibleRect(plan: types.LayoutPlan) ?types.Rect {
    if (!plan.visible) return null;
    const clip = plan.clip orelse return plan.rect;
    const left = @max(@as(i64, plan.rect.x), clip.x);
    const top = @max(@as(i64, plan.rect.y), clip.y);
    const right = @min(
        @as(i64, plan.rect.x) + plan.rect.size.width,
        @as(i64, clip.x) + clip.size.width,
    );
    const bottom = @min(
        @as(i64, plan.rect.y) + plan.rect.size.height,
        @as(i64, clip.y) + clip.size.height,
    );
    if (left >= right or top >= bottom) return null;
    return .{
        .x = @intCast(left),
        .y = @intCast(top),
        .size = types.Size.init(@intCast(right - left), @intCast(bottom - top)),
    };
}

fn dragCoordinate(value: f64) i32 {
    return @intFromFloat(@floor(std.math.clamp(
        value,
        @as(f64, @floatFromInt(std.math.minInt(i32))),
        @as(f64, @floatFromInt(std.math.maxInt(i32))),
    )));
}

test "tiling drag hit testing honors visibility and layout clipping" {
    const plan: types.LayoutPlan = .{
        .id = types.id(1),
        .rect = .{ .x = 10, .y = 20, .size = types.Size.init(100, 80) },
        .visible = true,
        .clip = .{ .x = 30, .y = 10, .size = types.Size.init(40, 50) },
    };
    const visible = types.Rect{ .x = 30, .y = 20, .size = types.Size.init(40, 40) };
    try std.testing.expectEqual(visible, visibleRect(plan).?);
    try std.testing.expectEqual(visible, hitTest(30, 20, plan).?);
    try std.testing.expectEqual(visible, hitTest(69.99, 59.99, plan).?);
    try std.testing.expect(hitTest(29.99, 20, plan) == null);
    try std.testing.expect(hitTest(70, 20, plan) == null);
    try std.testing.expect(hitTest(std.math.nan(f64), 20, plan) == null);

    var hidden = plan;
    hidden.visible = false;
    try std.testing.expect(visibleRect(hidden) == null);
}

test "tiling drag drop zones select a side and preview its half" {
    const rect: types.Rect = .{
        .x = 100,
        .y = 200,
        .size = types.Size.init(400, 200),
    };
    try std.testing.expectEqual(layout_mod.DropPosition.center, dropPosition(300, 300, rect));
    try std.testing.expectEqual(layout_mod.DropPosition.left, dropPosition(110, 300, rect));
    try std.testing.expectEqual(layout_mod.DropPosition.right, dropPosition(490, 300, rect));
    try std.testing.expectEqual(layout_mod.DropPosition.top, dropPosition(300, 205, rect));
    try std.testing.expectEqual(layout_mod.DropPosition.bottom, dropPosition(300, 395, rect));

    try std.testing.expectEqual(
        types.Rect{ .x = 100, .y = 200, .size = types.Size.init(200, 200) },
        dropPreview(rect, .left),
    );
    try std.testing.expectEqual(
        types.Rect{ .x = 300, .y = 200, .size = types.Size.init(200, 200) },
        dropPreview(rect, .right),
    );
    try std.testing.expectEqual(
        types.Rect{ .x = 100, .y = 200, .size = types.Size.init(400, 100) },
        dropPreview(rect, .top),
    );
    try std.testing.expectEqual(
        types.Rect{ .x = 100, .y = 300, .size = types.Size.init(400, 100) },
        dropPreview(rect, .bottom),
    );
}

test "tiling drag detects output left and right edge targets" {
    const bounds: types.Rect = .{
        .x = 100,
        .y = 200,
        .size = types.Size.init(400, 200),
    };
    try std.testing.expectEqual(
        layout_mod.DropPosition.left,
        outputEdgePosition(100, 250, bounds, 32).?,
    );
    try std.testing.expectEqual(
        layout_mod.DropPosition.left,
        outputEdgePosition(132, 250, bounds, 32).?,
    );
    try std.testing.expectEqual(
        layout_mod.DropPosition.right,
        outputEdgePosition(499.99, 250, bounds, 32).?,
    );
    try std.testing.expect(outputEdgePosition(133, 250, bounds, 32) == null);
    try std.testing.expect(outputEdgePosition(300, 199, bounds, 32) == null);
    try std.testing.expect(outputEdgePosition(500, 250, bounds, 32) == null);
}

test "toplevel drag preserves the grab offset and clamps coordinates" {
    try std.testing.expectEqual(
        Scene.Position{ .x = 90, .y = 185 },
        toplevelPosition(100.75, 200.25, 10, 15),
    );
    try std.testing.expectEqual(
        Scene.Position{ .x = std.math.maxInt(i32), .y = std.math.minInt(i32) },
        toplevelPosition(1.0e20, -1.0e20, 0, 0),
    );
}
