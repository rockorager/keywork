//! Applied, protocol-neutral presentation topology for headless surfaces.
//!
//! Nodes are stored in stable slots selected by canonical SurfaceRegistry IDs.
//! Only addRoot may grow storage. Every later mapping, placement, stacking,
//! detach, removal, traversal, bounds, and completion operation is infallible
//! and allocation-free. Render providers remain borrowed from SurfaceRegistry
//! by Server at render time.

const HeadlessSurfaceForest = @This();

const builtin = @import("builtin");
const std = @import("std");
const render = @import("render/types.zig");
const SurfaceRegistry = @import("SurfaceRegistry.zig");
const SurfaceFrameCompletion = @import("SurfaceFrameCompletion.zig");

pub const Position = struct {
    x: i32 = 0,
    y: i32 = 0,
};

pub const AppliedSurfaceState = struct {
    id: SurfaceRegistry.Id,
    mapped_size: ?render.Size,
    callbacks_committed: bool,
};

pub const AppliedStackEntry = union(enum) {
    parent,
    child: struct {
        id: SurfaceRegistry.Id,
        position: Position,
    },
};

pub const AppliedParentState = struct {
    id: SurfaceRegistry.Id,
    /// Borrowed bottom-to-top stack containing exactly one parent sentinel.
    stack: []const AppliedStackEntry,
};

pub const AppliedBatch = struct {
    /// Borrowed applied surface states. IDs occur at most once.
    surfaces: []const AppliedSurfaceState,
    /// Borrowed complete direct-child stack snapshots. Parent IDs occur at
    /// most once and every child occurs in at most one snapshot.
    parents: []const AppliedParentState,
};

pub const Placement = union(enum) {
    detached,
    root,
    child: struct {
        parent: SurfaceRegistry.Id,
        position: Position,
    },
};

/// Presentation ownership for an attached compound root. This is independent
/// from wl_surface role and child topology. Managed and cursor are permanent;
/// an unpublished XDG reservation may return to background until a concrete
/// role is assigned.
pub const PresentationClass = enum {
    background,
    xdg_reserved,
    managed,
    cursor,
};

pub const NodeState = struct {
    id: SurfaceRegistry.Id,
    mapped_size: ?render.Size,
    frame_completion: ?SurfaceFrameCompletion,
    frame_demand: bool,
    placement: Placement,
    presentation_class: PresentationClass,
};

pub const RenderEntry = struct {
    id: SurfaceRegistry.Id,
    mapped_size: render.Size,
    position: Position,
};

pub const InputHit = struct {
    id: SurfaceRegistry.Id,
    x: f64,
    y: f64,
};

pub const InputFilter = struct {
    context: *anyopaque,
    accepts: *const fn (*anyopaque, SurfaceRegistry.Id, f64, f64) bool,
};

pub const CompoundBounds = union(enum) {
    hidden,
    rect: render.Rect,
    /// At least one visible descendant cannot be represented by render.Rect.
    full_damage,
};

const StackEntry = union(enum) {
    parent,
    child: SurfaceRegistry.Id,
};

const PlacementTag = enum { detached, root, child };

const Node = struct {
    id: SurfaceRegistry.Id = .{ .index = 0, .generation = 0 },
    mapped_size: ?render.Size = null,
    frame_completion: ?SurfaceFrameCompletion = null,
    frame_demand: bool = false,
    presentation_class: PresentationClass = .background,

    placement: PlacementTag = .detached,
    parent: ?SurfaceRegistry.Id = null,
    position: Position = .{},

    root_prev: ?SurfaceRegistry.Id = null,
    root_next: ?SurfaceRegistry.Id = null,

    // Links for this node's entry in its parent's stack.
    stack_prev: ?StackEntry = null,
    stack_next: ?StackEntry = null,

    // Every node owns one direct-child stack with exactly one parent sentinel.
    stack_head: StackEntry = .parent,
    stack_tail: StackEntry = .parent,
    sentinel_prev: ?StackEntry = null,
    sentinel_next: ?StackEntry = null,
    direct_child_count: usize = 0,
};

const Slot = struct {
    active: bool = false,
    generation: u32 = 0,
    node: Node = .{},
};

const ExactGeometry = struct {
    x: i64,
    y: i64,
    size: render.Size,
};

allocator: std.mem.Allocator,
slots: std.ArrayList(Slot) = .empty,
node_count: usize = 0,
root_count: usize = 0,
root_head: ?SurfaceRegistry.Id = null,
root_tail: ?SurfaceRegistry.Id = null,

pub fn init(allocator: std.mem.Allocator) HeadlessSurfaceForest {
    return .{ .allocator = allocator };
}

/// Requires every node to have been removed.
pub fn deinit(self: *HeadlessSurfaceForest) void {
    std.debug.assert(self.node_count == 0);
    std.debug.assert(self.root_count == 0);
    std.debug.assert(self.root_head == null and self.root_tail == null);
    self.slots.deinit(self.allocator);
    self.* = undefined;
}

/// Appends an unmapped root at the top of the applied order. This is the only
/// topology operation allowed to allocate.
pub fn addRoot(
    self: *HeadlessSurfaceForest,
    id: SurfaceRegistry.Id,
    frame_completion: ?SurfaceFrameCompletion,
) error{OutOfMemory}!void {
    std.debug.assert(self.node(id) == null);
    const required = @as(usize, id.index) + 1;
    try self.slots.ensureTotalCapacity(self.allocator, required);
    while (self.slots.items.len < required) self.slots.appendAssumeCapacity(.{});

    const slot = &self.slots.items[id.index];
    std.debug.assert(!slot.active);
    slot.* = .{
        .active = true,
        .generation = id.generation,
        .node = .{
            .id = id,
            .frame_completion = frame_completion,
            .placement = .root,
            .root_prev = self.root_tail,
        },
    };
    if (self.root_tail) |tail| {
        self.node(tail).?.root_next = id;
    } else {
        self.root_head = id;
    }
    self.root_tail = id;
    self.node_count += 1;
    self.root_count += 1;
    self.validateAfterMutation();
}

/// Applies a fully prepared resource-free transaction. The caller guarantees
/// canonical IDs, one sentinel per parent snapshot, unique children, and an
/// acyclic resulting ancestry graph. No borrowed slice is retained.
pub fn apply(self: *HeadlessSurfaceForest, batch: AppliedBatch) void {
    self.assertBatch(batch);

    // Clear every replaced parent stack first, preserving each detached
    // child's own content, frame demand, and direct-child stack.
    for (batch.parents) |parent_state| self.detachDirectChildren(parent_state.id);

    // A listed child may move from an unchanged parent or the root list.
    for (batch.parents) |parent_state| {
        for (parent_state.stack) |entry| switch (entry) {
            .parent => {},
            .child => |child| self.detachPlacement(child.id),
        };
    }

    for (batch.parents) |parent_state| {
        var before_parent = true;
        for (parent_state.stack) |entry| switch (entry) {
            .parent => before_parent = false,
            .child => |child| self.attachChild(
                parent_state.id,
                child.id,
                child.position,
                before_parent,
            ),
        };
    }

    for (batch.surfaces) |surface| {
        if (surface.mapped_size) |size|
            std.debug.assert(size.width > 0 and size.height > 0);
        const target = self.node(surface.id).?;
        target.mapped_size = surface.mapped_size;
        if (surface.callbacks_committed) {
            std.debug.assert(target.frame_completion != null);
            target.frame_demand = true;
        }
    }
    self.validateAfterMutation();
}

/// Immediately hides a whole compound subtree while preserving every node's
/// content, frame demand, relative placement value, and direct-child stack.
pub fn detach(self: *HeadlessSurfaceForest, id: SurfaceRegistry.Id) void {
    const target = self.node(id) orelse unreachable;
    std.debug.assert(target.presentation_class == .background);
    self.detachPlacement(id);
    self.validateAfterMutation();
}

/// Removes one node. Direct children become detached compounds; descendants
/// and all frontend-owned providers/resources remain untouched.
pub fn remove(self: *HeadlessSurfaceForest, id: SurfaceRegistry.Id) void {
    std.debug.assert(self.node(id) != null);
    self.detachPlacement(id);
    self.detachDirectChildren(id);
    const slot = &self.slots.items[id.index];
    slot.active = false;
    slot.generation = id.generation;
    slot.node = .{};
    self.node_count -= 1;
    self.validateAfterMutation();
}

/// Clears committed demand before returning its resource-free completion.
pub fn takeFrameCompletion(
    self: *HeadlessSurfaceForest,
    id: SurfaceRegistry.Id,
) ?SurfaceFrameCompletion {
    const target = self.node(id) orelse return null;
    if (!target.frame_demand) return null;
    const completion = target.frame_completion orelse unreachable;
    target.frame_demand = false;
    self.validateAfterMutation();
    return completion;
}

/// Applies one allocation-free root presentation transition. Detached and
/// child nodes are rejected. Managed and cursor roots cannot regress.
pub fn setRootPresentationClass(
    self: *HeadlessSurfaceForest,
    id: SurfaceRegistry.Id,
    class: PresentationClass,
) bool {
    const target = self.node(id) orelse return false;
    if (target.placement != .root) return false;
    const allowed = switch (target.presentation_class) {
        .background => true,
        .xdg_reserved => class == .background or class == .xdg_reserved or class == .managed,
        .managed => class == .managed,
        .cursor => class == .cursor,
    };
    if (!allowed) return false;
    target.presentation_class = class;
    self.validateAfterMutation();
    return true;
}

/// Resolves the effective class through the current compound root.
pub fn presentationClass(
    self: *const HeadlessSurfaceForest,
    id: SurfaceRegistry.Id,
) ?PresentationClass {
    const root = self.compoundRoot(id) orelse return null;
    return self.nodeConst(root).?.presentation_class;
}

pub fn isCursorRole(self: *const HeadlessSurfaceForest, id: SurfaceRegistry.Id) bool {
    return self.presentationClass(id) == .cursor;
}

pub fn state(self: *const HeadlessSurfaceForest, id: SurfaceRegistry.Id) ?NodeState {
    const target = self.nodeConst(id) orelse return null;
    return nodeState(target);
}

pub fn rootAt(self: *const HeadlessSurfaceForest, wanted: usize) ?NodeState {
    var index: usize = 0;
    var id = self.root_head;
    while (id) |current| {
        const target = self.nodeConst(current) orelse unreachable;
        if (index == wanted) return nodeState(target);
        index += 1;
        id = target.root_next;
    }
    return null;
}

pub fn rootIndex(self: *const HeadlessSurfaceForest, id: SurfaceRegistry.Id) ?usize {
    var index: usize = 0;
    var current = self.root_head;
    while (current) |candidate| {
        if (sameId(candidate, id)) return index;
        current = self.nodeConst(candidate).?.root_next;
        index += 1;
    }
    return null;
}

/// Resolves one active node to its current attached compound root. Detached,
/// removed, stale, cyclic, and foreign-forest identities are rejected. The
/// bounded parent walk is allocation-free.
pub fn compoundRoot(
    self: *const HeadlessSurfaceForest,
    id: SurfaceRegistry.Id,
) ?SurfaceRegistry.Id {
    var current = self.nodeConst(id) orelse return null;
    var steps: usize = 0;
    while (true) {
        steps += 1;
        if (steps > self.node_count) return null;
        switch (current.placement) {
            .detached => return null,
            .root => return current.id,
            .child => current = self.nodeConst(current.parent orelse return null) orelse
                return null,
        }
    }
}

/// Reports whether the exact endpoint is currently mapped through a fully
/// mapped ancestry chain under the expected compound root.
pub fn presentedInCompound(
    self: *const HeadlessSurfaceForest,
    id: SurfaceRegistry.Id,
    root: SurfaceRegistry.Id,
) bool {
    if (self.exactGeometry(id) == null) return false;
    const current_root = self.compoundRoot(id) orelse return false;
    if (self.nodeConst(current_root).?.presentation_class != .background) return false;
    return sameId(current_root, root);
}

pub fn len(self: *const HeadlessSurfaceForest) usize {
    return self.node_count;
}

pub fn rootLen(self: *const HeadlessSurfaceForest) usize {
    return self.root_count;
}

pub const NodeIterator = struct {
    forest: *const HeadlessSurfaceForest,
    index: usize = 0,

    pub fn next(self: *NodeIterator) ?NodeState {
        while (self.index < self.forest.slots.items.len) {
            const slot = &self.forest.slots.items[self.index];
            self.index += 1;
            if (slot.active) return nodeState(&slot.node);
        }
        return null;
    }
};

pub fn nodeIterator(self: *const HeadlessSurfaceForest) NodeIterator {
    return .{ .forest = self };
}

/// Iterates visible nodes in exact bottom-to-top paint order. Traversal is
/// bounded by node count and never uses the call stack for topology depth.
pub const RenderIterator = struct {
    forest: *const HeadlessSurfaceForest,
    next_root: ?SurfaceRegistry.Id,
    owner: ?SurfaceRegistry.Id = null,
    entry: ?StackEntry = null,
    steps_remaining: usize,

    pub fn next(self: *RenderIterator) ?RenderEntry {
        while (self.steps_remaining > 0) {
            if (self.owner == null) {
                const root = self.next_root orelse return null;
                const root_node = self.forest.nodeConst(root) orelse return null;
                self.next_root = root_node.root_next;
                if (root_node.presentation_class == .xdg_reserved or
                    root_node.presentation_class == .managed) continue;
                self.owner = root;
                self.entry = root_node.stack_head;
            }

            const owner = self.owner.?;
            const entry = self.entry.?;
            self.steps_remaining -= 1;
            switch (entry) {
                .child => |child| {
                    const child_node = self.forest.nodeConst(child) orelse return null;
                    self.owner = child;
                    self.entry = child_node.stack_head;
                },
                .parent => {
                    self.advance(owner, .parent);
                    const geometry = self.forest.exactGeometry(owner) orelse continue;
                    return .{
                        .id = owner,
                        .mapped_size = geometry.size,
                        .position = .{
                            .x = saturateI32(geometry.x),
                            .y = saturateI32(geometry.y),
                        },
                    };
                },
            }
        }
        self.owner = null;
        self.entry = null;
        self.next_root = null;
        return null;
    }

    fn advance(self: *RenderIterator, owner: SurfaceRegistry.Id, entry: StackEntry) void {
        var current_owner = owner;
        var following = self.forest.entryNext(current_owner, entry);
        while (following == null) {
            const current = self.forest.nodeConst(current_owner) orelse {
                self.owner = null;
                self.entry = null;
                return;
            };
            switch (current.placement) {
                .child => {
                    const parent = current.parent orelse unreachable;
                    following = current.stack_next;
                    current_owner = parent;
                },
                .root => {
                    self.owner = null;
                    self.entry = null;
                    return;
                },
                .detached => {
                    self.owner = null;
                    self.entry = null;
                    self.next_root = null;
                    return;
                },
            }
        }
        self.owner = current_owner;
        self.entry = following;
    }
};

pub fn renderIterator(self: *const HeadlessSurfaceForest) RenderIterator {
    return .{
        .forest = self,
        .next_root = self.root_head,
        .steps_remaining = self.node_count *| 2 +| self.root_count,
    };
}

/// Iterates one attached compound in exact bottom-to-top paint order. Entry
/// positions are relative to the compound root.
pub fn subtreeRenderIterator(
    self: *const HeadlessSurfaceForest,
    root: SurfaceRegistry.Id,
) RenderIterator {
    const target = self.nodeConst(root) orelse return .{
        .forest = self,
        .next_root = null,
        .steps_remaining = 0,
    };
    if (target.placement != .root) return .{
        .forest = self,
        .next_root = null,
        .steps_remaining = 0,
    };
    return .{
        .forest = self,
        .next_root = null,
        .owner = root,
        .entry = target.stack_head,
        .steps_remaining = self.node_count *| 2 +| 1,
    };
}

/// Returns the topmost visible node accepted by the frontend-local input
/// filter. Iteration follows exact paint order and retains only one candidate;
/// neither topology traversal nor filtering allocates.
pub fn inputHit(
    self: *const HeadlessSurfaceForest,
    x: f64,
    y: f64,
    filter: InputFilter,
) ?InputHit {
    if (!std.math.isFinite(x) or !std.math.isFinite(y)) return null;
    var hit: ?InputHit = null;
    var iterator = self.renderIterator();
    while (iterator.next()) |entry| {
        if (self.isCursorRole(entry.id)) continue;
        const surface_x = x - @as(f64, @floatFromInt(entry.position.x));
        const surface_y = y - @as(f64, @floatFromInt(entry.position.y));
        if (surface_x < 0 or surface_y < 0 or
            surface_x >= @as(f64, @floatFromInt(entry.mapped_size.width)) or
            surface_y >= @as(f64, @floatFromInt(entry.mapped_size.height))) continue;
        if (!filter.accepts(filter.context, entry.id, surface_x, surface_y)) continue;
        hit = .{ .id = entry.id, .x = surface_x, .y = surface_y };
    }
    return hit;
}

/// Returns the visible, unclipped bounds of a node and all its descendants.
/// Any unsafe coordinate or extent requests conservative full-output damage.
pub fn compoundBounds(
    self: *const HeadlessSurfaceForest,
    id: SurfaceRegistry.Id,
) CompoundBounds {
    const root = self.compoundRoot(id) orelse return .hidden;
    const class = self.nodeConst(root).?.presentation_class;
    if (class == .xdg_reserved or class == .managed) return .hidden;
    return self.geometryBounds(id);
}

/// Resource-free mapped bounds for semantic surface geometry. Unlike
/// presentation damage, XDG geometry remains observable while the generated
/// root is reserved or managed but intentionally hidden from rendering.
pub fn subtreeBounds(
    self: *const HeadlessSurfaceForest,
    id: SurfaceRegistry.Id,
) ?render.Rect {
    return switch (self.geometryBounds(id)) {
        .rect => |rect| rect,
        .hidden, .full_damage => null,
    };
}

fn geometryBounds(
    self: *const HeadlessSurfaceForest,
    id: SurfaceRegistry.Id,
) CompoundBounds {
    if (self.exactGeometry(id) == null) return .hidden;
    var has_bounds = false;
    var left: i64 = 0;
    var top: i64 = 0;
    var right: i64 = 0;
    var bottom: i64 = 0;

    var iterator = self.nodeIterator();
    while (iterator.next()) |entry| {
        if (!self.isDescendantOrSelf(entry.id, id)) continue;
        const geometry = self.exactGeometry(entry.id) orelse continue;
        if (geometry.x < std.math.minInt(i32) or geometry.x > std.math.maxInt(i32) or
            geometry.y < std.math.minInt(i32) or geometry.y > std.math.maxInt(i32))
        {
            return .full_damage;
        }
        const node_right = std.math.add(i64, geometry.x, geometry.size.width) catch
            return .full_damage;
        const node_bottom = std.math.add(i64, geometry.y, geometry.size.height) catch
            return .full_damage;
        if (!has_bounds) {
            left = geometry.x;
            top = geometry.y;
            right = node_right;
            bottom = node_bottom;
            has_bounds = true;
        } else {
            left = @min(left, geometry.x);
            top = @min(top, geometry.y);
            right = @max(right, node_right);
            bottom = @max(bottom, node_bottom);
        }
    }
    if (!has_bounds) return .hidden;
    if (left < std.math.minInt(i32) or left > std.math.maxInt(i32) or
        top < std.math.minInt(i32) or top > std.math.maxInt(i32) or
        right <= left or bottom <= top or
        right - left > std.math.maxInt(u32) or bottom - top > std.math.maxInt(u32))
    {
        return .full_damage;
    }
    return .{ .rect = .{
        .x = @intCast(left),
        .y = @intCast(top),
        .width = @intCast(right - left),
        .height = @intCast(bottom - top),
    } };
}

/// Allocation-free structural validation used after every mutator in Debug
/// and tests. It intentionally does not inspect SurfaceRegistry membership.
pub fn validate(self: *const HeadlessSurfaceForest) void {
    var active_count: usize = 0;
    for (self.slots.items, 0..) |slot, index| {
        if (!slot.active) continue;
        active_count += 1;
        const target = &slot.node;
        std.debug.assert(target.id.index == index);
        std.debug.assert(target.id.generation == slot.generation);
        if (target.mapped_size) |size|
            std.debug.assert(size.width > 0 and size.height > 0);
        std.debug.assert(!target.frame_demand or target.frame_completion != null);
        if (target.presentation_class != .background)
            std.debug.assert(target.placement == .root);

        switch (target.placement) {
            .root => {
                std.debug.assert(target.parent == null);
                std.debug.assert(target.position.x == 0 and target.position.y == 0);
                std.debug.assert(target.stack_prev == null and target.stack_next == null);
                if (target.root_prev) |previous|
                    std.debug.assert(sameOptionalId(self.nodeConst(previous).?.root_next, target.id));
                if (target.root_next) |next|
                    std.debug.assert(sameOptionalId(self.nodeConst(next).?.root_prev, target.id));
            },
            .detached => {
                std.debug.assert(target.parent == null);
                std.debug.assert(target.root_prev == null and target.root_next == null);
                std.debug.assert(target.stack_prev == null and target.stack_next == null);
            },
            .child => {
                const parent = target.parent orelse unreachable;
                std.debug.assert(self.nodeConst(parent) != null);
                std.debug.assert(target.root_prev == null and target.root_next == null);
                if (target.stack_prev) |previous|
                    std.debug.assert(stackEntryEqual(self.entryNext(parent, previous).?, .{ .child = target.id }));
                if (target.stack_next) |next|
                    std.debug.assert(stackEntryEqual(self.entryPrev(parent, next).?, .{ .child = target.id }));
            },
        }

        var sentinel_count: usize = 0;
        var child_count: usize = 0;
        var stack_steps: usize = 0;
        var previous: ?StackEntry = null;
        var current: ?StackEntry = target.stack_head;
        while (current) |entry| {
            stack_steps += 1;
            std.debug.assert(stack_steps <= self.node_count + 1);
            std.debug.assert(stackEntryOptionalEqual(self.entryPrev(target.id, entry), previous));
            switch (entry) {
                .parent => sentinel_count += 1,
                .child => |child| {
                    child_count += 1;
                    const child_node = self.nodeConst(child) orelse unreachable;
                    std.debug.assert(child_node.placement == .child);
                    std.debug.assert(sameOptionalId(child_node.parent, target.id));
                },
            }
            previous = entry;
            current = self.entryNext(target.id, entry);
        }
        std.debug.assert(stackEntryEqual(previous.?, target.stack_tail));
        std.debug.assert(sentinel_count == 1);
        std.debug.assert(child_count == target.direct_child_count);

        var ancestry_steps: usize = 0;
        var ancestor = target;
        while (ancestor.placement == .child) {
            ancestry_steps += 1;
            std.debug.assert(ancestry_steps <= self.node_count);
            ancestor = self.nodeConst(ancestor.parent.?) orelse unreachable;
        }
    }
    std.debug.assert(active_count == self.node_count);

    var roots_seen: usize = 0;
    var previous_root: ?SurfaceRegistry.Id = null;
    var root = self.root_head;
    while (root) |id| {
        roots_seen += 1;
        std.debug.assert(roots_seen <= self.node_count);
        const target = self.nodeConst(id) orelse unreachable;
        std.debug.assert(target.placement == .root);
        std.debug.assert(sameOptionalId(target.root_prev, previous_root));
        previous_root = id;
        root = target.root_next;
    }
    std.debug.assert(roots_seen == self.root_count);
    std.debug.assert(sameOptionalId(previous_root, self.root_tail));
    std.debug.assert((self.root_count == 0) == (self.root_head == null));
    std.debug.assert((self.root_count == 0) == (self.root_tail == null));
}

fn validateAfterMutation(self: *const HeadlessSurfaceForest) void {
    if (builtin.mode == .Debug or builtin.is_test) self.validate();
}

fn assertBatch(self: *const HeadlessSurfaceForest, batch: AppliedBatch) void {
    for (batch.surfaces, 0..) |surface, index| {
        std.debug.assert(self.nodeConst(surface.id) != null);
        if (surface.mapped_size) |size|
            std.debug.assert(size.width > 0 and size.height > 0);
        for (batch.surfaces[index + 1 ..]) |other|
            std.debug.assert(!sameId(surface.id, other.id));
    }
    for (batch.parents, 0..) |parent_state, parent_index| {
        std.debug.assert(self.nodeConst(parent_state.id) != null);
        for (batch.parents[parent_index + 1 ..]) |other|
            std.debug.assert(!sameId(parent_state.id, other.id));
        var sentinel_count: usize = 0;
        for (parent_state.stack, 0..) |entry, entry_index| switch (entry) {
            .parent => sentinel_count += 1,
            .child => |child| {
                std.debug.assert(self.nodeConst(child.id) != null);
                std.debug.assert(!sameId(parent_state.id, child.id));
                for (parent_state.stack[entry_index + 1 ..]) |later| switch (later) {
                    .parent => {},
                    .child => |other| std.debug.assert(!sameId(child.id, other.id)),
                };
                for (batch.parents[parent_index + 1 ..]) |later_parent| {
                    for (later_parent.stack) |later| switch (later) {
                        .parent => {},
                        .child => |other| std.debug.assert(!sameId(child.id, other.id)),
                    };
                }
            },
        };
        std.debug.assert(sentinel_count == 1);
    }
}

fn nodeState(target: *const Node) NodeState {
    return .{
        .id = target.id,
        .mapped_size = target.mapped_size,
        .frame_completion = target.frame_completion,
        .frame_demand = target.frame_demand,
        .presentation_class = target.presentation_class,
        .placement = switch (target.placement) {
            .detached => .detached,
            .root => .root,
            .child => .{ .child = .{
                .parent = target.parent.?,
                .position = target.position,
            } },
        },
    };
}

fn detachDirectChildren(self: *HeadlessSurfaceForest, parent: SurfaceRegistry.Id) void {
    while (self.node(parent).?.direct_child_count > 0) {
        const parent_node = self.node(parent).?;
        const entry = switch (parent_node.stack_head) {
            .child => |child| child,
            .parent => switch (parent_node.sentinel_next.?) {
                .child => |child| child,
                .parent => unreachable,
            },
        };
        self.detachPlacement(entry);
    }
}

fn detachPlacement(self: *HeadlessSurfaceForest, id: SurfaceRegistry.Id) void {
    const target = self.node(id) orelse unreachable;
    switch (target.placement) {
        .detached => return,
        .root => {
            if (target.root_prev) |previous| {
                self.node(previous).?.root_next = target.root_next;
            } else {
                self.root_head = target.root_next;
            }
            if (target.root_next) |next| {
                self.node(next).?.root_prev = target.root_prev;
            } else {
                self.root_tail = target.root_prev;
            }
            self.root_count -= 1;
        },
        .child => {
            const parent = target.parent orelse unreachable;
            const previous = target.stack_prev;
            const next = target.stack_next;
            if (previous) |entry| {
                self.setEntryNext(parent, entry, next);
            } else {
                self.node(parent).?.stack_head = next orelse unreachable;
            }
            if (next) |entry| {
                self.setEntryPrev(parent, entry, previous);
            } else {
                self.node(parent).?.stack_tail = previous orelse unreachable;
            }
            self.node(parent).?.direct_child_count -= 1;
        },
    }
    target.placement = .detached;
    target.parent = null;
    target.root_prev = null;
    target.root_next = null;
    target.stack_prev = null;
    target.stack_next = null;
}

fn attachChild(
    self: *HeadlessSurfaceForest,
    parent: SurfaceRegistry.Id,
    child: SurfaceRegistry.Id,
    position: Position,
    before_parent: bool,
) void {
    const child_node = self.node(child) orelse unreachable;
    std.debug.assert(child_node.placement == .detached);
    child_node.placement = .child;
    child_node.parent = parent;
    child_node.position = position;

    if (before_parent) {
        const previous = self.node(parent).?.sentinel_prev;
        child_node.stack_prev = previous;
        child_node.stack_next = .parent;
        if (previous) |entry| {
            self.setEntryNext(parent, entry, .{ .child = child });
        } else {
            self.node(parent).?.stack_head = .{ .child = child };
        }
        self.node(parent).?.sentinel_prev = .{ .child = child };
    } else {
        const tail = self.node(parent).?.stack_tail;
        child_node.stack_prev = tail;
        child_node.stack_next = null;
        self.setEntryNext(parent, tail, .{ .child = child });
        self.node(parent).?.stack_tail = .{ .child = child };
    }
    self.node(parent).?.direct_child_count += 1;
}

fn exactGeometry(self: *const HeadlessSurfaceForest, id: SurfaceRegistry.Id) ?ExactGeometry {
    const initial = self.nodeConst(id) orelse return null;
    const size = initial.mapped_size orelse return null;
    var x: i64 = 0;
    var y: i64 = 0;
    var current = initial;
    var steps: usize = 0;
    while (true) {
        steps += 1;
        if (steps > self.node_count) return null;
        switch (current.placement) {
            .detached => return null,
            .root => return .{ .x = x, .y = y, .size = size },
            .child => {
                x = std.math.add(i64, x, current.position.x) catch return null;
                y = std.math.add(i64, y, current.position.y) catch return null;
                current = self.nodeConst(current.parent.?) orelse return null;
                if (current.mapped_size == null) return null;
            },
        }
    }
}

fn isDescendantOrSelf(
    self: *const HeadlessSurfaceForest,
    candidate: SurfaceRegistry.Id,
    ancestor: SurfaceRegistry.Id,
) bool {
    var current = self.nodeConst(candidate) orelse return false;
    var steps: usize = 0;
    while (true) {
        if (sameId(current.id, ancestor)) return true;
        steps += 1;
        if (steps > self.node_count or current.placement != .child) return false;
        current = self.nodeConst(current.parent.?) orelse return false;
    }
}

fn entryPrev(
    self: *const HeadlessSurfaceForest,
    parent: SurfaceRegistry.Id,
    entry: StackEntry,
) ?StackEntry {
    return switch (entry) {
        .parent => self.nodeConst(parent).?.sentinel_prev,
        .child => |child| self.nodeConst(child).?.stack_prev,
    };
}

fn entryNext(
    self: *const HeadlessSurfaceForest,
    parent: SurfaceRegistry.Id,
    entry: StackEntry,
) ?StackEntry {
    return switch (entry) {
        .parent => self.nodeConst(parent).?.sentinel_next,
        .child => |child| self.nodeConst(child).?.stack_next,
    };
}

fn setEntryPrev(
    self: *HeadlessSurfaceForest,
    parent: SurfaceRegistry.Id,
    entry: StackEntry,
    previous: ?StackEntry,
) void {
    switch (entry) {
        .parent => self.node(parent).?.sentinel_prev = previous,
        .child => |child| self.node(child).?.stack_prev = previous,
    }
}

fn setEntryNext(
    self: *HeadlessSurfaceForest,
    parent: SurfaceRegistry.Id,
    entry: StackEntry,
    next: ?StackEntry,
) void {
    switch (entry) {
        .parent => self.node(parent).?.sentinel_next = next,
        .child => |child| self.node(child).?.stack_next = next,
    }
}

fn node(self: *HeadlessSurfaceForest, id: SurfaceRegistry.Id) ?*Node {
    if (id.index >= self.slots.items.len) return null;
    const slot = &self.slots.items[id.index];
    if (!slot.active or slot.generation != id.generation) return null;
    return &slot.node;
}

fn nodeConst(self: *const HeadlessSurfaceForest, id: SurfaceRegistry.Id) ?*const Node {
    if (id.index >= self.slots.items.len) return null;
    const slot = &self.slots.items[id.index];
    if (!slot.active or slot.generation != id.generation) return null;
    return &slot.node;
}

fn sameId(first: SurfaceRegistry.Id, second: SurfaceRegistry.Id) bool {
    return first.index == second.index and first.generation == second.generation;
}

fn sameOptionalId(first: ?SurfaceRegistry.Id, second: ?SurfaceRegistry.Id) bool {
    if (first == null or second == null) return first == null and second == null;
    return sameId(first.?, second.?);
}

fn stackEntryEqual(first: StackEntry, second: StackEntry) bool {
    return switch (first) {
        .parent => second == .parent,
        .child => |first_child| switch (second) {
            .parent => false,
            .child => |second_child| sameId(first_child, second_child),
        },
    };
}

fn stackEntryOptionalEqual(first: ?StackEntry, second: ?StackEntry) bool {
    if (first == null or second == null) return first == null and second == null;
    return stackEntryEqual(first.?, second.?);
}

fn saturateI32(value: i64) i32 {
    return @intCast(std.math.clamp(value, std.math.minInt(i32), std.math.maxInt(i32)));
}

fn applyOne(
    forest: *HeadlessSurfaceForest,
    id: SurfaceRegistry.Id,
    mapped_size: ?render.Size,
    callbacks_committed: bool,
) void {
    const surfaces = [_]AppliedSurfaceState{.{
        .id = id,
        .mapped_size = mapped_size,
        .callbacks_committed = callbacks_committed,
    }};
    forest.apply(.{ .surfaces = &surfaces, .parents = &.{} });
}

test "root parity and stale generations use canonical indexed slots" {
    var forest = HeadlessSurfaceForest.init(std.testing.allocator);
    defer forest.deinit();
    const first: SurfaceRegistry.Id = .{ .index = 3, .generation = 7 };
    const second: SurfaceRegistry.Id = .{ .index = 5, .generation = 11 };

    try forest.addRoot(first, null);
    try forest.addRoot(second, null);
    applyOne(&forest, first, .{ .width = 4, .height = 2 }, false);
    try std.testing.expectEqual(first, forest.rootAt(0).?.id);
    try std.testing.expectEqual(second, forest.rootAt(1).?.id);
    try std.testing.expectEqual(render.Size{ .width = 4, .height = 2 }, forest.state(first).?.mapped_size.?);

    forest.remove(first);
    const current: SurfaceRegistry.Id = .{ .index = 3, .generation = 8 };
    try forest.addRoot(current, null);
    try std.testing.expect(forest.state(first) == null);
    try std.testing.expect(forest.state(current) != null);
    forest.remove(second);
    forest.remove(current);
}

test "root presentation progression hides reservations and keeps managed and cursor permanent" {
    var forest = HeadlessSurfaceForest.init(std.testing.allocator);
    defer forest.deinit();
    const managed: SurfaceRegistry.Id = .{ .index = 0, .generation = 1 };
    const cursor: SurfaceRegistry.Id = .{ .index = 1, .generation = 1 };
    try forest.addRoot(managed, null);
    try forest.addRoot(cursor, null);
    applyOne(&forest, managed, .{ .width = 2, .height = 1 }, false);
    applyOne(&forest, cursor, .{ .width = 1, .height = 1 }, false);
    try std.testing.expectEqual(PresentationClass.background, forest.presentationClass(managed).?);

    try std.testing.expect(forest.setRootPresentationClass(managed, .xdg_reserved));
    try std.testing.expectEqual(PresentationClass.xdg_reserved, forest.presentationClass(managed).?);
    try std.testing.expectEqual(CompoundBounds.hidden, forest.compoundBounds(managed));
    try std.testing.expectEqual(
        render.Rect{ .x = 0, .y = 0, .width = 2, .height = 1 },
        forest.subtreeBounds(managed).?,
    );
    var reserved_subtree = forest.subtreeRenderIterator(managed);
    try std.testing.expectEqual(managed, reserved_subtree.next().?.id);
    try std.testing.expect(reserved_subtree.next() == null);

    try std.testing.expect(forest.setRootPresentationClass(managed, .background));
    try std.testing.expect(forest.setRootPresentationClass(managed, .xdg_reserved));
    try std.testing.expect(forest.setRootPresentationClass(managed, .managed));
    inline for (.{ PresentationClass.background, .xdg_reserved, .cursor }) |invalid|
        try std.testing.expect(!forest.setRootPresentationClass(managed, invalid));
    try std.testing.expectEqual(Placement.root, forest.state(managed).?.placement);
    try std.testing.expectEqual(CompoundBounds.hidden, forest.compoundBounds(managed));
    try std.testing.expectEqual(
        render.Rect{ .x = 0, .y = 0, .width = 2, .height = 1 },
        forest.subtreeBounds(managed).?,
    );
    var managed_subtree = forest.subtreeRenderIterator(managed);
    try std.testing.expectEqual(managed, managed_subtree.next().?.id);

    try std.testing.expect(forest.setRootPresentationClass(cursor, .cursor));
    inline for (.{ PresentationClass.background, .xdg_reserved, .managed }) |invalid|
        try std.testing.expect(!forest.setRootPresentationClass(cursor, invalid));
    try std.testing.expect(forest.isCursorRole(cursor));
    try std.testing.expect(!forest.presentedInCompound(cursor, cursor));

    var global = forest.renderIterator();
    try std.testing.expectEqual(cursor, global.next().?.id);
    try std.testing.expect(global.next() == null);
    forest.remove(managed);
    forest.remove(cursor);
}

test "compound roots reject stale removed detached and changed topology" {
    var forest = HeadlessSurfaceForest.init(std.testing.allocator);
    defer forest.deinit();
    var other = HeadlessSurfaceForest.init(std.testing.allocator);
    defer other.deinit();
    const root: SurfaceRegistry.Id = .{ .index = 0, .generation = 1 };
    const child: SurfaceRegistry.Id = .{ .index = 1, .generation = 1 };
    const replacement_root: SurfaceRegistry.Id = .{ .index = 2, .generation = 1 };
    try forest.addRoot(root, null);
    try forest.addRoot(child, null);
    try forest.addRoot(replacement_root, null);
    const initial_stack = [_]AppliedStackEntry{
        .parent,
        .{ .child = .{ .id = child, .position = .{} } },
    };
    forest.apply(.{
        .surfaces = &.{},
        .parents = &.{.{ .id = root, .stack = &initial_stack }},
    });
    try std.testing.expectEqual(root, forest.compoundRoot(child).?);
    try std.testing.expect(other.compoundRoot(child) == null);
    try std.testing.expect(forest.compoundRoot(.{
        .index = child.index,
        .generation = child.generation + 1,
    }) == null);

    const changed_stack = [_]AppliedStackEntry{
        .parent,
        .{ .child = .{ .id = root, .position = .{} } },
    };
    forest.apply(.{
        .surfaces = &.{},
        .parents = &.{.{ .id = replacement_root, .stack = &changed_stack }},
    });
    try std.testing.expectEqual(replacement_root, forest.compoundRoot(child).?);
    forest.detach(root);
    try std.testing.expect(forest.compoundRoot(child) == null);
    forest.remove(child);
    try std.testing.expect(forest.compoundRoot(child) == null);
    forest.remove(root);
    forest.remove(replacement_root);
}

test "input hit follows topmost compound paint order without allocation" {
    const Filter = struct {
        rejected: SurfaceRegistry.Id,

        fn accepts(context: *anyopaque, id: SurfaceRegistry.Id, x: f64, y: f64) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            std.debug.assert(x >= 0 and y >= 0);
            return !sameId(self.rejected, id);
        }
    };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var forest = HeadlessSurfaceForest.init(failing.allocator());
    defer forest.deinit();
    const root: SurfaceRegistry.Id = .{ .index = 0, .generation = 1 };
    const child: SurfaceRegistry.Id = .{ .index = 1, .generation = 1 };
    try forest.addRoot(root, null);
    try forest.addRoot(child, null);
    inline for (.{ root, child }) |id|
        applyOne(&forest, id, .{ .width = 4, .height = 4 }, false);
    const stack = [_]AppliedStackEntry{
        .parent,
        .{ .child = .{ .id = child, .position = .{ .x = 1, .y = 1 } } },
    };
    forest.apply(.{
        .surfaces = &.{},
        .parents = &.{.{ .id = root, .stack = &stack }},
    });
    var filter: Filter = .{ .rejected = root };
    failing.fail_index = failing.alloc_index;
    const hit = forest.inputHit(2, 3, .{
        .context = &filter,
        .accepts = Filter.accepts,
    }).?;
    try std.testing.expectEqual(child, hit.id);
    try std.testing.expectEqual(@as(f64, 1), hit.x);
    try std.testing.expectEqual(@as(f64, 2), hit.y);
    try std.testing.expect(!failing.has_induced_failure);
    forest.remove(root);
    forest.remove(child);
}

test "nested stack paints below parent above with grandchildren and negative positions" {
    var forest = HeadlessSurfaceForest.init(std.testing.allocator);
    defer forest.deinit();
    const root: SurfaceRegistry.Id = .{ .index = 0, .generation = 1 };
    const below: SurfaceRegistry.Id = .{ .index = 1, .generation = 1 };
    const above: SurfaceRegistry.Id = .{ .index = 2, .generation = 1 };
    const grandchild: SurfaceRegistry.Id = .{ .index = 3, .generation = 1 };
    try forest.addRoot(root, null);
    try forest.addRoot(below, null);
    try forest.addRoot(above, null);
    try forest.addRoot(grandchild, null);
    const root_stack = [_]AppliedStackEntry{
        .{ .child = .{ .id = below, .position = .{ .x = -3, .y = 2 } } },
        .parent,
        .{ .child = .{ .id = above, .position = .{ .x = 5, .y = -4 } } },
    };
    const above_stack = [_]AppliedStackEntry{
        .parent,
        .{ .child = .{ .id = grandchild, .position = .{ .x = -2, .y = 3 } } },
    };
    const parents = [_]AppliedParentState{
        .{ .id = root, .stack = &root_stack },
        .{ .id = above, .stack = &above_stack },
    };
    forest.apply(.{ .surfaces = &.{}, .parents = &parents });
    inline for (.{ root, below, above, grandchild }) |id|
        applyOne(&forest, id, .{ .width = 1, .height = 1 }, false);

    var iterator = forest.renderIterator();
    const first = iterator.next().?;
    const second = iterator.next().?;
    const third = iterator.next().?;
    const fourth = iterator.next().?;
    try std.testing.expectEqual(below, first.id);
    try std.testing.expectEqual(Position{ .x = -3, .y = 2 }, first.position);
    try std.testing.expectEqual(root, second.id);
    try std.testing.expectEqual(above, third.id);
    try std.testing.expectEqual(Position{ .x = 5, .y = -4 }, third.position);
    try std.testing.expectEqual(grandchild, fourth.id);
    try std.testing.expectEqual(Position{ .x = 3, .y = -1 }, fourth.position);
    try std.testing.expect(iterator.next() == null);

    forest.remove(root);
    forest.remove(below);
    forest.remove(above);
    forest.remove(grandchild);
}

test "recursive mapping hides descendants and children remain unclipped" {
    var forest = HeadlessSurfaceForest.init(std.testing.allocator);
    defer forest.deinit();
    const root: SurfaceRegistry.Id = .{ .index = 0, .generation = 1 };
    const child: SurfaceRegistry.Id = .{ .index = 1, .generation = 1 };
    try forest.addRoot(root, null);
    try forest.addRoot(child, null);
    const stack = [_]AppliedStackEntry{
        .parent,
        .{ .child = .{ .id = child, .position = .{ .x = 8, .y = 0 } } },
    };
    const parents = [_]AppliedParentState{.{ .id = root, .stack = &stack }};
    forest.apply(.{ .surfaces = &.{}, .parents = &parents });
    applyOne(&forest, child, .{ .width = 3, .height = 2 }, false);
    var hidden_iterator = forest.renderIterator();
    try std.testing.expect(hidden_iterator.next() == null);
    applyOne(&forest, root, .{ .width = 1, .height = 1 }, false);
    try std.testing.expectEqual(
        render.Rect{ .x = 0, .y = 0, .width = 11, .height = 2 },
        forest.compoundBounds(root).rect,
    );
    applyOne(&forest, root, null, false);
    try std.testing.expectEqual(CompoundBounds.hidden, forest.compoundBounds(child));
    forest.remove(root);
    forest.remove(child);
}

test "detach reattach restack position and parent removal preserve descendants" {
    var forest = HeadlessSurfaceForest.init(std.testing.allocator);
    defer forest.deinit();
    const root: SurfaceRegistry.Id = .{ .index = 0, .generation = 1 };
    const child: SurfaceRegistry.Id = .{ .index = 1, .generation = 1 };
    const grandchild: SurfaceRegistry.Id = .{ .index = 2, .generation = 1 };
    try forest.addRoot(root, null);
    try forest.addRoot(child, null);
    try forest.addRoot(grandchild, null);
    const child_stack = [_]AppliedStackEntry{
        .{ .child = .{ .id = grandchild, .position = .{ .x = 1 } } },
        .parent,
    };
    var root_stack = [_]AppliedStackEntry{
        .parent,
        .{ .child = .{ .id = child, .position = .{ .x = 2 } } },
    };
    var parents = [_]AppliedParentState{
        .{ .id = child, .stack = &child_stack },
        .{ .id = root, .stack = &root_stack },
    };
    forest.apply(.{ .surfaces = &.{}, .parents = &parents });
    forest.detach(child);
    try std.testing.expectEqual(Placement.detached, forest.state(child).?.placement);
    try std.testing.expect(std.meta.eql(
        Placement{ .child = .{ .parent = child, .position = .{ .x = 1 } } },
        forest.state(grandchild).?.placement,
    ));

    root_stack = .{
        .{ .child = .{ .id = child, .position = .{ .x = -4, .y = 3 } } },
        .parent,
    };
    parents[1].stack = &root_stack;
    forest.apply(.{ .surfaces = &.{}, .parents = parents[1..2] });
    try std.testing.expectEqual(@as(usize, 0), forest.rootIndex(root).?);
    forest.remove(root);
    try std.testing.expectEqual(Placement.detached, forest.state(child).?.placement);
    try std.testing.expect(forest.state(grandchild) != null);
    try std.testing.expectEqual(@as(usize, 0), forest.rootLen());
    forest.remove(child);
    try std.testing.expectEqual(Placement.detached, forest.state(grandchild).?.placement);
    forest.remove(grandchild);
}

test "per-node frame demand OR latches and clears before callback" {
    const Completion = struct {
        forest: *HeadlessSurfaceForest,
        cleared: bool = false,

        fn complete(context: *anyopaque, id: SurfaceRegistry.Id, _: u32) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.cleared = !self.forest.state(id).?.frame_demand;
        }
    };
    const id: SurfaceRegistry.Id = .{ .index = 3, .generation = 7 };
    var forest = HeadlessSurfaceForest.init(std.testing.allocator);
    defer forest.deinit();
    var completion: Completion = .{ .forest = &forest };
    try forest.addRoot(id, .{ .context = &completion, .complete = Completion.complete });
    applyOne(&forest, id, .{ .width = 2, .height = 1 }, true);
    applyOne(&forest, id, null, false);
    try std.testing.expect(forest.state(id).?.frame_demand);
    const thunk = forest.takeFrameCompletion(id).?;
    thunk.complete(thunk.context, id, 1);
    try std.testing.expect(completion.cleared);
    forest.remove(id);
}

test "hostile deep traversal and bounds avoid recursion" {
    var forest = HeadlessSurfaceForest.init(std.testing.allocator);
    defer forest.deinit();
    const depth = 2048;
    var index: usize = 0;
    while (index < depth) : (index += 1) {
        const id: SurfaceRegistry.Id = .{ .index = @intCast(index), .generation = 1 };
        try forest.addRoot(id, null);
        applyOne(&forest, id, .{ .width = 1, .height = 1 }, false);
    }
    index = 0;
    while (index + 1 < depth) : (index += 1) {
        const parent: SurfaceRegistry.Id = .{ .index = @intCast(index), .generation = 1 };
        const child: SurfaceRegistry.Id = .{ .index = @intCast(index + 1), .generation = 1 };
        const stack = [_]AppliedStackEntry{
            .parent,
            .{ .child = .{ .id = child, .position = .{ .x = 1 } } },
        };
        const parents = [_]AppliedParentState{.{ .id = parent, .stack = &stack }};
        forest.apply(.{ .surfaces = &.{}, .parents = &parents });
    }
    const root: SurfaceRegistry.Id = .{ .index = 0, .generation = 1 };
    try std.testing.expectEqual(
        render.Rect{ .x = 0, .y = 0, .width = depth, .height = 1 },
        forest.compoundBounds(root).rect,
    );
    var rendered: usize = 0;
    var iterator = forest.renderIterator();
    while (iterator.next() != null) rendered += 1;
    try std.testing.expectEqual(@as(usize, depth), rendered);
    index = 0;
    while (index < depth) : (index += 1)
        forest.remove(.{ .index = @intCast(index), .generation = 1 });
}

test "coordinate overflow requests full damage" {
    var forest = HeadlessSurfaceForest.init(std.testing.allocator);
    defer forest.deinit();
    const root: SurfaceRegistry.Id = .{ .index = 0, .generation = 1 };
    const child: SurfaceRegistry.Id = .{ .index = 1, .generation = 1 };
    const grandchild: SurfaceRegistry.Id = .{ .index = 2, .generation = 1 };
    try forest.addRoot(root, null);
    try forest.addRoot(child, null);
    try forest.addRoot(grandchild, null);
    inline for (.{ root, child, grandchild }) |id|
        applyOne(&forest, id, .{ .width = 1, .height = 1 }, false);
    const root_stack = [_]AppliedStackEntry{
        .parent,
        .{ .child = .{ .id = child, .position = .{ .x = std.math.maxInt(i32) } } },
    };
    const child_stack = [_]AppliedStackEntry{
        .parent,
        .{ .child = .{ .id = grandchild, .position = .{ .x = 1 } } },
    };
    const parents = [_]AppliedParentState{
        .{ .id = root, .stack = &root_stack },
        .{ .id = child, .stack = &child_stack },
    };
    forest.apply(.{ .surfaces = &.{}, .parents = &parents });
    try std.testing.expectEqual(CompoundBounds.full_damage, forest.compoundBounds(root));
    forest.remove(root);
    forest.remove(child);
    forest.remove(grandchild);
}

test "failed growth leaves existing topology unchanged" {
    var storage: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var forest = HeadlessSurfaceForest.init(fixed.allocator());
    defer forest.deinit();
    const root: SurfaceRegistry.Id = .{ .index = 0, .generation = 1 };
    try forest.addRoot(root, null);
    applyOne(&forest, root, .{ .width = 2, .height = 3 }, false);
    const before = forest.state(root).?;
    try std.testing.expectError(
        error.OutOfMemory,
        forest.addRoot(.{ .index = 4096, .generation = 1 }, null),
    );
    try std.testing.expectEqual(before, forest.state(root).?);
    try std.testing.expectEqual(@as(usize, 1), forest.len());
    forest.validate();
    forest.remove(root);
}

test "subtree iterator preserves nested stack order and rejects stale roots" {
    var forest = HeadlessSurfaceForest.init(std.testing.allocator);
    defer forest.deinit();
    const root: SurfaceRegistry.Id = .{ .index = 0, .generation = 1 };
    const below: SurfaceRegistry.Id = .{ .index = 1, .generation = 1 };
    const above: SurfaceRegistry.Id = .{ .index = 2, .generation = 1 };
    const nested: SurfaceRegistry.Id = .{ .index = 3, .generation = 1 };
    inline for (.{ root, below, above, nested }) |id| {
        try forest.addRoot(id, null);
        applyOne(&forest, id, .{ .width = 2, .height = 2 }, false);
    }
    const root_stack = [_]AppliedStackEntry{
        .{ .child = .{ .id = below, .position = .{ .x = -3, .y = 4 } } },
        .parent,
        .{ .child = .{ .id = above, .position = .{ .x = 5, .y = 6 } } },
    };
    const below_stack = [_]AppliedStackEntry{
        .parent,
        .{ .child = .{ .id = nested, .position = .{ .x = 7, .y = -2 } } },
    };
    const parents = [_]AppliedParentState{
        .{ .id = root, .stack = &root_stack },
        .{ .id = below, .stack = &below_stack },
    };
    forest.apply(.{ .surfaces = &.{}, .parents = &parents });

    const expected_ids = [_]SurfaceRegistry.Id{ below, nested, root, above };
    const expected_positions = [_]Position{
        .{ .x = -3, .y = 4 }, .{ .x = 4, .y = 2 }, .{}, .{ .x = 5, .y = 6 },
    };
    var iterator = forest.subtreeRenderIterator(root);
    for (expected_ids, expected_positions) |id, position| {
        const entry = iterator.next().?;
        try std.testing.expectEqual(id, entry.id);
        try std.testing.expectEqual(position, entry.position);
    }
    try std.testing.expect(iterator.next() == null);

    forest.detach(root);
    var detached_iterator = forest.subtreeRenderIterator(root);
    try std.testing.expect(detached_iterator.next() == null);
    inline for (.{ root, below, above, nested }) |id| forest.remove(id);
    try forest.addRoot(.{ .index = 0, .generation = 2 }, null);
    var stale_iterator = forest.subtreeRenderIterator(root);
    try std.testing.expect(stale_iterator.next() == null);
    forest.remove(.{ .index = 0, .generation = 2 });
}
