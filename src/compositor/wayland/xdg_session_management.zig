//! Mature libwayland frontend for XDG session management.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Authority = @import("../XdgSessionAuthority.zig");
const MatureClients = @import("MatureClients.zig");
const MatureXdgShell = @import("xdg_shell.zig");

const wl = wayland.server.wl;
const xdg = wayland.server.xdg;

allocator: std.mem.Allocator,
global: *wl.Global,
authority: *Authority,
xdg_shell: *MatureXdgShell,
mature_clients: *MatureClients,
session_resources: std.ArrayList(*SessionResource) = .empty,
toplevel_resources: std.ArrayList(*ToplevelResource) = .empty,

pub fn init(self: *Self, allocator: std.mem.Allocator, display: *wl.Server, authority: *Authority, xdg_shell: *MatureXdgShell, mature_clients: *MatureClients) !void {
    self.* = .{ .allocator = allocator, .global = undefined, .authority = authority, .xdg_shell = xdg_shell, .mature_clients = mature_clients };
    errdefer self.session_resources.deinit(allocator);
    errdefer self.toplevel_resources.deinit(allocator);
    self.global = try wl.Global.create(display, xdg.SessionManagerV1, 1, *Self, self, bind);
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.session_resources.items.len == 0);
    std.debug.assert(self.toplevel_resources.items.len == 0);
    self.global.destroy();
    self.session_resources.deinit(self.allocator);
    self.toplevel_resources.deinit(self.allocator);
    self.* = undefined;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = xdg.SessionManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleManagerRequest, null, self);
}
fn handleManagerRequest(resource: *xdg.SessionManagerV1, request: xdg.SessionManagerV1.Request, self: *Self) void {
    switch (request) {
        .destroy => resource.destroy(),
        .get_session => |get| self.getSession(resource, get.id, get.reason, get.session_id),
    }
}
fn getSession(self: *Self, manager: *xdg.SessionManagerV1, id: u32, reason: xdg.SessionManagerV1.Reason, requested_z: ?[*:0]const u8) void {
    switch (reason) {
        .launch, .recover, .session_restore => {},
        _ => {
            manager.postError(.invalid_reason, "invalid session reason");
            return;
        },
    }
    const requested = if (requested_z) |value| std.mem.span(value) else null;
    if (requested) |value| if (!std.unicode.utf8ValidateSlice(value)) {
        manager.postError(.invalid_session_id, "session identifier is not valid UTF-8");
        return;
    };
    const client_id = self.mature_clients.id(manager.getClient()) orelse {
        manager.getClient().postImplementationError("unregistered client");
        return;
    };
    SessionResource.create(self, manager, id, requested, client_id) catch |err| switch (err) {
        error.InUse => manager.postError(.in_use, "session is already in use by this client"),
        error.OutOfMemory, error.ResourceCreateFailed => manager.postNoMemory(),
    };
}

const SessionResource = struct {
    frontend: *Self,
    resource: *xdg.SessionV1,
    session: ?Authority.SessionHandle = null,
    remove_on_destroy: bool = false,

    fn create(frontend: *Self, manager: *xdg.SessionManagerV1, id: u32, requested: ?[]const u8, client_id: @import("../ClientRegistry.zig").Id) error{ InUse, OutOfMemory, ResourceCreateFailed }!void {
        const resource = try xdg.SessionV1.create(manager.getClient(), manager.getVersion(), id);
        errdefer resource.destroy();
        const self = try frontend.allocator.create(SessionResource);
        errdefer frontend.allocator.destroy(self);
        self.* = .{ .frontend = frontend, .resource = resource };
        try frontend.session_resources.append(frontend.allocator, self);
        errdefer _ = frontend.session_resources.pop();
        const result = frontend.authority.acquire(requested, client_id, .{ .context = self, .replaced = replaced }) catch |err| return err;
        self.session = result.session;
        resource.setHandler(*SessionResource, handleRequest, handleDestroy, self);
        if (result.restored) resource.sendRestored() else resource.sendCreated(result.id.ptr);
    }
    fn replaced(context: *anyopaque) void {
        const self: *SessionResource = @ptrCast(@alignCast(context));
        self.resource.sendReplaced();
        self.session = null;
    }
    fn handleRequest(resource: *xdg.SessionV1, request: xdg.SessionV1.Request, self: *SessionResource) void {
        const session = self.session orelse {
            switch (request) {
                .destroy, .remove => resource.destroy(),
                .add_toplevel => |a| self.frontend.createInert(resource.getClient(), resource.getVersion(), a.id),
                .restore_toplevel => |r| self.frontend.createInert(resource.getClient(), resource.getVersion(), r.id),
                .remove_toplevel => {},
            }
            return;
        };
        switch (request) {
            .destroy => resource.destroy(),
            .remove => {
                self.remove_on_destroy = true;
                resource.destroy();
            },
            .add_toplevel => |a| self.addToplevel(session, a.id, a.toplevel, std.mem.span(a.name), false),
            .restore_toplevel => |r| self.addToplevel(session, r.id, r.toplevel, std.mem.span(r.name), true),
            .remove_toplevel => |r| {
                const name = std.mem.span(r.name);
                if (!std.unicode.utf8ValidateSlice(name)) resource.postError(.invalid_name, "toplevel name is not valid UTF-8") else self.frontend.authority.removeToplevel(session, name);
            },
        }
    }
    fn addToplevel(self: *SessionResource, session: Authority.SessionHandle, id: u32, wire_toplevel: *xdg.Toplevel, name: []const u8, restore: bool) void {
        if (!std.unicode.utf8ValidateSlice(name)) {
            self.resource.postError(.invalid_name, "toplevel name is not valid UTF-8");
            return;
        }
        if (wire_toplevel.getClient() != self.resource.getClient()) {
            self.resource.getClient().postImplementationError("xdg_toplevel belongs to another client");
            return;
        }
        const toplevel = self.frontend.xdg_shell.toplevelFromResource(wire_toplevel) orelse {
            self.resource.getClient().postImplementationError("invalid xdg_toplevel resource");
            return;
        };
        const client_id = self.frontend.mature_clients.id(self.resource.getClient()) orelse {
            self.resource.getClient().postImplementationError("unregistered client");
            return;
        };
        ToplevelResource.create(self.frontend, self, self.resource.getClient(), self.resource.getVersion(), id, session, client_id, toplevel.window_id, name, restore) catch |err| switch (err) {
            error.AlreadyMapped => self.resource.postError(.already_mapped, "xdg_toplevel was already mapped"),
            error.AlreadyAdded => self.resource.postError(.already_added, "xdg_toplevel is already in a session"),
            error.NameInUse => self.resource.postError(.name_in_use, "toplevel name is already in use"),
            error.InactiveSession, error.InvalidClient => self.resource.getClient().postImplementationError("invalid XDG session authority identity"),
            error.InvalidWindow => unreachable,
            error.OutOfMemory, error.ResourceCreateFailed => self.resource.postNoMemory(),
        };
    }
    fn handleDestroy(_: *xdg.SessionV1, self: *SessionResource) void {
        if (self.session) |session| self.frontend.authority.release(session, self, self.remove_on_destroy);
        for (self.frontend.session_resources.items, 0..) |candidate, index| if (candidate == self) {
            _ = self.frontend.session_resources.orderedRemove(index);
            self.frontend.allocator.destroy(self);
            return;
        };
        unreachable;
    }
};

const ToplevelResource = struct {
    frontend: *Self,
    session_resource: ?*SessionResource,
    resource: *xdg.ToplevelSessionV1,
    association: ?Authority.AssociationHandle = null,

    fn create(frontend: *Self, session_resource: *SessionResource, client: *wl.Client, version: u32, id: u32, session: Authority.SessionHandle, client_id: @import("../ClientRegistry.zig").Id, window: @import("../XdgShell.zig").WindowId, name: []const u8, restore: bool) (Authority.AddError || error{ResourceCreateFailed})!void {
        const resource = try xdg.ToplevelSessionV1.create(client, version, id);
        errdefer resource.destroy();
        const self = try frontend.allocator.create(ToplevelResource);
        errdefer frontend.allocator.destroy(self);
        self.* = .{ .frontend = frontend, .session_resource = session_resource, .resource = resource };
        try frontend.toplevel_resources.append(frontend.allocator, self);
        errdefer _ = frontend.toplevel_resources.pop();
        self.association = frontend.authority.addToplevel(session, client_id, window, name, restore, .{ .context = self, .restored = restored, .inert = inert }) catch |err| switch (err) {
            error.InvalidWindow => null,
            else => return err,
        };
        resource.setHandler(*ToplevelResource, handleRequest, handleDestroy, self);
    }
    fn restored(context: *anyopaque) void {
        const self: *ToplevelResource = @ptrCast(@alignCast(context));
        self.resource.sendRestored();
    }
    fn inert(context: *anyopaque) void {
        const self: *ToplevelResource = @ptrCast(@alignCast(context));
        self.association = null;
        self.session_resource = null;
    }
    fn handleRequest(resource: *xdg.ToplevelSessionV1, request: xdg.ToplevelSessionV1.Request, self: *ToplevelResource) void {
        switch (request) {
            .destroy => resource.destroy(),
            .rename => |r| self.rename(std.mem.span(r.name)),
        }
    }
    fn rename(self: *ToplevelResource, name: []const u8) void {
        const association = self.association orelse return;
        if (!std.unicode.utf8ValidateSlice(name)) {
            const session = self.session_resource orelse return;
            session.resource.postError(.invalid_name, "toplevel name is not valid UTF-8");
            return;
        }
        self.frontend.authority.rename(association, name) catch |err| switch (err) {
            error.NameInUse => if (self.session_resource) |session| session.resource.postError(.name_in_use, "toplevel name is already in use"),
            error.OutOfMemory => self.resource.postNoMemory(),
        };
    }
    fn handleDestroy(_: *xdg.ToplevelSessionV1, self: *ToplevelResource) void {
        if (self.association) |a| self.frontend.authority.detachAssociationEndpoint(a, self);
        for (self.frontend.toplevel_resources.items, 0..) |candidate, index| if (candidate == self) {
            _ = self.frontend.toplevel_resources.orderedRemove(index);
            self.frontend.allocator.destroy(self);
            return;
        };
        unreachable;
    }
};

fn createInert(self: *Self, client: *wl.Client, version: u32, id: u32) void {
    const resource = xdg.ToplevelSessionV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    const adapter = self.allocator.create(ToplevelResource) catch {
        resource.destroy();
        client.postNoMemory();
        return;
    };
    adapter.* = .{ .frontend = self, .session_resource = null, .resource = resource };
    self.toplevel_resources.append(self.allocator, adapter) catch {
        self.allocator.destroy(adapter);
        resource.destroy();
        client.postNoMemory();
        return;
    };
    resource.setHandler(*ToplevelResource, ToplevelResource.handleRequest, ToplevelResource.handleDestroy, adapter);
}
