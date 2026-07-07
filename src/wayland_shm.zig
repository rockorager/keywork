//! Minimal `wl_shm` render backend for Keywork display lists.

const std = @import("std");
const event_loop = @import("event_loop.zig");
const keywork = @import("core.zig");
const TextRenderer = @import("text_renderer.zig");
const WaylandInput = @import("wayland_input.zig");
const wayland = @import("wayland");

const linux = std.os.linux;
const posix = std.posix;
const wp = wayland.client.wp;
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const zwlr = wayland.client.zwlr;

const log = std.log.scoped(.keywork_wayland_shm);

pub const Backend = struct {
    allocator: std.mem.Allocator,
    display: *wl.Display,
    registry: *wl.Registry,
    compositor: *wl.Compositor,
    shm: *wl.Shm,
    wm_base: ?*xdg.WmBase,
    layer_shell: ?*zwlr.LayerShellV1,
    viewporter: ?*wp.Viewporter,
    fractional_scale_manager: ?*wp.FractionalScaleManagerV1,
    cursor_shape_manager: ?*wp.CursorShapeManagerV1,
    input: WaylandInput,
    surface: *wl.Surface,
    viewport: ?*wp.Viewport,
    fractional_scale: ?*wp.FractionalScaleV1,
    shell_role: ShellRole,
    buffers: std.ArrayList(*Buffer),
    /// The buffer holding the most recently rendered frame; the source for
    /// partial redraws when the compositor hands us a different buffer.
    last_rendered: ?*Buffer = null,
    text_renderer: TextRenderer,
    configured: bool,
    closed: bool,
    width: u31,
    height: u31,
    scale: f32,
    scale_changed: bool,
    repaint_pending: bool,

    repaint_handler: ?RepaintHandler,
    repaint_context: ?*anyopaque,
    frame_handler: ?FrameHandler,
    frame_context: ?*anyopaque,
    frame_callback: ?*wl.Callback,
    frame_done_pending: bool,
    extra_surfaces: std.ArrayList(ExtraSurface),
    outputs: std.ArrayList(OutputRef),

    pub const PointerButtonHandler = WaylandInput.PointerButtonHandler;
    pub const PointerMoveHandler = WaylandInput.PointerMoveHandler;
    pub const CursorShapeHandler = WaylandInput.CursorShapeHandler;
    pub const KeyHandler = WaylandInput.KeyHandler;
    pub const ScrollHandler = WaylandInput.ScrollHandler;
    pub const RepaintHandler = *const fn (ctx: *anyopaque, size: keywork.Size) void;
    pub const FrameHandler = *const fn (ctx: *anyopaque) void;

    pub const Options = struct {
        title: [:0]const u8 = "Keywork",
        app_id: [:0]const u8 = "dev.keywork.Keywork",
        width: u31 = 640,
        height: u31 = 480,
        layer_shell: ?keywork.LayerShellOptions = null,
    };

    const ShellRole = union(enum) {
        xdg: struct {
            surface: *xdg.Surface,
            toplevel: *xdg.Toplevel,
        },
        layer: struct {
            surface: *zwlr.LayerSurfaceV1,
        },

        fn destroy(self: ShellRole) void {
            switch (self) {
                .xdg => |role| {
                    role.toplevel.destroy();
                    role.surface.destroy();
                },
                .layer => |role| role.surface.destroy(),
            }
        }
    };

    const Globals = struct {
        allocator: std.mem.Allocator,
        compositor: ?*wl.Compositor = null,
        shm: ?*wl.Shm = null,
        wm_base: ?*xdg.WmBase = null,
        layer_shell: ?*zwlr.LayerShellV1 = null,
        viewporter: ?*wp.Viewporter = null,
        fractional_scale_manager: ?*wp.FractionalScaleManagerV1 = null,
        cursor_shape_manager: ?*wp.CursorShapeManagerV1 = null,
        seat: ?*wl.Seat = null,
        outputs: std.ArrayList(OutputRef) = .empty,
    };

    const OutputRef = struct {
        global_name: u32,
        output: *wl.Output,
    };

    const ExtraSurface = struct {
        backend: ?*Backend = null,
        surface: *wl.Surface,
        viewport: ?*wp.Viewport,
        fractional_scale: ?*wp.FractionalScaleV1,
        shell_role: ShellRole,
        buffers: std.ArrayList(*Buffer) = .empty,
        last_rendered: ?*Buffer = null,
        configured: bool = false,
        closed: bool = false,
        width: u31,
        height: u31,
        scale: f32 = 1,
        scale_changed: bool = false,
        repaint_pending: bool = false,
        frame_callback: ?*wl.Callback = null,
        frame_done_pending: bool = false,

        fn destroy(self: *ExtraSurface, allocator: std.mem.Allocator) void {
            if (self.frame_callback) |callback| callback.destroy();
            for (self.buffers.items) |buffer| buffer.destroy(allocator);
            self.buffers.deinit(allocator);
            if (self.fractional_scale) |fractional_scale| fractional_scale.destroy();
            if (self.viewport) |viewport| viewport.destroy();
            self.shell_role.destroy();
            self.surface.destroy();
        }
    };

    pub fn create(allocator: std.mem.Allocator, options: Options) !*Backend {
        const display = try wl.Display.connect(null);
        errdefer display.disconnect();

        const registry = try display.getRegistry();
        var globals: Globals = .{ .allocator = allocator };
        errdefer releaseOutputs(allocator, &globals.outputs);
        registry.setListener(*Globals, registryListener, &globals);
        if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

        const compositor = globals.compositor orelse return error.NoWlCompositor;
        const shm = globals.shm orelse return error.NoWlShm;
        const wm_base = globals.wm_base;
        const layer_shell = globals.layer_shell;
        const viewporter = globals.viewporter;
        const fractional_scale_manager = globals.fractional_scale_manager;
        const cursor_shape_manager = globals.cursor_shape_manager;

        const all_outputs = if (options.layer_shell) |layer_options| layer_options.output == .all else false;
        if (all_outputs and globals.outputs.items.len == 0) return error.NoWlOutput;
        const primary_output = if (all_outputs) globals.outputs.items[0].output else null;

        const surface = try compositor.createSurface();
        errdefer surface.destroy();
        const shell_role = try createShellRole(surface, primary_output, wm_base, layer_shell, options);
        errdefer shell_role.destroy();
        const viewport = if (viewporter) |manager| try manager.getViewport(surface) else null;
        errdefer if (viewport) |surface_viewport| surface_viewport.destroy();
        const fractional_scale = if (fractional_scale_manager) |manager| try manager.getFractionalScale(surface) else null;
        errdefer if (fractional_scale) |surface_scale| surface_scale.destroy();

        var extra_surfaces: std.ArrayList(ExtraSurface) = .empty;
        errdefer {
            for (extra_surfaces.items) |*extra| extra.destroy(allocator);
            extra_surfaces.deinit(allocator);
        }
        if (all_outputs) {
            for (globals.outputs.items[1..]) |output_ref| {
                const extra = try createExtraSurface(
                    allocator,
                    compositor,
                    output_ref.output,
                    wm_base,
                    layer_shell,
                    viewporter,
                    fractional_scale_manager,
                    options,
                );
                try extra_surfaces.append(allocator, extra);
            }
        }

        var text_renderer_instance = try TextRenderer.init(allocator);
        errdefer text_renderer_instance.deinit();
        var input = try WaylandInput.init(globals.seat, cursor_shape_manager);
        errdefer input.deinit();

        const self = try allocator.create(Backend);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .display = display,
            .registry = registry,
            .compositor = compositor,
            .shm = shm,
            .wm_base = wm_base,
            .layer_shell = layer_shell,
            .viewporter = viewporter,
            .fractional_scale_manager = fractional_scale_manager,
            .cursor_shape_manager = cursor_shape_manager,
            .input = input,
            .surface = surface,
            .viewport = viewport,
            .fractional_scale = fractional_scale,
            .shell_role = shell_role,
            .buffers = .empty,
            .text_renderer = text_renderer_instance,
            .configured = false,
            .closed = false,
            .width = options.width,
            .height = options.height,
            .scale = 1,
            .scale_changed = false,
            .repaint_pending = false,
            .repaint_handler = null,
            .repaint_context = null,
            .frame_handler = null,
            .frame_context = null,
            .frame_callback = null,
            .frame_done_pending = false,
            .extra_surfaces = extra_surfaces,
            .outputs = globals.outputs,
        };

        if (wm_base) |base| base.setListener(*Backend, wmBaseListener, self);
        switch (self.shell_role) {
            .xdg => |role| {
                role.surface.setListener(*Backend, xdgSurfaceListener, self);
                role.toplevel.setListener(*Backend, toplevelListener, self);
            },
            .layer => |role| role.surface.setListener(*Backend, layerSurfaceListener, self),
        }
        if (fractional_scale) |surface_scale| surface_scale.setListener(*Backend, fractionalScaleListener, self);
        for (self.extra_surfaces.items) |*extra| {
            extra.backend = self;
            switch (extra.shell_role) {
                .xdg => unreachable,
                .layer => |role| role.surface.setListener(*ExtraSurface, extraLayerSurfaceListener, extra),
            }
            if (extra.fractional_scale) |surface_scale| surface_scale.setListener(*ExtraSurface, extraFractionalScaleListener, extra);
            extra.surface.commit();
        }
        self.input.attachListeners(Backend, self);
        surface.commit();

        return self;
    }

    pub fn destroy(self: *Backend) void {
        if (self.frame_callback) |callback| callback.destroy();
        for (self.buffers.items) |buffer| buffer.destroy(self.allocator);
        self.buffers.deinit(self.allocator);
        for (self.extra_surfaces.items) |*extra| extra.destroy(self.allocator);
        self.extra_surfaces.deinit(self.allocator);
        self.text_renderer.deinit();
        self.input.deinit();
        if (self.fractional_scale) |fractional_scale| fractional_scale.destroy();
        if (self.viewport) |viewport| viewport.destroy();
        self.shell_role.destroy();
        self.surface.destroy();
        if (self.cursor_shape_manager) |manager| manager.destroy();
        if (self.fractional_scale_manager) |manager| manager.destroy();
        if (self.viewporter) |viewporter| viewporter.destroy();
        if (self.layer_shell) |layer_shell| layer_shell.destroy();
        if (self.wm_base) |wm_base| wm_base.destroy();
        self.shm.destroy();
        self.compositor.destroy();
        releaseOutputs(self.allocator, &self.outputs);
        self.registry.destroy();
        self.display.disconnect();
        self.allocator.destroy(self);
    }

    pub fn renderBackend(self: *Backend) keywork.RenderBackend {
        return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = renderScale } };
    }

    pub fn outputCount(self: *const Backend) usize {
        return 1 + self.extra_surfaces.items.len;
    }

    pub fn outputSize(self: *const Backend, index: usize) keywork.Size {
        if (index == 0) return self.currentSize();
        const extra = &self.extra_surfaces.items[index - 1];
        return .{ .width = @floatFromInt(extra.width), .height = @floatFromInt(extra.height) };
    }

    pub fn renderBackendForOutput(self: *Backend, index: usize) OutputRenderBackend {
        return .{ .backend = self, .index = index };
    }

    pub const OutputRenderBackend = struct {
        backend: *Backend,
        index: usize,

        pub fn backendInterface(self: *OutputRenderBackend) keywork.RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = presentOutput, .measure_text = measureTextOutput, .scale = scaleOutput } };
        }

        fn presentOutput(ptr: *anyopaque, frame: keywork.RenderBackend.Frame) !bool {
            const self: *OutputRenderBackend = @ptrCast(@alignCast(ptr));
            while (!self.backend.allConfigured() and !self.backend.allClosed()) {
                if (self.backend.display.dispatch() != .SUCCESS) return error.DispatchFailed;
            }
            if (self.index == 0) {
                if (self.backend.closed) return false;
                const pending = try self.backend.presentPrimary(frame);
                _ = self.backend.display.flush();
                return pending;
            }
            const extra = &self.backend.extra_surfaces.items[self.index - 1];
            if (extra.closed) return false;
            const pending = try self.backend.presentExtra(extra, frame);
            _ = self.backend.display.flush();
            return pending;
        }

        fn measureTextOutput(ptr: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !keywork.Size {
            const self: *OutputRenderBackend = @ptrCast(@alignCast(ptr));
            return self.backend.text_renderer.measure(self.scale(), value, style);
        }

        fn scaleOutput(ptr: *anyopaque) f32 {
            const self: *OutputRenderBackend = @ptrCast(@alignCast(ptr));
            return self.scale();
        }

        fn scale(self: *const OutputRenderBackend) f32 {
            if (self.index == 0) return self.backend.scale;
            return self.backend.extra_surfaces.items[self.index - 1].scale;
        }
    };

    pub fn setPointerButtonHandler(self: *Backend, context: *anyopaque, handler: PointerButtonHandler) void {
        self.input.setPointerButtonHandler(context, handler);
    }

    pub fn setPointerMoveHandler(self: *Backend, context: *anyopaque, handler: PointerMoveHandler) void {
        self.input.setPointerMoveHandler(context, handler);
    }

    pub fn setCursorShapeHandler(self: *Backend, context: *anyopaque, handler: CursorShapeHandler) void {
        self.input.setCursorShapeHandler(context, handler);
    }

    pub fn setKeyHandler(self: *Backend, context: *anyopaque, handler: KeyHandler) void {
        self.input.setKeyHandler(context, handler);
    }

    pub fn setScrollHandler(self: *Backend, context: *anyopaque, handler: ScrollHandler) void {
        self.input.setScrollHandler(context, handler);
    }

    pub fn installEventTimers(self: *Backend, loop: *event_loop.EventLoop) !void {
        try self.input.installEventTimers(loop);
    }

    pub fn uninstallEventTimers(self: *Backend) void {
        self.input.uninstallEventTimers();
    }

    pub fn setRepaintHandler(self: *Backend, context: *anyopaque, handler: RepaintHandler) void {
        self.repaint_context = context;
        self.repaint_handler = handler;
    }

    pub fn setFrameHandler(self: *Backend, context: *anyopaque, handler: FrameHandler) void {
        self.frame_context = context;
        self.frame_handler = handler;
    }

    pub fn dispatch(self: *Backend) !bool {
        if (self.display.dispatch() != .SUCCESS) return error.DispatchFailed;
        return !self.closed;
    }

    pub fn eventLoopFd(self: *Backend) i32 {
        return self.display.getFd();
    }

    pub fn waitForInitialConfigure(self: *Backend) !keywork.Size {
        while (!self.allConfigured() and !self.allClosed()) {
            if (self.display.dispatch() != .SUCCESS) return error.DispatchFailed;
        }
        if (self.allClosed()) return error.WindowClosed;
        self.flushPending();
        return self.currentSize();
    }

    pub fn eventLoopPrepare(ctx: *anyopaque) !u32 {
        const self: *Backend = @ptrCast(@alignCast(ctx));
        while (!self.display.prepareRead()) {
            if (self.display.dispatchPending() != .SUCCESS) return error.DispatchFailed;
            self.flushPending();
        }

        return switch (self.display.flush()) {
            .SUCCESS => linux.EPOLL.IN,
            .AGAIN => linux.EPOLL.IN | linux.EPOLL.OUT,
            else => {
                self.display.cancelRead();
                return error.FlushFailed;
            },
        };
    }

    pub fn eventLoopFinish(ctx: *anyopaque, events: u32) !bool {
        const self: *Backend = @ptrCast(@alignCast(ctx));
        if (events & linux.EPOLL.IN != 0) {
            if (self.display.readEvents() != .SUCCESS) return error.ReadEventsFailed;
        } else {
            self.display.cancelRead();
        }

        if (self.display.dispatchPending() != .SUCCESS) return error.DispatchFailed;
        self.flushPending();
        return !self.allClosed();
    }

    fn present(ptr: *anyopaque, frame: keywork.RenderBackend.Frame) !bool {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        if (self.allClosed()) return error.WindowClosed;

        while (!self.allConfigured() and !self.allClosed()) {
            if (self.display.dispatch() != .SUCCESS) return error.DispatchFailed;
        }
        if (self.allClosed()) return error.WindowClosed;

        var frame_pending = false;
        if (!self.closed) frame_pending = try self.presentPrimary(frame) or frame_pending;
        for (self.extra_surfaces.items) |*extra| {
            if (!extra.closed) frame_pending = try self.presentExtra(extra, frame) or frame_pending;
        }
        _ = self.display.flush();
        return frame_pending;
    }

    fn presentPrimary(self: *Backend, frame: keywork.RenderBackend.Frame) !bool {
        const logical_width = try frameLogicalWidth(frame, self.width);
        const logical_height = try frameLogicalHeight(frame, self.height);
        const width = try scaledFrameDimension(logical_width, self.scale);
        const height = try scaledFrameDimension(logical_height, self.scale);
        const buffer = try self.acquireBuffer(width, height);
        const damage_clip = self.partialDamageClip(frame, buffer, width, height);
        try rasterize(&self.text_renderer, buffer.pixels(), width, height, self.scale, frame.display_list, damage_clip);
        self.last_rendered = buffer;

        try self.armFrameCallback();
        self.surface.attach(buffer.wl_buffer, 0, 0);
        if (damage_clip) |clip| {
            const x0: i32 = @max(0, clip.x0);
            const y0: i32 = @max(0, clip.y0);
            const x1: i32 = @min(@as(i32, width), clip.x1);
            const y1: i32 = @min(@as(i32, height), clip.y1);
            self.surface.damageBuffer(x0, y0, @max(0, x1 - x0), @max(0, y1 - y0));
        } else {
            self.surface.damageBuffer(0, 0, width, height);
        }
        self.surface.setBufferScale(1);
        if (self.viewport) |viewport| viewport.setDestination(logical_width, logical_height);
        self.surface.commit();
        buffer.busy = true;
        return true;
    }

    fn presentExtra(self: *Backend, extra: *ExtraSurface, frame: keywork.RenderBackend.Frame) !bool {
        const logical_width = try frameLogicalWidth(frame, extra.width);
        const logical_height = try frameLogicalHeight(frame, extra.height);
        const width = try scaledFrameDimension(logical_width, extra.scale);
        const height = try scaledFrameDimension(logical_height, extra.scale);
        const buffer = try self.acquireExtraBuffer(extra, width, height);
        try rasterize(&self.text_renderer, buffer.pixels(), width, height, extra.scale, frame.display_list, null);
        extra.last_rendered = buffer;

        try self.armExtraFrameCallback(extra);
        extra.surface.attach(buffer.wl_buffer, 0, 0);
        extra.surface.damageBuffer(0, 0, width, height);
        extra.surface.setBufferScale(1);
        if (extra.viewport) |viewport| viewport.setDestination(logical_width, logical_height);
        extra.surface.commit();
        buffer.busy = true;
        return true;
    }

    fn measureText(ptr: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !keywork.Size {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        return self.text_renderer.measure(self.scale, value, style);
    }

    fn renderScale(ptr: *anyopaque) f32 {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        return self.scale;
    }

    fn notifyRepaint(self: *Backend) void {
        if (self.repaint_handler) |handler| handler(self.repaint_context.?, self.currentSize());
    }

    fn currentSize(self: *const Backend) keywork.Size {
        return .{ .width = @floatFromInt(self.width), .height = @floatFromInt(self.height) };
    }

    fn queueRepaint(self: *Backend) void {
        self.repaint_pending = true;
    }

    fn flushPending(self: *Backend) void {
        if (self.scale_changed) {
            self.scale_changed = false;
            self.queueRepaint();
        }
        for (self.extra_surfaces.items) |*extra| {
            if (extra.scale_changed) {
                extra.scale_changed = false;
                extra.repaint_pending = true;
            }
            if (extra.repaint_pending) {
                extra.repaint_pending = false;
                self.queueRepaint();
            }
        }
        if (self.repaint_pending) {
            self.repaint_pending = false;
            self.notifyRepaint();
        }
        self.dispatchFrameDone();
        for (self.extra_surfaces.items) |*extra| self.dispatchExtraFrameDone(extra);
    }

    fn armFrameCallback(self: *Backend) !void {
        if (self.frame_callback != null) return;
        const callback = try self.surface.frame();
        callback.setListener(*Backend, frameListener, self);
        self.frame_callback = callback;
    }

    fn frameListener(callback: *wl.Callback, event: wl.Callback.Event, self: *Backend) void {
        switch (event) {
            .done => {
                if (self.frame_callback == callback) self.frame_callback = null;
                callback.destroy();
                self.frame_done_pending = true;
            },
        }
    }

    fn dispatchFrameDone(self: *Backend) void {
        if (!self.frame_done_pending) return;
        self.frame_done_pending = false;
        if (self.frame_handler) |handler| handler(self.frame_context.?);
    }

    fn armExtraFrameCallback(self: *Backend, extra: *ExtraSurface) !void {
        _ = self;
        if (extra.frame_callback != null) return;
        const callback = try extra.surface.frame();
        callback.setListener(*ExtraSurface, extraFrameListener, extra);
        extra.frame_callback = callback;
    }

    fn extraFrameListener(callback: *wl.Callback, event: wl.Callback.Event, extra: *ExtraSurface) void {
        switch (event) {
            .done => {
                if (extra.frame_callback == callback) extra.frame_callback = null;
                callback.destroy();
                extra.frame_done_pending = true;
            },
        }
    }

    fn dispatchExtraFrameDone(self: *Backend, extra: *ExtraSurface) void {
        if (!extra.frame_done_pending) return;
        extra.frame_done_pending = false;
        if (self.frame_handler) |handler| handler(self.frame_context.?);
    }

    fn allConfigured(self: *const Backend) bool {
        if (!self.closed and !self.configured) return false;
        for (self.extra_surfaces.items) |*extra| {
            if (!extra.closed and !extra.configured) return false;
        }
        return true;
    }

    fn allClosed(self: *const Backend) bool {
        if (!self.closed) return false;
        for (self.extra_surfaces.items) |*extra| {
            if (!extra.closed) return false;
        }
        return true;
    }

    /// Returns the pixel region that must be re-rasterized, or null when a
    /// full redraw is required. Partial redraw needs the previous frame's
    /// content: either the acquired buffer already holds it, or it is
    /// copied over from the buffer that does.
    fn partialDamageClip(self: *Backend, frame: keywork.RenderBackend.Frame, buffer: *Buffer, width: u31, height: u31) ?TextRenderer.PixelClip {
        if (frame.damage.len != 1) return null;
        const clip = TextRenderer.PixelClip.fromRect(frame.damage[0], self.scale);
        if (clip.x0 <= 0 and clip.y0 <= 0 and clip.x1 >= width and clip.y1 >= height) return null;

        const last = self.last_rendered orelse return null;
        if (last == buffer) return clip;
        if (last.width != width or last.height != height) return null;
        @memcpy(buffer.pixels(), last.pixels());
        return clip;
    }

    fn acquireBuffer(self: *Backend, width: u31, height: u31) !*Buffer {
        var index: usize = 0;
        while (index < self.buffers.items.len) {
            const buffer = self.buffers.items[index];
            if (buffer.busy) {
                index += 1;
                continue;
            }
            if (buffer.width == width and buffer.height == height) return buffer;
            if (self.last_rendered == buffer) self.last_rendered = null;
            buffer.destroy(self.allocator);
            _ = self.buffers.swapRemove(index);
        }

        const buffer = try Buffer.create(self.allocator, self.shm, width, height);
        errdefer buffer.destroy(self.allocator);
        try self.buffers.append(self.allocator, buffer);
        return buffer;
    }

    fn acquireExtraBuffer(self: *Backend, extra: *ExtraSurface, width: u31, height: u31) !*Buffer {
        var index: usize = 0;
        while (index < extra.buffers.items.len) {
            const buffer = extra.buffers.items[index];
            if (buffer.busy) {
                index += 1;
                continue;
            }
            if (buffer.width == width and buffer.height == height) return buffer;
            if (extra.last_rendered == buffer) extra.last_rendered = null;
            buffer.destroy(self.allocator);
            _ = extra.buffers.swapRemove(index);
        }

        const buffer = try Buffer.create(self.allocator, self.shm, width, height);
        errdefer buffer.destroy(self.allocator);
        try extra.buffers.append(self.allocator, buffer);
        return buffer;
    }

    fn createShellRole(
        surface: *wl.Surface,
        output: ?*wl.Output,
        wm_base: ?*xdg.WmBase,
        layer_shell: ?*zwlr.LayerShellV1,
        options: Options,
    ) !ShellRole {
        if (options.layer_shell) |layer_options| {
            const shell = layer_shell orelse return error.NoLayerShell;
            const layer_surface = try shell.getLayerSurface(surface, output, layer(layer_options.layer), layer_options.namespace);
            errdefer layer_surface.destroy();
            layer_surface.setSize(options.width, options.height);
            layer_surface.setAnchor(anchor(layer_options.anchors));
            layer_surface.setExclusiveZone(layer_options.exclusive_zone);
            layer_surface.setMargin(
                layer_options.margin.top,
                layer_options.margin.right,
                layer_options.margin.bottom,
                layer_options.margin.left,
            );
            layer_surface.setKeyboardInteractivity(keyboardInteractivity(layer_options.keyboard_interactivity));
            return .{ .layer = .{ .surface = layer_surface } };
        }

        const base = wm_base orelse return error.NoXdgWmBase;
        const xdg_surface = try base.getXdgSurface(surface);
        errdefer xdg_surface.destroy();
        const toplevel = try xdg_surface.getToplevel();
        errdefer toplevel.destroy();
        toplevel.setAppId(options.app_id);
        toplevel.setTitle(options.title);
        return .{ .xdg = .{ .surface = xdg_surface, .toplevel = toplevel } };
    }

    fn createExtraSurface(
        allocator: std.mem.Allocator,
        compositor: *wl.Compositor,
        output: *wl.Output,
        wm_base: ?*xdg.WmBase,
        layer_shell: ?*zwlr.LayerShellV1,
        viewporter: ?*wp.Viewporter,
        fractional_scale_manager: ?*wp.FractionalScaleManagerV1,
        options: Options,
    ) !ExtraSurface {
        _ = allocator;
        const surface = try compositor.createSurface();
        errdefer surface.destroy();
        const shell_role = try createShellRole(surface, output, wm_base, layer_shell, options);
        errdefer shell_role.destroy();
        const viewport = if (viewporter) |manager| try manager.getViewport(surface) else null;
        errdefer if (viewport) |surface_viewport| surface_viewport.destroy();
        const fractional_scale = if (fractional_scale_manager) |manager| try manager.getFractionalScale(surface) else null;
        errdefer if (fractional_scale) |surface_scale| surface_scale.destroy();

        return .{
            .surface = surface,
            .viewport = viewport,
            .fractional_scale = fractional_scale,
            .shell_role = shell_role,
            .width = options.width,
            .height = options.height,
        };
    }

    fn layer(value: keywork.LayerShellOptions.Layer) zwlr.LayerShellV1.Layer {
        return switch (value) {
            .background => .background,
            .bottom => .bottom,
            .top => .top,
            .overlay => .overlay,
        };
    }

    fn anchor(value: keywork.LayerShellOptions.AnchorSet) zwlr.LayerSurfaceV1.Anchor {
        return .{
            .top = value.top,
            .bottom = value.bottom,
            .left = value.left,
            .right = value.right,
        };
    }

    fn keyboardInteractivity(value: keywork.LayerShellOptions.KeyboardInteractivity) zwlr.LayerSurfaceV1.KeyboardInteractivity {
        return switch (value) {
            .none => .none,
            .exclusive => .exclusive,
            .on_demand => .on_demand,
        };
    }

    fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, globals: *Globals) void {
        switch (event) {
            .global => |global| {
                if (std.mem.orderZ(u8, global.interface, wl.Compositor.interface.name) == .eq) {
                    globals.compositor = registry.bind(global.name, wl.Compositor, 4) catch return;
                } else if (std.mem.orderZ(u8, global.interface, wl.Shm.interface.name) == .eq) {
                    globals.shm = registry.bind(global.name, wl.Shm, 1) catch return;
                } else if (std.mem.orderZ(u8, global.interface, xdg.WmBase.interface.name) == .eq) {
                    globals.wm_base = registry.bind(global.name, xdg.WmBase, @min(global.version, 6)) catch return;
                } else if (std.mem.orderZ(u8, global.interface, zwlr.LayerShellV1.interface.name) == .eq) {
                    globals.layer_shell = registry.bind(global.name, zwlr.LayerShellV1, @min(global.version, 5)) catch return;
                } else if (std.mem.orderZ(u8, global.interface, wp.Viewporter.interface.name) == .eq) {
                    globals.viewporter = registry.bind(global.name, wp.Viewporter, 1) catch return;
                } else if (std.mem.orderZ(u8, global.interface, wp.FractionalScaleManagerV1.interface.name) == .eq) {
                    globals.fractional_scale_manager = registry.bind(global.name, wp.FractionalScaleManagerV1, 1) catch return;
                } else if (std.mem.orderZ(u8, global.interface, wp.CursorShapeManagerV1.interface.name) == .eq) {
                    globals.cursor_shape_manager = registry.bind(global.name, wp.CursorShapeManagerV1, 1) catch return;
                } else if (std.mem.orderZ(u8, global.interface, wl.Seat.interface.name) == .eq) {
                    globals.seat = registry.bind(global.name, wl.Seat, @min(global.version, 8)) catch return;
                } else if (std.mem.orderZ(u8, global.interface, wl.Output.interface.name) == .eq) {
                    const output = registry.bind(global.name, wl.Output, @min(global.version, 4)) catch return;
                    globals.outputs.append(globals.allocator, .{ .global_name = global.name, .output = output }) catch {
                        output.release();
                        return;
                    };
                }
            },
            .global_remove => {},
        }
    }

    fn releaseOutputs(allocator: std.mem.Allocator, outputs: *std.ArrayList(OutputRef)) void {
        for (outputs.items) |output_ref| output_ref.output.release();
        outputs.deinit(allocator);
    }

    fn fractionalScaleListener(_: *wp.FractionalScaleV1, event: wp.FractionalScaleV1.Event, self: *Backend) void {
        switch (event) {
            .preferred_scale => |preferred| {
                if (preferred.scale == 0) return;
                const scale = @as(f32, @floatFromInt(preferred.scale)) / 120.0;
                if (scale == self.scale) return;
                self.scale = scale;
                self.scale_changed = true;
                log.info("fractional scale {d}", .{scale});
            },
        }
    }

    fn wmBaseListener(wm_base: *xdg.WmBase, event: xdg.WmBase.Event, _: *Backend) void {
        switch (event) {
            .ping => |ping| wm_base.pong(ping.serial),
        }
    }

    fn xdgSurfaceListener(xdg_surface: *xdg.Surface, event: xdg.Surface.Event, self: *Backend) void {
        switch (event) {
            .configure => |configure| {
                xdg_surface.ackConfigure(configure.serial);
                self.configured = true;
                self.queueRepaint();
            },
        }
    }

    fn layerSurfaceListener(layer_surface: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, self: *Backend) void {
        switch (event) {
            .configure => |configure| {
                layer_surface.ackConfigure(configure.serial);
                if (configure.width > 0) self.width = @intCast(configure.width);
                if (configure.height > 0) self.height = @intCast(configure.height);
                self.configured = true;
                self.queueRepaint();
            },
            .closed => self.closed = true,
        }
    }

    fn extraLayerSurfaceListener(layer_surface: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, extra: *ExtraSurface) void {
        switch (event) {
            .configure => |configure| {
                layer_surface.ackConfigure(configure.serial);
                if (configure.width > 0) extra.width = @intCast(configure.width);
                if (configure.height > 0) extra.height = @intCast(configure.height);
                extra.configured = true;
                extra.repaint_pending = true;
            },
            .closed => extra.closed = true,
        }
    }

    fn extraFractionalScaleListener(_: *wp.FractionalScaleV1, event: wp.FractionalScaleV1.Event, extra: *ExtraSurface) void {
        switch (event) {
            .preferred_scale => |preferred| {
                if (preferred.scale == 0) return;
                const scale = @as(f32, @floatFromInt(preferred.scale)) / 120.0;
                if (scale == extra.scale) return;
                extra.scale = scale;
                extra.scale_changed = true;
                log.info("fractional scale {d}", .{scale});
            },
        }
    }

    fn toplevelListener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, self: *Backend) void {
        switch (event) {
            .configure => |configure| {
                if (configure.width > 0) self.width = @intCast(configure.width);
                if (configure.height > 0) self.height = @intCast(configure.height);
            },
            .close => self.closed = true,
            .configure_bounds => {},
            .wm_capabilities => {},
        }
    }
};

const Buffer = struct {
    wl_buffer: *wl.Buffer,
    data: []align(std.heap.page_size_min) u8,
    width: u31,
    height: u31,
    busy: bool,

    fn create(allocator: std.mem.Allocator, shm: *wl.Shm, width: u31, height: u31) !*Buffer {
        std.debug.assert(width > 0 and height > 0);
        const stride: u31 = width * 4;
        const size: u31 = stride * height;

        const fd = try posix.memfd_create("keywork-shm", linux.MFD.CLOEXEC);
        defer _ = linux.close(fd);
        if (linux.errno(linux.ftruncate(fd, size)) != .SUCCESS) return error.ShmFailed;

        const data = try posix.mmap(
            null,
            size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        errdefer posix.munmap(data);

        const pool = try shm.createPool(fd, size);
        defer pool.destroy();
        const wl_buffer = try pool.createBuffer(0, width, height, stride, .argb8888);
        errdefer wl_buffer.destroy();

        const self = try allocator.create(Buffer);
        self.* = .{
            .wl_buffer = wl_buffer,
            .data = data,
            .width = width,
            .height = height,
            .busy = false,
        };
        wl_buffer.setListener(*Buffer, bufferListener, self);
        return self;
    }

    fn destroy(self: *Buffer, allocator: std.mem.Allocator) void {
        self.wl_buffer.destroy();
        posix.munmap(self.data);
        allocator.destroy(self);
    }

    fn pixels(self: *Buffer) []u32 {
        return @alignCast(std.mem.bytesAsSlice(u32, self.data));
    }

    fn bufferListener(_: *wl.Buffer, event: wl.Buffer.Event, self: *Buffer) void {
        switch (event) {
            .release => self.busy = false,
        }
    }
};

fn rasterize(
    renderer: *TextRenderer,
    pixels: []u32,
    width: u31,
    height: u31,
    scale: f32,
    commands: []const keywork.PaintCommand,
    base_clip: ?TextRenderer.PixelClip,
) !void {
    if (base_clip) |clip| {
        clearRegion(pixels, width, height, clip);
    } else {
        @memset(pixels, @as(u32, @bitCast(keywork.colors.transparent)));
    }
    var clip: ?TextRenderer.PixelClip = base_clip;
    for (commands) |command| {
        switch (command) {
            .fill_rect => |fill| fillRect(pixels, width, height, scale, fill.rect, fill.color, clip),
            .text => |text| try renderer.render(pixels, width, height, scale, text, clip),
            .alpha_image => |image| alphaImage(pixels, width, height, scale, image, clip),
            .color_image => |image| colorImage(pixels, width, height, scale, image, clip),
            .set_clip => |rect| clip = combineClips(base_clip, rect, scale),
        }
    }
}

fn combineClips(base: ?TextRenderer.PixelClip, rect: ?keywork.Rect, scale: f32) ?TextRenderer.PixelClip {
    const converted: ?TextRenderer.PixelClip = if (rect) |value| TextRenderer.PixelClip.fromRect(value, scale) else null;
    const base_clip = base orelse return converted;
    const other = converted orelse return base_clip;
    return .{
        .x0 = @max(base_clip.x0, other.x0),
        .y0 = @max(base_clip.y0, other.y0),
        .x1 = @min(base_clip.x1, other.x1),
        .y1 = @min(base_clip.y1, other.y1),
    };
}

fn clearRegion(pixels: []u32, width: u31, height: u31, clip: TextRenderer.PixelClip) void {
    const value: u32 = @bitCast(keywork.colors.transparent);
    const x0 = clampClip(clip.x0, width);
    const x1 = clampClip(clip.x1, width);
    const y0 = clampClip(clip.y0, height);
    const y1 = clampClip(clip.y1, height);
    if (x0 >= x1) return;
    var y = y0;
    while (y < y1) : (y += 1) {
        @memset(pixels[y * width ..][x0..x1], value);
    }
}

fn fillRect(pixels: []u32, width: u31, height: u31, scale: f32, rect: keywork.Rect, color: keywork.Color, clip: ?TextRenderer.PixelClip) void {
    var x0 = clampPixel(@floor(rect.x * scale), width);
    var y0 = clampPixel(@floor(rect.y * scale), height);
    var x1 = clampPixel(@ceil((rect.x + rect.width) * scale), width);
    var y1 = clampPixel(@ceil((rect.y + rect.height) * scale), height);
    if (clip) |c| {
        x0 = @max(x0, clampClip(c.x0, width));
        y0 = @max(y0, clampClip(c.y0, height));
        x1 = @min(x1, clampClip(c.x1, width));
        y1 = @min(y1, clampClip(c.y1, height));
    }
    if (x0 >= x1 or y0 >= y1) return;

    const value: u32 = @bitCast(color);
    var y = y0;
    while (y < y1) : (y += 1) {
        const row = pixels[y * width ..][0..width];
        @memset(row[x0..x1], value);
    }
}

fn alphaImage(
    pixels: []u32,
    width: u31,
    height: u31,
    scale: f32,
    image: keywork.PaintCommand.AlphaImage,
    clip: ?TextRenderer.PixelClip,
) void {
    if (image.width == 0 or image.height == 0) return;
    const image_width: usize = @intCast(image.width);
    const image_height: usize = @intCast(image.height);
    const dst_x0 = clampPixel(@floor(image.rect.x * scale), width);
    const dst_y0 = clampPixel(@floor(image.rect.y * scale), height);
    var start_x = dst_x0;
    var start_y = dst_y0;
    var dst_x1 = @min(dst_x0 + image_width, width);
    var dst_y1 = @min(dst_y0 + image_height, height);
    if (clip) |c| {
        start_x = @max(start_x, clampClip(c.x0, width));
        start_y = @max(start_y, clampClip(c.y0, height));
        dst_x1 = @min(dst_x1, clampClip(c.x1, width));
        dst_y1 = @min(dst_y1, clampClip(c.y1, height));
    }
    if (start_x >= dst_x1 or start_y >= dst_y1) return;

    var y = start_y;
    while (y < dst_y1) : (y += 1) {
        const row = y - dst_y0;
        var x = start_x;
        while (x < dst_x1) : (x += 1) {
            const column = x - dst_x0;
            const coverage = image.alpha[row * image_width + column];
            if (coverage == 0) continue;
            blendPixel(pixels, width, x, y, image.color, coverage);
        }
    }
}

fn colorImage(
    pixels: []u32,
    width: u31,
    height: u31,
    scale: f32,
    image: keywork.PaintCommand.ColorImage,
    clip: ?TextRenderer.PixelClip,
) void {
    if (image.width == 0 or image.height == 0) return;
    const image_width: usize = @intCast(image.width);
    const image_height: usize = @intCast(image.height);
    const dst_x0 = clampPixel(@floor(image.rect.x * scale), width);
    const dst_y0 = clampPixel(@floor(image.rect.y * scale), height);
    var start_x = dst_x0;
    var start_y = dst_y0;
    var dst_x1 = @min(dst_x0 + image_width, width);
    var dst_y1 = @min(dst_y0 + image_height, height);
    if (clip) |c| {
        start_x = @max(start_x, clampClip(c.x0, width));
        start_y = @max(start_y, clampClip(c.y0, height));
        dst_x1 = @min(dst_x1, clampClip(c.x1, width));
        dst_y1 = @min(dst_y1, clampClip(c.y1, height));
    }
    if (start_x >= dst_x1 or start_y >= dst_y1) return;

    var y = start_y;
    while (y < dst_y1) : (y += 1) {
        const row = y - dst_y0;
        var x = start_x;
        while (x < dst_x1) : (x += 1) {
            const column = x - dst_x0;
            const source = image.pixels[row * image_width + column];
            if (source.a == 0) continue;
            blendPixel(pixels, width, x, y, source, 255);
        }
    }
}

fn clampClip(value: i32, max_value: u31) usize {
    if (value <= 0) return 0;
    return @min(@as(usize, @intCast(value)), max_value);
}

fn blendPixel(pixels: []u32, width: u31, x: usize, y: usize, color: keywork.Color, coverage: u8) void {
    const index = y * width + x;
    const dst: keywork.Color = @bitCast(pixels[index]);
    const src_a = (@as(u32, color.a) * coverage + 127) / 255;
    const inv_a = 255 - src_a;

    const out: keywork.Color = .{
        .a = @intCast(src_a + (@as(u32, dst.a) * inv_a + 127) / 255),
        .r = @intCast((@as(u32, color.r) * src_a + @as(u32, dst.r) * inv_a + 127) / 255),
        .g = @intCast((@as(u32, color.g) * src_a + @as(u32, dst.g) * inv_a + 127) / 255),
        .b = @intCast((@as(u32, color.b) * src_a + @as(u32, dst.b) * inv_a + 127) / 255),
    };
    pixels[index] = @bitCast(out);
}

fn clampPixel(value: f32, max_value: u31) usize {
    if (value <= 0) return 0;
    const limit: f32 = @floatFromInt(max_value);
    if (value >= limit) return max_value;
    return @intFromFloat(value);
}

fn frameLogicalWidth(frame: keywork.RenderBackend.Frame, fallback: u31) !u31 {
    const value = if (frame.size.width > 0) frame.size.width else @as(f32, @floatFromInt(fallback));
    return positiveU31(value);
}

fn frameLogicalHeight(frame: keywork.RenderBackend.Frame, fallback: u31) !u31 {
    const value = if (frame.size.height > 0) frame.size.height else @as(f32, @floatFromInt(fallback));
    return positiveU31(value);
}

fn scaledFrameDimension(logical_dimension: u31, scale: f32) !u31 {
    if (!std.math.isFinite(scale) or scale <= 0) return error.InvalidScale;
    const value = @as(f32, @floatFromInt(logical_dimension)) * scale;
    return positiveU31(value);
}

fn positiveU31(value: f32) !u31 {
    if (!std.math.isFinite(value) or value <= 0) return error.InvalidFrameSize;
    const rounded = @ceil(value);
    if (rounded > @as(f32, @floatFromInt(std.math.maxInt(u31)))) return error.InvalidFrameSize;
    return @intFromFloat(rounded);
}
