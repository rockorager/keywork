//! Focus traversal and scroll-reveal helpers for the UI runtime.

const std = @import("std");
const keywork = @import("../../ui.zig");

const log = std.log.scoped(.keywork);

pub const ScrollbarDrag = struct {
    id: []u8,
    axis: keywork.ScrollbarAxis,
    drag_scale: f32,
    last_position: f32,
};

pub fn beginScrollbarDrag(self: anytype, hit: keywork.ScrollbarThumbHit, point: keywork.Point) !void {
    clearScrollbarDrag(self);
    const id = try self.allocator.dupe(u8, hit.id);
    self.scrollbar_drag = .{
        .id = id,
        .axis = hit.axis,
        .drag_scale = hit.drag_scale,
        .last_position = switch (hit.axis) {
            .vertical => point.y,
            .horizontal => point.x,
        },
    };
}

pub fn clearScrollbarDrag(self: anytype) void {
    if (self.scrollbar_drag) |drag| self.allocator.free(drag.id);
    self.scrollbar_drag = null;
}

pub fn requestFocus(self: anytype, id: []const u8) !void {
    const root = self.root orelse return error.NotBuilt;
    const target = keywork.findFocusTarget(root, id) orelse return error.FocusTargetNotFound;
    if (!target.can_request_focus) return error.FocusTargetNotFocusable;
    const targets = try keywork.collectFocusTargets(self.allocator, root);
    defer self.allocator.free(targets);
    if (activeModalScopeId(targets)) |modal_scope_id| {
        if (!sameOptionalString(target.modal_scope_id, modal_scope_id)) return error.FocusTargetOutsideModal;
    }
    _ = try setFocused(self, id);
    try revealFocused(self);
    try self.invalidate();
}

pub fn clearFocus(self: anytype) !void {
    self.autofocus_suppressed = true;
    _ = try setFocused(self, null);
    try self.invalidate();
}

pub fn setFocused(self: anytype, id: ?[]const u8) !bool {
    if (self.focused_id) |old_id| {
        if (id) |new_id| {
            if (std.mem.eql(u8, old_id, new_id)) return false;
        }
        if (focusedTarget(self)) |target| {
            if (target.focus_change_callback) |callback| try callback.call(false);
        }
        self.allocator.free(old_id);
        self.focused_id = null;
    }

    if (id) |new_id| {
        self.autofocus_suppressed = false;
        self.focused_id = try self.allocator.dupe(u8, new_id);
        log.info("focused {s}", .{new_id});
        if (focusedTarget(self)) |target| {
            if (target.focus_change_callback) |callback| try callback.call(true);
        }
        return true;
    }
    return self.focused_id == null and id == null;
}

pub fn focusedTarget(self: anytype) ?keywork.FocusTarget {
    const focused_id = self.focused_id orelse return null;
    const root = self.root orelse return null;
    return keywork.findFocusTarget(root, focused_id);
}

pub fn focusedTargetIs(self: anytype, kind: keywork.FocusTarget.Kind) bool {
    const target = focusedTarget(self) orelse return false;
    return target.kind == kind;
}

pub fn focusNext(self: anytype, reverse: bool) !void {
    const root = self.root orelse return error.NotBuilt;
    const targets = try keywork.collectFocusTargets(self.allocator, root);
    defer self.allocator.free(targets);
    if (targets.len == 0) return;

    const active_modal_scope_id = activeModalScopeId(targets);
    const current_target = if (self.focused_id) |focused_id| findCollectedFocusTarget(targets, focused_id) else null;
    const current_target_in_modal = if (current_target) |target| active_modal_scope_id == null or sameOptionalString(target.modal_scope_id, active_modal_scope_id) else false;
    const active_scope_id = if (current_target_in_modal) current_target.?.scope_id else null;
    const next_index = nextFocusTargetIndex(targets, if (current_target) |target| target.id else null, active_scope_id, active_modal_scope_id, reverse) orelse return;

    _ = try setFocused(self, targets[next_index].id);
    try revealFocused(self);
}

pub fn revealFocused(self: anytype) !void {
    const focused_id = self.focused_id orelse return;
    const root = self.root orelse return;
    var adjustments: std.ArrayList(keywork.RevealAdjustment) = .empty;
    defer adjustments.deinit(self.allocator);
    _ = try keywork.collectRevealAdjustments(self.allocator, root, focused_id, &adjustments);
    for (adjustments.items) |adjustment| {
        try scrollElementById(self, adjustment.id, adjustment.dx, adjustment.dy);
    }
}

pub fn scrollBy(self: anytype, point: keywork.Point, dx: f32, dy: f32) !void {
    const root = self.root orelse return error.NotBuilt;
    const id = keywork.hitTestScroll(root, point) orelse return;
    try scrollElementById(self, id, dx, dy);
}

pub fn scrollElementById(self: anytype, id: []const u8, dx: f32, dy: f32) !void {
    const element_root = if (self.element_root) |*element_root| element_root else return;
    const scroll_element = keywork.dirtyScrollElement(element_root, id) orelse return;
    switch (scroll_element.kind) {
        .scroll => {
            const state = keywork.scrollState(scroll_element);
            state.offset_x = @max(0, state.offset_x + dx);
            state.offset_y = @max(0, state.offset_y + dy);
        },
        .list => {
            const state = keywork.listState(scroll_element);
            state.offset = @max(0, state.offset + dy);
        },
        else => unreachable,
    }
    try self.invalidateState();
}

pub fn waylandScroll(comptime Runtime: type, ctx: *anyopaque, point: keywork.Point, dx: f32, dy: f32) void {
    const self: *Runtime = @ptrCast(@alignCast(ctx));
    scrollBy(self, point, dx, dy) catch |err| {
        log.err("scroll failed: {}", .{err});
    };
}

pub fn findCollectedFocusTarget(targets: []const keywork.FocusTarget, id: []const u8) ?keywork.FocusTarget {
    for (targets) |target| {
        if (std.mem.eql(u8, target.id, id)) return target;
    }
    return null;
}

pub fn nextFocusTargetIndex(targets: []const keywork.FocusTarget, focused_id: ?[]const u8, scope_id: ?[]const u8, modal_scope_id: ?[]const u8, reverse: bool) ?usize {
    var first: ?usize = null;
    var last: ?usize = null;
    var previous_matching: ?usize = null;
    var previous_before_focused: ?usize = null;
    var focused_seen = focused_id == null;
    const filter_by_scope = scope_id != null;

    for (targets, 0..) |target, index| {
        if (modal_scope_id) |active_modal_scope_id| {
            if (!sameOptionalString(target.modal_scope_id, active_modal_scope_id)) continue;
        }
        if (filter_by_scope and !sameOptionalString(target.scope_id, scope_id)) continue;
        if (focused_id) |focused| {
            if (std.mem.eql(u8, target.id, focused)) {
                focused_seen = true;
                previous_before_focused = previous_matching;
                continue;
            }
        }

        if (!isTraversableFocusTarget(target)) continue;
        if (first == null) first = index;
        if (focused_id) |_| {
            if (focused_seen and !reverse) return index;
        } else if (!reverse) return index;
        previous_matching = index;
        last = index;
    }

    if (focused_id == null and reverse) return last;
    if (reverse) return previous_before_focused orelse last;
    return first;
}

pub fn isTraversableFocusTarget(target: keywork.FocusTarget) bool {
    return target.can_request_focus and !target.skip_traversal;
}

pub fn activeModalScopeId(targets: []const keywork.FocusTarget) ?[]const u8 {
    var result: ?[]const u8 = null;
    for (targets) |target| {
        if (target.modal_scope_id) |modal_scope_id| result = modal_scope_id;
    }
    return result;
}

pub fn sameOptionalString(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |a_value| {
        const b_value = b orelse return false;
        return std.mem.eql(u8, a_value, b_value);
    }
    return b == null;
}
