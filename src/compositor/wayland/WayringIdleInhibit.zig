//! Scanner-backed idle-inhibit unstable-v1 adapter.

const Self = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayring = @import("wayring");
const CompositorServer = @import("../server.zig");
const WayringCompositor = @import("WayringCompositor.zig");

const server = wayring.server;

const Manager = struct {
    owner: *Self,
    client: *server.Client,
    resource: protocol.zwp_idle_inhibit_manager_v1.Resource,
};

const Inhibitor = struct {
    owner: *Self,
    client: *server.Client,
    resource: protocol.zwp_idle_inhibitor_v1.Resource,
    surface: WayringCompositor.SurfaceId,
    observer: ?*server.Resource.Observer,
};

allocator: std.mem.Allocator,
protocol_server: *server.Server,
compositor: *WayringCompositor,
compositor_server: *CompositorServer,
global: ?*const server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
inhibitors: std.ArrayList(*Inhibitor) = .empty,

pub fn init(self: *Self, allocator: std.mem.Allocator, protocol_server: *server.Server, compositor: *WayringCompositor, compositor_server: *CompositorServer) void {
    self.* = .{ .allocator = allocator, .protocol_server = protocol_server, .compositor = compositor, .compositor_server = compositor_server };
}

pub fn publish(self: *Self) !void {
    self.global = try self.protocol_server.addGlobal(protocol.zwp_idle_inhibit_manager_v1, 1, Self, self, bind);
}

pub fn unpublish(self: *Self) void {
    self.protocol_server.removeGlobal(self.global orelse unreachable) catch {};
    self.global = null;
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.global == null and self.managers.items.len == 0 and self.inhibitors.items.len == 0);
    self.inhibitors.deinit(self.allocator);
    self.managers.deinit(self.allocator);
    self.* = undefined;
}

pub fn provider(self: *Self) CompositorServer.GeneratedIdleInhibitProvider {
    return .{ .context = self, .has_visible = hasVisible };
}

fn hasVisible(context: *anyopaque, visibility_context: *anyopaque, visible: *const fn (*anyopaque, WayringCompositor.SurfaceId) bool) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    for (self.inhibitors.items) |inhibitor| {
        if (inhibitor.observer != null and visible(visibility_context, inhibitor.surface)) return true;
    }
    return false;
}

fn bind(client: *server.Client, id: u32, version: u32, self: *Self) !void {
    if (version != 1) return error.InvalidVersion;
    try self.managers.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Manager);
    errdefer self.allocator.destroy(value);
    value.* = .{ .owner = self, .client = client, .resource = .init(self.allocator, id, version, .client, client.ownerHooks()) };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Manager, value, managerRequest, null);
    try client.materialize(&value.resource.runtime);
    self.managers.appendAssumeCapacity(value);
}

fn managerRequest(_: *protocol.zwp_idle_inhibit_manager_v1.Resource, request: protocol.zwp_idle_inhibit_manager_v1.Request, value: *Manager) !void {
    switch (request) {
        .destroy => value.owner.destroyManager(value),
        .create_inhibitor => |args| try value.owner.createInhibitor(value, args.id, args.surface),
    }
}

fn createInhibitor(self: *Self, manager: *Manager, id: u32, surface_object: u32) !void {
    try self.inhibitors.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Inhibitor);
    errdefer self.allocator.destroy(value);
    value.* = .{ .owner = self, .client = manager.client, .resource = .init(self.allocator, id, 1, .client, manager.client.ownerHooks()), .surface = undefined, .observer = null };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    const observed = try self.compositor.observeSurfaceDestruction(manager.client, surface_object, Inhibitor, value, surfaceDestroyed) orelse {
        manager.client.postImplementationError(&manager.resource.runtime, "idle inhibitor requires the exact live same-client generated wl_surface");
        return;
    };
    value.surface = observed.id;
    value.observer = observed.observer;
    errdefer server.Resource.removeDestroyObserver(observed.observer);
    try value.resource.setHandler(Inhibitor, value, inhibitorRequest, null);
    try manager.client.materialize(&value.resource.runtime);
    self.inhibitors.appendAssumeCapacity(value);
    self.compositor_server.refreshIdleInhibition();
}

fn inhibitorRequest(_: *protocol.zwp_idle_inhibitor_v1.Resource, request: protocol.zwp_idle_inhibitor_v1.Request, value: *Inhibitor) !void {
    switch (request) {
        .destroy => value.owner.destroyInhibitor(value),
    }
}

fn surfaceDestroyed(value: *Inhibitor, _: *server.Resource, _: *server.Resource.Observer) void {
    value.observer = null;
    value.owner.compositor_server.refreshIdleInhibition();
}

pub fn destroyClientResources(self: *Self, client: *server.Client) void {
    var index = self.inhibitors.items.len;
    while (index > 0) {
        index -= 1;
        if (self.inhibitors.items[index].client == client) self.destroyInhibitor(self.inhibitors.items[index]);
    }
    index = self.managers.items.len;
    while (index > 0) {
        index -= 1;
        if (self.managers.items[index].client == client) self.destroyManager(self.managers.items[index]);
    }
}

fn destroyInhibitor(self: *Self, value: *Inhibitor) void {
    if (value.observer) |observer| server.Resource.removeDestroyObserver(observer);
    remove(Inhibitor, &self.inhibitors, value);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
    self.compositor_server.refreshIdleInhibition();
}

fn destroyManager(self: *Self, value: *Manager) void {
    remove(Manager, &self.managers, value);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}

fn remove(comptime T: type, list: *std.ArrayList(*T), value: *T) void {
    for (list.items, 0..) |candidate, index| if (candidate == value) {
        _ = list.swapRemove(index);
        return;
    };
    unreachable;
}

test "idle inhibit descriptors pin unstable v1" {
    try std.testing.expectEqual(@as(u32, 1), protocol.zwp_idle_inhibit_manager_v1.interface.version);
    try std.testing.expectEqual(@as(usize, 2), protocol.zwp_idle_inhibit_manager_v1.request_messages.len);
    try std.testing.expect(protocol.zwp_idle_inhibit_manager_v1.request_messages[0].destructor);
    try std.testing.expectEqualStrings("create_inhibitor", protocol.zwp_idle_inhibit_manager_v1.request_messages[1].name);
    try std.testing.expectEqual(@as(usize, 1), protocol.zwp_idle_inhibitor_v1.request_messages.len);
    try std.testing.expect(protocol.zwp_idle_inhibitor_v1.request_messages[0].destructor);
}
