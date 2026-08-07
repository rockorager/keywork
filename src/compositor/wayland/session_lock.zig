//! Libwayland adapter for the frontend-neutral session-lock owner.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Core = @import("../SessionLock.zig");
const MatureClients = @import("MatureClients.zig");
const MatureSerials = @import("mature_serials.zig");
const OutputLayout = @import("output_layout.zig");
const SecurityContext = @import("security_context.zig");
const Surface = @import("surface.zig");

const wl = wayland.server.wl;
const ext = wayland.server.ext;

allocator: std.mem.Allocator,
display: *wl.Server,
outputs: *OutputLayout,
surfaces: *Surface.Store,
security_context: *SecurityContext,
core: *Core,
mature_clients: *MatureClients,
global: *wl.Global,
locks: std.ArrayList(*Lock),

pub const SurfaceInfo = struct {
    surface_id: Surface.Id,
    position: struct { x: i32, y: i32 },
};

pub fn init(self: *Self, allocator: std.mem.Allocator, display: *wl.Server, outputs: *OutputLayout, surfaces: *Surface.Store, security_context: *SecurityContext, core: *Core, mature_clients: *MatureClients) !void {
    const global = try wl.Global.create(display, ext.SessionLockManagerV1, 1, *Self, self, bind);
    errdefer global.destroy();
    try security_context.restrictGlobal(global);
    self.* = .{ .allocator = allocator, .display = display, .outputs = outputs, .surfaces = surfaces, .security_context = security_context, .core = core, .mature_clients = mature_clients, .global = global, .locks = .empty };
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.locks.items.len == 0);
    self.security_context.unrestrictGlobal(self.global);
    self.global.destroy();
    self.locks.deinit(self.allocator);
    self.* = undefined;
}

pub fn isLocked(self: *const Self) bool {
    return self.core.isLocked();
}

pub fn surfaceForOutput(self: *Self, output_id: OutputLayout.Id) ?SurfaceInfo {
    const snapshot = self.core.surfaceForOutput(output_id) orelse return null;
    const output = self.outputs.get(output_id) orelse return null;
    return .{ .surface_id = snapshot.surface, .position = .{ .x = output.logicalPosition().x, .y = output.logicalPosition().y } };
}

pub fn ownsSurface(self: *Self, surface: Surface.Id) bool {
    return self.core.ownsMappedSurface(surface);
}

pub fn outputPresented(self: *Self, output: OutputLayout.Id) void {
    self.core.outputPresented(output) catch {
        const active = self.core.activeLock() orelse return;
        for (self.locks.items) |lock| if (std.meta.eql(lock.id, active)) {
            if (lock.resource) |resource| resource.postNoMemory();
            return;
        };
    };
}
pub fn outputRemoved(self: *Self, output: OutputLayout.Id) void {
    self.core.outputRemoved(output);
}
pub fn refreshSecurity(self: *Self) void {
    self.core.refreshSecurity();
}

pub fn refreshOutputs(self: *Self) void {
    for (self.locks.items) |lock| for (lock.surfaces.items) |adapter| {
        const id = adapter.id orelse continue;
        const snapshot = self.core.snapshot(id) orelse continue;
        const output = self.outputs.get(snapshot.output) orelse continue;
        const size = output.logicalSize();
        if (snapshot.configured_size != null and snapshot.configured_size.?[0] == size.width and snapshot.configured_size.?[1] == size.height) continue;
        _ = self.core.configure(id, size.width, size.height) catch |err| switch (err) {
            error.OutOfMemory => if (adapter.resource) |resource| resource.postNoMemory(),
            error.InvalidSurface, error.SequenceExhausted => {},
        };
    };
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = ext.SessionLockManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleManagerRequest, null, self);
}
fn handleManagerRequest(resource: *ext.SessionLockManagerV1, request: ext.SessionLockManagerV1.Request, self: *Self) void {
    switch (request) {
        .destroy => resource.destroy(),
        .lock => |request_lock| Lock.create(self, resource, request_lock.id) catch resource.postNoMemory(),
    }
}

const Lock = struct {
    manager: *Self,
    resource: ?*ext.SessionLockV1,
    id: Core.LockId,
    surfaces: std.ArrayList(*LockSurface),

    fn create(manager: *Self, manager_resource: *ext.SessionLockManagerV1, id: u32) !void {
        const resource = try ext.SessionLockV1.create(manager_resource.getClient(), manager_resource.getVersion(), id);
        errdefer resource.destroy();
        const self = try manager.allocator.create(Lock);
        errdefer manager.allocator.destroy(self);
        self.* = .{ .manager = manager, .resource = resource, .id = undefined, .surfaces = .empty };
        errdefer self.surfaces.deinit(manager.allocator);
        try manager.locks.append(manager.allocator, self);
        errdefer _ = manager.locks.pop();
        const client = manager.mature_clients.id(resource.getClient()) orelse return error.OutOfMemory;
        self.id = try manager.core.createLock(client, .{ .context = self, .acquired = acquired, .finished = finished });
        resource.setHandler(*Lock, handleRequest, handleResourceDestroy, self);
    }
    fn acquired(context: *anyopaque) void {
        const self: *Lock = @ptrCast(@alignCast(context));
        if (self.resource) |resource| resource.sendLocked();
    }
    fn finished(context: *anyopaque) void {
        const self: *Lock = @ptrCast(@alignCast(context));
        if (self.resource) |resource| resource.sendFinished();
    }

    fn handleRequest(resource: *ext.SessionLockV1, request: ext.SessionLockV1.Request, self: *Lock) void {
        switch (request) {
            .destroy => if (!self.manager.core.mayDestroyLock(self.id)) resource.postError(.invalid_destroy, "locked session must be explicitly unlocked") else resource.destroy(),
            .unlock_and_destroy => {
                self.manager.core.unlockAndDestroy(self.id) catch {
                    resource.postError(.invalid_unlock, "session lock was not acquired");
                    return;
                };
                resource.destroy();
            },
            .get_lock_surface => |get| self.createSurface(resource, get) catch |err| switch (err) {
                error.OutOfMemory, error.ResourceCreateFailed => resource.postNoMemory(),
                error.Role, error.InvalidOwner => resource.postError(.role, "wl_surface already has a role"),
                error.DuplicateOutput => resource.postError(.duplicate_output, "lock already has a surface for this output"),
                error.AlreadyConstructed => resource.postError(.already_constructed, "wl_surface already has attached or committed content"),
            },
        }
    }

    const CreateError = error{ OutOfMemory, ResourceCreateFailed, Role, InvalidOwner, DuplicateOutput, AlreadyConstructed };
    fn createSurface(self: *Lock, lock_resource: *ext.SessionLockV1, request: anytype) CreateError!void {
        if (request.surface.getClient() != lock_resource.getClient() or request.output.getClient() != lock_resource.getClient()) return error.InvalidOwner;
        const output = self.manager.outputs.findResource(request.output);
        const surface = Surface.fromResource(request.surface);
        if (surface.assignedRole() != null) return error.Role;
        if (surface.hasBufferAttachedOrCommitted()) return error.AlreadyConstructed;
        try LockSurface.create(self, lock_resource, request.id, surface, if (output) |value| value.id else null);
    }
    fn handleResourceDestroy(_: *ext.SessionLockV1, self: *Lock) void {
        self.resource = null;
        self.manager.core.destroyLock(self.id);
        self.destroyIfUnused();
    }

    fn destroyIfUnused(self: *Lock) void {
        if (self.resource != null or self.surfaces.items.len != 0) return;
        for (self.manager.locks.items, 0..) |candidate, index| if (candidate == self) {
            _ = self.manager.locks.orderedRemove(index);
            break;
        };
        self.surfaces.deinit(self.manager.allocator);
        self.manager.allocator.destroy(self);
    }
};

const LockSurface = struct {
    lock: *Lock,
    resource: ?*ext.SessionLockSurfaceV1,
    surface: ?*Surface,
    id: ?Core.LockSurfaceId,
    serials: std.ArrayList(SerialMapping),
    const SerialMapping = struct { wire: u32, token: Core.ConfigureToken };

    fn create(lock: *Lock, lock_resource: *ext.SessionLockV1, id: u32, surface: *Surface, output: ?OutputLayout.Id) Lock.CreateError!void {
        const resource = try ext.SessionLockSurfaceV1.create(lock_resource.getClient(), lock_resource.getVersion(), id);
        errdefer resource.destroy();
        const self = try lock.manager.allocator.create(LockSurface);
        errdefer lock.manager.allocator.destroy(self);
        self.* = .{ .lock = lock, .resource = resource, .surface = surface, .id = null, .serials = .empty };
        errdefer self.serials.deinit(lock.manager.allocator);
        surface.reserveRole(.session_lock, .{ .context = self, .before_commit = beforeCommit, .after_commit = afterCommit, .surface_destroyed = surfaceDestroyed }) catch return error.Role;
        errdefer surface.releaseRole(self);
        try lock.surfaces.append(lock.manager.allocator, self);
        errdefer _ = lock.surfaces.pop();
        if (output) |output_id| {
            const client = lock.manager.mature_clients.id(lock_resource.getClient()) orelse return error.InvalidOwner;
            self.id = lock.manager.core.createSurface(lock.id, client, surface.handle(), client, output_id, .{ .context = self, .configure = configureEndpoint }) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.DuplicateOutput => error.DuplicateOutput,
                error.InvalidLock, error.InvalidClient, error.InvalidSurface, error.ForeignSurface, error.InvalidOutput => error.InvalidOwner,
            };
            errdefer lock.manager.core.destroySurface(self.id.?);
        }
        resource.setHandler(*LockSurface, handleRequest, handleResourceDestroy, self);
        surface.assignReservedRole(.session_lock, self) catch unreachable;
        const output_id = output orelse return;
        const size = lock.manager.outputs.get(output_id).?.logicalSize();
        _ = lock.manager.core.configure(self.id.?, size.width, size.height) catch |err| switch (err) {
            error.OutOfMemory => resource.postNoMemory(),
            else => {},
        };
    }
    fn configureEndpoint(context: *anyopaque, width: u32, height: u32, token: Core.ConfigureToken) error{OutOfMemory}!void {
        const self: *LockSurface = @ptrCast(@alignCast(context));
        const resource = self.resource orelse return;
        const wire = MatureSerials.issueWire(self.lock.manager.display);
        try self.serials.append(self.lock.manager.allocator, .{ .wire = wire, .token = token });
        errdefer _ = self.serials.pop();
        resource.sendConfigure(wire, width, height);
    }
    fn handleRequest(resource: *ext.SessionLockSurfaceV1, request: ext.SessionLockSurfaceV1.Request, self: *LockSurface) void {
        switch (request) {
            .destroy => resource.destroy(),
            .ack_configure => |request_ack| self.ack(resource, request_ack.serial),
        }
    }
    fn ack(self: *LockSurface, resource: *ext.SessionLockSurfaceV1, wire: u32) void {
        const id = self.id orelse {
            resource.postError(.invalid_serial, "configure serial was not issued by this lock surface");
            return;
        };
        for (self.serials.items, 0..) |mapping, index| if (mapping.wire == wire) {
            self.lock.manager.core.ackConfigure(id, mapping.token) catch {
                resource.postError(.invalid_serial, "configure serial was not issued by this lock surface");
                return;
            };
            self.serials.replaceRangeAssumeCapacity(0, index + 1, &.{});
            return;
        };
        resource.postError(.invalid_serial, "configure serial was not issued by this lock surface");
    }
    fn beforeCommit(context: *anyopaque, info: Surface.CommitInfo) Surface.CommitAction {
        const self: *LockSurface = @ptrCast(@alignCast(context));
        const id = self.id orelse {
            if (self.resource) |resource| if (info.has_buffer)
                resource.postError(.commit_before_first_ack, "configure must be acknowledged before commit")
            else
                resource.postError(.null_buffer, "session lock surface requires a buffer");
            return .reject;
        };
        self.lock.manager.core.validateCommit(id, info.has_buffer) catch |err| {
            if (self.resource) |resource| switch (err) {
                error.NullBuffer => resource.postError(.null_buffer, "session lock surface requires a buffer"),
                error.CommitBeforeAck => resource.postError(.commit_before_first_ack, "configure must be acknowledged before commit"),
                error.InvalidSurface => {},
            };
            return .reject;
        };
        return .apply;
    }
    fn afterCommit(context: *anyopaque, _: Surface.CommitInfo) void {
        const self: *LockSurface = @ptrCast(@alignCast(context));
        const id = self.id orelse return;
        const surface = self.surface orelse return;
        const size = Surface.currentLogicalSize(self.lock.manager.surfaces, surface.handle()) orelse return;
        self.lock.manager.core.map(id, size.width, size.height) catch |err| switch (err) {
            error.DimensionsMismatch => if (self.resource) |resource| resource.postError(.dimensions_mismatch, "lock surface dimensions do not match configure"),
            else => {},
        };
    }
    fn surfaceDestroyed(context: *anyopaque) void {
        const self: *LockSurface = @ptrCast(@alignCast(context));
        const id = self.surface.?.handle();
        self.surface = null;
        if (self.id != null) self.lock.manager.core.surfaceDestroyed(id);
    }
    fn handleResourceDestroy(_: *ext.SessionLockSurfaceV1, self: *LockSurface) void {
        self.resource = null;
        if (self.surface) |surface| surface.releaseRole(self);
        self.surface = null;
        if (self.id) |id| self.lock.manager.core.destroySurface(id);
        const lock = self.lock;
        for (lock.surfaces.items, 0..) |candidate, index| if (candidate == self) {
            _ = lock.surfaces.orderedRemove(index);
            break;
        };
        self.serials.deinit(lock.manager.allocator);
        lock.manager.allocator.destroy(self);
        lock.destroyIfUnused();
    }
};
