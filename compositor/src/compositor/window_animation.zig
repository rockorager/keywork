//! Renderer-independent geometry, timing, and snapshot lifecycle for tiling transitions.

const WindowAnimation = @This();

const std = @import("std");
const render = @import("render/types.zig");

// Fluent UI React durationUltraFast, durationFaster, and durationFast.
pub const fade_duration_nanoseconds: u64 = 50 * std.time.ns_per_ms;
pub const fast_duration_nanoseconds: u64 = 100 * std.time.ns_per_ms;
pub const normal_duration_nanoseconds: u64 = 150 * std.time.ns_per_ms;
pub const target_wait_nanoseconds: u64 = 100 * std.time.ns_per_ms;

pub const Easing = enum {
    entrance,
    existing,
    exit,
};

pub const Rect = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

pub fn linearProgress(start: i96, now: i96, duration: u64) u32 {
    if (now <= start) return 0;
    const elapsed: u128 = @intCast(now - start);
    if (elapsed >= duration) return std.math.maxInt(u32);
    return @intCast((elapsed * std.math.maxInt(u32)) / duration);
}

pub fn progress(start: i96, now: i96, duration: u64, easing: Easing) u32 {
    return ease(linearProgress(start, now, duration), easing);
}

pub fn contentProgress(start: i96, now: i96, duration: u64) u32 {
    const fade_duration = @min(duration, fade_duration_nanoseconds);
    const offset = (duration - fade_duration) / 2;
    return linearProgress(start + @as(i96, @intCast(offset)), now, fade_duration);
}

pub fn appearanceProgress(start: i96, now: i96) u32 {
    return linearProgress(start, now, fade_duration_nanoseconds);
}

pub fn disappearanceProgress(start: i96, now: i96, duration: u64) u32 {
    const fade_duration = @min(duration, fade_duration_nanoseconds);
    return linearProgress(
        start + @as(i96, @intCast(duration - fade_duration)),
        now,
        fade_duration,
    );
}

pub fn reflowDuration(old: Rect, target: Rect) u64 {
    const delta = @max(
        @abs(@as(i64, target.x) - old.x),
        @abs(@as(i64, target.y) - old.y),
        @abs(@as(i64, target.width) - old.width),
        @abs(@as(i64, target.height) - old.height),
    );
    return if (delta >= 96) normal_duration_nanoseconds else fast_duration_nanoseconds;
}

pub fn ease(linear: u32, easing: Easing) u32 {
    return switch (easing) {
        .entrance => cubicBezier(linear, 0, 0, 0, 1),
        .existing => cubicBezier(linear, 0.55, 0.55, 0, 1),
        .exit => cubicBezier(linear, 1, 0, 1, 1),
    };
}

fn cubicBezier(linear: u32, x1: f64, y1: f64, x2: f64, y2: f64) u32 {
    if (linear == 0 or linear == std.math.maxInt(u32)) return linear;
    const maximum: f64 = @floatFromInt(std.math.maxInt(u32));
    const target_x = @as(f64, @floatFromInt(linear)) / maximum;
    var lower: f64 = 0;
    var upper: f64 = 1;
    var parameter: f64 = target_x;
    for (0..24) |_| {
        const x = bezierCoordinate(parameter, x1, x2);
        if (x < target_x) lower = parameter else upper = parameter;
        parameter = (lower + upper) / 2;
    }
    const value = std.math.clamp(bezierCoordinate(parameter, y1, y2), 0, 1);
    return @intFromFloat(@round(value * maximum));
}

fn bezierCoordinate(parameter: f64, first: f64, second: f64) f64 {
    const remaining = 1 - parameter;
    return 3 * remaining * remaining * parameter * first +
        3 * remaining * parameter * parameter * second +
        parameter * parameter * parameter;
}

pub fn interpolate(old: Rect, target: Rect, factor: u32) Rect {
    return .{
        .x = interpolateSigned(old.x, target.x, factor),
        .y = interpolateSigned(old.y, target.y, factor),
        .width = interpolateUnsigned(old.width, target.width, factor),
        .height = interpolateUnsigned(old.height, target.height, factor),
    };
}

pub fn targetReady(
    buffer_update_required: bool,
    old_source: render.SourceCache,
    current_source: render.SourceCache,
) bool {
    return !buffer_update_required or !std.meta.eql(old_source, current_source);
}

pub fn appearanceStart(target: Rect) Rect {
    return .{
        .x = target.x +| @as(i32, @intCast(target.width / 2)),
        .y = target.y +| @as(i32, @intCast(target.height / 2)),
        .width = 1,
        .height = 1,
    };
}

pub fn overlapArea(first: Rect, second: Rect) u64 {
    const left = @max(@as(i64, first.x), @as(i64, second.x));
    const top = @max(@as(i64, first.y), @as(i64, second.y));
    const right = @min(
        @as(i64, first.x) + first.width,
        @as(i64, second.x) + second.width,
    );
    const bottom = @min(
        @as(i64, first.y) + first.height,
        @as(i64, second.y) + second.height,
    );
    if (right <= left or bottom <= top) return 0;
    return @intCast((right - left) * (bottom - top));
}

fn edgeGap(first_end: i64, second_start: i64) i32 {
    return @intCast(@min(
        @as(i64, std.math.maxInt(i32)),
        @max(0, second_start - first_end),
    ));
}

/// Collapses a split pane beyond its moving edge while preserving the gap to
/// the pane that releases or absorbs its space.
pub fn splitCollapsedRect(existing_target: Rect, new_target: Rect) Rect {
    const existing_center_x = 2 * @as(i64, existing_target.x) + existing_target.width;
    const existing_center_y = 2 * @as(i64, existing_target.y) + existing_target.height;
    const new_center_x = 2 * @as(i64, new_target.x) + new_target.width;
    const new_center_y = 2 * @as(i64, new_target.y) + new_target.height;
    const horizontal_distance = @abs(new_center_x - existing_center_x);
    const vertical_distance = @abs(new_center_y - existing_center_y);
    if (horizontal_distance >= vertical_distance) return .{
        .x = if (new_center_x > existing_center_x)
            new_target.x +| @as(i32, @intCast(new_target.width)) +| edgeGap(
                @as(i64, existing_target.x) + existing_target.width,
                new_target.x,
            )
        else
            new_target.x -| edgeGap(
                @as(i64, new_target.x) + new_target.width,
                existing_target.x,
            ),
        .y = new_target.y,
        .width = 0,
        .height = new_target.height,
    };
    return .{
        .x = new_target.x,
        .y = if (new_center_y > existing_center_y)
            new_target.y +| @as(i32, @intCast(new_target.height)) +| edgeGap(
                @as(i64, existing_target.y) + existing_target.height,
                new_target.y,
            )
        else
            new_target.y -| edgeGap(
                @as(i64, new_target.y) + new_target.height,
                existing_target.y,
            ),
        .width = new_target.width,
        .height = 0,
    };
}

const Range = struct {
    start: i32,
    length: u32,
};

fn constrainCollapsedOuterEdge(current: Range, old: Range, target: Range) Range {
    const Split = struct { collapsed: Range, expanded: Range };
    const split: Split = if (old.length == 0 and target.length != 0)
        .{ .collapsed = old, .expanded = target }
    else if (target.length == 0 and old.length != 0)
        .{ .collapsed = target, .expanded = old }
    else
        return current;

    if (split.collapsed.start > split.expanded.start) {
        const outer_end = split.expanded.start +| @as(i32, @intCast(split.expanded.length));
        if (current.start >= outer_end) return .{ .start = outer_end, .length = 0 };
        return .{
            .start = current.start,
            .length = @min(current.length, @as(u32, @intCast(outer_end - current.start))),
        };
    }

    const outer_start = split.expanded.start;
    const current_end = current.start +| @as(i32, @intCast(current.length));
    if (current_end <= outer_start) return .{ .start = outer_start, .length = 0 };
    if (current.start >= outer_start) return current;
    return .{ .start = outer_start, .length = @intCast(current_end - outer_start) };
}

pub fn constrainSplitOuterEdge(rect: Rect, old: Rect, target: Rect) Rect {
    const horizontal = constrainCollapsedOuterEdge(
        .{ .start = rect.x, .length = rect.width },
        .{ .start = old.x, .length = old.width },
        .{ .start = target.x, .length = target.width },
    );
    const vertical = constrainCollapsedOuterEdge(
        .{ .start = rect.y, .length = rect.height },
        .{ .start = old.y, .length = old.height },
        .{ .start = target.y, .length = target.height },
    );
    return .{
        .x = horizontal.start,
        .y = vertical.start,
        .width = horizontal.length,
        .height = vertical.length,
    };
}

pub const maximum_growth_slices = 14;

pub const GrowthSlice = struct {
    source_start: u32,
    source_length: u32,
    destination_start: i32,
    destination_length: u32,
};

pub const GrowthSlices = struct {
    items: [maximum_growth_slices]GrowthSlice = undefined,
    count: usize = 0,

    pub fn slice(self: *const GrowthSlices) []const GrowthSlice {
        return self.items[0..self.count];
    }
};

const elastic_growth_slice_count = 12;

const GrowthMap = struct {
    old_start: i32,
    band_start: u32,
    band_length: u32,
    start_displacement: i64,
    end_displacement: i64,

    fn position(map: GrowthMap, source_offset: u32) i32 {
        const displacement: f64 = if (source_offset <= map.band_start)
            @floatFromInt(map.start_displacement)
        else if (source_offset >= map.band_start + map.band_length)
            @floatFromInt(map.end_displacement)
        else smooth: {
            const phase = @as(f64, @floatFromInt(source_offset - map.band_start)) /
                @as(f64, @floatFromInt(map.band_length));
            const smootherstep = phase * phase * phase *
                (phase * (phase * 6 - 15) + 10);
            break :smooth @as(f64, @floatFromInt(map.start_displacement)) +
                @as(f64, @floatFromInt(map.end_displacement - map.start_displacement)) * smootherstep;
        };
        return @intFromFloat(@round(
            @as(f64, @floatFromInt(map.old_start)) +
                @as(f64, @floatFromInt(source_offset)) +
                displacement,
        ));
    }
};

/// Keeps both ends native-sized while a compact smootherstep band absorbs growth.
pub fn growthSlices(
    old_start: i32,
    old_length: u32,
    animated_start: i32,
    animated_length: u32,
    moving_end: bool,
) GrowthSlices {
    std.debug.assert(old_length != 0 and animated_length >= old_length);
    const edge_cap = @min(@as(u32, 12), old_length / 8);
    const desired_elastic_length = @max(@as(u32, 16), old_length / 8);
    const elastic_length = @min(
        @as(u32, 64),
        @min(desired_elastic_length, old_length - edge_cap),
    );
    const band_start = if (moving_end)
        old_length - edge_cap - elastic_length
    else
        edge_cap;
    const band_end = band_start + elastic_length;
    const old_end = @as(i64, old_start) + old_length;
    const animated_end = @as(i64, animated_start) + animated_length;
    const map: GrowthMap = .{
        .old_start = old_start,
        .band_start = band_start,
        .band_length = elastic_length,
        .start_displacement = @as(i64, animated_start) - old_start,
        .end_displacement = animated_end - old_end,
    };

    var result: GrowthSlices = .{};
    appendGrowthSlice(&result, map, 0, band_start);
    for (0..elastic_growth_slice_count) |index| {
        const source_start = band_start + @as(u32, @intCast(index)) * elastic_length / elastic_growth_slice_count;
        const source_end = band_start + @as(u32, @intCast(index + 1)) * elastic_length / elastic_growth_slice_count;
        appendGrowthSlice(&result, map, source_start, source_end);
    }
    appendGrowthSlice(&result, map, band_end, old_length);
    return result;
}

fn appendGrowthSlice(
    result: *GrowthSlices,
    map: GrowthMap,
    source_start: u32,
    source_end: u32,
) void {
    if (source_start == source_end) return;
    const destination_start = map.position(source_start);
    const destination_end = map.position(source_end);
    std.debug.assert(destination_end > destination_start);
    std.debug.assert(result.count < maximum_growth_slices);
    result.items[result.count] = .{
        .source_start = source_start,
        .source_length = source_end - source_start,
        .destination_start = destination_start,
        .destination_length = @intCast(destination_end - destination_start),
    };
    result.count += 1;
}

pub fn targetReveal(old: Rect, target: Rect, factor: u32) Rect {
    const width_change = @abs(@as(i64, target.width) - old.width);
    const height_change = @abs(@as(i64, target.height) - old.height);
    if (width_change >= height_change) {
        const width = interpolateUnsigned(0, target.width, factor);
        const old_right = @as(i64, old.x) + old.width;
        const target_right = @as(i64, target.x) + target.width;
        const left_movement = @abs(@as(i64, target.x) - old.x);
        const right_movement = @abs(target_right - old_right);
        return .{
            .x = if (left_movement <= right_movement)
                target.x
            else
                target.x +| @as(i32, @intCast(target.width - width)),
            .y = target.y,
            .width = width,
            .height = target.height,
        };
    }

    const height = interpolateUnsigned(0, target.height, factor);
    const old_bottom = @as(i64, old.y) + old.height;
    const target_bottom = @as(i64, target.y) + target.height;
    const top_movement = @abs(@as(i64, target.y) - old.y);
    const bottom_movement = @abs(target_bottom - old_bottom);
    return .{
        .x = target.x,
        .y = if (top_movement <= bottom_movement)
            target.y
        else
            target.y +| @as(i32, @intCast(target.height - height)),
        .width = target.width,
        .height = height,
    };
}

/// Maps a contained logical target rectangle into the old snapshot's pixel coordinates.
pub fn targetSourceRect(old: Rect, target: Rect, source_size: render.Size) ?render.SourceRect {
    const old_right = @as(i64, old.x) + old.width;
    const old_bottom = @as(i64, old.y) + old.height;
    const target_right = @as(i64, target.x) + target.width;
    const target_bottom = @as(i64, target.y) + target.height;
    if (old.width == 0 or old.height == 0 or target.x < old.x or target.y < old.y or
        target_right > old_right or target_bottom > old_bottom) return null;

    const offset_x: u64 = @intCast(@as(i64, target.x) - old.x);
    const offset_y: u64 = @intCast(@as(i64, target.y) - old.y);
    const right: u64 = @intCast(target_right - old.x);
    const bottom: u64 = @intCast(target_bottom - old.y);
    const source_width: u64 = source_size.width;
    const source_height: u64 = source_size.height;
    const left_source = @as(f64, @floatFromInt(offset_x * source_width)) / @as(f64, @floatFromInt(old.width));
    const top_source = @as(f64, @floatFromInt(offset_y * source_height)) / @as(f64, @floatFromInt(old.height));
    const right_source = if (right == old.width)
        @as(f64, @floatFromInt(source_size.width))
    else
        @as(f64, @floatFromInt(right * source_width)) / @as(f64, @floatFromInt(old.width));
    const bottom_source = if (bottom == old.height)
        @as(f64, @floatFromInt(source_size.height))
    else
        @as(f64, @floatFromInt(bottom * source_height)) / @as(f64, @floatFromInt(old.height));
    return .{
        .x = left_source,
        .y = top_source,
        .width = right_source - left_source,
        .height = bottom_source - top_source,
    };
}

fn interpolateSigned(old: i32, target: i32, factor: u32) i32 {
    const delta: i64 = @as(i64, target) - old;
    return @intCast(@as(i64, old) + @divTrunc(delta * factor, std.math.maxInt(u32)));
}

fn interpolateUnsigned(old: u32, target: u32, factor: u32) u32 {
    return @intCast(interpolateSigned(@intCast(old), @intCast(target), factor));
}

pub const Snapshot = struct {
    source: render.ImageSource,
    owned_pixels: ?[]u32 = null,

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator, offscreen: ?render.OffscreenRenderer) void {
        switch (self.source) {
            .pixels => if (self.owned_pixels) |pixels| allocator.free(pixels),
            .offscreen => |target| if (offscreen) |access| access.release_target(access.context, target.id),
        }
        self.* = undefined;
    }
};

test "interpolation has exact endpoints" {
    const old: Rect = .{ .x = -20, .y = 10, .width = 100, .height = 80 };
    const target: Rect = .{ .x = 200, .y = -40, .width = 640, .height = 480 };
    try std.testing.expectEqual(old, interpolate(old, target, 0));
    try std.testing.expectEqual(target, interpolate(old, target, std.math.maxInt(u32)));
}

test "Fluent easing curves are monotonic and clamp" {
    for (std.enums.values(Easing)) |easing| {
        var previous: u32 = 0;
        for (0..252) |millisecond| {
            const current = progress(
                100,
                100 + @as(i96, @intCast(millisecond * std.time.ns_per_ms)),
                normal_duration_nanoseconds,
                easing,
            );
            try std.testing.expect(current >= previous);
            previous = current;
        }
        try std.testing.expectEqual(std.math.maxInt(u32), previous);
    }
}

test "entrance decelerates and exit accelerates with exact endpoints" {
    try std.testing.expectEqual(
        @as(u32, 0),
        progress(0, 0, fast_duration_nanoseconds, .entrance),
    );
    const entrance_midpoint = progress(
        0,
        fast_duration_nanoseconds / 2,
        fast_duration_nanoseconds,
        .entrance,
    );
    const exit_midpoint = progress(
        0,
        fast_duration_nanoseconds / 2,
        fast_duration_nanoseconds,
        .exit,
    );
    try std.testing.expect(entrance_midpoint > std.math.maxInt(u32) / 2);
    try std.testing.expect(exit_midpoint < std.math.maxInt(u32) / 2);
    try std.testing.expectEqual(
        std.math.maxInt(u32),
        progress(
            0,
            fast_duration_nanoseconds,
            fast_duration_nanoseconds,
            .entrance,
        ),
    );
}

test "split collapse preserves gaps while opening and closing" {
    const full: Rect = .{ .x = 0, .y = 0, .width = 1000, .height = 800 };
    const cases = [_]struct {
        existing: Rect,
        pane: Rect,
        collapsed: Rect,
        horizontal: bool,
    }{
        .{
            .existing = .{ .x = 0, .y = 0, .width = 492, .height = 800 },
            .pane = .{ .x = 508, .y = 0, .width = 492, .height = 800 },
            .collapsed = .{ .x = 1016, .y = 0, .width = 0, .height = 800 },
            .horizontal = true,
        },
        .{
            .existing = .{ .x = 0, .y = 0, .width = 1000, .height = 392 },
            .pane = .{ .x = 0, .y = 408, .width = 1000, .height = 392 },
            .collapsed = .{ .x = 0, .y = 816, .width = 1000, .height = 0 },
            .horizontal = false,
        },
    };
    const midpoint = std.math.maxInt(u32) / 2;
    for (cases) |case| {
        const collapsed = splitCollapsedRect(case.existing, case.pane);
        try std.testing.expectEqual(case.collapsed, collapsed);
        try std.testing.expect(overlapArea(full, case.pane) > overlapArea(case.existing, case.pane));

        const opening_existing = interpolate(full, case.existing, midpoint);
        const opening_pane = constrainSplitOuterEdge(
            interpolate(collapsed, case.pane, midpoint),
            collapsed,
            case.pane,
        );
        const closing_existing = interpolate(case.existing, full, midpoint);
        const closing_pane = constrainSplitOuterEdge(
            interpolate(case.pane, collapsed, midpoint),
            case.pane,
            collapsed,
        );
        if (case.horizontal) {
            const gap = @as(i64, case.pane.x) -
                (@as(i64, case.existing.x) + case.existing.width);
            try std.testing.expectEqual(
                gap,
                @as(i64, opening_pane.x) -
                    (@as(i64, opening_existing.x) + opening_existing.width),
            );
            try std.testing.expectEqual(
                gap,
                @as(i64, closing_pane.x) -
                    (@as(i64, closing_existing.x) + closing_existing.width),
            );
            try std.testing.expectEqual(
                @as(i64, case.pane.x) + case.pane.width,
                @as(i64, opening_pane.x) + opening_pane.width,
            );
        } else {
            const gap = @as(i64, case.pane.y) -
                (@as(i64, case.existing.y) + case.existing.height);
            try std.testing.expectEqual(
                gap,
                @as(i64, opening_pane.y) -
                    (@as(i64, opening_existing.y) + opening_existing.height),
            );
            try std.testing.expectEqual(
                gap,
                @as(i64, closing_pane.y) -
                    (@as(i64, closing_existing.y) + closing_existing.height),
            );
            try std.testing.expectEqual(
                @as(i64, case.pane.y) + case.pane.height,
                @as(i64, opening_pane.y) + opening_pane.height,
            );
        }
    }
}

test "elastic growth keeps the stable core and moving edge native-sized" {
    const right = growthSlices(0, 100, 0, 160, true);
    const right_slices = right.slice();
    try std.testing.expect(right_slices.len > 3);
    try std.testing.expectEqual(@as(u32, 0), right_slices[0].source_start);
    try std.testing.expectEqual(@as(i32, 0), right_slices[0].destination_start);
    try std.testing.expectEqual(
        right_slices[0].source_length,
        right_slices[0].destination_length,
    );
    const right_edge = right_slices[right_slices.len - 1];
    try std.testing.expectEqual(right_edge.source_length, right_edge.destination_length);
    try std.testing.expectEqual(
        @as(i64, 160),
        @as(i64, right_edge.destination_start) + right_edge.destination_length,
    );
    for (right_slices[1..], right_slices[0 .. right_slices.len - 1]) |current, previous| {
        try std.testing.expectEqual(
            previous.source_start + previous.source_length,
            current.source_start,
        );
        try std.testing.expectEqual(
            @as(i64, previous.destination_start) + previous.destination_length,
            current.destination_start,
        );
    }

    const left = growthSlices(60, 100, 0, 160, false);
    const left_slices = left.slice();
    try std.testing.expect(left_slices.len > 3);
    try std.testing.expectEqual(@as(i32, 0), left_slices[0].destination_start);
    try std.testing.expectEqual(
        left_slices[0].source_length,
        left_slices[0].destination_length,
    );
    const left_core = left_slices[left_slices.len - 1];
    try std.testing.expectEqual(left_core.source_length, left_core.destination_length);
    try std.testing.expectEqual(
        @as(i64, 160),
        @as(i64, left_core.destination_start) + left_core.destination_length,
    );
}

test "content and opacity transitions use explicit 50 millisecond windows" {
    const centered_start = (normal_duration_nanoseconds - fade_duration_nanoseconds) / 2;
    try std.testing.expectEqual(@as(u32, 0), contentProgress(0, centered_start, normal_duration_nanoseconds));
    try std.testing.expectEqual(
        std.math.maxInt(u32),
        contentProgress(0, centered_start + fade_duration_nanoseconds, normal_duration_nanoseconds),
    );
    try std.testing.expectEqual(
        std.math.maxInt(u32),
        appearanceProgress(0, fade_duration_nanoseconds),
    );
    try std.testing.expectEqual(
        @as(u32, 0),
        disappearanceProgress(
            0,
            normal_duration_nanoseconds - fade_duration_nanoseconds,
            normal_duration_nanoseconds,
        ),
    );
    try std.testing.expectEqual(
        std.math.maxInt(u32),
        disappearanceProgress(0, normal_duration_nanoseconds, normal_duration_nanoseconds),
    );
}

test "large reflows use the normal duration" {
    const old: Rect = .{ .x = 0, .y = 0, .width = 500, .height = 400 };
    try std.testing.expectEqual(
        fast_duration_nanoseconds,
        reflowDuration(old, .{ .x = 20, .y = 0, .width = 480, .height = 400 }),
    );
    try std.testing.expectEqual(
        normal_duration_nanoseconds,
        reflowDuration(old, .{ .x = 200, .y = 0, .width = 300, .height = 400 }),
    );
}

test "target content reveal and source crop preserve stable edges" {
    const factor = std.math.maxInt(u32) / 2;
    const right = targetReveal(
        .{ .x = 508, .y = 0, .width = 492, .height = 800 },
        .{ .x = 0, .y = 0, .width = 1000, .height = 800 },
        factor,
    );
    try std.testing.expectEqual(
        @as(i64, 1000),
        @as(i64, right.x) + right.width,
    );

    try std.testing.expectEqual(
        render.SourceRect{ .x = 0, .y = 0, .width = 492, .height = 800 },
        targetSourceRect(
            .{ .x = 0, .y = 0, .width = 1000, .height = 800 },
            .{ .x = 0, .y = 0, .width = 492, .height = 800 },
            .{ .width = 1000, .height = 800 },
        ).?,
    );
}

test "retarget starts at currently displayed position" {
    const first = interpolate(
        .{ .x = 0, .y = 0, .width = 100, .height = 100 },
        .{ .x = 200, .y = 80, .width = 300, .height = 200 },
        progress(0, 50 * std.time.ns_per_ms, normal_duration_nanoseconds, .existing),
    );
    const retargeted = interpolate(first, .{ .x = -100, .y = 20, .width = 500, .height = 400 }, 0);
    try std.testing.expectEqual(first, retargeted);
}

test "a resize waits for a new buffer generation" {
    const generation: render.SourceCache = .{ .id = 1, .version = 1 };
    try std.testing.expect(targetReady(false, generation, generation));
    try std.testing.expect(!targetReady(true, generation, generation));
    try std.testing.expect(targetReady(
        true,
        generation,
        .{ .id = 1, .version = 2 },
    ));
}

test "a first presentation starts collapsed at its target center" {
    try std.testing.expectEqual(
        Rect{ .x = 250, .y = 140, .width = 1, .height = 1 },
        appearanceStart(.{ .x = 50, .y = 40, .width = 400, .height = 200 }),
    );
}
