//! Lifetime-safe Lua handles for keywork resources.
//!
//! A handle is a full userdata holding a single resource-pointer slot, with a
//! shared per-type metatable providing colon-call methods. The owning Zig
//! resource keeps the registry ref returned by `create` and calls
//! `invalidate` when it dies (cancel, close, or teardown). Methods on a dead
//! handle observe a null slot and become no-ops instead of touching freed
//! memory. Handles never own the resource: dropping one to the GC does not
//! cancel anything.

const std = @import("std");
const c = @import("luajit_c");

pub const Method = struct {
    name: [*:0]const u8,
    func: c.lua_CFunction,
};

/// Pushes a new handle userdata for `resource` and returns a registry ref
/// that the resource must keep for later invalidation. The handle is left on
/// the stack as the caller's return value.
pub fn create(lua_state: *c.lua_State, type_name: [*:0]const u8, methods: []const Method, resource_ptr: *anyopaque) c_int {
    const slot: *?*anyopaque = @ptrCast(@alignCast(c.lua_newuserdata(lua_state, @sizeOf(?*anyopaque)).?));
    slot.* = resource_ptr;
    if (c.luaL_newmetatable(lua_state, type_name) != 0) {
        c.lua_createtable(lua_state, 0, @intCast(methods.len));
        for (methods) |method| {
            c.lua_pushcclosure(lua_state, method.func, 0);
            c.lua_setfield(lua_state, -2, method.name);
        }
        c.lua_setfield(lua_state, -2, "__index");
    }
    _ = c.lua_setmetatable(lua_state, -2);
    c.lua_pushvalue(lua_state, -1);
    return c.luaL_ref(lua_state, c.LUA_REGISTRYINDEX);
}

/// Nulls the handle's resource slot and drops the registry ref. Safe to call
/// with a negative ref, so owners can invalidate unconditionally.
pub fn invalidate(lua_state: *c.lua_State, ref: c_int) void {
    if (ref < 0) return;
    c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, ref);
    if (c.lua_touserdata(lua_state, -1)) |ptr| {
        const slot: *?*anyopaque = @ptrCast(@alignCast(ptr));
        slot.* = null;
    }
    c.lua_settop(lua_state, -2);
    c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, ref);
}

/// Returns the resource behind the handle at `index`, or null when the handle
/// has been invalidated (callers no-op). Raises a Lua error for values that
/// are not a `type_name` handle, so it must run before any allocation or ref
/// is taken in the calling C function.
pub fn resource(comptime T: type, lua_state: *c.lua_State, index: c_int, type_name: [*:0]const u8) ?*T {
    const ptr = c.luaL_checkudata(lua_state, index, type_name).?;
    const slot: *?*anyopaque = @ptrCast(@alignCast(ptr));
    const value = slot.* orelse return null;
    return @ptrCast(@alignCast(value));
}
