//! Process and event-loop runner for the Keywork Lua runtime.

const std = @import("std");
const keywork = @import("../ui.zig");

const desktop_settings = @import("../linux/desktop_settings.zig");
const event_loop = @import("../linux/event_loop.zig");
const log_backend_mod = @import("../backend/log.zig");
const app_options = @import("options.zig");
const app_windows = @import("windows.zig");
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
    /// Declarative window-set host; when present the Wayland backends run
    /// one runtime per declared window instead of a single main window.
    windows_host: ?app_windows.WindowsHost = null,
    bind_runtime: ?*const fn (ctx: *anyopaque, runtime: *runtime_mod.Runtime) void = null,
    bind_invalidator: ?*const fn (ctx: *anyopaque, invalidator: runtime_mod.Invalidator) void = null,
    unbind_runtime: ?*const fn (ctx: *anyopaque) void = null,
    bind_event_loop: ?*const fn (ctx: *anyopaque, loop: *event_loop.EventLoop) anyerror!void = null,
    unbind_event_loop: ?*const fn (ctx: *anyopaque) void = null,
    should_run_headless: ?*const fn (ctx: *anyopaque) bool = null,
};

pub fn run(allocator: std.mem.Allocator, loop: *event_loop.EventLoop, app: keywork.AppHost, options: Options) !void {
    const initial_width = if (options.layer_shell != null and options.width <= 0) 640 else options.width;
    const constraints: keywork.Constraints = .{ .max_width = initial_width, .max_height = options.height };
    return switch (options.backend) {
        .log => runLog(allocator, loop, app, constraints, options),
        .wayland_shm => if (options.windows_host) |windows_host|
            runWaylandWindowed(allocator, loop, windows_host, options, wayland_shm.Backend)
        else
            runWayland(allocator, loop, app, constraints, options, wayland_shm.Backend),
        .vulkan => if (options.windows_host) |windows_host|
            runWaylandWindowed(allocator, loop, windows_host, options, wayland_vulkan.Backend)
        else
            runWayland(allocator, loop, app, constraints, options, wayland_vulkan.Backend),
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
    // Send the portal color-scheme query before window setup so the dbus
    // round trip completes while the compositor configures the surface.
    var settings_client: ?desktop_settings.Client = desktop_settings.Client.init() catch |err| blk: {
        log.warn("desktop settings unavailable: {}", .{err});
        break :blk null;
    };
    defer if (settings_client) |*settings| settings.deinit();

    var initial_constraints = constraints;
    const backend_width = if (options.layer_shell != null and options.width <= 0) 0 else try positiveU31(constraints.max_width);
    var backend = try Backend.create(allocator);
    defer backend.destroy();
    const win = try backend.createWindow(.{
        .title = options.title,
        .app_id = options.app_id,
        .width = backend_width,
        .height = try positiveU31(constraints.max_height),
        .layer_shell = options.layer_shell,
    });
    try backend.waitForAllConfigured();
    const configured_size = win.currentSize();
    initial_constraints = .{ .max_width = configured_size.width, .max_height = configured_size.height };

    if (settings_client) |*settings| settings.finishColorSchemeRead();
    const initial_color_scheme: runtime_mod.UiColorScheme = if (settings_client) |settings| uiColorScheme(settings.color_scheme) else .no_preference;

    var runtime = try runtime_mod.Runtime.init(
        allocator,
        win.renderBackend(),
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
        queue.suspended_query = .{ .ctx = win, .func = Backend.Window.suspendedOpaque };
    }
    const popups_supported = @hasDecl(Backend, "createPopup");
    var popup_manager: if (popups_supported) PopupManager(Backend) else void = if (popups_supported) .{
        .allocator = allocator,
        .backend = backend,
        .parent = win,
        .runtime = &runtime,
    } else {};
    defer if (popups_supported) popup_manager.deinit();
    if (popups_supported) queue.popup_manager = popup_manager.hooks();
    win.setPointerButtonHandler(&queue, QueuedPlatformEvents.pointerButton);
    win.setPointerMoveHandler(&queue, QueuedPlatformEvents.pointerMove);
    win.setCursorShapeHandler(&runtime, runtime_mod.Runtime.waylandCursorShape);
    win.setRepaintHandler(&queue, QueuedPlatformEvents.configure);
    win.setFrameHandler(&queue, QueuedPlatformEvents.frameDone);
    win.setKeyHandler(&queue, QueuedPlatformEvents.keyInput);
    win.setScrollHandler(&queue, QueuedPlatformEvents.scroll);
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

/// Type-erased handle to a backend-specific popup manager, so the shared
/// event queue can drive popups without knowing the backend type.
const PopupHooks = struct {
    ctx: *anyopaque,
    drain_all: *const fn (ctx: *anyopaque) anyerror!void,
    reconcile_and_flush: *const fn (ctx: *anyopaque, content_dirty: bool) anyerror!void,
    parent_pointer_down: *const fn (ctx: *anyopaque, point: keywork.Point) anyerror!bool,
    escape_pressed: *const fn (ctx: *anyopaque) bool,
};

const QueuedPlatformEvents = struct {
    allocator: std.mem.Allocator,
    runtime: *runtime_mod.Runtime,
    popup_manager: ?PopupHooks = null,
    popup_surface: bool = false,
    suspended_query: ?SuspendedQuery = null,
    events: std.ArrayList(Event) = .empty,

    const SuspendedQuery = struct {
        ctx: *anyopaque,
        func: *const fn (ctx: *anyopaque) bool,
    };

    const Event = union(enum) {
        pointer_button: keywork.PointerButtonEvent,
        pointer_move: ?keywork.Point,
        scroll: keywork.ScrollEvent,
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

    fn pointerButton(ctx: *anyopaque, event: keywork.PointerButtonEvent) void {
        const self: *QueuedPlatformEvents = @ptrCast(@alignCast(ctx));
        self.append(.{ .pointer_button = event });
    }

    fn pointerMove(ctx: *anyopaque, point: ?keywork.Point) void {
        const self: *QueuedPlatformEvents = @ptrCast(@alignCast(ctx));
        self.append(.{ .pointer_move = point });
    }

    fn scroll(ctx: *anyopaque, event: keywork.ScrollEvent) void {
        const self: *QueuedPlatformEvents = @ptrCast(@alignCast(ctx));
        self.append(.{ .scroll = event });
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
            .pointer_button => |value| {
                // A press on the parent surface outside every live popup's
                // anchor dismisses the popups and is consumed, so clicking
                // "through" an open menu never activates what's beneath.
                if (!self.popup_surface and value.button == .left and value.state == .pressed) {
                    if (self.popup_manager) |manager| {
                        if (try manager.parent_pointer_down(manager.ctx, value.position)) continue;
                    }
                }
                try self.runtime.pointerButton(value);
            },
            .pointer_move => |point| try self.runtime.pointerMove(point),
            .scroll => |value| try self.runtime.scrollBy(value),
            .key => |input| switch (input) {
                .escape => {
                    if (self.popup_manager) |manager| {
                        if (manager.escape_pressed(manager.ctx)) continue;
                    }
                    try self.runtime.keyInput(input);
                },
                else => try self.runtime.keyInput(input),
            },
            .configure => |size| runtime_mod.Runtime.waylandConfigure(self.runtime, size),
            .frame_done => runtime_mod.Runtime.waylandFrameDone(self.runtime),
        };
    }

    fn afterPlatformHook(ctx: *anyopaque, _: *event_loop.EventLoop) !void {
        const self: *QueuedPlatformEvents = @ptrCast(@alignCast(ctx));
        try self.drain();
        if (self.popup_manager) |manager| try manager.drain_all(manager.ctx);
    }

    fn endTurnHook(ctx: *anyopaque, _: *event_loop.EventLoop) !void {
        const self: *QueuedPlatformEvents = @ptrCast(@alignCast(ctx));
        // Input repeat and kinetic-scroll timers are ordinary event-loop
        // sources, so they can enqueue semantic events after the platform
        // phase. Drain those before presenting the turn's coalesced frame.
        try self.drain();
        if (self.popup_manager) |manager| try manager.drain_all(manager.ctx);
        // While the compositor reports the toplevel suspended (minimized,
        // hidden workspace, fully occluded), skip presentation entirely:
        // invalidations keep coalescing into repaint_pending, and the
        // configure that clears the state wakes the loop and flushes them.
        if (self.suspended_query) |query| {
            if (query.func(query.ctx)) return;
        }
        // Sample dirtiness before the flush clears it: a main-tree
        // rebuild replaces the popup declarations popup runtimes
        // borrow, so their content must rebuild too.
        const content_dirty = self.runtime.rebuild_pending or self.runtime.state_rebuild_pending;
        try self.runtime.flushPendingRepaint();
        if (self.popup_manager) |manager| try manager.reconcile_and_flush(manager.ctx, content_dirty);
    }
};

/// Realizes popups declared by anchored widgets in the main tree as
/// xdg_popup surfaces, each driven by its own runtime. Popup existence is
/// state-driven: every turn the declared popups are diffed against live
/// surfaces, creating missing ones and closing dropped or
/// compositor-dismissed ones.
fn PopupManager(comptime Backend: type) type {
    return struct {
        allocator: std.mem.Allocator,
        backend: *Backend,
        parent: *Backend.Window,
        runtime: *runtime_mod.Runtime,
        popups: std.ArrayList(*PopupSurface) = .empty,
        next_reposition_token: u32 = 1,

        const Self = @This();

        /// Bound applied to a measured axis when the popup declares no
        /// explicit size for it.
        const default_max_size: f32 = 512;

        /// Type-erased entry points for the shared event queue.
        fn hooks(self: *Self) PopupHooks {
            return .{
                .ctx = self,
                .drain_all = drainAllOpaque,
                .reconcile_and_flush = reconcileAndFlushOpaque,
                .parent_pointer_down = parentPointerDownOpaque,
                .escape_pressed = escapePressedOpaque,
            };
        }

        fn parentPointerDownOpaque(ctx: *anyopaque, point: keywork.Point) anyerror!bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.parentPointerDown(point);
        }

        /// A press on the parent window outside every live popup's anchor
        /// dismisses those popups through on_close — like compositor
        /// dismissal — and consumes the press, matching desktop menu
        /// conventions. Presses on an anchor pass through so the anchor's
        /// own gesture can toggle its popup.
        fn parentPointerDown(self: *Self, point: keywork.Point) !bool {
            if (self.popups.items.len == 0) return false;
            for (self.popups.items) |popup| {
                if (popup.anchor_rect.contains(point)) return false;
            }
            return self.dismissAll();
        }

        fn escapePressedOpaque(ctx: *anyopaque) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.dismissAll();
        }

        fn dismissAll(self: *Self) bool {
            if (self.popups.items.len == 0) return false;
            for (self.popups.items) |popup| {
                if (popup.popup.on_close) |on_close| {
                    on_close.call() catch |err| log.warn("popup on_close failed: {}", .{err});
                }
            }
            return true;
        }

        fn drainAllOpaque(ctx: *anyopaque) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            try self.drainAll();
        }

        fn reconcileAndFlushOpaque(ctx: *anyopaque, content_dirty: bool) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            try self.reconcileAndFlush(content_dirty);
        }

        const PopupSurface = struct {
            id: []u8,
            win: *Backend.Window,
            /// Anchor rect in parent-window coordinates; refreshed on every
            /// reconcile pass so parent-press hit-testing tracks layout.
            anchor_rect: keywork.Rect,
            /// Last natural dimensions requested from the compositor.
            /// The configured size can be smaller when screen constraints
            /// force the compositor to resize the popup.
            requested_width: u31,
            requested_height: u31,
            runtime: runtime_mod.Runtime,
            queue: QueuedPlatformEvents,
            /// Borrowed from the main element tree; refreshed on every
            /// reconcile pass before any popup rebuild can observe it.
            popup: *const keywork.Widget.Popup,
        };

        fn deinit(self: *Self) void {
            while (self.popups.items.len > 0) self.destroyPopup(self.popups.items.len - 1);
            self.popups.deinit(self.allocator);
        }

        fn drainAll(self: *Self) !void {
            for (self.popups.items) |popup| try popup.queue.drain();
        }

        /// Diffs popups declared by the main tree against live surfaces.
        /// Runs after the main runtime's flush so anchor rects and borrowed
        /// popup declarations come from the freshly built tree.
        fn reconcileAndFlush(self: *Self, content_dirty: bool) !void {
            const had_popups = self.popups.items.len > 0;
            var requests: std.ArrayList(keywork.PopupRequest) = .empty;
            defer requests.deinit(self.allocator);
            try self.runtime.collectPopupRequests(self.allocator, &requests);

            var index: usize = 0;
            while (index < self.popups.items.len) {
                const popup = self.popups.items[index];
                const request = findRequest(requests.items, popup.id);
                if (popup.win.protocol.closed) {
                    // Compositor dismissal (grab break) reaches the app via
                    // on_close so state stops declaring the popup.
                    if (request) |req| if (req.popup.on_close) |on_close| {
                        on_close.call() catch |err| log.warn("popup on_close failed: {}", .{err});
                    };
                    self.destroyPopup(index);
                    continue;
                }
                if (request == null) {
                    self.destroyPopup(index);
                    continue;
                }
                index += 1;
            }

            for (requests.items) |request| {
                if (self.findPopup(request.id)) |popup| {
                    popup.popup = request.popup;
                    popup.anchor_rect = request.anchor_rect;
                    // measureContent builds a fresh tree, so it reflects
                    // updated parent-owned popup declarations but not state
                    // retained only inside the popup runtime.
                    if (content_dirty) {
                        self.resizePopup(popup, request) catch |err| {
                            log.warn("popup {s} resize failed: {}", .{ request.id, err });
                        };
                    }
                    if (content_dirty) {
                        popup.runtime.rebuild_pending = true;
                        popup.runtime.repaint_pending = true;
                    }
                } else {
                    self.createPopup(request) catch |err| log.warn("popup {s} creation failed: {}", .{ request.id, err });
                }
            }

            for (self.popups.items) |popup| try popup.runtime.flushPendingRepaint();
            if (had_popups and self.popups.items.len == 0) {
                self.backend.setPopupKeyboardFocus(self.parent, false);
            }
        }

        fn findPopup(self: *Self, id: []const u8) ?*PopupSurface {
            for (self.popups.items) |popup| {
                if (std.mem.eql(u8, popup.id, id)) return popup;
            }
            return null;
        }

        fn findRequest(requests: []const keywork.PopupRequest, id: []const u8) ?keywork.PopupRequest {
            for (requests) |request| {
                if (std.mem.eql(u8, request.id, id)) return request;
            }
            return null;
        }

        fn createPopup(self: *Self, request: keywork.PopupRequest) !void {
            const size = try self.measureContent(request.popup);
            const width = try positiveU31(size.width);
            const height = try positiveU31(size.height);
            const rect = request.anchor_rect;

            const surface = try self.allocator.create(PopupSurface);
            errdefer self.allocator.destroy(surface);
            const id = try self.allocator.dupe(u8, request.id);
            errdefer self.allocator.free(id);

            const first_popup = self.popups.items.len == 0;
            if (first_popup) self.backend.setPopupKeyboardFocus(self.parent, true);
            errdefer if (first_popup) self.backend.setPopupKeyboardFocus(self.parent, false);

            const win = try self.backend.createPopup(self.parent, .{
                .width = width,
                .height = height,
                .anchor_x = @intFromFloat(@floor(rect.x)),
                .anchor_y = @intFromFloat(@floor(rect.y)),
                .anchor_width = @intFromFloat(@max(1, @ceil(rect.width))),
                .anchor_height = @intFromFloat(@max(1, @ceil(rect.height))),
                .edge = request.popup.placement.edge,
                .alignment = request.popup.placement.alignment,
                .gap = @intFromFloat(@round(request.popup.placement.gap)),
            });
            errdefer self.backend.destroyWindow(win);

            surface.* = .{
                .id = id,
                .win = win,
                .anchor_rect = request.anchor_rect,
                .requested_width = width,
                .requested_height = height,
                .runtime = undefined,
                .queue = .{ .allocator = self.allocator, .runtime = undefined, .popup_surface = true },
                .popup = request.popup,
            };
            surface.runtime = try runtime_mod.Runtime.init(
                self.allocator,
                win.renderBackend(),
                .{ .max_width = size.width, .max_height = size.height },
                .{ .ptr = surface, .vtable = &popup_host_vtable },
                self.runtime.color_scheme,
            );
            errdefer surface.runtime.deinit();
            surface.queue.runtime = &surface.runtime;
            surface.queue.popup_manager = self.hooks();
            // Popups clear to transparent like layer-shell surfaces: the content
            // paints its own background, so rounded corners stay see-through.
            surface.runtime.setFrameBackground(keywork.colors.transparent);
            surface.runtime.setDeferredRepaint(true);
            surface.runtime.repaint_pending = true;

            win.setPointerButtonHandler(&surface.queue, QueuedPlatformEvents.pointerButton);
            win.setPointerMoveHandler(&surface.queue, QueuedPlatformEvents.pointerMove);
            win.setCursorShapeHandler(&surface.runtime, runtime_mod.Runtime.waylandCursorShape);
            win.setRepaintHandler(&surface.queue, QueuedPlatformEvents.configure);
            win.setFrameHandler(&surface.queue, QueuedPlatformEvents.frameDone);
            win.setKeyHandler(&surface.queue, QueuedPlatformEvents.keyInput);
            win.setScrollHandler(&surface.queue, QueuedPlatformEvents.scroll);

            try self.popups.append(self.allocator, surface);
        }

        /// Re-measures dirty popup content and asks xdg-shell to replace the
        /// live popup's positioner when its natural dimensions changed.
        /// The compositor's configure event then updates the runtime
        /// constraints used for subsequent frames.
        fn resizePopup(self: *Self, popup: *PopupSurface, request: keywork.PopupRequest) !void {
            const size = try self.measureContent(request.popup);
            const width = try positiveU31(size.width);
            const height = try positiveU31(size.height);
            if (width == popup.requested_width and height == popup.requested_height) return;

            const rect = request.anchor_rect;
            const token = self.next_reposition_token;
            self.next_reposition_token +%= 1;
            if (self.next_reposition_token == 0) self.next_reposition_token = 1;
            try self.backend.repositionPopup(popup.win, .{
                .width = width,
                .height = height,
                .anchor_x = @intFromFloat(@floor(rect.x)),
                .anchor_y = @intFromFloat(@floor(rect.y)),
                .anchor_width = @intFromFloat(@max(1, @ceil(rect.width))),
                .anchor_height = @intFromFloat(@max(1, @ceil(rect.height))),
                .edge = request.popup.placement.edge,
                .alignment = request.popup.placement.alignment,
                .gap = @intFromFloat(@round(request.popup.placement.gap)),
            }, token);
            popup.requested_width = width;
            popup.requested_height = height;
        }

        fn destroyPopup(self: *Self, index: usize) void {
            const popup = self.popups.items[index];
            _ = self.popups.orderedRemove(index);
            popup.runtime.deinit();
            popup.queue.deinit();
            self.backend.destroyWindow(popup.win);
            self.allocator.free(popup.id);
            self.allocator.destroy(popup);
        }

        /// Builds the popup content in a throwaway arena and lays it out to
        /// learn its natural size, so the surface can be created at the right
        /// dimensions before the popup runtime exists.
        fn measureContent(self: *Self, popup: *const keywork.Widget.Popup) !keywork.Size {
            if (popup.width) |width| if (popup.height) |height| {
                return .{ .width = width, .height = height };
            };

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const arena_allocator = arena.allocator();

            const constraints: keywork.Constraints = .{
                .max_width = popup.width orelse default_max_size,
                .max_height = popup.height orelse default_max_size,
            };
            const app_context: keywork.AppContext = .{
                .window_width = constraints.max_width,
                .window_height = constraints.max_height,
                .color_scheme = self.runtime.color_scheme.name(),
            };
            var scope: keywork.BuildScope = .{
                .allocator = arena_allocator,
                .theme = keywork.Theme.fromColorScheme(app_context.color_scheme),
                .app_context = app_context,
                .render_scale = self.runtime.renderScale(),
            };
            const widget = try popup.builder.build(&scope, .{
                .constraints = constraints,
                .theme = scope.theme,
                .default_text_style = scope.default_text_style,
                .app_context = app_context,
            });
            var element = try keywork.buildElementTreeScoped(arena_allocator, &scope, &widget, constraints);
            defer keywork.destroyElementTree(arena_allocator, &element);
            const root = try keywork.buildRenderTreeFromElement(arena_allocator, &element, constraints, self.parent.renderBackend());
            return .{
                .width = popup.width orelse @min(root.rect.width, constraints.max_width),
                .height = popup.height orelse @min(root.rect.height, constraints.max_height),
            };
        }

        const popup_host_vtable: keywork.AppHost.VTable = .{ .build_widget = popupBuildWidget };

        fn popupBuildWidget(ptr: *anyopaque, scope: *keywork.BuildScope, context: keywork.AppContext) anyerror!keywork.Widget {
            const surface: *PopupSurface = @ptrCast(@alignCast(ptr));
            return surface.popup.builder.build(scope, .{
                .constraints = .{ .max_width = context.window_width, .max_height = context.window_height },
                .theme = scope.theme,
                .default_text_style = scope.default_text_style,
                .interaction = scope.interaction,
                .app_context = context,
            });
        }
    };
}

fn runWaylandWindowed(
    allocator: std.mem.Allocator,
    loop: *event_loop.EventLoop,
    windows_host: app_windows.WindowsHost,
    options: Options,
    comptime Backend: type,
) !void {
    const Manager = WindowManager(Backend);

    var settings_client: ?desktop_settings.Client = desktop_settings.Client.init() catch |err| blk: {
        log.warn("desktop settings unavailable: {}", .{err});
        break :blk null;
    };
    defer if (settings_client) |*settings| settings.deinit();

    var backend = try Backend.create(allocator);
    defer backend.destroy();

    if (settings_client) |*settings| settings.finishColorSchemeRead();
    const initial_color_scheme: runtime_mod.UiColorScheme = if (settings_client) |settings| uiColorScheme(settings.color_scheme) else .no_preference;

    var manager: Manager = .{
        .allocator = allocator,
        .backend = backend,
        .windows_host = windows_host,
        .options = &options,
        .color_scheme = initial_color_scheme,
    };
    defer manager.deinit();
    backend.setOutputsChangedHandler(&manager, Manager.outputsChanged);

    if (options.bind_invalidator) |bind| bind(options.runtime_context.?, manager.invalidator());
    defer if (options.unbind_runtime) |unbind| unbind(options.runtime_context.?);
    if (options.bind_event_loop) |bind| try bind(options.runtime_context.?, loop);
    defer if (options.unbind_event_loop) |unbind| unbind(options.runtime_context.?);

    if (settings_client) |*settings| {
        try settings.installSignalFilter();
        settings.setChangeHandler(&manager, Manager.desktopSettingsChanged);
    }

    try manager.reconcile();
    if (manager.shouldQuit()) return;

    // Loop lifetime is the manager's decision, not the backend's: zero
    // live windows is a valid state while the app waits for outputs.
    try loop.setWayland(.{
        .fd = backend.eventLoopFd(),
        .ctx = backend,
        .prepare = Backend.eventLoopPrepare,
        .finish = Backend.eventLoopFinishKeepAlive,
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
    loop.setAfterPlatformHook(&manager, Manager.afterPlatformHook);
    defer loop.clearAfterPlatformHook();
    loop.setEndTurnHook(&manager, Manager.endTurnHook);
    defer loop.clearEndTurnHook();
    try loop.run();
}

/// Reconciles the app's declared window set against live surfaces by id:
/// each managed window owns its surface, runtime, input queue, and popup
/// manager. Output hotplug, script invalidation, and compositor closes
/// all mark the set for reconciliation at end of turn.
fn WindowManager(comptime Backend: type) type {
    return struct {
        allocator: std.mem.Allocator,
        backend: *Backend,
        windows_host: app_windows.WindowsHost,
        options: *const Options,
        color_scheme: runtime_mod.UiColorScheme = .no_preference,
        windows: std.ArrayList(*ManagedWindow) = .empty,
        /// Ids the compositor closed while the app still declares them;
        /// skipped on reconcile so a close is not immediately undone. An id
        /// is forgotten once its declaration disappears, letting the app
        /// re-declare it later.
        closed_ids: std.StringHashMapUnmanaged(void) = .empty,
        reconcile_pending: bool = false,

        const Self = @This();

        const ManagedWindow = struct {
            manager: *Self,
            id: []u8,
            win: *Backend.Window,
            layer_shell: bool,
            runtime: runtime_mod.Runtime,
            queue: QueuedPlatformEvents,
            popups: PopupManager(Backend),
        };

        fn deinit(self: *Self) void {
            while (self.windows.items.len > 0) self.destroyManaged(self.windows.items.len - 1);
            self.windows.deinit(self.allocator);
            var it = self.closed_ids.iterator();
            while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
            self.closed_ids.deinit(self.allocator);
        }

        fn invalidator(self: *Self) runtime_mod.Invalidator {
            return .{
                .ptr = self,
                .invalidate_fn = invalidateAll,
                .invalidate_state_fn = invalidateStateAll,
            };
        }

        fn invalidateAll(ptr: *anyopaque) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.reconcile_pending = true;
            for (self.windows.items) |managed| try managed.runtime.invalidate();
        }

        fn invalidateStateAll(ptr: *anyopaque) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.reconcile_pending = true;
            for (self.windows.items) |managed| try managed.runtime.invalidateState();
        }

        fn outputsChanged(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.reconcile_pending = true;
        }

        fn desktopSettingsChanged(ctx: *anyopaque, color_scheme: desktop_settings.ColorScheme) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const scheme = uiColorScheme(color_scheme);
            self.color_scheme = scheme;
            // The window set itself may branch on the color scheme.
            self.reconcile_pending = true;
            for (self.windows.items) |managed| managed.runtime.setColorScheme(scheme) catch |err| {
                log.warn("window {s}: color scheme change failed: {}", .{ managed.id, err });
            };
        }

        fn afterPlatformHook(ctx: *anyopaque, _: *event_loop.EventLoop) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            try self.drainAll();
        }

        fn endTurnHook(ctx: *anyopaque, loop: *event_loop.EventLoop) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            // Input repeat and kinetic-scroll timers are ordinary event-loop
            // sources, so they can enqueue semantic events after the platform
            // phase. Drain those before presenting the turn's coalesced frame.
            try self.drainAll();
            for (self.windows.items) |managed| {
                if (managed.win.protocol.closed) self.reconcile_pending = true;
            }
            if (self.reconcile_pending) {
                try self.reconcile();
                if (self.shouldQuit()) {
                    loop.quit();
                    return;
                }
            }
            for (self.windows.items) |managed| {
                // Layer-shell surfaces never receive xdg_toplevel suspension,
                // so only regular toplevels pause presentation while hidden.
                if (!managed.layer_shell and Backend.Window.suspendedOpaque(managed.win)) continue;
                // Sample dirtiness before the flush clears it: a main-tree
                // rebuild replaces the popup declarations popup runtimes
                // borrow, so their content must rebuild too.
                const content_dirty = managed.runtime.rebuild_pending or managed.runtime.state_rebuild_pending;
                try managed.runtime.flushPendingRepaint();
                try managed.popups.reconcileAndFlush(content_dirty);
            }
        }

        fn drainAll(self: *Self) !void {
            for (self.windows.items) |managed| {
                try managed.queue.drain();
                try managed.popups.drainAll();
            }
        }

        /// After a reconcile, `closed_ids` holds only ids the app still
        /// declares but the compositor closed. No live windows plus such an
        /// id means the user closed the app's last window: quit. Zero
        /// windows with zero closed ids is the app declaring none — a valid
        /// state (for example a shell waiting for output hotplug).
        fn shouldQuit(self: *const Self) bool {
            return self.windows.items.len == 0 and self.closed_ids.count() > 0;
        }

        /// Diffs the declared window set against live surfaces: destroys
        /// closed and dropped windows, creates missing ones. Declarations are
        /// built into a throwaway arena.
        fn reconcile(self: *Self) !void {
            self.reconcile_pending = false;

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const arena_allocator = arena.allocator();

            var outputs: std.ArrayList(wayland_options.OutputInfo) = .empty;
            for (0..self.backend.outputCount()) |index| {
                try outputs.append(arena_allocator, self.backend.outputInfoAt(index));
            }
            const context: app_windows.WindowsContext = .{
                .outputs = outputs.items,
                .color_scheme = self.color_scheme.name(),
            };
            const decls = self.windows_host.buildWindows(arena_allocator, context) catch |err| {
                log.warn("window set build failed: {}", .{err});
                return;
            };

            var index: usize = 0;
            while (index < self.windows.items.len) {
                const managed = self.windows.items[index];
                if (managed.win.protocol.closed) {
                    // Remember compositor closes so the still-present
                    // declaration does not resurrect the window.
                    self.rememberClosed(managed.id);
                    self.destroyManaged(index);
                    continue;
                }
                if (findDecl(decls, managed.id) == null) {
                    self.destroyManaged(index);
                    continue;
                }
                index += 1;
            }

            var stale_ids: std.ArrayList([]const u8) = .empty;
            var closed_it = self.closed_ids.iterator();
            while (closed_it.next()) |entry| {
                if (findDecl(decls, entry.key_ptr.*) == null) try stale_ids.append(arena_allocator, entry.key_ptr.*);
            }
            for (stale_ids.items) |id| {
                const key = self.closed_ids.getKey(id).?;
                _ = self.closed_ids.remove(id);
                self.allocator.free(key);
            }

            for (decls) |decl| {
                if (self.closed_ids.contains(decl.id)) continue;
                if (self.findManaged(decl.id) != null) continue;
                self.createManaged(decl) catch |err| {
                    log.warn("window {s}: creation failed: {}", .{ decl.id, err });
                };
            }
        }

        fn findDecl(decls: []const app_windows.WindowDeclaration, id: []const u8) ?*const app_windows.WindowDeclaration {
            for (decls) |*decl| {
                if (std.mem.eql(u8, decl.id, id)) return decl;
            }
            return null;
        }

        fn findManaged(self: *Self, id: []const u8) ?*ManagedWindow {
            for (self.windows.items) |managed| {
                if (std.mem.eql(u8, managed.id, id)) return managed;
            }
            return null;
        }

        fn rememberClosed(self: *Self, id: []const u8) void {
            if (self.closed_ids.contains(id)) return;
            const key = self.allocator.dupe(u8, id) catch return;
            self.closed_ids.put(self.allocator, key, {}) catch self.allocator.free(key);
        }

        fn createManaged(self: *Self, decl: app_windows.WindowDeclaration) !void {
            // Null declaration fields inherit the app-level defaults.
            const layer_shell = decl.layer_shell orelse self.options.layer_shell;
            const width = decl.width orelse self.options.width;
            const height = decl.height orelse self.options.height;
            const output = if (decl.output) |name|
                self.backend.findOutputByName(name) orelse return error.UnknownOutput
            else
                null;

            const win = try self.backend.createWindow(.{
                .title = decl.title orelse self.options.title,
                .app_id = self.options.app_id,
                .width = if (layer_shell != null and width <= 0) 0 else try positiveU31(width),
                .height = try positiveU31(height),
                .layer_shell = layer_shell,
                .output = output,
            });
            errdefer self.backend.destroyWindow(win);
            // Per-window wait: a global wait would clear other windows'
            // pending frame-done events without routing them to handlers.
            try self.backend.waitForConfigured(win);

            const managed = try self.allocator.create(ManagedWindow);
            errdefer self.allocator.destroy(managed);
            const id = try self.allocator.dupe(u8, decl.id);
            errdefer self.allocator.free(id);

            const size = win.currentSize();
            managed.* = .{
                .manager = self,
                .id = id,
                .win = win,
                .layer_shell = layer_shell != null,
                .runtime = undefined,
                .queue = .{ .allocator = self.allocator, .runtime = undefined },
                .popups = .{
                    .allocator = self.allocator,
                    .backend = self.backend,
                    .parent = win,
                    .runtime = undefined,
                },
            };
            managed.runtime = try runtime_mod.Runtime.init(
                self.allocator,
                win.renderBackend(),
                .{ .max_width = size.width, .max_height = size.height },
                .{ .ptr = managed, .vtable = &managed_host_vtable },
                self.color_scheme,
            );
            errdefer managed.runtime.deinit();
            managed.queue.runtime = &managed.runtime;
            managed.queue.popup_manager = managed.popups.hooks();
            managed.popups.runtime = &managed.runtime;
            if (managed.layer_shell) managed.runtime.setFrameBackground(keywork.colors.transparent);
            managed.runtime.setDeferredRepaint(true);

            win.setPointerButtonHandler(&managed.queue, QueuedPlatformEvents.pointerButton);
            win.setPointerMoveHandler(&managed.queue, QueuedPlatformEvents.pointerMove);
            win.setCursorShapeHandler(&managed.runtime, runtime_mod.Runtime.waylandCursorShape);
            win.setRepaintHandler(&managed.queue, QueuedPlatformEvents.configure);
            win.setFrameHandler(&managed.queue, QueuedPlatformEvents.frameDone);
            win.setKeyHandler(&managed.queue, QueuedPlatformEvents.keyInput);
            win.setScrollHandler(&managed.queue, QueuedPlatformEvents.scroll);

            try self.windows.append(self.allocator, managed);
            errdefer {
                _ = self.windows.pop();
                managed.queue.deinit();
            }
            try managed.runtime.repaint();
        }

        fn destroyManaged(self: *Self, index: usize) void {
            const managed = self.windows.items[index];
            _ = self.windows.orderedRemove(index);
            managed.popups.deinit();
            managed.runtime.deinit();
            managed.queue.deinit();
            self.backend.destroyWindow(managed.win);
            self.allocator.free(managed.id);
            self.allocator.destroy(managed);
        }

        const managed_host_vtable: keywork.AppHost.VTable = .{ .build_widget = managedBuildWidget };

        fn managedBuildWidget(ptr: *anyopaque, scope: *keywork.BuildScope, context: keywork.AppContext) anyerror!keywork.Widget {
            const managed: *ManagedWindow = @ptrCast(@alignCast(ptr));
            return managed.manager.windows_host.buildWindowWidget(managed.id, scope, context);
        }
    };
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

test "queued escape dismisses an open popup" {
    const Hooks = struct {
        fn drainAll(_: *anyopaque) anyerror!void {}
        fn reconcileAndFlush(_: *anyopaque, _: bool) anyerror!void {}
        fn parentPointerDown(_: *anyopaque, _: keywork.Point) anyerror!bool {
            return false;
        }
        fn escapePressed(ctx: *anyopaque) bool {
            const dismissed: *bool = @ptrCast(@alignCast(ctx));
            dismissed.* = true;
            return true;
        }
    };

    var dismissed = false;
    var runtime: runtime_mod.Runtime = undefined;
    var queue: QueuedPlatformEvents = .{
        .allocator = std.testing.allocator,
        .runtime = &runtime,
        .popup_manager = .{
            .ctx = &dismissed,
            .drain_all = Hooks.drainAll,
            .reconcile_and_flush = Hooks.reconcileAndFlush,
            .parent_pointer_down = Hooks.parentPointerDown,
            .escape_pressed = Hooks.escapePressed,
        },
    };
    defer queue.deinit();

    QueuedPlatformEvents.keyInput(&queue, .escape);
    try queue.drain();

    try std.testing.expect(dismissed);
}
