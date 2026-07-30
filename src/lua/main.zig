//! Keywork LuaJIT application runtime.

const std = @import("std");
const cli = @import("host/cli.zig");
const Application = @import("host/Application.zig");
const storybook = @import("host/storybook.zig");
const testing = @import("host/testing.zig");

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
    const command = cli.parseCommand(init, allocator) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            var stderr_buffer: [256]u8 = undefined;
            var stderr = std.Io.File.stderr().writer(init.io, &stderr_buffer);
            stderr.interface.writeAll(cli.usage) catch {};
            stderr.interface.flush() catch {};
            std.process.exit(2);
        },
    };
    switch (command) {
        .run => |run_options| {
            defer allocator.free(run_options.app_args);
            var app = try Application.init(allocator, run_options.script_path);
            defer app.deinit();
            const runtime_directory = init.environ_map.get("XDG_RUNTIME_DIR") orelse
                return error.MissingRuntimeDirectory;
            try app.run(init.io, runtime_directory, run_options);
            log.debug("frame rendered", .{});
        },
        .storybook => |storybook_options| {
            var stdout_buffer: [4096]u8 = undefined;
            var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
            defer stdout.interface.flush() catch {};
            storybook.run(allocator, init.io, storybook_options, &stdout.interface) catch |err| {
                var stderr_buffer: [256]u8 = undefined;
                var stderr = std.Io.File.stderr().writer(init.io, &stderr_buffer);
                stderr.interface.print("storybook: {s}\n", .{@errorName(err)}) catch {};
                stderr.interface.flush() catch {};
                std.process.exit(1);
            };
        },
        .test_command => |test_options| {
            defer allocator.free(test_options.paths);
            var stdout_buffer: [4096]u8 = undefined;
            var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
            defer stdout.interface.flush() catch {};
            if (test_options.help) {
                try stdout.interface.writeAll(cli.test_usage);
                return;
            }
            const successful = testing.run(allocator, init.io, test_options, &stdout.interface) catch |err| {
                stdout.interface.flush() catch {};
                var stderr_buffer: [256]u8 = undefined;
                var stderr = std.Io.File.stderr().writer(init.io, &stderr_buffer);
                stderr.interface.print("test: {s}\n", .{@errorName(err)}) catch {};
                stderr.interface.flush() catch {};
                std.process.exit(1);
            };
            if (!successful) {
                stdout.interface.flush() catch {};
                std.process.exit(1);
            }
        },
    }
}

test {
    _ = @import("host/Application.zig");
    _ = @import("host/storybook.zig");
    _ = @import("host/testing.zig");
    _ = @import("keywork-lua");
}
