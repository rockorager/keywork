//! SVG icon render object support.

const std = @import("std");
const keywork = @import("../ui.zig");
const c = @import("image_c");

const log = std.log.scoped(.keywork_svg);

const max_svg_bytes = 4 * 1024 * 1024;

const icon_supersample = 4;
// The supersampled raster buffer costs 64 bytes per output pixel, so the
// clamp bounds the transient allocation at 256 MiB; anything beyond
// icon-scale targets is either a layout bug or hostile input.
const max_raster_dim = 2048;

const SvgIcon = struct {
    path: []const u8,
    size: f32,
    /// Tint for the rasterized alpha mask; null renders the SVG's own
    /// colors as a full-color image.
    color: ?keywork.Color,

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
        const req_width = @ceil(context.rect.width * render_scale);
        const req_height = @ceil(context.rect.height * render_scale);
        // Backends blit images 1:1 into the rect, so a capped raster
        // can't be drawn scaled up; skip the draw instead of blitting a
        // truncated corner. No file IO happens on this path, and the
        // repeated warn flags what is either a layout bug or hostile
        // input.
        if (req_width > max_raster_dim or req_height > max_raster_dim) {
            log.warn("svg raster target {d:.0}x{d:.0} exceeds {d}: {s}", .{ req_width, req_height, max_raster_dim, self.path });
            return;
        }
        const width = @max(1, @as(usize, @intFromFloat(req_width)));
        const height = @max(1, @as(usize, @intFromFloat(req_height)));
        const cache_key = cacheKey(self.path, width, height, icon_supersample);
        if (self.color) |tint| {
            if (context.display_list.cachedAlphaImage(cache_key, @intCast(width), @intCast(height))) |alpha| {
                try context.display_list.alphaImage(
                    context.allocator,
                    context.rect,
                    @intCast(width),
                    @intCast(height),
                    @constCast(alpha),
                    tint,
                    cache_key,
                );
                return;
            }
        } else if (context.display_list.cachedColorImage(cache_key, @intCast(width), @intCast(height))) |cached| {
            try context.display_list.colorImage(
                context.allocator,
                context.rect,
                @intCast(width),
                @intCast(height),
                @constCast(cached),
                cache_key,
            );
            return;
        }

        // Parse failure degrades to a cached transparent tombstone
        // instead of failing the frame: the file may be malformed or
        // gone, and later repaints must not reopen it or warn again.
        const tree = parseSvgFile(context.allocator, self.path) orelse {
            log.warn("svg parse failed: {s}", .{self.path});
            return self.paintTombstone(context, width, height, cache_key);
        };
        defer c.resvg_tree_destroy(tree);

        const raster_width = width * icon_supersample;
        const raster_height = height * icon_supersample;
        const pixels = try context.allocator.alloc(u8, raster_width * raster_height * 4);
        defer context.allocator.free(pixels);
        @memset(pixels, 0);

        const image_size = c.resvg_get_image_size(tree);
        const image_width = image_size.width;
        const image_height = image_size.height;
        const scale = @min(@as(f32, @floatFromInt(raster_width)) / image_width, @as(f32, @floatFromInt(raster_height)) / image_height);
        const scaled_width = image_width * scale;
        const scaled_height = image_height * scale;
        const tx = (@as(f32, @floatFromInt(raster_width)) - scaled_width) / 2;
        const ty = (@as(f32, @floatFromInt(raster_height)) - scaled_height) / 2;
        c.resvg_render(
            tree,
            .{ .a = scale, .b = 0, .c = 0, .d = scale, .e = tx, .f = ty },
            @intCast(raster_width),
            @intCast(raster_height),
            pixels.ptr,
        );

        if (self.color) |tint| {
            const alpha = try context.allocator.alloc(u8, width * height);
            downsampleAlpha(alpha, pixels, width, height, icon_supersample);
            try context.display_list.alphaImage(
                context.allocator,
                context.rect,
                @intCast(width),
                @intCast(height),
                alpha,
                tint,
                cache_key,
            );
        } else {
            const colors = try context.allocator.alloc(keywork.Color, width * height);
            downsamplePremultipliedColor(colors, pixels, width, height, icon_supersample);
            try context.display_list.colorImage(
                context.allocator,
                context.rect,
                @intCast(width),
                @intCast(height),
                colors,
                cache_key,
            );
        }
    }

    /// Caches a fully transparent image under the icon's key so later
    /// paints hit the cache instead of reopening the broken file; both
    /// backends skip zero-alpha pixels, so it draws nothing.
    fn paintTombstone(
        self: *const SvgIcon,
        context: keywork.Widget.RenderObject.PaintContext,
        width: usize,
        height: usize,
        cache_key: u64,
    ) !void {
        if (self.color) |tint| {
            const alpha = try context.allocator.alloc(u8, width * height);
            @memset(alpha, 0);
            try context.display_list.alphaImage(
                context.allocator,
                context.rect,
                @intCast(width),
                @intCast(height),
                alpha,
                tint,
                cache_key,
            );
        } else {
            const colors = try context.allocator.alloc(keywork.Color, width * height);
            @memset(colors, keywork.colors.transparent);
            try context.display_list.colorImage(
                context.allocator,
                context.rect,
                @intCast(width),
                @intCast(height),
                colors,
                cache_key,
            );
        }
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

/// Reads and parses a bounded SVG file. Returns null on any failure; the
/// caller treats that as a broken file.
fn parseSvgFile(allocator: std.mem.Allocator, path: []const u8) ?*c.resvg_render_tree {
    const contents = readSvgFile(allocator, path) orelse return null;
    defer allocator.free(contents);

    const options = c.resvg_options_create() orelse return null;
    defer c.resvg_options_destroy(options);

    var tree: ?*c.resvg_render_tree = null;
    if (c.resvg_parse_tree_from_data(contents.ptr, contents.len, options, &tree) != c.RESVG_OK) return null;
    return tree;
}

fn readSvgFile(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    const fd = std.posix.openat(std.os.linux.AT.FDCWD, path, .{ .CLOEXEC = true }, 0) catch return null;
    defer _ = std.os.linux.close(fd);

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);
    var buffer: [4096]u8 = undefined;
    while (true) {
        const read_count = std.posix.read(fd, &buffer) catch return null;
        if (read_count == 0) break;
        if (result.items.len + read_count > max_svg_bytes) return null;
        result.appendSlice(allocator, buffer[0..read_count]) catch return null;
    }
    return result.toOwnedSlice(allocator) catch null;
}

/// Box-filters premultiplied RGBA, then converts to the display list's
/// straight-alpha Color representation.
fn downsamplePremultipliedColor(dst: []keywork.Color, src_rgba: []const u8, width: usize, height: usize, comptime supersample: usize) void {
    const raster_width = width * supersample;
    for (0..height) |y| {
        for (0..width) |x| {
            var sum_r: usize = 0;
            var sum_g: usize = 0;
            var sum_b: usize = 0;
            var sum_a: usize = 0;
            for (0..supersample) |sy| {
                for (0..supersample) |sx| {
                    const src_x = x * supersample + sx;
                    const src_y = y * supersample + sy;
                    const texel = src_rgba[(src_y * raster_width + src_x) * 4 ..][0..4];
                    sum_r += texel[0];
                    sum_g += texel[1];
                    sum_b += texel[2];
                    sum_a += texel[3];
                }
            }
            const samples = supersample * supersample;
            dst[y * width + x] = if (sum_a == 0) keywork.colors.transparent else .{
                .r = unpremultiply(sum_r, sum_a),
                .g = unpremultiply(sum_g, sum_a),
                .b = unpremultiply(sum_b, sum_a),
                .a = @intCast((sum_a + samples / 2) / samples),
            };
        }
    }
}

fn unpremultiply(channel_sum: usize, alpha_sum: usize) u8 {
    return @intCast(@min(255, (channel_sum * 255 + alpha_sum / 2) / alpha_sum));
}

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

test "premultiplied SVG pixels become straight-alpha colors" {
    var src: [icon_supersample * icon_supersample * 4]u8 = undefined;
    for (0..icon_supersample * icon_supersample) |index| {
        src[index * 4 + 0] = 128;
        src[index * 4 + 1] = 32;
        src[index * 4 + 2] = 0;
        src[index * 4 + 3] = 128;
    }
    var dst: [1]keywork.Color = undefined;

    downsamplePremultipliedColor(&dst, &src, 1, 1, icon_supersample);

    try std.testing.expectEqual(keywork.Color.argb(128, 255, 64, 0), dst[0]);
}

test "resvg renders use references" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "use.svg",
        .data =
        \\<svg xmlns="http://www.w3.org/2000/svg" width="4" height="4" viewBox="0 0 4 4">
        \\  <defs><rect id="bar" width="2" height="4" fill="#ff0000"/></defs>
        \\  <use href="#bar" x="2"/>
        \\</svg>
        ,
    });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "use.svg", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const tree = parseSvgFile(std.testing.allocator, path) orelse return error.TestUnexpectedResult;
    defer c.resvg_tree_destroy(tree);
    var pixels: [4 * 4 * 4]u8 = @splat(0);

    c.resvg_render(tree, c.resvg_transform_identity(), 4, 4, &pixels);

    try std.testing.expectEqual(@as(u8, 0), pixels[(1 * 4 + 0) * 4 + 3]);
    try std.testing.expectEqual(@as(u8, 255), pixels[(1 * 4 + 3) * 4 + 3]);
}

pub fn icon(allocator: std.mem.Allocator, path: []const u8, size: f32, color: ?keywork.Color) !keywork.Widget {
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
