//! Vulkan-independent GPU timestamp query planning and duration conversion.

const std = @import("std");

const max_segments = 256;
pub const query_count = max_segments + 4;
const timestamp_frame_start = 0;
const timestamp_composition_start = 1;

pub const Timing = struct {
    tag: u64,
    total_nanoseconds: u64,
    composition_nanoseconds: u64,
    output_encode_nanoseconds: u64,
    frame_finish_nanoseconds: u64 = 0,
    pass_timings_available: bool = false,
    preparation_nanoseconds: u64 = 0,
    solid_composition_nanoseconds: u64 = 0,
    image_composition_nanoseconds: u64 = 0,
    shadow_nanoseconds: u64 = 0,
    blur_downsample_nanoseconds: u64 = 0,
    blur_upsample_nanoseconds: u64 = 0,
    blur_composite_nanoseconds: u64 = 0,
    composition_overhead_nanoseconds: u64 = 0,
};

pub const Category = enum {
    composition_overhead,
    solid_composition,
    image_composition,
    shadow,
    blur_downsample,
    blur_upsample,
    blur_composite,
};

pub const Plan = struct {
    pass_timings_available: bool = true,
    segment_count: u16 = 0,
    segments: [max_segments]Category = undefined,

    pub fn append(self: *Plan, category: Category) void {
        if (!self.pass_timings_available) return;
        if (self.segment_count > 0 and self.segments[self.segment_count - 1] == category) return;
        if (self.segment_count == max_segments) {
            self.pass_timings_available = false;
            self.segment_count = 1;
            self.segments[0] = .composition_overhead;
            return;
        }
        self.segments[self.segment_count] = category;
        self.segment_count += 1;
    }

    pub fn frameStartQuery(_: Plan) u32 {
        return timestamp_frame_start;
    }

    pub fn compositionStartQuery(_: Plan) u32 {
        return timestamp_composition_start;
    }

    pub fn compositionEndQuery(self: Plan) u32 {
        std.debug.assert(self.segment_count > 0);
        return @as(u32, self.segment_count) + 1;
    }

    pub fn outputEncodeEndQuery(self: Plan) u32 {
        return self.compositionEndQuery() + 1;
    }

    pub fn frameEndQuery(self: Plan) u32 {
        return self.outputEncodeEndQuery() + 1;
    }

    pub fn queryCount(self: Plan) u32 {
        return self.frameEndQuery() + 1;
    }
};

fn timestampTickDelta(start: u64, end: u64, valid_bits: u32) u64 {
    std.debug.assert(valid_bits > 0 and valid_bits <= 64);
    if (valid_bits == 64) return end -% start;
    const mask = (@as(u64, 1) << @intCast(valid_bits)) - 1;
    return ((end & mask) -% (start & mask)) & mask;
}

fn timestampNanoseconds(ticks: u64, period: f32) u64 {
    if (!(period > 0)) return 0;
    const nanoseconds = @as(f64, @floatFromInt(ticks)) * @as(f64, period);
    return std.math.lossyCast(u64, nanoseconds);
}

pub fn fromTimestamps(
    tag: u64,
    timestamps: []const u64,
    plan: Plan,
    valid_bits: u32,
    period: f32,
) Timing {
    std.debug.assert(timestamps.len == plan.queryCount());
    var timing: Timing = .{
        .tag = tag,
        .total_nanoseconds = timestampNanoseconds(timestampTickDelta(
            timestamps[timestamp_frame_start],
            timestamps[plan.frameEndQuery()],
            valid_bits,
        ), period),
        .composition_nanoseconds = timestampNanoseconds(timestampTickDelta(
            timestamps[timestamp_frame_start],
            timestamps[plan.compositionEndQuery()],
            valid_bits,
        ), period),
        .output_encode_nanoseconds = timestampNanoseconds(timestampTickDelta(
            timestamps[plan.compositionEndQuery()],
            timestamps[plan.outputEncodeEndQuery()],
            valid_bits,
        ), period),
        .frame_finish_nanoseconds = timestampNanoseconds(timestampTickDelta(
            timestamps[plan.outputEncodeEndQuery()],
            timestamps[plan.frameEndQuery()],
            valid_bits,
        ), period),
        .pass_timings_available = plan.pass_timings_available,
        .preparation_nanoseconds = if (plan.pass_timings_available)
            timestampNanoseconds(timestampTickDelta(
                timestamps[timestamp_frame_start],
                timestamps[timestamp_composition_start],
                valid_bits,
            ), period)
        else
            0,
    };
    if (!plan.pass_timings_available) return timing;
    for (plan.segments[0..plan.segment_count], 0..) |category, index| {
        const nanoseconds = timestampNanoseconds(timestampTickDelta(
            timestamps[timestamp_composition_start + index],
            timestamps[timestamp_composition_start + index + 1],
            valid_bits,
        ), period);
        switch (category) {
            .composition_overhead => timing.composition_overhead_nanoseconds +|= nanoseconds,
            .solid_composition => timing.solid_composition_nanoseconds +|= nanoseconds,
            .image_composition => timing.image_composition_nanoseconds +|= nanoseconds,
            .shadow => timing.shadow_nanoseconds +|= nanoseconds,
            .blur_downsample => timing.blur_downsample_nanoseconds +|= nanoseconds,
            .blur_upsample => timing.blur_upsample_nanoseconds +|= nanoseconds,
            .blur_composite => timing.blur_composite_nanoseconds +|= nanoseconds,
        }
    }
    return timing;
}

test "timestamp durations handle device counter wraparound" {
    try std.testing.expectEqual(@as(u64, 11), timestampTickDelta(250, 5, 8));
    try std.testing.expectEqual(
        @as(u64, 10),
        timestampTickDelta(std.math.maxInt(u64) - 4, 5, 64),
    );
    try std.testing.expectEqual(@as(u64, 16), timestampNanoseconds(11, 1.5));

    var plan: Plan = .{};
    plan.append(.composition_overhead);
    plan.append(.image_composition);
    plan.append(.composition_overhead);
    const timing = fromTimestamps(7, &.{ 250, 2, 4, 7, 9, 12, 15 }, plan, 8, 2);
    try std.testing.expectEqual(@as(u64, 7), timing.tag);
    try std.testing.expectEqual(@as(u64, 42), timing.total_nanoseconds);
    try std.testing.expectEqual(@as(u64, 30), timing.composition_nanoseconds);
    try std.testing.expectEqual(@as(u64, 6), timing.output_encode_nanoseconds);
    try std.testing.expectEqual(@as(u64, 6), timing.frame_finish_nanoseconds);
    try std.testing.expectEqual(@as(u64, 16), timing.preparation_nanoseconds);
    try std.testing.expectEqual(@as(u64, 6), timing.image_composition_nanoseconds);
    try std.testing.expectEqual(@as(u64, 8), timing.composition_overhead_nanoseconds);
}

test "GPU timing plan falls back to coarse timestamps when segment capacity is exceeded" {
    var plan: Plan = .{};
    for (0..max_segments + 1) |index| {
        plan.append(if (index % 2 == 0) .solid_composition else .image_composition);
    }
    try std.testing.expect(!plan.pass_timings_available);
    try std.testing.expectEqual(@as(u16, 1), plan.segment_count);
    try std.testing.expectEqual(@as(u32, 5), plan.queryCount());

    const timing = fromTimestamps(9, &.{ 10, 20, 30, 40, 50 }, plan, 64, 1);
    try std.testing.expectEqual(@as(u64, 40), timing.total_nanoseconds);
    try std.testing.expectEqual(@as(u64, 20), timing.composition_nanoseconds);
    try std.testing.expectEqual(@as(u64, 10), timing.output_encode_nanoseconds);
    try std.testing.expectEqual(@as(u64, 10), timing.frame_finish_nanoseconds);
    try std.testing.expect(!timing.pass_timings_available);
    try std.testing.expectEqual(@as(u64, 0), timing.preparation_nanoseconds);
}
