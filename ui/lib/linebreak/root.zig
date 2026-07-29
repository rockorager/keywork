//! Unicode 17.0.0 default UAX #14 line breaking.
const std = @import("std");
const uucode = @import("uucode");
const rules = @import("rules.zig");

pub const Break = struct {
    end: usize,
    mandatory: bool,
    /// The break is forced by a hard-break code point in the input rather
    /// than by the end of the input.
    hard: bool = false,
};

/// Input must be valid UTF-8. Invalid input is rejected by `init`.
pub const Iterator = struct {
    input: []const u8,
    pos: usize = 0,
    state: rules.LineStepState = undefined,
    primed: bool = false,
    empty_pending: bool = false,

    pub fn init(input: []const u8) error{InvalidUtf8}!Iterator {
        if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;
        return .{ .input = input, .empty_pending = input.len == 0 };
    }

    pub fn next(self: *Iterator) ?Break {
        if (self.empty_pending) {
            self.empty_pending = false;
            return .{ .end = 0, .mandatory = true };
        }
        if (self.pos >= self.input.len) return null;
        if (!self.primed) {
            const len = std.unicode.utf8ByteSequenceLength(self.input[0]) catch unreachable;
            const cp = std.unicode.utf8Decode(self.input[0..len]) catch unreachable;
            self.state = .init(cp);
            self.primed = true;
        }
        var cursor = self.pos;
        const first_len = std.unicode.utf8ByteSequenceLength(self.input[cursor]) catch unreachable;
        cursor += first_len;
        while (cursor < self.input.len) {
            const decision = rules.lineStepBytes(self.state, self.input, cursor);
            self.state = decision.new_state;
            if (decision.kind != .prohibited) {
                self.pos = cursor;
                const mandatory = decision.kind == .mandatory;
                return .{ .end = cursor, .mandatory = mandatory, .hard = mandatory };
            }
            cursor += decision.consumed;
        }
        self.pos = self.input.len;
        return .{
            .end = self.input.len,
            .mandatory = true,
            .hard = rules.endsWithHardBreak(self.state),
        };
    }
};

test "uucode custom fields and basic boundaries" {
    try std.testing.expectEqual(@as(@TypeOf(uucode.get(.line_break, 0)), .al), uucode.get(.line_break, 'A'));
    _ = uucode.get(.grapheme_break, 0x0301);
    var it = try Iterator.init("a b");
    try std.testing.expectEqual(Break{ .end = 2, .mandatory = false }, it.next().?);
    try std.testing.expectEqual(Break{ .end = 3, .mandatory = true }, it.next().?);
}

test "empty and CRLF" {
    var empty = try Iterator.init("");
    try std.testing.expectEqual(Break{ .end = 0, .mandatory = true }, empty.next().?);
    var crlf = try Iterator.init("\r\nX");
    try std.testing.expectEqual(Break{ .end = 2, .mandatory = true, .hard = true }, crlf.next().?);
    try std.testing.expectEqual(Break{ .end = 3, .mandatory = true }, crlf.next().?);
    var trailing = try Iterator.init("X\n");
    try std.testing.expectEqual(Break{ .end = 2, .mandatory = true, .hard = true }, trailing.next().?);
}

test "Unicode 17 LineBreakTest" {
    var lines = std.mem.splitScalar(u8, @embedFile("data/LineBreakTest.txt"), '\n');
    var passed: usize = 0;
    while (lines.next()) |raw| {
        const content = if (std.mem.indexOfScalar(u8, raw, '#')) |i| raw[0..i] else raw;
        if (std.mem.trim(u8, content, " \t\r").len == 0) continue;
        var bytes: [512]u8 = undefined;
        var expected: [128]usize = undefined;
        var bytes_len: usize = 0;
        var expected_len: usize = 0;
        var tokens = std.mem.tokenizeAny(u8, content, " \t\r");
        while (tokens.next()) |token| {
            if (std.mem.eql(u8, token, "÷")) {
                expected[expected_len] = bytes_len;
                expected_len += 1;
            } else if (!std.mem.eql(u8, token, "×")) {
                const cp = try std.fmt.parseInt(u21, token, 16);
                bytes_len += try std.unicode.utf8Encode(cp, bytes[bytes_len..]);
            }
        }
        // LB2's start marker is not emitted by the public iterator.
        var expected_i: usize = 0;
        var it = try Iterator.init(bytes[0..bytes_len]);
        while (it.next()) |brk| {
            try std.testing.expectEqual(expected[expected_i], brk.end);
            expected_i += 1;
        }
        try std.testing.expectEqual(expected_len, expected_i);
        passed += 1;
    }
    try std.testing.expectEqual(@as(usize, 19338), passed);
}
