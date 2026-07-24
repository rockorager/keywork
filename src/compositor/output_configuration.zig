//! Ordered output-rule resolution independent of output mutation.

const std = @import("std");
const Config = @import("config.zig");
const DrmOutput = @import("backend/drm.zig");
const render = @import("render/types.zig");

pub const LiveSettings = struct {
    enabled: bool,
    mode_index: usize,
    x: i32,
    y: i32,
    scale: render.Scale,
};

pub const ResolvedSettings = struct {
    enabled: bool,
    mode_index: usize,
    x: i32,
    y: i32,
    scale: render.Scale,
    icc_profile: ?Config.OutputIccProfile = null,
};

/// Applies every matching rule in declaration order. Unspecified settings
/// retain their live values; an absent return means no rule matched.
pub fn resolve(
    live: LiveSettings,
    device: Config.OutputDeviceMatch,
    modes: []const DrmOutput.Mode,
    rules: []const Config.OutputRule,
) !?ResolvedSettings {
    var resolved: ResolvedSettings = .{
        .enabled = live.enabled,
        .mode_index = live.mode_index,
        .x = live.x,
        .y = live.y,
        .scale = live.scale,
    };
    var requested_mode: ?Config.OutputMode = null;
    var matched = false;
    for (rules) |rule| {
        if (!rule.matcher.matches(device)) continue;
        matched = true;
        const settings = rule.settings;
        if (settings.enable) |enabled| resolved.enabled = enabled;
        if (settings.position) |position| {
            resolved.x = position.x;
            resolved.y = position.y;
        }
        if (settings.mode) |mode| requested_mode = mode;
        if (settings.scale_v120_numerator) |numerator| {
            resolved.scale = .{ .numerator = numerator };
        }
        if (settings.icc_profile) |profile| resolved.icc_profile = profile;
    }
    if (!matched) return null;
    if (requested_mode) |mode| resolved.mode_index = try resolveMode(modes, mode);
    return resolved;
}

fn resolveMode(modes: []const DrmOutput.Mode, requested: Config.OutputMode) !usize {
    var selected: ?usize = null;
    for (modes, 0..) |mode, index| {
        const size = mode.size();
        if (size.width != requested.width or size.height != requested.height) continue;
        if (selected == null or if (requested.refresh_millihertz) |refresh|
            @abs(@as(i64, mode.refreshMillihertz()) - refresh) <
                @abs(@as(i64, modes[selected.?].refreshMillihertz()) - refresh)
        else
            mode.preferred and !modes[selected.?].preferred)
        {
            selected = index;
        }
    }
    return selected orelse error.OutputModeUnavailable;
}

fn testOutputMode(width: u16, height: u16, refresh_hertz: u32, preferred: bool) DrmOutput.Mode {
    var mode = std.mem.zeroes(DrmOutput.Mode);
    mode.value.hdisplay = width;
    mode.value.vdisplay = height;
    mode.value.vrefresh = refresh_hertz;
    mode.preferred = preferred;
    return mode;
}

test "matching rules overlay in order and preserve live fields" {
    const rules = [_]Config.OutputRule{
        .{
            .matcher = .{ .name = "DP-*" },
            .settings = .{
                .enable = false,
                .position = .{ .x = 10, .y = 20 },
                .scale_v120_numerator = 180,
                .icc_profile = .{ .path = "display.icc" },
            },
        },
        .{
            .matcher = .{ .make = "Acme" },
            .settings = .{
                .enable = true,
                .position = .{ .x = 30, .y = 40 },
                .icc_profile = .none,
            },
        },
    };
    const resolved = (try resolve(
        .{
            .enabled = true,
            .mode_index = 2,
            .x = 41,
            .y = -3,
            .scale = .{ .numerator = 120 },
        },
        .{ .name = "DP-1", .make = "Acme" },
        &.{},
        &rules,
    )).?;

    try std.testing.expect(resolved.enabled);
    try std.testing.expectEqual(@as(usize, 2), resolved.mode_index);
    try std.testing.expectEqual(@as(i32, 30), resolved.x);
    try std.testing.expectEqual(@as(i32, 40), resolved.y);
    try std.testing.expectEqual(@as(u32, 180), resolved.scale.numerator);
    try std.testing.expectEqual(Config.OutputIccProfile.none, resolved.icc_profile.?);
}

test "nonmatching output rules are omitted" {
    const rules = [_]Config.OutputRule{.{
        .matcher = .{ .name = "DP-*" },
        .settings = .{ .enable = false },
    }};
    try std.testing.expect(try resolve(
        .{ .enabled = true, .mode_index = 0, .x = 4, .y = 5, .scale = .{} },
        .{ .name = "HDMI-A-1" },
        &.{},
        &rules,
    ) == null);
}

test "mode resolution prefers preferred and closest refresh" {
    const modes = [_]DrmOutput.Mode{
        testOutputMode(1920, 1080, 60, false),
        testOutputMode(1920, 1080, 75, true),
        testOutputMode(1920, 1080, 120, false),
        testOutputMode(1280, 720, 60, true),
    };
    try std.testing.expectEqual(@as(usize, 1), try resolveMode(&modes, .{
        .width = 1920,
        .height = 1080,
    }));
    try std.testing.expectEqual(@as(usize, 2), try resolveMode(&modes, .{
        .width = 1920,
        .height = 1080,
        .refresh_millihertz = 110_000,
    }));
}

test "mode resolution rejects unavailable size" {
    const modes = [_]DrmOutput.Mode{testOutputMode(1920, 1080, 60, true)};
    try std.testing.expectError(error.OutputModeUnavailable, resolveMode(&modes, .{
        .width = 2560,
        .height = 1440,
    }));
}
