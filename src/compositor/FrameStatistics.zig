//! Per-output rolling frame, scanout, and latency telemetry.

const FrameStatistics = @This();

const std = @import("std");
const ControlProtocol = @import("keywork-control");
const Region = @import("region.zig");
const renderer_types = @import("render/renderer.zig");
const render = @import("render/types.zig");

const sample_capacity = 1024;
const frame_budget_tolerance_nanoseconds = std.time.ns_per_ms;
const direct_scanout_rejection_count = std.meta.fields(render.DirectScanoutRejection).len;
const overlay_scanout_rejection_count = std.meta.fields(render.OverlayScanoutRejection).len;

pub const FramePath = enum { composited, direct_scanout, overlay_scanout };

/// Monotonic timestamps collected for one presented frame.
pub const FrameTimestamps = struct {
    request_nanoseconds: i96,
    render_nanoseconds: i96,
    commit_nanoseconds: i96,
    render_completion_nanoseconds: ?i96 = null,
};

const FrameLatency = struct {
    request_to_presentation_microseconds: u64,
    request_to_render_microseconds: u64,
    render_to_commit_microseconds: u64,
    commit_to_presentation_microseconds: u64,
    render_to_gpu_completion_microseconds: ?u64 = null,
    gpu_completion_to_presentation_microseconds: ?u64 = null,
};

const LatencyKind = enum {
    request_to_presentation,
    request_to_render,
    render_to_commit,
    commit_to_presentation,
    render_to_gpu_completion,
    gpu_completion_to_presentation,
};

const GpuExecution = struct {
    total_microseconds: u64,
    composition_microseconds: u64,
    preparation_microseconds: u64,
    solid_composition_microseconds: u64,
    image_composition_microseconds: u64,
    shadow_microseconds: u64,
    blur_downsample_microseconds: u64,
    blur_upsample_microseconds: u64,
    blur_composite_microseconds: u64,
    composition_overhead_microseconds: u64,
    output_encode_microseconds: u64,
    frame_finish_microseconds: u64,
    pass_timings_available: bool,
};

const GpuExecutionKind = enum {
    total,
    composition,
    preparation,
    solid_composition,
    image_composition,
    shadow,
    blur_downsample,
    blur_upsample,
    blur_composite,
    composition_overhead,
    output_encode,
    frame_finish,

    fn requiresPassTimings(kind: GpuExecutionKind) bool {
        return switch (kind) {
            .total, .composition, .output_encode, .frame_finish => false,
            else => true,
        };
    }
};

frames_requested: u64 = 0,
frames_started: u64 = 0,
frames_presented: u64 = 0,
frames_discarded: u64 = 0,
acquire_retries: u64 = 0,
composited_frames: u64 = 0,
direct_scanout_candidates: u64 = 0,
direct_scanout_frames: u64 = 0,
direct_scanout_rejections: [direct_scanout_rejection_count]u64 = @splat(0),
overlay_scanout_candidates: u64 = 0,
overlay_scanout_frames: u64 = 0,
overlay_scanout_rejections: [overlay_scanout_rejection_count]u64 = @splat(0),
cpu_uploads: u64 = 0,
dmabuf_imports: u64 = 0,
frames_over_budget: u64 = 0,
render_fence_samples: u64 = 0,
render_fences_signaled_before_commit: u64 = 0,
latency_samples: [sample_capacity]FrameLatency = undefined,
latency_count: usize = 0,
latency_next: usize = 0,
gpu_execution_samples: [sample_capacity]GpuExecution = undefined,
gpu_execution_count: usize = 0,
gpu_execution_next: usize = 0,
last_path: ?FramePath = null,
last_scanout_format: ?render.DmabufFormat = null,
last_damage_rectangles: u64 = 0,
last_damaged_pixels: u64 = 0,

pub fn recordPresentation(
    self: *FrameStatistics,
    timestamps: FrameTimestamps,
    presented_nanoseconds: i96,
    refresh_nanoseconds: u64,
) void {
    const request_to_presentation = elapsedNanoseconds(
        timestamps.request_nanoseconds,
        presented_nanoseconds,
    );
    var latency: FrameLatency = .{
        .request_to_presentation_microseconds = nanosecondsToMicroseconds(request_to_presentation),
        .request_to_render_microseconds = nanosecondsToMicroseconds(elapsedNanoseconds(
            timestamps.request_nanoseconds,
            timestamps.render_nanoseconds,
        )),
        .render_to_commit_microseconds = nanosecondsToMicroseconds(elapsedNanoseconds(
            timestamps.render_nanoseconds,
            timestamps.commit_nanoseconds,
        )),
        .commit_to_presentation_microseconds = nanosecondsToMicroseconds(elapsedNanoseconds(
            timestamps.commit_nanoseconds,
            presented_nanoseconds,
        )),
    };
    if (timestamps.render_completion_nanoseconds) |completion_nanoseconds| {
        // DMA-fence and DRM vblank timestamps are both monotonic. Reject
        // out-of-range values so an unexpected clock domain cannot skew
        // the rolling latency distributions.
        if (completion_nanoseconds >= timestamps.render_nanoseconds and
            completion_nanoseconds <= presented_nanoseconds)
        {
            latency.render_to_gpu_completion_microseconds = nanosecondsToMicroseconds(
                elapsedNanoseconds(timestamps.render_nanoseconds, completion_nanoseconds),
            );
            latency.gpu_completion_to_presentation_microseconds = nanosecondsToMicroseconds(
                elapsedNanoseconds(completion_nanoseconds, presented_nanoseconds),
            );
            increment(&self.render_fence_samples);
            if (completion_nanoseconds <= timestamps.commit_nanoseconds) {
                increment(&self.render_fences_signaled_before_commit);
            }
        }
    }
    self.addLatency(latency);
    increment(&self.frames_presented);
    if (request_to_presentation > refresh_nanoseconds +| frame_budget_tolerance_nanoseconds) {
        increment(&self.frames_over_budget);
    }
}

fn addLatency(self: *FrameStatistics, latency: FrameLatency) void {
    self.latency_samples[self.latency_next] = latency;
    self.latency_next = (self.latency_next + 1) % sample_capacity;
    self.latency_count = @min(self.latency_count + 1, sample_capacity);
}

pub fn addGpuExecution(
    self: *FrameStatistics,
    timing: renderer_types.Renderer.GpuTiming,
) void {
    self.gpu_execution_samples[self.gpu_execution_next] = .{
        .total_microseconds = nanosecondsToMicroseconds(timing.total_nanoseconds),
        .composition_microseconds = nanosecondsToMicroseconds(timing.composition_nanoseconds),
        .preparation_microseconds = nanosecondsToMicroseconds(timing.preparation_nanoseconds),
        .solid_composition_microseconds = nanosecondsToMicroseconds(timing.solid_composition_nanoseconds),
        .image_composition_microseconds = nanosecondsToMicroseconds(timing.image_composition_nanoseconds),
        .shadow_microseconds = nanosecondsToMicroseconds(timing.shadow_nanoseconds),
        .blur_downsample_microseconds = nanosecondsToMicroseconds(timing.blur_downsample_nanoseconds),
        .blur_upsample_microseconds = nanosecondsToMicroseconds(timing.blur_upsample_nanoseconds),
        .blur_composite_microseconds = nanosecondsToMicroseconds(timing.blur_composite_nanoseconds),
        .composition_overhead_microseconds = nanosecondsToMicroseconds(timing.composition_overhead_nanoseconds),
        .output_encode_microseconds = nanosecondsToMicroseconds(timing.output_encode_nanoseconds),
        .frame_finish_microseconds = nanosecondsToMicroseconds(timing.frame_finish_nanoseconds),
        .pass_timings_available = timing.pass_timings_available,
    };
    self.gpu_execution_next = (self.gpu_execution_next + 1) % sample_capacity;
    self.gpu_execution_count = @min(self.gpu_execution_count + 1, sample_capacity);
}

pub fn rejectDirectScanout(
    self: *FrameStatistics,
    reason: render.DirectScanoutRejection,
) void {
    increment(&self.direct_scanout_rejections[@intFromEnum(reason)]);
}

pub fn rejectOverlayScanout(
    self: *FrameStatistics,
    reason: render.OverlayScanoutRejection,
) void {
    increment(&self.overlay_scanout_rejections[@intFromEnum(reason)]);
}

pub fn addFrameCompletion(
    self: *FrameStatistics,
    completion: render.FrameCompletion,
) void {
    self.cpu_uploads +|= completion.cpu_uploads;
    self.dmabuf_imports +|= completion.dmabuf_imports;
}

pub fn recordFrame(
    self: *FrameStatistics,
    path: FramePath,
    scanout_format: ?render.DmabufFormat,
    damage: *const Region,
) void {
    var rectangles: u64 = 0;
    var pixels: u64 = 0;
    var iterator = damage.rectangleIterator();
    while (iterator.next()) |rectangle| {
        rectangles +|= 1;
        pixels +|= @as(u64, rectangle.width) * rectangle.height;
    }
    self.last_path = path;
    self.last_scanout_format = scanout_format;
    self.last_damage_rectangles = rectangles;
    self.last_damaged_pixels = pixels;
}

pub fn snapshot(
    self: *const FrameStatistics,
    name: []const u8,
    size: render.Size,
    refresh_millihertz: i32,
    working_format: renderer_types.Renderer.WorkingFormat,
) ControlProtocol.OutputStatistics {
    return .{
        .name = name,
        .width = @intCast(size.width),
        .height = @intCast(size.height),
        .refresh_millihertz = refresh_millihertz,
        .last_frame = .{
            .path = controlFramePath(self.last_path),
            .working_format = controlWorkingFormat(working_format),
            .scanout_format = controlScanoutFormat(self.last_scanout_format),
            .output_transform = .normal,
            .damage_rectangles = wireInteger(self.last_damage_rectangles),
            .damaged_pixels = wireInteger(self.last_damaged_pixels),
        },
        .frames_requested = wireInteger(self.frames_requested),
        .frames_started = wireInteger(self.frames_started),
        .frames_presented = wireInteger(self.frames_presented),
        .frames_discarded = wireInteger(self.frames_discarded),
        .acquire_retries = wireInteger(self.acquire_retries),
        .composited_frames = wireInteger(self.composited_frames),
        .direct_scanout_candidates = wireInteger(self.direct_scanout_candidates),
        .direct_scanout_frames = wireInteger(self.direct_scanout_frames),
        .direct_scanout_rejections = .{
            .no_fullscreen_surface = self.directScanoutRejection(.no_fullscreen_surface),
            .non_opaque_surface = self.directScanoutRejection(.non_opaque_surface),
            .surface_transform = self.directScanoutRejection(.surface_transform),
            .non_dmabuf = self.directScanoutRejection(.non_dmabuf),
            .y_inverted = self.directScanoutRejection(.y_inverted),
            .missing_buffer_identity = self.directScanoutRejection(.missing_buffer_identity),
            .color_conversion = self.directScanoutRejection(.color_conversion),
            .unsupported_backend = self.directScanoutRejection(.unsupported_backend),
            .output_unavailable = self.directScanoutRejection(.output_unavailable),
            .output_busy = self.directScanoutRejection(.output_busy),
            .device_inactive = self.directScanoutRejection(.device_inactive),
            .unsupported_format_or_modifier = self.directScanoutRejection(.unsupported_format_or_modifier),
            .unsupported_layout = self.directScanoutRejection(.unsupported_layout),
            .framebuffer_import_failed = self.directScanoutRejection(.framebuffer_import_failed),
            .page_flip_failed = self.directScanoutRejection(.page_flip_failed),
        },
        .overlay_scanout_candidates = wireInteger(self.overlay_scanout_candidates),
        .overlay_scanout_frames = wireInteger(self.overlay_scanout_frames),
        .overlay_scanout_rejections = .{
            .no_topmost_surface = self.overlayScanoutRejection(.no_topmost_surface),
            .non_opaque_surface = self.overlayScanoutRejection(.non_opaque_surface),
            .clipped_surface = self.overlayScanoutRejection(.clipped_surface),
            .transformed_surface = self.overlayScanoutRejection(.transformed_surface),
            .scaled_surface = self.overlayScanoutRejection(.scaled_surface),
            .outside_output = self.overlayScanoutRejection(.outside_output),
            .non_dmabuf = self.overlayScanoutRejection(.non_dmabuf),
            .non_rgb_surface = self.overlayScanoutRejection(.non_rgb_surface),
            .y_inverted = self.overlayScanoutRejection(.y_inverted),
            .missing_buffer_identity = self.overlayScanoutRejection(.missing_buffer_identity),
            .color_conversion = self.overlayScanoutRejection(.color_conversion),
            .unsupported_backend = self.overlayScanoutRejection(.unsupported_backend),
            .output_unavailable = self.overlayScanoutRejection(.output_unavailable),
            .output_busy = self.overlayScanoutRejection(.output_busy),
            .device_inactive = self.overlayScanoutRejection(.device_inactive),
            .no_overlay_plane = self.overlayScanoutRejection(.no_overlay_plane),
            .unsupported_format_or_modifier = self.overlayScanoutRejection(.unsupported_format_or_modifier),
            .unsupported_layout = self.overlayScanoutRejection(.unsupported_layout),
            .synchronization_failed = self.overlayScanoutRejection(.synchronization_failed),
            .framebuffer_import_failed = self.overlayScanoutRejection(.framebuffer_import_failed),
            .atomic_test_failed = self.overlayScanoutRejection(.atomic_test_failed),
            .page_flip_failed = self.overlayScanoutRejection(.page_flip_failed),
        },
        .cpu_uploads = wireInteger(self.cpu_uploads),
        .dmabuf_imports = wireInteger(self.dmabuf_imports),
        .frames_over_budget = wireInteger(self.frames_over_budget),
        .render_fence_samples = wireInteger(self.render_fence_samples),
        .render_fences_signaled_before_commit = wireInteger(
            self.render_fences_signaled_before_commit,
        ),
        .gpu_execution = self.gpuExecutionSummary(.total),
        .gpu_composition = self.gpuExecutionSummary(.composition),
        .gpu_preparation = self.gpuExecutionSummary(.preparation),
        .gpu_solid_composition = self.gpuExecutionSummary(.solid_composition),
        .gpu_image_composition = self.gpuExecutionSummary(.image_composition),
        .gpu_shadow = self.gpuExecutionSummary(.shadow),
        .gpu_blur_downsample = self.gpuExecutionSummary(.blur_downsample),
        .gpu_blur_upsample = self.gpuExecutionSummary(.blur_upsample),
        .gpu_blur_composite = self.gpuExecutionSummary(.blur_composite),
        .gpu_composition_overhead = self.gpuExecutionSummary(.composition_overhead),
        .gpu_output_encode = self.gpuExecutionSummary(.output_encode),
        .gpu_frame_finish = self.gpuExecutionSummary(.frame_finish),
        .request_to_presentation = self.latencySummary(.request_to_presentation),
        .request_to_render = self.latencySummary(.request_to_render),
        .render_to_commit = self.latencySummary(.render_to_commit),
        .commit_to_presentation = self.latencySummary(.commit_to_presentation),
        .render_to_gpu_completion = self.latencySummary(.render_to_gpu_completion),
        .gpu_completion_to_presentation = self.latencySummary(
            .gpu_completion_to_presentation,
        ),
    };
}

fn directScanoutRejection(
    self: *const FrameStatistics,
    reason: render.DirectScanoutRejection,
) i64 {
    return wireInteger(self.direct_scanout_rejections[@intFromEnum(reason)]);
}

fn overlayScanoutRejection(
    self: *const FrameStatistics,
    reason: render.OverlayScanoutRejection,
) i64 {
    return wireInteger(self.overlay_scanout_rejections[@intFromEnum(reason)]);
}

fn latencySummary(
    self: *const FrameStatistics,
    comptime kind: LatencyKind,
) ControlProtocol.LatencyStatistics {
    var values: [sample_capacity]u64 = undefined;
    var value_count: usize = 0;
    for (self.latency_samples[0..self.latency_count]) |sample| {
        const value: ?u64 = switch (kind) {
            .request_to_presentation => sample.request_to_presentation_microseconds,
            .request_to_render => sample.request_to_render_microseconds,
            .render_to_commit => sample.render_to_commit_microseconds,
            .commit_to_presentation => sample.commit_to_presentation_microseconds,
            .render_to_gpu_completion => sample.render_to_gpu_completion_microseconds,
            .gpu_completion_to_presentation => sample.gpu_completion_to_presentation_microseconds,
        };
        values[value_count] = value orelse continue;
        value_count += 1;
    }
    if (value_count == 0) return .{};
    const sorted = values[0..value_count];
    std.mem.sort(u64, sorted, {}, std.sort.asc(u64));
    return .{
        .samples = @intCast(sorted.len),
        .p50_microseconds = wireInteger(percentile(sorted, 50)),
        .p95_microseconds = wireInteger(percentile(sorted, 95)),
        .p99_microseconds = wireInteger(percentile(sorted, 99)),
        .maximum_microseconds = wireInteger(sorted[sorted.len - 1]),
    };
}

fn gpuExecutionSummary(
    self: *const FrameStatistics,
    comptime kind: GpuExecutionKind,
) ControlProtocol.LatencyStatistics {
    const no_samples: ControlProtocol.LatencyStatistics = .{
        .samples = 0,
        .p50_microseconds = 0,
        .p95_microseconds = 0,
        .p99_microseconds = 0,
        .maximum_microseconds = 0,
    };
    if (self.gpu_execution_count == 0) return no_samples;
    var values: [sample_capacity]u64 = undefined;
    var value_count: usize = 0;
    for (self.gpu_execution_samples[0..self.gpu_execution_count]) |sample| {
        if (kind.requiresPassTimings() and !sample.pass_timings_available) continue;
        values[value_count] = switch (kind) {
            .total => sample.total_microseconds,
            .composition => sample.composition_microseconds,
            .preparation => sample.preparation_microseconds,
            .solid_composition => sample.solid_composition_microseconds,
            .image_composition => sample.image_composition_microseconds,
            .shadow => sample.shadow_microseconds,
            .blur_downsample => sample.blur_downsample_microseconds,
            .blur_upsample => sample.blur_upsample_microseconds,
            .blur_composite => sample.blur_composite_microseconds,
            .composition_overhead => sample.composition_overhead_microseconds,
            .output_encode => sample.output_encode_microseconds,
            .frame_finish => sample.frame_finish_microseconds,
        };
        value_count += 1;
    }
    if (value_count == 0) return no_samples;
    const sorted = values[0..value_count];
    std.mem.sort(u64, sorted, {}, std.sort.asc(u64));
    return .{
        .samples = @intCast(sorted.len),
        .p50_microseconds = wireInteger(percentile(sorted, 50)),
        .p95_microseconds = wireInteger(percentile(sorted, 95)),
        .p99_microseconds = wireInteger(percentile(sorted, 99)),
        .maximum_microseconds = wireInteger(sorted[sorted.len - 1]),
    };
}

pub fn reset(self: *FrameStatistics) void {
    self.* = .{};
}

fn elapsedNanoseconds(start: i96, end: i96) u64 {
    if (end <= start) return 0;
    return @intCast(end - start);
}

fn nanosecondsToMicroseconds(nanoseconds: u64) u64 {
    return nanoseconds / std.time.ns_per_us;
}

fn percentile(sorted: []const u64, percentage: u8) u64 {
    std.debug.assert(sorted.len > 0 and percentage > 0 and percentage <= 100);
    const rank = (sorted.len * @as(usize, percentage) + 99) / 100;
    return sorted[rank - 1];
}

fn wireInteger(value: u64) i64 {
    return @intCast(@min(value, @as(u64, std.math.maxInt(i64))));
}

fn controlFramePath(path: ?FramePath) ControlProtocol.FramePath {
    return if (path) |value| switch (value) {
        .composited => .composited,
        .direct_scanout => .direct_scanout,
        .overlay_scanout => .overlay_scanout,
    } else .none;
}

fn controlWorkingFormat(
    format: renderer_types.Renderer.WorkingFormat,
) ControlProtocol.BufferFormat {
    return switch (format) {
        .argb8888 => .argb8888,
        .rgba16f_linear => .rgba16f_linear,
    };
}

fn controlScanoutFormat(format: ?render.DmabufFormat) ControlProtocol.BufferFormat {
    return if (format) |value| switch (value) {
        .argb8888 => .argb8888,
        .xrgb8888 => .xrgb8888,
        .abgr8888 => .abgr8888,
        .xbgr8888 => .xbgr8888,
        .xrgb2101010 => .xrgb2101010,
        .nv12, .p010 => .none,
    } else .none;
}

fn increment(value: *u64) void {
    value.* +|= 1;
}

test "frame statistics summarize rolling latency and classify over-budget frames" {
    var statistics: FrameStatistics = .{};
    statistics.addLatency(.{
        .request_to_presentation_microseconds = 100,
        .request_to_render_microseconds = 5,
        .render_to_commit_microseconds = 10,
        .commit_to_presentation_microseconds = 90,
    });
    statistics.addLatency(.{
        .request_to_presentation_microseconds = 200,
        .request_to_render_microseconds = 10,
        .render_to_commit_microseconds = 20,
        .commit_to_presentation_microseconds = 180,
    });
    statistics.addLatency(.{
        .request_to_presentation_microseconds = 300,
        .request_to_render_microseconds = 15,
        .render_to_commit_microseconds = 30,
        .commit_to_presentation_microseconds = 270,
    });
    statistics.addLatency(.{
        .request_to_presentation_microseconds = 400,
        .request_to_render_microseconds = 20,
        .render_to_commit_microseconds = 40,
        .commit_to_presentation_microseconds = 360,
    });
    const summary = statistics.latencySummary(.request_to_presentation);
    try std.testing.expectEqual(@as(i64, 4), summary.samples);
    try std.testing.expectEqual(@as(i64, 200), summary.p50_microseconds);
    try std.testing.expectEqual(@as(i64, 400), summary.p95_microseconds);
    try std.testing.expectEqual(@as(i64, 400), summary.p99_microseconds);
    try std.testing.expectEqual(@as(i64, 400), summary.maximum_microseconds);

    statistics.rejectDirectScanout(.color_conversion);
    statistics.rejectDirectScanout(.color_conversion);
    statistics.rejectDirectScanout(.page_flip_failed);
    try std.testing.expectEqual(@as(i64, 2), statistics.directScanoutRejection(.color_conversion));
    try std.testing.expectEqual(@as(i64, 1), statistics.directScanoutRejection(.page_flip_failed));

    statistics.rejectOverlayScanout(.no_overlay_plane);
    statistics.rejectOverlayScanout(.atomic_test_failed);
    statistics.rejectOverlayScanout(.atomic_test_failed);
    try std.testing.expectEqual(@as(i64, 1), statistics.overlayScanoutRejection(.no_overlay_plane));
    try std.testing.expectEqual(@as(i64, 2), statistics.overlayScanoutRejection(.atomic_test_failed));

    statistics.addFrameCompletion(.{ .cpu_uploads = 3, .dmabuf_imports = 2 });
    statistics.addFrameCompletion(.{ .cpu_uploads = 1, .dmabuf_imports = 4 });
    try std.testing.expectEqual(@as(u64, 4), statistics.cpu_uploads);
    try std.testing.expectEqual(@as(u64, 6), statistics.dmabuf_imports);

    statistics.addGpuExecution(.{
        .tag = 0,
        .total_nanoseconds = 1_100 * std.time.ns_per_us,
        .composition_nanoseconds = 700 * std.time.ns_per_us,
        .preparation_nanoseconds = 100 * std.time.ns_per_us,
        .solid_composition_nanoseconds = 100 * std.time.ns_per_us,
        .image_composition_nanoseconds = 200 * std.time.ns_per_us,
        .shadow_nanoseconds = 50 * std.time.ns_per_us,
        .blur_downsample_nanoseconds = 50 * std.time.ns_per_us,
        .blur_upsample_nanoseconds = 50 * std.time.ns_per_us,
        .blur_composite_nanoseconds = 50 * std.time.ns_per_us,
        .composition_overhead_nanoseconds = 100 * std.time.ns_per_us,
        .output_encode_nanoseconds = 300 * std.time.ns_per_us,
        .frame_finish_nanoseconds = 100 * std.time.ns_per_us,
        .pass_timings_available = true,
    });
    statistics.addGpuExecution(.{
        .tag = 0,
        .total_nanoseconds = 2_200 * std.time.ns_per_us,
        .composition_nanoseconds = 1_400 * std.time.ns_per_us,
        .preparation_nanoseconds = 200 * std.time.ns_per_us,
        .solid_composition_nanoseconds = 200 * std.time.ns_per_us,
        .image_composition_nanoseconds = 400 * std.time.ns_per_us,
        .shadow_nanoseconds = 100 * std.time.ns_per_us,
        .blur_downsample_nanoseconds = 100 * std.time.ns_per_us,
        .blur_upsample_nanoseconds = 100 * std.time.ns_per_us,
        .blur_composite_nanoseconds = 100 * std.time.ns_per_us,
        .composition_overhead_nanoseconds = 200 * std.time.ns_per_us,
        .output_encode_nanoseconds = 600 * std.time.ns_per_us,
        .frame_finish_nanoseconds = 200 * std.time.ns_per_us,
        .pass_timings_available = true,
    });
    statistics.addGpuExecution(.{
        .tag = 0,
        .total_nanoseconds = 3_300 * std.time.ns_per_us,
        .composition_nanoseconds = 2_100 * std.time.ns_per_us,
        .preparation_nanoseconds = 300 * std.time.ns_per_us,
        .solid_composition_nanoseconds = 300 * std.time.ns_per_us,
        .image_composition_nanoseconds = 600 * std.time.ns_per_us,
        .shadow_nanoseconds = 150 * std.time.ns_per_us,
        .blur_downsample_nanoseconds = 150 * std.time.ns_per_us,
        .blur_upsample_nanoseconds = 150 * std.time.ns_per_us,
        .blur_composite_nanoseconds = 150 * std.time.ns_per_us,
        .composition_overhead_nanoseconds = 300 * std.time.ns_per_us,
        .output_encode_nanoseconds = 900 * std.time.ns_per_us,
        .frame_finish_nanoseconds = 300 * std.time.ns_per_us,
        .pass_timings_available = true,
    });
    const gpu_summary = statistics.gpuExecutionSummary(.total);
    try std.testing.expectEqual(@as(i64, 3), gpu_summary.samples);
    try std.testing.expectEqual(@as(i64, 2_200), gpu_summary.p50_microseconds);
    try std.testing.expectEqual(@as(i64, 3_300), gpu_summary.p95_microseconds);
    try std.testing.expectEqual(@as(i64, 3_300), gpu_summary.maximum_microseconds);
    try std.testing.expectEqual(
        @as(i64, 1_400),
        statistics.gpuExecutionSummary(.composition).p50_microseconds,
    );
    try std.testing.expectEqual(
        @as(i64, 600),
        statistics.gpuExecutionSummary(.output_encode).p50_microseconds,
    );
    try std.testing.expectEqual(
        @as(i64, 200),
        statistics.gpuExecutionSummary(.preparation).p50_microseconds,
    );
    try std.testing.expectEqual(
        @as(i64, 400),
        statistics.gpuExecutionSummary(.image_composition).p50_microseconds,
    );
    try std.testing.expectEqual(
        @as(i64, 200),
        statistics.gpuExecutionSummary(.frame_finish).p50_microseconds,
    );
    statistics.addGpuExecution(.{
        .tag = 0,
        .total_nanoseconds = 4_400 * std.time.ns_per_us,
        .composition_nanoseconds = 2_800 * std.time.ns_per_us,
        .output_encode_nanoseconds = 1_200 * std.time.ns_per_us,
        .frame_finish_nanoseconds = 400 * std.time.ns_per_us,
    });
    try std.testing.expectEqual(
        @as(i64, 4),
        statistics.gpuExecutionSummary(.total).samples,
    );
    try std.testing.expectEqual(
        @as(i64, 3),
        statistics.gpuExecutionSummary(.preparation).samples,
    );
    try std.testing.expectEqual(
        @as(i64, 4),
        statistics.gpuExecutionSummary(.frame_finish).samples,
    );

    var damage = Region.init();
    defer damage.deinit();
    try damage.add(0, 0, 10, 20);
    try damage.add(20, 0, 5, 5);
    statistics.recordFrame(.composited, .xrgb8888, &damage);
    const output_snapshot = statistics.snapshot(
        "HEADLESS-1",
        .{ .width = 100, .height = 100 },
        60_000,
        .rgba16f_linear,
    );
    try std.testing.expectEqual(ControlProtocol.FramePath.composited, output_snapshot.last_frame.path);
    try std.testing.expectEqual(ControlProtocol.BufferFormat.rgba16f_linear, output_snapshot.last_frame.working_format);
    try std.testing.expectEqual(ControlProtocol.BufferFormat.xrgb8888, output_snapshot.last_frame.scanout_format);
    try std.testing.expectEqual(@as(i64, 3), output_snapshot.last_frame.damage_rectangles);
    try std.testing.expectEqual(@as(i64, 225), output_snapshot.last_frame.damaged_pixels);
    try std.testing.expectEqual(@as(i64, 1), output_snapshot.overlay_scanout_rejections.no_overlay_plane);
    try std.testing.expectEqual(@as(i64, 2), output_snapshot.overlay_scanout_rejections.atomic_test_failed);

    statistics.recordFrame(.overlay_scanout, .xrgb8888, &damage);
    const overlay_snapshot = statistics.snapshot(
        "HEADLESS-1",
        .{ .width = 100, .height = 100 },
        60_000,
        .rgba16f_linear,
    );
    try std.testing.expectEqual(ControlProtocol.FramePath.overlay_scanout, overlay_snapshot.last_frame.path);

    statistics.recordPresentation(.{
        .request_nanoseconds = 0,
        .render_nanoseconds = std.time.ns_per_ms,
        .commit_nanoseconds = 2 * std.time.ns_per_ms,
    }, 20 * std.time.ns_per_ms, 10 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u64, 1), statistics.frames_presented);
    try std.testing.expectEqual(@as(u64, 1), statistics.frames_over_budget);

    statistics.recordPresentation(.{
        .request_nanoseconds = 20 * std.time.ns_per_ms,
        .render_nanoseconds = 21 * std.time.ns_per_ms,
        .commit_nanoseconds = 24 * std.time.ns_per_ms,
        .render_completion_nanoseconds = 23 * std.time.ns_per_ms,
    }, 30 * std.time.ns_per_ms, 10 * std.time.ns_per_ms);
    try std.testing.expectEqual(
        @as(i64, 2_000),
        statistics.latencySummary(.render_to_gpu_completion).p50_microseconds,
    );
    try std.testing.expectEqual(
        @as(i64, 7_000),
        statistics.latencySummary(.gpu_completion_to_presentation).p50_microseconds,
    );
    try std.testing.expectEqual(@as(u64, 1), statistics.render_fence_samples);
    try std.testing.expectEqual(@as(u64, 1), statistics.render_fences_signaled_before_commit);

    statistics.reset();
    try std.testing.expectEqual(@as(usize, 0), statistics.latency_count);
    try std.testing.expectEqual(@as(usize, 0), statistics.gpu_execution_count);
    try std.testing.expectEqual(@as(u64, 0), statistics.frames_presented);
    try std.testing.expectEqual(@as(i64, 0), statistics.directScanoutRejection(.color_conversion));
    try std.testing.expectEqual(@as(i64, 0), statistics.overlayScanoutRejection(.atomic_test_failed));
    try std.testing.expectEqual(@as(u64, 0), statistics.cpu_uploads);
    try std.testing.expectEqual(@as(u64, 0), statistics.dmabuf_imports);
    try std.testing.expectEqual(@as(u64, 0), statistics.render_fence_samples);
    try std.testing.expectEqual(@as(u64, 0), statistics.render_fences_signaled_before_commit);

    for (0..sample_capacity + 1) |value| statistics.addLatency(.{
        .request_to_presentation_microseconds = value,
        .request_to_render_microseconds = value,
        .render_to_commit_microseconds = value,
        .commit_to_presentation_microseconds = value,
    });
    const rolling = statistics.latencySummary(.request_to_presentation);
    try std.testing.expectEqual(@as(i64, sample_capacity), rolling.samples);
    try std.testing.expectEqual(@as(i64, sample_capacity), rolling.maximum_microseconds);
}
