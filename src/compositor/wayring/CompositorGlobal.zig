//! Native `wl_compositor` policy and atomic sans-I/O surface commits.

const CompositorGlobal = @This();

const std = @import("std");
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const Region = @import("../region.zig");
const render = @import("../render/types.zig");
const DrmSyncobj = @import("../drm_syncobj.zig");
const presentation = @import("../presentation.zig");
const surface_geometry = @import("../surface_geometry.zig");
const ShmGlobal = @import("ShmGlobal.zig");
const shm = @import("shm.zig");
const BufferResource = @import("BufferResource.zig");

const advertised_version: u32 = 6;

allocator: std.mem.Allocator,
server: *Server,
global_name: u32,
transactions: std.ArrayList(Transaction) = .empty,
hierarchy_handler: ?HierarchyHandler = null,

pub const BufferAttachment = struct {
    resource: wayring.ObjectHandle,
    buffer: *BufferResource,

    fn release(self: *const BufferAttachment, client: *Server.Client) !void {
        if (!self.buffer.isLastUse()) return;
        ShmGlobal.releaseBuffer(client, self.resource) catch |err| switch (err) {
            error.UnknownResource, error.StaleObject => {},
            else => return err,
        };
    }

    fn deinit(self: *BufferAttachment) void {
        self.buffer.unreference();
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

    fn releaseBuffer(self: *const Attachment, client: *Server.Client) !void {
        switch (self.*) {
            .buffer => |*buffer| try buffer.release(client),
            .unchanged, .removed => {},
        }
    }
};

pub const Commit = struct {
    allocator: std.mem.Allocator,
    surface: *Surface,
    attachment: Attachment,
    surface_damage: []render.Rect,
    buffer_damage: []render.Rect,
    frame_callbacks: []wayring.ObjectHandle,
    presentation_feedbacks: []*PresentationFeedback,
    content_type: ContentType,
    alpha_multiplier: u32,
    presentation_hint: PresentationHint,
    scale: i32,
    transform: u32,
    offset_x: i32,
    offset_y: i32,
    viewport: surface_geometry.ViewportState,
    opaque_region: Region,
    input_region: InputRegion,
    synchronization: ?DrmSyncobj.Commit = null,

    pub fn deinit(self: *Commit) void {
        if (self.synchronization) |*synchronization| {
            _ = synchronization.release.signal();
            synchronization.deinit();
        }
        self.attachment.deinit();
        self.allocator.free(self.surface_damage);
        self.allocator.free(self.buffer_damage);
        self.allocator.free(self.frame_callbacks);
        if (self.presentation_feedbacks.len != 0) {
            for (self.presentation_feedbacks) |feedback| feedback.discarded(feedback.context);
            self.surface.unreference();
        }
        self.allocator.free(self.presentation_feedbacks);
        self.opaque_region.deinit();
        self.input_region.deinit();
        self.surface.unreference();
        self.* = undefined;
    }

    pub fn releaseBuffer(self: *Commit) !void {
        try self.attachment.releaseBuffer(self.surface.client);
    }

    /// Transfers this commit's callbacks so an output scheduler can retain
    /// them until it actually accepts a frame. The returned batch owns one
    /// surface reference and the callback slice.
    pub fn takeFrameCallbacks(self: *Commit) !?FrameCallbacks {
        if (self.frame_callbacks.len == 0) return null;
        try self.surface.reference();
        const callbacks = self.frame_callbacks;
        self.frame_callbacks = &.{};
        return .{
            .allocator = self.allocator,
            .surface = self.surface,
            .callbacks = callbacks,
        };
    }

    /// Transfers this commit's presentation feedback so the output scheduler
    /// can retain it until the sampled frame is presented or discarded.
    pub fn takePresentationFeedbacks(self: *Commit) ?PresentationFeedbacks {
        if (self.presentation_feedbacks.len == 0) return null;
        const feedbacks = self.presentation_feedbacks;
        self.presentation_feedbacks = &.{};
        return .{
            .allocator = self.allocator,
            .surface = self.surface,
            .feedbacks = feedbacks,
        };
    }
};

pub const FrameCallbacks = struct {
    allocator: std.mem.Allocator,
    surface: *Surface,
    callbacks: []wayring.ObjectHandle,
    finished: bool = false,

    pub fn finish(self: *FrameCallbacks, time_milliseconds: u32) !void {
        if (self.finished) return error.FrameAlreadyFinished;
        if (self.surface.client.state == .active) {
            for (self.callbacks) |callback| {
                try generated.wl_callback_types.events.done(
                    &self.surface.client.connection,
                    callback,
                    time_milliseconds,
                );
                self.surface.client.destroyResource(callback) catch |err| switch (err) {
                    error.UnknownResource, error.StaleObject => {},
                    else => return err,
                };
            }
        }
        self.finished = true;
    }

    pub fn deinit(self: *FrameCallbacks) void {
        if (!self.finished and self.surface.client.state == .active) {
            for (self.callbacks) |callback|
                self.surface.client.destroyResource(callback) catch {};
        }
        self.allocator.free(self.callbacks);
        self.surface.unreference();
        self.* = undefined;
    }
};

/// The pending surface, commit, or output batch retains this caller-owned
/// callback until exactly one terminal method runs.
pub const PresentationFeedback = struct {
    context: *anyopaque,
    presented: *const fn (*anyopaque, *anyopaque, presentation.Info) void,
    discarded: *const fn (*anyopaque) void,
};

pub const PresentationFeedbacks = struct {
    allocator: std.mem.Allocator,
    surface: *Surface,
    feedbacks: []*PresentationFeedback,
    finished: bool = false,

    pub fn presented(
        self: *PresentationFeedbacks,
        output_context: *anyopaque,
        info: presentation.Info,
    ) void {
        std.debug.assert(!self.finished);
        self.finished = true;
        for (self.feedbacks) |feedback|
            feedback.presented(feedback.context, output_context, info);
    }

    pub fn discard(self: *PresentationFeedbacks) void {
        if (self.finished) return;
        self.finished = true;
        for (self.feedbacks) |feedback| feedback.discarded(feedback.context);
    }

    pub fn deinit(self: *PresentationFeedbacks) void {
        self.discard();
        self.allocator.free(self.feedbacks);
        self.surface.unreference();
        self.* = undefined;
    }
};

/// An owned atomic surface-state update. Entries are independently prepared,
/// but are applied and presented together.
pub const Transaction = struct {
    allocator: std.mem.Allocator,
    root: *Surface,
    entries: []Commit,
    hierarchy_updates: []HierarchyUpdate,

    pub fn init(allocator: std.mem.Allocator, root: *Surface, entries: []Commit, updates: []HierarchyUpdate) !Transaction {
        try root.reference();
        return .{ .allocator = allocator, .root = root, .entries = entries, .hierarchy_updates = updates };
    }

    pub fn deinit(self: *Transaction) void {
        for (self.hierarchy_updates) |update| update.deinit(update.context);
        self.allocator.free(self.hierarchy_updates);
        for (self.entries) |*commit| commit.deinit();
        self.allocator.free(self.entries);
        self.root.unreference();
        self.* = undefined;
    }

    pub fn releaseBuffers(self: *Transaction) void {
        for (self.entries) |*commit| commit.releaseBuffer() catch {};
    }
};

pub const HierarchyUpdate = struct {
    context: *anyopaque,
    apply: *const fn (*anyopaque) void,
    deinit: *const fn (*anyopaque) void,
};

pub const HierarchyHandler = struct {
    context: *anyopaque,
    commit: *const fn (*anyopaque, Commit) anyerror!void,
    surface_destroyed: *const fn (*anyopaque, *Surface) void,
};

pub const PendingAttachment = enum {
    none,
    null_buffer,
    dmabuf,
    unsupported,
};

pub const ExplicitSyncHandler = struct {
    context: *anyopaque,
    validate_commit: *const fn (*anyopaque, PendingAttachment) bool,
    take_pending: *const fn (*anyopaque) DrmSyncobj.Commit,
    surface_destroyed: *const fn (*anyopaque) void,
};

pub const ContentTypeHandler = struct {
    context: *anyopaque,
    surface_destroyed: *const fn (*anyopaque) void,
};

pub const ContentType = generated.wp_content_type_v1_types.type;

pub const AlphaModifierHandler = struct {
    context: *anyopaque,
    surface_destroyed: *const fn (*anyopaque) void,
};

pub const TearingControlHandler = struct {
    context: *anyopaque,
    surface_destroyed: *const fn (*anyopaque) void,
};

pub const PresentationHint = generated.wp_tearing_control_v1_types.presentation_hint;

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
    explicit_sync_handler: ?ExplicitSyncHandler = null,
    content_type_handler: ?ContentTypeHandler = null,
    alpha_modifier_handler: ?AlphaModifierHandler = null,
    tearing_control_handler: ?TearingControlHandler = null,
    pending_attachment: Attachment = .unchanged,
    pending_surface_damage: std.ArrayList(render.Rect) = .empty,
    pending_buffer_damage: std.ArrayList(render.Rect) = .empty,
    pending_callbacks: std.ArrayList(wayring.ObjectHandle) = .empty,
    pending_presentation_feedbacks: std.ArrayList(*PresentationFeedback) = .empty,
    pending_content_type: ContentType = .none,
    current_content_type: ContentType = .none,
    pending_alpha_multiplier: u32 = std.math.maxInt(u32),
    current_alpha_multiplier: u32 = std.math.maxInt(u32),
    pending_presentation_hint: PresentationHint = .vsync,
    current_presentation_hint: PresentationHint = .vsync,
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
    pending_opaque: Region,
    pending_input: InputRegion,

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

    pub fn hasExplicitSyncHandler(self: *const Surface) bool {
        return self.explicit_sync_handler != null;
    }

    pub fn setExplicitSyncHandler(self: *Surface, handler: ExplicitSyncHandler) !void {
        if (self.explicit_sync_handler != null) return error.AlreadyExists;
        self.explicit_sync_handler = handler;
    }

    pub fn clearExplicitSyncHandler(self: *Surface, context: *anyopaque) void {
        const handler = self.explicit_sync_handler orelse unreachable;
        std.debug.assert(handler.context == context);
        self.explicit_sync_handler = null;
    }

    pub fn setContentTypeHandler(self: *Surface, handler: ContentTypeHandler) !void {
        if (self.content_type_handler != null) return error.AlreadyExists;
        self.content_type_handler = handler;
    }

    pub fn clearContentTypeHandler(self: *Surface, context: *anyopaque) void {
        const handler = self.content_type_handler orelse unreachable;
        std.debug.assert(handler.context == context);
        self.content_type_handler = null;
        self.pending_content_type = .none;
    }

    pub fn setAlphaModifierHandler(self: *Surface, handler: AlphaModifierHandler) !void {
        if (self.alpha_modifier_handler != null) return error.AlreadyExists;
        self.alpha_modifier_handler = handler;
    }

    pub fn clearAlphaModifierHandler(self: *Surface, context: *anyopaque) void {
        const handler = self.alpha_modifier_handler orelse unreachable;
        std.debug.assert(handler.context == context);
        self.alpha_modifier_handler = null;
        self.pending_alpha_multiplier = std.math.maxInt(u32);
    }

    pub fn setTearingControlHandler(self: *Surface, handler: TearingControlHandler) !void {
        if (self.tearing_control_handler != null) return error.AlreadyExists;
        self.tearing_control_handler = handler;
    }

    pub fn resetTearingControl(self: *Surface, context: *anyopaque) void {
        const handler = self.tearing_control_handler orelse unreachable;
        std.debug.assert(handler.context == context);
        self.tearing_control_handler = null;
        self.pending_presentation_hint = .vsync;
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
        self.pending_attachment.releaseBuffer(client) catch {};
        self.pending_attachment.deinit();
        for (self.pending_callbacks.items) |callback|
            self.client.destroyResource(callback) catch {};
        self.pending_callbacks.deinit(self.allocator);
        for (self.pending_presentation_feedbacks.items) |feedback|
            feedback.discarded(feedback.context);
        self.pending_presentation_feedbacks.deinit(self.allocator);
        self.pending_buffer_damage.deinit(self.allocator);
        self.pending_surface_damage.deinit(self.allocator);
        self.pending_opaque.deinit();
        self.pending_input.deinit();
        self.allocator.destroy(self);
        client.unreference();
    }
};

pub const InputRegion = struct {
    infinite: bool,
    value: Region,

    pub fn init() InputRegion {
        return .{ .infinite = true, .value = Region.init() };
    }

    pub fn deinit(self: *InputRegion) void {
        self.value.deinit();
        self.* = undefined;
    }

    fn set(self: *InputRegion, region: *const Region) Region.Error!void {
        try self.value.copyFrom(region);
        self.infinite = false;
    }

    fn setInfinite(self: *InputRegion) void {
        self.value.clear();
        self.infinite = true;
    }

    pub fn copyFrom(self: *InputRegion, other: *const InputRegion) Region.Error!void {
        try self.value.copyFrom(&other.value);
        self.infinite = other.infinite;
    }

    pub fn accepts(self: *const InputRegion, x: f64, y: f64) bool {
        return self.infinite or self.value.containsPoint(.{ .x = x, .y = y });
    }
};

const RegionResource = struct {
    allocator: std.mem.Allocator,
    value: Region,

    fn deinit(self: *RegionResource) void {
        self.value.deinit();
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
    self.hierarchy_handler = null;
    for (self.transactions.items) |*transaction| {
        transaction.releaseBuffers();
        transaction.deinit();
    }
    self.transactions.deinit(self.allocator);
    // Surface resources may be destroyed later by Server.deinit. They retain
    // this owner only to observe that no hierarchy handler remains installed.
}

pub fn popTransaction(self: *CompositorGlobal) ?Transaction {
    if (self.transactions.items.len == 0) return null;
    return self.transactions.orderedRemove(0);
}

pub fn setHierarchyHandler(self: *CompositorGlobal, handler: HierarchyHandler) void {
    std.debug.assert(self.hierarchy_handler == null);
    self.hierarchy_handler = handler;
}

pub fn clearHierarchyHandler(self: *CompositorGlobal, context: *anyopaque) void {
    std.debug.assert(self.hierarchy_handler.?.context == context);
    self.hierarchy_handler = null;
}

pub fn enqueueTransaction(self: *CompositorGlobal, transaction: Transaction) !void {
    try self.transactions.append(self.allocator, transaction);
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
                .pending_opaque = Region.init(),
                .pending_input = InputRegion.init(),
            };
            errdefer surface.pending_opaque.deinit();
            errdefer surface.pending_input.deinit();
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
            const region = self.allocator.create(RegionResource) catch
                return client.postNoMemory();
            errdefer self.allocator.destroy(region);
            region.* = .{
                .allocator = self.allocator,
                .value = Region.init(),
            };
            errdefer region.value.deinit();
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
                    .buffer = try ShmGlobal.cloneBufferResource(client, handle),
                } };
            } else .removed;
            surface.pending_attachment.releaseBuffer(client) catch {};
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
        .set_opaque_region => |request| {
            if (request.region) |region_id| {
                const region = try regionFor(client, region_id);
                surface.pending_opaque.copyFrom(&region.value) catch
                    return client.postNoMemory();
            } else {
                surface.pending_opaque.clear();
            }
        },
        .set_input_region => |request| {
            if (request.region) |region_id| {
                const region = try regionFor(client, region_id);
                surface.pending_input.set(&region.value) catch
                    return client.postNoMemory();
            } else {
                surface.pending_input.setInfinite();
            }
        },
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
    const attachment_kind = pendingAttachment(surface.pending_attachment);
    if (surface.explicit_sync_handler) |handler| {
        if (!handler.validate_commit(handler.context, attachment_kind)) return;
    }
    const commit = takeCommit(surface, attachment_kind) catch
        return surface.client.postNoMemory();
    if (owner.hierarchy_handler) |handler| {
        handler.commit(handler.context, commit) catch return surface.client.postNoMemory();
        return;
    }
    const entries = owner.allocator.alloc(Commit, 1) catch {
        var owned = commit;
        owned.releaseBuffer() catch {};
        owned.deinit();
        return surface.client.postNoMemory();
    };
    entries[0] = commit;
    const updates = owner.allocator.alloc(HierarchyUpdate, 0) catch {
        entries[0].releaseBuffer() catch {};
        entries[0].deinit();
        owner.allocator.free(entries);
        return surface.client.postNoMemory();
    };
    var transaction = Transaction.init(owner.allocator, surface, entries, updates) catch {
        owner.allocator.free(updates);
        entries[0].releaseBuffer() catch {};
        entries[0].deinit();
        owner.allocator.free(entries);
        return surface.client.postNoMemory();
    };
    owner.transactions.append(owner.allocator, transaction) catch {
        transaction.releaseBuffers();
        transaction.deinit();
        return surface.client.postNoMemory();
    };
}

fn takeCommit(surface: *Surface, attachment_kind: PendingAttachment) !Commit {
    const owner = surface.owner;
    var opaque_region = Region.init();
    errdefer opaque_region.deinit();
    try opaque_region.copyFrom(&surface.pending_opaque);
    var input = InputRegion.init();
    errdefer input.deinit();
    try input.copyFrom(&surface.pending_input);
    const surface_damage = owner.allocator.dupe(
        render.Rect,
        surface.pending_surface_damage.items,
    ) catch return error.OutOfMemory;
    errdefer owner.allocator.free(surface_damage);
    const buffer_damage = owner.allocator.dupe(
        render.Rect,
        surface.pending_buffer_damage.items,
    ) catch return error.OutOfMemory;
    errdefer owner.allocator.free(buffer_damage);
    const frame_callbacks = owner.allocator.dupe(
        wayring.ObjectHandle,
        surface.pending_callbacks.items,
    ) catch return error.OutOfMemory;
    errdefer owner.allocator.free(frame_callbacks);
    const presentation_feedbacks = owner.allocator.dupe(
        *PresentationFeedback,
        surface.pending_presentation_feedbacks.items,
    ) catch return error.OutOfMemory;
    errdefer owner.allocator.free(presentation_feedbacks);
    surface.reference() catch return error.OutOfMemory;
    errdefer surface.unreference();
    if (presentation_feedbacks.len != 0) {
        surface.reference() catch return error.OutOfMemory;
        errdefer surface.unreference();
    }

    surface.current_scale = surface.pending_scale;
    surface.current_content_type = surface.pending_content_type;
    surface.current_alpha_multiplier = surface.pending_alpha_multiplier;
    surface.current_presentation_hint = surface.pending_presentation_hint;
    surface.current_transform = surface.pending_transform;
    surface.current_offset_x = surface.pending_offset_x;
    surface.current_offset_y = surface.pending_offset_y;
    surface.current_viewport = surface.pending_viewport;
    const attachment = surface.pending_attachment;
    surface.pending_attachment = .unchanged;
    surface.pending_surface_damage.clearRetainingCapacity();
    surface.pending_buffer_damage.clearRetainingCapacity();
    surface.pending_callbacks.clearRetainingCapacity();
    surface.pending_presentation_feedbacks.clearRetainingCapacity();
    const synchronization = if (attachment_kind == .dmabuf)
        if (surface.explicit_sync_handler) |handler| handler.take_pending(handler.context) else null
    else
        null;
    return .{
        .allocator = owner.allocator,
        .surface = surface,
        .attachment = attachment,
        .surface_damage = surface_damage,
        .buffer_damage = buffer_damage,
        .frame_callbacks = frame_callbacks,
        .presentation_feedbacks = presentation_feedbacks,
        .content_type = surface.current_content_type,
        .alpha_multiplier = surface.current_alpha_multiplier,
        .presentation_hint = surface.current_presentation_hint,
        .scale = surface.current_scale,
        .transform = surface.current_transform,
        .offset_x = surface.current_offset_x,
        .offset_y = surface.current_offset_y,
        .viewport = surface.current_viewport,
        .opaque_region = opaque_region,
        .input_region = input,
        .synchronization = synchronization,
    };
}

fn pendingAttachment(attachment: Attachment) PendingAttachment {
    return switch (attachment) {
        .unchanged => .none,
        .removed => .null_buffer,
        .buffer => |buffer| switch (buffer.buffer.content) {
            .dmabuf => .dmabuf,
            .shm, .single_pixel => .unsupported,
        },
    };
}

fn destroySurface(
    context: *anyopaque,
    _: *Server.Client,
    _: wayring.ObjectHandle,
) void {
    const surface: *Surface = @ptrCast(@alignCast(context));
    surface.resource_alive = false;
    if (surface.owner.hierarchy_handler) |handler|
        handler.surface_destroyed(handler.context, surface);
    if (surface.role_destroyed) |destroyed| destroyed(surface.role_context.?);
    if (surface.explicit_sync_handler) |handler| {
        handler.surface_destroyed(handler.context);
        surface.explicit_sync_handler = null;
    }
    if (surface.content_type_handler) |handler| {
        handler.surface_destroyed(handler.context);
        surface.content_type_handler = null;
    }
    if (surface.alpha_modifier_handler) |handler| {
        handler.surface_destroyed(handler.context);
        surface.alpha_modifier_handler = null;
    }
    if (surface.tearing_control_handler) |handler| {
        surface.tearing_control_handler = null;
        handler.surface_destroyed(handler.context);
    }
    surface.unreference();
}

fn dispatchRegion(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const region: *RegionResource = @ptrCast(@alignCast(context));
    switch (try generated.wl_region_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .add => |request| region.value.add(
            request.x,
            request.y,
            request.width,
            request.height,
        ) catch return client.postNoMemory(),
        .subtract => |request| region.value.subtract(
            request.x,
            request.y,
            request.width,
            request.height,
        ) catch return client.postNoMemory(),
    }
}

fn regionFor(client: *const Server.Client, id: u32) !*RegionResource {
    const object = client.connection.object(id) orelse return error.UnknownRegion;
    return @ptrCast(@alignCast(try client.resourceContext(
        .{ .id = id, .generation = object.generation },
        &generated.wl_region,
    )));
}

fn destroyRegion(
    context: *anyopaque,
    _: *Server.Client,
    _: wayring.ObjectHandle,
) void {
    const region: *RegionResource = @ptrCast(@alignCast(context));
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
    const region = try generated.wl_compositor_types.requests.create_region(
        &peer,
        compositor_resource,
    );
    try generated.wl_region_types.requests.add(&peer, region, 0, 0, 4, 4);
    try generated.wl_region_types.requests.subtract(&peer, region, 1, 1, 2, 2);
    try generated.wl_surface_types.requests.set_opaque_region(&peer, surface, region);
    try generated.wl_surface_types.requests.set_input_region(&peer, surface, region);
    // Surface setters snapshot region state immediately; later mutations do
    // not alter already-pending state.
    try generated.wl_region_types.requests.add(&peer, region, 1, 1, 2, 2);
    try generated.wl_surface_types.requests.attach(&peer, surface, buffer, 0, 0);
    try generated.wl_surface_types.requests.damage_buffer(&peer, surface, 1, 2, 2, 1);
    const callback = try generated.wl_surface_types.requests.frame(&peer, surface);
    try generated.wl_surface_types.requests.commit(&peer, surface);
    try transferToServer(&peer, client);

    var transaction = compositor.popTransaction() orelse return error.MissingCommit;
    defer transaction.deinit();
    const commit = &transaction.entries[0];
    try std.testing.expectEqual(surface.id, commit.surface.resource.id);
    try std.testing.expectEqualSlices(
        render.Rect,
        &.{.{ .x = 1, .y = 2, .width = 2, .height = 1 }},
        commit.buffer_damage,
    );
    try std.testing.expectEqual(callback.id, commit.frame_callbacks[0].id);
    try std.testing.expect(commit.opaque_region.contains(0, 0));
    try std.testing.expect(!commit.opaque_region.contains(1, 1));
    try std.testing.expect(commit.input_region.accepts(0.5, 0.5));
    try std.testing.expect(!commit.input_region.accepts(1.5, 1.5));
    try commit.releaseBuffer();
    var callbacks = (try commit.takeFrameCallbacks()).?;
    defer callbacks.deinit();
    try callbacks.finish(42);
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

    try generated.wl_surface_types.requests.set_opaque_region(&peer, surface, null);
    try generated.wl_surface_types.requests.set_input_region(&peer, surface, null);
    try generated.wl_surface_types.requests.commit(&peer, surface);
    try transferToServer(&peer, client);
    var reset_transaction = compositor.popTransaction() orelse
        return error.MissingCommit;
    defer reset_transaction.deinit();
    const reset = &reset_transaction.entries[0];
    try std.testing.expect(reset.opaque_region.isEmpty());
    try std.testing.expect(reset.input_region.accepts(-100, -100));
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
