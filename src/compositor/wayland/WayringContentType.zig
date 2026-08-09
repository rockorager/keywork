//! Scanner-backed content-type hints for generated surfaces.

const WayringContentType = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayring = @import("wayring");
const WayringCompositor = @import("WayringCompositor.zig");

const server = wayring.server;

const Manager = struct { owner: *WayringContentType, client: *server.Client, resource: protocol.wp_content_type_manager_v1.Resource };
const Value = struct {
    owner: *WayringContentType,
    client: *server.Client,
    resource: protocol.wp_content_type_v1.Resource,
    surface: ?WayringCompositor.SurfaceId,
};

allocator: std.mem.Allocator,
protocol_server: *server.Server,
compositor: *WayringCompositor,
global: ?*const server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
values: std.ArrayList(*Value) = .empty,

pub fn init(self: *WayringContentType, allocator: std.mem.Allocator, protocol_server: *server.Server, compositor: *WayringCompositor) void {
    self.* = .{ .allocator = allocator, .protocol_server = protocol_server, .compositor = compositor };
}
pub fn publish(self: *WayringContentType) !void {
    self.global = try self.protocol_server.addGlobal(protocol.wp_content_type_manager_v1, 1, WayringContentType, self, bind);
}
pub fn unpublish(self: *WayringContentType) void {
    self.protocol_server.removeGlobal(self.global.?) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}
pub fn destroyClientResources(self: *WayringContentType, client: *server.Client) void {
    var i = self.values.items.len;
    while (i > 0) {
        i -= 1;
        if (self.values.items[i].client == client) self.destroyValue(self.values.items[i]);
    }
    i = self.managers.items.len;
    while (i > 0) {
        i -= 1;
        if (self.managers.items[i].client == client) self.destroyManager(self.managers.items[i]);
    }
}
pub fn deinit(self: *WayringContentType) void {
    std.debug.assert(self.global == null and self.values.items.len == 0 and self.managers.items.len == 0);
    self.values.deinit(self.allocator);
    self.managers.deinit(self.allocator);
    self.* = undefined;
}
fn bind(client: *server.Client, id: u32, version: u32, self: *WayringContentType) !void {
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
fn handleManager(_: *protocol.wp_content_type_manager_v1.Resource, request: protocol.wp_content_type_manager_v1.Request, value: *Manager) !void {
    switch (request) {
        .destroy => value.owner.destroyManager(value),
        .get_surface_content_type => |args| try value.owner.create(value, args.id, args.surface),
    }
}
fn create(self: *WayringContentType, manager: *Manager, id: u32, surface_object: u32) !void {
    try self.values.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Value);
    errdefer self.allocator.destroy(value);
    value.* = .{ .owner = self, .client = manager.client, .resource = undefined, .surface = null };
    switch (self.compositor.attachContentType(manager.client, surface_object, .{ .context = value, .surface_destroyed = surfaceDestroyed })) {
        .attached => |surface| value.surface = surface,
        .already_constructed => {
            self.allocator.destroy(value);
            manager.client.postProtocolError(&manager.resource.runtime, @intCast(protocol.wp_content_type_manager_v1.@"error".already_constructed), "wl_surface already has a content type object");
            return;
        },
        .not_live, .wrong_client => {
            self.allocator.destroy(value);
            manager.client.postImplementationError(&manager.resource.runtime, "surface is not an exact live same-client Wayring wl_surface");
            return;
        },
    }
    errdefer self.compositor.detachContentType(value.surface.?, value);
    value.resource = .init(self.allocator, id, 1, .client, manager.client.ownerHooks());
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Value, value, handleValue, null);
    try manager.client.materialize(&value.resource.runtime);
    self.values.appendAssumeCapacity(value);
}
fn handleValue(_: *protocol.wp_content_type_v1.Resource, request: protocol.wp_content_type_v1.Request, value: *Value) !void {
    switch (request) {
        .destroy => value.owner.destroyValue(value),
        .set_content_type => |args| if (value.surface) |surface| {
            _ = value.owner.compositor.setPendingContentType(surface, value, @enumFromInt(args.content_type));
        },
    }
}
fn surfaceDestroyed(context: *anyopaque) void {
    const value: *Value = @ptrCast(@alignCast(context));
    value.surface = null;
}
fn destroyValue(self: *WayringContentType, value: *Value) void {
    if (value.surface) |surface| self.compositor.detachContentType(surface, value);
    remove(Value, &self.values, value);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}
fn destroyManager(self: *WayringContentType, value: *Manager) void {
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

test "content type protocol descriptors are version one" {
    try std.testing.expectEqual(@as(u32, 1), protocol.wp_content_type_manager_v1.interface.version);
    try std.testing.expectEqualStrings("get_surface_content_type", protocol.wp_content_type_manager_v1.request_messages[1].name);
    try std.testing.expectEqualStrings("set_content_type", protocol.wp_content_type_v1.request_messages[1].name);
}
