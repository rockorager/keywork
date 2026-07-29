//! DRM timeline synchronization objects and Wayland event-loop waiters.

const std = @import("std");
const wayland = @import("wayland");
const render = @import("render/types.zig");

const c = @cImport({
    @cInclude("sys/stat.h");
    @cInclude("sys/sysmacros.h");
    @cInclude("xf86drm.h");
});
const linux = std.os.linux;
const wl = wayland.server.wl;
const log = std.log.scoped(.drm_syncobj);

pub const Device = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    event_loop: *wl.EventLoop,
    file: std.Io.File,
    timeline_count: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        event_loop: *wl.EventLoop,
        preferred_device: ?render.DrmDeviceId,
    ) error{Unavailable}!Device {
        const file = openDevice(io, preferred_device) orelse return error.Unavailable;
        return .{
            .allocator = allocator,
            .io = io,
            .event_loop = event_loop,
            .file = file,
            .timeline_count = 0,
        };
    }

    pub fn deinit(self: *Device) void {
        std.debug.assert(self.timeline_count == 0);
        self.file.close(self.io);
        self.* = undefined;
    }

    pub fn importTimeline(
        self: *Device,
        syncobj_fd: std.posix.fd_t,
    ) error{ InvalidTimeline, OutOfMemory }!*Timeline {
        var handle: u32 = 0;
        if (c.drmSyncobjFDToHandle(self.file.handle, syncobj_fd, &handle) != 0) {
            return error.InvalidTimeline;
        }
        const timeline = self.allocator.create(Timeline) catch {
            _ = c.drmSyncobjDestroy(self.file.handle, handle);
            return error.OutOfMemory;
        };
        timeline.* = .{
            .device = self,
            .handle = handle,
            .reference_count = 1,
        };
        self.timeline_count += 1;
        return timeline;
    }
};

pub const Timeline = struct {
    device: *Device,
    handle: u32,
    reference_count: usize,

    pub fn reference(self: *Timeline) void {
        std.debug.assert(self.reference_count > 0);
        self.reference_count += 1;
    }

    pub fn unreference(self: *Timeline) void {
        std.debug.assert(self.reference_count > 0);
        self.reference_count -= 1;
        if (self.reference_count != 0) return;
        if (c.drmSyncobjDestroy(self.device.file.handle, self.handle) != 0) {
            log.warn("failed to destroy DRM syncobj handle {d}", .{self.handle});
        }
        self.device.timeline_count -= 1;
        self.device.allocator.destroy(self);
    }

    pub fn point(self: *Timeline, value: u64) Point {
        self.reference();
        return .{ .timeline = self, .value = value };
    }
};

pub const Point = struct {
    timeline: *Timeline,
    value: u64,

    pub fn deinit(self: *Point) void {
        self.timeline.unreference();
        self.* = undefined;
    }

    pub fn signaled(self: Point) bool {
        var handle = self.timeline.handle;
        var value = self.value;
        return c.drmSyncobjTimelineWait(
            self.timeline.device.file.handle,
            &handle,
            &value,
            1,
            0,
            0,
            null,
        ) == 0;
    }

    pub fn signal(self: Point) bool {
        var handle = self.timeline.handle;
        var value = self.value;
        return c.drmSyncobjTimelineSignal(
            self.timeline.device.file.handle,
            &handle,
            &value,
            1,
        ) == 0;
    }

    pub fn exportSyncFile(self: Point) ?std.posix.fd_t {
        const drm_fd = self.timeline.device.file.handle;
        var temporary: u32 = 0;
        if (c.drmSyncobjCreate(drm_fd, 0, &temporary) != 0) return null;
        defer _ = c.drmSyncobjDestroy(drm_fd, temporary);
        if (c.drmSyncobjTransfer(
            drm_fd,
            temporary,
            0,
            self.timeline.handle,
            self.value,
            0,
        ) != 0) return null;
        var sync_file_fd: c_int = -1;
        if (c.drmSyncobjExportSyncFile(drm_fd, temporary, &sync_file_fd) != 0) return null;
        return sync_file_fd;
    }

    pub fn importSyncFile(self: Point, sync_file_fd: std.posix.fd_t) bool {
        const drm_fd = self.timeline.device.file.handle;
        var temporary: u32 = 0;
        if (c.drmSyncobjCreate(drm_fd, 0, &temporary) != 0) return false;
        defer _ = c.drmSyncobjDestroy(drm_fd, temporary);
        if (c.drmSyncobjImportSyncFile(drm_fd, temporary, sync_file_fd) != 0) return false;
        return c.drmSyncobjTransfer(
            drm_fd,
            self.timeline.handle,
            self.value,
            temporary,
            0,
            0,
        ) == 0;
    }

    pub fn wait(
        self: Point,
        context: *anyopaque,
        callback: Waiter.Callback,
    ) error{WaitFailed}!*Waiter {
        return Waiter.create(self, context, callback);
    }
};

pub const Commit = struct {
    acquire: Point,
    release: Point,

    pub fn deinit(self: *Commit) void {
        self.acquire.deinit();
        self.release.deinit();
        self.* = undefined;
    }
};

pub const Waiter = struct {
    point: Point,
    event_fd: std.posix.fd_t,
    event_source: *wl.EventSource,
    context: *anyopaque,
    callback: Callback,

    pub const Callback = *const fn (*anyopaque, bool) void;

    fn create(
        point: Point,
        context: *anyopaque,
        callback: Callback,
    ) error{WaitFailed}!*Waiter {
        const device = point.timeline.device;
        const event_result = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (std.posix.errno(event_result) != .SUCCESS) return error.WaitFailed;
        const event_fd: std.posix.fd_t = @intCast(event_result);
        errdefer _ = std.c.close(event_fd);

        const self = device.allocator.create(Waiter) catch return error.WaitFailed;
        errdefer device.allocator.destroy(self);
        self.* = .{
            .point = point,
            .event_fd = event_fd,
            .event_source = undefined,
            .context = context,
            .callback = callback,
        };
        self.event_source = device.event_loop.addFd(
            *Waiter,
            event_fd,
            .{ .readable = true, .hangup = true, .@"error" = true },
            handleEvent,
            self,
        ) catch return error.WaitFailed;
        errdefer self.event_source.remove();
        if (c.drmSyncobjEventfd(
            device.file.handle,
            point.timeline.handle,
            point.value,
            event_fd,
            0,
        ) != 0) return error.WaitFailed;
        return self;
    }

    pub fn destroy(self: *Waiter) void {
        const allocator = self.point.timeline.device.allocator;
        self.event_source.remove();
        _ = std.c.close(self.event_fd);
        allocator.destroy(self);
    }

    fn handleEvent(_: c_int, mask: wl.EventMask, self: *Waiter) c_int {
        const allocator = self.point.timeline.device.allocator;
        const callback = self.callback;
        const context = self.context;
        var ready = false;
        if (mask.readable) {
            var value: u64 = 0;
            const bytes = std.mem.asBytes(&value);
            ready = (std.posix.read(self.event_fd, bytes) catch 0) == bytes.len;
        }
        self.event_source.remove();
        _ = std.c.close(self.event_fd);
        callback(context, ready and !mask.hangup and !mask.@"error");
        allocator.destroy(self);
        return 0;
    }
};

fn openDevice(io: std.Io, preferred_device: ?render.DrmDeviceId) ?std.Io.File {
    if (openDeviceRange(io, preferred_device, "renderD", 128, 192)) |file| return file;
    return openDeviceRange(io, preferred_device, "card", 0, 64);
}

fn openDeviceRange(
    io: std.Io,
    preferred_device: ?render.DrmDeviceId,
    prefix: []const u8,
    first: u32,
    end: u32,
) ?std.Io.File {
    var number = first;
    while (number < end) : (number += 1) {
        var path_buffer: [64]u8 = undefined;
        const path = std.fmt.bufPrint(
            &path_buffer,
            "/dev/dri/{s}{d}",
            .{ prefix, number },
        ) catch unreachable;
        const file = std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write }) catch continue;
        if (!matchesDevice(file.handle, preferred_device) or !supportsRequiredFeatures(file.handle)) {
            file.close(io);
            continue;
        }
        log.info("using {s} for DRM timeline synchronization", .{path});
        return file;
    }
    return null;
}

fn matchesDevice(fd: std.posix.fd_t, preferred_device: ?render.DrmDeviceId) bool {
    const preferred = preferred_device orelse return true;
    var status: c.struct_stat = undefined;
    if (c.fstat(fd, &status) != 0) return false;
    return c.major(status.st_rdev) == preferred.major and
        c.minor(status.st_rdev) == preferred.minor;
}

fn supportsRequiredFeatures(drm_fd: std.posix.fd_t) bool {
    var capability: u64 = 0;
    if (c.drmGetCap(drm_fd, c.DRM_CAP_SYNCOBJ, &capability) != 0 or capability == 0) {
        return false;
    }
    capability = 0;
    if (c.drmGetCap(drm_fd, c.DRM_CAP_SYNCOBJ_TIMELINE, &capability) != 0 or
        capability == 0) return false;

    var source: u32 = 0;
    if (c.drmSyncobjCreate(drm_fd, 0, &source) != 0) return false;
    defer _ = c.drmSyncobjDestroy(drm_fd, source);

    const event_result = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    if (std.posix.errno(event_result) != .SUCCESS) return false;
    const event_fd: std.posix.fd_t = @intCast(event_result);
    defer _ = std.c.close(event_fd);
    if (c.drmSyncobjEventfd(drm_fd, source, 1, event_fd, 0) != 0) return false;
    var point: u64 = 1;
    if (c.drmSyncobjTimelineSignal(drm_fd, &source, &point, 1) != 0) return false;
    var poll_fds = [_]std.posix.pollfd{.{
        .fd = event_fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    if ((std.posix.poll(&poll_fds, 0) catch return false) != 1) return false;

    var temporary: u32 = 0;
    if (c.drmSyncobjCreate(drm_fd, 0, &temporary) != 0) return false;
    defer _ = c.drmSyncobjDestroy(drm_fd, temporary);
    if (c.drmSyncobjTransfer(drm_fd, temporary, 0, source, 1, 0) != 0) return false;
    var sync_file_fd: c_int = -1;
    if (c.drmSyncobjExportSyncFile(drm_fd, temporary, &sync_file_fd) != 0) return false;
    defer _ = std.c.close(sync_file_fd);

    var destination: u32 = 0;
    if (c.drmSyncobjCreate(drm_fd, 0, &destination) != 0) return false;
    defer _ = c.drmSyncobjDestroy(drm_fd, destination);
    if (c.drmSyncobjImportSyncFile(drm_fd, destination, sync_file_fd) != 0) return false;
    if (c.drmSyncobjTransfer(drm_fd, destination, 1, destination, 0, 0) != 0) return false;
    var destination_point: u64 = 1;
    return c.drmSyncobjTimelineWait(
        drm_fd,
        &destination,
        &destination_point,
        1,
        0,
        0,
        null,
    ) == 0;
}

test "timeline point ordering uses unsigned 64-bit values" {
    const high: u32 = 0xffff_ffff;
    const low: u32 = 0x1234_5678;
    const value = @as(u64, high) << 32 | low;
    try std.testing.expectEqual(@as(u64, 0xffff_ffff_1234_5678), value);
}
