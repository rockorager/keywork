//! Client-authorized pointer warping without synthetic motion events.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Seat = @import("seat.zig");
const Surface = @import("surface.zig");

const wl = wayland.server.wl;
const wp = wayland.server.wp;

global: *wl.Global,
seat: *Seat,
surface_store: *Surface.Store,
listener: Listener,

pub const Listener = struct {
    context: *anyopaque,
    warp: *const fn (*anyopaque, Surface.Id, f64, f64) void,
};

pub fn init(
    self: *Self,
    display: *wl.Server,
    seat: *Seat,
    surface_store: *Surface.Store,
    listener: Listener,
) !void {
    self.* = .{
        .global = try wl.Global.create(display, wp.PointerWarpV1, 1, *Self, self, bind),
        .seat = seat,
        .surface_store = surface_store,
        .listener = listener,
    };
}

pub fn deinit(self: *Self) void {
    self.global.destroy();
    self.* = undefined;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = wp.PointerWarpV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleRequest, null, self);
}

fn handleRequest(resource: *wp.PointerWarpV1, request: wp.PointerWarpV1.Request, self: *Self) void {
    switch (request) {
        .destroy => resource.destroy(),
        .warp_pointer => |warp| {
            const pointer = self.seat.pointerHandle(warp.pointer) orelse return;
            const surface = Surface.fromResource(warp.surface);
            const surface_id = surface.handle();
            if (!self.seat.acceptsPointerEnterSerial(pointer, surface_id, warp.serial)) return;
            const size = Surface.currentLogicalSize(self.surface_store, surface_id) orelse return;
            const x = warp.x.toDouble();
            const y = warp.y.toDouble();
            if (!pointWithinSurface(x, y, size.width, size.height)) return;
            self.listener.warp(self.listener.context, surface_id, x, y);
        },
    }
}

fn pointWithinSurface(x: f64, y: f64, width: u32, height: u32) bool {
    return x >= 0 and y >= 0 and
        x < @as(f64, @floatFromInt(width)) and
        y < @as(f64, @floatFromInt(height));
}

test "warp coordinates must be inside the surface" {
    try std.testing.expect(pointWithinSurface(0, 0, 100, 50));
    try std.testing.expect(pointWithinSurface(99.99, 49.99, 100, 50));
    try std.testing.expect(!pointWithinSurface(-0.01, 10, 100, 50));
    try std.testing.expect(!pointWithinSurface(10, -0.01, 100, 50));
    try std.testing.expect(!pointWithinSurface(100, 10, 100, 50));
    try std.testing.expect(!pointWithinSurface(10, 50, 100, 50));
    try std.testing.expect(!pointWithinSurface(0, 0, 0, 0));
}
