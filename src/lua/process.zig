//! Lua child process integration for keywork.process.

const std = @import("std");
const event_loop = @import("../linux/event_loop.zig");
const lua_handle = @import("handle.zig");
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

pub const SpawnSpec = struct {
    argv: []const []const u8,
    stdout_pipe: bool,
    stderr_pipe: bool,
};

pub const Callbacks = struct {
    stdout_ref: c_int = -1,
    stderr_ref: c_int = -1,
    exit_ref: c_int = -1,

    pub fn unref(self: *Callbacks, lua_state: *c.lua_State) void {
        if (self.stdout_ref >= 0) {
            c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, self.stdout_ref);
            self.stdout_ref = -1;
        }
        if (self.stderr_ref >= 0) {
            c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, self.stderr_ref);
            self.stderr_ref = -1;
        }
        if (self.exit_ref >= 0) {
            c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, self.exit_ref);
            self.exit_ref = -1;
        }
    }
};

const PipeKind = enum { stdout, stderr };

const Pipe = struct {
    process: *LuaProcess = undefined,
    kind: PipeKind,
    fd: i32 = invalid_fd,
    source_handle: ?event_loop.EventLoop.SourceHandle = null,

    fn callbackRef(self: *Pipe) c_int {
        return switch (self.kind) {
            .stdout => self.process.stdout_ref,
            .stderr => self.process.stderr_ref,
        };
    }
};

pub const LuaProcess = struct {
    host: Host,
    pid: linux.pid_t,
    pidfd: i32,
    pidfd_source_handle: ?event_loop.EventLoop.SourceHandle = null,
    stdout_pipe: Pipe = .{ .kind = .stdout },
    stderr_pipe: Pipe = .{ .kind = .stderr },
    stdout_ref: c_int = -1,
    stderr_ref: c_int = -1,
    exit_ref: c_int = -1,
    handle_ref: c_int = -1,
    registered: bool = false,
    canceled: bool = false,
    exited: bool = false,

    pub fn spawn(host: Host, spec: SpawnSpec, callbacks: Callbacks) !LuaProcess {
        const allocator = host.allocator();
        var stdout_pipe: ?[2]i32 = null;
        var stderr_pipe: ?[2]i32 = null;
        if (spec.stdout_pipe) stdout_pipe = try createPipe();
        errdefer if (stdout_pipe) |pipe| closePipe(pipe);
        if (spec.stderr_pipe) stderr_pipe = try createPipe();
        errdefer if (stderr_pipe) |pipe| closePipe(pipe);

        var argv = try prepareArgv(allocator, spec.argv);
        defer argv.deinit(allocator);
        const executable = try resolveExecutable(allocator, spec.argv[0]);
        defer allocator.free(executable);

        const fork_result = linux.fork();
        switch (linux.errno(fork_result)) {
            .SUCCESS => {},
            .AGAIN, .NOMEM => return error.SystemResources,
            else => return error.ForkFailed,
        }

        if (fork_result == 0) {
            if (stdout_pipe) |pipe| {
                _ = linux.close(pipe[0]);
                dupTo(pipe[1], posix.STDOUT_FILENO) catch linux.exit(127);
            }
            if (stderr_pipe) |pipe| {
                _ = linux.close(pipe[0]);
                dupTo(pipe[1], posix.STDERR_FILENO) catch linux.exit(127);
            }
            _ = linux.execve(executable.ptr, argv.ptr(), std.c.environ);
            linux.exit(127);
        }

        const pid: linux.pid_t = @intCast(fork_result);
        errdefer _ = linux.kill(pid, .TERM);
        var result: LuaProcess = .{
            .host = host,
            .pid = pid,
            .pidfd = try linuxFd(linux.pidfd_open(pid, 0)),
            .stdout_ref = callbacks.stdout_ref,
            .stderr_ref = callbacks.stderr_ref,
            .exit_ref = callbacks.exit_ref,
        };
        errdefer {
            if (result.pidfd != invalid_fd) _ = linux.close(result.pidfd);
        }

        if (stdout_pipe) |pipe| {
            _ = linux.close(pipe[1]);
            result.stdout_pipe.fd = pipe[0];
            errdefer {
                if (result.stdout_pipe.fd != invalid_fd) _ = linux.close(result.stdout_pipe.fd);
            }
            try setNonblocking(result.stdout_pipe.fd);
        }
        if (stderr_pipe) |pipe| {
            _ = linux.close(pipe[1]);
            result.stderr_pipe.fd = pipe[0];
            errdefer {
                if (result.stderr_pipe.fd != invalid_fd) _ = linux.close(result.stderr_pipe.fd);
            }
            try setNonblocking(result.stderr_pipe.fd);
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
        self.pidfd_source_handle = try loop.addFd(.{ .fd = self.pidfd, .events = linux.EPOLL.IN | linux.EPOLL.HUP | linux.EPOLL.ERR, .ctx = self, .callback = exitCallback });
        self.registered = true;
        if (self.stdout_pipe.fd != invalid_fd) try drainPipe(&self.stdout_pipe);
        if (self.stderr_pipe.fd != invalid_fd) try drainPipe(&self.stderr_pipe);
    }

    pub fn cancel(self: *LuaProcess, lua_state: *c.lua_State) void {
        if (self.canceled or self.exited) return;
        self.canceled = true;
        _ = linux.kill(self.pid, .TERM);
        self.closeOutputFds();
        self.clearRefs(lua_state);
    }

    fn complete(self: *LuaProcess, lua_state: *c.lua_State, status: u32) !void {
        if (self.exited) return;
        self.exited = true;
        try drainPipe(&self.stdout_pipe);
        try drainPipe(&self.stderr_pipe);
        if (!self.canceled and self.exit_ref >= 0) {
            c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, self.exit_ref);
            pushResult(lua_state, status);
            if (c.lua_pcall(lua_state, 1, 0, 0) != 0) {
                failLuaCall(lua_state, "process exit callback failed") catch {};
            }
        }
    }

    pub fn closeFds(self: *LuaProcess) void {
        if (self.host.eventLoop()) |loop| {
            self.unregister(loop);
        } else {
            self.registered = false;
            self.stdout_pipe.source_handle = null;
            self.stderr_pipe.source_handle = null;
            self.pidfd_source_handle = null;
        }
        self.closeOutputFds();
        if (self.pidfd != invalid_fd) {
            _ = linux.close(self.pidfd);
            self.pidfd = invalid_fd;
        }
    }

    pub fn unregister(self: *LuaProcess, loop: *event_loop.EventLoop) void {
        if (self.stdout_pipe.source_handle) |handle| loop.removeSource(handle);
        if (self.stderr_pipe.source_handle) |handle| loop.removeSource(handle);
        if (self.pidfd_source_handle) |handle| loop.removeSource(handle);
        self.stdout_pipe.source_handle = null;
        self.stderr_pipe.source_handle = null;
        self.pidfd_source_handle = null;
        self.registered = false;
    }

    fn closeOutputFds(self: *LuaProcess) void {
        if (self.host.eventLoop()) |loop| {
            if (self.stdout_pipe.source_handle) |handle| loop.removeSource(handle);
            if (self.stderr_pipe.source_handle) |handle| loop.removeSource(handle);
        }
        self.stdout_pipe.source_handle = null;
        self.stderr_pipe.source_handle = null;
        if (self.stdout_pipe.fd != invalid_fd) {
            _ = linux.close(self.stdout_pipe.fd);
            self.stdout_pipe.fd = invalid_fd;
        }
        if (self.stderr_pipe.fd != invalid_fd) {
            _ = linux.close(self.stderr_pipe.fd);
            self.stderr_pipe.fd = invalid_fd;
        }
    }

    pub fn clearRefs(self: *LuaProcess, lua_state: *c.lua_State) void {
        if (self.stdout_ref >= 0) {
            c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, self.stdout_ref);
            self.stdout_ref = -1;
        }
        if (self.stderr_ref >= 0) {
            c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, self.stderr_ref);
            self.stderr_ref = -1;
        }
        if (self.exit_ref >= 0) {
            c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, self.exit_ref);
            self.exit_ref = -1;
        }
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
        self.closeFds();
        self.clearRefs(lua_state);
        // The process object is about to be freed; retained Lua handles
        // become inert no-ops from here on.
        lua_handle.invalidate(lua_state, self.handle_ref);
        self.handle_ref = -1;
    }

    pub fn destroy(self: *LuaProcess, allocator: std.mem.Allocator, lua_state: *c.lua_State) void {
        self.cancel(lua_state);
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

pub fn tableFunctionRef(lua_state: *c.lua_State, table: c_int, key: [*:0]const u8) !c_int {
    c.lua_getfield(lua_state, table, key);
    if (c.lua_isnil(lua_state, -1)) {
        pop(lua_state, 1);
        return -1;
    }
    if (c.lua_type(lua_state, -1) != c.LUA_TFUNCTION) {
        pop(lua_state, 1);
        return error.ExpectedLuaFunction;
    }
    return c.luaL_ref(lua_state, c.LUA_REGISTRYINDEX);
}

const process_type: [*:0]const u8 = "keywork.process";
const process_methods = [_]lua_handle.Method{
    .{ .name = "cancel", .func = luaCancel },
    .{ .name = "canceled", .func = luaCanceled },
};

pub fn pushHandle(lua_state: *c.lua_State, process: *LuaProcess) void {
    process.handle_ref = lua_handle.create(lua_state, process_type, &process_methods, process);
}

pub fn stringField(lua_state: *c.lua_State, table: c_int, key: [*:0]const u8) ![]const u8 {
    c.lua_getfield(lua_state, table, key);
    defer pop(lua_state, 1);
    var len: usize = 0;
    const ptr = c.lua_tolstring(lua_state, -1, &len) orelse return error.ExpectedLuaString;
    return ptr[0..len];
}

fn pipeCallback(ctx: *anyopaque, _: *event_loop.EventLoop, _: u32) !void {
    const pipe: *Pipe = @ptrCast(@alignCast(ctx));
    try drainPipe(pipe);
}

fn exitCallback(ctx: *anyopaque, _: *event_loop.EventLoop, _: u32) !void {
    const process: *LuaProcess = @ptrCast(@alignCast(ctx));
    if (process.exited) return;
    var status: u32 = 0;
    const result = linux.waitpid(process.pid, &status, linux.W.NOHANG);
    switch (linux.errno(result)) {
        .SUCCESS => {},
        .CHILD => {
            // Reaped elsewhere; mark exited so a retained handle's cancel()
            // cannot signal a reused PID.
            process.exited = true;
            process.closeFds();
            process.clearRefs(process.host.luaState());
            return;
        },
        else => return error.WaitPidFailed,
    }
    if (result == 0) return;

    const host = process.host;
    const lua_state = host.luaState();
    process.complete(lua_state, status) catch |err| {
        process.closeFds();
        process.clearRefs(lua_state);
        return err;
    };
    process.closeFds();
    process.clearRefs(lua_state);
}

fn drainPipe(pipe: *Pipe) !void {
    if (pipe.fd == invalid_fd) return;
    var buffer: [4096]u8 = undefined;
    while (true) {
        const result = linux.read(pipe.fd, &buffer, buffer.len);
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0) {
                    closePipeFd(pipe);
                    return;
                }
                try callChunk(pipe, buffer[0..result]);
            },
            .AGAIN => return,
            else => {
                closePipeFd(pipe);
                return;
            },
        }
    }
}

fn callChunk(pipe: *Pipe, chunk: []const u8) !void {
    const ref = pipe.callbackRef();
    if (ref < 0 or pipe.process.canceled) return;
    const lua_state = pipe.process.host.luaState();
    c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, ref);
    c.lua_pushlstring(lua_state, chunk.ptr, chunk.len);
    if (c.lua_pcall(lua_state, 1, 0, 0) != 0) {
        failLuaCall(lua_state, "process output callback failed") catch {};
        switch (pipe.kind) {
            .stdout => {
                if (pipe.process.stdout_ref >= 0) c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, pipe.process.stdout_ref);
                pipe.process.stdout_ref = -1;
            },
            .stderr => {
                if (pipe.process.stderr_ref >= 0) c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, pipe.process.stderr_ref);
                pipe.process.stderr_ref = -1;
            },
        }
        closePipeFd(pipe);
        return;
    }
}

fn closePipeFd(pipe: *Pipe) void {
    if (pipe.fd == invalid_fd) return;
    if (pipe.process.host.eventLoop()) |loop| if (pipe.source_handle) |handle| loop.removeSource(handle);
    pipe.source_handle = null;
    _ = linux.close(pipe.fd);
    pipe.fd = invalid_fd;
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
    process.cancel(lua_state);
    return 0;
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
    try linuxVoid(linux.pipe2(&fds, .{ .CLOEXEC = true }));
    return fds;
}

fn closePipe(pipe: [2]i32) void {
    _ = linux.close(pipe[0]);
    _ = linux.close(pipe[1]);
}

fn dupTo(old: i32, new: i32) !void {
    _ = try linuxFd(linux.dup2(old, new));
}

fn setNonblocking(fd: i32) !void {
    const flags = try linuxFd(linux.fcntl(fd, linux.F.GETFL, 0));
    try linuxVoid(linux.fcntl(fd, linux.F.SETFL, @as(usize, @intCast(flags)) | linux.SOCK.NONBLOCK));
}

fn linuxFd(result: usize) !i32 {
    return switch (linux.errno(result)) {
        .SUCCESS => @intCast(result),
        else => error.LinuxSyscallFailed,
    };
}

fn linuxVoid(result: usize) !void {
    return switch (linux.errno(result)) {
        .SUCCESS => {},
        else => error.LinuxSyscallFailed,
    };
}

fn absoluteIndex(lua_state: *c.lua_State, index: c_int) c_int {
    if (index > 0 or index <= c.LUA_REGISTRYINDEX) return index;
    return c.lua_gettop(lua_state) + index + 1;
}

fn expectType(lua_state: *c.lua_State, index: c_int, expected: c_int) !void {
    if (c.lua_type(lua_state, index) != expected) return error.UnexpectedLuaType;
}

fn dupeStringFromStack(lua_state: *c.lua_State, allocator: std.mem.Allocator, index: c_int) ![]const u8 {
    var len: usize = 0;
    const ptr = c.lua_tolstring(lua_state, index, &len) orelse return error.ExpectedLuaString;
    return try allocator.dupe(u8, ptr[0..len]);
}

fn pop(lua_state: *c.lua_State, count: c_int) void {
    c.lua_settop(lua_state, -count - 1);
}

fn failLuaCall(lua_state: *c.lua_State, err: []const u8) anyerror {
    var len: usize = 0;
    const message_ptr = c.lua_tolstring(lua_state, -1, &len);
    if (message_ptr) |message| std.log.scoped(.keywork_luajit).warn("{s}: {s}", .{ err, message[0..len] });
    pop(lua_state, 1);
    return error.LuaCallbackFailed;
}
