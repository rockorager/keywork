//! Lua unix domain stream sockets for keywork.loop.connect.

const std = @import("std");
const event_loop = @import("../linux/event_loop.zig");
const linux_syscall = @import("../linux/syscall.zig");
const lua_coro = @import("coro.zig");
const lua_handle = @import("handle.zig");
const lua_task = @import("task.zig");
const lua_sink = @import("sink.zig");
const lua_value = @import("value.zig");
const c = @import("luajit_c");

const linux = std.os.linux;
const log = std.log.scoped(.keywork_luajit);

const invalid_fd: i32 = -1;

pub const Host = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        allocator: *const fn (*anyopaque) std.mem.Allocator,
        luaState: *const fn (*anyopaque) *c.lua_State,
        eventLoop: *const fn (*anyopaque) ?*event_loop.EventLoop,
        addSocket: *const fn (*anyopaque, i32) anyerror!*LuaSocket,
    };

    fn allocator(self: Host) std.mem.Allocator {
        return self.vtable.allocator(self.ptr);
    }

    fn luaState(self: Host) *c.lua_State {
        return self.vtable.luaState(self.ptr);
    }

    fn eventLoop(self: Host) ?*event_loop.EventLoop {
        return self.vtable.eventLoop(self.ptr);
    }

    fn addSocket(self: Host, fd: i32) !*LuaSocket {
        return try self.vtable.addSocket(self.ptr, fd);
    }
};

pub const LuaSocket = struct {
    host: Host,
    fd: i32,
    /// Incoming chunks: queued while no reader is parked, like process pipes.
    stream: lua_coro.Stream = .{},
    /// Outgoing bytes under backpressure, with the parked writer coroutine.
    sink: lua_sink.Sink = .{},
    handle_ref: c_int = -1,
    source_handle: ?event_loop.EventLoop.SourceHandle = null,
    registered: bool = false,
    canceled: bool = false,

    pub fn connect(path: []const u8) !i32 {
        var address: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = undefined };
        if (path.len == 0 or path.len >= address.path.len) return error.PathTooLong;
        @memset(&address.path, 0);
        @memcpy(address.path[0..path.len], path);

        const fd = try linux_syscall.fd(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
        errdefer _ = linux.close(fd);
        // A blocking connect: unix sockets connect locally and immediately,
        // so async connect plumbing would buy nothing.
        const address_len: linux.socklen_t = @intCast(@offsetOf(linux.sockaddr.un, "path") + path.len + 1);
        while (true) {
            switch (linux.errno(linux.connect(fd, @ptrCast(&address), address_len))) {
                .SUCCESS, .ISCONN => break,
                .INTR => continue,
                .NOENT => return error.FileNotFound,
                .CONNREFUSED => return error.ConnectionRefused,
                .ACCES, .PERM => return error.AccessDenied,
                .AGAIN => return error.WouldBlock,
                else => return error.ConnectFailed,
            }
        }
        try linux_syscall.setNonblocking(fd);
        return fd;
    }

    pub fn register(self: *LuaSocket) !void {
        if (self.registered or self.canceled or self.fd == invalid_fd) return;
        const loop = self.host.eventLoop() orelse return;
        self.source_handle = try loop.addFd(.{
            .fd = self.fd,
            .events = self.wantedEvents(),
            .ctx = self,
            .callback = socketCallback,
        });
        self.registered = true;
    }

    pub fn unregister(self: *LuaSocket, loop: *event_loop.EventLoop) void {
        if (self.source_handle) |handle| loop.removeSource(handle);
        self.source_handle = null;
        self.registered = false;
    }

    fn wantedEvents(self: *const LuaSocket) u32 {
        var events: u32 = linux.EPOLL.IN | linux.EPOLL.HUP | linux.EPOLL.ERR;
        if (self.sink.hasPending()) events |= linux.EPOLL.OUT;
        return events;
    }

    fn updateInterests(self: *LuaSocket) void {
        if (!self.registered) return;
        const loop = self.host.eventLoop() orelse return;
        if (self.source_handle) |handle| loop.modifySource(handle, self.wantedEvents());
    }

    /// Unregisters and closes the fd and drops unflushed write bytes,
    /// without touching parked coroutines.
    fn closeFd(self: *LuaSocket) void {
        if (self.fd == invalid_fd) return;
        if (self.registered) {
            if (self.host.eventLoop()) |loop| self.unregister(loop);
        }
        _ = linux.close(self.fd);
        self.fd = invalid_fd;
        self.sink.clear(self.host.allocator());
    }

    /// Ends both directions on EOF or a socket error: the read stream
    /// finishes (queued chunks stay readable) and a parked writer fails
    /// with nil, "closed".
    fn shutdownFd(self: *LuaSocket, lua_state: *c.lua_State, mode: lua_coro.CancelMode) void {
        if (self.fd == invalid_fd) return;
        self.closeFd();
        self.sink.fail(lua_state, mode, "closed");
        self.stream.finish(lua_state, mode);
    }

    pub fn cancel(self: *LuaSocket, lua_state: *c.lua_State, mode: lua_coro.CancelMode) void {
        if (self.canceled) return;
        self.canceled = true;
        self.closeFd();
        self.sink.fail(lua_state, mode, "closed");
        lua_handle.invalidate(lua_state, self.handle_ref);
        self.handle_ref = -1;
        // End the stream last so a resumed reader observes the socket
        // already closed and its handle dead.
        self.stream.cancel(self.host.allocator(), lua_state, mode);
    }

    pub fn destroy(self: *LuaSocket, allocator: std.mem.Allocator, lua_state: *c.lua_State) void {
        self.cancel(lua_state, .silent);
        allocator.destroy(self);
    }

    fn drainReadable(self: *LuaSocket) void {
        const lua_state = self.host.luaState();
        var buffer: [4096]u8 = undefined;
        while (self.fd != invalid_fd) {
            const result = linux.read(self.fd, &buffer, buffer.len);
            switch (linux.errno(result)) {
                .SUCCESS => {
                    if (result == 0) {
                        // Peer EOF: virtually no SOCK_STREAM protocol keeps a
                        // half-open connection useful, and an open EOF'd fd
                        // would re-report readability every epoll turn.
                        self.shutdownFd(lua_state, .resume_reader);
                        return;
                    }
                    c.lua_pushlstring(lua_state, &buffer, result);
                    self.stream.deliver(self.host.allocator(), lua_state) catch |err| {
                        log.warn("socket delivery failed: {}", .{err});
                    };
                },
                .AGAIN => return,
                .INTR => continue,
                else => {
                    self.shutdownFd(lua_state, .resume_reader);
                    return;
                },
            }
        }
    }
};

fn socketCallback(ctx: *anyopaque, _: *event_loop.EventLoop, events: u32) !void {
    const socket: *LuaSocket = @ptrCast(@alignCast(ctx));
    if (socket.canceled or socket.fd == invalid_fd) return;
    const lua_state = socket.host.luaState();
    if (events & linux.EPOLL.OUT != 0 and socket.sink.hasPending()) {
        const flushed = socket.sink.flush(socket.fd) catch {
            socket.shutdownFd(lua_state, .resume_reader);
            return;
        };
        if (flushed) {
            socket.updateInterests();
            socket.sink.resolve(lua_state);
            if (socket.canceled or socket.fd == invalid_fd) return;
        }
    }
    if (events & (linux.EPOLL.IN | linux.EPOLL.HUP | linux.EPOLL.ERR) != 0) {
        socket.drainReadable();
    }
}

pub fn installApi(lua_state: *c.lua_State, loop_table: c_int, host: *Host) void {
    c.lua_pushlightuserdata(lua_state, host);
    c.lua_pushcclosure(lua_state, luaConnect, 1);
    c.lua_setfield(lua_state, loop_table, "connect");
}

fn hostFromLua(lua_state: *c.lua_State) Host {
    const ptr = c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?;
    return @as(*Host, @ptrCast(@alignCast(ptr))).*;
}

const socket_type: [*:0]const u8 = "keywork.socket";
const socket_methods = [_]lua_handle.Method{
    .{ .name = "next", .func = luaSocketNext },
    .{ .name = "chunks", .func = luaSocketChunks },
    .{ .name = "write", .func = luaSocketWrite },
    .{ .name = "close", .func = luaSocketClose },
    .{ .name = "cancel", .func = luaSocketClose },
    .{ .name = "closed", .func = luaSocketClosed },
};

fn luaConnect(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const host = hostFromLua(lua_state);
    lua_task.raiseIfCanceled(lua_state);
    const path = lua_value.checkString(lua_state, 1);

    // A missing or refusing socket is an expected runtime failure, so
    // connect reports nil, err instead of raising.
    const fd = LuaSocket.connect(path) catch |err| {
        log.warn("loop.connect {s} failed: {}", .{ path, err });
        return lua_value.pushNilError(lua_state, err);
    };
    const socket = host.addSocket(fd) catch |err| {
        _ = linux.close(fd);
        log.warn("loop.connect failed: {}", .{err});
        return lua_value.pushNilError(lua_state, err);
    };
    lua_task.adoptResource(LuaSocket, lua_state, socket);
    socket.handle_ref = lua_handle.create(lua_state, socket_type, &socket_methods, socket);
    return 1;
}

fn luaSocketNext(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    // A dead handle ends the iteration instead of parking forever.
    const socket = lua_handle.resource(LuaSocket, lua_state, 1, socket_type) orelse return 0;
    // A closed fd means no more chunks can arrive; queued chunks are still
    // returned first by awaitNext.
    return socket.stream.awaitNext(lua_state, socket.fd == invalid_fd);
}

fn luaSocketChunks(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    _ = c.luaL_checkudata(lua_state, 1, socket_type);
    return lua_coro.pushIterator(lua_state, luaSocketNext);
}

fn luaSocketWrite(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    // A dead or closed handle reports nil, err: writes need a
    // distinguishable result, so this is not a silent no-op.
    const socket_or_dead = lua_handle.resource(LuaSocket, lua_state, 1, socket_type);
    const data = lua_value.checkString(lua_state, 2);
    const socket = socket_or_dead orelse {
        c.lua_pushnil(lua_state);
        c.lua_pushliteral(lua_state, "closed");
        return 2;
    };
    if (socket.canceled or socket.fd == invalid_fd) {
        c.lua_pushnil(lua_state);
        c.lua_pushliteral(lua_state, "closed");
        return 2;
    }
    if (socket.sink.hasWaiter()) return c.luaL_error(lua_state, "socket already has a waiting writer");

    // Fast path: write what the kernel accepts right now. A write that
    // completes synchronously never yields, so it also works from the
    // main state.
    const written = lua_sink.writeNow(socket.fd, data) catch |err| {
        socket.shutdownFd(lua_state, .resume_reader);
        c.lua_pushnil(lua_state);
        const name = lua_sink.errorName(err);
        c.lua_pushlstring(lua_state, name.ptr, name.len);
        return 2;
    };
    if (written == data.len) {
        c.lua_pushboolean(lua_state, 1);
        return 1;
    }

    // Backpressure: buffer the remainder and park the caller until the
    // event loop flushes it.
    if (lua_coro.onMainThread(lua_state)) return c.luaL_error(lua_state, "socket write would block; call write from a coroutine (wrap the caller in loop.spawn)");
    const yielded = socket.sink.park(socket.host.allocator(), lua_state, data[written..]) catch return c.luaL_error(lua_state, "socket write failed");
    socket.updateInterests();
    return yielded;
}

fn luaSocketClose(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const socket = lua_handle.resource(LuaSocket, lua_state, 1, socket_type) orelse return 0;
    socket.cancel(lua_state, .resume_reader);
    return 0;
}

fn luaSocketClosed(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const socket = lua_handle.resource(LuaSocket, lua_state, 1, socket_type) orelse {
        c.lua_pushboolean(lua_state, 1);
        return 1;
    };
    c.lua_pushboolean(lua_state, if (socket.canceled or socket.fd == invalid_fd) 1 else 0);
    return 1;
}
