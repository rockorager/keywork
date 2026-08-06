//! Resource-only xdg-decoration adapter for generated XDG toplevels.

const WayringXdgDecoration = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayring = @import("wayring");
const XdgShell = @import("../XdgShell.zig");
const WayringXdgShell = @import("WayringXdgShell.zig");

const Manager = struct {
    owner: *WayringXdgDecoration,
    client: *wayring.server.Client,
    resource: protocol.zxdg_decoration_manager_v1.Resource,
};

const Decoration = struct {
    owner: *WayringXdgDecoration,
    client: *wayring.server.Client,
    resource: protocol.zxdg_toplevel_decoration_v1.Resource,
    identity: WayringXdgShell.ToplevelIdentity,
    configure_sent: bool = false,
};

allocator: std.mem.Allocator,
protocol_server: *wayring.server.Server,
xdg: *WayringXdgShell,
core_shell: *XdgShell,
global: ?*const wayring.server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
decorations: std.ArrayList(*Decoration) = .empty,

pub fn init(self: *WayringXdgDecoration, allocator: std.mem.Allocator, protocol_server: *wayring.server.Server, xdg: *WayringXdgShell, core_shell: *XdgShell) void {
    self.* = .{ .allocator = allocator, .protocol_server = protocol_server, .xdg = xdg, .core_shell = core_shell };
    xdg.setDecorationEndpoint(.{
        .context = self,
        .prepare_configure = prepareConfigure,
        .configured = configured,
        .allows_buffer_commit = allowsBufferCommit,
        .reset = resetConfigure,
        .destroyed = toplevelDestroyed,
    });
}

pub fn publish(self: *WayringXdgDecoration) !void {
    std.debug.assert(self.global == null);
    self.global = try self.protocol_server.addGlobal(protocol.zxdg_decoration_manager_v1, protocol.zxdg_decoration_manager_v1.interface.version, WayringXdgDecoration, self, bind);
}

pub fn unpublish(self: *WayringXdgDecoration) void {
    self.protocol_server.removeGlobal(self.global.?) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}

pub fn destroyClientResources(self: *WayringXdgDecoration, client: *wayring.server.Client) void {
    var i = self.decorations.items.len;
    while (i > 0) : (i -= 1) if (self.decorations.items[i - 1].client == client) self.destroyDecoration(self.decorations.items[i - 1]);
    i = self.managers.items.len;
    while (i > 0) : (i -= 1) if (self.managers.items[i - 1].client == client) self.destroyManager(self.managers.items[i - 1]);
}

pub fn deinit(self: *WayringXdgDecoration) void {
    std.debug.assert(self.global == null and self.managers.items.len == 0 and self.decorations.items.len == 0);
    self.xdg.clearDecorationEndpoint();
    self.decorations.deinit(self.allocator);
    self.managers.deinit(self.allocator);
    self.* = undefined;
}

fn bind(client: *wayring.server.Client, id: u32, version: u32, self: *WayringXdgDecoration) !void {
    try self.managers.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Manager);
    errdefer self.allocator.destroy(value);
    value.* = .{ .owner = self, .client = client, .resource = .init(self.allocator, id, version, .client, client.ownerHooks()) };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Manager, value, handleManager, null);
    try client.materialize(&value.resource.runtime);
    self.managers.appendAssumeCapacity(value);
}

fn handleManager(_: *protocol.zxdg_decoration_manager_v1.Resource, request: protocol.zxdg_decoration_manager_v1.Request, value: *Manager) !void {
    switch (request) {
        .destroy => value.owner.destroyManager(value),
        .get_toplevel_decoration => |args| try value.owner.createDecoration(value, args.id, args.toplevel),
    }
}

fn createDecoration(self: *WayringXdgDecoration, manager: *Manager, id: u32, toplevel_id: u32) !void {
    try self.decorations.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Decoration);
    errdefer self.allocator.destroy(value);
    value.* = .{
        .owner = self,
        .client = manager.client,
        .resource = .init(self.allocator, id, manager.resource.version(), .client, manager.client.ownerHooks()),
        .identity = undefined,
    };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Decoration, value, handleDecoration, null);
    try manager.client.materialize(&value.resource.runtime);
    const identity = self.xdg.toplevelIdentity(manager.client, toplevel_id) orelse {
        manager.client.postProtocolError(&value.resource.runtime, @intCast(protocol.zxdg_toplevel_decoration_v1.@"error".orphaned), "xdg_toplevel is not an exact live same-client generated object");
        value.resource.destroy();
        value.resource.deinit();
        self.allocator.destroy(value);
        return;
    };
    value.identity = identity;
    for (self.decorations.items) |existing| if (self.xdg.identityIsCurrent(existing.identity) and existing.identity.object_id == identity.object_id and existing.client == identity.client) {
        manager.client.postProtocolError(&value.resource.runtime, @intCast(protocol.zxdg_toplevel_decoration_v1.@"error".already_constructed), "xdg_toplevel already has a decoration object");
        value.resource.destroy();
        value.resource.deinit();
        self.allocator.destroy(value);
        return;
    };
    if (value.resource.version() == 1) {
        const content = self.xdg.toplevelContentState(identity) orelse {
            manager.client.postProtocolError(&value.resource.runtime, @intCast(protocol.zxdg_toplevel_decoration_v1.@"error".orphaned), "xdg_toplevel surface is no longer live");
            value.resource.destroy();
            value.resource.deinit();
            self.allocator.destroy(value);
            return;
        };
        if (content.has_pending_attachment or content.has_committed_buffer) {
            manager.client.postProtocolError(&value.resource.runtime, @intCast(protocol.zxdg_toplevel_decoration_v1.@"error".unconfigured_buffer), "version 1 decoration created after a buffer was attached or committed");
            value.resource.destroy();
            value.resource.deinit();
            self.allocator.destroy(value);
            return;
        }
    }
    self.decorations.appendAssumeCapacity(value);
    _ = self.core_shell.createDecoration(identity.core_id);
}

fn handleDecoration(_: *protocol.zxdg_toplevel_decoration_v1.Resource, request: protocol.zxdg_toplevel_decoration_v1.Request, value: *Decoration) !void {
    if (!value.owner.xdg.identityIsCurrent(value.identity) and request != .destroy) {
        value.client.postProtocolError(&value.resource.runtime, @intCast(protocol.zxdg_toplevel_decoration_v1.@"error".orphaned), "xdg_toplevel was destroyed");
        return;
    }
    switch (request) {
        .destroy => value.owner.destroyDecoration(value),
        .set_mode => |args| switch (args.mode) {
            @as(u32, @intCast(protocol.zxdg_toplevel_decoration_v1.mode.client_side)) => _ = value.owner.core_shell.setDecorationPreference(value.identity.core_id, .prefers_csd),
            @as(u32, @intCast(protocol.zxdg_toplevel_decoration_v1.mode.server_side)) => _ = value.owner.core_shell.setDecorationPreference(value.identity.core_id, .prefers_ssd),
            else => value.client.postProtocolError(&value.resource.runtime, @intCast(protocol.zxdg_toplevel_decoration_v1.@"error".invalid_mode), "invalid decoration mode"),
        },
        .unset_mode => _ = value.owner.core_shell.setDecorationPreference(value.identity.core_id, .no_preference),
    }
}

fn prepareConfigure(context: *anyopaque, identity: WayringXdgShell.ToplevelIdentity, mode: XdgShell.DecorationMode) ?wayring.server.Client.PreparedEvent {
    const self: *WayringXdgDecoration = @ptrCast(@alignCast(context));
    for (self.decorations.items) |value| if (sameIdentity(value.identity, identity)) {
        const values = switch (mode) {
            .client_side => &client_side_value,
            .server_side => &server_side_value,
        };
        return .{ .resource = &value.resource.runtime, .opcode = 0, .descriptor = &protocol.zxdg_toplevel_decoration_v1.event_messages[0], .values = values };
    };
    return null;
}

const client_side_value = [_]wayring.wire.Value{.{ .uint = @intCast(protocol.zxdg_toplevel_decoration_v1.mode.client_side) }};
const server_side_value = [_]wayring.wire.Value{.{ .uint = @intCast(protocol.zxdg_toplevel_decoration_v1.mode.server_side) }};

fn configured(context: *anyopaque, identity: WayringXdgShell.ToplevelIdentity) void {
    const self: *WayringXdgDecoration = @ptrCast(@alignCast(context));
    for (self.decorations.items) |value| if (sameIdentity(value.identity, identity)) {
        value.configure_sent = true;
        self.core_shell.decorationConfigured(identity.core_id);
        return;
    };
}

fn allowsBufferCommit(context: *anyopaque, identity: WayringXdgShell.ToplevelIdentity) bool {
    const self: *WayringXdgDecoration = @ptrCast(@alignCast(context));
    for (self.decorations.items) |value| if (sameIdentity(value.identity, identity)) {
        if (value.resource.version() == 1 and !value.configure_sent) {
            value.client.postProtocolError(&value.resource.runtime, @intCast(protocol.zxdg_toplevel_decoration_v1.@"error".unconfigured_buffer), "buffer committed before the initial decoration configure");
            return false;
        }
        return true;
    };
    return true;
}

fn resetConfigure(context: *anyopaque, identity: WayringXdgShell.ToplevelIdentity) void {
    const self: *WayringXdgDecoration = @ptrCast(@alignCast(context));
    for (self.decorations.items) |value| if (sameIdentity(value.identity, identity)) {
        value.configure_sent = false;
        return;
    };
}

fn toplevelDestroyed(context: *anyopaque, identity: WayringXdgShell.ToplevelIdentity) void {
    const self: *WayringXdgDecoration = @ptrCast(@alignCast(context));
    for (self.decorations.items) |value| if (sameIdentity(value.identity, identity)) {
        value.client.postProtocolError(&value.resource.runtime, @intCast(protocol.zxdg_toplevel_decoration_v1.@"error".orphaned), "destroy xdg_toplevel_decoration before xdg_toplevel");
        return;
    };
}

fn destroyDecoration(self: *WayringXdgDecoration, value: *Decoration) void {
    remove(Decoration, &self.decorations, value);
    if (self.xdg.identityIsCurrent(value.identity)) self.core_shell.destroyDecoration(value.identity.core_id);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}
fn destroyManager(self: *WayringXdgDecoration, value: *Manager) void {
    remove(Manager, &self.managers, value);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}
fn sameIdentity(a: WayringXdgShell.ToplevelIdentity, b: WayringXdgShell.ToplevelIdentity) bool {
    return a.client == b.client and a.object_id == b.object_id and a.generation == b.generation and std.meta.eql(a.core_id, b.core_id);
}
fn remove(comptime T: type, list: *std.ArrayList(*T), value: *T) void {
    for (list.items, 0..) |item, i| if (item == value) {
        _ = list.swapRemove(i);
        return;
    };
    unreachable;
}

test "generated decoration descriptors preserve pinned version two and errors" {
    try std.testing.expectEqual(@as(u32, 2), protocol.zxdg_decoration_manager_v1.interface.version);
    try std.testing.expectEqual(@as(u32, 2), protocol.zxdg_toplevel_decoration_v1.interface.version);
    try std.testing.expectEqual(@as(i64, 0), protocol.zxdg_toplevel_decoration_v1.@"error".unconfigured_buffer);
    try std.testing.expectEqual(@as(i64, 1), protocol.zxdg_toplevel_decoration_v1.@"error".already_constructed);
    try std.testing.expectEqual(@as(i64, 2), protocol.zxdg_toplevel_decoration_v1.@"error".orphaned);
    try std.testing.expectEqual(@as(i64, 3), protocol.zxdg_toplevel_decoration_v1.@"error".invalid_mode);
    try std.testing.expectEqualStrings("configure", protocol.zxdg_toplevel_decoration_v1.event_messages[0].name);
}
