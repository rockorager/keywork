//! Presentation-clock constraints for surface commits.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Surface = @import("surface.zig");

const c = @cImport(@cInclude("time.h"));
const wl = wayland.server.wl;
const wp = wayland.server.wp;
const log = std.log.scoped(.commit_timing);

allocator: std.mem.Allocator,
global: *wl.Global,
timer: *wl.EventSource,
surfaces: *Surface.Store,
clock_id: u32,
timer_count: usize,
listener: Listener,

pub const Listener = struct {
    context: *anyopaque,
    failed: *const fn (*anyopaque) void,
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    surfaces: *Surface.Store,
    clock_id: u32,
    listener: Listener,
) !void {
    self.* = .{
        .allocator = allocator,
        .global = undefined,
        .timer = undefined,
        .surfaces = surfaces,
        .clock_id = clock_id,
        .timer_count = 0,
        .listener = listener,
    };
    self.timer = try display.getEventLoop().addTimer(*Self, handleTimer, self);
    errdefer self.timer.remove();
    self.global = try wl.Global.create(display, wp.CommitTimingManagerV1, 1, *Self, self, bind);
}

pub fn deinit(self: *Self) void {
    self.timer.remove();
    std.debug.assert(self.timer_count == 0);
    self.global.destroy();
    self.* = undefined;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = wp.CommitTimingManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleRequest, null, self);
}

fn handleRequest(
    resource: *wp.CommitTimingManagerV1,
    request: wp.CommitTimingManagerV1.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .get_timer => |get| Timer.create(
            self,
            resource,
            get.id,
            Surface.fromResource(get.surface),
        ),
    }
}

const Timer = struct {
    manager: *Self,
    surface: ?*Surface,

    fn create(
        manager: *Self,
        manager_resource: *wp.CommitTimingManagerV1,
        id: u32,
        surface: *Surface,
    ) void {
        const resource = wp.CommitTimerV1.create(
            manager_resource.getClient(),
            manager_resource.getVersion(),
            id,
        ) catch {
            manager_resource.postNoMemory();
            return;
        };
        const self = manager.allocator.create(Timer) catch {
            resource.postNoMemory();
            resource.destroy();
            return;
        };
        self.* = .{ .manager = manager, .surface = surface };
        surface.setCommitTimerHandler(.{
            .context = self,
            .surface_destroyed = handleSurfaceDestroyed,
        }) catch {
            manager.allocator.destroy(self);
            resource.destroy();
            manager_resource.postError(
                .commit_timer_exists,
                "wl_surface already has a commit timer object",
            );
            return;
        };
        manager.timer_count += 1;
        resource.setHandler(*Timer, Timer.handleRequest, Timer.handleDestroy, self);
    }

    fn handleRequest(
        resource: *wp.CommitTimerV1,
        request: wp.CommitTimerV1.Request,
        self: *Timer,
    ) void {
        switch (request) {
            .set_timestamp => |set| {
                const surface = self.surface orelse {
                    resource.postError(.surface_destroyed, "wl_surface no longer exists");
                    return;
                };
                const target = timestampNanoseconds(
                    set.tv_sec_hi,
                    set.tv_sec_lo,
                    set.tv_nsec,
                ) catch {
                    resource.postError(.invalid_timestamp, "tv_nsec must be less than one second");
                    return;
                };
                const now = clockNanoseconds(self.manager.clock_id) catch {
                    self.manager.fail();
                    return;
                };
                surface.setPendingCommitTimestamp(target, target <= now) catch {
                    resource.postError(.timestamp_exists, "wl_surface already has a timestamp");
                    return;
                };
                self.manager.scheduleTimer(now) catch self.manager.fail();
            },
            .destroy => resource.destroy(),
        }
    }

    fn handleDestroy(_: *wp.CommitTimerV1, self: *Timer) void {
        if (self.surface) |surface| surface.clearCommitTimerHandler(self);
        self.manager.timer_count -= 1;
        self.manager.allocator.destroy(self);
    }

    fn handleSurfaceDestroyed(context: *anyopaque) void {
        const self: *Timer = @ptrCast(@alignCast(context));
        self.surface = null;
    }
};

fn handleTimer(self: *Self) c_int {
    const now = clockNanoseconds(self.clock_id) catch {
        self.fail();
        return 0;
    };
    Surface.releaseTimedCommits(self.surfaces, now);
    self.scheduleTimer(now) catch self.fail();
    return 0;
}

fn scheduleTimer(self: *Self, now: i96) std.posix.UnexpectedError!void {
    const target = Surface.earliestCommitTimestamp(self.surfaces) orelse {
        try self.timer.timerUpdate(0);
        return;
    };
    try self.timer.timerUpdate(delayMilliseconds(now, target));
}

fn fail(self: *Self) void {
    log.err("failed to schedule commit timing constraint", .{});
    self.listener.failed(self.listener.context);
}

fn timestampNanoseconds(high: u32, low: u32, nanoseconds: u32) error{InvalidTimestamp}!i96 {
    if (nanoseconds >= std.time.ns_per_s) return error.InvalidTimestamp;
    const seconds = @as(u64, high) << 32 | low;
    return @as(i96, seconds) * std.time.ns_per_s + nanoseconds;
}

fn clockNanoseconds(clock_id: u32) error{ClockFailed}!i96 {
    var timestamp: c.struct_timespec = undefined;
    if (c.clock_gettime(@intCast(clock_id), &timestamp) != 0 or
        timestamp.tv_sec < 0 or timestamp.tv_nsec < 0)
    {
        return error.ClockFailed;
    }
    return @as(i96, timestamp.tv_sec) * std.time.ns_per_s + timestamp.tv_nsec;
}

fn delayMilliseconds(now: i96, target: i96) c_int {
    if (target <= now) return 1;
    const nanoseconds = target - now;
    const milliseconds = @divFloor(nanoseconds + std.time.ns_per_ms - 1, std.time.ns_per_ms);
    return @intCast(@min(milliseconds, std.math.maxInt(c_int)));
}

test "commit timestamps preserve protocol words and validate nanoseconds" {
    try std.testing.expectEqual(
        @as(i96, 0x1234_5678_9abc_def0) * std.time.ns_per_s + 999_999_999,
        try timestampNanoseconds(0x1234_5678, 0x9abc_def0, 999_999_999),
    );
    try std.testing.expectError(
        error.InvalidTimestamp,
        timestampNanoseconds(0, 0, std.time.ns_per_s),
    );
}

test "commit timing delays round up and never arm a zero-delay timer" {
    try std.testing.expectEqual(@as(c_int, 1), delayMilliseconds(100, 101));
    try std.testing.expectEqual(@as(c_int, 1), delayMilliseconds(100, 100));
    try std.testing.expectEqual(
        @as(c_int, 2),
        delayMilliseconds(100, 100 + std.time.ns_per_ms + 1),
    );
}
