//! Protocol-neutral ICCCM and EWMH window metadata policy.

const std = @import("std");

pub const Size = struct {
    width: i32 = 0,
    height: i32 = 0,
};

pub const WindowType = enum {
    desktop,
    dock,
    toolbar,
    menu,
    utility,
    splash,
    dialog,
    dropdown_menu,
    popup_menu,
    tooltip,
    notification,
    combo,
    dnd,
    normal,

    pub fn participatesInWindowManagement(self: WindowType) bool {
        return switch (self) {
            .normal, .dialog, .utility, .toolbar, .menu => true,
            .desktop,
            .dock,
            .splash,
            .dropdown_menu,
            .popup_menu,
            .tooltip,
            .notification,
            .combo,
            .dnd,
            => false,
        };
    }
};

pub fn defaultWindowType(override_redirect: bool, transient: bool) WindowType {
    return if (!override_redirect and transient) .dialog else .normal;
}

pub fn preventsOverrideRedirectFocus(window_type: WindowType) bool {
    return switch (window_type) {
        .menu,
        .utility,
        .splash,
        .dropdown_menu,
        .popup_menu,
        .tooltip,
        .notification,
        .combo,
        .dnd,
        => true,
        .desktop, .dock, .toolbar, .dialog, .normal => false,
    };
}

/// `hints` must contain the five fields of a Motif WM hints property.
pub fn motifPrefersServerDecorations(hints: []const u32) ?bool {
    std.debug.assert(hints.len >= 5);
    const decorations_valid = hints[0] & (1 << 1) != 0;
    if (!decorations_valid) return null;
    const decorations = hints[2];
    if (decorations & (1 << 0) != 0) return true;
    return decorations & (1 << 1) != 0 and decorations & (1 << 3) != 0;
}

pub fn validSizeHint(width: i32, height: i32) Size {
    return .{
        .width = if (width > 0) width else 0,
        .height = if (height > 0) height else 0,
    };
}

test "EWMH window type fallback follows transient and override-redirect rules" {
    try std.testing.expectEqual(WindowType.normal, defaultWindowType(false, false));
    try std.testing.expectEqual(WindowType.dialog, defaultWindowType(false, true));
    try std.testing.expectEqual(WindowType.normal, defaultWindowType(true, false));
    try std.testing.expectEqual(WindowType.normal, defaultWindowType(true, true));
}

test "EWMH auxiliary window types bypass toplevel policy" {
    try std.testing.expect(WindowType.normal.participatesInWindowManagement());
    try std.testing.expect(WindowType.dialog.participatesInWindowManagement());
    try std.testing.expect(WindowType.utility.participatesInWindowManagement());
    try std.testing.expect(!WindowType.desktop.participatesInWindowManagement());
    try std.testing.expect(!WindowType.dock.participatesInWindowManagement());
    try std.testing.expect(!WindowType.splash.participatesInWindowManagement());
    try std.testing.expect(!WindowType.tooltip.participatesInWindowManagement());
    try std.testing.expect(!WindowType.notification.participatesInWindowManagement());
    try std.testing.expect(!WindowType.dnd.participatesInWindowManagement());
}

test "override-redirect input heuristic excludes transient UI types" {
    try std.testing.expect(!preventsOverrideRedirectFocus(.normal));
    try std.testing.expect(!preventsOverrideRedirectFocus(.dialog));
    try std.testing.expect(preventsOverrideRedirectFocus(.menu));
    try std.testing.expect(preventsOverrideRedirectFocus(.utility));
    try std.testing.expect(preventsOverrideRedirectFocus(.splash));
    try std.testing.expect(preventsOverrideRedirectFocus(.dropdown_menu));
    try std.testing.expect(preventsOverrideRedirectFocus(.popup_menu));
    try std.testing.expect(preventsOverrideRedirectFocus(.tooltip));
    try std.testing.expect(preventsOverrideRedirectFocus(.notification));
    try std.testing.expect(preventsOverrideRedirectFocus(.combo));
    try std.testing.expect(preventsOverrideRedirectFocus(.dnd));
}

test "Motif hints reduce partial decorations to client-side decoration" {
    try std.testing.expectEqual(null, motifPrefersServerDecorations(&.{ 0, 0, 0, 0, 0 }));
    try std.testing.expectEqual(true, motifPrefersServerDecorations(&.{ 2, 0, 1, 0, 0 }));
    try std.testing.expectEqual(true, motifPrefersServerDecorations(&.{ 2, 0, 10, 0, 0 }));
    try std.testing.expectEqual(false, motifPrefersServerDecorations(&.{ 2, 0, 0, 0, 0 }));
    try std.testing.expectEqual(false, motifPrefersServerDecorations(&.{ 2, 0, 2, 0, 0 }));
    try std.testing.expectEqual(false, motifPrefersServerDecorations(&.{ 2, 0, 8, 0, 0 }));
}

test "ICCCM size hints discard non-positive dimensions independently" {
    try std.testing.expectEqual(Size{ .width = 640, .height = 480 }, validSizeHint(640, 480));
    try std.testing.expectEqual(Size{ .width = 0, .height = 480 }, validSizeHint(-1, 480));
    try std.testing.expectEqual(Size{ .width = 640, .height = 0 }, validSizeHint(640, 0));
}
