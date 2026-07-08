//! Owned declarative documents.

const std = @import("std");
const core = @import("core.zig");
const resources_mod = @import("resources.zig");
const ui = @import("ui.zig");

const max_depth = 256;

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    store: *resources_mod.Store,
    root: *const ui.Widget,
    resources: std.ArrayList(ui.ResourceId) = .empty,

    pub fn init(allocator: std.mem.Allocator, store: *resources_mod.Store, root: ui.Widget) !Document {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        errdefer arena.deinit();
        var refs: std.ArrayList(ui.ResourceId) = .empty;
        errdefer releaseRefs(store, &refs);
        var path: [max_depth + 1]*const ui.Widget = undefined;
        const owned_root = try cloneWidget(arena.allocator(), store, &refs, &root, &path, 0);
        return .{ .arena = arena, .store = store, .root = owned_root, .resources = refs };
    }

    pub fn deinit(self: *Document) void {
        self.releaseResourceRefs(self.store);
        self.resources.deinit(self.store.allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn releaseResourceRefs(self: *Document, store: *resources_mod.Store) void {
        for (self.resources.items) |id| store.releaseDocument(id);
        self.resources.clearRetainingCapacity();
    }
};

fn releaseRefs(store: *resources_mod.Store, refs: *std.ArrayList(ui.ResourceId)) void {
    for (refs.items) |id| store.releaseDocument(id);
    refs.deinit(store.allocator);
}

fn cloneWidget(allocator: std.mem.Allocator, store: *resources_mod.Store, refs: *std.ArrayList(ui.ResourceId), source: *const ui.Widget, path: *[max_depth + 1]*const ui.Widget, depth: usize) anyerror!*ui.Widget {
    if (depth > max_depth) return error.DocumentTooDeep;
    for (path[0..depth]) |ancestor| if (ancestor == source) return error.CyclicDocument;
    path[depth] = source;
    try validateWidget(source.*);
    const result = try allocator.create(ui.Widget);
    result.* = switch (source.*) {
        .text => |v| .{ .text = .{ .key = try cloneOptString(allocator, v.key), .value = try cloneString(allocator, v.value), .color = v.color, .font_size = v.font_size, .role = v.role } },
        .container => |v| .{ .container = .{ .key = try cloneOptString(allocator, v.key), .child = try cloneWidget(allocator, store, refs, v.child, path, depth + 1), .background = v.background, .border = v.border, .border_width = v.border_width, .radius = v.radius, .min_width = v.min_width, .min_height = v.min_height, .horizontal_align = v.horizontal_align, .vertical_align = v.vertical_align } },
        .filled_button => |v| .{ .filled_button = .{ .key = try cloneOptString(allocator, v.key), .id = try cloneString(allocator, v.id), .handler = v.handler, .child = try cloneWidget(allocator, store, refs, v.child, path, depth + 1), .activation = v.activation } },
        .gesture_detector => |v| .{ .gesture_detector = .{ .key = try cloneOptString(allocator, v.key), .id = try cloneString(allocator, v.id), .handler = v.handler, .child = try cloneWidget(allocator, store, refs, v.child, path, depth + 1), .activation = v.activation, .hover_style = v.hover_style } },
        .focus => |v| .{ .focus = .{ .key = try cloneOptString(allocator, v.key), .node = .{ .id = try cloneString(allocator, v.node.id) }, .child = try cloneWidget(allocator, store, refs, v.child, path, depth + 1), .autofocus = v.autofocus, .skip_traversal = v.skip_traversal, .can_request_focus = v.can_request_focus, .on_focus_change = v.on_focus_change } },
        .focus_scope => |v| .{ .focus_scope = .{ .key = try cloneOptString(allocator, v.key), .id = try cloneString(allocator, v.id), .child = try cloneWidget(allocator, store, refs, v.child, path, depth + 1), .modal = v.modal } },
        .single_child_scroll_view => |v| .{ .single_child_scroll_view = .{ .key = try cloneOptString(allocator, v.key), .id = try cloneString(allocator, v.id), .child = try cloneWidget(allocator, store, refs, v.child, path, depth + 1), .axes = v.axes } },
        .text_field => |v| .{ .text_field = .{ .key = try cloneOptString(allocator, v.key), .id = try cloneString(allocator, v.id), .focus_node = .{ .id = try cloneString(allocator, v.focus_node.id) }, .value = try cloneString(allocator, v.value), .placeholder = try cloneString(allocator, v.placeholder), .on_change = v.on_change, .foreground = v.foreground, .background = v.background, .border = v.border, .focused_border = v.focused_border, .placeholder_foreground = v.placeholder_foreground, .padding_x = v.padding_x, .padding_y = v.padding_y, .radius = v.radius, .autofocus = v.autofocus } },
        .row => |v| .{ .row = try cloneChildren(allocator, store, refs, v, path, depth) },
        .column => |v| .{ .column = try cloneChildren(allocator, store, refs, v, path, depth) },
        .spacer => |v| .{ .spacer = .{ .key = try cloneOptString(allocator, v.key), .flex = v.flex } },
        .flexible => |v| .{ .flexible = .{ .key = try cloneOptString(allocator, v.key), .child = try cloneWidget(allocator, store, refs, v.child, path, depth + 1), .flex = v.flex, .fit = v.fit } },
        .sized_box => |v| .{ .sized_box = .{ .key = try cloneOptString(allocator, v.key), .child = try cloneWidget(allocator, store, refs, v.child, path, depth + 1), .width = v.width, .height = v.height, .min_width = v.min_width, .min_height = v.min_height, .max_width = v.max_width, .max_height = v.max_height } },
        .padding => |v| .{ .padding = .{ .key = try cloneOptString(allocator, v.key), .insets = v.insets, .child = try cloneWidget(allocator, store, refs, v.child, path, depth + 1) } },
        .center => |v| .{ .center = .{ .key = try cloneOptString(allocator, v.key), .child = try cloneWidget(allocator, store, refs, v.child, path, depth + 1) } },
        .shortcuts => |v| .{ .shortcuts = .{ .key = try cloneOptString(allocator, v.key), .bindings = try cloneBindings(allocator, v.bindings), .child = try cloneWidget(allocator, store, refs, v.child, path, depth + 1) } },
        .default_text_style => |v| .{ .default_text_style = .{ .key = try cloneOptString(allocator, v.key), .style = v.style, .child = try cloneWidget(allocator, store, refs, v.child, path, depth + 1) } },
        .image => |v| blk: {
            try retainImage(store, refs, v.resource, v.tint);
            break :blk .{ .image = .{ .key = try cloneOptString(allocator, v.key), .resource = v.resource, .width = v.width, .height = v.height, .tint = v.tint } };
        },
        .icon => |v| .{ .icon = .{ .key = try cloneOptString(allocator, v.key), .name = try cloneString(allocator, v.name), .size = v.size, .color = v.color } },
        .composite => |v| .{ .composite = .{ .key = try cloneOptString(allocator, v.key), .identity = v.identity, .config = v.config, .kind = v.kind } },
    };
    return result;
}

fn cloneChildren(allocator: std.mem.Allocator, store: *resources_mod.Store, refs: *std.ArrayList(ui.ResourceId), source: ui.Widget.Children, path: *[max_depth + 1]*const ui.Widget, depth: usize) !ui.Widget.Children {
    const children = try allocator.alloc(ui.Widget, source.children.len);
    for (source.children, children) |*src, *dst| dst.* = (try cloneWidget(allocator, store, refs, src, path, depth + 1)).*;
    try validateUniqueSiblingKeys(children);
    return .{ .key = try cloneOptString(allocator, source.key), .children = children, .gap = source.gap, .cross_align = source.cross_align, .main_align = source.main_align };
}

fn cloneBindings(allocator: std.mem.Allocator, bindings: []const ui.Widget.ShortcutBinding) ![]ui.Widget.ShortcutBinding {
    for (bindings) |binding| if (binding.handler == 0) return error.InvalidNodeField;
    return allocator.dupe(ui.Widget.ShortcutBinding, bindings);
}
fn cloneString(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidString;
    return allocator.dupe(u8, value);
}
fn cloneOptString(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |s| try cloneString(allocator, s) else null;
}

fn retainImage(store: *resources_mod.Store, refs: *std.ArrayList(ui.ResourceId), resource: ui.ResourceId, tint: ?core.Color) !void {
    if (resource == 0) return error.InvalidNodeField;
    const entry = store.get(resource) orelse return error.InvalidResource;
    if (tint != null and entry.kind != .a8) return error.InvalidResource;
    try store.retainDocument(resource, null);
    refs.append(store.allocator, resource) catch |err| {
        store.releaseDocument(resource);
        return err;
    };
}

fn validateUniqueSiblingKeys(children: []const ui.Widget) !void {
    for (children, 0..) |child, index| {
        const key = widgetKey(child) orelse continue;
        for (children[0..index]) |previous| {
            const previous_key = widgetKey(previous) orelse continue;
            if (std.mem.eql(u8, key, previous_key)) return error.DuplicateSiblingKey;
        }
    }
}

fn widgetKey(widget: ui.Widget) ?[]const u8 {
    return switch (widget) {
        inline else => |value| value.key,
    };
}

fn validateWidget(w: ui.Widget) !void {
    switch (w) {
        .text => |v| {
            try validOptString(v.key);
            try validString(v.value);
            if (v.font_size) |x| try positiveFinite(x);
        },
        .container => |v| {
            try validOptString(v.key);
            try nonNegativeFinite(v.border_width);
            try nonNegativeFinite(v.radius);
            try nonNegativeFinite(v.min_width);
            try nonNegativeFinite(v.min_height);
        },
        .filled_button => |v| {
            try validOptString(v.key);
            try validString(v.id);
            if (v.handler == 0) return error.InvalidNodeField;
        },
        .gesture_detector => |v| {
            try validOptString(v.key);
            try validString(v.id);
            if (v.handler == 0) return error.InvalidNodeField;
        },
        .focus => |v| {
            try validOptString(v.key);
            try validString(v.node.id);
            if (v.on_focus_change == 0) return error.InvalidNodeField;
        },
        .focus_scope => |v| {
            try validOptString(v.key);
            try validString(v.id);
        },
        .single_child_scroll_view => |v| {
            try validOptString(v.key);
            try validString(v.id);
        },
        .text_field => |v| {
            try validOptString(v.key);
            try validString(v.id);
            try validString(v.focus_node.id);
            try validString(v.value);
            try validString(v.placeholder);
            if (v.on_change == 0) return error.InvalidNodeField;
            try finite(v.padding_x);
            try finite(v.padding_y);
            try nonNegativeFinite(v.radius);
        },
        .row => |v| {
            try validOptString(v.key);
            try nonNegativeFinite(v.gap);
        },
        .column => |v| {
            try validOptString(v.key);
            try nonNegativeFinite(v.gap);
        },
        .spacer => |v| {
            try validOptString(v.key);
            try positiveFinite(v.flex);
        },
        .flexible => |v| {
            try validOptString(v.key);
            try positiveFinite(v.flex);
        },
        .sized_box => |v| {
            try validOptString(v.key);
            if (v.width) |x| try nonNegativeFinite(x);
            if (v.height) |x| try nonNegativeFinite(x);
            try nonNegativeFinite(v.min_width);
            try nonNegativeFinite(v.min_height);
            if (v.max_width) |x| try nonNegativeFinite(x);
            if (v.max_height) |x| try nonNegativeFinite(x);
        },
        .padding => |v| {
            try validOptString(v.key);
            try finite(v.insets.left);
            try finite(v.insets.top);
            try finite(v.insets.right);
            try finite(v.insets.bottom);
        },
        .center => |v| try validOptString(v.key),
        .shortcuts => |v| {
            try validOptString(v.key);
            for (v.bindings) |b| if (b.handler == 0) return error.InvalidNodeField;
        },
        .default_text_style => |v| {
            try validOptString(v.key);
            if (v.style.font_size) |x| try positiveFinite(x);
        },
        .image => |v| {
            try validOptString(v.key);
            if (v.resource == 0) return error.InvalidNodeField;
            if (v.width) |x| try nonNegativeFinite(x);
            if (v.height) |x| try nonNegativeFinite(x);
        },
        .icon => |v| {
            try validOptString(v.key);
            try validString(v.name);
            try positiveFinite(v.size);
        },
        .composite => |v| {
            try validOptString(v.key);
            if (v.identity == 0 or v.config == 0) return error.InvalidNodeField;
        },
    }
}

fn validString(s: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidString;
}
fn validOptString(s: ?[]const u8) !void {
    if (s) |v| try validString(v);
}
fn finite(v: f32) !void {
    if (!std.math.isFinite(v)) return error.InvalidNodeField;
}
fn nonNegativeFinite(v: f32) !void {
    if (!std.math.isFinite(v) or v < 0) return error.InvalidNodeField;
}
fn positiveFinite(v: f32) !void {
    if (!std.math.isFinite(v) or v <= 0) return error.InvalidNodeField;
}

test "typed document owns borrowed strings" {
    var store = resources_mod.Store.init(std.testing.allocator);
    defer store.deinit();
    var value = [_]u8{ 'h', 'i' };
    var document = try Document.init(std.testing.allocator, &store, ui.text(&value));
    defer document.deinit();
    value = .{ 'n', 'o' };
    try std.testing.expectEqualStrings("hi", document.root.text.value);
}

test "typed document preserves disabled semantic button" {
    var store = resources_mod.Store.init(std.testing.allocator);
    defer store.deinit();
    const label = ui.text("Disabled");
    var document = try Document.init(std.testing.allocator, &store, ui.filled_button("disabled", null, &label));
    defer document.deinit();
    try std.testing.expectEqual(@as(?ui.HandlerId, null), document.root.filled_button.handler);
    try std.testing.expectEqualStrings("Disabled", document.root.filled_button.child.text.value);
}

test "typed document rejects cycles" {
    var store = resources_mod.Store.init(std.testing.allocator);
    defer store.deinit();
    var root: ui.Widget = undefined;
    root = .{ .center = .{ .child = &root } };
    try std.testing.expectError(error.CyclicDocument, Document.init(std.testing.allocator, &store, root));
}

test "typed document rejects duplicate sibling keys" {
    var store = resources_mod.Store.init(std.testing.allocator);
    defer store.deinit();
    const children = [_]ui.Widget{
        .{ .text = .{ .key = "same", .value = "one" } },
        .{ .text = .{ .key = "same", .value = "two" } },
    };
    const root: ui.Widget = .{ .column = .{ .children = &children } };
    try std.testing.expectError(error.DuplicateSiblingKey, Document.init(std.testing.allocator, &store, root));
}

test "documents retain image resources after host release" {
    var store = resources_mod.Store.init(std.testing.allocator);
    defer store.deinit();
    const resource = try store.createRgba8(1, 1, 4, &.{ 0xff, 0, 0, 0xff });
    var document = try Document.init(std.testing.allocator, &store, .{ .image = .{ .resource = resource } });
    store.releaseHost(resource);
    try std.testing.expect(store.get(resource) != null);
    document.deinit();
    try std.testing.expect(store.get(resource) == null);
}

test "RGBA images reject mask tint" {
    var store = resources_mod.Store.init(std.testing.allocator);
    defer store.deinit();
    const resource = try store.createRgba8(1, 1, 4, &.{ 0xff, 0, 0, 0xff });
    try std.testing.expectError(error.InvalidResource, Document.init(std.testing.allocator, &store, .{ .image = .{ .resource = resource, .tint = core.colors.white } }));
}
