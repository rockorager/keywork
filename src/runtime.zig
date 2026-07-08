//! Runtime orchestration for Keywork applications.

const std = @import("std");
const uucode = @import("uucode");
const appearance = @import("appearance.zig");
const keywork = @import("core.zig");

const log = std.log.scoped(.keywork);

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
const Loop = @import("loop.zig").Loop;

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    backend: RenderBackend,
    constraints: Constraints,
    widget: keywork.Widget = keywork.widgets.text(""),
    render_factory: ?keywork.RenderFactory = null,
    color_scheme: appearance.ColorScheme,
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
    frame_background: ?keywork.Color = null,
    repaint_pending: bool = false,
    pending_interaction_ids: std.ArrayList([]u8) = .empty,
    handler_sink: keywork.HandlerSink,
    active_document_id: keywork.DocumentId = 0,
    rebuild_pending: bool = false,
    state_rebuild_pending: bool = false,
    frame_pending: bool = false,
    rendering: bool = false,
    repaint_scheduler: ?RepaintScheduler = null,
    repaint_scheduler_context: ?*anyopaque = null,

    pub const RepaintScheduler = *const fn (ctx: *anyopaque) anyerror!void;

    pub fn init(
        allocator: std.mem.Allocator,
        backend: RenderBackend,
        constraints: Constraints,
        handler_sink: keywork.HandlerSink,
        color_scheme: appearance.ColorScheme,
    ) !Runtime {
        var self: Runtime = .{
            .allocator = allocator,
            .backend = backend,
            .constraints = constraints,
            .color_scheme = color_scheme,
            .handler_sink = handler_sink,
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
    }

    pub fn frameSize(self: *const Runtime) Size {
        return .{ .width = self.constraints.max_width, .height = self.constraints.max_height };
    }

    pub fn repaint(self: *Runtime) !void {
        try self.presentFrame();
    }

    pub fn requestRepaint(self: *Runtime) !void {
        self.repaint_pending = true;
        if (self.repaint_scheduler) |scheduler| {
            try scheduler(self.repaint_scheduler_context.?);
            return;
        }
        if (!self.frame_pending and !self.rendering) try self.presentFrame();
    }

    pub fn setRepaintScheduler(self: *Runtime, context: *anyopaque, scheduler: RepaintScheduler) void {
        self.repaint_scheduler_context = context;
        self.repaint_scheduler = scheduler;
    }

    pub fn setDocument(
        self: *Runtime,
        widget: *const keywork.Widget,
        document_id: keywork.DocumentId,
        render_factory: keywork.RenderFactory,
    ) !void {
        const previous_widget = self.widget;
        const previous_document_id = self.active_document_id;
        const previous_render_factory = self.render_factory;
        self.widget = widget.*;
        self.active_document_id = document_id;
        self.render_factory = render_factory;
        self.invalidate() catch |err| {
            self.widget = previous_widget;
            self.active_document_id = previous_document_id;
            self.render_factory = previous_render_factory;
            return err;
        };
    }

    fn emitHandler(self: *Runtime, handler: keywork.HandlerRef, payload: keywork.EventPayload) !void {
        if (handler.document != self.active_document_id) return;
        try self.handler_sink.emit(handler, payload);
    }

    pub fn invalidate(self: *Runtime) !void {
        self.rebuild_pending = true;
        try self.requestRepaint();
    }

    pub fn setColorScheme(self: *Runtime, color_scheme: appearance.ColorScheme) !void {
        if (self.color_scheme == color_scheme) return;
        self.color_scheme = color_scheme;
        try self.invalidate();
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
        // Consume pending flags before rebuilding so invalidations raised during
        // the rebuild are observed on the next pass instead of being cleared and
        // dropped.
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
        const background = self.frame_background orelse keywork.Theme.fromColorScheme(self.color_scheme.name()).color_scheme.surface;
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
        const should_activate = if (self.pressed_id) |pressed_id| blk: {
            const hit_id = if (hit) |click_hit| click_hit.id else break :blk false;
            break :blk std.mem.eql(u8, pressed_id, hit_id);
        } else false;

        var needs_update = try self.setPressedId(null);
        if (should_activate) {
            const click_hit = hit.?;
            if (click_hit.activation == .release) {
                log.info("clicked button {s} at {d},{d}", .{ click_hit.id, point.x, point.y });
                if (try self.activateClick(click_hit)) needs_update = true;
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
                if (target.focus_change_handler) |handler| try self.emitHandler(handler, .{ .bool = false });
            }
            self.allocator.free(old_id);
            self.focused_id = null;
        }

        if (id) |new_id| {
            self.autofocus_suppressed = false;
            self.focused_id = try self.allocator.dupe(u8, new_id);
            log.info("focused {s}", .{new_id});
            if (self.focusedTarget()) |target| {
                if (target.focus_change_handler) |handler| try self.emitHandler(handler, .{ .bool = true });
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
                    .text_field => try self.editFocusedTextInput(.{ .append = " " }),
                    .gesture_detector => {
                        if (target.handler) |handler| _ = try self.activateClick(.{ .id = target.id, .handler = handler });
                        try self.invalidateState();
                    },
                    .focus => {},
                }
            },
            .enter => {
                const target = self.focusedTarget() orelse return;
                switch (target.kind) {
                    .text_field => {
                        self.autofocus_suppressed = true;
                        _ = try self.setFocused(null);
                        try self.invalidate();
                    },
                    .gesture_detector => {
                        if (target.handler) |handler| _ = try self.activateClick(.{ .id = target.id, .handler = handler });
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

    /// Applies a text edit to the focused text input's element-owned editing
    /// state, emits its on_change handler, and schedules a dirty-state pass.
    /// Typing relayouts exactly one input; no rebuild.
    fn editFocusedTextInput(self: *Runtime, edit: TextEdit) !void {
        if (!self.focusedTargetIs(.text_field)) return;
        const focused_id = self.focused_id orelse return;
        const element_root = if (self.element_root) |*element_root| element_root else return;
        const input = keywork.dirtyTextInputElement(element_root, focused_id) orelse return;
        const state = keywork.textInputState(input);
        switch (edit) {
            .append => |bytes| try state.text.appendSlice(self.allocator, bytes),
            .pop_grapheme => popLastGrapheme(&state.text),
        }
        if (input.widget.text_field.on_change) |handler_id| {
            try self.emitHandler(.{ .document = input.document_id, .handler = handler_id }, .{ .text = state.text.items });
        }
        try self.invalidateState();
    }

    fn activateShortcut(self: *Runtime, input: KeyInput) !bool {
        const shortcut_key = keywork.shortcutKeyForInput(input) orelse return false;
        if (self.focusedTargetIs(.text_field) and !keywork.shortcutAllowedWhileEditing(shortcut_key)) return false;
        const element_root = if (self.element_root) |*root| root else return false;
        const handler = if (self.focused_id) |focused_id|
            keywork.findFocusedShortcutHandler(element_root, focused_id, shortcut_key) orelse keywork.findShortcutHandler(element_root, shortcut_key) orelse return false
        else
            keywork.findShortcutHandler(element_root, shortcut_key) orelse return false;
        try self.emitHandler(handler, .none);
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
        try self.emitHandler(hit.handler, .none);
        return true;
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
    /// deferred to the next frame so the event path observes stable widget
    /// state until the next refresh replaces it.
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
        var build_scope = self.buildScope();
        var start: usize = 0;
        while (start < self.pending_interaction_ids.items.len) {
            var ids: [8][]const u8 = undefined;
            const count = @min(ids.len, self.pending_interaction_ids.items.len - start);
            for (self.pending_interaction_ids.items[start..][0..count], 0..) |id, index| ids[index] = id;
            _ = try keywork.refreshInteractionElements(self.allocator, &build_scope, element_root, self.constraints, ids[0..count]);
            start += count;
        }
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
            .single_child_scroll_view => {
                const state = keywork.scrollState(scroll_element);
                state.offset_x = @max(0, state.offset_x + dx);
                state.offset_y = @max(0, state.offset_y + dy);
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

    pub fn waylandKeyInput(ctx: *anyopaque, input: KeyInput) void {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        self.keyInput(input) catch |err| {
            log.err("key input failed: {}", .{err});
        };
    }

    pub fn fileChanged(
        ctx: *anyopaque,
        _: *Loop,
        path: []const u8,
        mask: u32,
        _: ?[]const u8,
    ) !void {
        log.info("reload requested for {s} mask=0x{x}", .{ path, mask });
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        try self.invalidate();
    }

    fn rebuild(self: *Runtime) !void {
        errdefer self.discardRetainedTrees();
        const max_focus_rebuild_passes = 4;
        var pass: usize = 0;
        while (true) : (pass += 1) {
            var build_scope = self.buildScope();
            if (self.element_root) |*element_root| {
                try keywork.updateElementTreeScoped(self.allocator, &build_scope, element_root, &self.widget, self.constraints);
            } else {
                self.element_root = try keywork.buildElementTreeScoped(self.allocator, &build_scope, &self.widget, self.constraints);
            }

            try self.rebuildRetainedTrees();

            if (!try self.reconcileFocusAfterRebuild()) break;
            if (pass + 1 >= max_focus_rebuild_passes) return error.FocusDidNotStabilize;
        }
    }

    fn rebuildDirtyState(self: *Runtime) !void {
        errdefer self.discardRetainedTrees();
        const element_root = if (self.element_root) |*element_root| element_root else {
            try self.rebuild();
            return;
        };

        var build_scope = self.buildScope();
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

    /// Element widgets own payloads borrowed by render nodes. If an update
    /// fails after partially replacing widgets, the previous render tree may
    /// contain stale pointers, so neither retained tree is safe to preserve.
    fn discardRetainedTrees(self: *Runtime) void {
        self.root = null;
        if (self.element_root) |*element_root| {
            keywork.destroyElementTree(self.allocator, element_root);
            self.element_root = null;
        }
        self.rebuild_pending = true;
    }

    fn buildScope(self: *Runtime) BuildScope {
        return .{
            .document_id = self.active_document_id,
            .theme = keywork.Theme.fromColorScheme(self.color_scheme.name()),
            .interaction = .{ .hovered_id = self.hovered_id, .pressed_id = self.pressed_id, .focused_id = self.focused_id },
            .render_factory = self.render_factory,
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

    try bytes.appendSlice(std.testing.allocator, "a🇺🇸");
    popLastGrapheme(&bytes);
    try std.testing.expectEqualStrings("a", bytes.items);
    popLastGrapheme(&bytes);
    try std.testing.expectEqualStrings("", bytes.items);
}
