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

const Fit = enum {
    fill,
    cover,
    contain,
    none,
};

const Cache = enum {
    auto,
    frame,
};

const Alignment = enum {
    top_left,
    top_center,
    top_right,
    center_left,
    center,
    center_right,
    bottom_left,
    bottom_center,
    bottom_right,

    fn horizontal(self: Alignment) f32 {
        return switch (self) {
            .top_left, .center_left, .bottom_left => 0,
            .top_center, .center, .bottom_center => 0.5,
            .top_right, .center_right, .bottom_right => 1,
        };
    }

    fn vertical(self: Alignment) f32 {
        return switch (self) {
            .top_left, .top_center, .top_right => 0,
            .center_left, .center, .center_right => 0.5,
            .bottom_left, .bottom_center, .bottom_right => 1,
        };
    }
};

const Options = struct {
    path: ?[]const u8 = null,
    width: u32 = 0,
    height: u32 = 0,
    size: ?f32 = null,
    format: []const u8 = "argb32",
    fit: Fit = .fill,
    @"align": Alignment = .center,
    cache: Cache = .auto,
    revision: f64 = 0,
};

const Image = struct {
    width: u32,
    height: u32,
    size: f32,
    preserve_aspect: bool = false,
    pixels: []keywork.Color,
    fit: Fit,
    alignment: Alignment,
    cache: Cache,
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

        const geometry = fittedGeometry(context.rect, self.width, self.height, self.fit, self.alignment);
        if (geometry.rect.width <= 0 or geometry.rect.height <= 0) return;

        // The renderer blits image pixels 1:1 at physical resolution, so
        // the source must be resampled to rect * scale (like svg_icon).
        const render_scale = if (std.math.isFinite(context.scale) and context.scale > 0) context.scale else 1;
        const target_width: u32 = @max(1, @as(u32, @intFromFloat(@ceil(geometry.rect.width * render_scale))));
        const target_height: u32 = @max(1, @as(u32, @intFromFloat(@ceil(geometry.rect.height * render_scale))));

        const cache_key = geometryCacheKey(self.cache_key, target_width, target_height, geometry.source);
        if (self.cache == .auto and try paintCached(context, geometry.rect, target_width, target_height, cache_key)) return;

        const pixel_allocator = imagePixelAllocator(self.cache, context.allocator);
        const pixels = try resampledPixels(pixel_allocator, self.pixels, self.width, self.height, target_width, target_height, geometry.source);
        const rendered = try retainPixels(context, self.cache, pixel_allocator, cache_key, target_width, target_height, pixels);
        try paintColorImage(context, geometry.rect, target_width, target_height, rendered, cache_key);
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
            .fit = self.fit,
            .alignment = self.alignment,
            .cache = self.cache,
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

pub fn parse(
    lua_state: *c.lua_State,
    allocator: std.mem.Allocator,
    dims_cache: ?*DimsCache,
    table: c_int,
) !keywork.Widget {
    const options = try lua_codec.decode(Options, lua_state, table, allocator);

    c.lua_getfield(lua_state, table, "pixels");
    defer pop(lua_state, 1);
    const has_pixels = !c.lua_isnil(lua_state, -1);
    if ((options.path != null) == has_pixels) return error.InvalidImageSource;
    if (options.path) |path| return fileImage(allocator, dims_cache, path, options);

    if (options.width == 0 or options.height == 0) return error.InvalidImageSize;
    if (options.width > max_image_dim or options.height > max_image_dim) return error.InvalidImageSize;
    if (@as(u64, options.width) * options.height > max_image_pixels) return error.InvalidImageSize;
    if (!std.mem.eql(u8, options.format, "argb32")) return error.UnsupportedImageFormat;

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
        .fit = options.fit,
        .alignment = options.@"align",
        .cache = options.cache,
        .cache_key = hasher.final(),
    };
    return image.widget();
}

/// File-backed image that defers pixel decoding to paint time. Widget parsing
/// happens on every rebuild, so only the header is read here for intrinsic
/// dimensions. Paint decodes once per file revision and target geometry.
const FileImage = struct {
    path: []const u8,
    width: f32,
    height: f32,
    source_width: u32,
    source_height: u32,
    fit: Fit,
    alignment: Alignment,
    cache: Cache,
    source_key: u64,

    const vtable: keywork.Widget.RenderObject.VTable = .{
        .layout = layout,
        .paint = paint,
    };

    fn widget(self: *FileImage) keywork.Widget {
        return .{ .render_object = .{
            .ptr = self,
            .vtable = &vtable,
            .clone_fn = clone,
            .destroy_fn = destroy,
        } };
    }

    fn layout(ptr: *const anyopaque, context: keywork.Widget.RenderObject.LayoutContext) !keywork.Size {
        const self: *const FileImage = @ptrCast(@alignCast(ptr));
        return .{
            .width = @min(self.width, context.constraints.max_width),
            .height = @min(self.height, context.constraints.max_height),
        };
    }

    fn paint(ptr: *const anyopaque, context: keywork.Widget.RenderObject.PaintContext) !void {
        const self: *const FileImage = @ptrCast(@alignCast(ptr));
        if (context.rect.width <= 0 or context.rect.height <= 0) return;

        const geometry = fittedGeometry(
            context.rect,
            self.source_width,
            self.source_height,
            self.fit,
            self.alignment,
        );
        if (geometry.rect.width <= 0 or geometry.rect.height <= 0) return;

        const render_scale = if (std.math.isFinite(context.scale) and context.scale > 0) context.scale else 1;
        const target_width: u32 = @max(1, @as(u32, @intFromFloat(@ceil(geometry.rect.width * render_scale))));
        const target_height: u32 = @max(1, @as(u32, @intFromFloat(@ceil(geometry.rect.height * render_scale))));

        const cache_key = geometryCacheKey(self.source_key, target_width, target_height, geometry.source);
        if (self.cache == .auto and try paintCached(context, geometry.rect, target_width, target_height, cache_key)) return;

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
            if (self.cache == .frame) return;
            return paintTombstone(context, geometry.rect, target_width, target_height, cache_key);
        };
        defer image_c.stbi_image_free(source_bytes);
        const dims = checkedDims(source_width, source_height) catch {
            log.warn("image rejected ({d}x{d}): {s}", .{ source_width, source_height, self.path });
            if (self.cache == .frame) return;
            return paintTombstone(context, geometry.rect, target_width, target_height, cache_key);
        };

        const pixel_count = @as(usize, dims.width) * dims.height;
        const pixel_allocator = imagePixelAllocator(self.cache, context.allocator);
        const pixels = try resampledRgbaPixels(
            pixel_allocator,
            source_bytes[0 .. pixel_count * 4],
            dims.width,
            dims.height,
            target_width,
            target_height,
            geometry.source,
        );
        const rendered = try retainPixels(context, self.cache, pixel_allocator, cache_key, target_width, target_height, pixels);
        try paintColorImage(context, geometry.rect, target_width, target_height, rendered, cache_key);
    }

    fn clone(allocator: std.mem.Allocator, ptr: *const anyopaque) !*anyopaque {
        const self: *const FileImage = @ptrCast(@alignCast(ptr));
        const result = try allocator.create(FileImage);
        errdefer allocator.destroy(result);
        result.* = self.*;
        result.path = try allocator.dupe(u8, self.path);
        return result;
    }

    fn destroy(allocator: std.mem.Allocator, ptr: *const anyopaque) void {
        const self: *FileImage = @ptrCast(@alignCast(@constCast(ptr)));
        allocator.free(self.path);
        allocator.destroy(self);
    }
};

const SourceRect = struct {
    x: f64 = 0,
    y: f64 = 0,
    width: f64 = 1,
    height: f64 = 1,
};

const FittedGeometry = struct {
    rect: keywork.Rect,
    source: SourceRect = .{},
};

fn geometryCacheKey(seed: u64, width: u32, height: u32, source: SourceRect) u64 {
    var hasher = std.hash.Wyhash.init(seed);
    hasher.update(std.mem.asBytes(&width));
    hasher.update(std.mem.asBytes(&height));
    hasher.update(std.mem.asBytes(&source.x));
    hasher.update(std.mem.asBytes(&source.y));
    hasher.update(std.mem.asBytes(&source.width));
    hasher.update(std.mem.asBytes(&source.height));
    return hasher.final();
}

fn paintCached(context: keywork.Widget.RenderObject.PaintContext, rect: keywork.Rect, width: u32, height: u32, cache_key: u64) !bool {
    const cached = context.raster_cache.cachedColorImage(cache_key, width, height) orelse return false;
    try paintColorImage(context, rect, width, height, cached, cache_key);
    return true;
}

fn paintColorImage(context: keywork.Widget.RenderObject.PaintContext, rect: keywork.Rect, width: u32, height: u32, pixels: []const keywork.Color, cache_key: u64) !void {
    try context.display_list.colorImage(context.allocator, rect, width, height, pixels, cache_key);
}

fn imagePixelAllocator(cache: Cache, retained_allocator: std.mem.Allocator) std.mem.Allocator {
    return switch (cache) {
        .auto => retained_allocator,
        // Large one-frame rasters should return their pages after present
        // instead of permanently raising the app-session allocator's RSS.
        .frame => std.heap.page_allocator,
    };
}

fn retainPixels(
    context: keywork.Widget.RenderObject.PaintContext,
    cache: Cache,
    pixel_allocator: std.mem.Allocator,
    cache_key: u64,
    width: u32,
    height: u32,
    pixels: []keywork.Color,
) ![]const keywork.Color {
    return switch (cache) {
        .auto => try context.raster_cache.insertColor(context.allocator, cache_key, width, height, pixels),
        .frame => try context.raster_cache.insertFrameColor(context.allocator, pixel_allocator, pixels),
    };
}

fn fittedGeometry(rect: keywork.Rect, source_width: u32, source_height: u32, fit: Fit, alignment: Alignment) FittedGeometry {
    const width: f32 = @floatFromInt(source_width);
    const height: f32 = @floatFromInt(source_height);
    const horizontal = alignment.horizontal();
    const vertical = alignment.vertical();

    return switch (fit) {
        .fill => .{ .rect = rect },
        .contain => blk: {
            const scale = @min(rect.width / width, rect.height / height);
            const fitted_width = width * scale;
            const fitted_height = height * scale;
            break :blk .{ .rect = .{
                .x = rect.x + (rect.width - fitted_width) * horizontal,
                .y = rect.y + (rect.height - fitted_height) * vertical,
                .width = fitted_width,
                .height = fitted_height,
            } };
        },
        .cover => blk: {
            const source_aspect = width / height;
            const target_aspect = rect.width / rect.height;
            var source: SourceRect = .{};
            if (source_aspect > target_aspect) {
                source.width = target_aspect / source_aspect;
                source.x = (1 - source.width) * horizontal;
            } else if (source_aspect < target_aspect) {
                source.height = source_aspect / target_aspect;
                source.y = (1 - source.height) * vertical;
            }
            break :blk .{ .rect = rect, .source = source };
        },
        .none => blk: {
            const fitted_width = @min(width, rect.width);
            const fitted_height = @min(height, rect.height);
            break :blk .{
                .rect = .{
                    .x = rect.x + (rect.width - fitted_width) * horizontal,
                    .y = rect.y + (rect.height - fitted_height) * vertical,
                    .width = fitted_width,
                    .height = fitted_height,
                },
                .source = .{
                    .x = @as(f64, @floatCast((width - fitted_width) * horizontal / width)),
                    .y = @as(f64, @floatCast((height - fitted_height) * vertical / height)),
                    .width = @as(f64, @floatCast(fitted_width / width)),
                    .height = @as(f64, @floatCast(fitted_height / height)),
                },
            };
        },
    };
}

/// Caches a fully transparent image under the icon's key so later paints
/// hit the cache instead of reopening the broken file; the backends skip
/// zero-alpha pixels, so it draws nothing.
fn paintTombstone(
    context: keywork.Widget.RenderObject.PaintContext,
    rect: keywork.Rect,
    width: u32,
    height: u32,
    cache_key: u64,
) !void {
    const pixels = try context.allocator.alloc(keywork.Color, @as(usize, width) * height);
    @memset(pixels, keywork.colors.transparent);
    const cached = try context.raster_cache.insertColor(context.allocator, cache_key, width, height, pixels);
    try paintColorImage(context, rect, width, height, cached, cache_key);
}

/// Caches intrinsic image dimensions per path and file fingerprint so widget
/// rebuilds avoid repeated header reads without hiding same-path replacements.
pub const DimsCache = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMapUnmanaged(Entry) = .empty,

    pub const Dims = struct { width: u32, height: u32 };
    const Entry = struct {
        fingerprint: u64,
        dims: ?Dims,
    };

    pub fn init(allocator: std.mem.Allocator) DimsCache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DimsCache) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.entries.deinit(self.allocator);
    }

    fn lookup(self: *DimsCache, path: []const u8, fingerprint: ?u64) !?Dims {
        if (self.entries.getPtr(path)) |entry| {
            const changed_fingerprint = fingerprint orelse return entry.dims;
            if (entry.fingerprint == changed_fingerprint) return entry.dims;
            entry.* = .{
                .fingerprint = changed_fingerprint,
                .dims = try cachedProbe(self.allocator, path),
            };
            return entry.dims;
        }

        const dims = try cachedProbe(self.allocator, path);
        const key = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(key);
        try self.entries.put(self.allocator, key, .{ .fingerprint = fingerprint orelse 0, .dims = dims });
        return dims;
    }

    fn cachedProbe(allocator: std.mem.Allocator, path: []const u8) !?Dims {
        const dims: ?Dims = probeDims(allocator, path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
        if (dims == null) log.warn("unreadable image: {s}", .{path});
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

fn fileImage(allocator: std.mem.Allocator, dims_cache: ?*DimsCache, path: []const u8, options: Options) !keywork.Widget {
    if (path.len == 0) return error.InvalidImage;
    if (options.size) |size| {
        if (!std.math.isFinite(size) or size <= 0) return error.InvalidImageSize;
    }

    const revision = try imageRevision(options.revision);
    const fingerprint = try fileFingerprint(allocator, path);
    var revision_hasher = std.hash.Wyhash.init(fingerprint);
    revision_hasher.update(std.mem.asBytes(&revision));
    const dims = if (dims_cache) |cache|
        (try cache.lookup(path, revision_hasher.final())) orelse return error.InvalidImage
    else
        try probeDims(allocator, path);
    const preferred = preferredImageSize(dims, options);
    return createFileImage(
        allocator,
        path,
        dims,
        preferred,
        options.fit,
        options.@"align",
        options.cache,
        fingerprint,
        revision,
    );
}

pub fn pngIcon(allocator: std.mem.Allocator, dims_cache: ?*DimsCache, path: []const u8, size: f32) !keywork.Widget {
    // Only the header is read for the intrinsic dimensions; the pixels
    // are decoded lazily at paint.
    const dims = if (dims_cache) |cache|
        (try cache.lookup(path, null)) orelse return error.InvalidImage
    else
        try probeDims(allocator, path);

    const longest: f32 = @floatFromInt(@max(dims.width, dims.height));
    const logical_size: f32 = @floatFromInt(positiveImageSize(size));
    const preferred: keywork.Size = .{
        .width = logical_size * @as(f32, @floatFromInt(dims.width)) / longest,
        .height = logical_size * @as(f32, @floatFromInt(dims.height)) / longest,
    };
    return createFileImage(allocator, path, dims, preferred, .contain, .center, .auto, 0, 0);
}

fn createFileImage(
    allocator: std.mem.Allocator,
    path: []const u8,
    dims: DimsCache.Dims,
    preferred: keywork.Size,
    fit: Fit,
    alignment: Alignment,
    cache: Cache,
    fingerprint: u64,
    revision: u64,
) !keywork.Widget {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(path);
    hasher.update(std.mem.asBytes(&fingerprint));
    hasher.update(std.mem.asBytes(&revision));
    hasher.update(std.mem.asBytes(&dims.width));
    hasher.update(std.mem.asBytes(&dims.height));
    const fit_value: u8 = @intFromEnum(fit);
    const alignment_value: u8 = @intFromEnum(alignment);
    hasher.update(std.mem.asBytes(&fit_value));
    hasher.update(std.mem.asBytes(&alignment_value));

    const image = try allocator.create(FileImage);
    errdefer allocator.destroy(image);
    image.* = .{
        .path = try allocator.dupe(u8, path),
        .width = preferred.width,
        .height = preferred.height,
        .source_width = dims.width,
        .source_height = dims.height,
        .fit = fit,
        .alignment = alignment,
        .cache = cache,
        .source_key = hasher.final(),
    };
    return image.widget();
}

fn preferredImageSize(dims: DimsCache.Dims, options: Options) keywork.Size {
    const source_width: f32 = @floatFromInt(dims.width);
    const source_height: f32 = @floatFromInt(dims.height);
    if (options.width > 0 and options.height > 0) return .{
        .width = @floatFromInt(options.width),
        .height = @floatFromInt(options.height),
    };
    if (options.width > 0) {
        const width: f32 = @floatFromInt(options.width);
        return .{ .width = width, .height = width * source_height / source_width };
    }
    if (options.height > 0) {
        const height: f32 = @floatFromInt(options.height);
        return .{ .width = height * source_width / source_height, .height = height };
    }
    if (options.size) |size| {
        const longest = @max(source_width, source_height);
        return .{ .width = size * source_width / longest, .height = size * source_height / longest };
    }
    return .{ .width = source_width, .height = source_height };
}

fn imageRevision(value: f64) !u64 {
    const max_exact_integer: f64 = 9007199254740991;
    if (!std.math.isFinite(value) or value < 0 or value > max_exact_integer or value != @floor(value)) return error.InvalidImageRevision;
    return @intFromFloat(value);
}

fn fileFingerprint(allocator: std.mem.Allocator, path: []const u8) !u64 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const linux = std.os.linux;
    var stat = std.mem.zeroes(linux.Statx);
    while (true) {
        switch (linux.errno(linux.statx(
            linux.AT.FDCWD,
            path_z.ptr,
            linux.AT.NO_AUTOMOUNT,
            .{ .INO = true, .SIZE = true, .MTIME = true, .CTIME = true },
            &stat,
        ))) {
            .SUCCESS => break,
            .INTR => continue,
            else => return error.ImageStatFailed,
        }
    }

    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&stat.dev_major));
    hasher.update(std.mem.asBytes(&stat.dev_minor));
    hasher.update(std.mem.asBytes(&stat.ino));
    hasher.update(std.mem.asBytes(&stat.size));
    hasher.update(std.mem.asBytes(&stat.mtime.sec));
    hasher.update(std.mem.asBytes(&stat.mtime.nsec));
    hasher.update(std.mem.asBytes(&stat.ctime.sec));
    hasher.update(std.mem.asBytes(&stat.ctime.nsec));
    return hasher.final();
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
    source_rect: SourceRect,
) ![]keywork.Color {
    const full_source = source_rect.x == 0 and source_rect.y == 0 and source_rect.width == 1 and source_rect.height == 1;
    if (full_source and source_width == target_width and source_height == target_height) return allocator.dupe(keywork.Color, source);

    const pixels = try allocator.alloc(keywork.Color, @as(usize, target_width) * target_height);
    errdefer allocator.free(pixels);
    const source_bytes = std.mem.sliceAsBytes(source);
    const target_bytes = std.mem.sliceAsBytes(pixels);
    if (full_source) {
        if (image_c.stbir_resize_uint8_linear(
            source_bytes.ptr,
            @intCast(source_width),
            @intCast(source_height),
            0,
            target_bytes.ptr,
            @intCast(target_width),
            @intCast(target_height),
            0,
            image_c.STBIR_BGRA_NO_AW,
        ) == null) return error.ImageResizeFailed;
    } else {
        var resize: image_c.STBIR_RESIZE = undefined;
        image_c.stbir_resize_init(
            &resize,
            source_bytes.ptr,
            @intCast(source_width),
            @intCast(source_height),
            0,
            target_bytes.ptr,
            @intCast(target_width),
            @intCast(target_height),
            0,
            image_c.STBIR_BGRA_NO_AW,
            image_c.STBIR_TYPE_UINT8,
        );
        if (image_c.stbir_set_input_subrect(
            &resize,
            source_rect.x,
            source_rect.y,
            source_rect.x + source_rect.width,
            source_rect.y + source_rect.height,
        ) == 0) return error.ImageResizeFailed;
        if (image_c.stbir_resize_extended(&resize) == 0) return error.ImageResizeFailed;
    }
    return pixels;
}

fn resampledRgbaPixels(
    allocator: std.mem.Allocator,
    source_bytes: []const u8,
    source_width: u32,
    source_height: u32,
    target_width: u32,
    target_height: u32,
    source_rect: SourceRect,
) ![]keywork.Color {
    const pixels = try allocator.alloc(keywork.Color, @as(usize, target_width) * target_height);
    errdefer allocator.free(pixels);
    const full_source = source_rect.x == 0 and source_rect.y == 0 and source_rect.width == 1 and source_rect.height == 1;
    if (full_source and source_width == target_width and source_height == target_height) {
        fillRgbaPixels(pixels, source_bytes);
        return pixels;
    }

    const target_bytes = std.mem.sliceAsBytes(pixels);
    if (full_source) {
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
    } else {
        var resize: image_c.STBIR_RESIZE = undefined;
        image_c.stbir_resize_init(
            &resize,
            source_bytes.ptr,
            @intCast(source_width),
            @intCast(source_height),
            0,
            target_bytes.ptr,
            @intCast(target_width),
            @intCast(target_height),
            0,
            image_c.STBIR_RGBA_NO_AW,
            image_c.STBIR_TYPE_UINT8,
        );
        if (image_c.stbir_set_input_subrect(
            &resize,
            source_rect.x,
            source_rect.y,
            source_rect.x + source_rect.width,
            source_rect.y + source_rect.height,
        ) == 0) return error.ImageResizeFailed;
        if (image_c.stbir_resize_extended(&resize) == 0) return error.ImageResizeFailed;
    }

    // stb wrote RGBA bytes into the framework's little-endian BGRA Color
    // storage. Swap red and blue in place instead of allocating another
    // full-size conversion buffer.
    for (0..pixels.len) |index| {
        const base = index * 4;
        std.mem.swap(u8, &target_bytes[base], &target_bytes[base + 2]);
    }
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

test "fitted geometry implements fill cover contain and none" {
    const rect: keywork.Rect = .{ .x = 10, .y = 20, .width = 100, .height = 100 };

    const fill = fittedGeometry(rect, 200, 100, .fill, .center);
    try std.testing.expectEqual(rect, fill.rect);
    try std.testing.expectEqual(SourceRect{}, fill.source);

    const contain = fittedGeometry(rect, 200, 100, .contain, .center);
    try std.testing.expectApproxEqAbs(@as(f32, 10), contain.rect.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 45), contain.rect.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 100), contain.rect.width, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 50), contain.rect.height, 0.001);

    const cover = fittedGeometry(rect, 200, 100, .cover, .center);
    try std.testing.expectEqual(rect, cover.rect);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), cover.source.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), cover.source.width, 0.0001);
    const left_cover = fittedGeometry(rect, 200, 100, .cover, .top_left);
    try std.testing.expectApproxEqAbs(@as(f64, 0), left_cover.source.x, 0.0001);

    const none = fittedGeometry(rect, 50, 25, .none, .bottom_right);
    try std.testing.expectApproxEqAbs(@as(f32, 60), none.rect.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 95), none.rect.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 50), none.rect.width, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 25), none.rect.height, 0.001);
}

test "cropped image resampling selects the fitted source region" {
    const red = keywork.Color.argb(255, 255, 0, 0);
    const blue = keywork.Color.argb(255, 0, 0, 255);
    const source = [_]keywork.Color{
        red, red, blue, blue,
        red, red, blue, blue,
    };
    const pixels = try resampledPixels(std.testing.allocator, &source, 4, 2, 2, 2, .{ .x = 0.5, .width = 0.5 });
    defer std.testing.allocator.free(pixels);
    try std.testing.expectEqual(@as(usize, 4), pixels.len);
    for (pixels) |pixel| try std.testing.expectEqual(blue, pixel);
}

test "image options decode fit alignment cache and revision" {
    const lua_state = c.luaL_newstate() orelse return error.OutOfMemory;
    defer c.lua_close(lua_state);

    c.lua_newtable(lua_state);
    const table = c.lua_gettop(lua_state);
    lua_value.setStringField(lua_state, table, "path", "/tmp/wallpaper.png");
    lua_value.setStringField(lua_state, table, "fit", "cover");
    lua_value.setStringField(lua_state, table, "align", "bottom_right");
    lua_value.setStringField(lua_state, table, "cache", "frame");
    lua_value.setIntegerField(lua_state, table, "revision", 7);

    const options = try lua_codec.decode(Options, lua_state, table, std.testing.allocator);
    try std.testing.expectEqual(Fit.cover, options.fit);
    try std.testing.expectEqual(Alignment.bottom_right, options.@"align");
    try std.testing.expectEqual(Cache.frame, options.cache);
    try std.testing.expectEqual(@as(u64, 7), try imageRevision(options.revision));
    try std.testing.expectError(error.InvalidImageRevision, imageRevision(-1));
    try std.testing.expectError(error.InvalidImageRevision, imageRevision(1.5));
    try std.testing.expectError(error.InvalidImageRevision, imageRevision(std.math.inf(f64)));
    try std.testing.expectEqual(table, c.lua_gettop(lua_state));
}

test "image requires exactly one source" {
    const lua_state = c.luaL_newstate() orelse return error.OutOfMemory;
    defer c.lua_close(lua_state);

    c.lua_newtable(lua_state);
    const table = c.lua_gettop(lua_state);
    try std.testing.expectError(error.InvalidImageSource, parse(lua_state, std.testing.allocator, null, table));

    lua_value.setStringField(lua_state, table, "path", "/tmp/wallpaper.png");
    lua_value.setStringField(lua_state, table, "pixels", "argb");
    try std.testing.expectError(error.InvalidImageSource, parse(lua_state, std.testing.allocator, null, table));
    try std.testing.expectEqual(table, c.lua_gettop(lua_state));
}

test "file image parses and decodes lazily into fitted paint" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "wallpaper.png" });
    defer allocator.free(path);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const red = [_]u8{ 255, 0, 0, 255 };
    const blue = [_]u8{ 0, 0, 255, 255 };
    const rgba = red ++ red ++ blue ++ blue ++ red ++ red ++ blue ++ blue;
    try std.testing.expect(image_c.stbi_write_png(path_z.ptr, 4, 2, 4, &rgba, 16) != 0);

    const lua_state = c.luaL_newstate() orelse return error.OutOfMemory;
    defer c.lua_close(lua_state);
    c.lua_newtable(lua_state);
    const table = c.lua_gettop(lua_state);
    lua_value.setStringField(lua_state, table, "path", path);
    lua_value.setStringField(lua_state, table, "fit", "cover");

    var dims_cache: DimsCache = .init(allocator);
    defer dims_cache.deinit();
    const widget = try parse(lua_state, allocator, &dims_cache, table);
    const render_object = switch (widget) {
        .render_object => |value| value,
        else => return error.ExpectedRenderObject,
    };
    defer render_object.destroy(allocator);

    var display_list: keywork.DisplayList = .{};
    defer display_list.deinit(allocator);
    var raster_cache = keywork.RasterCache.init(1024);
    raster_cache.beginFrame();
    defer {
        raster_cache.endFrame(allocator);
        raster_cache.deinit(allocator);
    }
    try render_object.paint(.{
        .allocator = allocator,
        .rect = .{ .x = 0, .y = 0, .width = 2, .height = 2 },
        .scale = 1,
        .display_list = &display_list,
        .raster_cache = &raster_cache,
    });

    try std.testing.expectEqual(@as(usize, 1), display_list.commands.items.len);
    const painted = switch (display_list.commands.items[0]) {
        .color_image => |value| value,
        else => return error.ExpectedColorImage,
    };
    try std.testing.expectEqual(@as(u32, 2), painted.width);
    try std.testing.expectEqual(@as(u32, 2), painted.height);
    try std.testing.expectEqual(@as(usize, 4), painted.pixels.len);

    // Replacing the file at the same path must invalidate both dimensions
    // and raster identity on the next widget rebuild.
    const replacement_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "replacement.png" });
    defer allocator.free(replacement_path);
    const replacement_path_z = try allocator.dupeZ(u8, replacement_path);
    defer allocator.free(replacement_path_z);
    const green = [_]u8{ 0, 255, 0, 255 };
    const replacement_rgba = green ** 8;
    try std.testing.expect(image_c.stbi_write_png(replacement_path_z.ptr, 2, 4, 4, &replacement_rgba, 8) != 0);
    try std.Io.Dir.rename(.cwd(), replacement_path, .cwd(), path, std.testing.io);

    const replacement_widget = try parse(lua_state, allocator, &dims_cache, table);
    const replacement_render_object = switch (replacement_widget) {
        .render_object => |value| value,
        else => return error.ExpectedRenderObject,
    };
    defer replacement_render_object.destroy(allocator);
    const replacement_size = try replacement_render_object.layout(.{
        .constraints = .{ .max_width = std.math.inf(f32), .max_height = std.math.inf(f32) },
        .measurer = .fixed,
    });
    try std.testing.expectEqual(@as(f32, 2), replacement_size.width);
    try std.testing.expectEqual(@as(f32, 4), replacement_size.height);
}

test "dims cache tombstones unreadable files" {
    // The first probe failure per path logs a warning by design.
    std.testing.log_level = .err;
    var cache: DimsCache = .init(std.testing.allocator);
    defer cache.deinit();

    try std.testing.expect(try cache.lookup("/nonexistent/keywork-test.png", 1) == null);
    try std.testing.expectEqual(@as(usize, 1), cache.entries.count());
    // The tombstone answers without a second probe or a new entry.
    try std.testing.expect(try cache.lookup("/nonexistent/keywork-test.png", 1) == null);
    try std.testing.expectEqual(@as(usize, 1), cache.entries.count());
    // A changed fingerprint retries the probe without leaking another key.
    try std.testing.expect(try cache.lookup("/nonexistent/keywork-test.png", 2) == null);
    try std.testing.expectEqual(@as(u64, 2), cache.entries.get("/nonexistent/keywork-test.png").?.fingerprint);
    try std.testing.expectEqual(@as(usize, 1), cache.entries.count());
}
