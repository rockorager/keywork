//! Lua event-loop resources for keywork.loop.

const std = @import("std");
const event_loop = @import("../linux/event_loop.zig");
const lua_handle = @import("handle.zig");
const c = @import("luajit_c");

const linux = std.os.linux;

pub const Host = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        allocator: *const fn (*anyopaque) std.mem.Allocator,
        luaState: *const fn (*anyopaque) *c.lua_State,
        eventLoop: *const fn (*anyopaque) ?*event_loop.EventLoop,
        invalidate: *const fn (*anyopaque) anyerror!void,
        addFdWatch: *const fn (*anyopaque, i32, u32, c_int) anyerror!*FdWatch,
        addFsEvent: *const fn (*anyopaque, []const u8, c_int) anyerror!*FsEvent,
        addTimer: *const fn (*anyopaque, u64, u64, c_int) anyerror!*LuaTimer,
    };

    fn allocator(self: Host) std.mem.Allocator {
        return self.vtable.allocator(self.ptr);
    }

    fn luaState(self: Host) *c.lua_State {
        return self.vtable.luaState(self.ptr);
    }

    fn eventLoop(self: Host) ?*event_loop.EventLoop {
        return self.vtable.eventLoop(self.ptr);
    }

    fn invalidate(self: Host) !void {
        try self.vtable.invalidate(self.ptr);
    }

    fn addFdWatch(self: Host, fd: i32, events: u32, ref: c_int) !*FdWatch {
        return try self.vtable.addFdWatch(self.ptr, fd, events, ref);
    }

    fn addFsEvent(self: Host, path: []const u8, ref: c_int) !*FsEvent {
        return try self.vtable.addFsEvent(self.ptr, path, ref);
    }

    fn addTimer(self: Host, delay_ms: u64, interval_ms: u64, ref: c_int) !*LuaTimer {
        return try self.vtable.addTimer(self.ptr, delay_ms, interval_ms, ref);
    }
};

pub const FdWatch = struct {
    host: Host,
    fd: i32,
    events: u32,
    ref: c_int,
    handle_ref: c_int = -1,
    registered: bool = false,
    canceled: bool = false,
    source_handle: ?event_loop.EventLoop.SourceHandle = null,

    pub fn register(self: *FdWatch) !void {
        if (self.registered or self.canceled) return;
        const loop = self.host.eventLoop() orelse return;
        self.source_handle = try loop.addFd(.{
            .fd = self.fd,
            .events = self.events,
            .ctx = self,
            .callback = fdWatchCallback,
        });
        errdefer self.unregister(loop);
        self.registered = true;
        try fdWatchCallback(self, loop, linux.EPOLL.IN);
    }

    pub fn unregister(self: *FdWatch, loop: *event_loop.EventLoop) void {
        if (self.source_handle) |handle| loop.removeSource(handle);
        self.source_handle = null;
        self.registered = false;
    }

    pub fn cancel(self: *FdWatch, lua_state: *c.lua_State) void {
        if (self.canceled) return;
        self.canceled = true;
        if (self.registered) {
            if (self.host.eventLoop()) |loop| self.unregister(loop);
        }
        if (self.ref >= 0) {
            c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, self.ref);
            self.ref = -1;
        }
        lua_handle.invalidate(lua_state, self.handle_ref);
        self.handle_ref = -1;
    }

    pub fn destroy(self: *FdWatch, allocator: std.mem.Allocator, lua_state: *c.lua_State) void {
        self.cancel(lua_state);
        allocator.destroy(self);
    }
};

pub const FsEvent = struct {
    host: Host,
    path: []const u8,
    ref: c_int,
    handle_ref: c_int = -1,
    watch: ?*event_loop.EventLoop.FileWatch = null,
    registered: bool = false,
    canceled: bool = false,

    pub fn register(self: *FsEvent) !void {
        if (self.registered or self.canceled) return;
        const loop = self.host.eventLoop() orelse return;
        self.watch = try loop.addFileWatch(self.path, self, fsEventCallback);
        self.registered = true;
    }

    pub fn unregister(self: *FsEvent, loop: *event_loop.EventLoop) void {
        if (self.watch) |watch| loop.removeFileWatch(watch);
        self.watch = null;
        self.registered = false;
    }

    pub fn cancel(self: *FsEvent, lua_state: *c.lua_State) void {
        if (self.canceled) return;
        self.canceled = true;
        if (self.registered) {
            if (self.host.eventLoop()) |loop| self.unregister(loop);
        }
        if (self.ref >= 0) {
            c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, self.ref);
            self.ref = -1;
        }
        lua_handle.invalidate(lua_state, self.handle_ref);
        self.handle_ref = -1;
    }

    pub fn destroy(self: *FsEvent, allocator: std.mem.Allocator, lua_state: *c.lua_State) void {
        self.cancel(lua_state);
        allocator.free(self.path);
        allocator.destroy(self);
    }
};

pub const LuaTimer = struct {
    host: Host,
    delay_ms: u64,
    interval_ms: u64,
    ref: c_int,
    handle_ref: c_int = -1,
    timer: ?*event_loop.EventLoop.Timer = null,
    registered: bool = false,
    canceled: bool = false,

    pub fn register(self: *LuaTimer) !void {
        if (self.registered or self.canceled) return;
        const loop = self.host.eventLoop() orelse return;
        const event_timer = try loop.addTimer(self, luaTimerCallback);
        errdefer loop.removeTimer(event_timer);
        try event_timer.arm(self.delay_ms, self.interval_ms);
        self.timer = event_timer;
        self.registered = true;
    }

    pub fn unregister(self: *LuaTimer, loop: *event_loop.EventLoop) void {
        if (self.timer) |timer| loop.removeTimer(timer);
        self.timer = null;
        self.registered = false;
    }

    pub fn cancel(self: *LuaTimer, lua_state: *c.lua_State) void {
        if (self.canceled) return;
        self.canceled = true;
        if (self.timer) |_| if (self.host.eventLoop()) |loop| self.unregister(loop);
        if (self.ref >= 0) {
            c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, self.ref);
            self.ref = -1;
        }
        lua_handle.invalidate(lua_state, self.handle_ref);
        self.handle_ref = -1;
    }

    pub fn destroy(self: *LuaTimer, allocator: std.mem.Allocator, lua_state: *c.lua_State) void {
        self.cancel(lua_state);
        allocator.destroy(self);
    }
};

pub fn installResourceApis(lua_state: *c.lua_State, loop_table: c_int, host: *Host) void {
    c.lua_pushlightuserdata(lua_state, host);
    c.lua_pushcclosure(lua_state, luaLoopTimer, 1);
    c.lua_setfield(lua_state, loop_table, "timer");
    c.lua_pushlightuserdata(lua_state, host);
    c.lua_pushcclosure(lua_state, luaWatchFd, 1);
    c.lua_setfield(lua_state, loop_table, "fd");
    c.lua_pushlightuserdata(lua_state, host);
    c.lua_pushcclosure(lua_state, luaFsEvent, 1);
    c.lua_setfield(lua_state, loop_table, "fs_event");
}

fn hostFromLua(lua_state: *c.lua_State) Host {
    const ptr = c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?;
    return @as(*Host, @ptrCast(@alignCast(ptr))).*;
}

fn fdWatchCallback(ctx: *anyopaque, _: *event_loop.EventLoop, events: u32) !void {
    const watch: *FdWatch = @ptrCast(@alignCast(ctx));
    if (watch.canceled or watch.ref < 0) return;
    const lua_state = watch.host.luaState();
    c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, watch.ref);
    c.lua_pushinteger(lua_state, watch.fd);
    c.lua_pushinteger(lua_state, @intCast(events));
    if (c.lua_pcall(lua_state, 2, 1, 0) != 0) {
        var len: usize = 0;
        const message_ptr = c.lua_tolstring(lua_state, -1, &len);
        if (message_ptr) |message| std.log.scoped(.keywork_luajit).warn("fd callback failed: {s}", .{message[0..len]});
        pop(lua_state, 1);
        watch.cancel(lua_state);
        return;
    }
    const should_invalidate = c.lua_toboolean(lua_state, -1) != 0;
    pop(lua_state, 1);
    if (should_invalidate) try watch.host.invalidate();
}

fn fsEventCallback(ctx: *anyopaque, _: *event_loop.EventLoop, path: []const u8, mask: u32, name: ?[]const u8) !void {
    const fs_event: *FsEvent = @ptrCast(@alignCast(ctx));
    if (fs_event.canceled or fs_event.ref < 0) return;
    const lua_state = fs_event.host.luaState();
    c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, fs_event.ref);
    pushFsEvent(lua_state, path, mask, name);
    if (c.lua_pcall(lua_state, 1, 1, 0) != 0) {
        var len: usize = 0;
        const message_ptr = c.lua_tolstring(lua_state, -1, &len);
        if (message_ptr) |message| std.log.scoped(.keywork_luajit).warn("fs_event callback failed: {s}", .{message[0..len]});
        pop(lua_state, 1);
        fs_event.cancel(lua_state);
        return;
    }
    const should_invalidate = c.lua_toboolean(lua_state, -1) != 0;
    pop(lua_state, 1);
    if (should_invalidate) try fs_event.host.invalidate();
}

fn luaTimerCallback(ctx: *anyopaque, _: *event_loop.EventLoop, expirations: u64) !void {
    const timer: *LuaTimer = @ptrCast(@alignCast(ctx));
    if (timer.canceled or timer.ref < 0 or expirations == 0) return;
    const lua_state = timer.host.luaState();
    c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, timer.ref);
    c.lua_pushinteger(lua_state, @intCast(expirations));
    if (c.lua_pcall(lua_state, 1, 0, 0) != 0) {
        var len: usize = 0;
        const message_ptr = c.lua_tolstring(lua_state, -1, &len);
        if (message_ptr) |message| std.log.scoped(.keywork_luajit).warn("timer callback failed: {s}", .{message[0..len]});
        pop(lua_state, 1);
        timer.cancel(lua_state);
        return;
    }
    if (timer.interval_ms == 0) timer.cancel(lua_state);
}

fn luaLoopTimer(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const host = hostFromLua(lua_state);
    c.luaL_checktype(lua_state, 1, c.LUA_TTABLE);
    c.luaL_checktype(lua_state, 2, c.LUA_TFUNCTION);
    const interval = optionalSecondsField(lua_state, 1, "interval");
    const delay = optionalSecondsField(lua_state, 1, "delay") orelse interval;
    const delay_seconds = delay orelse return c.luaL_error(lua_state, "timer requires delay or interval");
    const delay_ms = secondsToMilliseconds(delay_seconds) catch return c.luaL_error(lua_state, "invalid timer delay");
    const interval_ms = if (interval) |seconds| secondsToMilliseconds(seconds) catch return c.luaL_error(lua_state, "invalid timer interval") else 0;

    c.lua_pushvalue(lua_state, 2);
    const ref = c.luaL_ref(lua_state, c.LUA_REGISTRYINDEX);
    const timer = host.addTimer(delay_ms, interval_ms, ref) catch |err| {
        std.log.scoped(.keywork_luajit).warn("timer failed: {}", .{err});
        return c.luaL_error(lua_state, "timer failed");
    };
    pushTimerHandle(lua_state, timer);
    return 1;
}

fn luaWatchFd(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const host = hostFromLua(lua_state);
    const fd_int = c.luaL_checkinteger(lua_state, 1);
    if (fd_int < 0 or fd_int > std.math.maxInt(i32)) return c.luaL_error(lua_state, "invalid fd");
    c.luaL_checktype(lua_state, 2, c.LUA_TTABLE);
    c.luaL_checktype(lua_state, 3, c.LUA_TFUNCTION);
    var events: u32 = linux.EPOLL.HUP | linux.EPOLL.ERR;
    if (boolField(lua_state, 2, "read")) events |= linux.EPOLL.IN;
    if (boolField(lua_state, 2, "write")) events |= linux.EPOLL.OUT;
    if (events == (linux.EPOLL.HUP | linux.EPOLL.ERR)) events |= linux.EPOLL.IN;

    c.lua_pushvalue(lua_state, 3);
    const ref = c.luaL_ref(lua_state, c.LUA_REGISTRYINDEX);
    const watch = host.addFdWatch(@intCast(fd_int), events, ref) catch |err| {
        std.log.scoped(.keywork_luajit).warn("loop.fd failed: {}", .{err});
        return c.luaL_error(lua_state, "loop.fd failed");
    };
    pushFdWatchHandle(lua_state, watch);
    return 1;
}

fn luaFsEvent(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const host = hostFromLua(lua_state);
    const path = fsEventPath(lua_state, 1) catch return c.luaL_error(lua_state, "fs_event requires a path");
    c.luaL_checktype(lua_state, 2, c.LUA_TFUNCTION);

    c.lua_pushvalue(lua_state, 2);
    const ref = c.luaL_ref(lua_state, c.LUA_REGISTRYINDEX);
    const fs_event = host.addFsEvent(path, ref) catch |err| {
        std.log.scoped(.keywork_luajit).warn("loop.fs_event failed: {}", .{err});
        return c.luaL_error(lua_state, "loop.fs_event failed");
    };
    pushFsEventHandle(lua_state, fs_event);
    return 1;
}

const timer_type: [*:0]const u8 = "keywork.timer";
const timer_methods = [_]lua_handle.Method{
    .{ .name = "cancel", .func = luaCancelTimer },
    .{ .name = "canceled", .func = luaTimerCanceled },
};

const fd_watch_type: [*:0]const u8 = "keywork.fd";
const fd_watch_methods = [_]lua_handle.Method{
    .{ .name = "cancel", .func = luaCancelFdWatch },
    .{ .name = "canceled", .func = luaFdWatchCanceled },
};

const fs_event_type: [*:0]const u8 = "keywork.fs_event";
const fs_event_methods = [_]lua_handle.Method{
    .{ .name = "cancel", .func = luaCancelFsEvent },
    .{ .name = "canceled", .func = luaFsEventCanceled },
};

fn pushTimerHandle(lua_state: *c.lua_State, timer: *LuaTimer) void {
    timer.handle_ref = lua_handle.create(lua_state, timer_type, &timer_methods, timer);
}

fn pushFdWatchHandle(lua_state: *c.lua_State, watch: *FdWatch) void {
    watch.handle_ref = lua_handle.create(lua_state, fd_watch_type, &fd_watch_methods, watch);
}

fn pushFsEventHandle(lua_state: *c.lua_State, fs_event: *FsEvent) void {
    fs_event.handle_ref = lua_handle.create(lua_state, fs_event_type, &fs_event_methods, fs_event);
}

fn luaCancelTimer(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const timer = lua_handle.resource(LuaTimer, lua_state, 1, timer_type) orelse return 0;
    timer.cancel(lua_state);
    return 0;
}

fn luaCancelFdWatch(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const watch = lua_handle.resource(FdWatch, lua_state, 1, fd_watch_type) orelse return 0;
    watch.cancel(lua_state);
    return 0;
}

fn luaCancelFsEvent(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const fs_event = lua_handle.resource(FsEvent, lua_state, 1, fs_event_type) orelse return 0;
    fs_event.cancel(lua_state);
    return 0;
}

fn luaTimerCanceled(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const timer = lua_handle.resource(LuaTimer, lua_state, 1, timer_type) orelse {
        c.lua_pushboolean(lua_state, 1);
        return 1;
    };
    c.lua_pushboolean(lua_state, if (timer.canceled) 1 else 0);
    return 1;
}

fn luaFdWatchCanceled(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const watch = lua_handle.resource(FdWatch, lua_state, 1, fd_watch_type) orelse {
        c.lua_pushboolean(lua_state, 1);
        return 1;
    };
    c.lua_pushboolean(lua_state, if (watch.canceled) 1 else 0);
    return 1;
}

fn luaFsEventCanceled(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const fs_event = lua_handle.resource(FsEvent, lua_state, 1, fs_event_type) orelse {
        c.lua_pushboolean(lua_state, 1);
        return 1;
    };
    c.lua_pushboolean(lua_state, if (fs_event.canceled) 1 else 0);
    return 1;
}

fn pop(lua_state: *c.lua_State, count: c_int) void {
    c.lua_settop(lua_state, -count - 1);
}

fn absoluteIndex(lua_state: *c.lua_State, index: c_int) c_int {
    if (index > 0 or index <= c.LUA_REGISTRYINDEX) return index;
    return c.lua_gettop(lua_state) + index + 1;
}

fn stringFromStack(lua_state: *c.lua_State, index: c_int) ![]const u8 {
    var len: usize = 0;
    const ptr = c.lua_tolstring(lua_state, index, &len) orelse return error.ExpectedLuaString;
    return ptr[0..len];
}

fn stringField(lua_state: *c.lua_State, table: c_int, key: [*:0]const u8) ![]const u8 {
    c.lua_getfield(lua_state, table, key);
    defer pop(lua_state, 1);
    return try stringFromStack(lua_state, -1);
}

fn boolField(lua_state: *c.lua_State, table: c_int, key: [*:0]const u8) bool {
    c.lua_getfield(lua_state, table, key);
    defer pop(lua_state, 1);
    return c.lua_toboolean(lua_state, -1) != 0;
}

fn optionalSecondsField(lua_state: *c.lua_State, table: c_int, key: [*:0]const u8) ?f64 {
    c.lua_getfield(lua_state, table, key);
    defer pop(lua_state, 1);
    if (c.lua_isnil(lua_state, -1)) return null;
    if (c.lua_isnumber(lua_state, -1) == 0) return null;
    return c.lua_tonumber(lua_state, -1);
}

fn fsEventPath(lua_state: *c.lua_State, index: c_int) ![]const u8 {
    const absolute = absoluteIndex(lua_state, index);
    if (c.lua_type(lua_state, absolute) == c.LUA_TTABLE) return try stringField(lua_state, absolute, "path");
    return try stringFromStack(lua_state, absolute);
}

fn secondsToMilliseconds(seconds: f64) !u64 {
    if (!std.math.isFinite(seconds) or seconds <= 0) return error.InvalidTimerInterval;
    const milliseconds = @ceil(seconds * std.time.ms_per_s);
    if (milliseconds > @as(f64, @floatFromInt(std.math.maxInt(u64)))) return error.InvalidTimerInterval;
    return @intFromFloat(milliseconds);
}

fn pushFsEvent(lua_state: *c.lua_State, path: []const u8, mask: u32, name: ?[]const u8) void {
    c.lua_createtable(lua_state, 0, 7);
    const table = c.lua_gettop(lua_state);
    c.lua_pushlstring(lua_state, path.ptr, path.len);
    c.lua_setfield(lua_state, table, "path");
    if (name) |event_name| {
        c.lua_pushlstring(lua_state, event_name.ptr, event_name.len);
    } else {
        c.lua_pushnil(lua_state);
    }
    c.lua_setfield(lua_state, table, "name");
    c.lua_pushinteger(lua_state, @intCast(mask));
    c.lua_setfield(lua_state, table, "mask");
    c.lua_pushboolean(lua_state, if (mask & (linux.IN.MODIFY | linux.IN.CLOSE_WRITE | linux.IN.ATTRIB) != 0) 1 else 0);
    c.lua_setfield(lua_state, table, "change");
    c.lua_pushboolean(lua_state, if (mask & (linux.IN.MOVED_TO | linux.IN.MOVE_SELF | linux.IN.DELETE_SELF) != 0) 1 else 0);
    c.lua_setfield(lua_state, table, "rename");
    c.lua_pushboolean(lua_state, if (mask & linux.IN.DELETE_SELF != 0) 1 else 0);
    c.lua_setfield(lua_state, table, "delete_self");
    c.lua_pushboolean(lua_state, if (mask & linux.IN.MOVE_SELF != 0) 1 else 0);
    c.lua_setfield(lua_state, table, "move_self");
}
