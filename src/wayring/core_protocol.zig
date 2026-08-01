//! Handwritten bindings for the bootstrap Wayland protocol objects.

const std = @import("std");
const wayring = @import("wayring");

const display_sync_args = [_]wayring.ArgumentSpec{.{ .kind = .new_id }};
const display_get_registry_args = [_]wayring.ArgumentSpec{.{ .kind = .new_id }};
const display_error_args = [_]wayring.ArgumentSpec{
    .{ .kind = .object }, .{ .kind = .uint }, .{ .kind = .string },
};
const display_delete_id_args = [_]wayring.ArgumentSpec{.{ .kind = .uint }};
const display_requests = [_]wayring.MessageDescriptor{
    .{ .name = "sync", .opcode = 0, .args = &display_sync_args },
    .{ .name = "get_registry", .opcode = 1, .args = &display_get_registry_args },
};
const display_events = [_]wayring.MessageDescriptor{
    .{ .name = "error", .opcode = 0, .args = &display_error_args },
    .{ .name = "delete_id", .opcode = 1, .args = &display_delete_id_args },
};

const registry_bind_args = [_]wayring.ArgumentSpec{
    .{ .kind = .uint }, .{ .kind = .string }, .{ .kind = .uint }, .{ .kind = .new_id },
};
const registry_global_args = [_]wayring.ArgumentSpec{
    .{ .kind = .uint }, .{ .kind = .string }, .{ .kind = .uint },
};
const registry_global_remove_args = [_]wayring.ArgumentSpec{.{ .kind = .uint }};
const registry_requests = [_]wayring.MessageDescriptor{
    .{ .name = "bind", .opcode = 0, .args = &registry_bind_args },
};
const registry_events = [_]wayring.MessageDescriptor{
    .{ .name = "global", .opcode = 0, .args = &registry_global_args },
    .{ .name = "global_remove", .opcode = 1, .args = &registry_global_remove_args },
};
const callback_done_args = [_]wayring.ArgumentSpec{.{ .kind = .uint }};
const callback_events = [_]wayring.MessageDescriptor{
    .{ .name = "done", .opcode = 0, .args = &callback_done_args },
};

pub const wl_display: wayring.Interface = .{
    .name = "wl_display",
    .version = 1,
    .requests = &display_requests,
    .events = &display_events,
};
pub const wl_registry: wayring.Interface = .{
    .name = "wl_registry",
    .version = 1,
    .requests = &registry_requests,
    .events = &registry_events,
};
pub const wl_callback: wayring.Interface = .{
    .name = "wl_callback",
    .version = 1,
    .events = &callback_events,
};

pub fn bootstrapDisplay(connection: *wayring.Connection) !u64 {
    return connection.registerObject(1, &wl_display, 1);
}

fn registerAndQueue(connection: *wayring.Connection, parent_id: u32, opcode: u16, new_id: u32, interface: *const wayring.Interface, version: u32, values: []const wayring.OutValue) !u64 {
    const generation = try connection.registerObject(new_id, interface, version);
    errdefer connection.removeObject(new_id, generation) catch unreachable;
    try connection.queue(parent_id, opcode, values);
    return generation;
}

pub fn getRegistry(connection: *wayring.Connection, registry_id: u32) !u64 {
    return registerAndQueue(connection, 1, 1, registry_id, &wl_registry, 1, &.{.{ .new_id = registry_id }});
}

pub fn sync(connection: *wayring.Connection, callback_id: u32) !u64 {
    return registerAndQueue(connection, 1, 0, callback_id, &wl_callback, 1, &.{.{ .new_id = callback_id }});
}

pub fn bind(connection: *wayring.Connection, registry_id: u32, name: u32, interface_name: []const u8, version: u32, new_id: u32, interface: *const wayring.Interface) !u64 {
    return registerAndQueue(connection, registry_id, 0, new_id, interface, version, &.{
        .{ .uint = name }, .{ .string = interface_name }, .{ .uint = version }, .{ .new_id = new_id },
    });
}

pub const DisplayEvent = union(enum) {
    error_event: struct { object_id: u32, code: u32, message: []const u8 },
    delete_id: u32,
};
pub const RegistryEvent = union(enum) {
    global: struct { name: u32, interface: []const u8, version: u32 },
    global_remove: u32,
};
pub const CallbackEvent = union(enum) { done: u32 };
pub const DisplayRequest = union(enum) { sync: u32, get_registry: u32 };
pub const RegistryRequest = union(enum) {
    bind: struct { name: u32, interface: []const u8, version: u32, new_id: u32 },
};

fn validate(message: *const wayring.Message, object_id: u32, descriptor: *const wayring.MessageDescriptor, count: usize) !void {
    if (message.object_id != object_id) return error.WrongObject;
    if (message.descriptor != descriptor) return error.WrongDescriptor;
    if (message.descriptor.opcode != descriptor.opcode) return error.WrongOpcode;
    if (message.values.len != count) return error.SignatureMismatch;
    if (message.fds.len != 0) return error.UnexpectedFd;
}
fn uint(value: wayring.Value) !u32 {
    return if (value == .uint) value.uint else error.WrongValueType;
}
fn newId(value: wayring.Value) !u32 {
    return if (value == .new_id) value.new_id else error.WrongValueType;
}
fn object(value: wayring.Value) !u32 {
    return if (value == .object and value.object != null) value.object.? else error.WrongValueType;
}
fn string(value: wayring.Value) ![]const u8 {
    return if (value == .string and value.string != null) value.string.? else error.WrongValueType;
}

pub fn decodeDisplayEvent(message: *const wayring.Message) !DisplayEvent {
    if (message.descriptor == &display_events[0]) {
        try validate(message, 1, &display_events[0], 3);
        return .{ .error_event = .{ .object_id = try object(message.values[0]), .code = try uint(message.values[1]), .message = try string(message.values[2]) } };
    }
    if (message.descriptor == &display_events[1]) {
        try validate(message, 1, &display_events[1], 1);
        return .{ .delete_id = try uint(message.values[0]) };
    }
    return error.WrongDescriptor;
}
pub fn decodeRegistryEvent(message: *const wayring.Message, registry_id: u32) !RegistryEvent {
    if (message.descriptor == &registry_events[0]) {
        try validate(message, registry_id, &registry_events[0], 3);
        return .{ .global = .{ .name = try uint(message.values[0]), .interface = try string(message.values[1]), .version = try uint(message.values[2]) } };
    }
    if (message.descriptor == &registry_events[1]) {
        try validate(message, registry_id, &registry_events[1], 1);
        return .{ .global_remove = try uint(message.values[0]) };
    }
    return error.WrongDescriptor;
}
pub fn decodeCallbackEvent(message: *const wayring.Message, callback_id: u32) !CallbackEvent {
    try validate(message, callback_id, &callback_events[0], 1);
    return .{ .done = try uint(message.values[0]) };
}
pub fn decodeDisplayRequest(message: *const wayring.Message) !DisplayRequest {
    if (message.descriptor == &display_requests[0]) {
        try validate(message, 1, &display_requests[0], 1);
        return .{ .sync = try newId(message.values[0]) };
    }
    if (message.descriptor == &display_requests[1]) {
        try validate(message, 1, &display_requests[1], 1);
        return .{ .get_registry = try newId(message.values[0]) };
    }
    return error.WrongDescriptor;
}
pub fn decodeRegistryRequest(message: *const wayring.Message, registry_id: u32) !RegistryRequest {
    try validate(message, registry_id, &registry_requests[0], 4);
    return .{ .bind = .{ .name = try uint(message.values[0]), .interface = try string(message.values[1]), .version = try uint(message.values[2]), .new_id = try newId(message.values[3]) } };
}

pub fn queueGlobal(connection: *wayring.Connection, registry_id: u32, name: u32, interface: []const u8, version: u32) !void {
    try connection.queue(registry_id, 0, &.{ .{ .uint = name }, .{ .string = interface }, .{ .uint = version } });
}
pub fn queueGlobalRemove(connection: *wayring.Connection, registry_id: u32, name: u32) !void {
    try connection.queue(registry_id, 1, &.{.{ .uint = name }});
}
pub fn queueCallbackDone(connection: *wayring.Connection, callback_id: u32, data: u32) !void {
    try connection.queue(callback_id, 0, &.{.{ .uint = data }});
}
pub fn queueDeleteId(connection: *wayring.Connection, id: u32) !void {
    try connection.queue(1, 1, &.{.{ .uint = id }});
}
pub fn queueDisplayError(connection: *wayring.Connection, object_id: u32, code: u32, message: []const u8) !void {
    try connection.queue(1, 0, &.{ .{ .object = object_id }, .{ .uint = code }, .{ .string = message } });
}

test "core descriptors and dynamic registry bind wire shape" {
    try std.testing.expectEqual(@as(u32, 1), wl_display.version);
    try std.testing.expectEqual(@as(u32, 1), wl_registry.version);
    try std.testing.expectEqual(@as(u32, 1), wl_callback.version);
    try std.testing.expectEqualStrings("sync", wl_display.requests[0].name);
    try std.testing.expectEqual(@as(u16, 0), wl_display.requests[0].opcode);
    try std.testing.expectEqual(@as(u16, 1), wl_display.requests[1].opcode);
    try std.testing.expectEqual(wayring.ArgumentKind.new_id, wl_display.requests[0].args[0].kind);
    try std.testing.expectEqual(wayring.ArgumentKind.new_id, wl_display.requests[1].args[0].kind);
    try std.testing.expectEqual(@as(u16, 0), wl_display.events[0].opcode);
    try std.testing.expectEqual(@as(u16, 1), wl_display.events[1].opcode);
    try std.testing.expectEqualSlices(wayring.ArgumentKind, &.{ .object, .uint, .string }, &.{
        wl_display.events[0].args[0].kind,
        wl_display.events[0].args[1].kind,
        wl_display.events[0].args[2].kind,
    });
    try std.testing.expectEqual(wayring.ArgumentKind.uint, wl_display.events[1].args[0].kind);
    try std.testing.expectEqual(@as(u16, 0), wl_registry.requests[0].opcode);
    try std.testing.expectEqual(@as(usize, 4), wl_registry.requests[0].args.len);
    try std.testing.expectEqualSlices(wayring.ArgumentKind, &.{ .uint, .string, .uint, .new_id }, &.{
        wl_registry.requests[0].args[0].kind,
        wl_registry.requests[0].args[1].kind,
        wl_registry.requests[0].args[2].kind,
        wl_registry.requests[0].args[3].kind,
    });
    try std.testing.expectEqual(@as(u16, 0), wl_registry.events[0].opcode);
    try std.testing.expectEqual(@as(u16, 1), wl_registry.events[1].opcode);
    try std.testing.expectEqualSlices(wayring.ArgumentKind, &.{ .uint, .string, .uint }, &.{
        wl_registry.events[0].args[0].kind,
        wl_registry.events[0].args[1].kind,
        wl_registry.events[0].args[2].kind,
    });
    try std.testing.expectEqual(wayring.ArgumentKind.uint, wl_registry.events[1].args[0].kind);
    try std.testing.expectEqual(@as(u16, 0), wl_callback.events[0].opcode);
    try std.testing.expectEqual(wayring.ArgumentKind.uint, wl_callback.events[0].args[0].kind);
    var client = wayring.Connection.init(std.testing.allocator, .client, 4096);
    defer client.deinit();
    _ = try bootstrapDisplay(&client);
    _ = try getRegistry(&client, 2);
    const first = client.nextBatch().?;
    try client.acknowledge(first.token, first.bytes.len);
    _ = try bind(&client, 2, 17, "wl_callback", 1, 9, &wl_callback);
    const batch = client.nextBatch().?;
    var server = wayring.Connection.init(std.testing.allocator, .server, 4096);
    defer server.deinit();
    _ = try bootstrapDisplay(&server);
    _ = try server.registerObject(2, &wl_registry, 1);
    try server.feed(batch.bytes, &.{});
    var message = server.popMessage().?;
    defer message.deinit();
    const request = (try decodeRegistryRequest(&message, 2)).bind;
    try std.testing.expectEqual(@as(u32, 17), request.name);
    try std.testing.expectEqualStrings("wl_callback", request.interface);
    try std.testing.expectEqual(@as(u32, 9), request.new_id);
}

test "io_uring synthetic registry and sync round trip" {
    const IoUringTransport = @import("wayring-uring");
    const IoUringLoop = @import("keywork-loop").IoUringLoop;
    const linux = std.os.linux;
    const Context = struct {
        client: *IoUringTransport,
        server: *IoUringTransport,
        registry_id: u32 = 2,
        callback_id: u32 = 3,
        got_global: bool = false,
        got_done: bool = false,
        got_delete: bool = false,

        fn serverNotify(context_ptr: *anyopaque, _: *IoUringTransport, notification: IoUringTransport.Notification) !void {
            const self: *@This() = @ptrCast(@alignCast(context_ptr));
            if (notification != .messages) return;
            while (self.server.connection.popMessage()) |popped| {
                var message = popped;
                defer message.deinit();
                switch (try decodeDisplayRequest(&message)) {
                    .get_registry => |id| {
                        try std.testing.expectEqual(self.registry_id, id);
                        _ = try self.server.connection.registerObject(id, &wl_registry, 1);
                        try queueGlobal(self.server.connection, id, 41, "wl_callback", 1);
                    },
                    .sync => |id| {
                        try std.testing.expectEqual(self.callback_id, id);
                        _ = try self.server.connection.registerObject(id, &wl_callback, 1);
                        try queueCallbackDone(self.server.connection, id, 99);
                        try queueDeleteId(self.server.connection, id);
                    },
                }
            }
            try self.server.flush();
        }

        fn clientNotify(context_ptr: *anyopaque, _: *IoUringTransport, notification: IoUringTransport.Notification) !void {
            const self: *@This() = @ptrCast(@alignCast(context_ptr));
            if (notification != .messages) return;
            while (self.client.connection.popMessage()) |popped| {
                var message = popped;
                defer message.deinit();
                if (message.object_id == self.registry_id) {
                    const global = (try decodeRegistryEvent(&message, self.registry_id)).global;
                    try std.testing.expectEqual(@as(u32, 41), global.name);
                    try std.testing.expectEqualStrings("wl_callback", global.interface);
                    try std.testing.expectEqual(@as(u32, 1), global.version);
                    self.got_global = true;
                } else if (message.object_id == self.callback_id) {
                    try std.testing.expectEqual(@as(u32, 99), (try decodeCallbackEvent(&message, self.callback_id)).done);
                    self.got_done = true;
                } else {
                    const deleted = (try decodeDisplayEvent(&message)).delete_id;
                    try std.testing.expectEqual(self.callback_id, deleted);
                    const generation = self.client.connection.object(deleted).?.generation;
                    try self.client.connection.removeObject(deleted, generation);
                    self.got_delete = true;
                }
            }
            if (self.got_global and self.got_done and self.got_delete) {
                try self.client.shutdown();
                try self.server.shutdown();
            }
        }
    };

    var sockets: [2]i32 = undefined;
    if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets)) != .SUCCESS)
        return error.SocketPairFailed;
    var sockets_owned = true;
    defer if (sockets_owned) {
        for (sockets) |fd| _ = linux.close(fd);
    };

    var loop = try IoUringLoop.init(std.testing.allocator);
    defer loop.deinit();
    var client_connection = wayring.Connection.init(std.testing.allocator, .client, 4096);
    defer client_connection.deinit();
    var server_connection = wayring.Connection.init(std.testing.allocator, .server, 4096);
    defer server_connection.deinit();
    _ = try bootstrapDisplay(&client_connection);
    _ = try bootstrapDisplay(&server_connection);

    var client: IoUringTransport = undefined;
    var server: IoUringTransport = undefined;
    var context: Context = .{ .client = &client, .server = &server };
    try client.init(sockets[0], &loop, &client_connection, &context, Context.clientNotify);
    errdefer {
        client.shutdown() catch {};
        while (loop.hasActiveOperations()) loop.runOnce() catch {};
        client.deinit();
    }
    try server.init(sockets[1], &loop, &server_connection, &context, Context.serverNotify);
    sockets_owned = false;

    _ = try getRegistry(&client_connection, context.registry_id);
    _ = try sync(&client_connection, context.callback_id);
    try client.flush();
    while (loop.hasActiveOperations()) try loop.runOnce();

    try std.testing.expect(context.got_global);
    try std.testing.expect(context.got_done);
    try std.testing.expect(context.got_delete);
    try std.testing.expect(client_connection.object(context.callback_id) == null);
    try std.testing.expect(client.readyToDeinit());
    try std.testing.expect(server.readyToDeinit());
    client.deinit();
    server.deinit();
}
