//! Coroutine spawn and resume primitives for the Lua runtime.
//!
//! Keywork runs asynchronous Lua code OpenResty-style: user code awaits
//! one-shot operations inside coroutines instead of passing callbacks. An
//! awaitable C function refs the running coroutine in the registry, parks
//! it with lua_yield, and the operation's completion resumes it with the
//! results. While parked, the pending resource's registry ref is the only
//! thing anchoring the coroutine, so a coroutine nobody will resume is
//! collected by the GC — and collection never cancels the resource.

const std = @import("std");
const c = @import("luajit_c");

const log = std.log.scoped(.keywork_luajit);

/// Whether `lua_state` is the main state rather than a coroutine. The main
/// state cannot yield, so awaitables raise a Lua error when called on it.
pub fn onMainThread(lua_state: *c.lua_State) bool {
    const is_main = c.lua_pushthread(lua_state) != 0;
    c.lua_settop(lua_state, -2);
    return is_main;
}

/// Refs the running coroutine in the registry so a completion can resume it
/// later. The caller must arm its completion and then return `lua_yield`.
pub fn refCurrentThread(lua_state: *c.lua_State) c_int {
    std.debug.assert(!onMainThread(lua_state));
    _ = c.lua_pushthread(lua_state);
    return c.luaL_ref(lua_state, c.LUA_REGISTRYINDEX);
}

/// Resumes `thread`, which must already hold `nargs` values on its stack.
/// A finished or yielded-again coroutine needs no cleanup here; a failed one
/// logs the error and is left empty, matching the callback error policy.
pub fn resumeThread(thread: *c.lua_State, nargs: c_int) void {
    const status = c.lua_resume(thread, nargs);
    if (status == 0 or status == c.LUA_YIELD) return;
    var len: usize = 0;
    const message_ptr = c.lua_tolstring(thread, -1, &len);
    if (message_ptr) |message| log.warn("coroutine failed: {s}", .{message[0..len]});
    c.lua_settop(thread, 0);
}

/// Implements loop.spawn(fn, ...): runs `fn` on a fresh coroutine until it
/// first yields or finishes, and returns the coroutine so callers can
/// inspect it (and later wait on or cancel it).
pub fn luaSpawn(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    c.luaL_checktype(lua_state, 1, c.LUA_TFUNCTION);
    const nargs = c.lua_gettop(lua_state) - 1;
    const thread = c.lua_newthread(lua_state).?;
    c.lua_insert(lua_state, 1);
    c.lua_xmove(lua_state, thread, nargs + 1);
    resumeThread(thread, nargs);
    return 1;
}

fn runScript(lua_state: *c.lua_State, script: [*:0]const u8) !void {
    if (c.luaL_loadstring(lua_state, script) != 0) return error.LoadFailed;
    if (c.lua_pcall(lua_state, 0, 0, 0) != 0) {
        var len: usize = 0;
        const message_ptr = c.lua_tolstring(lua_state, -1, &len);
        if (message_ptr) |message| std.debug.print("script failed: {s}\n", .{message[0..len]});
        return error.ScriptFailed;
    }
}

fn testState() !*c.lua_State {
    const lua_state = c.luaL_newstate() orelse return error.OutOfMemory;
    c.luaL_openlibs(lua_state);
    c.lua_pushcclosure(lua_state, luaSpawn, 0);
    c.lua_setglobal(lua_state, "spawn");
    return lua_state;
}

test "spawn runs the function immediately with its arguments" {
    const lua_state = try testState();
    defer c.lua_close(lua_state);
    try runScript(lua_state,
        \\local t = spawn(function(a, b) sum = a + b end, 40, 2)
        \\assert(sum == 42)
        \\assert(coroutine.status(t) == "dead")
    );
}

test "spawn logs a failing coroutine and returns it dead" {
    const lua_state = try testState();
    defer c.lua_close(lua_state);
    try runScript(lua_state,
        \\local t = spawn(function() error("boom") end)
        \\assert(coroutine.status(t) == "dead")
    );
}

test "a suspended coroutine with no resumer is collectible" {
    const lua_state = try testState();
    defer c.lua_close(lua_state);
    try runScript(lua_state,
        \\local t = spawn(function() coroutine.yield() end)
        \\assert(coroutine.status(t) == "suspended")
        \\t = nil
        \\collectgarbage("collect")
    );
}
