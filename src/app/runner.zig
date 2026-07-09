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

pub const Options = struct {
    title: [:0]const u8 = "Keywork",
    app_id: [:0]const u8 = "dev.keywork.Keywork",
    width: f32 = 640,
    height: f32 = 480,
    backend: app_options.BackendKind = .log,
    layer_shell: ?wayland_options.LayerShellOptions = null,
    log_writer: *std.Io.Writer,
    runtime_context: ?*anyopaque = null,
    bind_runtime: ?*const fn (ctx: *anyopaque, runtime: *runtime_mod.Runtime) void = null,
    unbind_runtime: ?*const fn (ctx: *anyopaque) void = null,
    bind_event_loop: ?*const fn (ctx: *anyopaque, loop: *event_loop.EventLoop) anyerror!void = null,
    unbind_event_loop: ?*const fn (ctx: *anyopaque) void = null,
    should_run_headless: ?*const fn (ctx: *anyopaque) bool = null,
};

pub fn run(allocator: std.mem.Allocator, loop: *event_loop.EventLoop, app: keywork.AppHost, options: Options) !void {
    const initial_width = if (options.layer_shell != null and options.width <= 0) 640 else options.width;
    const constraints: keywork.Constraints = .{ .max_width = initial_width, .max_height = options.height };
    if (options.backend == .wayland_shm and options.layer_shell != null and options.layer_shell.?.output == .all) {
        return runWaylandAllOutputs(allocator, loop, app, constraints, options);
    }
    return switch (options.backend) {
        .log => runLog(allocator, loop, app, constraints, options),
        .wayland_shm => runWayland(allocator, loop, app, constraints, options, wayland_shm.Backend),
        .vulkan => runWayland(allocator, loop, app, constraints, options, wayland_vulkan.Backend),
    };
}

fn runLog(
    allocator: std.mem.Allocator,
    loop: *event_loop.EventLoop,
    app: keywork.AppHost,
    constraints: keywork.Constraints,
    options: Options,
) !void {
    var log_backend: log_backend_mod.LogBackend = .{ .writer = options.log_writer };
    return runHeadlessRuntime(allocator, loop, app, constraints, log_backend.backend(), options);
}

fn runHeadlessRuntime(
    allocator: std.mem.Allocator,
    loop: *event_loop.EventLoop,
    app: keywork.AppHost,
    constraints: keywork.Constraints,
    backend: keywork.RenderBackend,
    options: Options,
) !void {
    var runtime = try runtime_mod.Runtime.init(
        allocator,
        backend,
        constraints,
        app,
        .no_preference,
    );
    defer runtime.deinit();
    if (options.bind_runtime) |bind| bind(options.runtime_context.?, &runtime);
    defer if (options.unbind_runtime) |unbind| unbind(options.runtime_context.?);
    runtime.setDeferredRepaint(true);
    if (options.bind_event_loop) |bind| try bind(options.runtime_context.?, loop);
    defer if (options.unbind_event_loop) |unbind| unbind(options.runtime_context.?);
    try runtime.repaint();
    if (options.should_run_headless) |should_run| {
        if (should_run(options.runtime_context.?)) {
            var headless_loop: HeadlessLoop = .{ .runtime = &runtime, .options = &options };
            loop.setEndTurnHook(&headless_loop, HeadlessLoop.endTurn);
            defer loop.clearEndTurnHook();
            try loop.run();
        }
    }
}

const HeadlessLoop = struct {
    runtime: *runtime_mod.Runtime,
    options: *const Options,

    fn endTurn(ctx: *anyopaque, loop: *event_loop.EventLoop) !void {
        const self: *HeadlessLoop = @ptrCast(@alignCast(ctx));
        try self.runtime.flushPendingRepaint();
        const should_run = self.options.should_run_headless orelse return;
        if (!should_run(self.options.runtime_context.?)) loop.quit();
    }
};

fn runWayland(
    allocator: std.mem.Allocator,
    loop: *event_loop.EventLoop,
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
    defer runtime.deinit();
    if (options.bind_runtime) |bind| bind(options.runtime_context.?, &runtime);
    defer if (options.unbind_runtime) |unbind| unbind(options.runtime_context.?);
    if (options.layer_shell != null) runtime.setFrameBackground(keywork.colors.transparent);
    runtime.setDeferredRepaint(true);
    if (options.bind_event_loop) |bind| try bind(options.runtime_context.?, loop);
    defer if (options.unbind_event_loop) |unbind| unbind(options.runtime_context.?);

    var queue: QueuedPlatformEvents = .{ .allocator = allocator, .runtime = &runtime };
    defer queue.deinit();
    // Layer-shell surfaces never receive xdg_toplevel suspension, so only
    // regular toplevels pause presentation while hidden.
    if (options.layer_shell == null) {
        queue.suspended_query = .{ .ctx = backend, .func = Backend.suspendedOpaque };
    }
    backend.setPointerButtonHandler(&queue, QueuedPlatformEvents.pointerButton);
    backend.setPointerMoveHandler(&queue, QueuedPlatformEvents.pointerMove);
    backend.setCursorShapeHandler(&runtime, runtime_mod.Runtime.waylandCursorShape);
    backend.setRepaintHandler(&queue, QueuedPlatformEvents.configure);
    backend.setFrameHandler(&queue, QueuedPlatformEvents.frameDone);
    backend.setKeyHandler(&queue, QueuedPlatformEvents.keyInput);
    backend.setScrollHandler(&queue, QueuedPlatformEvents.scroll);
    if (settings_client) |*settings| {
        try settings.installSignalFilter();
        settings.setChangeHandler(&runtime, desktopSettingsChanged);
    }
    try runtime.repaint();

    try loop.setWayland(.{
        .fd = backend.eventLoopFd(),
        .ctx = backend,
        .prepare = Backend.eventLoopPrepare,
        .finish = Backend.eventLoopFinish,
    });
    defer loop.clearWayland();
    try backend.installEventTimers(loop);
    defer backend.uninstallEventTimers();
    var settings_source: ?event_loop.EventLoop.SourceHandle = null;
    defer if (settings_source) |handle| loop.removeSource(handle);
    if (settings_client) |*settings| settings_source = try loop.addFd(.{
        .fd = settings.eventLoopFd(),
        .events = std.os.linux.EPOLL.IN | std.os.linux.EPOLL.HUP,
        .ctx = settings,
        .callback = desktop_settings.Client.eventLoopCallback,
    });
    loop.setAfterPlatformHook(&queue, QueuedPlatformEvents.afterPlatformHook);
    defer loop.clearAfterPlatformHook();
    loop.setEndTurnHook(&queue, QueuedPlatformEvents.endTurnHook);
    defer loop.clearEndTurnHook();
    try loop.run();
}

const QueuedPlatformEvents = struct {
    allocator: std.mem.Allocator,
    runtime: *runtime_mod.Runtime,
    multi_output: ?*MultiOutputContext = null,
    suspended_query: ?SuspendedQuery = null,
    events: std.ArrayList(Event) = .empty,

    const SuspendedQuery = struct {
        ctx: *anyopaque,
        func: *const fn (ctx: *anyopaque) bool,
    };

    const Event = union(enum) {
        pointer_button: struct { point: keywork.Point, state: keywork.PointerButtonState },
        pointer_move: ?keywork.Point,
        scroll: struct { point: keywork.Point, dx: f32, dy: f32 },
        key: keywork.KeyInput,
        configure: keywork.Size,
        frame_done,
    };

    fn deinit(self: *QueuedPlatformEvents) void {
        self.clear();
        self.events.deinit(self.allocator);
    }

    fn clear(self: *QueuedPlatformEvents) void {
        for (self.events.items) |event| switch (event) {
            .key => |input| switch (input) {
                .text => |text| self.allocator.free(text),
                else => {},
            },
            else => {},
        };
        self.events.clearRetainingCapacity();
    }

    fn append(self: *QueuedPlatformEvents, event: Event) void {
        self.events.append(self.allocator, event) catch |err| {
            switch (event) {
                .key => |input| switch (input) {
                    .text => |text| self.allocator.free(text),
                    else => {},
                },
                else => {},
            }
            log.err("queue platform event failed: {}", .{err});
        };
    }

    fn pointerButton(ctx: *anyopaque, point: keywork.Point, state: keywork.PointerButtonState) void {
        const self: *QueuedPlatformEvents = @ptrCast(@alignCast(ctx));
        self.append(.{ .pointer_button = .{ .point = point, .state = state } });
    }

    fn pointerMove(ctx: *anyopaque, point: ?keywork.Point) void {
        const self: *QueuedPlatformEvents = @ptrCast(@alignCast(ctx));
        self.append(.{ .pointer_move = point });
    }

    fn scroll(ctx: *anyopaque, point: keywork.Point, dx: f32, dy: f32) void {
        const self: *QueuedPlatformEvents = @ptrCast(@alignCast(ctx));
        self.append(.{ .scroll = .{ .point = point, .dx = dx, .dy = dy } });
    }

    fn keyInput(ctx: *anyopaque, input: keywork.KeyInput) void {
        const self: *QueuedPlatformEvents = @ptrCast(@alignCast(ctx));
        const copied = switch (input) {
            .text => |text| keywork.KeyInput{ .text = self.allocator.dupe(u8, text) catch |err| {
                log.err("copy key text failed: {}", .{err});
                return;
            } },
            else => input,
        };
        self.append(.{ .key = copied });
    }

    fn configure(ctx: *anyopaque, size: keywork.Size) void {
        const self: *QueuedPlatformEvents = @ptrCast(@alignCast(ctx));
        self.append(.{ .configure = size });
    }

    fn frameDone(ctx: *anyopaque) void {
        const self: *QueuedPlatformEvents = @ptrCast(@alignCast(ctx));
        self.append(.frame_done);
    }

    fn drain(self: *QueuedPlatformEvents) !void {
        if (self.events.items.len == 0) return;
        defer self.clear();
        for (self.events.items) |event| switch (event) {
            .pointer_button => |value| try self.runtime.pointerButton(value.point, value.state),
            .pointer_move => |point| try self.runtime.pointerMove(point),
            .scroll => |value| try self.runtime.scrollBy(value.point, value.dx, value.dy),
            .key => |input| try self.runtime.keyInput(input),
            .configure => |size| if (self.multi_output) |multi| multi.configure(size) else runtime_mod.Runtime.waylandConfigure(self.runtime, size),
            .frame_done => if (self.multi_output) |multi| MultiOutputContext.frameHandler(multi) else runtime_mod.Runtime.waylandFrameDone(self.runtime),
        };
    }

    fn afterPlatformHook(ctx: *anyopaque, _: *event_loop.EventLoop) !void {
        const self: *QueuedPlatformEvents = @ptrCast(@alignCast(ctx));
        try self.drain();
    }

    fn endTurnHook(ctx: *anyopaque, _: *event_loop.EventLoop) !void {
        const self: *QueuedPlatformEvents = @ptrCast(@alignCast(ctx));
        // Input repeat and kinetic-scroll timers are ordinary event-loop
        // sources, so they can enqueue semantic events after the platform
        // phase. Drain those before presenting the turn's coalesced frame.
        try self.drain();
        // While the compositor reports the toplevel suspended (minimized,
        // hidden workspace, fully occluded), skip presentation entirely:
        // invalidations keep coalescing into repaint_pending, and the
        // configure that clears the state wakes the loop and flushes them.
        if (self.suspended_query) |query| {
            if (query.func(query.ctx)) return;
        }
        if (self.multi_output) |multi| {
            try multi.flush();
        } else {
            try self.runtime.flushPendingRepaint();
        }
    }
};

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
        self.runtime.repaint_pending = true;
    }

    fn configure(self: *MultiOutputContext, _: keywork.Size) void {
        self.runtime.rebuild_pending = true;
        self.runtime.repaint_pending = true;
    }

    fn frameHandler(ctx: *anyopaque) void {
        const self: *MultiOutputContext = @ptrCast(@alignCast(ctx));
        runtime_mod.Runtime.waylandFrameDone(self.runtime);
    }

    fn flush(self: *MultiOutputContext) !void {
        if (!self.runtime.repaint_pending or self.runtime.frame_pending or self.runtime.rendering) return;
        try self.repaintAll();
        self.runtime.repaint_pending = false;
    }
};

fn runWaylandAllOutputs(
    allocator: std.mem.Allocator,
    loop: *event_loop.EventLoop,
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
    defer runtime.deinit();
    if (options.bind_runtime) |bind| bind(options.runtime_context.?, &runtime);
    defer if (options.unbind_runtime) |unbind| unbind(options.runtime_context.?);
    runtime.setFrameBackground(keywork.colors.transparent);
    runtime.setDeferredRepaint(true);
    if (options.bind_event_loop) |bind| try bind(options.runtime_context.?, loop);
    defer if (options.unbind_event_loop) |unbind| unbind(options.runtime_context.?);

    var multi_context: MultiOutputContext = .{ .runtime = &runtime, .backend = backend, .output_backends = output_backends };
    runtime.setRepaintScheduler(&multi_context, MultiOutputContext.schedule);

    var queue: QueuedPlatformEvents = .{ .allocator = allocator, .runtime = &runtime, .multi_output = &multi_context };
    defer queue.deinit();
    backend.setPointerButtonHandler(&queue, QueuedPlatformEvents.pointerButton);
    backend.setPointerMoveHandler(&queue, QueuedPlatformEvents.pointerMove);
    backend.setCursorShapeHandler(&runtime, runtime_mod.Runtime.waylandCursorShape);
    backend.setRepaintHandler(&queue, QueuedPlatformEvents.configure);
    backend.setFrameHandler(&queue, QueuedPlatformEvents.frameDone);
    backend.setKeyHandler(&queue, QueuedPlatformEvents.keyInput);
    backend.setScrollHandler(&queue, QueuedPlatformEvents.scroll);
    if (settings_client) |*settings| {
        try settings.installSignalFilter();
        settings.setChangeHandler(&runtime, desktopSettingsChanged);
    }
    try multi_context.repaintAll();

    try loop.setWayland(.{
        .fd = backend.eventLoopFd(),
        .ctx = backend,
        .prepare = wayland_shm.Backend.eventLoopPrepare,
        .finish = wayland_shm.Backend.eventLoopFinish,
    });
    defer loop.clearWayland();
    try backend.installEventTimers(loop);
    defer backend.uninstallEventTimers();
    var settings_source: ?event_loop.EventLoop.SourceHandle = null;
    defer if (settings_source) |handle| loop.removeSource(handle);
    if (settings_client) |*settings| settings_source = try loop.addFd(.{
        .fd = settings.eventLoopFd(),
        .events = std.os.linux.EPOLL.IN | std.os.linux.EPOLL.HUP,
        .ctx = settings,
        .callback = desktop_settings.Client.eventLoopCallback,
    });
    loop.setAfterPlatformHook(&queue, QueuedPlatformEvents.afterPlatformHook);
    defer loop.clearAfterPlatformHook();
    loop.setEndTurnHook(&queue, QueuedPlatformEvents.endTurnHook);
    defer loop.clearEndTurnHook();
    try loop.run();
}

fn positiveU31(value: f32) !u31 {
    if (!std.math.isFinite(value) or value <= 0) return error.InvalidFrameSize;
    const rounded = @ceil(value);
    if (rounded > @as(f32, @floatFromInt(std.math.maxInt(u31)))) return error.InvalidFrameSize;
    return @intFromFloat(rounded);
}

test "queued key text is copied" {
    var runtime: runtime_mod.Runtime = undefined;
    var queue: QueuedPlatformEvents = .{ .allocator = std.testing.allocator, .runtime = &runtime };
    defer queue.deinit();

    var buffer = [_]u8{ 'a', 'b' };
    QueuedPlatformEvents.keyInput(&queue, .{ .text = buffer[0..] });
    buffer[0] = 'z';

    try std.testing.expectEqual(@as(usize, 1), queue.events.items.len);
    const input = queue.events.items[0].key;
    try std.testing.expectEqualStrings("ab", input.text);
}
