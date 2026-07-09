//! Experimental Wayland/Vulkan render backend.

const std = @import("std");
const event_loop = @import("../../linux/event_loop.zig");
const keywork = @import("../../ui.zig");
const VulkanRenderer = @import("vulkan/renderer.zig").Renderer;
const WaylandInput = @import("input.zig");
const wayland_options = @import("options.zig");
const window = @import("window.zig");

pub const Backend = struct {
    allocator: std.mem.Allocator,
    connection: *window.Connection,
    input: WaylandInput,
    protocol: window.Surface,
    renderer: VulkanRenderer,
    repaint_handler: ?RepaintHandler,
    repaint_context: ?*anyopaque,
    frame_handler: ?FrameHandler,
    frame_context: ?*anyopaque,

    pub const PointerButtonHandler = WaylandInput.PointerButtonHandler;
    pub const PointerMoveHandler = WaylandInput.PointerMoveHandler;
    pub const CursorShapeHandler = WaylandInput.CursorShapeHandler;
    pub const KeyHandler = WaylandInput.KeyHandler;
    pub const ScrollHandler = WaylandInput.ScrollHandler;
    pub const RepaintHandler = *const fn (ctx: *anyopaque, size: keywork.Size) void;
    pub const FrameHandler = *const fn (ctx: *anyopaque) void;

    pub const Options = struct {
        title: [:0]const u8 = "Keywork Vulkan",
        app_id: [:0]const u8 = "dev.keywork.Keywork",
        width: u31 = 640,
        height: u31 = 480,
        layer_shell: ?wayland_options.LayerShellOptions = null,
    };

    pub fn create(allocator: std.mem.Allocator, options: Options) !*Backend {
        if (options.layer_shell) |layer_options| {
            if (layer_options.output == .all) return error.UnsupportedLayerShellAllOutputs;
        }

        const connection = try window.Connection.init(allocator, .{});
        errdefer connection.deinit();
        var protocol = try window.Surface.init(connection, null, options);
        errdefer protocol.deinit();

        const seat = connection.takeSeat();
        var input = WaylandInput.init(protocol.surface, seat, connection.cursor_shape_manager) catch |err| {
            if (seat) |wl_seat| wl_seat.release();
            return err;
        };
        errdefer input.deinit();

        var renderer = try VulkanRenderer.init(allocator, connection.display, protocol.surface);
        errdefer renderer.deinit();

        const self = try allocator.create(Backend);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .connection = connection,
            .input = input,
            .protocol = protocol,
            .renderer = renderer,
            .repaint_handler = null,
            .repaint_context = null,
            .frame_handler = null,
            .frame_context = null,
        };

        window.installWmBaseListener(self.connection.wm_base);
        self.protocol.attachListeners();
        self.input.attachListeners();
        self.protocol.surface.commit();
        return self;
    }

    pub fn destroy(self: *Backend) void {
        self.renderer.deinit();
        self.input.deinit();
        self.protocol.deinit();
        self.connection.deinit();
        self.allocator.destroy(self);
    }

    pub fn renderBackend(self: *Backend) keywork.RenderBackend {
        return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = renderScale } };
    }

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

    pub fn eventLoopFd(self: *Backend) i32 {
        return self.connection.display.getFd();
    }

    pub fn waitForInitialConfigure(self: *Backend) !keywork.Size {
        while (!self.protocol.configured and !self.protocol.closed) {
            if (self.connection.display.dispatch() != .SUCCESS) return error.DispatchFailed;
        }
        if (self.protocol.closed) return error.WindowClosed;
        self.flushPending();
        return self.currentSize();
    }

    pub fn eventLoopPrepare(ctx: *anyopaque) !event_loop.EventLoop.WaylandPrepare {
        const self: *Backend = @ptrCast(@alignCast(ctx));
        return window.eventLoopPrepare(self.connection.display, self, flushPendingOpaque);
    }

    pub fn eventLoopFinish(ctx: *anyopaque, events: u32) !bool {
        const self: *Backend = @ptrCast(@alignCast(ctx));
        return window.eventLoopFinish(self.connection.display, self, flushPendingOpaque, isClosedOpaque, events);
    }

    fn flushPendingOpaque(ctx: *anyopaque) void {
        const self: *Backend = @ptrCast(@alignCast(ctx));
        self.flushPending();
    }

    fn isClosedOpaque(ctx: *anyopaque) bool {
        const self: *Backend = @ptrCast(@alignCast(ctx));
        return self.protocol.closed;
    }

    /// Whether the toplevel is suspended (not visible), so callers can
    /// pause presentation.
    pub fn suspendedOpaque(ctx: *anyopaque) bool {
        const self: *Backend = @ptrCast(@alignCast(ctx));
        return self.protocol.suspended;
    }

    fn present(ptr: *anyopaque, frame: keywork.RenderBackend.Frame) !bool {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        const protocol = &self.protocol;
        while (!protocol.configured and !protocol.closed) {
            if (self.connection.display.dispatch() != .SUCCESS) return error.DispatchFailed;
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
        _ = self.connection.display.flush();
        return true;
    }

    fn measureText(ptr: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !keywork.Size {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        return self.renderer.measureText(self.protocol.scale, value, style);
    }

    fn renderScale(ptr: *anyopaque) f32 {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        return self.protocol.scale;
    }

    fn notifyRepaint(self: *Backend) void {
        if (self.repaint_handler) |handler| handler(self.repaint_context.?, self.currentSize());
    }

    fn currentSize(self: *const Backend) keywork.Size {
        return self.protocol.currentSize();
    }

    fn flushPending(self: *Backend) void {
        const pending = self.protocol.flushPending();
        if (pending.repaint) self.notifyRepaint();
        if (pending.frame_done) if (self.frame_handler) |handler| handler(self.frame_context.?);
    }
};
