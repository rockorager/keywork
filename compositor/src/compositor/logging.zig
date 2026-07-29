//! Runtime filtering for compositor log messages.

const std = @import("std");
const control = @import("keywork-control");

var maximum_level: std.atomic.Value(control.LogLevel) = .init(defaultLevel());

pub fn defaultLevel() control.LogLevel {
    return switch (std.log.default_level) {
        .err => .@"error",
        .warn => .warning,
        .info => .info,
        .debug => .debug,
    };
}

pub fn setLevel(level: control.LogLevel) void {
    maximum_level.store(level, .monotonic);
}

pub fn enabled(message_level: std.log.Level) bool {
    return switch (maximum_level.load(.monotonic)) {
        .@"error" => message_level == .err,
        .warning => @intFromEnum(message_level) <= @intFromEnum(std.log.Level.warn),
        .info => @intFromEnum(message_level) <= @intFromEnum(std.log.Level.info),
        .debug => true,
    };
}

pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (enabled(message_level)) std.log.defaultLog(message_level, scope, format, args);
}
