//! Shared Wayland window protocol and event-loop integration.

const std = @import("std");
const event_loop = @import("../../linux/event_loop.zig");
const keywork = @import("../../ui.zig");
const wayland_options = @import("options.zig");
const wayland = @import("wayland");

const linux = std.os.linux;
const wp = wayland.client.wp;
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const zwlr = wayland.client.zwlr;
const zxdg = wayland.client.zxdg;

const log = std.log.scoped(.keywork_wayland_window);

const ShellRole = union(enum) {
    xdg: struct {
        surface: *xdg.Surface,
        toplevel: *xdg.Toplevel,
    },
    layer: struct {
        surface: *zwlr.LayerSurfaceV1,
    },
    popup: struct {
        surface: *xdg.Surface,
        popup: *xdg.Popup,
    },

    pub fn destroy(self: ShellRole) void {
        switch (self) {
            .xdg => |role| {
                role.toplevel.destroy();
                role.surface.destroy();
            },
            .layer => |role| role.surface.destroy(),
            .popup => |role| {
                role.popup.destroy();
                role.surface.destroy();
            },
        }
    }
};

/// Placement request for a popup surface, in the parent surface's
/// logical coordinate space.
pub const PopupOptions = struct {
    width: u31,
    height: u31,
    anchor_x: i32,
    anchor_y: i32,
    anchor_width: i32,
    anchor_height: i32,
    edge: keywork.Widget.PopupPlacement.Edge = .bottom,
    alignment: keywork.Widget.Alignment = .start,
    gap: i32 = 0,
};

/// Protocol state shared by every renderer targeting a Wayland surface.
/// Renderer-owned buffers and swapchains deliberately remain outside this
/// type so protocol callbacks cannot depend on a rendering implementation.
pub const Surface = struct {
    surface: *wl.Surface,
    viewport: ?*wp.Viewport,
    fractional_scale: ?*wp.FractionalScaleV1,
    shell_role: ShellRole,
    /// xdg-decoration object for toplevels; must be destroyed before the
    /// toplevel it decorates. Null on layer/popup roles or when the
    /// compositor lacks the protocol.
    decoration: ?*zxdg.ToplevelDecorationV1 = null,
    layer_keyboard_interactivity: ?wayland_options.LayerShellOptions.KeyboardInteractivity = null,
    configured: bool = false,
    closed: bool = false,
    /// The compositor reports the toplevel as not visible (minimized, on a
    /// hidden workspace, or fully occluded); repainting would be wasted
    /// work. Requires xdg-shell v6; older compositors never set it.
    suspended: bool = false,
    width: u31,
    height: u31,
    scale: f32 = 1,
    scale_changed: bool = false,
    repaint_pending: bool = false,
    frame_callback: ?*wl.Callback = null,
    frame_done_pending: bool = false,

    pub const Pending = packed struct {
        repaint: bool = false,
        frame_done: bool = false,
    };

    pub fn init(connection: *const Connection, output: ?*wl.Output, options: anytype) !Surface {
        const compositor = connection.compositor orelse return error.NoWlCompositor;
        const surface = try compositor.createSurface();
        errdefer surface.destroy();
        const shell_role = try createShellRole(surface, output, connection.wm_base, connection.layer_shell, options);
        errdefer shell_role.destroy();
        const decoration = try createDecoration(connection.decoration_manager, shell_role, options.decorations);
        errdefer if (decoration) |toplevel_decoration| toplevel_decoration.destroy();
        const viewport = if (connection.viewporter) |manager| try manager.getViewport(surface) else null;
        errdefer if (viewport) |surface_viewport| surface_viewport.destroy();
        const fractional_scale = if (connection.fractional_scale_manager) |manager| try manager.getFractionalScale(surface) else null;
        errdefer if (fractional_scale) |surface_scale| surface_scale.destroy();

        return .{
            .surface = surface,
            .viewport = viewport,
            .fractional_scale = fractional_scale,
            .shell_role = shell_role,
            .decoration = decoration,
            .layer_keyboard_interactivity = if (options.layer_shell) |layer_options|
                layer_options.keyboard_interactivity
            else
                null,
            .width = options.width,
            .height = options.height,
        };
    }

    /// Creates a popup surface anchored to `parent`. The compositor may
    /// reposition or resize the popup; the final geometry arrives in the
    /// xdg_popup configure event.
    pub fn initPopup(connection: *const Connection, parent: *const Surface, options: PopupOptions) !Surface {
        const compositor = connection.compositor orelse return error.NoWlCompositor;
        const wm_base = connection.wm_base orelse return error.NoXdgWmBase;
        std.debug.assert(options.width > 0 and options.height > 0);

        const surface = try compositor.createSurface();
        errdefer surface.destroy();
        const xdg_surface = try wm_base.getXdgSurface(surface);
        errdefer xdg_surface.destroy();

        const positioner = try wm_base.createPositioner();
        defer positioner.destroy();
        configurePopupPositioner(positioner, options);

        const parent_xdg_surface: ?*xdg.Surface = switch (parent.shell_role) {
            .xdg => |role| role.surface,
            .popup => |role| role.surface,
            .layer => null,
        };
        const popup = try xdg_surface.getPopup(parent_xdg_surface, positioner);
        errdefer popup.destroy();
        // Layer surfaces adopt the popup through the layer-shell protocol
        // instead of an xdg parent.
        if (parent.shell_role == .layer) parent.shell_role.layer.surface.getPopup(popup);

        const viewport = if (connection.viewporter) |manager| try manager.getViewport(surface) else null;
        errdefer if (viewport) |surface_viewport| surface_viewport.destroy();
        const fractional_scale = if (connection.fractional_scale_manager) |manager| try manager.getFractionalScale(surface) else null;
        errdefer if (fractional_scale) |surface_scale| surface_scale.destroy();

        return .{
            .surface = surface,
            .viewport = viewport,
            .fractional_scale = fractional_scale,
            .shell_role = .{ .popup = .{ .surface = xdg_surface, .popup = popup } },
            .width = options.width,
            .height = options.height,
            .scale = parent.scale,
        };
    }

    /// Requests new geometry for an already mapped popup. xdg-shell v3
    /// added reposition specifically for replacing all of a popup's
    /// positioner state, including its desired size.
    pub fn repositionPopup(self: *Surface, connection: *const Connection, options: PopupOptions, token: u32) !void {
        const role = switch (self.shell_role) {
            .popup => |role| role,
            else => return error.NotPopup,
        };
        if (role.popup.getVersion() < 3) return error.PopupRepositionUnsupported;
        const wm_base = connection.wm_base orelse return error.NoXdgWmBase;
        std.debug.assert(options.width > 0 and options.height > 0);

        const positioner = try wm_base.createPositioner();
        defer positioner.destroy();
        configurePopupPositioner(positioner, options);
        role.popup.reposition(positioner, token);
    }

    pub fn deinit(self: *Surface) void {
        if (self.frame_callback) |callback| callback.destroy();
        if (self.fractional_scale) |fractional_scale| fractional_scale.destroy();
        if (self.viewport) |viewport| viewport.destroy();
        if (self.decoration) |decoration| decoration.destroy();
        self.shell_role.destroy();
        self.surface.destroy();
    }

    /// Starts a compositor-driven interactive move. `serial` must come
    /// from the input event (typically a pointer press) that triggered it.
    pub fn startMove(self: *Surface, seat: *wl.Seat, serial: u32) !void {
        switch (self.shell_role) {
            .xdg => |role| role.toplevel.move(seat, serial),
            else => return error.NotToplevel,
        }
    }

    /// Starts a compositor-driven interactive resize from `edge`.
    pub fn startResize(self: *Surface, seat: *wl.Seat, serial: u32, edge: wayland_options.ResizeEdge) !void {
        switch (self.shell_role) {
            .xdg => |role| role.toplevel.resize(seat, serial, resizeEdge(edge)),
            else => return error.NotToplevel,
        }
    }

    /// Listener installation is separate from initialization because the
    /// callback context must point at the object's final storage location.
    pub fn attachListeners(self: *Surface) void {
        switch (self.shell_role) {
            .xdg => |role| {
                role.surface.setListener(*Surface, xdgSurfaceListener, self);
                role.toplevel.setListener(*Surface, toplevelListener, self);
            },
            .layer => |role| role.surface.setListener(*Surface, layerSurfaceListener, self),
            .popup => |role| {
                role.surface.setListener(*Surface, xdgSurfaceListener, self);
                role.popup.setListener(*Surface, popupListener, self);
            },
        }
        if (self.fractional_scale) |fractional_scale| {
            fractional_scale.setListener(*Surface, fractionalScaleListener, self);
        }
    }

    /// Requests an explicit pointer/keyboard grab so the compositor
    /// dismisses the popup when the user clicks elsewhere. Must be called
    /// before the initial commit, with the serial of the input event that
    /// opened the popup.
    pub fn grabPopup(self: *Surface, seat: *wl.Seat, serial: u32) void {
        std.debug.assert(self.shell_role == .popup);
        self.shell_role.popup.popup.grab(seat, serial);
    }

    /// Temporarily makes a normally non-interactive layer surface focusable
    /// while it owns a popup. Exclusive mode lets Sway focus it after the
    /// opening click has already been handled; restoring none returns focus
    /// without leaving the idle panel focusable on pointer hover.
    pub fn setPopupKeyboardFocus(self: *Surface, focused: bool) void {
        if (self.layer_keyboard_interactivity != .none) return;
        const layer_surface = switch (self.shell_role) {
            .layer => |role| role.surface,
            else => return,
        };
        layer_surface.setKeyboardInteractivity(if (focused) .exclusive else .none);
        self.surface.commit();
    }

    pub fn currentSize(self: *const Surface) keywork.Size {
        return .{ .width = @floatFromInt(self.width), .height = @floatFromInt(self.height) };
    }

    pub fn flushPending(self: *Surface) Pending {
        if (self.scale_changed) {
            self.scale_changed = false;
            self.repaint_pending = true;
        }
        const pending: Pending = .{
            .repaint = self.repaint_pending,
            .frame_done = self.frame_done_pending,
        };
        self.repaint_pending = false;
        self.frame_done_pending = false;
        return pending;
    }

    pub fn armFrameCallback(self: *Surface) !void {
        if (self.frame_callback != null) return;
        const callback = try self.surface.frame();
        callback.setListener(*Surface, frameListener, self);
        self.frame_callback = callback;
    }

    fn frameListener(callback: *wl.Callback, event: wl.Callback.Event, self: *Surface) void {
        switch (event) {
            .done => {
                if (self.frame_callback == callback) self.frame_callback = null;
                callback.destroy();
                self.frame_done_pending = true;
            },
        }
    }

    fn fractionalScaleListener(_: *wp.FractionalScaleV1, event: wp.FractionalScaleV1.Event, self: *Surface) void {
        switch (event) {
            .preferred_scale => |preferred| {
                if (preferred.scale == 0) return;
                const scale = @as(f32, @floatFromInt(preferred.scale)) / 120.0;
                if (scale == self.scale) return;
                self.scale = scale;
                self.scale_changed = true;
                log.info("fractional scale {d}", .{scale});
            },
        }
    }

    fn xdgSurfaceListener(xdg_surface: *xdg.Surface, event: xdg.Surface.Event, self: *Surface) void {
        switch (event) {
            .configure => |configure| {
                xdg_surface.ackConfigure(configure.serial);
                self.configured = true;
                self.repaint_pending = true;
            },
        }
    }

    fn layerSurfaceListener(layer_surface: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, self: *Surface) void {
        switch (event) {
            .configure => |configure| {
                layer_surface.ackConfigure(configure.serial);
                if (configure.width > 0) self.width = @intCast(configure.width);
                if (configure.height > 0) self.height = @intCast(configure.height);
                self.configured = true;
                self.repaint_pending = true;
            },
            .closed => self.closed = true,
        }
    }

    fn popupListener(_: *xdg.Popup, event: xdg.Popup.Event, self: *Surface) void {
        switch (event) {
            .configure => |configure| {
                if (configure.width > 0) self.width = @intCast(configure.width);
                if (configure.height > 0) self.height = @intCast(configure.height);
            },
            .popup_done => self.closed = true,
            .repositioned => {},
        }
    }

    fn toplevelListener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, self: *Surface) void {
        switch (event) {
            .configure => |configure| {
                if (configure.width > 0) self.width = @intCast(configure.width);
                if (configure.height > 0) self.height = @intCast(configure.height);
                self.suspended = toplevelHasState(configure.states, .suspended);
            },
            .close => self.closed = true,
            .configure_bounds => {},
            .wm_capabilities => {},
        }
    }
};

/// Requests the preferred decoration mode for xdg toplevels. Without the
/// manager (or on layer/popup roles) the compositor's default applies,
/// which on most desktops means the client is expected to decorate
/// itself.
fn createDecoration(
    manager: ?*zxdg.DecorationManagerV1,
    shell_role: ShellRole,
    preference: wayland_options.Decorations,
) !?*zxdg.ToplevelDecorationV1 {
    const decoration_manager = manager orelse return null;
    const toplevel = switch (shell_role) {
        .xdg => |role| role.toplevel,
        else => return null,
    };
    const decoration = try decoration_manager.getToplevelDecoration(toplevel);
    decoration.setMode(switch (preference) {
        .server => .server_side,
        .client => .client_side,
    });
    return decoration;
}

fn resizeEdge(edge: wayland_options.ResizeEdge) xdg.Toplevel.ResizeEdge {
    return switch (edge) {
        .top => .top,
        .bottom => .bottom,
        .left => .left,
        .right => .right,
        .top_left => .top_left,
        .top_right => .top_right,
        .bottom_left => .bottom_left,
        .bottom_right => .bottom_right,
    };
}

/// Whether a toplevel configure lists `needle` in its states array. States
/// arrive as a wl_array of u32 enum values.
fn toplevelHasState(states: anytype, needle: xdg.Toplevel.State) bool {
    const raw_needle: u32 = @intCast(@intFromEnum(needle));
    for (states.slice(u32)) |state| {
        if (state == raw_needle) return true;
    }
    return false;
}

test toplevelHasState {
    const FakeStates = struct {
        items: []const u32,

        fn slice(self: @This(), comptime T: type) []const T {
            comptime std.debug.assert(T == u32);
            return self.items;
        }
    };
    const suspended_raw: u32 = @intCast(@intFromEnum(xdg.Toplevel.State.suspended));
    const activated_raw: u32 = @intCast(@intFromEnum(xdg.Toplevel.State.activated));

    try std.testing.expect(!toplevelHasState(FakeStates{ .items = &.{} }, .suspended));
    try std.testing.expect(!toplevelHasState(FakeStates{ .items = &.{activated_raw} }, .suspended));
    try std.testing.expect(toplevelHasState(FakeStates{ .items = &.{ activated_raw, suspended_raw } }, .suspended));
}

const OutputRef = struct {
    global_name: u32,
    output: *wl.Output,
    /// Owned copy of the wl_output v4 name (e.g. "DP-1"); null until the
    /// compositor sends it or on older protocol versions.
    name: ?[]u8 = null,
    mode_width: i32 = 0,
    mode_height: i32 = 0,
    scale: i32 = 1,
    /// The initial property burst ended with a done event, so the info
    /// is complete enough to expose.
    ready: bool = false,
};

pub const OutputInfo = wayland_options.OutputInfo;

const GlobalNeeds = struct {
    shm: bool = false,
    outputs: bool = false,
};

/// Owns the Wayland connection and all registry globals. Single-seat: only
/// the first advertised `wl_seat` is bound; later seat globals are ignored.
/// The seat proxy is moved to the input subsystem after its initialization
/// succeeds, but the seat event listener stays connection-owned (wl_proxy
/// allows only one dispatcher) so the initial capabilities event is not
/// dropped. Every other proxy remains connection-owned for its full lifetime.
pub const Connection = struct {
    allocator: std.mem.Allocator,
    needs: GlobalNeeds,
    display: *wl.Display,
    registry: *wl.Registry,
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    wm_base: ?*xdg.WmBase = null,
    layer_shell: ?*zwlr.LayerShellV1 = null,
    viewporter: ?*wp.Viewporter = null,
    fractional_scale_manager: ?*wp.FractionalScaleManagerV1 = null,
    cursor_shape_manager: ?*wp.CursorShapeManagerV1 = null,
    data_device_manager: ?*wl.DataDeviceManager = null,
    activation: ?*xdg.ActivationV1 = null,
    decoration_manager: ?*zxdg.DecorationManagerV1 = null,
    seat: ?*wl.Seat = null,
    /// True once the first seat global has been bound. Survives takeSeat()
    /// so a later seat advertisement cannot overwrite selection or forward
    /// another seat's capabilities into the single WaylandInput.
    seat_selected: bool = false,
    /// Last `wl_seat.capabilities` observed on the selected seat. Input must
    /// not call get_pointer/get_keyboard until this reports the matching
    /// capability.
    seat_capabilities: wl.Seat.Capability = .{},
    /// Forwarded on each capabilities event after the initial bind so input
    /// can bind/release devices without owning the seat listener.
    seat_capabilities_ctx: ?*anyopaque = null,
    seat_capabilities_fn: ?*const fn (ctx: *anyopaque, capabilities: wl.Seat.Capability) void = null,
    outputs: std.ArrayList(OutputRef) = .empty,
    /// Fired when the output set or an output's properties change:
    /// hotplug adds (after the initial done), removals, and mode/scale
    /// updates. Consumers re-read the outputs list.
    outputs_changed_ctx: ?*anyopaque = null,
    outputs_changed_fn: ?*const fn (ctx: *anyopaque) void = null,

    pub fn init(allocator: std.mem.Allocator, needs: GlobalNeeds) !*Connection {
        const display = try wl.Display.connect(null);
        errdefer display.disconnect();

        const registry = try display.getRegistry();
        errdefer registry.destroy();
        const self = try allocator.create(Connection);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .needs = needs,
            .display = display,
            .registry = registry,
        };
        errdefer self.deinitGlobals();

        registry.setListener(*Connection, registryListener, self);
        if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
        if (self.compositor == null) return error.NoWlCompositor;
        if (needs.shm and self.shm == null) return error.NoWlShm;
        // Seat and output listeners were installed during the first
        // roundtrip; their bind requests are only flushed after that
        // roundtrip ends. A second collects the initial seat capabilities
        // and output name/mode/scale bursts so callers see complete state.
        if (self.seat_selected or (needs.outputs and self.outputs.items.len > 0)) {
            if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
        }
        return self;
    }

    pub fn deinit(self: *Connection) void {
        self.deinitGlobals();
        self.registry.destroy();
        self.display.disconnect();
        self.allocator.destroy(self);
    }

    fn deinitGlobals(self: *Connection) void {
        if (self.seat) |seat| seat.release();
        releaseOutputs(self.allocator, &self.outputs);
        if (self.decoration_manager) |manager| manager.destroy();
        if (self.activation) |activation| activation.destroy();
        if (self.data_device_manager) |manager| manager.destroy();
        if (self.cursor_shape_manager) |manager| manager.destroy();
        if (self.fractional_scale_manager) |manager| manager.destroy();
        if (self.viewporter) |viewporter| viewporter.destroy();
        if (self.layer_shell) |layer_shell| layer_shell.destroy();
        if (self.wm_base) |wm_base| wm_base.destroy();
        if (self.shm) |shm| shm.destroy();
        if (self.compositor) |compositor| compositor.destroy();
    }

    pub fn takeSeat(self: *Connection) ?*wl.Seat {
        const seat = self.seat;
        self.seat = null;
        return seat;
    }

    /// Capabilities from the seat's initial (and any subsequent) events.
    /// Valid to read after init and after takeSeat.
    pub fn seatCapabilities(self: *const Connection) wl.Seat.Capability {
        return self.seat_capabilities;
    }

    /// Register a handler for later `wl_seat.capabilities` changes. The seat
    /// listener is installed at bind time and cannot be reassigned.
    pub fn setSeatCapabilitiesHandler(
        self: *Connection,
        ctx: *anyopaque,
        handler: *const fn (ctx: *anyopaque, capabilities: wl.Seat.Capability) void,
    ) void {
        self.seat_capabilities_ctx = ctx;
        self.seat_capabilities_fn = handler;
    }

    pub fn setOutputsChangedHandler(self: *Connection, ctx: *anyopaque, handler: *const fn (ctx: *anyopaque) void) void {
        self.outputs_changed_ctx = ctx;
        self.outputs_changed_fn = handler;
    }

    fn notifyOutputsChanged(self: *Connection) void {
        const handler = self.outputs_changed_fn orelse return;
        handler(self.outputs_changed_ctx.?);
    }

    pub fn outputInfoAt(self: *const Connection, index: usize) OutputInfo {
        const ref = self.outputs.items[index];
        const scale: f32 = @floatFromInt(@max(1, ref.scale));
        return .{
            .name = ref.name orelse "",
            .width = @as(f32, @floatFromInt(@max(0, ref.mode_width))) / scale,
            .height = @as(f32, @floatFromInt(@max(0, ref.mode_height))) / scale,
            .scale = scale,
        };
    }

    pub fn findOutputByName(self: *const Connection, name: []const u8) ?*wl.Output {
        for (self.outputs.items) |ref| {
            const ref_name = ref.name orelse continue;
            if (std.mem.eql(u8, ref_name, name)) return ref.output;
        }
        return null;
    }
};

fn outputListener(output: *wl.Output, event: wl.Output.Event, connection: *Connection) void {
    const ref = for (connection.outputs.items) |*candidate| {
        if (candidate.output == output) break candidate;
    } else return;
    switch (event) {
        .geometry => {},
        .mode => |mode| {
            // Only the current mode describes the active resolution.
            if (!mode.flags.current) return;
            ref.mode_width = mode.width;
            ref.mode_height = mode.height;
        },
        .scale => |scale| ref.scale = scale.factor,
        .name => |name| {
            const duped = connection.allocator.dupe(u8, std.mem.span(name.name)) catch return;
            if (ref.name) |old| connection.allocator.free(old);
            ref.name = duped;
        },
        .description => {},
        .done => {
            ref.ready = true;
            connection.notifyOutputsChanged();
        },
    }
}

/// Single-seat registry policy: bind a seat global only before one has been
/// selected. Independent of the seat proxy pointer so takeSeat() can transfer
/// ownership without reopening selection.
fn shouldBindSeat(seat_selected: bool) bool {
    return !seat_selected;
}

test shouldBindSeat {
    try std.testing.expect(shouldBindSeat(false));
    try std.testing.expect(!shouldBindSeat(true));
}

fn connectionSeatListener(_: *wl.Seat, event: wl.Seat.Event, self: *Connection) void {
    switch (event) {
        .capabilities => |caps| {
            self.seat_capabilities = caps.capabilities;
            if (self.seat_capabilities_fn) |handler| {
                handler(self.seat_capabilities_ctx.?, caps.capabilities);
            }
        },
        .name => {},
    }
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, self: *Connection) void {
    switch (event) {
        .global => |global| {
            if (std.mem.orderZ(u8, global.interface, wl.Compositor.interface.name) == .eq) {
                self.compositor = registry.bind(global.name, wl.Compositor, 4) catch return;
            } else if (self.needs.shm and std.mem.orderZ(u8, global.interface, wl.Shm.interface.name) == .eq) {
                self.shm = registry.bind(global.name, wl.Shm, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, xdg.WmBase.interface.name) == .eq) {
                self.wm_base = registry.bind(global.name, xdg.WmBase, @min(global.version, 6)) catch return;
            } else if (std.mem.orderZ(u8, global.interface, zwlr.LayerShellV1.interface.name) == .eq) {
                self.layer_shell = registry.bind(global.name, zwlr.LayerShellV1, @min(global.version, 5)) catch return;
            } else if (std.mem.orderZ(u8, global.interface, wp.Viewporter.interface.name) == .eq) {
                self.viewporter = registry.bind(global.name, wp.Viewporter, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, wp.FractionalScaleManagerV1.interface.name) == .eq) {
                self.fractional_scale_manager = registry.bind(global.name, wp.FractionalScaleManagerV1, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, wp.CursorShapeManagerV1.interface.name) == .eq) {
                self.cursor_shape_manager = registry.bind(global.name, wp.CursorShapeManagerV1, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, wl.DataDeviceManager.interface.name) == .eq) {
                self.data_device_manager = registry.bind(global.name, wl.DataDeviceManager, @min(global.version, 3)) catch return;
            } else if (std.mem.orderZ(u8, global.interface, xdg.ActivationV1.interface.name) == .eq) {
                self.activation = registry.bind(global.name, xdg.ActivationV1, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, zxdg.DecorationManagerV1.interface.name) == .eq) {
                self.decoration_manager = registry.bind(global.name, zxdg.DecorationManagerV1, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, wl.Seat.interface.name) == .eq) {
                // Single-seat: bind only the first seat. seat_selected outlives
                // takeSeat() (which nulls self.seat) so later seats stay unbound
                // and cannot feed capabilities into WaylandInput.
                if (!shouldBindSeat(self.seat_selected)) return;
                // Install the listener before the roundtrip continues so the
                // compositor's initial capabilities event is not dropped.
                const seat = registry.bind(global.name, wl.Seat, @min(global.version, 8)) catch return;
                self.seat = seat;
                self.seat_selected = true;
                seat.setListener(*Connection, connectionSeatListener, self);
            } else if (self.needs.outputs and std.mem.orderZ(u8, global.interface, wl.Output.interface.name) == .eq) {
                const output = registry.bind(global.name, wl.Output, @min(global.version, 4)) catch return;
                self.outputs.append(self.allocator, .{ .global_name = global.name, .output = output }) catch {
                    output.release();
                    return;
                };
                output.setListener(*Connection, outputListener, self);
            }
        },
        .global_remove => |remove| {
            // Outputs are the only globals we track by name; an unplugged
            // monitor must not linger in the list. Surfaces on it receive
            // their own closed/configure events from the compositor.
            for (self.outputs.items, 0..) |output_ref, index| {
                if (output_ref.global_name != remove.name) continue;
                if (output_ref.name) |name| self.allocator.free(name);
                output_ref.output.release();
                _ = self.outputs.orderedRemove(index);
                self.notifyOutputsChanged();
                break;
            }
        },
    }
}

fn releaseOutputs(allocator: std.mem.Allocator, outputs: *std.ArrayList(OutputRef)) void {
    for (outputs.items) |output_ref| {
        if (output_ref.name) |name| allocator.free(name);
        output_ref.output.release();
    }
    outputs.deinit(allocator);
}

const TokenRequest = struct {
    allocator: std.mem.Allocator,
    token: ?[]u8 = null,
    done: bool = false,

    fn listener(_: *xdg.ActivationTokenV1, event: xdg.ActivationTokenV1.Event, self: *TokenRequest) void {
        switch (event) {
            .done => |done| {
                self.token = self.allocator.dupe(u8, std.mem.span(done.token)) catch null;
                self.done = true;
            },
        }
    }
};

/// Requests an xdg-activation token for handing focus to another client.
/// Blocks on roundtrips until the compositor answers. Returns null when
/// the compositor lacks xdg-activation; the caller frees the token.
pub fn requestActivationToken(
    connection: *Connection,
    allocator: std.mem.Allocator,
    seat: ?*wl.Seat,
    serial: ?u32,
    surface: ?*wl.Surface,
    app_id: ?[*:0]const u8,
) !?[]u8 {
    const activation = connection.activation orelse return null;
    const token_object = try activation.getActivationToken();
    defer token_object.destroy();

    var request: TokenRequest = .{ .allocator = allocator };
    token_object.setListener(*TokenRequest, TokenRequest.listener, &request);
    if (seat) |wl_seat| {
        if (serial) |value| token_object.setSerial(value, wl_seat);
    }
    if (surface) |wl_surface| token_object.setSurface(wl_surface);
    if (app_id) |id| token_object.setAppId(id);
    token_object.commit();

    // The done event answers the commit, so one roundtrip normally
    // suffices; the bound guards against a misbehaving compositor.
    var attempts: usize = 0;
    while (!request.done) : (attempts += 1) {
        if (attempts >= 8) return error.ActivationTokenTimeout;
        if (connection.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
    }
    return request.token;
}

pub fn installWmBaseListener(wm_base: ?*xdg.WmBase) void {
    if (wm_base) |base| base.setListener(*xdg.WmBase, wmBaseListener, base);
}

fn wmBaseListener(wm_base: *xdg.WmBase, event: xdg.WmBase.Event, _: *xdg.WmBase) void {
    switch (event) {
        .ping => |ping| wm_base.pong(ping.serial),
    }
}

fn createShellRole(
    surface: *wl.Surface,
    output: ?*wl.Output,
    wm_base: ?*xdg.WmBase,
    layer_shell: ?*zwlr.LayerShellV1,
    options: anytype,
) !ShellRole {
    if (options.layer_shell) |layer_options| {
        const shell = layer_shell orelse return error.NoLayerShell;
        const layer_surface = try shell.getLayerSurface(surface, output, layer(layer_options.layer), layer_options.namespace);
        errdefer layer_surface.destroy();
        layer_surface.setSize(options.width, options.height);
        layer_surface.setAnchor(anchor(layer_options.anchors));
        layer_surface.setExclusiveZone(layer_options.exclusive_zone);
        layer_surface.setMargin(
            layer_options.margin.top,
            layer_options.margin.right,
            layer_options.margin.bottom,
            layer_options.margin.left,
        );
        layer_surface.setKeyboardInteractivity(keyboardInteractivity(layer_options.keyboard_interactivity));
        return .{ .layer = .{ .surface = layer_surface } };
    }

    const base = wm_base orelse return error.NoXdgWmBase;
    const xdg_surface = try base.getXdgSurface(surface);
    errdefer xdg_surface.destroy();
    const toplevel = try xdg_surface.getToplevel();
    errdefer toplevel.destroy();
    toplevel.setAppId(options.app_id);
    toplevel.setTitle(options.title);
    return .{ .xdg = .{ .surface = xdg_surface, .toplevel = toplevel } };
}

/// The positioner anchor is the point on the anchor rect the popup
/// attaches to: the requested edge, adjusted along it by the alignment.
fn popupAnchor(edge: keywork.Widget.PopupPlacement.Edge, alignment: keywork.Widget.Alignment) xdg.Positioner.Anchor {
    return switch (edge) {
        .bottom => switch (alignment) {
            .start => .bottom_left,
            .center => .bottom,
            .end => .bottom_right,
        },
        .top => switch (alignment) {
            .start => .top_left,
            .center => .top,
            .end => .top_right,
        },
        .right => switch (alignment) {
            .start => .top_right,
            .center => .right,
            .end => .bottom_right,
        },
        .left => switch (alignment) {
            .start => .top_left,
            .center => .left,
            .end => .bottom_left,
        },
    };
}

/// Gravity is the direction the popup extends away from the anchor
/// point; the cross-axis component keeps the aligned edges flush.
fn popupGravity(edge: keywork.Widget.PopupPlacement.Edge, alignment: keywork.Widget.Alignment) xdg.Positioner.Gravity {
    return switch (edge) {
        .bottom => switch (alignment) {
            .start => .bottom_right,
            .center => .bottom,
            .end => .bottom_left,
        },
        .top => switch (alignment) {
            .start => .top_right,
            .center => .top,
            .end => .top_left,
        },
        .right => switch (alignment) {
            .start => .bottom_right,
            .center => .right,
            .end => .top_right,
        },
        .left => switch (alignment) {
            .start => .bottom_left,
            .center => .left,
            .end => .top_left,
        },
    };
}

fn popupOffset(edge: keywork.Widget.PopupPlacement.Edge, gap: i32) struct { x: i32, y: i32 } {
    return switch (edge) {
        .bottom => .{ .x = 0, .y = gap },
        .top => .{ .x = 0, .y = -gap },
        .right => .{ .x = gap, .y = 0 },
        .left => .{ .x = -gap, .y = 0 },
    };
}

fn configurePopupPositioner(positioner: *xdg.Positioner, options: PopupOptions) void {
    positioner.setSize(options.width, options.height);
    positioner.setAnchorRect(options.anchor_x, options.anchor_y, @max(options.anchor_width, 1), @max(options.anchor_height, 1));
    positioner.setAnchor(popupAnchor(options.edge, options.alignment));
    positioner.setGravity(popupGravity(options.edge, options.alignment));
    positioner.setConstraintAdjustment(.{ .slide_x = true, .slide_y = true, .flip_x = true, .flip_y = true });
    const offset = popupOffset(options.edge, options.gap);
    positioner.setOffset(offset.x, offset.y);
}

fn layer(value: wayland_options.LayerShellOptions.Layer) zwlr.LayerShellV1.Layer {
    return switch (value) {
        .background => .background,
        .bottom => .bottom,
        .top => .top,
        .overlay => .overlay,
    };
}

fn anchor(value: wayland_options.LayerShellOptions.AnchorSet) zwlr.LayerSurfaceV1.Anchor {
    return .{
        .top = value.top,
        .bottom = value.bottom,
        .left = value.left,
        .right = value.right,
    };
}

fn keyboardInteractivity(value: wayland_options.LayerShellOptions.KeyboardInteractivity) zwlr.LayerSurfaceV1.KeyboardInteractivity {
    return switch (value) {
        .none => .none,
        .exclusive => .exclusive,
        .on_demand => .on_demand,
    };
}

pub const FlushPendingFn = *const fn (*anyopaque) void;
pub const IsClosedFn = *const fn (*anyopaque) bool;

pub fn eventLoopPrepare(display: *wl.Display, ctx: *anyopaque, flush_pending: FlushPendingFn) !event_loop.EventLoop.WaylandPrepare {
    var dispatched_pending = false;
    while (!display.prepareRead()) {
        if (display.dispatchPending() != .SUCCESS) return error.DispatchFailed;
        flush_pending(ctx);
        dispatched_pending = true;
    }

    const events: u32 = switch (display.flush()) {
        .SUCCESS => linux.EPOLL.IN,
        .AGAIN => linux.EPOLL.IN | linux.EPOLL.OUT,
        else => {
            display.cancelRead();
            return error.FlushFailed;
        },
    };
    return .{ .events = events, .dispatched_pending = dispatched_pending };
}

pub fn eventLoopFinish(
    display: *wl.Display,
    ctx: *anyopaque,
    flush_pending: FlushPendingFn,
    is_closed: IsClosedFn,
    events: u32,
) !bool {
    if (events & linux.EPOLL.IN != 0) {
        if (display.readEvents() != .SUCCESS) return error.ReadEventsFailed;
    } else {
        display.cancelRead();
    }

    if (display.dispatchPending() != .SUCCESS) return error.DispatchFailed;
    flush_pending(ctx);
    return !is_closed(ctx);
}

pub fn frameLogicalWidth(frame: keywork.RenderBackend.Frame, fallback: u31) !u31 {
    const value = if (frame.size.width > 0) frame.size.width else @as(f32, @floatFromInt(fallback));
    return positiveU31(value);
}

pub fn frameLogicalHeight(frame: keywork.RenderBackend.Frame, fallback: u31) !u31 {
    const value = if (frame.size.height > 0) frame.size.height else @as(f32, @floatFromInt(fallback));
    return positiveU31(value);
}

pub fn scaledFrameDimension(logical_dimension: u31, scale: f32) !u31 {
    if (!std.math.isFinite(scale) or scale <= 0) return error.InvalidScale;
    const value = @as(f32, @floatFromInt(logical_dimension)) * scale;
    return positiveU31(value);
}

fn positiveU31(value: f32) !u31 {
    if (!std.math.isFinite(value) or value <= 0) return error.InvalidFrameSize;
    const rounded = @ceil(value);
    if (rounded > @as(f32, @floatFromInt(std.math.maxInt(u31)))) return error.InvalidFrameSize;
    return @intFromFloat(rounded);
}
