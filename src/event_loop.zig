//! Small Linux epoll event loop with a Wayland prepare-read integration point.

const std = @import("std");

const linux = std.os.linux;

pub const EventLoop = struct {
    allocator: std.mem.Allocator,
    epoll_fd: i32,
    wake_fd: i32,
    sources: std.ArrayList(Slot) = .empty,
    free_slots: std.ArrayList(u32) = .empty,
    pending_destroy: std.ArrayList(PendingDestroy) = .empty,
    timers: std.ArrayList(*Timer) = .empty,
    wayland_sources: std.ArrayList(WaylandSlot) = .empty,
    dispatching: bool = false,

    const wake_token = std.math.maxInt(u64);
    const wayland_token_bit: u64 = 1 << 63;
    const max_events = 16;

    /// A reusable source slot. Epoll tokens pack the slot index with its
    /// generation, so events queued for a removed (or removed-and-reused)
    /// slot are recognized as stale and dropped instead of dispatching to
    /// the wrong source.
    const Slot = struct {
        generation: u32 = 0,
        source: ?Source = null,
        registered: bool = false,
    };

    const WaylandSlot = struct {
        source: ?WaylandSource,
        prepared: bool = false,
        ready_events: u32 = 0,
    };

    /// Destruction deferred until the current dispatch batch completes, so
    /// a callback removing a source (including itself) never frees memory
    /// that this batch still touches.
    const PendingDestroy = struct {
        ctx: *anyopaque,
        destroy: *const fn (allocator: std.mem.Allocator, ctx: *anyopaque) void,
    };

    fn sourceToken(index: u32, generation: u32) u64 {
        return (@as(u64, generation & 0x7fff_ffff) << 32) | index;
    }

    fn waylandToken(index: u32) u64 {
        return wayland_token_bit | index;
    }

    pub const SourceCallback = *const fn (ctx: *anyopaque, loop: *EventLoop, events: u32) anyerror!void;
    pub const TimerCallback = *const fn (ctx: *anyopaque, loop: *EventLoop, expirations: u64) anyerror!void;
    pub const Source = struct {
        fd: i32,
        events: u32,
        ctx: *anyopaque,
        callback: SourceCallback,
        destroy_ctx: ?*const fn (allocator: std.mem.Allocator, ctx: *anyopaque) void = null,
    };

    pub const SourceHandle = struct {
        index: u32,
        generation: u32,
    };

    pub const WaylandSource = struct {
        fd: i32,
        ctx: *anyopaque,
        prepare: *const fn (ctx: *anyopaque) anyerror!u32,
        finish: *const fn (ctx: *anyopaque, events: u32) anyerror!bool,
    };

    pub const Timer = struct {
        fd: i32,
        ctx: *anyopaque,
        callback: TimerCallback,
        destroy_ctx: ?*const fn (allocator: std.mem.Allocator, ctx: *anyopaque) void = null,

        pub fn arm(self: *Timer, delay_ms: u64, interval_ms: u64) !void {
            const spec: linux.itimerspec = .{
                .it_interval = try millisecondsAllowZero(interval_ms),
                .it_value = try milliseconds(delay_ms),
            };
            try linuxVoid(linux.timerfd_settime(self.fd, .{ .ABSTIME = false }, &spec, null));
        }

        pub fn disarm(self: *Timer) void {
            const zero: linux.timespec = .{ .sec = 0, .nsec = 0 };
            const spec: linux.itimerspec = .{ .it_interval = zero, .it_value = zero };
            linuxVoid(linux.timerfd_settime(self.fd, .{ .ABSTIME = false }, &spec, null)) catch {};
        }
    };

    pub fn init(allocator: std.mem.Allocator) !EventLoop {
        const epoll_fd = try linuxFd(linux.epoll_create1(linux.EPOLL.CLOEXEC));
        errdefer _ = linux.close(epoll_fd);

        const wake_fd = try linuxFd(linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK));
        errdefer _ = linux.close(wake_fd);

        var self: EventLoop = .{
            .allocator = allocator,
            .epoll_fd = epoll_fd,
            .wake_fd = wake_fd,
        };
        errdefer self.sources.deinit(allocator);

        var event: linux.epoll_event = .{
            .events = linux.EPOLL.IN,
            .data = .{ .u64 = wake_token },
        };
        try linuxVoid(linux.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, wake_fd, &event));
        return self;
    }

    pub fn deinit(self: *EventLoop) void {
        self.flushPendingDestroy();
        for (self.timers.items) |timer| {
            _ = linux.close(timer.fd);
            if (timer.destroy_ctx) |destroy| destroy(self.allocator, timer.ctx);
            self.allocator.destroy(timer);
        }
        self.timers.deinit(self.allocator);
        for (self.sources.items) |slot| {
            const source = slot.source orelse continue;
            if (source.destroy_ctx) |destroy| destroy(self.allocator, source.ctx);
        }
        self.sources.deinit(self.allocator);
        self.free_slots.deinit(self.allocator);
        self.pending_destroy.deinit(self.allocator);
        for (self.wayland_sources.items) |slot| {
            if (slot.source) |source| {
                if (slot.prepared) _ = source.finish(source.ctx, 0) catch false;
            }
        }
        self.wayland_sources.deinit(self.allocator);
        _ = linux.close(self.wake_fd);
        _ = linux.close(self.epoll_fd);
    }

    pub fn addFd(self: *EventLoop, source: Source) !void {
        _ = try self.addFdSource(source, true);
    }

    /// Allocates a stable source slot. Disabled sources retain their slot so
    /// integrations with infallible toggle callbacks can change epoll state
    /// without allocating.
    pub fn addFdSource(self: *EventLoop, source: Source, enabled: bool) !SourceHandle {
        const index: u32 = if (self.free_slots.pop()) |free_index| free_index else blk: {
            const new_index: u32 = @intCast(self.sources.items.len);
            try self.sources.append(self.allocator, .{});
            break :blk new_index;
        };
        const slot = &self.sources.items[index];
        std.debug.assert(slot.source == null);
        slot.source = source;
        slot.registered = false;
        errdefer {
            slot.source = null;
            self.free_slots.append(self.allocator, index) catch {};
        }

        if (enabled) {
            var event: linux.epoll_event = .{
                .events = source.events,
                .data = .{ .u64 = sourceToken(index, slot.generation) },
            };
            try linuxVoid(linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, source.fd, &event));
            slot.registered = true;
        }
        return .{ .index = index, .generation = slot.generation };
    }

    /// Changes an existing source's interest set without allocating. The
    /// handle generation changes when disabling so readiness already queued
    /// by epoll cannot be delivered after a toggle.
    pub fn updateFdSource(self: *EventLoop, handle: *SourceHandle, events: u32, enabled: bool) !void {
        if (handle.index >= self.sources.items.len) return error.InvalidSourceHandle;
        const slot = &self.sources.items[handle.index];
        if (slot.source == null or slot.generation != handle.generation) return error.InvalidSourceHandle;
        slot.source.?.events = events;

        if (slot.registered and !enabled) {
            _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, slot.source.?.fd, null);
            slot.registered = false;
            slot.generation +%= 1;
            handle.generation = slot.generation;
            return;
        }
        if (!slot.registered and enabled) {
            var event: linux.epoll_event = .{
                .events = events,
                .data = .{ .u64 = sourceToken(handle.index, slot.generation) },
            };
            try linuxVoid(linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, slot.source.?.fd, &event));
            slot.registered = true;
            return;
        }
        if (slot.registered) {
            var event: linux.epoll_event = .{
                .events = events,
                .data = .{ .u64 = sourceToken(handle.index, slot.generation) },
            };
            try linuxVoid(linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_MOD, slot.source.?.fd, &event));
        }
    }

    pub fn removeFdSource(self: *EventLoop, handle: SourceHandle) void {
        if (handle.index >= self.sources.items.len) return;
        const slot = &self.sources.items[handle.index];
        if (slot.source == null or slot.generation != handle.generation) return;
        self.removeSlot(handle.index);
    }

    pub fn removeFd(self: *EventLoop, fd: i32) void {
        for (self.sources.items, 0..) |*slot, index| {
            const source = slot.source orelse continue;
            if (source.fd != fd) continue;
            self.removeSlot(@intCast(index));
        }
    }

    fn removeSlot(self: *EventLoop, index: u32) void {
        const slot = &self.sources.items[index];
        const source = slot.source orelse return;
        if (slot.registered) _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, source.fd, null);
        // The generation bump invalidates any events already queued for this
        // slot in the current dispatch batch.
        slot.generation +%= 1;
        slot.source = null;
        slot.registered = false;
        self.free_slots.append(self.allocator, index) catch {};
        if (source.destroy_ctx) |destroy| self.deferDestroy(.{ .ctx = source.ctx, .destroy = destroy });
    }

    fn deferDestroy(self: *EventLoop, pending: PendingDestroy) void {
        if (self.dispatching) {
            self.pending_destroy.append(self.allocator, pending) catch {
                // Keep the current dispatch memory-safe. This leaks only the
                // callback context on OOM rather than freeing storage that a
                // later event in this batch may still reference.
                return;
            };
            return;
        }
        self.destroyPending(pending);
    }

    fn destroyPending(self: *EventLoop, pending: PendingDestroy) void {
        pending.destroy(self.allocator, pending.ctx);
    }

    fn flushPendingDestroy(self: *EventLoop) void {
        for (self.pending_destroy.items) |pending| self.destroyPending(pending);
        self.pending_destroy.clearRetainingCapacity();
    }

    pub fn addTimer(self: *EventLoop, ctx: *anyopaque, callback: TimerCallback) !*Timer {
        const fd = try linuxFd(linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true, .NONBLOCK = true }));
        errdefer _ = linux.close(fd);

        const timer = try self.allocator.create(Timer);
        errdefer self.allocator.destroy(timer);
        timer.* = .{ .fd = fd, .ctx = ctx, .callback = callback };

        try self.timers.append(self.allocator, timer);
        errdefer _ = self.timers.pop();

        try self.addFd(.{
            .fd = fd,
            .events = linux.EPOLL.IN,
            .ctx = timer,
            .callback = timerSourceCallback,
        });

        return timer;
    }

    pub fn addRepeatingTimer(self: *EventLoop, interval_ms: u64, ctx: *anyopaque, callback: TimerCallback) !void {
        const timer = try self.addTimer(ctx, callback);
        try timer.arm(interval_ms, interval_ms);
    }

    pub fn removeTimer(self: *EventLoop, timer: *Timer) void {
        self.removeFd(timer.fd);
        for (self.timers.items, 0..) |item, index| {
            if (item == timer) {
                _ = self.timers.swapRemove(index);
                break;
            }
        }
        _ = linux.close(timer.fd);
        if (timer.destroy_ctx) |destroy| destroy(self.allocator, timer.ctx);
        self.allocator.destroy(timer);
    }

    pub fn setWayland(self: *EventLoop, source: WaylandSource) !void {
        const index: u32 = @intCast(self.wayland_sources.items.len);
        try self.wayland_sources.append(self.allocator, .{ .source = source });
        errdefer _ = self.wayland_sources.pop();
        var event: linux.epoll_event = .{
            .events = linux.EPOLL.IN,
            .data = .{ .u64 = waylandToken(index) },
        };
        try linuxVoid(linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, source.fd, &event));
        errdefer _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, source.fd, null);
        try self.prepareWayland(index);
    }

    pub fn removeWayland(self: *EventLoop, fd: i32) void {
        for (self.wayland_sources.items) |*slot| {
            const source = slot.source orelse continue;
            if (source.fd != fd) continue;
            if (slot.prepared) _ = source.finish(source.ctx, 0) catch false;
            _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, source.fd, null);
            slot.* = .{ .source = null };
            return;
        }
    }

    /// Re-establishes every Wayland prepare-read after callers have queued
    /// protocol requests between dispatches (for example while painting).
    pub fn refreshWayland(self: *EventLoop) !void {
        for (self.wayland_sources.items, 0..) |*slot, index| {
            const source = slot.source orelse continue;
            if (slot.prepared) {
                _ = try source.finish(source.ctx, 0);
                slot.prepared = false;
            }
            try self.prepareWayland(@intCast(index));
        }
    }

    pub fn wake(self: *EventLoop) !void {
        const value: u64 = 1;
        const bytes = std.mem.asBytes(&value);
        const written = linux.write(self.wake_fd, bytes.ptr, bytes.len);
        switch (linux.errno(written)) {
            .SUCCESS => {},
            .AGAIN => {},
            else => return error.WakeFailed,
        }
    }

    /// Dispatches one batch. A zero timeout is fully non-blocking and is
    /// the mode used by libkeywork hosts watching `epoll_fd` themselves.
    /// Wayland sources remain unprepared afterward so rendering and WSI code
    /// may use their displays; the owner calls `refreshWayland` when done.
    pub fn dispatch(self: *EventLoop, timeout_ms: i32) !void {
        var events: [max_events]linux.epoll_event = undefined;
        const ready = try epollWait(self.epoll_fd, &events, timeout_ms);
        var source_events: [max_events]linux.epoll_event = undefined;
        var source_count: usize = 0;

        for (events[0..ready]) |event| {
            if (event.data.u64 == wake_token) {
                drainWake(self.wake_fd);
            } else if (event.data.u64 & wayland_token_bit != 0) {
                const index: usize = @intCast(event.data.u64 & ~wayland_token_bit);
                if (index < self.wayland_sources.items.len) {
                    self.wayland_sources.items[index].ready_events |= event.events;
                }
            } else {
                source_events[source_count] = event;
                source_count += 1;
            }
        }

        self.dispatching = true;
        defer {
            self.dispatching = false;
            self.flushPendingDestroy();
        }

        for (self.wayland_sources.items) |*slot| {
            const source = slot.source orelse continue;
            const source_ready = slot.ready_events;
            slot.ready_events = 0;
            if (!slot.prepared) continue;
            slot.prepared = false;
            if (!try source.finish(source.ctx, source_ready)) {
                _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, source.fd, null);
                slot.source = null;
            }
        }

        for (source_events[0..source_count]) |event| {
            const token = event.data.u64;
            const index: usize = @intCast(@as(u32, @truncate(token)));
            const generation: u32 = @truncate(token >> 32);
            if (index >= self.sources.items.len) continue;
            // Re-read the slot per event: an earlier callback in this
            // batch may have removed or replaced this source.
            const slot = self.sources.items[index];
            if ((slot.generation & 0x7fff_ffff) != generation) continue;
            if (!slot.registered) continue;
            const source = slot.source orelse continue;
            try source.callback(source.ctx, self, event.events);
        }
    }

    fn prepareWayland(self: *EventLoop, index: u32) !void {
        const slot = &self.wayland_sources.items[index];
        const source = slot.source orelse return;
        std.debug.assert(!slot.prepared);
        const requested_events = try source.prepare(source.ctx);
        var event: linux.epoll_event = .{
            .events = requested_events,
            .data = .{ .u64 = waylandToken(index) },
        };
        try linuxVoid(linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_MOD, source.fd, &event));
        slot.prepared = true;
    }
};

fn timerSourceCallback(ctx: *anyopaque, loop: *EventLoop, _: u32) !void {
    const timer: *EventLoop.Timer = @ptrCast(@alignCast(ctx));
    const expirations = try drainTimer(timer.fd);
    if (expirations > 0) try timer.callback(timer.ctx, loop, expirations);
}

fn drainTimer(fd: i32) !u64 {
    var expirations: u64 = 0;
    const bytes = std.mem.asBytes(&expirations);
    const read = linux.read(fd, bytes.ptr, bytes.len);
    switch (linux.errno(read)) {
        .SUCCESS => {
            if (read != bytes.len) return error.ShortTimerRead;
            return expirations;
        },
        .AGAIN => return 0,
        else => return error.TimerReadFailed,
    }
}

fn drainWake(fd: i32) void {
    var value: u64 = 0;
    const bytes = std.mem.asBytes(&value);
    while (true) {
        const read = linux.read(fd, bytes.ptr, bytes.len);
        switch (linux.errno(read)) {
            .SUCCESS => {},
            .AGAIN => return,
            else => return,
        }
    }
}

fn epollWait(fd: i32, events: *[EventLoop.max_events]linux.epoll_event, timeout_ms: i32) !usize {
    while (true) {
        const result = linux.epoll_wait(fd, events.ptr, EventLoop.max_events, timeout_ms);
        switch (linux.errno(result)) {
            .SUCCESS => return result,
            .INTR => continue,
            else => return error.EpollWaitFailed,
        }
    }
}

fn linuxFd(result: usize) !i32 {
    return switch (linux.errno(result)) {
        .SUCCESS => @intCast(result),
        else => error.LinuxSyscallFailed,
    };
}

fn linuxVoid(result: usize) !void {
    return switch (linux.errno(result)) {
        .SUCCESS => {},
        else => error.LinuxSyscallFailed,
    };
}

fn milliseconds(value: u64) !linux.timespec {
    if (value == 0) return error.InvalidTimerInterval;
    return millisecondsAllowZero(value);
}

fn millisecondsAllowZero(value: u64) !linux.timespec {
    const seconds = value / 1000;
    const millis = value % 1000;
    if (seconds > @as(u64, @intCast(std.math.maxInt(isize)))) return error.InvalidTimerInterval;
    return .{
        .sec = @intCast(seconds),
        .nsec = @intCast(millis * std.time.ns_per_ms),
    };
}

test "Wayland remains unprepared during owner work after dispatch" {
    const FakeWayland = struct {
        fd: i32,
        finishes: usize = 0,

        fn prepare(_: *anyopaque) !u32 {
            return linux.EPOLL.IN;
        }

        fn finish(ctx: *anyopaque, events: u32) !bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.finishes += 1;
            if (events & linux.EPOLL.IN != 0) {
                var byte: [1]u8 = undefined;
                _ = linux.read(self.fd, &byte, byte.len);
            }
            return true;
        }
    };

    var loop = try EventLoop.init(std.testing.allocator);
    defer loop.deinit();
    var fds: [2]i32 = undefined;
    try linuxVoid(linux.pipe2(&fds, .{ .NONBLOCK = true, .CLOEXEC = true }));
    defer for (fds) |fd| {
        _ = linux.close(fd);
    };

    var fake: FakeWayland = .{ .fd = fds[0] };
    try loop.setWayland(.{
        .fd = fds[0],
        .ctx = &fake,
        .prepare = FakeWayland.prepare,
        .finish = FakeWayland.finish,
    });
    _ = linux.write(fds[1], "x", 1);
    try loop.dispatch(-1);

    try std.testing.expectEqual(@as(usize, 1), fake.finishes);
    try std.testing.expect(!loop.wayland_sources.items[0].prepared);
    try loop.refreshWayland();
    try std.testing.expect(loop.wayland_sources.items[0].prepared);
}

test "repeating timer fires and can quit the loop" {
    const TimerTest = struct {
        fired: u64 = 0,

        fn callback(ctx: *anyopaque, _: *EventLoop, expirations: u64) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.fired += expirations;
        }
    };

    var loop = try EventLoop.init(std.testing.allocator);
    defer loop.deinit();

    var context: TimerTest = .{};
    try loop.addRepeatingTimer(1, &context, TimerTest.callback);
    try loop.dispatch(-1);

    try std.testing.expect(context.fired > 0);
}

test "fd source toggles without reallocating its slot" {
    const PipeTest = struct {
        fired: usize = 0,

        fn callback(ctx: *anyopaque, _: *EventLoop, _: u32) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.fired += 1;
        }
    };

    var loop = try EventLoop.init(std.testing.allocator);
    defer loop.deinit();
    var fds: [2]i32 = undefined;
    try linuxVoid(linux.pipe2(&fds, .{ .NONBLOCK = true, .CLOEXEC = true }));
    defer for (fds) |fd| {
        _ = linux.close(fd);
    };

    var context: PipeTest = .{};
    var handle = try loop.addFdSource(.{
        .fd = fds[0],
        .events = linux.EPOLL.IN,
        .ctx = &context,
        .callback = PipeTest.callback,
    }, false);
    const index = handle.index;
    _ = linux.write(fds[1], "x", 1);
    try loop.dispatch(0);
    try std.testing.expectEqual(@as(usize, 0), context.fired);

    try loop.updateFdSource(&handle, linux.EPOLL.IN, true);
    try loop.dispatch(0);
    try std.testing.expectEqual(@as(usize, 1), context.fired);

    try loop.updateFdSource(&handle, linux.EPOLL.IN, false);
    try std.testing.expectEqual(index, handle.index);
    try loop.dispatch(0);
    try std.testing.expectEqual(@as(usize, 1), context.fired);
    loop.removeFdSource(handle);
}

test "source removed during dispatch does not fire stale events" {
    const PipeTest = struct {
        loop: *EventLoop,
        fired: usize = 0,
        other_fd: i32 = -1,
        self_fd: i32 = -1,

        fn callback(ctx: *anyopaque, loop: *EventLoop, _: u32) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.fired += 1;
            // Remove both sources mid-batch; the sibling's queued event
            // must be dropped via the generation check.
            loop.removeFd(self.self_fd);
            loop.removeFd(self.other_fd);
        }
    };

    var loop = try EventLoop.init(std.testing.allocator);
    defer loop.deinit();

    var fds_a: [2]i32 = undefined;
    try linuxVoid(linux.pipe2(&fds_a, .{ .NONBLOCK = true, .CLOEXEC = true }));
    defer for (fds_a) |fd| {
        _ = linux.close(fd);
    };
    var fds_b: [2]i32 = undefined;
    try linuxVoid(linux.pipe2(&fds_b, .{ .NONBLOCK = true, .CLOEXEC = true }));
    defer for (fds_b) |fd| {
        _ = linux.close(fd);
    };

    var context_a: PipeTest = .{ .loop = &loop, .self_fd = fds_a[0], .other_fd = fds_b[0] };
    var context_b: PipeTest = .{ .loop = &loop, .self_fd = fds_b[0], .other_fd = fds_a[0] };
    try loop.addFd(.{ .fd = fds_a[0], .events = linux.EPOLL.IN, .ctx = &context_a, .callback = PipeTest.callback });
    try loop.addFd(.{ .fd = fds_b[0], .events = linux.EPOLL.IN, .ctx = &context_b, .callback = PipeTest.callback });

    // Make both pipes readable so both events arrive in one epoll batch.
    _ = linux.write(fds_a[1], "x", 1);
    _ = linux.write(fds_b[1], "x", 1);
    try loop.dispatch(-1);

    try std.testing.expectEqual(@as(usize, 1), context_a.fired + context_b.fired);
}

test "removed slot is reused with a fresh generation" {
    const Noop = struct {
        fn callback(_: *anyopaque, _: *EventLoop, _: u32) !void {}
    };

    var loop = try EventLoop.init(std.testing.allocator);
    defer loop.deinit();

    var fds: [2]i32 = undefined;
    try linuxVoid(linux.pipe2(&fds, .{ .NONBLOCK = true, .CLOEXEC = true }));
    defer for (fds) |fd| {
        _ = linux.close(fd);
    };

    var ctx: u8 = 0;
    try loop.addFd(.{ .fd = fds[0], .events = linux.EPOLL.IN, .ctx = &ctx, .callback = Noop.callback });
    try std.testing.expectEqual(@as(usize, 1), loop.sources.items.len);
    loop.removeFd(fds[0]);
    try std.testing.expectEqual(@as(usize, 1), loop.free_slots.items.len);

    try loop.addFd(.{ .fd = fds[0], .events = linux.EPOLL.IN, .ctx = &ctx, .callback = Noop.callback });
    try std.testing.expectEqual(@as(usize, 1), loop.sources.items.len);
    try std.testing.expectEqual(@as(u32, 1), loop.sources.items[0].generation);
}
