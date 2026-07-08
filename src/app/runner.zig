//! Process and event-loop runner for the Keywork Lua runtime.

const std = @import("std");
const keywork = @import("../ui.zig");

const desktop_settings = @import("../linux/desktop_settings.zig");
const event_loop = @import("../linux/event_loop.zig");
const log_backend_mod = @import("../backend/log.zig");
const app_options = @import("options.zig");
const runtime_mod = @import("../ui/runtime.zig");
const wayland_options = @import("../backend/wayland/options.zig");
const wayland_shm = @import("../backend/wayland/shm.zig");
const wayland_vulkan = @import("../backend/wayland/vulkan.zig");

const log = std.log.scoped(.keywork_runner);

fn uiColorScheme(value: desktop_settings.ColorScheme) runtime_mod.UiColorScheme {
    return switch (value) {
        .no_preference => .no_preference,
        .dark => .dark,
        .light => .light,
    };
}

fn desktopSettingsChanged(ctx: *anyopaque, color_scheme: desktop_settings.ColorScheme) void {
    runtime_mod.Runtime.colorSchemeChanged(ctx, uiColorScheme(color_scheme));
}

fn watchedFileChanged(
    ctx: *anyopaque,
    _: *event_loop.EventLoop,
    path: []const u8,
    mask: u32,
    _: ?[]const u8,
) !void {
    const runtime: *runtime_mod.Runtime = @ptrCast(@alignCast(ctx));
    try runtime.reloadFileChanged(path, mask);
}

pub const EventSourceInstaller = *const fn (
    ctx: ?*anyopaque,
    loop: *event_loop.EventLoop,
    runtime: *runtime_mod.Runtime,
) anyerror!void;

pub const Options = struct {
    title: [:0]const u8 = "Keywork",
    app_id: [:0]const u8 = "dev.keywork.Keywork",
    width: f32 = 640,
    height: f32 = 480,
    backend: app_options.BackendKind = .log,
    layer_shell: ?wayland_options.LayerShellOptions = null,
    log_writer: ?*std.Io.Writer = null,
    file_watch_path: ?[]const u8 = null,
    event_source_context: ?*anyopaque = null,
    install_event_sources: ?EventSourceInstaller = null,
};

pub fn run(allocator: std.mem.Allocator, app: keywork.AppHost, options: Options) !void {
    const initial_width = if (options.layer_shell != null and options.width <= 0) 640 else options.width;
    const constraints: keywork.Constraints = .{ .max_width = initial_width, .max_height = options.height };
    if (options.backend == .wayland_shm and options.layer_shell != null and options.layer_shell.?.output == .all) {
        return runWaylandAllOutputs(allocator, app, constraints, options);
    }
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
        var log_backend: log_backend_mod.LogBackend = .{ .writer = writer };
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
    var runtime = try runtime_mod.Runtime.init(
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
    var initial_constraints = constraints;
    const backend_width = if (options.layer_shell != null and options.width <= 0) 0 else try positiveU31(constraints.max_width);
    var backend = try Backend.create(allocator, .{
        .title = options.title,
        .app_id = options.app_id,
        .width = backend_width,
        .height = try positiveU31(constraints.max_height),
        .layer_shell = options.layer_shell,
    });
    defer backend.destroy();
    const configured_size = try backend.waitForInitialConfigure();
    initial_constraints = .{ .max_width = configured_size.width, .max_height = configured_size.height };

    var settings_client: ?desktop_settings.Client = desktop_settings.Client.init() catch |err| blk: {
        log.warn("desktop settings unavailable: {}", .{err});
        break :blk null;
    };
    defer if (settings_client) |*settings| settings.deinit();
    const initial_color_scheme: runtime_mod.UiColorScheme = if (settings_client) |settings| uiColorScheme(settings.color_scheme) else .no_preference;

    var runtime = try runtime_mod.Runtime.init(
        allocator,
        backend.renderBackend(),
        initial_constraints,
        app,
        initial_color_scheme,
    );
    if (options.layer_shell != null) runtime.frame_background = keywork.colors.transparent;
    errdefer runtime.deinit();

    backend.setPointerButtonHandler(&runtime, runtime_mod.Runtime.waylandPointerButton);
    backend.setPointerMoveHandler(&runtime, runtime_mod.Runtime.waylandPointerMove);
    backend.setCursorShapeHandler(&runtime, runtime_mod.Runtime.waylandCursorShape);
    backend.setRepaintHandler(&runtime, runtime_mod.Runtime.waylandConfigure);
    backend.setFrameHandler(&runtime, runtime_mod.Runtime.waylandFrameDone);
    backend.setKeyHandler(&runtime, runtime_mod.Runtime.waylandKeyInput);
    backend.setScrollHandler(&runtime, runtime_mod.Runtime.waylandScroll);
    if (settings_client) |*settings| {
        try settings.installSignalFilter();
        settings.setChangeHandler(&runtime, desktopSettingsChanged);
    }
    try runtime.repaint();

    var loop = try event_loop.EventLoop.init(allocator);
    defer loop.deinit();
    defer runtime.deinit();
    try loop.setWayland(.{
        .fd = backend.eventLoopFd(),
        .ctx = backend,
        .prepare = Backend.eventLoopPrepare,
        .finish = Backend.eventLoopFinish,
    });
    try backend.installEventTimers(&loop);
    defer backend.uninstallEventTimers();
    if (settings_client) |*settings| try loop.addFd(.{
        .fd = settings.eventLoopFd(),
        .events = std.os.linux.EPOLL.IN | std.os.linux.EPOLL.HUP,
        .ctx = settings,
        .callback = desktop_settings.Client.eventLoopCallback,
    });
    if (options.file_watch_path) |path| {
        _ = loop.addFileWatch(path, &runtime, watchedFileChanged) catch |err| {
            if (err != error.FileWatchNotFound) log.warn("{s} watch not installed: {}", .{ path, err });
        };
    }
    if (options.install_event_sources) |install| {
        try install(options.event_source_context, &loop, &runtime);
    }
    try loop.run();
}

const MultiOutputContext = struct {
    runtime: *runtime_mod.Runtime,
    backend: *wayland_shm.Backend,
    output_backends: []wayland_shm.Backend.OutputRenderBackend,

    fn repaintAll(self: *MultiOutputContext) !void {
        var index = self.output_backends.len;
        while (index > 0) {
            index -= 1;
            self.runtime.backend = self.output_backends[index].backendInterface();
            const size = self.backend.outputSize(index);
            self.runtime.constraints = .{ .max_width = size.width, .max_height = size.height };
            self.runtime.rebuild_pending = true;
            try self.runtime.repaint();
        }
    }

    fn schedule(ctx: *anyopaque) !void {
        const self: *MultiOutputContext = @ptrCast(@alignCast(ctx));
        if (!self.runtime.frame_pending and !self.runtime.rendering) try self.repaintAll();
    }

    fn repaintHandler(ctx: *anyopaque, _: keywork.Size) void {
        const self: *MultiOutputContext = @ptrCast(@alignCast(ctx));
        self.repaintAll() catch |err| log.warn("multi-output repaint failed: {}", .{err});
    }

    fn frameHandler(ctx: *anyopaque) void {
        const self: *MultiOutputContext = @ptrCast(@alignCast(ctx));
        runtime_mod.Runtime.waylandFrameDone(self.runtime);
    }
};

fn runWaylandAllOutputs(
    allocator: std.mem.Allocator,
    app: keywork.AppHost,
    constraints: keywork.Constraints,
    options: Options,
) !void {
    const backend_width = if (options.width <= 0) 0 else try positiveU31(constraints.max_width);
    var backend = try wayland_shm.Backend.create(allocator, .{
        .title = options.title,
        .app_id = options.app_id,
        .width = backend_width,
        .height = try positiveU31(constraints.max_height),
        .layer_shell = options.layer_shell,
    });
    defer backend.destroy();
    _ = try backend.waitForInitialConfigure();

    const output_count = backend.outputCount();
    var output_backends = try allocator.alloc(wayland_shm.Backend.OutputRenderBackend, output_count);
    defer allocator.free(output_backends);
    for (output_backends, 0..) |*output_backend, index| output_backend.* = backend.renderBackendForOutput(index);

    var settings_client: ?desktop_settings.Client = desktop_settings.Client.init() catch |err| blk: {
        log.warn("desktop settings unavailable: {}", .{err});
        break :blk null;
    };
    defer if (settings_client) |*settings| settings.deinit();
    const initial_color_scheme: runtime_mod.UiColorScheme = if (settings_client) |settings| uiColorScheme(settings.color_scheme) else .no_preference;

    const first_size = backend.outputSize(0);
    var runtime = try runtime_mod.Runtime.init(
        allocator,
        output_backends[0].backendInterface(),
        .{ .max_width = first_size.width, .max_height = first_size.height },
        app,
        initial_color_scheme,
    );
    runtime.frame_background = keywork.colors.transparent;
    errdefer runtime.deinit();

    var multi_context: MultiOutputContext = .{ .runtime = &runtime, .backend = backend, .output_backends = output_backends };
    runtime.setRepaintScheduler(&multi_context, MultiOutputContext.schedule);

    backend.setPointerButtonHandler(&runtime, runtime_mod.Runtime.waylandPointerButton);
    backend.setPointerMoveHandler(&runtime, runtime_mod.Runtime.waylandPointerMove);
    backend.setCursorShapeHandler(&runtime, runtime_mod.Runtime.waylandCursorShape);
    backend.setRepaintHandler(&multi_context, MultiOutputContext.repaintHandler);
    backend.setFrameHandler(&multi_context, MultiOutputContext.frameHandler);
    backend.setKeyHandler(&runtime, runtime_mod.Runtime.waylandKeyInput);
    backend.setScrollHandler(&runtime, runtime_mod.Runtime.waylandScroll);
    if (settings_client) |*settings| {
        try settings.installSignalFilter();
        settings.setChangeHandler(&runtime, desktopSettingsChanged);
    }
    try multi_context.repaintAll();

    var loop = try event_loop.EventLoop.init(allocator);
    defer loop.deinit();
    defer runtime.deinit();
    try loop.setWayland(.{
        .fd = backend.eventLoopFd(),
        .ctx = backend,
        .prepare = wayland_shm.Backend.eventLoopPrepare,
        .finish = wayland_shm.Backend.eventLoopFinish,
    });
    try backend.installEventTimers(&loop);
    defer backend.uninstallEventTimers();
    if (settings_client) |*settings| try loop.addFd(.{
        .fd = settings.eventLoopFd(),
        .events = std.os.linux.EPOLL.IN | std.os.linux.EPOLL.HUP,
        .ctx = settings,
        .callback = desktop_settings.Client.eventLoopCallback,
    });
    if (options.file_watch_path) |path| {
        _ = loop.addFileWatch(path, &runtime, watchedFileChanged) catch |err| {
            if (err != error.FileWatchNotFound) log.warn("{s} watch not installed: {}", .{ path, err });
        };
    }
    if (options.install_event_sources) |install| {
        try install(options.event_source_context, &loop, &runtime);
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
        return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
    }

    fn present(_: *anyopaque, _: keywork.RenderBackend.Frame) !bool {
        return false;
    }

    fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !keywork.Size {
        const measurer: keywork.TextMeasurer = .fixed;
        return try measurer.measureText(value, style);
    }

    fn scale(_: *anyopaque) f32 {
        return 1;
    }
};
