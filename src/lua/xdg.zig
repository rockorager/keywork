//! Native filesystem helpers backing the keywork.xdg Lua module: directory
//! creation, directory listing, and (atomic) file reads/writes so
//! applications can persist state without shelling out.

const std = @import("std");
const linux_syscall = @import("../linux/syscall.zig");
const lua_value = @import("value.zig");
const c = @import("luajit_c");

const linux = std.os.linux;

const pop = lua_value.pop;

pub const EntryKind = enum {
    file,
    dir,
    symlink,
    other,

    fn name(self: EntryKind) []const u8 {
        return switch (self) {
            .file => "file",
            .dir => "dir",
            .symlink => "symlink",
            .other => "other",
        };
    }
};

pub const DirEntry = struct {
    name: []u8,
    kind: EntryKind,
};

/// Creates `path` and any missing parents, like `mkdir -p`. Existing
/// directories (and the path itself already existing as a directory) are
/// not errors.
pub fn mkdirAll(path: []const u8) !void {
    if (path.len == 0) return error.InvalidPath;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buffer.len) return error.NameTooLong;
    @memcpy(buffer[0..path.len], path);
    buffer[path.len] = 0;

    var index: usize = 1; // A leading '/' is not a component.
    while (index <= path.len) : (index += 1) {
        if (index < path.len and buffer[index] != '/') continue;
        if (buffer[index - 1] == '/') continue; // Empty component ("//").
        const saved = buffer[index];
        buffer[index] = 0;
        defer buffer[index] = saved;
        const component: [*:0]const u8 = @ptrCast(&buffer);
        switch (linux.errno(linux.mkdirat(linux.AT.FDCWD, component, 0o755))) {
            .SUCCESS, .EXIST => {},
            .ACCES => return error.AccessDenied,
            .NOTDIR => return error.NotDir,
            .NOENT => return error.FileNotFound,
            else => return error.MkdirFailed,
        }
    }
}

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = try openFd(linux.openat(linux.AT.FDCWD, path_z.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0));
    defer _ = linux.close(fd);
    return linux_syscall.readAllAlloc(allocator, fd);
}

/// Replaces `path` atomically: the data lands in a same-directory
/// temporary file which is then renamed over the destination, so readers
/// never observe a partial write.
pub fn writeFileAtomic(allocator: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    var random_bytes: [8]u8 = undefined;
    if (linux.errno(linux.getrandom(&random_bytes, random_bytes.len, 0)) != .SUCCESS) {
        // getrandom is available since Linux 3.17; pid+monotonic time is
        // enough to avoid same-directory collisions if it ever fails.
        var timespec: linux.timespec = undefined;
        _ = linux.clock_gettime(.MONOTONIC, &timespec);
        const fallback: u64 = @as(u64, @intCast(linux.getpid())) ^ @as(u64, @bitCast(timespec.nsec));
        random_bytes = @bitCast(fallback);
    }
    const tmp_path = try std.fmt.allocPrintSentinel(allocator, "{s}.tmp-{x}", .{ path, @as(u64, @bitCast(random_bytes)) }, 0);
    defer allocator.free(tmp_path);

    const fd = try openFd(linux.openat(linux.AT.FDCWD, tmp_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, 0o666));
    var fd_open = true;
    defer if (fd_open) {
        _ = linux.close(fd);
    };
    errdefer _ = linux.unlinkat(linux.AT.FDCWD, tmp_path.ptr, 0);

    try writeAll(fd, data);
    if (linux.errno(linux.fsync(fd)) != .SUCCESS) return error.WriteFailed;
    _ = linux.close(fd);
    fd_open = false;

    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    if (linux.errno(linux.renameat(linux.AT.FDCWD, tmp_path.ptr, linux.AT.FDCWD, path_z.ptr)) != .SUCCESS) {
        return error.RenameFailed;
    }
}

pub fn writeFileTruncate(allocator: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = try openFd(linux.openat(linux.AT.FDCWD, path_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o666));
    defer _ = linux.close(fd);
    try writeAll(fd, data);
}

fn openFd(result: usize) !i32 {
    return switch (linux.errno(result)) {
        .SUCCESS => @intCast(result),
        .NOENT => error.FileNotFound,
        .ACCES => error.AccessDenied,
        else => error.OpenFailed,
    };
}

fn writeAll(fd: i32, data: []const u8) !void {
    var written: usize = 0;
    while (written < data.len) {
        const result = linux.write(fd, data.ptr + written, data.len - written);
        switch (linux.errno(result)) {
            .SUCCESS => written += result,
            .INTR => continue,
            else => return error.WriteFailed,
        }
    }
}

pub fn freeDirEntries(allocator: std.mem.Allocator, entries: []DirEntry) void {
    for (entries) |entry| allocator.free(entry.name);
    allocator.free(entries);
}

/// Lists a directory's entries (unsorted, without "." and "..").
pub fn readDirAlloc(allocator: std.mem.Allocator, path: []const u8) ![]DirEntry {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const open_result = linux.openat(linux.AT.FDCWD, path_z.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    switch (linux.errno(open_result)) {
        .SUCCESS => {},
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .ACCES => return error.AccessDenied,
        else => return error.OpenFailed,
    }
    const fd: i32 = @intCast(open_result);
    defer _ = linux.close(fd);

    var entries: std.ArrayList(DirEntry) = .empty;
    errdefer {
        for (entries.items) |entry| allocator.free(entry.name);
        entries.deinit(allocator);
    }

    var buffer: [8192]u8 align(@alignOf(linux.dirent64)) = undefined;
    while (true) {
        const result = linux.getdents64(fd, &buffer, buffer.len);
        switch (linux.errno(result)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.ReadFailed,
        }
        if (result == 0) break;
        var offset: usize = 0;
        while (offset < result) {
            const entry: *align(1) linux.dirent64 = @ptrCast(&buffer[offset]);
            defer offset += entry.reclen;
            const entry_name = std.mem.span(@as([*:0]u8, @ptrCast(&entry.name)));
            if (std.mem.eql(u8, entry_name, ".") or std.mem.eql(u8, entry_name, "..")) continue;
            const owned = try allocator.dupe(u8, entry_name);
            errdefer allocator.free(owned);
            try entries.append(allocator, .{
                .name = owned,
                .kind = entryKind(entry.type, fd, entry_name),
            });
        }
    }
    return entries.toOwnedSlice(allocator);
}

/// d_type when the filesystem reports it, fstatat otherwise (e.g. XFS
/// returns DT_UNKNOWN).
fn entryKind(d_type: u8, dir_fd: i32, entry_name: []const u8) EntryKind {
    switch (d_type) {
        linux.DT.REG => return .file,
        linux.DT.DIR => return .dir,
        linux.DT.LNK => return .symlink,
        linux.DT.UNKNOWN => {},
        else => return .other,
    }
    var name_buffer: [std.fs.max_name_bytes:0]u8 = undefined;
    if (entry_name.len > std.fs.max_name_bytes) return .other;
    @memcpy(name_buffer[0..entry_name.len], entry_name);
    name_buffer[entry_name.len] = 0;
    var stat: linux.Statx = undefined;
    const name_z: [*:0]const u8 = @ptrCast(&name_buffer);
    const result = linux.statx(dir_fd, name_z, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &stat);
    if (linux.errno(result) != .SUCCESS) return .other;
    return switch (stat.mode & linux.S.IFMT) {
        linux.S.IFREG => .file,
        linux.S.IFDIR => .dir,
        linux.S.IFLNK => .symlink,
        else => .other,
    };
}

/// Registers the native functions on the keywork.xdg module table. The
/// allocator pointer must outlive the Lua state.
pub fn installApi(lua_state: *c.lua_State, table: c_int, allocator: *const std.mem.Allocator) void {
    const target = lua_value.absoluteIndex(lua_state, table);
    const functions = [_]struct { name: [*:0]const u8, func: c.lua_CFunction }{
        .{ .name = "mkdir_all", .func = luaMkdirAll },
        .{ .name = "read_dir", .func = luaReadDir },
        .{ .name = "read_file", .func = luaReadFile },
        .{ .name = "write_file", .func = luaWriteFile },
    };
    for (functions) |function| {
        c.lua_pushlightuserdata(lua_state, @constCast(allocator));
        lua_value.setClosureField(lua_state, target, function.name, function.func, 1);
    }
}

fn upvalueAllocator(lua_state: *c.lua_State) std.mem.Allocator {
    return lua_value.upvaluePointer(*const std.mem.Allocator, lua_state, 1).*;
}

fn luaMkdirAll(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const path = lua_value.checkString(lua_state, 1);
    mkdirAll(path) catch |err| return lua_value.pushNilError(lua_state, err);
    c.lua_pushboolean(lua_state, 1);
    return 1;
}

fn luaReadDir(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const allocator = upvalueAllocator(lua_state);
    const path = lua_value.checkString(lua_state, 1);
    const entries = readDirAlloc(allocator, path) catch |err| return lua_value.pushNilError(lua_state, err);
    defer freeDirEntries(allocator, entries);

    c.lua_createtable(lua_state, @intCast(entries.len), 0);
    const list = c.lua_gettop(lua_state);
    for (entries, 1..) |entry, index| {
        c.lua_createtable(lua_state, 0, 2);
        lua_value.setStringField(lua_state, -1, "name", entry.name);
        const kind = entry.kind.name();
        lua_value.setStringField(lua_state, -1, "type", kind);
        c.lua_rawseti(lua_state, list, @intCast(index));
    }
    return 1;
}

fn luaReadFile(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const allocator = upvalueAllocator(lua_state);
    const path = lua_value.checkString(lua_state, 1);
    const data = readFileAlloc(allocator, path) catch |err| return lua_value.pushNilError(lua_state, err);
    defer allocator.free(data);
    c.lua_pushlstring(lua_state, data.ptr, data.len);
    return 1;
}

fn luaWriteFile(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const allocator = upvalueAllocator(lua_state);
    const path = lua_value.checkString(lua_state, 1);
    const data = lua_value.checkString(lua_state, 2);
    var atomic = true;
    if (c.lua_type(lua_state, 3) == c.LUA_TTABLE) {
        c.lua_getfield(lua_state, 3, "atomic");
        if (!c.lua_isnil(lua_state, -1)) atomic = c.lua_toboolean(lua_state, -1) != 0;
        pop(lua_state, 1);
    }
    const result = if (atomic)
        writeFileAtomic(allocator, path, data)
    else
        writeFileTruncate(allocator, path, data);
    result catch |err| return lua_value.pushNilError(lua_state, err);
    c.lua_pushboolean(lua_state, 1);
    return 1;
}

test "mkdirAll creates nested directories and tolerates existing ones" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;

    const base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer allocator.free(base);
    const nested = try std.fs.path.join(allocator, &.{ base, "a", "b", "c" });
    defer allocator.free(nested);

    try mkdirAll(nested);
    try mkdirAll(nested); // Idempotent.

    const entries = try readDirAlloc(allocator, nested);
    defer freeDirEntries(allocator, entries);
    try std.testing.expectEqual(@as(usize, 0), entries.len);
}

test "writeFileAtomic replaces content without leaving temp files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;

    const base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer allocator.free(base);
    const file_path = try std.fs.path.join(allocator, &.{ base, "state.txt" });
    defer allocator.free(file_path);

    try writeFileAtomic(allocator, file_path, "first");
    try writeFileAtomic(allocator, file_path, "second");

    const content = try readFileAlloc(allocator, file_path);
    defer allocator.free(content);
    try std.testing.expectEqualStrings("second", content);

    const entries = try readDirAlloc(allocator, base);
    defer freeDirEntries(allocator, entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("state.txt", entries[0].name);
    try std.testing.expectEqual(EntryKind.file, entries[0].kind);
}

test "readDirAlloc reports entry kinds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;

    const base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer allocator.free(base);
    const sub = try std.fs.path.join(allocator, &.{ base, "sub" });
    defer allocator.free(sub);
    const file_path = try std.fs.path.join(allocator, &.{ base, "file.desktop" });
    defer allocator.free(file_path);

    try mkdirAll(sub);
    try writeFileAtomic(allocator, file_path, "x");

    const entries = try readDirAlloc(allocator, base);
    defer freeDirEntries(allocator, entries);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, "sub")) {
            try std.testing.expectEqual(EntryKind.dir, entry.kind);
        } else {
            try std.testing.expectEqualStrings("file.desktop", entry.name);
            try std.testing.expectEqual(EntryKind.file, entry.kind);
        }
    }
}

test "readDirAlloc distinguishes missing from not-a-directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;

    const base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer allocator.free(base);
    const missing = try std.fs.path.join(allocator, &.{ base, "missing" });
    defer allocator.free(missing);
    const file_path = try std.fs.path.join(allocator, &.{ base, "plain" });
    defer allocator.free(file_path);
    try writeFileAtomic(allocator, file_path, "x");

    try std.testing.expectError(error.FileNotFound, readDirAlloc(allocator, missing));
    try std.testing.expectError(error.NotDir, readDirAlloc(allocator, file_path));
}
