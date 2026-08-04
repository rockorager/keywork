//! Weak compositor-owned surface identity and render-provider registry.
//!
//! The registry owns only generational provider records. Provider contexts and
//! every resource exposed by their render state remain owned by the frontend.

const SurfaceRegistry = @This();

const std = @import("std");
const Region = @import("region.zig");
const render = @import("render/types.zig");
const slot_map = @import("slot_map.zig");

/// A one-shot render description returned by a surface provider.
///
/// This value does not transfer ownership. Pixel and source-damage slices,
/// DMA-BUF contexts, descriptors, and file descriptors, and region pointers
/// are borrowed through synchronous Renderer.finishFrame or cancelFrame for
/// the active event-loop frame. The registry never retains or releases DMA-BUF
/// resources and never emits frontend protocol events.
pub const RenderState = struct {
    buffer: render.PixelBuffer,
    logical_size: render.Size,
    source: ?render.SourceRect = null,
    transform: render.BufferTransform = .normal,
    force_opaque: bool = false,
    alpha_multiplier: u32 = std.math.maxInt(u32),
    opaque_region: ?*const Region = null,
    blur_region: ?*const Region = null,
};

pub const Provider = struct {
    /// Borrowed stable context. It must remain valid while this provider is
    /// registered and through any active render-state borrow.
    context: *anyopaque,
    render_state: *const fn (*anyopaque) ?RenderState,
};

const Store = slot_map.SlotMap(Provider, enum { compositor_surface });

pub const Id = Store.Id;

allocator: std.mem.Allocator,
providers: Store = .{},

pub fn init(allocator: std.mem.Allocator) SurfaceRegistry {
    return .{ .allocator = allocator };
}

/// Requires every provider to have been removed.
pub fn deinit(self: *SurfaceRegistry) void {
    self.providers.deinit(self.allocator);
    self.* = undefined;
}

pub fn add(self: *SurfaceRegistry, provider: Provider) error{OutOfMemory}!Id {
    return self.providers.insert(self.allocator, provider);
}

pub fn remove(self: *SurfaceRegistry, id: Id) void {
    std.debug.assert(self.providers.remove(id) != null);
}

pub fn contains(self: *const SurfaceRegistry, id: Id) bool {
    return self.providers.getConst(id) != null;
}

pub fn len(self: *const SurfaceRegistry) usize {
    return self.providers.len();
}

pub fn renderState(self: *const SurfaceRegistry, id: Id) ?RenderState {
    const provider = self.providers.getConst(id) orelse return null;
    return provider.render_state(provider.context);
}

const TestProvider = struct {
    pixel: u32,
    available: bool = true,

    fn renderState(context: *anyopaque) ?RenderState {
        const self: *TestProvider = @ptrCast(@alignCast(context));
        if (!self.available) return null;
        return .{
            .buffer = .{
                .size = .{ .width = 1, .height = 1 },
                .stride_pixels = 1,
                .pixels = @as([*]u32, @ptrCast(&self.pixel))[0..1],
            },
            .logical_size = .{ .width = self.pixel, .height = 1 },
        };
    }

    fn provider(self: *TestProvider) Provider {
        return .{ .context = self, .render_state = TestProvider.renderState };
    }
};

test "provider lookup distinguishes contexts and removal" {
    var registry = SurfaceRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var first: TestProvider = .{ .pixel = 11 };
    var second: TestProvider = .{ .pixel = 22 };

    const first_id = try registry.add(first.provider());
    const second_id = try registry.add(second.provider());
    try std.testing.expectEqual(@as(usize, 2), registry.len());
    try std.testing.expect(registry.contains(first_id));
    try std.testing.expectEqual(@as(u32, 11), registry.renderState(first_id).?.buffer.pixels[0]);
    try std.testing.expectEqual(@as(u32, 22), registry.renderState(second_id).?.buffer.pixels[0]);

    first.available = false;
    try std.testing.expectEqual(@as(?RenderState, null), registry.renderState(first_id));
    registry.remove(first_id);
    try std.testing.expect(!registry.contains(first_id));
    try std.testing.expectEqual(@as(?RenderState, null), registry.renderState(first_id));
    registry.remove(second_id);
    try std.testing.expectEqual(@as(usize, 0), registry.len());
}

test "stale IDs stay rejected after provider slot reuse" {
    var registry = SurfaceRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var first: TestProvider = .{ .pixel = 1 };
    var second: TestProvider = .{ .pixel = 2 };

    const stale = try registry.add(first.provider());
    registry.remove(stale);
    const current = try registry.add(second.provider());
    try std.testing.expectEqual(stale.index, current.index);
    try std.testing.expect(stale.generation != current.generation);
    try std.testing.expect(!registry.contains(stale));
    try std.testing.expectEqual(@as(?RenderState, null), registry.renderState(stale));
    try std.testing.expectEqual(@as(u32, 2), registry.renderState(current).?.buffer.pixels[0]);
    registry.remove(current);
}

test "empty registry tears down" {
    var registry = SurfaceRegistry.init(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), registry.len());
    registry.deinit();
}
