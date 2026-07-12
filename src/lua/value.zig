//! Shared Lua stack and value helpers.

const std = @import("std");
const c = @import("luajit_c");

pub fn absoluteIndex(lua_state: *c.lua_State, index: c_int) c_int {
    if (index > 0 or index <= c.LUA_REGISTRYINDEX) return index;
    return c.lua_gettop(lua_state) + index + 1;
}

pub fn expectType(lua_state: *c.lua_State, index: c_int, expected: c_int) !void {
    if (c.lua_type(lua_state, index) != expected) return error.UnexpectedLuaType;
}

/// Pushes the requested field and leaves it on the stack.
pub fn getStringField(lua_state: *c.lua_State, table: c_int, key: [*:0]const u8) ![]const u8 {
    c.lua_getfield(lua_state, table, key);
    return stringFromStack(lua_state, -1);
}

pub fn dupeStringField(lua_state: *c.lua_State, allocator: std.mem.Allocator, table: c_int, key: [*:0]const u8) ![]const u8 {
    const result = try stringField(lua_state, table, key);
    return allocator.dupe(u8, result);
}

pub fn stringField(lua_state: *c.lua_State, table: c_int, key: [*:0]const u8) ![]const u8 {
    const result = try getStringField(lua_state, table, key);
    defer pop(lua_state, 1);
    return result;
}

pub fn boolField(lua_state: *c.lua_State, table: c_int, key: [*:0]const u8) bool {
    c.lua_getfield(lua_state, table, key);
    defer pop(lua_state, 1);
    return c.lua_toboolean(lua_state, -1) != 0;
}

pub fn tableRefField(lua_state: *c.lua_State, table: c_int, key: [*:0]const u8) !c_int {
    c.lua_getfield(lua_state, table, key);
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) {
        pop(lua_state, 1);
        return error.ExpectedLuaTable;
    }
    return c.luaL_ref(lua_state, c.LUA_REGISTRYINDEX);
}

pub fn cloneRegistryRef(lua_state: *c.lua_State, ref: c_int) !c_int {
    if (ref < 0) return error.InvalidLuaRegistryRef;
    c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, ref);
    return c.luaL_ref(lua_state, c.LUA_REGISTRYINDEX);
}

pub fn stringFromStack(lua_state: *c.lua_State, index: c_int) ![]const u8 {
    var len: usize = 0;
    const ptr = c.lua_tolstring(lua_state, index, &len) orelse return error.ExpectedLuaString;
    return ptr[0..len];
}

pub fn checkString(lua_state: *c.lua_State, index: c_int) []const u8 {
    var len: usize = 0;
    const ptr = c.luaL_checklstring(lua_state, index, &len);
    return ptr[0..len];
}

pub fn dupeStringFromStack(lua_state: *c.lua_State, allocator: std.mem.Allocator, index: c_int) ![]const u8 {
    return allocator.dupe(u8, try stringFromStack(lua_state, index));
}

pub fn pop(lua_state: *c.lua_State, count: c_int) void {
    c.lua_settop(lua_state, -count - 1);
}

pub fn pushNilError(lua_state: *c.lua_State, err: anyerror) c_int {
    c.lua_pushnil(lua_state);
    const name = @errorName(err);
    c.lua_pushlstring(lua_state, name.ptr, name.len);
    return 2;
}

/// Logs and pops the Lua error at the top of the stack, then returns
/// error.LuaCallbackFailed for the caller to propagate.
pub fn failLuaCall(lua_state: *c.lua_State, err: []const u8) anyerror {
    var len: usize = 0;
    const message_ptr = c.lua_tolstring(lua_state, -1, &len);
    if (message_ptr) |message| std.log.scoped(.keywork_luajit).warn("{s}: {s}", .{ err, message[0..len] });
    pop(lua_state, 1);
    return error.LuaCallbackFailed;
}
