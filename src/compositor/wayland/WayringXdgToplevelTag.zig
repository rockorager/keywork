//! Persistent metadata for generated XDG toplevels.

const WayringXdgToplevelTag = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayring = @import("wayring");
const XdgShell = @import("../XdgShell.zig");
const WayringXdgShell = @import("WayringXdgShell.zig");

const server = wayring.server;

const Manager = struct {
    owner: *WayringXdgToplevelTag,
    client: *server.Client,
    resource: protocol.xdg_toplevel_tag_manager_v1.Resource,
};

allocator: std.mem.Allocator,
protocol_server: *server.Server,
xdg_shell: *WayringXdgShell,
global: ?*const server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,

pub fn init(
    self: *WayringXdgToplevelTag,
    allocator: std.mem.Allocator,
    protocol_server: *server.Server,
    xdg_shell: *WayringXdgShell,
) void {
    self.* = .{
        .allocator = allocator,
        .protocol_server = protocol_server,
        .xdg_shell = xdg_shell,
    };
}

pub fn publish(self: *WayringXdgToplevelTag) !void {
    std.debug.assert(self.global == null);
    self.global = try self.protocol_server.addGlobal(
        protocol.xdg_toplevel_tag_manager_v1,
        1,
        WayringXdgToplevelTag,
        self,
        bind,
    );
}

pub fn unpublish(self: *WayringXdgToplevelTag) void {
    const global = self.global orelse return;
    self.protocol_server.removeGlobal(global) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}

pub fn destroyClientResources(self: *WayringXdgToplevelTag, client: *server.Client) void {
    var index = self.managers.items.len;
    while (index > 0) {
        index -= 1;
        if (self.managers.items[index].client == client) self.destroyManager(self.managers.items[index]);
    }
}

pub fn deinit(self: *WayringXdgToplevelTag) void {
    std.debug.assert(self.global == null and self.managers.items.len == 0);
    self.managers.deinit(self.allocator);
    self.* = undefined;
}

fn bind(client: *server.Client, id: u32, version: u32, self: *WayringXdgToplevelTag) !void {
    try self.managers.ensureUnusedCapacity(self.allocator, 1);
    const manager = try self.allocator.create(Manager);
    errdefer self.allocator.destroy(manager);
    manager.* = .{
        .owner = self,
        .client = client,
        .resource = .init(self.allocator, id, version, .client, client.ownerHooks()),
    };
    errdefer {
        manager.resource.destroy();
        manager.resource.deinit();
    }
    try manager.resource.setHandler(Manager, manager, handleRequest, null);
    try client.materialize(&manager.resource.runtime);
    self.managers.appendAssumeCapacity(manager);
}

fn handleRequest(
    _: *protocol.xdg_toplevel_tag_manager_v1.Resource,
    request: protocol.xdg_toplevel_tag_manager_v1.Request,
    manager: *Manager,
) !void {
    switch (request) {
        .destroy => manager.owner.destroyManager(manager),
        .set_toplevel_tag => |args| manager.owner.setMetadata(manager, args.toplevel, .tag, args.tag),
        .set_toplevel_description => |args| manager.owner.setMetadata(manager, args.toplevel, .description, args.description),
    }
}

fn setMetadata(
    self: *WayringXdgToplevelTag,
    manager: *Manager,
    toplevel_object: u32,
    field: XdgShell.ToplevelTagField,
    value: []const u8,
) void {
    self.xdg_shell.setToplevelTag(manager.client, toplevel_object, field, value) catch |err| switch (err) {
        error.OutOfMemory => manager.client.postOutOfMemory(&manager.resource.runtime, "setting XDG toplevel metadata"),
        error.InvalidToplevel => manager.client.postImplementationError(&manager.resource.runtime, "xdg_toplevel is not exact, live, and owned by this client"),
        error.InvalidUtf8 => manager.client.postImplementationError(&manager.resource.runtime, "XDG toplevel metadata is not valid UTF-8"),
    };
}

fn destroyManager(self: *WayringXdgToplevelTag, manager: *Manager) void {
    for (self.managers.items, 0..) |candidate, index| {
        if (candidate != manager) continue;
        _ = self.managers.swapRemove(index);
        manager.resource.destroy();
        manager.resource.deinit();
        self.allocator.destroy(manager);
        return;
    }
}

test "toplevel tag descriptors match the scanner contract" {
    try std.testing.expectEqual(@as(u32, 1), protocol.xdg_toplevel_tag_manager_v1.interface.version);
    try std.testing.expectEqualStrings("set_toplevel_tag", protocol.xdg_toplevel_tag_manager_v1.request_messages[1].name);
    try std.testing.expectEqualStrings("set_toplevel_description", protocol.xdg_toplevel_tag_manager_v1.request_messages[2].name);
}
