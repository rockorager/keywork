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
const RasterCache = @import("display.zig").RasterCache;
const ResolvedTextStyle = model.ResolvedTextStyle;

pub fn paint(allocator: std.mem.Allocator, node: *const RenderNode, display_list: *DisplayList, raster_cache: *RasterCache) !void {
    return paintScaled(allocator, node, display_list, raster_cache, 1);
}

pub fn paintScaled(allocator: std.mem.Allocator, node: *const RenderNode, display_list: *DisplayList, raster_cache: *RasterCache, scale: f32) !void {
    std.debug.assert(raster_cache.in_frame);
    return paintNode(allocator, node, display_list, raster_cache, scale, null);
}

/// Builds only the commands that can affect `damage`. The caller must use
/// this only with a backend that preserves pixels outside that region.
pub fn paintDamagedScaled(
    allocator: std.mem.Allocator,
    node: *const RenderNode,
    display_list: *DisplayList,
    raster_cache: *RasterCache,
    scale: f32,
    damage: Rect,
) !void {
    std.debug.assert(raster_cache.in_frame);
    if (damage.isEmpty()) return;
    return paintNode(allocator, node, display_list, raster_cache, scale, damage);
}

fn paintNode(
    allocator: std.mem.Allocator,
    node: *const RenderNode,
    display_list: *DisplayList,
    raster_cache: *RasterCache,
    scale: f32,
    cull_rect: ?Rect,
) !void {
    if (cull_rect) |cull| {
        const subtree_bounds = node.paintBounds() orelse return;
        if (subtree_bounds.intersect(cull).isEmpty()) return;
    }
    const paints_node = if (cull_rect) |cull|
        if (node.deriveOwnPaintBounds()) |bounds| !bounds.intersect(cull).isEmpty() else false
    else
        true;

    if (paints_node) switch (node.kind) {
        .render_object => {
            const render_object = node.render_object orelse return error.MissingRenderObject;
            try render_object.paint(.{ .allocator = allocator, .rect = node.rect, .scale = scale, .display_list = display_list, .raster_cache = raster_cache });
        },
        .box => {
            if (node.box_shadow) |shadow| try paintBoxShadow(allocator, display_list, raster_cache, node.rect, node.box_radius, shadow, scale);
            if (node.box_radius > 0) {
                try paintRoundedBox(allocator, display_list, raster_cache, node.rect, node.background, node.box_border, node.box_border_width, node.box_radius, scale);
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
            const border_width: f32 = if (node.focused) 2 else 1;
            if (node.box_radius > 0) {
                try paintRoundedBox(allocator, display_list, raster_cache, node.rect, node.background, border, border_width, node.box_radius, scale);
            } else {
                try display_list.fillRect(allocator, node.rect, node.background);
                try paintBorder(allocator, display_list, node.rect, border, border_width);
            }
            const value = node.text orelse "";
            const visible_text = if (value.len > 0) value else node.placeholder orelse "";
            const text_color = if (value.len > 0) node.foreground else node.placeholder_foreground;
            // Overflowing text and caret must not paint outside the field.
            try display_list.pushClip(allocator, node.rect);
            try display_list.text(allocator, .{
                .x = node.rect.x + node.padding_x,
                .y = node.rect.y + node.padding_y,
            }, visible_text, .{
                .color = text_color,
                .font_size = node.text_style.font_size,
                .line_height = node.text_style.line_height,
            });
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
        .spinner => try paintSpinner(allocator, node, display_list, raster_cache, scale),
        .scroll, .list => try display_list.pushClip(allocator, node.rect),
        else => {},
    };

    const child_cull = if (node.kind.isViewport())
        if (cull_rect) |cull| node.rect.intersect(cull) else null
    else
        cull_rect;
    for (node.children) |child| {
        try paintNode(allocator, child, display_list, raster_cache, scale, child_cull);
    }

    if (node.kind.isViewport()) {
        try paintScrollbars(allocator, node, display_list, raster_cache, scale);
        try display_list.popClip(allocator);
    }
}

fn paintBoxShadow(allocator: std.mem.Allocator, display_list: *DisplayList, raster_cache: *RasterCache, rect: Rect, radius: f32, shadow: model.BoxShadow, scale: f32) !void {
    const render_scale = if (std.math.isFinite(scale) and scale > 0) scale else 1;
    var index: usize = shadow.count;
    while (index > 0) {
        index -= 1;
        const layer = shadow.layers[index].normalized();
        if (layer.color.a == 0) continue;
        const support = layer.blurSupport();
        const shape_width = rect.width + layer.spread * 2;
        const shape_height = rect.height + layer.spread * 2;
        if (shape_width <= 0 or shape_height <= 0) continue;
        const destination: Rect = .{
            .x = rect.x + layer.offset_x - layer.spread - support,
            .y = rect.y + layer.offset_y - layer.spread - support,
            .width = shape_width + support * 2,
            .height = shape_height + support * 2,
        };
        const width: usize = @max(1, @as(usize, @intFromFloat(@ceil(destination.width * render_scale))));
        const height: usize = @max(1, @as(usize, @intFromFloat(@ceil(destination.height * render_scale))));
        const padding = support * render_scale;
        const scaled_radius = @max(0, (radius + layer.spread) * render_scale);
        const desired_blur_radius: usize = @intFromFloat(@round(layer.blur * render_scale / 2));
        const blur_radius = @min(desired_blur_radius, @as(usize, @intFromFloat(@floor(padding / 3))));
        const cache_key = shadowCacheKey(width, height, scaled_radius, padding, blur_radius, layer.color.a);
        const alpha = if (raster_cache.cachedAlphaImage(cache_key, @intCast(width), @intCast(height))) |cached|
            cached
        else
            try raster_cache.insertAlpha(allocator, cache_key, @intCast(width), @intCast(height), try shadowAlpha(allocator, width, height, padding, scaled_radius, blur_radius, layer.color.a));
        var color = layer.color;
        color.a = 255;
        try display_list.alphaImageDithered(allocator, destination, @intCast(width), @intCast(height), alpha, color, cache_key);
    }
}

fn shadowAlpha(allocator: std.mem.Allocator, width: usize, height: usize, padding: f32, radius: f32, blur_radius: usize, opacity: u8) ![]u8 {
    var surface = try z2d.Surface.init(.image_surface_alpha8, allocator, @intCast(width), @intCast(height));
    defer surface.deinit(allocator);
    var path: z2d.Path = .empty;
    defer path.deinit(allocator);
    try appendRoundedRectPath(&path, allocator, padding, padding, @max(0, @as(f64, @floatFromInt(width)) - padding * 2), @max(0, @as(f64, @floatFromInt(height)) - padding * 2), radius);
    const pattern: z2d.Pattern = .{ .opaque_pattern = .{ .pixel = .{ .alpha8 = .{ .a = 255 } } } };
    try z2d.painter.fill(allocator, &surface, &pattern, path.nodes.items, .{});
    const coverage = try allocator.alloc(u16, width * height);
    defer allocator.free(coverage);
    for (surface.image_surface_alpha8.buf, coverage) |pixel, *value| value.* = @as(u16, pixel.a) * 257;
    if (blur_radius > 0) {
        const scratch = try allocator.alloc(u16, coverage.len);
        defer allocator.free(scratch);
        for (0..3) |_| {
            boxBlurHorizontal(coverage, scratch, width, height, blur_radius);
            boxBlurVertical(scratch, coverage, width, height, blur_radius);
        }
    }
    const alpha = try allocator.alloc(u8, width * height);
    errdefer allocator.free(alpha);
    for (coverage, alpha, 0..) |value, *result, index| {
        result.* = ditheredShadowAlpha(value, opacity, index % width, index / width);
    }
    return alpha;
}

fn boxBlurHorizontal(source: []const u16, destination: []u16, width: usize, height: usize, radius: usize) void {
    const divisor: u64 = @intCast(radius * 2 + 1);
    for (0..height) |y| {
        const row = y * width;
        var sum: u64 = 0;
        for (0..@min(width, radius + 1)) |x| sum += source[row + x];
        for (0..width) |x| {
            destination[row + x] = @intCast((sum + divisor / 2) / divisor);
            if (x >= radius) sum -= source[row + x - radius];
            const added = x + radius + 1;
            if (added < width) sum += source[row + added];
        }
    }
}

fn boxBlurVertical(source: []const u16, destination: []u16, width: usize, height: usize, radius: usize) void {
    const divisor: u64 = @intCast(radius * 2 + 1);
    for (0..width) |x| {
        var sum: u64 = 0;
        for (0..@min(height, radius + 1)) |y| sum += source[y * width + x];
        for (0..height) |y| {
            destination[y * width + x] = @intCast((sum + divisor / 2) / divisor);
            if (y >= radius) sum -= source[(y - radius) * width + x];
            const added = y + radius + 1;
            if (added < height) sum += source[added * width + x];
        }
    }
}

const bayer8 = [64]u8{
    0,  48, 12, 60, 3,  51, 15, 63,
    32, 16, 44, 28, 35, 19, 47, 31,
    8,  56, 4,  52, 11, 59, 7,  55,
    40, 24, 36, 20, 43, 27, 39, 23,
    2,  50, 14, 62, 1,  49, 13, 61,
    34, 18, 46, 30, 33, 17, 45, 29,
    10, 58, 6,  54, 9,  57, 5,  53,
    42, 26, 38, 22, 41, 25, 37, 21,
};

fn ditheredShadowAlpha(coverage: u16, opacity: u8, x: usize, y: usize) u8 {
    const denominator = std.math.maxInt(u16);
    const scaled = @as(u32, coverage) * opacity;
    const base = scaled / denominator;
    if (base == 255) return 255;
    const remainder = scaled % denominator;
    // Quantize the combined shape coverage and layer opacity only once. The
    // ordered threshold turns sub-byte coverage into a stable spatial
    // average instead of a visible contour in a low-contrast shadow.
    const rank = bayer8[(y % 8) * 8 + (x % 8)];
    const threshold = (@as(u32, rank) * 2 + 1) * denominator / (bayer8.len * 2);
    return @intCast(base + @intFromBool(remainder > threshold));
}

fn shadowCacheKey(width: usize, height: usize, radius: f32, padding: f32, blur_radius: usize, opacity: u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update("box-shadow");
    hasher.update(std.mem.asBytes(&width));
    hasher.update(std.mem.asBytes(&height));
    hasher.update(std.mem.asBytes(&radius));
    hasher.update(std.mem.asBytes(&padding));
    hasher.update(std.mem.asBytes(&blur_radius));
    hasher.update(std.mem.asBytes(&opacity));
    return hasher.final();
}

test "box shadows paint back to front and share masks at the same opacity" {
    var shadow: model.BoxShadow = .{};
    try shadow.append(.{ .color = colors.white, .offset_x = 1, .blur = 4 });
    try shadow.append(.{ .color = colors.ink, .offset_x = 2, .blur = 4 });
    const node: RenderNode = .{ .kind = .box, .rect = .{ .x = 10, .y = 10, .width = 20, .height = 20 }, .box_shadow = shadow };
    var list: DisplayList = .{};
    defer list.deinit(std.testing.allocator);
    var cache: RasterCache = .{};
    defer cache.deinit(std.testing.allocator);
    cache.beginFrame();
    defer cache.endFrame(std.testing.allocator);
    try paint(std.testing.allocator, &node, &list, &cache);
    try std.testing.expectEqual(@as(usize, 2), list.commands.items.len);
    try std.testing.expectEqual(colors.ink, list.commands.items[0].alpha_image.color);
    try std.testing.expectEqual(colors.white, list.commands.items[1].alpha_image.color);
    try std.testing.expectEqual(list.commands.items[0].alpha_image.cache_key, list.commands.items[1].alpha_image.cache_key);
    try std.testing.expect(list.commands.items[0].alpha_image.dither);
}

test "box shadow masks bake opacity before dither" {
    var shadow: model.BoxShadow = .{};
    try shadow.append(.{ .color = Color.argb(64, 0, 0, 0), .blur = 4 });
    try shadow.append(.{ .color = Color.argb(128, 0, 0, 0), .blur = 4 });
    const node: RenderNode = .{ .kind = .box, .rect = .{ .x = 0, .y = 0, .width = 20, .height = 20 }, .box_shadow = shadow };
    var list: DisplayList = .{};
    defer list.deinit(std.testing.allocator);
    var cache: RasterCache = .{};
    defer cache.deinit(std.testing.allocator);
    cache.beginFrame();
    defer cache.endFrame(std.testing.allocator);
    try paint(std.testing.allocator, &node, &list, &cache);
    try std.testing.expectEqual(@as(usize, 2), list.commands.items.len);
    try std.testing.expectEqual(@as(u8, 255), list.commands.items[0].alpha_image.color.a);
    try std.testing.expectEqual(@as(u8, 255), list.commands.items[1].alpha_image.color.a);
    try std.testing.expect(list.commands.items[0].alpha_image.cache_key != list.commands.items[1].alpha_image.cache_key);
}

test "blurred shadow mask falls off outside source" {
    const alpha = try shadowAlpha(std.testing.allocator, 20, 20, 6, 0, 2, 255);
    defer std.testing.allocator.free(alpha);
    try std.testing.expect(alpha[10 * 20 + 10] > alpha[10 * 20 + 3]);
    try std.testing.expect(alpha[10 * 20 + 3] > 0);
    try std.testing.expect(alpha[10 * 20] < alpha[10 * 20 + 3]);
}

test "unblurred shadow mask preserves transparent padding" {
    const alpha = try shadowAlpha(std.testing.allocator, 10, 10, 2, 0, 0, 255);
    defer std.testing.allocator.free(alpha);
    try std.testing.expectEqual(@as(u8, 0), alpha[0]);
    try std.testing.expectEqual(@as(u8, 255), alpha[5 * 10 + 5]);
}

test "damage paint emits only intersecting node commands" {
    var first: RenderNode = .{
        .kind = .box,
        .rect = .{ .x = 0, .y = 0, .width = 20, .height = 20 },
        .background = colors.white,
    };
    var second: RenderNode = .{
        .kind = .box,
        .rect = .{ .x = 30, .y = 0, .width = 20, .height = 20 },
        .background = colors.ink,
    };
    var children = [_]*RenderNode{ &first, &second };
    const root: RenderNode = .{
        .kind = .row,
        .rect = .{ .x = 0, .y = 0, .width = 50, .height = 20 },
        .children = &children,
    };

    var display_list: DisplayList = .{};
    defer display_list.deinit(std.testing.allocator);
    var raster_cache: RasterCache = .{};
    defer raster_cache.deinit(std.testing.allocator);
    raster_cache.beginFrame();
    defer raster_cache.endFrame(std.testing.allocator);

    try paintDamagedScaled(std.testing.allocator, &root, &display_list, &raster_cache, 1, second.rect);

    try std.testing.expectEqual(@as(usize, 1), display_list.commands.items.len);
    try std.testing.expectEqual(second.rect, display_list.commands.items[0].fill_rect.rect);
}

test "damage paint retains text whose glyphs may overhang its layout rect" {
    const text: RenderNode = .{
        .kind = .text,
        .rect = .{ .x = 20, .y = 0, .width = 20, .height = 20 },
        .text = "text",
    };

    var display_list: DisplayList = .{};
    defer display_list.deinit(std.testing.allocator);
    var raster_cache: RasterCache = .{};
    defer raster_cache.deinit(std.testing.allocator);
    raster_cache.beginFrame();
    defer raster_cache.endFrame(std.testing.allocator);

    try paintDamagedScaled(
        std.testing.allocator,
        &text,
        &display_list,
        &raster_cache,
        1,
        .{ .x = 10, .y = 0, .width = 5, .height = 20 },
    );

    try std.testing.expectEqual(@as(usize, 1), display_list.commands.items.len);
    try std.testing.expect(display_list.commands.items[0] == .text);
}

test "damage paint keeps overflowing children and culls clipped viewports" {
    var visible_overflow: RenderNode = .{
        .kind = .box,
        .rect = .{ .x = 30, .y = 0, .width = 20, .height = 20 },
        .background = colors.ink,
    };
    var overflow_children = [_]*RenderNode{&visible_overflow};
    var outside_parent: RenderNode = .{
        .kind = .center,
        .rect = .{ .x = 0, .y = 0, .width = 20, .height = 20 },
        .children = &overflow_children,
    };
    var clipped_child: RenderNode = .{
        .kind = .box,
        .rect = visible_overflow.rect,
        .background = colors.white,
    };
    var clipped_children = [_]*RenderNode{&clipped_child};
    var viewport: RenderNode = .{
        .kind = .scroll,
        .rect = .{ .x = 0, .y = 30, .width = 20, .height = 20 },
        .children = &clipped_children,
    };
    var children = [_]*RenderNode{ &outside_parent, &viewport };
    const root: RenderNode = .{
        .kind = .column,
        .rect = .{ .x = 0, .y = 0, .width = 50, .height = 50 },
        .children = &children,
    };

    var display_list: DisplayList = .{};
    defer display_list.deinit(std.testing.allocator);
    var raster_cache: RasterCache = .{};
    defer raster_cache.deinit(std.testing.allocator);
    raster_cache.beginFrame();
    defer raster_cache.endFrame(std.testing.allocator);

    try paintDamagedScaled(std.testing.allocator, &root, &display_list, &raster_cache, 1, visible_overflow.rect);

    try std.testing.expectEqual(@as(usize, 1), display_list.commands.items.len);
    try std.testing.expectEqual(visible_overflow.rect, display_list.commands.items[0].fill_rect.rect);
    try std.testing.expectEqual(@as(usize, 0), display_list.clip_stack.items.len);
}

test "damage paint does not emit children outside an intersecting viewport" {
    var clipped_child: RenderNode = .{
        .kind = .box,
        .rect = .{ .x = 25, .y = 0, .width = 10, .height = 20 },
        .background = colors.white,
    };
    var viewport_children = [_]*RenderNode{&clipped_child};
    const viewport: RenderNode = .{
        .kind = .scroll,
        .rect = .{ .x = 0, .y = 0, .width = 20, .height = 20 },
        .children = &viewport_children,
    };

    var display_list: DisplayList = .{};
    defer display_list.deinit(std.testing.allocator);
    var raster_cache: RasterCache = .{};
    defer raster_cache.deinit(std.testing.allocator);
    raster_cache.beginFrame();
    defer raster_cache.endFrame(std.testing.allocator);

    try paintDamagedScaled(
        std.testing.allocator,
        &viewport,
        &display_list,
        &raster_cache,
        1,
        .{ .x = 15, .y = 0, .width = 20, .height = 20 },
    );

    try std.testing.expectEqual(@as(usize, 2), display_list.commands.items.len);
    try std.testing.expect(display_list.commands.items[0] == .set_clip);
    try std.testing.expect(display_list.commands.items[1] == .set_clip);
    try std.testing.expectEqual(@as(usize, 0), display_list.clip_stack.items.len);
}

const spinner_dots = 8;
/// Floor for trailing dot brightness so the whole ring stays visible.
const spinner_trail_floor: f32 = 0.25;
const spinner_opacity: f32 = 0.65;

/// A ring of dots at fixed positions; the sweep phase picks the brightest
/// dot and brightness trails off behind it. Dot positions never move, so
/// the spinner needs no path stroking or transforms.
fn paintSpinner(allocator: std.mem.Allocator, node: *const RenderNode, display_list: *DisplayList, raster_cache: *RasterCache, scale: f32) !void {
    std.debug.assert(node.spinner_progress >= 0 and node.spinner_progress < 1);
    const size = @min(node.rect.width, node.rect.height);
    if (size <= 0) return;
    const dot_radius = size * 0.1;
    const ring_radius = size / 2 - dot_radius;
    const center_x = node.rect.x + node.rect.width / 2;
    const center_y = node.rect.y + node.rect.height / 2;

    for (0..spinner_dots) |index| {
        const fraction = @as(f32, @floatFromInt(index)) / spinner_dots;
        // Dots start at 12 o'clock and the sweep runs clockwise; a dot is
        // brightest as the sweep passes it and dims with age behind it.
        const angle = fraction * std.math.tau - std.math.tau / 4.0;
        const age = @mod(node.spinner_progress - fraction + 1, 1);
        const intensity = spinner_opacity * (spinner_trail_floor + (1 - spinner_trail_floor) * (1 - age));
        var color = node.foreground;
        color.a = @intFromFloat(@round(@as(f32, @floatFromInt(color.a)) * intensity));
        if (color.a == 0) continue;
        const dot: Rect = .{
            .x = center_x + ring_radius * @cos(angle) - dot_radius,
            .y = center_y + ring_radius * @sin(angle) - dot_radius,
            .width = dot_radius * 2,
            .height = dot_radius * 2,
        };
        try paintRoundedBox(allocator, display_list, raster_cache, dot, color, null, 0, dot_radius, scale);
    }
}

pub const scrollbar_thickness: f32 = model.scale.space(1);
pub const scrollbar_margin: f32 = model.scale.space(1);
const scrollbar_min_thumb: f32 = model.scale.space(4);
pub const scrollbar_track_color: Color = colors.slate3;
pub const scrollbar_color: Color = colors.slate8;
/// Extra pointer slop around the painted thumb so the thin bar is
/// grabbable.
const scrollbar_hit_slop: f32 = (model.scale.space(4) - scrollbar_thickness) / 2;
pub const ScrollbarAxis = enum { vertical, horizontal };

const ScrollbarGeometry = struct {
    track: Rect,
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
            .track = .{
                .x = node.rect.x + node.rect.width - scrollbar_thickness - scrollbar_margin,
                .y = node.rect.y + scrollbar_margin,
                .width = scrollbar_thickness,
                .height = track,
            },
            .thumb = .{
                .x = node.rect.x + node.rect.width - scrollbar_thickness - scrollbar_margin,
                .y = node.rect.y + scrollbar_margin + along,
                .width = scrollbar_thickness,
                .height = thumb,
            },
            .drag_scale = if (travel > 0) max_offset / travel else 0,
        },
        .horizontal => .{
            .track = .{
                .x = node.rect.x + scrollbar_margin,
                .y = node.rect.y + node.rect.height - scrollbar_thickness - scrollbar_margin,
                .width = track,
                .height = scrollbar_thickness,
            },
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

/// Paints scrollbar tracks and proportional thumbs for axes whose content
/// overflows the viewport. They are rounded overlays on the content's edge.
fn paintScrollbars(allocator: std.mem.Allocator, node: *const RenderNode, display_list: *DisplayList, raster_cache: *RasterCache, scale: f32) !void {
    std.debug.assert(node.kind.isViewport());
    const track_color = fadedScrollbarColor(node.scrollbar_track_color, node.scrollbar_alpha);
    const thumb_color = fadedScrollbarColor(node.scrollbar_color, node.scrollbar_alpha) orelse return;
    inline for ([_]ScrollbarAxis{ .vertical, .horizontal }) |axis| {
        if (scrollbarGeometry(node, axis)) |geometry| {
            if (track_color) |color| try paintRoundedBox(allocator, display_list, raster_cache, geometry.track, color, null, 0, model.scale.radius(1), scale);
            try paintRoundedBox(allocator, display_list, raster_cache, geometry.thumb, thumb_color, null, 0, model.scale.radius(1), scale);
        }
    }
}

/// Thumb color at the node's current fade alpha; null when it has faded
/// out entirely and nothing should paint.
fn fadedScrollbarColor(base: Color, alpha: f32) ?Color {
    std.debug.assert(alpha >= 0 and alpha <= 1);
    const scaled: u8 = @intFromFloat(@round(@as(f32, @floatFromInt(base.a)) * alpha));
    if (scaled == 0) return null;
    var color = base;
    color.a = scaled;
    return color;
}

/// Alpha below which a fading thumb stops accepting pointer grabs, so a
/// nearly invisible thumb does not steal clicks from content beneath it.
const scrollbar_hit_min_alpha: f32 = 0.1;

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
    if (node.scrollbar_alpha < scrollbar_hit_min_alpha) return null;
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
    raster_cache: *RasterCache,
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
        const alpha = if (raster_cache.cachedAlphaImage(cache_key, @intCast(width), @intCast(height))) |cached|
            cached
        else
            try raster_cache.insertAlpha(allocator, cache_key, @intCast(width), @intCast(height), try roundedRectAlpha(allocator, width, height, scaled_radius, null));
        try display_list.alphaImage(allocator, rect, @intCast(width), @intCast(height), alpha, background, cache_key);
    }

    if (border) |border_color| {
        const stroke_width = @min(@max(0, border_width * render_scale), @min(@as(f32, @floatFromInt(width)), @as(f32, @floatFromInt(height))) / 2);
        if (stroke_width > 0) {
            const cache_key = roundedRectCacheKey(width, height, scaled_radius, stroke_width);
            const alpha = if (raster_cache.cachedAlphaImage(cache_key, @intCast(width), @intCast(height))) |cached|
                cached
            else
                try raster_cache.insertAlpha(allocator, cache_key, @intCast(width), @intCast(height), try roundedRectAlpha(allocator, width, height, scaled_radius, stroke_width));
            try display_list.alphaImage(allocator, rect, @intCast(width), @intCast(height), alpha, border_color, cache_key);
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
