//! Pure window hit-testing, clipping, occlusion, and border geometry.

const std = @import("std");
const render = @import("render/types.zig");
const Scene = @import("scene.zig");
const damage_geometry = @import("damage_geometry.zig");

pub fn pointInRect(x: f64, y: f64, rect: render.Rect) bool {
    return x >= @as(f64, @floatFromInt(rect.x)) and
        y >= @as(f64, @floatFromInt(rect.y)) and
        x < @as(f64, @floatFromInt(@as(i64, rect.x) + rect.width)) and
        y < @as(f64, @floatFromInt(@as(i64, rect.y) + rect.height));
}

pub fn pointInRoundedRect(x: f64, y: f64, rect: render.Rect, requested_radius: u32) bool {
    if (!pointInRect(x, y, rect)) return false;
    const radius: f64 = @floatFromInt(@min(
        requested_radius,
        @min(rect.width, rect.height) / 2,
    ));
    if (radius == 0) return true;

    const left: f64 = @floatFromInt(rect.x);
    const top: f64 = @floatFromInt(rect.y);
    const right: f64 = @floatFromInt(@as(i64, rect.x) + rect.width);
    const bottom: f64 = @floatFromInt(@as(i64, rect.y) + rect.height);
    const center_x = std.math.clamp(x, left + radius, right - radius);
    const center_y = std.math.clamp(y, top + radius, bottom - radius);
    const distance_x = x - center_x;
    const distance_y = y - center_y;
    return distance_x * distance_x + distance_y * distance_y <= radius * radius;
}

pub fn fullscreenRootOccludesOutput(
    window: *const Scene.Window,
    root_size: render.Size,
    root_opaque: bool,
    output_rect: render.Rect,
) bool {
    if (!window.mapped or !window.fullscreen or !root_opaque or
        window.effects.corner_radius != 0 or window.clip_box != null or
        window.content_clip_box != null)
    {
        return false;
    }
    const offset = if (window.content_geometry) |geometry| geometry.offset else Scene.Position{};
    return std.meta.eql(output_rect, render.Rect{
        .x = window.position.x -| offset.x,
        .y = window.position.y -| offset.y,
        .width = root_size.width,
        .height = root_size.height,
    });
}

pub const ShadowCaster = struct {
    rect: render.Rect,
    corner_radius: u32,
};

/// Returns the visible surface frame that casts a window shadow. A complete
/// exterior border participates in the silhouette; partial borders remain
/// decorative and do not change the apparent surface size.
pub fn shadowCaster(
    content_rect: render.Rect,
    borders: ?Scene.Borders,
    corner_radius: u32,
) ShadowCaster {
    const border = borders orelse return .{
        .rect = content_rect,
        .corner_radius = corner_radius,
    };
    if (!fullBorder(border)) return .{
        .rect = content_rect,
        .corner_radius = corner_radius,
    };
    return .{
        .rect = damage_geometry.expandRect(content_rect, border.width),
        .corner_radius = corner_radius +| border.width,
    };
}

fn fullBorder(borders: Scene.Borders) bool {
    return borders.edges.top and borders.edges.bottom and
        borders.edges.left and borders.edges.right;
}

/// Emits the draw commands for one window border into `commands`.
///
/// A border enclosing all four edges becomes a single rounded-rect frame whose
/// thickness comes from `spread`. That keeps the thickness uniform under
/// fractional output scaling: `spread` is rounded to device pixels exactly
/// once, whereas four independent rects round each edge on its own and differ
/// by a pixel depending on where the window sits on the pixel grid. The frame's
/// outer corners are `corner_radius + width`, so a square window still gets
/// slightly rounded outer corners.
///
/// Partial borders fall back to one solid rect per edge and inherit that
/// per-edge rounding. Every returned command is clipped to `clip`.
pub fn makeBorderCommands(
    content_rect: render.Rect,
    borders: Scene.Borders,
    corner_radius: u32,
    clip: ?render.Rect,
    commands: *[4]render.Command,
) []const render.Command {
    const width = borders.width;
    if (width > 0 and fullBorder(borders)) {
        commands[0] = .{ .shadow = .{
            .rect = content_rect,
            .corner_radius = corner_radius,
            .blur_radius = 0,
            .spread = @intCast(width),
            .color = borders.color,
            .cutout = .{ .rect = content_rect, .radius = corner_radius },
            .clip = clip,
        } };
        return commands[0..1];
    }

    const width_i32: i32 = @intCast(width);
    const content_width_i32: i32 = @intCast(@min(
        content_rect.width,
        std.math.maxInt(i32),
    ));
    const content_height_i32: i32 = @intCast(@min(
        content_rect.height,
        std.math.maxInt(i32),
    ));
    const vertical_y = if (borders.edges.top)
        content_rect.y -| width_i32
    else
        content_rect.y;
    var vertical_height = content_rect.height;
    if (borders.edges.top) vertical_height +|= width;
    if (borders.edges.bottom) vertical_height +|= width;

    var command_count: usize = 0;
    if (borders.edges.top) {
        commands[command_count] = .{ .solid_rect = .{
            .rect = .{
                .x = content_rect.x,
                .y = content_rect.y -| width_i32,
                .width = content_rect.width,
                .height = width,
            },
            .color = borders.color,
            .clip = clip,
        } };
        command_count += 1;
    }
    if (borders.edges.bottom) {
        commands[command_count] = .{ .solid_rect = .{
            .rect = .{
                .x = content_rect.x,
                .y = content_rect.y +| content_height_i32,
                .width = content_rect.width,
                .height = width,
            },
            .color = borders.color,
            .clip = clip,
        } };
        command_count += 1;
    }
    if (borders.edges.left) {
        commands[command_count] = .{ .solid_rect = .{
            .rect = .{
                .x = content_rect.x -| width_i32,
                .y = vertical_y,
                .width = width,
                .height = vertical_height,
            },
            .color = borders.color,
            .clip = clip,
        } };
        command_count += 1;
    }
    if (borders.edges.right) {
        commands[command_count] = .{ .solid_rect = .{
            .rect = .{
                .x = content_rect.x +| content_width_i32,
                .y = vertical_y,
                .width = width,
                .height = vertical_height,
            },
            .color = borders.color,
            .clip = clip,
        } };
        command_count += 1;
    }
    std.debug.assert(command_count > 0);
    return commands[0..command_count];
}

pub fn pointInBorderCommand(x: f64, y: f64, command: render.Command) bool {
    return switch (command) {
        .solid_rect => |solid| if (solid.clip) |clip|
            pointInRect(x, y, solid.rect) and pointInRect(x, y, clip)
        else
            pointInRect(x, y, solid.rect),
        .shadow => |shadow| contains: {
            std.debug.assert(shadow.blur_radius == 0);
            std.debug.assert(shadow.spread > 0);
            if (shadow.clip) |clip| if (!pointInRect(x, y, clip)) break :contains false;
            const spread: u32 = @intCast(shadow.spread);
            const outer = damage_geometry.expandRect(shadow.rect, spread);
            if (!pointInRoundedRect(
                x,
                y,
                outer,
                shadow.corner_radius +| spread,
            )) break :contains false;
            const cutout = shadow.cutout orelse break :contains true;
            break :contains !pointInRoundedRect(x, y, cutout.rect, cutout.radius);
        },
        else => unreachable,
    };
}

pub fn windowContentRect(window: *const Scene.Window, content_size: render.Size) ?render.Rect {
    const content_rect: render.Rect = .{
        .x = window.position.x,
        .y = window.position.y,
        .width = content_size.width,
        .height = content_size.height,
    };
    const clip_box = window.content_clip_box orelse return content_rect;
    return content_rect.intersection(clip_box.translated(window.position.x, window.position.y));
}

test "only an opaque fullscreen root exactly covering the output occludes lower layers" {
    const output_rect: render.Rect = .{ .x = 1280, .y = 0, .width = 1920, .height = 1200 };
    var window: Scene.Window = .{
        .surface_id = .{ .index = 100, .generation = 1 },
        .position = .{ .x = 1280 },
        .mapped = true,
        .fullscreen = true,
        .effects = .{},
    };
    try std.testing.expect(fullscreenRootOccludesOutput(
        &window,
        .{ .width = 1920, .height = 1200 },
        true,
        output_rect,
    ));
    try std.testing.expect(!fullscreenRootOccludesOutput(
        &window,
        .{ .width = 1920, .height = 1200 },
        false,
        output_rect,
    ));
    window.position.x += 10;
    window.content_geometry = .{
        .offset = .{ .x = 10 },
        .size = .{ .width = 1920, .height = 1200 },
    };
    try std.testing.expect(fullscreenRootOccludesOutput(
        &window,
        .{ .width = 1920, .height = 1200 },
        true,
        output_rect,
    ));
    window.content_clip_box = output_rect;
    try std.testing.expect(!fullscreenRootOccludesOutput(
        &window,
        .{ .width = 1920, .height = 1200 },
        true,
        output_rect,
    ));
    window.content_clip_box = null;
    window.effects.corner_radius = 1;
    try std.testing.expect(!fullscreenRootOccludesOutput(
        &window,
        .{ .width = 1920, .height = 1200 },
        true,
        output_rect,
    ));
}

test "window borders occupy only requested exterior edges and corners" {
    var commands: [4]render.Command = undefined;
    const color = render.Color.rgba(0x80, 0x40, 0x20, 0xff);
    const result = makeBorderCommands(
        .{ .x = 10, .y = 20, .width = 100, .height = 50 },
        .{
            .edges = .{ .top = true, .left = true, .right = true },
            .width = 4,
            .color = color,
        },
        12,
        .{ .x = 0, .y = 0, .width = 200, .height = 200 },
        &commands,
    );
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqual(render.Rect{
        .x = 10,
        .y = 16,
        .width = 100,
        .height = 4,
    }, result[0].solid_rect.rect);
    try std.testing.expectEqual(render.Rect{
        .x = 6,
        .y = 16,
        .width = 4,
        .height = 54,
    }, result[1].solid_rect.rect);
    try std.testing.expectEqual(render.Rect{
        .x = 110,
        .y = 16,
        .width = 4,
        .height = 54,
    }, result[2].solid_rect.rect);
    try std.testing.expectEqual(color, result[0].solid_rect.color);
    try std.testing.expectEqual(render.Rect{
        .x = 0,
        .y = 0,
        .width = 200,
        .height = 200,
    }, result[0].solid_rect.clip.?);
}

test "window border follows rounded content corners" {
    var commands: [4]render.Command = undefined;
    const content: render.Rect = .{ .x = 10, .y = 20, .width = 100, .height = 50 };
    const result = makeBorderCommands(
        content,
        .{
            .edges = .{ .top = true, .bottom = true, .left = true, .right = true },
            .width = 4,
            .color = render.Color.rgba(0x80, 0x40, 0x20, 0xff),
        },
        12,
        null,
        &commands,
    );
    try std.testing.expectEqual(@as(usize, 1), result.len);
    const border = result[0].shadow;
    try std.testing.expectEqual(content, border.rect);
    try std.testing.expectEqual(@as(u32, 12), border.corner_radius);
    try std.testing.expectEqual(@as(u32, 0), border.blur_radius);
    try std.testing.expectEqual(@as(i32, 4), border.spread);
    try std.testing.expectEqual(content, border.cutout.?.rect);
    try std.testing.expectEqual(@as(u32, 12), border.cutout.?.radius);
    try std.testing.expect(pointInBorderCommand(50, 18, result[0]));
    try std.testing.expect(pointInBorderCommand(12, 22, result[0]));
    try std.testing.expect(!pointInBorderCommand(7, 17, result[0]));
    try std.testing.expect(!pointInBorderCommand(50, 21, result[0]));
}

test "complete border expands the shadow caster silhouette" {
    const content: render.Rect = .{ .x = 10, .y = 20, .width = 100, .height = 50 };
    const full: Scene.Borders = .{
        .edges = .{ .top = true, .bottom = true, .left = true, .right = true },
        .width = 2,
        .color = render.Color.rgba(0, 0, 0, 0xff),
    };
    try std.testing.expectEqual(ShadowCaster{
        .rect = .{ .x = 8, .y = 18, .width = 104, .height = 54 },
        .corner_radius = 14,
    }, shadowCaster(content, full, 12));

    var partial = full;
    partial.edges.bottom = false;
    try std.testing.expectEqual(ShadowCaster{
        .rect = content,
        .corner_radius = 12,
    }, shadowCaster(content, partial, 12));
    try std.testing.expectEqual(ShadowCaster{
        .rect = content,
        .corner_radius = 12,
    }, shadowCaster(content, null, 12));
}

test "square window borders keep a uniform thickness under fractional scale" {
    const command_geometry = @import("render/command_geometry.zig");
    var commands: [4]render.Command = undefined;
    const color = render.Color.rgba(0x80, 0x40, 0x20, 0xff);
    const edges: Scene.BorderEdges = .{
        .top = true,
        .bottom = true,
        .left = true,
        .right = true,
    };

    // Every horizontal placement must scale to the same three device pixels.
    // Four independent edge rects would alternate between two and three here.
    for (100..104) |origin| {
        const content: render.Rect = .{
            .x = @intCast(origin),
            .y = 20,
            .width = 100,
            .height = 50,
        };
        const result = makeBorderCommands(
            content,
            .{ .edges = edges, .width = 2, .color = color },
            0,
            null,
            &commands,
        );
        try std.testing.expectEqual(@as(usize, 1), result.len);
        const border = result[0].shadow;
        try std.testing.expectEqual(content, border.rect);
        try std.testing.expectEqual(@as(u32, 0), border.corner_radius);
        try std.testing.expectEqual(@as(i32, 2), border.spread);
        try std.testing.expectEqual(content, border.cutout.?.rect);
        try std.testing.expectEqual(@as(u32, 0), border.cutout.?.radius);

        const scaled = command_geometry.scale(result[0], .{ .numerator = 150 }).shadow;
        try std.testing.expectEqual(@as(i32, 3), scaled.spread);
    }

    // A zero width still yields no frame to hit-test or draw.
    const empty = makeBorderCommands(
        .{ .x = 10, .y = 20, .width = 100, .height = 50 },
        .{ .edges = edges, .width = 0, .color = color },
        0,
        null,
        &commands,
    );
    try std.testing.expectEqual(@as(usize, 4), empty.len);
    for (empty) |command| {
        try std.testing.expect(command.solid_rect.rect.width == 0 or
            command.solid_rect.rect.height == 0);
    }
}

test "content clip boxes intersect window dimensions in global coordinates" {
    const window: Scene.Window = .{
        .surface_id = .{ .index = 1, .generation = 1 },
        .position = .{ .x = 100, .y = 50 },
        .content_clip_box = .{ .x = -10, .y = 20, .width = 80, .height = 100 },
    };
    try std.testing.expectEqual(render.Rect{
        .x = 100,
        .y = 70,
        .width = 70,
        .height = 60,
    }, windowContentRect(&window, .{ .width = 200, .height = 80 }).?);
}

test "rounded window corners reject points outside visible content" {
    const rect: render.Rect = .{ .x = 10, .y = 20, .width = 20, .height = 20 };
    try std.testing.expect(!pointInRoundedRect(10.5, 20.5, rect, 8));
    try std.testing.expect(pointInRoundedRect(14.5, 24.5, rect, 8));
    try std.testing.expect(pointInRoundedRect(20, 20.5, rect, 8));
    try std.testing.expect(!pointInRoundedRect(30, 30, rect, 8));
}
