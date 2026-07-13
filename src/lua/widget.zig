//! Lua widget parsing and Lua-backed widget runtime objects.

const std = @import("std");
const keywork = @import("../ui.zig");
const icon_theme = @import("../linux/icon_theme.zig");
const lua_codec = @import("codec.zig");
const lua_handle = @import("handle.zig");
const lua_image = @import("image.zig");
const lua_task = @import("task.zig");
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
    state_invalidator: keywork.Widget.Callback,
    create_scope_fn: *const fn (*anyopaque) anyerror!*lua_task.LuaScope,
    dispose_scope_fn: *const fn (*anyopaque, *lua_task.LuaScope) void,

    pub fn invalidateState(self: Host) !void {
        try self.state_invalidator.call();
    }

    fn withStateInvalidator(self: Host, state_invalidator: ?keywork.Widget.Callback) Host {
        var result = self;
        result.state_invalidator = state_invalidator orelse return result;
        return result;
    }

    pub fn createScope(self: Host) !*lua_task.LuaScope {
        return self.create_scope_fn(self.ptr);
    }

    pub fn disposeScope(self: Host, scope: *lua_task.LuaScope) void {
        self.dispose_scope_fn(self.ptr, scope);
    }
};

fn luaSetState(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    // A callback may retain the state table past dispose; a dead slot makes
    // the stale set_state a no-op instead of touching freed memory.
    const state = lua_handle.slotResource(LuaStatefulState, lua_state, c.lua_upvalueindex(1)) orelse return 0;
    if (c.lua_type(lua_state, 2) == c.LUA_TFUNCTION) {
        c.lua_pushvalue(lua_state, 2);
        c.lua_pushvalue(lua_state, 1);
        if (c.lua_pcall(lua_state, 1, 0, 0) != 0) {
            failLuaCall(lua_state, "set_state callback failed") catch {};
            return c.luaL_error(lua_state, "set_state callback failed");
        }
    }
    state.rebuild_generation +%= 1;
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
    shadow: ?keywork.BoxShadow = null,
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
    pressed_background: ?keywork.Color = null,
    focused_border: ?keywork.Color = null,
    focused_border_width: f32 = 2,
    cursor: keywork.CursorShape = .default,
    activation: keywork.Widget.ClickActivation = .press,

    fn hoverStyle(self: GestureOptions) ?keywork.Widget.ClickableStyle {
        if (self.hover_background == null) return null;
        return .{ .background = self.hover_background };
    }

    fn pressedStyle(self: GestureOptions) ?keywork.Widget.ClickableStyle {
        if (self.pressed_background == null) return null;
        return .{ .background = self.pressed_background };
    }
};

const FocusOptions = struct {
    autofocus: bool = false,
    skip_traversal: bool = false,
    can_request_focus: bool = true,
};

const PopupOptions = struct {
    edge: keywork.Widget.PopupPlacement.Edge = .bottom,
    alignment: keywork.Widget.Alignment = .start,
    gap: f32 = 0,
    width: ?f32 = null,
    height: ?f32 = null,
    shadow: ?keywork.BoxShadow = null,
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
    symbolic: ?bool = null,
};

const SeparatorOptions = struct {
    color: ?keywork.Color = null,
    thickness: f32 = 1,
    axis: keywork.Widget.Separator.Axis = .horizontal,
    margin: f32 = 0,
};

const TextInputOptions = struct {
    variant: ?[]const u8 = null,
    obscured: bool = false,
    clear_on_submit: bool = false,
    background: ?keywork.Color = null,
    foreground: ?keywork.Color = null,
    placeholder_color: ?keywork.Color = null,
    border: ?keywork.Color = null,
    focused_border: ?keywork.Color = null,
    padding_x: ?f32 = null,
    padding_y: ?f32 = null,
    radius: ?f32 = null,
    font_size: ?f32 = null,
    line_height: ?f32 = null,

    fn style(self: TextInputOptions) keywork.Widget.TextInput.Style {
        const plain = if (self.variant) |variant| std.mem.eql(u8, variant, "plain") else false;
        return .{
            .background = self.background orelse if (plain) keywork.colors.transparent else null,
            .foreground = self.foreground,
            .placeholder_foreground = self.placeholder_color,
            .border = self.border orelse if (plain) keywork.colors.transparent else null,
            .focused_border = self.focused_border orelse if (plain) keywork.colors.transparent else null,
            .padding_x = self.padding_x orelse if (plain) 0 else null,
            .padding_y = self.padding_y orelse if (plain) 0 else null,
            .radius = self.radius orelse if (plain) 0 else null,
            .font_size = self.font_size,
            .line_height = self.line_height,
        };
    }
};

const ParseContext = struct {
    icon: IconOptions = .{},
    icon_cache: ?*icon_theme.Cache = null,
    /// Render scale used to select icon files at physical resolution.
    icon_scale: f32 = 1,
    /// Intrinsic image dimensions per path, so raster icons skip the
    /// stbi_info header read on every rebuild.
    png_dims: ?*lua_image.DimsCache = null,
    /// Lexically enclosing Lua theme. Borrowed during recursive parsing;
    /// deferred builders and stateful widgets clone it for their lifetime.
    theme_ref: c_int = -1,

    fn resolveIcon(self: ParseContext, options: IconOptions) struct { size: f32, color: ?keywork.Color, symbolic: bool } {
        const color = options.color orelse self.icon.color;
        return .{
            .size = options.size orelse self.icon.size orelse keywork.scale.space(4),
            // No explicit or ambient color renders the icon's own palette.
            .color = color,
            .symbolic = options.symbolic orelse self.icon.symbolic orelse false,
        };
    }

    fn mergeIcon(self: ParseContext, options: IconOptions) ParseContext {
        return .{
            .icon = .{
                .size = options.size orelse self.icon.size,
                .color = options.color orelse self.icon.color,
                .symbolic = options.symbolic orelse self.icon.symbolic,
            },
            .icon_cache = self.icon_cache,
            .icon_scale = self.icon_scale,
            .png_dims = self.png_dims,
            .theme_ref = self.theme_ref,
        };
    }

    fn cloneOwned(self: ParseContext, lua_state: *c.lua_State) !ParseContext {
        var result = self;
        if (self.theme_ref >= 0) result.theme_ref = try cloneRegistryRef(lua_state, self.theme_ref);
        return result;
    }

    fn deinitOwned(self: *ParseContext, lua_state: *c.lua_State) void {
        if (self.theme_ref >= 0) c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, self.theme_ref);
        self.theme_ref = -2;
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

const SpinnerOptions = struct {
    size: f32 = keywork.scale.space(4),
    color: ?keywork.Color = null,
    period_ms: u32 = 800,
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

    fn keyworkTapCallback(self: *LuaCallback) keywork.Widget.TapCallback {
        return .{ .ptr = self, .call_fn = callTapEvent, .clone_fn = clone, .destroy_fn = destroy };
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

    fn keyworkScrollEventCallback(self: *LuaCallback) keywork.Widget.ScrollEventCallback {
        return .{ .ptr = self, .call_fn = callScrollEvent, .clone_fn = clone, .destroy_fn = destroy };
    }

    fn pushModifiers(lua_state: *c.lua_State, modifiers: keywork.Modifiers) void {
        c.lua_createtable(lua_state, 0, 4);
        inline for (.{ .{ "shift", modifiers.shift }, .{ "ctrl", modifiers.ctrl }, .{ "alt", modifiers.alt }, .{ "super", modifiers.super } }) |field| {
            lua_value.setBooleanField(lua_state, -1, field[0], field[1]);
        }
    }

    fn pushPosition(lua_state: *c.lua_State, position: keywork.Point, window_position: keywork.Point) void {
        inline for (.{ .{ "x", position.x }, .{ "y", position.y }, .{ "window_x", window_position.x }, .{ "window_y", window_position.y } }) |field| {
            lua_value.setNumberField(lua_state, -1, field[0], field[1]);
        }
    }

    fn callTapEvent(ptr: *anyopaque, event: keywork.TapEvent) !void {
        const self: *LuaCallback = @ptrCast(@alignCast(ptr));
        c.lua_rawgeti(self.lua_state, c.LUA_REGISTRYINDEX, self.ref);
        c.lua_createtable(self.lua_state, 0, 8);
        const source = @tagName(event.source);
        lua_value.setStringField(self.lua_state, -1, "source", source);
        if (event.button) |value| {
            const button = @tagName(value);
            c.lua_pushlstring(self.lua_state, button.ptr, button.len);
        } else c.lua_pushnil(self.lua_state);
        c.lua_setfield(self.lua_state, -2, "button");
        if (event.local) |local| {
            pushPosition(self.lua_state, local, event.position.?);
        } else {
            inline for (.{ "x", "y", "window_x", "window_y" }) |field| {
                c.lua_pushnil(self.lua_state);
                c.lua_setfield(self.lua_state, -2, field);
            }
        }
        pushModifiers(self.lua_state, event.modifiers);
        c.lua_setfield(self.lua_state, -2, "modifiers");
        if (c.lua_pcall(self.lua_state, 1, 0, 0) != 0) return failLuaCall(self.lua_state, "tap callback failed");
    }

    fn callScrollEvent(ptr: *anyopaque, event: keywork.ScrollEvent) !void {
        const self: *LuaCallback = @ptrCast(@alignCast(ptr));
        c.lua_rawgeti(self.lua_state, c.LUA_REGISTRYINDEX, self.ref);
        c.lua_createtable(self.lua_state, 0, 7);
        pushPosition(self.lua_state, event.position, event.window_position orelse event.position);
        lua_value.setNumberField(self.lua_state, -1, "dx", event.dx);
        lua_value.setNumberField(self.lua_state, -1, "dy", event.dy);
        pushModifiers(self.lua_state, event.modifiers);
        c.lua_setfield(self.lua_state, -2, "modifiers");
        if (c.lua_pcall(self.lua_state, 1, 0, 0) != 0) return failLuaCall(self.lua_state, "scroll callback failed");
    }

    fn callTextChange(ptr: *anyopaque, text: []const u8) !void {
        const self: *LuaCallback = @ptrCast(@alignCast(ptr));
        c.lua_rawgeti(self.lua_state, c.LUA_REGISTRYINDEX, self.ref);
        c.lua_pushlstring(self.lua_state, text.ptr, text.len);
        if (c.lua_pcall(self.lua_state, 1, 0, 0) != 0) return failLuaCall(self.lua_state, "text change callback failed");
    }

    fn call(ptr: *anyopaque) !void {
        const self: *LuaCallback = @ptrCast(@alignCast(ptr));
        c.lua_rawgeti(self.lua_state, c.LUA_REGISTRYINDEX, self.ref);
        if (c.lua_pcall(self.lua_state, 0, 0, 0) != 0) return failLuaCall(self.lua_state, "callback failed");
    }

    fn callFocusChange(ptr: *anyopaque, focused: bool) !void {
        const self: *LuaCallback = @ptrCast(@alignCast(ptr));
        c.lua_rawgeti(self.lua_state, c.LUA_REGISTRYINDEX, self.ref);
        c.lua_pushboolean(self.lua_state, if (focused) 1 else 0);
        if (c.lua_pcall(self.lua_state, 1, 0, 0) != 0) return failLuaCall(self.lua_state, "focus callback failed");
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
        .rebuild_token = rebuildToken,
        .finish_rebuild = finishRebuild,
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
        errdefer lua_handle.invalidate(self.lua_state, state.slot_ref);
        setStateProps(self.lua_state, state_table, self.props_ref);

        c.lua_rawgeti(self.lua_state, c.LUA_REGISTRYINDEX, self.spec_ref);
        const spec = c.lua_gettop(self.lua_state);
        c.lua_createtable(self.lua_state, 0, 1);
        c.lua_rawgeti(self.lua_state, c.LUA_REGISTRYINDEX, state.slot_ref);
        c.lua_pushvalue(self.lua_state, spec);
        lua_value.setClosureField(self.lua_state, -3, "__index", luaStateIndex, 2);
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
        pushRuntimeStateWithTheme(self.lua_state, context.app_context, self.parse_context);
        if (c.lua_pcall(self.lua_state, 2, 1, 0) != 0) return failLuaCall(self.lua_state, "stateful build failed");
        defer pop(self.lua_state, 1);
        return try parse(self.host.withStateInvalidator(scope.state_invalidator), self.lua_state, scope.allocator, scope.allocator, context.app_context, self.parse_context, -1);
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

        if (state.scope) |state_scope| self.host.disposeScope(state_scope);
        if (state.state_ref >= 0) c.luaL_unref(self.lua_state, c.LUA_REGISTRYINDEX, state.state_ref);
        lua_handle.invalidate(self.lua_state, state.slot_ref);
        allocator.destroy(state);
    }

    fn rebuildToken(state_ptr: *anyopaque, force: bool) ?u64 {
        const state: *LuaStatefulState = @ptrCast(@alignCast(state_ptr));
        if (!force and state.rebuild_generation == state.built_generation) return null;
        return state.rebuild_generation;
    }

    fn finishRebuild(state_ptr: *anyopaque, token: u64) void {
        const state: *LuaStatefulState = @ptrCast(@alignCast(state_ptr));
        state.built_generation = token;
    }

    fn clone(allocator: std.mem.Allocator, ptr: *const anyopaque) !*const anyopaque {
        const self: *LuaStatefulWidget = @ptrCast(@alignCast(@constCast(ptr)));
        if (self.spec_ref < 0 or self.props_ref < 0) return error.LuaStatefulWidgetAlreadyMoved;
        const spec_ref = try cloneRegistryRef(self.lua_state, self.spec_ref);
        errdefer c.luaL_unref(self.lua_state, c.LUA_REGISTRYINDEX, spec_ref);
        const props_ref = try cloneRegistryRef(self.lua_state, self.props_ref);
        errdefer c.luaL_unref(self.lua_state, c.LUA_REGISTRYINDEX, props_ref);
        var parse_context = try self.parse_context.cloneOwned(self.lua_state);
        errdefer parse_context.deinitOwned(self.lua_state);
        c.luaL_unref(self.lua_state, c.LUA_REGISTRYINDEX, self.spec_ref);
        c.luaL_unref(self.lua_state, c.LUA_REGISTRYINDEX, self.props_ref);
        self.parse_context.deinitOwned(self.lua_state);
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
            .parse_context = parse_context,
        };
        return result;
    }

    fn destroy(_: std.mem.Allocator, ptr: *const anyopaque) void {
        const self: *LuaStatefulWidget = @ptrCast(@alignCast(@constCast(ptr)));
        if (self.spec_ref >= 0) c.luaL_unref(self.lua_state, c.LUA_REGISTRYINDEX, self.spec_ref);
        if (self.props_ref >= 0) c.luaL_unref(self.lua_state, c.LUA_REGISTRYINDEX, self.props_ref);
        self.parse_context.deinitOwned(self.lua_state);
        self.allocator.destroy(self);
    }
};

const LuaStatefulState = struct {
    host: Host,
    lua_state: *c.lua_State,
    state_ref: c_int,
    slot_ref: c_int = -1,
    rebuild_generation: u64 = 0,
    built_generation: u64 = 0,
    /// Lazily created on first self.scope access; canceled on dispose.
    scope: ?*lua_task.LuaScope = null,
};

/// Popup content held as a registry ref: either a widget table parsed as-is
/// on every popup build, or a function called with the popup's runtime
/// state that returns one.
const LuaPopupBuilder = struct {
    allocator: std.mem.Allocator,
    host: Host,
    lua_state: *c.lua_State,
    content_ref: c_int,
    parse_context: ParseContext,

    fn popupBuilder(self: *LuaPopupBuilder) keywork.Widget.PopupBuilder {
        return .{
            .ptr = self,
            .build_fn = buildContent,
            .clone_fn = clone,
            .destroy_fn = destroy,
        };
    }

    fn buildContent(ptr: *const anyopaque, scope: *BuildScope, context: keywork.Widget.BuildContext) anyerror!keywork.Widget {
        const self: *const LuaPopupBuilder = @ptrCast(@alignCast(ptr));
        if (self.content_ref < 0) return error.LuaPopupBuilderAlreadyMoved;
        c.lua_rawgeti(self.lua_state, c.LUA_REGISTRYINDEX, self.content_ref);
        if (c.lua_isfunction(self.lua_state, -1)) {
            pushRuntimeStateWithTheme(self.lua_state, context.app_context, self.parse_context);
            if (c.lua_pcall(self.lua_state, 1, 1, 0) != 0) return failLuaCall(self.lua_state, "popup build failed");
        }
        defer pop(self.lua_state, 1);
        return try parse(self.host.withStateInvalidator(scope.state_invalidator), self.lua_state, scope.allocator, scope.allocator, context.app_context, self.parse_context, -1);
    }

    /// Transfers the registry ref like LuaCallback.clone: parse-tree
    /// builders are moved into the element tree, not shared.
    fn clone(allocator: std.mem.Allocator, ptr: *const anyopaque) !*const anyopaque {
        const self: *LuaPopupBuilder = @ptrCast(@alignCast(@constCast(ptr)));
        if (self.content_ref < 0) return error.LuaPopupBuilderAlreadyMoved;
        const content_ref = try cloneRegistryRef(self.lua_state, self.content_ref);
        errdefer c.luaL_unref(self.lua_state, c.LUA_REGISTRYINDEX, content_ref);
        var parse_context = try self.parse_context.cloneOwned(self.lua_state);
        errdefer parse_context.deinitOwned(self.lua_state);
        c.luaL_unref(self.lua_state, c.LUA_REGISTRYINDEX, self.content_ref);
        self.parse_context.deinitOwned(self.lua_state);
        self.content_ref = -2;
        const result = try allocator.create(LuaPopupBuilder);
        result.* = .{
            .allocator = allocator,
            .host = self.host,
            .lua_state = self.lua_state,
            .content_ref = content_ref,
            .parse_context = parse_context,
        };
        return result;
    }

    fn destroy(_: std.mem.Allocator, ptr: *const anyopaque) void {
        const self: *LuaPopupBuilder = @ptrCast(@alignCast(@constCast(ptr)));
        if (self.content_ref >= 0) c.luaL_unref(self.lua_state, c.LUA_REGISTRYINDEX, self.content_ref);
        self.parse_context.deinitOwned(self.lua_state);
        self.allocator.destroy(self);
    }
};

pub fn pushRuntimeState(lua_state: *c.lua_State, state: State) void {
    c.lua_createtable(lua_state, 0, 3);
    const table = c.lua_gettop(lua_state);
    lua_value.setNumberField(lua_state, table, "window_width", state.window_width);
    lua_value.setNumberField(lua_state, table, "window_height", state.window_height);
    lua_value.setStringField(lua_state, table, "color_scheme", state.color_scheme);
}

fn pushRuntimeStateWithTheme(lua_state: *c.lua_State, state: State, parse_context: ParseContext) void {
    pushRuntimeState(lua_state, state);
    if (parse_context.theme_ref < 0) return;
    const table = c.lua_gettop(lua_state);
    c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, parse_context.theme_ref);
    c.lua_setfield(lua_state, table, "theme");
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
) anyerror!keywork.Widget {
    const table = absoluteIndex(lua_state, index);
    try expectType(lua_state, table, c.LUA_TTABLE);

    const kind = try getStringField(lua_state, table, "type");
    defer pop(lua_state, 1);

    if (std.mem.eql(u8, kind, "text")) {
        const value = try dupeStringField(lua_state, allocator, table, "value");
        const options = try lua_codec.decode(TextOptions, lua_state, table, allocator);
        if (options.max_lines == 0) return error.InvalidMaxLines;
        return .{ .text = .{
            .value = value,
            .color = options.color,
            .font_size = options.resolvedFontSize(),
            .line_height = options.line_height,
            .role = options.role orelse .body,
            .max_lines = options.max_lines,
            .overflow = options.overflow orelse .ellipsis,
            .line_break = options.line_break,
        } };
    }
    if (std.mem.eql(u8, kind, "keyed")) {
        const key = try dupeStringField(lua_state, allocator, table, "key");
        const child = try parseChild(host, lua_state, allocator, callback_allocator, runtime_state, parse_context, table);
        return .{ .keyed = .{ .key = .{ .string = key }, .child = child } };
    }
    if (std.mem.eql(u8, kind, "stateful")) {
        const stateful = try allocator.create(LuaStatefulWidget);
        const spec_ref = try tableRefField(lua_state, table, "spec");
        errdefer c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, spec_ref);
        const props_ref = try tableRefField(lua_state, table, "props");
        errdefer c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, props_ref);
        var owned_parse_context = try parse_context.cloneOwned(lua_state);
        errdefer owned_parse_context.deinitOwned(lua_state);
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
            .parse_context = owned_parse_context,
        };
        return stateful.widget();
    }
    if (std.mem.eql(u8, kind, "theme")) {
        const native_theme = lua_theme.parseField(lua_state, table, "theme");
        c.lua_getfield(lua_state, table, "theme");
        const theme_ref = if (c.lua_type(lua_state, -1) == c.LUA_TTABLE)
            c.luaL_ref(lua_state, c.LUA_REGISTRYINDEX)
        else blk: {
            pop(lua_state, 1);
            break :blk -1;
        };
        defer if (theme_ref >= 0) c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, theme_ref);
        var theme_context = parse_context;
        theme_context.theme_ref = theme_ref;
        const child = try parseChild(host, lua_state, allocator, callback_allocator, runtime_state, theme_context, table);
        return .{ .theme = .{ .theme = native_theme, .child = child } };
    }
    if (std.mem.eql(u8, kind, "default_text_style")) {
        const options = try lua_codec.decode(TextOptions, lua_state, table, allocator);
        const child = try parseChild(host, lua_state, allocator, callback_allocator, runtime_state, parse_context, table);
        return .{ .default_text_style = .{ .style = .{
            .color = options.color,
            .font_size = options.resolvedFontSize(),
            .line_height = options.line_height,
        }, .child = child } };
    }
    if (std.mem.eql(u8, kind, "icon_theme")) {
        const options = try lua_codec.decode(IconOptions, lua_state, table, allocator);
        const child = try parseChild(host, lua_state, allocator, callback_allocator, runtime_state, parse_context.mergeIcon(options), table);
        const result = child.*;
        allocator.destroy(child);
        return result;
    }
    if (std.mem.eql(u8, kind, "box")) {
        const options = try lua_codec.decode(BoxOptions, lua_state, table, allocator);
        const child = try parseChild(host, lua_state, allocator, callback_allocator, runtime_state, parse_context, table);
        return .{ .box = .{
            .child = child,
            .background = options.background,
            .border = options.border,
            .border_width = options.border_width,
            .radius = options.radius,
            .shadow = options.shadow,
            .min_width = options.min_width,
            .min_height = options.min_height,
            .horizontal_align = options.horizontalAlign(),
            .vertical_align = options.verticalAlign(),
        } };
    }
    if (std.mem.eql(u8, kind, "gesture")) {
        const options = try lua_codec.decode(GestureOptions, lua_state, table, allocator);
        const id = try dupeStringField(lua_state, allocator, table, "id");
        // Validate buttons before taking any registry refs so an invalid
        // option cannot leak callback refs (see parse's doc comment).
        const buttons = try getPointerButtons(lua_state, table);
        const on_click = try getOptionalTapCallbackField(lua_state, callback_allocator, table, "on_tap");
        errdefer if (on_click) |callback| callback.destroy(callback_allocator);
        const on_tap_down = try getOptionalTapCallbackField(lua_state, callback_allocator, table, "on_tap_down");
        errdefer if (on_tap_down) |callback| callback.destroy(callback_allocator);
        const on_tap_up = try getOptionalTapCallbackField(lua_state, callback_allocator, table, "on_tap_up");
        errdefer if (on_tap_up) |callback| callback.destroy(callback_allocator);
        const on_tap_cancel = try getOptionalTapCallbackField(lua_state, callback_allocator, table, "on_tap_cancel");
        errdefer if (on_tap_cancel) |callback| callback.destroy(callback_allocator);
        const on_scroll = try getOptionalScrollCallbackField(lua_state, callback_allocator, table, "on_scroll");
        errdefer if (on_scroll) |callback| callback.destroy(callback_allocator);
        const on_hover = try getOptionalFocusChangeCallbackField(lua_state, callback_allocator, table, "on_hover");
        errdefer if (on_hover) |callback| callback.destroy(callback_allocator);
        const child = try parseChild(host, lua_state, allocator, callback_allocator, runtime_state, parse_context, table);
        return .{ .clickable = .{
            .id = id,
            .child = child,
            .on_click = on_click,
            .on_tap_down = on_tap_down,
            .on_tap_up = on_tap_up,
            .on_tap_cancel = on_tap_cancel,
            .on_scroll = on_scroll,
            .on_hover_change = on_hover,
            .buttons = buttons,
            .hover_style = options.hoverStyle(),
            .pressed_style = options.pressedStyle(),
            .focused_border = options.focused_border,
            .focused_border_width = options.focused_border_width,
            .cursor = options.cursor,
            .activation = options.activation,
        } };
    }
    if (std.mem.eql(u8, kind, "anchored")) {
        const id = try dupeStringField(lua_state, allocator, table, "id");
        const child = try parseChild(host, lua_state, allocator, callback_allocator, runtime_state, parse_context, table);

        c.lua_getfield(lua_state, table, "popup");
        defer pop(lua_state, 1);
        if (c.lua_isnil(lua_state, -1)) {
            return .{ .anchored = .{ .id = id, .child = child, .popup = null } };
        }
        const popup_table = absoluteIndex(lua_state, -1);
        try expectType(lua_state, popup_table, c.LUA_TTABLE);
        const options = try lua_codec.decode(PopupOptions, lua_state, popup_table, allocator);

        c.lua_getfield(lua_state, popup_table, "content");
        if (c.lua_isnil(lua_state, -1)) {
            pop(lua_state, 1);
            return error.PopupContentMissing;
        }
        const content_ref = c.luaL_ref(lua_state, c.LUA_REGISTRYINDEX);
        errdefer c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, content_ref);
        var owned_parse_context = try parse_context.cloneOwned(lua_state);
        errdefer owned_parse_context.deinitOwned(lua_state);
        const builder = try callback_allocator.create(LuaPopupBuilder);
        builder.* = .{
            .allocator = callback_allocator,
            .host = host,
            .lua_state = lua_state,
            .content_ref = content_ref,
            .parse_context = owned_parse_context,
        };
        const on_close = try getOptionalCallbackField(lua_state, callback_allocator, popup_table, "on_close");

        return .{ .anchored = .{
            .id = id,
            .child = child,
            .popup = .{
                .builder = builder.popupBuilder(),
                .placement = .{ .edge = options.edge, .alignment = options.alignment, .gap = options.gap },
                .shadow = options.shadow,
                .width = options.width,
                .height = options.height,
                .on_close = on_close,
            },
        } };
    }
    if (std.mem.eql(u8, kind, "focus")) {
        const options = try lua_codec.decode(FocusOptions, lua_state, table, allocator);
        const id = try dupeStringField(lua_state, allocator, table, "id");
        const child = try parseChild(host, lua_state, allocator, callback_allocator, runtime_state, parse_context, table);
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
        const child = try parseChild(host, lua_state, allocator, callback_allocator, runtime_state, parse_context, table);
        return .{ .focus_scope = .{ .id = id, .child = child, .modal = options.modal } };
    }
    if (std.mem.eql(u8, kind, "button")) {
        const id = try dupeStringField(lua_state, allocator, table, "id");
        const label = try dupeStringField(lua_state, allocator, table, "label");
        const on_pressed = try getOptionalTapCallbackField(lua_state, callback_allocator, table, "on_pressed");
        const intent = try getOptionalIntentField(lua_state, allocator, table, "action_id");
        return .{ .button = .{ .id = id, .label = label, .on_pressed = on_pressed, .intent = intent } };
    }
    if (std.mem.eql(u8, kind, "text_input")) {
        const id = try dupeStringField(lua_state, allocator, table, "id");
        const placeholder = try dupeStringField(lua_state, allocator, table, "placeholder");
        const value = dupeStringField(lua_state, allocator, table, "value") catch try allocator.dupe(u8, "");
        const on_change = try getOptionalTextChangeCallbackField(lua_state, callback_allocator, table, "on_change");
        const on_submit = try getOptionalTextChangeCallbackField(lua_state, callback_allocator, table, "on_submit");
        var widget = keywork.widgets.textInput(id, value, placeholder);
        const options = try lua_codec.decode(TextInputOptions, lua_state, table, allocator);
        widget.text_input.style = options.style();
        widget.text_input.on_change = on_change;
        widget.text_input.on_submit = on_submit;
        widget.text_input.obscured = options.obscured;
        widget.text_input.clear_on_submit = options.clear_on_submit;
        widget.text_input.autofocus = boolField(lua_state, table, "autofocus");
        return widget;
    }
    if (std.mem.eql(u8, kind, "scroll")) {
        const id = try dupeStringField(lua_state, allocator, table, "id");
        const child = try parseChild(host, lua_state, allocator, callback_allocator, runtime_state, parse_context, table);
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
            selected: ?usize = null,
        };
        const id = try dupeStringField(lua_state, allocator, table, "id");
        const options = try lua_codec.decode(ListOptions, lua_state, table, allocator);
        c.lua_getfield(lua_state, table, "build_item");
        defer pop(lua_state, 1);
        if (c.lua_type(lua_state, -1) != c.LUA_TFUNCTION) return error.ExpectedLuaFunction;
        c.lua_pushvalue(lua_state, -1);
        const ref = c.luaL_ref(lua_state, c.LUA_REGISTRYINDEX);
        errdefer c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, ref);
        var owned_parse_context = try parse_context.cloneOwned(lua_state);
        errdefer owned_parse_context.deinitOwned(lua_state);
        const builder = try callback_allocator.create(LuaItemBuilder);
        builder.* = .{ .allocator = callback_allocator, .host = host, .lua_state = lua_state, .ref = ref, .parse_context = owned_parse_context };
        var list_widget = keywork.widgets.list(id, options.count, options.item_height, builder.itemBuilder());
        // Lua indices are 1-based; 0 or nil means no selection.
        if (options.selected) |selected| {
            if (selected >= 1) list_widget.list.selected = selected - 1;
        }
        return list_widget;
    }
    if (std.mem.eql(u8, kind, "spacer")) {
        const options = try lua_codec.decode(SpacerOptions, lua_state, table, allocator);
        return keywork.widgets.spacer(options.flex);
    }
    if (std.mem.eql(u8, kind, "spinner")) {
        const options = try lua_codec.decode(SpinnerOptions, lua_state, table, allocator);
        return keywork.widgets.spinner(.{
            .size = @max(0, options.size),
            .color = options.color,
            .period_ms = @max(1, options.period_ms),
        });
    }
    if (std.mem.eql(u8, kind, "separator")) {
        const options = try lua_codec.decode(SeparatorOptions, lua_state, table, allocator);
        return .{ .separator = .{
            .color = options.color,
            .thickness = @max(0, options.thickness),
            .axis = options.axis,
            .margin = @max(0, options.margin),
        } };
    }
    if (std.mem.eql(u8, kind, "sized")) {
        const options = try lua_codec.decode(SizedOptions, lua_state, table, allocator);
        const child = try parseChild(host, lua_state, allocator, callback_allocator, runtime_state, parse_context, table);
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
        return try lua_image.parse(lua_state, allocator, parse_context.png_dims, table);
    }
    if (std.mem.eql(u8, kind, "icon")) {
        const options = try lua_codec.decode(IconOptions, lua_state, table, allocator);
        const icon = parse_context.resolveIcon(options);
        const raw_name = try stringField(lua_state, table, "name");
        const fallback_color = icon.color orelse keywork.colors.ink;
        const name = blk: {
            if (isAbsolutePath(raw_name)) {
                // Desktop entries may name absolute icon files: .svg goes
                // to the SVG rasterizer; anything else is probed by stb,
                // which decodes supported rasters regardless of extension.
                if (std.ascii.endsWithIgnoreCase(raw_name, ".svg")) return svg_icon.icon(allocator, raw_name, icon.size, icon.color);
                if (lua_image.pngIcon(allocator, parse_context.png_dims, raw_name, icon.size)) |widget| {
                    return widget;
                } else |err| if (err == error.OutOfMemory) return error.OutOfMemory;
                // Unsupported format (XPM etc.): fall back to a theme
                // lookup by basename, which may find a themed variant.
                break :blk std.fs.path.stem(raw_name);
            }
            // Legacy desktop entries carry a stray extension on theme
            // names ("firefox.png"); the icon-theme spec says to strip
            // known extensions before lookup.
            break :blk stripLegacyIconExtension(raw_name);
        };
        if (name.len == 0) return missingIconWidget(allocator, fallback_color);
        // Select the icon file for the physical pixel size so HiDPI
        // outputs get the sharper large variant; widgets stay logical.
        const lookup_size = icon.size * parse_context.icon_scale;
        if (parse_context.icon_cache) |cache| {
            // The cache owns the path and tombstones misses, so absent
            // icons neither re-walk the theme tree nor warn again.
            const icon_file = try cache.lookupPreferred(name, lookup_size, icon.symbolic) orelse return missingIconWidget(allocator, fallback_color);
            return switch (icon_file.format) {
                .svg => svg_icon.icon(allocator, icon_file.path, icon.size, icon.color),
                .png => pngIconOrMissing(allocator, parse_context, icon_file.path, icon.size, fallback_color),
            };
        }
        const icon_file = try icon_theme.lookupIconSizedPreferred(allocator, name, lookup_size, icon.symbolic) orelse {
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
            .png => pngIconOrMissing(allocator, parse_context, icon_file.path, icon.size, fallback_color),
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
        const child = try parseChild(host, lua_state, allocator, callback_allocator, runtime_state, parse_context, table);
        return .{ .padding = .{ .insets = options.resolved(), .child = child } };
    }
    if (std.mem.eql(u8, kind, "center")) {
        const child = try parseChild(host, lua_state, allocator, callback_allocator, runtime_state, parse_context, table);
        return .{ .center = .{ .child = child } };
    }
    if (std.mem.eql(u8, kind, "flexible")) {
        const options = try lua_codec.decode(FlexibleOptions, lua_state, table, allocator);
        const child = try parseChild(host, lua_state, allocator, callback_allocator, runtime_state, parse_context, table);
        return .{ .flexible = .{ .child = child, .flex = options.flex, .fit = options.fit orelse .tight } };
    }
    if (std.mem.eql(u8, kind, "actions")) {
        const child = try parseChild(host, lua_state, allocator, callback_allocator, runtime_state, parse_context, table);
        const bindings = try parseActionBindings(lua_state, allocator, callback_allocator, table);
        return .{ .actions = .{ .bindings = bindings, .child = child } };
    }
    if (std.mem.eql(u8, kind, "shortcuts")) {
        const child = try parseChild(host, lua_state, allocator, callback_allocator, runtime_state, parse_context, table);
        const bindings = try parseShortcutBindings(lua_state, allocator, table);
        return .{ .shortcuts = .{ .bindings = bindings, .child = child } };
    }

    return error.UnknownWidgetType;
}

fn parseChild(
    host: Host,
    lua_state: *c.lua_State,
    allocator: std.mem.Allocator,
    callback_allocator: std.mem.Allocator,
    runtime_state: State,
    parse_context: ParseContext,
    table: c_int,
) anyerror!*keywork.Widget {
    const child = try allocator.create(keywork.Widget);
    c.lua_getfield(lua_state, table, "child");
    defer pop(lua_state, 1);
    child.* = try parse(host, lua_state, allocator, callback_allocator, runtime_state, parse_context, -1);
    return child;
}

fn isAbsolutePath(name: []const u8) bool {
    return name.len > 0 and name[0] == '/';
}

test "absolute icon paths bypass icon theme lookup" {
    try std.testing.expect(isAbsolutePath("/tmp/icon.png"));
    try std.testing.expect(!isAbsolutePath("document-open"));
    try std.testing.expect(!isAbsolutePath(""));
}

test "symbolic icon preference is explicit and inherited" {
    const context: ParseContext = .{};
    try std.testing.expect(!context.resolveIcon(.{}).symbolic);
    try std.testing.expect(!context.resolveIcon(.{ .color = keywork.colors.ink }).symbolic);
    try std.testing.expect(context.resolveIcon(.{ .symbolic = true }).symbolic);

    const themed = context.mergeIcon(.{ .symbolic = true });
    try std.testing.expect(themed.resolveIcon(.{}).symbolic);
    try std.testing.expect(!themed.resolveIcon(.{ .symbolic = false }).symbolic);
}

test "plain text input defaults are chromeless and explicit values win" {
    const plain: TextInputOptions = .{ .variant = "plain", .padding_x = 3, .border = keywork.colors.ink };
    const style = plain.style();
    try std.testing.expectEqual(keywork.colors.transparent, style.background.?);
    try std.testing.expectEqual(keywork.colors.ink, style.border.?);
    try std.testing.expectEqual(keywork.colors.transparent, style.focused_border.?);
    try std.testing.expectEqual(@as(f32, 3), style.padding_x.?);
    try std.testing.expectEqual(@as(f32, 0), style.padding_y.?);
    try std.testing.expectEqual(@as(f32, 0), style.radius.?);
}

test "gesture buttons parse names and reject invalid values" {
    const lua_state = c.luaL_newstate() orelse return error.OutOfMemory;
    defer c.lua_close(lua_state);

    c.lua_newtable(lua_state);
    const table = c.lua_gettop(lua_state);

    // Absent buttons default to left-only.
    const default_buttons: keywork.PointerButtons = .{};
    try std.testing.expectEqual(default_buttons, try getPointerButtons(lua_state, table));

    // "any" enables every button; other strings are rejected.
    lua_value.setStringField(lua_state, table, "buttons", "any");
    try std.testing.expectEqual(keywork.PointerButtons.any, try getPointerButtons(lua_state, table));
    lua_value.setStringField(lua_state, table, "buttons", "primary");
    try std.testing.expectError(error.InvalidPointerButtons, getPointerButtons(lua_state, table));

    // Arrays of names enable exactly the listed buttons.
    c.lua_newtable(lua_state);
    c.lua_pushstring(lua_state, "right");
    c.lua_rawseti(lua_state, -2, 1);
    c.lua_pushstring(lua_state, "middle");
    c.lua_rawseti(lua_state, -2, 2);
    c.lua_setfield(lua_state, table, "buttons");
    const right_middle: keywork.PointerButtons = .{ .left = false, .right = true, .middle = true };
    try std.testing.expectEqual(right_middle, try getPointerButtons(lua_state, table));

    // Non-string array entries and unknown names are rejected.
    c.lua_newtable(lua_state);
    c.lua_pushinteger(lua_state, 42);
    c.lua_rawseti(lua_state, -2, 1);
    c.lua_setfield(lua_state, table, "buttons");
    try std.testing.expectError(error.InvalidPointerButton, getPointerButtons(lua_state, table));
    c.lua_newtable(lua_state);
    c.lua_pushstring(lua_state, "primary");
    c.lua_rawseti(lua_state, -2, 1);
    c.lua_setfield(lua_state, table, "buttons");
    try std.testing.expectError(error.InvalidPointerButton, getPointerButtons(lua_state, table));

    // Non-table, non-string values are rejected.
    lua_value.setBooleanField(lua_state, table, "buttons", true);
    try std.testing.expectError(error.InvalidPointerButtons, getPointerButtons(lua_state, table));

    // Tap callback fields must hold functions.
    lua_value.setIntegerField(lua_state, table, "on_tap", 7);
    try std.testing.expectError(
        error.ExpectedLuaFunction,
        getOptionalTapCallbackField(lua_state, std.testing.allocator, table, "on_tap"),
    );

    // Every path above must leave the stack balanced.
    try std.testing.expectEqual(table, c.lua_gettop(lua_state));
}

test "gesture activation parses release and defaults to press" {
    const lua_state = c.luaL_newstate() orelse return error.OutOfMemory;
    defer c.lua_close(lua_state);

    c.lua_newtable(lua_state);
    const table = c.lua_gettop(lua_state);

    // Absent activation keeps the press default.
    const defaults = try lua_codec.decode(GestureOptions, lua_state, table, std.testing.allocator);
    try std.testing.expectEqual(keywork.Widget.ClickActivation.press, defaults.activation);

    lua_value.setStringField(lua_state, table, "activation", "release");
    const options = try lua_codec.decode(GestureOptions, lua_state, table, std.testing.allocator);
    try std.testing.expectEqual(keywork.Widget.ClickActivation.release, options.activation);

    // Unknown values are rejected rather than silently defaulted.
    lua_value.setStringField(lua_state, table, "activation", "click");
    try std.testing.expectError(
        error.UnknownLuaEnumValue,
        lua_codec.decode(GestureOptions, lua_state, table, std.testing.allocator),
    );

    // Every path above must leave the stack balanced.
    try std.testing.expectEqual(table, c.lua_gettop(lua_state));
}

test "text line breaking parses Knuth-Plass and defaults to greedy" {
    const lua_state = c.luaL_newstate() orelse return error.OutOfMemory;
    defer c.lua_close(lua_state);

    c.lua_newtable(lua_state);
    const table = c.lua_gettop(lua_state);

    const defaults = try lua_codec.decode(TextOptions, lua_state, table, std.testing.allocator);
    try std.testing.expectEqual(keywork.Widget.LineBreakStrategy.greedy, defaults.line_break);

    lua_value.setStringField(lua_state, table, "line_break", "knuth_plass");
    const options = try lua_codec.decode(TextOptions, lua_state, table, std.testing.allocator);
    try std.testing.expectEqual(keywork.Widget.LineBreakStrategy.knuth_plass, options.line_break);

    lua_value.setStringField(lua_state, table, "line_break", "optimal");
    try std.testing.expectError(
        error.UnknownLuaEnumValue,
        lua_codec.decode(TextOptions, lua_state, table, std.testing.allocator),
    );
    try std.testing.expectEqual(table, c.lua_gettop(lua_state));
}

test "failed gesture parse destroys callbacks it already captured" {
    const TestHost = struct {
        fn invalidate(_: *anyopaque) anyerror!void {}
        fn createScope(_: *anyopaque) anyerror!*lua_task.LuaScope {
            return error.Unsupported;
        }
        fn disposeScope(_: *anyopaque, _: *lua_task.LuaScope) void {}
    };

    const lua_state = c.luaL_newstate() orelse return error.OutOfMemory;
    defer c.lua_close(lua_state);

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var host_ctx: u8 = 0;
    const host: Host = .{
        .ptr = &host_ctx,
        .state_invalidator = .{ .ptr = &host_ctx, .call_fn = TestHost.invalidate },
        .create_scope_fn = TestHost.createScope,
        .dispose_scope_fn = TestHost.disposeScope,
    };

    c.lua_newtable(lua_state);
    const table = c.lua_gettop(lua_state);
    lua_value.setStringField(lua_state, table, "type", "gesture");
    lua_value.setStringField(lua_state, table, "id", "g");
    try std.testing.expectEqual(@as(c_int, 0), c.luaL_loadstring(lua_state, "return 1"));
    c.lua_setfield(lua_state, table, "on_tap");

    // A non-function later callback fails the parse after on_tap was
    // captured; the errdefer chain must release on_tap's registry ref and
    // its wrapper. The testing callback allocator reports a missed destroy.
    lua_value.setIntegerField(lua_state, table, "on_tap_down", 42);
    try std.testing.expectError(
        error.ExpectedLuaFunction,
        parse(host, lua_state, arena.allocator(), std.testing.allocator, .{}, .{}, table),
    );
    try std.testing.expectEqual(table, c.lua_gettop(lua_state));

    // Valid callbacks followed by a malformed child must also unwind both
    // captured callbacks.
    try std.testing.expectEqual(@as(c_int, 0), c.luaL_loadstring(lua_state, "return 1"));
    c.lua_setfield(lua_state, table, "on_tap_down");
    try std.testing.expectError(
        error.UnexpectedLuaType,
        parse(host, lua_state, arena.allocator(), std.testing.allocator, .{}, .{}, table),
    );
    try std.testing.expectEqual(table, c.lua_gettop(lua_state));
}

// Callers log the miss; the cache path warns only once per name+size.
fn missingIconWidget(allocator: std.mem.Allocator, color: keywork.Color) !keywork.Widget {
    return .{ .text = .{ .value = try allocator.dupe(u8, "□"), .color = color } };
}

/// Raster icon or the missing-icon glyph: a broken or oversized file
/// degrades to □ instead of failing the whole widget build. The dims
/// cache warns once per path; only OOM propagates.
fn pngIconOrMissing(
    allocator: std.mem.Allocator,
    parse_context: ParseContext,
    path: []const u8,
    size: f32,
    fallback_color: keywork.Color,
) !keywork.Widget {
    return lua_image.pngIcon(allocator, parse_context.png_dims, path, size) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => missingIconWidget(allocator, fallback_color),
    };
}

/// Legacy desktop entries carry a stray extension on theme names
/// ("firefox.png"); the icon-theme spec says to strip known image
/// extensions before lookup.
fn stripLegacyIconExtension(name: []const u8) []const u8 {
    inline for (.{ ".png", ".svg", ".xpm" }) |ext| {
        if (std.ascii.endsWithIgnoreCase(name, ext)) return name[0 .. name.len - ext.len];
    }
    return name;
}

test "stripLegacyIconExtension strips known image extensions" {
    try std.testing.expectEqualStrings("firefox", stripLegacyIconExtension("firefox.png"));
    try std.testing.expectEqualStrings("firefox", stripLegacyIconExtension("firefox.SVG"));
    try std.testing.expectEqualStrings("firefox", stripLegacyIconExtension("firefox.xpm"));
    try std.testing.expectEqualStrings("firefox", stripLegacyIconExtension("firefox"));
    try std.testing.expectEqualStrings("org.gnome.Maps", stripLegacyIconExtension("org.gnome.Maps"));
    try std.testing.expectEqualStrings("icon.tar", stripLegacyIconExtension("icon.tar"));
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
    if (std.mem.eql(u8, value, "tab")) return .tab;
    if (std.mem.eql(u8, value, "escape")) return .escape;
    if (std.mem.eql(u8, value, "up")) return .up;
    if (std.mem.eql(u8, value, "down")) return .down;
    return error.UnknownShortcutKey;
}

fn installStateMethods(lua_state: *c.lua_State, state: *LuaStatefulState, state_table: c_int) void {
    state.slot_ref = lua_handle.createSlot(lua_state, state);
    lua_value.setClosureField(lua_state, state_table, "set_state", luaSetState, 1);
}

/// __index for stateful widget state tables. Resolves "scope" to the
/// widget's lifecycle scope — created on first access, canceled by the
/// runtime when the widget is disposed — and everything else through the
/// spec table. Upvalues: 1 = state slot, 2 = spec table.
fn luaStateIndex(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    if (c.lua_type(lua_state, 2) == c.LUA_TSTRING) {
        var len: usize = 0;
        const key = c.lua_tolstring(lua_state, 2, &len);
        if (std.mem.eql(u8, key[0..len], "scope")) return pushStateScope(lua_state);
    }
    c.lua_pushvalue(lua_state, 2);
    c.lua_gettable(lua_state, c.lua_upvalueindex(2));
    return 1;
}

fn pushStateScope(lua_state: *c.lua_State) c_int {
    const state = lua_handle.slotResource(LuaStatefulState, lua_state, c.lua_upvalueindex(1)) orelse {
        c.lua_pushnil(lua_state);
        return 1;
    };
    if (state.scope == null) {
        state.scope = state.host.createScope() catch |err| {
            std.log.scoped(.keywork_luajit).warn("widget scope creation failed: {}", .{err});
            return c.luaL_error(lua_state, "widget scope creation failed");
        };
    }
    lua_task.pushScopeHandle(lua_state, state.scope.?);
    // Cache the handle on the state table so later accesses skip __index.
    c.lua_pushvalue(lua_state, 2);
    c.lua_pushvalue(lua_state, -2);
    c.lua_rawset(lua_state, 1);
    return 1;
}

fn setStateProps(lua_state: *c.lua_State, state_table: c_int, props_ref: c_int) void {
    c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, props_ref);
    c.lua_setfield(lua_state, state_table, "props");
}

const failLuaCall = lua_value.failLuaCall;

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

fn getOptionalTapCallbackField(lua_state: *c.lua_State, allocator: std.mem.Allocator, table: c_int, field: [*:0]const u8) !?keywork.Widget.TapCallback {
    c.lua_getfield(lua_state, table, field);
    defer pop(lua_state, 1);
    if (c.lua_isnil(lua_state, -1)) return null;
    const callback = try luaCallbackFromStack(lua_state, allocator, -1);
    return callback.keyworkTapCallback();
}

fn getPointerButtons(lua_state: *c.lua_State, table: c_int) !keywork.PointerButtons {
    c.lua_getfield(lua_state, table, "buttons");
    defer pop(lua_state, 1);
    if (c.lua_isnil(lua_state, -1)) return .{};
    if (c.lua_isstring(lua_state, -1) != 0) {
        if (std.mem.eql(u8, try stringFromStack(lua_state, -1), "any")) return .any;
        return error.InvalidPointerButtons;
    }
    if (!c.lua_istable(lua_state, -1)) return error.InvalidPointerButtons;
    var result: keywork.PointerButtons = .{ .left = false };
    var index: c_int = 1;
    while (true) : (index += 1) {
        c.lua_rawgeti(lua_state, -1, index);
        if (c.lua_isnil(lua_state, -1)) {
            pop(lua_state, 1);
            break;
        }
        if (c.lua_isstring(lua_state, -1) == 0) {
            pop(lua_state, 1);
            return error.InvalidPointerButton;
        }
        const name = try stringFromStack(lua_state, -1);
        if (std.mem.eql(u8, name, "left")) result.left = true else if (std.mem.eql(u8, name, "right")) result.right = true else if (std.mem.eql(u8, name, "middle")) result.middle = true else if (std.mem.eql(u8, name, "back")) result.back = true else if (std.mem.eql(u8, name, "forward")) result.forward = true else {
            pop(lua_state, 1);
            return error.InvalidPointerButton;
        }
        pop(lua_state, 1);
    }
    return result;
}

fn getOptionalScrollCallbackField(lua_state: *c.lua_State, allocator: std.mem.Allocator, table: c_int, field: [*:0]const u8) !?keywork.Widget.ScrollEventCallback {
    c.lua_getfield(lua_state, table, field);
    defer pop(lua_state, 1);
    if (c.lua_isnil(lua_state, -1)) return null;
    const callback = try luaCallbackFromStack(lua_state, allocator, -1);
    return callback.keyworkScrollEventCallback();
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
    // Captured at parse time so deferred row builds keep the icon cache,
    // icon scale, and ambient icon options; without it every row entering
    // the window re-walks the icon theme directories at scale 1.
    parse_context: ParseContext,

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
        if (c.lua_pcall(self.lua_state, 1, 1, 0) != 0) return failLuaCall(self.lua_state, "list item builder failed");
        defer pop(self.lua_state, 1);
        return parse(self.host.withStateInvalidator(scope.state_invalidator), self.lua_state, scope.allocator, scope.allocator, scope.app_context, self.parse_context, -1);
    }

    /// Transfers the registry ref like LuaCallback.clone: parse-tree
    /// originals live in the build arena and are never destroyed, so the
    /// element clone must become the sole owner.
    fn cloneBuilder(allocator: std.mem.Allocator, ptr: *const anyopaque) !*const anyopaque {
        const self: *LuaItemBuilder = @ptrCast(@alignCast(@constCast(ptr)));
        if (self.ref < 0) return error.LuaCallbackAlreadyMoved;
        var parse_context = try self.parse_context.cloneOwned(self.lua_state);
        errdefer parse_context.deinitOwned(self.lua_state);
        const copy = try allocator.create(LuaItemBuilder);
        copy.* = .{ .allocator = allocator, .host = self.host, .lua_state = self.lua_state, .ref = self.ref, .parse_context = parse_context };
        self.parse_context.deinitOwned(self.lua_state);
        self.ref = -2;
        return copy;
    }

    fn destroyBuilder(allocator: std.mem.Allocator, ptr: *const anyopaque) void {
        const self: *LuaItemBuilder = @ptrCast(@alignCast(@constCast(ptr)));
        if (self.ref >= 0) c.luaL_unref(self.lua_state, c.LUA_REGISTRYINDEX, self.ref);
        self.parse_context.deinitOwned(self.lua_state);
        allocator.destroy(self);
    }
};

fn textChangeCallbackFromStack(lua_state: *c.lua_State, allocator: std.mem.Allocator, index: c_int) !keywork.Widget.TextChangeCallback {
    const callback = try luaCallbackFromStack(lua_state, allocator, index);
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
    const callback = try luaCallbackFromStack(lua_state, allocator, index);
    return callback.keyworkCallback();
}

fn luaCallbackFromStack(lua_state: *c.lua_State, allocator: std.mem.Allocator, index: c_int) !*LuaCallback {
    if (c.lua_type(lua_state, index) != c.LUA_TFUNCTION) return error.ExpectedLuaFunction;
    c.lua_pushvalue(lua_state, index);
    const ref = c.luaL_ref(lua_state, c.LUA_REGISTRYINDEX);
    errdefer c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, ref);
    const callback = try allocator.create(LuaCallback);
    callback.* = .{ .allocator = allocator, .lua_state = lua_state, .ref = ref };
    return callback;
}

fn focusChangeCallbackFromStack(lua_state: *c.lua_State, allocator: std.mem.Allocator, index: c_int) !keywork.Widget.FocusChangeCallback {
    const callback = try luaCallbackFromStack(lua_state, allocator, index);
    return callback.keyworkFocusChangeCallback();
}
