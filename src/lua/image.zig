//! Lua image widget decoding and rendering.

const std = @import("std");
const keywork = @import("../ui.zig");
const lua_codec = @import("codec.zig");
const lua_value = @import("value.zig");
const image_c = @import("image_c");
const c = @import("luajit_c");

const absoluteIndex = lua_value.absoluteIndex;
const expectType = lua_value.expectType;
const pop = lua_value.pop;
const stringFromStack = lua_value.stringFromStack;

const log = std.log.scoped(.keywork_image);

// stb's own dimension cap (131072) still allows multi-GiB decodes;
// reject absurd raster sources before any pixel allocation.
const max_image_dim = 16384;
const max_image_pixels = 16 << 20;

const Options = struct {
    width: u32 = 0,
    height: u32 = 0,
    size: ?f32 = null,
    format: []const u8 = "argb32",
};

const Image = struct {
    width: u32,
    height: u32,
    size: f32,
    preserve_aspect: bool = false,
    pixels: []keywork.Color,
    cache_key: u64,

    const vtable: keywork.Widget.RenderObject.VTable = .{
        .layout = layout,
        .paint = paint,
    };

    fn widget(self: *Image) keywork.Widget {
        return .{ .render_object = .{
            .ptr = self,
            .vtable = &vtable,
            .clone_fn = clone,
            .destroy_fn = destroy,
        } };
    }

    fn layout(ptr: *const anyopaque, context: keywork.Widget.RenderObject.LayoutContext) !keywork.Size {
        const self: *const Image = @ptrCast(@alignCast(ptr));
        const longest: f32 = @floatFromInt(@max(self.width, self.height));
        const width = if (self.preserve_aspect and longest > 0) self.size * @as(f32, @floatFromInt(self.width)) / longest else self.size;
        const height = if (self.preserve_aspect and longest > 0) self.size * @as(f32, @floatFromInt(self.height)) / longest else self.size;
        return .{
            .width = @min(width, context.constraints.max_width),
            .height = @min(height, context.constraints.max_height),
        };
    }

    fn paint(ptr: *const anyopaque, context: keywork.Widget.RenderObject.PaintContext) !void {
        const self: *const Image = @ptrCast(@alignCast(ptr));
        if (context.rect.width <= 0 or context.rect.height <= 0) return;
        if (self.width == 0 or self.height == 0) return;

        // The renderer blits image pixels 1:1 at physical resolution, so
        // the source must be resampled to rect * scale (like svg_icon).
        const render_scale = if (std.math.isFinite(context.scale) and context.scale > 0) context.scale else 1;
        const target_width: u32 = @max(1, @as(u32, @intFromFloat(@ceil(context.rect.width * render_scale))));
        const target_height: u32 = @max(1, @as(u32, @intFromFloat(@ceil(context.rect.height * render_scale))));

        var hasher = std.hash.Wyhash.init(self.cache_key);
        hasher.update(std.mem.asBytes(&target_width));
        hasher.update(std.mem.asBytes(&target_height));
        const cache_key = hasher.final();

        if (context.raster_cache.cachedColorImage(cache_key, target_width, target_height)) |cached| {
            try context.display_list.colorImage(
                context.allocator,
                context.rect,
                target_width,
                target_height,
                cached,
                cache_key,
            );
            return;
        }

        const pixels = try resampledPixels(context.allocator, self.pixels, self.width, self.height, target_width, target_height);
        const cached = try context.raster_cache.insertColor(context.allocator, cache_key, target_width, target_height, pixels);
        try context.display_list.colorImage(
            context.allocator,
            context.rect,
            target_width,
            target_height,
            cached,
            cache_key,
        );
    }

    fn clone(allocator: std.mem.Allocator, ptr: *const anyopaque) !*anyopaque {
        const self: *const Image = @ptrCast(@alignCast(ptr));
        const result = try allocator.create(Image);
        errdefer allocator.destroy(result);
        result.* = .{
            .width = self.width,
            .height = self.height,
            .size = self.size,
            .preserve_aspect = self.preserve_aspect,
            .pixels = try allocator.dupe(keywork.Color, self.pixels),
            .cache_key = self.cache_key,
        };
        return result;
    }

    fn destroy(allocator: std.mem.Allocator, ptr: *const anyopaque) void {
        const self: *Image = @ptrCast(@alignCast(@constCast(ptr)));
        allocator.free(self.pixels);
        allocator.destroy(self);
    }
};

pub fn parse(lua_state: *c.lua_State, allocator: std.mem.Allocator, table: c_int) !keywork.Widget {
    const options = try lua_codec.decode(Options, lua_state, table, allocator);
    if (options.width == 0 or options.height == 0) return error.InvalidImageSize;
    if (options.width > max_image_dim or options.height > max_image_dim) return error.InvalidImageSize;
    if (@as(u64, options.width) * options.height > max_image_pixels) return error.InvalidImageSize;
    if (!std.mem.eql(u8, options.format, "argb32")) return error.UnsupportedImageFormat;

    c.lua_getfield(lua_state, table, "pixels");
    defer pop(lua_state, 1);
    const pixels = try parseArgb32Pixels(lua_state, allocator, -1, options.width, options.height);
    errdefer allocator.free(pixels);

    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&options.width));
    hasher.update(std.mem.asBytes(&options.height));
    hasher.update(std.mem.sliceAsBytes(pixels));

    const image = try allocator.create(Image);
    errdefer allocator.destroy(image);
    image.* = .{
        .width = options.width,
        .height = options.height,
        .size = options.size orelse @floatFromInt(@max(options.width, options.height)),
        .pixels = pixels,
        .cache_key = hasher.final(),
    };
    return image.widget();
}

/// PNG-backed icon that defers pixel decoding to paint time. Widget parsing
/// happens on every rebuild (every scroll frame for visible list rows), so
/// it must stay free of decode work: only the header is read here for the
/// intrinsic aspect ratio. Paint decodes once per path+target size and the
/// pixels then live in the display list's color cache.
const PngIcon = struct {
    path: []const u8,
    size: f32,
    source_width: u32,
    source_height: u32,

    const vtable: keywork.Widget.RenderObject.VTable = .{
        .layout = layout,
        .paint = paint,
    };

    fn widget(self: *PngIcon) keywork.Widget {
        return .{ .render_object = .{
            .ptr = self,
            .vtable = &vtable,
            .clone_fn = clone,
            .destroy_fn = destroy,
        } };
    }

    fn layout(ptr: *const anyopaque, context: keywork.Widget.RenderObject.LayoutContext) !keywork.Size {
        const self: *const PngIcon = @ptrCast(@alignCast(ptr));
        const longest: f32 = @floatFromInt(@max(self.source_width, self.source_height));
        const width = self.size * @as(f32, @floatFromInt(self.source_width)) / longest;
        const height = self.size * @as(f32, @floatFromInt(self.source_height)) / longest;
        return .{
            .width = @min(width, context.constraints.max_width),
            .height = @min(height, context.constraints.max_height),
        };
    }

    fn paint(ptr: *const anyopaque, context: keywork.Widget.RenderObject.PaintContext) !void {
        const self: *const PngIcon = @ptrCast(@alignCast(ptr));
        if (context.rect.width <= 0 or context.rect.height <= 0) return;

        const render_scale = if (std.math.isFinite(context.scale) and context.scale > 0) context.scale else 1;
        const target_width: u32 = @max(1, @as(u32, @intFromFloat(@ceil(context.rect.width * render_scale))));
        const target_height: u32 = @max(1, @as(u32, @intFromFloat(@ceil(context.rect.height * render_scale))));

        var path_hasher = std.hash.Wyhash.init(0);
        path_hasher.update(self.path);
        var hasher = std.hash.Wyhash.init(path_hasher.final());
        hasher.update(std.mem.asBytes(&target_width));
        hasher.update(std.mem.asBytes(&target_height));
        const cache_key = hasher.final();

        if (context.raster_cache.cachedColorImage(cache_key, target_width, target_height)) |cached| {
            try context.display_list.colorImage(
                context.allocator,
                context.rect,
                target_width,
                target_height,
                cached,
                cache_key,
            );
            return;
        }

        const path_z = try context.allocator.dupeZ(u8, self.path);
        defer context.allocator.free(path_z);
        var source_width: c_int = 0;
        var source_height: c_int = 0;
        var source_channels: c_int = 0;
        // Decode failure degrades to a cached transparent tombstone
        // instead of failing the frame: the file may have changed or
        // vanished since the header probe, and later repaints must not
        // reopen it or warn again.
        const source_bytes = image_c.stbi_load(path_z.ptr, &source_width, &source_height, &source_channels, 4) orelse {
            log.warn("image decode failed: {s}", .{self.path});
            return paintTombstone(context, target_width, target_height, cache_key);
        };
        defer image_c.stbi_image_free(source_bytes);
        const dims = checkedDims(source_width, source_height) catch {
            log.warn("image rejected ({d}x{d}): {s}", .{ source_width, source_height, self.path });
            return paintTombstone(context, target_width, target_height, cache_key);
        };

        const pixel_count = @as(usize, dims.width) * dims.height;
        const source_pixels = try context.allocator.alloc(keywork.Color, pixel_count);
        defer context.allocator.free(source_pixels);
        fillRgbaPixels(source_pixels, source_bytes[0 .. pixel_count * 4]);

        const pixels = try resampledPixels(
            context.allocator,
            source_pixels,
            dims.width,
            dims.height,
            target_width,
            target_height,
        );
        const cached = try context.raster_cache.insertColor(context.allocator, cache_key, target_width, target_height, pixels);
        try context.display_list.colorImage(
            context.allocator,
            context.rect,
            target_width,
            target_height,
            cached,
            cache_key,
        );
    }

    fn clone(allocator: std.mem.Allocator, ptr: *const anyopaque) !*anyopaque {
        const self: *const PngIcon = @ptrCast(@alignCast(ptr));
        const result = try allocator.create(PngIcon);
        errdefer allocator.destroy(result);
        result.* = .{
            .path = try allocator.dupe(u8, self.path),
            .size = self.size,
            .source_width = self.source_width,
            .source_height = self.source_height,
        };
        return result;
    }

    fn destroy(allocator: std.mem.Allocator, ptr: *const anyopaque) void {
        const self: *PngIcon = @ptrCast(@alignCast(@constCast(ptr)));
        allocator.free(self.path);
        allocator.destroy(self);
    }
};

/// Caches a fully transparent image under the icon's key so later paints
/// hit the cache instead of reopening the broken file; the backends skip
/// zero-alpha pixels, so it draws nothing.
fn paintTombstone(
    context: keywork.Widget.RenderObject.PaintContext,
    width: u32,
    height: u32,
    cache_key: u64,
) !void {
    const pixels = try context.allocator.alloc(keywork.Color, @as(usize, width) * height);
    @memset(pixels, keywork.colors.transparent);
    const cached = try context.raster_cache.insertColor(context.allocator, cache_key, width, height, pixels);
    try context.display_list.colorImage(context.allocator, context.rect, width, height, cached, cache_key);
}

/// Caches intrinsic image dimensions per path so widget parsing (every
/// rebuild of a visible list row) skips the stbi_info header read.
/// Probe failures tombstone like the icon-theme cache: a broken file
/// stays broken until the process restarts, and warns only once.
pub const DimsCache = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMapUnmanaged(?Dims) = .empty,

    pub const Dims = struct { width: u32, height: u32 };

    pub fn init(allocator: std.mem.Allocator) DimsCache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DimsCache) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.entries.deinit(self.allocator);
    }

    fn lookup(self: *DimsCache, path: []const u8) !?Dims {
        if (self.entries.get(path)) |cached| return cached;
        const dims: ?Dims = probeDims(self.allocator, path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
        if (dims == null) log.warn("unreadable image: {s}", .{path});
        const key = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(key);
        try self.entries.put(self.allocator, key, dims);
        return dims;
    }
};

fn probeDims(allocator: std.mem.Allocator, path: []const u8) !DimsCache.Dims {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    var source_width: c_int = 0;
    var source_height: c_int = 0;
    var source_channels: c_int = 0;
    if (image_c.stbi_info(path_z.ptr, &source_width, &source_height, &source_channels) == 0) return error.InvalidImage;
    return checkedDims(source_width, source_height);
}

fn checkedDims(width: c_int, height: c_int) !DimsCache.Dims {
    if (width <= 0 or height <= 0) return error.InvalidImage;
    const w: u32 = @intCast(width);
    const h: u32 = @intCast(height);
    if (w > max_image_dim or h > max_image_dim) return error.ImageTooLarge;
    if (@as(u64, w) * h > max_image_pixels) return error.ImageTooLarge;
    return .{ .width = w, .height = h };
}

pub fn pngIcon(allocator: std.mem.Allocator, dims_cache: ?*DimsCache, path: []const u8, size: f32) !keywork.Widget {
    // Only the header is read for the intrinsic dimensions; the pixels
    // are decoded lazily at paint.
    const dims = if (dims_cache) |cache|
        (try cache.lookup(path)) orelse return error.InvalidImage
    else
        try probeDims(allocator, path);

    const icon = try allocator.create(PngIcon);
    errdefer allocator.destroy(icon);
    icon.* = .{
        .path = try allocator.dupe(u8, path),
        .size = @floatFromInt(positiveImageSize(size)),
        .source_width = dims.width,
        .source_height = dims.height,
    };
    return icon.widget();
}

fn parseArgb32Pixels(lua_state: *c.lua_State, allocator: std.mem.Allocator, index: c_int, width: u32, height: u32) ![]keywork.Color {
    const pixel_count = @as(usize, width) * @as(usize, height);
    const byte_count = pixel_count * 4;
    const pixels = try allocator.alloc(keywork.Color, pixel_count);
    errdefer allocator.free(pixels);

    if (c.lua_type(lua_state, index) == c.LUA_TSTRING) {
        const bytes = try stringFromStack(lua_state, index);
        if (bytes.len < byte_count) return error.InvalidImagePixels;
        fillArgb32Pixels(pixels, bytes[0..byte_count]);
        return pixels;
    }

    try expectType(lua_state, index, c.LUA_TTABLE);
    const table = absoluteIndex(lua_state, index);
    var pixel_index: usize = 0;
    while (pixel_index < pixel_count) : (pixel_index += 1) {
        const base: c_int = @intCast(pixel_index * 4);
        const a = try imageByteField(lua_state, table, base + 1);
        const r = try imageByteField(lua_state, table, base + 2);
        const g = try imageByteField(lua_state, table, base + 3);
        const b = try imageByteField(lua_state, table, base + 4);
        pixels[pixel_index] = keywork.Color.argb(a, r, g, b);
    }
    return pixels;
}

fn fillArgb32Pixels(pixels: []keywork.Color, bytes: []const u8) void {
    for (pixels, 0..) |*pixel, index| {
        const base = index * 4;
        pixel.* = keywork.Color.argb(bytes[base], bytes[base + 1], bytes[base + 2], bytes[base + 3]);
    }
}

fn fillRgbaPixels(pixels: []keywork.Color, bytes: []const u8) void {
    for (pixels, 0..) |*pixel, index| {
        const base = index * 4;
        pixel.* = keywork.Color.argb(bytes[base + 3], bytes[base], bytes[base + 1], bytes[base + 2]);
    }
}

fn resampledPixels(
    allocator: std.mem.Allocator,
    source: []const keywork.Color,
    source_width: u32,
    source_height: u32,
    target_width: u32,
    target_height: u32,
) ![]keywork.Color {
    if (source_width == target_width and source_height == target_height) return allocator.dupe(keywork.Color, source);

    const source_bytes = try allocator.alloc(u8, source.len * 4);
    defer allocator.free(source_bytes);
    for (source, 0..) |pixel, index| {
        const base = index * 4;
        source_bytes[base] = pixel.r;
        source_bytes[base + 1] = pixel.g;
        source_bytes[base + 2] = pixel.b;
        source_bytes[base + 3] = pixel.a;
    }

    const target_bytes = try allocator.alloc(u8, @as(usize, target_width) * target_height * 4);
    defer allocator.free(target_bytes);
    if (image_c.stbir_resize_uint8_linear(
        source_bytes.ptr,
        @intCast(source_width),
        @intCast(source_height),
        0,
        target_bytes.ptr,
        @intCast(target_width),
        @intCast(target_height),
        0,
        image_c.STBIR_RGBA_NO_AW,
    ) == null) return error.ImageResizeFailed;

    const pixels = try allocator.alloc(keywork.Color, @as(usize, target_width) * target_height);
    fillRgbaPixels(pixels, target_bytes);
    return pixels;
}

fn positiveImageSize(size: f32) usize {
    if (!std.math.isFinite(size) or size <= 0) return 16;
    return @max(1, @as(usize, @intFromFloat(@round(size))));
}

fn imageByteField(lua_state: *c.lua_State, table: c_int, index: c_int) !u8 {
    c.lua_rawgeti(lua_state, table, index);
    defer pop(lua_state, 1);
    if (c.lua_isnumber(lua_state, -1) == 0) return error.InvalidImagePixels;
    const value = c.lua_tointeger(lua_state, -1);
    if (value < 0 or value > 255) return error.InvalidImagePixels;
    return @intCast(value);
}

test "checkedDims rejects invalid and oversized sources" {
    try std.testing.expectError(error.InvalidImage, checkedDims(0, 16));
    try std.testing.expectError(error.InvalidImage, checkedDims(16, -1));
    try std.testing.expectError(error.ImageTooLarge, checkedDims(max_image_dim + 1, 1));
    try std.testing.expectError(error.ImageTooLarge, checkedDims(1, max_image_dim + 1));
    // Both dimensions in range, but the pixel count blows the budget.
    try std.testing.expectError(error.ImageTooLarge, checkedDims(8192, 8192));
    const dims = try checkedDims(4096, 4096);
    try std.testing.expectEqual(@as(u32, 4096), dims.width);
    try std.testing.expectEqual(@as(u32, 4096), dims.height);
}

test "dims cache tombstones unreadable files" {
    // The first probe failure per path logs a warning by design.
    std.testing.log_level = .err;
    var cache: DimsCache = .init(std.testing.allocator);
    defer cache.deinit();

    try std.testing.expect(try cache.lookup("/nonexistent/keywork-test.png") == null);
    try std.testing.expectEqual(@as(usize, 1), cache.entries.count());
    // The tombstone answers without a second probe or a new entry.
    try std.testing.expect(try cache.lookup("/nonexistent/keywork-test.png") == null);
    try std.testing.expectEqual(@as(usize, 1), cache.entries.count());
}
