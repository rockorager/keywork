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
    text_renderer: TextRenderer,
    configured: bool,
    closed: bool,
    width: u31,
    height: u31,
    scale: f32,
    scale_changed: bool,

    repaint_handler: ?RepaintHandler,
    repaint_context: ?*anyopaque,
    frame_handler: ?FrameHandler,
    frame_context: ?*anyopaque,
    frame_callback: ?*wl.Callback,

    pub const PointerButtonHandler = WaylandInput.PointerButtonHandler;
    pub const PointerMoveHandler = WaylandInput.PointerMoveHandler;
    pub const CursorShapeHandler = WaylandInput.CursorShapeHandler;
    pub const KeyHandler = WaylandInput.KeyHandler;
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
        compositor: ?*wl.Compositor = null,
        shm: ?*wl.Shm = null,
        wm_base: ?*xdg.WmBase = null,
        layer_shell: ?*zwlr.LayerShellV1 = null,
        viewporter: ?*wp.Viewporter = null,
        fractional_scale_manager: ?*wp.FractionalScaleManagerV1 = null,
        cursor_shape_manager: ?*wp.CursorShapeManagerV1 = null,
        seat: ?*wl.Seat = null,
    };

    pub fn create(allocator: std.mem.Allocator, options: Options) !*Backend {
        const display = try wl.Display.connect(null);
        errdefer display.disconnect();

        const registry = try display.getRegistry();
        var globals: Globals = .{};
        registry.setListener(*Globals, registryListener, &globals);
        if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

        const compositor = globals.compositor orelse return error.NoWlCompositor;
        const shm = globals.shm orelse return error.NoWlShm;
        const wm_base = globals.wm_base;
        const layer_shell = globals.layer_shell;
        const viewporter = globals.viewporter;
        const fractional_scale_manager = globals.fractional_scale_manager;
        const cursor_shape_manager = globals.cursor_shape_manager;

        const surface = try compositor.createSurface();
        errdefer surface.destroy();
        const shell_role = try createShellRole(surface, wm_base, layer_shell, options);
        errdefer shell_role.destroy();
        const viewport = if (viewporter) |manager| try manager.getViewport(surface) else null;
        errdefer if (viewport) |surface_viewport| surface_viewport.destroy();
        const fractional_scale = if (fractional_scale_manager) |manager| try manager.getFractionalScale(surface) else null;
        errdefer if (fractional_scale) |surface_scale| surface_scale.destroy();

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
            .repaint_handler = null,
            .repaint_context = null,
            .frame_handler = null,
            .frame_context = null,
            .frame_callback = null,
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
        self.input.attachListeners(Backend, self);
        surface.commit();

        return self;
    }

    pub fn destroy(self: *Backend) void {
        if (self.frame_callback) |callback| callback.destroy();
        for (self.buffers.items) |buffer| buffer.destroy(self.allocator);
        self.buffers.deinit(self.allocator);
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
        self.registry.destroy();
        self.display.disconnect();
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

    pub fn installKeyRepeat(self: *Backend, loop: *event_loop.EventLoop) !void {
        try self.input.installKeyRepeat(loop);
    }

    pub fn uninstallKeyRepeat(self: *Backend) void {
        self.input.uninstallKeyRepeat();
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

    pub fn eventLoopPrepare(ctx: *anyopaque) !u32 {
        const self: *Backend = @ptrCast(@alignCast(ctx));
        while (!self.display.prepareRead()) {
            if (self.display.dispatchPending() != .SUCCESS) return error.DispatchFailed;
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
        if (self.scale_changed) {
            self.scale_changed = false;
            self.notifyRepaint();
        }
        return !self.closed;
    }

    fn present(ptr: *anyopaque, frame: keywork.RenderBackend.Frame) !bool {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        if (self.closed) return error.WindowClosed;

        while (!self.configured and !self.closed) {
            if (self.display.dispatch() != .SUCCESS) return error.DispatchFailed;
        }
        if (self.closed) return error.WindowClosed;

        const logical_width = try frameLogicalWidth(frame, self.width);
        const logical_height = try frameLogicalHeight(frame, self.height);
        const width = try scaledFrameDimension(logical_width, self.scale);
        const height = try scaledFrameDimension(logical_height, self.scale);
        const buffer = try self.acquireBuffer(width, height);
        try rasterize(&self.text_renderer, buffer.pixels(), width, height, self.scale, frame.display_list);

        try self.armFrameCallback();
        self.surface.attach(buffer.wl_buffer, 0, 0);
        self.surface.damageBuffer(0, 0, width, height);
        self.surface.setBufferScale(1);
        if (self.viewport) |viewport| viewport.setDestination(logical_width, logical_height);
        self.surface.commit();
        buffer.busy = true;
        _ = self.display.flush();
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
        if (self.repaint_handler) |handler| handler(self.repaint_context.?, .{
            .width = @floatFromInt(self.width),
            .height = @floatFromInt(self.height),
        });
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
                if (self.frame_handler) |handler| handler(self.frame_context.?);
            },
        }
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
            buffer.destroy(self.allocator);
            _ = self.buffers.swapRemove(index);
        }

        const buffer = try Buffer.create(self.allocator, self.shm, width, height);
        errdefer buffer.destroy(self.allocator);
        try self.buffers.append(self.allocator, buffer);
        return buffer;
    }

    fn createShellRole(
        surface: *wl.Surface,
        wm_base: ?*xdg.WmBase,
        layer_shell: ?*zwlr.LayerShellV1,
        options: Options,
    ) !ShellRole {
        if (options.layer_shell) |layer_options| {
            const shell = layer_shell orelse return error.NoLayerShell;
            const layer_surface = try shell.getLayerSurface(surface, null, layer(layer_options.layer), layer_options.namespace);
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
                }
            },
            .global_remove => {},
        }
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
                self.notifyRepaint();
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
                self.notifyRepaint();
            },
            .closed => self.closed = true,
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
) !void {
    @memset(pixels, @as(u32, @bitCast(keywork.colors.panel)));
    for (commands) |command| {
        switch (command) {
            .fill_rect => |fill| fillRect(pixels, width, height, scale, fill.rect, fill.color),
            .text => |text| try renderer.render(pixels, width, height, scale, text),
            .alpha_image => |image| alphaImage(pixels, width, height, scale, image),
        }
    }
}

fn fillRect(pixels: []u32, width: u31, height: u31, scale: f32, rect: keywork.Rect, color: keywork.Color) void {
    const x0 = clampPixel(@floor(rect.x * scale), width);
    const y0 = clampPixel(@floor(rect.y * scale), height);
    const x1 = clampPixel(@ceil((rect.x + rect.width) * scale), width);
    const y1 = clampPixel(@ceil((rect.y + rect.height) * scale), height);
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
) void {
    if (image.width == 0 or image.height == 0) return;
    const image_width: usize = @intCast(image.width);
    const image_height: usize = @intCast(image.height);
    const dst_x0 = clampPixel(@floor(image.rect.x * scale), width);
    const dst_y0 = clampPixel(@floor(image.rect.y * scale), height);
    const dst_x1 = @min(dst_x0 + image_width, width);
    const dst_y1 = @min(dst_y0 + image_height, height);
    if (dst_x0 >= dst_x1 or dst_y0 >= dst_y1) return;

    var row: usize = 0;
    while (dst_y0 + row < dst_y1) : (row += 1) {
        var column: usize = 0;
        while (dst_x0 + column < dst_x1) : (column += 1) {
            const coverage = image.alpha[row * image_width + column];
            if (coverage == 0) continue;
            blendPixel(pixels, width, dst_x0 + column, dst_y0 + row, image.color, coverage);
        }
    }
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
