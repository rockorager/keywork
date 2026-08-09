//! Pointer locking and confinement policy for focused surfaces.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const NeutralPointerConstraints = @import("../PointerConstraints.zig");
const Region = @import("../region.zig");
const Seat = @import("seat.zig");
const Surface = @import("surface.zig");
const WaylandRegion = @import("region.zig");

const wl = wayland.server.wl;
const zwp = wayland.server.zwp;

allocator: std.mem.Allocator,
global: *wl.Global,
seat: *Seat,
surface_store: *Surface.Store,
coordinator: *NeutralPointerConstraints,
constraints: std.ArrayList(*Constraint),

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    seat: *Seat,
    surface_store: *Surface.Store,
    coordinator: *NeutralPointerConstraints,
) !void {
    self.* = .{
        .allocator = allocator,
        .global = try wl.Global.create(
            display,
            zwp.PointerConstraintsV1,
            1,
            *Self,
            self,
            bind,
        ),
        .seat = seat,
        .surface_store = surface_store,
        .coordinator = coordinator,
        .constraints = .empty,
    };
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.constraints.items.len == 0);
    self.global.destroy();
    self.constraints.deinit(self.allocator);
    self.* = undefined;
}

fn syncFocus(self: *Self) void {
    self.coordinator.syncFocus(canonicalFocus(self.seat));
}

fn canonicalFocus(seat: *const Seat) ?NeutralPointerConstraints.Focus {
    const focus = seat.pointerFocus() orelse return null;
    return .{ .surface = focus.surface_id, .x = focus.x, .y = focus.y };
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = zwp.PointerConstraintsV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleManagerRequest, null, self);
}

fn handleManagerRequest(
    resource: *zwp.PointerConstraintsV1,
    request: zwp.PointerConstraintsV1.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .lock_pointer => |lock| self.createConstraint(
            resource,
            .locked,
            lock.id,
            lock.surface,
            lock.pointer,
            lock.region,
            lock.lifetime,
        ) catch resource.postNoMemory(),
        .confine_pointer => |confine| self.createConstraint(
            resource,
            .confined,
            confine.id,
            confine.surface,
            confine.pointer,
            confine.region,
            confine.lifetime,
        ) catch resource.postNoMemory(),
    }
}

fn createConstraint(
    self: *Self,
    manager_resource: *zwp.PointerConstraintsV1,
    kind: Kind,
    id: u32,
    surface_resource: *wl.Surface,
    pointer_resource: *wl.Pointer,
    region_resource: ?*wl.Region,
    lifetime: zwp.PointerConstraintsV1.Lifetime,
) !void {
    const surface = Surface.fromResource(surface_resource);
    const surface_id = surface.handle();
    if (self.coordinator.isConstrained(surface_id)) {
        manager_resource.postError(
            .already_constrained,
            "pointer constraint already requested on this surface",
        );
        return;
    }

    const protocol_resource: ConstraintResource = switch (kind) {
        .locked => .{ .locked = try zwp.LockedPointerV1.create(
            manager_resource.getClient(),
            manager_resource.getVersion(),
            id,
        ) },
        .confined => .{ .confined = try zwp.ConfinedPointerV1.create(
            manager_resource.getClient(),
            manager_resource.getVersion(),
            id,
        ) },
    };
    errdefer protocol_resource.destroy();
    const constraint = try self.allocator.create(Constraint);
    errdefer self.allocator.destroy(constraint);
    constraint.* = .{
        .manager = self,
        .resource = protocol_resource,
        .surface = surface,
        .surface_id = surface_id,
        .pointer = self.seat.pointerHandle(pointer_resource),
        .lifetime = lifetime,
        .listener = undefined,
        .current_region = Region.init(),
        .current_region_set = region_resource != null,
        .pending_region = Region.init(),
        .pending_region_set = false,
        .pending_region_changed = false,
        .effective_region = Region.init(),
        .cursor_hint = null,
        .pending_cursor_hint = null,
        .pending_cursor_hint_changed = false,
        .neutral = undefined,
    };
    constraint.neutral = .{
        .surface = surface_id,
        .kind = switch (kind) {
            .locked => .locked,
            .confined => .confined,
        },
        .lifetime = switch (lifetime) {
            .oneshot => .oneshot,
            // The protocol specifies that unknown values behave as persistent.
            else => .persistent,
        },
        .context = constraint,
        .eligible = Constraint.eligible,
        .effective_region = Constraint.effectiveRegion,
        .activated = Constraint.activated,
        .deactivated = Constraint.deactivated,
    };
    errdefer constraint.current_region.deinit();
    errdefer constraint.pending_region.deinit();
    errdefer constraint.effective_region.deinit();
    if (region_resource) |region| {
        try constraint.current_region.copyFrom(&WaylandRegion.fromResource(region).value);
    }
    try constraint.refreshEffectiveRegion();
    constraint.listener = .{
        .context = constraint,
        .applied = handleSurfaceApplied,
        .surface_destroyed = handleSurfaceDestroyed,
    };
    try surface.addCommitListener(&constraint.listener);
    errdefer surface.removeCommitListener(&constraint.listener);
    try self.coordinator.register(&constraint.neutral);
    errdefer self.coordinator.unregister(&constraint.neutral);
    try self.constraints.append(self.allocator, constraint);
    switch (protocol_resource) {
        .locked => |locked| locked.setHandler(
            *Constraint,
            handleLockedRequest,
            handleLockedDestroy,
            constraint,
        ),
        .confined => |confined| confined.setHandler(
            *Constraint,
            handleConfinedRequest,
            handleConfinedDestroy,
            constraint,
        ),
    }
    self.syncFocus();
}

const Kind = enum { locked, confined };

const ConstraintResource = union(Kind) {
    locked: *zwp.LockedPointerV1,
    confined: *zwp.ConfinedPointerV1,

    fn destroy(self: ConstraintResource) void {
        switch (self) {
            inline else => |resource| resource.destroy(),
        }
    }

    fn postNoMemory(self: ConstraintResource) void {
        switch (self) {
            inline else => |resource| resource.postNoMemory(),
        }
    }

    fn sendActivated(self: ConstraintResource) void {
        switch (self) {
            .locked => |resource| resource.sendLocked(),
            .confined => |resource| resource.sendConfined(),
        }
    }

    fn sendDeactivated(self: ConstraintResource) void {
        switch (self) {
            .locked => |resource| resource.sendUnlocked(),
            .confined => |resource| resource.sendUnconfined(),
        }
    }
};

const Constraint = struct {
    manager: *Self,
    resource: ConstraintResource,
    surface: ?*Surface,
    surface_id: Surface.Id,
    pointer: ?Seat.PointerHandle,
    lifetime: zwp.PointerConstraintsV1.Lifetime,
    listener: Surface.CommitListener,
    current_region: Region,
    current_region_set: bool,
    pending_region: Region,
    pending_region_set: bool,
    pending_region_changed: bool,
    effective_region: Region,
    cursor_hint: ?Region.Point,
    pending_cursor_hint: ?Region.Point,
    pending_cursor_hint_changed: bool,
    neutral: NeutralPointerConstraints.Constraint,

    fn kind(self: *const Constraint) Kind {
        return std.meta.activeTag(self.resource);
    }

    fn eligible(context: *anyopaque) bool {
        const self: *Constraint = @ptrCast(@alignCast(context));
        if (self.surface == null) return false;
        const pointer = self.pointer orelse return false;
        return self.manager.seat.pointerHandleIsActive(pointer);
    }

    fn effectiveRegion(context: *anyopaque) *const Region {
        const self: *Constraint = @ptrCast(@alignCast(context));
        return &self.effective_region;
    }

    fn activated(context: *anyopaque) void {
        const self: *Constraint = @ptrCast(@alignCast(context));
        self.resource.sendActivated();
    }

    fn deactivated(context: *anyopaque) void {
        const self: *Constraint = @ptrCast(@alignCast(context));
        self.resource.sendDeactivated();
    }

    fn setPendingRegion(self: *Constraint, region_resource: ?*wl.Region) !void {
        if (region_resource) |region| {
            var replacement = Region.init();
            defer replacement.deinit();
            try replacement.copyFrom(&WaylandRegion.fromResource(region).value);
            std.mem.swap(Region, &self.pending_region, &replacement);
            self.pending_region_set = true;
        } else {
            self.pending_region.clear();
            self.pending_region_set = false;
        }
        self.pending_region_changed = true;
    }

    fn applyPending(self: *Constraint) !void {
        if (self.pending_region_changed) {
            std.mem.swap(Region, &self.current_region, &self.pending_region);
            self.current_region_set = self.pending_region_set;
            self.pending_region.clear();
            self.pending_region_changed = false;
        }
        if (self.pending_cursor_hint_changed) {
            self.cursor_hint = self.pending_cursor_hint;
            self.pending_cursor_hint_changed = false;
        }
        try self.refreshEffectiveRegion();
    }

    fn refreshEffectiveRegion(self: *Constraint) !void {
        try Surface.copyCurrentInputRegion(
            self.manager.surface_store,
            self.surface_id,
            &self.effective_region,
        );
        if (self.current_region_set) {
            try self.effective_region.intersectWith(&self.current_region);
        }
    }

    fn destroy(self: *Constraint) void {
        self.manager.coordinator.unregister(&self.neutral);
        if (self.surface) |surface| surface.removeCommitListener(&self.listener);
        for (self.manager.constraints.items, 0..) |constraint, index| {
            if (constraint != self) continue;
            _ = self.manager.constraints.orderedRemove(index);
            self.current_region.deinit();
            self.pending_region.deinit();
            self.effective_region.deinit();
            self.manager.allocator.destroy(self);
            return;
        }
        unreachable;
    }
};

fn handleLockedRequest(
    resource: *zwp.LockedPointerV1,
    request: zwp.LockedPointerV1.Request,
    constraint: *Constraint,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .set_cursor_position_hint => |hint| {
            constraint.pending_cursor_hint = .{
                .x = hint.surface_x.toDouble(),
                .y = hint.surface_y.toDouble(),
            };
            constraint.pending_cursor_hint_changed = true;
        },
        .set_region => |set| constraint.setPendingRegion(set.region) catch
            resource.postNoMemory(),
    }
}

fn handleLockedDestroy(_: *zwp.LockedPointerV1, constraint: *Constraint) void {
    constraint.destroy();
}

fn handleConfinedRequest(
    resource: *zwp.ConfinedPointerV1,
    request: zwp.ConfinedPointerV1.Request,
    constraint: *Constraint,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .set_region => |set| constraint.setPendingRegion(set.region) catch
            resource.postNoMemory(),
    }
}

fn handleConfinedDestroy(_: *zwp.ConfinedPointerV1, constraint: *Constraint) void {
    constraint.destroy();
}

fn handleSurfaceApplied(context: *anyopaque) void {
    const constraint: *Constraint = @ptrCast(@alignCast(context));
    constraint.applyPending() catch {
        constraint.resource.postNoMemory();
        constraint.manager.coordinator.deactivateConstraint(&constraint.neutral);
        return;
    };
    constraint.manager.syncFocus();
}

fn handleSurfaceDestroyed(context: *anyopaque) void {
    const constraint: *Constraint = @ptrCast(@alignCast(context));
    const surface = constraint.surface orelse unreachable;
    surface.removeCommitListener(&constraint.listener);
    constraint.manager.coordinator.surfaceDestroyed(&constraint.neutral);
    constraint.surface = null;
}
