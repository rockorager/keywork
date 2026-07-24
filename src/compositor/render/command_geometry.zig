//! Conservative visible bounds for renderer command streams.

const std = @import("std");
const render = @import("types.zig");

/// Returns a frame-clipped bounding rectangle, not exact rounded-shape
/// coverage. Capture markers do not draw and therefore have no visible bounds.
pub fn visibleRect(command: render.Command, frame_size: render.Size) ?render.Rect {
    return switch (command) {
        .clear => .{ .x = 0, .y = 0, .width = frame_size.width, .height = frame_size.height },
        .solid_rect => |solid| clipped: {
            var rect = solid.rect.clipTo(frame_size) orelse break :clipped null;
            if (solid.clip) |clip| rect = rect.intersection(clip) orelse break :clipped null;
            break :clipped rect;
        },
        .image => |image| clipped: {
            var rect = (render.Rect{
                .x = image.x,
                .y = image.y,
                .width = image.size.width,
                .height = image.size.height,
            }).clipTo(frame_size) orelse break :clipped null;
            if (image.clip) |clip| rect = rect.intersection(clip) orelse break :clipped null;
            if (image.rounded_clip) |clip| {
                rect = rect.intersection(clip.rect) orelse break :clipped null;
            }
            break :clipped rect;
        },
        .crossfade => |fade| clipped: {
            var rect = fade.destination.clipTo(frame_size) orelse break :clipped null;
            if (fade.clip) |clip| rect = rect.intersection(clip) orelse break :clipped null;
            if (fade.rounded_clip) |clip| rect = rect.intersection(clip.rect) orelse break :clipped null;
            break :clipped rect;
        },
        .shadow => |shadow| shadowVisibleRect(shadow, frame_size),
        .backdrop_capture => null,
        .backdrop_blur => |blur| clipped: {
            var rect = blur.rect.clipTo(frame_size) orelse break :clipped null;
            if (blur.clip) |clip| rect = rect.intersection(clip) orelse break :clipped null;
            break :clipped rect;
        },
    };
}

fn shadowVisibleRect(shadow: render.Shadow, frame_size: render.Size) ?render.Rect {
    if (shadow.color.alpha == 0 or shadow.rect.width == 0 or shadow.rect.height == 0) {
        return null;
    }
    const spread: i64 = shadow.spread;
    const shape_x = @as(i64, shadow.rect.x) - spread;
    const shape_y = @as(i64, shadow.rect.y) - spread;
    const shape_width = @as(i64, shadow.rect.width) + 2 * spread;
    const shape_height = @as(i64, shadow.rect.height) + 2 * spread;
    if (shape_width <= 0 or shape_height <= 0) return null;
    const blur_extent: i64 = render.shadowBlurExtent(shadow.blur_radius);
    const left = @max(shape_x - blur_extent, 0);
    const top = @max(shape_y - blur_extent, 0);
    const right = @min(shape_x + shape_width + blur_extent, frame_size.width);
    const bottom = @min(shape_y + shape_height + blur_extent, frame_size.height);
    if (left >= right or top >= bottom) return null;
    var rect: render.Rect = .{
        .x = @intCast(left),
        .y = @intCast(top),
        .width = @intCast(right - left),
        .height = @intCast(bottom - top),
    };
    if (shadow.clip) |clip| rect = rect.intersection(clip) orelse return null;
    return rect;
}

test "visible bounds combine frame and command clips" {
    var pixels = [_]u32{0};
    const command: render.Command = .{ .image = .{
        .x = -5,
        .y = 4,
        .size = .{ .width = 20, .height = 12 },
        .buffer = .{
            .size = .{ .width = 1, .height = 1 },
            .stride_pixels = 1,
            .pixels = &pixels,
        },
        .rounded_clip = .{
            .rect = .{ .x = 2, .y = 1, .width = 10, .height = 10 },
            .radius = 2,
        },
        .clip = .{ .x = 0, .y = 6, .width = 8, .height = 4 },
    } };
    try std.testing.expectEqual(
        render.Rect{ .x = 2, .y = 6, .width = 6, .height = 4 },
        visibleRect(command, .{ .width = 12, .height = 12 }).?,
    );
}

test "shadow bounds include spread and blur before clipping" {
    const shadow: render.Command = .{ .shadow = .{
        .rect = .{ .x = 20, .y = 20, .width = 10, .height = 10 },
        .corner_radius = 2,
        .blur_radius = 4,
        .spread = 2,
        .color = render.Color.rgba(0, 0, 0, 128),
        .clip = .{ .x = 10, .y = 15, .width = 20, .height = 20 },
    } };
    try std.testing.expectEqual(
        render.Rect{ .x = 12, .y = 15, .width = 18, .height = 20 },
        visibleRect(shadow, .{ .width = 100, .height = 100 }).?,
    );

    var transparent = shadow;
    transparent.shadow.color.alpha = 0;
    try std.testing.expect(visibleRect(transparent, .{ .width = 100, .height = 100 }) == null);
}
