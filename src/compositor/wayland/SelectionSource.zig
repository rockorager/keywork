//! Protocol-neutral selection source callbacks.

const SelectionSource = @This();

const std = @import("std");

context: *anyopaque,
mime_types: *const fn (*anyopaque) []const [:0]const u8,
send: *const fn (*anyopaque, [*:0]const u8, std.posix.fd_t) void,
cancel: *const fn (*anyopaque) void,

pub fn hasMime(self: *const SelectionSource, mime_type: [*:0]const u8) bool {
    const value = std.mem.span(mime_type);
    for (self.mime_types(self.context)) |candidate| {
        if (std.mem.eql(u8, candidate, value)) return true;
    }
    return false;
}

test "MIME matching is exact" {
    const Fixture = struct {
        fn types(_: *anyopaque) []const [:0]const u8 {
            return &.{ "text/plain", "text/html" };
        }
        fn send(_: *anyopaque, _: [*:0]const u8, _: std.posix.fd_t) void {}
        fn cancel(_: *anyopaque) void {}
    };
    var context: u8 = 0;
    const source: SelectionSource = .{
        .context = &context,
        .mime_types = Fixture.types,
        .send = Fixture.send,
        .cancel = Fixture.cancel,
    };
    try std.testing.expect(source.hasMime("text/plain"));
    try std.testing.expect(!source.hasMime("text"));
}
