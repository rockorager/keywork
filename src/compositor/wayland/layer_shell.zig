//! wlr-layer-shell protocol and output-local policy mechanics.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const render = @import("../render/types.zig");
const Scene = @import("../scene.zig");
const slot_map = @import("../slot_map.zig");
const Output = @import("output.zig");
const OutputLayout = @import("output_layout.zig");
const Seat = @import("seat.zig");
const Surface = @import("surface.zig");
const XdgShell = @import("../XdgShell.zig");
const MatureXdgShell = @import("xdg_shell.zig");
const MatureSerials = @import("mature_serials.zig");

const wl = wayland.server.wl;
const zwlr = wayland.server.zwlr;

allocator: std.mem.Allocator,
display: *wl.Server,
outputs: *OutputLayout,
default_output_id: OutputLayout.Id,
scene: *Scene,
seat: *Seat,
xdg_shell: *MatureXdgShell,
xdg_core: *XdgShell,
surfaces: *Surface.Store,
global: *wl.Global,
states: Store = .{},
regular_focus: ?Surface.Id = null,
usable_area: Rect,
policy_listener: ?PolicyListener = null,
repaint_listener: ?RepaintListener = null,

const Store = slot_map.SlotMap(State, enum { layer_surface });
const Id = Store.Id;

pub const Rect = struct { x: i32, y: i32, width: i32, height: i32 };
pub const FocusClass = enum { exclusive, non_exclusive, none };
pub const PolicyListener = struct {
    context: *anyopaque,
    supported: *const fn (*anyopaque) bool,
    changed: *const fn (*anyopaque, Rect, FocusClass) void,
};
pub const RepaintListener = struct {
    context: *anyopaque,
    request: *const fn (*anyopaque) void,
};
const Margins = struct { top: i32 = 0, right: i32 = 0, bottom: i32 = 0, left: i32 = 0 };
const StateValue = struct {
    width: u32 = 0,
    height: u32 = 0,
    anchor: zwlr.LayerSurfaceV1.Anchor = .{},
    zone: i32 = 0,
    margins: Margins = .{},
    keyboard: zwlr.LayerSurfaceV1.KeyboardInteractivity = .none,
    layer: zwlr.LayerShellV1.Layer,
    exclusive_edge: zwlr.LayerSurfaceV1.Anchor = .{},
};
const State = struct {
    adapter: *Adapter,
    surface_id: Surface.Id,
    scene_id: Scene.LayerSurfaceId,
    output_id: OutputLayout.Id,
    initial_layer: zwlr.LayerShellV1.Layer,
    pending: StateValue,
    current: StateValue,
    serials: std.ArrayList(u32) = .empty,
    acked: bool = false,
    configured: bool = false,
    mapped: bool = false,
    awaiting_initial_commit: bool = true,
    last_size: ?[2]u32 = null,
};
const Adapter = struct { shell: *Self, id: Id, resource: ?*zwlr.LayerSurfaceV1, surface: ?*Surface };

pub fn init(self: *Self, allocator: std.mem.Allocator, display: *wl.Server, outputs: *OutputLayout, output_id: OutputLayout.Id, scene: *Scene, seat: *Seat, xdg_shell: *MatureXdgShell, xdg_core: *XdgShell, surfaces: *Surface.Store) !void {
    const output = outputs.get(output_id) orelse unreachable;
    const bounds = outputBounds(output);
    self.* = .{
        .allocator = allocator,
        .display = display,
        .outputs = outputs,
        .default_output_id = output_id,
        .scene = scene,
        .seat = seat,
        .xdg_shell = xdg_shell,
        .xdg_core = xdg_core,
        .surfaces = surfaces,
        .global = try wl.Global.create(display, zwlr.LayerShellV1, 5, *Self, self, bind),
        .usable_area = bounds,
    };
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.states.len() == 0);
    self.global.destroy();
    self.states.deinit(self.allocator);
    self.* = undefined;
}

pub fn usableArea(self: *const Self) Rect {
    return self.usable_area;
}

pub fn usableAreaFor(self: *Self, output_id: OutputLayout.Id) ?Rect {
    const output = self.outputs.get(output_id) orelse return null;
    var usable = outputBounds(output);
    var it = self.states.iterator();
    while (it.next()) |entry| {
        const state = entry.value;
        if (!std.meta.eql(state.output_id, output_id)) continue;
        if (state.awaiting_initial_commit) continue;
        if (!state.configured and state.adapter.surface.?.state().has_committed == false) continue;
        if (state.current.zone <= 0) continue;
        const edge = exclusiveEdge(state.current) orelse continue;
        subtract(
            &usable,
            edge,
            @as(i64, state.current.zone) + edgeMargin(state.current, edge),
        );
    }
    return usable;
}

pub fn setDefaultOutput(self: *Self, output_id: OutputLayout.Id) void {
    std.debug.assert(self.outputs.get(output_id) != null);
    self.default_output_id = output_id;
    self.arrange();
}

pub fn outputRemoved(self: *Self, output_id: OutputLayout.Id) void {
    var removed = false;
    var iterator = self.states.iterator();
    while (iterator.next()) |entry| {
        if (!std.meta.eql(entry.value.output_id, output_id)) continue;
        if (entry.value.adapter.resource) |resource| resource.sendClosed();
        std.debug.assert(self.removeState(entry.id));
        removed = true;
    }
    if (removed) self.arrange();
}

pub fn refresh(self: *Self) void {
    self.arrange();
}

/// Copies the listener and retains its context until replacement, clear, or deinit.
pub fn setPolicyListener(self: *Self, listener: PolicyListener) void {
    self.policy_listener = listener;
    self.notifyPolicy();
}

pub fn clearPolicyListener(self: *Self) void {
    self.policy_listener = null;
}

/// Copies the listener and retains its context until clearRepaintListener or deinit.
pub fn setRepaintListener(self: *Self, listener: RepaintListener) void {
    std.debug.assert(self.repaint_listener == null);
    self.repaint_listener = listener;
}

pub fn clearRepaintListener(self: *Self) void {
    std.debug.assert(self.repaint_listener != null);
    self.repaint_listener = null;
}

pub fn relinquishNonExclusiveFocus(self: *Self) bool {
    if (self.focusClass() != .non_exclusive) return false;
    self.regular_focus = null;
    self.notifyPolicy();
    self.requestRepaint();
    return true;
}

fn focusClass(self: *Self) FocusClass {
    if (self.exclusiveKeyboardFocus() != null) return .exclusive;
    if (self.regularKeyboardFocus() != null) return .non_exclusive;
    return .none;
}

fn notifyPolicy(self: *Self) void {
    const listener = self.policy_listener orelse return;
    listener.changed(listener.context, self.usable_area, self.focusClass());
}

fn requestRepaint(self: *Self) void {
    if (self.repaint_listener) |listener| listener.request(listener.context);
}

fn exclusiveKeyboardFocus(self: *Self) ?Surface.Id {
    const layers = [_]Scene.Layer{ .overlay, .top };
    for (layers) |layer| {
        var it = self.scene.reverseLayerSurfaceIterator(layer);
        while (it.next()) |entry| {
            if (!entry.layer_surface.mapped) continue;
            const state = self.findScene(entry.id) orelse continue;
            if (state.current.keyboard == .exclusive) return state.surface_id;
        }
    }
    return null;
}

fn regularKeyboardFocus(self: *Self) ?Surface.Id {
    const id = self.regular_focus orelse return null;
    const state = self.findSurface(id) orelse return null;
    return if (state.mapped and (state.current.keyboard == .on_demand or
        ((state.current.layer == .background or state.current.layer == .bottom) and state.current.keyboard == .exclusive))) id else null;
}

pub fn keyboardFocus(self: *Self, popup_focus: ?Surface.Id) ?Surface.Id {
    if (self.exclusiveKeyboardFocus()) |exclusive| {
        if (popup_focus) |popup| {
            const root = self.xdg_core.popupRootLayerSurface(popup);
            const state = if (root) |id| self.findScene(id) else null;
            if (state != null and std.meta.eql(state.?.surface_id, exclusive)) return popup;
        }
        return exclusive;
    }
    if (popup_focus) |popup| {
        const root = self.xdg_core.popupRootLayerSurface(popup) orelse return popup;
        const state = self.findScene(root) orelse return self.regularKeyboardFocus();
        if (state.current.keyboard != .none) return popup;
    }
    return self.regularKeyboardFocus();
}

pub fn pointerPressed(self: *Self, id: ?Surface.Id) void {
    self.regular_focus = null;
    defer self.notifyPolicy();
    const surface_id = id orelse return;
    const state = self.findSurface(surface_id) orelse popup: {
        const scene_id = self.xdg_core.popupRootLayerSurface(surface_id) orelse return;
        break :popup self.findScene(scene_id) orelse return;
    };
    if (state.mapped and (state.current.keyboard == .on_demand or
        ((state.current.layer == .background or state.current.layer == .bottom) and state.current.keyboard == .exclusive))) self.regular_focus = state.surface_id;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = zwlr.LayerShellV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, managerRequest, null, self);
}

fn managerRequest(resource: *zwlr.LayerShellV1, request: zwlr.LayerShellV1.Request, self: *Self) void {
    switch (request) {
        .destroy => resource.destroy(),
        .get_layer_surface => |r| self.createSurface(resource, r) catch |err| switch (err) {
            error.OutOfMemory => resource.postNoMemory(),
            error.InvalidLayer => resource.postError(.invalid_layer, "invalid layer"),
            error.Role => resource.postError(.role, "wl_surface already has a role"),
            error.AlreadyConstructed => resource.postError(
                .already_constructed,
                "wl_surface already has attached or committed content",
            ),
            error.InvalidOutput => resource.getClient().postImplementationError(
                "layer surface requested an unsupported wl_output",
            ),
            error.InvalidNamespace => resource.getClient().postImplementationError(
                "layer surface namespace is not valid UTF-8",
            ),
        },
    }
}

const CreateError = error{
    OutOfMemory,
    InvalidLayer,
    Role,
    AlreadyConstructed,
    InvalidOutput,
    InvalidNamespace,
};
fn createSurface(self: *Self, manager: *zwlr.LayerShellV1, r: anytype) CreateError!void {
    if (!validLayer(r.layer)) return error.InvalidLayer;
    const output_id = if (r.output) |resource| output: {
        const output = self.outputs.findResource(resource) orelse return error.InvalidOutput;
        break :output output.id;
    } else self.outputForUnspecifiedSurface();
    if (!std.unicode.utf8ValidateSlice(std.mem.span(r.namespace))) {
        return error.InvalidNamespace;
    }
    const surface = Surface.fromResource(r.surface);
    if (surface.assignedRole()) |role| if (role != .layer_surface) return error.Role;
    if (surface.hasBufferAttachedOrCommitted()) return error.AlreadyConstructed;
    const adapter = self.allocator.create(Adapter) catch return error.OutOfMemory;
    errdefer self.allocator.destroy(adapter);
    surface.reserveRole(.layer_surface, .{
        .context = adapter,
        .before_commit = beforeCommit,
        .after_commit = afterCommit,
        .surface_destroyed = surfaceDestroyed,
        .preferred_scale = surfacePreferredScale,
    }) catch return error.Role;
    errdefer surface.releaseRole(adapter);
    const scene_id = self.scene.addLayerSurface(surface.handle(), sceneLayer(r.layer)) catch return error.OutOfMemory;
    errdefer self.scene.removeLayerSurface(scene_id);
    const value: StateValue = .{ .layer = r.layer };
    const id = self.states.insert(self.allocator, .{ .adapter = adapter, .surface_id = surface.handle(), .scene_id = scene_id, .output_id = output_id, .initial_layer = r.layer, .pending = value, .current = value }) catch return error.OutOfMemory;
    adapter.* = .{ .shell = self, .id = id, .resource = null, .surface = surface };
    const protocol = zwlr.LayerSurfaceV1.create(manager.getClient(), manager.getVersion(), r.id) catch {
        self.remove(id);
        return error.OutOfMemory;
    };
    adapter.resource = protocol;
    protocol.setHandler(*Adapter, surfaceRequest, resourceDestroyed, adapter);
    surface.assignReservedRole(.layer_surface, adapter) catch unreachable;
    if (self.policy_listener) |listener| if (!listener.supported(listener.context)) {
        protocol.sendClosed();
        self.remove(id);
        return;
    };
}

fn outputForUnspecifiedSurface(self: *Self) OutputLayout.Id {
    const position = self.seat.pointerPosition() orelse return self.default_output_id;
    const output = self.outputs.outputAt(position.x, position.y) orelse return self.default_output_id;
    return output.id;
}

fn surfacePreferredScale(context: *anyopaque) ?render.Scale {
    const adapter: *Adapter = @ptrCast(@alignCast(context));
    const state = adapter.shell.states.get(adapter.id) orelse return null;
    const output = adapter.shell.outputs.get(state.output_id) orelse return null;
    return output.preferredScale();
}

fn surfaceRequest(resource: *zwlr.LayerSurfaceV1, request: zwlr.LayerSurfaceV1.Request, adapter: *Adapter) void {
    switch (request) {
        .destroy => {
            resource.destroy();
            return;
        },
        else => {},
    }
    const state = adapter.shell.states.get(adapter.id) orelse return;
    switch (request) {
        .set_size => |r| {
            state.pending.width = r.width;
            state.pending.height = r.height;
        },
        .set_anchor => |r| state.pending.anchor = r.anchor,
        .set_exclusive_zone => |r| state.pending.zone = r.zone,
        .set_margin => |r| state.pending.margins = .{ .top = r.top, .right = r.right, .bottom = r.bottom, .left = r.left },
        .set_keyboard_interactivity => |r| state.pending.keyboard = if (resource.getVersion() < 4 and
            r.keyboard_interactivity != .none) .exclusive else r.keyboard_interactivity,
        .set_layer => |r| state.pending.layer = r.layer,
        .set_exclusive_edge => |r| state.pending.exclusive_edge = r.edge,
        .ack_configure => |r| ackConfigure(resource, state, r.serial),
        .get_popup => |r| adapter.shell.xdg_shell.attachPopup(r.popup, state.scene_id) catch |err| switch (err) {
            error.OutOfMemory => resource.postNoMemory(),
            else => resource.postError(.invalid_surface_state, "invalid xdg popup"),
        },
        .destroy => unreachable,
    }
}

fn ackConfigure(resource: *zwlr.LayerSurfaceV1, state: *State, serial: u32) void {
    for (state.serials.items, 0..) |candidate, i| {
        if (candidate != serial) continue;
        state.acked = true;
        var count = i + 1;
        while (count > 0) : (count -= 1) _ = state.serials.orderedRemove(0);
        return;
    }
    resource.postError(.invalid_surface_state, "configure serial was not issued by this layer surface");
}

fn beforeCommit(context: *anyopaque, info: Surface.CommitInfo) Surface.CommitAction {
    const adapter: *Adapter = @ptrCast(@alignCast(context));
    const state = adapter.shell.states.get(adapter.id) orelse return .reject;
    if (!validState(state.pending)) {
        postStateError(adapter.resource.?, state.pending);
        return .reject;
    }
    if (info.has_buffer and !state.acked) {
        adapter.resource.?.postError(.invalid_surface_state, "buffer committed before configure was acknowledged");
        return .reject;
    }
    return .apply;
}

fn afterCommit(context: *anyopaque, info: Surface.CommitInfo) void {
    const adapter: *Adapter = @ptrCast(@alignCast(context));
    const self = adapter.shell;
    const state = self.states.get(adapter.id) orelse return;
    if (!info.has_buffer and state.mapped) {
        self.xdg_core.dismissLayerSurfacePopups(state.scene_id);
        state.mapped = false;
        state.configured = false;
        state.acked = false;
        state.serials.clearRetainingCapacity();
        state.last_size = null;
        state.awaiting_initial_commit = true;
        state.pending = .{ .layer = state.initial_layer };
        self.scene.setLayerSurfaceMapped(state.scene_id, false);
        self.commitPendingState(state) catch {
            adapter.resource.?.postNoMemory();
            self.invalidateFocus(state.surface_id);
            self.arrange();
            return;
        };
        self.invalidateFocus(state.surface_id);
        self.arrange();
        return;
    }
    self.commitPendingState(state) catch {
        adapter.resource.?.postNoMemory();
        return;
    };
    state.awaiting_initial_commit = false;
    if (info.has_buffer) {
        state.mapped = true;
        self.scene.setLayerSurfaceMapped(state.scene_id, true);
        self.scene.layerSurfaceCommitted(state.scene_id);
    }
    self.arrange();
}

fn commitPendingState(self: *Self, state: *State) error{OutOfMemory}!void {
    try self.scene.setLayerSurfaceLayer(state.scene_id, sceneLayer(state.pending.layer));
    state.current = state.pending;
}

fn arrange(self: *Self) void {
    var outputs = self.outputs.iterator();
    while (outputs.next()) |entry| {
        const usable = self.arrangeOutput(entry.id, entry.output);
        if (std.meta.eql(entry.id, self.default_output_id)) self.usable_area = usable;
    }
    self.notifyPolicy();
}

fn arrangeOutput(self: *Self, output_id: OutputLayout.Id, output: *Output) Rect {
    const output_bounds = outputBounds(output);
    var usable = output_bounds;
    var pass: u2 = 0;
    while (pass < 2) : (pass += 1) {
        var it = self.states.iterator();
        while (it.next()) |entry| {
            const state = entry.value;
            if (!std.meta.eql(state.output_id, output_id)) continue;
            if (state.awaiting_initial_commit) continue;
            if (!state.configured and state.adapter.surface.?.state().has_committed == false) continue;
            const edge = exclusiveEdge(state.current);
            if ((pass == 0) != (state.current.zone > 0 and edge != null)) continue;
            const bounds = if (state.current.zone == -1) output_bounds else usable;
            const hint = place(bounds, state.current, null);
            const actual: ?[2]i32 = if (state.mapped) if (Surface.currentLogicalSize(self.surfaces, state.surface_id)) |logical|
                .{ @intCast(logical.width), @intCast(logical.height) }
            else
                null else null;
            const geometry = place(bounds, state.current, actual);
            self.scene.setLayerSurfacePosition(state.scene_id, .{ .x = geometry.x, .y = geometry.y });
            const desired = [2]u32{ @intCast(hint.width), @intCast(hint.height) };
            if (pass == 0) subtract(
                &usable,
                edge.?,
                @as(i64, state.current.zone) + edgeMargin(state.current, edge.?),
            );
            if (!state.configured or !std.meta.eql(state.last_size, desired)) {
                const serial = MatureSerials.issueWire(self.display);
                state.serials.append(self.allocator, serial) catch {
                    state.adapter.resource.?.postNoMemory();
                    continue;
                };
                state.adapter.resource.?.sendConfigure(serial, desired[0], desired[1]);
                state.last_size = desired;
                state.configured = true;
            }
        }
    }
    return usable;
}

fn outputBounds(output: *const Output) Rect {
    const rect = output.logicalRect();
    return .{
        .x = rect.x,
        .y = rect.y,
        .width = @intCast(rect.width),
        .height = @intCast(rect.height),
    };
}

fn resourceDestroyed(_: *zwlr.LayerSurfaceV1, adapter: *Adapter) void {
    adapter.resource = null;
    if (adapter.shell.states.get(adapter.id) != null) {
        adapter.shell.remove(adapter.id);
    } else {
        adapter.shell.allocator.destroy(adapter);
    }
}
fn surfaceDestroyed(context: *anyopaque) void {
    const adapter: *Adapter = @ptrCast(@alignCast(context));
    adapter.surface = null;
    adapter.shell.remove(adapter.id);
}
fn remove(self: *Self, id: Id) void {
    if (!self.removeState(id)) return;
    self.arrange();
}
fn removeState(self: *Self, id: Id) bool {
    var state = self.states.remove(id) orelse return false;
    self.xdg_core.dismissLayerSurfacePopups(state.scene_id);
    self.scene.removeLayerSurface(state.scene_id);
    self.invalidateFocus(state.surface_id);
    if (state.adapter.surface) |surface| surface.releaseRole(state.adapter);
    state.serials.deinit(self.allocator);
    if (state.adapter.resource == null) self.allocator.destroy(state.adapter);
    return true;
}

fn invalidateFocus(self: *Self, id: Surface.Id) void {
    if (self.regular_focus) |focus| {
        if (std.meta.eql(focus, id)) self.regular_focus = null;
    }
}
fn findSurface(self: *Self, id: Surface.Id) ?*State {
    var it = self.states.iterator();
    while (it.next()) |e| if (std.meta.eql(e.value.surface_id, id)) return e.value;
    return null;
}
fn findScene(self: *Self, id: Scene.LayerSurfaceId) ?*State {
    var it = self.states.iterator();
    while (it.next()) |e| if (std.meta.eql(e.value.scene_id, id)) return e.value;
    return null;
}
fn validLayer(layer: zwlr.LayerShellV1.Layer) bool {
    return switch (layer) {
        .background, .bottom, .top, .overlay => true,
        _ => false,
    };
}
fn sceneLayer(layer: zwlr.LayerShellV1.Layer) Scene.Layer {
    return switch (layer) {
        .background => .background,
        .bottom => .bottom,
        .top => .top,
        .overlay => .overlay,
        _ => unreachable,
    };
}
fn validState(s: StateValue) bool {
    const bits: u32 = @bitCast(s.anchor);
    return bits <= 15 and validLayer(s.layer) and
        (s.keyboard == .none or s.keyboard == .exclusive or s.keyboard == .on_demand) and
        !(s.width == 0 and !(s.anchor.left and s.anchor.right)) and
        !(s.height == 0 and !(s.anchor.top and s.anchor.bottom)) and validExclusive(s);
}
fn validExclusive(s: StateValue) bool {
    const bits: u32 = @bitCast(s.exclusive_edge);
    return bits == 0 or (bits & (bits - 1) == 0 and bits <= 8 and (bits & @as(u32, @bitCast(s.anchor))) != 0);
}
fn postStateError(r: *zwlr.LayerSurfaceV1, s: StateValue) void {
    if (@as(u32, @bitCast(s.anchor)) > 15) {
        r.postError(.invalid_anchor, "invalid anchor");
    } else if (!(s.keyboard == .none or
        s.keyboard == .exclusive or
        s.keyboard == .on_demand))
    {
        r.postError(.invalid_keyboard_interactivity, "invalid keyboard interactivity");
    } else if (!validLayer(s.layer)) {
        r.postError(.invalid_surface_state, "invalid layer");
    } else if (!validExclusive(s)) {
        r.postError(.invalid_exclusive_edge, "invalid exclusive edge");
    } else {
        r.postError(.invalid_size, "invalid size or zero size without opposite anchors");
    }
}
fn exclusiveEdge(s: StateValue) ?zwlr.LayerSurfaceV1.Anchor.Enum {
    const explicit: u32 = @bitCast(s.exclusive_edge);
    if (explicit != 0) return @enumFromInt(explicit);
    const a = s.anchor;
    if (a.top and !a.bottom and (a.left == a.right)) return .top;
    if (a.bottom and !a.top and (a.left == a.right)) return .bottom;
    if (a.left and !a.right and (a.top == a.bottom)) return .left;
    if (a.right and !a.left and (a.top == a.bottom)) return .right;
    return null;
}
fn edgeMargin(s: StateValue, edge: zwlr.LayerSurfaceV1.Anchor.Enum) i64 {
    return switch (edge) {
        .top => s.margins.top,
        .bottom => s.margins.bottom,
        .left => s.margins.left,
        .right => s.margins.right,
        _ => 0,
    };
}
fn subtract(r: *Rect, edge: zwlr.LayerSurfaceV1.Anchor.Enum, amount: i64) void {
    const available = switch (edge) {
        .top, .bottom => r.height,
        .left, .right => r.width,
        _ => 0,
    };
    const n: i32 = @intCast(std.math.clamp(amount, 0, @as(i64, available)));
    switch (edge) {
        .top => {
            r.y += n;
            r.height = @max(0, r.height - n);
        },
        .bottom => r.height = @max(0, r.height - n),
        .left => {
            r.x += n;
            r.width = @max(0, r.width - n);
        },
        .right => r.width = @max(0, r.width - n),
        _ => {},
    }
}
fn place(bounds: Rect, s: StateValue, actual: ?[2]i32) Rect {
    const width = if (actual) |a|
        @as(i64, a[0])
    else if (s.width == 0)
        @max(0, @as(i64, bounds.width) - s.margins.left - s.margins.right)
    else
        s.width;
    const height = if (actual) |a|
        @as(i64, a[1])
    else if (s.height == 0)
        @max(0, @as(i64, bounds.height) - s.margins.top - s.margins.bottom)
    else
        s.height;
    const x = if (s.anchor.left and !s.anchor.right)
        @as(i64, bounds.x) + s.margins.left
    else if (s.anchor.right and !s.anchor.left)
        @as(i64, bounds.x) + bounds.width - width - s.margins.right
    else if (s.anchor.left and s.anchor.right)
        @as(i64, bounds.x) + @divTrunc(
            @as(i64, bounds.width) - width + s.margins.left - s.margins.right,
            2,
        )
    else
        @as(i64, bounds.x) + @divTrunc(@as(i64, bounds.width) - width, 2);
    const y = if (s.anchor.top and !s.anchor.bottom)
        @as(i64, bounds.y) + s.margins.top
    else if (s.anchor.bottom and !s.anchor.top)
        @as(i64, bounds.y) + bounds.height - height - s.margins.bottom
    else if (s.anchor.top and s.anchor.bottom)
        @as(i64, bounds.y) + @divTrunc(
            @as(i64, bounds.height) - height + s.margins.top - s.margins.bottom,
            2,
        )
    else
        @as(i64, bounds.y) + @divTrunc(@as(i64, bounds.height) - height, 2);
    return .{
        .x = clampI32(x),
        .y = clampI32(y),
        .width = clampSize(width),
        .height = clampSize(height),
    };
}

fn clampI32(value: i64) i32 {
    return @intCast(std.math.clamp(
        value,
        std.math.minInt(i32),
        std.math.maxInt(i32),
    ));
}

fn clampSize(value: i64) i32 {
    return @intCast(std.math.clamp(value, 0, std.math.maxInt(i32)));
}

test "geometry validation inference and usable area" {
    var s: StateValue = .{ .layer = .top, .width = 100, .height = 20, .anchor = .{ .top = true, .left = true, .right = true }, .zone = 20, .margins = .{ .top = 3 } };
    try std.testing.expect(validState(s));
    try std.testing.expectEqual(zwlr.LayerSurfaceV1.Anchor.Enum.top, exclusiveEdge(s).?);
    const g = place(.{ .x = 0, .y = 0, .width = 800, .height = 600 }, s, null);
    try std.testing.expectEqual(@as(i32, 350), g.x);
    try std.testing.expectEqual(@as(i32, 3), g.y);
    var area: Rect = .{ .x = 0, .y = 0, .width = 800, .height = 600 };
    subtract(&area, .top, 23);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 23, .width = 800, .height = 577 }, area);
    s.width = 0;
    s.anchor.right = false;
    try std.testing.expect(!validState(s));
}

test "geometry ignores margins on unanchored edges" {
    const state: StateValue = .{
        .layer = .top,
        .width = 100,
        .height = 50,
        .margins = .{ .top = 10, .right = 20, .bottom = 30, .left = 40 },
    };
    try std.testing.expectEqual(
        Rect{ .x = 350, .y = 275, .width = 100, .height = 50 },
        place(.{ .x = 0, .y = 0, .width = 800, .height = 600 }, state, null),
    );
}

test "geometry preserves a non-zero output origin" {
    const state: StateValue = .{
        .layer = .top,
        .width = 100,
        .height = 50,
        .anchor = .{ .top = true, .left = true },
        .margins = .{ .top = 5, .left = 10 },
    };
    try std.testing.expectEqual(
        Rect{ .x = 1290, .y = -195, .width = 100, .height = 50 },
        place(.{ .x = 1280, .y = -200, .width = 800, .height = 600 }, state, null),
    );
}

test "committing layer state is atomic with the scene stack" {
    var scene: Scene = undefined;
    scene.init(std.testing.allocator);
    defer scene.deinit();
    const scene_id = try scene.addLayerSurface(
        .{ .index = 1, .generation = 1 },
        .top,
    );
    defer scene.removeLayerSurface(scene_id);

    var shell: Self = undefined;
    shell.scene = &scene;
    var state: State = .{
        .adapter = undefined,
        .surface_id = .{ .index = 1, .generation = 1 },
        .scene_id = scene_id,
        .output_id = undefined,
        .initial_layer = .top,
        .pending = .{ .layer = .overlay },
        .current = .{ .layer = .top },
    };

    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    scene.allocator = failing.allocator();
    const result = shell.commitPendingState(&state);
    scene.allocator = std.testing.allocator;
    try std.testing.expectError(error.OutOfMemory, result);
    try std.testing.expectEqual(zwlr.LayerShellV1.Layer.top, state.current.layer);
    try std.testing.expectEqual(Scene.Layer.top, scene.layerSurface(scene_id).?.layer);

    try shell.commitPendingState(&state);
    try std.testing.expectEqual(zwlr.LayerShellV1.Layer.overlay, state.current.layer);
    try std.testing.expectEqual(Scene.Layer.overlay, scene.layerSurface(scene_id).?.layer);
}
