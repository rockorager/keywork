//! Lua widget parsing and Lua-backed widget runtime objects.

const std = @import("std");
const keywork = @import("../ui.zig");
const icon_theme = @import("../linux/icon_theme.zig");
const lua_codec = @import("codec.zig");
const lua_image = @import("image.zig");
const lua_theme = @import("theme.zig");
const lua_value = @import("value.zig");
const svg_icon = @import("../graphics/svg_icon.zig");
const c = @import("luajit_c");

const State = keywork.AppContext;
const BuildScope = keywork.BuildScope;
const TextOptions = lua_theme.TextOptions;
const absoluteIndex = lua_value.absoluteIndex;
const boolField = lua_value.boolField;
const cloneRegistryRef = lua_value.cloneRegistryRef;
const dupeStringField = lua_value.dupeStringField;
const expectType = lua_value.expectType;
const getStringField = lua_value.getStringField;
const pop = lua_value.pop;
const stringField = lua_value.stringField;
const stringFromStack = lua_value.stringFromStack;
const tableRefField = lua_value.tableRefField;

pub const Host = struct {
    ptr: *anyopaque,
    invalidate_state_fn: *const fn (*anyopaque) anyerror!void,

    pub fn invalidateState(self: Host) !void {
        try self.invalidate_state_fn(self.ptr);
    }
};

fn luaSetState(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const state: *LuaStatefulState = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    if (c.lua_type(lua_state, 2) == c.LUA_TFUNCTION) {
        c.lua_pushvalue(lua_state, 2);
        c.lua_pushvalue(lua_state, 1);
        if (c.lua_pcall(lua_state, 1, 0, 0) != 0) {
            failLuaCall(lua_state, "set_state callback failed") catch {};
            return c.luaL_error(lua_state, "set_state callback failed");
        }
    }
    state.dirty = true;
    state.host.invalidateState() catch |err| {
        std.log.scoped(.keywork_luajit).warn("set_state invalidate failed: {}", .{err});
        return c.luaL_error(lua_state, "set_state invalidate failed");
    };
    return 0;
}

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
    host: Host,
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
        state.* = .{ .host = self.host, .lua_state = self.lua_state, .state_ref = -1 };

        c.lua_createtable(self.lua_state, 0, 0);
        const state_table = c.lua_gettop(self.lua_state);
        errdefer pop(self.lua_state, 1);
        installStateMethods(self.lua_state, state, state_table);
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
        return try parse(self.host, self.lua_state, scope.allocator, scope.allocator, context.app_context, self.parse_context, -1);
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
            .host = self.host,
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
    host: Host,
    lua_state: *c.lua_State,
    state_ref: c_int,
    dirty: bool = false,
};

pub fn pushRuntimeState(lua_state: *c.lua_State, state: State) void {
    c.lua_createtable(lua_state, 0, 3);
    const table = c.lua_gettop(lua_state);
    c.lua_pushnumber(lua_state, state.window_width);
    c.lua_setfield(lua_state, table, "window_width");
    c.lua_pushnumber(lua_state, state.window_height);
    c.lua_setfield(lua_state, table, "window_height");
    c.lua_pushlstring(lua_state, state.color_scheme.ptr, state.color_scheme.len);
    c.lua_setfield(lua_state, table, "color_scheme");
}

/// Both allocators are the runtime's per-build arena, so parse never frees
/// partial trees on error; the arena reclaims them wholesale on the next
/// build. Do not add per-allocation errdefer cleanup here. Lua registry refs
/// are the exception: the arena cannot release them, so any branch that takes
/// a ref must errdefer-unref it before the next fallible call.
pub fn parse(
    host: Host,
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
        child.* = try parse(host, lua_state, allocator, callback_allocator, runtime_state, parse_context, -1);
        return .{ .keyed = .{ .key = .{ .string = key }, .child = child } };
    }
    if (std.mem.eql(u8, kind, "stateful")) {
        const stateful = try allocator.create(LuaStatefulWidget);
        const spec_ref = try tableRefField(lua_state, table, "spec");
        errdefer c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, spec_ref);
        const props_ref = try tableRefField(lua_state, table, "props");
        errdefer c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, props_ref);
        c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, spec_ref);
        const spec_token = c.lua_topointer(lua_state, -1);
        pop(lua_state, 1);
        stateful.* = .{
            .allocator = allocator,
            .host = host,
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
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parse(host, lua_state, allocator, callback_allocator, runtime_state, parse_context, -1);
        return .{ .theme = .{ .theme = lua_theme.parseField(lua_state, table, "theme"), .child = child } };
    }
    if (std.mem.eql(u8, kind, "default_text_style")) {
        const options = try lua_codec.decode(TextOptions, lua_state, table, allocator);
        const child = try allocator.create(keywork.Widget);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parse(host, lua_state, allocator, callback_allocator, runtime_state, parse_context, -1);
        return .{ .default_text_style = .{ .style = .{ .color = options.color, .font_size = options.resolvedFontSize() }, .child = child } };
    }
    if (std.mem.eql(u8, kind, "icon_theme")) {
        const options = try lua_codec.decode(IconOptions, lua_state, table, allocator);
        const child = try allocator.create(keywork.Widget);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parse(host, lua_state, allocator, callback_allocator, runtime_state, parse_context.mergeIcon(options), -1);
        const result = child.*;
        allocator.destroy(child);
        return result;
    }
    if (std.mem.eql(u8, kind, "box")) {
        const options = try lua_codec.decode(BoxOptions, lua_state, table, allocator);
        const child = try allocator.create(keywork.Widget);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parse(host, lua_state, allocator, callback_allocator, runtime_state, parse_context, -1);
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
        const child = try allocator.create(keywork.Widget);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parse(host, lua_state, allocator, callback_allocator, runtime_state, parse_context, -1);
        const on_click = try getOptionalCallbackField(lua_state, callback_allocator, table, "on_click");
        return .{ .clickable = .{ .id = id, .child = child, .on_click = on_click, .activation = getActivationField(lua_state, table) } };
    }
    if (std.mem.eql(u8, kind, "gesture")) {
        const options = try lua_codec.decode(GestureOptions, lua_state, table, allocator);
        const id = try dupeStringField(lua_state, allocator, table, "id");
        const child = try allocator.create(keywork.Widget);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parse(host, lua_state, allocator, callback_allocator, runtime_state, parse_context, -1);
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
        const child = try allocator.create(keywork.Widget);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parse(host, lua_state, allocator, callback_allocator, runtime_state, parse_context, -1);
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
        const child = try allocator.create(keywork.Widget);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parse(host, lua_state, allocator, callback_allocator, runtime_state, parse_context, -1);
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
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parse(host, lua_state, allocator, callback_allocator, runtime_state, parse_context, -1);
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
        builder.* = .{ .allocator = callback_allocator, .host = host, .lua_state = lua_state, .ref = ref };
        return keywork.widgets.list(id, options.count, options.item_height, builder.itemBuilder());
    }
    if (std.mem.eql(u8, kind, "spacer")) {
        const options = try lua_codec.decode(SpacerOptions, lua_state, table, allocator);
        return keywork.widgets.spacer(options.flex);
    }
    if (std.mem.eql(u8, kind, "sized")) {
        const options = try lua_codec.decode(SizedOptions, lua_state, table, allocator);
        const child = try allocator.create(keywork.Widget);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parse(host, lua_state, allocator, callback_allocator, runtime_state, parse_context, -1);
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
        return try lua_image.parse(lua_state, allocator, table);
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
                .png => lua_image.pngIcon(allocator, icon_file.path, icon.size),
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
            .png => lua_image.pngIcon(allocator, icon_file.path, icon.size),
        };
    }
    if (std.mem.eql(u8, kind, "row")) {
        const options = try lua_codec.decode(LinearOptions, lua_state, table, allocator);
        const children = try parseChildren(host, lua_state, allocator, callback_allocator, runtime_state, parse_context, table);
        return .{ .row = .{ .children = children, .gap = options.spacing, .cross_align = options.crossAlign(), .main_align = options.mainAlign() } };
    }
    if (std.mem.eql(u8, kind, "column")) {
        const options = try lua_codec.decode(LinearOptions, lua_state, table, allocator);
        const children = try parseChildren(host, lua_state, allocator, callback_allocator, runtime_state, parse_context, table);
        return .{ .column = .{ .children = children, .gap = options.spacing, .cross_align = options.crossAlign(), .main_align = options.mainAlign() } };
    }
    if (std.mem.eql(u8, kind, "padding")) {
        const options = try lua_codec.decode(PaddingOptions, lua_state, table, allocator);
        const child = try allocator.create(keywork.Widget);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parse(host, lua_state, allocator, callback_allocator, runtime_state, parse_context, -1);
        return .{ .padding = .{ .insets = options.resolved(), .child = child } };
    }
    if (std.mem.eql(u8, kind, "center")) {
        const child = try allocator.create(keywork.Widget);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parse(host, lua_state, allocator, callback_allocator, runtime_state, parse_context, -1);
        return .{ .center = .{ .child = child } };
    }
    if (std.mem.eql(u8, kind, "flexible")) {
        const options = try lua_codec.decode(FlexibleOptions, lua_state, table, allocator);
        const child = try allocator.create(keywork.Widget);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parse(host, lua_state, allocator, callback_allocator, runtime_state, parse_context, -1);
        return .{ .flexible = .{ .child = child, .flex = options.flex, .fit = options.fit orelse .tight } };
    }
    if (std.mem.eql(u8, kind, "actions")) {
        const child = try allocator.create(keywork.Widget);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parse(host, lua_state, allocator, callback_allocator, runtime_state, parse_context, -1);
        const bindings = try parseActionBindings(lua_state, allocator, callback_allocator, table);
        return .{ .actions = .{ .bindings = bindings, .child = child } };
    }
    if (std.mem.eql(u8, kind, "shortcuts")) {
        const child = try allocator.create(keywork.Widget);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parse(host, lua_state, allocator, callback_allocator, runtime_state, parse_context, -1);
        const bindings = try parseShortcutBindings(lua_state, allocator, table);
        return .{ .shortcuts = .{ .bindings = bindings, .child = child } };
    }

    return error.UnknownWidgetType;
}

// Callers log the miss; the cache path warns only once per name+size.
fn missingIconWidget(allocator: std.mem.Allocator, color: keywork.Color) !keywork.Widget {
    return .{ .text = .{ .value = try allocator.dupe(u8, "□"), .color = color } };
}

fn parseChildren(
    host: Host,
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
        child.* = try parse(host, lua_state, allocator, callback_allocator, runtime_state, parse_context, -1);
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

fn installStateMethods(lua_state: *c.lua_State, state: *LuaStatefulState, state_table: c_int) void {
    c.lua_pushlightuserdata(lua_state, state);
    c.lua_pushcclosure(lua_state, luaSetState, 1);
    c.lua_setfield(lua_state, state_table, "set_state");
}

fn setStateProps(lua_state: *c.lua_State, state_table: c_int, props_ref: c_int) void {
    c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, props_ref);
    c.lua_setfield(lua_state, state_table, "props");
}

const failLuaCall = lua_value.failLuaCall;

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
    host: Host,
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
        return parse(self.host, self.lua_state, scope.allocator, scope.allocator, .{}, .{}, -1);
    }

    /// Transfers the registry ref like LuaCallback.clone: parse-tree
    /// originals live in the build arena and are never destroyed, so the
    /// element clone must become the sole owner.
    fn cloneBuilder(allocator: std.mem.Allocator, ptr: *const anyopaque) !*const anyopaque {
        const self: *LuaItemBuilder = @ptrCast(@alignCast(@constCast(ptr)));
        if (self.ref < 0) return error.LuaCallbackAlreadyMoved;
        const copy = try allocator.create(LuaItemBuilder);
        copy.* = .{ .allocator = allocator, .host = self.host, .lua_state = self.lua_state, .ref = self.ref };
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
