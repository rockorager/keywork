//! libdbus integration with Keywork's aggregate epoll loop.
//!
//! This module owns transport readiness only. Toolkit-specific bus names,
//! messages, and policy belong in services such as desktop_settings.zig.

const Self = @This();

const std = @import("std");
const c = @import("dbus_c");
const event_loop = @import("event_loop.zig");

const linux = std.os.linux;

allocator: std.mem.Allocator,
loop: *event_loop.EventLoop,
connection: *c.DBusConnection,
needs_dispatch: bool = false,
pending_error: ?anyerror = null,
watch_functions_installed: bool = false,
timeout_functions_installed: bool = false,

const WatchState = struct {
    owner: *Self,
    watch: *c.DBusWatch,
    fd: i32,
    source: event_loop.EventLoop.SourceHandle,
    in_callback: bool = false,
    pending_remove: bool = false,
};

const TimeoutState = struct {
    owner: *Self,
    timeout: *c.DBusTimeout,
    timer: *event_loop.EventLoop.Timer,
    in_callback: bool = false,
    pending_remove: bool = false,
};

pub fn create(allocator: std.mem.Allocator, loop: *event_loop.EventLoop) !*Self {
    const connection = c.dbus_bus_get_private(c.DBUS_BUS_SESSION, null) orelse return error.DBusUnavailable;
    errdefer {
        c.dbus_connection_close(connection);
        c.dbus_connection_unref(connection);
    }
    // A library must never allow a session-bus restart to terminate its host.
    c.dbus_connection_set_exit_on_disconnect(connection, 0);

    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{ .allocator = allocator, .loop = loop, .connection = connection };

    if (c.dbus_connection_set_watch_functions(connection, addWatch, removeWatch, toggleWatch, self, null) == 0) {
        return error.OutOfMemory;
    }
    self.watch_functions_installed = true;
    errdefer {
        _ = c.dbus_connection_set_watch_functions(connection, null, null, null, null, null);
        self.watch_functions_installed = false;
    }

    if (c.dbus_connection_set_timeout_functions(connection, addTimeout, removeTimeout, toggleTimeout, self, null) == 0) {
        return error.OutOfMemory;
    }
    self.timeout_functions_installed = true;
    errdefer {
        _ = c.dbus_connection_set_timeout_functions(connection, null, null, null, null, null);
        self.timeout_functions_installed = false;
    }

    c.dbus_connection_set_dispatch_status_function(connection, dispatchStatusChanged, self, null);
    c.dbus_connection_set_wakeup_main_function(connection, wakeMain, self, null);
    self.needs_dispatch = c.dbus_connection_get_dispatch_status(connection) == c.DBUS_DISPATCH_DATA_REMAINS;
    if (self.needs_dispatch) self.requestDispatch();
    return self;
}

pub fn destroy(self: *Self) void {
    c.dbus_connection_set_dispatch_status_function(self.connection, null, null, null);
    c.dbus_connection_set_wakeup_main_function(self.connection, null, null, null);
    if (self.timeout_functions_installed) {
        _ = c.dbus_connection_set_timeout_functions(self.connection, null, null, null, null, null);
        self.timeout_functions_installed = false;
    }
    if (self.watch_functions_installed) {
        _ = c.dbus_connection_set_watch_functions(self.connection, null, null, null, null, null);
        self.watch_functions_installed = false;
    }
    c.dbus_connection_close(self.connection);
    c.dbus_connection_unref(self.connection);
    const allocator = self.allocator;
    self.* = undefined;
    allocator.destroy(self);
}

pub fn raw(self: *Self) *c.DBusConnection {
    return self.connection;
}

/// Dispatches complete messages already assembled by libdbus. It performs no
/// blocking read and must be called by Context after EventLoop dispatch.
pub fn dispatchPending(self: *Self) void {
    while (self.needs_dispatch or c.dbus_connection_get_dispatch_status(self.connection) == c.DBUS_DISPATCH_DATA_REMAINS) {
        self.needs_dispatch = false;
        switch (c.dbus_connection_dispatch(self.connection)) {
            c.DBUS_DISPATCH_DATA_REMAINS => self.needs_dispatch = true,
            c.DBUS_DISPATCH_COMPLETE => {},
            c.DBUS_DISPATCH_NEED_MEMORY => {
                self.needs_dispatch = true;
                self.recordError(error.OutOfMemory);
                break;
            },
            else => break,
        }
    }
}

pub fn takeError(self: *Self) ?anyerror {
    const result = self.pending_error;
    self.pending_error = null;
    return result;
}

fn recordError(self: *Self, err: anyerror) void {
    if (self.pending_error == null) self.pending_error = err;
}

fn requestDispatch(self: *Self) void {
    self.needs_dispatch = true;
    self.loop.wake() catch |err| self.recordError(err);
}

fn addWatch(watch_optional: ?*c.DBusWatch, data: ?*anyopaque) callconv(.c) c.dbus_bool_t {
    const self: *Self = @ptrCast(@alignCast(data orelse return 0));
    const watch = watch_optional orelse return 0;
    addWatchInner(self, watch) catch return 0;
    return 1;
}

fn addWatchInner(self: *Self, watch: *c.DBusWatch) !void {
    const state = try self.allocator.create(WatchState);
    errdefer self.allocator.destroy(state);
    const fd = try duplicateFd(c.dbus_watch_get_unix_fd(watch));
    errdefer _ = linux.close(fd);

    state.* = .{
        .owner = self,
        .watch = watch,
        .fd = fd,
        .source = undefined,
    };
    state.source = try self.loop.addFdSource(.{
        .fd = fd,
        .events = watchEpollEvents(watch),
        .ctx = state,
        .callback = watchReady,
    }, c.dbus_watch_get_enabled(watch) != 0);
    c.dbus_watch_set_data(watch, state, null);
}

fn removeWatch(watch_optional: ?*c.DBusWatch, _: ?*anyopaque) callconv(.c) void {
    const watch = watch_optional orelse return;
    const state: *WatchState = @ptrCast(@alignCast(c.dbus_watch_get_data(watch) orelse return));
    c.dbus_watch_set_data(watch, null, null);
    state.owner.loop.removeFdSource(state.source);
    if (state.in_callback) {
        state.pending_remove = true;
        return;
    }
    destroyWatchState(state);
}

fn toggleWatch(watch_optional: ?*c.DBusWatch, _: ?*anyopaque) callconv(.c) void {
    const watch = watch_optional orelse return;
    const state: *WatchState = @ptrCast(@alignCast(c.dbus_watch_get_data(watch) orelse return));
    state.owner.loop.updateFdSource(
        &state.source,
        watchEpollEvents(watch),
        c.dbus_watch_get_enabled(watch) != 0,
    ) catch |err| state.owner.recordError(err);
}

fn watchReady(context: *anyopaque, _: *event_loop.EventLoop, events: u32) !void {
    const state: *WatchState = @ptrCast(@alignCast(context));
    const owner = state.owner;
    state.in_callback = true;
    defer {
        state.in_callback = false;
        if (state.pending_remove) destroyWatchState(state);
    }
    if (c.dbus_watch_handle(state.watch, dbusWatchEvents(events)) == 0) owner.recordError(error.OutOfMemory);
    owner.requestDispatch();
}

fn destroyWatchState(state: *WatchState) void {
    const allocator = state.owner.allocator;
    _ = linux.close(state.fd);
    allocator.destroy(state);
}

fn watchEpollEvents(watch: *c.DBusWatch) u32 {
    const flags = c.dbus_watch_get_flags(watch);
    var events: u32 = 0;
    if (flags & c.DBUS_WATCH_READABLE != 0) events |= linux.EPOLL.IN;
    if (flags & c.DBUS_WATCH_WRITABLE != 0) events |= linux.EPOLL.OUT;
    return events;
}

fn dbusWatchEvents(events: u32) c_uint {
    var flags: c_uint = 0;
    if (events & linux.EPOLL.IN != 0) flags |= c.DBUS_WATCH_READABLE;
    if (events & linux.EPOLL.OUT != 0) flags |= c.DBUS_WATCH_WRITABLE;
    if (events & linux.EPOLL.ERR != 0) flags |= c.DBUS_WATCH_ERROR;
    if (events & linux.EPOLL.HUP != 0) flags |= c.DBUS_WATCH_HANGUP;
    return flags;
}

fn addTimeout(timeout_optional: ?*c.DBusTimeout, data: ?*anyopaque) callconv(.c) c.dbus_bool_t {
    const self: *Self = @ptrCast(@alignCast(data orelse return 0));
    const timeout = timeout_optional orelse return 0;
    addTimeoutInner(self, timeout) catch return 0;
    return 1;
}

fn addTimeoutInner(self: *Self, timeout: *c.DBusTimeout) !void {
    const state = try self.allocator.create(TimeoutState);
    errdefer self.allocator.destroy(state);
    state.* = .{ .owner = self, .timeout = timeout, .timer = undefined };
    state.timer = try self.loop.addTimer(state, timeoutReady);
    configureTimeout(state);
    c.dbus_timeout_set_data(timeout, state, null);
}

fn removeTimeout(timeout_optional: ?*c.DBusTimeout, _: ?*anyopaque) callconv(.c) void {
    const timeout = timeout_optional orelse return;
    const state: *TimeoutState = @ptrCast(@alignCast(c.dbus_timeout_get_data(timeout) orelse return));
    c.dbus_timeout_set_data(timeout, null, null);
    state.owner.loop.removeTimer(state.timer);
    if (state.in_callback) {
        state.pending_remove = true;
        return;
    }
    state.owner.allocator.destroy(state);
}

fn toggleTimeout(timeout_optional: ?*c.DBusTimeout, _: ?*anyopaque) callconv(.c) void {
    const timeout = timeout_optional orelse return;
    const state: *TimeoutState = @ptrCast(@alignCast(c.dbus_timeout_get_data(timeout) orelse return));
    configureTimeout(state);
}

fn configureTimeout(state: *TimeoutState) void {
    if (c.dbus_timeout_get_enabled(state.timeout) == 0) {
        state.timer.disarm();
        return;
    }
    const raw_interval = c.dbus_timeout_get_interval(state.timeout);
    const interval: u64 = @intCast(@max(raw_interval, 1));
    state.timer.arm(interval, interval) catch |err| state.owner.recordError(err);
}

fn timeoutReady(context: *anyopaque, _: *event_loop.EventLoop, _: u64) !void {
    const state: *TimeoutState = @ptrCast(@alignCast(context));
    const owner = state.owner;
    state.in_callback = true;
    defer {
        state.in_callback = false;
        if (state.pending_remove) owner.allocator.destroy(state);
    }
    if (c.dbus_timeout_handle(state.timeout) == 0) owner.recordError(error.OutOfMemory);
    owner.requestDispatch();
}

fn dispatchStatusChanged(_: ?*c.DBusConnection, status: c.DBusDispatchStatus, data: ?*anyopaque) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(data orelse return));
    if (status == c.DBUS_DISPATCH_DATA_REMAINS) self.requestDispatch();
}

fn wakeMain(data: ?*anyopaque) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(data orelse return));
    self.loop.wake() catch |err| self.recordError(err);
}

fn duplicateFd(fd: i32) !i32 {
    if (fd < 0) return error.InvalidDbusWatch;
    const result = linux.fcntl(fd, linux.F.DUPFD_CLOEXEC, 0);
    return switch (linux.errno(result)) {
        .SUCCESS => @intCast(result),
        else => error.DuplicateFdFailed,
    };
}

test "session bus adapter releases watches and timeouts" {
    var loop = try event_loop.EventLoop.init(std.testing.allocator);
    defer loop.deinit();
    const adapter = create(std.testing.allocator, &loop) catch |err| switch (err) {
        error.DBusUnavailable => return error.SkipZigTest,
        else => return err,
    };
    adapter.destroy();
}
