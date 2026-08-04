//! Managed, sans-I/O implementation of the Wayland core display objects.
//!
//! The handwritten descriptors deliberately do not depend on generated
//! bindings. Registry publication is an initial snapshot; hot global
//! add/remove notification is deferred. Application resources created by
//! binders are not owned here and must be destroyed before CoreClient.

const CoreClient = @This();

const std = @import("std");
const wire = @import("../wire.zig");
const Client = @import("Client.zig");
const Resource = @import("Resource.zig");
const Server = @import("Server.zig");

pub const Options = Client.Options;

const callback_interface: wire.Interface = .{ .name = "wl_callback", .version = 1 };
const registry_interface: wire.Interface = .{ .name = "wl_registry", .version = 1 };
const display_interface: wire.Interface = .{ .name = "wl_display", .version = 1 };

const callback_done: wire.MessageDescriptor = .{ .name = "done", .destructor = true, .arguments = &.{.{ .name = "callback_data", .kind = .uint }} };
const callback_requests: []const wire.MessageDescriptor = &.{};
const registry_bind: wire.MessageDescriptor = .{ .name = "bind", .arguments = &.{
    .{ .name = "name", .kind = .uint },
    .{ .name = "id", .kind = .{ .new_id = null } },
} };
const registry_requests = [_]wire.MessageDescriptor{registry_bind};
const registry_global: wire.MessageDescriptor = .{ .name = "global", .arguments = &.{
    .{ .name = "name", .kind = .uint },
    .{ .name = "interface", .kind = .{ .string = .required } },
    .{ .name = "version", .kind = .uint },
} };
const display_sync: wire.MessageDescriptor = .{ .name = "sync", .arguments = &.{.{ .name = "callback", .kind = .{ .new_id = &callback_interface } }} };
const display_get_registry: wire.MessageDescriptor = .{ .name = "get_registry", .arguments = &.{.{ .name = "registry", .kind = .{ .new_id = &registry_interface } }} };
const display_requests = [_]wire.MessageDescriptor{ display_sync, display_get_registry };

const Registry = struct { resource: Resource };
const Callback = struct { resource: Resource };

allocator: std.mem.Allocator,
server: *Server,
connection: Client,
display: Resource,
registries: std.ArrayList(*Registry) = .empty,
serial: u32 = 0,

pub fn create(allocator: std.mem.Allocator, server: *Server, options: Options) !*CoreClient {
    const self = try allocator.create(CoreClient);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .server = server,
        .connection = .init(allocator, options),
        .display = undefined,
    };
    errdefer self.connection.deinit();
    self.display = .init(allocator, 1, 1, &display_interface, &display_requests, .client, self.connection.ownerHooks());
    try self.display.setHandler(CoreClient, self, handleDisplay, null);
    try self.connection.installClientInitial(1, &self.display);
    return self;
}

/// Synchronously retires core objects and discards unsent teardown events.
/// Every application-owned resource must already have been destroyed.
pub fn destroy(self: *CoreClient) void {
    for (self.registries.items) |registry| {
        registry.resource.destroy();
        registry.resource.deinit();
        self.allocator.destroy(registry);
    }
    self.registries.deinit(self.allocator);
    self.display.destroy();
    self.display.deinit();
    std.debug.assert(self.connection.objectCount() == 0);
    self.connection.deinit();
    const allocator = self.allocator;
    self.* = undefined;
    allocator.destroy(self);
}

pub fn client(self: *CoreClient) *Client {
    return &self.connection;
}

fn handleDisplay(self: *CoreClient, _: *Resource, opcode: u16, message: *wire.DecodedMessage) !void {
    switch (opcode) {
        0 => try self.sync(message.values[0].new_id.typed),
        1 => try self.getRegistry(message.values[0].new_id.typed),
        else => unreachable,
    }
}

fn sync(self: *CoreClient, id: u32) !void {
    const callback = try self.allocator.create(Callback);
    callback.* = .{ .resource = .init(self.allocator, id, 1, &callback_interface, callback_requests, .client, self.connection.ownerHooks()) };
    errdefer self.allocator.destroy(callback);
    try self.connection.materialize(&callback.resource);
    var live = true;
    errdefer if (live) {
        callback.resource.destroy();
        callback.resource.deinit();
    };
    self.serial +%= 1;
    if (self.serial == 0) self.serial = 1;
    try callback.resource.emit(0, &callback_done, &.{.{ .uint = self.serial }});
    callback.resource.destroy();
    live = false;
    callback.resource.deinit();
    self.allocator.destroy(callback);
}

fn getRegistry(self: *CoreClient, id: u32) !void {
    const registry = try self.allocator.create(Registry);
    errdefer self.allocator.destroy(registry);
    registry.* = .{ .resource = .init(self.allocator, id, 1, &registry_interface, &registry_requests, .client, self.connection.ownerHooks()) };
    try registry.resource.setHandler(CoreClient, self, handleRegistry, null);
    try self.connection.materialize(&registry.resource);
    var live = true;
    errdefer if (live) {
        registry.resource.destroy();
        registry.resource.deinit();
    };
    var globals = self.server.iterator();
    while (globals.next()) |global| try registry.resource.emit(0, &registry_global, &.{
        .{ .uint = global.name() },
        .{ .string = global.interface().name },
        .{ .uint = global.version() },
    });
    try self.registries.append(self.allocator, registry);
    live = false;
}

fn handleRegistry(self: *CoreClient, resource: *Resource, _: u16, message: *wire.DecodedMessage) !void {
    const name = message.values[0].uint;
    const generic = message.values[1].new_id.generic;
    self.server.bind(&self.connection, name, generic.interface, generic.version, generic.id) catch |err| switch (err) {
        error.UnknownGlobal, error.RemovedGlobal, error.InterfaceMismatch, error.ZeroVersion, error.VersionTooHigh => {
            self.connection.postProtocolError(resource, 0, "invalid wl_registry.bind");
            return;
        },
        else => return err,
    };
}

fn testSend(client_value: *Client, object_id: u32, opcode: u16, descriptor: *const wire.MessageDescriptor, values: []const wire.Value) !void {
    var output: wire.Output = .init(std.testing.allocator);
    defer output.deinit();
    try output.enqueue(object_id, opcode, descriptor, values);
    const batch = (try output.beginSend()).?;
    try client_value.receive(batch.bytes, &.{});
    try output.completeSend(batch.token, batch.bytes.len);
    try client_value.dispatch();
}

test "display sync emits callback done before delete_id and tears down cleanly" {
    var host: Server = .init(std.testing.allocator);
    defer host.deinit();
    const managed = try CoreClient.create(std.testing.allocator, &host, .{});
    defer managed.destroy();
    try testSend(managed.client(), 1, 0, &display_sync, &.{.{ .new_id = .{ .typed = 2 } }});
    var bytes: [24]u8 = undefined;
    var offset: usize = 0;
    while (try managed.client().beginSend()) |batch| {
        @memcpy(bytes[offset..][0..batch.bytes.len], batch.bytes);
        offset += batch.bytes.len;
        try managed.client().completeSend(batch.token, batch.bytes.len);
    }
    try std.testing.expectEqual(bytes.len, offset);
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, bytes[0..4], .little));
    try std.testing.expectEqual(@as(u16, 0), @as(u16, @truncate(std.mem.readInt(u32, bytes[4..8], .little))));
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, bytes[12..16], .little));
    try std.testing.expectEqual(@as(u16, 1), @as(u16, @truncate(std.mem.readInt(u32, bytes[16..20], .little))));
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, bytes[20..24], .little));
}

test "invalid registry bind posts protocol fatal without entering binder" {
    const Fixture = struct {
        pub const interface: wire.Interface = .{ .name = "wl_fixture", .version = 1 };
        var calls: usize = 0;
        fn bind(_: *Client, _: u32, _: u32, _: *@This()) !void {
            calls += 1;
        }
    };
    var host: Server = .init(std.testing.allocator);
    defer host.deinit();
    var fixture: Fixture = .{};
    _ = try host.addGlobal(Fixture, 1, Fixture, &fixture, Fixture.bind);
    const managed = try CoreClient.create(std.testing.allocator, &host, .{});
    defer managed.destroy();
    try testSend(managed.client(), 1, 1, &display_get_registry, &.{.{ .new_id = .{ .typed = 2 } }});
    try testSend(managed.client(), 2, 0, &registry_bind, &.{
        .{ .uint = 99 },
        .{ .new_id = .{ .generic = .{ .interface = "wl_fixture", .version = 1, .id = 3 } } },
    });
    const fatal = managed.client().fatal().?;
    try std.testing.expectEqual(@import("fatal.zig").Kind.protocol, fatal.kind);
    try std.testing.expectEqual(@as(?u32, 0), fatal.protocol_code);
    try std.testing.expectEqualStrings("wl_registry", fatal.interface.?.name);
    try std.testing.expectEqual(@as(usize, 0), Fixture.calls);

    var batch_count: usize = 0;
    var terminal_batch_index: ?usize = null;
    while (try managed.client().beginSend()) |batch| {
        const batch_index = batch_count;
        batch_count += 1;
        if (std.mem.readInt(u32, batch.bytes[0..4], .native) == 1 and
            @as(u16, @truncate(std.mem.readInt(u32, batch.bytes[4..8], .native))) == 0)
        {
            terminal_batch_index = batch_index;
            try std.testing.expectEqual(@as(u16, 0), @as(u16, @truncate(std.mem.readInt(u32, batch.bytes[4..8], .native))));
            try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, batch.bytes[8..12], .native));
            try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, batch.bytes[12..16], .native));
            const detail_len = std.mem.readInt(u32, batch.bytes[16..20], .native);
            const expected_len = 20 + std.mem.alignForward(usize, detail_len, 4);
            try std.testing.expectEqual(batch.bytes.len, expected_len);
            try std.testing.expectEqual(@as(u16, @intCast(batch.bytes.len)), @as(u16, @truncate(std.mem.readInt(u32, batch.bytes[4..8], .native) >> 16)));
            try std.testing.expectEqualStrings("invalid wl_registry.bind\x00", batch.bytes[20..][0..detail_len]);
            try std.testing.expectEqual(@as(u8, 0), batch.bytes[20 + detail_len - 1]);
            for (batch.bytes[20 + detail_len ..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
            try std.testing.expectEqual(@as(usize, 0), batch.fds.len);
        }
        try managed.client().completeSend(batch.token, batch.bytes.len);
    }
    try std.testing.expect(terminal_batch_index != null);
    try std.testing.expectEqual(batch_count - 1, terminal_batch_index.?);
}
