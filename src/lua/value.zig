//! Shared Lua stack and value helpers.

const std = @import("std");
const c = @import("luajit_c");

pub fn absoluteIndex(lua_state: *c.lua_State, index: c_int) c_int {
    if (index > 0 or index <= c.LUA_REGISTRYINDEX) return index;
    return c.lua_gettop(lua_state) + index + 1;
}

pub fn upvaluePointer(comptime Pointer: type, lua_state: *c.lua_State, slot: c_int) Pointer {
    const ptr = c.lua_touserdata(lua_state, c.lua_upvalueindex(slot)).?;
    return @ptrCast(@alignCast(ptr));
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

pub fn setStringField(lua_state: *c.lua_State, table: c_int, key: [*:0]const u8, value: []const u8) void {
    const absolute_table = absoluteIndex(lua_state, table);
    c.lua_pushlstring(lua_state, value.ptr, value.len);
    c.lua_setfield(lua_state, absolute_table, key);
}

pub fn setIntegerField(lua_state: *c.lua_State, table: c_int, key: [*:0]const u8, value: c.lua_Integer) void {
    const absolute_table = absoluteIndex(lua_state, table);
    c.lua_pushinteger(lua_state, value);
    c.lua_setfield(lua_state, absolute_table, key);
}

pub fn setNumberField(lua_state: *c.lua_State, table: c_int, key: [*:0]const u8, value: c.lua_Number) void {
    const absolute_table = absoluteIndex(lua_state, table);
    c.lua_pushnumber(lua_state, value);
    c.lua_setfield(lua_state, absolute_table, key);
}

pub fn setBooleanField(lua_state: *c.lua_State, table: c_int, key: [*:0]const u8, value: bool) void {
    const absolute_table = absoluteIndex(lua_state, table);
    c.lua_pushboolean(lua_state, @intFromBool(value));
    c.lua_setfield(lua_state, absolute_table, key);
}

pub fn setClosureField(lua_state: *c.lua_State, table: c_int, key: [*:0]const u8, function: c.lua_CFunction, upvalue_count: c_int) void {
    const absolute_table = absoluteIndex(lua_state, table);
    c.lua_pushcclosure(lua_state, function, upvalue_count);
    c.lua_setfield(lua_state, absolute_table, key);
}

pub fn dupeStringFromStack(lua_state: *c.lua_State, allocator: std.mem.Allocator, index: c_int) ![]const u8 {
    return allocator.dupe(u8, try stringFromStack(lua_state, index));
}

pub fn pop(lua_state: *c.lua_State, count: c_int) void {
    c.lua_settop(lua_state, -count - 1);
}

pub fn pushNilMessage(lua_state: *c.lua_State, message: []const u8) c_int {
    c.lua_pushnil(lua_state);
    c.lua_pushlstring(lua_state, message.ptr, message.len);
    return 2;
}

pub fn pushNilError(lua_state: *c.lua_State, err: anyerror) c_int {
    return pushNilMessage(lua_state, @errorName(err));
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
