//! Keywork LuaJIT application runtime.

const std = @import("std");
const keywork = @import("ui.zig");
const cli = @import("app/cli.zig");
const app_options = @import("app/options.zig");
const runner = @import("app/runner.zig");
const lua_module = @import("lua/app.zig");

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
    const run_options = try cli.parse(init, allocator);
    defer allocator.free(run_options.app_args);
    var lua = try lua_module.App.init(allocator, run_options.script_path);
    defer lua.deinit();
    lua.setScriptArgs(run_options.app_args);
    // Run the script now so keywork.window declarations can shape the
    // window. CLI flags override the script; the script overrides
    // built-in defaults.
    try lua.ensureLoaded();
    const window = lua.window_config;

    const layer_shell = run_options.layer_shell orelse window.layer_shell;
    const backend = run_options.backend orelse window.backend orelse
        // A layer-shell surface is useless on the log backend, so
        // requesting one implies the cpu backend unless a backend was
        // chosen explicitly.
        if (layer_shell != null) app_options.BackendKind.wayland_shm else .log;
    const title: [:0]const u8 = window.title orelse
        if (backend == .vulkan) "Keywork MVP (Vulkan)" else "Keywork MVP";

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    defer stdout_writer.interface.flush() catch {};

    try runner.run(allocator, lua.host(), .{
        .title = title,
        .app_id = window.app_id orelse "dev.keywork.Keywork",
        .width = run_options.width orelse window.width orelse 640,
        .height = run_options.height orelse window.height orelse 480,
        .backend = backend,
        .layer_shell = layer_shell,
        .log_writer = &stdout_writer.interface,
        .event_source_context = &lua,
        .install_event_sources = lua_module.App.installEventSources,
    });

    log.debug("frame rendered", .{});
}

test {
    _ = @import("app/runner.zig");
    _ = @import("lua/app.zig");
}
