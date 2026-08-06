//! Resource-free semantic owner for XDG surfaces, windows, and popups.

const XdgShell = @This();

const std = @import("std");
const slot_map = @import("slot_map.zig");
const render = @import("render/types.zig");
const Scene = @import("scene.zig");
const SurfaceRegistry = @import("SurfaceRegistry.zig");
const ClientRegistry = @import("ClientRegistry.zig");
const OutputLayout = @import("output_layout.zig");
const popup_placement = @import("xdg_popup_placement.zig");

const XdgSurfaceStore = slot_map.SlotMap(XdgSurfaceState, enum { xdg_surface });
pub const XdgSurfaceId = XdgSurfaceStore.Id;
const WindowStore = slot_map.SlotMap(WindowState, enum { window });
pub const WindowId = WindowStore.Id;
const PopupStore = slot_map.SlotMap(PopupState, enum { popup });
pub const PopupId = PopupStore.Id;

pub const ConfigureToken = struct { surface: XdgSurfaceId, sequence: u64 };
pub const Geometry = struct { x: i32, y: i32, width: i32, height: i32 };
pub const Dimensions = struct { width: i32, height: i32 };
pub const SizeHint = struct { width: i32 = 0, height: i32 = 0 };
pub const TiledEdges = packed struct(u8) { top: bool = false, bottom: bool = false, left: bool = false, right: bool = false, _padding: u4 = 0 };
pub const ConstrainedEdges = packed struct(u8) { top: bool = false, bottom: bool = false, left: bool = false, right: bool = false, _padding: u4 = 0 };
pub const WindowCapabilities = packed struct(u8) { window_menu: bool = true, maximize: bool = true, fullscreen: bool = true, minimize: bool = true, _padding: u4 = 0 };
pub const DecorationMode = enum { client_side, server_side };
pub const DecorationPreference = enum { only_csd, prefers_csd, prefers_ssd, no_preference };
pub const ResizeEdges = packed struct(u4) { top: bool = false, bottom: bool = false, left: bool = false, right: bool = false };
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
pub const WindowRequestState = struct {
    maximized: bool = false,
    fullscreen: bool = false,
    fullscreen_output: ?OutputLayout.Id = null,
    minimized: bool = false,
};
pub const UserAction = struct {
    client: ClientRegistry.Id,
    serial: ?ClientRegistry.Serial,
    granted: bool,
};

pub const WindowRequest = union(enum) {
    pointer_move: UserAction,
    pointer_resize: struct {
        action: UserAction,
        edges: ResizeEdges,
    },
    show_window_menu: struct {
        action: UserAction,
        x: i32,
        y: i32,
    },
    maximize,
    unmaximize,
    fullscreen: ?OutputLayout.Id,
    exit_fullscreen,
    minimize,
    unminimize,
    activate: UserAction,
};

pub const Anchor = popup_placement.Anchor;
pub const Gravity = popup_placement.Gravity;
pub const ConstraintAdjustment = popup_placement.ConstraintAdjustment;
pub const Rules = popup_placement.Rules;
pub const Placement = popup_placement.Placement;
pub const PopupConfigure = struct {
    rules: Rules,
    placement: Placement,
};

pub const AcceptedConfigure = struct {
    token: ConfigureToken,
    popup: ?PopupConfigure = null,
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

pub const ToplevelTagField = enum { tag, description };

pub const WindowInfo = struct {
    scene_id: Scene.Id,
    client: ClientRegistry.Id,
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
    scene_presentation_enabled: bool,
    interaction_enabled: bool,
    requested_state: WindowRequestState,
};

/// The adapter owns this stable context while the corresponding neutral XDG
/// surface exists. Calls are synchronous and retain no borrowed values.
pub const SurfaceEndpoint = struct {
    context: *anyopaque,
    configure_toplevel: *const fn (
        *anyopaque,
        Dimensions,
        ToplevelConfigure,
        ConfigureToken,
    ) error{OutOfMemory}!void,
    configure_popup: *const fn (
        *anyopaque,
        PopupConfigure,
        ConfigureToken,
    ) error{OutOfMemory}!void,
    close: *const fn (*anyopaque) void,
    popup_done: *const fn (*anyopaque) void,
    report_failure: *const fn (*anyopaque, EndpointFailure) void,
};

pub const EndpointFailure = enum { no_memory, invalid_positioner };

/// Frontend-neutral queries required by semantic geometry policy.
/// The context remains valid for the lifetime of this XDG shell.
pub const Environment = struct {
    context: *anyopaque,
    subtree_geometry: *const fn (*anyopaque, SurfaceRegistry.Id) ?Geometry,
    surface_size: *const fn (*anyopaque, SurfaceRegistry.Id) ?render.Size,
    popup_output_bounds: *const fn (
        *anyopaque,
        Scene.Position,
        render.Size,
        OutputLayout.Id,
    ) ?render.Rect,
};
pub const WindowListener = struct {
    context: *anyopaque,
    ready: *const fn (*anyopaque, WindowId) bool,
    committed: *const fn (*anyopaque, WindowId, ?ConfigureToken) bool,
    unmapping: *const fn (*anyopaque, WindowId) void,
    unmapped: *const fn (*anyopaque, WindowId) void,
    destroyed: *const fn (*anyopaque, WindowId) void,
    metadata_changed: *const fn (*anyopaque, WindowId) bool,
    presentation_changed: *const fn (
        *anyopaque,
        WindowId,
        bool,
    ) error{OutOfMemory}!void,
    interaction_changed: *const fn (*anyopaque, WindowId, bool) void,
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

pub const Role = union(enum) {
    toplevel: WindowId,
    popup: PopupId,
};

const XdgSurfaceState = struct {
    surface_id: SurfaceRegistry.Id,
    client: ClientRegistry.Id,
    endpoint: SurfaceEndpoint,
    role: ?Role = null,
    geometry: ?Geometry = null,
    mapped: bool = false,
    configured: bool = false,
    initial_configure_sent: bool = false,
    next_sequence: u64 = 1,
    fn nextToken(
        self: *XdgSurfaceState,
        id: XdgSurfaceId,
    ) error{ConfigureSequenceExhausted}!ConfigureToken {
        if (self.next_sequence == 0 or self.next_sequence == std.math.maxInt(u64)) {
            return error.ConfigureSequenceExhausted;
        }
        return .{ .surface = id, .sequence = self.next_sequence };
    }

    fn consumeToken(self: *XdgSurfaceState, token: ConfigureToken) void {
        std.debug.assert(token.sequence == self.next_sequence);
        self.next_sequence += 1;
    }
};
const WindowState = struct {
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
    requested_scene_visibility: bool = true,
    scene_presentation_enabled: bool = true,
    interaction_enabled: bool = true,
    requested_state: WindowRequestState = .{},
    fn deinit(self: *WindowState, a: std.mem.Allocator) void {
        if (self.title) |v| a.free(v);
        if (self.app_id) |v| a.free(v);
        if (self.tag) |v| a.free(v);
        if (self.description) |v| a.free(v);
        if (self.icon) |*v| v.deinit(a);
        if (self.pending_icon) |*v| v.deinit(a);
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
        if (self.title) |value| allocator.free(value);
        if (self.app_id) |value| allocator.free(value);
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
        self.requested_scene_visibility = false;
        self.requested_state = .{};
    }

    fn requestMaximized(self: *WindowState, value: bool) void {
        self.requested_state.maximized = value;
    }

    fn requestFullscreen(self: *WindowState, value: bool, output: ?OutputLayout.Id) void {
        self.requested_state.fullscreen = value;
        self.requested_state.fullscreen_output = if (value) output else null;
    }

    fn requestMinimized(self: *WindowState, value: bool) void {
        self.requested_state.minimized = value;
    }
};
const PopupParent = union(enum) {
    unattached,
    xdg_surface: XdgSurfaceId,
    layer_surface: Scene.LayerSurfaceId,
};

const PopupState = struct {
    xdg_surface_id: XdgSurfaceId,
    parent: PopupParent,
    scene_id: ?Scene.PopupId,
    rules: Rules,
    ready: bool = false,
    mapped: bool = false,
    scene_presentation_enabled: bool = true,
    grabbed: bool = false,
    dismissed: bool = false,
    order: u64,
    client: ClientRegistry.Id,
};

allocator: std.mem.Allocator,
scene: *Scene,
environment: Environment,
default_output_id: OutputLayout.Id,
xdg_surfaces: XdgSurfaceStore = .{},
windows: WindowStore = .{},
popups: PopupStore = .{},
next_popup_order: u64 = 0,
window_listener: ?WindowListener = null,
window_observers: std.ArrayList(WindowObserver) = .empty,
notifying_window_observers: bool = false,

pub fn init(
    allocator: std.mem.Allocator,
    scene: *Scene,
    environment: Environment,
    default_output_id: OutputLayout.Id,
) XdgShell {
    return .{
        .allocator = allocator,
        .scene = scene,
        .environment = environment,
        .default_output_id = default_output_id,
    };
}

pub fn deinit(self: *XdgShell) void {
    std.debug.assert(self.window_listener == null);
    std.debug.assert(self.window_observers.items.len == 0);
    std.debug.assert(self.xdg_surfaces.len() == 0);
    std.debug.assert(self.windows.len() == 0);
    std.debug.assert(self.popups.len() == 0);
    self.xdg_surfaces.deinit(self.allocator);
    self.windows.deinit(self.allocator);
    self.popups.deinit(self.allocator);
    self.window_observers.deinit(self.allocator);
    self.* = undefined;
}

pub fn createSurface(
    self: *XdgShell,
    surface: SurfaceRegistry.Id,
    client: ClientRegistry.Id,
    endpoint: SurfaceEndpoint,
) error{OutOfMemory}!XdgSurfaceId {
    return self.xdg_surfaces.insert(self.allocator, .{
        .surface_id = surface,
        .client = client,
        .endpoint = endpoint,
    });
}

pub fn removeSurface(self: *XdgShell, id: XdgSurfaceId) void {
    const state = self.xdg_surfaces.get(id) orelse return;
    std.debug.assert(state.role == null);
    _ = self.xdg_surfaces.remove(id) orelse unreachable;
}

pub fn createToplevel(
    self: *XdgShell,
    id: XdgSurfaceId,
    pid: i32,
) error{ InvalidSurface, RoleAssigned, OutOfMemory }!WindowId {
    const state = self.xdg_surfaces.get(id) orelse return error.InvalidSurface;
    if (state.role != null) return error.RoleAssigned;
    const scene_id = try self.scene.addWindow(state.surface_id);
    errdefer self.scene.removeWindow(scene_id);
    const window = try self.windows.insert(self.allocator, .{
        .xdg_surface_id = id,
        .scene_id = scene_id,
        .unreliable_pid = pid,
    });
    state.role = .{ .toplevel = window };
    return window;
}

pub const PopupValidationError = error{
    InvalidSurface,
    RoleAssigned,
    InvalidParent,
    ParentMissingRole,
    ParentUnattached,
    InvalidPositioner,
};

pub fn validatePopup(
    self: *XdgShell,
    id: XdgSurfaceId,
    parent: ?XdgSurfaceId,
    rules: Rules,
) PopupValidationError!void {
    if (!rules.complete()) return error.InvalidPositioner;
    const state = self.xdg_surfaces.get(id) orelse return error.InvalidSurface;
    if (state.role != null) return error.RoleAssigned;
    _ = try self.popupSceneParent(id, parent);
}

pub fn validatePopupParent(
    self: *XdgShell,
    id: XdgSurfaceId,
    parent: ?XdgSurfaceId,
) PopupValidationError!void {
    _ = self.xdg_surfaces.get(id) orelse return error.InvalidSurface;
    _ = try self.popupSceneParent(id, parent);
}

fn popupSceneParent(
    self: *XdgShell,
    id: XdgSurfaceId,
    parent: ?XdgSurfaceId,
) PopupValidationError!?Scene.PopupParent {
    const state = self.xdg_surfaces.get(id) orelse return error.InvalidSurface;
    if (parent) |parent_id| {
        const parent_state = self.xdg_surfaces.get(parent_id) orelse
            return error.InvalidParent;
        if (std.meta.eql(id, parent_id) or !std.meta.eql(state.client, parent_state.client)) {
            return error.InvalidParent;
        }
        const scene_parent: Scene.PopupParent = switch (parent_state.role orelse
            return error.ParentMissingRole) {
            .toplevel => |window_id| .{
                .window = (self.windows.get(window_id) orelse
                    return error.InvalidParent).scene_id,
            },
            .popup => |popup_id| .{
                .popup = (self.popups.get(popup_id) orelse
                    return error.InvalidParent).scene_id orelse return error.ParentUnattached,
            },
        };
        return scene_parent;
    }
    return null;
}

pub fn createPopup(
    self: *XdgShell,
    id: XdgSurfaceId,
    parent: ?XdgSurfaceId,
    rules: Rules,
) (PopupValidationError || error{ OutOfMemory, PopupOrderExhausted })!PopupId {
    if (self.next_popup_order == std.math.maxInt(u64)) return error.PopupOrderExhausted;
    try self.validatePopup(id, parent, rules);
    const scene_parent = try self.popupSceneParent(id, parent);
    const state = self.xdg_surfaces.get(id) orelse return error.InvalidSurface;
    const scene_id = if (scene_parent) |scene_parent_value|
        self.scene.addPopup(state.surface_id, scene_parent_value) catch |err| switch (err) {
            error.InvalidParent => return error.InvalidParent,
            error.OutOfMemory => return error.OutOfMemory,
        }
    else
        null;
    errdefer if (scene_id) |scene_popup_id| self.scene.removePopup(scene_popup_id);
    const order = self.next_popup_order;
    const popup = try self.popups.insert(self.allocator, .{
        .xdg_surface_id = id,
        .parent = if (parent) |parent_id| .{ .xdg_surface = parent_id } else .unattached,
        .scene_id = scene_id,
        .rules = rules,
        .order = order,
        .client = state.client,
    });
    self.next_popup_order += 1;
    state.role = .{ .popup = popup };
    return popup;
}

pub const ConfigureError = error{
    InvalidWindow,
    OutOfMemory,
    ConfigureSequenceExhausted,
};

pub fn configureWindowState(
    self: *XdgShell,
    id: WindowId,
    dimensions: Dimensions,
    configuration: ToplevelConfigure,
) ConfigureError!ConfigureToken {
    if (dimensions.width < 0 or dimensions.height < 0 or
        configuration.bounds.width < 0 or configuration.bounds.height < 0)
    {
        return error.InvalidWindow;
    }
    const window = self.windows.get(id) orelse return error.InvalidWindow;
    const state = self.xdg_surfaces.get(window.xdg_surface_id) orelse
        return error.InvalidWindow;
    const token = try state.nextToken(window.xdg_surface_id);
    try state.endpoint.configure_toplevel(
        state.endpoint.context,
        dimensions,
        configuration,
        token,
    );
    state.consumeToken(token);
    state.initial_configure_sent = true;
    if (!std.meta.eql(window.configuration, configuration)) {
        window.configuration = configuration;
        self.notify(.state_changed, id);
    }
    return token;
}

pub fn configureWindow(
    self: *XdgShell,
    id: WindowId,
    dimensions: Dimensions,
) ConfigureError!ConfigureToken {
    return self.configureWindowState(id, dimensions, .{});
}

pub fn commitGeometry(self: *XdgShell, id: XdgSurfaceId, requested: Geometry) void {
    const state = self.xdg_surfaces.get(id) orelse return;
    state.geometry = self.effectiveGeometry(state.surface_id, requested);
}

pub const CommitValidationError = error{
    InvalidSurface,
    RoleMissing,
    InvalidSizeHints,
    PopupUnattached,
};

pub fn validateCommit(self: *XdgShell, id: XdgSurfaceId) CommitValidationError!Role {
    const state = self.xdg_surfaces.get(id) orelse return error.InvalidSurface;
    const role = state.role orelse return error.RoleMissing;
    switch (role) {
        .toplevel => |window_id| {
            const window = self.windows.get(window_id) orelse return error.InvalidSurface;
            if (!validSizeHints(window.pending_min_size, window.pending_max_size)) {
                return error.InvalidSizeHints;
            }
        },
        .popup => |popup_id| {
            const popup = self.popups.get(popup_id) orelse return error.InvalidSurface;
            if (popup.scene_id == null) return error.PopupUnattached;
        },
    }
    return role;
}

pub fn beforeAppliedCommit(
    self: *XdgShell,
    id: XdgSurfaceId,
    had_buffer: bool,
    has_buffer: bool,
) void {
    if (!had_buffer or has_buffer) return;
    const state = self.xdg_surfaces.get(id) orelse return;
    switch (state.role orelse return) {
        .toplevel => |window_id| if (self.window_listener) |listener| {
            listener.unmapping(listener.context, window_id);
        },
        .popup => {},
    }
}

pub const CommitError = error{ PopupParentNotMapped, InvalidPopupParent };

pub fn afterAppliedCommit(
    self: *XdgShell,
    id: XdgSurfaceId,
    had_buffer: bool,
    has_buffer: bool,
    accepted: ?AcceptedConfigure,
) CommitError!void {
    const state = self.xdg_surfaces.get(id) orelse return;
    const role = state.role orelse return;
    switch (role) {
        .toplevel => |window_id| {
            const window = self.windows.get(window_id) orelse return;
            if (window.commit(self.allocator)) _ = self.notifyMetadata(window_id);
            if (had_buffer and !has_buffer) {
                self.unmapToplevel(id, window_id);
            } else if (has_buffer) {
                self.commitToplevelBuffer(id, window_id, accepted);
            } else {
                self.readyToplevel(id, window_id);
            }
        },
        .popup => |popup_id| {
            const popup = self.popups.get(popup_id) orelse return;
            if (popup.dismissed) return;
            if (had_buffer and !has_buffer) {
                self.unmapPopup(popup_id);
                popup.dismissed = false;
                state.mapped = false;
                state.configured = false;
                state.initial_configure_sent = false;
            } else if (has_buffer) {
                try self.commitPopupBuffer(id, popup_id, accepted);
            } else {
                try self.readyPopup(id, popup_id);
            }
        },
    }
}

fn contentGeometry(
    self: *XdgShell,
    state: *const XdgSurfaceState,
) ?Scene.ContentGeometry {
    if (state.geometry) |geometry| {
        return .{
            .offset = .{ .x = geometry.x, .y = geometry.y },
            .size = .{
                .width = @intCast(geometry.width),
                .height = @intCast(geometry.height),
            },
        };
    }
    const bounds = self.environment.subtree_geometry(
        self.environment.context,
        state.surface_id,
    ) orelse return null;
    return .{
        .offset = .{ .x = bounds.x, .y = bounds.y },
        .size = .{
            .width = @intCast(bounds.width),
            .height = @intCast(bounds.height),
        },
    };
}

fn effectiveGeometry(
    self: *XdgShell,
    surface_id: SurfaceRegistry.Id,
    requested: Geometry,
) Geometry {
    const bounds = self.environment.subtree_geometry(
        self.environment.context,
        surface_id,
    ) orelse return requested;
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

fn readyToplevel(
    self: *XdgShell,
    surface_id: XdgSurfaceId,
    window_id: WindowId,
) void {
    const window = self.windows.get(window_id) orelse return;
    if (window.ready) return;
    window.ready = true;
    const externally_managed = if (self.window_listener) |listener|
        listener.ready(listener.context, window_id)
    else
        false;
    if (externally_managed) return;
    _ = self.configureWindow(window_id, .{ .width = 0, .height = 0 }) catch |err| {
        if (err == error.OutOfMemory) {
            const state = self.xdg_surfaces.get(surface_id) orelse return;
            state.endpoint.report_failure(state.endpoint.context, .no_memory);
        }
    };
}

fn commitToplevelBuffer(
    self: *XdgShell,
    surface_id: XdgSurfaceId,
    window_id: WindowId,
    accepted: ?AcceptedConfigure,
) void {
    const state = self.xdg_surfaces.get(surface_id) orelse return;
    const window = self.windows.get(window_id) orelse return;
    const geometry = self.contentGeometry(state) orelse unreachable;
    const dimensions: Dimensions = .{
        .width = @intCast(geometry.size.width),
        .height = @intCast(geometry.size.height),
    };
    const previous_dimensions = window.committed_dimensions;
    window.committed_dimensions = dimensions;
    self.scene.setContentGeometry(window.scene_id, geometry);
    const was_mapped = window.mapped;
    const configure_token: ?ConfigureToken = if (accepted) |configure| token: {
        std.debug.assert(std.meta.eql(configure.token.surface, surface_id));
        std.debug.assert(configure.popup == null);
        state.configured = true;
        break :token configure.token;
    } else null;
    state.mapped = state.configured;
    window.mapped = state.mapped;
    if (windowCommitNeedsNotification(
        was_mapped,
        configure_token,
        previous_dimensions,
        dimensions,
    )) {
        const externally_managed = self.notifyWindowCommitted(
            window_id,
            configure_token,
        );
        if (!externally_managed) window.requested_scene_visibility = state.mapped;
        self.applyWindowSceneMapping(window);
    }
    if (was_mapped and state.mapped) self.scene.surfaceCommitted(window.scene_id);
}

fn unmapToplevel(
    self: *XdgShell,
    surface_id: XdgSurfaceId,
    window_id: WindowId,
) void {
    const state = self.xdg_surfaces.get(surface_id) orelse return;
    const window = self.windows.get(window_id) orelse return;
    self.dismissPopupsForParent(surface_id);
    self.reparentChildren(window_id, window.parent);
    self.notifyWindowUnmapped(window_id);
    state.mapped = false;
    state.configured = false;
    state.initial_configure_sent = false;
    window.requested_scene_visibility = false;
    self.applyWindowSceneMapping(window);
    self.scene.setContentGeometry(window.scene_id, null);
    window.reset(self.allocator);
}

fn readyPopup(
    self: *XdgShell,
    surface_id: XdgSurfaceId,
    popup_id: PopupId,
) CommitError!void {
    const popup = self.popups.get(popup_id) orelse return;
    if (popup.dismissed or popup.ready) return;
    if (!self.parentMapped(popup)) return error.PopupParentNotMapped;
    popup.ready = true;
    _ = self.sendPopupConfigure(popup_id, popup.rules) catch |err| switch (err) {
        error.OutOfMemory => {
            const state = self.xdg_surfaces.get(surface_id) orelse return;
            state.endpoint.report_failure(state.endpoint.context, .no_memory);
        },
        error.InvalidParent => return error.InvalidPopupParent,
        error.InvalidPositioner, error.ConfigureSequenceExhausted => {
            const state = self.xdg_surfaces.get(surface_id) orelse return;
            state.endpoint.report_failure(state.endpoint.context, .invalid_positioner);
        },
    };
}

fn commitPopupBuffer(
    self: *XdgShell,
    surface_id: XdgSurfaceId,
    popup_id: PopupId,
    accepted: ?AcceptedConfigure,
) CommitError!void {
    const state = self.xdg_surfaces.get(surface_id) orelse return;
    const popup = self.popups.get(popup_id) orelse return;
    if (popup.dismissed) return;
    const scene_id = popup.scene_id orelse return;
    if (!self.parentMapped(popup)) return error.PopupParentNotMapped;
    const was_mapped = popup.mapped;
    if (accepted) |configure| {
        std.debug.assert(std.meta.eql(configure.token.surface, surface_id));
        const pending = configure.popup orelse unreachable;
        state.configured = true;
        popup.rules = pending.rules;
        self.scene.setPopupPosition(scene_id, pending.placement.position);
    }
    self.scene.setPopupContentGeometry(scene_id, self.contentGeometry(state));
    state.mapped = state.configured and !popup.dismissed;
    popup.mapped = state.mapped;
    self.scene.setPopupMapped(scene_id, popup.mapped and popup.scene_presentation_enabled);
    if (was_mapped and popup.mapped and popup.scene_presentation_enabled)
        self.scene.popupCommitted(scene_id);
}

fn windowCommitNeedsNotification(
    was_mapped: bool,
    configure_token: ?ConfigureToken,
    previous_dimensions: ?Dimensions,
    dimensions: Dimensions,
) bool {
    return !was_mapped or configure_token != null or previous_dimensions == null or
        !std.meta.eql(previous_dimensions.?, dimensions);
}

pub const WindowIterator = struct {
    inner: WindowStore.Iterator,

    pub fn next(self: *WindowIterator) ?WindowId {
        return (self.inner.next() orelse return null).id;
    }
};

pub fn windowIterator(self: *XdgShell) WindowIterator {
    return .{ .inner = self.windows.iterator() };
}

pub fn windowInfo(self: *XdgShell, id: WindowId) ?WindowInfo {
    const window = self.windows.get(id) orelse return null;
    const state = self.xdg_surfaces.get(window.xdg_surface_id) orelse return null;
    const dimensions: ?Dimensions = if (self.contentGeometry(state)) |geometry| .{
        .width = @intCast(geometry.size.width),
        .height = @intCast(geometry.size.height),
    } else null;
    return .{
        .scene_id = window.scene_id,
        .client = state.client,
        .unreliable_pid = window.unreliable_pid,
        .title = window.title,
        .app_id = window.app_id,
        .tag = window.tag,
        .description = window.description,
        .icon = if (window.icon) |*icon| .{ .name = icon.name, .buffers = icon.buffers } else null,
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
        .scene_presentation_enabled = window.scene_presentation_enabled,
        .interaction_enabled = window.interaction_enabled,
        .requested_state = window.requested_state,
    };
}

pub fn setTitle(self: *XdgShell, id: WindowId, value: []const u8) error{OutOfMemory}!void {
    try self.setText(id, .title, value);
}

pub fn setAppId(self: *XdgShell, id: WindowId, value: []const u8) error{OutOfMemory}!void {
    try self.setText(id, .app_id, value);
}

const TextField = enum { title, app_id };
fn setText(self: *XdgShell, id: WindowId, field: TextField, value: []const u8) !void {
    const window = self.windows.get(id) orelse return;
    const destination = switch (field) {
        .title => &window.title,
        .app_id => &window.app_id,
    };
    const copy = try self.allocator.dupeSentinel(u8, value, 0);
    if (destination.*) |old| self.allocator.free(old);
    destination.* = copy;
    _ = self.notifyMetadata(id);
}

pub fn setToplevelTag(self: *XdgShell, id: WindowId, field: ToplevelTagField, value: []const u8) !void {
    const window = self.windows.get(id) orelse return;
    const destination = switch (field) {
        .tag => &window.tag,
        .description => &window.description,
    };
    const copy = try self.allocator.dupeSentinel(u8, value, 0);
    if (destination.*) |old| self.allocator.free(old);
    destination.* = copy;
    _ = self.notifyMetadata(id);
}

pub fn setDialogState(self: *XdgShell, id: WindowId, dialog: bool, modal: bool) void {
    std.debug.assert(dialog or !modal);
    const window = self.windows.get(id) orelse return;
    if (window.dialog == dialog and window.modal == modal) return;
    window.dialog = dialog;
    window.modal = modal;
    _ = self.notifyMetadata(id);
}

pub fn setPendingToplevelIcon(self: *XdgShell, id: WindowId, icon: ?ToplevelIcon) void {
    const window = self.windows.get(id) orelse return;
    if (window.pending_icon) |*old| old.deinit(self.allocator);
    window.pending_icon = icon;
    window.pending_icon_changed = true;
}

pub fn setPendingSizeHints(self: *XdgShell, id: WindowId, minimum: SizeHint, maximum: SizeHint) void {
    const window = self.windows.get(id) orelse return;
    window.pending_min_size = minimum;
    window.pending_max_size = maximum;
}

pub fn setPendingMinSize(self: *XdgShell, id: WindowId, minimum: SizeHint) void {
    const window = self.windows.get(id) orelse return;
    window.pending_min_size = minimum;
}

pub fn setPendingMaxSize(self: *XdgShell, id: WindowId, maximum: SizeHint) void {
    const window = self.windows.get(id) orelse return;
    window.pending_max_size = maximum;
}

pub fn createDecoration(self: *XdgShell, id: WindowId) bool {
    const window = self.windows.get(id) orelse return false;
    window.decoration_preference = .no_preference;
    window.decoration_configure_requested = true;
    return self.notifyMetadata(id);
}

pub fn setDecorationPreference(
    self: *XdgShell,
    id: WindowId,
    preference: DecorationPreference,
) bool {
    const window = self.windows.get(id) orelse return false;
    window.decoration_preference = preference;
    window.decoration_configure_requested = true;
    return self.notifyMetadata(id);
}

pub fn decorationConfigured(self: *XdgShell, id: WindowId) void {
    const window = self.windows.get(id) orelse return;
    window.decoration_configure_requested = false;
}

pub fn destroyDecoration(self: *XdgShell, id: WindowId) void {
    const window = self.windows.get(id) orelse return;
    window.decoration_preference = .only_csd;
    window.decoration_configure_requested = false;
    _ = self.notifyMetadata(id);
}

pub const ParentError = error{InvalidParent};
pub fn setParent(self: *XdgShell, child_id: WindowId, parent_id: ?WindowId) ParentError!void {
    const child = self.windows.get(child_id) orelse return error.InvalidParent;
    const applied_parent: ?WindowId = if (parent_id) |id| parent: {
        const parent = self.windows.get(id) orelse return error.InvalidParent;
        break :parent if (parent.mapped) id else null;
    } else null;
    var ancestor = applied_parent;
    while (ancestor) |candidate| {
        if (std.meta.eql(candidate, child_id)) return error.InvalidParent;
        ancestor = (self.windows.get(candidate) orelse return error.InvalidParent).parent;
    }
    child.parent = applied_parent;
    child.parent_owner = null;
    _ = self.notifyMetadata(child_id);
}

pub fn setForeignParent(
    self: *XdgShell,
    child_surface: SurfaceRegistry.Id,
    parent_id: WindowId,
    owner: *anyopaque,
) error{ InvalidSurface, InvalidParent }!void {
    const id = self.toplevelForSurface(child_surface) orelse return error.InvalidSurface;
    const child = self.windows.get(id) orelse return error.InvalidSurface;
    const parent = self.windows.get(parent_id) orelse return error.InvalidParent;
    const applied_parent: ?WindowId = if (parent.mapped) parent_id else null;
    var ancestor = applied_parent;
    while (ancestor) |candidate| {
        if (std.meta.eql(candidate, id)) return error.InvalidParent;
        const candidate_window = self.windows.get(candidate) orelse break;
        ancestor = candidate_window.parent;
    }
    child.parent = applied_parent;
    child.parent_owner = if (applied_parent != null) owner else null;
    _ = self.notifyMetadata(id);
}

pub fn clearForeignParents(self: *XdgShell, owner: *anyopaque) void {
    var iterator = self.windows.iterator();
    while (iterator.next()) |entry| if (entry.value.parent_owner == owner) {
        entry.value.parent = null;
        entry.value.parent_owner = null;
        _ = self.notifyMetadata(entry.id);
    };
}

fn notifyMetadata(self: *XdgShell, id: WindowId) bool {
    const managed = if (self.window_listener) |listener|
        listener.metadata_changed(listener.context, id)
    else
        false;
    self.notify(.metadata_changed, id);
    return managed;
}

pub fn restoreStandaloneWindow(self: *XdgShell, id: WindowId, deactivate: bool, dimensions: Dimensions) void {
    const window = self.windows.get(id) orelse return;
    const state = self.xdg_surfaces.get(window.xdg_surface_id) orelse return;
    if (deactivate or (window.ready and !state.initial_configure_sent)) {
        _ = self.configureWindowState(
            id,
            if (deactivate) dimensions else .{ .width = 0, .height = 0 },
            .{},
        ) catch |err| switch (err) {
            error.OutOfMemory => state.endpoint.report_failure(
                state.endpoint.context,
                .no_memory,
            ),
            error.InvalidWindow, error.ConfigureSequenceExhausted => {},
        };
    }
    if (window.mapped) window.requested_scene_visibility = true;
    self.applyWindowSceneMapping(window);
}

pub fn setWindowVisible(self: *XdgShell, id: WindowId, visible: bool) void {
    const w = self.windows.get(id) orelse return;
    w.requested_scene_visibility = visible;
    self.applyWindowSceneMapping(w);
}

pub fn setWindowScenePresentationEnabled(
    self: *XdgShell,
    id: WindowId,
    enabled: bool,
) error{OutOfMemory}!void {
    const window = self.windows.get(id) orelse return;
    if (window.scene_presentation_enabled == enabled) return;
    if (self.window_listener) |listener| {
        try listener.presentation_changed(listener.context, id, enabled);
    }
    window.scene_presentation_enabled = enabled;
    self.notify(.metadata_changed, id);
    self.applyWindowSceneMapping(window);
    if (!enabled) self.scene.placeUnmappedWindowBottom(window.scene_id);
}

pub fn setWindowInteractionEnabled(self: *XdgShell, id: WindowId, enabled: bool) void {
    const window = self.windows.get(id) orelse return;
    if (window.interaction_enabled == enabled) return;
    window.interaction_enabled = enabled;
    if (self.window_listener) |listener| {
        listener.interaction_changed(listener.context, id, enabled);
    }
}

fn applyWindowSceneMapping(self: *XdgShell, window: *WindowState) void {
    self.scene.setMapped(
        window.scene_id,
        windowSceneMapped(window),
    );
}

fn windowSceneMapped(window: *const WindowState) bool {
    return window.mapped and window.requested_scene_visibility and
        window.scene_presentation_enabled;
}
pub fn setWindowPosition(self: *XdgShell, id: WindowId, position: Scene.Position) void {
    const window = self.windows.get(id) orelse return;
    const changed = if (self.scene.windowPosition(window.scene_id)) |current|
        !std.meta.eql(current, position)
    else
        false;
    self.scene.setPosition(window.scene_id, position);
    if (changed) self.reconfigureReactivePopups(id);
}
pub fn setWindowFocused(self: *XdgShell, id: WindowId, value: bool) void {
    const w = self.windows.get(id) orelse return;
    self.scene.setFocused(w.scene_id, value);
}
pub fn setWindowFullscreen(self: *XdgShell, id: WindowId, value: bool) void {
    const w = self.windows.get(id) orelse return;
    self.scene.setFullscreen(w.scene_id, value);
}
pub fn setWindowBorders(self: *XdgShell, id: WindowId, value: ?Scene.Borders) void {
    const w = self.windows.get(id) orelse return;
    self.scene.setBorders(w.scene_id, value);
}
pub fn setWindowClipBox(self: *XdgShell, id: WindowId, value: ?Scene.ClipBox) void {
    const w = self.windows.get(id) orelse return;
    self.scene.setClipBox(w.scene_id, value);
}
pub fn setWindowContentClipBox(self: *XdgShell, id: WindowId, value: ?Scene.ClipBox) void {
    const w = self.windows.get(id) orelse return;
    self.scene.setContentClipBox(w.scene_id, value);
}
pub fn addWindowDecoration(self: *XdgShell, id: WindowId, surface: SurfaceRegistry.Id, layer: Scene.DecorationLayer) !Scene.DecorationId {
    const w = self.windows.get(id) orelse return error.InvalidWindow;
    return self.scene.addDecoration(w.scene_id, surface, layer);
}
pub fn removeWindowDecoration(self: *XdgShell, id: Scene.DecorationId) void {
    self.scene.removeDecoration(id);
}
pub fn setWindowDecorationOffset(self: *XdgShell, id: Scene.DecorationId, value: Scene.Position) void {
    self.scene.setDecorationOffset(id, value);
}
pub fn setWindowDecorationMapped(self: *XdgShell, id: Scene.DecorationId, value: bool) void {
    self.scene.setDecorationMapped(id, value);
}
pub fn windowDecorationCommitted(self: *XdgShell, id: Scene.DecorationId) void {
    self.scene.decorationCommitted(id);
}
pub fn placeWindowTop(self: *XdgShell, id: WindowId) void {
    const w = self.windows.get(id) orelse return;
    self.scene.placeTop(w.scene_id);
}
pub fn placeWindowBottom(self: *XdgShell, id: WindowId) void {
    const w = self.windows.get(id) orelse return;
    self.scene.placeBottom(w.scene_id);
}
pub fn placeWindowAbove(self: *XdgShell, id: WindowId, other: WindowId) void {
    const w = self.windows.get(id) orelse return;
    const o = self.windows.get(other) orelse return;
    self.scene.placeAbove(w.scene_id, o.scene_id);
}
pub fn placeWindowBelow(self: *XdgShell, id: WindowId, other: WindowId) void {
    const w = self.windows.get(id) orelse return;
    const o = self.windows.get(other) orelse return;
    self.scene.placeBelow(w.scene_id, o.scene_id);
}

pub fn hasPopupGrab(self: *XdgShell) bool {
    return self.topGrabbedPopup() != null;
}

pub fn popupGrabOwnsClient(self: *XdgShell, client: ?ClientRegistry.Id) bool {
    const id = self.topGrabbedPopup() orelse return true;
    const popup = self.popups.get(id) orelse return true;
    const candidate = client orelse return false;
    return std.meta.eql(candidate, popup.client);
}

pub fn popupKeyboardFocus(self: *XdgShell) ?SurfaceRegistry.Id {
    const popup = self.popups.get(self.topMappedGrabbedPopup() orelse return null) orelse
        return null;
    const state = self.xdg_surfaces.get(popup.xdg_surface_id) orelse return null;
    return state.surface_id;
}

pub fn attachPopup(
    self: *XdgShell,
    id: PopupId,
    layer_surface_id: Scene.LayerSurfaceId,
) error{ AlreadyAttached, InvalidLayerSurface, OutOfMemory }!void {
    const popup = self.popups.get(id) orelse return error.AlreadyAttached;
    if (popup.parent != .unattached) return error.AlreadyAttached;
    const state = self.xdg_surfaces.get(popup.xdg_surface_id) orelse
        return error.AlreadyAttached;
    const scene_id = self.scene.addPopup(
        state.surface_id,
        .{ .layer_surface = layer_surface_id },
    ) catch |err| switch (err) {
        error.InvalidParent => return error.InvalidLayerSurface,
        error.OutOfMemory => return error.OutOfMemory,
    };
    popup.parent = .{ .layer_surface = layer_surface_id };
    popup.scene_id = scene_id;
}

pub fn dismissLayerSurfacePopups(
    self: *XdgShell,
    layer_surface_id: Scene.LayerSurfaceId,
) void {
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

pub fn popupRootLayerSurface(
    self: *XdgShell,
    surface_id: SurfaceRegistry.Id,
) ?Scene.LayerSurfaceId {
    var popup: ?*PopupState = null;
    var iterator = self.popups.iterator();
    while (iterator.next()) |entry| {
        const state = self.xdg_surfaces.get(entry.value.xdg_surface_id) orelse continue;
        if (std.meta.eql(state.surface_id, surface_id)) {
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

pub fn surfaceRootWindow(
    self: *XdgShell,
    surface_id: SurfaceRegistry.Id,
) ?WindowId {
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

pub fn toplevelForSurface(
    self: *XdgShell,
    surface_id: SurfaceRegistry.Id,
) ?WindowId {
    var iterator = self.xdg_surfaces.iterator();
    while (iterator.next()) |entry| {
        if (!std.meta.eql(entry.value.surface_id, surface_id)) continue;
        const id = switch (entry.value.role orelse return null) {
            .toplevel => |window_id| window_id,
            .popup => return null,
        };
        return if (self.windows.get(id) != null) id else null;
    }
    return null;
}

pub fn popupForSurface(
    self: *XdgShell,
    surface_id: SurfaceRegistry.Id,
) ?PopupId {
    var iterator = self.xdg_surfaces.iterator();
    while (iterator.next()) |entry| {
        if (!std.meta.eql(entry.value.surface_id, surface_id)) continue;
        return switch (entry.value.role orelse return null) {
            .toplevel => null,
            .popup => |id| id,
        };
    }
    return null;
}

pub fn dismissPopupGrab(self: *XdgShell) void {
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

fn topGrabbedPopup(self: *XdgShell) ?PopupId {
    return self.findTopGrabbedPopup(false);
}

fn topMappedGrabbedPopup(self: *XdgShell) ?PopupId {
    return self.findTopGrabbedPopup(true);
}

fn findTopGrabbedPopup(self: *XdgShell, require_mapped: bool) ?PopupId {
    var result: ?PopupId = null;
    var order: u64 = 0;
    var iterator = self.popups.iterator();
    while (iterator.next()) |entry| {
        const popup = entry.value;
        if (!popup.grabbed or popup.dismissed or (require_mapped and !popup.mapped)) continue;
        if (result == null or popup.order > order) {
            result = entry.id;
            order = popup.order;
        }
    }
    return result;
}

pub const PopupGrabResult = enum { grabbed, dismissed, ignored };
pub const PopupGrabError = error{
    InvalidPopup,
    AlreadyMapped,
    Unattached,
    InvalidLayerParent,
    InvalidParent,
    ParentRoleMissing,
    AnotherGrab,
    ParentDoesNotOwnGrab,
};

pub fn grabPopup(
    self: *XdgShell,
    id: PopupId,
    action: UserAction,
) PopupGrabError!PopupGrabResult {
    const popup = self.popups.get(id) orelse return error.InvalidPopup;
    if (popup.dismissed) return .ignored;
    if (popup.mapped) return error.AlreadyMapped;
    if (popup.grabbed) {
        self.dismissPopup(id);
        return .dismissed;
    }

    const parent_role: ?Role = switch (popup.parent) {
        .unattached => return error.Unattached,
        .layer_surface => |layer_id| if (self.scene.layerSurface(layer_id) != null)
            null
        else
            return error.InvalidLayerParent,
        .xdg_surface => |parent_id| (self.xdg_surfaces.get(parent_id) orelse
            return error.InvalidParent).role orelse return error.ParentRoleMissing,
    };
    if (parent_role) |role| switch (role) {
        .toplevel => if (self.topGrabbedPopup() != null) return error.AnotherGrab,
        .popup => |parent_id| {
            const parent_popup = self.popups.get(parent_id) orelse return error.InvalidParent;
            const topmost = self.topGrabbedPopup();
            if (!parent_popup.grabbed or parent_popup.dismissed or topmost == null or
                !std.meta.eql(topmost.?, parent_id)) return error.ParentDoesNotOwnGrab;
        },
    } else if (self.topGrabbedPopup() != null) return error.AnotherGrab;

    if (!action.granted or !std.meta.eql(action.client, popup.client)) {
        self.dismissPopup(id);
        return .dismissed;
    }
    popup.grabbed = true;
    return .grabbed;
}

pub fn popupIsTopmost(self: *XdgShell, id: PopupId) bool {
    const popup = self.popups.get(id) orelse return true;
    var iterator = self.popups.iterator();
    while (iterator.next()) |entry| {
        switch (entry.value.parent) {
            .xdg_surface => |parent_id| if (std.meta.eql(parent_id, popup.xdg_surface_id)) {
                return false;
            },
            .unattached, .layer_surface => {},
        }
    }
    return true;
}

fn popupRootWindow(self: *XdgShell, id: PopupId) ?WindowId {
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

fn parentMapped(self: *XdgShell, popup: *const PopupState) bool {
    return switch (popup.parent) {
        .unattached => false,
        .xdg_surface => |id| (self.xdg_surfaces.get(id) orelse return false).mapped,
        .layer_surface => |id| (self.scene.layerSurface(id) orelse return false).mapped,
    };
}

fn popupParentGeometry(
    self: *XdgShell,
    popup: *const PopupState,
) ?struct { geometry: Scene.ContentGeometry, position: Scene.Position } {
    switch (popup.parent) {
        .unattached => return null,
        .layer_surface => |layer_id| {
            const layer = self.scene.layerSurface(layer_id) orelse return null;
            const size = self.environment.surface_size(
                self.environment.context,
                layer.surface_id,
            ) orelse return null;
            return .{ .geometry = .{ .size = size }, .position = layer.position };
        },
        .xdg_surface => |parent_id| {
            const parent = self.xdg_surfaces.get(parent_id) orelse return null;
            const geometry = self.contentGeometry(parent) orelse return null;
            const position = switch (parent.role orelse return null) {
                .toplevel => |window_id| window: {
                    const window = self.windows.get(window_id) orelse return null;
                    break :window self.scene.windowPosition(window.scene_id) orelse return null;
                },
                .popup => |popup_id| parent_popup: {
                    const parent_popup = self.popups.get(popup_id) orelse return null;
                    break :parent_popup self.scene.popupPosition(
                        parent_popup.scene_id orelse return null,
                    ) orelse return null;
                },
            };
            return .{ .geometry = geometry, .position = position };
        },
    }
}

fn popupPlacement(
    self: *XdgShell,
    popup: *const PopupState,
    rules: Rules,
) error{ InvalidParent, InvalidPositioner }!Placement {
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
    const output_bounds = self.environment.popup_output_bounds(
        self.environment.context,
        parent.position,
        parent.geometry.size,
        self.default_output_id,
    ) orelse return error.InvalidParent;
    return popup_placement.place(rules, parent.position, output_bounds);
}

pub const PopupConfigureError = error{
    InvalidParent,
    InvalidPositioner,
    OutOfMemory,
    ConfigureSequenceExhausted,
};

pub fn sendPopupConfigure(
    self: *XdgShell,
    id: PopupId,
    rules: Rules,
) PopupConfigureError!ConfigureToken {
    const popup = self.popups.get(id) orelse return error.InvalidParent;
    const placement = try self.popupPlacement(popup, rules);
    const state = self.xdg_surfaces.get(popup.xdg_surface_id) orelse
        return error.InvalidParent;
    const token = try state.nextToken(popup.xdg_surface_id);
    try state.endpoint.configure_popup(
        state.endpoint.context,
        .{ .rules = rules, .placement = placement },
        token,
    );
    state.consumeToken(token);
    state.initial_configure_sent = true;
    return token;
}

fn dismissPopup(self: *XdgShell, id: PopupId) void {
    const popup = self.popups.get(id) orelse return;
    if (popup.dismissed) return;
    self.dismissPopupsForParent(popup.xdg_surface_id);
    popup.dismissed = true;
    popup.mapped = false;
    if (popup.scene_id) |scene_id| self.scene.setPopupMapped(scene_id, false);
    if (self.xdg_surfaces.get(popup.xdg_surface_id)) |state| {
        state.mapped = false;
        state.endpoint.popup_done(state.endpoint.context);
    }
}

fn dismissPopupsForParent(self: *XdgShell, parent: XdgSurfaceId) void {
    while (true) {
        var found: ?PopupId = null;
        var order: u64 = 0;
        var iterator = self.popups.iterator();
        while (iterator.next()) |entry| {
            if (entry.value.dismissed or !self.popupDescendsFrom(entry.id, parent)) continue;
            if (found == null or entry.value.order > order) {
                found = entry.id;
                order = entry.value.order;
            }
        }
        self.dismissPopup(found orelse return);
    }
}

fn popupDescendsFrom(self: *XdgShell, id: PopupId, ancestor: XdgSurfaceId) bool {
    var popup = self.popups.get(id) orelse return false;
    var remaining = self.popups.len() + 1;
    while (remaining > 0) : (remaining -= 1) {
        const parent = switch (popup.parent) {
            .xdg_surface => |value| value,
            else => return false,
        };
        if (std.meta.eql(parent, ancestor)) return true;
        const state = self.xdg_surfaces.get(parent) orelse return false;
        popup = self.popups.get(switch (state.role orelse return false) {
            .popup => |value| value,
            .toplevel => return false,
        }) orelse return false;
    }
    return false;
}

fn reconfigureReactivePopups(self: *XdgShell, window_id: WindowId) void {
    var iterator = self.popups.iterator();
    while (iterator.next()) |entry| {
        const root = self.popupRootWindow(entry.id) orelse continue;
        if (!std.meta.eql(root, window_id) or !entry.value.mapped or
            !entry.value.scene_presentation_enabled or
            !entry.value.rules.reactive or entry.value.dismissed) continue;
        _ = self.sendPopupConfigure(entry.id, entry.value.rules) catch |err| switch (err) {
            error.OutOfMemory => failure: {
                const state = self.xdg_surfaces.get(entry.value.xdg_surface_id) orelse
                    break :failure;
                state.endpoint.report_failure(state.endpoint.context, .no_memory);
            },
            error.InvalidParent, error.InvalidPositioner => self.dismissPopup(entry.id),
            error.ConfigureSequenceExhausted => self.dismissPopup(entry.id),
        };
    }
}

fn unmapPopup(self: *XdgShell, id: PopupId) void {
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

fn removePopupState(self: *XdgShell, id: PopupId) void {
    const popup = self.popups.get(id) orelse return;
    self.dismissPopupsForParent(popup.xdg_surface_id);
    const removed = self.popups.remove(id) orelse return;
    if (removed.scene_id) |scene_id| self.scene.removePopup(scene_id);
}

pub fn destroyPopup(self: *XdgShell, id: PopupId) void {
    const popup = self.popups.get(id) orelse return;
    const surface_id = popup.xdg_surface_id;
    if (self.xdg_surfaces.get(surface_id)) |state| {
        state.role = null;
        state.mapped = false;
        state.configured = false;
        state.initial_configure_sent = false;
    }
    self.removePopupState(id);
}

pub fn destroyToplevel(self: *XdgShell, id: WindowId) void {
    const window = self.windows.get(id) orelse return;
    const surface_id = window.xdg_surface_id;
    self.dismissPopupsForParent(surface_id);
    if (self.xdg_surfaces.get(surface_id)) |state| {
        state.role = null;
        state.mapped = false;
        state.configured = false;
        state.initial_configure_sent = false;
    }
    if (self.windows.remove(id)) |window_value| {
        self.clearParentReferences(id);
        self.notifyWindowDestroyed(id);
        var removed = window_value;
        self.scene.removeWindow(removed.scene_id);
        removed.deinit(self.allocator);
    }
}

pub fn surfaceDestroyed(self: *XdgShell, id: XdgSurfaceId) void {
    const state = self.xdg_surfaces.get(id) orelse return;
    state.mapped = false;
    switch (state.role orelse return) {
        .toplevel => |window_id| {
            self.dismissPopupsForParent(id);
            if (self.windows.get(window_id)) |window| {
                if (window.ready) self.notifyWindowUnmapped(window_id);
                window.mapped = false;
                window.ready = false;
                window.requested_scene_visibility = false;
                self.applyWindowSceneMapping(window);
                self.scene.setContentGeometry(window.scene_id, null);
            }
        },
        .popup => |popup_id| self.unmapPopup(popup_id),
    }
}

fn reparentChildren(
    self: *XdgShell,
    parent_id: WindowId,
    replacement_parent: ?WindowId,
) void {
    var iterator = self.windows.iterator();
    while (iterator.next()) |entry| {
        const current_parent = entry.value.parent orelse continue;
        if (!std.meta.eql(current_parent, parent_id)) continue;
        entry.value.parent = replacement_parent;
        if (replacement_parent == null) entry.value.parent_owner = null;
        _ = self.notifyMetadata(entry.id);
    }
}

fn clearParentReferences(self: *XdgShell, parent_id: WindowId) void {
    var iterator = self.windows.iterator();
    while (iterator.next()) |entry| {
        if (entry.value.parent) |candidate| {
            if (!std.meta.eql(candidate, parent_id)) continue;
            entry.value.parent = null;
            entry.value.parent_owner = null;
            _ = self.notifyMetadata(entry.id);
        }
    }
}

fn notifyWindowCommitted(
    self: *XdgShell,
    window_id: WindowId,
    token: ?ConfigureToken,
) bool {
    const externally_managed = if (self.window_listener) |listener|
        listener.committed(listener.context, window_id, token)
    else
        false;
    self.notify(.committed, window_id);
    return externally_managed;
}

fn notifyWindowUnmapped(self: *XdgShell, window_id: WindowId) void {
    if (self.window_listener) |listener| listener.unmapped(listener.context, window_id);
    self.notify(.unmapped, window_id);
}

fn notifyWindowDestroyed(self: *XdgShell, window_id: WindowId) void {
    if (self.window_listener) |listener| listener.destroyed(listener.context, window_id);
    self.notify(.destroyed, window_id);
}

pub fn surfaceRole(self: *XdgShell, id: XdgSurfaceId) ?Role {
    const state = self.xdg_surfaces.get(id) orelse return null;
    return state.role;
}

pub fn surfaceConfigured(self: *XdgShell, id: XdgSurfaceId) bool {
    const state = self.xdg_surfaces.get(id) orelse return false;
    return state.configured;
}

pub fn popupDismissed(self: *XdgShell, id: PopupId) bool {
    const popup = self.popups.get(id) orelse return true;
    return popup.dismissed;
}

pub fn popupMapped(self: *XdgShell, id: PopupId) bool {
    const popup = self.popups.get(id) orelse return false;
    return popup.mapped;
}

pub const PopupPresentationInfo = struct {
    surface: SurfaceRegistry.Id,
    scene_id: Scene.PopupId,
    client: ClientRegistry.Id,
    mapped: bool,
    scene_presentation_enabled: bool,
};

/// Returns the exact neutral/Scene ownership tuple for a popup. Callers must
/// still verify frontend ownership; this deliberately performs no ancestry
/// inference from the popup's root toplevel.
pub fn popupPresentationInfo(self: *XdgShell, id: PopupId) ?PopupPresentationInfo {
    const popup = self.popups.get(id) orelse return null;
    const state = self.xdg_surfaces.get(popup.xdg_surface_id) orelse return null;
    return .{
        .surface = state.surface_id,
        .scene_id = popup.scene_id orelse return null,
        .client = popup.client,
        .mapped = popup.mapped,
        .scene_presentation_enabled = popup.scene_presentation_enabled,
    };
}

/// True only while every neutral parent is presented and interactive.
pub fn popupParentChainInteractive(self: *XdgShell, id: PopupId) bool {
    var popup = self.popups.get(id) orelse return false;
    var remaining = self.popups.len() + 1;
    while (remaining > 0) : (remaining -= 1) switch (popup.parent) {
        .unattached => return false,
        .layer_surface => |layer_id| return (self.scene.layerSurface(layer_id) orelse return false).mapped,
        .xdg_surface => |parent_id| {
            const parent = self.xdg_surfaces.get(parent_id) orelse return false;
            if (!parent.mapped) return false;
            switch (parent.role orelse return false) {
                .toplevel => |window_id| {
                    const window = self.windows.get(window_id) orelse return false;
                    return window.scene_presentation_enabled and window.interaction_enabled and
                        self.scene.surfaceMapped(parent.surface_id);
                },
                .popup => |popup_id| {
                    popup = self.popups.get(popup_id) orelse return false;
                    if (!popup.mapped or !popup.scene_presentation_enabled) return false;
                },
            }
        },
    };
    return false;
}

pub fn popupScenePresentationEnabled(self: *XdgShell, id: PopupId) bool {
    const popup = self.popups.get(id) orelse return false;
    return popup.scene_presentation_enabled;
}

pub fn setPopupScenePresentationEnabled(self: *XdgShell, id: PopupId, enabled: bool) void {
    const popup = self.popups.get(id) orelse return;
    if (popup.scene_presentation_enabled == enabled) return;
    popup.scene_presentation_enabled = enabled;
    if (popup.scene_id) |scene_id|
        self.scene.setPopupMapped(scene_id, popup.mapped and enabled);
}

pub fn surfaceClient(self: *XdgShell, id: XdgSurfaceId) ?ClientRegistry.Id {
    const state = self.xdg_surfaces.get(id) orelse return null;
    return state.client;
}

pub fn setWindowListener(self: *XdgShell, listener: WindowListener) void {
    std.debug.assert(self.window_listener == null);
    self.window_listener = listener;
}
pub fn clearWindowListener(self: *XdgShell) void {
    std.debug.assert(self.window_listener != null);
    self.window_listener = null;
}
pub fn addWindowObserver(self: *XdgShell, observer: WindowObserver) !void {
    std.debug.assert(!self.notifying_window_observers);
    for (self.window_observers.items) |existing| {
        std.debug.assert(existing.context != observer.context);
    }
    try self.window_observers.append(self.allocator, observer);
}
pub fn removeWindowObserver(self: *XdgShell, context: *anyopaque) void {
    std.debug.assert(!self.notifying_window_observers);
    for (self.window_observers.items, 0..) |v, i| if (v.context == context) {
        _ = self.window_observers.orderedRemove(i);
        return;
    };
    unreachable;
}
const Notification = enum { committed, unmapped, destroyed, metadata_changed, state_changed };
fn notify(self: *XdgShell, event: Notification, id: WindowId) void {
    std.debug.assert(!self.notifying_window_observers);
    self.notifying_window_observers = true;
    defer self.notifying_window_observers = false;
    for (self.window_observers.items) |o| switch (event) {
        .committed => o.committed(o.context, id),
        .unmapped => o.unmapped(o.context, id),
        .destroyed => o.destroyed(o.context, id),
        .metadata_changed => o.metadata_changed(o.context, id),
        .state_changed => o.state_changed(o.context, id),
    };
}

pub fn requestMaximized(self: *XdgShell, id: WindowId, maximized: bool) void {
    const window = self.windows.get(id) orelse return;
    window.requestMaximized(maximized);
}

pub fn requestFullscreen(
    self: *XdgShell,
    id: WindowId,
    fullscreen: bool,
    output: ?OutputLayout.Id,
) void {
    const window = self.windows.get(id) orelse return;
    window.requestFullscreen(fullscreen, output);
}

pub fn requestMinimized(self: *XdgShell, id: WindowId, minimized: bool) void {
    const window = self.windows.get(id) orelse return;
    window.requestMinimized(minimized);
}

pub fn requestWindow(self: *XdgShell, id: WindowId, request: WindowRequest) void {
    const window = self.windows.get(id) orelse return;
    const state = self.xdg_surfaces.get(window.xdg_surface_id) orelse return;
    switch (request) {
        .pointer_move => |a| if (!windowAcceptsAction(window, state, a)) return,
        .pointer_resize => |v| if (!windowAcceptsAction(window, state, v.action)) return,
        .show_window_menu => |v| if (!windowAcceptsAction(window, state, v.action)) return,
        // Activation provenance is decided by the caller (for example,
        // foreign-toplevel policy). It is intentionally serialless and may
        // originate from a client other than the target window.
        .activate => |a| if (!window.interaction_enabled or !a.granted) return,
        else => {},
    }
    if (self.window_listener) |l| l.request(l.context, id, request);
}

fn windowAcceptsAction(
    window: *const WindowState,
    state: *const XdgSurfaceState,
    action: UserAction,
) bool {
    return window.mapped and window.scene_presentation_enabled and
        window.interaction_enabled and action.granted and
        std.meta.eql(state.client, action.client) and action.serial != null;
}
pub fn windowSurface(self: *XdgShell, id: WindowId) ?SurfaceRegistry.Id {
    const w = self.windows.get(id) orelse return null;
    return (self.xdg_surfaces.get(w.xdg_surface_id) orelse return null).surface_id;
}
pub fn closeWindow(self: *XdgShell, id: WindowId) void {
    const w = self.windows.get(id) orelse return;
    const xs = self.xdg_surfaces.get(w.xdg_surface_id) orelse return;
    xs.endpoint.close(xs.endpoint.context);
}
pub fn setDefaultOutput(self: *XdgShell, id: OutputLayout.Id) void {
    self.default_output_id = id;
}
pub fn validSizeHints(min: SizeHint, max: SizeHint) bool {
    return min.width >= 0 and min.height >= 0 and max.width >= 0 and max.height >= 0 and (max.width == 0 or min.width <= max.width) and (max.height == 0 or min.height <= max.height);
}

test "surface-owned configure sequence and generational identity" {
    var store: XdgSurfaceStore = .{};
    defer store.deinit(std.testing.allocator);
    const dummy: XdgSurfaceState = undefined;
    const first = try store.insert(std.testing.allocator, dummy);
    var state = store.get(first).?;
    state.next_sequence = 1;
    const token = try state.nextToken(first);
    try std.testing.expectEqual(@as(u64, 1), token.sequence);
    state.consumeToken(token);
    state.next_sequence = std.math.maxInt(u64);
    try std.testing.expectError(error.ConfigureSequenceExhausted, state.nextToken(first));
    _ = store.remove(first);
    const second = try store.insert(std.testing.allocator, dummy);
    try std.testing.expect(first.index == second.index and first.generation != second.generation);
    _ = store.remove(second);
}

test "popup order exhaustion prevents wrap and publication" {
    const allocator = std.testing.allocator;
    const client: ClientRegistry.Id = .{ .index = 1, .generation = 1 };
    const rules: Rules = .{
        .size = .{ .width = 1, .height = 1 },
        .anchor_rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
    };

    var shell: XdgShell = undefined;
    shell.allocator = allocator;
    shell.scene = undefined;
    shell.xdg_surfaces = .{};
    shell.windows = .{};
    shell.popups = .{};
    shell.next_popup_order = std.math.maxInt(u64) - 1;
    defer shell.xdg_surfaces.deinit(allocator);
    defer shell.windows.deinit(allocator);
    defer shell.popups.deinit(allocator);

    const first_surface = try shell.xdg_surfaces.insert(allocator, .{
        .surface_id = undefined,
        .client = client,
        .endpoint = undefined,
    });
    defer _ = shell.xdg_surfaces.remove(first_surface);
    const first_popup = try shell.createPopup(first_surface, null, rules);
    defer {
        shell.xdg_surfaces.get(first_surface).?.role = null;
        _ = shell.popups.remove(first_popup);
    }
    try std.testing.expectEqual(
        std.math.maxInt(u64) - 1,
        shell.popups.get(first_popup).?.order,
    );
    try std.testing.expectEqual(std.math.maxInt(u64), shell.next_popup_order);

    const parent_surface = try shell.xdg_surfaces.insert(allocator, .{
        .surface_id = undefined,
        .client = client,
        .endpoint = undefined,
    });
    defer _ = shell.xdg_surfaces.remove(parent_surface);
    const parent_window = try shell.windows.insert(allocator, .{
        .xdg_surface_id = parent_surface,
        .scene_id = undefined,
        .unreliable_pid = 0,
    });
    shell.xdg_surfaces.get(parent_surface).?.role = .{ .toplevel = parent_window };
    defer {
        shell.xdg_surfaces.get(parent_surface).?.role = null;
        var removed_parent = shell.windows.remove(parent_window).?;
        removed_parent.deinit(allocator);
    }
    const rejected_surface = try shell.xdg_surfaces.insert(allocator, .{
        .surface_id = undefined,
        .client = client,
        .endpoint = undefined,
    });
    defer _ = shell.xdg_surfaces.remove(rejected_surface);

    try std.testing.expectError(
        error.PopupOrderExhausted,
        shell.createPopup(rejected_surface, parent_surface, rules),
    );
    try std.testing.expect(shell.xdg_surfaces.get(rejected_surface).?.role == null);
    try std.testing.expectEqual(@as(usize, 1), shell.popups.len());
    try std.testing.expectEqual(std.math.maxInt(u64), shell.next_popup_order);
}

test "explicit popup grabs precede popup mapping" {
    const allocator = std.testing.allocator;
    var shell: XdgShell = undefined;
    shell.popups = .{};
    defer shell.popups.deinit(allocator);

    const initial: PopupState = .{
        .xdg_surface_id = undefined,
        .parent = .unattached,
        .scene_id = null,
        .rules = .{},
        .order = 1,
        .client = undefined,
    };
    const parent = try shell.popups.insert(allocator, initial);
    errdefer _ = shell.popups.remove(parent);
    var child_state = initial;
    child_state.order = 2;
    const child = try shell.popups.insert(allocator, child_state);
    errdefer _ = shell.popups.remove(child);
    defer {
        _ = shell.popups.remove(child);
        _ = shell.popups.remove(parent);
    }

    shell.popups.get(parent).?.grabbed = true;
    try std.testing.expect(std.meta.eql(parent, shell.topGrabbedPopup().?));
    try std.testing.expect(shell.topMappedGrabbedPopup() == null);
    shell.popups.get(parent).?.mapped = true;
    shell.popups.get(child).?.grabbed = true;
    try std.testing.expect(std.meta.eql(child, shell.topGrabbedPopup().?));
    try std.testing.expect(std.meta.eql(parent, shell.topMappedGrabbedPopup().?));
    shell.popups.get(child).?.mapped = true;
    try std.testing.expect(std.meta.eql(child, shell.topMappedGrabbedPopup().?));
}

test "hidden popup maps semantically without Scene policy" {
    const Support = struct {
        configure_count: usize = 0,

        fn geometry(_: *anyopaque, _: SurfaceRegistry.Id) ?Geometry {
            return .{ .x = 0, .y = 0, .width = 1, .height = 1 };
        }
        fn size(_: *anyopaque, _: SurfaceRegistry.Id) ?render.Size {
            return .{ .width = 1, .height = 1 };
        }
        fn bounds(_: *anyopaque, _: Scene.Position, _: render.Size, _: OutputLayout.Id) ?render.Rect {
            return .{ .x = 0, .y = 0, .width = 100, .height = 100 };
        }
        fn configureToplevel(_: *anyopaque, _: Dimensions, _: ToplevelConfigure, _: ConfigureToken) error{OutOfMemory}!void {}
        fn configurePopup(context: *anyopaque, _: PopupConfigure, _: ConfigureToken) error{OutOfMemory}!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.configure_count += 1;
        }
        fn ignore(_: *anyopaque) void {}
        fn ignoreFailure(_: *anyopaque, _: EndpointFailure) void {}

        fn endpoint(self: *@This()) SurfaceEndpoint {
            return .{
                .context = self,
                .configure_toplevel = configureToplevel,
                .configure_popup = configurePopup,
                .close = ignore,
                .popup_done = ignore,
                .report_failure = ignoreFailure,
            };
        }
    };

    var support: Support = .{};
    var scene: Scene = undefined;
    scene.init(std.testing.allocator);
    defer scene.deinit();
    var shell = XdgShell.init(
        std.testing.allocator,
        &scene,
        .{
            .context = &support,
            .subtree_geometry = Support.geometry,
            .surface_size = Support.size,
            .popup_output_bounds = Support.bounds,
        },
        .{ .index = 0, .generation = 1 },
    );
    defer shell.deinit();
    const client: ClientRegistry.Id = .{ .index = 1, .generation = 1 };
    const parent_surface = try shell.createSurface(.{ .index = 1, .generation = 1 }, client, support.endpoint());
    const popup_surface = try shell.createSurface(.{ .index = 2, .generation = 1 }, client, support.endpoint());
    const window_id = try shell.createToplevel(parent_surface, 1);
    const window = shell.windows.get(window_id).?;
    shell.xdg_surfaces.get(parent_surface).?.mapped = true;
    scene.setContentGeometry(window.scene_id, .{ .size = .{ .width = 1, .height = 1 } });
    scene.setMapped(window.scene_id, true);
    const rules: Rules = .{
        .size = .{ .width = 1, .height = 1 },
        .anchor_rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .reactive = true,
    };
    const popup_id = try shell.createPopup(popup_surface, parent_surface, rules);
    const scene_id = shell.popups.get(popup_id).?.scene_id.?;
    try std.testing.expect(shell.popupScenePresentationEnabled(popup_id));
    shell.setPopupScenePresentationEnabled(popup_id, false);
    shell.commitPopupBuffer(popup_surface, popup_id, .{
        .token = .{ .surface = popup_surface, .sequence = 1 },
        .popup = .{
            .rules = rules,
            .placement = .{
                .position = .{ .x = 1, .y = 2 },
                .dimensions = .{ .width = 1, .height = 1 },
            },
        },
    }) catch unreachable;

    try std.testing.expect(shell.popupMapped(popup_id));
    try std.testing.expect(!scene.popupFor(scene_id).?.mapped);
    shell.setPopupScenePresentationEnabled(popup_id, true);
    try std.testing.expect(shell.popupMapped(popup_id));
    try std.testing.expect(scene.popupFor(scene_id).?.mapped);
    shell.setPopupScenePresentationEnabled(popup_id, false);
    try std.testing.expect(shell.popupMapped(popup_id));
    try std.testing.expect(!scene.popupFor(scene_id).?.mapped);
    shell.setWindowPosition(window_id, .{ .x = 5, .y = 6 });
    try std.testing.expectEqual(@as(usize, 0), support.configure_count);

    shell.destroyPopup(popup_id);
    shell.destroyToplevel(window_id);
    shell.removeSurface(popup_surface);
    shell.removeSurface(parent_surface);
}

test "dismissed popup commits remain inert until role destruction" {
    const allocator = std.testing.allocator;
    var shell: XdgShell = undefined;
    shell.xdg_surfaces = .{};
    shell.popups = .{};
    defer shell.xdg_surfaces.deinit(allocator);
    defer shell.popups.deinit(allocator);

    const surface_id = try shell.xdg_surfaces.insert(allocator, .{
        .surface_id = undefined,
        .client = undefined,
        .endpoint = undefined,
        .mapped = true,
        .configured = true,
        .initial_configure_sent = true,
    });
    const popup_id = try shell.popups.insert(allocator, .{
        .xdg_surface_id = surface_id,
        .parent = .unattached,
        .scene_id = null,
        .rules = .{},
        .mapped = false,
        .dismissed = true,
        .order = 0,
        .client = undefined,
    });
    shell.xdg_surfaces.get(surface_id).?.role = .{ .popup = popup_id };
    defer {
        _ = shell.popups.remove(popup_id);
        _ = shell.xdg_surfaces.remove(surface_id);
    }

    try shell.afterAppliedCommit(surface_id, true, false, null);
    const surface = shell.xdg_surfaces.get(surface_id).?;
    try std.testing.expect(surface.mapped);
    try std.testing.expect(surface.configured);
    try std.testing.expect(surface.initial_configure_sent);
    try std.testing.expect(shell.popups.get(popup_id).?.dismissed);
}

test "xdg pixel-only window commits do not notify policy" {
    const dimensions: Dimensions = .{ .width = 800, .height = 600 };
    const token: ConfigureToken = .{ .surface = undefined, .sequence = 1 };

    try std.testing.expect(windowCommitNeedsNotification(false, null, null, dimensions));
    try std.testing.expect(windowCommitNeedsNotification(true, token, dimensions, dimensions));
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

test "window Scene presentation gate retains policy visibility and resets on unmap" {
    const allocator = std.testing.allocator;
    var window: WindowState = .{
        .xdg_surface_id = undefined,
        .scene_id = undefined,
        .unreliable_pid = 0,
        .mapped = true,
        .requested_scene_visibility = true,
        .scene_presentation_enabled = false,
    };
    defer window.deinit(allocator);

    try std.testing.expect(!windowSceneMapped(&window));
    window.scene_presentation_enabled = true;
    try std.testing.expect(windowSceneMapped(&window));
    window.scene_presentation_enabled = false;
    window.reset(allocator);
    try std.testing.expect(!window.requested_scene_visibility);
    window.mapped = true;
    window.scene_presentation_enabled = true;
    try std.testing.expect(!windowSceneMapped(&window));

    const mature_default: WindowState = .{
        .xdg_surface_id = undefined,
        .scene_id = undefined,
        .unreliable_pid = 0,
        .mapped = true,
    };
    try std.testing.expect(windowSceneMapped(&mature_default));
}

test "presentation handoff is atomic across listener failure and retry" {
    const allocator = std.testing.allocator;
    var scene: Scene = undefined;
    scene.init(allocator);
    defer scene.deinit();

    var shell = XdgShell.init(allocator, &scene, undefined, undefined);
    defer shell.deinit();
    const scene_id = try scene.addWindow(.{ .index = 1, .generation = 1 });
    defer scene.removeWindow(scene_id);
    const window_id = try shell.windows.insert(allocator, .{
        .xdg_surface_id = undefined,
        .scene_id = scene_id,
        .unreliable_pid = 0,
        .mapped = true,
        .requested_scene_visibility = true,
        .scene_presentation_enabled = false,
    });
    defer {
        shell.windows.get(window_id).?.deinit(allocator);
        _ = shell.windows.remove(window_id);
    }

    const Context = struct {
        shell: *XdgShell,
        window_id: WindowId,
        fail_enable: bool = true,
        transition_count: usize = 0,
        workspace_enrolled: bool = false,
        wm_presentation_enabled: bool = false,
        metadata_notifications: usize = 0,
        observer_saw_enabled: bool = false,

        fn ready(_: *anyopaque, _: WindowId) bool {
            return true;
        }
        fn listenerCommitted(_: *anyopaque, _: WindowId, _: ?ConfigureToken) bool {
            return true;
        }
        fn ignored(_: *anyopaque, _: WindowId) void {}
        fn metadataChanged(_: *anyopaque, _: WindowId) bool {
            return true;
        }
        fn interactionChanged(_: *anyopaque, _: WindowId, _: bool) void {}
        fn presentationChanged(
            context: *anyopaque,
            id: WindowId,
            enabled: bool,
        ) error{OutOfMemory}!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            std.debug.assert(std.meta.eql(id, self.window_id));
            std.debug.assert(
                self.shell.windows.get(id).?.scene_presentation_enabled != enabled,
            );
            self.transition_count += 1;
            if (enabled and self.fail_enable) return error.OutOfMemory;
            self.workspace_enrolled = enabled;
            self.wm_presentation_enabled = enabled;
        }
        fn request(_: *anyopaque, _: WindowId, _: WindowRequest) void {}
        fn observerCommitted(_: *anyopaque, _: WindowId) void {}
        fn observerMetadataChanged(context: *anyopaque, id: WindowId) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.metadata_notifications += 1;
            self.observer_saw_enabled = self.shell.windows.get(id).?.scene_presentation_enabled;
        }
    };
    var context: Context = .{ .shell = &shell, .window_id = window_id };
    shell.setWindowListener(.{
        .context = &context,
        .ready = Context.ready,
        .committed = Context.listenerCommitted,
        .unmapping = Context.ignored,
        .unmapped = Context.ignored,
        .destroyed = Context.ignored,
        .metadata_changed = Context.metadataChanged,
        .presentation_changed = Context.presentationChanged,
        .interaction_changed = Context.interactionChanged,
        .request = Context.request,
    });
    defer shell.clearWindowListener();
    try shell.addWindowObserver(.{
        .context = &context,
        .committed = Context.observerCommitted,
        .unmapped = Context.ignored,
        .destroyed = Context.ignored,
        .metadata_changed = Context.observerMetadataChanged,
        .state_changed = Context.ignored,
    });
    defer shell.removeWindowObserver(&context);

    try std.testing.expectError(
        error.OutOfMemory,
        shell.setWindowScenePresentationEnabled(window_id, true),
    );
    try std.testing.expectEqual(@as(usize, 1), context.transition_count);
    try std.testing.expect(!context.workspace_enrolled);
    try std.testing.expect(!context.wm_presentation_enabled);
    try std.testing.expect(!shell.windows.get(window_id).?.scene_presentation_enabled);
    try std.testing.expectEqual(@as(usize, 0), context.metadata_notifications);
    var scene_windows = scene.iterator();
    try std.testing.expect(!scene_windows.next().?.window.mapped);

    context.fail_enable = false;
    try shell.setWindowScenePresentationEnabled(window_id, true);
    try std.testing.expectEqual(@as(usize, 2), context.transition_count);
    try std.testing.expect(context.workspace_enrolled);
    try std.testing.expect(context.wm_presentation_enabled);
    try std.testing.expect(shell.windows.get(window_id).?.scene_presentation_enabled);
    try std.testing.expectEqual(@as(usize, 1), context.metadata_notifications);
    try std.testing.expect(context.observer_saw_enabled);
    scene_windows = scene.iterator();
    try std.testing.expect(scene_windows.next().?.window.mapped);

    try shell.setWindowScenePresentationEnabled(window_id, false);
    try std.testing.expectEqual(@as(usize, 3), context.transition_count);
    try std.testing.expect(!context.workspace_enrolled);
    try std.testing.expect(!context.wm_presentation_enabled);
    try std.testing.expect(!shell.windows.get(window_id).?.scene_presentation_enabled);
    try std.testing.expectEqual(@as(usize, 2), context.metadata_notifications);
    try std.testing.expect(!context.observer_saw_enabled);
    scene_windows = scene.iterator();
    try std.testing.expect(!scene_windows.next().?.window.mapped);
}

test "unmapping a toplevel reparents only its direct children" {
    const allocator = std.testing.allocator;
    var shell: XdgShell = undefined;
    shell.windows = .{};
    shell.window_listener = null;
    shell.window_observers = .empty;
    shell.notifying_window_observers = false;
    defer shell.windows.deinit(allocator);
    defer shell.window_observers.deinit(allocator);

    const initial: WindowState = .{
        .xdg_surface_id = undefined,
        .scene_id = undefined,
        .unreliable_pid = 0,
    };
    const grandparent = try shell.windows.insert(allocator, initial);
    errdefer _ = shell.windows.remove(grandparent);
    const parent = try shell.windows.insert(allocator, initial);
    errdefer _ = shell.windows.remove(parent);
    const child = try shell.windows.insert(allocator, initial);
    errdefer _ = shell.windows.remove(child);
    const sibling = try shell.windows.insert(allocator, initial);
    errdefer _ = shell.windows.remove(sibling);
    const grandchild = try shell.windows.insert(allocator, initial);
    errdefer _ = shell.windows.remove(grandchild);
    defer {
        _ = shell.windows.remove(grandchild);
        _ = shell.windows.remove(sibling);
        _ = shell.windows.remove(child);
        _ = shell.windows.remove(parent);
        _ = shell.windows.remove(grandparent);
    }

    shell.windows.get(parent).?.parent = grandparent;
    shell.windows.get(child).?.parent = parent;
    shell.windows.get(sibling).?.parent = parent;
    shell.windows.get(grandchild).?.parent = child;
    var parent_owner: u8 = 0;
    shell.windows.get(child).?.parent_owner = &parent_owner;

    shell.reparentChildren(parent, grandparent);
    try std.testing.expect(std.meta.eql(grandparent, shell.windows.get(child).?.parent.?));
    try std.testing.expectEqual(
        @as(?*anyopaque, &parent_owner),
        shell.windows.get(child).?.parent_owner,
    );
    try std.testing.expect(std.meta.eql(grandparent, shell.windows.get(sibling).?.parent.?));
    try std.testing.expect(std.meta.eql(child, shell.windows.get(grandchild).?.parent.?));

    shell.reparentChildren(grandparent, null);
    try std.testing.expect(shell.windows.get(parent).?.parent == null);
    try std.testing.expect(shell.windows.get(child).?.parent == null);
    try std.testing.expect(shell.windows.get(child).?.parent_owner == null);
    try std.testing.expect(shell.windows.get(sibling).?.parent == null);
    try std.testing.expect(std.meta.eql(child, shell.windows.get(grandchild).?.parent.?));
}
