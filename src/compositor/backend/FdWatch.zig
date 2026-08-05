//! Compositor-owned adapter for readable Linux file-descriptor producers.
//!
//! Legacy protocol policy still runs on libwayland's event loop while the
//! native Wayring server runs on Keywork's io_uring loop. Backend devices use
//! this adapter so that their ownership and failure policy stay independent of
//! whichever outer loop currently hosts the compositor.

const FdWatch = @This();

const std = @import("std");
const linux = std.os.linux;
const keywork_loop = @import("keywork-loop");
const wayland = @import("wayland");

const EventLoop = keywork_loop.EventLoop;
const wl = wayland.server.wl;

loop: Loop,
registration: Registration,
context: *anyopaque,
callback: Callback,
active: bool,

pub const Loop = union(enum) {
    wayland: *wl.EventLoop,
    io_uring: *EventLoop,
};

pub const Events = struct {
    readable: bool = false,
    hangup: bool = false,
    error_occurred: bool = false,
};

pub const Callback = *const fn (*anyopaque, Events) void;

const Registration = union(enum) {
    wayland: *wl.EventSource,
    io_uring: EventLoop.SourceHandle,
};

pub fn init(
    self: *FdWatch,
    loop: Loop,
    fd: std.posix.fd_t,
    context: *anyopaque,
    callback: Callback,
) !void {
    self.* = .{
        .loop = loop,
        .registration = undefined,
        .context = context,
        .callback = callback,
        .active = true,
    };
    self.registration = switch (loop) {
        .wayland => |event_loop| .{ .wayland = try event_loop.addFd(
            *FdWatch,
            fd,
            .{ .readable = true },
            waylandReady,
            self,
        ) },
        .io_uring => |event_loop| .{ .io_uring = try event_loop.addFd(.{
            .fd = fd,
            .events = linux.POLL.IN,
            .ctx = self,
            .callback = ioUringReady,
        }) },
    };
}

pub fn deinit(self: *FdWatch) void {
    self.remove();
    self.* = undefined;
}

pub fn remove(self: *FdWatch) void {
    if (!self.active) return;
    self.active = false;
    switch (self.registration) {
        .wayland => |source| source.remove(),
        .io_uring => |handle| self.loop.io_uring.removeSource(handle),
    }
}

fn waylandReady(_: c_int, mask: wl.EventMask, self: *FdWatch) c_int {
    if (!self.active) return 0;
    self.callback(self.context, .{
        .readable = mask.readable,
        .hangup = mask.hangup,
        .error_occurred = mask.@"error",
    });
    return 0;
}

fn ioUringReady(context: *anyopaque, _: *EventLoop, events: u32) !void {
    const self: *FdWatch = @ptrCast(@alignCast(context));
    if (!self.active) return;
    self.callback(self.context, eventsFromPoll(events));
}

fn eventsFromPoll(events: u32) Events {
    return .{
        .readable = events & (linux.POLL.IN | linux.POLL.PRI) != 0,
        .hangup = events & linux.POLL.HUP != 0,
        .error_occurred = events & (linux.POLL.ERR | linux.POLL.NVAL) != 0,
    };
}

test "poll readiness maps to backend events" {
    try std.testing.expectEqual(Events{ .readable = true }, eventsFromPoll(linux.POLL.IN));
    try std.testing.expectEqual(
        Events{ .readable = true, .hangup = true, .error_occurred = true },
        eventsFromPoll(linux.POLL.PRI | linux.POLL.HUP | linux.POLL.ERR),
    );
}

test "io_uring watch dispatches readable descriptor" {
    var event_loop = try EventLoop.init(std.testing.allocator);
    defer event_loop.deinit();
    const result = linux.eventfd(1, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    if (linux.errno(result) != .SUCCESS) return error.EventFdFailed;
    const fd: i32 = @intCast(result);
    defer _ = linux.close(fd);

    const Context = struct {
        loop: *EventLoop,
        watch: *FdWatch,
        called: bool = false,

        fn ready(context_pointer: *anyopaque, events: Events) void {
            const context: *@This() = @ptrCast(@alignCast(context_pointer));
            context.called = events.readable;
            context.watch.remove();
            context.loop.quit();
        }
    };

    var watch: FdWatch = undefined;
    var context: Context = .{ .loop = &event_loop, .watch = &watch };
    try watch.init(.{ .io_uring = &event_loop }, fd, &context, Context.ready);
    defer watch.deinit();
    try event_loop.run();
    try std.testing.expect(context.called);
}
