//! Rebuild lifecycle and tree reconciliation helpers for the UI runtime.

const std = @import("std");
const keywork = @import("../../ui.zig");
const focus_scroll = @import("focus_scroll.zig");

pub fn currentState(self: anytype) @TypeOf(self.*).State {
    return .{
        .window_width = self.constraints.max_width,
        .window_height = self.constraints.max_height,
        .color_scheme = self.color_scheme.name(),
    };
}

pub fn buildScope(self: anytype, state: @TypeOf(self.*).State) keywork.BuildScope {
    return .{
        .allocator = self.build_arena.allocator(),
        .theme = keywork.Theme.fromColorScheme(state.color_scheme),
        .interaction = .{ .hovered_id = self.hovered_id, .pressed_id = self.pressed_id, .focused_id = self.focused_id },
        .app_context = state,
        .render_scale = self.renderScale(),
    };
}

pub fn rebuild(self: anytype) !void {
    const max_focus_rebuild_passes = 4;
    var pass: usize = 0;
    while (true) : (pass += 1) {
        _ = self.build_arena.reset(.free_all);
        const state = currentState(self);
        var scope = buildScope(self, state);

        var app_root = try self.app.buildWidget(&scope, state);
        self.app_context = scope.app_context;
        if (self.element_root) |*element_root| {
            try keywork.updateElementTreeScoped(self.allocator, &scope, element_root, &app_root, self.constraints);
        } else {
            self.element_root = try keywork.buildElementTreeScoped(self.allocator, &scope, &app_root, self.constraints);
        }

        try rebuildRetainedTrees(self);

        if (!try reconcileFocusAfterRebuild(self)) break;
        if (pass + 1 >= max_focus_rebuild_passes) return error.FocusDidNotStabilize;
    }
}

pub fn rebuildDirtyState(self: anytype) !void {
    const element_root = if (self.element_root) |*element_root| element_root else {
        try rebuild(self);
        return;
    };

    _ = self.build_arena.reset(.free_all);
    var scope = buildScope(self, self.app_context);
    const rebuilt = try keywork.rebuildDirtyElementTreeScoped(self.allocator, &scope, element_root, self.constraints);
    if (!rebuilt) {
        try rebuildRetainedTrees(self);
        return;
    }

    try rebuildRetainedTrees(self);
    if (try reconcileFocusAfterRebuild(self)) {
        try rebuild(self);
    }
}

pub fn rebuildRetainedTrees(self: anytype) !void {
    const element_root = if (self.element_root) |*element_root| element_root else return error.NotBuilt;
    self.root = try keywork.buildRenderTreeFromElement(self.allocator, element_root, self.constraints, self.backend);
    reconcileInteractionAfterRebuild(self);
}

pub fn reconcileInteractionAfterRebuild(self: anytype) void {
    const root = self.root orelse return;
    if (self.hovered_id) |id| {
        if (keywork.findClickHitById(root, id) == null) {
            self.allocator.free(id);
            self.hovered_id = null;
        }
    }
    if (self.pressed_id) |id| {
        if (keywork.findClickHitById(root, id) == null) {
            self.allocator.free(id);
            self.pressed_id = null;
        }
    }
}

pub fn reconcileFocusAfterRebuild(self: anytype) !bool {
    const root = self.root orelse return false;
    const targets = try keywork.collectFocusTargets(self.allocator, root);
    defer self.allocator.free(targets);
    const active_modal_scope_id = focus_scroll.activeModalScopeId(targets);

    if (self.focused_id) |focused_id| {
        for (targets) |target| {
            if (std.mem.eql(u8, target.id, focused_id) and target.can_request_focus and (active_modal_scope_id == null or focus_scroll.sameOptionalString(target.modal_scope_id, active_modal_scope_id))) {
                self.autofocus_suppressed = false;
                return false;
            }
        }
    }

    const desired_focus = if (!self.autofocus_suppressed) blk: {
        break :blk if (autofocusTarget(targets, active_modal_scope_id)) |target| target.id else null;
    } else null;
    if (focus_scroll.sameOptionalString(self.focused_id, desired_focus)) return false;
    _ = try focus_scroll.setFocused(self, desired_focus);
    return true;
}

pub fn flushInteractionRefresh(self: anytype) !void {
    if (self.pending_interaction_ids.items.len == 0) return;
    defer {
        for (self.pending_interaction_ids.items) |id| self.allocator.free(id);
        self.pending_interaction_ids.clearRetainingCapacity();
    }
    if (self.rebuild_pending) return;
    const element_root = if (self.element_root) |*element_root| element_root else return;
    var ids: [8][]const u8 = undefined;
    const count = @min(ids.len, self.pending_interaction_ids.items.len);
    for (self.pending_interaction_ids.items[0..count], 0..) |id, index| ids[index] = id;
    var scope = buildScope(self, self.app_context);
    _ = try keywork.refreshInteractionElements(self.allocator, &scope, element_root, self.constraints, ids[0..count]);
}

pub fn autofocusTarget(targets: []const keywork.FocusTarget, modal_scope_id: ?[]const u8) ?keywork.FocusTarget {
    for (targets) |target| {
        if (modal_scope_id) |active_modal_scope_id| {
            if (!focus_scroll.sameOptionalString(target.modal_scope_id, active_modal_scope_id)) continue;
        }
        if (target.autofocus and target.can_request_focus) return target;
    }
    return null;
}
