//! Rectangle-region operations shared by Wayland state and damage tracking.

const Self = @This();

const std = @import("std");

const pixman = @cImport({
    @cInclude("pixman.h");
});

region: pixman.pixman_region32_t,

pub const Error = error{OutOfMemory};

pub const Rectangle = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

pub const RectangleIterator = struct {
    boxes: []const pixman.pixman_box32_t,
    index: usize = 0,

    pub fn next(self: *RectangleIterator) ?Rectangle {
        if (self.index >= self.boxes.len) return null;
        const box = self.boxes[self.index];
        self.index += 1;
        std.debug.assert(box.x2 > box.x1 and box.y2 > box.y1);
        return .{
            .x = box.x1,
            .y = box.y1,
            .width = @intCast(box.x2 - box.x1),
            .height = @intCast(box.y2 - box.y1),
        };
    }
};

pub fn init() Self {
    var self: Self = undefined;
    pixman.pixman_region32_init(&self.region);
    return self;
}

pub fn deinit(self: *Self) void {
    pixman.pixman_region32_fini(&self.region);
    self.* = undefined;
}

pub fn clear(self: *Self) void {
    pixman.pixman_region32_clear(&self.region);
}

pub fn setRectangle(self: *Self, x: i32, y: i32, width: u32, height: u32) void {
    pixman.pixman_region32_fini(&self.region);
    if (width == 0 or height == 0) {
        pixman.pixman_region32_init(&self.region);
    } else {
        pixman.pixman_region32_init_rect(&self.region, x, y, width, height);
    }
}

pub fn isEmpty(self: *const Self) bool {
    return pixman.pixman_region32_not_empty(@constCast(&self.region)) == 0;
}

pub fn rectangleIterator(self: *const Self) RectangleIterator {
    var count: c_int = 0;
    const boxes = pixman.pixman_region32_rectangles(
        @constCast(&self.region),
        &count,
    );
    return .{ .boxes = boxes[0..@intCast(count)] };
}

pub fn copyFrom(self: *Self, other: *const Self) Error!void {
    if (pixman.pixman_region32_copy(&self.region, &other.region) == 0) {
        return error.OutOfMemory;
    }
}

pub fn unionWith(self: *Self, other: *const Self) Error!void {
    if (pixman.pixman_region32_union(&self.region, &self.region, &other.region) == 0) {
        return error.OutOfMemory;
    }
}

pub fn intersectWith(self: *Self, other: *const Self) Error!void {
    if (pixman.pixman_region32_intersect(&self.region, &self.region, &other.region) == 0) {
        return error.OutOfMemory;
    }
}

pub fn add(self: *Self, x: i32, y: i32, width: i32, height: i32) Error!void {
    if (width <= 0 or height <= 0) return;

    if (pixman.pixman_region32_union_rect(
        &self.region,
        &self.region,
        x,
        y,
        @intCast(width),
        @intCast(height),
    ) == 0) {
        return error.OutOfMemory;
    }
}

/// Removes every rectangle of `other` from `self` in one pass. Prefer this
/// over repeated `subtract` calls: each of those builds a temporary region
/// and rewrites `self`, so subtracting a region rectangle by rectangle costs
/// one full region rewrite per rectangle.
pub fn subtractRegion(self: *Self, other: *const Self) Error!void {
    if (pixman.pixman_region32_subtract(
        &self.region,
        &self.region,
        @constCast(&other.region),
    ) == 0) {
        return error.OutOfMemory;
    }
}

pub fn subtract(self: *Self, x: i32, y: i32, width: i32, height: i32) Error!void {
    if (width <= 0 or height <= 0) return;

    var rectangle: pixman.pixman_region32_t = undefined;
    pixman.pixman_region32_init_rect(
        &rectangle,
        x,
        y,
        @intCast(width),
        @intCast(height),
    );
    defer pixman.pixman_region32_fini(&rectangle);

    if (pixman.pixman_region32_subtract(&self.region, &self.region, &rectangle) == 0) {
        return error.OutOfMemory;
    }
}

pub fn translate(self: *Self, x: i32, y: i32) void {
    pixman.pixman_region32_translate(&self.region, x, y);
}

pub fn contains(self: *const Self, x: i32, y: i32) bool {
    return pixman.pixman_region32_contains_point(&self.region, x, y, null) != 0;
}

pub fn coversRectangle(self: *const Self, x: i32, y: i32, width: u32, height: u32) bool {
    if (width == 0 or height == 0 or
        width > std.math.maxInt(i32) or height > std.math.maxInt(i32)) return false;
    var box: pixman.pixman_box32_t = .{
        .x1 = x,
        .y1 = y,
        .x2 = x +| @as(i32, @intCast(width)),
        .y2 = y +| @as(i32, @intCast(height)),
    };
    return pixman.pixman_region32_contains_rectangle(
        @constCast(&self.region),
        &box,
    ) == pixman.PIXMAN_REGION_IN;
}

pub const Point = struct {
    x: f64,
    y: f64,
};

pub fn containsPoint(self: *const Self, point: Point) bool {
    if (!std.math.isFinite(point.x) or !std.math.isFinite(point.y)) return false;
    const x = floorToI32(point.x) orelse return false;
    const y = floorToI32(point.y) orelse return false;
    return self.contains(x, y);
}

/// Clip a motion segment to this region while allowing motion along edges.
pub fn confine(self: *const Self, start: Point, target: Point) ?Point {
    if (!std.math.isFinite(start.x) or !std.math.isFinite(start.y) or
        !std.math.isFinite(target.x) or !std.math.isFinite(target.y)) return null;
    const start_x = floorToI32(start.x) orelse return null;
    const start_y = floorToI32(start.y) orelse return null;
    var box: pixman.pixman_box32_t = undefined;
    if (pixman.pixman_region32_contains_point(
        &self.region,
        start_x,
        start_y,
        &box,
    ) == 0) return null;
    const rectangle_count: usize = @intCast(pixman.pixman_region32_n_rects(&self.region));
    return self.confineToBox(start, target, box, rectangle_count *| 4 +| 8);
}

fn confineToBox(
    self: *const Self,
    start: Point,
    target: Point,
    box: pixman.pixman_box32_t,
    steps_remaining: usize,
) Point {
    // Wayland coordinates have 1/256 precision. Stay in the final cell of the
    // rectangle rather than snapping a whole pixel away from its exclusive edge.
    const maximum_x = @as(f64, @floatFromInt(box.x2)) - 1.0 / 256.0;
    const maximum_y = @as(f64, @floatFromInt(box.y2)) - 1.0 / 256.0;
    const clamped: Point = .{
        .x = std.math.clamp(target.x, @as(f64, @floatFromInt(box.x1)), maximum_x),
        .y = std.math.clamp(target.y, @as(f64, @floatFromInt(box.y1)), maximum_y),
    };
    if (clamped.x == target.x and clamped.y == target.y) return target;
    if (steps_remaining == 0) return clamped;

    const dx = target.x - start.x;
    const dy = target.y - start.y;
    const x_fraction = if (dx == 0)
        std.math.inf(f64)
    else
        @abs(clamped.x - start.x) / @abs(dx);
    const y_fraction = if (dy == 0)
        std.math.inf(f64)
    else
        @abs(clamped.y - start.y) / @abs(dy);
    const fraction = @min(x_fraction, y_fraction);
    const boundary: Point = .{
        .x = std.math.clamp(
            start.x + fraction * dx,
            @as(f64, @floatFromInt(box.x1)),
            maximum_x,
        ),
        .y = std.math.clamp(
            start.y + fraction * dy,
            @as(f64, @floatFromInt(box.y1)),
            maximum_y,
        ),
    };

    const boundary_x = floorToI32(boundary.x) orelse return boundary;
    const boundary_y = floorToI32(boundary.y) orelse return boundary;
    const probe_x = addDirection(boundary_x, dx) orelse return boundary;
    const probe_y = addDirection(boundary_y, dy) orelse return boundary;
    var next_box: pixman.pixman_box32_t = undefined;
    if (pixman.pixman_region32_contains_point(
        &self.region,
        probe_x,
        probe_y,
        &next_box,
    ) != 0) {
        return self.confineToBox(start, target, next_box, steps_remaining - 1);
    }
    if (dx == 0 or dy == 0) return boundary;

    const on_x_edge = boundary.x == @as(f64, @floatFromInt(box.x1)) or
        boundary.x == maximum_x;
    const on_y_edge = boundary.y == @as(f64, @floatFromInt(box.y1)) or
        boundary.y == maximum_y;
    if (on_x_edge == on_y_edge) {
        const vertical = self.confineToBox(
            boundary,
            .{ .x = boundary.x, .y = target.y },
            box,
            steps_remaining - 1,
        );
        const horizontal = self.confineToBox(
            boundary,
            .{ .x = target.x, .y = boundary.y },
            box,
            steps_remaining - 1,
        );
        if (@abs(horizontal.x - boundary.x) > @abs(vertical.y - boundary.y)) {
            return .{ .x = horizontal.x, .y = boundary.y };
        }
        return .{ .x = boundary.x, .y = vertical.y };
    }
    return if (on_x_edge)
        self.confineToBox(
            boundary,
            .{ .x = boundary.x, .y = target.y },
            box,
            steps_remaining - 1,
        )
    else
        self.confineToBox(
            boundary,
            .{ .x = target.x, .y = boundary.y },
            box,
            steps_remaining - 1,
        );
}

fn floorToI32(value: f64) ?i32 {
    const floored = @floor(value);
    if (floored < std.math.minInt(i32) or floored > std.math.maxInt(i32)) return null;
    return @intFromFloat(floored);
}

fn addDirection(value: i32, delta: f64) ?i32 {
    if (delta > 0) return std.math.add(i32, value, 1) catch null;
    if (delta < 0) return std.math.sub(i32, value, 1) catch null;
    return value;
}

test "region unions and subtracts rectangles" {
    var region = Self.init();
    defer region.deinit();

    try region.add(0, 0, 8, 8);
    try region.subtract(2, 2, 4, 4);

    try std.testing.expect(region.contains(1, 1));
    try std.testing.expect(!region.contains(3, 3));
    try std.testing.expect(region.contains(7, 7));
}

test "region copy has independent storage" {
    var source = Self.init();
    defer source.deinit();
    try source.add(0, 0, 4, 4);

    var copy = Self.init();
    defer copy.deinit();
    try copy.copyFrom(&source);
    try copy.subtract(0, 0, 2, 2);

    try std.testing.expect(source.contains(1, 1));
    try std.testing.expect(!copy.contains(1, 1));
}

test "rectangle iteration preserves disjoint damage" {
    var region = Self.init();
    defer region.deinit();
    try region.add(1, 2, 3, 4);
    try region.add(10, 20, 5, 6);

    var iterator = region.rectangleIterator();
    try std.testing.expectEqual(
        Rectangle{ .x = 1, .y = 2, .width = 3, .height = 4 },
        iterator.next().?,
    );
    try std.testing.expectEqual(
        Rectangle{ .x = 10, .y = 20, .width = 5, .height = 6 },
        iterator.next().?,
    );
    try std.testing.expectEqual(@as(?Rectangle, null), iterator.next());
}

test "empty and translated regions expose current state" {
    var region = Self.init();
    defer region.deinit();
    try std.testing.expect(region.isEmpty());
    try region.add(1, 2, 3, 4);
    try std.testing.expect(!region.isEmpty());
    region.translate(5, -1);

    var iterator = region.rectangleIterator();
    try std.testing.expectEqual(
        Rectangle{ .x = 6, .y = 1, .width = 3, .height = 4 },
        iterator.next().?,
    );

    region.setRectangle(-2, -3, 7, 8);
    iterator = region.rectangleIterator();
    try std.testing.expectEqual(
        Rectangle{ .x = -2, .y = -3, .width = 7, .height = 8 },
        iterator.next().?,
    );
}

test "rectangle coverage can span multiple region boxes" {
    var region = Self.init();
    defer region.deinit();
    try region.add(0, 0, 4, 2);
    try region.add(0, 2, 4, 2);

    try std.testing.expect(region.coversRectangle(0, 0, 4, 4));
    try std.testing.expect(!region.coversRectangle(0, 0, 5, 4));
    try std.testing.expect(!region.coversRectangle(0, 0, 0, 4));
}

test "region confinement stops at a rectangular edge" {
    var region = Self.init();
    defer region.deinit();
    try region.add(0, 0, 10, 10);

    const point = region.confine(.{ .x = 5.5, .y = 5.5 }, .{ .x = 20, .y = 7.5 }).?;
    try std.testing.expectEqual(@as(f64, 10 - 1.0 / 256.0), point.x);
    try std.testing.expectEqual(@as(f64, 7.5), point.y);
}

test "region confinement slides along an inside corner" {
    var region = Self.init();
    defer region.deinit();
    try region.add(0, 0, 5, 10);
    try region.add(5, 5, 5, 5);

    const point = region.confine(.{ .x = 2, .y = 2 }, .{ .x = 8, .y = 4 }).?;
    try std.testing.expectEqual(@as(f64, 5 - 1.0 / 256.0), point.x);
    try std.testing.expectEqual(@as(f64, 4), point.y);
}
