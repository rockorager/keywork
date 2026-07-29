//! Ordered input-rule resolution independent of device mutation.

const std = @import("std");
const Config = @import("config.zig");
const NativeInput = @import("backend/native_input.zig");

const log = std.log.scoped(.input_configuration);

pub const EffectiveSettings = struct {
    send_events: NativeInput.SendEventsModes,
    tap: ?NativeInput.Toggle,
    tap_button_map: ?NativeInput.TapButtonMap,
    drag: ?NativeInput.Toggle,
    drag_lock: ?NativeInput.DragLock,
    three_finger_drag: ?NativeInput.ThreeFingerDrag,
    accel_profile: ?NativeInput.AccelProfile,
    accel_speed: ?f64,
    natural_scroll: ?NativeInput.Toggle,
    left_handed: ?NativeInput.Toggle,
    click_method: ?NativeInput.ClickMethod,
    clickfinger_button_map: ?NativeInput.ClickfingerButtonMap,
    middle_emulation: ?NativeInput.Toggle,
    scroll_method: ?NativeInput.ScrollMethod,
    scroll_button: ?u32,
    scroll_button_lock: ?NativeInput.Toggle,
    disable_while_typing: ?NativeInput.Toggle,
    disable_while_trackpointing: ?NativeInput.Toggle,
    rotation: ?u32,
    scroll_factor: f64 = 1,
    repeat_rate: i32 = 25,
    repeat_delay: i32 = 600,
};

pub fn resolve(
    defaults: NativeInput.DeviceConfig,
    device: Config.InputDeviceMatch,
    rules: []const Config.InputRule,
) EffectiveSettings {
    var effective: EffectiveSettings = .{
        .send_events = defaults.send_events.default,
        .tap = settingDefault(NativeInput.Toggle, defaults.tap),
        .tap_button_map = settingDefault(NativeInput.TapButtonMap, defaults.tap_button_map),
        .drag = settingDefault(NativeInput.Toggle, defaults.drag),
        .drag_lock = settingDefault(NativeInput.DragLock, defaults.drag_lock),
        .three_finger_drag = settingDefault(NativeInput.ThreeFingerDrag, defaults.three_finger_drag),
        .accel_profile = if (defaults.accel_profiles) |setting| setting.default else null,
        .accel_speed = if (defaults.accel_profiles) |setting| setting.speed.default else null,
        .natural_scroll = settingDefault(NativeInput.Toggle, defaults.natural_scroll),
        .left_handed = settingDefault(NativeInput.Toggle, defaults.left_handed),
        .click_method = if (defaults.click_method) |setting| setting.default else null,
        .clickfinger_button_map = settingDefault(NativeInput.ClickfingerButtonMap, defaults.clickfinger_button_map),
        .middle_emulation = settingDefault(NativeInput.Toggle, defaults.middle_emulation),
        .scroll_method = if (defaults.scroll_method) |setting| setting.default else null,
        .scroll_button = settingDefault(u32, defaults.scroll_button),
        .scroll_button_lock = settingDefault(NativeInput.Toggle, defaults.scroll_button_lock),
        .disable_while_typing = settingDefault(NativeInput.Toggle, defaults.dwt),
        .disable_while_trackpointing = settingDefault(NativeInput.Toggle, defaults.dwtp),
        .rotation = settingDefault(u32, defaults.rotation),
    };
    for (rules) |rule| {
        if (!rule.matcher.matches(device)) continue;
        overlayInputSettings(&effective, defaults, device, rule.settings);
    }
    return effective;
}

fn settingDefault(comptime T: type, setting: ?NativeInput.Setting(T)) ?T {
    return if (setting) |value| value.default else null;
}

fn overlayInputSettings(
    effective: *EffectiveSettings,
    defaults: NativeInput.DeviceConfig,
    device: Config.InputDeviceMatch,
    settings: Config.InputSettings,
) void {
    if (settings.send_events) |configured| {
        effective.send_events = switch (configured) {
            .use_default => defaults.send_events.default,
            .value => |value| switch (value) {
                .enabled => .{},
                .disabled => .{ .disabled = true },
                .disabled_on_external_mouse => .{ .disabled_on_external_mouse = true },
            },
        };
    }
    overlayNativeSetting(NativeInput.Toggle, &effective.tap, settingDefault(NativeInput.Toggle, defaults.tap), settings.tap, device.name, "tap");
    overlayNativeSetting(NativeInput.TapButtonMap, &effective.tap_button_map, settingDefault(NativeInput.TapButtonMap, defaults.tap_button_map), settings.tap_button_map, device.name, "tap-button-map");
    overlayNativeSetting(NativeInput.Toggle, &effective.drag, settingDefault(NativeInput.Toggle, defaults.drag), settings.drag, device.name, "drag");
    overlayNativeSetting(NativeInput.DragLock, &effective.drag_lock, settingDefault(NativeInput.DragLock, defaults.drag_lock), settings.drag_lock, device.name, "drag-lock");
    overlayNativeSetting(NativeInput.ThreeFingerDrag, &effective.three_finger_drag, settingDefault(NativeInput.ThreeFingerDrag, defaults.three_finger_drag), settings.three_finger_drag, device.name, "three-finger-drag");
    overlayNativeSetting(NativeInput.AccelProfile, &effective.accel_profile, if (defaults.accel_profiles) |setting| setting.default else null, settings.accel_profile, device.name, "accel-profile");
    overlayNativeSetting(f64, &effective.accel_speed, if (defaults.accel_profiles) |setting| setting.speed.default else null, settings.accel_speed, device.name, "accel-speed");
    overlayNativeSetting(NativeInput.Toggle, &effective.natural_scroll, settingDefault(NativeInput.Toggle, defaults.natural_scroll), settings.natural_scroll, device.name, "natural-scroll");
    overlayNativeSetting(NativeInput.Toggle, &effective.left_handed, settingDefault(NativeInput.Toggle, defaults.left_handed), settings.left_handed, device.name, "left-handed");
    overlayNativeSetting(NativeInput.ClickMethod, &effective.click_method, if (defaults.click_method) |setting| setting.default else null, settings.click_method, device.name, "click-method");
    overlayNativeSetting(NativeInput.ClickfingerButtonMap, &effective.clickfinger_button_map, settingDefault(NativeInput.ClickfingerButtonMap, defaults.clickfinger_button_map), settings.clickfinger_button_map, device.name, "clickfinger-button-map");
    overlayNativeSetting(NativeInput.Toggle, &effective.middle_emulation, settingDefault(NativeInput.Toggle, defaults.middle_emulation), settings.middle_emulation, device.name, "middle-emulation");
    overlayNativeSetting(NativeInput.ScrollMethod, &effective.scroll_method, if (defaults.scroll_method) |setting| setting.default else null, settings.scroll_method, device.name, "scroll-method");
    overlayNativeSetting(u32, &effective.scroll_button, settingDefault(u32, defaults.scroll_button), settings.scroll_button, device.name, "scroll-button");
    overlayNativeSetting(NativeInput.Toggle, &effective.scroll_button_lock, settingDefault(NativeInput.Toggle, defaults.scroll_button_lock), settings.scroll_button_lock, device.name, "scroll-button-lock");
    overlayNativeSetting(NativeInput.Toggle, &effective.disable_while_typing, settingDefault(NativeInput.Toggle, defaults.dwt), settings.disable_while_typing, device.name, "disable-while-typing");
    overlayNativeSetting(NativeInput.Toggle, &effective.disable_while_trackpointing, settingDefault(NativeInput.Toggle, defaults.dwtp), settings.disable_while_trackpointing, device.name, "disable-while-trackpointing");
    overlayNativeSetting(u32, &effective.rotation, settingDefault(u32, defaults.rotation), settings.rotation, device.name, "rotation");
    overlayDeviceSetting(f64, &effective.scroll_factor, 1, settings.scroll_factor, device.pointer, device.name, "scroll-factor");
    overlayDeviceSetting(i32, &effective.repeat_rate, 25, settings.repeat_rate, device.keyboard, device.name, "repeat-rate");
    overlayDeviceSetting(i32, &effective.repeat_delay, 600, settings.repeat_delay, device.keyboard, device.name, "repeat-delay");
}

fn overlayNativeSetting(
    comptime T: type,
    effective: *?T,
    default_value: ?T,
    configured: ?Config.InputValue(T),
    device_name: []const u8,
    setting_name: []const u8,
) void {
    const value = configured orelse return;
    const default = default_value orelse {
        log.warn("input setting {s} is unsupported by {s}", .{ setting_name, device_name });
        return;
    };
    effective.* = value.resolve(default);
}

fn overlayDeviceSetting(
    comptime T: type,
    effective: *T,
    default_value: T,
    configured: ?Config.InputValue(T),
    supported: bool,
    device_name: []const u8,
    setting_name: []const u8,
) void {
    const value = configured orelse return;
    if (!supported) {
        log.warn("input setting {s} is unsupported by {s}", .{ setting_name, device_name });
        return;
    }
    effective.* = value.resolve(default_value);
}

test "input settings overlay in order and can restore defaults" {
    const defaults: NativeInput.DeviceConfig = .{
        .physical_id = 1,
        .send_events = .{ .supported = .{ .disabled = true }, .default = .{}, .current = .{} },
        .tap_finger_count = 2,
        .tap = .{ .default = .disabled, .current = .disabled },
        .tap_button_map = null,
        .drag = null,
        .drag_lock = null,
        .three_finger_drag_count = 0,
        .three_finger_drag = null,
        .calibration_matrix = null,
        .accel_profiles = .{
            .supported = .{ .adaptive = true },
            .default = .adaptive,
            .current = .adaptive,
            .speed = .{ .default = 0, .current = 0 },
        },
        .natural_scroll = .{ .default = .disabled, .current = .disabled },
        .left_handed = null,
        .click_method = null,
        .clickfinger_button_map = null,
        .middle_emulation = null,
        .scroll_method = null,
        .scroll_button = null,
        .scroll_button_lock = null,
        .dwt = null,
        .dwtp = null,
        .rotation = null,
    };
    const device: Config.InputDeviceMatch = .{
        .name = "Test Touchpad",
        .vendor = 1,
        .product = 2,
        .keyboard = true,
        .pointer = true,
        .touchpad = true,
    };
    const rules = [_]Config.InputRule{
        .{
            .matcher = .{ .name = "Test Touchpad" },
            .settings = .{
                .send_events = .{ .value = .disabled },
                .tap = .{ .value = .enabled },
                .accel_speed = .{ .value = 0.5 },
                .natural_scroll = .{ .value = .enabled },
                .scroll_factor = .{ .value = 0.75 },
                .repeat_rate = .{ .value = 30 },
            },
        },
        .{
            .matcher = .{ .name = "Test Touchpad" },
            .settings = .{
                .tap = .use_default,
                .natural_scroll = .use_default,
                .scroll_factor = .use_default,
            },
        },
    };
    const effective = resolve(defaults, device, &rules);

    try std.testing.expect(effective.send_events.disabled);
    try std.testing.expectEqual(NativeInput.Toggle.disabled, effective.tap.?);
    try std.testing.expectEqual(@as(f64, 0.5), effective.accel_speed.?);
    try std.testing.expectEqual(NativeInput.Toggle.disabled, effective.natural_scroll.?);
    try std.testing.expectEqual(@as(f64, 1), effective.scroll_factor);
    try std.testing.expectEqual(@as(i32, 30), effective.repeat_rate);
}
