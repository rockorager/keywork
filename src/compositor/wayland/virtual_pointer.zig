//! Privileged synthetic pointer devices for physical and transient seats.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const VirtualPointerOwner = @import("../VirtualPointer.zig");
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
owner: VirtualPointerOwner,
provider: *VirtualPointerOwner.Provider,

pub const Event = VirtualPointerOwner.Event;
pub const Listener = VirtualPointerOwner.Listener;

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
        .owner = VirtualPointerOwner.init(allocator, outputs, listener),
        .provider = undefined,
    };
    errdefer self.global.destroy();
    self.provider = try self.owner.createProvider();
    errdefer {
        self.owner.destroyProvider(self.provider);
        self.owner.deinit();
    }
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
    self.owner.destroyProvider(self.provider);
    self.owner.deinit();
    self.* = undefined;
}

/// Shared protocol-neutral authority used by unpublished generated adapters.
/// Publication and wire-resource ownership remain frontend-local.
pub fn authority(self: *Self) *VirtualPointerOwner {
    return &self.owner;
}

fn transientSeatRemoved(context: *anyopaque, seat: *Seat) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.owner.deactivateSeat(seat);
}

fn releaseTransientSeat(context: *anyopaque, seat: *Seat) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.transient_seat.releaseSeat(seat);
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
    neutral: ?*VirtualPointerOwner.Device,

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
        if (seat) |target| {
            std.debug.assert(target == manager.default_seat or retained_transient_seat);
        }
        const neutral = if (seat) |target| try manager.owner.createDevice(manager.provider, .{
            .seat = target,
            .output = output,
            .release_context = if (retained_transient_seat) manager else null,
            .release = if (retained_transient_seat) releaseTransientSeat else null,
        }) else null;
        errdefer if (neutral) |device| manager.owner.destroyDevice(device);
        self.* = .{
            .manager = manager,
            .resource = resource,
            .neutral = neutral,
        };
        try manager.devices.append(manager.allocator, self);
        resource.setHandler(*Device, handleRequest, handleDestroy, self);
    }

    fn handleRequest(
        resource: *zwlr.VirtualPointerV1,
        request: zwlr.VirtualPointerV1.Request,
        self: *Device,
    ) void {
        const neutral = self.neutral orelse {
            if (request == .destroy) resource.destroy();
            return;
        };
        if (!neutral.active) {
            if (request == .destroy) resource.destroy();
            return;
        }
        switch (request) {
            .motion => |motion| neutral.motion(motion.time, motion.dx.toDouble(), motion.dy.toDouble()),
            .motion_absolute => |motion| neutral.motionAbsolute(motion.time, motion.x, motion.y, motion.x_extent, motion.y_extent),
            .button => |event| self.buttonEvent(
                resource,
                event.time,
                event.button,
                event.state,
            ),
            .axis => |axis| {
                neutral.axis(axis.time, @intCast(@intFromEnum(axis.axis)), axis.value) catch {
                    resource.postError(.invalid_axis, "invalid virtual pointer axis");
                };
            },
            .frame => neutral.frame(),
            .axis_source => |source| {
                neutral.axisSource(@intCast(@intFromEnum(source.axis_source))) catch {
                    resource.postError(.invalid_axis_source, "invalid virtual pointer axis source");
                };
            },
            .axis_stop => |stop| {
                neutral.axisStop(stop.time, @intCast(@intFromEnum(stop.axis))) catch {
                    resource.postError(.invalid_axis, "invalid virtual pointer axis");
                };
            },
            .axis_discrete => |axis| {
                neutral.axisDiscrete(axis.time, @intCast(@intFromEnum(axis.axis)), axis.value, axis.discrete) catch {
                    resource.postError(.invalid_axis, "invalid virtual pointer axis");
                };
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
        self.neutral.?.button(time, button_code, @intCast(@intFromEnum(state))) catch |err| switch (err) {
            error.OutOfMemory => resource.postNoMemory(),
            error.InvalidButtonState => {},
        };
    }

    fn handleDestroy(_: *zwlr.VirtualPointerV1, self: *Device) void {
        if (self.neutral) |neutral| self.manager.owner.destroyDevice(neutral);
        for (self.manager.devices.items, 0..) |device, index| {
            if (device != self) continue;
            _ = self.manager.devices.orderedRemove(index);
            self.manager.allocator.destroy(self);
            return;
        }
        unreachable;
    }
};
