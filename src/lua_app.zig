//! LuaJIT-backed widget descriptions.

const std = @import("std");
const keywork = @import("libkeywork");
const c = @import("luajit_c");

const linux = std.os.linux;

const State = keywork.AppContext;
const BuildScope = keywork.BuildScope;

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

        return try parseWidget(self.state, allocator, runtime_state, -1);
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
    c.lua_createtable(lua_state, 0, 7);
    const table = c.lua_gettop(lua_state);
    c.lua_pushboolean(lua_state, if (state.button_pressed) 1 else 0);
    c.lua_setfield(lua_state, table, "button_pressed");
    c.lua_pushboolean(lua_state, if (state.pulse) 1 else 0);
    c.lua_setfield(lua_state, table, "pulse");
    c.lua_pushlstring(lua_state, state.input_text.ptr, state.input_text.len);
    c.lua_setfield(lua_state, table, "input_text");
    if (state.focused_input_id) |id| {
        c.lua_pushlstring(lua_state, id.ptr, id.len);
    } else {
        c.lua_pushnil(lua_state);
    }
    c.lua_setfield(lua_state, table, "focused_input_id");
    c.lua_pushnumber(lua_state, state.window_width);
    c.lua_setfield(lua_state, table, "window_width");
    c.lua_pushnumber(lua_state, state.window_height);
    c.lua_setfield(lua_state, table, "window_height");
    c.lua_pushlstring(lua_state, state.color_scheme.ptr, state.color_scheme.len);
    c.lua_setfield(lua_state, table, "color_scheme");
}

fn parseWidget(lua_state: *c.lua_State, allocator: std.mem.Allocator, runtime_state: State, index: c_int) !keywork.Widget {
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
        child.* = try parseWidget(lua_state, allocator, runtime_state, -1);
        return .{ .keyed = .{ .key = .{ .string = key }, .child = child } };
    }
    if (std.mem.eql(u8, kind, "box")) {
        const child = try allocator.create(keywork.Widget);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parseWidget(lua_state, allocator, runtime_state, -1);
        return .{ .box = .{
            .child = child,
            .background = getColorField(lua_state, table, "background", keywork.colors.transparent),
        } };
    }
    if (std.mem.eql(u8, kind, "clickable")) {
        const id = try dupeStringField(lua_state, allocator, table, "id");
        const child = try allocator.create(keywork.Widget);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parseWidget(lua_state, allocator, runtime_state, -1);
        return .{ .clickable = .{ .id = id, .child = child } };
    }
    if (std.mem.eql(u8, kind, "button")) {
        const id = try dupeStringField(lua_state, allocator, table, "id");
        const label = try dupeStringField(lua_state, allocator, table, "label");
        const pressed = getBooleanField(lua_state, table, "pressed", false);
        return keywork.widgets.button(allocator, id, label, pressed);
    }
    if (std.mem.eql(u8, kind, "text_input")) {
        const id = try dupeStringField(lua_state, allocator, table, "id");
        const placeholder = try dupeStringField(lua_state, allocator, table, "placeholder");
        const value = try allocator.dupe(u8, runtime_state.input_text);
        const focused = if (runtime_state.focused_input_id) |focused_id| std.mem.eql(u8, focused_id, id) else false;
        return .{ .text_input = .{ .id = id, .value = value, .placeholder = placeholder, .focused = focused } };
    }
    if (std.mem.eql(u8, kind, "column")) {
        c.lua_getfield(lua_state, table, "children");
        defer pop(lua_state, 1);
        const children_table = absoluteIndex(lua_state, -1);
        try expectType(lua_state, children_table, c.LUA_TTABLE);
        const count: usize = @intCast(c.lua_objlen(lua_state, children_table));
        const children = try allocator.alloc(keywork.Widget, count);
        for (children, 0..) |*child, child_index| {
            c.lua_rawgeti(lua_state, children_table, @intCast(child_index + 1));
            defer pop(lua_state, 1);
            child.* = try parseWidget(lua_state, allocator, runtime_state, -1);
        }
        return .{ .column = .{ .children = children, .gap = getNumberField(lua_state, table, "gap", 0) } };
    }
    if (std.mem.eql(u8, kind, "padding")) {
        const child = try allocator.create(keywork.Widget);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parseWidget(lua_state, allocator, runtime_state, -1);
        const inset = getNumberField(lua_state, table, "insets", 0);
        return .{ .padding = .{ .insets = keywork.EdgeInsets.all(inset), .child = child } };
    }
    if (std.mem.eql(u8, kind, "center")) {
        const child = try allocator.create(keywork.Widget);
        c.lua_getfield(lua_state, table, "child");
        defer pop(lua_state, 1);
        child.* = try parseWidget(lua_state, allocator, runtime_state, -1);
        return .{ .center = .{ .child = child } };
    }

    return error.UnknownWidgetType;
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
    var len: usize = 0;
    const ptr = c.lua_tolstring(lua_state, -1, &len) orelse return error.ExpectedLuaString;
    return ptr[0..len];
}

fn dupeStringField(lua_state: *c.lua_State, allocator: std.mem.Allocator, table: c_int, key: [*:0]const u8) ![]const u8 {
    const value = try getStringField(lua_state, table, key);
    defer pop(lua_state, 1);
    return try allocator.dupe(u8, value);
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
