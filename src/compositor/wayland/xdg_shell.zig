//! xdg-shell globals and toplevel protocol state.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const render = @import("../render/types.zig");
const Scene = @import("../scene.zig");
const Seat = @import("seat.zig");
const slot_map = @import("../slot_map.zig");
const Surface = @import("surface.zig");
const Subcompositor = @import("subcompositor.zig");
const OutputLayout = @import("output_layout.zig");
const GtkShell = @import("gtk_shell.zig");

const wl = wayland.server.wl;
const xdg = wayland.server.xdg;
const zxdg = wayland.server.zxdg;

allocator: std.mem.Allocator,
display: *wl.Server,
surface_store: *Surface.Store,
subcompositor: *Subcompositor,
scene: *Scene,
seat: *Seat,
outputs: *OutputLayout,
default_output_id: OutputLayout.Id,
gtk_shell: *GtkShell,
global: *wl.Global,
decoration_global: *wl.Global,
bindings: BindingStore,
xdg_surfaces: XdgSurfaceStore,
windows: WindowStore,
popups: PopupStore,
next_popup_order: u64,
window_listener: ?WindowListener,
window_observers: std.ArrayList(WindowObserver),

const BindingStore = slot_map.SlotMap(BindingState, enum { xdg_binding });
const BindingId = BindingStore.Id;

const XdgSurfaceStore = slot_map.SlotMap(XdgSurfaceState, enum { xdg_surface });
const XdgSurfaceId = XdgSurfaceStore.Id;

pub const WindowStore = slot_map.SlotMap(WindowState, enum { window });
pub const WindowId = WindowStore.Id;
const PopupStore = slot_map.SlotMap(PopupState, enum { popup });
const PopupId = PopupStore.Id;

const BindingState = struct {
    surface_count: usize = 0,
};

const Geometry = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

const XdgRole = union(enum) {
    toplevel: WindowId,
    popup: PopupId,
};

const PositionerRules = struct {
    size: ?Dimensions = null,
    anchor_rect: ?Geometry = null,
    anchor: xdg.Positioner.Anchor = .none,
    gravity: xdg.Positioner.Gravity = .none,
    adjustment: xdg.Positioner.ConstraintAdjustment = .{},
    offset: Scene.Position = .{},
    reactive: bool = false,
    parent_size: ?Dimensions = null,
    parent_configure: ?u32 = null,

    fn complete(self: PositionerRules) bool {
        const size = self.size orelse return false;
        const anchor_rect = self.anchor_rect orelse return false;
        return size.width > 0 and size.height > 0 and
            anchor_rect.width > 0 and anchor_rect.height > 0;
    }
};

const PopupPlacement = struct {
    position: Scene.Position,
    dimensions: Dimensions,
};

const PendingPopupConfigure = struct {
    serial: u32,
    rules: PositionerRules,
    placement: PopupPlacement,
};

pub const SizeHint = struct {
    width: i32 = 0,
    height: i32 = 0,
};

pub const WindowRequestState = struct {
    maximized: bool = false,
    fullscreen: bool = false,
    fullscreen_output: ?OutputLayout.Id = null,
    minimized: bool = false,
};

const XdgSurfaceState = struct {
    surface_id: Surface.Id,
    role: ?XdgRole = null,
    pending_geometry: ?Geometry = null,
    pending_geometry_changed: bool = false,
    current_geometry: ?Geometry = null,
    configure_serials: std.ArrayList(u32) = .empty,
    last_acked_serial: ?u32 = null,
    initial_configure_sent: bool = false,
    configured: bool = false,
    sent_capabilities: ?WindowCapabilities = null,
    sent_bounds: ?Dimensions = null,
    mapped: bool = false,
    surface_alive: bool = true,
    toplevel_resource: ?*xdg.Toplevel = null,

    fn deinit(self: *XdgSurfaceState, allocator: std.mem.Allocator) void {
        self.configure_serials.deinit(allocator);
        self.* = undefined;
    }
};

const PopupState = struct {
    xdg_surface_id: XdgSurfaceId,
    parent: PopupParent,
    scene_id: ?Scene.PopupId,
    resource: *xdg.Popup,
    rules: PositionerRules,
    pending_configure: ?PendingPopupConfigure = null,
    ready: bool = false,
    mapped: bool = false,
    grabbed: bool = false,
    dismissed: bool = false,
    order: u64,
};

const PopupParent = union(enum) {
    unattached,
    xdg_surface: XdgSurfaceId,
    layer_surface: Scene.LayerSurfaceId,
};

pub const WindowState = struct {
    xdg_surface_id: XdgSurfaceId,
    scene_id: Scene.Id,
    unreliable_pid: i32,
    parent: ?WindowId = null,
    parent_owner: ?*anyopaque = null,
    title: ?[:0]u8 = null,
    app_id: ?[:0]u8 = null,
    tag: ?[:0]u8 = null,
    description: ?[:0]u8 = null,
    icon: ?ToplevelIcon = null,
    pending_icon: ?ToplevelIcon = null,
    pending_icon_changed: bool = false,
    dialog: bool = false,
    modal: bool = false,
    pending_min_size: SizeHint = .{},
    pending_max_size: SizeHint = .{},
    current_min_size: SizeHint = .{},
    current_max_size: SizeHint = .{},
    decoration_preference: DecorationPreference = .only_csd,
    decoration_configure_requested: bool = false,
    configuration: ToplevelConfigure = .{},
    committed_dimensions: ?Dimensions = null,
    mapped: bool = false,
    ready: bool = false,
    requested_state: WindowRequestState = .{},

    fn deinit(self: *WindowState, allocator: std.mem.Allocator) void {
        if (self.title) |title| allocator.free(title);
        if (self.app_id) |app_id| allocator.free(app_id);
        if (self.tag) |tag| allocator.free(tag);
        if (self.description) |description| allocator.free(description);
        if (self.icon) |*icon| icon.deinit(allocator);
        if (self.pending_icon) |*icon| icon.deinit(allocator);
        self.* = undefined;
    }

    fn commit(self: *WindowState, allocator: std.mem.Allocator) bool {
        var changed = !std.meta.eql(self.current_min_size, self.pending_min_size) or
            !std.meta.eql(self.current_max_size, self.pending_max_size);
        self.current_min_size = self.pending_min_size;
        self.current_max_size = self.pending_max_size;
        if (self.pending_icon_changed) {
            if (self.icon) |*icon| icon.deinit(allocator);
            self.icon = self.pending_icon;
            self.pending_icon = null;
            self.pending_icon_changed = false;
            changed = true;
        }
        return changed;
    }

    fn reset(self: *WindowState, allocator: std.mem.Allocator) void {
        if (self.title) |title| allocator.free(title);
        if (self.app_id) |app_id| allocator.free(app_id);
        self.title = null;
        self.app_id = null;
        self.parent = null;
        self.parent_owner = null;
        self.pending_min_size = .{};
        self.pending_max_size = .{};
        self.current_min_size = .{};
        self.current_max_size = .{};
        self.configuration = .{};
        self.committed_dimensions = null;
        self.mapped = false;
        self.ready = false;
        self.requested_state = .{};
    }

    fn requestMaximized(self: *WindowState, maximized: bool) void {
        self.requested_state.maximized = maximized;
    }

    fn requestFullscreen(self: *WindowState, fullscreen: bool, output: ?OutputLayout.Id) void {
        self.requested_state.fullscreen = fullscreen;
        self.requested_state.fullscreen_output = if (fullscreen) output else null;
    }

    fn requestMinimized(self: *WindowState, minimized: bool) void {
        self.requested_state.minimized = minimized;
    }
};

pub const Dimensions = struct {
    width: i32,
    height: i32,
};

pub const ToplevelIconBuffer = struct {
    size: u32,
    scale: i32,
    format: u32,
    stride: u32,
    data: []u8,
};

pub const ToplevelIcon = struct {
    name: ?[:0]u8,
    buffers: []ToplevelIconBuffer,

    pub fn deinit(self: *ToplevelIcon, allocator: std.mem.Allocator) void {
        if (self.name) |name| allocator.free(name);
        for (self.buffers) |buffer| allocator.free(buffer.data);
        allocator.free(self.buffers);
        self.* = undefined;
    }
};

pub const ToplevelIconInfo = struct {
    name: ?[:0]const u8,
    buffers: []const ToplevelIconBuffer,
};

fn windowCommitNeedsNotification(
    was_mapped: bool,
    configure_serial: ?u32,
    previous_dimensions: ?Dimensions,
    dimensions: Dimensions,
) bool {
    return !was_mapped or configure_serial != null or previous_dimensions == null or
        !std.meta.eql(previous_dimensions.?, dimensions);
}

pub const TiledEdges = packed struct(u8) {
    top: bool = false,
    bottom: bool = false,
    left: bool = false,
    right: bool = false,
    _padding: u4 = 0,
};

pub const ConstrainedEdges = packed struct(u8) {
    top: bool = false,
    bottom: bool = false,
    left: bool = false,
    right: bool = false,
    _padding: u4 = 0,
};

pub const WindowCapabilities = packed struct(u8) {
    window_menu: bool = true,
    maximize: bool = true,
    fullscreen: bool = true,
    minimize: bool = true,
    _padding: u4 = 0,
};

pub const ToplevelConfigure = struct {
    activated: bool = false,
    maximized: bool = false,
    fullscreen: bool = false,
    resizing: bool = false,
    tiled: TiledEdges = .{},
    capabilities: WindowCapabilities = .{},
    decoration_mode: DecorationMode = .client_side,
    bounds: Dimensions = .{ .width = 0, .height = 0 },
    suspended: bool = false,
    constrained: ConstrainedEdges = .{},
};

pub const DecorationMode = enum {
    client_side,
    server_side,
};

pub const DecorationPreference = enum {
    only_csd,
    prefers_csd,
    prefers_ssd,
    no_preference,
};

pub const ResizeEdges = packed struct(u4) {
    top: bool = false,
    bottom: bool = false,
    left: bool = false,
    right: bool = false,
};

pub const WindowRequest = union(enum) {
    pointer_move,
    pointer_resize: ResizeEdges,
    show_window_menu: struct {
        x: i32,
        y: i32,
    },
    maximize,
    unmaximize,
    fullscreen: ?*wl.Output,
    exit_fullscreen,
    minimize,
    unminimize,
    activate: *Seat,
};

pub const WindowInfo = struct {
    scene_id: Scene.Id,
    unreliable_pid: i32,
    title: ?[:0]const u8,
    app_id: ?[:0]const u8,
    tag: ?[:0]const u8,
    description: ?[:0]const u8,
    icon: ?ToplevelIconInfo,
    dialog: bool,
    modal: bool,
    parent: ?WindowId,
    min_size: SizeHint,
    max_size: SizeHint,
    decoration_preference: DecorationPreference,
    decoration_configure_requested: bool,
    configuration: ToplevelConfigure,
    dimensions: ?Dimensions,
    ready: bool,
    mapped: bool,
    requested_state: WindowRequestState,
};

pub const WindowListener = struct {
    context: *anyopaque,
    ready: *const fn (*anyopaque, WindowId) bool,
    committed: *const fn (*anyopaque, WindowId, ?u32) bool,
    unmapping: *const fn (*anyopaque, WindowId) void,
    unmapped: *const fn (*anyopaque, WindowId) void,
    destroyed: *const fn (*anyopaque, WindowId) void,
    metadata_changed: *const fn (*anyopaque, WindowId) bool,
    request: *const fn (*anyopaque, WindowId, WindowRequest) void,
};

pub const WindowObserver = struct {
    context: *anyopaque,
    committed: *const fn (*anyopaque, WindowId) void,
    unmapped: *const fn (*anyopaque, WindowId) void,
    destroyed: *const fn (*anyopaque, WindowId) void,
    metadata_changed: *const fn (*anyopaque, WindowId) void,
    state_changed: *const fn (*anyopaque, WindowId) void,
};

pub const WindowIterator = struct {
    inner: WindowStore.Iterator,

    pub fn next(self: *WindowIterator) ?WindowId {
        const entry = self.inner.next() orelse return null;
        return entry.id;
    }
};

pub const ToplevelInfo = struct {
    window_id: WindowId,
    surface_resource: *wl.Surface,
    xdg_surface_resource: *xdg.Surface,
    resource: *xdg.Toplevel,
};

pub const ForeignParentError = error{ InvalidSurface, InvalidParent };

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    surface_store: *Surface.Store,
    subcompositor: *Subcompositor,
    scene: *Scene,
    seat: *Seat,
    outputs: *OutputLayout,
    default_output_id: OutputLayout.Id,
    gtk_shell: *GtkShell,
) !void {
    self.* = .{
        .allocator = allocator,
        .display = display,
        .surface_store = surface_store,
        .subcompositor = subcompositor,
        .scene = scene,
        .seat = seat,
        .outputs = outputs,
        .default_output_id = default_output_id,
        .gtk_shell = gtk_shell,
        .global = undefined,
        .decoration_global = undefined,
        .bindings = .{},
        .xdg_surfaces = .{},
        .windows = .{},
        .popups = .{},
        .next_popup_order = 0,
        .window_listener = null,
        .window_observers = .empty,
    };
    errdefer self.bindings.deinit(allocator);
    errdefer self.xdg_surfaces.deinit(allocator);
    errdefer self.windows.deinit(allocator);
    errdefer self.popups.deinit(allocator);
    errdefer self.window_observers.deinit(allocator);
    self.global = try wl.Global.create(display, xdg.WmBase, 7, *Self, self, bind);
    errdefer self.global.destroy();
    self.decoration_global = try wl.Global.create(
        display,
        zxdg.DecorationManagerV1,
        2,
        *Self,
        self,
        bindDecorationManager,
    );
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.window_listener == null);
    std.debug.assert(self.window_observers.items.len == 0);
    self.decoration_global.destroy();
    self.global.destroy();
    self.bindings.deinit(self.allocator);
    self.xdg_surfaces.deinit(self.allocator);
    self.windows.deinit(self.allocator);
    self.popups.deinit(self.allocator);
    self.window_observers.deinit(self.allocator);
    self.* = undefined;
}

pub fn setDefaultOutput(self: *Self, output_id: OutputLayout.Id) void {
    std.debug.assert(self.outputs.get(output_id) != null);
    self.default_output_id = output_id;
}

pub fn setWindowListener(self: *Self, listener: WindowListener) void {
    std.debug.assert(self.window_listener == null);
    self.window_listener = listener;
}

pub fn clearWindowListener(self: *Self) void {
    std.debug.assert(self.window_listener != null);
    self.window_listener = null;
}

pub fn addWindowObserver(self: *Self, observer: WindowObserver) error{OutOfMemory}!void {
    for (self.window_observers.items) |existing| {
        std.debug.assert(existing.context != observer.context);
    }
    try self.window_observers.append(self.allocator, observer);
}

pub fn removeWindowObserver(self: *Self, context: *anyopaque) void {
    for (self.window_observers.items, 0..) |observer, index| {
        if (observer.context != context) continue;
        _ = self.window_observers.orderedRemove(index);
        return;
    }
    unreachable;
}

pub fn windowIterator(self: *Self) WindowIterator {
    return .{ .inner = self.windows.iterator() };
}

pub fn windowInfo(self: *Self, id: WindowId) ?WindowInfo {
    const window = self.windows.get(id) orelse return null;
    const xdg_surface = self.xdg_surfaces.get(window.xdg_surface_id) orelse return null;
    const dimensions: ?Dimensions = if (self.contentGeometry(xdg_surface)) |geometry|
        .{
            .width = @intCast(geometry.size.width),
            .height = @intCast(geometry.size.height),
        }
    else
        null;
    return .{
        .scene_id = window.scene_id,
        .unreliable_pid = window.unreliable_pid,
        .title = window.title,
        .app_id = window.app_id,
        .tag = window.tag,
        .description = window.description,
        .icon = if (window.icon) |*icon| .{
            .name = icon.name,
            .buffers = icon.buffers,
        } else null,
        .dialog = window.dialog,
        .modal = window.modal,
        .parent = window.parent,
        .min_size = window.current_min_size,
        .max_size = window.current_max_size,
        .decoration_preference = window.decoration_preference,
        .decoration_configure_requested = window.decoration_configure_requested,
        .configuration = window.configuration,
        .dimensions = dimensions,
        .ready = window.ready,
        .mapped = window.mapped,
        .requested_state = window.requested_state,
    };
}

pub fn windowSurface(self: *Self, id: WindowId) ?Surface.Id {
    const window = self.windows.get(id) orelse return null;
    const xdg_surface = self.xdg_surfaces.get(window.xdg_surface_id) orelse return null;
    return xdg_surface.surface_id;
}

pub fn requestWindow(self: *Self, id: WindowId, request: WindowRequest) void {
    if (self.windows.get(id) == null) return;
    if (self.window_listener) |listener| listener.request(listener.context, id, request);
}

pub fn setPendingToplevelIcon(self: *Self, id: WindowId, icon: ?ToplevelIcon) void {
    const window = self.windows.get(id) orelse unreachable;
    if (window.pending_icon) |*pending| pending.deinit(self.allocator);
    window.pending_icon = icon;
    window.pending_icon_changed = true;
}

pub fn setDialogState(self: *Self, id: WindowId, dialog: bool, modal: bool) void {
    std.debug.assert(dialog or !modal);
    const window = self.windows.get(id) orelse return;
    if (window.dialog == dialog and window.modal == modal) return;
    window.dialog = dialog;
    window.modal = modal;
    _ = self.notifyWindowMetadataChanged(id);
}

pub const ToplevelTagField = enum { tag, description };

pub fn setToplevelTag(
    self: *Self,
    id: WindowId,
    field: ToplevelTagField,
    value: []const u8,
) error{OutOfMemory}!void {
    const window = self.windows.get(id) orelse return;
    const destination = switch (field) {
        .tag => &window.tag,
        .description => &window.description,
    };
    const copy = try self.allocator.dupeSentinel(u8, value, 0);
    if (destination.*) |previous| self.allocator.free(previous);
    destination.* = copy;
    _ = self.notifyWindowMetadataChanged(id);
}

pub const AttachPopupError = error{
    ForeignResource,
    AlreadyAttached,
    InvalidLayerSurface,
    OutOfMemory,
};

/// The layer-surface owner must dismiss these popups before unmapping or
/// removing their parent.
pub fn attachPopup(
    self: *Self,
    resource: *xdg.Popup,
    layer_surface_id: Scene.LayerSurfaceId,
) AttachPopupError!void {
    const data = resource.getUserData() orelse return error.ForeignResource;
    const adapter: *PopupResource = @ptrCast(@alignCast(data));
    if (adapter.shell != self) return error.ForeignResource;
    const popup = self.popups.get(adapter.id) orelse return error.ForeignResource;
    if (popup.parent != .unattached) return error.AlreadyAttached;
    const xdg_surface = self.xdg_surfaces.get(popup.xdg_surface_id) orelse
        return error.ForeignResource;
    const scene_id = self.scene.addPopup(
        xdg_surface.surface_id,
        .{ .layer_surface = layer_surface_id },
    ) catch |err| switch (err) {
        error.InvalidParent => return error.InvalidLayerSurface,
        error.OutOfMemory => return error.OutOfMemory,
    };
    popup.parent = .{ .layer_surface = layer_surface_id };
    popup.scene_id = scene_id;
}

pub fn dismissLayerSurfacePopups(self: *Self, layer_surface_id: Scene.LayerSurfaceId) void {
    while (true) {
        var root: ?PopupId = null;
        var iterator = self.popups.iterator();
        while (iterator.next()) |entry| {
            if (entry.value.dismissed) continue;
            switch (entry.value.parent) {
                .layer_surface => |id| if (std.meta.eql(id, layer_surface_id)) {
                    root = entry.id;
                    break;
                },
                .unattached, .xdg_surface => {},
            }
        }
        self.dismissPopup(root orelse return);
    }
}

fn contentGeometry(self: *Self, state: *const XdgSurfaceState) ?Scene.ContentGeometry {
    if (state.current_geometry) |geometry| {
        return .{
            .offset = .{ .x = geometry.x, .y = geometry.y },
            .size = .{
                .width = @intCast(geometry.width),
                .height = @intCast(geometry.height),
            },
        };
    }
    const bounds = self.subcompositor.treeBounds(state.surface_id) orelse return null;
    return .{
        .offset = .{ .x = bounds.x, .y = bounds.y },
        .size = .{ .width = bounds.width, .height = bounds.height },
    };
}

fn effectiveGeometry(self: *Self, surface_id: Surface.Id, requested: Geometry) Geometry {
    const bounds = self.subcompositor.treeBounds(surface_id) orelse return requested;
    const left = @max(@as(i64, requested.x), @as(i64, bounds.x));
    const top = @max(@as(i64, requested.y), @as(i64, bounds.y));
    const right = @min(
        @as(i64, requested.x) + requested.width,
        @as(i64, bounds.x) + bounds.width,
    );
    const bottom = @min(
        @as(i64, requested.y) + requested.height,
        @as(i64, bounds.y) + bounds.height,
    );
    if (right <= left or bottom <= top) return requested;
    return .{
        .x = @intCast(left),
        .y = @intCast(top),
        .width = @intCast(right - left),
        .height = @intCast(bottom - top),
    };
}

fn appendEnum(values: anytype, count: *usize, value: anytype) void {
    std.debug.assert(count.* < values.len);
    values[count.*] = @intCast(@intFromEnum(value));
    count.* += 1;
}

fn toplevelStates(
    configuration: ToplevelConfigure,
    version: u32,
    values: *[13]u32,
) []u32 {
    var count: usize = 0;
    if (configuration.maximized) appendEnum(values, &count, xdg.Toplevel.State.maximized);
    if (configuration.fullscreen) appendEnum(values, &count, xdg.Toplevel.State.fullscreen);
    if (configuration.resizing) appendEnum(values, &count, xdg.Toplevel.State.resizing);
    if (configuration.activated) appendEnum(values, &count, xdg.Toplevel.State.activated);
    if (version >= 2) {
        if (configuration.tiled.left) appendEnum(values, &count, xdg.Toplevel.State.tiled_left);
        if (configuration.tiled.right) appendEnum(values, &count, xdg.Toplevel.State.tiled_right);
        if (configuration.tiled.top) appendEnum(values, &count, xdg.Toplevel.State.tiled_top);
        if (configuration.tiled.bottom) appendEnum(values, &count, xdg.Toplevel.State.tiled_bottom);
    }
    if (version >= 6 and configuration.suspended) {
        appendEnum(values, &count, xdg.Toplevel.State.suspended);
    }
    if (version >= 7) {
        if (configuration.constrained.left) appendEnum(values, &count, xdg.Toplevel.State.constrained_left);
        if (configuration.constrained.right) appendEnum(values, &count, xdg.Toplevel.State.constrained_right);
        if (configuration.constrained.top) appendEnum(values, &count, xdg.Toplevel.State.constrained_top);
        if (configuration.constrained.bottom) appendEnum(values, &count, xdg.Toplevel.State.constrained_bottom);
    }
    return values[0..count];
}

pub fn configureWindow(
    self: *Self,
    id: WindowId,
    dimensions: Dimensions,
) error{ InvalidWindow, OutOfMemory }!u32 {
    return self.configureWindowState(id, dimensions, .{});
}

pub fn configureWindowState(
    self: *Self,
    id: WindowId,
    dimensions: Dimensions,
    configuration: ToplevelConfigure,
) error{ InvalidWindow, OutOfMemory }!u32 {
    if (dimensions.width < 0 or dimensions.height < 0 or
        configuration.bounds.width < 0 or configuration.bounds.height < 0)
    {
        return error.InvalidWindow;
    }
    const window = self.windows.get(id) orelse return error.InvalidWindow;
    const state = self.xdg_surfaces.get(window.xdg_surface_id) orelse
        return error.InvalidWindow;
    const toplevel = state.toplevel_resource orelse return error.InvalidWindow;
    const serial = self.display.nextSerial();
    state.configure_serials.append(self.allocator, serial) catch return error.OutOfMemory;

    var state_values: [13]u32 = undefined;
    const states = toplevelStates(configuration, toplevel.getVersion(), &state_values);
    var states_array: wl.Array = .{
        .size = states.len * @sizeOf(u32),
        .alloc = states.len * @sizeOf(u32),
        .data = if (states.len == 0) null else @ptrCast(states.ptr),
    };
    if (toplevel.getVersion() >= 5 and
        (state.sent_capabilities == null or
            !std.meta.eql(state.sent_capabilities.?, configuration.capabilities)))
    {
        var capability_values: [4]u32 = undefined;
        var capability_count: usize = 0;
        if (configuration.capabilities.window_menu) appendEnum(
            &capability_values,
            &capability_count,
            xdg.Toplevel.WmCapabilities.window_menu,
        );
        if (configuration.capabilities.maximize) appendEnum(
            &capability_values,
            &capability_count,
            xdg.Toplevel.WmCapabilities.maximize,
        );
        if (configuration.capabilities.fullscreen) appendEnum(
            &capability_values,
            &capability_count,
            xdg.Toplevel.WmCapabilities.fullscreen,
        );
        if (configuration.capabilities.minimize) appendEnum(
            &capability_values,
            &capability_count,
            xdg.Toplevel.WmCapabilities.minimize,
        );
        var capabilities_array: wl.Array = .{
            .size = capability_count * @sizeOf(u32),
            .alloc = capability_count * @sizeOf(u32),
            .data = if (capability_count == 0) null else @ptrCast(&capability_values),
        };
        toplevel.sendWmCapabilities(&capabilities_array);
        state.sent_capabilities = configuration.capabilities;
    }
    if (toplevel.getVersion() >= 4 and
        (state.sent_bounds == null or
            !std.meta.eql(state.sent_bounds.?, configuration.bounds)))
    {
        toplevel.sendConfigureBounds(
            configuration.bounds.width,
            configuration.bounds.height,
        );
        state.sent_bounds = configuration.bounds;
    }
    const adapter: *ToplevelResource = @ptrCast(@alignCast(toplevel.getUserData().?));
    if (adapter.decoration) |decoration| {
        decoration.resource.sendConfigure(switch (configuration.decoration_mode) {
            .client_side => .client_side,
            .server_side => .server_side,
        });
        decoration.configure_sent = true;
        window.decoration_configure_requested = false;
    }
    self.gtk_shell.configureSurface(state.surface_id, .{
        .top = configuration.tiled.top,
        .right = configuration.tiled.right,
        .bottom = configuration.tiled.bottom,
        .left = configuration.tiled.left,
    });
    toplevel.sendConfigure(dimensions.width, dimensions.height, &states_array);
    adapter.xdg_surface_resource.resource.sendConfigure(serial);
    state.initial_configure_sent = true;
    if (!std.meta.eql(window.configuration, configuration)) {
        window.configuration = configuration;
        self.notifyWindowStateChanged(id);
    }
    return serial;
}

pub fn restoreStandaloneWindow(
    self: *Self,
    id: WindowId,
    deactivate: bool,
    dimensions: Dimensions,
) void {
    const window = self.windows.get(id) orelse return;
    const state = self.xdg_surfaces.get(window.xdg_surface_id) orelse return;
    if (deactivate or (window.ready and !state.initial_configure_sent)) {
        _ = self.configureWindowState(
            id,
            if (deactivate) dimensions else .{ .width = 0, .height = 0 },
            .{},
        ) catch |err| switch (err) {
            error.OutOfMemory => if (state.toplevel_resource) |resource| resource.postNoMemory(),
            error.InvalidWindow => {},
        };
    }
    if (window.mapped) self.scene.setMapped(window.scene_id, true);
}

pub fn setWindowVisible(self: *Self, id: WindowId, visible: bool) void {
    const window = self.windows.get(id) orelse return;
    self.scene.setMapped(window.scene_id, visible and window.mapped);
}

pub fn setWindowPosition(self: *Self, id: WindowId, position: Scene.Position) void {
    const window = self.windows.get(id) orelse return;
    const changed = if (self.scene.windowPosition(window.scene_id)) |current|
        !std.meta.eql(current, position)
    else
        false;
    self.scene.setPosition(window.scene_id, position);
    if (changed) self.reconfigureReactivePopups(id);
}

pub fn setWindowFocused(self: *Self, id: WindowId, focused: bool) void {
    const window = self.windows.get(id) orelse return;
    self.scene.setFocused(window.scene_id, focused);
}

pub fn setWindowFullscreen(self: *Self, id: WindowId, fullscreen: bool) void {
    const window = self.windows.get(id) orelse return;
    self.scene.setFullscreen(window.scene_id, fullscreen);
}

pub fn setWindowBorders(self: *Self, id: WindowId, borders: ?Scene.Borders) void {
    const window = self.windows.get(id) orelse return;
    self.scene.setBorders(window.scene_id, borders);
}

pub fn setWindowClipBox(self: *Self, id: WindowId, clip_box: ?Scene.ClipBox) void {
    const window = self.windows.get(id) orelse return;
    self.scene.setClipBox(window.scene_id, clip_box);
}

pub fn setWindowContentClipBox(self: *Self, id: WindowId, clip_box: ?Scene.ClipBox) void {
    const window = self.windows.get(id) orelse return;
    self.scene.setContentClipBox(window.scene_id, clip_box);
}

pub fn addWindowDecoration(
    self: *Self,
    id: WindowId,
    surface_id: Surface.Id,
    layer: Scene.DecorationLayer,
) error{ InvalidWindow, OutOfMemory }!Scene.DecorationId {
    const window = self.windows.get(id) orelse return error.InvalidWindow;
    return self.scene.addDecoration(window.scene_id, surface_id, layer);
}

pub fn removeWindowDecoration(self: *Self, id: Scene.DecorationId) void {
    self.scene.removeDecoration(id);
}

pub fn setWindowDecorationOffset(
    self: *Self,
    id: Scene.DecorationId,
    offset: Scene.Position,
) void {
    self.scene.setDecorationOffset(id, offset);
}

pub fn setWindowDecorationMapped(
    self: *Self,
    id: Scene.DecorationId,
    mapped: bool,
) void {
    self.scene.setDecorationMapped(id, mapped);
}

pub fn windowDecorationCommitted(self: *Self, id: Scene.DecorationId) void {
    self.scene.decorationCommitted(id);
}

pub fn placeWindowTop(self: *Self, id: WindowId) void {
    const window = self.windows.get(id) orelse return;
    self.scene.placeTop(window.scene_id);
}

pub fn placeWindowBottom(self: *Self, id: WindowId) void {
    const window = self.windows.get(id) orelse return;
    self.scene.placeBottom(window.scene_id);
}

pub fn placeWindowAbove(self: *Self, id: WindowId, other: WindowId) void {
    const window = self.windows.get(id) orelse return;
    const other_window = self.windows.get(other) orelse return;
    self.scene.placeAbove(window.scene_id, other_window.scene_id);
}

pub fn placeWindowBelow(self: *Self, id: WindowId, other: WindowId) void {
    const window = self.windows.get(id) orelse return;
    const other_window = self.windows.get(other) orelse return;
    self.scene.placeBelow(window.scene_id, other_window.scene_id);
}

pub fn closeWindow(self: *Self, id: WindowId) void {
    const window = self.windows.get(id) orelse return;
    const state = self.xdg_surfaces.get(window.xdg_surface_id) orelse return;
    if (state.toplevel_resource) |resource| resource.sendClose();
}

pub fn hasPopupGrab(self: *Self) bool {
    return self.topGrabbedPopup() != null;
}

pub fn popupGrabOwnsSurface(self: *Self, surface_id: Surface.Id) bool {
    const popup_id = self.topGrabbedPopup() orelse return true;
    const popup = self.popups.get(popup_id) orelse return true;
    const surface = Surface.resourceFor(self.surface_store, surface_id) orelse return false;
    return surface.getClient() == popup.resource.getClient();
}

pub fn popupKeyboardFocus(self: *Self) ?Surface.Id {
    const popup_id = self.topGrabbedPopup() orelse return null;
    const popup = self.popups.get(popup_id) orelse return null;
    const xdg_surface = self.xdg_surfaces.get(popup.xdg_surface_id) orelse return null;
    return xdg_surface.surface_id;
}

pub fn popupRootLayerSurface(
    self: *Self,
    surface_id: Surface.Id,
) ?Scene.LayerSurfaceId {
    var popup: ?*PopupState = null;
    var iterator = self.popups.iterator();
    while (iterator.next()) |entry| {
        const xdg_surface = self.xdg_surfaces.get(entry.value.xdg_surface_id) orelse continue;
        if (std.meta.eql(xdg_surface.surface_id, surface_id)) {
            popup = entry.value;
            break;
        }
    }

    var remaining = self.popups.len();
    while (popup) |current| {
        if (remaining == 0) return null;
        remaining -= 1;
        const parent_id = switch (current.parent) {
            .layer_surface => |id| return id,
            .unattached => return null,
            .xdg_surface => |id| id,
        };
        const parent = self.xdg_surfaces.get(parent_id) orelse return null;
        const parent_popup_id = switch (parent.role orelse return null) {
            .toplevel => return null,
            .popup => |id| id,
        };
        popup = self.popups.get(parent_popup_id);
    }
    return null;
}

pub fn dismissPopupGrab(self: *Self) void {
    var current = self.topGrabbedPopup();
    while (current) |id| {
        const popup = self.popups.get(id) orelse return;
        const parent = switch (popup.parent) {
            .xdg_surface => |parent_id| self.xdg_surfaces.get(parent_id),
            .unattached, .layer_surface => null,
        };
        const parent_popup_id = if (parent) |state| switch (state.role orelse return) {
            .toplevel => null,
            .popup => |popup_id| popup_id,
        } else null;
        self.dismissPopup(id);
        current = if (parent_popup_id) |parent_id| parent: {
            const parent_popup = self.popups.get(parent_id) orelse break :parent null;
            break :parent if (parent_popup.grabbed) parent_id else null;
        } else null;
    }
}

fn topGrabbedPopup(self: *Self) ?PopupId {
    var result: ?PopupId = null;
    var order: u64 = 0;
    var iterator = self.popups.iterator();
    while (iterator.next()) |entry| {
        const popup = entry.value;
        if (!popup.grabbed or !popup.mapped or popup.dismissed) continue;
        if (result == null or popup.order > order) {
            result = entry.id;
            order = popup.order;
        }
    }
    return result;
}

fn popupRootWindow(self: *Self, id: PopupId) ?WindowId {
    var popup = self.popups.get(id) orelse return null;
    var remaining = self.popups.len() + 1;
    while (remaining > 0) : (remaining -= 1) {
        const parent_id = switch (popup.parent) {
            .xdg_surface => |parent_id| parent_id,
            .unattached, .layer_surface => return null,
        };
        const parent = self.xdg_surfaces.get(parent_id) orelse return null;
        switch (parent.role orelse return null) {
            .toplevel => |window_id| return window_id,
            .popup => |popup_id| popup = self.popups.get(popup_id) orelse return null,
        }
    }
    return null;
}

/// Resolve an xdg toplevel or popup surface to its logical root window.
pub fn surfaceRootWindow(self: *Self, surface_id: Surface.Id) ?WindowId {
    var iterator = self.xdg_surfaces.iterator();
    while (iterator.next()) |entry| {
        if (!std.meta.eql(entry.value.surface_id, surface_id)) continue;
        return switch (entry.value.role orelse return null) {
            .toplevel => |id| id,
            .popup => |id| self.popupRootWindow(id),
        };
    }
    return null;
}

pub fn toplevelForSurface(self: *Self, surface_id: Surface.Id) ?ToplevelInfo {
    var iterator = self.xdg_surfaces.iterator();
    while (iterator.next()) |entry| {
        if (!std.meta.eql(entry.value.surface_id, surface_id)) continue;
        const window_id = switch (entry.value.role orelse return null) {
            .toplevel => |id| id,
            .popup => return null,
        };
        if (self.windows.get(window_id) == null) return null;
        const resource = entry.value.toplevel_resource orelse return null;
        const adapter: *ToplevelResource = @ptrCast(@alignCast(resource.getUserData().?));
        return .{
            .window_id = window_id,
            .surface_resource = Surface.resourceFor(self.surface_store, surface_id) orelse return null,
            .xdg_surface_resource = adapter.xdg_surface_resource.resource,
            .resource = resource,
        };
    }
    return null;
}

pub fn toplevelFromResource(self: *Self, resource: *xdg.Toplevel) ?ToplevelInfo {
    const data = resource.getUserData() orelse return null;
    const toplevel: *ToplevelResource = @ptrCast(@alignCast(data));
    if (toplevel.shell != self) return null;
    const xdg_surface = self.xdg_surfaces.get(toplevel.xdg_surface_id) orelse return null;
    if (self.windows.get(toplevel.id) == null or xdg_surface.toplevel_resource != resource)
        return null;
    return .{
        .window_id = toplevel.id,
        .surface_resource = Surface.resourceFor(self.surface_store, xdg_surface.surface_id) orelse
            return null,
        .xdg_surface_resource = toplevel.xdg_surface_resource.resource,
        .resource = resource,
    };
}

pub fn setForeignParent(
    self: *Self,
    child_surface_id: Surface.Id,
    parent_id: WindowId,
    owner: *anyopaque,
) ForeignParentError!void {
    const child_id = (self.toplevelForSurface(child_surface_id) orelse
        return error.InvalidSurface).window_id;
    const child = self.windows.get(child_id) orelse return error.InvalidSurface;
    const parent = self.windows.get(parent_id) orelse return error.InvalidParent;
    const applied_parent: ?WindowId = if (parent.mapped) parent_id else null;
    var ancestor = applied_parent;
    while (ancestor) |candidate| {
        if (std.meta.eql(candidate, child_id)) return error.InvalidParent;
        const candidate_window = self.windows.get(candidate) orelse break;
        ancestor = candidate_window.parent;
    }
    child.parent = applied_parent;
    child.parent_owner = if (applied_parent != null) owner else null;
    _ = self.notifyWindowMetadataChanged(child_id);
}

pub fn clearForeignParents(self: *Self, owner: *anyopaque) void {
    var iterator = self.windows.iterator();
    while (iterator.next()) |entry| {
        if (entry.value.parent_owner != owner) continue;
        entry.value.parent = null;
        entry.value.parent_owner = null;
        _ = self.notifyWindowMetadataChanged(entry.id);
    }
}

fn clearParentReferences(self: *Self, parent_id: WindowId) void {
    var iterator = self.windows.iterator();
    while (iterator.next()) |entry| {
        if (entry.value.parent) |candidate| {
            if (!std.meta.eql(candidate, parent_id)) continue;
            entry.value.parent = null;
            entry.value.parent_owner = null;
            _ = self.notifyWindowMetadataChanged(entry.id);
        }
    }
}

fn notifyWindowMetadataChanged(self: *Self, window_id: WindowId) bool {
    const externally_managed = if (self.window_listener) |listener|
        listener.metadata_changed(listener.context, window_id)
    else
        false;
    for (self.window_observers.items) |observer| {
        observer.metadata_changed(observer.context, window_id);
    }
    return externally_managed;
}

fn notifyWindowCommitted(self: *Self, window_id: WindowId, configure_serial: ?u32) bool {
    const externally_managed = if (self.window_listener) |listener|
        listener.committed(listener.context, window_id, configure_serial)
    else
        false;
    for (self.window_observers.items) |observer| {
        observer.committed(observer.context, window_id);
    }
    return externally_managed;
}

fn notifyWindowUnmapped(self: *Self, window_id: WindowId) void {
    if (self.window_listener) |listener| listener.unmapped(listener.context, window_id);
    for (self.window_observers.items) |observer| observer.unmapped(observer.context, window_id);
}

fn notifyWindowDestroyed(self: *Self, window_id: WindowId) void {
    if (self.window_listener) |listener| listener.destroyed(listener.context, window_id);
    for (self.window_observers.items) |observer| observer.destroyed(observer.context, window_id);
}

fn notifyWindowStateChanged(self: *Self, window_id: WindowId) void {
    for (self.window_observers.items) |observer| observer.state_changed(observer.context, window_id);
}

fn isTopmostPopup(self: *Self, id: PopupId) bool {
    const popup = self.popups.get(id) orelse return true;
    var iterator = self.popups.iterator();
    while (iterator.next()) |entry| {
        switch (entry.value.parent) {
            .xdg_surface => |parent_id| if (std.meta.eql(parent_id, popup.xdg_surface_id)) return false,
            .unattached, .layer_surface => {},
        }
    }
    return true;
}

fn parentMapped(self: *Self, popup: *const PopupState) bool {
    return switch (popup.parent) {
        .unattached => false,
        .xdg_surface => |id| (self.xdg_surfaces.get(id) orelse return false).mapped,
        .layer_surface => |id| (self.scene.layerSurface(id) orelse return false).mapped,
    };
}

fn popupParentGeometry(self: *Self, popup: *const PopupState) ?struct {
    geometry: Scene.ContentGeometry,
    position: Scene.Position,
} {
    if (popup.parent == .unattached) return null;
    if (popup.parent == .layer_surface) {
        const layer = self.scene.layerSurface(popup.parent.layer_surface) orelse return null;
        const buffer = Surface.currentBuffer(self.surface_store, layer.surface_id) orelse return null;
        return .{ .geometry = .{ .size = buffer.logical_size }, .position = layer.position };
    }
    const parent = self.xdg_surfaces.get(popup.parent.xdg_surface) orelse return null;
    const geometry = self.contentGeometry(parent) orelse return null;
    const position = switch (parent.role orelse return null) {
        .toplevel => |window_id| window: {
            const window = self.windows.get(window_id) orelse return null;
            break :window self.scene.windowPosition(window.scene_id) orelse return null;
        },
        .popup => |popup_id| parent_popup: {
            const parent_popup = self.popups.get(popup_id) orelse return null;
            break :parent_popup self.scene.popupPosition(parent_popup.scene_id orelse return null) orelse return null;
        },
    };
    return .{ .geometry = geometry, .position = position };
}

fn popupPlacement(
    self: *Self,
    popup: *const PopupState,
    rules: PositionerRules,
) error{ InvalidParent, InvalidPositioner }!PopupPlacement {
    if (!rules.complete()) return error.InvalidPositioner;
    const parent = self.popupParentGeometry(popup) orelse return error.InvalidParent;
    const anchor_rect = rules.anchor_rect.?;
    const parent_width: i64 = parent.geometry.size.width;
    const parent_height: i64 = parent.geometry.size.height;
    const anchor_right = @as(i64, anchor_rect.x) + anchor_rect.width;
    const anchor_bottom = @as(i64, anchor_rect.y) + anchor_rect.height;
    if (anchor_rect.x < 0 or anchor_rect.y < 0 or
        anchor_right > parent_width or anchor_bottom > parent_height)
    {
        return error.InvalidPositioner;
    }
    return placePopup(
        rules,
        parent.position,
        self.popupOutputBounds(parent.position, parent.geometry.size),
    );
}

fn popupOutputBounds(
    self: *Self,
    parent_position: Scene.Position,
    parent_size: render.Size,
) render.Rect {
    const parent_rect: render.Rect = .{
        .x = parent_position.x,
        .y = parent_position.y,
        .width = parent_size.width,
        .height = parent_size.height,
    };
    var selected = self.outputs.get(self.default_output_id).?.logicalRect();
    var selected_area: u64 = 0;
    var outputs = self.outputs.iterator();
    while (outputs.next()) |entry| {
        const intersection = parent_rect.intersection(entry.output.logicalRect()) orelse continue;
        const area = @as(u64, intersection.width) * intersection.height;
        if (area <= selected_area) continue;
        selected = entry.output.logicalRect();
        selected_area = area;
    }
    return selected;
}

fn sendPopupConfigure(
    self: *Self,
    id: PopupId,
    rules: PositionerRules,
    reposition_token: ?u32,
) error{ InvalidParent, InvalidPositioner, OutOfMemory }!void {
    const popup = self.popups.get(id) orelse return error.InvalidParent;
    const placement = try self.popupPlacement(popup, rules);
    const xdg_surface = self.xdg_surfaces.get(popup.xdg_surface_id) orelse
        return error.InvalidParent;
    const serial = self.display.nextSerial();
    try xdg_surface.configure_serials.append(self.allocator, serial);
    popup.pending_configure = .{
        .serial = serial,
        .rules = rules,
        .placement = placement,
    };
    if (reposition_token) |token| popup.resource.sendRepositioned(token);
    popup.resource.sendConfigure(
        placement.position.x,
        placement.position.y,
        placement.dimensions.width,
        placement.dimensions.height,
    );
    const adapter: *PopupResource = @ptrCast(@alignCast(popup.resource.getUserData().?));
    adapter.xdg_surface_resource.resource.sendConfigure(serial);
    xdg_surface.initial_configure_sent = true;
}

fn reconfigureReactivePopups(self: *Self, window_id: WindowId) void {
    var iterator = self.popups.iterator();
    while (iterator.next()) |entry| {
        const root = self.popupRootWindow(entry.id) orelse continue;
        if (!std.meta.eql(root, window_id) or !entry.value.mapped or
            !entry.value.rules.reactive or entry.value.dismissed) continue;
        self.sendPopupConfigure(entry.id, entry.value.rules, null) catch |err| switch (err) {
            error.OutOfMemory => entry.value.resource.postNoMemory(),
            error.InvalidParent, error.InvalidPositioner => self.dismissPopup(entry.id),
        };
    }
}

fn dismissPopup(self: *Self, id: PopupId) void {
    const popup = self.popups.get(id) orelse return;
    if (popup.dismissed) return;
    self.dismissPopupsForParent(popup.xdg_surface_id);
    popup.dismissed = true;
    popup.mapped = false;
    if (self.xdg_surfaces.get(popup.xdg_surface_id)) |xdg_surface| {
        xdg_surface.mapped = false;
    }
    if (popup.scene_id) |scene_id| self.scene.setPopupMapped(scene_id, false);
    popup.resource.sendPopupDone();
}

fn dismissPopupsForParent(self: *Self, parent_id: XdgSurfaceId) void {
    while (true) {
        var result: ?PopupId = null;
        var order: u64 = 0;
        var iterator = self.popups.iterator();
        while (iterator.next()) |entry| {
            if (entry.value.dismissed or
                !self.popupDescendsFrom(entry.id, parent_id)) continue;
            if (result == null or entry.value.order > order) {
                result = entry.id;
                order = entry.value.order;
            }
        }
        self.dismissPopup(result orelse return);
    }
}

fn popupDescendsFrom(self: *Self, id: PopupId, ancestor: XdgSurfaceId) bool {
    var popup = self.popups.get(id) orelse return false;
    var remaining = self.popups.len() + 1;
    while (remaining > 0) : (remaining -= 1) {
        const parent_xdg_id = switch (popup.parent) {
            .xdg_surface => |parent_id| parent_id,
            .unattached, .layer_surface => return false,
        };
        if (std.meta.eql(parent_xdg_id, ancestor)) return true;
        const parent = self.xdg_surfaces.get(parent_xdg_id) orelse return false;
        const parent_id = switch (parent.role orelse return false) {
            .toplevel => return false,
            .popup => |popup_id| popup_id,
        };
        popup = self.popups.get(parent_id) orelse return false;
    }
    return false;
}

fn unmapPopup(self: *Self, id: PopupId) void {
    const popup = self.popups.get(id) orelse return;
    self.dismissPopupsForParent(popup.xdg_surface_id);
    popup.mapped = false;
    popup.ready = false;
    popup.grabbed = false;
    if (popup.scene_id) |scene_id| {
        self.scene.setPopupMapped(scene_id, false);
        self.scene.setPopupContentGeometry(scene_id, null);
    }
}

fn removePopupState(self: *Self, id: PopupId) void {
    const popup = self.popups.get(id) orelse return;
    self.dismissPopupsForParent(popup.xdg_surface_id);
    const removed = self.popups.remove(id) orelse return;
    if (removed.scene_id) |scene_id| self.scene.removePopup(scene_id);
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    WmBaseResource.create(self, client, version, id) catch client.postNoMemory();
}

fn bindDecorationManager(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = zxdg.DecorationManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleDecorationManagerRequest, null, self);
}

fn handleDecorationManagerRequest(
    resource: *zxdg.DecorationManagerV1,
    request: zxdg.DecorationManagerV1.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .get_toplevel_decoration => |get| ToplevelDecorationResource.create(
            self,
            resource,
            get.toplevel,
            get.id,
        ) catch resource.postNoMemory(),
    }
}

const WmBaseResource = struct {
    allocator: std.mem.Allocator,
    shell: *Self,
    id: BindingId,

    fn create(
        shell: *Self,
        client: *wl.Client,
        version: u32,
        id: u32,
    ) error{ OutOfMemory, ResourceCreateFailed }!void {
        const resource = try xdg.WmBase.create(client, version, id);
        errdefer resource.destroy();

        const self = shell.allocator.create(WmBaseResource) catch return error.OutOfMemory;
        errdefer shell.allocator.destroy(self);

        const binding_id = shell.bindings.insert(shell.allocator, .{}) catch
            return error.OutOfMemory;
        self.* = .{
            .allocator = shell.allocator,
            .shell = shell,
            .id = binding_id,
        };
        resource.setHandler(*WmBaseResource, handleRequest, handleDestroy, self);
    }

    fn handleRequest(
        resource: *xdg.WmBase,
        request: xdg.WmBase.Request,
        self: *WmBaseResource,
    ) void {
        switch (request) {
            .destroy => {
                const binding = self.shell.bindings.get(self.id) orelse unreachable;
                if (binding.surface_count != 0) {
                    resource.postError(
                        .defunct_surfaces,
                        "xdg_wm_base still owns xdg_surface objects",
                    );
                    return;
                }
                resource.destroy();
            },
            .create_positioner => |positioner| Positioner.create(
                self.allocator,
                resource.getClient(),
                resource.getVersion(),
                positioner.id,
            ) catch resource.postNoMemory(),
            .get_xdg_surface => |get| XdgSurfaceResource.create(
                self.shell,
                self.id,
                resource,
                get.surface,
                get.id,
            ) catch resource.postNoMemory(),
            .pong => {},
        }
    }

    fn handleDestroy(_: *xdg.WmBase, self: *WmBaseResource) void {
        _ = self.shell.bindings.remove(self.id);
        self.allocator.destroy(self);
    }
};

const Positioner = struct {
    allocator: std.mem.Allocator,
    rules: PositionerRules,

    fn create(
        allocator: std.mem.Allocator,
        client: *wl.Client,
        version: u32,
        id: u32,
    ) error{ OutOfMemory, ResourceCreateFailed }!void {
        const resource = try xdg.Positioner.create(client, version, id);
        errdefer resource.destroy();

        const self = allocator.create(Positioner) catch return error.OutOfMemory;
        self.* = .{ .allocator = allocator, .rules = .{} };
        resource.setHandler(*Positioner, handleRequest, handleDestroy, self);
    }

    fn handleRequest(
        resource: *xdg.Positioner,
        request: xdg.Positioner.Request,
        self: *Positioner,
    ) void {
        switch (request) {
            .destroy => resource.destroy(),
            .set_size => |set| {
                if (set.width <= 0 or set.height <= 0) {
                    resource.postError(.invalid_input, "positioner size must be positive");
                    return;
                }
                self.rules.size = .{ .width = set.width, .height = set.height };
            },
            .set_anchor_rect => |set| {
                if (set.width < 0 or set.height < 0) {
                    resource.postError(.invalid_input, "anchor rectangle size must not be negative");
                    return;
                }
                self.rules.anchor_rect = .{
                    .x = set.x,
                    .y = set.y,
                    .width = set.width,
                    .height = set.height,
                };
            },
            .set_anchor => |set| {
                if (!validAnchor(set.anchor)) {
                    resource.postError(.invalid_input, "invalid positioner anchor");
                    return;
                }
                self.rules.anchor = set.anchor;
            },
            .set_gravity => |set| {
                if (!validGravity(set.gravity)) {
                    resource.postError(.invalid_input, "invalid positioner gravity");
                    return;
                }
                self.rules.gravity = set.gravity;
            },
            .set_constraint_adjustment => |set| {
                const adjustment: u32 = @bitCast(set.constraint_adjustment);
                if (adjustment & ~@as(u32, 0x3f) != 0) {
                    resource.postError(.invalid_input, "invalid constraint adjustment");
                    return;
                }
                self.rules.adjustment = set.constraint_adjustment;
            },
            .set_offset => |set| self.rules.offset = .{ .x = set.x, .y = set.y },
            .set_reactive => self.rules.reactive = true,
            .set_parent_configure => |set| self.rules.parent_configure = set.serial,
            .set_parent_size => |set| {
                if (set.parent_width <= 0 or set.parent_height <= 0) {
                    resource.postError(.invalid_input, "parent size must be positive");
                    return;
                }
                self.rules.parent_size = .{
                    .width = set.parent_width,
                    .height = set.parent_height,
                };
            },
        }
    }

    fn fromResource(resource: *xdg.Positioner) *Positioner {
        return @ptrCast(@alignCast(resource.getUserData().?));
    }

    fn handleDestroy(_: *xdg.Positioner, self: *Positioner) void {
        self.allocator.destroy(self);
    }

    fn validAnchor(anchor: xdg.Positioner.Anchor) bool {
        return switch (anchor) {
            .none,
            .top,
            .bottom,
            .left,
            .right,
            .top_left,
            .bottom_left,
            .top_right,
            .bottom_right,
            => true,
            else => false,
        };
    }

    fn validGravity(gravity: xdg.Positioner.Gravity) bool {
        return switch (gravity) {
            .none,
            .top,
            .bottom,
            .left,
            .right,
            .top_left,
            .bottom_left,
            .top_right,
            .bottom_right,
            => true,
            else => false,
        };
    }
};

const XdgSurfaceResource = struct {
    allocator: std.mem.Allocator,
    shell: *Self,
    id: XdgSurfaceId,
    binding_id: BindingId,
    wm_base_resource: *xdg.WmBase,
    resource: *xdg.Surface,
    surface: ?*Surface,
    toplevel_resource: ?*xdg.Toplevel,

    fn create(
        shell: *Self,
        binding_id: BindingId,
        wm_base_resource: *xdg.WmBase,
        wl_surface_resource: *wl.Surface,
        id: u32,
    ) error{ OutOfMemory, ResourceCreateFailed }!void {
        const resource = try xdg.Surface.create(
            wm_base_resource.getClient(),
            wm_base_resource.getVersion(),
            id,
        );
        errdefer resource.destroy();

        const self = shell.allocator.create(XdgSurfaceResource) catch return error.OutOfMemory;
        errdefer shell.allocator.destroy(self);

        const surface = Surface.fromResource(wl_surface_resource);
        const state_id = shell.xdg_surfaces.insert(shell.allocator, .{
            .surface_id = surface.handle(),
        }) catch return error.OutOfMemory;
        errdefer {
            var removed = shell.xdg_surfaces.remove(state_id).?;
            removed.deinit(shell.allocator);
        }

        self.* = .{
            .allocator = shell.allocator,
            .shell = shell,
            .id = state_id,
            .binding_id = binding_id,
            .wm_base_resource = wm_base_resource,
            .resource = resource,
            .surface = surface,
            .toplevel_resource = null,
        };

        if (surface.assignedRole() != null) {
            wm_base_resource.postError(.role, "wl_surface already has a role");
            var removed = shell.xdg_surfaces.remove(state_id) orelse unreachable;
            removed.deinit(shell.allocator);
            shell.allocator.destroy(self);
            resource.destroy();
            return;
        }
        if (surface.hasBufferAttachedOrCommitted()) {
            wm_base_resource.postError(
                .invalid_surface_state,
                "wl_surface already has a buffer attached or committed",
            );
            var removed = shell.xdg_surfaces.remove(state_id) orelse unreachable;
            removed.deinit(shell.allocator);
            shell.allocator.destroy(self);
            resource.destroy();
            return;
        }
        surface.reserveRole(.xdg_toplevel, .{
            .context = self,
            .before_commit = beforeSurfaceCommit,
            .after_commit = afterSurfaceStateCommit,
            .tree_applied = afterSurfaceCommit,
            .surface_destroyed = surfaceDestroyed,
        }) catch {
            wm_base_resource.postError(.role, "wl_surface is not available for an xdg role");
            var removed = shell.xdg_surfaces.remove(state_id) orelse unreachable;
            removed.deinit(shell.allocator);
            shell.allocator.destroy(self);
            resource.destroy();
            return;
        };

        if (shell.bindings.get(binding_id)) |binding| binding.surface_count += 1;
        resource.setHandler(*XdgSurfaceResource, handleRequest, handleDestroy, self);
    }

    fn handleRequest(
        resource: *xdg.Surface,
        request: xdg.Surface.Request,
        self: *XdgSurfaceResource,
    ) void {
        const state = self.shell.xdg_surfaces.get(self.id) orelse return;
        switch (request) {
            .destroy => {
                if (state.role != null) {
                    resource.postError(
                        .defunct_role_object,
                        "destroy the xdg role object before xdg_surface",
                    );
                    return;
                }
                resource.destroy();
            },
            .get_toplevel => |get| {
                if (state.role != null) {
                    resource.postError(.already_constructed, "xdg_surface already has a role");
                    return;
                }
                ToplevelResource.create(self, get.id) catch resource.postNoMemory();
            },
            .get_popup => |get| {
                if (state.role != null) {
                    resource.postError(.already_constructed, "xdg_surface already has a role");
                    return;
                }
                PopupResource.create(self, get.id, get.parent, get.positioner) catch |err| switch (err) {
                    error.OutOfMemory => resource.postNoMemory(),
                    error.ResourceCreateFailed => {},
                };
            },
            .set_window_geometry => |set| {
                if (!self.requireRole()) return;
                if (set.width <= 0 or set.height <= 0) {
                    resource.postError(.invalid_size, "window geometry size must be positive");
                    return;
                }
                state.pending_geometry = .{
                    .x = set.x,
                    .y = set.y,
                    .width = set.width,
                    .height = set.height,
                };
                state.pending_geometry_changed = true;
            },
            .ack_configure => |ack| {
                if (!self.requireRole()) return;
                self.ackConfigure(ack.serial);
            },
        }
    }

    fn handleDestroy(_: *xdg.Surface, self: *XdgSurfaceResource) void {
        if (self.surface) |surface| surface.releaseRole(self);

        if (self.shell.bindings.get(self.binding_id)) |binding| {
            std.debug.assert(binding.surface_count > 0);
            binding.surface_count -= 1;
        }

        var removed = self.shell.xdg_surfaces.remove(self.id) orelse {
            self.allocator.destroy(self);
            return;
        };
        if (removed.role) |role| switch (role) {
            .toplevel => |window_id| {
                self.shell.clearParentReferences(window_id);
                if (self.shell.windows.remove(window_id)) |window_value| {
                    self.shell.notifyWindowDestroyed(window_id);
                    var window = window_value;
                    self.shell.scene.removeWindow(window.scene_id);
                    window.deinit(self.allocator);
                }
            },
            .popup => |popup_id| self.shell.removePopupState(popup_id),
        };
        removed.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn requireRole(self: *XdgSurfaceResource) bool {
        const state = self.shell.xdg_surfaces.get(self.id) orelse return false;
        if (state.role == null) {
            self.resource.postError(.not_constructed, "xdg_surface has no role");
            return false;
        }
        return true;
    }

    fn ackConfigure(self: *XdgSurfaceResource, serial: u32) void {
        const state = self.shell.xdg_surfaces.get(self.id) orelse return;
        const index = for (state.configure_serials.items, 0..) |candidate, i| {
            if (candidate == serial) break i;
        } else {
            self.resource.postError(.invalid_serial, "unknown xdg_surface configure serial");
            return;
        };

        const consumed = index + 1;
        std.mem.copyForwards(
            u32,
            state.configure_serials.items[0 .. state.configure_serials.items.len - consumed],
            state.configure_serials.items[consumed..],
        );
        state.configure_serials.items.len -= consumed;
        state.last_acked_serial = serial;
    }

    fn beforeSurfaceCommit(context: *anyopaque, info: Surface.CommitInfo) Surface.CommitAction {
        const self: *XdgSurfaceResource = @ptrCast(@alignCast(context));
        const state = self.shell.xdg_surfaces.get(self.id) orelse unreachable;
        if (state.role == null) {
            self.resource.postError(.not_constructed, "xdg_surface committed before role creation");
            return .reject;
        }
        if (state.role.? == .toplevel) {
            const window = self.shell.windows.get(state.role.?.toplevel) orelse unreachable;
            if (!ToplevelResource.validSizeHints(
                window.pending_min_size,
                window.pending_max_size,
            )) {
                state.toplevel_resource.?.postError(
                    .invalid_size,
                    "invalid minimum or maximum window size",
                );
                return .reject;
            }
        }
        if (state.role.? == .popup) {
            const popup = self.shell.popups.get(state.role.?.popup) orelse return .reject;
            if (popup.scene_id == null) {
                self.wm_base_resource.postError(
                    .invalid_popup_parent,
                    "unattached xdg_popup committed before external parent attachment",
                );
                return .reject;
            }
        }
        if (info.has_buffer and state.toplevel_resource != null) {
            const toplevel: *ToplevelResource = @ptrCast(@alignCast(
                state.toplevel_resource.?.getUserData().?,
            ));
            if (toplevel.decoration) |decoration| {
                if (decoration.resource.getVersion() == 1 and !decoration.configure_sent) {
                    decoration.resource.postError(
                        .unconfigured_buffer,
                        "buffer committed before the initial decoration configure",
                    );
                    return .reject;
                }
            }
        }
        if (info.has_buffer and !state.configured and state.last_acked_serial == null) {
            self.resource.postError(
                .unconfigured_buffer,
                "buffer committed before the initial configure was acknowledged",
            );
            return .reject;
        }
        if (info.had_buffer and !info.has_buffer) {
            switch (state.role.?) {
                .toplevel => |window_id| if (self.shell.window_listener) |listener|
                    listener.unmapping(listener.context, window_id),
                .popup => {},
            }
        }
        return .apply;
    }

    fn afterSurfaceStateCommit(_: *anyopaque, _: Surface.CommitInfo) void {}

    fn afterSurfaceCommit(context: *anyopaque, info: Surface.CommitInfo) void {
        const self: *XdgSurfaceResource = @ptrCast(@alignCast(context));
        const state = self.shell.xdg_surfaces.get(self.id) orelse return;
        if (state.pending_geometry_changed) {
            state.current_geometry = self.shell.effectiveGeometry(
                state.surface_id,
                state.pending_geometry orelse unreachable,
            );
            state.pending_geometry_changed = false;
        }

        const role = state.role orelse return;
        switch (role) {
            .toplevel => |window_id| self.afterToplevelCommit(state, window_id, info),
            .popup => |popup_id| self.afterPopupCommit(state, popup_id, info),
        }
    }

    fn afterToplevelCommit(
        self: *XdgSurfaceResource,
        state: *XdgSurfaceState,
        window_id: WindowId,
        info: Surface.CommitInfo,
    ) void {
        const window = self.shell.windows.get(window_id) orelse return;
        if (window.commit(self.allocator)) {
            _ = self.shell.notifyWindowMetadataChanged(window_id);
        }

        if (info.had_buffer and !info.has_buffer) {
            self.shell.dismissPopupsForParent(self.id);
            self.shell.notifyWindowUnmapped(window_id);
            state.mapped = false;
            state.configured = false;
            state.initial_configure_sent = false;
            state.sent_capabilities = null;
            state.sent_bounds = null;
            state.last_acked_serial = null;
            state.configure_serials.clearRetainingCapacity();
            if (state.toplevel_resource) |resource| {
                const toplevel: *ToplevelResource = @ptrCast(@alignCast(resource.getUserData().?));
                if (toplevel.decoration) |decoration| decoration.configure_sent = false;
            }
            self.shell.scene.setMapped(window.scene_id, false);
            self.shell.scene.setContentGeometry(window.scene_id, null);
            window.reset(self.allocator);
            return;
        }

        if (info.has_buffer) {
            const geometry = self.shell.contentGeometry(state) orelse unreachable;
            const dimensions: Dimensions = .{
                .width = @intCast(geometry.size.width),
                .height = @intCast(geometry.size.height),
            };
            const previous_dimensions = window.committed_dimensions;
            window.committed_dimensions = dimensions;
            self.shell.scene.setContentGeometry(
                window.scene_id,
                geometry,
            );
            const was_mapped = window.mapped;
            const configure_serial = state.last_acked_serial;
            if (configure_serial != null) {
                state.configured = true;
                state.last_acked_serial = null;
            }
            state.mapped = state.configured;
            window.mapped = state.mapped;
            if (windowCommitNeedsNotification(
                was_mapped,
                configure_serial,
                previous_dimensions,
                dimensions,
            )) {
                const externally_managed = self.shell.notifyWindowCommitted(
                    window_id,
                    configure_serial,
                );
                if (!externally_managed) {
                    self.shell.scene.setMapped(window.scene_id, state.mapped);
                }
            }
            if (was_mapped and state.mapped) {
                self.shell.scene.surfaceCommitted(window.scene_id);
            }
            return;
        }

        if (!window.ready) {
            window.ready = true;
            const externally_managed = if (self.shell.window_listener) |listener|
                listener.ready(listener.context, window_id)
            else
                false;
            if (!externally_managed) self.sendInitialConfigure(window_id);
        }
    }

    fn afterPopupCommit(
        self: *XdgSurfaceResource,
        state: *XdgSurfaceState,
        popup_id: PopupId,
        info: Surface.CommitInfo,
    ) void {
        const popup = self.shell.popups.get(popup_id) orelse return;
        if (popup.dismissed) return;
        const scene_id = popup.scene_id orelse return;
        if (info.had_buffer and !info.has_buffer) {
            self.shell.unmapPopup(popup_id);
            popup.dismissed = false;
            popup.pending_configure = null;
            state.mapped = false;
            state.configured = false;
            state.initial_configure_sent = false;
            state.last_acked_serial = null;
            state.configure_serials.clearRetainingCapacity();
            return;
        }

        if (info.has_buffer) {
            if (!self.shell.parentMapped(popup)) {
                self.wm_base_resource.postError(
                    .invalid_popup_parent,
                    "xdg_popup parent is not mapped",
                );
                return;
            }
            const was_mapped = popup.mapped;
            if (state.last_acked_serial) |serial| {
                state.configured = true;
                if (popup.pending_configure) |pending| {
                    if (pending.serial == serial) {
                        popup.rules = pending.rules;
                        self.shell.scene.setPopupPosition(scene_id, pending.placement.position);
                        popup.pending_configure = null;
                    }
                }
                state.last_acked_serial = null;
            }
            self.shell.scene.setPopupContentGeometry(
                scene_id,
                self.shell.contentGeometry(state),
            );
            state.mapped = state.configured and !popup.dismissed;
            popup.mapped = state.mapped;
            self.shell.scene.setPopupMapped(scene_id, popup.mapped);
            if (was_mapped and popup.mapped) self.shell.scene.popupCommitted(scene_id);
            return;
        }

        if (popup.ready) return;
        if (!self.shell.parentMapped(popup)) {
            self.wm_base_resource.postError(
                .invalid_popup_parent,
                "xdg_popup parent is not mapped",
            );
            return;
        }
        popup.ready = true;
        self.shell.sendPopupConfigure(popup_id, popup.rules, null) catch |err| switch (err) {
            error.OutOfMemory => self.resource.postNoMemory(),
            error.InvalidParent => self.wm_base_resource.postError(
                .invalid_popup_parent,
                "invalid xdg_popup parent",
            ),
            error.InvalidPositioner => self.wm_base_resource.postError(
                .invalid_positioner,
                "invalid xdg_popup positioner",
            ),
        };
    }

    fn surfaceDestroyed(context: *anyopaque) void {
        const self: *XdgSurfaceResource = @ptrCast(@alignCast(context));
        self.surface = null;
        const state = self.shell.xdg_surfaces.get(self.id) orelse return;
        state.surface_alive = false;
        state.mapped = false;
        if (state.role) |role| switch (role) {
            .toplevel => |window_id| {
                if (self.shell.windows.get(window_id)) |window| {
                    if (window.ready) {
                        self.shell.notifyWindowUnmapped(window_id);
                    }
                    window.mapped = false;
                    window.ready = false;
                    self.shell.scene.setMapped(window.scene_id, false);
                    self.shell.scene.setContentGeometry(window.scene_id, null);
                }
            },
            .popup => |popup_id| self.shell.unmapPopup(popup_id),
        };
    }

    fn sendInitialConfigure(self: *XdgSurfaceResource, window_id: WindowId) void {
        _ = self.shell.configureWindow(window_id, .{ .width = 0, .height = 0 }) catch |err| switch (err) {
            error.OutOfMemory => self.resource.postNoMemory(),
            error.InvalidWindow => {},
        };
    }
};

const PopupResource = struct {
    allocator: std.mem.Allocator,
    shell: *Self,
    id: PopupId,
    xdg_surface_id: XdgSurfaceId,
    xdg_surface_resource: *XdgSurfaceResource,

    fn create(
        xdg_surface: *XdgSurfaceResource,
        id: u32,
        parent_resource: ?*xdg.Surface,
        positioner_resource: *xdg.Positioner,
    ) error{ OutOfMemory, ResourceCreateFailed }!void {
        const surface = xdg_surface.surface orelse return error.ResourceCreateFailed;
        if (parent_resource) |parent_xdg_resource| if (parent_xdg_resource.getClient() != xdg_surface.resource.getClient()) {
            xdg_surface.wm_base_resource.postError(
                .invalid_popup_parent,
                "xdg_popup parent belongs to another client",
            );
            return error.ResourceCreateFailed;
        };
        const parent_adapter: ?*XdgSurfaceResource = if (parent_resource) |parent_xdg_resource|
            @ptrCast(@alignCast(parent_xdg_resource.getUserData() orelse return error.ResourceCreateFailed))
        else
            null;
        if (parent_adapter) |adapter| if (adapter.shell != xdg_surface.shell or
            std.meta.eql(adapter.id, xdg_surface.id))
        {
            xdg_surface.wm_base_resource.postError(
                .invalid_popup_parent,
                "invalid xdg_popup parent",
            );
            return error.ResourceCreateFailed;
        };
        const parent_state = if (parent_adapter) |adapter| xdg_surface.shell.xdg_surfaces.get(adapter.id) orelse {
            xdg_surface.wm_base_resource.postError(
                .invalid_popup_parent,
                "xdg_popup parent no longer exists",
            );
            return error.ResourceCreateFailed;
        } else null;
        const scene_parent: ?Scene.PopupParent = if (parent_state) |state| switch (state.role orelse {
            xdg_surface.wm_base_resource.postError(
                .invalid_popup_parent,
                "xdg_popup parent has no role",
            );
            return error.ResourceCreateFailed;
        }) {
            .toplevel => |window_id| window: {
                const window = xdg_surface.shell.windows.get(window_id) orelse
                    return error.ResourceCreateFailed;
                break :window .{ .window = window.scene_id };
            },
            .popup => |popup_id| popup: {
                const parent_popup = xdg_surface.shell.popups.get(popup_id) orelse
                    return error.ResourceCreateFailed;
                const parent_scene_id = parent_popup.scene_id orelse {
                    xdg_surface.wm_base_resource.postError(
                        .invalid_popup_parent,
                        "xdg_popup parent is not attached",
                    );
                    return error.ResourceCreateFailed;
                };
                break :popup .{ .popup = parent_scene_id };
            },
        } else null;
        const rules = Positioner.fromResource(positioner_resource).rules;
        if (!rules.complete()) {
            xdg_surface.wm_base_resource.postError(
                .invalid_positioner,
                "incomplete xdg_positioner",
            );
            return error.ResourceCreateFailed;
        }
        surface.assignReservedRole(.xdg_popup, xdg_surface) catch {
            xdg_surface.resource.postError(.already_constructed, "wl_surface already has a role");
            return error.ResourceCreateFailed;
        };

        const resource = try xdg.Popup.create(
            xdg_surface.resource.getClient(),
            xdg_surface.resource.getVersion(),
            id,
        );
        errdefer resource.destroy();
        const self = xdg_surface.allocator.create(PopupResource) catch
            return error.OutOfMemory;
        errdefer xdg_surface.allocator.destroy(self);
        const scene_id = if (scene_parent) |parent| xdg_surface.shell.scene.addPopup(surface.handle(), parent) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidParent => return error.ResourceCreateFailed,
        } else null;
        errdefer if (scene_id) |scene_popup_id| xdg_surface.shell.scene.removePopup(scene_popup_id);
        const order = xdg_surface.shell.next_popup_order;
        xdg_surface.shell.next_popup_order +%= 1;
        const popup_id = xdg_surface.shell.popups.insert(xdg_surface.allocator, .{
            .xdg_surface_id = xdg_surface.id,
            .parent = if (parent_adapter) |adapter| .{ .xdg_surface = adapter.id } else .unattached,
            .scene_id = scene_id,
            .resource = resource,
            .rules = rules,
            .order = order,
        }) catch return error.OutOfMemory;

        self.* = .{
            .allocator = xdg_surface.allocator,
            .shell = xdg_surface.shell,
            .id = popup_id,
            .xdg_surface_id = xdg_surface.id,
            .xdg_surface_resource = xdg_surface,
        };
        const state = xdg_surface.shell.xdg_surfaces.get(xdg_surface.id) orelse unreachable;
        state.role = .{ .popup = popup_id };
        resource.setHandler(*PopupResource, handleRequest, handleDestroy, self);
    }

    fn handleRequest(
        resource: *xdg.Popup,
        request: xdg.Popup.Request,
        self: *PopupResource,
    ) void {
        const popup = self.shell.popups.get(self.id) orelse return;
        switch (request) {
            .destroy => {
                if (!self.shell.isTopmostPopup(self.id)) {
                    self.xdg_surface_resource.wm_base_resource.postError(
                        .not_the_topmost_popup,
                        "destroy the topmost xdg_popup first",
                    );
                    return;
                }
                resource.destroy();
            },
            .grab => |grab| {
                if (popup.dismissed) return;
                if (popup.mapped) {
                    resource.postError(.invalid_grab, "cannot grab a mapped xdg_popup");
                    return;
                }
                if (popup.grabbed) {
                    self.shell.dismissPopup(self.id);
                    return;
                }
                const parent_role: ?XdgRole = switch (popup.parent) {
                    .unattached => {
                        resource.postError(.invalid_grab, "xdg_popup is not attached");
                        return;
                    },
                    .layer_surface => if (self.shell.scene.layerSurface(popup.parent.layer_surface) != null)
                        null
                    else {
                        resource.postError(.invalid_grab, "layer surface parent no longer exists");
                        return;
                    },
                    .xdg_surface => |parent_id| (self.shell.xdg_surfaces.get(parent_id) orelse {
                        resource.postError(.invalid_grab, "xdg_popup parent no longer exists");
                        return;
                    }).role orelse {
                        resource.postError(.invalid_grab, "xdg_popup parent has no role");
                        return;
                    },
                };
                if (parent_role) |role| switch (role) {
                    .toplevel => if (self.shell.topGrabbedPopup() != null) {
                        resource.postError(.invalid_grab, "another xdg_popup owns the grab");
                        return;
                    },
                    .popup => |parent_id| {
                        const parent_popup = self.shell.popups.get(parent_id) orelse {
                            resource.postError(.invalid_grab, "xdg_popup parent no longer exists");
                            return;
                        };
                        const topmost = self.shell.topGrabbedPopup();
                        if (!parent_popup.grabbed or parent_popup.dismissed or
                            topmost == null or !std.meta.eql(topmost.?, parent_id))
                        {
                            resource.postError(.invalid_grab, "parent xdg_popup does not own a grab");
                            return;
                        }
                    },
                } else if (self.shell.topGrabbedPopup() != null) {
                    resource.postError(.invalid_grab, "another xdg_popup owns the grab");
                    return;
                }
                if (!self.shell.seat.acceptsUserActionSerial(
                    grab.seat,
                    resource.getClient(),
                    grab.serial,
                )) {
                    self.shell.dismissPopup(self.id);
                    return;
                }
                popup.grabbed = true;
            },
            .reposition => |reposition| {
                if (popup.dismissed) return;
                const rules = Positioner.fromResource(reposition.positioner).rules;
                if (!rules.complete()) {
                    self.xdg_surface_resource.wm_base_resource.postError(
                        .invalid_positioner,
                        "incomplete xdg_positioner",
                    );
                    return;
                }
                self.shell.sendPopupConfigure(self.id, rules, reposition.token) catch |err| switch (err) {
                    error.OutOfMemory => resource.postNoMemory(),
                    error.InvalidParent => self.xdg_surface_resource.wm_base_resource.postError(
                        .invalid_popup_parent,
                        "invalid xdg_popup parent",
                    ),
                    error.InvalidPositioner => self.xdg_surface_resource.wm_base_resource.postError(
                        .invalid_positioner,
                        "invalid xdg_popup positioner",
                    ),
                };
            },
        }
    }

    fn handleDestroy(_: *xdg.Popup, self: *PopupResource) void {
        if (self.shell.xdg_surfaces.get(self.xdg_surface_id)) |xdg_surface| {
            xdg_surface.role = null;
            xdg_surface.mapped = false;
            xdg_surface.configured = false;
            xdg_surface.initial_configure_sent = false;
            xdg_surface.last_acked_serial = null;
            xdg_surface.configure_serials.clearRetainingCapacity();
        }
        self.shell.removePopupState(self.id);
        self.allocator.destroy(self);
    }
};

const ToplevelDecorationResource = struct {
    allocator: std.mem.Allocator,
    shell: *Self,
    resource: *zxdg.ToplevelDecorationV1,
    toplevel: ?*ToplevelResource,
    configure_sent: bool = false,

    fn create(
        shell: *Self,
        manager: *zxdg.DecorationManagerV1,
        toplevel_resource: *xdg.Toplevel,
        id: u32,
    ) error{ OutOfMemory, ResourceCreateFailed }!void {
        const resource = try zxdg.ToplevelDecorationV1.create(
            manager.getClient(),
            manager.getVersion(),
            id,
        );
        errdefer resource.destroy();

        const data = toplevel_resource.getUserData() orelse {
            resource.postError(.orphaned, "xdg_toplevel no longer exists");
            return;
        };
        const toplevel: *ToplevelResource = @ptrCast(@alignCast(data));
        if (toplevel.shell != shell or toplevel_resource.getClient() != manager.getClient()) {
            resource.postError(.orphaned, "xdg_toplevel belongs to another client");
            return;
        }
        if (toplevel.decoration != null) {
            resource.postError(.already_constructed, "xdg_toplevel already has a decoration object");
            return;
        }
        if (resource.getVersion() == 1) {
            const surface = toplevel.xdg_surface_resource.surface;
            if (surface == null or surface.?.hasBufferAttachedOrCommitted()) {
                resource.postError(
                    .unconfigured_buffer,
                    "version 1 decoration created after a buffer was attached",
                );
                return;
            }
        }

        const self = shell.allocator.create(ToplevelDecorationResource) catch
            return error.OutOfMemory;
        self.* = .{
            .allocator = shell.allocator,
            .shell = shell,
            .resource = resource,
            .toplevel = toplevel,
        };
        toplevel.decoration = self;
        if (shell.windows.get(toplevel.id)) |window| {
            window.decoration_preference = .no_preference;
            window.decoration_configure_requested = true;
        }
        const externally_managed = self.notifyMetadataChanged();
        if (!externally_managed) self.configureStandalone();
        resource.setHandler(
            *ToplevelDecorationResource,
            handleRequest,
            handleDestroy,
            self,
        );
    }

    fn handleRequest(
        resource: *zxdg.ToplevelDecorationV1,
        request: zxdg.ToplevelDecorationV1.Request,
        self: *ToplevelDecorationResource,
    ) void {
        if (self.toplevel == null and request != .destroy) {
            resource.postError(.orphaned, "xdg_toplevel was destroyed");
            return;
        }
        switch (request) {
            .destroy => resource.destroy(),
            .set_mode => |set| self.setPreference(switch (set.mode) {
                .client_side => .prefers_csd,
                .server_side => .prefers_ssd,
                else => {
                    resource.postError(.invalid_mode, "invalid decoration mode");
                    return;
                },
            }),
            .unset_mode => self.setPreference(.no_preference),
        }
    }

    fn setPreference(self: *ToplevelDecorationResource, preference: DecorationPreference) void {
        const toplevel = self.toplevel orelse return;
        const window = self.shell.windows.get(toplevel.id) orelse return;
        window.decoration_preference = preference;
        window.decoration_configure_requested = true;
        const externally_managed = self.notifyMetadataChanged();
        if (!externally_managed) self.configureStandalone();
    }

    fn notifyMetadataChanged(self: *ToplevelDecorationResource) bool {
        const toplevel = self.toplevel orelse return false;
        return self.shell.notifyWindowMetadataChanged(toplevel.id);
    }

    fn configureStandalone(self: *ToplevelDecorationResource) void {
        const toplevel = self.toplevel orelse return;
        const window = self.shell.windows.get(toplevel.id) orelse return;
        if (!window.ready) return;
        const state = self.shell.xdg_surfaces.get(toplevel.xdg_surface_id) orelse return;
        if (!state.initial_configure_sent) return;
        const dimensions: Dimensions = if (self.shell.contentGeometry(state)) |geometry| .{
            .width = @intCast(geometry.size.width),
            .height = @intCast(geometry.size.height),
        } else .{ .width = 0, .height = 0 };
        _ = self.shell.configureWindowState(toplevel.id, dimensions, .{}) catch |err| switch (err) {
            error.OutOfMemory => self.resource.postNoMemory(),
            error.InvalidWindow => {},
        };
    }

    fn handleDestroy(_: *zxdg.ToplevelDecorationV1, self: *ToplevelDecorationResource) void {
        if (self.toplevel) |toplevel| {
            toplevel.decoration = null;
            if (self.shell.windows.get(toplevel.id)) |window| {
                window.decoration_preference = .only_csd;
                window.decoration_configure_requested = false;
            }
            _ = self.notifyMetadataChanged();
        }
        self.allocator.destroy(self);
    }
};

const ToplevelResource = struct {
    allocator: std.mem.Allocator,
    shell: *Self,
    id: WindowId,
    xdg_surface_id: XdgSurfaceId,
    xdg_surface_resource: *XdgSurfaceResource,
    decoration: ?*ToplevelDecorationResource,

    fn create(
        xdg_surface: *XdgSurfaceResource,
        id: u32,
    ) error{ OutOfMemory, ResourceCreateFailed }!void {
        const surface = xdg_surface.surface orelse return error.ResourceCreateFailed;
        surface.assignReservedRole(.xdg_toplevel, xdg_surface) catch {
            xdg_surface.resource.postError(.already_constructed, "wl_surface already has a role");
            return;
        };

        const resource = try xdg.Toplevel.create(
            xdg_surface.resource.getClient(),
            xdg_surface.resource.getVersion(),
            id,
        );
        errdefer resource.destroy();

        const self = xdg_surface.allocator.create(ToplevelResource) catch
            return error.OutOfMemory;
        errdefer xdg_surface.allocator.destroy(self);

        const scene_id = xdg_surface.shell.scene.addWindow(surface.handle()) catch
            return error.OutOfMemory;
        errdefer xdg_surface.shell.scene.removeWindow(scene_id);
        const window_id = xdg_surface.shell.windows.insert(xdg_surface.allocator, .{
            .xdg_surface_id = xdg_surface.id,
            .scene_id = scene_id,
            .unreliable_pid = @intCast(resource.getClient().getCredentials().pid),
        }) catch return error.OutOfMemory;

        self.* = .{
            .allocator = xdg_surface.allocator,
            .shell = xdg_surface.shell,
            .id = window_id,
            .xdg_surface_id = xdg_surface.id,
            .xdg_surface_resource = xdg_surface,
            .decoration = null,
        };
        const state = xdg_surface.shell.xdg_surfaces.get(xdg_surface.id) orelse unreachable;
        state.role = .{ .toplevel = window_id };
        state.toplevel_resource = resource;
        xdg_surface.toplevel_resource = resource;
        resource.setHandler(*ToplevelResource, handleRequest, handleDestroy, self);
    }

    fn handleRequest(
        resource: *xdg.Toplevel,
        request: xdg.Toplevel.Request,
        self: *ToplevelResource,
    ) void {
        const window = self.shell.windows.get(self.id) orelse return;
        switch (request) {
            .destroy => resource.destroy(),
            .set_parent => |set| self.setParent(resource, set.parent),
            .set_title => |set| self.setText(resource, &window.title, set.title),
            .set_app_id => |set| self.setText(resource, &window.app_id, set.app_id),
            .set_max_size => |set| window.pending_max_size = .{
                .width = set.width,
                .height = set.height,
            },
            .set_min_size => |set| window.pending_min_size = .{
                .width = set.width,
                .height = set.height,
            },
            .show_window_menu => |menu| {
                if (!self.acceptsUserAction(resource, menu.seat, menu.serial)) return;
                self.forwardRequest(.{ .show_window_menu = .{
                    .x = menu.x,
                    .y = menu.y,
                } });
            },
            .move => |move| {
                if (!self.acceptsUserAction(resource, move.seat, move.serial)) return;
                self.forwardRequest(.pointer_move);
            },
            .resize => |resize| {
                if (!validResizeEdge(resize.edges)) {
                    resource.postError(.invalid_resize_edge, "invalid resize edge");
                    return;
                }
                const edges = resizeEdges(resize.edges);
                if (@as(u4, @bitCast(edges)) == 0) return;
                if (!self.acceptsUserAction(resource, resize.seat, resize.serial)) return;
                self.forwardRequest(.{ .pointer_resize = edges });
            },
            .set_maximized => {
                window.requestMaximized(true);
                self.forwardRequest(.maximize);
            },
            .unset_maximized => {
                window.requestMaximized(false);
                self.forwardRequest(.unmaximize);
            },
            .set_fullscreen => |fullscreen| {
                window.requestFullscreen(true, if (fullscreen.output) |output|
                    if (self.shell.outputs.findResource(output)) |entry| entry.id else null
                else
                    null);
                self.forwardRequest(.{ .fullscreen = fullscreen.output });
            },
            .unset_fullscreen => {
                window.requestFullscreen(false, null);
                self.forwardRequest(.exit_fullscreen);
            },
            .set_minimized => {
                window.requestMinimized(true);
                self.forwardRequest(.minimize);
            },
        }
    }

    fn forwardRequest(self: *ToplevelResource, request: WindowRequest) void {
        const window = self.shell.windows.get(self.id) orelse return;
        if (!window.ready) return;
        self.shell.requestWindow(self.id, request);
    }

    fn acceptsUserAction(
        self: *ToplevelResource,
        resource: *xdg.Toplevel,
        seat: *wl.Seat,
        serial: u32,
    ) bool {
        return self.shell.seat.acceptsUserActionSerial(seat, resource.getClient(), serial);
    }

    fn handleDestroy(_: *xdg.Toplevel, self: *ToplevelResource) void {
        if (self.decoration) |decoration| {
            decoration.toplevel = null;
            decoration.resource.postError(
                .orphaned,
                "destroy xdg_toplevel_decoration before xdg_toplevel",
            );
        }
        self.shell.dismissPopupsForParent(self.xdg_surface_id);
        if (self.shell.xdg_surfaces.get(self.xdg_surface_id)) |xdg_surface| {
            xdg_surface.role = null;
            xdg_surface.mapped = false;
            xdg_surface.configured = false;
            xdg_surface.initial_configure_sent = false;
            xdg_surface.sent_capabilities = null;
            xdg_surface.sent_bounds = null;
            xdg_surface.last_acked_serial = null;
            xdg_surface.configure_serials.clearRetainingCapacity();
            xdg_surface.toplevel_resource = null;
            self.xdg_surface_resource.toplevel_resource = null;
        }
        if (self.shell.windows.remove(self.id)) |window_value| {
            self.shell.clearParentReferences(self.id);
            self.shell.notifyWindowDestroyed(self.id);
            var window = window_value;
            self.shell.scene.removeWindow(window.scene_id);
            window.deinit(self.allocator);
        }
        self.allocator.destroy(self);
    }

    fn setText(
        self: *ToplevelResource,
        resource: *xdg.Toplevel,
        destination: *?[:0]u8,
        source_z: [*:0]const u8,
    ) void {
        const source = std.mem.span(source_z);
        if (!std.unicode.utf8ValidateSlice(source)) {
            resource.getClient().postImplementationError("xdg_toplevel string is not valid UTF-8");
            return;
        }
        const copy = self.allocator.dupeSentinel(u8, source, 0) catch {
            resource.postNoMemory();
            return;
        };
        if (destination.*) |old| self.allocator.free(old);
        destination.* = copy;
        _ = self.shell.notifyWindowMetadataChanged(self.id);
    }

    fn setParent(
        self: *ToplevelResource,
        resource: *xdg.Toplevel,
        parent_resource: ?*xdg.Toplevel,
    ) void {
        const window = self.shell.windows.get(self.id) orelse return;
        const parent_id = if (parent_resource) |parent| parent: {
            const adapter: *ToplevelResource = @ptrCast(@alignCast(parent.getUserData().?));
            const parent_window = self.shell.windows.get(adapter.id) orelse break :parent null;
            if (!parent_window.mapped) break :parent null;
            break :parent adapter.id;
        } else null;

        var ancestor = parent_id;
        while (ancestor) |candidate| {
            if (std.meta.eql(candidate, self.id)) {
                resource.postError(.invalid_parent, "xdg_toplevel parent cycle");
                return;
            }
            const candidate_window = self.shell.windows.get(candidate) orelse break;
            ancestor = candidate_window.parent;
        }
        window.parent = parent_id;
        window.parent_owner = null;
        _ = self.shell.notifyWindowMetadataChanged(self.id);
    }

    fn validSizeHints(minimum: SizeHint, maximum: SizeHint) bool {
        if (minimum.width < 0 or minimum.height < 0 or
            maximum.width < 0 or maximum.height < 0)
        {
            return false;
        }
        if (maximum.width != 0 and minimum.width != 0 and maximum.width < minimum.width) {
            return false;
        }
        if (maximum.height != 0 and minimum.height != 0 and maximum.height < minimum.height) {
            return false;
        }
        return true;
    }

    fn validResizeEdge(edge: xdg.Toplevel.ResizeEdge) bool {
        return switch (edge) {
            .none,
            .top,
            .bottom,
            .left,
            .top_left,
            .bottom_left,
            .right,
            .top_right,
            .bottom_right,
            => true,
            else => false,
        };
    }

    fn resizeEdges(edge: xdg.Toplevel.ResizeEdge) ResizeEdges {
        return switch (edge) {
            .none => .{},
            .top => .{ .top = true },
            .bottom => .{ .bottom = true },
            .left => .{ .left = true },
            .top_left => .{ .top = true, .left = true },
            .bottom_left => .{ .bottom = true, .left = true },
            .right => .{ .right = true },
            .top_right => .{ .top = true, .right = true },
            .bottom_right => .{ .bottom = true, .right = true },
            else => unreachable,
        };
    }
};

fn placePopup(
    rules: PositionerRules,
    parent_position: Scene.Position,
    output_bounds: render.Rect,
) PopupPlacement {
    const size = rules.size.?;
    var width: i64 = size.width;
    var height: i64 = size.height;
    const parent_x: i64 = parent_position.x;
    const parent_y: i64 = parent_position.y;
    const output_left: i64 = output_bounds.x;
    const output_top: i64 = output_bounds.y;
    const output_right = output_left + output_bounds.width;
    const output_bottom = output_top + output_bounds.height;
    const local = popupPosition(rules, false, false);
    var global_x = parent_x + local.x;
    var global_y = parent_y + local.y;

    if (rules.adjustment.flip_x and axisConstrained(global_x, width, output_left, output_right)) {
        const flipped = popupPosition(rules, true, false);
        const flipped_global = parent_x + flipped.x;
        if (!axisConstrained(flipped_global, width, output_left, output_right)) {
            global_x = flipped_global;
        }
    }
    if (rules.adjustment.flip_y and axisConstrained(global_y, height, output_top, output_bottom)) {
        const flipped = popupPosition(rules, false, true);
        const flipped_global = parent_y + flipped.y;
        if (!axisConstrained(flipped_global, height, output_top, output_bottom)) {
            global_y = flipped_global;
        }
    }

    if (rules.adjustment.slide_x and axisConstrained(global_x, width, output_left, output_right)) {
        global_x = std.math.clamp(global_x, output_left, @max(output_right - width, output_left));
    }
    if (rules.adjustment.slide_y and axisConstrained(global_y, height, output_top, output_bottom)) {
        global_y = std.math.clamp(global_y, output_top, @max(output_bottom - height, output_top));
    }

    if (rules.adjustment.resize_x and axisConstrained(global_x, width, output_left, output_right)) {
        const left = std.math.clamp(global_x, output_left, @max(output_right - 1, output_left));
        const right = std.math.clamp(global_x + width, left + 1, @max(output_right, left + 1));
        global_x = left;
        width = right - left;
    }
    if (rules.adjustment.resize_y and axisConstrained(global_y, height, output_top, output_bottom)) {
        const top = std.math.clamp(global_y, output_top, @max(output_bottom - 1, output_top));
        const bottom = std.math.clamp(global_y + height, top + 1, @max(output_bottom, top + 1));
        global_y = top;
        height = bottom - top;
    }

    return .{
        .position = .{
            .x = clampI32(global_x - parent_x),
            .y = clampI32(global_y - parent_y),
        },
        .dimensions = .{
            .width = @intCast(@min(width, std.math.maxInt(i32))),
            .height = @intCast(@min(height, std.math.maxInt(i32))),
        },
    };
}

const Position64 = struct {
    x: i64,
    y: i64,
};

fn popupPosition(rules: PositionerRules, flip_x: bool, flip_y: bool) Position64 {
    const anchor_rect = rules.anchor_rect.?;
    const size = rules.size.?;
    const anchor = flipAnchor(rules.anchor, flip_x, flip_y);
    const gravity = flipGravity(rules.gravity, flip_x, flip_y);
    const anchor_x = switch (anchor) {
        .left, .top_left, .bottom_left => @as(i64, anchor_rect.x),
        .right, .top_right, .bottom_right => @as(i64, anchor_rect.x) + anchor_rect.width,
        else => @as(i64, anchor_rect.x) + @divTrunc(@as(i64, anchor_rect.width), 2),
    };
    const anchor_y = switch (anchor) {
        .top, .top_left, .top_right => @as(i64, anchor_rect.y),
        .bottom, .bottom_left, .bottom_right => @as(i64, anchor_rect.y) + anchor_rect.height,
        else => @as(i64, anchor_rect.y) + @divTrunc(@as(i64, anchor_rect.height), 2),
    };
    const x = switch (gravity) {
        .left, .top_left, .bottom_left => anchor_x - size.width,
        .right, .top_right, .bottom_right => anchor_x,
        else => anchor_x - @divTrunc(@as(i64, size.width), 2),
    };
    const y = switch (gravity) {
        .top, .top_left, .top_right => anchor_y - size.height,
        .bottom, .bottom_left, .bottom_right => anchor_y,
        else => anchor_y - @divTrunc(@as(i64, size.height), 2),
    };
    return .{
        .x = x + rules.offset.x,
        .y = y + rules.offset.y,
    };
}

fn flipAnchor(
    anchor: xdg.Positioner.Anchor,
    flip_x: bool,
    flip_y: bool,
) xdg.Positioner.Anchor {
    var result = anchor;
    if (flip_x) result = switch (result) {
        .left => .right,
        .right => .left,
        .top_left => .top_right,
        .top_right => .top_left,
        .bottom_left => .bottom_right,
        .bottom_right => .bottom_left,
        else => result,
    };
    if (flip_y) result = switch (result) {
        .top => .bottom,
        .bottom => .top,
        .top_left => .bottom_left,
        .bottom_left => .top_left,
        .top_right => .bottom_right,
        .bottom_right => .top_right,
        else => result,
    };
    return result;
}

fn flipGravity(
    gravity: xdg.Positioner.Gravity,
    flip_x: bool,
    flip_y: bool,
) xdg.Positioner.Gravity {
    var result = gravity;
    if (flip_x) result = switch (result) {
        .left => .right,
        .right => .left,
        .top_left => .top_right,
        .top_right => .top_left,
        .bottom_left => .bottom_right,
        .bottom_right => .bottom_left,
        else => result,
    };
    if (flip_y) result = switch (result) {
        .top => .bottom,
        .bottom => .top,
        .top_left => .bottom_left,
        .bottom_left => .top_left,
        .top_right => .bottom_right,
        .bottom_right => .top_right,
        else => result,
    };
    return result;
}

fn axisConstrained(position: i64, size: i64, minimum: i64, maximum: i64) bool {
    return position < minimum or position + size > maximum;
}

fn clampI32(value: i64) i32 {
    return @intCast(std.math.clamp(
        value,
        @as(i64, std.math.minInt(i32)),
        @as(i64, std.math.maxInt(i32)),
    ));
}

test "xdg toplevel states are gated by protocol version" {
    const configuration: ToplevelConfigure = .{
        .suspended = true,
        .constrained = .{
            .top = true,
            .bottom = true,
            .left = true,
            .right = true,
        },
    };
    var values: [13]u32 = undefined;

    try std.testing.expectEqualSlices(u32, &.{}, toplevelStates(configuration, 5, &values));
    try std.testing.expectEqualSlices(u32, &.{
        @intFromEnum(xdg.Toplevel.State.suspended),
    }, toplevelStates(configuration, 6, &values));
    try std.testing.expectEqualSlices(u32, &.{
        @intFromEnum(xdg.Toplevel.State.suspended),
        @intFromEnum(xdg.Toplevel.State.constrained_left),
        @intFromEnum(xdg.Toplevel.State.constrained_right),
        @intFromEnum(xdg.Toplevel.State.constrained_top),
        @intFromEnum(xdg.Toplevel.State.constrained_bottom),
    }, toplevelStates(configuration, 7, &values));
}

test "xdg size hints validate committed bounds" {
    try std.testing.expect(ToplevelResource.validSizeHints(
        .{ .width = 50, .height = 50 },
        .{ .width = 100, .height = 100 },
    ));
    try std.testing.expect(!ToplevelResource.validSizeHints(
        .{ .width = 50, .height = 50 },
        .{ .width = 40, .height = 100 },
    ));
    try std.testing.expect(!ToplevelResource.validSizeHints(
        .{ .width = -1, .height = 0 },
        .{},
    ));
    try std.testing.expect(!ToplevelResource.validSizeHints(
        .{},
        .{ .width = 0, .height = -1 },
    ));
}

test "xdg resize edges translate to independent policy edge flags" {
    try std.testing.expectEqual(
        ResizeEdges{ .top = true, .left = true },
        ToplevelResource.resizeEdges(.top_left),
    );
    try std.testing.expectEqual(
        ResizeEdges{ .bottom = true, .right = true },
        ToplevelResource.resizeEdges(.bottom_right),
    );
    try std.testing.expectEqual(ResizeEdges{}, ToplevelResource.resizeEdges(.none));
}

test "xdg pixel-only window commits do not notify policy" {
    const dimensions: Dimensions = .{ .width = 800, .height = 600 };

    try std.testing.expect(windowCommitNeedsNotification(false, null, null, dimensions));
    try std.testing.expect(windowCommitNeedsNotification(true, 42, dimensions, dimensions));
    try std.testing.expect(windowCommitNeedsNotification(
        true,
        null,
        dimensions,
        .{ .width = 801, .height = 600 },
    ));
    try std.testing.expect(!windowCommitNeedsNotification(true, null, dimensions, dimensions));
}

test "toplevel icon assignment is applied on commit and can be reset" {
    const allocator = std.testing.allocator;
    var window: WindowState = .{
        .xdg_surface_id = undefined,
        .scene_id = undefined,
        .unreliable_pid = 0,
    };
    defer window.deinit(allocator);

    window.pending_icon = .{
        .name = try allocator.dupeSentinel(u8, "document", 0),
        .buffers = try allocator.alloc(ToplevelIconBuffer, 0),
    };
    window.pending_icon_changed = true;
    try std.testing.expect(window.icon == null);
    try std.testing.expect(window.commit(allocator));
    try std.testing.expectEqualStrings("document", window.icon.?.name.?);

    window.pending_icon_changed = true;
    try std.testing.expect(window.commit(allocator));
    try std.testing.expect(window.icon == null);
}

test "xdg state requests survive initial setup and reset on unmap" {
    const allocator = std.testing.allocator;
    var window: WindowState = .{
        .xdg_surface_id = undefined,
        .scene_id = undefined,
        .unreliable_pid = 0,
    };
    defer window.deinit(allocator);

    const output: OutputLayout.Id = .{ .index = 3, .generation = 2 };
    window.requestMaximized(true);
    window.requestFullscreen(true, output);
    window.requestMinimized(true);
    try std.testing.expect(window.requested_state.maximized);
    try std.testing.expect(window.requested_state.fullscreen);
    try std.testing.expectEqual(output, window.requested_state.fullscreen_output.?);
    try std.testing.expect(window.requested_state.minimized);

    window.reset(allocator);
    try std.testing.expectEqual(WindowRequestState{}, window.requested_state);
}

test "xdg positioner derives popup geometry from anchor and gravity" {
    const placement = placePopup(.{
        .size = .{ .width = 120, .height = 80 },
        .anchor_rect = .{ .x = 10, .y = 20, .width = 30, .height = 40 },
        .anchor = .bottom_left,
        .gravity = .bottom_right,
        .offset = .{ .x = 3, .y = 4 },
    }, .{ .x = 100, .y = 50 }, .{ .x = 0, .y = 0, .width = 1280, .height = 720 });

    try std.testing.expectEqual(Scene.Position{ .x = 13, .y = 64 }, placement.position);
    try std.testing.expectEqual(Dimensions{ .width = 120, .height = 80 }, placement.dimensions);
}

test "xdg positioner flips before sliding constrained popups" {
    const placement = placePopup(.{
        .size = .{ .width = 200, .height = 100 },
        .anchor_rect = .{ .x = 80, .y = 20, .width = 20, .height = 20 },
        .anchor = .right,
        .gravity = .right,
        .adjustment = .{ .flip_x = true, .slide_y = true },
    }, .{ .x = 2430, .y = 450 }, .{ .x = 1280, .y = -200, .width = 1280, .height = 720 });

    try std.testing.expectEqual(Scene.Position{ .x = -120, .y = -30 }, placement.position);
    try std.testing.expectEqual(Dimensions{ .width = 200, .height = 100 }, placement.dimensions);
}

test "xdg positioner resizes a popup to the output boundary" {
    const placement = placePopup(.{
        .size = .{ .width = 400, .height = 300 },
        .anchor_rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 },
        .anchor = .top_left,
        .gravity = .bottom_right,
        .adjustment = .{ .resize_x = true, .resize_y = true },
    }, .{}, .{ .x = 0, .y = 0, .width = 320, .height = 200 });

    try std.testing.expectEqual(Scene.Position{}, placement.position);
    try std.testing.expectEqual(Dimensions{ .width = 320, .height = 200 }, placement.dimensions);
}
