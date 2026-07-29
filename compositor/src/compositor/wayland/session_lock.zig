//! Secure session locking and per-output lock surface roles.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
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
global: *wl.Global,
locks: std.ArrayList(*Lock),
active_lock: ?*Lock,
session_locked: bool,
secured_outputs: std.AutoHashMapUnmanaged(OutputLayout.Id, void),
listener: Listener,

pub const Listener = struct {
    context: *anyopaque,
    state_changed: *const fn (*anyopaque, bool) void,
    output_secure_without_frame: *const fn (*anyopaque, OutputLayout.Id) bool,
    repaint: *const fn (*anyopaque) void,
};

pub const SurfaceInfo = struct {
    surface_id: Surface.Id,
    position: struct { x: i32, y: i32 },
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    outputs: *OutputLayout,
    surfaces: *Surface.Store,
    security_context: *SecurityContext,
    listener: Listener,
) !void {
    const global = try wl.Global.create(
        display,
        ext.SessionLockManagerV1,
        1,
        *Self,
        self,
        bind,
    );
    errdefer global.destroy();
    try security_context.restrictGlobal(global);
    self.* = .{
        .allocator = allocator,
        .display = display,
        .outputs = outputs,
        .surfaces = surfaces,
        .security_context = security_context,
        .global = global,
        .locks = .empty,
        .active_lock = null,
        .session_locked = false,
        .secured_outputs = .empty,
        .listener = listener,
    };
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.locks.items.len == 0);
    std.debug.assert(self.active_lock == null);
    self.security_context.unrestrictGlobal(self.global);
    self.global.destroy();
    self.secured_outputs.deinit(self.allocator);
    self.locks.deinit(self.allocator);
    self.* = undefined;
}

pub fn isLocked(self: *const Self) bool {
    return self.session_locked;
}

pub fn surfaceForOutput(self: *Self, output_id: OutputLayout.Id) ?SurfaceInfo {
    if (!self.session_locked) return null;
    const lock = self.active_lock orelse return null;
    for (lock.surfaces.items) |lock_surface| {
        const candidate_output_id = lock_surface.output_id orelse continue;
        if (!std.meta.eql(candidate_output_id, output_id) or !lock_surface.mapped) continue;
        const surface = lock_surface.surface orelse continue;
        const output = self.outputs.get(output_id) orelse continue;
        return .{
            .surface_id = surface.handle(),
            .position = .{
                .x = output.logicalPosition().x,
                .y = output.logicalPosition().y,
            },
        };
    }
    return null;
}

pub fn keyboardFocus(self: *Self) ?Surface.Id {
    if (!self.session_locked) return null;
    const lock = self.active_lock orelse return null;
    if (lock.keyboard_focus) |focus| {
        for (lock.surfaces.items) |lock_surface| {
            if (!lock_surface.mapped) continue;
            const output_id = lock_surface.output_id orelse continue;
            if (self.outputs.get(output_id) == null) continue;
            const surface = lock_surface.surface orelse continue;
            if (std.meta.eql(surface.handle(), focus)) return focus;
        }
    }
    for (lock.surfaces.items) |lock_surface| {
        if (!lock_surface.mapped) continue;
        const output_id = lock_surface.output_id orelse continue;
        if (self.outputs.get(output_id) == null) continue;
        const surface = lock_surface.surface orelse continue;
        lock.keyboard_focus = surface.handle();
        return surface.handle();
    }
    lock.keyboard_focus = null;
    return null;
}

pub fn pointerPressed(self: *Self, root_surface_id: ?Surface.Id) void {
    if (!self.session_locked) return;
    const lock = self.active_lock orelse return;
    const surface_id = root_surface_id orelse return;
    for (lock.surfaces.items) |lock_surface| {
        if (!lock_surface.mapped) continue;
        const output_id = lock_surface.output_id orelse continue;
        if (self.outputs.get(output_id) == null) continue;
        const surface = lock_surface.surface orelse continue;
        if (!std.meta.eql(surface.handle(), surface_id)) continue;
        lock.keyboard_focus = surface_id;
        self.requestRepaint();
        return;
    }
}

pub fn ownsSurface(self: *Self, root_surface_id: Surface.Id) bool {
    if (!self.session_locked) return false;
    const lock = self.active_lock orelse return false;
    for (lock.surfaces.items) |lock_surface| {
        if (!lock_surface.mapped) continue;
        const output_id = lock_surface.output_id orelse continue;
        if (self.outputs.get(output_id) == null) continue;
        const surface = lock_surface.surface orelse continue;
        if (std.meta.eql(surface.handle(), root_surface_id)) return true;
    }
    return false;
}

pub fn outputPresented(self: *Self, output_id: OutputLayout.Id) void {
    const lock = self.active_lock orelse return;
    if (!self.session_locked or lock.outcome != .pending) return;
    if (self.outputs.get(output_id) == null) return;
    self.secured_outputs.put(self.allocator, output_id, {}) catch {
        lock.resource.?.postNoMemory();
        return;
    };
    self.finishLockIfSecure();
}

pub fn outputRemoved(self: *Self, output_id: OutputLayout.Id) void {
    _ = self.secured_outputs.remove(output_id);
    self.finishLockIfSecure();
}

pub fn refreshOutputs(self: *Self) void {
    for (self.locks.items) |lock| {
        for (lock.surfaces.items) |lock_surface| lock_surface.configure() catch {
            if (lock_surface.resource) |resource| resource.postNoMemory();
        };
    }
}

pub fn refreshSecurity(self: *Self) void {
    self.finishLockIfSecure();
}

fn finishLockIfSecure(self: *Self) void {
    const lock = self.active_lock orelse return;
    if (!self.session_locked or lock.outcome != .pending) return;
    var outputs = self.outputs.iterator();
    while (outputs.next()) |entry| {
        if (!self.secured_outputs.contains(entry.id) and
            !self.listener.output_secure_without_frame(self.listener.context, entry.id))
        {
            return;
        }
    }
    lock.outcome = .locked;
    lock.resource.?.sendLocked();
}

fn requestRepaint(self: *Self) void {
    self.listener.repaint(self.listener.context);
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = ext.SessionLockManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleManagerRequest, null, self);
}

fn handleManagerRequest(
    resource: *ext.SessionLockManagerV1,
    request: ext.SessionLockManagerV1.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .lock => |lock| Lock.create(self, resource, lock.id) catch resource.postNoMemory(),
    }
}

const Lock = struct {
    manager: *Self,
    resource: ?*ext.SessionLockV1,
    outcome: Outcome,
    was_locked: bool,
    surfaces: std.ArrayList(*LockSurface),
    keyboard_focus: ?Surface.Id,

    const Outcome = enum { pending, locked, finished };

    fn create(
        manager: *Self,
        manager_resource: *ext.SessionLockManagerV1,
        id: u32,
    ) error{ OutOfMemory, ResourceCreateFailed }!void {
        const resource = try ext.SessionLockV1.create(
            manager_resource.getClient(),
            manager_resource.getVersion(),
            id,
        );
        errdefer resource.destroy();
        const self = manager.allocator.create(Lock) catch return error.OutOfMemory;
        errdefer manager.allocator.destroy(self);
        try manager.locks.append(manager.allocator, self);
        errdefer _ = manager.locks.pop();
        self.* = .{
            .manager = manager,
            .resource = resource,
            .outcome = .finished,
            .was_locked = manager.session_locked,
            .surfaces = .empty,
            .keyboard_focus = null,
        };
        resource.setHandler(*Lock, handleRequest, handleResourceDestroy, self);
        if (manager.active_lock != null) {
            resource.sendFinished();
            return;
        }
        self.outcome = .pending;
        manager.active_lock = self;
        manager.secured_outputs.clearRetainingCapacity();
        if (!manager.session_locked) {
            manager.session_locked = true;
            manager.listener.state_changed(manager.listener.context, true);
        }
        manager.requestRepaint();
        manager.finishLockIfSecure();
    }

    fn handleRequest(
        resource: *ext.SessionLockV1,
        request: ext.SessionLockV1.Request,
        self: *Lock,
    ) void {
        switch (request) {
            .destroy => {
                if (self.outcome == .locked) {
                    resource.postError(.invalid_destroy, "locked session must be explicitly unlocked");
                    return;
                }
                resource.destroy();
            },
            .unlock_and_destroy => {
                if (self.outcome != .locked or self.manager.active_lock != self) {
                    resource.postError(.invalid_unlock, "session lock was not acquired");
                    return;
                }
                self.manager.active_lock = null;
                self.manager.session_locked = false;
                self.manager.secured_outputs.clearRetainingCapacity();
                self.outcome = .finished;
                self.manager.listener.state_changed(self.manager.listener.context, false);
                self.manager.requestRepaint();
                resource.destroy();
            },
            .get_lock_surface => |get| self.createSurface(resource, get) catch |err| switch (err) {
                error.OutOfMemory, error.ResourceCreateFailed => resource.postNoMemory(),
                error.Role => resource.postError(.role, "wl_surface already has a role"),
                error.DuplicateOutput => resource.postError(
                    .duplicate_output,
                    "lock already has a surface for this output",
                ),
                error.AlreadyConstructed => resource.postError(
                    .already_constructed,
                    "wl_surface already has attached or committed content",
                ),
            },
        }
    }

    const CreateSurfaceError = error{
        OutOfMemory,
        ResourceCreateFailed,
        Role,
        DuplicateOutput,
        AlreadyConstructed,
    };

    fn createSurface(
        self: *Lock,
        lock_resource: *ext.SessionLockV1,
        request: anytype,
    ) CreateSurfaceError!void {
        const output_id = if (self.manager.outputs.findResource(request.output)) |output|
            output.id
        else
            null;
        if (output_id) |id| for (self.surfaces.items) |candidate| {
            if (candidate.output_id) |candidate_id| {
                if (std.meta.eql(candidate_id, id)) return error.DuplicateOutput;
            }
        };
        const surface = Surface.fromResource(request.surface);
        if (surface.assignedRole() != null) return error.Role;
        if (surface.hasBufferAttachedOrCommitted()) return error.AlreadyConstructed;
        try LockSurface.create(self, lock_resource, request.id, surface, output_id);
    }

    fn handleResourceDestroy(_: *ext.SessionLockV1, self: *Lock) void {
        self.resource = null;
        const manager = self.manager;
        if (manager.active_lock == self) {
            manager.active_lock = null;
            manager.secured_outputs.clearRetainingCapacity();
            if (self.outcome == .pending and !self.was_locked) {
                manager.session_locked = false;
                manager.listener.state_changed(manager.listener.context, false);
            }
            manager.requestRepaint();
        }
        self.destroyIfUnused();
    }

    fn destroyIfUnused(self: *Lock) void {
        if (self.resource != null or self.surfaces.items.len != 0) return;
        const manager = self.manager;
        for (manager.locks.items, 0..) |candidate, index| {
            if (candidate != self) continue;
            _ = manager.locks.orderedRemove(index);
            self.surfaces.deinit(manager.allocator);
            manager.allocator.destroy(self);
            return;
        }
        unreachable;
    }
};

const LockSurface = struct {
    lock: *Lock,
    resource: ?*ext.SessionLockSurfaceV1,
    surface: ?*Surface,
    output_id: ?OutputLayout.Id,
    configurations: std.ArrayList(Configuration),
    acked_size: ?[2]u32,
    last_configured_size: ?[2]u32,
    mapped: bool,

    const Configuration = struct {
        serial: u32,
        size: [2]u32,
    };

    fn create(
        lock: *Lock,
        lock_resource: *ext.SessionLockV1,
        id: u32,
        surface: *Surface,
        output_id: ?OutputLayout.Id,
    ) error{ OutOfMemory, ResourceCreateFailed, Role }!void {
        const resource = try ext.SessionLockSurfaceV1.create(
            lock_resource.getClient(),
            lock_resource.getVersion(),
            id,
        );
        errdefer resource.destroy();
        const self = lock.manager.allocator.create(LockSurface) catch return error.OutOfMemory;
        errdefer lock.manager.allocator.destroy(self);
        self.* = .{
            .lock = lock,
            .resource = resource,
            .surface = surface,
            .output_id = output_id,
            .configurations = .empty,
            .acked_size = null,
            .last_configured_size = null,
            .mapped = false,
        };
        errdefer self.configurations.deinit(lock.manager.allocator);
        surface.reserveRole(.session_lock, .{
            .context = self,
            .before_commit = beforeCommit,
            .after_commit = afterCommit,
            .surface_destroyed = surfaceDestroyed,
        }) catch return error.Role;
        errdefer surface.releaseRole(self);
        try lock.surfaces.append(lock.manager.allocator, self);
        errdefer _ = lock.surfaces.pop();
        resource.setHandler(*LockSurface, handleRequest, handleResourceDestroy, self);
        surface.assignReservedRole(.session_lock, self) catch unreachable;
        self.configure() catch resource.postNoMemory();
    }

    fn handleRequest(
        resource: *ext.SessionLockSurfaceV1,
        request: ext.SessionLockSurfaceV1.Request,
        self: *LockSurface,
    ) void {
        switch (request) {
            .destroy => resource.destroy(),
            .ack_configure => |ack| self.ackConfigure(resource, ack.serial),
        }
    }

    fn ackConfigure(self: *LockSurface, resource: *ext.SessionLockSurfaceV1, serial: u32) void {
        for (self.configurations.items, 0..) |configuration, index| {
            if (configuration.serial != serial) continue;
            self.acked_size = configuration.size;
            var count = index + 1;
            while (count > 0) : (count -= 1) _ = self.configurations.orderedRemove(0);
            return;
        }
        resource.postError(.invalid_serial, "configure serial was not issued by this lock surface");
    }

    fn configure(self: *LockSurface) error{OutOfMemory}!void {
        const resource = self.resource orelse return;
        const output_id = self.output_id orelse return;
        const output = self.lock.manager.outputs.get(output_id) orelse return;
        const logical_size = output.logicalSize();
        const size = [2]u32{ logical_size.width, logical_size.height };
        if (std.meta.eql(self.last_configured_size, size)) return;
        const serial = self.lock.manager.display.nextSerial();
        try self.configurations.append(self.lock.manager.allocator, .{
            .serial = serial,
            .size = size,
        });
        self.last_configured_size = size;
        resource.sendConfigure(serial, size[0], size[1]);
    }

    fn beforeCommit(context: *anyopaque, info: Surface.CommitInfo) Surface.CommitAction {
        const self: *LockSurface = @ptrCast(@alignCast(context));
        const resource = self.resource orelse return .reject;
        if (!info.has_buffer) {
            resource.postError(.null_buffer, "session lock surface requires a buffer");
            return .reject;
        }
        if (self.acked_size == null) {
            resource.postError(.commit_before_first_ack, "configure must be acknowledged before commit");
            return .reject;
        }
        return .apply;
    }

    fn afterCommit(context: *anyopaque, _: Surface.CommitInfo) void {
        const self: *LockSurface = @ptrCast(@alignCast(context));
        const resource = self.resource orelse return;
        const surface = self.surface orelse return;
        const size = Surface.currentLogicalSize(
            self.lock.manager.surfaces,
            surface.handle(),
        ) orelse return;
        const expected = self.acked_size.?;
        if (size.width != expected[0] or size.height != expected[1]) {
            self.mapped = false;
            resource.postError(.dimensions_mismatch, "lock surface dimensions do not match configure");
            self.lock.manager.requestRepaint();
            return;
        }
        self.mapped = true;
        if (self.lock.keyboard_focus == null) self.lock.keyboard_focus = surface.handle();
        self.lock.manager.requestRepaint();
    }

    fn surfaceDestroyed(context: *anyopaque) void {
        const self: *LockSurface = @ptrCast(@alignCast(context));
        const surface_id = self.surface.?.handle();
        self.surface = null;
        self.mapped = false;
        if (self.lock.keyboard_focus) |focus| {
            if (std.meta.eql(focus, surface_id)) self.lock.keyboard_focus = null;
        }
        self.lock.manager.requestRepaint();
    }

    fn handleResourceDestroy(_: *ext.SessionLockSurfaceV1, self: *LockSurface) void {
        self.resource = null;
        const lock = self.lock;
        if (self.surface) |surface| {
            const surface_id = surface.handle();
            surface.releaseRole(self);
            if (lock.keyboard_focus) |focus| {
                if (std.meta.eql(focus, surface_id)) lock.keyboard_focus = null;
            }
        }
        self.surface = null;
        self.mapped = false;
        for (lock.surfaces.items, 0..) |candidate, index| {
            if (candidate != self) continue;
            _ = lock.surfaces.orderedRemove(index);
            break;
        }
        self.configurations.deinit(lock.manager.allocator);
        lock.manager.allocator.destroy(self);
        lock.manager.requestRepaint();
        lock.destroyIfUnused();
    }
};
