//! LuaJIT application host and native Keywork bindings.

const std = @import("std");
const keywork = @import("../ui.zig");
const log_backend_mod = @import("../backend/log.zig");
const event_loop = @import("../linux/event_loop.zig");
const icon_theme = @import("../linux/icon_theme.zig");
const lua_config = @import("config.zig");
const lua_process = @import("process.zig");
const lua_dbus = @import("dbus.zig");
const lua_loop = @import("loop.zig");
const lua_value = @import("value.zig");
const lua_widget = @import("widget.zig");
const runtime_mod = @import("../ui/runtime.zig");
const c = @import("luajit_c");

const linux = std.os.linux;
const State = keywork.AppContext;
const BuildScope = keywork.BuildScope;

const invalid_fd: i32 = -1;
const LuaProcess = lua_process.LuaProcess;
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
    script_dirty: bool = true,
    fd_watches: std.ArrayList(*FdWatch) = .empty,
    fs_events: std.ArrayList(*FsEvent) = .empty,
    timers: std.ArrayList(*LuaTimer) = .empty,
    processes: std.ArrayList(*LuaProcess) = .empty,
    dbus_buses: std.ArrayList(*DbusBus) = .empty,
    dbus_host: lua_dbus.Host = undefined,
    loop_host: lua_loop.Host = undefined,
    event_loop: ?*event_loop.EventLoop = null,
    runtime: ?*runtime_mod.Runtime = null,
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
        installUi(lua_state);

        return .{
            .allocator = allocator,
            .path = path_z,
            .chunk_name = chunk_name,
            .state = lua_state,
            .icon_cache = .init(allocator),
        };
    }

    pub fn deinit(self: *App) void {
        for (self.fd_watches.items) |watch| watch.destroy(self.allocator, self.state);
        self.fd_watches.deinit(self.allocator);
        for (self.fs_events.items) |fs_event| fs_event.destroy(self.allocator, self.state);
        self.fs_events.deinit(self.allocator);
        for (self.timers.items) |timer| timer.destroy(self.allocator, self.state);
        self.timers.deinit(self.allocator);
        for (self.processes.items) |process| process.destroy(self.allocator, self.state);
        self.processes.deinit(self.allocator);
        for (self.dbus_buses.items) |bus| bus.destroy(self.allocator, self.state);
        self.dbus_buses.deinit(self.allocator);
        if (self.script_ref >= 0) c.luaL_unref(self.state, c.LUA_REGISTRYINDEX, self.script_ref);
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
        for (self.fs_events.items) |fs_event| try fs_event.register();
        for (self.timers.items) |timer| try timer.register();
        for (self.processes.items) |process| try self.registerProcess(process);
        for (self.dbus_buses.items) |bus| try bus.register();
    }

    pub fn bindRuntime(self: *App, runtime: *runtime_mod.Runtime) void {
        self.runtime = runtime;
    }

    pub fn unbindRuntime(self: *App) void {
        self.runtime = null;
    }

    pub fn unbindEventLoop(self: *App) void {
        const loop = self.event_loop orelse return;
        if (self.script_watch) |watch| loop.removeFileWatch(watch);
        self.script_watch = null;
        for (self.fd_watches.items) |watch| watch.unregister(loop);
        for (self.fs_events.items) |fs_event| fs_event.unregister(loop);
        for (self.timers.items) |timer| timer.unregister(loop);
        for (self.processes.items) |process| process.unregister(loop);
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

    pub fn buildWidget(self: *App, allocator: std.mem.Allocator, runtime_state: State) !keywork.Widget {
        try self.ensureLoaded();

        const icon_scale: f32 = blk: {
            const runtime = self.runtime orelse break :blk 1;
            const value = runtime.backend.scale();
            break :blk if (std.math.isFinite(value) and value > 0) value else 1;
        };

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

    fn reloadScript(self: *App) !void {
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
        errdefer config.deinit(self.allocator);
        const script_ref = c.luaL_ref(self.state, c.LUA_REGISTRYINDEX);
        if (self.script_ref >= 0) c.luaL_unref(self.state, c.LUA_REGISTRYINDEX, self.script_ref);
        self.window_config.deinit(self.allocator);
        self.window_config = config;
        self.script_ref = script_ref;
        self.script_dirty = false;
        _ = c.lua_gc(self.state, c.LUA_GCCOLLECT, 0);
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
        return self.buildWidget(scope.allocator, runtime_state);
    }

    fn widgetHost(self: *App) lua_widget.Host {
        return .{ .ptr = self, .invalidate_state_fn = invalidateWidgetState };
    }

    fn invalidateWidgetState(ptr: *anyopaque) !void {
        const self: *App = @ptrCast(@alignCast(ptr));
        const runtime = self.runtime orelse return;
        try runtime.invalidateState();
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
        errdefer c.luaL_unref(self.state, c.LUA_REGISTRYINDEX, ref);
        const watch = try self.allocator.create(FdWatch);
        errdefer self.allocator.destroy(watch);
        watch.* = .{ .host = self.loopHost(), .fd = fd, .events = events, .ref = ref };

        try self.fd_watches.append(self.allocator, watch);
        errdefer _ = self.fd_watches.pop();
        try watch.register();
        return watch;
    }

    fn addFsEvent(self: *App, path: []const u8, ref: c_int) !*FsEvent {
        errdefer c.luaL_unref(self.state, c.LUA_REGISTRYINDEX, ref);
        const fs_event = try self.allocator.create(FsEvent);
        errdefer self.allocator.destroy(fs_event);
        fs_event.* = .{
            .host = self.loopHost(),
            .path = try self.allocator.dupe(u8, path),
            .ref = ref,
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

    fn addProcess(self: *App, spec: lua_process.SpawnSpec, callbacks: *lua_process.Callbacks) !*LuaProcess {
        var spawned = try LuaProcess.spawn(self.processHost(), spec, callbacks.*);
        callbacks.* = .{};
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

    fn addDbusBus(self: *App, kind: lua_dbus.Kind) !*DbusBus {
        const bus = try DbusBus.create(self.dbusHost(), kind);
        errdefer bus.destroy(self.allocator, self.state);
        try self.dbus_buses.append(self.allocator, bus);
        errdefer _ = self.dbus_buses.pop();
        try bus.register();
        return bus;
    }

    fn removeDbusBus(self: *App, bus: *DbusBus) void {
        for (self.dbus_buses.items, 0..) |item, index| {
            if (item == bus) {
                _ = self.dbus_buses.swapRemove(index);
                return;
            }
        }
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
    const runtime = app.runtime orelse return;
    try runtime.invalidate();
}

fn loopHostAddFdWatch(ptr: *anyopaque, fd: i32, events: u32, ref: c_int) anyerror!*FdWatch {
    const app: *App = @ptrCast(@alignCast(ptr));
    return app.addFdWatch(fd, events, ref);
}

fn loopHostAddFsEvent(ptr: *anyopaque, path: []const u8, ref: c_int) anyerror!*FsEvent {
    const app: *App = @ptrCast(@alignCast(ptr));
    return app.addFsEvent(path, ref);
}

fn loopHostAddTimer(ptr: *anyopaque, delay_ms: u64, interval_ms: u64, ref: c_int) anyerror!*LuaTimer {
    const app: *App = @ptrCast(@alignCast(ptr));
    return app.addTimerWithDelay(delay_ms, interval_ms, ref);
}

const dbus_host_vtable: lua_dbus.Host.VTable = .{
    .allocator = dbusHostAllocator,
    .luaState = dbusHostLuaState,
    .eventLoop = dbusHostEventLoop,
    .addBus = dbusHostAddBus,
    .removeBus = dbusHostRemoveBus,
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

fn dbusHostRemoveBus(ptr: *anyopaque, bus: *DbusBus) void {
    const app: *App = @ptrCast(@alignCast(ptr));
    app.removeDbusBus(bus);
}

fn scriptChanged(ctx: *anyopaque, _: *event_loop.EventLoop, path: []const u8, mask: u32, _: ?[]const u8) !void {
    const app: *App = @ptrCast(@alignCast(ctx));
    std.log.scoped(.keywork_luajit).info("reload requested for {s} mask=0x{x}", .{ path, mask });
    app.script_dirty = true;
    const runtime = app.runtime orelse return;
    try runtime.invalidate();
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

fn installUi(lua_state: *c.lua_State) void {
    addPackagePath(lua_state, "src/lua/?.lua");

    // Fallback loader appended after the standard searchers so a
    // checkout's src/lua/ui.lua wins during development while shipped
    // scripts resolve require("ui") anywhere.
    c.lua_getfield(lua_state, c.LUA_GLOBALSINDEX, "package");
    const package_table = c.lua_gettop(lua_state);
    c.lua_getfield(lua_state, package_table, "loaders");
    const loaders_table = c.lua_gettop(lua_state);
    const loader_count: c_int = @intCast(c.lua_objlen(lua_state, loaders_table));
    c.lua_pushcclosure(lua_state, embeddedUiLoader, 0);
    c.lua_rawseti(lua_state, loaders_table, loader_count + 1);
    pop(lua_state, 2);
}

fn embeddedUiLoader(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    var len: usize = 0;
    const name_ptr = c.luaL_checklstring(lua_state, 1, &len);
    const name = name_ptr[0..len];
    if (!std.mem.eql(u8, name, "ui") and !std.mem.eql(u8, name, "kw")) {
        const message = "\n\tno embedded keywork module";
        c.lua_pushlstring(lua_state, message.ptr, message.len);
        return 1;
    }
    if (c.luaL_loadbuffer(lua_state, embedded_ui_source.ptr, embedded_ui_source.len, "@ui.lua") != 0) {
        return c.lua_error(lua_state);
    }
    if (std.mem.eql(u8, name, "kw")) c.lua_pushcclosure(lua_state, embeddedKwLoader, 1);
    return 1;
}

fn embeddedKwLoader(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    c.lua_pushvalue(lua_state, c.lua_upvalueindex(1));
    return kwModuleLoader(lua_state);
}

fn installKeyworkModule(lua_state: *c.lua_State, app: *App) void {
    c.lua_getfield(lua_state, c.LUA_GLOBALSINDEX, "package");
    const package_table = c.lua_gettop(lua_state);
    c.lua_getfield(lua_state, package_table, "preload");
    const preload_table = c.lua_gettop(lua_state);
    c.lua_pushlightuserdata(lua_state, app);
    c.lua_pushcclosure(lua_state, keyworkModuleLoader, 1);
    c.lua_setfield(lua_state, preload_table, "keywork");
    c.lua_pushlightuserdata(lua_state, app);
    c.lua_pushcclosure(lua_state, kwPreloadLoader, 1);
    c.lua_setfield(lua_state, preload_table, "kw");
    pop(lua_state, 2);
}

fn kwPreloadLoader(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    if (c.luaL_loadbuffer(lua_state, embedded_ui_source.ptr, embedded_ui_source.len, "@ui.lua") != 0) return c.lua_error(lua_state);
    return kwModuleLoader(lua_state);
}

fn kwModuleLoader(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    if (c.lua_pcall(lua_state, 0, 1, 0) != 0) return c.lua_error(lua_state);
    const kw_table = c.lua_gettop(lua_state);

    c.lua_getglobal(lua_state, "require");
    c.lua_pushliteral(lua_state, "keywork");
    if (c.lua_pcall(lua_state, 1, 1, 0) != 0) return c.lua_error(lua_state);
    const native_table = c.lua_gettop(lua_state);

    c.lua_pushnil(lua_state);
    while (c.lua_next(lua_state, native_table) != 0) {
        c.lua_pushvalue(lua_state, -2);
        c.lua_insert(lua_state, -2);
        c.lua_settable(lua_state, kw_table);
    }
    pop(lua_state, 1);
    return 1;
}

fn keyworkModuleLoader(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const app: *App = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    c.lua_createtable(lua_state, 0, 5);
    const table = c.lua_gettop(lua_state);

    c.lua_createtable(lua_state, 0, 4);
    const loop_table = c.lua_gettop(lua_state);
    app.loop_host = app.loopHost();
    lua_loop.installResourceApis(lua_state, loop_table, &app.loop_host);
    c.lua_pushlightuserdata(lua_state, app);
    c.lua_pushcclosure(lua_state, luaSpawn, 1);
    c.lua_setfield(lua_state, loop_table, "spawn");
    c.lua_setfield(lua_state, table, "loop");

    app.dbus_host = app.dbusHost();
    lua_dbus.pushModule(lua_state, &app.dbus_host);
    c.lua_setfield(lua_state, table, "dbus");

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
    c.lua_setfield(lua_state, table, "log");

    c.lua_pushlightuserdata(lua_state, app);
    c.lua_pushcclosure(lua_state, luaInvalidate, 1);
    c.lua_setfield(lua_state, table, "invalidate");
    return 1;
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
    c.luaL_checktype(lua_state, 2, c.LUA_TTABLE);

    const argv = lua_process.parseArgv(lua_state, app.allocator, 1) catch |err| {
        std.log.scoped(.keywork_luajit).warn("spawn argv failed: {}", .{err});
        return c.luaL_error(lua_state, "invalid spawn argv");
    };
    defer lua_process.freeArgv(app.allocator, argv);

    var callbacks: lua_process.Callbacks = .{};
    callbacks.stdout_ref = lua_process.tableFunctionRef(lua_state, 2, "stdout") catch -1;
    callbacks.stderr_ref = lua_process.tableFunctionRef(lua_state, 2, "stderr") catch -1;
    callbacks.exit_ref = lua_process.tableFunctionRef(lua_state, 2, "exit") catch -1;

    const spec: lua_process.SpawnSpec = .{
        .argv = argv,
        .stdout_pipe = std.mem.eql(u8, lua_process.stringField(lua_state, 1, "stdout") catch "ignore", "pipe"),
        .stderr_pipe = std.mem.eql(u8, lua_process.stringField(lua_state, 1, "stderr") catch "ignore", "pipe"),
    };
    const process = app.addProcess(spec, &callbacks) catch |err| {
        callbacks.unref(lua_state);
        std.log.scoped(.keywork_luajit).warn("loop.spawn failed: {}", .{err});
        return c.luaL_error(lua_state, "loop.spawn failed");
    };
    lua_process.pushHandle(lua_state, process);
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

test "script must return a valid kw.app root" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cases = [_]struct {
        name: []const u8,
        script: []const u8,
    }{
        .{ .name = "widget.lua", .script = "local kw = require('kw'); return kw.text('not an app')\n" },
        .{ .name = "option.lua", .script = "local kw = require('kw'); return kw.app({ width = 'wide', child = kw.text('x') })\n" },
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

test "lua stateful widget set_state rebuilds retained subtree" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\local kw = require("kw")
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
        \\local kw = require("kw")
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
        \\local kw = require("kw")
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
        \\local kw = require("kw")
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
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "fill_rect x=0 y=0 w=240 h=32 color=#ff223344") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "text x=12 y=8 value=\"Name\" color=#ff445566") != null);
}

test "lua flexible and main_align lay out through the parser" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\local kw = require("kw")
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
        \\local kw = require("kw")
        \\
        \\fs_event_seen = false
        \\fs_event_path = ""
        \\local App = kw.stateful({{
        \\  init = function(self)
        \\    self.watch = kw.loop.fs_event({{ path = "{s}" }}, function(event)
        \\      fs_event_seen = event.change
        \\      fs_event_path = event.path
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

test "lua loop spawn captures stdout and exit" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\local kw = require("kw")
        \\
        \\spawn_done = false
        \\spawn_output = ""
        \\local App = kw.stateful({
        \\  init = function(self)
        \\    self.proc = kw.loop.spawn({
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
        \\    spawn_cancel = self.proc.cancel
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

test "lua process survives failed event loop bind" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\local kw = require("kw")
        \\local first_chunk = true
        \\spawn_done = false
        \\kw.loop.spawn({
        \\  argv = { "/usr/bin/printf", "hello" },
        \\  stdout = "pipe",
        \\}, {
        \\  stdout = function(chunk)
        \\    if first_chunk then
        \\      first_chunk = false
        \\      error("fail initial bind")
        \\    end
        \\  end,
        \\  exit = function(result)
        \\    spawn_done = result.ok and result.code == 0
        \\  end,
        \\})
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
    try std.testing.expectError(error.LuaCallbackFailed, app.bindEventLoop(&loop));
    try std.testing.expect(app.event_loop == null);
    try std.testing.expect(!process.registered);
    try std.testing.expect(process.stdout_pipe.fd != invalid_fd);
    try std.testing.expect(process.pidfd != invalid_fd);

    try app.bindEventLoop(&loop);
    defer app.unbindEventLoop();
    try std.testing.expect(process.registered);

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
    defer pop(app.state, 1);
    try std.testing.expect(c.lua_toboolean(app.state, -1) != 0);
}
