//! Command-line parsing for the Keywork executable.

const std = @import("std");
const app_options = @import("options.zig");
const wayland_options = @import("../backend/wayland/options.zig");

pub const Options = struct {
    backend: ?app_options.BackendKind = null,
    width: ?f32 = null,
    height: ?f32 = null,
    script_path: []const u8 = "",
    layer_shell: ?wayland_options.LayerShellOptions = null,
    /// Arguments after the script path, forwarded verbatim to the Lua
    /// application via the `arg` global.
    app_args: []const [:0]const u8 = &.{},
};

pub const usage = "usage: keywork [options] <script.lua> [args...]\n";

pub fn parse(init: std.process.Init, allocator: std.mem.Allocator) !Options {
    var result: Options = .{};
    var app_args: std.ArrayList([:0]const u8) = .empty;
    errdefer app_args.deinit(allocator);
    var script_seen = false;
    var args = init.minimal.args.iterate();
    _ = args.skip();
    while (args.next()) |arg| {
        if (script_seen) {
            try app_args.append(allocator, arg);
        } else if (!std.mem.startsWith(u8, arg, "--")) {
            result.script_path = arg;
            script_seen = true;
        } else if (std.mem.eql(u8, arg, "--wayland")) {
            result.backend = .wayland_shm;
        } else if (std.mem.eql(u8, arg, "--backend=cpu")) {
            result.backend = .wayland_shm;
        } else if (std.mem.eql(u8, arg, "--backend=vulkan")) {
            result.backend = .vulkan;
        } else if (std.mem.eql(u8, arg, "--backend=log")) {
            result.backend = .log;
        } else if (std.mem.eql(u8, arg, "--layer-shell")) {
            if (result.layer_shell == null) result.layer_shell = .{};
        } else if (std.mem.startsWith(u8, arg, "--layer=")) {
            if (result.layer_shell == null) result.layer_shell = .{};
            result.layer_shell.?.layer = parseLayer(arg["--layer=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--anchor=")) {
            if (result.layer_shell == null) result.layer_shell = .{};
            result.layer_shell.?.anchors = parseAnchors(arg["--anchor=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--exclusive-zone=")) {
            if (result.layer_shell == null) result.layer_shell = .{};
            result.layer_shell.?.exclusive_zone = std.fmt.parseInt(i32, arg["--exclusive-zone=".len..], 10) catch result.layer_shell.?.exclusive_zone;
        } else if (std.mem.startsWith(u8, arg, "--keyboard=")) {
            if (result.layer_shell == null) result.layer_shell = .{};
            result.layer_shell.?.keyboard_interactivity = parseKeyboardInteractivity(arg["--keyboard=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--width=")) {
            result.width = std.fmt.parseFloat(f32, arg["--width=".len..]) catch result.width;
        } else if (std.mem.startsWith(u8, arg, "--height=")) {
            result.height = std.fmt.parseFloat(f32, arg["--height=".len..]) catch result.height;
        } else if (std.mem.startsWith(u8, arg, "--script=")) {
            result.script_path = arg["--script=".len..];
            script_seen = true;
        }
    }
    if (result.script_path.len == 0) return error.MissingScriptPath;
    result.app_args = try app_args.toOwnedSlice(allocator);
    return result;
}

fn parseLayer(value: []const u8) wayland_options.LayerShellOptions.Layer {
    if (std.mem.eql(u8, value, "background")) return .background;
    if (std.mem.eql(u8, value, "bottom")) return .bottom;
    if (std.mem.eql(u8, value, "overlay")) return .overlay;
    return .top;
}

fn parseAnchors(value: []const u8) wayland_options.LayerShellOptions.AnchorSet {
    var result: wayland_options.LayerShellOptions.AnchorSet = .{};
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |anchor| {
        if (std.mem.eql(u8, anchor, "top")) result.top = true;
        if (std.mem.eql(u8, anchor, "bottom")) result.bottom = true;
        if (std.mem.eql(u8, anchor, "left")) result.left = true;
        if (std.mem.eql(u8, anchor, "right")) result.right = true;
    }
    return result;
}

fn parseKeyboardInteractivity(value: []const u8) wayland_options.LayerShellOptions.KeyboardInteractivity {
    if (std.mem.eql(u8, value, "exclusive")) return .exclusive;
    if (std.mem.eql(u8, value, "on-demand") or std.mem.eql(u8, value, "on_demand")) return .on_demand;
    return .none;
}
