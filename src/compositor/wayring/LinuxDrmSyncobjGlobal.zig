//! Native linux-drm-syncobj version 1 policy for explicit buffer synchronization.

const LinuxDrmSyncobjGlobal = @This();

const std = @import("std");
const linux = std.os.linux;
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const DrmSyncobj = @import("../drm_syncobj.zig");
const render = @import("../render/types.zig");
const CompositorGlobal = @import("CompositorGlobal.zig");

const log = std.log.scoped(.linux_drm_syncobj);

allocator: std.mem.Allocator,
server: *Server,
global_name: ?u32,
device: ?DrmSyncobj.Device,

const TimelineResource = struct {
    owner: *LinuxDrmSyncobjGlobal,
    timeline: *DrmSyncobj.Timeline,
};

const SyncSurface = struct {
    owner: *LinuxDrmSyncobjGlobal,
    resource: wayring.ObjectHandle,
    surface: ?*CompositorGlobal.Surface,
    pending_acquire: ?DrmSyncobj.Point = null,
    pending_release: ?DrmSyncobj.Point = null,

    fn clearPending(self: *SyncSurface) void {
        if (self.pending_acquire) |*point| point.deinit();
        if (self.pending_release) |*point| point.deinit();
        self.pending_acquire = null;
        self.pending_release = null;
    }
};

pub fn init(
    self: *LinuxDrmSyncobjGlobal,
    allocator: std.mem.Allocator,
    io: std.Io,
    server: *Server,
    preferred_device: ?render.DrmDeviceId,
) !void {
    self.* = .{
        .allocator = allocator,
        .server = server,
        .global_name = null,
        .device = null,
    };
    self.device = DrmSyncobj.Device.initNative(allocator, io, preferred_device) catch {
        log.info("DRM timeline synchronization unavailable", .{});
        return;
    };
    errdefer {
        self.device.?.deinit();
        self.device = null;
    }
    self.global_name = try server.createGlobal(
        &generated.wp_linux_drm_syncobj_manager_v1,
        1,
        .{ .context = self, .bind = bind },
    );
}

pub fn deinit(self: *LinuxDrmSyncobjGlobal) void {
    if (self.global_name) |name| self.server.removeGlobal(name) catch unreachable;
    if (self.device) |*device| device.deinit();
    self.* = undefined;
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *LinuxDrmSyncobjGlobal = @ptrCast(@alignCast(context));
    _ = client.createResource(
        id,
        &generated.wp_linux_drm_syncobj_manager_v1,
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
    const self: *LinuxDrmSyncobjGlobal = @ptrCast(@alignCast(context));
    switch (try generated.wp_linux_drm_syncobj_manager_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .get_surface => |request| {
            const object = client.connection.object(request.surface) orelse
                return error.UnknownSurface;
            const surface = try CompositorGlobal.surfaceFor(client, .{
                .id = request.surface,
                .generation = object.generation,
            });
            if (surface.hasExplicitSyncHandler()) return client.postError(
                resource,
                @intFromEnum(generated.wp_linux_drm_syncobj_manager_v1_types.@"error".surface_exists),
                "wl_surface already has an explicit synchronization object",
            );
            const sync_surface = self.allocator.create(SyncSurface) catch
                return client.postNoMemory();
            errdefer self.allocator.destroy(sync_surface);
            sync_surface.* = .{
                .owner = self,
                .resource = undefined,
                .surface = surface,
            };
            surface.setExplicitSyncHandler(.{
                .context = sync_surface,
                .validate_commit = validateCommit,
                .take_pending = takePending,
                .surface_destroyed = surfaceDestroyed,
            }) catch unreachable;
            errdefer surface.clearExplicitSyncHandler(sync_surface);
            sync_surface.resource = client.createResource(
                request.id,
                &generated.wp_linux_drm_syncobj_surface_v1,
                1,
                .{
                    .context = sync_surface,
                    .dispatch = dispatchSyncSurface,
                    .destroy = destroySyncSurface,
                },
            ) catch return client.postNoMemory();
        },
        .import_timeline => |request| {
            const fd = try message.takeFd(request.fd);
            defer _ = linux.close(fd);
            const timeline = self.device.?.importTimeline(fd) catch |err| switch (err) {
                error.InvalidTimeline => return client.postError(
                    resource,
                    @intFromEnum(generated.wp_linux_drm_syncobj_manager_v1_types.@"error".invalid_timeline),
                    "failed to import DRM syncobj timeline",
                ),
                error.OutOfMemory => return client.postNoMemory(),
            };
            errdefer timeline.unreference();
            const holder = self.allocator.create(TimelineResource) catch
                return client.postNoMemory();
            errdefer self.allocator.destroy(holder);
            holder.* = .{ .owner = self, .timeline = timeline };
            _ = client.createResource(
                request.id,
                &generated.wp_linux_drm_syncobj_timeline_v1,
                1,
                .{
                    .context = holder,
                    .dispatch = dispatchTimeline,
                    .destroy = destroyTimeline,
                },
            ) catch return client.postNoMemory();
        },
    }
}

fn dispatchTimeline(
    _: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    _ = try generated.wp_linux_drm_syncobj_timeline_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    );
}

fn destroyTimeline(context: *anyopaque, _: *Server.Client, _: wayring.ObjectHandle) void {
    const holder: *TimelineResource = @ptrCast(@alignCast(context));
    holder.timeline.unreference();
    holder.owner.allocator.destroy(holder);
}

fn dispatchSyncSurface(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const self: *SyncSurface = @ptrCast(@alignCast(context));
    switch (try generated.wp_linux_drm_syncobj_surface_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .set_acquire_point => |request| try setPoint(
            self,
            client,
            .acquire,
            request.timeline,
            request.point_hi,
            request.point_lo,
        ),
        .set_release_point => |request| try setPoint(
            self,
            client,
            .release,
            request.timeline,
            request.point_hi,
            request.point_lo,
        ),
    }
}

fn setPoint(
    self: *SyncSurface,
    client: *Server.Client,
    kind: enum { acquire, release },
    timeline_id: u32,
    high: u32,
    low: u32,
) !void {
    if (self.surface == null) return client.postError(
        self.resource,
        @intFromEnum(generated.wp_linux_drm_syncobj_surface_v1_types.@"error".no_surface),
        "the associated wl_surface was destroyed",
    );
    const object = client.connection.object(timeline_id) orelse return error.UnknownTimeline;
    const holder: *TimelineResource = @ptrCast(@alignCast(try client.resourceContext(
        .{ .id = timeline_id, .generation = object.generation },
        &generated.wp_linux_drm_syncobj_timeline_v1,
    )));
    const point = holder.timeline.point(pointValue(high, low));
    switch (kind) {
        .acquire => {
            if (self.pending_acquire) |*pending| pending.deinit();
            self.pending_acquire = point;
        },
        .release => {
            if (self.pending_release) |*pending| pending.deinit();
            self.pending_release = point;
        },
    }
}

fn destroySyncSurface(context: *anyopaque, _: *Server.Client, _: wayring.ObjectHandle) void {
    const self: *SyncSurface = @ptrCast(@alignCast(context));
    if (self.surface) |surface| surface.clearExplicitSyncHandler(self);
    self.clearPending();
    self.owner.allocator.destroy(self);
}

fn validateCommit(context: *anyopaque, attachment: CompositorGlobal.PendingAttachment) bool {
    const self: *SyncSurface = @ptrCast(@alignCast(context));
    const has_acquire = self.pending_acquire != null;
    const has_release = self.pending_release != null;
    const conflict = has_acquire and has_release and
        pointsConflict(self.pending_acquire.?, self.pending_release.?);
    const validation_error = validateAttachment(
        attachment,
        has_acquire,
        has_release,
        conflict,
    ) orelse return true;
    const error_code: generated.wp_linux_drm_syncobj_surface_v1_types.@"error" = switch (validation_error) {
        .no_buffer => .no_buffer,
        .unsupported_buffer => .unsupported_buffer,
        .no_acquire_point => .no_acquire_point,
        .no_release_point => .no_release_point,
        .conflicting_points => .conflicting_points,
    };
    self.surface.?.client.postError(
        self.resource,
        @intFromEnum(error_code),
        switch (validation_error) {
            .no_buffer => "explicit synchronization points require a non-null buffer attachment",
            .unsupported_buffer => "explicit synchronization only supports linux-dmabuf buffers",
            .no_acquire_point => "buffer attachment has no acquire point",
            .no_release_point => "buffer attachment has no release point",
            .conflicting_points => "acquire point must precede release point on the same timeline",
        },
    ) catch {};
    return false;
}

fn takePending(context: *anyopaque) DrmSyncobj.Commit {
    const self: *SyncSurface = @ptrCast(@alignCast(context));
    const commit: DrmSyncobj.Commit = .{
        .acquire = self.pending_acquire.?,
        .release = self.pending_release.?,
    };
    self.pending_acquire = null;
    self.pending_release = null;
    return commit;
}

fn surfaceDestroyed(context: *anyopaque) void {
    const self: *SyncSurface = @ptrCast(@alignCast(context));
    self.surface = null;
    self.clearPending();
}

fn pointValue(high: u32, low: u32) u64 {
    return @as(u64, high) << 32 | low;
}

fn pointsConflict(acquire: DrmSyncobj.Point, release: DrmSyncobj.Point) bool {
    return acquire.timeline == release.timeline and acquire.value >= release.value;
}

const ValidationError = enum {
    no_buffer,
    unsupported_buffer,
    no_acquire_point,
    no_release_point,
    conflicting_points,
};

fn validateAttachment(
    attachment: CompositorGlobal.PendingAttachment,
    has_acquire: bool,
    has_release: bool,
    conflicting: bool,
) ?ValidationError {
    return switch (attachment) {
        .none, .null_buffer => if (has_acquire or has_release) .no_buffer else null,
        .unsupported => .unsupported_buffer,
        .dmabuf => if (!has_acquire)
            .no_acquire_point
        else if (!has_release)
            .no_release_point
        else if (conflicting)
            .conflicting_points
        else
            null,
    };
}

test "native explicit synchronization validates attachment state" {
    try std.testing.expectEqual(
        ValidationError.no_buffer,
        validateAttachment(.none, true, false, false).?,
    );
    try std.testing.expectEqual(
        ValidationError.unsupported_buffer,
        validateAttachment(.unsupported, false, false, false).?,
    );
    try std.testing.expectEqual(
        ValidationError.no_acquire_point,
        validateAttachment(.dmabuf, false, true, false).?,
    );
    try std.testing.expectEqual(
        ValidationError.no_release_point,
        validateAttachment(.dmabuf, true, false, false).?,
    );
    try std.testing.expectEqual(
        ValidationError.conflicting_points,
        validateAttachment(.dmabuf, true, true, true).?,
    );
    try std.testing.expect(validateAttachment(.dmabuf, true, true, false) == null);
}

test "native explicit synchronization preserves 64-bit timeline values" {
    try std.testing.expectEqual(
        @as(u64, 0x89ab_cdef_0123_4567),
        pointValue(0x89ab_cdef, 0x0123_4567),
    );
}
