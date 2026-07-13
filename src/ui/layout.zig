//! Layout and retained render-node damage behavior for the UI model.

const std = @import("std");
const model = @import("model.zig");
const uucode = @import("uucode");
const unicode_linebreak = @import("linebreak");

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
    const text_buffer = node.text_buffer;
    const constraints = node.constraints;
    // Layout and paint dirtiness are independent. A full widget rebuild may
    // need to refresh retained payload pointers while producing identical
    // pixels; only changed bounds or an explicitly changed painted payload
    // contribute damage.
    const old_paint_bounds = node.paintBounds();
    const new_paint_bounds = value.derivePaintBoundsForChildren(children);
    const bounds_changed = !std.meta.eql(old_paint_bounds, new_paint_bounds);
    const paint_changed = node.needs_paint;
    var damage = node.damage;
    if (bounds_changed or paint_changed) {
        damage = unionPaintBounds(unionPaintBounds(damage, old_paint_bounds), new_paint_bounds);
    }
    node.* = value;
    node.children = children;
    node.text_buffer = text_buffer;
    node.constraints = constraints;
    node.paint_bounds = new_paint_bounds;
    node.damage = damage;
    node.needs_layout = false;
    node.needs_paint = false;
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

fn unionPaintBounds(damage: ?Rect, paint_bounds: ?Rect) ?Rect {
    return if (paint_bounds) |bounds| unionDamage(damage, bounds) else damage;
}

const ellipsis = "…";

fn measuredFittingEnd(
    value: []const u8,
    available_width: f32,
    style: ResolvedTextStyle,
    measurer: TextMeasurer,
) LayoutError!usize {
    var result: usize = 0;
    var it = uucode.grapheme.utf8Iterator(value);
    while (it.nextGrapheme()) |cluster| {
        const measured = try measurer.measureText(value[0..cluster.end], style);
        if (measured.width > available_width) break;
        result = cluster.end;
    }
    return result;
}

const FittedTextLine = struct {
    content_end: usize,
    next_start: usize,
    hard_break: bool,
};

const BreakCandidate = struct {
    line: FittedTextLine,
    emergency: bool = false,
};

const BreakFitness = enum(u2) {
    tight,
    normal,
    loose,
    very_loose,
};

const break_fitness_count = @typeInfo(BreakFitness).@"enum".fields.len;

const BreakPoint = struct {
    candidate: usize,
    fitness: BreakFitness,
};

const BreakPath = struct {
    demerits: f64 = std.math.inf(f64),
    previous: ?BreakPoint = null,
};

fn previousScalarStart(value: []const u8, start: usize, end: usize) usize {
    std.debug.assert(start < end);
    var result = end - 1;
    while (result > start and value[result] & 0xc0 == 0x80) result -= 1;
    return result;
}

fn trimTrailingSpaces(value: []const u8, start: usize, end: usize) usize {
    var result = end;
    while (result > start and value[result - 1] == ' ') result -= 1;
    return result;
}

fn breakContentEnd(value: []const u8, start: usize, end: usize, hard_break: bool) usize {
    if (!hard_break) return trimTrailingSpaces(value, start, end);

    var result = previousScalarStart(value, start, end);
    // Treat CRLF as one hard break and normalize every hard break to the
    // newline inserted by wrapText.
    if (std.mem.eql(u8, value[result..end], "\n") and result > start) {
        const previous = previousScalarStart(value, start, result);
        if (std.mem.eql(u8, value[previous..result], "\r")) result = previous;
    }
    return trimTrailingSpaces(value, start, result);
}

fn fitTextLine(
    value: []const u8,
    source_start: usize,
    available_width: f32,
    style: ResolvedTextStyle,
    measurer: TextMeasurer,
) LayoutError!FittedTextLine {
    std.debug.assert(source_start < value.len);
    var breaks = try unicode_linebreak.Iterator.init(value[source_start..]);
    var last_fitting: ?FittedTextLine = null;

    while (breaks.next()) |line_break| {
        const next_start = source_start + line_break.end;
        const terminal = next_start == value.len;
        const content_end = breakContentEnd(value, source_start, next_start, line_break.hard);
        const candidate: FittedTextLine = .{
            .content_end = content_end,
            .next_start = next_start,
            .hard_break = line_break.hard,
        };
        if (!std.math.isFinite(available_width)) {
            if (line_break.hard or terminal) return candidate;
            continue;
        }

        const measured = try measurer.measureText(value[source_start..content_end], style);

        if (measured.width <= available_width) {
            if (line_break.hard or terminal) return candidate;
            last_fitting = candidate;
            continue;
        }

        if (last_fitting) |fitting| return fitting;
        if (content_end == source_start) return candidate;

        const source_line = value[source_start..content_end];
        const fitting_end = try measuredFittingEnd(source_line, available_width, style, measurer);
        if (fitting_end > 0) {
            return .{
                .content_end = source_start + fitting_end,
                .next_start = source_start + fitting_end,
                .hard_break = false,
            };
        }

        // A grapheme wider than the constraint still has to make progress;
        // preserving it is preferable to silently dropping text.
        var graphemes = uucode.grapheme.utf8Iterator(source_line);
        const first = graphemes.nextGrapheme() orelse unreachable;
        return .{
            .content_end = source_start + first.end,
            .next_start = source_start + first.end,
            .hard_break = false,
        };
    }
    unreachable;
}

fn appendEmergencyBreaks(
    allocator: std.mem.Allocator,
    candidates: *std.ArrayList(BreakCandidate),
    value: []const u8,
    start: usize,
    end: usize,
) LayoutError!void {
    var graphemes = uucode.grapheme.utf8Iterator(value[start..end]);
    while (graphemes.nextGrapheme()) |grapheme| {
        const boundary = start + grapheme.end;
        if (boundary == end) break;
        try candidates.append(allocator, .{
            .line = .{
                .content_end = boundary,
                .next_start = boundary,
                .hard_break = false,
            },
            .emergency = true,
        });
    }
}

fn collectParagraphBreaks(
    allocator: std.mem.Allocator,
    candidates: *std.ArrayList(BreakCandidate),
    value: []const u8,
    source_start: usize,
    available_width: f32,
    style: ResolvedTextStyle,
    measurer: TextMeasurer,
) LayoutError!void {
    var breaks = try unicode_linebreak.Iterator.init(value[source_start..]);
    var segment_start = source_start;

    while (breaks.next()) |line_break| {
        const next_start = source_start + line_break.end;
        const terminal = next_start == value.len;
        const content_end = breakContentEnd(value, source_start, next_start, line_break.hard);

        // Emergency opportunities are only introduced inside a UAX #14
        // segment that cannot fit by itself. This keeps paragraph optimization
        // from preferring arbitrary grapheme breaks merely to improve color.
        if (content_end > segment_start) {
            const measured = try measurer.measureText(value[segment_start..content_end], style);
            if (measured.width > available_width) {
                try appendEmergencyBreaks(allocator, candidates, value, segment_start, content_end);
            }
        }

        try candidates.append(allocator, .{ .line = .{
            .content_end = content_end,
            .next_start = next_start,
            .hard_break = line_break.hard,
        } });
        if (line_break.hard or terminal) return;
        segment_start = next_start;
    }
    unreachable;
}

const LineDemerits = struct {
    value: f64,
    fitness: BreakFitness,
};

fn lineDemerits(width: f32, available_width: f32, final_line: bool, emergency: bool) LineDemerits {
    const target: f64 = @floatCast(@max(available_width, 1));
    const natural: f64 = @floatCast(width);
    const ratio = if (natural < target) (target - natural) / target else 0;
    const fitness: BreakFitness = if (ratio < 0.1)
        .tight
    else if (ratio < 0.25)
        .normal
    else if (ratio < 0.5)
        .loose
    else
        .very_loose;

    // Knuth-Plass normally derives badness from glue stretch or shrink. The
    // renderer is ragged-right and does not stretch spaces, so remaining line
    // width is the adjustment ratio that produces the visible result.
    const badness = if (final_line) 0 else 100 * ratio * ratio * ratio;
    var value = (1 + badness) * (1 + badness);
    if (emergency) value += 10_000;
    if (natural > target) {
        const overflow = (natural - target) / target;
        value += 1_000_000 * (1 + overflow * overflow);
    }
    return .{ .value = value, .fitness = fitness };
}

fn relaxBreak(
    paths: [][break_fitness_count]BreakPath,
    target: usize,
    score: LineDemerits,
    base_demerits: f64,
    previous: ?BreakPoint,
) void {
    var demerits = base_demerits + score.value;
    if (previous) |point| {
        const previous_fitness: i8 = @intCast(@intFromEnum(point.fitness));
        const current_fitness: i8 = @intCast(@intFromEnum(score.fitness));
        if (@abs(previous_fitness - current_fitness) > 1) demerits += 100;
    }

    const fitness_index = @intFromEnum(score.fitness);
    if (demerits < paths[target][fitness_index].demerits) {
        paths[target][fitness_index] = .{
            .demerits = demerits,
            .previous = previous,
        };
    }
}

fn fitTextParagraph(
    allocator: std.mem.Allocator,
    lines: *std.ArrayList(FittedTextLine),
    candidates: []const BreakCandidate,
    value: []const u8,
    source_start: usize,
    available_width: f32,
    style: ResolvedTextStyle,
    measurer: TextMeasurer,
) LayoutError!void {
    std.debug.assert(source_start < value.len);
    std.debug.assert(std.math.isFinite(available_width));

    std.debug.assert(candidates.len > 0);

    const paths = try allocator.alloc([break_fitness_count]BreakPath, candidates.len);
    defer allocator.free(paths);
    for (paths) |*candidate_paths| {
        for (candidate_paths) |*path| path.* = .{};
    }

    // Each candidate is a graph vertex. Edges connect every pair whose text
    // fits on one line; demerits make this the Knuth-Plass shortest-path
    // formulation rather than a locally greedy choice.
    var from_slot: usize = 0;
    while (from_slot < candidates.len) : (from_slot += 1) {
        const line_start = if (from_slot == 0)
            source_start
        else
            candidates[from_slot - 1].line.next_start;

        var reachable = from_slot == 0;
        if (!reachable) {
            for (paths[from_slot - 1]) |path| {
                if (std.math.isFinite(path.demerits)) {
                    reachable = true;
                    break;
                }
            }
        }
        if (!reachable) continue;

        var found_fitting = false;
        var target = from_slot;
        while (target < candidates.len) : (target += 1) {
            const candidate = candidates[target];
            if (candidate.line.content_end < line_start) continue;
            const measured = try measurer.measureText(value[line_start..candidate.line.content_end], style);
            const overfull = measured.width > available_width;
            if (overfull and found_fitting) break;
            if (!overfull) found_fitting = true;

            const score = lineDemerits(
                measured.width,
                available_width,
                target + 1 == candidates.len,
                candidate.emergency,
            );
            if (from_slot == 0) {
                relaxBreak(paths, target, score, 0, null);
            } else {
                for (paths[from_slot - 1], 0..) |path, fitness_index| {
                    if (!std.math.isFinite(path.demerits)) continue;
                    const point: BreakPoint = .{
                        .candidate = from_slot - 1,
                        .fitness = @enumFromInt(fitness_index),
                    };
                    relaxBreak(paths, target, score, path.demerits, point);
                }
            }
            // If even the first grapheme is wider than the constraint, that
            // one overfull edge is retained to guarantee forward progress.
            if (overfull) break;
        }
    }

    const final_candidate = candidates.len - 1;
    var final_fitness: usize = 0;
    for (paths[final_candidate], 0..) |path, fitness_index| {
        if (path.demerits < paths[final_candidate][final_fitness].demerits) {
            final_fitness = fitness_index;
        }
    }
    if (!std.math.isFinite(paths[final_candidate][final_fitness].demerits)) return error.NoLineBreakPath;

    const first_new_line = lines.items.len;
    errdefer lines.shrinkRetainingCapacity(first_new_line);
    var point: BreakPoint = .{
        .candidate = final_candidate,
        .fitness = @enumFromInt(final_fitness),
    };
    while (true) {
        try lines.append(allocator, candidates[point.candidate].line);
        point = paths[point.candidate][@intFromEnum(point.fitness)].previous orelse break;
    }
    std.mem.reverse(FittedTextLine, lines.items[first_new_line..]);
}

fn appendEllipsizedLine(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    value: []const u8,
    source_start: usize,
    content_end: usize,
    available_width: f32,
    style: ResolvedTextStyle,
    measurer: TextMeasurer,
) LayoutError!void {
    const ellipsis_width = (try measurer.measureText(ellipsis, style)).width;
    if (ellipsis_width > available_width) return;
    const fitting_end = try measuredFittingEnd(value[source_start..content_end], available_width - ellipsis_width, style, measurer);
    const visible_end = trimTrailingSpaces(value, source_start, source_start + fitting_end);
    try output.appendSlice(allocator, value[source_start..visible_end]);
    try output.appendSlice(allocator, ellipsis);
}

fn wrapTextGreedy(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    value: []const u8,
    max_lines: ?u32,
    overflow: Widget.TextOverflow,
    available_width: f32,
    style: ResolvedTextStyle,
    measurer: TextMeasurer,
) LayoutError!void {
    if (max_lines) |limit| std.debug.assert(limit >= 1);
    if (value.len == 0) return;
    const line_limit: usize = if (max_lines) |limit| limit else std.math.maxInt(usize);
    var source_start: usize = 0;
    var line_count: usize = 0;

    while (source_start < value.len) {
        const line = try fitTextLine(value, source_start, available_width, style, measurer);
        // A leading SP run is a legal opportunity whose visible content is
        // empty. Consume it without manufacturing a blank visual line.
        if (!line.hard_break and line.content_end == source_start and line.next_start > source_start) {
            source_start = line.next_start;
            continue;
        }
        line_count += 1;
        const has_more = line.next_start < value.len or line.hard_break;
        if (line_count == line_limit and has_more) {
            if (overflow == .ellipsis) {
                try appendEllipsizedLine(allocator, output, value, source_start, line.content_end, available_width, style, measurer);
            } else {
                try output.appendSlice(allocator, value[source_start..line.content_end]);
            }
            return;
        }

        try output.appendSlice(allocator, value[source_start..line.content_end]);
        if (!has_more) return;
        try output.append(allocator, '\n');
        std.debug.assert(line.next_start > source_start);
        source_start = line.next_start;
    }
}

fn wrapTextKnuthPlass(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    value: []const u8,
    max_lines: ?u32,
    overflow: Widget.TextOverflow,
    available_width: f32,
    style: ResolvedTextStyle,
    measurer: TextMeasurer,
) LayoutError!void {
    if (!std.math.isFinite(available_width)) {
        return wrapTextGreedy(allocator, output, value, max_lines, overflow, available_width, style, measurer);
    }
    if (max_lines) |limit| std.debug.assert(limit >= 1);
    if (value.len == 0) return;
    const line_limit: usize = if (max_lines) |limit| limit else std.math.maxInt(usize);
    var source_start: usize = 0;
    var line_count: usize = 0;

    while (source_start < value.len) {
        var candidates: std.ArrayList(BreakCandidate) = .empty;
        defer candidates.deinit(allocator);
        try collectParagraphBreaks(allocator, &candidates, value, source_start, available_width, style, measurer);
        const first = candidates.items[0].line;
        if (!first.hard_break and first.content_end == source_start and first.next_start > source_start) {
            source_start = first.next_start;
            continue;
        }

        var paragraph_lines: std.ArrayList(FittedTextLine) = .empty;
        defer paragraph_lines.deinit(allocator);
        try fitTextParagraph(allocator, &paragraph_lines, candidates.items, value, source_start, available_width, style, measurer);
        for (paragraph_lines.items) |line| {
            line_count += 1;
            const has_more = line.next_start < value.len or line.hard_break;
            if (line_count == line_limit and has_more) {
                if (overflow == .ellipsis) {
                    try appendEllipsizedLine(allocator, output, value, source_start, line.content_end, available_width, style, measurer);
                } else {
                    try output.appendSlice(allocator, value[source_start..line.content_end]);
                }
                return;
            }

            try output.appendSlice(allocator, value[source_start..line.content_end]);
            if (!has_more) return;
            try output.append(allocator, '\n');
            std.debug.assert(line.next_start > source_start);
            source_start = line.next_start;
        }
    }
}

fn wrapText(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    value: []const u8,
    max_lines: ?u32,
    overflow: Widget.TextOverflow,
    line_break: Widget.LineBreakStrategy,
    available_width: f32,
    style: ResolvedTextStyle,
    measurer: TextMeasurer,
) LayoutError!void {
    return switch (line_break) {
        .greedy => wrapTextGreedy(allocator, output, value, max_lines, overflow, available_width, style, measurer),
        .knuth_plass => wrapTextKnuthPlass(allocator, output, value, max_lines, overflow, available_width, style, measurer),
    };
}

/// Accumulates damage on a retained node outside of layout, for changes
/// (animation ticks) that repaint without re-laying-out anything.
pub fn addDamage(node: *RenderNode, rect: Rect) void {
    node.damage = unionDamage(node.damage, rect);
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
    translateNode(node, dx, dy);
}

fn translateNode(node: *RenderNode, dx: f32, dy: f32) void {
    node.damage = unionPaintBounds(node.damage, node.paintBounds());
    node.rect.x += dx;
    node.rect.y += dy;
    if (node.paint_bounds) |*bounds| {
        bounds.x += dx;
        bounds.y += dy;
    }
    if (node.caret_x) |caret_x| node.caret_x = caret_x + dx;
    node.damage = unionPaintBounds(node.damage, node.paintBounds());
    for (node.children) |child| translateNode(child, dx, dy);
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
            const style: ResolvedTextStyle = .{
                .color = text_widget.color orelse colors.ink,
                .font_size = text_widget.font_size orelse 16,
                .line_height = text_widget.line_height,
            };
            node.text_buffer.clearRetainingCapacity();
            const should_wrap = text_widget.max_lines != null or std.math.isFinite(constraints.max_width);
            const visible_text = if (should_wrap) blk: {
                try wrapText(allocator, &node.text_buffer, text_widget.value, text_widget.max_lines, text_widget.overflow, text_widget.line_break, constraints.max_width, style, measurer);
                break :blk node.text_buffer.items;
            } else text_widget.value;
            const measured = try measurer.measureText(visible_text, style);
            const size_value = constraints.clamp(measured);
            _ = try ensureChildSlice(allocator, node, 0);
            commitRenderNode(node, .{
                .kind = .text,
                .rect = .{ .x = origin.x, .y = origin.y, .width = size_value.width, .height = size_value.height },
                .text = visible_text,
                .text_buffered = should_wrap,
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
                .scroll_event_callback = clickable_widget.on_scroll,
                .hover_change_callback = clickable_widget.on_hover_change,
                .click_buttons = clickable_widget.buttons,
                .click_activation = clickable_widget.activation,
                .click_cursor = clickable_widget.cursor,
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
                .scrollbar_alpha = state.scrollbar_alpha,
                .scrollbar_track_color = scroll_widget.scrollbar_track_color.?,
                .scrollbar_color = scroll_widget.scrollbar_color.?,
            });
        },
        .list => |list_widget| {
            const state = listState(element);
            const content_height = list_widget.item_extent * @as(f32, @floatFromInt(list_widget.item_count));
            const available_height = if (std.math.isFinite(constraints.max_height)) constraints.max_height else content_height;
            const height = @min(available_height, content_height);
            state.viewport_height = height;

            // Follow the controlled selection: when it changes (or first
            // appears), scroll the minimum distance to bring the item
            // fully into view. Free scrolling in between is left alone.
            if (list_widget.selected) |selected| {
                if (state.last_selected != selected and selected < list_widget.item_count) {
                    const top = list_widget.item_extent * @as(f32, @floatFromInt(selected));
                    const bottom = top + list_widget.item_extent;
                    if (top < state.offset) {
                        state.offset = top;
                    } else if (bottom > state.offset + height) {
                        state.offset = bottom - height;
                    }
                }
                state.last_selected = selected;
            } else {
                state.last_selected = null;
            }

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
                .scrollbar_alpha = state.scrollbar_alpha,
                .scrollbar_track_color = list_widget.scrollbar_track_color.?,
                .scrollbar_color = list_widget.scrollbar_color.?,
            });
        },
        .text_input => |input_widget| {
            const value = textInputState(element).text.items;
            node.text_buffer.clearRetainingCapacity();
            const visible_value = if (input_widget.obscured and value.len > 0) blk: {
                var graphemes = uucode.grapheme.utf8Iterator(value);
                while (graphemes.nextGrapheme() != null) try node.text_buffer.appendSlice(allocator, "•");
                break :blk node.text_buffer.items;
            } else value;
            const text_value = if (visible_value.len > 0) visible_value else input_widget.placeholder;
            const style: ResolvedTextStyle = .{
                .color = input_widget.foreground,
                .font_size = input_widget.font_size,
                .line_height = input_widget.line_height,
            };
            const measured = try measurer.measureText(text_value, style);
            const value_size = try measurer.measureText(visible_value, style);
            const fill_width = if (std.math.isFinite(constraints.max_width)) constraints.max_width else 0;
            const requested = Size{
                .width = @max(measured.width + input_widget.padding_x * 2, fill_width),
                .height = measured.height + input_widget.padding_y * 2,
            };
            const size_value = constraints.clamp(requested);
            _ = try ensureChildSlice(allocator, node, 0);
            commitRenderNode(node, .{
                .kind = .text_input,
                .rect = .{ .x = origin.x, .y = origin.y, .width = size_value.width, .height = size_value.height },
                .text = visible_value,
                .text_buffered = input_widget.obscured,
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
        .separator => |separator| {
            const horizontal = separator.axis == .horizontal;
            const requested: Size = if (horizontal)
                .{ .width = constraints.max_width, .height = separator.thickness + separator.margin * 2 }
            else
                .{ .width = separator.thickness + separator.margin * 2, .height = constraints.max_height };
            const size_value = constraints.clamp(requested);
            _ = try ensureChildSlice(allocator, node, 0);
            commitRenderNode(node, .{
                .kind = .separator,
                .rect = .{ .x = origin.x, .y = origin.y, .width = size_value.width, .height = size_value.height },
                .background = separator.color.?,
                .separator_axis = separator.axis,
                .separator_margin = separator.margin,
            });
        },
        .spinner => |spinner_widget| {
            const state = model.spinnerState(element);
            const size_value = constraints.clamp(.{ .width = spinner_widget.size, .height = spinner_widget.size });
            _ = try ensureChildSlice(allocator, node, 0);
            commitRenderNode(node, .{
                .kind = .spinner,
                .rect = .{ .x = origin.x, .y = origin.y, .width = size_value.width, .height = size_value.height },
                .foreground = spinner_widget.color.?,
                .spinner_progress = state.progress,
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
    node.damage = unionPaintBounds(node.damage, node.paintBounds());
    node.rect.width = width;
    node.rect.height = height;
    node.paint_bounds = node.derivePaintBounds();
    node.damage = unionPaintBounds(node.damage, node.paintBounds());
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

    const max_main = switch (kind) {
        .row => constraints.max_width,
        .column => constraints.max_height,
        else => unreachable,
    };
    const bounded = std.math.isFinite(max_main);
    if (!bounded) {
        for (elements) |child_element| switch (child_element.widget) {
            .spacer => |spacer_widget| if (spacer_widget.flex > 0) return error.UnboundedTightFlex,
            .flexible => |flexible_widget| if (flexible_widget.flex > 0 and flexible_widget.fit == .tight) return error.UnboundedTightFlex,
            else => {},
        };
    }

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
            if (children[index].children.len == 1 and mainExtent(kind, children[index].children[0]) < share) {
                setMainExtent(kind, children[index].children[0], share);
            }
            // Recompute the wrapper after its child so its aggregate paint
            // bounds observe any parent-side child resize.
            setMainExtent(kind, children[index], share);
            children[index].paint_bounds = children[index].derivePaintBounds();
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
    const cap_center: ?f32 = if (kind == .row and cross_align == .baseline)
        try rowCapHeightCenter(children, cross, measurer)
    else
        null;
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
            const aligned_cross = alignedCrossOffset(kind, cross_align, cross, child, cap_center);
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

fn alignedCrossOffset(kind: RenderNode.Kind, alignment: Widget.CrossAxisAlignment, cross: f32, child: *const RenderNode, cap_center: ?f32) f32 {
    const child_cross = switch (kind) {
        .row => child.rect.height,
        .column => child.rect.width,
        else => unreachable,
    };
    return switch (alignment) {
        .start, .stretch => 0,
        .center => @max(0, cross - child_cross) / 2,
        .end => @max(0, cross - child_cross),
        .baseline => switch (child.kind) {
            .text, .text_input => @max(0, cross - child_cross) / 2,
            else => if (cap_center) |center|
                center - child_cross / 2
            else
                @max(0, cross - child_cross) / 2,
        },
    };
}

/// Cross-axis position of the first text child's cap-height midline,
/// including the half-leading used when painting an explicit line height.
/// Null when the row has no text child.
fn rowCapHeightCenter(children: []const *RenderNode, cross: f32, measurer: TextMeasurer) LayoutError!?f32 {
    for (children) |child| {
        if (child.kind != .text) continue;
        const text_metrics = try measurer.textMetrics(child.text_style.font_size);
        const line_height = child.text_style.line_height orelse text_metrics.line_height;
        const half_leading = (line_height - text_metrics.line_height) / 2;
        const top = @max(0, cross - child.rect.height) / 2;
        return top + half_leading + text_metrics.ascender - text_metrics.cap_height / 2;
    }
    return null;
}

fn alignedOffset(alignment: Widget.Alignment, outer: f32, inner: f32) f32 {
    return switch (alignment) {
        .start => 0,
        .center => @max(0, outer - inner) / 2,
        .end => @max(0, outer - inner),
    };
}

test "explicit line height preserves a centered row cap-height" {
    var natural: RenderNode = .{
        .kind = .text,
        .rect = .{ .x = 0, .y = 0, .width = 7, .height = 14 },
        .text_style = .{ .color = colors.ink, .font_size = 14 },
    };
    var explicit: RenderNode = .{
        .kind = .text,
        .rect = .{ .x = 0, .y = 0, .width = 7, .height = 20 },
        .text_style = .{ .color = colors.ink, .font_size = 14, .line_height = 20 },
    };
    const natural_children = [_]*RenderNode{&natural};
    const explicit_children = [_]*RenderNode{&explicit};

    try std.testing.expectEqual(
        try rowCapHeightCenter(&natural_children, 28, .fixed),
        try rowCapHeightCenter(&explicit_children, 28, .fixed),
    );
}

test "moving a clean subtree translates text input carets" {
    var input: RenderNode = .{
        .kind = .text_input,
        .rect = .{ .x = 10, .y = 5, .width = 100, .height = 20 },
        .caret_x = 42,
    };
    var children = [_]*RenderNode{&input};
    var root: RenderNode = .{
        .kind = .center,
        .rect = .{ .x = 0, .y = 0, .width = 100, .height = 20 },
        .children = &children,
    };

    moveNode(&root, 15, 20);

    try std.testing.expectEqual(@as(f32, 25), input.rect.x);
    try std.testing.expectEqual(@as(f32, 25), input.rect.y);
    try std.testing.expectEqual(@as(?f32, 57), input.caret_x);
}

test "text paint overhang contributes to retained damage" {
    var text: RenderNode = .{
        .kind = .text,
        .rect = .{ .x = 20, .y = 10, .width = 16, .height = 16 },
        .text = "a",
        .needs_paint = true,
    };
    text.paint_bounds = text.derivePaintBounds();

    commitRenderNode(&text, .{
        .kind = .text,
        .rect = text.rect,
        .text = "b",
    });

    const expected: Rect = .{ .x = 4, .y = -6, .width = 48, .height = 48 };
    try std.testing.expectEqual(expected, text.paint_bounds.?);
    try std.testing.expectEqual(expected, text.damage.?);
}

test "removing an overflowing child damages its retained paint bounds" {
    var child: RenderNode = .{
        .kind = .box,
        .rect = .{ .x = 30, .y = 0, .width = 20, .height = 20 },
        .background = colors.white,
        .needs_paint = false,
    };
    child.paint_bounds = child.derivePaintBounds();
    var children = [_]*RenderNode{&child};
    var parent: RenderNode = .{
        .kind = .center,
        .rect = .{ .x = 0, .y = 0, .width = 20, .height = 20 },
        .children = &children,
        .needs_paint = false,
    };
    parent.paint_bounds = parent.derivePaintBounds();

    parent.children = &.{};
    commitRenderNode(&parent, .{
        .kind = .center,
        .rect = parent.rect,
    });

    try std.testing.expectEqual(child.rect, parent.damage.?);
    try std.testing.expectEqual(@as(?Rect, null), parent.paint_bounds);
}

fn expectWrapped(value: []const u8, max_lines: ?u32, line_break: Widget.LineBreakStrategy, available_width: f32, expected: []const u8) !void {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    const style: ResolvedTextStyle = .{ .color = colors.ink, .font_size = 16 };
    try wrapText(std.testing.allocator, &output, value, max_lines, .ellipsis, line_break, available_width, style, .fixed);
    try std.testing.expectEqualStrings(expected, output.items);
}

test "wrapped text preserves fitting text and ellipsizes one line" {
    try expectWrapped("abc", 1, .greedy, 40, "abc");
    try expectWrapped("abcdef", 1, .greedy, 40, "ab…");
}

test "wrapped text omits an ellipsis that cannot fit" {
    try expectWrapped("abc", 1, .greedy, 16, "");
}

test "wrapped text uses Unicode opportunities and ellipsizes at two lines" {
    try expectWrapped("hello world again", 2, .greedy, 48, "hello\nwor…");
}

test "wrapped text prefers word boundaries and emergency breaks long words" {
    try expectWrapped("hello world", null, .greedy, 48, "hello\nworld");
    try expectWrapped("abcdefg", null, .greedy, 24, "abc\ndef\ng");
    try expectWrapped("hello   ", null, .greedy, 48, "hello");
    try expectWrapped("   abc", null, .greedy, 16, "ab\nc");
}

test "wrapped text normalizes hard breaks and preserves graphemes" {
    try expectWrapped("one\r\ntwo", null, .greedy, 100, "one\ntwo");
    try expectWrapped("e\u{301}x", null, .greedy, 8, "e\u{301}\nx");
}

test "Knuth-Plass chooses lower paragraph demerits than greedy wrapping" {
    const value = "aaaaaa bbb ccccc ddddd";
    try expectWrapped(value, null, .greedy, 80, "aaaaaa bbb\nccccc\nddddd");
    try expectWrapped(value, null, .knuth_plass, 80, "aaaaaa\nbbb ccccc\nddddd");
}

test "Knuth-Plass preserves hard breaks and emergency grapheme wrapping" {
    try expectWrapped("abcdefg", null, .knuth_plass, 24, "abc\ndef\ng");
    try expectWrapped("one\r\ntwo", null, .knuth_plass, 100, "one\ntwo");
    try expectWrapped("   abc", null, .knuth_plass, 16, "ab\nc");
    try expectWrapped("e\u{301}x", null, .knuth_plass, 8, "e\u{301}\nx");
}
