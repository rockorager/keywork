//! Pixman-backed CPU renderer.

const Self = @This();

const std = @import("std");
const headless = @import("../backend/headless.zig");
const render_types = @import("types.zig");
const blur_geometry = @import("blur_geometry.zig");
const dual_kawase = @import("dual_kawase.zig");

const pixman = @cImport({
    @cInclude("pixman.h");
});

allocator: std.mem.Allocator,

pub const Error = error{
    InvalidTarget,
    OutOfMemory,
};

pub fn init(allocator: std.mem.Allocator) Self {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Self) void {
    self.* = undefined;
}

pub fn render(self: *Self, frame: render_types.Frame, target: render_types.PixelBuffer) Error!void {
    const destination = try createDestination(frame, target);
    defer _ = pixman.pixman_image_unref(destination);
    try setDestinationDamage(destination, frame);

    var captures: std.ArrayList(BackdropSnapshot) = .empty;
    defer {
        for (captures.items) |snapshot| self.allocator.free(snapshot.pixels);
        captures.deinit(self.allocator);
    }
    for (frame.commands) |command| {
        switch (command) {
            .clear => |color| try fill(
                destination,
                .{ .x = 0, .y = 0, .width = frame.size.width, .height = frame.size.height },
                color,
                pixman.PIXMAN_OP_SRC,
            ),
            .solid_rect => |solid| {
                var clipped = solid.rect.clipTo(frame.size) orelse continue;
                if (solid.clip) |clip| {
                    clipped = clipped.intersection(clip) orelse continue;
                }
                try fill(destination, clipped, solid.color, pixman.PIXMAN_OP_OVER);
            },
            .shadow => |shadow| try drawShadow(destination, frame.size, shadow),
            .backdrop_capture => |marker| {
                if (try self.captureBackdrop(target, marker)) |snapshot| {
                    captures.append(self.allocator, snapshot) catch |err| {
                        self.allocator.free(snapshot.pixels);
                        return err;
                    };
                }
            },
            .backdrop_blur => |blur| try drawBackdropBlur(
                target,
                blur,
                frame.damage,
                backdropSnapshot(captures.items, blur.capture_id),
            ),
            .image => |image| try composite(destination, frame.size, image),
            .crossfade => |crossfade| try self.compositeCrossfade(
                destination,
                frame.size,
                crossfade,
            ),
        }
    }
}

fn compositeCrossfade(
    self: *Self,
    destination: *pixman.pixman_image_t,
    destination_size: render_types.Size,
    fade: render_types.Crossfade,
) Error!void {
    const old = switch (fade.old) {
        .pixels => |pixels| pixels,
        .offscreen => return error.InvalidTarget,
    };
    const new = switch (fade.new) {
        .pixels => |pixels| pixels,
        .offscreen => return error.InvalidTarget,
    };
    if (fade.destination.width == 0 or fade.destination.height == 0) return error.InvalidTarget;
    var clipped = fade.destination.clipTo(destination_size) orelse return;
    if (fade.clip) |clip| clipped = clipped.intersection(clip) orelse return;
    if (fade.rounded_clip) |clip| clipped = clipped.intersection(clip.rect) orelse return;
    const count = std.math.mul(usize, clipped.width, clipped.height) catch
        return error.InvalidTarget;
    const old_pixels = self.allocator.alloc(u32, count) catch return error.OutOfMemory;
    defer self.allocator.free(old_pixels);
    const new_pixels = self.allocator.alloc(u32, count) catch return error.OutOfMemory;
    defer self.allocator.free(new_pixels);
    @memset(old_pixels, 0);
    @memset(new_pixels, 0);
    const local_size: render_types.Size = .{ .width = clipped.width, .height = clipped.height };
    const old_target = try createImage(.{ .size = local_size, .stride_pixels = local_size.width, .pixels = old_pixels }, false, false);
    defer _ = pixman.pixman_image_unref(old_target);
    const new_target = try createImage(.{ .size = local_size, .stride_pixels = local_size.width, .pixels = new_pixels }, false, false);
    defer _ = pixman.pixman_image_unref(new_target);
    const local_x = fade.destination.x -| clipped.x;
    const local_y = fade.destination.y -| clipped.y;
    try composite(old_target, local_size, .{
        .x = local_x,
        .y = local_y,
        .size = .{ .width = fade.destination.width, .height = fade.destination.height },
        .buffer = old,
        .source = fade.old_source,
    });
    try composite(new_target, local_size, .{
        .x = local_x,
        .y = local_y,
        .size = .{ .width = fade.destination.width, .height = fade.destination.height },
        .buffer = new,
        .source = fade.new_source,
    });
    const t: u64 = fade.factor;
    for (old_pixels, new_pixels) |*a, b| {
        var mixed: u32 = 0;
        inline for (0..4) |component| {
            const shift: u5 = @intCast(component * 8);
            const av = (a.* >> shift) & 0xff;
            const bv = (b >> shift) & 0xff;
            const value = (@as(u64, av) * (std.math.maxInt(u32) - t) + @as(u64, bv) * t + std.math.maxInt(u32) / 2) / std.math.maxInt(u32);
            mixed |= @as(u32, @intCast(value)) << shift;
        }
        a.* = mixed;
    }
    try compositePixels(destination, destination_size, .{
        .x = clipped.x,
        .y = clipped.y,
        .size = local_size,
        .buffer = .{ .size = local_size, .stride_pixels = local_size.width, .pixels = old_pixels },
        .rounded_clip = fade.rounded_clip,
    }, false, false, false);
}

test "CPU renderer crossfades premultiplied sources before source-over" {
    var renderer = init(std.testing.allocator);
    defer renderer.deinit();
    const old_pixels = [_]u32{0x80800000};
    const new_pixels = [_]u32{0x40000040};
    const source_size: render_types.Size = .{ .width = 1, .height = 1 };
    const factors = [_]u32{ 0, std.math.maxInt(u32) / 2, std.math.maxInt(u32) };
    const expected = [_]u32{ 0xff902030, 0xff54285c, 0xff183088 };
    for (factors, expected) |factor, wanted| {
        var pixel = [_]u32{0};
        const commands = [_]render_types.Command{
            .{ .clear = .{ .red = 0x20, .green = 0x40, .blue = 0x60, .alpha = 0xff } },
            .{ .crossfade = .{
                .destination = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
                .old = .{ .pixels = .{ .size = source_size, .stride_pixels = 1, .pixels = @constCast(&old_pixels) } },
                .new = .{ .pixels = .{ .size = source_size, .stride_pixels = 1, .pixels = @constCast(&new_pixels) } },
                .factor = factor,
            } },
        };
        try renderer.render(.{ .size = source_size, .commands = &commands }, .{ .size = source_size, .stride_pixels = 1, .pixels = &pixel });
        try std.testing.expectEqual(wanted, pixel[0]);
    }
}

const BackdropSnapshot = struct {
    marker: render_types.BackdropCapture,
    sample_rect: render_types.Rect,
    pixels: []u32,
};

fn backdropSnapshot(captures: []const BackdropSnapshot, id: u32) ?BackdropSnapshot {
    var index = captures.len;
    while (index > 0) {
        index -= 1;
        if (captures[index].marker.id == id) return captures[index];
    }
    return null;
}

fn setDestinationDamage(
    destination: *pixman.pixman_image_t,
    frame: render_types.Frame,
) Error!void {
    const damage = frame.damage orelse return;
    var region: pixman.pixman_region32_t = undefined;
    pixman.pixman_region32_init(&region);
    defer pixman.pixman_region32_fini(&region);

    for (damage) |rectangle| {
        const clipped = rectangle.clipTo(frame.size) orelse continue;
        if (pixman.pixman_region32_union_rect(
            &region,
            &region,
            clipped.x,
            clipped.y,
            clipped.width,
            clipped.height,
        ) == 0) return error.OutOfMemory;
    }
    if (pixman.pixman_image_set_clip_region32(destination, &region) == 0) {
        return error.OutOfMemory;
    }
}

fn createDestination(
    frame: render_types.Frame,
    target: render_types.PixelBuffer,
) Error!*pixman.pixman_image_t {
    if (frame.size.width == 0 or frame.size.height == 0) return error.InvalidTarget;
    if (!std.meta.eql(frame.size, target.size)) return error.InvalidTarget;
    if (target.dmabuf != null) return error.InvalidTarget;
    return createImage(target, false, false);
}

fn createImage(
    buffer: render_types.PixelBuffer,
    force_opaque: bool,
    red_blue_swapped: bool,
) Error!*pixman.pixman_image_t {
    if (buffer.size.width == 0 or buffer.size.height == 0) return error.InvalidTarget;
    if (buffer.stride_pixels < buffer.size.width) return error.InvalidTarget;

    const stride_bytes = std.math.mul(u32, buffer.stride_pixels, @sizeOf(u32)) catch
        return error.InvalidTarget;
    if (stride_bytes > std.math.maxInt(c_int)) return error.InvalidTarget;
    if (buffer.size.width > std.math.maxInt(c_int) or
        buffer.size.height > std.math.maxInt(c_int)) return error.InvalidTarget;

    const row_offset = std.math.mul(
        usize,
        buffer.size.height - 1,
        buffer.stride_pixels,
    ) catch return error.InvalidTarget;
    const required_pixels = std.math.add(usize, row_offset, buffer.size.width) catch
        return error.InvalidTarget;
    if (buffer.pixels.len < required_pixels) return error.InvalidTarget;

    return pixman.pixman_image_create_bits(
        if (red_blue_swapped)
            if (force_opaque) pixman.PIXMAN_x8b8g8r8 else pixman.PIXMAN_a8b8g8r8
        else if (force_opaque)
            pixman.PIXMAN_x8r8g8b8
        else
            pixman.PIXMAN_a8r8g8b8,
        @intCast(buffer.size.width),
        @intCast(buffer.size.height),
        buffer.pixels.ptr,
        @intCast(stride_bytes),
    ) orelse error.OutOfMemory;
}

fn drawShadow(
    destination: *pixman.pixman_image_t,
    destination_size: render_types.Size,
    shadow: render_types.Shadow,
) Error!void {
    if (shadow.rect.width == 0 or shadow.rect.height == 0 or shadow.color.alpha == 0) return;

    const spread: i64 = shadow.spread;
    const shape_x = @as(i64, shadow.rect.x) - spread;
    const shape_y = @as(i64, shadow.rect.y) - spread;
    const shape_width = @as(i64, shadow.rect.width) + 2 * spread;
    const shape_height = @as(i64, shadow.rect.height) + 2 * spread;
    if (shape_width <= 0 or shape_height <= 0) return;

    const blur_extent: i64 = render_types.shadowBlurExtent(shadow.blur_radius);
    const mask_x = shape_x - blur_extent;
    const mask_y = shape_y - blur_extent;
    const mask_width = shape_width + 2 * blur_extent;
    const mask_height = shape_height + 2 * blur_extent;
    const mask_right = mask_x + mask_width;
    const mask_bottom = mask_y + mask_height;
    if (mask_right <= 0 or mask_bottom <= 0 or
        mask_x >= destination_size.width or mask_y >= destination_size.height)
    {
        return;
    }
    var composite_rect = (render_types.Rect{
        .x = @intCast(@max(mask_x, 0)),
        .y = @intCast(@max(mask_y, 0)),
        .width = @intCast(@min(mask_right, destination_size.width) - @max(mask_x, 0)),
        .height = @intCast(@min(mask_bottom, destination_size.height) - @max(mask_y, 0)),
    });
    if (shadow.clip) |clip| {
        composite_rect = composite_rect.intersection(clip) orelse return;
    }

    const width = composite_rect.width;
    const height = composite_rect.height;
    const mask = pixman.pixman_image_create_bits(
        pixman.PIXMAN_a8,
        @intCast(width),
        @intCast(height),
        null,
        0,
    ) orelse return error.OutOfMemory;
    defer _ = pixman.pixman_image_unref(mask);

    const data: [*]u8 = @ptrCast(pixman.pixman_image_get_data(mask));
    const stride: usize = @intCast(pixman.pixman_image_get_stride(mask));
    const radius_value = @max(@as(i64, shadow.corner_radius) + spread, 0);
    const radius: f64 = @floatFromInt(@min(
        radius_value,
        @divTrunc(@min(shape_width, shape_height), 2),
    ));
    const shape_left: f64 = @floatFromInt(shape_x);
    const shape_top: f64 = @floatFromInt(shape_y);
    const shape_size_x: f64 = @floatFromInt(shape_width);
    const shape_size_y: f64 = @floatFromInt(shape_height);
    var cutout_left: f64 = 0;
    var cutout_top: f64 = 0;
    var cutout_width: f64 = 0;
    var cutout_height: f64 = 0;
    var cutout_radius: f64 = 0;
    if (shadow.cutout) |cutout| {
        cutout_left = @floatFromInt(cutout.rect.x);
        cutout_top = @floatFromInt(cutout.rect.y);
        cutout_width = @floatFromInt(cutout.rect.width);
        cutout_height = @floatFromInt(cutout.rect.height);
        cutout_radius = @floatFromInt(@min(
            cutout.radius,
            @min(cutout.rect.width, cutout.rect.height) / 2,
        ));
    }
    for (0..height) |y| {
        for (0..width) |x| {
            const pixel_x: f64 = @as(f64, @floatFromInt(composite_rect.x)) +
                @as(f64, @floatFromInt(x)) + 0.5;
            const pixel_y: f64 = @as(f64, @floatFromInt(composite_rect.y)) +
                @as(f64, @floatFromInt(y)) + 0.5;
            var cutout_alpha: f64 = 1;
            if (shadow.cutout != null) {
                cutout_alpha -= roundedRectCoverage(
                    pixel_x,
                    pixel_y,
                    cutout_left,
                    cutout_top,
                    cutout_width,
                    cutout_height,
                    cutout_radius,
                );
                if (cutout_alpha == 0) {
                    data[y * stride + x] = 0;
                    continue;
                }
            }
            const coverage = roundedBoxShadowCoverage(
                pixel_x,
                pixel_y,
                shape_left,
                shape_top,
                shape_size_x,
                shape_size_y,
                radius,
                @floatFromInt(shadow.blur_radius),
            ) * cutout_alpha;
            data[y * stride + x] = @intFromFloat(
                std.math.clamp(coverage, 0.0, 1.0) * 255.0 + 0.5,
            );
        }
    }

    const color: pixman.pixman_color_t = .{
        .red = expand(shadow.color.red),
        .green = expand(shadow.color.green),
        .blue = expand(shadow.color.blue),
        .alpha = expand(shadow.color.alpha),
    };
    const source = pixman.pixman_image_create_solid_fill(&color) orelse
        return error.OutOfMemory;
    defer _ = pixman.pixman_image_unref(source);
    pixman.pixman_image_composite32(
        pixman.PIXMAN_OP_OVER,
        source,
        mask,
        destination,
        0,
        0,
        0,
        0,
        composite_rect.x,
        composite_rect.y,
        @intCast(composite_rect.width),
        @intCast(composite_rect.height),
    );
}

fn captureBackdrop(
    self: *Self,
    target: render_types.PixelBuffer,
    marker: render_types.BackdropCapture,
) Error!?BackdropSnapshot {
    const clipped = marker.rect.clipTo(target.size) orelse return null;
    const level = blur_geometry.configuredLevel(marker.radius, marker.downsample_level);
    const sample_rect = blur_geometry.sampleRect(
        clipped,
        blur_geometry.footprint(marker.radius, marker.downsample_level),
        level,
        target.size,
    );
    const pixels = try dual_kawase.blurArgb(
        self.allocator,
        target,
        sample_rect,
        marker.radius,
        marker.downsample_level,
        marker.finish,
    );
    return .{ .marker = marker, .sample_rect = sample_rect, .pixels = pixels };
}

fn drawBackdropBlur(
    target: render_types.PixelBuffer,
    blur: render_types.BackdropBlur,
    damage: ?[]const render_types.Rect,
    capture: ?BackdropSnapshot,
) Error!void {
    if (blur.radius == 0 or blur.rect.width == 0 or blur.rect.height == 0) return;
    var clipped = blur.rect.clipTo(target.size) orelse return;
    if (blur.clip) |clip| clipped = clipped.intersection(clip) orelse return;
    const snapshot = capture orelse return error.InvalidTarget;
    if (blur.radius != snapshot.marker.radius or
        blur.downsample_level != snapshot.marker.downsample_level or
        !std.meta.eql(blur.finish, snapshot.marker.finish) or
        !rectContains(snapshot.marker.rect, clipped)) return error.InvalidTarget;
    _ = damageBounds(damage, clipped) orelse return;

    if (damage) |rectangles| {
        for (rectangles) |rectangle| {
            const composite_rect = clipped.intersection(rectangle) orelse continue;
            compositeBackdropBlur(
                target,
                blur,
                composite_rect,
                snapshot.pixels,
                @intCast(snapshot.sample_rect.x),
                @intCast(snapshot.sample_rect.y),
                snapshot.sample_rect.width,
            );
        }
    } else {
        compositeBackdropBlur(
            target,
            blur,
            clipped,
            snapshot.pixels,
            @intCast(snapshot.sample_rect.x),
            @intCast(snapshot.sample_rect.y),
            snapshot.sample_rect.width,
        );
    }
}

fn rectContains(outer: render_types.Rect, inner: render_types.Rect) bool {
    return @as(i64, inner.x) >= outer.x and
        @as(i64, inner.y) >= outer.y and
        @as(i64, inner.x) + inner.width <= @as(i64, outer.x) + outer.width and
        @as(i64, inner.y) + inner.height <= @as(i64, outer.y) + outer.height;
}

fn compositeBackdropBlur(
    target: render_types.PixelBuffer,
    blur: render_types.BackdropBlur,
    clipped: render_types.Rect,
    pixels: []const u32,
    sample_left: u32,
    sample_top: u32,
    sample_width: u32,
) void {
    const requested_corner_radius = @min(
        blur.corner_radius,
        @min(blur.rect.width, blur.rect.height) / 2,
    );
    for (0..clipped.height) |y| {
        const output_y: u32 = @intCast(@as(i64, clipped.y) + @as(i64, @intCast(y)));
        for (0..clipped.width) |x| {
            const output_x: u32 = @intCast(@as(i64, clipped.x) + @as(i64, @intCast(x)));
            const coverage: u8 = if (requested_corner_radius == 0)
                255
            else
                @intFromFloat(roundedRectCoverage(
                    @as(f64, @floatFromInt(output_x)) + 0.5,
                    @as(f64, @floatFromInt(output_y)) + 0.5,
                    @floatFromInt(blur.rect.x),
                    @floatFromInt(blur.rect.y),
                    @floatFromInt(blur.rect.width),
                    @floatFromInt(blur.rect.height),
                    @floatFromInt(requested_corner_radius),
                ) * 255.0);
            const output_index = @as(usize, output_y) * target.stride_pixels + output_x;
            const blurred_index = @as(usize, output_y - sample_top) * sample_width +
                output_x - sample_left;
            target.pixels[output_index] = blendArgb(
                pixels[blurred_index],
                target.pixels[output_index],
                coverage,
            );
        }
    }
}

fn damageBounds(
    damage: ?[]const render_types.Rect,
    visible: render_types.Rect,
) ?render_types.Rect {
    const rectangles = damage orelse return visible;
    var bounds: ?render_types.Rect = null;
    for (rectangles) |rectangle| {
        const clipped = visible.intersection(rectangle) orelse continue;
        bounds = if (bounds) |current| unionRect(current, clipped) else clipped;
    }
    return bounds;
}

fn unionRect(a: render_types.Rect, b: render_types.Rect) render_types.Rect {
    const left = @min(a.x, b.x);
    const top = @min(a.y, b.y);
    const right = @max(@as(i64, a.x) + a.width, @as(i64, b.x) + b.width);
    const bottom = @max(@as(i64, a.y) + a.height, @as(i64, b.y) + b.height);
    return .{
        .x = left,
        .y = top,
        .width = @intCast(right - left),
        .height = @intCast(bottom - top),
    };
}

fn blendArgb(source: u32, destination: u32, coverage: u8) u32 {
    if (coverage == 255) return source;
    if (coverage == 0) return destination;

    const inverse = 255 - @as(u16, coverage);
    var result: u32 = 0;
    inline for (0..4) |component| {
        const source_component: u8 = @truncate(source >> component * 8);
        const destination_component: u8 = @truncate(destination >> component * 8);
        const blended = (@as(u16, source_component) * coverage +
            @as(u16, destination_component) * inverse + 127) / 255;
        result |= @as(u32, @intCast(blended)) << component * 8;
    }
    return result;
}

fn roundedRectCoverage(
    pixel_x: f64,
    pixel_y: f64,
    left: f64,
    top: f64,
    width: f64,
    height: f64,
    radius: f64,
) f64 {
    const half_width = width / 2.0;
    const half_height = height / 2.0;
    const center_x = left + half_width;
    const center_y = top + half_height;
    const inner_half_width = @max(half_width - radius, 0.0);
    const inner_half_height = @max(half_height - radius, 0.0);
    const distance_x = @abs(pixel_x - center_x) - inner_half_width;
    const distance_y = @abs(pixel_y - center_y) - inner_half_height;
    const outside_x = @max(distance_x, 0.0);
    const outside_y = @max(distance_y, 0.0);
    const signed_distance = @sqrt(outside_x * outside_x + outside_y * outside_y) +
        @min(@max(distance_x, distance_y), 0.0) - radius;
    return std.math.clamp(0.5 - signed_distance, 0.0, 1.0);
}

fn roundedBoxShadowCoverage(
    pixel_x: f64,
    pixel_y: f64,
    left: f64,
    top: f64,
    width: f64,
    height: f64,
    radius: f64,
    blur_radius: f64,
) f64 {
    if (blur_radius == 0) {
        return roundedRectCoverage(pixel_x, pixel_y, left, top, width, height, radius);
    }

    const sigma = blur_radius * 0.5;
    const half_width = width * 0.5;
    const half_height = height * 0.5;
    const x = pixel_x - (left + half_width);
    const y = pixel_y - (top + half_height);
    const low = y - half_height;
    const high = y + half_height;
    const start = std.math.clamp(-3.0 * sigma, low, high);
    const end = std.math.clamp(3.0 * sigma, low, high);
    const step = (end - start) * 0.25;
    var sample_y = start + step * 0.5;
    var coverage: f64 = 0;
    for (0..4) |_| {
        coverage += roundedBoxShadowX(
            x,
            y - sample_y,
            sigma,
            radius,
            half_width,
            half_height,
        ) * gaussian(sample_y, sigma) * step;
        sample_y += step;
    }
    return std.math.clamp(coverage, 0.0, 1.0);
}

fn roundedBoxShadowX(
    x: f64,
    y: f64,
    sigma: f64,
    radius: f64,
    half_width: f64,
    half_height: f64,
) f64 {
    const delta = @min(half_height - radius - @abs(y), 0.0);
    const curved = half_width - radius +
        std.math.sqrt(@max(0.0, radius * radius - delta * delta));
    const scale = std.math.sqrt(0.5) / sigma;
    const lower = 0.5 + 0.5 * erfApprox((x - curved) * scale);
    const upper = 0.5 + 0.5 * erfApprox((x + curved) * scale);
    return upper - lower;
}

fn gaussian(value: f64, sigma: f64) f64 {
    return std.math.exp(-(value * value) / (2.0 * sigma * sigma)) /
        (std.math.sqrt(2.0 * std.math.pi) * sigma);
}

fn erfApprox(value: f64) f64 {
    const sign: f64 = if (value < 0) -1 else if (value > 0) 1 else 0;
    const absolute = @abs(value);
    var denominator = 1.0 +
        (0.278393 + (0.230389 + 0.078108 * absolute * absolute) * absolute) * absolute;
    denominator *= denominator;
    return sign - sign / (denominator * denominator);
}

fn composite(
    destination: *pixman.pixman_image_t,
    destination_size: render_types.Size,
    image: render_types.Image,
) Error!void {
    const dmabuf = image.buffer.dmabuf orelse
        return compositePixels(destination, destination_size, image, false, false, false);
    if (dmabuf.modifier != 0) return error.InvalidTarget;
    const format = render_types.DmabufFormat.fromFourcc(dmabuf.format) orelse
        return error.InvalidTarget;
    if (!format.isPackedRgb() or dmabuf.plane_count != 1) return error.InvalidTarget;
    const plane = dmabuf.planes[0];
    if (plane.offset % @alignOf(u32) != 0 or plane.stride % @sizeOf(u32) != 0) {
        return error.InvalidTarget;
    }
    const mapping = std.posix.mmap(
        null,
        plane.required_bytes,
        .{ .READ = true },
        .{ .TYPE = .SHARED },
        plane.fd,
        0,
    ) catch return error.InvalidTarget;
    defer std.posix.munmap(mapping);
    if (!(dmabuf.begin_cpu_read)(dmabuf.context)) return error.InvalidTarget;
    defer _ = (dmabuf.end_cpu_read)(dmabuf.context);
    const source_bytes = mapping[plane.offset..];
    const source_pixels: [*]u32 = @ptrCast(@alignCast(source_bytes.ptr));
    var mapped_image = image;
    mapped_image.buffer.pixels = source_pixels[0 .. source_bytes.len / @sizeOf(u32)];
    mapped_image.buffer.dmabuf = null;
    return compositePixels(
        destination,
        destination_size,
        mapped_image,
        dmabuf.y_inverted,
        dmabuf.force_opaque,
        format.redBlueSwapped(),
    );
}

fn compositePixels(
    destination: *pixman.pixman_image_t,
    destination_size: render_types.Size,
    image: render_types.Image,
    y_inverted: bool,
    force_opaque: bool,
    red_blue_swapped: bool,
) Error!void {
    const source = try createImage(image.buffer, force_opaque, red_blue_swapped);
    defer _ = pixman.pixman_image_unref(source);
    if (image.size.width == 0 or image.size.height == 0) return error.InvalidTarget;
    const transformed_size = image.transform.applyToSize(image.buffer.size);
    const source_rect = image.source orelse render_types.SourceRect{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(transformed_size.width),
        .height = @floatFromInt(transformed_size.height),
    };
    if (!validSourceRect(source_rect, transformed_size)) return error.InvalidTarget;
    if (y_inverted or image.transform != .normal or image.source != null or
        source_rect.width != @as(f64, @floatFromInt(image.size.width)) or
        source_rect.height != @as(f64, @floatFromInt(image.size.height)))
    {
        const floating_transform = sourceTransform(image, source_rect, y_inverted);
        var transform: pixman.pixman_transform_t = undefined;
        if (pixman.pixman_transform_from_pixman_f_transform(
            &transform,
            &floating_transform,
        ) == 0 or pixman.pixman_image_set_transform(source, &transform) == 0 or
            pixman.pixman_image_set_filter(
                source,
                if (image.samplingFilter() == .nearest)
                    pixman.PIXMAN_FILTER_NEAREST
                else
                    pixman.PIXMAN_FILTER_BILINEAR,
                null,
                0,
            ) == 0)
        {
            return error.OutOfMemory;
        }
    }

    const destination_rect: render_types.Rect = .{
        .x = image.x,
        .y = image.y,
        .width = image.size.width,
        .height = image.size.height,
    };
    var clipped = destination_rect.clipTo(destination_size) orelse return;
    if (image.clip) |clip| clipped = clipped.intersection(clip) orelse return;
    if (image.rounded_clip) |clip| clipped = clipped.intersection(clip.rect) orelse return;
    const source_x: i32 = clipped.x - image.x;
    const source_y: i32 = clipped.y - image.y;
    const mask = if (image.rounded_clip) |clip| rounded: {
        const rounded_mask = try createRoundedMask(
            .{ .width = clip.rect.width, .height = clip.rect.height },
            clip.radius,
        );
        scaleMask(rounded_mask, image.alpha_multiplier);
        break :rounded rounded_mask;
    } else if (image.alpha_multiplier != std.math.maxInt(u32))
        try createAlphaMask(image.alpha_multiplier)
    else
        null;
    defer if (mask) |rounded_mask| {
        _ = pixman.pixman_image_unref(rounded_mask);
    };
    pixman.pixman_image_composite32(
        pixman.PIXMAN_OP_OVER,
        source,
        mask,
        destination,
        source_x,
        source_y,
        if (image.rounded_clip) |clip| clipped.x - clip.rect.x else 0,
        if (image.rounded_clip) |clip| clipped.y - clip.rect.y else 0,
        clipped.x,
        clipped.y,
        @intCast(clipped.width),
        @intCast(clipped.height),
    );
}

fn createAlphaMask(factor: u32) Error!*pixman.pixman_image_t {
    const alpha: u16 = @intCast((@as(u64, factor) * std.math.maxInt(u16) + std.math.maxInt(u32) / 2) / std.math.maxInt(u32));
    const color: pixman.pixman_color_t = .{ .red = 0, .green = 0, .blue = 0, .alpha = alpha };
    return pixman.pixman_image_create_solid_fill(&color) orelse error.OutOfMemory;
}

fn scaleMask(mask: *pixman.pixman_image_t, factor: u32) void {
    if (factor == std.math.maxInt(u32)) return;
    const data: [*]u8 = @ptrCast(pixman.pixman_image_get_data(mask));
    const stride: usize = @intCast(pixman.pixman_image_get_stride(mask));
    const width: usize = @intCast(pixman.pixman_image_get_width(mask));
    const height: usize = @intCast(pixman.pixman_image_get_height(mask));
    for (0..height) |y| for (data[y * stride ..][0..width]) |*value| {
        value.* = @intCast((@as(u64, value.*) * factor + std.math.maxInt(u32) / 2) / std.math.maxInt(u32));
    };
}

fn sourceTransform(
    image: render_types.Image,
    source: render_types.SourceRect,
    y_inverted: bool,
) pixman.pixman_f_transform_t {
    const scale_x = source.width / @as(f64, @floatFromInt(image.size.width));
    const scale_y = source.height / @as(f64, @floatFromInt(image.size.height));
    const buffer_width: f64 = @floatFromInt(image.buffer.size.width);
    const buffer_height: f64 = @floatFromInt(image.buffer.size.height);
    var matrix: [3][3]f64 = switch (image.transform) {
        .normal => .{
            .{ scale_x, 0, source.x },
            .{ 0, scale_y, source.y },
            .{ 0, 0, 1 },
        },
        .rotate_90 => .{
            .{ 0, scale_y, source.y },
            .{ -scale_x, 0, buffer_height - source.x },
            .{ 0, 0, 1 },
        },
        .rotate_180 => .{
            .{ -scale_x, 0, buffer_width - source.x },
            .{ 0, -scale_y, buffer_height - source.y },
            .{ 0, 0, 1 },
        },
        .rotate_270 => .{
            .{ 0, -scale_y, buffer_width - source.y },
            .{ scale_x, 0, source.x },
            .{ 0, 0, 1 },
        },
        .flipped => .{
            .{ -scale_x, 0, buffer_width - source.x },
            .{ 0, scale_y, source.y },
            .{ 0, 0, 1 },
        },
        .flipped_90 => .{
            .{ 0, -scale_y, buffer_width - source.y },
            .{ -scale_x, 0, buffer_height - source.x },
            .{ 0, 0, 1 },
        },
        .flipped_180 => .{
            .{ scale_x, 0, source.x },
            .{ 0, -scale_y, buffer_height - source.y },
            .{ 0, 0, 1 },
        },
        .flipped_270 => .{
            .{ 0, scale_y, source.y },
            .{ scale_x, 0, source.x },
            .{ 0, 0, 1 },
        },
    };
    if (y_inverted) {
        matrix[1][0] = -matrix[1][0];
        matrix[1][1] = -matrix[1][1];
        matrix[1][2] = buffer_height - matrix[1][2];
    }
    return .{ .m = matrix };
}

fn validSourceRect(source: render_types.SourceRect, buffer_size: render_types.Size) bool {
    return std.math.isFinite(source.x) and std.math.isFinite(source.y) and
        std.math.isFinite(source.width) and std.math.isFinite(source.height) and
        source.x >= 0 and source.y >= 0 and source.width > 0 and source.height > 0 and
        source.x + source.width <= @as(f64, @floatFromInt(buffer_size.width)) and
        source.y + source.height <= @as(f64, @floatFromInt(buffer_size.height));
}

fn createRoundedMask(
    size: render_types.Size,
    requested_radius: u32,
) Error!*pixman.pixman_image_t {
    const mask = pixman.pixman_image_create_bits(
        pixman.PIXMAN_a8,
        @intCast(size.width),
        @intCast(size.height),
        null,
        0,
    ) orelse return error.OutOfMemory;
    errdefer _ = pixman.pixman_image_unref(mask);

    const data: [*]u8 = @ptrCast(pixman.pixman_image_get_data(mask));
    const stride: usize = @intCast(pixman.pixman_image_get_stride(mask));
    const radius = @min(requested_radius, @min(size.width, size.height) / 2);
    if (radius == 0) {
        for (0..size.height) |y| @memset(data[y * stride ..][0..size.width], 255);
        return mask;
    }

    const radius_float: f32 = @floatFromInt(radius);
    for (0..size.height) |y| {
        for (0..size.width) |x| {
            const pixel_x: f32 = @as(f32, @floatFromInt(x)) + 0.5;
            const pixel_y: f32 = @as(f32, @floatFromInt(y)) + 0.5;
            const center_x: f32 = if (x < radius)
                radius_float
            else if (x >= size.width - radius)
                @floatFromInt(size.width - radius)
            else
                pixel_x;
            const center_y: f32 = if (y < radius)
                radius_float
            else if (y >= size.height - radius)
                @floatFromInt(size.height - radius)
            else
                pixel_y;
            const distance = @sqrt(
                (pixel_x - center_x) * (pixel_x - center_x) +
                    (pixel_y - center_y) * (pixel_y - center_y),
            );
            const coverage = std.math.clamp(radius_float + 0.5 - distance, 0.0, 1.0);
            data[y * stride + x] = @intFromFloat(coverage * 255.0);
        }
    }
    return mask;
}

fn fill(
    destination: *pixman.pixman_image_t,
    rect: render_types.Rect,
    color: render_types.Color,
    operator: pixman.pixman_op_t,
) Error!void {
    std.debug.assert(rect.width > 0 and rect.height > 0);

    const pixman_color: pixman.pixman_color_t = .{
        .red = expand(color.red),
        .green = expand(color.green),
        .blue = expand(color.blue),
        .alpha = expand(color.alpha),
    };
    const box: pixman.pixman_box32_t = .{
        .x1 = rect.x,
        .y1 = rect.y,
        .x2 = rect.x + @as(i32, @intCast(rect.width)),
        .y2 = rect.y + @as(i32, @intCast(rect.height)),
    };

    if (pixman.pixman_image_fill_boxes(operator, destination, &pixman_color, 1, &box) == 0) {
        return error.OutOfMemory;
    }
}

fn expand(component: u8) u16 {
    return @as(u16, component) * 257;
}

test "CPU renderer draws clipped premultiplied rectangles" {
    const size: render_types.Size = .{ .width = 4, .height = 3 };
    var output = try headless.init(std.testing.allocator, size);
    defer output.deinit();

    const commands = [_]render_types.Command{
        .{ .clear = render_types.Color.rgba(0, 0, 255, 255) },
        .{ .solid_rect = .{
            .rect = .{ .x = -1, .y = 1, .width = 3, .height = 2 },
            .color = render_types.Color.rgba(255, 0, 0, 128),
            .clip = .{ .x = 1, .y = 0, .width = 1, .height = 3 },
        } },
    };

    var renderer = Self.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.render(.{ .size = size, .commands = &commands }, output.target());

    try std.testing.expectEqual(@as(u32, 0xff0000ff), output.pixel(0, 0));
    try std.testing.expectEqual(@as(u32, 0xff0000ff), output.pixel(0, 1));
    try std.testing.expectEqual(@as(u32, 0xff80007f), output.pixel(1, 2));
    try std.testing.expectEqual(@as(u32, 0xff0000ff), output.pixel(2, 1));
}

test "CPU renderer rejects undersized targets" {
    var renderer = Self.init(std.testing.allocator);
    defer renderer.deinit();

    var pixels = [_]u32{0} ** 3;
    const target: render_types.PixelBuffer = .{
        .size = .{ .width = 2, .height = 2 },
        .stride_pixels = 2,
        .pixels = &pixels,
    };

    try std.testing.expectError(error.InvalidTarget, renderer.render(.{
        .size = target.size,
        .commands = &.{},
    }, target));
}

test "CPU renderer composites clipped images" {
    const size: render_types.Size = .{ .width = 3, .height = 2 };
    var output = try headless.init(std.testing.allocator, size);
    defer output.deinit();

    var source_pixels = [_]u32{
        0xffff0000, 0xff00ff00,
        0xff0000ff, 0x80808080,
    };
    const commands = [_]render_types.Command{
        .{ .clear = render_types.Color.rgba(0, 0, 0, 255) },
        .{ .image = .{
            .x = -1,
            .y = 0,
            .size = .{ .width = 2, .height = 2 },
            .buffer = .{
                .size = .{ .width = 2, .height = 2 },
                .stride_pixels = 2,
                .pixels = &source_pixels,
            },
            .clip = .{ .x = 0, .y = 1, .width = 1, .height = 1 },
        } },
    };

    var renderer = Self.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.render(.{ .size = size, .commands = &commands }, output.target());

    try std.testing.expectEqual(@as(u32, 0xff000000), output.pixel(0, 0));
    try std.testing.expectEqual(@as(u32, 0xff808080), output.pixel(0, 1));
    try std.testing.expectEqual(@as(u32, 0xff000000), output.pixel(1, 0));
}

test "CPU renderer scales images to logical size" {
    var output = try headless.init(std.testing.allocator, .{ .width = 1, .height = 1 });
    defer output.deinit();

    var source_pixels = [_]u32{0xff336699} ** 4;
    const commands = [_]render_types.Command{
        .{ .image = .{
            .x = 0,
            .y = 0,
            .size = .{ .width = 1, .height = 1 },
            .buffer = .{
                .size = .{ .width = 2, .height = 2 },
                .stride_pixels = 2,
                .pixels = &source_pixels,
            },
        } },
    };

    var renderer = Self.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.render(.{
        .size = .{ .width = 1, .height = 1 },
        .commands = &commands,
    }, output.target());

    try std.testing.expectEqual(@as(u32, 0xff336699), output.pixel(0, 0));
}

test "CPU renderer applies every buffer transform" {
    var source_pixels = [_]u32{
        0xff010101, 0xff020202,
        0xff030303, 0xff040404,
        0xff050505, 0xff060606,
    };
    const Case = struct {
        transform: render_types.BufferTransform,
        size: render_types.Size,
        expected: []const u32,
    };
    const cases = [_]Case{
        .{ .transform = .normal, .size = .{ .width = 2, .height = 3 }, .expected = &.{
            0xff010101, 0xff020202,
            0xff030303, 0xff040404,
            0xff050505, 0xff060606,
        } },
        .{ .transform = .rotate_90, .size = .{ .width = 3, .height = 2 }, .expected = &.{
            0xff050505, 0xff030303, 0xff010101,
            0xff060606, 0xff040404, 0xff020202,
        } },
        .{ .transform = .rotate_180, .size = .{ .width = 2, .height = 3 }, .expected = &.{
            0xff060606, 0xff050505,
            0xff040404, 0xff030303,
            0xff020202, 0xff010101,
        } },
        .{ .transform = .rotate_270, .size = .{ .width = 3, .height = 2 }, .expected = &.{
            0xff020202, 0xff040404, 0xff060606,
            0xff010101, 0xff030303, 0xff050505,
        } },
        .{ .transform = .flipped, .size = .{ .width = 2, .height = 3 }, .expected = &.{
            0xff020202, 0xff010101,
            0xff040404, 0xff030303,
            0xff060606, 0xff050505,
        } },
        .{ .transform = .flipped_90, .size = .{ .width = 3, .height = 2 }, .expected = &.{
            0xff060606, 0xff040404, 0xff020202,
            0xff050505, 0xff030303, 0xff010101,
        } },
        .{ .transform = .flipped_180, .size = .{ .width = 2, .height = 3 }, .expected = &.{
            0xff050505, 0xff060606,
            0xff030303, 0xff040404,
            0xff010101, 0xff020202,
        } },
        .{ .transform = .flipped_270, .size = .{ .width = 3, .height = 2 }, .expected = &.{
            0xff010101, 0xff030303, 0xff050505,
            0xff020202, 0xff040404, 0xff060606,
        } },
    };

    var renderer = Self.init(std.testing.allocator);
    defer renderer.deinit();
    var output_pixels: [source_pixels.len]u32 = undefined;
    for (cases) |case| {
        @memset(&output_pixels, 0);
        const command = [_]render_types.Command{.{ .image = .{
            .x = 0,
            .y = 0,
            .size = case.size,
            .buffer = .{
                .size = .{ .width = 2, .height = 3 },
                .stride_pixels = 2,
                .pixels = &source_pixels,
            },
            .transform = case.transform,
        } }};
        try renderer.render(.{ .size = case.size, .commands = &command }, .{
            .size = case.size,
            .stride_pixels = case.size.width,
            .pixels = &output_pixels,
        });
        try std.testing.expectEqualSlices(u32, case.expected, &output_pixels);
    }
}

test "CPU renderer crops in post-transform coordinates" {
    var source_pixels = [_]u32{
        0xff010101, 0xff020202,
        0xff030303, 0xff040404,
        0xff050505, 0xff060606,
    };
    var output_pixels: [2]u32 = undefined;
    const size: render_types.Size = .{ .width = 2, .height = 1 };
    const command = [_]render_types.Command{.{ .image = .{
        .x = 0,
        .y = 0,
        .size = size,
        .buffer = .{
            .size = .{ .width = 2, .height = 3 },
            .stride_pixels = 2,
            .pixels = &source_pixels,
        },
        .source = .{ .x = 1, .y = 0, .width = 2, .height = 1 },
        .transform = .rotate_90,
    } }};
    var renderer = Self.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.render(.{ .size = size, .commands = &command }, .{
        .size = size,
        .stride_pixels = size.width,
        .pixels = &output_pixels,
    });

    try std.testing.expectEqualSlices(u32, &.{ 0xff030303, 0xff010101 }, &output_pixels);
}

test "CPU renderer crops an image source rectangle" {
    var output = try headless.init(std.testing.allocator, .{ .width = 2, .height = 1 });
    defer output.deinit();

    var source_pixels = [_]u32{ 0xffff0000, 0xff00ff00, 0xff0000ff, 0xffffffff };
    const commands = [_]render_types.Command{
        .{ .image = .{
            .x = 0,
            .y = 0,
            .size = .{ .width = 2, .height = 1 },
            .buffer = .{
                .size = .{ .width = 4, .height = 1 },
                .stride_pixels = 4,
                .pixels = &source_pixels,
            },
            .source = .{ .x = 1, .y = 0, .width = 2, .height = 1 },
        } },
    };

    var renderer = Self.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.render(.{
        .size = .{ .width = 2, .height = 1 },
        .commands = &commands,
    }, output.target());

    try std.testing.expectEqual(@as(u32, 0xff00ff00), output.pixel(0, 0));
    try std.testing.expectEqual(@as(u32, 0xff0000ff), output.pixel(1, 0));
}

test "CPU renderer clips image corners with an antialiased mask" {
    const size: render_types.Size = .{ .width = 4, .height = 4 };
    var output = try headless.init(std.testing.allocator, size);
    defer output.deinit();

    var source_pixels = [_]u32{0xffffffff} ** 16;
    const commands = [_]render_types.Command{
        .{ .image = .{
            .x = 0,
            .y = 0,
            .size = size,
            .buffer = .{
                .size = size,
                .stride_pixels = size.width,
                .pixels = &source_pixels,
            },
            .rounded_clip = .{
                .rect = .{ .x = 0, .y = 0, .width = size.width, .height = size.height },
                .radius = 2,
            },
        } },
    };

    var renderer = Self.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.render(.{ .size = size, .commands = &commands }, output.target());

    const corner_alpha: u8 = @truncate(output.pixel(0, 0) >> 24);
    try std.testing.expect(corner_alpha > 0 and corner_alpha < 255);
    try std.testing.expectEqual(@as(u32, 0xffffffff), output.pixel(1, 1));
}

test "CPU renderer applies alpha multiplier to premultiplied and opaque pixels" {
    const size: render_types.Size = .{ .width = 1, .height = 1 };
    var output = try headless.init(std.testing.allocator, size);
    defer output.deinit();
    var renderer = Self.init(std.testing.allocator);
    defer renderer.deinit();

    var source = [_]u32{0xffff0000};
    const image: render_types.Image = .{
        .x = 0,
        .y = 0,
        .size = size,
        .buffer = .{ .size = size, .stride_pixels = 1, .pixels = &source },
        .alpha_multiplier = 0x8000_0000,
    };
    const commands = [_]render_types.Command{
        .{ .clear = render_types.Color.rgba(0, 0, 255, 255) },
        .{ .image = image },
    };
    try renderer.render(.{ .size = size, .commands = &commands }, output.target());
    try std.testing.expectEqual(@as(u32, 0xff80007f), output.pixel(0, 0));

    source[0] = 0x80400000;
    output.target().pixels[0] = 0;
    try renderer.render(.{ .size = size, .commands = &.{.{ .image = image }} }, output.target());
    try std.testing.expectEqual(@as(u32, 0x40200000), output.pixel(0, 0));

    var zero = image;
    zero.alpha_multiplier = 0;
    output.target().pixels[0] = 0xff123456;
    try renderer.render(.{ .size = size, .commands = &.{.{ .image = zero }} }, output.target());
    try std.testing.expectEqual(@as(u32, 0xff123456), output.pixel(0, 0));
}

test "CPU renderer positions rounded clips independently from images" {
    const size: render_types.Size = .{ .width = 6, .height = 4 };
    var output = try headless.init(std.testing.allocator, size);
    defer output.deinit();

    var source_pixels = [_]u32{0xffffffff} ** 24;
    const commands = [_]render_types.Command{
        .{ .image = .{
            .x = 0,
            .y = 0,
            .size = size,
            .buffer = .{
                .size = size,
                .stride_pixels = size.width,
                .pixels = &source_pixels,
            },
            .rounded_clip = .{
                .rect = .{ .x = 2, .y = 0, .width = 4, .height = 4 },
                .radius = 2,
            },
        } },
    };

    var renderer = Self.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.render(.{ .size = size, .commands = &commands }, output.target());

    try std.testing.expectEqual(@as(u32, 0), output.pixel(1, 1));
    const corner_alpha: u8 = @truncate(output.pixel(2, 0) >> 24);
    try std.testing.expect(corner_alpha > 0 and corner_alpha < 255);
    try std.testing.expectEqual(@as(u32, 0xffffffff), output.pixel(3, 1));
}

test "CPU renderer draws blurred rounded shadows" {
    const size: render_types.Size = .{ .width = 9, .height = 9 };
    var output = try headless.init(std.testing.allocator, size);
    defer output.deinit();

    const commands = [_]render_types.Command{
        .{ .shadow = .{
            .rect = .{ .x = 3, .y = 3, .width = 3, .height = 3 },
            .corner_radius = 1,
            .blur_radius = 2,
            .spread = 0,
            .color = render_types.Color.rgba(0, 0, 0, 255),
            .clip = .{ .x = 4, .y = 0, .width = 1, .height = 9 },
        } },
    };

    var renderer = Self.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.render(.{ .size = size, .commands = &commands }, output.target());

    const center_alpha: u8 = @truncate(output.pixel(4, 4) >> 24);
    try std.testing.expect(center_alpha > 0);
    const tail_alpha: u8 = @truncate(output.pixel(4, 0) >> 24);
    try std.testing.expect(tail_alpha > 0);
    try std.testing.expectEqual(@as(u32, 0), output.pixel(3, 4));
    try std.testing.expectEqual(@as(u32, 0), output.pixel(5, 4));
    try std.testing.expectEqual(@as(u32, 0), output.pixel(8, 8));
}

test "CPU renderer cuts the rounded window interior out of shadows" {
    const size: render_types.Size = .{ .width = 15, .height = 15 };
    var output = try headless.init(std.testing.allocator, size);
    defer output.deinit();

    const commands = [_]render_types.Command{
        .{ .shadow = .{
            .rect = .{ .x = 4, .y = 6, .width = 7, .height = 7 },
            .corner_radius = 2,
            .blur_radius = 3,
            .spread = 0,
            .color = render_types.Color.rgba(0, 0, 0, 255),
            .cutout = .{
                .rect = .{ .x = 4, .y = 4, .width = 7, .height = 7 },
                .radius = 2,
            },
        } },
    };

    var renderer = Self.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.render(.{ .size = size, .commands = &commands }, output.target());

    try std.testing.expectEqual(@as(u32, 0), output.pixel(7, 7));
    try std.testing.expect(@as(u8, @truncate(output.pixel(7, 12) >> 24)) > 0);
    try std.testing.expect(@as(u8, @truncate(output.pixel(4, 4) >> 24)) > 0);
}

test "CPU renderer bounds shadow work to the clipped output" {
    const size: render_types.Size = .{ .width = 9, .height = 9 };
    var output = try headless.init(std.testing.allocator, size);
    defer output.deinit();

    const commands = [_]render_types.Command{
        .{ .shadow = .{
            .rect = .{
                .x = 0,
                .y = 0,
                .width = std.math.maxInt(i32),
                .height = std.math.maxInt(i32),
            },
            .corner_radius = 0,
            .blur_radius = 2,
            .spread = 0,
            .color = render_types.Color.rgba(0, 0, 0, 255),
            .clip = .{ .x = 4, .y = 4, .width = 1, .height = 1 },
        } },
    };

    var renderer = Self.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.render(.{ .size = size, .commands = &commands }, output.target());

    try std.testing.expectEqual(@as(u32, 0xff000000), output.pixel(4, 4));
    try std.testing.expectEqual(@as(u32, 0), output.pixel(3, 4));
}

test "CPU renderer applies dual Kawase blur inside a window region" {
    const size: render_types.Size = .{ .width = 5, .height = 1 };
    var output = try headless.init(std.testing.allocator, size);
    defer output.deinit();

    const target = output.target();
    @memcpy(target.pixels[0..5], &[_]u32{
        0xff000000,
        0xff000000,
        0xffffffff,
        0xff000000,
        0xff000000,
    });
    const commands = [_]render_types.Command{
        .{ .backdrop_capture = .{
            .rect = .{ .x = 1, .y = 0, .width = 3, .height = 1 },
            .radius = 1,
        } },
        .{ .backdrop_blur = .{
            .rect = .{ .x = 1, .y = 0, .width = 3, .height = 1 },
            .corner_radius = 0,
            .radius = 1,
            .clip = .{ .x = 2, .y = 0, .width = 1, .height = 1 },
        } },
    };

    var renderer = Self.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.render(.{ .size = size, .commands = &commands }, target);

    try std.testing.expectEqual(@as(u32, 0xff000000), output.pixel(0, 0));
    try std.testing.expectEqual(@as(u32, 0xff000000), output.pixel(1, 0));
    try std.testing.expectEqual(@as(u32, 0xff979797), output.pixel(2, 0));
    try std.testing.expectEqual(@as(u32, 0xff000000), output.pixel(3, 0));
    try std.testing.expectEqual(@as(u32, 0xff000000), output.pixel(4, 0));
}

test "CPU backdrop blur only requires a capture when visible" {
    const size: render_types.Size = .{ .width = 2, .height = 1 };
    var output = try headless.init(std.testing.allocator, size);
    defer output.deinit();

    const invisible = [_]render_types.Command{
        .{ .backdrop_blur = .{
            .rect = .{ .x = 2, .y = 0, .width = 1, .height = 1 },
            .corner_radius = 0,
            .radius = 1,
        } },
        .{ .backdrop_blur = .{
            .rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
            .corner_radius = 0,
            .radius = 1,
            .clip = .{ .x = 1, .y = 0, .width = 1, .height = 1 },
        } },
    };
    var renderer = Self.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.render(.{ .size = size, .commands = &invisible }, output.target());

    const visible = [_]render_types.Command{.{ .backdrop_blur = .{
        .rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .corner_radius = 0,
        .radius = 1,
    } }};
    try std.testing.expectError(
        error.InvalidTarget,
        renderer.render(.{ .size = size, .commands = &visible }, output.target()),
    );
}

test "CPU backdrop capture excludes owner content emitted after it" {
    const size: render_types.Size = .{ .width = 3, .height = 1 };
    var output = try headless.init(std.testing.allocator, size);
    defer output.deinit();

    const target = output.target();
    @memset(target.pixels[0..3], 0xff000000);
    const commands = [_]render_types.Command{
        .{ .backdrop_capture = .{
            .rect = .{ .x = 0, .y = 0, .width = 3, .height = 1 },
            .radius = 1,
        } },
        .{ .solid_rect = .{
            .rect = .{ .x = 1, .y = 0, .width = 1, .height = 1 },
            .color = render_types.Color.rgba(255, 255, 255, 255),
        } },
        .{ .backdrop_blur = .{
            .rect = .{ .x = 1, .y = 0, .width = 1, .height = 1 },
            .corner_radius = 0,
            .radius = 1,
        } },
    };

    var renderer = Self.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.render(.{ .size = size, .commands = &commands }, target);

    try std.testing.expectEqual(@as(u32, 0xff000000), output.pixel(1, 0));
}

test "CPU backdrop blur keeps its capture across an interleaved owner" {
    const size: render_types.Size = .{ .width = 3, .height = 1 };
    var output = try headless.init(std.testing.allocator, size);
    defer output.deinit();

    const target = output.target();
    @memset(target.pixels[0..3], 0xff000000);
    const commands = [_]render_types.Command{
        .{ .backdrop_capture = .{
            .id = 1,
            .rect = .{ .x = 0, .y = 0, .width = 3, .height = 1 },
            .radius = 1,
        } },
        .{ .solid_rect = .{
            .rect = .{ .x = 1, .y = 0, .width = 1, .height = 1 },
            .color = render_types.Color.rgba(255, 255, 255, 255),
        } },
        .{ .backdrop_capture = .{
            .id = 2,
            .rect = .{ .x = 0, .y = 0, .width = 3, .height = 1 },
            .radius = 1,
        } },
        .{ .backdrop_blur = .{
            .capture_id = 1,
            .rect = .{ .x = 1, .y = 0, .width = 1, .height = 1 },
            .corner_radius = 0,
            .radius = 1,
        } },
    };

    var renderer = Self.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.render(.{ .size = size, .commands = &commands }, target);

    try std.testing.expectEqual(@as(u32, 0xff000000), output.pixel(1, 0));
}

test "CPU backdrop blur snapshots disjoint damage before compositing" {
    const size: render_types.Size = .{ .width = 5, .height = 1 };
    var output = try headless.init(std.testing.allocator, size);
    defer output.deinit();

    const target = output.target();
    @memcpy(target.pixels[0..5], &[_]u32{
        0xff000000,
        0xff000000,
        0xffffffff,
        0xff000000,
        0xff000000,
    });
    const commands = [_]render_types.Command{
        .{ .backdrop_capture = .{
            .rect = .{ .x = 0, .y = 0, .width = 5, .height = 1 },
            .radius = 1,
        } },
        .{ .backdrop_blur = .{
            .rect = .{ .x = 0, .y = 0, .width = 5, .height = 1 },
            .corner_radius = 0,
            .radius = 1,
        } },
    };
    const damage = [_]render_types.Rect{
        .{ .x = 1, .y = 0, .width = 1, .height = 1 },
        .{ .x = 2, .y = 0, .width = 1, .height = 1 },
    };

    var renderer = Self.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.render(.{ .size = size, .commands = &commands, .damage = &damage }, target);

    try std.testing.expectEqual(@as(u32, 0xff303030), output.pixel(1, 0));
    try std.testing.expectEqual(@as(u32, 0xff979797), output.pixel(2, 0));
    try std.testing.expectEqual(@as(u32, 0xff000000), output.pixel(3, 0));
}

test "CPU renderer clips writes to frame damage and preserves stride padding" {
    const untouched = 0x1122_3344;
    var pixels = [_]u32{untouched} ** 10;
    const target: render_types.PixelBuffer = .{
        .size = .{ .width = 3, .height = 2 },
        .stride_pixels = 5,
        .pixels = &pixels,
    };
    const commands = [_]render_types.Command{
        .{ .clear = render_types.Color.rgba(255, 0, 0, 255) },
    };
    const damage = [_]render_types.Rect{
        .{ .x = 1, .y = 0, .width = 2, .height = 2 },
    };

    var renderer = Self.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.render(.{
        .size = target.size,
        .commands = &commands,
        .damage = &damage,
    }, target);

    try std.testing.expectEqualSlices(
        u32,
        &.{
            untouched, 0xffff0000, 0xffff0000, untouched, untouched,
            untouched, 0xffff0000, 0xffff0000, untouched, untouched,
        },
        &pixels,
    );
}
