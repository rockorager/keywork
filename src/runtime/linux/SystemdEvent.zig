//! Embeds one sd-event dispatcher in Keywork's completion event loop.
//!
//! sd-bus and sd-varlink sources attach to `event`. Keywork remains the
//! outer loop: io_uring watches sd-event's descriptor and performs every
//! prepare/wait/dispatch transition without starting a nested blocking loop.

const SystemdEvent = @This();

const std = @import("std");
const event_loop = @import("keywork-loop");
const systemd = @import("systemd_c");

const linux = std.os.linux;
const dispatch_budget = 64;

event: *systemd.sd_event,
source_handle: ?event_loop.EventLoop.SourceHandle = null,
bound_loop: ?*event_loop.EventLoop = null,

pub fn create(allocator: std.mem.Allocator) !*SystemdEvent {
    const self = try allocator.create(SystemdEvent);
    errdefer allocator.destroy(self);
    var event: ?*systemd.sd_event = null;
    try check(systemd.sd_event_new(&event));
    self.* = .{ .event = event.? };
    return self;
}

pub fn destroy(self: *SystemdEvent, allocator: std.mem.Allocator) void {
    std.debug.assert(self.bound_loop == null);
    std.debug.assert(self.source_handle == null);
    _ = systemd.sd_event_unref(self.event);
    allocator.destroy(self);
}

pub fn register(self: *SystemdEvent, loop: *event_loop.EventLoop) !void {
    if (self.bound_loop != null) return;
    std.debug.assert(self.source_handle == null);
    const fd = systemd.sd_event_get_fd(self.event);
    if (fd < 0) return error.SystemdEventFdUnavailable;

    loop.setPrePoll(.{ .ctx = self, .prepare = prepareCallback });
    errdefer loop.clearPrePoll(self);
    self.source_handle = try loop.addFd(.{
        .fd = fd,
        .events = linux.EPOLL.IN | linux.EPOLL.HUP | linux.EPOLL.ERR,
        .ctx = self,
        .callback = eventCallback,
    });
    self.bound_loop = loop;
}

pub fn unregister(self: *SystemdEvent) void {
    const loop = self.bound_loop orelse return;
    loop.clearPrePoll(self);
    if (self.source_handle) |handle| loop.removeSource(handle);
    self.source_handle = null;
    self.bound_loop = null;
}

pub fn sdEvent(self: *SystemdEvent) *systemd.sd_event {
    return self.event;
}

/// Drives pending work and leaves sd-event armed for its next outer poll
/// wait. A dispatch budget prevents a busy IPC peer from starving a Keywork
/// turn; prepare() will continue the drain before the following blocking wait.
fn prepare(self: *SystemdEvent) !bool {
    _ = systemd.sd_event_ref(self.event);
    defer _ = systemd.sd_event_unref(self.event);

    var dispatched = false;
    var remaining: usize = dispatch_budget;
    while (remaining > 0) : (remaining -= 1) {
        switch (systemd.sd_event_get_state(self.event)) {
            systemd.SD_EVENT_INITIAL => {
                const result = try checkResult(systemd.sd_event_prepare(self.event));
                if (result == 0) return dispatched;
            },
            systemd.SD_EVENT_PENDING => {
                const result = try checkResult(systemd.sd_event_dispatch(self.event));
                dispatched = true;
                if (result == 0) return dispatched;
            },
            systemd.SD_EVENT_ARMED => {
                // Sources can enqueue userspace work while Keywork dispatches
                // an unrelated outer-loop callback. Poll sd-event with a zero
                // timeout before the outer ring blocks again; its nested fd
                // need not become readable for that newly queued work.
                const result = try checkResult(systemd.sd_event_wait(self.event, 0));
                if (result == 0) continue;
            },
            systemd.SD_EVENT_FINISHED => return dispatched,
            else => return error.InvalidSystemdEventState,
        }
    }
    return dispatched;
}

fn ready(self: *SystemdEvent) !void {
    _ = systemd.sd_event_ref(self.event);
    defer _ = systemd.sd_event_unref(self.event);

    if (systemd.sd_event_get_state(self.event) == systemd.SD_EVENT_ARMED) {
        _ = try checkResult(systemd.sd_event_wait(self.event, 0));
    }
    _ = try self.prepare();
}

fn prepareCallback(ctx: *anyopaque) !bool {
    const self: *SystemdEvent = @ptrCast(@alignCast(ctx));
    return self.prepare();
}

fn eventCallback(ctx: *anyopaque, _: *event_loop.EventLoop, _: u32) !void {
    const self: *SystemdEvent = @ptrCast(@alignCast(ctx));
    try self.ready();
}

fn check(result: c_int) !void {
    if (result < 0) return error.SystemdEventFailed;
}

fn checkResult(result: c_int) !c_int {
    if (result < 0) return error.SystemdEventFailed;
    return result;
}

test "prepare dispatches pending sd-event work before io_uring blocks" {
    const Context = struct {
        loop: *event_loop.EventLoop,
        fired: bool = false,

        fn callback(_: ?*systemd.sd_event_source, userdata: ?*anyopaque) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.fired = true;
            self.loop.quit();
            return 0;
        }
    };

    var loop = try event_loop.EventLoop.init(std.testing.allocator);
    defer loop.deinit();
    const bridge = try SystemdEvent.create(std.testing.allocator);
    defer bridge.destroy(std.testing.allocator);
    try bridge.register(&loop);
    defer bridge.unregister();

    var context: Context = .{ .loop = &loop };
    var source: ?*systemd.sd_event_source = null;
    try check(systemd.sd_event_add_defer(bridge.event, &source, Context.callback, &context));
    defer _ = systemd.sd_event_source_unref(source.?);

    try loop.run();
    try std.testing.expect(context.fired);
}

test "pre-poll dispatches userspace work queued while sd-event is armed" {
    const Context = struct {
        bridge: *SystemdEvent,
        loop: *event_loop.EventLoop,
        source: ?*systemd.sd_event_source = null,
        fired: bool = false,

        fn queue(ctx: *anyopaque, _: *event_loop.EventLoop, _: u64) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try std.testing.expectEqual(systemd.SD_EVENT_ARMED, systemd.sd_event_get_state(self.bridge.event));
            try check(systemd.sd_event_add_defer(self.bridge.event, &self.source, dispatch, self));
        }

        fn dispatch(_: ?*systemd.sd_event_source, userdata: ?*anyopaque) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.fired = true;
            self.loop.quit();
            return 0;
        }
    };

    var loop = try event_loop.EventLoop.init(std.testing.allocator);
    defer loop.deinit();
    const bridge = try SystemdEvent.create(std.testing.allocator);
    defer bridge.destroy(std.testing.allocator);
    try bridge.register(&loop);
    defer bridge.unregister();

    var context: Context = .{ .bridge = bridge, .loop = &loop };
    defer {
        if (context.source) |source| _ = systemd.sd_event_source_unref(source);
    }
    const timer = try loop.addTimer(&context, Context.queue);
    defer loop.removeTimer(timer);
    try timer.arm(1, 0);

    try loop.run();
    try std.testing.expect(context.fired);
}
