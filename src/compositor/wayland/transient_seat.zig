//! Privileged creation and lifetime management for temporary Wayland seats.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const SecurityContext = @import("security_context.zig");
const Seat = @import("seat.zig");
const Surface = @import("surface.zig");
const ClientRegistry = @import("../ClientRegistry.zig");
const SurfaceRegistry = @import("../SurfaceRegistry.zig");
const MatureClients = @import("MatureClients.zig");

const ext = wayland.server.ext;
const wl = wayland.server.wl;

allocator: std.mem.Allocator,
io: std.Io,
display: *wl.Server,
surface_store: *Surface.Store,
clients: *ClientRegistry,
mature_clients: *MatureClients,
surface_registry: *SurfaceRegistry,
security_context: *SecurityContext,
global: *wl.Global,
seats: std.ArrayList(*TransientSeat),
listeners: std.ArrayList(SeatListener),
next_name: u64,

pub const SeatListener = struct {
    context: *anyopaque,
    removed: *const fn (*anyopaque, *Seat) void,
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    io: std.Io,
    display: *wl.Server,
    surface_store: *Surface.Store,
    clients: *ClientRegistry,
    mature_clients: *MatureClients,
    surface_registry: *SurfaceRegistry,
    security_context: *SecurityContext,
) !void {
    self.* = .{
        .allocator = allocator,
        .io = io,
        .display = display,
        .surface_store = surface_store,
        .clients = clients,
        .mature_clients = mature_clients,
        .surface_registry = surface_registry,
        .security_context = security_context,
        .global = try wl.Global.create(
            display,
            ext.TransientSeatManagerV1,
            1,
            *Self,
            self,
            bind,
        ),
        .seats = .empty,
        .listeners = .empty,
        .next_name = 0,
    };
    errdefer self.global.destroy();
    try security_context.restrictGlobal(self.global);
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.seats.items.len == 0);
    std.debug.assert(self.listeners.items.len == 0);
    self.security_context.unrestrictGlobal(self.global);
    self.global.destroy();
    self.listeners.deinit(self.allocator);
    self.seats.deinit(self.allocator);
    self.* = undefined;
}

/// Copies the listener and retains its context until removeSeatListener.
pub fn addSeatListener(self: *Self, listener: SeatListener) error{OutOfMemory}!void {
    for (self.listeners.items) |existing| std.debug.assert(existing.context != listener.context);
    try self.listeners.append(self.allocator, listener);
}

pub fn removeSeatListener(self: *Self, context: *anyopaque) void {
    for (self.listeners.items, 0..) |listener, index| {
        if (listener.context != context) continue;
        _ = self.listeners.orderedRemove(index);
        return;
    }
    unreachable;
}

pub fn seatForResource(self: *Self, resource: *wl.Seat) ?*Seat {
    for (self.seats.items) |transient| {
        if (transient.active and transient.seat.ownsResource(resource)) return &transient.seat;
    }
    return null;
}

pub fn retainSeat(self: *Self, seat: *Seat) bool {
    for (self.seats.items) |transient| {
        if (!transient.active or &transient.seat != seat) continue;
        transient.references = std.math.add(usize, transient.references, 1) catch unreachable;
        return true;
    }
    return false;
}

pub fn releaseSeat(self: *Self, seat: *Seat) void {
    for (self.seats.items) |transient| {
        if (&transient.seat != seat) continue;
        std.debug.assert(transient.references > 0);
        transient.references -= 1;
        transient.destroyIfUnused();
        return;
    }
    unreachable;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = ext.TransientSeatManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleManagerRequest, null, self);
}

fn handleManagerRequest(
    resource: *ext.TransientSeatManagerV1,
    request: ext.TransientSeatManagerV1.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .create => |create| TransientSeat.create(self, resource, create.seat) catch
            resource.postNoMemory(),
    }
}

fn allocateName(allocator: std.mem.Allocator, generation: u64) error{OutOfMemory}![:0]u8 {
    return std.fmt.allocPrintSentinel(allocator, "transient-{d}", .{generation}, 0);
}

const TransientSeat = struct {
    manager: *Self,
    resource: ?*ext.TransientSeatV1,
    seat: Seat,
    name: [:0]u8,
    active: bool,
    resources: usize,
    references: usize,

    fn create(
        manager: *Self,
        manager_resource: *ext.TransientSeatManagerV1,
        id: u32,
    ) !void {
        const resource = try ext.TransientSeatV1.create(
            manager_resource.getClient(),
            manager_resource.getVersion(),
            id,
        );
        errdefer resource.destroy();
        const self = try manager.allocator.create(TransientSeat);
        errdefer manager.allocator.destroy(self);
        const generation = manager.next_name;
        manager.next_name = std.math.add(u64, generation, 1) catch unreachable;
        const name = try allocateName(manager.allocator, generation);
        errdefer manager.allocator.free(name);
        self.* = .{
            .manager = manager,
            .resource = resource,
            .seat = undefined,
            .name = name,
            .active = true,
            .resources = 0,
            .references = 0,
        };
        try self.seat.init(
            manager.allocator,
            manager.io,
            manager.display,
            name,
            manager.surface_store,
            manager.clients,
            manager.mature_clients,
            manager.surface_registry,
        );
        errdefer self.seat.deinit();
        self.seat.setSeatResourceListener(.{
            .context = self,
            .changed = seatResourceCountChanged,
        });
        errdefer self.seat.clearSeatResourceListener();
        try manager.seats.append(manager.allocator, self);
        resource.setHandler(*TransientSeat, handleRequest, handleDestroy, self);
        resource.sendReady(self.seat.globalName(resource.getClient()));
    }

    fn handleRequest(
        resource: *ext.TransientSeatV1,
        request: ext.TransientSeatV1.Request,
        _: *TransientSeat,
    ) void {
        switch (request) {
            .destroy => resource.destroy(),
        }
    }

    fn handleDestroy(_: *ext.TransientSeatV1, self: *TransientSeat) void {
        std.debug.assert(self.resource != null and self.active);
        self.active = false;
        self.seat.removeGlobal();
        for (self.manager.listeners.items) |listener| {
            listener.removed(listener.context, &self.seat);
        }
        self.resource = null;
        self.destroyIfUnused();
    }

    fn seatResourceCountChanged(context: *anyopaque, count: usize) void {
        const self: *TransientSeat = @ptrCast(@alignCast(context));
        self.resources = count;
        self.destroyIfUnused();
    }

    fn destroyIfUnused(self: *TransientSeat) void {
        if (self.resource != null or self.resources != 0 or self.references != 0) return;
        std.debug.assert(!self.active);
        self.seat.clearSeatResourceListener();
        self.seat.discardAuthorityGrants();
        self.seat.deinit();
        for (self.manager.seats.items, 0..) |transient, index| {
            if (transient != self) continue;
            _ = self.manager.seats.orderedRemove(index);
            self.manager.allocator.free(self.name);
            self.manager.allocator.destroy(self);
            return;
        }
        unreachable;
    }
};

test "transient seat names are distinct" {
    const first = try allocateName(std.testing.allocator, 0);
    defer std.testing.allocator.free(first);
    const second = try allocateName(std.testing.allocator, 1);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("transient-0", first);
    try std.testing.expectEqualStrings("transient-1", second);
}
