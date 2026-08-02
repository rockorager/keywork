//! Protocol-neutral selection source and change notification contracts.

const std = @import("std");

context: *anyopaque,
mime_types: *const fn (*anyopaque) []const []const u8,
send: *const fn (*anyopaque, []const u8, std.posix.fd_t) anyerror!void,
cancel: *const fn (*anyopaque) anyerror!void,

pub fn mimeTypes(self: *const @This()) []const []const u8 {
    return self.mime_types(self.context);
}

pub fn hasMime(self: *const @This(), mime_type: []const u8) bool {
    for (self.mimeTypes()) |offered| if (std.mem.eql(u8, offered, mime_type)) return true;
    return false;
}

pub const Listener = struct {
    context: *anyopaque,
    changed: *const fn (*anyopaque) void,
    offered: *const fn (*anyopaque, []const u8) void,
};
