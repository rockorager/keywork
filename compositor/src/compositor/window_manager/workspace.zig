//! Workspace membership, ordering, focus, and classification tags.

const std = @import("std");
const layout_mod = @import("layout.zig");
const types = @import("types.zig");

pub const TagSet = struct {
    items: std.ArrayList(types.TagId) = .empty,

    pub fn deinit(self: *TagSet, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
    }

    pub fn contains(self: *const TagSet, tag: types.TagId) bool {
        return std.mem.indexOfScalar(types.TagId, self.items.items, tag) != null;
    }

    pub fn add(self: *TagSet, allocator: std.mem.Allocator, tag: types.TagId) !bool {
        if (self.contains(tag)) return false;
        try self.items.append(allocator, tag);
        return true;
    }

    pub fn remove(self: *TagSet, tag: types.TagId) bool {
        const index = std.mem.indexOfScalar(types.TagId, self.items.items, tag) orelse return false;
        _ = self.items.orderedRemove(index);
        return true;
    }
};

pub const Workspace = struct {
    layout: layout_mod.Layout = .init(.tiled),
    members: std.ArrayList(types.WindowId) = .empty,
    /// Least- to most-recently focused member order.
    focus_history: std.ArrayList(types.WindowId) = .empty,
    focused: ?types.WindowId = null,

    pub fn deinit(self: *Workspace, allocator: std.mem.Allocator) void {
        self.layout.deinit(allocator);
        self.members.deinit(allocator);
        self.focus_history.deinit(allocator);
    }

    pub fn contains(self: *const Workspace, id: types.WindowId) bool {
        return self.indexOf(id) != null;
    }

    pub fn insert(self: *Workspace, allocator: std.mem.Allocator, id: types.WindowId) !bool {
        if (self.contains(id)) return false;
        try self.ensureInsertCapacity(allocator, 1);
        try self.layout.windowAdded(allocator, id, self.focused);
        self.addMemberAssumeCapacity(id);
        return true;
    }

    pub fn remove(self: *Workspace, id: types.WindowId) bool {
        const index = self.indexOf(id) orelse return false;
        const history_index = self.focusHistoryIndex(id) orelse unreachable;
        const was_focused = self.focused != null and self.focused.?.eql(id);
        _ = self.focus_history.orderedRemove(history_index);
        const next_focus = if (was_focused and self.focus_history.items.len != 0)
            self.focus_history.items[self.focus_history.items.len - 1]
        else if (was_focused)
            null
        else
            self.focused;
        self.layout.windowRemoved(id);
        _ = self.members.orderedRemove(index);
        self.focused = if (self.members.items.len == 0) null else next_focus;
        std.debug.assert(self.members.items.len == self.focus_history.items.len);
        return true;
    }

    pub fn focus(self: *Workspace, id: types.WindowId) bool {
        const history_index = self.focusHistoryIndex(id) orelse return false;
        const focused = self.focus_history.orderedRemove(history_index);
        self.focus_history.appendAssumeCapacity(focused);
        self.focused = id;
        return true;
    }

    pub fn raise(self: *Workspace, id: types.WindowId) bool {
        const index = self.indexOf(id) orelse return false;
        const value = self.members.orderedRemove(index);
        self.members.appendAssumeCapacity(value);
        return true;
    }

    pub fn moveWindow(allocator: std.mem.Allocator, from: *Workspace, to: *Workspace, id: types.WindowId) !bool {
        if (!from.contains(id) or to.contains(id)) return false;
        try to.ensureInsertCapacity(allocator, 1);
        const was_focused = from.focused != null and from.focused.?.eql(id);
        try to.layout.windowAdded(allocator, id, to.focused);
        std.debug.assert(from.remove(id));
        to.addMemberAssumeCapacity(id);
        if (was_focused) std.debug.assert(to.focus(id));
        return true;
    }

    pub fn ensureInsertCapacity(
        self: *Workspace,
        allocator: std.mem.Allocator,
        additional_count: usize,
    ) error{OutOfMemory}!void {
        try self.members.ensureUnusedCapacity(allocator, additional_count);
        try self.focus_history.ensureUnusedCapacity(allocator, additional_count);
        try self.layout.ensureWindowCapacity(allocator, additional_count);
    }

    pub fn setLayout(
        self: *Workspace,
        allocator: std.mem.Allocator,
        kind: layout_mod.Kind,
        usable: ?types.Rect,
    ) error{OutOfMemory}!void {
        var replacement: layout_mod.Layout = .init(kind);
        errdefer replacement.deinit(allocator);
        if (usable) |area| replacement.setUsableArea(area);
        try replacement.ensureWindowCapacity(allocator, self.members.items.len);
        var insertion_focus: ?types.WindowId = null;
        for (self.members.items) |id| {
            try replacement.windowAdded(allocator, id, insertion_focus);
            insertion_focus = id;
        }
        self.layout.deinit(allocator);
        self.layout = replacement;
    }

    pub fn nextWindow(
        self: *const Workspace,
        current: types.WindowId,
        reverse: bool,
    ) ?types.WindowId {
        if (self.layout.usesTreeOrder()) return self.layout.nextWindow(current, reverse);
        const current_index = self.indexOf(current) orelse return null;
        const next_index = if (reverse)
            (current_index + self.members.items.len - 1) % self.members.items.len
        else
            (current_index + 1) % self.members.items.len;
        return self.members.items[next_index];
    }

    pub fn swapWindows(self: *Workspace, first: types.WindowId, second: types.WindowId) bool {
        const first_index = self.indexOf(first) orelse return false;
        const second_index = self.indexOf(second) orelse return false;
        self.layout.swapWindows(first, second);
        std.mem.swap(types.WindowId, &self.members.items[first_index], &self.members.items[second_index]);
        return true;
    }

    pub fn repositionWindow(
        self: *Workspace,
        source: types.WindowId,
        target: types.WindowId,
        position: layout_mod.DropPosition,
    ) bool {
        if (source.eql(target)) return false;
        const source_index = self.indexOf(source) orelse return false;
        if (!self.contains(target)) return false;
        if (position == .center) return self.swapWindows(source, target);

        self.layout.repositionWindow(source, target, position);
        const moved = self.members.orderedRemove(source_index);
        const target_index = self.indexOf(target) orelse unreachable;
        const after = position == .right or position == .bottom;
        self.members.insertAssumeCapacity(target_index + @intFromBool(after), moved);
        return true;
    }

    pub fn repositionWindowAtRoot(
        self: *Workspace,
        source: types.WindowId,
        position: layout_mod.DropPosition,
    ) bool {
        std.debug.assert(position == .left or position == .right);
        if (self.members.items.len < 2) return false;
        const source_index = self.indexOf(source) orelse return false;
        self.layout.repositionWindowAtRoot(source, position);
        const moved = self.members.orderedRemove(source_index);
        if (position == .left) {
            self.members.insertAssumeCapacity(0, moved);
        } else {
            self.members.appendAssumeCapacity(moved);
        }
        return true;
    }

    fn indexOf(self: *const Workspace, id: types.WindowId) ?usize {
        for (self.members.items, 0..) |candidate, index| if (candidate.eql(id)) return index;
        return null;
    }

    fn focusHistoryIndex(self: *const Workspace, id: types.WindowId) ?usize {
        for (self.focus_history.items, 0..) |candidate, index| if (candidate.eql(id)) return index;
        return null;
    }

    fn addMemberAssumeCapacity(self: *Workspace, id: types.WindowId) void {
        self.members.appendAssumeCapacity(id);
        if (self.focused == null) {
            self.focus_history.appendAssumeCapacity(id);
            self.focused = id;
        } else {
            // An inserted but not-yet-focused member must not displace the
            // workspace's actual last-focused window.
            self.focus_history.insertAssumeCapacity(0, id);
        }
        std.debug.assert(self.members.items.len == self.focus_history.items.len);
    }
};

test "tag set prevents duplicates and removes tags" {
    var tags: TagSet = .{};
    defer tags.deinit(std.testing.allocator);
    try std.testing.expect(try tags.add(std.testing.allocator, 42));
    try std.testing.expect(!(try tags.add(std.testing.allocator, 42)));
    try std.testing.expect(try tags.add(std.testing.allocator, 1000));
    try std.testing.expectEqual(@as(usize, 2), tags.items.items.len);
    try std.testing.expect(tags.remove(42));
    try std.testing.expect(!tags.contains(42));
    try std.testing.expect(!tags.remove(42));
}

test "workspace membership move focus and order have single ownership" {
    var first: Workspace = .{};
    defer first.deinit(std.testing.allocator);
    var second: Workspace = .{};
    defer second.deinit(std.testing.allocator);
    const one = types.id(1);
    const two = types.id(2);
    try std.testing.expect(try first.insert(std.testing.allocator, one));
    try std.testing.expect(!(try first.insert(std.testing.allocator, one)));
    try std.testing.expect(try first.insert(std.testing.allocator, two));
    try std.testing.expect(first.focus(two));
    try std.testing.expectEqualSlices(types.WindowId, &.{ one, two }, first.focus_history.items);
    try std.testing.expect(first.raise(one));
    try std.testing.expectEqual(one, first.members.items[1]);
    try std.testing.expect(try Workspace.moveWindow(std.testing.allocator, &first, &second, two));
    try std.testing.expect(!first.contains(two));
    try std.testing.expect(second.contains(two));
    try std.testing.expectEqual(two, second.focused.?);
    try std.testing.expect(!first.remove(two));
}

test "workspaces default to tiled" {
    var workspace: Workspace = .{};
    defer workspace.deinit(std.testing.allocator);
    try std.testing.expect(workspace.layout == .tiled);
}

test "setting tiled layout reconstructs tree order and tracks membership" {
    var workspace: Workspace = .{};
    defer workspace.deinit(std.testing.allocator);
    const first = types.id(1);
    const second = types.id(2);
    const third = types.id(3);
    try std.testing.expect(try workspace.insert(std.testing.allocator, first));
    try std.testing.expect(try workspace.insert(std.testing.allocator, second));
    try std.testing.expect(try workspace.insert(std.testing.allocator, third));
    try workspace.setLayout(std.testing.allocator, .tiled, .{
        .x = 0,
        .y = 0,
        .size = types.Size.init(120, 80),
    });

    var plans = try workspace.layout.arrange(std.testing.allocator, &.{
        .{ .id = first, .current = types.Size.init(10, 10) },
        .{ .id = second, .current = types.Size.init(10, 10) },
        .{ .id = third, .current = types.Size.init(10, 10) },
    }, .{ .x = 0, .y = 0, .size = types.Size.init(120, 80) }, workspace.focused);
    defer plans.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i32, 12), plans.items[0].rect.x);
    try std.testing.expectEqual(@as(i32, 66), plans.items[1].rect.x);
    try std.testing.expectEqual(@as(i32, 12), plans.items[1].rect.y);
    try std.testing.expectEqual(@as(i32, 46), plans.items[2].rect.y);

    try std.testing.expectEqual(second, workspace.nextWindow(first, false).?);
    try std.testing.expect(workspace.swapWindows(first, second));
    try std.testing.expectEqual(third, workspace.nextWindow(first, false).?);
    try std.testing.expect(workspace.focus(third));
    try std.testing.expect(workspace.focus(first));
    try std.testing.expect(workspace.remove(first));
    try std.testing.expectEqual(third, workspace.focused.?);
    try std.testing.expectEqual(second, workspace.nextWindow(third, false).?);
}

test "removing the focused window restores most recent surviving focus" {
    var workspace: Workspace = .{};
    defer workspace.deinit(std.testing.allocator);
    const first = types.id(1);
    const second = types.id(2);
    const third = types.id(3);
    try std.testing.expect(try workspace.insert(std.testing.allocator, first));
    try std.testing.expect(try workspace.insert(std.testing.allocator, second));
    try std.testing.expect(try workspace.insert(std.testing.allocator, third));
    try std.testing.expect(workspace.focus(third));
    try std.testing.expect(workspace.focus(first));
    try std.testing.expect(workspace.focus(second));

    try std.testing.expect(workspace.remove(second));
    try std.testing.expectEqual(first, workspace.focused.?);
    try std.testing.expectEqualSlices(types.WindowId, &.{ third, first }, workspace.focus_history.items);
}

test "workspace reposition keeps membership in drop order" {
    var workspace: Workspace = .{};
    defer workspace.deinit(std.testing.allocator);
    const first = types.id(1);
    const second = types.id(2);
    const third = types.id(3);
    try std.testing.expect(try workspace.insert(std.testing.allocator, first));
    try std.testing.expect(try workspace.insert(std.testing.allocator, second));
    try std.testing.expect(try workspace.insert(std.testing.allocator, third));

    try std.testing.expect(workspace.repositionWindow(first, third, .right));
    try std.testing.expectEqualSlices(
        types.WindowId,
        &.{ second, third, first },
        workspace.members.items,
    );
    try std.testing.expect(workspace.repositionWindow(first, second, .center));
    try std.testing.expectEqualSlices(
        types.WindowId,
        &.{ first, third, second },
        workspace.members.items,
    );
    try std.testing.expect(workspace.repositionWindowAtRoot(third, .left));
    try std.testing.expectEqualSlices(
        types.WindowId,
        &.{ third, first, second },
        workspace.members.items,
    );
    try std.testing.expect(workspace.repositionWindowAtRoot(third, .right));
    try std.testing.expectEqualSlices(
        types.WindowId,
        &.{ first, second, third },
        workspace.members.items,
    );
}
