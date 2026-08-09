const std = @import("std");

test {
    std.testing.refAllDecls(@import("wayland/WayringDrmLease.zig"));
    std.testing.refAllDecls(@import("wayland/WayringOutputPower.zig"));
    std.testing.refAllDecls(@import("wayland/WayringGammaControl.zig"));
    std.testing.refAllDecls(@import("wayland/WayringLinuxDmabuf.zig"));
    std.testing.refAllDecls(@import("wayland/WayringScreencopy.zig"));
    std.testing.refAllDecls(@import("wayland/WayringFixes.zig"));
    std.testing.refAllDecls(@import("wayland/WayringSystemBell.zig"));
    std.testing.refAllDecls(@import("wayland/WayringAlphaModifier.zig"));
    std.testing.refAllDecls(@import("wayland/WayringColorRepresentation.zig"));
    std.testing.refAllDecls(@import("wayland/WayringTearingControl.zig"));
    std.testing.refAllDecls(@import("wayland/WayringSinglePixelBuffer.zig"));
    std.testing.refAllDecls(@import("wayland/WayringPointerWarp.zig"));
}
