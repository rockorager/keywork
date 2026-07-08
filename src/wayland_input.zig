//! Shared Wayland seat, pointer, keyboard, XKB, and key-repeat handling.

const Self = @This();

const std = @import("std");
const Loop = @import("loop.zig").Loop;
const keywork = @import("core.zig");
const wayland = @import("wayland");
const xkb = @import("xkb_c");

const linux = std.os.linux;
const posix = std.posix;
const wp = wayland.client.wp;
const wl = wayland.client.wl;

const log = std.log.scoped(.keywork_wayland_input);

seat: ?*wl.Seat = null,
pointer: ?*wl.Pointer = null,
cursor_shape_manager: ?*wp.CursorShapeManagerV1 = null,
cursor_shape_device: ?*wp.CursorShapeDeviceV1 = null,
keyboard: ?*wl.Keyboard = null,
xkb_context: ?*xkb.struct_xkb_context = null,
xkb_keymap: ?*xkb.struct_xkb_keymap = null,
xkb_state: ?*xkb.struct_xkb_state = null,
pointer_position: ?keywork.Point = null,
pointer_enter_serial: ?u32 = null,
/// Pointer events accumulated until the wl_pointer.frame marker so one
/// logical group (e.g. a diagonal scroll or enter+motion) dispatches
/// once, with the group's final position.
pending_pointer: PendingPointer = .{},
cursor_shape: ?keywork.CursorShape = null,
shift_down: bool = false,
/// Kinetic scroll state: velocity is estimated from finger axis frames
/// and, once the fingers lift, a timer keeps scrolling the viewport
/// under the anchor point with exponential decay.
fling_timer: ?*Loop.Timer = null,
fling_active: bool = false,
fling_velocity_x: f32 = 0,
fling_velocity_y: f32 = 0,
fling_point: keywork.Point = .{ .x = 0, .y = 0 },
scroll_velocity_x: f32 = 0,
scroll_velocity_y: f32 = 0,
last_scroll_time_ms: ?u32 = null,
repeat_timer: ?*Loop.Timer = null,
repeat_key: ?u32 = null,
repeat_input: ?keywork.KeyInput = null,
repeat_text_buffer: [64]u8 = undefined,
key_text_buffer: [64]u8 = undefined,
repeat_delay_ms: u64 = 0,
repeat_interval_ms: u64 = 0,
pointer_button_handler: ?PointerButtonHandler = null,
pointer_button_context: ?*anyopaque = null,
pointer_move_handler: ?PointerMoveHandler = null,
pointer_move_context: ?*anyopaque = null,
cursor_shape_handler: ?CursorShapeHandler = null,
cursor_shape_context: ?*anyopaque = null,
key_handler: ?KeyHandler = null,
key_context: ?*anyopaque = null,
scroll_handler: ?ScrollHandler = null,
scroll_context: ?*anyopaque = null,

/// Multiplier for finger and continuous axis deltas. libinput's touchpad
/// deltas track finger travel 1:1, which feels sluggish for scrolling
/// content; toolkits conventionally boost them.
const touchpad_scroll_speed = 2.0;

/// Kinetic scroll tuning. Velocity decays exponentially per millisecond,
/// matching the feel of common toolkits.
const fling_decay_per_ms = 0.998;
const fling_interval_ms = 8;
/// Minimum finger velocity (px/s) at lift-off that starts a fling.
const fling_start_velocity = 150.0;
/// Fling stops once velocity decays below this (px/s).
const fling_min_velocity = 30.0;
const fling_max_velocity = 8000.0;
/// Weight of the newest frame in the velocity moving average.
const velocity_smoothing = 0.75;

const PendingPointer = struct {
    /// The pointer entered or moved; flush dispatches one move with the
    /// final position.
    moved: bool = false,
    /// The pointer left the surface.
    left: bool = false,
    buttons: [4]keywork.PointerButtonState = undefined,
    button_count: usize = 0,
    scroll_dx: f32 = 0,
    scroll_dy: f32 = 0,
    scrolled: bool = false,
    scroll_source: wl.Pointer.AxisSource = .wheel,
    /// Timestamp of the frame's axis events, for velocity estimation.
    scroll_time_ms: u32 = 0,
    /// The fingers lifted; flush may start a fling.
    scroll_stopped: bool = false,
};

pub const PointerButtonHandler = *const fn (ctx: *anyopaque, point: keywork.Point, state: keywork.PointerButtonState) void;
pub const PointerMoveHandler = *const fn (ctx: *anyopaque, point: ?keywork.Point) void;
pub const CursorShapeHandler = *const fn (ctx: *anyopaque, point: keywork.Point) keywork.CursorShape;
pub const KeyHandler = *const fn (ctx: *anyopaque, input: keywork.KeyInput) void;
pub const ScrollHandler = *const fn (ctx: *anyopaque, point: keywork.Point, dx: f32, dy: f32) void;

pub fn init(seat: ?*wl.Seat, cursor_shape_manager: ?*wp.CursorShapeManagerV1) !Self {
    const pointer = if (seat) |wl_seat| pointer: {
        break :pointer wl_seat.getPointer() catch null;
    } else null;
    const keyboard = if (seat) |wl_seat| keyboard: {
        break :keyboard wl_seat.getKeyboard() catch null;
    } else null;
    const xkb_context = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS) orelse return error.XkbContextFailed;

    var self: Self = .{
        .seat = seat,
        .pointer = pointer,
        .cursor_shape_manager = cursor_shape_manager,
        .keyboard = keyboard,
        .xkb_context = xkb_context,
    };
    self.createCursorShapeDevice();
    return self;
}

pub fn deinit(self: *Self) void {
    self.clearXkbKeymap();
    if (self.xkb_context) |context| xkb.xkb_context_unref(context);
    self.destroyCursorShapeDevice();
    if (self.pointer) |pointer| pointer.release();
    if (self.keyboard) |keyboard| keyboard.release();
    if (self.seat) |seat| seat.release();
    self.* = .{};
}

pub fn attachListeners(self: *Self, comptime Backend: type, backend: *Backend) void {
    if (self.seat) |seat| seat.setListener(*Backend, seatListener(Backend), backend);
    if (self.pointer) |pointer| pointer.setListener(*Backend, pointerListener(Backend), backend);
    if (self.keyboard) |keyboard| keyboard.setListener(*Backend, keyboardListener(Backend), backend);
}

pub fn setPointerButtonHandler(self: *Self, context: *anyopaque, handler: PointerButtonHandler) void {
    self.pointer_button_context = context;
    self.pointer_button_handler = handler;
}

pub fn setPointerMoveHandler(self: *Self, context: *anyopaque, handler: PointerMoveHandler) void {
    self.pointer_move_context = context;
    self.pointer_move_handler = handler;
}

pub fn setCursorShapeHandler(self: *Self, context: *anyopaque, handler: CursorShapeHandler) void {
    self.cursor_shape_context = context;
    self.cursor_shape_handler = handler;
}

pub fn setKeyHandler(self: *Self, context: *anyopaque, handler: KeyHandler) void {
    self.key_context = context;
    self.key_handler = handler;
}

pub fn setScrollHandler(self: *Self, context: *anyopaque, handler: ScrollHandler) void {
    self.scroll_context = context;
    self.scroll_handler = handler;
}

pub fn installEventTimers(self: *Self, loop: *Loop) !void {
    if (self.repeat_timer == null) self.repeat_timer = try loop.addTimer(self, repeatTimerCallback);
    if (self.fling_timer == null) self.fling_timer = try loop.addTimer(self, flingTimerCallback);
}

pub fn uninstallEventTimers(self: *Self) void {
    self.stopKeyRepeat();
    self.repeat_timer = null;
    self.stopFling();
    self.fling_timer = null;
}

pub fn removeEventTimers(self: *Self, loop: *Loop) void {
    self.stopKeyRepeat();
    if (self.repeat_timer) |timer| loop.removeTimer(timer);
    self.repeat_timer = null;
    self.stopFling();
    if (self.fling_timer) |timer| loop.removeTimer(timer);
    self.fling_timer = null;
}

fn seatListener(comptime Backend: type) *const fn (*wl.Seat, wl.Seat.Event, *Backend) void {
    return struct {
        fn callback(seat: *wl.Seat, event: wl.Seat.Event, backend: *Backend) void {
            const self = &backend.input;
            switch (event) {
                .capabilities => |caps| {
                    if (caps.capabilities.pointer and self.pointer == null) {
                        self.pointer = seat.getPointer() catch null;
                        if (self.pointer) |pointer| pointer.setListener(*Backend, pointerListener(Backend), backend);
                        self.createCursorShapeDevice();
                    } else if (!caps.capabilities.pointer and self.pointer != null) {
                        self.destroyCursorShapeDevice();
                        self.pointer.?.release();
                        self.pointer = null;
                        self.pointer_position = null;
                        self.pointer_enter_serial = null;
                        self.cursor_shape = null;
                    }
                    if (caps.capabilities.keyboard and self.keyboard == null) {
                        self.keyboard = seat.getKeyboard() catch null;
                        if (self.keyboard) |keyboard| keyboard.setListener(*Backend, keyboardListener(Backend), backend);
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
    }.callback;
}

fn pointerListener(comptime Backend: type) *const fn (*wl.Pointer, wl.Pointer.Event, *Backend) void {
    return struct {
        fn callback(pointer: *wl.Pointer, event: wl.Pointer.Event, backend: *Backend) void {
            const self = &backend.input;
            switch (event) {
                .enter => |enter| {
                    if (enter.surface != backend.surface) return;
                    self.pointer_enter_serial = enter.serial;
                    self.cursor_shape = null;
                    self.pointer_position = .{ .x = @floatCast(enter.surface_x.toDouble()), .y = @floatCast(enter.surface_y.toDouble()) };
                    self.pending_pointer.moved = true;
                },
                .leave => {
                    self.pointer_position = null;
                    self.pointer_enter_serial = null;
                    self.cursor_shape = null;
                    self.pending_pointer.left = true;
                },
                .motion => |motion| {
                    self.pointer_position = .{ .x = @floatCast(motion.surface_x.toDouble()), .y = @floatCast(motion.surface_y.toDouble()) };
                    self.pending_pointer.moved = true;
                },
                .button => |button| {
                    if (button.button != 272) return;
                    const state: keywork.PointerButtonState = switch (button.state) {
                        .pressed => .pressed,
                        .released => .released,
                        _ => return,
                    };
                    if (state == .pressed) self.stopFling();
                    const pending = &self.pending_pointer;
                    if (pending.button_count < pending.buttons.len) {
                        pending.buttons[pending.button_count] = state;
                        pending.button_count += 1;
                    }
                },
                .axis => |axis| {
                    const delta: f32 = @floatCast(axis.value.toDouble());
                    switch (axis.axis) {
                        .vertical_scroll => self.pending_pointer.scroll_dy += delta,
                        .horizontal_scroll => self.pending_pointer.scroll_dx += delta,
                        _ => return,
                    }
                    self.pending_pointer.scrolled = true;
                    self.pending_pointer.scroll_time_ms = axis.time;
                },
                .axis_source => |axis_source| self.pending_pointer.scroll_source = axis_source.axis_source,
                .axis_stop => self.pending_pointer.scroll_stopped = true,
                .frame => self.flushPointerFrame(),
                else => {},
            }
            // Pointers below version 5 never send frame; each event is its
            // own logical group.
            if (pointer.getVersion() < 5) self.flushPointerFrame();
        }
    }.callback;
}

/// Dispatches one accumulated pointer event group: a single move with the
/// group's final position, buttons in arrival order, and one combined
/// scroll delta.
fn flushPointerFrame(self: *Self) void {
    const pending = self.pending_pointer;
    self.pending_pointer = .{};

    if (pending.left and self.pointer_position == null) {
        self.dispatchPointerMove(null);
    } else if (pending.moved or pending.left) {
        if (self.pointer_position) |point| {
            self.dispatchPointerMove(point);
            self.updateCursorShape(point);
        }
    }
    if (self.pointer_position) |point| {
        for (pending.buttons[0..pending.button_count]) |state| {
            self.dispatchPointerButton(point, state);
        }
        if (pending.scrolled) {
            // Direct scrolling always overrides a running fling.
            self.stopFling();
            const speed: f32 = switch (pending.scroll_source) {
                .finger, .continuous => touchpad_scroll_speed,
                else => 1.0,
            };
            const dx = pending.scroll_dx * speed;
            const dy = pending.scroll_dy * speed;
            self.dispatchScroll(point, dx, dy);
            if (pending.scroll_source == .finger) {
                self.trackScrollVelocity(dx, dy, pending.scroll_time_ms);
            } else {
                self.resetScrollVelocity();
            }
        }
        if (pending.scroll_stopped) {
            self.startFling(point);
            self.resetScrollVelocity();
        }
    }
}

/// Folds one finger-scroll frame into the velocity moving average, in
/// boosted pixels per second so a fling continues at the on-screen speed.
fn trackScrollVelocity(self: *Self, dx: f32, dy: f32, time_ms: u32) void {
    defer self.last_scroll_time_ms = time_ms;
    const last = self.last_scroll_time_ms orelse return;
    const dt: f32 = @floatFromInt(time_ms -% last);
    if (dt <= 0 or dt > 200) return;
    const weight = velocity_smoothing;
    self.scroll_velocity_x = (1 - weight) * self.scroll_velocity_x + weight * (dx / dt * 1000.0);
    self.scroll_velocity_y = (1 - weight) * self.scroll_velocity_y + weight * (dy / dt * 1000.0);
}

fn resetScrollVelocity(self: *Self) void {
    self.scroll_velocity_x = 0;
    self.scroll_velocity_y = 0;
    self.last_scroll_time_ms = null;
}

fn startFling(self: *Self, point: keywork.Point) void {
    const timer = self.fling_timer orelse return;
    const vx = std.math.clamp(self.scroll_velocity_x, -fling_max_velocity, fling_max_velocity);
    const vy = std.math.clamp(self.scroll_velocity_y, -fling_max_velocity, fling_max_velocity);
    if (@abs(vx) < fling_start_velocity and @abs(vy) < fling_start_velocity) return;
    self.fling_velocity_x = vx;
    self.fling_velocity_y = vy;
    self.fling_point = point;
    timer.arm(fling_interval_ms, fling_interval_ms) catch return;
    self.fling_active = true;
}

fn stopFling(self: *Self) void {
    if (!self.fling_active) return;
    self.fling_active = false;
    if (self.fling_timer) |timer| timer.disarm();
}

fn flingTimerCallback(ctx: *anyopaque, _: *Loop, expirations: u64) !void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    if (!self.fling_active) return;
    const dt_ms: f32 = @floatFromInt(fling_interval_ms * @max(1, expirations));
    self.dispatchScroll(
        self.fling_point,
        self.fling_velocity_x * dt_ms / 1000.0,
        self.fling_velocity_y * dt_ms / 1000.0,
    );
    const decay = std.math.pow(f32, fling_decay_per_ms, dt_ms);
    self.fling_velocity_x *= decay;
    self.fling_velocity_y *= decay;
    if (@abs(self.fling_velocity_x) < fling_min_velocity and @abs(self.fling_velocity_y) < fling_min_velocity) {
        self.stopFling();
    }
}

fn dispatchPointerMove(self: *Self, point: ?keywork.Point) void {
    if (self.pointer_move_handler) |handler| handler(self.pointer_move_context.?, point);
}

fn dispatchScroll(self: *Self, point: keywork.Point, dx: f32, dy: f32) void {
    if (self.scroll_handler) |handler| handler(self.scroll_context.?, point, dx, dy);
}

fn dispatchPointerButton(self: *Self, point: keywork.Point, state: keywork.PointerButtonState) void {
    if (self.pointer_button_handler) |handler| handler(self.pointer_button_context.?, point, state);
}

fn createCursorShapeDevice(self: *Self) void {
    if (self.cursor_shape_device != null) return;
    const manager = self.cursor_shape_manager orelse return;
    const pointer = self.pointer orelse return;
    self.cursor_shape_device = manager.getPointer(pointer) catch |err| blk: {
        log.warn("failed to create cursor shape device: {}", .{err});
        break :blk null;
    };
}

fn destroyCursorShapeDevice(self: *Self) void {
    if (self.cursor_shape_device) |device| device.destroy();
    self.cursor_shape_device = null;
}

fn updateCursorShape(self: *Self, point: keywork.Point) void {
    const handler = self.cursor_shape_handler orelse return;
    const serial = self.pointer_enter_serial orelse return;
    const device = self.cursor_shape_device orelse return;
    const shape = handler(self.cursor_shape_context.?, point);
    if (self.cursor_shape == shape) return;
    device.setShape(serial, waylandCursorShape(shape));
    self.cursor_shape = shape;
}

fn waylandCursorShape(shape: keywork.CursorShape) wp.CursorShapeDeviceV1.Shape {
    return switch (shape) {
        .default => .default,
        .pointer => .pointer,
        .text => .text,
    };
}

fn keyboardListener(comptime Backend: type) *const fn (*wl.Keyboard, wl.Keyboard.Event, *Backend) void {
    return struct {
        fn callback(_: *wl.Keyboard, event: wl.Keyboard.Event, backend: *Backend) void {
            const self = &backend.input;
            switch (event) {
                .keymap => |keymap| self.installXkbKeymap(keymap),
                .enter => |enter| {
                    if (enter.surface != backend.surface) {
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
    }.callback;
}

fn installXkbKeymap(self: *Self, keymap: @TypeOf(@as(wl.Keyboard.Event, undefined).keymap)) void {
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

fn clearXkbKeymap(self: *Self) void {
    self.stopKeyRepeat();
    if (self.xkb_state) |state| xkb.xkb_state_unref(state);
    if (self.xkb_keymap) |keymap| xkb.xkb_keymap_unref(keymap);
    self.xkb_state = null;
    self.xkb_keymap = null;
}

fn keyInputFromWaylandKey(self: *Self, key: u32) ?keywork.KeyInput {
    const state = self.xkb_state orelse return keyInputFromEvdev(key, self.shift_down);
    const keycode: xkb.xkb_keycode_t = key + 8;
    const keysym = xkb.xkb_state_key_get_one_sym(state, keycode);
    switch (keysym) {
        xkb.XKB_KEY_BackSpace => return .backspace,
        xkb.XKB_KEY_Return, xkb.XKB_KEY_KP_Enter => return .enter,
        xkb.XKB_KEY_space => return .space,
        xkb.XKB_KEY_Tab => return .{ .tab = .{} },
        xkb.XKB_KEY_ISO_Left_Tab => return .{ .tab = .{ .reverse = true } },
        xkb.XKB_KEY_Escape => return .escape,
        xkb.XKB_KEY_Up, xkb.XKB_KEY_KP_Up => return .up,
        xkb.XKB_KEY_Down, xkb.XKB_KEY_KP_Down => return .down,
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

fn setRepeatInfo(self: *Self, rate: i32, delay: i32) void {
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

fn dispatchKeyInput(self: *Self, input: keywork.KeyInput) void {
    if (self.key_handler) |handler| handler(self.key_context.?, input);
}

fn startKeyRepeat(self: *Self, key: u32, input: keywork.KeyInput) void {
    if (!inputCanRepeat(input) or self.repeat_interval_ms == 0) return;
    const timer = self.repeat_timer orelse return;
    self.repeat_key = key;
    self.repeat_input = self.storedRepeatInput(input) orelse return;
    timer.arm(self.repeat_delay_ms, self.repeat_interval_ms) catch |err| {
        log.warn("failed to arm key repeat timer: {}", .{err});
        self.stopKeyRepeat();
    };
}

fn storedRepeatInput(self: *Self, input: keywork.KeyInput) ?keywork.KeyInput {
    return switch (input) {
        .text => |bytes| {
            if (bytes.len > self.repeat_text_buffer.len) return null;
            @memcpy(self.repeat_text_buffer[0..bytes.len], bytes);
            return .{ .text = self.repeat_text_buffer[0..bytes.len] };
        },
        .backspace => .backspace,
        .up => .up,
        .down => .down,
        .enter, .space, .tab, .escape => null,
    };
}

fn stopKeyRepeat(self: *Self) void {
    if (self.repeat_timer) |timer| timer.disarm();
    self.repeat_key = null;
    self.repeat_input = null;
}

fn repeatTimerCallback(ctx: *anyopaque, _: *Loop, expirations: u64) !void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    const input = self.repeat_input orelse return;
    var remaining = expirations;
    while (remaining > 0) : (remaining -= 1) {
        self.dispatchKeyInput(input);
    }
}

fn keyInputFromEvdev(key: u32, shift: bool) ?keywork.KeyInput {
    return switch (key) {
        14 => .backspace,
        28 => .enter,
        15 => .{ .tab = .{ .reverse = shift } },
        57 => .space,
        1 => .escape,
        103 => .up,
        108 => .down,
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
        .text, .backspace, .up, .down => true,
        .enter, .space, .tab, .escape => false,
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
