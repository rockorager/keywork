//! Declarative window-set contract between the runner and the app host.
//!
//! The app declares which windows should exist for its current state;
//! the runner diffs those declarations against live surfaces by id,
//! creating and destroying windows to match. Null declaration fields
//! inherit the runner's app-level defaults, so a simple single-window
//! app declares only an id.

const std = @import("std");
const keywork = @import("../ui.zig");
const wayland_options = @import("../backend/wayland/options.zig");

pub const WindowDeclaration = struct {
    id: []const u8,
    title: ?[:0]const u8 = null,
    width: ?f32 = null,
    height: ?f32 = null,
    /// Let a layer-shell surface use the retained root child's laid-out
    /// height. Normal xdg-toplevel windows do not support this policy.
    content_height: bool = false,
    layer_shell: ?wayland_options.LayerShellOptions = null,
    /// Output name (e.g. "DP-1") the window should appear on; null lets
    /// the compositor choose.
    output: ?[]const u8 = null,
};

/// App-level build input for the window set: everything a script needs
/// to decide which windows exist, before any window does.
pub const WindowsContext = struct {
    outputs: []const wayland_options.OutputInfo = &.{},
    color_scheme: []const u8 = "no-preference",
};

pub const WindowsHost = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Returns the window set for the app's current state. Results
        /// (slice, ids, titles) are allocated from `allocator`, which the
        /// caller owns (typically an arena discarded after reconciling).
        build_windows: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, context: WindowsContext) anyerror![]WindowDeclaration,
        /// Builds the widget tree for the window declared with `id`.
        build_window_widget: *const fn (ptr: *anyopaque, id: []const u8, scope: *keywork.BuildScope, context: keywork.AppContext) anyerror!keywork.Widget,
        /// Notifies the host after the compositor closes a managed window.
        window_closed: *const fn (ptr: *anyopaque, id: []const u8) anyerror!void,
    };

    pub fn buildWindows(self: WindowsHost, allocator: std.mem.Allocator, context: WindowsContext) ![]WindowDeclaration {
        return self.vtable.build_windows(self.ptr, allocator, context);
    }

    pub fn buildWindowWidget(self: WindowsHost, id: []const u8, scope: *keywork.BuildScope, context: keywork.AppContext) !keywork.Widget {
        return self.vtable.build_window_widget(self.ptr, id, scope, context);
    }

    pub fn windowClosed(self: WindowsHost, id: []const u8) !void {
        try self.vtable.window_closed(self.ptr, id);
    }
};
