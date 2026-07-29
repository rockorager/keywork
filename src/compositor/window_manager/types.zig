//! Protocol-neutral identifiers and layout geometry.

const std = @import("std");

pub const WindowId = struct {
    index: u32,
    generation: u32,

    pub fn eql(a: WindowId, b: WindowId) bool {
        return a.index == b.index and a.generation == b.generation;
    }
};

pub const TagId = u32;

pub const Size = struct {
    width: u32,
    height: u32,

    pub fn init(width: u32, height: u32) Size {
        std.debug.assert(width > 0 and height > 0);
        return .{ .width = width, .height = height };
    }
};

pub const Rect = struct {
    x: i32,
    y: i32,
    size: Size,
};

pub const SizeConstraints = struct {
    min_width: u32 = 1,
    min_height: u32 = 1,
    max_width: ?u32 = null,
    max_height: ?u32 = null,
};

pub const WindowInput = struct {
    id: WindowId,
    constraints: SizeConstraints = .{},
    current: Size,
};

pub const TiledEdges = packed struct(u4) {
    top: bool = false,
    right: bool = false,
    bottom: bool = false,
    left: bool = false,
};

pub const LayoutPlan = struct {
    id: WindowId,
    rect: Rect,
    visible: bool,
    clip: ?Rect = null,
    shadow_clip: ?Rect = null,
    tiled_edges: TiledEdges = .{},
};

pub fn id(index: u32) WindowId {
    return .{ .index = index, .generation = 1 };
}
