//! LuaJIT-backed widget descriptions.

const std = @import("std");
const keywork = @import("libkeywork");
const c = @import("luajit_c");

const linux = std.os.linux;

const State = keywork.AppContext;
const BuildScope = keywork.BuildScope;

const app_registry_key = "keywork.app";

const LuaCallback = struct {
    allocator: std.mem.Allocator,
    lua_state: *c.lua_State,
    ref: c_int,

    fn keyworkCallback(self: *LuaCallback) keywork.Widget.Callback {
        return .{
            .ptr = self,
            .call_fn = call,
            .clone_fn = clone,
            .destroy_fn = destroy,
        };
    }

    fn keyworkFocusChangeCallback(self: *LuaCallback) keywork.Widget.FocusChangeCallback {
        return .{
            .ptr = self,
            .call_fn = callFocusChange,
            .clone_fn = clone,
            .destroy_fn = destroy,
        };
    }

    fn call(ptr: *anyopaque) !void {
        const self: *LuaCallback = @ptrCast(@alignCast(ptr));
        c.lua_rawgeti(self.lua_state, c.LUA_REGISTRYINDEX, self.ref);
        if (c.lua_pcall(self.lua_state, 0, 0, 0) != 0) {
            var len: usize = 0;
            const message_ptr = c.lua_tolstring(self.lua_state, -1, &len);
            if (message_ptr) |message| std.log.scoped(.keywork_luajit).warn("callback failed: {s}", .{message[0..len]});
            pop(self.lua_state, 1);
            return error.LuaCallbackFailed;
        }
    }

    fn callFocusChange(ptr: *anyopaque, focused: bool) !void {
        const self: *LuaCallback = @ptrCast(@alignCast(ptr));
        c.lua_rawgeti(self.lua_state, c.LUA_REGISTRYINDEX, self.ref);
        c.lua_pushboolean(self.lua_state, if (focused) 1 else 0);
        if (c.lua_pcall(self.lua_state, 1, 0, 0) != 0) {
            var len: usize = 0;
            const message_ptr = c.lua_tolstring(self.lua_state, -1, &len);
            if (message_ptr) |message| std.log.scoped(.keywork_luajit).warn("focus callback failed: {s}", .{message[0..len]});
            pop(self.lua_state, 1);
            return error.LuaCallbackFailed;
        }
    }

    fn clone(allocator: std.mem.Allocator, ptr: *anyopaque) !*anyopaque {
        const self: *LuaCallback = @ptrCast(@alignCast(ptr));
        if (self.ref < 0) return error.LuaCallbackAlreadyMoved;
        c.lua_rawgeti(self.lua_state, c.LUA_REGISTRYINDEX, self.ref);
        const ref = c.luaL_ref(self.lua_state, c.LUA_REGISTRYINDEX);
        errdefer c.luaL_unref(self.lua_state, c.LUA_REGISTRYINDEX, ref);
        c.luaL_unref(self.lua_state, c.LUA_REGISTRYINDEX, self.ref);
        self.ref = -2;
        const result = try allocator.create(LuaCallback);
        result.* = .{ .allocator = allocator, .lua_state = self.lua_state, .ref = ref };
        return result;
    }

    fn destroy(_: std.mem.Allocator, ptr: *anyopaque) void {
        const self: *LuaCallback = @ptrCast(@alignCast(ptr));
        if (self.ref >= 0) c.luaL_unref(self.lua_state, c.LUA_REGISTRYINDEX, self.ref);
        self.allocator.destroy(self);
    }
};

const LuaStatefulWidget = struct {
    allocator: std.mem.Allocator,
    app: *App,
    lua_state: *c.lua_State,
    spec_ref: c_int,
    props_ref: c_int,

    const vtable: keywork.Widget.Stateful.VTable = .{
        .create_state = createState,
        .update = update,
        .build = build,
        .destroy_state = destroyState,
        .needs_rebuild = needsRebuild,
        .clear_rebuild = clearRebuild,
    };

    fn widget(self: *LuaStatefulWidget) keywork.Widget {
        return .{ .stateful = .{
            .ptr = self,
            .vtable = &vtable,
            .clone_fn = clone,
            .destroy_fn = destroy,
        } };
    }

    fn createState(ptr: *const anyopaque, allocator: std.mem.Allocator) !*anyopaque {
        const self: *const LuaStatefulWidget = @ptrCast(@alignCast(ptr));
        const state = try allocator.create(LuaStatefulState);
        errdefer allocator.destroy(state);
        state.* = .{ .lua_state = self.lua_state, .state_ref = -1 };

        c.lua_rawgeti(self.lua_state, c.LUA_REGISTRYINDEX, self.spec_ref);
        const spec = c.lua_gettop(self.lua_state);
        defer pop(self.lua_state, 1);

        c.lua_getfield(self.lua_state, spec, "init");
        if (c.lua_isnil(self.lua_state, -1)) {
            pop(self.lua_state, 1);
            c.lua_createtable(self.lua_state, 0, 0);
        } else {
            c.lua_rawgeti(self.lua_state, c.LUA_REGISTRYINDEX, self.props_ref);
            if (c.lua_pcall(self.lua_state, 1, 1, 0) != 0) return failLuaCall(self.lua_state, "stateful init failed");
            if (c.lua_type(self.lua_state, -1) != c.LUA_TTABLE) return error.StatefulInitReturnedInvalidValue;
        }
        errdefer pop(self.lua_state, 1);

        installStateMethods(self.lua_state, self.app, state, c.lua_gettop(self.lua_state));
        setStateProps(self.lua_state, c.lua_gettop(self.lua_state), self.props_ref);
        state.state_ref = c.luaL_ref(self.lua_state, c.LUA_REGISTRYINDEX);
        return state;
    }

    fn update(ptr: *const anyopaque, state_ptr: *anyopaque, _: std.mem.Allocator, _: keywork.Widget.BuildContext) !void {
        const self: *const LuaStatefulWidget = @ptrCast(@alignCast(ptr));
        const state: *LuaStatefulState = @ptrCast(@alignCast(state_ptr));
        c.lua_rawgeti(self.lua_state, c.LUA_REGISTRYINDEX, state.state_ref);
        const state_table = c.lua_gettop(self.lua_state);
        defer pop(self.lua_state, 1);

        setStateProps(self.lua_state, state_table, self.props_ref);

        c.lua_rawgeti(self.lua_state, c.LUA_REGISTRYINDEX, self.spec_ref);
        const spec = c.lua_gettop(self.lua_state);
        defer pop(self.lua_state, 1);
        c.lua_getfield(self.lua_state, spec, "update");
        if (c.lua_isnil(self.lua_state, -1)) {
            pop(self.lua_state, 1);
            return;
        }
        c.lua_pushvalue(self.lua_state, state_table);
        c.lua_rawgeti(self.lua_state, c.LUA_REGISTRYINDEX, self.props_ref);
        if (c.lua_pcall(self.lua_state, 2, 0, 0) != 0) return failLuaCall(self.lua_state, "stateful update failed");
    }

    fn build(ptr: *const anyopaque, state_ptr: *anyopaque, scope: *BuildScope, context: keywork.Widget.BuildContext) !keywork.Widget {
        const self: *const LuaStatefulWidget = @ptrCast(@alignCast(ptr));
        const state: *LuaStatefulState = @ptrCast(@alignCast(state_ptr));

        c.lua_rawgeti(self.lua_state, c.LUA_REGISTRYINDEX, self.spec_ref);
        const spec = c.lua_gettop(self.lua_state);
        defer pop(self.lua_state, 1);
        c.lua_getfield(self.lua_state, spec, "build");
        if (c.lua_isnil(self.lua_state, -1)) {
            pop(self.lua_state, 1);
            return error.StatefulBuildMissing;
        }
        c.lua_rawgeti(self.lua_state, c.LUA_REGISTRYINDEX, state.state_ref);
        pushRuntimeState(self.lua_state, context.app_context);
        if (c.lua_pcall(self.lua_state, 2, 1, 0) != 0) return failLuaCall(self.lua_state, "stateful build failed");
        defer pop(self.lua_state, 1);
        return try parseWidget(self.lua_state, scope.allocator, scope.allocator, context.app_context, -1);
    }

    fn destroyState(ptr: *const anyopaque, state_ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *const LuaStatefulWidget = @ptrCast(@alignCast(ptr));
        const state: *LuaStatefulState = @ptrCast(@alignCast(state_ptr));

        c.lua_rawgeti(self.lua_state, c.LUA_REGISTRYINDEX, self.spec_ref);
        const spec = c.lua_gettop(self.lua_state);
        c.lua_getfield(self.lua_state, spec, "destroy");
        if (c.lua_isnil(self.lua_state, -1)) {
            pop(self.lua_state, 2);
        } else {
            c.lua_rawgeti(self.lua_state, c.LUA_REGISTRYINDEX, state.state_ref);
            if (c.lua_pcall(self.lua_state, 1, 0, 0) != 0) {
                failLuaCall(self.lua_state, "stateful destroy failed") catch {};
            }
            pop(self.lua_state, 1);
        }

        if (state.state_ref >= 0) c.luaL_unref(self.lua_state, c.LUA_REGISTRYINDEX, state.state_ref);
        allocator.destroy(state);
    }

    fn needsRebuild(_: *const anyopaque, state_ptr: *anyopaque) bool {
        const state: *LuaStatefulState = @ptrCast(@alignCast(state_ptr));
        return state.dirty;
    }

    fn clearRebuild(_: *const anyopaque, state_ptr: *anyopaque) void {
        const state: *LuaStatefulState = @ptrCast(@alignCast(state_ptr));
        state.dirty = false;
    }

    fn clone(allocator: std.mem.Allocator, ptr: *const anyopaque) !*const anyopaque {
        const self: *LuaStatefulWidget = @ptrCast(@alignCast(@constCast(ptr)));
        if (self.spec_ref < 0 or self.props_ref < 0) return error.LuaStatefulWidgetAlreadyMoved;
        const spec_ref = try cloneRegistryRef(self.lua_state, self.spec_ref);
        errdefer c.luaL_unref(self.lua_state, c.LUA_REGISTRYINDEX, spec_ref);
        const props_ref = try cloneRegistryRef(self.lua_state, self.props_ref);
        errdefer c.luaL_unref(self.lua_state, c.LUA_REGISTRYINDEX, props_ref);
        c.luaL_unref(self.lua_state, c.LUA_REGISTRYINDEX, self.spec_ref);
        c.luaL_unref(self.lua_state, c.LUA_REGISTRYINDEX, self.props_ref);
        self.spec_ref = -2;
        self.props_ref = -2;

        const result = try allocator.create(LuaStatefulWidget);
        result.* = .{
            .allocator = allocator,
            .app = self.app,
            .lua_state = self.lua_state,
            .spec_ref = spec_ref,
            .props_ref = props_ref,
        };
        return result;
    }

    fn destroy(_: std.mem.Allocator, ptr: *const anyopaque) void {
        const self: *LuaStatefulWidget = @ptrCast(@alignCast(@constCast(ptr)));
        if (self.spec_ref >= 0) c.luaL_unref(self.lua_state, c.LUA_REGISTRYINDEX, self.spec_ref);
        if (self.props_ref >= 0) c.luaL_unref(self.lua_state, c.LUA_REGISTRYINDEX, self.props_ref);
        self.allocator.destroy(self);
    }
};

const LuaStatefulState = struct {
    lua_state: *c.lua_State,
    state_ref: c_int,
    dirty: bool = false,
};

pub const App = struct {
    allocator: std.mem.Allocator,
    path: [:0]u8,
    state: *c.lua_State,
    fd_watches: std.ArrayList(*FdWatch) = .empty,
    event_loop: ?*keywork.event_loop.EventLoop = null,
    runtime: ?*keywork.Runtime = null,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !App {
        const path_z = try allocator.dupeZ(u8, path);
        errdefer allocator.free(path_z);

        switch (linux.errno(linux.access(path_z.ptr, 0))) {
            .SUCCESS => {},
            .NOENT => return error.ScriptNotFound,
            else => return error.ScriptAccessFailed,
        }

        const lua_state = c.luaL_newstate() orelse return error.OutOfMemory;
        errdefer c.lua_close(lua_state);
        c.luaL_openlibs(lua_state);
        installUi(lua_state);

        return .{
            .allocator = allocator,
            .path = path_z,
            .state = lua_state,
        };
    }

    pub fn deinit(self: *App) void {
        for (self.fd_watches.items) |watch| watch.destroy(self.allocator, self.state);
        self.fd_watches.deinit(self.allocator);
        c.lua_close(self.state);
        self.allocator.free(self.path);
    }

    pub fn installEventSources(self: *App, loop: *keywork.event_loop.EventLoop, runtime: *keywork.Runtime) !void {
        self.event_loop = loop;
        self.runtime = runtime;
        for (self.fd_watches.items) |watch| try self.registerFdWatch(watch);
    }

    pub fn host(self: *App) keywork.AppHost {
        return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidgetHost } };
    }

    pub fn buildWidget(self: *App, allocator: std.mem.Allocator, runtime_state: State) !keywork.Widget {
        c.lua_settop(self.state, 0);
        installKeyworkModule(self.state, self);
        if (c.luaL_loadfile(self.state, self.path.ptr) != 0) return self.failWithLuaError(error.ScriptLoadFailed);
        if (c.lua_pcall(self.state, 0, 1, 0) != 0) return self.failWithLuaError(error.ScriptRunFailed);

        switch (c.lua_type(self.state, -1)) {
            c.LUA_TFUNCTION => {
                pushRuntimeState(self.state, runtime_state);
                if (c.lua_pcall(self.state, 1, 1, 0) != 0) return self.failWithLuaError(error.ScriptRunFailed);
            },
            c.LUA_TTABLE => {},
            else => return error.ScriptReturnedInvalidValue,
        }

        return try parseWidget(self.state, allocator, allocator, runtime_state, -1);
    }

    fn buildWidgetHost(ptr: *anyopaque, scope: *BuildScope, runtime_state: State) !keywork.Widget {
        const self: *App = @ptrCast(@alignCast(ptr));
        return self.buildWidget(scope.allocator, runtime_state);
    }

    fn failWithLuaError(self: *App, err: anyerror) anyerror {
        var len: usize = 0;
        const message_ptr = c.lua_tolstring(self.state, -1, &len);
        if (message_ptr) |ptr| {
            std.log.scoped(.keywork_luajit).warn("{s}", .{ptr[0..len]});
        }
        return err;
    }

    fn addFdWatch(self: *App, fd: i32, events: u32, ref: c_int) !void {
        const watch = try self.allocator.create(FdWatch);
        errdefer self.allocator.destroy(watch);
        watch.* = .{ .app = self, .fd = fd, .events = events, .ref = ref };
        errdefer c.luaL_unref(self.state, c.LUA_REGISTRYINDEX, ref);

        try self.fd_watches.append(self.allocator, watch);
        errdefer _ = self.fd_watches.pop();
        try self.registerFdWatch(watch);
    }

    fn registerFdWatch(self: *App, watch: *FdWatch) !void {
        if (watch.registered) return;
        const loop = self.event_loop orelse return;
        try loop.addFd(.{
            .fd = watch.fd,
            .events = watch.events,
            .ctx = watch,
            .callback = fdWatchCallback,
        });
        watch.registered = true;
        try fdWatchCallback(watch, loop, linux.EPOLL.IN);
    }
};

const FdWatch = struct {
    app: *App,
    fd: i32,
    events: u32,
    ref: c_int,
    registered: bool = false,

    fn destroy(self: *FdWatch, allocator: std.mem.Allocator, lua_state: *c.lua_State) void {
        if (self.ref >= 0) c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, self.ref);
        allocator.destroy(self);
    }
};

fn fdWatchCallback(ctx: *anyopaque, _: *keywork.event_loop.EventLoop, events: u32) !void {
    const watch: *FdWatch = @ptrCast(@alignCast(ctx));
    const app = watch.app;
    c.lua_rawgeti(app.state, c.LUA_REGISTRYINDEX, watch.ref);
    c.lua_pushinteger(app.state, watch.fd);
    c.lua_pushinteger(app.state, @intCast(events));
    if (c.lua_pcall(app.state, 2, 1, 0) != 0) {
        var len: usize = 0;
        const message_ptr = c.lua_tolstring(app.state, -1, &len);
        if (message_ptr) |message| std.log.scoped(.keywork_luajit).warn("fd callback failed: {s}", .{message[0..len]});
        pop(app.state, 1);
        return error.LuaCallbackFailed;
    }
    const should_invalidate = c.lua_toboolean(app.state, -1) != 0;
    pop(app.state, 1);
    if (should_invalidate) {
        const runtime = app.runtime orelse return;
        try runtime.invalidate();
    }
}

fn installUi(lua_state: *c.lua_State) void {
    addPackagePath(lua_state, "src/?.lua");
}

fn installKeyworkModule(lua_state: *c.lua_State, app: *App) void {
    c.lua_pushlightuserdata(lua_state, app);
    c.lua_setfield(lua_state, c.LUA_REGISTRYINDEX, app_registry_key);

    c.lua_getfield(lua_state, c.LUA_GLOBALSINDEX, "package");
    const package_table = c.lua_gettop(lua_state);
    c.lua_getfield(lua_state, package_table, "preload");
    const preload_table = c.lua_gettop(lua_state);
    c.lua_pushlightuserdata(lua_state, app);
    c.lua_pushcclosure(lua_state, keyworkModuleLoader, 1);
    c.lua_setfield(lua_state, preload_table, "keywork");
    pop(lua_state, 2);
}

fn keyworkModuleLoader(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const app: *App = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    c.lua_createtable(lua_state, 0, 2);
    const table = c.lua_gettop(lua_state);

    c.lua_pushlightuserdata(lua_state, app);
    c.lua_pushcclosure(lua_state, luaWatchFd, 1);
    c.lua_setfield(lua_state, table, "watch_fd");

    c.lua_pushlightuserdata(lua_state, app);
    c.lua_pushcclosure(lua_state, luaInvalidate, 1);
    c.lua_setfield(lua_state, table, "invalidate");
    return 1;
}

fn luaWatchFd(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const app: *App = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    const fd_int = c.luaL_checkinteger(lua_state, 1);
    if (fd_int < 0 or fd_int > std.math.maxInt(i32)) return c.luaL_error(lua_state, "invalid fd");
    c.luaL_checktype(lua_state, 2, c.LUA_TFUNCTION);
    const events: u32 = if (c.lua_isnumber(lua_state, 3) != 0)
        @intCast(c.lua_tointeger(lua_state, 3))
    else
        linux.EPOLL.IN | linux.EPOLL.HUP | linux.EPOLL.ERR;

    c.lua_pushvalue(lua_state, 2);
    const ref = c.luaL_ref(lua_state, c.LUA_REGISTRYINDEX);
    app.addFdWatch(@intCast(fd_int), events, ref) catch |err| {
        c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, ref);
        std.log.scoped(.keywork_luajit).warn("watch_fd failed: {}", .{err});
        return c.luaL_error(lua_state, "watch_fd failed");
    };
    return 0;
}

fn luaInvalidate(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const app: *App = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    const runtime = app.runtime orelse return 0;
    runtime.invalidate() catch |err| {
        std.log.scoped(.keywork_luajit).warn("invalidate failed: {}", .{err});
        return c.luaL_error(lua_state, "invalidate failed");
    };
    return 0;
}

fn luaSetState(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const app: *App = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    const state: *LuaStatefulState = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(2)).?));
    if (c.lua_type(lua_state, 2) == c.LUA_TFUNCTION) {
        c.lua_pushvalue(lua_state, 2);
        c.lua_pushvalue(lua_state, 1);
        if (c.lua_pcall(lua_state, 1, 0, 0) != 0) {
            failLuaCall(lua_state, "set_state callback failed") catch {};
            return c.luaL_error(lua_state, "set_state callback failed");
        }
    }
    state.dirty = true;
    const runtime = app.runtime orelse return 0;
    runtime.invalidateState() catch |err| {
        std.log.scoped(.keywork_luajit).warn("set_state invalidate failed: {}", .{err});
        return c.luaL_error(lua_state, "set_state invalidate failed");
    };
    return 0;
}

fn addPackagePath(lua_state: *c.lua_State, path: []const u8) void {
    c.lua_getfield(lua_state, c.LUA_GLOBALSINDEX, "package");
    const package_table = c.lua_gettop(lua_state);
    c.lua_getfield(lua_state, package_table, "path");
    var len: usize = 0;
    const current = c.lua_tolstring(lua_state, -1, &len) orelse {
        pop(lua_state, 2);
        return;
    };
    c.lua_pushlstring(lua_state, current, len);
    c.lua_pushlstring(lua_state, ";", 1);
    c.lua_pushlstring(lua_state, path.ptr, path.len);
    c.lua_concat(lua_state, 3);
    c.lua_setfield(lua_state, package_table, "path");
    pop(lua_state, 2);
}

fn pushRuntimeState(lua_state: *c.lua_State, state: State) void {
    c.lua_createtable(lua_state, 0, 5);
    const table = c.lua_gettop(lua_state);
    c.lua_pushboolean(lua_state, if (state.pulse) 1 else 0);
    c.lua_setfield(lua_state, table, "pulse");
    c.lua_pushlstring(lua_state, state.input_text.ptr, state.input_text.len);
    c.lua_setfield(lua_state, table, "input_text");
    c.lua_pushnumber(lua_state, state.window_width);
    c.lua_setfield(lua_state, table, "window_width");
    c.lua_pushnumber(lua_state, state.window_height);
    c.lua_setfield(lua_state, table, "window_height");
    c.lua_pushlstring(lua_state, state.color_scheme.ptr, state.color_scheme.len);
    c.lua_setfield(lua_state, table, "color_scheme");
}

fn parseWidget(
    lua_state: *c.lua_State,
    allocator: std.mem.Allocator,
    callback_allocator: std.mem.Allocator,
    runtime_state: State,
    index: c_int,
) !keywork.Widget {
    const table = absoluteIndex(lua_state, index);
    try expectType(lua_state, table, c.LUA_TTABLE);

    const kind = try getStringField(lua_state, table, "type");
    defer pop(lua_state, 1);

    if (std.mem.eql(u8, kind, "text")) {
        const value = try dupeStringField(lua_state, allocator, table, "value");
        return .{ .text = .{ .value = value, .color = getOptionalColorField(lua_state, table, "color") } };
    }
    if (std.mem.eql(u8, kind, "keyed")) {
        const key = try dupeStringField(lua_state, allocator, table, "key");
        const child = try allocator.create(keywork.Widget);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parseWidget(lua_state, allocator, callback_allocator, runtime_state, -1);
        return .{ .keyed = .{ .key = .{ .string = key }, .child = child } };
    }
    if (std.mem.eql(u8, kind, "stateful")) {
        const app = appFromRegistry(lua_state) orelse return error.MissingLuaApp;
        const stateful = try allocator.create(LuaStatefulWidget);
        errdefer allocator.destroy(stateful);
        const spec_ref = try tableRefField(lua_state, table, "spec");
        errdefer c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, spec_ref);
        const props_ref = try tableRefField(lua_state, table, "props");
        errdefer c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, props_ref);
        stateful.* = .{
            .allocator = allocator,
            .app = app,
            .lua_state = lua_state,
            .spec_ref = spec_ref,
            .props_ref = props_ref,
        };
        return stateful.widget();
    }
    if (std.mem.eql(u8, kind, "box")) {
        const child = try allocator.create(keywork.Widget);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parseWidget(lua_state, allocator, callback_allocator, runtime_state, -1);
        return .{ .box = .{
            .child = child,
            .background = getColorField(lua_state, table, "background", keywork.colors.transparent),
        } };
    }
    if (std.mem.eql(u8, kind, "clickable")) {
        const id = try dupeStringField(lua_state, allocator, table, "id");
        errdefer allocator.free(id);
        const child = try allocator.create(keywork.Widget);
        errdefer allocator.destroy(child);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parseWidget(lua_state, allocator, callback_allocator, runtime_state, -1);
        const on_click = try getOptionalCallbackField(lua_state, callback_allocator, table, "on_click");
        return .{ .clickable = .{ .id = id, .child = child, .on_click = on_click, .activation = getActivationField(lua_state, table) } };
    }
    if (std.mem.eql(u8, kind, "focus")) {
        const id = try dupeStringField(lua_state, allocator, table, "id");
        errdefer allocator.free(id);
        const child = try allocator.create(keywork.Widget);
        errdefer allocator.destroy(child);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parseWidget(lua_state, allocator, callback_allocator, runtime_state, -1);
        const on_focus_change = try getOptionalFocusChangeCallbackField(lua_state, callback_allocator, table, "on_focus_change");
        return .{ .focus = .{
            .node = .named(id),
            .child = child,
            .autofocus = getBooleanField(lua_state, table, "autofocus", false),
            .skip_traversal = getBooleanField(lua_state, table, "skip_traversal", false),
            .can_request_focus = getBooleanField(lua_state, table, "can_request_focus", true),
            .on_focus_change = on_focus_change,
        } };
    }
    if (std.mem.eql(u8, kind, "focus_scope")) {
        const id = try dupeStringField(lua_state, allocator, table, "id");
        errdefer allocator.free(id);
        const child = try allocator.create(keywork.Widget);
        errdefer allocator.destroy(child);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parseWidget(lua_state, allocator, callback_allocator, runtime_state, -1);
        return .{ .focus_scope = .{ .id = id, .child = child, .modal = getBooleanField(lua_state, table, "modal", false) } };
    }
    if (std.mem.eql(u8, kind, "button")) {
        const id = try dupeStringField(lua_state, allocator, table, "id");
        const label = try dupeStringField(lua_state, allocator, table, "label");
        const on_pressed = try getOptionalCallbackField(lua_state, callback_allocator, table, "on_pressed");
        const intent = try getOptionalIntentField(lua_state, allocator, table, "action_id");
        return .{ .button = .{ .id = id, .label = label, .on_pressed = on_pressed, .intent = intent } };
    }
    if (std.mem.eql(u8, kind, "text_input")) {
        const id = try dupeStringField(lua_state, allocator, table, "id");
        const placeholder = try dupeStringField(lua_state, allocator, table, "placeholder");
        const value = try allocator.dupe(u8, runtime_state.input_text);
        return keywork.widgets.textInput(id, value, placeholder);
    }
    if (std.mem.eql(u8, kind, "spacer")) {
        return keywork.widgets.spacer(getNumberField(lua_state, table, "flex", 1));
    }
    if (std.mem.eql(u8, kind, "svg_icon")) {
        const path = try stringField(lua_state, table, "path");
        return keywork.svg_icon.icon(
            allocator,
            path,
            getNumberField(lua_state, table, "size", 16),
            getColorField(lua_state, table, "color", keywork.colors.ink),
        );
    }
    if (std.mem.eql(u8, kind, "icon")) {
        const name = try stringField(lua_state, table, "name");
        const size = getNumberField(lua_state, table, "size", 16);
        const path = try keywork.icon_theme.lookupSvgIconSized(allocator, name, size) orelse return error.IconNotFound;
        defer allocator.free(path);
        return keywork.svg_icon.icon(
            allocator,
            path,
            size,
            getColorField(lua_state, table, "color", keywork.colors.ink),
        );
    }
    if (std.mem.eql(u8, kind, "row")) {
        const children = try parseChildren(lua_state, allocator, callback_allocator, runtime_state, table);
        return .{ .row = .{ .children = children, .gap = getNumberField(lua_state, table, "gap", 0) } };
    }
    if (std.mem.eql(u8, kind, "column")) {
        const children = try parseChildren(lua_state, allocator, callback_allocator, runtime_state, table);
        return .{ .column = .{ .children = children, .gap = getNumberField(lua_state, table, "gap", 0) } };
    }
    if (std.mem.eql(u8, kind, "padding")) {
        const child = try allocator.create(keywork.Widget);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parseWidget(lua_state, allocator, callback_allocator, runtime_state, -1);
        const inset = getNumberField(lua_state, table, "insets", 0);
        return .{ .padding = .{ .insets = keywork.EdgeInsets.all(inset), .child = child } };
    }
    if (std.mem.eql(u8, kind, "center")) {
        const child = try allocator.create(keywork.Widget);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parseWidget(lua_state, allocator, callback_allocator, runtime_state, -1);
        return .{ .center = .{ .child = child } };
    }
    if (std.mem.eql(u8, kind, "actions")) {
        const child = try allocator.create(keywork.Widget);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parseWidget(lua_state, allocator, callback_allocator, runtime_state, -1);
        const bindings = try parseActionBindings(lua_state, allocator, callback_allocator, table);
        return .{ .actions = .{ .bindings = bindings, .child = child } };
    }
    if (std.mem.eql(u8, kind, "shortcuts")) {
        const child = try allocator.create(keywork.Widget);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parseWidget(lua_state, allocator, callback_allocator, runtime_state, -1);
        const bindings = try parseShortcutBindings(lua_state, allocator, table);
        return .{ .shortcuts = .{ .bindings = bindings, .child = child } };
    }

    return error.UnknownWidgetType;
}

fn parseChildren(
    lua_state: *c.lua_State,
    allocator: std.mem.Allocator,
    callback_allocator: std.mem.Allocator,
    runtime_state: State,
    table: c_int,
) anyerror![]keywork.Widget {
    c.lua_getfield(lua_state, table, "children");
    defer pop(lua_state, 1);
    const children_table = absoluteIndex(lua_state, -1);
    try expectType(lua_state, children_table, c.LUA_TTABLE);
    const count: usize = @intCast(c.lua_objlen(lua_state, children_table));
    const children = try allocator.alloc(keywork.Widget, count);
    for (children, 0..) |*child, child_index| {
        c.lua_rawgeti(lua_state, children_table, @intCast(child_index + 1));
        defer pop(lua_state, 1);
        child.* = try parseWidget(lua_state, allocator, callback_allocator, runtime_state, -1);
    }
    return children;
}

fn parseActionBindings(
    lua_state: *c.lua_State,
    allocator: std.mem.Allocator,
    callback_allocator: std.mem.Allocator,
    table: c_int,
) ![]keywork.Widget.ActionBinding {
    c.lua_getfield(lua_state, table, "bindings");
    defer pop(lua_state, 1);
    const bindings_table = absoluteIndex(lua_state, -1);
    try expectType(lua_state, bindings_table, c.LUA_TTABLE);

    var bindings: std.ArrayList(keywork.Widget.ActionBinding) = .empty;
    errdefer bindings.deinit(allocator);
    c.lua_pushnil(lua_state);
    while (c.lua_next(lua_state, bindings_table) != 0) {
        defer pop(lua_state, 1);
        const id = try stringFromStack(lua_state, -2);
        const callback = try callbackFromStack(lua_state, callback_allocator, -1);
        try bindings.append(allocator, .{ .id = try allocator.dupe(u8, id), .callback = callback });
    }
    return try bindings.toOwnedSlice(allocator);
}

fn parseShortcutBindings(
    lua_state: *c.lua_State,
    allocator: std.mem.Allocator,
    table: c_int,
) ![]keywork.Widget.ShortcutBinding {
    c.lua_getfield(lua_state, table, "bindings");
    defer pop(lua_state, 1);
    const bindings_table = absoluteIndex(lua_state, -1);
    try expectType(lua_state, bindings_table, c.LUA_TTABLE);

    var bindings: std.ArrayList(keywork.Widget.ShortcutBinding) = .empty;
    errdefer bindings.deinit(allocator);
    c.lua_pushnil(lua_state);
    while (c.lua_next(lua_state, bindings_table) != 0) {
        defer pop(lua_state, 1);
        const key_name = try stringFromStack(lua_state, -2);
        const intent = try intentFromStack(lua_state, allocator, -1);
        try bindings.append(allocator, .{
            .key = try shortcutKeyFromString(key_name),
            .intent = intent,
        });
    }
    return try bindings.toOwnedSlice(allocator);
}

fn shortcutKeyFromString(value: []const u8) !keywork.ShortcutKey {
    if (std.mem.eql(u8, value, "enter")) return .enter;
    if (std.mem.eql(u8, value, "space")) return .space;
    if (std.mem.eql(u8, value, "backspace")) return .backspace;
    return error.UnknownShortcutKey;
}

fn absoluteIndex(lua_state: *c.lua_State, index: c_int) c_int {
    if (index > 0 or index <= c.LUA_REGISTRYINDEX) return index;
    return c.lua_gettop(lua_state) + index + 1;
}

fn expectType(lua_state: *c.lua_State, index: c_int, expected: c_int) !void {
    if (c.lua_type(lua_state, index) != expected) return error.UnexpectedLuaType;
}

fn getStringField(lua_state: *c.lua_State, table: c_int, key: [*:0]const u8) ![]const u8 {
    c.lua_getfield(lua_state, table, key);
    return stringFromStack(lua_state, -1);
}

fn dupeStringField(lua_state: *c.lua_State, allocator: std.mem.Allocator, table: c_int, key: [*:0]const u8) ![]const u8 {
    const value = try stringField(lua_state, table, key);
    return try allocator.dupe(u8, value);
}

fn stringField(lua_state: *c.lua_State, table: c_int, key: [*:0]const u8) ![]const u8 {
    const value = try getStringField(lua_state, table, key);
    defer pop(lua_state, 1);
    return value;
}

fn tableRefField(lua_state: *c.lua_State, table: c_int, key: [*:0]const u8) !c_int {
    c.lua_getfield(lua_state, table, key);
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) {
        pop(lua_state, 1);
        return error.ExpectedLuaTable;
    }
    return c.luaL_ref(lua_state, c.LUA_REGISTRYINDEX);
}

fn cloneRegistryRef(lua_state: *c.lua_State, ref: c_int) !c_int {
    if (ref < 0) return error.InvalidLuaRegistryRef;
    c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, ref);
    return c.luaL_ref(lua_state, c.LUA_REGISTRYINDEX);
}

fn appFromRegistry(lua_state: *c.lua_State) ?*App {
    c.lua_getfield(lua_state, c.LUA_REGISTRYINDEX, app_registry_key);
    defer pop(lua_state, 1);
    return @ptrCast(@alignCast(c.lua_touserdata(lua_state, -1) orelse return null));
}

fn installStateMethods(lua_state: *c.lua_State, app: *App, state: *LuaStatefulState, state_table: c_int) void {
    c.lua_pushlightuserdata(lua_state, app);
    c.lua_pushlightuserdata(lua_state, state);
    c.lua_pushcclosure(lua_state, luaSetState, 2);
    c.lua_setfield(lua_state, state_table, "set_state");
}

fn setStateProps(lua_state: *c.lua_State, state_table: c_int, props_ref: c_int) void {
    c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, props_ref);
    c.lua_setfield(lua_state, state_table, "props");
}

fn failLuaCall(lua_state: *c.lua_State, err: []const u8) anyerror {
    var len: usize = 0;
    const message_ptr = c.lua_tolstring(lua_state, -1, &len);
    if (message_ptr) |message| std.log.scoped(.keywork_luajit).warn("{s}: {s}", .{ err, message[0..len] });
    pop(lua_state, 1);
    return error.LuaCallbackFailed;
}

fn getActivationField(lua_state: *c.lua_State, table: c_int) keywork.Widget.ClickActivation {
    c.lua_getfield(lua_state, table, "activation");
    defer pop(lua_state, 1);
    if (c.lua_isnil(lua_state, -1)) return .release;
    const value = stringFromStack(lua_state, -1) catch return .release;
    if (std.mem.eql(u8, value, "press")) return .press;
    return .release;
}

fn getOptionalIntentField(lua_state: *c.lua_State, allocator: std.mem.Allocator, table: c_int, key: [*:0]const u8) !?keywork.Intent {
    c.lua_getfield(lua_state, table, key);
    defer pop(lua_state, 1);
    if (c.lua_isnil(lua_state, -1)) return null;
    return try intentFromStack(lua_state, allocator, -1);
}

fn intentFromStack(lua_state: *c.lua_State, allocator: std.mem.Allocator, index: c_int) !keywork.Intent {
    return .action(try allocator.dupe(u8, try stringFromStack(lua_state, index)));
}

fn stringFromStack(lua_state: *c.lua_State, index: c_int) ![]const u8 {
    var len: usize = 0;
    const ptr = c.lua_tolstring(lua_state, index, &len) orelse return error.ExpectedLuaString;
    return ptr[0..len];
}

fn getNumberField(lua_state: *c.lua_State, table: c_int, key: [*:0]const u8, default: f32) f32 {
    c.lua_getfield(lua_state, table, key);
    defer pop(lua_state, 1);
    if (c.lua_isnumber(lua_state, -1) == 0) return default;
    return @floatCast(c.lua_tonumber(lua_state, -1));
}

fn getBooleanField(lua_state: *c.lua_State, table: c_int, key: [*:0]const u8, default: bool) bool {
    c.lua_getfield(lua_state, table, key);
    defer pop(lua_state, 1);
    if (!c.lua_isboolean(lua_state, -1)) return default;
    return c.lua_toboolean(lua_state, -1) != 0;
}

fn getOptionalCallbackField(
    lua_state: *c.lua_State,
    allocator: std.mem.Allocator,
    table: c_int,
    key: [*:0]const u8,
) !?keywork.Widget.Callback {
    c.lua_getfield(lua_state, table, key);
    defer pop(lua_state, 1);
    if (c.lua_isnil(lua_state, -1)) return null;
    return try callbackFromStack(lua_state, allocator, -1);
}

fn getOptionalFocusChangeCallbackField(
    lua_state: *c.lua_State,
    allocator: std.mem.Allocator,
    table: c_int,
    key: [*:0]const u8,
) !?keywork.Widget.FocusChangeCallback {
    c.lua_getfield(lua_state, table, key);
    defer pop(lua_state, 1);
    if (c.lua_isnil(lua_state, -1)) return null;
    return try focusChangeCallbackFromStack(lua_state, allocator, -1);
}

fn callbackFromStack(lua_state: *c.lua_State, allocator: std.mem.Allocator, index: c_int) !keywork.Widget.Callback {
    if (c.lua_type(lua_state, index) != c.LUA_TFUNCTION) return error.ExpectedLuaFunction;

    c.lua_pushvalue(lua_state, index);
    const ref = c.luaL_ref(lua_state, c.LUA_REGISTRYINDEX);
    errdefer c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, ref);
    const callback = try allocator.create(LuaCallback);
    callback.* = .{ .allocator = allocator, .lua_state = lua_state, .ref = ref };
    return callback.keyworkCallback();
}

fn focusChangeCallbackFromStack(lua_state: *c.lua_State, allocator: std.mem.Allocator, index: c_int) !keywork.Widget.FocusChangeCallback {
    if (c.lua_type(lua_state, index) != c.LUA_TFUNCTION) return error.ExpectedLuaFunction;

    c.lua_pushvalue(lua_state, index);
    const ref = c.luaL_ref(lua_state, c.LUA_REGISTRYINDEX);
    errdefer c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, ref);
    const callback = try allocator.create(LuaCallback);
    callback.* = .{ .allocator = allocator, .lua_state = lua_state, .ref = ref };
    return callback.keyworkFocusChangeCallback();
}

fn getColorField(lua_state: *c.lua_State, table: c_int, key: [*:0]const u8, default: keywork.Color) keywork.Color {
    c.lua_getfield(lua_state, table, key);
    defer pop(lua_state, 1);
    if (c.lua_isnumber(lua_state, -1) == 0) return default;
    const value = c.lua_tonumber(lua_state, -1);
    if (value < 0 or value > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return default;
    return @bitCast(@as(u32, @intFromFloat(value)));
}

fn getOptionalColorField(lua_state: *c.lua_State, table: c_int, key: [*:0]const u8) ?keywork.Color {
    c.lua_getfield(lua_state, table, key);
    defer pop(lua_state, 1);
    if (c.lua_isnumber(lua_state, -1) == 0) return null;
    const value = c.lua_tonumber(lua_state, -1);
    if (value < 0 or value > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return null;
    return @bitCast(@as(u32, @intFromFloat(value)));
}

fn pop(lua_state: *c.lua_State, count: c_int) void {
    c.lua_settop(lua_state, -count - 1);
}

test "lua stateful widget set_state rebuilds retained subtree" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\local ui = require("ui")
        \\local Counter = ui.stateful({
        \\  init = function()
        \\    return { count = 0 }
        \\  end,
        \\  build = function(self, state)
        \\    return ui.clickable("counter", ui.text(tostring(self.count)), function()
        \\      self:set_state(function(s)
        \\        s.count = s.count + 1
        \\      end)
        \\    end)
        \\  end,
        \\})
        \\return function(state)
        \\  return Counter({ key = "counter" })
        \\end
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "stateful.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "stateful.lua" });
    defer allocator.free(script_path);

    var app = try App.init(allocator, script_path);
    defer app.deinit();

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var log_backend: keywork.LogBackend = .{ .writer = &output.writer };
    var runtime = try keywork.Runtime.init(
        allocator,
        log_backend.backend(),
        .{ .max_width = 100, .max_height = 40 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();
    app.runtime = &runtime;

    try runtime.repaint();
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "value=\"0\"") != null);

    try runtime.click(.{ .x = 2, .y = 2 });
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "value=\"1\"") != null);
}
