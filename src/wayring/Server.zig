//! Sans-I/O Wayland server state, resource dispatch, and global discovery.
//!
//! `Server` owns protocol state but no sockets and performs no waits. A
//! transport feeds bytes and file descriptors into a stable `Client`, drains
//! its `Connection` output, and calls `outputDrained` after all queued output
//! has been acknowledged.

const Server = @This();

const std = @import("std");
const wayring = @import("wayring");
const core = @import("wayring-core");
const linux = std.os.linux;

const server_object_id_start: u32 = 0xff000000;

pub const RequestDispatch = *const fn (
    context: *anyopaque,
    client: *Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) anyerror!void;

pub const ResourceDestroy = *const fn (
    context: *anyopaque,
    client: *Client,
    resource: wayring.ObjectHandle,
) void;

pub const GlobalBind = *const fn (
    context: *anyopaque,
    client: *Client,
    id: u32,
    version: u32,
) anyerror!void;

pub const GlobalFilter = *const fn (context: *anyopaque, client: *const Client) bool;

pub const ResourceImplementation = struct {
    context: *anyopaque,
    dispatch: ?RequestDispatch = null,
    destroy: ?ResourceDestroy = null,
};

pub const GlobalImplementation = struct {
    context: *anyopaque,
    bind: GlobalBind,
    filter_context: ?*anyopaque = null,
    filter: ?GlobalFilter = null,
};

pub const ClientState = enum { active, protocol_error, closing };

const Resource = struct {
    handle: wayring.ObjectHandle,
    interface: *const wayring.Interface,
    version: u32,
    implementation: ResourceImplementation,
    destroying: bool = false,
};

pub const Global = struct {
    name: u32,
    interface: *const wayring.Interface,
    version: u32,
    implementation: GlobalImplementation,

    fn visibleTo(self: *const Global, client: *const Client) bool {
        const filter = self.implementation.filter orelse return true;
        return filter(self.implementation.filter_context orelse self.implementation.context, client);
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    server: *Server,
    connection: wayring.Connection,
    resources: std.AutoHashMapUnmanaged(u32, Resource) = .empty,
    registries: std.ArrayList(wayring.ObjectHandle) = .empty,
    retired_ids: std.ArrayList(u32) = .empty,
    deferred_destroys: std.ArrayList(wayring.ObjectHandle) = .empty,
    state: ClientState = .active,
    dispatch_depth: usize = 0,
    references: usize = 1,
    transport_attached: bool = true,

    fn init(allocator: std.mem.Allocator, server: *Server) !Client {
        var client: Client = .{
            .allocator = allocator,
            .server = server,
            .connection = wayring.Connection.init(allocator, .server, wayring.default_max_frame_size),
        };
        errdefer client.connection.deinit();
        try client.resources.ensureUnusedCapacity(allocator, 1);
        const generation = try core.bootstrapDisplay(&client.connection);
        client.resources.putAssumeCapacity(1, .{
            .handle = .{ .id = 1, .generation = generation },
            .interface = &core.wl_display,
            .version = 1,
            .implementation = .{
                .context = server,
                .dispatch = dispatchDisplay,
            },
        });
        return client;
    }

    fn closeResources(self: *Client) void {
        if (self.state == .closing) return;
        self.state = .closing;
        while (self.resources.count() != 0) {
            var iterator = self.resources.iterator();
            const entry = iterator.next().?;
            const resource = entry.value_ptr.*;
            _ = self.resources.remove(resource.handle.id);
            if (resource.implementation.destroy) |destroy|
                destroy(resource.implementation.context, self, resource.handle);
            self.connection.removeObject(resource.handle.id, resource.handle.generation) catch {};
        }
    }

    fn deinit(self: *Client) void {
        self.closeResources();
        self.deferred_destroys.deinit(self.allocator);
        self.retired_ids.deinit(self.allocator);
        self.registries.deinit(self.allocator);
        self.resources.deinit(self.allocator);
        self.connection.deinit();
        self.* = undefined;
    }

    /// Retains the client storage beyond transport teardown. Policy objects
    /// that keep a client pointer after request dispatch must hold a reference.
    pub fn reference(self: *Client) !void {
        if (self.references == std.math.maxInt(usize)) return error.ReferenceOverflow;
        self.references += 1;
    }

    pub fn unreference(self: *Client) void {
        self.server.releaseClientReference(self);
    }

    /// Feeds one transport receive and dispatches every complete request.
    /// Descriptor ownership transfers to the connection on every return path.
    pub fn receive(self: *Client, bytes: []const u8, fds: []const i32) !void {
        if (self.state != .active) {
            closeAll(fds);
            return error.ClientNotActive;
        }
        self.connection.feed(bytes, fds) catch {
            return self.protocolError(1, 0, "malformed Wayland request");
        };
        try self.dispatchPending();
    }

    pub fn dispatchPending(self: *Client) !void {
        if (self.state != .active) return error.ClientNotActive;
        self.dispatch_depth += 1;
        defer self.dispatch_depth -= 1;

        while (self.connection.popMessage()) |popped| {
            var message = popped;
            defer message.deinit();
            self.dispatchOne(&message) catch {
                if (self.state == .protocol_error) return error.ProtocolError;
                return self.protocolError(message.object_id, 3, "Wayland request dispatch failed");
            };
            if (hasConstructor(message.descriptor)) {
                self.validateConstructors(&message) catch {
                    return self.protocolError(message.object_id, 3, "request constructor was not registered");
                };
            }
            if (message.descriptor.destructor) {
                if (self.resources.get(message.object_id)) |resource|
                    self.destroyResource(resource.handle) catch {
                        return self.protocolError(message.object_id, 2, "resource destruction failed");
                    };
            }
            self.destroyDeferredResources() catch {
                return self.protocolError(message.object_id, 2, "deferred resource destruction failed");
            };
            if (hasConstructor(message.descriptor)) {
                self.connection.resumeParsing() catch {
                    return self.protocolError(message.object_id, 0, "invalid request following constructor");
                };
            }
        }
    }

    fn dispatchOne(self: *Client, message: *wayring.Message) !void {
        const resource = self.resources.get(message.object_id) orelse return error.UnknownResource;
        _ = try self.connection.objectForHandle(resource.handle, resource.interface);
        try self.validateArguments(message);
        const dispatch = resource.implementation.dispatch orelse return error.UnhandledRequest;
        try dispatch(resource.implementation.context, self, resource.handle, message);
    }

    fn validateArguments(self: *const Client, message: *const wayring.Message) !void {
        for (message.descriptor.args, message.values, 0..) |spec, value, index| switch (spec.kind) {
            .object => if (value.object) |id| {
                const resource = self.resources.get(id) orelse return error.UnknownObject;
                const registered = self.connection.object(id) orelse return error.UnknownObject;
                if (registered.generation != resource.handle.generation) return error.StaleObject;
                if (spec.interface_name) |expected| {
                    if (!std.mem.eql(u8, expected, resource.interface.name)) return error.WrongInterface;
                }
            },
            .new_id => {
                const id = value.new_id;
                if (id >= server_object_id_start) return error.InvalidObjectId;
                if (self.resources.contains(id) or self.connection.object(id) != null)
                    return error.ObjectExists;
                for (message.descriptor.args[0..index], message.values[0..index]) |prior_spec, prior_value| {
                    if (prior_spec.kind == .new_id and prior_value.new_id == id)
                        return error.ObjectExists;
                }
            },
            else => {},
        };
    }

    fn validateConstructors(self: *const Client, message: *const wayring.Message) !void {
        for (message.descriptor.args, message.values) |spec, value| {
            if (spec.kind != .new_id) continue;
            const resource = self.resources.get(value.new_id) orelse return error.MissingResource;
            const registered = self.connection.object(value.new_id) orelse return error.MissingResource;
            if (registered.generation != resource.handle.generation) return error.StaleObject;
            if (spec.interface_name) |expected| {
                if (!std.mem.eql(u8, expected, resource.interface.name)) return error.WrongInterface;
            }
        }
    }

    pub fn createResource(
        self: *Client,
        id: u32,
        interface: *const wayring.Interface,
        version: u32,
        implementation: ResourceImplementation,
    ) !wayring.ObjectHandle {
        if (self.state != .active) return error.ClientNotActive;
        if (id <= 1 or id >= server_object_id_start) return error.InvalidObjectId;
        try self.resources.ensureUnusedCapacity(self.allocator, 1);
        const generation = try self.connection.registerObject(id, interface, version);
        errdefer self.connection.removeObject(id, generation) catch unreachable;
        const handle: wayring.ObjectHandle = .{ .id = id, .generation = generation };
        self.resources.putAssumeCapacity(id, .{
            .handle = handle,
            .interface = interface,
            .version = version,
            .implementation = implementation,
        });
        return handle;
    }

    pub fn createServerResource(
        self: *Client,
        interface: *const wayring.Interface,
        version: u32,
        implementation: ResourceImplementation,
    ) !wayring.ObjectHandle {
        if (self.state != .active) return error.ClientNotActive;
        try self.resources.ensureUnusedCapacity(self.allocator, 1);
        const handle = try self.connection.allocateServerObject(interface, version);
        errdefer self.connection.removeObject(handle.id, handle.generation) catch unreachable;
        self.resources.putAssumeCapacity(handle.id, .{
            .handle = handle,
            .interface = interface,
            .version = version,
            .implementation = implementation,
        });
        return handle;
    }

    /// Resolves the policy context attached to a live resource argument.
    pub fn resourceContext(
        self: *const Client,
        handle: wayring.ObjectHandle,
        interface: *const wayring.Interface,
    ) !*anyopaque {
        const resource = self.resources.get(handle.id) orelse return error.UnknownResource;
        if (resource.handle.generation != handle.generation) return error.StaleObject;
        if (resource.interface != interface) return error.WrongInterface;
        return resource.implementation.context;
    }

    pub fn resourceVersion(
        self: *const Client,
        handle: wayring.ObjectHandle,
        interface: *const wayring.Interface,
    ) !u32 {
        const resource = self.resources.get(handle.id) orelse return error.UnknownResource;
        if (resource.handle.generation != handle.generation) return error.StaleObject;
        if (resource.interface != interface) return error.WrongInterface;
        return resource.version;
    }

    /// Queues a protocol-defined error and marks the client for deferred
    /// disconnect once the transport has flushed pending output.
    pub fn postError(
        self: *Client,
        resource: wayring.ObjectHandle,
        code: u32,
        text: []const u8,
    ) anyerror!void {
        const registered = self.resources.get(resource.id) orelse return error.UnknownResource;
        if (registered.handle.generation != resource.generation) return error.StaleObject;
        return self.protocolError(resource.id, code, text);
    }

    pub fn postNoMemory(self: *Client) anyerror!void {
        return self.protocolError(1, 2, "out of memory");
    }

    pub fn destroyResource(self: *Client, handle: wayring.ObjectHandle) !void {
        if (handle.id == 1) return error.CannotDestroyDisplay;
        const resource = self.resources.getPtr(handle.id) orelse return error.UnknownResource;
        if (resource.handle.generation != handle.generation) return error.StaleObject;
        if (resource.destroying) return;
        if (handle.id < server_object_id_start)
            try self.retired_ids.ensureUnusedCapacity(self.allocator, 1);

        resource.destroying = true;
        const implementation = resource.implementation;
        if (implementation.destroy) |destroy| destroy(implementation.context, self, handle);
        const current = self.resources.get(handle.id) orelse return;
        if (current.handle.generation != handle.generation) return error.StaleObject;
        if (handle.id < server_object_id_start)
            try self.retired_ids.ensureUnusedCapacity(self.allocator, 1);

        removeHandle(&self.registries, handle);
        _ = self.resources.remove(handle.id);
        if (handle.id < server_object_id_start) {
            try self.connection.retireServerObject(handle);
            try core.queueDeleteId(&self.connection, handle.id);
            self.retired_ids.appendAssumeCapacity(handle.id);
        } else {
            try self.connection.removeObject(handle.id, handle.generation);
        }
    }

    /// Defers destruction until the current request's constructor invariants
    /// have been checked. This is used by destructor events such as
    /// `wl_callback.done`, which may be queued while handling a constructor.
    pub fn deferResourceDestroy(self: *Client, handle: wayring.ObjectHandle) !void {
        const resource = self.resources.get(handle.id) orelse return error.UnknownResource;
        if (resource.handle.generation != handle.generation) return error.StaleObject;
        try self.deferred_destroys.append(self.allocator, handle);
    }

    fn destroyDeferredResources(self: *Client) !void {
        while (self.deferred_destroys.items.len != 0) {
            const handle = self.deferred_destroys.orderedRemove(0);
            const resource = self.resources.get(handle.id) orelse continue;
            if (resource.handle.generation != handle.generation) continue;
            try self.destroyResource(handle);
        }
    }

    /// Releases client-created numeric IDs only after the transport has sent
    /// every frame queued before and including `wl_display.delete_id`.
    pub fn outputDrained(self: *Client) !void {
        if (self.connection.hasPendingOutput()) return error.OutputPending;
        for (self.retired_ids.items) |id| try self.connection.releaseServerObjectId(id);
        self.retired_ids.clearRetainingCapacity();
    }

    pub fn shouldDisconnect(self: *const Client) bool {
        return self.state == .protocol_error and !self.connection.hasPendingOutput();
    }

    fn protocolError(self: *Client, object_id: u32, code: u32, text: []const u8) anyerror!void {
        self.state = .protocol_error;
        core.queueDisplayError(&self.connection, object_id, code, text) catch return error.ProtocolErrorWithoutEvent;
        return error.ProtocolError;
    }
};

allocator: std.mem.Allocator,
clients: std.ArrayList(*Client) = .empty,
globals: std.ArrayList(Global) = .empty,
next_global_name: u64 = 1,
serial: u32 = 0,

pub fn init(allocator: std.mem.Allocator) Server {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Server) void {
    while (self.clients.pop()) |client| {
        client.closeResources();
        std.debug.assert(client.transport_attached and client.references == 1);
        client.transport_attached = false;
        client.references = 0;
        client.deinit();
        self.allocator.destroy(client);
    }
    self.globals.deinit(self.allocator);
    self.clients.deinit(self.allocator);
    self.* = undefined;
}

/// Allocates a stable client address suitable for completion callback context.
pub fn createClient(self: *Server) !*Client {
    const client = try self.allocator.create(Client);
    errdefer self.allocator.destroy(client);
    client.* = try Client.init(self.allocator, self);
    errdefer client.deinit();
    try self.clients.append(self.allocator, client);
    return client;
}

/// Destroys a client after transport completions no longer reference it.
pub fn destroyClient(self: *Server, client: *Client) !void {
    if (client.dispatch_depth != 0) return error.DispatchActive;
    if (!client.transport_attached) return error.TransportDetached;
    std.debug.assert(client.server == self);
    client.closeResources();
    client.transport_attached = false;
    self.releaseClientReference(client);
}

fn releaseClientReference(self: *Server, client: *Client) void {
    std.debug.assert(client.references > 0);
    client.references -= 1;
    if (client.references != 0) return;
    std.debug.assert(!client.transport_attached and client.dispatch_depth == 0);
    const index = std.mem.indexOfScalar(*Client, self.clients.items, client) orelse unreachable;
    _ = self.clients.orderedRemove(index);
    client.deinit();
    self.allocator.destroy(client);
}

pub fn createGlobal(
    self: *Server,
    interface: *const wayring.Interface,
    version: u32,
    implementation: GlobalImplementation,
) !u32 {
    if (version == 0 or version > interface.version) return error.InvalidGlobalVersion;
    if (self.next_global_name > std.math.maxInt(u32)) return error.GlobalNameExhausted;
    try self.globals.ensureUnusedCapacity(self.allocator, 1);
    const name: u32 = @intCast(self.next_global_name);
    self.next_global_name += 1;
    self.globals.appendAssumeCapacity(.{
        .name = name,
        .interface = interface,
        .version = version,
        .implementation = implementation,
    });
    const added_global = self.globals.items[self.globals.items.len - 1];
    for (self.clients.items) |client| {
        if (client.state != .active or !added_global.visibleTo(client)) continue;
        for (client.registries.items) |registry|
            try core.queueGlobal(&client.connection, registry.id, name, interface.name, version);
    }
    return name;
}

pub fn removeGlobal(self: *Server, name: u32) !void {
    const index = self.globalIndex(name) orelse return error.UnknownGlobal;
    const removed_global = self.globals.items[index];
    for (self.clients.items) |client| {
        if (client.state != .active or !removed_global.visibleTo(client)) continue;
        for (client.registries.items) |registry|
            try core.queueGlobalRemove(&client.connection, registry.id, name);
    }
    _ = self.globals.orderedRemove(index);
}

fn globalIndex(self: *const Server, name: u32) ?usize {
    for (self.globals.items, 0..) |global_value, index| if (global_value.name == name) return index;
    return null;
}

fn findGlobal(self: *Server, name: u32) ?*Global {
    const index = self.globalIndex(name) orelse return null;
    return &self.globals.items[index];
}

pub fn nextSerial(self: *Server) u32 {
    self.serial +%= 1;
    if (self.serial == 0) self.serial = 1;
    return self.serial;
}

fn dispatchDisplay(
    context: *anyopaque,
    client: *Client,
    _: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const self: *Server = @ptrCast(@alignCast(context));
    switch (try core.decodeDisplayRequest(message)) {
        .get_registry => |id| {
            try client.registries.ensureUnusedCapacity(client.allocator, 1);
            const handle = try client.createResource(id, &core.wl_registry, 1, .{
                .context = self,
                .dispatch = dispatchRegistry,
            });
            client.registries.appendAssumeCapacity(handle);
            for (self.globals.items) |*global_value| {
                if (!global_value.visibleTo(client)) continue;
                try core.queueGlobal(
                    &client.connection,
                    handle.id,
                    global_value.name,
                    global_value.interface.name,
                    global_value.version,
                );
            }
        },
        .sync => |id| {
            const callback = try client.createResource(id, &core.wl_callback, 1, .{
                .context = self,
            });
            try core.queueCallbackDone(&client.connection, callback.id, self.nextSerial());
            try client.deferResourceDestroy(callback);
        },
    }
}

fn dispatchRegistry(
    context: *anyopaque,
    client: *Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const self: *Server = @ptrCast(@alignCast(context));
    const request = (try core.decodeRegistryRequest(message, resource.id)).bind;
    const global_value = (self.findGlobal(request.name) orelse return error.UnknownGlobal).*;
    if (!global_value.visibleTo(client)) return error.FilteredGlobal;
    if (!std.mem.eql(u8, request.interface, global_value.interface.name)) return error.WrongInterface;
    if (request.version == 0 or request.version > global_value.version) return error.InvalidVersion;
    try global_value.implementation.bind(
        global_value.implementation.context,
        client,
        request.new_id,
        request.version,
    );
    const created = client.resources.get(request.new_id) orelse return error.MissingResource;
    if (created.interface != global_value.interface or created.version != request.version)
        return error.WrongBoundResource;
}

fn hasConstructor(descriptor: *const wayring.MessageDescriptor) bool {
    for (descriptor.args) |argument| if (argument.kind == .new_id) return true;
    return false;
}

fn removeHandle(handles: *std.ArrayList(wayring.ObjectHandle), target: wayring.ObjectHandle) void {
    for (handles.items, 0..) |handle, index| {
        if (handle.id == target.id and handle.generation == target.generation) {
            _ = handles.orderedRemove(index);
            return;
        }
    }
}

fn closeAll(fds: []const i32) void {
    for (fds) |fd| {
        if (fd >= 0) _ = linux.close(fd);
    }
}

const test_ping_args = [_]wayring.ArgumentSpec{.{ .kind = .uint }};
const test_child_requests = [_]wayring.MessageDescriptor{ .{
    .name = "ping",
    .opcode = 0,
    .args = &test_ping_args,
}, .{
    .name = "destroy",
    .opcode = 1,
    .destructor = true,
} };
const test_child_events = [_]wayring.MessageDescriptor{.{
    .name = "notice",
    .opcode = 0,
    .args = &test_ping_args,
}};
const test_child: wayring.Interface = .{
    .name = "test_child",
    .version = 2,
    .requests = &test_child_requests,
    .events = &test_child_events,
};
const test_create_args = [_]wayring.ArgumentSpec{.{
    .kind = .new_id,
    .interface_name = "test_child",
    .new_id_interface = &test_child,
}};
const test_factory_requests = [_]wayring.MessageDescriptor{.{
    .name = "create",
    .opcode = 0,
    .args = &test_create_args,
}};
const test_factory: wayring.Interface = .{
    .name = "test_factory",
    .version = 2,
    .requests = &test_factory_requests,
};

const TestContext = struct {
    factory_dispatches: usize = 0,
    child_pings: usize = 0,
    child_destroys: usize = 0,
    register_constructor: bool = true,
    denied_client: ?*Client = null,
    nested_destroy: ?wayring.ObjectHandle = null,
    nested_destroy_failed: bool = false,

    fn bind(context: *anyopaque, client: *Client, id: u32, version: u32) !void {
        const self: *@This() = @ptrCast(@alignCast(context));
        _ = try client.createResource(id, &test_factory, version, .{
            .context = self,
            .dispatch = factoryDispatch,
        });
    }

    fn filter(context: *anyopaque, client: *const Client) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        return client != self.denied_client;
    }

    fn factoryDispatch(
        context: *anyopaque,
        client: *Client,
        _: wayring.ObjectHandle,
        message: *wayring.Message,
    ) !void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.factory_dispatches += 1;
        if (self.register_constructor) {
            _ = try client.createResource(message.values[0].new_id, &test_child, 2, .{
                .context = self,
                .dispatch = childDispatch,
                .destroy = childDestroy,
            });
        }
    }

    fn childDispatch(
        context: *anyopaque,
        client: *Client,
        resource: wayring.ObjectHandle,
        message: *wayring.Message,
    ) !void {
        const self: *@This() = @ptrCast(@alignCast(context));
        switch (message.descriptor.opcode) {
            0 => {
                try std.testing.expectEqual(@as(u32, 77), message.values[0].uint);
                self.child_pings += 1;
            },
            1 => try client.connection.queueObject(
                resource,
                &test_child,
                0,
                &.{.{ .uint = 88 }},
            ),
            else => return error.UnknownOpcode,
        }
    }

    fn childDestroy(
        context: *anyopaque,
        client: *Client,
        _: wayring.ObjectHandle,
    ) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.child_destroys += 1;
        if (self.nested_destroy) |handle| {
            self.nested_destroy = null;
            client.destroyResource(handle) catch {
                self.nested_destroy_failed = true;
            };
        }
    }
};

const TestPeer = struct {
    connection: wayring.Connection,
    display: wayring.ObjectHandle,
    registry: ?wayring.ObjectHandle = null,

    fn init(allocator: std.mem.Allocator) !TestPeer {
        var connection = wayring.Connection.init(allocator, .client, wayring.default_max_frame_size);
        errdefer connection.deinit();
        const display_generation = try core.bootstrapDisplay(&connection);
        return .{
            .connection = connection,
            .display = .{ .id = 1, .generation = display_generation },
        };
    }

    fn deinit(self: *TestPeer) void {
        self.connection.deinit();
    }

    fn getRegistry(self: *TestPeer) !void {
        const id: u32 = 2;
        self.registry = .{ .id = id, .generation = try core.getRegistry(&self.connection, id) };
    }

    fn transferToServer(self: *TestPeer, client: *Client) !void {
        while (self.connection.nextBatch()) |batch| {
            try client.receive(batch.bytes, batch.fds);
            try self.connection.acknowledge(batch.token, batch.bytes.len);
        }
    }

    fn transferFromServer(self: *TestPeer, client: *Client) !void {
        while (client.connection.nextBatch()) |batch| {
            try self.connection.feed(batch.bytes, batch.fds);
            try client.connection.acknowledge(batch.token, batch.bytes.len);
        }
        try client.outputDrained();
    }
};

test "registry advertises globals and bind dispatches resources" {
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var context: TestContext = .{};
    const global_name = try server.createGlobal(&test_factory, 2, .{
        .context = &context,
        .bind = TestContext.bind,
    });
    const client = try server.createClient();
    var peer = try TestPeer.init(std.testing.allocator);
    defer peer.deinit();

    try peer.getRegistry();
    try peer.transferToServer(client);
    try peer.transferFromServer(client);
    var global_message = peer.connection.popMessage() orelse return error.MissingGlobal;
    defer global_message.deinit();
    const advertised = (try core.decodeRegistryEvent(&global_message, peer.registry.?.id)).global;
    try std.testing.expectEqual(global_name, advertised.name);
    try std.testing.expectEqualStrings(test_factory.name, advertised.interface);
    try std.testing.expectEqual(@as(u32, 2), advertised.version);

    const factory_id: u32 = 3;
    _ = try core.bind(
        &peer.connection,
        peer.registry.?.id,
        global_name,
        test_factory.name,
        2,
        factory_id,
        &test_factory,
    );
    try peer.transferToServer(client);
    try std.testing.expect(client.resources.contains(factory_id));

    try peer.connection.queue(factory_id, 0, &.{.{ .new_id = 4 }});
    _ = try peer.connection.registerObject(4, &test_child, 2);
    try peer.connection.queue(4, 0, &.{.{ .uint = 77 }});
    try peer.transferToServer(client);
    try std.testing.expectEqual(@as(usize, 1), context.factory_dispatches);
    try std.testing.expectEqual(@as(usize, 1), context.child_pings);
}

test "global filters gate advertisement and bind" {
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var context: TestContext = .{};
    const allowed = try server.createClient();
    const denied = try server.createClient();
    context.denied_client = denied;
    const global_name = try server.createGlobal(&test_factory, 1, .{
        .context = &context,
        .bind = TestContext.bind,
        .filter = TestContext.filter,
    });
    var allowed_peer = try TestPeer.init(std.testing.allocator);
    defer allowed_peer.deinit();
    var denied_peer = try TestPeer.init(std.testing.allocator);
    defer denied_peer.deinit();
    try allowed_peer.getRegistry();
    try denied_peer.getRegistry();
    try allowed_peer.transferToServer(allowed);
    try denied_peer.transferToServer(denied);
    try allowed_peer.transferFromServer(allowed);
    try denied_peer.transferFromServer(denied);
    var allowed_global = allowed_peer.connection.popMessage() orelse return error.MissingGlobal;
    allowed_global.deinit();
    try std.testing.expect(denied_peer.connection.popMessage() == null);

    _ = try core.bind(
        &denied_peer.connection,
        denied_peer.registry.?.id,
        global_name,
        test_factory.name,
        1,
        3,
        &test_factory,
    );
    try std.testing.expectError(error.ProtocolError, denied_peer.transferToServer(denied));
    try std.testing.expectEqual(ClientState.protocol_error, denied.state);
}

test "sync retires callback IDs until delete-id output drains" {
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    const client = try server.createClient();
    var peer = try TestPeer.init(std.testing.allocator);
    defer peer.deinit();
    const callback_id: u32 = 2;
    _ = try core.sync(&peer.connection, callback_id);
    try peer.transferToServer(client);
    try std.testing.expectError(
        error.ObjectExists,
        client.createResource(callback_id, &test_child, 1, .{ .context = client }),
    );

    try peer.transferFromServer(client);
    var done_message = peer.connection.popMessage() orelse return error.MissingDone;
    defer done_message.deinit();
    try std.testing.expectEqual(@as(u32, 1), (try core.decodeCallbackEvent(&done_message, callback_id)).done);
    var delete_message = peer.connection.popMessage() orelse return error.MissingDeleteId;
    defer delete_message.deinit();
    try std.testing.expectEqual(callback_id, (try core.decodeDisplayEvent(&delete_message)).delete_id);
    const reused = try client.createResource(callback_id, &test_child, 1, .{ .context = client });
    try std.testing.expectEqual(callback_id, reused.id);
}

test "destructor requests queue events before delete-id and reserve the ID" {
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var context: TestContext = .{};
    const client = try server.createClient();
    const server_child = try client.createResource(2, &test_child, 2, .{
        .context = &context,
        .dispatch = TestContext.childDispatch,
        .destroy = TestContext.childDestroy,
    });
    var peer = try TestPeer.init(std.testing.allocator);
    defer peer.deinit();
    const peer_child: wayring.ObjectHandle = .{
        .id = 2,
        .generation = try peer.connection.registerObject(2, &test_child, 2),
    };

    try peer.connection.queueDestructorObject(peer_child, &test_child, 1, &.{});
    try peer.transferToServer(client);
    try std.testing.expectEqual(@as(usize, 1), context.child_destroys);
    try std.testing.expectError(
        error.ObjectExists,
        client.createResource(server_child.id, &test_child, 1, .{ .context = client }),
    );

    const event_batch = client.connection.nextBatch() orelse return error.MissingDestructorEvent;
    try std.testing.expectEqual(server_child.id, readTestU32(event_batch.bytes[0..4]));
    try peer.connection.feed(event_batch.bytes, event_batch.fds);
    try client.connection.acknowledge(event_batch.token, event_batch.bytes.len);
    const delete_batch = client.connection.nextBatch() orelse return error.MissingDeleteId;
    try std.testing.expectEqual(@as(u32, 1), readTestU32(delete_batch.bytes[0..4]));
    try peer.connection.feed(delete_batch.bytes, delete_batch.fds);
    try client.connection.acknowledge(delete_batch.token, delete_batch.bytes.len);
    try client.outputDrained();

    var delete_message = peer.connection.popMessage() orelse return error.MissingDeleteId;
    defer delete_message.deinit();
    try std.testing.expectEqual(server_child.id, (try core.decodeDisplayEvent(&delete_message)).delete_id);
    const reused = try client.createResource(server_child.id, &test_child, 1, .{ .context = client });
    try std.testing.expectEqual(server_child.id, reused.id);
}

test "destroy callbacks may destroy another resource" {
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var context: TestContext = .{};
    const client = try server.createClient();
    const first = try client.createResource(2, &test_child, 1, .{
        .context = &context,
        .destroy = TestContext.childDestroy,
    });
    const second = try client.createResource(3, &test_child, 1, .{
        .context = &context,
        .destroy = TestContext.childDestroy,
    });
    context.nested_destroy = second;

    try client.destroyResource(first);
    try std.testing.expect(!context.nested_destroy_failed);
    try std.testing.expectEqual(@as(usize, 2), context.child_destroys);
    try std.testing.expect(client.connection.object(first.id) == null);
    try std.testing.expect(client.connection.object(second.id) == null);
    var frame_count: usize = 0;
    while (client.connection.nextBatch()) |batch| {
        frame_count += 1;
        try client.connection.acknowledge(batch.token, batch.bytes.len);
    }
    try std.testing.expectEqual(@as(usize, 2), frame_count);
    try client.outputDrained();
    _ = try client.createResource(first.id, &test_child, 1, .{ .context = client });
    _ = try client.createResource(second.id, &test_child, 1, .{ .context = client });
}

test "resource contexts resolve by generation and policy errors flush" {
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var context: TestContext = .{};
    const client = try server.createClient();
    const resource = try client.createResource(2, &test_child, 1, .{ .context = &context });
    const resolved: *TestContext = @ptrCast(@alignCast(try client.resourceContext(resource, &test_child)));
    try std.testing.expectEqual(&context, resolved);
    try std.testing.expectError(error.WrongInterface, client.resourceContext(resource, &test_factory));
    try std.testing.expectError(error.ProtocolError, client.postError(resource, 19, "bad child"));
    try std.testing.expectEqual(ClientState.protocol_error, client.state);
    try std.testing.expect(!client.shouldDisconnect());

    var peer = try TestPeer.init(std.testing.allocator);
    defer peer.deinit();
    try peer.transferFromServer(client);
    var error_message = peer.connection.popMessage() orelse return error.MissingDisplayError;
    defer error_message.deinit();
    const posted = (try core.decodeDisplayEvent(&error_message)).error_event;
    try std.testing.expectEqual(resource.id, posted.object_id);
    try std.testing.expectEqual(@as(u32, 19), posted.code);
    try std.testing.expectEqualStrings("bad child", posted.message);
    try std.testing.expect(client.shouldDisconnect());
}

test "missing constructor registration stops a coalesced child request" {
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var context: TestContext = .{ .register_constructor = false };
    const client = try server.createClient();
    _ = try client.createResource(2, &test_factory, 2, .{
        .context = &context,
        .dispatch = TestContext.factoryDispatch,
    });
    var peer = try TestPeer.init(std.testing.allocator);
    defer peer.deinit();
    _ = try peer.connection.registerObject(2, &test_factory, 2);
    try peer.connection.queue(2, 0, &.{.{ .new_id = 3 }});
    _ = try peer.connection.registerObject(3, &test_child, 2);
    try peer.connection.queue(3, 0, &.{.{ .uint = 77 }});

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    while (peer.connection.nextBatch()) |batch| {
        try bytes.appendSlice(std.testing.allocator, batch.bytes);
        try peer.connection.acknowledge(batch.token, batch.bytes.len);
    }
    try std.testing.expectError(error.ProtocolError, client.receive(bytes.items, &.{}));
    try std.testing.expectEqual(@as(usize, 1), context.factory_dispatches);
    try std.testing.expectEqual(@as(usize, 0), context.child_pings);
}

test "global add and remove fan out to every registry" {
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var context: TestContext = .{};
    const first_client = try server.createClient();
    const second_client = try server.createClient();
    var first = try TestPeer.init(std.testing.allocator);
    defer first.deinit();
    var second = try TestPeer.init(std.testing.allocator);
    defer second.deinit();
    try first.getRegistry();
    try second.getRegistry();
    try first.transferToServer(first_client);
    try second.transferToServer(second_client);

    const name = try server.createGlobal(&test_factory, 1, .{
        .context = &context,
        .bind = TestContext.bind,
    });
    try first.transferFromServer(first_client);
    try second.transferFromServer(second_client);
    var first_add = first.connection.popMessage() orelse return error.MissingGlobal;
    defer first_add.deinit();
    var second_add = second.connection.popMessage() orelse return error.MissingGlobal;
    defer second_add.deinit();
    try std.testing.expectEqual(name, (try core.decodeRegistryEvent(&first_add, 2)).global.name);
    try std.testing.expectEqual(name, (try core.decodeRegistryEvent(&second_add, 2)).global.name);

    try server.removeGlobal(name);
    try first.transferFromServer(first_client);
    try second.transferFromServer(second_client);
    var first_remove = first.connection.popMessage() orelse return error.MissingGlobalRemove;
    defer first_remove.deinit();
    var second_remove = second.connection.popMessage() orelse return error.MissingGlobalRemove;
    defer second_remove.deinit();
    try std.testing.expectEqual(name, (try core.decodeRegistryEvent(&first_remove, 2)).global_remove);
    try std.testing.expectEqual(name, (try core.decodeRegistryEvent(&second_remove, 2)).global_remove);
}

test "retained policy state keeps client storage alive after transport teardown" {
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    const client = try server.createClient();
    try client.reference();

    try server.destroyClient(client);
    try std.testing.expectEqual(ClientState.closing, client.state);
    try std.testing.expectEqual(@as(usize, 1), server.clients.items.len);

    client.unreference();
    try std.testing.expectEqual(@as(usize, 0), server.clients.items.len);
}

fn readTestU32(bytes: []const u8) u32 {
    std.debug.assert(bytes.len == 4);
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}
