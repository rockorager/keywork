//! Protocol-neutral ownership for privileged synthetic pointer providers.
//!
//! Wire adapters authenticate and resolve object identities, then hand seats
//! and output generations to this owner. This type owns source identities,
//! pressed-button state, routing lifetime, and exact-once seat teardown.

const VirtualPointer = @This();

const std = @import("std");
const wayland = @import("wayland");
const ClientRegistry = @import("ClientRegistry.zig");
const SurfaceRegistry = @import("SurfaceRegistry.zig");
const MatureClients = @import("wayland/MatureClients.zig");
const OutputLayout = @import("wayland/output_layout.zig");
const Seat = @import("wayland/seat.zig");
const Surface = @import("wayland/surface.zig");

const wl = wayland.server.wl;

pub const Event = union(enum) {
    motion: struct { time: u32, dx: f64, dy: f64 },
    motion_absolute: struct { time: u32, x: u32, y: u32, x_extent: u32, y_extent: u32 },
    button: struct { time: u32, button: u32, state: wl.Pointer.ButtonState },
    axis: struct { time: u32, axis: wl.Pointer.Axis, value: wl.Fixed },
    frame,
    axis_source: wl.Pointer.AxisSource,
    axis_stop: struct { time: u32, axis: wl.Pointer.Axis },
    axis_discrete: struct { time: u32, axis: wl.Pointer.Axis, value: wl.Fixed, discrete: i32 },
};

pub const Listener = struct {
    context: *anyopaque,
    event: *const fn (*anyopaque, *Seat, ?OutputLayout.Id, u64, Event) void,
};

pub const Provider = struct {
    owner: *VirtualPointer,
    id: u64,
};

pub const Selection = struct {
    seat: *Seat,
    output: ?OutputLayout.Id = null,
    release_context: ?*anyopaque = null,
    release: ?*const fn (*anyopaque, *Seat) void = null,
};

pub const Device = struct {
    owner: *VirtualPointer,
    provider: *Provider,
    seat: ?*Seat,
    output: ?OutputLayout.Id,
    source: u64,
    release_context: ?*anyopaque,
    release: ?*const fn (*anyopaque, *Seat) void,
    pressed_buttons: std.ArrayList(u32) = .empty,
    active: bool = true,

    pub fn motion(self: *Device, time: u32, dx: f64, dy: f64) void {
        self.emit(.{ .motion = .{ .time = time, .dx = dx, .dy = dy } });
    }

    pub fn motionAbsolute(self: *Device, time: u32, x: u32, y: u32, x_extent: u32, y_extent: u32) void {
        self.emit(.{ .motion_absolute = .{ .time = time, .x = x, .y = y, .x_extent = x_extent, .y_extent = y_extent } });
    }

    pub fn button(self: *Device, time: u32, button_code: u32, state_value: u32) !void {
        const state: wl.Pointer.ButtonState = switch (state_value) {
            @intFromEnum(wl.Pointer.ButtonState.released) => .released,
            @intFromEnum(wl.Pointer.ButtonState.pressed) => .pressed,
            else => return error.InvalidButtonState,
        };
        switch (state) {
            .pressed => {
                for (self.pressed_buttons.items) |pressed| if (pressed == button_code) return;
                try self.pressed_buttons.append(self.owner.allocator, button_code);
            },
            .released => {
                for (self.pressed_buttons.items, 0..) |pressed, index| {
                    if (pressed != button_code) continue;
                    _ = self.pressed_buttons.orderedRemove(index);
                    break;
                } else return;
            },
            else => unreachable,
        }
        self.emit(.{ .button = .{ .time = time, .button = button_code, .state = state } });
    }

    pub fn axis(self: *Device, time: u32, axis_value: u32, value: wl.Fixed) !void {
        self.emit(.{ .axis = .{ .time = time, .axis = try validateAxis(axis_value), .value = value } });
    }

    pub fn frame(self: *Device) void {
        self.emit(.frame);
    }

    pub fn axisSource(self: *Device, source_value: u32) !void {
        self.emit(.{ .axis_source = try validateAxisSource(source_value) });
    }

    pub fn axisStop(self: *Device, time: u32, axis_value: u32) !void {
        self.emit(.{ .axis_stop = .{ .time = time, .axis = try validateAxis(axis_value) } });
    }

    pub fn axisDiscrete(self: *Device, time: u32, axis_value: u32, value: wl.Fixed, discrete: i32) !void {
        self.emit(.{ .axis_discrete = .{ .time = time, .axis = try validateAxis(axis_value), .value = value, .discrete = discrete } });
    }

    fn emit(self: *Device, event: Event) void {
        if (!self.active) return;
        const seat = self.seat orelse return;
        const output = if (self.output) |id| if (self.owner.outputs.get(id) != null) id else return else null;
        const listener = self.owner.listener;
        listener.event(listener.context, seat, output, self.source, event);
    }

    fn emitCleanup(self: *Device, event: Event) void {
        const seat = self.seat orelse return;
        const output = if (self.output) |id| if (self.owner.outputs.get(id) != null) id else null else null;
        const listener = self.owner.listener;
        listener.event(listener.context, seat, output, self.source, event);
    }

    pub fn deactivate(self: *Device) void {
        if (!self.active) return;
        const seat = self.seat orelse unreachable;
        const had_buttons = self.pressed_buttons.items.len != 0;
        // Output retirement makes new device input inert, but cannot suppress
        // releases already owed to Seat's aggregate pressed-button state.
        while (self.pressed_buttons.pop()) |button_code| self.emitCleanup(.{ .button = .{
            .time = 0,
            .button = button_code,
            .state = .released,
        } });
        if (had_buttons) self.emitCleanup(.frame);
        seat.removeVirtualPointer();
        self.active = false;
        self.seat = null;
        if (self.release) |release| release(self.release_context.?, seat);
        self.release = null;
        self.release_context = null;
    }
};

allocator: std.mem.Allocator,
outputs: *OutputLayout,
listener: Listener,
providers: std.ArrayList(*Provider) = .empty,
devices: std.ArrayList(*Device) = .empty,
next_provider: u64 = 0,
next_source: u64 = 0,

pub fn init(allocator: std.mem.Allocator, outputs: *OutputLayout, listener: Listener) VirtualPointer {
    return .{ .allocator = allocator, .outputs = outputs, .listener = listener };
}

pub fn deinit(self: *VirtualPointer) void {
    std.debug.assert(self.providers.items.len == 0 and self.devices.items.len == 0);
    self.devices.deinit(self.allocator);
    self.providers.deinit(self.allocator);
    self.* = undefined;
}

pub fn createProvider(self: *VirtualPointer) !*Provider {
    const provider = try self.allocator.create(Provider);
    errdefer self.allocator.destroy(provider);
    provider.* = .{ .owner = self, .id = self.next_provider };
    self.next_provider = std.math.add(u64, self.next_provider, 1) catch unreachable;
    try self.providers.append(self.allocator, provider);
    return provider;
}

pub fn destroyProvider(self: *VirtualPointer, provider: *Provider) void {
    var i = self.devices.items.len;
    while (i > 0) : (i -= 1) if (self.devices.items[i - 1].provider == provider)
        self.destroyDevice(self.devices.items[i - 1]);
    for (self.providers.items, 0..) |candidate, index| if (candidate == provider) {
        _ = self.providers.orderedRemove(index);
        self.allocator.destroy(provider);
        return;
    };
    unreachable;
}

pub fn createDevice(self: *VirtualPointer, provider: *Provider, selection: Selection) !*Device {
    std.debug.assert(provider.owner == self);
    std.debug.assert((selection.release == null) == (selection.release_context == null));
    errdefer if (selection.release) |release| release(selection.release_context.?, selection.seat);
    const device = try self.allocator.create(Device);
    errdefer self.allocator.destroy(device);
    device.* = .{
        .owner = self,
        .provider = provider,
        .seat = selection.seat,
        .output = selection.output,
        .source = self.next_source,
        .release_context = selection.release_context,
        .release = selection.release,
    };
    self.next_source = std.math.add(u64, self.next_source, 1) catch unreachable;
    try self.devices.append(self.allocator, device);
    selection.seat.addVirtualPointer();
    return device;
}

pub fn destroyDevice(self: *VirtualPointer, device: *Device) void {
    device.deactivate();
    for (self.devices.items, 0..) |candidate, index| if (candidate == device) {
        _ = self.devices.orderedRemove(index);
        device.pressed_buttons.deinit(self.allocator);
        self.allocator.destroy(device);
        return;
    };
    unreachable;
}

pub fn deactivateSeat(self: *VirtualPointer, seat: *Seat) void {
    for (self.devices.items) |device| if (device.seat == seat) device.deactivate();
}

pub fn validateAxis(value: u32) error{InvalidAxis}!wl.Pointer.Axis {
    return switch (value) {
        @intFromEnum(wl.Pointer.Axis.vertical_scroll) => .vertical_scroll,
        @intFromEnum(wl.Pointer.Axis.horizontal_scroll) => .horizontal_scroll,
        else => error.InvalidAxis,
    };
}

pub fn validateAxisSource(value: u32) error{InvalidAxisSource}!wl.Pointer.AxisSource {
    return switch (value) {
        @intFromEnum(wl.Pointer.AxisSource.wheel) => .wheel,
        @intFromEnum(wl.Pointer.AxisSource.finger) => .finger,
        @intFromEnum(wl.Pointer.AxisSource.continuous) => .continuous,
        @intFromEnum(wl.Pointer.AxisSource.wheel_tilt) => .wheel_tilt,
        else => error.InvalidAxisSource,
    };
}

test "axis and source validation is exact" {
    try std.testing.expectEqual(wl.Pointer.Axis.vertical_scroll, try validateAxis(0));
    try std.testing.expectEqual(wl.Pointer.Axis.horizontal_scroll, try validateAxis(1));
    try std.testing.expectError(error.InvalidAxis, validateAxis(2));
    try std.testing.expectEqual(wl.Pointer.AxisSource.wheel_tilt, try validateAxisSource(3));
    try std.testing.expectError(error.InvalidAxisSource, validateAxisSource(4));
}

const TestFixture = struct {
    display: *wl.Server,
    surfaces: Surface.Store = .{},
    clients: ClientRegistry,
    surface_registry: SurfaceRegistry,
    mature_clients: MatureClients = undefined,
    seat: Seat = undefined,
    outputs: OutputLayout = undefined,
    events: [32]RecordedEvent = undefined,
    event_count: usize = 0,

    const RecordedEvent = struct {
        source: u64,
        output: ?OutputLayout.Id,
        event: Event,
    };

    fn init(self: *TestFixture) !void {
        const display = try wl.Server.create();
        errdefer display.destroy();
        self.* = .{
            .display = display,
            .clients = .init(std.testing.allocator),
            .surface_registry = .init(std.testing.allocator),
        };
        errdefer self.surface_registry.deinit();
        errdefer self.clients.deinit();
        self.mature_clients.init(std.testing.allocator, display, &self.clients);
        errdefer self.mature_clients.deinit();
        try self.seat.init(
            std.testing.allocator,
            std.testing.io,
            display,
            "test-seat",
            &self.surfaces,
            &self.clients,
            &self.mature_clients,
            &self.surface_registry,
        );
        errdefer self.seat.deinit();
        self.outputs.init(
            std.testing.allocator,
            display,
            &self.surface_registry,
            &self.surfaces,
        );
    }

    fn deinit(self: *TestFixture) void {
        self.outputs.deinit();
        self.seat.deinit();
        self.mature_clients.deinit();
        self.surface_registry.deinit();
        self.clients.deinit();
        self.surfaces.deinit(std.testing.allocator);
        self.display.destroy();
        self.* = undefined;
    }

    fn listener(self: *TestFixture) Listener {
        return .{ .context = self, .event = record };
    }

    fn record(context: *anyopaque, _: *Seat, output: ?OutputLayout.Id, source: u64, event: Event) void {
        const self: *TestFixture = @ptrCast(@alignCast(context));
        self.events[self.event_count] = .{ .source = source, .output = output, .event = event };
        self.event_count += 1;
    }
};

test "providers isolate devices and teardown releases each pressed button exactly once" {
    var fixture: TestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var owner = init(std.testing.allocator, &fixture.outputs, fixture.listener());
    defer owner.deinit();
    const first_provider = try owner.createProvider();
    const second_provider = try owner.createProvider();
    const first = try owner.createDevice(first_provider, .{ .seat = &fixture.seat });
    const second = try owner.createDevice(second_provider, .{ .seat = &fixture.seat });
    try std.testing.expect(fixture.seat.hasVirtualPointers());
    try std.testing.expect(first.source != second.source);

    try first.button(10, 0x110, @intFromEnum(wl.Pointer.ButtonState.pressed));
    try first.button(11, 0x110, @intFromEnum(wl.Pointer.ButtonState.pressed));
    try second.button(12, 0x111, @intFromEnum(wl.Pointer.ButtonState.pressed));
    try std.testing.expectEqual(@as(usize, 2), fixture.event_count);

    owner.destroyProvider(first_provider);
    try std.testing.expect(fixture.seat.hasVirtualPointers());
    try std.testing.expectEqual(@as(usize, 4), fixture.event_count);
    try std.testing.expectEqual(Event.button, std.meta.activeTag(fixture.events[2].event));
    try std.testing.expectEqual(wl.Pointer.ButtonState.released, fixture.events[2].event.button.state);
    try std.testing.expectEqual(@as(u32, 0), fixture.events[2].event.button.time);
    try std.testing.expectEqual(Event.frame, std.meta.activeTag(fixture.events[3].event));

    owner.destroyProvider(second_provider);
    try std.testing.expect(!fixture.seat.hasVirtualPointers());
    try std.testing.expectEqual(@as(usize, 6), fixture.event_count);
}

test "retired output suppresses new input but cannot suppress cleanup releases" {
    var fixture: TestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const output = try fixture.outputs.add(.{
        .size = .{ .width = 800, .height = 600 },
        .physical_size = .{ .width = 800, .height = 600 },
        .scale = 1,
        .name = "HEADLESS-VP",
        .description = "virtual pointer test output",
        .model = "headless",
    });

    var owner = init(std.testing.allocator, &fixture.outputs, fixture.listener());
    defer owner.deinit();
    const provider = try owner.createProvider();
    const device = try owner.createDevice(provider, .{ .seat = &fixture.seat, .output = output });
    try device.button(20, 0x110, @intFromEnum(wl.Pointer.ButtonState.pressed));
    try std.testing.expectEqual(output, fixture.events[0].output.?);
    try std.testing.expect(fixture.outputs.remove(output));
    device.motion(21, 4, 5);
    device.frame();
    try std.testing.expectEqual(@as(usize, 1), fixture.event_count);

    owner.destroyProvider(provider);
    try std.testing.expectEqual(@as(usize, 3), fixture.event_count);
    try std.testing.expectEqual(@as(?OutputLayout.Id, null), fixture.events[1].output);
    try std.testing.expectEqual(Event.button, std.meta.activeTag(fixture.events[1].event));
    try std.testing.expectEqual(Event.frame, std.meta.activeTag(fixture.events[2].event));
}
