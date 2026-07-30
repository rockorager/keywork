//! Pixman-backed CPU renderer.

const Self = @This();

const std = @import("std");
const headless = @import("../backend/headless.zig");
const render_types = @import("types.zig");
const blur_geometry = @import("blur_geometry.zig");
const dual_kawase = @import("dual_kawase.zig");
const rect_region = @import("rect_region.zig");

const pixman = @cImport({
    @cInclude("pixman.h");
});

allocator: std.mem.Allocator,
rounded_masks: RoundedMaskCache,

pub const Error = error{
    InvalidTarget,
    OutOfMemory,
};

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .allocator = allocator,
        .rounded_masks = .init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.rounded_masks.deinit();
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
    for (frame.commands, 0..) |command, command_index| {
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
            .shadow => |shadow| try drawShadow(destination, frame.size, shadow, frame.damage),
            .backdrop_capture => |marker| {
                if (!backdropCaptureRequired(
                    frame.commands[command_index + 1 ..],
                    marker.id,
                    frame.size,
                    frame.damage,
                )) continue;
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
            .image => |image| try composite(destination, frame.size, image, &self.rounded_masks),
            .crossfade => |crossfade| try self.compositeCrossfade(
                destination,
                frame.size,
                crossfade,
                &self.rounded_masks,
                frame.damage,
            ),
        }
    }
}

/// A later capture with the same ID supersedes this one for subsequent blur
/// commands, matching backdropSnapshot's nearest-preceding lookup.
fn backdropCaptureRequired(
    commands: []const render_types.Command,
    id: u32,
    frame_size: render_types.Size,
    damage: ?[]const render_types.Rect,
) bool {
    for (commands) |command| switch (command) {
        .backdrop_capture => |capture| if (capture.id == id) return false,
        .backdrop_blur => |blur| {
            if (blur.capture_id != id or blur.radius == 0 or
                blur.rect.width == 0 or blur.rect.height == 0) continue;
            var clipped = blur.rect.clipTo(frame_size) orelse continue;
            if (blur.clip) |clip| clipped = clipped.intersection(clip) orelse continue;
            if (rect_region.damageBounds(damage, clipped) != null) return true;
        },
        else => {},
    };
    return false;
}

fn compositeCrossfade(
    self: *Self,
    destination: *pixman.pixman_image_t,
    destination_size: render_types.Size,
    fade: render_types.Crossfade,
    rounded_masks: *RoundedMaskCache,
    damage: ?[]const render_types.Rect,
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
    if (fade.factor == 0 or fade.factor == std.math.maxInt(u32)) {
        return composite(destination, destination_size, .{
            .x = fade.destination.x,
            .y = fade.destination.y,
            .size = .{
                .width = fade.destination.width,
                .height = fade.destination.height,
            },
            .buffer = if (fade.factor == 0) old else new,
            .source = if (fade.factor == 0) fade.old_source else fade.new_source,
            .rounded_clip = fade.rounded_clip,
            .clip = fade.clip,
        }, rounded_masks);
    }
    var clipped = fade.destination.clipTo(destination_size) orelse return;
    if (fade.clip) |clip| clipped = clipped.intersection(clip) orelse return;
    if (fade.rounded_clip) |clip| clipped = clipped.intersection(clip.rect) orelse return;
    if (damage) |rectangles| {
        for (rectangles) |rectangle| {
            const damaged = clipped.intersection(rectangle) orelse continue;
            try self.compositeCrossfadeRect(
                destination,
                destination_size,
                fade,
                old,
                new,
                damaged,
                rounded_masks,
            );
        }
    } else {
        try self.compositeCrossfadeRect(
            destination,
            destination_size,
            fade,
            old,
            new,
            clipped,
            rounded_masks,
        );
    }
}

fn compositeCrossfadeRect(
    self: *Self,
    destination: *pixman.pixman_image_t,
    destination_size: render_types.Size,
    fade: render_types.Crossfade,
    old: render_types.PixelBuffer,
    new: render_types.PixelBuffer,
    clipped: render_types.Rect,
    rounded_masks: *RoundedMaskCache,
) Error!void {
    const count = std.math.mul(usize, clipped.width, clipped.height) catch
        return error.InvalidTarget;
    const mixed_pixels = self.allocator.alloc(u32, count) catch return error.OutOfMemory;
    defer self.allocator.free(mixed_pixels);
    @memset(mixed_pixels, 0);
    const local_size: render_types.Size = .{ .width = clipped.width, .height = clipped.height };
    const mixed_target = try createImage(.{ .size = local_size, .stride_pixels = local_size.width, .pixels = mixed_pixels }, false, false);
    defer _ = pixman.pixman_image_unref(mixed_target);
    const local_x = fade.destination.x -| clipped.x;
    const local_y = fade.destination.y -| clipped.y;
    try compositeWithOperator(mixed_target, local_size, .{
        .x = local_x,
        .y = local_y,
        .size = .{ .width = fade.destination.width, .height = fade.destination.height },
        .buffer = old,
        .source = fade.old_source,
        .alpha_multiplier = std.math.maxInt(u32) - fade.factor,
    }, rounded_masks, pixman.PIXMAN_OP_SRC);
    try compositeWithOperator(mixed_target, local_size, .{
        .x = local_x,
        .y = local_y,
        .size = .{ .width = fade.destination.width, .height = fade.destination.height },
        .buffer = new,
        .source = fade.new_source,
        .alpha_multiplier = fade.factor,
    }, rounded_masks, pixman.PIXMAN_OP_ADD);
    try compositePixels(destination, destination_size, .{
        .x = clipped.x,
        .y = clipped.y,
        .size = local_size,
        .buffer = .{ .size = local_size, .stride_pixels = local_size.width, .pixels = mixed_pixels },
        .rounded_clip = fade.rounded_clip,
    }, false, false, false, rounded_masks, null);
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

test "CPU renderer does not allocate an unreferenced backdrop capture" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
    });
    var renderer = init(failing_allocator.allocator());
    defer renderer.deinit();
    var pixel = [_]u32{0xff112233};
    const commands = [_]render_types.Command{.{ .backdrop_capture = .{
        .id = 1,
        .rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .radius = 1,
        .base = true,
    } }};

    try renderer.render(.{
        .size = .{ .width = 1, .height = 1 },
        .commands = &commands,
    }, .{
        .size = .{ .width = 1, .height = 1 },
        .stride_pixels = 1,
        .pixels = &pixel,
    });
    try std.testing.expect(!failing_allocator.has_induced_failure);
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
    damage: ?[]const render_types.Rect,
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

    const radius_value = @max(@as(i64, shadow.corner_radius) + spread, 0);
    const cutout_radius = if (shadow.cutout) |cutout|
        @min(
            cutout.radius,
            @min(cutout.rect.width, cutout.rect.height) / 2,
        )
    else
        0;
    const raster: ShadowRaster = .{
        .shape_left = @floatFromInt(shape_x),
        .shape_top = @floatFromInt(shape_y),
        .shape_width = @floatFromInt(shape_width),
        .shape_height = @floatFromInt(shape_height),
        .radius = @floatFromInt(@min(
            radius_value,
            @divTrunc(@min(shape_width, shape_height), 2),
        )),
        .blur_radius = @floatFromInt(shadow.blur_radius),
        .cutout = if (shadow.cutout) |cutout| .{
            .left = @floatFromInt(cutout.rect.x),
            .top = @floatFromInt(cutout.rect.y),
            .width = @floatFromInt(cutout.rect.width),
            .height = @floatFromInt(cutout.rect.height),
            .radius = @floatFromInt(cutout_radius),
        } else null,
    };
    const color: pixman.pixman_color_t = .{
        .red = expand(shadow.color.red),
        .green = expand(shadow.color.green),
        .blue = expand(shadow.color.blue),
        .alpha = expand(shadow.color.alpha),
    };
    const source = pixman.pixman_image_create_solid_fill(&color) orelse
        return error.OutOfMemory;
    defer _ = pixman.pixman_image_unref(source);
    const cutout_interior = if (shadow.cutout) |cutout|
        rect_region.roundedRectInterior(cutout.rect, cutout_radius)
    else
        null;
    if (damage) |rectangles| {
        for (rectangles) |rectangle| {
            const damaged = composite_rect.intersection(rectangle) orelse continue;
            try drawShadowDamage(destination, source, raster, damaged, cutout_interior);
        }
    } else {
        try drawShadowDamage(destination, source, raster, composite_rect, cutout_interior);
    }
}

const ShadowRaster = struct {
    const Rounded = struct {
        left: f64,
        top: f64,
        width: f64,
        height: f64,
        radius: f64,
    };

    shape_left: f64,
    shape_top: f64,
    shape_width: f64,
    shape_height: f64,
    radius: f64,
    blur_radius: f64,
    cutout: ?Rounded,
};

fn drawShadowDamage(
    destination: *pixman.pixman_image_t,
    source: *pixman.pixman_image_t,
    raster: ShadowRaster,
    rect: render_types.Rect,
    cutout_interior: ?render_types.Rect,
) Error!void {
    if (cutout_interior) |interior| {
        for (rect_region.differenceStrips(rect, interior)) |strip| {
            try drawShadowRect(destination, source, raster, strip orelse continue);
        }
    } else {
        try drawShadowRect(destination, source, raster, rect);
    }
}

fn drawShadowRect(
    destination: *pixman.pixman_image_t,
    source: *pixman.pixman_image_t,
    raster: ShadowRaster,
    rect: render_types.Rect,
) Error!void {
    const mask = pixman.pixman_image_create_bits(
        pixman.PIXMAN_a8,
        @intCast(rect.width),
        @intCast(rect.height),
        null,
        0,
    ) orelse return error.OutOfMemory;
    defer _ = pixman.pixman_image_unref(mask);

    const data: [*]u8 = @ptrCast(pixman.pixman_image_get_data(mask));
    const stride: usize = @intCast(pixman.pixman_image_get_stride(mask));
    for (0..rect.height) |y| {
        for (0..rect.width) |x| {
            const pixel_x: f64 = @as(f64, @floatFromInt(rect.x)) +
                @as(f64, @floatFromInt(x)) + 0.5;
            const pixel_y: f64 = @as(f64, @floatFromInt(rect.y)) +
                @as(f64, @floatFromInt(y)) + 0.5;
            var cutout_alpha: f64 = 1;
            if (raster.cutout) |cutout| {
                cutout_alpha -= roundedRectCoverage(
                    pixel_x,
                    pixel_y,
                    cutout.left,
                    cutout.top,
                    cutout.width,
                    cutout.height,
                    cutout.radius,
                );
                if (cutout_alpha == 0) {
                    data[y * stride + x] = 0;
                    continue;
                }
            }
            const coverage = roundedBoxShadowCoverage(
                pixel_x,
                pixel_y,
                raster.shape_left,
                raster.shape_top,
                raster.shape_width,
                raster.shape_height,
                raster.radius,
                raster.blur_radius,
            ) * cutout_alpha;
            data[y * stride + x] = @intFromFloat(
                std.math.clamp(coverage, 0.0, 1.0) * 255.0 + 0.5,
            );
        }
    }
    pixman.pixman_image_composite32(
        pixman.PIXMAN_OP_OVER,
        source,
        mask,
        destination,
        0,
        0,
        0,
        0,
        rect.x,
        rect.y,
        @intCast(rect.width),
        @intCast(rect.height),
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
    _ = rect_region.damageBounds(damage, clipped) orelse return;
    const snapshot = capture orelse return error.InvalidTarget;
    if (blur.radius != snapshot.marker.radius or
        blur.downsample_level != snapshot.marker.downsample_level or
        !std.meta.eql(blur.finish, snapshot.marker.finish) or
        !snapshot.marker.rect.contains(clipped)) return error.InvalidTarget;
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

const RoundedMaskCache = struct {
    const maximum_entries = 8;
    const maximum_bytes = 32 * 1024 * 1024;

    const Entry = struct {
        size: render_types.Size,
        radius: u32,
        factor: u32,
        image: *pixman.pixman_image_t,
        bytes: usize,
        last_used: u64,
    };

    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    bytes: usize = 0,
    epoch: u64 = 0,

    fn init(allocator: std.mem.Allocator) RoundedMaskCache {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *RoundedMaskCache) void {
        for (self.entries.items) |entry| _ = pixman.pixman_image_unref(entry.image);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    fn advance(self: *RoundedMaskCache) u64 {
        self.epoch +%= 1;
        if (self.epoch == 0) self.epoch = 1;
        return self.epoch;
    }

    fn get(
        self: *RoundedMaskCache,
        size: render_types.Size,
        requested_radius: u32,
        factor: u32,
    ) Error!*pixman.pixman_image_t {
        const radius = @min(requested_radius, @min(size.width, size.height) / 2);
        const epoch = self.advance();
        for (self.entries.items) |*entry| {
            if (std.meta.eql(entry.size, size) and entry.radius == radius and
                entry.factor == factor)
            {
                entry.last_used = epoch;
                return entry.image;
            }
        }

        const image = try createRoundedMask(size, radius, factor);
        errdefer _ = pixman.pixman_image_unref(image);
        const stride: usize = @intCast(pixman.pixman_image_get_stride(image));
        const bytes = std.math.mul(usize, stride, size.height) catch
            return error.InvalidTarget;
        while (self.entries.items.len > 0 and
            (self.entries.items.len >= maximum_entries or
                self.bytes +| bytes > maximum_bytes))
        {
            var oldest_index: usize = 0;
            for (self.entries.items[1..], 1..) |entry, index| {
                if (entry.last_used < self.entries.items[oldest_index].last_used) {
                    oldest_index = index;
                }
            }
            const oldest = self.entries.swapRemove(oldest_index);
            self.bytes -= oldest.bytes;
            _ = pixman.pixman_image_unref(oldest.image);
        }
        try self.entries.append(self.allocator, .{
            .size = size,
            .radius = radius,
            .factor = factor,
            .image = image,
            .bytes = bytes,
            .last_used = epoch,
        });
        self.bytes += bytes;
        return image;
    }
};

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
    rounded_masks: *RoundedMaskCache,
) Error!void {
    return compositeWithOperator(destination, destination_size, image, rounded_masks, null);
}

fn compositeWithOperator(
    destination: *pixman.pixman_image_t,
    destination_size: render_types.Size,
    image: render_types.Image,
    rounded_masks: *RoundedMaskCache,
    operator: ?pixman.pixman_op_t,
) Error!void {
    const dmabuf = image.buffer.dmabuf orelse
        return compositePixels(destination, destination_size, image, false, false, false, rounded_masks, operator);
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
        rounded_masks,
        operator,
    );
}

fn compositePixels(
    destination: *pixman.pixman_image_t,
    destination_size: render_types.Size,
    image: render_types.Image,
    y_inverted: bool,
    force_opaque: bool,
    red_blue_swapped: bool,
    rounded_masks: *RoundedMaskCache,
    operator: ?pixman.pixman_op_t,
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
    const can_replace = image.is_opaque and
        image.alpha_multiplier == std.math.maxInt(u32);
    const transformed = y_inverted or image.transform != .normal or image.source != null or
        source_rect.width != @as(f64, @floatFromInt(image.size.width)) or
        source_rect.height != @as(f64, @floatFromInt(image.size.height));
    if (transformed) {
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
        // Vulkan's replacement path samples with clamp-to-edge. Without the
        // equivalent Pixman repeat mode, bilinear taps outside an opaque
        // source produce a translucent fringe that PIXMAN_OP_SRC exposes.
        if (can_replace) pixman.pixman_image_set_repeat(source, pixman.PIXMAN_REPEAT_PAD);
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
    var owned_mask: ?*pixman.pixman_image_t = null;
    const mask = if (image.rounded_clip) |clip|
        try rounded_masks.get(
            .{ .width = clip.rect.width, .height = clip.rect.height },
            clip.radius,
            image.alpha_multiplier,
        )
    else if (image.alpha_multiplier != std.math.maxInt(u32)) owned: {
        owned_mask = try createAlphaMask(image.alpha_multiplier);
        break :owned owned_mask;
    } else null;
    defer if (owned_mask) |alpha_mask| {
        _ = pixman.pixman_image_unref(alpha_mask);
    };
    if (operator) |selected| {
        compositeImageRect(selected, source, mask, destination, image, clipped);
        return;
    }
    if (can_replace and image.rounded_clip != null) {
        const rounded = image.rounded_clip.?;
        const radius = @min(
            rounded.radius,
            @min(rounded.rect.width, rounded.rect.height) / 2,
        );
        if (rect_region.roundedRectInterior(rounded.rect, radius)) |interior| {
            if (interior.intersection(clipped)) |opaque_rect| {
                compositeImageRect(
                    pixman.PIXMAN_OP_SRC,
                    source,
                    null,
                    destination,
                    image,
                    opaque_rect,
                );
                for (rect_region.differenceStrips(clipped, opaque_rect)) |strip| {
                    compositeImageRect(
                        pixman.PIXMAN_OP_OVER,
                        source,
                        mask,
                        destination,
                        image,
                        strip orelse continue,
                    );
                }
                return;
            }
        }
    }
    compositeImageRect(
        if (can_replace and image.rounded_clip == null)
            pixman.PIXMAN_OP_SRC
        else
            pixman.PIXMAN_OP_OVER,
        source,
        mask,
        destination,
        image,
        clipped,
    );
}

fn compositeImageRect(
    operator: pixman.pixman_op_t,
    source: *pixman.pixman_image_t,
    mask: ?*pixman.pixman_image_t,
    destination: *pixman.pixman_image_t,
    image: render_types.Image,
    rect: render_types.Rect,
) void {
    pixman.pixman_image_composite32(
        operator,
        source,
        mask,
        destination,
        rect.x - image.x,
        rect.y - image.y,
        if (image.rounded_clip) |clip| rect.x - clip.rect.x else 0,
        if (image.rounded_clip) |clip| rect.y - clip.rect.y else 0,
        rect.x,
        rect.y,
        @intCast(rect.width),
        @intCast(rect.height),
    );
}

fn createAlphaMask(factor: u32) Error!*pixman.pixman_image_t {
    const alpha: u16 = @intCast((@as(u64, factor) * std.math.maxInt(u16) + std.math.maxInt(u32) / 2) / std.math.maxInt(u32));
    const color: pixman.pixman_color_t = .{ .red = 0, .green = 0, .blue = 0, .alpha = alpha };
    return pixman.pixman_image_create_solid_fill(&color) orelse error.OutOfMemory;
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
    radius: u32,
    factor: u32,
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
    std.debug.assert(radius <= @min(size.width, size.height) / 2);
    const interior_alpha = scaleMaskValue(255, factor);
    for (0..size.height) |y| @memset(data[y * stride ..][0..size.width], interior_alpha);
    if (radius == 0) {
        return mask;
    }

    const radius_float: f32 = @floatFromInt(radius);
    for (0..radius) |y| {
        for (0..radius) |x| {
            const pixel_x: f32 = @as(f32, @floatFromInt(x)) + 0.5;
            const pixel_y: f32 = @as(f32, @floatFromInt(y)) + 0.5;
            const distance = @sqrt(
                (pixel_x - radius_float) * (pixel_x - radius_float) +
                    (pixel_y - radius_float) * (pixel_y - radius_float),
            );
            const coverage = std.math.clamp(radius_float + 0.5 - distance, 0.0, 1.0);
            const alpha = scaleMaskValue(@intFromFloat(coverage * 255.0), factor);
            const opposite_x = size.width - 1 - x;
            const opposite_y = size.height - 1 - y;
            data[y * stride + x] = alpha;
            data[y * stride + opposite_x] = alpha;
            data[opposite_y * stride + x] = alpha;
            data[opposite_y * stride + opposite_x] = alpha;
        }
    }
    return mask;
}

fn scaleMaskValue(value: u8, factor: u32) u8 {
    if (factor == std.math.maxInt(u32)) return value;
    return @intCast((@as(u64, value) * factor + std.math.maxInt(u32) / 2) /
        std.math.maxInt(u32));
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

test "CPU renderer blends opaque image antialiasing outside replaceable interiors" {
    const Case = struct {
        size: render_types.Size,
        rounded: render_types.RoundedClip,
        clip: ?render_types.Rect = null,
    };
    const cases = [_]Case{
        .{
            .size = .{ .width = 2, .height = 2 },
            .rounded = .{
                .rect = .{ .x = 0, .y = 0, .width = 2, .height = 2 },
                .radius = 1,
            },
        },
        .{
            .size = .{ .width = 6, .height = 6 },
            .rounded = .{
                .rect = .{ .x = 0, .y = 0, .width = 6, .height = 6 },
                .radius = 2,
            },
            .clip = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        },
    };

    var renderer = Self.init(std.testing.allocator);
    defer renderer.deinit();
    for (cases) |case| {
        const pixel_count = try case.size.pixelCount();
        const source = try std.testing.allocator.alloc(u32, pixel_count);
        defer std.testing.allocator.free(source);
        @memset(source, 0xffffffff);
        var expected = try headless.init(std.testing.allocator, case.size);
        defer expected.deinit();
        var actual = try headless.init(std.testing.allocator, case.size);
        defer actual.deinit();
        const base_image: render_types.Image = .{
            .x = 0,
            .y = 0,
            .size = case.size,
            .buffer = .{
                .size = case.size,
                .stride_pixels = case.size.width,
                .pixels = source,
            },
            .rounded_clip = case.rounded,
            .clip = case.clip,
        };
        var opaque_image = base_image;
        opaque_image.is_opaque = true;
        const expected_commands = [_]render_types.Command{
            .{ .clear = render_types.Color.rgba(20, 40, 80, 255) },
            .{ .image = base_image },
        };
        const actual_commands = [_]render_types.Command{
            .{ .clear = render_types.Color.rgba(20, 40, 80, 255) },
            .{ .image = opaque_image },
        };
        try renderer.render(.{
            .size = case.size,
            .commands = &expected_commands,
        }, expected.target());
        try renderer.render(.{
            .size = case.size,
            .commands = &actual_commands,
        }, actual.target());
        try std.testing.expectEqualSlices(
            u32,
            expected.target().pixels[0..pixel_count],
            actual.target().pixels[0..pixel_count],
        );
    }
}

test "CPU renderer keeps fractionally scaled opaque image edges opaque" {
    const source_size: render_types.Size = .{ .width = 2, .height = 2 };
    const output_size: render_types.Size = .{ .width = 3, .height = 3 };
    var source = [_]u32{
        0xffff0000, 0xff00ff00,
        0xff0000ff, 0xffffffff,
    };
    var output = try headless.init(std.testing.allocator, output_size);
    defer output.deinit();
    const commands = [_]render_types.Command{
        .{ .clear = render_types.Color.rgba(20, 40, 80, 255) },
        .{ .image = .{
            .x = 0,
            .y = 0,
            .size = output_size,
            .buffer = .{
                .size = source_size,
                .stride_pixels = source_size.width,
                .pixels = &source,
            },
            .is_opaque = true,
        } },
    };

    var renderer = Self.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.render(.{ .size = output_size, .commands = &commands }, output.target());
    for (output.target().pixels[0 .. output_size.width * output_size.height]) |pixel| {
        try std.testing.expectEqual(@as(u8, 255), @as(u8, @truncate(pixel >> 24)));
    }
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

test "CPU renderer damage-scoped crossfade matches a full render" {
    const size: render_types.Size = .{ .width = 4, .height = 1 };
    var old = [_]u32{ 0xffff0000, 0xff00ff00, 0xff0000ff, 0xffffffff };
    var new = [_]u32{ 0xff000000, 0xffffffff, 0xffff0000, 0xff00ff00 };
    const commands = [_]render_types.Command{
        .{ .clear = render_types.Color.rgba(12, 24, 48, 255) },
        .{ .crossfade = .{
            .destination = .{ .x = 0, .y = 0, .width = size.width, .height = size.height },
            .old = .{ .pixels = .{ .size = size, .stride_pixels = size.width, .pixels = &old } },
            .new = .{ .pixels = .{ .size = size, .stride_pixels = size.width, .pixels = &new } },
            .factor = std.math.maxInt(u32) / 3,
        } },
    };
    var expected = try headless.init(std.testing.allocator, size);
    defer expected.deinit();
    var actual = try headless.init(std.testing.allocator, size);
    defer actual.deinit();
    @memset(actual.target().pixels[0..size.width], 0xff123456);
    var renderer = Self.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.render(.{ .size = size, .commands = &commands }, expected.target());
    const damage = [_]render_types.Rect{.{ .x = 1, .y = 0, .width = 2, .height = 1 }};
    try renderer.render(.{
        .size = size,
        .commands = &commands,
        .damage = &damage,
    }, actual.target());

    try std.testing.expectEqual(@as(u32, 0xff123456), actual.pixel(0, 0));
    try std.testing.expectEqual(expected.pixel(1, 0), actual.pixel(1, 0));
    try std.testing.expectEqual(expected.pixel(2, 0), actual.pixel(2, 0));
    try std.testing.expectEqual(@as(u32, 0xff123456), actual.pixel(3, 0));
}

test "CPU renderer damage-scoped shadows match a full render" {
    const size: render_types.Size = .{ .width = 11, .height = 9 };
    const commands = [_]render_types.Command{.{ .shadow = .{
        .rect = .{ .x = 3, .y = 2, .width = 5, .height = 5 },
        .corner_radius = 2,
        .blur_radius = 2,
        .spread = 0,
        .color = render_types.Color.rgba(0, 0, 0, 192),
        .cutout = .{
            .rect = .{ .x = 3, .y = 2, .width = 5, .height = 5 },
            .radius = 2,
        },
    } }};
    var expected = try headless.init(std.testing.allocator, size);
    defer expected.deinit();
    var actual = try headless.init(std.testing.allocator, size);
    defer actual.deinit();
    var renderer = Self.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.render(.{ .size = size, .commands = &commands }, expected.target());
    const damage = [_]render_types.Rect{
        .{ .x = 1, .y = 1, .width = 2, .height = 3 },
        .{ .x = 8, .y = 5, .width = 2, .height = 3 },
    };
    try renderer.render(.{
        .size = size,
        .commands = &commands,
        .damage = &damage,
    }, actual.target());

    for (0..size.height) |y| for (0..size.width) |x| {
        const damaged = (x >= 1 and x < 3 and y >= 1 and y < 4) or
            (x >= 8 and x < 10 and y >= 5 and y < 8);
        if (damaged) {
            try std.testing.expectEqual(expected.pixel(x, y), actual.pixel(x, y));
        } else {
            try std.testing.expectEqual(@as(u32, 0), actual.pixel(x, y));
        }
    };
}
