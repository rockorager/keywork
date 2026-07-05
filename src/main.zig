//! Keywork demo application consuming libkeywork.

const std = @import("std");
const keywork = @import("libkeywork");
const lua_app = @import("lua_app.zig");

pub const std_options: std.Options = .{
    .logFn = logWithTimestamp,
};

const log = std.log.scoped(.keywork);

fn logWithTimestamp(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const io = std.Options.debug_io;
    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);

    var buffer: [256]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();
    logWithTimestampTerminal(level, scope, format, args, stderr) catch {};
}

fn logWithTimestampTerminal(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
    terminal: std.Io.Terminal,
) std.Io.Writer.Error!void {
    const unix_ms = std.Io.Clock.now(.real, std.Options.debug_io).toMilliseconds();
    const seconds = @divTrunc(unix_ms, std.time.ms_per_s);
    const milliseconds = @mod(unix_ms, std.time.ms_per_s);

    terminal.setColor(.dim) catch {};
    try terminal.writer.print("{d}.", .{seconds});
    if (milliseconds < 100) try terminal.writer.writeByte('0');
    if (milliseconds < 10) try terminal.writer.writeByte('0');
    try terminal.writer.print("{d} ", .{milliseconds});

    terminal.setColor(switch (level) {
        .err => .red,
        .warn => .yellow,
        .info => .green,
        .debug => .magenta,
    }) catch {};
    terminal.setColor(.bold) catch {};
    try terminal.writer.writeAll(level.asText());
    terminal.setColor(.reset) catch {};
    terminal.setColor(.dim) catch {};
    terminal.setColor(.bold) catch {};
    if (scope != .default) try terminal.writer.print("({t})", .{scope});
    try terminal.writer.writeAll(": ");
    terminal.setColor(.reset) catch {};
    try terminal.writer.print(format ++ "\n", args);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const run_options = selectedRunOptions(init);
    var lua = try lua_app.App.init(allocator, run_options.script_path);
    defer lua.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    defer stdout_writer.interface.flush() catch {};

    try keywork.run(allocator, lua.host(), .{
        .title = if (run_options.backend == .vulkan) "Keywork MVP (Vulkan)" else "Keywork MVP",
        .width = run_options.width,
        .height = run_options.height,
        .backend = run_options.backend,
        .layer_shell = run_options.layer_shell,
        .log_writer = &stdout_writer.interface,
        .event_source_context = &lua,
        .install_event_sources = lua_app.App.installEventSources,
    });

    log.debug("frame rendered", .{});
}

const SelectedRunOptions = struct {
    backend: keywork.BackendKind = .log,
    width: f32 = 640,
    height: f32 = 480,
    script_path: []const u8 = "main.lua",
    layer_shell: ?keywork.LayerShellOptions = null,
};

fn selectedRunOptions(init: std.process.Init) SelectedRunOptions {
    var result: SelectedRunOptions = .{};
    var args = init.minimal.args.iterate();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--wayland")) {
            result.backend = .wayland_shm;
        } else if (std.mem.eql(u8, arg, "--backend=shm")) {
            result.backend = .wayland_shm;
        } else if (std.mem.eql(u8, arg, "--backend=vulkan")) {
            result.backend = .vulkan;
        } else if (std.mem.eql(u8, arg, "--layer-shell")) {
            if (result.backend == .log) result.backend = .wayland_shm;
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
        }
    }
    return result;
}

fn parseLayer(value: []const u8) keywork.LayerShellOptions.Layer {
    if (std.mem.eql(u8, value, "background")) return .background;
    if (std.mem.eql(u8, value, "bottom")) return .bottom;
    if (std.mem.eql(u8, value, "overlay")) return .overlay;
    return .top;
}

fn parseAnchors(value: []const u8) keywork.LayerShellOptions.AnchorSet {
    var result: keywork.LayerShellOptions.AnchorSet = .{};
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |anchor| {
        if (std.mem.eql(u8, anchor, "top")) result.top = true;
        if (std.mem.eql(u8, anchor, "bottom")) result.bottom = true;
        if (std.mem.eql(u8, anchor, "left")) result.left = true;
        if (std.mem.eql(u8, anchor, "right")) result.right = true;
    }
    return result;
}

fn parseKeyboardInteractivity(value: []const u8) keywork.LayerShellOptions.KeyboardInteractivity {
    if (std.mem.eql(u8, value, "exclusive")) return .exclusive;
    if (std.mem.eql(u8, value, "on-demand") or std.mem.eql(u8, value, "on_demand")) return .on_demand;
    return .none;
}
