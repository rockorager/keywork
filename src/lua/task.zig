//! Lifecycle-scoped tasks and scopes for the Lua runtime.
//!
//! loop.spawn runs a function on a fresh coroutine and returns a task
//! handle instead of the raw coroutine. A task owns the async resources
//! created while its coroutine runs (ambient ownership): cancelling the
//! task cancels those resources, wakes a parked await with an end-of-
//! stream, and makes any further await or resource creation on that
//! coroutine raise "task canceled" so it unwinds instead of parking
//! forever. Cancellation is cooperative — a coroutine is never killed
//! mid-execution.
//!
//! Scopes group tasks: scope:spawn adds a task to the scope, and tasks
//! spawned from inside a scoped task inherit the scope, so cancelling the
//! scope cancels the whole tree of work it started. Stateful widgets get a
//! lazily-created scope (self.scope) that the runtime cancels when the
//! widget is disposed.

const std = @import("std");
const lua_coro = @import("coro.zig");
const lua_handle = @import("handle.zig");
const lua_loop = @import("loop.zig");
const lua_value = @import("value.zig");
const c = @import("luajit_c");

const log = std.log.scoped(.keywork_luajit);

pub const Status = enum {
    running,
    completed,
    failed,
    canceled,
};

/// Type-erased cancel hook for a task-owned resource. Resource structs are
/// only freed at app teardown, so the pointer stays valid for the task's
/// whole life.
pub const Cancelable = struct {
    ptr: *anyopaque,
    cancel_fn: *const fn (*anyopaque, *c.lua_State, lua_coro.CancelMode) void,
};

pub const LuaTask = struct {
    allocator: std.mem.Allocator,
    /// The coroutine running the task body; null once settled.
    thread: ?*c.lua_State,
    /// Registry ref anchoring the coroutine for the task's lifetime, so a
    /// live task is inspectable and cancelable even while parked.
    thread_ref: c_int,
    handle_ref: c_int = -1,
    scope: ?*LuaScope = null,
    status: Status = .running,
    /// Set by cancel; makes further awaits on this task's coroutine raise.
    cancel_requested: bool = false,
    /// Coroutines parked in task:join(), resumed with the final status.
    joiner_refs: std.ArrayList(c_int) = .empty,
    /// Async resources created while this task's coroutine ran.
    resources: std.ArrayList(Cancelable) = .empty,

    pub fn done(self: *const LuaTask) bool {
        return self.status != .running;
    }

    /// The status reported to Lua: a cancel request shows as "canceled"
    /// immediately, even while the coroutine is still unwinding.
    pub fn statusName(self: *const LuaTask) []const u8 {
        if (self.status == .running and self.cancel_requested) return "canceled";
        return @tagName(self.status);
    }

    /// Cooperative cancellation: cancels owned resources — waking a parked
    /// await with an end-of-stream — and marks the task so further awaits
    /// raise. Cancelling an already-settled task still cancels resources
    /// that outlived it.
    pub fn requestCancel(self: *LuaTask, lua_state: *c.lua_State, mode: lua_coro.CancelMode) void {
        self.cancel_requested = true;
        self.cancelResources(lua_state, mode);
        // Bulk teardown never resumes the coroutine, so settle here to drop
        // the anchoring refs and let the GC collect it.
        if (mode == .silent) self.settle(lua_state, .canceled, .silent);
    }

    /// Bulk teardown (reload/deinit): cancel silently and kill the handle.
    pub fn cancel(self: *LuaTask, lua_state: *c.lua_State, mode: lua_coro.CancelMode) void {
        self.requestCancel(lua_state, mode);
        if (mode == .silent) {
            lua_handle.invalidate(lua_state, self.handle_ref);
            self.handle_ref = -1;
        }
    }

    pub fn destroy(self: *LuaTask, allocator: std.mem.Allocator, lua_state: *c.lua_State) void {
        self.cancel(lua_state, .silent);
        self.resources.deinit(allocator);
        self.joiner_refs.deinit(allocator);
        allocator.destroy(self);
    }

    fn cancelResources(self: *LuaTask, lua_state: *c.lua_State, mode: lua_coro.CancelMode) void {
        // Pop before cancelling: a cancel can resume this task's coroutine,
        // which may settle the task and re-enter this list.
        while (self.resources.pop()) |entry| entry.cancel_fn(entry.ptr, lua_state, mode);
    }

    /// Records the terminal state, releases the coroutine, and resumes
    /// joiners with the status name. Idempotent.
    fn settle(self: *LuaTask, lua_state: *c.lua_State, status: Status, mode: lua_coro.CancelMode) void {
        if (self.done()) return;
        self.status = if (self.cancel_requested) .canceled else status;
        if (self.thread) |thread| removeThreadEntry(lua_state, thread);
        self.thread = null;
        if (self.thread_ref >= 0) {
            c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, self.thread_ref);
            self.thread_ref = -1;
        }
        while (self.joiner_refs.pop()) |ref| {
            var reader_ref = ref;
            switch (mode) {
                .resume_reader => {
                    const name = self.statusName();
                    c.lua_pushlstring(lua_state, name.ptr, name.len);
                    lua_coro.resumeReaderWith(lua_state, &reader_ref, 1);
                },
                .silent => c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, reader_ref),
            }
        }
    }
};

pub const LuaScope = struct {
    host: lua_loop.Host,
    handle_ref: c_int = -1,
    canceled: bool = false,
    tasks: std.ArrayList(*LuaTask) = .empty,
    /// Lua callbacks registered via scope:on_cancel, run on interactive
    /// cancel so Lua code can release resources tied to the scope's life.
    cancel_refs: std.ArrayList(c_int) = .empty,

    pub fn cancel(self: *LuaScope, lua_state: *c.lua_State, mode: lua_coro.CancelMode) void {
        self.canceled = true;
        // Pop before cancelling: an unwinding member may spawn into the
        // scope while we drain (its own cancel then raises on await).
        while (self.tasks.pop()) |task| task.requestCancel(lua_state, mode);
        // Callbacks run after members settle, so cleanup observes a fully
        // canceled scope. Bulk teardown never re-enters Lua, so the refs
        // are simply dropped.
        while (self.cancel_refs.pop()) |ref| {
            switch (mode) {
                .resume_reader => {
                    c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, ref);
                    c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, ref);
                    callCancelCallback(lua_state);
                },
                .silent => c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, ref),
            }
        }
        if (mode == .silent) {
            lua_handle.invalidate(lua_state, self.handle_ref);
            self.handle_ref = -1;
        }
    }

    pub fn destroy(self: *LuaScope, allocator: std.mem.Allocator, lua_state: *c.lua_State) void {
        self.cancel(lua_state, .silent);
        self.tasks.deinit(allocator);
        self.cancel_refs.deinit(allocator);
        allocator.destroy(self);
    }
};

/// Calls the function on top of the stack, logging instead of propagating
/// failures: one broken cleanup callback must not stop the rest.
fn callCancelCallback(lua_state: *c.lua_State) void {
    if (c.lua_pcall(lua_state, 0, 0, 0) != 0) {
        var len: usize = 0;
        const message = c.lua_tolstring(lua_state, -1, &len);
        if (message) |text| log.warn("scope on_cancel callback failed: {s}", .{text[0..len]});
        c.lua_settop(lua_state, -2);
    }
}

/// Registry table mapping live task coroutines to their LuaTask pointer
/// (lightuserdata). Entries are removed when a task settles, so the map
/// never keeps a finished coroutine alive.
const thread_map_key = "keywork.task.threads";

fn pushThreadMap(lua_state: *c.lua_State) void {
    c.lua_getfield(lua_state, c.LUA_REGISTRYINDEX, thread_map_key);
    if (c.lua_istable(lua_state, -1)) return;
    c.lua_settop(lua_state, -2);
    c.lua_createtable(lua_state, 0, 4);
    c.lua_pushvalue(lua_state, -1);
    c.lua_setfield(lua_state, c.LUA_REGISTRYINDEX, thread_map_key);
}

fn registerThread(lua_state: *c.lua_State, thread_index: c_int, task: *LuaTask) void {
    std.debug.assert(thread_index > 0);
    pushThreadMap(lua_state);
    c.lua_pushvalue(lua_state, thread_index);
    c.lua_pushlightuserdata(lua_state, task);
    c.lua_rawset(lua_state, -3);
    c.lua_settop(lua_state, -2);
}

fn removeThreadEntry(lua_state: *c.lua_State, thread: *c.lua_State) void {
    pushThreadMap(lua_state);
    if (thread == lua_state) {
        _ = c.lua_pushthread(lua_state);
    } else {
        _ = c.lua_pushthread(thread);
        c.lua_xmove(thread, lua_state, 1);
    }
    c.lua_pushnil(lua_state);
    c.lua_rawset(lua_state, -3);
    c.lua_settop(lua_state, -2);
}

/// The task whose coroutine is `lua_state`, or null for the main state and
/// coroutines not spawned through loop.spawn.
pub fn currentTask(lua_state: *c.lua_State) ?*LuaTask {
    pushThreadMap(lua_state);
    _ = c.lua_pushthread(lua_state);
    c.lua_rawget(lua_state, -2);
    const ptr = c.lua_touserdata(lua_state, -1);
    c.lua_settop(lua_state, -3);
    const found = ptr orelse return null;
    return @ptrCast(@alignCast(found));
}

/// Raises when the calling coroutine's task has been canceled, so an
/// unwinding task can neither park nor create new resources.
pub fn raiseIfCanceled(lua_state: *c.lua_State) void {
    const task = currentTask(lua_state) orelse return;
    if (!task.cancel_requested) return;
    _ = c.luaL_error(lua_state, "task canceled");
    unreachable;
}

/// Hook called by resumeThread when a task coroutine finishes or fails.
pub fn noteThreadFinished(thread: *c.lua_State, status: Status) void {
    const task = currentTask(thread) orelse return;
    // The dead coroutine's stack is valid staging space for registry work.
    task.settle(thread, status, .resume_reader);
}

/// Whether a failed coroutine belongs to a canceled task, whose "task
/// canceled" error is expected unwinding rather than a script bug.
pub fn threadCancelExpected(thread: *c.lua_State) bool {
    const task = currentTask(thread) orelse return false;
    return task.cancel_requested;
}

/// Registers `entry` with the calling coroutine's task, if any, so task or
/// scope cancellation cancels the resource. Resources created on the main
/// thread stay app-owned only.
pub fn adopt(lua_state: *c.lua_State, entry: Cancelable) void {
    const task = currentTask(lua_state) orelse return;
    task.resources.append(task.allocator, entry) catch |err| {
        log.warn("task resource adoption failed: {}", .{err});
    };
}

/// adopt() for resources with the standard cancel(lua_state, mode) shape.
pub fn adoptResource(comptime T: type, lua_state: *c.lua_State, resource: *T) void {
    adopt(lua_state, .{
        .ptr = resource,
        .cancel_fn = struct {
            fn cancel(ptr: *anyopaque, state: *c.lua_State, mode: lua_coro.CancelMode) void {
                const typed: *T = @ptrCast(@alignCast(ptr));
                typed.cancel(state, mode);
            }
        }.cancel,
    });
}

const task_type: [*:0]const u8 = "keywork.task";
const task_methods = [_]lua_handle.Method{
    .{ .name = "status", .func = luaTaskStatus },
    .{ .name = "join", .func = luaTaskJoin },
    .{ .name = "cancel", .func = luaTaskCancel },
};

const scope_type: [*:0]const u8 = "keywork.scope";
const scope_methods = [_]lua_handle.Method{
    .{ .name = "spawn", .func = luaScopeSpawn },
    .{ .name = "cancel", .func = luaScopeCancel },
    .{ .name = "canceled", .func = luaScopeCanceled },
    .{ .name = "on_cancel", .func = luaScopeOnCancel },
};

fn pushTaskHandle(lua_state: *c.lua_State, task: *LuaTask) void {
    task.handle_ref = lua_handle.create(lua_state, task_type, &task_methods, task);
}

/// Pushes the scope's handle, creating it on first use so scopes made from
/// Zig (widget scopes) materialize a handle only when Lua sees them.
pub fn pushScopeHandle(lua_state: *c.lua_State, scope: *LuaScope) void {
    if (scope.handle_ref >= 0) {
        c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, scope.handle_ref);
        return;
    }
    scope.handle_ref = lua_handle.create(lua_state, scope_type, &scope_methods, scope);
}

fn hostFromLua(lua_state: *c.lua_State) lua_loop.Host {
    return lua_value.upvaluePointer(*lua_loop.Host, lua_state, 1).*;
}

/// Implements loop.spawn(fn, ...): runs `fn` on a fresh coroutine until it
/// first yields or finishes, and returns a task handle. A task spawned from
/// inside a scoped task inherits the scope.
pub fn luaSpawn(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const host = hostFromLua(lua_state);
    const inherited: ?*LuaScope = if (currentTask(lua_state)) |task| task.scope else null;
    return spawnTask(lua_state, host, inherited, 1);
}

/// Implements loop.scope(): creates an empty scope for grouping tasks.
pub fn luaScope(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const host = hostFromLua(lua_state);
    raiseIfCanceled(lua_state);
    const scope = host.addScope() catch |err| {
        log.warn("loop.scope failed: {}", .{err});
        return c.luaL_error(lua_state, "loop.scope failed");
    };
    pushScopeHandle(lua_state, scope);
    return 1;
}

fn spawnTask(lua_state: *c.lua_State, host: lua_loop.Host, scope: ?*LuaScope, fn_index: c_int) c_int {
    c.luaL_checktype(lua_state, fn_index, c.LUA_TFUNCTION);
    raiseIfCanceled(lua_state);

    const nargs = c.lua_gettop(lua_state) - fn_index;
    const thread = c.lua_newthread(lua_state).?;
    c.lua_pushvalue(lua_state, -1);
    const thread_ref = c.luaL_ref(lua_state, c.LUA_REGISTRYINDEX);
    const task = host.addTask(thread, thread_ref) catch |err| {
        c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, thread_ref);
        log.warn("loop.spawn failed: {}", .{err});
        return c.luaL_error(lua_state, "loop.spawn failed");
    };
    task.scope = scope;
    if (scope) |live_scope| live_scope.tasks.append(host.allocator(), task) catch |err| {
        log.warn("scope task tracking failed: {}", .{err});
    };
    registerThread(lua_state, c.lua_gettop(lua_state), task);

    // Leave the thread parked at fn_index and move fn+args onto it.
    c.lua_insert(lua_state, fn_index);
    c.lua_xmove(lua_state, thread, nargs + 1);
    pushTaskHandle(lua_state, task);
    lua_coro.resumeThread(thread, nargs);
    return 1;
}

fn luaTaskStatus(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    // A dead handle means the owning script load was torn down.
    const task = lua_handle.resource(LuaTask, lua_state, 1, task_type) orelse {
        c.lua_pushliteral(lua_state, "canceled");
        return 1;
    };
    const name = task.statusName();
    c.lua_pushlstring(lua_state, name.ptr, name.len);
    return 1;
}

fn luaTaskCancel(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const task = lua_handle.resource(LuaTask, lua_state, 1, task_type) orelse return 0;
    task.requestCancel(lua_state, .resume_reader);
    return 0;
}

/// task:join() parks the calling coroutine until the task settles and
/// returns the final status name. Joining a settled task returns at once,
/// so it is legal from the main state.
fn luaTaskJoin(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const task = lua_handle.resource(LuaTask, lua_state, 1, task_type) orelse {
        c.lua_pushliteral(lua_state, "canceled");
        return 1;
    };
    if (task.done()) {
        const name = task.statusName();
        c.lua_pushlstring(lua_state, name.ptr, name.len);
        return 1;
    }
    if (lua_coro.onMainThread(lua_state)) return c.luaL_error(lua_state, "join must be called from a coroutine (wrap the caller in loop.spawn)");
    if (currentTask(lua_state) == task) return c.luaL_error(lua_state, "task cannot join itself");
    const ref = lua_coro.refCurrentThread(lua_state);
    task.joiner_refs.append(task.allocator, ref) catch {
        c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, ref);
        return c.luaL_error(lua_state, "join failed");
    };
    return c.lua_yield(lua_state, 0);
}

fn luaScopeSpawn(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const scope = lua_handle.resource(LuaScope, lua_state, 1, scope_type) orelse return c.luaL_error(lua_state, "scope canceled");
    if (scope.canceled) return c.luaL_error(lua_state, "scope canceled");
    return spawnTask(lua_state, scope.host, scope, 2);
}

fn luaScopeCancel(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const scope = lua_handle.resource(LuaScope, lua_state, 1, scope_type) orelse return 0;
    scope.cancel(lua_state, .resume_reader);
    return 0;
}

/// scope:on_cancel(fn) runs `fn` once when the scope is canceled
/// interactively. Registering on an already-canceled scope runs the
/// callback immediately, so cleanup never silently fails to happen; a
/// scope torn down in bulk (dead handle) drops the callback because
/// everything it would release dies with the load anyway.
fn luaScopeOnCancel(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    c.luaL_checktype(lua_state, 2, c.LUA_TFUNCTION);
    const scope = lua_handle.resource(LuaScope, lua_state, 1, scope_type) orelse return 0;
    if (scope.canceled) {
        c.lua_pushvalue(lua_state, 2);
        callCancelCallback(lua_state);
        return 0;
    }
    c.lua_pushvalue(lua_state, 2);
    const ref = c.luaL_ref(lua_state, c.LUA_REGISTRYINDEX);
    scope.cancel_refs.append(scope.host.allocator(), ref) catch {
        c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, ref);
        return c.luaL_error(lua_state, "on_cancel failed");
    };
    return 0;
}

fn luaScopeCanceled(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const scope = lua_handle.resource(LuaScope, lua_state, 1, scope_type) orelse {
        c.lua_pushboolean(lua_state, 1);
        return 1;
    };
    c.lua_pushboolean(lua_state, if (scope.canceled) 1 else 0);
    return 1;
}
