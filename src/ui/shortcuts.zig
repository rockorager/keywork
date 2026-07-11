//! shortcuts behavior for the retained UI model.

const std = @import("std");
const model = @import("model.zig");

const Widget = model.Widget;
const Element = model.Element;
const RenderNode = model.RenderNode;
const Color = model.Color;
const colors = model.colors;
const Point = model.Point;
const Rect = model.Rect;
const KeyInput = model.KeyInput;
const ShortcutKey = model.ShortcutKey;
const Intent = model.Intent;
const CursorShape = model.CursorShape;
const DisplayList = model.DisplayList;
const ResolvedTextStyle = model.ResolvedTextStyle;
const ActionScope = model.ActionScope;

pub fn shortcutKeyForInput(input: KeyInput) ?ShortcutKey {
    return switch (input) {
        .enter => .enter,
        .space => .space,
        .backspace => .backspace,
        .escape => .escape,
        .up => .up,
        .down => .down,
        // Plain tab may be bound as a shortcut (unbound it falls through
        // to focus traversal); shift-tab always keeps reverse traversal.
        .tab => |tab| if (tab.reverse) null else .tab,
        .text => null,
    };
}

/// Keys that never edit text may activate shortcuts even while a text
/// input owns focus; editing keys must keep reaching the input.
pub fn shortcutAllowedWhileEditing(key: ShortcutKey) bool {
    return switch (key) {
        .enter, .tab, .escape, .up, .down => true,
        .space, .backspace => false,
    };
}

pub fn findShortcutAction(element: *const Element, key: ShortcutKey) ?Widget.Callback {
    return findShortcutActionScoped(element, key, null);
}

pub fn findFocusedShortcutAction(element: *const Element, key: ShortcutKey, focused_id: []const u8) ?Widget.Callback {
    return findFocusedShortcutActionScoped(element, key, focused_id, null, null);
}

const ShortcutScope = struct {
    bindings: []const Widget.ShortcutBinding,
    parent: ?*const ShortcutScope = null,
};

fn findShortcutActionScoped(element: *const Element, key: ShortcutKey, scope: ?*const ActionScope) ?Widget.Callback {
    switch (element.widget) {
        .actions => |actions_widget| {
            const nested: ActionScope = .{ .bindings = actions_widget.bindings, .parent = scope };
            for (element.children) |*child| {
                if (findShortcutActionScoped(child, key, &nested)) |callback| return callback;
            }
            return null;
        },
        else => {},
    }

    switch (element.widget) {
        .shortcuts => |shortcuts_widget| {
            for (shortcuts_widget.bindings) |binding| {
                if (binding.key != key) continue;
                if (findActionForIntent(scope, binding.intent)) |callback| return callback;
            }
        },
        else => {},
    }

    for (element.children) |*child| {
        if (findShortcutActionScoped(child, key, scope)) |callback| return callback;
    }
    return null;
}

pub fn findActionForIntent(scope: ?*const ActionScope, intent: Intent) ?Widget.Callback {
    var cursor = scope;
    while (cursor) |action_scope| {
        for (action_scope.bindings) |binding| {
            if (std.mem.eql(u8, binding.id, intent.action_id)) return binding.callback;
        }
        cursor = action_scope.parent;
    }
    return null;
}

fn findFocusedShortcutActionScoped(
    element: *const Element,
    key: ShortcutKey,
    focused_id: []const u8,
    actions: ?*const ActionScope,
    shortcuts: ?*const ShortcutScope,
) ?Widget.Callback {
    switch (element.widget) {
        .actions => |actions_widget| {
            const nested_actions: ActionScope = .{ .bindings = actions_widget.bindings, .parent = actions };
            return findFocusedShortcutActionInChildren(element, key, focused_id, &nested_actions, shortcuts);
        },
        .shortcuts => |shortcuts_widget| {
            const nested_shortcuts: ShortcutScope = .{ .bindings = shortcuts_widget.bindings, .parent = shortcuts };
            if (elementIsFocused(element, focused_id)) return findShortcutInScope(&nested_shortcuts, key, actions);
            return findFocusedShortcutActionInChildren(element, key, focused_id, actions, &nested_shortcuts);
        },
        else => {
            if (elementIsFocused(element, focused_id)) return findShortcutInScope(shortcuts, key, actions);
            return findFocusedShortcutActionInChildren(element, key, focused_id, actions, shortcuts);
        },
    }
}

fn findFocusedShortcutActionInChildren(
    element: *const Element,
    key: ShortcutKey,
    focused_id: []const u8,
    actions: ?*const ActionScope,
    shortcuts: ?*const ShortcutScope,
) ?Widget.Callback {
    for (element.children) |*child| {
        if (findFocusedShortcutActionScoped(child, key, focused_id, actions, shortcuts)) |callback| return callback;
    }
    return null;
}

fn findShortcutInScope(scope: ?*const ShortcutScope, key: ShortcutKey, actions: ?*const ActionScope) ?Widget.Callback {
    var cursor = scope;
    while (cursor) |shortcut_scope| {
        for (shortcut_scope.bindings) |binding| {
            if (binding.key != key) continue;
            if (findActionForIntent(actions, binding.intent)) |callback| return callback;
        }
        cursor = shortcut_scope.parent;
    }
    return null;
}

fn elementIsFocused(element: *const Element, focused_id: []const u8) bool {
    return switch (element.widget) {
        .button => |button_widget| std.mem.eql(u8, button_widget.id, focused_id),
        .clickable => |clickable_widget| std.mem.eql(u8, clickable_widget.id, focused_id),
        .focus => |focus_widget| std.mem.eql(u8, focus_widget.node.id, focused_id),
        .text_input => |input_widget| std.mem.eql(u8, input_widget.focus_node.id, focused_id),
        else => false,
    };
}
