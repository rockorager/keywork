//! Shared validation and reading of wlr gamma-control table file descriptors.

const std = @import("std");

pub fn read(
    io: std.Io,
    allocator: std.mem.Allocator,
    fd: std.posix.fd_t,
    gamma_size: u32,
) error{ OutOfMemory, InvalidGamma, ReadGammaFailed }![]u16 {
    const value_count = std.math.mul(usize, gamma_size, 3) catch
        return error.InvalidGamma;
    const byte_count = std.math.mul(usize, value_count, @sizeOf(u16)) catch
        return error.InvalidGamma;
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    const stat = file.stat(io) catch return error.ReadGammaFailed;
    if (stat.kind != .file or stat.size != byte_count) return error.InvalidGamma;
    const table = allocator.alloc(u16, value_count) catch return error.OutOfMemory;
    errdefer allocator.free(table);
    const bytes = std.mem.sliceAsBytes(table);
    const bytes_read = file.readPositionalAll(io, bytes, 0) catch
        return error.ReadGammaFailed;
    if (bytes_read != bytes.len) return error.InvalidGamma;
    return table;
}
