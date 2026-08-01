//! Native `wl_compositor` policy and atomic sans-I/O surface commits.

const CompositorGlobal = @This();

const std = @import("std");
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const render = @import("../render/types.zig");
const surface_geometry = @import("../surface_geometry.zig");
const ShmGlobal = @import("ShmGlobal.zig");
const shm = @import("shm.zig");

const advertised_version: u32 = 6;

allocator: std.mem.Allocator,
server: *Server,
global_name: u32,
commits: std.ArrayList(Commit) = .empty,

pub const BufferAttachment = struct {
    resource: wayring.ObjectHandle,
    buffer: shm.Buffer,

    fn deinit(self: *BufferAttachment) void {
        self.buffer.deinit();
        self.* = undefined;
    }
};

pub const Attachment = union(enum) {
    unchanged,
    removed,
    buffer: BufferAttachment,

    fn deinit(self: *Attachment) void {
        switch (self.*) {
            .buffer => |*buffer| buffer.deinit(),
            .unchanged, .removed => {},
        }
        self.* = undefined;
    }
};

pub const Commit = struct {
    allocator: std.mem.Allocator,
    surface: *Surface,
    attachment: Attachment,
    surface_damage: []render.Rect,
    buffer_damage: []render.Rect,
    frame_callbacks: []wayring.ObjectHandle,
    scale: i32,
    transform: u32,
    offset_x: i32,
    offset_y: i32,
    viewport: surface_geometry.ViewportState,
    frame_finished: bool = false,

    pub fn deinit(self: *Commit) void {
        self.attachment.deinit();
        self.allocator.free(self.surface_damage);
        self.allocator.free(self.buffer_damage);
        self.allocator.free(self.frame_callbacks);
        self.surface.unreference();
        self.* = undefined;
    }

    /// Completes all frame callbacks atomically after the compositor presents
    /// this commit. Callback resources are retired after their done events.
    pub fn finishFrame(self: *Commit, time_milliseconds: u32) !void {
        if (self.frame_finished) return error.FrameAlreadyFinished;
        for (self.frame_callbacks) |callback| {
            try generated.wl_callback_types.events.done(
                &self.surface.client.connection,
                callback,
                time_milliseconds,
            );
            try self.surface.client.destroyResource(callback);
        }
        self.frame_finished = true;
    }

    pub fn releaseBuffer(self: *Commit) !void {
        const attachment = switch (self.attachment) {
            .buffer => |buffer| buffer,
            .unchanged, .removed => return,
        };
        ShmGlobal.releaseBuffer(self.surface.client, attachment.resource) catch |err| switch (err) {
            error.UnknownResource, error.StaleObject => {},
            else => return err,
        };
    }
};

pub const Surface = struct {
    allocator: std.mem.Allocator,
    owner: *CompositorGlobal,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    references: usize = 1,
    resource_alive: bool = true,
    role_owner: ?*const anyopaque = null,
    role_context: ?*anyopaque = null,
    role_destroyed: ?*const fn (*anyopaque) void = null,
    pending_attachment: Attachment = .unchanged,
    pending_surface_damage: std.ArrayList(render.Rect) = .empty,
    pending_buffer_damage: std.ArrayList(render.Rect) = .empty,
    pending_callbacks: std.ArrayList(wayring.ObjectHandle) = .empty,
    pending_scale: i32 = 1,
    current_scale: i32 = 1,
    pending_transform: u32 = 0,
    current_transform: u32 = 0,
    pending_offset_x: i32 = 0,
    pending_offset_y: i32 = 0,
    current_offset_x: i32 = 0,
    current_offset_y: i32 = 0,
    pending_viewport: surface_geometry.ViewportState = .{},
    current_viewport: surface_geometry.ViewportState = .{},

    pub fn setRole(
        self: *Surface,
        owner: *const anyopaque,
        context: *anyopaque,
        destroyed: *const fn (*anyopaque) void,
    ) !void {
        if (self.role_context != null) return error.RoleAlreadyAssigned;
        self.role_owner = owner;
        self.role_context = context;
        self.role_destroyed = destroyed;
    }

    pub fn clearRole(self: *Surface, context: *anyopaque) void {
        std.debug.assert(self.role_context == context);
        self.role_owner = null;
        self.role_context = null;
        self.role_destroyed = null;
    }

    pub fn reference(self: *Surface) !void {
        if (self.references == std.math.maxInt(usize)) return error.ReferenceOverflow;
        self.references += 1;
    }

    pub fn unreference(self: *Surface) void {
        std.debug.assert(self.references > 0);
        self.references -= 1;
        if (self.references != 0) return;
        const client = self.client;
        self.pending_attachment.deinit();
        for (self.pending_callbacks.items) |callback|
            self.client.destroyResource(callback) catch {};
        self.pending_callbacks.deinit(self.allocator);
        self.pending_buffer_damage.deinit(self.allocator);
        self.pending_surface_damage.deinit(self.allocator);
        self.allocator.destroy(self);
        client.unreference();
    }
};

const Region = struct {
    allocator: std.mem.Allocator,
    rectangles: std.ArrayList(render.Rect) = .empty,

    fn deinit(self: *Region) void {
        self.rectangles.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

pub fn init(self: *CompositorGlobal, allocator: std.mem.Allocator, server: *Server) !void {
    self.* = .{
        .allocator = allocator,
        .server = server,
        .global_name = undefined,
    };
    self.global_name = try server.createGlobal(
        &generated.wl_compositor,
        advertised_version,
        .{ .context = self, .bind = bind },
    );
}

pub fn deinit(self: *CompositorGlobal) void {
    self.server.removeGlobal(self.global_name) catch unreachable;
    for (self.commits.items) |*commit| commit.deinit();
    self.commits.deinit(self.allocator);
    self.* = undefined;
}

pub fn popCommit(self: *CompositorGlobal) ?Commit {
    if (self.commits.items.len == 0) return null;
    return self.commits.orderedRemove(0);
}

pub fn surfaceFor(
    client: *const Server.Client,
    handle: wayring.ObjectHandle,
) !*Surface {
    return @ptrCast(@alignCast(
        try client.resourceContext(handle, &generated.wl_surface),
    ));
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *CompositorGlobal = @ptrCast(@alignCast(context));
    _ = client.createResource(id, &generated.wl_compositor, version, .{
        .context = self,
        .dispatch = dispatchCompositor,
    }) catch return client.postNoMemory();
}

fn dispatchCompositor(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const self: *CompositorGlobal = @ptrCast(@alignCast(context));
    switch (try generated.wl_compositor_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .create_surface => |request| {
            const surface = self.allocator.create(Surface) catch
                return client.postNoMemory();
            errdefer self.allocator.destroy(surface);
            client.reference() catch return client.postNoMemory();
            errdefer client.unreference();
            surface.* = .{
                .allocator = self.allocator,
                .owner = self,
                .client = client,
                .resource = undefined,
            };
            const version = @min(
                try client.resourceVersion(resource, &generated.wl_compositor),
                generated.wl_surface.version,
            );
            surface.resource = client.createResource(
                request.id,
                &generated.wl_surface,
                version,
                .{
                    .context = surface,
                    .dispatch = dispatchSurface,
                    .destroy = destroySurface,
                },
            ) catch return client.postNoMemory();
        },
        .create_region => |request| {
            const region = self.allocator.create(Region) catch
                return client.postNoMemory();
            errdefer self.allocator.destroy(region);
            region.* = .{ .allocator = self.allocator };
            const version = @min(
                try client.resourceVersion(resource, &generated.wl_compositor),
                generated.wl_region.version,
            );
            _ = client.createResource(request.id, &generated.wl_region, version, .{
                .context = region,
                .dispatch = dispatchRegion,
                .destroy = destroyRegion,
            }) catch return client.postNoMemory();
        },
        .release => {},
    }
}

fn dispatchSurface(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const surface: *Surface = @ptrCast(@alignCast(context));
    switch (try generated.wl_surface_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .attach => |request| {
            if (try client.resourceVersion(resource, &generated.wl_surface) >= 5 and
                (request.x != 0 or request.y != 0))
            {
                return client.postError(
                    resource,
                    @intFromEnum(generated.wl_surface_types.@"error".invalid_offset),
                    "wl_surface.attach offsets must be zero at version 5 or newer",
                );
            }
            const attachment: Attachment = if (request.buffer) |buffer_id| blk: {
                const object = client.connection.object(buffer_id) orelse
                    return error.UnknownBuffer;
                const handle: wayring.ObjectHandle = .{
                    .id = buffer_id,
                    .generation = object.generation,
                };
                break :blk .{ .buffer = .{
                    .resource = handle,
                    .buffer = try ShmGlobal.cloneBuffer(client, handle),
                } };
            } else .removed;
            surface.pending_attachment.deinit();
            surface.pending_attachment = attachment;
            if (try client.resourceVersion(resource, &generated.wl_surface) < 5) {
                surface.pending_offset_x = request.x;
                surface.pending_offset_y = request.y;
            }
        },
        .damage => |request| try appendDamage(
            surface,
            &surface.pending_surface_damage,
            request.x,
            request.y,
            request.width,
            request.height,
        ),
        .frame => |request| {
            surface.pending_callbacks.ensureUnusedCapacity(surface.allocator, 1) catch
                return client.postNoMemory();
            const callback = client.createResource(
                request.callback,
                &generated.wl_callback,
                1,
                .{ .context = surface },
            ) catch return client.postNoMemory();
            surface.pending_callbacks.appendAssumeCapacity(callback);
        },
        .set_opaque_region, .set_input_region => {},
        .commit => try queueCommit(surface),
        .set_buffer_transform => |request| {
            if (request.transform < 0 or request.transform > 7) return client.postError(
                resource,
                @intFromEnum(generated.wl_surface_types.@"error".invalid_transform),
                "invalid buffer transform",
            );
            surface.pending_transform = @intCast(request.transform);
        },
        .set_buffer_scale => |request| {
            if (request.scale <= 0) return client.postError(
                resource,
                @intFromEnum(generated.wl_surface_types.@"error".invalid_scale),
                "buffer scale must be positive",
            );
            surface.pending_scale = request.scale;
        },
        .damage_buffer => |request| try appendDamage(
            surface,
            &surface.pending_buffer_damage,
            request.x,
            request.y,
            request.width,
            request.height,
        ),
        .offset => |request| {
            surface.pending_offset_x = request.x;
            surface.pending_offset_y = request.y;
        },
        .get_release => |request| {
            const callback = client.createResource(
                request.callback,
                &generated.wl_callback,
                1,
                .{ .context = surface },
            ) catch return client.postNoMemory();
            try generated.wl_callback_types.events.done(
                &client.connection,
                callback,
                0,
            );
            try client.deferResourceDestroy(callback);
        },
    }
}

fn appendDamage(
    surface: *Surface,
    damage: *std.ArrayList(render.Rect),
    x: i32,
    y: i32,
    width: i32,
    height: i32,
) !void {
    if (width <= 0 or height <= 0) return;
    damage.append(surface.allocator, .{
        .x = x,
        .y = y,
        .width = @intCast(width),
        .height = @intCast(height),
    }) catch return surface.client.postNoMemory();
}

fn queueCommit(surface: *Surface) !void {
    const owner = surface.owner;
    owner.commits.ensureUnusedCapacity(owner.allocator, 1) catch
        return surface.client.postNoMemory();
    const surface_damage = owner.allocator.dupe(
        render.Rect,
        surface.pending_surface_damage.items,
    ) catch return surface.client.postNoMemory();
    errdefer owner.allocator.free(surface_damage);
    const buffer_damage = owner.allocator.dupe(
        render.Rect,
        surface.pending_buffer_damage.items,
    ) catch return surface.client.postNoMemory();
    errdefer owner.allocator.free(buffer_damage);
    const frame_callbacks = owner.allocator.dupe(
        wayring.ObjectHandle,
        surface.pending_callbacks.items,
    ) catch return surface.client.postNoMemory();
    errdefer owner.allocator.free(frame_callbacks);
    surface.reference() catch return surface.client.postNoMemory();
    errdefer surface.unreference();

    surface.current_scale = surface.pending_scale;
    surface.current_transform = surface.pending_transform;
    surface.current_offset_x = surface.pending_offset_x;
    surface.current_offset_y = surface.pending_offset_y;
    surface.current_viewport = surface.pending_viewport;
    const attachment = surface.pending_attachment;
    surface.pending_attachment = .unchanged;
    surface.pending_surface_damage.clearRetainingCapacity();
    surface.pending_buffer_damage.clearRetainingCapacity();
    surface.pending_callbacks.clearRetainingCapacity();
    owner.commits.appendAssumeCapacity(.{
        .allocator = owner.allocator,
        .surface = surface,
        .attachment = attachment,
        .surface_damage = surface_damage,
        .buffer_damage = buffer_damage,
        .frame_callbacks = frame_callbacks,
        .scale = surface.current_scale,
        .transform = surface.current_transform,
        .offset_x = surface.current_offset_x,
        .offset_y = surface.current_offset_y,
        .viewport = surface.current_viewport,
    });
}

fn destroySurface(
    context: *anyopaque,
    _: *Server.Client,
    _: wayring.ObjectHandle,
) void {
    const surface: *Surface = @ptrCast(@alignCast(context));
    surface.resource_alive = false;
    if (surface.role_destroyed) |destroyed| destroyed(surface.role_context.?);
    surface.unreference();
}

fn dispatchRegion(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const region: *Region = @ptrCast(@alignCast(context));
    switch (try generated.wl_region_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .add => |request| if (request.width > 0 and request.height > 0) {
            region.rectangles.append(region.allocator, .{
                .x = request.x,
                .y = request.y,
                .width = @intCast(request.width),
                .height = @intCast(request.height),
            }) catch return client.postNoMemory();
        },
        .subtract => {},
    }
}

fn destroyRegion(
    context: *anyopaque,
    _: *Server.Client,
    _: wayring.ObjectHandle,
) void {
    const region: *Region = @ptrCast(@alignCast(context));
    region.deinit();
}

test "native surfaces queue atomic damage-aware SHM commits" {
    const core = @import("wayring-core");
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var shm_global: ShmGlobal = undefined;
    try shm_global.init(std.testing.allocator, &server);
    defer shm_global.deinit();
    var compositor: CompositorGlobal = undefined;
    try compositor.init(std.testing.allocator, &server);
    defer compositor.deinit();
    const client = try server.createClient();

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
    var shm_name: u32 = 0;
    var compositor_name: u32 = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const global = (try core.decodeRegistryEvent(&message, registry.id)).global;
        if (std.mem.eql(u8, global.interface, generated.wl_shm.name)) shm_name = global.name;
        if (std.mem.eql(u8, global.interface, generated.wl_compositor.name))
            compositor_name = global.name;
    }
    const shm_resource: wayring.ObjectHandle = .{
        .id = 3,
        .generation = try core.bind(
            &peer,
            registry.id,
            shm_name,
            generated.wl_shm.name,
            2,
            3,
            &generated.wl_shm,
        ),
    };
    const compositor_resource: wayring.ObjectHandle = .{
        .id = 4,
        .generation = try core.bind(
            &peer,
            registry.id,
            compositor_name,
            generated.wl_compositor.name,
            6,
            4,
            &generated.wl_compositor,
        ),
    };
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    while (peer.popMessage()) |popped| {
        var message = popped;
        message.deinit();
    }

    const fd = try std.posix.memfd_create("keywork-surface-test", std.os.linux.MFD.CLOEXEC);
    var fd_owned = true;
    defer if (fd_owned) {
        _ = std.os.linux.close(fd);
    };
    if (std.os.linux.errno(std.os.linux.ftruncate(fd, 64)) != .SUCCESS)
        return error.TruncateFailed;
    const pool = try generated.wl_shm_types.requests.create_pool(
        &peer,
        shm_resource,
        fd,
        64,
    );
    fd_owned = false;
    const buffer = try generated.wl_shm_pool_types.requests.create_buffer(
        &peer,
        pool,
        0,
        4,
        4,
        16,
        @intFromEnum(shm.Format.xrgb8888),
    );
    const surface = try generated.wl_compositor_types.requests.create_surface(
        &peer,
        compositor_resource,
    );
    try generated.wl_surface_types.requests.attach(&peer, surface, buffer, 0, 0);
    try generated.wl_surface_types.requests.damage_buffer(&peer, surface, 1, 2, 2, 1);
    const callback = try generated.wl_surface_types.requests.frame(&peer, surface);
    try generated.wl_surface_types.requests.commit(&peer, surface);
    try transferToServer(&peer, client);

    var commit = compositor.popCommit() orelse return error.MissingCommit;
    defer commit.deinit();
    try std.testing.expectEqual(surface.id, commit.surface.resource.id);
    try std.testing.expectEqualSlices(
        render.Rect,
        &.{.{ .x = 1, .y = 2, .width = 2, .height = 1 }},
        commit.buffer_damage,
    );
    try std.testing.expectEqual(callback.id, commit.frame_callbacks[0].id);
    try commit.releaseBuffer();
    try commit.finishFrame(42);
    try transferFromServer(&peer, client);
    var got_release = false;
    var got_frame = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == buffer.id) {
            _ = try generated.wl_buffer_types.decodeEvent(&peer, buffer, &message);
            got_release = true;
        } else if (message.object_id == callback.id) {
            _ = try generated.wl_callback_types.decodeEvent(&peer, callback, &message);
            got_frame = true;
        } else {
            _ = try core.decodeDisplayEvent(&message);
        }
    }
    try std.testing.expect(got_release);
    try std.testing.expect(got_frame);
}

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
