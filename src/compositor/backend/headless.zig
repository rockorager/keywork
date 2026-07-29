//! In-memory output storage for the headless backend.

const Self = @This();

const std = @import("std");
const render = @import("../render/types.zig");
const log = std.log.scoped(.headless);

allocator: std.mem.Allocator,
size: render.Size,
scale: render.Scale,
refresh_millihertz: i32,
pixels: []u32,
offscreen_renderer: ?render.OffscreenRenderer,
offscreen_target: ?render.OffscreenTarget,

pub const Error = error{
    InvalidDimensions,
    Overflow,
    OutOfMemory,
};

pub fn init(allocator: std.mem.Allocator, size: render.Size) Error!Self {
    return initForRenderer(allocator, size, .{}, 60_000, null) catch |err| switch (err) {
        error.InvalidDimensions, error.Overflow, error.OutOfMemory => |known| return known,
        else => unreachable,
    };
}

/// Retains the renderer callbacks and created target until deinit.
pub fn initForRenderer(
    allocator: std.mem.Allocator,
    size: render.Size,
    scale: render.Scale,
    refresh_millihertz: i32,
    offscreen_renderer: ?render.OffscreenRenderer,
) !Self {
    if (size.width == 0 or size.height == 0) return error.InvalidDimensions;
    if (refresh_millihertz <= 0) return error.InvalidRefresh;
    _ = scale.logicalSize(size) catch return error.InvalidDimensions;

    if (offscreen_renderer) |renderer| {
        const offscreen = try renderer.create_target(renderer.context, size);
        std.debug.assert(offscreen.id != 0 and std.meta.eql(offscreen.size, size));
        log.info("allocated GPU-resident output at {}x{}", .{ size.width, size.height });
        return .{
            .allocator = allocator,
            .size = size,
            .scale = scale,
            .refresh_millihertz = refresh_millihertz,
            .pixels = &.{},
            .offscreen_renderer = renderer,
            .offscreen_target = offscreen,
        };
    }

    const pixel_count = size.pixelCount() catch return error.Overflow;
    const pixels = allocator.alloc(u32, pixel_count) catch return error.OutOfMemory;
    @memset(pixels, 0);
    log.info("allocated CPU output at {}x{}", .{ size.width, size.height });

    return .{
        .allocator = allocator,
        .size = size,
        .scale = scale,
        .refresh_millihertz = refresh_millihertz,
        .pixels = pixels,
        .offscreen_renderer = null,
        .offscreen_target = null,
    };
}

pub fn deinit(self: *Self) void {
    if (self.offscreen_target) |offscreen| {
        const renderer = self.offscreen_renderer.?;
        renderer.release_target(renderer.context, offscreen.id);
    } else {
        self.allocator.free(self.pixels);
    }
    self.* = undefined;
}

pub fn logicalSize(self: *const Self) render.Size {
    return self.scale.logicalSize(self.size) catch unreachable;
}

pub fn refreshMillihertz(self: *const Self) i32 {
    return self.refresh_millihertz;
}

pub fn refreshNanoseconds(self: *const Self) u32 {
    const frequency: u64 = @intCast(self.refresh_millihertz);
    const period = (std.time.ns_per_s * 1000 + frequency / 2) / frequency;
    return @intCast(@min(period, std.math.maxInt(u32)));
}

pub fn renderTarget(self: *Self) render.Target {
    if (self.offscreen_target) |offscreen| return .{ .offscreen = offscreen };
    return .{ .pixels = self.target() };
}

pub fn target(self: *Self) render.PixelBuffer {
    std.debug.assert(self.offscreen_target == null);
    return .{
        .size = self.size,
        .stride_pixels = self.size.width,
        .pixels = self.pixels,
    };
}

pub fn pixel(self: *const Self, x: u32, y: u32) u32 {
    std.debug.assert(self.offscreen_target == null);
    std.debug.assert(x < self.size.width);
    std.debug.assert(y < self.size.height);

    return self.pixels[@as(usize, y) * self.size.width + x];
}

test "headless output starts transparent" {
    var output = try Self.init(std.testing.allocator, .{ .width = 2, .height = 3 });
    defer output.deinit();

    try std.testing.expectEqual(@as(usize, 6), output.pixels.len);
    try std.testing.expectEqual(@as(u32, 0), output.pixel(1, 2));
    try std.testing.expectEqual(@as(i32, 60_000), output.refreshMillihertz());
}

test "headless output uses configured refresh timing" {
    var output = try initForRenderer(
        std.testing.allocator,
        .{ .width = 2, .height = 3 },
        .{},
        120_000,
        null,
    );
    defer output.deinit();

    try std.testing.expectEqual(@as(i32, 120_000), output.refreshMillihertz());
    try std.testing.expectEqual(@as(u32, 8_333_333), output.refreshNanoseconds());
}
