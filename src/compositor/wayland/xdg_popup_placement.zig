//! Pure xdg-positioner popup placement and constraint adjustment policy.

const std = @import("std");
const wayland = @import("wayland");
const render = @import("../render/types.zig");
const Scene = @import("../scene.zig");

const xdg = wayland.server.xdg;

pub const Size = struct {
    width: i32,
    height: i32,
};

pub const AnchorRect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const Rules = struct {
    size: ?Size = null,
    anchor_rect: ?AnchorRect = null,
    anchor: xdg.Positioner.Anchor = .none,
    gravity: xdg.Positioner.Gravity = .none,
    adjustment: xdg.Positioner.ConstraintAdjustment = .{},
    offset: Scene.Position = .{},
    reactive: bool = false,
    parent_size: ?Size = null,
    parent_configure: ?u32 = null,

    pub fn complete(self: Rules) bool {
        const size = self.size orelse return false;
        const anchor_rect = self.anchor_rect orelse return false;
        return size.width > 0 and size.height > 0 and
            anchor_rect.width > 0 and anchor_rect.height > 0;
    }
};

pub const Placement = struct {
    position: Scene.Position,
    dimensions: Size,
};

/// Places a popup from complete positioner rules and applies output constraints.
pub fn place(
    rules: Rules,
    parent_position: Scene.Position,
    output_bounds: render.Rect,
) Placement {
    std.debug.assert(rules.complete());
    const size = rules.size.?;
    var width: i64 = size.width;
    var height: i64 = size.height;
    const parent_x: i64 = parent_position.x;
    const parent_y: i64 = parent_position.y;
    const output_left: i64 = output_bounds.x;
    const output_top: i64 = output_bounds.y;
    const output_right = output_left + output_bounds.width;
    const output_bottom = output_top + output_bounds.height;
    const local = popupPosition(rules, false, false);
    var global_x = parent_x + local.x;
    var global_y = parent_y + local.y;

    if (rules.adjustment.flip_x and axisConstrained(global_x, width, output_left, output_right)) {
        const flipped = popupPosition(rules, true, false);
        const flipped_global = parent_x + flipped.x;
        if (!axisConstrained(flipped_global, width, output_left, output_right)) {
            global_x = flipped_global;
        }
    }
    if (rules.adjustment.flip_y and axisConstrained(global_y, height, output_top, output_bottom)) {
        const flipped = popupPosition(rules, false, true);
        const flipped_global = parent_y + flipped.y;
        if (!axisConstrained(flipped_global, height, output_top, output_bottom)) {
            global_y = flipped_global;
        }
    }

    if (rules.adjustment.slide_x and axisConstrained(global_x, width, output_left, output_right)) {
        global_x = std.math.clamp(global_x, output_left, @max(output_right - width, output_left));
    }
    if (rules.adjustment.slide_y and axisConstrained(global_y, height, output_top, output_bottom)) {
        global_y = std.math.clamp(global_y, output_top, @max(output_bottom - height, output_top));
    }

    if (rules.adjustment.resize_x and axisConstrained(global_x, width, output_left, output_right)) {
        const left = std.math.clamp(global_x, output_left, @max(output_right - 1, output_left));
        const right = std.math.clamp(global_x + width, left + 1, @max(output_right, left + 1));
        global_x = left;
        width = right - left;
    }
    if (rules.adjustment.resize_y and axisConstrained(global_y, height, output_top, output_bottom)) {
        const top = std.math.clamp(global_y, output_top, @max(output_bottom - 1, output_top));
        const bottom = std.math.clamp(global_y + height, top + 1, @max(output_bottom, top + 1));
        global_y = top;
        height = bottom - top;
    }

    return .{
        .position = .{
            .x = clampI32(global_x - parent_x),
            .y = clampI32(global_y - parent_y),
        },
        .dimensions = .{
            .width = @intCast(@min(width, std.math.maxInt(i32))),
            .height = @intCast(@min(height, std.math.maxInt(i32))),
        },
    };
}

const Position64 = struct {
    x: i64,
    y: i64,
};

fn popupPosition(rules: Rules, flip_x: bool, flip_y: bool) Position64 {
    const anchor_rect = rules.anchor_rect.?;
    const size = rules.size.?;
    const anchor = flipAnchor(rules.anchor, flip_x, flip_y);
    const gravity = flipGravity(rules.gravity, flip_x, flip_y);
    const anchor_x = switch (anchor) {
        .left, .top_left, .bottom_left => @as(i64, anchor_rect.x),
        .right, .top_right, .bottom_right => @as(i64, anchor_rect.x) + anchor_rect.width,
        else => @as(i64, anchor_rect.x) + @divTrunc(@as(i64, anchor_rect.width), 2),
    };
    const anchor_y = switch (anchor) {
        .top, .top_left, .top_right => @as(i64, anchor_rect.y),
        .bottom, .bottom_left, .bottom_right => @as(i64, anchor_rect.y) + anchor_rect.height,
        else => @as(i64, anchor_rect.y) + @divTrunc(@as(i64, anchor_rect.height), 2),
    };
    const x = switch (gravity) {
        .left, .top_left, .bottom_left => anchor_x - size.width,
        .right, .top_right, .bottom_right => anchor_x,
        else => anchor_x - @divTrunc(@as(i64, size.width), 2),
    };
    const y = switch (gravity) {
        .top, .top_left, .top_right => anchor_y - size.height,
        .bottom, .bottom_left, .bottom_right => anchor_y,
        else => anchor_y - @divTrunc(@as(i64, size.height), 2),
    };
    return .{
        .x = x + rules.offset.x,
        .y = y + rules.offset.y,
    };
}

fn flipAnchor(
    anchor: xdg.Positioner.Anchor,
    flip_x: bool,
    flip_y: bool,
) xdg.Positioner.Anchor {
    var result = anchor;
    if (flip_x) result = switch (result) {
        .left => .right,
        .right => .left,
        .top_left => .top_right,
        .top_right => .top_left,
        .bottom_left => .bottom_right,
        .bottom_right => .bottom_left,
        else => result,
    };
    if (flip_y) result = switch (result) {
        .top => .bottom,
        .bottom => .top,
        .top_left => .bottom_left,
        .bottom_left => .top_left,
        .top_right => .bottom_right,
        .bottom_right => .top_right,
        else => result,
    };
    return result;
}

fn flipGravity(
    gravity: xdg.Positioner.Gravity,
    flip_x: bool,
    flip_y: bool,
) xdg.Positioner.Gravity {
    var result = gravity;
    if (flip_x) result = switch (result) {
        .left => .right,
        .right => .left,
        .top_left => .top_right,
        .top_right => .top_left,
        .bottom_left => .bottom_right,
        .bottom_right => .bottom_left,
        else => result,
    };
    if (flip_y) result = switch (result) {
        .top => .bottom,
        .bottom => .top,
        .top_left => .bottom_left,
        .bottom_left => .top_left,
        .top_right => .bottom_right,
        .bottom_right => .top_right,
        else => result,
    };
    return result;
}

fn axisConstrained(position: i64, size: i64, minimum: i64, maximum: i64) bool {
    return position < minimum or position + size > maximum;
}

fn clampI32(value: i64) i32 {
    return @intCast(std.math.clamp(
        value,
        @as(i64, std.math.minInt(i32)),
        @as(i64, std.math.maxInt(i32)),
    ));
}

test "xdg positioner derives popup geometry from anchor and gravity" {
    const placement = place(.{
        .size = .{ .width = 120, .height = 80 },
        .anchor_rect = .{ .x = 10, .y = 20, .width = 30, .height = 40 },
        .anchor = .bottom_left,
        .gravity = .bottom_right,
        .offset = .{ .x = 3, .y = 4 },
    }, .{ .x = 100, .y = 50 }, .{ .x = 0, .y = 0, .width = 1280, .height = 720 });

    try std.testing.expectEqual(Scene.Position{ .x = 13, .y = 64 }, placement.position);
    try std.testing.expectEqual(Size{ .width = 120, .height = 80 }, placement.dimensions);
}

test "xdg positioner flips before sliding constrained popups" {
    const placement = place(.{
        .size = .{ .width = 200, .height = 100 },
        .anchor_rect = .{ .x = 80, .y = 20, .width = 20, .height = 20 },
        .anchor = .right,
        .gravity = .right,
        .adjustment = .{ .flip_x = true, .slide_y = true },
    }, .{ .x = 2430, .y = 450 }, .{ .x = 1280, .y = -200, .width = 1280, .height = 720 });

    try std.testing.expectEqual(Scene.Position{ .x = -120, .y = -30 }, placement.position);
    try std.testing.expectEqual(Size{ .width = 200, .height = 100 }, placement.dimensions);
}

test "xdg positioner resizes a popup to the output boundary" {
    const placement = place(.{
        .size = .{ .width = 400, .height = 300 },
        .anchor_rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 },
        .anchor = .top_left,
        .gravity = .bottom_right,
        .adjustment = .{ .resize_x = true, .resize_y = true },
    }, .{}, .{ .x = 0, .y = 0, .width = 320, .height = 200 });

    try std.testing.expectEqual(Scene.Position{}, placement.position);
    try std.testing.expectEqual(Size{ .width = 320, .height = 200 }, placement.dimensions);
}
