//! Seat-scoped user idle notifications.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Seat = @import("seat.zig");

const ext = wayland.server.ext;
const wl = wayland.server.wl;
const log = std.log.scoped(.idle_notify);

allocator: std.mem.Allocator,
io: std.Io,
global: *wl.Global,
timer: *wl.EventSource,
notifications: std.ArrayList(*Notification),
inhibited: bool,
listener: Listener,

pub const Listener = struct {
    context: *anyopaque,
    failed: *const fn (*anyopaque) void,
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    io: std.Io,
    display: *wl.Server,
    listener: Listener,
) !void {
    self.* = .{
        .allocator = allocator,
        .io = io,
        .global = undefined,
        .timer = undefined,
        .notifications = .empty,
        .inhibited = false,
        .listener = listener,
    };
    errdefer self.notifications.deinit(allocator);
    self.timer = try display.getEventLoop().addTimer(*Self, handleTimer, self);
    errdefer self.timer.remove();
    self.global = try wl.Global.create(display, ext.IdleNotifierV1, 2, *Self, self, bind);
}

pub fn deinit(self: *Self) void {
    self.timer.remove();
    std.debug.assert(self.notifications.items.len == 0);
    self.global.destroy();
    self.notifications.deinit(self.allocator);
    self.* = undefined;
}

pub fn notifyActivity(self: *Self, seat: *Seat) void {
    const timestamp = now(self.io);
    for (self.notifications.items) |notification| {
        if (notification.seat != seat) continue;
        notification.setIdle(false);
        notification.restart(timestamp);
    }
    self.scheduleTimer() catch self.fail();
}

pub fn setInhibited(self: *Self, inhibited: bool) void {
    if (self.inhibited == inhibited) return;
    self.inhibited = inhibited;
    for (self.notifications.items) |notification| {
        if (!notification.obey_inhibitors) continue;
        notification.setIdle(false);
    }
    self.scheduleTimer() catch self.fail();
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = ext.IdleNotifierV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleNotifierRequest, null, self);
}

fn handleNotifierRequest(
    resource: *ext.IdleNotifierV1,
    request: ext.IdleNotifierV1.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .get_idle_notification => |get| self.createNotification(
            resource,
            get.id,
            get.timeout,
            get.seat,
            true,
        ),
        .get_input_idle_notification => |get| self.createNotification(
            resource,
            get.id,
            get.timeout,
            get.seat,
            false,
        ),
    }
}

fn createNotification(
    self: *Self,
    notifier: *ext.IdleNotifierV1,
    id: u32,
    timeout_ms: u32,
    seat_resource: *wl.Seat,
    obey_inhibitors: bool,
) void {
    const resource = ext.IdleNotificationV1.create(
        notifier.getClient(),
        notifier.getVersion(),
        id,
    ) catch {
        notifier.postNoMemory();
        return;
    };
    const notification = self.allocator.create(Notification) catch {
        resource.postNoMemory();
        resource.destroy();
        return;
    };
    notification.* = .{
        .manager = self,
        .resource = resource,
        .seat = Seat.fromResource(seat_resource),
        .timeout_ms = timeout_ms,
        .deadline = deadline(now(self.io), timeout_ms),
        .obey_inhibitors = obey_inhibitors,
        .idle = false,
    };
    self.notifications.append(self.allocator, notification) catch {
        self.allocator.destroy(notification);
        resource.postNoMemory();
        resource.destroy();
        return;
    };
    resource.setHandler(*Notification, handleNotificationRequest, handleNotificationDestroy, notification);
    self.scheduleTimer() catch self.fail();
}

fn handleNotificationRequest(
    resource: *ext.IdleNotificationV1,
    request: ext.IdleNotificationV1.Request,
    _: *Notification,
) void {
    switch (request) {
        .destroy => resource.destroy(),
    }
}

fn handleNotificationDestroy(_: *ext.IdleNotificationV1, notification: *Notification) void {
    const manager = notification.manager;
    for (manager.notifications.items, 0..) |candidate, index| {
        if (candidate != notification) continue;
        _ = manager.notifications.orderedRemove(index);
        manager.allocator.destroy(notification);
        manager.scheduleTimer() catch manager.fail();
        return;
    }
    unreachable;
}

fn handleTimer(self: *Self) c_int {
    self.scheduleTimer() catch self.fail();
    return 0;
}

fn scheduleTimer(self: *Self) std.posix.UnexpectedError!void {
    const timestamp = now(self.io);
    var earliest: ?i96 = null;
    for (self.notifications.items) |notification| {
        // Inhibition suppresses delivery without pausing elapsed inactivity.
        if (notification.idle or (self.inhibited and notification.obey_inhibitors)) continue;
        const notification_deadline = notification.deadline;
        if (notification_deadline <= timestamp) {
            notification.setIdle(true);
            continue;
        }
        earliest = if (earliest) |current|
            @min(current, notification_deadline)
        else
            notification_deadline;
    }
    const next = earliest orelse {
        try self.timer.timerUpdate(0);
        return;
    };
    try self.timer.timerUpdate(delayMilliseconds(timestamp, next));
}

fn fail(self: *Self) void {
    log.err("failed to update idle notification timer", .{});
    self.listener.failed(self.listener.context);
}

fn now(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn deadline(timestamp: i96, timeout_ms: u32) i96 {
    return timestamp + @as(i96, timeout_ms) * std.time.ns_per_ms;
}

fn delayMilliseconds(timestamp: i96, target: i96) c_int {
    std.debug.assert(target > timestamp);
    const nanoseconds = target - timestamp;
    const milliseconds = @divFloor(nanoseconds + std.time.ns_per_ms - 1, std.time.ns_per_ms);
    return @intCast(@min(milliseconds, std.math.maxInt(c_int)));
}

const Notification = struct {
    manager: *Self,
    resource: *ext.IdleNotificationV1,
    seat: *Seat,
    timeout_ms: u32,
    deadline: i96,
    obey_inhibitors: bool,
    idle: bool,

    fn restart(self: *Notification, timestamp: i96) void {
        self.deadline = deadline(timestamp, self.timeout_ms);
    }

    fn setIdle(self: *Notification, idle: bool) void {
        if (self.idle == idle) return;
        if (idle) {
            self.resource.sendIdled();
        } else {
            self.resource.sendResumed();
        }
        self.idle = idle;
    }
};

test "idle deadlines round timer delays up to the next millisecond" {
    try std.testing.expectEqual(@as(c_int, 1), delayMilliseconds(100, 101));
    try std.testing.expectEqual(
        @as(c_int, 2),
        delayMilliseconds(100, 100 + std.time.ns_per_ms + 1),
    );
}
