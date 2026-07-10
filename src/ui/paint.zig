//! paint behavior for the retained UI model.

const std = @import("std");
const z2d = @import("z2d");
const model = @import("model.zig");

const Widget = model.Widget;
const Element = model.Element;
const RenderNode = model.RenderNode;
const Color = model.Color;
const colors = model.colors;
const Point = model.Point;
const Rect = model.Rect;
const KeyInput = model.KeyInput;
const ShortcutKey = model.ShortcutKey;
const Intent = model.Intent;
const CursorShape = model.CursorShape;
const DisplayList = model.DisplayList;
const ResolvedTextStyle = model.ResolvedTextStyle;

pub fn paint(allocator: std.mem.Allocator, node: *const RenderNode, display_list: *DisplayList) !void {
    return paintScaled(allocator, node, display_list, 1);
}

pub fn paintScaled(allocator: std.mem.Allocator, node: *const RenderNode, display_list: *DisplayList, scale: f32) !void {
    switch (node.kind) {
        .render_object => {
            const render_object = node.render_object orelse return error.MissingRenderObject;
            try render_object.paint(.{ .allocator = allocator, .rect = node.rect, .scale = scale, .display_list = display_list });
        },
        .box => {
            if (node.box_radius > 0) {
                try paintRoundedBox(allocator, display_list, node.rect, node.background, node.box_border, node.box_border_width, node.box_radius, scale);
            } else {
                if (node.background.a > 0) try display_list.fillRect(allocator, node.rect, node.background);
                if (node.box_border) |border| try paintBorder(allocator, display_list, node.rect, border, node.box_border_width);
            }
        },
        .separator => {
            const rect: Rect = switch (node.separator_axis) {
                .horizontal => .{
                    .x = node.rect.x,
                    .y = node.rect.y + node.separator_margin,
                    .width = node.rect.width,
                    .height = @max(0, node.rect.height - node.separator_margin * 2),
                },
                .vertical => .{
                    .x = node.rect.x + node.separator_margin,
                    .y = node.rect.y,
                    .width = @max(0, node.rect.width - node.separator_margin * 2),
                    .height = node.rect.height,
                },
            };
            if (node.background.a > 0) try display_list.fillRect(allocator, rect, node.background);
        },
        .text_input => {
            const border = if (node.focused) node.focused_border else node.border;
            if (node.box_radius > 0) {
                try paintRoundedBox(allocator, display_list, node.rect, node.background, border, 1, node.box_radius, scale);
            } else {
                try display_list.fillRect(allocator, node.rect, node.background);
                try paintBorder(allocator, display_list, node.rect, border, 1);
            }
            const value = node.text orelse "";
            const visible_text = if (value.len > 0) value else node.placeholder orelse "";
            const text_color = if (value.len > 0) node.foreground else node.placeholder_foreground;
            // Overflowing text and caret must not paint outside the field.
            try display_list.pushClip(allocator, node.rect);
            try display_list.text(allocator, .{
                .x = node.rect.x + node.padding_x,
                .y = node.rect.y + node.padding_y,
            }, visible_text, .{ .color = text_color, .font_size = node.text_style.font_size });
            if (node.focused) {
                const caret_x = node.caret_x orelse node.rect.x + node.padding_x;
                try display_list.fillRect(allocator, .{
                    .x = caret_x,
                    .y = node.rect.y + node.padding_y,
                    .width = 1,
                    .height = @max(1, node.rect.height - node.padding_y * 2),
                }, node.foreground);
            }
            try display_list.popClip(allocator);
        },
        .text => if (node.text) |value| {
            try display_list.text(allocator, .{ .x = node.rect.x, .y = node.rect.y }, value, node.text_style);
        },
        .scroll, .list => try display_list.pushClip(allocator, node.rect),
        else => {},
    }

    for (node.children) |child| {
        try paintScaled(allocator, child, display_list, scale);
    }

    if (node.kind.isViewport()) {
        try paintScrollbars(allocator, node, display_list);
        try display_list.popClip(allocator);
    }
}

pub const scrollbar_thickness: f32 = 4;
const scrollbar_margin: f32 = 2;
const scrollbar_min_thumb: f32 = 12;
pub const scrollbar_color: Color = Color.argb(0x60, 0x80, 0x80, 0x88);
/// Extra pointer slop around the painted thumb so the thin bar is
/// grabbable.
const scrollbar_hit_slop: f32 = 4;

pub const ScrollbarAxis = enum { vertical, horizontal };

const ScrollbarGeometry = struct {
    thumb: Rect,
    /// Scroll offset change per pixel of thumb travel along the track;
    /// zero when the thumb fills the track and cannot move.
    drag_scale: f32,
};

/// Thumb geometry for one axis of a viewport node, or null when the
/// content does not overflow that axis. Single source for painting and
/// pointer hit testing.
fn scrollbarGeometry(node: *const RenderNode, axis: ScrollbarAxis) ?ScrollbarGeometry {
    std.debug.assert(node.kind.isViewport());
    const content = node.scroll_content;
    const viewport = switch (axis) {
        .vertical => node.rect.height,
        .horizontal => node.rect.width,
    };
    const extent = switch (axis) {
        .vertical => content.height,
        .horizontal => content.width,
    };
    if (extent <= viewport) return null;

    const track = viewport - scrollbar_margin * 2;
    const thumb = @max(scrollbar_min_thumb, track * viewport / extent);
    const max_offset = extent - viewport;
    const travel = track - thumb;
    const offset = switch (axis) {
        .vertical => node.scroll_offset.y,
        .horizontal => node.scroll_offset.x,
    };
    const along = if (travel > 0) travel * (offset / max_offset) else 0;
    return switch (axis) {
        .vertical => .{
            .thumb = .{
                .x = node.rect.x + node.rect.width - scrollbar_thickness - scrollbar_margin,
                .y = node.rect.y + scrollbar_margin + along,
                .width = scrollbar_thickness,
                .height = thumb,
            },
            .drag_scale = if (travel > 0) max_offset / travel else 0,
        },
        .horizontal => .{
            .thumb = .{
                .x = node.rect.x + scrollbar_margin + along,
                .y = node.rect.y + node.rect.height - scrollbar_thickness - scrollbar_margin,
                .width = thumb,
                .height = scrollbar_thickness,
            },
            .drag_scale = if (travel > 0) max_offset / travel else 0,
        },
    };
}

/// Paints proportional scrollbar thumbs for axes whose content overflows
/// the viewport, from the geometry recorded during layout.
fn paintScrollbars(allocator: std.mem.Allocator, node: *const RenderNode, display_list: *DisplayList) !void {
    std.debug.assert(node.kind.isViewport());
    inline for ([_]ScrollbarAxis{ .vertical, .horizontal }) |axis| {
        if (scrollbarGeometry(node, axis)) |geometry| {
            try display_list.fillRect(allocator, geometry.thumb, scrollbar_color);
        }
    }
}

pub const ScrollbarThumbHit = struct {
    id: []const u8,
    axis: ScrollbarAxis,
    /// Scroll offset change per pixel of pointer travel along the track.
    drag_scale: f32,
};

/// Finds the innermost scrollbar thumb under the pointer, with a small
/// slop so the thin thumb is grabbable.
pub fn hitTestScrollbarThumb(node: *const RenderNode, point: Point) ?ScrollbarThumbHit {
    if (node.kind.isViewport() and !node.rect.contains(point)) return null;
    var index = node.children.len;
    while (index > 0) {
        index -= 1;
        if (hitTestScrollbarThumb(node.children[index], point)) |hit| return hit;
    }
    if (!node.kind.isViewport()) return null;
    const id = node.scroll_id orelse return null;
    for ([_]ScrollbarAxis{ .vertical, .horizontal }) |axis| {
        const geometry = scrollbarGeometry(node, axis) orelse continue;
        const slop: Rect = .{
            .x = geometry.thumb.x - scrollbar_hit_slop,
            .y = geometry.thumb.y - scrollbar_hit_slop,
            .width = geometry.thumb.width + scrollbar_hit_slop * 2,
            .height = geometry.thumb.height + scrollbar_hit_slop * 2,
        };
        if (slop.contains(point)) return .{ .id = id, .axis = axis, .drag_scale = geometry.drag_scale };
    }
    return null;
}

fn paintBorder(allocator: std.mem.Allocator, display_list: *DisplayList, rect: Rect, color: Color, width: f32) !void {
    const clamped_width = @min(@max(0, width), @min(rect.width, rect.height) / 2);
    if (clamped_width <= 0) return;
    try display_list.fillRect(allocator, .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = clamped_width }, color);
    try display_list.fillRect(allocator, .{ .x = rect.x, .y = rect.y + rect.height - clamped_width, .width = rect.width, .height = clamped_width }, color);
    try display_list.fillRect(allocator, .{ .x = rect.x, .y = rect.y + clamped_width, .width = clamped_width, .height = @max(0, rect.height - clamped_width * 2) }, color);
    try display_list.fillRect(allocator, .{ .x = rect.x + rect.width - clamped_width, .y = rect.y + clamped_width, .width = clamped_width, .height = @max(0, rect.height - clamped_width * 2) }, color);
}

fn paintRoundedBox(
    allocator: std.mem.Allocator,
    display_list: *DisplayList,
    rect: Rect,
    background: Color,
    border: ?Color,
    border_width: f32,
    radius: f32,
    scale: f32,
) !void {
    if (rect.width <= 0 or rect.height <= 0) return;

    const render_scale = if (std.math.isFinite(scale) and scale > 0) scale else 1;
    const width = @max(1, @as(usize, @intFromFloat(@ceil(rect.width * render_scale))));
    const height = @max(1, @as(usize, @intFromFloat(@ceil(rect.height * render_scale))));
    const scaled_radius = @max(0, radius * render_scale);

    if (background.a > 0) {
        const cache_key = roundedRectCacheKey(width, height, scaled_radius, null);
        const alpha = if (display_list.cachedAlphaImage(cache_key, @intCast(width), @intCast(height))) |cached|
            cached
        else
            try roundedRectAlpha(allocator, width, height, scaled_radius, null);
        try display_list.alphaImage(allocator, rect, @intCast(width), @intCast(height), @constCast(alpha), background, cache_key);
    }

    if (border) |border_color| {
        const stroke_width = @min(@max(0, border_width * render_scale), @min(@as(f32, @floatFromInt(width)), @as(f32, @floatFromInt(height))) / 2);
        if (stroke_width > 0) {
            const cache_key = roundedRectCacheKey(width, height, scaled_radius, stroke_width);
            const alpha = if (display_list.cachedAlphaImage(cache_key, @intCast(width), @intCast(height))) |cached|
                cached
            else
                try roundedRectAlpha(allocator, width, height, scaled_radius, stroke_width);
            try display_list.alphaImage(allocator, rect, @intCast(width), @intCast(height), @constCast(alpha), border_color, cache_key);
        }
    }
}

/// Rasterizes an antialiased rounded-rect coverage mask with z2d. A fill
/// covers the whole shape; with stroke_width set, only the border band
/// between the outer rect and an inset inner rect is covered (even-odd fill
/// of two nested subpaths).
pub fn roundedRectAlpha(allocator: std.mem.Allocator, width: usize, height: usize, radius: f32, stroke_width: ?f32) ![]u8 {
    std.debug.assert(width > 0 and height > 0);
    const w: f64 = @floatFromInt(width);
    const h: f64 = @floatFromInt(height);

    var surface = try z2d.Surface.init(.image_surface_alpha8, allocator, @intCast(width), @intCast(height));
    defer surface.deinit(allocator);

    var path: z2d.Path = .empty;
    defer path.deinit(allocator);

    try appendRoundedRectPath(&path, allocator, 0, 0, w, h, radius);
    if (stroke_width) |stroke| {
        const inset: f64 = stroke;
        const inner_width = w - inset * 2;
        const inner_height = h - inset * 2;
        if (inner_width > 0 and inner_height > 0) {
            try appendRoundedRectPath(&path, allocator, inset, inset, inner_width, inner_height, @max(0, radius - stroke));
        }
    }

    const pattern: z2d.Pattern = .{ .opaque_pattern = .{ .pixel = .{ .alpha8 = .{ .a = 255 } } } };
    try z2d.painter.fill(allocator, &surface, &pattern, path.nodes.items, .{ .fill_rule = .even_odd });

    const alpha = try allocator.alloc(u8, width * height);
    for (surface.image_surface_alpha8.buf, alpha) |pixel, *value| value.* = pixel.a;
    return alpha;
}

fn appendRoundedRectPath(path: *z2d.Path, allocator: std.mem.Allocator, x: f64, y: f64, width: f64, height: f64, radius: f32) !void {
    const r = @min(@as(f64, radius), @min(width, height) / 2);
    if (r <= 0) {
        try path.moveTo(allocator, x, y);
        try path.lineTo(allocator, x + width, y);
        try path.lineTo(allocator, x + width, y + height);
        try path.lineTo(allocator, x, y + height);
        try path.close(allocator);
        return;
    }

    const half_pi = std.math.pi / 2.0;
    // The moveTo starts a fresh subpath; each arc connects to the previous
    // one with the straight edge segment.
    try path.moveTo(allocator, x + r, y);
    try path.arc(allocator, x + width - r, y + r, r, -half_pi, 0);
    try path.arc(allocator, x + width - r, y + height - r, r, 0, half_pi);
    try path.arc(allocator, x + r, y + height - r, r, half_pi, std.math.pi);
    try path.arc(allocator, x + r, y + r, r, std.math.pi, 3 * half_pi);
    try path.close(allocator);
}

fn roundedRectCacheKey(width: usize, height: usize, radius: f32, stroke_width: ?f32) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update("rounded-rect");
    hasher.update(std.mem.asBytes(&width));
    hasher.update(std.mem.asBytes(&height));
    hasher.update(std.mem.asBytes(&radius));
    if (stroke_width) |value| hasher.update(std.mem.asBytes(&value));
    return hasher.final();
}
