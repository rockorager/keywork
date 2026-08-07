//! Seat-scoped user idle notifications.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const NeutralIdleNotification = @import("../IdleNotification.zig");
const Seat = @import("seat.zig");

const ext = wayland.server.ext;
const wl = wayland.server.wl;
const log = std.log.scoped(.idle_notify);

allocator: std.mem.Allocator,
io: std.Io,
global: *wl.Global,
timer: *wl.EventSource,
core: *NeutralIdleNotification,
timer_generation: NeutralIdleNotification.TimerGeneration,
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
    core: *NeutralIdleNotification,
    listener: Listener,
) !void {
    self.* = .{
        .allocator = allocator,
        .io = io,
        .global = undefined,
        .timer = undefined,
        .core = core,
        .timer_generation = 0,
        .listener = listener,
    };
    self.timer = try display.getEventLoop().addTimer(*Self, handleTimer, self);
    errdefer self.timer.remove();
    self.global = try wl.Global.create(display, ext.IdleNotifierV1, 2, *Self, self, bind);
}

pub fn deinit(self: *Self) void {
    self.timer.remove();
    self.global.destroy();
    self.* = undefined;
}

pub fn clock(self: *Self) NeutralIdleNotification.Clock {
    return .{ .context = self, .now = now };
}

pub fn scheduler(self: *Self) NeutralIdleNotification.Scheduler {
    return .{ .context = self, .arm = armTimer };
}

pub fn notifyActivity(self: *Self, seat: *Seat) void {
    self.core.observeActivity(NeutralIdleNotification.SeatRef.fromPointer(seat)) catch self.fail();
}

pub fn setInhibited(self: *Self, inhibited: bool) void {
    self.core.setInhibited(inhibited) catch self.fail();
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
    const seat = Seat.fromResource(seat_resource);
    const client = seat.matureClientId(notifier.getClient()) orelse {
        notifier.postNoMemory();
        return;
    };
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
        .core_id = undefined,
    };
    notification.core_id = self.core.create(
        client,
        NeutralIdleNotification.SeatRef.fromPointer(seat),
        timeout_ms,
        obey_inhibitors,
        notification.endpoint(),
    ) catch |err| {
        self.allocator.destroy(notification);
        switch (err) {
            error.OutOfMemory, error.InvalidClient => resource.postNoMemory(),
            error.ScheduleFailed, error.TimerGenerationExhausted => self.fail(),
        }
        resource.destroy();
        return;
    };
    resource.setHandler(*Notification, handleNotificationRequest, handleNotificationDestroy, notification);
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
    manager.core.destroy(notification.core_id);
    manager.allocator.destroy(notification);
}

fn handleTimer(self: *Self) c_int {
    _ = self.core.timerFired(self.timer_generation) catch self.fail();
    return 0;
}

fn armTimer(
    context: *anyopaque,
    delay: NeutralIdleNotification.TimerDelay,
    generation: NeutralIdleNotification.TimerGeneration,
) error{ScheduleFailed}!void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.timer.timerUpdate(if (delay) |nanoseconds| delayMilliseconds(nanoseconds) else 0) catch
        return error.ScheduleFailed;
    self.timer_generation = generation;
}

fn fail(self: *Self) void {
    log.err("failed to update idle notification timer", .{});
    self.listener.failed(self.listener.context);
}

fn now(context: *anyopaque) NeutralIdleNotification.Timestamp {
    const self: *Self = @ptrCast(@alignCast(context));
    return std.Io.Clock.awake.now(self.io).nanoseconds;
}

fn delayMilliseconds(nanoseconds: NeutralIdleNotification.Timestamp) c_int {
    std.debug.assert(nanoseconds > 0);
    const milliseconds = @divFloor(nanoseconds - 1, std.time.ns_per_ms) + 1;
    return @intCast(@min(milliseconds, std.math.maxInt(c_int)));
}

const Notification = struct {
    manager: *Self,
    resource: *ext.IdleNotificationV1,
    core_id: NeutralIdleNotification.Id,

    fn endpoint(self: *Notification) NeutralIdleNotification.Endpoint {
        return .{
            .context = self,
            .idled = sendIdled,
            .resumed = sendResumed,
            .close = close,
        };
    }

    fn sendIdled(context: *anyopaque) void {
        const self: *Notification = @ptrCast(@alignCast(context));
        self.resource.sendIdled();
    }

    fn sendResumed(context: *anyopaque) void {
        const self: *Notification = @ptrCast(@alignCast(context));
        self.resource.sendResumed();
    }

    fn close(context: *anyopaque) void {
        const self: *Notification = @ptrCast(@alignCast(context));
        self.resource.destroy();
    }
};

test "idle deadlines round timer delays up to the next millisecond" {
    try std.testing.expectEqual(@as(c_int, 1), delayMilliseconds(1));
    try std.testing.expectEqual(
        @as(c_int, 2),
        delayMilliseconds(std.time.ns_per_ms + 1),
    );
}
