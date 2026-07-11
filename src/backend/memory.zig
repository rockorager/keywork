//! In-memory CPU render backend for deterministic headless frames.

const Self = @This();

const std = @import("std");
const image_c = @import("image_c");
const keywork = @import("../ui.zig");
const raster = @import("../graphics/raster.zig");
const TextRenderer = @import("../graphics/text.zig");

allocator: std.mem.Allocator,
text_renderer: TextRenderer,
scale_value: f32,
pixels: []u32 = &.{},
width: u31 = 0,
height: u31 = 0,

pub fn init(allocator: std.mem.Allocator, scale_value: f32) !Self {
    if (!std.math.isFinite(scale_value) or scale_value <= 0) return error.InvalidScale;
    return .{
        .allocator = allocator,
        .text_renderer = try TextRenderer.init(allocator),
        .scale_value = scale_value,
    };
}

pub fn deinit(self: *Self) void {
    if (self.pixels.len > 0) self.allocator.free(self.pixels);
    self.text_renderer.deinit();
    self.* = undefined;
}

pub fn backend(self: *Self) keywork.RenderBackend {
    return .{ .ptr = self, .vtable = &.{
        .present = present,
        .measure_text = measureText,
        .scale = scale,
        .text_metrics = textMetrics,
    } };
}

pub fn writePng(self: *const Self, io: std.Io, path: []const u8) !void {
    if (self.width == 0 or self.height == 0 or self.pixels.len == 0) return error.NoFrame;

    const rgba_len = std.math.mul(usize, self.pixels.len, 4) catch return error.ImageTooLarge;
    const rgba = try self.allocator.alloc(u8, rgba_len);
    defer self.allocator.free(rgba);
    pixelsToRgba(self.pixels, rgba);

    const temporary = try std.fmt.allocPrintSentinel(self.allocator, "{s}.tmp-{d}", .{ path, std.os.linux.getpid() }, 0);
    defer self.allocator.free(temporary);
    defer std.Io.Dir.cwd().deleteFile(io, temporary) catch {};

    const stride = std.math.cast(c_int, @as(usize, self.width) * 4) orelse return error.ImageTooLarge;
    if (image_c.stbi_write_png(
        temporary.ptr,
        self.width,
        self.height,
        4,
        rgba.ptr,
        stride,
    ) == 0) return error.PngWriteFailed;
    try std.Io.Dir.rename(.cwd(), temporary, .cwd(), path, io);
}

fn present(ptr: *anyopaque, frame: keywork.RenderBackend.Frame) !bool {
    const self: *Self = @ptrCast(@alignCast(ptr));
    if (frame.partial_display_list) return error.PartialPaintUnavailable;
    const width = try physicalDimension(frame.size.width, frame.scale);
    const height = try physicalDimension(frame.size.height, frame.scale);
    const count = std.math.mul(usize, width, height) catch return error.ImageTooLarge;
    self.pixels = if (self.pixels.len == 0)
        try self.allocator.alloc(u32, count)
    else
        try self.allocator.realloc(self.pixels, count);
    self.width = width;
    self.height = height;
    try raster.rasterize(&self.text_renderer, self.pixels, width, height, frame.scale, frame.display_list, null);
    return false;
}

fn measureText(ptr: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !keywork.Size {
    const self: *Self = @ptrCast(@alignCast(ptr));
    return self.text_renderer.measure(self.scale_value, value, style);
}

fn textMetrics(ptr: *anyopaque, font_size: f32) !keywork.TextMetrics {
    const self: *Self = @ptrCast(@alignCast(ptr));
    return self.text_renderer.metrics(self.scale_value, font_size);
}

fn scale(ptr: *anyopaque) f32 {
    const self: *Self = @ptrCast(@alignCast(ptr));
    return self.scale_value;
}

fn physicalDimension(logical: f32, scale_value: f32) !u31 {
    if (!std.math.isFinite(logical) or logical <= 0) return error.InvalidFrameSize;
    const physical = @ceil(logical * scale_value);
    if (!std.math.isFinite(physical) or physical <= 0 or @as(f64, physical) > @as(f64, @floatFromInt(std.math.maxInt(u31)))) return error.InvalidFrameSize;
    return @intFromFloat(physical);
}

fn pixelsToRgba(pixels: []const u32, rgba: []u8) void {
    std.debug.assert(rgba.len == pixels.len * 4);
    for (pixels, 0..) |pixel, index| {
        const color: keywork.Color = @bitCast(pixel);
        rgba[index * 4 + 0] = color.r;
        rgba[index * 4 + 1] = color.g;
        rgba[index * 4 + 2] = color.b;
        rgba[index * 4 + 3] = color.a;
    }
}

test "pixelsToRgba writes channel order explicitly" {
    const pixels = [_]u32{@bitCast(keywork.Color.argb(0x11, 0x22, 0x33, 0x44))};
    var rgba: [4]u8 = undefined;
    pixelsToRgba(&pixels, &rgba);
    try std.testing.expectEqualSlices(u8, &.{ 0x22, 0x33, 0x44, 0x11 }, &rgba);
}
