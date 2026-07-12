//! Renderer-independent Wayland backend lifecycle.

const std = @import("std");
const event_loop = @import("../../linux/event_loop.zig");
const keywork = @import("../../ui.zig");
const WaylandInput = @import("input.zig");
const data_device = @import("data_device.zig");
const wayland_options = @import("options.zig");
const window = @import("window.zig");
const wayland = @import("wayland");

const wl = wayland.client.wl;

pub fn Backend(comptime RendererAdapter: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        connection: *window.Connection,
        input: WaylandInput,
        renderer: RendererAdapter.BackendResources,
        windows: std.ArrayList(*Window),
        clipboard: ?*data_device.Clipboard = null,

        pub const PointerButtonHandler = WaylandInput.PointerButtonHandler;
        pub const PointerMoveHandler = WaylandInput.PointerMoveHandler;
        pub const CursorShapeHandler = WaylandInput.CursorShapeHandler;
        pub const KeyHandler = WaylandInput.KeyHandler;
        pub const ScrollHandler = WaylandInput.ScrollHandler;
        pub const RepaintHandler = *const fn (ctx: *anyopaque, size: keywork.Size) void;
        pub const FrameHandler = *const fn (ctx: *anyopaque) void;

        pub const WindowOptions = struct {
            title: [:0]const u8 = RendererAdapter.default_title,
            app_id: [:0]const u8 = "dev.keywork.Keywork",
            width: u31 = 640,
            height: u31 = 480,
            decorations: wayland_options.Decorations = .server,
            layer_shell: ?wayland_options.LayerShellOptions = null,
            output: ?*wl.Output = null,
        };

        pub fn create(allocator: std.mem.Allocator) !*Self {
            const connection = try window.Connection.init(allocator, RendererAdapter.connection_options);
            errdefer connection.deinit();
            var renderer = try RendererAdapter.initBackend(allocator, connection);
            errdefer RendererAdapter.deinitBackend(&renderer);
            const seat = connection.takeSeat();
            var input = WaylandInput.init(allocator, seat, connection.seatCapabilities(), connection.cursor_shape_manager, connection.compositor, connection.shm) catch |err| {
                if (seat) |wl_seat| WaylandInput.destroySeat(wl_seat);
                return err;
            };
            errdefer input.deinit();
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            self.* = .{ .allocator = allocator, .connection = connection, .input = input, .renderer = renderer, .windows = .empty };
            window.installWmBaseListener(connection.wm_base);
            connection.setSeatCapabilitiesHandler(&self.input, WaylandInput.seatCapabilitiesCallback);
            self.input.attachListeners();
            self.clipboard = data_device.Clipboard.init(allocator, connection.display, connection.data_device_manager, self.input.seat);
            return self;
        }

        pub fn destroy(self: *Self) void {
            while (self.windows.items.len > 0) self.destroyWindow(self.windows.items[self.windows.items.len - 1]);
            self.windows.deinit(self.allocator);
            if (self.clipboard) |clipboard| clipboard.destroy();
            RendererAdapter.deinitBackend(&self.renderer);
            self.input.deinit();
            self.connection.deinit();
            self.allocator.destroy(self);
        }

        pub fn createWindow(self: *Self, options: WindowOptions) !*Window {
            var protocol = try window.Surface.init(self.connection, options.output, options);
            errdefer protocol.deinit();
            if (@hasDecl(RendererAdapter, "beforeWindowRendererInit")) RendererAdapter.beforeWindowRendererInit(self, &protocol);
            var renderer = try RendererAdapter.initWindow(self, &protocol);
            errdefer RendererAdapter.deinitWindow(self, &renderer);
            const win = try self.allocateWindow(protocol, renderer);
            errdefer self.rollbackWindowRegistration(win);
            try win.protocol.attachListeners();
            if (@hasDecl(RendererAdapter, "afterWindowListeners")) RendererAdapter.afterWindowListeners(self, win);
            return win;
        }

        pub fn createPopup(self: *Self, parent: *Window, options: window.PopupOptions) !*Window {
            var protocol = try window.Surface.initPopup(self.connection, &parent.protocol, options);
            errdefer protocol.deinit();
            var renderer = try RendererAdapter.initWindow(self, &protocol);
            errdefer RendererAdapter.deinitWindow(self, &renderer);
            const win = try self.allocateWindow(protocol, renderer);
            errdefer self.rollbackWindowRegistration(win);
            try win.protocol.attachListeners();
            if (self.input.seat) |seat| if (self.input.last_button_press_serial) |serial| win.protocol.grabPopup(seat, serial);
            win.protocol.surface.commit();
            _ = self.connection.display.flush();
            return win;
        }

        fn allocateWindow(self: *Self, protocol: window.Surface, renderer: RendererAdapter.WindowResources) !*Window {
            const win = try self.allocator.create(Window);
            errdefer self.allocator.destroy(win);
            win.* = .{ .backend = self, .protocol = protocol, .renderer = renderer, .input_target = .{ .surface = protocol.surface } };
            try self.windows.append(self.allocator, win);
            errdefer _ = self.windows.pop();
            try self.input.registerTarget(&win.input_target);
            return win;
        }

        fn rollbackWindowRegistration(self: *Self, win: *Window) void {
            self.input.unregisterTarget(&win.input_target);
            _ = self.windows.pop();
            self.allocator.destroy(win);
        }

        pub fn destroyWindow(self: *Self, win: *Window) void {
            self.input.unregisterTarget(&win.input_target);
            for (self.windows.items, 0..) |existing, index| if (existing == win) {
                _ = self.windows.orderedRemove(index);
                break;
            };
            RendererAdapter.deinitWindow(self, &win.renderer);
            win.protocol.deinit();
            self.allocator.destroy(win);
        }

        pub fn setPopupKeyboardFocus(self: *Self, win: *Window, focused: bool) void {
            win.protocol.setPopupKeyboardFocus(focused);
            _ = self.connection.display.flush();
        }
        pub fn repositionPopup(self: *Self, win: *Window, options: window.PopupOptions, token: u32) !void {
            try win.protocol.repositionPopup(self.connection, options, token);
            _ = self.connection.display.flush();
        }
        pub fn requestLayerSize(self: *Self, win: *Window, width: u31, height: u31) !void {
            try win.protocol.requestLayerSize(width, height);
            _ = self.connection.display.flush();
        }
        pub fn outputCount(self: *const Self) usize {
            return self.connection.outputs.items.len;
        }
        pub fn outputAt(self: *const Self, index: usize) *wl.Output {
            return self.connection.outputs.items[index].output;
        }
        pub fn outputInfoAt(self: *const Self, index: usize) window.OutputInfo {
            return self.connection.outputInfoAt(index);
        }
        pub fn findOutputByName(self: *const Self, name: []const u8) ?*wl.Output {
            return self.connection.findOutputByName(name);
        }
        pub fn setOutputsChangedHandler(self: *Self, ctx: *anyopaque, handler: *const fn (*anyopaque) void) void {
            self.connection.setOutputsChangedHandler(ctx, handler);
        }
        pub fn installEventTimers(self: *Self, loop: *event_loop.EventLoop) !void {
            try self.input.installEventTimers(loop);
        }
        pub fn uninstallEventTimers(self: *Self) void {
            self.input.uninstallEventTimers();
        }
        pub fn eventLoopFd(self: *Self) i32 {
            return self.connection.display.getFd();
        }

        pub fn waitForAllConfigured(self: *Self) !void {
            while (!self.allConfigured() and !self.allClosed()) if (self.connection.display.dispatch() != .SUCCESS) return error.DispatchFailed;
            if (self.allClosed()) return error.WindowClosed;
            for (self.windows.items) |win| {
                _ = win.protocol.flushPending();
                self.input.setTargetScale(&win.input_target, win.protocol.scale);
            }
        }
        pub fn waitForConfigured(self: *Self, win: *Window) !void {
            while (!win.protocol.configured and !win.protocol.closed) if (self.connection.display.dispatch() != .SUCCESS) return error.DispatchFailed;
            if (win.protocol.closed) return error.WindowClosed;
            _ = win.protocol.flushPending();
            self.input.setTargetScale(&win.input_target, win.protocol.scale);
        }
        pub fn waitForConfigureAfter(self: *Self, win: *Window, generation: u64) !void {
            while (win.protocol.configureGeneration() == generation and !win.protocol.closed) if (self.connection.display.dispatch() != .SUCCESS) return error.DispatchFailed;
            if (win.protocol.closed) return error.WindowClosed;
            _ = win.protocol.flushPending();
            self.input.setTargetScale(&win.input_target, win.protocol.scale);
        }

        pub fn eventLoopPrepare(ctx: *anyopaque) !event_loop.EventLoop.WaylandPrepare {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return window.eventLoopPrepare(self.connection.display, self, flushPendingOpaque);
        }
        pub fn eventLoopFinish(ctx: *anyopaque, events: u32) !bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return window.eventLoopFinish(self.connection.display, self, flushPendingOpaque, allClosedOpaque, events);
        }
        pub fn eventLoopFinishKeepAlive(ctx: *anyopaque, events: u32) !bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return window.eventLoopFinish(self.connection.display, self, flushPendingOpaque, neverClosedOpaque, events);
        }
        fn flushPendingOpaque(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.flushPending();
        }
        fn allClosedOpaque(ctx: *anyopaque) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.allClosed();
        }
        fn neverClosedOpaque(_: *anyopaque) bool {
            return false;
        }
        fn flushPending(self: *Self) void {
            for (self.windows.items) |win| win.flushPending();
        }
        fn allConfigured(self: *const Self) bool {
            for (self.windows.items) |win| if (!win.protocol.closed and !win.protocol.configured) return false;
            return true;
        }
        fn allClosed(self: *const Self) bool {
            for (self.windows.items) |win| if (!win.protocol.closed) return false;
            return true;
        }

        pub const Window = struct {
            backend: *Self,
            protocol: window.Surface,
            renderer: RendererAdapter.WindowResources,
            input_target: WaylandInput.Target,
            repaint_handler: ?RepaintHandler = null,
            repaint_context: ?*anyopaque = null,
            frame_handler: ?FrameHandler = null,
            frame_context: ?*anyopaque = null,

            pub fn renderBackend(self: *Window) keywork.RenderBackend {
                const vtable: keywork.RenderBackend.VTable = if (@hasDecl(RendererAdapter, "partialPaintBounds"))
                    .{ .present = present, .measure_text = measureText, .scale = renderScale, .text_metrics = textMetrics, .partial_paint_bounds = partialPaintBounds }
                else
                    .{ .present = present, .measure_text = measureText, .scale = renderScale, .text_metrics = textMetrics };
                return .{ .ptr = self, .vtable = &vtable };
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
            pub fn configureGeneration(self: *const Window) u64 {
                return self.protocol.configureGeneration();
            }
            pub fn suspendedOpaque(ctx: *anyopaque) bool {
                const self: *Window = @ptrCast(@alignCast(ctx));
                return self.protocol.suspended;
            }
            fn flushPending(self: *Window) void {
                const pending = self.protocol.flushPending();
                self.backend.input.setTargetScale(&self.input_target, self.protocol.scale);
                if (pending.repaint) if (self.repaint_handler) |handler| handler(self.repaint_context.?, self.currentSize());
                if (pending.frame_done) if (self.frame_handler) |handler| handler(self.frame_context.?);
            }
            fn present(ptr: *anyopaque, frame: keywork.RenderBackend.Frame) !bool {
                const self: *Window = @ptrCast(@alignCast(ptr));
                return RendererAdapter.present(self, frame);
            }
            fn measureText(ptr: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !keywork.Size {
                const self: *Window = @ptrCast(@alignCast(ptr));
                return RendererAdapter.measureText(self, value, style);
            }
            fn textMetrics(ptr: *anyopaque, font_size: f32) !keywork.TextMetrics {
                const self: *Window = @ptrCast(@alignCast(ptr));
                return RendererAdapter.textMetrics(self, font_size);
            }
            fn renderScale(ptr: *anyopaque) f32 {
                const self: *Window = @ptrCast(@alignCast(ptr));
                return self.protocol.scale;
            }
            fn partialPaintBounds(ptr: *anyopaque, size: keywork.Size, scale: f32, damage: []const keywork.Rect) !?keywork.Rect {
                const self: *Window = @ptrCast(@alignCast(ptr));
                return RendererAdapter.partialPaintBounds(self, size, scale, damage);
            }
        };
    };
}
