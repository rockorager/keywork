//! Client-authorized pointer warping for generated Wayring surfaces.

const WayringPointerWarp = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayring = @import("wayring");
const SurfaceRegistry = @import("../SurfaceRegistry.zig");
const WayringCompositor = @import("WayringCompositor.zig");
const WayringSeatAdapter = @import("WayringSeatAdapter.zig");

pub const Listener = struct {
    context: *anyopaque,
    warp: *const fn (*anyopaque, SurfaceRegistry.Id, f64, f64) void,
};

const Resource = struct {
    owner: *WayringPointerWarp,
    client: *wayring.server.Client,
    resource: protocol.wp_pointer_warp_v1.Resource,
};

allocator: std.mem.Allocator,
protocol_server: *wayring.server.Server,
compositor: *WayringCompositor,
seat: *WayringSeatAdapter,
listener: Listener,
global: ?*const wayring.server.Server.Global = null,
resources: std.ArrayList(*Resource) = .empty,

pub fn init(
    self: *WayringPointerWarp,
    allocator: std.mem.Allocator,
    protocol_server: *wayring.server.Server,
    compositor: *WayringCompositor,
    seat: *WayringSeatAdapter,
    listener: Listener,
) void {
    self.* = .{
        .allocator = allocator,
        .protocol_server = protocol_server,
        .compositor = compositor,
        .seat = seat,
        .listener = listener,
    };
}

pub fn publish(self: *WayringPointerWarp) !void {
    std.debug.assert(self.global == null);
    self.global = try self.protocol_server.addGlobal(
        protocol.wp_pointer_warp_v1,
        1,
        WayringPointerWarp,
        self,
        bind,
    );
}

pub fn unpublish(self: *WayringPointerWarp) void {
    const global = self.global orelse return;
    self.protocol_server.removeGlobal(global) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}

pub fn destroyClientResources(self: *WayringPointerWarp, client: *wayring.server.Client) void {
    var index = self.resources.items.len;
    while (index > 0) {
        index -= 1;
        if (self.resources.items[index].client == client) self.destroyResource(self.resources.items[index]);
    }
}

pub fn deinit(self: *WayringPointerWarp) void {
    std.debug.assert(self.global == null and self.resources.items.len == 0);
    self.resources.deinit(self.allocator);
    self.* = undefined;
}

fn bind(client: *wayring.server.Client, id: u32, version: u32, self: *WayringPointerWarp) !void {
    try self.resources.ensureUnusedCapacity(self.allocator, 1);
    const resource = try self.allocator.create(Resource);
    errdefer self.allocator.destroy(resource);
    resource.* = .{
        .owner = self,
        .client = client,
        .resource = .init(self.allocator, id, version, .client, client.ownerHooks()),
    };
    errdefer {
        resource.resource.destroy();
        resource.resource.deinit();
    }
    try resource.resource.setHandler(Resource, resource, handleRequest, null);
    try client.materialize(&resource.resource.runtime);
    self.resources.appendAssumeCapacity(resource);
}

fn handleRequest(
    _: *protocol.wp_pointer_warp_v1.Resource,
    request: protocol.wp_pointer_warp_v1.Request,
    resource: *Resource,
) !void {
    switch (request) {
        .destroy => resource.owner.destroyResource(resource),
        .warp_pointer => |warp| resource.owner.warpPointer(resource, warp.surface, warp.pointer, warp.x, warp.y, warp.serial),
    }
}

fn warpPointer(
    self: *WayringPointerWarp,
    resource: *Resource,
    surface_object: u32,
    pointer_object: u32,
    x_fixed: i32,
    y_fixed: i32,
    serial: u32,
) void {
    const surface = self.compositor.surfaceId(resource.client, surface_object) orelse return;
    _ = self.seat.pointerIdentity(resource.client, pointer_object) orelse return;
    if (!self.seat.acceptsPointerEnterSerial(resource.client, pointer_object, serial)) return;
    const size = self.compositor.currentLogicalSize(surface) orelse return;
    const x = fixedDouble(x_fixed);
    const y = fixedDouble(y_fixed);
    if (!pointWithinSurface(x, y, size.width, size.height)) return;
    self.listener.warp(self.listener.context, surface, x, y);
}

fn destroyResource(self: *WayringPointerWarp, resource: *Resource) void {
    for (self.resources.items, 0..) |candidate, index| {
        if (candidate != resource) continue;
        _ = self.resources.swapRemove(index);
        resource.resource.destroy();
        resource.resource.deinit();
        self.allocator.destroy(resource);
        return;
    }
}

fn fixedDouble(value: i32) f64 {
    return @as(f64, @floatFromInt(value)) / 256.0;
}

fn pointWithinSurface(x: f64, y: f64, width: u32, height: u32) bool {
    return x >= 0 and y >= 0 and
        x < @as(f64, @floatFromInt(width)) and
        y < @as(f64, @floatFromInt(height));
}

test "pointer warp descriptor and surface bounds match the protocol" {
    try std.testing.expectEqual(@as(u32, 1), protocol.wp_pointer_warp_v1.interface.version);
    try std.testing.expectEqualStrings("warp_pointer", protocol.wp_pointer_warp_v1.request_messages[1].name);
    try std.testing.expect(pointWithinSurface(0, 0, 100, 50));
    try std.testing.expect(pointWithinSurface(99.99, 49.99, 100, 50));
    try std.testing.expect(!pointWithinSurface(-0.01, 10, 100, 50));
    try std.testing.expect(!pointWithinSurface(100, 10, 100, 50));
    try std.testing.expect(!pointWithinSurface(0, 0, 0, 0));
}
