//! Allocation-independent record of a client's first terminal failure.

const Fatal = @This();

const std = @import("std");
const wire = @import("../wire.zig");

pub const max_detail_len = 256;

pub const Kind = enum {
    malformed_wire,
    protocol,
    implementation,
    out_of_memory,
    peer_disconnect,
};

pub const Details = struct {
    kind: Kind,
    object_id: u32 = 0,
    opcode: ?u16 = null,
    protocol_code: ?u32 = null,
    interface: ?*const wire.Interface = null,
    message: ?*const wire.MessageDescriptor = null,
    detail: []const u8 = "",
};

recorded: bool = false,
kind: Kind = .implementation,
object_id: u32 = 0,
opcode: ?u16 = null,
protocol_code: ?u32 = null,
interface: ?*const wire.Interface = null,
message: ?*const wire.MessageDescriptor = null,
detail_buffer: [max_detail_len]u8 = undefined,
detail_len: u16 = 0,
detail_truncated: bool = false,

/// Records the first failure without allocating. Later failures cannot hide
/// the cause that began client shutdown.
pub fn record(self: *Fatal, details: Details) bool {
    if (self.recorded) return false;
    self.recorded = true;
    self.kind = details.kind;
    self.object_id = details.object_id;
    self.opcode = details.opcode;
    self.protocol_code = details.protocol_code;
    self.interface = details.interface;
    self.message = details.message;
    const len = @min(details.detail.len, self.detail_buffer.len);
    @memcpy(self.detail_buffer[0..len], details.detail[0..len]);
    self.detail_len = @intCast(len);
    self.detail_truncated = details.detail.len > len;
    return true;
}

pub fn detail(self: *const Fatal) []const u8 {
    return self.detail_buffer[0..self.detail_len];
}

test "first fatal wins and long details are deterministically truncated" {
    const interface: wire.Interface = .{ .name = "test", .version = 1 };
    const message: wire.MessageDescriptor = .{ .name = "break", .arguments = &.{} };
    var fatal: Fatal = .{};
    const long_detail = "x" ** (max_detail_len + 10);

    try std.testing.expect(fatal.record(.{
        .kind = .protocol,
        .object_id = 42,
        .opcode = 3,
        .protocol_code = 7,
        .interface = &interface,
        .message = &message,
        .detail = long_detail,
    }));
    try std.testing.expectEqual(Kind.protocol, fatal.kind);
    try std.testing.expectEqual(@as(u32, 42), fatal.object_id);
    try std.testing.expectEqual(@as(usize, max_detail_len), fatal.detail().len);
    try std.testing.expect(fatal.detail_truncated);
    try std.testing.expect(!fatal.record(.{ .kind = .out_of_memory, .detail = "later" }));
    try std.testing.expectEqual(Kind.protocol, fatal.kind);
    try std.testing.expectEqualSlices(u8, long_detail[0..max_detail_len], fatal.detail());
}
