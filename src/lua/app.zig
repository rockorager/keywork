//! LuaJIT application host and native Keywork bindings.

const std = @import("std");
const app_windows = @import("../app/windows.zig");
const keywork = @import("../ui.zig");
const log_backend_mod = @import("../backend/log.zig");
const event_loop = @import("../linux/event_loop.zig");
const icon_theme = @import("../linux/icon_theme.zig");
const lua_config = @import("config.zig");
const lua_process = @import("process.zig");
const lua_dbus = @import("dbus.zig");
const lua_json = @import("json.zig");
const lua_loop = @import("loop.zig");
const lua_socket = @import("socket.zig");
const lua_value = @import("value.zig");
const lua_widget = @import("widget.zig");
const runtime_mod = @import("../ui/runtime.zig");
const c = @import("luajit_c");

const linux = std.os.linux;
const State = keywork.AppContext;
const BuildScope = keywork.BuildScope;

const invalid_fd: i32 = -1;
const LuaProcess = lua_process.LuaProcess;
const LuaSocket = lua_socket.LuaSocket;
const DbusBus = lua_dbus.Bus;
const FdWatch = lua_loop.FdWatch;
const FsEvent = lua_loop.FsEvent;
const LuaTimer = lua_loop.LuaTimer;
const pop = lua_value.pop;
const stringFromStack = lua_value.stringFromStack;

pub const WindowConfig = lua_config.Config;

pub const App = struct {
    allocator: std.mem.Allocator,
    path: [:0]u8,
    /// Chunk name passed to the Lua loader ("@" ++ path) so stack
    /// traces point at the script file.
    chunk_name: [:0]u8,
    window_config: WindowConfig = .{},
    state: *c.lua_State,
    script_ref: c_int = -1,
    start_ref: c_int = -1,
    stop_ref: c_int = -1,
    script_dirty: bool = true,
    lifecycle_started: bool = false,
    quit_requested: bool = false,
    fd_watches: std.ArrayList(*FdWatch) = .empty,
    fs_events: std.ArrayList(*FsEvent) = .empty,
    timers: std.ArrayList(*LuaTimer) = .empty,
    processes: std.ArrayList(*LuaProcess) = .empty,
    sockets: std.ArrayList(*LuaSocket) = .empty,
    dbus_buses: std.ArrayList(*DbusBus) = .empty,
    dbus_host: lua_dbus.Host = undefined,
    loop_host: lua_loop.Host = undefined,
    socket_host: lua_socket.Host = undefined,
    event_loop: ?*event_loop.EventLoop = null,
    invalidator: ?runtime_mod.Invalidator = null,
    /// Registry refs of the child widget tables from the last window-set
    /// build, keyed by window id (keys owned by `allocator`).
    window_children: std.StringHashMapUnmanaged(c_int) = .empty,
    script_watch: ?*event_loop.EventLoop.FileWatch = null,
    icon_cache: icon_theme.Cache,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !App {
        const path_z = try allocator.dupeZ(u8, path);
        errdefer allocator.free(path_z);
        const chunk_name = try std.fmt.allocPrintSentinel(allocator, "@{s}", .{path}, 0);
        errdefer allocator.free(chunk_name);

        switch (linux.errno(linux.access(path_z.ptr, 0))) {
            .SUCCESS => {},
            .NOENT => return error.ScriptNotFound,
            else => return error.ScriptAccessFailed,
        }

        const lua_state = c.luaL_newstate() orelse return error.OutOfMemory;
        errdefer c.lua_close(lua_state);
        c.luaL_openlibs(lua_state);

        return .{
            .allocator = allocator,
            .path = path_z,
            .chunk_name = chunk_name,
            .state = lua_state,
            .icon_cache = .init(allocator),
        };
    }

    pub fn deinit(self: *App) void {
        self.stopLifecycleLog();
        for (self.fd_watches.items) |watch| watch.destroy(self.allocator, self.state);
        self.fd_watches.deinit(self.allocator);
        for (self.fs_events.items) |fs_event| fs_event.destroy(self.allocator, self.state);
        self.fs_events.deinit(self.allocator);
        for (self.timers.items) |timer| timer.destroy(self.allocator, self.state);
        self.timers.deinit(self.allocator);
        for (self.processes.items) |process| process.destroy(self.allocator, self.state);
        self.processes.deinit(self.allocator);
        for (self.sockets.items) |socket| socket.destroy(self.allocator, self.state);
        self.sockets.deinit(self.allocator);
        for (self.dbus_buses.items) |bus| bus.destroy(self.allocator, self.state);
        self.dbus_buses.deinit(self.allocator);
        self.releaseWindowChildren(&self.window_children);
        if (self.script_ref >= 0) c.luaL_unref(self.state, c.LUA_REGISTRYINDEX, self.script_ref);
        if (self.start_ref >= 0) c.luaL_unref(self.state, c.LUA_REGISTRYINDEX, self.start_ref);
        if (self.stop_ref >= 0) c.luaL_unref(self.state, c.LUA_REGISTRYINDEX, self.stop_ref);
        c.lua_close(self.state);
        self.icon_cache.deinit();
        self.window_config.deinit(self.allocator);
        self.allocator.free(self.path);
        self.allocator.free(self.chunk_name);
    }

    pub fn bindEventLoop(self: *App, loop: *event_loop.EventLoop) !void {
        std.debug.assert(self.event_loop == null);
        self.event_loop = loop;
        errdefer self.unbindEventLoop();

        self.script_watch = loop.addFileWatch(self.path, self, scriptChanged) catch |err| blk: {
            if (err != error.FileWatchNotFound) std.log.scoped(.keywork_luajit).warn("{s} watch not installed: {}", .{ self.path, err });
            break :blk null;
        };
        for (self.fd_watches.items) |watch| try watch.register();
        // A watched path may have vanished since the fs_event was created;
        // cancel just that watch instead of failing the whole bind.
        for (self.fs_events.items) |fs_event| fs_event.register() catch |err| {
            std.log.scoped(.keywork_luajit).warn("{s} watch not installed: {}", .{ fs_event.path, err });
            fs_event.cancel(self.state, .silent);
        };
        for (self.timers.items) |timer| try timer.register();
        for (self.processes.items) |process| try self.registerProcess(process);
        for (self.sockets.items) |socket| try socket.register();
        for (self.dbus_buses.items) |bus| try bus.register();
        if (self.invalidator != null) try self.startLifecycle();
        if (self.quit_requested) {
            self.quit_requested = false;
            loop.quit();
        }
    }

    pub fn bindRuntime(self: *App, runtime: *runtime_mod.Runtime) void {
        self.invalidator = .fromRuntime(runtime);
    }

    pub fn bindInvalidator(self: *App, invalidator: runtime_mod.Invalidator) void {
        self.invalidator = invalidator;
    }

    pub fn unbindRuntime(self: *App) void {
        self.stopLifecycleLog();
        self.invalidator = null;
    }

    pub fn unbindEventLoop(self: *App) void {
        const loop = self.event_loop orelse return;
        self.stopLifecycleLog();
        if (self.script_watch) |watch| loop.removeFileWatch(watch);
        self.script_watch = null;
        for (self.fd_watches.items) |watch| watch.unregister(loop);
        for (self.fs_events.items) |fs_event| fs_event.unregister(loop);
        for (self.timers.items) |timer| timer.unregister(loop);
        for (self.processes.items) |process| process.unregister(loop);
        for (self.sockets.items) |socket| socket.unregister(loop);
        for (self.dbus_buses.items) |bus| bus.unregister();
        self.event_loop = null;
    }

    pub fn host(self: *App) keywork.AppHost {
        return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidgetHost } };
    }

    /// Run the script if it has not executed yet (or is dirty). Called
    /// before app/runner.zig starts the backend so the returned app root can
    /// shape the window, and again on every rebuild.
    pub fn ensureLoaded(self: *App) !void {
        if (self.script_dirty or self.script_ref < 0) try self.reloadScript();
    }

    pub fn hasLiveAsyncResources(self: *const App) bool {
        for (self.fd_watches.items) |watch| if (!watch.canceled) return true;
        for (self.fs_events.items) |fs_event| if (!fs_event.canceled) return true;
        for (self.timers.items) |timer| if (!timer.canceled and !timer.expired) return true;
        for (self.processes.items) |process| if (!process.canceled and !process.exited) return true;
        for (self.sockets.items) |socket| if (!socket.canceled and socket.fd != invalid_fd) return true;
        for (self.dbus_buses.items) |bus| if (!bus.closed) return true;
        return false;
    }

    pub fn buildWidget(self: *App, allocator: std.mem.Allocator, runtime_state: State, render_scale: f32) !keywork.Widget {
        try self.ensureLoaded();

        const icon_scale: f32 = if (std.math.isFinite(render_scale) and render_scale > 0) render_scale else 1;

        c.lua_settop(self.state, 0);
        c.lua_rawgeti(self.state, c.LUA_REGISTRYINDEX, self.script_ref);
        c.lua_getfield(self.state, -1, "child");
        const widget = try lua_widget.parse(self.widgetHost(), self.state, allocator, allocator, runtime_state, .{
            .icon_cache = &self.icon_cache,
            .icon_scale = icon_scale,
        }, -1);
        c.lua_settop(self.state, 0);
        // A bounded incremental step keeps garbage from widget-table churn
        // paced across builds; a full collection here would stall every
        // rebuild for time proportional to the entire Lua heap. Full
        // collections still happen on script reload.
        _ = c.lua_gc(self.state, c.LUA_GCSTEP, 200);
        return widget;
    }

    pub fn windowsHost(self: *App) app_windows.WindowsHost {
        return .{ .ptr = self, .vtable = &windows_host_vtable };
    }

    const windows_host_vtable: app_windows.WindowsHost.VTable = .{
        .build_windows = hostBuildWindows,
        .build_window_widget = hostBuildWindowWidget,
    };

    fn hostBuildWindows(ptr: *anyopaque, allocator: std.mem.Allocator, context: app_windows.WindowsContext) anyerror![]app_windows.WindowDeclaration {
        const self: *App = @ptrCast(@alignCast(ptr));
        return self.buildWindowDecls(allocator, context);
    }

    fn hostBuildWindowWidget(ptr: *anyopaque, id: []const u8, scope: *BuildScope, context: keywork.AppContext) anyerror!keywork.Widget {
        const self: *App = @ptrCast(@alignCast(ptr));
        return self.buildWindowWidget(id, scope, context);
    }

    /// Runs the script's windows function (or synthesizes a single main
    /// window from the app child) and captures each window's child table
    /// so per-window runtimes can build it later. Captures are staged and
    /// swapped in only on success, so a failing build leaves the previous
    /// window set's widget refs intact for live windows.
    pub fn buildWindowDecls(self: *App, allocator: std.mem.Allocator, context: app_windows.WindowsContext) ![]app_windows.WindowDeclaration {
        try self.ensureLoaded();
        var staged: std.StringHashMapUnmanaged(c_int) = .empty;
        errdefer self.releaseWindowChildren(&staged);

        c.lua_settop(self.state, 0);
        defer c.lua_settop(self.state, 0);
        c.lua_rawgeti(self.state, c.LUA_REGISTRYINDEX, self.script_ref);
        const script = c.lua_gettop(self.state);

        c.lua_getfield(self.state, script, "windows");
        if (c.lua_isnil(self.state, -1)) {
            // Single-window sugar: kw.app{ child = ... } declares one
            // window inheriting all app-level options.
            pop(self.state, 1);
            c.lua_getfield(self.state, script, "child");
            if (c.lua_isnil(self.state, -1)) return error.AppChildMissing;
            try self.captureWindowChild(&staged, "main");
            const decls = try allocator.alloc(app_windows.WindowDeclaration, 1);
            decls[0] = .{ .id = "main" };
            self.commitWindowChildren(&staged);
            return decls;
        }

        pushWindowsContext(self.state, context);
        if (c.lua_pcall(self.state, 1, 1, 0) != 0) return self.failWithLuaError(error.LuaCallbackFailed);
        if (c.lua_type(self.state, -1) != c.LUA_TTABLE) return error.WindowsListInvalid;
        const list = c.lua_gettop(self.state);

        const count: usize = @intCast(c.lua_objlen(self.state, list));
        var decls: std.ArrayList(app_windows.WindowDeclaration) = .empty;
        errdefer decls.deinit(allocator);
        var index: usize = 1;
        while (index <= count) : (index += 1) {
            c.lua_rawgeti(self.state, list, @intCast(index));
            defer pop(self.state, 1);
            const decl = try self.parseWindowDecl(allocator, &staged, c.lua_gettop(self.state));
            try decls.append(allocator, decl);
        }
        self.commitWindowChildren(&staged);
        return decls.toOwnedSlice(allocator);
    }

    fn parseWindowDecl(self: *App, allocator: std.mem.Allocator, staged: *std.StringHashMapUnmanaged(c_int), table: c_int) !app_windows.WindowDeclaration {
        if (c.lua_type(self.state, table) != c.LUA_TTABLE) return error.WindowDeclInvalid;

        c.lua_getfield(self.state, table, "id");
        if (c.lua_type(self.state, -1) != c.LUA_TSTRING) {
            pop(self.state, 1);
            return error.WindowIdMissing;
        }
        const id = try allocator.dupe(u8, stringFromStack(self.state, -1) catch unreachable);
        pop(self.state, 1);

        var decl: app_windows.WindowDeclaration = .{ .id = id };

        c.lua_getfield(self.state, table, "title");
        if (c.lua_type(self.state, -1) == c.LUA_TSTRING) {
            decl.title = try allocator.dupeZ(u8, stringFromStack(self.state, -1) catch unreachable);
        }
        pop(self.state, 1);

        c.lua_getfield(self.state, table, "width");
        if (c.lua_isnumber(self.state, -1) != 0) decl.width = @floatCast(c.lua_tonumber(self.state, -1));
        pop(self.state, 1);
        c.lua_getfield(self.state, table, "height");
        if (c.lua_isnumber(self.state, -1) != 0) decl.height = @floatCast(c.lua_tonumber(self.state, -1));
        pop(self.state, 1);

        c.lua_getfield(self.state, table, "output");
        if (c.lua_type(self.state, -1) == c.LUA_TSTRING) {
            decl.output = try allocator.dupe(u8, stringFromStack(self.state, -1) catch unreachable);
        }
        pop(self.state, 1);

        c.lua_getfield(self.state, table, "layer_shell");
        if (c.lua_type(self.state, -1) == c.LUA_TTABLE) {
            decl.layer_shell = try lua_config.parseLayerShellTable(self.state, c.lua_gettop(self.state));
        }
        pop(self.state, 1);

        c.lua_getfield(self.state, table, "child");
        if (c.lua_isnil(self.state, -1)) return error.WindowChildMissing;
        try self.captureWindowChild(staged, id);
        return decl;
    }

    /// Takes the value on top of the stack as `id`'s child table and
    /// stores a registry ref to it in `staged`. Pops the value.
    fn captureWindowChild(self: *App, staged: *std.StringHashMapUnmanaged(c_int), id: []const u8) !void {
        if (staged.contains(id)) {
            pop(self.state, 1);
            return error.DuplicateWindowId;
        }
        const ref = c.luaL_ref(self.state, c.LUA_REGISTRYINDEX);
        errdefer c.luaL_unref(self.state, c.LUA_REGISTRYINDEX, ref);
        const key = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(key);
        try staged.putNoClobber(self.allocator, key, ref);
    }

    /// Replaces the live window-child refs with the staged set.
    fn commitWindowChildren(self: *App, staged: *std.StringHashMapUnmanaged(c_int)) void {
        self.releaseWindowChildren(&self.window_children);
        self.window_children = staged.*;
        staged.* = .empty;
    }

    fn pushWindowsContext(lua_state: *c.lua_State, context: app_windows.WindowsContext) void {
        c.lua_createtable(lua_state, 0, 2);
        const table = c.lua_gettop(lua_state);
        c.lua_createtable(lua_state, @intCast(context.outputs.len), 0);
        const outputs = c.lua_gettop(lua_state);
        for (context.outputs, 1..) |output, index| {
            c.lua_createtable(lua_state, 0, 4);
            c.lua_pushlstring(lua_state, output.name.ptr, output.name.len);
            c.lua_setfield(lua_state, -2, "name");
            c.lua_pushnumber(lua_state, output.width);
            c.lua_setfield(lua_state, -2, "width");
            c.lua_pushnumber(lua_state, output.height);
            c.lua_setfield(lua_state, -2, "height");
            c.lua_pushnumber(lua_state, output.scale);
            c.lua_setfield(lua_state, -2, "scale");
            c.lua_rawseti(lua_state, outputs, @intCast(index));
        }
        c.lua_setfield(lua_state, table, "outputs");
        c.lua_pushlstring(lua_state, context.color_scheme.ptr, context.color_scheme.len);
        c.lua_setfield(lua_state, table, "color_scheme");
    }

    fn releaseWindowChildren(self: *App, map: *std.StringHashMapUnmanaged(c_int)) void {
        var it = map.iterator();
        while (it.next()) |entry| {
            c.luaL_unref(self.state, c.LUA_REGISTRYINDEX, entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        map.deinit(self.allocator);
        map.* = .empty;
    }

    pub fn buildWindowWidget(self: *App, id: []const u8, scope: *BuildScope, context: keywork.AppContext) !keywork.Widget {
        const ref = self.window_children.get(id) orelse return error.UnknownWindow;
        const icon_scale: f32 = if (std.math.isFinite(scope.render_scale) and scope.render_scale > 0) scope.render_scale else 1;

        c.lua_settop(self.state, 0);
        defer c.lua_settop(self.state, 0);
        c.lua_rawgeti(self.state, c.LUA_REGISTRYINDEX, ref);
        const widget = try lua_widget.parse(self.widgetHost(), self.state, scope.allocator, scope.allocator, context, .{
            .icon_cache = &self.icon_cache,
            .icon_scale = icon_scale,
        }, -1);
        _ = c.lua_gc(self.state, c.LUA_GCSTEP, 200);
        return widget;
    }

    fn reloadScript(self: *App) !void {
        self.stopLifecycleLog();
        self.cancelScriptResources();
        c.lua_settop(self.state, 0);
        installKeyworkModule(self.state, self);
        const source = try self.readScriptFile();
        defer self.allocator.free(source);
        const chunk = scriptChunk(source);
        if (c.luaL_loadbuffer(self.state, chunk.ptr, chunk.len, self.chunk_name.ptr) != 0) return self.failWithLuaError(error.ScriptLoadFailed);
        if (c.lua_pcall(self.state, 0, 1, 0) != 0) return self.failWithLuaError(error.ScriptRunFailed);
        errdefer c.lua_settop(self.state, 0);

        if (c.lua_type(self.state, -1) != c.LUA_TTABLE) return error.ScriptReturnedInvalidValue;
        const app_root = c.lua_gettop(self.state);
        var config = try lua_config.parseRoot(self.state, self.allocator, app_root);
        var committed = false;
        errdefer if (!committed) config.deinit(self.allocator);
        const script_ref = c.luaL_ref(self.state, c.LUA_REGISTRYINDEX);
        errdefer if (!committed) c.luaL_unref(self.state, c.LUA_REGISTRYINDEX, script_ref);
        const start_ref = try tableFunctionRef(self.state, script_ref, "start");
        errdefer if (!committed and start_ref >= 0) c.luaL_unref(self.state, c.LUA_REGISTRYINDEX, start_ref);
        const stop_ref = try tableFunctionRef(self.state, script_ref, "stop");
        errdefer if (!committed and stop_ref >= 0) c.luaL_unref(self.state, c.LUA_REGISTRYINDEX, stop_ref);

        if (self.script_ref >= 0) c.luaL_unref(self.state, c.LUA_REGISTRYINDEX, self.script_ref);
        if (self.start_ref >= 0) c.luaL_unref(self.state, c.LUA_REGISTRYINDEX, self.start_ref);
        if (self.stop_ref >= 0) c.luaL_unref(self.state, c.LUA_REGISTRYINDEX, self.stop_ref);
        self.window_config.deinit(self.allocator);
        self.window_config = config;
        self.script_ref = script_ref;
        self.start_ref = start_ref;
        self.stop_ref = stop_ref;
        self.script_dirty = false;
        committed = true;
        _ = c.lua_gc(self.state, c.LUA_GCCOLLECT, 0);
        if (self.event_loop != null and self.invalidator != null) try self.startLifecycle();
    }

    fn tableFunctionRef(lua_state: *c.lua_State, table_ref: c_int, key: [*:0]const u8) !c_int {
        c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, table_ref);
        c.lua_getfield(lua_state, -1, key);
        c.lua_remove(lua_state, -2);
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

    fn startLifecycle(self: *App) !void {
        if (self.lifecycle_started) return;
        if (self.start_ref >= 0) {
            c.lua_rawgeti(self.state, c.LUA_REGISTRYINDEX, self.start_ref);
            if (c.lua_pcall(self.state, 0, 0, 0) != 0) return self.failWithLuaError(error.LuaCallbackFailed);
        }
        self.lifecycle_started = true;
    }

    fn stopLifecycleLog(self: *App) void {
        if (!self.lifecycle_started) return;
        self.lifecycle_started = false;
        if (self.stop_ref >= 0) {
            c.lua_rawgeti(self.state, c.LUA_REGISTRYINDEX, self.stop_ref);
            if (c.lua_pcall(self.state, 0, 0, 0) != 0) self.failWithLuaError(error.LuaCallbackFailed) catch {};
        }
    }

    fn cancelScriptResources(self: *App) void {
        for (self.fd_watches.items) |watch| watch.cancel(self.state, .silent);
        for (self.fs_events.items) |fs_event| fs_event.cancel(self.state, .silent);
        for (self.timers.items) |timer| timer.cancel(self.state, .silent);
        for (self.processes.items) |process| process.cancel(self.state, .silent);
        for (self.sockets.items) |socket| socket.cancel(self.state, .silent);
        for (self.dbus_buses.items) |bus| bus.close();
    }

    fn readScriptFile(self: *App) ![]u8 {
        const open_result = linux.openat(linux.AT.FDCWD, self.path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (linux.errno(open_result) != .SUCCESS) return error.ScriptReadFailed;
        const fd: i32 = @intCast(open_result);
        defer _ = linux.close(fd);

        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(self.allocator);
        while (true) {
            try list.ensureUnusedCapacity(self.allocator, 4096);
            const dest = list.unusedCapacitySlice();
            const read_result = linux.read(fd, dest.ptr, dest.len);
            switch (linux.errno(read_result)) {
                .SUCCESS => {},
                .INTR => continue,
                else => return error.ScriptReadFailed,
            }
            if (read_result == 0) break;
            list.items.len += read_result;
        }
        return list.toOwnedSlice(self.allocator);
    }

    /// Expose the standard Lua `arg` table: arg[0] is the script path,
    /// arg[1..] are the arguments forwarded to the application.
    pub fn setScriptArgs(self: *App, args: []const [:0]const u8) void {
        c.lua_createtable(self.state, @intCast(args.len), 1);
        const table = c.lua_gettop(self.state);
        c.lua_pushlstring(self.state, self.path.ptr, self.path.len);
        c.lua_rawseti(self.state, table, 0);
        for (args, 1..) |arg, index| {
            c.lua_pushlstring(self.state, arg.ptr, arg.len);
            c.lua_rawseti(self.state, table, @intCast(index));
        }
        c.lua_setfield(self.state, c.LUA_GLOBALSINDEX, "arg");
    }

    fn buildWidgetHost(ptr: *anyopaque, scope: *BuildScope, runtime_state: State) !keywork.Widget {
        const self: *App = @ptrCast(@alignCast(ptr));
        return self.buildWidget(scope.allocator, runtime_state, scope.render_scale);
    }

    fn widgetHost(self: *App) lua_widget.Host {
        return .{ .ptr = self, .invalidate_state_fn = invalidateWidgetState };
    }

    fn invalidateWidgetState(ptr: *anyopaque) !void {
        const self: *App = @ptrCast(@alignCast(ptr));
        const invalidator = self.invalidator orelse return;
        try invalidator.invalidateState();
    }

    fn failWithLuaError(self: *App, err: anyerror) anyerror {
        var len: usize = 0;
        const message_ptr = c.lua_tolstring(self.state, -1, &len);
        if (message_ptr) |ptr| {
            std.log.scoped(.keywork_luajit).warn("{s}", .{ptr[0..len]});
        }
        return err;
    }

    fn addFdWatch(self: *App, fd: i32, events: u32) !*FdWatch {
        const watch = try self.allocator.create(FdWatch);
        errdefer self.allocator.destroy(watch);
        watch.* = .{ .host = self.loopHost(), .fd = fd, .events = events };

        try self.fd_watches.append(self.allocator, watch);
        errdefer _ = self.fd_watches.pop();
        try watch.register();
        return watch;
    }

    fn addFsEvent(self: *App, path: []const u8) !*FsEvent {
        const fs_event = try self.allocator.create(FsEvent);
        errdefer self.allocator.destroy(fs_event);
        fs_event.* = .{
            .host = self.loopHost(),
            .path = try self.allocator.dupe(u8, path),
        };
        errdefer self.allocator.free(fs_event.path);
        try self.fs_events.append(self.allocator, fs_event);
        errdefer _ = self.fs_events.pop();
        try fs_event.register();
        return fs_event;
    }

    fn addTimerWithDelay(self: *App, delay_ms: u64, interval_ms: u64, ref: c_int) !*LuaTimer {
        errdefer c.luaL_unref(self.state, c.LUA_REGISTRYINDEX, ref);
        const timer = try self.allocator.create(LuaTimer);
        errdefer self.allocator.destroy(timer);
        timer.* = .{ .host = self.loopHost(), .delay_ms = delay_ms, .interval_ms = interval_ms, .ref = ref };

        try self.timers.append(self.allocator, timer);
        errdefer _ = self.timers.pop();
        try timer.register();
        return timer;
    }

    fn addProcess(self: *App, spec: lua_process.SpawnSpec) !*LuaProcess {
        var spawned = try LuaProcess.spawn(self.processHost(), spec);
        var moved = false;
        errdefer if (!moved) spawned.cleanup(self.state);

        const process = try self.allocator.create(LuaProcess);
        process.* = spawned;
        moved = true;
        errdefer process.deinit(self.allocator, self.state);

        process.bindSelf();

        try self.processes.append(self.allocator, process);
        errdefer _ = self.processes.pop();
        try self.registerProcess(process);
        return process;
    }

    fn registerProcess(_: *App, process: *LuaProcess) !void {
        try process.register();
    }

    fn processHost(self: *App) lua_process.Host {
        return .{ .ptr = self, .vtable = &process_host_vtable };
    }

    fn loopHost(self: *App) lua_loop.Host {
        return .{ .ptr = self, .vtable = &loop_host_vtable };
    }

    /// Takes ownership of `fd`: on failure the caller must close it.
    fn addSocket(self: *App, fd: i32) !*LuaSocket {
        const socket = try self.allocator.create(LuaSocket);
        errdefer self.allocator.destroy(socket);
        socket.* = .{ .host = self.socketHost(), .fd = fd };

        try self.sockets.append(self.allocator, socket);
        errdefer _ = self.sockets.pop();
        try socket.register();
        return socket;
    }

    fn socketHost(self: *App) lua_socket.Host {
        return .{ .ptr = self, .vtable = &socket_host_vtable };
    }

    fn addDbusBus(self: *App, kind: lua_dbus.Kind) !*DbusBus {
        const bus = try DbusBus.create(self.dbusHost(), kind);
        errdefer bus.destroy(self.allocator, self.state);
        try self.dbus_buses.append(self.allocator, bus);
        errdefer _ = self.dbus_buses.pop();
        try bus.register();
        return bus;
    }

    fn dbusHost(self: *App) lua_dbus.Host {
        return .{ .ptr = self, .vtable = &dbus_host_vtable };
    }
};

const process_host_vtable: lua_process.Host.VTable = .{
    .allocator = processHostAllocator,
    .luaState = processHostLuaState,
    .eventLoop = processHostEventLoop,
};

fn processHostAllocator(ptr: *anyopaque) std.mem.Allocator {
    const app: *App = @ptrCast(@alignCast(ptr));
    return app.allocator;
}

fn processHostLuaState(ptr: *anyopaque) *c.lua_State {
    const app: *App = @ptrCast(@alignCast(ptr));
    return app.state;
}

fn processHostEventLoop(ptr: *anyopaque) ?*event_loop.EventLoop {
    const app: *App = @ptrCast(@alignCast(ptr));
    return app.event_loop;
}

const loop_host_vtable: lua_loop.Host.VTable = .{
    .allocator = loopHostAllocator,
    .luaState = loopHostLuaState,
    .eventLoop = loopHostEventLoop,
    .invalidate = loopHostInvalidate,
    .addFdWatch = loopHostAddFdWatch,
    .addFsEvent = loopHostAddFsEvent,
    .addTimer = loopHostAddTimer,
};

fn loopHostAllocator(ptr: *anyopaque) std.mem.Allocator {
    const app: *App = @ptrCast(@alignCast(ptr));
    return app.allocator;
}

fn loopHostLuaState(ptr: *anyopaque) *c.lua_State {
    const app: *App = @ptrCast(@alignCast(ptr));
    return app.state;
}

fn loopHostEventLoop(ptr: *anyopaque) ?*event_loop.EventLoop {
    const app: *App = @ptrCast(@alignCast(ptr));
    return app.event_loop;
}

fn loopHostInvalidate(ptr: *anyopaque) anyerror!void {
    const app: *App = @ptrCast(@alignCast(ptr));
    const invalidator = app.invalidator orelse return;
    try invalidator.invalidate();
}

fn loopHostAddFdWatch(ptr: *anyopaque, fd: i32, events: u32) anyerror!*FdWatch {
    const app: *App = @ptrCast(@alignCast(ptr));
    return app.addFdWatch(fd, events);
}

fn loopHostAddFsEvent(ptr: *anyopaque, path: []const u8) anyerror!*FsEvent {
    const app: *App = @ptrCast(@alignCast(ptr));
    return app.addFsEvent(path);
}

fn loopHostAddTimer(ptr: *anyopaque, delay_ms: u64, interval_ms: u64, ref: c_int) anyerror!*LuaTimer {
    const app: *App = @ptrCast(@alignCast(ptr));
    return app.addTimerWithDelay(delay_ms, interval_ms, ref);
}

const socket_host_vtable: lua_socket.Host.VTable = .{
    .allocator = socketHostAllocator,
    .luaState = socketHostLuaState,
    .eventLoop = socketHostEventLoop,
    .addSocket = socketHostAddSocket,
};

fn socketHostAllocator(ptr: *anyopaque) std.mem.Allocator {
    const app: *App = @ptrCast(@alignCast(ptr));
    return app.allocator;
}

fn socketHostLuaState(ptr: *anyopaque) *c.lua_State {
    const app: *App = @ptrCast(@alignCast(ptr));
    return app.state;
}

fn socketHostEventLoop(ptr: *anyopaque) ?*event_loop.EventLoop {
    const app: *App = @ptrCast(@alignCast(ptr));
    return app.event_loop;
}

fn socketHostAddSocket(ptr: *anyopaque, fd: i32) anyerror!*LuaSocket {
    const app: *App = @ptrCast(@alignCast(ptr));
    return app.addSocket(fd);
}

const dbus_host_vtable: lua_dbus.Host.VTable = .{
    .allocator = dbusHostAllocator,
    .luaState = dbusHostLuaState,
    .eventLoop = dbusHostEventLoop,
    .addBus = dbusHostAddBus,
};

fn dbusHostAllocator(ptr: *anyopaque) std.mem.Allocator {
    const app: *App = @ptrCast(@alignCast(ptr));
    return app.allocator;
}

fn dbusHostLuaState(ptr: *anyopaque) *c.lua_State {
    const app: *App = @ptrCast(@alignCast(ptr));
    return app.state;
}

fn dbusHostEventLoop(ptr: *anyopaque) ?*event_loop.EventLoop {
    const app: *App = @ptrCast(@alignCast(ptr));
    return app.event_loop;
}

fn dbusHostAddBus(ptr: *anyopaque, kind: lua_dbus.Kind) anyerror!*DbusBus {
    const app: *App = @ptrCast(@alignCast(ptr));
    return app.addDbusBus(kind);
}

fn scriptChanged(ctx: *anyopaque, _: *event_loop.EventLoop, path: []const u8, mask: u32, _: ?[]const u8) !void {
    const app: *App = @ptrCast(@alignCast(ctx));
    std.log.scoped(.keywork_luajit).info("reload requested for {s} mask=0x{x}", .{ path, mask });
    app.script_dirty = true;
    const invalidator = app.invalidator orelse return;
    try invalidator.invalidate();
}

/// First byte of a LuaJIT (and PUC Lua) bytecode dump.
const bytecode_signature: u8 = 0x1b;

/// Mirror luaL_loadfile's `#` first-line handling, which LuaJIT's own
/// loader lacks for bytecode chunks. The newline is kept for source
/// chunks so error line numbers stay correct, and dropped for bytecode
/// where it would corrupt the dump.
fn scriptChunk(source: []const u8) []const u8 {
    if (source.len == 0 or source[0] != '#') return source;
    const newline = std.mem.indexOfScalar(u8, source, '\n') orelse return source[source.len..];
    const rest = source[newline..];
    if (rest.len > 1 and rest[1] == bytecode_signature) return rest[1..];
    return rest;
}

test "scriptChunk passes plain chunks through" {
    try std.testing.expectEqualStrings("return 1\n", scriptChunk("return 1\n"));
    try std.testing.expectEqualStrings("\x1bLJ\x02", scriptChunk("\x1bLJ\x02"));
    try std.testing.expectEqualStrings("", scriptChunk(""));
}

test "scriptChunk keeps the newline for shebang source" {
    try std.testing.expectEqualStrings("\nreturn 1\n", scriptChunk("#!/usr/bin/env keywork\nreturn 1\n"));
}

test "scriptChunk strips the whole line for shebang bytecode" {
    try std.testing.expectEqualStrings("\x1bLJ\x02", scriptChunk("#!/usr/bin/env keywork\n\x1bLJ\x02"));
}

test "scriptChunk handles a shebang-only file" {
    try std.testing.expectEqualStrings("", scriptChunk("#!/usr/bin/env keywork"));
    try std.testing.expectEqualStrings("\n", scriptChunk("#!/usr/bin/env keywork\n"));
}

const embedded_ui_source = @embedFile("ui.lua");

fn installKeyworkModule(lua_state: *c.lua_State, app: *App) void {
    c.lua_getfield(lua_state, c.LUA_GLOBALSINDEX, "package");
    const package_table = c.lua_gettop(lua_state);
    c.lua_getfield(lua_state, package_table, "preload");
    const preload_table = c.lua_gettop(lua_state);

    c.lua_pushlightuserdata(lua_state, app);
    c.lua_pushcclosure(lua_state, keyworkModuleLoader, 1);
    c.lua_setfield(lua_state, preload_table, "keywork");

    c.lua_pushlightuserdata(lua_state, app);
    c.lua_pushcclosure(lua_state, loopModuleLoader, 1);
    c.lua_setfield(lua_state, preload_table, "keywork.loop");

    c.lua_pushlightuserdata(lua_state, app);
    c.lua_pushcclosure(lua_state, processModuleLoader, 1);
    c.lua_setfield(lua_state, preload_table, "keywork.process");

    c.lua_pushlightuserdata(lua_state, app);
    c.lua_pushcclosure(lua_state, dbusModuleLoader, 1);
    c.lua_setfield(lua_state, preload_table, "keywork.dbus");

    c.lua_pushcclosure(lua_state, logModuleLoader, 0);
    c.lua_setfield(lua_state, preload_table, "keywork.log");

    c.lua_pushlightuserdata(lua_state, app);
    c.lua_pushcclosure(lua_state, jsonModuleLoader, 1);
    c.lua_setfield(lua_state, preload_table, "keywork.json");

    pop(lua_state, 2);
}

fn keyworkModuleLoader(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const app: *App = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    if (c.luaL_loadbuffer(lua_state, embedded_ui_source.ptr, embedded_ui_source.len, "@keywork/ui.lua") != 0) return c.lua_error(lua_state);
    if (c.lua_pcall(lua_state, 0, 1, 0) != 0) return c.lua_error(lua_state);
    const keywork_table = c.lua_gettop(lua_state);

    pushAppNamespace(lua_state, app);
    c.lua_setfield(lua_state, keywork_table, "app");
    return 1;
}

fn loopModuleLoader(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const app: *App = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    c.lua_createtable(lua_state, 0, 4);
    const loop_table = c.lua_gettop(lua_state);
    app.loop_host = app.loopHost();
    lua_loop.installResourceApis(lua_state, loop_table, &app.loop_host);
    app.socket_host = app.socketHost();
    lua_socket.installApi(lua_state, loop_table, &app.socket_host);
    return 1;
}

fn processModuleLoader(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const app: *App = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    c.lua_createtable(lua_state, 0, 1);
    c.lua_pushlightuserdata(lua_state, app);
    c.lua_pushcclosure(lua_state, luaSpawn, 1);
    c.lua_setfield(lua_state, -2, "spawn");
    return 1;
}

fn dbusModuleLoader(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const app: *App = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    app.dbus_host = app.dbusHost();
    lua_dbus.pushModule(lua_state, &app.dbus_host);
    return 1;
}

fn jsonModuleLoader(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const app: *App = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    lua_json.pushModule(lua_state, &app.allocator);
    return 1;
}

fn logModuleLoader(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    c.lua_createtable(lua_state, 0, 4);
    const log_table = c.lua_gettop(lua_state);
    c.lua_pushcclosure(lua_state, luaLogDebug, 0);
    c.lua_setfield(lua_state, log_table, "debug");
    c.lua_pushcclosure(lua_state, luaLogInfo, 0);
    c.lua_setfield(lua_state, log_table, "info");
    c.lua_pushcclosure(lua_state, luaLogWarn, 0);
    c.lua_setfield(lua_state, log_table, "warn");
    c.lua_pushcclosure(lua_state, luaLogErr, 0);
    c.lua_setfield(lua_state, log_table, "err");
    return 1;
}

fn pushAppNamespace(lua_state: *c.lua_State, app: *App) void {
    c.lua_createtable(lua_state, 0, 3);
    const app_table = c.lua_gettop(lua_state);
    c.lua_pushlightuserdata(lua_state, app);
    c.lua_pushcclosure(lua_state, luaQuit, 1);
    c.lua_setfield(lua_state, app_table, "quit");
    c.lua_pushlightuserdata(lua_state, app);
    c.lua_pushcclosure(lua_state, luaReload, 1);
    c.lua_setfield(lua_state, app_table, "reload");
    c.lua_pushlightuserdata(lua_state, app);
    c.lua_pushcclosure(lua_state, luaInvalidate, 1);
    c.lua_setfield(lua_state, app_table, "invalidate");

    c.lua_createtable(lua_state, 0, 1);
    c.lua_pushcclosure(lua_state, luaAppCall, 0);
    c.lua_setfield(lua_state, -2, "__call");
    _ = c.lua_setmetatable(lua_state, app_table);
}

fn luaAppCall(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    if (c.lua_isnoneornil(lua_state, 2)) c.lua_createtable(lua_state, 0, 1) else c.luaL_checktype(lua_state, 2, c.LUA_TTABLE);
    c.lua_pushliteral(lua_state, "app");
    c.lua_setfield(lua_state, -2, "type");
    return 1;
}

fn luaQuit(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const app: *App = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    if (app.event_loop) |loop| {
        loop.quit();
    } else {
        app.quit_requested = true;
    }
    return 0;
}

fn luaReload(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const app: *App = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    app.script_dirty = true;
    if (app.invalidator) |invalidator| invalidator.invalidate() catch |err| {
        std.log.scoped(.keywork_luajit).warn("reload invalidate failed: {}", .{err});
        return c.luaL_error(lua_state, "reload failed");
    };
    if (app.event_loop) |loop| loop.wake() catch {};
    return 0;
}

fn luaLogDebug(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    return luaLog(lua_state_optional, .debug);
}

fn luaLogInfo(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    return luaLog(lua_state_optional, .info);
}

fn luaLogWarn(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    return luaLog(lua_state_optional, .warn);
}

fn luaLogErr(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    return luaLog(lua_state_optional, .err);
}

fn luaLog(lua_state_optional: ?*c.lua_State, comptime level: std.log.Level) c_int {
    const lua_state = lua_state_optional.?;
    var writer: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer writer.deinit();

    const count = c.lua_gettop(lua_state);
    var index: c_int = 1;
    while (index <= count) : (index += 1) {
        if (index > 1) writer.writer.writeByte(' ') catch return c.luaL_error(lua_state, "log failed");
        tryLuaToString(lua_state, index, &writer.writer) catch return c.luaL_error(lua_state, "log failed");
    }

    const message = writer.written();
    switch (level) {
        .debug => std.log.scoped(.keywork_lua).debug("{s}", .{message}),
        .info => std.log.scoped(.keywork_lua).info("{s}", .{message}),
        .warn => std.log.scoped(.keywork_lua).warn("{s}", .{message}),
        .err => std.log.scoped(.keywork_lua).err("{s}", .{message}),
    }
    return 0;
}

fn tryLuaToString(lua_state: *c.lua_State, index: c_int, writer: *std.Io.Writer) !void {
    c.lua_getglobal(lua_state, "tostring");
    c.lua_pushvalue(lua_state, index);
    if (c.lua_pcall(lua_state, 1, 1, 0) != 0) {
        pop(lua_state, 1);
        return error.LuaToStringFailed;
    }
    defer pop(lua_state, 1);
    const value = stringFromStack(lua_state, -1) catch "<unprintable>";
    try writer.writeAll(value);
}

fn luaSpawn(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const app: *App = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    c.luaL_checktype(lua_state, 1, c.LUA_TTABLE);

    const argv = lua_process.parseArgv(lua_state, app.allocator, 1) catch |err| {
        std.log.scoped(.keywork_luajit).warn("spawn argv failed: {}", .{err});
        return c.luaL_error(lua_state, "invalid spawn argv");
    };
    defer lua_process.freeArgv(app.allocator, argv);

    const spec: lua_process.SpawnSpec = .{
        .argv = argv,
        .stdin_pipe = std.mem.eql(u8, lua_value.stringField(lua_state, 1, "stdin") catch "ignore", "pipe"),
        .stdout_pipe = std.mem.eql(u8, lua_value.stringField(lua_state, 1, "stdout") catch "ignore", "pipe"),
        .stderr_pipe = std.mem.eql(u8, lua_value.stringField(lua_state, 1, "stderr") catch "ignore", "pipe"),
    };
    // A missing executable or exhausted system resources are expected
    // runtime failures, so spawn reports nil, err instead of raising.
    const process = app.addProcess(spec) catch |err| {
        std.log.scoped(.keywork_luajit).warn("process.spawn failed: {}", .{err});
        c.lua_pushnil(lua_state);
        const name = @errorName(err);
        c.lua_pushlstring(lua_state, name.ptr, name.len);
        return 2;
    };
    lua_process.pushHandle(lua_state, process);
    return 1;
}

fn luaInvalidate(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const app: *App = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    const invalidator = app.invalidator orelse return 0;
    invalidator.invalidate() catch |err| {
        std.log.scoped(.keywork_luajit).warn("invalidate failed: {}", .{err});
        return c.luaL_error(lua_state, "invalidate failed");
    };
    return 0;
}

test "script must return a valid keywork.app root" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cases = [_]struct {
        name: []const u8,
        script: []const u8,
    }{
        .{ .name = "widget.lua", .script = "local kw = require('keywork'); return kw.text('not an app')\n" },
        .{ .name = "option.lua", .script = "local kw = require('keywork'); return kw.app({ width = 'wide', child = kw.text('x') })\n" },
    };

    for (cases) |case| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = case.name, .data = case.script });
        const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], case.name });
        defer allocator.free(script_path);

        var app = try App.init(allocator, script_path);
        defer app.deinit();
        try std.testing.expectError(error.InvalidAppRoot, app.ensureLoaded());
    }
}

test "keywork core excludes optional capability modules" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\local kw = require("keywork")
        \\assert(type(kw.app) == "table")
        \\assert(type(kw.app.quit) == "function")
        \\assert(type(kw.app.reload) == "function")
        \\assert(type(kw.app.invalidate) == "function")
        \\assert(kw.invalidate == nil)
        \\assert(kw.loop == nil)
        \\assert(kw.dbus == nil)
        \\assert(kw.log == nil)
        \\assert(package.loaded["keywork.loop"] == nil)
        \\assert(package.loaded["keywork.process"] == nil)
        \\assert(package.loaded["keywork.dbus"] == nil)
        \\assert(package.loaded["keywork.log"] == nil)
        \\assert(type(require("keywork.loop").timer) == "function")
        \\assert(type(require("keywork.process").spawn) == "function")
        \\assert(type(require("keywork.dbus").session) == "function")
        \\assert(type(require("keywork.log").info) == "function")
        \\local options = { child = kw.text("x") }
        \\local root = kw.app(options)
        \\assert(root == options)
        \\assert(root.type == "app")
        \\return root
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app-callable.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "app-callable.lua" });
    defer allocator.free(script_path);

    var app = try App.init(allocator, script_path);
    defer app.deinit();
    try app.ensureLoaded();
}

test "application lifecycle hooks run exactly once per load" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\local kw = require("keywork")
        \\starts, stops = 0, 0
        \\return kw.app({
        \\  child = kw.text("lifecycle"),
        \\  start = function() starts = starts + 1 end,
        \\  stop = function() stops = stops + 1 end,
        \\})
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lifecycle.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "lifecycle.lua" });
    defer allocator.free(script_path);

    var app = try App.init(allocator, script_path);
    defer app.deinit();
    try app.ensureLoaded();

    try app.startLifecycle();
    try app.startLifecycle();
    c.lua_getglobal(app.state, "starts");
    try std.testing.expectEqual(@as(c.lua_Integer, 1), c.lua_tointeger(app.state, -1));
    pop(app.state, 1);

    app.stopLifecycleLog();
    app.stopLifecycleLog();
    c.lua_getglobal(app.state, "stops");
    try std.testing.expectEqual(@as(c.lua_Integer, 1), c.lua_tointeger(app.state, -1));
    pop(app.state, 1);
}

test "reload cancels resources from the previous script load" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\local kw = require("keywork")
        \\local loop = require("keywork.loop")
        \\loop.timer({ interval = 60 })
        \\return kw.app({ child = kw.text("reload") })
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "reload.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "reload.lua" });
    defer allocator.free(script_path);

    var app = try App.init(allocator, script_path);
    defer app.deinit();
    try app.ensureLoaded();
    const previous_timer = app.timers.items[0];
    try std.testing.expect(!previous_timer.canceled);

    app.script_dirty = true;
    try app.ensureLoaded();
    try std.testing.expect(previous_timer.canceled);
    try std.testing.expectEqual(@as(usize, 2), app.timers.items.len);
    try std.testing.expect(!app.timers.items[1].canceled);
}

test "stale handles from a previous script load are inert" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Globals survive reload because the Lua state is reused, so a handle
    // retained by the first load is observable from the second. The reload
    // cancels the underlying timer, which must leave the retained handle as
    // a safe no-op rather than a dangling pointer.
    const script =
        \\local kw = require("keywork")
        \\local loop = require("keywork.loop")
        \\if stale_timer then
        \\  stale_canceled = stale_timer:canceled()
        \\  stale_timer:cancel()
        \\  stale_timer:cancel()
        \\  stale_still_canceled = stale_timer:canceled()
        \\else
        \\  stale_timer = loop.timer({ interval = 60 })
        \\  fresh_canceled = stale_timer:canceled()
        \\end
        \\return kw.app({ child = kw.text("stale") })
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "stale.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "stale.lua" });
    defer allocator.free(script_path);

    var app = try App.init(allocator, script_path);
    defer app.deinit();
    try app.ensureLoaded();

    c.lua_getglobal(app.state, "fresh_canceled");
    try std.testing.expect(c.lua_toboolean(app.state, -1) == 0);
    pop(app.state, 1);

    app.script_dirty = true;
    try app.ensureLoaded();

    c.lua_getglobal(app.state, "stale_canceled");
    try std.testing.expect(c.lua_toboolean(app.state, -1) != 0);
    pop(app.state, 1);
    c.lua_getglobal(app.state, "stale_still_canceled");
    try std.testing.expect(c.lua_toboolean(app.state, -1) != 0);
    pop(app.state, 1);
    // The stale cancel calls must not have created new resources.
    try std.testing.expectEqual(@as(usize, 1), app.timers.items.len);
    try std.testing.expect(app.timers.items[0].canceled);
}

test "application quit is idempotent before the loop starts" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\local kw = require("keywork")
        \\kw.app.quit()
        \\kw.app.quit()
        \\return kw.app({ child = kw.text("quit") })
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "quit.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "quit.lua" });
    defer allocator.free(script_path);

    var app = try App.init(allocator, script_path);
    defer app.deinit();
    try app.ensureLoaded();
    try std.testing.expect(app.quit_requested);

    var loop = try event_loop.EventLoop.init(allocator);
    defer loop.deinit();
    try app.bindEventLoop(&loop);
    defer app.unbindEventLoop();
    try std.testing.expect(!app.quit_requested);
    try loop.run();
}

test "lua timer streams ticks to a coroutine reader" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\local kw = require("keywork")
        \\local loop = require("keywork.loop")
        \\ticks = 0
        \\done = false
        \\local t = loop.timer({ delay = 0.001, interval = 0.001 })
        \\loop.spawn(function()
        \\  for n in t:ticks() do
        \\    ticks = ticks + n
        \\    if ticks >= 3 then t:cancel() end
        \\  end
        \\  done = true
        \\end)
        \\return kw.app({ child = kw.text("timer") })
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "timer-ticks.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "timer-ticks.lua" });
    defer allocator.free(script_path);

    var app = try App.init(allocator, script_path);
    defer app.deinit();
    try app.ensureLoaded();

    var loop = try event_loop.EventLoop.init(allocator);
    defer loop.deinit();
    try app.bindEventLoop(&loop);
    defer app.unbindEventLoop();

    const TickTest = struct {
        app: *App,
        rounds: u32 = 0,

        fn callback(ctx: *anyopaque, event_loop_instance: *event_loop.EventLoop, _: u64) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.rounds += 1;
            c.lua_getglobal(self.app.state, "done");
            const done = c.lua_toboolean(self.app.state, -1) != 0;
            pop(self.app.state, 1);
            if (done or self.rounds > 1000) event_loop_instance.quit();
        }
    };
    var context: TickTest = .{ .app = &app };
    try loop.addRepeatingTimer(1, &context, TickTest.callback);
    try loop.run();

    c.lua_getglobal(app.state, "done");
    try std.testing.expect(c.lua_toboolean(app.state, -1) != 0);
    pop(app.state, 1);
    c.lua_getglobal(app.state, "ticks");
    defer pop(app.state, 1);
    try std.testing.expect(c.lua_tointeger(app.state, -1) >= 3);
    try std.testing.expect(app.timers.items[0].canceled);
}

test "lua one-shot timer ends iteration after its tick" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\local kw = require("keywork")
        \\local loop = require("keywork.loop")
        \\ticks = 0
        \\done = false
        \\local t = loop.timer({ delay = 0.001 })
        \\loop.spawn(function()
        \\  for n in t:ticks() do
        \\    ticks = ticks + n
        \\  end
        \\  done = true
        \\end)
        \\return kw.app({ child = kw.text("timer") })
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "timer-oneshot.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "timer-oneshot.lua" });
    defer allocator.free(script_path);

    var app = try App.init(allocator, script_path);
    defer app.deinit();
    try app.ensureLoaded();

    var loop = try event_loop.EventLoop.init(allocator);
    defer loop.deinit();
    try app.bindEventLoop(&loop);
    defer app.unbindEventLoop();

    const TickTest = struct {
        app: *App,
        rounds: u32 = 0,

        fn callback(ctx: *anyopaque, event_loop_instance: *event_loop.EventLoop, _: u64) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.rounds += 1;
            c.lua_getglobal(self.app.state, "done");
            const done = c.lua_toboolean(self.app.state, -1) != 0;
            pop(self.app.state, 1);
            if (done or self.rounds > 1000) event_loop_instance.quit();
        }
    };
    var context: TickTest = .{ .app = &app };
    try loop.addRepeatingTimer(1, &context, TickTest.callback);
    try loop.run();

    c.lua_getglobal(app.state, "done");
    try std.testing.expect(c.lua_toboolean(app.state, -1) != 0);
    pop(app.state, 1);
    c.lua_getglobal(app.state, "ticks");
    defer pop(app.state, 1);
    try std.testing.expectEqual(@as(c.lua_Integer, 1), c.lua_tointeger(app.state, -1));
    // The spent one-shot is expired, not canceled, and no longer counts as
    // live work.
    try std.testing.expect(app.timers.items[0].expired);
    try std.testing.expect(!app.timers.items[0].canceled);
    try std.testing.expect(!app.hasLiveAsyncResources());
}

test "lua timer cancel resumes a parked reader and ends iteration" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Cancel comes from the main state while the reader coroutine is parked
    // in next(); it must resume with no value so the loop ends.
    const script =
        \\local kw = require("keywork")
        \\local loop = require("keywork.loop")
        \\ended = false
        \\local t = loop.timer({ interval = 60 })
        \\loop.spawn(function()
        \\  for _ in t:ticks() do end
        \\  ended = true
        \\end)
        \\t:cancel()
        \\return kw.app({ child = kw.text("timer") })
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "timer-cancel.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "timer-cancel.lua" });
    defer allocator.free(script_path);

    var app = try App.init(allocator, script_path);
    defer app.deinit();
    try app.ensureLoaded();

    c.lua_getglobal(app.state, "ended");
    defer pop(app.state, 1);
    try std.testing.expect(c.lua_toboolean(app.state, -1) != 0);
    try std.testing.expect(app.timers.items[0].canceled);
}

test "lua loop.spawn awaits loop.sleep" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\local kw = require("keywork")
        \\local loop = require("keywork.loop")
        \\order = ""
        \\loop.spawn(function()
        \\  order = order .. "a"
        \\  loop.sleep(1)
        \\  order = order .. "c"
        \\end)
        \\order = order .. "b"
        \\return kw.app({ child = kw.text("sleep") })
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sleep.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "sleep.lua" });
    defer allocator.free(script_path);

    var app = try App.init(allocator, script_path);
    defer app.deinit();
    try app.ensureLoaded();

    // The spawned coroutine runs synchronously until the sleep parks it.
    c.lua_getglobal(app.state, "order");
    try std.testing.expectEqualStrings("ab", try stringFromStack(app.state, -1));
    pop(app.state, 1);
    try std.testing.expectEqual(@as(usize, 1), app.timers.items.len);
    try std.testing.expect(app.timers.items[0].waiter);

    var loop = try event_loop.EventLoop.init(allocator);
    defer loop.deinit();
    try app.bindEventLoop(&loop);
    defer app.unbindEventLoop();

    const SleepTest = struct {
        app: *App,
        ticks: u32 = 0,

        fn callback(ctx: *anyopaque, event_loop_instance: *event_loop.EventLoop, _: u64) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.ticks += 1;
            c.lua_getglobal(self.app.state, "order");
            const done = std.mem.eql(u8, stringFromStack(self.app.state, -1) catch "", "abc");
            pop(self.app.state, 1);
            if (done or self.ticks > 1000) event_loop_instance.quit();
        }
    };
    var context: SleepTest = .{ .app = &app };
    try loop.addRepeatingTimer(1, &context, SleepTest.callback);
    try loop.run();

    c.lua_getglobal(app.state, "order");
    defer pop(app.state, 1);
    try std.testing.expectEqualStrings("abc", try stringFromStack(app.state, -1));
    // The waiter timer is one-shot and spends itself after resuming.
    try std.testing.expect(app.timers.items[0].canceled);
}

test "loop.sleep on the main state raises" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\local kw = require("keywork")
        \\local loop = require("keywork.loop")
        \\local ok, err = pcall(loop.sleep, 1)
        \\assert(not ok)
        \\assert(err:find("coroutine", 1, true))
        \\return kw.app({ child = kw.text("main") })
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sleep-main.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "sleep-main.lua" });
    defer allocator.free(script_path);

    var app = try App.init(allocator, script_path);
    defer app.deinit();
    try app.ensureLoaded();
    try std.testing.expectEqual(@as(usize, 0), app.timers.items.len);
}

test "a sleeping coroutine tears down cleanly with the app" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\local kw = require("keywork")
        \\local loop = require("keywork.loop")
        \\loop.spawn(function() loop.sleep(3600000) end)
        \\return kw.app({ child = kw.text("sleep") })
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sleep-teardown.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "sleep-teardown.lua" });
    defer allocator.free(script_path);

    var app = try App.init(allocator, script_path);
    defer app.deinit();
    try app.ensureLoaded();
    try std.testing.expectEqual(@as(usize, 1), app.timers.items.len);
    try std.testing.expect(!app.timers.items[0].canceled);
    // deinit cancels the waiter timer without resuming; the parked
    // coroutine is simply dropped with the state.
}

test "lua bus:call awaits replies and reports peer errors as nil, err" {
    if (std.c.getenv("DBUS_SESSION_BUS_ADDRESS") == null) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\local kw = require("keywork")
        \\local dbus = require("keywork.dbus")
        \\local loop = require("keywork.loop")
        \\local bus = assert(dbus.session())
        \\
        \\-- Awaiting on the main state is programmer misuse and raises.
        \\local ok, err = pcall(function() return bus:call({}) end)
        \\assert(not ok and err:find("coroutine", 1, true))
        \\
        \\-- A dead handle reports nil, err instead of parking forever.
        \\local closed = assert(dbus.session())
        \\closed:close()
        \\local dead_reply, dead_err = closed:call({})
        \\assert(dead_reply == nil and dead_err == "BusClosed")
        \\
        \\loop.spawn(function()
        \\  local reply, call_err = bus:call({
        \\    destination = "org.freedesktop.DBus",
        \\    path = "/org/freedesktop/DBus",
        \\    interface = "org.freedesktop.DBus",
        \\    member = "GetId",
        \\    timeout_ms = 2000,
        \\  })
        \\  got_id = call_err == nil and type(reply.args[1]) == "string"
        \\  local missing, missing_err = bus:call({
        \\    destination = "org.keywork.NoSuchService",
        \\    path = "/",
        \\    interface = "org.keywork.Nope",
        \\    member = "Nope",
        \\    timeout_ms = 2000,
        \\  })
        \\  got_error = missing == nil and type(missing_err) == "string"
        \\  done = true
        \\end)
        \\return kw.app({ child = kw.text("dbus") })
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "dbus-call.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "dbus-call.lua" });
    defer allocator.free(script_path);

    var app = try App.init(allocator, script_path);
    defer app.deinit();
    try app.ensureLoaded();

    var loop = try event_loop.EventLoop.init(allocator);
    defer loop.deinit();
    try app.bindEventLoop(&loop);
    defer app.unbindEventLoop();

    const DbusCallTest = struct {
        app: *App,
        ticks: u32 = 0,

        fn callback(ctx: *anyopaque, event_loop_instance: *event_loop.EventLoop, _: u64) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.ticks += 1;
            c.lua_getglobal(self.app.state, "done");
            const done = c.lua_toboolean(self.app.state, -1) != 0;
            pop(self.app.state, 1);
            if (done or self.ticks > 3000) event_loop_instance.quit();
        }
    };
    var context: DbusCallTest = .{ .app = &app };
    try loop.addRepeatingTimer(1, &context, DbusCallTest.callback);
    try loop.run();

    c.lua_getglobal(app.state, "got_id");
    try std.testing.expect(c.lua_toboolean(app.state, -1) != 0);
    pop(app.state, 1);
    c.lua_getglobal(app.state, "got_error");
    try std.testing.expect(c.lua_toboolean(app.state, -1) != 0);
    pop(app.state, 1);
}

test "lua bus:subscribe streams signals to a coroutine reader" {
    if (std.c.getenv("DBUS_SESSION_BUS_ADDRESS") == null) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The bus subscribes to its own broadcast signal: the daemon routes it
    // back because of the match rule, so no second peer is needed.
    const script =
        \\local kw = require("keywork")
        \\local dbus = require("keywork.dbus")
        \\local loop = require("keywork.loop")
        \\local bus = assert(dbus.session())
        \\local sub = bus:subscribe({ interface = "org.keywork.StreamTest", member = "Ping" })
        \\got_signal = false
        \\sub_ended = false
        \\loop.spawn(function()
        \\  for signal in sub:events() do
        \\    got_signal = signal.interface == "org.keywork.StreamTest"
        \\      and signal.member == "Ping"
        \\      and signal.args[1] == "hello"
        \\    sub:cancel()
        \\  end
        \\  sub_ended = true
        \\  done = true
        \\end)
        \\bus:emit({
        \\  path = "/org/keywork/stream_test",
        \\  interface = "org.keywork.StreamTest",
        \\  member = "Ping",
        \\  args = { "hello" },
        \\})
        \\return kw.app({ child = kw.text("dbus-sub") })
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "dbus-subscribe.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "dbus-subscribe.lua" });
    defer allocator.free(script_path);

    var app = try App.init(allocator, script_path);
    defer app.deinit();
    try app.ensureLoaded();

    var loop = try event_loop.EventLoop.init(allocator);
    defer loop.deinit();
    try app.bindEventLoop(&loop);
    defer app.unbindEventLoop();

    const DbusSubscribeTest = struct {
        app: *App,
        ticks: u32 = 0,

        fn callback(ctx: *anyopaque, event_loop_instance: *event_loop.EventLoop, _: u64) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.ticks += 1;
            c.lua_getglobal(self.app.state, "done");
            const done = c.lua_toboolean(self.app.state, -1) != 0;
            pop(self.app.state, 1);
            if (done or self.ticks > 3000) event_loop_instance.quit();
        }
    };
    var context: DbusSubscribeTest = .{ .app = &app };
    try loop.addRepeatingTimer(1, &context, DbusSubscribeTest.callback);
    try loop.run();

    c.lua_getglobal(app.state, "got_signal");
    try std.testing.expect(c.lua_toboolean(app.state, -1) != 0);
    pop(app.state, 1);
    c.lua_getglobal(app.state, "sub_ended");
    try std.testing.expect(c.lua_toboolean(app.state, -1) != 0);
    pop(app.state, 1);
}

test "lua dbus property sugar and proxies drive exported objects" {
    if (std.c.getenv("DBUS_SESSION_BUS_ADDRESS") == null) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The bus exports an object and calls it through its own well-known
    // name: the daemon routes calls and replies back over the same
    // connection, so no second peer is needed.
    const script =
        \\local kw = require("keywork")
        \\local dbus = require("keywork.dbus")
        \\local loop = require("keywork.loop")
        \\local bus = assert(dbus.session())
        \\
        \\-- Programmer misuse raises: bad proxy arguments, uninferable value.
        \\assert(not pcall(function() return bus:proxy(nil, "/", "org.keywork.Nope") end))
        \\assert(not pcall(function()
        \\  return bus:set_property({
        \\    destination = "org.keywork.Nope", path = "/",
        \\    interface = "org.keywork.Nope", name = "X", value = {},
        \\  })
        \\end))
        \\
        \\local value = "initial"
        \\local count = 0
        \\assert(bus:request_name("org.keywork.test.Properties"))
        \\bus:export("/org/keywork/prop_test", {
        \\  ["org.keywork.PropTest"] = {
        \\    methods = {
        \\      Echo = { call = function(call, text) return text end },
        \\    },
        \\    properties = {
        \\      Value = {
        \\        signature = "s",
        \\        access = "readwrite",
        \\        get = function() return value end,
        \\        set = function(v) value = v end,
        \\      },
        \\      Count = {
        \\        signature = "u",
        \\        access = "readwrite",
        \\        get = function() return dbus.uint32(count) end,
        \\        set = function(v) count = v end,
        \\      },
        \\      Fixed = {
        \\        signature = "s",
        \\        get = function() return "fixed" end,
        \\      },
        \\    },
        \\  },
        \\})
        \\
        \\loop.spawn(function()
        \\  local target = {
        \\    destination = "org.keywork.test.Properties",
        \\    path = "/org/keywork/prop_test",
        \\    interface = "org.keywork.PropTest",
        \\    timeout_ms = 2000,
        \\  }
        \\  local function options(extra)
        \\    local merged = {}
        \\    for key, entry in pairs(target) do merged[key] = entry end
        \\    for key, entry in pairs(extra) do merged[key] = entry end
        \\    return merged
        \\  end
        \\
        \\  got_initial = bus:get_property(options({ name = "Value" })) == "initial"
        \\  set_ok = bus:set_property(options({ name = "Value", value = "updated" })) == true
        \\  got_updated = bus:get_property(options({ name = "Value" })) == "updated" and value == "updated"
        \\
        \\  -- Typed values carry their own wire signature through the variant.
        \\  typed_set = bus:set_property(options({ name = "Count", value = dbus.uint32(7) })) == true
        \\  typed_get = bus:get_property(options({ name = "Count" })) == 7 and count == 7
        \\
        \\  -- A property without a setter is read-only on the wire.
        \\  local denied, denied_err = bus:set_property(options({ name = "Fixed", value = "nope" }))
        \\  read_only = denied == nil and denied_err == "org.freedesktop.DBus.Error.PropertyReadOnly"
        \\
        \\  local proxy = bus:proxy(target.destination, target.path, target.interface, { timeout_ms = 2000 })
        \\  proxy_echo = proxy:Echo("hello") == "hello"
        \\  local nope, nope_err = proxy:NoSuchMethod()
        \\  proxy_error = nope == nil and type(nope_err) == "string"
        \\  done = true
        \\end)
        \\return kw.app({ child = kw.text("dbus-props") })
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "dbus-properties.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "dbus-properties.lua" });
    defer allocator.free(script_path);

    var app = try App.init(allocator, script_path);
    defer app.deinit();
    try app.ensureLoaded();

    var loop = try event_loop.EventLoop.init(allocator);
    defer loop.deinit();
    try app.bindEventLoop(&loop);
    defer app.unbindEventLoop();

    const DbusPropertiesTest = struct {
        app: *App,
        ticks: u32 = 0,

        fn callback(ctx: *anyopaque, event_loop_instance: *event_loop.EventLoop, _: u64) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.ticks += 1;
            c.lua_getglobal(self.app.state, "done");
            const done = c.lua_toboolean(self.app.state, -1) != 0;
            pop(self.app.state, 1);
            if (done or self.ticks > 5000) event_loop_instance.quit();
        }
    };
    var context: DbusPropertiesTest = .{ .app = &app };
    try loop.addRepeatingTimer(1, &context, DbusPropertiesTest.callback);
    try loop.run();

    const expected_true = [_][:0]const u8{
        "got_initial", "set_ok",    "got_updated", "typed_set",
        "typed_get",   "read_only", "proxy_echo",  "proxy_error",
    };
    for (expected_true) |global| {
        c.lua_getglobal(app.state, global.ptr);
        std.testing.expect(c.lua_toboolean(app.state, -1) != 0) catch |err| {
            std.debug.print("expected global '{s}' to be true\n", .{global});
            return err;
        };
        pop(app.state, 1);
    }
}

test "lua stateful widget set_state rebuilds retained subtree" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\local kw = require("keywork")
        \\local Counter = kw.stateful({
        \\  init = function(self)
        \\    self.count = 0
        \\  end,
        \\  build = function(self, state)
        \\    return kw.gesture({ id = "counter", child = kw.text(tostring(self.count)), on_tap = function()
        \\      self:set_state(function(s)
        \\        s.count = s.count + 1
        \\      end)
        \\    end })
        \\  end,
        \\})
        \\local App = kw.stateful({
        \\  build = function(self, state)
        \\    return Counter({ key = "counter" })
        \\  end,
        \\})
        \\return kw.app({ child = App({ key = "app" }) })
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "stateful.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "stateful.lua" });
    defer allocator.free(script_path);

    var app = try App.init(allocator, script_path);
    defer app.deinit();

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var log_backend: log_backend_mod.LogBackend = .{ .writer = &output.writer };
    var runtime = try runtime_mod.Runtime.init(
        allocator,
        log_backend.backend(),
        .{ .max_width = 100, .max_height = 40 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();
    app.bindRuntime(&runtime);

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
        \\local kw = require("keywork")
        \\disposed = false
        \\local Child = kw.stateful({
        \\  dispose = function(self)
        \\    disposed = true
        \\  end,
        \\  build = function(self, state)
        \\    return kw.gesture({ id = "remove", child = kw.text("remove"), on_tap = self.props.on_remove })
        \\  end,
        \\})
        \\local App = kw.stateful({
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
        \\    return kw.text("gone")
        \\  end,
        \\})
        \\return kw.app({ child = App({ key = "app" }) })
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "dispose.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "dispose.lua" });
    defer allocator.free(script_path);

    var app = try App.init(allocator, script_path);
    defer app.deinit();

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var log_backend: log_backend_mod.LogBackend = .{ .writer = &output.writer };
    var runtime = try runtime_mod.Runtime.init(
        allocator,
        log_backend.backend(),
        .{ .max_width = 100, .max_height = 40 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();
    app.bindRuntime(&runtime);

    try runtime.repaint();
    try runtime.click(.{ .x = 2, .y = 2 });
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "value=\"gone\"") != null);

    c.lua_getglobal(app.state, "disposed");
    defer pop(app.state, 1);
    try std.testing.expect(c.lua_toboolean(app.state, -1) != 0);
}

test "lua stateful set_state is inert after dispose" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A callback may retain the state table (via self) past dispose. The
    // stale set_state must be a safe no-op that neither errors nor marks
    // the freed state dirty.
    const script =
        \\local kw = require("keywork")
        \\disposed = false
        \\local Child = kw.stateful({
        \\  init = function(self)
        \\    stale_set_state = function()
        \\      self:set_state(function(s) s.poked = true end)
        \\    end
        \\  end,
        \\  dispose = function(self)
        \\    disposed = true
        \\  end,
        \\  build = function(self, state)
        \\    return kw.gesture({ id = "remove", child = kw.text("remove"), on_tap = self.props.on_remove })
        \\  end,
        \\})
        \\local App = kw.stateful({
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
        \\    return kw.text("gone")
        \\  end,
        \\})
        \\return kw.app({ child = App({ key = "app" }) })
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "stale-set-state.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "stale-set-state.lua" });
    defer allocator.free(script_path);

    var app = try App.init(allocator, script_path);
    defer app.deinit();

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var log_backend: log_backend_mod.LogBackend = .{ .writer = &output.writer };
    var runtime = try runtime_mod.Runtime.init(
        allocator,
        log_backend.backend(),
        .{ .max_width = 100, .max_height = 40 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();
    app.bindRuntime(&runtime);

    try runtime.repaint();
    try runtime.click(.{ .x = 2, .y = 2 });

    c.lua_getglobal(app.state, "disposed");
    try std.testing.expect(c.lua_toboolean(app.state, -1) != 0);
    pop(app.state, 1);

    c.lua_getglobal(app.state, "stale_set_state");
    try std.testing.expectEqual(c.LUA_TFUNCTION, c.lua_type(app.state, -1));
    try std.testing.expectEqual(@as(c_int, 0), c.lua_pcall(app.state, 0, 0, 0));
}

test "event loop bind survives a vanished fs_event path" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Registration is deferred until the loop binds, so the script can
    // watch a path that never exists; the bind must cancel that watch
    // instead of failing.
    const script =
        \\local kw = require("keywork")
        \\local loop = require("keywork.loop")
        \\watch = loop.fs_event("/nonexistent/keywork/test/path")
        \\return kw.app({ child = kw.text("bind") })
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bind-vanished.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "bind-vanished.lua" });
    defer allocator.free(script_path);

    var app = try App.init(allocator, script_path);
    defer app.deinit();
    try app.ensureLoaded();
    try std.testing.expectEqual(@as(usize, 1), app.fs_events.items.len);
    try std.testing.expect(!app.fs_events.items[0].canceled);

    var loop = try event_loop.EventLoop.init(allocator);
    defer loop.deinit();
    try app.bindEventLoop(&loop);
    defer app.unbindEventLoop();

    try std.testing.expect(app.fs_events.items[0].canceled);
}

test "lua fs_event cancel resumes a parked reader and ends iteration" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Cancel must resume the coroutine parked in next() with no value so
    // the events() iteration terminates, all synchronously (no event loop).
    const script =
        \\local kw = require("keywork")
        \\local loop = require("keywork.loop")
        \\local watch = loop.fs_event("/tmp")
        \\stream_ended = false
        \\local reader = loop.spawn(function()
        \\  for _ in watch:events() do end
        \\  stream_ended = true
        \\end)
        \\assert(coroutine.status(reader) == "suspended")
        \\watch:cancel()
        \\assert(stream_ended)
        \\assert(coroutine.status(reader) == "dead")
        \\assert(watch:canceled())
        \\-- next() on a dead handle ends iteration instead of parking.
        \\loop.spawn(function()
        \\  assert(watch:next() == nil)
        \\  dead_next_ok = true
        \\end)
        \\assert(dead_next_ok)
        \\return kw.app({ child = kw.text("cancel") })
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fs-event-cancel.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "fs-event-cancel.lua" });
    defer allocator.free(script_path);

    var app = try App.init(allocator, script_path);
    defer app.deinit();
    try app.ensureLoaded();
}

test "lua fd watch cancel resumes a parked reader and ends iteration" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // No event loop is bound, so the watch never registers and the reader
    // parks until cancel resumes it with no value.
    const script =
        \\local kw = require("keywork")
        \\local loop = require("keywork.loop")
        \\local watch = loop.fd(0, { read = true })
        \\fd_stream_ended = false
        \\local reader = loop.spawn(function()
        \\  for _ in watch:events() do end
        \\  fd_stream_ended = true
        \\end)
        \\assert(coroutine.status(reader) == "suspended")
        \\watch:cancel()
        \\assert(fd_stream_ended)
        \\assert(watch:canceled())
        \\return kw.app({ child = kw.text("fd-cancel") })
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fd-cancel.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "fd-cancel.lua" });
    defer allocator.free(script_path);

    var app = try App.init(allocator, script_path);
    defer app.deinit();
    try app.ensureLoaded();
}

test "lua fd watch coalesces readiness and hands it to the next reader" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var fds: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&fds, .{ .NONBLOCK = true, .CLOEXEC = true })) != .SUCCESS) return error.PipeFailed;
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);

    // Bind-time registration primes the watch with a read event while no
    // reader is parked; it must coalesce into pending readiness that the
    // first next() returns without yielding.
    const script = try std.fmt.allocPrint(allocator,
        \\local kw = require("keywork")
        \\local loop = require("keywork.loop")
        \\watch = loop.fd({d}, {{ read = true }})
        \\got_read = false
        \\function start_reader()
        \\  loop.spawn(function()
        \\    local ev = watch:next()
        \\    got_read = ev.read
        \\    watch:cancel()
        \\  end)
        \\end
        \\return kw.app({{ child = kw.text("fd-pending") }})
        \\
    , .{fds[0]});
    defer allocator.free(script);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fd-pending.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "fd-pending.lua" });
    defer allocator.free(script_path);

    var app = try App.init(allocator, script_path);
    defer app.deinit();
    try app.ensureLoaded();

    var loop = try event_loop.EventLoop.init(allocator);
    defer loop.deinit();
    try app.bindEventLoop(&loop);
    defer app.unbindEventLoop();

    try std.testing.expectEqual(@as(usize, 1), app.fd_watches.items.len);
    try std.testing.expect(app.fd_watches.items[0].pending != 0);

    c.lua_getglobal(app.state, "start_reader");
    try std.testing.expectEqual(@as(c_int, 0), c.lua_pcall(app.state, 0, 0, 0));

    c.lua_getglobal(app.state, "got_read");
    defer pop(app.state, 1);
    try std.testing.expect(c.lua_toboolean(app.state, -1) != 0);
    try std.testing.expect(app.fd_watches.items[0].canceled);
}

test "lua stateful build context includes theme" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\local kw = require("keywork")
        \\local App = kw.stateful({
        \\  build = function(self, context)
        \\    return kw.theme({ data = context.theme, child = kw.label(context.theme.color_scheme) })
        \\  end,
        \\})
        \\return kw.app({ child = App({ key = "app" }) })
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "theme-context.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "theme-context.lua" });
    defer allocator.free(script_path);

    var app = try App.init(allocator, script_path);
    defer app.deinit();

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var log_backend: log_backend_mod.LogBackend = .{ .writer = &output.writer };
    var runtime = try runtime_mod.Runtime.init(
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

test "lua resolves theme families and component tokens" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\local kw = require("keywork")
        \\local theme_family = kw.theme_data({
        \\  schemes = {
        \\    dark = {
        \\      colors = {
        \\        primary = 0xff112233,
        \\        background = 0xff010203,
        \\        foreground = 0xfffefdfc,
        \\        surface_high = 0xff223344,
        \\        border = 0xff334455,
        \\        muted = 0xff445566,
        \\      },
        \\    },
        \\  },
        \\  components = {
        \\    input = {
        \\      background = "surface_high",
        \\      foreground = "foreground",
        \\      placeholder = "muted",
        \\      border = "border",
        \\      focused_border = "primary",
        \\      radius = 0,
        \\    },
        \\  },
        \\})
        \\local App = kw.stateful({
        \\  build = function(self, context)
        \\    return kw.theme({
        \\      data = kw.resolve_theme(theme_family, context),
        \\      child = kw.text_input({ id = "name", value = "", placeholder = "Name" }),
        \\    })
        \\  end,
        \\})
        \\return kw.app({ child = App({ key = "app" }) })
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "theme-family.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "theme-family.lua" });
    defer allocator.free(script_path);

    var app = try App.init(allocator, script_path);
    defer app.deinit();

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var log_backend: log_backend_mod.LogBackend = .{ .writer = &output.writer };
    var runtime = try runtime_mod.Runtime.init(
        allocator,
        log_backend.backend(),
        .{ .max_width = 240, .max_height = 40 },
        app.host(),
        .dark,
    );
    defer runtime.deinit();

    try runtime.repaint();
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "fill_rect x=0 y=0 w=240 h=40 color=#ff111113") != null);
    // Input geometry follows the default input theme: 14px text plus 6px
    // vertical and 8px horizontal padding (Radix size-2 text field).
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "fill_rect x=0 y=0 w=240 h=26 color=#ff223344") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "text x=8 y=6 value=\"Name\" color=#ff445566") != null);
}

test "lua flexible and main_align lay out through the parser" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\local kw = require("keywork")
        \\return kw.app({ child = kw.column({
        \\  children = {
        \\    kw.row({ main_align = "space_between", children = { kw.text("L"), kw.text("R") } }),
        \\    kw.row({ children = { kw.text("A"), kw.expanded(kw.text("B")) } }),
        \\  },
        \\}) })
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "flex.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "flex.lua" });
    defer allocator.free(script_path);

    var app = try App.init(allocator, script_path);
    defer app.deinit();

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var log_backend: log_backend_mod.LogBackend = .{ .writer = &output.writer };
    var runtime = try runtime_mod.Runtime.init(
        allocator,
        log_backend.backend(),
        .{ .max_width = 100, .max_height = 60 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();

    try runtime.repaint();
    // space_between pushes R (8px wide) to the 100px right edge.
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "x=92 y=0 value=\"R\"") != null);
    // The expanded text starts right after A regardless of its own width.
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "x=8 y=16 value=\"B\"") != null);
}

test "lua loop fs_event observes file changes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "watched.txt", .data = "before\n" });
    const watched_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "watched.txt" });
    defer allocator.free(watched_path);

    const script = try std.fmt.allocPrint(allocator,
        \\local kw = require("keywork")
        \\local loop = require("keywork.loop")
        \\
        \\fs_event_seen = false
        \\fs_event_path = ""
        \\local App = kw.stateful({{
        \\  init = function(self)
        \\    self.watch = loop.fs_event({{ path = "{s}" }})
        \\    loop.spawn(function()
        \\      for event in self.watch:events() do
        \\        fs_event_seen = event.change
        \\        fs_event_path = event.path
        \\      end
        \\      fs_event_stream_ended = true
        \\    end)
        \\  end,
        \\  dispose = function(self)
        \\    if self.watch then
        \\      self.watch:cancel()
        \\    end
        \\  end,
        \\  build = function(self, state)
        \\    return kw.text("fs_event")
        \\  end,
        \\}})
        \\return kw.app({{ child = App({{ key = "app" }}) }})
        \\
    , .{watched_path});
    defer allocator.free(script);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fs-event.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "fs-event.lua" });
    defer allocator.free(script_path);

    var app = try App.init(allocator, script_path);
    defer app.deinit();

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var log_backend: log_backend_mod.LogBackend = .{ .writer = &output.writer };
    // The loop must outlive the runtime: runtime deinit disposes stateful
    // widgets whose Lua dispose callbacks cancel sources on the loop.
    var loop = try event_loop.EventLoop.init(allocator);
    defer loop.deinit();
    var runtime = try runtime_mod.Runtime.init(
        allocator,
        log_backend.backend(),
        .{ .max_width = 100, .max_height = 40 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();

    try std.testing.expectEqual(@as(usize, 1), app.fs_events.items.len);
    try std.testing.expect(!app.fs_events.items[0].registered);
    app.bindRuntime(&runtime);
    defer app.unbindRuntime();
    try app.bindEventLoop(&loop);
    defer app.unbindEventLoop();
    try std.testing.expect(app.fs_events.items[0].registered);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "watched.txt", .data = "after\n" });

    const FsEventTest = struct {
        app: *App,
        ticks: u32 = 0,

        fn callback(ctx: *anyopaque, event_loop_instance: *event_loop.EventLoop, _: u64) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.ticks += 1;
            c.lua_getglobal(self.app.state, "fs_event_seen");
            const seen = c.lua_toboolean(self.app.state, -1) != 0;
            pop(self.app.state, 1);
            if (seen or self.ticks > 1000) event_loop_instance.quit();
        }
    };
    var context: FsEventTest = .{ .app = &app };
    try loop.addRepeatingTimer(1, &context, FsEventTest.callback);
    try loop.run();

    c.lua_getglobal(app.state, "fs_event_seen");
    defer pop(app.state, 1);
    try std.testing.expect(c.lua_toboolean(app.state, -1) != 0);
    c.lua_getglobal(app.state, "fs_event_path");
    defer pop(app.state, 1);
    const path = try stringFromStack(app.state, -1);
    try std.testing.expectEqualStrings(watched_path, path);
}

test "lua process spawn captures stdout and exit" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\local kw = require("keywork")
        \\local process = require("keywork.process")
        \\local loop = require("keywork.loop")
        \\
        \\spawn_done = false
        \\spawn_output = ""
        \\local App = kw.stateful({
        \\  init = function(self)
        \\    self.proc = process.spawn({
        \\      argv = { "/usr/bin/printf", "hello" },
        \\      stdout = "pipe",
        \\      stderr = "ignore",
        \\    })
        \\    local proc = self.proc
        \\    loop.spawn(function()
        \\      for chunk in proc:stdout() do
        \\        spawn_output = spawn_output .. chunk
        \\      end
        \\      local result = proc:wait()
        \\      spawn_done = result ~= nil and result.ok and result.code == 0
        \\    end)
        \\    spawn_cancel = function() proc:cancel() end
        \\  end,
        \\  dispose = function(self)
        \\    if self.proc then
        \\      self.proc:cancel()
        \\    end
        \\  end,
        \\  build = function(self, state)
        \\    return kw.text("spawn")
        \\  end,
        \\})
        \\return kw.app({ child = App({ key = "app" }) })
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "spawn.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "spawn.lua" });
    defer allocator.free(script_path);

    var app = try App.init(allocator, script_path);
    defer app.deinit();

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var log_backend: log_backend_mod.LogBackend = .{ .writer = &output.writer };
    // The loop must outlive the runtime: runtime deinit disposes stateful
    // widgets whose Lua dispose callbacks cancel sources on the loop.
    var loop = try event_loop.EventLoop.init(allocator);
    defer loop.deinit();
    var runtime = try runtime_mod.Runtime.init(
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

        fn callback(ctx: *anyopaque, event_loop_instance: *event_loop.EventLoop, _: u64) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.ticks += 1;
            c.lua_getglobal(self.app.state, "spawn_done");
            const done = c.lua_toboolean(self.app.state, -1) != 0;
            pop(self.app.state, 1);
            if (done or self.ticks > 1000) event_loop_instance.quit();
        }
    };

    app.bindRuntime(&runtime);
    defer app.unbindRuntime();
    try app.bindEventLoop(&loop);
    defer app.unbindEventLoop();
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

    c.lua_getglobal(app.state, "spawn_cancel");
    try std.testing.expectEqual(c.LUA_TFUNCTION, c.lua_type(app.state, -1));
    try std.testing.expectEqual(@as(c_int, 0), c.lua_pcall(app.state, 0, 0, 0));
}

test "lua process spawn reports a missing executable as nil, err" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\local kw = require("keywork")
        \\local process = require("keywork.process")
        \\spawn_result, spawn_err = process.spawn({
        \\  argv = { "keywork-test-no-such-binary" },
        \\})
        \\return kw.app({ child = kw.text("spawn") })
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "spawn-missing.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "spawn-missing.lua" });
    defer allocator.free(script_path);

    var app = try App.init(allocator, script_path);
    defer app.deinit();
    try app.ensureLoaded();

    c.lua_getglobal(app.state, "spawn_result");
    try std.testing.expectEqual(c.LUA_TNIL, c.lua_type(app.state, -1));
    pop(app.state, 1);
    c.lua_getglobal(app.state, "spawn_err");
    try std.testing.expectEqual(c.LUA_TSTRING, c.lua_type(app.state, -1));
    pop(app.state, 1);
    try std.testing.expectEqual(@as(usize, 0), app.processes.items.len);
}

test "lua fs_event reports a missing path as nil, err" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\local kw = require("keywork")
        \\local loop = require("keywork.loop")
        \\watch_result, watch_err = loop.fs_event("/nonexistent/keywork/test/path")
        \\return kw.app({ child = kw.text("fs_event") })
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fs-event-missing.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "fs-event-missing.lua" });
    defer allocator.free(script_path);

    var app = try App.init(allocator, script_path);
    defer app.deinit();

    // Registration is deferred until an event loop is bound, so bind first
    // to make the inotify failure surface synchronously during script load.
    var loop = try event_loop.EventLoop.init(allocator);
    defer loop.deinit();
    try app.bindEventLoop(&loop);
    defer app.unbindEventLoop();
    try app.ensureLoaded();

    c.lua_getglobal(app.state, "watch_result");
    try std.testing.expectEqual(c.LUA_TNIL, c.lua_type(app.state, -1));
    pop(app.state, 1);
    c.lua_getglobal(app.state, "watch_err");
    try std.testing.expectEqual(c.LUA_TSTRING, c.lua_type(app.state, -1));
    pop(app.state, 1);
    try std.testing.expectEqual(@as(usize, 0), app.fs_events.items.len);
}

test "lua process output produced before bind is queued for readers" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The child writes before an event loop exists; bind-time registration
    // drains the pipe into the stream queue, and a reader started after the
    // bind must still receive every chunk.
    const script =
        \\local kw = require("keywork")
        \\local process = require("keywork.process")
        \\local loop = require("keywork.loop")
        \\spawn_done = false
        \\spawn_output = ""
        \\proc = process.spawn({
        \\  argv = { "/usr/bin/printf", "hello" },
        \\  stdout = "pipe",
        \\})
        \\function start_reader()
        \\  loop.spawn(function()
        \\    for chunk in proc:stdout() do
        \\      spawn_output = spawn_output .. chunk
        \\    end
        \\    local result = proc:wait()
        \\    spawn_done = result ~= nil and result.ok and result.code == 0
        \\  end)
        \\end
        \\return kw.app({ child = kw.text("spawn") })
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "spawn-rebind.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "spawn-rebind.lua" });
    defer allocator.free(script_path);

    var app = try App.init(allocator, script_path);
    defer app.deinit();
    try app.ensureLoaded();
    try std.testing.expectEqual(@as(usize, 1), app.processes.items.len);

    const process = app.processes.items[0];
    var poll_fds = [_]std.posix.pollfd{.{
        .fd = process.stdout_pipe.fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 1), try std.posix.poll(&poll_fds, 1000));

    var loop = try event_loop.EventLoop.init(allocator);
    defer loop.deinit();
    try app.bindEventLoop(&loop);
    defer app.unbindEventLoop();
    try std.testing.expect(app.event_loop != null);
    try std.testing.expect(process.registered);
    // printf exits immediately, so bind-time drain reached EOF and queued
    // the output with no reader parked.
    try std.testing.expect(process.stdout_pipe.fd == invalid_fd);
    try std.testing.expect(process.stdout_pipe.stream.queue.items.len > 0);
    try std.testing.expect(process.pidfd != invalid_fd);

    c.lua_getglobal(app.state, "start_reader");
    try std.testing.expectEqual(@as(c_int, 0), c.lua_pcall(app.state, 0, 0, 0));

    const SpawnTest = struct {
        app: *App,
        ticks: usize = 0,

        fn callback(ctx: *anyopaque, event_loop_instance: *event_loop.EventLoop, _: u64) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.ticks += 1;
            c.lua_getglobal(self.app.state, "spawn_done");
            const done = c.lua_toboolean(self.app.state, -1) != 0;
            pop(self.app.state, 1);
            if (done or self.ticks > 1000) event_loop_instance.quit();
        }
    };
    var context: SpawnTest = .{ .app = &app };
    try loop.addRepeatingTimer(1, &context, SpawnTest.callback);
    try loop.run();

    c.lua_getglobal(app.state, "spawn_done");
    try std.testing.expect(c.lua_toboolean(app.state, -1) != 0);
    pop(app.state, 1);
    c.lua_getglobal(app.state, "spawn_output");
    defer pop(app.state, 1);
    const value = try stringFromStack(app.state, -1);
    try std.testing.expectEqualStrings("hello", value);
}

fn testUnixListener(path: []const u8) !i32 {
    var address: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = undefined };
    if (path.len >= address.path.len) return error.PathTooLong;
    @memset(&address.path, 0);
    @memcpy(address.path[0..path.len], path);
    const socket_result = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(socket_result) != .SUCCESS) return error.SocketFailed;
    const fd: i32 = @intCast(socket_result);
    errdefer _ = linux.close(fd);
    const address_len: linux.socklen_t = @intCast(@offsetOf(linux.sockaddr.un, "path") + path.len + 1);
    if (linux.errno(linux.bind(fd, @ptrCast(&address), address_len)) != .SUCCESS) return error.BindFailed;
    if (linux.errno(linux.listen(fd, 8)) != .SUCCESS) return error.ListenFailed;
    return fd;
}

fn testAccept(listener: i32) !i32 {
    const result = linux.accept4(listener, null, null, linux.SOCK.CLOEXEC);
    if (linux.errno(result) != .SUCCESS) return error.AcceptFailed;
    return @intCast(result);
}

test "lua loop.connect reports a missing socket path as nil, err" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\local kw = require("keywork")
        \\local loop = require("keywork.loop")
        \\sock_result, sock_err = loop.connect("/nonexistent/keywork/test.sock")
        \\return kw.app({ child = kw.text("connect") })
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "connect-missing.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "connect-missing.lua" });
    defer allocator.free(script_path);

    var app = try App.init(allocator, script_path);
    defer app.deinit();
    try app.ensureLoaded();

    c.lua_getglobal(app.state, "sock_result");
    try std.testing.expectEqual(c.LUA_TNIL, c.lua_type(app.state, -1));
    pop(app.state, 1);
    c.lua_getglobal(app.state, "sock_err");
    try std.testing.expectEqualStrings("FileNotFound", try stringFromStack(app.state, -1));
    pop(app.state, 1);
    try std.testing.expectEqual(@as(usize, 0), app.sockets.items.len);
}

test "lua socket streams chunks and finishes on peer EOF" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const socket_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "ipc.sock" });
    defer allocator.free(socket_path);
    const listener = try testUnixListener(socket_path);
    defer _ = linux.close(listener);

    // The script connects and writes synchronously from the main state (a
    // small write never parks), then a coroutine reads until peer EOF ends
    // the stream.
    const script = try std.fmt.allocPrint(allocator,
        \\local kw = require("keywork")
        \\local loop = require("keywork.loop")
        \\sock = assert(loop.connect("{s}"))
        \\assert(sock:write("ping"))
        \\received = ""
        \\done = false
        \\loop.spawn(function()
        \\  for chunk in sock:chunks() do
        \\    received = received .. chunk
        \\  end
        \\  closed_after = sock:closed()
        \\  done = true
        \\end)
        \\return kw.app({{ child = kw.text("socket") }})
        \\
    , .{socket_path});
    defer allocator.free(script);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "socket-stream.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "socket-stream.lua" });
    defer allocator.free(script_path);

    var app = try App.init(allocator, script_path);
    defer app.deinit();
    try app.ensureLoaded();
    try std.testing.expectEqual(@as(usize, 1), app.sockets.items.len);

    // The connection is already pending, and "ping" is already in flight.
    const conn = try testAccept(listener);
    var request: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), linux.read(conn, &request, request.len));
    try std.testing.expectEqualStrings("ping", &request);
    try std.testing.expectEqual(@as(usize, 4), linux.write(conn, "pong", 4));
    _ = linux.close(conn);

    var loop = try event_loop.EventLoop.init(allocator);
    defer loop.deinit();
    try app.bindEventLoop(&loop);
    defer app.unbindEventLoop();

    const SocketTest = struct {
        app: *App,
        ticks: u32 = 0,

        fn callback(ctx: *anyopaque, event_loop_instance: *event_loop.EventLoop, _: u64) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.ticks += 1;
            c.lua_getglobal(self.app.state, "done");
            const done = c.lua_toboolean(self.app.state, -1) != 0;
            pop(self.app.state, 1);
            if (done or self.ticks > 1000) event_loop_instance.quit();
        }
    };
    var context: SocketTest = .{ .app = &app };
    try loop.addRepeatingTimer(1, &context, SocketTest.callback);
    try loop.run();

    c.lua_getglobal(app.state, "done");
    try std.testing.expect(c.lua_toboolean(app.state, -1) != 0);
    pop(app.state, 1);
    c.lua_getglobal(app.state, "received");
    try std.testing.expectEqualStrings("pong", try stringFromStack(app.state, -1));
    pop(app.state, 1);
    c.lua_getglobal(app.state, "closed_after");
    try std.testing.expect(c.lua_toboolean(app.state, -1) != 0);
    pop(app.state, 1);
    // EOF closed the socket without canceling it; it no longer counts as
    // live async work.
    try std.testing.expect(!app.sockets.items[0].canceled);
    try std.testing.expectEqual(invalid_fd, app.sockets.items[0].fd);
    try std.testing.expect(!app.hasLiveAsyncResources());
}

test "lua socket close resumes a parked reader and ends iteration" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const socket_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "ipc.sock" });
    defer allocator.free(socket_path);
    const listener = try testUnixListener(socket_path);
    defer _ = linux.close(listener);

    // No event loop is bound, so the socket never registers and the reader
    // parks until close resumes it with no value, all synchronously.
    const script = try std.fmt.allocPrint(allocator,
        \\local kw = require("keywork")
        \\local loop = require("keywork.loop")
        \\local sock = assert(loop.connect("{s}"))
        \\stream_ended = false
        \\local reader = loop.spawn(function()
        \\  for _ in sock:chunks() do end
        \\  stream_ended = true
        \\end)
        \\assert(coroutine.status(reader) == "suspended")
        \\sock:close()
        \\assert(stream_ended)
        \\assert(coroutine.status(reader) == "dead")
        \\assert(sock:closed())
        \\-- Writing to a dead handle reports nil, err.
        \\local ok, err = sock:write("late")
        \\assert(ok == nil and err == "closed")
        \\-- next() on a dead handle ends iteration instead of parking.
        \\loop.spawn(function()
        \\  assert(sock:next() == nil)
        \\  dead_next_ok = true
        \\end)
        \\assert(dead_next_ok)
        \\return kw.app({{ child = kw.text("socket-close") }})
        \\
    , .{socket_path});
    defer allocator.free(script);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "socket-close.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "socket-close.lua" });
    defer allocator.free(script_path);

    var app = try App.init(allocator, script_path);
    defer app.deinit();
    try app.ensureLoaded();
    try std.testing.expectEqual(@as(usize, 1), app.sockets.items.len);
    try std.testing.expect(app.sockets.items[0].canceled);
}

test "lua socket write parks under backpressure and resumes when flushed" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const socket_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "ipc.sock" });
    defer allocator.free(socket_path);
    const listener = try testUnixListener(socket_path);
    defer _ = linux.close(listener);

    // 4 MiB exceeds the kernel socket buffer, so the coroutine writer must
    // park; a partial write on the main state must raise instead.
    const script = try std.fmt.allocPrint(allocator,
        \\local kw = require("keywork")
        \\local loop = require("keywork.loop")
        \\local big = string.rep("x", 4 * 1024 * 1024)
        \\total = #big
        \\sock = assert(loop.connect("{s}"))
        \\write_ok = false
        \\wrote = false
        \\loop.spawn(function()
        \\  write_ok = sock:write(big)
        \\  wrote = true
        \\end)
        \\local sock2 = assert(loop.connect("{s}"))
        \\local ok, err = pcall(sock2.write, sock2, big)
        \\main_write_raised = not ok and err:find("coroutine", 1, true) ~= nil
        \\sock2:close()
        \\return kw.app({{ child = kw.text("socket-write") }})
        \\
    , .{ socket_path, socket_path });
    defer allocator.free(script);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "socket-write.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "socket-write.lua" });
    defer allocator.free(script_path);

    var app = try App.init(allocator, script_path);
    defer app.deinit();
    try app.ensureLoaded();

    // The writer parked with unflushed bytes buffered.
    c.lua_getglobal(app.state, "wrote");
    try std.testing.expect(c.lua_toboolean(app.state, -1) == 0);
    pop(app.state, 1);
    c.lua_getglobal(app.state, "main_write_raised");
    try std.testing.expect(c.lua_toboolean(app.state, -1) != 0);
    pop(app.state, 1);
    try std.testing.expectEqual(@as(usize, 2), app.sockets.items.len);
    try std.testing.expect(app.sockets.items[0].sink.buffer.items.len > 0);

    const conn = try testAccept(listener);
    defer _ = linux.close(conn);
    const flags = linux.fcntl(conn, linux.F.GETFL, 0);
    _ = linux.fcntl(conn, linux.F.SETFL, flags | linux.SOCK.NONBLOCK);

    var loop = try event_loop.EventLoop.init(allocator);
    defer loop.deinit();
    try app.bindEventLoop(&loop);
    defer app.unbindEventLoop();

    const WriteTest = struct {
        app: *App,
        conn: i32,
        drained: usize = 0,
        ticks: u32 = 0,

        fn callback(ctx: *anyopaque, event_loop_instance: *event_loop.EventLoop, _: u64) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.ticks += 1;
            var buffer: [65536]u8 = undefined;
            while (true) {
                const result = linux.read(self.conn, &buffer, buffer.len);
                if (linux.errno(result) != .SUCCESS or result == 0) break;
                self.drained += result;
            }
            c.lua_getglobal(self.app.state, "wrote");
            const wrote = c.lua_toboolean(self.app.state, -1) != 0;
            pop(self.app.state, 1);
            if ((wrote and self.drained >= 4 * 1024 * 1024) or self.ticks > 5000) event_loop_instance.quit();
        }
    };
    var context: WriteTest = .{ .app = &app, .conn = conn };
    try loop.addRepeatingTimer(1, &context, WriteTest.callback);
    try loop.run();

    c.lua_getglobal(app.state, "write_ok");
    try std.testing.expect(c.lua_toboolean(app.state, -1) != 0);
    pop(app.state, 1);
    try std.testing.expectEqual(@as(usize, 4 * 1024 * 1024), context.drained);
    try std.testing.expectEqual(@as(usize, 0), app.sockets.items[0].sink.buffer.items.len);
}

test "lua process stdin roundtrips through cat under backpressure" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // 1 MiB exceeds the pipe buffer, so the writer coroutine parks at spawn
    // time (no event loop yet) and the flush happens after the loop binds.
    const script =
        \\local kw = require("keywork")
        \\local process = require("keywork.process")
        \\local loop = require("keywork.loop")
        \\local total = 1024 * 1024
        \\local proc = assert(process.spawn({
        \\  argv = { "/usr/bin/cat" },
        \\  stdin = "pipe",
        \\  stdout = "pipe",
        \\}))
        \\write_ok = false
        \\received = 0
        \\done = false
        \\loop.spawn(function()
        \\  write_ok = proc:write(string.rep("x", total))
        \\  proc:close_stdin()
        \\end)
        \\loop.spawn(function()
        \\  for chunk in proc:stdout() do
        \\    received = received + #chunk
        \\  end
        \\  local result = proc:wait()
        \\  done = result ~= nil and result.ok and received == total
        \\end)
        \\return kw.app({ child = kw.text("stdin") })
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "stdin-roundtrip.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "stdin-roundtrip.lua" });
    defer allocator.free(script_path);

    var app = try App.init(allocator, script_path);
    defer app.deinit();
    try app.ensureLoaded();
    try std.testing.expectEqual(@as(usize, 1), app.processes.items.len);
    // The writer parked with unflushed bytes buffered before the loop bound.
    try std.testing.expect(app.processes.items[0].stdin_sink.buffer.items.len > 0);

    var loop = try event_loop.EventLoop.init(allocator);
    defer loop.deinit();
    try app.bindEventLoop(&loop);
    defer app.unbindEventLoop();

    const StdinTest = struct {
        app: *App,
        ticks: u32 = 0,

        fn callback(ctx: *anyopaque, event_loop_instance: *event_loop.EventLoop, _: u64) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.ticks += 1;
            c.lua_getglobal(self.app.state, "done");
            const done = c.lua_toboolean(self.app.state, -1) != 0;
            pop(self.app.state, 1);
            if (done or self.ticks > 5000) event_loop_instance.quit();
        }
    };
    var context: StdinTest = .{ .app = &app };
    try loop.addRepeatingTimer(1, &context, StdinTest.callback);
    try loop.run();

    c.lua_getglobal(app.state, "done");
    try std.testing.expect(c.lua_toboolean(app.state, -1) != 0);
    pop(app.state, 1);
    c.lua_getglobal(app.state, "write_ok");
    try std.testing.expect(c.lua_toboolean(app.state, -1) != 0);
    pop(app.state, 1);
    try std.testing.expectEqual(invalid_fd, app.processes.items[0].stdin_fd);
    try std.testing.expectEqual(@as(usize, 0), app.processes.items[0].stdin_sink.buffer.items.len);
}

test "lua process stdin write semantics without an event loop" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // sleep never reads stdin, so the pipe fills and a large main-state
    // write must raise instead of parking; everything here runs
    // synchronously at load time.
    const script =
        \\local kw = require("keywork")
        \\local process = require("keywork.process")
        \\local proc = assert(process.spawn({
        \\  argv = { "/usr/bin/sleep", "5" },
        \\  stdin = "pipe",
        \\}))
        \\-- A small write completes synchronously even on the main state.
        \\assert(proc:write("hello"))
        \\local ok, err = pcall(proc.write, proc, string.rep("x", 4 * 1024 * 1024))
        \\main_write_raised = not ok and err:find("coroutine", 1, true) ~= nil
        \\proc:close_stdin()
        \\proc:close_stdin() -- idempotent
        \\local ok2, err2 = proc:write("late")
        \\closed_write = ok2 == nil and err2 == "closed"
        \\-- Writing to a process spawned without stdin = "pipe" is misuse.
        \\local proc2 = assert(process.spawn({ argv = { "/usr/bin/sleep", "5" } }))
        \\local ok3, err3 = pcall(proc2.write, proc2, "data")
        \\nopipe_raised = not ok3 and err3:find("stdin", 1, true) ~= nil
        \\proc2:close_stdin() -- no-op without a stdin pipe
        \\proc:cancel()
        \\proc2:cancel()
        \\-- write on a canceled (dead) handle reports nil, err.
        \\local ok4, err4 = proc:write("dead")
        \\dead_write = ok4 == nil and err4 == "closed"
        \\return kw.app({ child = kw.text("stdin-sync") })
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "stdin-sync.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "stdin-sync.lua" });
    defer allocator.free(script_path);

    var app = try App.init(allocator, script_path);
    defer app.deinit();
    try app.ensureLoaded();

    for ([_][:0]const u8{ "main_write_raised", "closed_write", "nopipe_raised", "dead_write" }) |global| {
        c.lua_getglobal(app.state, global.ptr);
        std.testing.expect(c.lua_toboolean(app.state, -1) != 0) catch |err| {
            std.debug.print("failed global: {s}\n", .{global});
            return err;
        };
        pop(app.state, 1);
    }
}
