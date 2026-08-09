//! Scanner-backed Linux DRM syncobj explicit synchronization protocol v1.

const Self = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayland = @import("wayland");
const wayring = @import("wayring");
const DrmSyncobj = @import("../drm_syncobj.zig");
const render = @import("../render/types.zig");
const WayringCompositor = @import("WayringCompositor.zig");
const linux_dmabuf = @import("linux_dmabuf_buffer.zig");

const server = wayring.server;
const wl = wayland.server.wl;
const log = std.log.scoped(.wayring_linux_drm_syncobj);

pub const FailureListener = struct {
    context: *anyopaque,
    failed: *const fn (*anyopaque) void,
};

const Manager = struct {
    owner: *Self,
    client: *server.Client,
    resource: protocol.wp_linux_drm_syncobj_manager_v1.Resource,
};

const Timeline = struct {
    owner: *Self,
    client: *server.Client,
    resource: protocol.wp_linux_drm_syncobj_timeline_v1.Resource,
    timeline: *DrmSyncobj.Timeline,
};

const SyncSurface = struct {
    owner: *Self,
    client: *server.Client,
    resource: protocol.wp_linux_drm_syncobj_surface_v1.Resource,
    surface: ?WayringCompositor.SurfaceId,
    pending_acquire: ?DrmSyncobj.Point = null,
    pending_release: ?DrmSyncobj.Point = null,
};

allocator: std.mem.Allocator,
protocol_server: *server.Server,
compositor: *WayringCompositor,
failure_listener: FailureListener,
device: ?DrmSyncobj.Device,
global: ?*const server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
timelines: std.ArrayList(*Timeline) = .empty,
surfaces: std.ArrayList(*SyncSurface) = .empty,
use_count: usize = 0,

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    io: std.Io,
    protocol_server: *server.Server,
    compositor: *WayringCompositor,
    failure_listener: FailureListener,
    event_loop: *wl.EventLoop,
    preferred_device: ?render.DrmDeviceId,
) void {
    self.* = .{
        .allocator = allocator,
        .protocol_server = protocol_server,
        .compositor = compositor,
        .failure_listener = failure_listener,
        .device = DrmSyncobj.Device.init(allocator, io, event_loop, preferred_device) catch null,
    };
    if (self.device == null) log.info("DRM timeline synchronization unavailable", .{});
}

pub fn available(self: *const Self) bool {
    return self.device != null;
}

pub fn publish(self: *Self) !void {
    std.debug.assert(self.global == null);
    if (!self.available()) return;
    self.global = try self.protocol_server.addGlobal(protocol.wp_linux_drm_syncobj_manager_v1, 1, Self, self, bind);
}

pub fn unpublish(self: *Self) void {
    const global = self.global orelse return;
    self.protocol_server.removeGlobal(global) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}

pub fn destroyClientResources(self: *Self, client: *server.Client) void {
    var i = self.surfaces.items.len;
    while (i > 0) {
        i -= 1;
        if (self.surfaces.items[i].client == client) self.destroySurface(self.surfaces.items[i]);
    }
    i = self.timelines.items.len;
    while (i > 0) {
        i -= 1;
        if (self.timelines.items[i].client == client) self.destroyTimeline(self.timelines.items[i]);
    }
    i = self.managers.items.len;
    while (i > 0) {
        i -= 1;
        if (self.managers.items[i].client == client) self.destroyManager(self.managers.items[i]);
    }
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.global == null);
    std.debug.assert(self.surfaces.items.len == 0 and self.timelines.items.len == 0 and self.managers.items.len == 0);
    std.debug.assert(self.use_count == 0);
    self.surfaces.deinit(self.allocator);
    self.timelines.deinit(self.allocator);
    self.managers.deinit(self.allocator);
    if (self.device) |*device| device.deinit();
    self.* = undefined;
}

fn bind(client: *server.Client, id: u32, version: u32, self: *Self) !void {
    try self.managers.ensureUnusedCapacity(self.allocator, 1);
    const manager = try self.allocator.create(Manager);
    errdefer self.allocator.destroy(manager);
    manager.* = .{ .owner = self, .client = client, .resource = .init(self.allocator, id, version, .client, client.ownerHooks()) };
    errdefer {
        manager.resource.destroy();
        manager.resource.deinit();
    }
    try manager.resource.setHandler(Manager, manager, managerRequest, null);
    try client.materialize(&manager.resource.runtime);
    self.managers.appendAssumeCapacity(manager);
}

fn managerRequest(_: *protocol.wp_linux_drm_syncobj_manager_v1.Resource, request: protocol.wp_linux_drm_syncobj_manager_v1.Request, manager: *Manager) !void {
    switch (request) {
        .destroy => manager.owner.destroyManager(manager),
        .import_timeline => |args| {
            defer _ = std.c.close(args.fd);
            manager.owner.importTimeline(manager, args.id, args.fd);
        },
        .get_surface => |args| try manager.owner.createSurface(manager, args.id, args.surface),
    }
}

fn importTimeline(self: *Self, manager: *Manager, id: u32, fd: std.posix.fd_t) void {
    const timeline = self.device.?.importTimeline(fd) catch |err| switch (err) {
        error.InvalidTimeline => return manager.client.postProtocolError(&manager.resource.runtime, @intCast(protocol.wp_linux_drm_syncobj_manager_v1.@"error".invalid_timeline), "failed to import DRM syncobj timeline"),
        error.OutOfMemory => return manager.client.postOutOfMemory(&manager.resource.runtime, "importing DRM syncobj timeline"),
    };
    self.createTimeline(manager, id, timeline) catch {
        timeline.unreference();
        manager.client.postOutOfMemory(&manager.resource.runtime, "creating DRM syncobj timeline resource");
    };
}

fn createTimeline(self: *Self, manager: *Manager, id: u32, timeline: *DrmSyncobj.Timeline) !void {
    try self.timelines.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Timeline);
    errdefer self.allocator.destroy(value);
    value.* = .{ .owner = self, .client = manager.client, .resource = .init(self.allocator, id, 1, .client, manager.client.ownerHooks()), .timeline = timeline };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Timeline, value, timelineRequest, null);
    try manager.client.materialize(&value.resource.runtime);
    self.timelines.appendAssumeCapacity(value);
}

fn createSurface(self: *Self, manager: *Manager, id: u32, surface_object: u32) !void {
    try self.surfaces.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(SyncSurface);
    errdefer self.allocator.destroy(value);
    value.* = .{ .owner = self, .client = manager.client, .resource = undefined, .surface = null };
    switch (self.compositor.attachExplicitSync(manager.client, surface_object, .{
        .context = value,
        .validate_commit = validateCommit,
        .take_pending = takePending,
        .surface_destroyed = surfaceDestroyed,
    })) {
        .attached => |surface| value.surface = surface,
        .already_exists => {
            self.allocator.destroy(value);
            manager.client.postProtocolError(&manager.resource.runtime, @intCast(protocol.wp_linux_drm_syncobj_manager_v1.@"error".surface_exists), "wl_surface already has an explicit synchronization object");
            return;
        },
        .not_live, .wrong_client => {
            self.allocator.destroy(value);
            manager.client.postImplementationError(&manager.resource.runtime, "surface is not an exact live same-client Wayring wl_surface");
            return;
        },
    }
    errdefer self.compositor.detachExplicitSync(value.surface.?, value);
    value.resource = .init(self.allocator, id, 1, .client, manager.client.ownerHooks());
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(SyncSurface, value, surfaceRequest, null);
    try manager.client.materialize(&value.resource.runtime);
    self.surfaces.appendAssumeCapacity(value);
}

fn timelineRequest(_: *protocol.wp_linux_drm_syncobj_timeline_v1.Resource, request: protocol.wp_linux_drm_syncobj_timeline_v1.Request, value: *Timeline) !void {
    switch (request) {
        .destroy => value.owner.destroyTimeline(value),
    }
}

fn surfaceRequest(_: *protocol.wp_linux_drm_syncobj_surface_v1.Resource, request: protocol.wp_linux_drm_syncobj_surface_v1.Request, value: *SyncSurface) !void {
    switch (request) {
        .destroy => value.owner.destroySurface(value),
        .set_acquire_point => |args| setPoint(value, .acquire, args.timeline, args.point_hi, args.point_lo),
        .set_release_point => |args| setPoint(value, .release, args.timeline, args.point_hi, args.point_lo),
    }
}

fn setPoint(value: *SyncSurface, kind: enum { acquire, release }, timeline_object: u32, high: u32, low: u32) void {
    if (value.surface == null) {
        value.client.postProtocolError(&value.resource.runtime, @intCast(protocol.wp_linux_drm_syncobj_surface_v1.@"error".no_surface), "the associated wl_surface was destroyed");
        return;
    }
    const timeline = value.owner.findTimeline(value.client, timeline_object) orelse {
        value.client.postImplementationError(&value.resource.runtime, "timeline is not an exact live same-client syncobj timeline");
        return;
    };
    const point = timeline.timeline.point(pointValue(high, low));
    const destination = switch (kind) {
        .acquire => &value.pending_acquire,
        .release => &value.pending_release,
    };
    if (destination.*) |*old| old.deinit();
    destination.* = point;
}

fn findTimeline(self: *Self, client: *server.Client, object_id: u32) ?*Timeline {
    const installed = client.lookup(object_id) orelse return null;
    for (self.timelines.items) |timeline| {
        if (timeline.client == client and &timeline.resource.runtime == installed) return timeline;
    }
    return null;
}

fn validateCommit(context: *anyopaque, attachment: WayringCompositor.ExplicitSyncAttachment) bool {
    const value: *SyncSurface = @ptrCast(@alignCast(context));
    const validation_error = validateAttachment(attachment, value.pending_acquire != null, value.pending_release != null, if (value.pending_acquire != null and value.pending_release != null) pointsConflict(value.pending_acquire.?, value.pending_release.?) else false) orelse return true;
    const code: i64 = switch (validation_error) {
        .no_buffer => protocol.wp_linux_drm_syncobj_surface_v1.@"error".no_buffer,
        .unsupported_buffer => protocol.wp_linux_drm_syncobj_surface_v1.@"error".unsupported_buffer,
        .no_acquire_point => protocol.wp_linux_drm_syncobj_surface_v1.@"error".no_acquire_point,
        .no_release_point => protocol.wp_linux_drm_syncobj_surface_v1.@"error".no_release_point,
        .conflicting_points => protocol.wp_linux_drm_syncobj_surface_v1.@"error".conflicting_points,
    };
    value.client.postProtocolError(&value.resource.runtime, @intCast(code), @tagName(validation_error));
    return false;
}

fn takePending(context: *anyopaque, buffer: *linux_dmabuf.Buffer, listener: WayringCompositor.ExplicitSyncReadyListener) error{OutOfMemory}!WayringCompositor.ExplicitSyncUse {
    const surface: *SyncSurface = @ptrCast(@alignCast(context));
    const acquire = surface.pending_acquire.?;
    const release = surface.pending_release.?;
    surface.pending_acquire = null;
    surface.pending_release = null;
    return DmabufUse.create(surface.owner, buffer, acquire, release, listener);
}

fn surfaceDestroyed(context: *anyopaque) void {
    const value: *SyncSurface = @ptrCast(@alignCast(context));
    value.surface = null;
    clearPending(value);
}

const DmabufUse = struct {
    owner: *Self,
    buffer: *linux_dmabuf.Buffer,
    acquire: DrmSyncobj.Point,
    release_point: DrmSyncobj.Point,
    listener: WayringCompositor.ExplicitSyncReadyListener,
    refs: usize = 1,
    ready: bool,
    waiter: ?*DrmSyncobj.Waiter = null,
    gpu_accessed: bool = false,

    fn create(owner: *Self, buffer: *linux_dmabuf.Buffer, acquire: DrmSyncobj.Point, release_point: DrmSyncobj.Point, listener: WayringCompositor.ExplicitSyncReadyListener) error{OutOfMemory}!WayringCompositor.ExplicitSyncUse {
        const self = owner.allocator.create(DmabufUse) catch {
            var a = acquire;
            var r = release_point;
            a.deinit();
            r.deinit();
            return error.OutOfMemory;
        };
        buffer.retainSnapshot();
        self.* = .{ .owner = owner, .buffer = buffer, .acquire = acquire, .release_point = release_point, .listener = listener, .ready = acquire.signaled() };
        if (!self.ready) self.waiter = acquire.wait(self, acquireReady) catch {
            buffer.releaseSnapshot();
            self.acquire.deinit();
            self.release_point.deinit();
            owner.allocator.destroy(self);
            return error.OutOfMemory;
        };
        owner.use_count += 1;
        return .{ .context = self, .is_ready = isReady, .retain = retain, .release = release, .render_source = renderSource };
    }

    fn isReady(context: *anyopaque) bool {
        const self: *DmabufUse = @ptrCast(@alignCast(context));
        if (self.ready) return true;
        if (!self.acquire.signaled()) return false;
        if (self.waiter) |waiter| waiter.destroy();
        self.waiter = null;
        self.ready = true;
        return true;
    }

    fn acquireReady(context: *anyopaque, ready: bool) void {
        const self: *DmabufUse = @ptrCast(@alignCast(context));
        self.waiter = null;
        if (!ready) {
            if (self.acquire.signaled()) {
                self.ready = true;
                self.listener.ready(self.listener.context, self, true);
                return;
            }
            self.waiter = self.acquire.wait(self, acquireReady) catch {
                log.warn("failed to re-arm DRM syncobj acquire waiter", .{});
                self.listener.ready(self.listener.context, self, false);
                return;
            };
            return;
        }
        self.ready = true;
        self.listener.ready(self.listener.context, self, true);
    }

    fn retain(context: *anyopaque) void {
        const self: *DmabufUse = @ptrCast(@alignCast(context));
        self.refs += 1;
    }

    fn release(context: *anyopaque) void {
        const self: *DmabufUse = @ptrCast(@alignCast(context));
        self.refs -= 1;
        if (self.refs != 0) return;
        if (self.waiter) |waiter| waiter.destroy();
        const succeeded = if (self.gpu_accessed) completed: {
            const fd = self.buffer.exportCompletionFence() orelse break :completed false;
            defer _ = std.c.close(fd);
            break :completed self.release_point.importSyncFile(fd);
        } else self.release_point.signal();
        if (!succeeded) {
            log.err("failed to signal accepted DRM syncobj release point", .{});
            self.owner.failure_listener.failed(self.owner.failure_listener.context);
        }
        self.acquire.deinit();
        self.release_point.deinit();
        self.buffer.releaseSnapshot();
        self.owner.use_count -= 1;
        self.owner.allocator.destroy(self);
    }

    fn renderSource(context: *anyopaque) render.DmabufSource {
        const self: *DmabufUse = @ptrCast(@alignCast(context));
        var source = self.buffer.renderSource();
        source.context = self;
        source.retain = retain;
        source.release = release;
        source.begin_cpu_read = beginCpuRead;
        source.end_cpu_read = endCpuRead;
        source.export_read_fence = exportReadFence;
        return source;
    }

    fn beginCpuRead(context: *anyopaque) bool {
        const self: *DmabufUse = @ptrCast(@alignCast(context));
        if (!isReady(self)) return false;
        const source = self.buffer.renderSource();
        return source.begin_cpu_read(source.context);
    }

    fn endCpuRead(context: *anyopaque) bool {
        const self: *DmabufUse = @ptrCast(@alignCast(context));
        const source = self.buffer.renderSource();
        return source.end_cpu_read(source.context);
    }

    fn exportReadFence(context: *anyopaque, _: u8) ?std.posix.fd_t {
        const self: *DmabufUse = @ptrCast(@alignCast(context));
        if (!isReady(self)) return null;
        self.gpu_accessed = true;
        return self.acquire.exportSyncFile();
    }
};

fn destroySurface(self: *Self, value: *SyncSurface) void {
    if (value.surface) |surface| self.compositor.detachExplicitSync(surface, value);
    clearPending(value);
    remove(SyncSurface, &self.surfaces, value);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}

fn clearPending(value: *SyncSurface) void {
    if (value.pending_acquire) |*point| point.deinit();
    if (value.pending_release) |*point| point.deinit();
    value.pending_acquire = null;
    value.pending_release = null;
}

fn destroyTimeline(self: *Self, value: *Timeline) void {
    remove(Timeline, &self.timelines, value);
    value.resource.destroy();
    value.resource.deinit();
    value.timeline.unreference();
    self.allocator.destroy(value);
}

fn destroyManager(self: *Self, value: *Manager) void {
    remove(Manager, &self.managers, value);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}

fn remove(comptime T: type, list: *std.ArrayList(*T), value: *T) void {
    for (list.items, 0..) |item, i| if (item == value) {
        _ = list.swapRemove(i);
        return;
    };
    unreachable;
}

fn pointValue(high: u32, low: u32) u64 {
    return @as(u64, high) << 32 | low;
}

fn pointsConflict(acquire: DrmSyncobj.Point, release_point: DrmSyncobj.Point) bool {
    return acquire.timeline == release_point.timeline and acquire.value >= release_point.value;
}

const ValidationError = enum { no_buffer, unsupported_buffer, no_acquire_point, no_release_point, conflicting_points };

fn validateAttachment(attachment: WayringCompositor.ExplicitSyncAttachment, has_acquire: bool, has_release: bool, conflicting: bool) ?ValidationError {
    return switch (attachment) {
        .none, .null_buffer => if (has_acquire or has_release) .no_buffer else null,
        .unsupported => .unsupported_buffer,
        .dmabuf => if (!has_acquire) .no_acquire_point else if (!has_release) .no_release_point else if (conflicting) .conflicting_points else null,
    };
}

test "syncobj scanner descriptors and errors are pinned" {
    try std.testing.expectEqual(@as(u32, 1), protocol.wp_linux_drm_syncobj_manager_v1.interface.version);
    try std.testing.expectEqualStrings("import_timeline", protocol.wp_linux_drm_syncobj_manager_v1.request_messages[2].name);
    try std.testing.expectEqualStrings("set_acquire_point", protocol.wp_linux_drm_syncobj_surface_v1.request_messages[1].name);
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(protocol.wp_linux_drm_syncobj_manager_v1.@"error".invalid_timeline));
}

test "timeline values preserve request words" {
    try std.testing.expectEqual(@as(u64, 0x89ab_cdef_0123_4567), pointValue(0x89ab_cdef, 0x0123_4567));
}

test "validation and point conflict rules are pure" {
    var first: DrmSyncobj.Timeline = undefined;
    var second: DrmSyncobj.Timeline = undefined;
    try std.testing.expect(pointsConflict(.{ .timeline = &first, .value = 4 }, .{ .timeline = &first, .value = 4 }));
    try std.testing.expect(!pointsConflict(.{ .timeline = &first, .value = 5 }, .{ .timeline = &second, .value = 4 }));
    try std.testing.expect(validateAttachment(.none, false, false, false) == null);
    try std.testing.expectEqual(ValidationError.no_buffer, validateAttachment(.none, true, false, false).?);
    try std.testing.expect(validateAttachment(.null_buffer, false, false, false) == null);
    try std.testing.expectEqual(ValidationError.no_buffer, validateAttachment(.null_buffer, false, true, false).?);
    try std.testing.expectEqual(ValidationError.unsupported_buffer, validateAttachment(.unsupported, false, false, false).?);
    try std.testing.expectEqual(ValidationError.unsupported_buffer, validateAttachment(.unsupported, true, true, false).?);
    try std.testing.expectEqual(ValidationError.no_acquire_point, validateAttachment(.dmabuf, false, true, false).?);
    try std.testing.expectEqual(ValidationError.no_release_point, validateAttachment(.dmabuf, true, false, false).?);
    try std.testing.expectEqual(ValidationError.conflicting_points, validateAttachment(.dmabuf, true, true, true).?);
    try std.testing.expect(validateAttachment(.dmabuf, true, true, false) == null);
}
