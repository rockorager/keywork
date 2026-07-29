//! Shared handling for raw Linux syscall return values.

const std = @import("std");

const linux = std.os.linux;

pub fn fd(result: usize) !i32 {
    return switch (linux.errno(result)) {
        .SUCCESS => @intCast(result),
        else => error.LinuxSyscallFailed,
    };
}

pub fn check(result: usize) !void {
    return switch (linux.errno(result)) {
        .SUCCESS => {},
        else => error.LinuxSyscallFailed,
    };
}

pub fn setNonblocking(file_descriptor: i32) !void {
    const flags = try fd(linux.fcntl(file_descriptor, linux.F.GETFL, 0));
    try check(linux.fcntl(file_descriptor, linux.F.SETFL, @as(usize, @intCast(flags)) | linux.SOCK.NONBLOCK));
}

pub fn readAllAlloc(allocator: std.mem.Allocator, file_descriptor: i32) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    while (true) {
        try list.ensureUnusedCapacity(allocator, 4096);
        const dest = list.unusedCapacitySlice();
        const read_result = linux.read(file_descriptor, dest.ptr, dest.len);
        switch (linux.errno(read_result)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.ReadFailed,
        }
        if (read_result == 0) return list.toOwnedSlice(allocator);
        list.items.len += read_result;
    }
}
