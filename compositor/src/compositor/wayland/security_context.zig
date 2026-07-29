//! Sandboxed Wayland client registration and immutable security metadata.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");

const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("netinet/in.h");
    @cInclude("sys/socket.h");
    @cInclude("unistd.h");
});
const wl = wayland.server.wl;
const wp = wayland.server.wp;
const log = std.log.scoped(.security_context);

allocator: std.mem.Allocator,
display: *wl.Server,
event_loop: *wl.EventLoop,
global: *wl.Global,
contexts: std.ArrayList(*Context),
clients: std.AutoHashMapUnmanaged(*const wl.Client, *ClientContext),
restricted_globals: std.ArrayList(*wl.Global),
private_globals: std.ArrayList(PrivateGlobal),

const PrivateGlobal = struct {
    global: *wl.Global,
    client: ?*const wl.Client,
};

pub const Metadata = struct {
    sandbox_engine: ?[:0]const u8,
    app_id: ?[:0]const u8,
    instance_id: ?[:0]const u8,
};

pub fn init(self: *Self, allocator: std.mem.Allocator, display: *wl.Server) !void {
    self.* = .{
        .allocator = allocator,
        .display = display,
        .event_loop = display.getEventLoop(),
        .global = try wl.Global.create(
            display,
            wp.SecurityContextManagerV1,
            1,
            *Self,
            self,
            bind,
        ),
        .contexts = .empty,
        .clients = .empty,
        .restricted_globals = .empty,
        .private_globals = .empty,
    };
    errdefer self.private_globals.deinit(allocator);
    errdefer self.restricted_globals.deinit(allocator);
    display.setGlobalFilter(*Self, globalFilter, self);
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.clients.count() == 0);
    while (self.contexts.items.len > 0) {
        const context = self.contexts.items[self.contexts.items.len - 1];
        std.debug.assert(context.resource == null);
        context.deactivate();
    }
    self.display.setGlobalFilter(*Self, allowAllGlobals, self);
    self.global.destroy();
    std.debug.assert(self.restricted_globals.items.len == 0);
    std.debug.assert(self.private_globals.items.len == 0);
    self.private_globals.deinit(self.allocator);
    self.restricted_globals.deinit(self.allocator);
    self.clients.deinit(self.allocator);
    self.contexts.deinit(self.allocator);
    self.* = undefined;
}

pub fn metadataForClient(self: *const Self, client: *const wl.Client) ?Metadata {
    const context = self.clients.get(client) orelse return null;
    return context.metadata();
}

pub fn restrictGlobal(self: *Self, global: *wl.Global) error{OutOfMemory}!void {
    for (self.restricted_globals.items) |candidate| std.debug.assert(candidate != global);
    try self.restricted_globals.append(self.allocator, global);
}

pub fn unrestrictGlobal(self: *Self, global: *wl.Global) void {
    for (self.restricted_globals.items, 0..) |candidate, index| {
        if (candidate != global) continue;
        _ = self.restricted_globals.orderedRemove(index);
        return;
    }
    unreachable;
}

/// Hide a global from every client until one client is explicitly authorized.
pub fn privatizeGlobal(self: *Self, global: *wl.Global) error{OutOfMemory}!void {
    for (self.private_globals.items) |entry| std.debug.assert(entry.global != global);
    try self.private_globals.append(self.allocator, .{ .global = global, .client = null });
}

pub fn authorizePrivateGlobal(
    self: *Self,
    global: *wl.Global,
    client: *const wl.Client,
) void {
    for (self.private_globals.items) |*entry| {
        if (entry.global != global) continue;
        std.debug.assert(entry.client == null);
        entry.client = client;
        return;
    }
    unreachable;
}

pub fn clearPrivateGlobalClient(self: *Self, global: *wl.Global) void {
    for (self.private_globals.items) |*entry| {
        if (entry.global != global) continue;
        std.debug.assert(entry.client != null);
        entry.client = null;
        return;
    }
    unreachable;
}

pub fn unprivatizeGlobal(self: *Self, global: *wl.Global) void {
    for (self.private_globals.items, 0..) |entry, index| {
        if (entry.global != global) continue;
        std.debug.assert(entry.client == null);
        _ = self.private_globals.orderedRemove(index);
        return;
    }
    unreachable;
}

fn globalFilter(client: *const wl.Client, global: *const wl.Global, self: *Self) bool {
    for (self.private_globals.items) |entry| {
        if (entry.global == global) return entry.client == client;
    }
    if (!self.clients.contains(client)) return true;
    if (global == self.global) return false;
    for (self.restricted_globals.items) |restricted| {
        if (global == restricted) return false;
    }
    return true;
}

fn allowAllGlobals(_: *const wl.Client, _: *const wl.Global, _: *Self) bool {
    return true;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    if (self.clients.contains(client)) {
        const resource = wp.SecurityContextManagerV1.create(client, version, id) catch {
            client.postNoMemory();
            return;
        };
        resource.postError(.nested, "nested security contexts are forbidden");
        return;
    }
    const resource = wp.SecurityContextManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleManagerRequest, null, self);
}

fn handleManagerRequest(
    resource: *wp.SecurityContextManagerV1,
    request: wp.SecurityContextManagerV1.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .create_listener => |create| self.createContext(
            resource,
            create.id,
            create.listen_fd,
            create.close_fd,
        ),
    }
}

fn createContext(
    self: *Self,
    manager_resource: *wp.SecurityContextManagerV1,
    id: u32,
    listen_fd: std.posix.fd_t,
    close_fd: std.posix.fd_t,
) void {
    if (!validListenFd(listen_fd) or !setNonblocking(listen_fd)) {
        _ = std.c.close(listen_fd);
        _ = std.c.close(close_fd);
        manager_resource.postError(.invalid_listen_fd, "listen_fd is not a listening socket");
        return;
    }
    const resource = wp.SecurityContextV1.create(
        manager_resource.getClient(),
        manager_resource.getVersion(),
        id,
    ) catch {
        _ = std.c.close(listen_fd);
        _ = std.c.close(close_fd);
        manager_resource.postNoMemory();
        return;
    };
    const context = self.allocator.create(Context) catch {
        _ = std.c.close(listen_fd);
        _ = std.c.close(close_fd);
        resource.postNoMemory();
        resource.destroy();
        return;
    };
    context.* = .{
        .manager = self,
        .resource = resource,
        .listen_fd = listen_fd,
        .close_fd = close_fd,
    };
    self.contexts.append(self.allocator, context) catch {
        self.allocator.destroy(context);
        _ = std.c.close(listen_fd);
        _ = std.c.close(close_fd);
        resource.postNoMemory();
        resource.destroy();
        return;
    };
    resource.setHandler(*Context, Context.handleRequest, Context.handleResourceDestroy, context);
}

fn validListenFd(fd: std.posix.fd_t) bool {
    var accepting: c_int = 0;
    var size: c.socklen_t = @sizeOf(c_int);
    return c.getsockopt(fd, c.SOL_SOCKET, c.SO_ACCEPTCONN, &accepting, &size) == 0 and
        accepting != 0;
}

fn setNonblocking(fd: std.posix.fd_t) bool {
    const flags = std.c.fcntl(fd, std.posix.F.GETFL);
    if (flags < 0) return false;
    var status: std.posix.O = @bitCast(@as(u32, @intCast(flags)));
    status.NONBLOCK = true;
    return std.c.fcntl(
        fd,
        std.posix.F.SETFL,
        @as(c_int, @intCast(@as(u32, @bitCast(status)))),
    ) == 0;
}

fn acceptClient(context: *Context) void {
    const fd = c.accept4(
        context.listen_fd,
        .{ .__sockaddr__ = null },
        null,
        c.SOCK_CLOEXEC,
    );
    if (fd < 0) {
        switch (std.posix.errno(fd)) {
            .AGAIN, .INTR, .CONNABORTED => {},
            else => log.warn("failed to accept sandboxed Wayland client", .{}),
        }
        return;
    }
    var close_fd = true;
    defer if (close_fd) {
        _ = std.c.close(fd);
    };

    context.manager.clients.ensureUnusedCapacity(context.manager.allocator, 1) catch {
        log.err("failed to reserve sandbox client metadata", .{});
        return;
    };
    const client_context = context.manager.allocator.create(ClientContext) catch {
        log.err("failed to allocate sandbox client metadata", .{});
        return;
    };
    client_context.* = .{
        .manager = context.manager,
        .client = undefined,
        .sandbox_engine = duplicateOptional(
            context.manager.allocator,
            context.sandbox_engine,
        ) catch {
            context.manager.allocator.destroy(client_context);
            log.err("failed to copy sandbox engine metadata", .{});
            return;
        },
        .app_id = null,
        .instance_id = null,
        .destroy_listener = wl.Listener(*wl.Client).init(ClientContext.handleClientDestroyed),
    };
    client_context.app_id = duplicateOptional(
        context.manager.allocator,
        context.app_id,
    ) catch {
        client_context.deinitMetadata();
        context.manager.allocator.destroy(client_context);
        log.err("failed to copy sandbox application metadata", .{});
        return;
    };
    client_context.instance_id = duplicateOptional(
        context.manager.allocator,
        context.instance_id,
    ) catch {
        client_context.deinitMetadata();
        context.manager.allocator.destroy(client_context);
        log.err("failed to copy sandbox instance metadata", .{});
        return;
    };

    const client = wl.Client.create(context.manager.display, fd) orelse {
        client_context.deinitMetadata();
        context.manager.allocator.destroy(client_context);
        log.err("failed to create sandboxed Wayland client", .{});
        return;
    };
    close_fd = false;
    client_context.client = client;
    client.addDestroyListener(&client_context.destroy_listener);
    context.manager.clients.putAssumeCapacityNoClobber(client, client_context);
}

fn duplicateOptional(
    allocator: std.mem.Allocator,
    value: ?[:0]const u8,
) error{OutOfMemory}!?[:0]u8 {
    const source = value orelse return null;
    return try allocator.dupeSentinel(u8, source, 0);
}

const Context = struct {
    manager: *Self,
    resource: ?*wp.SecurityContextV1,
    listen_fd: std.posix.fd_t,
    close_fd: std.posix.fd_t,
    listen_source: ?*wl.EventSource = null,
    close_source: ?*wl.EventSource = null,
    sandbox_engine: ?[:0]u8 = null,
    app_id: ?[:0]u8 = null,
    instance_id: ?[:0]u8 = null,
    committed: bool = false,
    active: bool = true,

    fn handleRequest(
        resource: *wp.SecurityContextV1,
        request: wp.SecurityContextV1.Request,
        self: *Context,
    ) void {
        if (request == .destroy) {
            resource.destroy();
            return;
        }
        if (self.committed) {
            resource.postError(.already_used, "security context is already committed");
            return;
        }
        switch (request) {
            .destroy => unreachable,
            .set_sandbox_engine => |set| self.setMetadata(
                resource,
                &self.sandbox_engine,
                set.name,
            ),
            .set_app_id => |set| self.setMetadata(resource, &self.app_id, set.app_id),
            .set_instance_id => |set| self.setMetadata(
                resource,
                &self.instance_id,
                set.instance_id,
            ),
            .commit => self.commit(resource),
        }
    }

    fn setMetadata(
        self: *Context,
        resource: *wp.SecurityContextV1,
        destination: *?[:0]u8,
        value: [*:0]const u8,
    ) void {
        if (destination.* != null) {
            resource.postError(.already_set, "security context metadata is already set");
            return;
        }
        destination.* = self.manager.allocator.dupeSentinel(u8, std.mem.span(value), 0) catch {
            resource.postNoMemory();
            return;
        };
    }

    fn commit(self: *Context, resource: *wp.SecurityContextV1) void {
        self.listen_source = self.manager.event_loop.addFd(
            *Context,
            self.listen_fd,
            .{ .readable = true },
            handleListenEvent,
            self,
        ) catch {
            resource.postNoMemory();
            return;
        };
        self.close_source = self.manager.event_loop.addFd(
            *Context,
            self.close_fd,
            .{},
            handleCloseEvent,
            self,
        ) catch {
            self.listen_source.?.remove();
            self.listen_source = null;
            resource.postNoMemory();
            return;
        };
        self.committed = true;
    }

    fn handleResourceDestroy(_: *wp.SecurityContextV1, self: *Context) void {
        self.resource = null;
        if (!self.committed) {
            self.deactivate();
            return;
        }
        if (!self.active) self.destroy();
    }

    fn deactivate(self: *Context) void {
        if (self.active) {
            self.active = false;
            if (self.listen_source) |source| source.remove();
            if (self.close_source) |source| source.remove();
            self.listen_source = null;
            self.close_source = null;
            _ = std.c.close(self.listen_fd);
            _ = std.c.close(self.close_fd);
        }
        if (self.resource == null) self.destroy();
    }

    fn destroy(self: *Context) void {
        std.debug.assert(!self.active and self.resource == null);
        for (self.manager.contexts.items, 0..) |context, index| {
            if (context != self) continue;
            _ = self.manager.contexts.orderedRemove(index);
            if (self.sandbox_engine) |value| self.manager.allocator.free(value);
            if (self.app_id) |value| self.manager.allocator.free(value);
            if (self.instance_id) |value| self.manager.allocator.free(value);
            self.manager.allocator.destroy(self);
            return;
        }
        unreachable;
    }
};

fn handleListenEvent(_: c_int, mask: wl.EventMask, context: *Context) c_int {
    if (mask.hangup or mask.@"error") {
        context.deactivate();
        return 0;
    }
    if (mask.readable) acceptClient(context);
    return 0;
}

fn handleCloseEvent(_: c_int, mask: wl.EventMask, context: *Context) c_int {
    if (mask.hangup or mask.@"error") context.deactivate();
    return 0;
}

const ClientContext = struct {
    manager: *Self,
    client: *wl.Client,
    sandbox_engine: ?[:0]u8,
    app_id: ?[:0]u8,
    instance_id: ?[:0]u8,
    destroy_listener: wl.Listener(*wl.Client),

    fn metadata(self: *const ClientContext) Metadata {
        return .{
            .sandbox_engine = self.sandbox_engine,
            .app_id = self.app_id,
            .instance_id = self.instance_id,
        };
    }

    fn deinitMetadata(self: *ClientContext) void {
        if (self.sandbox_engine) |value| self.manager.allocator.free(value);
        if (self.app_id) |value| self.manager.allocator.free(value);
        if (self.instance_id) |value| self.manager.allocator.free(value);
        self.sandbox_engine = null;
        self.app_id = null;
        self.instance_id = null;
    }

    fn handleClientDestroyed(listener: *wl.Listener(*wl.Client), _: *wl.Client) void {
        const self: *ClientContext = @fieldParentPtr("destroy_listener", listener);
        listener.link.remove();
        std.debug.assert(self.manager.clients.remove(self.client));
        self.deinitMetadata();
        self.manager.allocator.destroy(self);
    }
};

fn testGlobalBind(_: *wl.Client, _: *u8, _: u32, _: u32) void {}

test "sandbox clients cannot see registered privileged globals" {
    const display = try wl.Server.create();
    defer display.destroy();

    var manager: Self = undefined;
    try manager.init(std.testing.allocator, display);
    defer manager.deinit();

    var context: u8 = 0;
    const restricted = try wl.Global.create(
        display,
        wl.Compositor,
        1,
        *u8,
        &context,
        testGlobalBind,
    );
    defer restricted.destroy();
    const unrestricted = try wl.Global.create(
        display,
        wl.Subcompositor,
        1,
        *u8,
        &context,
        testGlobalBind,
    );
    defer unrestricted.destroy();
    try manager.restrictGlobal(restricted);
    defer manager.unrestrictGlobal(restricted);

    const client: *const wl.Client = @ptrFromInt(0x1000);
    try std.testing.expect(globalFilter(client, restricted, &manager));
    try manager.clients.put(
        std.testing.allocator,
        client,
        @as(*ClientContext, @ptrFromInt(0x2000)),
    );
    defer std.debug.assert(manager.clients.remove(client));

    try std.testing.expect(!globalFilter(client, manager.global, &manager));
    try std.testing.expect(!globalFilter(client, restricted, &manager));
    try std.testing.expect(globalFilter(client, unrestricted, &manager));
}

test "private globals are visible only to their authorized client" {
    const display = try wl.Server.create();
    defer display.destroy();

    var manager: Self = undefined;
    try manager.init(std.testing.allocator, display);
    defer manager.deinit();

    var context: u8 = 0;
    const private = try wl.Global.create(
        display,
        wl.Compositor,
        1,
        *u8,
        &context,
        testGlobalBind,
    );
    defer private.destroy();
    try manager.privatizeGlobal(private);
    defer manager.unprivatizeGlobal(private);

    const authorized: *const wl.Client = @ptrFromInt(0x1000);
    const other: *const wl.Client = @ptrFromInt(0x2000);
    try std.testing.expect(!globalFilter(authorized, private, &manager));
    manager.authorizePrivateGlobal(private, authorized);
    try std.testing.expect(globalFilter(authorized, private, &manager));
    try std.testing.expect(!globalFilter(other, private, &manager));
    manager.clearPrivateGlobalClient(private);
    try std.testing.expect(!globalFilter(authorized, private, &manager));
}

test "listen fd validation rejects connected sockets" {
    var sockets: [2]c_int = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.socketpair(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0, &sockets),
    );
    defer _ = std.c.close(sockets[0]);
    defer _ = std.c.close(sockets[1]);
    try std.testing.expect(!validListenFd(sockets[0]));
}

test "listen fd validation accepts listening sockets" {
    const fd = c.socket(c.AF_INET, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0);
    try std.testing.expect(fd >= 0);
    defer _ = std.c.close(fd);
    var address: c.struct_sockaddr_in = std.mem.zeroes(c.struct_sockaddr_in);
    address.sin_family = c.AF_INET;
    address.sin_addr.s_addr = c.htonl(c.INADDR_LOOPBACK);
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.bind(
            fd,
            .{ .__sockaddr__ = @ptrCast(&address) },
            @sizeOf(c.struct_sockaddr_in),
        ),
    );
    try std.testing.expectEqual(@as(c_int, 0), c.listen(fd, 1));
    try std.testing.expect(validListenFd(fd));
}
