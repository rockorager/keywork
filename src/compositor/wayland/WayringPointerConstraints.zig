//! Scanner-backed pointer constraints unstable-v1 adapter.

const Self = @This();
const std = @import("std");
const protocol = @import("wayring-protocol");
const wayring = @import("wayring");
const Neutral = @import("../PointerConstraints.zig");
const Region = @import("../region.zig");
const WayringCompositor = @import("WayringCompositor.zig");
const WayringSeatAdapter = @import("WayringSeatAdapter.zig");
const server = wayring.server;

const Manager = struct { owner: *Self, client: *server.Client, resource: protocol.zwp_pointer_constraints_v1.Resource };
const Kind = enum { locked, confined };
const Resource = union(Kind) {
    locked: protocol.zwp_locked_pointer_v1.Resource,
    confined: protocol.zwp_confined_pointer_v1.Resource,
};
const Snapshot = struct { token: WayringCompositor.UpdateToken, region: Region, region_set: bool, hint: ?Region.Point };
const Constraint = struct {
    owner: *Self,
    client: *server.Client,
    pointer_object_id: u32,
    pointer_identity: WayringSeatAdapter.PointerIdentity,
    reservation: ?WayringCompositor.PointerConstraintReservation,
    resource: Resource,
    current_region: Region,
    current_region_set: bool,
    pending_region: Region,
    pending_region_set: bool = false,
    pending_region_changed: bool = false,
    hint: ?Region.Point = null,
    pending_hint: ?Region.Point = null,
    pending_hint_changed: bool = false,
    effective_region: Region,
    snapshots: std.ArrayList(Snapshot) = .empty,
    neutral: Neutral.Constraint,
};

allocator: std.mem.Allocator,
protocol_server: *server.Server,
seat: *WayringSeatAdapter,
compositor: *WayringCompositor,
coordinator: *Neutral,
sync_context: *anyopaque,
sync_callback: *const fn (*anyopaque) void,
global: ?*const server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
constraints: std.ArrayList(*Constraint) = .empty,

pub fn init(self: *Self, allocator: std.mem.Allocator, protocol_server: *server.Server, seat: *WayringSeatAdapter, compositor: *WayringCompositor, coordinator: *Neutral, sync_context: *anyopaque, sync_callback: *const fn (*anyopaque) void) void {
    self.* = .{ .allocator = allocator, .protocol_server = protocol_server, .seat = seat, .compositor = compositor, .coordinator = coordinator, .sync_context = sync_context, .sync_callback = sync_callback };
}
pub fn publish(self: *Self) !void {
    self.global = try self.protocol_server.addGlobal(protocol.zwp_pointer_constraints_v1, 1, Self, self, bind);
}
pub fn unpublish(self: *Self) void {
    self.protocol_server.removeGlobal(self.global orelse unreachable) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}
pub fn deinit(self: *Self) void {
    std.debug.assert(self.global == null and self.managers.items.len == 0 and self.constraints.items.len == 0);
    self.constraints.deinit(self.allocator);
    self.managers.deinit(self.allocator);
    self.* = undefined;
}
pub fn destroyClientResources(self: *Self, client: *server.Client) void {
    var i = self.constraints.items.len;
    while (i > 0) {
        i -= 1;
        if (self.constraints.items[i].client == client) self.destroyConstraint(self.constraints.items[i]);
    }
    i = self.managers.items.len;
    while (i > 0) {
        i -= 1;
        if (self.managers.items[i].client == client) self.destroyManager(self.managers.items[i]);
    }
}

fn bind(client: *server.Client, id: u32, version: u32, self: *Self) !void {
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
fn managerRequest(_: *protocol.zwp_pointer_constraints_v1.Resource, request: protocol.zwp_pointer_constraints_v1.Request, manager: *Manager) !void {
    switch (request) {
        .destroy => manager.owner.destroyManager(manager),
        .lock_pointer => |args| try manager.owner.create(manager, .locked, args.id, args.surface, args.pointer, args.region, args.lifetime),
        .confine_pointer => |args| try manager.owner.create(manager, .confined, args.id, args.surface, args.pointer, args.region, args.lifetime),
    }
}
fn create(self: *Self, manager: *Manager, kind: Kind, id: u32, surface: u32, pointer: u32, region: ?u32, lifetime: u32) !void {
    const identity = self.seat.pointerIdentityIncludingInactive(manager.client, pointer) orelse {
        manager.client.postImplementationError(&manager.resource.runtime, "pointer constraint requires exact same-client wl_pointer");
        return;
    };
    try self.constraints.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Constraint);
    value.* = .{
        .owner = self,
        .client = manager.client,
        .pointer_object_id = pointer,
        .pointer_identity = identity,
        .reservation = null,
        .resource = switch (kind) {
            .locked => .{ .locked = .init(self.allocator, id, 1, .client, manager.client.ownerHooks()) },
            .confined => .{ .confined = .init(self.allocator, id, 1, .client, manager.client.ownerHooks()) },
        },
        .current_region = .init(),
        .current_region_set = region != null,
        .pending_region = .init(),
        .effective_region = .init(),
        .neutral = undefined,
    };
    var installed = false;
    defer if (!installed) {
        switch (value.resource) {
            inline else => |*resource| {
                resource.destroy();
                resource.deinit();
            },
        }
        value.current_region.deinit();
        value.pending_region.deinit();
        value.effective_region.deinit();
        value.snapshots.deinit(self.allocator);
        self.allocator.destroy(value);
    };
    if (region) |region_id| if (!try self.compositor.copyRegion(manager.client, region_id, &value.current_region)) {
        manager.client.postImplementationError(&manager.resource.runtime, "invalid wl_region");
        return;
    };
    value.neutral = .{ .surface = undefined, .kind = if (kind == .locked) .locked else .confined, .lifetime = if (lifetime == @as(u32, @intCast(protocol.zwp_pointer_constraints_v1.lifetime.oneshot))) .oneshot else .persistent, .context = value, .eligible = eligible, .effective_region = effectiveRegion, .activated = activated, .deactivated = deactivated };
    const reservation = self.compositor.reservePointerConstraint(manager.client, surface, .{ .context = value, .prepare_committed = prepareCommitted, .committed = committed, .abort_committed = abortCommitted, .applied = applied, .discarded = discarded, .surface_destroyed = surfaceDestroyed }) catch |err| {
        if (err == error.AlreadyReserved) manager.client.postProtocolError(&manager.resource.runtime, @intCast(protocol.zwp_pointer_constraints_v1.@"error".already_constrained), "surface already constrained") else manager.client.postImplementationError(&manager.resource.runtime, "invalid wl_surface");
        return;
    };
    value.reservation = reservation;
    value.neutral.surface = reservation.surface;
    var reservation_live = true;
    defer if (!installed and reservation_live) self.compositor.releasePointerConstraint(reservation) catch {};
    if (!try self.compositor.copyCurrentInputRegion(reservation.surface, &value.effective_region)) return;
    if (value.current_region_set) try value.effective_region.intersectWith(&value.current_region);
    var registered = false;
    self.coordinator.register(&value.neutral) catch |err| {
        if (err == error.AlreadyConstrained) manager.client.postProtocolError(&manager.resource.runtime, @intCast(protocol.zwp_pointer_constraints_v1.@"error".already_constrained), "surface already constrained");
        return;
    };
    registered = true;
    defer if (!installed and registered) self.coordinator.unregister(&value.neutral);
    switch (value.resource) {
        .locked => |*resource| {
            try resource.setHandler(Constraint, value, lockedRequest, null);
            try manager.client.materialize(&resource.runtime);
        },
        .confined => |*resource| {
            try resource.setHandler(Constraint, value, confinedRequest, null);
            try manager.client.materialize(&resource.runtime);
        },
    }
    self.constraints.appendAssumeCapacity(value);
    installed = true;
    reservation_live = false;
    self.sync_callback(self.sync_context);
}
fn eligible(context: *anyopaque) bool {
    const value: *Constraint = @ptrCast(@alignCast(context));
    const current = value.owner.seat.pointerIdentity(value.client, value.pointer_object_id) orelse return false;
    return std.meta.eql(current, value.pointer_identity);
}
fn effectiveRegion(context: *anyopaque) *const Region {
    return &(@as(*Constraint, @ptrCast(@alignCast(context))).effective_region);
}
fn activated(context: *anyopaque) void {
    const v: *Constraint = @ptrCast(@alignCast(context));
    switch (v.resource) {
        .locked => |*r| protocol.zwp_locked_pointer_v1.@"send:locked"(r) catch |err| eventFailed(v, err),
        .confined => |*r| protocol.zwp_confined_pointer_v1.@"send:confined"(r) catch |err| eventFailed(v, err),
    }
}
fn deactivated(context: *anyopaque) void {
    const v: *Constraint = @ptrCast(@alignCast(context));
    switch (v.resource) {
        .locked => |*r| protocol.zwp_locked_pointer_v1.@"send:unlocked"(r) catch |err| eventFailed(v, err),
        .confined => |*r| protocol.zwp_confined_pointer_v1.@"send:unconfined"(r) catch |err| eventFailed(v, err),
    }
    if (v.neutral.defunct) {
        if (v.reservation) |reservation| {
            v.owner.compositor.releasePointerConstraint(reservation) catch {};
            v.reservation = null;
            clearSnapshots(v);
        }
    }
}
fn setRegion(v: *Constraint, region: ?u32) !void {
    var candidate = Region.init();
    defer candidate.deinit();
    if (region) |id| if (!try v.owner.compositor.copyRegion(v.client, id, &candidate)) {
        v.client.postImplementationError(resourceRuntime(v), "invalid wl_region");
        return;
    };
    std.mem.swap(Region, &v.pending_region, &candidate);
    v.pending_region_set = region != null;
    v.pending_region_changed = true;
}
fn lockedRequest(_: *protocol.zwp_locked_pointer_v1.Resource, request: protocol.zwp_locked_pointer_v1.Request, v: *Constraint) !void {
    switch (request) {
        .destroy => v.owner.destroyConstraint(v),
        .set_region => |a| try setRegion(v, a.region),
        .set_cursor_position_hint => |a| {
            v.pending_hint = .{ .x = fixedDouble(a.surface_x), .y = fixedDouble(a.surface_y) };
            v.pending_hint_changed = true;
        },
    }
}
fn confinedRequest(_: *protocol.zwp_confined_pointer_v1.Resource, request: protocol.zwp_confined_pointer_v1.Request, v: *Constraint) !void {
    switch (request) {
        .destroy => v.owner.destroyConstraint(v),
        .set_region => |a| try setRegion(v, a.region),
    }
}
fn prepareCommitted(context: *anyopaque, token: WayringCompositor.UpdateToken) !void {
    const v: *Constraint = @ptrCast(@alignCast(context));
    const inherited_region = if (v.snapshots.items.len != 0)
        &v.snapshots.items[v.snapshots.items.len - 1].region
    else
        &v.current_region;
    const inherited_region_set = if (v.snapshots.items.len != 0)
        v.snapshots.items[v.snapshots.items.len - 1].region_set
    else
        v.current_region_set;
    const inherited_hint = if (v.snapshots.items.len != 0)
        v.snapshots.items[v.snapshots.items.len - 1].hint
    else
        v.hint;
    var region = Region.init();
    errdefer region.deinit();
    try region.copyFrom(if (v.pending_region_changed) &v.pending_region else inherited_region);
    try v.snapshots.append(v.owner.allocator, .{
        .token = token,
        .region = region,
        .region_set = if (v.pending_region_changed) v.pending_region_set else inherited_region_set,
        .hint = if (v.pending_hint_changed) v.pending_hint else inherited_hint,
    });
}
fn abortCommitted(context: *anyopaque, token: WayringCompositor.UpdateToken) void {
    const v: *Constraint = @ptrCast(@alignCast(context));
    for (v.snapshots.items, 0..) |*snapshot, index| {
        if (!std.meta.eql(snapshot.token, token)) continue;
        snapshot.region.deinit();
        _ = v.snapshots.orderedRemove(index);
        return;
    }
}
fn committed(context: *anyopaque, token: WayringCompositor.UpdateToken) void {
    const v: *Constraint = @ptrCast(@alignCast(context));
    var found = false;
    for (v.snapshots.items) |snapshot| if (std.meta.eql(snapshot.token, token)) {
        found = true;
        break;
    };
    if (!found) {
        unreachable;
    }
    if (v.pending_region_changed) {
        v.pending_region.clear();
        v.pending_region_changed = false;
    }
    if (v.pending_hint_changed) {
        v.pending_hint_changed = false;
    }
}
fn applied(context: *anyopaque, token: WayringCompositor.UpdateToken) void {
    const v: *Constraint = @ptrCast(@alignCast(context));
    for (v.snapshots.items, 0..) |*s, i| {
        if (!std.meta.eql(s.token, token)) continue;
        std.mem.swap(Region, &v.current_region, &s.region);
        v.current_region_set = s.region_set;
        v.hint = s.hint;
        s.region.deinit();
        _ = v.snapshots.orderedRemove(i);
        _ = v.owner.compositor.copyCurrentInputRegion(v.neutral.surface, &v.effective_region) catch {
            v.client.postOutOfMemory(resourceRuntime(v), "applying pointer constraint");
            return;
        };
        if (v.current_region_set) {
            v.effective_region.intersectWith(&v.current_region) catch {
                v.client.postOutOfMemory(resourceRuntime(v), "applying pointer constraint");
                return;
            };
        }
        return;
    }
}
fn discarded(context: *anyopaque, token: WayringCompositor.UpdateToken) void {
    const v: *Constraint = @ptrCast(@alignCast(context));
    for (v.snapshots.items, 0..) |*s, i| {
        if (!std.meta.eql(s.token, token)) continue;
        s.region.deinit();
        _ = v.snapshots.orderedRemove(i);
        return;
    }
}
fn surfaceDestroyed(context: *anyopaque) void {
    const v: *Constraint = @ptrCast(@alignCast(context));
    v.reservation = null;
    clearSnapshots(v);
    v.owner.coordinator.surfaceDestroyed(&v.neutral);
    v.owner.sync_callback(v.owner.sync_context);
}
fn clearSnapshots(v: *Constraint) void {
    for (v.snapshots.items) |*snapshot| snapshot.region.deinit();
    v.snapshots.clearRetainingCapacity();
}
fn fixedDouble(value: i32) f64 {
    return @as(f64, @floatFromInt(value)) / 256.0;
}
fn resourceRuntime(v: *Constraint) *server.Resource {
    return switch (v.resource) {
        .locked => |*r| &r.runtime,
        .confined => |*r| &r.runtime,
    };
}
fn eventFailed(v: *Constraint, err: anyerror) void {
    switch (err) {
        error.OutOfMemory, error.WriteFailed => v.client.postOutOfMemory(resourceRuntime(v), "queueing pointer constraint event"),
        error.OutputSealed, error.ClientFatal => {},
        else => v.client.postImplementationError(resourceRuntime(v), "queueing pointer constraint event"),
    }
}
fn destroyManager(self: *Self, v: *Manager) void {
    remove(Manager, &self.managers, v);
    v.resource.destroy();
    v.resource.deinit();
    self.allocator.destroy(v);
}
fn destroyConstraint(self: *Self, v: *Constraint) void {
    self.coordinator.unregister(&v.neutral);
    if (v.reservation) |r| self.compositor.releasePointerConstraint(r) catch {};
    for (v.snapshots.items) |*s| s.region.deinit();
    v.snapshots.deinit(self.allocator);
    remove(Constraint, &self.constraints, v);
    switch (v.resource) {
        inline else => |*r| {
            r.destroy();
            r.deinit();
        },
    }
    v.current_region.deinit();
    v.pending_region.deinit();
    v.effective_region.deinit();
    self.allocator.destroy(v);
    self.sync_callback(self.sync_context);
}
fn remove(comptime T: type, list: *std.ArrayList(*T), value: *T) void {
    for (list.items, 0..) |item, i| if (item == value) {
        _ = list.orderedRemove(i);
        return;
    };
    unreachable;
}
