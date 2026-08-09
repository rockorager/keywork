//! Scanner-backed per-surface background blur regions.

const WayringBackgroundEffect = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayring = @import("wayring");
const WayringCompositor = @import("WayringCompositor.zig");

const server = wayring.server;

const Manager = struct {
    owner: *WayringBackgroundEffect,
    client: *server.Client,
    resource: protocol.ext_background_effect_manager_v1.Resource,
};

const Effect = struct {
    owner: *WayringBackgroundEffect,
    client: *server.Client,
    resource: protocol.ext_background_effect_surface_v1.Resource,
    surface: ?WayringCompositor.SurfaceId,
};

allocator: std.mem.Allocator,
protocol_server: *server.Server,
compositor: *WayringCompositor,
global: ?*const server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
effects: std.ArrayList(*Effect) = .empty,

pub fn init(self: *WayringBackgroundEffect, allocator: std.mem.Allocator, protocol_server: *server.Server, compositor: *WayringCompositor) void {
    self.* = .{ .allocator = allocator, .protocol_server = protocol_server, .compositor = compositor };
}

pub fn publish(self: *WayringBackgroundEffect) !void {
    self.global = try self.protocol_server.addGlobal(protocol.ext_background_effect_manager_v1, 1, WayringBackgroundEffect, self, bind);
}

pub fn unpublish(self: *WayringBackgroundEffect) void {
    self.protocol_server.removeGlobal(self.global.?) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}

pub fn destroyClientResources(self: *WayringBackgroundEffect, client: *server.Client) void {
    var i = self.effects.items.len;
    while (i > 0) {
        i -= 1;
        if (self.effects.items[i].client == client) self.destroyEffect(self.effects.items[i]);
    }
    i = self.managers.items.len;
    while (i > 0) {
        i -= 1;
        if (self.managers.items[i].client == client) self.destroyManager(self.managers.items[i]);
    }
}

pub fn deinit(self: *WayringBackgroundEffect) void {
    std.debug.assert(self.global == null and self.effects.items.len == 0 and self.managers.items.len == 0);
    self.effects.deinit(self.allocator);
    self.managers.deinit(self.allocator);
    self.* = undefined;
}

fn bind(client: *server.Client, id: u32, version: u32, self: *WayringBackgroundEffect) !void {
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
    protocol.ext_background_effect_manager_v1.@"send:capabilities"(
        &manager.resource,
        @intCast(protocol.ext_background_effect_manager_v1.capability.blur),
    ) catch |err| switch (err) {
        error.OutOfMemory, error.WriteFailed => client.postOutOfMemory(&manager.resource.runtime, "queueing background effect capabilities"),
        error.OutputSealed, error.ClientFatal => {},
        else => client.postImplementationError(&manager.resource.runtime, "queueing background effect capabilities"),
    };
}

fn handleManager(_: *protocol.ext_background_effect_manager_v1.Resource, request: protocol.ext_background_effect_manager_v1.Request, manager: *Manager) !void {
    switch (request) {
        .destroy => manager.owner.destroyManager(manager),
        .get_background_effect => |args| try manager.owner.createEffect(manager, args.id, args.surface),
    }
}

fn createEffect(self: *WayringBackgroundEffect, manager: *Manager, id: u32, surface_object: u32) !void {
    try self.effects.ensureUnusedCapacity(self.allocator, 1);
    const effect = try self.allocator.create(Effect);
    errdefer self.allocator.destroy(effect);
    effect.* = .{ .owner = self, .client = manager.client, .resource = undefined, .surface = null };
    switch (self.compositor.attachBackgroundEffect(manager.client, surface_object, .{
        .context = effect,
        .surface_destroyed = surfaceDestroyed,
    })) {
        .attached => |surface| effect.surface = surface,
        .background_effect_exists => {
            self.allocator.destroy(effect);
            manager.client.postProtocolError(&manager.resource.runtime, @intCast(protocol.ext_background_effect_manager_v1.@"error".background_effect_exists), "wl_surface already has a background effect object");
            return;
        },
        .not_live, .wrong_client => {
            self.allocator.destroy(effect);
            manager.client.postImplementationError(&manager.resource.runtime, "surface is not an exact live same-client Wayring wl_surface");
            return;
        },
    }
    errdefer self.compositor.detachBackgroundEffect(effect.surface.?, effect);
    effect.resource = .init(self.allocator, id, 1, .client, manager.client.ownerHooks());
    errdefer {
        effect.resource.destroy();
        effect.resource.deinit();
    }
    try effect.resource.setHandler(Effect, effect, handleEffect, null);
    try manager.client.materialize(&effect.resource.runtime);
    self.effects.appendAssumeCapacity(effect);
}

fn handleEffect(_: *protocol.ext_background_effect_surface_v1.Resource, request: protocol.ext_background_effect_surface_v1.Request, effect: *Effect) !void {
    switch (request) {
        .destroy => effect.owner.destroyEffect(effect),
        .set_blur_region => |args| {
            const surface = effect.surface orelse {
                effect.client.postProtocolError(&effect.resource.runtime, @intCast(protocol.ext_background_effect_surface_v1.@"error".surface_destroyed), "wl_surface has been destroyed");
                return;
            };
            switch (effect.owner.compositor.setPendingBlurRegion(effect.client, surface, effect, args.region)) {
                .applied => {},
                .out_of_memory => effect.client.postOutOfMemory(&effect.resource.runtime, "copying background effect blur region"),
                .not_live => {
                    effect.surface = null;
                    effect.client.postProtocolError(&effect.resource.runtime, @intCast(protocol.ext_background_effect_surface_v1.@"error".surface_destroyed), "wl_surface has been destroyed");
                },
                .wrong_context => effect.client.postImplementationError(&effect.resource.runtime, "background effect attachment no longer matches"),
                .invalid_region => effect.client.postImplementationError(&effect.resource.runtime, "blur region is not a live same-client Wayring wl_region"),
            }
        },
    }
}

fn surfaceDestroyed(context: *anyopaque) void {
    const effect: *Effect = @ptrCast(@alignCast(context));
    effect.surface = null;
}

fn destroyEffect(self: *WayringBackgroundEffect, effect: *Effect) void {
    if (effect.surface) |surface| self.compositor.detachBackgroundEffect(surface, effect);
    remove(Effect, &self.effects, effect);
    effect.resource.destroy();
    effect.resource.deinit();
    self.allocator.destroy(effect);
}

fn destroyManager(self: *WayringBackgroundEffect, manager: *Manager) void {
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

test "background effect protocol descriptors expose blur capability" {
    try std.testing.expectEqual(@as(u32, 1), protocol.ext_background_effect_manager_v1.interface.version);
    try std.testing.expectEqualStrings("capabilities", protocol.ext_background_effect_manager_v1.event_messages[0].name);
    try std.testing.expectEqualStrings("set_blur_region", protocol.ext_background_effect_surface_v1.request_messages[1].name);
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(protocol.ext_background_effect_manager_v1.capability.blur));
}
