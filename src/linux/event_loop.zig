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
    file_watches: std.ArrayList(*FileWatch) = .empty,
    wayland: ?WaylandSource = null,
    running: bool = true,
    dispatching: bool = false,

    const wake_token = std.math.maxInt(u64);
    const wayland_token = wake_token - 1;
    const max_events = 16;

    /// A reusable source slot. Epoll tokens pack the slot index with its
    /// generation, so events queued for a removed (or removed-and-reused)
    /// slot are recognized as stale and dropped instead of dispatching to
    /// the wrong source.
    const Slot = struct {
        generation: u32 = 0,
        source: ?Source = null,
    };

    /// Destruction deferred until the current dispatch batch completes, so
    /// a callback removing a source (including itself) never frees memory
    /// that this batch still touches.
    const PendingDestroy = union(enum) {
        source_ctx: struct {
            ctx: *anyopaque,
            destroy: *const fn (allocator: std.mem.Allocator, ctx: *anyopaque) void,
        },
        file_watch: *FileWatch,
    };

    fn sourceToken(index: u32, generation: u32) u64 {
        return (@as(u64, generation) << 32) | index;
    }

    pub const SourceCallback = *const fn (ctx: *anyopaque, loop: *EventLoop, events: u32) anyerror!void;
    pub const TimerCallback = *const fn (ctx: *anyopaque, loop: *EventLoop, expirations: u64) anyerror!void;
    pub const FileWatchCallback = *const fn (
        ctx: *anyopaque,
        loop: *EventLoop,
        path: []const u8,
        mask: u32,
        name: ?[]const u8,
    ) anyerror!void;

    pub const Source = struct {
        fd: i32,
        events: u32,
        ctx: *anyopaque,
        callback: SourceCallback,
        destroy_ctx: ?*const fn (allocator: std.mem.Allocator, ctx: *anyopaque) void = null,
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

    pub const FileWatch = struct {
        fd: i32,
        wd: i32,
        path: [:0]u8,
        ctx: *anyopaque,
        callback: FileWatchCallback,
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
        for (self.file_watches.items) |watch| self.destroyFileWatch(watch);
        self.file_watches.deinit(self.allocator);
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
        _ = linux.close(self.wake_fd);
        _ = linux.close(self.epoll_fd);
    }

    pub fn addFd(self: *EventLoop, source: Source) !void {
        const index: u32 = if (self.free_slots.pop()) |free_index| free_index else blk: {
            const new_index: u32 = @intCast(self.sources.items.len);
            try self.sources.append(self.allocator, .{});
            break :blk new_index;
        };
        const slot = &self.sources.items[index];
        std.debug.assert(slot.source == null);
        slot.source = source;
        errdefer {
            slot.source = null;
            self.free_slots.append(self.allocator, index) catch {};
        }

        var event: linux.epoll_event = .{
            .events = source.events,
            .data = .{ .u64 = sourceToken(index, slot.generation) },
        };
        try linuxVoid(linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, source.fd, &event));
    }

    pub fn removeFd(self: *EventLoop, fd: i32) void {
        _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, fd, null);
        for (self.sources.items, 0..) |*slot, index| {
            const source = slot.source orelse continue;
            if (source.fd != fd) continue;
            // The generation bump invalidates any events already queued for
            // this slot in the current dispatch batch.
            slot.generation +%= 1;
            slot.source = null;
            self.free_slots.append(self.allocator, @intCast(index)) catch {};
            if (source.destroy_ctx) |destroy| self.deferDestroy(.{ .source_ctx = .{ .ctx = source.ctx, .destroy = destroy } });
        }
    }

    fn deferDestroy(self: *EventLoop, pending: PendingDestroy) void {
        if (self.dispatching) {
            self.pending_destroy.append(self.allocator, pending) catch {
                // Allocation failure: destroying immediately risks a stale
                // reference within this batch, but leaking is worse.
                self.destroyPending(pending);
            };
            return;
        }
        self.destroyPending(pending);
    }

    fn destroyPending(self: *EventLoop, pending: PendingDestroy) void {
        switch (pending) {
            .source_ctx => |entry| entry.destroy(self.allocator, entry.ctx),
            .file_watch => |watch| self.destroyFileWatch(watch),
        }
    }

    fn flushPendingDestroy(self: *EventLoop) void {
        for (self.pending_destroy.items) |pending| self.destroyPending(pending);
        self.pending_destroy.clearRetainingCapacity();
    }

    fn destroyFileWatch(self: *EventLoop, watch: *FileWatch) void {
        _ = linux.inotify_rm_watch(watch.fd, watch.wd);
        _ = linux.close(watch.fd);
        self.allocator.free(watch.path);
        self.allocator.destroy(watch);
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

    pub fn addFileWatch(self: *EventLoop, path: []const u8, ctx: *anyopaque, callback: FileWatchCallback) !*FileWatch {
        const path_z = try self.allocator.dupeZ(u8, path);
        errdefer self.allocator.free(path_z);

        const fd = try linuxFd(linux.inotify_init1(linux.IN.CLOEXEC | linux.IN.NONBLOCK));
        errdefer _ = linux.close(fd);

        const mask = linux.IN.MODIFY |
            linux.IN.CLOSE_WRITE |
            linux.IN.MOVED_TO |
            linux.IN.DELETE_SELF |
            linux.IN.MOVE_SELF |
            linux.IN.ATTRIB;
        const wd = try inotifyWatchFd(linux.inotify_add_watch(fd, path_z.ptr, mask));

        const watch = try self.allocator.create(FileWatch);
        errdefer self.allocator.destroy(watch);
        watch.* = .{
            .fd = fd,
            .wd = wd,
            .path = path_z,
            .ctx = ctx,
            .callback = callback,
        };

        try self.addFd(.{
            .fd = fd,
            .events = linux.EPOLL.IN,
            .ctx = watch,
            .callback = fileWatchSourceCallback,
        });
        errdefer self.removeFd(fd);

        try self.file_watches.append(self.allocator, watch);
        return watch;
    }

    pub fn removeFileWatch(self: *EventLoop, watch: *FileWatch) void {
        self.removeFd(watch.fd);
        for (self.file_watches.items, 0..) |item, index| {
            if (item == watch) {
                _ = self.file_watches.swapRemove(index);
                break;
            }
        }
        // Deferred while dispatching: fileWatchSourceCallback may still be
        // draining this watch's fd further up the stack.
        self.deferDestroy(.{ .file_watch = watch });
    }

    pub fn setWayland(self: *EventLoop, source: WaylandSource) !void {
        self.wayland = source;
        var event: linux.epoll_event = .{
            .events = linux.EPOLL.IN,
            .data = .{ .u64 = wayland_token },
        };
        try linuxVoid(linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, source.fd, &event));
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

    pub fn quit(self: *EventLoop) void {
        self.running = false;
        self.wake() catch {};
    }

    pub fn run(self: *EventLoop) !void {
        var events: [max_events]linux.epoll_event = undefined;
        while (self.running) {
            if (self.wayland) |wayland| {
                const requested_events = try wayland.prepare(wayland.ctx);
                var event: linux.epoll_event = .{
                    .events = requested_events,
                    .data = .{ .u64 = wayland_token },
                };
                try linuxVoid(linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_MOD, wayland.fd, &event));
            }

            const ready = try epollWait(self.epoll_fd, &events, -1);
            var wayland_events: u32 = 0;
            var source_events: [max_events]linux.epoll_event = undefined;
            var source_count: usize = 0;

            for (events[0..ready]) |event| {
                if (event.data.u64 == wake_token) {
                    drainWake(self.wake_fd);
                } else if (event.data.u64 == wayland_token) {
                    wayland_events |= event.events;
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

            if (self.wayland) |wayland| {
                if (!try wayland.finish(wayland.ctx, wayland_events)) self.running = false;
            }

            for (source_events[0..source_count]) |event| {
                const token = event.data.u64;
                const index: usize = @intCast(@as(u32, @truncate(token)));
                const generation: u32 = @truncate(token >> 32);
                if (index >= self.sources.items.len) continue;
                // Re-read the slot per event: an earlier callback in this
                // batch may have removed or replaced this source.
                const slot = self.sources.items[index];
                if (slot.generation != generation) continue;
                const source = slot.source orelse continue;
                try source.callback(source.ctx, self, event.events);
            }
        }
    }
};

fn timerSourceCallback(ctx: *anyopaque, loop: *EventLoop, _: u32) !void {
    const timer: *EventLoop.Timer = @ptrCast(@alignCast(ctx));
    const expirations = try drainTimer(timer.fd);
    if (expirations > 0) try timer.callback(timer.ctx, loop, expirations);
}

fn fileWatchSourceCallback(ctx: *anyopaque, loop: *EventLoop, _: u32) !void {
    const watch: *EventLoop.FileWatch = @ptrCast(@alignCast(ctx));
    var buffer: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
    while (true) {
        const read = linux.read(watch.fd, &buffer, buffer.len);
        switch (linux.errno(read)) {
            .SUCCESS => {
                if (read == 0) return;
                try dispatchFileWatchEvents(watch, loop, buffer[0..read]);
            },
            .AGAIN => return,
            else => return error.FileWatchReadFailed,
        }
    }
}

fn dispatchFileWatchEvents(watch: *EventLoop.FileWatch, loop: *EventLoop, bytes: []align(@alignOf(linux.inotify_event)) u8) !void {
    var offset: usize = 0;
    while (offset + @sizeOf(linux.inotify_event) <= bytes.len) {
        const event: *const linux.inotify_event = @ptrCast(@alignCast(bytes.ptr + offset));
        const name = if (event.getName()) |event_name| event_name[0..event_name.len] else null;
        try watch.callback(watch.ctx, loop, watch.path[0..watch.path.len], event.mask, name);
        offset += @sizeOf(linux.inotify_event) + event.len;
    }
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

fn inotifyWatchFd(result: usize) !i32 {
    return switch (linux.errno(result)) {
        .SUCCESS => @intCast(result),
        .NOENT => error.FileWatchNotFound,
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

test "repeating timer fires and can quit the loop" {
    const TimerTest = struct {
        fired: u64 = 0,

        fn callback(ctx: *anyopaque, loop: *EventLoop, expirations: u64) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.fired += expirations;
            loop.quit();
        }
    };

    var loop = try EventLoop.init(std.testing.allocator);
    defer loop.deinit();

    var context: TimerTest = .{};
    try loop.addRepeatingTimer(1, &context, TimerTest.callback);
    try loop.run();

    try std.testing.expect(context.fired > 0);
}

test "file watch fires and can quit the loop" {
    const FileWatchTest = struct {
        fired: bool = false,

        fn callback(
            ctx: *anyopaque,
            loop: *EventLoop,
            path: []const u8,
            mask: u32,
            name: ?[]const u8,
        ) !void {
            _ = path;
            _ = name;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (mask & (linux.IN.MODIFY | linux.IN.CLOSE_WRITE) != 0) {
                self.fired = true;
                loop.quit();
            }
        }
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "watched.lua", .data = "return 1\n" });

    const watched_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "watched.lua" });
    defer std.testing.allocator.free(watched_path);

    var loop = try EventLoop.init(std.testing.allocator);
    defer loop.deinit();

    var context: FileWatchTest = .{};
    _ = try loop.addFileWatch(watched_path, &context, FileWatchTest.callback);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "watched.lua", .data = "return 2\n" });
    try loop.run();

    try std.testing.expect(context.fired);
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
            loop.quit();
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
    try loop.run();

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

test "file watch can remove itself from its own callback" {
    const SelfRemove = struct {
        watch: ?*EventLoop.FileWatch = null,
        fired: bool = false,

        fn callback(
            ctx: *anyopaque,
            loop: *EventLoop,
            path: []const u8,
            mask: u32,
            name: ?[]const u8,
        ) !void {
            _ = path;
            _ = name;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (mask & (linux.IN.MODIFY | linux.IN.CLOSE_WRITE) != 0 and !self.fired) {
                self.fired = true;
                // Removal defers destruction: the dispatch code above this
                // frame still drains the watch fd after we return.
                if (self.watch) |watch| loop.removeFileWatch(watch);
                self.watch = null;
                loop.quit();
            }
        }
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "watched.lua", .data = "return 1\n" });

    const watched_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "watched.lua" });
    defer std.testing.allocator.free(watched_path);

    var loop = try EventLoop.init(std.testing.allocator);
    defer loop.deinit();

    var context: SelfRemove = .{};
    context.watch = try loop.addFileWatch(watched_path, &context, SelfRemove.callback);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "watched.lua", .data = "return 2\n" });
    try loop.run();

    try std.testing.expect(context.fired);
}
