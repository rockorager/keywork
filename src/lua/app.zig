//! LuaJIT application host and native Keywork bindings.

const std = @import("std");
const app_windows = @import("../app/windows.zig");
const keywork = @import("../ui.zig");
const log_backend_mod = @import("../backend/log.zig");
const event_loop = @import("../linux/event_loop.zig");
const icon_theme = @import("../linux/icon_theme.zig");
const linux_syscall = @import("../linux/syscall.zig");
const lua_config = @import("config.zig");
const lua_process = @import("process.zig");
const lua_dbus = @import("dbus.zig");
const lua_json = @import("json.zig");
const lua_loop = @import("loop.zig");
const lua_pipewire = @import("pipewire.zig");
const lua_socket = @import("socket.zig");
const lua_storybook = @import("storybook.zig");
const lua_task = @import("task.zig");
const lua_value = @import("value.zig");
const lua_image = @import("image.zig");
const lua_widget = @import("widget.zig");
const lua_xdg = @import("xdg.zig");
const platform_mod = @import("../app/platform.zig");
const runtime_mod = @import("../ui/runtime.zig");
const c = @import("luajit_c");

const linux = std.os.linux;
const State = keywork.AppContext;
const BuildScope = keywork.BuildScope;

const invalid_fd: i32 = -1;
const LuaProcess = lua_process.LuaProcess;
const LuaSocket = lua_socket.LuaSocket;
const DbusBus = lua_dbus.Bus;
const PipeWireConnection = lua_pipewire.Connection;
const FdWatch = lua_loop.FdWatch;
const FsEvent = lua_loop.FsEvent;
const LuaTimer = lua_loop.LuaTimer;
const Channel = lua_loop.Channel;
const LuaTask = lua_task.LuaTask;
const LuaScope = lua_task.LuaScope;
const pop = lua_value.pop;
const stringFromStack = lua_value.stringFromStack;

pub const WindowConfig = lua_config.Config;

pub const RootKind = enum {
    application,
    storybook,
};

pub const App = struct {
    allocator: std.mem.Allocator,
    path: [:0]u8,
    /// Chunk name passed to the Lua loader ("@" ++ path) so stack
    /// traces point at the script file.
    chunk_name: [:0]u8,
    root_kind: RootKind = .application,
    storybook_browser: bool = false,
    window_config: WindowConfig = .{},
    storybook_catalog: ?lua_storybook.Catalog = null,
    selected_story_id: ?[]u8 = null,
    state: *c.lua_State,
    script_ref: c_int = -1,
    browser_ref: c_int = -1,
    start_ref: c_int = -1,
    stop_ref: c_int = -1,
    script_dirty: bool = true,
    lifecycle_started: bool = false,
    quit_requested: bool = false,
    fd_watches: std.ArrayList(*FdWatch) = .empty,
    fs_events: std.ArrayList(*FsEvent) = .empty,
    timers: std.ArrayList(*LuaTimer) = .empty,
    channels: std.ArrayList(*Channel) = .empty,
    processes: std.ArrayList(*LuaProcess) = .empty,
    sockets: std.ArrayList(*LuaSocket) = .empty,
    dbus_buses: std.ArrayList(*DbusBus) = .empty,
    pipewire_connections: std.ArrayList(*PipeWireConnection) = .empty,
    tasks: std.ArrayList(*LuaTask) = .empty,
    scopes: std.ArrayList(*LuaScope) = .empty,
    /// Widget scopes whose cancellation is deferred to the next loop turn,
    /// so disposing a widget never re-enters Lua mid-reconciliation.
    pending_scope_cancels: std.ArrayList(*LuaScope) = .empty,
    scope_cancel_timer: ?*event_loop.EventLoop.Timer = null,
    dbus_host: lua_dbus.Host = undefined,
    loop_host: lua_loop.Host = undefined,
    pipewire_host: lua_pipewire.Host = undefined,
    socket_host: lua_socket.Host = undefined,
    event_loop: ?*event_loop.EventLoop = null,
    invalidator: ?runtime_mod.Invalidator = null,
    /// Desktop services (clipboard, activation tokens, interactive
    /// move/resize) bridged from the windowing backend; null on
    /// headless backends.
    platform: ?platform_mod.Platform = null,
    /// Registry refs of the child widget tables from the last window-set
    /// build, keyed by window id (keys owned by `allocator`).
    window_children: std.StringHashMapUnmanaged(c_int) = .empty,
    script_watch: ?*event_loop.EventLoop.FileWatch = null,
    icon_cache: icon_theme.Cache,
    png_dims: lua_image.DimsCache,

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
        installScriptModuleRoots(lua_state, allocator, path) catch |err| {
            std.log.scoped(.keywork_luajit).warn("script module roots not installed: {}", .{err});
        };

        return .{
            .allocator = allocator,
            .path = path_z,
            .chunk_name = chunk_name,
            .state = lua_state,
            .icon_cache = .init(allocator),
            .png_dims = .init(allocator),
        };
    }

    pub fn initStorybook(allocator: std.mem.Allocator, path: []const u8) !App {
        var app = try init(allocator, path);
        app.root_kind = .storybook;
        return app;
    }

    pub fn initStorybookBrowser(allocator: std.mem.Allocator, path: []const u8) !App {
        var app = try initStorybook(allocator, path);
        app.storybook_browser = true;
        return app;
    }

    pub fn deinit(self: *App) void {
        self.stopLifecycleLog();
        // Scopes and tasks go first: destroying a task cancels the
        // resources it adopted, which must still be alive. The per-type
        // destroy loops below then reclaim whatever remains.
        for (self.scopes.items) |scope| scope.destroy(self.allocator, self.state);
        self.scopes.deinit(self.allocator);
        for (self.tasks.items) |task| task.destroy(self.allocator, self.state);
        self.tasks.deinit(self.allocator);
        for (self.fd_watches.items) |watch| watch.destroy(self.allocator, self.state);
        self.fd_watches.deinit(self.allocator);
        for (self.fs_events.items) |fs_event| fs_event.destroy(self.allocator, self.state);
        self.fs_events.deinit(self.allocator);
        for (self.timers.items) |timer| timer.destroy(self.allocator, self.state);
        self.timers.deinit(self.allocator);
        for (self.channels.items) |channel| channel.destroy(self.allocator, self.state);
        self.channels.deinit(self.allocator);
        for (self.processes.items) |process| process.destroy(self.allocator, self.state);
        self.processes.deinit(self.allocator);
        for (self.sockets.items) |socket| socket.destroy(self.allocator, self.state);
        self.sockets.deinit(self.allocator);
        for (self.dbus_buses.items) |bus| bus.destroy(self.allocator, self.state);
        self.dbus_buses.deinit(self.allocator);
        for (self.pipewire_connections.items) |connection| connection.destroy(self.allocator, self.state);
        self.pipewire_connections.deinit(self.allocator);
        self.pending_scope_cancels.deinit(self.allocator);
        self.releaseWindowChildren(&self.window_children);
        if (self.script_ref >= 0) c.luaL_unref(self.state, c.LUA_REGISTRYINDEX, self.script_ref);
        if (self.browser_ref >= 0) c.luaL_unref(self.state, c.LUA_REGISTRYINDEX, self.browser_ref);
        if (self.start_ref >= 0) c.luaL_unref(self.state, c.LUA_REGISTRYINDEX, self.start_ref);
        if (self.stop_ref >= 0) c.luaL_unref(self.state, c.LUA_REGISTRYINDEX, self.stop_ref);
        c.lua_close(self.state);
        self.icon_cache.deinit();
        self.png_dims.deinit();
        if (self.storybook_catalog) |*catalog| catalog.deinit(self.allocator);
        if (self.selected_story_id) |id| self.allocator.free(id);
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
        for (self.pipewire_connections.items) |connection| try connection.register();
        if (self.pending_scope_cancels.items.len > 0) try self.armScopeCancelTimer(loop);
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

    pub fn bindPlatform(self: *App, platform: platform_mod.Platform) void {
        self.platform = platform;
    }

    pub fn unbindPlatform(self: *App) void {
        self.platform = null;
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
        if (self.scope_cancel_timer) |timer| loop.removeTimer(timer);
        self.scope_cancel_timer = null;
        for (self.fd_watches.items) |watch| watch.unregister(loop);
        for (self.fs_events.items) |fs_event| fs_event.unregister(loop);
        for (self.timers.items) |timer| timer.unregister(loop);
        for (self.processes.items) |process| process.unregister(loop);
        for (self.sockets.items) |socket| socket.unregister(loop);
        for (self.dbus_buses.items) |bus| bus.unregister();
        for (self.pipewire_connections.items) |connection| connection.unregister(loop);
        self.event_loop = null;
    }

    pub fn bindRuntimeOpaque(ctx: *anyopaque, runtime: *runtime_mod.Runtime) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.bindRuntime(runtime);
    }

    pub fn bindInvalidatorOpaque(ctx: *anyopaque, invalidator: runtime_mod.Invalidator) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.bindInvalidator(invalidator);
    }

    pub fn bindPlatformOpaque(ctx: *anyopaque, platform: platform_mod.Platform) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.bindPlatform(platform);
    }

    pub fn unbindPlatformOpaque(ctx: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.unbindPlatform();
    }

    pub fn unbindRuntimeOpaque(ctx: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.unbindRuntime();
    }

    pub fn bindEventLoopOpaque(ctx: *anyopaque, loop: *event_loop.EventLoop) anyerror!void {
        const self: *App = @ptrCast(@alignCast(ctx));
        try self.bindEventLoop(loop);
    }

    pub fn unbindEventLoopOpaque(ctx: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.unbindEventLoop();
    }

    pub fn shouldRunHeadlessOpaque(ctx: *anyopaque) bool {
        const self: *App = @ptrCast(@alignCast(ctx));
        return self.hasLiveAsyncResources();
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
        for (self.pipewire_connections.items) |connection| if (!connection.closed) return true;
        return false;
    }

    pub fn buildWidget(self: *App, allocator: std.mem.Allocator, runtime_state: State, render_scale: f32) !keywork.Widget {
        return self.buildWidgetWithInvalidator(allocator, runtime_state, render_scale, null);
    }

    pub fn storyCatalog(self: *App) !*const lua_storybook.Catalog {
        try self.ensureLoaded();
        return if (self.storybook_catalog) |*catalog| catalog else error.NotStorybook;
    }

    pub fn selectStory(self: *App, id: []const u8) !void {
        const catalog = try self.storyCatalog();
        _ = catalog.find(id) orelse return error.UnknownStory;
        const selected = try self.allocator.dupe(u8, id);
        if (self.selected_story_id) |previous| self.allocator.free(previous);
        self.selected_story_id = selected;
    }

    fn buildWidgetWithInvalidator(
        self: *App,
        allocator: std.mem.Allocator,
        runtime_state: State,
        render_scale: f32,
        state_invalidator: ?keywork.Widget.Callback,
    ) !keywork.Widget {
        try self.ensureLoaded();
        if (self.root_kind == .storybook) {
            if (self.storybook_browser) return self.buildStorybookBrowser(allocator, runtime_state, render_scale, state_invalidator);
            return self.buildSelectedStory(allocator, runtime_state, render_scale, state_invalidator);
        }

        c.lua_settop(self.state, 0);
        c.lua_rawgeti(self.state, c.LUA_REGISTRYINDEX, self.script_ref);
        c.lua_getfield(self.state, -1, "child");
        const widget = try self.parseWidgetAtTop(allocator, runtime_state, render_scale, state_invalidator);
        c.lua_settop(self.state, 0);
        return widget;
    }

    fn buildStorybookBrowser(
        self: *App,
        allocator: std.mem.Allocator,
        runtime_state: State,
        render_scale: f32,
        state_invalidator: ?keywork.Widget.Callback,
    ) !keywork.Widget {
        if (self.browser_ref < 0) return error.StorybookBrowserMissing;

        c.lua_settop(self.state, 0);
        defer c.lua_settop(self.state, 0);
        c.lua_rawgeti(self.state, c.LUA_REGISTRYINDEX, self.browser_ref);
        return self.parseWidgetAtTop(allocator, runtime_state, render_scale, state_invalidator);
    }

    fn buildSelectedStory(
        self: *App,
        allocator: std.mem.Allocator,
        runtime_state: State,
        render_scale: f32,
        state_invalidator: ?keywork.Widget.Callback,
    ) !keywork.Widget {
        const selected_id = self.selected_story_id orelse return error.StoryNotSelected;
        const catalog = if (self.storybook_catalog) |*value| value else return error.NotStorybook;
        const story = catalog.find(selected_id) orelse return error.UnknownStory;

        c.lua_settop(self.state, 0);
        defer c.lua_settop(self.state, 0);
        c.lua_rawgeti(self.state, c.LUA_REGISTRYINDEX, self.script_ref);
        c.lua_getfield(self.state, -1, "stories");
        c.lua_rawgeti(self.state, -1, @intCast(story.index));
        c.lua_getfield(self.state, -1, "render");
        if (c.lua_type(self.state, -1) != c.LUA_TFUNCTION) return error.StoryRenderMissing;
        lua_widget.pushRuntimeState(self.state, runtime_state);
        if (c.lua_pcall(self.state, 1, 1, 0) != 0) return self.failWithLuaError(error.StoryRenderFailed);
        return self.parseWidgetAtTop(allocator, runtime_state, render_scale, state_invalidator);
    }

    fn parseWidgetAtTop(self: *App, allocator: std.mem.Allocator, runtime_state: State, render_scale: f32, state_invalidator: ?keywork.Widget.Callback) !keywork.Widget {
        const icon_scale: f32 = if (std.math.isFinite(render_scale) and render_scale > 0) render_scale else 1;
        const widget = try lua_widget.parse(self.widgetHost(state_invalidator), self.state, allocator, allocator, runtime_state, .{
            .icon_cache = &self.icon_cache,
            .icon_scale = icon_scale,
            .png_dims = &self.png_dims,
        }, -1);
        // Keep garbage from widget-table churn paced across builds; full
        // collections here would stall in proportion to the whole Lua heap.
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
        if (c.lua_isnumber(self.state, -1) != 0) {
            decl.height = @floatCast(c.lua_tonumber(self.state, -1));
        } else if (c.lua_type(self.state, -1) == c.LUA_TSTRING) {
            const value = stringFromStack(self.state, -1) catch unreachable;
            if (!std.mem.eql(u8, value, "content")) {
                pop(self.state, 1);
                return error.InvalidWindowHeight;
            }
            decl.content_height = true;
        }
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
            lua_value.setStringField(lua_state, -1, "name", output.name);
            lua_value.setNumberField(lua_state, -1, "width", output.width);
            lua_value.setNumberField(lua_state, -1, "height", output.height);
            lua_value.setNumberField(lua_state, -1, "scale", output.scale);
            c.lua_rawseti(lua_state, outputs, @intCast(index));
        }
        c.lua_setfield(lua_state, table, "outputs");
        lua_value.setStringField(lua_state, table, "color_scheme", context.color_scheme);
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

        c.lua_settop(self.state, 0);
        defer c.lua_settop(self.state, 0);
        c.lua_rawgeti(self.state, c.LUA_REGISTRYINDEX, ref);
        return self.parseWidgetAtTop(scope.allocator, context, scope.render_scale, scope.state_invalidator);
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
        const root = c.lua_gettop(self.state);
        var config: WindowConfig = .{};
        var catalog: ?lua_storybook.Catalog = null;
        switch (self.root_kind) {
            .application => config = try lua_config.parseRoot(self.state, self.allocator, root),
            .storybook => catalog = try lua_storybook.parseRoot(self.state, self.allocator, root),
        }
        var committed = false;
        errdefer if (!committed) config.deinit(self.allocator);
        errdefer if (!committed) if (catalog) |*value| value.deinit(self.allocator);
        const script_ref = c.luaL_ref(self.state, c.LUA_REGISTRYINDEX);
        errdefer if (!committed) c.luaL_unref(self.state, c.LUA_REGISTRYINDEX, script_ref);
        const browser_ref = if (self.storybook_browser) try self.createStorybookBrowserRef(script_ref) else -1;
        errdefer if (!committed and browser_ref >= 0) c.luaL_unref(self.state, c.LUA_REGISTRYINDEX, browser_ref);
        const start_ref = if (self.root_kind == .application) try tableFunctionRef(self.state, script_ref, "start") else -1;
        errdefer if (!committed and start_ref >= 0) c.luaL_unref(self.state, c.LUA_REGISTRYINDEX, start_ref);
        const stop_ref = if (self.root_kind == .application) try tableFunctionRef(self.state, script_ref, "stop") else -1;
        errdefer if (!committed and stop_ref >= 0) c.luaL_unref(self.state, c.LUA_REGISTRYINDEX, stop_ref);

        if (self.script_ref >= 0) c.luaL_unref(self.state, c.LUA_REGISTRYINDEX, self.script_ref);
        if (self.browser_ref >= 0) c.luaL_unref(self.state, c.LUA_REGISTRYINDEX, self.browser_ref);
        if (self.start_ref >= 0) c.luaL_unref(self.state, c.LUA_REGISTRYINDEX, self.start_ref);
        if (self.stop_ref >= 0) c.luaL_unref(self.state, c.LUA_REGISTRYINDEX, self.stop_ref);
        self.window_config.deinit(self.allocator);
        if (self.storybook_catalog) |*previous| previous.deinit(self.allocator);
        self.window_config = config;
        self.storybook_catalog = catalog;
        self.script_ref = script_ref;
        self.browser_ref = browser_ref;
        self.start_ref = start_ref;
        self.stop_ref = stop_ref;
        self.script_dirty = false;
        committed = true;
        _ = c.lua_gc(self.state, c.LUA_GCCOLLECT, 0);
        if (self.event_loop != null and self.invalidator != null) try self.startLifecycle();
    }

    fn createStorybookBrowserRef(self: *App, script_ref: c_int) !c_int {
        if (c.luaL_loadbuffer(self.state, embedded_storybook_browser_source.ptr, embedded_storybook_browser_source.len, "@keywork/storybook_browser.lua") != 0) {
            return self.failWithLuaError(error.StorybookBrowserLoadFailed);
        }
        if (c.lua_pcall(self.state, 0, 1, 0) != 0) return self.failWithLuaError(error.StorybookBrowserLoadFailed);
        c.lua_rawgeti(self.state, c.LUA_REGISTRYINDEX, script_ref);
        if (c.lua_pcall(self.state, 1, 1, 0) != 0) return self.failWithLuaError(error.StorybookBrowserCreateFailed);
        if (c.lua_type(self.state, -1) != c.LUA_TTABLE) return error.StorybookBrowserInvalid;
        return c.luaL_ref(self.state, c.LUA_REGISTRYINDEX);
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
        for (self.scopes.items) |scope| scope.cancel(self.state, .silent);
        for (self.tasks.items) |task| task.cancel(self.state, .silent);
        for (self.fd_watches.items) |watch| watch.cancel(self.state, .silent);
        for (self.fs_events.items) |fs_event| fs_event.cancel(self.state, .silent);
        for (self.timers.items) |timer| timer.cancel(self.state, .silent);
        for (self.channels.items) |channel| channel.cancel(self.state, .silent);
        for (self.processes.items) |process| process.cancel(self.state, .silent);
        for (self.sockets.items) |socket| socket.cancel(self.state, .silent);
        for (self.dbus_buses.items) |bus| bus.close();
        for (self.pipewire_connections.items) |connection| connection.cancel(self.state, .silent);
    }

    fn readScriptFile(self: *App) ![]u8 {
        const open_result = linux.openat(linux.AT.FDCWD, self.path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (linux.errno(open_result) != .SUCCESS) return error.ScriptReadFailed;
        const fd: i32 = @intCast(open_result);
        defer _ = linux.close(fd);
        return linux_syscall.readAllAlloc(self.allocator, fd) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.ReadFailed => error.ScriptReadFailed,
        };
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
        return self.buildWidgetWithInvalidator(scope.allocator, runtime_state, scope.render_scale, scope.state_invalidator);
    }

    fn widgetHost(self: *App, state_invalidator: ?keywork.Widget.Callback) lua_widget.Host {
        return .{
            .ptr = self,
            .state_invalidator = state_invalidator orelse .{ .ptr = self, .call_fn = invalidateWidgetState },
            .create_scope_fn = createWidgetScope,
            .dispose_scope_fn = disposeWidgetScope,
        };
    }

    fn invalidateWidgetState(ptr: *anyopaque) !void {
        const self: *App = @ptrCast(@alignCast(ptr));
        const invalidator = self.invalidator orelse return;
        try invalidator.invalidateState();
    }

    fn createWidgetScope(ptr: *anyopaque) anyerror!*LuaScope {
        const self: *App = @ptrCast(@alignCast(ptr));
        return self.addScope();
    }

    fn disposeWidgetScope(ptr: *anyopaque, scope: *LuaScope) void {
        const self: *App = @ptrCast(@alignCast(ptr));
        self.scheduleScopeCancel(scope);
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

    fn addChannel(self: *App) !*Channel {
        const channel = try self.allocator.create(Channel);
        errdefer self.allocator.destroy(channel);
        channel.* = .{ .host = self.loopHost() };
        try self.channels.append(self.allocator, channel);
        return channel;
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

    fn addPipeWireConnection(self: *App, realtime: bool) !*PipeWireConnection {
        const connection = try PipeWireConnection.create(self.pipewireHost(), realtime);
        errdefer connection.destroy(self.allocator, self.state);
        try self.pipewire_connections.append(self.allocator, connection);
        errdefer _ = self.pipewire_connections.pop();
        try connection.register();
        return connection;
    }

    fn pipewireHost(self: *App) lua_pipewire.Host {
        return .{ .ptr = self, .vtable = &pipewire_host_vtable };
    }

    fn addTask(self: *App, thread: *c.lua_State, thread_ref: c_int) !*LuaTask {
        const task = try self.allocator.create(LuaTask);
        errdefer self.allocator.destroy(task);
        task.* = .{ .allocator = self.allocator, .thread = thread, .thread_ref = thread_ref };
        try self.tasks.append(self.allocator, task);
        return task;
    }

    fn addScope(self: *App) !*LuaScope {
        const scope = try self.allocator.create(LuaScope);
        errdefer self.allocator.destroy(scope);
        scope.* = .{ .host = self.loopHost() };
        try self.scopes.append(self.allocator, scope);
        return scope;
    }

    /// Cancels a widget scope on the next loop turn. Widget disposal runs
    /// inside reconciliation, where resuming coroutines could re-enter the
    /// build; without a loop (teardown) the scope is canceled silently.
    fn scheduleScopeCancel(self: *App, scope: *LuaScope) void {
        if (scope.canceled) return;
        const loop = self.event_loop orelse {
            scope.cancel(self.state, .silent);
            return;
        };
        self.pending_scope_cancels.append(self.allocator, scope) catch {
            scope.cancel(self.state, .silent);
            return;
        };
        self.armScopeCancelTimer(loop) catch |err| {
            std.log.scoped(.keywork_luajit).warn("scope cancel deferral failed: {}", .{err});
            _ = self.pending_scope_cancels.pop();
            scope.cancel(self.state, .silent);
        };
    }

    fn armScopeCancelTimer(self: *App, loop: *event_loop.EventLoop) !void {
        if (self.scope_cancel_timer != null) return;
        const timer = try loop.addTimer(self, scopeCancelFired);
        errdefer loop.removeTimer(timer);
        try timer.arm(1, 0);
        self.scope_cancel_timer = timer;
    }

    fn scopeCancelFired(ctx: *anyopaque, loop: *event_loop.EventLoop, _: u64) !void {
        const self: *App = @ptrCast(@alignCast(ctx));
        if (self.scope_cancel_timer) |timer| loop.removeTimer(timer);
        self.scope_cancel_timer = null;
        while (self.pending_scope_cancels.pop()) |scope| scope.cancel(self.state, .resume_reader);
    }
};

const process_host_vtable: lua_process.Host.VTable = .{
    .allocator = hostAllocator,
    .luaState = hostLuaState,
    .eventLoop = hostEventLoop,
};

fn hostAllocator(ptr: *anyopaque) std.mem.Allocator {
    const app: *App = @ptrCast(@alignCast(ptr));
    return app.allocator;
}

fn hostLuaState(ptr: *anyopaque) *c.lua_State {
    const app: *App = @ptrCast(@alignCast(ptr));
    return app.state;
}

fn hostEventLoop(ptr: *anyopaque) ?*event_loop.EventLoop {
    const app: *App = @ptrCast(@alignCast(ptr));
    return app.event_loop;
}

const loop_host_vtable: lua_loop.Host.VTable = .{
    .allocator = hostAllocator,
    .luaState = hostLuaState,
    .eventLoop = hostEventLoop,
    .invalidate = loopHostInvalidate,
    .addFdWatch = loopHostAddFdWatch,
    .addFsEvent = loopHostAddFsEvent,
    .addTimer = loopHostAddTimer,
    .addTask = loopHostAddTask,
    .addScope = loopHostAddScope,
    .addChannel = loopHostAddChannel,
};

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

fn loopHostAddTask(ptr: *anyopaque, thread: *c.lua_State, thread_ref: c_int) anyerror!*LuaTask {
    const app: *App = @ptrCast(@alignCast(ptr));
    return app.addTask(thread, thread_ref);
}

fn loopHostAddChannel(ptr: *anyopaque) anyerror!*Channel {
    const app: *App = @ptrCast(@alignCast(ptr));
    return app.addChannel();
}

fn loopHostAddScope(ptr: *anyopaque) anyerror!*LuaScope {
    const app: *App = @ptrCast(@alignCast(ptr));
    return app.addScope();
}

const socket_host_vtable: lua_socket.Host.VTable = .{
    .allocator = hostAllocator,
    .luaState = hostLuaState,
    .eventLoop = hostEventLoop,
    .addSocket = socketHostAddSocket,
};

fn socketHostAddSocket(ptr: *anyopaque, fd: i32) anyerror!*LuaSocket {
    const app: *App = @ptrCast(@alignCast(ptr));
    return app.addSocket(fd);
}

const dbus_host_vtable: lua_dbus.Host.VTable = .{
    .allocator = hostAllocator,
    .luaState = hostLuaState,
    .eventLoop = hostEventLoop,
    .addBus = dbusHostAddBus,
};

const pipewire_host_vtable: lua_pipewire.Host.VTable = .{
    .allocator = hostAllocator,
    .luaState = hostLuaState,
    .eventLoop = hostEventLoop,
    .addConnection = pipewireHostAddConnection,
};

fn pipewireHostAddConnection(ptr: *anyopaque, realtime: bool) anyerror!*PipeWireConnection {
    const app: *App = @ptrCast(@alignCast(ptr));
    return app.addPipeWireConnection(realtime);
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

/// Prepends the script's directory to `package.path` so applications can
/// require sibling modules (`foo` → `<script-dir>/foo.lua` or
/// `<script-dir>/foo/init.lua`) without a LUA_PATH bootstrap wrapper.
fn installScriptModuleRoots(lua_state: *c.lua_State, allocator: std.mem.Allocator, script_path: []const u8) !void {
    const dir = std.fs.path.dirname(script_path) orelse ".";

    c.lua_getfield(lua_state, c.LUA_GLOBALSINDEX, "package");
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) {
        pop(lua_state, 1);
        return error.NoPackageTable;
    }
    const package_table = c.lua_gettop(lua_state);
    c.lua_getfield(lua_state, package_table, "path");
    const existing = stringFromStack(lua_state, -1) catch "";

    const merged = try std.fmt.allocPrint(allocator, "{s}/?.lua;{s}/?/init.lua;{s}", .{ dir, dir, existing });
    defer allocator.free(merged);
    lua_value.setStringField(lua_state, package_table, "path", merged);
    pop(lua_state, 2);
}

const embedded_ui_source = @embedFile("ui.lua");
const embedded_audio_source = @embedFile("audio.lua");
const embedded_storybook_source = @embedFile("storybook.lua");
const embedded_storybook_browser_source = @embedFile("storybook_browser.lua");
const embedded_service_source = @embedFile("service.lua");
const embedded_process_source = @embedFile("process.lua");
const embedded_stream_source = @embedFile("stream.lua");
const embedded_xdg_source = @embedFile("xdg.lua");
const embedded_xdg_applications_source = @embedFile("xdg_applications.lua");
const embedded_notify_source = @embedFile("notify.lua");
const embedded_portal_source = @embedFile("portal.lua");

fn installKeyworkModule(lua_state: *c.lua_State, app: *App) void {
    c.lua_getfield(lua_state, c.LUA_GLOBALSINDEX, "package");
    const package_table = c.lua_gettop(lua_state);
    c.lua_getfield(lua_state, package_table, "preload");
    const preload_table = c.lua_gettop(lua_state);

    c.lua_pushlightuserdata(lua_state, app);
    lua_value.setClosureField(lua_state, preload_table, "keywork", keyworkModuleLoader, 1);

    lua_value.setClosureField(lua_state, preload_table, "keywork.storybook", storybookModuleLoader, 0);

    c.lua_pushlightuserdata(lua_state, app);
    lua_value.setClosureField(lua_state, preload_table, "keywork.loop", loopModuleLoader, 1);

    c.lua_pushlightuserdata(lua_state, app);
    lua_value.setClosureField(lua_state, preload_table, "keywork.process", processModuleLoader, 1);

    c.lua_pushlightuserdata(lua_state, app);
    lua_value.setClosureField(lua_state, preload_table, "keywork.dbus", dbusModuleLoader, 1);

    c.lua_pushlightuserdata(lua_state, app);
    lua_value.setClosureField(lua_state, preload_table, "keywork.pipewire", pipewireModuleLoader, 1);

    lua_value.setClosureField(lua_state, preload_table, "keywork.audio", audioModuleLoader, 0);

    lua_value.setClosureField(lua_state, preload_table, "keywork.log", logModuleLoader, 0);

    c.lua_pushlightuserdata(lua_state, app);
    lua_value.setClosureField(lua_state, preload_table, "keywork.json", jsonModuleLoader, 1);

    lua_value.setClosureField(lua_state, preload_table, "keywork.service", serviceModuleLoader, 0);

    lua_value.setClosureField(lua_state, preload_table, "keywork.stream", streamModuleLoader, 0);

    c.lua_pushlightuserdata(lua_state, app);
    lua_value.setClosureField(lua_state, preload_table, "keywork.xdg", xdgModuleLoader, 1);

    lua_value.setClosureField(lua_state, preload_table, "keywork.xdg.applications", xdgApplicationsModuleLoader, 0);

    lua_value.setClosureField(lua_state, preload_table, "keywork.notify", notifyModuleLoader, 0);

    lua_value.setClosureField(lua_state, preload_table, "keywork.portal", portalModuleLoader, 0);

    pop(lua_state, 2);
}

fn storybookModuleLoader(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    return loadEmbeddedModule(lua_state_optional.?, embedded_storybook_source, "@keywork/storybook.lua");
}

fn audioModuleLoader(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    return loadEmbeddedModule(lua_state_optional.?, embedded_audio_source, "@keywork/audio.lua");
}

fn serviceModuleLoader(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    return loadEmbeddedModule(lua_state_optional.?, embedded_service_source, "@keywork/service.lua");
}

fn loadEmbeddedModule(lua_state: *c.lua_State, source: []const u8, chunk_name: [*:0]const u8) c_int {
    if (c.luaL_loadbuffer(lua_state, source.ptr, source.len, chunk_name) != 0) return c.lua_error(lua_state);
    if (c.lua_pcall(lua_state, 0, 1, 0) != 0) return c.lua_error(lua_state);
    return 1;
}

fn keyworkModuleLoader(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const app = lua_value.upvaluePointer(*App, lua_state, 1);
    if (c.luaL_loadbuffer(lua_state, embedded_ui_source.ptr, embedded_ui_source.len, "@keywork/ui.lua") != 0) return c.lua_error(lua_state);
    if (c.lua_pcall(lua_state, 0, 1, 0) != 0) return c.lua_error(lua_state);
    const keywork_table = c.lua_gettop(lua_state);

    pushAppNamespace(lua_state, app);
    c.lua_setfield(lua_state, keywork_table, "app");

    pushClipboardNamespace(lua_state, app);
    c.lua_setfield(lua_state, keywork_table, "clipboard");
    installWindowOperations(lua_state, keywork_table, app);
    return 1;
}

/// Attaches window-level operations to the `kw.window` callable table
/// declared in ui.lua.
fn installWindowOperations(lua_state: *c.lua_State, keywork_table: c_int, app: *App) void {
    c.lua_getfield(lua_state, keywork_table, "window");
    std.debug.assert(c.lua_type(lua_state, -1) == c.LUA_TTABLE);
    const window_table = c.lua_gettop(lua_state);
    c.lua_pushlightuserdata(lua_state, app);
    lua_value.setClosureField(lua_state, window_table, "start_move", luaWindowStartMove, 1);
    c.lua_pushlightuserdata(lua_state, app);
    lua_value.setClosureField(lua_state, window_table, "start_resize", luaWindowStartResize, 1);
    c.lua_pushlightuserdata(lua_state, app);
    lua_value.setClosureField(lua_state, window_table, "request_activation_token", luaWindowRequestActivationToken, 1);
    pop(lua_state, 1);
}

fn pushClipboardNamespace(lua_state: *c.lua_State, app: *App) void {
    c.lua_createtable(lua_state, 0, 2);
    const clipboard_table = c.lua_gettop(lua_state);
    c.lua_pushlightuserdata(lua_state, app);
    lua_value.setClosureField(lua_state, clipboard_table, "read", luaClipboardRead, 1);
    c.lua_pushlightuserdata(lua_state, app);
    lua_value.setClosureField(lua_state, clipboard_table, "write", luaClipboardWrite, 1);
}

/// kw.clipboard.read() -> text | nil [, err]. Nil without an error means
/// the clipboard is empty or holds no text.
fn luaClipboardRead(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const app = lua_value.upvaluePointer(*App, lua_state, 1);
    const platform = app.platform orelse return lua_value.pushNilError(lua_state, error.PlatformUnavailable);
    const text = platform.clipboardRead(app.allocator) catch |err| return lua_value.pushNilError(lua_state, err);
    const value = text orelse {
        c.lua_pushnil(lua_state);
        return 1;
    };
    defer app.allocator.free(value);
    c.lua_pushlstring(lua_state, value.ptr, value.len);
    return 1;
}

/// kw.clipboard.write(text) -> true | nil, err. Call from an input
/// handler: compositors reject selection claims without a recent input
/// serial.
fn luaClipboardWrite(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const app = lua_value.upvaluePointer(*App, lua_state, 1);
    const text = lua_value.checkString(lua_state, 1);
    const platform = app.platform orelse return lua_value.pushNilError(lua_state, error.PlatformUnavailable);
    platform.clipboardWrite(text) catch |err| return lua_value.pushNilError(lua_state, err);
    c.lua_pushboolean(lua_state, 1);
    return 1;
}

/// kw.window.start_move() -> true | nil, err. Starts a compositor-driven
/// interactive move of the window the most recent pointer press landed
/// in; call from a press handler.
fn luaWindowStartMove(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const app = lua_value.upvaluePointer(*App, lua_state, 1);
    const platform = app.platform orelse return lua_value.pushNilError(lua_state, error.PlatformUnavailable);
    platform.startMove() catch |err| return lua_value.pushNilError(lua_state, err);
    c.lua_pushboolean(lua_state, 1);
    return 1;
}

/// kw.window.start_resize(edge) -> true | nil, err. Edge names mirror
/// xdg_toplevel ("top", "bottom_left" / "bottom-left", ...).
fn luaWindowStartResize(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const app = lua_value.upvaluePointer(*App, lua_state, 1);
    const edge = platform_mod.resizeEdgeFromName(lua_value.checkString(lua_state, 1)) orelse
        return c.luaL_error(lua_state, "invalid resize edge (expected top, bottom, left, right, or a corner)");
    const platform = app.platform orelse return lua_value.pushNilError(lua_state, error.PlatformUnavailable);
    platform.startResize(edge) catch |err| return lua_value.pushNilError(lua_state, err);
    c.lua_pushboolean(lua_state, 1);
    return 1;
}

/// kw.window.request_activation_token(opts?) -> token | nil [, err].
/// `opts.app_id` hints which application will be activated; pass the
/// token to xdg.applications.launch as opts.activation_token. Nil
/// without an error means the compositor lacks xdg-activation.
fn luaWindowRequestActivationToken(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const app = lua_value.upvaluePointer(*App, lua_state, 1);
    const platform = app.platform orelse return lua_value.pushNilError(lua_state, error.PlatformUnavailable);

    var app_id: ?[:0]u8 = null;
    defer if (app_id) |value| app.allocator.free(value);
    if (c.lua_type(lua_state, 1) == c.LUA_TTABLE) {
        if (lua_value.stringField(lua_state, 1, "app_id")) |value| {
            app_id = app.allocator.dupeZ(u8, value) catch return c.luaL_error(lua_state, "out of memory");
        } else |_| {}
    }

    const token = platform.activationToken(app.allocator, if (app_id) |value| value.ptr else null) catch |err|
        return lua_value.pushNilError(lua_state, err);
    const value = token orelse {
        c.lua_pushnil(lua_state);
        return 1;
    };
    defer app.allocator.free(value);
    c.lua_pushlstring(lua_state, value.ptr, value.len);
    return 1;
}

fn loopModuleLoader(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const app = lua_value.upvaluePointer(*App, lua_state, 1);
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
    const app = lua_value.upvaluePointer(*App, lua_state, 1);
    c.lua_createtable(lua_state, 0, 2);
    c.lua_pushlightuserdata(lua_state, app);
    lua_value.setClosureField(lua_state, -2, "spawn", luaSpawn, 1);
    // The embedded Lua layer augments the native table in place (capture, ...).
    if (c.luaL_loadbuffer(lua_state, embedded_process_source.ptr, embedded_process_source.len, "@keywork/process.lua") != 0) return c.lua_error(lua_state);
    c.lua_pushvalue(lua_state, -2);
    if (c.lua_pcall(lua_state, 1, 0, 0) != 0) return c.lua_error(lua_state);
    return 1;
}

fn streamModuleLoader(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    return loadEmbeddedModule(lua_state_optional.?, embedded_stream_source, "@keywork/stream.lua");
}

fn xdgApplicationsModuleLoader(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    return loadEmbeddedModule(lua_state_optional.?, embedded_xdg_applications_source, "@keywork/xdg_applications.lua");
}

fn xdgModuleLoader(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const app = lua_value.upvaluePointer(*App, lua_state, 1);
    c.lua_createtable(lua_state, 0, 12);
    lua_xdg.installApi(lua_state, -1, &app.allocator);
    // The embedded Lua layer adds the base-directory functions in place.
    if (c.luaL_loadbuffer(lua_state, embedded_xdg_source.ptr, embedded_xdg_source.len, "@keywork/xdg.lua") != 0) return c.lua_error(lua_state);
    c.lua_pushvalue(lua_state, -2);
    if (c.lua_pcall(lua_state, 1, 0, 0) != 0) return c.lua_error(lua_state);
    return 1;
}

fn notifyModuleLoader(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    return loadEmbeddedModule(lua_state_optional.?, embedded_notify_source, "@keywork/notify.lua");
}

fn portalModuleLoader(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    return loadEmbeddedModule(lua_state_optional.?, embedded_portal_source, "@keywork/portal.lua");
}

fn dbusModuleLoader(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const app = lua_value.upvaluePointer(*App, lua_state, 1);
    app.dbus_host = app.dbusHost();
    lua_dbus.pushModule(lua_state, &app.dbus_host);
    return 1;
}

fn pipewireModuleLoader(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const app = lua_value.upvaluePointer(*App, lua_state, 1);
    app.pipewire_host = app.pipewireHost();
    lua_pipewire.pushModule(lua_state, &app.pipewire_host);
    return 1;
}

fn jsonModuleLoader(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const app = lua_value.upvaluePointer(*App, lua_state, 1);
    lua_json.pushModule(lua_state, &app.allocator);
    return 1;
}

fn logModuleLoader(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    c.lua_createtable(lua_state, 0, 4);
    const log_table = c.lua_gettop(lua_state);
    lua_value.setClosureField(lua_state, log_table, "debug", luaLogDebug, 0);
    lua_value.setClosureField(lua_state, log_table, "info", luaLogInfo, 0);
    lua_value.setClosureField(lua_state, log_table, "warn", luaLogWarn, 0);
    lua_value.setClosureField(lua_state, log_table, "err", luaLogErr, 0);
    return 1;
}

fn pushAppNamespace(lua_state: *c.lua_State, app: *App) void {
    c.lua_createtable(lua_state, 0, 3);
    const app_table = c.lua_gettop(lua_state);
    c.lua_pushlightuserdata(lua_state, app);
    lua_value.setClosureField(lua_state, app_table, "quit", luaQuit, 1);
    c.lua_pushlightuserdata(lua_state, app);
    lua_value.setClosureField(lua_state, app_table, "reload", luaReload, 1);
    c.lua_pushlightuserdata(lua_state, app);
    lua_value.setClosureField(lua_state, app_table, "invalidate", luaInvalidate, 1);

    c.lua_createtable(lua_state, 0, 1);
    lua_value.setClosureField(lua_state, -1, "__call", luaAppCall, 0);
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
    const app = lua_value.upvaluePointer(*App, lua_state, 1);
    if (app.event_loop) |loop| {
        loop.quit();
    } else {
        app.quit_requested = true;
    }
    return 0;
}

fn luaReload(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const app = lua_value.upvaluePointer(*App, lua_state, 1);
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
    const app = lua_value.upvaluePointer(*App, lua_state, 1);
    lua_task.raiseIfCanceled(lua_state);
    c.luaL_checktype(lua_state, 1, c.LUA_TTABLE);

    const argv = lua_process.parseArgv(lua_state, app.allocator, 1) catch |err| {
        std.log.scoped(.keywork_luajit).warn("spawn argv failed: {}", .{err});
        return c.luaL_error(lua_state, "invalid spawn argv");
    };
    defer lua_process.freeArgv(app.allocator, argv);
    const env = lua_process.parseEnv(lua_state, app.allocator, 1) catch |err| {
        std.log.scoped(.keywork_luajit).warn("spawn env failed: {}", .{err});
        return c.luaL_error(lua_state, "invalid spawn env (string names to string values)");
    };
    defer lua_process.freeEnv(app.allocator, env);

    const spec: lua_process.SpawnSpec = .{
        .argv = argv,
        .stdin_pipe = std.mem.eql(u8, lua_value.stringField(lua_state, 1, "stdin") catch "ignore", "pipe"),
        .stdout_pipe = std.mem.eql(u8, lua_value.stringField(lua_state, 1, "stdout") catch "ignore", "pipe"),
        .stderr_pipe = std.mem.eql(u8, lua_value.stringField(lua_state, 1, "stderr") catch "ignore", "pipe"),
        .env = env,
    };
    // A missing executable or exhausted system resources are expected
    // runtime failures, so spawn reports nil, err instead of raising.
    const process = app.addProcess(spec) catch |err| {
        std.log.scoped(.keywork_luajit).warn("process.spawn failed: {}", .{err});
        return lua_value.pushNilError(lua_state, err);
    };
    lua_task.adoptResource(LuaProcess, lua_state, process);
    lua_process.pushHandle(lua_state, process);
    return 1;
}

fn luaInvalidate(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const app = lua_value.upvaluePointer(*App, lua_state, 1);
    const invalidator = app.invalidator orelse return 0;
    invalidator.invalidate() catch |err| {
        std.log.scoped(.keywork_luajit).warn("invalidate failed: {}", .{err});
        return c.luaL_error(lua_state, "invalidate failed");
    };
    return 0;
}

fn initTestApp(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, name: []const u8, script: []const u8) !App {
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], name });
    defer allocator.free(script_path);
    return App.init(allocator, script_path);
}

const LuaBooleanPoll = struct {
    app: *App,
    global: [:0]const u8,
    max_ticks: u32,
    ticks: u32 = 0,

    fn callback(ctx: *anyopaque, loop: *event_loop.EventLoop, _: u64) !void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.ticks += 1;
        c.lua_getglobal(self.app.state, self.global.ptr);
        const done = c.lua_toboolean(self.app.state, -1) != 0;
        pop(self.app.state, 1);
        if (done or self.ticks > self.max_ticks) loop.quit();
    }
};

fn runUntilLuaBoolean(loop: *event_loop.EventLoop, app: *App, global: [:0]const u8, max_ticks: u32) !void {
    var poll: LuaBooleanPoll = .{ .app = app, .global = global, .max_ticks = max_ticks };
    const timer = try loop.addTimer(&poll, LuaBooleanPoll.callback);
    defer loop.removeTimer(timer);
    try timer.arm(1, 1);
    try loop.run();
}

fn expectLuaBoolean(app: *App, global: [:0]const u8, expected: bool) !void {
    c.lua_getglobal(app.state, global.ptr);
    defer pop(app.state, 1);
    std.testing.expectEqual(expected, c.lua_toboolean(app.state, -1) != 0) catch |err| {
        std.debug.print("unexpected Lua boolean global '{s}'\n", .{global});
        return err;
    };
}

fn expectLuaBooleans(app: *App, globals: []const [:0]const u8) !void {
    for (globals) |global| try expectLuaBoolean(app, global, true);
}

fn initTestRuntime(
    allocator: std.mem.Allocator,
    backend: *log_backend_mod.LogBackend,
    app: *App,
    constraints: keywork.Constraints,
    color_scheme: runtime_mod.UiColorScheme,
) !runtime_mod.Runtime {
    return runtime_mod.Runtime.init(allocator, backend.backend(), constraints, app.host(), color_scheme);
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
        var app = try initTestApp(allocator, &tmp, case.name, case.script);
        defer app.deinit();
        try std.testing.expectError(error.InvalidAppRoot, app.ensureLoaded());
    }
}

test "storybook root catalogs and renders a selected story" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\local kw = require("keywork")
        \\local sb = require("keywork.storybook")
        \\return sb.book({
        \\  title = "Components",
        \\  stories = {
        \\    sb.story({
        \\      id = "text/hello",
        \\      group = "Text",
        \\      name = "Hello",
        \\      viewport = { width = 320, height = 180, scale = 2 },
        \\      color_scheme = "dark",
        \\      render = function(context)
        \\        assert(context.window_width == 320)
        \\        assert(context.color_scheme == "dark")
        \\        return kw.text("hello")
        \\      end,
        \\    }),
        \\  },
        \\})
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "stories.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "stories.lua" });
    defer allocator.free(script_path);

    var app = try App.initStorybook(allocator, script_path);
    defer app.deinit();
    const catalog = try app.storyCatalog();
    try std.testing.expectEqualStrings("Components", catalog.title.?);
    try std.testing.expectEqual(@as(usize, 1), catalog.stories.len);
    try std.testing.expectEqual(@as(f32, 2), catalog.stories[0].scale);
    try std.testing.expectEqual(lua_storybook.ColorScheme.dark, catalog.stories[0].color_scheme);
    try std.testing.expectError(error.UnknownStory, app.selectStory("missing"));
    try app.selectStory("text/hello");

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    _ = try app.buildWidget(arena.allocator(), .{
        .window_width = 320,
        .window_height = 180,
        .color_scheme = "dark",
    }, 2);

    var browser = try App.initStorybookBrowser(allocator, script_path);
    defer browser.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var log_backend: log_backend_mod.LogBackend = .{ .writer = &output.writer };
    var runtime = try runtime_mod.Runtime.init(
        allocator,
        log_backend.backend(),
        .{ .max_width = 1200, .max_height = 800 },
        browser.host(),
        .light,
    );
    defer runtime.deinit();
    browser.bindRuntime(&runtime);
    defer browser.unbindRuntime();
    try runtime.repaint();
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "value=\"Components\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "value=\"Hello\"") != null);
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
        \\assert(kw.pipewire == nil)
        \\assert(kw.audio == nil)
        \\assert(kw.log == nil)
        \\assert(package.loaded["keywork.loop"] == nil)
        \\assert(package.loaded["keywork.process"] == nil)
        \\assert(package.loaded["keywork.dbus"] == nil)
        \\assert(package.loaded["keywork.pipewire"] == nil)
        \\assert(package.loaded["keywork.audio"] == nil)
        \\assert(package.loaded["keywork.log"] == nil)
        \\assert(type(require("keywork.loop").timer) == "function")
        \\assert(type(require("keywork.process").spawn) == "function")
        \\assert(type(require("keywork.dbus").session) == "function")
        \\assert(type(require("keywork.pipewire").connect) == "function")
        \\assert(type(require("keywork.audio").monitor) == "function")
        \\assert(type(require("keywork.log").info) == "function")
        \\local options = { child = kw.text("x") }
        \\local root = kw.app(options)
        \\assert(root == options)
        \\assert(root.type == "app")
        \\return root
        \\
    ;
    var app = try initTestApp(allocator, &tmp, "app-callable.lua", script);
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
    var app = try initTestApp(allocator, &tmp, "lifecycle.lua", script);
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

test "script directory is a module root for require" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sibling.lua", .data = "return { value = 41 }\n" });
    try tmp.dir.createDir(std.testing.io, "nested", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "nested/init.lua", .data = "return { value = 1 }\n" });
    const script =
        \\local kw = require("keywork")
        \\local sibling = require("sibling")
        \\local nested = require("nested")
        \\answer = sibling.value + nested.value
        \\return kw.app({ child = kw.text("modules") })
        \\
    ;
    var app = try initTestApp(allocator, &tmp, "modules.lua", script);
    defer app.deinit();
    try app.ensureLoaded();

    c.lua_getglobal(app.state, "answer");
    try std.testing.expectEqual(@as(c.lua_Integer, 42), c.lua_tointeger(app.state, -1));
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
    var app = try initTestApp(allocator, &tmp, "reload.lua", script);
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
    var app = try initTestApp(allocator, &tmp, "stale.lua", script);
    defer app.deinit();
    try app.ensureLoaded();

    try expectLuaBoolean(&app, "fresh_canceled", false);

    app.script_dirty = true;
    try app.ensureLoaded();

    try expectLuaBoolean(&app, "stale_canceled", true);
    try expectLuaBoolean(&app, "stale_still_canceled", true);
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
    var app = try initTestApp(allocator, &tmp, "quit.lua", script);
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
    var app = try initTestApp(allocator, &tmp, "timer-ticks.lua", script);
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

    try expectLuaBoolean(&app, "done", true);
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
    var app = try initTestApp(allocator, &tmp, "timer-oneshot.lua", script);
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

    try expectLuaBoolean(&app, "done", true);
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
    var app = try initTestApp(allocator, &tmp, "timer-cancel.lua", script);
    defer app.deinit();
    try app.ensureLoaded();

    try expectLuaBoolean(&app, "ended", true);
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
    var app = try initTestApp(allocator, &tmp, "sleep.lua", script);
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
    var app = try initTestApp(allocator, &tmp, "sleep-main.lua", script);
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
    var app = try initTestApp(allocator, &tmp, "sleep-teardown.lua", script);
    defer app.deinit();
    try app.ensureLoaded();
    try std.testing.expectEqual(@as(usize, 1), app.timers.items.len);
    try std.testing.expect(!app.timers.items[0].canceled);
    // deinit cancels the waiter timer without resuming; the parked
    // coroutine is simply dropped with the state.
}

test "loop.spawn returns a task handle with status, join, and cancel" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // No event loop is bound, so sleeps park forever and every wake-up
    // below is driven synchronously by cancel.
    const script =
        \\local kw = require("keywork")
        \\local loop = require("keywork.loop")
        \\local task = loop.spawn(function()
        \\  loop.sleep(3600000)
        \\  woke = true
        \\  loop.sleep(3600000) -- raises "task canceled" and unwinds
        \\  unreachable = true
        \\end)
        \\assert(task:status() == "running")
        \\join_result = nil
        \\loop.spawn(function()
        \\  join_result = task:join()
        \\end)
        \\assert(join_result == nil)
        \\task:cancel()
        \\-- Cancel resumed the sleep so the body could unwind, but the next
        \\-- await raised instead of parking again.
        \\assert(woke)
        \\assert(unreachable == nil)
        \\assert(task:status() == "canceled")
        \\assert(join_result == "canceled")
        \\-- Joining a settled task returns at once, even from the main state.
        \\local settled = loop.spawn(function() end)
        \\assert(settled:status() == "completed")
        \\assert(settled:join() == "completed")
        \\-- Joining an unsettled task from the main state is misuse.
        \\local parked = loop.spawn(function() loop.sleep(3600000) end)
        \\local ok, err = pcall(function() return parked:join() end)
        \\assert(not ok and err:find("coroutine", 1, true))
        \\-- A task cannot join itself; cancel wakes the sleep so the body
        \\-- reaches the self-join while still running.
        \\local self_join_err
        \\local selfish
        \\selfish = loop.spawn(function()
        \\  loop.sleep(3600000)
        \\  local _, join_err = pcall(function() return selfish:join() end)
        \\  self_join_err = join_err
        \\end)
        \\selfish:cancel()
        \\assert(self_join_err:find("cannot join itself", 1, true))
        \\return kw.app({ child = kw.text("task") })
        \\
    ;
    var app = try initTestApp(allocator, &tmp, "task.lua", script);
    defer app.deinit();
    try app.ensureLoaded();
    // The parked tasks are torn down silently with the app.
}

test "scope cancel unwinds member tasks and inherited children" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\local kw = require("keywork")
        \\local loop = require("keywork.loop")
        \\local scope = loop.scope()
        \\parent_woke = false
        \\child_woke = false
        \\scope:spawn(function()
        \\  -- A plain loop.spawn from inside a scoped task inherits the scope.
        \\  loop.spawn(function()
        \\    loop.sleep(3600000)
        \\    child_woke = true
        \\  end)
        \\  loop.sleep(3600000)
        \\  parent_woke = true
        \\end)
        \\assert(not scope:canceled())
        \\scope:cancel()
        \\assert(scope:canceled())
        \\assert(parent_woke and child_woke)
        \\-- Spawning on a canceled scope raises.
        \\local ok, err = pcall(function() return scope:spawn(function() end) end)
        \\assert(not ok and err:find("scope canceled", 1, true))
        \\return kw.app({ child = kw.text("scope") })
        \\
    ;
    var app = try initTestApp(allocator, &tmp, "scope.lua", script);
    defer app.deinit();
    try app.ensureLoaded();
    try std.testing.expectEqual(@as(usize, 1), app.scopes.items.len);
    try std.testing.expect(app.scopes.items[0].canceled);
    for (app.tasks.items) |task| {
        try std.testing.expectEqual(lua_task.Status.canceled, task.status);
    }
}

test "task cancel cancels resources the task created" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The timer is created while the task's coroutine runs, so the task
    // owns it ambiently: task:cancel() cancels the timer, which ends the
    // ticks() iteration so the body unwinds.
    const script =
        \\local kw = require("keywork")
        \\local loop = require("keywork.loop")
        \\stream_ended = false
        \\local task = loop.spawn(function()
        \\  local t = loop.timer({ interval = 60 })
        \\  for _ in t:ticks() do end
        \\  stream_ended = true
        \\end)
        \\assert(task:status() == "running")
        \\task:cancel()
        \\assert(stream_ended)
        \\assert(task:status() == "canceled")
        \\return kw.app({ child = kw.text("owned") })
        \\
    ;
    var app = try initTestApp(allocator, &tmp, "owned.lua", script);
    defer app.deinit();
    try app.ensureLoaded();
    try std.testing.expectEqual(@as(usize, 1), app.timers.items.len);
    try std.testing.expect(app.timers.items[0].canceled);
}

test "reload cancels tasks and scopes from the previous load" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Globals survive reload, so handles retained by the first load are
    // observable from the second; the canceled originals must be inert.
    const script =
        \\local kw = require("keywork")
        \\local loop = require("keywork.loop")
        \\if not first_load then
        \\  first_load = true
        \\  task = loop.spawn(function() loop.sleep(3600000) end)
        \\  scope = loop.scope()
        \\  scope:spawn(function() loop.sleep(3600000) end)
        \\else
        \\  stale_task_status = task:status()
        \\  stale_scope_canceled = scope:canceled()
        \\end
        \\return kw.app({ child = kw.text("reload-tasks") })
        \\
    ;
    var app = try initTestApp(allocator, &tmp, "reload-tasks.lua", script);
    defer app.deinit();
    try app.ensureLoaded();
    try std.testing.expectEqual(@as(usize, 2), app.tasks.items.len);
    try std.testing.expectEqual(lua_task.Status.running, app.tasks.items[0].status);

    app.script_dirty = true;
    try app.ensureLoaded();
    for (app.tasks.items) |task| {
        try std.testing.expectEqual(lua_task.Status.canceled, task.status);
    }
    try std.testing.expect(app.scopes.items[0].canceled);

    c.lua_getglobal(app.state, "stale_task_status");
    try std.testing.expectEqualStrings("canceled", try stringFromStack(app.state, -1));
    pop(app.state, 1);
    try expectLuaBoolean(&app, "stale_scope_canceled", true);
}

test "shared service starts once, fans out, and stops with its last subscriber" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\local kw = require("keywork")
        \\local loop = require("keywork.loop")
        \\local service = require("keywork.service")
        \\starts = 0
        \\local svc = service.define("monitor", function(self)
        \\  starts = starts + 1
        \\  self:publish("ready")
        \\  loop.sleep(3600000)
        \\end)
        \\local s1 = loop.scope()
        \\local s2 = loop.scope()
        \\local got1, got2 = nil, nil
        \\local first = svc:use(s1, function(v) got1 = v end)
        \\local second = svc:use(s2, function(v) got2 = v end)
        \\assert(starts == 1)
        \\assert(first == "ready" and second == "ready")
        \\-- publish fans out to every subscriber
        \\svc:publish("update")
        \\assert(got1 == "update" and got2 == "update")
        \\-- scope cancel releases one subscription
        \\s1:cancel()
        \\svc:publish("late")
        \\assert(got1 == "update" and got2 == "late")
        \\-- the last release stops the service
        \\s2:cancel()
        \\assert(svc.scope:canceled())
        \\assert(svc.task:status() == "canceled")
        \\-- the next use restarts it
        \\local s3 = loop.scope()
        \\local third = svc:use(s3, function() end)
        \\assert(starts == 2)
        \\assert(third == "ready")
        \\return kw.app({ child = kw.text("service") })
        \\
    ;
    var app = try initTestApp(allocator, &tmp, "service.lua", script);
    defer app.deinit();
    try app.ensureLoaded();
}

test "restarting a settled service body tears down its old scope" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A body that returns while children it spawned are still running
    // must not be respawned next to them: restart cancels the old scope
    // first, so the service's work is never duplicated.
    const script =
        \\local kw = require("keywork")
        \\local loop = require("keywork.loop")
        \\local service = require("keywork.service")
        \\starts = 0
        \\children = {}
        \\local svc = service.define("settling", function(self)
        \\  starts = starts + 1
        \\  table.insert(children, loop.spawn(function()
        \\    loop.sleep(3600000)
        \\  end))
        \\  self:publish(starts)
        \\end)
        \\local s1 = loop.scope()
        \\svc:use(s1, function() end)
        \\assert(starts == 1)
        \\assert(svc.task:status() == "completed")
        \\assert(children[1]:status() == "running")
        \\local s2 = loop.scope()
        \\svc:use(s2, function() end)
        \\assert(starts == 2)
        \\assert(children[1]:status() == "canceled")
        \\assert(children[2]:status() == "running")
        \\return kw.app({ child = kw.text("service-restart") })
        \\
    ;
    var app = try initTestApp(allocator, &tmp, "service-restart.lua", script);
    defer app.deinit();
    try app.ensureLoaded();
}

test "reload resets stale service entries" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The registry survives reload via the module cache, but reload
    // cancels the service's scope; the next use must detect the dead
    // entry and start fresh instead of returning stale state.
    const script =
        \\local kw = require("keywork")
        \\local loop = require("keywork.loop")
        \\local service = require("keywork.service")
        \\starts = starts or 0
        \\local svc = service.define("reloaded", function(self)
        \\  starts = starts + 1
        \\  self:publish(starts)
        \\  loop.sleep(3600000)
        \\end)
        \\local scope = loop.scope()
        \\snapshot = svc:use(scope, function() end)
        \\return kw.app({ child = kw.text("service-reload") })
        \\
    ;
    var app = try initTestApp(allocator, &tmp, "service-reload.lua", script);
    defer app.deinit();
    try app.ensureLoaded();

    c.lua_getglobal(app.state, "snapshot");
    try std.testing.expectEqual(@as(c.lua_Integer, 1), c.lua_tointeger(app.state, -1));
    pop(app.state, 1);

    app.script_dirty = true;
    try app.ensureLoaded();

    c.lua_getglobal(app.state, "starts");
    try std.testing.expectEqual(@as(c.lua_Integer, 2), c.lua_tointeger(app.state, -1));
    pop(app.state, 1);
    c.lua_getglobal(app.state, "snapshot");
    defer pop(app.state, 1);
    try std.testing.expectEqual(@as(c.lua_Integer, 2), c.lua_tointeger(app.state, -1));
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
    var app = try initTestApp(allocator, &tmp, "dbus-call.lua", script);
    defer app.deinit();
    try app.ensureLoaded();

    var loop = try event_loop.EventLoop.init(allocator);
    defer loop.deinit();
    try app.bindEventLoop(&loop);
    defer app.unbindEventLoop();

    try runUntilLuaBoolean(&loop, &app, "done", 3000);

    try expectLuaBoolean(&app, "got_id", true);
    try expectLuaBoolean(&app, "got_error", true);
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
    var app = try initTestApp(allocator, &tmp, "dbus-subscribe.lua", script);
    defer app.deinit();
    try app.ensureLoaded();

    var loop = try event_loop.EventLoop.init(allocator);
    defer loop.deinit();
    try app.bindEventLoop(&loop);
    defer app.unbindEventLoop();

    try runUntilLuaBoolean(&loop, &app, "done", 3000);

    try expectLuaBoolean(&app, "got_signal", true);
    try expectLuaBoolean(&app, "sub_ended", true);
}

test "lua loop.channel delivers pushed values to a coroutine reader" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\local kw = require("keywork")
        \\local loop = require("keywork.loop")
        \\
        \\-- Values pushed before a reader exists queue up; close is EOF, so
        \\-- queued values stay readable and iteration ends after the drain.
        \\local pre = loop.channel()
        \\pre:push("x")
        \\pre:push("y")
        \\pre:close()
        \\pre:push("dropped")
        \\local pre_results = {}
        \\loop.spawn(function()
        \\  for value in pre:events() do
        \\    table.insert(pre_results, value)
        \\  end
        \\end)
        \\assert(#pre_results == 2)
        \\assert(pre_results[1] == "x")
        \\assert(pre_results[2] == "y")
        \\
        \\-- A parked reader resumes synchronously on push, including pushes
        \\-- from the main thread.
        \\local live = loop.channel()
        \\local live_results = {}
        \\live_done = false
        \\loop.spawn(function()
        \\  for value in live:events() do
        \\    table.insert(live_results, value.n)
        \\  end
        \\  live_done = true
        \\end)
        \\live:push({ n = 1 })
        \\live:push({ n = 2 })
        \\live:close()
        \\assert(live_done)
        \\assert(#live_results == 2)
        \\assert(live_results[1] == 1)
        \\assert(live_results[2] == 2)
        \\
        \\return kw.app({ child = kw.text("channel") })
        \\
    ;
    var app = try initTestApp(allocator, &tmp, "channel.lua", script);
    defer app.deinit();
    try app.ensureLoaded();
}

test "lua bus:observe snapshots, resyncs, and tracks owner changes" {
    if (std.c.getenv("DBUS_SESSION_BUS_ADDRESS") == null) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The bus observes an object exported on its own connection: the daemon
    // routes GetAll calls and signals back, so no second peer is needed.
    const script =
        \\local kw = require("keywork")
        \\local dbus = require("keywork.dbus")
        \\local loop = require("keywork.loop")
        \\local bus = assert(dbus.session())
        \\
        \\local value = "initial"
        \\assert(bus:request_name("org.keywork.test.Observe"))
        \\bus:export("/org/keywork/observe_test", {
        \\  ["org.keywork.ObserveTest"] = {
        \\    properties = {
        \\      Value = {
        \\        signature = "s",
        \\        access = "readwrite",
        \\        get = function() return value end,
        \\        set = function(v) value = v end,
        \\      },
        \\    },
        \\  },
        \\})
        \\
        \\local stage = 0
        \\loop.spawn(function()
        \\  local obs = bus:observe({
        \\    destination = "org.keywork.test.Observe",
        \\    path = "/org/keywork/observe_test",
        \\    interface = "org.keywork.ObserveTest",
        \\    timeout_ms = 2000,
        \\  })
        \\  for event in obs:changes() do
        \\    if stage == 0 then
        \\      initial_ok = event.available
        \\        and event.props.Value == "initial"
        \\        and event.changed.Value == "initial"
        \\      stage = 1
        \\      -- Services like StatusNotifierItem change silently and
        \\      -- signal with custom members; refresh must re-snapshot.
        \\      value = "refreshed"
        \\      obs:refresh()
        \\    elseif stage == 1 then
        \\      refresh_ok = event.available and event.props.Value == "refreshed"
        \\      stage = 2
        \\      -- Invalidated properties carry no value; observe must
        \\      -- recover with a fresh GetAll.
        \\      value = "updated"
        \\      bus:emit({
        \\        path = "/org/keywork/observe_test",
        \\        interface = "org.freedesktop.DBus.Properties",
        \\        member = "PropertiesChanged",
        \\        args = {
        \\          "org.keywork.ObserveTest",
        \\          dbus.array("{sv}", {}),
        \\          dbus.array("s", { "Value" }),
        \\        },
        \\      })
        \\    elseif stage == 2 then
        \\      resync_ok = event.available and event.props.Value == "updated"
        \\      stage = 3
        \\      bus:release_name("org.keywork.test.Observe")
        \\    elseif stage == 3 then
        \\      vanish_ok = event.available == false and event.props.Value == nil
        \\      stage = 4
        \\      assert(bus:request_name("org.keywork.test.Observe"))
        \\    elseif stage == 4 then
        \\      recover_ok = event.available and event.props.Value == "updated"
        \\      obs:cancel()
        \\    end
        \\  end
        \\  done = true
        \\end)
        \\return kw.app({ child = kw.text("observe") })
        \\
    ;
    var app = try initTestApp(allocator, &tmp, "dbus-observe.lua", script);
    defer app.deinit();
    try app.ensureLoaded();

    var loop = try event_loop.EventLoop.init(allocator);
    defer loop.deinit();
    try app.bindEventLoop(&loop);
    defer app.unbindEventLoop();

    try runUntilLuaBoolean(&loop, &app, "done", 5000);

    try expectLuaBooleans(&app, &.{ "initial_ok", "refresh_ok", "resync_ok", "vanish_ok", "recover_ok", "done" });
}

test "lua exported methods can yield before replying" {
    if (std.c.getenv("DBUS_SESSION_BUS_ADDRESS") == null) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Slow yields through a nested bus:call to Echo on the same connection
    // before replying, so the bus must keep dispatching while a handler is
    // parked. Boom proves handler errors still surface as LuaError.
    const script =
        \\local kw = require("keywork")
        \\local dbus = require("keywork.dbus")
        \\local loop = require("keywork.loop")
        \\local bus = assert(dbus.session())
        \\
        \\local NAME = "org.keywork.test.AsyncMethods"
        \\local PATH = "/org/keywork/async_test"
        \\local IFACE = "org.keywork.AsyncTest"
        \\assert(bus:request_name(NAME))
        \\bus:export(PATH, {
        \\  [IFACE] = {
        \\    methods = {
        \\      Echo = {
        \\        in_signature = "s",
        \\        call = function(_, text) return "echo:" .. text end,
        \\      },
        \\      Slow = {
        \\        in_signature = "s",
        \\        call = function(_, text)
        \\          local reply = assert(bus:call({
        \\            destination = NAME,
        \\            path = PATH,
        \\            interface = IFACE,
        \\            member = "Echo",
        \\            args = { text },
        \\            timeout_ms = 2000,
        \\          }))
        \\          return "slow:" .. ((reply.args or {})[1] or "?")
        \\        end,
        \\      },
        \\      Boom = {
        \\        in_signature = "",
        \\        call = function() error("kaboom") end,
        \\      },
        \\    },
        \\  },
        \\})
        \\
        \\loop.spawn(function()
        \\  local reply = bus:call({
        \\    destination = NAME,
        \\    path = PATH,
        \\    interface = IFACE,
        \\    member = "Slow",
        \\    args = { "hi" },
        \\    timeout_ms = 2000,
        \\  })
        \\  slow_ok = reply ~= nil and (reply.args or {})[1] == "slow:echo:hi"
        \\  local failed, err = bus:call({
        \\    destination = NAME,
        \\    path = PATH,
        \\    interface = IFACE,
        \\    member = "Boom",
        \\    timeout_ms = 2000,
        \\  })
        \\  boom_ok = failed == nil and err == "org.keywork.LuaError"
        \\  done = true
        \\end)
        \\return kw.app({ child = kw.text("async methods") })
        \\
    ;
    var app = try initTestApp(allocator, &tmp, "dbus-async-methods.lua", script);
    defer app.deinit();
    try app.ensureLoaded();

    var loop = try event_loop.EventLoop.init(allocator);
    defer loop.deinit();
    try app.bindEventLoop(&loop);
    defer app.unbindEventLoop();

    try runUntilLuaBoolean(&loop, &app, "done", 5000);

    try expectLuaBooleans(&app, &.{ "slow_ok", "boom_ok", "done" });
}

test "lua dbus session buses are pooled and refcounted" {
    if (std.c.getenv("DBUS_SESSION_BUS_ADDRESS") == null) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Names are owned by the connection, so a name requested through one
    // lease surviving that lease's close proves the connection is shared,
    // and the name vanishing after the last close proves it really closed.
    const script =
        \\local kw = require("keywork")
        \\local dbus = require("keywork.dbus")
        \\local loop = require("keywork.loop")
        \\
        \\local NAME = "org.keywork.test.Pool"
        \\local b1 = assert(dbus.session())
        \\local b2 = assert(dbus.session())
        \\assert(b1:request_name(NAME))
        \\
        \\loop.spawn(function()
        \\  local function owner_of(bus, name)
        \\    local reply = bus:call({
        \\      destination = "org.freedesktop.DBus",
        \\      path = "/org/freedesktop/DBus",
        \\      interface = "org.freedesktop.DBus",
        \\      member = "GetNameOwner",
        \\      args = { name },
        \\      timeout_ms = 2000,
        \\    })
        \\    return reply and (reply.args or {})[1] or nil
        \\  end
        \\
        \\  local before = owner_of(b2, NAME)
        \\  b1:close()
        \\  closed_ok = b1:closed() and not b2:closed()
        \\  local after = owner_of(b2, NAME)
        \\  shared_ok = before ~= nil and after == before
        \\  b2:close()
        \\  fully_closed_ok = b2:closed()
        \\  local b3 = assert(dbus.session())
        \\  reacquire_ok = not b3:closed() and owner_of(b3, NAME) == nil
        \\  b3:close()
        \\  done = true
        \\end)
        \\return kw.app({ child = kw.text("pool") })
        \\
    ;
    var app = try initTestApp(allocator, &tmp, "dbus-pool.lua", script);
    defer app.deinit();
    try app.ensureLoaded();

    var loop = try event_loop.EventLoop.init(allocator);
    defer loop.deinit();
    try app.bindEventLoop(&loop);
    defer app.unbindEventLoop();

    try runUntilLuaBoolean(&loop, &app, "done", 5000);

    try expectLuaBooleans(&app, &.{ "closed_ok", "shared_ok", "fully_closed_ok", "reacquire_ok", "done" });
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
    var app = try initTestApp(allocator, &tmp, "dbus-properties.lua", script);
    defer app.deinit();
    try app.ensureLoaded();

    var loop = try event_loop.EventLoop.init(allocator);
    defer loop.deinit();
    try app.bindEventLoop(&loop);
    defer app.unbindEventLoop();

    try runUntilLuaBoolean(&loop, &app, "done", 5000);

    try expectLuaBooleans(&app, &.{
        "got_initial", "set_ok",    "got_updated", "typed_set",
        "typed_get",   "read_only", "proxy_echo",  "proxy_error",
    });
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
    var app = try initTestApp(allocator, &tmp, "stateful.lua", script);
    defer app.deinit();

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var log_backend: log_backend_mod.LogBackend = .{ .writer = &output.writer };
    var runtime = try initTestRuntime(allocator, &log_backend, &app, .{ .max_width = 100, .max_height = 40 }, .no_preference);
    defer runtime.deinit();
    app.bindRuntime(&runtime);

    try runtime.repaint();
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "value=\"0\"") != null);

    try runtime.click(.{ .x = 2, .y = 2 });
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "value=\"1\"") != null);
}

test "lua stateful widget prefers its build scope invalidator" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\local kw = require("keywork")
        \\local Counter = kw.stateful({
        \\  build = function(self, state)
        \\    return kw.gesture({ id = "counter", child = kw.text("counter"), on_tap = function()
        \\      self:set_state()
        \\    end })
        \\  end,
        \\})
        \\return kw.app({ child = Counter({ key = "counter" }) })
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "scoped-stateful.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "scoped-stateful.lua" });
    defer allocator.free(script_path);

    const Counter = struct {
        calls: usize = 0,

        fn invalidate(ptr: *anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
        }
    };
    const ScopedHost = struct {
        app: *App,
        invalidator: *Counter,

        fn host(self: *@This()) keywork.AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(ptr: *anyopaque, scope: *BuildScope, context: State) anyerror!keywork.Widget {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            scope.state_invalidator = .{ .ptr = self.invalidator, .call_fn = Counter.invalidate };
            return self.app.host().buildWidget(scope, context);
        }
    };

    var app = try App.init(allocator, script_path);
    defer app.deinit();
    var global_invalidator: Counter = .{};
    app.bindInvalidator(.{
        .ptr = &global_invalidator,
        .invalidate_fn = Counter.invalidate,
        .invalidate_state_fn = Counter.invalidate,
    });

    var scoped_invalidator: Counter = .{};
    var scoped_host: ScopedHost = .{ .app = &app, .invalidator = &scoped_invalidator };
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var log_backend: log_backend_mod.LogBackend = .{ .writer = &output.writer };
    var runtime = try runtime_mod.Runtime.init(
        allocator,
        log_backend.backend(),
        .{ .max_width = 100, .max_height = 40 },
        scoped_host.host(),
        .no_preference,
    );
    defer runtime.deinit();

    try runtime.click(.{ .x = 2, .y = 2 });
    try std.testing.expectEqual(@as(usize, 1), scoped_invalidator.calls);
    try std.testing.expectEqual(@as(usize, 0), global_invalidator.calls);
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
    var app = try initTestApp(allocator, &tmp, "dispose.lua", script);
    defer app.deinit();

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var log_backend: log_backend_mod.LogBackend = .{ .writer = &output.writer };
    var runtime = try initTestRuntime(allocator, &log_backend, &app, .{ .max_width = 100, .max_height = 40 }, .no_preference);
    defer runtime.deinit();
    app.bindRuntime(&runtime);

    try runtime.repaint();
    try runtime.click(.{ .x = 2, .y = 2 });
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "value=\"gone\"") != null);

    try expectLuaBoolean(&app, "disposed", true);
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
    var app = try initTestApp(allocator, &tmp, "stale-set-state.lua", script);
    defer app.deinit();

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var log_backend: log_backend_mod.LogBackend = .{ .writer = &output.writer };
    var runtime = try initTestRuntime(allocator, &log_backend, &app, .{ .max_width = 100, .max_height = 40 }, .no_preference);
    defer runtime.deinit();
    app.bindRuntime(&runtime);

    try runtime.repaint();
    try runtime.click(.{ .x = 2, .y = 2 });

    try expectLuaBoolean(&app, "disposed", true);

    c.lua_getglobal(app.state, "stale_set_state");
    try std.testing.expectEqual(c.LUA_TFUNCTION, c.lua_type(app.state, -1));
    try std.testing.expectEqual(@as(c_int, 0), c.lua_pcall(app.state, 0, 0, 0));
}

test "widget scope is canceled on the loop turn after dispose" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // self.scope lazily creates the widget's lifecycle scope; removing the
    // widget must cancel it, but deferred to the next loop turn because
    // dispose runs inside reconciliation where resuming coroutines could
    // re-enter the build.
    const script =
        \\local kw = require("keywork")
        \\local loop = require("keywork.loop")
        \\scope_task_woke = false
        \\local Child = kw.stateful({
        \\  init = function(self)
        \\    self.scope:spawn(function()
        \\      loop.sleep(3600000)
        \\      scope_task_woke = true
        \\    end)
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
    var app = try initTestApp(allocator, &tmp, "widget-scope.lua", script);
    defer app.deinit();

    var loop = try event_loop.EventLoop.init(allocator);
    defer loop.deinit();
    try app.bindEventLoop(&loop);
    defer app.unbindEventLoop();

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var log_backend: log_backend_mod.LogBackend = .{ .writer = &output.writer };
    var runtime = try initTestRuntime(allocator, &log_backend, &app, .{ .max_width = 100, .max_height = 40 }, .no_preference);
    defer runtime.deinit();
    app.bindRuntime(&runtime);

    try runtime.repaint();
    try std.testing.expectEqual(@as(usize, 1), app.scopes.items.len);
    try std.testing.expect(!app.scopes.items[0].canceled);

    // Removing the widget schedules the cancel instead of running it
    // inside reconciliation.
    try runtime.click(.{ .x = 2, .y = 2 });
    try std.testing.expect(!app.scopes.items[0].canceled);
    try std.testing.expectEqual(@as(usize, 1), app.pending_scope_cancels.items.len);

    const ScopeTest = struct {
        app: *App,
        rounds: u32 = 0,

        fn callback(ctx: *anyopaque, event_loop_instance: *event_loop.EventLoop, _: u64) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.rounds += 1;
            c.lua_getglobal(self.app.state, "scope_task_woke");
            const woke = c.lua_toboolean(self.app.state, -1) != 0;
            pop(self.app.state, 1);
            if (woke or self.rounds > 1000) event_loop_instance.quit();
        }
    };
    var context: ScopeTest = .{ .app = &app };
    try loop.addRepeatingTimer(1, &context, ScopeTest.callback);
    try loop.run();

    try std.testing.expect(app.scopes.items[0].canceled);
    try std.testing.expectEqual(@as(usize, 0), app.pending_scope_cancels.items.len);
    try expectLuaBoolean(&app, "scope_task_woke", true);
    try std.testing.expectEqual(lua_task.Status.canceled, app.tasks.items[0].status);
}

test "widget dispose releases its service subscription" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The widget subscribes through self.scope; removing the widget must
    // release the subscription on the deferred scope cancel, and as the
    // last subscriber that stops the service, unwinding its body.
    const script =
        \\local kw = require("keywork")
        \\local loop = require("keywork.loop")
        \\local service = require("keywork.service")
        \\starts = 0
        \\service_unwound = false
        \\local svc = service.define("widget-monitor", function(self)
        \\  starts = starts + 1
        \\  self:publish("ready")
        \\  loop.sleep(3600000)
        \\  service_unwound = true
        \\end)
        \\local Child = kw.stateful({
        \\  init = function(self)
        \\    self.snapshot = svc:use(self.scope, function(v)
        \\      self:set_state(function(s) s.snapshot = v end)
        \\    end)
        \\  end,
        \\  build = function(self, state)
        \\    return kw.gesture({ id = "remove", child = kw.text(self.snapshot or "none"), on_tap = self.props.on_remove })
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
    var app = try initTestApp(allocator, &tmp, "widget-service.lua", script);
    defer app.deinit();

    var loop = try event_loop.EventLoop.init(allocator);
    defer loop.deinit();
    try app.bindEventLoop(&loop);
    defer app.unbindEventLoop();

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var log_backend: log_backend_mod.LogBackend = .{ .writer = &output.writer };
    var runtime = try initTestRuntime(allocator, &log_backend, &app, .{ .max_width = 100, .max_height = 40 }, .no_preference);
    defer runtime.deinit();
    app.bindRuntime(&runtime);

    try runtime.repaint();
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "ready") != null);

    try runtime.click(.{ .x = 2, .y = 2 });

    const ServiceTest = struct {
        app: *App,
        rounds: u32 = 0,

        fn callback(ctx: *anyopaque, event_loop_instance: *event_loop.EventLoop, _: u64) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.rounds += 1;
            c.lua_getglobal(self.app.state, "service_unwound");
            const unwound = c.lua_toboolean(self.app.state, -1) != 0;
            pop(self.app.state, 1);
            if (unwound or self.rounds > 1000) event_loop_instance.quit();
        }
    };
    var context: ServiceTest = .{ .app = &app };
    try loop.addRepeatingTimer(1, &context, ServiceTest.callback);
    try loop.run();

    try expectLuaBoolean(&app, "service_unwound", true);
    // Both the widget scope and the service scope are canceled, and the
    // service task settled as canceled.
    for (app.scopes.items) |scope| try std.testing.expect(scope.canceled);
    try std.testing.expectEqual(lua_task.Status.canceled, app.tasks.items[0].status);
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
    var app = try initTestApp(allocator, &tmp, "bind-vanished.lua", script);
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
        \\assert(reader:status() == "running")
        \\watch:cancel()
        \\assert(stream_ended)
        \\assert(reader:status() == "completed")
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
    var app = try initTestApp(allocator, &tmp, "fs-event-cancel.lua", script);
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
        \\assert(reader:status() == "running")
        \\watch:cancel()
        \\assert(fd_stream_ended)
        \\assert(watch:canceled())
        \\return kw.app({ child = kw.text("fd-cancel") })
        \\
    ;
    var app = try initTestApp(allocator, &tmp, "fd-cancel.lua", script);
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
    var app = try initTestApp(allocator, &tmp, "fd-pending.lua", script);
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

    try expectLuaBoolean(&app, "got_read", true);
    try std.testing.expect(app.fd_watches.items[0].canceled);
}

test "lua stateful build context keeps ambient component theme" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\local kw = require("keywork")
        \\local theme = kw.resolve_theme(kw.theme_data({
        \\  components = { chip = {
        \\    min_height = 28,
        \\    hover_background = 0xff00ff00,
        \\    selected_background = 0xffff0000,
        \\  } },
        \\}), "dark")
        \\local App = kw.stateful({
        \\  build = function(self, context)
        \\    local chip = context.theme.components.chip
        \\    local status = context.theme.color_scheme == "dark"
        \\      and chip.min_height == 28
        \\      and chip.hover_background == 0xff00ff00
        \\      and chip.selected_background == 0xffff0000
        \\    return kw.column({ children = {
        \\      kw.chip({ id = "hover", label = "Hover", on_tap = function() end }),
        \\      kw.chip({ id = "selected", label = "Selected", selected = true }),
        \\      kw.label(status and "ambient" or "missing"),
        \\    } })
        \\  end,
        \\})
        \\return kw.app({ child = kw.theme({ data = theme, child = App({ key = "app" }) }) })
        \\
    ;
    var app = try initTestApp(allocator, &tmp, "theme-context.lua", script);
    defer app.deinit();

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var log_backend: log_backend_mod.LogBackend = .{ .writer = &output.writer };
    var runtime = try initTestRuntime(allocator, &log_backend, &app, .{ .max_width = 100, .max_height = 100 }, .dark);
    defer runtime.deinit();

    try runtime.repaint();
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "value=\"ambient\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "color=#ffff0000") != null);

    try runtime.pointerMove(.{ .x = 5, .y = 5 });
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "color=#ff00ff00") != null);
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
    var app = try initTestApp(allocator, &tmp, "theme-family.lua", script);
    defer app.deinit();

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var log_backend: log_backend_mod.LogBackend = .{ .writer = &output.writer };
    var runtime = try initTestRuntime(allocator, &log_backend, &app, .{ .max_width = 240, .max_height = 40 }, .dark);
    defer runtime.deinit();

    try runtime.repaint();
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "fill_rect x=0 y=0 w=240 h=40 color=#ff111113") != null);
    // Input geometry follows the default input theme: 14px text plus 6px
    // vertical and 8px horizontal padding (Radix size-2 text field).
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "fill_rect x=0 y=0 w=240 h=26 color=#ff223344") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "text x=8 y=6 value=\"Name\" color=#ff445566") != null);
}

test "lua default theme exposes paired Radix size 2 typography" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\local kw = require("keywork")
        \\local theme = kw.resolve_theme(kw.theme_data(), "light")
        \\return kw.app({
        \\  child = kw.label(theme.font_size[2] .. ":" .. theme.line_height[2]),
        \\})
        \\
    ;
    var app = try initTestApp(allocator, &tmp, "radix-typography.lua", script);
    defer app.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var log_backend: log_backend_mod.LogBackend = .{ .writer = &output.writer };
    var runtime = try initTestRuntime(allocator, &log_backend, &app, .{ .max_width = 100, .max_height = 100 }, .light);
    defer runtime.deinit();

    const root = runtime.root.?;
    try std.testing.expectEqualStrings("14:20", root.text.?);
    try std.testing.expectEqual(@as(f32, 14), root.text_style.font_size);
    try std.testing.expectEqual(@as(?f32, 20), root.text_style.line_height);
    try std.testing.expectEqual(@as(f32, 20), root.rect.height);
}

test "lua window declarations preserve numeric sizes and accept content height" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\local kw = require("keywork")
        \\return kw.app({
        \\  windows = function()
        \\    return {
        \\      kw.window({ id = "fixed", width = 320, height = 180, child = kw.text("fixed") }),
        \\      kw.window({
        \\        id = "content", width = 380, height = "content",
        \\        layer_shell = { layer = "overlay", anchor = { "top", "right" }, pointer = "none" },
        \\        child = kw.text("content"),
        \\      }),
        \\    }
        \\  end,
        \\})
        \\
    ;
    var app = try initTestApp(allocator, &tmp, "content-window.lua", script);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const declarations = try app.buildWindowDecls(arena.allocator(), .{});

    try std.testing.expectEqual(@as(usize, 2), declarations.len);
    try std.testing.expectEqual(@as(?f32, 320), declarations[0].width);
    try std.testing.expectEqual(@as(?f32, 180), declarations[0].height);
    try std.testing.expect(!declarations[0].content_height);
    try std.testing.expectEqual(@as(?f32, 380), declarations[1].width);
    try std.testing.expectEqual(@as(?f32, null), declarations[1].height);
    try std.testing.expect(declarations[1].content_height);
    try std.testing.expect(declarations[1].layer_shell != null);
    try std.testing.expect(declarations[1].layer_shell.?.pointer_interactivity == .none);
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
    var app = try initTestApp(allocator, &tmp, "flex.lua", script);
    defer app.deinit();

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var log_backend: log_backend_mod.LogBackend = .{ .writer = &output.writer };
    var runtime = try initTestRuntime(allocator, &log_backend, &app, .{ .max_width = 100, .max_height = 60 }, .no_preference);
    defer runtime.deinit();

    try runtime.repaint();
    // space_between pushes R (8px wide) to the 100px right edge.
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "x=92 y=0 value=\"R\"") != null);
    // The expanded text starts right after A regardless of its own width.
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "x=8 y=24 value=\"B\"") != null);
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
    var app = try initTestApp(allocator, &tmp, "fs-event.lua", script);
    defer app.deinit();

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var log_backend: log_backend_mod.LogBackend = .{ .writer = &output.writer };
    // The loop must outlive the runtime: runtime deinit disposes stateful
    // widgets whose Lua dispose callbacks cancel sources on the loop.
    var loop = try event_loop.EventLoop.init(allocator);
    defer loop.deinit();
    var runtime = try initTestRuntime(allocator, &log_backend, &app, .{ .max_width = 100, .max_height = 40 }, .no_preference);
    defer runtime.deinit();

    try std.testing.expectEqual(@as(usize, 1), app.fs_events.items.len);
    try std.testing.expect(!app.fs_events.items[0].registered);
    app.bindRuntime(&runtime);
    defer app.unbindRuntime();
    try app.bindEventLoop(&loop);
    defer app.unbindEventLoop();
    try std.testing.expect(app.fs_events.items[0].registered);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "watched.txt", .data = "after\n" });

    try runUntilLuaBoolean(&loop, &app, "fs_event_seen", 1000);

    try expectLuaBoolean(&app, "fs_event_seen", true);
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
    var app = try initTestApp(allocator, &tmp, "spawn.lua", script);
    defer app.deinit();

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var log_backend: log_backend_mod.LogBackend = .{ .writer = &output.writer };
    // The loop must outlive the runtime: runtime deinit disposes stateful
    // widgets whose Lua dispose callbacks cancel sources on the loop.
    var loop = try event_loop.EventLoop.init(allocator);
    defer loop.deinit();
    var runtime = try initTestRuntime(allocator, &log_backend, &app, .{ .max_width = 100, .max_height = 40 }, .no_preference);
    defer runtime.deinit();

    try runtime.repaint();

    app.bindRuntime(&runtime);
    defer app.unbindRuntime();
    try app.bindEventLoop(&loop);
    defer app.unbindEventLoop();
    try runUntilLuaBoolean(&loop, &app, "spawn_done", 1000);

    try expectLuaBoolean(&app, "spawn_done", true);
    c.lua_getglobal(app.state, "spawn_output");
    defer pop(app.state, 1);
    const value = try stringFromStack(app.state, -1);
    try std.testing.expectEqualStrings("hello", value);

    c.lua_getglobal(app.state, "spawn_cancel");
    try std.testing.expectEqual(c.LUA_TFUNCTION, c.lua_type(app.state, -1));
    try std.testing.expectEqual(@as(c_int, 0), c.lua_pcall(app.state, 0, 0, 0));
}

test "lua stream.lines splits chunks and yields the unterminated tail" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\local kw = require("keywork")
        \\local stream = require("keywork.stream")
        \\
        \\local function chunks(list)
        \\  local index = 0
        \\  return function()
        \\    index = index + 1
        \\    return list[index]
        \\  end
        \\end
        \\
        \\local function collect(iter)
        \\  local lines = {}
        \\  for line in iter do
        \\    table.insert(lines, line)
        \\  end
        \\  return lines
        \\end
        \\
        \\-- lines split across chunk boundaries, plus an unterminated tail
        \\local got = collect(stream.lines(chunks({ "al", "pha\nbe", "ta\ngam", "ma" })))
        \\assert(#got == 3)
        \\assert(got[1] == "alpha")
        \\assert(got[2] == "beta")
        \\assert(got[3] == "gamma")
        \\
        \\-- empty lines survive; trailing newline yields no phantom line
        \\got = collect(stream.lines(chunks({ "a\n\nb\n" })))
        \\assert(#got == 3)
        \\assert(got[1] == "a")
        \\assert(got[2] == "")
        \\assert(got[3] == "b")
        \\
        \\-- empty stream yields nothing
        \\got = collect(stream.lines(chunks({})))
        \\assert(#got == 0)
        \\
        \\return kw.app({ child = kw.text("lines") })
        \\
    ;
    var app = try initTestApp(allocator, &tmp, "lines.lua", script);
    defer app.deinit();
    try app.ensureLoaded();
}

test "lua xdg.applications parses entries, looks up ids, and expands exec" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "share/applications/org/example");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "share/applications/editor.desktop",
        .data =
        \\[Desktop Entry]
        \\Type=Application
        \\Name=Editor
        \\Name[de]=Bearbeiter
        \\GenericName=Text Editor
        \\Comment=Edit text files
        \\Keywords=semi\;colon;plain;
        \\Categories=Utility;TextEditor;
        \\Icon=editor-icon
        \\Exec=editor --title %c %%x %F --icon-args %i
        \\Terminal=false
        \\Actions=new-window;
        \\MimeType=text/plain;
        \\
        \\[Desktop Action new-window]
        \\Name=New Window
        \\Exec=editor --new-window
        \\
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "share/applications/org/example/Viewer.desktop",
        .data =
        \\[Desktop Entry]
        \\Type=Application
        \\Name=Viewer
        \\Exec=viewer %U
        \\
        ,
    });

    const data_dir = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "share" });
    defer allocator.free(data_dir);

    const script_body =
        \\local kw = require("keywork")
        \\local apps = require("keywork.xdg.applications")
        \\local dirs = { data_dir }
        \\
        \\-- locale-aware parse: Name[de] wins for de_DE, lists and actions parse
        \\local entry = assert(apps.lookup("editor", { dirs = dirs, locale = "de_DE" }))
        \\assert(entry.name == "Bearbeiter")
        \\assert(entry.generic_name == "Text Editor")
        \\assert(entry.icon == "editor-icon")
        \\assert(#entry.keywords == 2)
        \\assert(entry.keywords[1] == "semi;colon")
        \\assert(entry.keywords[2] == "plain")
        \\assert(entry.categories[2] == "TextEditor")
        \\assert(#entry.actions == 1)
        \\assert(entry.actions[1].id == "new-window")
        \\assert(entry.actions[1].name == "New Window")
        \\
        \\-- unmatched locale falls back to the plain key
        \\local plain = assert(apps.lookup("editor.desktop", { dirs = dirs, locale = "C" }))
        \\assert(plain.name == "Editor")
        \\
        \\-- desktop-id dashes map to subdirectories
        \\local viewer = assert(apps.lookup("org-example-Viewer", { dirs = dirs }))
        \\assert(viewer.name == "Viewer")
        \\
        \\-- missing entries report an error
        \\local missing, err = apps.lookup("nope", { dirs = dirs })
        \\assert(missing == nil and err ~= nil)
        \\
        \\-- exec expansion: %c name, %% literal, %F file list, %i icon pair
        \\local argv = assert(apps.exec_argv(plain, { files = { "/tmp/a b.txt", "/tmp/c.txt" } }))
        \\assert(argv[1] == "editor")
        \\assert(argv[2] == "--title")
        \\assert(argv[3] == "Editor")
        \\assert(argv[4] == "%x")
        \\assert(argv[5] == "/tmp/a b.txt")
        \\assert(argv[6] == "/tmp/c.txt")
        \\assert(argv[7] == "--icon-args")
        \\assert(argv[8] == "--icon")
        \\assert(argv[9] == "editor-icon")
        \\
        \\-- files convert to escaped file:// URIs for %U
        \\local uris = assert(apps.exec_argv(viewer, { files = { "/tmp/a b.txt" } }))
        \\assert(uris[1] == "viewer")
        \\assert(uris[2] == "file:///tmp/a%20b.txt")
        \\
        \\-- action Exec replaces the entry Exec
        \\local action_argv = assert(apps.exec_argv(plain, { action = "new-window" }))
        \\assert(action_argv[1] == "editor")
        \\assert(action_argv[2] == "--new-window")
        \\
        \\return kw.app({ child = kw.text("xdg") })
        \\
    ;
    const script = try std.mem.concat(allocator, u8, &.{ "local data_dir = \"", data_dir, "\"\n", script_body });
    defer allocator.free(script);

    var app = try initTestApp(allocator, &tmp, "xdg.lua", script);
    defer app.deinit();
    try app.ensureLoaded();
}

test "lua process.capture collects output and exit status" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\local kw = require("keywork")
        \\local process = require("keywork.process")
        \\local loop = require("keywork.loop")
        \\
        \\capture_done = false
        \\capture_ok = false
        \\local App = kw.stateful({
        \\  init = function(self)
        \\    loop.spawn(function()
        \\      local result = process.capture({
        \\        argv = { "/bin/sh", "-c", "printf out; printf err >&2; exit 3" },
        \\      })
        \\      capture_ok = result ~= nil
        \\        and result.stdout == "out"
        \\        and result.stderr == "err"
        \\        and result.ok == false
        \\        and result.code == 3
        \\      -- plain argv array form
        \\      local hello = process.capture({ "/usr/bin/printf", "hello" })
        \\      capture_ok = capture_ok
        \\        and hello ~= nil
        \\        and hello.stdout == "hello"
        \\        and hello.stderr == ""
        \\        and hello.ok
        \\        and hello.code == 0
        \\      -- missing executable reports nil, err
        \\      local missing, err = process.capture({ "keywork-test-no-such-binary" })
        \\      capture_ok = capture_ok and missing == nil and type(err) == "string"
        \\      capture_done = true
        \\    end)
        \\  end,
        \\  build = function(self, state)
        \\    return kw.text("capture")
        \\  end,
        \\})
        \\return kw.app({ child = App({ key = "app" }) })
        \\
    ;
    var app = try initTestApp(allocator, &tmp, "capture.lua", script);
    defer app.deinit();

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var log_backend: log_backend_mod.LogBackend = .{ .writer = &output.writer };
    var loop = try event_loop.EventLoop.init(allocator);
    defer loop.deinit();
    var runtime = try initTestRuntime(allocator, &log_backend, &app, .{ .max_width = 100, .max_height = 40 }, .no_preference);
    defer runtime.deinit();

    try runtime.repaint();

    app.bindRuntime(&runtime);
    defer app.unbindRuntime();
    try app.bindEventLoop(&loop);
    defer app.unbindEventLoop();
    try runUntilLuaBoolean(&loop, &app, "capture_done", 1000);

    try expectLuaBoolean(&app, "capture_done", true);
    try expectLuaBoolean(&app, "capture_ok", true);
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
    var app = try initTestApp(allocator, &tmp, "spawn-missing.lua", script);
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
    var app = try initTestApp(allocator, &tmp, "fs-event-missing.lua", script);
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
    var app = try initTestApp(allocator, &tmp, "spawn-rebind.lua", script);
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

    try runUntilLuaBoolean(&loop, &app, "spawn_done", 1000);

    try expectLuaBoolean(&app, "spawn_done", true);
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
    var app = try initTestApp(allocator, &tmp, "connect-missing.lua", script);
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
    var app = try initTestApp(allocator, &tmp, "socket-stream.lua", script);
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

    try runUntilLuaBoolean(&loop, &app, "done", 1000);

    try expectLuaBoolean(&app, "done", true);
    c.lua_getglobal(app.state, "received");
    try std.testing.expectEqualStrings("pong", try stringFromStack(app.state, -1));
    pop(app.state, 1);
    try expectLuaBoolean(&app, "closed_after", true);
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
        \\assert(reader:status() == "running")
        \\sock:close()
        \\assert(stream_ended)
        \\assert(reader:status() == "completed")
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
    var app = try initTestApp(allocator, &tmp, "socket-close.lua", script);
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
    var app = try initTestApp(allocator, &tmp, "socket-write.lua", script);
    defer app.deinit();
    try app.ensureLoaded();

    // The writer parked with unflushed bytes buffered.
    try expectLuaBoolean(&app, "wrote", false);
    try expectLuaBoolean(&app, "main_write_raised", true);
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

    try expectLuaBoolean(&app, "write_ok", true);
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
    var app = try initTestApp(allocator, &tmp, "stdin-roundtrip.lua", script);
    defer app.deinit();
    try app.ensureLoaded();
    try std.testing.expectEqual(@as(usize, 1), app.processes.items.len);
    // The writer parked with unflushed bytes buffered before the loop bound.
    try std.testing.expect(app.processes.items[0].stdin_sink.buffer.items.len > 0);

    var loop = try event_loop.EventLoop.init(allocator);
    defer loop.deinit();
    try app.bindEventLoop(&loop);
    defer app.unbindEventLoop();

    try runUntilLuaBoolean(&loop, &app, "done", 5000);

    try expectLuaBoolean(&app, "done", true);
    try expectLuaBoolean(&app, "write_ok", true);
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
    var app = try initTestApp(allocator, &tmp, "stdin-sync.lua", script);
    defer app.deinit();
    try app.ensureLoaded();

    try expectLuaBooleans(&app, &.{ "main_write_raised", "closed_write", "nopipe_raised", "dead_write" });
}
