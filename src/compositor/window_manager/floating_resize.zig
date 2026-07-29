//! Hit testing and constrained geometry policy for floating-window resize.

const std = @import("std");
const wayland = @import("wayland");
const types = @import("types.zig");

const PointerShape = wayland.server.wp.CursorShapeDeviceV1.Shape;

pub const Edges = packed struct(u4) {
    top: bool = false,
    right: bool = false,
    bottom: bool = false,
    left: bool = false,
};

/// Returns the nearest horizontal and vertical edges within `threshold` when
/// the pointer lies inside the half-open window rectangle.
pub fn edgesAt(
    rect: types.Rect,
    pointer_x: f64,
    pointer_y: f64,
    threshold: f64,
) ?Edges {
    std.debug.assert(threshold >= 0);
    const left: f64 = @floatFromInt(rect.x);
    const top: f64 = @floatFromInt(rect.y);
    const right: f64 = @floatFromInt(@as(i64, rect.x) + rect.size.width);
    const bottom: f64 = @floatFromInt(@as(i64, rect.y) + rect.size.height);
    if (pointer_x < left or pointer_x >= right or pointer_y < top or pointer_y >= bottom) {
        return null;
    }
    const left_distance = pointer_x - left;
    const right_distance = right - pointer_x;
    const top_distance = pointer_y - top;
    const bottom_distance = bottom - pointer_y;
    var edges: Edges = .{};
    if (@min(left_distance, right_distance) <= threshold) {
        if (left_distance <= right_distance) edges.left = true else edges.right = true;
    }
    if (@min(top_distance, bottom_distance) <= threshold) {
        if (top_distance <= bottom_distance) edges.top = true else edges.bottom = true;
    }
    return if (@as(u4, @bitCast(edges)) == 0) null else edges;
}

/// Returns the directional cursor for a nonempty, nonconflicting edge set.
pub fn cursorShape(edges: Edges) PointerShape {
    std.debug.assert(!(edges.left and edges.right) and !(edges.top and edges.bottom));
    if (edges.top) {
        if (edges.left) return .nw_resize;
        if (edges.right) return .ne_resize;
        return .n_resize;
    }
    if (edges.bottom) {
        if (edges.left) return .sw_resize;
        if (edges.right) return .se_resize;
        return .s_resize;
    }
    if (edges.left) return .w_resize;
    std.debug.assert(edges.right);
    return .e_resize;
}

/// Applies pointer motion to the selected edges, preserving the opposite edge
/// while clamping dimensions to valid size constraints.
pub fn resizedRect(
    initial: types.Rect,
    initial_pointer_x: f64,
    initial_pointer_y: f64,
    edges: Edges,
    constraints: types.SizeConstraints,
    pointer_x: f64,
    pointer_y: f64,
) types.Rect {
    const horizontal = edges.left or edges.right;
    const vertical = edges.top or edges.bottom;
    std.debug.assert((horizontal or vertical) and !(edges.left and edges.right) and
        !(edges.top and edges.bottom));
    const width = if (horizontal)
        resizedLength(
            initial.size.width,
            pointerDelta(pointer_x - initial_pointer_x),
            edges.left,
            constraints.min_width,
            constraints.max_width orelse std.math.maxInt(i32),
        )
    else
        initial.size.width;
    const height = if (vertical)
        resizedLength(
            initial.size.height,
            pointerDelta(pointer_y - initial_pointer_y),
            edges.top,
            constraints.min_height,
            constraints.max_height orelse std.math.maxInt(i32),
        )
    else
        initial.size.height;
    const x = if (edges.left)
        @as(i64, initial.x) + initial.size.width - width
    else
        initial.x;
    const y = if (edges.top)
        @as(i64, initial.y) + initial.size.height - height
    else
        initial.y;
    return .{
        .x = @intCast(std.math.clamp(x, std.math.minInt(i32), std.math.maxInt(i32))),
        .y = @intCast(std.math.clamp(y, std.math.minInt(i32), std.math.maxInt(i32))),
        .size = types.Size.init(width, height),
    };
}

fn resizedLength(
    initial: u32,
    delta: i64,
    leading: bool,
    minimum: u32,
    maximum: u32,
) u32 {
    std.debug.assert(minimum > 0 and minimum <= maximum);
    const requested = @as(i64, initial) + if (leading) -delta else delta;
    return @intCast(std.math.clamp(
        requested,
        @as(i64, minimum),
        @as(i64, maximum),
    ));
}

fn pointerDelta(value: f64) i64 {
    return @intFromFloat(@round(std.math.clamp(
        value,
        @as(f64, @floatFromInt(std.math.minInt(i32))),
        @as(f64, @floatFromInt(std.math.maxInt(i32))),
    )));
}

test "resize anchors the opposite corner and honors constraints" {
    const initial: types.Rect = .{
        .x = 100,
        .y = 200,
        .size = types.Size.init(400, 300),
    };
    const edges: Edges = .{ .top = true, .left = true };
    const constraints: types.SizeConstraints = .{
        .min_width = 300,
        .min_height = 250,
        .max_width = 450,
        .max_height = 350,
    };
    try std.testing.expectEqual(
        types.Rect{ .x = 150, .y = 220, .size = types.Size.init(350, 280) },
        resizedRect(initial, 150, 250, edges, constraints, 200, 270),
    );
    try std.testing.expectEqual(
        types.Rect{ .x = 200, .y = 250, .size = types.Size.init(300, 250) },
        resizedRect(initial, 150, 250, edges, constraints, 1000, 1000),
    );
    try std.testing.expectEqual(
        types.Rect{ .x = 100, .y = 200, .size = types.Size.init(450, 250) },
        resizedRect(
            initial,
            450,
            450,
            .{ .right = true, .bottom = true },
            constraints,
            550,
            -50,
        ),
    );
    try std.testing.expectEqual(
        types.Rect{ .x = 100, .y = 220, .size = types.Size.init(400, 280) },
        resizedRect(
            initial,
            300,
            202,
            .{ .top = true },
            constraints,
            900,
            222,
        ),
    );
}

test "edges are restricted to the pointer hit region" {
    const rect: types.Rect = .{
        .x = 100,
        .y = 200,
        .size = types.Size.init(400, 300),
    };
    try std.testing.expectEqual(
        Edges{ .top = true, .left = true },
        edgesAt(rect, 102, 202, 8).?,
    );
    try std.testing.expectEqual(
        Edges{ .right = true },
        edgesAt(rect, 499, 350, 8).?,
    );
    try std.testing.expect(edgesAt(rect, 300, 350, 8) == null);
    try std.testing.expect(edgesAt(rect, 500, 350, 8) == null);
}

test "edges select directional cursor shapes" {
    try std.testing.expectEqual(PointerShape.n_resize, cursorShape(.{ .top = true }));
    try std.testing.expectEqual(PointerShape.ne_resize, cursorShape(.{
        .top = true,
        .right = true,
    }));
    try std.testing.expectEqual(PointerShape.e_resize, cursorShape(.{ .right = true }));
    try std.testing.expectEqual(PointerShape.se_resize, cursorShape(.{
        .bottom = true,
        .right = true,
    }));
    try std.testing.expectEqual(PointerShape.s_resize, cursorShape(.{ .bottom = true }));
    try std.testing.expectEqual(PointerShape.sw_resize, cursorShape(.{
        .bottom = true,
        .left = true,
    }));
    try std.testing.expectEqual(PointerShape.w_resize, cursorShape(.{ .left = true }));
    try std.testing.expectEqual(PointerShape.nw_resize, cursorShape(.{
        .top = true,
        .left = true,
    }));
}
