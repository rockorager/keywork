//! Keyboard input and text-editing helpers for the UI runtime.

const std = @import("std");
const uucode = @import("uucode");
const keywork = @import("../../ui.zig");
const focus_scroll = @import("focus_scroll.zig");

const log = std.log.scoped(.keywork);

pub const TextEdit = union(enum) {
    append: []const u8,
    pop_grapheme,
};

pub fn click(self: anytype, point: keywork.Point) !void {
    try pointerButton(self, .{ .button = .left, .state = .pressed, .position = point });
    try pointerButton(self, .{ .button = .left, .state = .released, .position = point });
}

pub fn pointerButton(self: anytype, event: keywork.PointerButtonEvent) !void {
    _ = self.root orelse return error.NotBuilt;
    if (self.pressed_button) |button| if (button != event.button) return;
    switch (event.state) {
        .pressed => try pointerDown(self, event),
        .released => try pointerUp(self, event),
    }
}

fn tapEvent(event: keywork.PointerButtonEvent, rect: keywork.Rect) keywork.TapEvent {
    return .{ .source = .pointer, .button = event.button, .position = event.position, .local = .{
        .x = event.position.x - rect.x,
        .y = event.position.y - rect.y,
    }, .modifiers = event.modifiers };
}

pub fn pointerDown(self: anytype, event: keywork.PointerButtonEvent) !void {
    const point = event.position;
    const root = self.root orelse return error.NotBuilt;
    // Scrollbar drags and text-input focus are primary-button interactions;
    // other buttons fall through so a button-accepting ancestor can win the
    // click hit test instead.
    if (event.button == .left) {
        if (keywork.hitTestScrollbarThumb(root, point)) |hit| {
            try focus_scroll.beginScrollbarDrag(self, hit, point);
            self.pressed_button = .left;
            return;
        }
        if (keywork.hitTestTextInput(root, point)) |id| {
            const focus_changed = try focus_scroll.setFocused(self, id);
            _ = try setPressedId(self, null);
            if (focus_changed) try self.invalidate() else try self.invalidateState();
            return;
        }
    }

    if (keywork.hitTestClick(root, point, event.button)) |hit| {
        const focus_changed = try focus_scroll.setFocused(self, hit.id);
        var needs_update = try setPressedId(self, hit.id);
        self.pressed_button = event.button;
        if (hit.tap_down) |callback| {
            try callback.call(tapEvent(event, hit.rect));
            needs_update = true;
        }
        if (hit.activation == .press) {
            log.info("clicked button {s} at {d},{d}", .{ hit.id, point.x, point.y });
            if (try activateClick(self, hit, tapEvent(event, hit.rect))) needs_update = true;
        }
        if (focus_changed) {
            try self.invalidate();
        } else if (needs_update) {
            try self.invalidateState();
        }
    } else if (event.button == .left) {
        self.autofocus_suppressed = true;
        const focus_changed = try focus_scroll.setFocused(self, null);
        log.info("pointer down on empty space at {d},{d}", .{ point.x, point.y });
        _ = try setPressedId(self, null);
        if (focus_changed) try self.invalidate() else try self.invalidateState();
    }
}

pub fn pointerUp(self: anytype, event: keywork.PointerButtonEvent) !void {
    const point = event.position;
    if (self.scrollbar_drag != null) {
        focus_scroll.clearScrollbarDrag(self);
        self.pressed_button = null;
        return;
    }
    const root = self.root orelse return error.NotBuilt;
    const hit = keywork.hitTestClick(root, point, event.button);
    const pressed_hit = if (self.pressed_id) |pressed_id| keywork.findClickHitById(root, pressed_id) else null;
    const should_activate = if (self.pressed_id) |pressed_id| blk: {
        const hit_id = if (hit) |click_hit| click_hit.id else break :blk false;
        break :blk std.mem.eql(u8, pressed_id, hit_id);
    } else false;

    var needs_update = try setPressedId(self, null);
    self.pressed_button = null;
    if (should_activate) {
        const click_hit = hit.?;
        if (click_hit.tap_up) |callback| {
            try callback.call(tapEvent(event, click_hit.rect));
            needs_update = true;
        }
        if (click_hit.activation == .release) {
            log.info("clicked button {s} at {d},{d}", .{ click_hit.id, point.x, point.y });
            if (try activateClick(self, click_hit, tapEvent(event, click_hit.rect))) needs_update = true;
        }
    } else if (pressed_hit) |cancel_hit| {
        if (cancel_hit.tap_cancel) |callback| {
            try callback.call(tapEvent(event, cancel_hit.rect));
            needs_update = true;
        }
    }

    if (needs_update) try self.invalidateState();
}

pub fn keyInput(self: anytype, input: keywork.KeyInput) !void {
    if (try activateShortcut(self, input)) {
        try self.invalidate();
        return;
    }

    switch (input) {
        .tab => |tab| {
            try focus_scroll.focusNext(self, tab.reverse);
            try self.invalidate();
        },
        .text => |bytes| try editFocusedTextInput(self, .{ .append = bytes }),
        .backspace => try editFocusedTextInput(self, .pop_grapheme),
        .space => {
            const target = focus_scroll.focusedTarget(self) orelse return;
            switch (target.kind) {
                .text_input => try editFocusedTextInput(self, .{ .append = " " }),
                .clickable => {
                    _ = try activateClick(self, .{ .id = target.id, .callback = target.callback }, .{ .source = .keyboard });
                    try self.invalidateState();
                },
                .focus => {},
            }
        },
        .enter => {
            const target = focus_scroll.focusedTarget(self) orelse return;
            switch (target.kind) {
                .text_input => {
                    self.autofocus_suppressed = true;
                    _ = try focus_scroll.setFocused(self, null);
                    try self.invalidate();
                },
                .clickable => {
                    _ = try activateClick(self, .{ .id = target.id, .callback = target.callback }, .{ .source = .keyboard });
                    try self.invalidateState();
                },
                .focus => {},
            }
        },
        .escape, .up, .down => {},
    }
}

pub fn editFocusedTextInput(self: anytype, edit: TextEdit) !void {
    if (!focus_scroll.focusedTargetIs(self, .text_input)) return;
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

pub fn activateShortcut(self: anytype, input: keywork.KeyInput) !bool {
    const shortcut_key = keywork.shortcutKeyForInput(input) orelse return false;
    if (focus_scroll.focusedTargetIs(self, .text_input) and !keywork.shortcutAllowedWhileEditing(shortcut_key)) return false;
    const element_root = if (self.element_root) |*root| root else return false;
    const callback = if (self.focused_id) |focused_id|
        keywork.findFocusedShortcutAction(element_root, shortcut_key, focused_id) orelse keywork.findShortcutAction(element_root, shortcut_key) orelse return false
    else
        keywork.findShortcutAction(element_root, shortcut_key) orelse return false;
    try callback.call();
    return true;
}

pub fn activateClick(self: anytype, hit: keywork.ClickHit, event: keywork.TapEvent) !bool {
    _ = self;
    if (hit.callback) |callback| {
        try callback.call(event);
        return true;
    }
    return false;
}

pub fn cursorShape(self: anytype, point: keywork.Point) keywork.CursorShape {
    const root = self.root orelse return .default;
    return keywork.hitTestCursorShape(root, point);
}

pub fn pointerMove(self: anytype, point: ?keywork.Point) !void {
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
                .vertical => try focus_scroll.scrollElementById(self, drag.id, 0, delta),
                .horizontal => try focus_scroll.scrollElementById(self, drag.id, delta, 0),
            }
        }
        return;
    }
    const hit = if (point) |position| blk: {
        const root = self.root orelse return error.NotBuilt;
        break :blk keywork.hitTestClick(root, position, .left);
    } else null;
    const hit_id = if (hit) |click_hit| click_hit.id else null;
    // Capture the previous target's hover callback before setHoveredId
    // frees the old id. Hover callbacks fire only here, from real pointer
    // motion, so content scrolling beneath a stationary pointer cannot
    // re-trigger them.
    const left_hover_change = if (self.hovered_id) |old_id| blk: {
        const root = self.root orelse break :blk null;
        break :blk if (keywork.findClickHitById(root, old_id)) |old_hit| old_hit.hover_change else null;
    } else null;
    if (!try setHoveredId(self, hit_id)) return;
    if (left_hover_change) |callback| try callback.call(false);
    if (hit) |click_hit| {
        if (click_hit.hover_change) |callback| try callback.call(true);
    }
    try self.invalidateState();
}

pub fn setHoveredId(self: anytype, id: ?[]const u8) !bool {
    return setInteractionId(self, &self.hovered_id, id);
}

pub fn setPressedId(self: anytype, id: ?[]const u8) !bool {
    return setInteractionId(self, &self.pressed_id, id);
}

pub fn setInteractionId(self: anytype, slot: *?[]u8, id: ?[]const u8) !bool {
    if (slot.*) |old_id| {
        if (id) |new_id| {
            if (std.mem.eql(u8, old_id, new_id)) return false;
        }
    } else if (id == null) return false;

    const old_id = slot.*;
    if (old_id) |value| try queueInteractionRefresh(self, value);
    if (id) |value| try queueInteractionRefresh(self, value);
    if (old_id) |value| self.allocator.free(value);
    slot.* = if (id) |new_id| try self.allocator.dupe(u8, new_id) else null;
    return true;
}

pub fn queueInteractionRefresh(self: anytype, id: []const u8) !void {
    for (self.pending_interaction_ids.items) |pending| {
        if (std.mem.eql(u8, pending, id)) return;
    }
    const owned = try self.allocator.dupe(u8, id);
    errdefer self.allocator.free(owned);
    try self.pending_interaction_ids.append(self.allocator, owned);
}

pub fn waylandPointerButton(comptime Runtime: type, ctx: *anyopaque, event: keywork.PointerButtonEvent) void {
    const self: *Runtime = @ptrCast(@alignCast(ctx));
    pointerButton(self, event) catch |err| log.err("pointer button handling failed: {}", .{err});
}

pub fn waylandCursorShape(comptime Runtime: type, ctx: *anyopaque, point: keywork.Point) keywork.CursorShape {
    const self: *Runtime = @ptrCast(@alignCast(ctx));
    return cursorShape(self, point);
}

pub fn waylandPointerMove(comptime Runtime: type, ctx: *anyopaque, point: ?keywork.Point) void {
    const self: *Runtime = @ptrCast(@alignCast(ctx));
    pointerMove(self, point) catch |err| log.err("pointer motion failed: {}", .{err});
}

pub fn waylandKeyInput(comptime Runtime: type, ctx: *anyopaque, input: keywork.KeyInput) void {
    const self: *Runtime = @ptrCast(@alignCast(ctx));
    keyInput(self, input) catch |err| log.err("key input failed: {}", .{err});
}

pub fn popLastGrapheme(bytes: *std.ArrayList(u8)) void {
    if (bytes.items.len == 0) return;

    var it = uucode.grapheme.utf8Iterator(bytes.items);
    var start: usize = 0;
    while (it.nextGrapheme()) |grapheme| {
        start = grapheme.start;
    }
    bytes.shrinkRetainingCapacity(start);
}
