//! Built-in, protocol-neutral workspace policy for XDG and Xwayland toplevels.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const slot_map = @import("slot_map.zig");
const Scene = @import("scene.zig");
const OutputLayout = @import("wayland/output_layout.zig");
const Surface = @import("wayland/surface.zig");
const Seat = @import("wayland/seat.zig");
const XdgShell = @import("wayland/xdg_shell.zig");
const LayerShell = @import("wayland/layer_shell.zig");
const WorkspaceProtocol = @import("wayland/workspace.zig");
const Xwm = @import("xwayland/xwm.zig");
const ConfigureTransaction = @import("window_manager/ConfigureTransaction.zig");
const XwaylandController = @import("window_manager/XwaylandController.zig");
const types = @import("window_manager/types.zig");
const drag_geometry = @import("window_manager/drag_geometry.zig");
const floating_placement = @import("window_manager/floating_placement.zig");
const floating_resize = @import("window_manager/floating_resize.zig");
const layout_mod = @import("window_manager/layout.zig");
const workspace_mod = @import("window_manager/workspace.zig");
const command_mod = @import("command.zig");
const Command = command_mod.Command;
const Direction = command_mod.Direction;

const wl = wayland.server.wl;
const PointerShape = wayland.server.wp.CursorShapeDeviceV1.Shape;
const workspace_count = 10;
const resize_edge_threshold: f64 = 8;
const tiling_drag_activation_threshold: f64 = 8;
const tiling_drag_output_edge_threshold: f64 = 32;

allocator: std.mem.Allocator,
outputs: *OutputLayout,
seat: *Seat,
default_output: OutputLayout.Id,
scene: *Scene,
xdg_shell: *XdgShell,
xwayland: XwaylandController,
layer_shell: *LayerShell,
workspace_protocol: *WorkspaceProtocol,
windows: WindowStore = .{},
known_xwayland: std.AutoHashMapUnmanaged(Xwm.WindowId, KnownXwaylandWindow) = .empty,
workspaces: std.ArrayList(OutputWorkspace) = .empty,
transaction: ConfigureTransaction = .{},
geometry_listener: ?GeometryTransitionListener = null,
configure_timer: *wl.EventSource,
layer_focus: LayerShell.FocusClass = .none,
session_locked: bool = false,
focus_follows_mouse: bool = true,
inner_gap: u32 = 12,
outer_gap: u32 = 12,
window_effects: WindowEffects = .{},
unfocused_window_border: ?Scene.Borders = null,
focused_window_border: ?Scene.Borders = null,
tiling_drag: ?TilingDrag = null,
toplevel_drag: ?ToplevelDrag = null,
interactive_resize: ?InteractiveResize = null,
session_listener: ?SessionListener = null,
pending_session_restores: std.AutoHashMapUnmanaged(XdgShell.WindowId, SessionState) = .empty,

const WindowStore = slot_map.SlotMap(Window, enum { builtin_window });
pub const WindowId = WindowStore.Id;

pub const WindowProtocol = enum { xdg_shell, xwayland };

pub const WindowEffects = struct {
    tiled: Scene.Effects = Scene.default_effects,
    tiled_focused: Scene.Effects = Scene.default_effects,
    floating: Scene.Effects = Scene.default_effects,
    floating_focused: Scene.Effects = Scene.default_effects,
};

pub const WindowRect = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

pub const WindowSnapshot = struct {
    id: WindowId,
    protocol: WindowProtocol,
    title: ?[]const u8,
    app_id: ?[]const u8,
    pid: ?i32,
    rect: ?WindowRect,
    output_name: []const u8,
    workspace: u8,
    focused: bool,
    visible: bool,
    floating: bool,
    fullscreen: bool,
    maximized: bool,
    minimized: bool,
};

pub const SessionState = struct {
    output_name: []const u8,
    workspace: u8,
    floating: bool,
    position: ?Scene.Position,
    size: types.Size,
    maximized: bool,
    fullscreen: bool,
    minimized: bool,
};

pub const SessionListener = struct {
    context: *anyopaque,
    state_for_remap: *const fn (*anyopaque, XdgShell.WindowId) ?SessionState,
    restored: *const fn (*anyopaque, XdgShell.WindowId) void,
    changed: *const fn (*anyopaque, XdgShell.WindowId) void,
};

/// Boundary between policy transactions and renderer-owned window snapshots.
/// `prepare` runs before any configure for the transaction; `published` runs
/// after scene positions have reached their final geometry. `appeared` reports
/// the first mapped publication, which has no old presentation to capture;
/// `closing` runs while the last presentation can still be captured. Workspace
/// switching similarly brackets the policy change and the transaction that
/// publishes the selected workspace.
pub const GeometryTransitionListener = struct {
    context: *anyopaque,
    prepare: *const fn (*anyopaque, GeometryTransition) void,
    published: *const fn (*anyopaque, Scene.Id) void,
    appeared: *const fn (*anyopaque, GeometryAppearance) void,
    closing: *const fn (*anyopaque, GeometryAppearance) void,
    removed: *const fn (*anyopaque, Scene.Id) void,
    workspace_switching: *const fn (*anyopaque, OutputLayout.Id) void,
    workspace_published: *const fn (*anyopaque, OutputLayout.Id) void,
};

pub const GeometryTransition = struct {
    scene_id: Scene.Id,
    surface_id: Surface.Id,
    output: OutputLayout.Id,
    old_rect: types.Rect,
    target_rect: types.Rect,
};

pub const GeometryAppearance = struct {
    scene_id: Scene.Id,
    surface_id: Surface.Id,
    output: OutputLayout.Id,
    target_rect: types.Rect,
    /// True when this appearance or closure is part of a tiled reflow.
    coordinated: bool,
};

const TilingDrag = struct {
    source: WindowId,
    initial_x: f64,
    initial_y: f64,
    target: ?TilingDragTarget = null,
};

const TilingDragTarget = union(enum) {
    window: WindowDropTarget,
    workspace: WorkspaceDropTarget,
};

const WindowDropTarget = struct {
    window: WindowId,
    position: layout_mod.DropPosition,
};

const WorkspaceDropTarget = struct {
    output: OutputLayout.Id,
    position: ?layout_mod.DropPosition = null,
};

const ToplevelDrag = struct {
    window: WindowId,
    grab_x: f64,
    grab_y: f64,
    modifier: bool = false,
    initial_position: Scene.Position,
    original_floating_override: ?bool,
    original_floating_position: ?Scene.Position,
    original_floating_restore_size: ?types.Size,
};

const InteractiveResize = union(enum) {
    floating: FloatingResize,
    tiled: TiledResize,
};

const FloatingResize = struct {
    window: WindowId,
    initial_rect: types.Rect,
    initial_pointer_x: f64,
    initial_pointer_y: f64,
    edges: floating_resize.Edges,
    constraints: types.SizeConstraints,
};

const TiledResize = struct {
    window: WindowId,
    output: OutputLayout.Id,
    workspace_number: u8,
    resize: layout_mod.Layout.Resize,
};

const KnownXwaylandWindow = struct {
    scene_id: Scene.Id,
    surface_id: Surface.Id,
};

const Window = struct {
    backend: Backend,
    scene_id: Scene.Id,
    surface_id: Surface.Id,
    workspace: usize,
    fixed_size_floating: bool = false,
    floating_override: ?bool = null,
    floating_restore_size: ?types.Size = null,
    floating_position: ?Scene.Position = null,
    tags: workspace_mod.TagSet = .{},
    serial: ?u32 = null,
    placement: ?types.LayoutPlan = null,
    published_rect: ?types.Rect = null,
    published_fullscreen: bool = false,
    published_once: bool = false,
    transition_prepared: bool = false,
    closing_prepared: bool = false,
    mapped: bool = false,
    minimized: bool = false,
    maximized: bool = false,
    fullscreen_output: ?OutputLayout.Id = null,
    urgent: bool = false,
    pending_activation: bool = false,

    const Backend = union(enum) {
        xdg: XdgShell.WindowId,
        xwayland: Xwm.WindowId,
    };
};

const OutputWorkspace = struct {
    output: OutputLayout.Id,
    number: u8,
    active: bool,
    transition_pending: bool = false,
    transition_inflight: bool = false,
    workspace: workspace_mod.Workspace = .{},
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    outputs: *OutputLayout,
    seat: *Seat,
    default_output: OutputLayout.Id,
    scene: *Scene,
    xdg_shell: *XdgShell,
    xwayland: XwaylandController,
    layer_shell: *LayerShell,
    workspace_protocol: *WorkspaceProtocol,
) !void {
    self.* = .{
        .allocator = allocator,
        .outputs = outputs,
        .seat = seat,
        .default_output = default_output,
        .scene = scene,
        .xdg_shell = xdg_shell,
        .xwayland = xwayland,
        .layer_shell = layer_shell,
        .workspace_protocol = workspace_protocol,
        .configure_timer = undefined,
    };
    var output_iterator = outputs.iterator();
    while (output_iterator.next()) |entry| {
        self.appendOutputWorkspaces(entry.id) catch |err| {
            for (self.workspaces.items) |*workspace| workspace.workspace.deinit(allocator);
            self.workspaces.deinit(allocator);
            return err;
        };
    }
    std.debug.assert(self.workspaceFor(default_output) != null);
    errdefer {
        for (self.workspaces.items) |*entry| entry.workspace.deinit(allocator);
        self.workspaces.deinit(allocator);
    }
    self.configure_timer = try display.getEventLoop().addTimer(*Self, configureTimeout, self);
    errdefer self.configure_timer.remove();
    xdg_shell.setWindowListener(.{
        .context = self,
        .ready = windowReady,
        .committed = windowCommitted,
        .unmapping = windowUnmapping,
        .unmapped = windowUnmapped,
        .destroyed = windowDestroyed,
        .metadata_changed = windowMetadataChanged,
        .request = windowRequest,
    });
    layer_shell.setPolicyListener(.{ .context = self, .supported = layerSupported, .changed = layerChanged });
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.session_listener == null);
    std.debug.assert(self.geometry_listener == null);
    self.layer_shell.clearPolicyListener();
    self.xdg_shell.clearWindowListener();
    self.configure_timer.remove();
    var windows = self.windows.iterator();
    while (windows.next()) |entry| entry.value.tags.deinit(self.allocator);
    while (self.windows.len() != 0) {
        var it = self.windows.iterator();
        _ = self.windows.remove(it.next().?.id);
    }
    self.windows.deinit(self.allocator);
    self.known_xwayland.deinit(self.allocator);
    self.pending_session_restores.deinit(self.allocator);
    for (self.workspaces.items) |*entry| entry.workspace.deinit(self.allocator);
    self.workspaces.deinit(self.allocator);
    self.* = undefined;
}

/// Copies the listener and retains its context until clearGeometryTransitionListener.
pub fn setGeometryTransitionListener(self: *Self, listener: GeometryTransitionListener) void {
    std.debug.assert(self.geometry_listener == null);
    self.geometry_listener = listener;
}

pub fn clearGeometryTransitionListener(self: *Self) void {
    std.debug.assert(self.geometry_listener != null);
    self.geometry_listener = null;
}

/// Copies the listener and retains its context until clearSessionListener.
pub fn setSessionListener(self: *Self, listener: SessionListener) void {
    std.debug.assert(self.session_listener == null);
    self.session_listener = listener;
}

pub fn clearSessionListener(self: *Self) void {
    std.debug.assert(self.session_listener != null);
    self.session_listener = null;
}

pub fn prepareSessionRestore(
    self: *Self,
    xdg_id: XdgShell.WindowId,
    state: SessionState,
) error{ InvalidWindow, AlreadyMapped, OutOfMemory }!void {
    const info = self.xdg_shell.windowInfo(xdg_id) orelse return error.InvalidWindow;
    if (info.ready or info.mapped or self.findXdg(xdg_id) != null) return error.AlreadyMapped;
    if (self.pending_session_restores.contains(xdg_id)) return error.AlreadyMapped;
    try self.pending_session_restores.put(self.allocator, xdg_id, state);
}

pub fn cancelSessionRestore(self: *Self, xdg_id: XdgShell.WindowId) void {
    _ = self.pending_session_restores.remove(xdg_id);
}

pub fn sessionState(self: *Self, xdg_id: XdgShell.WindowId) ?SessionState {
    const window = self.windows.get(self.findXdg(xdg_id) orelse return null) orelse return null;
    const workspace = self.workspaces.items[window.workspace];
    const output = self.outputs.get(workspace.output) orelse return null;
    const dimensions = self.currentDimensions(window);
    const size = window.floating_restore_size orelse if (window.placement) |placement|
        placement.rect.size
    else
        types.Size.init(
            @intCast(@max(1, dimensions.width)),
            @intCast(@max(1, dimensions.height)),
        );
    const position: ?Scene.Position = if (self.isFloating(window))
        window.floating_position orelse if (window.placement) |placement|
            .{ .x = placement.rect.x, .y = placement.rect.y }
        else
            null
    else
        null;
    return .{
        .output_name = output.name(),
        .workspace = workspace.number,
        .floating = self.isFloating(window),
        .position = position,
        .size = size,
        .maximized = window.maximized,
        .fullscreen = window.fullscreen_output != null,
        .minimized = window.minimized,
    };
}

/// Returns mapped windows at their currently published geometry. The caller
/// owns the returned slice; string fields borrow compositor-owned metadata.
pub fn windowSnapshots(
    self: *Self,
    allocator: std.mem.Allocator,
) error{OutOfMemory}![]WindowSnapshot {
    var result: std.ArrayList(WindowSnapshot) = .empty;
    errdefer result.deinit(allocator);
    try result.ensureTotalCapacity(allocator, self.windows.len());

    const focused_workspace = self.workspaceFor(self.default_output);
    var windows = self.windows.iterator();
    while (windows.next()) |entry| {
        const window = entry.value;
        if (!window.mapped) continue;
        const metadata: struct {
            protocol: WindowProtocol,
            title: ?[]const u8,
            app_id: ?[]const u8,
            pid: ?i32,
        } = switch (window.backend) {
            .xdg => |id| metadata: {
                const info = self.xdg_shell.windowInfo(id) orelse continue;
                break :metadata .{
                    .protocol = .xdg_shell,
                    .title = info.title,
                    .app_id = info.app_id,
                    .pid = info.unreliable_pid,
                };
            },
            .xwayland => |id| metadata: {
                const info = self.xwayland.window_info(self.xwayland.context, id) orelse continue;
                break :metadata .{
                    .protocol = .xwayland,
                    .title = info.title,
                    .app_id = info.app_id,
                    .pid = info.unreliable_pid,
                };
            },
        };
        const workspace = &self.workspaces.items[window.workspace];
        const output = self.outputs.get(workspace.output) orelse continue;
        const focused = !window.minimized and focused_workspace != null and
            window.workspace == focused_workspace.? and workspace.workspace.focused != null and
            neutral(entry.id).eql(workspace.workspace.focused.?);
        try result.append(allocator, .{
            .id = entry.id,
            .protocol = metadata.protocol,
            .title = metadata.title,
            .app_id = metadata.app_id,
            .pid = metadata.pid,
            .rect = if (window.published_rect) |rect| .{
                .x = rect.x,
                .y = rect.y,
                .width = rect.size.width,
                .height = rect.size.height,
            } else null,
            .output_name = output.name(),
            .workspace = workspace.number,
            .focused = focused,
            .visible = displayed(window.mapped, window.minimized, workspace.active, window.placement),
            .floating = self.isFloating(window),
            .fullscreen = window.fullscreen_output != null,
            .maximized = window.maximized,
            .minimized = window.minimized,
        });
    }
    return result.toOwnedSlice(allocator);
}

fn neutral(id: WindowId) types.WindowId {
    return .{ .index = id.index, .generation = id.generation };
}

fn internal(id: types.WindowId) WindowId {
    return .{ .index = id.index, .generation = id.generation };
}

fn findXdg(self: *Self, xdg_id: XdgShell.WindowId) ?WindowId {
    var it = self.windows.iterator();
    while (it.next()) |entry| switch (entry.value.backend) {
        .xdg => |candidate| if (std.meta.eql(candidate, xdg_id)) return entry.id,
        .xwayland => {},
    };
    return null;
}

fn findXwayland(self: *Self, xwayland_id: Xwm.WindowId) ?WindowId {
    var it = self.windows.iterator();
    while (it.next()) |entry| switch (entry.value.backend) {
        .xdg => {},
        .xwayland => |candidate| if (std.meta.eql(candidate, xwayland_id)) return entry.id,
    };
    return null;
}

fn transientParent(self: *Self, window: *const Window) ?WindowId {
    return switch (window.backend) {
        .xdg => |id| {
            const parent = (self.xdg_shell.windowInfo(id) orelse return null).parent orelse return null;
            return self.findXdg(parent);
        },
        .xwayland => |id| {
            const parent = (self.xwayland.window_info(self.xwayland.context, id) orelse return null).parent orelse return null;
            return self.findXwayland(parent);
        },
    };
}

fn fixedSizeWantsFloating(minimum: XdgShell.SizeHint, maximum: XdgShell.SizeHint) bool {
    return minimum.width != 0 and minimum.height != 0 and
        (minimum.width == maximum.width or minimum.height == maximum.height);
}

fn automaticallyFloating(self: *Self, window: *const Window) bool {
    return window.fixed_size_floating or self.transientParent(window) != null;
}

fn isFloating(self: *Self, window: *const Window) bool {
    return window.floating_override orelse self.automaticallyFloating(window);
}

fn setFullscreen(self: *Self, window: *Window, output: ?OutputLayout.Id) void {
    if (window.fullscreen_output == null and output != null and self.isFloating(window)) {
        const current = self.currentDimensions(window);
        window.floating_restore_size = types.Size.init(
            @intCast(@max(1, current.width)),
            @intCast(@max(1, current.height)),
        );
    }
    window.fullscreen_output = output;
    if (output == null and !self.isFloating(window)) window.floating_restore_size = null;
}

fn transientDepth(self: *Self, window: *const Window) usize {
    var depth: usize = 0;
    var candidate = window;
    while (self.transientParent(candidate)) |parent_id| {
        depth += 1;
        candidate = self.windows.get(parent_id) orelse break;
    }
    return depth;
}

fn transientIsVisible(self: *Self, window: *const Window) bool {
    if (self.transientParent(window) == null) return true;
    return window.placement != null and window.placement.?.visible;
}

fn syncTransientWorkspaces(self: *Self) error{OutOfMemory}!void {
    var remaining = self.windows.len();
    while (remaining > 0) : (remaining -= 1) {
        var changed = false;
        var it = self.windows.iterator();
        while (it.next()) |entry| {
            const parent = self.windows.get(self.transientParent(entry.value) orelse continue) orelse continue;
            const source = entry.value.workspace;
            const target = parent.workspace;
            if (source == target) continue;
            const moved = try workspace_mod.Workspace.moveWindow(
                self.allocator,
                &self.workspaces.items[source].workspace,
                &self.workspaces.items[target].workspace,
                neutral(entry.id),
            );
            std.debug.assert(moved);
            entry.value.workspace = target;
            self.reportWorkspaceOccupancy(source);
            self.reportWorkspaceOccupancy(target);
            self.reportWorkspaceUrgency(source);
            self.reportWorkspaceUrgency(target);
            changed = true;
        }
        if (!changed) return;
    }
}

fn addXdg(self: *Self, xdg_id: XdgShell.WindowId) !WindowId {
    if (self.findXdg(xdg_id)) |id| return id;
    const info = self.xdg_shell.windowInfo(xdg_id) orelse return error.OutOfMemory;
    const surface_id = self.xdg_shell.windowSurface(xdg_id) orelse return error.OutOfMemory;
    const restore = self.pending_session_restores.get(xdg_id);
    const default_workspace = if (info.parent) |parent|
        if (self.findXdg(parent)) |parent_id|
            self.windows.get(parent_id).?.workspace
        else
            self.initialWorkspace() orelse 0
    else
        self.initialWorkspace() orelse 0;
    const workspace = if (restore) |state|
        if (self.outputNamed(state.output_name)) |output|
            self.workspaceNumber(output, state.workspace) orelse default_workspace
        else
            default_workspace
    else
        default_workspace;
    const id = try self.windows.insert(self.allocator, .{
        .backend = .{ .xdg = xdg_id },
        .scene_id = info.scene_id,
        .surface_id = surface_id,
        .workspace = workspace,
        .fixed_size_floating = fixedSizeWantsFloating(info.min_size, info.max_size),
        .floating_override = if (restore) |state| state.floating else null,
        .floating_restore_size = if (restore) |state|
            if (state.floating) state.size else null
        else
            null,
        .floating_position = if (restore) |state| state.position else null,
        .minimized = if (restore) |state| state.minimized else info.requested_state.minimized,
        .maximized = if (restore) |state| state.maximized else info.requested_state.maximized,
        .fullscreen_output = if (restore) |state|
            if (state.fullscreen) self.workspaces.items[workspace].output else null
        else if (info.requested_state.fullscreen)
            if (info.requested_state.fullscreen_output) |output|
                if (self.outputs.get(output) != null) output else self.workspaces.items[workspace].output
            else
                self.workspaces.items[workspace].output
        else
            null,
    });
    errdefer _ = self.windows.remove(id);
    _ = try self.workspaces.items[workspace].workspace.insert(self.allocator, neutral(id));
    _ = self.workspaces.items[workspace].workspace.focus(neutral(id));
    // Keep compositor commands on the output selected for a new window. A
    // restored window must not change the user's current output selection.
    if (restore == null) self.default_output = self.workspaces.items[workspace].output;
    self.reportWorkspaceOccupancy(workspace);
    if (restore != null) std.debug.assert(self.pending_session_restores.remove(xdg_id));
    return id;
}

fn prepareClosing(self: *Self, id: WindowId) void {
    const window = self.windows.get(id) orelse return;
    if (window.closing_prepared or !window.mapped or window.minimized or
        window.fullscreen_output != null or self.transientParent(window) != null) return;
    const workspace = self.workspaces.items[window.workspace];
    if (!workspace.active) return;
    const rect = window.published_rect orelse return;
    if (self.geometry_listener) |listener| listener.closing(listener.context, .{
        .scene_id = window.scene_id,
        .surface_id = window.surface_id,
        .output = workspace.output,
        .target_rect = rect,
        .coordinated = !self.isFloating(window),
    });
    window.closing_prepared = true;
}

fn removeId(self: *Self, id: WindowId) void {
    self.prepareClosing(id);
    const pending = self.windows.get(id).?.serial != null;
    self.removeWindowPointerInteractions(id);
    var window = self.windows.remove(id).?;
    if (self.geometry_listener) |listener| listener.removed(listener.context, window.scene_id);
    _ = self.workspaces.items[window.workspace].workspace.remove(neutral(id));
    self.reportWorkspaceOccupancy(window.workspace);
    self.reportWorkspaceUrgency(window.workspace);
    window.tags.deinit(self.allocator);
    if (self.transaction.removed(pending)) self.publish();
    self.relayout();
}

fn removeWindowPointerInteractions(self: *Self, id: WindowId) void {
    if (self.tiling_drag) |*drag| {
        if (std.meta.eql(drag.source, id)) {
            self.tiling_drag = null;
        } else if (drag.target) |target| switch (target) {
            .window => |window_target| if (std.meta.eql(window_target.window, id)) {
                drag.target = null;
            },
            .workspace => {},
        };
    }
    if (self.toplevel_drag) |drag| {
        if (std.meta.eql(drag.window, id)) self.toplevel_drag = null;
    }
    if (self.interactivelyResizing(id)) self.cancelInteractiveResize();
}

fn removeXdg(self: *Self, xdg_id: XdgShell.WindowId) void {
    self.removeId(self.findXdg(xdg_id) orelse return);
}

fn addXwayland(self: *Self, xwayland_id: Xwm.WindowId) !?WindowId {
    if (self.findXwayland(xwayland_id)) |id| return id;
    const known = self.known_xwayland.get(xwayland_id) orelse return null;
    const info = self.xwayland.window_info(self.xwayland.context, xwayland_id) orelse return null;
    if (!info.participatesInWindowManagement()) return null;
    const workspace = self.initialWorkspace() orelse return null;
    const id = try self.windows.insert(self.allocator, .{
        .backend = .{ .xwayland = xwayland_id },
        .scene_id = known.scene_id,
        .surface_id = known.surface_id,
        .workspace = workspace,
        .mapped = info.mapped,
        .minimized = info.minimized,
        .maximized = info.maximized,
        .fullscreen_output = if (info.fullscreen) self.workspaces.items[workspace].output else null,
    });
    errdefer _ = self.windows.remove(id);
    _ = try self.workspaces.items[workspace].workspace.insert(self.allocator, neutral(id));
    _ = self.workspaces.items[workspace].workspace.focus(neutral(id));
    self.default_output = self.workspaces.items[workspace].output;
    self.reportWorkspaceOccupancy(workspace);
    return id;
}

fn reportWorkspaceOccupancy(self: *Self, index: usize) void {
    const entry = &self.workspaces.items[index];
    self.workspace_protocol.setOccupied(entry.output, entry.number, entry.workspace.members.items.len != 0);
}

fn reportWorkspaceUrgency(self: *Self, index: usize) void {
    const entry = &self.workspaces.items[index];
    for (entry.workspace.members.items) |member| {
        const window = self.windows.get(internal(member)) orelse continue;
        if (window.urgent) {
            self.workspace_protocol.setUrgent(entry.output, entry.number, true);
            return;
        }
    }
    self.workspace_protocol.setUrgent(entry.output, entry.number, false);
}

fn moveWindowToWorkspace(
    self: *Self,
    id: WindowId,
    target: usize,
) error{OutOfMemory}!bool {
    const window = self.windows.get(id) orelse return false;
    const source = window.workspace;
    if (source == target) return false;
    const moved = try workspace_mod.Workspace.moveWindow(
        self.allocator,
        &self.workspaces.items[source].workspace,
        &self.workspaces.items[target].workspace,
        neutral(id),
    );
    if (!moved) return false;
    window.workspace = target;
    self.reportWorkspaceOccupancy(source);
    self.reportWorkspaceOccupancy(target);
    self.reportWorkspaceUrgency(source);
    self.reportWorkspaceUrgency(target);
    return true;
}

fn workspaceFor(self: *Self, output: OutputLayout.Id) ?usize {
    for (self.workspaces.items, 0..) |entry, i| {
        if (entry.active and std.meta.eql(entry.output, output)) return i;
    }
    return null;
}

fn workspaceNumber(self: *Self, output: OutputLayout.Id, number: u8) ?usize {
    if (number == 0 or number > workspace_count) return null;
    for (self.workspaces.items, 0..) |entry, i| {
        if (entry.number == number and std.meta.eql(entry.output, output)) return i;
    }
    return null;
}

fn outputNamed(self: *Self, name: []const u8) ?OutputLayout.Id {
    var outputs = self.outputs.iterator();
    while (outputs.next()) |entry| {
        if (std.mem.eql(u8, entry.output.name(), name)) return entry.id;
    }
    return null;
}

fn initialWorkspace(self: *Self) ?usize {
    const output = if (self.seat.pointerPosition()) |position|
        if (self.outputs.outputAt(position.x, position.y)) |entry| entry.id else self.default_output
    else
        self.default_output;
    return self.workspaceFor(output) orelse self.workspaceFor(self.default_output);
}

fn appendOutputWorkspaces(self: *Self, output: OutputLayout.Id) !void {
    const original_len = self.workspaces.items.len;
    errdefer {
        for (self.workspaces.items[original_len..]) |*entry| entry.workspace.deinit(self.allocator);
        self.workspaces.items.len = original_len;
    }
    for (1..workspace_count + 1) |number| {
        try self.workspaces.append(self.allocator, .{
            .output = output,
            .number = @intCast(number),
            .active = number == 1,
        });
        self.workspaces.items[self.workspaces.items.len - 1].workspace.layout.setGaps(
            self.inner_gap,
            self.outer_gap,
        );
    }
}

pub fn outputAdded(self: *Self, output: OutputLayout.Id) !void {
    if (self.workspaceFor(output) == null) try self.appendOutputWorkspaces(output);
    self.relayout();
}

pub fn outputRemoved(self: *Self, output: OutputLayout.Id) error{OutOfMemory}!void {
    _ = self.workspaceFor(output) orelse return;
    var replacement: ?usize = null;
    for (self.workspaces.items, 0..) |entry, index| {
        if (!entry.active or std.meta.eql(entry.output, output)) continue;
        replacement = index;
        break;
    }
    var replacement_index = replacement orelse return;
    const replacement_output = self.workspaces.items[replacement_index].output;
    if (self.tiling_drag) |*drag| if (drag.target) |target| switch (target) {
        .window => {},
        .workspace => |workspace_target| if (std.meta.eql(workspace_target.output, output)) {
            drag.target = null;
        },
    };
    if (self.interactive_resize) |resize| switch (resize) {
        .floating => {},
        .tiled => |tiled| if (std.meta.eql(tiled.output, output)) self.cancelInteractiveResize(),
    };
    var migration_count: usize = 0;
    var it = self.windows.iterator();
    while (it.next()) |entry| {
        if (std.meta.eql(self.workspaces.items[entry.value.workspace].output, output)) {
            migration_count += 1;
        }
    }
    try self.workspaces.items[replacement_index].workspace.ensureInsertCapacity(
        self.allocator,
        migration_count,
    );
    it = self.windows.iterator();
    while (it.next()) |entry| {
        const source_index = entry.value.workspace;
        if (std.meta.eql(self.workspaces.items[source_index].output, output)) {
            const moved = try workspace_mod.Workspace.moveWindow(
                self.allocator,
                &self.workspaces.items[source_index].workspace,
                &self.workspaces.items[replacement_index].workspace,
                neutral(entry.id),
            );
            std.debug.assert(moved);
            entry.value.workspace = replacement_index;
            self.reportWorkspaceOccupancy(source_index);
            self.reportWorkspaceOccupancy(replacement_index);
        }
        if (entry.value.fullscreen_output) |fullscreen_output| {
            if (std.meta.eql(fullscreen_output, output)) {
                entry.value.fullscreen_output = self.workspaces.items[entry.value.workspace].output;
            }
        }
    }
    self.reportWorkspaceUrgency(replacement_index);
    var index = self.workspaces.items.len;
    while (index > 0) {
        index -= 1;
        if (!std.meta.eql(self.workspaces.items[index].output, output)) continue;
        self.workspaces.items[index].workspace.deinit(self.allocator);
        _ = self.workspaces.orderedRemove(index);
        if (replacement_index > index) replacement_index -= 1;
        it = self.windows.iterator();
        while (it.next()) |entry| {
            if (entry.value.workspace > index) entry.value.workspace -= 1;
        }
    }
    if (std.meta.eql(self.default_output, output)) self.default_output = replacement_output;
    self.relayout();
}

pub fn outputStateChanged(
    self: *Self,
    _: OutputLayout.Id,
    position_changed: bool,
    dimensions_changed: bool,
) void {
    if (position_changed or dimensions_changed) self.relayout();
}

pub fn setDefaultOutput(self: *Self, output: OutputLayout.Id) void {
    std.debug.assert(self.workspaceFor(output) != null);
    self.default_output = output;
}

pub fn setGaps(self: *Self, inner_gap: u32, outer_gap: u32) void {
    std.debug.assert(inner_gap <= 256 and outer_gap <= 256);
    if (self.inner_gap == inner_gap and self.outer_gap == outer_gap) return;
    self.inner_gap = inner_gap;
    self.outer_gap = outer_gap;
    for (self.workspaces.items) |*entry| {
        entry.workspace.layout.setGaps(inner_gap, outer_gap);
    }
    self.relayout();
}

pub fn setWindowEffects(self: *Self, effects: WindowEffects) void {
    if (std.meta.eql(self.window_effects, effects)) return;
    self.window_effects = effects;
    var it = self.windows.iterator();
    while (it.next()) |entry| {
        const window = entry.value;
        self.scene.setEffects(
            window.scene_id,
            self.effectsForWindow(window, self.windowFocused(entry.id, window)),
        );
    }
}

pub fn setWindowBorders(
    self: *Self,
    unfocused_border: ?Scene.Borders,
    focused_border: ?Scene.Borders,
) void {
    if (std.meta.eql(self.unfocused_window_border, unfocused_border) and
        std.meta.eql(self.focused_window_border, focused_border)) return;
    self.unfocused_window_border = unfocused_border;
    self.focused_window_border = focused_border;
    var it = self.windows.iterator();
    while (it.next()) |entry| {
        const window = entry.value;
        self.scene.setBorders(
            window.scene_id,
            self.borderForWindow(window, self.windowFocused(entry.id, window)),
        );
    }
}

fn windowFocused(self: *Self, id: WindowId, window: *const Window) bool {
    const focused = self.workspaces.items[window.workspace].workspace.focused orelse return false;
    return !window.minimized and neutral(id).eql(focused);
}

fn effectsForWindow(self: *Self, window: *const Window, focused: bool) Scene.Effects {
    return effectsForWindowState(
        self.window_effects,
        self.isFloating(window),
        focused,
        window.fullscreen_output != null,
    );
}

fn effectsForWindowState(
    effects: WindowEffects,
    floating: bool,
    focused: bool,
    fullscreen: bool,
) Scene.Effects {
    if (fullscreen) return .{};
    if (floating) return if (focused) effects.floating_focused else effects.floating;
    return if (focused) effects.tiled_focused else effects.tiled;
}

fn borderForWindow(self: *Self, window: *const Window, focused: bool) ?Scene.Borders {
    const fullscreen = window.fullscreen_output != null;
    return borderForWindowState(
        self.unfocused_window_border,
        self.focused_window_border,
        focused,
        fullscreen,
    );
}

fn borderForWindowState(
    unfocused_border: ?Scene.Borders,
    focused_border: ?Scene.Borders,
    focused: bool,
    fullscreen: bool,
) ?Scene.Borders {
    if (fullscreen) return null;
    return if (focused) focused_border else unfocused_border;
}

pub fn focusedSurface(self: *Self) ?Surface.Id {
    const workspace_index = self.workspaceFor(self.default_output) orelse return null;
    const focused = self.workspaces.items[workspace_index].workspace.focused orelse return null;
    const window = self.windows.get(internal(focused)) orelse return null;
    if (window.minimized or !window.mapped) return null;
    return window.surface_id;
}

/// Applies xdg-activation policy to a managed surface. Requests without
/// interaction provenance notify the shell without stealing focus.
pub fn activationRequested(
    self: *Self,
    surface_id: Surface.Id,
    proven_interaction: bool,
) bool {
    const id = self.windowForSurface(surface_id) orelse return false;
    if (!proven_interaction or self.layer_focus == .exclusive) {
        _ = self.setWindowUrgent(id, true);
        return false;
    }
    const window = self.windows.get(id) orelse return false;
    if (!window.mapped) {
        window.pending_activation = true;
        return false;
    }
    return self.activateWindow(id);
}

fn activateWindow(self: *Self, id: WindowId) bool {
    if (self.session_locked or self.layer_focus == .exclusive) {
        _ = self.setWindowUrgent(id, true);
        return false;
    }
    const window = self.windows.get(id) orelse return false;
    std.debug.assert(window.mapped);
    const was_minimized = window.minimized;
    window.minimized = false;
    const urgency_changed = self.setWindowUrgent(id, false);
    const workspace_index = window.workspace;
    const workspace = &self.workspaces.items[workspace_index];
    const target = neutral(id);
    const focus_changed = workspace.workspace.focused == null or
        !workspace.workspace.focused.?.eql(target);
    if (focus_changed) {
        const changed = workspace.workspace.focus(target);
        std.debug.assert(changed);
    }
    _ = self.layer_shell.relinquishNonExclusiveFocus();
    if (!workspace.active) {
        const activated = self.activateWorkspace(workspace.output, workspace.number, true);
        std.debug.assert(activated);
        return true;
    }

    const output_changed = !std.meta.eql(self.default_output, workspace.output);
    self.default_output = workspace.output;
    const changed = was_minimized or urgency_changed or focus_changed or output_changed;
    if (changed) self.relayout();
    return changed;
}

fn setWindowUrgent(self: *Self, id: WindowId, urgent: bool) bool {
    const window = self.windows.get(id) orelse return false;
    const workspace = &self.workspaces.items[window.workspace];
    if (urgent and self.selectionOwnsKeyboardFocus() and
        window.mapped and !window.minimized and workspace.active and
        std.meta.eql(self.default_output, workspace.output) and
        workspace.workspace.focused != null and workspace.workspace.focused.?.eql(neutral(id)))
    {
        return false;
    }
    if (window.urgent == urgent) return false;
    window.urgent = urgent;
    self.reportWorkspaceUrgency(window.workspace);
    return true;
}

pub fn setSessionLocked(self: *Self, locked: bool) void {
    self.session_locked = locked;
    if (!locked) self.clearFocusedUrgency();
}

fn selectionOwnsKeyboardFocus(self: *const Self) bool {
    return !self.session_locked and self.layer_focus == .none;
}

test "workspace selection owns keyboard focus only without lock or layer focus" {
    var manager: Self = undefined;
    manager.session_locked = false;
    manager.layer_focus = .none;
    try std.testing.expect(manager.selectionOwnsKeyboardFocus());

    manager.layer_focus = .non_exclusive;
    try std.testing.expect(!manager.selectionOwnsKeyboardFocus());
    manager.layer_focus = .exclusive;
    try std.testing.expect(!manager.selectionOwnsKeyboardFocus());

    manager.layer_focus = .none;
    manager.session_locked = true;
    try std.testing.expect(!manager.selectionOwnsKeyboardFocus());
}

fn clearFocusedUrgency(self: *Self) void {
    if (!self.selectionOwnsKeyboardFocus()) return;
    const workspace_index = self.workspaceFor(self.default_output) orelse return;
    const workspace = &self.workspaces.items[workspace_index];
    const focused = workspace.workspace.focused orelse return;
    const window = self.windows.get(internal(focused)) orelse return;
    if (!window.mapped or window.minimized or !window.urgent) return;
    window.urgent = false;
    self.reportWorkspaceUrgency(workspace_index);
}

pub fn setFocusFollowsMouse(self: *Self, enabled: bool) void {
    self.focus_follows_mouse = enabled;
}

pub fn pointerMoved(self: *Self, root: ?Surface.Id) void {
    if (!self.focus_follows_mouse) return;
    self.focusPointerRoot(root);
}

pub fn pointerButton(self: *Self, root: ?Surface.Id, state: wl.Pointer.ButtonState) void {
    if (state != .pressed) return;
    self.focusPointerRoot(root);
}

fn focusPointerRoot(self: *Self, root: ?Surface.Id) void {
    if (self.layer_focus == .exclusive) return;
    const id = self.windowForSurface(root orelse return) orelse return;
    if (self.focusWindow(id)) self.relayout();
}

fn windowForSurface(self: *Self, surface_id: Surface.Id) ?WindowId {
    var it = self.windows.iterator();
    while (it.next()) |entry| {
        if (std.meta.eql(entry.value.surface_id, surface_id)) return entry.id;
    }
    const xdg_id = self.xdg_shell.surfaceRootWindow(surface_id) orelse return null;
    return self.findXdg(xdg_id);
}

fn focusWindow(self: *Self, id: WindowId) bool {
    const window = self.windows.get(id) orelse return false;
    const workspace = &self.workspaces.items[window.workspace];
    if (!workspace.active) return false;
    const target = neutral(id);
    const output_changed = !std.meta.eql(self.default_output, workspace.output);
    const focus_changed = workspace.workspace.focused == null or
        !workspace.workspace.focused.?.eql(target);
    _ = self.layer_shell.relinquishNonExclusiveFocus();
    if (!output_changed and !focus_changed) return false;
    self.default_output = workspace.output;
    if (focus_changed) {
        const changed = workspace.workspace.focus(target);
        std.debug.assert(changed);
    }
    return true;
}

/// Starts a compositor-owned Super+pointer tiling drag. The server owns the
/// physical button grab; this object owns only policy and drop state.
pub fn beginTilingDrag(
    self: *Self,
    root: ?Surface.Id,
    pointer_x: f64,
    pointer_y: f64,
) bool {
    if (self.pointerInteractionActive() or self.layer_focus == .exclusive) return false;
    const id = self.windowForSurface(root orelse return false) orelse return false;
    const window = self.windows.get(id) orelse return false;
    if (!self.isDraggableTiledWindow(window)) return false;
    const workspace = &self.workspaces.items[window.workspace];
    if (!workspace.active) return false;
    self.tiling_drag = .{
        .source = id,
        .initial_x = pointer_x,
        .initial_y = pointer_y,
    };
    if (self.focusWindow(id)) self.relayout();
    return true;
}

pub fn tilingDragActive(self: *const Self) bool {
    return self.tiling_drag != null;
}

/// Updates the drop target and returns whether the visible preview changed.
pub fn updateTilingDrag(self: *Self, x: f64, y: f64) bool {
    const drag = if (self.tiling_drag) |*value| value else return false;
    const previous = drag.target;
    drag.target = null;
    const source = self.windows.get(drag.source) orelse return previous != null;
    if (!self.isDraggableTiledWindow(source)) return previous != null;
    const source_workspace = &self.workspaces.items[source.workspace];
    if (!source_workspace.active) return previous != null;
    const output = self.outputs.outputAt(x, y) orelse return previous != null;
    const workspace_index = self.workspaceFor(output.id) orelse return previous != null;
    const workspace = &self.workspaces.items[workspace_index];
    var has_peer = false;
    for (workspace.workspace.members.items) |member| {
        const id = internal(member);
        if (std.meta.eql(id, drag.source)) continue;
        const window = self.windows.get(id) orelse continue;
        if (!self.isDraggableTiledWindow(window)) continue;
        has_peer = true;
        break;
    }
    const activated = @abs(x - drag.initial_x) >= tiling_drag_activation_threshold or
        @abs(y - drag.initial_y) >= tiling_drag_activation_threshold;
    if (has_peer and activated) {
        const position = output.output.logicalPosition();
        const size = output.output.logicalSize();
        const bounds: types.Rect = .{
            .x = position.x,
            .y = position.y,
            .size = types.Size.init(size.width, size.height),
        };
        if (drag_geometry.outputEdgePosition(x, y, bounds, tiling_drag_output_edge_threshold)) |edge| {
            drag.target = .{ .workspace = .{
                .output = output.id,
                .position = edge,
            } };
            return !std.meta.eql(previous, drag.target);
        }
    }
    for (workspace.workspace.members.items) |member| {
        const id = internal(member);
        if (std.meta.eql(id, drag.source)) continue;
        const window = self.windows.get(id) orelse continue;
        if (!self.isDraggableTiledWindow(window)) continue;
        const plan = window.placement orelse continue;
        const rect = drag_geometry.hitTest(x, y, plan) orelse continue;
        drag.target = .{ .window = .{
            .window = id,
            .position = drag_geometry.dropPosition(x, y, rect),
        } };
        break;
    }
    if (drag.target == null and workspace_index != source.workspace and activated) {
        drag.target = .{ .workspace = .{ .output = output.id } };
    }
    return !std.meta.eql(previous, drag.target);
}

pub fn tilingDragPreview(self: *Self) ?types.Rect {
    const drag = self.tiling_drag orelse return null;
    const drag_target = drag.target orelse return null;
    return switch (drag_target) {
        .window => |window_target| preview: {
            const target = self.windows.get(window_target.window) orelse return null;
            if (!self.isDraggableTiledWindow(target)) return null;
            const rect = drag_geometry.visibleRect(target.placement orelse return null) orelse return null;
            break :preview drag_geometry.dropPreview(rect, window_target.position);
        },
        .workspace => |workspace_target| preview: {
            const workspace_index = self.workspaceFor(workspace_target.output) orelse return null;
            const workspace = &self.workspaces.items[workspace_index];
            if (!workspace.active) return null;
            const area = self.layer_shell.usableAreaFor(workspace_target.output) orelse return null;
            if (area.width <= 0 or area.height <= 0) return null;
            const rect: types.Rect = .{
                .x = area.x,
                .y = area.y,
                .size = types.Size.init(@intCast(area.width), @intCast(area.height)),
            };
            break :preview if (workspace_target.position) |position|
                drag_geometry.dropPreview(rect, position)
            else
                rect;
        },
    };
}

/// Ends the pointer grab by applying the selected target-relative placement.
pub fn endTilingDrag(self: *Self, commit: bool) bool {
    const drag = self.tiling_drag orelse return false;
    self.tiling_drag = null;
    if (!commit) return true;
    const drag_target = drag.target orelse return true;
    const source = self.windows.get(drag.source) orelse return true;
    if (!self.isDraggableTiledWindow(source)) return true;
    const source_workspace = source.workspace;
    if (!self.workspaces.items[source_workspace].active) return true;
    var workspace_index = source_workspace;
    const changed = switch (drag_target) {
        .window => |window_target| changed: {
            const target = self.windows.get(window_target.window) orelse return true;
            if (!self.isDraggableTiledWindow(target) or
                !self.workspaces.items[target.workspace].active) return true;
            workspace_index = target.workspace;
            const moved = source_workspace != workspace_index and
                (self.moveWindowToWorkspace(drag.source, workspace_index) catch return true);
            if (source_workspace != workspace_index and !moved) return true;
            const repositioned = self.workspaces.items[workspace_index].workspace.repositionWindow(
                neutral(drag.source),
                neutral(window_target.window),
                window_target.position,
            );
            break :changed moved or repositioned;
        },
        .workspace => |workspace_target| changed: {
            workspace_index = self.workspaceFor(workspace_target.output) orelse return true;
            if (!self.workspaces.items[workspace_index].active) return true;
            const moved = source_workspace != workspace_index and
                (self.moveWindowToWorkspace(drag.source, workspace_index) catch return true);
            if (source_workspace != workspace_index and !moved) return true;
            const repositioned = if (workspace_target.position) |position|
                self.workspaces.items[workspace_index].workspace.repositionWindowAtRoot(
                    neutral(drag.source),
                    position,
                )
            else
                false;
            break :changed moved or repositioned;
        },
    };
    if (!changed) return true;
    _ = self.workspaces.items[workspace_index].workspace.focus(neutral(drag.source));
    self.default_output = self.workspaces.items[workspace_index].output;
    self.relayout();
    return true;
}

pub fn beginModifierMove(
    self: *Self,
    root: ?Surface.Id,
    pointer_x: f64,
    pointer_y: f64,
) bool {
    if (self.beginTilingDrag(root, pointer_x, pointer_y)) return true;
    const id = self.windowForSurface(root orelse return false) orelse return false;
    const window = self.windows.get(id) orelse return false;
    if (!self.isFloating(window)) return false;
    return self.beginWindowMove(id, pointer_x, pointer_y, 0, 0, false, true, false);
}

pub fn beginInteractiveResize(
    self: *Self,
    root: ?Surface.Id,
    pointer_x: f64,
    pointer_y: f64,
) bool {
    if (self.pointerInteractionActive() or self.layer_focus == .exclusive) return false;
    if (root) |surface_id| {
        const id = self.windowForSurface(surface_id) orelse return false;
        return self.beginInteractiveResizeWindow(id, pointer_x, pointer_y);
    }
    for (self.workspaces.items) |workspace| {
        if (!workspace.active) continue;
        for (workspace.workspace.members.items) |member| {
            const id = internal(member);
            const window = self.windows.get(id) orelse continue;
            if (self.isFloating(window)) continue;
            if (self.beginInteractiveResizeWindow(id, pointer_x, pointer_y)) return true;
        }
    }
    return false;
}

fn beginInteractiveResizeWindow(
    self: *Self,
    id: WindowId,
    pointer_x: f64,
    pointer_y: f64,
) bool {
    const resize = self.interactiveResizeForWindow(id, pointer_x, pointer_y) orelse return false;
    self.interactive_resize = resize;
    const window = self.windows.get(id).?;
    const workspace = &self.workspaces.items[window.workspace];
    switch (resize) {
        .floating => {
            _ = workspace.workspace.raise(neutral(id));
            self.scene.placeTop(window.scene_id);
        },
        .tiled => {},
    }
    _ = workspace.workspace.focus(neutral(id));
    self.default_output = workspace.output;
    self.relayout();
    return true;
}

fn interactiveResizeForWindow(
    self: *Self,
    id: WindowId,
    pointer_x: f64,
    pointer_y: f64,
) ?InteractiveResize {
    const window = self.windows.get(id) orelse return null;
    if (!window.mapped or window.minimized or window.fullscreen_output != null) return null;
    const workspace = &self.workspaces.items[window.workspace];
    if (!workspace.active) return null;
    if (self.isFloating(window)) {
        const rect = (window.placement orelse return null).rect;
        const edges = floating_resize.edgesAt(
            rect,
            pointer_x,
            pointer_y,
            resize_edge_threshold,
        ) orelse return null;
        return .{ .floating = .{
            .window = id,
            .initial_rect = rect,
            .initial_pointer_x = pointer_x,
            .initial_pointer_y = pointer_y,
            .edges = edges,
            .constraints = self.windowSizeConstraints(window),
        } };
    }
    if (!self.isDraggableTiledWindow(window)) return null;
    const resize = workspace.workspace.layout.beginResize(
        neutral(id),
        pointer_x,
        pointer_y,
        resize_edge_threshold,
    ) orelse return null;
    return .{ .tiled = .{
        .window = id,
        .output = workspace.output,
        .workspace_number = workspace.number,
        .resize = resize,
    } };
}

pub fn compositorPointerGrabActive(self: *const Self) bool {
    return self.tiling_drag != null or self.interactive_resize != null or
        if (self.toplevel_drag) |drag| drag.modifier else false;
}

pub fn directManipulationActive(self: *const Self) bool {
    return self.pointerInteractionActive();
}

pub fn interactiveResizeCursorShape(self: *const Self) ?PointerShape {
    const resize = self.interactive_resize orelse return null;
    return cursorShapeForInteractiveResize(resize);
}

pub fn resizeCursorShapeAt(
    self: *Self,
    root: ?Surface.Id,
    pointer_x: f64,
    pointer_y: f64,
) ?PointerShape {
    if (self.pointerInteractionActive() or self.layer_focus == .exclusive) return null;
    if (root) |surface_id| {
        const id = self.windowForSurface(surface_id) orelse return null;
        const resize = self.interactiveResizeForWindow(id, pointer_x, pointer_y) orelse return null;
        return cursorShapeForInteractiveResize(resize);
    }
    for (self.workspaces.items) |workspace| {
        if (!workspace.active) continue;
        for (workspace.workspace.members.items) |member| {
            const id = internal(member);
            const window = self.windows.get(id) orelse continue;
            if (self.isFloating(window)) continue;
            const resize = self.interactiveResizeForWindow(id, pointer_x, pointer_y) orelse continue;
            return cursorShapeForInteractiveResize(resize);
        }
    }
    return null;
}

fn cursorShapeForInteractiveResize(resize: InteractiveResize) PointerShape {
    return switch (resize) {
        .floating => |value| floating_resize.cursorShape(value.edges),
        .tiled => |value| switch (value.resize) {
            .tiled => |tiled| switch (tiled.axis) {
                .horizontal => .ew_resize,
                .vertical => .ns_resize,
            },
        },
    };
}

pub fn updateCompositorPointerGrab(self: *Self, pointer_x: f64, pointer_y: f64) bool {
    if (self.tiling_drag != null) return self.updateTilingDrag(pointer_x, pointer_y);
    if (self.toplevel_drag) |drag| {
        if (drag.modifier) {
            self.updateToplevelDrag(pointer_x, pointer_y);
            return true;
        }
    }
    const resize = self.interactive_resize orelse return false;
    return switch (resize) {
        .floating => |value| self.updateFloatingResize(value, pointer_x, pointer_y),
        .tiled => |value| update: {
            const layout = self.tiledResizeLayout(value) orelse break :update false;
            const changed = layout.updateResize(
                value.resize,
                pointer_x,
                pointer_y,
            );
            if (changed) self.relayout();
            break :update changed;
        },
    };
}

pub fn endCompositorPointerGrab(self: *Self, commit: bool) bool {
    if (self.tiling_drag != null) return self.endTilingDrag(commit);
    if (self.toplevel_drag) |drag| {
        if (drag.modifier) {
            self.toplevel_drag = null;
            if (!commit) if (self.windows.get(drag.window)) |window| {
                window.floating_override = drag.original_floating_override;
                window.floating_position = drag.original_floating_position;
                window.floating_restore_size = drag.original_floating_restore_size;
                self.setWindowPositionImmediate(window, drag.initial_position);
            };
            self.relayout();
            return true;
        }
    }
    const resize = self.interactive_resize orelse return false;
    self.interactive_resize = null;
    if (!commit) switch (resize) {
        .floating => |value| if (self.windows.get(value.window)) |window| {
            if (self.isFloating(window)) {
                const position: Scene.Position = .{
                    .x = value.initial_rect.x,
                    .y = value.initial_rect.y,
                };
                window.floating_position = position;
                window.floating_restore_size = value.initial_rect.size;
                self.setWindowPositionImmediate(window, position);
            }
        },
        .tiled => |value| if (self.tiledResizeLayout(value)) |layout| {
            _ = layout.cancelResize(value.resize);
        },
    };
    self.relayout();
    return true;
}

fn cancelInteractiveResize(self: *Self) void {
    const resize = self.interactive_resize orelse return;
    self.interactive_resize = null;
    switch (resize) {
        .floating => {},
        .tiled => |value| if (self.tiledResizeLayout(value)) |layout| {
            _ = layout.cancelResize(value.resize);
        },
    }
}

fn tiledResizeLayout(self: *Self, resize: TiledResize) ?*layout_mod.Layout {
    const window = self.windows.get(resize.window) orelse return null;
    if (window.workspace >= self.workspaces.items.len) return null;
    const entry = &self.workspaces.items[window.workspace];
    if (!std.meta.eql(entry.output, resize.output) or
        entry.number != resize.workspace_number) return null;
    return &entry.workspace.layout;
}

pub fn beginToplevelDrag(
    self: *Self,
    xdg_id: XdgShell.WindowId,
    pointer_x: f64,
    pointer_y: f64,
    x_offset: i32,
    y_offset: i32,
    use_offset_hint: bool,
) bool {
    const id = self.findXdg(xdg_id) orelse return false;
    return self.beginWindowMove(
        id,
        pointer_x,
        pointer_y,
        x_offset,
        y_offset,
        use_offset_hint,
        false,
        true,
    );
}

fn beginWindowMove(
    self: *Self,
    id: WindowId,
    pointer_x: f64,
    pointer_y: f64,
    x_offset: i32,
    y_offset: i32,
    use_offset_hint: bool,
    modifier: bool,
    allow_tiled: bool,
) bool {
    if (self.pointerInteractionActive() or self.layer_focus == .exclusive) return false;
    const window = self.windows.get(id) orelse return false;
    if (!window.mapped or window.minimized or window.fullscreen_output != null) return false;
    if (!allow_tiled and !self.isFloating(window)) return false;
    const current = self.scene.windowPosition(window.scene_id) orelse return false;
    const grab_x = if (use_offset_hint)
        @as(f64, @floatFromInt(x_offset))
    else
        pointer_x - @as(f64, @floatFromInt(current.x));
    const grab_y = if (use_offset_hint)
        @as(f64, @floatFromInt(y_offset))
    else
        pointer_y - @as(f64, @floatFromInt(current.y));
    const position = drag_geometry.toplevelPosition(pointer_x, pointer_y, grab_x, grab_y);
    const original_floating_override = window.floating_override;
    const original_floating_position = window.floating_position;
    const original_floating_restore_size = window.floating_restore_size;
    if (!self.isFloating(window)) {
        const dimensions = self.currentDimensions(window);
        window.floating_restore_size = types.Size.init(
            @intCast(@max(1, dimensions.width)),
            @intCast(@max(1, dimensions.height)),
        );
    }
    window.floating_override = true;
    window.floating_position = position;
    const workspace = &self.workspaces.items[window.workspace];
    _ = workspace.workspace.focus(neutral(id));
    _ = workspace.workspace.raise(neutral(id));
    self.default_output = workspace.output;
    self.toplevel_drag = .{
        .window = id,
        .grab_x = grab_x,
        .grab_y = grab_y,
        .modifier = modifier,
        .initial_position = current,
        .original_floating_override = original_floating_override,
        .original_floating_position = original_floating_position,
        .original_floating_restore_size = original_floating_restore_size,
    };
    self.relayout();
    self.setWindowPositionImmediate(window, position);
    self.scene.placeTop(window.scene_id);
    return true;
}

pub fn updateToplevelDrag(self: *Self, pointer_x: f64, pointer_y: f64) void {
    const drag = self.toplevel_drag orelse return;
    const window = self.windows.get(drag.window) orelse {
        self.toplevel_drag = null;
        return;
    };
    const position = drag_geometry.toplevelPosition(pointer_x, pointer_y, drag.grab_x, drag.grab_y);
    window.floating_position = position;
    if (window.placement) |*placement| {
        placement.rect.x = position.x;
        placement.rect.y = position.y;
    }
    self.setWindowPositionImmediate(window, position);
    self.scene.placeTop(window.scene_id);
}

pub fn endToplevelDrag(self: *Self) void {
    const drag = self.toplevel_drag orelse return;
    if (drag.modifier) return;
    self.toplevel_drag = null;
    self.relayout();
}

fn pointerInteractionActive(self: *const Self) bool {
    return self.tiling_drag != null or self.toplevel_drag != null or
        self.interactive_resize != null;
}

fn updateFloatingResize(
    self: *Self,
    resize: FloatingResize,
    pointer_x: f64,
    pointer_y: f64,
) bool {
    const window = self.windows.get(resize.window) orelse {
        self.interactive_resize = null;
        return false;
    };
    if (!window.mapped or window.minimized or window.fullscreen_output != null or
        !self.isFloating(window))
    {
        self.interactive_resize = null;
        return false;
    }
    const rect = floating_resize.resizedRect(
        resize.initial_rect,
        resize.initial_pointer_x,
        resize.initial_pointer_y,
        resize.edges,
        resize.constraints,
        pointer_x,
        pointer_y,
    );
    if (window.placement) |placement| {
        if (std.meta.eql(placement.rect, rect)) return false;
    }
    window.floating_position = .{ .x = rect.x, .y = rect.y };
    window.floating_restore_size = rect.size;
    if (window.placement) |*placement| placement.rect = rect;
    self.setWindowPositionImmediate(window, .{ .x = rect.x, .y = rect.y });
    self.scene.placeTop(window.scene_id);
    self.relayout();
    return true;
}

fn setWindowPositionImmediate(
    self: *Self,
    window: *const Window,
    position: Scene.Position,
) void {
    switch (window.backend) {
        .xdg => |id| self.xdg_shell.setWindowPosition(id, position),
        .xwayland => |id| {
            self.scene.setPosition(window.scene_id, position);
            _ = self.xwayland.move(
                self.xwayland.context,
                id,
                clampI16(position.x),
                clampI16(position.y),
            );
        },
    }
}

fn windowSizeConstraints(self: *Self, window: *const Window) types.SizeConstraints {
    return switch (window.backend) {
        .xdg => |id| constraints: {
            const info = self.xdg_shell.windowInfo(id) orelse break :constraints .{};
            const min_width: u32 = @intCast(@max(1, info.min_size.width));
            const min_height: u32 = @intCast(@max(1, info.min_size.height));
            break :constraints .{
                .min_width = min_width,
                .min_height = min_height,
                .max_width = if (info.max_size.width > 0)
                    @intCast(@max(@as(i32, @intCast(min_width)), info.max_size.width))
                else
                    null,
                .max_height = if (info.max_size.height > 0)
                    @intCast(@max(@as(i32, @intCast(min_height)), info.max_size.height))
                else
                    null,
            };
        },
        .xwayland => |id| constraints: {
            const info = self.xwayland.window_info(self.xwayland.context, id) orelse
                break :constraints .{};
            const min_width: u32 = @intCast(@min(
                @max(1, info.min_size.width),
                std.math.maxInt(u16),
            ));
            const min_height: u32 = @intCast(@min(
                @max(1, info.min_size.height),
                std.math.maxInt(u16),
            ));
            break :constraints .{
                .min_width = min_width,
                .min_height = min_height,
                .max_width = if (info.max_size.width > 0)
                    @intCast(@min(
                        @max(@as(i32, @intCast(min_width)), info.max_size.width),
                        std.math.maxInt(u16),
                    ))
                else
                    null,
                .max_height = if (info.max_size.height > 0)
                    @intCast(@min(
                        @max(@as(i32, @intCast(min_height)), info.max_size.height),
                        std.math.maxInt(u16),
                    ))
                else
                    null,
            };
        },
    };
}

fn isDraggableTiledWindow(self: *Self, window: *const Window) bool {
    return window.mapped and !window.minimized and window.fullscreen_output == null and
        !self.isFloating(window) and self.transientParent(window) == null and
        window.placement != null and window.placement.?.visible;
}

fn currentDimensions(self: *Self, window: *const Window) XdgShell.Dimensions {
    return switch (window.backend) {
        .xdg => |id| if (self.xdg_shell.windowInfo(id)) |info| info.dimensions orelse .{ .width = 640, .height = 480 } else .{ .width = 640, .height = 480 },
        .xwayland => |id| if (self.xwayland.window_info(self.xwayland.context, id)) |info| .{ .width = info.geometry.width, .height = info.geometry.height } else .{ .width = 640, .height = 480 },
    };
}

fn needsXdgConfigure(
    current_dimensions: ?XdgShell.Dimensions,
    current_configuration: XdgShell.ToplevelConfigure,
    decoration_configure_requested: bool,
    dimensions: XdgShell.Dimensions,
    configuration: XdgShell.ToplevelConfigure,
) bool {
    return decoration_configure_requested or current_dimensions == null or
        !std.meta.eql(current_dimensions.?, dimensions) or
        !std.meta.eql(current_configuration, configuration);
}

fn requestedXdgDimensions(
    current: ?XdgShell.Dimensions,
    placement: XdgShell.Dimensions,
    floating: bool,
    fullscreen: bool,
) XdgShell.Dimensions {
    if (floating and !fullscreen and current == null) return .{ .width = 0, .height = 0 };
    return placement;
}

pub fn execute(self: *Self, command: Command) void {
    switch (command) {
        .focus_next => self.focusNext(),
        .focus_previous => self.focusPrevious(),
        .focus_direction => |direction| self.focusDirection(direction),
        .move_focused_next => self.moveFocusedNext(),
        .move_focused_previous => self.moveFocusedPrevious(),
        .move_focused_direction => |direction| self.moveFocusedDirection(direction),
        .close => |target| switch (target) {
            .focused => self.closeFocused(),
        },
        .toggle_fullscreen => |target| switch (target) {
            .focused => self.toggleFocusedFullscreen(),
        },
        .toggle_floating => |target| switch (target) {
            .focused => self.toggleFocusedFloating(),
        },
        .layout_tiled => self.switchLayout(.tiled),
        .switch_workspace => |number| self.switchWorkspace(number),
        .move_to_workspace => |number| self.moveFocusedToWorkspace(number),
    }
}

pub fn focusNext(self: *Self) void {
    self.focusRelative(false);
}
pub fn focusPrevious(self: *Self) void {
    self.focusRelative(true);
}
pub fn focusDirection(self: *Self, direction: Direction) void {
    const index = self.workspaceFor(self.default_output) orelse return;
    const workspace = &self.workspaces.items[index].workspace;
    const candidate = self.directionalNeighbor(workspace, direction, true, true) orelse return;
    const changed = workspace.focus(candidate);
    std.debug.assert(changed);
    const window = self.windows.get(internal(candidate)) orelse unreachable;
    if (self.isFloating(window)) _ = workspace.raise(candidate);
    self.relayout();
}
pub fn moveFocusedNext(self: *Self) void {
    self.moveFocused(false);
}
pub fn moveFocusedPrevious(self: *Self) void {
    self.moveFocused(true);
}
pub fn moveFocusedDirection(self: *Self, direction: Direction) void {
    const index = self.workspaceFor(self.default_output) orelse return;
    const workspace = &self.workspaces.items[index].workspace;
    const focused = workspace.focused orelse return;
    const focused_window = self.windows.get(internal(focused)) orelse return;
    if (self.isFloating(focused_window)) return;
    const candidate = self.directionalNeighbor(workspace, direction, false, false) orelse return;
    const changed = workspace.swapWindows(focused, candidate);
    std.debug.assert(changed);
    self.relayout();
}
pub fn closeFocused(self: *Self) void {
    const window = self.focusedWindow() orelse return;
    if (!window.mapped or window.minimized) return;
    switch (window.backend) {
        .xdg => |id| self.xdg_shell.closeWindow(id),
        .xwayland => |id| self.xwayland.close(self.xwayland.context, id),
    }
}
pub fn toggleFocusedFullscreen(self: *Self) void {
    const window = self.focusedWindow() orelse return;
    if (!window.mapped or window.minimized) return;
    self.setFullscreen(window, if (window.fullscreen_output == null)
        self.workspaces.items[window.workspace].output
    else
        null);
    self.relayout();
}
pub fn toggleFocusedFloating(self: *Self) void {
    const window = self.focusedWindow() orelse return;
    if (!window.mapped or window.minimized) return;
    window.floating_override = !self.isFloating(window);
    if (!self.isFloating(window)) {
        window.floating_restore_size = null;
        window.floating_position = null;
    }
    self.relayout();
}
pub fn switchLayout(self: *Self, kind: layout_mod.Kind) void {
    const index = self.workspaceFor(self.default_output) orelse return;
    const entry = &self.workspaces.items[index];
    var usable: ?types.Rect = null;
    if (self.layer_shell.usableAreaFor(entry.output)) |area| {
        if (area.width > 0 and area.height > 0) usable = .{
            .x = area.x,
            .y = area.y,
            .size = types.Size.init(@intCast(area.width), @intCast(area.height)),
        };
    }
    entry.workspace.setLayout(self.allocator, kind, usable) catch return;
    entry.workspace.layout.setGaps(self.inner_gap, self.outer_gap);
    self.relayout();
}

pub fn switchWorkspace(self: *Self, number: u8) void {
    _ = self.activateWorkspace(self.default_output, number, true);
}

pub fn activateWorkspaceFromProtocol(self: *Self, output: OutputLayout.Id, number: u8) bool {
    return self.activateWorkspace(output, number, false);
}

fn activateWorkspace(self: *Self, output: OutputLayout.Id, number: u8, notify_protocol: bool) bool {
    const current = self.workspaceFor(output) orelse return false;
    const target = self.workspaceNumber(output, number) orelse return false;
    const output_changed = !std.meta.eql(self.default_output, output);
    self.default_output = output;
    if (current == target) {
        if (output_changed) self.relayout();
        return true;
    }
    if (self.geometry_listener) |listener| {
        listener.workspace_switching(listener.context, output);
        queueWorkspaceTransition(self.workspaces.items, output, target);
    }
    self.workspaces.items[current].active = false;
    self.workspaces.items[target].active = true;
    if (notify_protocol) self.workspace_protocol.setActive(output, number);
    self.relayout();
    return true;
}

fn queueWorkspaceTransition(
    workspaces: []OutputWorkspace,
    output: OutputLayout.Id,
    target: usize,
) void {
    const target_inflight = workspaces[target].transition_inflight;
    for (workspaces) |*workspace| {
        if (std.meta.eql(workspace.output, output)) workspace.transition_pending = false;
    }
    workspaces[target].transition_pending = !target_inflight;
}

fn beginPendingWorkspaceTransitions(workspaces: []OutputWorkspace) void {
    for (workspaces) |*workspace| {
        if (!workspace.active or !workspace.transition_pending) continue;
        workspace.transition_pending = false;
        workspace.transition_inflight = true;
    }
}

fn publishWorkspaceTransition(workspace: *OutputWorkspace) bool {
    const animate = workspace.active and workspace.transition_inflight;
    workspace.transition_inflight = false;
    return animate;
}

pub fn moveFocusedToWorkspace(self: *Self, number: u8) void {
    const source = self.workspaceFor(self.default_output) orelse return;
    const target = self.workspaceNumber(self.default_output, number) orelse return;
    if (source == target) return;
    const id = self.workspaces.items[source].workspace.focused orelse return;
    const moved = self.moveWindowToWorkspace(internal(id), target) catch return;
    std.debug.assert(moved);
    self.relayout();
}
pub fn addTagToFocused(self: *Self, tag: types.TagId) !void {
    if (self.focusedWindow()) |window| _ = try window.tags.add(self.allocator, tag);
}
pub fn removeTagFromFocused(self: *Self, tag: types.TagId) void {
    if (self.focusedWindow()) |window| _ = window.tags.remove(tag);
}

fn focusedWindow(self: *Self) ?*Window {
    const index = self.workspaceFor(self.default_output) orelse return null;
    return self.windows.get(internal(self.workspaces.items[index].workspace.focused orelse return null));
}
fn focusRelative(self: *Self, reverse: bool) void {
    const index = self.workspaceFor(self.default_output) orelse return;
    const ws = &self.workspaces.items[index].workspace;
    const focused = ws.focused orelse return;
    const window = self.windows.get(internal(focused)) orelse return;
    if (self.isFloating(window)) {
        // Unlike Sway, Keywork has no explicit focus-layer toggle yet. Keep
        // next/previous able to leave the floating layer.
        self.cycleFocus(ws, focused, reverse);
        return;
    }
    const direction = ws.layout.relativeDirection(focused, reverse) orelse return;
    self.focusDirection(direction);
}

fn cycleFocus(
    self: *Self,
    workspace: *workspace_mod.Workspace,
    focused: types.WindowId,
    reverse: bool,
) void {
    var candidate = focused;
    for (0..workspace.members.items.len) |_| {
        candidate = workspace.nextWindow(candidate, reverse) orelse return;
        const window = self.windows.get(internal(candidate)) orelse continue;
        if (window.minimized or !self.transientIsVisible(window)) continue;
        const changed = workspace.focus(candidate);
        std.debug.assert(changed);
        self.relayout();
        return;
    }
}

fn moveFocused(self: *Self, reverse: bool) void {
    const index = self.workspaceFor(self.default_output) orelse return;
    const ws = &self.workspaces.items[index].workspace;
    const focused = ws.focused orelse return;
    const window = self.windows.get(internal(focused)) orelse return;
    if (self.isFloating(window)) return;
    const direction = ws.layout.relativeDirection(focused, reverse) orelse return;
    self.moveFocusedDirection(direction);
}

fn directionalNeighbor(
    self: *Self,
    workspace: *const workspace_mod.Workspace,
    direction: Direction,
    wrap: bool,
    allow_cross_layer: bool,
) ?types.WindowId {
    const focused = workspace.focused orelse return null;
    const focused_window = self.windows.get(internal(focused)) orelse return null;
    if (self.isFloating(focused_window)) {
        if (self.geometricDirectionalNeighbor(workspace, focused, direction, true, false)) |candidate| {
            return candidate;
        }
        // Try the other layer before wrapping so keyboard focus cannot become
        // trapped in either layer without a mode-toggle command.
        if (allow_cross_layer) {
            if (self.geometricDirectionalNeighbor(workspace, focused, direction, false, false)) |candidate| {
                return candidate;
            }
            if (self.mostRecentLayerWindow(workspace, false)) |candidate| return candidate;
        }
        return if (wrap)
            self.geometricDirectionalNeighbor(workspace, focused, direction, true, true)
        else
            null;
    }

    var eligible: std.ArrayList(types.WindowId) = .empty;
    defer eligible.deinit(self.allocator);
    for (workspace.members.items) |id| {
        const window = self.windows.get(internal(id)) orelse continue;
        if (window.minimized or self.isFloating(window) or !self.transientIsVisible(window)) continue;
        eligible.append(self.allocator, id) catch return null;
    }
    if (workspace.layout.directionalWindow(
        focused,
        direction,
        eligible.items,
        workspace.focus_history.items,
        false,
    )) |candidate| return candidate;
    // See the floating branch above: crossing layers takes precedence over
    // wrapping within the current one.
    if (allow_cross_layer) {
        if (self.geometricDirectionalNeighbor(workspace, focused, direction, true, false)) |candidate| {
            return candidate;
        }
        if (self.mostRecentLayerWindow(workspace, true)) |candidate| return candidate;
    }
    return if (wrap)
        workspace.layout.directionalWindow(
            focused,
            direction,
            eligible.items,
            workspace.focus_history.items,
            true,
        )
    else
        null;
}

fn mostRecentLayerWindow(
    self: *Self,
    workspace: *const workspace_mod.Workspace,
    floating: bool,
) ?types.WindowId {
    var index = workspace.focus_history.items.len;
    while (index > 0) {
        index -= 1;
        const id = workspace.focus_history.items[index];
        const window = self.windows.get(internal(id)) orelse continue;
        if (window.minimized or self.isFloating(window) != floating or
            !self.transientIsVisible(window) or window.placement == null) continue;
        return id;
    }
    return null;
}

fn geometricDirectionalNeighbor(
    self: *Self,
    workspace: *const workspace_mod.Workspace,
    focused: types.WindowId,
    direction: Direction,
    floating_candidates: bool,
    wrap: bool,
) ?types.WindowId {
    const focused_window = self.windows.get(internal(focused)) orelse return null;
    const origin = if (focused_window.placement) |plan| plan.rect else return null;
    var best_id: ?types.WindowId = null;
    var best_delta: ?i64 = null;
    var wrap_id: ?types.WindowId = null;
    var wrap_delta: ?i64 = null;
    for (workspace.members.items) |id| {
        if (id.eql(focused)) continue;
        const window = self.windows.get(internal(id)) orelse continue;
        if (window.minimized or self.isFloating(window) != floating_candidates or
            !self.transientIsVisible(window)) continue;
        const candidate = if (window.placement) |plan| plan.rect else continue;
        const delta = directionalDelta(origin, candidate, direction);
        if (delta > 0 and (best_delta == null or delta < best_delta.?)) {
            best_id = id;
            best_delta = delta;
        } else if (wrap and delta < 0 and (wrap_delta == null or delta < wrap_delta.?)) {
            wrap_id = id;
            wrap_delta = delta;
        }
    }
    return best_id orelse wrap_id;
}

fn relayout(self: *Self) void {
    self.syncTransientWorkspaces() catch return;
    if (!self.transaction.change()) return;
    var planned: std.ArrayList(types.LayoutPlan) = .empty;
    defer planned.deinit(self.allocator);
    for (self.workspaces.items) |*entry| {
        const area = self.layer_shell.usableAreaFor(entry.output) orelse continue;
        if (area.width <= 0 or area.height <= 0) continue;
        var inputs: std.ArrayList(types.WindowInput) = .empty;
        defer inputs.deinit(self.allocator);
        for (entry.workspace.members.items) |member| {
            const window = self.windows.get(internal(member)) orelse continue;
            if (window.minimized or window.fullscreen_output != null or
                self.isFloating(window)) continue;
            const current = self.currentDimensions(window);
            inputs.append(self.allocator, .{
                .id = member,
                .constraints = self.windowSizeConstraints(window),
                .current = types.Size.init(
                    @intCast(@max(1, current.width)),
                    @intCast(@max(1, current.height)),
                ),
            }) catch return;
        }
        var plans = entry.workspace.layout.arrange(self.allocator, inputs.items, .{ .x = area.x, .y = area.y, .size = types.Size.init(@intCast(area.width), @intCast(area.height)) }, entry.workspace.focused) catch return;
        defer plans.deinit(self.allocator);
        planned.appendSlice(self.allocator, plans.items) catch return;
    }

    var pending: u32 = 0;
    var windows = self.windows.iterator();
    while (windows.next()) |entry| {
        entry.value.placement = null;
        entry.value.serial = null;
    }
    for (planned.items) |plan| {
        const window = self.windows.get(internal(plan.id)) orelse continue;
        window.placement = plan;
    }
    for (self.workspaces.items) |*entry| {
        for (entry.workspace.members.items) |member| {
            const window = self.windows.get(internal(member)) orelse continue;
            const fullscreen_output_id = window.fullscreen_output orelse continue;
            const output = self.outputs.get(entry.output) orelse continue;
            const fullscreen_output = self.outputs.get(fullscreen_output_id) orelse output;
            const position = fullscreen_output.logicalPosition();
            const size = fullscreen_output.logicalSize();
            window.placement = .{
                .id = member,
                .rect = .{
                    .x = position.x,
                    .y = position.y,
                    .size = types.Size.init(size.width, size.height),
                },
                .visible = true,
            };
        }
    }
    for (self.workspaces.items) |*entry| {
        const area = self.layer_shell.usableAreaFor(entry.output) orelse continue;
        if (area.width <= 0 or area.height <= 0) continue;
        const bounds: types.Rect = .{
            .x = area.x,
            .y = area.y,
            .size = types.Size.init(@intCast(area.width), @intCast(area.height)),
        };
        for (entry.workspace.members.items) |member| {
            const window = self.windows.get(internal(member)) orelse continue;
            if (window.placement != null or window.fullscreen_output != null or
                !self.isFloating(window) or self.transientParent(window) != null) continue;
            const current = self.currentDimensions(window);
            const current_size = types.Size.init(
                @intCast(@max(1, current.width)),
                @intCast(@max(1, current.height)),
            );
            const restore_size = window.floating_restore_size;
            const size = restore_size orelse
                if (window.floating_override orelse false)
                    floating_placement.manualSize(bounds.size, current.width, current.height)
                else
                    current_size;
            if (restore_size) |expected| {
                if (std.meta.eql(current_size, expected)) window.floating_restore_size = null;
            }
            window.placement = .{
                .id = member,
                .rect = floating_placement.rect(bounds, size, window.floating_position),
                .visible = true,
            };
        }
    }
    var remaining = self.windows.len();
    while (remaining > 0) : (remaining -= 1) {
        var changed = false;
        for (self.workspaces.items) |*entry| {
            for (entry.workspace.members.items) |member| {
                const window = self.windows.get(internal(member)) orelse continue;
                if (window.placement != null or window.fullscreen_output != null) continue;
                const parent = self.windows.get(self.transientParent(window) orelse continue) orelse continue;
                const parent_placement = parent.placement orelse continue;
                const current = self.currentDimensions(window);
                const current_size = types.Size.init(
                    @intCast(@max(1, current.width)),
                    @intCast(@max(1, current.height)),
                );
                const restore_size = window.floating_restore_size;
                const size = restore_size orelse current_size;
                if (restore_size) |expected| {
                    if (std.meta.eql(current_size, expected)) window.floating_restore_size = null;
                }
                window.placement = .{
                    .id = member,
                    .rect = floating_placement.rect(
                        parent_placement.rect,
                        size,
                        window.floating_position,
                    ),
                    .visible = parent_placement.visible,
                };
                changed = true;
            }
        }
        if (!changed) break;
    }
    for (self.workspaces.items) |*entry| {
        if (entry.active) self.normalizeFocus(entry);
        for (entry.workspace.members.items) |member| {
            const window = self.windows.get(internal(member)) orelse continue;
            const output = self.outputs.get(entry.output) orelse continue;
            const floating = self.isFloating(window);
            const plan = window.placement;
            const repaint_suspended = repaintSuspended(window.minimized, entry.active, plan);
            const current_dimensions = self.currentDimensions(window);
            const dimensions: XdgShell.Dimensions = if (plan) |placement| .{
                .width = @intCast(placement.rect.size.width),
                .height = @intCast(placement.rect.size.height),
            } else .{
                .width = @max(1, current_dimensions.width),
                .height = @max(1, current_dimensions.height),
            };
            if (!window.mapped) switch (window.backend) {
                .xdg => |id| self.xdg_shell.setWindowVisible(id, false),
                .xwayland => {},
            };
            window.transition_prepared = false;
            if (self.geometry_listener) |listener| if (plan) |placement| {
                if (window.published_rect) |old_rect| {
                    const entering_fullscreen = window.fullscreen_output != null and
                        !window.published_fullscreen and
                        std.meta.eql(window.fullscreen_output.?, entry.output);
                    const eligible = window.mapped and entry.active and placement.visible and
                        !window.minimized and
                        (window.fullscreen_output == null or entering_fullscreen) and
                        !floating and self.transientParent(window) == null and
                        self.interactive_resize == null and self.tiling_drag == null and
                        self.toplevel_drag == null and !std.meta.eql(old_rect, placement.rect);
                    if (eligible) {
                        listener.prepare(listener.context, .{
                            .scene_id = window.scene_id,
                            .surface_id = window.surface_id,
                            .output = entry.output,
                            .old_rect = old_rect,
                            .target_rect = placement.rect,
                        });
                        window.transition_prepared = true;
                    }
                }
            };
            const tiled: XdgShell.TiledEdges = if (plan) |placement| .{
                .top = placement.tiled_edges.top,
                .right = placement.tiled_edges.right,
                .bottom = placement.tiled_edges.bottom,
                .left = placement.tiled_edges.left,
            } else .{};
            const serial = switch (window.backend) {
                .xwayland => |id| serial: {
                    const current = self.currentDimensions(window);
                    if (!std.meta.eql(current, dimensions)) {
                        _ = self.xwayland.resize(
                            self.xwayland.context,
                            id,
                            @intCast(@min(dimensions.width, std.math.maxInt(u16))),
                            @intCast(@min(dimensions.height, std.math.maxInt(u16))),
                        );
                    }
                    break :serial null;
                },
                .xdg => |id| configure: {
                    const info = self.xdg_shell.windowInfo(id) orelse break :configure null;
                    const bounds_output = if (window.fullscreen_output) |fullscreen_output|
                        self.outputs.get(fullscreen_output) orelse output
                    else
                        output;
                    const configure_dimensions = requestedXdgDimensions(
                        info.dimensions,
                        dimensions,
                        floating,
                        window.fullscreen_output != null,
                    );
                    const configuration: XdgShell.ToplevelConfigure = .{
                        .activated = !repaint_suspended and entry.workspace.focused != null and
                            member.eql(entry.workspace.focused.?),
                        .resizing = !repaint_suspended and
                            self.interactivelyResizing(internal(member)),
                        .maximized = window.maximized,
                        .fullscreen = window.fullscreen_output != null,
                        .tiled = tiled,
                        .decoration_mode = if (info.decoration_preference == .only_csd)
                            .client_side
                        else
                            .server_side,
                        .bounds = .{
                            .width = @intCast(bounds_output.logicalSize().width),
                            .height = @intCast(bounds_output.logicalSize().height),
                        },
                        .suspended = repaint_suspended,
                    };
                    if (!needsXdgConfigure(
                        info.dimensions,
                        info.configuration,
                        info.decoration_configure_requested,
                        configure_dimensions,
                        configuration,
                    )) break :configure null;
                    break :configure self.xdg_shell.configureWindowState(
                        id,
                        configure_dimensions,
                        configuration,
                    ) catch null;
                },
            };
            // Suspended windows do not gate publishing because clients may stop repainting them.
            window.serial = if (repaint_suspended) null else serial;
            if (window.serial != null) pending += 1;
        }
    }
    beginPendingWorkspaceTransitions(self.workspaces.items);
    self.transaction.begin(pending);
    if (pending == 0) {
        self.publish();
    } else {
        self.configure_timer.timerUpdate(100) catch self.handleOutOfMemory();
    }
}

fn interactivelyResizing(self: *const Self, id: WindowId) bool {
    const resize = self.interactive_resize orelse return false;
    const target = switch (resize) {
        .floating => |value| value.window,
        .tiled => |value| switch (value.resize) {
            .tiled => |tiled| internal(tiled.window),
        },
    };
    return std.meta.eql(target, id);
}

fn normalizeFocus(self: *Self, entry: *OutputWorkspace) void {
    const workspace = &entry.workspace;
    if (workspace.members.items.len == 0) {
        workspace.focused = null;
        return;
    }
    var index = workspace.focus_history.items.len;
    while (index > 0) {
        index -= 1;
        const candidate = workspace.focus_history.items[index];
        if (self.windows.get(internal(candidate))) |window| {
            if (!window.minimized and self.transientIsVisible(window)) {
                const changed = workspace.focus(candidate);
                std.debug.assert(changed);
                return;
            }
        }
    }
    workspace.focused = null;
}

fn publish(self: *Self) void {
    self.clearFocusedUrgency();
    var it = self.windows.iterator();
    while (it.next()) |entry| {
        const window = entry.value;
        const plan = window.placement;
        const visible = displayed(
            window.mapped,
            window.minimized,
            self.workspaces.items[window.workspace].active,
            plan,
        ) and firstPublicationReady(
            window.published_once,
            self.isFloating(window),
            self.transaction.hasPendingChange(),
        );
        if (plan) |placement| switch (window.backend) {
            .xdg => |id| self.xdg_shell.setWindowPosition(id, .{ .x = placement.rect.x, .y = placement.rect.y }),
            .xwayland => |id| _ = self.xwayland.move(self.xwayland.context, id, clampI16(placement.rect.x), clampI16(placement.rect.y)),
        };
        if (plan) |placement| window.published_rect = placement.rect else window.published_rect = null;
        window.published_fullscreen = window.fullscreen_output != null;
        const focused = self.windowFocused(entry.id, window);
        self.scene.setFocused(window.scene_id, focused);
        self.scene.setFullscreen(window.scene_id, window.fullscreen_output != null);
        self.scene.setBorders(window.scene_id, self.borderForWindow(window, focused));
        switch (window.backend) {
            .xdg => |id| {
                self.xdg_shell.setWindowFocused(id, focused);
                self.xdg_shell.setWindowFullscreen(id, window.fullscreen_output != null);
            },
            .xwayland => |id| {
                self.xwayland.set_fullscreen(self.xwayland.context, id, window.fullscreen_output != null);
                self.xwayland.set_maximized(self.xwayland.context, id, window.maximized);
                self.xwayland.set_minimized(self.xwayland.context, id, window.minimized);
            },
        }
        self.scene.setEffects(window.scene_id, self.effectsForWindow(window, focused));
        const clip_box: ?Scene.ClipBox = if (plan) |placement|
            if (placement.clip) |clip| .{
                .x = clip.x -| placement.rect.x,
                .y = clip.y -| placement.rect.y,
                .width = clip.size.width,
                .height = clip.size.height,
            } else null
        else
            null;
        const shadow_clip_box: ?Scene.ClipBox = if (plan) |placement|
            if (placement.shadow_clip) |clip| .{
                .x = clip.x -| placement.rect.x,
                .y = clip.y -| placement.rect.y,
                .width = clip.size.width,
                .height = clip.size.height,
            } else null
        else
            null;
        self.scene.setShadowClipBox(window.scene_id, shadow_clip_box);
        switch (window.backend) {
            .xdg => |id| {
                self.xdg_shell.setWindowClipBox(id, clip_box);
                self.xdg_shell.setWindowContentClipBox(id, null);
                self.xdg_shell.setWindowVisible(id, visible);
            },
            .xwayland => |id| self.xwayland.refresh_scene(self.xwayland.context, id),
        }
        if (window.backend == .xwayland) {
            self.scene.setClipBox(window.scene_id, clip_box);
            self.scene.setContentClipBox(window.scene_id, null);
        }
        // Xwayland refreshes its Scene node above, so snapshots observe the
        // published position and current decoration/effect state.
        if (window.transition_prepared) {
            if (self.geometry_listener) |listener| listener.published(listener.context, window.scene_id);
            window.transition_prepared = false;
        } else if (!window.published_once and visible and
            window.fullscreen_output == null and self.transientParent(window) == null)
        {
            if (self.geometry_listener) |listener| if (plan) |placement| listener.appeared(
                listener.context,
                .{
                    .scene_id = window.scene_id,
                    .surface_id = window.surface_id,
                    .output = self.workspaces.items[window.workspace].output,
                    .target_rect = placement.rect,
                    .coordinated = !self.isFloating(window),
                },
            );
        }
        window.published_once = window.published_once or visible;
    }
    self.publishStacking();
    self.xwayland.stacking_changed(self.xwayland.context);
    for (self.workspaces.items) |*workspace| {
        if (!publishWorkspaceTransition(workspace)) continue;
        if (self.geometry_listener) |listener| {
            listener.workspace_published(listener.context, workspace.output);
        }
    }
    if (self.session_listener) |listener| {
        var windows = self.windows.iterator();
        while (windows.next()) |entry| switch (entry.value.backend) {
            .xdg => |id| listener.changed(listener.context, id),
            .xwayland => {},
        };
    }
    if (self.transaction.consumeDirty()) self.relayout();
}

fn publishStacking(self: *Self) void {
    const batched = update: {
        self.scene.beginStackUpdate() catch break :update false;
        break :update true;
    };
    defer if (batched) self.scene.endStackUpdate();

    for (self.workspaces.items) |workspace| {
        if (!workspace.active) continue;
        inline for (.{
            StackTier.tiled,
            StackTier.tiled_focused,
            StackTier.floating,
            StackTier.floating_focused,
            StackTier.fullscreen,
        }) |tier| self.placeWorkspaceStackTier(&workspace, tier);
    }
    var depth: usize = 1;
    while (depth <= self.windows.len()) : (depth += 1) {
        for (self.workspaces.items) |workspace| {
            if (!workspace.active) continue;
            var index = workspace.workspace.members.items.len;
            while (index > 0) {
                index -= 1;
                const window = self.windows.get(internal(workspace.workspace.members.items[index])) orelse continue;
                if (window.placement == null or window.fullscreen_output != null or
                    self.transientDepth(window) != depth) continue;
                const parent = self.windows.get(self.transientParent(window) orelse continue) orelse continue;
                if (parent.placement != null and
                    !self.scene.windowAbove(window.scene_id, parent.scene_id))
                {
                    self.scene.placeAbove(window.scene_id, parent.scene_id);
                }
            }
        }
    }
}

const StackTier = enum {
    tiled,
    tiled_focused,
    floating,
    floating_focused,
    fullscreen,
};

fn placeWorkspaceStackTier(
    self: *Self,
    workspace: *const OutputWorkspace,
    tier: StackTier,
) void {
    for (workspace.workspace.members.items) |member| {
        const id = internal(member);
        const window = self.windows.get(id) orelse continue;
        if (window.placement == null) continue;
        const window_tier = stackTier(
            self.isFloating(window),
            self.windowFocused(id, window),
            window.fullscreen_output != null,
        );
        if (window_tier == tier) self.scene.placeTop(window.scene_id);
    }
}

fn stackTier(floating: bool, focused: bool, fullscreen: bool) StackTier {
    if (fullscreen) return .fullscreen;
    if (floating) return if (focused) .floating_focused else .floating;
    return if (focused) .tiled_focused else .tiled;
}

test "window effects follow elevation and suppress fullscreen effects" {
    const effects: WindowEffects = .{
        .tiled = .{ .corner_radius = 1 },
        .tiled_focused = .{ .corner_radius = 2 },
        .floating = .{ .corner_radius = 3 },
        .floating_focused = .{ .corner_radius = 4 },
    };
    try std.testing.expectEqual(@as(u32, 1), effectsForWindowState(effects, false, false, false).corner_radius);
    try std.testing.expectEqual(@as(u32, 2), effectsForWindowState(effects, false, true, false).corner_radius);
    try std.testing.expectEqual(@as(u32, 3), effectsForWindowState(effects, true, false, false).corner_radius);
    try std.testing.expectEqual(@as(u32, 4), effectsForWindowState(effects, true, true, false).corner_radius);
    try std.testing.expectEqual(Scene.Effects{}, effectsForWindowState(effects, true, true, true));
}

test "stack tiers raise focus without crossing floating or fullscreen tiers" {
    try std.testing.expectEqual(StackTier.tiled, stackTier(false, false, false));
    try std.testing.expectEqual(StackTier.tiled_focused, stackTier(false, true, false));
    try std.testing.expectEqual(StackTier.floating, stackTier(true, false, false));
    try std.testing.expectEqual(StackTier.floating_focused, stackTier(true, true, false));
    try std.testing.expectEqual(StackTier.fullscreen, stackTier(false, true, true));
}

fn clampI16(value: i32) i16 {
    return @intCast(std.math.clamp(value, std.math.minInt(i16), std.math.maxInt(i16)));
}

fn directionalDelta(origin: types.Rect, candidate: types.Rect, direction: Direction) i64 {
    const origin_x = doubledCenter(origin.x, origin.size.width);
    const origin_y = doubledCenter(origin.y, origin.size.height);
    const candidate_x = doubledCenter(candidate.x, candidate.size.width);
    const candidate_y = doubledCenter(candidate.y, candidate.size.height);
    return switch (direction) {
        .left => origin_x - candidate_x,
        .right => candidate_x - origin_x,
        .up => origin_y - candidate_y,
        .down => candidate_y - origin_y,
    };
}

fn doubledCenter(start: i32, length: u32) i64 {
    return 2 * @as(i64, start) + length;
}

fn repaintSuspended(minimized: bool, active: bool, plan: ?types.LayoutPlan) bool {
    return minimized or !active or plan == null or !plan.?.visible;
}

fn displayed(mapped: bool, minimized: bool, active: bool, plan: ?types.LayoutPlan) bool {
    return mapped and !repaintSuspended(minimized, active, plan);
}

/// A floating window's first commit can choose a natural size while its
/// fallback placement is still behind the configure barrier. Keep it hidden
/// until the coalesced relayout publishes the matching placement.
fn firstPublicationReady(
    published_once: bool,
    floating: bool,
    relayout_pending: bool,
) bool {
    return published_once or !floating or !relayout_pending;
}

fn configureTimeout(self: *Self) c_int {
    if (!self.transaction.timeout()) return 0;
    self.publish();
    return 0;
}

fn handleOutOfMemory(self: *Self) void {
    // A timer allocation failure must not freeze every managed window.
    _ = self.transaction.timeout();
    self.publish();
}

fn windowReady(context: *anyopaque, id: XdgShell.WindowId) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    const restoring = self.pending_session_restores.contains(id);
    if (!restoring) if (self.session_listener) |listener| {
        if (listener.state_for_remap(listener.context, id)) |state| {
            self.pending_session_restores.put(self.allocator, id, state) catch return false;
        }
    };
    _ = self.addXdg(id) catch return false;
    if (restoring) {
        std.debug.assert(!self.pending_session_restores.contains(id));
        if (self.session_listener) |listener| listener.restored(listener.context, id);
    }
    self.xdg_shell.setWindowVisible(id, false);
    self.relayout();
    return true;
}
fn windowCommitted(context: *anyopaque, id: XdgShell.WindowId, serial: ?u32) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    const managed = self.findXdg(id) orelse return false;
    const window = self.windows.get(managed) orelse return false;
    window.mapped = true;
    const pending_activation = window.pending_activation;
    window.pending_activation = false;
    if (self.isFloating(window)) self.relayout();
    if (serial != null and window.serial == serial) {
        window.serial = null;
        const complete = self.transaction.configured();
        // A gated commit may arrive after the configure barrier timed out.
        if (complete or !self.transaction.isInflight()) self.publish();
    }
    if (pending_activation) _ = self.activateWindow(managed);
    return true;
}
fn windowUnmapping(context: *anyopaque, id: XdgShell.WindowId) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.prepareClosing(self.findXdg(id) orelse return);
}
fn windowUnmapped(context: *anyopaque, id: XdgShell.WindowId) void {
    removeXdg(@ptrCast(@alignCast(context)), id);
}
fn windowDestroyed(context: *anyopaque, id: XdgShell.WindowId) void {
    removeXdg(@ptrCast(@alignCast(context)), id);
}
fn windowMetadataChanged(context: *anyopaque, id: XdgShell.WindowId) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    const window = self.windows.get(self.findXdg(id) orelse return false) orelse return false;
    if (!window.mapped) {
        const info = self.xdg_shell.windowInfo(id) orelse return false;
        window.fixed_size_floating = fixedSizeWantsFloating(info.min_size, info.max_size);
    }
    self.relayout();
    return true;
}
fn windowRequest(context: *anyopaque, id: XdgShell.WindowId, request: XdgShell.WindowRequest) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const window = self.windows.get(self.findXdg(id) orelse return) orelse return;
    switch (request) {
        .activate => {
            if (self.layer_focus == .exclusive) return;
            window.minimized = false;
            _ = self.layer_shell.relinquishNonExclusiveFocus();
            _ = self.workspaces.items[window.workspace].workspace.focus(neutral(self.findXdg(id).?));
        },
        .unminimize => {
            window.minimized = false;
            _ = self.workspaces.items[window.workspace].workspace.focus(neutral(self.findXdg(id).?));
        },
        .minimize => window.minimized = true,
        .maximize => window.maximized = true,
        .unmaximize => window.maximized = false,
        .fullscreen => |fullscreen| self.setFullscreen(window, if (fullscreen) |resource|
            if (self.outputs.findResource(resource)) |entry| entry.id else self.workspaces.items[window.workspace].output
        else
            self.workspaces.items[window.workspace].output),
        .exit_fullscreen => self.setFullscreen(window, null),
        else => {},
    }
    self.relayout();
}
fn layerSupported(_: *anyopaque) bool {
    return true;
}
fn layerChanged(context: *anyopaque, _: LayerShell.Rect, focus: LayerShell.FocusClass) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.layer_focus = focus;
    self.relayout();
}

pub fn xwaylandWindowAssociated(self: *Self, id: Xwm.WindowId, scene_id: Scene.Id, surface_id: Surface.Id) error{OutOfMemory}!void {
    std.debug.assert(!self.known_xwayland.contains(id));
    try self.known_xwayland.put(self.allocator, id, .{
        .scene_id = scene_id,
        .surface_id = surface_id,
    });
    errdefer _ = self.known_xwayland.remove(id);
    const info = self.xwayland.window_info(self.xwayland.context, id) orelse return;
    if (info.mapped and try self.addXwayland(id) != null) self.relayout();
}

pub fn xwaylandWindowDissociated(self: *Self, id: Xwm.WindowId) void {
    if (self.findXwayland(id)) |managed| self.removeId(managed);
    _ = self.known_xwayland.remove(id);
}

pub fn xwaylandWindowClosing(self: *Self, id: Xwm.WindowId) void {
    self.prepareClosing(self.findXwayland(id) orelse return);
}

pub fn xwaylandWindowMapped(self: *Self, id: Xwm.WindowId, mapped: bool) void {
    if (!mapped) {
        if (self.findXwayland(id)) |managed| {
            self.prepareClosing(managed);
            self.removeId(managed);
        }
        return;
    }
    const managed = self.addXwayland(id) catch return orelse return;
    self.windows.get(managed).?.mapped = true;
    self.relayout();
}

pub fn xwaylandWindowConfigured(self: *Self, id: Xwm.WindowId, geometry: Xwm.Geometry, override_redirect: bool) void {
    if (override_redirect) {
        if (self.findXwayland(id)) |managed| self.removeId(managed);
        return;
    }
    const window = self.windows.get(self.findXwayland(id) orelse return) orelse return;
    const restore_size = window.floating_restore_size orelse return;
    if (window.fullscreen_output == null and
        restore_size.width == geometry.width and restore_size.height == geometry.height)
    {
        window.floating_restore_size = null;
    }
}

pub fn xwaylandWindowMetadataChanged(self: *Self, id: Xwm.WindowId) void {
    const info = self.xwayland.window_info(self.xwayland.context, id) orelse return;
    if (!info.participatesInWindowManagement()) {
        if (self.findXwayland(id)) |managed| self.removeId(managed);
        return;
    }
    if (self.findXwayland(id) == null) {
        if (info.mapped) self.xwaylandWindowMapped(id, true);
        return;
    }
    self.relayout();
}

pub fn xwaylandWindowFullscreenRequested(self: *Self, id: Xwm.WindowId, fullscreen: bool, output: ?OutputLayout.Id) void {
    const window = self.windows.get(self.findXwayland(id) orelse return) orelse return;
    self.setFullscreen(window, if (fullscreen) output orelse self.workspaces.items[window.workspace].output else null);
    self.relayout();
}

pub fn xwaylandWindowMaximizeRequested(self: *Self, id: Xwm.WindowId, maximized: bool) void {
    const window = self.windows.get(self.findXwayland(id) orelse return) orelse return;
    window.maximized = maximized;
    self.relayout();
}

pub fn xwaylandWindowMinimizeRequested(self: *Self, id: Xwm.WindowId, minimized: bool) void {
    const window = self.windows.get(self.findXwayland(id) orelse return) orelse return;
    window.minimized = minimized;
    self.relayout();
}

pub fn xwaylandWindowActivationRequested(self: *Self, id: Xwm.WindowId, _: *Seat) void {
    if (self.layer_focus == .exclusive) return;
    const managed = self.findXwayland(id) orelse return;
    const window = self.windows.get(managed).?;
    window.minimized = false;
    _ = self.layer_shell.relinquishNonExclusiveFocus();
    _ = self.workspaces.items[window.workspace].workspace.focus(neutral(managed));
    self.relayout();
}

pub fn xwaylandWindowDisplayed(self: *Self, id: Xwm.WindowId) bool {
    const window = self.windows.get(self.findXwayland(id) orelse return true) orelse return true;
    return displayed(window.mapped, window.minimized, self.workspaces.items[window.workspace].active, window.placement);
}

test "each output owns ten numbered workspaces" {
    var manager: Self = undefined;
    manager.allocator = std.testing.allocator;
    manager.workspaces = .empty;
    defer {
        for (manager.workspaces.items) |*entry| entry.workspace.deinit(std.testing.allocator);
        manager.workspaces.deinit(std.testing.allocator);
    }

    const first: OutputLayout.Id = .{ .index = 1, .generation = 1 };
    const second: OutputLayout.Id = .{ .index = 2, .generation = 1 };
    try manager.appendOutputWorkspaces(first);
    try manager.appendOutputWorkspaces(second);

    try std.testing.expectEqual(@as(usize, 20), manager.workspaces.items.len);
    try std.testing.expectEqual(@as(usize, 0), manager.workspaceFor(first).?);
    try std.testing.expectEqual(@as(usize, 10), manager.workspaceFor(second).?);
    try std.testing.expectEqual(@as(usize, 9), manager.workspaceNumber(first, 10).?);
    try std.testing.expectEqual(@as(usize, 19), manager.workspaceNumber(second, 10).?);
}

test "workspace transition waits for the transaction containing the latest switch" {
    const output: OutputLayout.Id = .{ .index = 1, .generation = 1 };
    var workspaces = [_]OutputWorkspace{
        .{ .output = output, .number = 1, .active = true },
        .{ .output = output, .number = 2, .active = false },
    };

    queueWorkspaceTransition(&workspaces, output, 0);
    beginPendingWorkspaceTransitions(&workspaces);
    try std.testing.expect(workspaces[0].transition_inflight);

    workspaces[0].active = false;
    workspaces[1].active = true;
    queueWorkspaceTransition(&workspaces, output, 1);
    try std.testing.expect(!publishWorkspaceTransition(&workspaces[0]));
    try std.testing.expect(workspaces[1].transition_pending);

    beginPendingWorkspaceTransitions(&workspaces);
    try std.testing.expect(!workspaces[1].transition_pending);
    try std.testing.expect(workspaces[1].transition_inflight);
    try std.testing.expect(publishWorkspaceTransition(&workspaces[1]));
}

test "switching back to an inflight workspace does not queue a second fade" {
    const output: OutputLayout.Id = .{ .index = 1, .generation = 1 };
    var workspaces = [_]OutputWorkspace{
        .{ .output = output, .number = 1, .active = false },
        .{ .output = output, .number = 2, .active = true },
    };

    queueWorkspaceTransition(&workspaces, output, 1);
    beginPendingWorkspaceTransitions(&workspaces);
    workspaces[0].active = true;
    workspaces[1].active = false;
    queueWorkspaceTransition(&workspaces, output, 0);
    workspaces[0].active = false;
    workspaces[1].active = true;
    queueWorkspaceTransition(&workspaces, output, 1);

    try std.testing.expect(!workspaces[1].transition_pending);
    try std.testing.expect(publishWorkspaceTransition(&workspaces[1]));
}

test "hidden windows are suspended and not displayed" {
    const plan: types.LayoutPlan = .{ .id = types.id(1), .rect = .{ .x = 0, .y = 0, .size = types.Size.init(1, 1) }, .visible = true };
    try std.testing.expect(repaintSuspended(false, false, plan));
    try std.testing.expect(!displayed(true, false, false, plan));
    try std.testing.expect(!repaintSuspended(false, true, plan));
    try std.testing.expect(displayed(true, false, true, plan));
    try std.testing.expect(!displayed(false, false, true, plan));

    var hidden = plan;
    hidden.visible = false;
    try std.testing.expect(repaintSuspended(false, true, hidden));
    try std.testing.expect(repaintSuspended(false, true, null));
    try std.testing.expect(repaintSuspended(true, true, plan));
}

test "first floating publication waits for its coalesced relayout" {
    try std.testing.expect(!firstPublicationReady(false, true, true));
    try std.testing.expect(firstPublicationReady(false, true, false));
    try std.testing.expect(firstPublicationReady(false, false, true));
    try std.testing.expect(firstPublicationReady(true, true, true));
}

test "window borders distinguish focus and exclude fullscreen windows" {
    const unfocused: Scene.Borders = .{
        .edges = .{ .top = true },
        .width = 1,
        .color = .{ .red = 64, .green = 64, .blue = 64, .alpha = 255 },
    };
    const focused: Scene.Borders = .{
        .edges = .{ .top = true },
        .width = 2,
        .color = .{ .red = 128, .green = 128, .blue = 128, .alpha = 255 },
    };
    try std.testing.expectEqual(unfocused, borderForWindowState(unfocused, focused, false, false).?);
    try std.testing.expectEqual(focused, borderForWindowState(unfocused, focused, true, false).?);
    try std.testing.expect(borderForWindowState(unfocused, focused, false, true) == null);
}

test "XDG configure is sent only for initial or changed state" {
    const dimensions: XdgShell.Dimensions = .{ .width = 640, .height = 480 };
    const configuration: XdgShell.ToplevelConfigure = .{
        .activated = true,
        .tiled = .{ .top = true, .bottom = true },
    };

    try std.testing.expect(needsXdgConfigure(null, configuration, false, dimensions, configuration));
    try std.testing.expect(needsXdgConfigure(dimensions, configuration, true, dimensions, configuration));
    try std.testing.expect(needsXdgConfigure(
        dimensions,
        configuration,
        false,
        .{ .width = 800, .height = 600 },
        configuration,
    ));
    try std.testing.expect(needsXdgConfigure(
        dimensions,
        configuration,
        false,
        dimensions,
        .{ .activated = false },
    ));
    try std.testing.expect(!needsXdgConfigure(
        dimensions,
        configuration,
        false,
        dimensions,
        configuration,
    ));
}

test "unmapped floating XDG toplevel chooses its natural size" {
    const placement: XdgShell.Dimensions = .{ .width = 640, .height = 480 };
    try std.testing.expectEqual(
        XdgShell.Dimensions{ .width = 0, .height = 0 },
        requestedXdgDimensions(null, placement, true, false),
    );
    try std.testing.expectEqual(
        placement,
        requestedXdgDimensions(.{ .width = 420, .height = 240 }, placement, true, false),
    );
    try std.testing.expectEqual(placement, requestedXdgDimensions(null, placement, false, false));
    try std.testing.expectEqual(placement, requestedXdgDimensions(null, placement, true, true));
}

test "XDG toplevel with one fixed dimension wants floating" {
    try std.testing.expect(fixedSizeWantsFloating(
        .{ .width = 784, .height = 400 },
        .{ .width = 784, .height = std.math.maxInt(i32) },
    ));
    try std.testing.expect(fixedSizeWantsFloating(
        .{ .width = 784, .height = 400 },
        .{ .width = std.math.maxInt(i32), .height = 400 },
    ));
    try std.testing.expect(!fixedSizeWantsFloating(
        .{ .width = 784, .height = 400 },
        .{ .width = std.math.maxInt(i32), .height = std.math.maxInt(i32) },
    ));
    try std.testing.expect(!fixedSizeWantsFloating(
        .{ .width = 784, .height = 0 },
        .{ .width = 784, .height = 0 },
    ));
}

test "removed windows release owned pointer interactions and drop targets" {
    const removed: WindowId = .{ .index = 1, .generation = 1 };
    const other: WindowId = .{ .index = 2, .generation = 1 };
    var manager: Self = undefined;
    manager.tiling_drag = .{ .source = removed, .initial_x = 0, .initial_y = 0 };
    manager.toplevel_drag = .{
        .window = removed,
        .grab_x = 0,
        .grab_y = 0,
        .initial_position = .{},
        .original_floating_override = null,
        .original_floating_position = null,
        .original_floating_restore_size = null,
    };
    manager.interactive_resize = .{ .floating = .{
        .window = removed,
        .initial_rect = .{ .x = 0, .y = 0, .size = types.Size.init(1, 1) },
        .initial_pointer_x = 0,
        .initial_pointer_y = 0,
        .edges = .{ .right = true },
        .constraints = .{},
    } };

    manager.removeWindowPointerInteractions(removed);
    try std.testing.expect(manager.tiling_drag == null);
    try std.testing.expect(manager.toplevel_drag == null);
    try std.testing.expect(manager.interactive_resize == null);

    manager.tiling_drag = .{
        .source = other,
        .initial_x = 0,
        .initial_y = 0,
        .target = .{ .window = .{ .window = removed, .position = .left } },
    };
    manager.toplevel_drag = null;
    manager.interactive_resize = null;
    manager.removeWindowPointerInteractions(removed);
    try std.testing.expect(manager.tiling_drag != null);
    try std.testing.expect(manager.tiling_drag.?.target == null);
}

test "floating directional navigation uses signed center distance on its axis" {
    const origin: types.Rect = .{ .x = 40, .y = 40, .size = types.Size.init(20, 20) };
    const left: types.Rect = .{ .x = 0, .y = 400, .size = types.Size.init(20, 10) };
    const right: types.Rect = .{ .x = 70, .y = 40, .size = types.Size.init(20, 20) };

    try std.testing.expect(directionalDelta(origin, left, .left) > 0);
    try std.testing.expect(directionalDelta(origin, left, .right) < 0);
    try std.testing.expect(directionalDelta(origin, right, .right) > 0);
    try std.testing.expectEqual(
        directionalDelta(origin, left, .left),
        directionalDelta(origin, .{ .x = 0, .y = -400, .size = types.Size.init(20, 10) }, .left),
    );
}
