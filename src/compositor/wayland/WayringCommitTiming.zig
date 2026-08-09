//! Scanner-backed presentation-clock constraints for generated surfaces.

const WayringCommitTiming = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayland = @import("wayland");
const wayring = @import("wayring");
const WayringCompositor = @import("WayringCompositor.zig");

const c = @cImport(@cInclude("time.h"));
const server = wayring.server;
const wl = wayland.server.wl;

pub const Listener = struct {
    context: *anyopaque,
    failed: *const fn (*anyopaque) void,
};

const Manager = struct {
    owner: *WayringCommitTiming,
    client: *server.Client,
    resource: protocol.wp_commit_timing_manager_v1.Resource,
};

const Timer = struct {
    owner: *WayringCommitTiming,
    client: *server.Client,
    resource: protocol.wp_commit_timer_v1.Resource,
    surface: ?WayringCompositor.SurfaceId,
};

allocator: std.mem.Allocator,
protocol_server: *server.Server,
compositor: *WayringCompositor,
clock_id: u32,
listener: Listener,
event_source: *wl.EventSource,
global: ?*const server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
timers: std.ArrayList(*Timer) = .empty,

pub fn init(self: *WayringCommitTiming, allocator: std.mem.Allocator, protocol_server: *server.Server, compositor: *WayringCompositor, event_loop: *wl.EventLoop, clock_id: u32, listener: Listener) !void {
    self.* = .{ .allocator = allocator, .protocol_server = protocol_server, .compositor = compositor, .clock_id = clock_id, .listener = listener, .event_source = undefined };
    self.event_source = try event_loop.addTimer(*WayringCommitTiming, timerFired, self);
}

pub fn publish(self: *WayringCommitTiming) !void {
    self.global = try self.protocol_server.addGlobal(protocol.wp_commit_timing_manager_v1, 1, WayringCommitTiming, self, bind);
}

pub fn unpublish(self: *WayringCommitTiming) void {
    self.protocol_server.removeGlobal(self.global.?) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}

pub fn destroyClientResources(self: *WayringCommitTiming, client: *server.Client) void {
    var i = self.timers.items.len;
    while (i > 0) {
        i -= 1;
        if (self.timers.items[i].client == client) self.destroyTimer(self.timers.items[i]);
    }
    i = self.managers.items.len;
    while (i > 0) {
        i -= 1;
        if (self.managers.items[i].client == client) self.destroyManager(self.managers.items[i]);
    }
}

pub fn deinit(self: *WayringCommitTiming) void {
    std.debug.assert(self.global == null and self.timers.items.len == 0 and self.managers.items.len == 0);
    self.event_source.remove();
    self.timers.deinit(self.allocator);
    self.managers.deinit(self.allocator);
    self.* = undefined;
}

fn bind(client: *server.Client, id: u32, version: u32, self: *WayringCommitTiming) !void {
    try self.managers.ensureUnusedCapacity(self.allocator, 1);
    const manager = try self.allocator.create(Manager);
    errdefer self.allocator.destroy(manager);
    manager.* = .{ .owner = self, .client = client, .resource = .init(self.allocator, id, version, .client, client.ownerHooks()) };
    errdefer {
        manager.resource.destroy();
        manager.resource.deinit();
    }
    try manager.resource.setHandler(Manager, manager, handleManager, null);
    try client.materialize(&manager.resource.runtime);
    self.managers.appendAssumeCapacity(manager);
}

fn handleManager(_: *protocol.wp_commit_timing_manager_v1.Resource, request: protocol.wp_commit_timing_manager_v1.Request, manager: *Manager) !void {
    switch (request) {
        .destroy => manager.owner.destroyManager(manager),
        .get_timer => |args| try manager.owner.createTimer(manager, args.id, args.surface),
    }
}

fn createTimer(self: *WayringCommitTiming, manager: *Manager, id: u32, surface_object: u32) !void {
    try self.timers.ensureUnusedCapacity(self.allocator, 1);
    const timer = try self.allocator.create(Timer);
    errdefer self.allocator.destroy(timer);
    timer.* = .{ .owner = self, .client = manager.client, .resource = undefined, .surface = null };
    switch (self.compositor.attachCommitTiming(manager.client, surface_object, .{ .context = timer, .surface_destroyed = surfaceDestroyed })) {
        .attached => |surface| timer.surface = surface,
        .already_exists => {
            self.allocator.destroy(timer);
            manager.client.postProtocolError(&manager.resource.runtime, @intCast(protocol.wp_commit_timing_manager_v1.@"error".commit_timer_exists), "wl_surface already has a commit timer object");
            return;
        },
        .not_live, .wrong_client => {
            self.allocator.destroy(timer);
            manager.client.postImplementationError(&manager.resource.runtime, "surface is not an exact live same-client Wayring wl_surface");
            return;
        },
    }
    errdefer self.compositor.detachCommitTiming(timer.surface.?, timer);
    timer.resource = .init(self.allocator, id, 1, .client, manager.client.ownerHooks());
    errdefer {
        timer.resource.destroy();
        timer.resource.deinit();
    }
    try timer.resource.setHandler(Timer, timer, handleTimer, null);
    try manager.client.materialize(&timer.resource.runtime);
    self.timers.appendAssumeCapacity(timer);
}

fn handleTimer(resource: *protocol.wp_commit_timer_v1.Resource, request: protocol.wp_commit_timer_v1.Request, timer: *Timer) !void {
    switch (request) {
        .destroy => timer.owner.destroyTimer(timer),
        .set_timestamp => |args| {
            const surface = timer.surface orelse {
                timer.client.postProtocolError(&resource.runtime, @intCast(protocol.wp_commit_timer_v1.@"error".surface_destroyed), "wl_surface no longer exists");
                return;
            };
            const target = timestampNanoseconds(args.tv_sec_hi, args.tv_sec_lo, args.tv_nsec) catch {
                timer.client.postProtocolError(&resource.runtime, @intCast(protocol.wp_commit_timer_v1.@"error".invalid_timestamp), "tv_nsec must be less than one second");
                return;
            };
            const now = clockNanoseconds(timer.owner.clock_id) catch return timer.owner.fail();
            switch (timer.owner.compositor.setPendingCommitTimestamp(surface, timer, target, target <= now)) {
                .set => timer.owner.schedule(now) catch timer.owner.fail(),
                .timestamp_exists => timer.client.postProtocolError(&resource.runtime, @intCast(protocol.wp_commit_timer_v1.@"error".timestamp_exists), "wl_surface already has a timestamp"),
                .surface_destroyed => timer.client.postProtocolError(&resource.runtime, @intCast(protocol.wp_commit_timer_v1.@"error".surface_destroyed), "wl_surface no longer exists"),
            }
        },
    }
}

fn timerFired(self: *WayringCommitTiming) c_int {
    const now = clockNanoseconds(self.clock_id) catch {
        self.fail();
        return 0;
    };
    self.compositor.releaseTimedCommits(now) catch {
        self.fail();
        return 0;
    };
    self.schedule(now) catch self.fail();
    return 0;
}

fn schedule(self: *WayringCommitTiming, now: i96) !void {
    const target = self.compositor.earliestCommitTimestamp() orelse return self.event_source.timerUpdate(0);
    try self.event_source.timerUpdate(delayMilliseconds(now, target));
}

fn fail(self: *WayringCommitTiming) void {
    self.listener.failed(self.listener.context);
}

fn surfaceDestroyed(context: *anyopaque) void {
    const timer: *Timer = @ptrCast(@alignCast(context));
    timer.surface = null;
}

fn destroyTimer(self: *WayringCommitTiming, timer: *Timer) void {
    if (timer.surface) |surface| self.compositor.detachCommitTiming(surface, timer);
    remove(Timer, &self.timers, timer);
    timer.resource.destroy();
    timer.resource.deinit();
    self.allocator.destroy(timer);
}

fn destroyManager(self: *WayringCommitTiming, manager: *Manager) void {
    remove(Manager, &self.managers, manager);
    manager.resource.destroy();
    manager.resource.deinit();
    self.allocator.destroy(manager);
}

fn remove(comptime T: type, list: *std.ArrayList(*T), value: *T) void {
    for (list.items, 0..) |item, i| if (item == value) {
        _ = list.swapRemove(i);
        return;
    };
    unreachable;
}

fn timestampNanoseconds(high: u32, low: u32, nanoseconds: u32) error{InvalidTimestamp}!i96 {
    if (nanoseconds >= std.time.ns_per_s) return error.InvalidTimestamp;
    return @as(i96, @as(u64, high) << 32 | low) * std.time.ns_per_s + nanoseconds;
}

fn clockNanoseconds(clock_id: u32) error{ClockFailed}!i96 {
    var timestamp: c.struct_timespec = undefined;
    if (c.clock_gettime(@intCast(clock_id), &timestamp) != 0 or timestamp.tv_sec < 0 or timestamp.tv_nsec < 0) return error.ClockFailed;
    return @as(i96, timestamp.tv_sec) * std.time.ns_per_s + timestamp.tv_nsec;
}

fn delayMilliseconds(now: i96, target: i96) c_int {
    if (target <= now) return 1;
    return @intCast(@min(@divFloor(target - now + std.time.ns_per_ms - 1, std.time.ns_per_ms), std.math.maxInt(c_int)));
}

test "commit timing descriptors and timer arithmetic" {
    try std.testing.expectEqualStrings("get_timer", protocol.wp_commit_timing_manager_v1.request_messages[1].name);
    try std.testing.expectEqualStrings("set_timestamp", protocol.wp_commit_timer_v1.request_messages[0].name);
    try std.testing.expectEqual(@as(c_int, 1), delayMilliseconds(100, 101));
    try std.testing.expectError(error.InvalidTimestamp, timestampNanoseconds(0, 0, std.time.ns_per_s));
}
