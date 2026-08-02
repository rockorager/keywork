//! Native visibility-scoped idle-inhibit-v1 policy.

const IdleInhibitGlobal = @This();

const std = @import("std");
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const CompositorGlobal = @import("CompositorGlobal.zig");

const advertised_version: u32 = 1;

allocator: std.mem.Allocator,
server: *Server,
compositor: *CompositorGlobal,
global_name: u32,
inhibitors: std.ArrayList(*Inhibitor) = .empty,

const Inhibitor = struct {
    owner: *IdleInhibitGlobal,
    surface: *CompositorGlobal.Surface,
};

pub fn init(
    self: *IdleInhibitGlobal,
    allocator: std.mem.Allocator,
    server: *Server,
    compositor: *CompositorGlobal,
) !void {
    self.* = .{
        .allocator = allocator,
        .server = server,
        .compositor = compositor,
        .global_name = undefined,
    };
    self.global_name = try server.createGlobal(
        &generated.zwp_idle_inhibit_manager_v1,
        advertised_version,
        .{ .context = self, .bind = bind },
    );
}

pub fn deinit(self: *IdleInhibitGlobal) void {
    std.debug.assert(self.inhibitors.items.len == 0);
    self.server.removeGlobal(self.global_name) catch unreachable;
    self.inhibitors.deinit(self.allocator);
    self.* = undefined;
}

pub fn hasVisibleInhibitor(
    self: *const IdleInhibitGlobal,
    context: *anyopaque,
    is_visible: *const fn (*anyopaque, *const CompositorGlobal.Surface) bool,
) bool {
    for (self.inhibitors.items) |inhibitor| {
        if (inhibitor.surface.resource_alive and is_visible(context, inhibitor.surface))
            return true;
    }
    return false;
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *IdleInhibitGlobal = @ptrCast(@alignCast(context));
    _ = client.createResource(
        id,
        &generated.zwp_idle_inhibit_manager_v1,
        version,
        .{ .context = self, .dispatch = dispatchManager },
    ) catch return client.postNoMemory();
}

fn dispatchManager(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const self: *IdleInhibitGlobal = @ptrCast(@alignCast(context));
    switch (try generated.zwp_idle_inhibit_manager_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .create_inhibitor => |request| try self.createInhibitor(
            client,
            resource,
            request.id,
            request.surface,
        ),
    }
}

fn createInhibitor(
    self: *IdleInhibitGlobal,
    client: *Server.Client,
    manager_resource: wayring.ObjectHandle,
    id: u32,
    surface_id: u32,
) !void {
    const object = client.connection.object(surface_id) orelse
        return error.UnknownSurface;
    const surface = try CompositorGlobal.surfaceFor(client, .{
        .id = surface_id,
        .generation = object.generation,
    });
    if (surface.owner != self.compositor) return error.WrongSurface;

    const inhibitor = self.allocator.create(Inhibitor) catch
        return client.postNoMemory();
    errdefer self.allocator.destroy(inhibitor);
    self.inhibitors.ensureUnusedCapacity(self.allocator, 1) catch
        return client.postNoMemory();
    surface.reference() catch return client.postNoMemory();
    errdefer surface.unreference();
    inhibitor.* = .{ .owner = self, .surface = surface };
    const version = try client.resourceVersion(
        manager_resource,
        &generated.zwp_idle_inhibit_manager_v1,
    );
    _ = client.createResource(
        id,
        &generated.zwp_idle_inhibitor_v1,
        version,
        .{
            .context = inhibitor,
            .dispatch = dispatchInhibitor,
            .destroy = destroyInhibitor,
        },
    ) catch return client.postNoMemory();
    self.inhibitors.appendAssumeCapacity(inhibitor);
}

fn dispatchInhibitor(
    _: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    _ = try generated.zwp_idle_inhibitor_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    );
}

fn destroyInhibitor(
    context: *anyopaque,
    _: *Server.Client,
    _: wayring.ObjectHandle,
) void {
    const inhibitor: *Inhibitor = @ptrCast(@alignCast(context));
    const owner = inhibitor.owner;
    for (owner.inhibitors.items, 0..) |candidate, index| {
        if (candidate != inhibitor) continue;
        _ = owner.inhibitors.orderedRemove(index);
        inhibitor.surface.unreference();
        owner.allocator.destroy(inhibitor);
        return;
    }
    unreachable;
}

test "idle inhibitors allow multiplicity and survive manager and surface destruction" {
    const core = @import("wayring-core");

    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var compositor: CompositorGlobal = undefined;
    try compositor.init(std.testing.allocator, &server);
    defer compositor.deinit();
    var idle_inhibit: IdleInhibitGlobal = undefined;
    try idle_inhibit.init(std.testing.allocator, &server, &compositor);
    defer idle_inhibit.deinit();

    const client = try server.createClient();
    defer server.destroyClient(client) catch unreachable;
    var peer = wayring.Connection.init(
        std.testing.allocator,
        .client,
        wayring.default_max_frame_size,
    );
    defer peer.deinit();
    _ = try core.bootstrapDisplay(&peer);
    const registry: wayring.ObjectHandle = .{
        .id = 2,
        .generation = try core.getRegistry(&peer, 2),
    };
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);

    var compositor_name: u32 = 0;
    var idle_inhibit_name: u32 = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const global = (try core.decodeRegistryEvent(&message, registry.id)).global;
        if (std.mem.eql(u8, global.interface, generated.wl_compositor.name))
            compositor_name = global.name;
        if (std.mem.eql(u8, global.interface, generated.zwp_idle_inhibit_manager_v1.name)) {
            try std.testing.expectEqual(advertised_version, global.version);
            idle_inhibit_name = global.name;
        }
    }
    try std.testing.expect(compositor_name != 0);
    try std.testing.expect(idle_inhibit_name != 0);

    const compositor_resource: wayring.ObjectHandle = .{
        .id = 3,
        .generation = try core.bind(
            &peer,
            registry.id,
            compositor_name,
            generated.wl_compositor.name,
            6,
            3,
            &generated.wl_compositor,
        ),
    };
    const manager: wayring.ObjectHandle = .{
        .id = 4,
        .generation = try core.bind(
            &peer,
            registry.id,
            idle_inhibit_name,
            generated.zwp_idle_inhibit_manager_v1.name,
            advertised_version,
            4,
            &generated.zwp_idle_inhibit_manager_v1,
        ),
    };
    try transferToServer(&peer, client);

    const surface_handle = try generated.wl_compositor_types.requests.create_surface(
        &peer,
        compositor_resource,
    );
    const first = try generated.zwp_idle_inhibit_manager_v1_types.requests.create_inhibitor(
        &peer,
        manager,
        surface_handle,
    );
    const second = try generated.zwp_idle_inhibit_manager_v1_types.requests.create_inhibitor(
        &peer,
        manager,
        surface_handle,
    );
    try generated.zwp_idle_inhibit_manager_v1_types.requests.destroy(&peer, manager);
    try transferToServer(&peer, client);
    try std.testing.expectEqual(Server.ClientState.active, client.state);
    try std.testing.expectEqual(@as(usize, 2), idle_inhibit.inhibitors.items.len);

    const surface = try CompositorGlobal.surfaceFor(client, .{
        .id = surface_handle.id,
        .generation = client.connection.object(surface_handle.id).?.generation,
    });
    var visibility: TestVisibility = .{ .visible = surface };
    try std.testing.expect(idle_inhibit.hasVisibleInhibitor(
        &visibility,
        TestVisibility.isVisible,
    ));

    try generated.zwp_idle_inhibitor_v1_types.requests.destroy(&peer, first);
    try transferToServer(&peer, client);
    try std.testing.expectEqual(@as(usize, 1), idle_inhibit.inhibitors.items.len);
    try std.testing.expect(idle_inhibit.hasVisibleInhibitor(
        &visibility,
        TestVisibility.isVisible,
    ));

    try generated.wl_surface_types.requests.destroy(&peer, surface_handle);
    try transferToServer(&peer, client);
    try std.testing.expect(!surface.resource_alive);
    try std.testing.expect(!idle_inhibit.hasVisibleInhibitor(
        &visibility,
        TestVisibility.isVisible,
    ));

    try generated.zwp_idle_inhibitor_v1_types.requests.destroy(&peer, second);
    try transferToServer(&peer, client);
    try std.testing.expectEqual(Server.ClientState.active, client.state);
    try std.testing.expectEqual(@as(usize, 0), idle_inhibit.inhibitors.items.len);
    try transferFromServer(&peer, client);
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == 1) {
            _ = try core.decodeDisplayEvent(&message);
        } else return error.UnexpectedIdleInhibitEvent;
    }
}

const TestVisibility = struct {
    visible: ?*const CompositorGlobal.Surface = null,

    fn isVisible(context: *anyopaque, surface: *const CompositorGlobal.Surface) bool {
        const self: *TestVisibility = @ptrCast(@alignCast(context));
        return self.visible == surface;
    }
};

fn transferToServer(connection: *wayring.Connection, client: *Server.Client) !void {
    while (connection.nextBatch()) |batch| {
        try client.receive(batch.bytes, batch.fds);
        try connection.acknowledge(batch.token, batch.bytes.len);
    }
}

fn transferFromServer(connection: *wayring.Connection, client: *Server.Client) !void {
    while (client.connection.nextBatch()) |batch| {
        try connection.feed(batch.bytes, batch.fds);
        try client.connection.acknowledge(batch.token, batch.bytes.len);
    }
    try client.outputDrained();
}
