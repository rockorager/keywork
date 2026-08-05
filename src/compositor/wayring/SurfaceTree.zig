//! Protocol-neutral retained surface hierarchy and atomic scene updates.

const SurfaceTree = @This();

const std = @import("std");
const CompositorGlobal = @import("CompositorGlobal.zig");

pub const Surface = CompositorGlobal.Surface;

allocator: std.mem.Allocator,
nodes: std.ArrayList(*Node) = .empty,
redraw_needed: bool = false,

pub const Position = struct { x: i32 = 0, y: i32 = 0 };
pub const CommitMode = enum { parent, own };

pub const Node = struct {
    surface: *Surface,
    parent: ?*Node = null,
    current_children: std.ArrayList(*Node) = .empty,
    pending_children: std.ArrayList(*Node) = .empty,
    current_marker: usize = 0,
    pending_marker: usize = 0,
    current_position: Position = .{},
    pending_position: Position = .{},
    current_active: bool = false,
    pending_active: bool = false,
    link_serial: u64 = 0,
    commit_mode: CommitMode = .own,
};

pub const CapturedRelation = struct {
    node: *Node,
    position: Position,
    active: bool,
    link_serial: u64,
};

pub const Update = struct {
    allocator: std.mem.Allocator,
    parent: *Node,
    children: []*Node,
    marker: usize,
    relations: []CapturedRelation,

    pub fn apply(self: *Update) void {
        self.parent.current_children.clearRetainingCapacity();
        self.parent.current_marker = 0;
        for (self.children, self.relations, 0..) |child, relation, index| {
            if (child.parent != self.parent or child.link_serial != relation.link_serial) continue;
            self.parent.current_children.appendAssumeCapacity(child);
            if (index < self.marker) self.parent.current_marker += 1;
        }
        for (self.relations) |relation| {
            if (relation.node.parent != self.parent or relation.node.link_serial != relation.link_serial) continue;
            relation.node.current_position = relation.position;
            relation.node.current_active = relation.active;
        }
    }

    pub fn deinit(self: *Update) void {
        self.allocator.free(self.children);
        self.allocator.free(self.relations);
        self.* = undefined;
    }
};

pub const PaintEntry = struct { surface: *Surface, x: i32, y: i32 };

pub const DirectUpdate = struct {
    node: *Node,
    parent: ?*Node,
    link_serial: u64,
    position: Position,
    active: bool,

    pub fn isCurrent(self: DirectUpdate) bool {
        return self.node.parent == self.parent and self.node.link_serial == self.link_serial;
    }

    pub fn apply(self: DirectUpdate) void {
        if (!self.isCurrent()) return;
        if (self.parent) |parent| {
            if (std.mem.indexOfScalar(*Node, parent.current_children.items, self.node) == null)
                parent.current_children.appendAssumeCapacity(self.node);
        }
        self.node.current_position = self.position;
        self.node.current_active = self.active;
    }
};

pub fn init(allocator: std.mem.Allocator) SurfaceTree {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *SurfaceTree) void {
    for (self.nodes.items) |node| {
        node.current_children.deinit(self.allocator);
        node.pending_children.deinit(self.allocator);
        node.surface.unreference();
        self.allocator.destroy(node);
    }
    self.nodes.deinit(self.allocator);
    self.* = undefined;
}

pub fn nodeFor(self: *SurfaceTree, surface: *Surface) !*Node {
    if (self.find(surface)) |node| return node;
    const node = try self.allocator.create(Node);
    errdefer self.allocator.destroy(node);
    try surface.reference();
    errdefer surface.unreference();
    node.* = .{ .surface = surface };
    try self.nodes.append(self.allocator, node);
    return node;
}

pub fn find(self: *const SurfaceTree, surface: *const Surface) ?*Node {
    for (self.nodes.items) |node| if (node.surface == surface) return node;
    return null;
}

pub fn root(node: *Node) *Node {
    var result = node;
    while (result.parent) |parent| result = parent;
    return result;
}

pub fn globalPosition(node: *const Node) Position {
    var position: Position = .{};
    var cursor: ?*const Node = node;
    while (cursor) |current| : (cursor = current.parent) {
        position.x +|= current.current_position.x;
        position.y +|= current.current_position.y;
    }
    return position;
}

pub fn wouldCycle(child: *Node, parent: *Node) bool {
    var cursor: ?*Node = parent;
    while (cursor) |node| : (cursor = node.parent) if (node == child) return true;
    return false;
}

pub fn attach(self: *SurfaceTree, child: *Node, parent: *Node, commit_mode: CommitMode) !void {
    if (child == parent or child.parent != null or wouldCycle(child, parent)) return error.InvalidParent;
    try parent.pending_children.append(self.allocator, child);
    self.redraw_needed = self.redraw_needed or child.current_active;
    child.link_serial +%= 1;
    child.parent = parent;
    child.commit_mode = commit_mode;
    child.pending_active = false;
    child.current_active = false;
}

pub fn activateRoot(node: *Node) void {
    if (node.parent != null) return;
    node.pending_active = true;
    node.current_active = true;
}

pub fn isSiblingOrParent(child: *const Node, reference: *const Node) bool {
    const parent = child.parent orelse return false;
    return reference == parent or reference.parent == parent;
}

pub fn setPosition(node: *Node, x: i32, y: i32) void {
    node.pending_position = .{ .x = x, .y = y };
}

pub fn place(node: *Node, reference: *Node, above: bool) !void {
    const parent = node.parent orelse return error.Inert;
    if (!isSiblingOrParent(node, reference) or reference == node) return error.InvalidSibling;
    const old = std.mem.indexOfScalar(*Node, parent.pending_children.items, node) orelse return error.Inert;
    _ = parent.pending_children.orderedRemove(old);
    if (old < parent.pending_marker) parent.pending_marker -= 1;
    if (reference == parent) {
        parent.pending_children.insertAssumeCapacity(parent.pending_marker, node);
        if (!above) parent.pending_marker += 1;
        return;
    }
    const reference_index = std.mem.indexOfScalar(*Node, parent.pending_children.items, reference) orelse return error.InvalidSibling;
    const reference_below = reference_index < parent.pending_marker;
    var index = reference_index;
    if (above) index += 1;
    parent.pending_children.insertAssumeCapacity(index, node);
    if (reference_below) parent.pending_marker += 1;
}

pub fn capture(self: *SurfaceTree, parent: *Node) !Update {
    const children = try self.allocator.dupe(*Node, parent.pending_children.items);
    errdefer self.allocator.free(children);
    const relations = try self.allocator.alloc(CapturedRelation, children.len);
    errdefer self.allocator.free(relations);
    for (children, relations) |child, *relation| {
        relation.* = .{
            .node = child,
            .position = if (child.commit_mode == .parent)
                child.pending_position
            else
                child.current_position,
            .active = if (child.commit_mode == .parent) true else child.current_active,
            .link_serial = child.link_serial,
        };
        if (child.commit_mode == .parent) child.pending_active = true;
    }
    try parent.current_children.ensureTotalCapacity(self.allocator, children.len);
    return .{ .allocator = self.allocator, .parent = parent, .children = children, .marker = parent.pending_marker, .relations = relations };
}

pub fn captureDirect(self: *SurfaceTree, node: *Node, position: Position, active: bool) !DirectUpdate {
    if (node.parent) |parent|
        try parent.current_children.ensureTotalCapacity(self.allocator, parent.pending_children.items.len);
    return .{
        .node = node,
        .parent = node.parent,
        .link_serial = node.link_serial,
        .position = position,
        .active = active,
    };
}

pub fn detach(self: *SurfaceTree, node: *Node) void {
    self.redraw_needed = self.redraw_needed or node.current_active;
    if (node.parent) |parent| {
        removeChild(&parent.pending_children, &parent.pending_marker, node);
        removeChild(&parent.current_children, &parent.current_marker, node);
    }
    node.link_serial +%= 1;
    node.parent = null;
    node.commit_mode = .own;
    node.current_position = .{};
    node.pending_position = .{};
    self.deactivate(node);
}

pub fn needsRedraw(self: *const SurfaceTree) bool {
    return self.redraw_needed;
}

pub fn redrawHandled(self: *SurfaceTree) void {
    self.redraw_needed = false;
}

pub fn deactivateNow(self: *SurfaceTree, node: *Node) void {
    self.redraw_needed = self.redraw_needed or node.current_active;
    node.link_serial +%= 1;
    self.deactivate(node);
}

fn deactivate(self: *SurfaceTree, node: *Node) void {
    node.pending_active = false;
    node.current_active = false;
    for (node.pending_children.items) |child| self.deactivate(child);
    for (node.current_children.items) |child| {
        if (std.mem.indexOfScalar(*Node, node.pending_children.items, child) == null) self.deactivate(child);
    }
}

fn removeChild(children: *std.ArrayList(*Node), marker: *usize, child: *Node) void {
    const index = std.mem.indexOfScalar(*Node, children.items, child) orelse return;
    _ = children.orderedRemove(index);
    if (index < marker.*) marker.* -= 1;
}

pub fn paint(self: *const SurfaceTree, root_node: *Node, output: *std.ArrayList(PaintEntry)) !void {
    _ = self;
    try paintRecursive(root_node, 0, 0, output, root_node.surface.allocator);
}

fn paintRecursive(node: *Node, parent_x: i32, parent_y: i32, output: *std.ArrayList(PaintEntry), allocator: std.mem.Allocator) !void {
    if (!node.current_active) return;
    const x = parent_x +| node.current_position.x;
    const y = parent_y +| node.current_position.y;
    for (node.current_children.items[0..node.current_marker]) |child| try paintRecursive(child, x, y, output, allocator);
    try output.append(allocator, .{ .surface = node.surface, .x = x, .y = y });
    for (node.current_children.items[node.current_marker..]) |child| try paintRecursive(child, x, y, output, allocator);
}

test "capture applies position and exact below-parent-above traversal" {
    // Surface ownership is tested through SubcompositorGlobal; keep this test
    // structural by using aligned sentinel surfaces.
    const a: *Surface = @ptrFromInt(0x1000);
    const b: *Surface = @ptrFromInt(0x2000);
    const c: *Surface = @ptrFromInt(0x3000);
    var root_node: Node = .{ .surface = a, .current_active = true };
    var below: Node = .{ .surface = b, .parent = &root_node, .current_position = .{ .x = 2, .y = 3 }, .current_active = true };
    var above: Node = .{ .surface = c, .parent = &root_node, .current_position = .{ .x = 5, .y = 7 }, .current_active = true };
    try root_node.current_children.append(std.testing.allocator, &below);
    defer root_node.current_children.deinit(std.testing.allocator);
    try root_node.current_children.append(std.testing.allocator, &above);
    root_node.current_marker = 1;
    var entries: std.ArrayList(PaintEntry) = .empty;
    defer entries.deinit(std.testing.allocator);
    try paintRecursive(&root_node, 10, 20, &entries, std.testing.allocator);
    try std.testing.expectEqualSlices(*Surface, &.{ b, a, c }, &.{ entries.items[0].surface, entries.items[1].surface, entries.items[2].surface });
    try std.testing.expectEqual(Position{ .x = 12, .y = 23 }, Position{ .x = entries.items[0].x, .y = entries.items[0].y });
}

test "default above and parent partition placement are exact" {
    const surface: *Surface = @ptrFromInt(0x1000);
    var parent: Node = .{ .surface = surface, .current_active = true };
    var first: Node = .{ .surface = @ptrFromInt(0x2000), .parent = &parent };
    var second: Node = .{ .surface = @ptrFromInt(0x3000), .parent = &parent };
    defer parent.pending_children.deinit(std.testing.allocator);
    try parent.pending_children.append(std.testing.allocator, &first);
    try parent.pending_children.append(std.testing.allocator, &second);
    try std.testing.expectEqualSlices(*Node, &.{ &first, &second }, parent.pending_children.items);
    try place(&second, &parent, false);
    try std.testing.expectEqual(@as(usize, 1), parent.pending_marker);
    try std.testing.expectEqualSlices(*Node, &.{ &second, &first }, parent.pending_children.items);
    try place(&second, &parent, true);
    try std.testing.expectEqual(@as(usize, 0), parent.pending_marker);
    try std.testing.expectEqualSlices(*Node, &.{ &second, &first }, parent.pending_children.items);
}

test "capture is immediate allocation-free apply and nested paint accumulates coordinates" {
    const surface: *Surface = @ptrFromInt(0x1000);
    var tree = init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);
    var parent: Node = .{ .surface = surface, .current_active = true };
    var child: Node = .{
        .surface = @ptrFromInt(0x2000),
        .parent = &parent,
        .pending_position = .{ .x = 3, .y = 5 },
        .current_active = false,
        .commit_mode = .parent,
    };
    var grandchild: Node = .{ .surface = @ptrFromInt(0x3000), .parent = &child, .current_position = .{ .x = 7, .y = 11 }, .current_active = true };
    defer parent.pending_children.deinit(std.testing.allocator);
    defer parent.current_children.deinit(std.testing.allocator);
    defer child.current_children.deinit(std.testing.allocator);
    try parent.pending_children.append(std.testing.allocator, &child);
    try child.current_children.append(std.testing.allocator, &grandchild);
    var update = try tree.capture(&parent);
    defer update.deinit();
    try std.testing.expectEqual(Position{}, child.current_position);
    update.apply();
    try std.testing.expectEqual(Position{ .x = 3, .y = 5 }, child.current_position);
    try std.testing.expectEqual(@as(usize, 1), child.current_children.items.len);
    var entries: std.ArrayList(PaintEntry) = .empty;
    defer entries.deinit(std.testing.allocator);
    try paintRecursive(&parent, 0, 0, &entries, std.testing.allocator);
    try std.testing.expectEqual(Position{ .x = 10, .y = 16 }, Position{ .x = entries.items[2].x, .y = entries.items[2].y });
}

test "root and cycle detection follow pending ancestry" {
    var parent: Node = .{ .surface = @ptrFromInt(0x1000) };
    var child: Node = .{ .surface = @ptrFromInt(0x2000), .parent = &parent };
    var grandchild: Node = .{ .surface = @ptrFromInt(0x3000), .parent = &child };
    try std.testing.expect(root(&grandchild) == &parent);
    try std.testing.expect(wouldCycle(&parent, &grandchild));
    try std.testing.expect(!wouldCycle(&grandchild, &parent));
}

test "parent capture applies subsurfaces without disturbing own-commit popups" {
    var tree = init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);
    var parent: Node = .{ .surface = @ptrFromInt(0x1000), .current_active = true };
    var subsurface: Node = .{
        .surface = @ptrFromInt(0x2000),
        .parent = &parent,
        .pending_position = .{ .x = 7, .y = 9 },
        .commit_mode = .parent,
    };
    var popup: Node = .{
        .surface = @ptrFromInt(0x3000),
        .parent = &parent,
        .current_position = .{ .x = 11, .y = 13 },
        .pending_position = .{ .x = 101, .y = 103 },
        .current_active = true,
        .commit_mode = .own,
    };
    defer parent.pending_children.deinit(std.testing.allocator);
    defer parent.current_children.deinit(std.testing.allocator);
    try parent.pending_children.append(std.testing.allocator, &subsurface);
    try parent.pending_children.append(std.testing.allocator, &popup);

    var update = try tree.capture(&parent);
    defer update.deinit();
    update.apply();

    try std.testing.expectEqual(Position{ .x = 7, .y = 9 }, subsurface.current_position);
    try std.testing.expect(subsurface.current_active);
    try std.testing.expectEqual(Position{ .x = 11, .y = 13 }, popup.current_position);
    try std.testing.expect(popup.current_active);
}

test "direct updates reserve shared capacity and reject stale hierarchy generations" {
    var tree = init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);
    var parent: Node = .{ .surface = @ptrFromInt(0x1000), .current_active = true };
    var first: Node = .{ .surface = @ptrFromInt(0x2000), .parent = &parent, .link_serial = 1 };
    var second: Node = .{ .surface = @ptrFromInt(0x3000), .parent = &parent, .link_serial = 1 };
    defer parent.pending_children.deinit(std.testing.allocator);
    defer parent.current_children.deinit(std.testing.allocator);
    try parent.pending_children.append(std.testing.allocator, &first);
    try parent.pending_children.append(std.testing.allocator, &second);

    const first_update = try tree.captureDirect(&first, .{ .x = 2, .y = 3 }, true);
    const second_update = try tree.captureDirect(&second, .{ .x = 5, .y = 7 }, true);
    try std.testing.expect(first_update.isCurrent());
    try std.testing.expect(second_update.isCurrent());
    first_update.apply();
    second_update.apply();
    try std.testing.expectEqualSlices(*Node, &.{ &first, &second }, parent.current_children.items);

    const stale = try tree.captureDirect(&first, .{ .x = 17, .y = 19 }, false);
    tree.deactivateNow(&first);
    try std.testing.expect(!stale.isCurrent());
    stale.apply();
    try std.testing.expectEqual(Position{ .x = 2, .y = 3 }, first.current_position);
    try std.testing.expect(!first.current_active);
}

test "captured parent updates cannot reactivate invalidated own-commit children" {
    var tree = init(std.testing.allocator);
    defer tree.nodes.deinit(std.testing.allocator);
    var parent: Node = .{ .surface = @ptrFromInt(0x1000), .current_active = true };
    var popup: Node = .{
        .surface = @ptrFromInt(0x2000),
        .parent = &parent,
        .current_active = true,
        .commit_mode = .own,
        .link_serial = 1,
    };
    defer parent.pending_children.deinit(std.testing.allocator);
    defer parent.current_children.deinit(std.testing.allocator);
    try parent.pending_children.append(std.testing.allocator, &popup);
    try parent.current_children.append(std.testing.allocator, &popup);

    var update = try tree.capture(&parent);
    defer update.deinit();
    tree.deactivateNow(&popup);
    update.apply();

    try std.testing.expect(!popup.current_active);
    try std.testing.expectEqual(@as(usize, 0), parent.current_children.items.len);
}

test "inactive roots suppress active descendants" {
    var root_node: Node = .{ .surface = @ptrFromInt(0x1000), .current_active = false };
    var child: Node = .{
        .surface = @ptrFromInt(0x2000),
        .parent = &root_node,
        .current_active = true,
    };
    defer root_node.current_children.deinit(std.testing.allocator);
    try root_node.current_children.append(std.testing.allocator, &child);
    var entries: std.ArrayList(PaintEntry) = .empty;
    defer entries.deinit(std.testing.allocator);
    try paintRecursive(&root_node, 0, 0, &entries, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), entries.items.len);
}
