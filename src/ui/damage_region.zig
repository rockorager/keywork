//! Small, allocation-free region used to carry repaint damage.

const std = @import("std");
const Rect = @import("types.zig").Rect;

pub const DamageRegion = struct {
    rects: [max_rects]Rect = undefined,
    len: u8 = 0,

    /// Keeps retained render nodes allocation-free while preserving the
    /// disjoint regions normally produced by widgets and canvas commits.
    pub const max_rects = 32;

    pub fn slice(self: *const DamageRegion) []const Rect {
        return self.rects[0..self.len];
    }

    pub fn isEmpty(self: *const DamageRegion) bool {
        return self.len == 0;
    }

    pub fn clear(self: *DamageRegion) void {
        self.len = 0;
    }

    pub fn add(self: *DamageRegion, rect: Rect) void {
        if (!valid(rect)) return;

        var merged = rect;
        var index: usize = 0;
        while (index < self.len) {
            const current = self.rects[index];
            if (!canMerge(current, merged)) {
                index += 1;
                continue;
            }
            merged = unionRect(current, merged);
            self.len -= 1;
            self.rects[index] = self.rects[self.len];
            index = 0;
        }

        if (self.len < max_rects) {
            self.rects[self.len] = merged;
            self.len += 1;
            return;
        }

        // A pathological producer must not make damage storage unbounded.
        // Conservatively collapse only after the explicit region budget is
        // exhausted; normal disjoint commits retain every rectangle.
        var collapsed = merged;
        for (self.slice()) |current| collapsed = unionRect(collapsed, current);
        self.rects[0] = collapsed;
        self.len = 1;
    }

    pub fn addSlice(self: *DamageRegion, rects: []const Rect) void {
        for (rects) |rect| self.add(rect);
    }

    pub fn addRegion(self: *DamageRegion, other: *const DamageRegion) void {
        self.addSlice(other.slice());
    }

    pub fn intersect(self: *DamageRegion, clip: Rect) void {
        var result: DamageRegion = .{};
        for (self.slice()) |rect| result.add(rect.intersect(clip));
        self.* = result;
    }

    pub fn bounds(self: *const DamageRegion) ?Rect {
        if (self.len == 0) return null;
        var result = self.rects[0];
        for (self.slice()[1..]) |rect| result = unionRect(result, rect);
        return result;
    }

    fn valid(rect: Rect) bool {
        return std.math.isFinite(rect.x) and std.math.isFinite(rect.y) and
            std.math.isFinite(rect.width) and std.math.isFinite(rect.height) and
            rect.width > 0 and rect.height > 0;
    }

    fn canMerge(a: Rect, b: Rect) bool {
        const intersection = a.intersect(b);
        if (!intersection.isEmpty()) return true;

        // Merge edge-adjacent rectangles only when their union is still a
        // rectangle. Corner contact and L shapes remain disjoint.
        const same_vertical_span = a.y == b.y and a.height == b.height;
        const horizontal_touch = a.x + a.width == b.x or b.x + b.width == a.x;
        const same_horizontal_span = a.x == b.x and a.width == b.width;
        const vertical_touch = a.y + a.height == b.y or b.y + b.height == a.y;
        return (same_vertical_span and horizontal_touch) or
            (same_horizontal_span and vertical_touch);
    }

    fn unionRect(a: Rect, b: Rect) Rect {
        const left = @min(a.x, b.x);
        const top = @min(a.y, b.y);
        const right = @max(a.x + a.width, b.x + b.width);
        const bottom = @max(a.y + a.height, b.y + b.height);
        return .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
    }
};

test "damage region preserves disjoint rectangles" {
    var region: DamageRegion = .{};
    region.add(.{ .x = 1, .y = 1, .width = 2, .height = 2 });
    region.add(.{ .x = 10, .y = 10, .width = 3, .height = 3 });
    try std.testing.expectEqual(@as(usize, 2), region.slice().len);
    try std.testing.expectEqual(Rect{ .x = 1, .y = 1, .width = 12, .height = 12 }, region.bounds().?);
}

test "damage region merges overlap and rectangular adjacency" {
    var region: DamageRegion = .{};
    region.add(.{ .x = 0, .y = 0, .width = 4, .height = 4 });
    region.add(.{ .x = 3, .y = 2, .width = 3, .height = 2 });
    region.add(.{ .x = 6, .y = 0, .width = 2, .height = 4 });
    try std.testing.expectEqual(@as(usize, 1), region.slice().len);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 8, .height = 4 }, region.slice()[0]);
}

test "damage region clips each rectangle without filling gaps" {
    var region: DamageRegion = .{};
    region.add(.{ .x = -2, .y = 1, .width = 4, .height = 2 });
    region.add(.{ .x = 8, .y = 1, .width = 4, .height = 2 });
    region.intersect(.{ .x = 0, .y = 0, .width = 10, .height = 10 });
    try std.testing.expectEqual(@as(usize, 2), region.slice().len);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 1, .width = 2, .height = 2 }, region.slice()[0]);
    try std.testing.expectEqual(Rect{ .x = 8, .y = 1, .width = 2, .height = 2 }, region.slice()[1]);
}
