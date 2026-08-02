//! Deny-only provenance for clients accepted through security-context listeners.

const SecurityContextGlobal = @This();

const std = @import("std");
const linux = std.os.linux;
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const IoUringServer = @import("wayring-server-uring");

allocator: std.mem.Allocator,
server: *Server,
transport: *IoUringServer,
global_name: u32,
contexts: std.ArrayList(*Context) = .empty,

var provenance_key: u8 = 0;

pub const Metadata = struct {
    sandbox_engine: ?[]const u8,
    app_id: ?[]const u8,
    instance_id: ?[]const u8,
};

const OwnedMetadata = struct {
    allocator: std.mem.Allocator,
    sandbox_engine: ?[]u8 = null,
    app_id: ?[]u8 = null,
    instance_id: ?[]u8 = null,

    fn cloneForClient(context: *anyopaque) !Server.OwnedProvenance {
        const self: *@This() = @ptrCast(@alignCast(context));
        const copy = try self.allocator.create(OwnedMetadata);
        copy.* = .{ .allocator = self.allocator };
        errdefer copy.destroy();
        copy.sandbox_engine = try duplicateOptional(self.allocator, self.sandbox_engine);
        copy.app_id = try duplicateOptional(self.allocator, self.app_id);
        copy.instance_id = try duplicateOptional(self.allocator, self.instance_id);
        return .{
            .key = &provenance_key,
            .data = copy,
            .destroy = destroyClientMetadata,
        };
    }

    fn destroy(self: *OwnedMetadata) void {
        if (self.sandbox_engine) |value| self.allocator.free(value);
        if (self.app_id) |value| self.allocator.free(value);
        if (self.instance_id) |value| self.allocator.free(value);
        self.allocator.destroy(self);
    }

    fn view(self: *const OwnedMetadata) Metadata {
        return .{
            .sandbox_engine = self.sandbox_engine,
            .app_id = self.app_id,
            .instance_id = self.instance_id,
        };
    }
};

const Context = struct {
    owner: *SecurityContextGlobal,
    resource: wayring.ObjectHandle,
    listen_fd: i32,
    close_fd: i32,
    sandbox_engine: ?[]u8 = null,
    app_id: ?[]u8 = null,
    instance_id: ?[]u8 = null,
    committed: bool = false,

    fn deinit(self: *Context) void {
        const owner = self.owner;
        for (owner.contexts.items, 0..) |candidate, index| {
            if (candidate != self) continue;
            _ = owner.contexts.orderedRemove(index);
            self.deinitOwned();
            owner.allocator.destroy(self);
            return;
        }
        unreachable;
    }

    fn deinitOwned(self: *Context) void {
        if (self.listen_fd >= 0) _ = linux.close(self.listen_fd);
        if (self.close_fd >= 0) _ = linux.close(self.close_fd);
        if (self.sandbox_engine) |value| self.owner.allocator.free(value);
        if (self.app_id) |value| self.owner.allocator.free(value);
        if (self.instance_id) |value| self.owner.allocator.free(value);
    }
};

pub fn init(
    self: *SecurityContextGlobal,
    allocator: std.mem.Allocator,
    server: *Server,
    transport: *IoUringServer,
) !void {
    self.* = .{
        .allocator = allocator,
        .server = server,
        .transport = transport,
        .global_name = undefined,
    };
    self.global_name = try server.createGlobal(
        &generated.wp_security_context_manager_v1,
        1,
        .{
            .context = self,
            .bind = bind,
            .filter_context = self,
            .filter = allowUnconfined,
        },
    );
}

pub fn deinit(self: *SecurityContextGlobal) void {
    std.debug.assert(self.contexts.items.len == 0);
    self.server.removeGlobal(self.global_name) catch unreachable;
    self.contexts.deinit(self.allocator);
    self.* = undefined;
}

/// Returns self-asserted metadata. Its presence is deny-only authority.
pub fn metadataFor(self: *const SecurityContextGlobal, client: *const Server.Client) ?Metadata {
    _ = self;
    const raw = client.provenance(&provenance_key) orelse return null;
    const metadata: *const OwnedMetadata = @ptrCast(@alignCast(raw));
    return metadata.view();
}

/// Global filter for capabilities unavailable to contextual clients.
pub fn allowUnconfined(_: *anyopaque, client: *const Server.Client) bool {
    return client.provenance(&provenance_key) == null;
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *SecurityContextGlobal = @ptrCast(@alignCast(context));
    const resource = client.createResource(
        id,
        &generated.wp_security_context_manager_v1,
        version,
        .{ .context = self, .dispatch = dispatchManager },
    ) catch return client.postNoMemory();
    if (!allowUnconfined(self, client)) return client.postError(
        resource,
        @intFromEnum(generated.wp_security_context_manager_v1_types.@"error".nested),
        "nested security contexts are forbidden",
    );
}

fn dispatchManager(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const self: *SecurityContextGlobal = @ptrCast(@alignCast(context));
    switch (try generated.wp_security_context_manager_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .create_listener => |request| try self.createContext(
            client,
            resource,
            message,
            request.id,
            request.listen_fd,
            request.close_fd,
        ),
    }
}

fn createContext(
    self: *SecurityContextGlobal,
    client: *Server.Client,
    manager_resource: wayring.ObjectHandle,
    message: *wayring.Message,
    id: u32,
    listen_fd_index: usize,
    close_fd_index: usize,
) !void {
    const listen_fd = try message.takeFd(listen_fd_index);
    var listen_fd_owned = true;
    defer if (listen_fd_owned) {
        _ = linux.close(listen_fd);
    };
    const close_fd = try message.takeFd(close_fd_index);
    var close_fd_owned = true;
    defer if (close_fd_owned) {
        _ = linux.close(close_fd);
    };
    if (!validListenFd(listen_fd)) return client.postError(
        manager_resource,
        @intFromEnum(
            generated.wp_security_context_manager_v1_types.@"error".invalid_listen_fd,
        ),
        "listen_fd is not a listening socket",
    );

    const context = self.allocator.create(Context) catch
        return client.postNoMemory();
    context.* = .{
        .owner = self,
        .resource = undefined,
        .listen_fd = listen_fd,
        .close_fd = close_fd,
    };
    listen_fd_owned = false;
    close_fd_owned = false;
    var registered = false;
    errdefer if (!registered) {
        context.deinitOwned();
        self.allocator.destroy(context);
    };
    self.contexts.ensureUnusedCapacity(self.allocator, 1) catch
        return client.postNoMemory();
    const version = try client.resourceVersion(
        manager_resource,
        &generated.wp_security_context_manager_v1,
    );
    context.resource = client.createResource(
        id,
        &generated.wp_security_context_v1,
        version,
        .{
            .context = context,
            .dispatch = dispatchContext,
            .destroy = destroyContext,
        },
    ) catch return client.postNoMemory();
    self.contexts.appendAssumeCapacity(context);
    registered = true;
}

fn dispatchContext(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const security_context: *Context = @ptrCast(@alignCast(context));
    const request = try generated.wp_security_context_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    );
    if (request == .destroy) return;
    if (security_context.committed) return client.postError(
        resource,
        @intFromEnum(generated.wp_security_context_v1_types.@"error".already_used),
        "security context is already committed",
    );
    switch (request) {
        .destroy => unreachable,
        .set_sandbox_engine => |set| try setMetadata(
            security_context,
            client,
            &security_context.sandbox_engine,
            set.name,
        ),
        .set_app_id => |set| try setMetadata(
            security_context,
            client,
            &security_context.app_id,
            set.app_id,
        ),
        .set_instance_id => |set| try setMetadata(
            security_context,
            client,
            &security_context.instance_id,
            set.instance_id,
        ),
        .commit => try commit(security_context, client),
    }
}

fn setMetadata(
    context: *Context,
    client: *Server.Client,
    destination: *?[]u8,
    value: []const u8,
) !void {
    if (destination.* != null) return client.postError(
        context.resource,
        @intFromEnum(generated.wp_security_context_v1_types.@"error".already_set),
        "security context metadata is already set",
    );
    destination.* = context.owner.allocator.dupe(u8, value) catch
        return client.postNoMemory();
}

fn commit(context: *Context, client: *Server.Client) !void {
    const owner = context.owner;
    const metadata = owner.allocator.create(OwnedMetadata) catch
        return client.postNoMemory();
    metadata.* = .{
        .allocator = owner.allocator,
        .sandbox_engine = context.sandbox_engine,
        .app_id = context.app_id,
        .instance_id = context.instance_id,
    };
    context.sandbox_engine = null;
    context.app_id = null;
    context.instance_id = null;
    const listen_fd = context.listen_fd;
    const close_fd = context.close_fd;
    context.listen_fd = -1;
    context.close_fd = -1;
    context.committed = true;
    owner.transport.adoptListener(.{
        .listen_fd = listen_fd,
        .lifetime_fd = close_fd,
        .provenance = .{
            .context = metadata,
            .cloneForClient = OwnedMetadata.cloneForClient,
            .destroy = destroyListenerMetadata,
        },
    }) catch return client.postNoMemory();
}

fn destroyContext(
    context: *anyopaque,
    _: *Server.Client,
    _: wayring.ObjectHandle,
) void {
    const security_context: *Context = @ptrCast(@alignCast(context));
    security_context.deinit();
}

fn validListenFd(fd: i32) bool {
    var accepting: i32 = 0;
    var length: linux.socklen_t = @sizeOf(i32);
    const result = linux.getsockopt(
        fd,
        linux.SOL.SOCKET,
        linux.SO.ACCEPTCONN,
        std.mem.asBytes(&accepting).ptr,
        &length,
    );
    return linux.errno(result) == .SUCCESS and
        length == @sizeOf(i32) and accepting != 0;
}

fn duplicateOptional(
    allocator: std.mem.Allocator,
    value: ?[]const u8,
) error{OutOfMemory}!?[]u8 {
    return if (value) |source| try allocator.dupe(u8, source) else null;
}

fn destroyListenerMetadata(context: *anyopaque) void {
    const metadata: *OwnedMetadata = @ptrCast(@alignCast(context));
    metadata.destroy();
}

fn destroyClientMetadata(context: *anyopaque) void {
    const metadata: *OwnedMetadata = @ptrCast(@alignCast(context));
    metadata.destroy();
}

test "metadata is deep-owned and all-null provenance is still confined" {
    const core = @import("wayring-core");
    const allocator = std.testing.allocator;
    var server = Server.init(allocator);
    defer server.deinit();
    var transport: IoUringServer = undefined;
    var security_context: SecurityContextGlobal = undefined;
    try security_context.init(allocator, &server, &transport);
    defer security_context.deinit();

    const ordinary = try server.createClient();
    defer server.destroyClient(ordinary) catch unreachable;
    try std.testing.expect(try managerAdvertised(core, allocator, ordinary));
    try std.testing.expect(allowUnconfined(&security_context, ordinary));
    try std.testing.expect(security_context.metadataFor(ordinary) == null);

    const populated_template = try allocator.create(OwnedMetadata);
    populated_template.* = .{ .allocator = allocator };
    var populated_template_owned = true;
    defer if (populated_template_owned) populated_template.destroy();
    populated_template.sandbox_engine = try allocator.dupe(u8, "bubblewrap");
    populated_template.app_id = try allocator.dupe(u8, "org.example.App");
    populated_template.instance_id = try allocator.dupe(u8, "instance-1");
    const populated_provenance = try OwnedMetadata.cloneForClient(populated_template);
    populated_template.destroy();
    populated_template_owned = false;
    const populated = try server.createClientWithProvenance(populated_provenance);
    defer server.destroyClient(populated) catch unreachable;
    const metadata = security_context.metadataFor(populated).?;
    try std.testing.expectEqualStrings("bubblewrap", metadata.sandbox_engine.?);
    try std.testing.expectEqualStrings("org.example.App", metadata.app_id.?);
    try std.testing.expectEqualStrings("instance-1", metadata.instance_id.?);

    const empty_template = try allocator.create(OwnedMetadata);
    empty_template.* = .{ .allocator = allocator };
    var empty_template_owned = true;
    defer if (empty_template_owned) empty_template.destroy();
    const empty_provenance = try OwnedMetadata.cloneForClient(empty_template);
    empty_template.destroy();
    empty_template_owned = false;
    const confined = try server.createClientWithProvenance(empty_provenance);
    defer server.destroyClient(confined) catch unreachable;
    const empty = security_context.metadataFor(confined).?;
    try std.testing.expect(empty.sandbox_engine == null);
    try std.testing.expect(empty.app_id == null);
    try std.testing.expect(empty.instance_id == null);
    try std.testing.expect(!allowUnconfined(&security_context, confined));
    try std.testing.expect(!(try managerAdvertised(core, allocator, confined)));
}

fn managerAdvertised(
    comptime core: type,
    allocator: std.mem.Allocator,
    client: *Server.Client,
) !bool {
    var peer = wayring.Connection.init(allocator, .client, wayring.default_max_frame_size);
    defer peer.deinit();
    _ = try core.bootstrapDisplay(&peer);
    const registry: wayring.ObjectHandle = .{
        .id = 2,
        .generation = try core.getRegistry(&peer, 2),
    };
    try transferTest(&peer, &client.connection, client);
    try transferTest(&client.connection, &peer, null);
    try client.outputDrained();
    var advertised = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const event = try core.decodeRegistryEvent(&message, registry.id);
        if (event == .global and std.mem.eql(
            u8,
            event.global.interface,
            generated.wp_security_context_manager_v1.name,
        )) advertised = true;
    }
    return advertised;
}

fn transferTest(
    sender: *wayring.Connection,
    receiver: *wayring.Connection,
    server_client: ?*Server.Client,
) !void {
    while (sender.nextBatch()) |batch| {
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
        const transferred = duplicated[0..count];
        count = 0;
        if (server_client) |client|
            try client.receive(batch.bytes, transferred)
        else
            try receiver.feed(batch.bytes, transferred);
        try sender.acknowledge(batch.token, batch.bytes.len);
    }
}

test "committed protocol listener outlives its creator and confines accepted clients" {
    const core = @import("wayring-core");
    const IoUringLoop = @import("keywork-loop").IoUringLoop;
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    var main_path_buffer: [@sizeOf(@FieldType(linux.sockaddr.un, "path"))]u8 = undefined;
    const main_path = try std.fmt.bufPrint(
        &main_path_buffer,
        ".zig-cache/tmp/{s}/main",
        .{temporary.sub_path},
    );
    const main_listener = try createTestListener(main_path);
    var main_listener_owned = true;
    defer if (main_listener_owned) {
        _ = linux.close(main_listener);
    };

    var loop = try IoUringLoop.init(allocator);
    defer loop.deinit();
    var server = Server.init(allocator);
    defer server.deinit();
    var transport: IoUringServer = undefined;
    main_listener_owned = false;
    try transport.init(allocator, &loop, &server, main_listener);
    var security_context: SecurityContextGlobal = undefined;
    try security_context.init(allocator, &server, &transport);
    const unrestricted_name = try server.createGlobal(
        &generated.wl_compositor,
        1,
        .{ .context = &server, .bind = testGlobalBind },
    );
    var unrestricted_owned = true;
    defer if (unrestricted_owned) {
        server.removeGlobal(unrestricted_name) catch unreachable;
    };

    const creator = try server.createClient();
    var creator_owned = true;
    defer if (creator_owned) {
        server.destroyClient(creator) catch unreachable;
    };
    var creator_peer = wayring.Connection.init(allocator, .client, wayring.default_max_frame_size);
    defer creator_peer.deinit();
    _ = try core.bootstrapDisplay(&creator_peer);
    const registry: wayring.ObjectHandle = .{
        .id = 2,
        .generation = try core.getRegistry(&creator_peer, 2),
    };
    try transferTest(&creator_peer, &creator.connection, creator);
    try transferTest(&creator.connection, &creator_peer, null);
    try creator.outputDrained();
    var manager_name: u32 = 0;
    while (creator_peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const event = try core.decodeRegistryEvent(&message, registry.id);
        if (event == .global and std.mem.eql(
            u8,
            event.global.interface,
            generated.wp_security_context_manager_v1.name,
        )) manager_name = event.global.name;
    }
    try std.testing.expect(manager_name != 0);
    const manager: wayring.ObjectHandle = .{
        .id = 3,
        .generation = try core.bind(
            &creator_peer,
            registry.id,
            manager_name,
            generated.wp_security_context_manager_v1.name,
            1,
            3,
            &generated.wp_security_context_manager_v1,
        ),
    };

    var contextual_path_buffer: [@sizeOf(@FieldType(linux.sockaddr.un, "path"))]u8 = undefined;
    const contextual_path = try std.fmt.bufPrint(
        &contextual_path_buffer,
        ".zig-cache/tmp/{s}/contextual",
        .{temporary.sub_path},
    );
    const contextual_listener = try createTestListener(contextual_path);
    var contextual_listener_owned = true;
    defer if (contextual_listener_owned) {
        _ = linux.close(contextual_listener);
    };
    var lifetime: [2]i32 = undefined;
    if (linux.errno(linux.socketpair(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
        0,
        &lifetime,
    )) != .SUCCESS) return error.SocketPairFailed;
    var lifetime_listener_owned = true;
    defer if (lifetime_listener_owned) {
        _ = linux.close(lifetime[0]);
    };
    var lifetime_peer_owned = true;
    defer if (lifetime_peer_owned) {
        _ = linux.close(lifetime[1]);
    };

    const context = try generated.wp_security_context_manager_v1_types.requests.create_listener(
        &creator_peer,
        manager,
        contextual_listener,
        lifetime[0],
    );
    contextual_listener_owned = false;
    lifetime_listener_owned = false;
    // Manager destruction does not destroy its child context.
    try generated.wp_security_context_manager_v1_types.requests.destroy(&creator_peer, manager);
    try generated.wp_security_context_v1_types.requests.set_sandbox_engine(
        &creator_peer,
        context,
        "bubblewrap",
    );
    try generated.wp_security_context_v1_types.requests.set_app_id(
        &creator_peer,
        context,
        "org.example.App",
    );
    try generated.wp_security_context_v1_types.requests.set_instance_id(
        &creator_peer,
        context,
        "instance-1",
    );
    try generated.wp_security_context_v1_types.requests.commit(&creator_peer, context);
    try transferTest(&creator_peer, &creator.connection, creator);
    try std.testing.expectEqual(@as(usize, 2), transport.listenerCount());

    // The adopted listener is independent of the context resource and creator.
    try server.destroyClient(creator);
    creator_owned = false;
    try std.testing.expectEqual(@as(usize, 0), security_context.contexts.items.len);
    try std.testing.expectEqual(@as(usize, 2), transport.listenerCount());

    const contextual_fd = try connectTestClient(contextual_path);
    var contextual_fd_owned = true;
    defer if (contextual_fd_owned) {
        _ = linux.close(contextual_fd);
    };
    var contextual_peer = wayring.Connection.init(allocator, .client, wayring.default_max_frame_size);
    defer contextual_peer.deinit();
    _ = try core.bootstrapDisplay(&contextual_peer);
    const contextual_registry: wayring.ObjectHandle = .{
        .id = 2,
        .generation = try core.getRegistry(&contextual_peer, 2),
    };
    try sendConnection(&contextual_peer, contextual_fd);
    var turns: usize = 0;
    while (transport.clientCount() == 0 and turns < 32) : (turns += 1) {
        try loop.runOnce();
        try transport.dispatch();
    }
    try std.testing.expectEqual(@as(usize, 1), transport.clientCount());
    // Receive and dispatch the registry request, then submit its output.
    try loop.runOnce();
    try transport.dispatch();
    _ = try loop.submit();
    try receiveConnection(&contextual_peer, contextual_fd);

    var manager_advertised = false;
    while (contextual_peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const event = try core.decodeRegistryEvent(&message, contextual_registry.id);
        if (event == .global and std.mem.eql(
            u8,
            event.global.interface,
            generated.wp_security_context_manager_v1.name,
        )) manager_advertised = true;
    }
    try std.testing.expect(!manager_advertised);

    // Lifetime HUP removes only the contextual listener. Its accepted client
    // remains alive with independently owned provenance.
    _ = linux.close(lifetime[1]);
    lifetime_peer_owned = false;
    turns = 0;
    while (transport.listenerCount() != 1 and turns < 32) : (turns += 1) {
        try loop.runOnce();
        try transport.dispatch();
    }
    try std.testing.expectEqual(@as(usize, 1), transport.listenerCount());
    try std.testing.expectEqual(@as(usize, 1), transport.clientCount());

    _ = linux.close(contextual_fd);
    contextual_fd_owned = false;
    turns = 0;
    while (transport.clientCount() != 0 and turns < 32) : (turns += 1) {
        try loop.runOnce();
        try transport.dispatch();
    }
    try std.testing.expectEqual(@as(usize, 0), transport.clientCount());
    try transport.shutdown();
    while (!transport.readyToDeinit()) {
        try loop.runOnce();
        try transport.dispatch();
    }
    try transport.dispatch();
    transport.deinit();
    try server.removeGlobal(unrestricted_name);
    unrestricted_owned = false;
    security_context.deinit();
}

fn testGlobalBind(_: *anyopaque, _: *Server.Client, _: u32, _: u32) !void {
    unreachable;
}

fn createTestListener(path: []const u8) !i32 {
    var address: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = undefined };
    if (path.len >= address.path.len) return error.NameTooLong;
    @memset(&address.path, 0);
    @memcpy(address.path[0..path.len], path);
    const result = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(result) != .SUCCESS) return error.SocketFailed;
    const fd: i32 = @intCast(result);
    errdefer _ = linux.close(fd);
    const address_length: linux.socklen_t = @intCast(
        @offsetOf(linux.sockaddr.un, "path") + path.len + 1,
    );
    if (linux.errno(linux.bind(fd, @ptrCast(&address), address_length)) != .SUCCESS)
        return error.BindFailed;
    if (linux.errno(linux.listen(fd, 8)) != .SUCCESS) return error.ListenFailed;
    return fd;
}

fn connectTestClient(path: []const u8) !i32 {
    var address: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = undefined };
    if (path.len >= address.path.len) return error.NameTooLong;
    @memset(&address.path, 0);
    @memcpy(address.path[0..path.len], path);
    const result = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(result) != .SUCCESS) return error.SocketFailed;
    const fd: i32 = @intCast(result);
    errdefer _ = linux.close(fd);
    const address_length: linux.socklen_t = @intCast(
        @offsetOf(linux.sockaddr.un, "path") + path.len + 1,
    );
    if (linux.errno(linux.connect(fd, @ptrCast(&address), address_length)) != .SUCCESS)
        return error.ConnectFailed;
    return fd;
}

fn sendConnection(connection: *wayring.Connection, fd: i32) !void {
    while (connection.nextBatch()) |batch| {
        if (batch.fds.len != 0) return error.UnexpectedFileDescriptor;
        const written = linux.sendto(fd, batch.bytes.ptr, batch.bytes.len, 0, null, 0);
        if (linux.errno(written) != .SUCCESS) return error.WriteFailed;
        try connection.acknowledge(batch.token, written);
    }
}

fn receiveConnection(connection: *wayring.Connection, fd: i32) !void {
    var buffer: [8192]u8 = undefined;
    const received = linux.recvfrom(fd, &buffer, buffer.len, 0, null, null);
    if (linux.errno(received) != .SUCCESS) return error.ReadFailed;
    if (received == 0) return error.UnexpectedEof;
    try connection.feed(buffer[0..received], &.{});
}
