//! Privileged synthetic pointer devices for physical and transient seats.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const OutputLayout = @import("output_layout.zig");
const SecurityContext = @import("security_context.zig");
const Seat = @import("seat.zig");
const TransientSeat = @import("transient_seat.zig");

const wl = wayland.server.wl;
const zwlr = wayland.server.zwlr;

allocator: std.mem.Allocator,
global: *wl.Global,
security_context: *SecurityContext,
default_seat: *Seat,
transient_seat: *TransientSeat,
outputs: *OutputLayout,
listener: Listener,
devices: std.ArrayList(*Device),
next_source: u64,

pub const Event = union(enum) {
    motion: struct {
        time: u32,
        dx: f64,
        dy: f64,
    },
    motion_absolute: struct {
        time: u32,
        x: u32,
        y: u32,
        x_extent: u32,
        y_extent: u32,
    },
    button: struct {
        time: u32,
        button: u32,
        state: wl.Pointer.ButtonState,
    },
    axis: struct {
        time: u32,
        axis: wl.Pointer.Axis,
        value: wl.Fixed,
    },
    frame,
    axis_source: wl.Pointer.AxisSource,
    axis_stop: struct {
        time: u32,
        axis: wl.Pointer.Axis,
    },
    axis_discrete: struct {
        time: u32,
        axis: wl.Pointer.Axis,
        value: wl.Fixed,
        discrete: i32,
    },
};

pub const Listener = struct {
    context: *anyopaque,
    event: *const fn (
        *anyopaque,
        *Seat,
        ?OutputLayout.Id,
        u64,
        Event,
    ) void,
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    security_context: *SecurityContext,
    default_seat: *Seat,
    transient_seat: *TransientSeat,
    outputs: *OutputLayout,
    listener: Listener,
) !void {
    self.* = .{
        .allocator = allocator,
        .global = try wl.Global.create(
            display,
            zwlr.VirtualPointerManagerV1,
            2,
            *Self,
            self,
            bind,
        ),
        .security_context = security_context,
        .default_seat = default_seat,
        .transient_seat = transient_seat,
        .outputs = outputs,
        .listener = listener,
        .devices = .empty,
        .next_source = 0,
    };
    errdefer self.global.destroy();
    try security_context.restrictGlobal(self.global);
    errdefer security_context.unrestrictGlobal(self.global);
    try transient_seat.addSeatListener(.{
        .context = self,
        .removed = transientSeatRemoved,
    });
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.devices.items.len == 0);
    self.transient_seat.removeSeatListener(self);
    self.security_context.unrestrictGlobal(self.global);
    self.global.destroy();
    self.devices.deinit(self.allocator);
    self.* = undefined;
}

fn transientSeatRemoved(context: *anyopaque, seat: *Seat) void {
    const self: *Self = @ptrCast(@alignCast(context));
    for (self.devices.items) |device| {
        if (device.seat == seat) device.deactivate();
    }
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = zwlr.VirtualPointerManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleManagerRequest, null, self);
}

fn handleManagerRequest(
    resource: *zwlr.VirtualPointerManagerV1,
    request: zwlr.VirtualPointerManagerV1.Request,
    self: *Self,
) void {
    switch (request) {
        .create_virtual_pointer => |create| self.createDevice(
            resource,
            create.seat,
            null,
            create.id,
        ),
        .create_virtual_pointer_with_output => |create| self.createDevice(
            resource,
            create.seat,
            create.output,
            create.id,
        ),
        .destroy => resource.destroy(),
    }
}

fn createDevice(
    self: *Self,
    manager_resource: *zwlr.VirtualPointerManagerV1,
    seat_resource: ?*wl.Seat,
    output_resource: ?*wl.Output,
    id: u32,
) void {
    const seat = if (seat_resource) |resource|
        if (self.default_seat.ownsResource(resource))
            self.default_seat
        else
            self.transient_seat.seatForResource(resource)
    else
        self.default_seat;
    const output = if (output_resource) |resource|
        if (self.outputs.findResource(resource)) |entry| entry.id else null
    else
        null;
    Device.create(self, manager_resource, seat, output, id) catch
        manager_resource.postNoMemory();
}

const Device = struct {
    manager: *Self,
    resource: *zwlr.VirtualPointerV1,
    seat: ?*Seat,
    output: ?OutputLayout.Id,
    source: u64,
    retained_transient_seat: bool,
    active: bool,
    pressed_buttons: std.ArrayList(u32),

    fn create(
        manager: *Self,
        manager_resource: *zwlr.VirtualPointerManagerV1,
        seat: ?*Seat,
        output: ?OutputLayout.Id,
        id: u32,
    ) !void {
        const resource = try zwlr.VirtualPointerV1.create(
            manager_resource.getClient(),
            manager_resource.getVersion(),
            id,
        );
        errdefer resource.destroy();
        const self = try manager.allocator.create(Device);
        errdefer manager.allocator.destroy(self);
        const retained_transient_seat = if (seat) |target|
            target != manager.default_seat and manager.transient_seat.retainSeat(target)
        else
            false;
        errdefer if (retained_transient_seat) manager.transient_seat.releaseSeat(seat.?);
        if (seat) |target| {
            std.debug.assert(target == manager.default_seat or retained_transient_seat);
        }
        const source = manager.next_source;
        manager.next_source = std.math.add(u64, source, 1) catch unreachable;
        self.* = .{
            .manager = manager,
            .resource = resource,
            .seat = seat,
            .output = output,
            .source = source,
            .retained_transient_seat = retained_transient_seat,
            .active = seat != null,
            .pressed_buttons = .empty,
        };
        errdefer self.pressed_buttons.deinit(manager.allocator);
        try manager.devices.append(manager.allocator, self);
        if (seat) |target| target.addVirtualPointer();
        resource.setHandler(*Device, handleRequest, handleDestroy, self);
    }

    fn handleRequest(
        resource: *zwlr.VirtualPointerV1,
        request: zwlr.VirtualPointerV1.Request,
        self: *Device,
    ) void {
        if (!self.active) {
            if (request == .destroy) resource.destroy();
            return;
        }
        switch (request) {
            .motion => |motion| self.emit(.{ .motion = .{
                .time = motion.time,
                .dx = motion.dx.toDouble(),
                .dy = motion.dy.toDouble(),
            } }),
            .motion_absolute => |motion| self.emit(.{ .motion_absolute = .{
                .time = motion.time,
                .x = motion.x,
                .y = motion.y,
                .x_extent = motion.x_extent,
                .y_extent = motion.y_extent,
            } }),
            .button => |event| self.buttonEvent(
                resource,
                event.time,
                event.button,
                event.state,
            ),
            .axis => |axis| {
                const valid = validateAxis(resource, axis.axis) orelse return;
                self.emit(.{ .axis = .{
                    .time = axis.time,
                    .axis = valid,
                    .value = axis.value,
                } });
            },
            .frame => self.emit(.frame),
            .axis_source => |source| {
                const valid = validateAxisSource(resource, source.axis_source) orelse return;
                self.emit(.{ .axis_source = valid });
            },
            .axis_stop => |stop| {
                const valid = validateAxis(resource, stop.axis) orelse return;
                self.emit(.{ .axis_stop = .{ .time = stop.time, .axis = valid } });
            },
            .axis_discrete => |axis| {
                const valid = validateAxis(resource, axis.axis) orelse return;
                self.emit(.{ .axis_discrete = .{
                    .time = axis.time,
                    .axis = valid,
                    .value = axis.value,
                    .discrete = axis.discrete,
                } });
            },
            .destroy => resource.destroy(),
        }
    }

    fn buttonEvent(
        self: *Device,
        resource: *zwlr.VirtualPointerV1,
        time: u32,
        button_code: u32,
        state: wl.Pointer.ButtonState,
    ) void {
        switch (state) {
            .pressed => {
                for (self.pressed_buttons.items) |pressed| {
                    if (pressed == button_code) return;
                }
                self.pressed_buttons.append(self.manager.allocator, button_code) catch {
                    resource.postNoMemory();
                    return;
                };
            },
            .released => {
                for (self.pressed_buttons.items, 0..) |pressed, index| {
                    if (pressed != button_code) continue;
                    _ = self.pressed_buttons.orderedRemove(index);
                    break;
                } else return;
            },
            else => return,
        }
        self.emit(.{ .button = .{
            .time = time,
            .button = button_code,
            .state = state,
        } });
    }

    fn emit(self: *Device, event: Event) void {
        const seat = self.seat orelse return;
        const listener = self.manager.listener;
        listener.event(listener.context, seat, self.output, self.source, event);
    }

    fn deactivate(self: *Device) void {
        if (!self.active) return;
        const seat = self.seat orelse unreachable;
        const had_pressed_buttons = self.pressed_buttons.items.len != 0;
        while (self.pressed_buttons.pop()) |button_code| {
            self.emit(.{ .button = .{
                .time = 0,
                .button = button_code,
                .state = .released,
            } });
        }
        if (had_pressed_buttons) self.emit(.frame);
        seat.removeVirtualPointer();
        self.active = false;
        self.seat = null;
        if (self.retained_transient_seat) {
            self.retained_transient_seat = false;
            self.manager.transient_seat.releaseSeat(seat);
        }
    }

    fn handleDestroy(_: *zwlr.VirtualPointerV1, self: *Device) void {
        self.deactivate();
        for (self.manager.devices.items, 0..) |device, index| {
            if (device != self) continue;
            _ = self.manager.devices.orderedRemove(index);
            self.pressed_buttons.deinit(self.manager.allocator);
            self.manager.allocator.destroy(self);
            return;
        }
        unreachable;
    }
};

fn validateAxis(
    resource: *zwlr.VirtualPointerV1,
    axis: wl.Pointer.Axis,
) ?wl.Pointer.Axis {
    return switch (axis) {
        .vertical_scroll, .horizontal_scroll => axis,
        else => {
            resource.postError(.invalid_axis, "invalid virtual pointer axis");
            return null;
        },
    };
}

fn validateAxisSource(
    resource: *zwlr.VirtualPointerV1,
    source: wl.Pointer.AxisSource,
) ?wl.Pointer.AxisSource {
    return switch (source) {
        .wheel, .finger, .continuous, .wheel_tilt => source,
        else => {
            resource.postError(.invalid_axis_source, "invalid virtual pointer axis source");
            return null;
        },
    };
}
