//! Desktop appearance values shared by platform services and public APIs.

const std = @import("std");

pub const ColorScheme = enum(c_int) {
    no_preference = 0,
    dark = 1,
    light = 2,

    pub fn name(self: ColorScheme) []const u8 {
        return switch (self) {
            .no_preference => "no-preference",
            .dark => "dark",
            .light => "light",
        };
    }
};

pub fn fromPortalValue(value: u32) ?ColorScheme {
    return switch (value) {
        0 => .no_preference,
        1 => .dark,
        2 => .light,
        else => null,
    };
}

test "portal color schemes map only specified values" {
    try std.testing.expectEqual(ColorScheme.no_preference, fromPortalValue(0).?);
    try std.testing.expectEqual(ColorScheme.dark, fromPortalValue(1).?);
    try std.testing.expectEqual(ColorScheme.light, fromPortalValue(2).?);
    try std.testing.expect(fromPortalValue(3) == null);
}
