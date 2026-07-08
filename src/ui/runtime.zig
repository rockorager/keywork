//! Runtime orchestration for Keywork applications.

const std = @import("std");
const uucode = @import("uucode");
const keywork = @import("../ui.zig");

const log = std.log.scoped(.keywork);

const AppContext = keywork.AppContext;
const AppHost = keywork.AppHost;
const Constraints = keywork.Constraints;
const BuildScope = keywork.BuildScope;
const DisplayList = keywork.DisplayList;
const Element = keywork.Element;
const CursorShape = keywork.CursorShape;
const KeyInput = keywork.KeyInput;
const Point = keywork.Point;
const PointerButtonState = keywork.PointerButtonState;
const RenderBackend = keywork.RenderBackend;
const RenderNode = keywork.RenderNode;
const Size = keywork.Size;

pub const UiColorScheme = enum {
    no_preference,
    dark,
    light,

    pub fn name(self: UiColorScheme) []const u8 {
        return switch (self) {
            .no_preference => "no-preference",
            .dark => "dark",
            .light => "light",
        };
    }
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    backend: RenderBackend,
    constraints: Constraints,
    app: AppHost,
    build_arena: std.heap.ArenaAllocator,
    color_scheme: UiColorScheme,
    focused_id: ?[]u8 = null,
    autofocus_suppressed: bool = false,
    hovered_id: ?[]u8 = null,
    pressed_id: ?[]u8 = null,
    /// Active scrollbar thumb drag. The pointer stays captured by the
    /// drag until release, so motion keeps scrolling even after leaving
    /// the thumb or the viewport.
    scrollbar_drag: ?ScrollbarDrag = null,
    element_root: ?Element = null,
    root: ?*RenderNode = null,
    display_list: DisplayList = .{},
    app_context: State = .{},
    frame_background: ?keywork.Color = null,
    repaint_pending: bool = false,
    pending_interaction_ids: std.ArrayList([]u8) = .empty,
    rebuild_pending: bool = false,
    state_rebuild_pending: bool = false,
    frame_pending: bool = false,
    rendering: bool = false,
    defer_repaint_until_flush: bool = false,
    repaint_scheduler: ?RepaintScheduler = null,
    repaint_scheduler_context: ?*anyopaque = null,

    pub const RepaintScheduler = *const fn (ctx: *anyopaque) anyerror!void;

    pub const State = AppContext;

    pub fn init(
        allocator: std.mem.Allocator,
        backend: RenderBackend,
        constraints: Constraints,
        app: AppHost,
        color_scheme: UiColorScheme,
    ) !Runtime {
        var self: Runtime = .{
            .allocator = allocator,
            .backend = backend,
            .constraints = constraints,
            .app = app,
            .build_arena = .init(allocator),
            .color_scheme = color_scheme,
        };
        errdefer self.deinit();
        try self.rebuild();
        return self;
    }

    pub fn deinit(self: *Runtime) void {
        if (self.element_root) |*element_root| {
            keywork.destroyElementTree(self.allocator, element_root);
            self.element_root = null;
        }
        self.display_list.deinit(self.allocator);
        if (self.focused_id) |id| self.allocator.free(id);
        for (self.pending_interaction_ids.items) |id| self.allocator.free(id);
        self.pending_interaction_ids.deinit(self.allocator);
        if (self.hovered_id) |id| self.allocator.free(id);
        if (self.pressed_id) |id| self.allocator.free(id);
        if (self.scrollbar_drag) |drag| self.allocator.free(drag.id);
        self.build_arena.deinit();
    }

    fn currentState(self: *const Runtime) State {
        return .{
            .window_width = self.constraints.max_width,
            .window_height = self.constraints.max_height,
            .color_scheme = self.color_scheme.name(),
        };
    }

    pub fn frameSize(self: *const Runtime) Size {
        return .{ .width = self.constraints.max_width, .height = self.constraints.max_height };
    }

    pub fn repaint(self: *Runtime) !void {
        try self.presentFrame();
    }

    pub fn requestRepaint(self: *Runtime) !void {
        self.repaint_pending = true;
        if (self.defer_repaint_until_flush) {
            if (self.repaint_scheduler) |scheduler| try scheduler(self.repaint_scheduler_context.?);
            return;
        }
        if (self.repaint_scheduler) |scheduler| {
            try scheduler(self.repaint_scheduler_context.?);
            return;
        }
        if (!self.frame_pending and !self.rendering) try self.presentFrame();
    }

    pub fn setDeferredRepaint(self: *Runtime, enabled: bool) void {
        self.defer_repaint_until_flush = enabled;
    }

    pub fn flushPendingRepaint(self: *Runtime) !void {
        if (!self.repaint_pending or self.frame_pending or self.rendering) return;
        try self.presentFrame();
    }

    pub fn setRepaintScheduler(self: *Runtime, context: *anyopaque, scheduler: RepaintScheduler) void {
        self.repaint_scheduler_context = context;
        self.repaint_scheduler = scheduler;
    }

    pub fn invalidate(self: *Runtime) !void {
        self.rebuild_pending = true;
        try self.requestRepaint();
    }

    pub fn invalidateState(self: *Runtime) !void {
        self.state_rebuild_pending = true;
        try self.requestRepaint();
    }

    fn presentFrame(self: *Runtime) !void {
        if (self.rendering) {
            self.repaint_pending = true;
            return;
        }

        self.rendering = true;
        defer self.rendering = false;
        try self.flushInteractionRefresh();
        // Consume pending flags before rebuilding so invalidations raised by
        // callbacks during the rebuild are observed on the next pass instead
        // of being cleared and dropped.
        const max_rebuild_passes = 8;
        var pass: usize = 0;
        while (self.rebuild_pending or self.state_rebuild_pending) : (pass += 1) {
            if (pass >= max_rebuild_passes) return error.RebuildDidNotStabilize;
            const full_rebuild = self.rebuild_pending;
            self.rebuild_pending = false;
            self.state_rebuild_pending = false;
            if (full_rebuild) {
                try self.rebuild();
            } else {
                try self.rebuildDirtyState();
            }
            // Layout may discover that a virtualized list's built window
            // drifted; another dirty-state pass rebuilds it.
            if (self.element_root) |*element_root| {
                if (keywork.anyListRangeStale(element_root)) self.state_rebuild_pending = true;
            }
        }
        self.repaint_pending = false;

        const root = self.root orelse return error.NotBuilt;
        self.display_list.clearRetainingCapacity(self.allocator);
        const frame_size = self.frameSize();
        const full_frame: keywork.Rect = .{ .x = 0, .y = 0, .width = frame_size.width, .height = frame_size.height };
        // Damage accumulated by relayout since the last collection; a
        // repaint without any layout change (e.g. a scale change) reports
        // the full frame.
        const damage = if (keywork.collectDamage(root)) |dirty| dirty.intersect(full_frame) else full_frame;
        const background = self.frame_background orelse keywork.Theme.fromColorScheme(self.color_scheme.name()).color_scheme.background;
        if (background.a > 0) try self.display_list.fillRect(self.allocator, full_frame, background);
        const render_scale = self.backend.scale();
        try keywork.paintScaled(self.allocator, root, &self.display_list, render_scale);
        self.frame_pending = try self.backend.present(.{
            .size = frame_size,
            .scale = render_scale,
            .damage = &.{damage},
            .display_list = self.display_list.commands.items,
        });
    }

    fn frameDone(self: *Runtime) !void {
        self.frame_pending = false;
        if (self.repaint_pending) {
            if (self.defer_repaint_until_flush) return;
            if (self.repaint_scheduler) |scheduler| {
                try scheduler(self.repaint_scheduler_context.?);
            } else {
                try self.presentFrame();
            }
        }
    }

    pub fn click(self: *Runtime, point: Point) !void {
        try self.pointerButton(point, .pressed);
        try self.pointerButton(point, .released);
    }

    pub fn pointerButton(self: *Runtime, point: Point, state: PointerButtonState) !void {
        switch (state) {
            .pressed => try self.pointerDown(point),
            .released => try self.pointerUp(point),
        }
    }

    const ScrollbarDrag = struct {
        id: []u8,
        axis: keywork.ScrollbarAxis,
        /// Scroll offset change per pixel of pointer travel.
        drag_scale: f32,
        /// Pointer coordinate along the drag axis at the last update.
        last_position: f32,
    };

    fn pointerDown(self: *Runtime, point: Point) !void {
        const root = self.root orelse return error.NotBuilt;
        if (keywork.hitTestScrollbarThumb(root, point)) |hit| {
            try self.beginScrollbarDrag(hit, point);
            return;
        }
        if (keywork.hitTestTextInput(root, point)) |id| {
            const focus_changed = try self.setFocused(id);
            _ = try self.setPressedId(null);
            if (focus_changed) try self.invalidate() else try self.invalidateState();
            return;
        }

        if (keywork.hitTestClick(root, point)) |hit| {
            const focus_changed = try self.setFocused(hit.id);
            var needs_update = try self.setPressedId(hit.id);
            if (hit.tap_down) |callback| {
                try callback.call();
                needs_update = true;
            }
            if (hit.activation == .press) {
                log.info("clicked button {s} at {d},{d}", .{ hit.id, point.x, point.y });
                if (try self.activateClick(hit)) needs_update = true;
            }
            if (focus_changed) {
                try self.invalidate();
            } else if (needs_update) {
                try self.invalidateState();
            }
        } else {
            self.autofocus_suppressed = true;
            const focus_changed = try self.setFocused(null);
            log.info("pointer down on empty space at {d},{d}", .{ point.x, point.y });
            _ = try self.setPressedId(null);
            if (focus_changed) try self.invalidate() else try self.invalidateState();
        }
    }

    fn beginScrollbarDrag(self: *Runtime, hit: keywork.ScrollbarThumbHit, point: Point) !void {
        self.clearScrollbarDrag();
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

    fn clearScrollbarDrag(self: *Runtime) void {
        if (self.scrollbar_drag) |drag| self.allocator.free(drag.id);
        self.scrollbar_drag = null;
    }

    fn pointerUp(self: *Runtime, point: Point) !void {
        if (self.scrollbar_drag != null) {
            self.clearScrollbarDrag();
            return;
        }
        const root = self.root orelse return error.NotBuilt;
        const hit = keywork.hitTestClick(root, point);
        const pressed_hit = if (self.pressed_id) |pressed_id| keywork.findClickHitById(root, pressed_id) else null;
        const should_activate = if (self.pressed_id) |pressed_id| blk: {
            const hit_id = if (hit) |click_hit| click_hit.id else break :blk false;
            break :blk std.mem.eql(u8, pressed_id, hit_id);
        } else false;

        var needs_update = try self.setPressedId(null);
        if (should_activate) {
            const click_hit = hit.?;
            if (click_hit.tap_up) |callback| {
                try callback.call();
                needs_update = true;
            }
            if (click_hit.activation == .release) {
                log.info("clicked button {s} at {d},{d}", .{ click_hit.id, point.x, point.y });
                if (try self.activateClick(click_hit)) needs_update = true;
            }
        } else if (pressed_hit) |cancel_hit| {
            if (cancel_hit.tap_cancel) |callback| {
                try callback.call();
                needs_update = true;
            }
        }

        if (needs_update) {
            try self.invalidateState();
        }
    }

    pub fn requestFocus(self: *Runtime, id: []const u8) !void {
        const root = self.root orelse return error.NotBuilt;
        const target = keywork.findFocusTarget(root, id) orelse return error.FocusTargetNotFound;
        if (!target.can_request_focus) return error.FocusTargetNotFocusable;
        const targets = try keywork.collectFocusTargets(self.allocator, root);
        defer self.allocator.free(targets);
        if (activeModalScopeId(targets)) |modal_scope_id| {
            if (!sameOptionalString(target.modal_scope_id, modal_scope_id)) return error.FocusTargetOutsideModal;
        }
        _ = try self.setFocused(id);
        try self.revealFocused();
        try self.invalidate();
    }

    pub fn clearFocus(self: *Runtime) !void {
        self.autofocus_suppressed = true;
        _ = try self.setFocused(null);
        try self.invalidate();
    }

    fn setFocused(self: *Runtime, id: ?[]const u8) !bool {
        if (self.focused_id) |old_id| {
            if (id) |new_id| {
                if (std.mem.eql(u8, old_id, new_id)) return false;
            }
            if (self.focusedTarget()) |target| {
                if (target.focus_change_callback) |callback| try callback.call(false);
            }
            self.allocator.free(old_id);
            self.focused_id = null;
        }

        if (id) |new_id| {
            self.autofocus_suppressed = false;
            self.focused_id = try self.allocator.dupe(u8, new_id);
            log.info("focused {s}", .{new_id});
            if (self.focusedTarget()) |target| {
                if (target.focus_change_callback) |callback| try callback.call(true);
            }
            return true;
        }
        return self.focused_id == null and id == null;
    }

    pub fn keyInput(self: *Runtime, input: KeyInput) !void {
        if (try self.activateShortcut(input)) {
            try self.invalidate();
            return;
        }

        switch (input) {
            .tab => |tab| {
                try self.focusNext(tab.reverse);
                try self.invalidate();
            },
            .text => |bytes| try self.editFocusedTextInput(.{ .append = bytes }),
            .backspace => try self.editFocusedTextInput(.pop_grapheme),
            .space => {
                const target = self.focusedTarget() orelse return;
                switch (target.kind) {
                    .text_input => try self.editFocusedTextInput(.{ .append = " " }),
                    .clickable => {
                        _ = try self.activateClick(.{ .id = target.id, .callback = target.callback });
                        try self.invalidateState();
                    },
                    .focus => {},
                }
            },
            .enter => {
                const target = self.focusedTarget() orelse return;
                switch (target.kind) {
                    .text_input => {
                        self.autofocus_suppressed = true;
                        _ = try self.setFocused(null);
                        try self.invalidate();
                    },
                    .clickable => {
                        _ = try self.activateClick(.{ .id = target.id, .callback = target.callback });
                        try self.invalidateState();
                    },
                    .focus => {},
                }
            },
            // Only meaningful as shortcuts; ignored without a binding.
            .escape, .up, .down => {},
        }
    }

    const TextEdit = union(enum) {
        append: []const u8,
        pop_grapheme,
    };

    /// Applies a text edit to the focused text input's element-owned
    /// editing state, fires its on_change callback, and schedules a
    /// dirty-state pass. Typing relayouts exactly one input; no rebuild.
    fn editFocusedTextInput(self: *Runtime, edit: TextEdit) !void {
        if (!self.focusedTargetIs(.text_input)) return;
        const focused_id = self.focused_id orelse return;
        const element_root = if (self.element_root) |*element_root| element_root else return;
        const input = keywork.dirtyTextInputElement(element_root, focused_id) orelse return;
        const state = keywork.textInputState(input);
        switch (edit) {
            .append => |bytes| try state.text.appendSlice(self.allocator, bytes),
            .pop_grapheme => popLastGrapheme(&state.text),
        }
        if (input.widget.text_input.on_change) |callback| try callback.call(state.text.items);
        try self.invalidateState();
    }

    fn activateShortcut(self: *Runtime, input: KeyInput) !bool {
        const shortcut_key = keywork.shortcutKeyForInput(input) orelse return false;
        if (self.focusedTargetIs(.text_input) and !keywork.shortcutAllowedWhileEditing(shortcut_key)) return false;
        const element_root = if (self.element_root) |*root| root else return false;
        const callback = if (self.focused_id) |focused_id|
            keywork.findFocusedShortcutAction(element_root, shortcut_key, focused_id) orelse keywork.findShortcutAction(element_root, shortcut_key) orelse return false
        else
            keywork.findShortcutAction(element_root, shortcut_key) orelse return false;
        try callback.call();
        return true;
    }

    fn focusedTarget(self: *Runtime) ?keywork.FocusTarget {
        const focused_id = self.focused_id orelse return null;
        const root = self.root orelse return null;
        return keywork.findFocusTarget(root, focused_id);
    }

    fn focusedTargetIs(self: *Runtime, kind: keywork.FocusTarget.Kind) bool {
        const target = self.focusedTarget() orelse return false;
        return target.kind == kind;
    }

    fn focusNext(self: *Runtime, reverse: bool) !void {
        const root = self.root orelse return error.NotBuilt;
        const targets = try keywork.collectFocusTargets(self.allocator, root);
        defer self.allocator.free(targets);
        if (targets.len == 0) return;

        const active_modal_scope_id = activeModalScopeId(targets);
        const current_target = if (self.focused_id) |focused_id| findCollectedFocusTarget(targets, focused_id) else null;
        const current_target_in_modal = if (current_target) |target| active_modal_scope_id == null or sameOptionalString(target.modal_scope_id, active_modal_scope_id) else false;
        const active_scope_id = if (current_target_in_modal) current_target.?.scope_id else null;
        const next_index = nextFocusTargetIndex(targets, if (current_target) |target| target.id else null, active_scope_id, active_modal_scope_id, reverse) orelse return;

        _ = try self.setFocused(targets[next_index].id);
        try self.revealFocused();
    }

    /// Scrolls ancestor viewports the minimum distance needed to bring
    /// the keyboard-focused widget into view.
    fn revealFocused(self: *Runtime) !void {
        const focused_id = self.focused_id orelse return;
        const root = self.root orelse return;
        var adjustments: std.ArrayList(keywork.RevealAdjustment) = .empty;
        defer adjustments.deinit(self.allocator);
        _ = try keywork.collectRevealAdjustments(self.allocator, root, focused_id, &adjustments);
        for (adjustments.items) |adjustment| {
            try self.scrollElementById(adjustment.id, adjustment.dx, adjustment.dy);
        }
    }

    fn findCollectedFocusTarget(targets: []const keywork.FocusTarget, id: []const u8) ?keywork.FocusTarget {
        for (targets) |target| {
            if (std.mem.eql(u8, target.id, id)) return target;
        }
        return null;
    }

    fn nextFocusTargetIndex(
        targets: []const keywork.FocusTarget,
        focused_id: ?[]const u8,
        scope_id: ?[]const u8,
        modal_scope_id: ?[]const u8,
        reverse: bool,
    ) ?usize {
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
                if (focused_seen and !reverse) {
                    return index;
                }
            } else if (!reverse) {
                return index;
            }
            previous_matching = index;
            last = index;
        }

        if (focused_id == null and reverse) return last;
        if (reverse) return previous_before_focused orelse last;
        return first;
    }

    fn isTraversableFocusTarget(target: keywork.FocusTarget) bool {
        return target.can_request_focus and !target.skip_traversal;
    }

    fn activeModalScopeId(targets: []const keywork.FocusTarget) ?[]const u8 {
        var result: ?[]const u8 = null;
        for (targets) |target| {
            if (target.modal_scope_id) |modal_scope_id| result = modal_scope_id;
        }
        return result;
    }

    fn sameOptionalString(a: ?[]const u8, b: ?[]const u8) bool {
        if (a) |a_value| {
            const b_value = b orelse return false;
            return std.mem.eql(u8, a_value, b_value);
        }
        return b == null;
    }

    fn activateClick(self: *Runtime, hit: keywork.ClickHit) !bool {
        _ = self;
        if (hit.callback) |callback| {
            try callback.call();
            return true;
        }
        return false;
    }

    pub fn cursorShape(self: *Runtime, point: Point) CursorShape {
        const root = self.root orelse return .default;
        return keywork.hitTestCursorShape(root, point);
    }

    pub fn pointerMove(self: *Runtime, point: ?Point) !void {
        if (self.scrollbar_drag) |*drag| {
            const position = point orelse return;
            const coordinate = switch (drag.axis) {
                .vertical => position.y,
                .horizontal => position.x,
            };
            const delta = (coordinate - drag.last_position) * drag.drag_scale;
            drag.last_position = coordinate;
            if (delta != 0) {
                switch (drag.axis) {
                    .vertical => try self.scrollElementById(drag.id, 0, delta),
                    .horizontal => try self.scrollElementById(drag.id, delta, 0),
                }
            }
            return;
        }
        const hit_id = if (point) |position| blk: {
            const root = self.root orelse return error.NotBuilt;
            break :blk if (keywork.hitTestClick(root, position)) |hit| hit.id else null;
        } else null;
        if (!try self.setHoveredId(hit_id)) return;
        try self.invalidateState();
    }

    fn setHoveredId(self: *Runtime, id: ?[]const u8) !bool {
        return self.setInteractionId(&self.hovered_id, id);
    }

    fn setPressedId(self: *Runtime, id: ?[]const u8) !bool {
        return self.setInteractionId(&self.pressed_id, id);
    }

    fn setInteractionId(self: *Runtime, slot: *?[]u8, id: ?[]const u8) !bool {
        if (slot.*) |old_id| {
            if (id) |new_id| {
                if (std.mem.eql(u8, old_id, new_id)) return false;
            }
        } else if (id == null) {
            return false;
        }

        const old_id = slot.*;
        if (old_id) |value| try self.queueInteractionRefresh(value);
        if (id) |value| try self.queueInteractionRefresh(value);
        if (old_id) |value| self.allocator.free(value);
        slot.* = if (id) |new_id| try self.allocator.dupe(u8, new_id) else null;
        return true;
    }

    /// Queues a widget id whose hover/press styling changed. The restyle is
    /// deferred to the next frame because the event handler that triggered
    /// it may still hold callbacks borrowed from the widgets a refresh
    /// would replace.
    fn queueInteractionRefresh(self: *Runtime, id: []const u8) !void {
        for (self.pending_interaction_ids.items) |pending| {
            if (std.mem.eql(u8, pending, id)) return;
        }
        const owned = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(owned);
        try self.pending_interaction_ids.append(self.allocator, owned);
    }

    /// Restyles only the widgets whose hover/press state changed, marking
    /// their layout path dirty so the dirty-state pass relayouts and
    /// repaints them without rebuilding the app.
    fn flushInteractionRefresh(self: *Runtime) !void {
        if (self.pending_interaction_ids.items.len == 0) return;
        defer {
            for (self.pending_interaction_ids.items) |id| self.allocator.free(id);
            self.pending_interaction_ids.clearRetainingCapacity();
        }
        // A pending full rebuild restyles everything anyway.
        if (self.rebuild_pending) return;
        const element_root = if (self.element_root) |*element_root| element_root else return;
        var ids: [8][]const u8 = undefined;
        const count = @min(ids.len, self.pending_interaction_ids.items.len);
        for (self.pending_interaction_ids.items[0..count], 0..) |id, index| ids[index] = id;
        var build_scope = self.buildScope(self.app_context);
        _ = try keywork.refreshInteractionElements(self.allocator, &build_scope, element_root, self.constraints, ids[0..count]);
    }

    pub fn waylandPointerButton(ctx: *anyopaque, point: Point, state: PointerButtonState) void {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        self.pointerButton(point, state) catch |err| {
            log.err("pointer button handling failed: {}", .{err});
        };
    }

    pub fn waylandCursorShape(ctx: *anyopaque, point: Point) CursorShape {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        return self.cursorShape(point);
    }

    /// Scrolls the innermost viewport under the pointer. Offsets are
    /// clamped to the content extent during the relayout this schedules.
    pub fn scrollBy(self: *Runtime, point: Point, dx: f32, dy: f32) !void {
        const root = self.root orelse return error.NotBuilt;
        const id = keywork.hitTestScroll(root, point) orelse return;
        try self.scrollElementById(id, dx, dy);
    }

    fn scrollElementById(self: *Runtime, id: []const u8, dx: f32, dy: f32) !void {
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

    pub fn waylandScroll(ctx: *anyopaque, point: Point, dx: f32, dy: f32) void {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        self.scrollBy(point, dx, dy) catch |err| {
            log.err("scroll failed: {}", .{err});
        };
    }

    pub fn waylandPointerMove(ctx: *anyopaque, point: ?Point) void {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        self.pointerMove(point) catch |err| {
            log.err("pointer motion failed: {}", .{err});
        };
    }

    pub fn waylandConfigure(ctx: *anyopaque, size: Size) void {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        if (size.width > 0 and size.height > 0) {
            self.constraints = .{ .max_width = size.width, .max_height = size.height };
        }
        self.invalidate() catch |err| {
            log.err("configure invalidate failed: {}", .{err});
        };
    }

    pub fn waylandFrameDone(ctx: *anyopaque) void {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        self.frameDone() catch |err| {
            log.err("frame repaint failed: {}", .{err});
        };
    }

    pub fn setColorScheme(self: *Runtime, color_scheme: UiColorScheme) !void {
        if (self.color_scheme == color_scheme) return;
        self.color_scheme = color_scheme;
        try self.invalidate();
    }

    pub fn colorSchemeChanged(ctx: *anyopaque, color_scheme: UiColorScheme) void {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        self.setColorScheme(color_scheme) catch |err| {
            log.err("desktop settings invalidate failed: {}", .{err});
        };
    }

    pub fn waylandKeyInput(ctx: *anyopaque, input: KeyInput) void {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        self.keyInput(input) catch |err| {
            log.err("key input failed: {}", .{err});
        };
    }

    fn rebuild(self: *Runtime) !void {
        const max_focus_rebuild_passes = 4;
        var pass: usize = 0;
        while (true) : (pass += 1) {
            _ = self.build_arena.reset(.free_all);
            const state = self.currentState();
            var build_scope = self.buildScope(state);

            var app_root = try self.app.buildWidget(&build_scope, state);
            self.app_context = build_scope.app_context;
            if (self.element_root) |*element_root| {
                try keywork.updateElementTreeScoped(self.allocator, &build_scope, element_root, &app_root, self.constraints);
            } else {
                self.element_root = try keywork.buildElementTreeScoped(self.allocator, &build_scope, &app_root, self.constraints);
            }

            try self.rebuildRetainedTrees();

            if (!try self.reconcileFocusAfterRebuild()) break;
            if (pass + 1 >= max_focus_rebuild_passes) return error.FocusDidNotStabilize;
        }
    }

    fn rebuildDirtyState(self: *Runtime) !void {
        const element_root = if (self.element_root) |*element_root| element_root else {
            try self.rebuild();
            return;
        };

        _ = self.build_arena.reset(.free_all);
        var build_scope = self.buildScope(self.app_context);
        const rebuilt = try keywork.rebuildDirtyElementTreeScoped(self.allocator, &build_scope, element_root, self.constraints);
        if (!rebuilt) {
            try self.rebuildRetainedTrees();
            return;
        }

        try self.rebuildRetainedTrees();
        if (try self.reconcileFocusAfterRebuild()) {
            try self.rebuild();
        }
    }

    fn buildScope(self: *Runtime, state: State) BuildScope {
        return .{
            .allocator = self.build_arena.allocator(),
            .theme = keywork.Theme.fromColorScheme(state.color_scheme),
            .interaction = .{ .hovered_id = self.hovered_id, .pressed_id = self.pressed_id, .focused_id = self.focused_id },
            .app_context = state,
        };
    }

    fn rebuildRetainedTrees(self: *Runtime) !void {
        const element_root = if (self.element_root) |*element_root| element_root else return error.NotBuilt;
        self.root = try keywork.buildRenderTreeFromElement(self.allocator, element_root, self.constraints, self.backend);
        self.reconcileInteractionAfterRebuild();
    }

    /// Drops hovered/pressed ids whose widgets no longer exist so they
    /// cannot leak stale interaction styling into later builds. Focus has
    /// its own reconciliation with autofocus fallback.
    fn reconcileInteractionAfterRebuild(self: *Runtime) void {
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

    fn reconcileFocusAfterRebuild(self: *Runtime) !bool {
        const root = self.root orelse return false;
        const targets = try keywork.collectFocusTargets(self.allocator, root);
        defer self.allocator.free(targets);
        const active_modal_scope_id = activeModalScopeId(targets);

        if (self.focused_id) |focused_id| {
            for (targets) |target| {
                if (std.mem.eql(u8, target.id, focused_id) and target.can_request_focus and (active_modal_scope_id == null or sameOptionalString(target.modal_scope_id, active_modal_scope_id))) {
                    self.autofocus_suppressed = false;
                    return false;
                }
            }
        }

        const desired_focus = if (!self.autofocus_suppressed) blk: {
            break :blk if (autofocusTarget(targets, active_modal_scope_id)) |target| target.id else null;
        } else null;
        if (sameOptionalString(self.focused_id, desired_focus)) return false;
        _ = try self.setFocused(desired_focus);
        return true;
    }

    fn autofocusTarget(targets: []const keywork.FocusTarget, modal_scope_id: ?[]const u8) ?keywork.FocusTarget {
        for (targets) |target| {
            if (modal_scope_id) |active_modal_scope_id| {
                if (!sameOptionalString(target.modal_scope_id, active_modal_scope_id)) continue;
            }
            if (target.autofocus and target.can_request_focus) return target;
        }
        return null;
    }
};

fn popLastGrapheme(bytes: *std.ArrayList(u8)) void {
    if (bytes.items.len == 0) return;

    var it = uucode.grapheme.utf8Iterator(bytes.items);
    var start: usize = 0;
    while (it.nextGrapheme()) |grapheme| {
        start = grapheme.start;
    }
    bytes.shrinkRetainingCapacity(start);
}

test "popLastGrapheme removes one extended grapheme cluster" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);

    try bytes.appendSlice(std.testing.allocator, "aé🇺🇸👩🏽‍🚀");
    popLastGrapheme(&bytes);
    try std.testing.expectEqualStrings("aé🇺🇸", bytes.items);
    popLastGrapheme(&bytes);
    try std.testing.expectEqualStrings("aé", bytes.items);
    popLastGrapheme(&bytes);
    try std.testing.expectEqualStrings("a", bytes.items);
    popLastGrapheme(&bytes);
    try std.testing.expectEqualStrings("", bytes.items);
}

test "invalidation raised during rebuild is not dropped" {
    const TestApp = struct {
        builds: usize = 0,
        runtime: ?*Runtime = null,

        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(ptr: *anyopaque, _: *BuildScope, _: AppContext) !keywork.Widget {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.builds += 1;
            // Re-invalidate exactly once from inside a rebuild pass.
            if (self.builds == 2) {
                if (self.runtime) |runtime| try runtime.invalidate();
            }
            return keywork.widgets.text("hello");
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 200, .max_height = 120 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();
    app.runtime = &runtime;

    try std.testing.expectEqual(@as(usize, 1), app.builds);
    try runtime.invalidate();
    try std.testing.expectEqual(@as(usize, 3), app.builds);
    try std.testing.expect(!runtime.rebuild_pending);
    try std.testing.expect(!runtime.state_rebuild_pending);
}

test "deferred invalidations coalesce until flush" {
    const TestApp = struct {
        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(_: *anyopaque, _: *BuildScope, _: AppContext) !keywork.Widget {
            return keywork.widgets.text("hello");
        }
    };

    const TestBackend = struct {
        presents: usize = 0,

        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(ptr: *anyopaque, _: RenderBackend.Frame) !bool {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.presents += 1;
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(std.testing.allocator, backend.backend(), .{ .max_width = 100, .max_height = 40 }, app.host(), .no_preference);
    defer runtime.deinit();
    try runtime.repaint();
    try std.testing.expectEqual(@as(usize, 1), backend.presents);
    runtime.setDeferredRepaint(true);
    try runtime.invalidate();
    try runtime.invalidateState();
    try std.testing.expectEqual(@as(usize, 1), backend.presents);
    try runtime.flushPendingRepaint();
    try std.testing.expectEqual(@as(usize, 2), backend.presents);
}

test "rebuild passes that never stabilize return an error" {
    const TestApp = struct {
        runtime: ?*Runtime = null,

        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(ptr: *anyopaque, _: *BuildScope, _: AppContext) !keywork.Widget {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (self.runtime) |runtime| try runtime.invalidate();
            return keywork.widgets.text("hello");
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 200, .max_height = 120 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();
    app.runtime = &runtime;

    try std.testing.expectError(error.RebuildDidNotStabilize, runtime.invalidate());
}

fn renderedInputText(node: *const RenderNode) ?[]const u8 {
    if (node.kind == .text_input) return node.text;
    for (node.children) |child| {
        if (renderedInputText(child)) |text| return text;
    }
    return null;
}

test "tab traversal focuses widgets and enter activates focused clickable" {
    const TestApp = struct {
        clicks: usize = 0,

        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(ptr: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const input = keywork.widgets.textInput("input", "", "placeholder");
            const button = try keywork.widgets.button(scope.allocator, "button", "Button", .{ .ptr = self, .call_fn = increment });
            const children = [_]keywork.Widget{ input, button };
            return keywork.widgets.column(scope.allocator, &children, 4);
        }

        fn increment(ptr: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.clicks += 1;
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 200, .max_height = 120 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();

    try runtime.keyInput(.{ .tab = .{} });
    try std.testing.expectEqualStrings("input", runtime.focused_id.?);
    try runtime.keyInput(.{ .text = "a" });
    try std.testing.expectEqualStrings("a", renderedInputText(runtime.root.?).?);

    try runtime.keyInput(.{ .tab = .{} });
    try std.testing.expectEqualStrings("button", runtime.focused_id.?);
    try runtime.keyInput(.enter);
    try std.testing.expectEqual(@as(usize, 1), app.clicks);
    try runtime.keyInput(.space);
    try std.testing.expectEqual(@as(usize, 2), app.clicks);

    try runtime.keyInput(.{ .tab = .{ .reverse = true } });
    try std.testing.expectEqualStrings("input", runtime.focused_id.?);
    try runtime.keyInput(.space);
    try std.testing.expectEqualStrings("a ", renderedInputText(runtime.root.?).?);
}

test "wheel scroll moves viewport content without rebuilding" {
    const TestApp = struct {
        builds: usize = 0,

        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(ptr: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.builds += 1;
            var rows: [20]keywork.Widget = undefined;
            for (&rows) |*row| row.* = keywork.widgets.text("row");
            const column = try keywork.widgets.column(scope.allocator, &rows, 0);
            return keywork.widgets.scroll(scope.allocator, "list", column);
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 200, .max_height = 120 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();
    try std.testing.expectEqual(@as(usize, 1), app.builds);
    // 20 rows at 16px in a 120px viewport: 200px of scroll range.
    try std.testing.expectEqual(@as(f32, 0), runtime.root.?.children[0].rect.y);

    try runtime.scrollBy(.{ .x = 5, .y = 5 }, 0, 30);
    try std.testing.expectEqual(@as(f32, -30), runtime.root.?.children[0].rect.y);
    try std.testing.expectEqual(@as(usize, 1), app.builds);

    // Scrolling past the edges clamps.
    try runtime.scrollBy(.{ .x = 5, .y = 5 }, 0, 10_000);
    try std.testing.expectEqual(@as(f32, -200), runtime.root.?.children[0].rect.y);
    try runtime.scrollBy(.{ .x = 5, .y = 5 }, 0, -10_000);
    try std.testing.expectEqual(@as(f32, 0), runtime.root.?.children[0].rect.y);
    try std.testing.expectEqual(@as(usize, 1), app.builds);

    // Scrolling outside any viewport is a no-op.
    try runtime.scrollBy(.{ .x = 5, .y = 500 }, 0, 30);
    try std.testing.expectEqual(@as(f32, 0), runtime.root.?.children[0].rect.y);
}

test "dragging the scrollbar thumb scrolls and captures the pointer" {
    const TestApp = struct {
        builds: usize = 0,

        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(ptr: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.builds += 1;
            var rows: [20]keywork.Widget = undefined;
            for (&rows) |*row| row.* = keywork.widgets.text("row");
            const column = try keywork.widgets.column(scope.allocator, &rows, 0);
            return keywork.widgets.scroll(scope.allocator, "list", column);
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 200, .max_height = 120 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();

    // 20 rows at 16px in a 120px viewport: content 320, scroll range 200.
    // Thumb: track 116, length max(12, 116*120/320) = 43.5, travel 72.5.
    const drag_scale: f32 = 200.0 / 72.5;
    // The viewport shrink-wraps its child's width; the thumb hugs its
    // right edge.
    const viewport = runtime.root.?.rect;
    const thumb_x = viewport.x + viewport.width - 4;

    // Press on the thumb; this starts a drag, not a click.
    try runtime.pointerButton(.{ .x = thumb_x, .y = 10 }, .pressed);
    try std.testing.expect(runtime.scrollbar_drag != null);

    // Dragging down moves the content proportionally without rebuilding.
    try runtime.pointerMove(.{ .x = thumb_x, .y = 39 });
    try std.testing.expectApproxEqAbs(@as(f32, -29 * drag_scale), runtime.root.?.children[0].rect.y, 0.01);
    try std.testing.expectEqual(@as(usize, 1), app.builds);

    // The drag stays captured when the pointer leaves the viewport.
    try runtime.pointerMove(.{ .x = 500, .y = 1000 });
    try std.testing.expectEqual(@as(f32, -200), runtime.root.?.children[0].rect.y);
    try runtime.pointerMove(.{ .x = 500, .y = -1000 });
    try std.testing.expectEqual(@as(f32, 0), runtime.root.?.children[0].rect.y);

    // Release ends the drag; further motion no longer scrolls.
    try runtime.pointerButton(.{ .x = 500, .y = -1000 }, .released);
    try std.testing.expect(runtime.scrollbar_drag == null);
    try runtime.pointerMove(.{ .x = thumb_x, .y = 60 });
    try std.testing.expectEqual(@as(f32, 0), runtime.root.?.children[0].rect.y);
    try std.testing.expectEqual(@as(usize, 1), app.builds);
}

test "keyboard focus scrolls its viewport to reveal the target" {
    const TestApp = struct {
        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(_: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            var rows: [12]keywork.Widget = undefined;
            var names: [12][]const u8 = undefined;
            for (&rows, 0..) |*row, index| {
                names[index] = try std.fmt.allocPrint(scope.allocator, "input-{d}", .{index});
                row.* = keywork.widgets.textInput(names[index], "", "");
            }
            const column = try keywork.widgets.column(scope.allocator, &rows, 0);
            return keywork.widgets.scroll(scope.allocator, "pane", column);
        }

        fn findFocusRect(node: *const keywork.RenderNode, id: []const u8) ?keywork.Rect {
            if (node.focus_id) |focus_id| {
                if (std.mem.eql(u8, focus_id, id)) return node.rect;
            }
            for (node.children) |child| {
                if (findFocusRect(child, id)) |rect| return rect;
            }
            return null;
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 300, .max_height = 120 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();

    const viewport = runtime.root.?.rect;
    try std.testing.expect(runtime.root.?.scroll_content.height > viewport.height);

    // Tab through every input; each focused input must be inside the
    // viewport after the reveal scroll.
    for (0..12) |_| {
        try runtime.keyInput(.{ .tab = .{} });
        const focused = runtime.focused_id.?;
        const rect = TestApp.findFocusRect(runtime.root.?, focused).?;
        try std.testing.expect(rect.y >= viewport.y - 0.01);
        try std.testing.expect(rect.y + rect.height <= viewport.y + viewport.height + 0.01);
    }

    // Wrapping back to the first input scrolls the viewport up again.
    try runtime.keyInput(.{ .tab = .{} });
    try std.testing.expectEqualStrings("input-0", runtime.focused_id.?);
    const rect = TestApp.findFocusRect(runtime.root.?, "input-0").?;
    try std.testing.expect(rect.y >= viewport.y - 0.01);
}

test "scrolling a virtualized list converges its window in one frame" {
    const TestApp = struct {
        builds: usize = 0,

        var dummy: u8 = 0;

        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(ptr: *anyopaque, _: *BuildScope, _: AppContext) !keywork.Widget {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.builds += 1;
            return keywork.widgets.list("rows", 1000, 16, .{ .ptr = &dummy, .build_fn = buildItem });
        }

        fn buildItem(_: *const anyopaque, scope: *BuildScope, index: usize) !keywork.Widget {
            const label = try std.fmt.allocPrint(scope.allocator, "row {d}", .{index});
            return .{ .text = .{ .value = label } };
        }

        fn firstRowText(node: *const keywork.RenderNode) ?[]const u8 {
            if (node.kind == .text) return node.text;
            for (node.children) |child| {
                if (firstRowText(child)) |text| return text;
            }
            return null;
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 200, .max_height = 120 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();
    try std.testing.expectEqualStrings("row 0", TestApp.firstRowText(runtime.root.?).?);

    // A deep scroll rebuilds the window through the frame loop's
    // convergence pass, with no app rebuild.
    try runtime.scrollBy(.{ .x = 5, .y = 5 }, 0, 8000);
    try std.testing.expectEqualStrings("row 498", TestApp.firstRowText(runtime.root.?).?);
    try std.testing.expectEqual(@as(usize, 1), app.builds);

    try runtime.scrollBy(.{ .x = 5, .y = 5 }, 0, -100_000);
    try std.testing.expectEqualStrings("row 0", TestApp.firstRowText(runtime.root.?).?);
    try std.testing.expectEqual(@as(usize, 1), app.builds);
}

test "typing edits element-owned input state without rebuilding" {
    const TestApp = struct {
        builds: usize = 0,
        last_change: [32]u8 = undefined,
        last_change_len: usize = 0,

        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(ptr: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.builds += 1;
            var first = keywork.widgets.textInput("first", "", "first");
            first.text_input.on_change = .{ .ptr = self, .call_fn = onChange };
            const second = keywork.widgets.textInput("second", "", "second");
            const children = [_]keywork.Widget{ first, second };
            return keywork.widgets.column(scope.allocator, &children, 4);
        }

        fn onChange(ptr: *anyopaque, text: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.last_change_len = @min(text.len, self.last_change.len);
            @memcpy(self.last_change[0..self.last_change_len], text[0..self.last_change_len]);
        }

        fn lastChange(self: *const @This()) []const u8 {
            return self.last_change[0..self.last_change_len];
        }

        fn collectInputTexts(node: *const keywork.RenderNode, out: [][]const u8, count: *usize) void {
            if (node.kind == .text_input) {
                out[count.*] = node.text orelse "";
                count.* += 1;
            }
            for (node.children) |child| collectInputTexts(child, out, count);
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 200, .max_height = 120 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();

    try runtime.keyInput(.{ .tab = .{} });
    try std.testing.expectEqualStrings("first", runtime.focused_id.?);
    const builds_after_focus = app.builds;

    // Typing edits the element buffer and fires on_change with no rebuild.
    try runtime.keyInput(.{ .text = "h" });
    try runtime.keyInput(.{ .text = "i" });
    try std.testing.expectEqual(builds_after_focus, app.builds);
    try std.testing.expectEqualStrings("hi", app.lastChange());

    // The second input keeps independent state.
    try runtime.keyInput(.{ .tab = .{} });
    try std.testing.expectEqualStrings("second", runtime.focused_id.?);
    try runtime.keyInput(.{ .text = "y" });
    try runtime.keyInput(.{ .text = "o" });

    var texts: [4][]const u8 = undefined;
    var count: usize = 0;
    TestApp.collectInputTexts(runtime.root.?, &texts, &count);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("hi", texts[0]);
    try std.testing.expectEqualStrings("yo", texts[1]);
    // on_change belongs to the first input; the second never fired it.
    try std.testing.expectEqualStrings("hi", app.lastChange());
}

test "pointer hover restyles buttons without a full rebuild" {
    const TestApp = struct {
        builds: usize = 0,

        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(ptr: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.builds += 1;
            const theme: keywork.Theme = .{
                .color_scheme = .light,
                .button_theme = .{
                    .background = keywork.colors.white,
                    .foreground = keywork.colors.ink,
                    .hover_background = keywork.colors.black,
                },
            };
            const first = try keywork.widgets.button(scope.allocator, "first", "First", .{ .ptr = self, .call_fn = noop });
            const second = try keywork.widgets.button(scope.allocator, "second", "Second", .{ .ptr = self, .call_fn = noop });
            const children = [_]keywork.Widget{ first, second };
            const column = try keywork.widgets.column(scope.allocator, &children, 4);
            return keywork.widgets.theme(scope.allocator, theme, column);
        }

        fn noop(_: *anyopaque) !void {}

        fn collectBoxBackgrounds(node: *const keywork.RenderNode, out: []keywork.Color, count: *usize) void {
            if (node.kind == .box) {
                out[count.*] = node.background;
                count.* += 1;
            }
            for (node.children) |child| collectBoxBackgrounds(child, out, count);
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 200, .max_height = 120 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();
    try std.testing.expectEqual(@as(usize, 1), app.builds);

    var backgrounds: [8]keywork.Color = undefined;
    var count: usize = 0;
    TestApp.collectBoxBackgrounds(runtime.root.?, &backgrounds, &count);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(keywork.colors.white, backgrounds[0]);
    try std.testing.expectEqual(keywork.colors.white, backgrounds[1]);

    // Hovering the first button restyles only it, with no root rebuild.
    try runtime.pointerMove(.{ .x = 5, .y = 5 });
    try std.testing.expectEqual(@as(usize, 1), app.builds);
    count = 0;
    TestApp.collectBoxBackgrounds(runtime.root.?, &backgrounds, &count);
    try std.testing.expectEqual(keywork.colors.black, backgrounds[0]);
    try std.testing.expectEqual(keywork.colors.white, backgrounds[1]);

    // Leaving the surface clears the hover styling, still without rebuilds.
    try runtime.pointerMove(null);
    try std.testing.expectEqual(@as(usize, 1), app.builds);
    count = 0;
    TestApp.collectBoxBackgrounds(runtime.root.?, &backgrounds, &count);
    try std.testing.expectEqual(keywork.colors.white, backgrounds[0]);
    try std.testing.expectEqual(keywork.colors.white, backgrounds[1]);
}

test "shortcut invokes ambient action outside text input focus" {
    const TestApp = struct {
        actions: usize = 0,

        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(ptr: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const input = keywork.widgets.textInput("input", "", "placeholder");
            const label = keywork.widgets.text("Shortcut target");
            const children = [_]keywork.Widget{ input, label };
            const column = try keywork.widgets.column(scope.allocator, &children, 4);
            const shortcut_bindings = [_]keywork.Widget.ShortcutBinding{.{ .key = .space, .intent = .action("activate") }};
            const action_bindings = [_]keywork.Widget.ActionBinding{.{ .id = "activate", .callback = .{ .ptr = self, .call_fn = activate } }};
            const shortcuts = try keywork.widgets.shortcuts(scope.allocator, &shortcut_bindings, column);
            return keywork.widgets.actions(scope.allocator, &action_bindings, shortcuts);
        }

        fn activate(ptr: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.actions += 1;
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 200, .max_height = 120 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();

    try runtime.keyInput(.space);
    try std.testing.expectEqual(@as(usize, 1), app.actions);

    try runtime.keyInput(.{ .tab = .{} });
    try std.testing.expectEqualStrings("input", runtime.focused_id.?);
    try runtime.keyInput(.space);
    try std.testing.expectEqual(@as(usize, 1), app.actions);
    try std.testing.expectEqualStrings(" ", renderedInputText(runtime.root.?).?);
}

test "non-editing shortcuts fire while a text input is focused" {
    const TestApp = struct {
        actions: usize = 0,

        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(ptr: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            var input = keywork.widgets.textInput("input", "", "placeholder");
            input.text_input.autofocus = true;
            const shortcut_bindings = [_]keywork.Widget.ShortcutBinding{
                .{ .key = .enter, .intent = .action("activate") },
                .{ .key = .escape, .intent = .action("activate") },
                .{ .key = .down, .intent = .action("activate") },
                .{ .key = .up, .intent = .action("activate") },
            };
            const action_bindings = [_]keywork.Widget.ActionBinding{.{ .id = "activate", .callback = .{ .ptr = self, .call_fn = activate } }};
            const shortcuts = try keywork.widgets.shortcuts(scope.allocator, &shortcut_bindings, input);
            return keywork.widgets.actions(scope.allocator, &action_bindings, shortcuts);
        }

        fn activate(ptr: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.actions += 1;
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 200, .max_height = 120 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();

    // The autofocus text input owns focus from the initial build.
    try std.testing.expectEqualStrings("input", runtime.focused_id.?);

    try runtime.keyInput(.enter);
    try runtime.keyInput(.escape);
    try runtime.keyInput(.down);
    try runtime.keyInput(.up);
    try std.testing.expectEqual(@as(usize, 4), app.actions);

    // Editing keys still reach the input instead of shortcuts.
    try runtime.keyInput(.{ .text = "hi" });
    try runtime.keyInput(.space);
    try runtime.keyInput(.backspace);
    try std.testing.expectEqual(@as(usize, 4), app.actions);
    try std.testing.expectEqualStrings("hi", renderedInputText(runtime.root.?).?);
    try std.testing.expectEqualStrings("input", runtime.focused_id.?);
}

test "focus widget participates in traversal and shortcut context" {
    const TestApp = struct {
        actions: usize = 0,

        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(ptr: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const label = keywork.widgets.text("Focusable shortcut target");
            const focused_label = try keywork.widgets.focus(scope.allocator, .named("label-focus"), label);
            const shortcut_bindings = [_]keywork.Widget.ShortcutBinding{.{ .key = .space, .intent = .action("activate") }};
            const action_bindings = [_]keywork.Widget.ActionBinding{.{ .id = "activate", .callback = .{ .ptr = self, .call_fn = activate } }};
            const shortcuts = try keywork.widgets.shortcuts(scope.allocator, &shortcut_bindings, focused_label);
            return keywork.widgets.actions(scope.allocator, &action_bindings, shortcuts);
        }

        fn activate(ptr: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.actions += 1;
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 240, .max_height = 80 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();

    try runtime.keyInput(.{ .tab = .{} });
    try std.testing.expectEqualStrings("label-focus", runtime.focused_id.?);
    try runtime.keyInput(.space);
    try std.testing.expectEqual(@as(usize, 1), app.actions);
}

test "autofocus focus node is selected during initial build" {
    const TestApp = struct {
        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(_: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            return keywork.widgets.focusWithOptions(
                scope.allocator,
                .named("initial"),
                keywork.widgets.text("Initial focus"),
                .{ .autofocus = true },
            );
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 240, .max_height = 80 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();

    try std.testing.expectEqualStrings("initial", runtime.focused_id.?);
    try std.testing.expect(runtime.root.?.focused);

    try runtime.clearFocus();
    try std.testing.expectEqual(@as(?[]u8, null), runtime.focused_id);
    try std.testing.expect(!runtime.root.?.focused);
}

test "autofocus replaces focused node removed during rebuild" {
    const TestApp = struct {
        show_old_focus: bool = true,

        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(ptr: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const first = if (self.show_old_focus)
                try keywork.widgets.focus(scope.allocator, .named("old"), keywork.widgets.text("Old"))
            else
                keywork.widgets.text("Removed");
            const replacement = try keywork.widgets.focusWithOptions(
                scope.allocator,
                .named("replacement"),
                keywork.widgets.text("Replacement"),
                .{ .autofocus = true },
            );
            const children = [_]keywork.Widget{ first, replacement };
            return keywork.widgets.column(scope.allocator, &children, 4);
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 240, .max_height = 120 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();

    _ = try runtime.setFocused("old");
    try runtime.rebuild();
    try std.testing.expectEqualStrings("old", runtime.focused_id.?);

    app.show_old_focus = false;
    try runtime.rebuild();
    try std.testing.expectEqualStrings("replacement", runtime.focused_id.?);
    try std.testing.expect(runtime.root.?.children[1].focused);
}

test "runtime requestFocus and clearFocus notify focus widgets" {
    const TestApp = struct {
        a_focused: usize = 0,
        a_blurred: usize = 0,
        b_focused: usize = 0,
        b_blurred: usize = 0,

        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(ptr: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const a = try keywork.widgets.focusWithOptions(
                scope.allocator,
                .named("a"),
                keywork.widgets.text("A"),
                .{ .on_focus_change = .{ .ptr = self, .call_fn = focusA } },
            );
            const b = try keywork.widgets.focusWithOptions(
                scope.allocator,
                .named("b"),
                keywork.widgets.text("B"),
                .{ .on_focus_change = .{ .ptr = self, .call_fn = focusB } },
            );
            const children = [_]keywork.Widget{ a, b };
            return keywork.widgets.column(scope.allocator, &children, 4);
        }

        fn focusA(ptr: *anyopaque, focused: bool) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (focused) {
                self.a_focused += 1;
            } else {
                self.a_blurred += 1;
            }
        }

        fn focusB(ptr: *anyopaque, focused: bool) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (focused) {
                self.b_focused += 1;
            } else {
                self.b_blurred += 1;
            }
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 240, .max_height = 120 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();

    try std.testing.expectEqual(@as(?[]u8, null), runtime.focused_id);
    try runtime.requestFocus("a");
    try std.testing.expectEqualStrings("a", runtime.focused_id.?);
    try std.testing.expect(runtime.root.?.children[0].focused);
    try std.testing.expectEqual(@as(usize, 1), app.a_focused);
    try std.testing.expectEqual(@as(usize, 0), app.a_blurred);

    try runtime.requestFocus("b");
    try std.testing.expectEqualStrings("b", runtime.focused_id.?);
    try std.testing.expect(runtime.root.?.children[1].focused);
    try std.testing.expectEqual(@as(usize, 1), app.a_blurred);
    try std.testing.expectEqual(@as(usize, 1), app.b_focused);

    try runtime.clearFocus();
    try std.testing.expectEqual(@as(?[]u8, null), runtime.focused_id);
    try std.testing.expectEqual(@as(usize, 1), app.b_blurred);
    try std.testing.expectError(error.FocusTargetNotFound, runtime.requestFocus("missing"));
}

test "focus traversal respects request and traversal policy" {
    const TestApp = struct {
        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(_: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            const a = try keywork.widgets.focus(scope.allocator, .named("a"), keywork.widgets.text("A"));
            const skipped = try keywork.widgets.focusWithOptions(
                scope.allocator,
                .named("skipped"),
                keywork.widgets.text("Skipped"),
                .{ .skip_traversal = true },
            );
            const blocked = try keywork.widgets.focusWithOptions(
                scope.allocator,
                .named("blocked"),
                keywork.widgets.text("Blocked"),
                .{ .autofocus = true, .can_request_focus = false },
            );
            const c = try keywork.widgets.focus(scope.allocator, .named("c"), keywork.widgets.text("C"));
            const children = [_]keywork.Widget{ a, skipped, blocked, c };
            return keywork.widgets.column(scope.allocator, &children, 4);
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 240, .max_height = 160 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();

    try std.testing.expectEqual(@as(?[]u8, null), runtime.focused_id);
    try runtime.keyInput(.{ .tab = .{} });
    try std.testing.expectEqualStrings("a", runtime.focused_id.?);
    try runtime.keyInput(.{ .tab = .{} });
    try std.testing.expectEqualStrings("c", runtime.focused_id.?);

    try runtime.requestFocus("skipped");
    try std.testing.expectEqualStrings("skipped", runtime.focused_id.?);
    try runtime.keyInput(.{ .tab = .{} });
    try std.testing.expectEqualStrings("c", runtime.focused_id.?);
    try std.testing.expectError(error.FocusTargetNotFocusable, runtime.requestFocus("blocked"));
}

test "focused node becoming non-requestable falls back to autofocus" {
    const TestApp = struct {
        allow_a_focus: bool = true,

        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(ptr: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const a = try keywork.widgets.focusWithOptions(
                scope.allocator,
                .named("a"),
                keywork.widgets.text("A"),
                .{ .can_request_focus = self.allow_a_focus },
            );
            const replacement = try keywork.widgets.focusWithOptions(
                scope.allocator,
                .named("replacement"),
                keywork.widgets.text("Replacement"),
                .{ .autofocus = true },
            );
            const children = [_]keywork.Widget{ a, replacement };
            return keywork.widgets.column(scope.allocator, &children, 4);
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 240, .max_height = 120 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();

    try runtime.requestFocus("a");
    try std.testing.expectEqualStrings("a", runtime.focused_id.?);

    app.allow_a_focus = false;
    try runtime.rebuild();
    try std.testing.expectEqualStrings("replacement", runtime.focused_id.?);
    try std.testing.expect(runtime.root.?.children[1].focused);
}

test "focus scope contains tab traversal once focus is inside it" {
    const TestApp = struct {
        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(_: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            const a1 = try keywork.widgets.focus(scope.allocator, .named("a1"), keywork.widgets.text("A1"));
            const a2 = try keywork.widgets.focus(scope.allocator, .named("a2"), keywork.widgets.text("A2"));
            const a_children = [_]keywork.Widget{ a1, a2 };
            const a_column = try keywork.widgets.column(scope.allocator, &a_children, 4);
            const scope_a = try keywork.widgets.focusScope(scope.allocator, "scope-a", a_column);

            const b1 = try keywork.widgets.focus(scope.allocator, .named("b1"), keywork.widgets.text("B1"));
            const b2 = try keywork.widgets.focus(scope.allocator, .named("b2"), keywork.widgets.text("B2"));
            const b_children = [_]keywork.Widget{ b1, b2 };
            const b_column = try keywork.widgets.column(scope.allocator, &b_children, 4);
            const scope_b = try keywork.widgets.focusScope(scope.allocator, "scope-b", b_column);

            const children = [_]keywork.Widget{ scope_a, scope_b };
            return keywork.widgets.column(scope.allocator, &children, 8);
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 240, .max_height = 160 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();

    try runtime.keyInput(.{ .tab = .{} });
    try std.testing.expectEqualStrings("a1", runtime.focused_id.?);
    try runtime.keyInput(.{ .tab = .{} });
    try std.testing.expectEqualStrings("a2", runtime.focused_id.?);
    try runtime.keyInput(.{ .tab = .{} });
    try std.testing.expectEqualStrings("a1", runtime.focused_id.?);
    try runtime.keyInput(.{ .tab = .{ .reverse = true } });
    try std.testing.expectEqualStrings("a2", runtime.focused_id.?);
}

test "modal focus scope traps autofocus traversal and focus requests" {
    const TestApp = struct {
        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(_: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            const background = try keywork.widgets.focusWithOptions(
                scope.allocator,
                .named("background"),
                keywork.widgets.text("Background"),
                .{ .autofocus = true },
            );

            const modal_a = try keywork.widgets.focusWithOptions(
                scope.allocator,
                .named("modal-a"),
                keywork.widgets.text("Modal A"),
                .{ .autofocus = true },
            );
            const modal_b = try keywork.widgets.focus(scope.allocator, .named("modal-b"), keywork.widgets.text("Modal B"));
            const modal_children = [_]keywork.Widget{ modal_a, modal_b };
            const modal_column = try keywork.widgets.column(scope.allocator, &modal_children, 4);
            const modal = try keywork.widgets.focusScopeWithOptions(scope.allocator, "modal", modal_column, .{ .modal = true });

            const after_modal = try keywork.widgets.focus(scope.allocator, .named("after-modal"), keywork.widgets.text("After modal"));
            const children = [_]keywork.Widget{ background, modal, after_modal };
            return keywork.widgets.column(scope.allocator, &children, 8);
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 240, .max_height = 180 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();

    try std.testing.expectEqualStrings("modal-a", runtime.focused_id.?);
    try std.testing.expectError(error.FocusTargetOutsideModal, runtime.requestFocus("background"));
    try std.testing.expectError(error.FocusTargetOutsideModal, runtime.requestFocus("after-modal"));

    try runtime.requestFocus("modal-b");
    try std.testing.expectEqualStrings("modal-b", runtime.focused_id.?);
    try runtime.keyInput(.{ .tab = .{} });
    try std.testing.expectEqualStrings("modal-a", runtime.focused_id.?);
    try runtime.keyInput(.{ .tab = .{ .reverse = true } });
    try std.testing.expectEqualStrings("modal-b", runtime.focused_id.?);

    try runtime.clearFocus();
    try runtime.keyInput(.{ .tab = .{} });
    try std.testing.expectEqualStrings("modal-a", runtime.focused_id.?);
}
