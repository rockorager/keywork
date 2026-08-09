//! Scanner-backed keyboard-shortcuts-inhibit unstable-v1 adapter.

const Self = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayring = @import("wayring");
const ClientRegistry = @import("../ClientRegistry.zig");
const CompositorServer = @import("../server.zig");
const Seat = @import("seat.zig");
const WayringCompositor = @import("WayringCompositor.zig");
const WayringSeatAdapter = @import("WayringSeatAdapter.zig");

const server = wayring.server;

const Manager = struct { owner: *Self, client: *server.Client, resource: protocol.zwp_keyboard_shortcuts_inhibit_manager_v1.Resource };
const Inhibitor = struct {
    owner: *Self,
    client: *server.Client,
    client_id: ClientRegistry.Id,
    resource: protocol.zwp_keyboard_shortcuts_inhibitor_v1.Resource,
    surface: WayringCompositor.SurfaceId,
    observer: ?*server.Resource.Observer,
    active: bool = false,
};

allocator: std.mem.Allocator,
protocol_server: *server.Server,
compositor: *WayringCompositor,
seat_adapter: *WayringSeatAdapter,
seat: *Seat,
global: ?*const server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
inhibitors: std.ArrayList(*Inhibitor) = .empty,
focus_listener_installed: bool = false,

pub fn init(self: *Self, allocator: std.mem.Allocator, protocol_server: *server.Server, compositor: *WayringCompositor, seat_adapter: *WayringSeatAdapter, seat: *Seat) void {
    self.* = .{ .allocator = allocator, .protocol_server = protocol_server, .compositor = compositor, .seat_adapter = seat_adapter, .seat = seat };
}
pub fn installFocusListener(self: *Self) !void {
    try self.seat.addKeyboardFocusListener(.{ .context = self, .changed = focusChanged });
    self.focus_listener_installed = true;
    self.sync();
}
pub fn clearFocusListener(self: *Self) void {
    if (!self.focus_listener_installed) return;
    self.seat.removeKeyboardFocusListener(self);
    self.focus_listener_installed = false;
}
pub fn publish(self: *Self) !void {
    self.global = try self.protocol_server.addGlobal(protocol.zwp_keyboard_shortcuts_inhibit_manager_v1, 1, Self, self, bind);
}
pub fn unpublish(self: *Self) void {
    self.protocol_server.removeGlobal(self.global orelse unreachable) catch {};
    self.global = null;
}
pub fn deinit(self: *Self) void {
    std.debug.assert(self.global == null and !self.focus_listener_installed and self.managers.items.len == 0 and self.inhibitors.items.len == 0);
    self.inhibitors.deinit(self.allocator);
    self.managers.deinit(self.allocator);
    self.* = undefined;
}
pub fn provider(self: *Self) CompositorServer.GeneratedKeyboardShortcutsInhibitProvider {
    return .{ .context = self, .inhibits_default_seat = inhibitsDefaultSeat };
}
fn inhibitsDefaultSeat(context: *anyopaque) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    for (self.inhibitors.items) |value| if (value.active) return true;
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
fn managerRequest(_: *protocol.zwp_keyboard_shortcuts_inhibit_manager_v1.Resource, request: protocol.zwp_keyboard_shortcuts_inhibit_manager_v1.Request, value: *Manager) !void {
    switch (request) {
        .destroy => value.owner.destroyManager(value),
        .inhibit_shortcuts => |args| try value.owner.create(value, args.id, args.surface, args.seat),
    }
}
fn create(self: *Self, manager: *Manager, id: u32, surface_object: u32, seat_object: u32) !void {
    const client_id = self.seat_adapter.seatClientIdentity(manager.client, seat_object) orelse {
        manager.client.postImplementationError(&manager.resource.runtime, "shortcut inhibitor requires the exact live same-client generated wl_seat");
        return;
    };
    try self.inhibitors.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Inhibitor);
    errdefer self.allocator.destroy(value);
    value.* = .{ .owner = self, .client = manager.client, .client_id = client_id, .resource = .init(self.allocator, id, 1, .client, manager.client.ownerHooks()), .surface = undefined, .observer = null };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    const observed = try self.compositor.observeSurfaceDestruction(manager.client, surface_object, Inhibitor, value, surfaceDestroyed) orelse {
        manager.client.postImplementationError(&manager.resource.runtime, "shortcut inhibitor requires the exact live same-client generated wl_surface");
        return;
    };
    value.surface = observed.id;
    value.observer = observed.observer;
    errdefer server.Resource.removeDestroyObserver(observed.observer);
    for (self.inhibitors.items) |existing| if (existing.observer != null and std.meta.eql(existing.surface, value.surface)) {
        manager.client.postProtocolError(&manager.resource.runtime, @intCast(protocol.zwp_keyboard_shortcuts_inhibit_manager_v1.@"error".already_inhibited), "keyboard shortcuts are already inhibited for this surface and seat");
        return;
    };
    try value.resource.setHandler(Inhibitor, value, inhibitorRequest, null);
    try manager.client.materialize(&value.resource.runtime);
    self.inhibitors.appendAssumeCapacity(value);
    self.syncOne(value);
}
fn inhibitorRequest(_: *protocol.zwp_keyboard_shortcuts_inhibitor_v1.Resource, request: protocol.zwp_keyboard_shortcuts_inhibitor_v1.Request, value: *Inhibitor) !void {
    switch (request) {
        .destroy => value.owner.destroyInhibitor(value),
    }
}
fn focusChanged(context: *anyopaque, _: ?*@import("wayland").server.wl.Client) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.sync();
}
fn sync(self: *Self) void {
    for (self.inhibitors.items) |value| self.syncOne(value);
}
fn syncOne(self: *Self, value: *Inhibitor) void {
    const focus = self.seat.effectiveGeneratedKeyboardFocus();
    const active = value.observer != null and focus != null and
        std.meta.eql(focus.?.surface, value.surface) and std.meta.eql(focus.?.client, value.client_id);
    if (active == value.active) return;
    value.active = active;
    if (active) protocol.zwp_keyboard_shortcuts_inhibitor_v1.@"send:active"(&value.resource) catch |err| eventFailure(value, err);
}
fn surfaceDestroyed(value: *Inhibitor, _: *server.Resource, _: *server.Resource.Observer) void {
    value.observer = null;
    value.active = false;
}
fn eventFailure(value: *Inhibitor, err: anyerror) void {
    if (value.client.fatal() != null) return;
    switch (err) {
        error.OutOfMemory, error.WriteFailed => value.client.postOutOfMemory(&value.resource.runtime, "queueing shortcut inhibitor active event"),
        error.OutputSealed, error.ClientFatal => {},
        else => value.client.postImplementationError(&value.resource.runtime, "queueing shortcut inhibitor active event"),
    }
}
pub fn destroyClientResources(self: *Self, client: *server.Client) void {
    var i = self.inhibitors.items.len;
    while (i > 0) {
        i -= 1;
        if (self.inhibitors.items[i].client == client) self.destroyInhibitor(self.inhibitors.items[i]);
    }
    i = self.managers.items.len;
    while (i > 0) {
        i -= 1;
        if (self.managers.items[i].client == client) self.destroyManager(self.managers.items[i]);
    }
}
fn destroyInhibitor(self: *Self, value: *Inhibitor) void {
    if (value.observer) |observer| server.Resource.removeDestroyObserver(observer);
    remove(Inhibitor, &self.inhibitors, value);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
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

test "keyboard shortcuts inhibit descriptors pin unstable v1" {
    try std.testing.expectEqual(@as(u32, 1), protocol.zwp_keyboard_shortcuts_inhibit_manager_v1.interface.version);
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(protocol.zwp_keyboard_shortcuts_inhibit_manager_v1.@"error".already_inhibited));
    try std.testing.expectEqual(@as(usize, 2), protocol.zwp_keyboard_shortcuts_inhibitor_v1.event_messages.len);
}
