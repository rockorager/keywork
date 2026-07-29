//! Linux DRM syncobj explicit synchronization protocol version 1.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const DrmSyncobj = @import("../drm_syncobj.zig");
const render = @import("../render/types.zig");
const Surface = @import("surface.zig");

const wl = wayland.server.wl;
const wp = wayland.server.wp;
const log = std.log.scoped(.linux_drm_syncobj);

allocator: std.mem.Allocator,
global: ?*wl.Global,
device: ?DrmSyncobj.Device,
timeline_count: usize,
surface_count: usize,

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    io: std.Io,
    display: *wl.Server,
    preferred_device: ?render.DrmDeviceId,
) !void {
    self.* = .{
        .allocator = allocator,
        .global = null,
        .device = null,
        .timeline_count = 0,
        .surface_count = 0,
    };
    self.device = DrmSyncobj.Device.init(
        allocator,
        io,
        display.getEventLoop(),
        preferred_device,
    ) catch {
        log.info("DRM timeline synchronization unavailable", .{});
        return;
    };
    errdefer {
        self.device.?.deinit();
        self.device = null;
    }
    self.global = try wl.Global.create(
        display,
        wp.LinuxDrmSyncobjManagerV1,
        1,
        *Self,
        self,
        bind,
    );
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.timeline_count == 0);
    std.debug.assert(self.surface_count == 0);
    if (self.global) |global| global.destroy();
    if (self.device) |*device| device.deinit();
    self.* = undefined;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = wp.LinuxDrmSyncobjManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleRequest, null, self);
}

fn handleRequest(
    resource: *wp.LinuxDrmSyncobjManagerV1,
    request: wp.LinuxDrmSyncobjManagerV1.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .get_surface => |get| {
            const surface = Surface.fromResource(get.surface);
            if (surface.hasExplicitSyncHandler()) {
                resource.postError(
                    .surface_exists,
                    "wl_surface already has an explicit synchronization object",
                );
                return;
            }
            SyncSurface.create(self, surface, resource.getClient(), get.id) catch
                resource.postNoMemory();
        },
        .import_timeline => |import| {
            defer _ = std.c.close(import.fd);
            const timeline = self.device.?.importTimeline(import.fd) catch |err| switch (err) {
                error.InvalidTimeline => {
                    resource.postError(
                        .invalid_timeline,
                        "failed to import DRM syncobj timeline",
                    );
                    return;
                },
                error.OutOfMemory => {
                    resource.postNoMemory();
                    return;
                },
            };
            TimelineResource.create(self, timeline, resource.getClient(), import.id) catch {
                timeline.unreference();
                resource.postNoMemory();
            };
        },
    }
}

const TimelineResource = struct {
    manager: *Self,
    timeline: *DrmSyncobj.Timeline,

    fn create(
        manager: *Self,
        timeline: *DrmSyncobj.Timeline,
        client: *wl.Client,
        id: u32,
    ) error{OutOfMemory}!void {
        const resource = wp.LinuxDrmSyncobjTimelineV1.create(client, 1, id) catch
            return error.OutOfMemory;
        errdefer resource.destroy();
        const self = manager.allocator.create(TimelineResource) catch return error.OutOfMemory;
        self.* = .{ .manager = manager, .timeline = timeline };
        manager.timeline_count += 1;
        resource.setHandler(
            *TimelineResource,
            TimelineResource.handleRequest,
            TimelineResource.handleDestroy,
            self,
        );
    }

    fn handleRequest(
        resource: *wp.LinuxDrmSyncobjTimelineV1,
        request: wp.LinuxDrmSyncobjTimelineV1.Request,
        _: *TimelineResource,
    ) void {
        switch (request) {
            .destroy => resource.destroy(),
        }
    }

    fn handleDestroy(_: *wp.LinuxDrmSyncobjTimelineV1, self: *TimelineResource) void {
        self.timeline.unreference();
        self.manager.timeline_count -= 1;
        self.manager.allocator.destroy(self);
    }
};

const SyncSurface = struct {
    manager: *Self,
    resource: *wp.LinuxDrmSyncobjSurfaceV1,
    surface: ?*Surface,
    pending_acquire: ?DrmSyncobj.Point,
    pending_release: ?DrmSyncobj.Point,

    fn create(
        manager: *Self,
        surface: *Surface,
        client: *wl.Client,
        id: u32,
    ) error{OutOfMemory}!void {
        const resource = wp.LinuxDrmSyncobjSurfaceV1.create(client, 1, id) catch
            return error.OutOfMemory;
        errdefer resource.destroy();
        const self = manager.allocator.create(SyncSurface) catch return error.OutOfMemory;
        errdefer manager.allocator.destroy(self);
        self.* = .{
            .manager = manager,
            .resource = resource,
            .surface = surface,
            .pending_acquire = null,
            .pending_release = null,
        };
        surface.setExplicitSyncHandler(.{
            .context = self,
            .validate_commit = validateCommit,
            .pending_ready = pendingReady,
            .take_pending = takePending,
            .surface_destroyed = surfaceDestroyed,
        }) catch unreachable;
        manager.surface_count += 1;
        resource.setHandler(
            *SyncSurface,
            SyncSurface.handleRequest,
            SyncSurface.handleDestroy,
            self,
        );
    }

    fn handleRequest(
        resource: *wp.LinuxDrmSyncobjSurfaceV1,
        request: wp.LinuxDrmSyncobjSurfaceV1.Request,
        self: *SyncSurface,
    ) void {
        switch (request) {
            .destroy => resource.destroy(),
            .set_acquire_point => |set| self.setPoint(
                resource,
                .acquire,
                set.timeline,
                set.point_hi,
                set.point_lo,
            ),
            .set_release_point => |set| self.setPoint(
                resource,
                .release,
                set.timeline,
                set.point_hi,
                set.point_lo,
            ),
        }
    }

    fn setPoint(
        self: *SyncSurface,
        resource: *wp.LinuxDrmSyncobjSurfaceV1,
        kind: enum { acquire, release },
        timeline_resource: *wp.LinuxDrmSyncobjTimelineV1,
        high: u32,
        low: u32,
    ) void {
        if (self.surface == null) {
            resource.postError(.no_surface, "the associated wl_surface was destroyed");
            return;
        }
        const timeline: *TimelineResource = @ptrCast(@alignCast(
            timeline_resource.getUserData().?,
        ));
        const point = timeline.timeline.point(pointValue(high, low));
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

    fn handleDestroy(_: *wp.LinuxDrmSyncobjSurfaceV1, self: *SyncSurface) void {
        if (self.surface) |surface| surface.clearExplicitSyncHandler(self);
        self.clearPending();
        self.manager.surface_count -= 1;
        self.manager.allocator.destroy(self);
    }

    fn validateCommit(context: *anyopaque, attachment: Surface.PendingAttachment) bool {
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
        switch (validation_error) {
            .no_buffer => self.resource.postError(
                .no_buffer,
                "explicit synchronization points require a non-null buffer attachment",
            ),
            .unsupported_buffer => self.resource.postError(
                .unsupported_buffer,
                "explicit synchronization only supports linux-dmabuf buffers",
            ),
            .no_acquire_point => self.resource.postError(
                .no_acquire_point,
                "buffer attachment has no acquire point",
            ),
            .no_release_point => self.resource.postError(
                .no_release_point,
                "buffer attachment has no release point",
            ),
            .conflicting_points => self.resource.postError(
                .conflicting_points,
                "acquire point must precede release point on the same timeline",
            ),
        }
        return false;
    }

    fn pendingReady(context: *anyopaque) bool {
        const self: *SyncSurface = @ptrCast(@alignCast(context));
        return self.pending_acquire == null or self.pending_acquire.?.signaled();
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

    fn clearPending(self: *SyncSurface) void {
        if (self.pending_acquire) |*point| point.deinit();
        if (self.pending_release) |*point| point.deinit();
        self.pending_acquire = null;
        self.pending_release = null;
    }
};

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
    attachment: Surface.PendingAttachment,
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

test "timeline values preserve high and low request words" {
    try std.testing.expectEqual(
        @as(u64, 0x89ab_cdef_0123_4567),
        pointValue(0x89ab_cdef, 0x0123_4567),
    );
}

test "only ordered points on one timeline can conflict" {
    var first: DrmSyncobj.Timeline = undefined;
    var second: DrmSyncobj.Timeline = undefined;
    try std.testing.expect(pointsConflict(
        .{ .timeline = &first, .value = 4 },
        .{ .timeline = &first, .value = 4 },
    ));
    try std.testing.expect(pointsConflict(
        .{ .timeline = &first, .value = 5 },
        .{ .timeline = &first, .value = 4 },
    ));
    try std.testing.expect(!pointsConflict(
        .{ .timeline = &first, .value = 5 },
        .{ .timeline = &second, .value = 4 },
    ));
}

test "commit validation requires points exactly with supported attachments" {
    try std.testing.expectEqual(
        @as(?ValidationError, null),
        validateAttachment(.none, false, false, false),
    );
    try std.testing.expectEqual(
        ValidationError.no_buffer,
        validateAttachment(.null_buffer, true, true, false).?,
    );
    try std.testing.expectEqual(
        ValidationError.unsupported_buffer,
        validateAttachment(.unsupported, true, true, false).?,
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
    try std.testing.expectEqual(
        @as(?ValidationError, null),
        validateAttachment(.dmabuf, true, true, false),
    );
}
