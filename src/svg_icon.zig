//! SVG icon render object support.

const std = @import("std");
const keywork = @import("core.zig");
const c = @import("image_c");

const icon_supersample = 4;

const SvgIcon = struct {
    path: []const u8,
    size: f32,
    color: keywork.Color,

    const vtable: keywork.Widget.RenderObject.VTable = .{
        .layout = layout,
        .paint = paint,
    };

    fn renderObject(self: *SvgIcon) keywork.Widget.RenderObject {
        return .{
            .ptr = self,
            .vtable = &vtable,
            .clone_fn = clone,
            .destroy_fn = destroy,
        };
    }

    fn layout(ptr: *const anyopaque, context: keywork.Widget.RenderObject.LayoutContext) !keywork.Size {
        const self: *const SvgIcon = @ptrCast(@alignCast(ptr));
        return .{
            .width = @min(self.size, context.constraints.max_width),
            .height = @min(self.size, context.constraints.max_height),
        };
    }

    fn paint(ptr: *const anyopaque, context: keywork.Widget.RenderObject.PaintContext) !void {
        const self: *const SvgIcon = @ptrCast(@alignCast(ptr));
        if (context.rect.width <= 0 or context.rect.height <= 0) return;

        const render_scale = if (std.math.isFinite(context.scale) and context.scale > 0) context.scale else 1;
        const width = @max(1, @as(usize, @intFromFloat(@ceil(context.rect.width * render_scale))));
        const height = @max(1, @as(usize, @intFromFloat(@ceil(context.rect.height * render_scale))));
        const alpha_cache_key = cacheKey(self.path, width, height, icon_supersample);
        if (context.display_list.cachedAlphaImage(alpha_cache_key, @intCast(width), @intCast(height))) |alpha| {
            try context.display_list.alphaImage(
                context.allocator,
                context.rect,
                @intCast(width),
                @intCast(height),
                @constCast(alpha),
                self.color,
                alpha_cache_key,
            );
            return;
        }

        const path_z = try context.allocator.dupeZ(u8, self.path);
        defer context.allocator.free(path_z);
        const image = c.nsvgParseFromFile(path_z.ptr, "px", 96) orelse return error.InvalidSvg;
        defer c.nsvgDelete(image);
        const rasterizer = c.nsvgCreateRasterizer() orelse return error.OutOfMemory;
        defer c.nsvgDeleteRasterizer(rasterizer);

        const raster_width = width * icon_supersample;
        const raster_height = height * icon_supersample;
        const pixels = try context.allocator.alloc(u8, raster_width * raster_height * 4);
        defer context.allocator.free(pixels);
        @memset(pixels, 0);

        const image_width = if (image.*.width > 0) image.*.width else context.rect.width;
        const image_height = if (image.*.height > 0) image.*.height else context.rect.height;
        const scale = @min(@as(f32, @floatFromInt(raster_width)) / image_width, @as(f32, @floatFromInt(raster_height)) / image_height);
        const scaled_width = image_width * scale;
        const scaled_height = image_height * scale;
        const tx = (@as(f32, @floatFromInt(raster_width)) - scaled_width) / 2;
        const ty = (@as(f32, @floatFromInt(raster_height)) - scaled_height) / 2;
        c.nsvgRasterize(rasterizer, image, tx, ty, scale, pixels.ptr, @intCast(raster_width), @intCast(raster_height), @intCast(raster_width * 4));

        const alpha = try context.allocator.alloc(u8, width * height);
        downsampleAlpha(alpha, pixels, width, height, icon_supersample);
        try context.display_list.alphaImage(
            context.allocator,
            context.rect,
            @intCast(width),
            @intCast(height),
            alpha,
            self.color,
            alpha_cache_key,
        );
    }

    fn cacheKey(path: []const u8, width: usize, height: usize, supersample: usize) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(path);
        hasher.update(std.mem.asBytes(&width));
        hasher.update(std.mem.asBytes(&height));
        hasher.update(std.mem.asBytes(&supersample));
        return hasher.final();
    }

    fn clone(allocator: std.mem.Allocator, ptr: *const anyopaque) !*anyopaque {
        const self: *const SvgIcon = @ptrCast(@alignCast(ptr));
        const result = try allocator.create(SvgIcon);
        errdefer allocator.destroy(result);
        result.* = .{
            .path = try allocator.dupe(u8, self.path),
            .size = self.size,
            .color = self.color,
        };
        return result;
    }

    fn destroy(allocator: std.mem.Allocator, ptr: *const anyopaque) void {
        const self: *SvgIcon = @ptrCast(@alignCast(@constCast(ptr)));
        allocator.free(self.path);
        allocator.destroy(self);
    }
};

fn downsampleAlpha(dst: []u8, src_rgba: []const u8, width: usize, height: usize, comptime supersample: usize) void {
    const raster_width = width * supersample;
    const samples = supersample * supersample;
    for (0..height) |y| {
        for (0..width) |x| {
            var sum: usize = 0;
            for (0..supersample) |sy| {
                for (0..supersample) |sx| {
                    const src_x = x * supersample + sx;
                    const src_y = y * supersample + sy;
                    sum += src_rgba[(src_y * raster_width + src_x) * 4 + 3];
                }
            }
            dst[y * width + x] = @intCast((sum + samples / 2) / samples);
        }
    }
}

pub fn icon(allocator: std.mem.Allocator, path: []const u8, size: f32, color: keywork.Color) !keywork.Widget {
    const icon_size = @max(1, size);
    const self = try allocator.create(SvgIcon);
    errdefer allocator.destroy(self);
    self.* = .{
        .path = try allocator.dupe(u8, path),
        .size = icon_size,
        .color = color,
    };
    return .{ .render_object = self.renderObject() };
}
