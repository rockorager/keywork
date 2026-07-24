//! Initial size and placement policy for floating windows.

const std = @import("std");
const Scene = @import("../scene.zig");
const types = @import("types.zig");

/// Centers an unsaved window over its parent; a saved position replaces the
/// origin without constraining it to the parent.
pub fn rect(parent: types.Rect, size: types.Size, position: ?Scene.Position) types.Rect {
    var result = centeredRect(parent, size);
    if (position) |value| {
        result.x = value.x;
        result.y = value.y;
    }
    return result;
}

/// Clamps signed natural dimensions to at least one pixel and at most two
/// thirds of the usable bounds.
pub fn manualSize(
    bounds: types.Size,
    current_width: i32,
    current_height: i32,
) types.Size {
    const maximum_width: u32 = @intCast(@max(1, @divFloor(@as(i64, bounds.width) * 2, 3)));
    const maximum_height: u32 = @intCast(@max(1, @divFloor(@as(i64, bounds.height) * 2, 3)));
    return types.Size.init(
        @min(@as(u32, @intCast(@max(1, current_width))), maximum_width),
        @min(@as(u32, @intCast(@max(1, current_height))), maximum_height),
    );
}

fn centeredRect(parent: types.Rect, size: types.Size) types.Rect {
    return .{
        .x = centeredCoordinate(parent.x, parent.size.width, size.width),
        .y = centeredCoordinate(parent.y, parent.size.height, size.height),
        .size = size,
    };
}

fn centeredCoordinate(parent_start: i32, parent_length: u32, child_length: u32) i32 {
    const doubled = 2 * @as(i64, parent_start) + parent_length - child_length;
    return @intCast(std.math.clamp(
        @divFloor(doubled, 2),
        std.math.minInt(i32),
        std.math.maxInt(i32),
    ));
}

test "transient toplevel is centered over its parent" {
    const parent: types.Rect = .{
        .x = 100,
        .y = 50,
        .size = types.Size.init(800, 600),
    };
    try std.testing.expectEqual(
        types.Rect{ .x = 250, .y = 200, .size = types.Size.init(500, 300) },
        centeredRect(parent, types.Size.init(500, 300)),
    );
    try std.testing.expectEqual(
        types.Rect{ .x = 0, .y = 0, .size = types.Size.init(1000, 700) },
        centeredRect(parent, types.Size.init(1000, 700)),
    );
    try std.testing.expectEqual(
        types.Rect{ .x = 700, .y = 400, .size = types.Size.init(500, 300) },
        rect(parent, types.Size.init(500, 300), .{ .x = 700, .y = 400 }),
    );
}

test "manually floated windows are capped to two thirds of the usable area" {
    try std.testing.expectEqual(
        types.Size.init(800, 600),
        manualSize(types.Size.init(1200, 900), 1200, 900),
    );
    try std.testing.expectEqual(
        types.Size.init(640, 480),
        manualSize(types.Size.init(1200, 900), 640, 480),
    );
    try std.testing.expectEqual(
        types.Size.init(1, 1),
        manualSize(types.Size.init(1200, 900), 0, -1),
    );
}
