//! Shared application runner for libkeywork hosts.

const std = @import("std");
const keywork = @import("core.zig");

const desktop_settings = @import("desktop_settings.zig");
const event_loop = @import("event_loop.zig");
const wayland_shm = @import("wayland_shm.zig");
const wayland_vulkan = @import("wayland_vulkan.zig");

const log = std.log.scoped(.keywork_runner);

pub const BackendKind = enum {
    log,
    wayland_shm,
    vulkan,
};

pub const Options = struct {
    title: [:0]const u8 = "Keywork",
    width: f32 = 640,
    height: f32 = 480,
    backend: BackendKind = .log,
    log_writer: ?*std.Io.Writer = null,
    timer_interval_ms: ?u64 = 1000,
    file_watch_path: ?[]const u8 = null,
};

pub fn run(allocator: std.mem.Allocator, app: keywork.AppHost, options: Options) !void {
    const constraints: keywork.Constraints = .{ .max_width = options.width, .max_height = options.height };
    return switch (options.backend) {
        .log => runLog(allocator, app, constraints, options),
        .wayland_shm => runWayland(allocator, app, constraints, options, wayland_shm.Backend),
        .vulkan => runWayland(allocator, app, constraints, options, wayland_vulkan.Backend),
    };
}

fn runLog(
    allocator: std.mem.Allocator,
    app: keywork.AppHost,
    constraints: keywork.Constraints,
    options: Options,
) !void {
    if (options.log_writer) |writer| {
        var log_backend: keywork.LogBackend = .{ .writer = writer };
        return runHeadlessRuntime(allocator, app, constraints, log_backend.backend());
    }

    var discard_backend: DiscardBackend = .{};
    return runHeadlessRuntime(allocator, app, constraints, discard_backend.backend());
}

fn runHeadlessRuntime(
    allocator: std.mem.Allocator,
    app: keywork.AppHost,
    constraints: keywork.Constraints,
    backend: keywork.RenderBackend,
) !void {
    var runtime = try @import("runtime.zig").Runtime.init(
        allocator,
        backend,
        constraints,
        app,
        .no_preference,
    );
    defer runtime.deinit();
    try runtime.repaint();
}

fn runWayland(
    allocator: std.mem.Allocator,
    app: keywork.AppHost,
    constraints: keywork.Constraints,
    options: Options,
    comptime Backend: type,
) !void {
    var backend = try Backend.create(allocator, .{
        .title = options.title,
        .width = try positiveU31(constraints.max_width),
        .height = try positiveU31(constraints.max_height),
    });
    defer backend.destroy();

    var settings_client: ?desktop_settings.Client = desktop_settings.Client.init() catch |err| blk: {
        log.warn("desktop settings unavailable: {}", .{err});
        break :blk null;
    };
    defer if (settings_client) |*settings| settings.deinit();
    const initial_color_scheme: desktop_settings.ColorScheme = if (settings_client) |settings| settings.color_scheme else .no_preference;

    var runtime = try @import("runtime.zig").Runtime.init(
        allocator,
        backend.renderBackend(),
        constraints,
        app,
        initial_color_scheme,
    );
    defer runtime.deinit();

    backend.setClickHandler(&runtime, @import("runtime.zig").Runtime.waylandClick);
    backend.setRepaintHandler(&runtime, @import("runtime.zig").Runtime.waylandConfigure);
    backend.setFrameHandler(&runtime, @import("runtime.zig").Runtime.waylandFrameDone);
    backend.setKeyHandler(&runtime, @import("runtime.zig").Runtime.waylandKeyInput);
    if (settings_client) |*settings| {
        try settings.installSignalFilter();
        settings.setChangeHandler(&runtime, @import("runtime.zig").Runtime.desktopSettingsChanged);
    }
    try runtime.repaint();

    var loop = try event_loop.EventLoop.init(allocator);
    defer loop.deinit();
    try loop.setWayland(.{
        .fd = backend.eventLoopFd(),
        .ctx = backend,
        .prepare = Backend.eventLoopPrepare,
        .finish = Backend.eventLoopFinish,
    });
    try backend.installKeyRepeat(&loop);
    defer backend.uninstallKeyRepeat();
    if (settings_client) |*settings| try loop.addFd(.{
        .fd = settings.eventLoopFd(),
        .events = std.os.linux.EPOLL.IN | std.os.linux.EPOLL.HUP,
        .ctx = settings,
        .callback = desktop_settings.Client.eventLoopCallback,
    });
    if (options.timer_interval_ms) |interval_ms| {
        try loop.addRepeatingTimer(interval_ms, &runtime, @import("runtime.zig").Runtime.timerTick);
    }
    if (options.file_watch_path) |path| {
        loop.addFileWatch(path, &runtime, @import("runtime.zig").Runtime.fileChanged) catch |err| {
            if (err != error.FileWatchNotFound) log.warn("{s} watch not installed: {}", .{ path, err });
        };
    }
    try loop.run();
}

fn positiveU31(value: f32) !u31 {
    if (!std.math.isFinite(value) or value <= 0) return error.InvalidFrameSize;
    const rounded = @ceil(value);
    if (rounded > @as(f32, @floatFromInt(std.math.maxInt(u31)))) return error.InvalidFrameSize;
    return @intFromFloat(rounded);
}

const DiscardBackend = struct {
    fn backend(self: *DiscardBackend) keywork.RenderBackend {
        return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText } };
    }

    fn present(_: *anyopaque, _: keywork.RenderBackend.Frame) !bool {
        return false;
    }

    fn measureText(_: *anyopaque, value: []const u8) !keywork.Size {
        const measurer: keywork.TextMeasurer = .fixed;
        return try measurer.measureText(value);
    }
};
