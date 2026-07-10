//! hit testing behavior for the retained UI model.

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

pub fn hitTestButton(node: *const RenderNode, point: Point) ?[]const u8 {
    return if (hitTestClick(node, point, .left)) |hit| hit.id else null;
}

pub const ClickHit = struct {
    id: []const u8,
    callback: ?Widget.TapCallback = null,
    tap_down: ?Widget.TapCallback = null,
    tap_up: ?Widget.TapCallback = null,
    tap_cancel: ?Widget.TapCallback = null,
    rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    activation: Widget.ClickActivation = .release,
    cursor: CursorShape = .default,
};

pub const FocusTarget = struct {
    id: []const u8,
    kind: Kind,
    callback: ?Widget.TapCallback = null,
    scope_id: ?[]const u8 = null,
    modal_scope_id: ?[]const u8 = null,
    autofocus: bool = false,
    skip_traversal: bool = false,
    can_request_focus: bool = true,
    focus_change_callback: ?Widget.FocusChangeCallback = null,

    pub const Kind = enum {
        text_input,
        clickable,
        focus,
    };
};

pub fn collectFocusTargets(allocator: std.mem.Allocator, node: *const RenderNode) ![]FocusTarget {
    var targets: std.ArrayList(FocusTarget) = .empty;
    errdefer targets.deinit(allocator);
    try appendFocusTargets(allocator, &targets, node, null, null);
    return try targets.toOwnedSlice(allocator);
}

fn appendFocusTargets(
    allocator: std.mem.Allocator,
    targets: *std.ArrayList(FocusTarget),
    node: *const RenderNode,
    scope_id: ?[]const u8,
    modal_scope_id: ?[]const u8,
) !void {
    const active_scope_id = node.focus_scope_id orelse scope_id;
    const active_modal_scope_id = if (node.modal_focus_scope) node.focus_scope_id else modal_scope_id;
    switch (node.kind) {
        .text_input => if (node.focus_id) |id| try targets.append(allocator, .{ .id = id, .kind = .text_input, .scope_id = active_scope_id, .modal_scope_id = active_modal_scope_id, .autofocus = node.autofocus }),
        .focus => if (node.focus_id) |id| try targets.append(allocator, .{
            .id = id,
            .kind = .focus,
            .scope_id = active_scope_id,
            .modal_scope_id = active_modal_scope_id,
            .autofocus = node.autofocus,
            .skip_traversal = node.skip_traversal,
            .can_request_focus = node.can_request_focus,
            .focus_change_callback = node.focus_change_callback,
        }),
        .clickable => if (node.click_callback) |callback| {
            if (node.clickable_id) |id| try targets.append(allocator, .{ .id = id, .kind = .clickable, .callback = callback, .scope_id = active_scope_id, .modal_scope_id = active_modal_scope_id });
        },
        else => {},
    }
    for (node.children) |child| {
        try appendFocusTargets(allocator, targets, child, active_scope_id, active_modal_scope_id);
    }
}

pub fn findFocusTarget(node: *const RenderNode, id: []const u8) ?FocusTarget {
    return findFocusTargetScoped(node, id, null, null);
}

fn findFocusTargetScoped(node: *const RenderNode, id: []const u8, scope_id: ?[]const u8, modal_scope_id: ?[]const u8) ?FocusTarget {
    const active_scope_id = node.focus_scope_id orelse scope_id;
    const active_modal_scope_id = if (node.modal_focus_scope) node.focus_scope_id else modal_scope_id;
    switch (node.kind) {
        .text_input => if (node.focus_id) |focus_id| {
            if (std.mem.eql(u8, focus_id, id)) return .{ .id = focus_id, .kind = .text_input, .scope_id = active_scope_id, .modal_scope_id = active_modal_scope_id, .autofocus = node.autofocus };
        },
        .focus => if (node.focus_id) |focus_id| {
            if (std.mem.eql(u8, focus_id, id)) return .{
                .id = focus_id,
                .kind = .focus,
                .scope_id = active_scope_id,
                .modal_scope_id = active_modal_scope_id,
                .autofocus = node.autofocus,
                .skip_traversal = node.skip_traversal,
                .can_request_focus = node.can_request_focus,
                .focus_change_callback = node.focus_change_callback,
            };
        },
        .clickable => if (node.click_callback) |callback| {
            if (node.clickable_id) |clickable_id| {
                if (std.mem.eql(u8, clickable_id, id)) return .{ .id = clickable_id, .kind = .clickable, .callback = callback, .scope_id = active_scope_id, .modal_scope_id = active_modal_scope_id };
            }
        },
        else => {},
    }
    for (node.children) |child| {
        if (findFocusTargetScoped(child, id, active_scope_id, active_modal_scope_id)) |target| return target;
    }
    return null;
}

pub fn hitTestClick(node: *const RenderNode, point: Point, button: model.PointerButton) ?ClickHit {
    if (node.kind.isViewport() and !node.rect.contains(point)) return null;
    var index = node.children.len;
    while (index > 0) {
        index -= 1;
        if (hitTestClick(node.children[index], point, button)) |hit| return hit;
    }

    if (node.kind == .clickable and node.rect.contains(point) and node.click_buttons.accepts(button)) {
        if (!nodeHasTapCallback(node)) return null;
        return .{
            .id = node.clickable_id orelse return null,
            .callback = node.click_callback,
            .tap_down = node.tap_down_callback,
            .tap_up = node.tap_up_callback,
            .tap_cancel = node.tap_cancel_callback,
            .rect = node.rect,
            .activation = node.click_activation,
            .cursor = node.click_cursor,
        };
    }
    if (node.kind == .render_object) {
        if (node.render_object) |render_object| {
            if (render_object.hitTest(node.rect, point)) |id| return .{ .id = id };
        }
    }
    return null;
}

test "right click skips left-only child and hits accepting ancestor" {
    const Callback = struct {
        fn call(_: *anyopaque, _: model.TapEvent) !void {}
    };
    var state: u8 = 0;
    const callback: Widget.TapCallback = .{ .ptr = &state, .call_fn = Callback.call };
    var child: RenderNode = .{
        .kind = .clickable,
        .rect = .{ .x = 2, .y = 2, .width = 10, .height = 10 },
        .clickable_id = "child",
        .click_callback = callback,
    };
    var children = [_]*RenderNode{&child};
    const root: RenderNode = .{
        .kind = .clickable,
        .rect = .{ .x = 0, .y = 0, .width = 20, .height = 20 },
        .clickable_id = "ancestor",
        .click_callback = callback,
        .click_buttons = .{ .right = true },
        .children = &children,
    };

    try std.testing.expectEqualStrings("ancestor", hitTestClick(&root, .{ .x = 5, .y = 5 }, .right).?.id);
    try std.testing.expectEqualStrings("child", hitTestClick(&root, .{ .x = 5, .y = 5 }, .left).?.id);
}

pub const ScrollHit = struct { callback: Widget.ScrollEventCallback, rect: Rect };

pub fn hitTestScrollCallback(node: *const RenderNode, point: Point) ?ScrollHit {
    if (node.kind.isViewport() and !node.rect.contains(point)) return null;
    var index = node.children.len;
    while (index > 0) {
        index -= 1;
        if (hitTestScrollCallback(node.children[index], point)) |hit| return hit;
    }
    if (node.rect.contains(point)) if (node.scroll_event_callback) |callback| return .{ .callback = callback, .rect = node.rect };
    return null;
}

pub fn findClickHitById(node: *const RenderNode, id: []const u8) ?ClickHit {
    if (node.kind == .clickable) {
        if (node.clickable_id) |clickable_id| {
            if (std.mem.eql(u8, clickable_id, id) and nodeHasTapCallback(node)) return .{
                .id = clickable_id,
                .callback = node.click_callback,
                .tap_down = node.tap_down_callback,
                .tap_up = node.tap_up_callback,
                .tap_cancel = node.tap_cancel_callback,
                .rect = node.rect,
                .activation = node.click_activation,
            };
        }
    }
    for (node.children) |child| {
        if (findClickHitById(child, id)) |hit| return hit;
    }
    return null;
}

fn nodeHasTapCallback(node: *const RenderNode) bool {
    return node.click_callback != null or
        node.tap_down_callback != null or
        node.tap_up_callback != null or
        node.tap_cancel_callback != null;
}

pub fn hitTestTextInput(node: *const RenderNode, point: Point) ?[]const u8 {
    if (node.kind.isViewport() and !node.rect.contains(point)) return null;
    var index = node.children.len;
    while (index > 0) {
        index -= 1;
        if (hitTestTextInput(node.children[index], point)) |id| return id;
    }

    if (node.kind == .text_input and node.rect.contains(point)) {
        return node.focus_id;
    }
    return null;
}

pub fn hitTestScroll(node: *const RenderNode, point: Point) ?[]const u8 {
    if (node.kind.isViewport() and !node.rect.contains(point)) return null;
    var index = node.children.len;
    while (index > 0) {
        index -= 1;
        if (hitTestScroll(node.children[index], point)) |id| return id;
    }
    if (node.kind.isViewport()) return node.scroll_id;
    return null;
}

pub const RevealAdjustment = struct {
    /// Borrowed from the render node; valid until the next layout.
    id: []const u8,
    dx: f32,
    dy: f32,
};

/// Collects the viewport offset increases needed to bring the focus
/// target with the given id into view, innermost viewport first. Returns
/// the target's rect (shifted by the collected adjustments) when found.
pub fn collectRevealAdjustments(
    allocator: std.mem.Allocator,
    node: *const RenderNode,
    id: []const u8,
    out: *std.ArrayList(RevealAdjustment),
) !?Rect {
    const is_target = switch (node.kind) {
        .text_input, .focus => node.focus_id != null and std.mem.eql(u8, node.focus_id.?, id),
        .clickable => node.clickable_id != null and std.mem.eql(u8, node.clickable_id.?, id),
        else => false,
    };
    if (is_target) return node.rect;
    for (node.children) |child| {
        const target_rect = try collectRevealAdjustments(allocator, child, id, out) orelse continue;
        var rect = target_rect;
        if (node.kind.isViewport()) {
            if (node.scroll_id) |scroll_id| {
                const dx = revealDelta(rect.x, rect.width, node.rect.x, node.rect.width);
                const dy = revealDelta(rect.y, rect.height, node.rect.y, node.rect.height);
                if (dx != 0 or dy != 0) {
                    try out.append(allocator, .{ .id = scroll_id, .dx = dx, .dy = dy });
                    rect.x -= dx;
                    rect.y -= dy;
                }
            }
        }
        return rect;
    }
    return null;
}

/// Offset increase that reveals [start, start+extent) inside the viewport
/// span: the minimum scroll distance, aligning to the near edge when the
/// target is larger than the viewport.
fn revealDelta(start: f32, extent: f32, viewport_start: f32, viewport_extent: f32) f32 {
    if (start < viewport_start) return start - viewport_start;
    const end = start + extent;
    const viewport_end = viewport_start + viewport_extent;
    if (end > viewport_end) return @min(start - viewport_start, end - viewport_end);
    return 0;
}

pub fn hitTestCursorShape(node: *const RenderNode, point: Point) CursorShape {
    if (hitTestTextInput(node, point) != null) return .text;
    if (hitTestClick(node, point, .left)) |hit| return hit.cursor;
    return .default;
}
