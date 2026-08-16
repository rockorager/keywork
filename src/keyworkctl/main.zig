//! Top-level namespace and compatibility routing for the Keywork control CLI.

const std = @import("std");
const application = @import("application.zig");
const compositor = @import("keyworkctl-compositor");

const usage =
    \\usage: keyworkctl NAMESPACE COMMAND [ARGUMENT...]
    \\
    \\namespaces: app, compositor
    \\
    \\Compositor commands are also accepted without the namespace for compatibility.
    \\
;

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        if (err == error.Reported) std.process.exit(2);
        if (err == error.RemoteError) std.process.exit(1);
        var buffer: [1024]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(init.io, &buffer);
        stderr.interface.print("keyworkctl: {t}\n", .{err}) catch {};
        stderr.interface.flush() catch {};
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    var iterator = try init.minimal.args.iterateAllocator(init.gpa);
    defer iterator.deinit();
    _ = iterator.next();
    var arguments: std.ArrayList([]const u8) = .empty;
    defer arguments.deinit(init.gpa);
    while (iterator.next()) |argument| try arguments.append(init.gpa, argument);
    return route(init, arguments.items);
}

fn route(init: std.process.Init, arguments: []const []const u8) !void {
    if (arguments.len == 0) return reportUsage(init.io, error.InvalidArguments, usage);
    if (arguments.len == 1 and std.mem.eql(u8, arguments[0], "--help")) {
        return writeUsage(init.io, usage);
    }

    if (std.mem.eql(u8, arguments[0], "app")) {
        if (arguments.len == 2 and std.mem.eql(u8, arguments[1], "--help")) {
            return writeUsage(init.io, application.usage);
        }
        application.run(init, arguments[1..]) catch |err| {
            if (err == error.InvalidArguments or err == error.UnknownCommand or err == error.InvalidInstance) {
                return reportUsage(init.io, err, application.usage);
            }
            return err;
        };
        return;
    }

    const compositor_arguments = if (std.mem.eql(u8, arguments[0], "compositor")) blk: {
        if (arguments.len == 2 and std.mem.eql(u8, arguments[1], "--help")) {
            return writeUsage(init.io, compositor.usage);
        }
        break :blk arguments[1..];
    } else arguments;
    compositor.run(init, compositor_arguments) catch |err| {
        if (isCommandError(err)) return reportUsage(init.io, err, compositor.usage);
        return err;
    };
}

fn isCommandError(err: anyerror) bool {
    return switch (err) {
        error.InvalidArguments,
        error.InvalidWorkspace,
        error.InvalidDirection,
        error.InvalidWindowTarget,
        error.InvalidLayout,
        error.InvalidLogLevel,
        error.InvalidBorderWidth,
        error.InvalidColor,
        error.InvalidHeadlessOutputMode,
        error.UnknownCommand,
        => true,
        else => false,
    };
}

fn writeUsage(io: std.Io, text: []const u8) !void {
    var buffer: [2048]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    defer stdout.interface.flush() catch {};
    try stdout.interface.writeAll(text);
}

fn reportUsage(io: std.Io, err: anyerror, text: []const u8) anyerror {
    var buffer: [2048]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buffer);
    defer stderr.interface.flush() catch {};
    stderr.interface.print("keyworkctl: {t}\n{s}", .{ err, text }) catch {};
    return error.Reported;
}

test "top-level help names application and compositor namespaces" {
    try std.testing.expect(std.mem.indexOf(u8, usage, "compositor") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "app") != null);
}

test "invalid headless output mode is a compositor command error" {
    try std.testing.expect(isCommandError(error.InvalidHeadlessOutputMode));
}
