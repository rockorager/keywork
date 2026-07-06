//! LuaJIT-backed widget descriptions.

const std = @import("std");
const keywork = @import("libkeywork");
const lua_codec = @import("lua_codec.zig");
const c = @import("luajit_c");
const dbus_c = @import("dbus_c");

const linux = std.os.linux;
const posix = std.posix;

const State = keywork.AppContext;
const BuildScope = keywork.BuildScope;

const app_registry_key = "keywork.app";
const invalid_fd: i32 = -1;
var dbus_temp_z_slot: usize = 0;
var dbus_temp_z_buffers: [8][4096]u8 = undefined;

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

const GestureOptions = struct {
    hover_background: ?keywork.Color = null,

    fn hoverStyle(self: GestureOptions) ?keywork.Widget.ClickableStyle {
        if (self.hover_background == null) return null;
        return .{ .background = self.hover_background };
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

const ImageOptions = struct {
    width: u32 = 0,
    height: u32 = 0,
    size: ?f32 = null,
    format: []const u8 = "argb32",
};

const ParseContext = struct {
    icon: IconOptions = .{},

    fn resolveIcon(self: ParseContext, options: IconOptions) struct { size: f32, color: ?keywork.Color } {
        return .{
            .size = options.size orelse self.icon.size orelse 16,
            // No explicit or ambient color renders the icon's own palette.
            .color = options.color orelse self.icon.color,
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
    main_align: ?keywork.Widget.MainAxisAlignment = null,

    fn crossAlign(self: LinearOptions) keywork.Widget.CrossAxisAlignment {
        return self.@"align" orelse .start;
    }

    fn mainAlign(self: LinearOptions) keywork.Widget.MainAxisAlignment {
        return self.main_align orelse .start;
    }
};

const FlexibleOptions = struct {
    flex: f32 = 1,
    fit: ?keywork.Widget.FlexFit = null,
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

    fn keyworkTextChangeCallback(self: *LuaCallback) keywork.Widget.TextChangeCallback {
        return .{
            .ptr = self,
            .call_fn = callTextChange,
            .clone_fn = clone,
            .destroy_fn = destroy,
        };
    }

    fn callTextChange(ptr: *anyopaque, text: []const u8) !void {
        const self: *LuaCallback = @ptrCast(@alignCast(ptr));
        c.lua_rawgeti(self.lua_state, c.LUA_REGISTRYINDEX, self.ref);
        c.lua_pushlstring(self.lua_state, text.ptr, text.len);
        if (c.lua_pcall(self.lua_state, 1, 0, 0) != 0) {
            var len: usize = 0;
            const message_ptr = c.lua_tolstring(self.lua_state, -1, &len);
            if (message_ptr) |message| std.log.scoped(.keywork_luajit).warn("text change callback failed: {s}", .{message[0..len]});
            pop(self.lua_state, 1);
            return error.LuaCallbackFailed;
        }
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
    spec_token: ?*const anyopaque = null,
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
        return .{
            .stateful = .{
                .ptr = self,
                .vtable = &vtable,
                .clone_fn = clone,
                .destroy_fn = destroy,
                // The spec table's address identifies the widget type; the
                // registry ref keeps the table (and thus the address) alive.
                .type_token = self.spec_token,
            },
        };
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
            .spec_token = self.spec_token,
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

const LuaImage = struct {
    width: u32,
    height: u32,
    size: f32,
    pixels: []keywork.Color,
    cache_key: u64,

    const vtable: keywork.Widget.RenderObject.VTable = .{
        .layout = layout,
        .paint = paint,
    };

    fn widget(self: *LuaImage) keywork.Widget {
        return .{ .render_object = .{
            .ptr = self,
            .vtable = &vtable,
            .clone_fn = clone,
            .destroy_fn = destroy,
        } };
    }

    fn layout(ptr: *const anyopaque, context: keywork.Widget.RenderObject.LayoutContext) !keywork.Size {
        const self: *const LuaImage = @ptrCast(@alignCast(ptr));
        return .{
            .width = @min(self.size, context.constraints.max_width),
            .height = @min(self.size, context.constraints.max_height),
        };
    }

    fn paint(ptr: *const anyopaque, context: keywork.Widget.RenderObject.PaintContext) !void {
        const self: *const LuaImage = @ptrCast(@alignCast(ptr));
        if (context.rect.width <= 0 or context.rect.height <= 0) return;
        const pixels = try context.allocator.dupe(keywork.Color, self.pixels);
        try context.display_list.colorImage(
            context.allocator,
            context.rect,
            self.width,
            self.height,
            pixels,
            self.cache_key,
        );
    }

    fn clone(allocator: std.mem.Allocator, ptr: *const anyopaque) !*anyopaque {
        const self: *const LuaImage = @ptrCast(@alignCast(ptr));
        const result = try allocator.create(LuaImage);
        errdefer allocator.destroy(result);
        result.* = .{
            .width = self.width,
            .height = self.height,
            .size = self.size,
            .pixels = try allocator.dupe(keywork.Color, self.pixels),
            .cache_key = self.cache_key,
        };
        return result;
    }

    fn destroy(allocator: std.mem.Allocator, ptr: *const anyopaque) void {
        const self: *LuaImage = @ptrCast(@alignCast(@constCast(ptr)));
        allocator.free(self.pixels);
        allocator.destroy(self);
    }
};

/// Window options declared by the script via keywork.window({...}).
/// Null fields fall back to CLI flags and built-in defaults.
pub const WindowConfig = struct {
    app_id: ?[:0]u8 = null,
    title: ?[:0]u8 = null,
    backend: ?keywork.BackendKind = null,
    width: ?f32 = null,
    height: ?f32 = null,
    layer_shell: ?keywork.LayerShellOptions = null,

    fn deinit(self: *WindowConfig, allocator: std.mem.Allocator) void {
        if (self.app_id) |value| allocator.free(value);
        if (self.title) |value| allocator.free(value);
        self.* = .{};
    }
};

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
    event_loop: ?*keywork.event_loop.EventLoop = null,
    runtime: ?*keywork.Runtime = null,

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
        self.window_config.deinit(self.allocator);
        self.allocator.free(self.path);
        self.allocator.free(self.chunk_name);
    }

    pub fn installEventSources(ctx: ?*anyopaque, loop: *keywork.event_loop.EventLoop, runtime: *keywork.Runtime) !void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        self.event_loop = loop;
        self.runtime = runtime;
        _ = loop.addFileWatch(self.path, self, scriptChanged) catch |err| {
            if (err != error.FileWatchNotFound) std.log.scoped(.keywork_luajit).warn("{s} watch not installed: {}", .{ self.path, err });
        };
        for (self.fd_watches.items) |watch| try self.registerFdWatch(watch);
        for (self.fs_events.items) |fs_event| try self.registerFsEvent(fs_event);
        for (self.timers.items) |timer| try self.registerTimer(timer);
        for (self.processes.items) |process| try self.registerProcess(process);
        for (self.dbus_buses.items) |bus| try self.registerDbusBus(bus);
    }

    pub fn host(self: *App) keywork.AppHost {
        return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidgetHost } };
    }

    /// Run the script if it has not executed yet (or is dirty). Called
    /// before keywork.run so top-level keywork.window declarations can
    /// shape the window, and again on every rebuild.
    pub fn ensureLoaded(self: *App) !void {
        if (self.script_dirty or self.script_ref < 0) try self.reloadScript();
    }

    pub fn buildWidget(self: *App, allocator: std.mem.Allocator, runtime_state: State) !keywork.Widget {
        try self.ensureLoaded();

        c.lua_settop(self.state, 0);
        c.lua_rawgeti(self.state, c.LUA_REGISTRYINDEX, self.script_ref);
        const widget = try parseWidget(self.state, allocator, allocator, runtime_state, .{}, -1);
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

        if (c.lua_type(self.state, -1) != c.LUA_TTABLE or !isWidgetTable(self.state, c.lua_gettop(self.state))) return error.ScriptReturnedInvalidValue;
        const script_ref = c.luaL_ref(self.state, c.LUA_REGISTRYINDEX);
        if (self.script_ref >= 0) c.luaL_unref(self.state, c.LUA_REGISTRYINDEX, self.script_ref);
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

    fn addFsEvent(self: *App, path: []const u8, ref: c_int) !*FsEvent {
        const fs_event = try self.allocator.create(FsEvent);
        errdefer self.allocator.destroy(fs_event);
        fs_event.* = .{
            .app = self,
            .path = try self.allocator.dupe(u8, path),
            .ref = ref,
        };
        errdefer self.allocator.free(fs_event.path);
        errdefer c.luaL_unref(self.state, c.LUA_REGISTRYINDEX, ref);

        try self.fs_events.append(self.allocator, fs_event);
        errdefer _ = self.fs_events.pop();
        try self.registerFsEvent(fs_event);
        return fs_event;
    }

    fn registerFsEvent(self: *App, fs_event: *FsEvent) !void {
        if (fs_event.registered or fs_event.canceled) return;
        const loop = self.event_loop orelse return;
        fs_event.watch = try loop.addFileWatch(fs_event.path, fs_event, fsEventCallback);
        fs_event.registered = true;
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

    fn addDbusBus(self: *App, kind: DbusBus.Kind) !*DbusBus {
        const bus = try self.allocator.create(DbusBus);
        errdefer self.allocator.destroy(bus);
        bus.* = try DbusBus.init(self, kind);
        errdefer bus.deinit(self.allocator, self.state);
        try bus.installFilter();

        try self.dbus_buses.append(self.allocator, bus);
        errdefer _ = self.dbus_buses.pop();
        try self.registerDbusBus(bus);
        return bus;
    }

    fn registerDbusBus(self: *App, bus: *DbusBus) !void {
        if (bus.registered or bus.closed) return;
        const loop = self.event_loop orelse return;
        try loop.addFd(.{
            .fd = bus.fd,
            .events = linux.EPOLL.IN | linux.EPOLL.HUP | linux.EPOLL.ERR,
            .ctx = bus,
            .callback = dbusBusCallback,
        });
        bus.registered = true;
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

const FsEvent = struct {
    app: *App,
    path: []const u8,
    ref: c_int,
    watch: ?*keywork.event_loop.EventLoop.FileWatch = null,
    registered: bool = false,
    canceled: bool = false,

    fn cancel(self: *FsEvent, lua_state: *c.lua_State) void {
        if (self.canceled) return;
        self.canceled = true;
        if (self.registered) {
            if (self.app.event_loop) |loop| if (self.watch) |watch| loop.removeFileWatch(watch);
            self.registered = false;
            self.watch = null;
        }
        if (self.ref >= 0) {
            c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, self.ref);
            self.ref = -1;
        }
    }

    fn destroy(self: *FsEvent, allocator: std.mem.Allocator, lua_state: *c.lua_State) void {
        if (self.ref >= 0) c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, self.ref);
        allocator.free(self.path);
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
            _ = linux.execve(executable.ptr, argv.ptr(), std.c.environ);
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

const DbusSubscription = struct {
    bus: *DbusBus,
    ref: c_int,
    match_rule: ?[:0]const u8 = null,
    sender: ?[]const u8 = null,
    path: ?[]const u8 = null,
    path_namespace: ?[]const u8 = null,
    interface: ?[]const u8 = null,
    member: ?[]const u8 = null,
    canceled: bool = false,

    fn cancel(self: *DbusSubscription, lua_state: *c.lua_State) void {
        if (self.canceled) return;
        self.canceled = true;
        if (self.match_rule) |rule| {
            if (!self.bus.closed) dbus_c.dbus_bus_remove_match(self.bus.connection, rule.ptr, null);
        }
        if (self.ref >= 0) {
            c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, self.ref);
            self.ref = -1;
        }
    }

    fn deinit(self: *DbusSubscription, allocator: std.mem.Allocator, lua_state: *c.lua_State) void {
        if (self.ref >= 0) c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, self.ref);
        if (self.match_rule) |rule| allocator.free(rule);
        if (self.sender) |value| allocator.free(value);
        if (self.path) |value| allocator.free(value);
        if (self.path_namespace) |value| allocator.free(value);
        if (self.interface) |value| allocator.free(value);
        if (self.member) |value| allocator.free(value);
    }

    fn destroy(self: *DbusSubscription, allocator: std.mem.Allocator, lua_state: *c.lua_State) void {
        self.deinit(allocator, lua_state);
        allocator.destroy(self);
    }

    fn matches(self: *const DbusSubscription, message: *dbus_c.DBusMessage) bool {
        if (self.canceled or self.ref < 0) return false;
        if (self.sender) |expected| {
            const actual = dbus_c.dbus_message_get_sender(message) orelse return false;
            if (!std.mem.eql(u8, expected, std.mem.span(actual))) return false;
        }
        if (self.interface) |expected| {
            const actual = dbus_c.dbus_message_get_interface(message) orelse return false;
            if (!std.mem.eql(u8, expected, std.mem.span(actual))) return false;
        }
        if (self.member) |expected| {
            const actual = dbus_c.dbus_message_get_member(message) orelse return false;
            if (!std.mem.eql(u8, expected, std.mem.span(actual))) return false;
        }
        if (self.path) |expected| {
            const actual = dbus_c.dbus_message_get_path(message) orelse return false;
            if (!std.mem.eql(u8, expected, std.mem.span(actual))) return false;
        }
        if (self.path_namespace) |expected| {
            const actual = dbus_c.dbus_message_get_path(message) orelse return false;
            if (!std.mem.startsWith(u8, std.mem.span(actual), expected)) return false;
        }
        return true;
    }
};

const DbusOwnedName = struct {
    bus: *DbusBus,
    name: [:0]const u8,
    released: bool = false,

    fn release(self: *DbusOwnedName) void {
        if (self.released) return;
        self.released = true;
        if (!self.bus.closed) _ = dbus_c.dbus_bus_release_name(self.bus.connection, self.name.ptr, null);
    }

    fn destroy(self: *DbusOwnedName, allocator: std.mem.Allocator) void {
        self.release();
        allocator.free(self.name);
        allocator.destroy(self);
    }
};

const DbusExportedObject = struct {
    bus: *DbusBus,
    path: [:0]const u8,
    ref: c_int,
    unexported: bool = false,

    fn unexport(self: *DbusExportedObject, lua_state: *c.lua_State) void {
        if (self.unexported) return;
        self.unexported = true;
        if (self.ref >= 0) {
            c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, self.ref);
            self.ref = -1;
        }
    }

    fn destroy(self: *DbusExportedObject, allocator: std.mem.Allocator, lua_state: *c.lua_State) void {
        self.unexport(lua_state);
        allocator.free(self.path);
        allocator.destroy(self);
    }
};

const DbusCall = struct {
    bus: *DbusBus,
    ref: c_int = -1,
    pending: ?*dbus_c.DBusPendingCall = null,
    completed: bool = false,

    fn complete(self: *DbusCall) !void {
        if (self.completed) return;
        self.completed = true;

        const lua_state = self.bus.app.state;
        c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, self.ref);

        const reply = if (self.pending) |pending| dbus_c.dbus_pending_call_steal_reply(pending) else null;
        if (reply) |message| {
            defer dbus_c.dbus_message_unref(message);
            if (dbus_c.dbus_message_get_type(message) == dbus_c.DBUS_MESSAGE_TYPE_ERROR) {
                c.lua_pushnil(lua_state);
                pushOptionalDbusString(lua_state, dbus_c.dbus_message_get_error_name(message));
                if (c.lua_pcall(lua_state, 2, 0, 0) != 0) return failLuaCall(lua_state, "dbus call callback failed");
            } else {
                pushDbusReply(lua_state, message);
                if (c.lua_pcall(lua_state, 1, 0, 0) != 0) return failLuaCall(lua_state, "dbus call callback failed");
            }
        } else {
            c.lua_pushnil(lua_state);
            c.lua_pushliteral(lua_state, "dbus call failed");
            if (c.lua_pcall(lua_state, 2, 0, 0) != 0) return failLuaCall(lua_state, "dbus call callback failed");
        }
    }

    fn deinit(self: *DbusCall, lua_state: *c.lua_State) void {
        if (self.pending) |pending| {
            // Clearing the notify guarantees libdbus never calls back with
            // this soon-to-be-freed state, regardless of cancel semantics.
            _ = dbus_c.dbus_pending_call_set_notify(pending, null, null, null);
            if (!self.completed) dbus_c.dbus_pending_call_cancel(pending);
            dbus_c.dbus_pending_call_unref(pending);
        }
        self.pending = null;
        if (self.ref >= 0) c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, self.ref);
        self.ref = -1;
    }

    fn destroy(self: *DbusCall, allocator: std.mem.Allocator, lua_state: *c.lua_State) void {
        self.deinit(lua_state);
        allocator.destroy(self);
    }
};

const DbusBus = struct {
    app: *App,
    kind: Kind,
    connection: *dbus_c.DBusConnection,
    fd: i32,
    subscriptions: std.ArrayList(*DbusSubscription) = .empty,
    pending_calls: std.ArrayList(*DbusCall) = .empty,
    owned_names: std.ArrayList(*DbusOwnedName) = .empty,
    exported_objects: std.ArrayList(*DbusExportedObject) = .empty,
    registered: bool = false,
    closed: bool = false,
    filter_installed: bool = false,

    const Kind = enum {
        session,
        system,

        fn busType(self: Kind) dbus_c.DBusBusType {
            return switch (self) {
                .session => dbus_c.DBUS_BUS_SESSION,
                .system => dbus_c.DBUS_BUS_SYSTEM,
            };
        }
    };

    fn init(app: *App, kind: Kind) !DbusBus {
        const connection = dbus_c.dbus_bus_get_private(kind.busType(), null) orelse return error.DBusUnavailable;
        errdefer {
            dbus_c.dbus_connection_close(connection);
            dbus_c.dbus_connection_unref(connection);
        }
        dbus_c.dbus_connection_set_exit_on_disconnect(connection, 0);
        var fd: c_int = -1;
        if (dbus_c.dbus_connection_get_unix_fd(connection, &fd) == 0 or fd < 0) return error.DBusUnavailable;
        const self: DbusBus = .{
            .app = app,
            .kind = kind,
            .connection = connection,
            .fd = @intCast(fd),
        };
        return self;
    }

    fn installFilter(self: *DbusBus) !void {
        if (self.filter_installed) return;
        if (dbus_c.dbus_connection_add_filter(self.connection, dbusFilter, self, null) == 0) return error.OutOfMemory;
        self.filter_installed = true;
    }

    fn close(self: *DbusBus) void {
        if (self.closed) return;
        self.closed = true;
        if (self.registered) {
            if (self.app.event_loop) |loop| loop.removeFd(self.fd);
            self.registered = false;
        }
        if (self.filter_installed) {
            dbus_c.dbus_connection_remove_filter(self.connection, dbusFilter, self);
            self.filter_installed = false;
        }
        dbus_c.dbus_connection_close(self.connection);
        dbus_c.dbus_connection_unref(self.connection);
        self.fd = invalid_fd;
    }

    fn deinit(self: *DbusBus, allocator: std.mem.Allocator, lua_state: *c.lua_State) void {
        for (self.exported_objects.items) |object| object.destroy(allocator, lua_state);
        self.exported_objects.deinit(allocator);
        for (self.owned_names.items) |name| name.destroy(allocator);
        self.owned_names.deinit(allocator);
        for (self.subscriptions.items) |subscription| subscription.destroy(allocator, lua_state);
        self.subscriptions.deinit(allocator);
        for (self.pending_calls.items) |pending_call| pending_call.destroy(allocator, lua_state);
        self.pending_calls.deinit(allocator);
        self.close();
    }

    fn destroy(self: *DbusBus, allocator: std.mem.Allocator, lua_state: *c.lua_State) void {
        self.deinit(allocator, lua_state);
        allocator.destroy(self);
    }

    fn subscribe(self: *DbusBus, lua_state: *c.lua_State, options_index: c_int, callback_index: c_int) !*DbusSubscription {
        const subscription = try self.app.allocator.create(DbusSubscription);
        errdefer self.app.allocator.destroy(subscription);

        subscription.* = .{
            .bus = self,
            .ref = -1,
            .sender = try optionalStringFieldDupe(lua_state, self.app.allocator, options_index, "sender"),
            .path = try optionalStringFieldDupe(lua_state, self.app.allocator, options_index, "path"),
            .path_namespace = try optionalStringFieldDupe(lua_state, self.app.allocator, options_index, "path_namespace"),
            .interface = try optionalStringFieldDupe(lua_state, self.app.allocator, options_index, "interface"),
            .member = try optionalStringFieldDupe(lua_state, self.app.allocator, options_index, "member"),
        };
        errdefer subscription.deinit(self.app.allocator, lua_state);
        subscription.match_rule = try buildDbusMatchRule(self.app.allocator, subscription);
        dbus_c.dbus_bus_add_match(self.connection, subscription.match_rule.?.ptr, null);

        c.lua_pushvalue(lua_state, callback_index);
        subscription.ref = c.luaL_ref(lua_state, c.LUA_REGISTRYINDEX);

        try self.subscriptions.append(self.app.allocator, subscription);
        return subscription;
    }

    fn requestName(self: *DbusBus, lua_state: *c.lua_State, options_index: c_int) !*DbusOwnedName {
        const name = try stringFromStack(lua_state, options_index);
        var flags: c_uint = 0;
        if (c.lua_type(lua_state, options_index + 1) == c.LUA_TTABLE) {
            if (boolField(lua_state, options_index + 1, "allow_replacement")) flags |= 0x1;
            if (boolField(lua_state, options_index + 1, "replace_existing")) flags |= 0x2;
            if (boolField(lua_state, options_index + 1, "do_not_queue")) flags |= 0x4;
        }
        const result = dbus_c.dbus_bus_request_name(self.connection, tryZTemp(name).ptr, flags, null);
        if (result != 1 and result != 4) return error.DBusNameUnavailable;

        const owned = try self.app.allocator.create(DbusOwnedName);
        errdefer self.app.allocator.destroy(owned);
        owned.* = .{
            .bus = self,
            .name = try self.app.allocator.dupeZ(u8, name),
        };
        errdefer self.app.allocator.free(owned.name);
        try self.owned_names.append(self.app.allocator, owned);
        return owned;
    }

    fn releaseName(self: *DbusBus, name: []const u8) void {
        for (self.owned_names.items) |owned| {
            if (std.mem.eql(u8, owned.name, name)) {
                owned.release();
                return;
            }
        }
        if (!self.closed) _ = dbus_c.dbus_bus_release_name(self.connection, tryZTemp(name).ptr, null);
    }

    fn exportObject(self: *DbusBus, lua_state: *c.lua_State, path_index: c_int, spec_index: c_int) !*DbusExportedObject {
        const path = try stringFromStack(lua_state, path_index);
        try expectType(lua_state, spec_index, c.LUA_TTABLE);
        const object = try self.app.allocator.create(DbusExportedObject);
        errdefer self.app.allocator.destroy(object);
        c.lua_pushvalue(lua_state, spec_index);
        object.* = .{
            .bus = self,
            .path = try self.app.allocator.dupeZ(u8, path),
            .ref = c.luaL_ref(lua_state, c.LUA_REGISTRYINDEX),
        };
        errdefer object.destroy(self.app.allocator, lua_state);
        try self.exported_objects.append(self.app.allocator, object);
        return object;
    }

    fn exportedObjectForPath(self: *DbusBus, path_z: [*:0]const u8) ?*DbusExportedObject {
        const path = std.mem.span(path_z);
        for (self.exported_objects.items) |object| {
            if (!object.unexported and std.mem.eql(u8, object.path, path)) return object;
        }
        return null;
    }

    fn call(self: *DbusBus, lua_state: *c.lua_State, options_index: c_int, callback_index: c_int) !void {
        const destination = try stringField(lua_state, options_index, "destination");
        const path = try stringField(lua_state, options_index, "path");
        const interface = try stringField(lua_state, options_index, "interface");
        const member = try stringField(lua_state, options_index, "member");
        const message = dbus_c.dbus_message_new_method_call(destination.ptr, path.ptr, interface.ptr, member.ptr) orelse return error.OutOfMemory;
        defer dbus_c.dbus_message_unref(message);

        var iter: dbus_c.DBusMessageIter = undefined;
        dbus_c.dbus_message_iter_init_append(message, &iter);
        try appendDbusLuaArgs(lua_state, options_index, &iter);

        const timeout_ms = getIntegerField(lua_state, options_index, "timeout_ms", 1000);
        const call_state = try self.app.allocator.create(DbusCall);
        errdefer self.app.allocator.destroy(call_state);
        c.lua_pushvalue(lua_state, callback_index);
        call_state.* = .{
            .bus = self,
            .ref = c.luaL_ref(lua_state, c.LUA_REGISTRYINDEX),
        };
        errdefer call_state.deinit(lua_state);

        var pending: ?*dbus_c.DBusPendingCall = null;
        if (dbus_c.dbus_connection_send_with_reply(self.connection, message, &pending, @intCast(timeout_ms)) == 0) return error.OutOfMemory;
        call_state.pending = pending orelse return error.DBusCallFailed;

        try self.pending_calls.append(self.app.allocator, call_state);
        errdefer _ = self.removePendingCall(call_state);
        if (dbus_c.dbus_pending_call_set_notify(call_state.pending, dbusCallNotify, call_state, null) == 0) return error.OutOfMemory;
        dbus_c.dbus_connection_flush(self.connection);
    }

    fn removePendingCall(self: *DbusBus, pending_call: *DbusCall) bool {
        for (self.pending_calls.items, 0..) |item, index| {
            if (item == pending_call) {
                _ = self.pending_calls.swapRemove(index);
                return true;
            }
        }
        return false;
    }

    fn dispatch(self: *DbusBus) void {
        _ = dbus_c.dbus_connection_read_write(self.connection, 0);
        while (dbus_c.dbus_connection_dispatch(self.connection) == dbus_c.DBUS_DISPATCH_DATA_REMAINS) {}
    }

    fn emitSignal(self: *DbusBus, lua_state: *c.lua_State, options_index: c_int) !void {
        const path = try stringField(lua_state, options_index, "path");
        const interface = try stringField(lua_state, options_index, "interface");
        const member = try stringField(lua_state, options_index, "member");
        const message = dbus_c.dbus_message_new_signal(path.ptr, interface.ptr, member.ptr) orelse return error.OutOfMemory;
        defer dbus_c.dbus_message_unref(message);
        var iter: dbus_c.DBusMessageIter = undefined;
        dbus_c.dbus_message_iter_init_append(message, &iter);
        try appendDbusLuaArgs(lua_state, options_index, &iter);
        if (dbus_c.dbus_connection_send(self.connection, message, null) == 0) return error.OutOfMemory;
        dbus_c.dbus_connection_flush(self.connection);
    }

    fn handleSignal(self: *DbusBus, message: *dbus_c.DBusMessage) !void {
        const lua_state = self.app.state;
        for (self.subscriptions.items) |subscription| {
            if (!subscription.matches(message)) continue;
            c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, subscription.ref);
            pushDbusSignal(lua_state, message);
            if (c.lua_pcall(lua_state, 1, 0, 0) != 0) {
                failLuaCall(lua_state, "dbus signal callback failed") catch {};
                return error.LuaCallbackFailed;
            }
        }
    }

    fn handleMethodCall(self: *DbusBus, message: *dbus_c.DBusMessage) !bool {
        const path_z = dbus_c.dbus_message_get_path(message) orelse return false;
        const object = self.exportedObjectForPath(path_z) orelse return false;
        const interface_z = dbus_c.dbus_message_get_interface(message) orelse return false;
        const member_z = dbus_c.dbus_message_get_member(message) orelse return false;
        const interface = std.mem.span(interface_z);
        const member = std.mem.span(member_z);

        if (std.mem.eql(u8, interface, "org.freedesktop.DBus.Properties")) {
            std.log.scoped(.keywork_luajit).info("dbus properties call {s}.{s}", .{ interface, member });
            try self.handlePropertiesMethod(object, message, member);
            return true;
        }
        if (std.mem.eql(u8, interface, "org.freedesktop.DBus.Introspectable") and std.mem.eql(u8, member, "Introspect")) {
            std.log.scoped(.keywork_luajit).info("dbus introspect {s}", .{object.path});
            const xml = try buildDbusIntrospectionXml(self.app.allocator, self.app.state, object);
            defer self.app.allocator.free(xml);
            try self.replyString(message, xml);
            return true;
        }
        return try self.callExportedMethod(object, message, interface, member);
    }

    fn callExportedMethod(self: *DbusBus, object: *DbusExportedObject, message: *dbus_c.DBusMessage, interface: []const u8, member: []const u8) !bool {
        const lua_state = self.app.state;
        const original_top = c.lua_gettop(lua_state);
        defer c.lua_settop(lua_state, original_top);

        c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, object.ref);
        c.lua_getfield(lua_state, -1, tryZTemp(interface).ptr);
        if (c.lua_isnil(lua_state, -1)) return false;
        c.lua_getfield(lua_state, -1, "methods");
        if (c.lua_isnil(lua_state, -1)) return false;
        c.lua_getfield(lua_state, -1, tryZTemp(member).ptr);
        if (c.lua_isnil(lua_state, -1)) return false;
        c.lua_getfield(lua_state, -1, "call");
        if (c.lua_type(lua_state, -1) != c.LUA_TFUNCTION) return false;

        std.log.scoped(.keywork_luajit).info("dbus method call {s}.{s}", .{ interface, member });
        pushDbusCallTable(lua_state, message);
        const arg_count = pushDbusMessageArgs(lua_state, message);
        const return_base = c.lua_gettop(lua_state) - @as(c_int, @intCast(arg_count)) - 1;
        if (c.lua_pcall(lua_state, @intCast(arg_count + 1), c.LUA_MULTRET, 0) != 0) {
            const error_message = stringFromStack(lua_state, -1) catch "Lua D-Bus method failed";
            try self.replyError(message, "org.keywork.LuaError", error_message);
            return true;
        }
        const after_top = c.lua_gettop(lua_state);
        const return_count: usize = if (after_top < return_base) 0 else @intCast(after_top - return_base + 1);
        try self.replyValues(message, lua_state, return_base, return_count);
        return true;
    }

    fn handlePropertiesMethod(self: *DbusBus, object: *DbusExportedObject, message: *dbus_c.DBusMessage, member: []const u8) !void {
        if (std.mem.eql(u8, member, "Get")) {
            const pair = methodCallStringPair(message) orelse {
                try self.replyError(message, "org.freedesktop.DBus.Error.InvalidArgs", "Get requires interface and property");
                return;
            };
            try self.replyPropertyGet(object, message, pair.interface, pair.property);
        } else if (std.mem.eql(u8, member, "GetAll")) {
            const interface = methodCallString(message, 0) orelse {
                try self.replyError(message, "org.freedesktop.DBus.Error.InvalidArgs", "GetAll requires interface");
                return;
            };
            try self.replyPropertiesGetAll(object, message, interface);
        } else {
            try self.replyError(message, "org.freedesktop.DBus.Error.UnknownMethod", "unsupported Properties method");
        }
    }

    fn replyValues(self: *DbusBus, message: *dbus_c.DBusMessage, lua_state: *c.lua_State, first_index: c_int, count: usize) !void {
        const reply = dbus_c.dbus_message_new_method_return(message) orelse return error.OutOfMemory;
        defer dbus_c.dbus_message_unref(reply);
        var iter: dbus_c.DBusMessageIter = undefined;
        dbus_c.dbus_message_iter_init_append(reply, &iter);
        var offset: usize = 0;
        while (offset < count) : (offset += 1) {
            const index = first_index + @as(c_int, @intCast(offset));
            if (c.lua_isnil(lua_state, index)) continue;
            try appendLuaValueToDbusIter(lua_state, index, &iter);
        }
        if (dbus_c.dbus_connection_send(self.connection, reply, null) == 0) return error.OutOfMemory;
        dbus_c.dbus_connection_flush(self.connection);
    }

    fn replyString(self: *DbusBus, message: *dbus_c.DBusMessage, value: []const u8) !void {
        const reply = dbus_c.dbus_message_new_method_return(message) orelse return error.OutOfMemory;
        defer dbus_c.dbus_message_unref(reply);
        var iter: dbus_c.DBusMessageIter = undefined;
        dbus_c.dbus_message_iter_init_append(reply, &iter);
        var value_z = tryZTemp(value);
        try appendDbusBasic(&iter, dbus_c.DBUS_TYPE_STRING, &value_z.ptr);
        if (dbus_c.dbus_connection_send(self.connection, reply, null) == 0) return error.OutOfMemory;
        dbus_c.dbus_connection_flush(self.connection);
    }

    fn replyError(self: *DbusBus, message: *dbus_c.DBusMessage, name: []const u8, text: []const u8) !void {
        const error_message = dbus_c.dbus_message_new_error(message, tryZTemp(name).ptr, tryZTemp(text).ptr) orelse return error.OutOfMemory;
        defer dbus_c.dbus_message_unref(error_message);
        if (dbus_c.dbus_connection_send(self.connection, error_message, null) == 0) return error.OutOfMemory;
        dbus_c.dbus_connection_flush(self.connection);
    }

    fn replyPropertyGet(self: *DbusBus, object: *DbusExportedObject, message: *dbus_c.DBusMessage, interface: []const u8, property: []const u8) !void {
        const lua_state = self.app.state;
        const original_top = c.lua_gettop(lua_state);
        defer c.lua_settop(lua_state, original_top);
        try pushPropertyGetterResult(lua_state, object, interface, property);
        const signature = try propertySignature(lua_state, object, interface, property);

        const reply = dbus_c.dbus_message_new_method_return(message) orelse return error.OutOfMemory;
        defer dbus_c.dbus_message_unref(reply);
        var iter: dbus_c.DBusMessageIter = undefined;
        dbus_c.dbus_message_iter_init_append(reply, &iter);
        var variant: dbus_c.DBusMessageIter = undefined;
        if (dbus_c.dbus_message_iter_open_container(&iter, dbus_c.DBUS_TYPE_VARIANT, tryZTemp(signature).ptr, &variant) == 0) return error.OutOfMemory;
        try appendLuaValueWithSignature(lua_state, -1, signature, &variant);
        if (dbus_c.dbus_message_iter_close_container(&iter, &variant) == 0) return error.OutOfMemory;
        if (dbus_c.dbus_connection_send(self.connection, reply, null) == 0) return error.OutOfMemory;
        dbus_c.dbus_connection_flush(self.connection);
    }

    fn replyPropertiesGetAll(self: *DbusBus, object: *DbusExportedObject, message: *dbus_c.DBusMessage, interface: []const u8) !void {
        const lua_state = self.app.state;
        const original_top = c.lua_gettop(lua_state);
        defer c.lua_settop(lua_state, original_top);

        const reply = dbus_c.dbus_message_new_method_return(message) orelse return error.OutOfMemory;
        defer dbus_c.dbus_message_unref(reply);
        var iter: dbus_c.DBusMessageIter = undefined;
        dbus_c.dbus_message_iter_init_append(reply, &iter);
        var array: dbus_c.DBusMessageIter = undefined;
        if (dbus_c.dbus_message_iter_open_container(&iter, dbus_c.DBUS_TYPE_ARRAY, "{sv}", &array) == 0) return error.OutOfMemory;

        c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, object.ref);
        c.lua_getfield(lua_state, -1, tryZTemp(interface).ptr);
        if (!c.lua_isnil(lua_state, -1)) {
            c.lua_getfield(lua_state, -1, "properties");
            if (!c.lua_isnil(lua_state, -1)) {
                c.lua_pushnil(lua_state);
                while (c.lua_next(lua_state, -2) != 0) {
                    if (c.lua_type(lua_state, -2) != c.LUA_TSTRING or c.lua_type(lua_state, -1) != c.LUA_TTABLE) {
                        pop(lua_state, 1);
                        continue;
                    }
                    const property_name = try stringFromStack(lua_state, -2);
                    c.lua_getfield(lua_state, -1, "signature");
                    const signature = stringFromStack(lua_state, -1) catch {
                        pop(lua_state, 1);
                        pop(lua_state, 1);
                        continue;
                    };
                    pop(lua_state, 1);
                    c.lua_getfield(lua_state, -1, "get");
                    if (c.lua_type(lua_state, -1) != c.LUA_TFUNCTION) {
                        pop(lua_state, 2);
                        continue;
                    }
                    if (c.lua_pcall(lua_state, 0, 1, 0) != 0) {
                        pop(lua_state, 2);
                        continue;
                    }
                    try appendPropertyDictEntry(lua_state, &array, property_name, signature, -1);
                    pop(lua_state, 2);
                }
            }
        }
        if (dbus_c.dbus_message_iter_close_container(&iter, &array) == 0) return error.OutOfMemory;
        if (dbus_c.dbus_connection_send(self.connection, reply, null) == 0) return error.OutOfMemory;
        dbus_c.dbus_connection_flush(self.connection);
    }
};

fn dbusCallNotify(_: ?*dbus_c.DBusPendingCall, user_data: ?*anyopaque) callconv(.c) void {
    const call: *DbusCall = @ptrCast(@alignCast(user_data orelse return));
    call.complete() catch |err| {
        std.log.scoped(.keywork_luajit).warn("dbus call callback failed: {}", .{err});
    };
    _ = call.bus.removePendingCall(call);
    call.destroy(call.bus.app.allocator, call.bus.app.state);
}

fn dbusBusCallback(ctx: *anyopaque, _: *keywork.event_loop.EventLoop, _: u32) !void {
    const bus: *DbusBus = @ptrCast(@alignCast(ctx));
    if (bus.closed) return;
    bus.dispatch();
}

fn dbusFilter(_: ?*dbus_c.DBusConnection, message: ?*dbus_c.DBusMessage, user_data: ?*anyopaque) callconv(.c) dbus_c.DBusHandlerResult {
    const bus: *DbusBus = @ptrCast(@alignCast(user_data orelse return dbus_c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED));
    const msg = message orelse return dbus_c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    switch (dbus_c.dbus_message_get_type(msg)) {
        dbus_c.DBUS_MESSAGE_TYPE_SIGNAL => {
            bus.handleSignal(msg) catch |err| {
                std.log.scoped(.keywork_luajit).warn("dbus signal dispatch failed: {}", .{err});
            };
            return dbus_c.DBUS_HANDLER_RESULT_HANDLED;
        },
        dbus_c.DBUS_MESSAGE_TYPE_METHOD_CALL => {
            const handled = bus.handleMethodCall(msg) catch |err| blk: {
                std.log.scoped(.keywork_luajit).warn("dbus method dispatch failed: {}", .{err});
                break :blk true;
            };
            return if (handled) dbus_c.DBUS_HANDLER_RESULT_HANDLED else dbus_c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
        },
        else => return dbus_c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED,
    }
}

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

fn fsEventCallback(ctx: *anyopaque, _: *keywork.event_loop.EventLoop, path: []const u8, mask: u32, name: ?[]const u8) !void {
    const fs_event: *FsEvent = @ptrCast(@alignCast(ctx));
    if (fs_event.canceled or fs_event.ref < 0) return;
    const app = fs_event.app;
    c.lua_rawgeti(app.state, c.LUA_REGISTRYINDEX, fs_event.ref);
    pushFsEvent(app.state, path, mask, name);
    if (c.lua_pcall(app.state, 1, 1, 0) != 0) {
        var len: usize = 0;
        const message_ptr = c.lua_tolstring(app.state, -1, &len);
        if (message_ptr) |message| std.log.scoped(.keywork_luajit).warn("fs_event callback failed: {s}", .{message[0..len]});
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
    addPackagePath(lua_state, "src/?.lua");

    // Fallback loader appended after the standard searchers so a
    // checkout's src/ui.lua wins during development while shipped
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
    if (!std.mem.eql(u8, name_ptr[0..len], "ui")) {
        const message = "\n\tno embedded keywork module";
        c.lua_pushlstring(lua_state, message.ptr, message.len);
        return 1;
    }
    if (c.luaL_loadbuffer(lua_state, embedded_ui_source.ptr, embedded_ui_source.len, "@ui.lua") != 0) {
        return c.lua_error(lua_state);
    }
    return 1;
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
    c.lua_createtable(lua_state, 0, 5);
    const table = c.lua_gettop(lua_state);

    c.lua_createtable(lua_state, 0, 4);
    const loop_table = c.lua_gettop(lua_state);
    c.lua_pushlightuserdata(lua_state, app);
    c.lua_pushcclosure(lua_state, luaLoopTimer, 1);
    c.lua_setfield(lua_state, loop_table, "timer");
    c.lua_pushlightuserdata(lua_state, app);
    c.lua_pushcclosure(lua_state, luaWatchFd, 1);
    c.lua_setfield(lua_state, loop_table, "fd");
    c.lua_pushlightuserdata(lua_state, app);
    c.lua_pushcclosure(lua_state, luaFsEvent, 1);
    c.lua_setfield(lua_state, loop_table, "fs_event");
    c.lua_pushlightuserdata(lua_state, app);
    c.lua_pushcclosure(lua_state, luaSpawn, 1);
    c.lua_setfield(lua_state, loop_table, "spawn");
    c.lua_setfield(lua_state, table, "loop");

    c.lua_createtable(lua_state, 0, 16);
    const dbus_table = c.lua_gettop(lua_state);
    c.lua_pushlightuserdata(lua_state, app);
    c.lua_pushcclosure(lua_state, luaDbusSession, 1);
    c.lua_setfield(lua_state, dbus_table, "session");
    c.lua_pushlightuserdata(lua_state, app);
    c.lua_pushcclosure(lua_state, luaDbusSystem, 1);
    c.lua_setfield(lua_state, dbus_table, "system");
    c.lua_pushcclosure(lua_state, luaDbusString, 0);
    c.lua_setfield(lua_state, dbus_table, "string");
    c.lua_pushcclosure(lua_state, luaDbusObjectPath, 0);
    c.lua_setfield(lua_state, dbus_table, "object_path");
    c.lua_pushcclosure(lua_state, luaDbusBoolean, 0);
    c.lua_setfield(lua_state, dbus_table, "boolean");
    c.lua_pushcclosure(lua_state, luaDbusInt32, 0);
    c.lua_setfield(lua_state, dbus_table, "int32");
    c.lua_pushcclosure(lua_state, luaDbusUint32, 0);
    c.lua_setfield(lua_state, dbus_table, "uint32");
    c.lua_pushcclosure(lua_state, luaDbusDouble, 0);
    c.lua_setfield(lua_state, dbus_table, "double");
    c.lua_pushcclosure(lua_state, luaDbusArray, 0);
    c.lua_setfield(lua_state, dbus_table, "array");
    c.lua_pushcclosure(lua_state, luaDbusVariant, 0);
    c.lua_setfield(lua_state, dbus_table, "variant");
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

    c.lua_pushlightuserdata(lua_state, app);
    c.lua_pushcclosure(lua_state, luaWindow, 1);
    c.lua_setfield(lua_state, table, "window");
    return 1;
}

/// Read an optional string field from a table. Raises a Lua error for
/// non-string values. The returned slice stays valid while the table is
/// reachable: the string is anchored by the table field itself.
fn checkStringField(lua_state: *c.lua_State, table_index: c_int, name: [:0]const u8) ?[]const u8 {
    c.lua_getfield(lua_state, table_index, name.ptr);
    defer pop(lua_state, 1);
    switch (c.lua_type(lua_state, -1)) {
        c.LUA_TNIL => return null,
        c.LUA_TSTRING => {},
        else => {
            _ = c.luaL_error(lua_state, "window option '%s' must be a string", name.ptr);
            unreachable;
        },
    }
    var len: usize = 0;
    const ptr = c.lua_tolstring(lua_state, -1, &len).?;
    return ptr[0..len];
}

/// Read an optional number field from a table. Raises a Lua error for
/// non-number values.
fn checkNumberField(lua_state: *c.lua_State, table_index: c_int, name: [:0]const u8) ?f64 {
    c.lua_getfield(lua_state, table_index, name.ptr);
    defer pop(lua_state, 1);
    switch (c.lua_type(lua_state, -1)) {
        c.LUA_TNIL => return null,
        c.LUA_TNUMBER => return c.lua_tonumber(lua_state, -1),
        else => {
            _ = c.luaL_error(lua_state, "window option '%s' must be a number", name.ptr);
            unreachable;
        },
    }
}

fn checkI32Field(lua_state: *c.lua_State, table_index: c_int, name: [:0]const u8) ?i32 {
    const value = checkNumberField(lua_state, table_index, name) orelse return null;
    const min: f64 = @floatFromInt(std.math.minInt(i32));
    const max: f64 = @floatFromInt(std.math.maxInt(i32));
    if (!std.math.isFinite(value) or value < min or value > max) {
        _ = c.luaL_error(lua_state, "window option '%s' is out of range", name.ptr);
        unreachable;
    }
    return @intFromFloat(value);
}

fn backendFromName(name: []const u8) ?keywork.BackendKind {
    if (std.mem.eql(u8, name, "cpu")) return .wayland_shm;
    if (std.mem.eql(u8, name, "vulkan")) return .vulkan;
    if (std.mem.eql(u8, name, "log")) return .log;
    return null;
}

fn parseLayerShellTable(lua_state: *c.lua_State, table_index: c_int) keywork.LayerShellOptions {
    var options: keywork.LayerShellOptions = .{};

    if (checkStringField(lua_state, table_index, "layer")) |name| {
        options.layer = if (std.mem.eql(u8, name, "background"))
            .background
        else if (std.mem.eql(u8, name, "bottom"))
            .bottom
        else if (std.mem.eql(u8, name, "top"))
            .top
        else if (std.mem.eql(u8, name, "overlay"))
            .overlay
        else {
            _ = c.luaL_error(lua_state, "unknown layer '%s' (expected background, bottom, top, or overlay)", name.ptr);
            unreachable;
        };
    }

    c.lua_getfield(lua_state, table_index, "anchor");
    switch (c.lua_type(lua_state, -1)) {
        c.LUA_TNIL => {},
        c.LUA_TTABLE => {
            const anchor_table = c.lua_gettop(lua_state);
            const count: usize = @intCast(c.lua_objlen(lua_state, anchor_table));
            var index: usize = 1;
            while (index <= count) : (index += 1) {
                c.lua_rawgeti(lua_state, anchor_table, @intCast(index));
                if (c.lua_type(lua_state, -1) != c.LUA_TSTRING) {
                    _ = c.luaL_error(lua_state, "anchor entries must be strings");
                    unreachable;
                }
                var len: usize = 0;
                const ptr = c.lua_tolstring(lua_state, -1, &len).?;
                const name = ptr[0..len];
                if (std.mem.eql(u8, name, "top")) {
                    options.anchors.top = true;
                } else if (std.mem.eql(u8, name, "bottom")) {
                    options.anchors.bottom = true;
                } else if (std.mem.eql(u8, name, "left")) {
                    options.anchors.left = true;
                } else if (std.mem.eql(u8, name, "right")) {
                    options.anchors.right = true;
                } else {
                    _ = c.luaL_error(lua_state, "unknown anchor '%s' (expected top, bottom, left, or right)", ptr);
                    unreachable;
                }
                pop(lua_state, 1);
            }
        },
        else => {
            _ = c.luaL_error(lua_state, "layer_shell.anchor must be an array of strings");
            unreachable;
        },
    }
    pop(lua_state, 1);

    if (checkI32Field(lua_state, table_index, "exclusive_zone")) |value| options.exclusive_zone = value;

    c.lua_getfield(lua_state, table_index, "margin");
    switch (c.lua_type(lua_state, -1)) {
        c.LUA_TNIL => {},
        c.LUA_TTABLE => {
            const margin_table = c.lua_gettop(lua_state);
            if (checkI32Field(lua_state, margin_table, "top")) |value| options.margin.top = value;
            if (checkI32Field(lua_state, margin_table, "right")) |value| options.margin.right = value;
            if (checkI32Field(lua_state, margin_table, "bottom")) |value| options.margin.bottom = value;
            if (checkI32Field(lua_state, margin_table, "left")) |value| options.margin.left = value;
        },
        else => {
            _ = c.luaL_error(lua_state, "layer_shell.margin must be a table");
            unreachable;
        },
    }
    pop(lua_state, 1);

    if (checkStringField(lua_state, table_index, "keyboard")) |name| {
        options.keyboard_interactivity = if (std.mem.eql(u8, name, "none"))
            .none
        else if (std.mem.eql(u8, name, "exclusive"))
            .exclusive
        else if (std.mem.eql(u8, name, "on-demand") or std.mem.eql(u8, name, "on_demand"))
            .on_demand
        else {
            _ = c.luaL_error(lua_state, "unknown keyboard interactivity '%s' (expected none, exclusive, or on-demand)", name.ptr);
            unreachable;
        };
    }

    return options;
}

fn luaWindow(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const app: *App = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    c.luaL_checktype(lua_state, 1, c.LUA_TTABLE);
    if (app.runtime != null) {
        std.log.scoped(.keywork_luajit).warn("keywork.window applies at startup; restart to pick up changes", .{});
        return 0;
    }

    // Validate everything before allocating so Lua errors cannot leak
    // partially-built configs.
    var config: WindowConfig = .{};
    if (checkStringField(lua_state, 1, "backend")) |name| {
        config.backend = backendFromName(name) orelse {
            _ = c.luaL_error(lua_state, "unknown backend '%s' (expected cpu, vulkan, or log)", name.ptr);
            unreachable;
        };
    }
    if (checkNumberField(lua_state, 1, "width")) |value| config.width = @floatCast(value);
    if (checkNumberField(lua_state, 1, "height")) |value| config.height = @floatCast(value);

    c.lua_getfield(lua_state, 1, "layer_shell");
    switch (c.lua_type(lua_state, -1)) {
        c.LUA_TNIL => {},
        c.LUA_TTABLE => config.layer_shell = parseLayerShellTable(lua_state, c.lua_gettop(lua_state)),
        else => {
            _ = c.luaL_error(lua_state, "window option 'layer_shell' must be a table");
            unreachable;
        },
    }
    pop(lua_state, 1);

    const app_id = checkStringField(lua_state, 1, "app_id");
    const title = checkStringField(lua_state, 1, "title");
    if (app_id) |value| {
        config.app_id = app.allocator.dupeZ(u8, value) catch return c.luaL_error(lua_state, "out of memory");
    }
    if (title) |value| {
        config.title = app.allocator.dupeZ(u8, value) catch {
            config.deinit(app.allocator);
            return c.luaL_error(lua_state, "out of memory");
        };
    }

    app.window_config.deinit(app.allocator);
    app.window_config = config;
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

fn luaFsEvent(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const app: *App = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    const path = fsEventPath(lua_state, 1) catch return c.luaL_error(lua_state, "fs_event requires a path");
    c.luaL_checktype(lua_state, 2, c.LUA_TFUNCTION);

    c.lua_pushvalue(lua_state, 2);
    const ref = c.luaL_ref(lua_state, c.LUA_REGISTRYINDEX);
    const fs_event = app.addFsEvent(path, ref) catch |err| {
        c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, ref);
        std.log.scoped(.keywork_luajit).warn("loop.fs_event failed: {}", .{err});
        return c.luaL_error(lua_state, "loop.fs_event failed");
    };
    pushFsEventHandle(lua_state, fs_event);
    return 1;
}

fn luaDbusString(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    return pushDbusTypedValue(lua_state_optional.?, "string", 1);
}

fn luaDbusObjectPath(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    return pushDbusTypedValue(lua_state_optional.?, "object_path", 1);
}

fn luaDbusBoolean(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    return pushDbusTypedValue(lua_state_optional.?, "boolean", 1);
}

fn luaDbusInt32(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    return pushDbusTypedValue(lua_state_optional.?, "int32", 1);
}

fn luaDbusUint32(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    return pushDbusTypedValue(lua_state_optional.?, "uint32", 1);
}

fn luaDbusDouble(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    return pushDbusTypedValue(lua_state_optional.?, "double", 1);
}

fn luaDbusArray(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    c.luaL_checktype(lua_state, 1, c.LUA_TSTRING);
    c.luaL_checktype(lua_state, 2, c.LUA_TTABLE);
    c.lua_createtable(lua_state, 0, 3);
    c.lua_pushliteral(lua_state, "array");
    c.lua_setfield(lua_state, -2, "__dbus_type");
    c.lua_pushvalue(lua_state, 1);
    c.lua_setfield(lua_state, -2, "signature");
    c.lua_pushvalue(lua_state, 2);
    c.lua_setfield(lua_state, -2, "value");
    return 1;
}

fn luaDbusVariant(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    c.luaL_checktype(lua_state, 1, c.LUA_TSTRING);
    c.lua_createtable(lua_state, 0, 3);
    c.lua_pushliteral(lua_state, "variant");
    c.lua_setfield(lua_state, -2, "__dbus_type");
    c.lua_pushvalue(lua_state, 1);
    c.lua_setfield(lua_state, -2, "signature");
    c.lua_pushvalue(lua_state, 2);
    c.lua_setfield(lua_state, -2, "value");
    return 1;
}

fn pushDbusTypedValue(lua_state: *c.lua_State, comptime type_name: [:0]const u8, value_index: c_int) c_int {
    c.lua_createtable(lua_state, 0, 2);
    c.lua_pushstring(lua_state, type_name.ptr);
    c.lua_setfield(lua_state, -2, "__dbus_type");
    c.lua_pushvalue(lua_state, value_index);
    c.lua_setfield(lua_state, -2, "value");
    return 1;
}

fn luaDbusSession(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    return luaDbusBus(lua_state_optional, .session);
}

fn luaDbusSystem(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    return luaDbusBus(lua_state_optional, .system);
}

fn luaDbusBus(lua_state_optional: ?*c.lua_State, kind: DbusBus.Kind) c_int {
    const lua_state = lua_state_optional.?;
    const app: *App = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    const bus = app.addDbusBus(kind) catch |err| {
        std.log.scoped(.keywork_luajit).warn("dbus bus failed: {}", .{err});
        return c.luaL_error(lua_state, "dbus bus failed");
    };
    pushDbusBusHandle(lua_state, bus);
    return 1;
}

fn luaDbusSubscribe(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const bus: *DbusBus = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    if (bus.closed) return c.luaL_error(lua_state, "dbus bus is closed");
    const options_index: c_int = if (c.lua_type(lua_state, 3) == c.LUA_TFUNCTION) 2 else 1;
    const callback_index: c_int = options_index + 1;
    c.luaL_checktype(lua_state, options_index, c.LUA_TTABLE);
    c.luaL_checktype(lua_state, callback_index, c.LUA_TFUNCTION);
    const subscription = bus.subscribe(lua_state, options_index, callback_index) catch |err| {
        std.log.scoped(.keywork_luajit).warn("dbus subscribe failed: {}", .{err});
        return c.luaL_error(lua_state, "dbus subscribe failed");
    };
    pushDbusSubscriptionHandle(lua_state, subscription);
    return 1;
}

fn luaDbusCall(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const bus: *DbusBus = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    if (bus.closed) return c.luaL_error(lua_state, "dbus bus is closed");
    const options_index: c_int = if (c.lua_type(lua_state, 3) == c.LUA_TFUNCTION) 2 else 1;
    const callback_index: c_int = options_index + 1;
    c.luaL_checktype(lua_state, options_index, c.LUA_TTABLE);
    c.luaL_checktype(lua_state, callback_index, c.LUA_TFUNCTION);
    bus.call(lua_state, options_index, callback_index) catch |err| {
        std.log.scoped(.keywork_luajit).warn("dbus call failed: {}", .{err});
        return c.luaL_error(lua_state, "dbus call failed");
    };
    return 0;
}

fn luaDbusRequestName(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const bus: *DbusBus = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    if (bus.closed) return c.luaL_error(lua_state, "dbus bus is closed");
    const name_index: c_int = if (c.lua_type(lua_state, 2) == c.LUA_TSTRING) 2 else 1;
    const owned = bus.requestName(lua_state, name_index) catch |err| {
        std.log.scoped(.keywork_luajit).warn("dbus request_name failed: {}", .{err});
        return c.luaL_error(lua_state, "dbus request_name failed");
    };
    pushDbusOwnedNameHandle(lua_state, owned);
    return 1;
}

fn luaDbusReleaseName(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const bus: *DbusBus = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    const name_index: c_int = if (c.lua_type(lua_state, 2) == c.LUA_TSTRING) 2 else 1;
    const name = stringFromStack(lua_state, name_index) catch return c.luaL_error(lua_state, "release_name requires a name");
    bus.releaseName(name);
    return 0;
}

fn luaDbusExport(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const bus: *DbusBus = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    if (bus.closed) return c.luaL_error(lua_state, "dbus bus is closed");
    const path_index: c_int = if (c.lua_type(lua_state, 2) == c.LUA_TSTRING) 2 else 1;
    const spec_index = path_index + 1;
    const object = bus.exportObject(lua_state, path_index, spec_index) catch |err| {
        std.log.scoped(.keywork_luajit).warn("dbus export failed: {}", .{err});
        return c.luaL_error(lua_state, "dbus export failed");
    };
    pushDbusExportHandle(lua_state, object);
    return 1;
}

fn luaDbusEmit(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const bus: *DbusBus = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    if (bus.closed) return c.luaL_error(lua_state, "dbus bus is closed");
    const options_index: c_int = if (c.lua_type(lua_state, 2) == c.LUA_TTABLE) 2 else 1;
    bus.emitSignal(lua_state, options_index) catch |err| {
        std.log.scoped(.keywork_luajit).warn("dbus emit failed: {}", .{err});
        return c.luaL_error(lua_state, "dbus emit failed");
    };
    return 0;
}

fn luaDbusClose(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const bus: *DbusBus = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    bus.close();
    return 0;
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

fn pushFsEventHandle(lua_state: *c.lua_State, fs_event: *FsEvent) void {
    c.lua_createtable(lua_state, 0, 1);
    c.lua_pushlightuserdata(lua_state, fs_event);
    c.lua_pushcclosure(lua_state, luaCancelFsEvent, 1);
    c.lua_setfield(lua_state, -2, "cancel");
}

fn pushDbusBusHandle(lua_state: *c.lua_State, bus: *DbusBus) void {
    c.lua_createtable(lua_state, 0, 7);
    c.lua_pushlightuserdata(lua_state, bus);
    c.lua_pushcclosure(lua_state, luaDbusSubscribe, 1);
    c.lua_setfield(lua_state, -2, "subscribe");
    c.lua_pushlightuserdata(lua_state, bus);
    c.lua_pushcclosure(lua_state, luaDbusCall, 1);
    c.lua_setfield(lua_state, -2, "call");
    c.lua_pushlightuserdata(lua_state, bus);
    c.lua_pushcclosure(lua_state, luaDbusRequestName, 1);
    c.lua_setfield(lua_state, -2, "request_name");
    c.lua_pushlightuserdata(lua_state, bus);
    c.lua_pushcclosure(lua_state, luaDbusReleaseName, 1);
    c.lua_setfield(lua_state, -2, "release_name");
    c.lua_pushlightuserdata(lua_state, bus);
    c.lua_pushcclosure(lua_state, luaDbusExport, 1);
    c.lua_setfield(lua_state, -2, "export");
    c.lua_pushlightuserdata(lua_state, bus);
    c.lua_pushcclosure(lua_state, luaDbusEmit, 1);
    c.lua_setfield(lua_state, -2, "emit");
    c.lua_pushlightuserdata(lua_state, bus);
    c.lua_pushcclosure(lua_state, luaDbusClose, 1);
    c.lua_setfield(lua_state, -2, "close");
}

fn pushDbusSubscriptionHandle(lua_state: *c.lua_State, subscription: *DbusSubscription) void {
    c.lua_createtable(lua_state, 0, 1);
    c.lua_pushlightuserdata(lua_state, subscription);
    c.lua_pushcclosure(lua_state, luaCancelDbusSubscription, 1);
    c.lua_setfield(lua_state, -2, "cancel");
}

fn pushDbusOwnedNameHandle(lua_state: *c.lua_State, owned: *DbusOwnedName) void {
    c.lua_createtable(lua_state, 0, 1);
    c.lua_pushlightuserdata(lua_state, owned);
    c.lua_pushcclosure(lua_state, luaReleaseDbusOwnedName, 1);
    c.lua_setfield(lua_state, -2, "release");
}

fn pushDbusExportHandle(lua_state: *c.lua_State, object: *DbusExportedObject) void {
    c.lua_createtable(lua_state, 0, 1);
    c.lua_pushlightuserdata(lua_state, object);
    c.lua_pushcclosure(lua_state, luaUnexportDbusObject, 1);
    c.lua_setfield(lua_state, -2, "unexport");
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

fn luaCancelFsEvent(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const fs_event: *FsEvent = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    fs_event.cancel(lua_state);
    return 0;
}

fn luaCancelDbusSubscription(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const subscription: *DbusSubscription = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    subscription.cancel(lua_state);
    return 0;
}

fn luaReleaseDbusOwnedName(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const owned: *DbusOwnedName = @ptrCast(@alignCast(c.lua_touserdata(lua_state_optional.?, c.lua_upvalueindex(1)).?));
    owned.release();
    return 0;
}

fn luaUnexportDbusObject(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const object: *DbusExportedObject = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    object.unexport(lua_state);
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
    c.lua_createtable(lua_state, 0, 3);
    const table = c.lua_gettop(lua_state);
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
        c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, spec_ref);
        const spec_token = c.lua_topointer(lua_state, -1);
        pop(lua_state, 1);
        stateful.* = .{
            .allocator = allocator,
            .app = app,
            .lua_state = lua_state,
            .spec_ref = spec_ref,
            .props_ref = props_ref,
            .spec_token = spec_token,
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
        const options = try lua_codec.decode(GestureOptions, lua_state, table, allocator);
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
            .hover_style = options.hoverStyle(),
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
        const value = dupeStringField(lua_state, allocator, table, "value") catch try allocator.dupe(u8, "");
        const on_change = try getOptionalTextChangeCallbackField(lua_state, callback_allocator, table, "on_change");
        var widget = keywork.widgets.textInput(id, value, placeholder);
        widget.text_input.on_change = on_change;
        return widget;
    }
    if (std.mem.eql(u8, kind, "scroll")) {
        const id = try dupeStringField(lua_state, allocator, table, "id");
        const child = try allocator.create(keywork.Widget);
        errdefer allocator.destroy(child);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parseWidget(lua_state, allocator, callback_allocator, runtime_state, parse_context, -1);
        var axes: keywork.Widget.ScrollAxes = .vertical;
        if (stringField(lua_state, table, "axes")) |value| {
            if (std.mem.eql(u8, value, "horizontal")) axes = .horizontal;
            if (std.mem.eql(u8, value, "both")) axes = .both;
        } else |_| {}
        return .{ .scroll = .{ .id = id, .child = child, .axes = axes } };
    }
    if (std.mem.eql(u8, kind, "list")) {
        const ListOptions = struct {
            count: usize = 0,
            item_height: f32 = 16,
        };
        const id = try dupeStringField(lua_state, allocator, table, "id");
        const options = try lua_codec.decode(ListOptions, lua_state, table, allocator);
        c.lua_getfield(lua_state, table, "build_item");
        defer pop(lua_state, 1);
        if (c.lua_type(lua_state, -1) != c.LUA_TFUNCTION) return error.ExpectedLuaFunction;
        c.lua_pushvalue(lua_state, -1);
        const ref = c.luaL_ref(lua_state, c.LUA_REGISTRYINDEX);
        errdefer c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, ref);
        const builder = try callback_allocator.create(LuaItemBuilder);
        builder.* = .{ .allocator = callback_allocator, .lua_state = lua_state, .ref = ref };
        return keywork.widgets.list(id, options.count, options.item_height, builder.itemBuilder());
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
    if (std.mem.eql(u8, kind, "image")) {
        return try parseImage(lua_state, allocator, table);
    }
    if (std.mem.eql(u8, kind, "icon")) {
        const options = try lua_codec.decode(IconOptions, lua_state, table, allocator);
        const icon = parse_context.resolveIcon(options);
        const name = try stringField(lua_state, table, "name");
        const path = try keywork.icon_theme.lookupSvgIconSized(allocator, name, icon.size) orelse return missingIconWidget(allocator, name, icon.color orelse keywork.colors.ink);
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
        return .{ .row = .{ .children = children, .gap = options.spacing, .cross_align = options.crossAlign(), .main_align = options.mainAlign() } };
    }
    if (std.mem.eql(u8, kind, "column")) {
        const options = try lua_codec.decode(LinearOptions, lua_state, table, allocator);
        const children = try parseChildren(lua_state, allocator, callback_allocator, runtime_state, parse_context, table);
        return .{ .column = .{ .children = children, .gap = options.spacing, .cross_align = options.crossAlign(), .main_align = options.mainAlign() } };
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
    if (std.mem.eql(u8, kind, "flexible")) {
        const options = try lua_codec.decode(FlexibleOptions, lua_state, table, allocator);
        const child = try allocator.create(keywork.Widget);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parseWidget(lua_state, allocator, callback_allocator, runtime_state, parse_context, -1);
        return .{ .flexible = .{ .child = child, .flex = options.flex, .fit = options.fit orelse .tight } };
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

fn parseImage(lua_state: *c.lua_State, allocator: std.mem.Allocator, table: c_int) !keywork.Widget {
    const options = try lua_codec.decode(ImageOptions, lua_state, table, allocator);
    if (options.width == 0 or options.height == 0) return error.InvalidImageSize;
    if (!std.mem.eql(u8, options.format, "argb32")) return error.UnsupportedImageFormat;

    c.lua_getfield(lua_state, table, "pixels");
    defer pop(lua_state, 1);
    const pixels = try parseArgb32Pixels(lua_state, allocator, -1, options.width, options.height);
    errdefer allocator.free(pixels);

    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&options.width));
    hasher.update(std.mem.asBytes(&options.height));
    hasher.update(std.mem.sliceAsBytes(pixels));

    const image = try allocator.create(LuaImage);
    errdefer allocator.destroy(image);
    image.* = .{
        .width = options.width,
        .height = options.height,
        .size = options.size orelse @floatFromInt(@max(options.width, options.height)),
        .pixels = pixels,
        .cache_key = hasher.final(),
    };
    return image.widget();
}

fn parseArgb32Pixels(lua_state: *c.lua_State, allocator: std.mem.Allocator, index: c_int, width: u32, height: u32) ![]keywork.Color {
    const pixel_count = @as(usize, width) * @as(usize, height);
    const byte_count = pixel_count * 4;
    const pixels = try allocator.alloc(keywork.Color, pixel_count);
    errdefer allocator.free(pixels);

    if (c.lua_type(lua_state, index) == c.LUA_TSTRING) {
        const bytes = try stringFromStack(lua_state, index);
        if (bytes.len < byte_count) return error.InvalidImagePixels;
        fillArgb32Pixels(pixels, bytes[0..byte_count]);
        return pixels;
    }

    try expectType(lua_state, index, c.LUA_TTABLE);
    const table = absoluteIndex(lua_state, index);
    var pixel_index: usize = 0;
    while (pixel_index < pixel_count) : (pixel_index += 1) {
        const base: c_int = @intCast(pixel_index * 4);
        const a = try imageByteField(lua_state, table, base + 1);
        const r = try imageByteField(lua_state, table, base + 2);
        const g = try imageByteField(lua_state, table, base + 3);
        const b = try imageByteField(lua_state, table, base + 4);
        pixels[pixel_index] = keywork.Color.argb(a, r, g, b);
    }
    return pixels;
}

fn fillArgb32Pixels(pixels: []keywork.Color, bytes: []const u8) void {
    for (pixels, 0..) |*pixel, index| {
        const base = index * 4;
        pixel.* = keywork.Color.argb(bytes[base], bytes[base + 1], bytes[base + 2], bytes[base + 3]);
    }
}

fn imageByteField(lua_state: *c.lua_State, table: c_int, index: c_int) !u8 {
    c.lua_rawgeti(lua_state, table, index);
    defer pop(lua_state, 1);
    if (c.lua_isnumber(lua_state, -1) == 0) return error.InvalidImagePixels;
    const value = c.lua_tointeger(lua_state, -1);
    if (value < 0 or value > 255) return error.InvalidImagePixels;
    return @intCast(value);
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

fn optionalStringFieldDupe(lua_state: *c.lua_State, allocator: std.mem.Allocator, table: c_int, key: [*:0]const u8) !?[]const u8 {
    c.lua_getfield(lua_state, table, key);
    defer pop(lua_state, 1);
    if (c.lua_isnil(lua_state, -1)) return null;
    const value = try stringFromStack(lua_state, -1);
    return try allocator.dupe(u8, value);
}

fn getIntegerField(lua_state: *c.lua_State, table: c_int, key: [*:0]const u8, default: c_int) c_int {
    c.lua_getfield(lua_state, table, key);
    defer pop(lua_state, 1);
    if (c.lua_isnumber(lua_state, -1) == 0) return default;
    return @intCast(c.lua_tointeger(lua_state, -1));
}

fn appendDbusLuaArgs(lua_state: *c.lua_State, options_index: c_int, iter: *dbus_c.DBusMessageIter) !void {
    c.lua_getfield(lua_state, options_index, "args");
    defer pop(lua_state, 1);
    if (c.lua_isnil(lua_state, -1)) return;
    try expectType(lua_state, -1, c.LUA_TTABLE);

    const args_index = absoluteIndex(lua_state, -1);
    var index: c_int = 1;
    while (true) : (index += 1) {
        c.lua_rawgeti(lua_state, args_index, index);
        if (c.lua_isnil(lua_state, -1)) {
            pop(lua_state, 1);
            return;
        }
        const arg_type = c.lua_type(lua_state, -1);
        if (arg_type == c.LUA_TNIL) {
            pop(lua_state, 1);
            return;
        }
        try appendLuaValueToDbusIter(lua_state, -1, iter);
        pop(lua_state, 1);
    }
}

fn appendLuaValueToDbusIter(lua_state: *c.lua_State, index: c_int, iter: *dbus_c.DBusMessageIter) anyerror!void {
    const absolute = absoluteIndex(lua_state, index);
    if (c.lua_type(lua_state, absolute) == c.LUA_TTABLE) {
        c.lua_getfield(lua_state, absolute, "__dbus_type");
        defer pop(lua_state, 1);
        if (!c.lua_isnil(lua_state, -1)) {
            const type_name = try stringFromStack(lua_state, -1);
            if (std.mem.eql(u8, type_name, "string")) return appendTypedField(lua_state, absolute, "s", iter);
            if (std.mem.eql(u8, type_name, "object_path")) return appendTypedField(lua_state, absolute, "o", iter);
            if (std.mem.eql(u8, type_name, "boolean")) return appendTypedField(lua_state, absolute, "b", iter);
            if (std.mem.eql(u8, type_name, "int32")) return appendTypedField(lua_state, absolute, "i", iter);
            if (std.mem.eql(u8, type_name, "uint32")) return appendTypedField(lua_state, absolute, "u", iter);
            if (std.mem.eql(u8, type_name, "double")) return appendTypedField(lua_state, absolute, "d", iter);
            if (std.mem.eql(u8, type_name, "array")) return appendTypedArray(lua_state, absolute, iter);
            if (std.mem.eql(u8, type_name, "variant")) return appendTypedVariant(lua_state, absolute, iter);
            return error.UnsupportedDbusArgument;
        }
    }
    switch (c.lua_type(lua_state, absolute)) {
        c.LUA_TSTRING => try appendLuaValueWithSignature(lua_state, absolute, "s", iter),
        c.LUA_TBOOLEAN => try appendLuaValueWithSignature(lua_state, absolute, "b", iter),
        c.LUA_TNUMBER => try appendLuaValueWithSignature(lua_state, absolute, "d", iter),
        else => return error.UnsupportedDbusArgument,
    }
}

fn appendTypedField(lua_state: *c.lua_State, table: c_int, signature: []const u8, iter: *dbus_c.DBusMessageIter) !void {
    c.lua_getfield(lua_state, table, "value");
    defer pop(lua_state, 1);
    try appendLuaValueWithSignature(lua_state, -1, signature, iter);
}

fn appendTypedArray(lua_state: *c.lua_State, table: c_int, iter: *dbus_c.DBusMessageIter) !void {
    c.lua_getfield(lua_state, table, "signature");
    const signature = try stringFromStack(lua_state, -1);
    defer pop(lua_state, 1);
    c.lua_getfield(lua_state, table, "value");
    defer pop(lua_state, 1);
    try appendArrayWithSignature(lua_state, -1, signature, iter);
}

fn appendTypedVariant(lua_state: *c.lua_State, table: c_int, iter: *dbus_c.DBusMessageIter) !void {
    c.lua_getfield(lua_state, table, "signature");
    const signature = try stringFromStack(lua_state, -1);
    defer pop(lua_state, 1);
    c.lua_getfield(lua_state, table, "value");
    defer pop(lua_state, 1);
    var variant: dbus_c.DBusMessageIter = undefined;
    if (dbus_c.dbus_message_iter_open_container(iter, dbus_c.DBUS_TYPE_VARIANT, tryZTemp(signature).ptr, &variant) == 0) return error.OutOfMemory;
    try appendLuaValueWithSignature(lua_state, -1, signature, &variant);
    if (dbus_c.dbus_message_iter_close_container(iter, &variant) == 0) return error.OutOfMemory;
}

fn appendLuaValueWithSignature(lua_state: *c.lua_State, index: c_int, signature: []const u8, iter: *dbus_c.DBusMessageIter) anyerror!void {
    if (signature.len == 0) return;
    const absolute = absoluteIndex(lua_state, index);
    if (c.lua_type(lua_state, absolute) == c.LUA_TTABLE) {
        c.lua_getfield(lua_state, absolute, "__dbus_type");
        if (!c.lua_isnil(lua_state, -1)) {
            const type_name = try stringFromStack(lua_state, -1);
            pop(lua_state, 1);
            if (std.mem.eql(u8, type_name, "array") or std.mem.eql(u8, type_name, "variant")) return appendLuaValueToDbusIter(lua_state, absolute, iter);
            c.lua_getfield(lua_state, absolute, "value");
            defer pop(lua_state, 1);
            return appendLuaValueWithSignature(lua_state, -1, signature, iter);
        }
        pop(lua_state, 1);
    }
    if (signature[0] == 'a') return appendArrayWithSignature(lua_state, index, signature[1..], iter);
    switch (signature[0]) {
        's' => {
            var value = tryZTemp(try stringFromStack(lua_state, index));
            try appendDbusBasic(iter, dbus_c.DBUS_TYPE_STRING, &value.ptr);
        },
        'o' => {
            var value = tryZTemp(try stringFromStack(lua_state, index));
            try appendDbusBasic(iter, dbus_c.DBUS_TYPE_OBJECT_PATH, &value.ptr);
        },
        'b' => {
            var value: dbus_c.dbus_bool_t = if (c.lua_toboolean(lua_state, index) != 0) 1 else 0;
            try appendDbusBasic(iter, dbus_c.DBUS_TYPE_BOOLEAN, &value);
        },
        'i' => {
            var value: i32 = @intCast(c.lua_tointeger(lua_state, index));
            try appendDbusBasic(iter, dbus_c.DBUS_TYPE_INT32, &value);
        },
        'u' => {
            var value: u32 = @intCast(c.lua_tointeger(lua_state, index));
            try appendDbusBasic(iter, dbus_c.DBUS_TYPE_UINT32, &value);
        },
        'd' => {
            var value: f64 = c.lua_tonumber(lua_state, index);
            try appendDbusBasic(iter, dbus_c.DBUS_TYPE_DOUBLE, &value);
        },
        'v' => try appendLuaValueToDbusIter(lua_state, index, iter),
        else => return error.UnsupportedDbusArgument,
    }
}

fn appendArrayWithSignature(lua_state: *c.lua_State, index: c_int, element_signature: []const u8, iter: *dbus_c.DBusMessageIter) !void {
    try expectType(lua_state, index, c.LUA_TTABLE);
    var array: dbus_c.DBusMessageIter = undefined;
    if (dbus_c.dbus_message_iter_open_container(iter, dbus_c.DBUS_TYPE_ARRAY, tryZTemp(element_signature).ptr, &array) == 0) return error.OutOfMemory;
    const table = absoluteIndex(lua_state, index);
    var item_index: c_int = 1;
    while (true) : (item_index += 1) {
        c.lua_rawgeti(lua_state, table, item_index);
        if (c.lua_isnil(lua_state, -1)) {
            pop(lua_state, 1);
            break;
        }
        try appendLuaValueWithSignature(lua_state, -1, element_signature, &array);
        pop(lua_state, 1);
    }
    if (dbus_c.dbus_message_iter_close_container(iter, &array) == 0) return error.OutOfMemory;
}

fn appendPropertyDictEntry(lua_state: *c.lua_State, array: *dbus_c.DBusMessageIter, name: []const u8, signature: []const u8, value_index: c_int) !void {
    var entry: dbus_c.DBusMessageIter = undefined;
    if (dbus_c.dbus_message_iter_open_container(array, dbus_c.DBUS_TYPE_DICT_ENTRY, null, &entry) == 0) return error.OutOfMemory;
    var name_z = tryZTemp(name);
    try appendDbusBasic(&entry, dbus_c.DBUS_TYPE_STRING, &name_z.ptr);
    var variant: dbus_c.DBusMessageIter = undefined;
    if (dbus_c.dbus_message_iter_open_container(&entry, dbus_c.DBUS_TYPE_VARIANT, tryZTemp(signature).ptr, &variant) == 0) return error.OutOfMemory;
    try appendLuaValueWithSignature(lua_state, value_index, signature, &variant);
    if (dbus_c.dbus_message_iter_close_container(&entry, &variant) == 0) return error.OutOfMemory;
    if (dbus_c.dbus_message_iter_close_container(array, &entry) == 0) return error.OutOfMemory;
}

fn appendDbusBasic(iter: *dbus_c.DBusMessageIter, type_: c_int, value: anytype) !void {
    const opaque_value: *const anyopaque = @ptrCast(value);
    if (dbus_c.dbus_message_iter_append_basic(iter, type_, opaque_value) == 0) return error.OutOfMemory;
}

fn dupeStringFromStack(lua_state: *c.lua_State, allocator: std.mem.Allocator, index: c_int) ![]const u8 {
    const value = try stringFromStack(lua_state, index);
    return try allocator.dupe(u8, value);
}

fn buildDbusMatchRule(allocator: std.mem.Allocator, subscription: *const DbusSubscription) ![:0]const u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try writer.writer.writeAll("type='signal'");
    try appendDbusMatchField(&writer.writer, "sender", subscription.sender);
    try appendDbusMatchField(&writer.writer, "path", subscription.path);
    try appendDbusMatchField(&writer.writer, "path_namespace", subscription.path_namespace);
    try appendDbusMatchField(&writer.writer, "interface", subscription.interface);
    try appendDbusMatchField(&writer.writer, "member", subscription.member);
    return try writer.toOwnedSliceSentinel(0);
}

fn appendDbusMatchField(writer: *std.Io.Writer, name: []const u8, value: ?[]const u8) !void {
    const field = value orelse return;
    if (std.mem.indexOfAny(u8, field, "',") != null) return error.InvalidDbusMatchField;
    try writer.print(",{s}='{s}'", .{ name, field });
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
    if (c.lua_type(lua_state, absolute) == c.LUA_TTABLE) {
        return try stringField(lua_state, absolute, "path");
    }
    return try stringFromStack(lua_state, absolute);
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
    // Sentinel-terminated so free() sees the full allocSentinel length.
    values: [:null]?[*:0]const u8,
    strings: [][:0]u8,

    fn ptr(self: *const PreparedArgv) [*:null]const ?[*:0]const u8 {
        return self.values.ptr;
    }

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
    return .{ .values = values, .strings = strings };
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

fn pushDbusSignal(lua_state: *c.lua_State, message: *dbus_c.DBusMessage) void {
    c.lua_createtable(lua_state, 0, 6);
    const table = c.lua_gettop(lua_state);
    pushOptionalDbusString(lua_state, dbus_c.dbus_message_get_sender(message));
    c.lua_setfield(lua_state, table, "sender");
    pushOptionalDbusString(lua_state, dbus_c.dbus_message_get_path(message));
    c.lua_setfield(lua_state, table, "path");
    pushOptionalDbusString(lua_state, dbus_c.dbus_message_get_interface(message));
    c.lua_setfield(lua_state, table, "interface");
    pushOptionalDbusString(lua_state, dbus_c.dbus_message_get_member(message));
    c.lua_setfield(lua_state, table, "member");

    const signature = dbus_c.dbus_message_get_signature(message);
    if (signature) |sig| {
        c.lua_pushstring(lua_state, sig);
    } else {
        c.lua_pushnil(lua_state);
    }
    c.lua_setfield(lua_state, table, "signature");

    pushDbusArgsTable(lua_state, message);
    c.lua_setfield(lua_state, table, "args");
}

fn pushDbusReply(lua_state: *c.lua_State, message: *dbus_c.DBusMessage) void {
    c.lua_createtable(lua_state, 0, 2);
    const table = c.lua_gettop(lua_state);
    const signature = dbus_c.dbus_message_get_signature(message);
    if (signature) |sig| {
        c.lua_pushstring(lua_state, sig);
    } else {
        c.lua_pushnil(lua_state);
    }
    c.lua_setfield(lua_state, table, "signature");

    pushDbusArgsTable(lua_state, message);
    c.lua_setfield(lua_state, table, "args");
}

fn pushDbusCallTable(lua_state: *c.lua_State, message: *dbus_c.DBusMessage) void {
    c.lua_createtable(lua_state, 0, 6);
    const table = c.lua_gettop(lua_state);
    pushOptionalDbusString(lua_state, dbus_c.dbus_message_get_sender(message));
    c.lua_setfield(lua_state, table, "sender");
    pushOptionalDbusString(lua_state, dbus_c.dbus_message_get_path(message));
    c.lua_setfield(lua_state, table, "path");
    pushOptionalDbusString(lua_state, dbus_c.dbus_message_get_interface(message));
    c.lua_setfield(lua_state, table, "interface");
    pushOptionalDbusString(lua_state, dbus_c.dbus_message_get_member(message));
    c.lua_setfield(lua_state, table, "member");
    const serial = dbus_c.dbus_message_get_serial(message);
    c.lua_pushnumber(lua_state, @floatFromInt(serial));
    c.lua_setfield(lua_state, table, "serial");
}

fn pushDbusMessageArgs(lua_state: *c.lua_State, message: *dbus_c.DBusMessage) usize {
    var count: usize = 0;
    var iter: dbus_c.DBusMessageIter = undefined;
    if (dbus_c.dbus_message_iter_init(message, &iter) != 0) {
        while (dbus_c.dbus_message_iter_get_arg_type(&iter) != dbus_c.DBUS_TYPE_INVALID) {
            pushDbusIterValue(lua_state, &iter);
            count += 1;
            if (dbus_c.dbus_message_iter_next(&iter) == 0) break;
        }
    }
    return count;
}

fn methodCallStringPair(message: *dbus_c.DBusMessage) ?struct { interface: []const u8, property: []const u8 } {
    const interface = methodCallString(message, 0) orelse return null;
    const property = methodCallString(message, 1) orelse return null;
    return .{ .interface = interface, .property = property };
}

fn methodCallString(message: *dbus_c.DBusMessage, wanted_index: usize) ?[]const u8 {
    var iter: dbus_c.DBusMessageIter = undefined;
    if (dbus_c.dbus_message_iter_init(message, &iter) == 0) return null;
    var index: usize = 0;
    while (dbus_c.dbus_message_iter_get_arg_type(&iter) != dbus_c.DBUS_TYPE_INVALID) : (index += 1) {
        if (index == wanted_index) {
            if (dbus_c.dbus_message_iter_get_arg_type(&iter) != dbus_c.DBUS_TYPE_STRING) return null;
            var value: [*:0]const u8 = undefined;
            dbus_c.dbus_message_iter_get_basic(&iter, @ptrCast(&value));
            return std.mem.span(value);
        }
        if (dbus_c.dbus_message_iter_next(&iter) == 0) break;
    }
    return null;
}

fn propertySignature(lua_state: *c.lua_State, object: *DbusExportedObject, interface: []const u8, property: []const u8) ![]const u8 {
    const original_top = c.lua_gettop(lua_state);
    defer c.lua_settop(lua_state, original_top);
    c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, object.ref);
    c.lua_getfield(lua_state, -1, tryZTemp(interface).ptr);
    c.lua_getfield(lua_state, -1, "properties");
    c.lua_getfield(lua_state, -1, tryZTemp(property).ptr);
    c.lua_getfield(lua_state, -1, "signature");
    const signature = try stringFromStack(lua_state, -1);
    return tryZTemp(signature);
}

fn pushPropertyGetterResult(lua_state: *c.lua_State, object: *DbusExportedObject, interface: []const u8, property: []const u8) !void {
    c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, object.ref);
    c.lua_getfield(lua_state, -1, tryZTemp(interface).ptr);
    if (c.lua_isnil(lua_state, -1)) return error.DBusUnknownInterface;
    c.lua_getfield(lua_state, -1, "properties");
    if (c.lua_isnil(lua_state, -1)) return error.DBusUnknownProperty;
    c.lua_getfield(lua_state, -1, tryZTemp(property).ptr);
    if (c.lua_isnil(lua_state, -1)) return error.DBusUnknownProperty;
    c.lua_getfield(lua_state, -1, "get");
    if (c.lua_type(lua_state, -1) != c.LUA_TFUNCTION) return error.DBusUnreadableProperty;
    if (c.lua_pcall(lua_state, 0, 1, 0) != 0) return error.LuaCallbackFailed;
}

fn buildDbusIntrospectionXml(allocator: std.mem.Allocator, lua_state: *c.lua_State, object: *DbusExportedObject) ![]u8 {
    const original_top = c.lua_gettop(lua_state);
    defer c.lua_settop(lua_state, original_top);

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    try writer.writer.writeAll(
        \\<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
        \\<node>
        \\  <interface name="org.freedesktop.DBus.Introspectable">
        \\    <method name="Introspect">
        \\      <arg name="xml_data" type="s" direction="out"/>
        \\    </method>
        \\  </interface>
        \\  <interface name="org.freedesktop.DBus.Properties">
        \\    <method name="Get">
        \\      <arg name="interface_name" type="s" direction="in"/>
        \\      <arg name="property_name" type="s" direction="in"/>
        \\      <arg name="value" type="v" direction="out"/>
        \\    </method>
        \\    <method name="GetAll">
        \\      <arg name="interface_name" type="s" direction="in"/>
        \\      <arg name="properties" type="a{sv}" direction="out"/>
        \\    </method>
        \\  </interface>
        \\
    );

    c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, object.ref);
    const spec_index = absoluteIndex(lua_state, -1);
    c.lua_pushnil(lua_state);
    while (c.lua_next(lua_state, spec_index) != 0) {
        if (c.lua_type(lua_state, -2) != c.LUA_TSTRING or c.lua_type(lua_state, -1) != c.LUA_TTABLE) {
            pop(lua_state, 1);
            continue;
        }
        const interface_name = try stringFromStack(lua_state, -2);
        const interface_index = absoluteIndex(lua_state, -1);
        try writer.writer.print("  <interface name=\"{s}\">\n", .{interface_name});
        try writeDbusIntrospectionMethods(&writer.writer, lua_state, interface_index);
        try writeDbusIntrospectionSignals(&writer.writer, lua_state, interface_index);
        try writeDbusIntrospectionProperties(&writer.writer, lua_state, interface_index);
        try writer.writer.writeAll("  </interface>\n");
        pop(lua_state, 1);
    }

    try writer.writer.writeAll("</node>\n");
    return writer.toOwnedSlice();
}

fn writeDbusIntrospectionMethods(writer: *std.Io.Writer, lua_state: *c.lua_State, interface_index: c_int) !void {
    c.lua_getfield(lua_state, interface_index, "methods");
    defer pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return;
    const methods_index = absoluteIndex(lua_state, -1);
    c.lua_pushnil(lua_state);
    while (c.lua_next(lua_state, methods_index) != 0) {
        if (c.lua_type(lua_state, -2) != c.LUA_TSTRING or c.lua_type(lua_state, -1) != c.LUA_TTABLE) {
            pop(lua_state, 1);
            continue;
        }
        const method_name = try stringFromStack(lua_state, -2);
        const method_index = absoluteIndex(lua_state, -1);
        try writer.print("    <method name=\"{s}\">\n", .{method_name});
        try writeDbusIntrospectionArgs(writer, lua_state, method_index, "in_signature", "in");
        try writeDbusIntrospectionArgs(writer, lua_state, method_index, "out_signature", "out");
        try writer.writeAll("    </method>\n");
        pop(lua_state, 1);
    }
}

fn writeDbusIntrospectionSignals(writer: *std.Io.Writer, lua_state: *c.lua_State, interface_index: c_int) !void {
    c.lua_getfield(lua_state, interface_index, "signals");
    defer pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return;
    const signals_index = absoluteIndex(lua_state, -1);
    c.lua_pushnil(lua_state);
    while (c.lua_next(lua_state, signals_index) != 0) {
        if (c.lua_type(lua_state, -2) != c.LUA_TSTRING or c.lua_type(lua_state, -1) != c.LUA_TTABLE) {
            pop(lua_state, 1);
            continue;
        }
        const signal_name = try stringFromStack(lua_state, -2);
        const signal_index = absoluteIndex(lua_state, -1);
        try writer.print("    <signal name=\"{s}\">\n", .{signal_name});
        try writeDbusIntrospectionArgs(writer, lua_state, signal_index, "signature", null);
        try writer.writeAll("    </signal>\n");
        pop(lua_state, 1);
    }
}

fn writeDbusIntrospectionProperties(writer: *std.Io.Writer, lua_state: *c.lua_State, interface_index: c_int) !void {
    c.lua_getfield(lua_state, interface_index, "properties");
    defer pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return;
    const properties_index = absoluteIndex(lua_state, -1);
    c.lua_pushnil(lua_state);
    while (c.lua_next(lua_state, properties_index) != 0) {
        if (c.lua_type(lua_state, -2) != c.LUA_TSTRING or c.lua_type(lua_state, -1) != c.LUA_TTABLE) {
            pop(lua_state, 1);
            continue;
        }
        const property_name = try stringFromStack(lua_state, -2);
        const property_index = absoluteIndex(lua_state, -1);
        c.lua_getfield(lua_state, property_index, "signature");
        const signature = tryZTemp(stringFromStack(lua_state, -1) catch "v");
        pop(lua_state, 1);
        c.lua_getfield(lua_state, property_index, "access");
        const access = tryZTemp(stringFromStack(lua_state, -1) catch "read");
        pop(lua_state, 1);
        try writer.print("    <property name=\"{s}\" type=\"{s}\" access=\"{s}\"/>\n", .{ property_name, signature, access });
        pop(lua_state, 1);
    }
}

fn writeDbusIntrospectionArgs(writer: *std.Io.Writer, lua_state: *c.lua_State, table_index: c_int, key: [:0]const u8, direction: ?[]const u8) !void {
    c.lua_getfield(lua_state, table_index, key.ptr);
    defer pop(lua_state, 1);
    if (c.lua_isnil(lua_state, -1)) return;
    const signature = try stringFromStack(lua_state, -1);
    if (signature.len == 0) return;
    if (direction) |dir| {
        try writer.print("      <arg type=\"{s}\" direction=\"{s}\"/>\n", .{ signature, dir });
    } else {
        try writer.print("      <arg type=\"{s}\"/>\n", .{signature});
    }
}

fn pushDbusArgsTable(lua_state: *c.lua_State, message: *dbus_c.DBusMessage) void {
    c.lua_createtable(lua_state, 0, 0);
    const args_table = c.lua_gettop(lua_state);
    var iter: dbus_c.DBusMessageIter = undefined;
    if (dbus_c.dbus_message_iter_init(message, &iter) != 0) {
        var arg_index: c_int = 1;
        while (dbus_c.dbus_message_iter_get_arg_type(&iter) != dbus_c.DBUS_TYPE_INVALID) : (arg_index += 1) {
            pushDbusIterValue(lua_state, &iter);
            c.lua_rawseti(lua_state, args_table, arg_index);
            if (dbus_c.dbus_message_iter_next(&iter) == 0) break;
        }
    }
}

fn pushOptionalDbusString(lua_state: *c.lua_State, value: ?[*:0]const u8) void {
    if (value) |ptr| {
        c.lua_pushstring(lua_state, ptr);
    } else {
        c.lua_pushnil(lua_state);
    }
}

fn pushDbusIterValue(lua_state: *c.lua_State, iter: *dbus_c.DBusMessageIter) void {
    switch (dbus_c.dbus_message_iter_get_arg_type(iter)) {
        dbus_c.DBUS_TYPE_STRING, dbus_c.DBUS_TYPE_OBJECT_PATH, dbus_c.DBUS_TYPE_SIGNATURE => {
            var value: [*:0]const u8 = undefined;
            dbus_c.dbus_message_iter_get_basic(iter, @ptrCast(&value));
            c.lua_pushstring(lua_state, value);
        },
        dbus_c.DBUS_TYPE_BOOLEAN => {
            var value: dbus_c.dbus_bool_t = 0;
            dbus_c.dbus_message_iter_get_basic(iter, &value);
            c.lua_pushboolean(lua_state, if (value != 0) 1 else 0);
        },
        dbus_c.DBUS_TYPE_BYTE => {
            var value: u8 = 0;
            dbus_c.dbus_message_iter_get_basic(iter, &value);
            c.lua_pushnumber(lua_state, @floatFromInt(value));
        },
        dbus_c.DBUS_TYPE_INT16 => {
            var value: i16 = 0;
            dbus_c.dbus_message_iter_get_basic(iter, &value);
            c.lua_pushnumber(lua_state, @floatFromInt(value));
        },
        dbus_c.DBUS_TYPE_UINT16 => {
            var value: u16 = 0;
            dbus_c.dbus_message_iter_get_basic(iter, &value);
            c.lua_pushnumber(lua_state, @floatFromInt(value));
        },
        dbus_c.DBUS_TYPE_INT32 => {
            var value: i32 = 0;
            dbus_c.dbus_message_iter_get_basic(iter, &value);
            c.lua_pushnumber(lua_state, @floatFromInt(value));
        },
        dbus_c.DBUS_TYPE_UINT32 => {
            var value: u32 = 0;
            dbus_c.dbus_message_iter_get_basic(iter, &value);
            c.lua_pushnumber(lua_state, @floatFromInt(value));
        },
        dbus_c.DBUS_TYPE_INT64 => {
            var value: i64 = 0;
            dbus_c.dbus_message_iter_get_basic(iter, &value);
            c.lua_pushnumber(lua_state, @floatFromInt(value));
        },
        dbus_c.DBUS_TYPE_UINT64 => {
            var value: u64 = 0;
            dbus_c.dbus_message_iter_get_basic(iter, &value);
            c.lua_pushnumber(lua_state, @floatFromInt(value));
        },
        dbus_c.DBUS_TYPE_DOUBLE => {
            var value: f64 = 0;
            dbus_c.dbus_message_iter_get_basic(iter, &value);
            c.lua_pushnumber(lua_state, value);
        },
        dbus_c.DBUS_TYPE_VARIANT => {
            var child: dbus_c.DBusMessageIter = undefined;
            dbus_c.dbus_message_iter_recurse(iter, &child);
            pushDbusIterValue(lua_state, &child);
        },
        dbus_c.DBUS_TYPE_ARRAY, dbus_c.DBUS_TYPE_STRUCT, dbus_c.DBUS_TYPE_DICT_ENTRY => pushDbusIterSequence(lua_state, iter),
        else => c.lua_pushnil(lua_state),
    }
}

fn pushDbusIterSequence(lua_state: *c.lua_State, iter: *dbus_c.DBusMessageIter) void {
    c.lua_createtable(lua_state, 0, 0);
    const table = c.lua_gettop(lua_state);
    var child: dbus_c.DBusMessageIter = undefined;
    dbus_c.dbus_message_iter_recurse(iter, &child);
    var index: c_int = 1;
    while (dbus_c.dbus_message_iter_get_arg_type(&child) != dbus_c.DBUS_TYPE_INVALID) : (index += 1) {
        pushDbusIterValue(lua_state, &child);
        c.lua_rawseti(lua_state, table, index);
        if (dbus_c.dbus_message_iter_next(&child) == 0) break;
    }
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

fn tryZTemp(value: []const u8) [:0]const u8 {
    std.debug.assert(value.len < dbus_temp_z_buffers[0].len);
    const slot = dbus_temp_z_slot % dbus_temp_z_buffers.len;
    dbus_temp_z_slot +%= 1;
    @memcpy(dbus_temp_z_buffers[slot][0..value.len], value);
    dbus_temp_z_buffers[slot][value.len] = 0;
    return dbus_temp_z_buffers[slot][0..value.len :0];
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
        .background = getColorField(lua_state, colors_table, "background", base.background),
        .foreground = getColorField(lua_state, colors_table, "foreground", base.foreground),
        .primary = getColorField(lua_state, colors_table, "primary", base.primary),
        .on_primary = getColorField(lua_state, colors_table, "on_primary", base.on_primary),
        .surface = getColorField(lua_state, colors_table, "surface", base.surface),
        .surface_high = getColorField(lua_state, colors_table, "surface_high", base.surface_high),
        .surface_low = getColorField(lua_state, colors_table, "surface_low", base.surface_low),
        .border = getColorField(lua_state, colors_table, "border", base.border),
        .muted = getColorField(lua_state, colors_table, "muted", base.muted),
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
    c.lua_getfield(lua_state, theme_table, "components");
    defer pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return base;
    const components_table = c.lua_gettop(lua_state);

    c.lua_getfield(lua_state, components_table, "button");
    defer pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return base;
    const button_table = c.lua_gettop(lua_state);

    var result = base;
    result.padding_x = getNumberField(lua_state, button_table, "padding_x", result.padding_x);
    result.padding_y = getNumberField(lua_state, button_table, "padding_y", result.padding_y);
    result.radius = getNumberField(lua_state, button_table, "radius", result.radius);
    parseButtonStateTheme(lua_state, button_table, "default", &result.background, &result.foreground);
    parseButtonStateTheme(lua_state, button_table, "hover", &result.hover_background, &result.hover_foreground);
    parseButtonStateTheme(lua_state, button_table, "pressed", &result.pressed_background, null);
    parseButtonStateTheme(lua_state, button_table, "disabled", &result.disabled_background, &result.disabled_foreground);
    parseButtonFocusTheme(lua_state, button_table, &result.focused_border);
    return result;
}

fn parseButtonStateTheme(
    lua_state: *c.lua_State,
    button_table: c_int,
    key: [*:0]const u8,
    background: *?keywork.Color,
    foreground: ?*?keywork.Color,
) void {
    c.lua_getfield(lua_state, button_table, key);
    defer pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return;
    const state_table = c.lua_gettop(lua_state);
    background.* = getOptionalColorField(lua_state, state_table, "background") orelse background.*;
    if (foreground) |field| field.* = getOptionalColorField(lua_state, state_table, "foreground") orelse field.*;
}

fn parseButtonFocusTheme(lua_state: *c.lua_State, button_table: c_int, border: *?keywork.Color) void {
    c.lua_getfield(lua_state, button_table, "focused");
    defer pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return;
    const focused_table = c.lua_gettop(lua_state);
    border.* = getOptionalColorField(lua_state, focused_table, "border") orelse border.*;
}

fn parseInputTheme(lua_state: *c.lua_State, theme_table: c_int, base: keywork.InputTheme) keywork.InputTheme {
    c.lua_getfield(lua_state, theme_table, "components");
    defer pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return base;
    const components_table = c.lua_gettop(lua_state);

    c.lua_getfield(lua_state, components_table, "input");
    defer pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return base;
    const input_table = c.lua_gettop(lua_state);

    var result = base;
    result.background = getOptionalColorField(lua_state, input_table, "background") orelse result.background;
    result.foreground = getOptionalColorField(lua_state, input_table, "foreground") orelse result.foreground;
    result.placeholder = getOptionalColorField(lua_state, input_table, "placeholder") orelse result.placeholder;
    result.border = getOptionalColorField(lua_state, input_table, "border") orelse result.border;
    result.focused_border = getOptionalColorField(lua_state, input_table, "focused_border") orelse result.focused_border;
    result.padding_x = getNumberField(lua_state, input_table, "padding_x", result.padding_x);
    result.padding_y = getNumberField(lua_state, input_table, "padding_y", result.padding_y);
    result.radius = getNumberField(lua_state, input_table, "radius", result.radius);
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

fn getOptionalTextChangeCallbackField(
    lua_state: *c.lua_State,
    allocator: std.mem.Allocator,
    table: c_int,
    key: [*:0]const u8,
) !?keywork.Widget.TextChangeCallback {
    c.lua_getfield(lua_state, table, key);
    defer pop(lua_state, 1);
    if (c.lua_isnil(lua_state, -1)) return null;
    return try textChangeCallbackFromStack(lua_state, allocator, -1);
}

const LuaItemBuilder = struct {
    allocator: std.mem.Allocator,
    lua_state: *c.lua_State,
    ref: c_int,

    fn itemBuilder(self: *LuaItemBuilder) keywork.Widget.ItemBuilder {
        return .{
            .ptr = self,
            .build_fn = buildItem,
            .clone_fn = cloneBuilder,
            .destroy_fn = destroyBuilder,
        };
    }

    fn buildItem(ptr: *const anyopaque, scope: *BuildScope, index: usize) !keywork.Widget {
        const self: *const LuaItemBuilder = @ptrCast(@alignCast(ptr));
        if (self.ref < 0) return error.LuaCallbackAlreadyMoved;
        c.lua_rawgeti(self.lua_state, c.LUA_REGISTRYINDEX, self.ref);
        c.lua_pushinteger(self.lua_state, @intCast(index + 1));
        if (c.lua_pcall(self.lua_state, 1, 1, 0) != 0) {
            var len: usize = 0;
            const message_ptr = c.lua_tolstring(self.lua_state, -1, &len);
            if (message_ptr) |message| std.log.scoped(.keywork_luajit).warn("list item builder failed: {s}", .{message[0..len]});
            pop(self.lua_state, 1);
            return error.LuaCallbackFailed;
        }
        defer pop(self.lua_state, 1);
        return parseWidget(self.lua_state, scope.allocator, scope.allocator, .{}, .{}, -1);
    }

    /// Transfers the registry ref like LuaCallback.clone: parse-tree
    /// originals live in the build arena and are never destroyed, so the
    /// element clone must become the sole owner.
    fn cloneBuilder(allocator: std.mem.Allocator, ptr: *const anyopaque) !*const anyopaque {
        const self: *LuaItemBuilder = @ptrCast(@alignCast(@constCast(ptr)));
        if (self.ref < 0) return error.LuaCallbackAlreadyMoved;
        const copy = try allocator.create(LuaItemBuilder);
        copy.* = .{ .allocator = allocator, .lua_state = self.lua_state, .ref = self.ref };
        self.ref = -2;
        return copy;
    }

    fn destroyBuilder(allocator: std.mem.Allocator, ptr: *const anyopaque) void {
        const self: *LuaItemBuilder = @ptrCast(@alignCast(@constCast(ptr)));
        if (self.ref >= 0) c.luaL_unref(self.lua_state, c.LUA_REGISTRYINDEX, self.ref);
        allocator.destroy(self);
    }
};

fn textChangeCallbackFromStack(lua_state: *c.lua_State, allocator: std.mem.Allocator, index: c_int) !keywork.Widget.TextChangeCallback {
    if (c.lua_type(lua_state, index) != c.LUA_TFUNCTION) return error.ExpectedLuaFunction;

    c.lua_pushvalue(lua_state, index);
    const ref = c.luaL_ref(lua_state, c.LUA_REGISTRYINDEX);
    errdefer c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, ref);
    const callback = try allocator.create(LuaCallback);
    callback.* = .{ .allocator = allocator, .lua_state = lua_state, .ref = ref };
    return callback.keyworkTextChangeCallback();
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
        \\    return ui.gesture({ id = "counter", child = ui.text(tostring(self.count)), on_tap = function()
        \\      self:set_state(function(s)
        \\        s.count = s.count + 1
        \\      end)
        \\    end })
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
        \\    return ui.gesture({ id = "remove", child = ui.text("remove"), on_tap = self.props.on_remove })
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
        \\    return ui.theme({ data = context.theme, child = ui.label(context.theme.color_scheme) })
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

test "lua resolves theme families and component tokens" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\local ui = require("ui")
        \\local theme_family = ui.theme_data({
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
        \\local App = ui.stateful({
        \\  build = function(self, context)
        \\    return ui.theme({
        \\      data = ui.resolve_theme(theme_family, context),
        \\      child = ui.text_input({ id = "name", value = "", placeholder = "Name" }),
        \\    })
        \\  end,
        \\})
        \\return App({ key = "app" })
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "theme-family.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "theme-family.lua" });
    defer allocator.free(script_path);

    var app = try App.init(allocator, script_path);
    defer app.deinit();

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var log_backend: keywork.LogBackend = .{ .writer = &output.writer };
    var runtime = try keywork.Runtime.init(
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
        \\local ui = require("ui")
        \\return ui.column({
        \\  children = {
        \\    ui.row({ main_align = "space_between", children = { ui.text("L"), ui.text("R") } }),
        \\    ui.row({ children = { ui.text("A"), ui.expanded(ui.text("B")) } }),
        \\  },
        \\})
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "flex.lua", .data = script });
    const script_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "flex.lua" });
    defer allocator.free(script_path);

    var app = try App.init(allocator, script_path);
    defer app.deinit();

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var log_backend: keywork.LogBackend = .{ .writer = &output.writer };
    var runtime = try keywork.Runtime.init(
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
        \\local ui = require("ui")
        \\local keywork = require("keywork")
        \\fs_event_seen = false
        \\fs_event_path = ""
        \\local App = ui.stateful({{
        \\  init = function(self)
        \\    self.watch = keywork.loop.fs_event({{ path = "{s}" }}, function(event)
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
        \\    return ui.text("fs_event")
        \\  end,
        \\}})
        \\return App({{ key = "app" }})
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
    var log_backend: keywork.LogBackend = .{ .writer = &output.writer };
    // The loop must outlive the runtime: runtime deinit disposes stateful
    // widgets whose Lua dispose callbacks cancel sources on the loop.
    var loop = try keywork.event_loop.EventLoop.init(allocator);
    defer loop.deinit();
    var runtime = try keywork.Runtime.init(
        allocator,
        log_backend.backend(),
        .{ .max_width = 100, .max_height = 40 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();

    try App.installEventSources(&app, &loop, &runtime);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "watched.txt", .data = "after\n" });

    const FsEventTest = struct {
        app: *App,
        ticks: u32 = 0,

        fn callback(ctx: *anyopaque, event_loop: *keywork.event_loop.EventLoop, _: u64) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.ticks += 1;
            c.lua_getglobal(self.app.state, "fs_event_seen");
            const seen = c.lua_toboolean(self.app.state, -1) != 0;
            pop(self.app.state, 1);
            if (seen or self.ticks > 1000) event_loop.quit();
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
    // The loop must outlive the runtime: runtime deinit disposes stateful
    // widgets whose Lua dispose callbacks cancel sources on the loop.
    var loop = try keywork.event_loop.EventLoop.init(allocator);
    defer loop.deinit();
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

        fn callback(ctx: *anyopaque, event_loop: *keywork.event_loop.EventLoop, _: u64) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.ticks += 1;
            c.lua_getglobal(self.app.state, "spawn_done");
            const done = c.lua_toboolean(self.app.state, -1) != 0;
            pop(self.app.state, 1);
            if (done or self.ticks > 1000) event_loop.quit();
        }
    };

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
