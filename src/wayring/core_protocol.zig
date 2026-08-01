//! Handwritten bindings for the bootstrap Wayland protocol objects.

const std = @import("std");
const wayring = @import("wayring");
const generated = @import("wayring-protocols");

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

test "generated client builds and commits an SHM xdg surface" {
    const linux = std.os.linux;
    const Pair = struct {
        client: wayring.ObjectHandle,
        server: wayring.ObjectHandle,
    };
    const Harness = struct {
        client: *wayring.Connection,
        server: *wayring.Connection,
        client_registry: wayring.ObjectHandle,
        server_registry: wayring.ObjectHandle,

        fn transfer(sender: *wayring.Connection, receiver: *wayring.Connection) !void {
            const batch = sender.nextBatch() orelse return error.MissingBatch;
            var duplicated: [wayring.max_fds_per_batch]i32 = undefined;
            var count: usize = 0;
            errdefer {
                for (duplicated[0..count]) |fd| _ = linux.close(fd);
            }
            for (batch.fds) |fd| {
                const result = linux.dup(fd);
                if (linux.errno(result) != .SUCCESS) return error.DuplicateFdFailed;
                duplicated[count] = @intCast(result);
                count += 1;
            }
            try receiver.feed(batch.bytes, duplicated[0..count]);
            count = 0; // receiver owns every duplicate, including on feed errors
            try sender.acknowledge(batch.token, batch.bytes.len);
        }

        fn register(connection: *wayring.Connection, id: u32, interface: *const wayring.Interface, version: u32) !wayring.ObjectHandle {
            return .{ .id = id, .generation = try connection.registerObject(id, interface, version) };
        }

        fn bind(self: *@This(), name: u32, interface: *const wayring.Interface, version: u32) !Pair {
            const client_object = try generated.wl_registry_types.requests.bind(
                self.client,
                self.client_registry,
                name,
                interface,
                version,
            );
            try transfer(self.client, self.server);
            var message = self.server.popMessage() orelse return error.MissingMessage;
            defer message.deinit();
            const request = (try generated.wl_registry_types.decodeRequest(
                self.server,
                self.server_registry,
                &message,
            )).bind;
            try std.testing.expectEqual(name, request.name);
            try std.testing.expectEqualStrings(interface.name, request.new_interface.?);
            try std.testing.expectEqual(version, request.new_version);
            try std.testing.expectEqual(client_object.id, request.id);
            return .{
                .client = client_object,
                .server = try register(self.server, request.id, interface, version),
            };
        }
    };

    var client = wayring.Connection.init(std.testing.allocator, .client, 64 * 1024);
    defer client.deinit();
    var server = wayring.Connection.init(std.testing.allocator, .server, 64 * 1024);
    defer server.deinit();

    const client_display = try Harness.register(&client, 1, &generated.wl_display, 1);
    const server_display = try Harness.register(&server, 1, &generated.wl_display, 1);
    const client_registry = try generated.wl_display_types.requests.get_registry(&client, client_display);
    try Harness.transfer(&client, &server);
    var registry_message = server.popMessage() orelse return error.MissingMessage;
    defer registry_message.deinit();
    const registry_id = (try generated.wl_display_types.decodeRequest(&server, server_display, &registry_message)).get_registry.registry;
    const server_registry = try Harness.register(&server, registry_id, &generated.wl_registry, 1);
    var harness: Harness = .{
        .client = &client,
        .server = &server,
        .client_registry = client_registry,
        .server_registry = server_registry,
    };

    const compositor = try harness.bind(1, &generated.wl_compositor, generated.wl_compositor.version);
    const shm = try harness.bind(2, &generated.wl_shm, generated.wl_shm.version);
    const wm_base = try harness.bind(3, &generated.xdg_wm_base, generated.xdg_wm_base.version);

    const client_surface = try generated.wl_compositor_types.requests.create_surface(&client, compositor.client);
    try Harness.transfer(&client, &server);
    var create_surface_message = server.popMessage() orelse return error.MissingMessage;
    defer create_surface_message.deinit();
    const surface_id = (try generated.wl_compositor_types.decodeRequest(&server, compositor.server, &create_surface_message)).create_surface.id;
    try std.testing.expectEqual(client_surface.id, surface_id);
    const server_surface = try Harness.register(&server, surface_id, &generated.wl_surface, generated.wl_surface.version);

    const shm_size: i32 = 64 * 64 * 4;
    const shm_fd = try std.posix.memfd_create("wayring-shm-test", linux.MFD.CLOEXEC);
    var shm_fd_owned = true;
    defer if (shm_fd_owned) {
        _ = linux.close(shm_fd);
    };
    if (linux.errno(linux.ftruncate(shm_fd, shm_size)) != .SUCCESS) return error.TruncateFailed;
    const client_pool = try generated.wl_shm_types.requests.create_pool(&client, shm.client, shm_fd, shm_size);
    shm_fd_owned = false;
    try Harness.transfer(&client, &server);
    var create_pool_message = server.popMessage() orelse return error.MissingMessage;
    defer create_pool_message.deinit();
    const create_pool = (try generated.wl_shm_types.decodeRequest(&server, shm.server, &create_pool_message)).create_pool;
    try std.testing.expectEqual(client_pool.id, create_pool.id);
    try std.testing.expectEqual(@as(usize, 1), create_pool.fd);
    try std.testing.expectEqual(shm_size, create_pool.size);
    const received_shm_fd = try create_pool_message.takeFd(create_pool.fd);
    defer _ = linux.close(received_shm_fd);
    const server_pool = try Harness.register(&server, create_pool.id, &generated.wl_shm_pool, generated.wl_shm_pool.version);

    const xrgb8888: u32 = @intFromEnum(generated.wl_shm_types.format.xrgb8888);
    const client_buffer = try generated.wl_shm_pool_types.requests.create_buffer(&client, client_pool, 0, 64, 64, 64 * 4, xrgb8888);
    try Harness.transfer(&client, &server);
    var create_buffer_message = server.popMessage() orelse return error.MissingMessage;
    defer create_buffer_message.deinit();
    const create_buffer = (try generated.wl_shm_pool_types.decodeRequest(&server, server_pool, &create_buffer_message)).create_buffer;
    try std.testing.expectEqual(client_buffer.id, create_buffer.id);
    const server_buffer = try Harness.register(&server, create_buffer.id, &generated.wl_buffer, generated.wl_buffer.version);

    const client_xdg_surface = try generated.xdg_wm_base_types.requests.get_xdg_surface(&client, wm_base.client, client_surface);
    try Harness.transfer(&client, &server);
    var get_xdg_surface_message = server.popMessage() orelse return error.MissingMessage;
    defer get_xdg_surface_message.deinit();
    const get_xdg_surface = (try generated.xdg_wm_base_types.decodeRequest(&server, wm_base.server, &get_xdg_surface_message)).get_xdg_surface;
    try std.testing.expectEqual(client_surface.id, get_xdg_surface.surface);
    const server_xdg_surface = try Harness.register(&server, get_xdg_surface.id, &generated.xdg_surface, generated.xdg_surface.version);

    const client_toplevel = try generated.xdg_surface_types.requests.get_toplevel(&client, client_xdg_surface);
    try Harness.transfer(&client, &server);
    var get_toplevel_message = server.popMessage() orelse return error.MissingMessage;
    defer get_toplevel_message.deinit();
    const toplevel_id = (try generated.xdg_surface_types.decodeRequest(&server, server_xdg_surface, &get_toplevel_message)).get_toplevel.id;
    try std.testing.expectEqual(client_toplevel.id, toplevel_id);
    _ = try Harness.register(&server, toplevel_id, &generated.xdg_toplevel, generated.xdg_toplevel.version);

    try generated.wl_surface_types.requests.commit(&client, client_surface);
    try Harness.transfer(&client, &server);
    var initial_commit_message = server.popMessage() orelse return error.MissingMessage;
    defer initial_commit_message.deinit();
    _ = (try generated.wl_surface_types.decodeRequest(&server, server_surface, &initial_commit_message)).commit;

    const configure_serial: u32 = 42;
    try server.queue(server_xdg_surface.id, 0, &.{.{ .uint = configure_serial }});
    try Harness.transfer(&server, &client);
    var configure_message = client.popMessage() orelse return error.MissingMessage;
    defer configure_message.deinit();
    const configure = (try generated.xdg_surface_types.decodeEvent(&client, client_xdg_surface, &configure_message)).configure;
    try std.testing.expectEqual(configure_serial, configure.serial);

    try generated.xdg_surface_types.requests.ack_configure(&client, client_xdg_surface, configure.serial);
    try Harness.transfer(&client, &server);
    var ack_message = server.popMessage() orelse return error.MissingMessage;
    defer ack_message.deinit();
    const ack = (try generated.xdg_surface_types.decodeRequest(&server, server_xdg_surface, &ack_message)).ack_configure;
    try std.testing.expectEqual(configure_serial, ack.serial);

    try generated.wl_surface_types.requests.attach(&client, client_surface, client_buffer, 0, 0);
    try Harness.transfer(&client, &server);
    var attach_message = server.popMessage() orelse return error.MissingMessage;
    defer attach_message.deinit();
    const attach = (try generated.wl_surface_types.decodeRequest(&server, server_surface, &attach_message)).attach;
    try std.testing.expectEqual(server_buffer.id, attach.buffer.?);

    try generated.wl_surface_types.requests.damage_buffer(&client, client_surface, 0, 0, 64, 64);
    try Harness.transfer(&client, &server);
    var damage_message = server.popMessage() orelse return error.MissingMessage;
    defer damage_message.deinit();
    const damage = (try generated.wl_surface_types.decodeRequest(&server, server_surface, &damage_message)).damage_buffer;
    try std.testing.expectEqual(@as(i32, 64), damage.width);
    try std.testing.expectEqual(@as(i32, 64), damage.height);

    try generated.wl_surface_types.requests.commit(&client, client_surface);
    try Harness.transfer(&client, &server);
    var final_commit_message = server.popMessage() orelse return error.MissingMessage;
    defer final_commit_message.deinit();
    _ = (try generated.wl_surface_types.decodeRequest(&server, server_surface, &final_commit_message)).commit;
    try std.testing.expect(client.popMessage() == null);
    try std.testing.expect(server.popMessage() == null);
}
