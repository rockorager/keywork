//! Owned declarative documents and the version-0 wire decoder.

const std = @import("std");
const core = @import("core.zig");
const resources_mod = @import("resources.zig");
const ui = @import("ui.zig");

pub const wire_version: u16 = 0;
pub const wire_header_size: usize = 48;
pub const wire_node_size: usize = 80;
pub const wire_binding_size: usize = 16;
pub const wire_magic = "KWW0";
const key_flag: u16 = 0x8000;
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

    pub fn decode(allocator: std.mem.Allocator, store: *resources_mod.Store, bytes: []const u8) !Document {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        errdefer arena.deinit();
        var refs: std.ArrayList(ui.ResourceId) = .empty;
        errdefer releaseRefs(store, &refs);
        const root = try WireDecoder.decode(arena.allocator(), store, &refs, bytes);
        return .{ .arena = arena, .store = store, .root = root, .resources = refs };
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

const Record = struct {
    tag: u16,
    flags: u16,
    first_child: u32,
    child_count: u32,
    key_off: u32,
    key_len: u32,
    string_off: u32,
    string_len: u32,
    id0: u64,
    a: u32,
    b: u32,
    c: u32,
    d: u32,
    color0: u32,
    color1: u32,
    extra0: u32,
    extra1: u32,
    extra2: u32,
    extra3: u32,
    reserved: u32,
};

const WireDecoder = struct {
    allocator: std.mem.Allocator,
    store: *resources_mod.Store,
    refs: *std.ArrayList(ui.ResourceId),
    bytes: []const u8,
    node_count: usize,
    child_count: usize,
    binding_count: usize,
    children: []const u8,
    bindings: []const u8,
    strings: []const u8,
    states: []State,

    const State = enum { unseen, visiting, done };

    fn decode(allocator: std.mem.Allocator, store: *resources_mod.Store, refs: *std.ArrayList(ui.ResourceId), bytes: []const u8) !*ui.Widget {
        if (bytes.len < wire_header_size) return error.TruncatedDocument;
        if (!std.mem.eql(u8, bytes[0..4], wire_magic)) return error.InvalidDocumentMagic;
        if (readInt(u16, bytes, 4) != wire_version or readInt(u16, bytes, 6) != wire_header_size) return error.InvalidDocumentHeader;
        if (readInt(u32, bytes, 8) != bytes.len) return error.InvalidDocumentSize;
        const root: usize = readInt(u32, bytes, 12);
        const node_count: usize = readInt(u32, bytes, 16);
        const child_count: usize = readInt(u32, bytes, 20);
        const binding_count: usize = readInt(u32, bytes, 24);
        const string_size: usize = readInt(u32, bytes, 28);
        if (readInt(u32, bytes, 32) != 0 or readInt(u32, bytes, 36) != 0 or readInt(u32, bytes, 40) != 0 or readInt(u32, bytes, 44) != 0) return error.InvalidDocumentHeader;
        if (node_count == 0 or root >= node_count) return error.InvalidRootNode;
        const nodes_size = std.math.mul(usize, node_count, wire_node_size) catch return error.InvalidDocumentSize;
        const child_size = std.math.mul(usize, child_count, 4) catch return error.InvalidDocumentSize;
        const binding_size = std.math.mul(usize, binding_count, wire_binding_size) catch return error.InvalidDocumentSize;
        const child_off = std.math.add(usize, wire_header_size, nodes_size) catch return error.InvalidDocumentSize;
        const binding_off = std.math.add(usize, child_off, child_size) catch return error.InvalidDocumentSize;
        const string_off = std.math.add(usize, binding_off, binding_size) catch return error.InvalidDocumentSize;
        const end = std.math.add(usize, string_off, string_size) catch return error.InvalidDocumentSize;
        if (end != bytes.len) return error.InvalidDocumentSize;
        const states = try allocator.alloc(State, node_count);
        @memset(states, .unseen);
        var self: WireDecoder = .{ .allocator = allocator, .store = store, .refs = refs, .bytes = bytes, .node_count = node_count, .child_count = child_count, .binding_count = binding_count, .children = bytes[child_off..binding_off], .bindings = bytes[binding_off..string_off], .strings = bytes[string_off..], .states = states };
        const result = try self.node(root, 0);
        for (self.states) |state| if (state != .done) return error.UnreachableNode;
        return result;
    }

    fn node(self: *WireDecoder, index: usize, depth: usize) anyerror!*ui.Widget {
        if (index >= self.node_count) return error.InvalidNodeIndex;
        if (depth > max_depth) return error.DocumentTooDeep;
        switch (self.states[index]) {
            .unseen => {},
            .visiting => return error.CyclicDocument,
            .done => return error.DuplicateNodeReference,
        }
        self.states[index] = .visiting;
        errdefer self.states[index] = .unseen;
        const r = self.record(index);
        try validateRecord(r);
        const key = if (r.flags & key_flag != 0) try self.string(r.key_off, r.key_len) else null;
        const s = try self.string(r.string_off, r.string_len);
        const a: f32 = @bitCast(r.a);
        const b: f32 = @bitCast(r.b);
        const c: f32 = @bitCast(r.c);
        const d: f32 = @bitCast(r.d);
        const result = try self.allocator.create(ui.Widget);
        result.* = switch (r.tag) {
            1 => .{ .text = .{ .key = try cloneOptString(self.allocator, key), .value = try cloneString(self.allocator, s), .color = if (r.flags & 1 != 0) @bitCast(r.color0) else null, .font_size = if (r.flags & 2 != 0) a else null, .role = std.enums.fromInt(ui.TextRole, @as(u8, @truncate(r.extra0))) orelse return error.InvalidNodeField } },
            2 => .{ .row = try self.linear(r, key, a, depth) },
            3 => .{ .column = try self.linear(r, key, a, depth) },
            4 => .{ .container = .{ .key = try cloneOptString(self.allocator, key), .child = try self.onlyChild(r, depth), .background = @bitCast(r.color0), .border = if (r.flags & 1 != 0) @bitCast(r.color1) else null, .border_width = a, .radius = b, .min_width = c, .min_height = d, .horizontal_align = try enumFromInt(ui.Alignment, r.extra0), .vertical_align = try enumFromInt(ui.Alignment, r.extra1) } },
            5 => .{ .padding = .{ .key = try cloneOptString(self.allocator, key), .child = try self.onlyChild(r, depth), .insets = .{ .left = a, .top = b, .right = c, .bottom = d } } },
            6 => .{ .spacer = .{ .key = try cloneOptString(self.allocator, key), .flex = a } },
            7 => .{ .flexible = .{ .key = try cloneOptString(self.allocator, key), .child = try self.onlyChild(r, depth), .flex = a, .fit = try enumFromInt(ui.FlexFit, r.extra0) } },
            8 => .{ .gesture_detector = .{ .key = try cloneOptString(self.allocator, key), .id = try cloneString(self.allocator, s), .handler = r.id0, .child = try self.onlyChild(r, depth), .activation = if (r.flags & 2 != 0) .press else .release, .hover_style = if (r.flags & 1 != 0) .{ .background = @bitCast(r.color0) } else null } },
            9 => .{ .center = .{ .key = try cloneOptString(self.allocator, key), .child = try self.onlyChild(r, depth) } },
            10 => .{ .sized_box = .{ .key = try cloneOptString(self.allocator, key), .child = try self.onlyChild(r, depth), .width = if (r.flags & 1 != 0) a else null, .height = if (r.flags & 2 != 0) b else null, .min_width = c, .min_height = d, .max_width = if (r.flags & 4 != 0) @as(f32, @bitCast(r.extra0)) else null, .max_height = if (r.flags & 8 != 0) @as(f32, @bitCast(r.extra1)) else null } },
            11 => blk: {
                const tint: ?core.Color = if (r.flags & 4 != 0) @bitCast(r.color0) else null;
                try retainImage(self.store, self.refs, r.id0, tint);
                break :blk .{ .image = .{ .key = try cloneOptString(self.allocator, key), .resource = r.id0, .width = if (r.flags & 1 != 0) a else null, .height = if (r.flags & 2 != 0) b else null, .tint = tint } };
            },
            12 => .{ .icon = .{ .key = try cloneOptString(self.allocator, key), .name = try cloneString(self.allocator, s), .size = a, .color = if (r.flags & 1 != 0) @bitCast(r.color0) else null } },
            13 => .{ .single_child_scroll_view = .{ .key = try cloneOptString(self.allocator, key), .id = try cloneString(self.allocator, s), .child = try self.onlyChild(r, depth), .axes = try enumFromInt(ui.ScrollAxes, r.extra0) } },
            14 => .{ .focus = .{ .key = try cloneOptString(self.allocator, key), .node = .{ .id = try cloneString(self.allocator, s) }, .child = try self.onlyChild(r, depth), .on_focus_change = if (r.id0 != 0) r.id0 else null, .autofocus = r.flags & 1 != 0, .skip_traversal = r.flags & 2 != 0, .can_request_focus = r.flags & 4 != 0 } },
            15 => .{ .focus_scope = .{ .key = try cloneOptString(self.allocator, key), .id = try cloneString(self.allocator, s), .child = try self.onlyChild(r, depth), .modal = r.flags & 1 != 0 } },
            16 => .{ .text_field = .{ .key = try cloneOptString(self.allocator, key), .id = try cloneString(self.allocator, s), .focus_node = .{ .id = try cloneString(self.allocator, s) }, .value = try cloneString(self.allocator, try self.string(r.extra0, r.extra1)), .placeholder = try cloneString(self.allocator, try self.string(r.extra2, r.extra3)), .on_change = if (r.id0 != 0) r.id0 else null, .autofocus = r.flags & 1 != 0 } },
            17 => .{ .shortcuts = .{ .key = try cloneOptString(self.allocator, key), .bindings = try self.bindingSlice(r.extra0, r.extra1), .child = try self.onlyChild(r, depth) } },
            18 => .{ .default_text_style = .{ .key = try cloneOptString(self.allocator, key), .style = .{ .color = if (r.flags & 1 != 0) @bitCast(r.color0) else null, .font_size = if (r.flags & 2 != 0) a else null }, .child = try self.onlyChild(r, depth) } },
            19 => .{ .filled_button = .{ .key = try cloneOptString(self.allocator, key), .id = try cloneString(self.allocator, s), .handler = if (r.id0 != 0) r.id0 else null, .child = try self.onlyChild(r, depth), .activation = if (r.flags & 1 != 0) .release else .press } },
            else => return error.UnknownNodeTag,
        };
        try validateWidget(result.*);
        self.states[index] = .done;
        return result;
    }

    fn linear(self: *WireDecoder, r: Record, key: ?[]const u8, gap: f32, depth: usize) !ui.Widget.Children {
        try self.childRange(r.first_child, r.child_count);
        const children = try self.allocator.alloc(ui.Widget, r.child_count);
        for (children, 0..) |*child, i| child.* = (try self.node(try self.childIndex(r.first_child + i), depth + 1)).*;
        try validateUniqueSiblingKeys(children);
        return .{ .key = try cloneOptString(self.allocator, key), .children = children, .gap = gap, .cross_align = try enumFromInt(ui.CrossAlignment, r.extra0), .main_align = try enumFromInt(ui.MainAlignment, r.extra1) };
    }

    fn onlyChild(self: *WireDecoder, r: Record, depth: usize) !*ui.Widget {
        if (r.child_count != 1) return error.InvalidChildCount;
        try self.childRange(r.first_child, r.child_count);
        return self.node(try self.childIndex(r.first_child), depth + 1);
    }

    fn bindingSlice(self: *WireDecoder, first: u32, count: u32) ![]ui.Widget.ShortcutBinding {
        const end = std.math.add(usize, first, count) catch return error.InvalidNodeField;
        if (end > self.binding_count) return error.InvalidNodeField;
        const out = try self.allocator.alloc(ui.Widget.ShortcutBinding, count);
        for (out, 0..) |*dst, i| {
            const off = (first + i) * wire_binding_size;
            if (readInt(u32, self.bindings, off + 4) != 0) return error.InvalidNodeField;
            const handler = readInt(u64, self.bindings, off + 8);
            if (handler == 0) return error.InvalidNodeField;
            dst.* = .{ .key = try enumFromInt(ui.ShortcutKey, readInt(u32, self.bindings, off)), .handler = handler };
        }
        return out;
    }

    fn record(self: *WireDecoder, index: usize) Record {
        const o = wire_header_size + index * wire_node_size;
        return .{ .tag = readInt(u16, self.bytes, o), .flags = readInt(u16, self.bytes, o + 2), .first_child = readInt(u32, self.bytes, o + 4), .child_count = readInt(u32, self.bytes, o + 8), .key_off = readInt(u32, self.bytes, o + 12), .key_len = readInt(u32, self.bytes, o + 16), .string_off = readInt(u32, self.bytes, o + 20), .string_len = readInt(u32, self.bytes, o + 24), .id0 = readInt(u64, self.bytes, o + 28), .a = readInt(u32, self.bytes, o + 36), .b = readInt(u32, self.bytes, o + 40), .c = readInt(u32, self.bytes, o + 44), .d = readInt(u32, self.bytes, o + 48), .color0 = readInt(u32, self.bytes, o + 52), .color1 = readInt(u32, self.bytes, o + 56), .extra0 = readInt(u32, self.bytes, o + 60), .extra1 = readInt(u32, self.bytes, o + 64), .extra2 = readInt(u32, self.bytes, o + 68), .extra3 = readInt(u32, self.bytes, o + 72), .reserved = readInt(u32, self.bytes, o + 76) };
    }

    fn childIndex(self: *WireDecoder, index: usize) !usize {
        if (index >= self.child_count) return error.InvalidChildIndex;
        return readInt(u32, self.children, index * 4);
    }

    fn childRange(self: *WireDecoder, first: usize, count: usize) !void {
        const end = std.math.add(usize, first, count) catch return error.InvalidChildIndex;
        if (end > self.child_count) return error.InvalidChildIndex;
    }

    fn string(self: *WireDecoder, off: usize, len: usize) ![]const u8 {
        const end = std.math.add(usize, off, len) catch return error.InvalidString;
        if (end > self.strings.len) return error.InvalidString;
        const s = self.strings[off..end];
        if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidString;
        return s;
    }
};

fn validateRecord(r: Record) !void {
    if (r.reserved != 0) return error.InvalidNodeField;
    if (r.flags & key_flag == 0 and (r.key_off != 0 or r.key_len != 0)) return error.InvalidNodeField;
    if (r.child_count == 0 and r.first_child != 0) return error.InvalidNodeField;
    const vf = r.flags & ~key_flag;
    switch (r.tag) {
        1 => if (vf & ~@as(u16, 3) != 0 or r.child_count != 0 or r.id0 != 0 or r.b != 0 or r.c != 0 or r.d != 0 or absent(vf, 1, r.color0) or absent(vf, 2, r.a) or r.color1 != 0 or r.extra1 != 0 or r.extra2 != 0 or r.extra3 != 0) return error.InvalidNodeField,
        2, 3 => if (vf != 0 or hasString(r) or r.id0 != 0 or r.b != 0 or r.c != 0 or r.d != 0 or hasColors(r) or r.extra2 != 0 or r.extra3 != 0) return error.InvalidNodeField,
        4 => if (vf & ~@as(u16, 1) != 0 or r.child_count != 1 or hasString(r) or r.id0 != 0 or absent(vf, 1, r.color1) or r.extra2 != 0 or r.extra3 != 0) return error.InvalidNodeField,
        5 => if (vf != 0 or r.child_count != 1 or hasString(r) or r.id0 != 0 or hasColors(r) or hasExtras(r)) return error.InvalidNodeField,
        6 => if (vf != 0 or r.child_count != 0 or hasString(r) or r.id0 != 0 or r.b != 0 or r.c != 0 or r.d != 0 or hasColors(r) or hasExtras(r)) return error.InvalidNodeField,
        7 => if (vf != 0 or r.child_count != 1 or hasString(r) or r.id0 != 0 or r.b != 0 or r.c != 0 or r.d != 0 or hasColors(r) or r.extra1 != 0 or r.extra2 != 0 or r.extra3 != 0) return error.InvalidNodeField,
        8 => if (vf & ~@as(u16, 3) != 0 or r.child_count != 1 or r.id0 == 0 or r.a != 0 or r.b != 0 or r.c != 0 or r.d != 0 or absent(vf, 1, r.color0) or r.color1 != 0 or hasExtras(r)) return error.InvalidNodeField,
        9 => if (vf != 0 or r.child_count != 1 or hasString(r) or r.id0 != 0 or hasNumbers(r) or hasColors(r) or hasExtras(r)) return error.InvalidNodeField,
        10 => if (vf & ~@as(u16, 15) != 0 or r.child_count != 1 or hasString(r) or r.id0 != 0 or absent(vf, 1, r.a) or absent(vf, 2, r.b) or absent(vf, 4, r.extra0) or absent(vf, 8, r.extra1) or hasColors(r) or r.extra2 != 0 or r.extra3 != 0) return error.InvalidNodeField,
        11 => if (vf & ~@as(u16, 7) != 0 or r.child_count != 0 or hasString(r) or r.id0 == 0 or absent(vf, 1, r.a) or absent(vf, 2, r.b) or r.c != 0 or r.d != 0 or absent(vf, 4, r.color0) or r.color1 != 0 or hasExtras(r)) return error.InvalidNodeField,
        12 => if (vf & ~@as(u16, 1) != 0 or r.child_count != 0 or r.id0 != 0 or r.b != 0 or r.c != 0 or r.d != 0 or absent(vf, 1, r.color0) or r.color1 != 0 or hasExtras(r)) return error.InvalidNodeField,
        13 => if (vf != 0 or r.child_count != 1 or r.id0 != 0 or hasNumbers(r) or hasColors(r) or r.extra1 != 0 or r.extra2 != 0 or r.extra3 != 0) return error.InvalidNodeField,
        14 => if (vf & ~@as(u16, 7) != 0 or r.child_count != 1 or hasNumbers(r) or hasColors(r) or hasExtras(r)) return error.InvalidNodeField,
        15 => if (vf & ~@as(u16, 1) != 0 or r.child_count != 1 or r.id0 != 0 or hasNumbers(r) or hasColors(r) or hasExtras(r)) return error.InvalidNodeField,
        16 => if (vf & ~@as(u16, 1) != 0 or r.child_count != 0 or hasNumbers(r) or hasColors(r)) return error.InvalidNodeField,
        17 => if (vf != 0 or r.child_count != 1 or hasString(r) or r.id0 != 0 or hasNumbers(r) or hasColors(r) or r.extra2 != 0 or r.extra3 != 0) return error.InvalidNodeField,
        18 => if (vf & ~@as(u16, 3) != 0 or r.child_count != 1 or hasString(r) or r.id0 != 0 or absent(vf, 1, r.color0) or absent(vf, 2, r.a) or r.b != 0 or r.c != 0 or r.d != 0 or r.color1 != 0 or hasExtras(r)) return error.InvalidNodeField,
        19 => if (vf & ~@as(u16, 1) != 0 or r.child_count != 1 or hasNumbers(r) or hasColors(r) or hasExtras(r)) return error.InvalidNodeField,
        else => return error.UnknownNodeTag,
    }
}

fn absent(flags: u16, flag: u16, value: u32) bool {
    return flags & flag == 0 and value != 0;
}

fn hasString(r: Record) bool {
    return r.string_off != 0 or r.string_len != 0;
}

fn hasNumbers(r: Record) bool {
    return r.a != 0 or r.b != 0 or r.c != 0 or r.d != 0;
}

fn hasColors(r: Record) bool {
    return r.color0 != 0 or r.color1 != 0;
}

fn hasExtras(r: Record) bool {
    return r.extra0 != 0 or r.extra1 != 0 or r.extra2 != 0 or r.extra3 != 0;
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
    }
}

fn validString(s: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidString;
}
fn validOptString(s: ?[]const u8) !void {
    if (s) |v| try validString(v);
}
fn enumFromInt(comptime T: type, value: anytype) !T {
    return std.enums.fromInt(T, value) orelse return error.InvalidNodeField;
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
fn readInt(comptime T: type, bytes: []const u8, offset: usize) T {
    const size = @divExact(@typeInfo(T).int.bits, 8);
    return std.mem.readInt(T, bytes[offset..][0..size], .little);
}

fn writeInt(comptime T: type, bytes: []u8, offset: usize, value: T) void {
    const size = @divExact(@typeInfo(T).int.bits, 8);
    std.mem.writeInt(T, bytes[offset..][0..size], value, .little);
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

test "wire decoder rejects cycles" {
    var store = resources_mod.Store.init(std.testing.allocator);
    defer store.deinit();
    var bytes = [_]u8{0} ** (wire_header_size + wire_node_size + 4);
    @memcpy(bytes[0..4], wire_magic);
    writeInt(u16, &bytes, 4, wire_version);
    writeInt(u16, &bytes, 6, wire_header_size);
    writeInt(u32, &bytes, 8, bytes.len);
    writeInt(u32, &bytes, 16, 1);
    writeInt(u32, &bytes, 20, 1);
    writeInt(u16, &bytes, wire_header_size, 9);
    writeInt(u32, &bytes, wire_header_size + 8, 1);
    writeInt(u32, &bytes, wire_header_size + wire_node_size, 0);
    try std.testing.expectError(error.CyclicDocument, Document.decode(std.testing.allocator, &store, &bytes));
}

test "wire decoder rejects shared node references" {
    var store = resources_mod.Store.init(std.testing.allocator);
    defer store.deinit();
    var bytes = [_]u8{0} ** (wire_header_size + 2 * wire_node_size + 8);
    @memcpy(bytes[0..4], wire_magic);
    writeInt(u16, &bytes, 4, wire_version);
    writeInt(u16, &bytes, 6, wire_header_size);
    writeInt(u32, &bytes, 8, bytes.len);
    writeInt(u32, &bytes, 16, 2);
    writeInt(u32, &bytes, 20, 2);
    writeInt(u16, &bytes, wire_header_size, 2);
    writeInt(u32, &bytes, wire_header_size + 8, 2);
    const child_off = wire_header_size + 2 * wire_node_size;
    writeInt(u32, &bytes, child_off, 1);
    writeInt(u32, &bytes, child_off + 4, 1);
    writeInt(u16, &bytes, wire_header_size + wire_node_size, 1);
    try std.testing.expectError(error.DuplicateNodeReference, Document.decode(std.testing.allocator, &store, &bytes));
}

test "wire decoder decodes sized max fields" {
    var store = resources_mod.Store.init(std.testing.allocator);
    defer store.deinit();
    var bytes = [_]u8{0} ** (wire_header_size + 2 * wire_node_size + 4);
    @memcpy(bytes[0..4], wire_magic);
    writeInt(u16, &bytes, 4, wire_version);
    writeInt(u16, &bytes, 6, wire_header_size);
    writeInt(u32, &bytes, 8, bytes.len);
    writeInt(u32, &bytes, 16, 2);
    writeInt(u32, &bytes, 20, 1);
    writeInt(u16, &bytes, wire_header_size, 10);
    writeInt(u16, &bytes, wire_header_size + 2, 0x0c);
    writeInt(u32, &bytes, wire_header_size + 8, 1);
    writeInt(u32, &bytes, wire_header_size + 60, @bitCast(@as(f32, 10)));
    writeInt(u32, &bytes, wire_header_size + 64, @bitCast(@as(f32, 20)));
    writeInt(u32, &bytes, wire_header_size + 2 * wire_node_size, 1);
    writeInt(u16, &bytes, wire_header_size + wire_node_size, 1);
    var doc = try Document.decode(std.testing.allocator, &store, &bytes);
    defer doc.deinit();
    try std.testing.expectEqual(@as(f32, 10), doc.root.sized_box.max_width.?);
    try std.testing.expectEqual(@as(f32, 20), doc.root.sized_box.max_height.?);
}

test "wire decoder rejects zero handlers" {
    var store = resources_mod.Store.init(std.testing.allocator);
    defer store.deinit();
    var bytes = [_]u8{0} ** (wire_header_size + 2 * wire_node_size + 4);
    @memcpy(bytes[0..4], wire_magic);
    writeInt(u16, &bytes, 4, wire_version);
    writeInt(u16, &bytes, 6, wire_header_size);
    writeInt(u32, &bytes, 8, bytes.len);
    writeInt(u32, &bytes, 16, 2);
    writeInt(u32, &bytes, 20, 1);
    writeInt(u16, &bytes, wire_header_size, 8);
    writeInt(u32, &bytes, wire_header_size + 8, 1);
    writeInt(u32, &bytes, wire_header_size + 2 * wire_node_size, 1);
    writeInt(u16, &bytes, wire_header_size + wire_node_size, 1);
    try std.testing.expectError(error.InvalidNodeField, Document.decode(std.testing.allocator, &store, &bytes));
}
