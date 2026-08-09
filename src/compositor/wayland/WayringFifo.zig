//! Scanner-backed display-refresh FIFO constraints for generated surfaces.

const WayringFifo = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayring = @import("wayring");
const WayringCompositor = @import("WayringCompositor.zig");

const server = wayring.server;

const Manager = struct {
    owner: *WayringFifo,
    client: *server.Client,
    resource: protocol.wp_fifo_manager_v1.Resource,
};

const Fifo = struct {
    owner: *WayringFifo,
    client: *server.Client,
    resource: protocol.wp_fifo_v1.Resource,
    surface: ?WayringCompositor.SurfaceId,
};

allocator: std.mem.Allocator,
protocol_server: *server.Server,
compositor: *WayringCompositor,
global: ?*const server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
fifos: std.ArrayList(*Fifo) = .empty,

pub fn init(self: *WayringFifo, allocator: std.mem.Allocator, protocol_server: *server.Server, compositor: *WayringCompositor) void {
    self.* = .{ .allocator = allocator, .protocol_server = protocol_server, .compositor = compositor };
}

pub fn publish(self: *WayringFifo) !void {
    self.global = try self.protocol_server.addGlobal(protocol.wp_fifo_manager_v1, 1, WayringFifo, self, bind);
}

pub fn unpublish(self: *WayringFifo) void {
    self.protocol_server.removeGlobal(self.global.?) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}

pub fn destroyClientResources(self: *WayringFifo, client: *server.Client) void {
    var i = self.fifos.items.len;
    while (i > 0) {
        i -= 1;
        if (self.fifos.items[i].client == client) self.destroyFifo(self.fifos.items[i]);
    }
    i = self.managers.items.len;
    while (i > 0) {
        i -= 1;
        if (self.managers.items[i].client == client) self.destroyManager(self.managers.items[i]);
    }
}

pub fn deinit(self: *WayringFifo) void {
    std.debug.assert(self.global == null and self.fifos.items.len == 0 and self.managers.items.len == 0);
    self.fifos.deinit(self.allocator);
    self.managers.deinit(self.allocator);
    self.* = undefined;
}

fn bind(client: *server.Client, id: u32, version: u32, self: *WayringFifo) !void {
    try self.managers.ensureUnusedCapacity(self.allocator, 1);
    const manager = try self.allocator.create(Manager);
    errdefer self.allocator.destroy(manager);
    manager.* = .{
        .owner = self,
        .client = client,
        .resource = .init(self.allocator, id, version, .client, client.ownerHooks()),
    };
    errdefer {
        manager.resource.destroy();
        manager.resource.deinit();
    }
    try manager.resource.setHandler(Manager, manager, handleManager, null);
    try client.materialize(&manager.resource.runtime);
    self.managers.appendAssumeCapacity(manager);
}

fn handleManager(_: *protocol.wp_fifo_manager_v1.Resource, request: protocol.wp_fifo_manager_v1.Request, manager: *Manager) !void {
    switch (request) {
        .destroy => manager.owner.destroyManager(manager),
        .get_fifo => |args| try manager.owner.createFifo(manager, args.id, args.surface),
    }
}

fn createFifo(self: *WayringFifo, manager: *Manager, id: u32, surface_object: u32) !void {
    try self.fifos.ensureUnusedCapacity(self.allocator, 1);
    const fifo = try self.allocator.create(Fifo);
    errdefer self.allocator.destroy(fifo);
    fifo.* = .{ .owner = self, .client = manager.client, .resource = undefined, .surface = null };
    switch (self.compositor.attachFifo(manager.client, surface_object, .{
        .context = fifo,
        .surface_destroyed = surfaceDestroyed,
    })) {
        .attached => |surface| fifo.surface = surface,
        .already_exists => {
            self.allocator.destroy(fifo);
            manager.client.postProtocolError(&manager.resource.runtime, @intCast(protocol.wp_fifo_manager_v1.@"error".already_exists), "wl_surface already has a FIFO object");
            return;
        },
        .not_live, .wrong_client => {
            self.allocator.destroy(fifo);
            manager.client.postImplementationError(&manager.resource.runtime, "surface is not an exact live same-client Wayring wl_surface");
            return;
        },
    }
    errdefer self.compositor.detachFifo(fifo.surface.?, fifo);
    fifo.resource = .init(self.allocator, id, 1, .client, manager.client.ownerHooks());
    errdefer {
        fifo.resource.destroy();
        fifo.resource.deinit();
    }
    try fifo.resource.setHandler(Fifo, fifo, handleFifo, null);
    try manager.client.materialize(&fifo.resource.runtime);
    self.fifos.appendAssumeCapacity(fifo);
}

fn handleFifo(resource: *protocol.wp_fifo_v1.Resource, request: protocol.wp_fifo_v1.Request, fifo: *Fifo) !void {
    switch (request) {
        .destroy => fifo.owner.destroyFifo(fifo),
        .set_barrier => if (fifo.surface) |surface| {
            _ = fifo.owner.compositor.setPendingFifoBarrier(surface, fifo);
        } else postSurfaceDestroyed(resource, fifo.client),
        .wait_barrier => if (fifo.surface) |surface| {
            _ = fifo.owner.compositor.setPendingFifoWait(surface, fifo);
        } else postSurfaceDestroyed(resource, fifo.client),
    }
}

fn postSurfaceDestroyed(resource: *protocol.wp_fifo_v1.Resource, client: *server.Client) void {
    client.postProtocolError(&resource.runtime, @intCast(protocol.wp_fifo_v1.@"error".surface_destroyed), "wl_surface no longer exists");
}

fn surfaceDestroyed(context: *anyopaque) void {
    const fifo: *Fifo = @ptrCast(@alignCast(context));
    fifo.surface = null;
}

fn destroyFifo(self: *WayringFifo, fifo: *Fifo) void {
    if (fifo.surface) |surface| self.compositor.detachFifo(surface, fifo);
    remove(Fifo, &self.fifos, fifo);
    fifo.resource.destroy();
    fifo.resource.deinit();
    self.allocator.destroy(fifo);
}

fn destroyManager(self: *WayringFifo, manager: *Manager) void {
    remove(Manager, &self.managers, manager);
    manager.resource.destroy();
    manager.resource.deinit();
    self.allocator.destroy(manager);
}

fn remove(comptime T: type, list: *std.ArrayList(*T), value: *T) void {
    for (list.items, 0..) |item, i| if (item == value) {
        _ = list.swapRemove(i);
        return;
    };
    unreachable;
}

test "fifo protocol descriptors are version one" {
    try std.testing.expectEqual(@as(u32, 1), protocol.wp_fifo_manager_v1.interface.version);
    try std.testing.expectEqualStrings("get_fifo", protocol.wp_fifo_manager_v1.request_messages[1].name);
    try std.testing.expectEqualStrings("set_barrier", protocol.wp_fifo_v1.request_messages[0].name);
    try std.testing.expectEqualStrings("wait_barrier", protocol.wp_fifo_v1.request_messages[1].name);
}
