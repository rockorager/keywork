//! Minimal `wl_shm` render backend for Keywork display lists.

const std = @import("std");
const builtin = @import("builtin");
const event_loop = @import("../../linux/event_loop.zig");
const keywork = @import("../../ui.zig");
const raster = @import("../../graphics/raster.zig");
const TextRenderer = @import("../../graphics/text.zig");
const WaylandInput = @import("input.zig");
const data_device = @import("data_device.zig");
const wayland_options = @import("options.zig");
const window = @import("window.zig");
const wayland = @import("wayland");

const linux = std.os.linux;
const posix = std.posix;
const wl = wayland.client.wl;

pub const Backend = struct {
    allocator: std.mem.Allocator,
    connection: *window.Connection,
    input: WaylandInput,
    text_renderer: TextRenderer,
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
        title: [:0]const u8 = "Keywork",
        app_id: [:0]const u8 = "dev.keywork.Keywork",
        width: u31 = 640,
        height: u31 = 480,
        decorations: wayland_options.Decorations = .server,
        layer_shell: ?wayland_options.LayerShellOptions = null,
        /// Output a layer-shell surface is placed on; null lets the
        /// compositor choose.
        output: ?*wl.Output = null,
    };

    pub fn create(allocator: std.mem.Allocator) !*Backend {
        const connection = try window.Connection.init(allocator, .{ .shm = true, .outputs = true });
        errdefer connection.deinit();

        var text_renderer_instance = try TextRenderer.init(allocator);
        errdefer text_renderer_instance.deinit();

        const seat = connection.takeSeat();
        var input = WaylandInput.init(
            allocator,
            seat,
            connection.seatCapabilities(),
            connection.cursor_shape_manager,
            connection.compositor,
            connection.shm,
        ) catch |err| {
            if (seat) |wl_seat| WaylandInput.destroySeat(wl_seat);
            return err;
        };
        errdefer input.deinit();

        const self = try allocator.create(Backend);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .connection = connection,
            .input = input,
            .text_renderer = text_renderer_instance,
            .windows = .empty,
        };

        window.installWmBaseListener(self.connection.wm_base);
        // Seat listener stays on the connection; forward capability changes
        // into input once it lives at its final address.
        self.connection.setSeatCapabilitiesHandler(&self.input, WaylandInput.seatCapabilitiesCallback);
        self.input.attachListeners();
        self.clipboard = data_device.Clipboard.init(allocator, connection.display, connection.data_device_manager, self.input.seat);
        return self;
    }

    pub fn destroy(self: *Backend) void {
        while (self.windows.items.len > 0) {
            self.destroyWindow(self.windows.items[self.windows.items.len - 1]);
        }
        self.windows.deinit(self.allocator);
        if (self.clipboard) |clipboard| clipboard.destroy();
        self.text_renderer.deinit();
        self.input.deinit();
        self.connection.deinit();
        self.allocator.destroy(self);
    }

    pub fn createWindow(self: *Backend, options: WindowOptions) !*Window {
        var protocol = try window.Surface.init(self.connection, options.output, options);
        errdefer protocol.deinit();

        const win = try self.allocator.create(Window);
        errdefer self.allocator.destroy(win);
        win.* = .{
            .backend = self,
            .protocol = protocol,
            .input_target = .{ .surface = protocol.surface },
        };
        try self.windows.append(self.allocator, win);
        errdefer _ = self.windows.pop();
        try self.input.registerTarget(&win.input_target);
        errdefer self.input.unregisterTarget(&win.input_target);

        // Listener contexts must point at the window's final storage.
        try win.protocol.attachListeners();
        // Commit and flush now so the compositor prepares the initial
        // configure while the caller finishes setup. Events queue until
        // the first dispatch.
        win.protocol.surface.commit();
        _ = self.connection.display.flush();
        return win;
    }

    /// Creates a popup window anchored to `parent`. The popup grabs the
    /// seat when an input serial is available, so the compositor dismisses
    /// it (closing the window) when the user clicks elsewhere.
    pub fn createPopup(self: *Backend, parent: *Window, options: window.PopupOptions) !*Window {
        var protocol = try window.Surface.initPopup(self.connection, &parent.protocol, options);
        errdefer protocol.deinit();

        const win = try self.allocator.create(Window);
        errdefer self.allocator.destroy(win);
        win.* = .{
            .backend = self,
            .protocol = protocol,
            .input_target = .{ .surface = protocol.surface },
        };
        try self.windows.append(self.allocator, win);
        errdefer _ = self.windows.pop();
        try self.input.registerTarget(&win.input_target);
        errdefer self.input.unregisterTarget(&win.input_target);

        try win.protocol.attachListeners();
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
        for (self.windows.items) |win| {
            _ = win.protocol.flushPending();
            self.input.setTargetScale(&win.input_target, win.protocol.scale);
        }
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
        self.input.setTargetScale(&win.input_target, win.protocol.scale);
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

    /// One Wayland surface with its own buffers, damage history, frame
    /// state, and input target. Created and destroyed through the owning
    /// `Backend`; all windows share one connection, seat, and text
    /// renderer.
    pub const Window = struct {
        backend: *Backend,
        protocol: window.Surface,
        input_target: WaylandInput.Target,
        buffers: std.ArrayList(*Buffer) = .empty,
        last_rendered: ?*Buffer = null,
        last_rendered_scale: f32 = 0,
        /// Monotonic per-window frame number; `Buffer.frame` refers to it.
        frame_counter: u64 = 0,
        history: DamageHistory = .{},
        repaint_handler: ?RepaintHandler = null,
        repaint_context: ?*anyopaque = null,
        frame_handler: ?FrameHandler = null,
        frame_context: ?*anyopaque = null,

        pub fn renderBackend(self: *Window) keywork.RenderBackend {
            return .{ .ptr = self, .vtable = &.{
                .present = present,
                .measure_text = measureText,
                .scale = renderScale,
                .text_metrics = textMetrics,
                .partial_paint_bounds = partialPaintBounds,
            } };
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
            for (self.buffers.items) |buffer| buffer.destroy(self.backend.allocator);
            self.buffers.deinit(self.backend.allocator);
            self.protocol.deinit();
        }

        fn flushPending(self: *Window) void {
            const pending = self.protocol.flushPending();
            self.backend.input.setTargetScale(&self.input_target, self.protocol.scale);
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
            const buffer = try self.acquireBuffer(width, height);
            const damage_clip = self.partialDamageClip(frame, buffer, width, height);
            if (frame.partial_display_list and damage_clip == null) return error.PartialPaintUnavailable;
            try raster.rasterize(&self.backend.text_renderer, buffer.pixels(), width, height, protocol.scale, frame.display_list, damage_clip);
            self.last_rendered = buffer;
            self.last_rendered_scale = protocol.scale;

            try protocol.armFrameCallback();
            protocol.surface.attach(buffer.wl_buffer, 0, 0);
            if (damage_clip) |clip| {
                const x0: i32 = @max(0, clip.x0);
                const y0: i32 = @max(0, clip.y0);
                const x1: i32 = @min(@as(i32, width), clip.x1);
                const y1: i32 = @min(@as(i32, height), clip.y1);
                protocol.damagePixels(x0, y0, @max(0, x1 - x0), @max(0, y1 - y0));
            } else {
                protocol.damagePixels(0, 0, width, height);
            }
            protocol.configureBuffer(logical_width, logical_height);
            protocol.surface.commit();
            buffer.busy = true;
            self.frame_counter += 1;
            buffer.frame = self.frame_counter;
            self.history.record(
                self.frame_counter,
                width,
                height,
                damage_clip orelse .{ .x0 = 0, .y0 = 0, .x1 = width, .y1 = height },
            );
            _ = self.backend.connection.display.flush();
            return true;
        }

        fn measureText(ptr: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !keywork.Size {
            const self: *Window = @ptrCast(@alignCast(ptr));
            return self.backend.text_renderer.measure(self.protocol.scale, value, style);
        }

        fn textMetrics(ptr: *anyopaque, font_size: f32) !keywork.TextMetrics {
            const self: *Window = @ptrCast(@alignCast(ptr));
            return self.backend.text_renderer.metrics(self.protocol.scale, font_size);
        }

        fn renderScale(ptr: *anyopaque) f32 {
            const self: *Window = @ptrCast(@alignCast(ptr));
            return self.protocol.scale;
        }

        fn partialPaintBounds(ptr: *anyopaque, size: keywork.Size, scale: f32, damage: []const keywork.Rect) !?keywork.Rect {
            const self: *Window = @ptrCast(@alignCast(ptr));
            if (!self.protocol.configured or scale != self.protocol.scale or damage.len != 1) return null;

            const probe: keywork.RenderBackend.Frame = .{
                .size = size,
                .scale = scale,
                .damage = damage,
                .display_list = &.{},
            };
            const logical_width = try window.frameLogicalWidth(probe, self.protocol.width);
            const logical_height = try window.frameLogicalHeight(probe, self.protocol.height);
            const width = try window.scaledFrameDimension(logical_width, scale);
            const height = try window.scaledFrameDimension(logical_height, scale);
            const last = self.last_rendered orelse return null;
            if (self.last_rendered_scale != scale or last.width != width or last.height != height) return null;

            const clip = TextRenderer.PixelClip.fromRect(damage[0], scale);
            if (clip.x0 >= clip.x1 or clip.y0 >= clip.y1) return null;
            if (clip.x0 <= 0 and clip.y0 <= 0 and clip.x1 >= width and clip.y1 >= height) return null;

            // Cull against pixel-aligned logical bounds. A neighboring node
            // whose edge shares a rounded damage pixel must still be emitted.
            const x0: f32 = @floatFromInt(@max(0, clip.x0));
            const y0: f32 = @floatFromInt(@max(0, clip.y0));
            const x1: f32 = @floatFromInt(@min(@as(i32, width), clip.x1));
            const y1: f32 = @floatFromInt(@min(@as(i32, height), clip.y1));
            return .{
                .x = x0 / scale,
                .y = y0 / scale,
                .width = (x1 - x0) / scale,
                .height = (y1 - y0) / scale,
            };
        }

        /// Returns the pixel region that must be re-rasterized, or null
        /// when a full redraw is required. Partial redraw needs the
        /// previous frame's content: either the acquired buffer already
        /// holds it, or it is copied over from the buffer that does.
        fn partialDamageClip(self: *Window, frame: keywork.RenderBackend.Frame, buffer: *Buffer, width: u31, height: u31) ?TextRenderer.PixelClip {
            if (frame.damage.len != 1) return null;
            const clip = TextRenderer.PixelClip.fromRect(frame.damage[0], self.protocol.scale);
            if (clip.x0 <= 0 and clip.y0 <= 0 and clip.x1 >= width and clip.y1 >= height) return null;

            const last = self.last_rendered orelse return null;
            if (self.last_rendered_scale != self.protocol.scale) return null;
            if (last == buffer) return clip;
            if (last.width != width or last.height != height) return null;
            if (self.history.canRepair(buffer.frame, width, height)) {
                repairRegions(
                    buffer.pixels(),
                    last.pixels(),
                    width,
                    height,
                    self.history.entries[0..self.history.len],
                    buffer.frame,
                    clip,
                );
            } else {
                copyPixels(buffer.pixels(), last.pixels());
            }
            return clip;
        }

        fn acquireBuffer(self: *Window, width: u31, height: u31) !*Buffer {
            const allocator = self.backend.allocator;
            var index: usize = 0;
            while (index < self.buffers.items.len) {
                const buffer = self.buffers.items[index];
                if (buffer.busy) {
                    index += 1;
                    continue;
                }
                if (buffer.width == width and buffer.height == height) return buffer;
                if (self.last_rendered == buffer) self.last_rendered = null;
                buffer.destroy(allocator);
                _ = self.buffers.swapRemove(index);
            }

            const buffer = try Buffer.create(allocator, self.backend.connection.shm.?, width, height);
            errdefer buffer.destroy(allocator);
            try self.buffers.append(allocator, buffer);
            return buffer;
        }
    };
};

const Buffer = struct {
    wl_buffer: *wl.Buffer,
    data: []align(std.heap.page_size_min) u8,
    width: u31,
    height: u31,
    busy: bool,
    /// Backend.frame_counter value when this buffer was last committed;
    /// 0 means the buffer has never held a frame.
    frame: u64,

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
            .frame = 0,
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

/// Damage records for recently committed primary frames, newest first.
/// A reused buffer the compositor held for several frames is repaired by
/// copying only the regions that changed in the interim, instead of the
/// whole frame.
const DamageHistory = struct {
    entries: [capacity]Entry = undefined,
    len: usize = 0,
    width: u31 = 0,
    height: u31 = 0,

    /// More frames than the compositor plausibly holds buffers for;
    /// wl_shm double/triple buffering stays well under this.
    const capacity = 8;

    const Entry = struct {
        frame: u64,
        clip: TextRenderer.PixelClip,
    };

    fn record(self: *DamageHistory, frame: u64, width: u31, height: u31, clip: TextRenderer.PixelClip) void {
        if (self.width != width or self.height != height) {
            self.len = 0;
            self.width = width;
            self.height = height;
        }
        std.debug.assert(self.len == 0 or frame == self.entries[0].frame + 1);
        const count = @min(self.len + 1, capacity);
        var index = count - 1;
        while (index > 0) : (index -= 1) self.entries[index] = self.entries[index - 1];
        self.entries[0] = .{ .frame = frame, .clip = clip };
        self.len = count;
    }

    /// Whether the history covers every frame committed after
    /// `buffer_frame`, i.e. a stale buffer can be repaired from damage
    /// records alone.
    fn canRepair(self: *const DamageHistory, buffer_frame: u64, width: u31, height: u31) bool {
        if (buffer_frame == 0) return false;
        if (self.len == 0 or self.width != width or self.height != height) return false;
        return self.entries[self.len - 1].frame <= buffer_frame + 1;
    }
};

/// Copy the regions damaged after `buffer_frame` from `src` into `dst`,
/// skipping regions the current frame repaints anyway. Entries must be
/// ordered newest first.
fn repairRegions(
    dst: []u32,
    src: []const u32,
    width: u31,
    height: u31,
    entries: []const DamageHistory.Entry,
    buffer_frame: u64,
    repaint: TextRenderer.PixelClip,
) void {
    for (entries) |entry| {
        if (entry.frame <= buffer_frame) break;
        if (clipContains(repaint, entry.clip)) continue;
        copyRegion(dst, src, width, height, entry.clip);
    }
}

fn clipContains(outer: TextRenderer.PixelClip, inner: TextRenderer.PixelClip) bool {
    return outer.x0 <= inner.x0 and outer.y0 <= inner.y0 and
        outer.x1 >= inner.x1 and outer.y1 >= inner.y1;
}

/// Copy one clip region between equally sized frames. Full-width regions
/// collapse into a single contiguous copy so large repairs can use the
/// non-temporal path.
fn copyRegion(noalias dst: []u32, noalias src: []const u32, width: u31, height: u31, clip: TextRenderer.PixelClip) void {
    const x0 = clampClip(clip.x0, width);
    const x1 = clampClip(clip.x1, width);
    const y0 = clampClip(clip.y0, height);
    const y1 = clampClip(clip.y1, height);
    if (x0 >= x1 or y0 >= y1) return;
    if (x0 == 0 and x1 == width) {
        copyPixels(dst[y0 * width .. y1 * width], src[y0 * width .. y1 * width]);
        return;
    }
    var y = y0;
    while (y < y1) : (y += 1) {
        @memcpy(dst[y * width ..][x0..x1], src[y * width ..][x0..x1]);
    }
}

fn clampClip(value: i32, max_value: u31) usize {
    if (value <= 0) return 0;
    return @min(@as(usize, @intCast(value)), max_value);
}

/// Copy pixels into a buffer the CPU will not read back (a wl_shm
/// buffer). Large copies use non-temporal stores on x86_64: they skip
/// the read-for-ownership of every destination cache line (about a
/// third of the bus traffic) and keep the copy from evicting the render
/// working set.
fn copyPixels(noalias dst: []u32, noalias src: []const u32) void {
    std.debug.assert(dst.len == src.len);
    // Below this size the fence and alignment fixup outweigh the saved
    // traffic, and freshly written destination lines may still be hot.
    const nt_threshold = 256 * 1024 / @sizeOf(u32);
    // The self-hosted backend's assembler can't parse the SSE memory
    // operands, so the non-temporal path is LLVM-only.
    if (comptime builtin.cpu.arch == .x86_64 and builtin.zig_backend == .stage2_llvm) {
        if (dst.len >= nt_threshold) return copyNonTemporal(dst, src);
    }
    @memcpy(dst, src);
}

fn copyNonTemporal(noalias dst: []u32, noalias src: []const u32) void {
    var d: [*]u8 = @ptrCast(dst.ptr);
    var s: [*]const u8 = @ptrCast(src.ptr);
    var n: usize = dst.len * @sizeOf(u32);

    // movntdq requires a 16-byte-aligned destination.
    const misalign = @intFromPtr(d) & 15;
    if (misalign != 0) {
        const head = @min(16 - misalign, n);
        @memcpy(d[0..head], s[0..head]);
        d += head;
        s += head;
        n -= head;
    }
    while (n >= 64) {
        asm volatile (
            \\movdqu  (%%rsi), %%xmm0
            \\movdqu 16(%%rsi), %%xmm1
            \\movdqu 32(%%rsi), %%xmm2
            \\movdqu 48(%%rsi), %%xmm3
            \\movntdq %%xmm0,  (%%rdi)
            \\movntdq %%xmm1, 16(%%rdi)
            \\movntdq %%xmm2, 32(%%rdi)
            \\movntdq %%xmm3, 48(%%rdi)
            :
            : [s] "{rsi}" (s),
              [d] "{rdi}" (d),
            : .{ .xmm0 = true, .xmm1 = true, .xmm2 = true, .xmm3 = true, .memory = true });
        d += 64;
        s += 64;
        n -= 64;
    }
    if (n != 0) @memcpy(d[0..n], s[0..n]);
    // Non-temporal stores are weakly ordered; publish them before the
    // buffer is handed to the compositor.
    asm volatile ("sfence" ::: .{ .memory = true });
}

test "damage history covers only retained consecutive frames" {
    var history: DamageHistory = .{};
    try std.testing.expect(!history.canRepair(1, 4, 4));

    var frame: u64 = 1;
    while (frame <= 10) : (frame += 1) {
        history.record(frame, 4, 4, .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1 });
    }
    // Capacity 8: frames 3..10 retained, so buffers as old as frame 2
    // are repairable (their first missing frame is 3).
    try std.testing.expectEqual(@as(usize, DamageHistory.capacity), history.len);
    try std.testing.expect(history.canRepair(9, 4, 4));
    try std.testing.expect(history.canRepair(2, 4, 4));
    try std.testing.expect(!history.canRepair(1, 4, 4));
    // Never-committed buffers and size mismatches are unrecoverable.
    try std.testing.expect(!history.canRepair(0, 4, 4));
    try std.testing.expect(!history.canRepair(9, 8, 4));
}

test "damage history resets when the frame size changes" {
    var history: DamageHistory = .{};
    history.record(1, 4, 4, .{ .x0 = 0, .y0 = 0, .x1 = 4, .y1 = 4 });
    history.record(2, 8, 8, .{ .x0 = 0, .y0 = 0, .x1 = 8, .y1 = 8 });
    try std.testing.expectEqual(@as(usize, 1), history.len);
    try std.testing.expect(!history.canRepair(2, 4, 4));
    try std.testing.expect(history.canRepair(2, 8, 8));
}

test "stale buffer repair copies only interim damage" {
    const width: u31 = 4;
    const height: u31 = 4;
    var src: [width * height]u32 = undefined;
    for (&src, 0..) |*pixel, index| pixel.* = @intCast(index + 100);
    var dst: [width * height]u32 = @splat(0);

    const entries = [_]DamageHistory.Entry{
        .{ .frame = 5, .clip = .{ .x0 = 0, .y0 = 3, .x1 = 4, .y1 = 4 } },
        .{ .frame = 4, .clip = .{ .x0 = 1, .y0 = 1, .x1 = 3, .y1 = 2 } },
        .{ .frame = 3, .clip = .{ .x0 = 0, .y0 = 0, .x1 = 4, .y1 = 1 } },
    };
    // Buffer last held frame 3, so frames 4 and 5 are missing. The
    // current repaint covers frame 5's clip, leaving only frame 4's.
    repairRegions(&dst, &src, width, height, &entries, 3, .{ .x0 = 0, .y0 = 3, .x1 = 4, .y1 = 4 });

    const expected = [width * height]u32{
        0, 0,   0,   0,
        0, 105, 106, 0,
        0, 0,   0,   0,
        0, 0,   0,   0,
    };
    try std.testing.expectEqualSlices(u32, &expected, &dst);
}

test "copyRegion clamps out-of-bounds clips" {
    const width: u31 = 2;
    const height: u31 = 2;
    const src = [width * height]u32{ 1, 2, 3, 4 };
    var dst: [width * height]u32 = @splat(0);
    copyRegion(&dst, &src, width, height, .{ .x0 = -5, .y0 = -5, .x1 = 10, .y1 = 10 });
    try std.testing.expectEqualSlices(u32, &src, &dst);

    var untouched: [width * height]u32 = @splat(0);
    copyRegion(&untouched, &src, width, height, .{ .x0 = 2, .y0 = 0, .x1 = 2, .y1 = 2 });
    try std.testing.expectEqualSlices(u32, &[_]u32{ 0, 0, 0, 0 }, &untouched);
}

test "copyPixels matches the source above the non-temporal threshold" {
    const allocator = std.testing.allocator;
    // Odd length above the threshold with offset slices exercises the
    // misaligned head and short tail of the non-temporal path.
    const len = 256 * 1024 / @sizeOf(u32) + 13;
    const src_storage = try allocator.alloc(u32, len + 1);
    defer allocator.free(src_storage);
    const dst_storage = try allocator.alloc(u32, len + 1);
    defer allocator.free(dst_storage);

    var prng: std.Random.DefaultPrng = .init(0x6b657977);
    const random = prng.random();
    for (src_storage) |*pixel| pixel.* = random.int(u32);

    const src = src_storage[1..];
    const dst = dst_storage[1..];
    copyPixels(dst, src);
    try std.testing.expectEqualSlices(u32, src, dst);
}
