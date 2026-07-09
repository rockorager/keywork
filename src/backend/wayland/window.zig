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

const log = std.log.scoped(.keywork_wayland_window);

const ShellRole = union(enum) {
    xdg: struct {
        surface: *xdg.Surface,
        toplevel: *xdg.Toplevel,
    },
    layer: struct {
        surface: *zwlr.LayerSurfaceV1,
    },

    pub fn destroy(self: ShellRole) void {
        switch (self) {
            .xdg => |role| {
                role.toplevel.destroy();
                role.surface.destroy();
            },
            .layer => |role| role.surface.destroy(),
        }
    }
};

/// Protocol state shared by every renderer targeting a Wayland surface.
/// Renderer-owned buffers and swapchains deliberately remain outside this
/// type so protocol callbacks cannot depend on a rendering implementation.
pub const Surface = struct {
    surface: *wl.Surface,
    viewport: ?*wp.Viewport,
    fractional_scale: ?*wp.FractionalScaleV1,
    shell_role: ShellRole,
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
        const viewport = if (connection.viewporter) |manager| try manager.getViewport(surface) else null;
        errdefer if (viewport) |surface_viewport| surface_viewport.destroy();
        const fractional_scale = if (connection.fractional_scale_manager) |manager| try manager.getFractionalScale(surface) else null;
        errdefer if (fractional_scale) |surface_scale| surface_scale.destroy();

        return .{
            .surface = surface,
            .viewport = viewport,
            .fractional_scale = fractional_scale,
            .shell_role = shell_role,
            .width = options.width,
            .height = options.height,
        };
    }

    pub fn deinit(self: *Surface) void {
        if (self.frame_callback) |callback| callback.destroy();
        if (self.fractional_scale) |fractional_scale| fractional_scale.destroy();
        if (self.viewport) |viewport| viewport.destroy();
        self.shell_role.destroy();
        self.surface.destroy();
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
        }
        if (self.fractional_scale) |fractional_scale| {
            fractional_scale.setListener(*Surface, fractionalScaleListener, self);
        }
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
};

const GlobalNeeds = struct {
    shm: bool = false,
    outputs: bool = false,
};

/// Owns the Wayland connection and all registry globals. Seats are moved to
/// the input subsystem after its initialization succeeds; every other proxy
/// remains connection-owned for its full lifetime.
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
    seat: ?*wl.Seat = null,
    outputs: std.ArrayList(OutputRef) = .empty,

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
};

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
            } else if (std.mem.orderZ(u8, global.interface, wl.Seat.interface.name) == .eq) {
                self.seat = registry.bind(global.name, wl.Seat, @min(global.version, 8)) catch return;
            } else if (self.needs.outputs and std.mem.orderZ(u8, global.interface, wl.Output.interface.name) == .eq) {
                const output = registry.bind(global.name, wl.Output, @min(global.version, 4)) catch return;
                self.outputs.append(self.allocator, .{ .global_name = global.name, .output = output }) catch {
                    output.release();
                    return;
                };
            }
        },
        .global_remove => {},
    }
}

fn releaseOutputs(allocator: std.mem.Allocator, outputs: *std.ArrayList(OutputRef)) void {
    for (outputs.items) |output_ref| output_ref.output.release();
    outputs.deinit(allocator);
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
