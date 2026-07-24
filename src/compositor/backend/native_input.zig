//! Native keyboard, pointer, and touch input through libinput.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Session = @import("session.zig");
const render = @import("../render/types.zig");

const c = @cImport({
    @cInclude("libinput.h");
    @cInclude("libudev.h");
    @cInclude("linux/input-event-codes.h");
    @cInclude("stdlib.h");
    @cInclude("xkbcommon/xkbcommon.h");
    @cInclude("xkbcommon/xkbcommon-names.h");
});
const wl = wayland.server.wl;

const log = std.log.scoped(.native_input);

allocator: std.mem.Allocator,
io: std.Io,
session: *Session,
session_listener: Session.Listener,
event_source: ?*wl.EventSource,
context: *c.struct_libinput,
listener: Listener,
devices: std.AutoHashMapUnmanaged(std.posix.fd_t, Session.Device),
input_devices: std.ArrayList(InputDevice),
next_input_device_id: DeviceId,
tablet_tools: std.ArrayList(TabletTool),
next_tablet_tool_id: TabletToolId,
device_listener: ?DeviceListener,
keymap_compiler: KeymapCompiler,
default_keymap: *Keymap,
active_keyboard: ?DeviceId,
keyboard_state_listener: ?KeyboardStateListener,
keyboard_event_listener: ?KeyboardEventListener,
active_repeat_info: RepeatInfo,
size: render.Size,
pointer_x: f64,
pointer_y: f64,
keyboard_count: usize,
pointer_count: usize,
touch_count: usize,
modifiers: Modifiers,
left_meta_pressed: bool,
right_meta_pressed: bool,
left_ctrl_pressed: bool,
right_ctrl_pressed: bool,
left_alt_pressed: bool,
right_alt_pressed: bool,
session_switch_key: ?u32,
suspended: bool,
initialized: bool,
failed: bool,

pub const DeviceId = u64;
pub const PhysicalDeviceId = u64;
pub const TabletToolId = u64;

pub const Listener = struct {
    context: *anyopaque,
    close: *const fn (*anyopaque) void,
    keyboard_available: *const fn (*anyopaque, bool) void,
    keyboard_keymap: *const fn (*anyopaque, ?DeviceId, wl.Keyboard.KeymapFormat, std.posix.fd_t, u32) void,
    keyboard_enter: *const fn (*anyopaque, []const u32) void,
    keyboard_key: *const fn (*anyopaque, DeviceId, u32, u32, wl.Keyboard.KeyState) void,
    keyboard_modifiers: *const fn (*anyopaque, ?DeviceId, u32, u32, u32, u32) void,
    keyboard_repeat_info: *const fn (*anyopaque, ?DeviceId, i32, i32) void,
    pointer_available: *const fn (*anyopaque, bool) void,
    pointer_motion: *const fn (*anyopaque, DeviceId, u32, f64, f64) void,
    pointer_relative_motion: *const fn (*anyopaque, DeviceId, u64, f64, f64, f64, f64) void,
    pointer_button: *const fn (*anyopaque, DeviceId, u32, u32, wl.Pointer.ButtonState) void,
    pointer_axis: *const fn (*anyopaque, DeviceId, u32, wl.Pointer.Axis, wl.Fixed) void,
    pointer_frame: *const fn (*anyopaque, DeviceId) void,
    pointer_axis_source: *const fn (*anyopaque, DeviceId, wl.Pointer.AxisSource) void,
    pointer_axis_stop: *const fn (*anyopaque, DeviceId, u32, wl.Pointer.Axis) void,
    pointer_axis_discrete: *const fn (*anyopaque, DeviceId, wl.Pointer.Axis, i32) void,
    pointer_axis_value120: *const fn (*anyopaque, DeviceId, wl.Pointer.Axis, i32) void,
    swipe_begin: *const fn (*anyopaque, DeviceId, u32, u32) void,
    swipe_update: *const fn (*anyopaque, DeviceId, u32, f64, f64) void,
    swipe_end: *const fn (*anyopaque, DeviceId, u32, bool) void,
    pinch_begin: *const fn (*anyopaque, DeviceId, u32, u32) void,
    pinch_update: *const fn (*anyopaque, DeviceId, u32, f64, f64, f64, f64) void,
    pinch_end: *const fn (*anyopaque, DeviceId, u32, bool) void,
    hold_begin: *const fn (*anyopaque, DeviceId, u32, u32) void,
    hold_end: *const fn (*anyopaque, DeviceId, u32, bool) void,
    tablet_tool_proximity: *const fn (*anyopaque, DeviceId, TabletToolId, u32, f64, f64, bool, TabletToolAxes) void,
    tablet_tool_axis: *const fn (*anyopaque, DeviceId, TabletToolId, u32, TabletToolAxes) void,
    tablet_tool_tip: *const fn (*anyopaque, DeviceId, TabletToolId, u32, TabletToolAxes, bool) void,
    tablet_tool_button: *const fn (*anyopaque, DeviceId, TabletToolId, u32, TabletToolAxes, u32, bool) void,
    tablet_pad_button: *const fn (*anyopaque, DeviceId, u32, u32, bool, u32, u32) void,
    tablet_pad_ring: *const fn (*anyopaque, DeviceId, u32, u32, f64, bool, u32, u32) void,
    tablet_pad_strip: *const fn (*anyopaque, DeviceId, u32, u32, f64, bool, u32, u32) void,
    tablet_pad_dial: *const fn (*anyopaque, DeviceId, u32, u32, i32, u32, u32) void,
    touch_available: *const fn (*anyopaque, bool) void,
    touch_down: *const fn (*anyopaque, DeviceId, u32, i32, f64, f64) void,
    touch_up: *const fn (*anyopaque, DeviceId, u32, i32) void,
    touch_motion: *const fn (*anyopaque, DeviceId, u32, i32, f64, f64) void,
    touch_frame: *const fn (*anyopaque, DeviceId) void,
    touch_cancel: *const fn (*anyopaque, DeviceId) void,
};

pub const Status = enum { success, unsupported, invalid };
pub const Toggle = enum(u1) { disabled, enabled };
pub const TapButtonMap = enum(u1) { lrm, lmr };
pub const ClickfingerButtonMap = enum(u1) { lrm, lmr };
pub const DragLock = enum(u2) { disabled, timeout, sticky };
pub const ThreeFingerDrag = enum(u2) { disabled, three_fingers, four_fingers };
pub const AccelProfile = enum(u3) { none = 0, flat = 1, adaptive = 2, custom = 4 };
pub const ClickMethod = enum(u2) { none = 0, button_areas = 1, clickfinger = 2 };
pub const ScrollMethod = enum(u3) { none = 0, two_finger = 1, edge = 2, on_button_down = 4 };
pub const AccelType = enum { fallback, motion, scroll };

pub const SendEventsModes = packed struct(u32) {
    disabled: bool = false,
    disabled_on_external_mouse: bool = false,
    _padding: u30 = 0,
};
pub const AccelProfiles = packed struct(u32) {
    flat: bool = false,
    adaptive: bool = false,
    custom: bool = false,
    _padding: u29 = 0,
};
pub const ClickMethods = packed struct(u32) {
    button_areas: bool = false,
    clickfinger: bool = false,
    _padding: u30 = 0,
};
pub const ScrollMethods = packed struct(u32) {
    two_finger: bool = false,
    edge: bool = false,
    on_button_down: bool = false,
    _padding: u29 = 0,
};
pub const CalibrationMatrix = [6]f32;

pub const KeymapFormat = enum(u32) {
    text_v1 = 1,
    text_v2 = 2,
};

pub const Keymap = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    native: *c.struct_xkb_keymap,
    file: std.Io.File,
    size: u32,
    references: usize = 1,

    pub fn ref(self: *Keymap) *Keymap {
        self.references = std.math.add(usize, self.references, 1) catch unreachable;
        return self;
    }

    pub fn unref(self: *Keymap) void {
        std.debug.assert(self.references > 0);
        self.references -= 1;
        if (self.references != 0) return;
        self.file.close(self.io);
        c.xkb_keymap_unref(self.native);
        self.allocator.destroy(self);
    }
};

pub const KeymapCompiler = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    context: *c.struct_xkb_context,

    pub fn init(self: *KeymapCompiler, allocator: std.mem.Allocator, io: std.Io) !void {
        self.* = .{
            .allocator = allocator,
            .io = io,
            .context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS) orelse
                return error.XkbContextFailed,
        };
    }

    pub fn deinit(self: *KeymapCompiler) void {
        c.xkb_context_unref(self.context);
        self.* = undefined;
    }

    pub fn defaultKeymap(self: *KeymapCompiler) !*Keymap {
        const native = c.xkb_keymap_new_from_names2(
            self.context,
            null,
            c.XKB_KEYMAP_FORMAT_TEXT_V1,
            c.XKB_KEYMAP_COMPILE_NO_FLAGS,
        ) orelse return error.XkbKeymapFailed;
        return self.wrap(native);
    }

    pub fn compile(self: *KeymapCompiler, format: KeymapFormat, text: []const u8) !?*Keymap {
        if (text.len == 0) return null;
        const native = c.xkb_keymap_new_from_buffer(
            self.context,
            text.ptr,
            text.len,
            @as(c.enum_xkb_keymap_format, @intFromEnum(format)),
            c.XKB_KEYMAP_COMPILE_NO_FLAGS,
        ) orelse return null;
        return try self.wrap(native);
    }

    fn wrap(self: *KeymapCompiler, native: *c.struct_xkb_keymap) !*Keymap {
        errdefer c.xkb_keymap_unref(native);
        const text_pointer = c.xkb_keymap_get_as_string(
            native,
            c.XKB_KEYMAP_FORMAT_TEXT_V1,
        ) orelse return error.SerializeKeymapFailed;
        defer c.free(text_pointer);
        const text = std.mem.span(text_pointer);
        const size = std.math.add(usize, text.len, 1) catch return error.KeymapTooLarge;
        if (size > std.math.maxInt(u32)) return error.KeymapTooLarge;

        const fd = try std.posix.memfd_create(
            "keywork-keymap",
            std.os.linux.MFD.CLOEXEC | std.os.linux.MFD.ALLOW_SEALING,
        );
        const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
        errdefer file.close(self.io);
        try file.setLength(self.io, size);
        try file.writeStreamingAll(self.io, text.ptr[0..size]);
        const seals = std.os.linux.F.SEAL_SHRINK |
            std.os.linux.F.SEAL_GROW |
            std.os.linux.F.SEAL_WRITE |
            std.os.linux.F.SEAL_SEAL;
        if (std.c.fcntl(fd, std.os.linux.F.ADD_SEALS, @as(c_int, seals)) < 0) {
            return error.SealKeymapFailed;
        }
        const keymap = try self.allocator.create(Keymap);
        keymap.* = .{
            .allocator = self.allocator,
            .io = self.io,
            .native = native,
            .file = file,
            .size = @intCast(size),
        };
        return keymap;
    }
};

pub const KeyboardState = struct {
    keymap: *const Keymap,
    layout_index: u32,
    layout_name: ?[*:0]const u8,
    capslock_enabled: bool,
    numlock_enabled: bool,
};

pub const KeyboardStateListener = struct {
    context: *anyopaque,
    changed: *const fn (*anyopaque, DeviceId, KeyboardState) void,
};

pub const KeyboardEvent = struct {
    device_id: DeviceId,
    key_code: u32,
    state: wl.Keyboard.KeyState,
    seat_level: bool,
    modifiers: u32,
    keysyms: []const u32,
    is_modifier: bool,
};

pub const KeyboardEventDisposition = enum {
    forwarded,
    captured,
    shortcuts_inhibited,
};

pub const KeyboardEventListener = struct {
    context: *anyopaque,
    key: *const fn (*anyopaque, KeyboardEvent) KeyboardEventDisposition,
    modifiers: *const fn (*anyopaque, ?DeviceId, u32, u32) void,
};

pub fn Setting(comptime T: type) type {
    return struct { default: T, current: T };
}

/// Null sections are unsupported. This avoids exposing libinput's placeholder
/// return values as real defaults on devices without the feature.
pub const DeviceConfig = struct {
    physical_id: PhysicalDeviceId,
    send_events: struct { supported: SendEventsModes, default: SendEventsModes, current: SendEventsModes },
    tap_finger_count: u32,
    tap: ?Setting(Toggle),
    tap_button_map: ?Setting(TapButtonMap),
    drag: ?Setting(Toggle),
    drag_lock: ?Setting(DragLock),
    three_finger_drag_count: u32,
    three_finger_drag: ?Setting(ThreeFingerDrag),
    calibration_matrix: ?Setting(CalibrationMatrix),
    accel_profiles: ?struct { supported: AccelProfiles, default: AccelProfile, current: AccelProfile, speed: Setting(f64) },
    natural_scroll: ?Setting(Toggle),
    left_handed: ?Setting(Toggle),
    click_method: ?struct { supported: ClickMethods, default: ClickMethod, current: ClickMethod },
    clickfinger_button_map: ?Setting(ClickfingerButtonMap),
    middle_emulation: ?Setting(Toggle),
    scroll_method: ?struct { supported: ScrollMethods, default: ScrollMethod, current: ScrollMethod },
    scroll_button: ?Setting(u32),
    scroll_button_lock: ?Setting(Toggle),
    dwt: ?Setting(Toggle),
    dwtp: ?Setting(Toggle),
    rotation: ?Setting(u32),
};

/// Owns one transient native acceleration configuration. Call deinit exactly once.
pub const AccelConfig = struct {
    native: *anyopaque,

    pub fn deinit(self: *AccelConfig) void {
        c.libinput_config_accel_destroy(@ptrCast(@alignCast(self.native)));
        self.* = undefined;
    }

    pub fn setPoints(self: *AccelConfig, accel_type: AccelType, step: f64, points: []const f64) Status {
        if (!validAccelPoints(step, points)) return .invalid;
        return statusFromNative(c.libinput_config_accel_set_points(
            @ptrCast(@alignCast(self.native)),
            @as(c.enum_libinput_config_accel_type, @intFromEnum(accel_type)),
            step,
            points.len,
            points.ptr,
        ));
    }
};

pub const DeviceType = enum {
    keyboard,
    pointer,
    touch,
    tablet,
    tablet_pad,
};

pub const DeviceInfo = struct {
    id: DeviceId,
    physical_id: PhysicalDeviceId,
    device_type: DeviceType,
    name: [:0]const u8,
    vendor: u32,
    product: u32,
};

pub const DeviceCapabilities = struct {
    keyboard: bool,
    pointer: bool,
    touch: bool,
    tablet: bool,
    tablet_pad: bool,
};

pub const TabletInfo = struct {
    vendor: u32,
    product: u32,
    bustype: u32,
    path: ?[:0]const u8,
};

pub const TabletPadGroupInfo = struct {
    buttons: []const u32,
    rings: []const u32,
    strips: []const u32,
    dials: []const u32,
    mode_count: u32,
    current_mode: u32,
};

pub const TabletPadInfo = struct {
    path: ?[:0]const u8,
    button_count: u32,
    groups: []const TabletPadGroupInfo,
};

pub const TabletToolType = enum {
    pen,
    eraser,
    brush,
    pencil,
    airbrush,
    mouse,
    lens,
};

pub const TabletToolCapabilities = packed struct {
    pressure: bool = false,
    distance: bool = false,
    tilt: bool = false,
    rotation: bool = false,
    slider: bool = false,
    wheel: bool = false,
    _padding: u2 = 0,
};

pub const TabletToolInfo = struct {
    id: TabletToolId,
    tool_type: TabletToolType,
    serial: ?u64,
    hardware_id: ?u64,
    capabilities: TabletToolCapabilities,
};

pub const TabletToolAxes = struct {
    position: ?struct { x: f64, y: f64 } = null,
    pressure: ?f64 = null,
    distance: ?f64 = null,
    tilt: ?struct { x: f64, y: f64 } = null,
    rotation: ?f64 = null,
    slider: ?f64 = null,
    wheel: ?struct { degrees: f64, clicks: i32 } = null,

    pub fn hasChanges(self: TabletToolAxes) bool {
        return self.position != null or self.pressure != null or self.distance != null or
            self.tilt != null or self.rotation != null or self.slider != null or
            self.wheel != null;
    }
};

pub const DeviceListener = struct {
    context: *anyopaque,
    added: *const fn (*anyopaque, DeviceInfo) void,
    removed: *const fn (*anyopaque, DeviceId) void,
};

const InputDevice = struct {
    info: DeviceInfo,
    libinput_device: *c.struct_libinput_device,
    keyboard: ?Keyboard = null,
    repeat_info: RepeatInfo = .{},
    scroll_factor: f64 = 1,
    map: ?DeviceMap = null,
    tablet_info: ?TabletInfo = null,
    tablet_pad_info: ?TabletPadInfo = null,
};

const TabletTool = struct {
    info: TabletToolInfo,
    device_id: DeviceId,
    native: *c.struct_libinput_tablet_tool,
};

const Keyboard = struct {
    keymap: *Keymap,
    state: *c.struct_xkb_state,
};

pub const DeviceMap = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

pub const RepeatInfo = struct {
    rate: i32 = 25,
    delay: i32 = 600,
};

pub const DeviceIterator = struct {
    devices: []const InputDevice,
    index: usize = 0,

    pub fn next(self: *DeviceIterator) ?DeviceInfo {
        if (self.index >= self.devices.len) return null;
        defer self.index += 1;
        return self.devices[self.index].info;
    }
};

pub const Modifiers = struct {
    depressed: u32 = 0,
    latched: u32 = 0,
    locked: u32 = 0,
    group: u32 = 0,
};

const libinput_interface: c.struct_libinput_interface = .{
    .open_restricted = openRestricted,
    .close_restricted = closeRestricted,
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    io: std.Io,
    event_loop: *wl.EventLoop,
    session: *Session,
    size: render.Size,
    listener: Listener,
) !void {
    std.debug.assert(size.width > 0 and size.height > 0);
    self.* = .{
        .allocator = allocator,
        .io = io,
        .session = session,
        .session_listener = .{
            .context = self,
            .activated = handleSessionActivated,
            .deactivated = handleSessionDeactivated,
            .failed = handleSessionFailed,
        },
        .event_source = null,
        .context = undefined,
        .listener = listener,
        .devices = .empty,
        .input_devices = .empty,
        .next_input_device_id = 1,
        .tablet_tools = .empty,
        .next_tablet_tool_id = 1,
        .device_listener = null,
        .keymap_compiler = undefined,
        .default_keymap = undefined,
        .active_keyboard = null,
        .keyboard_state_listener = null,
        .keyboard_event_listener = null,
        .active_repeat_info = .{},
        .size = size,
        .pointer_x = @as(f64, @floatFromInt(size.width)) / 2,
        .pointer_y = @as(f64, @floatFromInt(size.height)) / 2,
        .keyboard_count = 0,
        .pointer_count = 0,
        .touch_count = 0,
        .modifiers = .{},
        .left_meta_pressed = false,
        .right_meta_pressed = false,
        .left_ctrl_pressed = false,
        .right_ctrl_pressed = false,
        .left_alt_pressed = false,
        .right_alt_pressed = false,
        .session_switch_key = null,
        .suspended = false,
        .initialized = false,
        .failed = false,
    };
    errdefer self.devices.deinit(allocator);
    errdefer self.input_devices.deinit(allocator);
    errdefer self.tablet_tools.deinit(allocator);

    try self.keymap_compiler.init(allocator, io);
    errdefer self.keymap_compiler.deinit();
    self.default_keymap = try self.keymap_compiler.defaultKeymap();
    errdefer self.default_keymap.unref();
    try self.installKeymap(null, self.default_keymap);
    listener.keyboard_repeat_info(listener.context, null, 25, 600);

    const udev = c.udev_new() orelse return error.UdevContextFailed;
    defer _ = c.udev_unref(udev);
    self.context = c.libinput_udev_create_context(
        &libinput_interface,
        self,
        udev,
    ) orelse return error.LibinputContextFailed;
    errdefer _ = c.libinput_unref(self.context);
    if (c.libinput_udev_assign_seat(self.context, session.name().ptr) != 0) {
        return error.AssignSeatFailed;
    }
    errdefer self.clearCapabilities();
    try self.dispatchEvents();

    const fd = c.libinput_get_fd(self.context);
    if (fd < 0) return error.GetLibinputFdFailed;
    self.event_source = try event_loop.addFd(
        *Self,
        fd,
        .{ .readable = true },
        handleEvent,
        self,
    );
    errdefer self.event_source.?.remove();
    try session.addListener(&self.session_listener);
    self.initialized = true;
    log.info(
        "initialized on {s}: {d} keyboard(s), {d} pointer(s), {d} touch device(s)",
        .{ session.name(), self.keyboard_count, self.pointer_count, self.touch_count },
    );
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.device_listener == null);
    std.debug.assert(self.keyboard_state_listener == null);
    std.debug.assert(self.keyboard_event_listener == null);
    self.initialized = false;
    self.session.removeListener(&self.session_listener);
    if (self.event_source) |source| {
        source.remove();
        self.event_source = null;
    }
    self.clearCapabilities();
    _ = c.libinput_unref(self.context);
    std.debug.assert(self.devices.count() == 0);
    self.devices.deinit(self.allocator);
    std.debug.assert(self.input_devices.items.len == 0);
    self.input_devices.deinit(self.allocator);
    std.debug.assert(self.tablet_tools.items.len == 0);
    self.tablet_tools.deinit(self.allocator);
    std.debug.assert(self.default_keymap.references == 1);
    self.default_keymap.unref();
    self.keymap_compiler.deinit();
    self.* = undefined;
}

pub fn setDeviceListener(self: *Self, listener: DeviceListener) void {
    std.debug.assert(self.device_listener == null);
    self.device_listener = listener;
    for (self.input_devices.items) |device| {
        listener.added(listener.context, device.info);
    }
}

pub fn clearDeviceListener(self: *Self) void {
    std.debug.assert(self.device_listener != null);
    self.device_listener = null;
}

pub fn setKeyboardStateListener(self: *Self, listener: KeyboardStateListener) void {
    std.debug.assert(self.keyboard_state_listener == null);
    self.keyboard_state_listener = listener;
}

pub fn clearKeyboardStateListener(self: *Self) void {
    std.debug.assert(self.keyboard_state_listener != null);
    self.keyboard_state_listener = null;
}

pub fn setKeyboardEventListener(self: *Self, listener: KeyboardEventListener) void {
    std.debug.assert(self.keyboard_event_listener == null);
    self.keyboard_event_listener = listener;
}

pub fn clearKeyboardEventListener(self: *Self) void {
    std.debug.assert(self.keyboard_event_listener != null);
    self.keyboard_event_listener = null;
}

pub fn deviceIterator(self: *const Self) DeviceIterator {
    return .{ .devices = self.input_devices.items };
}

pub fn tabletInfo(self: *Self, id: DeviceId) ?TabletInfo {
    const device = self.findInputDeviceById(id) orelse return null;
    return device.tablet_info;
}

pub fn tabletPadInfo(self: *Self, id: DeviceId) ?TabletPadInfo {
    const device = self.findInputDeviceById(id) orelse return null;
    return device.tablet_pad_info;
}

pub fn tabletToolInfo(self: *const Self, id: TabletToolId) ?TabletToolInfo {
    for (self.tablet_tools.items) |tool| {
        if (tool.info.id == id) return tool.info;
    }
    return null;
}

pub fn compileKeymap(self: *Self, format: KeymapFormat, text: []const u8) !?*Keymap {
    return self.keymap_compiler.compile(format, text);
}

pub fn keyboardState(self: *Self, id: DeviceId) ?KeyboardState {
    const device = self.findInputDeviceById(id) orelse return null;
    const keyboard = if (device.keyboard) |*value| value else return null;
    return stateSnapshot(keyboard);
}

/// Returns a close-on-exec duplicate of the device's cached keymap fd.
/// The caller owns the returned fd and must close it.
pub fn duplicateKeyboardKeymapFd(self: *Self, id: DeviceId) !?std.posix.fd_t {
    const device = self.findInputDeviceById(id) orelse return null;
    const keyboard = device.keyboard orelse return null;
    return try duplicateKeymapFd(keyboard.keymap);
}

pub fn deviceRepeatInfo(self: *Self, id: DeviceId) ?RepeatInfo {
    const device = self.findInputDeviceById(id) orelse return null;
    if (device.info.device_type != .keyboard) return null;
    return device.repeat_info;
}

pub fn deviceModifiers(self: *Self, id: DeviceId) ?Modifiers {
    const device = self.findInputDeviceById(id) orelse return null;
    const keyboard = if (device.keyboard) |*value| value else return null;
    return .{
        .depressed = c.xkb_state_serialize_mods(keyboard.state, c.XKB_STATE_MODS_DEPRESSED),
        .latched = c.xkb_state_serialize_mods(keyboard.state, c.XKB_STATE_MODS_LATCHED),
        .locked = c.xkb_state_serialize_mods(keyboard.state, c.XKB_STATE_MODS_LOCKED),
        .group = c.xkb_state_serialize_layout(keyboard.state, c.XKB_STATE_LAYOUT_EFFECTIVE),
    };
}

pub fn deviceEffectiveModifiers(self: *Self, id: DeviceId) ?u32 {
    const device = self.findInputDeviceById(id) orelse return null;
    const keyboard = if (device.keyboard) |*value| value else return null;
    return effectiveKeyboardModifiers(keyboard);
}

pub fn setKeyboardKeymap(self: *Self, id: DeviceId, keymap: *Keymap) !bool {
    const device = self.findInputDeviceById(id) orelse return false;
    const keyboard = if (device.keyboard) |*value| value else return false;
    const state = c.xkb_state_new(keymap.native) orelse return error.XkbStateFailed;
    errdefer c.xkb_state_unref(state);
    if (self.active_keyboard == id) try self.installKeymap(id, keymap);
    const old_keymap = keyboard.keymap;
    const old_state = keyboard.state;
    keyboard.* = .{ .keymap = keymap.ref(), .state = state };
    c.xkb_state_unref(old_state);
    old_keymap.unref();
    if (self.active_keyboard == id) self.sendKeyboardModifiers(keyboard, true);
    self.notifyKeyboardState(device);
    return true;
}

pub fn setKeyboardLayoutIndex(self: *Self, id: DeviceId, index: i32) bool {
    const device = self.findInputDeviceById(id) orelse return false;
    const keyboard = if (device.keyboard) |*value| value else return false;
    if (index < 0 or index >= c.xkb_keymap_num_layouts(keyboard.keymap.native)) return true;
    _ = c.xkb_state_update_latched_locked(
        keyboard.state,
        0,
        0,
        false,
        0,
        0,
        0,
        true,
        index,
    );
    self.configuredKeyboardStateChanged(device);
    return true;
}

pub fn setKeyboardLayoutName(self: *Self, id: DeviceId, name: [*:0]const u8) bool {
    const device = self.findInputDeviceById(id) orelse return false;
    const keyboard = if (device.keyboard) |*value| value else return false;
    const index = c.xkb_keymap_layout_get_index(keyboard.keymap.native, name);
    if (index == c.XKB_LAYOUT_INVALID) return true;
    return self.setKeyboardLayoutIndex(id, @intCast(index));
}

pub fn setKeyboardCapslock(self: *Self, id: DeviceId, enabled: bool) bool {
    return self.setKeyboardLock(id, c.XKB_MOD_NAME_CAPS, enabled);
}

pub fn setKeyboardNumlock(self: *Self, id: DeviceId, enabled: bool) bool {
    return self.setKeyboardLock(id, c.XKB_MOD_NAME_NUM, enabled);
}

pub fn keyboardMatchesKeysym(
    self: *Self,
    id: DeviceId,
    key_code: u32,
    layout: u32,
    keysym: u32,
) bool {
    const device = self.findInputDeviceById(id) orelse return false;
    const keyboard = if (device.keyboard) |*value| value else return false;
    if (layout >= c.xkb_keymap_num_layouts(keyboard.keymap.native)) return false;
    var base_symbols: [*c]const c.xkb_keysym_t = null;
    const base_count = c.xkb_keymap_key_get_syms_by_level(
        keyboard.keymap.native,
        key_code + 8,
        layout,
        0,
        &base_symbols,
    );
    if (base_count > 0 and base_symbols != null) {
        for (base_symbols[0..@intCast(base_count)]) |symbol| if (symbol == keysym) return true;
    }
    return false;
}

pub fn setDeviceRepeatInfo(self: *Self, id: DeviceId, rate: i32, delay: i32) void {
    std.debug.assert(rate >= 0 and delay >= 0);
    const device = self.findInputDeviceById(id) orelse return;
    if (device.info.device_type != .keyboard) return;
    device.repeat_info = .{ .rate = rate, .delay = delay };
    if (self.active_keyboard == id) self.updateActiveRepeatInfo(device);
}

pub fn setDeviceScrollFactor(self: *Self, id: DeviceId, factor: f64) void {
    std.debug.assert(std.math.isFinite(factor) and factor >= 0);
    const device = self.findInputDeviceById(id) orelse return;
    if (device.info.device_type != .pointer) return;
    device.scroll_factor = factor;
}

pub fn setDeviceMap(self: *Self, id: DeviceId, map: ?DeviceMap) void {
    if (map) |rectangle| {
        std.debug.assert(rectangle.width > 0 and rectangle.height > 0);
    }
    const device = self.findInputDeviceById(id) orelse return;
    if (device.info.device_type == .keyboard) return;
    device.map = map;
}

pub fn createAccelConfig(profile: AccelProfile) ?AccelConfig {
    const native = c.libinput_config_accel_create(
        @as(c.enum_libinput_config_accel_profile, @intFromEnum(profile)),
    ) orelse return null;
    return .{ .native = native };
}

pub fn deviceCapabilities(self: *Self, id: DeviceId) ?DeviceCapabilities {
    const device = (self.findInputDeviceById(id) orelse return null).libinput_device;
    return .{
        .keyboard = c.libinput_device_has_capability(device, c.LIBINPUT_DEVICE_CAP_KEYBOARD) != 0,
        .pointer = c.libinput_device_has_capability(device, c.LIBINPUT_DEVICE_CAP_POINTER) != 0,
        .touch = c.libinput_device_has_capability(device, c.LIBINPUT_DEVICE_CAP_TOUCH) != 0,
        .tablet = c.libinput_device_has_capability(device, c.LIBINPUT_DEVICE_CAP_TABLET_TOOL) != 0,
        .tablet_pad = c.libinput_device_has_capability(device, c.LIBINPUT_DEVICE_CAP_TABLET_PAD) != 0,
    };
}

pub fn deviceConfig(self: *Self, id: DeviceId) ?DeviceConfig {
    const d = (self.findInputDeviceById(id) orelse return null).libinput_device;
    const tap_count: u32 = @intCast(c.libinput_device_config_tap_get_finger_count(d));
    const drag_count: u32 = @intCast(c.libinput_device_config_3fg_drag_get_finger_count(d));
    const click_bits = c.libinput_device_config_click_get_methods(d);
    const scroll_bits = c.libinput_device_config_scroll_get_methods(d);
    var matrix_default: CalibrationMatrix = undefined;
    var matrix_current: CalibrationMatrix = undefined;
    const has_matrix = c.libinput_device_config_calibration_has_matrix(d) != 0;
    if (has_matrix) {
        _ = c.libinput_device_config_calibration_get_default_matrix(d, &matrix_default);
        _ = c.libinput_device_config_calibration_get_matrix(d, &matrix_current);
    }
    return .{
        .physical_id = physicalId(d),
        .send_events = .{
            .supported = @bitCast(c.libinput_device_config_send_events_get_modes(d)),
            .default = @bitCast(c.libinput_device_config_send_events_get_default_mode(d)),
            .current = @bitCast(c.libinput_device_config_send_events_get_mode(d)),
        },
        .tap_finger_count = tap_count,
        .tap = if (tap_count > 0) setting(Toggle, c.libinput_device_config_tap_get_default_enabled(d), c.libinput_device_config_tap_get_enabled(d)) else null,
        .tap_button_map = if (tap_count > 0) setting(TapButtonMap, c.libinput_device_config_tap_get_default_button_map(d), c.libinput_device_config_tap_get_button_map(d)) else null,
        .drag = if (tap_count > 0) setting(Toggle, c.libinput_device_config_tap_get_default_drag_enabled(d), c.libinput_device_config_tap_get_drag_enabled(d)) else null,
        .drag_lock = if (tap_count > 0) setting(DragLock, c.libinput_device_config_tap_get_default_drag_lock_enabled(d), c.libinput_device_config_tap_get_drag_lock_enabled(d)) else null,
        .three_finger_drag_count = drag_count,
        .three_finger_drag = if (drag_count >= 3) setting(ThreeFingerDrag, c.libinput_device_config_3fg_drag_get_default_enabled(d), c.libinput_device_config_3fg_drag_get_enabled(d)) else null,
        .calibration_matrix = if (has_matrix) .{ .default = matrix_default, .current = matrix_current } else null,
        .accel_profiles = if (c.libinput_device_config_accel_is_available(d) != 0) .{
            .supported = @bitCast(c.libinput_device_config_accel_get_profiles(d)),
            .default = nativeEnum(AccelProfile, c.libinput_device_config_accel_get_default_profile(d)),
            .current = nativeEnum(AccelProfile, c.libinput_device_config_accel_get_profile(d)),
            .speed = .{ .default = c.libinput_device_config_accel_get_default_speed(d), .current = c.libinput_device_config_accel_get_speed(d) },
        } else null,
        .natural_scroll = if (c.libinput_device_config_scroll_has_natural_scroll(d) != 0) settingBool(c.libinput_device_config_scroll_get_default_natural_scroll_enabled(d), c.libinput_device_config_scroll_get_natural_scroll_enabled(d)) else null,
        .left_handed = if (c.libinput_device_config_left_handed_is_available(d) != 0) settingBool(c.libinput_device_config_left_handed_get_default(d), c.libinput_device_config_left_handed_get(d)) else null,
        .click_method = if (click_bits != 0) .{ .supported = @bitCast(click_bits), .default = nativeEnum(ClickMethod, c.libinput_device_config_click_get_default_method(d)), .current = nativeEnum(ClickMethod, c.libinput_device_config_click_get_method(d)) } else null,
        .clickfinger_button_map = if (click_bits & c.LIBINPUT_CONFIG_CLICK_METHOD_CLICKFINGER != 0) setting(ClickfingerButtonMap, c.libinput_device_config_click_get_default_clickfinger_button_map(d), c.libinput_device_config_click_get_clickfinger_button_map(d)) else null,
        .middle_emulation = if (c.libinput_device_config_middle_emulation_is_available(d) != 0) setting(Toggle, c.libinput_device_config_middle_emulation_get_default_enabled(d), c.libinput_device_config_middle_emulation_get_enabled(d)) else null,
        .scroll_method = if (scroll_bits != 0) .{ .supported = @bitCast(scroll_bits), .default = nativeEnum(ScrollMethod, c.libinput_device_config_scroll_get_default_method(d)), .current = nativeEnum(ScrollMethod, c.libinput_device_config_scroll_get_method(d)) } else null,
        .scroll_button = if (scroll_bits & c.LIBINPUT_CONFIG_SCROLL_ON_BUTTON_DOWN != 0) .{ .default = c.libinput_device_config_scroll_get_default_button(d), .current = c.libinput_device_config_scroll_get_button(d) } else null,
        .scroll_button_lock = if (scroll_bits & c.LIBINPUT_CONFIG_SCROLL_ON_BUTTON_DOWN != 0) setting(Toggle, c.libinput_device_config_scroll_get_default_button_lock(d), c.libinput_device_config_scroll_get_button_lock(d)) else null,
        .dwt = if (c.libinput_device_config_dwt_is_available(d) != 0) setting(Toggle, c.libinput_device_config_dwt_get_default_enabled(d), c.libinput_device_config_dwt_get_enabled(d)) else null,
        .dwtp = if (c.libinput_device_config_dwtp_is_available(d) != 0) setting(Toggle, c.libinput_device_config_dwtp_get_default_enabled(d), c.libinput_device_config_dwtp_get_enabled(d)) else null,
        .rotation = if (c.libinput_device_config_rotation_is_available(d) != 0) .{ .default = c.libinput_device_config_rotation_get_default_angle(d), .current = c.libinput_device_config_rotation_get_angle(d) } else null,
    };
}

pub fn setSendEvents(self: *Self, id: DeviceId, value: SendEventsModes) ?Status {
    return self.call(
        id,
        c.libinput_device_config_send_events_set_mode,
        @as(c.enum_libinput_config_send_events_mode, @bitCast(value)),
    );
}
pub fn setTap(self: *Self, id: DeviceId, value: Toggle) ?Status {
    return self.call(id, c.libinput_device_config_tap_set_enabled, @as(c.enum_libinput_config_tap_state, @intFromEnum(value)));
}
pub fn setTapButtonMap(self: *Self, id: DeviceId, value: TapButtonMap) ?Status {
    return self.call(id, c.libinput_device_config_tap_set_button_map, @as(c.enum_libinput_config_tap_button_map, @intFromEnum(value)));
}
pub fn setDrag(self: *Self, id: DeviceId, value: Toggle) ?Status {
    return self.call(id, c.libinput_device_config_tap_set_drag_enabled, @as(c.enum_libinput_config_drag_state, @intFromEnum(value)));
}
pub fn setDragLock(self: *Self, id: DeviceId, value: DragLock) ?Status {
    return self.call(id, c.libinput_device_config_tap_set_drag_lock_enabled, @as(c.enum_libinput_config_drag_lock_state, @intFromEnum(value)));
}
pub fn setThreeFingerDrag(self: *Self, id: DeviceId, value: ThreeFingerDrag) ?Status {
    return self.call(id, c.libinput_device_config_3fg_drag_set_enabled, @as(c.enum_libinput_config_3fg_drag_state, @intFromEnum(value)));
}
pub fn setCalibrationMatrix(self: *Self, id: DeviceId, value: CalibrationMatrix) ?Status {
    if (!validMatrix(value)) return .invalid;
    return self.call(id, c.libinput_device_config_calibration_set_matrix, &value);
}
pub fn setAccelProfile(self: *Self, id: DeviceId, value: AccelProfile) ?Status {
    return self.call(id, c.libinput_device_config_accel_set_profile, @as(c.enum_libinput_config_accel_profile, @intFromEnum(value)));
}
pub fn setAccelSpeed(self: *Self, id: DeviceId, value: f64) ?Status {
    if (!std.math.isFinite(value) or value < -1 or value > 1) return .invalid;
    return self.call(id, c.libinput_device_config_accel_set_speed, value);
}
pub fn applyAccelConfig(self: *Self, id: DeviceId, config: *const AccelConfig) ?Status {
    return self.call(id, c.libinput_device_config_accel_apply, @as(*c.struct_libinput_config_accel, @ptrCast(@alignCast(config.native))));
}
pub fn setNaturalScroll(self: *Self, id: DeviceId, value: Toggle) ?Status {
    return self.call(id, c.libinput_device_config_scroll_set_natural_scroll_enabled, @intFromEnum(value));
}
pub fn setLeftHanded(self: *Self, id: DeviceId, value: Toggle) ?Status {
    return self.call(id, c.libinput_device_config_left_handed_set, @intFromEnum(value));
}
pub fn setClickMethod(self: *Self, id: DeviceId, value: ClickMethod) ?Status {
    return self.call(id, c.libinput_device_config_click_set_method, @as(c.enum_libinput_config_click_method, @intFromEnum(value)));
}
pub fn setClickfingerButtonMap(self: *Self, id: DeviceId, value: ClickfingerButtonMap) ?Status {
    return self.call(id, c.libinput_device_config_click_set_clickfinger_button_map, @as(c.enum_libinput_config_clickfinger_button_map, @intFromEnum(value)));
}
pub fn setMiddleEmulation(self: *Self, id: DeviceId, value: Toggle) ?Status {
    return self.call(id, c.libinput_device_config_middle_emulation_set_enabled, @as(c.enum_libinput_config_middle_emulation_state, @intFromEnum(value)));
}
pub fn setScrollMethod(self: *Self, id: DeviceId, value: ScrollMethod) ?Status {
    return self.call(id, c.libinput_device_config_scroll_set_method, @as(c.enum_libinput_config_scroll_method, @intFromEnum(value)));
}
pub fn setScrollButton(self: *Self, id: DeviceId, value: u32) ?Status {
    return self.call(id, c.libinput_device_config_scroll_set_button, value);
}
pub fn setScrollButtonLock(self: *Self, id: DeviceId, value: Toggle) ?Status {
    return self.call(id, c.libinput_device_config_scroll_set_button_lock, @as(c.enum_libinput_config_scroll_button_lock_state, @intFromEnum(value)));
}
pub fn setDwt(self: *Self, id: DeviceId, value: Toggle) ?Status {
    return self.call(id, c.libinput_device_config_dwt_set_enabled, @as(c.enum_libinput_config_dwt_state, @intFromEnum(value)));
}
pub fn setDwtp(self: *Self, id: DeviceId, value: Toggle) ?Status {
    return self.call(id, c.libinput_device_config_dwtp_set_enabled, @as(c.enum_libinput_config_dwtp_state, @intFromEnum(value)));
}
pub fn setRotation(self: *Self, id: DeviceId, value: u32) ?Status {
    if (value >= 360) return .invalid;
    return self.call(id, c.libinput_device_config_rotation_set_angle, value);
}

fn call(self: *Self, id: DeviceId, function: anytype, argument: anytype) ?Status {
    const device = self.findInputDeviceById(id) orelse return null;
    return statusFromNative(function(device.libinput_device, argument));
}

pub fn retarget(self: *Self, size: render.Size, listener: Listener) void {
    std.debug.assert(size.width > 0 and size.height > 0);
    self.size = size;
    self.listener = listener;
    self.pointer_x = @min(self.pointer_x, @as(f64, @floatFromInt(size.width - 1)));
    self.pointer_y = @min(self.pointer_y, @as(f64, @floatFromInt(size.height - 1)));
}

pub fn setPointerPosition(self: *Self, x: f64, y: f64) void {
    std.debug.assert(self.initialized);
    self.pointer_x = clampCoordinate(x, self.size.width);
    self.pointer_y = clampCoordinate(y, self.size.height);
}

fn duplicateKeymapFd(keymap: *const Keymap) !std.posix.fd_t {
    const duplicate = std.c.fcntl(
        keymap.file.handle,
        std.os.linux.F.DUPFD_CLOEXEC,
        @as(c_int, 0),
    );
    if (duplicate < 0) return error.DuplicateKeymapFailed;
    return duplicate;
}

fn installKeymap(self: *Self, source: ?DeviceId, keymap: *const Keymap) !void {
    const duplicate = try duplicateKeymapFd(keymap);
    self.listener.keyboard_keymap(
        self.listener.context,
        source,
        .xkb_v1,
        duplicate,
        keymap.size,
    );
}

fn dispatchEvents(self: *Self) !void {
    if (c.libinput_dispatch(self.context) != 0) return error.LibinputDispatchFailed;
    while (c.libinput_get_event(self.context)) |event| {
        defer c.libinput_event_destroy(event);
        self.processEvent(event);
        if (self.failed) return error.InputFailed;
    }
}

fn processEvent(self: *Self, event: *c.struct_libinput_event) void {
    switch (c.libinput_event_get_type(event)) {
        c.LIBINPUT_EVENT_DEVICE_ADDED => self.deviceAdded(c.libinput_event_get_device(event).?),
        c.LIBINPUT_EVENT_DEVICE_REMOVED => self.deviceRemoved(c.libinput_event_get_device(event).?),
        c.LIBINPUT_EVENT_KEYBOARD_KEY => self.keyboardKey(
            c.libinput_event_get_keyboard_event(event).?,
        ),
        c.LIBINPUT_EVENT_POINTER_MOTION => self.pointerMotion(
            c.libinput_event_get_pointer_event(event).?,
        ),
        c.LIBINPUT_EVENT_POINTER_MOTION_ABSOLUTE => self.pointerMotionAbsolute(
            c.libinput_event_get_pointer_event(event).?,
        ),
        c.LIBINPUT_EVENT_POINTER_BUTTON => self.pointerButton(
            c.libinput_event_get_pointer_event(event).?,
        ),
        c.LIBINPUT_EVENT_POINTER_SCROLL_WHEEL => self.pointerScroll(
            c.libinput_event_get_pointer_event(event).?,
            .wheel,
        ),
        c.LIBINPUT_EVENT_POINTER_SCROLL_FINGER => self.pointerScroll(
            c.libinput_event_get_pointer_event(event).?,
            .finger,
        ),
        c.LIBINPUT_EVENT_POINTER_SCROLL_CONTINUOUS => self.pointerScroll(
            c.libinput_event_get_pointer_event(event).?,
            .continuous,
        ),
        c.LIBINPUT_EVENT_GESTURE_SWIPE_BEGIN => self.swipeBegin(
            c.libinput_event_get_gesture_event(event).?,
        ),
        c.LIBINPUT_EVENT_GESTURE_SWIPE_UPDATE => self.swipeUpdate(
            c.libinput_event_get_gesture_event(event).?,
        ),
        c.LIBINPUT_EVENT_GESTURE_SWIPE_END => self.swipeEnd(
            c.libinput_event_get_gesture_event(event).?,
        ),
        c.LIBINPUT_EVENT_GESTURE_PINCH_BEGIN => self.pinchBegin(
            c.libinput_event_get_gesture_event(event).?,
        ),
        c.LIBINPUT_EVENT_GESTURE_PINCH_UPDATE => self.pinchUpdate(
            c.libinput_event_get_gesture_event(event).?,
        ),
        c.LIBINPUT_EVENT_GESTURE_PINCH_END => self.pinchEnd(
            c.libinput_event_get_gesture_event(event).?,
        ),
        c.LIBINPUT_EVENT_GESTURE_HOLD_BEGIN => self.holdBegin(
            c.libinput_event_get_gesture_event(event).?,
        ),
        c.LIBINPUT_EVENT_GESTURE_HOLD_END => self.holdEnd(
            c.libinput_event_get_gesture_event(event).?,
        ),
        c.LIBINPUT_EVENT_TABLET_TOOL_AXIS => self.tabletToolAxis(
            c.libinput_event_get_tablet_tool_event(event).?,
        ),
        c.LIBINPUT_EVENT_TABLET_TOOL_PROXIMITY => self.tabletToolProximity(
            c.libinput_event_get_tablet_tool_event(event).?,
        ),
        c.LIBINPUT_EVENT_TABLET_TOOL_TIP => self.tabletToolTip(
            c.libinput_event_get_tablet_tool_event(event).?,
        ),
        c.LIBINPUT_EVENT_TABLET_TOOL_BUTTON => self.tabletToolButton(
            c.libinput_event_get_tablet_tool_event(event).?,
        ),
        c.LIBINPUT_EVENT_TABLET_PAD_BUTTON => self.tabletPadButton(
            c.libinput_event_get_tablet_pad_event(event).?,
        ),
        c.LIBINPUT_EVENT_TABLET_PAD_RING => self.tabletPadRing(
            c.libinput_event_get_tablet_pad_event(event).?,
        ),
        c.LIBINPUT_EVENT_TABLET_PAD_STRIP => self.tabletPadStrip(
            c.libinput_event_get_tablet_pad_event(event).?,
        ),
        c.LIBINPUT_EVENT_TABLET_PAD_DIAL => self.tabletPadDial(
            c.libinput_event_get_tablet_pad_event(event).?,
        ),
        c.LIBINPUT_EVENT_TOUCH_DOWN => self.touchDown(c.libinput_event_get_touch_event(event).?),
        c.LIBINPUT_EVENT_TOUCH_UP => self.touchUp(c.libinput_event_get_touch_event(event).?),
        c.LIBINPUT_EVENT_TOUCH_MOTION => self.touchMotion(c.libinput_event_get_touch_event(event).?),
        c.LIBINPUT_EVENT_TOUCH_CANCEL => self.touchCancelOrFrame(event, true),
        c.LIBINPUT_EVENT_TOUCH_FRAME => self.touchCancelOrFrame(event, false),
        else => {},
    }
}

fn deviceAdded(self: *Self, device: *c.struct_libinput_device) void {
    if (self.suspended) return;
    const has_keyboard = c.libinput_device_has_capability(
        device,
        c.LIBINPUT_DEVICE_CAP_KEYBOARD,
    ) != 0;
    const has_pointer = c.libinput_device_has_capability(
        device,
        c.LIBINPUT_DEVICE_CAP_POINTER,
    ) != 0;
    const has_touch = c.libinput_device_has_capability(
        device,
        c.LIBINPUT_DEVICE_CAP_TOUCH,
    ) != 0;
    const has_tablet = c.libinput_device_has_capability(
        device,
        c.LIBINPUT_DEVICE_CAP_TABLET_TOOL,
    ) != 0;
    const has_tablet_pad = c.libinput_device_has_capability(
        device,
        c.LIBINPUT_DEVICE_CAP_TABLET_PAD,
    ) != 0;
    const name_pointer = c.libinput_device_get_name(device);
    const name = if (name_pointer == null) "unknown" else std.mem.span(name_pointer);
    log.info(
        "added {s} (keyboard={}, pointer={}, touch={}, tablet={}, tablet_pad={})",
        .{ name, has_keyboard, has_pointer, has_touch, has_tablet, has_tablet_pad },
    );
    const old_device_count = self.input_devices.items.len;
    if (has_keyboard) self.addInputDevice(device, .keyboard, name) catch |err| {
        self.rollbackInputDevices(old_device_count);
        return self.fail(err);
    };
    if (has_pointer) self.addInputDevice(device, .pointer, name) catch |err| {
        self.rollbackInputDevices(old_device_count);
        return self.fail(err);
    };
    if (has_touch) self.addInputDevice(device, .touch, name) catch |err| {
        self.rollbackInputDevices(old_device_count);
        return self.fail(err);
    };
    if (has_tablet) {
        self.addInputDevice(device, .tablet, name) catch |err| {
            self.rollbackInputDevices(old_device_count);
            return self.fail(err);
        };
    }
    if (has_tablet_pad) {
        self.addInputDevice(device, .tablet_pad, name) catch |err| {
            if (err == error.InvalidTabletPad) {
                log.warn("ignoring invalid tablet pad metadata for {s}", .{name});
            } else {
                self.rollbackInputDevices(old_device_count);
                return self.fail(err);
            }
        };
    }
    if (has_keyboard) {
        self.keyboard_count += 1;
        if (self.keyboard_count == 1) {
            self.listener.keyboard_available(self.listener.context, true);
            self.listener.keyboard_enter(self.listener.context, &.{});
        }
    }
    if (has_pointer) {
        self.pointer_count += 1;
        if (self.pointer_count == 1) self.listener.pointer_available(self.listener.context, true);
    }
    if (has_touch) {
        self.touch_count += 1;
        if (self.touch_count == 1) self.listener.touch_available(self.listener.context, true);
    }
}

fn deviceRemoved(self: *Self, device: *c.struct_libinput_device) void {
    if (self.suspended) return;
    const name_pointer = c.libinput_device_get_name(device);
    const name = if (name_pointer == null) "unknown" else std.mem.span(name_pointer);
    log.info("removed {s}", .{name});
    self.removeInputDevices(device);
    if (c.libinput_device_has_capability(device, c.LIBINPUT_DEVICE_CAP_KEYBOARD) != 0) {
        std.debug.assert(self.keyboard_count > 0);
        self.keyboard_count -= 1;
        if (self.keyboard_count == 0) {
            self.listener.keyboard_available(self.listener.context, false);
            self.resetKeyboardState();
        }
    }
    if (c.libinput_device_has_capability(device, c.LIBINPUT_DEVICE_CAP_POINTER) != 0) {
        std.debug.assert(self.pointer_count > 0);
        self.pointer_count -= 1;
        if (self.pointer_count == 0) self.listener.pointer_available(self.listener.context, false);
    }
    if (c.libinput_device_has_capability(device, c.LIBINPUT_DEVICE_CAP_TOUCH) != 0) {
        std.debug.assert(self.touch_count > 0);
        self.touch_count -= 1;
        if (self.touch_count == 0) self.listener.touch_available(self.listener.context, false);
    }
}

fn addInputDevice(
    self: *Self,
    libinput_device: *c.struct_libinput_device,
    device_type: DeviceType,
    name: []const u8,
) !void {
    const name_copy = try self.allocator.dupeSentinel(u8, name, 0);
    errdefer self.allocator.free(name_copy);
    const id = self.next_input_device_id;
    self.next_input_device_id = std.math.add(DeviceId, id, 1) catch return error.OutOfMemory;
    var keyboard: ?Keyboard = null;
    if (device_type == .keyboard) {
        const keymap = self.default_keymap.ref();
        errdefer keymap.unref();
        keyboard = .{
            .keymap = keymap,
            .state = c.xkb_state_new(keymap.native) orelse return error.XkbStateFailed,
        };
    }
    errdefer if (keyboard) |value| c.xkb_state_unref(value.state);
    var tablet_info: ?TabletInfo = null;
    if (device_type == .tablet) {
        var path: ?[:0]u8 = null;
        if (c.libinput_device_get_udev_device(libinput_device)) |udev_device| {
            defer _ = c.udev_device_unref(udev_device);
            if (c.udev_device_get_devnode(udev_device)) |devnode| {
                path = try self.allocator.dupeSentinel(u8, std.mem.span(devnode), 0);
            }
        }
        tablet_info = .{
            .vendor = c.libinput_device_get_id_vendor(libinput_device),
            .product = c.libinput_device_get_id_product(libinput_device),
            .bustype = c.libinput_device_get_id_bustype(libinput_device),
            .path = path,
        };
    }
    errdefer if (tablet_info) |info| if (info.path) |path| self.allocator.free(path);
    const tablet_pad_info = if (device_type == .tablet_pad)
        try self.createTabletPadInfo(libinput_device)
    else
        null;
    errdefer if (tablet_pad_info) |info| self.deinitTabletPadInfo(info);
    const retained_device = c.libinput_device_ref(libinput_device).?;
    errdefer _ = c.libinput_device_unref(retained_device);
    try self.input_devices.append(self.allocator, .{
        .info = .{
            .id = id,
            .physical_id = physicalId(libinput_device),
            .device_type = device_type,
            .name = name_copy,
            .vendor = c.libinput_device_get_id_vendor(libinput_device),
            .product = c.libinput_device_get_id_product(libinput_device),
        },
        .libinput_device = retained_device,
        .keyboard = keyboard,
        .tablet_info = tablet_info,
        .tablet_pad_info = tablet_pad_info,
    });
    if (device_type == .keyboard and self.active_keyboard == null) self.active_keyboard = id;
    if (self.device_listener) |listener| {
        listener.added(listener.context, self.input_devices.items[self.input_devices.items.len - 1].info);
    }
}

fn createTabletPadInfo(
    self: *Self,
    device: *c.struct_libinput_device,
) !TabletPadInfo {
    var path: ?[:0]u8 = null;
    if (c.libinput_device_get_udev_device(device)) |udev_device| {
        defer _ = c.udev_device_unref(udev_device);
        if (c.udev_device_get_devnode(udev_device)) |devnode| {
            path = try self.allocator.dupeSentinel(u8, std.mem.span(devnode), 0);
        }
    }
    errdefer if (path) |value| self.allocator.free(value);

    const button_count = try tabletPadCount(c.libinput_device_tablet_pad_get_num_buttons(device));
    const ring_count = try tabletPadCount(c.libinput_device_tablet_pad_get_num_rings(device));
    const strip_count = try tabletPadCount(c.libinput_device_tablet_pad_get_num_strips(device));
    const dial_count = try tabletPadCount(c.libinput_device_tablet_pad_get_num_dials(device));
    const group_count_native = c.libinput_device_tablet_pad_get_num_mode_groups(device);
    if (group_count_native <= 0) return error.InvalidTabletPad;
    const groups = try self.allocator.alloc(TabletPadGroupInfo, @intCast(group_count_native));
    var initialized: usize = 0;
    errdefer {
        for (groups[0..initialized]) |group| self.deinitTabletPadGroupInfo(group);
        self.allocator.free(groups);
    }
    while (initialized < groups.len) : (initialized += 1) {
        const group = c.libinput_device_tablet_pad_get_mode_group(
            device,
            @intCast(initialized),
        ) orelse return error.InvalidTabletPad;
        groups[initialized] = try self.createTabletPadGroupInfo(
            group,
            button_count,
            ring_count,
            strip_count,
            dial_count,
        );
    }
    return .{
        .path = path,
        .button_count = button_count,
        .groups = groups,
    };
}

fn createTabletPadGroupInfo(
    self: *Self,
    group: *c.struct_libinput_tablet_pad_mode_group,
    button_count: u32,
    ring_count: u32,
    strip_count: u32,
    dial_count: u32,
) !TabletPadGroupInfo {
    var buttons: std.ArrayList(u32) = .empty;
    defer buttons.deinit(self.allocator);
    var rings: std.ArrayList(u32) = .empty;
    defer rings.deinit(self.allocator);
    var strips: std.ArrayList(u32) = .empty;
    defer strips.deinit(self.allocator);
    var dials: std.ArrayList(u32) = .empty;
    defer dials.deinit(self.allocator);
    for (0..button_count) |index| {
        if (c.libinput_tablet_pad_mode_group_has_button(group, @intCast(index)) != 0) {
            try buttons.append(self.allocator, @intCast(index));
        }
    }
    for (0..ring_count) |index| {
        if (c.libinput_tablet_pad_mode_group_has_ring(group, @intCast(index)) != 0) {
            try rings.append(self.allocator, @intCast(index));
        }
    }
    for (0..strip_count) |index| {
        if (c.libinput_tablet_pad_mode_group_has_strip(group, @intCast(index)) != 0) {
            try strips.append(self.allocator, @intCast(index));
        }
    }
    for (0..dial_count) |index| {
        if (c.libinput_tablet_pad_mode_group_has_dial(group, @intCast(index)) != 0) {
            try dials.append(self.allocator, @intCast(index));
        }
    }
    const mode_count = c.libinput_tablet_pad_mode_group_get_num_modes(group);
    if (mode_count == 0) return error.InvalidTabletPad;
    const current_mode = c.libinput_tablet_pad_mode_group_get_mode(group);
    if (current_mode >= mode_count) return error.InvalidTabletPad;

    const owned_buttons = try buttons.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(owned_buttons);
    const owned_rings = try rings.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(owned_rings);
    const owned_strips = try strips.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(owned_strips);
    const owned_dials = try dials.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(owned_dials);
    return .{
        .buttons = owned_buttons,
        .rings = owned_rings,
        .strips = owned_strips,
        .dials = owned_dials,
        .mode_count = mode_count,
        .current_mode = current_mode,
    };
}

fn deinitTabletPadInfo(self: *Self, info: TabletPadInfo) void {
    if (info.path) |path| self.allocator.free(path);
    for (info.groups) |group| self.deinitTabletPadGroupInfo(group);
    self.allocator.free(info.groups);
}

fn deinitTabletPadGroupInfo(self: *Self, info: TabletPadGroupInfo) void {
    self.allocator.free(info.dials);
    self.allocator.free(info.strips);
    self.allocator.free(info.rings);
    self.allocator.free(info.buttons);
}

fn tabletPadCount(value: c_int) !u32 {
    if (value < 0) return error.InvalidTabletPad;
    return @intCast(value);
}

fn rollbackInputDevices(self: *Self, old_count: usize) void {
    while (self.input_devices.items.len > old_count) {
        var device = self.input_devices.pop().?;
        if (self.device_listener) |listener| listener.removed(listener.context, device.info.id);
        if (self.active_keyboard == device.info.id) self.active_keyboard = null;
        self.deinitInputDevice(&device);
    }
    self.promoteKeyboard();
}

fn removeInputDevices(self: *Self, libinput_device: *c.struct_libinput_device) void {
    var index = self.input_devices.items.len;
    while (index > 0) {
        index -= 1;
        var device = self.input_devices.items[index];
        if (device.libinput_device != libinput_device) continue;
        _ = self.input_devices.orderedRemove(index);
        if (self.device_listener) |listener| listener.removed(listener.context, device.info.id);
        if (self.active_keyboard == device.info.id) self.active_keyboard = null;
        self.deinitInputDevice(&device);
    }
    self.promoteKeyboard();
}

fn removeAllInputDevices(self: *Self) void {
    while (self.input_devices.pop()) |value| {
        var device = value;
        if (self.device_listener) |listener| listener.removed(listener.context, device.info.id);
        self.deinitInputDevice(&device);
    }
    self.active_keyboard = null;
}

fn deinitInputDevice(self: *Self, device: *InputDevice) void {
    self.removeTabletTools(device.info.id);
    if (device.keyboard) |*keyboard| {
        c.xkb_state_unref(keyboard.state);
        keyboard.keymap.unref();
    }
    if (device.tablet_info) |info| if (info.path) |path| self.allocator.free(path);
    if (device.tablet_pad_info) |info| self.deinitTabletPadInfo(info);
    self.allocator.free(device.info.name);
    _ = c.libinput_device_unref(device.libinput_device);
}

fn promoteKeyboard(self: *Self) void {
    if (self.active_keyboard != null) return;
    for (self.input_devices.items) |*device| {
        if (device.keyboard == null) continue;
        self.activateKeyboard(device) catch |err| return self.fail(err);
        return;
    }
}

fn keyboardKey(self: *Self, event: *c.struct_libinput_event_keyboard) void {
    const base_event = c.libinput_event_keyboard_get_base_event(event);
    const libinput_device = c.libinput_event_get_device(base_event).?;
    const device = self.findInputDevice(libinput_device, .keyboard) orelse return;
    const keyboard = if (device.keyboard) |*value| value else unreachable;
    const key = c.libinput_event_keyboard_get_key(event);
    const pressed = c.libinput_event_keyboard_get_key_state(event) == c.LIBINPUT_KEY_STATE_PRESSED;
    const seat_key_count = c.libinput_event_keyboard_get_seat_key_count(event);
    const forward = (pressed and seat_key_count == 1) or (!pressed and seat_key_count == 0);
    if (self.active_keyboard != device.info.id) {
        self.activateKeyboard(device) catch |err| return self.fail(err);
    } else {
        self.updateActiveRepeatInfo(device);
    }
    const binding_event = keyboardEvent(device, keyboard, key, pressed, forward);
    const emergency_captured = forward and self.handleEmergencyShortcut(key, pressed);
    const binding_disposition: KeyboardEventDisposition = if (!emergency_captured and
        self.keyboard_event_listener != null)
        self.keyboard_event_listener.?.key(
            self.keyboard_event_listener.?.context,
            binding_event,
        )
    else
        .forwarded;
    const binding_captured = binding_disposition == .captured;
    const old_state = stateSnapshot(keyboard);
    _ = c.xkb_state_update_key(
        keyboard.state,
        key + 8,
        if (pressed) c.XKB_KEY_DOWN else c.XKB_KEY_UP,
    );
    const new_state = stateSnapshot(keyboard);
    if (!keyboardStatesEqual(old_state, new_state)) self.notifyKeyboardState(device);
    log.debug("key {d} {s}", .{ key, if (pressed) "pressed" else "released" });
    if (!emergency_captured and !binding_captured) {
        self.listener.keyboard_key(
            self.listener.context,
            device.info.id,
            c.libinput_event_keyboard_get_time(event),
            key,
            if (pressed) .pressed else .released,
        );
    }
    self.sendKeyboardModifiers(keyboard, false);
}

fn handleEmergencyShortcut(self: *Self, key: u32, pressed: bool) bool {
    if (key == c.KEY_LEFTMETA) self.left_meta_pressed = pressed;
    if (key == c.KEY_RIGHTMETA) self.right_meta_pressed = pressed;
    if (key == c.KEY_LEFTCTRL) self.left_ctrl_pressed = pressed;
    if (key == c.KEY_RIGHTCTRL) self.right_ctrl_pressed = pressed;
    if (key == c.KEY_LEFTALT) self.left_alt_pressed = pressed;
    if (key == c.KEY_RIGHTALT) self.right_alt_pressed = pressed;
    if (!pressed and self.session_switch_key == key) {
        self.session_switch_key = null;
        return true;
    }
    if (pressed and (self.left_ctrl_pressed or self.right_ctrl_pressed) and
        (self.left_alt_pressed or self.right_alt_pressed))
    {
        if (key == c.KEY_BACKSPACE) {
            log.warn("Ctrl+Alt+Backspace requested compositor exit", .{});
            self.listener.close(self.listener.context);
            return true;
        }
        if (virtualTerminalForKey(key)) |session| {
            self.session_switch_key = key;
            log.info("requesting switch to VT {d}", .{session});
            self.session.switchSession(session) catch |err| {
                log.err("failed to switch to VT {d}: {t}", .{ session, err });
            };
            return true;
        }
    }
    return false;
}

fn activateKeyboard(self: *Self, device: *InputDevice) !void {
    const keyboard = if (device.keyboard) |*value| value else unreachable;
    try self.installKeymap(device.info.id, keyboard.keymap);
    self.active_keyboard = device.info.id;
    self.updateActiveRepeatInfo(device);
    self.sendKeyboardModifiers(keyboard, true);
}

fn updateActiveRepeatInfo(self: *Self, device: *const InputDevice) void {
    std.debug.assert(self.active_keyboard == device.info.id and device.keyboard != null);
    if (std.meta.eql(self.active_repeat_info, device.repeat_info)) return;
    self.active_repeat_info = device.repeat_info;
    self.listener.keyboard_repeat_info(
        self.listener.context,
        device.info.id,
        device.repeat_info.rate,
        device.repeat_info.delay,
    );
}

fn sendKeyboardModifiers(self: *Self, keyboard: *const Keyboard, force: bool) void {
    const modifiers: Modifiers = .{
        .depressed = c.xkb_state_serialize_mods(keyboard.state, c.XKB_STATE_MODS_DEPRESSED),
        .latched = c.xkb_state_serialize_mods(keyboard.state, c.XKB_STATE_MODS_LATCHED),
        .locked = c.xkb_state_serialize_mods(keyboard.state, c.XKB_STATE_MODS_LOCKED),
        .group = c.xkb_state_serialize_layout(keyboard.state, c.XKB_STATE_LAYOUT_EFFECTIVE),
    };
    if (!force and std.meta.eql(self.modifiers, modifiers)) return;
    const old_effective = effectiveModifiers(self.modifiers);
    self.modifiers = modifiers;
    self.listener.keyboard_modifiers(
        self.listener.context,
        self.active_keyboard,
        modifiers.depressed,
        modifiers.latched,
        modifiers.locked,
        modifiers.group,
    );
    const new_effective = effectiveModifiers(modifiers);
    if (old_effective != new_effective) if (self.keyboard_event_listener) |listener| {
        listener.modifiers(listener.context, self.active_keyboard, old_effective, new_effective);
    };
}

fn keyboardEvent(
    device: *const InputDevice,
    keyboard: *const Keyboard,
    key_code: u32,
    pressed: bool,
    seat_level: bool,
) KeyboardEvent {
    const xkb_key_code = key_code + 8;
    var symbols: [*c]const c.xkb_keysym_t = null;
    const layout = c.xkb_state_key_get_layout(keyboard.state, xkb_key_code);
    const count = if (layout == c.XKB_LAYOUT_INVALID)
        0
    else
        c.xkb_keymap_key_get_syms_by_level(keyboard.keymap.native, xkb_key_code, layout, 0, &symbols);
    const keysyms: []const u32 = if (count > 0 and symbols != null)
        symbols[0..@intCast(count)]
    else
        &.{};
    return .{
        .device_id = device.info.id,
        .key_code = key_code,
        .state = if (pressed) .pressed else .released,
        .seat_level = seat_level,
        .modifiers = effectiveKeyboardModifiers(keyboard),
        .keysyms = keysyms,
        .is_modifier = isModifierKeysyms(keysyms),
    };
}

fn effectiveKeyboardModifiers(keyboard: *const Keyboard) u32 {
    return effectiveModifiers(.{
        .depressed = c.xkb_state_serialize_mods(keyboard.state, c.XKB_STATE_MODS_DEPRESSED),
        .latched = c.xkb_state_serialize_mods(keyboard.state, c.XKB_STATE_MODS_LATCHED),
    });
}

fn effectiveModifiers(modifiers: Modifiers) u32 {
    return (modifiers.depressed | modifiers.latched) & 0xed;
}

fn isModifierKeysyms(keysyms: []const u32) bool {
    for (keysyms) |keysym| switch (keysym) {
        c.XKB_KEY_Shift_L,
        c.XKB_KEY_Shift_R,
        c.XKB_KEY_Control_L,
        c.XKB_KEY_Control_R,
        c.XKB_KEY_Caps_Lock,
        c.XKB_KEY_Shift_Lock,
        c.XKB_KEY_Meta_L,
        c.XKB_KEY_Meta_R,
        c.XKB_KEY_Alt_L,
        c.XKB_KEY_Alt_R,
        c.XKB_KEY_Super_L,
        c.XKB_KEY_Super_R,
        c.XKB_KEY_Hyper_L,
        c.XKB_KEY_Hyper_R,
        c.XKB_KEY_Mode_switch,
        c.XKB_KEY_Num_Lock,
        c.XKB_KEY_ISO_Level3_Shift,
        c.XKB_KEY_ISO_Level5_Shift,
        => return true,
        else => {},
    };
    return false;
}

fn resetKeyboardState(self: *Self) void {
    const old_effective = effectiveModifiers(self.modifiers);
    const old_keyboard = self.active_keyboard;
    self.active_keyboard = null;
    self.modifiers = .{};
    self.left_meta_pressed = false;
    self.right_meta_pressed = false;
    self.left_ctrl_pressed = false;
    self.right_ctrl_pressed = false;
    self.left_alt_pressed = false;
    self.right_alt_pressed = false;
    self.session_switch_key = null;
    self.listener.keyboard_modifiers(self.listener.context, null, 0, 0, 0, 0);
    if (old_effective != 0) if (self.keyboard_event_listener) |listener| {
        listener.modifiers(listener.context, old_keyboard, old_effective, 0);
    };
}

fn configuredKeyboardStateChanged(self: *Self, device: *InputDevice) void {
    const keyboard = if (device.keyboard) |*value| value else unreachable;
    if (self.active_keyboard == device.info.id) self.sendKeyboardModifiers(keyboard, false);
    self.notifyKeyboardState(device);
}

fn notifyKeyboardState(self: *Self, device: *const InputDevice) void {
    const listener = self.keyboard_state_listener orelse return;
    const keyboard = if (device.keyboard) |*value| value else unreachable;
    listener.changed(listener.context, device.info.id, stateSnapshot(keyboard));
}

fn setKeyboardLock(self: *Self, id: DeviceId, name: [*:0]const u8, enabled: bool) bool {
    const device = self.findInputDeviceById(id) orelse return false;
    const keyboard = if (device.keyboard) |*value| value else return false;
    const index = c.xkb_keymap_mod_get_index(keyboard.keymap.native, name);
    if (index == c.XKB_MOD_INVALID or index >= @bitSizeOf(c.xkb_mod_mask_t)) return true;
    const mask = @as(c.xkb_mod_mask_t, 1) << @intCast(index);
    _ = c.xkb_state_update_latched_locked(
        keyboard.state,
        0,
        0,
        false,
        0,
        mask,
        if (enabled) mask else 0,
        false,
        0,
    );
    self.configuredKeyboardStateChanged(device);
    return true;
}

fn stateSnapshot(keyboard: *const Keyboard) KeyboardState {
    const layout_index: u32 = c.xkb_state_serialize_layout(
        keyboard.state,
        c.XKB_STATE_LAYOUT_EFFECTIVE,
    );
    return .{
        .keymap = keyboard.keymap,
        .layout_index = layout_index,
        .layout_name = c.xkb_keymap_layout_get_name(keyboard.keymap.native, layout_index),
        .capslock_enabled = c.xkb_state_mod_name_is_active(
            keyboard.state,
            c.XKB_MOD_NAME_CAPS,
            c.XKB_STATE_MODS_LOCKED,
        ) > 0,
        .numlock_enabled = c.xkb_state_mod_name_is_active(
            keyboard.state,
            c.XKB_MOD_NAME_NUM,
            c.XKB_STATE_MODS_LOCKED,
        ) > 0,
    };
}

fn keyboardStatesEqual(a: KeyboardState, b: KeyboardState) bool {
    return a.keymap == b.keymap and
        a.layout_index == b.layout_index and
        a.capslock_enabled == b.capslock_enabled and
        a.numlock_enabled == b.numlock_enabled;
}

fn pointerMotion(self: *Self, event: *c.struct_libinput_event_pointer) void {
    const device = self.eventInputDevice(c.libinput_event_pointer_get_base_event(event).?, .pointer) orelse return;
    self.listener.pointer_relative_motion(
        self.listener.context,
        device.info.id,
        c.libinput_event_pointer_get_time_usec(event),
        c.libinput_event_pointer_get_dx(event),
        c.libinput_event_pointer_get_dy(event),
        c.libinput_event_pointer_get_dx_unaccelerated(event),
        c.libinput_event_pointer_get_dy_unaccelerated(event),
    );
    self.listener.pointer_frame(self.listener.context, device.info.id);
}

fn pointerMotionAbsolute(self: *Self, event: *c.struct_libinput_event_pointer) void {
    const device = self.eventInputDevice(c.libinput_event_pointer_get_base_event(event).?, .pointer) orelse return;
    const map = device.map orelse
        DeviceMap{ .x = 0, .y = 0, .width = self.size.width, .height = self.size.height };
    self.pointer_x = @as(f64, @floatFromInt(map.x)) +
        c.libinput_event_pointer_get_absolute_x_transformed(event, map.width);
    self.pointer_y = @as(f64, @floatFromInt(map.y)) +
        c.libinput_event_pointer_get_absolute_y_transformed(event, map.height);
    self.listener.pointer_motion(
        self.listener.context,
        device.info.id,
        c.libinput_event_pointer_get_time(event),
        self.pointer_x,
        self.pointer_y,
    );
    self.listener.pointer_frame(self.listener.context, device.info.id);
}

fn pointerButton(self: *Self, event: *c.struct_libinput_event_pointer) void {
    const device = self.eventInputDevice(c.libinput_event_pointer_get_base_event(event).?, .pointer) orelse return;
    const pressed = c.libinput_event_pointer_get_button_state(event) ==
        c.LIBINPUT_BUTTON_STATE_PRESSED;
    self.listener.pointer_button(
        self.listener.context,
        device.info.id,
        c.libinput_event_pointer_get_time(event),
        c.libinput_event_pointer_get_button(event),
        if (pressed) .pressed else .released,
    );
    self.listener.pointer_frame(self.listener.context, device.info.id);
}

fn pointerScroll(
    self: *Self,
    event: *c.struct_libinput_event_pointer,
    source: wl.Pointer.AxisSource,
) void {
    const device = self.eventInputDevice(c.libinput_event_pointer_get_base_event(event).?, .pointer) orelse return;
    self.listener.pointer_axis_source(self.listener.context, device.info.id, source);
    self.pointerScrollAxis(device, event, source, c.LIBINPUT_POINTER_AXIS_SCROLL_VERTICAL, .vertical_scroll);
    self.pointerScrollAxis(device, event, source, c.LIBINPUT_POINTER_AXIS_SCROLL_HORIZONTAL, .horizontal_scroll);
    self.listener.pointer_frame(self.listener.context, device.info.id);
}

fn pointerScrollAxis(
    self: *Self,
    device: *const InputDevice,
    event: *c.struct_libinput_event_pointer,
    source: wl.Pointer.AxisSource,
    libinput_axis: c.enum_libinput_pointer_axis,
    axis: wl.Pointer.Axis,
) void {
    if (c.libinput_event_pointer_has_axis(event, libinput_axis) == 0) return;
    const time = c.libinput_event_pointer_get_time(event);
    const factor = device.scroll_factor;
    const value = c.libinput_event_pointer_get_scroll_value(event, libinput_axis) * factor;
    if (value == 0 and source != .wheel) {
        self.listener.pointer_axis_stop(self.listener.context, device.info.id, time, axis);
        return;
    }
    self.listener.pointer_axis(
        self.listener.context,
        device.info.id,
        time,
        axis,
        wl.Fixed.fromDouble(value),
    );
    if (source == .wheel) {
        const value_120 = c.libinput_event_pointer_get_scroll_value_v120(event, libinput_axis) * factor;
        const discrete: i32 = @intFromFloat(@round(value_120 / 120));
        self.listener.pointer_axis_value120(
            self.listener.context,
            device.info.id,
            axis,
            @intFromFloat(@round(value_120)),
        );
        if (discrete != 0) {
            self.listener.pointer_axis_discrete(self.listener.context, device.info.id, axis, discrete);
        }
    }
}

fn swipeBegin(self: *Self, event: *c.struct_libinput_event_gesture) void {
    const device = self.gestureInputDevice(event) orelse return;
    const fingers = gestureFingerCount(event) orelse return;
    self.listener.swipe_begin(
        self.listener.context,
        device.info.id,
        c.libinput_event_gesture_get_time(event),
        fingers,
    );
}

fn swipeUpdate(self: *Self, event: *c.struct_libinput_event_gesture) void {
    const device = self.gestureInputDevice(event) orelse return;
    self.listener.swipe_update(
        self.listener.context,
        device.info.id,
        c.libinput_event_gesture_get_time(event),
        c.libinput_event_gesture_get_dx(event),
        c.libinput_event_gesture_get_dy(event),
    );
}

fn swipeEnd(self: *Self, event: *c.struct_libinput_event_gesture) void {
    const device = self.gestureInputDevice(event) orelse return;
    self.listener.swipe_end(
        self.listener.context,
        device.info.id,
        c.libinput_event_gesture_get_time(event),
        c.libinput_event_gesture_get_cancelled(event) != 0,
    );
}

fn pinchBegin(self: *Self, event: *c.struct_libinput_event_gesture) void {
    const device = self.gestureInputDevice(event) orelse return;
    const fingers = gestureFingerCount(event) orelse return;
    self.listener.pinch_begin(
        self.listener.context,
        device.info.id,
        c.libinput_event_gesture_get_time(event),
        fingers,
    );
}

fn pinchUpdate(self: *Self, event: *c.struct_libinput_event_gesture) void {
    const device = self.gestureInputDevice(event) orelse return;
    self.listener.pinch_update(
        self.listener.context,
        device.info.id,
        c.libinput_event_gesture_get_time(event),
        c.libinput_event_gesture_get_dx(event),
        c.libinput_event_gesture_get_dy(event),
        c.libinput_event_gesture_get_scale(event),
        c.libinput_event_gesture_get_angle_delta(event),
    );
}

fn pinchEnd(self: *Self, event: *c.struct_libinput_event_gesture) void {
    const device = self.gestureInputDevice(event) orelse return;
    self.listener.pinch_end(
        self.listener.context,
        device.info.id,
        c.libinput_event_gesture_get_time(event),
        c.libinput_event_gesture_get_cancelled(event) != 0,
    );
}

fn holdBegin(self: *Self, event: *c.struct_libinput_event_gesture) void {
    const device = self.gestureInputDevice(event) orelse return;
    const fingers = gestureFingerCount(event) orelse return;
    self.listener.hold_begin(
        self.listener.context,
        device.info.id,
        c.libinput_event_gesture_get_time(event),
        fingers,
    );
}

fn holdEnd(self: *Self, event: *c.struct_libinput_event_gesture) void {
    const device = self.gestureInputDevice(event) orelse return;
    self.listener.hold_end(
        self.listener.context,
        device.info.id,
        c.libinput_event_gesture_get_time(event),
        c.libinput_event_gesture_get_cancelled(event) != 0,
    );
}

fn gestureInputDevice(
    self: *Self,
    event: *c.struct_libinput_event_gesture,
) ?*InputDevice {
    const base = c.libinput_event_gesture_get_base_event(event) orelse return null;
    return self.eventInputDevice(base, .pointer);
}

fn gestureFingerCount(event: *c.struct_libinput_event_gesture) ?u32 {
    const fingers = c.libinput_event_gesture_get_finger_count(event);
    return if (fingers > 0) @intCast(fingers) else null;
}

fn tabletToolProximity(self: *Self, event: *c.struct_libinput_event_tablet_tool) void {
    const device = self.tabletInputDevice(event) orelse return;
    const tool = self.ensureTabletTool(device, event) catch |err| {
        self.fail(err);
        return;
    } orelse return;
    const map = device.map orelse
        DeviceMap{ .x = 0, .y = 0, .width = self.size.width, .height = self.size.height };
    const x = @as(f64, @floatFromInt(map.x)) +
        c.libinput_event_tablet_tool_get_x_transformed(event, map.width);
    const y = @as(f64, @floatFromInt(map.y)) +
        c.libinput_event_tablet_tool_get_y_transformed(event, map.height);
    const in_proximity = c.libinput_event_tablet_tool_get_proximity_state(event) ==
        c.LIBINPUT_TABLET_TOOL_PROXIMITY_STATE_IN;
    const axes: TabletToolAxes = if (in_proximity) self.tabletToolAxes(device, event) else .{};
    self.listener.tablet_tool_proximity(
        self.listener.context,
        device.info.id,
        tool.info.id,
        c.libinput_event_tablet_tool_get_time(event),
        x,
        y,
        in_proximity,
        axes,
    );
}

fn tabletToolAxis(self: *Self, event: *c.struct_libinput_event_tablet_tool) void {
    const device = self.tabletInputDevice(event) orelse return;
    const tool = self.ensureTabletTool(device, event) catch |err| {
        self.fail(err);
        return;
    } orelse return;
    const axes = self.tabletToolAxes(device, event);
    if (!axes.hasChanges()) return;
    self.listener.tablet_tool_axis(
        self.listener.context,
        device.info.id,
        tool.info.id,
        c.libinput_event_tablet_tool_get_time(event),
        axes,
    );
}

fn tabletToolTip(self: *Self, event: *c.struct_libinput_event_tablet_tool) void {
    const device = self.tabletInputDevice(event) orelse return;
    const tool = self.ensureTabletTool(device, event) catch |err| {
        self.fail(err);
        return;
    } orelse return;
    self.listener.tablet_tool_tip(
        self.listener.context,
        device.info.id,
        tool.info.id,
        c.libinput_event_tablet_tool_get_time(event),
        self.tabletToolAxes(device, event),
        c.libinput_event_tablet_tool_get_tip_state(event) == c.LIBINPUT_TABLET_TOOL_TIP_DOWN,
    );
}

fn tabletToolButton(self: *Self, event: *c.struct_libinput_event_tablet_tool) void {
    const device = self.tabletInputDevice(event) orelse return;
    const tool = self.ensureTabletTool(device, event) catch |err| {
        self.fail(err);
        return;
    } orelse return;
    self.listener.tablet_tool_button(
        self.listener.context,
        device.info.id,
        tool.info.id,
        c.libinput_event_tablet_tool_get_time(event),
        self.tabletToolAxes(device, event),
        c.libinput_event_tablet_tool_get_button(event),
        c.libinput_event_tablet_tool_get_button_state(event) == c.LIBINPUT_BUTTON_STATE_PRESSED,
    );
}

const TabletPadEventRoute = struct {
    device: *InputDevice,
    time: u32,
    group: u32,
    mode: u32,
};

fn tabletPadButton(self: *Self, event: *c.struct_libinput_event_tablet_pad) void {
    const route = self.tabletPadEventRoute(event) orelse return;
    self.listener.tablet_pad_button(
        self.listener.context,
        route.device.info.id,
        route.time,
        c.libinput_event_tablet_pad_get_button_number(event),
        c.libinput_event_tablet_pad_get_button_state(event) == c.LIBINPUT_BUTTON_STATE_PRESSED,
        route.group,
        route.mode,
    );
}

fn tabletPadRing(self: *Self, event: *c.struct_libinput_event_tablet_pad) void {
    const route = self.tabletPadEventRoute(event) orelse return;
    self.listener.tablet_pad_ring(
        self.listener.context,
        route.device.info.id,
        route.time,
        c.libinput_event_tablet_pad_get_ring_number(event),
        c.libinput_event_tablet_pad_get_ring_position(event),
        c.libinput_event_tablet_pad_get_ring_source(event) ==
            c.LIBINPUT_TABLET_PAD_RING_SOURCE_FINGER,
        route.group,
        route.mode,
    );
}

fn tabletPadStrip(self: *Self, event: *c.struct_libinput_event_tablet_pad) void {
    const route = self.tabletPadEventRoute(event) orelse return;
    self.listener.tablet_pad_strip(
        self.listener.context,
        route.device.info.id,
        route.time,
        c.libinput_event_tablet_pad_get_strip_number(event),
        c.libinput_event_tablet_pad_get_strip_position(event),
        c.libinput_event_tablet_pad_get_strip_source(event) ==
            c.LIBINPUT_TABLET_PAD_STRIP_SOURCE_FINGER,
        route.group,
        route.mode,
    );
}

fn tabletPadDial(self: *Self, event: *c.struct_libinput_event_tablet_pad) void {
    const route = self.tabletPadEventRoute(event) orelse return;
    const value120 = protocolValue120(
        c.libinput_event_tablet_pad_get_dial_delta_v120(event),
    ) orelse return;
    self.listener.tablet_pad_dial(
        self.listener.context,
        route.device.info.id,
        route.time,
        c.libinput_event_tablet_pad_get_dial_number(event),
        value120,
        route.group,
        route.mode,
    );
}

fn tabletPadEventRoute(
    self: *Self,
    event: *c.struct_libinput_event_tablet_pad,
) ?TabletPadEventRoute {
    const base = c.libinput_event_tablet_pad_get_base_event(event) orelse return null;
    const device = self.eventInputDevice(base, .tablet_pad) orelse return null;
    const group = c.libinput_event_tablet_pad_get_mode_group(event) orelse return null;
    const group_index = c.libinput_tablet_pad_mode_group_get_index(group);
    const info = device.tablet_pad_info orelse return null;
    if (group_index >= info.groups.len) return null;
    const mode = c.libinput_event_tablet_pad_get_mode(event);
    if (mode >= info.groups[group_index].mode_count) return null;
    return .{
        .device = device,
        .time = c.libinput_event_tablet_pad_get_time(event),
        .group = group_index,
        .mode = mode,
    };
}

fn protocolValue120(value: f64) ?i32 {
    if (!std.math.isFinite(value)) return null;
    const rounded = @round(value);
    const clamped = std.math.clamp(
        rounded,
        @as(f64, @floatFromInt(std.math.minInt(i32))),
        @as(f64, @floatFromInt(std.math.maxInt(i32))),
    );
    const result: i32 = @intFromFloat(clamped);
    return if (result == 0) null else result;
}

fn tabletToolAxes(
    self: *const Self,
    device: *const InputDevice,
    event: *c.struct_libinput_event_tablet_tool,
) TabletToolAxes {
    var axes: TabletToolAxes = .{};
    if (c.libinput_event_tablet_tool_x_has_changed(event) != 0 or
        c.libinput_event_tablet_tool_y_has_changed(event) != 0)
    {
        const map = device.map orelse
            DeviceMap{ .x = 0, .y = 0, .width = self.size.width, .height = self.size.height };
        axes.position = .{
            .x = @as(f64, @floatFromInt(map.x)) +
                c.libinput_event_tablet_tool_get_x_transformed(event, map.width),
            .y = @as(f64, @floatFromInt(map.y)) +
                c.libinput_event_tablet_tool_get_y_transformed(event, map.height),
        };
    }
    if (c.libinput_event_tablet_tool_pressure_has_changed(event) != 0) {
        axes.pressure = c.libinput_event_tablet_tool_get_pressure(event);
    }
    if (c.libinput_event_tablet_tool_distance_has_changed(event) != 0) {
        axes.distance = c.libinput_event_tablet_tool_get_distance(event);
    }
    if (c.libinput_event_tablet_tool_tilt_x_has_changed(event) != 0 or
        c.libinput_event_tablet_tool_tilt_y_has_changed(event) != 0)
    {
        axes.tilt = .{
            .x = c.libinput_event_tablet_tool_get_tilt_x(event),
            .y = c.libinput_event_tablet_tool_get_tilt_y(event),
        };
    }
    if (c.libinput_event_tablet_tool_rotation_has_changed(event) != 0) {
        axes.rotation = c.libinput_event_tablet_tool_get_rotation(event);
    }
    if (c.libinput_event_tablet_tool_slider_has_changed(event) != 0) {
        axes.slider = c.libinput_event_tablet_tool_get_slider_position(event);
    }
    if (c.libinput_event_tablet_tool_wheel_has_changed(event) != 0) {
        axes.wheel = .{
            .degrees = c.libinput_event_tablet_tool_get_wheel_delta(event),
            .clicks = c.libinput_event_tablet_tool_get_wheel_delta_discrete(event),
        };
    }
    return axes;
}

fn tabletInputDevice(
    self: *Self,
    event: *c.struct_libinput_event_tablet_tool,
) ?*InputDevice {
    const base = c.libinput_event_tablet_tool_get_base_event(event) orelse return null;
    return self.eventInputDevice(base, .tablet);
}

fn ensureTabletTool(
    self: *Self,
    device: *const InputDevice,
    event: *c.struct_libinput_event_tablet_tool,
) !?*TabletTool {
    const native = c.libinput_event_tablet_tool_get_tool(event) orelse return null;
    for (self.tablet_tools.items) |*tool| {
        if (tool.device_id == device.info.id and tool.native == native) return tool;
    }
    const tool_type: TabletToolType = switch (c.libinput_tablet_tool_get_type(native)) {
        c.LIBINPUT_TABLET_TOOL_TYPE_PEN => .pen,
        c.LIBINPUT_TABLET_TOOL_TYPE_ERASER => .eraser,
        c.LIBINPUT_TABLET_TOOL_TYPE_BRUSH => .brush,
        c.LIBINPUT_TABLET_TOOL_TYPE_PENCIL => .pencil,
        c.LIBINPUT_TABLET_TOOL_TYPE_AIRBRUSH => .airbrush,
        c.LIBINPUT_TABLET_TOOL_TYPE_MOUSE => .mouse,
        c.LIBINPUT_TABLET_TOOL_TYPE_LENS => .lens,
        else => return null,
    };
    const id = self.next_tablet_tool_id;
    self.next_tablet_tool_id = std.math.add(TabletToolId, id, 1) catch return error.OutOfMemory;
    _ = c.libinput_tablet_tool_ref(native);
    errdefer _ = c.libinput_tablet_tool_unref(native);
    const serial = c.libinput_tablet_tool_get_serial(native);
    const hardware_id = c.libinput_tablet_tool_get_tool_id(native);
    try self.tablet_tools.append(self.allocator, .{
        .info = .{
            .id = id,
            .tool_type = tool_type,
            .serial = if (c.libinput_tablet_tool_is_unique(native) != 0 and serial != 0)
                serial
            else
                null,
            .hardware_id = if (hardware_id != 0) hardware_id else null,
            .capabilities = .{
                .pressure = c.libinput_tablet_tool_has_pressure(native) != 0,
                .distance = c.libinput_tablet_tool_has_distance(native) != 0,
                .tilt = c.libinput_tablet_tool_has_tilt(native) != 0,
                .rotation = c.libinput_tablet_tool_has_rotation(native) != 0,
                .slider = c.libinput_tablet_tool_has_slider(native) != 0,
                .wheel = c.libinput_tablet_tool_has_wheel(native) != 0,
            },
        },
        .device_id = device.info.id,
        .native = native,
    });
    return &self.tablet_tools.items[self.tablet_tools.items.len - 1];
}

fn removeTabletTools(self: *Self, device_id: DeviceId) void {
    var index = self.tablet_tools.items.len;
    while (index > 0) {
        index -= 1;
        const tool = self.tablet_tools.items[index];
        if (tool.device_id != device_id) continue;
        _ = self.tablet_tools.orderedRemove(index);
        _ = c.libinput_tablet_tool_unref(tool.native);
    }
}

fn touchDown(self: *Self, event: *c.struct_libinput_event_touch) void {
    const device = self.eventInputDevice(c.libinput_event_touch_get_base_event(event).?, .touch) orelse return;
    const map = device.map orelse
        DeviceMap{ .x = 0, .y = 0, .width = self.size.width, .height = self.size.height };
    self.listener.touch_down(
        self.listener.context,
        device.info.id,
        c.libinput_event_touch_get_time(event),
        c.libinput_event_touch_get_seat_slot(event),
        @as(f64, @floatFromInt(map.x)) + c.libinput_event_touch_get_x_transformed(event, map.width),
        @as(f64, @floatFromInt(map.y)) + c.libinput_event_touch_get_y_transformed(event, map.height),
    );
}

fn touchUp(self: *Self, event: *c.struct_libinput_event_touch) void {
    const device = self.eventInputDevice(c.libinput_event_touch_get_base_event(event).?, .touch) orelse return;
    self.listener.touch_up(
        self.listener.context,
        device.info.id,
        c.libinput_event_touch_get_time(event),
        c.libinput_event_touch_get_seat_slot(event),
    );
}

fn touchMotion(self: *Self, event: *c.struct_libinput_event_touch) void {
    const device = self.eventInputDevice(c.libinput_event_touch_get_base_event(event).?, .touch) orelse return;
    const map = device.map orelse
        DeviceMap{ .x = 0, .y = 0, .width = self.size.width, .height = self.size.height };
    self.listener.touch_motion(
        self.listener.context,
        device.info.id,
        c.libinput_event_touch_get_time(event),
        c.libinput_event_touch_get_seat_slot(event),
        @as(f64, @floatFromInt(map.x)) + c.libinput_event_touch_get_x_transformed(event, map.width),
        @as(f64, @floatFromInt(map.y)) + c.libinput_event_touch_get_y_transformed(event, map.height),
    );
}

fn touchCancelOrFrame(self: *Self, event: *c.struct_libinput_event, cancel: bool) void {
    const device = self.eventInputDevice(event, .touch) orelse return;
    if (cancel) {
        self.listener.touch_cancel(self.listener.context, device.info.id);
    } else {
        self.listener.touch_frame(self.listener.context, device.info.id);
    }
}

fn findInputDeviceById(self: *Self, id: DeviceId) ?*InputDevice {
    for (self.input_devices.items) |*device| if (device.info.id == id) return device;
    return null;
}

fn findInputDevice(
    self: *Self,
    libinput_device: *c.struct_libinput_device,
    device_type: DeviceType,
) ?*InputDevice {
    for (self.input_devices.items) |*device| {
        if (device.libinput_device == libinput_device and device.info.device_type == device_type) {
            return device;
        }
    }
    return null;
}

fn eventInputDevice(
    self: *Self,
    event: *c.struct_libinput_event,
    device_type: DeviceType,
) ?*InputDevice {
    return self.findInputDevice(c.libinput_event_get_device(event).?, device_type);
}

fn clearCapabilities(self: *Self) void {
    self.removeAllInputDevices();
    if (self.keyboard_count != 0) self.listener.keyboard_available(self.listener.context, false);
    if (self.pointer_count != 0) self.listener.pointer_available(self.listener.context, false);
    if (self.touch_count != 0) self.listener.touch_available(self.listener.context, false);
    self.keyboard_count = 0;
    self.pointer_count = 0;
    self.touch_count = 0;
    self.resetKeyboardState();
}

fn discardEvents(self: *Self) void {
    if (c.libinput_dispatch(self.context) != 0) return self.fail(error.LibinputDispatchFailed);
    while (c.libinput_get_event(self.context)) |event| c.libinput_event_destroy(event);
}

fn fail(self: *Self, err: anyerror) void {
    if (self.failed) return;
    self.failed = true;
    log.err("native input failed: {t}", .{err});
    if (self.event_source) |source| {
        source.remove();
        self.event_source = null;
    }
    if (self.initialized) self.listener.close(self.listener.context);
}

fn handleEvent(_: c_int, mask: wl.EventMask, self: *Self) c_int {
    if (mask.hangup or mask.@"error") {
        self.fail(error.InputDisconnected);
    } else if (mask.readable) {
        self.dispatchEvents() catch |err| self.fail(err);
    }
    return 0;
}

fn handleSessionActivated(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.failed or !self.suspended) return;
    log.info("resuming input", .{});
    if (c.libinput_resume(self.context) != 0) return self.fail(error.ResumeFailed);
    self.suspended = false;
    self.dispatchEvents() catch |err| self.fail(err);
}

fn handleSessionDeactivated(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.suspended) return;
    log.info("suspending input", .{});
    self.clearCapabilities();
    self.suspended = true;
    c.libinput_suspend(self.context);
    self.discardEvents();
}

fn handleSessionFailed(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.fail(error.SessionFailed);
}

fn openRestricted(path: [*c]const u8, _: c_int, data: ?*anyopaque) callconv(.c) c_int {
    const self: *Self = @ptrCast(@alignCast(data.?));
    const device = self.session.openDevice(std.mem.span(path)) catch return -1;
    self.devices.put(self.allocator, device.fd, device) catch {
        self.session.closeDevice(device) catch {};
        return -1;
    };
    return device.fd;
}

fn closeRestricted(fd: c_int, data: ?*anyopaque) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(data.?));
    const entry = self.devices.fetchRemove(fd) orelse {
        log.err("libinput closed unknown device fd {d}", .{fd});
        return;
    };
    self.session.closeDevice(entry.value) catch |err| {
        log.err("failed to close input device: {t}", .{err});
    };
}

fn clampCoordinate(value: f64, dimension: u32) f64 {
    std.debug.assert(dimension > 0);
    return std.math.clamp(value, 0, @as(f64, @floatFromInt(dimension - 1)));
}

fn physicalId(device: *c.struct_libinput_device) PhysicalDeviceId {
    return @intFromPtr(device);
}

fn statusFromNative(status: c.enum_libinput_config_status) Status {
    return switch (status) {
        c.LIBINPUT_CONFIG_STATUS_SUCCESS => .success,
        c.LIBINPUT_CONFIG_STATUS_UNSUPPORTED => .unsupported,
        c.LIBINPUT_CONFIG_STATUS_INVALID => .invalid,
        else => unreachable,
    };
}

fn nativeEnum(comptime T: type, value: anytype) T {
    return @enumFromInt(switch (@typeInfo(@TypeOf(value))) {
        .@"enum" => @intFromEnum(value),
        .int => value,
        else => unreachable,
    });
}

fn setting(comptime T: type, default: anytype, current: @TypeOf(default)) Setting(T) {
    return .{ .default = nativeEnum(T, default), .current = nativeEnum(T, current) };
}

fn settingBool(default: c_int, current: c_int) Setting(Toggle) {
    return .{
        .default = if (default == 0) .disabled else .enabled,
        .current = if (current == 0) .disabled else .enabled,
    };
}

fn validMatrix(matrix: CalibrationMatrix) bool {
    for (matrix) |value| if (!std.math.isFinite(value)) return false;
    return true;
}

fn validAccelPoints(step: f64, points: []const f64) bool {
    if (!std.math.isFinite(step) or step <= 0 or points.len == 0) return false;
    for (points) |point| if (!std.math.isFinite(point)) return false;
    return true;
}

fn virtualTerminalForKey(key: u32) ?u32 {
    return switch (key) {
        c.KEY_F1...c.KEY_F10 => key - c.KEY_F1 + 1,
        c.KEY_F11 => 11,
        c.KEY_F12 => 12,
        else => null,
    };
}

test "function keys map to virtual terminals" {
    try std.testing.expectEqual(@as(?u32, 1), virtualTerminalForKey(c.KEY_F1));
    try std.testing.expectEqual(@as(?u32, 10), virtualTerminalForKey(c.KEY_F10));
    try std.testing.expectEqual(@as(?u32, 11), virtualTerminalForKey(c.KEY_F11));
    try std.testing.expectEqual(@as(?u32, 12), virtualTerminalForKey(c.KEY_F12));
    try std.testing.expectEqual(@as(?u32, null), virtualTerminalForKey(c.KEY_ENTER));
}

test "keymap compiler works without native input" {
    var compiler: KeymapCompiler = undefined;
    try compiler.init(std.testing.allocator, std.testing.io);
    defer compiler.deinit();

    const default = try compiler.defaultKeymap();
    defer default.unref();
    const text_pointer = c.xkb_keymap_get_as_string(
        default.native,
        c.XKB_KEYMAP_FORMAT_TEXT_V1,
    ) orelse return error.SerializeKeymapFailed;
    defer c.free(text_pointer);
    const compiled = (try compiler.compile(.text_v1, std.mem.span(text_pointer))).?;
    compiled.unref();
}

test "native pointer coordinates stay inside the output" {
    try std.testing.expectEqual(@as(f64, 0), clampCoordinate(-5, 100));
    try std.testing.expectEqual(@as(f64, 99), clampCoordinate(120, 100));
    try std.testing.expectEqual(@as(f64, 42.5), clampCoordinate(42.5, 100));
}

test "tablet pad dial deltas use nonzero value120 units" {
    try std.testing.expectEqual(@as(?i32, 120), protocolValue120(120));
    try std.testing.expectEqual(@as(?i32, -30), protocolValue120(-30.4));
    try std.testing.expectEqual(@as(?i32, null), protocolValue120(0.1));
    try std.testing.expectEqual(@as(?i32, null), protocolValue120(std.math.nan(f64)));
}

test "libinput configuration status mapping" {
    try std.testing.expectEqual(Status.success, statusFromNative(c.LIBINPUT_CONFIG_STATUS_SUCCESS));
    try std.testing.expectEqual(Status.unsupported, statusFromNative(c.LIBINPUT_CONFIG_STATUS_UNSUPPORTED));
    try std.testing.expectEqual(Status.invalid, statusFromNative(c.LIBINPUT_CONFIG_STATUS_INVALID));
}

test "typed configuration enums match libinput semantics" {
    try std.testing.expectEqual(@as(u3, c.LIBINPUT_CONFIG_ACCEL_PROFILE_CUSTOM), @intFromEnum(AccelProfile.custom));
    try std.testing.expectEqual(@as(u2, c.LIBINPUT_CONFIG_DRAG_LOCK_ENABLED_STICKY), @intFromEnum(DragLock.sticky));
    try std.testing.expectEqual(@as(u3, c.LIBINPUT_CONFIG_SCROLL_ON_BUTTON_DOWN), @intFromEnum(ScrollMethod.on_button_down));
}

test "configuration value validation" {
    try std.testing.expect(validMatrix(.{ 1, 0, 0, 0, 1, 0 }));
    try std.testing.expect(!validMatrix(.{ 1, 0, std.math.nan(f32), 0, 1, 0 }));
    try std.testing.expect(validAccelPoints(0.5, &.{ 0, 1, 2 }));
    try std.testing.expect(!validAccelPoints(0, &.{1}));
    try std.testing.expect(!validAccelPoints(1, &.{}));
    try std.testing.expect(!validAccelPoints(1, &.{std.math.inf(f64)}));
}

test "modifier keysyms are classified for chord handling" {
    try std.testing.expect(isModifierKeysyms(&.{c.XKB_KEY_Shift_L}));
    try std.testing.expect(isModifierKeysyms(&.{c.XKB_KEY_ISO_Level3_Shift}));
    try std.testing.expect(!isModifierKeysyms(&.{c.XKB_KEY_a}));
}
