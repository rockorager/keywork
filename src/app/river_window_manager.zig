//! Headless client for River's external window-management protocol.

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
    object: *river.WindowV1,
    node: *river.NodeV1,
    title: ?[]u8 = null,
    app_id: ?[]u8 = null,
    identifier: ?[]u8 = null,
    placement: ?policy.Placement = null,
    is_new: bool = true,
    closed: bool = false,
};

const Output = struct {
    object: *river.OutputV1,
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    removed: bool = false,
};

const Binding = struct {
    object: *river.XkbBindingV1,
    id: []u8,
    keysym: u32,
    modifiers: u32,
    pressed: bool = false,
};

const Seat = struct {
    object: *river.SeatV1,
    bindings: std.ArrayList(*Binding) = .empty,
    interacted_window: ?*river.WindowV1 = null,
    removed: bool = false,
};

const Runtime = struct {
    allocator: std.mem.Allocator,
    host: *policy.Host,
    display: *wl.Display,
    registry: *wl.Registry,
    manager: ?*river.WindowManagerV1 = null,
    xkb_bindings: ?*river.XkbBindingsV1 = null,
    manager_global: ?u32 = null,
    xkb_global: ?u32 = null,
    windows: std.ArrayList(*Window) = .empty,
    outputs: std.ArrayList(*Output) = .empty,
    seats: std.ArrayList(*Seat) = .empty,
    actions: std.ArrayList(policy.Action) = .empty,
    focused_window: ?*Window = null,
    phase: Phase = .idle,
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
        if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
        if (self.manager == null) return error.NoRiverWindowManager;
        if (self.xkb_bindings == null) return error.NoRiverXkbBindings;
        if (self.fatal) return error.RiverInitializationFailed;
    }

    fn deinit(self: *Runtime) void {
        self.destroyChildren();
        if (self.manager) |manager| manager.destroy();
        if (self.xkb_bindings) |bindings| bindings.destroy();
        self.registry.destroy();
        self.display.disconnect();
        self.actions.deinit(self.allocator);
    }

    fn destroyChildren(self: *Runtime) void {
        for (self.seats.items) |seat| self.destroySeat(seat, true);
        self.seats.deinit(self.allocator);
        for (self.windows.items) |window| self.destroyWindow(window, true);
        self.windows.deinit(self.allocator);
        for (self.outputs.items) |output| {
            output.object.destroy();
            self.allocator.destroy(output);
        }
        self.outputs.deinit(self.allocator);
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

    fn requestAction(ctx: *anyopaque, action: policy.Action) anyerror!void {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        try self.actions.append(self.allocator, action);
        try invalidate(self);
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
                }
            },
            .global_remove => |removed| {
                if (self.manager_global == removed.name or self.xkb_global == removed.name) self.fatal = true;
            },
        }
    }

    fn managerListener(_: *river.WindowManagerV1, event: river.WindowManagerV1.Event, self: *Runtime) void {
        switch (event) {
            .unavailable => self.unavailable = true,
            .finished => self.finished = true,
            .manage_start => self.manage(),
            .render_start => self.render(),
            .session_locked, .session_unlocked => {},
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
        window.* = .{ .runtime = self, .object = object, .node = node };
        object.setListener(*Window, windowListener, window);
        try self.windows.append(self.allocator, window);
    }

    fn addOutput(self: *Runtime, object: *river.OutputV1) !void {
        const output = try self.allocator.create(Output);
        errdefer self.allocator.destroy(output);
        output.* = .{ .object = object };
        object.setListener(*Output, outputListener, output);
        try self.outputs.append(self.allocator, output);
    }

    fn addSeat(self: *Runtime, object: *river.SeatV1) !void {
        const seat = try self.allocator.create(Seat);
        errdefer self.allocator.destroy(seat);
        seat.* = .{ .object = object };
        object.setListener(*Seat, seatListener, seat);
        try self.seats.append(self.allocator, seat);
    }

    fn manage(self: *Runtime) void {
        const manager = self.manager orelse return;
        if (self.phase != .idle) {
            self.fatal = true;
            return;
        }
        self.phase = .manage;
        defer {
            manager.manageFinish();
            self.phase = .idle;
        }
        if (self.fatal) return;

        self.removeClosedObjects();
        self.invokeBindings();
        self.applyActions();
        self.removeClosedObjects();
        self.reconcileBindings() catch |err| {
            // A failed reload leaves the last successfully loaded root
            // committed, so keep managing with that policy.
            log.err("failed to refresh River key bindings; keeping the previous bindings: {}", .{err});
        };
        self.updateFocus();
        self.updateLayout();
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

        var previous: ?*river.NodeV1 = null;
        for (self.windows.items) |window| {
            if (window.closed) continue;
            const placement = window.placement orelse continue;
            if (!placement.visible) {
                window.object.hide();
                continue;
            }
            window.node.setPosition(placement.x, placement.y);
            window.object.show();
            if (previous) |node| {
                window.node.placeAbove(node);
            } else {
                window.node.placeBottom();
            }
            previous = window.node;
        }
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
            if (self.focused_window == window) self.focused_window = null;
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
        if (destroy_object) seat.object.destroy();
        self.allocator.destroy(seat);
    }

    fn destroyBinding(self: *Runtime, binding: *Binding, destroy_object: bool) void {
        if (destroy_object) binding.object.destroy();
        self.allocator.free(binding.id);
        self.allocator.destroy(binding);
    }

    fn invokeBindings(self: *Runtime) void {
        for (self.seats.items) |seat| {
            for (seat.bindings.items) |binding| {
                if (!binding.pressed) continue;
                binding.pressed = false;
                self.host.invokeBinding(binding.id) catch |err| {
                    log.err("River binding '{s}' failed: {}", .{ binding.id, err });
                };
            }
        }
    }

    fn applyActions(self: *Runtime) void {
        defer self.actions.clearRetainingCapacity();
        for (self.actions.items) |action| switch (action) {
            .close_focused => if (self.focused_window) |window| window.object.close(),
            .focus_next => self.focusNext(),
            .exit_session => if (self.manager) |manager| {
                if (manager.getVersion() >= river.WindowManagerV1.exit_session_since_version) {
                    self.exit_requested = true;
                    manager.exitSession();
                } else {
                    log.err("River compositor does not support exit_session", .{});
                }
            },
        };
    }

    fn focusNext(self: *Runtime) void {
        if (self.windows.items.len == 0) {
            self.focused_window = null;
            return;
        }
        const current = self.focused_window orelse {
            self.focused_window = self.windows.items[0];
            return;
        };
        for (self.windows.items, 0..) |window, index| {
            if (window != current) continue;
            self.focused_window = self.windows.items[(index + 1) % self.windows.items.len];
            return;
        }
        self.focused_window = self.windows.items[0];
    }

    fn updateFocus(self: *Runtime) void {
        for (self.seats.items) |seat| {
            if (seat.interacted_window) |object| {
                if (self.findWindow(object)) |window| self.focused_window = window;
                seat.interacted_window = null;
            }
        }
        if (self.focused_window == null and self.windows.items.len > 0) {
            self.focused_window = self.windows.items[0];
        }
        for (self.seats.items) |seat| {
            if (self.focused_window) |window| {
                seat.object.focusWindow(window.object);
            } else {
                seat.object.clearFocus();
            }
        }
    }

    fn reconcileBindings(self: *Runtime) !void {
        try self.host.refresh();
        const declarations = try self.host.bindings(self.allocator);
        defer policy.freeBindings(self.allocator, declarations);
        for (self.seats.items) |seat| try self.reconcileSeatBindings(seat, declarations);
    }

    fn reconcileSeatBindings(self: *Runtime, seat: *Seat, declarations: []const policy.Binding) !void {
        var index: usize = 0;
        while (index < seat.bindings.items.len) {
            const binding = seat.bindings.items[index];
            const declaration = findBindingDeclaration(declarations, binding.id);
            if (declaration != null and declaration.?.keysym == binding.keysym and declaration.?.modifiers == binding.modifiers) {
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
            .object = object,
            .id = id,
            .keysym = declaration.keysym,
            .modifiers = declaration.modifiers,
        };
        object.setListener(*Binding, bindingListener, binding);
        try seat.bindings.append(self.allocator, binding);
        object.enable();
    }

    fn updateLayout(self: *Runtime) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const outputs = allocator.alloc(policy.Output, self.outputs.items.len) catch {
            self.fatal = true;
            return;
        };
        for (self.outputs.items, 0..) |output, index| outputs[index] = .{
            .id = output.object.getId(),
            .x = output.x,
            .y = output.y,
            .width = output.width,
            .height = output.height,
        };
        const windows = allocator.alloc(policy.Window, self.windows.items.len) catch {
            self.fatal = true;
            return;
        };
        for (self.windows.items, 0..) |window, index| windows[index] = .{
            .id = window.object.getId(),
            .title = window.title,
            .app_id = window.app_id,
            .identifier = window.identifier,
        };
        const context: policy.Context = .{
            .outputs = outputs,
            .windows = windows,
            .focused_window = if (self.focused_window) |window| window.object.getId() else null,
        };

        const placements = self.host.layout(allocator, context) catch |err| {
            log.err("River layout failed, using the fallback layout: {}", .{err});
            self.fallbackLayout();
            self.proposeLayout();
            return;
        };
        self.applyPlacements(placements) catch |err| {
            log.err("River layout is invalid, using the fallback layout: {}", .{err});
            self.fallbackLayout();
        };
        self.proposeLayout();
    }

    fn applyPlacements(self: *Runtime, placements: []const policy.Placement) !void {
        for (self.windows.items) |window| window.placement = null;
        for (placements) |placement| {
            const window = self.findWindowId(placement.window_id) orelse return error.UnknownWindow;
            if (window.placement != null) return error.DuplicateWindow;
            window.placement = placement;
        }
        for (self.windows.items) |window| {
            if (window.placement != null) continue;
            const hidden: policy.Placement = .{
                .window_id = window.object.getId(),
                .x = 0,
                .y = 0,
                .width = 640,
                .height = 480,
            };
            window.placement = .{
                .window_id = hidden.window_id,
                .x = hidden.x,
                .y = hidden.y,
                .width = hidden.width,
                .height = hidden.height,
                .visible = false,
            };
        }
    }

    fn fallbackLayout(self: *Runtime) void {
        const count = self.windows.items.len;
        if (count == 0) return;
        const output = if (self.outputs.items.len > 0) self.outputs.items[0] else null;
        const x = if (output) |item| item.x else 0;
        const y = if (output) |item| item.y else 0;
        const total_width: i32 = if (output) |item| @max(1, item.width) else 1280;
        const height: i32 = if (output) |item| @max(1, item.height) else 720;
        const width = @max(1, @divTrunc(total_width, @as(i32, @intCast(count))));
        for (self.windows.items, 0..) |window, index| window.placement = .{
            .window_id = window.object.getId(),
            .x = x + width * @as(i32, @intCast(index)),
            .y = y,
            .width = if (index + 1 == count) total_width - width * @as(i32, @intCast(index)) else width,
            .height = height,
        };
    }

    fn proposeLayout(self: *Runtime) void {
        for (self.windows.items) |window| {
            const placement = window.placement orelse continue;
            if (window.is_new) {
                window.object.setCapabilities(.{});
                window.object.setTiled(.{ .top = true, .bottom = true, .left = true, .right = true });
                window.is_new = false;
            }
            window.object.proposeDimensions(placement.width, placement.height);
        }
    }

    fn findWindow(self: *Runtime, object: *river.WindowV1) ?*Window {
        for (self.windows.items) |window| if (window.object == object) return window;
        return null;
    }

    fn findWindowId(self: *Runtime, id: u32) ?*Window {
        for (self.windows.items) |window| if (window.object.getId() == id) return window;
        return null;
    }

    fn windowListener(_: *river.WindowV1, event: river.WindowV1.Event, window: *Window) void {
        switch (event) {
            .closed => window.closed = true,
            .dimensions => {},
            .app_id => |app_id| replaceOptionalString(window.runtime.allocator, &window.app_id, app_id.app_id) catch {
                window.runtime.fatal = true;
            },
            .title => |title| replaceOptionalString(window.runtime.allocator, &window.title, title.title) catch {
                window.runtime.fatal = true;
            },
            .identifier => |identifier| replaceOptionalString(window.runtime.allocator, &window.identifier, identifier.identifier) catch {
                window.runtime.fatal = true;
            },
            else => {},
        }
    }

    fn outputListener(_: *river.OutputV1, event: river.OutputV1.Event, output: *Output) void {
        switch (event) {
            .removed => output.removed = true,
            .position => |position| {
                output.x = position.x;
                output.y = position.y;
            },
            .dimensions => |dimensions| {
                output.width = dimensions.width;
                output.height = dimensions.height;
            },
            .wl_output => {},
        }
    }

    fn seatListener(_: *river.SeatV1, event: river.SeatV1.Event, seat: *Seat) void {
        switch (event) {
            .removed => seat.removed = true,
            .window_interaction => |interaction| seat.interacted_window = interaction.window,
            else => {},
        }
    }

    fn bindingListener(_: *river.XkbBindingV1, event: river.XkbBindingV1.Event, binding: *Binding) void {
        switch (event) {
            .pressed => binding.pressed = true,
            .released, .stop_repeat => {},
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
    const control: policy.Control = .{ .ptr = &runtime, .vtable = &control_vtable };
    host.setControl(control);
    defer host.setControl(null);
    try host.bindInvalidator(&runtime, Runtime.invalidate);
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

const control_vtable: policy.Control.VTable = .{
    .request_action = Runtime.requestAction,
};

fn findBinding(bindings: []*Binding, id: []const u8) ?*Binding {
    for (bindings) |binding| if (std.mem.eql(u8, binding.id, id)) return binding;
    return null;
}

fn findBindingDeclaration(bindings: []const policy.Binding, id: []const u8) ?policy.Binding {
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
