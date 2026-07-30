//! Borrowed CPU pixel buffer exposed as a retained widget.

const PixelBuffer = @This();

const std = @import("std");
const display = @import("display.zig");
const model = @import("model.zig");
const types = @import("types.zig");

const Color = types.Color;
const Size = types.Size;
const Widget = model.Widget;

/// Application-owned packed 0xAARRGGBB pixels. This descriptor does not own
/// or copy the source. The mapping must outlive the retained widget and must
/// not be written concurrently with a Keywork present. After a producer
/// finishes writing, rebuild with an incremented `Options.revision` and
/// invalidate the application.
pixels: []const u32,
width: u32,
height: u32,
stride: u32,
logical_size: Size,
format: display.PixelFormat,
id: u64,
revision: u64,
committed_damage: model.DamageRegion,

pub const Options = struct {
    /// Source row length in pixels, including padding.
    stride: ?u32 = null,
    /// Destination size in logical UI pixels. Defaults to the source size.
    logical_size: ?Size = null,
    format: display.PixelFormat = .argb8888_premultiplied,
    /// Stable producer identity used by GPU caches. Zero derives it from the
    /// mapping address.
    id: u64 = 0,
    /// Increment whenever the producer changes source pixels.
    revision: u64 = 0,
    /// Source-pixel rectangles changed in this revision. A missing or empty
    /// region falls back to full-widget damage when `revision` advances.
    damage: []const types.Rect = &.{},
};

pub fn init(pixels: []const u32, width: u32, height: u32, options: Options) !PixelBuffer {
    const logical_size: Size = options.logical_size orelse .{
        .width = @as(f32, @floatFromInt(width)),
        .height = @as(f32, @floatFromInt(height)),
    };
    var result: PixelBuffer = .{
        .pixels = pixels,
        .width = width,
        .height = height,
        .stride = options.stride orelse width,
        .logical_size = logical_size,
        .format = options.format,
        .id = options.id,
        .revision = options.revision,
        .committed_damage = .{},
    };
    result.committed_damage.addSlice(options.damage);
    result.committed_damage.intersect(.{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(width),
        .height = @floatFromInt(height),
    });
    try result.validate();
    return result;
}

pub fn widget(self: *const PixelBuffer) Widget {
    return .{ .render_object = .{
        .ptr = self,
        .vtable = &vtable,
        .clone_fn = clone,
        .destroy_fn = destroy,
    } };
}

fn validate(self: PixelBuffer) !void {
    if (self.width == 0 or self.height == 0 or self.stride < self.width) return error.InvalidPixelBuffer;
    const rows_before_last = try std.math.mul(usize, self.height - 1, self.stride);
    const required = try std.math.add(usize, rows_before_last, self.width);
    if (self.pixels.len < required) return error.InvalidPixelBuffer;
    if (!std.math.isFinite(self.logical_size.width) or self.logical_size.width <= 0 or
        !std.math.isFinite(self.logical_size.height) or self.logical_size.height <= 0)
    {
        return error.InvalidPixelBuffer;
    }
}

const vtable: Widget.RenderObject.VTable = .{
    .layout = layout,
    .paint = paint,
    .damage = damage,
};

fn layout(ptr: *const anyopaque, context: Widget.RenderObject.LayoutContext) !Size {
    const self: *const PixelBuffer = @ptrCast(@alignCast(ptr));
    return context.constraints.clamp(self.logical_size);
}

fn paint(ptr: *const anyopaque, context: Widget.RenderObject.PaintContext) !void {
    const self: *const PixelBuffer = @ptrCast(@alignCast(ptr));
    try self.validate();
    if (context.rect.isEmpty()) return;

    const color_pixels: [*]const Color = @ptrCast(self.pixels.ptr);
    try context.display_list.colorImageStrided(
        context.allocator,
        context.rect,
        self.width,
        self.height,
        color_pixels[0..self.pixels.len],
        self.stride,
        self.format,
        self.cacheKey(),
        self.revision,
    );
}

fn damage(old_ptr: *const anyopaque, new_ptr: *const anyopaque, rect: types.Rect, result: *model.DamageRegion) void {
    const old: *const PixelBuffer = @ptrCast(@alignCast(old_ptr));
    const new: *const PixelBuffer = @ptrCast(@alignCast(new_ptr));
    if (old.cacheKey() != new.cacheKey() or !std.meta.eql(old.logical_size, new.logical_size)) {
        result.add(rect);
        return;
    }
    if (old.revision == new.revision) return;
    if (new.revision != old.revision +% 1 or new.committed_damage.isEmpty()) {
        result.add(rect);
        return;
    }
    for (new.committed_damage.slice()) |source| {
        result.add(.{
            .x = rect.x + source.x / @as(f32, @floatFromInt(new.width)) * rect.width,
            .y = rect.y + source.y / @as(f32, @floatFromInt(new.height)) * rect.height,
            .width = source.width / @as(f32, @floatFromInt(new.width)) * rect.width,
            .height = source.height / @as(f32, @floatFromInt(new.height)) * rect.height,
        });
    }
}

fn cacheKey(self: *const PixelBuffer) u64 {
    const identity = if (self.id != 0) self.id else @as(u64, @intCast(@intFromPtr(self.pixels.ptr)));
    var hasher = std.hash.Wyhash.init(0);
    hasher.update("keywork-pixel-buffer");
    hasher.update(std.mem.asBytes(&identity));
    hasher.update(std.mem.asBytes(&self.width));
    hasher.update(std.mem.asBytes(&self.height));
    hasher.update(std.mem.asBytes(&self.stride));
    const format: u8 = @intFromEnum(self.format);
    hasher.update(std.mem.asBytes(&format));
    return hasher.final();
}

fn clone(allocator: std.mem.Allocator, ptr: *const anyopaque) !*const anyopaque {
    const self: *const PixelBuffer = @ptrCast(@alignCast(ptr));
    const result = try allocator.create(PixelBuffer);
    result.* = self.*;
    return result;
}

fn destroy(allocator: std.mem.Allocator, ptr: *const anyopaque) void {
    const self: *const PixelBuffer = @ptrCast(@alignCast(ptr));
    allocator.destroy(@constCast(self));
}

test "pixel buffer widget borrows padded rows and retains only metadata" {
    const source = [_]u32{
        0xff112233, 0xff445566, 0xdeadbeef,
        0xff778899, 0xffaabbcc, 0xdeadbeef,
    };
    const buffer = try PixelBuffer.init(&source, 2, 2, .{
        .stride = 3,
        .logical_size = .{ .width = 20, .height = 10 },
        .format = .xrgb8888,
        .id = 7,
        .revision = 3,
    });
    const render_object = buffer.widget().render_object;
    const retained = try render_object.clone(std.testing.allocator);
    defer retained.destroy(std.testing.allocator);

    const size = try retained.layout(.{
        .constraints = .{ .max_width = 100, .max_height = 100 },
        .measurer = .fixed,
    });
    try std.testing.expectEqual(Size{ .width = 20, .height = 10 }, size);

    var list: display.DisplayList = .{};
    defer list.deinit(std.testing.allocator);
    var cache: display.RasterCache = .{};
    defer cache.deinit(std.testing.allocator);
    cache.beginFrame();
    defer cache.endFrame(std.testing.allocator);
    try retained.paint(.{
        .allocator = std.testing.allocator,
        .rect = .{ .x = 4, .y = 5, .width = 20, .height = 10 },
        .scale = 1,
        .display_list = &list,
        .raster_cache = &cache,
    });

    const image = list.commands.items[0].color_image;
    try std.testing.expectEqual(@as(u32, 3), image.stride);
    try std.testing.expectEqual(display.PixelFormat.xrgb8888, image.format);
    try std.testing.expectEqual(@as(u64, 3), image.revision);
    try std.testing.expectEqual(@as(u32, 0xff778899), @as(u32, @bitCast(image.pixels[3])));
}

test "pixel buffer rejects undersized mappings" {
    const source = [_]u32{0} ** 4;
    try std.testing.expectError(error.InvalidPixelBuffer, PixelBuffer.init(&source, 2, 2, .{ .stride = 3 }));
}
