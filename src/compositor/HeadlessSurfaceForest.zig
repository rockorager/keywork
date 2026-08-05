//! Applied, protocol-neutral presentation state for headless surface roots.
//!
//! Roots are ordered from bottom to top. The forest owns only canonical
//! compositor surface identity, applied mapping state, and resource-free frame
//! completion demand. Render providers remain borrowed from SurfaceRegistry by
//! Server at render time.

const HeadlessSurfaceForest = @This();

const std = @import("std");
const render = @import("render/types.zig");
const SurfaceRegistry = @import("SurfaceRegistry.zig");
const SurfaceFrameCompletion = @import("SurfaceFrameCompletion.zig");

pub const Root = struct {
    id: SurfaceRegistry.Id,
    mapped_size: ?render.Size = null,
    frame_completion: ?SurfaceFrameCompletion = null,
    frame_demand: bool = false,
};

allocator: std.mem.Allocator,
ordered_roots: std.ArrayList(Root) = .empty,

pub fn init(allocator: std.mem.Allocator) HeadlessSurfaceForest {
    return .{ .allocator = allocator };
}

/// Requires every root to have been removed.
pub fn deinit(self: *HeadlessSurfaceForest) void {
    std.debug.assert(self.ordered_roots.items.len == 0);
    self.ordered_roots.deinit(self.allocator);
    self.* = undefined;
}

/// Appends an unmapped root at the top of the applied order.
pub fn addRoot(
    self: *HeadlessSurfaceForest,
    id: SurfaceRegistry.Id,
    frame_completion: ?SurfaceFrameCompletion,
) error{OutOfMemory}!void {
    std.debug.assert(self.rootIndex(id) == null);
    try self.ordered_roots.append(self.allocator, .{
        .id = id,
        .frame_completion = frame_completion,
    });
}

/// Replaces the applied mapping state and latches new frame demand without
/// changing root order. Older demand is never cleared by a later commit.
pub fn applyRoot(
    self: *HeadlessSurfaceForest,
    id: SurfaceRegistry.Id,
    mapped_size: ?render.Size,
    callbacks_committed: bool,
) void {
    if (mapped_size) |size| std.debug.assert(size.width > 0 and size.height > 0);
    const index = self.rootIndex(id) orelse unreachable;
    const root = &self.ordered_roots.items[index];
    root.mapped_size = mapped_size;
    if (callbacks_committed) {
        std.debug.assert(root.frame_completion != null);
        root.frame_demand = true;
    }
}

/// Clears committed demand before returning its completion thunk.
pub fn takeFrameCompletion(
    self: *HeadlessSurfaceForest,
    id: SurfaceRegistry.Id,
) ?SurfaceFrameCompletion {
    const index = self.rootIndex(id) orelse unreachable;
    const root = &self.ordered_roots.items[index];
    if (!root.frame_demand) return null;
    const completion = root.frame_completion orelse unreachable;
    root.frame_demand = false;
    return completion;
}

/// Removes a root without changing the relative order of remaining roots.
pub fn removeRoot(self: *HeadlessSurfaceForest, id: SurfaceRegistry.Id) void {
    const index = self.rootIndex(id) orelse unreachable;
    _ = self.ordered_roots.orderedRemove(index);
}

/// Returns roots in deterministic bottom-to-top rendering order. The slice is
/// invalidated by addRoot or removeRoot.
pub fn roots(self: *const HeadlessSurfaceForest) []const Root {
    return self.ordered_roots.items;
}

pub fn rootIndex(self: *const HeadlessSurfaceForest, id: SurfaceRegistry.Id) ?usize {
    for (self.ordered_roots.items, 0..) |root, index| {
        if (std.meta.eql(root.id, id)) return index;
    }
    return null;
}

pub fn len(self: *const HeadlessSurfaceForest) usize {
    return self.ordered_roots.items.len;
}

test "applied roots preserve identity mapping and append order" {
    var forest = HeadlessSurfaceForest.init(std.testing.allocator);
    defer forest.deinit();
    const first: SurfaceRegistry.Id = .{ .index = 3, .generation = 7 };
    const second: SurfaceRegistry.Id = .{ .index = 5, .generation = 11 };

    try forest.addRoot(first, null);
    try forest.addRoot(second, null);
    forest.applyRoot(first, .{ .width = 4, .height = 2 }, false);
    try std.testing.expectEqualSlices(Root, &.{
        .{ .id = first, .mapped_size = .{ .width = 4, .height = 2 } },
        .{ .id = second },
    }, forest.roots());

    forest.applyRoot(first, null, false);
    forest.removeRoot(first);
    try std.testing.expectEqualSlices(Root, &.{.{ .id = second }}, forest.roots());
    forest.removeRoot(second);
}

test "root lookup keeps stale and current registry generations distinct" {
    const NullProvider = struct {
        fn renderState(_: *anyopaque) ?SurfaceRegistry.RenderState {
            return null;
        }
    };

    var registry = SurfaceRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var forest = HeadlessSurfaceForest.init(std.testing.allocator);
    defer forest.deinit();
    var first_context: u8 = 0;
    var current_context: u8 = 0;

    const stale = try registry.add(.{
        .context = &first_context,
        .render_state = NullProvider.renderState,
    });
    try forest.addRoot(stale, null);
    registry.remove(stale);
    const current = try registry.add(.{
        .context = &current_context,
        .render_state = NullProvider.renderState,
    });
    try std.testing.expectEqual(stale.index, current.index);
    try std.testing.expect(stale.generation != current.generation);
    try std.testing.expectEqual(@as(?usize, 0), forest.rootIndex(stale));
    try std.testing.expectEqual(@as(?usize, null), forest.rootIndex(current));

    try forest.addRoot(current, null);
    try std.testing.expectEqual(@as(?usize, 1), forest.rootIndex(current));
    forest.removeRoot(stale);
    forest.removeRoot(current);
    registry.remove(current);
}

test "frame demand is OR-latched and taken before completion" {
    const Completion = struct {
        fn complete(_: *anyopaque, _: SurfaceRegistry.Id, _: u32) void {}
    };
    var context: u8 = 0;
    const completion: SurfaceFrameCompletion = .{
        .context = &context,
        .complete = Completion.complete,
    };
    const id: SurfaceRegistry.Id = .{ .index = 3, .generation = 7 };
    var forest = HeadlessSurfaceForest.init(std.testing.allocator);
    defer forest.deinit();

    try forest.addRoot(id, completion);
    forest.applyRoot(id, .{ .width = 2, .height = 1 }, true);
    forest.applyRoot(id, null, false);
    try std.testing.expect(forest.roots()[0].frame_demand);
    try std.testing.expectEqual(completion, forest.takeFrameCompletion(id).?);
    try std.testing.expect(!forest.roots()[0].frame_demand);
    try std.testing.expectEqual(@as(?SurfaceFrameCompletion, null), forest.takeFrameCompletion(id));
    forest.removeRoot(id);
}
