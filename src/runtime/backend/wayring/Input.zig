//! Wayring seat, pointer, and XKB keyboard state for one XDG surface.

const Input = @This();

const std = @import("std");
const keywork = @import("keywork-ui");
const wayring = @import("wayring");
const protocol = @import("wayring-protocols");
const xkb = @import("xkb_c");
const Client = @import("Client.zig");

const linux = std.os.linux;
const posix = std.posix;
const log = std.log.scoped(.keywork_wayring_input);

pub const Event = union(enum) {
    pointer_move: ?keywork.Point,
    pointer_button: keywork.PointerButtonEvent,
    scroll: keywork.ScrollEvent,
    key: keywork.KeyInput,
};
pub const Notify = *const fn (context: *anyopaque, input: *Input, event: Event) anyerror!void;

const PendingPointer = struct {
    moved: bool = false,
    left: bool = false,
    buttons: [4]struct { button: keywork.PointerButton, state: keywork.PointerButtonState } = undefined,
    button_count: usize = 0,
    scroll_dx: f32 = 0,
    scroll_dy: f32 = 0,
    scroll_steps_x: ?f32 = null,
    scroll_steps_y: ?f32 = null,
    scrolled: bool = false,
    scroll_source: u32 = @intFromEnum(protocol.wl_pointer_types.axis_source.wheel),
};

const wheel_scroll_step: f32 = 100;
const smooth_scroll_speed: f32 = 3;

connection: *wayring.Connection,
seat: wayring.ObjectHandle,
pointer: ?wayring.ObjectHandle = null,
keyboard: ?wayring.ObjectHandle = null,
surface_id: ?u32 = null,
pointer_focused: bool = false,
keyboard_focused: bool = false,
pointer_enabled: bool = false,
keyboard_enabled: bool = false,
pointer_position: ?keywork.Point = null,
pending_pointer: PendingPointer = .{},
shift_down: bool = false,
xkb_context: *xkb.struct_xkb_context,
xkb_keymap: ?*xkb.struct_xkb_keymap = null,
xkb_state: ?*xkb.struct_xkb_state = null,
key_text_buffer: [64]u8 = undefined,
notify_context: *anyopaque,
notify: Notify,

pub fn init(
    self: *Input,
    connection: *wayring.Connection,
    seat: Client.Seat,
    notify_context: *anyopaque,
    notify: Notify,
) !void {
    const xkb_context = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS) orelse
        return error.XkbContextFailed;
    self.* = .{
        .connection = connection,
        .seat = seat.handle,
        .xkb_context = xkb_context,
        .notify_context = notify_context,
        .notify = notify,
    };
    errdefer self.deinit();
    try self.applyCapabilities(seat.capabilities);
}

/// Protocol objects are connection-owned at this point; local XKB state is
/// safe to release after transport shutdown or disconnect.
pub fn deinit(self: *Input) void {
    self.clearXkbKeymap();
    xkb.xkb_context_unref(self.xkb_context);
    self.* = undefined;
}

pub fn setSurface(self: *Input, surface_id: u32) void {
    self.surface_id = surface_id;
}

pub fn ownsObject(self: *const Input, id: u32) bool {
    return id == self.seat.id or
        (self.pointer != null and id == self.pointer.?.id) or
        (self.keyboard != null and id == self.keyboard.?.id);
}

pub fn handleMessage(self: *Input, message: *wayring.Message) !void {
    if (message.object_id == self.seat.id) {
        switch (try protocol.wl_seat_types.decodeEvent(self.connection, self.seat, message)) {
            .capabilities => |event| try self.applyCapabilities(event.capabilities),
            .name => {},
        }
        return;
    }
    if (self.pointer) |pointer| {
        if (message.object_id == pointer.id) {
            try self.handlePointer(try protocol.wl_pointer_types.decodeEvent(
                self.connection,
                pointer,
                message,
            ));
            return;
        }
    }
    if (self.keyboard) |keyboard| {
        if (message.object_id == keyboard.id) {
            const event = try protocol.wl_keyboard_types.decodeEvent(
                self.connection,
                keyboard,
                message,
            );
            try self.handleKeyboard(message, event);
            return;
        }
    }
    return error.UnknownInputObject;
}

fn applyCapabilities(self: *Input, capabilities: u32) !void {
    self.pointer_enabled = capabilities & protocol.wl_seat_types.capability.pointer != 0;
    self.keyboard_enabled = capabilities & protocol.wl_seat_types.capability.keyboard != 0;
    if (self.pointer_enabled and self.pointer == null) {
        self.pointer = try protocol.wl_seat_types.requests.get_pointer(self.connection, self.seat);
    } else if (!self.pointer_enabled) {
        if (self.pointer_focused) try self.notify(self.notify_context, self, .{ .pointer_move = null });
        self.pointer_focused = false;
        self.pointer_position = null;
        self.pending_pointer = .{};
    }
    if (self.keyboard_enabled and self.keyboard == null) {
        self.keyboard = try protocol.wl_seat_types.requests.get_keyboard(self.connection, self.seat);
    } else if (!self.keyboard_enabled) {
        self.keyboard_focused = false;
        self.shift_down = false;
    }
}

fn handlePointer(self: *Input, event: protocol.wl_pointer_types.Event) !void {
    if (!self.pointer_enabled) return;
    switch (event) {
        .enter => |enter| {
            if (self.pointer_focused) try self.flushPointerFrame();
            self.pointer_focused = self.surface_id != null and enter.surface == self.surface_id.?;
            if (!self.pointer_focused) return;
            self.pointer_position = fixedPoint(enter.surface_x, enter.surface_y);
            self.pending_pointer.moved = true;
        },
        .leave => |leave| {
            if (!self.pointer_focused or self.surface_id == null or leave.surface != self.surface_id.?) return;
            self.pointer_position = null;
            self.pending_pointer.left = true;
        },
        .motion => |motion| {
            if (!self.pointer_focused) return;
            self.pointer_position = fixedPoint(motion.surface_x, motion.surface_y);
            self.pending_pointer.moved = true;
        },
        .button => |button| {
            if (!self.pointer_focused) return;
            const mapped_button: keywork.PointerButton = switch (button.button) {
                272 => .left,
                273 => .right,
                274 => .middle,
                275 => .back,
                276 => .forward,
                else => return,
            };
            const state: keywork.PointerButtonState = switch (button.state) {
                @intFromEnum(protocol.wl_pointer_types.button_state.pressed) => .pressed,
                @intFromEnum(protocol.wl_pointer_types.button_state.released) => .released,
                else => return,
            };
            if (self.pending_pointer.button_count < self.pending_pointer.buttons.len) {
                self.pending_pointer.buttons[self.pending_pointer.button_count] = .{
                    .button = mapped_button,
                    .state = state,
                };
                self.pending_pointer.button_count += 1;
            }
        },
        .axis => |axis| {
            if (!self.pointer_focused) return;
            const delta = fixedToFloat(axis.value);
            switch (axis.axis) {
                @intFromEnum(protocol.wl_pointer_types.axis.vertical_scroll) => self.pending_pointer.scroll_dy += delta,
                @intFromEnum(protocol.wl_pointer_types.axis.horizontal_scroll) => self.pending_pointer.scroll_dx += delta,
                else => return,
            }
            self.pending_pointer.scrolled = true;
        },
        .axis_source => |source| self.pending_pointer.scroll_source = source.axis_source,
        .axis_discrete => |axis| {
            const steps: f32 = @floatFromInt(axis.discrete);
            switch (axis.axis) {
                @intFromEnum(protocol.wl_pointer_types.axis.vertical_scroll) => self.pending_pointer.scroll_steps_y = steps,
                @intFromEnum(protocol.wl_pointer_types.axis.horizontal_scroll) => self.pending_pointer.scroll_steps_x = steps,
                else => {},
            }
        },
        .axis_value120 => |axis| {
            const steps = @as(f32, @floatFromInt(axis.value120)) / 120;
            switch (axis.axis) {
                @intFromEnum(protocol.wl_pointer_types.axis.vertical_scroll) => self.pending_pointer.scroll_steps_y = steps,
                @intFromEnum(protocol.wl_pointer_types.axis.horizontal_scroll) => self.pending_pointer.scroll_steps_x = steps,
                else => {},
            }
        },
        .frame => try self.flushPointerFrame(),
        .axis_stop, .axis_relative_direction => {},
        .warp => |warp| {
            if (!self.pointer_focused) return;
            self.pointer_position = fixedPoint(warp.surface_x, warp.surface_y);
            self.pending_pointer.moved = true;
        },
    }
}

fn flushPointerFrame(self: *Input) !void {
    const pending = self.pending_pointer;
    self.pending_pointer = .{};
    if (!self.pointer_focused) return;
    defer {
        if (pending.left) self.pointer_focused = false;
    }
    if (pending.left) {
        try self.notify(self.notify_context, self, .{ .pointer_move = null });
    } else if (pending.moved) {
        try self.notify(self.notify_context, self, .{ .pointer_move = self.pointer_position });
    }
    const point = self.pointer_position orelse return;
    const modifiers = self.currentModifiers();
    for (pending.buttons[0..pending.button_count]) |button| {
        try self.notify(self.notify_context, self, .{ .pointer_button = .{
            .button = button.button,
            .state = button.state,
            .position = point,
            .modifiers = modifiers,
        } });
    }
    if (pending.scrolled) {
        const wheel = pending.scroll_source == @intFromEnum(protocol.wl_pointer_types.axis_source.wheel) or
            pending.scroll_source == @intFromEnum(protocol.wl_pointer_types.axis_source.wheel_tilt);
        try self.notify(self.notify_context, self, .{ .scroll = .{
            .position = point,
            .dx = normalizedAxis(pending.scroll_dx, pending.scroll_steps_x, wheel),
            .dy = normalizedAxis(pending.scroll_dy, pending.scroll_steps_y, wheel),
            .modifiers = modifiers,
        } });
    }
}

fn handleKeyboard(
    self: *Input,
    message: *wayring.Message,
    event: protocol.wl_keyboard_types.Event,
) !void {
    switch (event) {
        .keymap => |keymap| {
            const fd = try message.takeFd(keymap.fd);
            self.installXkbKeymap(fd, keymap.format, keymap.size);
        },
        .enter => |enter| {
            self.keyboard_focused = self.keyboard_enabled and
                self.surface_id != null and enter.surface == self.surface_id.?;
            self.shift_down = false;
        },
        .leave => |leave| {
            if (self.surface_id != null and leave.surface == self.surface_id.?) {
                self.keyboard_focused = false;
                self.shift_down = false;
            }
        },
        .key => |key| {
            if (!self.keyboard_focused) return;
            const pressed = key.state == @intFromEnum(protocol.wl_keyboard_types.key_state.pressed) or
                key.state == @intFromEnum(protocol.wl_keyboard_types.key_state.repeated);
            switch (key.key) {
                42, 54 => {
                    self.shift_down = pressed;
                    return;
                },
                else => {},
            }
            if (!pressed) return;
            const input = self.keyInput(key.key) orelse return;
            try self.notify(self.notify_context, self, .{ .key = input });
        },
        .modifiers => |modifiers| if (self.xkb_state) |state| {
            _ = xkb.xkb_state_update_mask(
                state,
                modifiers.mods_depressed,
                modifiers.mods_latched,
                modifiers.mods_locked,
                0,
                0,
                modifiers.group,
            );
        },
        .repeat_info => {},
    }
}

fn installXkbKeymap(self: *Input, fd: i32, format: u32, size: u32) void {
    defer _ = linux.close(fd);
    if (format != @intFromEnum(protocol.wl_keyboard_types.keymap_format.xkb_v1) or size == 0) {
        self.clearXkbKeymap();
        return;
    }
    const bytes = posix.mmap(
        null,
        size,
        .{ .READ = true },
        .{ .TYPE = .PRIVATE },
        fd,
        0,
    ) catch |err| {
        log.warn("failed to map Wayring XKB keymap: {}", .{err});
        self.clearXkbKeymap();
        return;
    };
    defer posix.munmap(bytes);
    const new_keymap = xkb.xkb_keymap_new_from_buffer(
        self.xkb_context,
        @ptrCast(bytes.ptr),
        size,
        xkb.XKB_KEYMAP_FORMAT_TEXT_V1,
        xkb.XKB_KEYMAP_COMPILE_NO_FLAGS,
    ) orelse {
        self.clearXkbKeymap();
        return;
    };
    const new_state = xkb.xkb_state_new(new_keymap) orelse {
        xkb.xkb_keymap_unref(new_keymap);
        self.clearXkbKeymap();
        return;
    };
    self.clearXkbKeymap();
    self.xkb_keymap = new_keymap;
    self.xkb_state = new_state;
}

fn clearXkbKeymap(self: *Input) void {
    if (self.xkb_state) |state| xkb.xkb_state_unref(state);
    if (self.xkb_keymap) |keymap| xkb.xkb_keymap_unref(keymap);
    self.xkb_state = null;
    self.xkb_keymap = null;
}

fn keyInput(self: *Input, key: u32) ?keywork.KeyInput {
    const state = self.xkb_state orelse return keyInputFromEvdev(key, self.shift_down);
    const keycode: xkb.xkb_keycode_t = key + 8;
    const keysym = xkb.xkb_state_key_get_one_sym(state, keycode);
    const modifiers = self.currentModifiers();
    if (modifiers.ctrl and !modifiers.alt and !modifiers.super and
        (keysym == xkb.XKB_KEY_v or keysym == xkb.XKB_KEY_V)) return .paste;
    if (hasUnconsumedShortcutModifier(state, keycode)) return null;
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
    const written = xkb.xkb_state_key_get_utf8(state, keycode, &self.key_text_buffer, self.key_text_buffer.len);
    if (written <= 0) return null;
    const len: usize = @intCast(written);
    if (len >= self.key_text_buffer.len) return null;
    return .{ .text = self.key_text_buffer[0..len] };
}

fn currentModifiers(self: *const Input) keywork.Modifiers {
    const state = self.xkb_state orelse return .{ .shift = self.shift_down };
    const effective = xkb.XKB_STATE_MODS_EFFECTIVE;
    return .{
        .shift = xkb.xkb_state_mod_name_is_active(state, xkb.XKB_MOD_NAME_SHIFT, effective) != 0,
        .ctrl = xkb.xkb_state_mod_name_is_active(state, xkb.XKB_MOD_NAME_CTRL, effective) != 0,
        .alt = xkb.xkb_state_mod_name_is_active(state, xkb.XKB_VMOD_NAME_ALT, effective) != 0,
        .super = xkb.xkb_state_mod_name_is_active(state, xkb.XKB_MOD_NAME_MOD4, effective) != 0,
    };
}

fn hasUnconsumedShortcutModifier(state: *xkb.struct_xkb_state, keycode: xkb.xkb_keycode_t) bool {
    const keymap = xkb.xkb_state_get_keymap(state) orelse return false;
    const names = [_][*c]const u8{
        xkb.XKB_MOD_NAME_CTRL,
        xkb.XKB_VMOD_NAME_ALT,
        xkb.XKB_MOD_NAME_MOD1,
        xkb.XKB_VMOD_NAME_SUPER,
        xkb.XKB_MOD_NAME_MOD4,
    };
    for (names) |name| {
        if (xkb.xkb_state_mod_name_is_active(state, name, xkb.XKB_STATE_MODS_EFFECTIVE) <= 0) continue;
        const index = xkb.xkb_keymap_mod_get_index(keymap, name);
        if (index == xkb.XKB_MOD_INVALID) continue;
        if (xkb.xkb_state_mod_index_is_consumed2(state, keycode, index, xkb.XKB_CONSUMED_MODE_GTK) == 0) return true;
    }
    return false;
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
        else => null,
    };
}

fn fixedPoint(x: i32, y: i32) keywork.Point {
    return .{ .x = fixedToFloat(x), .y = fixedToFloat(y) };
}

fn fixedToFloat(value: i32) f32 {
    return @as(f32, @floatFromInt(value)) / 256;
}

fn normalizedAxis(raw: f32, steps: ?f32, wheel: bool) f32 {
    return if (wheel) (if (steps) |value| value * wheel_scroll_step else raw * smooth_scroll_speed) else raw * smooth_scroll_speed;
}

test "Wayland fixed coordinates and wheel steps preserve precision" {
    try std.testing.expectEqual(@as(f32, 1.5), fixedToFloat(384));
    try std.testing.expectEqual(@as(f32, -100), normalizedAxis(2, -1, true));
    try std.testing.expectEqual(@as(f32, 6), normalizedAxis(2, null, false));
}

test {
    std.testing.refAllDecls(Input);
}
