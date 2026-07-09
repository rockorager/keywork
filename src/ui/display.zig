//! Display-list and rendering-backend abstractions.

const std = @import("std");
const types = @import("types.zig");

const Color = types.Color;
const Point = types.Point;
const Rect = types.Rect;
const ResolvedTextStyle = types.ResolvedTextStyle;
const Size = types.Size;

pub const PaintCommand = union(enum) {
    fill_rect: FillRect,
    text: TextRun,
    alpha_image: AlphaImage,
    color_image: ColorImage,
    /// Clips subsequent commands to the given rect (logical coordinates)
    /// until the next set_clip; null removes clipping. The rect is already
    /// resolved against enclosing clips, so backends need no stack.
    set_clip: ?Rect,

    pub const FillRect = struct {
        rect: Rect,
        color: Color,
    };

    pub const TextRun = struct {
        origin: Point,
        value: []const u8,
        style: ResolvedTextStyle,
    };

    pub const AlphaImage = struct {
        rect: Rect,
        width: u32,
        height: u32,
        alpha: []const u8,
        color: Color,
        cache_key: u64,
    };

    /// Full-color image with straight (non-premultiplied) alpha, pixels in
    /// the framework's ARGB Color layout.
    pub const ColorImage = struct {
        rect: Rect,
        width: u32,
        height: u32,
        pixels: []const Color,
        cache_key: u64,
    };
};

pub const DisplayList = struct {
    commands: std.ArrayList(PaintCommand) = .empty,
    alpha_cache: std.AutoHashMapUnmanaged(u64, AlphaCacheEntry) = .empty,
    color_cache: std.AutoHashMapUnmanaged(u64, ColorCacheEntry) = .empty,
    clip_stack: std.ArrayList(Rect) = .empty,

    const AlphaCacheEntry = struct {
        width: u32,
        height: u32,
        alpha: []u8,
    };

    const ColorCacheEntry = struct {
        width: u32,
        height: u32,
        pixels: []Color,
    };

    pub fn deinit(self: *DisplayList, allocator: std.mem.Allocator) void {
        self.commands.deinit(allocator);
        self.clearAlphaCache(allocator);
        self.alpha_cache.deinit(allocator);
        self.clearColorCache(allocator);
        self.color_cache.deinit(allocator);
        self.clip_stack.deinit(allocator);
    }

    fn clearColorCache(self: *DisplayList, allocator: std.mem.Allocator) void {
        var values = self.color_cache.valueIterator();
        while (values.next()) |entry| allocator.free(entry.pixels);
        self.color_cache.clearRetainingCapacity();
    }

    pub fn cachedColorImage(self: *const DisplayList, cache_key: u64, width: u32, height: u32) ?[]const Color {
        const entry = self.color_cache.get(cache_key) orelse return null;
        if (entry.width != width or entry.height != height) return null;
        return entry.pixels;
    }

    /// Appends a color image command, taking ownership of pixels into the
    /// cache keyed by cache_key (mirroring alphaImage's contract).
    pub fn colorImage(
        self: *DisplayList,
        allocator: std.mem.Allocator,
        rect: Rect,
        width: u32,
        height: u32,
        pixels: []Color,
        cache_key: u64,
    ) !void {
        var pixels_owned = true;
        errdefer if (pixels_owned) allocator.free(pixels);
        const result = try self.color_cache.getOrPut(allocator, cache_key);
        const cached_pixels = if (result.found_existing) blk: {
            if (result.value_ptr.width == width and result.value_ptr.height == height) {
                if (pixels.ptr != result.value_ptr.pixels.ptr) allocator.free(pixels);
                pixels_owned = false;
                break :blk result.value_ptr.pixels;
            }
            allocator.free(result.value_ptr.pixels);
            result.value_ptr.* = .{ .width = width, .height = height, .pixels = pixels };
            pixels_owned = false;
            break :blk pixels;
        } else blk: {
            result.value_ptr.* = .{ .width = width, .height = height, .pixels = pixels };
            pixels_owned = false;
            break :blk pixels;
        };
        try self.commands.append(allocator, .{ .color_image = .{
            .rect = rect,
            .width = width,
            .height = height,
            .pixels = cached_pixels,
            .cache_key = cache_key,
        } });
    }

    pub fn clearRetainingCapacity(self: *DisplayList, _: std.mem.Allocator) void {
        self.commands.clearRetainingCapacity();
        self.clip_stack.clearRetainingCapacity();
    }

    /// Clips subsequent commands to rect intersected with any enclosing
    /// clips. Every pushClip must be matched by a popClip.
    pub fn pushClip(self: *DisplayList, allocator: std.mem.Allocator, rect: Rect) !void {
        const resolved = if (self.clip_stack.items.len > 0)
            self.clip_stack.items[self.clip_stack.items.len - 1].intersect(rect)
        else
            rect;
        try self.clip_stack.append(allocator, resolved);
        try self.commands.append(allocator, .{ .set_clip = resolved });
    }

    pub fn popClip(self: *DisplayList, allocator: std.mem.Allocator) !void {
        std.debug.assert(self.clip_stack.items.len > 0);
        _ = self.clip_stack.pop();
        const restored: ?Rect = if (self.clip_stack.items.len > 0)
            self.clip_stack.items[self.clip_stack.items.len - 1]
        else
            null;
        try self.commands.append(allocator, .{ .set_clip = restored });
    }

    fn clearAlphaCache(self: *DisplayList, allocator: std.mem.Allocator) void {
        var values = self.alpha_cache.valueIterator();
        while (values.next()) |entry| allocator.free(entry.alpha);
        self.alpha_cache.clearRetainingCapacity();
    }

    pub fn cachedAlphaImage(self: *const DisplayList, cache_key: u64, width: u32, height: u32) ?[]const u8 {
        const entry = self.alpha_cache.get(cache_key) orelse return null;
        if (entry.width != width or entry.height != height) return null;
        return entry.alpha;
    }

    pub fn fillRect(self: *DisplayList, allocator: std.mem.Allocator, rect: Rect, color: Color) !void {
        try self.commands.append(allocator, .{ .fill_rect = .{ .rect = rect, .color = color } });
    }

    pub fn text(self: *DisplayList, allocator: std.mem.Allocator, origin: Point, value: []const u8, style: ResolvedTextStyle) !void {
        try self.commands.append(allocator, .{ .text = .{ .origin = origin, .value = value, .style = style } });
    }

    pub fn alphaImage(
        self: *DisplayList,
        allocator: std.mem.Allocator,
        rect: Rect,
        width: u32,
        height: u32,
        alpha: []u8,
        color: Color,
        cache_key: u64,
    ) !void {
        var alpha_owned = true;
        errdefer if (alpha_owned) allocator.free(alpha);
        const result = try self.alpha_cache.getOrPut(allocator, cache_key);
        const cached_alpha = if (result.found_existing) blk: {
            if (result.value_ptr.width == width and result.value_ptr.height == height) {
                if (alpha.ptr != result.value_ptr.alpha.ptr) allocator.free(alpha);
                alpha_owned = false;
                break :blk result.value_ptr.alpha;
            }
            allocator.free(result.value_ptr.alpha);
            result.value_ptr.* = .{ .width = width, .height = height, .alpha = alpha };
            alpha_owned = false;
            break :blk alpha;
        } else blk: {
            result.value_ptr.* = .{ .width = width, .height = height, .alpha = alpha };
            alpha_owned = false;
            break :blk alpha;
        };
        try self.commands.append(allocator, .{ .alpha_image = .{
            .rect = rect,
            .width = width,
            .height = height,
            .alpha = cached_alpha,
            .color = color,
            .cache_key = cache_key,
        } });
    }
};

pub const RenderBackend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        present: *const fn (ptr: *anyopaque, frame: Frame) anyerror!bool,
        measure_text: *const fn (ptr: *anyopaque, value: []const u8, style: ResolvedTextStyle) anyerror!Size,
        scale: *const fn (ptr: *anyopaque) f32,
        /// Optional; backends without real font metrics fall back to the
        /// fixed approximation.
        text_metrics: ?*const fn (ptr: *anyopaque, font_size: f32) anyerror!TextMetrics = null,
    };

    pub const Frame = struct {
        size: Size,
        scale: f32,
        damage: []const Rect,
        display_list: []const PaintCommand,
    };

    pub fn present(self: RenderBackend, frame: Frame) !bool {
        return self.vtable.present(self.ptr, frame);
    }

    pub fn measureText(self: RenderBackend, value: []const u8, style: ResolvedTextStyle) !Size {
        return self.vtable.measure_text(self.ptr, value, style);
    }

    pub fn textMetrics(self: RenderBackend, font_size: f32) !TextMetrics {
        const text_metrics = self.vtable.text_metrics orelse return fixedTextMetrics(font_size);
        return text_metrics(self.ptr, font_size);
    }

    pub fn scale(self: RenderBackend) f32 {
        return self.vtable.scale(self.ptr);
    }
};

pub const TextMeasurer = union(enum) {
    fixed,
    backend: RenderBackend,

    pub fn measureText(self: TextMeasurer, value: []const u8, style: ResolvedTextStyle) !Size {
        return switch (self) {
            .fixed => fixedMeasureText(value, style),
            .backend => |backend| backend.measureText(value, style),
        };
    }

    pub fn textMetrics(self: TextMeasurer, font_size: f32) !TextMetrics {
        return switch (self) {
            .fixed => fixedTextMetrics(font_size),
            .backend => |backend| backend.textMetrics(font_size),
        };
    }
};

/// Vertical font metrics in logical units, mirroring how text paints:
/// glyphs sit at box top + ascender, all leading below the baseline.
pub const TextMetrics = struct {
    ascender: f32,
    cap_height: f32,
    line_height: f32,
};

pub fn fixedTextMetrics(font_size: f32) TextMetrics {
    // Matches fixedMeasureText's line height; ascender and cap height
    // use common sans-serif ratios.
    return .{
        .ascender = 0.8 * font_size,
        .cap_height = 0.7 * font_size,
        .line_height = font_size,
    };
}

pub const text_width_ratio = 0.5;

pub fn fixedMeasureText(value: []const u8, style: ResolvedTextStyle) Size {
    return .{ .width = @as(f32, @floatFromInt(value.len)) * style.font_size * text_width_ratio, .height = style.font_size };
}
