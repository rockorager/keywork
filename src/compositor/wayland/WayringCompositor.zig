//! Scanner-backed Wayring ownership slice for wl_compositor, wl_surface, and
//! wl_shm.
//!
//! This deliberately owns a distinct surface identity namespace. Copied SHM
//! commits use the compositor's protocol-neutral snapshot contract, while
//! render-tree integration and other surface state remain separate from the
//! libwayland implementation.

const WayringCompositor = @This();

const std = @import("std");
const core = @import("wayring-core-protocol");
const wayring = @import("wayring");
const slot_map = @import("../slot_map.zig");
const CopiedBufferSnapshot = @import("CopiedBufferSnapshot.zig");
const Region = @import("../region.zig");
const render = @import("../render/types.zig");

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
    pending_attachment: ?PendingAttachment = null,
    has_pending_attachment: bool = false,
    pending_damage: Region,
    current: ?CopiedBufferSnapshot = null,
    source_cache_id: u64,
    next_source_version: u64 = 1,
};

const PendingAttachment = struct {
    pin: server.shm.Buffer.Pin,
    resource: ?*server.Resource,
    observer: ?*server.Resource.Observer = null,

    fn bufferDestroyed(self: *PendingAttachment, _: *server.Resource, _: *server.Resource.Observer) void {
        self.resource = null;
        self.observer = null;
    }

    fn deinit(self: *PendingAttachment) void {
        if (self.observer) |observer| server.Resource.removeDestroyObserver(observer);
        self.pin.deinit();
        self.* = undefined;
    }
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

pub fn currentBuffer(self: *WayringCompositor, id: SurfaceId) ?*CopiedBufferSnapshot {
    const identity = self.surfaces.getConst(id) orelse return null;
    const objects = self.findClient(identity.client) orelse return null;
    for (objects.surfaces.items) |surface| {
        if (!std.meta.eql(surface.id, id)) continue;
        return if (surface.current) |*current| current else null;
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
    surface.* = .{
        .resource = .init(self.allocator, object_id, 1, .client, client.ownerHooks()),
        .id = undefined,
        .pending_damage = .init(),
        .source_cache_id = render.allocateSourceCacheId(),
    };
    errdefer surface.pending_damage.deinit();
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
        .attach => |attach| try self.attachSurface(resource, attach.buffer, attach.x, attach.y),
        .damage => |damage| {
            if (damage.width > 0 and damage.height > 0) {
                const surface: *Surface = @fieldParentPtr("resource", resource);
                try surface.pending_damage.add(damage.x, damage.y, damage.width, damage.height);
            }
        },
        .commit => try self.commitSurface(@fieldParentPtr("resource", resource)),
        else => {
            const client = self.clientForResource(&resource.runtime) orelse return error.UntrackedClient;
            client.postImplementationError(&resource.runtime, "wl_surface request is not implemented by the Wayring backend");
        },
    }
}

fn attachSurface(
    self: *WayringCompositor,
    resource: *core.wl_surface.Resource,
    buffer_id: ?u32,
    x: i32,
    y: i32,
) !void {
    const client = self.clientForResource(&resource.runtime) orelse return error.UntrackedClient;
    const surface: *Surface = @fieldParentPtr("resource", resource);
    self.clearPendingAttachment(surface, true);
    surface.has_pending_attachment = true;
    if (x != 0 or y != 0) {
        client.postProtocolError(&resource.runtime, core.wl_surface.@"error".invalid_offset, "wl_surface.attach offset requires version 5");
        return;
    }
    const id = buffer_id orelse return;
    const buffer_resource = client.lookup(id) orelse {
        client.postImplementationError(&resource.runtime, "wl_surface.attach references an unknown buffer");
        return;
    };
    const pin = self.shm.pin(buffer_resource) orelse {
        client.postImplementationError(&resource.runtime, "wl_surface.attach supports only Wayring wl_shm buffers");
        return;
    };
    surface.pending_attachment = .{ .pin = pin, .resource = buffer_resource };
    errdefer {
        surface.pending_attachment.?.deinit();
        surface.pending_attachment = null;
    }
    surface.pending_attachment.?.observer = try buffer_resource.addDestroyObserver(
        PendingAttachment,
        &surface.pending_attachment.?,
        PendingAttachment.bufferDestroyed,
    );
}

fn commitSurface(self: *WayringCompositor, surface: *Surface) !void {
    defer surface.pending_damage.clear();
    if (!surface.has_pending_attachment) return;
    surface.has_pending_attachment = false;
    const pending = if (surface.pending_attachment) |*attachment| attachment else {
        if (surface.current) |*current| current.deinit();
        surface.current = null;
        return;
    };
    var access = pending.pin.access() catch |err| {
        const client = self.clientForResource(&surface.resource.runtime) orelse return error.UntrackedClient;
        client.postImplementationError(&surface.resource.runtime, @errorName(err));
        self.clearPendingAttachment(surface, false);
        return;
    };
    var access_live = true;
    defer if (access_live) access.end() catch {};
    const geometry = access.geometry;
    const source_cache: render.SourceCache = .{
        .id = surface.source_cache_id,
        .version = surface.next_source_version,
    };
    var candidate = CopiedBufferSnapshot.copy(
        self.allocator,
        .{
            .bytes = access.bytes,
            .size = .{ .width = @intCast(geometry.width), .height = @intCast(geometry.height) },
            .stride_bytes = geometry.stride,
            .format = switch (geometry.format) {
                .argb8888 => .argb8888,
                .xrgb8888 => .xrgb8888,
            },
        },
        null,
        &surface.pending_damage,
        source_cache,
    ) catch |err| {
        const client = self.clientForResource(&surface.resource.runtime) orelse return error.UntrackedClient;
        if (err == error.OutOfMemory) client.postOutOfMemory(&surface.resource.runtime, "copying wl_shm surface buffer") else client.postImplementationError(&surface.resource.runtime, @errorName(err));
        self.clearPendingAttachment(surface, false);
        return;
    };
    var candidate_owned = true;
    defer if (candidate_owned) candidate.deinit();
    access.end() catch |err| {
        access_live = false;
        const client = self.clientForResource(&surface.resource.runtime) orelse return error.UntrackedClient;
        client.postImplementationError(&surface.resource.runtime, @errorName(err));
        self.clearPendingAttachment(surface, false);
        return;
    };
    access_live = false;
    if (pending.resource) |buffer_resource| self.shm.sendRelease(buffer_resource) catch |err| switch (err) {
        error.ResourceNotLive, error.NotShmBuffer => {},
        else => return err,
    };
    self.clearPendingAttachment(surface, false);
    if (surface.current) |*current| current.deinit();
    surface.current = candidate;
    candidate_owned = false;
    surface.next_source_version +%= 1;
}

fn clearPendingAttachment(self: *WayringCompositor, surface: *Surface, release: bool) void {
    if (surface.pending_attachment) |*pending| {
        if (release) if (pending.resource) |resource| self.shm.sendRelease(resource) catch {};
        pending.deinit();
        surface.pending_attachment = null;
    }
    surface.has_pending_attachment = false;
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
    self.clearPendingAttachment(surface, false);
    if (surface.current) |*current| current.deinit();
    surface.pending_damage.deinit();
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

fn sendWithFds(client: *server.Client, object_id: u32, opcode: u16, descriptor: *const wire.MessageDescriptor, values: []const wire.Value) !void {
    var output: wire.Output = .init(std.testing.allocator);
    defer output.deinit();
    try output.enqueue(object_id, opcode, descriptor, values);
    const batch = (try output.beginSend()).?;
    var receiver_fds: std.ArrayList(wire.FileDescriptor) = .empty;
    defer receiver_fds.deinit(std.testing.allocator);
    try receiver_fds.ensureUnusedCapacity(std.testing.allocator, batch.fds.len);
    errdefer {
        for (receiver_fds.items) |fd| _ = std.c.close(fd);
    }
    for (batch.fds) |fd| {
        const duplicate = std.c.fcntl(fd, std.c.F.DUPFD_CLOEXEC, @as(c_int, 0));
        if (duplicate < 0) return error.Unexpected;
        receiver_fds.appendAssumeCapacity(duplicate);
    }
    try client.receive(batch.bytes, receiver_fds.items);
    receiver_fds.clearRetainingCapacity();
    try output.completeSend(batch.token, batch.bytes.len);
    try client.dispatch();
}

fn memfdWithPixels(pixels: []const u32) !std.posix.fd_t {
    const bytes = std.mem.sliceAsBytes(pixels);
    const fd = try std.posix.memfd_create("keywork-wayring-surface", std.os.linux.MFD.CLOEXEC);
    errdefer _ = std.c.close(fd);
    if (std.os.linux.errno(std.os.linux.ftruncate(fd, @intCast(bytes.len))) != .SUCCESS) return error.Unexpected;
    const written = std.c.write(fd, bytes.ptr, bytes.len);
    if (written != bytes.len) return error.Unexpected;
    return fd;
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
    try send(second.client(), 4, 6, &core.wl_surface.request_messages[6], &.{});
    try std.testing.expect(second.client().fatal() == null);
    try std.testing.expectEqual(@as(?*CopiedBufferSnapshot, null), compositor.currentBuffer(second_id));
}

test "scanner-backed surface commits copied SHM and releases the buffer" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host);
    defer compositor.deinit();
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    try bindCompositor(client, 3);
    try send(client, 2, 0, &core.wl_registry.request_messages[0], &.{
        .{ .uint = compositor.shm.global.?.name() },
        .{ .new_id = .{ .generic = .{ .interface = "wl_shm", .version = 1, .id = 4 } } },
    });
    const formats = try drain(client);
    defer std.testing.allocator.free(formats);
    try send(client, 3, 0, &core.wl_compositor.request_messages[0], &.{.{ .new_id = .{ .typed = 5 } }});
    const surface_id = compositor.surfaceId(client, 5).?;

    const pixels = [_]u32{ 0x0011_2233, 0x0044_5566 };
    const fd = try memfdWithPixels(&pixels);
    defer _ = std.c.close(fd);
    try sendWithFds(client, 4, 0, &core.wl_shm.request_messages[0], &.{
        .{ .new_id = .{ .typed = 6 } }, .{ .fd = fd }, .{ .int = @intCast(@sizeOf(@TypeOf(pixels))) },
    });
    try send(client, 6, 0, &core.wl_shm_pool.request_messages[0], &.{
        .{ .new_id = .{ .typed = 7 } },
        .{ .int = 0 },
        .{ .int = 2 },
        .{ .int = 1 },
        .{ .int = 2 * @sizeOf(u32) },
        .{ .uint = @intFromEnum(server.shm.Format.xrgb8888) },
    });
    try send(client, 5, 1, &core.wl_surface.request_messages[1], &.{
        .{ .object = 7 }, .{ .int = 0 }, .{ .int = 0 },
    });
    try send(client, 5, 2, &core.wl_surface.request_messages[2], &.{
        .{ .int = 0 }, .{ .int = 0 }, .{ .int = 2 }, .{ .int = 1 },
    });
    try send(client, 5, 6, &core.wl_surface.request_messages[6], &.{});

    const current = compositor.currentBuffer(surface_id).?;
    try std.testing.expect(current.forceOpaque());
    try std.testing.expectEqualSlices(u32, &.{ 0xff11_2233, 0xff44_5566 }, current.pixels);
    const release = try drain(client);
    defer std.testing.allocator.free(release);
    try std.testing.expectEqual(@as(usize, 8), release.len);
    try std.testing.expectEqual(@as(u32, 7), word(release, 0));

    try send(client, 6, 0, &core.wl_shm_pool.request_messages[0], &.{
        .{ .new_id = .{ .typed = 8 } },
        .{ .int = 0 },
        .{ .int = 2 },
        .{ .int = 1 },
        .{ .int = 2 * @sizeOf(u32) },
        .{ .uint = @intFromEnum(server.shm.Format.argb8888) },
    });
    try send(client, 5, 1, &core.wl_surface.request_messages[1], &.{
        .{ .object = 8 }, .{ .int = 0 }, .{ .int = 0 },
    });
    try send(client, 8, 0, &core.wl_buffer.request_messages[0], &.{});
    const delete_id = try drain(client);
    defer std.testing.allocator.free(delete_id);
    try send(client, 5, 6, &core.wl_surface.request_messages[6], &.{});
    try std.testing.expectEqualSlices(u32, &pixels, compositor.currentBuffer(surface_id).?.pixels);
    const no_release = try drain(client);
    defer std.testing.allocator.free(no_release);
    try std.testing.expectEqual(@as(usize, 0), no_release.len);

    try send(client, 6, 0, &core.wl_shm_pool.request_messages[0], &.{
        .{ .new_id = .{ .typed = 8 } },
        .{ .int = 0 },
        .{ .int = 2 },
        .{ .int = 1 },
        .{ .int = 2 * @sizeOf(u32) },
        .{ .uint = @intFromEnum(server.shm.Format.argb8888) },
    });
    try send(client, 5, 1, &core.wl_surface.request_messages[1], &.{
        .{ .object = 8 }, .{ .int = 0 }, .{ .int = 0 },
    });
    if (std.os.linux.errno(std.os.linux.ftruncate(fd, 0)) != .SUCCESS) return error.Unexpected;
    try send(client, 5, 6, &core.wl_surface.request_messages[6], &.{});
    try std.testing.expectEqual(server.Fatal.Kind.implementation, client.fatal().?.kind);
    try std.testing.expectEqualSlices(u32, &pixels, compositor.currentBuffer(surface_id).?.pixels);
}
