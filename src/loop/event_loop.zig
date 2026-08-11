//! Linux event loop with an epoll readiness reactor, io_uring operations,
//! and a Wayland prepare-read integration point.

const std = @import("std");

const linux = std.os.linux;

pub const EventLoop = struct {
    allocator: std.mem.Allocator,
    epoll_fd: i32,
    wake_fd: i32,
    completion_fd: i32,
    ring: linux.IoUring,
    sources: std.ArrayList(Slot) = .empty,
    free_slots: std.ArrayList(u32) = .empty,
    pending_destroy: std.ArrayList(PendingDestroy) = .empty,
    timers: std.ArrayList(*Timer) = .empty,
    file_watches: std.ArrayList(*FileWatch) = .empty,
    operations: std.ArrayList(*Operation) = .empty,
    wayland: ?WaylandSource = null,
    pre_poll: ?PrePollSource = null,
    after_platform_hook: ?PhaseHook = null,
    after_platform_context: ?*anyopaque = null,
    end_turn_hook: ?PhaseHook = null,
    end_turn_context: ?*anyopaque = null,
    submission_pending: bool = false,
    running: bool = false,
    stop_requested: bool = false,
    dispatching: bool = false,

    const wake_token = std.math.maxInt(u64);
    const wayland_token = wake_token - 1;
    const completion_token = wayland_token - 1;
    const max_events = 16;
    const max_completions = 64;

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
        timer: *Timer,
        file_watch: *FileWatch,
        operation: *Operation,
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
    pub const PhaseHook = *const fn (ctx: *anyopaque, loop: *EventLoop) anyerror!void;
    pub const OperationCallback = *const fn (ctx: *anyopaque, loop: *EventLoop, operation: *Operation, result: i32) anyerror!void;

    /// A stable completion identity. Buffers and path arguments passed to a
    /// submission must remain valid until its callback (or destroy callback).
    pub const Operation = struct {
        ctx: *anyopaque,
        callback: OperationCallback,
        destroy_ctx: ?*const fn (allocator: std.mem.Allocator, ctx: *anyopaque) void,
        result: ?i32 = null,
        active: bool = false,
        removed: bool = false,
        cancel_queued: bool = false,
    };

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
        prepare: *const fn (ctx: *anyopaque) anyerror!WaylandPrepare,
        finish: *const fn (ctx: *anyopaque, events: u32) anyerror!bool,
    };

    pub const WaylandPrepare = struct {
        events: u32,
        dispatched_pending: bool = false,
    };

    /// A subordinate event source that may discover ready userspace work
    /// while arming itself. Returning true requests a non-blocking turn so
    /// phase hooks observe work dispatched from prepare().
    pub const PrePollSource = struct {
        ctx: *anyopaque,
        prepare: *const fn (ctx: *anyopaque) anyerror!bool,
    };

    pub const Timer = struct {
        fd: i32,
        source_handle: ?SourceHandle,
        ctx: *anyopaque,
        callback: TimerCallback,
        wall_interval_ms: u64 = 0,
        destroy_ctx: ?*const fn (allocator: std.mem.Allocator, ctx: *anyopaque) void = null,
        removed: bool = false,

        pub fn arm(self: *Timer, delay_ms: u64, interval_ms: u64) !void {
            const spec: linux.itimerspec = .{
                .it_interval = try millisecondsAllowZero(interval_ms),
                .it_value = try milliseconds(delay_ms),
            };
            try linuxVoid(linux.timerfd_settime(self.fd, .{ .ABSTIME = false }, &spec, null));
        }

        pub fn armWall(self: *Timer, interval_ms: u64) !void {
            var now: linux.timespec = undefined;
            try linuxVoid(linux.clock_gettime(.REALTIME, &now));
            const spec: linux.itimerspec = .{
                .it_interval = try milliseconds(interval_ms),
                .it_value = try nextAlignedExpiration(now, interval_ms),
            };
            try linuxVoid(linux.timerfd_settime(self.fd, .{
                .ABSTIME = true,
                .CANCEL_ON_SET = true,
            }, &spec, null));
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
        const epoll_fd = try linuxFd(linux.epoll_create1(linux.EPOLL.CLOEXEC));
        errdefer _ = linux.close(epoll_fd);

        const wake_fd = try linuxFd(linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK));
        errdefer _ = linux.close(wake_fd);

        var ring = try linux.IoUring.init(256, 0);
        errdefer ring.deinit();
        const completion_fd = try linuxFd(linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK));
        errdefer _ = linux.close(completion_fd);
        try ring.register_eventfd(completion_fd);

        var self: EventLoop = .{
            .allocator = allocator,
            .epoll_fd = epoll_fd,
            .wake_fd = wake_fd,
            .completion_fd = completion_fd,
            .ring = ring,
        };
        errdefer self.sources.deinit(allocator);

        var event: linux.epoll_event = .{
            .events = linux.EPOLL.IN,
            .data = .{ .u64 = wake_token },
        };
        try linuxVoid(linux.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, wake_fd, &event));
        event.data.u64 = completion_token;
        try linuxVoid(linux.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, completion_fd, &event));
        return self;
    }

    pub fn deinit(self: *EventLoop) void {
        self.flushPendingDestroy();
        self.quiesceOperations();
        // All original CQEs have now been reaped, so no kernel request can
        // still refer to an operation or to its caller-owned arguments.
        self.ring.deinit();
        for (self.operations.items) |operation| self.destroyOperation(operation);
        self.operations.deinit(self.allocator);
        for (self.file_watches.items) |watch| {
            if (watch.source_handle) |handle| self.removeSource(handle);
            self.destroyFileWatch(watch);
        }
        self.file_watches.deinit(self.allocator);
        for (self.timers.items) |timer| {
            if (timer.source_handle) |handle| self.removeSource(handle);
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
        _ = linux.close(self.completion_fd);
        _ = linux.close(self.wake_fd);
        _ = linux.close(self.epoll_fd);
    }

    pub fn addFd(self: *EventLoop, source: Source) !SourceHandle {
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
        return .{ .index = index, .generation = slot.generation };
    }

    /// Changes the epoll event mask of a registered source in place, so
    /// callers can toggle interests (e.g. write readiness) without churning
    /// slots and generations. Stale handles are ignored.
    pub fn modifySource(self: *EventLoop, handle: SourceHandle, events: u32) void {
        if (handle.index >= self.sources.items.len) return;
        const slot = &self.sources.items[handle.index];
        if (slot.generation != handle.generation) return;
        if (slot.source) |*source| {
            if (source.events == events) return;
            source.events = events;
            var event: linux.epoll_event = .{
                .events = events,
                .data = .{ .u64 = sourceToken(handle.index, slot.generation) },
            };
            _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_MOD, source.fd, &event);
        }
    }

    pub fn removeSource(self: *EventLoop, handle: SourceHandle) void {
        if (handle.index >= self.sources.items.len) return;
        const slot = &self.sources.items[handle.index];
        if (slot.generation != handle.generation) return;
        const source = slot.source orelse return;
        _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, source.fd, null);
        // The generation bump invalidates any events already queued for this
        // slot in the current dispatch batch.
        slot.generation +%= 1;
        slot.source = null;
        self.free_slots.append(self.allocator, handle.index) catch {};
        if (source.destroy_ctx) |destroy| self.deferDestroy(.{ .source_ctx = .{ .ctx = source.ctx, .destroy = destroy } });
    }

    fn deferDestroy(self: *EventLoop, pending: PendingDestroy) void {
        if (self.dispatching) {
            self.pending_destroy.append(self.allocator, pending) catch {
                // Never trade an allocation failure for use-after-free: the
                // current epoll batch may still hold this callback context.
                // Under OOM, leaking this removed object is the safe failure
                // mode; normal destruction resumes for subsequent objects.
            };
            return;
        }
        self.destroyPending(pending);
    }

    fn destroyPending(self: *EventLoop, pending: PendingDestroy) void {
        switch (pending) {
            .source_ctx => |entry| entry.destroy(self.allocator, entry.ctx),
            .timer => |timer| self.destroyTimer(timer),
            .file_watch => |watch| self.destroyFileWatch(watch),
            .operation => |operation| self.destroyOperation(operation),
        }
    }

    fn destroyOperation(self: *EventLoop, operation: *Operation) void {
        if (operation.destroy_ctx) |destroy| destroy(self.allocator, operation.ctx);
        self.allocator.destroy(operation);
    }

    pub fn addOperation(self: *EventLoop, ctx: *anyopaque, callback: OperationCallback, destroy_ctx: ?*const fn (std.mem.Allocator, *anyopaque) void) !*Operation {
        const operation = try self.allocator.create(Operation);
        errdefer self.allocator.destroy(operation);
        operation.* = .{ .ctx = ctx, .callback = callback, .destroy_ctx = destroy_ctx };
        try self.operations.append(self.allocator, operation);
        return operation;
    }

    pub fn removeOperation(self: *EventLoop, operation: *Operation) void {
        if (operation.removed) return;
        operation.removed = true;
        if (operation.active) {
            _ = self.ring.cancel(operationUserData(operation) | 1, operationUserData(operation), 0) catch return;
            operation.cancel_queued = true;
            self.submitPrepared() catch {};
            return;
        }
        self.untrackOperation(operation);
        self.deferDestroy(.{ .operation = operation });
    }

    fn untrackOperation(self: *EventLoop, operation: *Operation) void {
        for (self.operations.items, 0..) |item, index| if (item == operation) {
            _ = self.operations.swapRemove(index);
            return;
        };
    }

    fn prepareOperation(operation: *Operation) !u64 {
        if (operation.removed) return error.OperationRemoved;
        if (operation.active) return error.OperationActive;
        operation.result = null;
        operation.cancel_queued = false;
        operation.active = true;
        return operationUserData(operation);
    }

    fn submitPrepared(self: *EventLoop) !void {
        _ = self.ring.submit() catch {
            // The SQE remains queued and may still execute. Preserve its
            // operands and retry from the reactor instead of reporting a
            // false terminal failure to the caller.
            self.submission_pending = true;
            self.wake() catch {};
            return;
        };
        self.submission_pending = self.ring.sq_ready() > 0;
        if (self.submission_pending) self.wake() catch {};
    }

    fn quiesceOperations(self: *EventLoop) void {
        var active_count: usize = 0;
        for (self.operations.items) |operation| {
            if (!operation.active) continue;
            operation.removed = true;
            active_count += 1;
        }

        var cqes: [max_completions]linux.io_uring_cqe = undefined;
        while (active_count > 0) {
            const ready_count = self.ring.copy_cqes(&cqes, 0) catch |err| switch (err) {
                error.SignalInterrupt, error.SystemResources, error.CompletionQueueOvercommitted => continue,
                else => std.debug.panic("io_uring failed while draining operations: {}", .{err}),
            };
            recordTeardownCompletions(cqes[0..ready_count], &active_count);
            if (active_count == 0) break;

            var all_cancels_queued = true;
            for (self.operations.items) |operation| {
                if (!operation.active or operation.cancel_queued) continue;
                _ = self.ring.cancel(operationUserData(operation) | 1, operationUserData(operation), 0) catch {
                    all_cancels_queued = false;
                    break;
                };
                operation.cancel_queued = true;
            }

            const submitted = self.ring.submit() catch |err| switch (err) {
                error.SignalInterrupt, error.SystemResources, error.CompletionQueueOvercommitted => continue,
                else => std.debug.panic("io_uring failed while canceling operations: {}", .{err}),
            };
            _ = submitted;
            if (!all_cancels_queued or self.ring.sq_ready() > 0) continue;

            const count = self.ring.copy_cqes(&cqes, 1) catch |err| switch (err) {
                error.SignalInterrupt, error.SystemResources, error.CompletionQueueOvercommitted => continue,
                else => std.debug.panic("io_uring failed while awaiting operation cancellation: {}", .{err}),
            };
            recordTeardownCompletions(cqes[0..count], &active_count);
        }
    }

    fn recordTeardownCompletions(cqes: []const linux.io_uring_cqe, active_count: *usize) void {
        for (cqes) |cqe| {
            if (cqe.user_data & 1 != 0) continue;
            const operation: *Operation = @ptrFromInt(cqe.user_data);
            if (!operation.active) continue;
            operation.active = false;
            operation.result = cqe.res;
            active_count.* -= 1;
        }
    }

    pub fn submitNop(self: *EventLoop, operation: *Operation) !void {
        const data = try prepareOperation(operation);
        _ = self.ring.nop(data) catch |err| {
            operation.active = false;
            return err;
        };
        try self.submitPrepared();
    }

    pub fn submitOpenAt(self: *EventLoop, operation: *Operation, fd: linux.fd_t, path: [*:0]const u8, flags: linux.O, mode: std.posix.mode_t) !void {
        const data = try prepareOperation(operation);
        _ = self.ring.openat(data, fd, path, flags, mode) catch |err| {
            operation.active = false;
            return err;
        };
        try self.submitPrepared();
    }
    pub fn submitRead(self: *EventLoop, operation: *Operation, fd: linux.fd_t, buffer: linux.IoUring.ReadBuffer, offset: u64) !void {
        const data = try prepareOperation(operation);
        _ = self.ring.read(data, fd, buffer, offset) catch |err| {
            operation.active = false;
            return err;
        };
        try self.submitPrepared();
    }
    pub fn submitWrite(self: *EventLoop, operation: *Operation, fd: linux.fd_t, buffer: []const u8, offset: u64) !void {
        const data = try prepareOperation(operation);
        _ = self.ring.write(data, fd, buffer, offset) catch |err| {
            operation.active = false;
            return err;
        };
        try self.submitPrepared();
    }
    pub fn submitFsync(self: *EventLoop, operation: *Operation, fd: linux.fd_t, flags: u32) !void {
        const data = try prepareOperation(operation);
        _ = self.ring.fsync(data, fd, flags) catch |err| {
            operation.active = false;
            return err;
        };
        try self.submitPrepared();
    }
    pub fn submitClose(self: *EventLoop, operation: *Operation, fd: linux.fd_t) !void {
        const data = try prepareOperation(operation);
        _ = self.ring.close(data, fd) catch |err| {
            operation.active = false;
            return err;
        };
        try self.submitPrepared();
    }
    pub fn submitStatx(self: *EventLoop, operation: *Operation, fd: linux.fd_t, path: [:0]const u8, flags: u32, mask: linux.STATX, buf: *linux.Statx) !void {
        const data = try prepareOperation(operation);
        _ = self.ring.statx(data, fd, path, flags, mask, buf) catch |err| {
            operation.active = false;
            return err;
        };
        try self.submitPrepared();
    }
    pub fn submitRenameAt(self: *EventLoop, operation: *Operation, old_fd: linux.fd_t, old_path: [*:0]const u8, new_fd: linux.fd_t, new_path: [*:0]const u8, flags: u32) !void {
        const data = try prepareOperation(operation);
        _ = self.ring.renameat(data, old_fd, old_path, new_fd, new_path, flags) catch |err| {
            operation.active = false;
            return err;
        };
        try self.submitPrepared();
    }
    pub fn submitUnlinkAt(self: *EventLoop, operation: *Operation, fd: linux.fd_t, path: [*:0]const u8, flags: u32) !void {
        const data = try prepareOperation(operation);
        _ = self.ring.unlinkat(data, fd, path, flags) catch |err| {
            operation.active = false;
            return err;
        };
        try self.submitPrepared();
    }
    pub fn submitMkdirAt(self: *EventLoop, operation: *Operation, fd: linux.fd_t, path: [*:0]const u8, mode: std.posix.mode_t) !void {
        const data = try prepareOperation(operation);
        _ = self.ring.mkdirat(data, fd, path, mode) catch |err| {
            operation.active = false;
            return err;
        };
        try self.submitPrepared();
    }

    fn flushPendingDestroy(self: *EventLoop) void {
        for (self.pending_destroy.items) |pending| self.destroyPending(pending);
        self.pending_destroy.clearRetainingCapacity();
    }

    fn destroyFileWatch(self: *EventLoop, watch: *FileWatch) void {
        watch.removed = true;
        _ = linux.inotify_rm_watch(watch.fd, watch.wd);
        _ = linux.close(watch.fd);
        self.allocator.free(watch.path);
        self.allocator.destroy(watch);
    }

    fn destroyTimer(self: *EventLoop, timer: *Timer) void {
        timer.removed = true;
        _ = linux.close(timer.fd);
        if (timer.destroy_ctx) |destroy| destroy(self.allocator, timer.ctx);
        self.allocator.destroy(timer);
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

        timer.source_handle = try self.addFd(.{
            .fd = fd,
            .events = linux.EPOLL.IN,
            .ctx = timer,
            .callback = timerSourceCallback,
        });

        return timer;
    }

    pub fn removeTimer(self: *EventLoop, timer: *Timer) void {
        if (timer.removed) return;
        timer.removed = true;
        if (timer.source_handle) |handle| {
            self.removeSource(handle);
            timer.source_handle = null;
        }
        for (self.timers.items, 0..) |item, index| {
            if (item == timer) {
                _ = self.timers.swapRemove(index);
                break;
            }
        }
        self.deferDestroy(.{ .timer = timer });
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
            linux.IN.CREATE |
            linux.IN.DELETE |
            linux.IN.MOVED_FROM |
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
            .source_handle = null,
            .path = path_z,
            .ctx = ctx,
            .callback = callback,
        };

        watch.source_handle = try self.addFd(.{
            .fd = fd,
            .events = linux.EPOLL.IN,
            .ctx = watch,
            .callback = fileWatchSourceCallback,
        });
        errdefer if (watch.source_handle) |handle| self.removeSource(handle);

        try self.file_watches.append(self.allocator, watch);
        return watch;
    }

    pub fn removeFileWatch(self: *EventLoop, watch: *FileWatch) void {
        if (watch.removed) return;
        watch.removed = true;
        if (watch.source_handle) |handle| {
            self.removeSource(handle);
            watch.source_handle = null;
        }
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
        std.debug.assert(self.wayland == null);
        self.wayland = source;
        errdefer self.wayland = null;
        var event: linux.epoll_event = .{
            .events = linux.EPOLL.IN,
            .data = .{ .u64 = wayland_token },
        };
        try linuxVoid(linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, source.fd, &event));
    }

    pub fn clearWayland(self: *EventLoop) void {
        const source = self.wayland orelse return;
        _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, source.fd, null);
        self.wayland = null;
    }

    pub fn setPrePoll(self: *EventLoop, source: PrePollSource) void {
        std.debug.assert(self.pre_poll == null);
        self.pre_poll = source;
    }

    pub fn clearPrePoll(self: *EventLoop, ctx: *anyopaque) void {
        const source = self.pre_poll orelse return;
        if (source.ctx == ctx) self.pre_poll = null;
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
        const written = linux.write(self.wake_fd, bytes.ptr, bytes.len);
        switch (linux.errno(written)) {
            .SUCCESS => {},
            .AGAIN => {},
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
        defer {
            self.running = false;
            self.stop_requested = false;
        }
        var events: [max_events]linux.epoll_event = undefined;
        while (self.running) {
            if (self.wayland) |wayland| {
                const prepared = try wayland.prepare(wayland.ctx);
                var event: linux.epoll_event = .{
                    .events = prepared.events,
                    .data = .{ .u64 = wayland_token },
                };
                try linuxVoid(linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_MOD, wayland.fd, &event));

                // The Wayland prepare step may need to dispatch events that
                // were already queued in libwayland before it can prepare a
                // socket read. Finish cancels that prepared read, then this
                // turn delivers the resulting semantic events without
                // blocking for unrelated fd activity.
                if (prepared.dispatched_pending) {
                    try self.dispatchTurn(0, &.{});
                    continue;
                }
            }

            if (self.pre_poll) |source| {
                if (try source.prepare(source.ctx)) {
                    try self.dispatchTurn(0, &.{});
                    continue;
                }
            }

            const ready = try epollWait(self.epoll_fd, &events, -1);
            var wayland_events: u32 = 0;
            var source_events: [max_events]linux.epoll_event = undefined;
            var source_count: usize = 0;

            for (events[0..ready]) |event| {
                if (event.data.u64 == wake_token) {
                    drainWake(self.wake_fd);
                } else if (event.data.u64 == completion_token) {
                    drainWake(self.completion_fd);
                } else if (event.data.u64 == wayland_token) {
                    wayland_events |= event.events;
                } else {
                    source_events[source_count] = event;
                    source_count += 1;
                }
            }

            try self.dispatchTurn(wayland_events, source_events[0..source_count]);
        }
    }

    fn dispatchTurn(self: *EventLoop, wayland_events: u32, source_events: []const linux.epoll_event) !void {
        std.debug.assert(!self.dispatching);
        self.dispatching = true;
        defer {
            self.dispatching = false;
            self.flushPendingDestroy();
        }

        if (self.wayland) |wayland| {
            if (!try wayland.finish(wayland.ctx, wayland_events)) self.running = false;
        }

        if (self.after_platform_hook) |hook| try hook(self.after_platform_context.?, self);

        try self.dispatchCompletions();

        if (self.submission_pending) {
            try self.submitPrepared();
        }

        for (source_events) |event| {
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

        if (self.end_turn_hook) |hook| try hook(self.end_turn_context.?, self);
    }

    fn dispatchCompletions(self: *EventLoop) !void {
        var cqes: [max_completions]linux.io_uring_cqe = undefined;
        const count = try self.ring.copy_cqes(&cqes, 0);
        var callback_error: ?anyerror = null;
        for (cqes[0..count]) |cqe| {
            if (cqe.user_data & 1 != 0) continue;
            const operation: *Operation = @ptrFromInt(cqe.user_data);
            std.debug.assert(operation.active);
            operation.active = false;
            operation.result = cqe.res;
            if (operation.removed) {
                self.untrackOperation(operation);
                self.deferDestroy(.{ .operation = operation });
                continue;
            }
            operation.callback(operation.ctx, self, operation, cqe.res) catch |err| {
                if (callback_error == null) callback_error = err;
            };
        }
        if (self.ring.cq_ready() > 0) try self.wake();
        if (callback_error) |err| return err;
    }
};

fn operationUserData(operation: *EventLoop.Operation) u64 {
    const value: u64 = @intFromPtr(operation);
    std.debug.assert(value & 1 == 0);
    return value;
}

fn timerSourceCallback(ctx: *anyopaque, loop: *EventLoop, _: u32) !void {
    const timer: *EventLoop.Timer = @ptrCast(@alignCast(ctx));
    if (timer.removed) return;
    const expirations = drainTimer(timer.fd) catch |err| switch (err) {
        error.TimerCanceled => blk: {
            // CANCEL_ON_SET reports discontinuous realtime changes. Deliver
            // one immediate tick, then continue at the new wall boundaries.
            if (timer.wall_interval_ms == 0) return err;
            try timer.armWall(timer.wall_interval_ms);
            break :blk 1;
        },
        else => return err,
    };
    if (expirations > 0 and !timer.removed) try timer.callback(timer.ctx, loop, expirations);
}

fn fileWatchSourceCallback(ctx: *anyopaque, loop: *EventLoop, _: u32) !void {
    const watch: *EventLoop.FileWatch = @ptrCast(@alignCast(ctx));
    if (watch.removed) return;
    var buffer: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
    while (true) {
        const read = linux.read(watch.fd, &buffer, buffer.len);
        switch (linux.errno(read)) {
            .SUCCESS => {
                if (read == 0) return;
                try dispatchFileWatchEvents(watch, loop, buffer[0..read]);
                if (watch.removed) return;
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
        if (watch.removed) return;
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
        .CANCELED => return error.TimerCanceled,
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

test "wall timer expiration aligns to the next epoch interval" {
    try std.testing.expectEqual(linux.timespec{ .sec = 120, .nsec = 0 }, try nextAlignedExpiration(.{ .sec = 61, .nsec = 500_000_000 }, 60_000));
    try std.testing.expectEqual(linux.timespec{ .sec = 61, .nsec = 0 }, try nextAlignedExpiration(.{ .sec = 60, .nsec = 0 }, 1_000));
    try std.testing.expectEqual(linux.timespec{ .sec = 60, .nsec = 500_000_000 }, try nextAlignedExpiration(.{ .sec = 60, .nsec = 499_000_000 }, 500));
}

test "io_uring nop completes through epoll" {
    const Context = struct {
        completed: bool = false,
        fn callback(ctx: *anyopaque, loop: *EventLoop, _: *EventLoop.Operation, result: i32) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try std.testing.expectEqual(@as(i32, 0), result);
            self.completed = true;
            loop.quit();
        }
    };
    var loop = try EventLoop.init(std.testing.allocator);
    defer loop.deinit();
    var context: Context = .{};
    const operation = try loop.addOperation(&context, Context.callback, null);
    try loop.submitNop(operation);
    try loop.run();
    try std.testing.expect(context.completed);
}

test "deinit reaps an active operation before destroying its context" {
    const Context = struct {
        operation: ?*EventLoop.Operation = null,
        callback_called: bool = false,
        destroyed: bool = false,
        result: ?i32 = null,

        fn callback(ctx: *anyopaque, _: *EventLoop, _: *EventLoop.Operation, _: i32) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.callback_called = true;
        }

        fn destroy(_: std.mem.Allocator, ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.result = self.operation.?.result;
            if (self.result.? >= 0) _ = linux.close(self.result.?);
            self.destroyed = true;
        }
    };

    var loop = try EventLoop.init(std.testing.allocator);
    var context: Context = .{};
    const operation = try loop.addOperation(&context, Context.callback, Context.destroy);
    context.operation = operation;
    try loop.submitOpenAt(operation, linux.AT.FDCWD, "/proc/self/status", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    while (loop.ring.cq_ready() == 0) std.atomic.spinLoopHint();

    loop.deinit();
    try std.testing.expect(!context.callback_called);
    try std.testing.expect(context.destroyed);
    try std.testing.expect(context.result.? >= 0);
}

test "removing active operation suppresses callback and destroys context" {
    const Context = struct {
        callback_called: bool = false,
        destroyed: bool = false,
        fn callback(ctx: *anyopaque, _: *EventLoop, _: *EventLoop.Operation, _: i32) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.callback_called = true;
        }
        fn destroy(_: std.mem.Allocator, ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.destroyed = true;
        }
        fn timeout(ctx: *anyopaque, loop: *EventLoop, _: u64) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (!self.destroyed) return error.OperationWasNotDestroyed;
            loop.quit();
        }
    };
    var loop = try EventLoop.init(std.testing.allocator);
    defer loop.deinit();
    var context: Context = .{};
    const operation = try loop.addOperation(&context, Context.callback, Context.destroy);
    try loop.submitNop(operation);
    loop.removeOperation(operation);
    const timer = try loop.addTimer(&context, Context.timeout);
    try timer.arm(10, 0);
    try loop.run();
    try std.testing.expect(!context.callback_called);
    try std.testing.expect(context.destroyed);
}

test "operation callback can remove itself" {
    const Context = struct {
        destroyed: bool = false,
        fn callback(ctx: *anyopaque, loop: *EventLoop, operation: *EventLoop.Operation, _: i32) !void {
            loop.removeOperation(operation);
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try std.testing.expect(!self.destroyed);
            loop.quit();
        }
        fn destroy(_: std.mem.Allocator, ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.destroyed = true;
        }
    };
    var loop = try EventLoop.init(std.testing.allocator);
    defer loop.deinit();
    var context: Context = .{};
    const operation = try loop.addOperation(&context, Context.callback, Context.destroy);
    try loop.submitNop(operation);
    try loop.run();
    try std.testing.expect(context.destroyed);
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

test "quit before run is consumed without poisoning a later run" {
    const TimerTest = struct {
        fired: bool = false,

        fn callback(ctx: *anyopaque, loop: *EventLoop, _: u64) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.fired = true;
            loop.quit();
        }
    };

    var loop = try EventLoop.init(std.testing.allocator);
    defer loop.deinit();
    loop.quit();
    try loop.run();

    var context: TimerTest = .{};
    const timer = try loop.addTimer(&context, TimerTest.callback);
    try timer.arm(1, 0);
    try loop.run();
    try std.testing.expect(context.fired);
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

test "directory watch reports child create and delete" {
    const DirWatchTest = struct {
        created: bool = false,
        deleted: bool = false,

        fn callback(
            ctx: *anyopaque,
            loop: *EventLoop,
            path: []const u8,
            mask: u32,
            name: ?[]const u8,
        ) !void {
            _ = path;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (name == null) return;
            if (mask & linux.IN.CREATE != 0) self.created = true;
            if (mask & linux.IN.DELETE != 0) self.deleted = true;
            if (self.created and self.deleted) loop.quit();
        }
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const watched_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(watched_path);

    var loop = try EventLoop.init(std.testing.allocator);
    defer loop.deinit();

    var context: DirWatchTest = .{};
    _ = try loop.addFileWatch(watched_path, &context, DirWatchTest.callback);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "child.txt", .data = "x\n" });
    try tmp.dir.deleteFile(std.testing.io, "child.txt");
    try loop.run();

    try std.testing.expect(context.created);
    try std.testing.expect(context.deleted);
}

test "source removed during dispatch does not fire stale events" {
    const PipeTest = struct {
        loop: *EventLoop,
        fired: usize = 0,
        other_handle: EventLoop.SourceHandle,
        self_handle: EventLoop.SourceHandle,

        fn callback(ctx: *anyopaque, loop: *EventLoop, _: u32) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.fired += 1;
            // Remove both sources mid-batch; the sibling's queued event
            // must be dropped via the generation check.
            loop.removeSource(self.self_handle);
            loop.removeSource(self.other_handle);
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

    var context_a: PipeTest = undefined;
    var context_b: PipeTest = undefined;
    const handle_a = try loop.addFd(.{ .fd = fds_a[0], .events = linux.EPOLL.IN, .ctx = &context_a, .callback = PipeTest.callback });
    const handle_b = try loop.addFd(.{ .fd = fds_b[0], .events = linux.EPOLL.IN, .ctx = &context_b, .callback = PipeTest.callback });
    context_a = .{ .loop = &loop, .self_handle = handle_a, .other_handle = handle_b };
    context_b = .{ .loop = &loop, .self_handle = handle_b, .other_handle = handle_a };

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
    const stale_handle = try loop.addFd(.{ .fd = fds[0], .events = linux.EPOLL.IN, .ctx = &ctx, .callback = Noop.callback });
    try std.testing.expectEqual(@as(usize, 1), loop.sources.items.len);
    loop.removeSource(stale_handle);
    try std.testing.expectEqual(@as(usize, 1), loop.free_slots.items.len);

    _ = try loop.addFd(.{ .fd = fds[0], .events = linux.EPOLL.IN, .ctx = &ctx, .callback = Noop.callback });
    loop.removeSource(stale_handle);
    try std.testing.expectEqual(@as(usize, 1), loop.sources.items.len);
    try std.testing.expectEqual(@as(usize, 0), loop.free_slots.items.len);
    try std.testing.expectEqual(@as(u32, 1), loop.sources.items[0].generation);
}

test "timer can remove itself during dispatch" {
    const SelfRemove = struct {
        timer: ?*EventLoop.Timer = null,
        fired: usize = 0,

        fn callback(ctx: *anyopaque, loop: *EventLoop, expirations: u64) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.fired += @intCast(expirations);
            if (self.timer) |timer| {
                loop.removeTimer(timer);
                loop.removeTimer(timer);
                self.timer = null;
            }
            loop.quit();
        }
    };

    var loop = try EventLoop.init(std.testing.allocator);
    defer loop.deinit();

    var context: SelfRemove = .{};
    context.timer = try loop.addTimer(&context, SelfRemove.callback);
    try context.timer.?.arm(1, 0);
    try loop.run();

    try std.testing.expectEqual(@as(usize, 1), context.fired);
    try std.testing.expectEqual(@as(usize, 0), loop.timers.items.len);
    try std.testing.expectEqual(@as(usize, 0), loop.pending_destroy.items.len);
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

test "phase hooks bracket ordinary source callbacks" {
    const HookTest = struct {
        order: std.ArrayList(u8) = .empty,

        fn after(ctx: *anyopaque, _: *EventLoop) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try self.order.append(std.testing.allocator, 'a');
        }

        fn end(ctx: *anyopaque, _: *EventLoop) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try self.order.append(std.testing.allocator, 'e');
        }

        fn timer(ctx: *anyopaque, loop: *EventLoop, _: u64) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try self.order.append(std.testing.allocator, 's');
            loop.quit();
        }
    };

    var loop = try EventLoop.init(std.testing.allocator);
    defer loop.deinit();
    var context: HookTest = .{};
    defer context.order.deinit(std.testing.allocator);
    loop.setAfterPlatformHook(&context, HookTest.after);
    loop.setEndTurnHook(&context, HookTest.end);
    const timer = try loop.addTimer(&context, HookTest.timer);
    try timer.arm(1, 0);
    try loop.run();
    try std.testing.expectEqualStrings("ase", context.order.items);
}

test "Wayland events dispatched during prepare run without polling" {
    const WaylandTest = struct {
        order: [4]u8 = undefined,
        len: usize = 0,

        fn append(self: *@This(), value: u8) void {
            self.order[self.len] = value;
            self.len += 1;
        }

        fn prepare(ctx: *anyopaque) !EventLoop.WaylandPrepare {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.append('p');
            return .{ .events = linux.EPOLL.IN, .dispatched_pending = true };
        }

        fn finish(ctx: *anyopaque, events: u32) !bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try std.testing.expectEqual(@as(u32, 0), events);
            self.append('f');
            return true;
        }

        fn after(ctx: *anyopaque, _: *EventLoop) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.append('a');
        }

        fn end(ctx: *anyopaque, loop: *EventLoop) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.append('e');
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

    var context: WaylandTest = .{};
    try loop.setWayland(.{
        .fd = fds[0],
        .ctx = &context,
        .prepare = WaylandTest.prepare,
        .finish = WaylandTest.finish,
    });
    loop.setAfterPlatformHook(&context, WaylandTest.after);
    loop.setEndTurnHook(&context, WaylandTest.end);
    try loop.run();

    try std.testing.expectEqualStrings("pfae", context.order[0..context.len]);
}
