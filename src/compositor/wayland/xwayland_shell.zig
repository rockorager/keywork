//! Private Xwayland surface identity and serial association.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const SecurityContext = @import("security_context.zig");
const Surface = @import("surface.zig");

const wl = wayland.server.wl;
const xwayland = wayland.server.xwayland;

allocator: std.mem.Allocator,
global: *wl.Global,
security_context: *SecurityContext,
roles: std.ArrayList(*Role),
associations: std.AutoHashMapUnmanaged(u64, Surface.Id),
authorized_client: ?*wl.Client,
client_destroy_listener: wl.Listener(*wl.Client),
listener: Listener,

pub const Listener = struct {
    context: *anyopaque,
    associated: *const fn (*anyopaque, u64, Surface.Id) void,
    committed: *const fn (*anyopaque, u64, Surface.Id, bool) void,
    removed: *const fn (*anyopaque, u64, Surface.Id) void,
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    security_context: *SecurityContext,
    listener: Listener,
) !void {
    self.* = .{
        .allocator = allocator,
        .global = try wl.Global.create(
            display,
            xwayland.ShellV1,
            1,
            *Self,
            self,
            bind,
        ),
        .security_context = security_context,
        .roles = .empty,
        .associations = .empty,
        .authorized_client = null,
        .client_destroy_listener = wl.Listener(*wl.Client).init(clientDestroyed),
        .listener = listener,
    };
    errdefer self.global.destroy();
    errdefer self.roles.deinit(allocator);
    try security_context.privatizeGlobal(self.global);
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.authorized_client == null);
    std.debug.assert(self.roles.items.len == 0);
    std.debug.assert(self.associations.count() == 0);
    self.security_context.unprivatizeGlobal(self.global);
    self.global.destroy();
    self.associations.deinit(self.allocator);
    self.roles.deinit(self.allocator);
    self.* = undefined;
}

/// This must run immediately after creating the private Wayland client and
/// before that client requests its registry.
pub fn authorizeClient(self: *Self, client: *wl.Client) error{AlreadyAuthorized}!void {
    if (self.authorized_client != null) return error.AlreadyAuthorized;
    self.authorized_client = client;
    client.addDestroyListener(&self.client_destroy_listener);
    self.security_context.authorizePrivateGlobal(self.global, client);
}

pub fn surfaceForSerial(self: *const Self, serial: u64) ?Surface.Id {
    return self.associations.get(serial);
}

fn clientDestroyed(listener: *wl.Listener(*wl.Client), client: *wl.Client) void {
    const self: *Self = @fieldParentPtr("client_destroy_listener", listener);
    std.debug.assert(self.authorized_client == client);
    listener.link.remove();
    self.security_context.clearPrivateGlobalClient(self.global);
    self.authorized_client = null;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    if (self.authorized_client != client) {
        client.postImplementationError("xwayland-shell is restricted to Xwayland");
        return;
    }
    const resource = xwayland.ShellV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleShellRequest, null, self);
}

fn handleShellRequest(
    resource: *xwayland.ShellV1,
    request: xwayland.ShellV1.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .get_xwayland_surface => |get| Role.create(
            self,
            resource,
            get.id,
            get.surface,
        ) catch |err| switch (err) {
            error.OutOfMemory => resource.postNoMemory(),
            error.ResourceCreateFailed => resource.getClient().postNoMemory(),
            error.Role => resource.postError(.role, "wl_surface already has another role"),
        },
    }
}

const Role = struct {
    manager: *Self,
    resource: ?*xwayland.SurfaceV1,
    surface: ?*Surface,
    surface_id: Surface.Id,
    pending_serial: ?u64 = null,
    current_serial: ?u64 = null,

    const CreateError = error{ OutOfMemory, ResourceCreateFailed, Role };

    fn create(
        manager: *Self,
        shell_resource: *xwayland.ShellV1,
        id: u32,
        surface_resource: *wl.Surface,
    ) CreateError!void {
        const resource = try xwayland.SurfaceV1.create(
            shell_resource.getClient(),
            shell_resource.getVersion(),
            id,
        );
        errdefer resource.destroy();
        const self = manager.allocator.create(Role) catch return error.OutOfMemory;
        errdefer manager.allocator.destroy(self);
        const surface = Surface.fromResource(surface_resource);
        self.* = .{
            .manager = manager,
            .resource = resource,
            .surface = surface,
            .surface_id = surface.handle(),
        };
        surface.reserveRole(.xwayland, .{
            .context = self,
            .before_commit = beforeCommit,
            .after_commit = afterCommit,
            .surface_destroyed = surfaceDestroyed,
        }) catch return error.Role;
        errdefer surface.releaseRole(self);
        manager.roles.append(manager.allocator, self) catch return error.OutOfMemory;
        surface.assignReservedRole(.xwayland, self) catch unreachable;
        resource.setHandler(*Role, handleRequest, handleResourceDestroy, self);
    }

    fn handleRequest(
        resource: *xwayland.SurfaceV1,
        request: xwayland.SurfaceV1.Request,
        self: *Role,
    ) void {
        switch (request) {
            .destroy => resource.destroy(),
            .set_serial => |set| {
                const serial = @as(u64, set.serial_hi) << 32 | set.serial_lo;
                if (self.current_serial != null) {
                    resource.postError(.already_associated, "wl_surface is already associated");
                    return;
                }
                if (serial == 0 or self.serialInUse(serial)) {
                    resource.postError(.invalid_serial, "Xwayland surface serial is invalid");
                    return;
                }
                self.pending_serial = serial;
            },
        }
    }

    fn handleResourceDestroy(_: *xwayland.SurfaceV1, self: *Role) void {
        self.resource = null;
        self.destroyIfUnused();
    }

    fn beforeCommit(context: *anyopaque, _: Surface.CommitInfo) Surface.CommitAction {
        const self: *Role = @ptrCast(@alignCast(context));
        const serial = self.pending_serial orelse return .apply;
        if (self.current_serial != null) {
            if (self.resource) |resource| {
                resource.postError(.already_associated, "wl_surface is already associated");
            }
            return .reject;
        }
        if (self.serialInUse(serial)) {
            if (self.resource) |resource| {
                resource.postError(.invalid_serial, "Xwayland surface serial is not unique");
            }
            return .reject;
        }
        return .apply;
    }

    fn afterCommit(context: *anyopaque, info: Surface.CommitInfo) void {
        const self: *Role = @ptrCast(@alignCast(context));
        if (self.pending_serial) |serial| {
            self.manager.associations.put(
                self.manager.allocator,
                serial,
                self.surface_id,
            ) catch {
                const surface = self.surface orelse return;
                surface.waylandResource().postNoMemory();
                return;
            };
            self.pending_serial = null;
            self.current_serial = serial;
            self.manager.listener.associated(
                self.manager.listener.context,
                serial,
                self.surface_id,
            );
        }
        const serial = self.current_serial orelse return;
        self.manager.listener.committed(
            self.manager.listener.context,
            serial,
            self.surface_id,
            info.has_buffer,
        );
    }

    fn surfaceDestroyed(context: *anyopaque) void {
        const self: *Role = @ptrCast(@alignCast(context));
        self.surface = null;
        if (self.current_serial) |serial| {
            std.debug.assert(self.manager.associations.remove(serial));
            self.manager.listener.removed(
                self.manager.listener.context,
                serial,
                self.surface_id,
            );
        }
        self.destroyIfUnused();
    }

    fn serialInUse(self: *const Role, serial: u64) bool {
        if (self.pending_serial == serial) return false;
        if (self.manager.associations.contains(serial)) return true;
        for (self.manager.roles.items) |role| {
            if (role != self and role.pending_serial == serial) return true;
        }
        return false;
    }

    fn destroyIfUnused(self: *Role) void {
        if (self.resource != null or self.surface != null) return;
        for (self.manager.roles.items, 0..) |role, index| {
            if (role != self) continue;
            _ = self.manager.roles.swapRemove(index);
            self.manager.allocator.destroy(self);
            return;
        }
        unreachable;
    }
};

test "Xwayland serial combines low and high words" {
    const low: u32 = 0x89ab_cdef;
    const high: u32 = 0x0123_4567;
    try std.testing.expectEqual(
        @as(u64, 0x0123_4567_89ab_cdef),
        @as(u64, high) << 32 | low,
    );
}
