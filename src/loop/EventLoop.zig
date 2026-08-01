//! Completion-native Linux event loop built around one owned io_uring.

const EventLoop = @This();

const std = @import("std");
const linux = std.os.linux;
const IoUringLoop = @import("IoUringLoop.zig");

allocator: std.mem.Allocator,
io: IoUringLoop,
wake_fd: i32,
sources: std.ArrayList(Slot) = .empty,
free_slots: std.ArrayList(u32) = .empty,
pending_ready: std.ArrayList(Ready) = .empty,
timers: std.ArrayList(*Timer) = .empty,
file_watches: std.ArrayList(*FileWatch) = .empty,
retired: ?*Registration = null,
wayland: ?WaylandState = null,
pre_poll: ?PrePollSource = null,
after_platform_hook: ?PhaseHook = null,
after_platform_context: ?*anyopaque = null,
end_turn_hook: ?PhaseHook = null,
end_turn_context: ?*anyopaque = null,
running: bool = false,
stop_requested: bool = false,
dispatching: bool = false,
wake_handle: ?SourceHandle = null,

const Slot = struct { generation: u32 = 0, registration: ?*Registration = null };
const Ready = struct { handle: SourceHandle, events: u32 };
const Registration = struct {
    loop: *EventLoop,
    source: Source,
    handle: SourceHandle,
    operation: ?IoUringLoop.Handle = null,
    armed_mask: u32 = 0,
    removed: bool = false,
    cancel_requested: bool = false,
    cancel_retry: bool = false,
    terminal: bool = false,
    retired_next: ?*Registration = null,
};
const WaylandState = struct {
    source: WaylandSource,
    operation: ?IoUringLoop.Handle = null,
    armed_mask: u32 = 0,
    desired_mask: u32 = linux.POLL.IN,
    cancel_requested: bool = false,
    cancel_retry: bool = false,
    clear_requested: bool = false,
    readiness: u32 = 0,
};

pub const SourceCallback = *const fn (*anyopaque, *EventLoop, u32) anyerror!void;
pub const TimerCallback = *const fn (*anyopaque, *EventLoop, u64) anyerror!void;
pub const FileWatchCallback = *const fn (*anyopaque, *EventLoop, []const u8, u32, ?[]const u8) anyerror!void;
pub const PhaseHook = *const fn (*anyopaque, *EventLoop) anyerror!void;
pub const Source = struct {
    fd: i32,
    events: u32,
    ctx: *anyopaque,
    callback: SourceCallback,
    destroy_ctx: ?*const fn (std.mem.Allocator, *anyopaque) void = null,
};
pub const SourceHandle = struct { index: u32, generation: u32 };
pub const WaylandSource = struct {
    fd: i32,
    ctx: *anyopaque,
    prepare: *const fn (*anyopaque) anyerror!WaylandPrepare,
    finish: *const fn (*anyopaque, u32) anyerror!bool,
};
pub const WaylandPrepare = struct { events: u32, dispatched_pending: bool = false };
pub const PrePollSource = struct { ctx: *anyopaque, prepare: *const fn (*anyopaque) anyerror!bool };

pub const Timer = struct {
    fd: i32,
    source_handle: ?SourceHandle,
    ctx: *anyopaque,
    callback: TimerCallback,
    wall_interval_ms: u64 = 0,
    destroy_ctx: ?*const fn (std.mem.Allocator, *anyopaque) void = null,
    removed: bool = false,
    pub fn arm(self: *Timer, delay_ms: u64, interval_ms: u64) !void {
        const spec: linux.itimerspec = .{ .it_interval = try millisecondsAllowZero(interval_ms), .it_value = try milliseconds(delay_ms) };
        try linuxVoid(linux.timerfd_settime(self.fd, .{ .ABSTIME = false }, &spec, null));
    }
    pub fn armWall(self: *Timer, interval_ms: u64) !void {
        var now: linux.timespec = undefined;
        try linuxVoid(linux.clock_gettime(.REALTIME, &now));
        const spec: linux.itimerspec = .{ .it_interval = try milliseconds(interval_ms), .it_value = try nextAlignedExpiration(now, interval_ms) };
        try linuxVoid(linux.timerfd_settime(self.fd, .{ .ABSTIME = true, .CANCEL_ON_SET = true }, &spec, null));
        self.wall_interval_ms = interval_ms;
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
    source_handle: ?SourceHandle,
    path: [:0]u8,
    ctx: *anyopaque,
    callback: FileWatchCallback,
    removed: bool = false,
};

pub fn init(allocator: std.mem.Allocator) !EventLoop {
    const wake_fd = try linuxFd(linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK));
    errdefer _ = linux.close(wake_fd);
    return .{ .allocator = allocator, .io = try IoUringLoop.init(allocator), .wake_fd = wake_fd };
}

/// Borrowers must terminate all operations they queued before calling deinit.
pub fn ioLoop(self: *EventLoop) *IoUringLoop {
    return &self.io;
}

pub fn deinit(self: *EventLoop) void {
    self.clearWayland();
    while (self.file_watches.items.len != 0) self.removeFileWatch(self.file_watches.items[self.file_watches.items.len - 1]);
    while (self.timers.items.len != 0) self.removeTimer(self.timers.items[self.timers.items.len - 1]);
    var index: usize = 0;
    while (index < self.sources.items.len) : (index += 1) if (self.sources.items[index].registration) |reg| self.removeSource(reg.handle);
    while (self.retired != null or self.wayland != null or self.io.hasActiveOperations()) {
        self.retryCancels();
        self.drive(true) catch @panic("failed to drain event-loop cancellations");
    }
    self.io.deinit();
    self.sources.deinit(self.allocator);
    self.free_slots.deinit(self.allocator);
    self.pending_ready.deinit(self.allocator);
    self.timers.deinit(self.allocator);
    self.file_watches.deinit(self.allocator);
    _ = linux.close(self.wake_fd);
}

pub fn addFd(self: *EventLoop, source: Source) !SourceHandle {
    const index: u32 = if (self.free_slots.pop()) |value| value else blk: {
        const value: u32 = @intCast(self.sources.items.len);
        try self.sources.append(self.allocator, .{});
        break :blk value;
    };
    const slot = &self.sources.items[index];
    const reg = try self.allocator.create(Registration);
    errdefer self.allocator.destroy(reg);
    reg.* = .{ .loop = self, .source = source, .handle = .{ .index = index, .generation = slot.generation } };
    slot.registration = reg;
    errdefer {
        slot.registration = null;
        self.free_slots.append(self.allocator, index) catch {};
    }
    try self.arm(reg);
    return reg.handle;
}

pub fn modifySource(self: *EventLoop, handle: SourceHandle, events: u32) void {
    const reg = self.lookup(handle) orelse return;
    reg.source.events = events;
    if (reg.operation != null and reg.armed_mask != events) self.requestCancel(reg);
}

pub fn removeSource(self: *EventLoop, handle: SourceHandle) void {
    const reg = self.lookup(handle) orelse return;
    const slot = &self.sources.items[handle.index];
    slot.registration = null;
    slot.generation +%= 1;
    self.free_slots.append(self.allocator, handle.index) catch {};
    reg.removed = true;
    reg.retired_next = self.retired;
    self.retired = reg;
    if (reg.operation != null) self.requestCancel(reg) else reg.terminal = true;
    self.reapRetired();
}

fn lookup(self: *EventLoop, handle: SourceHandle) ?*Registration {
    if (handle.index >= self.sources.items.len) return null;
    const slot = self.sources.items[handle.index];
    if (slot.generation != handle.generation) return null;
    return slot.registration;
}
fn arm(self: *EventLoop, reg: *Registration) !void {
    if (reg.removed or reg.operation != null) return;
    reg.armed_mask = reg.source.events;
    reg.operation = try self.io.queue(reg, pollComplete, reg, preparePoll);
}
fn preparePoll(context: *anyopaque, sqe: *linux.io_uring_sqe) void {
    const reg: *Registration = @ptrCast(@alignCast(context));
    sqe.prep_poll_add(reg.source.fd, reg.armed_mask);
}
fn pollComplete(context: *anyopaque, _: *IoUringLoop, completion: IoUringLoop.Completion) !void {
    const reg: *Registration = @ptrCast(@alignCast(context));
    reg.operation = null;
    reg.cancel_requested = false;
    if (completion.result >= 0) try reg.loop.pending_ready.append(reg.loop.allocator, .{ .handle = reg.handle, .events = @intCast(completion.result) }) else if (completion.result != -@as(i32, @intFromEnum(linux.E.CANCELED))) return error.PollFailed;
    if (reg.removed) {
        reg.terminal = true;
    } else if (completion.result < 0) {
        try reg.loop.arm(reg);
    }
}
fn requestCancel(self: *EventLoop, reg: *Registration) void {
    if (reg.cancel_requested or reg.operation == null) return;
    self.io.cancel(reg.operation.?) catch {
        reg.cancel_retry = true;
        return;
    };
    reg.cancel_requested = true;
    reg.cancel_retry = false;
}
fn retryCancels(self: *EventLoop) void {
    var reg = self.retired;
    while (reg) |item| : (reg = item.retired_next) if (item.cancel_retry) self.requestCancel(item);
    for (self.sources.items) |slot| if (slot.registration) |item| if (item.cancel_retry) self.requestCancel(item);
    if (self.wayland) |*state| if (state.cancel_retry) self.requestWaylandCancel(state);
}

fn reapRetired(self: *EventLoop) void {
    if (self.dispatching) return;
    var link = &self.retired;
    while (link.*) |reg| {
        if (!reg.terminal) {
            link = &reg.retired_next;
            continue;
        }
        link.* = reg.retired_next;
        if (reg.source.destroy_ctx) |destroy| destroy(self.allocator, reg.source.ctx);
        self.allocator.destroy(reg);
    }
}

pub fn addTimer(self: *EventLoop, ctx: *anyopaque, callback: TimerCallback) !*Timer {
    return self.addTimerWithClock(.MONOTONIC, ctx, callback);
}
pub fn addWallTimer(self: *EventLoop, ctx: *anyopaque, callback: TimerCallback) !*Timer {
    return self.addTimerWithClock(.REALTIME, ctx, callback);
}
fn addTimerWithClock(self: *EventLoop, clock: linux.timerfd_clockid_t, ctx: *anyopaque, callback: TimerCallback) !*Timer {
    const fd = try linuxFd(linux.timerfd_create(clock, .{ .CLOEXEC = true, .NONBLOCK = true }));
    errdefer _ = linux.close(fd);
    const timer = try self.allocator.create(Timer);
    errdefer self.allocator.destroy(timer);
    timer.* = .{ .fd = fd, .source_handle = null, .ctx = ctx, .callback = callback };
    try self.timers.append(self.allocator, timer);
    errdefer _ = self.timers.pop();
    timer.source_handle = try self.addFd(.{ .fd = fd, .events = linux.POLL.IN, .ctx = timer, .callback = timerSourceCallback, .destroy_ctx = destroyTimerContext });
    return timer;
}
pub fn removeTimer(self: *EventLoop, timer: *Timer) void {
    if (timer.removed) return;
    timer.removed = true;
    if (timer.source_handle) |handle| self.removeSource(handle);
    timer.source_handle = null;
    removePointer(Timer, &self.timers, timer);
}
pub fn addRepeatingTimer(self: *EventLoop, interval_ms: u64, ctx: *anyopaque, callback: TimerCallback) !void {
    const timer = try self.addTimer(ctx, callback);
    try timer.arm(interval_ms, interval_ms);
}
fn destroyTimerContext(allocator: std.mem.Allocator, context: *anyopaque) void {
    const timer: *Timer = @ptrCast(@alignCast(context));
    _ = linux.close(timer.fd);
    if (timer.destroy_ctx) |destroy| destroy(allocator, timer.ctx);
    allocator.destroy(timer);
}

pub fn addFileWatch(self: *EventLoop, path: []const u8, ctx: *anyopaque, callback: FileWatchCallback) !*FileWatch {
    const path_z = try self.allocator.dupeZ(u8, path);
    errdefer self.allocator.free(path_z);
    const fd = try linuxFd(linux.inotify_init1(linux.IN.CLOEXEC | linux.IN.NONBLOCK));
    errdefer _ = linux.close(fd);
    const mask = linux.IN.MODIFY | linux.IN.CLOSE_WRITE | linux.IN.CREATE | linux.IN.DELETE | linux.IN.MOVED_FROM | linux.IN.MOVED_TO | linux.IN.DELETE_SELF | linux.IN.MOVE_SELF | linux.IN.ATTRIB;
    const wd = try inotifyWatchFd(linux.inotify_add_watch(fd, path_z.ptr, mask));
    const watch = try self.allocator.create(FileWatch);
    errdefer self.allocator.destroy(watch);
    watch.* = .{ .fd = fd, .wd = wd, .source_handle = null, .path = path_z, .ctx = ctx, .callback = callback };
    try self.file_watches.append(self.allocator, watch);
    errdefer _ = self.file_watches.pop();
    watch.source_handle = try self.addFd(.{ .fd = fd, .events = linux.POLL.IN, .ctx = watch, .callback = fileWatchSourceCallback, .destroy_ctx = destroyFileWatchContext });
    return watch;
}
pub fn removeFileWatch(self: *EventLoop, watch: *FileWatch) void {
    if (watch.removed) return;
    watch.removed = true;
    if (watch.source_handle) |handle| self.removeSource(handle);
    watch.source_handle = null;
    removePointer(FileWatch, &self.file_watches, watch);
}
fn destroyFileWatchContext(allocator: std.mem.Allocator, context: *anyopaque) void {
    const watch: *FileWatch = @ptrCast(@alignCast(context));
    _ = linux.inotify_rm_watch(watch.fd, watch.wd);
    _ = linux.close(watch.fd);
    allocator.free(watch.path);
    allocator.destroy(watch);
}
fn removePointer(comptime T: type, list: *std.ArrayList(*T), value: *T) void {
    for (list.items, 0..) |item, index| if (item == value) {
        _ = list.swapRemove(index);
        return;
    };
}

pub fn setWayland(self: *EventLoop, source: WaylandSource) !void {
    if (self.wayland != null) return error.WaylandAlreadySet;
    self.wayland = .{ .source = source };
}
pub fn clearWayland(self: *EventLoop) void {
    if (self.wayland) |*state| {
        state.clear_requested = true;
        self.requestWaylandCancel(state);
        if (state.operation == null) self.wayland = null;
    }
}
fn requestWaylandCancel(self: *EventLoop, state: *WaylandState) void {
    if (state.cancel_requested or state.operation == null) return;
    self.io.cancel(state.operation.?) catch {
        state.cancel_retry = true;
        return;
    };
    state.cancel_requested = true;
    state.cancel_retry = false;
}
fn prepareWaylandPoll(context: *anyopaque, sqe: *linux.io_uring_sqe) void {
    const self: *EventLoop = @ptrCast(@alignCast(context));
    const state = &self.wayland.?;
    sqe.prep_poll_add(state.source.fd, state.armed_mask);
}
fn waylandComplete(context: *anyopaque, _: *IoUringLoop, completion: IoUringLoop.Completion) !void {
    const self: *EventLoop = @ptrCast(@alignCast(context));
    const state = if (self.wayland) |*value| value else return;
    state.operation = null;
    state.cancel_requested = false;
    state.cancel_retry = false;
    if (completion.result >= 0) state.readiness |= @intCast(completion.result) else if (completion.result != -@as(i32, @intFromEnum(linux.E.CANCELED))) return error.WaylandPollFailed;
    if (state.clear_requested) self.wayland = null;
}
fn armWayland(self: *EventLoop) !void {
    const state = if (self.wayland) |*value| value else return;
    if (state.clear_requested or state.operation != null) return;
    state.armed_mask = state.desired_mask;
    state.operation = try self.io.queue(self, waylandComplete, self, prepareWaylandPoll);
}

pub fn setPrePoll(self: *EventLoop, source: PrePollSource) void {
    std.debug.assert(self.pre_poll == null);
    self.pre_poll = source;
}
pub fn clearPrePoll(self: *EventLoop, ctx: *anyopaque) void {
    if (self.pre_poll) |source| if (source.ctx == ctx) {
        self.pre_poll = null;
    };
}
pub fn setAfterPlatformHook(self: *EventLoop, context: *anyopaque, hook: PhaseHook) void {
    self.after_platform_context = context;
    self.after_platform_hook = hook;
}
pub fn clearAfterPlatformHook(self: *EventLoop) void {
    self.after_platform_hook = null;
    self.after_platform_context = null;
}
pub fn setEndTurnHook(self: *EventLoop, context: *anyopaque, hook: PhaseHook) void {
    self.end_turn_context = context;
    self.end_turn_hook = hook;
}
pub fn clearEndTurnHook(self: *EventLoop) void {
    self.end_turn_hook = null;
    self.end_turn_context = null;
}
pub fn wake(self: *EventLoop) !void {
    const value: u64 = 1;
    const bytes = std.mem.asBytes(&value);
    const result = linux.write(self.wake_fd, bytes.ptr, bytes.len);
    switch (linux.errno(result)) {
        .SUCCESS, .AGAIN => {},
        else => return error.WakeFailed,
    }
}
pub fn quit(self: *EventLoop) void {
    self.stop_requested = true;
    self.running = false;
    self.wake() catch {};
}
pub fn run(self: *EventLoop) !void {
    if (self.stop_requested) {
        self.stop_requested = false;
        return;
    }
    self.running = true;
    self.ensureWake() catch |err| {
        self.running = false;
        return err;
    };
    defer {
        self.running = false;
        self.stop_requested = false;
    }
    while (self.running) try self.turn(true);
}
fn ensureWake(self: *EventLoop) !void {
    if (self.wake_handle == null) self.wake_handle = try self.addFd(.{ .fd = self.wake_fd, .events = linux.POLL.IN, .ctx = self, .callback = wakeCallback });
}
fn wakeCallback(context: *anyopaque, _: *EventLoop, _: u32) !void {
    const self: *EventLoop = @ptrCast(@alignCast(context));
    drainWake(self.wake_fd);
}

fn turn(self: *EventLoop, wait: bool) !void {
    var userspace_work = false;
    var prepared_wayland = false;
    if (self.wayland) |*state| {
        const prepared = try state.source.prepare(state.source.ctx);
        prepared_wayland = true;
        userspace_work = prepared.dispatched_pending;
        state.desired_mask = prepared.events;
        if (state.operation != null and state.armed_mask != state.desired_mask) self.requestWaylandCancel(state);
        try self.armWayland();
    }
    if (self.pre_poll) |source| userspace_work = (try source.prepare(source.ctx)) or userspace_work;
    self.retryCancels();
    try self.drive(wait and !userspace_work);
    if (prepared_wayland) if (self.wayland) |*state| {
        const readiness = state.readiness;
        state.readiness = 0;
        if (!try state.source.finish(state.source.ctx, readiness)) self.running = false;
    };
    try self.dispatchPhases();
}
fn drive(self: *EventLoop, wait: bool) !void {
    if (wait) try self.io.runOnce() else try self.io.pollOnce();
    self.reapRetired();
}
fn dispatchPhases(self: *EventLoop) !void {
    std.debug.assert(!self.dispatching);
    self.dispatching = true;
    defer {
        self.dispatching = false;
        self.reapRetired();
    }
    if (self.after_platform_hook) |hook| try hook(self.after_platform_context.?, self);
    var index: usize = 0;
    while (index < self.pending_ready.items.len) : (index += 1) {
        const ready = self.pending_ready.items[index];
        const reg = self.lookup(ready.handle) orelse continue;
        try reg.source.callback(reg.source.ctx, self, ready.events);
        if (self.lookup(ready.handle)) |current| if (current.operation == null) try self.arm(current);
    }
    self.pending_ready.clearRetainingCapacity();
    if (self.end_turn_hook) |hook| try hook(self.end_turn_context.?, self);
}

fn timerSourceCallback(context: *anyopaque, loop: *EventLoop, _: u32) !void {
    const timer: *Timer = @ptrCast(@alignCast(context));
    if (timer.removed) return;
    const expirations = drainTimer(timer.fd) catch |err| switch (err) {
        error.TimerCanceled => blk: {
            if (timer.wall_interval_ms == 0) return err;
            try timer.armWall(timer.wall_interval_ms);
            break :blk 1;
        },
        else => return err,
    };
    if (expirations > 0 and !timer.removed) try timer.callback(timer.ctx, loop, expirations);
}
fn fileWatchSourceCallback(context: *anyopaque, loop: *EventLoop, _: u32) !void {
    const watch: *FileWatch = @ptrCast(@alignCast(context));
    if (watch.removed) return;
    var buffer: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
    while (true) {
        const result = linux.read(watch.fd, &buffer, buffer.len);
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0) return;
                try dispatchFileWatchEvents(watch, loop, buffer[0..result]);
                if (watch.removed) return;
            },
            .AGAIN => return,
            else => return error.FileWatchReadFailed,
        }
    }
}
fn dispatchFileWatchEvents(watch: *FileWatch, loop: *EventLoop, bytes: []align(@alignOf(linux.inotify_event)) u8) !void {
    var offset: usize = 0;
    while (offset + @sizeOf(linux.inotify_event) <= bytes.len) {
        const event: *const linux.inotify_event = @ptrCast(@alignCast(bytes.ptr + offset));
        const name = if (event.getName()) |value| value[0..value.len] else null;
        try watch.callback(watch.ctx, loop, watch.path[0..watch.path.len], event.mask, name);
        if (watch.removed) return;
        offset += @sizeOf(linux.inotify_event) + event.len;
    }
}
fn drainTimer(fd: i32) !u64 {
    var value: u64 = 0;
    const bytes = std.mem.asBytes(&value);
    const result = linux.read(fd, bytes.ptr, bytes.len);
    return switch (linux.errno(result)) {
        .SUCCESS => if (result == bytes.len) value else error.ShortTimerRead,
        .AGAIN => 0,
        .CANCELED => error.TimerCanceled,
        else => error.TimerReadFailed,
    };
}
fn drainWake(fd: i32) void {
    var value: u64 = 0;
    const bytes = std.mem.asBytes(&value);
    while (true) {
        const result = linux.read(fd, bytes.ptr, bytes.len);
        switch (linux.errno(result)) {
            .SUCCESS => {},
            .AGAIN => return,
            else => return,
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
fn nextAlignedExpiration(now: linux.timespec, interval_ms: u64) !linux.timespec {
    if (interval_ms == 0 or now.sec < 0 or now.nsec < 0) return error.InvalidTimerInterval;
    const interval_ns = @as(u128, interval_ms) * std.time.ns_per_ms;
    const now_ns = @as(u128, @intCast(now.sec)) * std.time.ns_per_s + @as(u128, @intCast(now.nsec));
    const next_ns = (now_ns / interval_ns + 1) * interval_ns;
    const next_sec = next_ns / std.time.ns_per_s;
    if (next_sec > std.math.maxInt(isize)) return error.InvalidTimerInterval;
    return .{
        .sec = @intCast(next_sec),
        .nsec = @intCast(next_ns % std.time.ns_per_s),
    };
}

test "completion-native timer fires and can remove itself" {
    const Context = struct {
        timer: ?*Timer = null,
        fired: bool = false,

        fn callback(context: *anyopaque, loop: *EventLoop, _: u64) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.fired = true;
            loop.removeTimer(self.timer.?);
            self.timer = null;
            loop.quit();
        }
    };

    var loop = try EventLoop.init(std.testing.allocator);
    defer loop.deinit();
    var context: Context = .{};
    context.timer = try loop.addTimer(&context, Context.callback);
    try context.timer.?.arm(1, 0);
    try loop.run();
    try std.testing.expect(context.fired);
}

test "wall timer expiration aligns to the next epoch interval" {
    try std.testing.expectEqual(linux.timespec{ .sec = 120, .nsec = 0 }, try nextAlignedExpiration(.{ .sec = 61, .nsec = 500_000_000 }, 60_000));
    try std.testing.expectEqual(linux.timespec{ .sec = 61, .nsec = 0 }, try nextAlignedExpiration(.{ .sec = 60, .nsec = 0 }, 1_000));
    try std.testing.expectEqual(linux.timespec{ .sec = 60, .nsec = 500_000_000 }, try nextAlignedExpiration(.{ .sec = 60, .nsec = 499_000_000 }, 500));
}

test "repeating timer fires and can quit the loop" {
    const Context = struct {
        fired: u64 = 0,
        fn callback(context: *anyopaque, loop: *EventLoop, expirations: u64) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.fired += expirations;
            loop.quit();
        }
    };
    var loop = try EventLoop.init(std.testing.allocator);
    defer loop.deinit();
    var context: Context = .{};
    try loop.addRepeatingTimer(1, &context, Context.callback);
    try loop.run();
    try std.testing.expect(context.fired > 0);
}

test "quit before run is consumed without poisoning a later run" {
    const Context = struct {
        fired: bool = false,
        fn callback(context: *anyopaque, loop: *EventLoop, _: u64) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.fired = true;
            loop.quit();
        }
    };
    var loop = try EventLoop.init(std.testing.allocator);
    defer loop.deinit();
    loop.quit();
    try loop.run();
    var context: Context = .{};
    const timer = try loop.addTimer(&context, Context.callback);
    try timer.arm(1, 0);
    try loop.run();
    try std.testing.expect(context.fired);
}

test "file watch fires and can quit the loop" {
    const Context = struct {
        fired: bool = false,
        fn callback(context: *anyopaque, loop: *EventLoop, _: []const u8, mask: u32, _: ?[]const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (mask & (linux.IN.MODIFY | linux.IN.CLOSE_WRITE) != 0) {
                self.fired = true;
                loop.quit();
            }
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "watched.lua", .data = "return 1\n" });
    const path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "watched.lua" });
    defer std.testing.allocator.free(path);
    var loop = try EventLoop.init(std.testing.allocator);
    defer loop.deinit();
    var context: Context = .{};
    _ = try loop.addFileWatch(path, &context, Context.callback);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "watched.lua", .data = "return 2\n" });
    try loop.run();
    try std.testing.expect(context.fired);
}

test "directory watch reports child create and delete" {
    const Context = struct {
        created: bool = false,
        deleted: bool = false,
        fn callback(context: *anyopaque, loop: *EventLoop, _: []const u8, mask: u32, name: ?[]const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (name == null) return;
            if (mask & linux.IN.CREATE != 0) self.created = true;
            if (mask & linux.IN.DELETE != 0) self.deleted = true;
            if (self.created and self.deleted) loop.quit();
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(path);
    var loop = try EventLoop.init(std.testing.allocator);
    defer loop.deinit();
    var context: Context = .{};
    _ = try loop.addFileWatch(path, &context, Context.callback);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "child.txt", .data = "x\n" });
    try tmp.dir.deleteFile(std.testing.io, "child.txt");
    try loop.run();
    try std.testing.expect(context.created);
    try std.testing.expect(context.deleted);
}

test "source removed during dispatch does not fire stale sibling" {
    const Context = struct {
        fired: usize = 0,
        self_handle: SourceHandle,
        other_handle: SourceHandle,
        fn callback(context: *anyopaque, loop: *EventLoop, _: u32) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.fired += 1;
            loop.removeSource(self.self_handle);
            loop.removeSource(self.other_handle);
            loop.quit();
        }
    };
    var loop = try EventLoop.init(std.testing.allocator);
    defer loop.deinit();
    var a: [2]i32 = undefined;
    try linuxVoid(linux.pipe2(&a, .{ .NONBLOCK = true, .CLOEXEC = true }));
    defer for (a) |fd| {
        _ = linux.close(fd);
    };
    var b: [2]i32 = undefined;
    try linuxVoid(linux.pipe2(&b, .{ .NONBLOCK = true, .CLOEXEC = true }));
    defer for (b) |fd| {
        _ = linux.close(fd);
    };
    var context_a: Context = undefined;
    var context_b: Context = undefined;
    const handle_a = try loop.addFd(.{ .fd = a[0], .events = linux.POLL.IN, .ctx = &context_a, .callback = Context.callback });
    const handle_b = try loop.addFd(.{ .fd = b[0], .events = linux.POLL.IN, .ctx = &context_b, .callback = Context.callback });
    context_a = .{ .self_handle = handle_a, .other_handle = handle_b };
    context_b = .{ .self_handle = handle_b, .other_handle = handle_a };
    _ = linux.write(a[1], "x", 1);
    _ = linux.write(b[1], "x", 1);
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
    var context: u8 = 0;
    const stale = try loop.addFd(.{ .fd = fds[0], .events = linux.POLL.IN, .ctx = &context, .callback = Noop.callback });
    loop.removeSource(stale);
    const fresh = try loop.addFd(.{ .fd = fds[0], .events = linux.POLL.IN, .ctx = &context, .callback = Noop.callback });
    try std.testing.expectEqual(stale.index, fresh.index);
    try std.testing.expectEqual(stale.generation +% 1, fresh.generation);
    try std.testing.expect(loop.lookup(stale) == null);
    try std.testing.expect(loop.lookup(fresh) != null);
    loop.removeSource(fresh);
    while (loop.retired != null) try loop.drive(true);
}

test "file watch can remove itself from its own callback" {
    const Context = struct {
        watch: ?*FileWatch = null,
        fired: bool = false,
        fn callback(context: *anyopaque, loop: *EventLoop, _: []const u8, mask: u32, _: ?[]const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (mask & (linux.IN.MODIFY | linux.IN.CLOSE_WRITE) != 0 and !self.fired) {
                self.fired = true;
                loop.removeFileWatch(self.watch.?);
                self.watch = null;
                loop.quit();
            }
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "watched.lua", .data = "return 1\n" });
    const path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "watched.lua" });
    defer std.testing.allocator.free(path);
    var loop = try EventLoop.init(std.testing.allocator);
    defer loop.deinit();
    var context: Context = .{};
    context.watch = try loop.addFileWatch(path, &context, Context.callback);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "watched.lua", .data = "return 2\n" });
    try loop.run();
    try std.testing.expect(context.fired);
}

test "phase hooks bracket ordinary source callbacks" {
    const Context = struct {
        order: std.ArrayList(u8) = .empty,
        fn after(context: *anyopaque, _: *EventLoop) !void {
            try (@as(*@This(), @ptrCast(@alignCast(context)))).order.append(std.testing.allocator, 'a');
        }
        fn end(context: *anyopaque, _: *EventLoop) !void {
            try (@as(*@This(), @ptrCast(@alignCast(context)))).order.append(std.testing.allocator, 'e');
        }
        fn timer(context: *anyopaque, loop: *EventLoop, _: u64) !void {
            try (@as(*@This(), @ptrCast(@alignCast(context)))).order.append(std.testing.allocator, 's');
            loop.quit();
        }
    };
    var loop = try EventLoop.init(std.testing.allocator);
    defer loop.deinit();
    var context: Context = .{};
    defer context.order.deinit(std.testing.allocator);
    loop.setAfterPlatformHook(&context, Context.after);
    loop.setEndTurnHook(&context, Context.end);
    const timer = try loop.addTimer(&context, Context.timer);
    try timer.arm(1, 0);
    try loop.run();
    try std.testing.expectEqualStrings("ase", context.order.items);
}

test "Wayland dispatched pending runs prepare finish and hooks without blocking" {
    const Context = struct {
        order: [4]u8 = undefined,
        len: usize = 0,
        fn append(self: *@This(), value: u8) void {
            self.order[self.len] = value;
            self.len += 1;
        }
        fn prepare(context: *anyopaque) !WaylandPrepare {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.append('p');
            return .{ .events = linux.POLL.IN, .dispatched_pending = true };
        }
        fn finish(context: *anyopaque, events: u32) !bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expectEqual(@as(u32, 0), events);
            self.append('f');
            return true;
        }
        fn after(context: *anyopaque, _: *EventLoop) !void {
            (@as(*@This(), @ptrCast(@alignCast(context)))).append('a');
        }
        fn end(context: *anyopaque, loop: *EventLoop) !void {
            (@as(*@This(), @ptrCast(@alignCast(context)))).append('e');
            loop.quit();
        }
    };
    var loop = try EventLoop.init(std.testing.allocator);
    defer loop.deinit();
    var fds: [2]i32 = undefined;
    try linuxVoid(linux.pipe2(&fds, .{ .NONBLOCK = true, .CLOEXEC = true }));
    defer for (fds) |fd| {
        _ = linux.close(fd);
    };
    var context: Context = .{};
    try loop.setWayland(.{ .fd = fds[0], .ctx = &context, .prepare = Context.prepare, .finish = Context.finish });
    loop.setAfterPlatformHook(&context, Context.after);
    loop.setEndTurnHook(&context, Context.end);
    try loop.run();
    try std.testing.expectEqualStrings("pfae", context.order[0..context.len]);
    loop.clearWayland();
    while (loop.wayland != null) try loop.drive(true);
}

test "modifySource cancels active poll and rearms the new mask" {
    const Context = struct {
        count: usize = 0,
        events: u32 = 0,
        fn callback(context: *anyopaque, loop: *EventLoop, events: u32) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
            self.events |= events;
            loop.quit();
        }
    };
    var loop = try EventLoop.init(std.testing.allocator);
    defer loop.deinit();
    var fds: [2]i32 = undefined;
    try linuxVoid(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0, &fds));
    defer for (fds) |fd| {
        _ = linux.close(fd);
    };
    var context: Context = .{};
    const handle = try loop.addFd(.{ .fd = fds[0], .events = linux.POLL.IN, .ctx = &context, .callback = Context.callback });
    _ = try loop.io.submit();
    loop.modifySource(handle, linux.POLL.OUT);
    try loop.run();
    try std.testing.expectEqual(@as(usize, 1), context.count);
    try std.testing.expect(context.events & linux.POLL.OUT != 0);
    loop.removeSource(handle);
    while (loop.retired != null) try loop.drive(true);
}

test "source context destruction waits for poll cancellation completion" {
    const Context = struct {
        destroyed: *bool,
        fn callback(_: *anyopaque, _: *EventLoop, _: u32) !void {}
        fn destroy(_: std.mem.Allocator, context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.destroyed.* = true;
        }
    };
    var loop = try EventLoop.init(std.testing.allocator);
    defer loop.deinit();
    var fds: [2]i32 = undefined;
    try linuxVoid(linux.pipe2(&fds, .{ .NONBLOCK = true, .CLOEXEC = true }));
    defer for (fds) |fd| {
        _ = linux.close(fd);
    };
    var destroyed = false;
    var context: Context = .{ .destroyed = &destroyed };
    const handle = try loop.addFd(.{ .fd = fds[0], .events = linux.POLL.IN, .ctx = &context, .callback = Context.callback, .destroy_ctx = Context.destroy });
    _ = try loop.io.submit();
    loop.removeSource(handle);
    try std.testing.expect(!destroyed);
    try loop.drive(true);
    try std.testing.expect(destroyed);
}
