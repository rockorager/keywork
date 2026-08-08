//! Scanner-resource security-context ingress adapter.
//!
//! Derives Wayring transports whose immutable provenance and peer credentials
//! are assigned before dispatch.

const WayringSecurityContext = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayland = @import("wayland");
const wayring = @import("wayring");
const WayringHost = @import("WayringHost.zig");

const linux = std.os.linux;
const server = wayring.server;
const wl = wayland.server.wl;

const ManagerProtocol = protocol.wp_security_context_manager_v1;
const ContextProtocol = protocol.wp_security_context_v1;

pub const Metadata = struct {
    sandbox_engine: ?[]const u8,
    app_id: ?[]const u8,
    instance_id: ?[]const u8,
};

const OwnedMetadata = struct {
    sandbox_engine: ?[]u8 = null,
    app_id: ?[]u8 = null,
    instance_id: ?[]u8 = null,

    fn snapshot(self: *const OwnedMetadata) Metadata {
        return .{
            .sandbox_engine = self.sandbox_engine,
            .app_id = self.app_id,
            .instance_id = self.instance_id,
        };
    }

    fn clone(self: *const OwnedMetadata, allocator: std.mem.Allocator) !OwnedMetadata {
        var result: OwnedMetadata = .{};
        errdefer result.deinit(allocator);
        if (self.sandbox_engine) |value| result.sandbox_engine = try allocator.dupe(u8, value);
        if (self.app_id) |value| result.app_id = try allocator.dupe(u8, value);
        if (self.instance_id) |value| result.instance_id = try allocator.dupe(u8, value);
        return result;
    }

    fn deinit(self: *OwnedMetadata, allocator: std.mem.Allocator) void {
        if (self.sandbox_engine) |value| allocator.free(value);
        if (self.app_id) |value| allocator.free(value);
        if (self.instance_id) |value| allocator.free(value);
        self.* = .{};
    }
};

const Manager = struct {
    owner: *WayringSecurityContext,
    client: *server.Client,
    resource: ManagerProtocol.Resource,
};

const Context = struct {
    owner: *WayringSecurityContext,
    client: *server.Client,
    resource: ?ContextProtocol.Resource,
    listen_fd: ?linux.fd_t,
    close_fd: ?linux.fd_t,
    close_source: ?*wl.EventSource = null,
    host: ?*WayringHost = null,
    metadata: OwnedMetadata = .{},
    committed: bool = false,
    active: bool = true,
};

const DerivedClient = struct {
    owner: *WayringSecurityContext,
    client: *server.Client,
    metadata: OwnedMetadata,
};

allocator: std.mem.Allocator,
event_loop: *wl.EventLoop,
protocol_server: *server.Server,
authorized_uid: linux.uid_t,
lifecycle: WayringHost.ClientLifecycle,
global: ?*const server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
contexts: std.ArrayList(*Context) = .empty,
derived_clients: std.ArrayList(*DerivedClient) = .empty,

pub fn init(
    self: *WayringSecurityContext,
    allocator: std.mem.Allocator,
    event_loop: *wl.EventLoop,
    protocol_server: *server.Server,
    authorized_uid: linux.uid_t,
    lifecycle: WayringHost.ClientLifecycle,
) void {
    self.* = .{
        .allocator = allocator,
        .event_loop = event_loop,
        .protocol_server = protocol_server,
        .authorized_uid = authorized_uid,
        .lifecycle = lifecycle,
    };
}

pub fn publish(self: *WayringSecurityContext) !void {
    std.debug.assert(self.global == null);
    self.global = try self.protocol_server.addGlobalWithOptions(
        ManagerProtocol,
        1,
        WayringSecurityContext,
        self,
        bind,
        .{ .visibility = .restricted },
    );
}

pub fn unpublish(self: *WayringSecurityContext) void {
    const global = self.global orelse return;
    self.protocol_server.removeGlobal(global) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}

/// Stops every derived listener and drains its clients while the shared
/// protocol adapters referenced by the lifecycle callbacks are still live.
pub fn shutdownIngress(self: *WayringSecurityContext) void {
    var index = self.contexts.items.len;
    while (index != 0) {
        index -= 1;
        self.deactivate(self.contexts.items[index]);
    }
    std.debug.assert(self.derived_clients.items.len == 0);
}

/// Submits externally queued events for every live derived transport.
pub fn flushIngress(self: *WayringSecurityContext) !void {
    for (self.contexts.items) |value| if (value.host) |host| try host.flush();
}

/// Deactivates ingress before releasing manager/filter dependencies.
pub fn deinit(self: *WayringSecurityContext) void {
    self.shutdownIngress();
    while (self.contexts.items.len != 0) {
        const value = self.contexts.items[self.contexts.items.len - 1];
        const resource_live = value.resource != null;
        if (resource_live) self.destroyContextResource(value);
    }
    while (self.managers.items.len != 0) self.destroyManager(self.managers.items[self.managers.items.len - 1]);
    self.unpublish();
    self.derived_clients.deinit(self.allocator);
    self.contexts.deinit(self.allocator);
    self.managers.deinit(self.allocator);
    self.* = undefined;
}

pub fn globalFilter(self: *const WayringSecurityContext, client: *const server.Client, global: *const server.Server.Global) bool {
    if (global == self.global) return client.isAuthorizedDirectPeer(self.authorized_uid);
    return switch (global.visibility()) {
        .public => true,
        .restricted => client.isAuthorizedDirectPeer(self.authorized_uid),
        .private => false,
    };
}

pub fn metadataForClient(self: *const WayringSecurityContext, client: *const server.Client) ?Metadata {
    for (self.derived_clients.items) |value| if (value.client == client) return value.metadata.snapshot();
    return null;
}

fn bind(client: *server.Client, id: u32, version: u32, self: *WayringSecurityContext) !void {
    if (version != 1) return error.InvalidVersion;
    if (client.transportProvenance() == .security_context) {
        const manager = try self.createManager(client, id, version);
        client.postProtocolError(
            &manager.resource.runtime,
            @intCast(ManagerProtocol.@"error".nested),
            "nested security contexts are forbidden",
        );
        return;
    }
    if (!client.isAuthorizedDirectPeer(self.authorized_uid)) return error.Unauthorized;
    _ = try self.createManager(client, id, version);
}

fn createManager(self: *WayringSecurityContext, client: *server.Client, id: u32, version: u32) !*Manager {
    try self.managers.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Manager);
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
    try value.resource.setHandler(Manager, value, managerRequest, null);
    try client.materialize(&value.resource.runtime);
    self.managers.appendAssumeCapacity(value);
    return value;
}

fn managerRequest(_: *ManagerProtocol.Resource, request: ManagerProtocol.Request, manager: *Manager) !void {
    switch (request) {
        .destroy => manager.owner.destroyManager(manager),
        .create_listener => |args| {
            if (!manager.client.isAuthorizedDirectPeer(manager.owner.authorized_uid)) {
                closeFd(args.listen_fd);
                closeFd(args.close_fd);
                return error.Unauthorized;
            }
            manager.owner.createContext(manager, args.id, args.listen_fd, args.close_fd);
        },
    }
}

fn createContext(
    self: *WayringSecurityContext,
    manager: *Manager,
    id: u32,
    listen_fd: linux.fd_t,
    close_fd: linux.fd_t,
) void {
    var listen_owned = true;
    defer if (listen_owned) closeFd(listen_fd);
    var close_owned = true;
    defer if (close_owned) closeFd(close_fd);
    if (!validListener(listen_fd) or !setDescriptorFlags(listen_fd) or !setDescriptorFlags(close_fd)) {
        manager.client.postProtocolError(
            &manager.resource.runtime,
            @intCast(ManagerProtocol.@"error".invalid_listen_fd),
            "listen_fd is not a listening socket",
        );
        return;
    }
    self.contexts.ensureUnusedCapacity(self.allocator, 1) catch {
        manager.client.postOutOfMemory(&manager.resource.runtime, "allocating security context");
        return;
    };
    const value = self.allocator.create(Context) catch {
        manager.client.postOutOfMemory(&manager.resource.runtime, "allocating security context");
        return;
    };
    value.* = .{
        .owner = self,
        .client = manager.client,
        .resource = ContextProtocol.Resource.init(self.allocator, id, 1, .client, manager.client.ownerHooks()),
        .listen_fd = listen_fd,
        .close_fd = close_fd,
    };
    const resource = &value.resource.?;
    resource.setHandler(Context, value, contextRequest, null) catch {
        resource.destroy();
        resource.deinit();
        self.allocator.destroy(value);
        manager.client.postOutOfMemory(&manager.resource.runtime, "installing security context handler");
        return;
    };
    manager.client.materialize(&resource.runtime) catch {
        resource.destroy();
        resource.deinit();
        self.allocator.destroy(value);
        manager.client.postOutOfMemory(&manager.resource.runtime, "materializing security context");
        return;
    };
    self.contexts.appendAssumeCapacity(value);
    listen_owned = false;
    close_owned = false;
}

fn contextRequest(resource: *ContextProtocol.Resource, request: ContextProtocol.Request, value: *Context) !void {
    if (request == .destroy) {
        value.owner.destroyContextResource(value);
        return;
    }
    if (value.committed) {
        value.client.postProtocolError(
            &resource.runtime,
            @intCast(ContextProtocol.@"error".already_used),
            "security context is already committed",
        );
        return;
    }
    switch (request) {
        .destroy => unreachable,
        .set_sandbox_engine => |args| setMetadata(value, resource, &value.metadata.sandbox_engine, args.name),
        .set_app_id => |args| setMetadata(value, resource, &value.metadata.app_id, args.app_id),
        .set_instance_id => |args| setMetadata(value, resource, &value.metadata.instance_id, args.instance_id),
        .commit => commit(value, resource),
    }
}

fn setMetadata(value: *Context, resource: *ContextProtocol.Resource, destination: *?[]u8, source: []const u8) void {
    if (destination.* != null) {
        value.client.postProtocolError(
            &resource.runtime,
            @intCast(ContextProtocol.@"error".already_set),
            "security context metadata is already set",
        );
        return;
    }
    destination.* = value.owner.allocator.dupe(u8, source) catch {
        value.client.postOutOfMemory(&resource.runtime, "copying security context metadata");
        return;
    };
}

fn commit(value: *Context, resource: *ContextProtocol.Resource) void {
    const self = value.owner;
    const listen_fd = value.listen_fd.?;
    const host = WayringHost.createFromListenerFd(
        self.allocator,
        self.event_loop,
        self.protocol_server,
        listen_fd,
        .{
            .context = value,
            .accepted = derivedAccepted,
            .destroy_resources = derivedDestroy,
        },
    ) catch |err| {
        if (err == error.OutOfMemory) value.client.postOutOfMemory(&resource.runtime, "creating security-context host") else value.client.postImplementationError(&resource.runtime, "creating security-context host");
        return;
    };
    value.listen_fd = null;
    const source = self.event_loop.addFd(
        *Context,
        value.close_fd.?,
        .{ .hangup = true, .@"error" = true },
        closeEvent,
        value,
    ) catch {
        host.destroy() catch {};
        value.client.postOutOfMemory(&resource.runtime, "watching security-context close descriptor");
        return;
    };
    value.host = host;
    value.close_source = source;
    value.committed = true;
}

fn derivedAccepted(erased: *anyopaque, client: *server.Client) !void {
    const context: *Context = @ptrCast(@alignCast(erased));
    const self = context.owner;
    std.debug.assert(client.transportProvenance() == .security_context);
    try self.derived_clients.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(DerivedClient);
    errdefer self.allocator.destroy(value);
    value.* = .{
        .owner = self,
        .client = client,
        .metadata = try context.metadata.clone(self.allocator),
    };
    errdefer value.metadata.deinit(self.allocator);
    self.derived_clients.appendAssumeCapacity(value);
    self.lifecycle.accepted(self.lifecycle.context, client) catch |err| {
        _ = self.derived_clients.pop();
        return err;
    };
}

fn derivedDestroy(erased: *anyopaque, client: *server.Client) void {
    const context: *Context = @ptrCast(@alignCast(erased));
    const self = context.owner;
    self.lifecycle.destroy_resources(self.lifecycle.context, client);
    for (self.derived_clients.items, 0..) |value, index| {
        if (value.client != client) continue;
        _ = self.derived_clients.orderedRemove(index);
        value.metadata.deinit(self.allocator);
        self.allocator.destroy(value);
        return;
    }
}

fn destroyContextResource(self: *WayringSecurityContext, value: *Context) void {
    if (value.resource) |*resource| {
        resource.destroy();
        resource.deinit();
        value.resource = null;
    }
    if (!value.committed) self.deactivate(value) else if (!value.active) self.destroyContext(value);
}

fn closeEvent(_: c_int, mask: wl.EventMask, value: *Context) c_int {
    if (mask.hangup or mask.@"error") value.owner.deactivate(value);
    return 0;
}

fn deactivate(self: *WayringSecurityContext, value: *Context) void {
    if (!value.active) return;
    value.active = false;
    if (value.close_source) |source| source.remove();
    value.close_source = null;
    if (value.host) |host| host.destroy() catch {};
    value.host = null;
    if (value.listen_fd) |fd| closeFd(fd);
    value.listen_fd = null;
    if (value.close_fd) |fd| closeFd(fd);
    value.close_fd = null;
    value.metadata.deinit(self.allocator);
    if (value.resource == null) self.destroyContext(value);
}

fn destroyContext(self: *WayringSecurityContext, value: *Context) void {
    std.debug.assert(!value.active and value.resource == null and value.host == null);
    remove(Context, &self.contexts, value);
    self.allocator.destroy(value);
}

fn destroyManager(self: *WayringSecurityContext, value: *Manager) void {
    remove(Manager, &self.managers, value);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}

pub fn destroyClientResources(self: *WayringSecurityContext, client: *server.Client) void {
    var index = self.contexts.items.len;
    while (index != 0) {
        index -= 1;
        const value = self.contexts.items[index];
        if (value.client == client) self.destroyContextResource(value);
    }
    index = self.managers.items.len;
    while (index != 0) {
        index -= 1;
        const value = self.managers.items[index];
        if (value.client == client) self.destroyManager(value);
    }
}

fn validListener(fd: linux.fd_t) bool {
    var accepting: c_int = 0;
    var length: linux.socklen_t = @sizeOf(c_int);
    const result = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.ACCEPTCONN, @ptrCast(&accepting), &length);
    return linux.errno(result) == .SUCCESS and length == @sizeOf(c_int) and accepting != 0;
}

fn setDescriptorFlags(fd: linux.fd_t) bool {
    const status_result = linux.fcntl(fd, linux.F.GETFL, 0);
    if (linux.errno(status_result) != .SUCCESS) return false;
    var status: linux.O = @bitCast(@as(u32, @intCast(status_result)));
    status.NONBLOCK = true;
    if (linux.errno(linux.fcntl(fd, linux.F.SETFL, @as(u32, @bitCast(status)))) != .SUCCESS) return false;
    const descriptor_result = linux.fcntl(fd, linux.F.GETFD, 0);
    if (linux.errno(descriptor_result) != .SUCCESS) return false;
    return linux.errno(linux.fcntl(fd, linux.F.SETFD, descriptor_result | linux.FD_CLOEXEC)) == .SUCCESS;
}

fn closeFd(fd: linux.fd_t) void {
    _ = linux.close(fd);
}

fn remove(comptime T: type, list: *std.ArrayList(*T), value: *T) void {
    for (list.items, 0..) |candidate, index| if (candidate == value) {
        _ = list.orderedRemove(index);
        return;
    };
    unreachable;
}

test "generated security-context protocol pins exact version descriptors destructors and errors" {
    try std.testing.expectEqual(@as(u32, 1), ManagerProtocol.interface.version);
    try std.testing.expectEqualStrings("wp_security_context_manager_v1", ManagerProtocol.interface.name);
    try std.testing.expectEqual(@as(usize, 2), ManagerProtocol.request_messages.len);
    try std.testing.expectEqualStrings("destroy", ManagerProtocol.request_messages[0].name);
    try std.testing.expect(ManagerProtocol.request_messages[0].destructor);
    try std.testing.expectEqualStrings("create_listener", ManagerProtocol.request_messages[1].name);
    try std.testing.expect(!ManagerProtocol.request_messages[1].destructor);
    try std.testing.expectEqual(@as(usize, 3), ManagerProtocol.request_messages[1].arguments.len);
    try std.testing.expectEqual(@as(i64, 1), ManagerProtocol.@"error".invalid_listen_fd);
    try std.testing.expectEqual(@as(i64, 2), ManagerProtocol.@"error".nested);
    try std.testing.expectEqual(@as(usize, 0), ManagerProtocol.event_messages.len);

    try std.testing.expectEqual(@as(u32, 1), ContextProtocol.interface.version);
    try std.testing.expectEqual(@as(usize, 5), ContextProtocol.request_messages.len);
    try std.testing.expectEqualStrings("destroy", ContextProtocol.request_messages[0].name);
    try std.testing.expect(ContextProtocol.request_messages[0].destructor);
    try std.testing.expectEqualStrings("set_sandbox_engine", ContextProtocol.request_messages[1].name);
    try std.testing.expectEqualStrings("set_app_id", ContextProtocol.request_messages[2].name);
    try std.testing.expectEqualStrings("set_instance_id", ContextProtocol.request_messages[3].name);
    try std.testing.expectEqualStrings("commit", ContextProtocol.request_messages[4].name);
    for (ContextProtocol.request_messages[1..]) |request| try std.testing.expect(!request.destructor);
    try std.testing.expectEqual(@as(i64, 1), ContextProtocol.@"error".already_used);
    try std.testing.expectEqual(@as(i64, 2), ContextProtocol.@"error".already_set);
    try std.testing.expectEqual(@as(i64, 3), ContextProtocol.@"error".invalid_metadata);
    try std.testing.expectEqual(@as(usize, 0), ContextProtocol.event_messages.len);
}

test "listener validation and required descriptor flags are exact" {
    var pair: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &pair)));
    defer closeFd(pair[0]);
    defer closeFd(pair[1]);
    try std.testing.expect(!validListener(pair[0]));

    const raw = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(raw));
    const listener: linux.fd_t = @intCast(raw);
    defer closeFd(listener);
    var address: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = @splat(0) };
    const name = "keywork-security-context-flags";
    address.path[0] = 0;
    @memcpy(address.path[1 .. name.len + 1], name);
    const length: linux.socklen_t = @intCast(@offsetOf(linux.sockaddr.un, "path") + 1 + name.len);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.bind(listener, @ptrCast(&address), length)));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.listen(listener, 4)));
    try std.testing.expect(validListener(listener));
    try std.testing.expect(setDescriptorFlags(listener));
    const status: linux.O = @bitCast(@as(u32, @intCast(linux.fcntl(listener, linux.F.GETFL, 0))));
    try std.testing.expect(status.NONBLOCK);
    try std.testing.expect((linux.fcntl(listener, linux.F.GETFD, 0) & linux.FD_CLOEXEC) != 0);
}

test "metadata cloning is immutable and independent" {
    var source: OwnedMetadata = .{
        .sandbox_engine = try std.testing.allocator.dupe(u8, "bubblewrap"),
        .app_id = try std.testing.allocator.dupe(u8, "org.example.App"),
        .instance_id = try std.testing.allocator.dupe(u8, "instance-a"),
    };
    defer source.deinit(std.testing.allocator);
    var copy = try source.clone(std.testing.allocator);
    defer copy.deinit(std.testing.allocator);
    source.app_id.?[0] = 'X';
    try std.testing.expectEqualStrings("org.example.App", copy.app_id.?);
    try std.testing.expect(copy.app_id.?.ptr != source.app_id.?.ptr);
}

test "metadata is set once and every post-commit mutation uses exact protocol errors" {
    const Case = struct {
        committed: bool,
        expected_code: u32,

        fn run(case: @This()) !void {
            var client: server.Client = .init(std.testing.allocator, .{});
            defer client.deinit();
            var adapter: WayringSecurityContext = undefined;
            adapter.allocator = std.testing.allocator;
            var value: Context = .{
                .owner = &adapter,
                .client = &client,
                .resource = null,
                .listen_fd = null,
                .close_fd = null,
                .committed = case.committed,
            };
            defer value.metadata.deinit(std.testing.allocator);
            var resource: ContextProtocol.Resource = .init(
                std.testing.allocator,
                2,
                1,
                .client,
                client.ownerHooks(),
            );
            try client.installClientInitial(2, &resource.runtime);
            defer {
                resource.destroy();
                resource.deinit();
            }
            if (!case.committed) {
                try contextRequest(&resource, .{ .set_app_id = .{ .app_id = "first" } }, &value);
                try std.testing.expectEqualStrings("first", value.metadata.app_id.?);
            }
            try contextRequest(&resource, .{ .set_app_id = .{ .app_id = "second" } }, &value);
            const fatal = client.fatal().?;
            try std.testing.expectEqual(server.Fatal.Kind.protocol, fatal.kind);
            try std.testing.expectEqual(case.expected_code, fatal.protocol_code.?);
            try std.testing.expectEqual(@as(u32, 2), fatal.object_id);
        }
    };
    try (Case{ .committed = false, .expected_code = @intCast(ContextProtocol.@"error".already_set) }).run();
    try (Case{ .committed = true, .expected_code = @intCast(ContextProtocol.@"error".already_used) }).run();
}

test "fixture filter exposes manager only to the exact direct compositor UID" {
    const event_loop = try wl.EventLoop.create();
    defer event_loop.destroy();
    var protocol_server: server.Server = .init(std.testing.allocator);
    defer protocol_server.deinit();
    const Lifecycle = struct {
        fn accepted(_: *anyopaque, _: *server.Client) !void {}
        fn destroy(_: *anyopaque, _: *server.Client) void {}
    };
    var marker: u8 = 0;
    var adapter: WayringSecurityContext = undefined;
    adapter.init(std.testing.allocator, event_loop, &protocol_server, 42, .{
        .context = &marker,
        .accepted = Lifecycle.accepted,
        .destroy_resources = Lifecycle.destroy,
    });
    defer adapter.deinit();
    try adapter.publish();

    const credentials: server.Client.Credentials = .{ .pid = 1, .uid = 42, .gid = 2 };
    var direct: server.Client = .init(std.testing.allocator, .{ .credentials = credentials, .transport_provenance = .direct });
    defer direct.deinit();
    var derived: server.Client = .init(std.testing.allocator, .{ .credentials = credentials, .transport_provenance = .security_context });
    defer derived.deinit();
    var foreign: server.Client = .init(std.testing.allocator, .{ .credentials = .{ .pid = 1, .uid = 41, .gid = 2 }, .transport_provenance = .direct });
    defer foreign.deinit();
    var unknown: server.Client = .init(std.testing.allocator, .{ .credentials = credentials });
    defer unknown.deinit();
    var missing: server.Client = .init(std.testing.allocator, .{ .transport_provenance = .direct });
    defer missing.deinit();

    const global = adapter.global.?;
    try std.testing.expect(adapter.globalFilter(&direct, global));
    inline for (.{ &derived, &foreign, &unknown, &missing }) |client|
        try std.testing.expect(!adapter.globalFilter(client, global));
}

test "shutdown ingress drains multiple resource-less contexts in reverse" {
    const event_loop = try wl.EventLoop.create();
    defer event_loop.destroy();
    var protocol_server: server.Server = .init(std.testing.allocator);
    defer protocol_server.deinit();
    const Lifecycle = struct {
        fn accepted(_: *anyopaque, _: *server.Client) !void {}
        fn destroy(_: *anyopaque, _: *server.Client) void {}
    };
    var marker: u8 = 0;
    var adapter: WayringSecurityContext = undefined;
    adapter.init(std.testing.allocator, event_loop, &protocol_server, linux.getuid(), .{
        .context = &marker,
        .accepted = Lifecycle.accepted,
        .destroy_resources = Lifecycle.destroy,
    });
    defer adapter.deinit();
    var client: server.Client = .init(std.testing.allocator, .{});
    defer client.deinit();

    for (0..3) |_| {
        const value = try std.testing.allocator.create(Context);
        value.* = .{
            .owner = &adapter,
            .client = &client,
            .resource = null,
            .listen_fd = null,
            .close_fd = null,
            .committed = true,
        };
        try adapter.contexts.append(std.testing.allocator, value);
    }
    adapter.shutdownIngress();
    try std.testing.expectEqual(@as(usize, 0), adapter.contexts.items.len);
}

const FixtureClient = struct {
    const Status = enum(u8) { running, ready, success, failed };

    direct_path: [:0]const u8,
    derived_name: []const u8,
    status: std.atomic.Value(u8) = .init(@intFromEnum(Status.running)),
    close_signal: std.atomic.Value(bool) = .init(false),
    manager: ?*wayland.client.wp.SecurityContextManagerV1 = null,

    fn run(self: *FixtureClient) void {
        self.runFallible() catch {
            self.status.store(@intFromEnum(Status.failed), .release);
            return;
        };
        self.status.store(@intFromEnum(Status.success), .release);
    }

    fn runFallible(self: *FixtureClient) !void {
        const direct_fd = try connectPath(self.direct_path);
        var direct_owned = true;
        defer if (direct_owned) closeFd(direct_fd);
        const display = try wayland.client.wl.Display.connectToFd(direct_fd);
        direct_owned = false;
        defer display.disconnect();
        const registry = try display.getRegistry();
        defer registry.destroy();
        registry.setListener(*FixtureClient, registryEvent, self);
        if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
        const manager = self.manager orelse return error.ManagerMissing;

        const listener_fd = try createAbstractListener(self.derived_name);
        defer closeFd(listener_fd);
        var close_pipe: [2]linux.fd_t = undefined;
        if (linux.errno(linux.pipe2(&close_pipe, .{ .CLOEXEC = true })) != .SUCCESS)
            return error.PipeFailed;
        defer closeFd(close_pipe[0]);
        defer closeFd(close_pipe[1]);
        const context = try manager.createListener(listener_fd, close_pipe[0]);
        context.setSandboxEngine("org.keywork.fixture");
        context.setAppId("dev.rockorager.fixture");
        context.setInstanceId("fixture-1");
        context.commit();
        // The committed listener and copied metadata outlive this resource.
        context.destroy();
        if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
        self.status.store(@intFromEnum(Status.ready), .release);
        const pause: linux.timespec = .{ .sec = 0, .nsec = std.time.ns_per_ms };
        while (!self.close_signal.load(.acquire)) _ = linux.nanosleep(&pause, null);
        closeFd(close_pipe[1]);
        close_pipe[1] = -1;
    }

    fn registryEvent(
        registry: *wayland.client.wl.Registry,
        event: wayland.client.wl.Registry.Event,
        self: *FixtureClient,
    ) void {
        switch (event) {
            .global => |global| {
                if (!std.mem.eql(u8, std.mem.span(global.interface), ManagerProtocol.interface.name) or self.manager != null) return;
                self.manager = registry.bind(
                    global.name,
                    wayland.client.wp.SecurityContextManagerV1,
                    @min(global.version, 1),
                ) catch null;
            },
            .global_remove => {},
        }
    }
};

fn connectPath(path: [:0]const u8) !linux.fd_t {
    var address: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = @splat(0) };
    if (path.len >= address.path.len) return error.InvalidSocketPath;
    @memcpy(address.path[0..path.len], path);
    const raw = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(raw) != .SUCCESS) return error.SocketFailed;
    const fd: linux.fd_t = @intCast(raw);
    errdefer closeFd(fd);
    const length: linux.socklen_t = @intCast(@offsetOf(linux.sockaddr.un, "path") + path.len + 1);
    if (linux.errno(linux.connect(fd, @ptrCast(&address), length)) != .SUCCESS) return error.ConnectFailed;
    return fd;
}

fn createAbstractListener(name: []const u8) !linux.fd_t {
    var address: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = @splat(0) };
    if (name.len + 1 > address.path.len) return error.InvalidSocketPath;
    @memcpy(address.path[1 .. name.len + 1], name);
    const raw = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(raw) != .SUCCESS) return error.SocketFailed;
    const fd: linux.fd_t = @intCast(raw);
    errdefer closeFd(fd);
    const length: linux.socklen_t = @intCast(@offsetOf(linux.sockaddr.un, "path") + name.len + 1);
    if (linux.errno(linux.bind(fd, @ptrCast(&address), length)) != .SUCCESS) return error.BindFailed;
    if (linux.errno(linux.listen(fd, 8)) != .SUCCESS) return error.ListenFailed;
    return fd;
}

fn connectAbstract(name: []const u8) !linux.fd_t {
    var address: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = @splat(0) };
    if (name.len + 1 > address.path.len) return error.InvalidSocketPath;
    @memcpy(address.path[1 .. name.len + 1], name);
    const raw = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(raw) != .SUCCESS) return error.SocketFailed;
    const fd: linux.fd_t = @intCast(raw);
    errdefer closeFd(fd);
    const length: linux.socklen_t = @intCast(@offsetOf(linux.sockaddr.un, "path") + name.len + 1);
    if (linux.errno(linux.connect(fd, @ptrCast(&address), length)) != .SUCCESS) return error.ConnectFailed;
    return fd;
}

test "committed fixture derives a libwayland client with copied metadata and close-fd shutdown" {
    var marker: u8 = 0;
    const runtime_directory = try std.fmt.allocPrintSentinel(
        std.testing.allocator,
        "/tmp/keywork-security-context-{d}-{x}",
        .{ linux.getpid(), @intFromPtr(&marker) },
        0,
    );
    defer std.testing.allocator.free(runtime_directory);
    if (linux.errno(linux.mkdir(runtime_directory.ptr, 0o700)) != .SUCCESS)
        return error.TestDirectoryCreationFailed;
    defer _ = linux.rmdir(runtime_directory.ptr);

    const event_loop = try wl.EventLoop.create();
    defer event_loop.destroy();
    var protocol_server: server.Server = .init(std.testing.allocator);
    defer protocol_server.deinit();
    const Probe = struct {
        adapter: *WayringSecurityContext,
        derived_accepted: usize = 0,
        derived_destroyed: usize = 0,
        metadata_valid: bool = false,
        identity_valid: bool = false,
        before_receive: bool = false,

        fn accepted(erased: *anyopaque, client: *server.Client) !void {
            const self: *@This() = @ptrCast(@alignCast(erased));
            if (client.transportProvenance() != .security_context) return;
            self.derived_accepted += 1;
            const metadata = self.adapter.metadataForClient(client) orelse return error.MetadataMissing;
            self.metadata_valid = std.mem.eql(u8, metadata.sandbox_engine.?, "org.keywork.fixture") and
                std.mem.eql(u8, metadata.app_id.?, "dev.rockorager.fixture") and
                std.mem.eql(u8, metadata.instance_id.?, "fixture-1");
            const identity = client.securityIdentity();
            self.identity_valid = identity.provenance == .security_context and
                identity.credentials != null and identity.credentials.?.uid == linux.getuid();
            self.before_receive = client.lookup(2) == null;
        }

        fn destroy(erased: *anyopaque, client: *server.Client) void {
            const self: *@This() = @ptrCast(@alignCast(erased));
            if (client.transportProvenance() == .direct) {
                self.adapter.destroyClientResources(client);
            } else {
                self.derived_destroyed += 1;
            }
        }
    };
    var adapter: WayringSecurityContext = undefined;
    var probe: Probe = .{ .adapter = &adapter };
    adapter.init(std.testing.allocator, event_loop, &protocol_server, linux.getuid(), .{
        .context = &probe,
        .accepted = Probe.accepted,
        .destroy_resources = Probe.destroy,
    });
    defer adapter.deinit();
    try adapter.publish();
    protocol_server.setGlobalFilter(WayringSecurityContext, &adapter, WayringSecurityContext.globalFilter);
    defer protocol_server.clearGlobalFilter();
    const direct_host = try WayringHost.create(
        std.testing.allocator,
        event_loop,
        &protocol_server,
        runtime_directory,
        .{ .context = &probe, .accepted = Probe.accepted, .destroy_resources = Probe.destroy },
    );
    var direct_live = true;
    defer if (direct_live) direct_host.destroy() catch {};
    const direct_path = try std.fmt.allocPrintSentinel(
        std.testing.allocator,
        "{s}/{s}",
        .{ runtime_directory, direct_host.displayName() },
        0,
    );
    defer std.testing.allocator.free(direct_path);
    const derived_name = try std.fmt.allocPrint(
        std.testing.allocator,
        "keywork-security-derived-{d}-{x}",
        .{ linux.getpid(), @intFromPtr(&probe) },
    );
    defer std.testing.allocator.free(derived_name);
    var fixture_client: FixtureClient = .{ .direct_path = direct_path, .derived_name = derived_name };
    const thread = try std.Thread.spawn(.{}, FixtureClient.run, .{&fixture_client});
    var thread_live = true;
    defer if (thread_live) {
        fixture_client.close_signal.store(true, .release);
        thread.join();
    };
    for (0..400) |_| {
        try event_loop.dispatch(10);
        const status: FixtureClient.Status = @enumFromInt(fixture_client.status.load(.acquire));
        if (status == .ready or status == .failed) break;
    }
    try std.testing.expectEqual(FixtureClient.Status.ready, @as(FixtureClient.Status, @enumFromInt(fixture_client.status.load(.acquire))));
    try std.testing.expectEqual(@as(usize, 1), adapter.contexts.items.len);
    try std.testing.expect(adapter.contexts.items[0].resource == null);

    const peer_fd = try connectAbstract(derived_name);
    var peer_owned = true;
    defer if (peer_owned) closeFd(peer_fd);
    const derived_display = try wayland.client.wl.Display.connectToFd(peer_fd);
    peer_owned = false;
    defer derived_display.disconnect();
    for (0..400) |_| {
        try event_loop.dispatch(10);
        if (probe.derived_accepted != 0) break;
    }
    try std.testing.expectEqual(@as(usize, 1), probe.derived_accepted);
    try std.testing.expect(probe.metadata_valid);
    try std.testing.expect(probe.identity_valid);
    try std.testing.expect(probe.before_receive);

    fixture_client.close_signal.store(true, .release);
    for (0..400) |_| {
        try event_loop.dispatch(10);
        if (adapter.contexts.items.len == 0) break;
    }
    thread.join();
    thread_live = false;
    try std.testing.expectEqual(FixtureClient.Status.success, @as(FixtureClient.Status, @enumFromInt(fixture_client.status.load(.acquire))));
    try std.testing.expectEqual(@as(usize, 0), adapter.contexts.items.len);
    try std.testing.expectEqual(@as(usize, 0), adapter.derived_clients.items.len);
    try std.testing.expectEqual(@as(usize, 1), probe.derived_destroyed);
    try std.testing.expect(direct_host.failure() == null);

    direct_live = false;
    try direct_host.destroy();
}
