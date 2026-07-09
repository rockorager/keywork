//! Backpressured fd writes for Lua stream resources.
//!
//! The write-side counterpart of lua_coro.Stream: bytes the kernel does not
//! accept immediately are buffered while the writing coroutine parks, and
//! the owning resource's event callback flushes the buffer and resumes the
//! writer once the fd turns writable. Resources expose this to Lua through
//! a write(data) method that returns true on completion or nil, err.

const std = @import("std");
const lua_coro = @import("coro.zig");
const c = @import("luajit_c");

const linux = std.os.linux;

pub const WriteError = error{ PeerClosed, WriteFailed };

/// The nil, err string reported to Lua for a failed write. A closed peer
/// reports "closed", matching what writes on an already-dead handle return.
pub fn errorName(err: WriteError) []const u8 {
    return switch (err) {
        error.PeerClosed => "closed",
        error.WriteFailed => "WriteFailed",
    };
}

/// Writes as much of `data` to `fd` as the kernel accepts right now.
/// Returns the number of bytes written (short on EAGAIN).
pub fn writeNow(fd: i32, data: []const u8) WriteError!usize {
    var offset: usize = 0;
    while (offset < data.len) {
        const result = linux.write(fd, data.ptr + offset, data.len - offset);
        switch (linux.errno(result)) {
            .SUCCESS => offset += result,
            .AGAIN => break,
            .INTR => continue,
            .PIPE, .CONNRESET => return error.PeerClosed,
            else => return error.WriteFailed,
        }
    }
    return offset;
}

pub const Sink = struct {
    /// Bytes accepted by write() but not yet flushed to the kernel.
    /// Non-empty only while a writer coroutine is parked (or during
    /// teardown, before clear drops them).
    buffer: std.ArrayList(u8) = .empty,
    /// Coroutine parked in write() awaiting the flush, if any.
    writer_ref: c_int = -1,

    pub fn hasWaiter(self: *const Sink) bool {
        return self.writer_ref >= 0;
    }

    pub fn hasPending(self: *const Sink) bool {
        return self.buffer.items.len > 0;
    }

    /// Flushes buffered bytes to `fd`; true when the buffer drained.
    pub fn flush(self: *Sink, fd: i32) WriteError!bool {
        const written = try writeNow(fd, self.buffer.items);
        self.buffer.replaceRangeAssumeCapacity(0, written, &.{});
        return self.buffer.items.len == 0;
    }

    /// Buffers the unwritten remainder and parks the calling coroutine
    /// until resolve() or fail(). Returns the value the Lua entrypoint must
    /// return; the yield takes effect on that return, so the caller may
    /// still update fd interests in between.
    pub fn park(self: *Sink, allocator: std.mem.Allocator, lua_state: *c.lua_State, remainder: []const u8) !c_int {
        std.debug.assert(!lua_coro.onMainThread(lua_state));
        std.debug.assert(self.writer_ref < 0);
        try self.buffer.appendSlice(allocator, remainder);
        self.writer_ref = lua_coro.refCurrentThread(lua_state);
        return c.lua_yield(lua_state, 0);
    }

    /// Resumes a parked writer with `true` (flush complete).
    pub fn resolve(self: *Sink, lua_state: *c.lua_State) void {
        if (self.writer_ref < 0) return;
        c.lua_pushboolean(lua_state, 1);
        lua_coro.resumeReaderWith(lua_state, &self.writer_ref, 1);
    }

    /// Resumes a parked writer with nil, err (or drops it silently).
    pub fn fail(self: *Sink, lua_state: *c.lua_State, mode: lua_coro.CancelMode, err: []const u8) void {
        if (self.writer_ref < 0) return;
        switch (mode) {
            .resume_reader => {
                c.lua_pushnil(lua_state);
                c.lua_pushlstring(lua_state, err.ptr, err.len);
                lua_coro.resumeReaderWith(lua_state, &self.writer_ref, 2);
            },
            .silent => {
                c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, self.writer_ref);
                self.writer_ref = -1;
            },
        }
    }

    /// Drops unflushed bytes without touching a parked writer.
    pub fn clear(self: *Sink, allocator: std.mem.Allocator) void {
        self.buffer.deinit(allocator);
        self.buffer = .empty;
    }
};
