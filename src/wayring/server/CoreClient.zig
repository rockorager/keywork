//! Managed, sans-I/O implementation of the Wayland core display objects.
//!
//! The handwritten descriptors deliberately do not depend on generated
//! bindings. Registry publication includes an initial snapshot and live
//! add/remove notifications. Application resources created by
//! binders are not owned here and must be destroyed before CoreClient.

const CoreClient = @This();

const std = @import("std");
const wire = @import("../wire.zig");
const Client = @import("Client.zig");
const Resource = @import("Resource.zig");
const Server = @import("Server.zig");

pub const Options = struct {
    max_objects: usize = 4096,
    credentials: ?Client.Credentials = null,
    transport_provenance: Client.TransportProvenance = .unknown,
};

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
const registry_global_remove: wire.MessageDescriptor = .{ .name = "global_remove", .arguments = &.{
    .{ .name = "name", .kind = .uint },
} };
const display_sync: wire.MessageDescriptor = .{ .name = "sync", .arguments = &.{.{ .name = "callback", .kind = .{ .new_id = &callback_interface } }} };
const display_get_registry: wire.MessageDescriptor = .{ .name = "get_registry", .arguments = &.{.{ .name = "registry", .kind = .{ .new_id = &registry_interface } }} };
const display_requests = [_]wire.MessageDescriptor{ display_sync, display_get_registry };

const Registry = struct {
    resource: Resource,
    advertised_globals: std.AutoHashMapUnmanaged(u32, void) = .empty,
};
const Callback = struct { resource: Resource };

allocator: std.mem.Allocator,
server: *Server,
connection: Client,
display: Resource,
registries: std.ArrayList(*Registry) = .empty,
publication_observer: *Server.PublicationObserver,

pub fn create(allocator: std.mem.Allocator, server: *Server, options: Options) !*CoreClient {
    const self = try allocator.create(CoreClient);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .server = server,
        .connection = .init(allocator, .{
            .max_objects = options.max_objects,
            .credentials = options.credentials,
            .transport_provenance = options.transport_provenance,
            .protocol_log_sink = server.protocolLogSink(),
        }),
        .display = undefined,
        .publication_observer = undefined,
    };
    errdefer self.connection.deinit();
    self.display = .init(allocator, 1, 1, &display_interface, &display_requests, .client, self.connection.ownerHooks());
    try self.display.setHandler(CoreClient, self, handleDisplay, null);
    try self.connection.installClientInitial(1, &self.display);
    errdefer {
        self.display.destroy();
        self.display.deinit();
    }
    self.publication_observer = try server.addPublicationObserver(CoreClient, self, publicationChanged);
    return self;
}

/// Synchronously retires core objects and discards unsent teardown events.
/// Every application-owned resource must already have been destroyed.
pub fn destroy(self: *CoreClient) void {
    self.server.removePublicationObserver(self.publication_observer);
    for (self.registries.items) |registry| {
        registry.advertised_globals.deinit(self.allocator);
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

fn publicationChanged(self: *CoreClient, publication: Server.Publication, global: *const Server.Global) void {
    for (self.registries.items) |registry| {
        if (self.connection.fatal() != null) break;
        const result = switch (publication) {
            .added => self.advertiseGlobal(registry, global),
            .removed => self.removeAdvertisedGlobal(registry, global),
        };
        result catch |err| switch (err) {
            error.OutOfMemory, error.WriteFailed => self.connection.postOutOfMemory(&registry.resource, "queueing registry publication"),
            error.OutputSealed, error.ClientFatal => {},
            else => self.connection.postImplementationError(&registry.resource, "queueing registry publication"),
        };
    }
}

pub fn client(self: *CoreClient) *Client {
    return &self.connection;
}

/// Reports whether only CoreClient-owned objects remain. Applications must
/// retire their resources before the transport releases this client.
pub fn canDestroy(self: *const CoreClient) bool {
    return self.connection.objectCount() == 1 + self.registries.items.len;
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
    // Wayland defines wl_display.sync callback data as undefined. Keep this
    // barrier namespace separate from display-wide authority serials.
    try callback.resource.emit(0, &callback_done, &.{.{ .uint = 0 }});
    callback.resource.destroy();
    live = false;
    callback.resource.deinit();
    self.allocator.destroy(callback);
}

fn getRegistry(self: *CoreClient, id: u32) !void {
    const registry = try self.allocator.create(Registry);
    errdefer self.allocator.destroy(registry);
    registry.* = .{ .resource = .init(self.allocator, id, 1, &registry_interface, &registry_requests, .client, self.connection.ownerHooks()) };
    errdefer registry.advertised_globals.deinit(self.allocator);
    try registry.resource.setHandler(CoreClient, self, handleRegistry, null);
    try self.connection.materialize(&registry.resource);
    var live = true;
    errdefer if (live) {
        registry.resource.destroy();
        registry.resource.deinit();
    };
    var globals = self.server.iterator();
    while (globals.next()) |global| try self.advertiseGlobal(registry, global);
    try self.registries.append(self.allocator, registry);
    live = false;
}

fn advertiseGlobal(self: *CoreClient, registry: *Registry, global: *const Server.Global) !void {
    if (!self.server.globalVisible(&self.connection, global)) return;
    if (registry.advertised_globals.contains(global.name())) return;
    try registry.advertised_globals.ensureUnusedCapacity(self.allocator, 1);
    try registry.resource.emit(0, &registry_global, &.{
        .{ .uint = global.name() },
        .{ .string = global.interface().name },
        .{ .uint = global.version() },
    });
    registry.advertised_globals.putAssumeCapacity(global.name(), {});
}

fn removeAdvertisedGlobal(_: *CoreClient, registry: *Registry, global: *const Server.Global) !void {
    if (!registry.advertised_globals.contains(global.name())) return;
    try registry.resource.emit(1, &registry_global_remove, &.{.{ .uint = global.name() }});
    std.debug.assert(registry.advertised_globals.remove(global.name()));
}

fn handleRegistry(self: *CoreClient, resource: *Resource, _: u16, message: *wire.DecodedMessage) !void {
    const name = message.values[0].uint;
    const generic = message.values[1].new_id.generic;
    self.server.bind(&self.connection, name, generic.interface, generic.version, generic.id) catch |err| switch (err) {
        error.UnknownGlobal, error.RemovedGlobal, error.HiddenGlobal, error.InterfaceMismatch, error.ZeroVersion, error.VersionTooHigh => {
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
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, bytes[8..12], .little));
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, bytes[12..16], .little));
    try std.testing.expectEqual(@as(u16, 1), @as(u16, @truncate(std.mem.readInt(u32, bytes[16..20], .little))));
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, bytes[20..24], .little));
}

test "repeated multi-client sync returns zero without consuming display serials" {
    var host: Server = .init(std.testing.allocator);
    defer host.deinit();
    const first = try CoreClient.create(std.testing.allocator, &host, .{});
    var first_live = true;
    defer if (first_live) first.destroy();
    const second = try CoreClient.create(std.testing.allocator, &host, .{});
    defer second.destroy();

    try std.testing.expectEqual(@as(u32, 1), try host.nextSerial());
    try testSend(first.client(), 1, 0, &display_sync, &.{.{ .new_id = .{ .typed = 2 } }});
    try testSend(first.client(), 1, 0, &display_sync, &.{.{ .new_id = .{ .typed = 3 } }});
    try testSend(second.client(), 1, 0, &display_sync, &.{.{ .new_id = .{ .typed = 2 } }});

    for ([_]*CoreClient{ first, second }) |managed| {
        while (try managed.client().beginSend()) |batch| {
            var offset: usize = 0;
            while (offset < batch.bytes.len) : (offset += 12) {
                const object_id = std.mem.readInt(u32, batch.bytes[offset..][0..4], .little);
                const opcode: u16 = @truncate(std.mem.readInt(u32, batch.bytes[offset + 4 ..][0..4], .little));
                if (object_id != 1 and opcode == 0)
                    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, batch.bytes[offset + 8 ..][0..4], .little));
            }
            try managed.client().completeSend(batch.token, batch.bytes.len);
        }
    }

    first.destroy();
    first_live = false;
    const reconnected = try CoreClient.create(std.testing.allocator, &host, .{});
    defer reconnected.destroy();
    try testSend(reconnected.client(), 1, 0, &display_sync, &.{.{ .new_id = .{ .typed = 2 } }});
    while (try reconnected.client().beginSend()) |batch| {
        try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, batch.bytes[8..12], .little));
        try reconnected.client().completeSend(batch.token, batch.bytes.len);
    }
    try std.testing.expectEqual(@as(u32, 2), try host.nextSerial());
}

test "managed client destruction notifies borrowed observers" {
    const Context = struct {
        called: bool = false,

        fn observe(self: *@This(), client_value: *Client, _: *Client.Observer) void {
            self.called = true;
            const credentials = client_value.credentials().?;
            std.testing.expectEqual(@as(std.os.linux.pid_t, 41), credentials.pid) catch unreachable;
            std.testing.expectEqual(@as(std.os.linux.uid_t, 42), credentials.uid) catch unreachable;
            std.testing.expectEqual(@as(std.os.linux.gid_t, 43), credentials.gid) catch unreachable;
        }
    };

    var host: Server = .init(std.testing.allocator);
    defer host.deinit();
    const managed = try CoreClient.create(std.testing.allocator, &host, .{
        .credentials = .{ .pid = 41, .uid = 42, .gid = 43 },
    });
    var context: Context = .{};
    _ = try managed.client().addDestroyObserver(Context, &context, Context.observe);
    managed.destroy();
    try std.testing.expect(context.called);
}

test "server protocol logger observes requests queued events and fatal diagnostics" {
    const Entry = struct {
        direction: Client.ProtocolDirection,
        object_id: u32,
        opcode: u16,
        name: []const u8,
    };
    const Context = struct {
        entries: std.ArrayList(Entry) = .empty,
        fatal_detail_seen: bool = false,

        fn observe(self: *@This(), _: *Client, message: Client.ProtocolMessage) void {
            self.entries.append(std.testing.allocator, .{
                .direction = message.direction,
                .object_id = message.resource.id(),
                .opcode = message.opcode,
                .name = message.descriptor.name,
            }) catch unreachable;
            if (std.mem.eql(u8, message.descriptor.name, "error")) {
                std.testing.expectEqual(@as(usize, 3), message.values.len) catch unreachable;
                std.testing.expectEqual(@as(?u32, 1), message.values[0].object) catch unreachable;
                std.testing.expectEqual(@as(u32, 3), message.values[1].uint) catch unreachable;
                std.testing.expectEqualStrings("logger fixture", message.values[2].string.?) catch unreachable;
                self.fatal_detail_seen = true;
            }
        }
    };

    var host: Server = .init(std.testing.allocator);
    defer host.deinit();
    var context: Context = .{};
    defer context.entries.deinit(std.testing.allocator);
    const logger = try host.addProtocolLogger(Context, &context, Context.observe);
    const managed = try CoreClient.create(std.testing.allocator, &host, .{});
    defer managed.destroy();

    try testSend(managed.client(), 1, 0, &display_sync, &.{.{ .new_id = .{ .typed = 2 } }});
    try std.testing.expectEqual(@as(usize, 3), context.entries.items.len);
    try std.testing.expectEqualDeep(Entry{ .direction = .request, .object_id = 1, .opcode = 0, .name = "sync" }, context.entries.items[0]);
    try std.testing.expectEqualDeep(Entry{ .direction = .event, .object_id = 2, .opcode = 0, .name = "done" }, context.entries.items[1]);
    try std.testing.expectEqualDeep(Entry{ .direction = .event, .object_id = 1, .opcode = 1, .name = "delete_id" }, context.entries.items[2]);

    managed.client().postImplementationError(&managed.display, "logger fixture");
    try std.testing.expectEqual(@as(usize, 4), context.entries.items.len);
    try std.testing.expectEqualDeep(Entry{ .direction = .event, .object_id = 1, .opcode = 0, .name = "error" }, context.entries.items[3]);
    try std.testing.expect(context.fatal_detail_seen);
    host.removeProtocolLogger(logger);
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

test "live globals emit exact add remove and later registry sees current monotonic snapshot" {
    const Fixture = struct {
        pub const interface: wire.Interface = .{ .name = "wl_fixture", .version = 1 };
        fn bind(_: *Client, _: u32, _: u32, _: *@This()) !void {}
    };
    var host: Server = .init(std.testing.allocator);
    defer host.deinit();
    const managed = try CoreClient.create(std.testing.allocator, &host, .{});
    defer managed.destroy();
    try testSend(managed.client(), 1, 1, &display_get_registry, &.{.{ .new_id = .{ .typed = 2 } }});
    var fixture: Fixture = .{};
    const first = try host.addGlobal(Fixture, 1, Fixture, &fixture, Fixture.bind);
    const add = (try managed.client().beginSend()).?;
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, add.bytes[0..4], .native));
    try std.testing.expectEqual(@as(u16, 0), @as(u16, @truncate(std.mem.readInt(u32, add.bytes[4..8], .native))));
    try std.testing.expectEqual(first.name(), std.mem.readInt(u32, add.bytes[8..12], .native));
    try managed.client().completeSend(add.token, add.bytes.len);
    try host.removeGlobal(first);
    const removed = (try managed.client().beginSend()).?;
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, removed.bytes[0..4], .native));
    try std.testing.expectEqual(@as(u16, 1), @as(u16, @truncate(std.mem.readInt(u32, removed.bytes[4..8], .native))));
    try std.testing.expectEqual(first.name(), std.mem.readInt(u32, removed.bytes[8..12], .native));
    try managed.client().completeSend(removed.token, removed.bytes.len);
    const second = try host.addGlobal(Fixture, 1, Fixture, &fixture, Fixture.bind);
    try std.testing.expectEqual(first.name() + 1, second.name());
    const live = (try managed.client().beginSend()).?;
    try managed.client().completeSend(live.token, live.bytes.len);
    try testSend(managed.client(), 1, 1, &display_get_registry, &.{.{ .new_id = .{ .typed = 3 } }});
    const snapshot = (try managed.client().beginSend()).?;
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, snapshot.bytes[0..4], .native));
    try std.testing.expectEqual(second.name(), std.mem.readInt(u32, snapshot.bytes[8..12], .native));
    try managed.client().completeSend(snapshot.token, snapshot.bytes.len);
    try std.testing.expect((try managed.client().beginSend()) == null);
}

test "global filter controls each registry snapshot removal and bind" {
    const Fixture = struct {
        pub const interface: wire.Interface = .{ .name = "wl_fixture", .version = 1 };
        calls: usize = 0,
        fn bind(_: *Client, _: u32, _: u32, self: *@This()) !void {
            self.calls += 1;
        }
    };
    const Filter = struct {
        hidden: *const Server.Global,
        fn allow(self: *@This(), client_value: *const Client, global: *const Server.Global) bool {
            return global != self.hidden or client_value.credentials().?.uid == 7;
        }
    };

    var host: Server = .init(std.testing.allocator);
    defer host.deinit();
    var fixture: Fixture = .{};
    const public = try host.addGlobal(Fixture, 1, Fixture, &fixture, Fixture.bind);
    const hidden = try host.addGlobal(Fixture, 1, Fixture, &fixture, Fixture.bind);
    var filter: Filter = .{ .hidden = hidden };
    host.setGlobalFilter(Filter, &filter, Filter.allow);
    defer host.clearGlobalFilter();
    const allowed = try CoreClient.create(std.testing.allocator, &host, .{ .credentials = .{ .pid = 1, .uid = 7, .gid = 1 } });
    defer allowed.destroy();
    const restricted = try CoreClient.create(std.testing.allocator, &host, .{ .credentials = .{ .pid = 2, .uid = 8, .gid = 2 } });
    defer restricted.destroy();

    try testSend(allowed.client(), 1, 1, &display_get_registry, &.{.{ .new_id = .{ .typed = 2 } }});
    try testSend(restricted.client(), 1, 1, &display_get_registry, &.{.{ .new_id = .{ .typed = 2 } }});
    const allowed_snapshot = (try allowed.client().beginSend()).?;
    try std.testing.expectEqual(public.name(), std.mem.readInt(u32, allowed_snapshot.bytes[8..12], .native));
    const second_offset: usize = @intCast(std.mem.readInt(u32, allowed_snapshot.bytes[4..8], .native) >> 16);
    try std.testing.expect(second_offset < allowed_snapshot.bytes.len);
    try std.testing.expectEqual(hidden.name(), std.mem.readInt(u32, allowed_snapshot.bytes[second_offset + 8 ..][0..4], .native));
    try allowed.client().completeSend(allowed_snapshot.token, allowed_snapshot.bytes.len);
    const restricted_public = (try restricted.client().beginSend()).?;
    try std.testing.expectEqual(public.name(), std.mem.readInt(u32, restricted_public.bytes[8..12], .native));
    try restricted.client().completeSend(restricted_public.token, restricted_public.bytes.len);
    try std.testing.expect((try restricted.client().beginSend()) == null);

    const attacker = try CoreClient.create(std.testing.allocator, &host, .{ .credentials = .{ .pid = 3, .uid = 8, .gid = 2 } });
    defer attacker.destroy();
    try testSend(attacker.client(), 1, 1, &display_get_registry, &.{.{ .new_id = .{ .typed = 2 } }});
    const attacker_public = (try attacker.client().beginSend()).?;
    try attacker.client().completeSend(attacker_public.token, attacker_public.bytes.len);
    try testSend(attacker.client(), 2, 0, &registry_bind, &.{
        .{ .uint = hidden.name() },
        .{ .new_id = .{ .generic = .{ .interface = "wl_fixture", .version = 1, .id = 3 } } },
    });
    try std.testing.expectEqual(@import("fatal.zig").Kind.protocol, attacker.client().fatal().?.kind);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);

    try host.removeGlobal(hidden);
    const allowed_remove = (try allowed.client().beginSend()).?;
    try std.testing.expectEqual(@as(u16, 1), @as(u16, @truncate(std.mem.readInt(u32, allowed_remove.bytes[4..8], .native))));
    try std.testing.expectEqual(hidden.name(), std.mem.readInt(u32, allowed_remove.bytes[8..12], .native));
    try allowed.client().completeSend(allowed_remove.token, allowed_remove.bytes.len);
    try std.testing.expect((try restricted.client().beginSend()) == null);
}

test "live notification OOM is client local and observer teardown leaves survivor" {
    const Fixture = struct {
        pub const interface: wire.Interface = .{ .name = "wl_fixture", .version = 1 };
        fn bind(_: *Client, _: u32, _: u32, _: *@This()) !void {}
    };
    var host: Server = .init(std.testing.allocator);
    defer host.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const affected = try CoreClient.create(failing.allocator(), &host, .{});
    var affected_live = true;
    defer if (affected_live) affected.destroy();
    const healthy = try CoreClient.create(std.testing.allocator, &host, .{});
    defer healthy.destroy();
    try testSend(affected.client(), 1, 1, &display_get_registry, &.{.{ .new_id = .{ .typed = 2 } }});
    try testSend(healthy.client(), 1, 1, &display_get_registry, &.{.{ .new_id = .{ .typed = 2 } }});
    failing.fail_index = failing.alloc_index;
    var fixture: Fixture = .{};
    const global = try host.addGlobal(Fixture, 1, Fixture, &fixture, Fixture.bind);
    try std.testing.expectEqual(@import("fatal.zig").Kind.out_of_memory, affected.client().fatal().?.kind);
    try std.testing.expect(global.published());
    const add = (try healthy.client().beginSend()).?;
    try std.testing.expectEqual(global.name(), std.mem.readInt(u32, add.bytes[8..12], .native));
    try healthy.client().completeSend(add.token, add.bytes.len);
    affected.destroy();
    affected_live = false;
    try host.removeGlobal(global);
    const removed = (try healthy.client().beginSend()).?;
    try std.testing.expectEqual(@as(u16, 1), @as(u16, @truncate(std.mem.readInt(u32, removed.bytes[4..8], .native))));
    try healthy.client().completeSend(removed.token, removed.bytes.len);
}
