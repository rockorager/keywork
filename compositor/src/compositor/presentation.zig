//! Renderer-independent output presentation timing.

const std = @import("std");

pub const monotonic_clock_id: u32 = @intCast(@intFromEnum(std.posix.CLOCK.MONOTONIC));
pub const nominal_refresh_nanoseconds: u32 = @intCast(std.time.ns_per_s / 60);

pub const Timestamp = struct {
    seconds: u64,
    nanoseconds: u32,

    pub fn fromNanoseconds(value: i96) Timestamp {
        std.debug.assert(value >= 0);
        return .{
            .seconds = @intCast(@divTrunc(value, std.time.ns_per_s)),
            .nanoseconds = @intCast(@mod(value, std.time.ns_per_s)),
        };
    }

    pub fn toNanoseconds(self: Timestamp) i96 {
        return @as(i96, self.seconds) * std.time.ns_per_s + self.nanoseconds;
    }

    pub fn highSeconds(self: Timestamp) u32 {
        return @truncate(self.seconds >> 32);
    }

    pub fn lowSeconds(self: Timestamp) u32 {
        return @truncate(self.seconds);
    }

    pub fn milliseconds(self: Timestamp) u32 {
        const seconds: u32 = @truncate(self.seconds);
        return seconds *% 1000 +% self.nanoseconds / std.time.ns_per_ms;
    }
};

pub const Flags = packed struct(u32) {
    vsync: bool = false,
    hardware_clock: bool = false,
    hardware_completion: bool = false,
    zero_copy: bool = false,
    _padding: u28 = 0,
};

pub const Info = struct {
    timestamp: Timestamp,
    refresh_nanoseconds: u32,
    sequence: u64 = 0,
    flags: Flags = .{},

    pub fn now(io: std.Io) Info {
        return .{
            .timestamp = .fromNanoseconds(std.Io.Clock.awake.now(io).nanoseconds),
            .refresh_nanoseconds = nominal_refresh_nanoseconds,
        };
    }

    pub fn highSequence(self: Info) u32 {
        return @truncate(self.sequence >> 32);
    }

    pub fn lowSequence(self: Info) u32 {
        return @truncate(self.sequence);
    }

    pub fn refreshMillihertz(self: Info) u32 {
        if (self.refresh_nanoseconds == 0) return 0;
        const numerator: u64 = std.time.ns_per_s * 1000;
        return @intCast(@min(
            (numerator + self.refresh_nanoseconds / 2) / self.refresh_nanoseconds,
            std.math.maxInt(u32),
        ));
    }
};

test "presentation timestamps split protocol fields and wrap frame time" {
    const timestamp: Timestamp = .{
        .seconds = 0x1234_5678_9abc_def0,
        .nanoseconds = 345_678_901,
    };
    try std.testing.expectEqual(@as(u32, 0x1234_5678), timestamp.highSeconds());
    try std.testing.expectEqual(@as(u32, 0x9abc_def0), timestamp.lowSeconds());
    try std.testing.expectEqual(
        @as(u32, @truncate(timestamp.seconds)) *% 1000 +% 345,
        timestamp.milliseconds(),
    );
}

test "presentation timestamp converts monotonic nanoseconds" {
    const nanoseconds = 12_345_678_901;
    const timestamp = Timestamp.fromNanoseconds(nanoseconds);
    try std.testing.expectEqual(Timestamp{ .seconds = 12, .nanoseconds = 345_678_901 }, timestamp);
    try std.testing.expectEqual(@as(i96, nanoseconds), timestamp.toNanoseconds());
}

test "presentation refresh converts to output millihertz" {
    const info: Info = .{
        .timestamp = .{ .seconds = 0, .nanoseconds = 0 },
        .refresh_nanoseconds = 16_666_667,
    };
    try std.testing.expectEqual(@as(u32, 60_000), info.refreshMillihertz());

    var variable_refresh = info;
    variable_refresh.refresh_nanoseconds = 0;
    try std.testing.expectEqual(@as(u32, 0), variable_refresh.refreshMillihertz());

    var implausibly_fast = info;
    implausibly_fast.refresh_nanoseconds = 1;
    try std.testing.expectEqual(std.math.maxInt(u32), implausibly_fast.refreshMillihertz());
}
