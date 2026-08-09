//! Scanner-backed per-surface presentation hints for asynchronous page flips.

const WayringTearingControl = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayring = @import("wayring");
const WayringCompositor = @import("WayringCompositor.zig");

const server = wayring.server;

const Manager = struct {
    owner: *WayringTearingControl,
    client: *server.Client,
    resource: protocol.wp_tearing_control_manager_v1.Resource,
};

const Control = struct {
    owner: *WayringTearingControl,
    client: *server.Client,
    resource: protocol.wp_tearing_control_v1.Resource,
    surface: ?WayringCompositor.SurfaceId,
};

allocator: std.mem.Allocator,
protocol_server: *server.Server,
compositor: *WayringCompositor,
global: ?*const server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
controls: std.ArrayList(*Control) = .empty,

pub fn init(self: *WayringTearingControl, allocator: std.mem.Allocator, protocol_server: *server.Server, compositor: *WayringCompositor) void {
    self.* = .{ .allocator = allocator, .protocol_server = protocol_server, .compositor = compositor };
}

pub fn publish(self: *WayringTearingControl) !void {
    self.global = try self.protocol_server.addGlobal(protocol.wp_tearing_control_manager_v1, 1, WayringTearingControl, self, bind);
}

pub fn unpublish(self: *WayringTearingControl) void {
    self.protocol_server.removeGlobal(self.global.?) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}

pub fn destroyClientResources(self: *WayringTearingControl, client: *server.Client) void {
    var i = self.controls.items.len;
    while (i > 0) {
        i -= 1;
        if (self.controls.items[i].client == client) self.destroyControl(self.controls.items[i]);
    }
    i = self.managers.items.len;
    while (i > 0) {
        i -= 1;
        if (self.managers.items[i].client == client) self.destroyManager(self.managers.items[i]);
    }
}

pub fn deinit(self: *WayringTearingControl) void {
    std.debug.assert(self.global == null and self.controls.items.len == 0 and self.managers.items.len == 0);
    self.controls.deinit(self.allocator);
    self.managers.deinit(self.allocator);
    self.* = undefined;
}

fn bind(client: *server.Client, id: u32, version: u32, self: *WayringTearingControl) !void {
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

fn handleManager(_: *protocol.wp_tearing_control_manager_v1.Resource, request: protocol.wp_tearing_control_manager_v1.Request, manager: *Manager) !void {
    switch (request) {
        .destroy => manager.owner.destroyManager(manager),
        .get_tearing_control => |args| try manager.owner.createControl(manager, args.id, args.surface),
    }
}

fn createControl(self: *WayringTearingControl, manager: *Manager, id: u32, surface_object: u32) !void {
    try self.controls.ensureUnusedCapacity(self.allocator, 1);
    const control = try self.allocator.create(Control);
    errdefer self.allocator.destroy(control);
    control.* = .{ .owner = self, .client = manager.client, .resource = undefined, .surface = null };
    switch (self.compositor.attachTearingControl(manager.client, surface_object, .{
        .context = control,
        .surface_destroyed = surfaceDestroyed,
    })) {
        .attached => |surface| control.surface = surface,
        .tearing_control_exists => {
            self.allocator.destroy(control);
            manager.client.postProtocolError(&manager.resource.runtime, @intCast(protocol.wp_tearing_control_manager_v1.@"error".tearing_control_exists), "wl_surface already has a tearing control object");
            return;
        },
        .not_live, .wrong_client => {
            self.allocator.destroy(control);
            manager.client.postImplementationError(&manager.resource.runtime, "surface is not an exact live same-client Wayring wl_surface");
            return;
        },
    }
    errdefer self.compositor.detachTearingControl(control.surface.?, control);
    control.resource = .init(self.allocator, id, 1, .client, manager.client.ownerHooks());
    errdefer {
        control.resource.destroy();
        control.resource.deinit();
    }
    try control.resource.setHandler(Control, control, handleControl, null);
    try manager.client.materialize(&control.resource.runtime);
    self.controls.appendAssumeCapacity(control);
}

fn handleControl(_: *protocol.wp_tearing_control_v1.Resource, request: protocol.wp_tearing_control_v1.Request, control: *Control) !void {
    switch (request) {
        .destroy => control.owner.destroyControl(control),
        .set_presentation_hint => |args| if (control.surface) |surface| {
            _ = control.owner.compositor.setPendingAllowTearing(
                surface,
                control,
                args.hint == protocol.wp_tearing_control_v1.presentation_hint.async,
            );
        },
    }
}

fn surfaceDestroyed(context: *anyopaque) void {
    const control: *Control = @ptrCast(@alignCast(context));
    control.surface = null;
}

fn destroyControl(self: *WayringTearingControl, control: *Control) void {
    if (control.surface) |surface| self.compositor.detachTearingControl(surface, control);
    remove(Control, &self.controls, control);
    control.resource.destroy();
    control.resource.deinit();
    self.allocator.destroy(control);
}

fn destroyManager(self: *WayringTearingControl, manager: *Manager) void {
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

test "tearing control protocol descriptors are version one" {
    try std.testing.expectEqual(@as(u32, 1), protocol.wp_tearing_control_manager_v1.interface.version);
    try std.testing.expectEqualStrings("get_tearing_control", protocol.wp_tearing_control_manager_v1.request_messages[1].name);
    try std.testing.expectEqualStrings("set_presentation_hint", protocol.wp_tearing_control_v1.request_messages[0].name);
}
