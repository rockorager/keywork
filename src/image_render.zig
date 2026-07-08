//! Rendering for context-owned image resources.

const std = @import("std");
const core = @import("core.zig");
const resources = @import("resources.zig");

const ImageRender = struct {
    store: *resources.Store,
    resource: core.ResourceId,
    kind: resources.Kind,
    source_width: u32,
    source_height: u32,
    width: ?f32,
    height: ?f32,
    tint: ?core.Color,

    fn renderObject(self: *ImageRender) core.RenderObject {
        return .{ .ptr = self, .vtable = &.{
            .layout = layout,
            .paint = paint,
            .hit_test = hitTest,
            .clone = clone,
            .destroy = destroy,
        } };
    }

    fn clone(ptr: *anyopaque, allocator: std.mem.Allocator) !core.RenderObject {
        const self: *const ImageRender = @ptrCast(@alignCast(ptr));
        try self.store.retainDocument(self.resource, self.kind);
        errdefer self.store.releaseDocument(self.resource);
        const copy = try allocator.create(ImageRender);
        copy.* = self.*;
        return copy.renderObject();
    }

    fn destroy(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *ImageRender = @ptrCast(@alignCast(ptr));
        self.store.releaseDocument(self.resource);
        allocator.destroy(self);
    }

    fn layout(ptr: *anyopaque, context: core.RenderObject.LayoutContext) !core.Size {
        const self: *const ImageRender = @ptrCast(@alignCast(ptr));
        const natural_width: f32 = @floatFromInt(self.source_width);
        const natural_height: f32 = @floatFromInt(self.source_height);
        const max_width = if (self.width) |value| @min(value, context.constraints.max_width) else context.constraints.max_width;
        const max_height = if (self.height) |value| @min(value, context.constraints.max_height) else context.constraints.max_height;
        if (!std.math.isFinite(max_width) and !std.math.isFinite(max_height)) return .{ .width = natural_width, .height = natural_height };
        if (!std.math.isFinite(max_width)) return .{ .width = natural_width * max_height / natural_height, .height = max_height };
        if (!std.math.isFinite(max_height)) return .{ .width = max_width, .height = natural_height * max_width / natural_width };
        const scale = @min(max_width / natural_width, max_height / natural_height);
        return .{ .width = @max(0, natural_width * scale), .height = @max(0, natural_height * scale) };
    }

    fn paint(ptr: *anyopaque, context: core.RenderObject.PaintContext) !void {
        const self: *const ImageRender = @ptrCast(@alignCast(ptr));
        if (context.rect.width <= 0 or context.rect.height <= 0) return;
        const entry = self.store.get(self.resource) orelse return error.InvalidResource;
        if (entry.kind != self.kind or entry.width != self.source_width or entry.height != self.source_height) return error.InvalidResource;
        const width = try pixelDimension(context.rect.width);
        const height = try pixelDimension(context.rect.height);
        const cache_key = imageCacheKey(self.resource, self.kind, width, height, self.tint);

        switch (self.kind) {
            .a8 => {
                const tint = self.tint orelse return error.InvalidResource;
                if (context.display_list.cachedAlphaImage(cache_key, width, height)) |alpha| {
                    try context.display_list.alphaImage(context.allocator, context.rect, width, height, @constCast(alpha), tint, cache_key);
                    return;
                }
                const alpha = try resizeAlpha(context.allocator, entry.pixels, entry.width, entry.height, width, height);
                try context.display_list.alphaImage(context.allocator, context.rect, width, height, alpha, tint, cache_key);
            },
            .rgba8 => {
                if (self.tint) |tint| {
                    if (context.display_list.cachedAlphaImage(cache_key, width, height)) |alpha| {
                        try context.display_list.alphaImage(context.allocator, context.rect, width, height, @constCast(alpha), tint, cache_key);
                        return;
                    }
                    const alpha = try rgbaAlpha(context.allocator, entry.pixels, entry.width, entry.height, width, height);
                    try context.display_list.alphaImage(context.allocator, context.rect, width, height, alpha, tint, cache_key);
                } else {
                    if (context.display_list.cachedColorImage(cache_key, width, height)) |pixels| {
                        try context.display_list.colorImage(context.allocator, context.rect, width, height, @constCast(pixels), cache_key);
                        return;
                    }
                    const pixels = try resizeRgba(context.allocator, entry.pixels, entry.width, entry.height, width, height);
                    try context.display_list.colorImage(context.allocator, context.rect, width, height, pixels, cache_key);
                }
            },
        }
    }

    fn hitTest(_: *anyopaque, _: core.Rect, _: core.Point) ?[]const u8 {
        return null;
    }
};

pub fn image(allocator: std.mem.Allocator, store: *resources.Store, config: core.Widget.Image) !core.RenderObject {
    const entry = store.get(config.resource) orelse return error.InvalidResource;
    try store.retainDocument(config.resource, entry.kind);
    errdefer store.releaseDocument(config.resource);
    const render = try allocator.create(ImageRender);
    render.* = .{
        .store = store,
        .resource = config.resource,
        .kind = entry.kind,
        .source_width = entry.width,
        .source_height = entry.height,
        .width = config.width,
        .height = config.height,
        .tint = config.tint,
    };
    return render.renderObject();
}

fn resizeRgba(allocator: std.mem.Allocator, source: []const u8, source_width: u32, source_height: u32, width: u32, height: u32) ![]core.Color {
    const pixels = try allocator.alloc(core.Color, try pixelCount(width, height));
    for (0..height) |y| for (0..width) |x| {
        const index = sourceIndex(x, y, width, height, source_width, source_height) * 4;
        pixels[y * @as(usize, width) + x] = .{ .r = source[index], .g = source[index + 1], .b = source[index + 2], .a = source[index + 3] };
    };
    return pixels;
}

fn rgbaAlpha(allocator: std.mem.Allocator, source: []const u8, source_width: u32, source_height: u32, width: u32, height: u32) ![]u8 {
    const alpha = try allocator.alloc(u8, try pixelCount(width, height));
    for (0..height) |y| for (0..width) |x| {
        alpha[y * @as(usize, width) + x] = source[sourceIndex(x, y, width, height, source_width, source_height) * 4 + 3];
    };
    return alpha;
}

fn resizeAlpha(allocator: std.mem.Allocator, source: []const u8, source_width: u32, source_height: u32, width: u32, height: u32) ![]u8 {
    const alpha = try allocator.alloc(u8, try pixelCount(width, height));
    for (0..height) |y| for (0..width) |x| {
        alpha[y * @as(usize, width) + x] = source[sourceIndex(x, y, width, height, source_width, source_height)];
    };
    return alpha;
}

fn sourceIndex(x: usize, y: usize, width: u32, height: u32, source_width: u32, source_height: u32) usize {
    const source_x = @min(source_width - 1, @as(u32, @intCast((x * @as(usize, source_width)) / @as(usize, width))));
    const source_y = @min(source_height - 1, @as(u32, @intCast((y * @as(usize, source_height)) / @as(usize, height))));
    return @as(usize, source_y) * source_width + source_x;
}

fn pixelDimension(logical: f32) !u32 {
    const pixels = @ceil(@as(f64, logical));
    if (!std.math.isFinite(pixels) or pixels <= 0 or pixels > @as(f64, std.math.maxInt(c_int))) return error.ImageTooLarge;
    return @max(1, @as(u32, @intFromFloat(pixels)));
}

fn pixelCount(width: u32, height: u32) !usize {
    return std.math.mul(usize, width, height) catch error.ImageTooLarge;
}

fn imageCacheKey(resource: core.ResourceId, kind: resources.Kind, width: u32, height: u32, tint: ?core.Color) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&resource));
    hasher.update(&.{@intFromEnum(kind)});
    hasher.update(std.mem.asBytes(&width));
    hasher.update(std.mem.asBytes(&height));
    hasher.update(std.mem.asBytes(&tint));
    return hasher.final();
}

test "image cache keys include dimensions" {
    try std.testing.expect(imageCacheKey(1, .rgba8, 16, 32, null) != imageCacheKey(1, .rgba8, 32, 16, null));
    try std.testing.expect(imageCacheKey(1, .rgba8, 16, 32, null) != imageCacheKey(1, .rgba8, 16, 32, core.colors.red9));
}
