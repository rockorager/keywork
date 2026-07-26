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
    shadow_ambient: Color,
    shadow_key: Color,
    unfocused_border: Color,
    focused_border: Color,
    tiling_drag_preview: Color,
};

pub const Scheme = enum { light, dark };
pub const default_scheme: Scheme = .dark;

// Fluent neutralStroke2 keeps unfocused window edges quiet, while
// brandStroke1 gives the focused window and tiling preview clear emphasis.
pub const light: Palette = .{
    .desktop_background = rgb(0xfa, 0xfa, 0xfa),
    .shadow_ambient = rgba(0, 0, 0, 0x1f),
    .shadow_key = rgba(0, 0, 0, 0x24),
    .unfocused_border = rgb(0xe0, 0xe0, 0xe0),
    .focused_border = rgb(0x0f, 0x6c, 0xbd),
    .tiling_drag_preview = rgba(0x0f, 0x6c, 0xbd, 0x70),
};

pub const dark: Palette = .{
    .desktop_background = rgb(0x1f, 0x1f, 0x1f),
    .shadow_ambient = rgba(0, 0, 0, 0x3d),
    .shadow_key = rgba(0, 0, 0, 0x47),
    .unfocused_border = rgb(0x52, 0x52, 0x52),
    .focused_border = rgb(0x47, 0x9e, 0xf5),
    .tiling_drag_preview = rgba(0x47, 0x9e, 0xf5, 0x70),
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
    try std.testing.expectEqual(Color{ .red = 0xfa, .green = 0xfa, .blue = 0xfa }, light.desktop_background);
    try std.testing.expectEqual(Color{ .red = 0, .green = 0, .blue = 0, .alpha = 0x1f }, light.shadow_ambient);
    try std.testing.expectEqual(Color{ .red = 0, .green = 0, .blue = 0, .alpha = 0x24 }, light.shadow_key);
    try std.testing.expectEqual(Color{ .red = 0xe0, .green = 0xe0, .blue = 0xe0 }, light.unfocused_border);
    try std.testing.expectEqual(Color{ .red = 0x0f, .green = 0x6c, .blue = 0xbd }, light.focused_border);

    try std.testing.expectEqual(Color{ .red = 0x1f, .green = 0x1f, .blue = 0x1f }, dark.desktop_background);
    try std.testing.expectEqual(Color{ .red = 0, .green = 0, .blue = 0, .alpha = 0x3d }, dark.shadow_ambient);
    try std.testing.expectEqual(Color{ .red = 0, .green = 0, .blue = 0, .alpha = 0x47 }, dark.shadow_key);
    try std.testing.expectEqual(Color{ .red = 0x52, .green = 0x52, .blue = 0x52 }, dark.unfocused_border);
    try std.testing.expectEqual(Color{ .red = 0x47, .green = 0x9e, .blue = 0xf5 }, dark.focused_border);
    try std.testing.expectEqual(light, builtIn(.light));
    try std.testing.expectEqual(dark, builtIn(.dark));
    try std.testing.expectEqual(Scheme.dark, default_scheme);
    try std.testing.expectEqual(dark, default_palette);
}
