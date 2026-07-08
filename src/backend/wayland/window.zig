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

pub const ShellRole = union(enum) {
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

pub const OutputRef = struct {
    global_name: u32,
    output: *wl.Output,
};

pub const GlobalNeeds = struct {
    shm: bool = false,
    outputs: bool = false,
};

pub const Globals = struct {
    allocator: std.mem.Allocator,
    needs: GlobalNeeds,
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    wm_base: ?*xdg.WmBase = null,
    layer_shell: ?*zwlr.LayerShellV1 = null,
    viewporter: ?*wp.Viewporter = null,
    fractional_scale_manager: ?*wp.FractionalScaleManagerV1 = null,
    cursor_shape_manager: ?*wp.CursorShapeManagerV1 = null,
    seat: ?*wl.Seat = null,
    outputs: std.ArrayList(OutputRef) = .empty,

    pub fn init(allocator: std.mem.Allocator, needs: GlobalNeeds) Globals {
        return .{ .allocator = allocator, .needs = needs };
    }
};

pub fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, globals: *Globals) void {
    switch (event) {
        .global => |global| {
            if (std.mem.orderZ(u8, global.interface, wl.Compositor.interface.name) == .eq) {
                globals.compositor = registry.bind(global.name, wl.Compositor, 4) catch return;
            } else if (globals.needs.shm and std.mem.orderZ(u8, global.interface, wl.Shm.interface.name) == .eq) {
                globals.shm = registry.bind(global.name, wl.Shm, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, xdg.WmBase.interface.name) == .eq) {
                globals.wm_base = registry.bind(global.name, xdg.WmBase, @min(global.version, 6)) catch return;
            } else if (std.mem.orderZ(u8, global.interface, zwlr.LayerShellV1.interface.name) == .eq) {
                globals.layer_shell = registry.bind(global.name, zwlr.LayerShellV1, @min(global.version, 5)) catch return;
            } else if (std.mem.orderZ(u8, global.interface, wp.Viewporter.interface.name) == .eq) {
                globals.viewporter = registry.bind(global.name, wp.Viewporter, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, wp.FractionalScaleManagerV1.interface.name) == .eq) {
                globals.fractional_scale_manager = registry.bind(global.name, wp.FractionalScaleManagerV1, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, wp.CursorShapeManagerV1.interface.name) == .eq) {
                globals.cursor_shape_manager = registry.bind(global.name, wp.CursorShapeManagerV1, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, wl.Seat.interface.name) == .eq) {
                globals.seat = registry.bind(global.name, wl.Seat, @min(global.version, 8)) catch return;
            } else if (globals.needs.outputs and std.mem.orderZ(u8, global.interface, wl.Output.interface.name) == .eq) {
                const output = registry.bind(global.name, wl.Output, @min(global.version, 4)) catch return;
                globals.outputs.append(globals.allocator, .{ .global_name = global.name, .output = output }) catch {
                    output.release();
                    return;
                };
            }
        },
        .global_remove => {},
    }
}

pub fn releaseOutputs(allocator: std.mem.Allocator, outputs: *std.ArrayList(OutputRef)) void {
    for (outputs.items) |output_ref| output_ref.output.release();
    outputs.deinit(allocator);
}

pub fn createShellRole(
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
