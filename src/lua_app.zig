//! LuaJIT-backed widget descriptions.

const std = @import("std");
const keywork = @import("root");
const c = @import("luajit_c");

const linux = std.os.linux;

const State = keywork.Runtime.State;

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
    c.lua_getfield(lua_state, c.LUA_GLOBALSINDEX, "package");
    const package_table = c.lua_gettop(lua_state);
    c.lua_getfield(lua_state, package_table, "preload");
    const preload_table = c.lua_gettop(lua_state);
    c.lua_pushcclosure(lua_state, luaOpenUi, 0);
    c.lua_setfield(lua_state, preload_table, "ui");
    pop(lua_state, 2);
}

fn luaOpenUi(optional_state: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = optional_state.?;
    pushUiTable(lua_state);
    return 1;
}

fn pushUiTable(lua_state: *c.lua_State) void {
    c.lua_createtable(lua_state, 0, 6);
    const table = c.lua_gettop(lua_state);
    setFunction(lua_state, table, "text", luaText);
    setFunction(lua_state, table, "button", luaButton);
    setFunction(lua_state, table, "text_input", luaTextInput);
    setFunction(lua_state, table, "column", luaColumn);
    setFunction(lua_state, table, "padding", luaPadding);
    setFunction(lua_state, table, "center", luaCenter);
}

fn setFunction(lua_state: *c.lua_State, table: c_int, name: [*:0]const u8, function: c.lua_CFunction) void {
    c.lua_pushcclosure(lua_state, function, 0);
    c.lua_setfield(lua_state, table, name);
}

fn luaText(optional_state: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = optional_state.?;
    var len: usize = 0;
    const value = c.luaL_checklstring(lua_state, 1, &len);
    c.lua_createtable(lua_state, 0, 2);
    const table = c.lua_gettop(lua_state);
    setStringField(lua_state, table, "type", "text");
    c.lua_pushlstring(lua_state, value, len);
    c.lua_setfield(lua_state, table, "value");
    return 1;
}

fn luaButton(optional_state: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = optional_state.?;
    var id_len: usize = 0;
    var label_len: usize = 0;
    const id = c.luaL_checklstring(lua_state, 1, &id_len);
    const label = c.luaL_checklstring(lua_state, 2, &label_len);
    c.lua_createtable(lua_state, 0, 3);
    const table = c.lua_gettop(lua_state);
    setStringField(lua_state, table, "type", "button");
    c.lua_pushlstring(lua_state, id, id_len);
    c.lua_setfield(lua_state, table, "id");
    c.lua_pushlstring(lua_state, label, label_len);
    c.lua_setfield(lua_state, table, "label");
    return 1;
}

fn luaTextInput(optional_state: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = optional_state.?;
    var id_len: usize = 0;
    var placeholder_len: usize = 0;
    const id = c.luaL_checklstring(lua_state, 1, &id_len);
    const placeholder = c.luaL_checklstring(lua_state, 2, &placeholder_len);
    c.lua_createtable(lua_state, 0, 3);
    const table = c.lua_gettop(lua_state);
    setStringField(lua_state, table, "type", "text_input");
    c.lua_pushlstring(lua_state, id, id_len);
    c.lua_setfield(lua_state, table, "id");
    c.lua_pushlstring(lua_state, placeholder, placeholder_len);
    c.lua_setfield(lua_state, table, "placeholder");
    return 1;
}

fn luaColumn(optional_state: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = optional_state.?;
    c.luaL_checktype(lua_state, 1, c.LUA_TTABLE);
    c.lua_createtable(lua_state, 0, 3);
    const table = c.lua_gettop(lua_state);
    setStringField(lua_state, table, "type", "column");
    c.lua_pushvalue(lua_state, 1);
    c.lua_setfield(lua_state, table, "children");
    c.lua_pushnumber(lua_state, if (c.lua_isnumber(lua_state, 2) != 0) c.lua_tonumber(lua_state, 2) else 0);
    c.lua_setfield(lua_state, table, "gap");
    return 1;
}

fn luaPadding(optional_state: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = optional_state.?;
    c.luaL_checktype(lua_state, 2, c.LUA_TTABLE);
    c.lua_createtable(lua_state, 0, 3);
    const table = c.lua_gettop(lua_state);
    setStringField(lua_state, table, "type", "padding");
    c.lua_pushnumber(lua_state, c.luaL_checknumber(lua_state, 1));
    c.lua_setfield(lua_state, table, "insets");
    c.lua_pushvalue(lua_state, 2);
    c.lua_setfield(lua_state, table, "child");
    return 1;
}

fn luaCenter(optional_state: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = optional_state.?;
    c.luaL_checktype(lua_state, 1, c.LUA_TTABLE);
    c.lua_createtable(lua_state, 0, 2);
    const table = c.lua_gettop(lua_state);
    setStringField(lua_state, table, "type", "center");
    c.lua_pushvalue(lua_state, 1);
    c.lua_setfield(lua_state, table, "child");
    return 1;
}

fn setStringField(lua_state: *c.lua_State, table: c_int, key: [*:0]const u8, value: [*:0]const u8) void {
    c.lua_pushstring(lua_state, value);
    c.lua_setfield(lua_state, table, key);
}

fn pushRuntimeState(lua_state: *c.lua_State, state: State) void {
    c.lua_createtable(lua_state, 0, 4);
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
}

fn parseWidget(lua_state: *c.lua_State, allocator: std.mem.Allocator, runtime_state: State, index: c_int) !keywork.Widget {
    const table = absoluteIndex(lua_state, index);
    try expectType(lua_state, table, c.LUA_TTABLE);

    const kind = try getStringField(lua_state, table, "type");
    defer pop(lua_state, 1);

    if (std.mem.eql(u8, kind, "text")) {
        const value = try dupeStringField(lua_state, allocator, table, "value");
        return .{ .text = .{ .value = value } };
    }
    if (std.mem.eql(u8, kind, "button")) {
        const id = try dupeStringField(lua_state, allocator, table, "id");
        const label = try dupeStringField(lua_state, allocator, table, "label");
        return .{ .button = .{ .id = id, .label = label } };
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

fn pop(lua_state: *c.lua_State, count: c_int) void {
    c.lua_settop(lua_state, -count - 1);
}
