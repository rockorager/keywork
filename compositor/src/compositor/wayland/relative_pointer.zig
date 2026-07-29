//! Relative pointer motion for focused wl_pointer clients.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Seat = @import("seat.zig");

const wl = wayland.server.wl;
const zwp = wayland.server.zwp;

allocator: std.mem.Allocator,
global: *wl.Global,
seat: *Seat,
devices: std.ArrayList(*Device),

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    seat: *Seat,
) !void {
    self.* = .{
        .allocator = allocator,
        .global = try wl.Global.create(
            display,
            zwp.RelativePointerManagerV1,
            1,
            *Self,
            self,
            bind,
        ),
        .seat = seat,
        .devices = .empty,
    };
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.devices.items.len == 0);
    self.global.destroy();
    self.devices.deinit(self.allocator);
    self.* = undefined;
}

pub fn motion(
    self: *Self,
    time_usec: u64,
    dx: f64,
    dy: f64,
    dx_unaccelerated: f64,
    dy_unaccelerated: f64,
) void {
    std.debug.assert(std.math.isFinite(dx));
    std.debug.assert(std.math.isFinite(dy));
    std.debug.assert(std.math.isFinite(dx_unaccelerated));
    std.debug.assert(std.math.isFinite(dy_unaccelerated));
    const focused_client = self.seat.pointerFocusedClient() orelse return;
    const time = timestampParts(time_usec);
    for (self.devices.items) |device| {
        if (device.client != focused_client) continue;
        const pointer = device.pointer orelse continue;
        if (!self.seat.pointerHandleIsActive(pointer)) continue;
        device.resource.sendRelativeMotion(
            time.high,
            time.low,
            fixed(dx),
            fixed(dy),
            fixed(dx_unaccelerated),
            fixed(dy_unaccelerated),
        );
    }
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = zwp.RelativePointerManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleManagerRequest, null, self);
}

fn handleManagerRequest(
    resource: *zwp.RelativePointerManagerV1,
    request: zwp.RelativePointerManagerV1.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .get_relative_pointer => |get| Device.create(
            self,
            resource,
            get.id,
            self.seat.pointerHandle(get.pointer),
        ) catch resource.postNoMemory(),
    }
}

const Device = struct {
    manager: *Self,
    resource: *zwp.RelativePointerV1,
    client: *wl.Client,
    pointer: ?Seat.PointerHandle,

    fn create(
        manager: *Self,
        manager_resource: *zwp.RelativePointerManagerV1,
        id: u32,
        pointer: ?Seat.PointerHandle,
    ) !void {
        const resource = try zwp.RelativePointerV1.create(
            manager_resource.getClient(),
            manager_resource.getVersion(),
            id,
        );
        errdefer resource.destroy();
        const self = try manager.allocator.create(Device);
        errdefer manager.allocator.destroy(self);
        self.* = .{
            .manager = manager,
            .resource = resource,
            .client = manager_resource.getClient(),
            .pointer = pointer,
        };
        try manager.devices.append(manager.allocator, self);
        resource.setHandler(*Device, handleRequest, handleDestroy, self);
    }

    fn handleRequest(
        resource: *zwp.RelativePointerV1,
        request: zwp.RelativePointerV1.Request,
        _: *Device,
    ) void {
        switch (request) {
            .destroy => resource.destroy(),
        }
    }

    fn handleDestroy(_: *zwp.RelativePointerV1, self: *Device) void {
        for (self.manager.devices.items, 0..) |device, index| {
            if (device != self) continue;
            _ = self.manager.devices.orderedRemove(index);
            self.manager.allocator.destroy(self);
            return;
        }
        unreachable;
    }
};

fn timestampParts(time_usec: u64) struct { high: u32, low: u32 } {
    return .{
        .high = @truncate(time_usec >> 32),
        .low = @truncate(time_usec),
    };
}

fn fixed(value: f64) wl.Fixed {
    const minimum = @as(f64, @floatFromInt(std.math.minInt(i32))) / 256.0;
    const maximum = @as(f64, @floatFromInt(std.math.maxInt(i32))) / 256.0;
    return wl.Fixed.fromDouble(std.math.clamp(value, minimum, maximum));
}

test "timestamp is split into protocol words" {
    const parts = timestampParts(0x0123_4567_89ab_cdef);
    try std.testing.expectEqual(@as(u32, 0x0123_4567), parts.high);
    try std.testing.expectEqual(@as(u32, 0x89ab_cdef), parts.low);
}
