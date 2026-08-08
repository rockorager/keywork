const std = @import("std");

test {
    std.testing.refAllDecls(@import("wayland/WayringLinuxDmabuf.zig"));
    std.testing.refAllDecls(@import("wayland/WayringScreencopy.zig"));
}
