//! Embedded LuaJIT virtual machine: state lifecycle and chunk execution.

const Vm = @This();

const std = @import("std");
const c = @import("lua_c");

state: *c.lua_State,

pub const Error = error{
    OutOfMemory,
    LuaSyntax,
    LuaFile,
    LuaRuntime,
};

pub fn init() error{OutOfMemory}!Vm {
    // LuaJIT on 64-bit targets requires its own allocator, so the state
    // cannot borrow a Zig allocator.
    const state = c.luaL_newstate() orelse return error.OutOfMemory;
    c.luaL_openlibs(state);
    return .{ .state = state };
}

pub fn deinit(self: *Vm) void {
    c.lua_close(self.state);
}

/// Loads and runs a Lua file. On failure the error message stays on the
/// stack; read it with `lastError` before the next VM call.
pub fn runFile(self: *Vm, path: [:0]const u8) Error!void {
    try self.checkLoad(c.luaL_loadfilex(self.state, path.ptr, null));
    try self.protectedCall(0, 0);
}

/// Loads and runs a Lua chunk from a string.
pub fn runString(self: *Vm, chunk: [:0]const u8) Error!void {
    try self.checkLoad(c.luaL_loadstring(self.state, chunk.ptr));
    try self.protectedCall(0, 0);
}

/// The message at the top of the stack, valid until the next VM call.
pub fn lastError(self: *Vm) []const u8 {
    var len: usize = 0;
    const ptr = c.lua_tolstring(self.state, -1, &len) orelse return "unknown error";
    return ptr[0..len];
}

fn checkLoad(self: *Vm, status: c_int) Error!void {
    _ = self;
    switch (status) {
        0 => {},
        c.LUA_ERRSYNTAX => return error.LuaSyntax,
        c.LUA_ERRMEM => return error.OutOfMemory,
        c.LUA_ERRFILE => return error.LuaFile,
        else => return error.LuaRuntime,
    }
}

fn protectedCall(self: *Vm, nargs: c_int, nresults: c_int) Error!void {
    switch (c.lua_pcall(self.state, nargs, nresults, 0)) {
        0 => {},
        c.LUA_ERRMEM => return error.OutOfMemory,
        else => return error.LuaRuntime,
    }
}

test "vm runs a chunk and exposes results through globals" {
    var vm = try Vm.init();
    defer vm.deinit();
    try vm.runString("answer = 21 * 2");
    c.lua_getfield(vm.state, c.LUA_GLOBALSINDEX, "answer");
    try std.testing.expectEqual(@as(f64, 42), c.lua_tonumber(vm.state, -1));
    c.lua_settop(vm.state, 0);
}

test "vm surfaces lua errors with their message" {
    var vm = try Vm.init();
    defer vm.deinit();
    try std.testing.expectError(error.LuaRuntime, vm.runString("error('boom')"));
    try std.testing.expect(std.mem.endsWith(u8, vm.lastError(), "boom"));
    try std.testing.expectError(error.LuaSyntax, vm.runString("not lua ("));
}

test "jit compiler is enabled" {
    var vm = try Vm.init();
    defer vm.deinit();
    try vm.runString("jit_on = jit.status()");
    c.lua_getfield(vm.state, c.LUA_GLOBALSINDEX, "jit_on");
    try std.testing.expect(c.lua_toboolean(vm.state, -1) != 0);
    c.lua_settop(vm.state, 0);
}
