//! Scanner-backed core protocol fixes.

const WayringFixes = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayring = @import("wayring");

const server = wayring.server;

const Value = struct {
    owner: *WayringFixes,
    client: *server.Client,
    resource: protocol.wl_fixes.Resource,
};

allocator: std.mem.Allocator,
protocol_server: *server.Server,
global: ?*const server.Server.Global = null,
values: std.ArrayList(*Value) = .empty,

pub fn init(self: *WayringFixes, allocator: std.mem.Allocator, protocol_server: *server.Server) void {
    self.* = .{ .allocator = allocator, .protocol_server = protocol_server };
}

pub fn publish(self: *WayringFixes) !void {
    self.global = try self.protocol_server.addGlobal(protocol.wl_fixes, 1, WayringFixes, self, bind);
}

pub fn unpublish(self: *WayringFixes) void {
    self.protocol_server.removeGlobal(self.global.?) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}

pub fn destroyClientResources(self: *WayringFixes, client: *server.Client) void {
    var i = self.values.items.len;
    while (i > 0) {
        i -= 1;
        if (self.values.items[i].client == client) self.destroyValue(self.values.items[i]);
    }
}

pub fn deinit(self: *WayringFixes) void {
    std.debug.assert(self.global == null and self.values.items.len == 0);
    self.values.deinit(self.allocator);
    self.* = undefined;
}

fn bind(client: *server.Client, id: u32, version: u32, self: *WayringFixes) !void {
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

fn handleRequest(_: *protocol.wl_fixes.Resource, request: protocol.wl_fixes.Request, value: *Value) !void {
    switch (request) {
        .destroy => value.owner.destroyValue(value),
        .destroy_registry => |args| value.client.destroyRegistry(args.registry) catch
            value.client.postImplementationError(&value.resource.runtime, "wl_registry is not owned by this Wayring core client"),
        else => unreachable,
    }
}

fn destroyValue(self: *WayringFixes, value: *Value) void {
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

fn discardEvents(client: *server.Client) !void {
    while (try client.beginSend()) |batch| try client.completeSend(batch.token, batch.bytes.len);
}

test "fixes destroys an exact core registry and itself" {
    const Fixture = struct {
        pub const interface: wayring.wire.Interface = .{ .name = "wl_fixes_fixture", .version = 1 };
        fn bind(_: *server.Client, _: u32, _: u32, _: *@This()) !void {}
    };
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var adapter: WayringFixes = undefined;
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
    while (globals.next()) |global| if (std.mem.eql(u8, global.interface().name, "wl_fixes")) {
        try testSend(client, 2, 0, &protocol.wl_registry.request_messages[0], &.{
            .{ .uint = global.name() },
            .{ .new_id = .{ .generic = .{ .interface = "wl_fixes", .version = 1, .id = 3 } } },
        });
        break;
    };
    try testSend(client, 1, 1, &protocol.wl_display.request_messages[1], &.{.{ .new_id = .{ .typed = 4 } }});
    try discardEvents(client);
    try std.testing.expect(client.lookup(2) != null);
    try std.testing.expect(client.lookup(3) != null);
    try std.testing.expect(client.lookup(4) != null);

    try testSend(client, 3, 1, &protocol.wl_fixes.request_messages[1], &.{.{ .object = 2 }});
    try std.testing.expect(client.lookup(2) == null);
    try std.testing.expect(client.lookup(3) != null);
    try std.testing.expect(client.lookup(4) != null);
    const deleted = (try client.beginSend()).?;
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, deleted.bytes[0..4], .native));
    try std.testing.expectEqual(@as(u16, 1), @as(u16, @truncate(std.mem.readInt(u32, deleted.bytes[4..8], .native))));
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, deleted.bytes[8..12], .native));
    try client.completeSend(deleted.token, deleted.bytes.len);

    var fixture: Fixture = .{};
    const fixture_global = try host.addGlobal(Fixture, 1, Fixture, &fixture, Fixture.bind);
    const publication = (try client.beginSend()).?;
    try std.testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, publication.bytes[0..4], .native));
    try std.testing.expectEqual(@as(u16, 0), @as(u16, @truncate(std.mem.readInt(u32, publication.bytes[4..8], .native))));
    try std.testing.expectEqual(fixture_global.name(), std.mem.readInt(u32, publication.bytes[8..12], .native));
    try client.completeSend(publication.token, publication.bytes.len);
    try host.removeGlobal(fixture_global);
    try discardEvents(client);

    try testSend(client, 3, 0, &protocol.wl_fixes.request_messages[0], &.{});
    try std.testing.expect(client.lookup(3) == null);
}
