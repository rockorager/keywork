//! Pure coordinate transforms and conservative visible bounds for renderer commands.

const std = @import("std");
const render = @import("types.zig");

/// Converts global command geometry to target-local coordinates while
/// preserving all non-geometric command data.
pub fn translate(command: render.Command, origin: render.Position) render.Command {
    var result = command;
    switch (result) {
        .clear => {},
        .solid_rect => |*solid| {
            solid.rect = translateRect(solid.rect, origin);
            if (solid.clip) |clip| solid.clip = translateRect(clip, origin);
        },
        .shadow => |*shadow| {
            shadow.rect = translateRect(shadow.rect, origin);
            if (shadow.cutout) |*cutout| cutout.rect = translateRect(cutout.rect, origin);
            if (shadow.clip) |clip| shadow.clip = translateRect(clip, origin);
        },
        .backdrop_capture => |*capture| capture.rect = translateRect(capture.rect, origin),
        .backdrop_blur => |*blur| {
            blur.rect = translateRect(blur.rect, origin);
            if (blur.clip) |clip| blur.clip = translateRect(clip, origin);
        },
        .image => |*image| {
            image.x = translateCoordinate(image.x, origin.x);
            image.y = translateCoordinate(image.y, origin.y);
            image.opaque_region = translateOpaqueRegion(image.opaque_region, origin);
            if (image.rounded_clip) |*clip| clip.rect = translateRect(clip.rect, origin);
            if (image.clip) |clip| image.clip = translateRect(clip, origin);
        },
        .crossfade => |*fade| {
            fade.destination = translateRect(fade.destination, origin);
            if (fade.rounded_clip) |*clip| clip.rect = translateRect(clip.rect, origin);
            if (fade.clip) |clip| fade.clip = translateRect(clip, origin);
        },
    }
    return result;
}

/// Converts logical command geometry to physical coordinates while preserving
/// all non-geometric command data. Opaque regions round inward so they never
/// claim pixels outside the scaled source coverage.
pub fn scale(command: render.Command, factor: render.Scale) render.Command {
    std.debug.assert(factor.numerator > 0 and factor.numerator <= std.math.maxInt(i32));
    var result = command;
    switch (result) {
        .clear => {},
        .solid_rect => |*solid| {
            solid.rect = scaleRect(solid.rect, factor);
            if (solid.clip) |clip| solid.clip = scaleRect(clip, factor);
        },
        .shadow => |*shadow| {
            shadow.rect = scaleRect(shadow.rect, factor);
            shadow.corner_radius = scaleUnsigned(shadow.corner_radius, factor);
            shadow.blur_radius = scaleUnsigned(shadow.blur_radius, factor);
            shadow.spread = scaleSigned(shadow.spread, factor);
            if (shadow.cutout) |*cutout| {
                cutout.rect = scaleRect(cutout.rect, factor);
                cutout.radius = scaleUnsigned(cutout.radius, factor);
            }
            if (shadow.clip) |clip| shadow.clip = scaleRect(clip, factor);
        },
        .backdrop_capture => |*capture| {
            capture.rect = scaleRect(capture.rect, factor);
            capture.radius = scaleUnsigned(capture.radius, factor);
        },
        .backdrop_blur => |*blur| {
            blur.rect = scaleRect(blur.rect, factor);
            blur.corner_radius = scaleUnsigned(blur.corner_radius, factor);
            blur.radius = scaleUnsigned(blur.radius, factor);
            if (blur.clip) |clip| blur.clip = scaleRect(clip, factor);
        },
        .image => |*image| {
            const rect = scaleRect(.{
                .x = image.x,
                .y = image.y,
                .width = image.size.width,
                .height = image.size.height,
            }, factor);
            image.x = rect.x;
            image.y = rect.y;
            image.size = .{ .width = rect.width, .height = rect.height };
            image.opaque_region = scaleOpaqueRegion(image.opaque_region, factor);
            if (image.rounded_clip) |*clip| {
                clip.rect = scaleRect(clip.rect, factor);
                clip.radius = scaleUnsigned(clip.radius, factor);
            }
            if (image.clip) |clip| image.clip = scaleRect(clip, factor);
        },
        .crossfade => |*fade| {
            fade.destination = scaleRect(fade.destination, factor);
            if (fade.rounded_clip) |*clip| {
                clip.rect = scaleRect(clip.rect, factor);
                clip.radius = scaleUnsigned(clip.radius, factor);
            }
            if (fade.clip) |clip| fade.clip = scaleRect(clip, factor);
        },
    }
    return result;
}

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
    const bottom_color = shadow.bottom_color orelse shadow.color;
    if ((shadow.color.alpha == 0 and bottom_color.alpha == 0) or
        shadow.rect.width == 0 or shadow.rect.height == 0)
    {
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

fn translateRect(rect: render.Rect, origin: render.Position) render.Rect {
    return .{
        .x = translateCoordinate(rect.x, origin.x),
        .y = translateCoordinate(rect.y, origin.y),
        .width = rect.width,
        .height = rect.height,
    };
}

fn translateCoordinate(value: i32, origin: i32) i32 {
    return @intCast(std.math.clamp(
        @as(i64, value) - origin,
        std.math.minInt(i32),
        std.math.maxInt(i32),
    ));
}

fn translateOpaqueRegion(
    region: render.OpaqueRegion,
    origin: render.Position,
) render.OpaqueRegion {
    var result: render.OpaqueRegion = .{};
    for (region.slice()) |rectangle| {
        _ = result.append(translateRect(rectangle, origin));
    }
    return result;
}

fn scaleOpaqueRegion(region: render.OpaqueRegion, factor: render.Scale) render.OpaqueRegion {
    var result: render.OpaqueRegion = .{};
    for (region.slice()) |rectangle| {
        const left = scaleCeil(@as(i64, rectangle.x), factor);
        const top = scaleCeil(@as(i64, rectangle.y), factor);
        const right = scaleFloor(@as(i64, rectangle.x) + rectangle.width, factor);
        const bottom = scaleFloor(@as(i64, rectangle.y) + rectangle.height, factor);
        if (left >= right or top >= bottom) continue;
        _ = result.append(.{
            .x = left,
            .y = top,
            .width = @intCast(@as(i64, right) - left),
            .height = @intCast(@as(i64, bottom) - top),
        });
    }
    return result;
}

fn scaleFloor(value: i64, factor: render.Scale) i32 {
    const product = @as(i128, value) * factor.numerator;
    return @intCast(std.math.clamp(
        @divFloor(product, render.Scale.denominator),
        std.math.minInt(i32),
        std.math.maxInt(i32),
    ));
}

fn scaleCeil(value: i64, factor: render.Scale) i32 {
    const product = @as(i128, value) * factor.numerator;
    return @intCast(std.math.clamp(
        -@divFloor(-product, render.Scale.denominator),
        std.math.minInt(i32),
        std.math.maxInt(i32),
    ));
}

fn scaleRect(rect: render.Rect, factor: render.Scale) render.Rect {
    const left = scaleSigned(rect.x, factor);
    const top = scaleSigned(rect.y, factor);
    const right = scaleSigned(@as(i64, rect.x) + rect.width, factor);
    const bottom = scaleSigned(@as(i64, rect.y) + rect.height, factor);
    return .{
        .x = left,
        .y = top,
        .width = @intCast(@max(@as(i64, right) - left, 0)),
        .height = @intCast(@max(@as(i64, bottom) - top, 0)),
    };
}

fn scaleSigned(value: i64, factor: render.Scale) i32 {
    const product = @as(i128, value) * factor.numerator;
    const rounded = if (product >= 0)
        @divTrunc(
            product + render.Scale.denominator / 2,
            render.Scale.denominator,
        )
    else
        -@divTrunc(
            -product + render.Scale.denominator / 2,
            render.Scale.denominator,
        );
    return @intCast(std.math.clamp(
        rounded,
        std.math.minInt(i32),
        std.math.maxInt(i32),
    ));
}

fn scaleUnsigned(value: u32, factor: render.Scale) u32 {
    const product = @as(u64, value) * factor.numerator;
    return @intCast(@min(
        (product + render.Scale.denominator / 2) / render.Scale.denominator,
        std.math.maxInt(u32),
    ));
}

test "command transforms preserve metadata and move opaque regions with images" {
    var pixels = [_]u32{0};
    var region: render.OpaqueRegion = .{};
    try std.testing.expect(region.append(.{ .x = 11, .y = -3, .width = 2, .height = 4 }));
    const command: render.Command = .{ .image = .{
        .x = 11,
        .y = -3,
        .size = .{ .width = 2, .height = 4 },
        .buffer = .{
            .size = .{ .width = 1, .height = 1 },
            .stride_pixels = 1,
            .pixels = &pixels,
        },
        .sample_tag = 42,
        .opaque_region = region,
    } };

    const translated = translate(command, .{ .x = 10, .y = -4 }).image;
    try std.testing.expectEqual(@as(?u64, 42), translated.sample_tag);
    try std.testing.expectEqualSlices(
        render.Rect,
        &.{.{ .x = 1, .y = 1, .width = 2, .height = 4 }},
        translated.opaque_region.slice(),
    );

    const scaled = scale(.{ .image = translated }, .{ .numerator = 180 }).image;
    try std.testing.expectEqualSlices(
        render.Rect,
        &.{.{ .x = 2, .y = 2, .width = 2, .height = 5 }},
        scaled.opaque_region.slice(),
    );
}

test "fractional command scaling transforms rounded clips independently" {
    var source_pixels = [_]u32{0xffffffff} ** 16;
    const scaled = scale(.{ .image = .{
        .x = 0,
        .y = 0,
        .size = .{ .width = 4, .height = 4 },
        .buffer = .{
            .size = .{ .width = 4, .height = 4 },
            .stride_pixels = 4,
            .pixels = &source_pixels,
        },
        .rounded_clip = .{
            .rect = .{ .x = 1, .y = 1, .width = 2, .height = 2 },
            .radius = 1,
        },
    } }, .{ .numerator = 180 });

    try std.testing.expectEqual(render.Rect{
        .x = 2,
        .y = 2,
        .width = 3,
        .height = 3,
    }, scaled.image.rounded_clip.?.rect);
    try std.testing.expectEqual(@as(u32, 2), scaled.image.rounded_clip.?.radius);
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
