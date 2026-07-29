//! Protocol-neutral controller for managed Xwayland windows.

const XwaylandController = @This();

const Xwm = @import("../xwayland/xwm.zig");

context: *anyopaque,
window_info: *const fn (*anyopaque, Xwm.WindowId) ?Xwm.WindowInfo,
resize: *const fn (*anyopaque, Xwm.WindowId, u16, u16) bool,
move: *const fn (*anyopaque, Xwm.WindowId, i16, i16) bool,
set_fullscreen: *const fn (*anyopaque, Xwm.WindowId, bool) void,
set_maximized: *const fn (*anyopaque, Xwm.WindowId, bool) void,
set_minimized: *const fn (*anyopaque, Xwm.WindowId, bool) void,
close: *const fn (*anyopaque, Xwm.WindowId) void,
refresh_scene: *const fn (*anyopaque, Xwm.WindowId) void,
stacking_changed: *const fn (*anyopaque) void,
