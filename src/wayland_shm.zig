//! Minimal `wl_shm` render backend for Keywork display lists.

const std = @import("std");
const event_loop = @import("event_loop.zig");
const keywork = @import("root");
const TextRenderer = @import("text_renderer.zig");
const wayland = @import("wayland");
const xkb = @import("xkb_c");

const linux = std.os.linux;
const posix = std.posix;
const wp = wayland.client.wp;
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;

const log = std.log.scoped(.keywork_wayland_shm);

pub const Backend = struct {
    allocator: std.mem.Allocator,
    display: *wl.Display,
    registry: *wl.Registry,
    compositor: *wl.Compositor,
    shm: *wl.Shm,
    wm_base: *xdg.WmBase,
    viewporter: ?*wp.Viewporter,
    fractional_scale_manager: ?*wp.FractionalScaleManagerV1,
    seat: ?*wl.Seat,
    pointer: ?*wl.Pointer,
    keyboard: ?*wl.Keyboard,
    xkb_context: ?*xkb.struct_xkb_context,
    xkb_keymap: ?*xkb.struct_xkb_keymap,
    xkb_state: ?*xkb.struct_xkb_state,
    surface: *wl.Surface,
    viewport: ?*wp.Viewport,
    fractional_scale: ?*wp.FractionalScaleV1,
    xdg_surface: *xdg.Surface,
    toplevel: *xdg.Toplevel,
    buffers: std.ArrayList(*Buffer),
    text_renderer: TextRenderer,
    configured: bool,
    closed: bool,
    width: u31,
    height: u31,
    scale: f32,
    scale_changed: bool,
    pointer_position: ?keywork.Point,
    shift_down: bool,
    repeat_timer: ?*event_loop.EventLoop.Timer,
    repeat_key: ?u32,
    repeat_input: ?keywork.KeyInput,
    repeat_text_buffer: [64]u8,
    key_text_buffer: [64]u8,
    repeat_delay_ms: u64,
    repeat_interval_ms: u64,
    click_handler: ?ClickHandler,
    click_context: ?*anyopaque,
    key_handler: ?KeyHandler,
    key_context: ?*anyopaque,
    repaint_handler: ?RepaintHandler,
    repaint_context: ?*anyopaque,

    pub const ClickHandler = *const fn (ctx: *anyopaque, point: keywork.Point) void;
    pub const KeyHandler = *const fn (ctx: *anyopaque, input: keywork.KeyInput) void;
    pub const RepaintHandler = *const fn (ctx: *anyopaque) void;

    pub const Options = struct {
        title: [:0]const u8 = "Keywork",
        app_id: [:0]const u8 = "dev.keywork.Keywork",
        width: u31 = 640,
        height: u31 = 480,
    };

    const Globals = struct {
        compositor: ?*wl.Compositor = null,
        shm: ?*wl.Shm = null,
        wm_base: ?*xdg.WmBase = null,
        viewporter: ?*wp.Viewporter = null,
        fractional_scale_manager: ?*wp.FractionalScaleManagerV1 = null,
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
        const wm_base = globals.wm_base orelse return error.NoXdgWmBase;
        const viewporter = globals.viewporter;
        const fractional_scale_manager = globals.fractional_scale_manager;
        const pointer = if (globals.seat) |seat| pointer: {
            break :pointer seat.getPointer() catch null;
        } else null;
        const keyboard = if (globals.seat) |seat| keyboard: {
            break :keyboard seat.getKeyboard() catch null;
        } else null;

        const surface = try compositor.createSurface();
        errdefer surface.destroy();
        const xdg_surface = try wm_base.getXdgSurface(surface);
        errdefer xdg_surface.destroy();
        const toplevel = try xdg_surface.getToplevel();
        errdefer toplevel.destroy();
        toplevel.setAppId(options.app_id);
        toplevel.setTitle(options.title);
        const viewport = if (viewporter) |manager| try manager.getViewport(surface) else null;
        errdefer if (viewport) |surface_viewport| surface_viewport.destroy();
        const fractional_scale = if (fractional_scale_manager) |manager| try manager.getFractionalScale(surface) else null;
        errdefer if (fractional_scale) |surface_scale| surface_scale.destroy();

        var text_renderer_instance = try TextRenderer.init(allocator);
        errdefer text_renderer_instance.deinit();
        const xkb_context = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS) orelse return error.XkbContextFailed;
        errdefer xkb.xkb_context_unref(xkb_context);

        const self = try allocator.create(Backend);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .display = display,
            .registry = registry,
            .compositor = compositor,
            .shm = shm,
            .wm_base = wm_base,
            .viewporter = viewporter,
            .fractional_scale_manager = fractional_scale_manager,
            .seat = globals.seat,
            .pointer = pointer,
            .keyboard = keyboard,
            .xkb_context = xkb_context,
            .xkb_keymap = null,
            .xkb_state = null,
            .surface = surface,
            .viewport = viewport,
            .fractional_scale = fractional_scale,
            .xdg_surface = xdg_surface,
            .toplevel = toplevel,
            .buffers = .empty,
            .text_renderer = text_renderer_instance,
            .configured = false,
            .closed = false,
            .width = options.width,
            .height = options.height,
            .scale = 1,
            .scale_changed = false,
            .pointer_position = null,
            .shift_down = false,
            .repeat_timer = null,
            .repeat_key = null,
            .repeat_input = null,
            .repeat_text_buffer = undefined,
            .key_text_buffer = undefined,
            .repeat_delay_ms = 0,
            .repeat_interval_ms = 0,
            .click_handler = null,
            .click_context = null,
            .key_handler = null,
            .key_context = null,
            .repaint_handler = null,
            .repaint_context = null,
        };

        wm_base.setListener(*Backend, wmBaseListener, self);
        xdg_surface.setListener(*Backend, xdgSurfaceListener, self);
        toplevel.setListener(*Backend, toplevelListener, self);
        if (fractional_scale) |surface_scale| surface_scale.setListener(*Backend, fractionalScaleListener, self);
        if (globals.seat) |seat| seat.setListener(*Backend, seatListener, self);
        if (pointer) |wl_pointer| wl_pointer.setListener(*Backend, pointerListener, self);
        if (keyboard) |wl_keyboard| wl_keyboard.setListener(*Backend, keyboardListener, self);
        surface.commit();

        return self;
    }

    pub fn destroy(self: *Backend) void {
        for (self.buffers.items) |buffer| buffer.destroy(self.allocator);
        self.buffers.deinit(self.allocator);
        self.text_renderer.deinit();
        self.clearXkbKeymap();
        if (self.xkb_context) |context| xkb.xkb_context_unref(context);
        if (self.pointer) |pointer| pointer.release();
        if (self.keyboard) |keyboard| keyboard.release();
        if (self.seat) |seat| seat.release();
        if (self.fractional_scale) |fractional_scale| fractional_scale.destroy();
        if (self.viewport) |viewport| viewport.destroy();
        self.toplevel.destroy();
        self.xdg_surface.destroy();
        self.surface.destroy();
        if (self.fractional_scale_manager) |manager| manager.destroy();
        if (self.viewporter) |viewporter| viewporter.destroy();
        self.wm_base.destroy();
        self.shm.destroy();
        self.compositor.destroy();
        self.registry.destroy();
        self.display.disconnect();
        self.allocator.destroy(self);
    }

    pub fn renderBackend(self: *Backend) keywork.RenderBackend {
        return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText } };
    }

    pub fn setClickHandler(self: *Backend, context: *anyopaque, handler: ClickHandler) void {
        self.click_context = context;
        self.click_handler = handler;
    }

    pub fn setKeyHandler(self: *Backend, context: *anyopaque, handler: KeyHandler) void {
        self.key_context = context;
        self.key_handler = handler;
    }

    pub fn installKeyRepeat(self: *Backend, loop: *event_loop.EventLoop) !void {
        if (self.repeat_timer != null) return;
        self.repeat_timer = try loop.addTimer(self, repeatTimerCallback);
    }

    pub fn uninstallKeyRepeat(self: *Backend) void {
        self.stopKeyRepeat();
        self.repeat_timer = null;
    }

    pub fn setRepaintHandler(self: *Backend, context: *anyopaque, handler: RepaintHandler) void {
        self.repaint_context = context;
        self.repaint_handler = handler;
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
            if (self.repaint_handler) |handler| handler(self.repaint_context.?);
        }
        return !self.closed;
    }

    fn present(ptr: *anyopaque, frame: keywork.RenderBackend.Frame) !void {
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

        self.surface.attach(buffer.wl_buffer, 0, 0);
        self.surface.damageBuffer(0, 0, width, height);
        self.surface.setBufferScale(1);
        if (self.viewport) |viewport| viewport.setDestination(logical_width, logical_height);
        self.surface.commit();
        buffer.busy = true;
        _ = self.display.flush();
    }

    fn measureText(ptr: *anyopaque, value: []const u8) !keywork.Size {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        return self.text_renderer.measure(self.scale, value);
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

    fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, globals: *Globals) void {
        switch (event) {
            .global => |global| {
                if (std.mem.orderZ(u8, global.interface, wl.Compositor.interface.name) == .eq) {
                    globals.compositor = registry.bind(global.name, wl.Compositor, 4) catch return;
                } else if (std.mem.orderZ(u8, global.interface, wl.Shm.interface.name) == .eq) {
                    globals.shm = registry.bind(global.name, wl.Shm, 1) catch return;
                } else if (std.mem.orderZ(u8, global.interface, xdg.WmBase.interface.name) == .eq) {
                    globals.wm_base = registry.bind(global.name, xdg.WmBase, @min(global.version, 6)) catch return;
                } else if (std.mem.orderZ(u8, global.interface, wp.Viewporter.interface.name) == .eq) {
                    globals.viewporter = registry.bind(global.name, wp.Viewporter, 1) catch return;
                } else if (std.mem.orderZ(u8, global.interface, wp.FractionalScaleManagerV1.interface.name) == .eq) {
                    globals.fractional_scale_manager = registry.bind(global.name, wp.FractionalScaleManagerV1, 1) catch return;
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

    fn seatListener(seat: *wl.Seat, event: wl.Seat.Event, self: *Backend) void {
        switch (event) {
            .capabilities => |caps| {
                if (caps.capabilities.pointer and self.pointer == null) {
                    self.pointer = seat.getPointer() catch null;
                    if (self.pointer) |pointer| pointer.setListener(*Backend, pointerListener, self);
                } else if (!caps.capabilities.pointer and self.pointer != null) {
                    self.pointer.?.release();
                    self.pointer = null;
                    self.pointer_position = null;
                }
                if (caps.capabilities.keyboard and self.keyboard == null) {
                    self.keyboard = seat.getKeyboard() catch null;
                    if (self.keyboard) |keyboard| keyboard.setListener(*Backend, keyboardListener, self);
                } else if (!caps.capabilities.keyboard and self.keyboard != null) {
                    self.keyboard.?.release();
                    self.keyboard = null;
                    self.shift_down = false;
                    self.stopKeyRepeat();
                    self.clearXkbKeymap();
                }
            },
            .name => {},
        }
    }

    fn pointerListener(_: *wl.Pointer, event: wl.Pointer.Event, self: *Backend) void {
        switch (event) {
            .enter => |enter| {
                if (enter.surface != self.surface) return;
                self.pointer_position = .{ .x = @floatCast(enter.surface_x.toDouble()), .y = @floatCast(enter.surface_y.toDouble()) };
            },
            .leave => self.pointer_position = null,
            .motion => |motion| {
                self.pointer_position = .{ .x = @floatCast(motion.surface_x.toDouble()), .y = @floatCast(motion.surface_y.toDouble()) };
            },
            .button => |button| {
                if (button.button == 272 and button.state == .pressed) {
                    if (self.pointer_position) |point| {
                        if (self.click_handler) |handler| handler(self.click_context.?, point);
                    }
                }
            },
            else => {},
        }
    }

    fn keyboardListener(_: *wl.Keyboard, event: wl.Keyboard.Event, self: *Backend) void {
        switch (event) {
            .keymap => |keymap| self.installXkbKeymap(keymap),
            .enter => |enter| {
                if (enter.surface != self.surface) {
                    self.shift_down = false;
                    self.stopKeyRepeat();
                }
            },
            .leave => {
                self.shift_down = false;
                self.stopKeyRepeat();
            },
            .key => |key| {
                const pressed = key.state == .pressed;
                switch (key.key) {
                    42, 54 => {
                        self.shift_down = pressed;
                        return;
                    },
                    else => {},
                }
                if (!pressed) {
                    if (self.repeat_key == key.key) self.stopKeyRepeat();
                    return;
                }
                const input = self.keyInputFromWaylandKey(key.key) orelse return;
                self.dispatchKeyInput(input);
                self.startKeyRepeat(key.key, input);
            },
            .modifiers => |modifiers| {
                if (self.xkb_state) |state| {
                    _ = xkb.xkb_state_update_mask(
                        state,
                        modifiers.mods_depressed,
                        modifiers.mods_latched,
                        modifiers.mods_locked,
                        0,
                        0,
                        modifiers.group,
                    );
                }
            },
            .repeat_info => |repeat_info| self.setRepeatInfo(repeat_info.rate, repeat_info.delay),
        }
    }

    fn installXkbKeymap(self: *Backend, keymap: @TypeOf(@as(wl.Keyboard.Event, undefined).keymap)) void {
        defer _ = linux.close(keymap.fd);
        if (keymap.format != .xkb_v1 or keymap.size == 0) {
            self.clearXkbKeymap();
            return;
        }

        const bytes = posix.mmap(
            null,
            keymap.size,
            .{ .READ = true },
            .{ .TYPE = .PRIVATE },
            keymap.fd,
            0,
        ) catch |err| {
            log.warn("failed to mmap XKB keymap: {}", .{err});
            self.clearXkbKeymap();
            return;
        };
        defer posix.munmap(bytes);

        const context = self.xkb_context orelse return;
        const new_keymap = xkb.xkb_keymap_new_from_buffer(
            context,
            @ptrCast(bytes.ptr),
            keymap.size,
            xkb.XKB_KEYMAP_FORMAT_TEXT_V1,
            xkb.XKB_KEYMAP_COMPILE_NO_FLAGS,
        ) orelse {
            log.warn("failed to compile XKB keymap", .{});
            self.clearXkbKeymap();
            return;
        };
        errdefer xkb.xkb_keymap_unref(new_keymap);

        const new_state = xkb.xkb_state_new(new_keymap) orelse {
            log.warn("failed to create XKB state", .{});
            self.clearXkbKeymap();
            return;
        };

        self.clearXkbKeymap();
        self.xkb_keymap = new_keymap;
        self.xkb_state = new_state;
    }

    fn clearXkbKeymap(self: *Backend) void {
        self.stopKeyRepeat();
        if (self.xkb_state) |state| xkb.xkb_state_unref(state);
        if (self.xkb_keymap) |keymap| xkb.xkb_keymap_unref(keymap);
        self.xkb_state = null;
        self.xkb_keymap = null;
    }

    fn keyInputFromWaylandKey(self: *Backend, key: u32) ?keywork.KeyInput {
        const state = self.xkb_state orelse return keyInputFromEvdev(key, self.shift_down);
        const keycode: xkb.xkb_keycode_t = key + 8;
        const keysym = xkb.xkb_state_key_get_one_sym(state, keycode);
        switch (keysym) {
            xkb.XKB_KEY_BackSpace => return .backspace,
            xkb.XKB_KEY_Return, xkb.XKB_KEY_KP_Enter => return .enter,
            else => {},
        }

        const written = xkb.xkb_state_key_get_utf8(
            state,
            keycode,
            &self.key_text_buffer,
            self.key_text_buffer.len,
        );
        if (written <= 0) return null;
        const len: usize = @intCast(written);
        if (len >= self.key_text_buffer.len) return null;
        return .{ .text = self.key_text_buffer[0..len] };
    }

    fn setRepeatInfo(self: *Backend, rate: i32, delay: i32) void {
        std.debug.assert(delay >= 0);
        if (rate <= 0) {
            self.repeat_interval_ms = 0;
            self.repeat_delay_ms = 0;
            self.stopKeyRepeat();
            return;
        }

        const rate_per_second: u64 = @intCast(rate);
        self.repeat_delay_ms = @max(1, @as(u64, @intCast(delay)));
        self.repeat_interval_ms = @max(1, 1000 / rate_per_second);
        if (self.repeat_key != null) {
            if (self.repeat_timer) |timer| timer.arm(self.repeat_interval_ms, self.repeat_interval_ms) catch |err| {
                log.warn("failed to update key repeat timer: {}", .{err});
                self.stopKeyRepeat();
            };
        }
    }

    fn dispatchKeyInput(self: *Backend, input: keywork.KeyInput) void {
        if (self.key_handler) |handler| handler(self.key_context.?, input);
    }

    fn startKeyRepeat(self: *Backend, key: u32, input: keywork.KeyInput) void {
        if (!inputCanRepeat(input) or self.repeat_interval_ms == 0) return;
        const timer = self.repeat_timer orelse return;
        self.repeat_key = key;
        self.repeat_input = self.storedRepeatInput(input) orelse return;
        timer.arm(self.repeat_delay_ms, self.repeat_interval_ms) catch |err| {
            log.warn("failed to arm key repeat timer: {}", .{err});
            self.stopKeyRepeat();
        };
    }

    fn storedRepeatInput(self: *Backend, input: keywork.KeyInput) ?keywork.KeyInput {
        return switch (input) {
            .text => |bytes| {
                if (bytes.len > self.repeat_text_buffer.len) return null;
                @memcpy(self.repeat_text_buffer[0..bytes.len], bytes);
                return .{ .text = self.repeat_text_buffer[0..bytes.len] };
            },
            .backspace => .backspace,
            .enter => null,
        };
    }

    fn stopKeyRepeat(self: *Backend) void {
        if (self.repeat_timer) |timer| timer.disarm();
        self.repeat_key = null;
        self.repeat_input = null;
    }

    fn repeatTimerCallback(ctx: *anyopaque, _: *event_loop.EventLoop, expirations: u64) !void {
        const self: *Backend = @ptrCast(@alignCast(ctx));
        const input = self.repeat_input orelse return;
        var remaining = expirations;
        while (remaining > 0) : (remaining -= 1) {
            self.dispatchKeyInput(input);
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
) !void {
    @memset(pixels, @as(u32, @bitCast(keywork.colors.panel)));
    for (commands) |command| {
        switch (command) {
            .fill_rect => |fill| fillRect(pixels, width, height, scale, fill.rect, fill.color),
            .text => |text| try renderer.render(pixels, width, height, scale, text),
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

fn keyInputFromEvdev(key: u32, shift: bool) ?keywork.KeyInput {
    return switch (key) {
        14 => .backspace,
        28 => .enter,
        57 => .{ .text = " " },
        2...11 => .{ .text = digitFromKey(key, shift) },
        16 => .{ .text = if (shift) "Q" else "q" },
        17 => .{ .text = if (shift) "W" else "w" },
        18 => .{ .text = if (shift) "E" else "e" },
        19 => .{ .text = if (shift) "R" else "r" },
        20 => .{ .text = if (shift) "T" else "t" },
        21 => .{ .text = if (shift) "Y" else "y" },
        22 => .{ .text = if (shift) "U" else "u" },
        23 => .{ .text = if (shift) "I" else "i" },
        24 => .{ .text = if (shift) "O" else "o" },
        25 => .{ .text = if (shift) "P" else "p" },
        30 => .{ .text = if (shift) "A" else "a" },
        31 => .{ .text = if (shift) "S" else "s" },
        32 => .{ .text = if (shift) "D" else "d" },
        33 => .{ .text = if (shift) "F" else "f" },
        34 => .{ .text = if (shift) "G" else "g" },
        35 => .{ .text = if (shift) "H" else "h" },
        36 => .{ .text = if (shift) "J" else "j" },
        37 => .{ .text = if (shift) "K" else "k" },
        38 => .{ .text = if (shift) "L" else "l" },
        44 => .{ .text = if (shift) "Z" else "z" },
        45 => .{ .text = if (shift) "X" else "x" },
        46 => .{ .text = if (shift) "C" else "c" },
        47 => .{ .text = if (shift) "V" else "v" },
        48 => .{ .text = if (shift) "B" else "b" },
        49 => .{ .text = if (shift) "N" else "n" },
        50 => .{ .text = if (shift) "M" else "m" },
        12 => .{ .text = if (shift) "_" else "-" },
        13 => .{ .text = if (shift) "+" else "=" },
        26 => .{ .text = if (shift) "{" else "[" },
        27 => .{ .text = if (shift) "}" else "]" },
        39 => .{ .text = if (shift) ":" else ";" },
        40 => .{ .text = if (shift) "\"" else "'" },
        41 => .{ .text = if (shift) "~" else "`" },
        43 => .{ .text = if (shift) "|" else "\\" },
        51 => .{ .text = if (shift) "<" else "," },
        52 => .{ .text = if (shift) ">" else "." },
        53 => .{ .text = if (shift) "?" else "/" },
        else => null,
    };
}

fn inputCanRepeat(input: keywork.KeyInput) bool {
    return switch (input) {
        .text, .backspace => true,
        .enter => false,
    };
}

fn digitFromKey(key: u32, shift: bool) []const u8 {
    if (shift) {
        return switch (key) {
            2 => "!",
            3 => "@",
            4 => "#",
            5 => "$",
            6 => "%",
            7 => "^",
            8 => "&",
            9 => "*",
            10 => "(",
            11 => ")",
            else => unreachable,
        };
    }
    return switch (key) {
        2 => "1",
        3 => "2",
        4 => "3",
        5 => "4",
        6 => "5",
        7 => "6",
        8 => "7",
        9 => "8",
        10 => "9",
        11 => "0",
        else => unreachable,
    };
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
