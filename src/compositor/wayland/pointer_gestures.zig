//! Swipe, pinch, and hold events for focused pointer clients.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Seat = @import("seat.zig");

const wl = wayland.server.wl;
const zwp = wayland.server.zwp;

allocator: std.mem.Allocator,
display: *wl.Server,
global: *wl.Global,
swipes: std.ArrayList(*Swipe),
pinches: std.ArrayList(*Pinch),
holds: std.ArrayList(*Hold),

pub fn init(self: *Self, allocator: std.mem.Allocator, display: *wl.Server) !void {
    self.* = .{
        .allocator = allocator,
        .display = display,
        .global = try wl.Global.create(
            display,
            zwp.PointerGesturesV1,
            3,
            *Self,
            self,
            bind,
        ),
        .swipes = .empty,
        .pinches = .empty,
        .holds = .empty,
    };
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.swipes.items.len == 0);
    std.debug.assert(self.pinches.items.len == 0);
    std.debug.assert(self.holds.items.len == 0);
    self.global.destroy();
    self.holds.deinit(self.allocator);
    self.pinches.deinit(self.allocator);
    self.swipes.deinit(self.allocator);
    self.* = undefined;
}

pub fn beginSwipe(self: *Self, seat: *Seat, time: u32, fingers: u32) void {
    const surface = seat.pointerFocusedResource() orelse return;
    const serial = self.display.nextSerial();
    for (self.swipes.items) |swipe| {
        if (!bindingMatches(swipe.binding, seat) or
            swipe.resource.getClient() != surface.getClient()) continue;
        if (swipe.active) swipe.resource.sendEnd(serial, time, 1);
        swipe.active = true;
        swipe.resource.sendBegin(serial, time, surface, fingers);
    }
}

pub fn updateSwipe(self: *Self, seat: *Seat, time: u32, dx: f64, dy: f64) void {
    for (self.swipes.items) |swipe| {
        if (bindingMatches(swipe.binding, seat) and swipe.active) {
            swipe.resource.sendUpdate(time, fixed(dx), fixed(dy));
        }
    }
}

pub fn endSwipe(self: *Self, seat: *Seat, time: u32, cancelled: bool) void {
    const serial = self.display.nextSerial();
    for (self.swipes.items) |swipe| {
        if (!bindingMatches(swipe.binding, seat) or !swipe.active) continue;
        swipe.active = false;
        swipe.resource.sendEnd(serial, time, @intFromBool(cancelled));
    }
}

pub fn beginPinch(self: *Self, seat: *Seat, time: u32, fingers: u32) void {
    const surface = seat.pointerFocusedResource() orelse return;
    const serial = self.display.nextSerial();
    for (self.pinches.items) |pinch| {
        if (!bindingMatches(pinch.binding, seat) or
            pinch.resource.getClient() != surface.getClient()) continue;
        if (pinch.active) pinch.resource.sendEnd(serial, time, 1);
        pinch.active = true;
        pinch.resource.sendBegin(serial, time, surface, fingers);
    }
}

pub fn updatePinch(
    self: *Self,
    seat: *Seat,
    time: u32,
    dx: f64,
    dy: f64,
    scale: f64,
    rotation: f64,
) void {
    for (self.pinches.items) |pinch| {
        if (bindingMatches(pinch.binding, seat) and pinch.active) {
            pinch.resource.sendUpdate(
                time,
                fixed(dx),
                fixed(dy),
                fixed(scale),
                fixed(rotation),
            );
        }
    }
}

pub fn endPinch(self: *Self, seat: *Seat, time: u32, cancelled: bool) void {
    const serial = self.display.nextSerial();
    for (self.pinches.items) |pinch| {
        if (!bindingMatches(pinch.binding, seat) or !pinch.active) continue;
        pinch.active = false;
        pinch.resource.sendEnd(serial, time, @intFromBool(cancelled));
    }
}

pub fn beginHold(self: *Self, seat: *Seat, time: u32, fingers: u32) void {
    const surface = seat.pointerFocusedResource() orelse return;
    const serial = self.display.nextSerial();
    for (self.holds.items) |hold| {
        if (!bindingMatches(hold.binding, seat) or
            hold.resource.getClient() != surface.getClient()) continue;
        if (hold.active) hold.resource.sendEnd(serial, time, 1);
        hold.active = true;
        hold.resource.sendBegin(serial, time, surface, fingers);
    }
}

pub fn endHold(self: *Self, seat: *Seat, time: u32, cancelled: bool) void {
    const serial = self.display.nextSerial();
    for (self.holds.items) |hold| {
        if (!bindingMatches(hold.binding, seat) or !hold.active) continue;
        hold.active = false;
        hold.resource.sendEnd(serial, time, @intFromBool(cancelled));
    }
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = zwp.PointerGesturesV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleManagerRequest, null, self);
}

fn handleManagerRequest(
    resource: *zwp.PointerGesturesV1,
    request: zwp.PointerGesturesV1.Request,
    self: *Self,
) void {
    switch (request) {
        .release => resource.destroy(),
        .get_swipe_gesture => |get| Swipe.create(
            self,
            resource,
            get.id,
            Seat.pointerBinding(get.pointer),
        ) catch resource.postNoMemory(),
        .get_pinch_gesture => |get| Pinch.create(
            self,
            resource,
            get.id,
            Seat.pointerBinding(get.pointer),
        ) catch resource.postNoMemory(),
        .get_hold_gesture => |get| Hold.create(
            self,
            resource,
            get.id,
            Seat.pointerBinding(get.pointer),
        ) catch resource.postNoMemory(),
    }
}

const Swipe = struct {
    manager: *Self,
    resource: *zwp.PointerGestureSwipeV1,
    binding: ?Seat.PointerBinding,
    active: bool,

    fn create(
        manager: *Self,
        manager_resource: *zwp.PointerGesturesV1,
        id: u32,
        binding: ?Seat.PointerBinding,
    ) !void {
        const resource = try zwp.PointerGestureSwipeV1.create(
            manager_resource.getClient(),
            manager_resource.getVersion(),
            id,
        );
        errdefer resource.destroy();
        const self = try manager.allocator.create(Swipe);
        errdefer manager.allocator.destroy(self);
        self.* = .{
            .manager = manager,
            .resource = resource,
            .binding = binding,
            .active = false,
        };
        try manager.swipes.append(manager.allocator, self);
        resource.setHandler(*Swipe, handleRequest, handleDestroy, self);
    }

    fn handleRequest(
        resource: *zwp.PointerGestureSwipeV1,
        request: zwp.PointerGestureSwipeV1.Request,
        _: *Swipe,
    ) void {
        switch (request) {
            .destroy => resource.destroy(),
        }
    }

    fn handleDestroy(_: *zwp.PointerGestureSwipeV1, self: *Swipe) void {
        removeResource(Swipe, self.manager.allocator, &self.manager.swipes, self);
    }
};

const Pinch = struct {
    manager: *Self,
    resource: *zwp.PointerGesturePinchV1,
    binding: ?Seat.PointerBinding,
    active: bool,

    fn create(
        manager: *Self,
        manager_resource: *zwp.PointerGesturesV1,
        id: u32,
        binding: ?Seat.PointerBinding,
    ) !void {
        const resource = try zwp.PointerGesturePinchV1.create(
            manager_resource.getClient(),
            manager_resource.getVersion(),
            id,
        );
        errdefer resource.destroy();
        const self = try manager.allocator.create(Pinch);
        errdefer manager.allocator.destroy(self);
        self.* = .{
            .manager = manager,
            .resource = resource,
            .binding = binding,
            .active = false,
        };
        try manager.pinches.append(manager.allocator, self);
        resource.setHandler(*Pinch, handleRequest, handleDestroy, self);
    }

    fn handleRequest(
        resource: *zwp.PointerGesturePinchV1,
        request: zwp.PointerGesturePinchV1.Request,
        _: *Pinch,
    ) void {
        switch (request) {
            .destroy => resource.destroy(),
        }
    }

    fn handleDestroy(_: *zwp.PointerGesturePinchV1, self: *Pinch) void {
        removeResource(Pinch, self.manager.allocator, &self.manager.pinches, self);
    }
};

const Hold = struct {
    manager: *Self,
    resource: *zwp.PointerGestureHoldV1,
    binding: ?Seat.PointerBinding,
    active: bool,

    fn create(
        manager: *Self,
        manager_resource: *zwp.PointerGesturesV1,
        id: u32,
        binding: ?Seat.PointerBinding,
    ) !void {
        const resource = try zwp.PointerGestureHoldV1.create(
            manager_resource.getClient(),
            manager_resource.getVersion(),
            id,
        );
        errdefer resource.destroy();
        const self = try manager.allocator.create(Hold);
        errdefer manager.allocator.destroy(self);
        self.* = .{
            .manager = manager,
            .resource = resource,
            .binding = binding,
            .active = false,
        };
        try manager.holds.append(manager.allocator, self);
        resource.setHandler(*Hold, handleRequest, handleDestroy, self);
    }

    fn handleRequest(
        resource: *zwp.PointerGestureHoldV1,
        request: zwp.PointerGestureHoldV1.Request,
        _: *Hold,
    ) void {
        switch (request) {
            .destroy => resource.destroy(),
        }
    }

    fn handleDestroy(_: *zwp.PointerGestureHoldV1, self: *Hold) void {
        removeResource(Hold, self.manager.allocator, &self.manager.holds, self);
    }
};

fn bindingMatches(binding: ?Seat.PointerBinding, seat: *Seat) bool {
    const value = binding orelse return false;
    return value.seat == seat and value.isActive();
}

fn removeResource(
    comptime Resource: type,
    allocator: std.mem.Allocator,
    resources: *std.ArrayList(*Resource),
    resource: *Resource,
) void {
    for (resources.items, 0..) |candidate, index| {
        if (candidate != resource) continue;
        _ = resources.orderedRemove(index);
        allocator.destroy(resource);
        return;
    }
    unreachable;
}

fn fixed(value: f64) wl.Fixed {
    std.debug.assert(std.math.isFinite(value));
    const minimum = @as(f64, @floatFromInt(std.math.minInt(i32))) / 256.0;
    const maximum = @as(f64, @floatFromInt(std.math.maxInt(i32))) / 256.0;
    return wl.Fixed.fromDouble(std.math.clamp(value, minimum, maximum));
}

test "gesture values clamp to the Wayland fixed-point range" {
    try std.testing.expectEqual(std.math.maxInt(i32), @intFromEnum(fixed(1.0e20)));
    try std.testing.expectEqual(std.math.minInt(i32), @intFromEnum(fixed(-1.0e20)));
}
