//! io_uring-backed Wayring client bootstrap and required global discovery.

const Client = @This();

const std = @import("std");
const keywork_loop = @import("keywork-loop");
const wayring = @import("wayring");
const IoUringTransport = @import("wayring-uring");
const protocol = @import("wayring-protocols");

const IoUringLoop = keywork_loop.IoUringLoop;

pub const Notification = enum { ready, eof, fatal };
pub const Notify = *const fn (context: *anyopaque, client: *Client, notification: Notification) anyerror!void;
pub const MessageNotify = *const fn (context: *anyopaque, client: *Client, message: *const wayring.Message) anyerror!void;

pub const Window = struct {
    surface: wayring.ObjectHandle,
    xdg_surface: wayring.ObjectHandle,
    toplevel: wayring.ObjectHandle,
};

pub const DmaBufCandidate = struct {
    format: u32,
    modifier: u64,
};

const SyncPhase = enum { globals, bindings };

const Global = struct {
    name: u32,
    handle: wayring.ObjectHandle,
};

allocator: std.mem.Allocator,
loop: *IoUringLoop,
connection: wayring.Connection,
transport: IoUringTransport,
notify_context: *anyopaque,
notify: Notify,
message_notify: MessageNotify,
display: wayring.ObjectHandle,
registry: wayring.ObjectHandle,
sync_callback: ?wayring.ObjectHandle,
compositor: ?Global = null,
wm_base: ?Global = null,
dmabuf: ?Global = null,
dmabuf_candidates: std.ArrayList(DmaBufCandidate) = .empty,
sync_phase: SyncPhase = .globals,
ready: bool = false,

pub fn initFd(
    self: *Client,
    allocator: std.mem.Allocator,
    fd: i32,
    loop: *IoUringLoop,
    notify_context: *anyopaque,
    notify: Notify,
    message_notify: MessageNotify,
) !void {
    try self.initBase(allocator, loop, notify_context, notify, message_notify);
    errdefer self.connection.deinit();
    try self.transport.init(fd, loop, &self.connection, self, transportNotify);
}

pub fn initConnect(
    self: *Client,
    allocator: std.mem.Allocator,
    path: []const u8,
    loop: *IoUringLoop,
    notify_context: *anyopaque,
    notify: Notify,
    message_notify: MessageNotify,
) !void {
    try self.initBase(allocator, loop, notify_context, notify, message_notify);
    errdefer self.connection.deinit();
    try self.transport.initConnect(path, loop, &self.connection, self, transportNotify);
}

fn initBase(
    self: *Client,
    allocator: std.mem.Allocator,
    loop: *IoUringLoop,
    notify_context: *anyopaque,
    notify: Notify,
    message_notify: MessageNotify,
) !void {
    self.* = .{
        .allocator = allocator,
        .loop = loop,
        .connection = wayring.Connection.init(allocator, .client, wayring.default_max_frame_size),
        .transport = undefined,
        .notify_context = notify_context,
        .notify = notify,
        .message_notify = message_notify,
        .display = undefined,
        .registry = undefined,
        .sync_callback = null,
    };
    errdefer self.connection.deinit();
    self.display = .{
        .id = 1,
        .generation = try self.connection.registerObject(1, &protocol.wl_display, 1),
    };
    self.registry = try protocol.wl_display_types.requests.get_registry(&self.connection, self.display);
    self.sync_callback = try protocol.wl_display_types.requests.sync(&self.connection, self.display);
}

pub fn flush(self: *Client) !void {
    try self.transport.flush();
}

pub fn shutdown(self: *Client) !void {
    try self.transport.shutdown();
}

pub fn readyToDeinit(self: *Client) bool {
    return self.transport.readyToDeinit();
}

pub fn deinit(self: *Client) void {
    self.transport.deinit();
    self.dmabuf_candidates.deinit(self.allocator);
    self.connection.deinit();
    self.* = undefined;
}

pub fn isReady(self: *const Client) bool {
    return self.ready;
}

pub fn dmaBufFactory(self: *const Client) ?wayring.ObjectHandle {
    return if (self.dmabuf) |global| global.handle else null;
}

pub fn dmaBufCandidates(self: *const Client) []const DmaBufCandidate {
    return self.dmabuf_candidates.items;
}

pub fn createXdgWindow(self: *Client, title: []const u8, app_id: []const u8) !Window {
    if (!self.ready) return error.ClientNotReady;
    const compositor = self.compositor orelse return error.MissingCompositor;
    const wm_base = self.wm_base orelse return error.MissingXdgWmBase;
    const surface = try protocol.wl_compositor_types.requests.create_surface(
        &self.connection,
        compositor.handle,
    );
    const xdg_surface = try protocol.xdg_wm_base_types.requests.get_xdg_surface(
        &self.connection,
        wm_base.handle,
        surface,
    );
    const toplevel = try protocol.xdg_surface_types.requests.get_toplevel(
        &self.connection,
        xdg_surface,
    );
    if (title.len != 0) try protocol.xdg_toplevel_types.requests.set_title(
        &self.connection,
        toplevel,
        title,
    );
    if (app_id.len != 0) try protocol.xdg_toplevel_types.requests.set_app_id(
        &self.connection,
        toplevel,
        app_id,
    );
    try protocol.wl_surface_types.requests.commit(&self.connection, surface);
    try self.flush();
    return .{ .surface = surface, .xdg_surface = xdg_surface, .toplevel = toplevel };
}

fn transportNotify(
    context: *anyopaque,
    _: *IoUringTransport,
    notification: IoUringTransport.Notification,
) !void {
    const self: *Client = @ptrCast(@alignCast(context));
    switch (notification) {
        .connected => {},
        .messages => try self.dispatchMessages(),
        .eof => try self.notify(self.notify_context, self, .eof),
        .fatal => try self.notify(self.notify_context, self, .fatal),
    }
}

fn dispatchMessages(self: *Client) !void {
    while (self.connection.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == self.display.id) {
            try self.handleDisplay(&message);
        } else if (message.object_id == self.registry.id) {
            try self.handleRegistry(&message);
        } else if (self.sync_callback) |callback| {
            if (message.object_id == callback.id) {
                _ = try protocol.wl_callback_types.decodeEvent(
                    &self.connection,
                    callback,
                    &message,
                );
                self.sync_callback = null;
                if (self.compositor == null or self.wm_base == null or self.dmabuf == null)
                    return error.MissingRequiredGlobal;
                switch (self.sync_phase) {
                    .globals => {
                        self.sync_phase = .bindings;
                        self.sync_callback = try protocol.wl_display_types.requests.sync(
                            &self.connection,
                            self.display,
                        );
                    },
                    .bindings => {
                        self.ready = true;
                        try self.notify(self.notify_context, self, .ready);
                    },
                }
                continue;
            }
            try self.dispatchApplicationMessage(&message);
        } else {
            try self.dispatchApplicationMessage(&message);
        }
    }
    try self.flush();
}

fn dispatchApplicationMessage(self: *Client, message: *const wayring.Message) !void {
    if (self.dmabuf) |global| {
        if (message.object_id == global.handle.id) {
            switch (try protocol.zwp_linux_dmabuf_v1_types.decodeEvent(
                &self.connection,
                global.handle,
                message,
            )) {
                .format => {},
                .modifier => |event| {
                    const candidate: DmaBufCandidate = .{
                        .format = event.format,
                        .modifier = (@as(u64, event.modifier_hi) << 32) | event.modifier_lo,
                    };
                    for (self.dmabuf_candidates.items) |existing| {
                        if (std.meta.eql(existing, candidate)) return;
                    }
                    try self.dmabuf_candidates.append(self.allocator, candidate);
                },
            }
            return;
        }
    }
    if (self.wm_base) |global| {
        if (message.object_id == global.handle.id) {
            const ping = (try protocol.xdg_wm_base_types.decodeEvent(
                &self.connection,
                global.handle,
                message,
            )).ping;
            try protocol.xdg_wm_base_types.requests.pong(
                &self.connection,
                global.handle,
                ping.serial,
            );
            return;
        }
    }
    try self.message_notify(self.notify_context, self, message);
}

fn handleDisplay(self: *Client, message: *const wayring.Message) !void {
    switch (try protocol.wl_display_types.decodeEvent(&self.connection, self.display, message)) {
        .@"error" => return error.WaylandProtocolError,
        .delete_id => |event| try self.connection.releaseClientObjectId(event.id),
    }
}

fn handleRegistry(self: *Client, message: *const wayring.Message) !void {
    switch (try protocol.wl_registry_types.decodeEvent(&self.connection, self.registry, message)) {
        .global => |event| try self.bindGlobal(event.name, event.interface, event.version),
        .global_remove => |event| {
            if ((self.compositor != null and self.compositor.?.name == event.name) or
                (self.wm_base != null and self.wm_base.?.name == event.name) or
                (self.dmabuf != null and self.dmabuf.?.name == event.name))
            {
                return error.RequiredGlobalRemoved;
            }
        },
    }
}

fn bindGlobal(self: *Client, name: u32, interface_name: []const u8, advertised_version: u32) !void {
    if (std.mem.eql(u8, interface_name, protocol.wl_compositor.name) and self.compositor == null) {
        self.compositor = .{
            .name = name,
            .handle = try self.bind(name, advertised_version, &protocol.wl_compositor, protocol.wl_compositor.version),
        };
    } else if (std.mem.eql(u8, interface_name, protocol.xdg_wm_base.name) and self.wm_base == null) {
        self.wm_base = .{
            .name = name,
            .handle = try self.bind(name, advertised_version, &protocol.xdg_wm_base, protocol.xdg_wm_base.version),
        };
    } else if (std.mem.eql(u8, interface_name, protocol.zwp_linux_dmabuf_v1.name) and self.dmabuf == null) {
        if (advertised_version < 3) return;
        self.dmabuf = .{
            .name = name,
            .handle = try self.bind(name, advertised_version, &protocol.zwp_linux_dmabuf_v1, 3),
        };
    }
}

fn bind(
    self: *Client,
    name: u32,
    advertised_version: u32,
    interface: *const wayring.Interface,
    maximum_version: u32,
) !wayring.ObjectHandle {
    return protocol.wl_registry_types.requests.bind(
        &self.connection,
        self.registry,
        name,
        interface,
        @min(advertised_version, maximum_version),
    );
}

test "io_uring client discovers and binds required globals" {
    const linux = std.os.linux;
    const Context = struct {
        client: *Client,
        server: *IoUringTransport,
        ready: bool = false,
        bind_count: usize = 0,

        fn clientNotify(context: *anyopaque, _: *Client, notification: Notification) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (notification != .ready) return;
            self.ready = true;
            if (self.bind_count == 3) {
                try self.client.shutdown();
                try self.server.shutdown();
            }
        }

        fn clientMessage(_: *anyopaque, _: *Client, _: *const wayring.Message) !void {
            return error.UnexpectedMessage;
        }

        fn serverNotify(
            context: *anyopaque,
            transport: *IoUringTransport,
            notification: IoUringTransport.Notification,
        ) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (notification != .messages) return;
            while (transport.connection.popMessage()) |popped| {
                var message = popped;
                defer message.deinit();
                if (message.object_id == 1) {
                    const display: wayring.ObjectHandle = .{
                        .id = 1,
                        .generation = transport.connection.object(1).?.generation,
                    };
                    switch (try protocol.wl_display_types.decodeRequest(
                        transport.connection,
                        display,
                        &message,
                    )) {
                        .get_registry => |request| {
                            const registry = try registerServerObject(
                                transport.connection,
                                request.registry,
                                &protocol.wl_registry,
                                1,
                            );
                            try transport.connection.queue(registry.id, 0, &.{
                                .{ .uint = 10 }, .{ .string = protocol.wl_compositor.name }, .{ .uint = 6 },
                            });
                            try transport.connection.queue(registry.id, 0, &.{
                                .{ .uint = 11 }, .{ .string = protocol.xdg_wm_base.name }, .{ .uint = 6 },
                            });
                            try transport.connection.queue(registry.id, 0, &.{
                                .{ .uint = 12 }, .{ .string = protocol.zwp_linux_dmabuf_v1.name }, .{ .uint = 4 },
                            });
                        },
                        .sync => |request| {
                            const callback = try registerServerObject(
                                transport.connection,
                                request.callback,
                                &protocol.wl_callback,
                                1,
                            );
                            try transport.connection.queue(callback.id, 0, &.{.{ .uint = 1 }});
                            try transport.connection.queue(1, 1, &.{.{ .uint = callback.id }});
                        },
                    }
                } else {
                    const object = transport.connection.object(message.object_id).?;
                    if (object.interface != &protocol.wl_registry) return error.UnexpectedRequest;
                    const registry: wayring.ObjectHandle = .{
                        .id = message.object_id,
                        .generation = object.generation,
                    };
                    const request = (try protocol.wl_registry_types.decodeRequest(
                        transport.connection,
                        registry,
                        &message,
                    )).bind;
                    const interface = if (std.mem.eql(u8, request.new_interface.?, protocol.wl_compositor.name))
                        &protocol.wl_compositor
                    else if (std.mem.eql(u8, request.new_interface.?, protocol.xdg_wm_base.name))
                        &protocol.xdg_wm_base
                    else if (std.mem.eql(u8, request.new_interface.?, protocol.zwp_linux_dmabuf_v1.name))
                        &protocol.zwp_linux_dmabuf_v1
                    else
                        return error.UnexpectedBind;
                    const bound = try registerServerObject(
                        transport.connection,
                        request.id,
                        interface,
                        request.new_version,
                    );
                    if (interface == &protocol.zwp_linux_dmabuf_v1) {
                        try transport.connection.queue(bound.id, 1, &.{
                            .{ .uint = 0x34325241 }, .{ .uint = 0 }, .{ .uint = 7 },
                        });
                    }
                    self.bind_count += 1;
                }
            }
            try transport.flush();
            if (self.ready and self.bind_count == 3) {
                try self.client.shutdown();
                try self.server.shutdown();
            }
        }

        fn registerServerObject(
            connection: *wayring.Connection,
            id: u32,
            interface: *const wayring.Interface,
            version: u32,
        ) !wayring.ObjectHandle {
            return .{ .id = id, .generation = try connection.registerObject(id, interface, version) };
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
    var server_connection = wayring.Connection.init(std.testing.allocator, .server, 4096);
    defer server_connection.deinit();
    _ = try server_connection.registerObject(1, &protocol.wl_display, 1);

    var client: Client = undefined;
    var server: IoUringTransport = undefined;
    var context: Context = .{ .client = &client, .server = &server };
    try client.initFd(
        std.testing.allocator,
        sockets[0],
        &loop,
        &context,
        Context.clientNotify,
        Context.clientMessage,
    );
    try server.init(sockets[1], &loop, &server_connection, &context, Context.serverNotify);
    sockets_owned = false;
    try client.flush();
    while (loop.hasActiveOperations()) try loop.runOnce();

    try std.testing.expect(context.ready);
    try std.testing.expectEqual(@as(usize, 3), context.bind_count);
    try std.testing.expectEqualSlices(DmaBufCandidate, &.{.{
        .format = 0x34325241,
        .modifier = 7,
    }}, client.dmaBufCandidates());
    try std.testing.expect(client.readyToDeinit());
    try std.testing.expect(server.readyToDeinit());
    client.deinit();
    server.deinit();
}

test {
    std.testing.refAllDecls(Client);
}
