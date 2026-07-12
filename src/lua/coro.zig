//! Coroutine spawn and resume primitives for the Lua runtime.
//!
//! Keywork runs asynchronous Lua code OpenResty-style: user code awaits
//! one-shot operations inside coroutines instead of passing callbacks. An
//! awaitable C function refs the running coroutine in the registry, parks
//! it with lua_yield, and the operation's completion resumes it with the
//! results. Coroutines spawned through loop.spawn are anchored by their
//! task until they settle (see task.zig); a bare coroutine parked with no
//! pending resource ref is collected by the GC — and collection never
//! cancels the resource.

const std = @import("std");
const lua_task = @import("task.zig");
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
/// Every park point funnels through here, so a canceled task raises instead
/// of parking again.
pub fn refCurrentThread(lua_state: *c.lua_State) c_int {
    std.debug.assert(!onMainThread(lua_state));
    lua_task.raiseIfCanceled(lua_state);
    _ = c.lua_pushthread(lua_state);
    return c.luaL_ref(lua_state, c.LUA_REGISTRYINDEX);
}

/// Resumes `thread`, which must already hold `nargs` values on its stack.
/// A yielded-again coroutine needs no cleanup here; a finished or failed one
/// settles its task, if any. A failure logs the error unless it is the
/// expected "task canceled" unwinding, matching the callback error policy.
pub fn resumeThread(thread: *c.lua_State, nargs: c_int) void {
    const status = c.lua_resume(thread, nargs);
    if (status == c.LUA_YIELD) return;
    if (status == 0) {
        lua_task.noteThreadFinished(thread, .completed);
        return;
    }
    if (!lua_task.threadCancelExpected(thread)) {
        var len: usize = 0;
        const message_ptr = c.lua_tolstring(thread, -1, &len);
        if (message_ptr) |message| log.warn("coroutine failed: {s}", .{message[0..len]});
    }
    c.lua_settop(thread, 0);
    lua_task.noteThreadFinished(thread, .failed);
}

/// How ending a stream treats a parked reader.
pub const CancelMode = enum {
    /// Drop the reader without resuming; used on bulk teardown, where
    /// re-entering Lua is unsafe.
    silent,
    /// Resume the reader with no value so its iterator terminates; used by
    /// Lua-facing cancel paths.
    resume_reader,
};

/// Resumes the coroutine parked in `reader_ref` with the top `nargs` values
/// of `main_state`'s stack (moved, not copied), then releases the ref.
pub fn resumeReaderWith(main_state: *c.lua_State, reader_ref: *c_int, nargs: c_int) void {
    std.debug.assert(reader_ref.* >= 0);
    const ref = reader_ref.*;
    reader_ref.* = -1;
    c.lua_rawgeti(main_state, c.LUA_REGISTRYINDEX, ref);
    const thread = c.lua_tothread(main_state, -1).?;
    c.lua_settop(main_state, -2);
    c.lua_xmove(main_state, thread, nargs);
    resumeThread(thread, nargs);
    // Unref after the resume: this ref may be the only anchor keeping the
    // coroutine alive while it runs.
    c.luaL_unref(main_state, c.LUA_REGISTRYINDEX, ref);
}

/// An asynchronous event stream: values are delivered to a single parked
/// reader, or queued as registry refs until one asks. Resources expose this
/// to Lua through next()/events() methods on their handle.
pub const Stream = struct {
    reader_ref: c_int = -1,
    queue: std.ArrayList(c_int) = .empty,

    /// Delivers the value on top of `main_state`'s stack to the parked
    /// reader or queues it. Consumes the value even on allocation failure.
    pub fn deliver(self: *Stream, allocator: std.mem.Allocator, main_state: *c.lua_State) !void {
        if (self.reader_ref >= 0) {
            resumeReaderWith(main_state, &self.reader_ref, 1);
            return;
        }
        const ref = c.luaL_ref(main_state, c.LUA_REGISTRYINDEX);
        errdefer c.luaL_unref(main_state, c.LUA_REGISTRYINDEX, ref);
        try self.queue.append(allocator, ref);
    }

    /// Implements the body of a stream's next() method: returns a queued
    /// value, ends the iteration (nil) when `ended` says no more values can
    /// arrive, or parks the calling coroutine.
    pub fn awaitNext(self: *Stream, lua_state: *c.lua_State, ended: bool) c_int {
        if (self.queue.items.len > 0) {
            const ref = self.queue.orderedRemove(0);
            c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, ref);
            c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, ref);
            return 1;
        }
        if (ended) return 0;
        if (onMainThread(lua_state)) return c.luaL_error(lua_state, "next must be called from a coroutine (wrap the caller in loop.spawn)");
        if (self.reader_ref >= 0) return c.luaL_error(lua_state, "stream already has a waiting reader");
        self.reader_ref = refCurrentThread(lua_state);
        return c.lua_yield(lua_state, 0);
    }

    /// Marks the natural end of the stream (EOF): finishes a parked reader
    /// according to `mode` but keeps queued values readable, so consumers
    /// can drain what was delivered before the end. The resource's `ended`
    /// flag passed to awaitNext terminates iteration after the queue empties.
    pub fn finish(self: *Stream, main_state: *c.lua_State, mode: CancelMode) void {
        if (self.reader_ref < 0) return;
        // A parked reader implies an empty queue: deliver would have resumed
        // it instead of queueing.
        std.debug.assert(self.queue.items.len == 0);
        self.releaseReader(main_state, mode);
    }

    /// Ends the stream: drops queued values and finishes a parked reader
    /// according to `mode`. Idempotent.
    pub fn cancel(self: *Stream, allocator: std.mem.Allocator, main_state: *c.lua_State, mode: CancelMode) void {
        for (self.queue.items) |ref| c.luaL_unref(main_state, c.LUA_REGISTRYINDEX, ref);
        self.queue.deinit(allocator);
        self.queue = .empty;
        if (self.reader_ref < 0) return;
        self.releaseReader(main_state, mode);
    }

    fn releaseReader(self: *Stream, main_state: *c.lua_State, mode: CancelMode) void {
        std.debug.assert(self.reader_ref >= 0);
        switch (mode) {
            .resume_reader => resumeReaderWith(main_state, &self.reader_ref, 0),
            .silent => {
                c.luaL_unref(main_state, c.LUA_REGISTRYINDEX, self.reader_ref);
                self.reader_ref = -1;
            },
        }
    }
};

/// Pushes the values of a `for v in handle:events()` iterator: the next
/// function and the handle at stack index 1, so the generic for calls
/// next(handle) directly each iteration (which keeps yields legal).
pub fn pushIterator(lua_state: *c.lua_State, next_fn: c.lua_CFunction) c_int {
    c.lua_pushcclosure(lua_state, next_fn, 0);
    c.lua_pushvalue(lua_state, 1);
    return 2;
}
