//! Scanner-resource frontend for the shared XDG session authority.

const Self = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayring = @import("wayring");
const Authority = @import("../XdgSessionAuthority.zig");
const WayringClients = @import("WayringClients.zig");
const WayringXdgShell = @import("WayringXdgShell.zig");

const server = wayring.server;

const Manager = struct { owner: *Self, client: *server.Client, resource: protocol.xdg_session_manager_v1.Resource };
const Session = struct {
    owner: *Self,
    client: *server.Client,
    resource: protocol.xdg_session_v1.Resource,
    session: ?Authority.SessionHandle = null,
    remove_on_destroy: bool = false,
};
const Toplevel = struct {
    owner: *Self,
    client: *server.Client,
    resource: protocol.xdg_toplevel_session_v1.Resource,
    session_resource: ?*Session,
    association: ?Authority.AssociationHandle = null,
};

allocator: std.mem.Allocator,
protocol_server: *server.Server,
clients: *WayringClients,
authority: *Authority,
xdg: *WayringXdgShell,
global: ?*const server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
sessions: std.ArrayList(*Session) = .empty,
toplevels: std.ArrayList(*Toplevel) = .empty,

pub fn init(self: *Self, allocator: std.mem.Allocator, protocol_server: *server.Server, clients: *WayringClients, authority: *Authority, xdg: *WayringXdgShell) void {
    self.* = .{ .allocator = allocator, .protocol_server = protocol_server, .clients = clients, .authority = authority, .xdg = xdg };
}
pub fn publish(self: *Self) !void {
    std.debug.assert(self.global == null);
    self.global = try self.protocol_server.addGlobal(protocol.xdg_session_manager_v1, 1, Self, self, bind);
}
pub fn unpublish(self: *Self) void {
    self.protocol_server.removeGlobal(self.global.?) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}
pub fn deinit(self: *Self) void {
    std.debug.assert(self.global == null and self.managers.items.len == 0 and self.sessions.items.len == 0 and self.toplevels.items.len == 0);
    self.toplevels.deinit(self.allocator);
    self.sessions.deinit(self.allocator);
    self.managers.deinit(self.allocator);
    self.* = undefined;
}

fn bind(client: *server.Client, id: u32, version: u32, self: *Self) !void {
    if (version != 1) return error.InvalidVersion;
    try self.managers.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Manager);
    errdefer self.allocator.destroy(value);
    value.* = .{ .owner = self, .client = client, .resource = .init(self.allocator, id, 1, .client, client.ownerHooks()) };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Manager, value, managerRequest, null);
    try client.materialize(&value.resource.runtime);
    self.managers.appendAssumeCapacity(value);
}
fn managerRequest(_: *protocol.xdg_session_manager_v1.Resource, request: protocol.xdg_session_manager_v1.Request, manager: *Manager) !void {
    switch (request) {
        .destroy => manager.owner.destroyManager(manager),
        .get_session => |args| manager.owner.createSession(manager, args.id, args.reason, args.session_id),
    }
}
fn createSession(self: *Self, manager: *Manager, id: u32, reason: u32, requested: ?[]const u8) void {
    if (!validReason(reason)) return manager.client.postProtocolError(&manager.resource.runtime, @intCast(protocol.xdg_session_manager_v1.@"error".invalid_reason), "invalid session reason");
    if (requested) |value| if (!std.unicode.utf8ValidateSlice(value)) return manager.client.postProtocolError(&manager.resource.runtime, @intCast(protocol.xdg_session_manager_v1.@"error".invalid_session_id), "session identifier is not valid UTF-8");
    const client_id = self.clients.id(manager.client) orelse return manager.client.postImplementationError(&manager.resource.runtime, "unregistered client");
    self.sessions.ensureUnusedCapacity(self.allocator, 1) catch return manager.client.postOutOfMemory(&manager.resource.runtime, "creating XDG session");
    const value = self.allocator.create(Session) catch return manager.client.postOutOfMemory(&manager.resource.runtime, "creating XDG session");
    value.* = .{ .owner = self, .client = manager.client, .resource = .init(self.allocator, id, 1, .client, manager.client.ownerHooks()) };
    value.resource.setHandler(Session, value, sessionRequest, null) catch {
        self.allocator.destroy(value);
        return manager.client.postOutOfMemory(&manager.resource.runtime, "creating XDG session");
    };
    manager.client.materialize(&value.resource.runtime) catch {
        value.resource.destroy();
        value.resource.deinit();
        self.allocator.destroy(value);
        return manager.client.postOutOfMemory(&manager.resource.runtime, "creating XDG session");
    };
    self.sessions.appendAssumeCapacity(value);
    const result = self.authority.acquire(requested, client_id, .{ .context = value, .replaced = replaced }) catch |err| {
        self.destroySession(value);
        return switch (err) {
            error.InUse => manager.client.postProtocolError(&manager.resource.runtime, @intCast(protocol.xdg_session_manager_v1.@"error".in_use), "session is already in use by this client"),
            error.OutOfMemory => manager.client.postOutOfMemory(&manager.resource.runtime, "acquiring XDG session"),
        };
    };
    value.session = result.session;
    if (result.restored) protocol.xdg_session_v1.@"send:restored"(&value.resource) catch eventFailure(value.client, &value.resource.runtime, "queueing restored event") else protocol.xdg_session_v1.@"send:created"(&value.resource, result.id) catch eventFailure(value.client, &value.resource.runtime, "queueing created event");
}
fn replaced(context: *anyopaque) void {
    const value: *Session = @ptrCast(@alignCast(context));
    value.session = null;
    protocol.xdg_session_v1.@"send:replaced"(&value.resource) catch eventFailure(value.client, &value.resource.runtime, "queueing replaced event");
}
fn sessionRequest(_: *protocol.xdg_session_v1.Resource, request: protocol.xdg_session_v1.Request, value: *Session) !void {
    const session = value.session orelse return switch (request) {
        .destroy, .remove => value.owner.destroySession(value),
        .add_toplevel => |args| value.owner.createInert(value, args.id),
        .restore_toplevel => |args| value.owner.createInert(value, args.id),
        .remove_toplevel => {},
    };
    switch (request) {
        .destroy => value.owner.destroySession(value),
        .remove => {
            value.remove_on_destroy = true;
            value.owner.destroySession(value);
        },
        .add_toplevel => |args| value.owner.createToplevel(value, session, args.id, args.toplevel, args.name, false),
        .restore_toplevel => |args| value.owner.createToplevel(value, session, args.id, args.toplevel, args.name, true),
        .remove_toplevel => |args| if (!std.unicode.utf8ValidateSlice(args.name)) value.client.postProtocolError(&value.resource.runtime, @intCast(protocol.xdg_session_v1.@"error".invalid_name), "toplevel name is not valid UTF-8") else value.owner.authority.removeToplevel(session, args.name),
    }
}
fn createToplevel(self: *Self, session_resource: *Session, session: Authority.SessionHandle, id: u32, object_id: u32, name: []const u8, restore: bool) void {
    if (!std.unicode.utf8ValidateSlice(name)) return session_resource.client.postProtocolError(&session_resource.resource.runtime, @intCast(protocol.xdg_session_v1.@"error".invalid_name), "toplevel name is not valid UTF-8");
    const identity = self.xdg.toplevelIdentity(session_resource.client, object_id) orelse return session_resource.client.postImplementationError(&session_resource.resource.runtime, "xdg_toplevel is not an exact live same-client generated object");
    const client_id = self.clients.id(session_resource.client) orelse return session_resource.client.postImplementationError(&session_resource.resource.runtime, "unregistered client");
    const value = self.makeToplevel(session_resource, id) catch return session_resource.client.postOutOfMemory(&session_resource.resource.runtime, "creating toplevel session");
    value.association = self.authority.addToplevel(session, client_id, identity.core_id, name, restore, .{ .context = value, .restored = restored, .inert = inert }) catch |err| switch (err) {
        error.InvalidWindow => null,
        error.AlreadyMapped => return self.failToplevel(value, session_resource, protocol.xdg_session_v1.@"error".already_mapped, "xdg_toplevel was already mapped"),
        error.AlreadyAdded => return self.failToplevel(value, session_resource, protocol.xdg_session_v1.@"error".already_added, "xdg_toplevel is already in a session"),
        error.NameInUse => return self.failToplevel(value, session_resource, protocol.xdg_session_v1.@"error".name_in_use, "toplevel name is already in use"),
        error.InactiveSession, error.InvalidClient => return self.failImplementation(value, session_resource),
        error.OutOfMemory => return self.failOutOfMemory(value, session_resource),
    };
}
fn makeToplevel(self: *Self, session: ?*Session, id: u32) !*Toplevel {
    try self.toplevels.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Toplevel);
    errdefer self.allocator.destroy(value);
    const client = session.?.client;
    value.* = .{ .owner = self, .client = client, .resource = .init(self.allocator, id, 1, .client, client.ownerHooks()), .session_resource = session };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Toplevel, value, toplevelRequest, null);
    try client.materialize(&value.resource.runtime);
    self.toplevels.appendAssumeCapacity(value);
    return value;
}
fn createInert(self: *Self, session: *Session, id: u32) void {
    _ = self.makeToplevel(session, id) catch session.client.postOutOfMemory(&session.resource.runtime, "creating inert toplevel session");
}
fn restored(context: *anyopaque) void {
    const value: *Toplevel = @ptrCast(@alignCast(context));
    protocol.xdg_toplevel_session_v1.@"send:restored"(&value.resource) catch eventFailure(value.client, &value.resource.runtime, "queueing toplevel restored event");
}
fn inert(context: *anyopaque) void {
    const value: *Toplevel = @ptrCast(@alignCast(context));
    value.association = null;
    value.session_resource = null;
}
fn toplevelRequest(_: *protocol.xdg_toplevel_session_v1.Resource, request: protocol.xdg_toplevel_session_v1.Request, value: *Toplevel) !void {
    switch (request) {
        .destroy => value.owner.destroyToplevel(value),
        .rename => |args| value.owner.rename(value, args.name),
    }
}
fn rename(self: *Self, value: *Toplevel, name: []const u8) void {
    const association = value.association orelse return;
    if (!std.unicode.utf8ValidateSlice(name)) return if (value.session_resource) |session| session.client.postProtocolError(&session.resource.runtime, @intCast(protocol.xdg_session_v1.@"error".invalid_name), "toplevel name is not valid UTF-8");
    self.authority.rename(association, name) catch |err| switch (err) {
        error.NameInUse => if (value.session_resource) |session| session.client.postProtocolError(&session.resource.runtime, @intCast(protocol.xdg_session_v1.@"error".name_in_use), "toplevel name is already in use"),
        error.OutOfMemory => value.client.postOutOfMemory(&value.resource.runtime, "renaming toplevel session"),
    };
}
fn failToplevel(self: *Self, value: *Toplevel, session: *Session, code: u32, message: []const u8) void {
    self.destroyToplevel(value);
    session.client.postProtocolError(&session.resource.runtime, code, message);
}
fn failImplementation(self: *Self, value: *Toplevel, session: *Session) void {
    self.destroyToplevel(value);
    session.client.postImplementationError(&session.resource.runtime, "invalid XDG session authority identity");
}
fn failOutOfMemory(self: *Self, value: *Toplevel, session: *Session) void {
    self.destroyToplevel(value);
    session.client.postOutOfMemory(&session.resource.runtime, "adding toplevel session");
}
fn destroyToplevel(self: *Self, value: *Toplevel) void {
    if (value.association) |a| self.authority.detachAssociationEndpoint(a, value);
    remove(Toplevel, &self.toplevels, value);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}
fn destroySession(self: *Self, value: *Session) void {
    if (value.session) |s| self.authority.release(s, value, value.remove_on_destroy);
    remove(Session, &self.sessions, value);
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
pub fn destroyClientResources(self: *Self, client: *server.Client) void {
    var i = self.sessions.items.len;
    while (i > 0) {
        i -= 1;
        if (self.sessions.items[i].client == client) self.destroySession(self.sessions.items[i]);
    }
    i = self.toplevels.items.len;
    while (i > 0) {
        i -= 1;
        if (self.toplevels.items[i].client == client) self.destroyToplevel(self.toplevels.items[i]);
    }
    i = self.managers.items.len;
    while (i > 0) {
        i -= 1;
        if (self.managers.items[i].client == client) self.destroyManager(self.managers.items[i]);
    }
}
fn validReason(reason: u32) bool {
    return reason >= 1 and reason <= 3;
}
fn eventFailure(client: *server.Client, resource: *server.Resource, detail: []const u8) void {
    client.postOutOfMemory(resource, detail);
}
fn remove(comptime T: type, list: *std.ArrayList(*T), value: *T) void {
    for (list.items, 0..) |candidate, i| if (candidate == value) {
        _ = list.swapRemove(i);
        return;
    };
    unreachable;
}

test "scanner XDG session descriptors and errors are pinned" {
    try std.testing.expectEqual(@as(u32, 1), protocol.xdg_session_manager_v1.interface.version);
    try std.testing.expectEqual(@as(i64, 1), protocol.xdg_session_manager_v1.@"error".in_use);
    try std.testing.expectEqual(@as(i64, 4), protocol.xdg_session_v1.@"error".already_added);
    try std.testing.expect(validReason(1) and validReason(3) and !validReason(0) and !validReason(4));
}
