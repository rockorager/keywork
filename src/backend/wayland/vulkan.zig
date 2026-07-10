//! Experimental Wayland/Vulkan render backend.

const std = @import("std");
const event_loop = @import("../../linux/event_loop.zig");
const keywork = @import("../../ui.zig");
const VulkanRenderer = @import("vulkan/renderer.zig").Renderer;
const WaylandInput = @import("input.zig");
const wayland_options = @import("options.zig");
const window = @import("window.zig");
const wayland = @import("wayland");

const wl = wayland.client.wl;

pub const Backend = struct {
    allocator: std.mem.Allocator,
    connection: *window.Connection,
    input: WaylandInput,
    windows: std.ArrayList(*Window),

    pub const PointerButtonHandler = WaylandInput.PointerButtonHandler;
    pub const PointerMoveHandler = WaylandInput.PointerMoveHandler;
    pub const CursorShapeHandler = WaylandInput.CursorShapeHandler;
    pub const KeyHandler = WaylandInput.KeyHandler;
    pub const ScrollHandler = WaylandInput.ScrollHandler;
    pub const RepaintHandler = *const fn (ctx: *anyopaque, size: keywork.Size) void;
    pub const FrameHandler = *const fn (ctx: *anyopaque) void;

    pub const WindowOptions = struct {
        title: [:0]const u8 = "Keywork Vulkan",
        app_id: [:0]const u8 = "dev.keywork.Keywork",
        width: u31 = 640,
        height: u31 = 480,
        layer_shell: ?wayland_options.LayerShellOptions = null,
        /// Output a layer-shell surface is placed on; null lets the
        /// compositor choose.
        output: ?*wl.Output = null,
    };

    pub fn create(allocator: std.mem.Allocator) !*Backend {
        const connection = try window.Connection.init(allocator, .{ .outputs = true });
        errdefer connection.deinit();

        const seat = connection.takeSeat();
        var input = WaylandInput.init(allocator, seat, connection.seatCapabilities(), connection.cursor_shape_manager) catch |err| {
            if (seat) |wl_seat| wl_seat.release();
            return err;
        };
        errdefer input.deinit();

        const self = try allocator.create(Backend);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .connection = connection,
            .input = input,
            .windows = .empty,
        };

        window.installWmBaseListener(self.connection.wm_base);
        // Seat listener stays on the connection; forward capability changes
        // into input once it lives at its final address.
        self.connection.setSeatCapabilitiesHandler(&self.input, WaylandInput.seatCapabilitiesCallback);
        self.input.attachListeners();
        return self;
    }

    pub fn destroy(self: *Backend) void {
        while (self.windows.items.len > 0) {
            self.destroyWindow(self.windows.items[self.windows.items.len - 1]);
        }
        self.windows.deinit(self.allocator);
        self.input.deinit();
        self.connection.deinit();
        self.allocator.destroy(self);
    }

    pub fn createWindow(self: *Backend, options: WindowOptions) !*Window {
        var protocol = try window.Surface.init(self.connection, options.output, options);
        errdefer protocol.deinit();

        // Commit and flush now so the compositor prepares the initial
        // configure while the Vulkan device initializes below. Events
        // queue until the first dispatch.
        protocol.surface.commit();
        _ = self.connection.display.flush();

        var renderer = try VulkanRenderer.init(self.allocator, self.connection.display, protocol.surface);
        errdefer renderer.deinit();

        const win = try self.allocator.create(Window);
        errdefer self.allocator.destroy(win);
        win.* = .{
            .backend = self,
            .protocol = protocol,
            .renderer = renderer,
            .input_target = .{ .surface = protocol.surface },
        };
        try self.windows.append(self.allocator, win);
        errdefer _ = self.windows.pop();
        try self.input.registerTarget(&win.input_target);

        // Listener contexts must point at the window's final storage.
        win.protocol.attachListeners();
        return win;
    }

    /// Creates a popup window anchored to `parent`. The popup grabs the
    /// seat when an input serial is available, so the compositor dismisses
    /// it (closing the window) when the user clicks elsewhere.
    pub fn createPopup(self: *Backend, parent: *Window, options: window.PopupOptions) !*Window {
        var protocol = try window.Surface.initPopup(self.connection, &parent.protocol, options);
        errdefer protocol.deinit();

        // The grab must precede the initial commit, so unlike createWindow
        // the renderer initializes before the surface is committed.
        var renderer = try VulkanRenderer.init(self.allocator, self.connection.display, protocol.surface);
        errdefer renderer.deinit();

        const win = try self.allocator.create(Window);
        errdefer self.allocator.destroy(win);
        win.* = .{
            .backend = self,
            .protocol = protocol,
            .renderer = renderer,
            .input_target = .{ .surface = protocol.surface },
        };
        try self.windows.append(self.allocator, win);
        errdefer _ = self.windows.pop();
        try self.input.registerTarget(&win.input_target);

        win.protocol.attachListeners();
        if (self.input.seat) |seat| {
            if (self.input.last_button_press_serial) |serial| win.protocol.grabPopup(seat, serial);
        }
        win.protocol.surface.commit();
        _ = self.connection.display.flush();
        return win;
    }

    pub fn destroyWindow(self: *Backend, win: *Window) void {
        self.input.unregisterTarget(&win.input_target);
        for (self.windows.items, 0..) |existing, index| {
            if (existing != win) continue;
            _ = self.windows.orderedRemove(index);
            break;
        }
        win.deinitResources();
        self.allocator.destroy(win);
    }

    pub fn setPopupKeyboardFocus(self: *Backend, win: *Window, focused: bool) void {
        win.protocol.setPopupKeyboardFocus(focused);
        _ = self.connection.display.flush();
    }

    pub fn repositionPopup(self: *Backend, win: *Window, options: window.PopupOptions, token: u32) !void {
        try win.protocol.repositionPopup(self.connection, options, token);
        _ = self.connection.display.flush();
    }

    pub fn outputCount(self: *const Backend) usize {
        return self.connection.outputs.items.len;
    }

    pub fn outputAt(self: *const Backend, index: usize) *wl.Output {
        return self.connection.outputs.items[index].output;
    }

    pub fn outputInfoAt(self: *const Backend, index: usize) window.OutputInfo {
        return self.connection.outputInfoAt(index);
    }

    pub fn findOutputByName(self: *const Backend, name: []const u8) ?*wl.Output {
        return self.connection.findOutputByName(name);
    }

    pub fn setOutputsChangedHandler(self: *Backend, ctx: *anyopaque, handler: *const fn (ctx: *anyopaque) void) void {
        self.connection.setOutputsChangedHandler(ctx, handler);
    }

    pub fn installEventTimers(self: *Backend, loop: *event_loop.EventLoop) !void {
        try self.input.installEventTimers(loop);
    }

    pub fn uninstallEventTimers(self: *Backend) void {
        self.input.uninstallEventTimers();
    }

    pub fn eventLoopFd(self: *Backend) i32 {
        return self.connection.display.getFd();
    }

    /// Dispatch until every window received its initial configure. Call
    /// after creating the initial set of windows and before rendering.
    pub fn waitForAllConfigured(self: *Backend) !void {
        while (!self.allConfigured() and !self.allClosed()) {
            if (self.connection.display.dispatch() != .SUCCESS) return error.DispatchFailed;
        }
        if (self.allClosed()) return error.WindowClosed;
        // Configure marks a repaint pending, but repaint handlers are not
        // installed yet; the caller paints the initial frame explicitly.
        for (self.windows.items) |win| _ = win.protocol.flushPending();
    }

    /// Dispatches until `win` receives its initial configure (or closes).
    /// Only the new window's pending protocol state is cleared; events
    /// dispatched for other windows stay queued for their handlers, so
    /// this is safe to call while other windows are live.
    pub fn waitForConfigured(self: *Backend, win: *Window) !void {
        while (!win.protocol.configured and !win.protocol.closed) {
            if (self.connection.display.dispatch() != .SUCCESS) return error.DispatchFailed;
        }
        if (win.protocol.closed) return error.WindowClosed;
        // Configure marked a repaint pending, but the window's handlers
        // are not installed yet; the caller paints the initial frame.
        _ = win.protocol.flushPending();
    }

    pub fn eventLoopPrepare(ctx: *anyopaque) !event_loop.EventLoop.WaylandPrepare {
        const self: *Backend = @ptrCast(@alignCast(ctx));
        return window.eventLoopPrepare(self.connection.display, self, flushPendingOpaque);
    }

    pub fn eventLoopFinish(ctx: *anyopaque, events: u32) !bool {
        const self: *Backend = @ptrCast(@alignCast(ctx));
        return window.eventLoopFinish(self.connection.display, self, flushPendingOpaque, allClosedOpaque, events);
    }

    /// Like `eventLoopFinish`, but never stops the loop when the window
    /// list is empty or all windows closed. Used by window-managed apps
    /// where the manager decides quit semantics: zero live windows is a
    /// valid state (for example a shell waiting for output hotplug).
    pub fn eventLoopFinishKeepAlive(ctx: *anyopaque, events: u32) !bool {
        const self: *Backend = @ptrCast(@alignCast(ctx));
        return window.eventLoopFinish(self.connection.display, self, flushPendingOpaque, neverClosedOpaque, events);
    }

    fn flushPendingOpaque(ctx: *anyopaque) void {
        const self: *Backend = @ptrCast(@alignCast(ctx));
        self.flushPending();
    }

    fn allClosedOpaque(ctx: *anyopaque) bool {
        const self: *Backend = @ptrCast(@alignCast(ctx));
        return self.allClosed();
    }

    fn neverClosedOpaque(_: *anyopaque) bool {
        return false;
    }

    fn flushPending(self: *Backend) void {
        for (self.windows.items) |win| win.flushPending();
    }

    fn allConfigured(self: *const Backend) bool {
        for (self.windows.items) |win| {
            if (!win.protocol.closed and !win.protocol.configured) return false;
        }
        return true;
    }

    fn allClosed(self: *const Backend) bool {
        for (self.windows.items) |win| {
            if (!win.protocol.closed) return false;
        }
        return true;
    }

    /// One Wayland surface with its own Vulkan renderer and input target.
    /// Created and destroyed through the owning `Backend`; all windows
    /// share one connection and seat.
    pub const Window = struct {
        backend: *Backend,
        protocol: window.Surface,
        renderer: VulkanRenderer,
        input_target: WaylandInput.Target,
        repaint_handler: ?RepaintHandler = null,
        repaint_context: ?*anyopaque = null,
        frame_handler: ?FrameHandler = null,
        frame_context: ?*anyopaque = null,

        pub fn renderBackend(self: *Window) keywork.RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = renderScale, .text_metrics = textMetrics } };
        }

        pub fn setPointerButtonHandler(self: *Window, context: *anyopaque, handler: PointerButtonHandler) void {
            self.input_target.setPointerButtonHandler(context, handler);
        }

        pub fn setPointerMoveHandler(self: *Window, context: *anyopaque, handler: PointerMoveHandler) void {
            self.input_target.setPointerMoveHandler(context, handler);
        }

        pub fn setCursorShapeHandler(self: *Window, context: *anyopaque, handler: CursorShapeHandler) void {
            self.input_target.setCursorShapeHandler(context, handler);
        }

        pub fn setKeyHandler(self: *Window, context: *anyopaque, handler: KeyHandler) void {
            self.input_target.setKeyHandler(context, handler);
        }

        pub fn setScrollHandler(self: *Window, context: *anyopaque, handler: ScrollHandler) void {
            self.input_target.setScrollHandler(context, handler);
        }

        pub fn setRepaintHandler(self: *Window, context: *anyopaque, handler: RepaintHandler) void {
            self.repaint_context = context;
            self.repaint_handler = handler;
        }

        pub fn setFrameHandler(self: *Window, context: *anyopaque, handler: FrameHandler) void {
            self.frame_context = context;
            self.frame_handler = handler;
        }

        pub fn currentSize(self: *const Window) keywork.Size {
            return self.protocol.currentSize();
        }

        /// Whether the compositor reports this toplevel as suspended (not
        /// visible), so callers can pause presentation. Layer-shell
        /// surfaces never suspend.
        pub fn suspendedOpaque(ctx: *anyopaque) bool {
            const self: *Window = @ptrCast(@alignCast(ctx));
            return self.protocol.suspended;
        }

        fn deinitResources(self: *Window) void {
            self.renderer.deinit();
            self.protocol.deinit();
        }

        fn flushPending(self: *Window) void {
            const pending = self.protocol.flushPending();
            if (pending.repaint) {
                if (self.repaint_handler) |handler| handler(self.repaint_context.?, self.currentSize());
            }
            if (pending.frame_done) {
                if (self.frame_handler) |handler| handler(self.frame_context.?);
            }
        }

        fn present(ptr: *anyopaque, frame: keywork.RenderBackend.Frame) !bool {
            const self: *Window = @ptrCast(@alignCast(ptr));
            const protocol = &self.protocol;
            while (!protocol.configured and !protocol.closed) {
                if (self.backend.connection.display.dispatch() != .SUCCESS) return error.DispatchFailed;
            }
            if (protocol.closed) return error.WindowClosed;

            const logical_width = try window.frameLogicalWidth(frame, protocol.width);
            const logical_height = try window.frameLogicalHeight(frame, protocol.height);
            const width = try window.scaledFrameDimension(logical_width, protocol.scale);
            const height = try window.scaledFrameDimension(logical_height, protocol.scale);
            protocol.surface.setBufferScale(1);
            if (protocol.viewport) |viewport| viewport.setDestination(logical_width, logical_height);
            const pending = try self.renderer.present(frame.display_list, protocol.scale, width, height);
            if (!pending) return false;
            try protocol.armFrameCallback();
            protocol.surface.commit();
            _ = self.backend.connection.display.flush();
            return true;
        }

        fn measureText(ptr: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !keywork.Size {
            const self: *Window = @ptrCast(@alignCast(ptr));
            return self.renderer.measureText(self.protocol.scale, value, style);
        }

        fn textMetrics(ptr: *anyopaque, font_size: f32) !keywork.TextMetrics {
            const self: *Window = @ptrCast(@alignCast(ptr));
            return self.renderer.textMetrics(self.protocol.scale, font_size);
        }

        fn renderScale(ptr: *anyopaque) f32 {
            const self: *Window = @ptrCast(@alignCast(ptr));
            return self.protocol.scale;
        }
    };
};
