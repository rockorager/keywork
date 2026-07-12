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
