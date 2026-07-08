//! LuaJIT application host and native Keywork bindings.

const std = @import("std");
const keywork = @import("../ui.zig");
const app_options = @import("../app/options.zig");
const log_backend_mod = @import("../backend/log.zig");
const wayland_options = @import("../backend/wayland/options.zig");
const event_loop = @import("../linux/event_loop.zig");
const icon_theme = @import("../linux/icon_theme.zig");
const image_c = @import("image_c");
const lua_codec = @import("codec.zig");
const lua_process = @import("process.zig");
const lua_dbus = @import("dbus.zig");
const lua_loop = @import("loop.zig");
const runtime_mod = @import("../ui/runtime.zig");
const svg_icon = @import("../graphics/svg_icon.zig");
const c = @import("luajit_c");

const linux = std.os.linux;
const State = keywork.AppContext;
const BuildScope = keywork.BuildScope;

const app_registry_key = "keywork.app";
const invalid_fd: i32 = -1;
const LuaProcess = lua_process.LuaProcess;
const DbusBus = lua_dbus.Bus;
const FdWatch = lua_loop.FdWatch;
const FsEvent = lua_loop.FsEvent;
const LuaTimer = lua_loop.LuaTimer;

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
    icon_cache: ?*icon_theme.Cache = null,
    /// Render scale used to select icon files at physical resolution.
    icon_scale: f32 = 1,

    fn resolveIcon(self: ParseContext, options: IconOptions) struct { size: f32, color: ?keywork.Color } {
        return .{
            .size = options.size orelse self.icon.size orelse 16,
            // No explicit or ambient color renders the icon's own palette.
            .color = options.color orelse self.icon.color,
        };
    }

    fn mergeIcon(self: ParseContext, options: IconOptions) ParseContext {
        return .{
            .icon = .{
                .size = options.size orelse self.icon.size,
                .color = options.color orelse self.icon.color,
            },
            .icon_cache = self.icon_cache,
            .icon_scale = self.icon_scale,
        };
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
        if (self.width == 0 or self.height == 0) return;

        // The renderer blits image pixels 1:1 at physical resolution, so
        // the source must be resampled to rect * scale (like svg_icon).
        const render_scale = if (std.math.isFinite(context.scale) and context.scale > 0) context.scale else 1;
        const target_width: u32 = @max(1, @as(u32, @intFromFloat(@ceil(context.rect.width * render_scale))));
        const target_height: u32 = @max(1, @as(u32, @intFromFloat(@ceil(context.rect.height * render_scale))));

        var hasher = std.hash.Wyhash.init(self.cache_key);
        hasher.update(std.mem.asBytes(&target_width));
        hasher.update(std.mem.asBytes(&target_height));
        const cache_key = hasher.final();

        if (context.display_list.cachedColorImage(cache_key, target_width, target_height)) |cached| {
            try context.display_list.colorImage(
                context.allocator,
                context.rect,
                target_width,
                target_height,
                @constCast(cached),
                cache_key,
            );
            return;
        }

        const pixels = try resampledPixels(context.allocator, self.pixels, self.width, self.height, target_width, target_height);
        try context.display_list.colorImage(
            context.allocator,
            context.rect,
            target_width,
            target_height,
            pixels,
            cache_key,
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

/// Window options declared by the returned keywork.app({...}) root.
/// Null fields fall back to CLI flags and built-in defaults.
pub const WindowConfig = struct {
    app_id: ?[:0]u8 = null,
    title: ?[:0]u8 = null,
    backend: ?app_options.BackendKind = null,
    width: ?f32 = null,
    height: ?f32 = null,
    layer_shell: ?wayland_options.LayerShellOptions = null,

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
        const widget = try parseWidget(self.state, allocator, allocator, runtime_state, .{
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
        var config = try parseAppRoot(self, app_root);
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
    c.lua_pushlightuserdata(lua_state, app);
    c.lua_setfield(lua_state, c.LUA_REGISTRYINDEX, app_registry_key);

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

/// Read an optional string field from an app-root table. The returned slice
/// stays valid while the table is reachable: the string is anchored by the
/// table field itself.
fn checkStringField(lua_state: *c.lua_State, table_index: c_int, name: [:0]const u8) !?[]const u8 {
    c.lua_getfield(lua_state, table_index, name.ptr);
    defer pop(lua_state, 1);
    switch (c.lua_type(lua_state, -1)) {
        c.LUA_TNIL => return null,
        c.LUA_TSTRING => {},
        else => return invalidAppRoot("app option '{s}' must be a string", .{name}),
    }
    var len: usize = 0;
    const ptr = c.lua_tolstring(lua_state, -1, &len).?;
    return ptr[0..len];
}

fn checkNumberField(lua_state: *c.lua_State, table_index: c_int, name: [:0]const u8) !?f64 {
    c.lua_getfield(lua_state, table_index, name.ptr);
    defer pop(lua_state, 1);
    switch (c.lua_type(lua_state, -1)) {
        c.LUA_TNIL => return null,
        c.LUA_TNUMBER => return c.lua_tonumber(lua_state, -1),
        else => return invalidAppRoot("app option '{s}' must be a number", .{name}),
    }
}

fn checkI32Field(lua_state: *c.lua_State, table_index: c_int, name: [:0]const u8) !?i32 {
    const value = (try checkNumberField(lua_state, table_index, name)) orelse return null;
    const min: f64 = @floatFromInt(std.math.minInt(i32));
    const max: f64 = @floatFromInt(std.math.maxInt(i32));
    if (!std.math.isFinite(value) or value < min or value > max) return invalidAppRoot("app option '{s}' is out of range", .{name});
    return @intFromFloat(value);
}

fn invalidAppRoot(comptime format: []const u8, args: anytype) error{InvalidAppRoot} {
    std.log.scoped(.keywork_luajit).warn(format, args);
    return error.InvalidAppRoot;
}

fn backendFromName(name: []const u8) ?app_options.BackendKind {
    if (std.mem.eql(u8, name, "cpu")) return .wayland_shm;
    if (std.mem.eql(u8, name, "vulkan")) return .vulkan;
    if (std.mem.eql(u8, name, "log")) return .log;
    return null;
}

fn parseLayerShellTable(lua_state: *c.lua_State, table_index: c_int) !wayland_options.LayerShellOptions {
    var options: wayland_options.LayerShellOptions = .{};

    if (try checkStringField(lua_state, table_index, "layer")) |name| {
        options.layer = if (std.mem.eql(u8, name, "background"))
            .background
        else if (std.mem.eql(u8, name, "bottom"))
            .bottom
        else if (std.mem.eql(u8, name, "top"))
            .top
        else if (std.mem.eql(u8, name, "overlay"))
            .overlay
        else
            return invalidAppRoot("unknown layer '{s}' (expected background, bottom, top, or overlay)", .{name});
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
                if (c.lua_type(lua_state, -1) != c.LUA_TSTRING) return invalidAppRoot("anchor entries must be strings", .{});
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
                } else return invalidAppRoot("unknown anchor '{s}' (expected top, bottom, left, or right)", .{name});
                pop(lua_state, 1);
            }
        },
        else => return invalidAppRoot("layer_shell.anchor must be an array of strings", .{}),
    }
    pop(lua_state, 1);

    if (try checkI32Field(lua_state, table_index, "exclusive_zone")) |value| options.exclusive_zone = value;

    c.lua_getfield(lua_state, table_index, "margin");
    switch (c.lua_type(lua_state, -1)) {
        c.LUA_TNIL => {},
        c.LUA_TTABLE => {
            const margin_table = c.lua_gettop(lua_state);
            if (try checkI32Field(lua_state, margin_table, "top")) |value| options.margin.top = value;
            if (try checkI32Field(lua_state, margin_table, "right")) |value| options.margin.right = value;
            if (try checkI32Field(lua_state, margin_table, "bottom")) |value| options.margin.bottom = value;
            if (try checkI32Field(lua_state, margin_table, "left")) |value| options.margin.left = value;
        },
        else => return invalidAppRoot("layer_shell.margin must be a table", .{}),
    }
    pop(lua_state, 1);

    if (try checkStringField(lua_state, table_index, "keyboard")) |name| {
        options.keyboard_interactivity = if (std.mem.eql(u8, name, "none"))
            .none
        else if (std.mem.eql(u8, name, "exclusive"))
            .exclusive
        else if (std.mem.eql(u8, name, "on-demand") or std.mem.eql(u8, name, "on_demand"))
            .on_demand
        else
            return invalidAppRoot("unknown keyboard interactivity '{s}' (expected none, exclusive, or on-demand)", .{name});
    }

    if (try checkStringField(lua_state, table_index, "output")) |name| {
        options.output = if (std.mem.eql(u8, name, "all"))
            .all
        else if (std.mem.eql(u8, name, "default") or std.mem.eql(u8, name, "compositor_default"))
            .compositor_default
        else
            return invalidAppRoot("unknown layer-shell output '{s}' (expected default or all)", .{name});
    }

    return options;
}

fn parseAppRoot(app: *App, table_index: c_int) !WindowConfig {
    const lua_state = app.state;
    var config: WindowConfig = .{};
    const root_type = (try checkStringField(lua_state, table_index, "type")) orelse
        return invalidAppRoot("script must return kw.app(...) as its root", .{});
    if (!std.mem.eql(u8, root_type, "app")) return invalidAppRoot("script root must be an app, got '{s}'", .{root_type});

    if (try checkStringField(lua_state, table_index, "backend")) |name| {
        config.backend = backendFromName(name) orelse
            return invalidAppRoot("unknown backend '{s}' (expected cpu, vulkan, or log)", .{name});
    }
    if (try checkNumberField(lua_state, table_index, "width")) |value| config.width = @floatCast(value);
    if (try checkNumberField(lua_state, table_index, "height")) |value| config.height = @floatCast(value);

    c.lua_getfield(lua_state, table_index, "layer_shell");
    switch (c.lua_type(lua_state, -1)) {
        c.LUA_TNIL => {},
        c.LUA_TTABLE => config.layer_shell = try parseLayerShellTable(lua_state, c.lua_gettop(lua_state)),
        else => return invalidAppRoot("app option 'layer_shell' must be a table", .{}),
    }
    pop(lua_state, 1);

    c.lua_getfield(lua_state, table_index, "child");
    const child_is_widget = c.lua_type(lua_state, -1) == c.LUA_TTABLE and isWidgetTable(lua_state, c.lua_gettop(lua_state));
    pop(lua_state, 1);
    if (!child_is_widget) return invalidAppRoot("kw.app requires a widget child", .{});

    const app_id = try checkStringField(lua_state, table_index, "app_id");
    const title = try checkStringField(lua_state, table_index, "title");
    if (app_id) |value| {
        config.app_id = app.allocator.dupeZ(u8, value) catch return error.OutOfMemory;
    }
    if (title) |value| {
        config.title = app.allocator.dupeZ(u8, value) catch {
            config.deinit(app.allocator);
            return error.OutOfMemory;
        };
    }

    return config;
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
        widget.text_input.autofocus = boolField(lua_state, table, "autofocus");
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
        return svg_icon.icon(
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
        const fallback_color = icon.color orelse keywork.colors.ink;
        // Select the icon file for the physical pixel size so HiDPI
        // outputs get the sharper large variant; widgets stay logical.
        const lookup_size = icon.size * parse_context.icon_scale;
        if (parse_context.icon_cache) |cache| {
            // The cache owns the path and tombstones misses, so absent
            // icons neither re-walk the theme tree nor warn again.
            const icon_file = try cache.lookup(name, lookup_size) orelse return missingIconWidget(allocator, fallback_color);
            return switch (icon_file.format) {
                .svg => svg_icon.icon(allocator, icon_file.path, icon.size, icon.color),
                .png => pngIconWidget(allocator, icon_file.path, icon.size),
            };
        }
        const icon_file = try icon_theme.lookupIconSized(allocator, name, lookup_size) orelse {
            std.log.scoped(.keywork_luajit).warn("missing icon {s}", .{name});
            return missingIconWidget(allocator, fallback_color);
        };
        defer allocator.free(icon_file.path);
        return switch (icon_file.format) {
            .svg => svg_icon.icon(
                allocator,
                icon_file.path,
                icon.size,
                icon.color,
            ),
            .png => pngIconWidget(allocator, icon_file.path, icon.size),
        };
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

// Callers log the miss; the cache path warns only once per name+size.
fn missingIconWidget(allocator: std.mem.Allocator, color: keywork.Color) !keywork.Widget {
    return .{ .text = .{ .value = try allocator.dupe(u8, "□"), .color = color } };
}

fn pngIconWidget(allocator: std.mem.Allocator, path: []const u8, size: f32) !keywork.Widget {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    var source_width: c_int = 0;
    var source_height: c_int = 0;
    var source_channels: c_int = 0;
    const source_pixels = image_c.stbi_load(path_z.ptr, &source_width, &source_height, &source_channels, 4) orelse return error.InvalidPng;
    defer image_c.stbi_image_free(source_pixels);
    if (source_width <= 0 or source_height <= 0) return error.InvalidPng;

    // Keep the source at native resolution; paint resamples straight to
    // the physical target so the pixels are only interpolated once.
    const pixel_count: usize = @intCast(source_width * source_height);
    const pixels = try allocator.alloc(keywork.Color, pixel_count);
    errdefer allocator.free(pixels);
    fillRgbaPixels(pixels, source_pixels[0 .. pixel_count * 4]);

    var hasher = std.hash.Wyhash.init(0);
    hasher.update(path);

    const image = try allocator.create(LuaImage);
    errdefer allocator.destroy(image);
    image.* = .{
        .width = @intCast(source_width),
        .height = @intCast(source_height),
        .size = @floatFromInt(positiveImageSize(size)),
        .pixels = pixels,
        .cache_key = hasher.final(),
    };
    return image.widget();
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

fn fillRgbaPixels(pixels: []keywork.Color, bytes: []const u8) void {
    for (pixels, 0..) |*pixel, index| {
        const base = index * 4;
        pixel.* = keywork.Color.argb(bytes[base + 3], bytes[base], bytes[base + 1], bytes[base + 2]);
    }
}

/// Resample source pixels to the target dimensions; returns freshly
/// allocated pixels the caller owns (a plain copy when sizes match).
fn resampledPixels(
    allocator: std.mem.Allocator,
    source: []const keywork.Color,
    source_width: u32,
    source_height: u32,
    target_width: u32,
    target_height: u32,
) ![]keywork.Color {
    if (source_width == target_width and source_height == target_height) {
        return allocator.dupe(keywork.Color, source);
    }

    const source_bytes = try allocator.alloc(u8, source.len * 4);
    defer allocator.free(source_bytes);
    for (source, 0..) |pixel, index| {
        const base = index * 4;
        source_bytes[base] = pixel.r;
        source_bytes[base + 1] = pixel.g;
        source_bytes[base + 2] = pixel.b;
        source_bytes[base + 3] = pixel.a;
    }

    const target_bytes = try allocator.alloc(u8, @as(usize, target_width) * target_height * 4);
    defer allocator.free(target_bytes);
    if (image_c.stbir_resize_uint8_linear(
        source_bytes.ptr,
        @intCast(source_width),
        @intCast(source_height),
        0,
        target_bytes.ptr,
        @intCast(target_width),
        @intCast(target_height),
        0,
        image_c.STBIR_RGBA_NO_AW,
    ) == null) {
        return error.ImageResizeFailed;
    }

    const pixels = try allocator.alloc(keywork.Color, @as(usize, target_width) * target_height);
    fillRgbaPixels(pixels, target_bytes);
    return pixels;
}

fn positiveImageSize(size: f32) usize {
    if (!std.math.isFinite(size) or size <= 0) return 16;
    return @max(1, @as(usize, @intFromFloat(@round(size))));
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
    if (std.mem.eql(u8, value, "escape")) return .escape;
    if (std.mem.eql(u8, value, "up")) return .up;
    if (std.mem.eql(u8, value, "down")) return .down;
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

fn boolField(lua_state: *c.lua_State, table: c_int, key: [*:0]const u8) bool {
    c.lua_getfield(lua_state, table, key);
    defer pop(lua_state, 1);
    return c.lua_toboolean(lua_state, -1) != 0;
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
