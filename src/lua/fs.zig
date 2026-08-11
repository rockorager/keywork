//! Awaitable native filesystem operations for `keywork.fs`.

const std = @import("std");
const event_loop = @import("keywork-loop");
const lua_coro = @import("coro.zig");
const lua_task = @import("task.zig");
const lua_value = @import("value.zig");
const c = @import("luajit_c");

const linux = std.os.linux;

pub const Host = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        allocator: *const fn (*anyopaque) std.mem.Allocator,
        luaState: *const fn (*anyopaque) *c.lua_State,
        eventLoop: *const fn (*anyopaque) ?*event_loop.EventLoop,
        addOperation: *const fn (*anyopaque, Kind, []const u8, ?[]const u8, bool, c_int) anyerror!*FsOperation,
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
    fn addOperation(self: Host, kind: Kind, path: []const u8, extra: ?[]const u8, option: bool, waiter_ref: c_int) !*FsOperation {
        return self.vtable.addOperation(self.ptr, kind, path, extra, option, waiter_ref);
    }
};

pub const Kind = enum { read, write, list, mkdir, stat, remove, rename };
const Stage = enum { start, opened, reading, writing, syncing, closing, renaming, removing, listing_stat, mkdir_next, done };
const Entry = struct { name: []u8, kind: EntryKind };
const EntryKind = enum { file, dir, symlink, other };

pub const FsOperation = struct {
    allocator: std.mem.Allocator,
    host: Host,
    kind: Kind,
    stage: Stage = .start,
    path: [:0]u8,
    extra: ?[:0]u8 = null,
    scratch_path: ?[:0]u8 = null,
    option: bool,
    waiter_ref: c_int,
    operation: ?*event_loop.EventLoop.Operation = null,
    fd: i32 = -1,
    offset: usize = 0,
    data: std.ArrayList(u8) = .empty,
    entries: std.ArrayList(Entry) = .empty,
    unknown_index: usize = 0,
    stat_buf: linux.Statx = undefined,
    canceled: bool = false,
    terminal: bool = false,
    detached: bool = false,
    storage_released: bool = false,

    pub fn init(host: Host, kind: Kind, path: []const u8, extra: ?[]const u8, option: bool, waiter_ref: c_int) !FsOperation {
        const allocator = host.allocator();
        const path_z = try allocator.dupeZ(u8, path);
        errdefer allocator.free(path_z);
        const extra_z = if (kind == .rename) try allocator.dupeZ(u8, extra.?) else null;
        errdefer if (extra_z) |value| allocator.free(value);
        var self: FsOperation = .{ .allocator = allocator, .host = host, .kind = kind, .path = path_z, .extra = extra_z, .option = option, .waiter_ref = waiter_ref };
        errdefer self.data.deinit(allocator);
        if (kind == .write) try self.data.appendSlice(allocator, extra.?);
        return self;
    }

    pub fn start(self: *FsOperation) !void {
        const loop = self.host.eventLoop() orelse return error.EventLoopNotBound;
        self.operation = try loop.addOperation(self, completion, operationDestroyed);
        try self.submitStart(loop);
    }

    fn submitStart(self: *FsOperation, loop: *event_loop.EventLoop) !void {
        const op = self.operation.?;
        switch (self.kind) {
            .read => try loop.submitOpenAt(op, linux.AT.FDCWD, self.path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0),
            .write => {
                if (self.option) {
                    var random: [8]u8 = @bitCast(@as(u64, @intCast(linux.getpid())));
                    _ = linux.getrandom(&random, random.len, 0);
                    const temp = try std.fmt.allocPrintSentinel(self.host.allocator(), "{s}.tmp-{x}", .{ self.path, @as(u64, @bitCast(random)) }, 0);
                    self.extra = temp;
                }
                const target = if (self.option) self.extra.?.ptr else self.path.ptr;
                try loop.submitOpenAt(op, linux.AT.FDCWD, target, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = self.option, .TRUNC = !self.option, .CLOEXEC = true }, 0o666);
            },
            .list => try loop.submitOpenAt(op, linux.AT.FDCWD, self.path.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0),
            .mkdir => {
                self.offset = if (!self.option) self.path.len else if (self.path.len > 0 and self.path[0] == '/') 1 else 0;
                try self.submitMkdir(loop);
            },
            .stat => try loop.submitStatx(op, linux.AT.FDCWD, self.path, 0, .{ .TYPE = true, .SIZE = true, .MTIME = true }, &self.stat_buf),
            .remove => try loop.submitUnlinkAt(op, linux.AT.FDCWD, self.path.ptr, if (self.option) linux.AT.REMOVEDIR else 0),
            .rename => try loop.submitRenameAt(op, linux.AT.FDCWD, self.path.ptr, linux.AT.FDCWD, self.extra.?.ptr, 0),
        }
    }

    fn submitMkdir(self: *FsOperation, loop: *event_loop.EventLoop) !void {
        if (!self.option) return loop.submitMkdirAt(self.operation.?, linux.AT.FDCWD, self.path.ptr, 0o755);
        while (self.offset < self.path.len and self.path[self.offset] == '/') self.offset += 1;
        if (self.offset >= self.path.len) self.offset = self.path.len else while (self.offset < self.path.len and self.path[self.offset] != '/') self.offset += 1;
        std.debug.assert(self.scratch_path == null);
        self.scratch_path = try self.allocator.dupeZ(u8, self.path[0..self.offset]);
        self.stage = .mkdir_next;
        try loop.submitMkdirAt(self.operation.?, linux.AT.FDCWD, self.scratch_path.?.ptr, 0o755);
    }

    pub fn cancel(self: *FsOperation, lua_state: *c.lua_State, mode: lua_coro.CancelMode) void {
        if (self.canceled or self.terminal) return;
        self.canceled = true;
        if (self.host.eventLoop()) |loop| if (self.operation) |op| loop.removeOperation(op);
        if (self.waiter_ref < 0) return;
        switch (mode) {
            .silent => {
                c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, self.waiter_ref);
                self.waiter_ref = -1;
            },
            .resume_reader => self.resumeError("canceled"),
        }
    }

    pub fn destroy(self: *FsOperation, allocator: std.mem.Allocator, lua_state: *c.lua_State) void {
        self.cancel(lua_state, .silent);
        if (self.operation != null) {
            // The App can die before the ring. Keep the kernel-facing context
            // alive until the original completion (or ring teardown).
            self.detached = true;
            return;
        }
        self.releaseStorage();
        allocator.destroy(self);
    }

    fn operationDestroyed(_: std.mem.Allocator, ctx: *anyopaque) void {
        const self: *FsOperation = @ptrCast(@alignCast(ctx));
        const operation = self.operation.?;
        if (operation.result) |result| {
            if (result >= 0 and self.stage == .start and (self.kind == .read or self.kind == .write or self.kind == .list)) {
                _ = linux.close(result);
            } else if (self.stage == .closing and result != -@as(i32, @intFromEnum(linux.E.CANCELED))) {
                self.fd = -1;
            }
        }
        self.operation = null;
        self.releaseStorage();
        if (self.detached) self.allocator.destroy(self);
    }

    fn releaseStorage(self: *FsOperation) void {
        if (self.storage_released) return;
        self.storage_released = true;
        const allocator = self.allocator;
        if (self.fd >= 0) _ = linux.close(self.fd);
        if (self.option and self.kind == .write and self.extra != null and !self.terminal) _ = linux.unlinkat(linux.AT.FDCWD, self.extra.?.ptr, 0);
        allocator.free(self.path);
        if (self.extra) |value| allocator.free(value);
        if (self.scratch_path) |value| allocator.free(value);
        self.data.deinit(allocator);
        for (self.entries.items) |entry| allocator.free(entry.name);
        self.entries.deinit(allocator);
    }

    fn completion(ctx: *anyopaque, loop: *event_loop.EventLoop, _: *event_loop.EventLoop.Operation, result: i32) anyerror!void {
        const self: *FsOperation = @ptrCast(@alignCast(ctx));
        self.advance(loop, result) catch |err| self.fail(loop, @errorName(err));
    }

    fn advance(self: *FsOperation, loop: *event_loop.EventLoop, result: i32) !void {
        // Once a close request completes, Linux owns consumption of the fd
        // even when filp_close reports an error. Do not close that numeric fd
        // again after another thread may have reused it.
        if (self.stage == .closing) self.fd = -1;
        if (result < 0) {
            const errno: linux.E = @enumFromInt(@as(u16, @intCast(-result)));
            if (self.kind == .mkdir and self.option and errno == .EXIST) return self.mkdirDone(loop);
            // Directory entry classification is best-effort. The entry may
            // disappear between getdents64 and statx, or metadata lookup may
            // be denied even though enumeration succeeded. Preserve it as
            // `other`, matching the previous synchronous API, and continue.
            if (self.kind == .list and self.stage == .listing_stat) {
                self.host.allocator().free(self.scratch_path.?);
                self.scratch_path = null;
                self.unknown_index += 1;
                return self.statNextUnknown(loop);
            }
            return self.fail(loop, errnoMessage(errno));
        }
        switch (self.kind) {
            .read => try self.advanceRead(loop, result),
            .write => try self.advanceWrite(loop, result),
            .list => try self.advanceList(loop, result),
            .mkdir => self.mkdirDone(loop),
            .stat => self.finishStat(loop),
            .remove, .rename => self.finishOk(loop),
        }
    }

    fn advanceRead(self: *FsOperation, loop: *event_loop.EventLoop, result: i32) !void {
        if (self.stage == .start) {
            self.fd = result;
            self.stage = .reading;
            return self.submitRead(loop);
        }
        if (self.stage == .reading) {
            if (result > 0) {
                self.offset += @intCast(result);
                self.data.items.len = self.offset;
                return self.submitRead(loop);
            }
            self.stage = .closing;
            return loop.submitClose(self.operation.?, self.fd);
        }
        self.fd = -1;
        self.finishData(loop);
    }

    fn submitRead(self: *FsOperation, loop: *event_loop.EventLoop) !void {
        const allocator = self.host.allocator();
        try self.data.ensureUnusedCapacity(allocator, 16384);
        self.data.items.len = self.offset + 16384;
        try loop.submitRead(self.operation.?, self.fd, .{ .buffer = self.data.items[self.offset..] }, self.offset);
    }

    fn advanceWrite(self: *FsOperation, loop: *event_loop.EventLoop, result: i32) !void {
        if (self.stage == .start) {
            self.fd = result;
            self.stage = .writing;
            return self.submitWrite(loop);
        }
        if (self.stage == .writing) {
            if (result == 0 and self.offset < self.data.items.len) return error.WriteFailed;
            self.offset += @intCast(result);
            if (self.offset < self.data.items.len) return self.submitWrite(loop);
            if (self.option) {
                self.stage = .syncing;
                return loop.submitFsync(self.operation.?, self.fd, 0);
            }
            self.stage = .closing;
            return loop.submitClose(self.operation.?, self.fd);
        }
        if (self.stage == .syncing) {
            self.stage = .closing;
            return loop.submitClose(self.operation.?, self.fd);
        }
        if (self.stage == .closing) {
            self.fd = -1;
            if (self.option) {
                self.stage = .renaming;
                return loop.submitRenameAt(self.operation.?, linux.AT.FDCWD, self.extra.?.ptr, linux.AT.FDCWD, self.path.ptr, 0);
            }
            return self.finishOk(loop);
        }
        self.finishOk(loop);
    }

    fn submitWrite(self: *FsOperation, loop: *event_loop.EventLoop) !void {
        if (self.offset == self.data.items.len) {
            self.stage = if (self.option) .syncing else .closing;
            return if (self.option) loop.submitFsync(self.operation.?, self.fd, 0) else loop.submitClose(self.operation.?, self.fd);
        }
        try loop.submitWrite(self.operation.?, self.fd, self.data.items[self.offset..], self.offset);
    }

    fn advanceList(self: *FsOperation, loop: *event_loop.EventLoop, result: i32) !void {
        if (self.stage == .start) {
            self.fd = result;
            self.stage = .opened;
            try self.readEntries();
            return self.statNextUnknown(loop);
        }
        if (self.stage == .listing_stat) {
            self.host.allocator().free(self.scratch_path.?);
            self.scratch_path = null;
            self.entries.items[self.unknown_index].kind = kindFromMode(self.stat_buf.mode);
            self.unknown_index += 1;
            return self.statNextUnknown(loop);
        }
        self.fd = -1;
        self.finishEntries(loop);
    }

    fn readEntries(self: *FsOperation) !void {
        var buffer: [8192]u8 align(@alignOf(linux.dirent64)) = undefined;
        while (true) {
            const n = linux.getdents64(self.fd, &buffer, buffer.len);
            switch (linux.errno(n)) {
                .SUCCESS => {},
                .INTR => continue,
                else => return error.ReadFailed,
            }
            if (n == 0) return;
            var offset: usize = 0;
            while (offset < n) {
                const dirent: *align(1) linux.dirent64 = @ptrCast(&buffer[offset]);
                offset += dirent.reclen;
                const name = std.mem.span(@as([*:0]u8, @ptrCast(&dirent.name)));
                if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
                const owned_name = try self.host.allocator().dupe(u8, name);
                errdefer self.host.allocator().free(owned_name);
                try self.entries.append(self.host.allocator(), .{ .name = owned_name, .kind = kindFromType(dirent.type) });
            }
        }
    }

    fn statNextUnknown(self: *FsOperation, loop: *event_loop.EventLoop) !void {
        while (self.unknown_index < self.entries.items.len and self.entries.items[self.unknown_index].kind != .other) self.unknown_index += 1;
        if (self.unknown_index == self.entries.items.len) {
            self.stage = .closing;
            return loop.submitClose(self.operation.?, self.fd);
        }
        self.scratch_path = try self.host.allocator().dupeZ(u8, self.entries.items[self.unknown_index].name);
        self.stage = .listing_stat;
        try loop.submitStatx(self.operation.?, self.fd, self.scratch_path.?, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &self.stat_buf);
    }

    fn mkdirDone(self: *FsOperation, loop: *event_loop.EventLoop) void {
        if (self.scratch_path) |path| {
            self.allocator.free(path);
            self.scratch_path = null;
        }
        if (self.option and self.offset < self.path.len) {
            self.offset += 1;
            self.submitMkdir(loop) catch |err| self.fail(loop, @errorName(err));
            return;
        }
        self.finishOk(loop);
    }

    fn finishData(self: *FsOperation, loop: *event_loop.EventLoop) void {
        c.lua_pushlstring(self.host.luaState(), self.data.items.ptr, self.offset);
        self.finish(loop, 1);
    }
    fn finishEntries(self: *FsOperation, loop: *event_loop.EventLoop) void {
        const state = self.host.luaState();
        c.lua_createtable(state, @intCast(self.entries.items.len), 0);
        for (self.entries.items, 1..) |entry, index| {
            c.lua_createtable(state, 0, 2);
            lua_value.setStringField(state, -1, "name", entry.name);
            lua_value.setStringField(state, -1, "type", @tagName(entry.kind));
            c.lua_rawseti(state, -2, @intCast(index));
        }
        self.finish(loop, 1);
    }
    fn finishStat(self: *FsOperation, loop: *event_loop.EventLoop) void {
        const state = self.host.luaState();
        c.lua_createtable(state, 0, 4);
        lua_value.setStringField(state, -1, "type", @tagName(kindFromMode(self.stat_buf.mode)));
        lua_value.setIntegerField(state, -1, "size", @intCast(self.stat_buf.size));
        lua_value.setIntegerField(state, -1, "mtime_sec", self.stat_buf.mtime.sec);
        lua_value.setIntegerField(state, -1, "mtime_nsec", self.stat_buf.mtime.nsec);
        self.finish(loop, 1);
    }
    fn finishOk(self: *FsOperation, loop: *event_loop.EventLoop) void {
        c.lua_pushboolean(self.host.luaState(), 1);
        self.finish(loop, 1);
    }
    fn fail(self: *FsOperation, loop: *event_loop.EventLoop, message: []const u8) void {
        if (self.fd >= 0) {
            _ = linux.close(self.fd);
            self.fd = -1;
        }
        if (self.option and self.kind == .write and self.extra != null) _ = linux.unlinkat(linux.AT.FDCWD, self.extra.?.ptr, 0);
        const state = self.host.luaState();
        c.lua_pushnil(state);
        c.lua_pushlstring(state, message.ptr, message.len);
        self.finish(loop, 2);
    }
    fn finish(self: *FsOperation, loop: *event_loop.EventLoop, nargs: c_int) void {
        self.terminal = true;
        if (self.operation) |op| loop.removeOperation(op);
        if (self.waiter_ref >= 0) lua_coro.resumeReaderWith(self.host.luaState(), &self.waiter_ref, nargs);
    }
    fn resumeError(self: *FsOperation, message: []const u8) void {
        const state = self.host.luaState();
        c.lua_pushnil(state);
        c.lua_pushlstring(state, message.ptr, message.len);
        lua_coro.resumeReaderWith(state, &self.waiter_ref, 2);
    }
};

fn kindFromType(value: u8) EntryKind {
    return switch (value) {
        linux.DT.REG => .file,
        linux.DT.DIR => .dir,
        linux.DT.LNK => .symlink,
        else => .other,
    };
}
fn kindFromMode(mode: u16) EntryKind {
    return switch (mode & linux.S.IFMT) {
        linux.S.IFREG => .file,
        linux.S.IFDIR => .dir,
        linux.S.IFLNK => .symlink,
        else => .other,
    };
}
fn errnoMessage(errno: linux.E) []const u8 {
    return switch (errno) {
        .NOENT => "FileNotFound",
        .NOTDIR => "NotDir",
        .ACCES, .PERM => "AccessDenied",
        .EXIST => "AlreadyExists",
        .NOTEMPTY => "NotEmpty",
        else => @tagName(errno),
    };
}

pub fn pushModule(lua_state: *c.lua_State, host: *Host) void {
    c.lua_createtable(lua_state, 0, 7);
    inline for (.{ .{ "read", Kind.read }, .{ "write", Kind.write }, .{ "list", Kind.list }, .{ "mkdir", Kind.mkdir }, .{ "stat", Kind.stat }, .{ "remove", Kind.remove }, .{ "rename", Kind.rename } }) |item| {
        c.lua_pushlightuserdata(lua_state, host);
        c.lua_pushinteger(lua_state, @intFromEnum(item[1]));
        lua_value.setClosureField(lua_state, -3, item[0], luaOperation, 2);
    }
}

fn luaOperation(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const state = lua_state_optional.?;
    if (lua_coro.onMainThread(state)) return c.luaL_error(state, "filesystem operations must be called from a coroutine (wrap the caller in loop.spawn)");
    const host = lua_value.upvaluePointer(*Host, state, 1);
    if (host.eventLoop() == null) return c.luaL_error(state, "filesystem operation requires a bound event loop");
    const kind: Kind = @enumFromInt(c.lua_tointeger(state, c.lua_upvalueindex(2)));
    const path = lua_value.checkString(state, 1);
    var extra: ?[]const u8 = null;
    var option = kind == .write;
    if (kind == .write or kind == .rename) extra = lua_value.checkString(state, 2);
    const options_index: c_int = if (kind == .write) 3 else 2;
    if (kind == .write or kind == .mkdir or kind == .remove) if (c.lua_istable(state, options_index)) {
        const field: [*:0]const u8 = switch (kind) {
            .write => "atomic",
            .mkdir => "parents",
            .remove => "directory",
            else => unreachable,
        };
        c.lua_getfield(state, options_index, field);
        if (!c.lua_isnil(state, -1)) option = c.lua_toboolean(state, -1) != 0;
        c.lua_settop(state, -2);
    };
    const waiter_ref = lua_coro.refCurrentThread(state);
    const resource = host.addOperation(kind, path, extra, option, waiter_ref) catch |err| {
        return lua_value.pushNilError(state, err);
    };
    lua_task.adoptResource(FsOperation, state, resource);
    return c.lua_yield(state, 0);
}
