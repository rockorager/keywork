//! Rendering for icon files selected by the XDG icon-theme service.

const std = @import("std");
const core = @import("core.zig");
const image_c = @import("image_c");
const icon_theme = @import("icon_theme.zig");

const svg_supersample = 4;

const IconRender = struct {
    path: []const u8,
    format: icon_theme.IconFormat,
    size: f32,
    color: ?core.Color,
    generation: u64,

    fn renderObject(self: *IconRender) core.RenderObject {
        return .{ .ptr = self, .vtable = &.{
            .layout = layout,
            .paint = paint,
            .hit_test = hitTest,
            .clone = clone,
            .destroy = destroy,
        } };
    }

    fn clone(ptr: *anyopaque, allocator: std.mem.Allocator) !core.RenderObject {
        const self: *const IconRender = @ptrCast(@alignCast(ptr));
        const copy = try allocator.create(IconRender);
        errdefer allocator.destroy(copy);
        copy.* = self.*;
        copy.path = try allocator.dupe(u8, self.path);
        return copy.renderObject();
    }

    fn destroy(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *const IconRender = @ptrCast(@alignCast(ptr));
        allocator.free(self.path);
        allocator.destroy(@constCast(self));
    }

    fn layout(ptr: *anyopaque, context: core.RenderObject.LayoutContext) !core.Size {
        const self: *const IconRender = @ptrCast(@alignCast(ptr));
        return .{
            .width = @min(self.size, context.constraints.max_width),
            .height = @min(self.size, context.constraints.max_height),
        };
    }

    fn paint(ptr: *anyopaque, context: core.RenderObject.PaintContext) !void {
        const self: *const IconRender = @ptrCast(@alignCast(ptr));
        if (context.rect.width <= 0 or context.rect.height <= 0) return;
        const width = try pixelDimension(context.rect.width, 1);
        const height = try pixelDimension(context.rect.height, 1);
        const cache_key = imageCacheKey(self.path, width, height, @intFromEnum(self.format), self.generation);

        if (self.color) |tint| {
            if (context.display_list.cachedAlphaImage(cache_key, width, height)) |alpha| {
                try context.display_list.alphaImage(context.allocator, context.rect, width, height, @constCast(alpha), tint, cache_key);
                return;
            }
        } else if (context.display_list.cachedColorImage(cache_key, width, height)) |pixels| {
            try context.display_list.colorImage(context.allocator, context.rect, width, height, @constCast(pixels), cache_key);
            return;
        }

        const rgba = switch (self.format) {
            .svg => try rasterizeSvg(context.allocator, self.path, width, height),
            .png => try rasterizePng(context.allocator, self.path, width, height),
        };
        defer context.allocator.free(rgba);

        if (self.color) |tint| {
            const alpha = try context.allocator.alloc(u8, try pixelCount(width, height));
            for (alpha, 0..) |*value, index| value.* = rgba[index * 4 + 3];
            try context.display_list.alphaImage(context.allocator, context.rect, width, height, alpha, tint, cache_key);
        } else {
            const pixels = try context.allocator.alloc(core.Color, try pixelCount(width, height));
            for (pixels, 0..) |*color, index| {
                color.* = .{
                    .r = rgba[index * 4],
                    .g = rgba[index * 4 + 1],
                    .b = rgba[index * 4 + 2],
                    .a = rgba[index * 4 + 3],
                };
            }
            try context.display_list.colorImage(context.allocator, context.rect, width, height, pixels, cache_key);
        }
    }

    fn hitTest(_: *anyopaque, _: core.Rect, _: core.Point) ?[]const u8 {
        return null;
    }
};

const MissingIconRender = struct {
    size: f32,

    fn renderObject(self: *MissingIconRender) core.RenderObject {
        return .{ .ptr = self, .vtable = &.{
            .layout = layout,
            .paint = paint,
            .hit_test = hitTest,
            .clone = clone,
            .destroy = destroy,
        } };
    }

    fn clone(ptr: *anyopaque, allocator: std.mem.Allocator) !core.RenderObject {
        const self: *const MissingIconRender = @ptrCast(@alignCast(ptr));
        const copy = try allocator.create(MissingIconRender);
        copy.* = self.*;
        return copy.renderObject();
    }

    fn destroy(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *MissingIconRender = @ptrCast(@alignCast(ptr));
        allocator.destroy(self);
    }

    fn layout(ptr: *anyopaque, context: core.RenderObject.LayoutContext) !core.Size {
        const self: *const MissingIconRender = @ptrCast(@alignCast(ptr));
        return .{ .width = @min(self.size, context.constraints.max_width), .height = @min(self.size, context.constraints.max_height) };
    }

    fn paint(_: *anyopaque, _: core.RenderObject.PaintContext) !void {}

    fn hitTest(_: *anyopaque, _: core.Rect, _: core.Point) ?[]const u8 {
        return null;
    }
};

pub fn icon(allocator: std.mem.Allocator, file: icon_theme.IconFile, size: f32, color: ?core.Color, generation: u64) !core.RenderObject {
    const render = try allocator.create(IconRender);
    errdefer allocator.destroy(render);
    render.* = .{
        .path = try allocator.dupe(u8, file.path),
        .format = file.format,
        .size = size,
        .color = color,
        .generation = generation,
    };
    return render.renderObject();
}

pub fn missing(allocator: std.mem.Allocator, size: f32) !core.RenderObject {
    const render = try allocator.create(MissingIconRender);
    render.* = .{ .size = size };
    return render.renderObject();
}

fn rasterizeSvg(allocator: std.mem.Allocator, path: []const u8, width: u32, height: u32) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const image = image_c.nsvgParseFromFile(path_z.ptr, "px", 96) orelse return error.InvalidSvg;
    defer image_c.nsvgDelete(image);
    const rasterizer = image_c.nsvgCreateRasterizer() orelse return error.OutOfMemory;
    defer image_c.nsvgDeleteRasterizer(rasterizer);

    const raster_width = std.math.mul(usize, width, svg_supersample) catch return error.ImageTooLarge;
    const raster_height = std.math.mul(usize, height, svg_supersample) catch return error.ImageTooLarge;
    if (raster_width > std.math.maxInt(c_int) or raster_height > std.math.maxInt(c_int)) return error.ImageTooLarge;
    const raster_len = std.math.mul(usize, try pixelCount(@intCast(raster_width), @intCast(raster_height)), 4) catch return error.ImageTooLarge;
    const raster = try allocator.alloc(u8, raster_len);
    defer allocator.free(raster);
    @memset(raster, 0);

    const image_width = if (image.*.width > 0) image.*.width else @as(f32, @floatFromInt(width));
    const image_height = if (image.*.height > 0) image.*.height else @as(f32, @floatFromInt(height));
    const fit_scale = @min(@as(f32, @floatFromInt(raster_width)) / image_width, @as(f32, @floatFromInt(raster_height)) / image_height);
    const tx = (@as(f32, @floatFromInt(raster_width)) - image_width * fit_scale) / 2;
    const ty = (@as(f32, @floatFromInt(raster_height)) - image_height * fit_scale) / 2;
    image_c.nsvgRasterize(
        rasterizer,
        image,
        tx,
        ty,
        fit_scale,
        raster.ptr,
        @intCast(raster_width),
        @intCast(raster_height),
        @intCast(raster_width * 4),
    );

    const result = try allocator.alloc(u8, std.math.mul(usize, try pixelCount(width, height), 4) catch return error.ImageTooLarge);
    downsampleRgba(result, raster, width, height, svg_supersample);
    return result;
}

fn rasterizePng(allocator: std.mem.Allocator, path: []const u8, width: u32, height: u32) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    var source_width: c_int = 0;
    var source_height: c_int = 0;
    var source_channels: c_int = 0;
    const source = image_c.stbi_load(path_z.ptr, &source_width, &source_height, &source_channels, 4) orelse return error.InvalidPng;
    defer image_c.stbi_image_free(source);
    if (source_width <= 0 or source_height <= 0) return error.InvalidPng;

    const source_w: u32 = @intCast(source_width);
    const source_h: u32 = @intCast(source_height);
    const fit = @min(
        @as(f64, @floatFromInt(width)) / @as(f64, @floatFromInt(source_w)),
        @as(f64, @floatFromInt(height)) / @as(f64, @floatFromInt(source_h)),
    );
    const scaled_width: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(source_w)) * fit))));
    const scaled_height: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(source_h)) * fit))));
    const scaled_len = std.math.mul(usize, try pixelCount(scaled_width, scaled_height), 4) catch return error.ImageTooLarge;
    const scaled = try allocator.alloc(u8, scaled_len);
    defer allocator.free(scaled);
    if (image_c.stbir_resize_uint8_srgb(
        source,
        source_width,
        source_height,
        0,
        scaled.ptr,
        @intCast(scaled_width),
        @intCast(scaled_height),
        0,
        image_c.STBIR_RGBA,
    ) == null) return error.ImageResizeFailed;

    const result_len = std.math.mul(usize, try pixelCount(width, height), 4) catch return error.ImageTooLarge;
    const result = try allocator.alloc(u8, result_len);
    @memset(result, 0);
    const offset_x = (width - scaled_width) / 2;
    const offset_y = (height - scaled_height) / 2;
    const scaled_stride: usize = @as(usize, scaled_width) * 4;
    const result_stride: usize = @as(usize, width) * 4;
    for (0..scaled_height) |y| {
        const destination = (y + offset_y) * result_stride + @as(usize, offset_x) * 4;
        @memcpy(result[destination..][0..scaled_stride], scaled[y * scaled_stride ..][0..scaled_stride]);
    }
    return result;
}

fn downsampleRgba(destination: []u8, source: []const u8, width: u32, height: u32, comptime supersample: usize) void {
    const raster_width: usize = @as(usize, width) * supersample;
    for (0..height) |y| for (0..width) |x| {
        var sums: [4]usize = .{ 0, 0, 0, 0 };
        for (0..supersample) |sample_y| for (0..supersample) |sample_x| {
            const source_index = (((y * supersample + sample_y) * raster_width) + x * supersample + sample_x) * 4;
            const alpha: usize = source[source_index + 3];
            sums[0] += @as(usize, source[source_index]) * alpha;
            sums[1] += @as(usize, source[source_index + 1]) * alpha;
            sums[2] += @as(usize, source[source_index + 2]) * alpha;
            sums[3] += alpha;
        };
        const destination_index = (y * width + x) * 4;
        const samples = supersample * supersample;
        if (sums[3] == 0) {
            @memset(destination[destination_index..][0..4], 0);
        } else {
            destination[destination_index] = @intCast((sums[0] + sums[3] / 2) / sums[3]);
            destination[destination_index + 1] = @intCast((sums[1] + sums[3] / 2) / sums[3]);
            destination[destination_index + 2] = @intCast((sums[2] + sums[3] / 2) / sums[3]);
            destination[destination_index + 3] = @intCast((sums[3] + samples / 2) / samples);
        }
    };
}

fn pixelDimension(logical: f32, scale: f32) !u32 {
    const pixels = @ceil(@as(f64, logical) * @as(f64, scale));
    if (!std.math.isFinite(pixels) or pixels <= 0 or pixels > @as(f64, std.math.maxInt(c_int))) return error.ImageTooLarge;
    return @max(1, @as(u32, @intFromFloat(pixels)));
}

fn pixelCount(width: u32, height: u32) !usize {
    return std.math.mul(usize, width, height) catch error.ImageTooLarge;
}

fn imageCacheKey(path: []const u8, width: u32, height: u32, format: u8, generation: u64) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(path);
    hasher.update(std.mem.asBytes(&width));
    hasher.update(std.mem.asBytes(&height));
    hasher.update(&.{format});
    hasher.update(std.mem.asBytes(&generation));
    return hasher.final();
}

test "NanoSVG rasterizes an SVG without system image libraries" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "icon.svg",
        .data = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"8\" height=\"8\"><rect width=\"8\" height=\"8\" fill=\"#ff0000\"/></svg>",
    });
    const path = try temporary.dir.realPathFileAlloc(std.testing.io, "icon.svg", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const rgba = try rasterizeSvg(std.testing.allocator, path, 8, 8);
    defer std.testing.allocator.free(rgba);
    try std.testing.expectEqual(@as(usize, 8 * 8 * 4), rgba.len);
    try std.testing.expectEqual(@as(u8, 0xff), rgba[0]);
    try std.testing.expectEqual(@as(u8, 0xff), rgba[3]);
}
