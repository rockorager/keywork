//! Scanner-backed XDG system bell requests.

const WayringSystemBell = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayring = @import("wayring");

const server = wayring.server;

const Value = struct {
    owner: *WayringSystemBell,
    client: *server.Client,
    resource: protocol.xdg_system_bell_v1.Resource,
};

allocator: std.mem.Allocator,
protocol_server: *server.Server,
global: ?*const server.Server.Global = null,
values: std.ArrayList(*Value) = .empty,

pub fn init(self: *WayringSystemBell, allocator: std.mem.Allocator, protocol_server: *server.Server) void {
    self.* = .{ .allocator = allocator, .protocol_server = protocol_server };
}

pub fn publish(self: *WayringSystemBell) !void {
    self.global = try self.protocol_server.addGlobal(protocol.xdg_system_bell_v1, 1, WayringSystemBell, self, bind);
}

pub fn unpublish(self: *WayringSystemBell) void {
    self.protocol_server.removeGlobal(self.global.?) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}

pub fn destroyClientResources(self: *WayringSystemBell, client: *server.Client) void {
    var i = self.values.items.len;
    while (i > 0) {
        i -= 1;
        if (self.values.items[i].client == client) self.destroyValue(self.values.items[i]);
    }
}

pub fn deinit(self: *WayringSystemBell) void {
    std.debug.assert(self.global == null and self.values.items.len == 0);
    self.values.deinit(self.allocator);
    self.* = undefined;
}

fn bind(client: *server.Client, id: u32, version: u32, self: *WayringSystemBell) !void {
    try self.values.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Value);
    errdefer self.allocator.destroy(value);
    value.* = .{
        .owner = self,
        .client = client,
        .resource = .init(self.allocator, id, version, .client, client.ownerHooks()),
    };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Value, value, handleRequest, null);
    try client.materialize(&value.resource.runtime);
    self.values.appendAssumeCapacity(value);
}

fn handleRequest(_: *protocol.xdg_system_bell_v1.Resource, request: protocol.xdg_system_bell_v1.Request, value: *Value) !void {
    switch (request) {
        .destroy => value.owner.destroyValue(value),
        .ring => {},
    }
}

fn destroyValue(self: *WayringSystemBell, value: *Value) void {
    for (self.values.items, 0..) |item, i| if (item == value) {
        _ = self.values.swapRemove(i);
        value.resource.destroy();
        value.resource.deinit();
        self.allocator.destroy(value);
        return;
    };
    unreachable;
}

fn testSend(client: *server.Client, object_id: u32, opcode: u16, descriptor: *const wayring.wire.MessageDescriptor, values: []const wayring.wire.Value) !void {
    var output: wayring.wire.Output = .init(std.testing.allocator);
    defer output.deinit();
    try output.enqueue(object_id, opcode, descriptor, values);
    const batch = (try output.beginSend()).?;
    try client.receive(batch.bytes, &.{});
    try output.completeSend(batch.token, batch.bytes.len);
    try client.dispatch();
}

test "system bell accepts an unassociated ring request" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var adapter: WayringSystemBell = undefined;
    adapter.init(std.testing.allocator, &host);
    defer adapter.deinit();
    try adapter.publish();
    defer adapter.unpublish();
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        adapter.destroyClientResources(client);
        managed.destroy();
    }

    try testSend(client, 1, 1, &protocol.wl_display.request_messages[1], &.{.{ .new_id = .{ .typed = 2 } }});
    var globals = host.iterator();
    while (globals.next()) |global| if (std.mem.eql(u8, global.interface().name, "xdg_system_bell_v1")) {
        try testSend(client, 2, 0, &protocol.wl_registry.request_messages[0], &.{
            .{ .uint = global.name() },
            .{ .new_id = .{ .generic = .{ .interface = "xdg_system_bell_v1", .version = 1, .id = 3 } } },
        });
        break;
    };
    try testSend(client, 3, 1, &protocol.xdg_system_bell_v1.request_messages[1], &.{.{ .object = null }});
    try std.testing.expect(client.fatal() == null);
    try testSend(client, 3, 0, &protocol.xdg_system_bell_v1.request_messages[0], &.{});
    try std.testing.expect(client.lookup(3) == null);
}
