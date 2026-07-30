//! Platform-neutral CPU rasterization for Keywork display lists.

const std = @import("std");
const keywork = @import("keywork-ui");
const TextRenderer = @import("text.zig");
const c = @import("pixman_c");

pub fn rasterize(
    renderer: *TextRenderer,
    pixels: []u32,
    width: u31,
    height: u31,
    scale: f32,
    commands: []const keywork.PaintCommand,
    base_clip: ?TextRenderer.PixelClip,
) !void {
    const pixel_count = try std.math.mul(usize, width, height);
    if (pixels.len < pixel_count) return error.InvalidImage;
    const stride = try std.math.mul(i32, @as(i32, @intCast(width)), @sizeOf(u32));
    const target = c.pixman_image_create_bits_no_clear(
        @intCast(c.PIXMAN_a8r8g8b8),
        @intCast(width),
        @intCast(height),
        @ptrCast(pixels.ptr),
        stride,
    ) orelse return error.OutOfMemory;
    defer _ = c.pixman_image_unref(target);

    const background = if (commands.len > 0) fullFrameFill(commands[0], width, height, scale) else null;
    const clear_color = background orelse keywork.colors.transparent;
    if (base_clip) |clip| {
        clearRegion(pixels, width, height, clip, clear_color);
    } else {
        @memset(pixels, @as(u32, @bitCast(clear_color)));
    }
    var clip: ?TextRenderer.PixelClip = base_clip;
    const first_command: usize = if (background != null) 1 else 0;
    for (commands[first_command..]) |command| {
        switch (command) {
            .fill_rect => |fill| try fillRect(target, pixels, width, height, scale, fill.rect, fill.color, clip),
            .text => |text| try renderer.render(pixels, width, height, scale, text, clip),
            .alpha_image => |image| try alphaImage(target, pixels, width, height, scale, image, clip),
            .color_image => |image| try colorImage(target, pixels, width, height, scale, image, clip),
            .external_image => |image| try externalImage(target, pixels, width, height, scale, image, clip),
            .set_clip => |rect| clip = combineClips(base_clip, rect, scale),
        }
    }
}

/// A leading opaque fill that reaches every target pixel is the clear. This
/// avoids writing the whole buffer twice for the normal window background.
fn fullFrameFill(command: keywork.PaintCommand, width: u31, height: u31, scale: f32) ?keywork.Color {
    const fill = switch (command) {
        .fill_rect => |value| value,
        else => return null,
    };
    if (fill.color.a != 255) return null;
    const x0 = clampPixel(@floor(fill.rect.x * scale), width);
    const y0 = clampPixel(@floor(fill.rect.y * scale), height);
    const x1 = clampPixel(@ceil((fill.rect.x + fill.rect.width) * scale), width);
    const y1 = clampPixel(@ceil((fill.rect.y + fill.rect.height) * scale), height);
    if (x0 != 0 or y0 != 0 or x1 != width or y1 != height) return null;
    return fill.color;
}

fn combineClips(base: ?TextRenderer.PixelClip, rect: ?keywork.Rect, scale: f32) ?TextRenderer.PixelClip {
    const converted: ?TextRenderer.PixelClip = if (rect) |value| TextRenderer.PixelClip.fromRect(value, scale) else null;
    const base_clip = base orelse return converted;
    const other = converted orelse return base_clip;
    return .{
        .x0 = @max(base_clip.x0, other.x0),
        .y0 = @max(base_clip.y0, other.y0),
        .x1 = @min(base_clip.x1, other.x1),
        .y1 = @min(base_clip.y1, other.y1),
    };
}

fn clearRegion(pixels: []u32, width: u31, height: u31, clip: TextRenderer.PixelClip, color: keywork.Color) void {
    const value: u32 = @bitCast(color);
    const x0 = clampClip(clip.x0, width);
    const x1 = clampClip(clip.x1, width);
    const y0 = clampClip(clip.y0, height);
    const y1 = clampClip(clip.y1, height);
    if (x0 >= x1) return;
    var y = y0;
    while (y < y1) : (y += 1) {
        @memset(pixels[y * width ..][x0..x1], value);
    }
}

fn fillRect(target: *c.pixman_image_t, pixels: []u32, width: u31, height: u31, scale: f32, rect: keywork.Rect, color: keywork.Color, clip: ?TextRenderer.PixelClip) !void {
    var x0 = clampPixel(@floor(rect.x * scale), width);
    var y0 = clampPixel(@floor(rect.y * scale), height);
    var x1 = clampPixel(@ceil((rect.x + rect.width) * scale), width);
    var y1 = clampPixel(@ceil((rect.y + rect.height) * scale), height);
    if (clip) |value| {
        x0 = @max(x0, clampClip(value.x0, width));
        y0 = @max(y0, clampClip(value.y0, height));
        x1 = @min(x1, clampClip(value.x1, width));
        y1 = @min(y1, clampClip(value.y1, height));
    }
    if (x0 >= x1 or y0 >= y1) return;

    if (color.a == 0) return;
    if (color.a < 255) {
        const pixman_color = premultipliedColor(color);
        const box: c.pixman_box32_t = .{
            .x1 = @intCast(x0),
            .y1 = @intCast(y0),
            .x2 = @intCast(x1),
            .y2 = @intCast(y1),
        };
        if (c.pixman_image_fill_boxes(@intCast(c.PIXMAN_OP_OVER), target, &pixman_color, 1, &box) == 0) return error.CompositeFailed;
        return;
    }

    // Opaque source-over is replacement, so the common background path
    // keeps its row-fill fast path.
    const value: u32 = @bitCast(color);
    var y = y0;
    while (y < y1) : (y += 1) {
        const row = pixels[y * width ..][0..width];
        @memset(row[x0..x1], value);
    }
}

fn alphaImage(
    target: *c.pixman_image_t,
    pixels: []u32,
    width: u31,
    height: u31,
    scale: f32,
    image: keywork.PaintCommand.AlphaImage,
    clip: ?TextRenderer.PixelClip,
) !void {
    if (image.width == 0 or image.height == 0) return;
    const image_width: usize = @intCast(image.width);
    const image_height: usize = @intCast(image.height);
    const image_stride: usize = @intCast(image.stride);
    if (image_stride < image_width or image_stride % 4 != 0) return error.InvalidImage;
    const image_size = try std.math.mul(usize, image_stride, image_height);
    if (image.alpha.len < image_size) return error.InvalidImage;
    const dst_x0 = clampPixel(@floor(image.rect.x * scale), width);
    const dst_y0 = clampPixel(@floor(image.rect.y * scale), height);
    var start_x = dst_x0;
    var start_y = dst_y0;
    var dst_x1 = @min(dst_x0 + image_width, width);
    var dst_y1 = @min(dst_y0 + image_height, height);
    if (clip) |value| {
        start_x = @max(start_x, clampClip(value.x0, width));
        start_y = @max(start_y, clampClip(value.y0, height));
        dst_x1 = @min(dst_x1, clampClip(value.x1, width));
        dst_y1 = @min(dst_y1, clampClip(value.y1, height));
    }
    if (start_x >= dst_x1 or start_y >= dst_y1) return;

    if (image.dither) {
        var y = start_y;
        while (y < dst_y1) : (y += 1) {
            const row = y - dst_y0;
            var x = start_x;
            while (x < dst_x1) : (x += 1) {
                const column = x - dst_x0;
                const coverage = image.alpha[row * image_stride + column];
                if (coverage == 0) continue;
                blendAlphaImagePixel(pixels, width, x, y, image.color, coverage);
            }
        }
        return;
    }

    const mask = c.pixman_image_create_bits_no_clear(
        @intCast(c.PIXMAN_a8),
        @intCast(image.width),
        @intCast(image.height),
        @ptrCast(@constCast(image.alpha.ptr)),
        @intCast(image.stride),
    ) orelse return error.OutOfMemory;
    defer _ = c.pixman_image_unref(mask);
    const pixman_color = premultipliedColor(image.color);
    const source = c.pixman_image_create_solid_fill(&pixman_color) orelse return error.OutOfMemory;
    defer _ = c.pixman_image_unref(source);
    c.pixman_image_composite32(
        @intCast(c.PIXMAN_OP_OVER),
        source,
        mask,
        target,
        0,
        0,
        @intCast(start_x - dst_x0),
        @intCast(start_y - dst_y0),
        @intCast(start_x),
        @intCast(start_y),
        @intCast(dst_x1 - start_x),
        @intCast(dst_y1 - start_y),
    );
}

fn colorImage(
    target: *c.pixman_image_t,
    pixels: []u32,
    width: u31,
    height: u31,
    scale: f32,
    image: keywork.PaintCommand.ColorImage,
    clip: ?TextRenderer.PixelClip,
) !void {
    if (image.width == 0 or image.height == 0) return;
    const image_width: usize = @intCast(image.width);
    const image_height: usize = @intCast(image.height);
    const image_stride: usize = @intCast(image.stride);
    if (image_stride < image_width) return error.InvalidImage;
    const rows_before_last = try std.math.mul(usize, image_height - 1, image_stride);
    const source_size = try std.math.add(usize, rows_before_last, image_width);
    if (image.pixels.len < source_size) return error.InvalidImage;

    const left = image.rect.x * scale;
    const top = image.rect.y * scale;
    const destination_width = image.rect.width * scale;
    const destination_height = image.rect.height * scale;
    if (!std.math.isFinite(left) or !std.math.isFinite(top) or
        !std.math.isFinite(destination_width) or destination_width <= 0 or
        !std.math.isFinite(destination_height) or destination_height <= 0)
    {
        return error.InvalidImage;
    }

    var start_x = clampPixel(@floor(left), width);
    var start_y = clampPixel(@floor(top), height);
    var dst_x1 = clampPixel(@ceil(left + destination_width), width);
    var dst_y1 = clampPixel(@ceil(top + destination_height), height);
    if (clip) |value| {
        start_x = @max(start_x, clampClip(value.x0, width));
        start_y = @max(start_y, clampClip(value.y0, height));
        dst_x1 = @min(dst_x1, clampClip(value.x1, width));
        dst_y1 = @min(dst_y1, clampClip(value.y1, height));
    }
    if (start_x >= dst_x1 or start_y >= dst_y1) return;

    const exact_size = destination_width == @as(f32, @floatFromInt(image_width)) and
        destination_height == @as(f32, @floatFromInt(image_height));
    const integral_origin = left == @floor(left) and top == @floor(top);
    if (exact_size and integral_origin) {
        const destination_x: i64 = @intFromFloat(left);
        const destination_y: i64 = @intFromFloat(top);
        const source_x: usize = @intCast(@as(i64, @intCast(start_x)) - destination_x);
        const source_y: usize = @intCast(@as(i64, @intCast(start_y)) - destination_y);
        if (image.format == .xrgb8888) {
            const source_pixels: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(image.pixels)));
            var y = start_y;
            while (y < dst_y1) : (y += 1) {
                const source_row = source_y + y - start_y;
                @memcpy(
                    pixels[y * width + start_x .. y * width + dst_x1],
                    source_pixels[source_row * image_stride + source_x ..][0 .. dst_x1 - start_x],
                );
                for (pixels[y * width + start_x .. y * width + dst_x1]) |*pixel| pixel.* |= 0xff000000;
            }
            return;
        }
        if (image.format == .argb8888_premultiplied) {
            const source = c.pixman_image_create_bits_no_clear(
                @intCast(c.PIXMAN_a8r8g8b8),
                @intCast(image.width),
                @intCast(image.height),
                @ptrCast(@constCast(image.pixels.ptr)),
                @intCast(image.stride * @sizeOf(u32)),
            ) orelse return error.OutOfMemory;
            defer _ = c.pixman_image_unref(source);
            c.pixman_image_composite32(
                @intCast(c.PIXMAN_OP_OVER),
                source,
                null,
                target,
                @intCast(source_x),
                @intCast(source_y),
                0,
                0,
                @intCast(start_x),
                @intCast(start_y),
                @intCast(dst_x1 - start_x),
                @intCast(dst_y1 - start_y),
            );
            return;
        }
    }

    var y = start_y;
    while (y < dst_y1) : (y += 1) {
        const source_y = sourceCoordinate(y, top, destination_height, image_height);
        var x = start_x;
        while (x < dst_x1) : (x += 1) {
            const source_x = sourceCoordinate(x, left, destination_width, image_width);
            compositeColorImagePixel(pixels, width, x, y, image.pixels[source_y * image_stride + source_x], image.format);
        }
    }
}

fn externalImage(
    target: *c.pixman_image_t,
    pixels: []u32,
    width: u31,
    height: u31,
    scale: f32,
    image: keywork.PaintCommand.ExternalImage,
    clip: ?TextRenderer.PixelClip,
) !void {
    const mapped = try image.source.beginRead();
    defer image.source.endRead();
    try colorImage(target, pixels, width, height, scale, .{
        .rect = image.rect,
        .width = image.width,
        .height = image.height,
        .pixels = mapped.pixels,
        .stride = mapped.stride,
        .format = mapped.format,
        .cache_key = image.cache_key,
        .revision = image.revision,
    }, clip);
}

fn sourceCoordinate(pixel: usize, origin: f32, destination_extent: f32, source_extent: usize) usize {
    std.debug.assert(source_extent > 0);
    const position = (@as(f64, @floatFromInt(pixel)) + 0.5 - @as(f64, origin)) /
        @as(f64, destination_extent) * @as(f64, @floatFromInt(source_extent));
    const maximum: f64 = @floatFromInt(source_extent - 1);
    return @intFromFloat(std.math.clamp(@floor(position), 0, maximum));
}

fn compositeColorImagePixel(
    pixels: []u32,
    width: u31,
    x: usize,
    y: usize,
    source: keywork.Color,
    format: keywork.PixelFormat,
) void {
    const index = y * width + x;
    switch (format) {
        .xrgb8888 => pixels[index] = @as(u32, @bitCast(source)) | 0xff000000,
        .argb8888_straight => {
            if (source.a == 0) return;
            if (source.a == 255) {
                pixels[index] = @bitCast(source);
                return;
            }
            const destination: keywork.Color = @bitCast(pixels[index]);
            pixels[index] = @bitCast(source.blendOver(destination, 255));
        },
        .argb8888_premultiplied => {
            if (source.a == 0) return;
            if (source.a == 255) {
                pixels[index] = @bitCast(source);
                return;
            }
            const destination: keywork.Color = @bitCast(pixels[index]);
            pixels[index] = @bitCast(blendPremultipliedOver(source, destination));
        },
    }
}

fn blendPremultipliedOver(source: keywork.Color, destination: keywork.Color) keywork.Color {
    const inverse_alpha = 255 - @as(u32, source.a);
    return .{
        .a = @intCast(@as(u32, source.a) + (@as(u32, destination.a) * inverse_alpha + 127) / 255),
        .r = @intCast(@min(255, @as(u32, source.r) + (@as(u32, destination.r) * inverse_alpha + 127) / 255)),
        .g = @intCast(@min(255, @as(u32, source.g) + (@as(u32, destination.g) * inverse_alpha + 127) / 255)),
        .b = @intCast(@min(255, @as(u32, source.b) + (@as(u32, destination.b) * inverse_alpha + 127) / 255)),
    };
}

pub fn clampClip(value: i32, max_value: u31) usize {
    if (value <= 0) return 0;
    return @min(@as(usize, @intCast(value)), max_value);
}

fn blendPixel(pixels: []u32, width: u31, x: usize, y: usize, color: keywork.Color, coverage: u8) void {
    const index = y * width + x;
    const dst: keywork.Color = @bitCast(pixels[index]);
    pixels[index] = @bitCast(color.blendOver(dst, coverage));
}

/// Pixman colors use premultiplied 16-bit channels. Expanding an 8-bit
/// premultiplied value preserves the exact ARGB8888 result pixman writes.
fn premultipliedColor(color: keywork.Color) c.pixman_color_t {
    const alpha: u32 = color.a;
    return .{
        .red = expand8(@intCast((@as(u32, color.r) * alpha + 127) / 255)),
        .green = expand8(@intCast((@as(u32, color.g) * alpha + 127) / 255)),
        .blue = expand8(@intCast((@as(u32, color.b) * alpha + 127) / 255)),
        .alpha = expand8(color.a),
    };
}

fn expand8(value: u8) u16 {
    return @as(u16, value) * 257;
}

fn blendAlphaImagePixel(pixels: []u32, width: u31, x: usize, y: usize, color: keywork.Color, coverage: u8) void {
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
    const rank = bayer8[(y % 8) * 8 + (x % 8)];
    const threshold: u8 = @intCast((@as(u16, rank) * 2 + 1) * 255 / (bayer8.len * 2));
    const index = y * width + x;
    const dst: keywork.Color = @bitCast(pixels[index]);
    pixels[index] = @bitCast(color.blendOverDithered(dst, coverage, threshold));
}

fn clampPixel(value: f32, max_value: u31) usize {
    if (value <= 0) return 0;
    const limit: f32 = @floatFromInt(max_value);
    if (value >= limit) return max_value;
    return @intFromFloat(value);
}

test "translucent rectangle blends without lowering destination alpha" {
    const width: u31 = 2;
    const height: u31 = 2;
    var pixels: [width * height]u32 = @splat(@bitCast(keywork.colors.black));

    const target = c.pixman_image_create_bits_no_clear(
        @intCast(c.PIXMAN_a8r8g8b8),
        width,
        height,
        @ptrCast(&pixels),
        width * @sizeOf(u32),
    ).?;
    defer _ = c.pixman_image_unref(target);
    try fillRect(
        target,
        &pixels,
        width,
        height,
        1,
        .{ .x = 0, .y = 0, .width = width, .height = height },
        keywork.Color.argb(128, 255, 255, 255),
        null,
    );

    const expected: u32 = @bitCast(keywork.Color.argb(255, 128, 128, 128));
    try std.testing.expectEqualSlices(u32, &@as([width * height]u32, @splat(expected)), &pixels);
}

test "pixman composites padded alpha mask rows" {
    const width: u31 = 3;
    const height: u31 = 2;
    var pixels: [width * height]u32 = @splat(@bitCast(keywork.colors.black));
    const target = c.pixman_image_create_bits_no_clear(
        @intCast(c.PIXMAN_a8r8g8b8),
        width,
        height,
        @ptrCast(&pixels),
        width * @sizeOf(u32),
    ).?;
    defer _ = c.pixman_image_unref(target);
    var alpha: [8]u8 align(4) = .{ 255, 0, 255, 99, 0, 255, 0, 99 };

    try alphaImage(target, &pixels, width, height, 1, .{
        .rect = .{ .x = 0, .y = 0, .width = width, .height = height },
        .width = width,
        .height = height,
        .alpha = &alpha,
        .stride = 4,
        .color = keywork.colors.white,
        .cache_key = 0,
    }, null);

    const black: u32 = @bitCast(keywork.colors.black);
    const white: u32 = @bitCast(keywork.colors.white);
    try std.testing.expectEqualSlices(u32, &.{ white, black, white, black, white, black }, &pixels);
}

test "dithered alpha masks ignore row padding" {
    const width: u31 = 3;
    const height: u31 = 2;
    var pixels: [width * height]u32 = @splat(@bitCast(keywork.colors.black));
    const target = c.pixman_image_create_bits_no_clear(
        @intCast(c.PIXMAN_a8r8g8b8),
        width,
        height,
        @ptrCast(&pixels),
        width * @sizeOf(u32),
    ).?;
    defer _ = c.pixman_image_unref(target);
    var alpha: [8]u8 align(4) = .{ 0, 0, 0, 255, 0, 0, 0, 255 };

    try alphaImage(target, &pixels, width, height, 1, .{
        .rect = .{ .x = 0, .y = 0, .width = width, .height = height },
        .width = width,
        .height = height,
        .alpha = &alpha,
        .stride = 4,
        .color = keywork.colors.white,
        .cache_key = 0,
        .dither = true,
    }, null);

    const black: u32 = @bitCast(keywork.colors.black);
    try std.testing.expectEqualSlices(u32, &@as([width * height]u32, @splat(black)), &pixels);
}

test "pixman alpha mask clipping preserves source offset" {
    const width: u31 = 3;
    const height: u31 = 1;
    var pixels: [width * height]u32 = @splat(@bitCast(keywork.colors.black));
    const target = c.pixman_image_create_bits_no_clear(
        @intCast(c.PIXMAN_a8r8g8b8),
        width,
        height,
        @ptrCast(&pixels),
        width * @sizeOf(u32),
    ).?;
    defer _ = c.pixman_image_unref(target);
    var alpha: [4]u8 align(4) = .{ 0, 255, 0, 99 };

    try alphaImage(target, &pixels, width, height, 1, .{
        .rect = .{ .x = 0, .y = 0, .width = width, .height = height },
        .width = width,
        .height = height,
        .alpha = &alpha,
        .stride = 4,
        .color = keywork.colors.white,
        .cache_key = 0,
    }, .{ .x0 = 1, .y0 = 0, .x1 = 2, .y1 = 1 });

    const black: u32 = @bitCast(keywork.colors.black);
    const white: u32 = @bitCast(keywork.colors.white);
    try std.testing.expectEqualSlices(u32, &.{ black, white, black }, &pixels);
}

test "pixman fill composites over translucent destination" {
    const width: u31 = 1;
    const height: u31 = 1;
    const destination = keywork.Color.argb(128, 64, 0, 0);
    var pixels = [1]u32{@bitCast(destination)};
    const target = c.pixman_image_create_bits_no_clear(
        @intCast(c.PIXMAN_a8r8g8b8),
        width,
        height,
        @ptrCast(&pixels),
        @sizeOf(u32),
    ).?;
    defer _ = c.pixman_image_unref(target);

    try fillRect(
        target,
        &pixels,
        width,
        height,
        1,
        .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        keywork.Color.argb(128, 0, 0, 255),
        null,
    );

    try std.testing.expectEqual(@as(u32, @bitCast(keywork.Color.argb(192, 32, 0, 128))), pixels[0]);
}

test "opaque leading full-frame fill can replace clear" {
    const color = keywork.Color.argb(255, 12, 34, 56);
    const command: keywork.PaintCommand = .{ .fill_rect = .{
        .rect = .{ .x = 0, .y = 0, .width = 320, .height = 240 },
        .color = color,
    } };
    try std.testing.expectEqual(color, fullFrameFill(command, 400, 300, 1.25).?);

    const translucent: keywork.PaintCommand = .{ .fill_rect = .{
        .rect = .{ .x = 0, .y = 0, .width = 400, .height = 300 },
        .color = keywork.Color.argb(254, 12, 34, 56),
    } };
    try std.testing.expectEqual(null, fullFrameFill(translucent, 400, 300, 1));
}

test "color image scales padded xrgb rows into its destination rect" {
    const source = [_]keywork.Color{
        keywork.Color.argb(0, 255, 0, 0),
        keywork.Color.argb(0, 0, 0, 255),
        keywork.colors.white,
    };
    var pixels: [4]u32 = @splat(@bitCast(keywork.colors.black));
    const target = c.pixman_image_create_bits_no_clear(
        @intCast(c.PIXMAN_a8r8g8b8),
        4,
        1,
        @ptrCast(&pixels),
        4 * @sizeOf(u32),
    ).?;
    defer _ = c.pixman_image_unref(target);
    try colorImage(target, &pixels, 4, 1, 1, .{
        .rect = .{ .x = 0, .y = 0, .width = 4, .height = 1 },
        .width = 2,
        .height = 1,
        .pixels = &source,
        .stride = 3,
        .format = .xrgb8888,
        .cache_key = 0,
        .revision = 0,
    }, null);

    const red: u32 = @bitCast(keywork.Color.argb(255, 255, 0, 0));
    const blue: u32 = @bitCast(keywork.Color.argb(255, 0, 0, 255));
    try std.testing.expectEqualSlices(u32, &.{ red, red, blue, blue }, &pixels);
}

test "color image does not multiply premultiplied alpha twice" {
    var premultiplied: [1]u32 = @splat(@bitCast(keywork.colors.black));
    const source = [_]keywork.Color{keywork.Color.argb(128, 64, 0, 0)};
    const target = c.pixman_image_create_bits_no_clear(
        @intCast(c.PIXMAN_a8r8g8b8),
        1,
        1,
        @ptrCast(&premultiplied),
        @sizeOf(u32),
    ).?;
    defer _ = c.pixman_image_unref(target);
    try colorImage(target, &premultiplied, 1, 1, 1, .{
        .rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .width = 1,
        .height = 1,
        .pixels = &source,
        .stride = 1,
        .format = .argb8888_premultiplied,
        .cache_key = 0,
        .revision = 0,
    }, null);

    try std.testing.expectEqual(@as(u32, @bitCast(keywork.Color.argb(255, 64, 0, 0))), premultiplied[0]);
}

test "external image brackets CPU fallback access" {
    const Source = struct {
        pixels: [1]keywork.Color = .{keywork.Color.argb(0, 12, 34, 56)},
        begins: usize = 0,
        ends: usize = 0,

        const vtable: keywork.ExternalImageSource.VTable = .{
            .retain = retain,
            .release = release,
            .begin_read = beginRead,
            .end_read = endRead,
        };

        fn retain(_: *anyopaque) void {}
        fn release(_: *anyopaque) void {}

        fn beginRead(context: *anyopaque) !keywork.ExternalImageSource.MappedPixels {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.begins += 1;
            return .{ .pixels = &self.pixels, .stride = 1, .format = .xrgb8888 };
        }

        fn endRead(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.ends += 1;
        }
    };

    var source: Source = .{};
    var pixels: [1]u32 = @splat(@bitCast(keywork.colors.black));
    const target = c.pixman_image_create_bits_no_clear(
        @intCast(c.PIXMAN_a8r8g8b8),
        1,
        1,
        @ptrCast(&pixels),
        @sizeOf(u32),
    ).?;
    defer _ = c.pixman_image_unref(target);
    try externalImage(target, &pixels, 1, 1, 1, .{
        .rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .width = 1,
        .height = 1,
        .source = .{ .context = &source, .vtable = &Source.vtable },
        .cache_key = 1,
        .revision = 1,
    }, null);

    try std.testing.expectEqual(@as(usize, 1), source.begins);
    try std.testing.expectEqual(@as(usize, 1), source.ends);
    try std.testing.expectEqual(@as(u32, @bitCast(keywork.Color.argb(255, 12, 34, 56))), pixels[0]);
}

test "color image clamps source coordinates before integer conversion" {
    const source = [_]keywork.Color{keywork.colors.white};
    var pixels: [1]u32 = @splat(@bitCast(keywork.colors.black));
    const target = c.pixman_image_create_bits_no_clear(
        @intCast(c.PIXMAN_a8r8g8b8),
        1,
        1,
        @ptrCast(&pixels),
        @sizeOf(u32),
    ).?;
    defer _ = c.pixman_image_unref(target);
    try colorImage(target, &pixels, 1, 1, 1, .{
        .rect = .{ .x = 0.25, .y = 0.25, .width = 1e-30, .height = 1e-30 },
        .width = 1,
        .height = 1,
        .pixels = &source,
        .stride = 1,
        .format = .xrgb8888,
        .cache_key = 0,
        .revision = 0,
    }, null);
    try std.testing.expectEqual(@as(u32, @bitCast(keywork.colors.white)), pixels[0]);
}
