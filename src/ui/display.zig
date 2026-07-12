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

/// App-session cache for reusable CPU-rasterized images. Display-list image
/// commands borrow these pixels for one synchronous present. Eviction is
/// deferred from beginFrame until endFrame so building a frame can exceed the
/// limit without invalidating commands already appended to that frame.
pub const RasterCache = struct {
    pub const default_byte_limit = 64 * 1024 * 1024;

    alpha: std.AutoHashMapUnmanaged(u64, AlphaEntry) = .empty,
    color: std.AutoHashMapUnmanaged(u64, ColorEntry) = .empty,
    byte_limit: usize = default_byte_limit,
    byte_usage: usize = 0,
    clock: u64 = 0,
    in_frame: bool = false,

    const AlphaEntry = struct {
        width: u32,
        height: u32,
        alpha: []u8,
        used: u64,
    };

    const ColorEntry = struct {
        width: u32,
        height: u32,
        pixels: []Color,
        used: u64,
    };

    pub fn init(byte_limit: usize) RasterCache {
        return .{ .byte_limit = byte_limit };
    }

    pub fn deinit(self: *RasterCache, allocator: std.mem.Allocator) void {
        std.debug.assert(!self.in_frame);
        var alpha_values = self.alpha.valueIterator();
        while (alpha_values.next()) |entry| allocator.free(entry.alpha);
        self.alpha.deinit(allocator);
        var values = self.color.valueIterator();
        while (values.next()) |entry| allocator.free(entry.pixels);
        self.color.deinit(allocator);
        self.* = undefined;
    }

    pub fn beginFrame(self: *RasterCache) void {
        std.debug.assert(!self.in_frame);
        self.in_frame = true;
    }

    pub fn endFrame(self: *RasterCache, allocator: std.mem.Allocator) void {
        std.debug.assert(self.in_frame);
        self.trim(allocator);
        self.in_frame = false;
    }

    fn touch(self: *RasterCache) u64 {
        self.clock +%= 1;
        return self.clock;
    }

    pub fn cachedColorImage(self: *RasterCache, cache_key: u64, width: u32, height: u32) ?[]const Color {
        std.debug.assert(self.in_frame);
        const entry = self.color.getPtr(cache_key) orelse return null;
        if (entry.width != width or entry.height != height) return null;
        entry.used = self.touch();
        return entry.pixels;
    }

    pub fn insertColor(self: *RasterCache, allocator: std.mem.Allocator, cache_key: u64, width: u32, height: u32, pixels: []Color) ![]const Color {
        std.debug.assert(self.in_frame);
        var pixels_owned = true;
        var retained_new = true;
        errdefer if (pixels_owned) allocator.free(pixels);
        const result = try self.color.getOrPut(allocator, cache_key);
        const cached_pixels = if (result.found_existing) blk: {
            if (result.value_ptr.width == width and result.value_ptr.height == height) {
                if (pixels.ptr != result.value_ptr.pixels.ptr) allocator.free(pixels);
                pixels_owned = false;
                retained_new = false;
                result.value_ptr.used = self.touch();
                break :blk result.value_ptr.pixels;
            }
            self.byte_usage -= result.value_ptr.pixels.len * @sizeOf(Color);
            allocator.free(result.value_ptr.pixels);
            result.value_ptr.* = .{ .width = width, .height = height, .pixels = pixels, .used = self.touch() };
            pixels_owned = false;
            break :blk pixels;
        } else blk: {
            result.value_ptr.* = .{ .width = width, .height = height, .pixels = pixels, .used = self.touch() };
            pixels_owned = false;
            break :blk pixels;
        };
        if (retained_new) self.byte_usage += pixels.len * @sizeOf(Color);
        return cached_pixels;
    }

    pub fn cachedAlphaImage(self: *RasterCache, cache_key: u64, width: u32, height: u32) ?[]const u8 {
        std.debug.assert(self.in_frame);
        const entry = self.alpha.getPtr(cache_key) orelse return null;
        if (entry.width != width or entry.height != height) return null;
        entry.used = self.touch();
        return entry.alpha;
    }

    pub fn insertAlpha(self: *RasterCache, allocator: std.mem.Allocator, cache_key: u64, width: u32, height: u32, alpha: []u8) ![]const u8 {
        std.debug.assert(self.in_frame);
        var owned = true;
        errdefer if (owned) allocator.free(alpha);
        const result = try self.alpha.getOrPut(allocator, cache_key);
        if (result.found_existing and result.value_ptr.width == width and result.value_ptr.height == height) {
            if (alpha.ptr != result.value_ptr.alpha.ptr) allocator.free(alpha);
            owned = false;
            result.value_ptr.used = self.touch();
            return result.value_ptr.alpha;
        }
        if (result.found_existing) {
            self.byte_usage -= result.value_ptr.alpha.len;
            allocator.free(result.value_ptr.alpha);
        }
        result.value_ptr.* = .{ .width = width, .height = height, .alpha = alpha, .used = self.touch() };
        owned = false;
        self.byte_usage += alpha.len;
        return alpha;
    }

    fn trim(self: *RasterCache, allocator: std.mem.Allocator) void {
        while (self.byte_usage > self.byte_limit) {
            var oldest: u64 = std.math.maxInt(u64);
            var alpha_key: ?u64 = null;
            var color_key: ?u64 = null;
            var ai = self.alpha.iterator();
            while (ai.next()) |entry| if (entry.value_ptr.used < oldest) {
                oldest = entry.value_ptr.used;
                alpha_key = entry.key_ptr.*;
                color_key = null;
            };
            var ci = self.color.iterator();
            while (ci.next()) |entry| if (entry.value_ptr.used < oldest) {
                oldest = entry.value_ptr.used;
                color_key = entry.key_ptr.*;
                alpha_key = null;
            };
            if (alpha_key) |key| {
                const removed = self.alpha.fetchRemove(key).?;
                self.byte_usage -= removed.value.alpha.len;
                allocator.free(removed.value.alpha);
            } else if (color_key) |key| {
                const removed = self.color.fetchRemove(key).?;
                self.byte_usage -= removed.value.pixels.len * @sizeOf(Color);
                allocator.free(removed.value.pixels);
            } else return;
        }
    }
};

pub const DisplayList = struct {
    commands: std.ArrayList(PaintCommand) = .empty,
    clip_stack: std.ArrayList(Rect) = .empty,

    pub fn deinit(self: *DisplayList, allocator: std.mem.Allocator) void {
        self.commands.deinit(allocator);
        self.clip_stack.deinit(allocator);
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
        alpha: []const u8,
        color: Color,
        cache_key: u64,
    ) !void {
        try self.commands.append(allocator, .{ .alpha_image = .{
            .rect = rect,
            .width = width,
            .height = height,
            .alpha = alpha,
            .color = color,
            .cache_key = cache_key,
        } });
    }

    pub fn colorImage(self: *DisplayList, allocator: std.mem.Allocator, rect: Rect, width: u32, height: u32, pixels: []const Color, cache_key: u64) !void {
        try self.commands.append(allocator, .{ .color_image = .{ .rect = rect, .width = width, .height = height, .pixels = pixels, .cache_key = cache_key } });
    }
};

test "raster cache evicts least recently used entry to byte limit" {
    const allocator = std.testing.allocator;
    var cache = RasterCache.init(8);
    defer cache.deinit(allocator);

    {
        cache.beginFrame();
        defer cache.endFrame(allocator);
        _ = try cache.insertAlpha(allocator, 1, 1, 4, try allocator.dupe(u8, &.{ 1, 1, 1, 1 }));
        _ = try cache.insertAlpha(allocator, 2, 1, 4, try allocator.dupe(u8, &.{ 2, 2, 2, 2 }));
    }
    {
        cache.beginFrame();
        defer cache.endFrame(allocator);
        _ = cache.cachedAlphaImage(1, 1, 4);
        _ = try cache.insertAlpha(allocator, 3, 1, 4, try allocator.dupe(u8, &.{ 3, 3, 3, 3 }));
        try std.testing.expect(cache.byte_usage > cache.byte_limit);
    }

    cache.beginFrame();
    defer cache.endFrame(allocator);
    try std.testing.expect(cache.cachedAlphaImage(1, 1, 4) != null);
    try std.testing.expect(cache.cachedAlphaImage(2, 1, 4) == null);
    try std.testing.expect(cache.cachedAlphaImage(3, 1, 4) != null);
    try std.testing.expect(cache.byte_usage <= cache.byte_limit);
}

test "raster cache retains current frame working set until end frame" {
    const allocator = std.testing.allocator;
    var cache = RasterCache.init(1);
    defer cache.deinit(allocator);

    cache.beginFrame();
    const pixels = try cache.insertAlpha(allocator, 1, 1, 4, try allocator.dupe(u8, &.{ 4, 3, 2, 1 }));
    try std.testing.expectEqualSlices(u8, &.{ 4, 3, 2, 1 }, pixels);
    try std.testing.expect(cache.byte_usage > cache.byte_limit);
    cache.endFrame(allocator);

    cache.beginFrame();
    defer cache.endFrame(allocator);
    try std.testing.expect(cache.cachedAlphaImage(1, 1, 4) == null);
    try std.testing.expect(cache.byte_usage <= cache.byte_limit);
}

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
        /// Optional logical bounds within which a damage-only display list
        /// is safe. Backends that redraw from scratch leave this null.
        partial_paint_bounds: ?*const fn (ptr: *anyopaque, size: Size, scale: f32, damage: []const Rect) anyerror!?Rect = null,
    };

    pub const Frame = struct {
        size: Size,
        scale: f32,
        damage: []const Rect,
        display_list: []const PaintCommand,
        /// The display list omits commands outside damage. A backend that
        /// advertised this capability must preserve those pixels or fail.
        partial_display_list: bool = false,
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

    pub fn partialPaintBounds(self: RenderBackend, size: Size, scale_value: f32, damage: []const Rect) !?Rect {
        const partial_paint_bounds = self.vtable.partial_paint_bounds orelse return null;
        return partial_paint_bounds(self.ptr, size, scale_value, damage);
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

/// Natural vertical font metrics in logical units. Text with an explicit
/// line height paints at box top + half-leading + ascender.
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
    var max_line_len: usize = 0;
    var line_count: usize = 0;
    var lines = std.mem.splitScalar(u8, value, '\n');
    while (lines.next()) |line| {
        max_line_len = @max(max_line_len, line.len);
        line_count += 1;
    }
    return .{
        .width = @as(f32, @floatFromInt(max_line_len)) * style.font_size * text_width_ratio,
        .height = @as(f32, @floatFromInt(line_count)) * (style.line_height orelse style.font_size),
    };
}

test "fixed text measurement accounts for lines" {
    const style: ResolvedTextStyle = .{ .color = types.colors.ink, .font_size = 16 };
    try std.testing.expectEqual(Size{ .width = 16, .height = 32 }, fixedMeasureText("ab\nc", style));
    try std.testing.expectEqual(Size{ .width = 0, .height = 16 }, fixedMeasureText("", style));

    const explicit: ResolvedTextStyle = .{ .color = types.colors.ink, .font_size = 14, .line_height = 20 };
    try std.testing.expectEqual(Size{ .width = 14, .height = 40 }, fixedMeasureText("ab\nc", explicit));
}
