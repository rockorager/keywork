//! Scanner-backed Wayring ownership slice for wl_compositor, wl_surface, and
//! wl_shm.
//!
//! Surfaces use the compositor-wide registry for identity and borrowed render
//! state. Wayring object ownership remains isolated per client; presentation
//! policy is delegated through the minimal optional lifecycle listener.

const WayringCompositor = @This();

const std = @import("std");
const core = @import("wayring-core-protocol");
const wayring = @import("wayring");
const CopiedBufferSnapshot = @import("../CopiedBufferSnapshot.zig");
const Region = @import("../region.zig");
const SurfaceRegistry = @import("../SurfaceRegistry.zig");
const render = @import("../render/types.zig");

const server = wayring.server;
const wire = wayring.wire;
const Shm = server.shm.Protocol(core);

pub const SurfaceId = SurfaceRegistry.Id;

/// Presentation lifecycle copied by init. The context remains borrowed until
/// compositor deinit; callbacks never receive Wayland resources or policy and
/// must not reenter surface lifecycle. During creation rollback, `removing`
/// can resolve the provider through SurfaceRegistry but the Wayring object has
/// not been published in its per-client list.
pub const PresentationListener = struct {
    context: *anyopaque,
    added: *const fn (*anyopaque, SurfaceId) error{OutOfMemory}!void,
    committed: *const fn (*anyopaque, SurfaceId, ?render.Size) void,
    removing: *const fn (*anyopaque, SurfaceId) void,
};

const Surface = struct {
    resource: core.wl_surface.Resource,
    id: SurfaceId,
    pending_attachment: ?PendingAttachment = null,
    has_pending_attachment: bool = false,
    pending_attach_x: i32 = 0,
    pending_attach_y: i32 = 0,
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
surface_registry: *SurfaceRegistry,
presentation_listener: ?PresentationListener,
global: *const server.Server.Global,
shm: Shm,
clients: std.ArrayList(*ClientObjects) = .empty,
owned_provider_count: usize = 0,

/// Borrows the shared registry and copies the optional presentation listener.
/// Both the registry and listener context must outlive this adapter.
pub fn init(
    self: *WayringCompositor,
    allocator: std.mem.Allocator,
    protocol_server: *server.Server,
    surface_registry: *SurfaceRegistry,
    presentation_listener: ?PresentationListener,
) !void {
    self.* = .{
        .allocator = allocator,
        .protocol_server = protocol_server,
        .surface_registry = surface_registry,
        .presentation_listener = presentation_listener,
        .global = undefined,
        .shm = .init(allocator),
    };
    self.global = try protocol_server.addGlobal(core.wl_compositor, 1, WayringCompositor, self, bind);
    errdefer protocol_server.removeGlobal(self.global) catch {};
    _ = try self.shm.publish(protocol_server, 1);
}

pub fn deinit(self: *WayringCompositor) void {
    std.debug.assert(self.clients.items.len == 0);
    std.debug.assert(self.owned_provider_count == 0);
    self.protocol_server.removeGlobal(self.global) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.shm.deinit();
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
    var count: usize = 0;
    for (self.clients.items) |objects| count += objects.surfaces.items.len;
    return count;
}

pub fn containsSurface(self: *const WayringCompositor, id: SurfaceId) bool {
    return self.surfaceForId(id) != null;
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
    const surface = self.surfaceForId(id) orelse return null;
    return if (surface.current) |*current| current else null;
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
    const surface = try self.allocator.create(Surface);
    errdefer self.allocator.destroy(surface);
    surface.* = .{
        .resource = undefined,
        .id = undefined,
        .pending_damage = .init(),
        .source_cache_id = render.allocateSourceCacheId(),
    };
    errdefer surface.pending_damage.deinit();
    surface.id = try self.surface_registry.add(.{
        .context = surface,
        .render_state = surfaceRenderState,
    });
    self.owned_provider_count += 1;
    errdefer {
        self.surface_registry.remove(surface.id);
        self.owned_provider_count -= 1;
    }
    var listener_added = false;
    errdefer if (listener_added) {
        const listener = self.presentation_listener.?;
        listener.removing(listener.context, surface.id);
    };
    if (self.presentation_listener) |listener| {
        try listener.added(listener.context, surface.id);
        listener_added = true;
    }
    try objects.surfaces.ensureUnusedCapacity(self.allocator, 1);
    surface.resource = .init(self.allocator, object_id, 1, .client, client.ownerHooks());
    surface.resource.setHandler(WayringCompositor, self, handleSurface, null) catch unreachable;
    // Dispatch reserved and type-checked this new_id before calling us;
    // materialization only replaces that reservation and cannot allocate.
    client.materialize(&surface.resource.runtime) catch unreachable;
    objects.surfaces.appendAssumeCapacity(surface);
}

fn surfaceRenderState(context: *anyopaque) ?SurfaceRegistry.RenderState {
    const surface: *Surface = @ptrCast(@alignCast(context));
    const current = if (surface.current) |*snapshot| snapshot else return null;
    return .{
        .buffer = current.pixelBuffer(.{}, .{}),
        .logical_size = current.size,
        .source = null,
        .transform = .normal,
        .force_opaque = current.forceOpaque(),
        .alpha_multiplier = std.math.maxInt(u32),
        .opaque_region = null,
        .blur_region = null,
    };
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
    if (resource.version() >= 5 and (x != 0 or y != 0)) {
        client.postProtocolError(&resource.runtime, core.wl_surface.@"error".invalid_offset, "attach offset requires wl_surface.offset");
        return;
    }
    clearPendingAttachment(surface);
    surface.has_pending_attachment = true;
    surface.pending_attach_x = x;
    surface.pending_attach_y = y;
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
        clearPendingAttachment(surface);
        if (surface.current) |*current| current.deinit();
        surface.current = null;
        if (self.presentation_listener) |listener|
            listener.committed(listener.context, surface.id, null);
        return;
    };
    defer clearPendingAttachment(surface);
    var access = pending.pin.access() catch |err| {
        const client = self.clientForResource(&surface.resource.runtime) orelse return error.UntrackedClient;
        client.postImplementationError(&surface.resource.runtime, @errorName(err));
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
        return;
    };
    var candidate_owned = true;
    defer if (candidate_owned) candidate.deinit();
    access.end() catch |err| {
        access_live = false;
        const client = self.clientForResource(&surface.resource.runtime) orelse return error.UntrackedClient;
        client.postImplementationError(&surface.resource.runtime, @errorName(err));
        return;
    };
    access_live = false;
    if (pending.resource) |buffer_resource| self.shm.sendRelease(buffer_resource) catch |err| switch (err) {
        error.ResourceNotLive, error.NotShmBuffer => {},
        else => return err,
    };
    if (surface.current) |*current| current.deinit();
    surface.current = candidate;
    candidate_owned = false;
    surface.next_source_version +%= 1;
    if (self.presentation_listener) |listener|
        listener.committed(listener.context, surface.id, surface.current.?.size);
}

fn clearPendingAttachment(surface: *Surface) void {
    if (surface.pending_attachment) |*pending| {
        pending.deinit();
        surface.pending_attachment = null;
    }
    surface.has_pending_attachment = false;
    surface.pending_attach_x = 0;
    surface.pending_attach_y = 0;
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

fn surfaceForId(self: *const WayringCompositor, id: SurfaceId) ?*Surface {
    for (self.clients.items) |objects| {
        for (objects.surfaces.items) |surface| {
            if (std.meta.eql(surface.id, id)) return surface;
        }
    }
    return null;
}

fn clientForResource(self: *WayringCompositor, resource: *server.Resource) ?*server.Client {
    for (self.clients.items) |objects| {
        if (resource.ownedBy(objects.client.ownerHooks())) return objects.client;
    }
    return null;
}

fn destroySurface(self: *WayringCompositor, surface: *Surface) void {
    const client = self.clientForResource(&surface.resource.runtime) orelse unreachable;
    const objects = self.findClient(client) orelse unreachable;
    if (self.presentation_listener) |listener|
        listener.removing(listener.context, surface.id);
    self.surface_registry.remove(surface.id);
    std.debug.assert(self.owned_provider_count > 0);
    self.owned_provider_count -= 1;
    removePointer(Surface, &objects.surfaces, surface);
    clearPendingAttachment(surface);
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

fn bindShm(self: *WayringCompositor, client: *server.Client, shm_id: u32) !void {
    try send(client, 2, 0, &core.wl_registry.request_messages[0], &.{
        .{ .uint = self.shm.global.?.name() },
        .{ .new_id = .{ .generic = .{ .interface = "wl_shm", .version = 1, .id = shm_id } } },
    });
    const formats = try drain(client);
    defer std.testing.allocator.free(formats);
}

fn createSurfaceResource(client: *server.Client, compositor_id: u32, surface_id: u32) !void {
    try send(client, compositor_id, 0, &core.wl_compositor.request_messages[0], &.{.{ .new_id = .{ .typed = surface_id } }});
}

fn createShmPool(client: *server.Client, shm_id: u32, pool_id: u32, fd: std.posix.fd_t, size: usize) !void {
    try sendWithFds(client, shm_id, 0, &core.wl_shm.request_messages[0], &.{
        .{ .new_id = .{ .typed = pool_id } }, .{ .fd = fd }, .{ .int = @intCast(size) },
    });
}

fn createShmBuffer(
    client: *server.Client,
    pool_id: u32,
    buffer_id: u32,
    offset: usize,
    size: render.Size,
    stride_bytes: usize,
    format: server.shm.Format,
) !void {
    try send(client, pool_id, 0, &core.wl_shm_pool.request_messages[0], &.{
        .{ .new_id = .{ .typed = buffer_id } },
        .{ .int = @intCast(offset) },
        .{ .int = @intCast(size.width) },
        .{ .int = @intCast(size.height) },
        .{ .int = @intCast(stride_bytes) },
        .{ .uint = @intFromEnum(format) },
    });
}

fn attachBuffer(client: *server.Client, surface_id: u32, buffer_id: ?u32) !void {
    try attachBufferAt(client, surface_id, buffer_id, 0, 0);
}

fn attachBufferAt(client: *server.Client, surface_id: u32, buffer_id: ?u32, x: i32, y: i32) !void {
    try send(client, surface_id, 1, &core.wl_surface.request_messages[1], &.{
        .{ .object = buffer_id }, .{ .int = x }, .{ .int = y },
    });
}

fn damageSurface(client: *server.Client, surface_id: u32, rectangle: render.Rect) !void {
    try send(client, surface_id, 2, &core.wl_surface.request_messages[2], &.{
        .{ .int = rectangle.x },
        .{ .int = rectangle.y },
        .{ .int = @intCast(rectangle.width) },
        .{ .int = @intCast(rectangle.height) },
    });
}

fn commitSurfaceResource(client: *server.Client, surface_id: u32) !void {
    try send(client, surface_id, 6, &core.wl_surface.request_messages[6], &.{});
}

// Scanner tests construct exact negotiated versions without changing the
// production global or its v1 child construction policy.
fn replaceSurfaceResourceForTest(
    self: *WayringCompositor,
    client: *server.Client,
    surface: *Surface,
    version: u32,
) !void {
    std.debug.assert(surface.pending_attachment == null);
    std.debug.assert(!surface.has_pending_attachment);
    std.debug.assert(surface.current == null);
    const object_id = surface.resource.id();
    surface.resource.destroy();
    surface.resource.deinit();
    const delete_id = try drain(client);
    defer std.testing.allocator.free(delete_id);
    try std.testing.expectEqual(@as(usize, 12), delete_id.len);
    try std.testing.expectEqual(@as(u32, object_id), word(delete_id, 8));

    surface.resource = .init(self.allocator, object_id, version, .client, client.ownerHooks());
    try surface.resource.setHandler(WayringCompositor, self, handleSurface, null);
    try client.installClientInitial(object_id, &surface.resource.runtime);
}

const SyntheticRegistryProvider = struct {
    pixel: u32,

    fn provider(self: *SyntheticRegistryProvider) SurfaceRegistry.Provider {
        return .{ .context = self, .render_state = renderState };
    }

    fn renderState(context: *anyopaque) ?SurfaceRegistry.RenderState {
        const self: *SyntheticRegistryProvider = @ptrCast(@alignCast(context));
        return .{
            .buffer = .{
                .size = .{ .width = 1, .height = 1 },
                .stride_pixels = 1,
                .pixels = @as([*]u32, @ptrCast(&self.pixel))[0..1],
            },
            .logical_size = .{ .width = 1, .height = 1 },
        };
    }
};

const TestPresentationListener = struct {
    const Event = enum { added, committed, removing };

    registry: *SurfaceRegistry,
    compositor: ?*WayringCompositor = null,
    fail_added: bool = false,
    require_owned_lookup_on_remove: bool = true,
    events: [16]Event = undefined,
    event_count: usize = 0,
    added_count: usize = 0,
    committed_count: usize = 0,
    removing_count: usize = 0,
    last_id: ?SurfaceId = null,
    last_size: ?render.Size = null,
    last_source_cache: ?render.SourceCache = null,
    last_pixel_pointer: ?[*]u32 = null,
    last_first_pixel: ?u32 = null,
    removing_had_render_state: bool = false,

    fn listener(self: *TestPresentationListener) PresentationListener {
        return .{
            .context = self,
            .added = added,
            .committed = committed,
            .removing = removing,
        };
    }

    fn added(context: *anyopaque, id: SurfaceId) error{OutOfMemory}!void {
        const self: *TestPresentationListener = @ptrCast(@alignCast(context));
        std.debug.assert(self.registry.contains(id));
        std.debug.assert(self.registry.renderState(id) == null);
        self.record(.added);
        self.added_count += 1;
        self.last_id = id;
        if (self.fail_added) return error.OutOfMemory;
    }

    fn committed(context: *anyopaque, id: SurfaceId, size: ?render.Size) void {
        const self: *TestPresentationListener = @ptrCast(@alignCast(context));
        std.debug.assert(self.registry.contains(id));
        const state = self.registry.renderState(id);
        if (size) |mapped_size| {
            std.debug.assert(state != null);
            std.debug.assert(std.meta.eql(mapped_size, state.?.logical_size));
            self.last_source_cache = state.?.buffer.source_cache;
            self.last_pixel_pointer = state.?.buffer.pixels.ptr;
            self.last_first_pixel = state.?.buffer.pixels[0];
        } else {
            std.debug.assert(state == null);
            self.last_source_cache = null;
            self.last_pixel_pointer = null;
            self.last_first_pixel = null;
        }
        self.record(.committed);
        self.committed_count += 1;
        self.last_id = id;
        self.last_size = size;
    }

    fn removing(context: *anyopaque, id: SurfaceId) void {
        const self: *TestPresentationListener = @ptrCast(@alignCast(context));
        std.debug.assert(self.registry.contains(id));
        self.removing_had_render_state = self.registry.renderState(id) != null;
        if (self.require_owned_lookup_on_remove) {
            const compositor = self.compositor.?;
            std.debug.assert(compositor.containsSurface(id));
            std.debug.assert((compositor.currentBuffer(id) != null) == self.removing_had_render_state);
        }
        self.record(.removing);
        self.removing_count += 1;
        self.last_id = id;
    }

    fn record(self: *TestPresentationListener, event: Event) void {
        std.debug.assert(self.event_count < self.events.len);
        self.events[self.event_count] = event;
        self.event_count += 1;
    }
};

test "scanner-backed surfaces use canonical registry IDs without Wayring lookup confusion" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var synthetic: SyntheticRegistryProvider = .{ .pixel = 0xff11_2233 };
    const synthetic_id = try surface_registry.add(synthetic.provider());
    defer surface_registry.remove(synthetic_id);
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &surface_registry, null);
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
    try std.testing.expect(!std.meta.eql(first_id, synthetic_id));
    try std.testing.expect(!std.meta.eql(first_id, second_id));
    try std.testing.expect(!compositor.containsSurface(synthetic_id));
    try std.testing.expectEqual(@as(?*CopiedBufferSnapshot, null), compositor.currentBuffer(synthetic_id));
    try std.testing.expectEqual(@as(u32, 0xff11_2233), surface_registry.renderState(synthetic_id).?.buffer.pixels[0]);
    try std.testing.expect(surface_registry.contains(first_id));
    try std.testing.expect(surface_registry.contains(second_id));
    try std.testing.expectEqual(@as(usize, 2), compositor.surfaceCount());

    try send(first.client(), 4, 0, &core.wl_surface.request_messages[0], &.{});
    try std.testing.expect(!compositor.containsSurface(first_id));
    try std.testing.expect(!surface_registry.contains(first_id));
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
    try std.testing.expectEqual(first_id.index, replacement_id.index);
    try std.testing.expect(first_id.generation != replacement_id.generation);
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

test "surface creation OOM before registration leaves no provider or listener entry" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var compositor_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var listener_state: TestPresentationListener = .{ .registry = &surface_registry };
    var compositor: WayringCompositor = undefined;
    try compositor.init(compositor_allocator.allocator(), &host, &surface_registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    try bindCompositor(client, 3);
    const live_before = compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes;
    compositor_allocator.fail_index = compositor_allocator.alloc_index;
    try createSurfaceResource(client, 3, 4);

    try std.testing.expect(compositor_allocator.has_induced_failure);
    try std.testing.expectEqual(server.Fatal.Kind.out_of_memory, client.fatal().?.kind);
    try std.testing.expectEqual(@as(usize, 0), listener_state.added_count);
    try std.testing.expectEqual(@as(usize, 0), listener_state.removing_count);
    try std.testing.expectEqual(@as(usize, 0), compositor.surfaceCount());
    try std.testing.expectEqual(@as(usize, 0), surface_registry.len());
    try std.testing.expect(client.lookup(4) == null);
    try std.testing.expectEqual(live_before, compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes);
}

test "surface registry allocation failure rolls back stable provider context before listener" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var registry_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var surface_registry = SurfaceRegistry.init(registry_allocator.allocator());
    defer surface_registry.deinit();
    var listener_state: TestPresentationListener = .{ .registry = &surface_registry };
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &surface_registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    try bindCompositor(client, 3);
    registry_allocator.fail_index = registry_allocator.alloc_index;
    try createSurfaceResource(client, 3, 4);

    try std.testing.expect(registry_allocator.has_induced_failure);
    try std.testing.expectEqual(server.Fatal.Kind.out_of_memory, client.fatal().?.kind);
    try std.testing.expectEqual(@as(usize, 0), listener_state.added_count);
    try std.testing.expectEqual(@as(usize, 0), listener_state.removing_count);
    try std.testing.expectEqual(@as(usize, 0), compositor.surfaceCount());
    try std.testing.expectEqual(@as(usize, 0), surface_registry.len());
    try std.testing.expect(client.lookup(4) == null);
}

test "listener-added failure unregisters provider without calling removing" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var listener_state: TestPresentationListener = .{
        .registry = &surface_registry,
        .fail_added = true,
        .require_owned_lookup_on_remove = false,
    };
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &surface_registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    try bindCompositor(client, 3);
    try createSurfaceResource(client, 3, 4);

    try std.testing.expectEqual(server.Fatal.Kind.out_of_memory, client.fatal().?.kind);
    try std.testing.expectEqual(@as(usize, 1), listener_state.added_count);
    try std.testing.expectEqual(@as(usize, 0), listener_state.removing_count);
    try std.testing.expectEqualSlices(TestPresentationListener.Event, &.{.added}, listener_state.events[0..listener_state.event_count]);
    try std.testing.expectEqual(@as(usize, 0), compositor.surfaceCount());
    try std.testing.expectEqual(@as(usize, 0), surface_registry.len());
    try std.testing.expect(client.lookup(4) == null);
}

test "post-added resource-list materialization OOM removes listener before provider rollback" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var compositor_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var listener_state: TestPresentationListener = .{
        .registry = &surface_registry,
        .require_owned_lookup_on_remove = false,
    };
    var compositor: WayringCompositor = undefined;
    try compositor.init(compositor_allocator.allocator(), &host, &surface_registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    try bindCompositor(client, 3);
    const live_before = compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes;
    compositor_allocator.fail_index = compositor_allocator.alloc_index + 1;
    try createSurfaceResource(client, 3, 4);

    try std.testing.expect(compositor_allocator.has_induced_failure);
    try std.testing.expectEqual(server.Fatal.Kind.out_of_memory, client.fatal().?.kind);
    try std.testing.expectEqual(@as(usize, 1), listener_state.added_count);
    try std.testing.expectEqual(@as(usize, 1), listener_state.removing_count);
    try std.testing.expectEqualSlices(
        TestPresentationListener.Event,
        &.{ .added, .removing },
        listener_state.events[0..listener_state.event_count],
    );
    try std.testing.expect(!listener_state.removing_had_render_state);
    try std.testing.expectEqual(@as(usize, 0), compositor.surfaceCount());
    try std.testing.expectEqual(@as(usize, 0), surface_registry.len());
    try std.testing.expect(client.lookup(4) == null);
    try std.testing.expectEqual(live_before, compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes);
}

test "scanner pending replacements never release and clean live and destroyed buffer pins" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var compositor_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var listener_state: TestPresentationListener = .{ .registry = &surface_registry };
    var compositor: WayringCompositor = undefined;
    try compositor.init(compositor_allocator.allocator(), &host, &surface_registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    try bindCompositor(client, 3);
    try bindShm(&compositor, client, 4);
    try createSurfaceResource(client, 3, 5);
    const id = compositor.surfaceId(client, 5).?;
    const surface = compositor.surfaceForId(id).?;
    const pixels = [_]u32{ 0xff11_2233, 0xff44_5566 };
    const fd = try memfdWithPixels(&pixels);
    defer _ = std.c.close(fd);
    try createShmPool(client, 4, 6, fd, @sizeOf(@TypeOf(pixels)));
    try createShmBuffer(client, 6, 7, 0, .{ .width = 1, .height = 1 }, @sizeOf(u32), .argb8888);
    try createShmBuffer(client, 6, 8, @sizeOf(u32), .{ .width = 1, .height = 1 }, @sizeOf(u32), .argb8888);

    try attachBuffer(client, 5, 7);
    try attachBuffer(client, 5, 8);
    const no_replacement_release = try drain(client);
    defer std.testing.allocator.free(no_replacement_release);
    try std.testing.expectEqual(@as(usize, 0), no_replacement_release.len);
    try std.testing.expectEqual(client.lookup(8).?, surface.pending_attachment.?.resource.?);
    try std.testing.expect(surface.pending_attachment.?.observer != null);

    const live_before_replaced_destroy = compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes;
    try send(client, 7, 0, &core.wl_buffer.request_messages[0], &.{});
    try std.testing.expectEqual(
        live_before_replaced_destroy - @sizeOf(server.shm.Buffer),
        compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes,
    );
    const replaced_delete_id = try drain(client);
    defer std.testing.allocator.free(replaced_delete_id);
    try std.testing.expectEqual(@as(usize, 12), replaced_delete_id.len);

    try commitSurfaceResource(client, 5);
    const committed_release = try drain(client);
    defer std.testing.allocator.free(committed_release);
    try std.testing.expectEqual(@as(usize, 8), committed_release.len);
    try std.testing.expectEqual(@as(u32, 8), word(committed_release, 0));
    try std.testing.expectEqual(@as(usize, 1), listener_state.committed_count);

    try createShmBuffer(client, 6, 7, 0, .{ .width = 1, .height = 1 }, @sizeOf(u32), .argb8888);
    try attachBuffer(client, 5, 7);
    try attachBuffer(client, 5, null);
    const no_null_replacement_release = try drain(client);
    defer std.testing.allocator.free(no_null_replacement_release);
    try std.testing.expectEqual(@as(usize, 0), no_null_replacement_release.len);
    try std.testing.expect(surface.pending_attachment == null);
    try std.testing.expect(surface.has_pending_attachment);

    const live_before_null_replaced_destroy = compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes;
    try send(client, 7, 0, &core.wl_buffer.request_messages[0], &.{});
    try std.testing.expectEqual(
        live_before_null_replaced_destroy - @sizeOf(server.shm.Buffer),
        compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes,
    );
    const null_replaced_delete_id = try drain(client);
    defer std.testing.allocator.free(null_replaced_delete_id);
    try std.testing.expectEqual(@as(usize, 12), null_replaced_delete_id.len);

    try createShmBuffer(client, 6, 7, 0, .{ .width = 1, .height = 1 }, @sizeOf(u32), .argb8888);
    try attachBuffer(client, 5, 7);
    try send(client, 7, 0, &core.wl_buffer.request_messages[0], &.{});
    try std.testing.expect(surface.pending_attachment != null);
    try std.testing.expect(surface.pending_attachment.?.resource == null);
    try std.testing.expect(surface.pending_attachment.?.observer == null);
    try std.testing.expect(surface.pending_attachment.?.pin.buffer != null);
    const destroyed_pending_delete_id = try drain(client);
    defer std.testing.allocator.free(destroyed_pending_delete_id);
    try std.testing.expectEqual(@as(usize, 12), destroyed_pending_delete_id.len);
    const live_with_destroyed_pending_pin = compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes;

    try attachBuffer(client, 5, null);
    try std.testing.expectEqual(
        live_with_destroyed_pending_pin - @sizeOf(server.shm.Buffer),
        compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes,
    );
    const no_destroyed_replacement_release = try drain(client);
    defer std.testing.allocator.free(no_destroyed_replacement_release);
    try std.testing.expectEqual(@as(usize, 0), no_destroyed_replacement_release.len);
    try commitSurfaceResource(client, 5);
    try std.testing.expect(compositor.currentBuffer(id) == null);
    try std.testing.expectEqual(@as(usize, 2), listener_state.committed_count);
}

test "scanner wl_surface versions 1 through 4 retain legacy pending attach offsets" {
    const Case = struct {
        fn run(version: u32) !void {
            var host: server.Server = .init(std.testing.allocator);
            defer host.deinit();
            var surface_registry = SurfaceRegistry.init(std.testing.allocator);
            defer surface_registry.deinit();
            var compositor: WayringCompositor = undefined;
            try compositor.init(std.testing.allocator, &host, &surface_registry, null);
            defer compositor.deinit();
            const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
            const client = managed.client();
            defer {
                compositor.destroyClientResources(client);
                managed.destroy();
            }

            try bindCompositor(client, 3);
            try bindShm(&compositor, client, 4);
            try createSurfaceResource(client, 3, 5);
            const id = compositor.surfaceId(client, 5).?;
            const surface = compositor.surfaceForId(id).?;
            try compositor.replaceSurfaceResourceForTest(client, surface, version);
            const pixels = [_]u32{0xff11_2233};
            const fd = try memfdWithPixels(&pixels);
            defer _ = std.c.close(fd);
            try createShmPool(client, 4, 6, fd, @sizeOf(@TypeOf(pixels)));
            try createShmBuffer(client, 6, 7, 0, .{ .width = 1, .height = 1 }, @sizeOf(u32), .argb8888);

            try attachBufferAt(client, 5, 7, -7, 9);
            try std.testing.expect(client.fatal() == null);
            try std.testing.expectEqual(version, surface.resource.version());
            try std.testing.expect(surface.has_pending_attachment);
            try std.testing.expectEqual(@as(i32, -7), surface.pending_attach_x);
            try std.testing.expectEqual(@as(i32, 9), surface.pending_attach_y);
            try std.testing.expectEqual(client.lookup(7).?, surface.pending_attachment.?.resource.?);
            const no_events = try drain(client);
            defer std.testing.allocator.free(no_events);
            try std.testing.expectEqual(@as(usize, 0), no_events.len);
        }
    };

    for (1..5) |version| try Case.run(@intCast(version));
}

test "scanner wl_surface version 5 and newer reject attach offsets before mutation" {
    const Case = struct {
        fn run(version: u32) !void {
            var host: server.Server = .init(std.testing.allocator);
            defer host.deinit();
            var compositor_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
            var surface_registry = SurfaceRegistry.init(std.testing.allocator);
            defer surface_registry.deinit();
            var listener_state: TestPresentationListener = .{ .registry = &surface_registry };
            var compositor: WayringCompositor = undefined;
            try compositor.init(compositor_allocator.allocator(), &host, &surface_registry, listener_state.listener());
            defer compositor.deinit();
            listener_state.compositor = &compositor;
            const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
            const client = managed.client();
            defer {
                compositor.destroyClientResources(client);
                managed.destroy();
            }

            try bindCompositor(client, 3);
            try bindShm(&compositor, client, 4);
            try createSurfaceResource(client, 3, 5);
            const id = compositor.surfaceId(client, 5).?;
            const surface = compositor.surfaceForId(id).?;
            try compositor.replaceSurfaceResourceForTest(client, surface, version);
            const pixels = [_]u32{ 0xff11_2233, 0xff44_5566, 0xff77_8899 };
            const fd = try memfdWithPixels(&pixels);
            defer _ = std.c.close(fd);
            try createShmPool(client, 4, 6, fd, @sizeOf(@TypeOf(pixels)));
            try createShmBuffer(client, 6, 7, 0, .{ .width = 1, .height = 1 }, @sizeOf(u32), .argb8888);
            try createShmBuffer(client, 6, 8, @sizeOf(u32), .{ .width = 1, .height = 1 }, @sizeOf(u32), .argb8888);
            try createShmBuffer(client, 6, 9, 2 * @sizeOf(u32), .{ .width = 1, .height = 1 }, @sizeOf(u32), .argb8888);

            try attachBuffer(client, 5, 7);
            try commitSurfaceResource(client, 5);
            const first_release = try drain(client);
            defer std.testing.allocator.free(first_release);
            try std.testing.expectEqual(@as(usize, 8), first_release.len);
            try attachBuffer(client, 5, 8);

            const old_current_pointer = compositor.currentBuffer(id).?.pixels.ptr;
            const old_current_pixels = compositor.currentBuffer(id).?.pixels;
            const old_source_cache = surface_registry.renderState(id).?.buffer.source_cache.?;
            const old_source_version = surface.next_source_version;
            const old_committed_count = listener_state.committed_count;
            const old_event_count = listener_state.event_count;
            const old_pending_resource = surface.pending_attachment.?.resource;
            const old_pending_observer = surface.pending_attachment.?.observer;
            const old_pending_pin = surface.pending_attachment.?.pin.buffer;

            try attachBufferAt(client, 5, 9, 1, -2);

            try std.testing.expectEqual(server.Fatal.Kind.protocol, client.fatal().?.kind);
            try std.testing.expectEqual(@as(?u32, @intCast(core.wl_surface.@"error".invalid_offset)), client.fatal().?.protocol_code);
            try std.testing.expectEqual(@as(u32, 5), client.fatal().?.object_id);
            try std.testing.expectEqual(version, surface.resource.version());
            try std.testing.expect(surface.has_pending_attachment);
            try std.testing.expectEqual(old_pending_resource, surface.pending_attachment.?.resource);
            try std.testing.expectEqual(old_pending_observer, surface.pending_attachment.?.observer);
            try std.testing.expectEqual(old_pending_pin, surface.pending_attachment.?.pin.buffer);
            try std.testing.expectEqual(@as(i32, 0), surface.pending_attach_x);
            try std.testing.expectEqual(@as(i32, 0), surface.pending_attach_y);
            try std.testing.expectEqual(old_current_pointer, compositor.currentBuffer(id).?.pixels.ptr);
            try std.testing.expectEqualSlices(u32, old_current_pixels, compositor.currentBuffer(id).?.pixels);
            try std.testing.expectEqual(old_source_cache, surface_registry.renderState(id).?.buffer.source_cache.?);
            try std.testing.expectEqual(old_source_version, surface.next_source_version);
            try std.testing.expectEqual(old_committed_count, listener_state.committed_count);
            try std.testing.expectEqual(old_event_count, listener_state.event_count);
            try std.testing.expectEqual(old_current_pointer, listener_state.last_pixel_pointer.?);
            try std.testing.expectEqual(old_source_cache, listener_state.last_source_cache.?);

            const live_before_unused_destroy = compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes;
            client.lookup(9).?.destroy();
            try std.testing.expectEqual(
                live_before_unused_destroy - @sizeOf(server.shm.Buffer),
                compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes,
            );
            try std.testing.expectEqual(old_pending_resource, surface.pending_attachment.?.resource);
        }
    };

    try Case.run(5);
    if (core.wl_surface.interface.version > 5) try Case.run(core.wl_surface.interface.version);
}

test "scanner-backed surface commits copied SHM and releases the buffer" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var listener_state: TestPresentationListener = .{ .registry = &surface_registry };
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &surface_registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
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
    const surface = compositor.findClient(client).?.surfaces.items[0];

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
    const render_state = surface_registry.renderState(surface_id).?;
    try std.testing.expectEqual(current.pixels.ptr, render_state.buffer.pixels.ptr);
    try std.testing.expectEqualSlices(u32, current.pixels, render_state.buffer.pixels);
    try std.testing.expectEqual(render.Size{ .width = 2, .height = 1 }, render_state.buffer.size);
    try std.testing.expectEqual(render.Size{ .width = 2, .height = 1 }, render_state.logical_size);
    try std.testing.expectEqual(@as(u32, 2), render_state.buffer.stride_pixels);
    try std.testing.expectEqual(render.SourceCache{ .id = surface.source_cache_id, .version = 1 }, render_state.buffer.source_cache.?);
    try std.testing.expect(render_state.buffer.source_damage == null);
    try std.testing.expect(render_state.source == null);
    try std.testing.expectEqual(render.BufferTransform.normal, render_state.transform);
    try std.testing.expect(render_state.force_opaque);
    try std.testing.expectEqual(std.math.maxInt(u32), render_state.alpha_multiplier);
    try std.testing.expect(render_state.opaque_region == null);
    try std.testing.expect(render_state.blur_region == null);
    try std.testing.expectEqual(@as(usize, 1), listener_state.committed_count);
    try std.testing.expectEqual(render.SourceCache{ .id = surface.source_cache_id, .version = 1 }, listener_state.last_source_cache.?);
    try std.testing.expectEqual(current.pixels.ptr, listener_state.last_pixel_pointer.?);
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
    const second_state = surface_registry.renderState(surface_id).?;
    try std.testing.expectEqual(render.SourceCache{ .id = surface.source_cache_id, .version = 2 }, second_state.buffer.source_cache.?);
    try std.testing.expect(!second_state.force_opaque);
    try std.testing.expectEqual(compositor.currentBuffer(surface_id).?.pixels.ptr, second_state.buffer.pixels.ptr);
    try std.testing.expectEqual(@as(usize, 2), listener_state.committed_count);
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
    try std.testing.expectEqual(render.SourceCache{ .id = surface.source_cache_id, .version = 2 }, surface_registry.renderState(surface_id).?.buffer.source_cache.?);
    try std.testing.expectEqual(@as(usize, 2), listener_state.committed_count);
}

test "listener observes published equal-size resize null and damage-only transactions" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var listener_state: TestPresentationListener = .{ .registry = &surface_registry };
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &surface_registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    try bindCompositor(client, 3);
    try bindShm(&compositor, client, 4);
    try createSurfaceResource(client, 3, 5);
    const id = compositor.surfaceId(client, 5).?;
    const surface = compositor.surfaceForId(id).?;
    try std.testing.expectEqual(@as(usize, 1), listener_state.added_count);
    try std.testing.expect(surface_registry.renderState(id) == null);

    const pixels = [_]u32{
        0xff11_0001,
        0xff11_0002,
        0xff22_0001,
        0xff22_0002,
        0xff33_0001,
        0xff33_0002,
    };
    const fd = try memfdWithPixels(&pixels);
    defer _ = std.c.close(fd);
    try createShmPool(client, 4, 6, fd, @sizeOf(@TypeOf(pixels)));
    try createShmBuffer(client, 6, 7, 0, .{ .width = 2, .height = 1 }, 2 * @sizeOf(u32), .argb8888);
    try createShmBuffer(client, 6, 8, 2 * @sizeOf(u32), .{ .width = 2, .height = 1 }, 2 * @sizeOf(u32), .argb8888);
    try createShmBuffer(client, 6, 9, 4 * @sizeOf(u32), .{ .width = 1, .height = 2 }, @sizeOf(u32), .argb8888);

    try attachBuffer(client, 5, 7);
    try damageSurface(client, 5, .{ .x = 0, .y = 0, .width = 2, .height = 1 });
    try commitSurfaceResource(client, 5);
    const first_release = try drain(client);
    defer std.testing.allocator.free(first_release);
    try std.testing.expectEqual(@as(usize, 8), first_release.len);
    const first_pointer = listener_state.last_pixel_pointer.?;
    const source_id = listener_state.last_source_cache.?.id;
    try std.testing.expectEqual(render.SourceCache{ .id = source_id, .version = 1 }, listener_state.last_source_cache.?);
    try std.testing.expectEqual(@as(u32, pixels[0]), listener_state.last_first_pixel.?);
    try std.testing.expectEqual(@as(usize, 1), listener_state.committed_count);

    try damageSurface(client, 5, .{ .x = 1, .y = 0, .width = 1, .height = 1 });
    try commitSurfaceResource(client, 5);
    try std.testing.expectEqual(@as(usize, 1), listener_state.committed_count);
    try std.testing.expectEqual(first_pointer, compositor.currentBuffer(id).?.pixels.ptr);
    try std.testing.expectEqual(@as(u64, 2), surface.next_source_version);

    try attachBuffer(client, 5, 8);
    try damageSurface(client, 5, .{ .x = 0, .y = 0, .width = 2, .height = 1 });
    try commitSurfaceResource(client, 5);
    const second_release = try drain(client);
    defer std.testing.allocator.free(second_release);
    try std.testing.expectEqual(@as(usize, 8), second_release.len);
    try std.testing.expectEqual(@as(usize, 2), listener_state.committed_count);
    try std.testing.expectEqual(render.Size{ .width = 2, .height = 1 }, listener_state.last_size.?);
    try std.testing.expectEqual(render.SourceCache{ .id = source_id, .version = 2 }, listener_state.last_source_cache.?);
    try std.testing.expectEqual(@as(u32, pixels[2]), listener_state.last_first_pixel.?);
    try std.testing.expect(first_pointer != listener_state.last_pixel_pointer.?);
    try std.testing.expect(surface_registry.renderState(id).?.buffer.source_damage == null);

    try attachBuffer(client, 5, 9);
    try commitSurfaceResource(client, 5);
    const third_release = try drain(client);
    defer std.testing.allocator.free(third_release);
    try std.testing.expectEqual(@as(usize, 8), third_release.len);
    try std.testing.expectEqual(@as(usize, 3), listener_state.committed_count);
    try std.testing.expectEqual(render.Size{ .width = 1, .height = 2 }, listener_state.last_size.?);
    try std.testing.expectEqual(render.SourceCache{ .id = source_id, .version = 3 }, listener_state.last_source_cache.?);
    try std.testing.expectEqualSlices(u32, pixels[4..6], surface_registry.renderState(id).?.buffer.pixels);

    try attachBuffer(client, 5, null);
    try commitSurfaceResource(client, 5);
    try std.testing.expectEqual(@as(usize, 4), listener_state.committed_count);
    try std.testing.expect(listener_state.last_size == null);
    try std.testing.expect(compositor.currentBuffer(id) == null);
    try std.testing.expect(surface_registry.renderState(id) == null);

    try damageSurface(client, 5, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    try commitSurfaceResource(client, 5);
    try std.testing.expectEqual(@as(usize, 4), listener_state.committed_count);
    try std.testing.expectEqualSlices(
        TestPresentationListener.Event,
        &.{ .added, .committed, .committed, .committed, .committed },
        listener_state.events[0..listener_state.event_count],
    );
}

test "scanner-backed release failure cleans pending attachment and preserves current pixels" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var compositor_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var listener_state: TestPresentationListener = .{ .registry = &surface_registry };
    var compositor: WayringCompositor = undefined;
    try compositor.init(compositor_allocator.allocator(), &host, &surface_registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    var client_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const managed = try server.CoreClient.create(client_allocator.allocator(), &host, .{});
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
    const surface = compositor.findClient(client).?.surfaces.items[0];

    const pixels = [_]u32{
        0xff11_2233,
        0xff44_5566,
        0xffaa_bbcc,
        0xffdd_eeff,
    };
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
        .{ .uint = @intFromEnum(server.shm.Format.argb8888) },
    });
    try send(client, 6, 0, &core.wl_shm_pool.request_messages[0], &.{
        .{ .new_id = .{ .typed = 8 } },
        .{ .int = 2 * @sizeOf(u32) },
        .{ .int = 2 },
        .{ .int = 1 },
        .{ .int = 2 * @sizeOf(u32) },
        .{ .uint = @intFromEnum(server.shm.Format.argb8888) },
    });
    try send(client, 5, 1, &core.wl_surface.request_messages[1], &.{
        .{ .object = 7 }, .{ .int = 0 }, .{ .int = 0 },
    });
    try send(client, 5, 6, &core.wl_surface.request_messages[6], &.{});
    const first_release = try drain(client);
    defer std.testing.allocator.free(first_release);
    const old_current = compositor.currentBuffer(surface_id).?;
    const old_pixels = old_current.pixels.ptr;
    const old_version = surface.next_source_version;
    try std.testing.expectEqualSlices(u32, pixels[0..2], old_current.pixels);
    try std.testing.expectEqual(@as(usize, 1), listener_state.committed_count);

    const live_before_attachment = compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes;
    const candidate_resource = client.lookup(8).?;
    try send(client, 5, 1, &core.wl_surface.request_messages[1], &.{
        .{ .object = 8 }, .{ .int = 0 }, .{ .int = 0 },
    });
    try std.testing.expect(surface.has_pending_attachment);
    try std.testing.expect(surface.pending_attachment.?.observer != null);
    try std.testing.expect(compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes > live_before_attachment);

    const commit = try encode(5, 6, &core.wl_surface.request_messages[6], &.{});
    defer std.testing.allocator.free(commit);
    try client.receive(commit, &.{});
    client_allocator.fail_index = client_allocator.alloc_index;
    try client.dispatch();

    try std.testing.expect(client_allocator.has_induced_failure);
    try std.testing.expectEqual(server.Fatal.Kind.implementation, client.fatal().?.kind);
    try std.testing.expect(!surface.has_pending_attachment);
    try std.testing.expect(surface.pending_attachment == null);
    try std.testing.expectEqual(live_before_attachment, compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes);
    const preserved = compositor.currentBuffer(surface_id).?;
    try std.testing.expectEqual(old_pixels, preserved.pixels.ptr);
    try std.testing.expectEqualSlices(u32, pixels[0..2], preserved.pixels);
    try std.testing.expectEqual(old_version, surface.next_source_version);
    try std.testing.expectEqual(@as(usize, 1), listener_state.committed_count);

    const live_before_buffer_destroy = compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes;
    candidate_resource.destroy();
    try std.testing.expectEqual(
        live_before_buffer_destroy - @sizeOf(server.shm.Buffer),
        compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes,
    );
    try std.testing.expect(surface.pending_attachment == null);
    try std.testing.expectEqualSlices(u32, pixels[0..2], compositor.currentBuffer(surface_id).?.pixels);
}

test "copied snapshot OOM preserves published current and suppresses committed" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var compositor_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var listener_state: TestPresentationListener = .{ .registry = &surface_registry };
    var compositor: WayringCompositor = undefined;
    try compositor.init(compositor_allocator.allocator(), &host, &surface_registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    try bindCompositor(client, 3);
    try bindShm(&compositor, client, 4);
    try createSurfaceResource(client, 3, 5);
    const id = compositor.surfaceId(client, 5).?;
    const surface = compositor.surfaceForId(id).?;
    const pixels = [_]u32{ 0xff11_2233, 0xff44_5566 };
    const fd = try memfdWithPixels(&pixels);
    defer _ = std.c.close(fd);
    try createShmPool(client, 4, 6, fd, @sizeOf(@TypeOf(pixels)));
    try createShmBuffer(client, 6, 7, 0, .{ .width = 1, .height = 1 }, @sizeOf(u32), .argb8888);
    try createShmBuffer(client, 6, 8, @sizeOf(u32), .{ .width = 1, .height = 1 }, @sizeOf(u32), .argb8888);

    try attachBuffer(client, 5, 7);
    try commitSurfaceResource(client, 5);
    const first_release = try drain(client);
    defer std.testing.allocator.free(first_release);
    const old_pointer = compositor.currentBuffer(id).?.pixels.ptr;
    const old_source_cache = surface_registry.renderState(id).?.buffer.source_cache.?;
    try std.testing.expectEqual(@as(usize, 1), listener_state.committed_count);

    try attachBuffer(client, 5, 8);
    try std.testing.expect(surface.pending_attachment != null);
    compositor_allocator.fail_index = compositor_allocator.alloc_index;
    try commitSurfaceResource(client, 5);

    try std.testing.expect(compositor_allocator.has_induced_failure);
    try std.testing.expectEqual(server.Fatal.Kind.out_of_memory, client.fatal().?.kind);
    try std.testing.expect(surface.pending_attachment == null);
    try std.testing.expect(!surface.has_pending_attachment);
    try std.testing.expectEqual(old_pointer, compositor.currentBuffer(id).?.pixels.ptr);
    try std.testing.expectEqual(old_source_cache, surface_registry.renderState(id).?.buffer.source_cache.?);
    try std.testing.expectEqual(@as(u64, 2), surface.next_source_version);
    try std.testing.expectEqual(@as(usize, 1), listener_state.committed_count);
}

test "explicit destroy and client disconnect remove listeners once while providers resolve" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var listener_state: TestPresentationListener = .{ .registry = &surface_registry };
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &surface_registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    const first = try server.CoreClient.create(std.testing.allocator, &host, .{});
    var first_live = true;
    defer if (first_live) {
        compositor.destroyClientResources(first.client());
        first.destroy();
    };
    const second = try server.CoreClient.create(std.testing.allocator, &host, .{});
    var second_live = true;
    defer if (second_live) {
        compositor.destroyClientResources(second.client());
        second.destroy();
    };

    try bindCompositor(first.client(), 3);
    try bindShm(&compositor, first.client(), 4);
    try createSurfaceResource(first.client(), 3, 5);
    const first_id = compositor.surfaceId(first.client(), 5).?;
    const first_pixels = [_]u32{0xff11_2233};
    const first_fd = try memfdWithPixels(&first_pixels);
    defer _ = std.c.close(first_fd);
    try createShmPool(first.client(), 4, 6, first_fd, @sizeOf(@TypeOf(first_pixels)));
    try createShmBuffer(first.client(), 6, 7, 0, .{ .width = 1, .height = 1 }, @sizeOf(u32), .argb8888);
    try attachBuffer(first.client(), 5, 7);
    try commitSurfaceResource(first.client(), 5);
    const first_release = try drain(first.client());
    defer std.testing.allocator.free(first_release);

    try bindCompositor(second.client(), 3);
    try bindShm(&compositor, second.client(), 4);
    try createSurfaceResource(second.client(), 3, 5);
    const second_id = compositor.surfaceId(second.client(), 5).?;
    const second_pixels = [_]u32{0xff44_5566};
    const second_fd = try memfdWithPixels(&second_pixels);
    defer _ = std.c.close(second_fd);
    try createShmPool(second.client(), 4, 6, second_fd, @sizeOf(@TypeOf(second_pixels)));
    try createShmBuffer(second.client(), 6, 7, 0, .{ .width = 1, .height = 1 }, @sizeOf(u32), .argb8888);
    try attachBuffer(second.client(), 5, 7);
    try commitSurfaceResource(second.client(), 5);
    const second_release = try drain(second.client());
    defer std.testing.allocator.free(second_release);

    try send(first.client(), 5, 0, &core.wl_surface.request_messages[0], &.{});
    try std.testing.expectEqual(@as(usize, 1), listener_state.removing_count);
    try std.testing.expect(listener_state.removing_had_render_state);
    try std.testing.expect(!surface_registry.contains(first_id));
    try std.testing.expect(!compositor.containsSurface(first_id));
    try std.testing.expect(surface_registry.contains(second_id));

    compositor.destroyClientResources(second.client());
    second.destroy();
    second_live = false;
    try std.testing.expectEqual(@as(usize, 2), listener_state.removing_count);
    try std.testing.expect(listener_state.removing_had_render_state);
    try std.testing.expect(!surface_registry.contains(second_id));
    try std.testing.expectEqual(@as(usize, 0), compositor.surfaceCount());

    compositor.destroyClientResources(first.client());
    first.destroy();
    first_live = false;
    try std.testing.expectEqual(@as(usize, 2), listener_state.removing_count);
    try std.testing.expectEqualSlices(
        TestPresentationListener.Event,
        &.{ .added, .committed, .added, .committed, .removing, .removing },
        listener_state.events[0..listener_state.event_count],
    );
}

test "null listener teardown leaves unrelated registry provider for compositor deinit" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var synthetic: SyntheticRegistryProvider = .{ .pixel = 0xffaa_bbcc };
    const synthetic_id = try surface_registry.add(synthetic.provider());
    var synthetic_live = true;
    defer if (synthetic_live) surface_registry.remove(synthetic_id);
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &surface_registry, null);
    var compositor_live = true;
    defer if (compositor_live) compositor.deinit();
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    var client_live = true;
    defer if (client_live) {
        compositor.destroyClientResources(managed.client());
        managed.destroy();
    };

    try bindCompositor(managed.client(), 3);
    try createSurfaceResource(managed.client(), 3, 4);
    const id = compositor.surfaceId(managed.client(), 4).?;
    try std.testing.expect(surface_registry.contains(id));
    try std.testing.expectEqual(@as(usize, 2), surface_registry.len());

    compositor.destroyClientResources(managed.client());
    managed.destroy();
    client_live = false;
    try std.testing.expect(!surface_registry.contains(id));
    try std.testing.expect(surface_registry.contains(synthetic_id));
    try std.testing.expectEqual(@as(usize, 1), surface_registry.len());

    compositor.deinit();
    compositor_live = false;
    try std.testing.expect(surface_registry.contains(synthetic_id));
    try std.testing.expectEqual(@as(u32, synthetic.pixel), surface_registry.renderState(synthetic_id).?.buffer.pixels[0]);
    surface_registry.remove(synthetic_id);
    synthetic_live = false;
}
