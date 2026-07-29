//! CPU dual-Kawase blur over premultiplied ARGB8888 pixels.

const std = @import("std");
const blur_geometry = @import("blur_geometry.zig");
const render = @import("types.zig");

pub const Error = error{
    InvalidTarget,
    OutOfMemory,
};

const Color = [4]f32;

const Image = struct {
    size: render.Size,
    pixels: []Color,

    fn init(allocator: std.mem.Allocator, size: render.Size) Error!Image {
        const pixel_count = std.math.mul(usize, size.width, size.height) catch
            return error.InvalidTarget;
        const pixels = allocator.alloc(Color, pixel_count) catch
            return error.OutOfMemory;
        return .{ .size = size, .pixels = pixels };
    }

    fn fromTarget(
        allocator: std.mem.Allocator,
        target: render.PixelBuffer,
        rect: render.Rect,
    ) Error!Image {
        std.debug.assert(rect.x >= 0 and rect.y >= 0);
        std.debug.assert(rect.width > 0 and rect.height > 0);
        std.debug.assert(@as(i64, rect.x) + rect.width <= target.size.width);
        std.debug.assert(@as(i64, rect.y) + rect.height <= target.size.height);
        std.debug.assert(target.stride_pixels >= target.size.width);
        var image = try Image.init(allocator, .{
            .width = rect.width,
            .height = rect.height,
        });
        errdefer image.deinit(allocator);
        for (0..rect.height) |y| {
            const source_y: usize = @intCast(@as(i64, rect.y) + @as(i64, @intCast(y)));
            for (0..rect.width) |x| {
                const source_x: usize = @intCast(@as(i64, rect.x) + @as(i64, @intCast(x)));
                image.pixels[y * rect.width + x] = unpackColor(
                    target.pixels[source_y * target.stride_pixels + source_x],
                );
            }
        }
        return image;
    }

    fn deinit(self: *Image, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.* = undefined;
    }
};

/// Borrows `target` for this call and returns caller-owned packed ARGB pixels.
/// `sample_rect` must be non-empty and clipped to the target.
pub fn blurArgb(
    allocator: std.mem.Allocator,
    target: render.PixelBuffer,
    sample_rect: render.Rect,
    radius: u32,
    downsample_level: ?u8,
    finish: render.BackdropBlurFinish,
) Error![]u32 {
    const level = blur_geometry.configuredLevel(radius, downsample_level);
    const offset = blur_geometry.sampleOffset(radius, level);
    const sample_size: render.Size = .{
        .width = sample_rect.width,
        .height = sample_rect.height,
    };
    var current = try Image.fromTarget(allocator, target, sample_rect);
    defer current.deinit(allocator);

    const downsample_passes: usize = @max(level, 1);
    for (0..downsample_passes) |index| {
        const destination_level: u8 = if (level == 0) 0 else @intCast(index + 1);
        const destination = try Image.init(
            allocator,
            blur_geometry.levelSize(sample_size, destination_level),
        );
        downsample(current, destination, offset);
        current.deinit(allocator);
        current = destination;
    }

    var source_level: usize = level;
    const upsample_passes: usize = @max(level, 1);
    for (0..upsample_passes) |_| {
        const destination_level: u8 = if (level == 0)
            0
        else
            @intCast(source_level - 1);
        const destination = try Image.init(
            allocator,
            blur_geometry.levelSize(sample_size, destination_level),
        );
        upsample(current, destination, offset, level == 0);
        current.deinit(allocator);
        current = destination;
        if (level > 0) source_level -= 1;
    }
    applyFinish(current, sample_rect, finish);
    return packImage(allocator, current);
}

fn downsample(source: Image, destination: Image, offset: f32) void {
    for (0..destination.size.height) |y| {
        const coordinate_y = (@as(f32, @floatFromInt(y)) + 0.5) *
            @as(f32, @floatFromInt(source.size.height)) /
            @as(f32, @floatFromInt(destination.size.height));
        for (0..destination.size.width) |x| {
            const coordinate_x = (@as(f32, @floatFromInt(x)) + 0.5) *
                @as(f32, @floatFromInt(source.size.width)) /
                @as(f32, @floatFromInt(destination.size.width));
            var color: Color = @splat(0);
            addColor(&color, sample(source, coordinate_x, coordinate_y), 4);
            addColor(&color, sample(source, coordinate_x - offset, coordinate_y - offset), 1);
            addColor(&color, sample(source, coordinate_x + offset, coordinate_y - offset), 1);
            addColor(&color, sample(source, coordinate_x - offset, coordinate_y + offset), 1);
            addColor(&color, sample(source, coordinate_x + offset, coordinate_y + offset), 1);
            inline for (0..4) |component| color[component] /= 8;
            destination.pixels[y * destination.size.width + x] = color;
        }
    }
}

fn upsample(
    source: Image,
    destination: Image,
    offset: f32,
    same_size: bool,
) void {
    const divisor: f32 = if (same_size) 1 else 2;
    const diagonal = offset * 0.5;
    for (0..destination.size.height) |y| {
        const coordinate_y = (@as(f32, @floatFromInt(y)) + 0.5) / divisor;
        for (0..destination.size.width) |x| {
            const coordinate_x = (@as(f32, @floatFromInt(x)) + 0.5) / divisor;
            var color: Color = @splat(0);
            addColor(&color, sample(source, coordinate_x - offset, coordinate_y), 1);
            addColor(&color, sample(source, coordinate_x + offset, coordinate_y), 1);
            addColor(&color, sample(source, coordinate_x, coordinate_y - offset), 1);
            addColor(&color, sample(source, coordinate_x, coordinate_y + offset), 1);
            addColor(&color, sample(source, coordinate_x - diagonal, coordinate_y - diagonal), 2);
            addColor(&color, sample(source, coordinate_x + diagonal, coordinate_y - diagonal), 2);
            addColor(&color, sample(source, coordinate_x - diagonal, coordinate_y + diagonal), 2);
            addColor(&color, sample(source, coordinate_x + diagonal, coordinate_y + diagonal), 2);
            inline for (0..4) |component| color[component] /= 12;
            destination.pixels[y * destination.size.width + x] = color;
        }
    }
}

fn sample(image: Image, coordinate_x: f32, coordinate_y: f32) Color {
    const texel_x = coordinate_x - 0.5;
    const texel_y = coordinate_y - 0.5;
    const base_x: i64 = @intFromFloat(@floor(texel_x));
    const base_y: i64 = @intFromFloat(@floor(texel_y));
    const fraction_x = texel_x - @as(f32, @floatFromInt(base_x));
    const fraction_y = texel_y - @as(f32, @floatFromInt(base_y));
    const x0 = clampedIndex(base_x, image.size.width);
    const x1 = clampedIndex(base_x + 1, image.size.width);
    const y0 = clampedIndex(base_y, image.size.height);
    const y1 = clampedIndex(base_y + 1, image.size.height);
    const top = mixColor(
        image.pixels[y0 * image.size.width + x0],
        image.pixels[y0 * image.size.width + x1],
        fraction_x,
    );
    const bottom = mixColor(
        image.pixels[y1 * image.size.width + x0],
        image.pixels[y1 * image.size.width + x1],
        fraction_x,
    );
    return mixColor(top, bottom, fraction_y);
}

fn clampedIndex(value: i64, limit: u32) usize {
    std.debug.assert(limit > 0);
    if (value <= 0) return 0;
    if (value >= @as(i64, limit) - 1) return limit - 1;
    return @intCast(value);
}

fn mixColor(a: Color, b: Color, amount: f32) Color {
    var result: Color = undefined;
    inline for (0..4) |component| {
        result[component] = a[component] + (b[component] - a[component]) * amount;
    }
    return result;
}

fn addColor(sum: *Color, color: Color, weight: f32) void {
    inline for (0..4) |component| sum[component] += color[component] * weight;
}

fn applyFinish(
    image: Image,
    sample_rect: render.Rect,
    finish: render.BackdropBlurFinish,
) void {
    if (finish.isNeutral()) return;
    std.debug.assert(sample_rect.x >= 0 and sample_rect.y >= 0);
    for (0..image.size.height) |y| {
        for (0..image.size.width) |x| {
            const color = &image.pixels[y * image.size.width + x];
            const alpha = color[3];
            if (alpha <= 0) {
                color.* = @splat(0);
                continue;
            }
            var straight: [3]f32 = undefined;
            inline for (0..3) |component| straight[component] = color[component] * 255 / alpha;
            const luminance = straight[0] * 0.0722 + straight[1] * 0.7152 + straight[2] * 0.2126;
            const grain = noise(
                @intCast(@as(i64, sample_rect.x) + @as(i64, @intCast(x))),
                @intCast(@as(i64, sample_rect.y) + @as(i64, @intCast(y))),
            ) * finish.noise * 255;
            inline for (0..3) |component| {
                var value = luminance + (straight[component] - luminance) * finish.saturation;
                value += (finish.brightness - 1) * 255;
                value = (value - 127.5) * finish.contrast + 127.5;
                value = @max(value + grain, 0);
                color[component] = value * alpha / 255;
            }
        }
    }
}

fn noise(x: u32, y: u32) f32 {
    var value = x *% 0x9e3779b9 ^ y *% 0x85ebca6b;
    value ^= value >> 16;
    value *%= 0x7feb352d;
    value ^= value >> 15;
    value *%= 0x846ca68b;
    value ^= value >> 16;
    return @as(f32, @floatFromInt(value & 0xffff)) / 65535 - 0.5;
}

fn unpackColor(pixel: u32) Color {
    var color: Color = undefined;
    inline for (0..4) |component| {
        color[component] = @floatFromInt(@as(u8, @truncate(pixel >> component * 8)));
    }
    return color;
}

fn packImage(allocator: std.mem.Allocator, image: Image) Error![]u32 {
    const pixels = allocator.alloc(u32, image.pixels.len) catch return error.OutOfMemory;
    for (pixels, image.pixels) |*pixel, color| {
        pixel.* = 0;
        inline for (0..4) |component| {
            const value: u32 = @intFromFloat(std.math.clamp(color[component], 0, 255) + 0.5);
            pixel.* |= value << component * 8;
        }
    }
    return pixels;
}

test "CPU dual Kawase pyramid preserves a uniform odd-sized image" {
    const size: render.Size = .{ .width = 5, .height = 3 };
    var source = [_]u32{0x80402010} ** (size.width * size.height);
    const blurred = try blurArgb(
        std.testing.allocator,
        .{
            .size = size,
            .stride_pixels = size.width,
            .pixels = &source,
        },
        .{ .x = 0, .y = 0, .width = size.width, .height = size.height },
        16,
        null,
        .{},
    );
    defer std.testing.allocator.free(blurred);

    try std.testing.expectEqualSlices(u32, &source, blurred);
}

test "CPU dual Kawase scoped pyramid matches full-frame results" {
    const size: render.Size = .{ .width = 64, .height = 32 };
    var source: [size.width * size.height]u32 = undefined;
    for (&source, 0..) |*pixel, index| {
        const x = index % size.width;
        const y = index / size.width;
        const value: u8 = @intCast((x * 3 + y * 5) % 256);
        pixel.* = 0xff000000 | @as(u32, value) * 0x00010101;
    }
    const target: render.PixelBuffer = .{
        .size = size,
        .stride_pixels = size.width,
        .pixels = &source,
    };
    const full_rect: render.Rect = .{
        .x = 0,
        .y = 0,
        .width = size.width,
        .height = size.height,
    };
    const output_rect: render.Rect = .{ .x = 28, .y = 14, .width = 4, .height = 4 };
    const level = blur_geometry.configuredLevel(3, null);
    const sample_rect = blur_geometry.sampleRect(
        output_rect,
        blur_geometry.footprint(3, null),
        level,
        size,
    );
    const full = try blurArgb(std.testing.allocator, target, full_rect, 3, null, .{});
    defer std.testing.allocator.free(full);
    const scoped = try blurArgb(std.testing.allocator, target, sample_rect, 3, null, .{});
    defer std.testing.allocator.free(scoped);

    for (0..output_rect.height) |y| {
        for (0..output_rect.width) |x| {
            const output_x: usize = @intCast(@as(i64, output_rect.x) + @as(i64, @intCast(x)));
            const output_y: usize = @intCast(@as(i64, output_rect.y) + @as(i64, @intCast(y)));
            const sample_x: usize = @intCast(@as(i64, output_rect.x - sample_rect.x) + @as(i64, @intCast(x)));
            const sample_y: usize = @intCast(@as(i64, output_rect.y - sample_rect.y) + @as(i64, @intCast(y)));
            try std.testing.expectEqual(
                full[output_y * size.width + output_x],
                scoped[sample_y * sample_rect.width + sample_x],
            );
        }
    }
}

test "CPU backdrop blur finish is stable across scoped captures" {
    const size: render.Size = .{ .width = 64, .height = 32 };
    var source = [_]u32{0xff806040} ** (size.width * size.height);
    const target: render.PixelBuffer = .{
        .size = size,
        .stride_pixels = size.width,
        .pixels = &source,
    };
    const full_rect: render.Rect = .{
        .x = 0,
        .y = 0,
        .width = size.width,
        .height = size.height,
    };
    const scoped_rect: render.Rect = .{ .x = 16, .y = 8, .width = 24, .height = 16 };
    const finish: render.BackdropBlurFinish = .{
        .brightness = 0.95,
        .contrast = 0.92,
        .saturation = 1.08,
        .noise = 0.01,
    };
    const full = try blurArgb(std.testing.allocator, target, full_rect, 3, null, finish);
    defer std.testing.allocator.free(full);
    const scoped = try blurArgb(std.testing.allocator, target, scoped_rect, 3, null, finish);
    defer std.testing.allocator.free(scoped);

    for (0..scoped_rect.height) |y| {
        for (0..scoped_rect.width) |x| {
            const full_x: usize = @intCast(@as(i64, scoped_rect.x) + @as(i64, @intCast(x)));
            const full_y: usize = @intCast(@as(i64, scoped_rect.y) + @as(i64, @intCast(y)));
            try std.testing.expectEqual(
                full[full_y * size.width + full_x],
                scoped[y * scoped_rect.width + x],
            );
        }
    }
    try std.testing.expect(full[0] != 0xff806040);
    try std.testing.expect(full[0] != full[1]);
}
