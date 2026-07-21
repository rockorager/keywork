//! Shared libcurl multi-handle integration for client networking modules.
//!
//! The runtime owns connection establishment and ordinary protocol transfers,
//! while the Linux event loop owns readiness dispatch. Transfer users provide
//! only an easy handle and a completion callback, allowing raw streams, HTTP,
//! WebSockets, and other client protocols to share DNS, TLS, proxy, timer, and
//! socket plumbing without exposing libcurl to Lua.

const std = @import("std");
const event_loop = @import("../linux/event_loop.zig");
const curl_c = @import("curl_c");

const linux = std.os.linux;
const log = std.log.scoped(.keywork_curl);

pub const Host = struct {
    ptr: *anyopaque,
    event_loop_fn: *const fn (*anyopaque) ?*event_loop.EventLoop,

    fn eventLoop(self: Host) ?*event_loop.EventLoop {
        return self.event_loop_fn(self.ptr);
    }
};

/// One operation attached to the shared multi handle. Owners embed this in
/// their resource and remove it before cleaning up the easy handle.
pub const Transfer = struct {
    easy: *curl_c.CURL,
    complete_fn: *const fn (*Transfer, curl_c.CURLcode) void,
    added: bool = false,
    completed: bool = false,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    host: Host,
    multi: *curl_c.CURLM,
    transfers: std.ArrayList(*Transfer) = .empty,
    sources: std.ArrayList(*Source) = .empty,
    timer: ?*event_loop.EventLoop.Timer = null,
    timeout_ms: ?u64 = null,
    registered: bool = false,

    const Source = struct {
        runtime: *Runtime,
        fd: curl_c.curl_socket_t,
        poll: c_int = curl_c.CURL_POLL_NONE,
        handle: ?event_loop.EventLoop.SourceHandle = null,
    };

    pub fn create(allocator: std.mem.Allocator, host: Host) !*Runtime {
        try curlCode(curl_c.curl_global_init(curl_c.CURL_GLOBAL_DEFAULT));
        errdefer curl_c.curl_global_cleanup();

        const multi = curl_c.curl_multi_init() orelse return error.CurlInitFailed;
        errdefer _ = curl_c.curl_multi_cleanup(multi);

        const runtime = try allocator.create(Runtime);
        errdefer allocator.destroy(runtime);
        runtime.* = .{
            .allocator = allocator,
            .host = host,
            .multi = multi,
        };
        errdefer runtime.deinitOptions();

        try multiCode(curl_c.curl_multi_setopt(
            multi,
            @as(curl_c.CURLMoption, @intCast(curl_c.CURLMOPT_SOCKETFUNCTION)),
            @as(curl_c.curl_socket_callback, curlSocketCallback),
        ));
        try multiCode(curl_c.curl_multi_setopt(
            multi,
            @as(curl_c.CURLMoption, @intCast(curl_c.CURLMOPT_SOCKETDATA)),
            runtime,
        ));
        try multiCode(curl_c.curl_multi_setopt(
            multi,
            @as(curl_c.CURLMoption, @intCast(curl_c.CURLMOPT_TIMERFUNCTION)),
            @as(curl_c.curl_multi_timer_callback, curlTimerCallback),
        ));
        try multiCode(curl_c.curl_multi_setopt(
            multi,
            @as(curl_c.CURLMoption, @intCast(curl_c.CURLMOPT_TIMERDATA)),
            runtime,
        ));
        return runtime;
    }

    pub fn destroy(self: *Runtime) void {
        std.debug.assert(self.transfers.items.len == 0);
        self.unregister();
        _ = curl_c.curl_multi_cleanup(self.multi);
        for (self.sources.items) |source| self.allocator.destroy(source);
        self.sources.deinit(self.allocator);
        self.transfers.deinit(self.allocator);
        curl_c.curl_global_cleanup();
        self.allocator.destroy(self);
    }

    /// Completes option-installation cleanup when create fails after the
    /// runtime object exists but before it can be returned.
    fn deinitOptions(self: *Runtime) void {
        self.sources.deinit(self.allocator);
        self.transfers.deinit(self.allocator);
    }

    pub fn add(self: *Runtime, transfer: *Transfer) !void {
        std.debug.assert(!transfer.added);
        try self.transfers.append(self.allocator, transfer);
        errdefer _ = self.transfers.pop();
        if (self.registered) try self.addToMulti(transfer);
    }

    pub fn remove(self: *Runtime, transfer: *Transfer) void {
        if (transfer.added) {
            const result = curl_c.curl_multi_remove_handle(self.multi, transfer.easy);
            if (result != curl_c.CURLM_OK) {
                log.warn("remove easy handle failed: {s}", .{std.mem.span(curl_c.curl_multi_strerror(result))});
            }
            transfer.added = false;
        }
        for (self.transfers.items, 0..) |item, index| {
            if (item == transfer) {
                _ = self.transfers.swapRemove(index);
                return;
            }
        }
    }

    pub fn register(self: *Runtime) !void {
        if (self.registered) return;
        const loop = self.host.eventLoop() orelse return;
        self.registered = true;
        errdefer self.unregister();

        self.timer = try loop.addTimer(self, timerFired);
        for (self.sources.items) |source| try self.registerSource(source);
        for (self.transfers.items) |transfer| {
            if (!transfer.added) try self.addToMulti(transfer);
        }

        // A previous event loop may have been detached while connection work
        // remained pending. Drive curl on the next turn so it refreshes both
        // its timer and socket interests without resuming Lua inside bind().
        for (self.transfers.items) |transfer| {
            if (!transfer.completed) {
                try self.armTimer(1);
                break;
            }
        }
    }

    pub fn unregister(self: *Runtime) void {
        if (!self.registered) return;
        const loop = self.host.eventLoop();
        if (loop) |value| {
            for (self.sources.items) |source| {
                if (source.handle) |handle| value.removeSource(handle);
                source.handle = null;
            }
            if (self.timer) |timer| value.removeTimer(timer);
        } else {
            for (self.sources.items) |source| source.handle = null;
        }
        self.timer = null;
        self.registered = false;
    }

    /// Stops curl from watching the active socket before a completed
    /// connect-only transfer starts watching it as an application stream.
    pub fn releaseSource(self: *Runtime, fd: curl_c.curl_socket_t) void {
        const source = self.findSource(fd) orelse return;
        self.unregisterSource(source);
        source.poll = curl_c.CURL_POLL_NONE;
    }

    fn addToMulti(self: *Runtime, transfer: *Transfer) !void {
        try multiCode(curl_c.curl_multi_add_handle(self.multi, transfer.easy));
        transfer.added = true;
    }

    fn socketAction(self: *Runtime, fd: curl_c.curl_socket_t, flags: c_int) !void {
        var running: c_int = 0;
        try multiCode(curl_c.curl_multi_socket_action(self.multi, fd, flags, &running));
        self.drainMessages();
    }

    fn drainMessages(self: *Runtime) void {
        while (true) {
            var remaining: c_int = 0;
            const message = curl_c.curl_multi_info_read(self.multi, &remaining);
            if (message == null) return;
            if (message.*.msg != curl_c.CURLMSG_DONE) continue;
            const easy = message.*.easy_handle orelse continue;
            const transfer = self.findTransfer(easy) orelse continue;
            if (transfer.completed) continue;
            transfer.completed = true;
            transfer.complete_fn(transfer, message.*.data.result);
        }
    }

    fn findTransfer(self: *Runtime, easy: *curl_c.CURL) ?*Transfer {
        for (self.transfers.items) |transfer| {
            if (transfer.easy == easy) return transfer;
        }
        return null;
    }

    fn updateSource(self: *Runtime, fd: curl_c.curl_socket_t, poll: c_int) !void {
        const source = self.findSource(fd) orelse blk: {
            if (poll == curl_c.CURL_POLL_REMOVE or poll == curl_c.CURL_POLL_NONE) return;
            const created = try self.allocator.create(Source);
            errdefer self.allocator.destroy(created);
            created.* = .{ .runtime = self, .fd = fd };
            try self.sources.append(self.allocator, created);
            break :blk created;
        };

        source.poll = poll;
        if (poll == curl_c.CURL_POLL_REMOVE or poll == curl_c.CURL_POLL_NONE) {
            self.unregisterSource(source);
            return;
        }
        if (self.registered) try self.registerSource(source);
    }

    fn findSource(self: *Runtime, fd: curl_c.curl_socket_t) ?*Source {
        for (self.sources.items) |source| {
            if (source.fd == fd) return source;
        }
        return null;
    }

    fn registerSource(self: *Runtime, source: *Source) !void {
        if (source.poll == curl_c.CURL_POLL_NONE or source.poll == curl_c.CURL_POLL_REMOVE) return;
        const loop = self.host.eventLoop() orelse return;
        const events = pollEvents(source.poll);
        if (source.handle) |handle| {
            loop.modifySource(handle, events);
        } else {
            source.handle = try loop.addFd(.{
                .fd = source.fd,
                .events = events,
                .ctx = source,
                .callback = sourceReady,
            });
        }
    }

    fn unregisterSource(self: *Runtime, source: *Source) void {
        if (source.handle) |handle| {
            if (self.host.eventLoop()) |loop| loop.removeSource(handle);
        }
        source.handle = null;
    }

    fn setTimeout(self: *Runtime, timeout_ms: c_long) !void {
        if (timeout_ms < 0) {
            self.timeout_ms = null;
            if (self.timer) |timer| timer.disarm();
            return;
        }
        const delay: u64 = if (timeout_ms == 0) 1 else @intCast(timeout_ms);
        self.timeout_ms = delay;
        try self.armTimer(delay);
    }

    fn armTimer(self: *Runtime, delay_ms: u64) !void {
        const timer = self.timer orelse return;
        try timer.arm(@max(delay_ms, 1), 0);
    }
};

fn curlSocketCallback(_: ?*curl_c.CURL, fd: curl_c.curl_socket_t, what: c_int, userp: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    const runtime: *Runtime = @ptrCast(@alignCast(userp.?));
    runtime.updateSource(fd, what) catch |err| {
        // Returning -1 permanently poisons the entire shared multi handle.
        // Keep unrelated transfers alive; the affected operation can still
        // time out if this readiness registration could not be installed.
        log.warn("curl socket registration failed: {}", .{err});
    };
    return 0;
}

fn curlTimerCallback(_: ?*curl_c.CURLM, timeout_ms: c_long, userp: ?*anyopaque) callconv(.c) c_int {
    const runtime: *Runtime = @ptrCast(@alignCast(userp.?));
    runtime.setTimeout(timeout_ms) catch |err| {
        log.warn("curl timer update failed: {}", .{err});
    };
    return 0;
}

fn sourceReady(ctx: *anyopaque, _: *event_loop.EventLoop, events: u32) !void {
    const source: *Runtime.Source = @ptrCast(@alignCast(ctx));
    var flags: c_int = 0;
    if (events & linux.EPOLL.IN != 0) flags |= curl_c.CURL_CSELECT_IN;
    if (events & linux.EPOLL.OUT != 0) flags |= curl_c.CURL_CSELECT_OUT;
    if (events & (linux.EPOLL.ERR | linux.EPOLL.HUP) != 0) flags |= curl_c.CURL_CSELECT_ERR;
    try source.runtime.socketAction(source.fd, flags);
}

fn timerFired(ctx: *anyopaque, _: *event_loop.EventLoop, _: u64) !void {
    const runtime: *Runtime = @ptrCast(@alignCast(ctx));
    runtime.timeout_ms = null;
    try runtime.socketAction(curl_c.CURL_SOCKET_TIMEOUT, 0);
}

fn pollEvents(poll: c_int) u32 {
    var events: u32 = linux.EPOLL.ERR | linux.EPOLL.HUP;
    if (poll == curl_c.CURL_POLL_IN or poll == curl_c.CURL_POLL_INOUT) events |= linux.EPOLL.IN;
    if (poll == curl_c.CURL_POLL_OUT or poll == curl_c.CURL_POLL_INOUT) events |= linux.EPOLL.OUT;
    return events;
}

pub fn curlCode(result: curl_c.CURLcode) !void {
    if (result != curl_c.CURLE_OK) return error.CurlFailed;
}

fn multiCode(result: curl_c.CURLMcode) !void {
    if (result != curl_c.CURLM_OK) return error.CurlMultiFailed;
}
