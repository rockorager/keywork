//! Command-line client for Keywork's compositor control interface.

const std = @import("std");
const control = @import("keywork-control");
const varlink = @import("varlink");
const Empty = struct {};

const usage =
    \\usage: keyworkctl COMMAND [ARGUMENT...]
    \\
    \\commands: focus DIRECTION | move-focused DIRECTION | set-layout LAYOUT
    \\          close TARGET
    \\          toggle-fullscreen TARGET | toggle-floating TARGET
    \\          switch-workspace WORKSPACE | move-focused-to-workspace WORKSPACE
    \\          set-unfocused-border WIDTH COLOR
    \\          windows [--json] | stats [--json] [--reset]
    \\          set-log-level LEVEL | reload | quit
    \\directions: next, previous, left, down, up, right
    \\targets: focused
    \\layouts: tiled
    \\workspaces: 1..10
    \\log levels: error, warning, info, debug
    \\colors: '#RRGGBB' or '#RRGGBBAA'
    \\
;

const Command = union(enum) {
    focus: control.Direction,
    move_focused: control.Direction,
    close: control.WindowTarget,
    toggle_fullscreen: control.WindowTarget,
    toggle_floating: control.WindowTarget,
    set_layout: control.Layout,
    switch_workspace: i64,
    move_to_workspace: i64,
    windows: WindowOptions,
    stats: StatisticsOptions,
    set_unfocused_border: control.Border,
    set_log_level: control.LogLevel,
    reload,
    quit,
};

const StatisticsOptions = struct {
    reset: bool = false,
    json: bool = false,
};

const WindowOptions = struct {
    json: bool = false,
};

const WindowParameters = struct {
    windows: []const control.Window,
};

const StatisticsParameters = struct {
    outputs: []const control.OutputStatistics,
};

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
    var arguments: [3][]const u8 = undefined;
    var count: usize = 0;
    while (iterator.next()) |argument| {
        if (count == arguments.len) return printUsage(init.io, error.InvalidArguments);
        arguments[count] = argument;
        count += 1;
    }
    if (count == 1 and std.mem.eql(u8, arguments[0], "--help")) {
        var buffer: [2048]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(init.io, &buffer);
        defer stdout.interface.flush() catch {};
        try stdout.interface.writeAll(usage);
        return;
    }
    const command = parse(arguments[0..count]) catch |err| return printUsage(init.io, err);

    const runtime_directory = init.environ_map.get("XDG_RUNTIME_DIR") orelse
        return error.MissingRuntimeDirectory;
    const address = try controlAddress(init.gpa, runtime_directory);
    defer init.gpa.free(address);
    var client = try varlink.Client.connect(init.gpa, init.io, address);
    defer client.deinit();
    var reply = switch (command) {
        .focus => |direction| try client.call(control.focus_method, .{ .direction = direction }),
        .move_focused => |direction| try client.call(control.move_focused_method, .{ .direction = direction }),
        .close => |target| try client.call(control.close_method, .{ .target = target }),
        .toggle_fullscreen => |target| try client.call(control.toggle_fullscreen_method, .{ .target = target }),
        .toggle_floating => |target| try client.call(control.toggle_floating_method, .{ .target = target }),
        .set_layout => |layout| try client.call(control.set_layout_method, .{ .layout = layout }),
        .switch_workspace => |workspace| try client.call(control.switch_workspace_method, .{ .workspace = workspace }),
        .move_to_workspace => |workspace| try client.call(control.move_focused_to_workspace_method, .{ .workspace = workspace }),
        .windows => try client.call(control.get_windows_method, Empty{}),
        .stats => |options| try client.call(control.get_performance_statistics_method, .{ .reset = options.reset }),
        .set_unfocused_border => |border| try client.call(control.set_unfocused_border_method, .{ .border = border }),
        .set_log_level => |level| try client.call(control.set_log_level_method, .{ .level = level }),
        .reload => try client.call(control.reload_configuration_method, Empty{}),
        .quit => try client.call(control.quit_method, Empty{}),
    };
    defer reply.deinit();
    if (reply.value.@"error") |name| {
        var buffer: [1024]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(init.io, &buffer);
        if (remoteErrorMessage(name, reply.value.parameters)) |message| {
            try stderr.interface.print("keyworkctl: {s}\n", .{message});
        } else {
            try stderr.interface.print("keyworkctl: Varlink error: {s}\n", .{name});
        }
        try stderr.interface.flush();
        return error.RemoteError;
    }
    if (reply.value.continues) return error.UnexpectedContinuation;
    switch (command) {
        .windows => |options| try printWindows(
            init.io,
            init.gpa,
            reply.value.parameters,
            options.json,
        ),
        .stats => |options| try printStatistics(
            init.io,
            init.gpa,
            reply.value.parameters,
            options.json,
        ),
        else => {},
    }
}

fn printWindows(
    io: std.Io,
    allocator: std.mem.Allocator,
    parameters: ?std.json.Value,
    json: bool,
) !void {
    const parsed = try parseWindowParameters(allocator, parameters);
    defer parsed.deinit();
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    defer stdout.interface.flush() catch {};
    if (json) {
        try writeWindowsJson(&stdout.interface, parsed.value.windows);
    } else {
        try writeWindows(&stdout.interface, parsed.value.windows);
    }
}

fn parseWindowParameters(
    allocator: std.mem.Allocator,
    parameters: ?std.json.Value,
) !std.json.Parsed(WindowParameters) {
    return std.json.parseFromValue(
        WindowParameters,
        allocator,
        parameters orelse return error.MissingWindows,
        .{},
    );
}

fn writeWindows(writer: *std.Io.Writer, windows: []const control.Window) !void {
    if (windows.len == 0) return writer.writeAll("No windows.\n");
    for (windows) |window| {
        try writer.writeAll(if (window.focused) "* " else "  ");
        try writeDisplayString(writer, window.id);
        if (window.app_id) |app_id| {
            try writer.writeByte(' ');
            try writeDisplayString(writer, app_id);
        }
        if (window.title) |title| {
            try writer.writeAll(" \"");
            try writeDisplayString(writer, title);
            try writer.writeByte('"');
        }
        try writer.print("\n  {s}, ", .{windowProtocolName(window.protocol)});
        try writeDisplayString(writer, window.output);
        try writer.print(" workspace {d}, ", .{window.workspace});
        if (window.rect) |rect| {
            try writer.print("{d},{d} {d}x{d}", .{ rect.x, rect.y, rect.width, rect.height });
        } else {
            try writer.writeAll("unplaced");
        }
        try writer.print(", {s}, {s}", .{
            if (window.visible) "visible" else "hidden",
            if (window.floating) "floating" else "tiled",
        });
        if (window.fullscreen) try writer.writeAll(", fullscreen");
        if (window.maximized) try writer.writeAll(", maximized");
        if (window.minimized) try writer.writeAll(", minimized");
        try writer.writeByte('\n');
    }
}

fn writeDisplayString(writer: *std.Io.Writer, value: []const u8) !void {
    const hexadecimal = "0123456789abcdef";
    for (value) |byte| switch (byte) {
        '\\' => try writer.writeAll("\\\\"),
        '"' => try writer.writeAll("\\\""),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => if (std.ascii.isControl(byte)) {
            try writer.writeAll("\\x");
            try writer.writeByte(hexadecimal[byte >> 4]);
            try writer.writeByte(hexadecimal[byte & 0x0f]);
        } else {
            try writer.writeByte(byte);
        },
    };
}

fn writeWindowsJson(writer: *std.Io.Writer, windows: []const control.Window) !void {
    try std.json.Stringify.value(WindowParameters{ .windows = windows }, .{}, writer);
    try writer.writeByte('\n');
}

fn windowProtocolName(protocol: control.WindowProtocol) []const u8 {
    return switch (protocol) {
        .xdg_shell => "xdg-shell",
        .xwayland => "xwayland",
    };
}

fn printStatistics(
    io: std.Io,
    allocator: std.mem.Allocator,
    parameters: ?std.json.Value,
    json: bool,
) !void {
    const parsed = try parseStatisticsParameters(allocator, parameters);
    defer parsed.deinit();
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    defer stdout.interface.flush() catch {};
    if (json) {
        try writeStatisticsJson(&stdout.interface, parsed.value.outputs);
    } else {
        try writeStatistics(&stdout.interface, parsed.value.outputs);
    }
}

fn parseStatisticsParameters(
    allocator: std.mem.Allocator,
    parameters: ?std.json.Value,
) !std.json.Parsed(StatisticsParameters) {
    return std.json.parseFromValue(
        StatisticsParameters,
        allocator,
        parameters orelse return error.MissingStatistics,
        .{},
    );
}

fn writeStatistics(writer: *std.Io.Writer, outputs: []const control.OutputStatistics) !void {
    if (outputs.len == 0) return writer.writeAll("No active outputs.\n");
    for (outputs, 0..) |output, index| {
        if (index != 0) try writer.writeByte('\n');
        try writer.print("{s} {d}x{d} ({d}.", .{
            output.name,
            output.width,
            output.height,
            @divTrunc(output.refresh_millihertz, 1000),
        });
        const fractional_refresh = @mod(output.refresh_millihertz, 1000);
        if (fractional_refresh < 10) {
            try writer.print("00{d}", .{fractional_refresh});
        } else if (fractional_refresh < 100) {
            try writer.print("0{d}", .{fractional_refresh});
        } else {
            try writer.print("{d}", .{fractional_refresh});
        }
        try writer.writeAll(" Hz)\n");
        try writeFrameDiagnostics(writer, output.last_frame);
        try writer.print(
            "  frames: requested {d}, started {d}, presented {d}, discarded {d}\n",
            .{
                output.frames_requested,
                output.frames_started,
                output.frames_presented,
                output.frames_discarded,
            },
        );
        try writer.print(
            "  paths: composited {d}, direct scanout {d}/{d} candidates, overlay scanout {d}/{d} candidates\n",
            .{
                output.composited_frames,
                output.direct_scanout_frames,
                output.direct_scanout_candidates,
                output.overlay_scanout_frames,
                output.overlay_scanout_candidates,
            },
        );
        try writeDirectScanoutRejections(writer, output.direct_scanout_rejections);
        try writeOverlayScanoutRejections(writer, output.overlay_scanout_rejections);
        try writer.print("  buffer operations: CPU uploads {d}, DMA-BUF imports {d}\n", .{
            output.cpu_uploads,
            output.dmabuf_imports,
        });
        try writer.print("  acquire retries: {d}, frames over budget: {d}\n", .{
            output.acquire_retries,
            output.frames_over_budget,
        });
        try writeLatency(writer, "GPU total", output.gpu_execution);
        try writeLatency(writer, "GPU composition/effects", output.gpu_composition);
        try writeLatency(writer, "GPU preparation/uploads", output.gpu_preparation);
        try writeLatency(writer, "GPU solid composition", output.gpu_solid_composition);
        try writeLatency(writer, "GPU image composition", output.gpu_image_composition);
        try writeLatency(writer, "GPU shadows", output.gpu_shadow);
        try writeLatency(writer, "GPU blur downsample", output.gpu_blur_downsample);
        try writeLatency(writer, "GPU blur upsample", output.gpu_blur_upsample);
        try writeLatency(writer, "GPU blur composite", output.gpu_blur_composite);
        try writeLatency(writer, "GPU composition overhead", output.gpu_composition_overhead);
        try writeLatency(writer, "GPU output encode", output.gpu_output_encode);
        try writeLatency(writer, "GPU frame finish", output.gpu_frame_finish);
        try writeLatency(writer, "request -> presentation", output.request_to_presentation);
        try writeLatency(writer, "request -> render", output.request_to_render);
        try writeLatency(writer, "render -> commit", output.render_to_commit);
        try writeLatency(writer, "commit -> presentation", output.commit_to_presentation);
        try writer.print("  render fences signaled before commit: {d}/{d}\n", .{
            output.render_fences_signaled_before_commit,
            output.render_fence_samples,
        });
        try writeLatency(writer, "render -> GPU completion", output.render_to_gpu_completion);
        try writeLatency(
            writer,
            "GPU completion -> presentation",
            output.gpu_completion_to_presentation,
        );
    }
}

fn writeStatisticsJson(writer: *std.Io.Writer, outputs: []const control.OutputStatistics) !void {
    try std.json.Stringify.value(StatisticsParameters{ .outputs = outputs }, .{}, writer);
    try writer.writeByte('\n');
}

fn writeFrameDiagnostics(
    writer: *std.Io.Writer,
    diagnostics: control.FrameDiagnostics,
) !void {
    try writer.print(
        "  last frame: {s}, working {s}, scanout {s}, transform {s}\n",
        .{
            framePathName(diagnostics.path),
            bufferFormatName(diagnostics.working_format),
            bufferFormatName(diagnostics.scanout_format),
            @tagName(diagnostics.output_transform),
        },
    );
    try writer.print("  damage: {d} rectangles, {d} pixels\n", .{
        diagnostics.damage_rectangles,
        diagnostics.damaged_pixels,
    });
}

fn framePathName(path: control.FramePath) []const u8 {
    return switch (path) {
        .none => "none",
        .composited => "composited",
        .direct_scanout => "direct scanout",
        .overlay_scanout => "overlay scanout",
    };
}

fn bufferFormatName(format: control.BufferFormat) []const u8 {
    return switch (format) {
        .none => "none",
        .argb8888 => "ARGB8888",
        .xrgb8888 => "XRGB8888",
        .abgr8888 => "ABGR8888",
        .xbgr8888 => "XBGR8888",
        .xrgb2101010 => "XRGB2101010",
        .rgba16f_linear => "RGBA16F linear",
    };
}

fn writeLatency(
    writer: *std.Io.Writer,
    label: []const u8,
    latency: control.LatencyStatistics,
) !void {
    try writer.print(
        "  {s}: p50 {d}us, p95 {d}us, p99 {d}us, max {d}us ({d} samples)\n",
        .{
            label,
            latency.p50_microseconds,
            latency.p95_microseconds,
            latency.p99_microseconds,
            latency.maximum_microseconds,
            latency.samples,
        },
    );
}

fn writeDirectScanoutRejections(
    writer: *std.Io.Writer,
    rejections: control.DirectScanoutRejections,
) !void {
    var wrote_rejection = false;
    try writeDirectScanoutRejection(writer, &wrote_rejection, "no fullscreen surface", rejections.no_fullscreen_surface);
    try writeDirectScanoutRejection(writer, &wrote_rejection, "non-opaque surface", rejections.non_opaque_surface);
    try writeDirectScanoutRejection(writer, &wrote_rejection, "surface transform", rejections.surface_transform);
    try writeDirectScanoutRejection(writer, &wrote_rejection, "non-DMA-BUF", rejections.non_dmabuf);
    try writeDirectScanoutRejection(writer, &wrote_rejection, "Y-inverted buffer", rejections.y_inverted);
    try writeDirectScanoutRejection(writer, &wrote_rejection, "missing buffer identity", rejections.missing_buffer_identity);
    try writeDirectScanoutRejection(writer, &wrote_rejection, "color conversion", rejections.color_conversion);
    try writeDirectScanoutRejection(writer, &wrote_rejection, "unsupported backend", rejections.unsupported_backend);
    try writeDirectScanoutRejection(writer, &wrote_rejection, "output unavailable", rejections.output_unavailable);
    try writeDirectScanoutRejection(writer, &wrote_rejection, "output busy", rejections.output_busy);
    try writeDirectScanoutRejection(writer, &wrote_rejection, "device inactive", rejections.device_inactive);
    try writeDirectScanoutRejection(writer, &wrote_rejection, "unsupported format/modifier", rejections.unsupported_format_or_modifier);
    try writeDirectScanoutRejection(writer, &wrote_rejection, "unsupported layout", rejections.unsupported_layout);
    try writeDirectScanoutRejection(writer, &wrote_rejection, "framebuffer import failed", rejections.framebuffer_import_failed);
    try writeDirectScanoutRejection(writer, &wrote_rejection, "page flip failed", rejections.page_flip_failed);
    if (!wrote_rejection) try writer.writeAll("  direct scanout rejections: none\n");
}

fn writeDirectScanoutRejection(
    writer: *std.Io.Writer,
    wrote_rejection: *bool,
    label: []const u8,
    count: i64,
) !void {
    return writeScanoutRejection(
        writer,
        wrote_rejection,
        "direct scanout",
        label,
        count,
    );
}

fn writeOverlayScanoutRejections(
    writer: *std.Io.Writer,
    rejections: control.OverlayScanoutRejections,
) !void {
    var wrote_rejection = false;
    try writeOverlayScanoutRejection(writer, &wrote_rejection, "no topmost surface", rejections.no_topmost_surface);
    try writeOverlayScanoutRejection(writer, &wrote_rejection, "non-opaque surface", rejections.non_opaque_surface);
    try writeOverlayScanoutRejection(writer, &wrote_rejection, "clipped surface", rejections.clipped_surface);
    try writeOverlayScanoutRejection(writer, &wrote_rejection, "transformed surface", rejections.transformed_surface);
    try writeOverlayScanoutRejection(writer, &wrote_rejection, "scaled surface", rejections.scaled_surface);
    try writeOverlayScanoutRejection(writer, &wrote_rejection, "outside output", rejections.outside_output);
    try writeOverlayScanoutRejection(writer, &wrote_rejection, "non-DMA-BUF", rejections.non_dmabuf);
    try writeOverlayScanoutRejection(writer, &wrote_rejection, "non-RGB surface", rejections.non_rgb_surface);
    try writeOverlayScanoutRejection(writer, &wrote_rejection, "Y-inverted buffer", rejections.y_inverted);
    try writeOverlayScanoutRejection(writer, &wrote_rejection, "missing buffer identity", rejections.missing_buffer_identity);
    try writeOverlayScanoutRejection(writer, &wrote_rejection, "color conversion", rejections.color_conversion);
    try writeOverlayScanoutRejection(writer, &wrote_rejection, "unsupported backend", rejections.unsupported_backend);
    try writeOverlayScanoutRejection(writer, &wrote_rejection, "output unavailable", rejections.output_unavailable);
    try writeOverlayScanoutRejection(writer, &wrote_rejection, "output busy", rejections.output_busy);
    try writeOverlayScanoutRejection(writer, &wrote_rejection, "device inactive", rejections.device_inactive);
    try writeOverlayScanoutRejection(writer, &wrote_rejection, "no overlay plane", rejections.no_overlay_plane);
    try writeOverlayScanoutRejection(writer, &wrote_rejection, "unsupported format/modifier", rejections.unsupported_format_or_modifier);
    try writeOverlayScanoutRejection(writer, &wrote_rejection, "unsupported layout", rejections.unsupported_layout);
    try writeOverlayScanoutRejection(writer, &wrote_rejection, "synchronization failed", rejections.synchronization_failed);
    try writeOverlayScanoutRejection(writer, &wrote_rejection, "framebuffer import failed", rejections.framebuffer_import_failed);
    try writeOverlayScanoutRejection(writer, &wrote_rejection, "atomic test failed", rejections.atomic_test_failed);
    try writeOverlayScanoutRejection(writer, &wrote_rejection, "page flip failed", rejections.page_flip_failed);
    if (!wrote_rejection) try writer.writeAll("  overlay scanout rejections: none\n");
}

fn writeOverlayScanoutRejection(
    writer: *std.Io.Writer,
    wrote_rejection: *bool,
    label: []const u8,
    count: i64,
) !void {
    return writeScanoutRejection(
        writer,
        wrote_rejection,
        "overlay scanout",
        label,
        count,
    );
}

fn writeScanoutRejection(
    writer: *std.Io.Writer,
    wrote_rejection: *bool,
    heading: []const u8,
    label: []const u8,
    count: i64,
) !void {
    if (count == 0) return;
    if (!wrote_rejection.*) {
        try writer.print("  {s} rejections:\n", .{heading});
        wrote_rejection.* = true;
    }
    try writer.print("    {s}: {d}\n", .{ label, count });
}

fn controlAddress(allocator: std.mem.Allocator, runtime_directory: []const u8) ![]u8 {
    if (!std.fs.path.isAbsolute(runtime_directory)) return error.InvalidRuntimeDirectory;
    return std.fmt.allocPrint(
        allocator,
        "unix:{s}/{s}",
        .{ runtime_directory, control.socket_name },
    );
}

fn remoteErrorMessage(name: []const u8, parameters: ?std.json.Value) ?[]const u8 {
    if (!std.mem.eql(u8, name, control.configuration_reload_failed_error)) return null;
    const value = parameters orelse return null;
    const object = switch (value) {
        .object => |object| object,
        else => return null,
    };
    const message = object.get("message") orelse return null;
    return switch (message) {
        .string => |string| string,
        else => null,
    };
}

fn printUsage(io: std.Io, err: anyerror) anyerror {
    var buffer: [2048]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buffer);
    defer stderr.interface.flush() catch {};
    stderr.interface.print("keyworkctl: {t}\n{s}", .{ err, usage }) catch {};
    return error.Reported;
}

fn parse(arguments: []const []const u8) !Command {
    if (arguments.len > 0 and std.mem.eql(u8, arguments[0], "windows")) {
        if (arguments.len == 1) return .{ .windows = .{} };
        if (arguments.len == 2 and std.mem.eql(u8, arguments[1], "--json")) {
            return .{ .windows = .{ .json = true } };
        }
        return error.InvalidArguments;
    }
    if (arguments.len > 0 and std.mem.eql(u8, arguments[0], "stats")) {
        var options: StatisticsOptions = .{};
        for (arguments[1..]) |argument| {
            if (std.mem.eql(u8, argument, "--reset") and !options.reset) {
                options.reset = true;
            } else if (std.mem.eql(u8, argument, "--json") and !options.json) {
                options.json = true;
            } else {
                return error.InvalidArguments;
            }
        }
        return .{ .stats = options };
    }
    if (arguments.len == 1 and std.mem.eql(u8, arguments[0], "reload")) return .reload;
    if (arguments.len == 1 and std.mem.eql(u8, arguments[0], "quit")) return .quit;
    if (arguments.len == 3 and std.mem.eql(u8, arguments[0], "set-unfocused-border")) {
        const width = std.fmt.parseInt(i64, arguments[1], 10) catch return error.InvalidBorderWidth;
        if (width < 0 or width > 256) return error.InvalidBorderWidth;
        return .{ .set_unfocused_border = .{
            .width = width,
            .color = parseColor(arguments[2]) orelse return error.InvalidColor,
        } };
    }
    if (arguments.len != 2) return error.InvalidArguments;
    const name = arguments[0];
    const value = arguments[1];
    if (std.mem.eql(u8, name, "focus")) return .{ .focus = parseDirection(value) orelse return error.InvalidDirection };
    if (std.mem.eql(u8, name, "move-focused")) return .{ .move_focused = parseDirection(value) orelse return error.InvalidDirection };
    if (std.mem.eql(u8, name, "close")) return .{ .close = parseWindowTarget(value) orelse return error.InvalidWindowTarget };
    if (std.mem.eql(u8, name, "toggle-fullscreen")) return .{ .toggle_fullscreen = parseWindowTarget(value) orelse return error.InvalidWindowTarget };
    if (std.mem.eql(u8, name, "toggle-floating")) return .{ .toggle_floating = parseWindowTarget(value) orelse return error.InvalidWindowTarget };
    if (std.mem.eql(u8, name, "set-layout")) return .{ .set_layout = parseLayout(value) orelse return error.InvalidLayout };
    if (std.mem.eql(u8, name, "set-log-level")) return .{
        .set_log_level = std.meta.stringToEnum(control.LogLevel, value) orelse
            return error.InvalidLogLevel,
    };
    if (std.mem.eql(u8, name, "switch-workspace")) return .{
        .switch_workspace = try parseWorkspace(value),
    };
    if (std.mem.eql(u8, name, "move-focused-to-workspace")) return .{
        .move_to_workspace = try parseWorkspace(value),
    };
    return error.UnknownCommand;
}

fn parseWorkspace(value: []const u8) !i64 {
    const workspace = std.fmt.parseInt(i64, value, 10) catch return error.InvalidWorkspace;
    if (!control.validWorkspace(workspace)) return error.InvalidWorkspace;
    return workspace;
}

fn parseDirection(value: []const u8) ?control.Direction {
    return std.meta.stringToEnum(control.Direction, value);
}

fn parseWindowTarget(value: []const u8) ?control.WindowTarget {
    return std.meta.stringToEnum(control.WindowTarget, value);
}

fn parseLayout(value: []const u8) ?control.Layout {
    return std.meta.stringToEnum(control.Layout, value);
}

fn parseColor(value: []const u8) ?control.Color {
    if ((value.len != 7 and value.len != 9) or value[0] != '#') return null;
    return .{
        .red = std.fmt.parseInt(u8, value[1..3], 16) catch return null,
        .green = std.fmt.parseInt(u8, value[3..5], 16) catch return null,
        .blue = std.fmt.parseInt(u8, value[5..7], 16) catch return null,
        .alpha = if (value.len == 9)
            std.fmt.parseInt(u8, value[7..9], 16) catch return null
        else
            255,
    };
}

test "CLI parsing maps wire values and validates workspaces" {
    try std.testing.expectEqual(control.Direction.left, (try parse(&.{ "focus", "left" })).focus);
    try std.testing.expectEqual(control.WindowTarget.focused, (try parse(&.{ "close", "focused" })).close);
    try std.testing.expectEqual(control.WindowTarget.focused, (try parse(&.{ "toggle-fullscreen", "focused" })).toggle_fullscreen);
    try std.testing.expectEqual(control.WindowTarget.focused, (try parse(&.{ "toggle-floating", "focused" })).toggle_floating);
    try std.testing.expectEqual(control.Layout.tiled, (try parse(&.{ "set-layout", "tiled" })).set_layout);
    try std.testing.expectEqual(control.LogLevel.debug, (try parse(&.{ "set-log-level", "debug" })).set_log_level);
    try std.testing.expectEqual(@as(i64, 10), (try parse(&.{ "switch-workspace", "10" })).switch_workspace);
    try std.testing.expect(!(try parse(&.{"windows"})).windows.json);
    try std.testing.expect((try parse(&.{ "windows", "--json" })).windows.json);
    try std.testing.expect(!(try parse(&.{"stats"})).stats.reset);
    try std.testing.expect((try parse(&.{ "stats", "--reset" })).stats.reset);
    try std.testing.expect((try parse(&.{ "stats", "--json" })).stats.json);
    const json_reset = (try parse(&.{ "stats", "--json", "--reset" })).stats;
    try std.testing.expect(json_reset.json);
    try std.testing.expect(json_reset.reset);
    try std.testing.expectEqual(control.Border{
        .width = 2,
        .color = .{ .red = 0x3a, .green = 0x3a, .blue = 0x40, .alpha = 0xff },
    }, (try parse(&.{ "set-unfocused-border", "2", "#3a3a40" })).set_unfocused_border);
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "stats", "--json", "--json" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "windows", "--reset" }));
    try std.testing.expectEqual(Command.reload, try parse(&.{"reload"}));
    try std.testing.expectEqual(Command.quit, try parse(&.{"quit"}));
    try std.testing.expectError(error.InvalidWorkspace, parse(&.{ "switch-workspace", "11" }));
    try std.testing.expectError(error.InvalidDirection, parse(&.{ "focus", "sideways" }));
    try std.testing.expectError(error.InvalidWindowTarget, parse(&.{ "close", "all" }));
    try std.testing.expectError(error.InvalidLogLevel, parse(&.{ "set-log-level", "verbose" }));
    try std.testing.expectError(error.InvalidBorderWidth, parse(&.{ "set-unfocused-border", "257", "#3a3a40" }));
    try std.testing.expectError(error.InvalidColor, parse(&.{ "set-unfocused-border", "2", "slate" }));
    try std.testing.expectError(error.UnknownCommand, parse(&.{ "unknown", "value" }));
}

test "control address uses the fixed runtime socket" {
    const address = try controlAddress(std.testing.allocator, "/run/user/1000");
    defer std.testing.allocator.free(address);
    try std.testing.expectEqualStrings(
        "unix:/run/user/1000/dev.rockorager.keywork.compositor",
        address,
    );
    try std.testing.expectError(
        error.InvalidRuntimeDirectory,
        controlAddress(std.testing.allocator, "run/user/1000"),
    );
}

test "reload parameters encode as an empty object" {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try varlink.encode(
        std.testing.allocator,
        &output,
        .{ .method = control.reload_configuration_method, .parameters = Empty{} },
        1024,
    );
    try std.testing.expectEqualStrings(
        "{\"method\":\"dev.rockorager.keywork.compositor.ReloadConfiguration\",\"parameters\":{}}\x00",
        output.items,
    );
}

test "log level parameters encode as a typed value" {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try varlink.encode(
        std.testing.allocator,
        &output,
        .{
            .method = control.set_log_level_method,
            .parameters = .{ .level = control.LogLevel.warning },
        },
        1024,
    );
    try std.testing.expectEqualStrings(
        "{\"method\":\"dev.rockorager.keywork.compositor.SetLogLevel\",\"parameters\":{\"level\":\"warning\"}}\x00",
        output.items,
    );
}

test "unfocused border parameters encode as typed values" {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try varlink.encode(
        std.testing.allocator,
        &output,
        .{
            .method = control.set_unfocused_border_method,
            .parameters = .{ .border = control.Border{
                .width = 2,
                .color = .{ .red = 58, .green = 58, .blue = 64, .alpha = 255 },
            } },
        },
        1024,
    );
    try std.testing.expectEqualStrings(
        "{\"method\":\"dev.rockorager.keywork.compositor.SetUnfocusedBorder\",\"parameters\":{\"border\":{\"width\":2,\"color\":{\"red\":58,\"green\":58,\"blue\":64,\"alpha\":255}}}}\x00",
        output.items,
    );
}

test "configuration reload errors expose their message" {
    var parsed = try std.json.parseFromSlice(varlink.Reply, std.testing.allocator,
        \\{"error":"dev.rockorager.keywork.compositor.ConfigurationReloadFailed","parameters":{"message":"/tmp/keywork.conf:4: invalid general setting"}}
    , .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "/tmp/keywork.conf:4: invalid general setting",
        remoteErrorMessage(parsed.value.@"error".?, parsed.value.parameters).?,
    );
    try std.testing.expect(remoteErrorMessage("org.varlink.service.MethodNotFound", parsed.value.parameters) == null);
}

test "performance statistics decode and render human-readable output" {
    var reply = try std.json.parseFromSlice(varlink.Reply, std.testing.allocator,
        \\{"parameters":{"outputs":[{"name":"eDP-1","width":2880,"height":1800,"refresh_millihertz":120000,"last_frame":{"path":"composited","working_format":"rgba16f_linear","scanout_format":"xrgb8888","output_transform":"normal","damage_rectangles":2,"damaged_pixels":800000},"frames_requested":10,"frames_started":9,"frames_presented":8,"frames_discarded":1,"acquire_retries":2,"composited_frames":7,"direct_scanout_candidates":3,"direct_scanout_frames":1,"direct_scanout_rejections":{"no_fullscreen_surface":4,"non_opaque_surface":0,"surface_transform":0,"non_dmabuf":0,"y_inverted":0,"missing_buffer_identity":0,"color_conversion":1,"unsupported_backend":0,"output_unavailable":0,"output_busy":0,"device_inactive":0,"unsupported_format_or_modifier":0,"unsupported_layout":0,"framebuffer_import_failed":0,"page_flip_failed":2},"cpu_uploads":4,"dmabuf_imports":6,"frames_over_budget":2,"gpu_execution":{"samples":7,"p50_microseconds":2100,"p95_microseconds":4400,"p99_microseconds":6100,"maximum_microseconds":7200},"gpu_composition":{"samples":7,"p50_microseconds":1500,"p95_microseconds":3300,"p99_microseconds":4700,"maximum_microseconds":5400},"gpu_preparation":{"samples":7,"p50_microseconds":100,"p95_microseconds":200,"p99_microseconds":300,"maximum_microseconds":400},"gpu_solid_composition":{"samples":7,"p50_microseconds":110,"p95_microseconds":210,"p99_microseconds":310,"maximum_microseconds":410},"gpu_image_composition":{"samples":7,"p50_microseconds":120,"p95_microseconds":220,"p99_microseconds":320,"maximum_microseconds":420},"gpu_shadow":{"samples":7,"p50_microseconds":130,"p95_microseconds":230,"p99_microseconds":330,"maximum_microseconds":430},"gpu_blur_downsample":{"samples":7,"p50_microseconds":140,"p95_microseconds":240,"p99_microseconds":340,"maximum_microseconds":440},"gpu_blur_upsample":{"samples":7,"p50_microseconds":150,"p95_microseconds":250,"p99_microseconds":350,"maximum_microseconds":450},"gpu_blur_composite":{"samples":7,"p50_microseconds":160,"p95_microseconds":260,"p99_microseconds":360,"maximum_microseconds":460},"gpu_composition_overhead":{"samples":7,"p50_microseconds":170,"p95_microseconds":270,"p99_microseconds":370,"maximum_microseconds":470},"gpu_output_encode":{"samples":7,"p50_microseconds":400,"p95_microseconds":700,"p99_microseconds":900,"maximum_microseconds":1100},"gpu_frame_finish":{"samples":7,"p50_microseconds":180,"p95_microseconds":280,"p99_microseconds":380,"maximum_microseconds":480},"request_to_presentation":{"samples":8,"p50_microseconds":8200,"p95_microseconds":9100,"p99_microseconds":16700,"maximum_microseconds":25000},"request_to_render":{"samples":8,"p50_microseconds":1000,"p95_microseconds":1200,"p99_microseconds":1400,"maximum_microseconds":1600},"render_to_commit":{"samples":8,"p50_microseconds":1100,"p95_microseconds":2800,"p99_microseconds":5600,"maximum_microseconds":7000},"commit_to_presentation":{"samples":8,"p50_microseconds":6800,"p95_microseconds":8000,"p99_microseconds":14900,"maximum_microseconds":18000}}]}}
    , .{});
    defer reply.deinit();
    const parsed = try parseStatisticsParameters(std.testing.allocator, reply.value.parameters);
    defer parsed.deinit();
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    try writeStatistics(&writer.writer, parsed.value.outputs);
    try std.testing.expectEqualStrings(
        \\eDP-1 2880x1800 (120.000 Hz)
        \\  last frame: composited, working RGBA16F linear, scanout XRGB8888, transform normal
        \\  damage: 2 rectangles, 800000 pixels
        \\  frames: requested 10, started 9, presented 8, discarded 1
        \\  paths: composited 7, direct scanout 1/3 candidates, overlay scanout 0/0 candidates
        \\  direct scanout rejections:
        \\    no fullscreen surface: 4
        \\    color conversion: 1
        \\    page flip failed: 2
        \\  overlay scanout rejections: none
        \\  buffer operations: CPU uploads 4, DMA-BUF imports 6
        \\  acquire retries: 2, frames over budget: 2
        \\  GPU total: p50 2100us, p95 4400us, p99 6100us, max 7200us (7 samples)
        \\  GPU composition/effects: p50 1500us, p95 3300us, p99 4700us, max 5400us (7 samples)
        \\  GPU preparation/uploads: p50 100us, p95 200us, p99 300us, max 400us (7 samples)
        \\  GPU solid composition: p50 110us, p95 210us, p99 310us, max 410us (7 samples)
        \\  GPU image composition: p50 120us, p95 220us, p99 320us, max 420us (7 samples)
        \\  GPU shadows: p50 130us, p95 230us, p99 330us, max 430us (7 samples)
        \\  GPU blur downsample: p50 140us, p95 240us, p99 340us, max 440us (7 samples)
        \\  GPU blur upsample: p50 150us, p95 250us, p99 350us, max 450us (7 samples)
        \\  GPU blur composite: p50 160us, p95 260us, p99 360us, max 460us (7 samples)
        \\  GPU composition overhead: p50 170us, p95 270us, p99 370us, max 470us (7 samples)
        \\  GPU output encode: p50 400us, p95 700us, p99 900us, max 1100us (7 samples)
        \\  GPU frame finish: p50 180us, p95 280us, p99 380us, max 480us (7 samples)
        \\  request -> presentation: p50 8200us, p95 9100us, p99 16700us, max 25000us (8 samples)
        \\  request -> render: p50 1000us, p95 1200us, p99 1400us, max 1600us (8 samples)
        \\  render -> commit: p50 1100us, p95 2800us, p99 5600us, max 7000us (8 samples)
        \\  commit -> presentation: p50 6800us, p95 8000us, p99 14900us, max 18000us (8 samples)
        \\  render fences signaled before commit: 0/0
        \\  render -> GPU completion: p50 0us, p95 0us, p99 0us, max 0us (0 samples)
        \\  GPU completion -> presentation: p50 0us, p95 0us, p99 0us, max 0us (0 samples)
        \\
    , writer.written());
}

test "window snapshots decode and render human-readable output" {
    var reply = try std.json.parseFromSlice(varlink.Reply, std.testing.allocator,
        \\{"parameters":{"windows":[{"id":"00000001:00000003","protocol":"xdg_shell","title":"Terminal","app_id":"org.example.Terminal","pid":8124,"rect":{"x":16,"y":16,"width":1248,"height":688},"output":"HEADLESS-1","workspace":1,"focused":true,"visible":true,"floating":false,"fullscreen":false,"maximized":false,"minimized":false},{"id":"00000001:00000004","protocol":"xwayland","app_id":"firefox","output":"HEADLESS-1","workspace":2,"focused":false,"visible":false,"floating":true,"fullscreen":false,"maximized":false,"minimized":true}]}}
    , .{});
    defer reply.deinit();
    const parsed = try parseWindowParameters(std.testing.allocator, reply.value.parameters);
    defer parsed.deinit();
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    try writeWindows(&writer.writer, parsed.value.windows);
    try std.testing.expectEqualStrings(
        \\* 00000001:00000003 org.example.Terminal "Terminal"
        \\  xdg-shell, HEADLESS-1 workspace 1, 16,16 1248x688, visible, tiled
        \\  00000001:00000004 firefox
        \\  xwayland, HEADLESS-1 workspace 2, unplaced, hidden, floating, minimized
        \\
    , writer.written());
}

test "window snapshots escape terminal control sequences" {
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    const windows = [_]control.Window{.{
        .id = "00000001:00000003",
        .protocol = .xdg_shell,
        .title = "bad\n\x1b]52;clipboard\x07\"title",
        .app_id = "org.example\\bad\tapp",
        .output = "HEADLESS-1",
        .workspace = 1,
        .focused = true,
        .visible = true,
        .floating = false,
        .fullscreen = false,
        .maximized = false,
        .minimized = false,
    }};

    try writeWindows(&writer.writer, &windows);
    try std.testing.expectEqualStrings(
        "* 00000001:00000003 org.example\\\\bad\\tapp \"bad\\n\\x1b]52;clipboard\\x07\\\"title\"\n" ++
            "  xdg-shell, HEADLESS-1 workspace 1, unplaced, visible, tiled\n",
        writer.written(),
    );
}

test "window snapshots render machine-readable JSON" {
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    const windows = [_]control.Window{.{
        .id = "00000001:00000003",
        .protocol = .xdg_shell,
        .title = "Terminal",
        .app_id = "org.example.Terminal",
        .pid = 8124,
        .rect = .{ .x = 16, .y = 16, .width = 1248, .height = 688 },
        .output = "HEADLESS-1",
        .workspace = 1,
        .focused = true,
        .visible = true,
        .floating = false,
        .fullscreen = false,
        .maximized = false,
        .minimized = false,
    }};

    try writeWindowsJson(&writer.writer, &windows);
    try std.testing.expectEqualStrings(
        "{\"windows\":[{\"id\":\"00000001:00000003\",\"protocol\":\"xdg_shell\",\"title\":\"Terminal\",\"app_id\":\"org.example.Terminal\",\"pid\":8124,\"rect\":{\"x\":16,\"y\":16,\"width\":1248,\"height\":688},\"output\":\"HEADLESS-1\",\"workspace\":1,\"focused\":true,\"visible\":true,\"floating\":false,\"fullscreen\":false,\"maximized\":false,\"minimized\":false}]}\n",
        writer.written(),
    );
}

test "overlay scanout rejections render nonzero reasons" {
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();

    try writeOverlayScanoutRejections(&writer.writer, .{
        .no_topmost_surface = 2,
        .atomic_test_failed = 1,
    });

    try std.testing.expectEqualStrings(
        \\  overlay scanout rejections:
        \\    no topmost surface: 2
        \\    atomic test failed: 1
        \\
    , writer.written());
}

test "performance statistics render machine-readable JSON" {
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();

    try writeStatisticsJson(&writer.writer, &.{});
    try std.testing.expectEqualStrings("{\"outputs\":[]}\n", writer.written());
}
