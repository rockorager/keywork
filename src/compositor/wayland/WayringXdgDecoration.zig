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

test "global publication allocation failure installs no decoration global" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    failing.fail_index = 0;
    var host: wayring.server.Server = .init(failing.allocator());
    defer host.deinit();
    var adapter: WayringXdgDecoration = .{
        .allocator = std.testing.allocator,
        .protocol_server = &host,
        .xdg = undefined,
        .core_shell = undefined,
    };
    defer {
        adapter.decorations.deinit(adapter.allocator);
        adapter.managers.deinit(adapter.allocator);
    }

    try std.testing.expectError(error.OutOfMemory, adapter.publish());
    try std.testing.expect(adapter.global == null);
    var globals = host.iterator();
    try std.testing.expect(globals.next() == null);
    try std.testing.expect(failing.has_induced_failure);
}

test "manager and decoration allocation failures leave no half-owned resource" {
    inline for (.{ false, true }) |fail_decoration| {
        var harness: WayringXdgShell.TestHarness = undefined;
        try harness.init();
        defer harness.deinit();
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var adapter: WayringXdgDecoration = undefined;
        adapter.init(failing.allocator(), &harness.host, &harness.adapter, &harness.core_shell);
        try adapter.publish();
        defer {
            adapter.destroyClientResources(harness.client());
            adapter.unpublish();
            adapter.deinit();
        }
        try harness.createSurface();
        try harness.installManager(2);
        try harness.createToplevel();

        if (fail_decoration) {
            try harness.bindGlobal("zxdg_decoration_manager_v1", 8, 2);
            try std.testing.expectEqual(@as(usize, 1), adapter.managers.items.len);
        }
        failing.fail_index = failing.alloc_index;
        if (fail_decoration) {
            harness.send(8, 1, &protocol.zxdg_decoration_manager_v1.request_messages[1], &.{
                .{ .new_id = .{ .typed = 9 } }, .{ .object = 7 },
            }) catch {};
            try std.testing.expectEqual(@as(usize, 0), adapter.decorations.items.len);
            try std.testing.expect(harness.client().lookup(9) == null);
        } else {
            harness.bindGlobal("zxdg_decoration_manager_v1", 8, 2) catch {};
            try std.testing.expectEqual(@as(usize, 0), adapter.managers.items.len);
            try std.testing.expect(harness.client().lookup(8) == null);
        }
        try std.testing.expect(failing.has_induced_failure);
    }
}

test "decoration request materializes before semantic ownership" {
    var harness: WayringXdgShell.TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    var adapter: WayringXdgDecoration = undefined;
    adapter.init(std.testing.allocator, &harness.host, &harness.adapter, &harness.core_shell);
    try adapter.publish();
    defer {
        adapter.unpublish();
        adapter.deinit();
    }
    try harness.createSurface();
    try harness.installManager(2);
    try harness.createToplevel();
    try harness.bindGlobal("zxdg_decoration_manager_v1", 8, 2);
    defer adapter.destroyClientResources(harness.client());

    try harness.send(8, 1, &protocol.zxdg_decoration_manager_v1.request_messages[1], &.{
        .{ .new_id = .{ .typed = 9 } }, .{ .object = 7 },
    });
    try std.testing.expectEqual(@as(usize, 1), adapter.decorations.items.len);
}

test "reused toplevel object id receives a distinct decoration identity" {
    var harness: WayringXdgShell.TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    var adapter: WayringXdgDecoration = undefined;
    adapter.init(std.testing.allocator, &harness.host, &harness.adapter, &harness.core_shell);
    try adapter.publish();
    defer {
        adapter.unpublish();
        adapter.deinit();
    }
    try harness.createSurface();
    try harness.installManager(2);
    try harness.createToplevel();
    try harness.bindGlobal("zxdg_decoration_manager_v1", 8, 2);
    defer adapter.destroyClientResources(harness.client());

    try harness.send(8, 1, &protocol.zxdg_decoration_manager_v1.request_messages[1], &.{
        .{ .new_id = .{ .typed = 9 } }, .{ .object = 7 },
    });
    const old_identity = adapter.decorations.items[0].identity;
    try harness.send(9, 0, &protocol.zxdg_toplevel_decoration_v1.request_messages[0], &.{});
    try harness.destroyToplevel();
    try harness.recreateToplevel();
    try harness.send(8, 1, &protocol.zxdg_decoration_manager_v1.request_messages[1], &.{
        .{ .new_id = .{ .typed = 9 } }, .{ .object = 7 },
    });

    const new_identity = adapter.decorations.items[0].identity;
    try std.testing.expectEqual(old_identity.object_id, new_identity.object_id);
    try std.testing.expect(old_identity.generation != new_identity.generation);
    try std.testing.expect(!sameIdentity(old_identity, new_identity));
    try std.testing.expect(!harness.adapter.identityIsCurrent(old_identity));
    try std.testing.expect(harness.adapter.identityIsCurrent(new_identity));
}
