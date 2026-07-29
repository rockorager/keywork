//! Embedded Lua test framework and result decoding.

const std = @import("std");
const lua_value = @import("value.zig");
const c = @import("luajit_c");

const embedded_source = @embedFile("testing.lua");
const pop = lua_value.pop;

pub const Status = enum {
    pass,
    fail,
    error_status,
    skip,
};

pub const Result = struct {
    name: []u8,
    status: Status,
    message: ?[]u8 = null,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.message) |message| allocator.free(message);
        self.* = undefined;
    }
};

pub fn moduleLoader(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    if (c.luaL_loadbuffer(lua_state, embedded_source.ptr, embedded_source.len, "@keywork/testing.lua") != 0) {
        return c.lua_error(lua_state);
    }
    if (c.lua_pcall(lua_state, 0, 1, 0) != 0) return c.lua_error(lua_state);
    return 1;
}

/// Runs the cases registered by the loaded test file. Returned strings are
/// allocator-owned and remain valid after the Lua VM is destroyed.
pub fn run(lua_state: *c.lua_State, allocator: std.mem.Allocator, filter: ?[]const u8) ![]Result {
    const initial_top = c.lua_gettop(lua_state);
    defer c.lua_settop(lua_state, initial_top);

    c.lua_getglobal(lua_state, "require");
    c.lua_pushliteral(lua_state, "keywork.test");
    if (c.lua_pcall(lua_state, 1, 1, 0) != 0) return error.TestModuleLoadFailed;
    const module = c.lua_gettop(lua_state);
    c.lua_getfield(lua_state, module, "_run");
    if (c.lua_type(lua_state, -1) != c.LUA_TFUNCTION) return error.TestRunMissing;
    if (filter) |value| {
        c.lua_pushlstring(lua_state, value.ptr, value.len);
    } else {
        c.lua_pushnil(lua_state);
    }
    if (c.lua_pcall(lua_state, 1, 1, 0) != 0) return error.TestRunFailed;
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return error.InvalidTestResults;

    const result_table = c.lua_gettop(lua_state);
    const count: usize = @intCast(c.lua_objlen(lua_state, result_table));
    var results: std.ArrayList(Result) = .empty;
    errdefer {
        for (results.items) |*result| result.deinit(allocator);
        results.deinit(allocator);
    }
    try results.ensureTotalCapacity(allocator, count);

    for (1..count + 1) |index| {
        c.lua_rawgeti(lua_state, result_table, @intCast(index));
        defer pop(lua_state, 1);
        if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return error.InvalidTestResult;
        var result = try parseResult(lua_state, allocator, c.lua_gettop(lua_state));
        errdefer result.deinit(allocator);
        results.appendAssumeCapacity(result);
    }
    return results.toOwnedSlice(allocator);
}

pub fn deinitResults(allocator: std.mem.Allocator, results: []Result) void {
    for (results) |*result| result.deinit(allocator);
    allocator.free(results);
}

fn parseResult(lua_state: *c.lua_State, allocator: std.mem.Allocator, table: c_int) !Result {
    const name = try dupeRequiredStringField(lua_state, allocator, table, "name");
    errdefer allocator.free(name);
    const status_name = try requiredStringField(lua_state, table, "status");
    const status: Status = if (std.mem.eql(u8, status_name, "pass"))
        .pass
    else if (std.mem.eql(u8, status_name, "fail"))
        .fail
    else if (std.mem.eql(u8, status_name, "error"))
        .error_status
    else if (std.mem.eql(u8, status_name, "skip"))
        .skip
    else
        return error.InvalidTestStatus;
    const message = try dupeOptionalStringField(lua_state, allocator, table, "message");
    return .{ .name = name, .status = status, .message = message };
}

fn requiredStringField(lua_state: *c.lua_State, table: c_int, key: [*:0]const u8) ![]const u8 {
    c.lua_getfield(lua_state, table, key);
    defer pop(lua_state, 1);
    return lua_value.stringFromStack(lua_state, -1) catch return error.InvalidTestResult;
}

fn dupeRequiredStringField(lua_state: *c.lua_State, allocator: std.mem.Allocator, table: c_int, key: [*:0]const u8) ![]u8 {
    return allocator.dupe(u8, try requiredStringField(lua_state, table, key));
}

fn dupeOptionalStringField(lua_state: *c.lua_State, allocator: std.mem.Allocator, table: c_int, key: [*:0]const u8) !?[]u8 {
    c.lua_getfield(lua_state, table, key);
    defer pop(lua_state, 1);
    if (c.lua_isnil(lua_state, -1)) return null;
    const value = lua_value.stringFromStack(lua_state, -1) catch return error.InvalidTestResult;
    const result = try allocator.dupe(u8, value);
    return result;
}
