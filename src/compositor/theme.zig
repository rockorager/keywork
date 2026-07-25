//! Built-in colors for compositor-owned UI.
//!
//! The light and dark palettes resolve the small set of semantic colors the
//! compositor consumes. Prefer selects a scheme but never supplies colors.

const std = @import("std");

pub const Color = struct {
    red: u8,
    green: u8,
    blue: u8,
    alpha: u8 = 0xff,
};

pub const Palette = struct {
    desktop_background: Color,
    unfocused_border: Color,
    focused_border: Color,
    tiling_drag_preview: Color,
};

pub const Scheme = enum { light, dark };
pub const default_scheme: Scheme = .dark;

// Radix Colors v3 Slate 1 and 6 provide the neutral roles. Blue 9 gives the
// light focus indicator enough contrast; dark mode uses the less intense Blue 8.
pub const light: Palette = .{
    .desktop_background = rgb(0xfc, 0xfc, 0xfd),
    .unfocused_border = rgb(0xd9, 0xd9, 0xe0),
    .focused_border = rgb(0x00, 0x90, 0xff),
    .tiling_drag_preview = rgba(0x00, 0x90, 0xff, 0x70),
};

pub const dark: Palette = .{
    .desktop_background = rgb(0x11, 0x11, 0x13),
    .unfocused_border = rgb(0x36, 0x3a, 0x3f),
    .focused_border = rgb(0x28, 0x70, 0xbd),
    .tiling_drag_preview = rgba(0x28, 0x70, 0xbd, 0x70),
};

/// The compositor remains dark until a preference service selects a scheme.
pub const default_palette = dark;

pub fn builtIn(scheme: Scheme) Palette {
    return switch (scheme) {
        .light => light,
        .dark => dark,
    };
}

fn rgb(red: u8, green: u8, blue: u8) Color {
    return .{ .red = red, .green = green, .blue = blue };
}

fn rgba(red: u8, green: u8, blue: u8, alpha: u8) Color {
    return .{ .red = red, .green = green, .blue = blue, .alpha = alpha };
}

test "built-in palettes resolve Keywork semantic colors" {
    try std.testing.expectEqual(Color{ .red = 0xfc, .green = 0xfc, .blue = 0xfd }, light.desktop_background);
    try std.testing.expectEqual(Color{ .red = 0xd9, .green = 0xd9, .blue = 0xe0 }, light.unfocused_border);
    try std.testing.expectEqual(Color{ .red = 0x00, .green = 0x90, .blue = 0xff }, light.focused_border);

    try std.testing.expectEqual(Color{ .red = 0x11, .green = 0x11, .blue = 0x13 }, dark.desktop_background);
    try std.testing.expectEqual(Color{ .red = 0x36, .green = 0x3a, .blue = 0x3f }, dark.unfocused_border);
    try std.testing.expectEqual(Color{ .red = 0x28, .green = 0x70, .blue = 0xbd }, dark.focused_border);
    try std.testing.expectEqual(light, builtIn(.light));
    try std.testing.expectEqual(dark, builtIn(.dark));
    try std.testing.expectEqual(Scheme.dark, default_scheme);
    try std.testing.expectEqual(dark, default_palette);
}
