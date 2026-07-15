//! Policy-neutral API for River input configuration.

const std = @import("std");

pub const DeviceType = enum { keyboard, pointer, touch, tablet };
pub const BinaryState = enum { disabled, enabled };
pub const TapButtonMap = enum { lrm, lmr };
pub const DragLockState = enum { disabled, enabled_timeout, enabled_sticky };
pub const ThreeFingerDragState = enum { disabled, enabled_3fg, enabled_4fg };
pub const AccelProfile = enum(u32) { none = 0, flat = 1, adaptive = 2, custom = 4 };
pub const ClickMethod = enum(u32) { none = 0, button_areas = 1, clickfinger = 2 };
pub const ScrollMethod = enum(u32) { no_scroll = 0, two_finger = 1, edge = 2, on_button_down = 4 };
pub const AccelType = enum { fallback, motion, scroll };
pub const KeymapFormat = enum { text_v1, text_v2 };

pub fn Value(comptime T: type) type {
    return struct { default: ?T = null, current: ?T = null };
}

pub fn SupportedValue(comptime T: type, comptime S: type) type {
    return struct { support: ?S = null, default: ?T = null, current: ?T = null };
}

/// Every value advertised by river_libinput_device_v1. Optional fields mean
/// that the compositor has not advertised that value (yet), not unsupported.
pub const LibinputState = struct {
    send_events: SupportedValue(u32, u32) = .{},
    tap: SupportedValue(BinaryState, i32) = .{},
    tap_button_map: Value(TapButtonMap) = .{},
    drag: Value(BinaryState) = .{},
    drag_lock: Value(DragLockState) = .{},
    three_finger_drag: SupportedValue(ThreeFingerDragState, i32) = .{},
    calibration_matrix: SupportedValue([6]f32, bool) = .{},
    accel_profile: SupportedValue(AccelProfile, u32) = .{},
    accel_speed: Value(f64) = .{},
    natural_scroll: SupportedValue(BinaryState, bool) = .{},
    left_handed: SupportedValue(BinaryState, bool) = .{},
    click_method: SupportedValue(ClickMethod, u32) = .{},
    clickfinger_button_map: Value(TapButtonMap) = .{},
    middle_emulation: SupportedValue(BinaryState, bool) = .{},
    scroll_method: SupportedValue(ScrollMethod, u32) = .{},
    scroll_button: Value(u32) = .{},
    scroll_button_lock: Value(BinaryState) = .{},
    dwt: SupportedValue(BinaryState, bool) = .{},
    dwtp: SupportedValue(BinaryState, bool) = .{},
    rotation: SupportedValue(u32, bool) = .{},
};

pub const KeyboardState = struct {
    layout_index: ?u32 = null,
    layout_name: ?[]const u8 = null,
    capslock: ?bool = null,
    numlock: ?bool = null,
};

pub const Device = struct {
    id: u32,
    type: ?DeviceType = null,
    name: ?[]const u8 = null,
    libinput: ?LibinputState = null,
    keyboard: ?KeyboardState = null,
};

pub const Output = struct { id: u32, registry_name: u32, name: ?[]const u8 = null };
pub const KeymapState = enum { pending, ready, failed };
pub const Keymap = struct { id: []const u8, state: KeymapState, error_message: ?[]const u8 = null };
pub const AccelConfig = struct { id: []const u8, profile: AccelProfile };
pub const ResultTarget = union(enum) { device: u32, accel_config: []const u8 };
pub const ResultStatus = enum { success, unsupported, invalid };
pub const Operation = enum {
    set_send_events,
    set_tap,
    set_tap_button_map,
    set_drag,
    set_drag_lock,
    set_three_finger_drag,
    set_calibration_matrix,
    set_accel_profile,
    set_accel_speed,
    apply_accel_config,
    set_natural_scroll,
    set_left_handed,
    set_click_method,
    set_clickfinger_button_map,
    set_middle_emulation,
    set_scroll_method,
    set_scroll_button,
    set_scroll_button_lock,
    set_dwt,
    set_dwtp,
    set_rotation,
    set_accel_points,
};
pub const LibinputResult = struct { target: ResultTarget, operation: Operation, status: ResultStatus };
pub const KeymapFailure = struct { id: []const u8, error_message: []const u8 };

pub const Event = union(enum) {
    device_added: u32,
    device_removed: u32,
    state_changed: u32,
    output_added: u32,
    output_removed: u32,
    keymap_ready: []const u8,
    keymap_failed: KeymapFailure,
    libinput_result: LibinputResult,
};

pub const Context = struct {
    devices: []const Device,
    outputs: []const Output,
    keymaps: []const Keymap,
    accel_configs: []const AccelConfig,
    events: []const Event,
    input_management_version: u32,
    libinput_config_version: u32,
    xkb_config_version: u32,
};

pub const DeviceTarget = struct { device: u32 };
pub const DeviceBool = struct { device: u32, enabled: bool };
pub const Command = union(enum) {
    create_seat: struct { name: []const u8 },
    destroy_seat: struct { name: []const u8 },
    assign_to_seat: struct { device: u32, name: []const u8 },
    set_repeat_info: struct { device: u32, rate: i32, delay: i32 },
    set_scroll_factor: struct { device: u32, factor: f64 },
    map_to_output: struct { device: u32, output: ?u32 },
    map_to_rectangle: struct { device: u32, x: i32, y: i32, width: i32, height: i32 },
    create_keymap: struct { id: []const u8, text: []const u8, format: KeymapFormat },
    destroy_keymap: struct { id: []const u8 },
    set_keymap: struct { device: u32, id: []const u8 },
    set_layout_by_index: struct { device: u32, index: i32 },
    set_layout_by_name: struct { device: u32, name: []const u8 },
    set_capslock: DeviceBool,
    set_numlock: DeviceBool,
    create_accel_config: struct { id: []const u8, profile: AccelProfile },
    destroy_accel_config: struct { id: []const u8 },
    set_accel_points: struct { id: []const u8, type: AccelType, step: f64, points: []const f64 },
    apply_accel_config: struct { device: u32, id: []const u8 },
    set_send_events: struct { device: u32, mode: u32 },
    set_tap: struct { device: u32, state: BinaryState },
    set_tap_button_map: struct { device: u32, map: TapButtonMap },
    set_drag: struct { device: u32, state: BinaryState },
    set_drag_lock: struct { device: u32, state: DragLockState },
    set_three_finger_drag: struct { device: u32, state: ThreeFingerDragState },
    set_calibration_matrix: struct { device: u32, matrix: [6]f32 },
    set_accel_profile: struct { device: u32, profile: AccelProfile },
    set_accel_speed: struct { device: u32, speed: f64 },
    set_natural_scroll: DeviceBool,
    set_left_handed: DeviceBool,
    set_click_method: struct { device: u32, method: ClickMethod },
    set_clickfinger_button_map: struct { device: u32, map: TapButtonMap },
    set_middle_emulation: DeviceBool,
    set_scroll_method: struct { device: u32, method: ScrollMethod },
    set_scroll_button: struct { device: u32, button: u32 },
    set_scroll_button_lock: DeviceBool,
    set_dwt: DeviceBool,
    set_dwtp: DeviceBool,
    set_rotation: struct { device: u32, angle: u32 },
};

pub const Host = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        refresh: *const fn (*anyopaque) anyerror!void,
        update: *const fn (*anyopaque, std.mem.Allocator, Context) anyerror![]Command,
        bind_invalidator: *const fn (*anyopaque, *anyopaque, *const fn (*anyopaque) anyerror!void) anyerror!void,
        unbind_invalidator: *const fn (*anyopaque) void,
    };
    pub fn refresh(self: Host) !void {
        try self.vtable.refresh(self.ptr);
    }
    pub fn update(self: Host, allocator: std.mem.Allocator, context: Context) ![]Command {
        return self.vtable.update(self.ptr, allocator, context);
    }
    pub fn bindInvalidator(self: Host, ptr: *anyopaque, callback: *const fn (*anyopaque) anyerror!void) !void {
        try self.vtable.bind_invalidator(self.ptr, ptr, callback);
    }
    pub fn unbindInvalidator(self: Host) void {
        self.vtable.unbind_invalidator(self.ptr);
    }
};
