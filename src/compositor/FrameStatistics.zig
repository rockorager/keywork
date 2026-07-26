//! Per-output rolling frame, scanout, and latency telemetry.

const FrameStatistics = @This();

const std = @import("std");
const ControlProtocol = @import("keywork-control");
const Region = @import("region.zig");
const Renderer = @import("render/Renderer.zig");
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
repaints_delayed: u64 = 0,
repaints_immediate: u64 = 0,
render_budget_resets_missed: u64 = 0,
render_budget_resets_no_timing: u64 = 0,
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
    const render_to_presentation = elapsedNanoseconds(
        timestamps.render_nanoseconds,
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
    if (render_to_presentation > refresh_nanoseconds +| frame_budget_tolerance_nanoseconds) {
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
    timing: Renderer.GpuTiming,
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

/// `render_budget_nanoseconds` is the repaint scheduler's current warmed
/// worst-case render cost, or null while the sample window is not full and
/// repaint delays are disabled.
pub fn snapshot(
    self: *const FrameStatistics,
    name: []const u8,
    size: render.Size,
    refresh_millihertz: i32,
    working_format: Renderer.WorkingFormat,
    render_budget_nanoseconds: ?u64,
) ControlProtocol.OutputStatistics {
    return .{
        .name = name,
        .width = @intCast(size.width),
        .height = @intCast(size.height),
        .refreshMillihertz = refresh_millihertz,
        .lastFrame = .{
            .path = controlFramePath(self.last_path),
            .workingFormat = controlWorkingFormat(working_format),
            .scanoutFormat = controlScanoutFormat(self.last_scanout_format),
            .outputTransform = .normal,
            .damageRectangles = wireInteger(self.last_damage_rectangles),
            .damagedPixels = wireInteger(self.last_damaged_pixels),
        },
        .framesRequested = wireInteger(self.frames_requested),
        .framesStarted = wireInteger(self.frames_started),
        .framesPresented = wireInteger(self.frames_presented),
        .framesDiscarded = wireInteger(self.frames_discarded),
        .acquireRetries = wireInteger(self.acquire_retries),
        .compositedFrames = wireInteger(self.composited_frames),
        .directScanoutCandidates = wireInteger(self.direct_scanout_candidates),
        .directScanoutFrames = wireInteger(self.direct_scanout_frames),
        .directScanoutRejections = .{
            .noFullscreenSurface = self.directScanoutRejection(.no_fullscreen_surface),
            .nonOpaqueSurface = self.directScanoutRejection(.non_opaque_surface),
            .surfaceTransform = self.directScanoutRejection(.surface_transform),
            .nonDmabuf = self.directScanoutRejection(.non_dmabuf),
            .yInverted = self.directScanoutRejection(.y_inverted),
            .missingBufferIdentity = self.directScanoutRejection(.missing_buffer_identity),
            .colorConversion = self.directScanoutRejection(.color_conversion),
            .unsupportedBackend = self.directScanoutRejection(.unsupported_backend),
            .outputUnavailable = self.directScanoutRejection(.output_unavailable),
            .outputBusy = self.directScanoutRejection(.output_busy),
            .deviceInactive = self.directScanoutRejection(.device_inactive),
            .unsupportedFormatOrModifier = self.directScanoutRejection(.unsupported_format_or_modifier),
            .unsupportedLayout = self.directScanoutRejection(.unsupported_layout),
            .framebufferImportFailed = self.directScanoutRejection(.framebuffer_import_failed),
            .pageFlipFailed = self.directScanoutRejection(.page_flip_failed),
        },
        .overlayScanoutCandidates = wireInteger(self.overlay_scanout_candidates),
        .overlayScanoutFrames = wireInteger(self.overlay_scanout_frames),
        .overlayScanoutRejections = .{
            .noTopmostSurface = self.overlayScanoutRejection(.no_topmost_surface),
            .nonOpaqueSurface = self.overlayScanoutRejection(.non_opaque_surface),
            .clippedSurface = self.overlayScanoutRejection(.clipped_surface),
            .transformedSurface = self.overlayScanoutRejection(.transformed_surface),
            .scaledSurface = self.overlayScanoutRejection(.scaled_surface),
            .outsideOutput = self.overlayScanoutRejection(.outside_output),
            .nonDmabuf = self.overlayScanoutRejection(.non_dmabuf),
            .nonRgbSurface = self.overlayScanoutRejection(.non_rgb_surface),
            .yInverted = self.overlayScanoutRejection(.y_inverted),
            .missingBufferIdentity = self.overlayScanoutRejection(.missing_buffer_identity),
            .colorConversion = self.overlayScanoutRejection(.color_conversion),
            .unsupportedBackend = self.overlayScanoutRejection(.unsupported_backend),
            .outputUnavailable = self.overlayScanoutRejection(.output_unavailable),
            .outputBusy = self.overlayScanoutRejection(.output_busy),
            .deviceInactive = self.overlayScanoutRejection(.device_inactive),
            .noOverlayPlane = self.overlayScanoutRejection(.no_overlay_plane),
            .unsupportedFormatOrModifier = self.overlayScanoutRejection(.unsupported_format_or_modifier),
            .unsupportedLayout = self.overlayScanoutRejection(.unsupported_layout),
            .synchronizationFailed = self.overlayScanoutRejection(.synchronization_failed),
            .framebufferImportFailed = self.overlayScanoutRejection(.framebuffer_import_failed),
            .atomicTestFailed = self.overlayScanoutRejection(.atomic_test_failed),
            .pageFlipFailed = self.overlayScanoutRejection(.page_flip_failed),
        },
        .cpuUploads = wireInteger(self.cpu_uploads),
        .dmabufImports = wireInteger(self.dmabuf_imports),
        .framesOverBudget = wireInteger(self.frames_over_budget),
        .repaintsDelayed = wireInteger(self.repaints_delayed),
        .repaintsImmediate = wireInteger(self.repaints_immediate),
        .renderBudgetResetsMissedDeadline = wireInteger(self.render_budget_resets_missed),
        .renderBudgetResetsNoTiming = wireInteger(self.render_budget_resets_no_timing),
        .renderBudgetMicroseconds = wireInteger(
            nanosecondsToMicroseconds(render_budget_nanoseconds orelse 0),
        ),
        .renderFenceSamples = wireInteger(self.render_fence_samples),
        .renderFencesSignaledBeforeCommit = wireInteger(
            self.render_fences_signaled_before_commit,
        ),
        .gpuExecution = self.gpuExecutionSummary(.total),
        .gpuComposition = self.gpuExecutionSummary(.composition),
        .gpuPreparation = self.gpuExecutionSummary(.preparation),
        .gpuSolidComposition = self.gpuExecutionSummary(.solid_composition),
        .gpuImageComposition = self.gpuExecutionSummary(.image_composition),
        .gpuShadow = self.gpuExecutionSummary(.shadow),
        .gpuBlurDownsample = self.gpuExecutionSummary(.blur_downsample),
        .gpuBlurUpsample = self.gpuExecutionSummary(.blur_upsample),
        .gpuBlurComposite = self.gpuExecutionSummary(.blur_composite),
        .gpuCompositionOverhead = self.gpuExecutionSummary(.composition_overhead),
        .gpuOutputEncode = self.gpuExecutionSummary(.output_encode),
        .gpuFrameFinish = self.gpuExecutionSummary(.frame_finish),
        .requestToPresentation = self.latencySummary(.request_to_presentation),
        .requestToRender = self.latencySummary(.request_to_render),
        .renderToCommit = self.latencySummary(.render_to_commit),
        .commitToPresentation = self.latencySummary(.commit_to_presentation),
        .renderToGpuCompletion = self.latencySummary(.render_to_gpu_completion),
        .gpuCompletionToPresentation = self.latencySummary(
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
        .p50Microseconds = wireInteger(percentile(sorted, 50)),
        .p95Microseconds = wireInteger(percentile(sorted, 95)),
        .p99Microseconds = wireInteger(percentile(sorted, 99)),
        .maximumMicroseconds = wireInteger(sorted[sorted.len - 1]),
    };
}

fn gpuExecutionSummary(
    self: *const FrameStatistics,
    comptime kind: GpuExecutionKind,
) ControlProtocol.LatencyStatistics {
    const no_samples: ControlProtocol.LatencyStatistics = .{
        .samples = 0,
        .p50Microseconds = 0,
        .p95Microseconds = 0,
        .p99Microseconds = 0,
        .maximumMicroseconds = 0,
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
        .p50Microseconds = wireInteger(percentile(sorted, 50)),
        .p95Microseconds = wireInteger(percentile(sorted, 95)),
        .p99Microseconds = wireInteger(percentile(sorted, 99)),
        .maximumMicroseconds = wireInteger(sorted[sorted.len - 1]),
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
    format: Renderer.WorkingFormat,
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
    try std.testing.expectEqual(@as(i64, 200), summary.p50Microseconds);
    try std.testing.expectEqual(@as(i64, 400), summary.p95Microseconds);
    try std.testing.expectEqual(@as(i64, 400), summary.p99Microseconds);
    try std.testing.expectEqual(@as(i64, 400), summary.maximumMicroseconds);

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
    try std.testing.expectEqual(@as(i64, 2_200), gpu_summary.p50Microseconds);
    try std.testing.expectEqual(@as(i64, 3_300), gpu_summary.p95Microseconds);
    try std.testing.expectEqual(@as(i64, 3_300), gpu_summary.maximumMicroseconds);
    try std.testing.expectEqual(
        @as(i64, 1_400),
        statistics.gpuExecutionSummary(.composition).p50Microseconds,
    );
    try std.testing.expectEqual(
        @as(i64, 600),
        statistics.gpuExecutionSummary(.output_encode).p50Microseconds,
    );
    try std.testing.expectEqual(
        @as(i64, 200),
        statistics.gpuExecutionSummary(.preparation).p50Microseconds,
    );
    try std.testing.expectEqual(
        @as(i64, 400),
        statistics.gpuExecutionSummary(.image_composition).p50Microseconds,
    );
    try std.testing.expectEqual(
        @as(i64, 200),
        statistics.gpuExecutionSummary(.frame_finish).p50Microseconds,
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
        null,
    );
    try std.testing.expectEqual(ControlProtocol.FramePath.composited, output_snapshot.lastFrame.path);
    // A cold repaint-delay budget reports zero microseconds.
    try std.testing.expectEqual(@as(i64, 0), output_snapshot.renderBudgetMicroseconds);
    try std.testing.expectEqual(ControlProtocol.BufferFormat.rgba16f_linear, output_snapshot.lastFrame.workingFormat);
    try std.testing.expectEqual(ControlProtocol.BufferFormat.xrgb8888, output_snapshot.lastFrame.scanoutFormat);
    try std.testing.expectEqual(@as(i64, 3), output_snapshot.lastFrame.damageRectangles);
    try std.testing.expectEqual(@as(i64, 225), output_snapshot.lastFrame.damagedPixels);
    try std.testing.expectEqual(@as(i64, 1), output_snapshot.overlayScanoutRejections.noOverlayPlane);
    try std.testing.expectEqual(@as(i64, 2), output_snapshot.overlayScanoutRejections.atomicTestFailed);

    statistics.recordFrame(.overlay_scanout, .xrgb8888, &damage);
    const overlay_snapshot = statistics.snapshot(
        "HEADLESS-1",
        .{ .width = 100, .height = 100 },
        60_000,
        .rgba16f_linear,
        1_500 * std.time.ns_per_us,
    );
    try std.testing.expectEqual(ControlProtocol.FramePath.overlay_scanout, overlay_snapshot.lastFrame.path);
    try std.testing.expectEqual(@as(i64, 1_500), overlay_snapshot.renderBudgetMicroseconds);

    // Time queued behind an already-submitted frame is request latency, not
    // compositor work exceeding the next presentation budget.
    statistics.recordPresentation(.{
        .request_nanoseconds = 0,
        .render_nanoseconds = 10 * std.time.ns_per_ms,
        .commit_nanoseconds = 11 * std.time.ns_per_ms,
    }, 20 * std.time.ns_per_ms, 10 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u64, 1), statistics.frames_presented);
    try std.testing.expectEqual(@as(u64, 0), statistics.frames_over_budget);

    statistics.recordPresentation(.{
        .request_nanoseconds = 20 * std.time.ns_per_ms,
        .render_nanoseconds = 21 * std.time.ns_per_ms,
        .commit_nanoseconds = 24 * std.time.ns_per_ms,
        .render_completion_nanoseconds = 23 * std.time.ns_per_ms,
    }, 30 * std.time.ns_per_ms, 10 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u64, 0), statistics.frames_over_budget);
    try std.testing.expectEqual(
        @as(i64, 2_000),
        statistics.latencySummary(.render_to_gpu_completion).p50Microseconds,
    );
    try std.testing.expectEqual(
        @as(i64, 7_000),
        statistics.latencySummary(.gpu_completion_to_presentation).p50Microseconds,
    );
    try std.testing.expectEqual(@as(u64, 1), statistics.render_fence_samples);
    try std.testing.expectEqual(@as(u64, 1), statistics.render_fences_signaled_before_commit);

    statistics.recordPresentation(.{
        .request_nanoseconds = 30 * std.time.ns_per_ms,
        .render_nanoseconds = 31 * std.time.ns_per_ms,
        .commit_nanoseconds = 32 * std.time.ns_per_ms,
    }, 43 * std.time.ns_per_ms, 10 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u64, 1), statistics.frames_over_budget);

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
    try std.testing.expectEqual(@as(i64, sample_capacity), rolling.maximumMicroseconds);
}
