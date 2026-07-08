//! Minimal `wl_shm` render backend for Keywork display lists.

const std = @import("std");
const event_loop = @import("../../linux/event_loop.zig");
const keywork = @import("../../ui.zig");
const TextRenderer = @import("../../graphics/text.zig");
const WaylandInput = @import("input.zig");
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
    protocol: window.Surface,
    buffers: std.ArrayList(*Buffer),
    /// The buffer holding the most recently rendered frame; the source for
    /// partial redraws when the compositor hands us a different buffer.
    last_rendered: ?*Buffer = null,
    text_renderer: TextRenderer,

    repaint_handler: ?RepaintHandler,
    repaint_context: ?*anyopaque,
    frame_handler: ?FrameHandler,
    frame_context: ?*anyopaque,
    extra_surfaces: std.ArrayList(ExtraSurface),

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
        layer_shell: ?wayland_options.LayerShellOptions = null,
    };

    const ExtraSurface = struct {
        protocol: window.Surface,
        buffers: std.ArrayList(*Buffer) = .empty,
        last_rendered: ?*Buffer = null,

        fn destroy(self: *ExtraSurface, allocator: std.mem.Allocator) void {
            for (self.buffers.items) |buffer| buffer.destroy(allocator);
            self.buffers.deinit(allocator);
            self.protocol.deinit();
        }
    };

    pub fn create(allocator: std.mem.Allocator, options: Options) !*Backend {
        const connection = try window.Connection.init(allocator, .{ .shm = true, .outputs = true });
        errdefer connection.deinit();

        const all_outputs = if (options.layer_shell) |layer_options| layer_options.output == .all else false;
        if (all_outputs and connection.outputs.items.len == 0) return error.NoWlOutput;
        const primary_output = if (all_outputs) connection.outputs.items[0].output else null;

        var protocol = try window.Surface.init(connection, primary_output, options);
        errdefer protocol.deinit();

        var extra_surfaces: std.ArrayList(ExtraSurface) = .empty;
        errdefer {
            for (extra_surfaces.items) |*extra| extra.destroy(allocator);
            extra_surfaces.deinit(allocator);
        }
        if (all_outputs) {
            for (connection.outputs.items[1..]) |output_ref| {
                const extra = try createExtraSurface(
                    output_ref.output,
                    connection,
                    options,
                );
                try extra_surfaces.append(allocator, extra);
            }
        }

        var text_renderer_instance = try TextRenderer.init(allocator);
        errdefer text_renderer_instance.deinit();
        const seat = connection.takeSeat();
        var input = WaylandInput.init(protocol.surface, seat, connection.cursor_shape_manager) catch |err| {
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
            .protocol = protocol,
            .buffers = .empty,
            .text_renderer = text_renderer_instance,
            .repaint_handler = null,
            .repaint_context = null,
            .frame_handler = null,
            .frame_context = null,
            .extra_surfaces = extra_surfaces,
        };

        window.installWmBaseListener(self.connection.wm_base);
        self.protocol.attachListeners();
        for (self.extra_surfaces.items) |*extra| {
            extra.protocol.attachListeners();
            extra.protocol.surface.commit();
        }
        self.input.attachListeners();
        self.protocol.surface.commit();

        return self;
    }

    pub fn destroy(self: *Backend) void {
        for (self.buffers.items) |buffer| buffer.destroy(self.allocator);
        self.buffers.deinit(self.allocator);
        for (self.extra_surfaces.items) |*extra| extra.destroy(self.allocator);
        self.extra_surfaces.deinit(self.allocator);
        self.text_renderer.deinit();
        self.input.deinit();
        self.protocol.deinit();
        self.connection.deinit();
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
        return extra.protocol.currentSize();
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
                if (self.backend.connection.display.dispatch() != .SUCCESS) return error.DispatchFailed;
            }
            if (self.index == 0) {
                if (self.backend.protocol.closed) return false;
                const pending = try self.backend.presentPrimary(frame);
                _ = self.backend.connection.display.flush();
                return pending;
            }
            const extra = &self.backend.extra_surfaces.items[self.index - 1];
            if (extra.protocol.closed) return false;
            const pending = try self.backend.presentExtra(extra, frame);
            _ = self.backend.connection.display.flush();
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
            if (self.index == 0) return self.backend.protocol.scale;
            return self.backend.extra_surfaces.items[self.index - 1].protocol.scale;
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

    pub fn eventLoopFd(self: *Backend) i32 {
        return self.connection.display.getFd();
    }

    pub fn waitForInitialConfigure(self: *Backend) !keywork.Size {
        while (!self.allConfigured() and !self.allClosed()) {
            if (self.connection.display.dispatch() != .SUCCESS) return error.DispatchFailed;
        }
        if (self.allClosed()) return error.WindowClosed;
        self.flushPending();
        return self.currentSize();
    }

    pub fn eventLoopPrepare(ctx: *anyopaque) !event_loop.EventLoop.WaylandPrepare {
        const self: *Backend = @ptrCast(@alignCast(ctx));
        return window.eventLoopPrepare(self.connection.display, self, flushPendingOpaque);
    }

    pub fn eventLoopFinish(ctx: *anyopaque, events: u32) !bool {
        const self: *Backend = @ptrCast(@alignCast(ctx));
        return window.eventLoopFinish(self.connection.display, self, flushPendingOpaque, allClosedOpaque, events);
    }

    fn flushPendingOpaque(ctx: *anyopaque) void {
        const self: *Backend = @ptrCast(@alignCast(ctx));
        self.flushPending();
    }

    fn allClosedOpaque(ctx: *anyopaque) bool {
        const self: *Backend = @ptrCast(@alignCast(ctx));
        return self.allClosed();
    }

    fn present(ptr: *anyopaque, frame: keywork.RenderBackend.Frame) !bool {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        if (self.allClosed()) return error.WindowClosed;

        while (!self.allConfigured() and !self.allClosed()) {
            if (self.connection.display.dispatch() != .SUCCESS) return error.DispatchFailed;
        }
        if (self.allClosed()) return error.WindowClosed;

        var frame_pending = false;
        if (!self.protocol.closed) frame_pending = try self.presentPrimary(frame) or frame_pending;
        for (self.extra_surfaces.items) |*extra| {
            if (!extra.protocol.closed) frame_pending = try self.presentExtra(extra, frame) or frame_pending;
        }
        _ = self.connection.display.flush();
        return frame_pending;
    }

    fn presentPrimary(self: *Backend, frame: keywork.RenderBackend.Frame) !bool {
        const protocol = &self.protocol;
        const logical_width = try window.frameLogicalWidth(frame, protocol.width);
        const logical_height = try window.frameLogicalHeight(frame, protocol.height);
        const width = try window.scaledFrameDimension(logical_width, protocol.scale);
        const height = try window.scaledFrameDimension(logical_height, protocol.scale);
        const buffer = try self.acquireBuffer(width, height);
        const damage_clip = self.partialDamageClip(frame, buffer, width, height);
        try rasterize(&self.text_renderer, buffer.pixels(), width, height, protocol.scale, frame.display_list, damage_clip);
        self.last_rendered = buffer;

        try protocol.armFrameCallback();
        protocol.surface.attach(buffer.wl_buffer, 0, 0);
        if (damage_clip) |clip| {
            const x0: i32 = @max(0, clip.x0);
            const y0: i32 = @max(0, clip.y0);
            const x1: i32 = @min(@as(i32, width), clip.x1);
            const y1: i32 = @min(@as(i32, height), clip.y1);
            protocol.surface.damageBuffer(x0, y0, @max(0, x1 - x0), @max(0, y1 - y0));
        } else {
            protocol.surface.damageBuffer(0, 0, width, height);
        }
        protocol.surface.setBufferScale(1);
        if (protocol.viewport) |viewport| viewport.setDestination(logical_width, logical_height);
        protocol.surface.commit();
        buffer.busy = true;
        return true;
    }

    fn presentExtra(self: *Backend, extra: *ExtraSurface, frame: keywork.RenderBackend.Frame) !bool {
        const protocol = &extra.protocol;
        const logical_width = try window.frameLogicalWidth(frame, protocol.width);
        const logical_height = try window.frameLogicalHeight(frame, protocol.height);
        const width = try window.scaledFrameDimension(logical_width, protocol.scale);
        const height = try window.scaledFrameDimension(logical_height, protocol.scale);
        const buffer = try self.acquireExtraBuffer(extra, width, height);
        try rasterize(&self.text_renderer, buffer.pixels(), width, height, protocol.scale, frame.display_list, null);
        extra.last_rendered = buffer;

        try protocol.armFrameCallback();
        protocol.surface.attach(buffer.wl_buffer, 0, 0);
        protocol.surface.damageBuffer(0, 0, width, height);
        protocol.surface.setBufferScale(1);
        if (protocol.viewport) |viewport| viewport.setDestination(logical_width, logical_height);
        protocol.surface.commit();
        buffer.busy = true;
        return true;
    }

    fn measureText(ptr: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !keywork.Size {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        return self.text_renderer.measure(self.protocol.scale, value, style);
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
        const primary = self.protocol.flushPending();
        var repaint = primary.repaint;
        if (primary.frame_done) self.notifyFrameDone();
        for (self.extra_surfaces.items) |*extra| {
            const pending = extra.protocol.flushPending();
            repaint = repaint or pending.repaint;
            if (pending.frame_done) self.notifyFrameDone();
        }
        if (repaint) self.notifyRepaint();
    }

    fn notifyFrameDone(self: *Backend) void {
        if (self.frame_handler) |handler| handler(self.frame_context.?);
    }

    fn allConfigured(self: *const Backend) bool {
        if (!self.protocol.closed and !self.protocol.configured) return false;
        for (self.extra_surfaces.items) |*extra| {
            if (!extra.protocol.closed and !extra.protocol.configured) return false;
        }
        return true;
    }

    fn allClosed(self: *const Backend) bool {
        if (!self.protocol.closed) return false;
        for (self.extra_surfaces.items) |*extra| {
            if (!extra.protocol.closed) return false;
        }
        return true;
    }

    /// Returns the pixel region that must be re-rasterized, or null when a
    /// full redraw is required. Partial redraw needs the previous frame's
    /// content: either the acquired buffer already holds it, or it is
    /// copied over from the buffer that does.
    fn partialDamageClip(self: *Backend, frame: keywork.RenderBackend.Frame, buffer: *Buffer, width: u31, height: u31) ?TextRenderer.PixelClip {
        if (frame.damage.len != 1) return null;
        const clip = TextRenderer.PixelClip.fromRect(frame.damage[0], self.protocol.scale);
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

        const buffer = try Buffer.create(self.allocator, self.connection.shm.?, width, height);
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

        const buffer = try Buffer.create(self.allocator, self.connection.shm.?, width, height);
        errdefer buffer.destroy(self.allocator);
        try extra.buffers.append(self.allocator, buffer);
        return buffer;
    }

    fn createExtraSurface(
        output: *wl.Output,
        connection: *const window.Connection,
        options: Options,
    ) !ExtraSurface {
        return .{ .protocol = try window.Surface.init(connection, output, options) };
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
