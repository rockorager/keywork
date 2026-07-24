//! Output presented as a window on a parent Wayland compositor.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const presentation = @import("../presentation.zig");
const render = @import("../render/types.zig");

const client = wayland.client;
const wl = client.wl;
const xdg = client.xdg;
const wp = client.wp;
const zwp = client.zwp;
const server_wl = wayland.server.wl;

const buffer_count = 3;
const scale_roundtrip_limit = 8;
const max_render_scale_120 = 480;

const SeatGlobal = struct {
    name: u32,
    version: u32,
};

io: std.Io,
display: ?*wl.Display,
registry: ?*wl.Registry,
compositor: ?*wl.Compositor,
shm: ?*wl.Shm,
wm_base: ?*xdg.WmBase,
viewporter: ?*wp.Viewporter,
fractional_scale_manager: ?*wp.FractionalScaleManagerV1,
presentation_manager: ?*wp.Presentation,
relative_pointer_manager: ?*zwp.RelativePointerManagerV1,
presentation_clock_id: ?u32,
seat_global: ?SeatGlobal,
seat: ?*wl.Seat,
keyboard: ?*wl.Keyboard,
pointer: ?*wl.Pointer,
relative_pointer: ?*zwp.RelativePointerV1,
touch: ?*wl.Touch,
surface: ?*wl.Surface,
viewport: ?*wp.Viewport,
fractional_scale: ?*wp.FractionalScaleV1,
xdg_surface: ?*xdg.Surface,
toplevel: ?*xdg.Toplevel,
frame_callback: ?*wl.Callback,
presentation_feedback: ?*wp.PresentationFeedback,
event_source: ?*server_wl.EventSource,
mapping: ?[]align(std.heap.page_size_min) u8,
buffers: [buffer_count]Buffer,
size: render.Size,
buffer_size: render.Size,
render_scale: render.Scale,
client_scale: u32,
preferred_scale_received: bool,
scale_locked: bool,
listener: Listener,
acquired: ?usize,
configured: bool,
failed: bool,

pub const Listener = struct {
    context: *anyopaque,
    ready: *const fn (*anyopaque) void,
    presented: *const fn (*anyopaque, presentation.Info) void,
    discarded: *const fn (*anyopaque) void,
    close: *const fn (*anyopaque) void,
    keyboard_available: *const fn (*anyopaque, bool) void,
    keyboard_keymap: *const fn (*anyopaque, wl.Keyboard.KeymapFormat, std.posix.fd_t, u32) void,
    keyboard_enter: *const fn (*anyopaque, []const u32) void,
    keyboard_leave: *const fn (*anyopaque) void,
    keyboard_key: *const fn (*anyopaque, u32, u32, wl.Keyboard.KeyState) void,
    keyboard_modifiers: *const fn (*anyopaque, u32, u32, u32, u32) void,
    keyboard_repeat_info: *const fn (*anyopaque, i32, i32) void,
    pointer_available: *const fn (*anyopaque, bool) void,
    pointer_enter: *const fn (*anyopaque, f64, f64) void,
    pointer_leave: *const fn (*anyopaque) void,
    pointer_motion: *const fn (*anyopaque, u32, f64, f64) void,
    pointer_relative_motion: *const fn (*anyopaque, u64, f64, f64, f64, f64) void,
    pointer_button: *const fn (*anyopaque, u32, u32, wl.Pointer.ButtonState) void,
    pointer_axis: *const fn (*anyopaque, u32, wl.Pointer.Axis, wl.Fixed) void,
    pointer_frame: *const fn (*anyopaque) void,
    pointer_axis_source: *const fn (*anyopaque, wl.Pointer.AxisSource) void,
    pointer_axis_stop: *const fn (*anyopaque, u32, wl.Pointer.Axis) void,
    pointer_axis_discrete: *const fn (*anyopaque, wl.Pointer.Axis, i32) void,
    pointer_axis_value120: *const fn (*anyopaque, wl.Pointer.Axis, i32) void,
    pointer_axis_relative_direction: *const fn (
        *anyopaque,
        wl.Pointer.Axis,
        wl.Pointer.AxisRelativeDirection,
    ) void,
    touch_available: *const fn (*anyopaque, bool) void,
    touch_down: *const fn (*anyopaque, u32, i32, f64, f64) void,
    touch_up: *const fn (*anyopaque, u32, i32) void,
    touch_motion: *const fn (*anyopaque, u32, i32, f64, f64) void,
    touch_frame: *const fn (*anyopaque) void,
    touch_cancel: *const fn (*anyopaque) void,
    touch_shape: *const fn (*anyopaque, i32, f64, f64) void,
    touch_orientation: *const fn (*anyopaque, i32, f64) void,
};

const Buffer = struct {
    owner: *Self,
    resource: ?*wl.Buffer,
    pixels: []u32,
    busy: bool,

    fn handleEvent(_: *wl.Buffer, event: wl.Buffer.Event, self: *Buffer) void {
        switch (event) {
            .release => {
                std.debug.assert(self.busy);
                self.busy = false;
                self.owner.notifyReady();
            },
        }
    }
};

/// Copies the listener and retains its context until deinit.
pub fn init(
    self: *Self,
    io: std.Io,
    child_display: *server_wl.Server,
    size: render.Size,
    listener: Listener,
) !void {
    if (size.width == 0 or size.height == 0 or
        size.width > std.math.maxInt(i32) or size.height > std.math.maxInt(i32))
    {
        return error.InvalidDimensions;
    }

    self.* = .{
        .io = io,
        .display = null,
        .registry = null,
        .compositor = null,
        .shm = null,
        .wm_base = null,
        .viewporter = null,
        .fractional_scale_manager = null,
        .presentation_manager = null,
        .relative_pointer_manager = null,
        .presentation_clock_id = null,
        .seat_global = null,
        .seat = null,
        .keyboard = null,
        .pointer = null,
        .relative_pointer = null,
        .touch = null,
        .surface = null,
        .viewport = null,
        .fractional_scale = null,
        .xdg_surface = null,
        .toplevel = null,
        .frame_callback = null,
        .presentation_feedback = null,
        .event_source = null,
        .mapping = null,
        .buffers = undefined,
        .size = size,
        .buffer_size = size,
        .render_scale = .{},
        .client_scale = 1,
        .preferred_scale_received = false,
        .scale_locked = false,
        .listener = listener,
        .acquired = null,
        .configured = false,
        .failed = false,
    };
    for (&self.buffers) |*buffer| {
        buffer.* = .{
            .owner = self,
            .resource = null,
            .pixels = &.{},
            .busy = false,
        };
    }
    errdefer self.deinit();

    const display = try wl.Display.connect(null);
    self.display = display;
    const registry = try display.getRegistry();
    self.registry = registry;
    registry.setListener(*Self, handleRegistryEvent, self);
    if (display.roundtrip() != .SUCCESS) return error.ParentDisplayFailed;
    if (self.compositor == null or self.shm == null or self.wm_base == null) {
        return error.MissingParentGlobal;
    }
    if (self.presentation_manager != null) {
        if (display.roundtrip() != .SUCCESS) return error.ParentDisplayFailed;
        if (self.presentation_clock_id == null) return error.ParentDisplayFailed;
    }

    const surface = try self.compositor.?.createSurface();
    self.surface = surface;
    if (self.viewporter != null and self.fractional_scale_manager != null) {
        const viewport = try self.viewporter.?.getViewport(surface);
        self.viewport = viewport;
        viewport.setDestination(@intCast(size.width), @intCast(size.height));
        const fractional_scale = try self.fractional_scale_manager.?.getFractionalScale(surface);
        self.fractional_scale = fractional_scale;
        fractional_scale.setListener(*Self, handleFractionalScaleEvent, self);
    }
    const xdg_surface = try self.wm_base.?.getXdgSurface(surface);
    self.xdg_surface = xdg_surface;
    xdg_surface.setListener(*Self, handleXdgSurfaceEvent, self);
    const toplevel = try xdg_surface.getToplevel();
    self.toplevel = toplevel;
    toplevel.setListener(*Self, handleToplevelEvent, self);
    toplevel.setTitle("Keywork Compositor");
    toplevel.setMinSize(@intCast(size.width), @intCast(size.height));
    toplevel.setMaxSize(@intCast(size.width), @intCast(size.height));

    surface.commit();
    while (!self.configured) {
        if (display.dispatch() != .SUCCESS) return error.ParentDisplayFailed;
        if (self.failed) return error.ParentDisplayFailed;
    }
    if (self.fractional_scale != null) try self.negotiateScale(io);
    self.buffer_size = self.render_scale.apply(size) catch return error.InvalidDimensions;
    try self.createBuffers(io);

    self.event_source = try child_display.getEventLoop().addFd(
        *Self,
        display.getFd(),
        .{ .readable = true },
        handleParentFd,
        self,
    );
}

/// Starts parent input forwarding after the child compositor has initialized
/// every subsystem reachable from the output listener.
pub fn startInput(self: *Self) !void {
    const registry = self.registry orelse return;
    if (self.seat_global) |global| {
        const seat = try registry.bind(global.name, wl.Seat, global.version);
        self.seat = seat;
        seat.setListener(*Self, handleSeatEvent, self);
    }
    registry.destroy();
    self.registry = null;
    switch (self.display.?.flush()) {
        .SUCCESS => {},
        .AGAIN => try self.event_source.?.fdUpdate(.{ .readable = true, .writable = true }),
        else => return error.ParentDisplayFailed,
    }
}

pub fn deinit(self: *Self) void {
    if (self.event_source) |source| source.remove();
    if (self.presentation_feedback) |feedback| feedback.destroy();
    if (self.frame_callback) |callback| callback.destroy();
    self.destroyBuffers();
    if (self.toplevel) |toplevel| toplevel.destroy();
    if (self.xdg_surface) |xdg_surface| xdg_surface.destroy();
    if (self.fractional_scale) |fractional_scale| fractional_scale.destroy();
    if (self.viewport) |viewport| viewport.destroy();
    if (self.touch) |touch| releaseTouch(touch);
    if (self.surface) |surface| surface.destroy();
    if (self.relative_pointer) |relative_pointer| relative_pointer.destroy();
    if (self.pointer) |pointer| releasePointer(pointer);
    if (self.keyboard) |keyboard| releaseKeyboard(keyboard);
    if (self.seat) |seat| releaseSeat(seat);
    if (self.wm_base) |wm_base| wm_base.destroy();
    if (self.relative_pointer_manager) |manager| manager.destroy();
    if (self.presentation_manager) |manager| manager.destroy();
    if (self.fractional_scale_manager) |manager| manager.destroy();
    if (self.viewporter) |viewporter| viewporter.destroy();
    if (self.shm) |shm| {
        if (shm.getVersion() >= wl.Shm.release_since_version) {
            shm.release();
        } else {
            shm.destroy();
        }
    }
    if (self.compositor) |compositor| {
        if (compositor.getVersion() >= wl.Compositor.release_since_version) {
            compositor.release();
        } else {
            compositor.destroy();
        }
    }
    if (self.registry) |registry| registry.destroy();
    if (self.display) |display| display.disconnect();
    self.* = undefined;
}

pub fn acquire(self: *Self) ?render.PixelBuffer {
    std.debug.assert(self.acquired == null);
    if (!self.ready()) return null;
    for (&self.buffers, 0..) |*buffer, index| {
        if (buffer.busy) continue;
        self.acquired = index;
        return .{
            .size = self.buffer_size,
            .stride_pixels = self.buffer_size.width,
            .pixels = buffer.pixels,
        };
    }
    return null;
}

pub fn ready(self: *const Self) bool {
    if (!self.configured or self.failed or self.frame_callback != null or
        self.presentation_feedback != null) return false;
    for (&self.buffers) |buffer| {
        if (!buffer.busy) return true;
    }
    return false;
}

pub fn presentationClockId(self: *const Self) u32 {
    return self.presentation_clock_id orelse presentation.monotonic_clock_id;
}

pub fn cancel(self: *Self) void {
    self.acquired = null;
}

pub fn present(self: *Self) !void {
    std.debug.assert(self.frame_callback == null);
    std.debug.assert(self.presentation_feedback == null);
    const index = self.acquired orelse return error.NoAcquiredBuffer;
    const buffer = &self.buffers[index];
    const resource = buffer.resource orelse return error.ParentDisplayFailed;
    const surface = self.surface orelse return error.ParentDisplayFailed;

    const frame_callback = try surface.frame();
    self.frame_callback = frame_callback;
    errdefer {
        frame_callback.destroy();
        self.frame_callback = null;
    }
    frame_callback.setListener(*Self, handleFrameEvent, self);

    if (self.presentation_manager) |manager| {
        const feedback = try manager.feedback(surface);
        self.presentation_feedback = feedback;
        errdefer {
            feedback.destroy();
            self.presentation_feedback = null;
        }
        feedback.setListener(*Self, handlePresentationFeedbackEvent, self);
    }

    buffer.busy = true;
    self.acquired = null;
    surface.attach(resource, 0, 0);
    surface.damageBuffer(
        0,
        0,
        @intCast(self.buffer_size.width),
        @intCast(self.buffer_size.height),
    );
    surface.commit();
    switch (self.display.?.flush()) {
        .SUCCESS => {},
        .AGAIN => try self.event_source.?.fdUpdate(.{ .readable = true, .writable = true }),
        else => return error.ParentDisplayFailed,
    }
}

fn createBuffers(self: *Self, io: std.Io) !void {
    std.debug.assert(self.mapping == null);
    const pixel_count = try self.buffer_size.pixelCount();
    const buffer_bytes = std.math.mul(usize, pixel_count, @sizeOf(u32)) catch
        return error.Overflow;
    const mapping_bytes = std.math.mul(usize, buffer_bytes, buffer_count) catch
        return error.Overflow;
    if (mapping_bytes > std.math.maxInt(i32)) return error.Overflow;

    const fd = try std.posix.memfd_create("keywork-nested-output", 0);
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer file.close(io);
    try file.setLength(io, mapping_bytes);
    const mapping = try std.posix.mmap(
        null,
        mapping_bytes,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    self.mapping = mapping;
    @memset(mapping, 0);

    const pool = try self.shm.?.createPool(fd, @intCast(mapping_bytes));
    defer pool.destroy();
    for (&self.buffers, 0..) |*buffer, index| {
        const offset = index * buffer_bytes;
        const resource = try pool.createBuffer(
            @intCast(offset),
            @intCast(self.buffer_size.width),
            @intCast(self.buffer_size.height),
            @intCast(self.buffer_size.width * @sizeOf(u32)),
            .argb8888,
        );
        buffer.resource = resource;
        buffer.pixels = @as([*]u32, @ptrCast(@alignCast(mapping.ptr + offset)))[0..pixel_count];
        resource.setListener(*Buffer, Buffer.handleEvent, buffer);
    }
}

fn destroyBuffers(self: *Self) void {
    for (&self.buffers) |*buffer| {
        if (buffer.resource) |resource| resource.destroy();
        buffer.resource = null;
        buffer.pixels = &.{};
        buffer.busy = false;
    }
    if (self.mapping) |mapping| std.posix.munmap(mapping);
    self.mapping = null;
}

fn negotiateScale(self: *Self, io: std.Io) !void {
    self.buffer_size = .{ .width = 1, .height = 1 };
    try self.createBuffers(io);
    const buffer = &self.buffers[0];
    buffer.busy = true;
    const surface = self.surface orelse return error.ParentDisplayFailed;
    surface.attach(buffer.resource orelse return error.ParentDisplayFailed, 0, 0);
    surface.damageBuffer(0, 0, 1, 1);
    surface.commit();

    var roundtrips: usize = 0;
    while (!self.preferred_scale_received and roundtrips < scale_roundtrip_limit) {
        if (self.display.?.roundtrip() != .SUCCESS) return error.ParentDisplayFailed;
        if (self.failed) return error.ParentDisplayFailed;
        roundtrips += 1;
    }
    // Output scale and render buffers are fixed for this backend instance.
    self.scale_locked = true;
    self.destroyBuffers();
}

fn handleRegistryEvent(_: *wl.Registry, event: wl.Registry.Event, self: *Self) void {
    switch (event) {
        .global => |global| {
            const interface = std.mem.span(global.interface);
            if (std.mem.eql(u8, interface, std.mem.span(wl.Compositor.interface.name))) {
                if (self.compositor == null) {
                    self.compositor = self.registry.?.bind(
                        global.name,
                        wl.Compositor,
                        @min(global.version, wl.Compositor.generated_version),
                    ) catch {
                        self.failed = true;
                        return;
                    };
                }
            } else if (std.mem.eql(u8, interface, std.mem.span(wl.Shm.interface.name))) {
                if (self.shm == null) {
                    self.shm = self.registry.?.bind(
                        global.name,
                        wl.Shm,
                        @min(global.version, wl.Shm.generated_version),
                    ) catch {
                        self.failed = true;
                        return;
                    };
                }
            } else if (std.mem.eql(u8, interface, std.mem.span(xdg.WmBase.interface.name))) {
                if (self.wm_base == null) {
                    const wm_base = self.registry.?.bind(
                        global.name,
                        xdg.WmBase,
                        @min(global.version, xdg.WmBase.generated_version),
                    ) catch {
                        self.failed = true;
                        return;
                    };
                    self.wm_base = wm_base;
                    wm_base.setListener(*Self, handleWmBaseEvent, self);
                }
            } else if (std.mem.eql(u8, interface, std.mem.span(wp.Viewporter.interface.name))) {
                if (self.viewporter == null) {
                    self.viewporter = self.registry.?.bind(
                        global.name,
                        wp.Viewporter,
                        @min(global.version, wp.Viewporter.generated_version),
                    ) catch {
                        self.failed = true;
                        return;
                    };
                }
            } else if (std.mem.eql(
                u8,
                interface,
                std.mem.span(wp.FractionalScaleManagerV1.interface.name),
            )) {
                if (self.fractional_scale_manager == null) {
                    self.fractional_scale_manager = self.registry.?.bind(
                        global.name,
                        wp.FractionalScaleManagerV1,
                        @min(global.version, wp.FractionalScaleManagerV1.generated_version),
                    ) catch {
                        self.failed = true;
                        return;
                    };
                }
            } else if (std.mem.eql(u8, interface, std.mem.span(wp.Presentation.interface.name))) {
                if (self.presentation_manager == null) {
                    const manager = self.registry.?.bind(
                        global.name,
                        wp.Presentation,
                        @min(global.version, wp.Presentation.generated_version),
                    ) catch {
                        self.failed = true;
                        return;
                    };
                    self.presentation_manager = manager;
                    manager.setListener(*Self, handlePresentationEvent, self);
                }
            } else if (std.mem.eql(
                u8,
                interface,
                std.mem.span(zwp.RelativePointerManagerV1.interface.name),
            )) {
                if (self.relative_pointer_manager == null) {
                    self.relative_pointer_manager = self.registry.?.bind(
                        global.name,
                        zwp.RelativePointerManagerV1,
                        @min(global.version, zwp.RelativePointerManagerV1.generated_version),
                    ) catch {
                        self.failed = true;
                        return;
                    };
                    self.ensureRelativePointer();
                }
            } else if (std.mem.eql(u8, interface, std.mem.span(wl.Seat.interface.name))) {
                if (self.seat_global == null) self.seat_global = .{
                    .name = global.name,
                    .version = @min(global.version, wl.Seat.generated_version),
                };
            }
        },
        .global_remove => |removed| {
            if (self.seat_global) |global| {
                if (global.name == removed.name) self.seat_global = null;
            }
        },
    }
}

fn handlePresentationEvent(
    _: *wp.Presentation,
    event: wp.Presentation.Event,
    self: *Self,
) void {
    switch (event) {
        .clock_id => |clock| self.presentation_clock_id = clock.clk_id,
    }
}

fn handleFrameEvent(callback: *wl.Callback, event: wl.Callback.Event, self: *Self) void {
    switch (event) {
        .done => {
            std.debug.assert(self.frame_callback == callback);
            callback.destroy();
            self.frame_callback = null;
            if (self.presentation_manager == null) {
                self.listener.presented(self.listener.context, .now(self.io));
            }
            self.notifyReady();
        },
    }
}

fn handlePresentationFeedbackEvent(
    feedback: *wp.PresentationFeedback,
    event: wp.PresentationFeedback.Event,
    self: *Self,
) void {
    switch (event) {
        .sync_output => {},
        .presented => |presented| {
            std.debug.assert(self.presentation_feedback == feedback);
            feedback.destroy();
            self.presentation_feedback = null;
            self.listener.presented(self.listener.context, .{
                .timestamp = .{
                    .seconds = @as(u64, presented.tv_sec_hi) << 32 | presented.tv_sec_lo,
                    .nanoseconds = presented.tv_nsec,
                },
                .refresh_nanoseconds = presented.refresh,
                .sequence = @as(u64, presented.seq_hi) << 32 | presented.seq_lo,
                .flags = .{
                    .vsync = presented.flags.vsync,
                    .hardware_clock = presented.flags.hw_clock,
                    .hardware_completion = presented.flags.hw_completion,
                    // Child surfaces were composited into our parent buffer.
                    .zero_copy = false,
                },
            });
            self.notifyReady();
        },
        .discarded => {
            std.debug.assert(self.presentation_feedback == feedback);
            feedback.destroy();
            self.presentation_feedback = null;
            self.listener.discarded(self.listener.context);
            self.notifyReady();
        },
    }
}

fn handleFractionalScaleEvent(
    _: *wp.FractionalScaleV1,
    event: wp.FractionalScaleV1.Event,
    self: *Self,
) void {
    switch (event) {
        .preferred_scale => |preferred| {
            if (self.scale_locked or preferred.scale == 0) return;
            self.preferred_scale_received = true;
            self.render_scale.numerator = @min(preferred.scale, max_render_scale_120);
            self.client_scale = self.render_scale.ceil() catch 1;
        },
    }
}

fn ensureRelativePointer(self: *Self) void {
    if (self.relative_pointer != null) return;
    const manager = self.relative_pointer_manager orelse return;
    const pointer = self.pointer orelse return;
    const relative_pointer = manager.getRelativePointer(pointer) catch {
        self.fail();
        return;
    };
    self.relative_pointer = relative_pointer;
    relative_pointer.setListener(*Self, handleRelativePointerEvent, self);
}

fn handleSeatEvent(seat: *wl.Seat, event: wl.Seat.Event, self: *Self) void {
    switch (event) {
        .capabilities => |capabilities| {
            if (capabilities.capabilities.keyboard and self.keyboard == null) {
                const keyboard = seat.getKeyboard() catch {
                    self.fail();
                    return;
                };
                self.keyboard = keyboard;
                keyboard.setListener(*Self, handleKeyboardEvent, self);
            } else if (!capabilities.capabilities.keyboard) {
                if (self.keyboard) |keyboard| releaseKeyboard(keyboard);
                self.keyboard = null;
            }
            if (capabilities.capabilities.pointer and self.pointer == null) {
                const pointer = seat.getPointer() catch {
                    self.fail();
                    return;
                };
                self.pointer = pointer;
                pointer.setListener(*Self, handlePointerEvent, self);
                self.ensureRelativePointer();
            } else if (!capabilities.capabilities.pointer) {
                if (self.relative_pointer) |relative_pointer| relative_pointer.destroy();
                self.relative_pointer = null;
                if (self.pointer) |pointer| releasePointer(pointer);
                self.pointer = null;
            }
            if (capabilities.capabilities.touch and self.touch == null) {
                const touch = seat.getTouch() catch {
                    self.fail();
                    return;
                };
                self.touch = touch;
                touch.setListener(*Self, handleTouchEvent, self);
            } else if (!capabilities.capabilities.touch) {
                if (self.touch) |touch| releaseTouch(touch);
                self.touch = null;
            }
            self.listener.keyboard_available(
                self.listener.context,
                capabilities.capabilities.keyboard,
            );
            self.listener.pointer_available(
                self.listener.context,
                capabilities.capabilities.pointer,
            );
            self.listener.touch_available(
                self.listener.context,
                capabilities.capabilities.touch,
            );
        },
        .name => {},
    }
}

fn handlePointerEvent(pointer: *wl.Pointer, event: wl.Pointer.Event, self: *Self) void {
    switch (event) {
        .enter => |enter| {
            pointer.setCursor(enter.serial, null, 0, 0);
            self.listener.pointer_enter(
                self.listener.context,
                enter.surface_x.toDouble(),
                enter.surface_y.toDouble(),
            );
        },
        .leave => self.listener.pointer_leave(self.listener.context),
        .motion => |motion| self.listener.pointer_motion(
            self.listener.context,
            motion.time,
            motion.surface_x.toDouble(),
            motion.surface_y.toDouble(),
        ),
        .button => |button| self.listener.pointer_button(
            self.listener.context,
            button.time,
            button.button,
            button.state,
        ),
        .axis => |axis| self.listener.pointer_axis(
            self.listener.context,
            axis.time,
            axis.axis,
            axis.value,
        ),
        .frame => self.listener.pointer_frame(self.listener.context),
        .axis_source => |source| self.listener.pointer_axis_source(
            self.listener.context,
            source.axis_source,
        ),
        .axis_stop => |stop| self.listener.pointer_axis_stop(
            self.listener.context,
            stop.time,
            stop.axis,
        ),
        .axis_discrete => |discrete| self.listener.pointer_axis_discrete(
            self.listener.context,
            discrete.axis,
            discrete.discrete,
        ),
        .axis_value120 => |value| self.listener.pointer_axis_value120(
            self.listener.context,
            value.axis,
            value.value120,
        ),
        .axis_relative_direction => |relative| self.listener.pointer_axis_relative_direction(
            self.listener.context,
            relative.axis,
            relative.direction,
        ),
    }
}

fn handleRelativePointerEvent(
    _: *zwp.RelativePointerV1,
    event: zwp.RelativePointerV1.Event,
    self: *Self,
) void {
    switch (event) {
        .relative_motion => |motion| self.listener.pointer_relative_motion(
            self.listener.context,
            @as(u64, motion.utime_hi) << 32 | motion.utime_lo,
            motion.dx.toDouble(),
            motion.dy.toDouble(),
            motion.dx_unaccel.toDouble(),
            motion.dy_unaccel.toDouble(),
        ),
    }
}

fn handleKeyboardEvent(_: *wl.Keyboard, event: wl.Keyboard.Event, self: *Self) void {
    switch (event) {
        .keymap => |keymap| self.listener.keyboard_keymap(
            self.listener.context,
            keymap.format,
            keymap.fd,
            keymap.size,
        ),
        .enter => |enter| self.listener.keyboard_enter(
            self.listener.context,
            enter.keys.*.slice(u32),
        ),
        .leave => self.listener.keyboard_leave(self.listener.context),
        .key => |key| self.listener.keyboard_key(
            self.listener.context,
            key.time,
            key.key,
            key.state,
        ),
        .modifiers => |modifiers| self.listener.keyboard_modifiers(
            self.listener.context,
            modifiers.mods_depressed,
            modifiers.mods_latched,
            modifiers.mods_locked,
            modifiers.group,
        ),
        .repeat_info => |repeat| self.listener.keyboard_repeat_info(
            self.listener.context,
            repeat.rate,
            repeat.delay,
        ),
    }
}

fn handleTouchEvent(_: *wl.Touch, event: wl.Touch.Event, self: *Self) void {
    switch (event) {
        .down => |down| {
            if (down.surface == null or down.surface.? != self.surface) return;
            self.listener.touch_down(
                self.listener.context,
                down.time,
                down.id,
                down.x.toDouble(),
                down.y.toDouble(),
            );
        },
        .up => |up| self.listener.touch_up(
            self.listener.context,
            up.time,
            up.id,
        ),
        .motion => |motion| self.listener.touch_motion(
            self.listener.context,
            motion.time,
            motion.id,
            motion.x.toDouble(),
            motion.y.toDouble(),
        ),
        .frame => self.listener.touch_frame(self.listener.context),
        .cancel => self.listener.touch_cancel(self.listener.context),
        .shape => |shape| self.listener.touch_shape(
            self.listener.context,
            shape.id,
            shape.major.toDouble(),
            shape.minor.toDouble(),
        ),
        .orientation => |orientation| self.listener.touch_orientation(
            self.listener.context,
            orientation.id,
            orientation.orientation.toDouble(),
        ),
    }
}

fn releaseKeyboard(keyboard: *wl.Keyboard) void {
    if (keyboard.getVersion() >= wl.Keyboard.release_since_version) {
        keyboard.release();
    } else {
        keyboard.destroy();
    }
}

fn releasePointer(pointer: *wl.Pointer) void {
    if (pointer.getVersion() >= wl.Pointer.release_since_version) {
        pointer.release();
    } else {
        pointer.destroy();
    }
}

fn releaseTouch(touch: *wl.Touch) void {
    if (touch.getVersion() >= wl.Touch.release_since_version) {
        touch.release();
    } else {
        touch.destroy();
    }
}

fn releaseSeat(seat: *wl.Seat) void {
    if (seat.getVersion() >= wl.Seat.release_since_version) {
        seat.release();
    } else {
        seat.destroy();
    }
}

fn handleWmBaseEvent(wm_base: *xdg.WmBase, event: xdg.WmBase.Event, _: *Self) void {
    switch (event) {
        .ping => |ping| wm_base.pong(ping.serial),
    }
}

fn handleXdgSurfaceEvent(
    xdg_surface: *xdg.Surface,
    event: xdg.Surface.Event,
    self: *Self,
) void {
    switch (event) {
        .configure => |configure| {
            xdg_surface.ackConfigure(configure.serial);
            self.configured = true;
        },
    }
}

fn handleToplevelEvent(_: *xdg.Toplevel, event: xdg.Toplevel.Event, self: *Self) void {
    switch (event) {
        .configure, .configure_bounds, .wm_capabilities => {},
        .close => self.fail(),
    }
}

fn handleParentFd(_: c_int, mask: server_wl.EventMask, self: *Self) c_int {
    if (mask.hangup or mask.@"error") {
        self.fail();
        return 0;
    }
    const display = self.display orelse return 0;
    if (mask.writable) switch (display.flush()) {
        .SUCCESS => self.event_source.?.fdUpdate(.{ .readable = true }) catch self.fail(),
        .AGAIN => {},
        else => self.fail(),
    };
    if (mask.readable and display.dispatch() != .SUCCESS) self.fail();
    return 0;
}

fn fail(self: *Self) void {
    if (self.failed) return;
    self.failed = true;
    self.listener.close(self.listener.context);
}

fn notifyReady(self: *Self) void {
    if (self.ready()) self.listener.ready(self.listener.context);
}
