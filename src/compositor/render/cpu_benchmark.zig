//! Repeatable standalone benchmark for the Pixman CPU renderer.

const std = @import("std");
const CpuRenderer = @import("cpu.zig");
const render = @import("types.zig");

const size: render.Size = .{ .width = 640, .height = 400 };
const window: render.Rect = .{ .x = 80, .y = 55, .width = 480, .height = 290 };
const warmup_iterations = 3;
const sample_count = 9;
const iterations_per_sample = 15;

const Scenario = struct {
    name: []const u8,
    commands: []const render.Command,
    damage: ?[]const render.Rect = null,
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const pixel_count = try size.pixelCount();
    const target_pixels = try allocator.alloc(u32, pixel_count);
    defer allocator.free(target_pixels);
    const source_a = try allocator.alloc(u32, pixel_count);
    defer allocator.free(source_a);
    const source_b = try allocator.alloc(u32, pixel_count);
    defer allocator.free(source_b);
    for (source_a, source_b, 0..) |*a, *b, index| {
        const value: u32 = @truncate(index *% 2_654_435_761);
        a.* = 0xff00_0000 | (value & 0x00ff_ffff);
        b.* = 0xff00_0000 | (~value & 0x00ff_ffff);
    }
    @memset(target_pixels, 0xff18_2028);

    const source_buffer: render.PixelBuffer = .{
        .size = size,
        .stride_pixels = size.width,
        .pixels = source_a,
    };
    const source_buffer_b: render.PixelBuffer = .{
        .size = size,
        .stride_pixels = size.width,
        .pixels = source_b,
    };
    const target: render.PixelBuffer = .{
        .size = size,
        .stride_pixels = size.width,
        .pixels = target_pixels,
    };
    const clear: render.Command = .{ .clear = render.Color.rgba(24, 32, 40, 255) };
    const full_image: render.Image = .{
        .x = 0,
        .y = 0,
        .size = size,
        .buffer = source_buffer,
        .is_opaque = true,
    };
    const finish: render.BackdropBlurFinish = .{
        .brightness = 0.88,
        .contrast = 0.87,
        .saturation = 1,
        .noise = 0.003,
    };
    const rounded: render.RoundedClip = .{ .rect = window, .radius = 12 };
    const full_damage = [_]render.Rect{.{ .x = 0, .y = 0, .width = size.width, .height = size.height }};
    const small_damage = [_]render.Rect{.{ .x = 280, .y = 180, .width = 80, .height = 50 }};
    const unrelated_damage = [_]render.Rect{.{ .x = 0, .y = 0, .width = 32, .height = 32 }};

    const baseline = [_]render.Command{ clear, .{ .image = full_image } };
    const unused_capture = [_]render.Command{ clear, .{ .image = full_image }, .{ .backdrop_capture = .{
        .id = 1,
        .rect = .{ .x = 0, .y = 0, .width = size.width, .height = size.height },
        .radius = 48,
        .downsample_level = 4,
        .finish = finish,
        .base = true,
    } } };
    const used_blur = [_]render.Command{ clear, .{ .image = full_image }, .{ .backdrop_capture = .{
        .id = 2,
        .rect = window,
        .radius = 48,
        .downsample_level = 4,
        .finish = finish,
    } }, .{ .backdrop_blur = .{
        .capture_id = 2,
        .rect = window,
        .corner_radius = 12,
        .radius = 48,
        .downsample_level = 4,
        .finish = finish,
    } } };
    const used_blur_neutral = [_]render.Command{ clear, .{ .image = full_image }, .{ .backdrop_capture = .{
        .id = 3,
        .rect = window,
        .radius = 48,
        .downsample_level = 4,
    } }, .{ .backdrop_blur = .{
        .capture_id = 3,
        .rect = window,
        .corner_radius = 12,
        .radius = 48,
        .downsample_level = 4,
    } } };
    const rounded_images = [_]render.Command{
        clear,
        .{ .image = .{ .x = 80, .y = 55, .size = .{ .width = 480, .height = 145 }, .buffer = source_buffer, .rounded_clip = rounded, .is_opaque = true } },
        .{ .image = .{ .x = 80, .y = 200, .size = .{ .width = 240, .height = 145 }, .buffer = source_buffer, .source = .{ .x = 0, .y = 145, .width = 240, .height = 145 }, .rounded_clip = rounded, .is_opaque = true } },
        .{ .image = .{ .x = 320, .y = 200, .size = .{ .width = 240, .height = 145 }, .buffer = source_buffer, .source = .{ .x = 240, .y = 145, .width = 240, .height = 145 }, .rounded_clip = rounded, .is_opaque = true } },
    };
    const shadows = [_]render.Command{ clear, .{ .shadow = .{
        .rect = window,
        .corner_radius = 12,
        .blur_radius = 2,
        .spread = 0,
        .color = render.Color.rgba(0, 0, 0, 0x3d),
        .cutout = rounded,
    } }, .{ .shadow = .{
        .rect = .{ .x = window.x, .y = window.y + 2, .width = window.width, .height = window.height },
        .corner_radius = 12,
        .blur_radius = 4,
        .spread = 0,
        .color = render.Color.rgba(0, 0, 0, 0x47),
        .cutout = rounded,
    } } };
    const crossfade_zero = [_]render.Command{ clear, .{ .crossfade = .{
        .destination = window,
        .old = .{ .pixels = source_buffer },
        .new = .{ .pixels = source_buffer_b },
        .factor = 0,
        .rounded_clip = rounded,
    } } };
    const crossfade_midpoint = [_]render.Command{ clear, .{ .crossfade = .{
        .destination = window,
        .old = .{ .pixels = source_buffer },
        .new = .{ .pixels = source_buffer_b },
        .factor = std.math.maxInt(u32) / 2,
        .rounded_clip = rounded,
    } } };
    const scenarios = [_]Scenario{
        .{ .name = "plain_opaque_image", .commands = &baseline },
        .{ .name = "unused_full_frame_base_capture", .commands = &unused_capture },
        .{ .name = "used_backdrop_capture_blur", .commands = &used_blur },
        .{ .name = "used_backdrop_capture_neutral_finish", .commands = &used_blur_neutral },
        .{ .name = "used_backdrop_capture_undamaged", .commands = &used_blur, .damage = &unrelated_damage },
        .{ .name = "rounded_opaque_subsurface_images", .commands = &rounded_images },
        .{ .name = "default_shadows_full_damage", .commands = &shadows, .damage = &full_damage },
        .{ .name = "default_shadows_small_damage", .commands = &shadows, .damage = &small_damage },
        .{ .name = "crossfade_factor_zero", .commands = &crossfade_zero },
        .{ .name = "crossfade_midpoint", .commands = &crossfade_midpoint },
        .{ .name = "crossfade_midpoint_small_damage", .commands = &crossfade_midpoint, .damage = &small_damage },
    };

    var renderer = CpuRenderer.init(allocator);
    defer renderer.deinit();
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &output_buffer);
    defer output.interface.flush() catch {};
    try output.interface.print("cpu-renderer benchmark: ReleaseFast size={}x{} warmup={} samples={} iterations/sample={}\n", .{ size.width, size.height, warmup_iterations, sample_count, iterations_per_sample });
    var checksum: u64 = 0xcbf29ce484222325;
    for (scenarios) |scenario| {
        const scenario_checksum = try benchmark(&renderer, target, scenario, &output.interface);
        checksum = (checksum ^ scenario_checksum) *% 0x100000001b3;
    }
    try output.interface.print("combined_checksum={x}\n", .{checksum});
}

fn benchmark(renderer: *CpuRenderer, target: render.PixelBuffer, scenario: Scenario, writer: *std.Io.Writer) !u64 {
    const frame: render.Frame = .{ .size = size, .commands = scenario.commands, .damage = scenario.damage };
    @memset(target.pixels, 0xff18_2028);
    for (0..warmup_iterations) |_| try renderer.render(frame, target);
    var samples: [sample_count]u64 = undefined;
    for (&samples) |*sample| {
        const start = monotonicNanoseconds();
        for (0..iterations_per_sample) |_| try renderer.render(frame, target);
        const elapsed = monotonicNanoseconds() - start;
        sample.* = elapsed / iterations_per_sample;
    }
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    var checksum: u64 = 0xcbf29ce484222325;
    for (target.pixels) |pixel| checksum = (checksum ^ pixel) *% 0x100000001b3;
    try writer.print("{s}: median_ns/frame={} min={} max={} checksum={x}\n", .{
        scenario.name,
        samples[sample_count / 2],
        samples[0],
        samples[sample_count - 1],
        checksum,
    });
    return checksum;
}

fn monotonicNanoseconds() u64 {
    var timestamp: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &timestamp);
    return @as(u64, @intCast(timestamp.sec)) * std.time.ns_per_s + @as(u64, @intCast(timestamp.nsec));
}
