//! Scanner-backed per-surface alpha multiplier state.

const WayringAlphaModifier = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayring = @import("wayring");
const WayringCompositor = @import("WayringCompositor.zig");

const server = wayring.server;

const Manager = struct {
    owner: *WayringAlphaModifier,
    client: *server.Client,
    resource: protocol.wp_alpha_modifier_v1.Resource,
};

const Modifier = struct {
    owner: *WayringAlphaModifier,
    client: *server.Client,
    resource: protocol.wp_alpha_modifier_surface_v1.Resource,
    surface: ?WayringCompositor.SurfaceId,
};

allocator: std.mem.Allocator,
protocol_server: *server.Server,
compositor: *WayringCompositor,
global: ?*const server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
modifiers: std.ArrayList(*Modifier) = .empty,

pub fn init(self: *WayringAlphaModifier, allocator: std.mem.Allocator, protocol_server: *server.Server, compositor: *WayringCompositor) void {
    self.* = .{ .allocator = allocator, .protocol_server = protocol_server, .compositor = compositor };
}

pub fn publish(self: *WayringAlphaModifier) !void {
    self.global = try self.protocol_server.addGlobal(protocol.wp_alpha_modifier_v1, 1, WayringAlphaModifier, self, bind);
}

pub fn unpublish(self: *WayringAlphaModifier) void {
    self.protocol_server.removeGlobal(self.global.?) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}

pub fn destroyClientResources(self: *WayringAlphaModifier, client: *server.Client) void {
    var i = self.modifiers.items.len;
    while (i > 0) {
        i -= 1;
        if (self.modifiers.items[i].client == client) self.destroyModifier(self.modifiers.items[i]);
    }
    i = self.managers.items.len;
    while (i > 0) {
        i -= 1;
        if (self.managers.items[i].client == client) self.destroyManager(self.managers.items[i]);
    }
}

pub fn deinit(self: *WayringAlphaModifier) void {
    std.debug.assert(self.global == null and self.modifiers.items.len == 0 and self.managers.items.len == 0);
    self.modifiers.deinit(self.allocator);
    self.managers.deinit(self.allocator);
    self.* = undefined;
}

fn bind(client: *server.Client, id: u32, version: u32, self: *WayringAlphaModifier) !void {
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

fn handleManager(_: *protocol.wp_alpha_modifier_v1.Resource, request: protocol.wp_alpha_modifier_v1.Request, manager: *Manager) !void {
    switch (request) {
        .destroy => manager.owner.destroyManager(manager),
        .get_surface => |args| try manager.owner.createModifier(manager, args.id, args.surface),
    }
}

fn createModifier(self: *WayringAlphaModifier, manager: *Manager, id: u32, surface_object: u32) !void {
    try self.modifiers.ensureUnusedCapacity(self.allocator, 1);
    const modifier = try self.allocator.create(Modifier);
    errdefer self.allocator.destroy(modifier);
    modifier.* = .{
        .owner = self,
        .client = manager.client,
        .resource = undefined,
        .surface = null,
    };
    switch (self.compositor.attachAlphaModifier(manager.client, surface_object, .{
        .context = modifier,
        .surface_destroyed = surfaceDestroyed,
    })) {
        .attached => |surface| modifier.surface = surface,
        .already_constructed => {
            self.allocator.destroy(modifier);
            manager.client.postProtocolError(&manager.resource.runtime, @intCast(protocol.wp_alpha_modifier_v1.@"error".already_constructed), "wl_surface already has an alpha modifier object");
            return;
        },
        .not_live, .wrong_client => {
            self.allocator.destroy(modifier);
            manager.client.postImplementationError(&manager.resource.runtime, "surface is not an exact live same-client Wayring wl_surface");
            return;
        },
    }
    errdefer self.compositor.detachAlphaModifier(modifier.surface.?, modifier);
    modifier.resource = .init(self.allocator, id, 1, .client, manager.client.ownerHooks());
    errdefer {
        modifier.resource.destroy();
        modifier.resource.deinit();
    }
    try modifier.resource.setHandler(Modifier, modifier, handleModifier, null);
    try manager.client.materialize(&modifier.resource.runtime);
    self.modifiers.appendAssumeCapacity(modifier);
}

fn handleModifier(_: *protocol.wp_alpha_modifier_surface_v1.Resource, request: protocol.wp_alpha_modifier_surface_v1.Request, modifier: *Modifier) !void {
    switch (request) {
        .destroy => modifier.owner.destroyModifier(modifier),
        .set_multiplier => |args| {
            const surface = modifier.surface orelse {
                modifier.client.postProtocolError(&modifier.resource.runtime, @intCast(protocol.wp_alpha_modifier_surface_v1.@"error".no_surface), "wl_surface has been destroyed");
                return;
            };
            _ = modifier.owner.compositor.setPendingAlphaMultiplier(surface, modifier, args.factor);
        },
    }
}

fn surfaceDestroyed(context: *anyopaque) void {
    const modifier: *Modifier = @ptrCast(@alignCast(context));
    modifier.surface = null;
}

fn destroyModifier(self: *WayringAlphaModifier, modifier: *Modifier) void {
    if (modifier.surface) |surface| self.compositor.detachAlphaModifier(surface, modifier);
    remove(Modifier, &self.modifiers, modifier);
    modifier.resource.destroy();
    modifier.resource.deinit();
    self.allocator.destroy(modifier);
}

fn destroyManager(self: *WayringAlphaModifier, manager: *Manager) void {
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

test "alpha modifier protocol descriptors are version one" {
    try std.testing.expectEqual(@as(u32, 1), protocol.wp_alpha_modifier_v1.interface.version);
    try std.testing.expectEqualStrings("get_surface", protocol.wp_alpha_modifier_v1.request_messages[1].name);
    try std.testing.expectEqualStrings("set_multiplier", protocol.wp_alpha_modifier_surface_v1.request_messages[1].name);
}
