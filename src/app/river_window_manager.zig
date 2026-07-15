//! Policy-neutral client for River's external window-management protocol.

const std = @import("std");
const wayland = @import("wayland");

const event_loop = @import("../linux/event_loop.zig");
const policy = @import("river_policy.zig");

const linux = std.os.linux;
const wl = wayland.client.wl;
const river = wayland.client.river;

const log = std.log.scoped(.river_window_manager);

const Phase = enum {
    idle,
    manage,
    render,
};

const Window = struct {
    runtime: *Runtime,
    id: u32,
    object: *river.WindowV1,
    node: *river.NodeV1,
    title: ?[]u8 = null,
    app_id: ?[]u8 = null,
    identifier: ?[]u8 = null,
    parent: ?u32 = null,
    dimensions: ?policy.Dimensions = null,
    dimensions_hint: ?policy.DimensionsHint = null,
    decoration_hint: ?policy.DecorationHint = null,
    unreliable_pid: ?i32 = null,
    presentation_hint: ?policy.PresentationMode = null,
    closed: bool = false,
};

const Output = struct {
    runtime: *Runtime,
    id: u32,
    object: *river.OutputV1,
    layer_shell: ?*river.LayerShellOutputV1 = null,
    wl_output: ?u32 = null,
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    non_exclusive_area: ?policy.Rectangle = null,
    removed: bool = false,
};

const Seat = struct {
    runtime: *Runtime,
    id: u32,
    object: *river.SeatV1,
    xkb_seat: ?*river.XkbBindingsSeatV1 = null,
    layer_shell: ?*river.LayerShellSeatV1 = null,
    wl_seat: ?u32 = null,
    pointer_position: ?policy.Point = null,
    modifiers: ?u32 = null,
    layer_shell_focus: ?policy.LayerShellFocus = null,
    bindings: std.ArrayList(*Binding) = .empty,
    pointer_bindings: std.ArrayList(*PointerBinding) = .empty,
    removed: bool = false,
};

const Binding = struct {
    runtime: *Runtime,
    seat: *Seat,
    object: *river.XkbBindingV1,
    id: []u8,
    keysym: u32,
    modifiers: u32,
    layout: ?u32,
};

const PointerBinding = struct {
    runtime: *Runtime,
    seat: *Seat,
    object: *river.PointerBindingV1,
    id: []u8,
    button: u32,
    modifiers: u32,
};

const InputInvocation = union(enum) {
    xkb: struct { binding: *Binding, event: policy.BindingEvent },
    pointer: struct { binding: *PointerBinding, event: policy.BindingEvent },
};

const Runtime = struct {
    allocator: std.mem.Allocator,
    host: *policy.Host,
    display: *wl.Display,
    registry: *wl.Registry,
    manager: ?*river.WindowManagerV1 = null,
    xkb_bindings: ?*river.XkbBindingsV1 = null,
    layer_shell: ?*river.LayerShellV1 = null,
    manager_global: ?u32 = null,
    xkb_global: ?u32 = null,
    layer_shell_global: ?u32 = null,
    windows: std.ArrayList(*Window) = .empty,
    outputs: std.ArrayList(*Output) = .empty,
    seats: std.ArrayList(*Seat) = .empty,
    events: std.ArrayList(policy.Event) = .empty,
    input_invocations: std.ArrayList(InputInvocation) = .empty,
    next_id: u32 = 1,
    phase: Phase = .idle,
    session_locked: bool = false,
    unavailable: bool = false,
    finished: bool = false,
    exit_requested: bool = false,
    fatal: bool = false,

    fn init(self: *Runtime, allocator: std.mem.Allocator, host: *policy.Host) !void {
        const display = try wl.Display.connect(null);
        errdefer display.disconnect();
        const registry = try display.getRegistry();
        errdefer registry.destroy();

        self.* = .{
            .allocator = allocator,
            .host = host,
            .display = display,
            .registry = registry,
        };
        registry.setListener(*Runtime, registryListener, self);
        try host.bindInvalidator(self, Runtime.invalidate);
        errdefer host.unbindInvalidator();
        if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
        if (self.manager == null) return error.NoRiverWindowManager;
        if (self.xkb_bindings == null) return error.NoRiverXkbBindings;
        if (self.fatal) return error.RiverInitializationFailed;
    }

    fn deinit(self: *Runtime) void {
        self.destroyChildren();
        if (self.layer_shell) |layer_shell| layer_shell.destroy();
        if (self.manager) |manager| manager.destroy();
        if (self.xkb_bindings) |bindings| bindings.destroy();
        self.registry.destroy();
        self.display.disconnect();
        self.input_invocations.deinit(self.allocator);
        self.events.deinit(self.allocator);
    }

    fn destroyChildren(self: *Runtime) void {
        for (self.seats.items) |seat| self.destroySeat(seat, true);
        self.seats.deinit(self.allocator);
        for (self.windows.items) |window| self.destroyWindow(window, true);
        self.windows.deinit(self.allocator);
        for (self.outputs.items) |output| {
            if (output.layer_shell) |layer_shell| layer_shell.destroy();
            output.object.destroy();
            self.allocator.destroy(output);
        }
        self.outputs.deinit(self.allocator);
    }

    fn allocateId(self: *Runtime) !u32 {
        if (self.next_id == std.math.maxInt(u32)) return error.RiverObjectIdExhausted;
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    fn recordEvent(self: *Runtime, event: policy.Event) void {
        self.events.append(self.allocator, event) catch {
            self.fatal = true;
        };
    }

    fn stop(self: *Runtime) void {
        if (self.unavailable or self.finished) return;
        const manager = self.manager orelse return;
        manager.stop();
        while (!self.finished) {
            if (self.display.dispatch() != .SUCCESS) return;
        }
    }

    fn shouldStop(self: *const Runtime) bool {
        return self.unavailable or self.finished or self.fatal;
    }

    fn invalidate(ctx: *anyopaque) anyerror!void {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        if (!self.shouldStop()) {
            if (self.manager) |manager| manager.manageDirty();
        }
    }

    fn eventLoopPrepare(ctx: *anyopaque) !event_loop.EventLoop.WaylandPrepare {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        var dispatched_pending = false;
        while (!self.display.prepareRead()) {
            if (self.display.dispatchPending() != .SUCCESS) return error.DispatchFailed;
            dispatched_pending = true;
        }

        const events: u32 = switch (self.display.flush()) {
            .SUCCESS => linux.EPOLL.IN,
            .AGAIN => linux.EPOLL.IN | linux.EPOLL.OUT,
            else => {
                self.display.cancelRead();
                return error.FlushFailed;
            },
        };
        return .{ .events = events, .dispatched_pending = dispatched_pending };
    }

    fn eventLoopFinish(ctx: *anyopaque, events: u32) !bool {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        if (events & linux.EPOLL.IN != 0) {
            if (self.display.readEvents() != .SUCCESS) {
                if (self.exit_requested) return false;
                return error.ReadEventsFailed;
            }
        } else {
            self.display.cancelRead();
        }
        if (self.display.dispatchPending() != .SUCCESS) {
            if (self.exit_requested) return false;
            return error.DispatchFailed;
        }
        return !self.shouldStop();
    }

    fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, self: *Runtime) void {
        switch (event) {
            .global => |global| {
                const interface = std.mem.span(global.interface);
                if (std.mem.eql(u8, interface, std.mem.span(river.WindowManagerV1.interface.name))) {
                    const manager = registry.bind(
                        global.name,
                        river.WindowManagerV1,
                        @min(global.version, river.WindowManagerV1.generated_version),
                    ) catch {
                        self.fatal = true;
                        return;
                    };
                    self.manager = manager;
                    self.manager_global = global.name;
                    manager.setListener(*Runtime, managerListener, self);
                } else if (std.mem.eql(u8, interface, std.mem.span(river.XkbBindingsV1.interface.name))) {
                    self.xkb_bindings = registry.bind(
                        global.name,
                        river.XkbBindingsV1,
                        @min(global.version, river.XkbBindingsV1.generated_version),
                    ) catch {
                        self.fatal = true;
                        return;
                    };
                    self.xkb_global = global.name;
                } else if (std.mem.eql(u8, interface, std.mem.span(river.LayerShellV1.interface.name))) {
                    self.layer_shell = registry.bind(
                        global.name,
                        river.LayerShellV1,
                        @min(global.version, river.LayerShellV1.generated_version),
                    ) catch {
                        self.fatal = true;
                        return;
                    };
                    self.layer_shell_global = global.name;
                    self.attachLayerShellObjects() catch {
                        self.fatal = true;
                    };
                }
            },
            .global_remove => |removed| {
                if (self.manager_global == removed.name or self.xkb_global == removed.name or
                    self.layer_shell_global == removed.name) self.fatal = true;
            },
        }
    }

    fn managerListener(_: *river.WindowManagerV1, event: river.WindowManagerV1.Event, self: *Runtime) void {
        switch (event) {
            .unavailable => self.unavailable = true,
            .finished => self.finished = true,
            .manage_start => self.manage(),
            .render_start => self.render(),
            .session_locked => {
                self.session_locked = true;
                self.recordEvent(.session_locked);
            },
            .session_unlocked => {
                self.session_locked = false;
                self.recordEvent(.session_unlocked);
            },
            .window => |new| self.addWindow(new.id) catch {
                self.fatal = true;
            },
            .output => |new| self.addOutput(new.id) catch {
                self.fatal = true;
            },
            .seat => |new| self.addSeat(new.id) catch {
                self.fatal = true;
            },
        }
    }

    fn addWindow(self: *Runtime, object: *river.WindowV1) !void {
        const window = try self.allocator.create(Window);
        errdefer self.allocator.destroy(window);
        const node = try object.getNode();
        window.* = .{
            .runtime = self,
            .id = try self.allocateId(),
            .object = object,
            .node = node,
        };
        object.setListener(*Window, windowListener, window);
        try self.windows.append(self.allocator, window);
        self.recordEvent(.{ .window_added = window.id });
    }

    fn addOutput(self: *Runtime, object: *river.OutputV1) !void {
        const output = try self.allocator.create(Output);
        errdefer self.allocator.destroy(output);
        output.* = .{ .runtime = self, .id = try self.allocateId(), .object = object };
        object.setListener(*Output, outputListener, output);
        try self.attachLayerShellOutput(output);
        try self.outputs.append(self.allocator, output);
        self.recordEvent(.{ .output_added = output.id });
    }

    fn addSeat(self: *Runtime, object: *river.SeatV1) !void {
        const seat = try self.allocator.create(Seat);
        errdefer self.allocator.destroy(seat);
        seat.* = .{ .runtime = self, .id = try self.allocateId(), .object = object };
        object.setListener(*Seat, seatListener, seat);
        const xkb_bindings = self.xkb_bindings orelse return error.NoRiverXkbBindings;
        if (xkb_bindings.getVersion() >= river.XkbBindingsV1.get_seat_since_version) {
            seat.xkb_seat = try xkb_bindings.getSeat(object);
            seat.xkb_seat.?.setListener(*Seat, xkbSeatListener, seat);
        }
        try self.attachLayerShellSeat(seat);
        try self.seats.append(self.allocator, seat);
        self.recordEvent(.{ .seat_added = seat.id });
    }

    fn attachLayerShellObjects(self: *Runtime) !void {
        for (self.outputs.items) |output| try self.attachLayerShellOutput(output);
        for (self.seats.items) |seat| try self.attachLayerShellSeat(seat);
    }

    fn attachLayerShellOutput(self: *Runtime, output: *Output) !void {
        if (output.layer_shell != null) return;
        const layer_shell = self.layer_shell orelse return;
        output.layer_shell = try layer_shell.getOutput(output.object);
        output.layer_shell.?.setListener(*Output, layerShellOutputListener, output);
    }

    fn attachLayerShellSeat(self: *Runtime, seat: *Seat) !void {
        if (seat.layer_shell != null) return;
        const layer_shell = self.layer_shell orelse return;
        seat.layer_shell = try layer_shell.getSeat(seat.object);
        seat.layer_shell.?.setListener(*Seat, layerShellSeatListener, seat);
    }

    fn manage(self: *Runtime) void {
        const manager = self.manager orelse return;
        if (self.phase != .idle) {
            self.fatal = true;
            return;
        }
        self.phase = .manage;
        defer {
            self.events.clearRetainingCapacity();
            manager.manageFinish();
            self.phase = .idle;
        }
        if (self.fatal) return;

        self.invokeBindings();
        self.reconcileBindings() catch |err| {
            // A failed reload leaves the last successfully loaded root committed.
            log.err("failed to refresh River key bindings; keeping the previous bindings: {}", .{err});
        };

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const context = self.buildContext(allocator, true) catch {
            self.fatal = true;
            return;
        };
        const commands = self.host.manage(allocator, context) catch |err| {
            log.err("River manage callback failed; submitting no changes: {}", .{err});
            self.removeClosedObjects();
            return;
        };
        self.validateManageCommands(commands) catch |err| {
            log.err("River manage commands are invalid; submitting no changes: {}", .{err});
            self.removeClosedObjects();
            return;
        };
        self.applyManageCommands(commands);
        self.removeClosedObjects();
    }

    fn render(self: *Runtime) void {
        const manager = self.manager orelse return;
        if (self.phase != .idle) {
            self.fatal = true;
            return;
        }
        self.phase = .render;
        defer {
            manager.renderFinish();
            self.phase = .idle;
        }
        if (self.fatal) return;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const context = self.buildContext(allocator, false) catch {
            self.fatal = true;
            return;
        };
        const commands = self.host.render(allocator, context) catch |err| {
            log.err("River render callback failed; submitting no changes: {}", .{err});
            return;
        };
        self.validateRenderCommands(commands) catch |err| {
            log.err("River render commands are invalid; submitting no changes: {}", .{err});
            return;
        };
        self.applyRenderCommands(commands);
    }

    fn buildContext(self: *Runtime, allocator: std.mem.Allocator, include_events: bool) !policy.Context {
        var window_count: usize = 0;
        for (self.windows.items) |window| if (!window.closed) {
            window_count += 1;
        };
        const windows = try allocator.alloc(policy.Window, window_count);
        var window_index: usize = 0;
        for (self.windows.items) |window| {
            if (window.closed) continue;
            windows[window_index] = .{
                .id = window.id,
                .title = window.title,
                .app_id = window.app_id,
                .identifier = window.identifier,
                .parent = window.parent,
                .dimensions = window.dimensions,
                .dimensions_hint = window.dimensions_hint,
                .decoration_hint = window.decoration_hint,
                .unreliable_pid = window.unreliable_pid,
                .presentation_hint = window.presentation_hint,
            };
            window_index += 1;
        }

        var output_count: usize = 0;
        for (self.outputs.items) |output| if (!output.removed) {
            output_count += 1;
        };
        const outputs = try allocator.alloc(policy.Output, output_count);
        var output_index: usize = 0;
        for (self.outputs.items) |output| {
            if (output.removed) continue;
            outputs[output_index] = .{
                .id = output.id,
                .wl_output = output.wl_output,
                .x = output.x,
                .y = output.y,
                .width = output.width,
                .height = output.height,
                .non_exclusive_area = output.non_exclusive_area,
            };
            output_index += 1;
        }

        var seat_count: usize = 0;
        for (self.seats.items) |seat| if (!seat.removed) {
            seat_count += 1;
        };
        const seats = try allocator.alloc(policy.Seat, seat_count);
        var seat_index: usize = 0;
        for (self.seats.items) |seat| {
            if (seat.removed) continue;
            seats[seat_index] = .{
                .id = seat.id,
                .wl_seat = seat.wl_seat,
                .pointer_position = seat.pointer_position,
                .modifiers = seat.modifiers,
                .layer_shell_focus = seat.layer_shell_focus,
            };
            seat_index += 1;
        }

        return .{
            .windows = windows,
            .outputs = outputs,
            .seats = seats,
            .events = if (include_events) self.events.items else &.{},
            .session_locked = self.session_locked,
            .window_management_version = self.manager.?.getVersion(),
            .xkb_bindings_version = self.xkb_bindings.?.getVersion(),
            .layer_shell_version = if (self.layer_shell) |layer_shell| layer_shell.getVersion() else 0,
        };
    }

    fn validateManageCommands(self: *Runtime, commands: []const policy.ManageCommand) !void {
        for (commands) |command| switch (command) {
            .close => |value| _ = try self.requireWindow(value.window),
            .propose_dimensions => |value| {
                _ = try self.requireWindow(value.window);
                if (value.width < 0 or value.height < 0) return error.InvalidDimensions;
            },
            .use_csd,
            .use_ssd,
            .inform_resize_start,
            .inform_resize_end,
            .inform_maximized,
            .inform_unmaximized,
            .inform_fullscreen,
            .inform_not_fullscreen,
            .exit_fullscreen,
            => |value| _ = try self.requireWindow(value.window),
            .set_tiled => |value| _ = try self.requireWindow(value.window),
            .set_capabilities => |value| _ = try self.requireWindow(value.window),
            .fullscreen => |value| {
                _ = try self.requireWindow(value.window);
                _ = try self.requireOutput(value.output);
            },
            .set_dimension_bounds => |value| {
                const window = try self.requireWindow(value.window);
                if (window.object.getVersion() < river.WindowV1.set_dimension_bounds_since_version)
                    return error.UnsupportedRiverProtocolVersion;
                if (value.max_width < 0 or value.max_height < 0) return error.InvalidDimensions;
            },
            .focus_window => |value| {
                _ = try self.requireSeat(value.seat);
                _ = try self.requireWindow(value.window);
            },
            .clear_focus,
            .op_start_pointer,
            .op_end,
            => |value| _ = try self.requireSeat(value.seat),
            .pointer_warp => |value| {
                const seat = try self.requireSeat(value.seat);
                if (seat.object.getVersion() < river.SeatV1.pointer_warp_since_version)
                    return error.UnsupportedRiverProtocolVersion;
            },
            .set_xcursor_theme => |value| {
                const seat = try self.requireSeat(value.seat);
                if (seat.object.getVersion() < river.SeatV1.set_xcursor_theme_since_version)
                    return error.UnsupportedRiverProtocolVersion;
            },
            .ensure_next_key_eaten, .cancel_ensure_next_key_eaten => |value| {
                const seat = try self.requireSeat(value.seat);
                const xkb_seat = seat.xkb_seat orelse return error.UnsupportedRiverProtocolVersion;
                if (xkb_seat.getVersion() < river.XkbBindingsSeatV1.ensure_next_key_eaten_since_version)
                    return error.UnsupportedRiverProtocolVersion;
            },
            .modifiers_watch => |value| {
                const seat = try self.requireSeat(value.seat);
                const xkb_seat = seat.xkb_seat orelse return error.UnsupportedRiverProtocolVersion;
                if (xkb_seat.getVersion() < river.XkbBindingsSeatV1.modifiers_watch_since_version)
                    return error.UnsupportedRiverProtocolVersion;
            },
            .set_layer_shell_default => |value| {
                const output = try self.requireOutput(value.output);
                if (output.layer_shell == null) return error.UnsupportedRiverProtocolVersion;
            },
            .exit_session => {
                const manager = self.manager orelse return error.NoRiverWindowManager;
                if (manager.getVersion() < river.WindowManagerV1.exit_session_since_version)
                    return error.UnsupportedRiverProtocolVersion;
            },
        };
    }

    fn applyManageCommands(self: *Runtime, commands: []const policy.ManageCommand) void {
        for (commands) |command| switch (command) {
            .close => |value| self.findWindowId(value.window).?.object.close(),
            .propose_dimensions => |value| self.findWindowId(value.window).?.object.proposeDimensions(value.width, value.height),
            .use_csd => |value| self.findWindowId(value.window).?.object.useCsd(),
            .use_ssd => |value| self.findWindowId(value.window).?.object.useSsd(),
            .set_tiled => |value| self.findWindowId(value.window).?.object.setTiled(riverEdges(value.edges)),
            .inform_resize_start => |value| self.findWindowId(value.window).?.object.informResizeStart(),
            .inform_resize_end => |value| self.findWindowId(value.window).?.object.informResizeEnd(),
            .set_capabilities => |value| self.findWindowId(value.window).?.object.setCapabilities(riverCapabilities(value.capabilities)),
            .inform_maximized => |value| self.findWindowId(value.window).?.object.informMaximized(),
            .inform_unmaximized => |value| self.findWindowId(value.window).?.object.informUnmaximized(),
            .inform_fullscreen => |value| self.findWindowId(value.window).?.object.informFullscreen(),
            .inform_not_fullscreen => |value| self.findWindowId(value.window).?.object.informNotFullscreen(),
            .fullscreen => |value| self.findWindowId(value.window).?.object.fullscreen(self.findOutputId(value.output).?.object),
            .exit_fullscreen => |value| self.findWindowId(value.window).?.object.exitFullscreen(),
            .set_dimension_bounds => |value| self.findWindowId(value.window).?.object.setDimensionBounds(value.max_width, value.max_height),
            .focus_window => |value| self.findSeatId(value.seat).?.object.focusWindow(self.findWindowId(value.window).?.object),
            .clear_focus => |value| self.findSeatId(value.seat).?.object.clearFocus(),
            .op_start_pointer => |value| self.findSeatId(value.seat).?.object.opStartPointer(),
            .op_end => |value| self.findSeatId(value.seat).?.object.opEnd(),
            .pointer_warp => |value| self.findSeatId(value.seat).?.object.pointerWarp(value.x, value.y),
            .set_xcursor_theme => |value| self.findSeatId(value.seat).?.object.setXcursorTheme(value.name, value.size),
            .ensure_next_key_eaten => |value| self.findSeatId(value.seat).?.xkb_seat.?.ensureNextKeyEaten(),
            .cancel_ensure_next_key_eaten => |value| self.findSeatId(value.seat).?.xkb_seat.?.cancelEnsureNextKeyEaten(),
            .modifiers_watch => |value| self.findSeatId(value.seat).?.xkb_seat.?.modifiersWatch(@bitCast(value.modifiers)),
            .set_layer_shell_default => |value| self.findOutputId(value.output).?.layer_shell.?.setDefault(),
            .exit_session => {
                self.exit_requested = true;
                self.manager.?.exitSession();
            },
        };
    }

    fn validateRenderCommands(self: *Runtime, commands: []const policy.RenderCommand) !void {
        for (commands) |command| switch (command) {
            .hide,
            .show,
            .place_top,
            .place_bottom,
            => |value| _ = try self.requireWindow(value.window),
            .set_position => |value| _ = try self.requireWindow(value.window),
            .set_borders => |value| {
                _ = try self.requireWindow(value.window);
                if (value.width < 0) return error.InvalidBorder;
            },
            .place_above, .place_below => |value| {
                _ = try self.requireWindow(value.window);
                _ = try self.requireWindow(value.other);
            },
            .set_clip_box => |value| {
                const window = try self.requireWindow(value.window);
                if (window.object.getVersion() < river.WindowV1.set_clip_box_since_version)
                    return error.UnsupportedRiverProtocolVersion;
                if (value.width < 0 or value.height < 0) return error.InvalidClipBox;
            },
            .set_content_clip_box => |value| {
                const window = try self.requireWindow(value.window);
                if (window.object.getVersion() < river.WindowV1.set_content_clip_box_since_version)
                    return error.UnsupportedRiverProtocolVersion;
                if (value.width < 0 or value.height < 0) return error.InvalidClipBox;
            },
            .set_presentation_mode => |value| {
                const output = try self.requireOutput(value.output);
                if (output.object.getVersion() < river.OutputV1.set_presentation_mode_since_version)
                    return error.UnsupportedRiverProtocolVersion;
            },
        };
    }

    fn applyRenderCommands(self: *Runtime, commands: []const policy.RenderCommand) void {
        for (commands) |command| switch (command) {
            .hide => |value| self.findWindowId(value.window).?.object.hide(),
            .show => |value| self.findWindowId(value.window).?.object.show(),
            .set_borders => |value| {
                const color = value.color;
                self.findWindowId(value.window).?.object.setBorders(
                    riverEdges(value.edges),
                    value.width,
                    color.r,
                    color.g,
                    color.b,
                    color.a,
                );
            },
            .set_position => |value| self.findWindowId(value.window).?.node.setPosition(value.x, value.y),
            .place_top => |value| self.findWindowId(value.window).?.node.placeTop(),
            .place_bottom => |value| self.findWindowId(value.window).?.node.placeBottom(),
            .place_above => |value| self.findWindowId(value.window).?.node.placeAbove(self.findWindowId(value.other).?.node),
            .place_below => |value| self.findWindowId(value.window).?.node.placeBelow(self.findWindowId(value.other).?.node),
            .set_clip_box => |value| self.findWindowId(value.window).?.object.setClipBox(value.x, value.y, value.width, value.height),
            .set_content_clip_box => |value| self.findWindowId(value.window).?.object.setContentClipBox(value.x, value.y, value.width, value.height),
            .set_presentation_mode => |value| self.findOutputId(value.output).?.object.setPresentationMode(switch (value.mode) {
                .vsync => .vsync,
                .async => .async,
            }),
        };
    }

    fn removeClosedObjects(self: *Runtime) void {
        var seat_index: usize = 0;
        while (seat_index < self.seats.items.len) {
            const seat = self.seats.items[seat_index];
            if (!seat.removed) {
                seat_index += 1;
                continue;
            }
            _ = self.seats.orderedRemove(seat_index);
            self.destroySeat(seat, true);
        }

        var window_index: usize = 0;
        while (window_index < self.windows.items.len) {
            const window = self.windows.items[window_index];
            if (!window.closed) {
                window_index += 1;
                continue;
            }
            for (self.windows.items) |child| {
                if (child.parent == window.id) child.parent = null;
            }
            _ = self.windows.orderedRemove(window_index);
            self.destroyWindow(window, true);
        }

        var output_index: usize = 0;
        while (output_index < self.outputs.items.len) {
            const output = self.outputs.items[output_index];
            if (!output.removed) {
                output_index += 1;
                continue;
            }
            _ = self.outputs.orderedRemove(output_index);
            if (output.layer_shell) |layer_shell| layer_shell.destroy();
            output.object.destroy();
            self.allocator.destroy(output);
        }
    }

    fn destroyWindow(self: *Runtime, window: *Window, destroy_object: bool) void {
        if (window.title) |title| self.allocator.free(title);
        if (window.app_id) |app_id| self.allocator.free(app_id);
        if (window.identifier) |identifier| self.allocator.free(identifier);
        if (destroy_object) {
            window.node.destroy();
            window.object.destroy();
        }
        self.allocator.destroy(window);
    }

    fn destroySeat(self: *Runtime, seat: *Seat, destroy_object: bool) void {
        for (seat.bindings.items) |binding| self.destroyBinding(binding, destroy_object);
        seat.bindings.deinit(self.allocator);
        for (seat.pointer_bindings.items) |binding| self.destroyPointerBinding(binding, destroy_object);
        seat.pointer_bindings.deinit(self.allocator);
        if (destroy_object) {
            if (seat.layer_shell) |layer_shell| layer_shell.destroy();
            if (seat.xkb_seat) |xkb_seat| xkb_seat.destroy();
            seat.object.destroy();
        }
        self.allocator.destroy(seat);
    }

    fn destroyBinding(self: *Runtime, binding: *Binding, destroy_object: bool) void {
        if (destroy_object) binding.object.destroy();
        self.allocator.free(binding.id);
        self.allocator.destroy(binding);
    }

    fn destroyPointerBinding(self: *Runtime, binding: *PointerBinding, destroy_object: bool) void {
        if (destroy_object) binding.object.destroy();
        self.allocator.free(binding.id);
        self.allocator.destroy(binding);
    }

    fn invokeBindings(self: *Runtime) void {
        defer self.input_invocations.clearRetainingCapacity();
        for (self.input_invocations.items) |invocation| switch (invocation) {
            .xkb => |value| self.host.invokeBinding(value.binding.id, value.event, value.binding.seat.id) catch |err| {
                log.err("River binding '{s}' callback failed: {}", .{ value.binding.id, err });
            },
            .pointer => |value| self.host.invokePointerBinding(value.binding.id, value.event, value.binding.seat.id) catch |err| {
                log.err("River pointer binding '{s}' callback failed: {}", .{ value.binding.id, err });
            },
        };
    }

    fn reconcileBindings(self: *Runtime) !void {
        try self.host.refresh();
        const declarations = try self.host.bindings(self.allocator);
        defer policy.freeBindings(self.allocator, declarations);
        const pointer_declarations = try self.host.pointerBindings(self.allocator);
        defer policy.freePointerBindings(self.allocator, pointer_declarations);
        for (self.seats.items) |seat| {
            if (seat.removed) continue;
            try self.reconcileSeatBindings(seat, declarations);
            try self.reconcilePointerBindings(seat, pointer_declarations);
        }
    }

    fn reconcileSeatBindings(self: *Runtime, seat: *Seat, declarations: []const policy.Binding) !void {
        var index: usize = 0;
        while (index < seat.bindings.items.len) {
            const binding = seat.bindings.items[index];
            const declaration = findBindingDeclaration(declarations, binding.id);
            if (declaration != null and declaration.?.keysym == binding.keysym and
                declaration.?.modifiers == binding.modifiers and declaration.?.layout == binding.layout)
            {
                index += 1;
                continue;
            }
            _ = seat.bindings.orderedRemove(index);
            self.destroyBinding(binding, true);
        }

        for (declarations) |declaration| {
            if (findBinding(seat.bindings.items, declaration.id) != null) continue;
            try self.addBinding(seat, declaration);
        }
    }

    fn addBinding(self: *Runtime, seat: *Seat, declaration: policy.Binding) !void {
        const xkb_bindings = self.xkb_bindings orelse return error.NoRiverXkbBindings;
        const modifiers: river.SeatV1.Modifiers = @bitCast(declaration.modifiers);
        const object = try xkb_bindings.getXkbBinding(seat.object, declaration.keysym, modifiers);
        errdefer object.destroy();
        const binding = try self.allocator.create(Binding);
        errdefer self.allocator.destroy(binding);
        const id = try self.allocator.dupe(u8, declaration.id);
        errdefer self.allocator.free(id);
        binding.* = .{
            .runtime = self,
            .seat = seat,
            .object = object,
            .id = id,
            .keysym = declaration.keysym,
            .modifiers = declaration.modifiers,
            .layout = declaration.layout,
        };
        object.setListener(*Binding, bindingListener, binding);
        try seat.bindings.append(self.allocator, binding);
        if (declaration.layout) |layout| object.setLayoutOverride(layout);
        object.enable();
    }

    fn reconcilePointerBindings(self: *Runtime, seat: *Seat, declarations: []const policy.PointerBinding) !void {
        var index: usize = 0;
        while (index < seat.pointer_bindings.items.len) {
            const binding = seat.pointer_bindings.items[index];
            const declaration = findPointerBindingDeclaration(declarations, binding.id);
            if (declaration != null and declaration.?.button == binding.button and
                declaration.?.modifiers == binding.modifiers)
            {
                index += 1;
                continue;
            }
            _ = seat.pointer_bindings.orderedRemove(index);
            self.destroyPointerBinding(binding, true);
        }

        for (declarations) |declaration| {
            if (findPointerBinding(seat.pointer_bindings.items, declaration.id) != null) continue;
            try self.addPointerBinding(seat, declaration);
        }
    }

    fn addPointerBinding(self: *Runtime, seat: *Seat, declaration: policy.PointerBinding) !void {
        const modifiers: river.SeatV1.Modifiers = @bitCast(declaration.modifiers);
        const object = try seat.object.getPointerBinding(declaration.button, modifiers);
        errdefer object.destroy();
        const binding = try self.allocator.create(PointerBinding);
        errdefer self.allocator.destroy(binding);
        const id = try self.allocator.dupe(u8, declaration.id);
        errdefer self.allocator.free(id);
        binding.* = .{
            .runtime = self,
            .seat = seat,
            .object = object,
            .id = id,
            .button = declaration.button,
            .modifiers = declaration.modifiers,
        };
        object.setListener(*PointerBinding, pointerBindingListener, binding);
        try seat.pointer_bindings.append(self.allocator, binding);
        object.enable();
    }

    fn requireWindow(self: *Runtime, id: u32) !*Window {
        const window = self.findWindowId(id) orelse return error.UnknownWindow;
        if (window.closed) return error.ClosedWindow;
        return window;
    }

    fn requireOutput(self: *Runtime, id: u32) !*Output {
        const output = self.findOutputId(id) orelse return error.UnknownOutput;
        if (output.removed) return error.RemovedOutput;
        return output;
    }

    fn requireSeat(self: *Runtime, id: u32) !*Seat {
        const seat = self.findSeatId(id) orelse return error.UnknownSeat;
        if (seat.removed) return error.RemovedSeat;
        return seat;
    }

    fn findWindow(self: *Runtime, object: *river.WindowV1) ?*Window {
        for (self.windows.items) |window| if (window.object == object) return window;
        return null;
    }

    fn findWindowId(self: *Runtime, id: u32) ?*Window {
        for (self.windows.items) |window| if (window.id == id) return window;
        return null;
    }

    fn findOutput(self: *Runtime, object: *river.OutputV1) ?*Output {
        for (self.outputs.items) |output| if (output.object == object) return output;
        return null;
    }

    fn findOutputId(self: *Runtime, id: u32) ?*Output {
        for (self.outputs.items) |output| if (output.id == id) return output;
        return null;
    }

    fn findSeat(self: *Runtime, object: *river.SeatV1) ?*Seat {
        for (self.seats.items) |seat| if (seat.object == object) return seat;
        return null;
    }

    fn findSeatId(self: *Runtime, id: u32) ?*Seat {
        for (self.seats.items) |seat| if (seat.id == id) return seat;
        return null;
    }

    fn windowListener(_: *river.WindowV1, event: river.WindowV1.Event, window: *Window) void {
        const runtime = window.runtime;
        switch (event) {
            .closed => {
                window.closed = true;
                runtime.recordEvent(.{ .window_closed = window.id });
            },
            .dimensions_hint => |hint| window.dimensions_hint = .{
                .min_width = hint.min_width,
                .min_height = hint.min_height,
                .max_width = hint.max_width,
                .max_height = hint.max_height,
            },
            .dimensions => |dimensions| window.dimensions = .{
                .width = dimensions.width,
                .height = dimensions.height,
            },
            .app_id => |app_id| replaceOptionalString(runtime.allocator, &window.app_id, app_id.app_id) catch {
                runtime.fatal = true;
            },
            .title => |title| replaceOptionalString(runtime.allocator, &window.title, title.title) catch {
                runtime.fatal = true;
            },
            .parent => |parent| window.parent = if (parent.parent) |object|
                if (runtime.findWindow(object)) |value| value.id else null
            else
                null,
            .decoration_hint => |hint| window.decoration_hint = switch (hint.hint) {
                .only_supports_csd => .only_supports_csd,
                .prefers_csd => .prefers_csd,
                .prefers_ssd => .prefers_ssd,
                .no_preference => .no_preference,
                else => null,
            },
            .pointer_move_requested => |request| {
                const object = request.seat orelse return;
                const seat = runtime.findSeat(object) orelse return;
                runtime.recordEvent(.{ .pointer_move_requested = .{ .window = window.id, .seat = seat.id } });
            },
            .pointer_resize_requested => |request| {
                const object = request.seat orelse return;
                const seat = runtime.findSeat(object) orelse return;
                runtime.recordEvent(.{ .pointer_resize_requested = .{
                    .window = window.id,
                    .seat = seat.id,
                    .edges = @bitCast(request.edges),
                } });
            },
            .show_window_menu_requested => |request| runtime.recordEvent(.{ .show_window_menu_requested = .{
                .window = window.id,
                .x = request.x,
                .y = request.y,
            } }),
            .maximize_requested => runtime.recordEvent(.{ .maximize_requested = window.id }),
            .unmaximize_requested => runtime.recordEvent(.{ .unmaximize_requested = window.id }),
            .fullscreen_requested => |request| runtime.recordEvent(.{ .fullscreen_requested = .{
                .window = window.id,
                .output = if (request.output) |object| if (runtime.findOutput(object)) |value| value.id else null else null,
            } }),
            .exit_fullscreen_requested => runtime.recordEvent(.{ .exit_fullscreen_requested = window.id }),
            .minimize_requested => runtime.recordEvent(.{ .minimize_requested = window.id }),
            .unreliable_pid => |pid| window.unreliable_pid = pid.unreliable_pid,
            .presentation_hint => |hint| window.presentation_hint = switch (hint.hint) {
                .vsync => .vsync,
                .async => .async,
                else => null,
            },
            .identifier => |identifier| replaceString(runtime.allocator, &window.identifier, identifier.identifier) catch {
                runtime.fatal = true;
            },
        }
    }

    fn outputListener(_: *river.OutputV1, event: river.OutputV1.Event, output: *Output) void {
        switch (event) {
            .removed => {
                output.removed = true;
                output.runtime.recordEvent(.{ .output_removed = output.id });
            },
            .wl_output => |value| output.wl_output = value.name,
            .position => |position| {
                output.x = position.x;
                output.y = position.y;
            },
            .dimensions => |dimensions| {
                output.width = dimensions.width;
                output.height = dimensions.height;
            },
        }
    }

    fn layerShellOutputListener(
        _: *river.LayerShellOutputV1,
        event: river.LayerShellOutputV1.Event,
        output: *Output,
    ) void {
        switch (event) {
            .non_exclusive_area => |area| {
                output.non_exclusive_area = .{
                    .x = area.x,
                    .y = area.y,
                    .width = area.width,
                    .height = area.height,
                };
                output.runtime.recordEvent(.{ .layer_shell_non_exclusive_area = .{
                    .output = output.id,
                    .area = output.non_exclusive_area.?,
                } });
            },
        }
    }

    fn seatListener(_: *river.SeatV1, event: river.SeatV1.Event, seat: *Seat) void {
        const runtime = seat.runtime;
        switch (event) {
            .removed => {
                seat.removed = true;
                runtime.recordEvent(.{ .seat_removed = seat.id });
            },
            .wl_seat => |value| seat.wl_seat = value.name,
            .pointer_enter => |value| {
                const object = value.window orelse return;
                const window = runtime.findWindow(object) orelse return;
                runtime.recordEvent(.{ .pointer_enter = .{ .seat = seat.id, .window = window.id } });
            },
            .pointer_leave => runtime.recordEvent(.{ .pointer_leave = seat.id }),
            .window_interaction => |value| {
                const object = value.window orelse return;
                const window = runtime.findWindow(object) orelse return;
                runtime.recordEvent(.{ .window_interaction = .{ .seat = seat.id, .window = window.id } });
            },
            .shell_surface_interaction => {},
            .op_delta => |value| runtime.recordEvent(.{ .op_delta = .{
                .seat = seat.id,
                .dx = value.dx,
                .dy = value.dy,
            } }),
            .op_release => runtime.recordEvent(.{ .op_release = seat.id }),
            .pointer_position => |value| seat.pointer_position = .{ .x = value.x, .y = value.y },
        }
    }

    fn layerShellSeatListener(
        _: *river.LayerShellSeatV1,
        event: river.LayerShellSeatV1.Event,
        seat: *Seat,
    ) void {
        const focus: policy.LayerShellFocus = switch (event) {
            .focus_exclusive => .exclusive,
            .focus_non_exclusive => .non_exclusive,
            .focus_none => .none,
        };
        seat.layer_shell_focus = focus;
        seat.runtime.recordEvent(.{ .layer_shell_focus = .{ .seat = seat.id, .focus = focus } });
    }

    fn bindingListener(_: *river.XkbBindingV1, event: river.XkbBindingV1.Event, binding: *Binding) void {
        const binding_event: policy.BindingEvent = switch (event) {
            .pressed => .pressed,
            .released => .released,
            .stop_repeat => .stop_repeat,
        };
        binding.runtime.input_invocations.append(binding.runtime.allocator, .{ .xkb = .{
            .binding = binding,
            .event = binding_event,
        } }) catch {
            binding.runtime.fatal = true;
        };
    }

    fn pointerBindingListener(
        _: *river.PointerBindingV1,
        event: river.PointerBindingV1.Event,
        binding: *PointerBinding,
    ) void {
        const binding_event: policy.BindingEvent = switch (event) {
            .pressed => .pressed,
            .released => .released,
        };
        binding.runtime.input_invocations.append(binding.runtime.allocator, .{ .pointer = .{
            .binding = binding,
            .event = binding_event,
        } }) catch {
            binding.runtime.fatal = true;
        };
    }

    fn xkbSeatListener(
        _: *river.XkbBindingsSeatV1,
        event: river.XkbBindingsSeatV1.Event,
        seat: *Seat,
    ) void {
        switch (event) {
            .ate_unbound_key => seat.runtime.recordEvent(.{ .ate_unbound_key = seat.id }),
            .modifiers_update => |value| {
                const old: u32 = @bitCast(value.old);
                const new: u32 = @bitCast(value.new);
                seat.modifiers = new;
                seat.runtime.recordEvent(.{ .modifiers_update = .{
                    .seat = seat.id,
                    .old = old,
                    .new = new,
                } });
            },
        }
    }
};

pub fn run(
    allocator: std.mem.Allocator,
    loop: *event_loop.EventLoop,
    host: *policy.Host,
) !void {
    var runtime: Runtime = undefined;
    try runtime.init(allocator, host);
    defer runtime.deinit();
    defer host.unbindInvalidator();

    if (runtime.unavailable) return error.RiverWindowManagementUnavailable;
    try loop.setWayland(.{
        .fd = runtime.display.getFd(),
        .ctx = &runtime,
        .prepare = Runtime.eventLoopPrepare,
        .finish = Runtime.eventLoopFinish,
    });
    defer loop.clearWayland();
    try loop.run();
    runtime.stop();
    if (runtime.unavailable) return error.RiverWindowManagementUnavailable;
    if (runtime.fatal) return error.RiverWindowManagerFailed;
}

fn riverEdges(edges: policy.Edges) river.WindowV1.Edges {
    return .{
        .top = edges.top,
        .bottom = edges.bottom,
        .left = edges.left,
        .right = edges.right,
    };
}

fn riverCapabilities(capabilities: policy.Capabilities) river.WindowV1.Capabilities {
    return .{
        .window_menu = capabilities.window_menu,
        .maximize = capabilities.maximize,
        .fullscreen = capabilities.fullscreen,
        .minimize = capabilities.minimize,
    };
}

fn findBinding(bindings: []*Binding, id: []const u8) ?*Binding {
    for (bindings) |binding| if (std.mem.eql(u8, binding.id, id)) return binding;
    return null;
}

fn findBindingDeclaration(bindings: []const policy.Binding, id: []const u8) ?policy.Binding {
    for (bindings) |binding| if (std.mem.eql(u8, binding.id, id)) return binding;
    return null;
}

fn findPointerBinding(bindings: []*PointerBinding, id: []const u8) ?*PointerBinding {
    for (bindings) |binding| if (std.mem.eql(u8, binding.id, id)) return binding;
    return null;
}

fn findPointerBindingDeclaration(
    bindings: []const policy.PointerBinding,
    id: []const u8,
) ?policy.PointerBinding {
    for (bindings) |binding| if (std.mem.eql(u8, binding.id, id)) return binding;
    return null;
}

fn replaceOptionalString(
    allocator: std.mem.Allocator,
    destination: *?[]u8,
    source: ?[*:0]const u8,
) !void {
    const replacement = if (source) |value| try allocator.dupe(u8, std.mem.span(value)) else null;
    if (destination.*) |old| allocator.free(old);
    destination.* = replacement;
}

fn replaceString(
    allocator: std.mem.Allocator,
    destination: *?[]u8,
    source: [*:0]const u8,
) !void {
    const replacement = try allocator.dupe(u8, std.mem.span(source));
    if (destination.*) |old| allocator.free(old);
    destination.* = replacement;
}
