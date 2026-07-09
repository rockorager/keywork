//! Layout and retained render-node damage behavior for the UI model.

const std = @import("std");
const model = @import("model.zig");

const Widget = model.Widget;
const Element = model.Element;
const RenderNode = model.RenderNode;
const Color = model.Color;
const colors = model.colors;
const Size = model.Size;
const Point = model.Point;
const Rect = model.Rect;
const Constraints = model.Constraints;
const TextMeasurer = model.TextMeasurer;
const ResolvedTextStyle = model.ResolvedTextStyle;
const input_min_width = model.input_min_width;
const LayoutError = model.LayoutError;
const scrollState = model.scrollState;
const listState = model.listState;
const textInputState = model.textInputState;
const listVisibleRange = model.listVisibleRange;
const scrollChildConstraints = model.scrollChildConstraints;

fn ensureRenderNode(allocator: std.mem.Allocator, element: *Element) !*RenderNode {
    if (element.render_node) |node| return node;
    const node = try allocator.create(RenderNode);
    node.* = .{ .kind = .spacer, .rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 } };
    element.render_node = node;
    return node;
}

/// Replaces the node payload in place, preserving node identity and its
/// child slice. Payload strings are borrowed from the element's widget,
/// which owns them and strictly outlives the node.
fn commitRenderNode(node: *RenderNode, value: RenderNode) void {
    std.debug.assert(value.children.len == 0);
    const children = node.children;
    const constraints = node.constraints;
    // Non-painting wrappers only damage when their bounds change (covering
    // vacated regions); painted nodes always damage since their payload may
    // have changed. Ancestors on a dirty path re-commit with identical
    // geometry and must not inflate the damage to their full bounds.
    const rect_changed = !std.meta.eql(node.rect, value.rect);
    const paints = switch (value.kind) {
        .box, .text, .text_input, .render_object => true,
        else => false,
    };
    var damage = node.damage;
    if (rect_changed or paints) {
        damage = unionDamage(unionDamage(damage, node.rect), value.rect);
    }
    node.* = value;
    node.children = children;
    node.constraints = constraints;
    node.damage = damage;
    node.needs_layout = false;
}

fn unionDamage(damage: ?Rect, rect: Rect) ?Rect {
    if (rect.isEmpty()) return damage;
    const existing = damage orelse return rect;
    const x0 = @min(existing.x, rect.x);
    const y0 = @min(existing.y, rect.y);
    const x1 = @max(existing.x + existing.width, rect.x + rect.width);
    const y1 = @max(existing.y + existing.height, rect.y + rect.height);
    return .{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0 };
}

/// Collects and clears the damage accumulated across the tree since the
/// last collection. Null means nothing changed.
pub fn collectDamage(node: *RenderNode) ?Rect {
    var damage = node.damage;
    node.damage = null;
    for (node.children) |child| {
        if (collectDamage(child)) |child_damage| {
            damage = unionDamage(damage, child_damage);
        }
    }
    return damage;
}

fn ensureChildSlice(allocator: std.mem.Allocator, node: *RenderNode, count: usize) ![]*RenderNode {
    if (node.children.len != count) {
        allocator.free(node.children);
        node.children = &.{};
        node.children = try allocator.alloc(*RenderNode, count);
    }
    return node.children;
}

fn moveNode(node: *RenderNode, x: f32, y: f32) void {
    if (node.rect.x == x and node.rect.y == y) return;
    const dx = x - node.rect.x;
    const dy = y - node.rect.y;
    node.damage = unionDamage(node.damage, node.rect);
    node.rect.x = x;
    node.rect.y = y;
    node.damage = unionDamage(node.damage, node.rect);
    translateChildren(node, dx, dy);
}

/// Lays out an element subtree into its retained render node, mutating
/// geometry in place. Nodes are created lazily and live as long as their
/// element; repeated layouts reuse them.
///
/// A clean subtree re-laid out with identical constraints is skipped
/// entirely: its cached geometry is still valid, so at most it is
/// translated to a new origin.
pub fn layoutElement(allocator: std.mem.Allocator, element: *Element, constraints: Constraints, origin: Point, measurer: TextMeasurer) LayoutError!*RenderNode {
    const node = try ensureRenderNode(allocator, element);
    if (!node.needs_layout and std.meta.eql(node.constraints, constraints)) {
        if (node.rect.x != origin.x or node.rect.y != origin.y) moveNode(node, origin.x, origin.y);
        return node;
    }
    try layoutElementInto(allocator, element, node, constraints, origin, measurer);
    node.constraints = constraints;
    return node;
}

/// Marks the element's retained render node for relayout. Called wherever
/// an element's widget (or a descendant's) may have changed.
pub fn markElementLayoutDirty(element: *Element) void {
    if (element.render_node) |node| node.needs_layout = true;
}

fn layoutWrapper(
    allocator: std.mem.Allocator,
    element: *Element,
    node: *RenderNode,
    comptime kind: RenderNode.Kind,
    constraints: Constraints,
    origin: Point,
    measurer: TextMeasurer,
) LayoutError!void {
    const child = try layoutElement(allocator, &element.children[0], constraints, origin, measurer);
    const children = try ensureChildSlice(allocator, node, 1);
    children[0] = child;
    commitRenderNode(node, .{
        .kind = kind,
        .rect = .{ .x = origin.x, .y = origin.y, .width = child.rect.width, .height = child.rect.height },
    });
}

fn layoutElementInto(
    allocator: std.mem.Allocator,
    element: *Element,
    node: *RenderNode,
    constraints: Constraints,
    origin: Point,
    measurer: TextMeasurer,
) LayoutError!void {
    switch (element.widget) {
        .keyed => try layoutWrapper(allocator, element, node, .keyed, constraints, origin, measurer),
        .button => try layoutWrapper(allocator, element, node, .button, constraints, origin, measurer),
        .actions => try layoutWrapper(allocator, element, node, .actions, constraints, origin, measurer),
        .shortcuts => try layoutWrapper(allocator, element, node, .shortcuts, constraints, origin, measurer),
        .theme => try layoutWrapper(allocator, element, node, .theme, constraints, origin, measurer),
        .default_text_style => try layoutWrapper(allocator, element, node, .default_text_style, constraints, origin, measurer),
        .component => try layoutWrapper(allocator, element, node, .component, constraints, origin, measurer),
        .stateful => try layoutWrapper(allocator, element, node, .stateful, constraints, origin, measurer),
        .element => try layoutWrapper(allocator, element, node, .element, constraints, origin, measurer),
        .text => |text_widget| {
            const style: ResolvedTextStyle = .{ .color = text_widget.color orelse colors.ink, .font_size = text_widget.font_size orelse 16 };
            const measured = try measurer.measureText(text_widget.value, style);
            const size_value = constraints.clamp(measured);
            _ = try ensureChildSlice(allocator, node, 0);
            commitRenderNode(node, .{
                .kind = .text,
                .rect = .{ .x = origin.x, .y = origin.y, .width = size_value.width, .height = size_value.height },
                .text = text_widget.value,
                .text_style = style,
                .foreground = style.color,
            });
        },
        .spacer => {
            _ = try ensureChildSlice(allocator, node, 0);
            commitRenderNode(node, .{
                .kind = .spacer,
                .rect = .{ .x = origin.x, .y = origin.y, .width = 0, .height = 0 },
            });
        },
        .sized => |sized_widget| {
            const child_constraints = constrainSized(constraints, sized_widget);
            const child = try layoutElement(allocator, &element.children[0], child_constraints, origin, measurer);
            // Sizes to the child like Flutter's RenderConstrainedBox; the
            // clamp only corrects children that ignore their constraints.
            const size_value = child_constraints.clamp(.{ .width = child.rect.width, .height = child.rect.height });
            const width = size_value.width;
            const height = size_value.height;
            moveNode(child, origin.x, origin.y);
            const children = try ensureChildSlice(allocator, node, 1);
            children[0] = child;
            commitRenderNode(node, .{
                .kind = .sized,
                .rect = .{ .x = origin.x, .y = origin.y, .width = width, .height = height },
            });
        },
        .box => |box_widget| {
            // The box absorbs any min constraint and aligns the loosely
            // laid-out child within the resulting extent.
            const child = try layoutElement(allocator, &element.children[0], constraints.loosen(), origin, measurer);
            const size_value = constraints.clamp(.{
                .width = @max(box_widget.min_width, child.rect.width),
                .height = @max(box_widget.min_height, child.rect.height),
            });
            const width = size_value.width;
            const height = size_value.height;
            moveNode(
                child,
                origin.x + alignedOffset(box_widget.horizontal_align, width, child.rect.width),
                origin.y + alignedOffset(box_widget.vertical_align, height, child.rect.height),
            );
            const children = try ensureChildSlice(allocator, node, 1);
            children[0] = child;
            commitRenderNode(node, .{
                .kind = .box,
                .rect = .{ .x = origin.x, .y = origin.y, .width = width, .height = height },
                .background = box_widget.background,
                .box_border = box_widget.border,
                .box_border_width = box_widget.border_width,
                .box_radius = box_widget.radius,
            });
        },
        .clickable => |clickable_widget| {
            const child = try layoutElement(allocator, &element.children[0], constraints, origin, measurer);
            const children = try ensureChildSlice(allocator, node, 1);
            children[0] = child;
            commitRenderNode(node, .{
                .kind = .clickable,
                .rect = .{ .x = origin.x, .y = origin.y, .width = child.rect.width, .height = child.rect.height },
                .clickable_id = clickable_widget.id,
                .click_callback = clickable_widget.on_click,
                .tap_down_callback = clickable_widget.on_tap_down,
                .tap_up_callback = clickable_widget.on_tap_up,
                .tap_cancel_callback = clickable_widget.on_tap_cancel,
                .click_activation = clickable_widget.activation,
            });
        },
        .anchored => {
            const child = try layoutElement(allocator, &element.children[0], constraints, origin, measurer);
            const children = try ensureChildSlice(allocator, node, 1);
            children[0] = child;
            commitRenderNode(node, .{
                .kind = .anchored,
                .rect = .{ .x = origin.x, .y = origin.y, .width = child.rect.width, .height = child.rect.height },
            });
        },
        .focus => |focus_widget| {
            const child = try layoutElement(allocator, &element.children[0], constraints, origin, measurer);
            const children = try ensureChildSlice(allocator, node, 1);
            children[0] = child;
            commitRenderNode(node, .{
                .kind = .focus,
                .rect = .{ .x = origin.x, .y = origin.y, .width = child.rect.width, .height = child.rect.height },
                .focus_id = focus_widget.node.id,
                .focused = element.focused,
                .autofocus = focus_widget.autofocus,
                .skip_traversal = focus_widget.skip_traversal,
                .can_request_focus = focus_widget.can_request_focus,
                .focus_change_callback = focus_widget.on_focus_change,
            });
        },
        .focus_scope => |focus_scope_widget| {
            const child = try layoutElement(allocator, &element.children[0], constraints, origin, measurer);
            const children = try ensureChildSlice(allocator, node, 1);
            children[0] = child;
            commitRenderNode(node, .{
                .kind = .focus_scope,
                .rect = .{ .x = origin.x, .y = origin.y, .width = child.rect.width, .height = child.rect.height },
                .focus_scope_id = focus_scope_widget.id,
                .modal_focus_scope = focus_scope_widget.modal,
            });
        },
        .scroll => |scroll_widget| {
            const state = scrollState(element);
            const child = try layoutElement(allocator, &element.children[0], scrollChildConstraints(constraints, scroll_widget.axes), .{
                .x = origin.x - state.offset_x,
                .y = origin.y - state.offset_y,
            }, measurer);
            const viewport = constraints.clamp(.{ .width = child.rect.width, .height = child.rect.height });
            const width = viewport.width;
            const height = viewport.height;
            state.offset_x = std.math.clamp(state.offset_x, 0, @max(0, child.rect.width - width));
            state.offset_y = std.math.clamp(state.offset_y, 0, @max(0, child.rect.height - height));
            moveNode(child, origin.x - state.offset_x, origin.y - state.offset_y);
            const children = try ensureChildSlice(allocator, node, 1);
            children[0] = child;
            commitRenderNode(node, .{
                .kind = .scroll,
                .rect = .{ .x = origin.x, .y = origin.y, .width = width, .height = height },
                .scroll_id = scroll_widget.id,
                .scroll_content = child.rect.size(),
                .scroll_offset = .{ .x = state.offset_x, .y = state.offset_y },
            });
        },
        .list => |list_widget| {
            const state = listState(element);
            const content_height = list_widget.item_extent * @as(f32, @floatFromInt(list_widget.item_count));
            const available_height = if (std.math.isFinite(constraints.max_height)) constraints.max_height else content_height;
            const height = @min(available_height, content_height);
            state.viewport_height = height;
            state.offset = std.math.clamp(state.offset, 0, @max(0, content_height - height));

            // A drifted window is rebuilt by the next dirty-state pass; this
            // pass lays out whatever window is currently built.
            const ideal = listVisibleRange(list_widget, state.offset, height);
            if (ideal.first != state.first or ideal.count != state.built) state.range_stale = true;

            const item_constraints: Constraints = .{ .max_width = constraints.max_width, .max_height = list_widget.item_extent };
            const children = try ensureChildSlice(allocator, node, element.children.len);
            var content_width: f32 = 0;
            for (element.children, 0..) |*child_element, index| {
                const child_y = origin.y - state.offset + @as(f32, @floatFromInt(state.first + index)) * list_widget.item_extent;
                children[index] = try layoutElement(allocator, child_element, item_constraints, .{ .x = origin.x, .y = child_y }, measurer);
                content_width = @max(content_width, children[index].rect.width);
            }
            const width = if (std.math.isFinite(constraints.max_width)) constraints.max_width else content_width;
            const viewport = constraints.clamp(.{ .width = width, .height = height });
            commitRenderNode(node, .{
                .kind = .list,
                .rect = .{ .x = origin.x, .y = origin.y, .width = viewport.width, .height = viewport.height },
                .scroll_id = list_widget.id,
                .scroll_content = .{ .width = content_width, .height = content_height },
                .scroll_offset = .{ .x = 0, .y = state.offset },
            });
        },
        .text_input => |input_widget| {
            const value = textInputState(element).text.items;
            const text_value = if (value.len > 0) value else input_widget.placeholder;
            const style: ResolvedTextStyle = .{ .color = input_widget.foreground, .font_size = input_widget.font_size };
            const measured = try measurer.measureText(text_value, style);
            const value_size = try measurer.measureText(value, style);
            const fill_width = if (std.math.isFinite(constraints.max_width)) constraints.max_width else 0;
            const requested = Size{
                .width = @max(input_min_width, @max(measured.width + input_widget.padding_x * 2, fill_width)),
                .height = measured.height + input_widget.padding_y * 2,
            };
            const size_value = constraints.clamp(requested);
            _ = try ensureChildSlice(allocator, node, 0);
            commitRenderNode(node, .{
                .kind = .text_input,
                .rect = .{ .x = origin.x, .y = origin.y, .width = size_value.width, .height = size_value.height },
                .text = textInputState(element).text.items,
                .text_input_id = input_widget.id,
                .focus_id = input_widget.focus_node.id,
                .autofocus = input_widget.autofocus,
                .text_style = style,
                .foreground = input_widget.foreground,
                .background = input_widget.background,
                .placeholder = input_widget.placeholder,
                .border = input_widget.border,
                .focused_border = input_widget.focused_border,
                .placeholder_foreground = input_widget.placeholder_foreground,
                .padding_x = input_widget.padding_x,
                .padding_y = input_widget.padding_y,
                .box_radius = input_widget.radius,
                .focused = element.focused,
                .caret_x = origin.x + input_widget.padding_x + value_size.width,
            });
        },
        .padding => |padding_widget| {
            const child = try layoutElement(allocator, &element.children[0], constraints.inset(padding_widget.insets), .{
                .x = origin.x + padding_widget.insets.left,
                .y = origin.y + padding_widget.insets.top,
            }, measurer);
            const children = try ensureChildSlice(allocator, node, 1);
            children[0] = child;
            commitRenderNode(node, .{
                .kind = .padding,
                .rect = blk: {
                    const size_value = constraints.clamp(.{
                        .width = child.rect.width + padding_widget.insets.horizontal(),
                        .height = child.rect.height + padding_widget.insets.vertical(),
                    });
                    break :blk .{ .x = origin.x, .y = origin.y, .width = size_value.width, .height = size_value.height };
                },
            });
        },
        .flexible => {
            // Outside a row or column a flexible wrapper is a passthrough;
            // inside one, layoutLinearElements supplies the share as the
            // constraints, tight on the main axis for a tight fit.
            const child = try layoutElement(allocator, &element.children[0], constraints, origin, measurer);
            const children = try ensureChildSlice(allocator, node, 1);
            children[0] = child;
            commitRenderNode(node, .{
                .kind = .flexible,
                .rect = child.rect,
            });
        },
        .center => {
            const child = try layoutElement(allocator, &element.children[0], constraints.loosen(), origin, measurer);
            // An unbounded axis centers around the child's own extent.
            const avail_width = if (std.math.isFinite(constraints.max_width)) constraints.max_width else @max(constraints.min_width, child.rect.width);
            const avail_height = if (std.math.isFinite(constraints.max_height)) constraints.max_height else @max(constraints.min_height, child.rect.height);
            moveNode(
                child,
                origin.x + @max(0, avail_width - child.rect.width) / 2,
                origin.y + @max(0, avail_height - child.rect.height) / 2,
            );
            const children = try ensureChildSlice(allocator, node, 1);
            children[0] = child;
            commitRenderNode(node, .{
                .kind = .center,
                .rect = .{ .x = origin.x, .y = origin.y, .width = avail_width, .height = avail_height },
            });
        },
        .column => |column_widget| try layoutLinearElements(allocator, node, .column, element.children, column_widget.gap, column_widget.cross_align, column_widget.main_align, constraints, origin, measurer),
        .row => |row_widget| try layoutLinearElements(allocator, node, .row, element.children, row_widget.gap, row_widget.cross_align, row_widget.main_align, constraints, origin, measurer),
        .render_object => |render_widget| {
            const measured = try render_widget.layout(.{ .constraints = constraints, .measurer = measurer });
            const size_value = constraints.clamp(measured);
            _ = try ensureChildSlice(allocator, node, 0);
            commitRenderNode(node, .{
                .kind = .render_object,
                .rect = .{ .x = origin.x, .y = origin.y, .width = size_value.width, .height = size_value.height },
                .render_object = render_widget,
            });
        },
    }
}

fn mainExtent(comptime kind: RenderNode.Kind, child: *const RenderNode) f32 {
    return switch (kind) {
        .row => child.rect.width,
        .column => child.rect.height,
        else => unreachable,
    };
}

fn crossExtent(comptime kind: RenderNode.Kind, child: *const RenderNode) f32 {
    return switch (kind) {
        .row => child.rect.height,
        .column => child.rect.width,
        else => unreachable,
    };
}

/// Resizes a node in place with damage for both the vacated and the newly
/// covered region. Returns whether the size actually changed.
fn resizeNode(node: *RenderNode, width: f32, height: f32) bool {
    if (node.rect.width == width and node.rect.height == height) return false;
    node.damage = unionDamage(node.damage, node.rect);
    node.rect.width = width;
    node.rect.height = height;
    node.damage = unionDamage(node.damage, node.rect);
    return true;
}

fn setMainExtent(comptime kind: RenderNode.Kind, child: *RenderNode, value: f32) void {
    _ = switch (kind) {
        .row => resizeNode(child, value, child.rect.height),
        .column => resizeNode(child, child.rect.width, value),
        else => unreachable,
    };
}

fn layoutLinearElements(
    allocator: std.mem.Allocator,
    node: *RenderNode,
    comptime kind: RenderNode.Kind,
    elements: []Element,
    gap: f32,
    cross_align: Widget.CrossAxisAlignment,
    main_align: Widget.MainAxisAlignment,
    constraints: Constraints,
    origin: Point,
    measurer: TextMeasurer,
) LayoutError!void {
    std.debug.assert(kind == .row or kind == .column);

    const children = try ensureChildSlice(allocator, node, elements.len);

    const total_gap = if (elements.len > 0) gap * @as(f32, @floatFromInt(elements.len - 1)) else 0;
    var fixed_main: f32 = 0;
    var cross: f32 = 0;
    var total_flex: f32 = 0;

    // Mirrors Flutter's RenderFlex: intrinsic children get an unbounded
    // main axis, and stretch turns a bounded cross axis into a tight
    // constraint so descendants size to it before aligning their content.
    // An unbounded cross axis cannot stretch through constraints; the
    // positioning pass falls back to inflating to the tallest sibling.
    const max_cross = switch (kind) {
        .row => constraints.max_height,
        .column => constraints.max_width,
        else => unreachable,
    };
    const fill_cross = cross_align == .stretch and std.math.isFinite(max_cross);
    const child_min_cross: f32 = if (fill_cross) max_cross else 0;
    const intrinsic_constraints: Constraints = switch (kind) {
        .row => .{ .max_width = std.math.inf(f32), .min_height = child_min_cross, .max_height = constraints.max_height },
        .column => .{ .min_width = child_min_cross, .max_width = constraints.max_width, .max_height = std.math.inf(f32) },
        else => unreachable,
    };

    // Pass 1: intrinsic children establish the fixed extent; spacers and
    // flexible children only contribute their flex factors.
    for (elements, 0..) |*child_element, index| {
        switch (child_element.widget) {
            .spacer => |spacer_widget| {
                total_flex += spacer_widget.flex;
                const spacer_node = try ensureRenderNode(allocator, child_element);
                commitRenderNode(spacer_node, .{
                    .kind = .spacer,
                    .rect = .{ .x = origin.x, .y = origin.y, .width = 0, .height = 0 },
                });
                spacer_node.constraints = intrinsic_constraints;
                children[index] = spacer_node;
            },
            .flexible => |flexible_widget| total_flex += flexible_widget.flex,
            else => {
                // Tentatively lay the child at its previous position; the
                // positioning pass moves it to its final slot. This keeps
                // unchanged children in place instead of thrashing their
                // damage via parent-origin moves.
                const tentative_origin: Point = if (child_element.render_node) |existing|
                    .{ .x = existing.rect.x, .y = existing.rect.y }
                else
                    origin;
                children[index] = try layoutElement(allocator, child_element, intrinsic_constraints, tentative_origin, measurer);
                fixed_main += mainExtent(kind, children[index]);
                cross = @max(cross, crossExtent(kind, children[index]));
            },
        }
    }

    const max_main = switch (kind) {
        .row => constraints.max_width,
        .column => constraints.max_height,
        else => unreachable,
    };
    const bounded = std.math.isFinite(max_main);
    const spare = if (bounded) @max(0, max_main - fixed_main - total_gap) else 0;

    // Pass 2: flexible children split the spare space in proportion to
    // their factors. A tight fit passes the share as a tight main-axis
    // constraint so descendants size themselves to it before aligning
    // their own content; forcing extents after layout would leave that
    // content aligned against the shrink-wrapped size.
    for (elements, 0..) |*child_element, index| {
        if (child_element.widget != .flexible) continue;
        const flexible_widget = child_element.widget.flexible;
        const share = if (total_flex > 0) spare * flexible_widget.flex / total_flex else 0;
        const min_main = if (flexible_widget.fit == .tight) share else 0;
        const child_constraints: Constraints = switch (kind) {
            .row => .{ .min_width = min_main, .max_width = share, .min_height = child_min_cross, .max_height = constraints.max_height },
            .column => .{ .min_width = child_min_cross, .max_width = constraints.max_width, .min_height = min_main, .max_height = share },
            else => unreachable,
        };
        const tentative_origin: Point = if (child_element.render_node) |existing|
            .{ .x = existing.rect.x, .y = existing.rect.y }
        else
            origin;
        children[index] = try layoutElement(allocator, child_element, child_constraints, tentative_origin, measurer);
        // Children that ignore min constraints (e.g. bare spacers, or
        // wrappers over them) still occupy their whole share; this is a
        // no-op for children that honored the tight constraint.
        if (flexible_widget.fit == .tight) {
            setMainExtent(kind, children[index], share);
            if (children[index].children.len == 1 and mainExtent(kind, children[index].children[0]) < share) {
                setMainExtent(kind, children[index].children[0], share);
            }
        }
        cross = @max(cross, crossExtent(kind, children[index]));
    }

    // A cross-axis min constraint (e.g. from an enclosing tight fit)
    // raises the extent children align and stretch against.
    cross = @max(cross, switch (kind) {
        .row => constraints.min_height,
        .column => constraints.min_width,
        else => unreachable,
    });

    var content_main: f32 = total_gap;
    for (elements, 0..) |*child_element, index| {
        if (child_element.widget == .spacer) {
            content_main += if (total_flex > 0) spare * child_element.widget.spacer.flex / total_flex else 0;
        } else {
            content_main += mainExtent(kind, children[index]);
        }
    }

    // Flex children or a non-start alignment claim the whole main axis;
    // otherwise the container shrink-wraps its content, though never
    // below its main-axis min constraint.
    const min_main = switch (kind) {
        .row => constraints.min_width,
        .column => constraints.min_height,
        else => unreachable,
    };
    const wants_full = bounded and (total_flex > 0 or main_align != .start);
    const main_size = if (wants_full) max_main else @max(content_main, min_main);
    const leftover = @max(0, main_size - content_main);

    var lead: f32 = 0;
    var extra_between: f32 = 0;
    const count: f32 = @floatFromInt(elements.len);
    switch (main_align) {
        .start => {},
        .center => lead = leftover / 2,
        .end => lead = leftover,
        .space_between => if (elements.len > 1) {
            extra_between = leftover / (count - 1);
        },
        .space_around => if (elements.len > 0) {
            lead = leftover / count / 2;
            extra_between = leftover / count;
        },
        .space_evenly => if (elements.len > 0) {
            lead = leftover / (count + 1);
            extra_between = leftover / (count + 1);
        },
    }

    // Positioning pass.
    var cursor: Point = switch (kind) {
        .row => .{ .x = origin.x + lead, .y = origin.y },
        .column => .{ .x = origin.x, .y = origin.y + lead },
        else => unreachable,
    };
    for (elements, 0..) |*child_element, index| {
        const child = children[index];
        if (child_element.widget == .spacer and total_flex > 0) {
            const spacer_main = spare * child_element.widget.spacer.flex / total_flex;
            child.rect = switch (kind) {
                .row => .{ .x = cursor.x, .y = origin.y, .width = spacer_main, .height = cross },
                .column => .{ .x = origin.x, .y = cursor.y, .width = cross, .height = spacer_main },
                else => unreachable,
            };
        } else {
            const aligned_cross = alignedCrossOffset(kind, cross_align, cross, child);
            const new_x = switch (kind) {
                .row => cursor.x,
                .column => origin.x + aligned_cross,
                else => unreachable,
            };
            const new_y = switch (kind) {
                .row => origin.y + aligned_cross,
                .column => cursor.y,
                else => unreachable,
            };
            moveNode(child, new_x, new_y);
            // Stretch normally happens through tight cross constraints and
            // this is a no-op. It still fires for an unbounded cross axis
            // (stretching to the tallest sibling) and for children that
            // ignore min constraints; such a parent-side mutation is not
            // represented in the child's constraints, so it must not be
            // cached as the child's intrinsic size.
            if (cross_align == .stretch) {
                const stretched = switch (kind) {
                    .row => resizeNode(child, child.rect.width, cross),
                    .column => resizeNode(child, cross, child.rect.height),
                    else => unreachable,
                };
                if (stretched) child.needs_layout = true;
            }
        }

        switch (kind) {
            .row => cursor.x += child.rect.width + gap + extra_between,
            .column => cursor.y += child.rect.height + gap + extra_between,
            else => unreachable,
        }
    }

    const size_value = switch (kind) {
        .row => constraints.clamp(.{ .width = main_size, .height = cross }),
        .column => constraints.clamp(.{ .width = cross, .height = main_size }),
        else => unreachable,
    };
    commitRenderNode(node, .{
        .kind = kind,
        .rect = .{ .x = origin.x, .y = origin.y, .width = size_value.width, .height = size_value.height },
    });
}

/// Mirrors Flutter's `BoxConstraints.tightFor(...).enforce(parent)`: an
/// explicit dimension is tight, and on an unspecified axis the parent's
/// min and max pass through, each clamped into the parent's range.
pub fn constrainSized(parent: Constraints, sized_widget: Widget.Sized) Constraints {
    const min_width = sized_widget.width orelse sized_widget.min_width;
    const max_width = sized_widget.width orelse sized_widget.max_width orelse std.math.inf(f32);
    const min_height = sized_widget.height orelse sized_widget.min_height;
    const max_height = sized_widget.height orelse sized_widget.max_height orelse std.math.inf(f32);
    return .{
        .min_width = std.math.clamp(min_width, parent.min_width, parent.max_width),
        .max_width = std.math.clamp(max_width, parent.min_width, parent.max_width),
        .min_height = std.math.clamp(min_height, parent.min_height, parent.max_height),
        .max_height = std.math.clamp(max_height, parent.min_height, parent.max_height),
    };
}

fn alignedCrossOffset(kind: RenderNode.Kind, alignment: Widget.CrossAxisAlignment, cross: f32, child: *const RenderNode) f32 {
    const child_cross = switch (kind) {
        .row => child.rect.height,
        .column => child.rect.width,
        else => unreachable,
    };
    return switch (alignment) {
        .start, .stretch => 0,
        .center => @max(0, cross - child_cross) / 2,
        .end => @max(0, cross - child_cross),
    };
}

fn alignedOffset(alignment: Widget.Alignment, outer: f32, inner: f32) f32 {
    return switch (alignment) {
        .start => 0,
        .center => @max(0, outer - inner) / 2,
        .end => @max(0, outer - inner),
    };
}

fn translateChildren(node: *RenderNode, dx: f32, dy: f32) void {
    for (node.children) |child| {
        child.rect.x += dx;
        child.rect.y += dy;
        translateChildren(child, dx, dy);
    }
}
