//! Compositor-owned window placement and visual effect state.

const Self = @This();

const std = @import("std");
const render = @import("render/types.zig");
const slot_map = @import("slot_map.zig");
const Surface = @import("wayland/surface.zig");

allocator: std.mem.Allocator,
windows: Store,
decorations: DecorationStore,
shell_surfaces: ShellSurfaceStore,
layer_surfaces: LayerSurfaceStore,
layer_stacks: [layer_count]std.ArrayList(LayerSurfaceId),
popups: PopupStore,
popup_stack: std.ArrayList(PopupId),
stack: std.ArrayList(NodeId),
stack_snapshot: std.ArrayList(NodeId),
stack_update_active: bool,
stack_update_repaint: bool,
repaint_listener: ?RepaintListener,

pub const Store = slot_map.SlotMap(Window, enum { scene_window });
pub const Id = Store.Id;
pub const DecorationStore = slot_map.SlotMap(Decoration, enum { scene_decoration });
pub const DecorationId = DecorationStore.Id;
pub const ShellSurfaceStore = slot_map.SlotMap(ShellSurface, enum { scene_shell_surface });
pub const ShellSurfaceId = ShellSurfaceStore.Id;
pub const LayerSurfaceStore = slot_map.SlotMap(LayerSurface, enum { scene_layer_surface });
pub const LayerSurfaceId = LayerSurfaceStore.Id;
pub const PopupStore = slot_map.SlotMap(Popup, enum { scene_popup });
pub const PopupId = PopupStore.Id;

const layer_count = @typeInfo(Layer).@"enum".fields.len;

pub const NodeId = union(enum) {
    window: Id,
    shell_surface: ShellSurfaceId,
};

pub const Position = struct {
    x: i32 = 0,
    y: i32 = 0,
};

pub const BorderEdges = packed struct(u8) {
    top: bool = false,
    bottom: bool = false,
    left: bool = false,
    right: bool = false,
    _padding: u4 = 0,
};

pub const Borders = struct {
    edges: BorderEdges,
    width: u32,
    color: render.Color,
};

pub const ClipBox = render.Rect;

pub const ContentGeometry = struct {
    offset: Position = .{},
    size: render.Size,
};

pub const Blur = struct {
    radius: u32,
    downsample_level: ?u8 = null,
    finish: render.BackdropBlurFinish = .{},
};

pub const Shadow = struct {
    offset: Position = .{},
    blur_radius: u32,
    spread: i32 = 0,
    color: render.Color,
};

pub const Effects = struct {
    corner_radius: u32 = 0,
    shadow: ?Shadow = null,
    contact_shadow: ?Shadow = null,
};

pub const background_blur: Blur = .{
    .radius = 48,
    .downsample_level = 4,
    .finish = .{
        .brightness = 0.88,
        .contrast = 0.87,
        .saturation = 1,
        .noise = 0.003,
    },
};

pub const default_effects: Effects = .{
    .corner_radius = 12,
    .shadow = .{
        .offset = .{ .y = 10 },
        .blur_radius = 44,
        .spread = 0,
        .color = render.Color.rgba(0, 0, 0, 0x70),
    },
    .contact_shadow = .{
        .offset = .{ .y = 2 },
        .blur_radius = 12,
        .spread = 0,
        .color = render.Color.rgba(0, 0, 0, 0x50),
    },
};

pub const Window = struct {
    surface_id: Surface.Id,
    position: Position = .{},
    mapped: bool = false,
    focused: bool = false,
    fullscreen: bool = false,
    effects: Effects = default_effects,
    borders: ?Borders = null,
    clip_box: ?ClipBox = null,
    shadow_clip_box: ?ClipBox = null,
    content_clip_box: ?ClipBox = null,
    content_geometry: ?ContentGeometry = null,
};

pub const DecorationLayer = enum {
    below,
    above,
};

pub const Decoration = struct {
    window_id: Id,
    surface_id: Surface.Id,
    layer: DecorationLayer,
    offset: Position = .{},
    mapped: bool = false,
};

pub const ShellSurface = struct {
    surface_id: Surface.Id,
    position: Position = .{},
    mapped: bool = false,
};

pub const Layer = enum {
    background,
    bottom,
    top,
    overlay,
};

pub const LayerSurface = struct {
    surface_id: Surface.Id,
    position: Position = .{},
    layer: Layer,
    mapped: bool = false,
};

pub const PopupParent = union(enum) {
    window: Id,
    layer_surface: LayerSurfaceId,
    popup: PopupId,
};

pub const Popup = struct {
    surface_id: Surface.Id,
    parent: PopupParent,
    position: Position = .{},
    mapped: bool = false,
    content_geometry: ?ContentGeometry = null,
};

pub const RepaintListener = struct {
    context: *anyopaque,
    request: *const fn (*anyopaque) void,
    surface_changed: *const fn (*anyopaque, Surface.Id) void,
    window_changed: *const fn (*anyopaque, Id) void,
};

pub const Iterator = struct {
    scene: *Self,
    index: usize = 0,

    pub const Entry = struct {
        id: Id,
        window: *Window,
    };

    pub fn next(self: *Iterator) ?Entry {
        while (self.index < self.scene.stack.items.len) {
            const node_id = self.scene.stack.items[self.index];
            self.index += 1;
            const id = switch (node_id) {
                .window => |id| id,
                .shell_surface => continue,
            };
            const window = self.scene.windows.get(id) orelse continue;
            return .{ .id = id, .window = window };
        }
        return null;
    }
};

pub const NodeIterator = struct {
    scene: *Self,
    index: usize = 0,

    pub const Entry = union(enum) {
        window: Iterator.Entry,
        shell_surface: struct {
            id: ShellSurfaceId,
            shell_surface: *ShellSurface,
        },
    };

    pub fn next(self: *NodeIterator) ?Entry {
        while (self.index < self.scene.stack.items.len) {
            const id = self.scene.stack.items[self.index];
            self.index += 1;
            switch (id) {
                .window => |window_id| {
                    const window = self.scene.windows.get(window_id) orelse continue;
                    return .{ .window = .{ .id = window_id, .window = window } };
                },
                .shell_surface => |shell_id| {
                    const shell_surface = self.scene.shell_surfaces.get(shell_id) orelse continue;
                    return .{ .shell_surface = .{
                        .id = shell_id,
                        .shell_surface = shell_surface,
                    } };
                },
            }
        }
        return null;
    }
};

pub const ReverseNodeIterator = struct {
    scene: *Self,
    index: usize,

    pub fn next(self: *ReverseNodeIterator) ?NodeIterator.Entry {
        while (self.index > 0) {
            self.index -= 1;
            const id = self.scene.stack.items[self.index];
            switch (id) {
                .window => |window_id| {
                    const window = self.scene.windows.get(window_id) orelse continue;
                    return .{ .window = .{ .id = window_id, .window = window } };
                },
                .shell_surface => |shell_id| {
                    const shell_surface = self.scene.shell_surfaces.get(shell_id) orelse continue;
                    return .{ .shell_surface = .{
                        .id = shell_id,
                        .shell_surface = shell_surface,
                    } };
                },
            }
        }
        return null;
    }
};

pub const LayerSurfaceIterator = struct {
    scene: *Self,
    layer: Layer,
    index: usize = 0,

    pub const Entry = struct {
        id: LayerSurfaceId,
        layer_surface: *LayerSurface,
    };

    pub fn next(self: *LayerSurfaceIterator) ?Entry {
        const stack = self.scene.layer_stacks[layerIndex(self.layer)].items;
        while (self.index < stack.len) {
            const id = stack[self.index];
            self.index += 1;
            const layer_surface = self.scene.layer_surfaces.get(id) orelse continue;
            return .{ .id = id, .layer_surface = layer_surface };
        }
        return null;
    }
};

pub const ReverseLayerSurfaceIterator = struct {
    scene: *Self,
    layer: Layer,
    index: usize,

    pub fn next(self: *ReverseLayerSurfaceIterator) ?LayerSurfaceIterator.Entry {
        const stack = self.scene.layer_stacks[layerIndex(self.layer)].items;
        while (self.index > 0) {
            self.index -= 1;
            const id = stack[self.index];
            const layer_surface = self.scene.layer_surfaces.get(id) orelse continue;
            return .{ .id = id, .layer_surface = layer_surface };
        }
        return null;
    }
};

pub const DecorationIterator = struct {
    inner: DecorationStore.Iterator,
    window_id: Id,
    layer: DecorationLayer,

    pub const Entry = struct {
        id: DecorationId,
        decoration: *Decoration,
    };

    pub fn next(self: *DecorationIterator) ?Entry {
        while (self.inner.next()) |entry| {
            if (!std.meta.eql(entry.value.window_id, self.window_id)) continue;
            if (entry.value.layer != self.layer) continue;
            return .{ .id = entry.id, .decoration = entry.value };
        }
        return null;
    }
};

pub const PopupIterator = struct {
    scene: *Self,
    window_id: Id,
    index: usize = 0,

    pub const Entry = struct {
        id: PopupId,
        popup: *Popup,
        position: Position,
    };

    pub fn next(self: *PopupIterator) ?Entry {
        while (self.index < self.scene.popup_stack.items.len) {
            const id = self.scene.popup_stack.items[self.index];
            self.index += 1;
            const popup = self.scene.popups.get(id) orelse continue;
            const root = self.scene.popupRootWindow(id) orelse continue;
            if (!std.meta.eql(root, self.window_id)) continue;
            const position = self.scene.popupGlobalPosition(id) orelse continue;
            return .{ .id = id, .popup = popup, .position = position };
        }
        return null;
    }
};

pub const ReversePopupIterator = struct {
    scene: *Self,
    window_id: Id,
    index: usize,

    pub fn next(self: *ReversePopupIterator) ?PopupIterator.Entry {
        while (self.index > 0) {
            self.index -= 1;
            const id = self.scene.popup_stack.items[self.index];
            const popup = self.scene.popups.get(id) orelse continue;
            const root = self.scene.popupRootWindow(id) orelse continue;
            if (!std.meta.eql(root, self.window_id)) continue;
            const position = self.scene.popupGlobalPosition(id) orelse continue;
            return .{ .id = id, .popup = popup, .position = position };
        }
        return null;
    }
};

pub const LayerPopupIterator = struct {
    scene: *Self,
    layer_surface_id: LayerSurfaceId,
    index: usize = 0,

    pub fn next(self: *LayerPopupIterator) ?PopupIterator.Entry {
        while (self.index < self.scene.popup_stack.items.len) {
            const id = self.scene.popup_stack.items[self.index];
            self.index += 1;
            const popup = self.scene.popups.get(id) orelse continue;
            const root = self.scene.popupRootLayerSurface(id) orelse continue;
            if (!std.meta.eql(root, self.layer_surface_id)) continue;
            const position = self.scene.popupGlobalPosition(id) orelse continue;
            return .{ .id = id, .popup = popup, .position = position };
        }
        return null;
    }
};

pub const ReverseLayerPopupIterator = struct {
    scene: *Self,
    layer_surface_id: LayerSurfaceId,
    index: usize,

    pub fn next(self: *ReverseLayerPopupIterator) ?PopupIterator.Entry {
        while (self.index > 0) {
            self.index -= 1;
            const id = self.scene.popup_stack.items[self.index];
            const popup = self.scene.popups.get(id) orelse continue;
            const root = self.scene.popupRootLayerSurface(id) orelse continue;
            if (!std.meta.eql(root, self.layer_surface_id)) continue;
            const position = self.scene.popupGlobalPosition(id) orelse continue;
            return .{ .id = id, .popup = popup, .position = position };
        }
        return null;
    }
};

pub fn init(self: *Self, allocator: std.mem.Allocator) void {
    self.* = .{
        .allocator = allocator,
        .windows = .{},
        .decorations = .{},
        .shell_surfaces = .{},
        .layer_surfaces = .{},
        .layer_stacks = @splat(.empty),
        .popups = .{},
        .popup_stack = .empty,
        .stack = .empty,
        .stack_snapshot = .empty,
        .stack_update_active = false,
        .stack_update_repaint = false,
        .repaint_listener = null,
    };
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.windows.len() == 0);
    std.debug.assert(self.decorations.len() == 0);
    std.debug.assert(self.shell_surfaces.len() == 0);
    std.debug.assert(self.layer_surfaces.len() == 0);
    std.debug.assert(self.popups.len() == 0);
    std.debug.assert(self.popup_stack.items.len == 0);
    std.debug.assert(self.stack.items.len == 0);
    std.debug.assert(!self.stack_update_active);
    std.debug.assert(self.stack_snapshot.items.len == 0);
    self.windows.deinit(self.allocator);
    self.decorations.deinit(self.allocator);
    self.shell_surfaces.deinit(self.allocator);
    self.layer_surfaces.deinit(self.allocator);
    for (&self.layer_stacks) |*stack| {
        std.debug.assert(stack.items.len == 0);
        stack.deinit(self.allocator);
    }
    self.popups.deinit(self.allocator);
    self.popup_stack.deinit(self.allocator);
    self.stack.deinit(self.allocator);
    self.stack_snapshot.deinit(self.allocator);
    self.* = undefined;
}

pub fn setRepaintListener(self: *Self, listener: RepaintListener) void {
    std.debug.assert(self.repaint_listener == null);
    self.repaint_listener = listener;
}

pub fn clearRepaintListener(self: *Self) void {
    std.debug.assert(self.repaint_listener != null);
    self.repaint_listener = null;
}

pub fn addWindow(self: *Self, surface_id: Surface.Id) error{OutOfMemory}!Id {
    const id = try self.windows.insert(self.allocator, .{ .surface_id = surface_id });
    errdefer _ = self.windows.remove(id);
    try self.stack.append(self.allocator, .{ .window = id });
    return id;
}

pub fn removeWindow(self: *Self, id: Id) void {
    const window = self.windows.remove(id) orelse return;
    while (self.firstWindowPopup(id)) |popup_id| self.removePopup(popup_id);
    var decorations = self.decorations.iterator();
    while (decorations.next()) |entry| {
        if (std.meta.eql(entry.value.window_id, id)) {
            _ = self.decorations.remove(entry.id);
        }
    }
    for (self.stack.items, 0..) |candidate, index| {
        if (std.meta.eql(candidate, NodeId{ .window = id })) {
            _ = self.stack.orderedRemove(index);
            break;
        }
    }
    if (window.mapped) self.requestRepaint();
}

pub fn addShellSurface(
    self: *Self,
    surface_id: Surface.Id,
) error{OutOfMemory}!ShellSurfaceId {
    const id = try self.shell_surfaces.insert(self.allocator, .{ .surface_id = surface_id });
    errdefer _ = self.shell_surfaces.remove(id);
    try self.stack.append(self.allocator, .{ .shell_surface = id });
    return id;
}

pub fn removeShellSurface(self: *Self, id: ShellSurfaceId) void {
    const shell_surface = self.shell_surfaces.remove(id) orelse return;
    for (self.stack.items, 0..) |candidate, index| {
        if (std.meta.eql(candidate, NodeId{ .shell_surface = id })) {
            _ = self.stack.orderedRemove(index);
            break;
        }
    }
    if (shell_surface.mapped) self.requestRepaint();
}

pub fn setShellSurfaceMapped(self: *Self, id: ShellSurfaceId, mapped: bool) void {
    const shell_surface = self.shell_surfaces.get(id) orelse return;
    if (shell_surface.mapped == mapped) return;
    shell_surface.mapped = mapped;
    self.requestRepaint();
}

pub fn setShellSurfacePosition(self: *Self, id: ShellSurfaceId, position: Position) void {
    const shell_surface = self.shell_surfaces.get(id) orelse return;
    if (std.meta.eql(shell_surface.position, position)) return;
    shell_surface.position = position;
    if (shell_surface.mapped) self.requestRepaint();
}

pub fn shellSurfaceCommitted(self: *Self, id: ShellSurfaceId) void {
    const shell_surface = self.shell_surfaces.get(id) orelse return;
    if (shell_surface.mapped) self.requestSurfaceChanged(shell_surface.surface_id);
}

pub fn addLayerSurface(
    self: *Self,
    surface_id: Surface.Id,
    layer: Layer,
) error{OutOfMemory}!LayerSurfaceId {
    const id = try self.layer_surfaces.insert(self.allocator, .{
        .surface_id = surface_id,
        .layer = layer,
    });
    errdefer _ = self.layer_surfaces.remove(id);
    try self.layer_stacks[layerIndex(layer)].append(self.allocator, id);
    return id;
}

pub fn removeLayerSurface(self: *Self, id: LayerSurfaceId) void {
    const layer_surface = self.layer_surfaces.remove(id) orelse return;
    while (self.firstLayerSurfacePopup(id)) |popup_id| self.removePopup(popup_id);
    removeLayerSurfaceFromStack(self, id, layer_surface.layer);
    if (layer_surface.mapped) self.requestRepaint();
}

pub fn setLayerSurfaceMapped(self: *Self, id: LayerSurfaceId, mapped: bool) void {
    const layer_surface = self.layer_surfaces.get(id) orelse return;
    if (layer_surface.mapped == mapped) return;
    layer_surface.mapped = mapped;
    self.requestRepaint();
}

pub fn setLayerSurfacePosition(
    self: *Self,
    id: LayerSurfaceId,
    position: Position,
) void {
    const layer_surface = self.layer_surfaces.get(id) orelse return;
    if (std.meta.eql(layer_surface.position, position)) return;
    layer_surface.position = position;
    if (layer_surface.mapped) self.requestRepaint();
}

pub fn setLayerSurfaceLayer(
    self: *Self,
    id: LayerSurfaceId,
    layer: Layer,
) error{OutOfMemory}!void {
    const layer_surface = self.layer_surfaces.get(id) orelse return;
    if (layer_surface.layer == layer) return;
    try self.layer_stacks[layerIndex(layer)].append(self.allocator, id);
    removeLayerSurfaceFromStack(self, id, layer_surface.layer);
    layer_surface.layer = layer;
    if (layer_surface.mapped) self.requestRepaint();
}

pub fn layerSurfaceCommitted(self: *Self, id: LayerSurfaceId) void {
    const layer_surface = self.layer_surfaces.get(id) orelse return;
    if (layer_surface.mapped) self.requestSurfaceChanged(layer_surface.surface_id);
}

pub fn addPopup(
    self: *Self,
    surface_id: Surface.Id,
    parent: PopupParent,
) error{ InvalidParent, OutOfMemory }!PopupId {
    switch (parent) {
        .window => |id| if (self.windows.get(id) == null) return error.InvalidParent,
        .layer_surface => |id| if (self.layer_surfaces.get(id) == null) return error.InvalidParent,
        .popup => |id| if (self.popups.get(id) == null) return error.InvalidParent,
    }
    const id = try self.popups.insert(self.allocator, .{
        .surface_id = surface_id,
        .parent = parent,
    });
    errdefer _ = self.popups.remove(id);
    try self.popup_stack.append(self.allocator, id);
    return id;
}

pub fn removePopup(self: *Self, id: PopupId) void {
    while (self.firstChildPopup(id)) |child_id| self.removePopup(child_id);
    const popup = self.popups.remove(id) orelse return;
    for (self.popup_stack.items, 0..) |candidate, index| {
        if (!std.meta.eql(candidate, id)) continue;
        _ = self.popup_stack.orderedRemove(index);
        break;
    }
    if (popup.mapped) self.requestRepaint();
}

pub fn setPopupMapped(self: *Self, id: PopupId, mapped: bool) void {
    const popup = self.popups.get(id) orelse return;
    if (popup.mapped == mapped) return;
    popup.mapped = mapped;
    self.requestRepaint();
}

pub fn setPopupPosition(self: *Self, id: PopupId, position: Position) void {
    const popup = self.popups.get(id) orelse return;
    if (std.meta.eql(popup.position, position)) return;
    popup.position = position;
    if (popup.mapped) self.requestRepaint();
}

pub fn setPopupContentGeometry(
    self: *Self,
    id: PopupId,
    geometry: ?ContentGeometry,
) void {
    const popup = self.popups.get(id) orelse return;
    if (std.meta.eql(popup.content_geometry, geometry)) return;
    popup.content_geometry = geometry;
    if (popup.mapped) self.requestRepaint();
}

pub fn popupCommitted(self: *Self, id: PopupId) void {
    const popup = self.popups.get(id) orelse return;
    if (popup.mapped) self.requestSurfaceChanged(popup.surface_id);
}

pub fn addDecoration(
    self: *Self,
    window_id: Id,
    surface_id: Surface.Id,
    layer: DecorationLayer,
) error{ InvalidWindow, OutOfMemory }!DecorationId {
    if (self.windows.get(window_id) == null) return error.InvalidWindow;
    return self.decorations.insert(self.allocator, .{
        .window_id = window_id,
        .surface_id = surface_id,
        .layer = layer,
    });
}

pub fn removeDecoration(self: *Self, id: DecorationId) void {
    const decoration = self.decorations.remove(id) orelse return;
    const window = self.windows.get(decoration.window_id) orelse return;
    if (window.mapped and decoration.mapped) self.requestWindowChanged(decoration.window_id);
}

pub fn setDecorationOffset(self: *Self, id: DecorationId, offset: Position) void {
    const decoration = self.decorations.get(id) orelse return;
    if (std.meta.eql(decoration.offset, offset)) return;
    decoration.offset = offset;
    const window = self.windows.get(decoration.window_id) orelse return;
    if (window.mapped and decoration.mapped) self.requestWindowChanged(decoration.window_id);
}

pub fn setDecorationMapped(self: *Self, id: DecorationId, mapped: bool) void {
    const decoration = self.decorations.get(id) orelse return;
    if (decoration.mapped == mapped) return;
    decoration.mapped = mapped;
    const window = self.windows.get(decoration.window_id) orelse return;
    if (window.mapped) self.requestWindowChanged(decoration.window_id);
}

pub fn decorationCommitted(self: *Self, id: DecorationId) void {
    const decoration = self.decorations.get(id) orelse return;
    const window = self.windows.get(decoration.window_id) orelse return;
    if (window.mapped and decoration.mapped) self.requestWindowChanged(decoration.window_id);
}

pub fn setMapped(self: *Self, id: Id, mapped: bool) void {
    const window = self.windows.get(id) orelse return;
    if (window.mapped == mapped) return;
    window.mapped = mapped;
    self.requestRepaint();
}

pub fn surfaceCommitted(self: *Self, id: Id) void {
    const window = self.windows.get(id) orelse return;
    if (window.mapped) self.requestSurfaceChanged(window.surface_id);
}

pub fn setPosition(self: *Self, id: Id, position: Position) void {
    const window = self.windows.get(id) orelse return;
    if (std.meta.eql(window.position, position)) return;
    window.position = position;
    if (window.mapped) self.requestRepaint();
}

pub fn placeTop(self: *Self, id: Id) void {
    self.placeNodeTop(.{ .window = id });
}

pub fn placeBottom(self: *Self, id: Id) void {
    self.placeNodeBottom(.{ .window = id });
}

pub fn placeAbove(self: *Self, id: Id, other: Id) void {
    self.placeNodeAbove(.{ .window = id }, .{ .window = other });
}

pub fn placeBelow(self: *Self, id: Id, other: Id) void {
    self.placeNodeBelow(.{ .window = id }, .{ .window = other });
}

pub fn placeNodeTop(self: *Self, id: NodeId) void {
    const index = self.nodeIndex(id) orelse return;
    if (index == self.stack.items.len - 1) return;
    const moved = self.stack.orderedRemove(index);
    self.stack.appendAssumeCapacity(moved);
    self.requestStackRepaint(id);
}

pub fn placeNodeBottom(self: *Self, id: NodeId) void {
    const index = self.nodeIndex(id) orelse return;
    if (index == 0) return;
    const moved = self.stack.orderedRemove(index);
    self.stack.insertAssumeCapacity(0, moved);
    self.requestStackRepaint(id);
}

pub fn placeNodeAbove(self: *Self, id: NodeId, other: NodeId) void {
    if (std.meta.eql(id, other)) return;
    const index = self.nodeIndex(id) orelse return;
    const other_index_before = self.nodeIndex(other) orelse return;
    if (index == other_index_before + 1) return;
    const moved = self.stack.orderedRemove(index);
    const other_index = self.nodeIndex(other) orelse unreachable;
    self.stack.insertAssumeCapacity(other_index + 1, moved);
    self.requestStackRepaint(id);
}

pub fn placeNodeBelow(self: *Self, id: NodeId, other: NodeId) void {
    if (std.meta.eql(id, other)) return;
    const index = self.nodeIndex(id) orelse return;
    const other_index_before = self.nodeIndex(other) orelse return;
    if (index + 1 == other_index_before) return;
    const moved = self.stack.orderedRemove(index);
    const other_index = self.nodeIndex(other) orelse unreachable;
    self.stack.insertAssumeCapacity(other_index, moved);
    self.requestStackRepaint(id);
}

/// Defers repaint notification until a sequence of stack operations has
/// produced a final order different from the initial order.
pub fn beginStackUpdate(self: *Self) error{OutOfMemory}!void {
    std.debug.assert(!self.stack_update_active);
    std.debug.assert(self.stack_snapshot.items.len == 0);
    try self.stack_snapshot.resize(self.allocator, self.stack.items.len);
    @memcpy(self.stack_snapshot.items, self.stack.items);
    self.stack_update_active = true;
    self.stack_update_repaint = false;
}

pub fn endStackUpdate(self: *Self) void {
    std.debug.assert(self.stack_update_active);
    const changed = !nodeStacksEqual(self.stack_snapshot.items, self.stack.items);
    const repaint = self.stack_update_repaint;
    self.stack_snapshot.clearRetainingCapacity();
    self.stack_update_active = false;
    self.stack_update_repaint = false;
    if (changed and repaint) self.requestRepaint();
}

pub fn setFocused(self: *Self, id: Id, focused: bool) void {
    const window = self.windows.get(id) orelse return;
    if (window.focused == focused) return;
    window.focused = focused;
    if (window.mapped) self.requestRepaint();
}

pub fn setFullscreen(self: *Self, id: Id, fullscreen: bool) void {
    const window = self.windows.get(id) orelse return;
    if (window.fullscreen == fullscreen) return;
    window.fullscreen = fullscreen;
    if (window.mapped) self.requestRepaint();
}

pub fn setBorders(self: *Self, id: Id, borders: ?Borders) void {
    if (borders) |value| {
        std.debug.assert(value.width > 0);
        std.debug.assert(value.width <= std.math.maxInt(i32));
        std.debug.assert(@as(u8, @bitCast(value.edges)) & 0x0f != 0);
    }
    const window = self.windows.get(id) orelse return;
    if (std.meta.eql(window.borders, borders)) return;
    window.borders = borders;
    if (window.mapped) self.requestRepaint();
}

pub fn setClipBox(self: *Self, id: Id, clip_box: ?ClipBox) void {
    setWindowClipBox(self, id, clip_box, .window);
}

pub fn setShadowClipBox(self: *Self, id: Id, clip_box: ?ClipBox) void {
    setWindowClipBox(self, id, clip_box, .shadow);
}

pub fn setContentClipBox(self: *Self, id: Id, clip_box: ?ClipBox) void {
    setWindowClipBox(self, id, clip_box, .content);
}

pub fn setContentGeometry(self: *Self, id: Id, geometry: ?ContentGeometry) void {
    if (geometry) |value| {
        std.debug.assert(value.size.width > 0);
        std.debug.assert(value.size.height > 0);
        std.debug.assert(value.size.width <= std.math.maxInt(i32));
        std.debug.assert(value.size.height <= std.math.maxInt(i32));
    }
    const window = self.windows.get(id) orelse return;
    if (std.meta.eql(window.content_geometry, geometry)) return;
    window.content_geometry = geometry;
    if (window.mapped) self.requestRepaint();
}

pub fn setEffects(self: *Self, id: Id, effects: Effects) void {
    const window = self.windows.get(id) orelse return;
    if (std.meta.eql(window.effects, effects)) return;
    window.effects = effects;
    if (window.mapped) self.requestRepaint();
}

pub fn iterator(self: *Self) Iterator {
    return .{ .scene = self };
}

pub fn nodeIterator(self: *Self) NodeIterator {
    return .{ .scene = self };
}

pub fn reverseNodeIterator(self: *Self) ReverseNodeIterator {
    return .{ .scene = self, .index = self.stack.items.len };
}

pub fn layerSurfaceIterator(self: *Self, layer: Layer) LayerSurfaceIterator {
    return .{ .scene = self, .layer = layer };
}

pub fn reverseLayerSurfaceIterator(
    self: *Self,
    layer: Layer,
) ReverseLayerSurfaceIterator {
    return .{
        .scene = self,
        .layer = layer,
        .index = self.layer_stacks[layerIndex(layer)].items.len,
    };
}

pub fn decorationIterator(
    self: *Self,
    window_id: Id,
    layer: DecorationLayer,
) DecorationIterator {
    return .{
        .inner = self.decorations.iterator(),
        .window_id = window_id,
        .layer = layer,
    };
}

pub fn popupIterator(self: *Self, window_id: Id) PopupIterator {
    return .{ .scene = self, .window_id = window_id };
}

pub fn reversePopupIterator(self: *Self, window_id: Id) ReversePopupIterator {
    return .{
        .scene = self,
        .window_id = window_id,
        .index = self.popup_stack.items.len,
    };
}

pub fn layerPopupIterator(self: *Self, id: LayerSurfaceId) LayerPopupIterator {
    return .{ .scene = self, .layer_surface_id = id };
}

pub fn reverseLayerPopupIterator(self: *Self, id: LayerSurfaceId) ReverseLayerPopupIterator {
    return .{
        .scene = self,
        .layer_surface_id = id,
        .index = self.popup_stack.items.len,
    };
}

pub fn windowPosition(self: *Self, id: Id) ?Position {
    const window = self.windows.get(id) orelse return null;
    return window.position;
}

pub fn windowSurface(self: *Self, id: Id) ?Surface.Id {
    const window = self.windows.get(id) orelse return null;
    return window.surface_id;
}

pub fn layerSurface(self: *Self, id: LayerSurfaceId) ?*LayerSurface {
    return self.layer_surfaces.get(id);
}

pub fn popupPosition(self: *Self, id: PopupId) ?Position {
    return self.popupGlobalPosition(id);
}

pub fn surfacePosition(self: *Self, surface_id: Surface.Id) ?Position {
    var windows = self.windows.iterator();
    while (windows.next()) |entry| {
        if (!std.meta.eql(entry.value.surface_id, surface_id)) continue;
        const offset = if (entry.value.content_geometry) |geometry| geometry.offset else Position{};
        return .{
            .x = entry.value.position.x -| offset.x,
            .y = entry.value.position.y -| offset.y,
        };
    }
    var shell_surfaces = self.shell_surfaces.iterator();
    while (shell_surfaces.next()) |entry| {
        if (std.meta.eql(entry.value.surface_id, surface_id)) return entry.value.position;
    }
    var layer_surfaces = self.layer_surfaces.iterator();
    while (layer_surfaces.next()) |entry| {
        if (std.meta.eql(entry.value.surface_id, surface_id)) return entry.value.position;
    }
    var popups = self.popups.iterator();
    while (popups.next()) |entry| {
        if (!std.meta.eql(entry.value.surface_id, surface_id)) continue;
        var position = self.popupGlobalPosition(entry.id) orelse return null;
        if (entry.value.content_geometry) |geometry| {
            position.x -|= geometry.offset.x;
            position.y -|= geometry.offset.y;
        }
        return position;
    }
    return null;
}

pub fn surfaceMapped(self: *Self, surface_id: Surface.Id) bool {
    var windows = self.windows.iterator();
    while (windows.next()) |entry| {
        if (std.meta.eql(entry.value.surface_id, surface_id)) return entry.value.mapped;
    }
    var shell_surfaces = self.shell_surfaces.iterator();
    while (shell_surfaces.next()) |entry| {
        if (std.meta.eql(entry.value.surface_id, surface_id)) return entry.value.mapped;
    }
    var layer_surfaces = self.layer_surfaces.iterator();
    while (layer_surfaces.next()) |entry| {
        if (std.meta.eql(entry.value.surface_id, surface_id)) return entry.value.mapped;
    }
    var popups = self.popups.iterator();
    while (popups.next()) |entry| {
        if (std.meta.eql(entry.value.surface_id, surface_id)) return entry.value.mapped;
    }
    var decorations = self.decorations.iterator();
    while (decorations.next()) |entry| {
        if (!std.meta.eql(entry.value.surface_id, surface_id)) continue;
        const window = self.windows.get(entry.value.window_id) orelse return false;
        return entry.value.mapped and window.mapped;
    }
    return false;
}

/// Returns whether both roots are top-level scene nodes and the first is
/// painted above the second. Other surface categories have no node ordering.
pub fn surfaceNodeAbove(
    self: *Self,
    surface_id: Surface.Id,
    other_surface_id: Surface.Id,
) ?bool {
    const index = self.surfaceNodeIndex(surface_id) orelse return null;
    const other_index = self.surfaceNodeIndex(other_surface_id) orelse return null;
    return index > other_index;
}

pub fn topFullscreen(self: *Self) ?Id {
    var index = self.stack.items.len;
    while (index > 0) {
        index -= 1;
        const id = switch (self.stack.items[index]) {
            .window => |id| id,
            .shell_surface => continue,
        };
        const window = self.windows.get(id) orelse continue;
        if (window.mapped and window.fullscreen) return id;
    }
    return null;
}

pub fn focusedSurface(self: *Self) ?Surface.Id {
    var index = self.stack.items.len;
    while (index > 0) {
        index -= 1;
        const id = switch (self.stack.items[index]) {
            .window => |id| id,
            .shell_surface => continue,
        };
        const window = self.windows.get(id) orelse continue;
        if (window.mapped and window.focused) return window.surface_id;
    }
    return null;
}

pub fn topWindowSurface(self: *Self) ?Surface.Id {
    var index = self.stack.items.len;
    while (index > 0) {
        index -= 1;
        const id = switch (self.stack.items[index]) {
            .window => |id| id,
            .shell_surface => continue,
        };
        const window = self.windows.get(id) orelse continue;
        if (window.mapped) return window.surface_id;
    }
    return null;
}

fn requestRepaint(self: *Self) void {
    if (self.repaint_listener) |listener| listener.request(listener.context);
}

fn requestStackRepaint(self: *Self, id: NodeId) void {
    if (!self.nodeMapped(id)) return;
    if (self.stack_update_active) {
        self.stack_update_repaint = true;
    } else {
        self.requestRepaint();
    }
}

fn requestSurfaceChanged(self: *Self, surface_id: Surface.Id) void {
    if (self.repaint_listener) |listener| {
        listener.surface_changed(listener.context, surface_id);
    }
}

fn requestWindowChanged(self: *Self, id: Id) void {
    if (self.repaint_listener) |listener| listener.window_changed(listener.context, id);
}

fn layerIndex(layer: Layer) usize {
    return @intFromEnum(layer);
}

fn removeLayerSurfaceFromStack(
    self: *Self,
    id: LayerSurfaceId,
    layer: Layer,
) void {
    const stack = &self.layer_stacks[layerIndex(layer)];
    for (stack.items, 0..) |candidate, index| {
        if (!std.meta.eql(candidate, id)) continue;
        _ = stack.orderedRemove(index);
        return;
    }
    unreachable;
}

fn firstWindowPopup(self: *Self, window_id: Id) ?PopupId {
    for (self.popup_stack.items) |id| {
        const popup = self.popups.get(id) orelse continue;
        switch (popup.parent) {
            .window => |parent_id| if (std.meta.eql(parent_id, window_id)) return id,
            .layer_surface => {},
            .popup => {},
        }
    }
    return null;
}

fn firstLayerSurfacePopup(self: *Self, layer_surface_id: LayerSurfaceId) ?PopupId {
    for (self.popup_stack.items) |id| {
        const popup = self.popups.get(id) orelse continue;
        switch (popup.parent) {
            .layer_surface => |parent_id| if (std.meta.eql(parent_id, layer_surface_id)) return id,
            .window, .popup => {},
        }
    }
    return null;
}

fn firstChildPopup(self: *Self, popup_id: PopupId) ?PopupId {
    for (self.popup_stack.items) |id| {
        const popup = self.popups.get(id) orelse continue;
        switch (popup.parent) {
            .window, .layer_surface => {},
            .popup => |parent_id| if (std.meta.eql(parent_id, popup_id)) return id,
        }
    }
    return null;
}

fn popupRootWindow(self: *Self, id: PopupId) ?Id {
    var parent = (self.popups.get(id) orelse return null).parent;
    var remaining = self.popups.len() + 1;
    while (remaining > 0) : (remaining -= 1) switch (parent) {
        .window => |window_id| return if (self.windows.get(window_id) != null)
            window_id
        else
            null,
        .layer_surface => return null,
        .popup => |popup_id| parent = (self.popups.get(popup_id) orelse return null).parent,
    };
    return null;
}

fn popupRootLayerSurface(self: *Self, id: PopupId) ?LayerSurfaceId {
    var parent = (self.popups.get(id) orelse return null).parent;
    var remaining = self.popups.len() + 1;
    while (remaining > 0) : (remaining -= 1) switch (parent) {
        .layer_surface => |layer_id| return if (self.layer_surfaces.get(layer_id) != null)
            layer_id
        else
            null,
        .window => return null,
        .popup => |popup_id| parent = (self.popups.get(popup_id) orelse return null).parent,
    };
    return null;
}

fn popupGlobalPosition(self: *Self, id: PopupId) ?Position {
    const popup = self.popups.get(id) orelse return null;
    var position = popup.position;
    var parent = popup.parent;
    var remaining = self.popups.len() + 1;
    while (remaining > 0) : (remaining -= 1) switch (parent) {
        .window => |window_id| {
            const window = self.windows.get(window_id) orelse return null;
            position.x +|= window.position.x;
            position.y +|= window.position.y;
            return position;
        },
        .layer_surface => |layer_id| {
            const layer_surface = self.layer_surfaces.get(layer_id) orelse return null;
            position.x +|= layer_surface.position.x;
            position.y +|= layer_surface.position.y;
            return position;
        },
        .popup => |popup_id| {
            const parent_popup = self.popups.get(popup_id) orelse return null;
            position.x +|= parent_popup.position.x;
            position.y +|= parent_popup.position.y;
            parent = parent_popup.parent;
        },
    };
    return null;
}

fn setWindowClipBox(
    self: *Self,
    id: Id,
    clip_box: ?ClipBox,
    target: enum { window, shadow, content },
) void {
    if (clip_box) |box| {
        std.debug.assert(box.width > 0);
        std.debug.assert(box.height > 0);
        std.debug.assert(box.width <= std.math.maxInt(i32));
        std.debug.assert(box.height <= std.math.maxInt(i32));
    }
    const window = self.windows.get(id) orelse return;
    const destination = switch (target) {
        .window => &window.clip_box,
        .shadow => &window.shadow_clip_box,
        .content => &window.content_clip_box,
    };
    if (std.meta.eql(destination.*, clip_box)) return;
    destination.* = clip_box;
    if (window.mapped) self.requestRepaint();
}

fn nodeIndex(self: *Self, id: NodeId) ?usize {
    if (!self.nodeExists(id)) return null;
    for (self.stack.items, 0..) |candidate, index| {
        if (std.meta.eql(candidate, id)) return index;
    }
    unreachable;
}

fn nodeStacksEqual(first: []const NodeId, second: []const NodeId) bool {
    if (first.len != second.len) return false;
    for (first, second) |first_node, second_node| {
        if (!std.meta.eql(first_node, second_node)) return false;
    }
    return true;
}

fn surfaceNodeIndex(self: *Self, surface_id: Surface.Id) ?usize {
    for (self.stack.items, 0..) |node, index| {
        const node_surface_id = switch (node) {
            .window => |id| (self.windows.get(id) orelse continue).surface_id,
            .shell_surface => |id| (self.shell_surfaces.get(id) orelse continue).surface_id,
        };
        if (std.meta.eql(node_surface_id, surface_id)) return index;
    }
    return null;
}

fn nodeExists(self: *Self, id: NodeId) bool {
    return switch (id) {
        .window => |window_id| self.windows.get(window_id) != null,
        .shell_surface => |shell_id| self.shell_surfaces.get(shell_id) != null,
    };
}

fn nodeMapped(self: *Self, id: NodeId) bool {
    return switch (id) {
        .window => |window_id| if (self.windows.get(window_id)) |window|
            window.mapped
        else
            false,
        .shell_surface => |shell_id| if (self.shell_surfaces.get(shell_id)) |shell_surface|
            shell_surface.mapped
        else
            false,
    };
}

test "scene keeps visual state behind generational handles" {
    var scene: Self = undefined;
    scene.init(std.testing.allocator);
    defer scene.deinit();

    const surface_id: Surface.Id = .{ .index = 4, .generation = 2 };
    const id = try scene.addWindow(surface_id);
    scene.setPosition(id, .{ .x = 30, .y = 40 });
    scene.setFocused(id, true);
    scene.setFullscreen(id, true);
    scene.setEffects(id, .{ .corner_radius = 12 });
    scene.setBorders(id, .{
        .edges = .{ .top = true },
        .width = 4,
        .color = render.Color.rgba(0x80, 0x40, 0x20, 0xff),
    });
    scene.setClipBox(id, .{ .x = -4, .y = 2, .width = 80, .height = 60 });
    scene.setShadowClipBox(id, .{ .x = -12, .y = -8, .width = 96, .height = 76 });
    scene.setContentClipBox(id, .{ .x = 3, .y = 4, .width = 70, .height = 50 });
    scene.setContentGeometry(id, .{
        .offset = .{ .x = 2, .y = 3 },
        .size = .{ .width = 640, .height = 480 },
    });
    scene.setMapped(id, true);
    try std.testing.expectEqual(surface_id, scene.focusedSurface().?);
    try std.testing.expectEqual(surface_id, scene.topWindowSurface().?);

    var iterator_value = scene.iterator();
    const entry = iterator_value.next().?;
    try std.testing.expect(std.meta.eql(id, entry.id));
    try std.testing.expect(std.meta.eql(surface_id, entry.window.surface_id));
    try std.testing.expectEqual(Position{ .x = 30, .y = 40 }, entry.window.position);
    try std.testing.expect(entry.window.focused);
    try std.testing.expect(entry.window.fullscreen);
    try std.testing.expect(entry.window.mapped);
    try std.testing.expectEqual(@as(u32, 12), entry.window.effects.corner_radius);
    try std.testing.expectEqual(@as(u32, 4), entry.window.borders.?.width);
    try std.testing.expect(entry.window.borders.?.edges.top);
    try std.testing.expectEqual(ClipBox{
        .x = -4,
        .y = 2,
        .width = 80,
        .height = 60,
    }, entry.window.clip_box.?);
    try std.testing.expectEqual(ClipBox{
        .x = -12,
        .y = -8,
        .width = 96,
        .height = 76,
    }, entry.window.shadow_clip_box.?);
    try std.testing.expectEqual(ClipBox{
        .x = 3,
        .y = 4,
        .width = 70,
        .height = 50,
    }, entry.window.content_clip_box.?);
    try std.testing.expectEqual(ContentGeometry{
        .offset = .{ .x = 2, .y = 3 },
        .size = .{ .width = 640, .height = 480 },
    }, entry.window.content_geometry.?);
    try std.testing.expectEqual(@as(?Iterator.Entry, null), iterator_value.next());

    scene.removeWindow(id);
    try std.testing.expectEqual(@as(?*Window, null), scene.windows.get(id));
    try std.testing.expectEqual(@as(?Surface.Id, null), scene.focusedSurface());
    try std.testing.expectEqual(@as(?Surface.Id, null), scene.topWindowSurface());
}

test "scene reorders windows through handles" {
    var scene: Self = undefined;
    scene.init(std.testing.allocator);
    defer scene.deinit();

    const first = try scene.addWindow(.{ .index = 1, .generation = 1 });
    const second = try scene.addWindow(.{ .index = 2, .generation = 1 });
    const third = try scene.addWindow(.{ .index = 3, .generation = 1 });

    scene.setFullscreen(first, true);
    scene.setMapped(first, true);
    scene.setFullscreen(second, true);
    try std.testing.expectEqual(first, scene.topFullscreen().?);
    scene.setMapped(second, true);
    try std.testing.expectEqual(second, scene.topFullscreen().?);

    scene.placeTop(first);
    try std.testing.expectEqualSlices(NodeId, &.{
        .{ .window = second },
        .{ .window = third },
        .{ .window = first },
    }, scene.stack.items);
    try std.testing.expectEqual(first, scene.topFullscreen().?);
    scene.placeBelow(first, third);
    try std.testing.expectEqualSlices(NodeId, &.{
        .{ .window = second },
        .{ .window = first },
        .{ .window = third },
    }, scene.stack.items);
    try std.testing.expectEqual(first, scene.topFullscreen().?);
    scene.placeAbove(second, third);
    try std.testing.expectEqualSlices(NodeId, &.{
        .{ .window = first },
        .{ .window = third },
        .{ .window = second },
    }, scene.stack.items);
    try std.testing.expectEqual(second, scene.topFullscreen().?);
    scene.placeBottom(second);
    try std.testing.expectEqualSlices(NodeId, &.{
        .{ .window = second },
        .{ .window = first },
        .{ .window = third },
    }, scene.stack.items);
    try std.testing.expectEqual(first, scene.topFullscreen().?);

    scene.removeWindow(first);
    try std.testing.expectEqual(second, scene.topFullscreen().?);
    scene.removeWindow(second);
    try std.testing.expectEqual(@as(?Id, null), scene.topFullscreen());
    scene.removeWindow(third);
}

const RepaintCounter = struct {
    count: usize = 0,
    last_window: ?Id = null,

    fn listener(self: *RepaintCounter) RepaintListener {
        return .{
            .context = self,
            .request = request,
            .surface_changed = surfaceChanged,
            .window_changed = windowChanged,
        };
    }

    fn request(context: *anyopaque) void {
        const self: *RepaintCounter = @ptrCast(@alignCast(context));
        self.count += 1;
    }

    fn surfaceChanged(_: *anyopaque, _: Surface.Id) void {}

    fn windowChanged(context: *anyopaque, id: Id) void {
        const self: *RepaintCounter = @ptrCast(@alignCast(context));
        self.count += 1;
        self.last_window = id;
    }
};

test "scene stack updates only repaint for a different final order" {
    var scene: Self = undefined;
    scene.init(std.testing.allocator);
    defer scene.deinit();

    const first = try scene.addWindow(.{ .index = 1, .generation = 1 });
    const second = try scene.addWindow(.{ .index = 2, .generation = 1 });
    const third = try scene.addWindow(.{ .index = 3, .generation = 1 });
    scene.setMapped(first, true);
    scene.setMapped(second, true);
    scene.setMapped(third, true);
    var repaint: RepaintCounter = .{};
    scene.setRepaintListener(repaint.listener());
    defer scene.clearRepaintListener();

    try scene.beginStackUpdate();
    scene.placeTop(first);
    scene.placeTop(second);
    scene.placeTop(third);
    scene.endStackUpdate();
    try std.testing.expectEqual(@as(usize, 0), repaint.count);

    try scene.beginStackUpdate();
    scene.placeTop(first);
    scene.endStackUpdate();
    try std.testing.expectEqual(@as(usize, 1), repaint.count);

    scene.placeAbove(first, third);
    scene.placeBelow(third, first);
    try std.testing.expectEqual(@as(usize, 1), repaint.count);

    scene.removeWindow(first);
    scene.removeWindow(second);
    scene.removeWindow(third);
}

test "scene interleaves shell surfaces and windows through node handles" {
    var scene: Self = undefined;
    scene.init(std.testing.allocator);
    defer scene.deinit();

    const window_surface: Surface.Id = .{ .index = 1, .generation = 1 };
    const shell_surface_root: Surface.Id = .{ .index = 2, .generation = 1 };
    const window = try scene.addWindow(window_surface);
    const shell_surface = try scene.addShellSurface(shell_surface_root);
    scene.setMapped(window, true);
    scene.setShellSurfaceMapped(shell_surface, true);
    scene.setShellSurfacePosition(shell_surface, .{ .x = 20, .y = 30 });
    scene.placeNodeBelow(.{ .shell_surface = shell_surface }, .{ .window = window });

    try std.testing.expectEqualSlices(NodeId, &.{
        .{ .shell_surface = shell_surface },
        .{ .window = window },
    }, scene.stack.items);

    var nodes = scene.nodeIterator();
    const shell_entry = nodes.next().?.shell_surface;
    try std.testing.expect(std.meta.eql(shell_surface, shell_entry.id));
    try std.testing.expectEqual(Position{ .x = 20, .y = 30 }, shell_entry.shell_surface.position);
    const window_entry = nodes.next().?.window;
    try std.testing.expect(std.meta.eql(window, window_entry.id));
    try std.testing.expectEqual(@as(?NodeIterator.Entry, null), nodes.next());

    var reverse_nodes = scene.reverseNodeIterator();
    try std.testing.expect(std.meta.eql(window, reverse_nodes.next().?.window.id));
    try std.testing.expect(std.meta.eql(shell_surface, reverse_nodes.next().?.shell_surface.id));
    try std.testing.expectEqual(@as(?NodeIterator.Entry, null), reverse_nodes.next());
    try std.testing.expect(scene.surfaceNodeAbove(window_surface, shell_surface_root).?);
    try std.testing.expect(!scene.surfaceNodeAbove(shell_surface_root, window_surface).?);
    try std.testing.expectEqual(
        @as(?bool, null),
        scene.surfaceNodeAbove(window_surface, .{ .index = 3, .generation = 1 }),
    );

    scene.removeShellSurface(shell_surface);
    scene.removeWindow(window);
}

test "scene keeps layer surfaces in fixed independent stacks" {
    var scene: Self = undefined;
    scene.init(std.testing.allocator);
    defer scene.deinit();

    const background = try scene.addLayerSurface(
        .{ .index = 1, .generation = 1 },
        .background,
    );
    const first_top = try scene.addLayerSurface(
        .{ .index = 2, .generation = 1 },
        .top,
    );
    const second_top = try scene.addLayerSurface(
        .{ .index = 3, .generation = 1 },
        .top,
    );
    scene.setLayerSurfacePosition(first_top, .{ .x = 20, .y = 30 });
    scene.setLayerSurfaceMapped(first_top, true);

    var top = scene.layerSurfaceIterator(.top);
    const first = top.next().?;
    try std.testing.expect(std.meta.eql(first_top, first.id));
    try std.testing.expectEqual(Position{ .x = 20, .y = 30 }, first.layer_surface.position);
    try std.testing.expect(first.layer_surface.mapped);
    try std.testing.expect(std.meta.eql(second_top, top.next().?.id));
    try std.testing.expectEqual(@as(?LayerSurfaceIterator.Entry, null), top.next());

    var reverse_top = scene.reverseLayerSurfaceIterator(.top);
    try std.testing.expect(std.meta.eql(second_top, reverse_top.next().?.id));
    try std.testing.expect(std.meta.eql(first_top, reverse_top.next().?.id));
    try std.testing.expectEqual(
        @as(?LayerSurfaceIterator.Entry, null),
        reverse_top.next(),
    );

    try scene.setLayerSurfaceLayer(first_top, .overlay);
    try std.testing.expectEqual(@as(usize, 1), scene.layer_stacks[layerIndex(.top)].items.len);
    try std.testing.expectEqual(@as(usize, 1), scene.layer_stacks[layerIndex(.overlay)].items.len);

    scene.removeLayerSurface(background);
    scene.removeLayerSurface(first_top);
    scene.removeLayerSurface(second_top);
}

test "scene attaches decoration handles to windows" {
    var scene: Self = undefined;
    scene.init(std.testing.allocator);
    defer scene.deinit();

    const window = try scene.addWindow(.{ .index = 1, .generation = 1 });
    const below = try scene.addDecoration(
        window,
        .{ .index = 2, .generation = 1 },
        .below,
    );
    const above = try scene.addDecoration(
        window,
        .{ .index = 3, .generation = 1 },
        .above,
    );
    scene.setDecorationOffset(above, .{ .x = -12, .y = 8 });
    scene.setDecorationMapped(above, true);

    var below_iterator = scene.decorationIterator(window, .below);
    const below_entry = below_iterator.next().?;
    try std.testing.expect(std.meta.eql(below, below_entry.id));
    try std.testing.expectEqual(DecorationLayer.below, below_entry.decoration.layer);
    try std.testing.expectEqual(@as(?DecorationIterator.Entry, null), below_iterator.next());

    var above_iterator = scene.decorationIterator(window, .above);
    const above_entry = above_iterator.next().?;
    try std.testing.expect(std.meta.eql(above, above_entry.id));
    try std.testing.expectEqual(Position{ .x = -12, .y = 8 }, above_entry.decoration.offset);
    try std.testing.expect(above_entry.decoration.mapped);
    try std.testing.expectEqual(@as(?DecorationIterator.Entry, null), above_iterator.next());

    scene.removeDecoration(below);
    scene.removeWindow(window);
    try std.testing.expectEqual(@as(?Decoration, null), scene.decorations.remove(above));
}

test "scene reports visible decoration changes with their owning window" {
    var scene: Self = undefined;
    scene.init(std.testing.allocator);
    defer scene.deinit();

    const window = try scene.addWindow(.{ .index = 1, .generation = 1 });
    const decoration = try scene.addDecoration(
        window,
        .{ .index = 2, .generation = 1 },
        .above,
    );
    scene.setMapped(window, true);
    var repaint: RepaintCounter = .{};
    scene.setRepaintListener(repaint.listener());
    defer scene.clearRepaintListener();

    scene.setDecorationOffset(decoration, .{ .x = 4 });
    try std.testing.expectEqual(@as(usize, 0), repaint.count);
    scene.setDecorationMapped(decoration, true);
    scene.setDecorationOffset(decoration, .{ .x = 8 });
    scene.decorationCommitted(decoration);
    scene.removeDecoration(decoration);
    try std.testing.expectEqual(@as(usize, 4), repaint.count);
    try std.testing.expect(std.meta.eql(window, repaint.last_window.?));

    scene.removeWindow(window);
}

test "scene keeps nested popups relative to their root window" {
    var scene: Self = undefined;
    scene.init(std.testing.allocator);
    defer scene.deinit();

    const window = try scene.addWindow(.{ .index = 1, .generation = 1 });
    scene.setPosition(window, .{ .x = 100, .y = 50 });
    const parent = try scene.addPopup(
        .{ .index = 2, .generation = 1 },
        .{ .window = window },
    );
    scene.setPopupPosition(parent, .{ .x = 10, .y = 20 });
    scene.setPopupMapped(parent, true);
    const child = try scene.addPopup(
        .{ .index = 3, .generation = 1 },
        .{ .popup = parent },
    );
    scene.setPopupPosition(child, .{ .x = 5, .y = -3 });
    scene.setPopupMapped(child, true);

    var popups = scene.popupIterator(window);
    const parent_entry = popups.next().?;
    try std.testing.expect(std.meta.eql(parent, parent_entry.id));
    try std.testing.expectEqual(Position{ .x = 110, .y = 70 }, parent_entry.position);
    const child_entry = popups.next().?;
    try std.testing.expect(std.meta.eql(child, child_entry.id));
    try std.testing.expectEqual(Position{ .x = 115, .y = 67 }, child_entry.position);
    try std.testing.expectEqual(@as(?PopupIterator.Entry, null), popups.next());

    var reverse = scene.reversePopupIterator(window);
    try std.testing.expect(std.meta.eql(child, reverse.next().?.id));
    try std.testing.expect(std.meta.eql(parent, reverse.next().?.id));
    try std.testing.expectEqual(@as(?PopupIterator.Entry, null), reverse.next());

    scene.removeWindow(window);
    try std.testing.expectEqual(@as(usize, 0), scene.popups.len());
    try std.testing.expectEqual(@as(usize, 0), scene.popup_stack.items.len);
}

test "scene keeps and removes popups rooted at a layer surface" {
    var scene: Self = undefined;
    scene.init(std.testing.allocator);
    defer scene.deinit();

    const root = try scene.addLayerSurface(
        .{ .index = 1, .generation = 1 },
        .overlay,
    );
    scene.setLayerSurfacePosition(root, .{ .x = 40, .y = 70 });
    const parent = try scene.addPopup(
        .{ .index = 2, .generation = 1 },
        .{ .layer_surface = root },
    );
    scene.setPopupPosition(parent, .{ .x = 8, .y = 9 });
    const child = try scene.addPopup(
        .{ .index = 3, .generation = 1 },
        .{ .popup = parent },
    );
    scene.setPopupPosition(child, .{ .x = -2, .y = 4 });

    var popups = scene.layerPopupIterator(root);
    try std.testing.expectEqual(Position{ .x = 48, .y = 79 }, popups.next().?.position);
    try std.testing.expectEqual(Position{ .x = 46, .y = 83 }, popups.next().?.position);
    try std.testing.expectEqual(@as(?PopupIterator.Entry, null), popups.next());

    var reverse = scene.reverseLayerPopupIterator(root);
    try std.testing.expect(std.meta.eql(child, reverse.next().?.id));
    try std.testing.expect(std.meta.eql(parent, reverse.next().?.id));
    try std.testing.expectEqual(@as(?PopupIterator.Entry, null), reverse.next());

    scene.removeLayerSurface(root);
    try std.testing.expectEqual(@as(usize, 0), scene.popups.len());
    try std.testing.expectEqual(@as(usize, 0), scene.popup_stack.items.len);
}
