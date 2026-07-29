//! Stateful, protocol-neutral workspace layouts.

const std = @import("std");
const Direction = @import("../command.zig").Direction;
const types = @import("types.zig");
const TiledLayout = @import("TiledLayout.zig");

pub const Kind = enum {
    tiled,
};

pub const Tiled = TiledLayout;
pub const DropPosition = TiledLayout.DropPosition;

pub const Layout = union(enum) {
    tiled: Tiled,

    pub const Resize = union(enum) {
        tiled: Tiled.Resize,
    };

    pub fn init(kind: Kind) Layout {
        return switch (kind) {
            .tiled => .{ .tiled = .{} },
        };
    }

    pub fn deinit(self: *Layout, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .tiled => |*layout| layout.deinit(allocator),
        }
    }

    pub fn ensureWindowCapacity(
        self: *Layout,
        allocator: std.mem.Allocator,
        additional_count: usize,
    ) error{OutOfMemory}!void {
        switch (self.*) {
            .tiled => |*layout| try layout.ensureWindowCapacity(allocator, additional_count),
        }
    }

    pub fn setUsableArea(self: *Layout, usable: types.Rect) void {
        switch (self.*) {
            .tiled => |*layout| layout.setUsableArea(usable),
        }
    }

    pub fn setGaps(self: *Layout, inner_gap: u32, outer_gap: u32) void {
        switch (self.*) {
            .tiled => |*layout| {
                layout.inner_gap = inner_gap;
                layout.outer_gap = outer_gap;
            },
        }
    }

    pub fn windowAdded(
        self: *Layout,
        allocator: std.mem.Allocator,
        id: types.WindowId,
        focused: ?types.WindowId,
    ) error{OutOfMemory}!void {
        switch (self.*) {
            .tiled => |*layout| try layout.windowAdded(allocator, id, focused),
        }
    }

    pub fn windowRemoved(self: *Layout, id: types.WindowId) void {
        switch (self.*) {
            .tiled => |*layout| layout.windowRemoved(id),
        }
    }

    pub fn nextWindow(
        self: *const Layout,
        current: types.WindowId,
        reverse: bool,
    ) ?types.WindowId {
        return switch (self.*) {
            .tiled => |*layout| layout.nextWindow(current, reverse),
        };
    }

    /// Finds a tiled neighbor by walking split ancestors. `focus_history` is
    /// ordered least- to most-recently focused and `eligible` contains the
    /// tiled leaves that may receive focus.
    pub fn directionalWindow(
        self: *const Layout,
        current: types.WindowId,
        direction: Direction,
        eligible: []const types.WindowId,
        focus_history: []const types.WindowId,
        wrap: bool,
    ) ?types.WindowId {
        return switch (self.*) {
            .tiled => |*layout| layout.directionalWindow(
                current,
                direction,
                eligible,
                focus_history,
                wrap,
            ),
        };
    }

    pub fn relativeDirection(
        self: *const Layout,
        current: types.WindowId,
        reverse: bool,
    ) ?Direction {
        return switch (self.*) {
            .tiled => |*layout| layout.relativeDirection(current, reverse),
        };
    }

    pub fn usesTreeOrder(self: *const Layout) bool {
        return switch (self.*) {
            .tiled => true,
        };
    }

    pub fn swapWindows(self: *Layout, first: types.WindowId, second: types.WindowId) void {
        switch (self.*) {
            .tiled => |*layout| layout.swapWindows(first, second),
        }
    }

    pub fn repositionWindow(
        self: *Layout,
        source: types.WindowId,
        target: types.WindowId,
        position: DropPosition,
    ) void {
        if (position == .center) {
            self.swapWindows(source, target);
            return;
        }
        switch (self.*) {
            .tiled => |*layout| layout.repositionWindow(source, target, position),
        }
    }

    pub fn repositionWindowAtRoot(
        self: *Layout,
        source: types.WindowId,
        position: DropPosition,
    ) void {
        std.debug.assert(position == .left or position == .right);
        switch (self.*) {
            .tiled => |*layout| layout.repositionWindowAtRoot(source, position),
        }
    }

    pub fn beginResize(
        self: *const Layout,
        id: types.WindowId,
        pointer_x: f64,
        pointer_y: f64,
        edge_threshold: f64,
    ) ?Resize {
        return switch (self.*) {
            .tiled => |layout| if (layout.beginResize(
                id,
                pointer_x,
                pointer_y,
                edge_threshold,
            )) |resize|
                .{ .tiled = resize }
            else
                null,
        };
    }

    pub fn updateResize(
        self: *Layout,
        resize: Resize,
        pointer_x: f64,
        pointer_y: f64,
    ) bool {
        return switch (self.*) {
            .tiled => |*layout| switch (resize) {
                .tiled => |value| layout.updateResize(value, pointer_x, pointer_y),
            },
        };
    }

    pub fn cancelResize(self: *Layout, resize: Resize) bool {
        return switch (self.*) {
            .tiled => |*layout| switch (resize) {
                .tiled => |value| layout.cancelResize(value),
            },
        };
    }

    pub fn arrange(
        self: *Layout,
        allocator: std.mem.Allocator,
        windows: []const types.WindowInput,
        usable: types.Rect,
        _: ?types.WindowId,
    ) !std.ArrayList(types.LayoutPlan) {
        return switch (self.*) {
            .tiled => |*layout| tiled: {
                const plans = try layout.arrange(allocator, windows, usable);
                setTiledShadowClips(plans.items, usable);
                break :tiled plans;
            },
        };
    }
};

fn setTiledShadowClips(plans: []types.LayoutPlan, usable: types.Rect) void {
    for (plans) |*plan| plan.shadow_clip = usable;
}

fn input(index: u32, width: u32) types.WindowInput {
    return .{ .id = types.id(index), .current = types.Size.init(width, 40) };
}

test "gap configuration applies to tiled layout" {
    var layout: Layout = .init(.tiled);
    defer layout.deinit(std.testing.allocator);
    layout.setGaps(20, 24);
    try std.testing.expectEqual(@as(u32, 20), layout.tiled.inner_gap);
    try std.testing.expectEqual(@as(u32, 24), layout.tiled.outer_gap);
}

test "tiled shadows share the usable area without neighbor clipping" {
    var layout: Layout = .{ .tiled = .{ .outer_gap = 8, .inner_gap = 8 } };
    defer layout.deinit(std.testing.allocator);
    const usable: types.Rect = .{
        .x = 10,
        .y = 20,
        .size = types.Size.init(100, 100),
    };
    try layout.windowAdded(std.testing.allocator, types.id(0), null);
    try layout.windowAdded(std.testing.allocator, types.id(1), types.id(0));
    var plans = try layout.arrange(
        std.testing.allocator,
        &.{ input(0, 10), input(1, 10) },
        usable,
        null,
    );
    defer plans.deinit(std.testing.allocator);

    try std.testing.expectEqual(usable, plans.items[0].shadow_clip.?);
    try std.testing.expectEqual(usable, plans.items[1].shadow_clip.?);
}
