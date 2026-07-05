//! LuaJIT-backed widget descriptions.

const std = @import("std");
const keywork = @import("libkeywork");
const lua_codec = @import("lua_codec.zig");
const c = @import("luajit_c");

const linux = std.os.linux;
const posix = std.posix;

const State = keywork.AppContext;
const BuildScope = keywork.BuildScope;

const app_registry_key = "keywork.app";
const invalid_fd: i32 = -1;

const TextOptions = struct {
    color: ?keywork.Color = null,
    size: ?f32 = null,
    font_size: ?f32 = null,
    role: ?keywork.TextRole = null,

    fn resolvedFontSize(self: TextOptions) ?f32 {
        return self.font_size orelse self.size;
    }
};

const BoxOptions = struct {
    background: keywork.Color = keywork.colors.transparent,
    border: ?keywork.Color = null,
    border_width: f32 = 1,
    radius: f32 = 0,
    min_width: f32 = 0,
    min_height: f32 = 0,
    @"align": ?keywork.Widget.Alignment = null,
    horizontal_align: ?keywork.Widget.Alignment = null,
    vertical_align: ?keywork.Widget.Alignment = null,

    fn horizontalAlign(self: BoxOptions) keywork.Widget.Alignment {
        return self.horizontal_align orelse self.@"align" orelse .start;
    }

    fn verticalAlign(self: BoxOptions) keywork.Widget.Alignment {
        return self.vertical_align orelse self.@"align" orelse .start;
    }
};

const FocusOptions = struct {
    autofocus: bool = false,
    skip_traversal: bool = false,
    can_request_focus: bool = true,
};

const FocusScopeOptions = struct {
    modal: bool = false,
};

const SizedOptions = struct {
    width: ?f32 = null,
    height: ?f32 = null,
    min_width: f32 = 0,
    min_height: f32 = 0,
    max_width: ?f32 = null,
    max_height: ?f32 = null,
};

const IconOptions = struct {
    size: ?f32 = null,
    color: ?keywork.Color = null,
};

const ParseContext = struct {
    icon: IconOptions = .{},

    fn resolveIcon(self: ParseContext, options: IconOptions) struct { size: f32, color: keywork.Color } {
        return .{
            .size = options.size orelse self.icon.size orelse 16,
            .color = options.color orelse self.icon.color orelse keywork.colors.ink,
        };
    }

    fn mergeIcon(self: ParseContext, options: IconOptions) ParseContext {
        return .{ .icon = .{
            .size = options.size orelse self.icon.size,
            .color = options.color orelse self.icon.color,
        } };
    }
};

const LinearOptions = struct {
    spacing: f32 = 0,
    @"align": ?keywork.Widget.CrossAxisAlignment = null,

    fn crossAlign(self: LinearOptions) keywork.Widget.CrossAxisAlignment {
        return self.@"align" orelse .start;
    }
};

const PaddingOptions = struct {
    all: ?f32 = null,
    x: ?f32 = null,
    y: ?f32 = null,
    left: ?f32 = null,
    right: ?f32 = null,
    top: ?f32 = null,
    bottom: ?f32 = null,
    insets: keywork.EdgeInsets = .{},
    padding: keywork.EdgeInsets = .{},

    fn resolved(self: PaddingOptions) keywork.EdgeInsets {
        if (self.all) |value| return keywork.EdgeInsets.all(value);
        var result = self.insets;
        if (self.padding.left != 0 or self.padding.right != 0 or self.padding.top != 0 or self.padding.bottom != 0) result = self.padding;
        if (self.x) |value| {
            result.left = value;
            result.right = value;
        }
        if (self.y) |value| {
            result.top = value;
            result.bottom = value;
        }
        if (self.left) |value| result.left = value;
        if (self.right) |value| result.right = value;
        if (self.top) |value| result.top = value;
        if (self.bottom) |value| result.bottom = value;
        return result;
    }
};

const SpacerOptions = struct {
    flex: f32 = 1,
};

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
    parse_context: ParseContext,

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

        c.lua_createtable(self.lua_state, 0, 0);
        const state_table = c.lua_gettop(self.lua_state);
        errdefer pop(self.lua_state, 1);
        installStateMethods(self.lua_state, self.app, state, state_table);
        setStateProps(self.lua_state, state_table, self.props_ref);

        c.lua_rawgeti(self.lua_state, c.LUA_REGISTRYINDEX, self.spec_ref);
        const spec = c.lua_gettop(self.lua_state);
        c.lua_createtable(self.lua_state, 0, 1);
        c.lua_pushvalue(self.lua_state, spec);
        c.lua_setfield(self.lua_state, -2, "__index");
        _ = c.lua_setmetatable(self.lua_state, state_table);
        c.lua_getfield(self.lua_state, spec, "init");
        if (c.lua_isnil(self.lua_state, -1)) {
            pop(self.lua_state, 1);
        } else {
            c.lua_pushvalue(self.lua_state, state_table);
            c.lua_rawgeti(self.lua_state, c.LUA_REGISTRYINDEX, self.props_ref);
            if (c.lua_pcall(self.lua_state, 2, 0, 0) != 0) return failLuaCall(self.lua_state, "stateful init failed");
        }
        pop(self.lua_state, 1);

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
        return try parseWidget(self.lua_state, scope.allocator, scope.allocator, context.app_context, self.parse_context, -1);
    }

    fn destroyState(ptr: *const anyopaque, state_ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *const LuaStatefulWidget = @ptrCast(@alignCast(ptr));
        const state: *LuaStatefulState = @ptrCast(@alignCast(state_ptr));

        c.lua_rawgeti(self.lua_state, c.LUA_REGISTRYINDEX, self.spec_ref);
        const spec = c.lua_gettop(self.lua_state);
        c.lua_getfield(self.lua_state, spec, "dispose");
        if (c.lua_isnil(self.lua_state, -1)) {
            pop(self.lua_state, 2);
        } else {
            c.lua_rawgeti(self.lua_state, c.LUA_REGISTRYINDEX, state.state_ref);
            if (c.lua_pcall(self.lua_state, 1, 0, 0) != 0) {
                failLuaCall(self.lua_state, "stateful dispose failed") catch {};
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
            .parse_context = self.parse_context,
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
    script_ref: c_int = -1,
    script_dirty: bool = true,
    fd_watches: std.ArrayList(*FdWatch) = .empty,
    timers: std.ArrayList(*LuaTimer) = .empty,
    processes: std.ArrayList(*LuaProcess) = .empty,
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
        for (self.timers.items) |timer| timer.destroy(self.allocator, self.state);
        self.timers.deinit(self.allocator);
        for (self.processes.items) |process| process.destroy(self.allocator, self.state);
        self.processes.deinit(self.allocator);
        if (self.script_ref >= 0) c.luaL_unref(self.state, c.LUA_REGISTRYINDEX, self.script_ref);
        c.lua_close(self.state);
        self.allocator.free(self.path);
    }

    pub fn installEventSources(ctx: ?*anyopaque, loop: *keywork.event_loop.EventLoop, runtime: *keywork.Runtime) !void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        self.event_loop = loop;
        self.runtime = runtime;
        loop.addFileWatch(self.path, self, scriptChanged) catch |err| {
            if (err != error.FileWatchNotFound) std.log.scoped(.keywork_luajit).warn("{s} watch not installed: {}", .{ self.path, err });
        };
        for (self.fd_watches.items) |watch| try self.registerFdWatch(watch);
        for (self.timers.items) |timer| try self.registerTimer(timer);
        for (self.processes.items) |process| try self.registerProcess(process);
    }

    pub fn host(self: *App) keywork.AppHost {
        return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidgetHost } };
    }

    pub fn buildWidget(self: *App, allocator: std.mem.Allocator, runtime_state: State) !keywork.Widget {
        if (self.script_dirty or self.script_ref < 0) try self.reloadScript();

        c.lua_settop(self.state, 0);
        c.lua_rawgeti(self.state, c.LUA_REGISTRYINDEX, self.script_ref);
        const widget = try parseWidget(self.state, allocator, allocator, runtime_state, .{}, -1);
        c.lua_settop(self.state, 0);
        _ = c.lua_gc(self.state, c.LUA_GCCOLLECT, 0);
        return widget;
    }

    fn reloadScript(self: *App) !void {
        c.lua_settop(self.state, 0);
        installKeyworkModule(self.state, self);
        if (c.luaL_loadfile(self.state, self.path.ptr) != 0) return self.failWithLuaError(error.ScriptLoadFailed);
        if (c.lua_pcall(self.state, 0, 1, 0) != 0) return self.failWithLuaError(error.ScriptRunFailed);
        errdefer c.lua_settop(self.state, 0);

        if (c.lua_type(self.state, -1) != c.LUA_TTABLE or !isWidgetTable(self.state, c.lua_gettop(self.state))) return error.ScriptReturnedInvalidValue;
        const script_ref = c.luaL_ref(self.state, c.LUA_REGISTRYINDEX);
        if (self.script_ref >= 0) c.luaL_unref(self.state, c.LUA_REGISTRYINDEX, self.script_ref);
        self.script_ref = script_ref;
        self.script_dirty = false;
        _ = c.lua_gc(self.state, c.LUA_GCCOLLECT, 0);
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

    fn addFdWatch(self: *App, fd: i32, events: u32, ref: c_int) !*FdWatch {
        const watch = try self.allocator.create(FdWatch);
        errdefer self.allocator.destroy(watch);
        watch.* = .{ .app = self, .fd = fd, .events = events, .ref = ref };
        errdefer c.luaL_unref(self.state, c.LUA_REGISTRYINDEX, ref);

        try self.fd_watches.append(self.allocator, watch);
        errdefer _ = self.fd_watches.pop();
        try self.registerFdWatch(watch);
        return watch;
    }

    fn registerFdWatch(self: *App, watch: *FdWatch) !void {
        if (watch.registered or watch.canceled) return;
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

    fn addTimerWithDelay(self: *App, delay_ms: u64, interval_ms: u64, ref: c_int) !*LuaTimer {
        const timer = try self.allocator.create(LuaTimer);
        errdefer self.allocator.destroy(timer);
        timer.* = .{ .app = self, .delay_ms = delay_ms, .interval_ms = interval_ms, .ref = ref };
        errdefer c.luaL_unref(self.state, c.LUA_REGISTRYINDEX, ref);

        try self.timers.append(self.allocator, timer);
        errdefer _ = self.timers.pop();
        try self.registerTimer(timer);
        return timer;
    }

    fn registerTimer(self: *App, timer: *LuaTimer) !void {
        if (timer.registered or timer.canceled) return;
        const loop = self.event_loop orelse return;
        const event_timer = try loop.addTimer(timer, luaTimerCallback);
        errdefer event_timer.disarm();
        try event_timer.arm(timer.delay_ms, timer.interval_ms);
        timer.timer = event_timer;
        timer.registered = true;
    }

    fn addProcess(self: *App, spec: SpawnSpec, callbacks: ProcessCallbacks) !*LuaProcess {
        var spawned = try LuaProcess.spawn(self, spec, callbacks);
        var moved = false;
        errdefer if (!moved) spawned.cleanup(self.state);

        const process = try self.allocator.create(LuaProcess);
        process.* = spawned;
        moved = true;
        errdefer process.deinit(self.allocator, self.state);

        process.stdout_pipe.process = process;
        process.stderr_pipe.process = process;

        try self.processes.append(self.allocator, process);
        errdefer _ = self.processes.pop();
        try self.registerProcess(process);
        return process;
    }

    fn registerProcess(self: *App, process: *LuaProcess) !void {
        if (process.registered or process.canceled or process.exited) return;
        const loop = self.event_loop orelse return;
        if (process.stdout_pipe.fd != invalid_fd) try loop.addFd(.{
            .fd = process.stdout_pipe.fd,
            .events = linux.EPOLL.IN | linux.EPOLL.HUP | linux.EPOLL.ERR,
            .ctx = &process.stdout_pipe,
            .callback = processPipeCallback,
        });
        if (process.stderr_pipe.fd != invalid_fd) try loop.addFd(.{
            .fd = process.stderr_pipe.fd,
            .events = linux.EPOLL.IN | linux.EPOLL.HUP | linux.EPOLL.ERR,
            .ctx = &process.stderr_pipe,
            .callback = processPipeCallback,
        });
        try loop.addFd(.{
            .fd = process.pidfd,
            .events = linux.EPOLL.IN | linux.EPOLL.HUP | linux.EPOLL.ERR,
            .ctx = process,
            .callback = processExitCallback,
        });
        process.registered = true;
        if (process.stdout_pipe.fd != invalid_fd) try drainProcessPipe(&process.stdout_pipe);
        if (process.stderr_pipe.fd != invalid_fd) try drainProcessPipe(&process.stderr_pipe);
    }

    fn removeProcess(self: *App, process: *LuaProcess) void {
        for (self.processes.items, 0..) |item, index| {
            if (item == process) {
                _ = self.processes.swapRemove(index);
                return;
            }
        }
    }
};

fn scriptChanged(ctx: *anyopaque, _: *keywork.event_loop.EventLoop, path: []const u8, mask: u32, _: ?[]const u8) !void {
    const app: *App = @ptrCast(@alignCast(ctx));
    std.log.scoped(.keywork_luajit).info("reload requested for {s} mask=0x{x}", .{ path, mask });
    app.script_dirty = true;
    const runtime = app.runtime orelse return;
    try runtime.invalidate();
}

const FdWatch = struct {
    app: *App,
    fd: i32,
    events: u32,
    ref: c_int,
    registered: bool = false,
    canceled: bool = false,

    fn cancel(self: *FdWatch, lua_state: *c.lua_State) void {
        if (self.canceled) return;
        self.canceled = true;
        if (self.registered) {
            if (self.app.event_loop) |loop| loop.removeFd(self.fd);
            self.registered = false;
        }
        if (self.ref >= 0) {
            c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, self.ref);
            self.ref = -1;
        }
    }

    fn destroy(self: *FdWatch, allocator: std.mem.Allocator, lua_state: *c.lua_State) void {
        if (self.ref >= 0) c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, self.ref);
        allocator.destroy(self);
    }
};

const LuaTimer = struct {
    app: *App,
    delay_ms: u64,
    interval_ms: u64,
    ref: c_int,
    timer: ?*keywork.event_loop.EventLoop.Timer = null,
    registered: bool = false,
    canceled: bool = false,

    fn cancel(self: *LuaTimer, lua_state: *c.lua_State) void {
        if (self.canceled) return;
        self.canceled = true;
        if (self.timer) |timer| timer.disarm();
        if (self.ref >= 0) {
            c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, self.ref);
            self.ref = -1;
        }
    }

    fn destroy(self: *LuaTimer, allocator: std.mem.Allocator, lua_state: *c.lua_State) void {
        if (self.ref >= 0) c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, self.ref);
        allocator.destroy(self);
    }
};

const SpawnSpec = struct {
    argv: []const []const u8,
    stdout_pipe: bool,
    stderr_pipe: bool,
};

const ProcessCallbacks = struct {
    stdout_ref: c_int = -1,
    stderr_ref: c_int = -1,
    exit_ref: c_int = -1,

    fn unref(self: *ProcessCallbacks, lua_state: *c.lua_State) void {
        if (self.stdout_ref >= 0) {
            c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, self.stdout_ref);
            self.stdout_ref = -1;
        }
        if (self.stderr_ref >= 0) {
            c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, self.stderr_ref);
            self.stderr_ref = -1;
        }
        if (self.exit_ref >= 0) {
            c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, self.exit_ref);
            self.exit_ref = -1;
        }
    }
};

const ProcessPipeKind = enum {
    stdout,
    stderr,
};

const ProcessPipe = struct {
    process: *LuaProcess = undefined,
    kind: ProcessPipeKind,
    fd: i32 = invalid_fd,

    fn callbackRef(self: *ProcessPipe) c_int {
        return switch (self.kind) {
            .stdout => self.process.stdout_ref,
            .stderr => self.process.stderr_ref,
        };
    }
};

const LuaProcess = struct {
    app: *App,
    pid: linux.pid_t,
    pidfd: i32,
    stdout_pipe: ProcessPipe = .{ .kind = .stdout },
    stderr_pipe: ProcessPipe = .{ .kind = .stderr },
    stdout_ref: c_int = -1,
    stderr_ref: c_int = -1,
    exit_ref: c_int = -1,
    handle_ref: c_int = -1,
    registered: bool = false,
    canceled: bool = false,
    exited: bool = false,

    fn spawn(app: *App, spec: SpawnSpec, callbacks: ProcessCallbacks) !LuaProcess {
        var stdout_pipe: ?[2]i32 = null;
        var stderr_pipe: ?[2]i32 = null;
        if (spec.stdout_pipe) stdout_pipe = try createPipe();
        errdefer if (stdout_pipe) |pipe| closePipe(pipe);
        if (spec.stderr_pipe) stderr_pipe = try createPipe();
        errdefer if (stderr_pipe) |pipe| closePipe(pipe);

        var argv = try prepareArgv(app.allocator, spec.argv);
        defer argv.deinit(app.allocator);
        const executable = try resolveExecutable(app.allocator, spec.argv[0]);
        defer app.allocator.free(executable);

        const fork_result = linux.fork();
        switch (linux.errno(fork_result)) {
            .SUCCESS => {},
            .AGAIN, .NOMEM => return error.SystemResources,
            else => return error.ForkFailed,
        }

        if (fork_result == 0) {
            if (stdout_pipe) |pipe| {
                _ = linux.close(pipe[0]);
                dupTo(pipe[1], posix.STDOUT_FILENO) catch linux.exit(127);
            }
            if (stderr_pipe) |pipe| {
                _ = linux.close(pipe[0]);
                dupTo(pipe[1], posix.STDERR_FILENO) catch linux.exit(127);
            }
            _ = linux.execve(executable.ptr, argv.ptr, std.c.environ);
            linux.exit(127);
        }

        const pid: linux.pid_t = @intCast(fork_result);
        errdefer _ = linux.kill(pid, .TERM);
        var result: LuaProcess = .{
            .app = app,
            .pid = pid,
            .pidfd = try linuxFd(linux.pidfd_open(pid, 0)),
            .stdout_ref = callbacks.stdout_ref,
            .stderr_ref = callbacks.stderr_ref,
            .exit_ref = callbacks.exit_ref,
        };
        errdefer {
            if (result.pidfd != invalid_fd) _ = linux.close(result.pidfd);
        }

        if (stdout_pipe) |pipe| {
            _ = linux.close(pipe[1]);
            result.stdout_pipe.fd = pipe[0];
            errdefer {
                if (result.stdout_pipe.fd != invalid_fd) _ = linux.close(result.stdout_pipe.fd);
            }
            try setNonblocking(result.stdout_pipe.fd);
        }
        if (stderr_pipe) |pipe| {
            _ = linux.close(pipe[1]);
            result.stderr_pipe.fd = pipe[0];
            errdefer {
                if (result.stderr_pipe.fd != invalid_fd) _ = linux.close(result.stderr_pipe.fd);
            }
            try setNonblocking(result.stderr_pipe.fd);
        }
        return result;
    }

    fn cancel(self: *LuaProcess, lua_state: *c.lua_State) void {
        if (self.canceled or self.exited) return;
        self.canceled = true;
        _ = linux.kill(self.pid, .TERM);
        self.closeOutputFds();
        self.clearRefs(lua_state);
    }

    fn complete(self: *LuaProcess, lua_state: *c.lua_State, status: u32) !void {
        if (self.exited) return;
        self.exited = true;
        try drainProcessPipe(&self.stdout_pipe);
        try drainProcessPipe(&self.stderr_pipe);

        if (!self.canceled and self.exit_ref >= 0) {
            c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, self.exit_ref);
            pushProcessResult(lua_state, status);
            if (c.lua_pcall(lua_state, 1, 0, 0) != 0) {
                failLuaCall(lua_state, "process exit callback failed") catch {};
                return error.LuaCallbackFailed;
            }
        }
    }

    fn closeFds(self: *LuaProcess) void {
        if (self.app.event_loop) |loop| {
            if (self.stdout_pipe.fd != invalid_fd) loop.removeFd(self.stdout_pipe.fd);
            if (self.stderr_pipe.fd != invalid_fd) loop.removeFd(self.stderr_pipe.fd);
            if (self.pidfd != invalid_fd) loop.removeFd(self.pidfd);
        }
        self.closeOutputFds();
        if (self.pidfd != invalid_fd) {
            _ = linux.close(self.pidfd);
            self.pidfd = invalid_fd;
        }
    }

    fn closeOutputFds(self: *LuaProcess) void {
        if (self.app.event_loop) |loop| {
            if (self.stdout_pipe.fd != invalid_fd) loop.removeFd(self.stdout_pipe.fd);
            if (self.stderr_pipe.fd != invalid_fd) loop.removeFd(self.stderr_pipe.fd);
        }
        if (self.stdout_pipe.fd != invalid_fd) {
            _ = linux.close(self.stdout_pipe.fd);
            self.stdout_pipe.fd = invalid_fd;
        }
        if (self.stderr_pipe.fd != invalid_fd) {
            _ = linux.close(self.stderr_pipe.fd);
            self.stderr_pipe.fd = invalid_fd;
        }
    }

    fn clearRefs(self: *LuaProcess, lua_state: *c.lua_State) void {
        if (self.stdout_ref >= 0) {
            c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, self.stdout_ref);
            self.stdout_ref = -1;
        }
        if (self.stderr_ref >= 0) {
            c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, self.stderr_ref);
            self.stderr_ref = -1;
        }
        if (self.exit_ref >= 0) {
            c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, self.exit_ref);
            self.exit_ref = -1;
        }
        if (self.handle_ref >= 0) {
            c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, self.handle_ref);
            c.lua_pushcclosure(lua_state, luaNoop, 0);
            c.lua_setfield(lua_state, -2, "cancel");
            pop(lua_state, 1);
            c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, self.handle_ref);
            self.handle_ref = -1;
        }
    }

    fn deinit(self: *LuaProcess, allocator: std.mem.Allocator, lua_state: *c.lua_State) void {
        self.cleanup(lua_state);
        allocator.destroy(self);
    }

    fn cleanup(self: *LuaProcess, lua_state: *c.lua_State) void {
        if (!self.exited and !self.canceled) {
            _ = linux.kill(self.pid, .TERM);
            var status: u32 = 0;
            _ = linux.waitpid(self.pid, &status, linux.W.NOHANG);
        }
        self.closeFds();
        self.clearRefs(lua_state);
    }

    fn destroy(self: *LuaProcess, allocator: std.mem.Allocator, lua_state: *c.lua_State) void {
        self.cancel(lua_state);
        if (!self.exited) {
            var status: u32 = 0;
            _ = linux.waitpid(self.pid, &status, linux.W.NOHANG);
        }
        self.deinit(allocator, lua_state);
    }
};

fn fdWatchCallback(ctx: *anyopaque, _: *keywork.event_loop.EventLoop, events: u32) !void {
    const watch: *FdWatch = @ptrCast(@alignCast(ctx));
    if (watch.canceled or watch.ref < 0) return;
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

fn luaTimerCallback(ctx: *anyopaque, _: *keywork.event_loop.EventLoop, expirations: u64) !void {
    const timer: *LuaTimer = @ptrCast(@alignCast(ctx));
    if (timer.canceled or timer.ref < 0 or expirations == 0) return;
    const app = timer.app;
    c.lua_rawgeti(app.state, c.LUA_REGISTRYINDEX, timer.ref);
    c.lua_pushinteger(app.state, @intCast(expirations));
    if (c.lua_pcall(app.state, 1, 0, 0) != 0) {
        var len: usize = 0;
        const message_ptr = c.lua_tolstring(app.state, -1, &len);
        if (message_ptr) |message| std.log.scoped(.keywork_luajit).warn("timer callback failed: {s}", .{message[0..len]});
        pop(app.state, 1);
        return error.LuaCallbackFailed;
    }
    if (timer.interval_ms == 0) timer.cancel(app.state);
}

fn processPipeCallback(ctx: *anyopaque, _: *keywork.event_loop.EventLoop, _: u32) !void {
    const pipe: *ProcessPipe = @ptrCast(@alignCast(ctx));
    try drainProcessPipe(pipe);
}

fn processExitCallback(ctx: *anyopaque, _: *keywork.event_loop.EventLoop, _: u32) !void {
    const process: *LuaProcess = @ptrCast(@alignCast(ctx));
    if (process.exited) return;
    var status: u32 = 0;
    const result = linux.waitpid(process.pid, &status, linux.W.NOHANG);
    switch (linux.errno(result)) {
        .SUCCESS => {},
        .CHILD => {
            process.closeFds();
            process.clearRefs(process.app.state);
            process.app.removeProcess(process);
            process.app.allocator.destroy(process);
            return;
        },
        else => return error.WaitPidFailed,
    }
    if (result == 0) return;

    const app = process.app;
    process.complete(app.state, status) catch |err| {
        process.closeFds();
        process.clearRefs(app.state);
        app.removeProcess(process);
        app.allocator.destroy(process);
        return err;
    };
    process.closeFds();
    process.clearRefs(app.state);
    app.removeProcess(process);
    app.allocator.destroy(process);
}

fn drainProcessPipe(pipe: *ProcessPipe) !void {
    if (pipe.fd == invalid_fd) return;
    var buffer: [4096]u8 = undefined;
    while (true) {
        const result = linux.read(pipe.fd, &buffer, buffer.len);
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0) {
                    closeProcessPipe(pipe);
                    return;
                }
                try callProcessChunk(pipe, buffer[0..result]);
            },
            .AGAIN => return,
            else => {
                closeProcessPipe(pipe);
                return;
            },
        }
    }
}

fn callProcessChunk(pipe: *ProcessPipe, chunk: []const u8) !void {
    const ref = pipe.callbackRef();
    if (ref < 0 or pipe.process.canceled) return;
    const lua_state = pipe.process.app.state;
    c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, ref);
    c.lua_pushlstring(lua_state, chunk.ptr, chunk.len);
    if (c.lua_pcall(lua_state, 1, 0, 0) != 0) {
        failLuaCall(lua_state, "process output callback failed") catch {};
        return error.LuaCallbackFailed;
    }
}

fn closeProcessPipe(pipe: *ProcessPipe) void {
    if (pipe.fd == invalid_fd) return;
    if (pipe.process.app.event_loop) |loop| loop.removeFd(pipe.fd);
    _ = linux.close(pipe.fd);
    pipe.fd = invalid_fd;
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

    c.lua_createtable(lua_state, 0, 3);
    const loop_table = c.lua_gettop(lua_state);
    c.lua_pushlightuserdata(lua_state, app);
    c.lua_pushcclosure(lua_state, luaLoopTimer, 1);
    c.lua_setfield(lua_state, loop_table, "timer");
    c.lua_pushlightuserdata(lua_state, app);
    c.lua_pushcclosure(lua_state, luaWatchFd, 1);
    c.lua_setfield(lua_state, loop_table, "fd");
    c.lua_pushlightuserdata(lua_state, app);
    c.lua_pushcclosure(lua_state, luaSpawn, 1);
    c.lua_setfield(lua_state, loop_table, "spawn");
    c.lua_setfield(lua_state, table, "loop");

    c.lua_pushlightuserdata(lua_state, app);
    c.lua_pushcclosure(lua_state, luaInvalidate, 1);
    c.lua_setfield(lua_state, table, "invalidate");
    return 1;
}

fn luaLoopTimer(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const app: *App = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    c.luaL_checktype(lua_state, 1, c.LUA_TTABLE);
    c.luaL_checktype(lua_state, 2, c.LUA_TFUNCTION);
    const interval = optionalSecondsField(lua_state, 1, "interval");
    const delay = optionalSecondsField(lua_state, 1, "delay") orelse interval;
    const delay_seconds = delay orelse return c.luaL_error(lua_state, "timer requires delay or interval");
    const delay_ms = secondsToMilliseconds(delay_seconds) catch return c.luaL_error(lua_state, "invalid timer delay");
    const interval_ms = if (interval) |seconds| secondsToMilliseconds(seconds) catch return c.luaL_error(lua_state, "invalid timer interval") else 0;

    c.lua_pushvalue(lua_state, 2);
    const ref = c.luaL_ref(lua_state, c.LUA_REGISTRYINDEX);
    const timer = app.addTimerWithDelay(delay_ms, interval_ms, ref) catch |err| {
        c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, ref);
        std.log.scoped(.keywork_luajit).warn("timer failed: {}", .{err});
        return c.luaL_error(lua_state, "timer failed");
    };
    pushTimerHandle(lua_state, timer);
    return 1;
}

fn luaWatchFd(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const app: *App = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
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
    const watch = app.addFdWatch(@intCast(fd_int), events, ref) catch |err| {
        c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, ref);
        std.log.scoped(.keywork_luajit).warn("loop.fd failed: {}", .{err});
        return c.luaL_error(lua_state, "loop.fd failed");
    };
    pushFdWatchHandle(lua_state, watch);
    return 1;
}

fn pushTimerHandle(lua_state: *c.lua_State, timer: *LuaTimer) void {
    c.lua_createtable(lua_state, 0, 1);
    c.lua_pushlightuserdata(lua_state, timer);
    c.lua_pushcclosure(lua_state, luaCancelTimer, 1);
    c.lua_setfield(lua_state, -2, "cancel");
}

fn pushFdWatchHandle(lua_state: *c.lua_State, watch: *FdWatch) void {
    c.lua_createtable(lua_state, 0, 1);
    c.lua_pushlightuserdata(lua_state, watch);
    c.lua_pushcclosure(lua_state, luaCancelFdWatch, 1);
    c.lua_setfield(lua_state, -2, "cancel");
}

fn pushProcessHandle(lua_state: *c.lua_State, process: *LuaProcess) void {
    c.lua_createtable(lua_state, 0, 1);
    c.lua_pushlightuserdata(lua_state, process);
    c.lua_pushcclosure(lua_state, luaCancelProcess, 1);
    c.lua_setfield(lua_state, -2, "cancel");
    c.lua_pushvalue(lua_state, -1);
    process.handle_ref = c.luaL_ref(lua_state, c.LUA_REGISTRYINDEX);
}

fn luaCancelTimer(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const timer: *LuaTimer = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    timer.cancel(lua_state);
    return 0;
}

fn luaCancelFdWatch(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const watch: *FdWatch = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    watch.cancel(lua_state);
    return 0;
}

fn luaCancelProcess(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const process: *LuaProcess = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    process.cancel(lua_state);
    return 0;
}

fn luaNoop(_: ?*c.lua_State) callconv(.c) c_int {
    return 0;
}

fn luaSpawn(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const app: *App = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    c.luaL_checktype(lua_state, 1, c.LUA_TTABLE);
    c.luaL_checktype(lua_state, 2, c.LUA_TTABLE);

    const argv = parseArgv(lua_state, app.allocator, 1) catch |err| {
        std.log.scoped(.keywork_luajit).warn("spawn argv failed: {}", .{err});
        return c.luaL_error(lua_state, "invalid spawn argv");
    };
    defer freeArgv(app.allocator, argv);

    var callbacks: ProcessCallbacks = .{};
    errdefer callbacks.unref(lua_state);
    callbacks.stdout_ref = tableFunctionRef(lua_state, 2, "stdout") catch -1;
    callbacks.stderr_ref = tableFunctionRef(lua_state, 2, "stderr") catch -1;
    callbacks.exit_ref = tableFunctionRef(lua_state, 2, "exit") catch -1;

    const spec: SpawnSpec = .{
        .argv = argv,
        .stdout_pipe = std.mem.eql(u8, stringField(lua_state, 1, "stdout") catch "ignore", "pipe"),
        .stderr_pipe = std.mem.eql(u8, stringField(lua_state, 1, "stderr") catch "ignore", "pipe"),
    };
    const process = app.addProcess(spec, callbacks) catch |err| {
        std.log.scoped(.keywork_luajit).warn("loop.spawn failed: {}", .{err});
        return c.luaL_error(lua_state, "loop.spawn failed");
    };
    callbacks = .{};
    pushProcessHandle(lua_state, process);
    return 1;
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
    c.lua_createtable(lua_state, 0, 4);
    const table = c.lua_gettop(lua_state);
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
    parse_context: ParseContext,
    index: c_int,
) !keywork.Widget {
    const table = absoluteIndex(lua_state, index);
    try expectType(lua_state, table, c.LUA_TTABLE);

    const kind = try getStringField(lua_state, table, "type");
    defer pop(lua_state, 1);

    if (std.mem.eql(u8, kind, "text")) {
        const value = try dupeStringField(lua_state, allocator, table, "value");
        const options = try lua_codec.decode(TextOptions, lua_state, table, allocator);
        return .{ .text = .{ .value = value, .color = options.color, .font_size = options.resolvedFontSize(), .role = options.role orelse .body } };
    }
    if (std.mem.eql(u8, kind, "keyed")) {
        const key = try dupeStringField(lua_state, allocator, table, "key");
        const child = try allocator.create(keywork.Widget);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parseWidget(lua_state, allocator, callback_allocator, runtime_state, parse_context, -1);
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
            .parse_context = parse_context,
        };
        return stateful.widget();
    }
    if (std.mem.eql(u8, kind, "theme")) {
        const child = try allocator.create(keywork.Widget);
        errdefer allocator.destroy(child);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parseWidget(lua_state, allocator, callback_allocator, runtime_state, parse_context, -1);
        return .{ .theme = .{ .theme = parseThemeField(lua_state, table, "theme"), .child = child } };
    }
    if (std.mem.eql(u8, kind, "default_text_style")) {
        const options = try lua_codec.decode(TextOptions, lua_state, table, allocator);
        const child = try allocator.create(keywork.Widget);
        errdefer allocator.destroy(child);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parseWidget(lua_state, allocator, callback_allocator, runtime_state, parse_context, -1);
        return .{ .default_text_style = .{ .style = .{ .color = options.color, .font_size = options.resolvedFontSize() }, .child = child } };
    }
    if (std.mem.eql(u8, kind, "icon_theme")) {
        const options = try lua_codec.decode(IconOptions, lua_state, table, allocator);
        const child = try allocator.create(keywork.Widget);
        errdefer allocator.destroy(child);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parseWidget(lua_state, allocator, callback_allocator, runtime_state, parse_context.mergeIcon(options), -1);
        const result = child.*;
        allocator.destroy(child);
        return result;
    }
    if (std.mem.eql(u8, kind, "box")) {
        const options = try lua_codec.decode(BoxOptions, lua_state, table, allocator);
        const child = try allocator.create(keywork.Widget);
        errdefer allocator.destroy(child);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parseWidget(lua_state, allocator, callback_allocator, runtime_state, parse_context, -1);
        return .{ .box = .{
            .child = child,
            .background = options.background,
            .border = options.border,
            .border_width = options.border_width,
            .radius = options.radius,
            .min_width = options.min_width,
            .min_height = options.min_height,
            .horizontal_align = options.horizontalAlign(),
            .vertical_align = options.verticalAlign(),
        } };
    }
    if (std.mem.eql(u8, kind, "clickable")) {
        const id = try dupeStringField(lua_state, allocator, table, "id");
        errdefer allocator.free(id);
        const child = try allocator.create(keywork.Widget);
        errdefer allocator.destroy(child);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parseWidget(lua_state, allocator, callback_allocator, runtime_state, parse_context, -1);
        const on_click = try getOptionalCallbackField(lua_state, callback_allocator, table, "on_click");
        return .{ .clickable = .{ .id = id, .child = child, .on_click = on_click, .activation = getActivationField(lua_state, table) } };
    }
    if (std.mem.eql(u8, kind, "gesture")) {
        const id = try dupeStringField(lua_state, allocator, table, "id");
        errdefer allocator.free(id);
        const child = try allocator.create(keywork.Widget);
        errdefer allocator.destroy(child);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parseWidget(lua_state, allocator, callback_allocator, runtime_state, parse_context, -1);
        return .{ .clickable = .{
            .id = id,
            .child = child,
            .on_click = try getOptionalCallbackField(lua_state, callback_allocator, table, "on_tap"),
            .on_tap_down = try getOptionalCallbackField(lua_state, callback_allocator, table, "on_tap_down"),
            .on_tap_up = try getOptionalCallbackField(lua_state, callback_allocator, table, "on_tap_up"),
            .on_tap_cancel = try getOptionalCallbackField(lua_state, callback_allocator, table, "on_tap_cancel"),
        } };
    }
    if (std.mem.eql(u8, kind, "focus")) {
        const options = try lua_codec.decode(FocusOptions, lua_state, table, allocator);
        const id = try dupeStringField(lua_state, allocator, table, "id");
        errdefer allocator.free(id);
        const child = try allocator.create(keywork.Widget);
        errdefer allocator.destroy(child);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parseWidget(lua_state, allocator, callback_allocator, runtime_state, parse_context, -1);
        const on_focus_change = try getOptionalFocusChangeCallbackField(lua_state, callback_allocator, table, "on_focus_change");
        return .{ .focus = .{
            .node = .named(id),
            .child = child,
            .autofocus = options.autofocus,
            .skip_traversal = options.skip_traversal,
            .can_request_focus = options.can_request_focus,
            .on_focus_change = on_focus_change,
        } };
    }
    if (std.mem.eql(u8, kind, "focus_scope")) {
        const options = try lua_codec.decode(FocusScopeOptions, lua_state, table, allocator);
        const id = try dupeStringField(lua_state, allocator, table, "id");
        errdefer allocator.free(id);
        const child = try allocator.create(keywork.Widget);
        errdefer allocator.destroy(child);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parseWidget(lua_state, allocator, callback_allocator, runtime_state, parse_context, -1);
        return .{ .focus_scope = .{ .id = id, .child = child, .modal = options.modal } };
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
        const options = try lua_codec.decode(SpacerOptions, lua_state, table, allocator);
        return keywork.widgets.spacer(options.flex);
    }
    if (std.mem.eql(u8, kind, "sized")) {
        const options = try lua_codec.decode(SizedOptions, lua_state, table, allocator);
        const child = try allocator.create(keywork.Widget);
        errdefer allocator.destroy(child);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parseWidget(lua_state, allocator, callback_allocator, runtime_state, parse_context, -1);
        return .{ .sized = .{
            .child = child,
            .width = options.width,
            .height = options.height,
            .min_width = options.min_width,
            .min_height = options.min_height,
            .max_width = options.max_width,
            .max_height = options.max_height,
        } };
    }
    if (std.mem.eql(u8, kind, "svg_icon")) {
        const options = try lua_codec.decode(IconOptions, lua_state, table, allocator);
        const icon = parse_context.resolveIcon(options);
        const path = try stringField(lua_state, table, "path");
        return keywork.svg_icon.icon(
            allocator,
            path,
            icon.size,
            icon.color,
        );
    }
    if (std.mem.eql(u8, kind, "icon")) {
        const options = try lua_codec.decode(IconOptions, lua_state, table, allocator);
        const icon = parse_context.resolveIcon(options);
        const name = try stringField(lua_state, table, "name");
        const path = try keywork.icon_theme.lookupSvgIconSized(allocator, name, icon.size) orelse return missingIconWidget(allocator, name, icon.color);
        defer allocator.free(path);
        return keywork.svg_icon.icon(
            allocator,
            path,
            icon.size,
            icon.color,
        );
    }
    if (std.mem.eql(u8, kind, "row")) {
        const options = try lua_codec.decode(LinearOptions, lua_state, table, allocator);
        const children = try parseChildren(lua_state, allocator, callback_allocator, runtime_state, parse_context, table);
        return .{ .row = .{ .children = children, .gap = options.spacing, .cross_align = options.crossAlign() } };
    }
    if (std.mem.eql(u8, kind, "column")) {
        const options = try lua_codec.decode(LinearOptions, lua_state, table, allocator);
        const children = try parseChildren(lua_state, allocator, callback_allocator, runtime_state, parse_context, table);
        return .{ .column = .{ .children = children, .gap = options.spacing, .cross_align = options.crossAlign() } };
    }
    if (std.mem.eql(u8, kind, "padding")) {
        const options = try lua_codec.decode(PaddingOptions, lua_state, table, allocator);
        const child = try allocator.create(keywork.Widget);
        errdefer allocator.destroy(child);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parseWidget(lua_state, allocator, callback_allocator, runtime_state, parse_context, -1);
        return .{ .padding = .{ .insets = options.resolved(), .child = child } };
    }
    if (std.mem.eql(u8, kind, "center")) {
        const child = try allocator.create(keywork.Widget);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parseWidget(lua_state, allocator, callback_allocator, runtime_state, parse_context, -1);
        return .{ .center = .{ .child = child } };
    }
    if (std.mem.eql(u8, kind, "actions")) {
        const child = try allocator.create(keywork.Widget);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parseWidget(lua_state, allocator, callback_allocator, runtime_state, parse_context, -1);
        const bindings = try parseActionBindings(lua_state, allocator, callback_allocator, table);
        return .{ .actions = .{ .bindings = bindings, .child = child } };
    }
    if (std.mem.eql(u8, kind, "shortcuts")) {
        const child = try allocator.create(keywork.Widget);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parseWidget(lua_state, allocator, callback_allocator, runtime_state, parse_context, -1);
        const bindings = try parseShortcutBindings(lua_state, allocator, table);
        return .{ .shortcuts = .{ .bindings = bindings, .child = child } };
    }

    return error.UnknownWidgetType;
}

fn isWidgetTable(lua_state: *c.lua_State, table: c_int) bool {
    c.lua_getfield(lua_state, table, "type");
    defer pop(lua_state, 1);
    return !c.lua_isnil(lua_state, -1);
}

fn missingIconWidget(allocator: std.mem.Allocator, name: []const u8, color: keywork.Color) !keywork.Widget {
    std.log.scoped(.keywork_luajit).warn("missing icon {s}", .{name});
    return .{ .text = .{ .value = try allocator.dupe(u8, "□"), .color = color } };
}

fn parseChildren(
    lua_state: *c.lua_State,
    allocator: std.mem.Allocator,
    callback_allocator: std.mem.Allocator,
    runtime_state: State,
    parse_context: ParseContext,
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
        child.* = try parseWidget(lua_state, allocator, callback_allocator, runtime_state, parse_context, -1);
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

fn dupeStringFromStack(lua_state: *c.lua_State, allocator: std.mem.Allocator, index: c_int) ![]const u8 {
    const value = try stringFromStack(lua_state, index);
    return try allocator.dupe(u8, value);
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

fn secondsToMilliseconds(seconds: f64) !u64 {
    if (!std.math.isFinite(seconds) or seconds <= 0) return error.InvalidTimerInterval;
    const milliseconds = @ceil(seconds * std.time.ms_per_s);
    if (milliseconds > @as(f64, @floatFromInt(std.math.maxInt(u64)))) return error.InvalidTimerInterval;
    return @intFromFloat(milliseconds);
}

fn tableFunctionRef(lua_state: *c.lua_State, table: c_int, key: [*:0]const u8) !c_int {
    c.lua_getfield(lua_state, table, key);
    if (c.lua_isnil(lua_state, -1)) {
        pop(lua_state, 1);
        return -1;
    }
    if (c.lua_type(lua_state, -1) != c.LUA_TFUNCTION) {
        pop(lua_state, 1);
        return error.ExpectedLuaFunction;
    }
    return c.luaL_ref(lua_state, c.LUA_REGISTRYINDEX);
}

fn parseArgv(lua_state: *c.lua_State, allocator: std.mem.Allocator, table: c_int) ![]const []const u8 {
    c.lua_getfield(lua_state, table, "argv");
    defer pop(lua_state, 1);
    const argv_table = absoluteIndex(lua_state, -1);
    try expectType(lua_state, argv_table, c.LUA_TTABLE);
    const count: usize = @intCast(c.lua_objlen(lua_state, argv_table));
    if (count == 0) return error.EmptyArgv;
    const argv = try allocator.alloc([]const u8, count);
    errdefer freeArgv(allocator, argv);
    for (argv, 0..) |*arg, index| {
        c.lua_rawgeti(lua_state, argv_table, @intCast(index + 1));
        defer pop(lua_state, 1);
        arg.* = try dupeStringFromStack(lua_state, allocator, -1);
    }
    return argv;
}

fn freeArgv(allocator: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |arg| allocator.free(arg);
    allocator.free(argv);
}

const PreparedArgv = struct {
    ptr: [*:null]?[*:0]const u8,
    values: []?[*:0]const u8,
    strings: [][:0]u8,

    fn deinit(self: *PreparedArgv, allocator: std.mem.Allocator) void {
        for (self.strings) |value| allocator.free(value);
        allocator.free(self.strings);
        allocator.free(self.values);
    }
};

fn prepareArgv(allocator: std.mem.Allocator, argv: []const []const u8) !PreparedArgv {
    const values = try allocator.allocSentinel(?[*:0]const u8, argv.len, null);
    errdefer allocator.free(values);
    const strings = try allocator.alloc([:0]u8, argv.len);
    errdefer allocator.free(strings);
    var initialized: usize = 0;
    errdefer for (strings[0..initialized]) |value| allocator.free(value);
    for (argv, 0..) |arg, index| {
        strings[index] = try allocator.dupeZ(u8, arg);
        initialized += 1;
        values[index] = strings[index].ptr;
    }
    return .{ .ptr = values.ptr, .values = values, .strings = strings };
}

fn resolveExecutable(allocator: std.mem.Allocator, name: []const u8) ![:0]u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) return allocator.dupeZ(u8, name);
    const path = getenv("PATH") orelse "/usr/local/bin:/usr/bin:/bin";
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        const resolved = try std.fs.path.joinZ(allocator, &.{ if (dir.len == 0) "." else dir, name });
        errdefer allocator.free(resolved);
        if (isExecutable(resolved)) return resolved;
        allocator.free(resolved);
    }
    return error.FileNotFound;
}

fn getenv(name: []const u8) ?[]const u8 {
    var index: usize = 0;
    while (std.c.environ[index]) |entry_z| : (index += 1) {
        const entry = std.mem.span(entry_z);
        if (entry.len > name.len and entry[name.len] == '=' and std.mem.eql(u8, entry[0..name.len], name)) return entry[name.len + 1 ..];
    }
    return null;
}

fn isExecutable(path: [:0]const u8) bool {
    return linux.errno(linux.access(path.ptr, linux.X_OK)) == .SUCCESS;
}

fn createPipe() ![2]i32 {
    var fds: [2]i32 = undefined;
    try linuxVoid(linux.pipe2(&fds, .{ .CLOEXEC = true }));
    return fds;
}

fn closePipe(pipe: [2]i32) void {
    _ = linux.close(pipe[0]);
    _ = linux.close(pipe[1]);
}

fn dupTo(old: i32, new: i32) !void {
    _ = try linuxFd(linux.dup2(old, new));
}

fn setNonblocking(fd: i32) !void {
    const flags = try linuxFd(linux.fcntl(fd, linux.F.GETFL, 0));
    try linuxVoid(linux.fcntl(fd, linux.F.SETFL, @as(usize, @intCast(flags)) | linux.SOCK.NONBLOCK));
}

fn pushProcessResult(lua_state: *c.lua_State, status: u32) void {
    c.lua_createtable(lua_state, 0, 3);
    const table = c.lua_gettop(lua_state);
    if (linux.W.IFEXITED(status)) {
        c.lua_pushinteger(lua_state, linux.W.EXITSTATUS(status));
        c.lua_setfield(lua_state, table, "code");
    } else if (linux.W.IFSIGNALED(status)) {
        c.lua_pushinteger(lua_state, @intFromEnum(linux.W.TERMSIG(status)));
        c.lua_setfield(lua_state, table, "signal");
    }
    c.lua_pushboolean(lua_state, if (linux.W.IFEXITED(status) and linux.W.EXITSTATUS(status) == 0) 1 else 0);
    c.lua_setfield(lua_state, table, "ok");
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

fn parseThemeField(lua_state: *c.lua_State, table: c_int, key: [*:0]const u8) keywork.Theme {
    c.lua_getfield(lua_state, table, key);
    defer pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return .default;
    const theme_table = c.lua_gettop(lua_state);

    var theme = keywork.Theme.fromColorScheme(stringField(lua_state, theme_table, "color_scheme") catch "light");
    theme.color_scheme = parseColorScheme(lua_state, theme_table, theme.color_scheme);
    theme.text_theme = parseTextTheme(lua_state, theme_table, theme.text_theme);
    theme.button_theme = parseButtonTheme(lua_state, theme_table, theme.button_theme);
    theme.input_theme = parseInputTheme(lua_state, theme_table, theme.input_theme);
    return theme;
}

fn parseColorScheme(lua_state: *c.lua_State, theme_table: c_int, base: keywork.ColorScheme) keywork.ColorScheme {
    c.lua_getfield(lua_state, theme_table, "colors");
    defer pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return base;
    const colors_table = c.lua_gettop(lua_state);
    return .{
        .brightness = base.brightness,
        .primary = getColorField(lua_state, colors_table, "primary", base.primary),
        .on_primary = getColorField(lua_state, colors_table, "on_primary", base.on_primary),
        .surface = getColorField(lua_state, colors_table, "surface", base.surface),
        .on_surface = getColorField(lua_state, colors_table, "on_surface", base.on_surface),
        .surface_variant = getColorField(lua_state, colors_table, "surface_variant", base.surface_variant),
        .on_surface_variant = getColorField(lua_state, colors_table, "on_surface_variant", base.on_surface_variant),
        .outline = getColorField(lua_state, colors_table, "outline", base.outline),
        .error_color = getColorField(lua_state, colors_table, "error", base.error_color),
        .on_error = getColorField(lua_state, colors_table, "on_error", base.on_error),
    };
}

fn parseTextTheme(lua_state: *c.lua_State, theme_table: c_int, base: keywork.TextTheme) keywork.TextTheme {
    c.lua_getfield(lua_state, theme_table, "text");
    defer pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return base;
    const text_table = c.lua_gettop(lua_state);
    var result = base;
    result.body = parseTextStyleField(lua_state, text_table, "body", result.body);
    result.label = parseTextStyleField(lua_state, text_table, "label", result.label);
    result.title = parseTextStyleField(lua_state, text_table, "title", result.title);
    return result;
}

fn parseTextStyleField(lua_state: *c.lua_State, table: c_int, key: [*:0]const u8, base: keywork.TextStyle) keywork.TextStyle {
    c.lua_getfield(lua_state, table, key);
    defer pop(lua_state, 1);
    if (c.lua_isnil(lua_state, -1)) return base;
    if (c.lua_isnumber(lua_state, -1) != 0) {
        var result = base;
        result.color = colorFromStack(lua_state, -1) catch result.color;
        return result;
    }
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return base;

    const options = lua_codec.decode(TextOptions, lua_state, -1, std.heap.page_allocator) catch return base;
    return .{
        .color = options.color orelse base.color,
        .font_size = options.resolvedFontSize() orelse base.font_size,
    };
}

fn parseButtonTheme(lua_state: *c.lua_State, theme_table: c_int, base: keywork.ButtonTheme) keywork.ButtonTheme {
    c.lua_getfield(lua_state, theme_table, "button");
    defer pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return base;
    const button_table = c.lua_gettop(lua_state);
    var result = base;
    result.background = getOptionalColorField(lua_state, button_table, "background") orelse result.background;
    result.foreground = getOptionalColorField(lua_state, button_table, "foreground") orelse result.foreground;
    result.hover_background = getOptionalColorField(lua_state, button_table, "hover_background") orelse result.hover_background;
    result.hover_foreground = getOptionalColorField(lua_state, button_table, "hover_foreground") orelse result.hover_foreground;
    result.focused_border = getOptionalColorField(lua_state, button_table, "focused_border") orelse result.focused_border;
    result.pressed_background = getOptionalColorField(lua_state, button_table, "pressed_background") orelse result.pressed_background;
    result.disabled_background = getOptionalColorField(lua_state, button_table, "disabled_background") orelse result.disabled_background;
    result.disabled_foreground = getOptionalColorField(lua_state, button_table, "disabled_foreground") orelse result.disabled_foreground;
    result.padding = getNumberField(lua_state, button_table, "padding", result.padding);
    return result;
}

fn parseInputTheme(lua_state: *c.lua_State, theme_table: c_int, base: keywork.InputTheme) keywork.InputTheme {
    c.lua_getfield(lua_state, theme_table, "input");
    defer pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return base;
    const input_table = c.lua_gettop(lua_state);
    var result = base;
    result.background = getOptionalColorField(lua_state, input_table, "background") orelse result.background;
    result.foreground = getOptionalColorField(lua_state, input_table, "foreground") orelse result.foreground;
    result.placeholder = getOptionalColorField(lua_state, input_table, "placeholder") orelse result.placeholder;
    result.border = getOptionalColorField(lua_state, input_table, "border") orelse result.border;
    result.focused_border = getOptionalColorField(lua_state, input_table, "focused_border") orelse result.focused_border;
    return result;
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
    return colorFromStack(lua_state, -1) catch default;
}

fn getOptionalColorField(lua_state: *c.lua_State, table: c_int, key: [*:0]const u8) ?keywork.Color {
    c.lua_getfield(lua_state, table, key);
    defer pop(lua_state, 1);
    return colorFromStack(lua_state, -1) catch null;
}

fn colorFromStack(lua_state: *c.lua_State, index: c_int) !keywork.Color {
    if (c.lua_isnumber(lua_state, index) == 0) return error.ExpectedLuaNumber;
    const value = c.lua_tonumber(lua_state, index);
    if (value < 0 or value > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return error.InvalidLuaColor;
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
        \\  init = function(self)
        \\    self.count = 0
        \\  end,
        \\  build = function(self, state)
        \\    return ui.clickable("counter", ui.text(tostring(self.count)), function()
        \\      self:set_state(function(s)
        \\        s.count = s.count + 1
        \\      end)
        \\    end)
        \\  end,
        \\})
        \\local App = ui.stateful({
        \\  build = function(self, state)
        \\    return Counter({ key = "counter" })
        \\  end,
        \\})
        \\return App({ key = "app" })
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

test "lua stateful widget dispose runs when removed" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\local ui = require("ui")
        \\disposed = false
        \\local Child = ui.stateful({
        \\  dispose = function(self)
        \\    disposed = true
        \\  end,
        \\  build = function(self, state)
        \\    return ui.clickable("remove", ui.text("remove"), self.props.on_remove)
        \\  end,
        \\})
        \\local App = ui.stateful({
        \\  init = function(self)
        \\    self.show = true
        \\  end,
        \\  build = function(self, state)
        \\    if self.show then
        \\      return Child({ key = "child", on_remove = function()
        \\        self:set_state(function(s)
        \\          s.show = false
        \\        end)
        \\      end })
        \\    end
        \\    return ui.text("gone")
        \\  end,
        \\})
        \\return App({ key = "app" })
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "dispose.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "dispose.lua" });
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
    try runtime.click(.{ .x = 2, .y = 2 });
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "value=\"gone\"") != null);

    c.lua_getglobal(app.state, "disposed");
    defer pop(app.state, 1);
    try std.testing.expect(c.lua_toboolean(app.state, -1) != 0);
}

test "lua stateful build context includes theme" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\local ui = require("ui")
        \\local App = ui.stateful({
        \\  build = function(self, context)
        \\    return ui.theme(context.theme, ui.label(context.theme.color_scheme))
        \\  end,
        \\})
        \\return App({ key = "app" })
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "theme-context.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "theme-context.lua" });
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
        .dark,
    );
    defer runtime.deinit();

    try runtime.repaint();
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "value=\"dark\"") != null);
}

test "lua loop spawn captures stdout and exit" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\local ui = require("ui")
        \\local keywork = require("keywork")
        \\spawn_done = false
        \\spawn_output = ""
        \\local App = ui.stateful({
        \\  init = function(self)
        \\    self.proc = keywork.loop.spawn({
        \\      argv = { "/usr/bin/printf", "hello" },
        \\      stdout = "pipe",
        \\      stderr = "ignore",
        \\    }, {
        \\      stdout = function(chunk)
        \\        spawn_output = spawn_output .. chunk
        \\      end,
        \\      exit = function(result)
        \\        spawn_done = result.ok and result.code == 0
        \\      end,
        \\    })
        \\  end,
        \\  dispose = function(self)
        \\    if self.proc then
        \\      self.proc:cancel()
        \\    end
        \\  end,
        \\  build = function(self, state)
        \\    return ui.text("spawn")
        \\  end,
        \\})
        \\return App({ key = "app" })
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "spawn.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "spawn.lua" });
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

    try runtime.repaint();

    const SpawnTest = struct {
        app: *App,
        ticks: usize = 0,

        fn callback(ctx: *anyopaque, loop: *keywork.event_loop.EventLoop, _: u64) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.ticks += 1;
            c.lua_getglobal(self.app.state, "spawn_done");
            const done = c.lua_toboolean(self.app.state, -1) != 0;
            pop(self.app.state, 1);
            if (done or self.ticks > 1000) loop.quit();
        }
    };

    var loop = try keywork.event_loop.EventLoop.init(allocator);
    defer loop.deinit();
    try App.installEventSources(&app, &loop, &runtime);
    var context: SpawnTest = .{ .app = &app };
    try loop.addRepeatingTimer(1, &context, SpawnTest.callback);
    try loop.run();

    c.lua_getglobal(app.state, "spawn_done");
    defer pop(app.state, 1);
    try std.testing.expect(c.lua_toboolean(app.state, -1) != 0);
    c.lua_getglobal(app.state, "spawn_output");
    defer pop(app.state, 1);
    const value = try stringFromStack(app.state, -1);
    try std.testing.expectEqualStrings("hello", value);
}
