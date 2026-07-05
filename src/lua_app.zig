//! LuaJIT-backed widget descriptions.

const std = @import("std");
const keywork = @import("libkeywork");
const c = @import("luajit_c");

const linux = std.os.linux;

const State = keywork.AppContext;
const BuildScope = keywork.BuildScope;

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

pub const App = struct {
    allocator: std.mem.Allocator,
    path: [:0]u8,
    state: *c.lua_State,

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
        c.lua_close(self.state);
        self.allocator.free(self.path);
    }

    pub fn host(self: *App) keywork.AppHost {
        return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidgetHost } };
    }

    pub fn buildWidget(self: *App, allocator: std.mem.Allocator, runtime_state: State) !keywork.Widget {
        c.lua_settop(self.state, 0);
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
};

fn installUi(lua_state: *c.lua_State) void {
    addPackagePath(lua_state, "src/?.lua");
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
        return .{ .clickable = .{ .id = id, .child = child, .on_click = on_click } };
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
