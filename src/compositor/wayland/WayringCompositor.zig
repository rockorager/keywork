//! Scanner-backed Wayring ownership slice for wl_compositor, wl_surface, and
//! wl_shm.
//!
//! This deliberately owns a distinct surface identity namespace. It proves
//! Keywork can consume native Wayring resources without pretending they are
//! libwayland resources; shared surface state begins only after attach and
//! commit contracts have a backend-neutral owner.

const WayringCompositor = @This();

const std = @import("std");
const core = @import("wayring-core-protocol");
const wayring = @import("wayring");
const slot_map = @import("../slot_map.zig");

const server = wayring.server;
const wire = wayring.wire;
const Shm = server.shm.Protocol(core);

const SurfaceIdentity = struct {
    client: *server.Client,
    object_id: u32,
};

const SurfaceStore = slot_map.SlotMap(SurfaceIdentity, enum { wayring_surface });
pub const SurfaceId = SurfaceStore.Id;

const Surface = struct {
    resource: core.wl_surface.Resource,
    id: SurfaceId,
};

const Compositor = struct {
    resource: core.wl_compositor.Resource,
};

const ClientObjects = struct {
    client: *server.Client,
    compositors: std.ArrayList(*Compositor) = .empty,
    surfaces: std.ArrayList(*Surface) = .empty,
};

allocator: std.mem.Allocator,
protocol_server: *server.Server,
global: *const server.Server.Global,
shm: Shm,
clients: std.ArrayList(*ClientObjects) = .empty,
surfaces: SurfaceStore = .{},

pub fn init(self: *WayringCompositor, allocator: std.mem.Allocator, protocol_server: *server.Server) !void {
    self.* = .{
        .allocator = allocator,
        .protocol_server = protocol_server,
        .global = undefined,
        .shm = .init(allocator),
    };
    self.global = try protocol_server.addGlobal(core.wl_compositor, 1, WayringCompositor, self, bind);
    errdefer protocol_server.removeGlobal(self.global) catch {};
    _ = try self.shm.publish(protocol_server, 1);
}

pub fn deinit(self: *WayringCompositor) void {
    std.debug.assert(self.clients.items.len == 0);
    std.debug.assert(self.surfaces.len() == 0);
    self.protocol_server.removeGlobal(self.global) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.shm.deinit();
    self.surfaces.deinit(self.allocator);
    self.clients.deinit(self.allocator);
    self.* = undefined;
}

pub fn destroyClientResources(self: *WayringCompositor, client: *server.Client) void {
    for (self.clients.items, 0..) |objects, index| {
        if (objects.client != client) continue;
        while (objects.surfaces.items.len > 0) {
            self.destroySurface(objects.surfaces.items[objects.surfaces.items.len - 1]);
        }
        while (objects.compositors.items.len > 0) {
            self.destroyCompositor(objects.compositors.items[objects.compositors.items.len - 1]);
        }
        objects.surfaces.deinit(self.allocator);
        objects.compositors.deinit(self.allocator);
        self.allocator.destroy(objects);
        _ = self.clients.orderedRemove(index);
        break;
    }
    self.shm.destroyClientResources(client);
}

pub fn surfaceCount(self: *const WayringCompositor) usize {
    return self.surfaces.len();
}

pub fn containsSurface(self: *const WayringCompositor, id: SurfaceId) bool {
    return self.surfaces.getConst(id) != null;
}

pub fn surfaceId(self: *const WayringCompositor, client: *const server.Client, object_id: u32) ?SurfaceId {
    for (self.clients.items) |objects| {
        if (objects.client != client) continue;
        for (objects.surfaces.items) |surface| {
            if (surface.resource.id() == object_id) return surface.id;
        }
        return null;
    }
    return null;
}

fn bind(client: *server.Client, id: u32, version: u32, self: *WayringCompositor) !void {
    const objects = try self.clientObjects(client);
    try objects.compositors.ensureUnusedCapacity(self.allocator, 1);
    const compositor = try self.allocator.create(Compositor);
    errdefer self.allocator.destroy(compositor);
    compositor.* = .{ .resource = .init(self.allocator, id, version, .client, client.ownerHooks()) };
    errdefer {
        compositor.resource.destroy();
        compositor.resource.deinit();
    }
    try compositor.resource.setHandler(WayringCompositor, self, handleCompositor, null);
    try client.materialize(&compositor.resource.runtime);
    objects.compositors.appendAssumeCapacity(compositor);
}

fn handleCompositor(
    resource: *core.wl_compositor.Resource,
    request: core.wl_compositor.Request,
    self: *WayringCompositor,
) !void {
    switch (request) {
        .create_surface => |create| try self.createSurface(resource, create.id),
        .create_region => {
            const client = self.clientForResource(&resource.runtime) orelse return error.UntrackedClient;
            client.postImplementationError(&resource.runtime, "wl_region is not implemented by the Wayring backend");
        },
        .release => self.destroyCompositor(@fieldParentPtr("resource", resource)),
    }
}

fn createSurface(self: *WayringCompositor, compositor: *core.wl_compositor.Resource, object_id: u32) !void {
    const client = self.clientForResource(&compositor.runtime) orelse return error.UntrackedClient;
    const objects = self.findClient(client) orelse return error.UntrackedClient;
    try objects.surfaces.ensureUnusedCapacity(self.allocator, 1);
    const surface = try self.allocator.create(Surface);
    errdefer self.allocator.destroy(surface);
    surface.resource = .init(self.allocator, object_id, 1, .client, client.ownerHooks());
    errdefer {
        surface.resource.destroy();
        surface.resource.deinit();
    }
    surface.id = try self.surfaces.insert(self.allocator, .{ .client = client, .object_id = object_id });
    errdefer _ = self.surfaces.remove(surface.id);
    try surface.resource.setHandler(WayringCompositor, self, handleSurface, null);
    try client.materialize(&surface.resource.runtime);
    objects.surfaces.appendAssumeCapacity(surface);
}

fn handleSurface(
    resource: *core.wl_surface.Resource,
    request: core.wl_surface.Request,
    self: *WayringCompositor,
) !void {
    switch (request) {
        .destroy => self.destroySurface(@fieldParentPtr("resource", resource)),
        else => {
            const client = self.clientForResource(&resource.runtime) orelse return error.UntrackedClient;
            client.postImplementationError(&resource.runtime, "wl_surface request is not implemented by the Wayring backend");
        },
    }
}

fn clientObjects(self: *WayringCompositor, client: *server.Client) !*ClientObjects {
    if (self.findClient(client)) |objects| return objects;
    const objects = try self.allocator.create(ClientObjects);
    errdefer self.allocator.destroy(objects);
    objects.* = .{ .client = client };
    try self.clients.append(self.allocator, objects);
    return objects;
}

fn findClient(self: *WayringCompositor, client: *const server.Client) ?*ClientObjects {
    for (self.clients.items) |objects| if (objects.client == client) return objects;
    return null;
}

fn clientForResource(self: *WayringCompositor, resource: *server.Resource) ?*server.Client {
    for (self.clients.items) |objects| {
        if (resource.ownedBy(objects.client.ownerHooks())) return objects.client;
    }
    return null;
}

fn destroySurface(self: *WayringCompositor, surface: *Surface) void {
    const identity = self.surfaces.remove(surface.id) orelse unreachable;
    const objects = self.findClient(identity.client) orelse unreachable;
    removePointer(Surface, &objects.surfaces, surface);
    surface.resource.destroy();
    surface.resource.deinit();
    self.allocator.destroy(surface);
}

fn destroyCompositor(self: *WayringCompositor, compositor: *Compositor) void {
    const client = self.clientForResource(&compositor.resource.runtime) orelse unreachable;
    const objects = self.findClient(client) orelse unreachable;
    removePointer(Compositor, &objects.compositors, compositor);
    compositor.resource.destroy();
    compositor.resource.deinit();
    self.allocator.destroy(compositor);
}

fn removePointer(comptime T: type, items: *std.ArrayList(*T), value: *T) void {
    for (items.items, 0..) |candidate, index| {
        if (candidate != value) continue;
        _ = items.orderedRemove(index);
        return;
    }
    unreachable;
}

fn encode(object_id: u32, opcode: u16, descriptor: *const wire.MessageDescriptor, values: []const wire.Value) ![]u8 {
    var output: wire.Output = .init(std.testing.allocator);
    defer output.deinit();
    try output.enqueue(object_id, opcode, descriptor, values);
    const batch = (try output.beginSend()).?;
    const bytes = try std.testing.allocator.dupe(u8, batch.bytes);
    try output.completeSend(batch.token, batch.bytes.len);
    return bytes;
}

fn send(client: *server.Client, object_id: u32, opcode: u16, descriptor: *const wire.MessageDescriptor, values: []const wire.Value) !void {
    const bytes = try encode(object_id, opcode, descriptor, values);
    defer std.testing.allocator.free(bytes);
    try client.receive(bytes, &.{});
    try client.dispatch();
}

fn drain(client: *server.Client) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(std.testing.allocator);
    while (try client.beginSend()) |batch| {
        try bytes.appendSlice(std.testing.allocator, batch.bytes);
        try client.completeSend(batch.token, batch.bytes.len);
    }
    return bytes.toOwnedSlice(std.testing.allocator);
}

fn word(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .native);
}

fn bindCompositor(client: *server.Client, compositor_id: u32) !void {
    try send(client, 1, 1, &core.wl_display.request_messages[1], &.{.{ .new_id = .{ .typed = 2 } }});
    const globals = try drain(client);
    defer std.testing.allocator.free(globals);
    const global_name = word(globals, 8);
    try send(client, 2, 0, &core.wl_registry.request_messages[0], &.{
        .{ .uint = global_name },
        .{ .new_id = .{ .generic = .{ .interface = "wl_compositor", .version = 1, .id = compositor_id } } },
    });
}

test "scanner-backed Keywork compositor owns distinct surface identities" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host);
    defer compositor.deinit();
    const first = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const second = try server.CoreClient.create(std.testing.allocator, &host, .{});
    defer {
        compositor.destroyClientResources(second.client());
        second.destroy();
        compositor.destroyClientResources(first.client());
        first.destroy();
    }

    try bindCompositor(first.client(), 3);
    try bindCompositor(second.client(), 3);
    try send(first.client(), 3, 0, &core.wl_compositor.request_messages[0], &.{.{ .new_id = .{ .typed = 4 } }});
    try send(second.client(), 3, 0, &core.wl_compositor.request_messages[0], &.{.{ .new_id = .{ .typed = 4 } }});
    const first_id = compositor.surfaceId(first.client(), 4).?;
    const second_id = compositor.surfaceId(second.client(), 4).?;
    try std.testing.expect(!std.meta.eql(first_id, second_id));
    try std.testing.expectEqual(@as(usize, 2), compositor.surfaceCount());

    try send(first.client(), 4, 0, &core.wl_surface.request_messages[0], &.{});
    try std.testing.expect(!compositor.containsSurface(first_id));
    try std.testing.expect(compositor.containsSurface(second_id));
    const events = try drain(first.client());
    defer std.testing.allocator.free(events);
    try std.testing.expectEqual(@as(usize, 12), events.len);
    try std.testing.expectEqual(@as(u32, 1), word(events, 0));
    try std.testing.expectEqual(@as(u16, 1), @as(u16, @truncate(word(events, 4))));
    try std.testing.expectEqual(@as(u32, 4), word(events, 8));

    try send(first.client(), 3, 0, &core.wl_compositor.request_messages[0], &.{.{ .new_id = .{ .typed = 4 } }});
    const replacement_id = compositor.surfaceId(first.client(), 4).?;
    try std.testing.expect(!std.meta.eql(first_id, replacement_id));
    try std.testing.expect(!compositor.containsSurface(first_id));
    try std.testing.expect(compositor.containsSurface(replacement_id));

    try send(second.client(), 4, 1, &core.wl_surface.request_messages[1], &.{
        .{ .object = null },
        .{ .int = 0 },
        .{ .int = 0 },
    });
    try std.testing.expectEqual(server.Fatal.Kind.implementation, second.client().fatal().?.kind);
}
