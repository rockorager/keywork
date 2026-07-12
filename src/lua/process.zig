//! Lua child process integration for keywork.process.

const std = @import("std");
const event_loop = @import("../linux/event_loop.zig");
const linux_syscall = @import("../linux/syscall.zig");
const lua_coro = @import("coro.zig");
const lua_handle = @import("handle.zig");
const lua_sink = @import("sink.zig");
const lua_value = @import("value.zig");
const c = @import("luajit_c");

const linux = std.os.linux;
const posix = std.posix;

const invalid_fd: i32 = -1;

pub const Host = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        allocator: *const fn (*anyopaque) std.mem.Allocator,
        luaState: *const fn (*anyopaque) *c.lua_State,
        eventLoop: *const fn (*anyopaque) ?*event_loop.EventLoop,
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
};

pub const EnvVar = struct {
    name: []const u8,
    value: []const u8,
};

pub const SpawnSpec = struct {
    argv: []const []const u8,
    stdin_pipe: bool,
    stdout_pipe: bool,
    stderr_pipe: bool,
    /// Additional environment variables for the child, merged over the
    /// inherited environment (additions win on name collisions).
    env: []const EnvVar = &.{},
};

const PipeKind = enum { stdout, stderr };

const Pipe = struct {
    process: *LuaProcess = undefined,
    kind: PipeKind,
    fd: i32 = invalid_fd,
    stream: lua_coro.Stream = .{},
    source_handle: ?event_loop.EventLoop.SourceHandle = null,
};

pub const LuaProcess = struct {
    host: Host,
    pid: linux.pid_t,
    pidfd: i32,
    pidfd_source_handle: ?event_loop.EventLoop.SourceHandle = null,
    stdout_pipe: Pipe = .{ .kind = .stdout },
    stderr_pipe: Pipe = .{ .kind = .stderr },
    /// Write end of the child's stdin pipe, when spawned with stdin = "pipe".
    stdin_fd: i32 = invalid_fd,
    /// Distinguishes "stdin was never a pipe" (write is misuse) from
    /// "stdin was a pipe and is now closed" (write reports nil, "closed").
    stdin_piped: bool = false,
    /// Outgoing stdin bytes under backpressure, with the parked writer.
    stdin_sink: lua_sink.Sink = .{},
    stdin_source_handle: ?event_loop.EventLoop.SourceHandle = null,
    /// Coroutine parked in wait(), if any.
    waiter_ref: c_int = -1,
    exit_status: ?u32 = null,
    handle_ref: c_int = -1,
    registered: bool = false,
    canceled: bool = false,
    exited: bool = false,

    pub fn spawn(host: Host, spec: SpawnSpec) !LuaProcess {
        const allocator = host.allocator();
        var stdin_pipe: ?[2]i32 = null;
        var stdout_pipe: ?[2]i32 = null;
        var stderr_pipe: ?[2]i32 = null;
        if (spec.stdin_pipe) stdin_pipe = try createPipe();
        errdefer if (stdin_pipe) |pipe| closePipe(pipe);
        if (spec.stdout_pipe) stdout_pipe = try createPipe();
        errdefer if (stdout_pipe) |pipe| closePipe(pipe);
        if (spec.stderr_pipe) stderr_pipe = try createPipe();
        errdefer if (stderr_pipe) |pipe| closePipe(pipe);

        var argv = try prepareArgv(allocator, spec.argv);
        defer argv.deinit(allocator);
        const executable = try resolveExecutable(allocator, spec.argv[0]);
        defer allocator.free(executable);
        // Built before fork: the child must not allocate.
        var envp: ?PreparedArgv = if (spec.env.len > 0) try prepareEnvp(allocator, spec.env) else null;
        defer if (envp) |*prepared| prepared.deinit(allocator);

        const fork_result = linux.fork();
        switch (linux.errno(fork_result)) {
            .SUCCESS => {},
            .AGAIN, .NOMEM => return error.SystemResources,
            else => return error.ForkFailed,
        }

        if (fork_result == 0) {
            if (stdin_pipe) |pipe| {
                _ = linux.close(pipe[1]);
                dupTo(pipe[0], posix.STDIN_FILENO) catch linux.exit(127);
            }
            if (stdout_pipe) |pipe| {
                _ = linux.close(pipe[0]);
                dupTo(pipe[1], posix.STDOUT_FILENO) catch linux.exit(127);
            }
            if (stderr_pipe) |pipe| {
                _ = linux.close(pipe[0]);
                dupTo(pipe[1], posix.STDERR_FILENO) catch linux.exit(127);
            }
            _ = linux.execve(executable.ptr, argv.ptr(), if (envp) |prepared| prepared.ptr() else std.c.environ);
            linux.exit(127);
        }

        const pid: linux.pid_t = @intCast(fork_result);
        errdefer _ = linux.kill(pid, .TERM);
        var result: LuaProcess = .{
            .host = host,
            .pid = pid,
            .pidfd = try linux_syscall.fd(linux.pidfd_open(pid, 0)),
        };
        errdefer {
            if (result.pidfd != invalid_fd) _ = linux.close(result.pidfd);
        }

        if (stdin_pipe) |pipe| {
            _ = linux.close(pipe[0]);
            result.stdin_fd = pipe[1];
            result.stdin_piped = true;
            errdefer {
                if (result.stdin_fd != invalid_fd) _ = linux.close(result.stdin_fd);
            }
            try linux_syscall.setNonblocking(result.stdin_fd);
        }
        if (stdout_pipe) |pipe| {
            _ = linux.close(pipe[1]);
            result.stdout_pipe.fd = pipe[0];
            errdefer {
                if (result.stdout_pipe.fd != invalid_fd) _ = linux.close(result.stdout_pipe.fd);
            }
            try linux_syscall.setNonblocking(result.stdout_pipe.fd);
        }
        if (stderr_pipe) |pipe| {
            _ = linux.close(pipe[1]);
            result.stderr_pipe.fd = pipe[0];
            errdefer {
                if (result.stderr_pipe.fd != invalid_fd) _ = linux.close(result.stderr_pipe.fd);
            }
            try linux_syscall.setNonblocking(result.stderr_pipe.fd);
        }
        return result;
    }

    pub fn bindSelf(self: *LuaProcess) void {
        self.stdout_pipe.process = self;
        self.stderr_pipe.process = self;
    }

    pub fn register(self: *LuaProcess) !void {
        if (self.registered or self.canceled or self.exited) return;
        const loop = self.host.eventLoop() orelse return;
        errdefer self.unregister(loop);
        if (self.stdout_pipe.fd != invalid_fd) self.stdout_pipe.source_handle = try loop.addFd(.{ .fd = self.stdout_pipe.fd, .events = linux.EPOLL.IN | linux.EPOLL.HUP | linux.EPOLL.ERR, .ctx = &self.stdout_pipe, .callback = pipeCallback });
        if (self.stderr_pipe.fd != invalid_fd) self.stderr_pipe.source_handle = try loop.addFd(.{ .fd = self.stderr_pipe.fd, .events = linux.EPOLL.IN | linux.EPOLL.HUP | linux.EPOLL.ERR, .ctx = &self.stderr_pipe, .callback = pipeCallback });
        if (self.stdin_fd != invalid_fd) self.stdin_source_handle = try loop.addFd(.{ .fd = self.stdin_fd, .events = self.wantedStdinEvents(), .ctx = self, .callback = stdinCallback });
        self.pidfd_source_handle = try loop.addFd(.{ .fd = self.pidfd, .events = linux.EPOLL.IN | linux.EPOLL.HUP | linux.EPOLL.ERR, .ctx = self, .callback = exitCallback });
        self.registered = true;
        if (self.stdout_pipe.fd != invalid_fd) try drainPipe(&self.stdout_pipe);
        if (self.stderr_pipe.fd != invalid_fd) try drainPipe(&self.stderr_pipe);
    }

    pub fn cancel(self: *LuaProcess, lua_state: *c.lua_State, mode: lua_coro.CancelMode) void {
        if (self.canceled or self.exited) return;
        self.canceled = true;
        _ = linux.kill(self.pid, .TERM);
        self.closeStdin(lua_state, mode);
        self.closeOutputFds(lua_state, mode);
        self.finishWaiter(lua_state, mode);
    }

    /// Epoll interest for the stdin write end: writability only matters
    /// while flushing buffered bytes for a parked writer.
    fn wantedStdinEvents(self: *const LuaProcess) u32 {
        var events: u32 = linux.EPOLL.HUP | linux.EPOLL.ERR;
        if (self.stdin_sink.hasPending()) events |= linux.EPOLL.OUT;
        return events;
    }

    fn updateStdinInterests(self: *LuaProcess) void {
        const loop = self.host.eventLoop() orelse return;
        if (self.stdin_source_handle) |handle| loop.modifySource(handle, self.wantedStdinEvents());
    }

    /// Closes the child's stdin (EOF to the child), drops unflushed bytes,
    /// and fails a parked writer with nil, "closed". Idempotent.
    fn closeStdin(self: *LuaProcess, lua_state: *c.lua_State, mode: lua_coro.CancelMode) void {
        if (self.stdin_fd == invalid_fd) return;
        if (self.host.eventLoop()) |loop| if (self.stdin_source_handle) |handle| loop.removeSource(handle);
        self.stdin_source_handle = null;
        _ = linux.close(self.stdin_fd);
        self.stdin_fd = invalid_fd;
        self.stdin_sink.clear(self.host.allocator());
        self.stdin_sink.fail(lua_state, mode, "closed");
    }

    /// Resolves a parked wait() with no value (canceled or reaped
    /// elsewhere); a normal exit resumes it with the result in complete().
    fn finishWaiter(self: *LuaProcess, lua_state: *c.lua_State, mode: lua_coro.CancelMode) void {
        if (self.waiter_ref < 0) return;
        switch (mode) {
            .resume_reader => lua_coro.resumeReaderWith(lua_state, &self.waiter_ref, 0),
            .silent => {
                c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, self.waiter_ref);
                self.waiter_ref = -1;
            },
        }
    }

    fn complete(self: *LuaProcess, lua_state: *c.lua_State, status: u32) !void {
        if (self.exited) return;
        self.exited = true;
        self.exit_status = status;
        // Drain before resolving the waiter so output readers observe their
        // streams end before wait() returns.
        try drainPipe(&self.stdout_pipe);
        try drainPipe(&self.stderr_pipe);
        if (self.waiter_ref >= 0) {
            pushResult(lua_state, status);
            lua_coro.resumeReaderWith(lua_state, &self.waiter_ref, 1);
        }
    }

    pub fn closeFds(self: *LuaProcess, lua_state: *c.lua_State, mode: lua_coro.CancelMode) void {
        if (self.host.eventLoop()) |loop| {
            self.unregister(loop);
        } else {
            self.registered = false;
            self.stdout_pipe.source_handle = null;
            self.stderr_pipe.source_handle = null;
            self.stdin_source_handle = null;
            self.pidfd_source_handle = null;
        }
        self.closeStdin(lua_state, mode);
        self.closeOutputFds(lua_state, mode);
        if (self.pidfd != invalid_fd) {
            _ = linux.close(self.pidfd);
            self.pidfd = invalid_fd;
        }
    }

    pub fn unregister(self: *LuaProcess, loop: *event_loop.EventLoop) void {
        if (self.stdout_pipe.source_handle) |handle| loop.removeSource(handle);
        if (self.stderr_pipe.source_handle) |handle| loop.removeSource(handle);
        if (self.stdin_source_handle) |handle| loop.removeSource(handle);
        if (self.pidfd_source_handle) |handle| loop.removeSource(handle);
        self.stdout_pipe.source_handle = null;
        self.stderr_pipe.source_handle = null;
        self.stdin_source_handle = null;
        self.pidfd_source_handle = null;
        self.registered = false;
    }

    fn closeOutputFds(self: *LuaProcess, lua_state: *c.lua_State, mode: lua_coro.CancelMode) void {
        closePipeFd(&self.stdout_pipe, lua_state, mode);
        closePipeFd(&self.stderr_pipe, lua_state, mode);
    }

    pub fn deinit(self: *LuaProcess, allocator: std.mem.Allocator, lua_state: *c.lua_State) void {
        self.cleanup(lua_state);
        allocator.destroy(self);
    }

    pub fn cleanup(self: *LuaProcess, lua_state: *c.lua_State) void {
        if (!self.exited and !self.canceled) {
            _ = linux.kill(self.pid, .TERM);
            var status: u32 = 0;
            _ = linux.waitpid(self.pid, &status, linux.W.NOHANG);
        }
        self.closeFds(lua_state, .silent);
        // Free queued output that no reader will consume.
        self.stdout_pipe.stream.cancel(self.host.allocator(), lua_state, .silent);
        self.stderr_pipe.stream.cancel(self.host.allocator(), lua_state, .silent);
        self.finishWaiter(lua_state, .silent);
        // The process object is about to be freed; retained Lua handles
        // become inert no-ops from here on.
        lua_handle.invalidate(lua_state, self.handle_ref);
        self.handle_ref = -1;
    }

    pub fn destroy(self: *LuaProcess, allocator: std.mem.Allocator, lua_state: *c.lua_State) void {
        self.cancel(lua_state, .silent);
        if (!self.exited) {
            var status: u32 = 0;
            _ = linux.waitpid(self.pid, &status, linux.W.NOHANG);
        }
        self.deinit(allocator, lua_state);
    }
};

pub fn parseArgv(lua_state: *c.lua_State, allocator: std.mem.Allocator, table: c_int) ![]const []const u8 {
    c.lua_getfield(lua_state, table, "argv");
    defer pop(lua_state, 1);
    const argv_table = absoluteIndex(lua_state, -1);
    try expectType(lua_state, argv_table, c.LUA_TTABLE);
    const count: usize = @intCast(c.lua_objlen(lua_state, argv_table));
    if (count == 0) return error.EmptyArgv;
    const argv = try allocator.alloc([]const u8, count);
    errdefer freeArgv(allocator, argv);
    for (argv, 0..) |*arg, index| {
        c.lua_rawgeti(lua_state, argv_table, @intCast(index + 1));
        defer pop(lua_state, 1);
        arg.* = try dupeStringFromStack(lua_state, allocator, -1);
    }
    return argv;
}

pub fn freeArgv(allocator: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |arg| allocator.free(arg);
    allocator.free(argv);
}

/// Parses the spec's optional `env` field: a table of string names to
/// string values. Missing field yields an empty slice.
pub fn parseEnv(lua_state: *c.lua_State, allocator: std.mem.Allocator, table: c_int) ![]const EnvVar {
    c.lua_getfield(lua_state, table, "env");
    defer pop(lua_state, 1);
    if (c.lua_isnil(lua_state, -1)) return &.{};
    const env_table = absoluteIndex(lua_state, -1);
    try expectType(lua_state, env_table, c.LUA_TTABLE);

    var env: std.ArrayList(EnvVar) = .empty;
    errdefer {
        for (env.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.value);
        }
        env.deinit(allocator);
    }
    c.lua_pushnil(lua_state);
    while (c.lua_next(lua_state, env_table) != 0) {
        defer pop(lua_state, 1);
        if (c.lua_type(lua_state, -2) != c.LUA_TSTRING) return error.InvalidEnvName;
        const name = try dupeStringFromStack(lua_state, allocator, -2);
        errdefer allocator.free(name);
        if (std.mem.indexOfScalar(u8, name, '=') != null) return error.InvalidEnvName;
        if (c.lua_type(lua_state, -1) != c.LUA_TSTRING) return error.InvalidEnvValue;
        const value = try dupeStringFromStack(lua_state, allocator, -1);
        errdefer allocator.free(value);
        try env.append(allocator, .{ .name = name, .value = value });
    }
    return env.toOwnedSlice(allocator);
}

pub fn freeEnv(allocator: std.mem.Allocator, env: []const EnvVar) void {
    for (env) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.value);
    }
    allocator.free(env);
}

const process_type: [*:0]const u8 = "keywork.process";
const process_methods = [_]lua_handle.Method{
    .{ .name = "stdout", .func = luaStdout },
    .{ .name = "stderr", .func = luaStderr },
    .{ .name = "write", .func = luaWrite },
    .{ .name = "close_stdin", .func = luaCloseStdin },
    .{ .name = "wait", .func = luaWait },
    .{ .name = "cancel", .func = luaCancel },
    .{ .name = "canceled", .func = luaCanceled },
};

pub fn pushHandle(lua_state: *c.lua_State, process: *LuaProcess) void {
    process.handle_ref = lua_handle.create(lua_state, process_type, &process_methods, process);
}

fn pipeCallback(ctx: *anyopaque, _: *event_loop.EventLoop, _: u32) !void {
    const pipe: *Pipe = @ptrCast(@alignCast(ctx));
    try drainPipe(pipe);
}

fn stdinCallback(ctx: *anyopaque, _: *event_loop.EventLoop, events: u32) !void {
    const process: *LuaProcess = @ptrCast(@alignCast(ctx));
    if (process.stdin_fd == invalid_fd) return;
    const lua_state = process.host.luaState();
    if (events & linux.EPOLL.OUT != 0 and process.stdin_sink.hasPending()) {
        const flushed = process.stdin_sink.flush(process.stdin_fd) catch {
            process.closeStdin(lua_state, .resume_reader);
            return;
        };
        if (flushed) {
            process.updateStdinInterests();
            process.stdin_sink.resolve(lua_state);
            if (process.stdin_fd == invalid_fd) return;
        }
    }
    // ERR on a pipe write end means the child closed its stdin (or died);
    // no write can ever succeed again.
    if (events & (linux.EPOLL.HUP | linux.EPOLL.ERR) != 0) {
        process.closeStdin(lua_state, .resume_reader);
    }
}

fn exitCallback(ctx: *anyopaque, _: *event_loop.EventLoop, _: u32) !void {
    const process: *LuaProcess = @ptrCast(@alignCast(ctx));
    if (process.exited) return;
    var status: u32 = 0;
    const result = linux.waitpid(process.pid, &status, linux.W.NOHANG);
    const lua_state = process.host.luaState();
    switch (linux.errno(result)) {
        .SUCCESS => {},
        .CHILD => {
            // Reaped elsewhere; mark exited so a retained handle's cancel()
            // cannot signal a reused PID. The exit status is unknown, so a
            // parked wait() resumes with no value.
            process.exited = true;
            process.closeFds(lua_state, .resume_reader);
            process.finishWaiter(lua_state, .resume_reader);
            return;
        },
        else => return error.WaitPidFailed,
    }
    if (result == 0) return;

    process.complete(lua_state, status) catch |err| {
        process.closeFds(lua_state, .resume_reader);
        return err;
    };
    process.closeFds(lua_state, .resume_reader);
}

fn drainPipe(pipe: *Pipe) !void {
    if (pipe.fd == invalid_fd) return;
    const lua_state = pipe.process.host.luaState();
    var buffer: [4096]u8 = undefined;
    while (pipe.fd != invalid_fd) {
        const result = linux.read(pipe.fd, &buffer, buffer.len);
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0) {
                    closePipeFd(pipe, lua_state, .resume_reader);
                    return;
                }
                c.lua_pushlstring(lua_state, &buffer, result);
                pipe.stream.deliver(pipe.process.host.allocator(), lua_state) catch |err| {
                    std.log.scoped(.keywork_luajit).warn("process output delivery failed: {}", .{err});
                };
            },
            .AGAIN => return,
            else => {
                closePipeFd(pipe, lua_state, .resume_reader);
                return;
            },
        }
    }
}

/// Closes the pipe and ends its stream. Chunks already queued stay readable;
/// `mode` decides whether a parked reader resumes (event/Lua context) or is
/// dropped (bulk teardown).
fn closePipeFd(pipe: *Pipe, lua_state: *c.lua_State, mode: lua_coro.CancelMode) void {
    if (pipe.fd == invalid_fd) return;
    if (pipe.process.host.eventLoop()) |loop| if (pipe.source_handle) |handle| loop.removeSource(handle);
    pipe.source_handle = null;
    _ = linux.close(pipe.fd);
    pipe.fd = invalid_fd;
    pipe.stream.finish(lua_state, mode);
}

fn pushResult(lua_state: *c.lua_State, status: u32) void {
    c.lua_createtable(lua_state, 0, 3);
    const table = c.lua_gettop(lua_state);
    if (linux.W.IFEXITED(status)) {
        c.lua_pushinteger(lua_state, linux.W.EXITSTATUS(status));
        c.lua_setfield(lua_state, table, "code");
    } else if (linux.W.IFSIGNALED(status)) {
        c.lua_pushinteger(lua_state, @intFromEnum(linux.W.TERMSIG(status)));
        c.lua_setfield(lua_state, table, "signal");
    }
    c.lua_pushboolean(lua_state, if (linux.W.IFEXITED(status) and linux.W.EXITSTATUS(status) == 0) 1 else 0);
    c.lua_setfield(lua_state, table, "ok");
}

fn luaCancel(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const process = lua_handle.resource(LuaProcess, lua_state, 1, process_type) orelse return 0;
    process.cancel(lua_state, .resume_reader);
    return 0;
}

fn pipeNext(lua_state: *c.lua_State, comptime kind: PipeKind) c_int {
    // A dead handle ends the iteration instead of parking forever.
    const process = lua_handle.resource(LuaProcess, lua_state, 1, process_type) orelse return 0;
    const pipe = switch (kind) {
        .stdout => &process.stdout_pipe,
        .stderr => &process.stderr_pipe,
    };
    // A closed (or never-piped) fd means no more chunks can arrive; queued
    // chunks are still returned first by awaitNext.
    return pipe.stream.awaitNext(lua_state, pipe.fd == invalid_fd);
}

fn luaStdoutNext(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    return pipeNext(lua_state_optional.?, .stdout);
}

fn luaStderrNext(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    return pipeNext(lua_state_optional.?, .stderr);
}

fn luaStdout(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    _ = c.luaL_checkudata(lua_state, 1, process_type);
    return lua_coro.pushIterator(lua_state, luaStdoutNext);
}

fn luaStderr(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    _ = c.luaL_checkudata(lua_state, 1, process_type);
    return lua_coro.pushIterator(lua_state, luaStderrNext);
}

fn luaWrite(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    // A dead or closed handle reports nil, err: writes need a
    // distinguishable result, so this is not a silent no-op.
    const process_or_dead = lua_handle.resource(LuaProcess, lua_state, 1, process_type);
    const data = lua_value.checkString(lua_state, 2);
    const process = process_or_dead orelse {
        c.lua_pushnil(lua_state);
        c.lua_pushliteral(lua_state, "closed");
        return 2;
    };
    // Writing to a process spawned without a stdin pipe can never succeed,
    // so it is misuse rather than a runtime failure.
    if (!process.stdin_piped) return c.luaL_error(lua_state, "process stdin is not a pipe (spawn with stdin = \"pipe\")");
    if (process.canceled or process.stdin_fd == invalid_fd) {
        c.lua_pushnil(lua_state);
        c.lua_pushliteral(lua_state, "closed");
        return 2;
    }
    if (process.stdin_sink.hasWaiter()) return c.luaL_error(lua_state, "process stdin already has a waiting writer");

    // Fast path: write what the pipe accepts right now. A write that
    // completes synchronously never yields, so it also works from the
    // main state.
    const written = lua_sink.writeNow(process.stdin_fd, data) catch |err| {
        process.closeStdin(lua_state, .resume_reader);
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
    if (lua_coro.onMainThread(lua_state)) return c.luaL_error(lua_state, "process write would block; call write from a coroutine (wrap the caller in loop.spawn)");
    const yielded = process.stdin_sink.park(process.host.allocator(), lua_state, data[written..]) catch return c.luaL_error(lua_state, "process write failed");
    process.updateStdinInterests();
    return yielded;
}

fn luaCloseStdin(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const process = lua_handle.resource(LuaProcess, lua_state, 1, process_type) orelse return 0;
    process.closeStdin(lua_state, .resume_reader);
    return 0;
}

fn luaWait(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    // A dead or canceled handle reports nil instead of parking forever.
    const process = lua_handle.resource(LuaProcess, lua_state, 1, process_type) orelse {
        c.lua_pushnil(lua_state);
        return 1;
    };
    if (process.exit_status) |status| {
        pushResult(lua_state, status);
        return 1;
    }
    if (process.canceled or process.exited) {
        c.lua_pushnil(lua_state);
        return 1;
    }
    if (lua_coro.onMainThread(lua_state)) return c.luaL_error(lua_state, "wait must be called from a coroutine (wrap the caller in loop.spawn)");
    if (process.waiter_ref >= 0) return c.luaL_error(lua_state, "process already has a waiting reader");
    process.waiter_ref = lua_coro.refCurrentThread(lua_state);
    return c.lua_yield(lua_state, 0);
}

fn luaCanceled(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const process = lua_handle.resource(LuaProcess, lua_state, 1, process_type) orelse {
        c.lua_pushboolean(lua_state, 1);
        return 1;
    };
    c.lua_pushboolean(lua_state, if (process.canceled) 1 else 0);
    return 1;
}

const PreparedArgv = struct {
    values: [:null]?[*:0]const u8,
    strings: [][:0]u8,

    fn ptr(self: *const PreparedArgv) [*:null]const ?[*:0]const u8 {
        return self.values.ptr;
    }

    fn deinit(self: *PreparedArgv, allocator: std.mem.Allocator) void {
        for (self.strings) |value| allocator.free(value);
        allocator.free(self.strings);
        allocator.free(self.values);
    }
};

fn prepareArgv(allocator: std.mem.Allocator, argv: []const []const u8) !PreparedArgv {
    const values = try allocator.allocSentinel(?[*:0]const u8, argv.len, null);
    errdefer allocator.free(values);
    const strings = try allocator.alloc([:0]u8, argv.len);
    errdefer allocator.free(strings);
    var initialized: usize = 0;
    errdefer for (strings[0..initialized]) |value| allocator.free(value);
    for (argv, 0..) |arg, index| {
        strings[index] = try allocator.dupeZ(u8, arg);
        initialized += 1;
        values[index] = strings[index].ptr;
    }
    return .{ .values = values, .strings = strings };
}

/// Merges `additions` over the inherited environment into an execve-ready
/// envp. Inherited entries whose name collides with an addition are dropped.
fn prepareEnvp(allocator: std.mem.Allocator, additions: []const EnvVar) !PreparedArgv {
    var inherited_count: usize = 0;
    while (std.c.environ[inherited_count]) |_| inherited_count += 1;

    var strings: std.ArrayList([:0]u8) = .empty;
    errdefer {
        for (strings.items) |value| allocator.free(value);
        strings.deinit(allocator);
    }

    var index: usize = 0;
    while (index < inherited_count) : (index += 1) {
        const entry = std.mem.span(std.c.environ[index].?);
        if (envNameOverridden(entry, additions)) continue;
        try strings.append(allocator, try allocator.dupeZ(u8, entry));
    }
    for (additions) |addition| {
        std.debug.assert(std.mem.indexOfScalar(u8, addition.name, '=') == null);
        try strings.append(allocator, try std.fmt.allocPrintSentinel(allocator, "{s}={s}", .{ addition.name, addition.value }, 0));
    }

    const values = try allocator.allocSentinel(?[*:0]const u8, strings.items.len, null);
    errdefer allocator.free(values);
    for (strings.items, 0..) |value, value_index| values[value_index] = value.ptr;
    return .{ .values = values, .strings = try strings.toOwnedSlice(allocator) };
}

fn envNameOverridden(entry: []const u8, additions: []const EnvVar) bool {
    const separator = std.mem.indexOfScalar(u8, entry, '=') orelse entry.len;
    const name = entry[0..separator];
    for (additions) |addition| {
        if (std.mem.eql(u8, name, addition.name)) return true;
    }
    return false;
}

test envNameOverridden {
    const additions: []const EnvVar = &.{.{ .name = "FOO", .value = "1" }};
    try std.testing.expect(envNameOverridden("FOO=old", additions));
    try std.testing.expect(envNameOverridden("FOO", additions));
    try std.testing.expect(!envNameOverridden("FOOBAR=1", additions));
    try std.testing.expect(!envNameOverridden("BAR=FOO", additions));
}

fn resolveExecutable(allocator: std.mem.Allocator, name: []const u8) ![:0]u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) return allocator.dupeZ(u8, name);
    const path = getenv("PATH") orelse "/usr/local/bin:/usr/bin:/bin";
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        const resolved = try std.fs.path.joinZ(allocator, &.{ if (dir.len == 0) "." else dir, name });
        errdefer allocator.free(resolved);
        if (isExecutable(resolved)) return resolved;
        allocator.free(resolved);
    }
    return error.FileNotFound;
}

fn getenv(name: []const u8) ?[]const u8 {
    var index: usize = 0;
    while (std.c.environ[index]) |entry_z| : (index += 1) {
        const entry = std.mem.span(entry_z);
        if (entry.len > name.len and entry[name.len] == '=' and std.mem.eql(u8, entry[0..name.len], name)) return entry[name.len + 1 ..];
    }
    return null;
}

fn isExecutable(path: [:0]const u8) bool {
    return linux.errno(linux.access(path.ptr, linux.X_OK)) == .SUCCESS;
}

fn createPipe() ![2]i32 {
    var fds: [2]i32 = undefined;
    try linux_syscall.check(linux.pipe2(&fds, .{ .CLOEXEC = true }));
    return fds;
}

fn closePipe(pipe: [2]i32) void {
    _ = linux.close(pipe[0]);
    _ = linux.close(pipe[1]);
}

fn dupTo(old: i32, new: i32) !void {
    _ = try linux_syscall.fd(linux.dup2(old, new));
}

const absoluteIndex = lua_value.absoluteIndex;
const expectType = lua_value.expectType;
const dupeStringFromStack = lua_value.dupeStringFromStack;
const pop = lua_value.pop;
