//! Resource-only cursor-shape adapter for generated Wayring pointers.

const WayringCursorShape = @This();

const std = @import("std");
const core = @import("wayring-protocol");
const wayring = @import("wayring");
const SeatDelivery = @import("../SeatDelivery.zig");
const CursorShape = @import("cursor_shape.zig");
const WayringSeatAdapter = @import("WayringSeatAdapter.zig");

const Manager = struct {
    owner: *WayringCursorShape,
    client: *wayring.server.Client,
    resource: core.wp_cursor_shape_manager_v1.Resource,
};

const Device = struct {
    owner: *WayringCursorShape,
    client: *wayring.server.Client,
    resource: core.wp_cursor_shape_device_v1.Resource,
    pointer_object: u32,
    identity: WayringSeatAdapter.PointerIdentity,
};

allocator: std.mem.Allocator,
protocol_server: *wayring.server.Server,
seat: *WayringSeatAdapter,
shapes: *CursorShape,
request_sink: SeatDelivery.RequestSink,
global: ?*const wayring.server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
devices: std.ArrayList(*Device) = .empty,

pub fn init(self: *WayringCursorShape, allocator: std.mem.Allocator, protocol_server: *wayring.server.Server, seat: *WayringSeatAdapter, shapes: *CursorShape, request_sink: SeatDelivery.RequestSink) void {
    self.* = .{ .allocator = allocator, .protocol_server = protocol_server, .seat = seat, .shapes = shapes, .request_sink = request_sink };
}

pub fn publish(self: *WayringCursorShape) !void {
    self.global = try self.protocol_server.addGlobal(
        core.wp_cursor_shape_manager_v1,
        core.wp_cursor_shape_manager_v1.interface.version,
        WayringCursorShape,
        self,
        bind,
    );
}

pub fn unpublish(self: *WayringCursorShape) void {
    self.protocol_server.removeGlobal(self.global.?) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}

pub fn destroyClientResources(self: *WayringCursorShape, client: *wayring.server.Client) void {
    var i = self.devices.items.len;
    while (i > 0) {
        i -= 1;
        if (self.devices.items[i].client == client) self.destroyDevice(self.devices.items[i]);
    }
    i = self.managers.items.len;
    while (i > 0) {
        i -= 1;
        if (self.managers.items[i].client == client) self.destroyManager(self.managers.items[i]);
    }
}

pub fn deinit(self: *WayringCursorShape) void {
    std.debug.assert(self.global == null and self.managers.items.len == 0 and self.devices.items.len == 0);
    self.devices.deinit(self.allocator);
    self.managers.deinit(self.allocator);
    self.* = undefined;
}

pub fn managerCount(self: *const WayringCursorShape) usize {
    return self.managers.items.len;
}

pub fn deviceCount(self: *const WayringCursorShape) usize {
    return self.devices.items.len;
}

fn bind(client: *wayring.server.Client, id: u32, version: u32, self: *WayringCursorShape) !void {
    try self.managers.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Manager);
    errdefer self.allocator.destroy(value);
    value.* = .{ .owner = self, .client = client, .resource = .init(self.allocator, id, version, .client, client.ownerHooks()) };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Manager, value, handleManager, null);
    try client.materialize(&value.resource.runtime);
    self.managers.appendAssumeCapacity(value);
}

fn handleManager(_: *core.wp_cursor_shape_manager_v1.Resource, request: core.wp_cursor_shape_manager_v1.Request, value: *Manager) !void {
    switch (request) {
        .destroy => value.owner.destroyManager(value),
        .get_pointer => |args| try value.owner.getPointer(value, args.cursor_shape_device, args.pointer),
        .get_tablet_tool_v2 => value.client.postImplementationError(&value.resource.runtime, "generated tablet tools are unavailable"),
    }
}

fn getPointer(self: *WayringCursorShape, manager: *Manager, id: u32, pointer: u32) !void {
    const identity = self.seat.pointerIdentity(manager.client, pointer) orelse {
        manager.client.postImplementationError(&manager.resource.runtime, "pointer is not an exact live same-client generated wl_pointer");
        return;
    };
    try self.devices.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Device);
    errdefer self.allocator.destroy(value);
    value.* = .{
        .owner = self,
        .client = manager.client,
        .resource = .init(self.allocator, id, manager.resource.version(), .client, manager.client.ownerHooks()),
        .pointer_object = pointer,
        .identity = identity,
    };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Device, value, handleDevice, null);
    try manager.client.materialize(&value.resource.runtime);
    self.devices.appendAssumeCapacity(value);
}

fn handleDevice(_: *core.wp_cursor_shape_device_v1.Resource, request: core.wp_cursor_shape_device_v1.Request, value: *Device) !void {
    switch (request) {
        .destroy => value.owner.destroyDevice(value),
        .set_shape => |args| {
            if (!CursorShape.generatedShapeValid(args.shape, value.resource.version())) {
                value.client.postProtocolError(&value.resource.runtime, @intCast(core.wp_cursor_shape_device_v1.@"error".invalid_shape), "unknown cursor shape for protocol version");
                return;
            }
            if (!value.owner.seat.acceptsCursorShape(value.client, value.pointer_object, value.identity, args.serial)) return;
            const image = value.owner.shapes.generatedCursorImage(args.shape, value.resource.version()) orelse {
                value.client.postOutOfMemory(&value.resource.runtime, "loading cursor shape image");
                return;
            };
            _ = value.owner.request_sink.set_shape(value.owner.request_sink.context, .{
                .client = value.identity.client,
                .resource_generation = value.identity.resource_generation,
                .capability_generation = value.identity.capability_generation,
                .serial = .{ .domain = .wayring_server, .value = args.serial },
                .image = .{ .buffer = image.buffer, .hotspot_x = image.hotspot_x, .hotspot_y = image.hotspot_y },
            });
        },
    }
}

fn destroyDevice(self: *WayringCursorShape, value: *Device) void {
    remove(Device, &self.devices, value);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}
fn destroyManager(self: *WayringCursorShape, value: *Manager) void {
    remove(Manager, &self.managers, value);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}
fn remove(comptime T: type, list: *std.ArrayList(*T), value: *T) void {
    for (list.items, 0..) |item, i| if (item == value) {
        _ = list.swapRemove(i);
        return;
    };
    unreachable;
}

test "generated cursor shape descriptors preserve pinned version two" {
    try std.testing.expectEqual(@as(u32, 2), core.wp_cursor_shape_manager_v1.interface.version);
    try std.testing.expectEqual(@as(u32, 2), core.wp_cursor_shape_device_v1.interface.version);
    try std.testing.expectEqualStrings("get_pointer", core.wp_cursor_shape_manager_v1.request_messages[1].name);
    try std.testing.expectEqualStrings("set_shape", core.wp_cursor_shape_device_v1.request_messages[1].name);
}
