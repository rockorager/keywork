//! Demand-driven animation primitives for the UI runtime.
//!
//! Time comes from an injectable monotonic clock sampled once per frame,
//! never from timer expirations or compositor callback timestamps, so
//! every animation in a frame sees the same `now` and tests can drive
//! frames deterministically with a fake clock.

const std = @import("std");

/// Injectable monotonic time source. The default reads CLOCK_MONOTONIC;
/// tests substitute a fake so frames advance deterministically.
pub const Clock = struct {
    ptr: ?*anyopaque = null,
    now_fn: ?*const fn (ptr: ?*anyopaque) u64 = null,

    /// Current monotonic time in nanoseconds.
    pub fn now(self: Clock) u64 {
        if (self.now_fn) |now_fn| return now_fn(self.ptr);
        return monotonicNow();
    }
};

pub fn monotonicNow() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// A one-shot normalized timeline: progress runs 0..1 over a fixed
/// duration measured in absolute monotonic time. Advancing past the end
/// clamps to 1 and deactivates, so the completion frame paints the exact
/// final value and registers no further demand.
pub const Timeline = struct {
    start_ns: u64 = 0,
    duration_ns: u64 = 0,
    active: bool = false,

    pub fn start(self: *Timeline, now_ns: u64, duration_ns: u64) void {
        std.debug.assert(duration_ns > 0);
        self.* = .{ .start_ns = now_ns, .duration_ns = duration_ns, .active = true };
    }

    pub fn stop(self: *Timeline) void {
        self.active = false;
    }

    /// Progress at `now_ns`, deactivating the timeline on completion.
    /// Inactive timelines report completion.
    pub fn advance(self: *Timeline, now_ns: u64) f32 {
        if (!self.active) return 1;
        const elapsed = now_ns -| self.start_ns;
        if (elapsed >= self.duration_ns) {
            self.active = false;
            return 1;
        }
        return @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(self.duration_ns));
    }
};

/// Normalized phase of a free-running repeating cycle: elapsed time modulo
/// the period, in 0..1.
pub fn repeatingPhase(start_ns: u64, now_ns: u64, period_ns: u64) f32 {
    std.debug.assert(period_ns > 0);
    const elapsed = (now_ns -| start_ns) % period_ns;
    return @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(period_ns));
}

// Curves are pure transforms of normalized progress, separate from
// timeline state, so they compose without touching clocks or scheduling.

pub fn easeOutCubic(t: f32) f32 {
    const clamped = std.math.clamp(t, 0, 1);
    const inverted = 1 - clamped;
    return 1 - inverted * inverted * inverted;
}

pub fn easeInOutCubic(t: f32) f32 {
    const clamped = std.math.clamp(t, 0, 1);
    if (clamped < 0.5) return 4 * clamped * clamped * clamped;
    const inverted = -2 * clamped + 2;
    return 1 - inverted * inverted * inverted / 2;
}

/// Scrollbar thumb reveal: full alpha for a hold period after scroll
/// activity, then an eased fade to invisible. One timeline covers hold
/// plus fade so retriggering activity restarts both.
pub const scrollbar_fade_hold_ms: u64 = 800;
pub const scrollbar_fade_duration_ms: u64 = 700;
pub const scrollbar_fade_total_ns: u64 = (scrollbar_fade_hold_ms + scrollbar_fade_duration_ms) * std.time.ns_per_ms;

/// Thumb alpha for a fade timeline progress in 0..1.
pub fn scrollbarFadeAlpha(progress: f32) f32 {
    const hold: f32 = @as(f32, @floatFromInt(scrollbar_fade_hold_ms)) /
        @as(f32, @floatFromInt(scrollbar_fade_hold_ms + scrollbar_fade_duration_ms));
    if (progress <= hold) return 1;
    const fade = (progress - hold) / (1 - hold);
    return 1 - easeOutCubic(fade);
}

test "timeline advances to completion and deactivates" {
    var timeline: Timeline = .{};
    try std.testing.expectEqual(@as(f32, 1), timeline.advance(0));

    timeline.start(1000, 500);
    try std.testing.expect(timeline.active);
    try std.testing.expectEqual(@as(f32, 0), timeline.advance(1000));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), timeline.advance(1250), 0.001);
    try std.testing.expect(timeline.active);

    // Completion clamps to the exact endpoint and drops demand.
    try std.testing.expectEqual(@as(f32, 1), timeline.advance(1500));
    try std.testing.expect(!timeline.active);
    try std.testing.expectEqual(@as(f32, 1), timeline.advance(2000));
}

test "timeline tolerates a clock sampled before its start" {
    var timeline: Timeline = .{};
    timeline.start(1000, 500);
    try std.testing.expectEqual(@as(f32, 0), timeline.advance(500));
    try std.testing.expect(timeline.active);
}

test "repeating phase wraps within the period" {
    try std.testing.expectEqual(@as(f32, 0), repeatingPhase(0, 0, 1000));
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), repeatingPhase(0, 250, 1000), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), repeatingPhase(0, 1250, 1000), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), repeatingPhase(100, 600, 1000), 0.001);
}

test "scrollbar fade holds then eases to invisible" {
    try std.testing.expectEqual(@as(f32, 1), scrollbarFadeAlpha(0));
    try std.testing.expectEqual(@as(f32, 1), scrollbarFadeAlpha(0.5));
    const mid = scrollbarFadeAlpha(0.87);
    try std.testing.expect(mid > 0 and mid < 1);
    try std.testing.expectApproxEqAbs(@as(f32, 0), scrollbarFadeAlpha(1), 0.001);
}

test "curves are clamped and hit their endpoints" {
    try std.testing.expectEqual(@as(f32, 0), easeOutCubic(-1));
    try std.testing.expectEqual(@as(f32, 1), easeOutCubic(2));
    try std.testing.expectApproxEqAbs(@as(f32, 1), easeInOutCubic(1), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), easeInOutCubic(0), 0.001);
}

test "default clock is monotonic" {
    const clock: Clock = .{};
    const first = clock.now();
    const second = clock.now();
    try std.testing.expect(second >= first);
    try std.testing.expect(first > 0);
}
