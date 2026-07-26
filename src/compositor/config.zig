//! Declarative keywork.conf loading and validation.

const std = @import("std");
const command = @import("command.zig");
const theme = @import("theme.zig");
const Command = command.Command;
const Direction = command.Direction;
const WindowTarget = command.WindowTarget;
const Launcher = @import("launcher.zig");
const NativeInput = @import("backend/native_input.zig");

const c = @cImport({
    @cInclude("xkbcommon/xkbcommon.h");
});
const log = std.log.scoped(.config);
const default_source = @embedFile("default-config");
const maximum_file_size = 1024 * 1024;

pub const super: u32 = 1 << 6; // xkb Mod4/Logo
pub const shift: u32 = 1 << 0;
pub const control: u32 = 1 << 2;
pub const alt: u32 = 1 << 3;

pub const Action = union(enum) {
    command: Command,
    run: []const []const u8,
};

pub const Binding = struct {
    modifiers: u32,
    keysym: u32,
    action: Action,
    repeat: bool = false,
};

pub fn InputValue(comptime T: type) type {
    return union(enum) {
        use_default,
        value: T,

        pub fn resolve(self: @This(), default_value: T) T {
            return switch (self) {
                .use_default => default_value,
                .value => |value| value,
            };
        }
    };
}

pub const InputDeviceType = enum {
    keyboard,
    pointer,
    touchpad,
    touch,
    tablet,
    tablet_pad,
};

pub const SendEvents = enum {
    enabled,
    disabled,
    disabled_on_external_mouse,
};

pub const InputMatcher = struct {
    device_type: ?InputDeviceType = null,
    name: ?[]const u8 = null,
    vendor: ?u32 = null,
    product: ?u32 = null,

    pub fn matches(self: InputMatcher, device: InputDeviceMatch) bool {
        if (self.device_type) |expected| {
            const type_matches = switch (expected) {
                .keyboard => device.keyboard,
                .pointer => device.pointer,
                .touchpad => device.touchpad,
                .touch => device.touch,
                .tablet => device.tablet,
                .tablet_pad => device.tablet_pad,
            };
            if (!type_matches) return false;
        }
        if (self.name) |pattern| if (!globMatches(pattern, device.name)) return false;
        if (self.vendor) |vendor| if (vendor != device.vendor) return false;
        if (self.product) |product| if (product != device.product) return false;
        return true;
    }
};

pub const InputDeviceMatch = struct {
    name: []const u8,
    vendor: u32,
    product: u32,
    keyboard: bool = false,
    pointer: bool = false,
    touchpad: bool = false,
    touch: bool = false,
    tablet: bool = false,
    tablet_pad: bool = false,
};

pub const InputSettings = struct {
    send_events: ?InputValue(SendEvents) = null,
    tap: ?InputValue(NativeInput.Toggle) = null,
    tap_button_map: ?InputValue(NativeInput.TapButtonMap) = null,
    drag: ?InputValue(NativeInput.Toggle) = null,
    drag_lock: ?InputValue(NativeInput.DragLock) = null,
    three_finger_drag: ?InputValue(NativeInput.ThreeFingerDrag) = null,
    accel_profile: ?InputValue(NativeInput.AccelProfile) = null,
    accel_speed: ?InputValue(f64) = null,
    natural_scroll: ?InputValue(NativeInput.Toggle) = null,
    left_handed: ?InputValue(NativeInput.Toggle) = null,
    click_method: ?InputValue(NativeInput.ClickMethod) = null,
    clickfinger_button_map: ?InputValue(NativeInput.ClickfingerButtonMap) = null,
    middle_emulation: ?InputValue(NativeInput.Toggle) = null,
    scroll_method: ?InputValue(NativeInput.ScrollMethod) = null,
    scroll_button: ?InputValue(u32) = null,
    scroll_button_lock: ?InputValue(NativeInput.Toggle) = null,
    disable_while_typing: ?InputValue(NativeInput.Toggle) = null,
    disable_while_trackpointing: ?InputValue(NativeInput.Toggle) = null,
    rotation: ?InputValue(u32) = null,
    scroll_factor: ?InputValue(f64) = null,
    repeat_rate: ?InputValue(i32) = null,
    repeat_delay: ?InputValue(i32) = null,
};

pub const InputRule = struct {
    matcher: InputMatcher,
    settings: InputSettings = .{},
};

pub const OutputDeviceMatch = struct {
    name: []const u8,
    make: ?[]const u8 = null,
    model: ?[]const u8 = null,
    serial: ?[]const u8 = null,
};

pub const OutputMatcher = struct {
    name: ?[]const u8 = null,
    make: ?[]const u8 = null,
    model: ?[]const u8 = null,
    serial: ?[]const u8 = null,

    pub fn matches(self: OutputMatcher, output: OutputDeviceMatch) bool {
        if (self.name) |pattern| if (!globMatches(pattern, output.name)) return false;
        inline for (.{ "make", "model", "serial" }) |field| {
            if (@field(self, field)) |pattern| {
                const actual = @field(output, field) orelse return false;
                if (!globMatches(pattern, actual)) return false;
            }
        }
        return true;
    }
};

pub const OutputMode = struct {
    width: u32,
    height: u32,
    refresh_millihertz: ?i32 = null,
};

pub const OutputPosition = struct { x: i32, y: i32 };

pub const OutputIccProfile = union(enum) {
    none,
    path: []const u8,
};

pub const OutputSettings = struct {
    enable: ?bool = null,
    mode: ?OutputMode = null,
    position: ?OutputPosition = null,
    scale_v120_numerator: ?u32 = null,
    icc_profile: ?OutputIccProfile = null,
};

pub const OutputRule = struct {
    matcher: OutputMatcher,
    settings: OutputSettings = .{},
};

pub const Color = theme.Color;

pub const GeneralSettings = struct {
    focus_follows_mouse: bool = true,
    inner_gap: u32 = 12,
    outer_gap: u32 = 12,
    corner_radius: u32 = 12,
    shadow_enabled: bool = true,
    shadow_blur_radius: ?u32 = null,
    shadow_color: ?Color = null,
    focused_shadow_color: ?Color = null,
    unfocused_border_width: u32 = 1,
    unfocused_border_color: ?Color = null,
    focused_border_width: u32 = 2,
    focused_border_color: ?Color = null,
};

pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    general: GeneralSettings,
    bindings: []const Binding,
    input_rules: []const InputRule,
    output_rules: []const OutputRule,

    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Problem = enum {
    invalid_section,
    unknown_section,
    directive_outside_section,
    invalid_directive,
    unknown_directive,
    invalid_general_setting,
    unknown_general_setting,
    duplicate_general_setting,
    empty_binding,
    unterminated_quote,
    dangling_escape,
    invalid_trigger,
    invalid_modifier,
    duplicate_modifier,
    duplicate_binding,
    invalid_key,
    unknown_action,
    invalid_action_arguments,
    invalid_direction,
    invalid_window_target,
    invalid_layout,
    invalid_workspace,
    invalid_executable,
    invalid_input_matcher,
    unknown_input_matcher,
    duplicate_input_matcher,
    invalid_input_setting,
    unknown_input_setting,
    duplicate_input_setting,
    invalid_output_matcher,
    unknown_output_matcher,
    duplicate_output_matcher,
    invalid_output_setting,
    unknown_output_setting,
    duplicate_output_setting,
};

pub const Diagnostic = struct {
    line: usize,
    problem: Problem,
};

pub const ParseResult = union(enum) {
    snapshot: Snapshot,
    diagnostic: Diagnostic,
};

const BindingError = error{
    EmptyBinding,
    UnterminatedQuote,
    DanglingEscape,
    InvalidTrigger,
    InvalidModifier,
    DuplicateModifier,
    InvalidKey,
    UnknownAction,
    InvalidActionArguments,
    InvalidDirection,
    InvalidWindowTarget,
    InvalidLayout,
    InvalidWorkspace,
    InvalidExecutable,
};

const LoadAttempt = union(enum) {
    not_found,
    snapshot: Snapshot,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    explicit_path: ?[]u8,
    failure_message: ?[]u8,
    snapshot: Snapshot,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        environ_map: *const std.process.Environ.Map,
        explicit_path: ?[]const u8,
    ) !Store {
        const owned_path = if (explicit_path) |path| try allocator.dupe(u8, path) else null;
        errdefer if (owned_path) |path| allocator.free(path);
        var self: Store = .{
            .allocator = allocator,
            .io = io,
            .environ_map = environ_map,
            .explicit_path = owned_path,
            .failure_message = null,
            .snapshot = undefined,
        };
        errdefer if (self.failure_message) |message| allocator.free(message);
        self.snapshot = self.loadSnapshot() catch |err| switch (err) {
            error.InvalidConfiguration, error.ConfigurationReadFailed => fallback: {
                log.warn("initial configuration failed; using built-in defaults", .{});
                break :fallback try defaultSnapshot(allocator);
            },
            else => return err,
        };
        return self;
    }

    pub fn deinit(self: *Store) void {
        self.snapshot.deinit();
        if (self.explicit_path) |path| self.allocator.free(path);
        if (self.failure_message) |message| self.allocator.free(message);
        self.* = undefined;
    }

    /// Returns a completely parsed replacement without changing active state.
    pub fn loadSnapshot(self: *Store) !Snapshot {
        if (self.failure_message) |message| self.allocator.free(message);
        self.failure_message = null;

        if (self.explicit_path) |path| return switch (try loadPath(
            self.allocator,
            self.io,
            path,
            &self.failure_message,
        )) {
            .snapshot => |snapshot| snapshot,
            .not_found => fallback: {
                log.info("no configuration found at {s}; using built-in defaults", .{path});
                break :fallback try defaultSnapshot(self.allocator);
            },
        };

        if (self.environ_map.get("XDG_CONFIG_HOME")) |directory| {
            if (std.fs.path.isAbsolute(directory)) {
                if (try loadBelow(self.allocator, self.io, directory, &self.failure_message)) |snapshot| return snapshot;
            }
        } else if (self.environ_map.get("HOME")) |home| {
            const directory = try std.fs.path.join(self.allocator, &.{ home, ".config" });
            defer self.allocator.free(directory);
            if (try loadBelow(self.allocator, self.io, directory, &self.failure_message)) |snapshot| return snapshot;
        }

        const config_directories = self.environ_map.get("XDG_CONFIG_DIRS") orelse "/etc/xdg";
        var iterator = std.mem.splitScalar(u8, config_directories, ':');
        while (iterator.next()) |directory| {
            if (directory.len == 0 or !std.fs.path.isAbsolute(directory)) continue;
            if (try loadBelow(self.allocator, self.io, directory, &self.failure_message)) |snapshot| return snapshot;
        }
        log.info("no configuration found; using built-in defaults", .{});
        return defaultSnapshot(self.allocator);
    }

    pub fn failureMessage(self: *const Store) ?[]const u8 {
        return self.failure_message;
    }
};

fn defaultSnapshot(allocator: std.mem.Allocator) !Snapshot {
    return switch (try parse(allocator, default_source)) {
        .snapshot => |snapshot| snapshot,
        .diagnostic => |diagnostic| {
            log.err(
                "built-in configuration:{d}: {s}",
                .{ diagnostic.line, problemMessage(diagnostic.problem) },
            );
            return error.InvalidDefaultConfiguration;
        },
    };
}

fn loadBelow(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
    failure_message: *?[]u8,
) !?Snapshot {
    const path = try std.fs.path.join(allocator, &.{ directory, "keywork", "config" });
    defer allocator.free(path);
    return switch (try loadPath(allocator, io, path, failure_message)) {
        .not_found => null,
        .snapshot => |snapshot| snapshot,
    };
}

fn loadPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    failure_message: *?[]u8,
) !LoadAttempt {
    const source = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(maximum_file_size),
    ) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return .not_found,
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            std.debug.assert(failure_message.* == null);
            failure_message.* = try std.fmt.allocPrint(
                allocator,
                "{s}: could not read configuration: {t}",
                .{ path, err },
            );
            log.err("{s}", .{failure_message.*.?});
            return error.ConfigurationReadFailed;
        },
    };
    defer allocator.free(source);
    const result = try parse(allocator, source);
    return switch (result) {
        .snapshot => |snapshot| loaded: {
            log.info("loaded configuration from {s}", .{path});
            break :loaded .{ .snapshot = snapshot };
        },
        .diagnostic => |diagnostic| {
            std.debug.assert(failure_message.* == null);
            failure_message.* = try std.fmt.allocPrint(
                allocator,
                "{s}:{d}: {s}",
                .{ path, diagnostic.line, problemMessage(diagnostic.problem) },
            );
            log.err("{s}", .{failure_message.*.?});
            return error.InvalidConfiguration;
        },
    };
}

/// Parses `source` into a diagnostic or an allocator-backed snapshot. The
/// caller owns a returned snapshot and must call `Snapshot.deinit`.
pub fn parse(allocator: std.mem.Allocator, source: []const u8) !ParseResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();
    var general: GeneralParser = .{};
    var bindings: std.ArrayList(Binding) = .empty;
    var input_rules: std.ArrayList(InputRule) = .empty;
    var output_rules: std.ArrayList(OutputRule) = .empty;
    var section: Section = .none;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_number: usize = 0;
    while (lines.next()) |raw_line| {
        line_number += 1;
        const line = std.mem.trim(u8, std.mem.trimEnd(u8, raw_line, "\r"), " \t");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (line[0] == '[') {
            if (line.len < 2 or line[line.len - 1] != ']') {
                arena.deinit();
                return .{ .diagnostic = .{ .line = line_number, .problem = .invalid_section } };
            }
            const header = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            if (std.mem.eql(u8, header, "general")) {
                section = .general;
                continue;
            }
            if (std.mem.eql(u8, header, "bindings")) {
                section = .bindings;
                continue;
            }
            if (parseOutputHeader(arena_allocator, header) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                arena.deinit();
                return .{ .diagnostic = .{ .line = line_number, .problem = problemForOutputHeaderError(err) } };
            }) |matcher| {
                try output_rules.append(arena_allocator, .{ .matcher = matcher });
                section = .{ .output = output_rules.items.len - 1 };
                continue;
            }
            const matcher = parseInputHeader(arena_allocator, header) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                arena.deinit();
                return .{ .diagnostic = .{
                    .line = line_number,
                    .problem = problemForInputHeaderError(err),
                } };
            } orelse {
                arena.deinit();
                return .{ .diagnostic = .{ .line = line_number, .problem = .unknown_section } };
            };
            try input_rules.append(arena_allocator, .{ .matcher = matcher });
            section = .{ .input = input_rules.items.len - 1 };
            continue;
        }
        if (section == .none) {
            arena.deinit();
            return .{ .diagnostic = .{ .line = line_number, .problem = .directive_outside_section } };
        }
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse {
            arena.deinit();
            return .{ .diagnostic = .{ .line = line_number, .problem = .invalid_directive } };
        };
        const name = std.mem.trim(u8, line[0..equals], " \t");
        const value = std.mem.trim(u8, line[equals + 1 ..], " \t");
        switch (section) {
            .none => unreachable,
            .general => parseGeneralSetting(&general, name, value) catch |err| {
                arena.deinit();
                return .{ .diagnostic = .{
                    .line = line_number,
                    .problem = problemForGeneralSettingError(err),
                } };
            },
            .bindings => {
                const repeat = if (std.mem.eql(u8, name, "bind"))
                    false
                else if (std.mem.eql(u8, name, "bind-repeat"))
                    true
                else {
                    arena.deinit();
                    return .{ .diagnostic = .{ .line = line_number, .problem = .unknown_directive } };
                };
                var binding = parseBinding(arena_allocator, value) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    arena.deinit();
                    return .{ .diagnostic = .{
                        .line = line_number,
                        .problem = problemForError(err),
                    } };
                };
                binding.repeat = repeat;
                for (bindings.items) |existing| {
                    if (existing.modifiers == binding.modifiers and
                        existing.keysym == binding.keysym)
                    {
                        arena.deinit();
                        return .{ .diagnostic = .{
                            .line = line_number,
                            .problem = .duplicate_binding,
                        } };
                    }
                }
                try bindings.append(arena_allocator, binding);
            },
            .input => |index| parseInputSetting(&input_rules.items[index].settings, name, value) catch |err| {
                arena.deinit();
                return .{ .diagnostic = .{
                    .line = line_number,
                    .problem = problemForInputSettingError(err),
                } };
            },
            .output => |index| parseOutputSetting(
                arena_allocator,
                &output_rules.items[index].settings,
                name,
                value,
            ) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                arena.deinit();
                return .{ .diagnostic = .{ .line = line_number, .problem = problemForOutputSettingError(err) } };
            },
        }
    }
    return .{ .snapshot = .{
        .arena = arena,
        .general = general.settings,
        .bindings = try bindings.toOwnedSlice(arena_allocator),
        .input_rules = try input_rules.toOwnedSlice(arena_allocator),
        .output_rules = try output_rules.toOwnedSlice(arena_allocator),
    } };
}

const Section = union(enum) {
    none,
    general,
    bindings,
    input: usize,
    output: usize,
};

const GeneralParser = struct {
    settings: GeneralSettings = .{},
    seen: std.EnumSet(GeneralSetting) = .initEmpty(),
};

const GeneralSetting = enum {
    focus_follows_mouse,
    inner_gap,
    outer_gap,
    corner_radius,
    shadow,
    shadow_blur_radius,
    shadow_color,
    focused_shadow_color,
    unfocused_border_width,
    unfocused_border_color,
    focused_border_width,
    focused_border_color,
};

const GeneralSettingError = error{
    InvalidGeneralSetting,
    UnknownGeneralSetting,
    DuplicateGeneralSetting,
};

fn parseGeneralSetting(
    general: *GeneralParser,
    name: []const u8,
    value: []const u8,
) GeneralSettingError!void {
    const setting = enumFromConfig(GeneralSetting, name) orelse
        return error.UnknownGeneralSetting;
    if (general.seen.contains(setting)) return error.DuplicateGeneralSetting;
    switch (setting) {
        .focus_follows_mouse => general.settings.focus_follows_mouse = try parseGeneralToggle(value),
        .inner_gap => general.settings.inner_gap = try parseGeneralSize(value),
        .outer_gap => general.settings.outer_gap = try parseGeneralSize(value),
        .corner_radius => general.settings.corner_radius = try parseGeneralSize(value),
        .shadow => general.settings.shadow_enabled = try parseGeneralToggle(value),
        .shadow_blur_radius => general.settings.shadow_blur_radius = try parseGeneralSize(value),
        .shadow_color => general.settings.shadow_color = try parseColor(value),
        .focused_shadow_color => general.settings.focused_shadow_color = try parseColor(value),
        .unfocused_border_width => general.settings.unfocused_border_width = try parseGeneralSize(value),
        .unfocused_border_color => general.settings.unfocused_border_color = try parseColor(value),
        .focused_border_width => general.settings.focused_border_width = try parseGeneralSize(value),
        .focused_border_color => general.settings.focused_border_color = try parseColor(value),
    }
    general.seen.insert(setting);
}

fn parseGeneralToggle(value: []const u8) GeneralSettingError!bool {
    if (std.mem.eql(u8, value, "enabled")) return true;
    if (std.mem.eql(u8, value, "disabled")) return false;
    return error.InvalidGeneralSetting;
}

fn parseGeneralSize(value: []const u8) GeneralSettingError!u32 {
    const size = std.fmt.parseInt(u32, value, 10) catch
        return error.InvalidGeneralSetting;
    if (size > 256) return error.InvalidGeneralSetting;
    return size;
}

fn parseColor(value: []const u8) GeneralSettingError!Color {
    if ((value.len != 7 and value.len != 9) or value[0] != '#') {
        return error.InvalidGeneralSetting;
    }
    return .{
        .red = std.fmt.parseInt(u8, value[1..3], 16) catch return error.InvalidGeneralSetting,
        .green = std.fmt.parseInt(u8, value[3..5], 16) catch return error.InvalidGeneralSetting,
        .blue = std.fmt.parseInt(u8, value[5..7], 16) catch return error.InvalidGeneralSetting,
        .alpha = if (value.len == 9)
            std.fmt.parseInt(u8, value[7..9], 16) catch return error.InvalidGeneralSetting
        else
            255,
    };
}

const InputHeaderError = error{
    InvalidInputMatcher,
    UnknownInputMatcher,
    DuplicateInputMatcher,
};

fn parseInputHeader(
    allocator: std.mem.Allocator,
    header: []const u8,
) (InputHeaderError || error{OutOfMemory})!?InputMatcher {
    const section_name = "input";
    if (!std.mem.startsWith(u8, header, section_name)) return null;
    if (header.len > section_name.len and header[section_name.len] != ' ' and
        header[section_name.len] != '\t') return null;
    const source = std.mem.trim(u8, header[section_name.len..], " \t");
    const words = parseWords(allocator, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnterminatedQuote, error.DanglingEscape => return error.InvalidInputMatcher,
        else => unreachable,
    };
    var matcher: InputMatcher = .{};
    for (words) |word| {
        const equals = std.mem.indexOfScalar(u8, word, '=') orelse return error.InvalidInputMatcher;
        const name = word[0..equals];
        const value = word[equals + 1 ..];
        if (name.len == 0 or value.len == 0) return error.InvalidInputMatcher;
        if (std.mem.eql(u8, name, "type")) {
            if (matcher.device_type != null) return error.DuplicateInputMatcher;
            matcher.device_type = enumFromConfig(InputDeviceType, value) orelse
                return error.InvalidInputMatcher;
        } else if (std.mem.eql(u8, name, "name")) {
            if (matcher.name != null) return error.DuplicateInputMatcher;
            matcher.name = value;
        } else if (std.mem.eql(u8, name, "vendor")) {
            if (matcher.vendor != null) return error.DuplicateInputMatcher;
            matcher.vendor = std.fmt.parseInt(u32, value, 0) catch
                return error.InvalidInputMatcher;
        } else if (std.mem.eql(u8, name, "product")) {
            if (matcher.product != null) return error.DuplicateInputMatcher;
            matcher.product = std.fmt.parseInt(u32, value, 0) catch
                return error.InvalidInputMatcher;
        } else {
            return error.UnknownInputMatcher;
        }
    }
    return matcher;
}

const OutputHeaderError = error{
    InvalidOutputMatcher,
    UnknownOutputMatcher,
    DuplicateOutputMatcher,
};

fn parseOutputHeader(
    allocator: std.mem.Allocator,
    header: []const u8,
) (OutputHeaderError || error{OutOfMemory})!?OutputMatcher {
    const section_name = "output";
    if (!std.mem.startsWith(u8, header, section_name)) return null;
    if (header.len > section_name.len and header[section_name.len] != ' ' and
        header[section_name.len] != '\t') return null;
    const words = parseWords(allocator, std.mem.trim(u8, header[section_name.len..], " \t")) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnterminatedQuote, error.DanglingEscape => return error.InvalidOutputMatcher,
        else => unreachable,
    };
    var matcher: OutputMatcher = .{};
    for (words) |word| {
        const equals = std.mem.indexOfScalar(u8, word, '=') orelse return error.InvalidOutputMatcher;
        const name = word[0..equals];
        const value = word[equals + 1 ..];
        if (name.len == 0 or value.len == 0) return error.InvalidOutputMatcher;
        if (std.mem.eql(u8, name, "name")) {
            if (matcher.name != null) return error.DuplicateOutputMatcher;
            matcher.name = value;
        } else if (std.mem.eql(u8, name, "make")) {
            if (matcher.make != null) return error.DuplicateOutputMatcher;
            matcher.make = value;
        } else if (std.mem.eql(u8, name, "model")) {
            if (matcher.model != null) return error.DuplicateOutputMatcher;
            matcher.model = value;
        } else if (std.mem.eql(u8, name, "serial")) {
            if (matcher.serial != null) return error.DuplicateOutputMatcher;
            matcher.serial = value;
        } else return error.UnknownOutputMatcher;
    }
    return matcher;
}

const OutputSettingError = error{
    InvalidOutputSetting,
    UnknownOutputSetting,
    DuplicateOutputSetting,
};

fn parseOutputSetting(
    allocator: std.mem.Allocator,
    settings: *OutputSettings,
    name: []const u8,
    value: []const u8,
) (OutputSettingError || error{OutOfMemory})!void {
    if (std.mem.eql(u8, name, "enable")) {
        if (settings.enable != null) return error.DuplicateOutputSetting;
        if (std.mem.eql(u8, value, "enabled")) {
            settings.enable = true;
        } else if (std.mem.eql(u8, value, "disabled")) {
            settings.enable = false;
        } else return error.InvalidOutputSetting;
    } else if (std.mem.eql(u8, name, "mode")) {
        if (settings.mode != null) return error.DuplicateOutputSetting;
        settings.mode = try parseOutputMode(value);
    } else if (std.mem.eql(u8, name, "position")) {
        if (settings.position != null) return error.DuplicateOutputSetting;
        settings.position = try parseOutputPosition(value);
    } else if (std.mem.eql(u8, name, "scale")) {
        if (settings.scale_v120_numerator != null) return error.DuplicateOutputSetting;
        const scale = std.fmt.parseFloat(f64, value) catch return error.InvalidOutputSetting;
        if (!std.math.isFinite(scale) or scale <= 0 or scale > @as(f64, @floatFromInt(std.math.maxInt(u32))) / 120.0)
            return error.InvalidOutputSetting;
        const numerator: u32 = @intFromFloat(@round(scale * 120.0));
        if (numerator == 0) return error.InvalidOutputSetting;
        settings.scale_v120_numerator = numerator;
    } else if (std.mem.eql(u8, name, "icc-profile")) {
        if (settings.icc_profile != null) return error.DuplicateOutputSetting;
        if (std.mem.eql(u8, value, "none")) {
            settings.icc_profile = .none;
        } else {
            if (value.len == 0) return error.InvalidOutputSetting;
            settings.icc_profile = .{ .path = try allocator.dupe(u8, value) };
        }
    } else return error.UnknownOutputSetting;
}

fn parseOutputMode(value: []const u8) OutputSettingError!OutputMode {
    const x = std.mem.indexOfScalar(u8, value, 'x') orelse return error.InvalidOutputSetting;
    if (x == 0) return error.InvalidOutputSetting;
    const at = std.mem.indexOfScalarPos(u8, value, x + 1, '@');
    const height_end = at orelse value.len;
    const width = std.fmt.parseInt(u32, value[0..x], 10) catch return error.InvalidOutputSetting;
    const height = std.fmt.parseInt(u32, value[x + 1 .. height_end], 10) catch return error.InvalidOutputSetting;
    if (width == 0 or height == 0) return error.InvalidOutputSetting;
    var refresh: ?i32 = null;
    if (at) |index| {
        var source = value[index + 1 ..];
        if (std.mem.endsWith(u8, source, "Hz")) source = source[0 .. source.len - 2];
        const hz = std.fmt.parseFloat(f64, source) catch return error.InvalidOutputSetting;
        if (!std.math.isFinite(hz) or hz <= 0 or hz > @as(f64, @floatFromInt(std.math.maxInt(i32))) / 1000.0)
            return error.InvalidOutputSetting;
        refresh = @intFromFloat(@round(hz * 1000.0));
        if (refresh.? <= 0) return error.InvalidOutputSetting;
    }
    return .{ .width = width, .height = height, .refresh_millihertz = refresh };
}

fn parseOutputPosition(value: []const u8) OutputSettingError!OutputPosition {
    const comma = std.mem.indexOfScalar(u8, value, ',') orelse return error.InvalidOutputSetting;
    return .{
        .x = std.fmt.parseInt(i32, value[0..comma], 10) catch return error.InvalidOutputSetting,
        .y = std.fmt.parseInt(i32, value[comma + 1 ..], 10) catch return error.InvalidOutputSetting,
    };
}

const InputSettingError = error{
    InvalidInputSetting,
    UnknownInputSetting,
    DuplicateInputSetting,
};

fn parseInputSetting(settings: *InputSettings, name: []const u8, value: []const u8) InputSettingError!void {
    if (std.mem.eql(u8, name, "send-events")) {
        try assignInputSetting(InputValue(SendEvents), &settings.send_events, try parseEnumInputValue(SendEvents, value));
    } else if (std.mem.eql(u8, name, "tap")) {
        try assignInputSetting(InputValue(NativeInput.Toggle), &settings.tap, try parseEnumInputValue(NativeInput.Toggle, value));
    } else if (std.mem.eql(u8, name, "tap-button-map")) {
        try assignInputSetting(InputValue(NativeInput.TapButtonMap), &settings.tap_button_map, try parseEnumInputValue(NativeInput.TapButtonMap, value));
    } else if (std.mem.eql(u8, name, "drag")) {
        try assignInputSetting(InputValue(NativeInput.Toggle), &settings.drag, try parseEnumInputValue(NativeInput.Toggle, value));
    } else if (std.mem.eql(u8, name, "drag-lock")) {
        try assignInputSetting(InputValue(NativeInput.DragLock), &settings.drag_lock, try parseEnumInputValue(NativeInput.DragLock, value));
    } else if (std.mem.eql(u8, name, "three-finger-drag")) {
        try assignInputSetting(InputValue(NativeInput.ThreeFingerDrag), &settings.three_finger_drag, try parseEnumInputValue(NativeInput.ThreeFingerDrag, value));
    } else if (std.mem.eql(u8, name, "accel-profile")) {
        const parsed = try parseEnumInputValue(NativeInput.AccelProfile, value);
        if (parsed == .value and (parsed.value == .none or parsed.value == .custom)) return error.InvalidInputSetting;
        try assignInputSetting(InputValue(NativeInput.AccelProfile), &settings.accel_profile, parsed);
    } else if (std.mem.eql(u8, name, "accel-speed")) {
        try assignInputSetting(InputValue(f64), &settings.accel_speed, try parseFloatInputValue(value, -1, 1));
    } else if (std.mem.eql(u8, name, "natural-scroll")) {
        try assignInputSetting(InputValue(NativeInput.Toggle), &settings.natural_scroll, try parseEnumInputValue(NativeInput.Toggle, value));
    } else if (std.mem.eql(u8, name, "left-handed")) {
        try assignInputSetting(InputValue(NativeInput.Toggle), &settings.left_handed, try parseEnumInputValue(NativeInput.Toggle, value));
    } else if (std.mem.eql(u8, name, "click-method")) {
        try assignInputSetting(InputValue(NativeInput.ClickMethod), &settings.click_method, try parseEnumInputValue(NativeInput.ClickMethod, value));
    } else if (std.mem.eql(u8, name, "clickfinger-button-map")) {
        try assignInputSetting(InputValue(NativeInput.ClickfingerButtonMap), &settings.clickfinger_button_map, try parseEnumInputValue(NativeInput.ClickfingerButtonMap, value));
    } else if (std.mem.eql(u8, name, "middle-emulation")) {
        try assignInputSetting(InputValue(NativeInput.Toggle), &settings.middle_emulation, try parseEnumInputValue(NativeInput.Toggle, value));
    } else if (std.mem.eql(u8, name, "scroll-method")) {
        try assignInputSetting(InputValue(NativeInput.ScrollMethod), &settings.scroll_method, try parseEnumInputValue(NativeInput.ScrollMethod, value));
    } else if (std.mem.eql(u8, name, "scroll-button")) {
        try assignInputSetting(InputValue(u32), &settings.scroll_button, try parseUnsignedInputValue(value));
    } else if (std.mem.eql(u8, name, "scroll-button-lock")) {
        try assignInputSetting(InputValue(NativeInput.Toggle), &settings.scroll_button_lock, try parseEnumInputValue(NativeInput.Toggle, value));
    } else if (std.mem.eql(u8, name, "disable-while-typing")) {
        try assignInputSetting(InputValue(NativeInput.Toggle), &settings.disable_while_typing, try parseEnumInputValue(NativeInput.Toggle, value));
    } else if (std.mem.eql(u8, name, "disable-while-trackpointing")) {
        try assignInputSetting(InputValue(NativeInput.Toggle), &settings.disable_while_trackpointing, try parseEnumInputValue(NativeInput.Toggle, value));
    } else if (std.mem.eql(u8, name, "rotation")) {
        const parsed = try parseUnsignedInputValue(value);
        if (parsed == .value and parsed.value >= 360) return error.InvalidInputSetting;
        try assignInputSetting(InputValue(u32), &settings.rotation, parsed);
    } else if (std.mem.eql(u8, name, "scroll-factor")) {
        try assignInputSetting(InputValue(f64), &settings.scroll_factor, try parseFloatInputValue(value, 0, std.math.inf(f64)));
    } else if (std.mem.eql(u8, name, "repeat-rate")) {
        try assignInputSetting(InputValue(i32), &settings.repeat_rate, try parseNonnegativeInputValue(value));
    } else if (std.mem.eql(u8, name, "repeat-delay")) {
        try assignInputSetting(InputValue(i32), &settings.repeat_delay, try parseNonnegativeInputValue(value));
    } else {
        return error.UnknownInputSetting;
    }
}

fn assignInputSetting(comptime T: type, target: *?T, value: T) InputSettingError!void {
    if (target.* != null) return error.DuplicateInputSetting;
    target.* = value;
}

fn parseEnumInputValue(comptime T: type, value: []const u8) InputSettingError!InputValue(T) {
    if (std.mem.eql(u8, value, "default")) return .use_default;
    return .{ .value = enumFromConfig(T, value) orelse return error.InvalidInputSetting };
}

fn parseFloatInputValue(value: []const u8, minimum: f64, maximum: f64) InputSettingError!InputValue(f64) {
    if (std.mem.eql(u8, value, "default")) return .use_default;
    const parsed = std.fmt.parseFloat(f64, value) catch return error.InvalidInputSetting;
    if (!std.math.isFinite(parsed) or parsed < minimum or parsed > maximum) return error.InvalidInputSetting;
    return .{ .value = parsed };
}

fn parseUnsignedInputValue(value: []const u8) InputSettingError!InputValue(u32) {
    if (std.mem.eql(u8, value, "default")) return .use_default;
    return .{ .value = std.fmt.parseInt(u32, value, 0) catch return error.InvalidInputSetting };
}

fn parseNonnegativeInputValue(value: []const u8) InputSettingError!InputValue(i32) {
    if (std.mem.eql(u8, value, "default")) return .use_default;
    const parsed = std.fmt.parseInt(i32, value, 0) catch return error.InvalidInputSetting;
    if (parsed < 0) return error.InvalidInputSetting;
    return .{ .value = parsed };
}

fn enumFromConfig(comptime T: type, value: []const u8) ?T {
    inline for (std.meta.fields(T)) |field| {
        if (configNameEquals(value, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn configNameEquals(value: []const u8, field_name: []const u8) bool {
    if (value.len != field_name.len) return false;
    for (value, field_name) |actual, field| {
        if (actual != if (field == '_') '-' else field) return false;
    }
    return true;
}

fn globMatches(pattern: []const u8, value: []const u8) bool {
    var pattern_index: usize = 0;
    var value_index: usize = 0;
    var star_index: ?usize = null;
    var star_value_index: usize = 0;
    while (value_index < value.len) {
        if (pattern_index < pattern.len and
            (pattern[pattern_index] == '?' or pattern[pattern_index] == value[value_index]))
        {
            pattern_index += 1;
            value_index += 1;
        } else if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            star_index = pattern_index;
            pattern_index += 1;
            star_value_index = value_index;
        } else if (star_index) |star| {
            star_value_index += 1;
            value_index = star_value_index;
            pattern_index = star + 1;
        } else {
            return false;
        }
    }
    while (pattern_index < pattern.len and pattern[pattern_index] == '*') pattern_index += 1;
    return pattern_index == pattern.len;
}

fn parseBinding(allocator: std.mem.Allocator, value: []const u8) (BindingError || error{OutOfMemory})!Binding {
    const words = try parseWords(allocator, value);
    if (words.len < 2) return error.EmptyBinding;
    const trigger = try parseTrigger(allocator, words[0]);
    const action_name = words[1];
    const arguments = words[2..];
    const action: Action = if (std.mem.eql(u8, action_name, "focus"))
        .{ .command = try parseDirectionalCommand(arguments, false) }
    else if (std.mem.eql(u8, action_name, "move-focused"))
        .{ .command = try parseDirectionalCommand(arguments, true) }
    else if (std.mem.eql(u8, action_name, "close"))
        .{ .command = .{ .close = try parseWindowTarget(arguments) } }
    else if (std.mem.eql(u8, action_name, "toggle-fullscreen"))
        .{ .command = .{ .toggle_fullscreen = try parseWindowTarget(arguments) } }
    else if (std.mem.eql(u8, action_name, "toggle-floating"))
        .{ .command = .{ .toggle_floating = try parseWindowTarget(arguments) } }
    else if (std.mem.eql(u8, action_name, "set-layout"))
        .{ .command = try parseLayout(arguments) }
    else if (std.mem.eql(u8, action_name, "switch-workspace"))
        .{ .command = .{ .switch_workspace = try parseWorkspace(arguments) } }
    else if (std.mem.eql(u8, action_name, "move-focused-to-workspace"))
        .{ .command = .{ .move_to_workspace = try parseWorkspace(arguments) } }
    else if (std.mem.eql(u8, action_name, "run")) run: {
        if (arguments.len == 0) return error.InvalidActionArguments;
        Launcher.validateArgv(arguments) catch return error.InvalidExecutable;
        break :run .{ .run = arguments };
    } else return error.UnknownAction;
    return .{ .modifiers = trigger.modifiers, .keysym = trigger.keysym, .action = action };
}

fn parseWords(allocator: std.mem.Allocator, value: []const u8) (BindingError || error{OutOfMemory})![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (true) {
        while (index < value.len and (value[index] == ' ' or value[index] == '\t')) index += 1;
        if (index == value.len) break;
        var word: std.ArrayList(u8) = .empty;
        var quote: ?u8 = null;
        var started = false;
        while (index < value.len) {
            const byte = value[index];
            if (quote) |delimiter| {
                if (byte == delimiter) {
                    quote = null;
                    started = true;
                    index += 1;
                } else if (byte == '\\') {
                    index += 1;
                    if (index == value.len) return error.DanglingEscape;
                    try word.append(allocator, value[index]);
                    started = true;
                    index += 1;
                } else {
                    try word.append(allocator, byte);
                    started = true;
                    index += 1;
                }
                continue;
            }
            if (byte == ' ' or byte == '\t') break;
            if (byte == '\'' or byte == '"') {
                quote = byte;
                started = true;
                index += 1;
            } else if (byte == '\\') {
                index += 1;
                if (index == value.len) return error.DanglingEscape;
                try word.append(allocator, value[index]);
                started = true;
                index += 1;
            } else {
                try word.append(allocator, byte);
                started = true;
                index += 1;
            }
        }
        if (quote != null) return error.UnterminatedQuote;
        std.debug.assert(started);
        try words.append(allocator, try word.toOwnedSlice(allocator));
    }
    return words.toOwnedSlice(allocator);
}

const Trigger = struct { modifiers: u32, keysym: u32 };

fn parseTrigger(allocator: std.mem.Allocator, value: []const u8) (BindingError || error{OutOfMemory})!Trigger {
    if (value.len == 0 or value[0] == '+' or value[value.len - 1] == '+' or
        std.mem.indexOf(u8, value, "++") != null)
    {
        return error.InvalidTrigger;
    }
    const last_plus = std.mem.lastIndexOfScalar(u8, value, '+');
    const key_name = if (last_plus) |index| value[index + 1 ..] else value;
    var modifiers: u32 = 0;
    if (last_plus) |end| {
        var parts = std.mem.splitScalar(u8, value[0..end], '+');
        while (parts.next()) |name| {
            const modifier: u32 = if (std.mem.eql(u8, name, "super"))
                super
            else if (std.mem.eql(u8, name, "shift"))
                shift
            else if (std.mem.eql(u8, name, "ctrl") or std.mem.eql(u8, name, "control"))
                control
            else if (std.mem.eql(u8, name, "alt"))
                alt
            else
                return error.InvalidModifier;
            if (modifiers & modifier != 0) return error.DuplicateModifier;
            modifiers |= modifier;
        }
    }
    const key_name_z = try allocator.dupeZ(u8, key_name);
    const keysym = c.xkb_keysym_from_name(key_name_z, c.XKB_KEYSYM_CASE_INSENSITIVE);
    if (keysym == c.XKB_KEY_NoSymbol) return error.InvalidKey;
    return .{ .modifiers = modifiers, .keysym = keysym };
}

fn parseDirectionalCommand(arguments: []const []const u8, move: bool) BindingError!Command {
    if (arguments.len != 1) return error.InvalidActionArguments;
    const direction = arguments[0];
    if (std.mem.eql(u8, direction, "next")) return if (move) .move_focused_next else .focus_next;
    if (std.mem.eql(u8, direction, "previous")) return if (move) .move_focused_previous else .focus_previous;
    const parsed: Direction = std.meta.stringToEnum(Direction, direction) orelse
        return error.InvalidDirection;
    return if (move) .{ .move_focused_direction = parsed } else .{ .focus_direction = parsed };
}

fn parseWindowTarget(arguments: []const []const u8) BindingError!WindowTarget {
    if (arguments.len != 1) return error.InvalidActionArguments;
    return std.meta.stringToEnum(WindowTarget, arguments[0]) orelse
        error.InvalidWindowTarget;
}

fn parseLayout(arguments: []const []const u8) BindingError!Command {
    if (arguments.len != 1) return error.InvalidActionArguments;
    if (std.mem.eql(u8, arguments[0], "tiled")) return .layout_tiled;
    return error.InvalidLayout;
}

fn parseWorkspace(arguments: []const []const u8) BindingError!u8 {
    if (arguments.len != 1) return error.InvalidActionArguments;
    const workspace = std.fmt.parseInt(u8, arguments[0], 10) catch return error.InvalidWorkspace;
    if (workspace < 1 or workspace > 10) return error.InvalidWorkspace;
    return workspace;
}

fn problemForError(err: anyerror) Problem {
    return switch (err) {
        error.EmptyBinding => .empty_binding,
        error.UnterminatedQuote => .unterminated_quote,
        error.DanglingEscape => .dangling_escape,
        error.InvalidTrigger => .invalid_trigger,
        error.InvalidModifier => .invalid_modifier,
        error.DuplicateModifier => .duplicate_modifier,
        error.InvalidKey => .invalid_key,
        error.UnknownAction => .unknown_action,
        error.InvalidActionArguments => .invalid_action_arguments,
        error.InvalidDirection => .invalid_direction,
        error.InvalidWindowTarget => .invalid_window_target,
        error.InvalidLayout => .invalid_layout,
        error.InvalidWorkspace => .invalid_workspace,
        error.InvalidExecutable => .invalid_executable,
        else => unreachable,
    };
}

fn problemForInputHeaderError(err: anyerror) Problem {
    return switch (err) {
        error.InvalidInputMatcher => .invalid_input_matcher,
        error.UnknownInputMatcher => .unknown_input_matcher,
        error.DuplicateInputMatcher => .duplicate_input_matcher,
        else => unreachable,
    };
}

fn problemForGeneralSettingError(err: anyerror) Problem {
    return switch (err) {
        error.InvalidGeneralSetting => .invalid_general_setting,
        error.UnknownGeneralSetting => .unknown_general_setting,
        error.DuplicateGeneralSetting => .duplicate_general_setting,
        else => unreachable,
    };
}

fn problemForInputSettingError(err: anyerror) Problem {
    return switch (err) {
        error.InvalidInputSetting => .invalid_input_setting,
        error.UnknownInputSetting => .unknown_input_setting,
        error.DuplicateInputSetting => .duplicate_input_setting,
        else => unreachable,
    };
}

fn problemForOutputHeaderError(err: anyerror) Problem {
    return switch (err) {
        error.InvalidOutputMatcher => .invalid_output_matcher,
        error.UnknownOutputMatcher => .unknown_output_matcher,
        error.DuplicateOutputMatcher => .duplicate_output_matcher,
        else => unreachable,
    };
}

fn problemForOutputSettingError(err: anyerror) Problem {
    return switch (err) {
        error.InvalidOutputSetting => .invalid_output_setting,
        error.UnknownOutputSetting => .unknown_output_setting,
        error.DuplicateOutputSetting => .duplicate_output_setting,
        else => unreachable,
    };
}

pub fn problemMessage(problem: Problem) []const u8 {
    return switch (problem) {
        .invalid_section => "invalid section header",
        .unknown_section => "unknown section",
        .directive_outside_section => "directive appears outside a section",
        .invalid_directive => "directive must contain '='",
        .unknown_directive => "unknown directive",
        .invalid_general_setting => "invalid general setting",
        .unknown_general_setting => "unknown general setting",
        .duplicate_general_setting => "duplicate general setting",
        .empty_binding => "binding requires a trigger and action",
        .unterminated_quote => "unterminated quoted argument",
        .dangling_escape => "unfinished argument escape",
        .invalid_trigger => "invalid binding trigger",
        .invalid_modifier => "unknown binding modifier",
        .duplicate_modifier => "duplicate binding modifier",
        .duplicate_binding => "duplicate binding trigger",
        .invalid_key => "unknown key name",
        .unknown_action => "unknown binding action",
        .invalid_action_arguments => "invalid arguments for binding action",
        .invalid_direction => "invalid direction",
        .invalid_window_target => "invalid window target",
        .invalid_layout => "invalid layout",
        .invalid_workspace => "workspace must be between 1 and 10",
        .invalid_executable => "executable must be an absolute path or a bare filename",
        .invalid_input_matcher => "invalid input matcher",
        .unknown_input_matcher => "unknown input matcher",
        .duplicate_input_matcher => "duplicate input matcher",
        .invalid_input_setting => "invalid input setting",
        .unknown_input_setting => "unknown input setting",
        .duplicate_input_setting => "duplicate input setting",
        .invalid_output_matcher => "invalid output matcher",
        .unknown_output_matcher => "unknown output matcher",
        .duplicate_output_matcher => "duplicate output matcher",
        .invalid_output_setting => "invalid output setting",
        .unknown_output_setting => "unknown output setting",
        .duplicate_output_setting => "duplicate output setting",
    };
}

test "configuration parses typed commands and explicit run argv" {
    const source =
        \\[bindings]
        \\bind=super+h focus left
        \\bind=super+shift+j move-focused down
        \\bind=super+q close focused
        \\bind=super+f toggle-fullscreen focused
        \\bind=super+shift+space toggle-floating focused
        \\bind=super+t set-layout tiled
        \\bind=super+1 switch-workspace 1
        \\bind=super+shift+0 move-focused-to-workspace 10
        \\bind=super+return run foot --title "Keywork Terminal" 'empty='
        \\bind-repeat=XF86AudioRaiseVolume run keywork-shell volume up
    ;
    const result = try parse(std.testing.allocator, source);
    var snapshot = switch (result) {
        .snapshot => |snapshot| snapshot,
        .diagnostic => return error.UnexpectedDiagnostic,
    };
    defer snapshot.deinit();
    try std.testing.expect(snapshot.general.focus_follows_mouse);
    try std.testing.expectEqual(@as(usize, 10), snapshot.bindings.len);
    try std.testing.expectEqual(Direction.left, snapshot.bindings[0].action.command.focus_direction);
    try std.testing.expectEqual(Direction.down, snapshot.bindings[1].action.command.move_focused_direction);
    try std.testing.expectEqual(WindowTarget.focused, snapshot.bindings[2].action.command.close);
    try std.testing.expectEqual(WindowTarget.focused, snapshot.bindings[3].action.command.toggle_fullscreen);
    try std.testing.expectEqual(WindowTarget.focused, snapshot.bindings[4].action.command.toggle_floating);
    try std.testing.expectEqual(Command.layout_tiled, snapshot.bindings[5].action.command);
    try std.testing.expectEqual(@as(u8, 10), snapshot.bindings[7].action.command.move_to_workspace);
    try std.testing.expectEqualStrings("foot", snapshot.bindings[8].action.run[0]);
    try std.testing.expectEqualStrings("Keywork Terminal", snapshot.bindings[8].action.run[2]);
    try std.testing.expectEqualStrings("empty=", snapshot.bindings[8].action.run[3]);
    try std.testing.expect(!snapshot.bindings[8].repeat);
    try std.testing.expect(snapshot.bindings[9].repeat);
    try std.testing.expectEqualStrings("keywork-shell", snapshot.bindings[9].action.run[0]);
}

test "valid empty configuration disables configured bindings" {
    const result = try parse(std.testing.allocator, "# intentionally empty\n[bindings]\n");
    var snapshot = switch (result) {
        .snapshot => |snapshot| snapshot,
        .diagnostic => return error.UnexpectedDiagnostic,
    };
    defer snapshot.deinit();
    try std.testing.expectEqual(GeneralSettings{}, snapshot.general);
    try std.testing.expectEqual(@as(usize, 0), snapshot.bindings.len);
    try std.testing.expectEqual(@as(usize, 0), snapshot.input_rules.len);
    try std.testing.expectEqual(@as(usize, 0), snapshot.output_rules.len);
}

test "embedded default configuration is valid and complete" {
    var snapshot = try defaultSnapshot(std.testing.allocator);
    defer snapshot.deinit();
    try std.testing.expectEqual(GeneralSettings{}, snapshot.general);
    try std.testing.expectEqual(@as(usize, 32), snapshot.bindings.len);
    try std.testing.expectEqual(@as(usize, 1), snapshot.input_rules.len);
    try std.testing.expectEqual(@as(usize, 0), snapshot.output_rules.len);
    const input_rule = snapshot.input_rules[0];
    try std.testing.expectEqual(InputDeviceType.touchpad, input_rule.matcher.device_type.?);
    try std.testing.expectEqual(NativeInput.Toggle.enabled, input_rule.settings.disable_while_typing.?.value);
    try std.testing.expectEqual(Direction.left, snapshot.bindings[0].action.command.focus_direction);
    try std.testing.expectEqual(WindowTarget.focused, snapshot.bindings[8].action.command.close);
    try std.testing.expectEqual(WindowTarget.focused, snapshot.bindings[9].action.command.toggle_fullscreen);
    try std.testing.expectEqual(WindowTarget.focused, snapshot.bindings[10].action.command.toggle_floating);
    try std.testing.expectEqualStrings("monstar", snapshot.bindings[31].action.run[0]);
}

test "output rules parse in order and match output identity" {
    const result = try parse(std.testing.allocator,
        \\[output]
        \\scale=1.25
        \\[output name="DP-?" make="Del*" model=U2723QE serial=ABC*]
        \\enable=disabled
        \\mode=3840x2160@59.94Hz
        \\position=-1920,40
        \\icc-profile=/home/user/.local/share/color/icc/display.icc
    );
    var snapshot = switch (result) {
        .snapshot => |snapshot| snapshot,
        .diagnostic => return error.UnexpectedDiagnostic,
    };
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 2), snapshot.output_rules.len);
    try std.testing.expect(snapshot.output_rules[0].matcher.matches(.{ .name = "anything" }));
    try std.testing.expectEqual(@as(u32, 150), snapshot.output_rules[0].settings.scale_v120_numerator.?);
    const rule = snapshot.output_rules[1];
    try std.testing.expect(rule.matcher.matches(.{
        .name = "DP-1",
        .make = "Dell Inc.",
        .model = "U2723QE",
        .serial = "ABC123",
    }));
    try std.testing.expect(!rule.matcher.matches(.{ .name = "DP-1", .make = "Dell Inc.", .model = "U2723QE" }));
    try std.testing.expectEqual(false, rule.settings.enable.?);
    try std.testing.expectEqual(@as(i32, 59940), rule.settings.mode.?.refresh_millihertz.?);
    try std.testing.expectEqual(OutputPosition{ .x = -1920, .y = 40 }, rule.settings.position.?);
    try std.testing.expectEqualStrings(
        "/home/user/.local/share/color/icc/display.icc",
        rule.settings.icc_profile.?.path,
    );
}

test "output rules reject invalid matchers and settings" {
    const cases = [_]struct { source: []const u8, problem: Problem }{
        .{ .source = "[output name]\n", .problem = .invalid_output_matcher },
        .{ .source = "[output connector=DP-1]\n", .problem = .unknown_output_matcher },
        .{ .source = "[output name=a name=b]\n", .problem = .duplicate_output_matcher },
        .{ .source = "[output]\nenable=maybe\n", .problem = .invalid_output_setting },
        .{ .source = "[output]\ntransform=90\n", .problem = .unknown_output_setting },
        .{ .source = "[output]\nscale=1\nscale=2\n", .problem = .duplicate_output_setting },
        .{ .source = "[output]\nscale=0\n", .problem = .invalid_output_setting },
        .{ .source = "[output]\nscale=nan\n", .problem = .invalid_output_setting },
        .{ .source = "[output]\nmode=1920-1080\n", .problem = .invalid_output_setting },
        .{ .source = "[output]\nmode=1920x1080@0Hz\n", .problem = .invalid_output_setting },
        .{ .source = "[output]\nposition=1:2\n", .problem = .invalid_output_setting },
        .{ .source = "[output]\nicc-profile=\n", .problem = .invalid_output_setting },
        .{ .source = "[output]\nicc-profile=a.icc\nicc-profile=b.icc\n", .problem = .duplicate_output_setting },
        .{ .source = "[outputs]\n", .problem = .unknown_section },
    };
    for (cases) |case| {
        const result = try parse(std.testing.allocator, case.source);
        try std.testing.expectEqual(case.problem, result.diagnostic.problem);
    }
}

test "general settings parse and reject invalid directives" {
    const result = try parse(std.testing.allocator,
        \\[general]
        \\focus-follows-mouse=disabled
        \\inner-gap=12
        \\outer-gap=16
        \\corner-radius=8
        \\shadow=disabled
        \\shadow-blur-radius=48
        \\shadow-color=#10203040
        \\focused-shadow-color=#aabbcc
        \\unfocused-border-width=2
        \\unfocused-border-color=#3a3a40
        \\focused-border-width=3
        \\focused-border-color=#7aa2f780
    );
    var snapshot = switch (result) {
        .snapshot => |snapshot| snapshot,
        .diagnostic => return error.UnexpectedDiagnostic,
    };
    defer snapshot.deinit();
    try std.testing.expect(!snapshot.general.focus_follows_mouse);
    try std.testing.expectEqual(@as(u32, 12), snapshot.general.inner_gap);
    try std.testing.expectEqual(@as(u32, 16), snapshot.general.outer_gap);
    try std.testing.expectEqual(@as(u32, 8), snapshot.general.corner_radius);
    try std.testing.expect(!snapshot.general.shadow_enabled);
    try std.testing.expectEqual(@as(u32, 48), snapshot.general.shadow_blur_radius.?);
    try std.testing.expectEqual(Color{ .red = 0x10, .green = 0x20, .blue = 0x30, .alpha = 0x40 }, snapshot.general.shadow_color.?);
    try std.testing.expectEqual(Color{ .red = 0xaa, .green = 0xbb, .blue = 0xcc, .alpha = 0xff }, snapshot.general.focused_shadow_color.?);
    try std.testing.expectEqual(@as(u32, 2), snapshot.general.unfocused_border_width);
    try std.testing.expectEqual(Color{ .red = 0x3a, .green = 0x3a, .blue = 0x40, .alpha = 0xff }, snapshot.general.unfocused_border_color.?);
    try std.testing.expectEqual(@as(u32, 3), snapshot.general.focused_border_width);
    try std.testing.expectEqual(Color{ .red = 0x7a, .green = 0xa2, .blue = 0xf7, .alpha = 0x80 }, snapshot.general.focused_border_color.?);

    const invalid = try parse(std.testing.allocator, "[general]\nfocus-follows-mouse=sometimes\n");
    try std.testing.expectEqual(Problem.invalid_general_setting, invalid.diagnostic.problem);
    const invalid_gap = try parse(std.testing.allocator, "[general]\ninner-gap=257\n");
    try std.testing.expectEqual(Problem.invalid_general_setting, invalid_gap.diagnostic.problem);
    const invalid_border_width = try parse(std.testing.allocator, "[general]\nfocused-border-width=257\n");
    try std.testing.expectEqual(Problem.invalid_general_setting, invalid_border_width.diagnostic.problem);
    const invalid_color = try parse(std.testing.allocator, "[general]\nshadow-color=#12345z\n");
    try std.testing.expectEqual(Problem.invalid_general_setting, invalid_color.diagnostic.problem);
    const unknown = try parse(std.testing.allocator, "[general]\nmouse-warping=enabled\n");
    try std.testing.expectEqual(Problem.unknown_general_setting, unknown.diagnostic.problem);
    const duplicate = try parse(std.testing.allocator, "[general]\nfocus-follows-mouse=enabled\nfocus-follows-mouse=disabled\n");
    try std.testing.expectEqual(Problem.duplicate_general_setting, duplicate.diagnostic.problem);
}

test "input rules parse matchers and typed settings" {
    const source =
        \\[input type=pointer]
        \\natural-scroll=disabled
        \\[input type=touchpad name="ELAN *" vendor=0x04f3 product=0x1234]
        \\send-events=disabled-on-external-mouse
        \\tap=enabled
        \\tap-button-map=lmr
        \\drag=enabled
        \\drag-lock=sticky
        \\three-finger-drag=four-fingers
        \\accel-profile=adaptive
        \\accel-speed=-0.25
        \\natural-scroll=enabled
        \\left-handed=disabled
        \\click-method=clickfinger
        \\clickfinger-button-map=lrm
        \\middle-emulation=enabled
        \\scroll-method=two-finger
        \\scroll-button=0x112
        \\scroll-button-lock=enabled
        \\disable-while-typing=enabled
        \\disable-while-trackpointing=disabled
        \\rotation=180
        \\scroll-factor=0.75
        \\repeat-rate=30
        \\repeat-delay=400
    ;
    const result = try parse(std.testing.allocator, source);
    var snapshot = switch (result) {
        .snapshot => |snapshot| snapshot,
        .diagnostic => return error.UnexpectedDiagnostic,
    };
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 2), snapshot.input_rules.len);
    try std.testing.expectEqual(InputDeviceType.pointer, snapshot.input_rules[0].matcher.device_type.?);
    try std.testing.expectEqual(NativeInput.Toggle.disabled, snapshot.input_rules[0].settings.natural_scroll.?.value);

    const rule = snapshot.input_rules[1];
    try std.testing.expectEqual(InputDeviceType.touchpad, rule.matcher.device_type.?);
    try std.testing.expectEqualStrings("ELAN *", rule.matcher.name.?);
    try std.testing.expectEqual(@as(u32, 0x04f3), rule.matcher.vendor.?);
    try std.testing.expectEqual(@as(u32, 0x1234), rule.matcher.product.?);
    try std.testing.expectEqual(SendEvents.disabled_on_external_mouse, rule.settings.send_events.?.value);
    try std.testing.expectEqual(NativeInput.ThreeFingerDrag.four_fingers, rule.settings.three_finger_drag.?.value);
    try std.testing.expectEqual(NativeInput.AccelProfile.adaptive, rule.settings.accel_profile.?.value);
    try std.testing.expectEqual(@as(f64, -0.25), rule.settings.accel_speed.?.value);
    try std.testing.expectEqual(@as(u32, 0x112), rule.settings.scroll_button.?.value);
    try std.testing.expectEqual(@as(i32, 400), rule.settings.repeat_delay.?.value);
    try std.testing.expect(rule.matcher.matches(.{
        .name = "ELAN Touchpad",
        .vendor = 0x04f3,
        .product = 0x1234,
        .pointer = true,
        .touchpad = true,
    }));
    try std.testing.expect(!rule.matcher.matches(.{
        .name = "ELAN Touchpad",
        .vendor = 0x04f3,
        .product = 1,
        .pointer = true,
        .touchpad = true,
    }));
}

test "input name matchers support star and question wildcards" {
    try std.testing.expect(globMatches("Logitech * 3S", "Logitech MX Master 3S"));
    try std.testing.expect(globMatches("event?", "event7"));
    try std.testing.expect(!globMatches("event?", "event12"));
    try std.testing.expect(!globMatches("ELAN*", "Logitech MX Master 3S"));
}

test "input rules reject malformed matchers and settings" {
    const duplicate_matcher = try parse(std.testing.allocator, "[input type=pointer type=touchpad]\n");
    try std.testing.expectEqual(Problem.duplicate_input_matcher, duplicate_matcher.diagnostic.problem);
    const unknown_matcher = try parse(std.testing.allocator, "[input path=/dev/input/event0]\n");
    try std.testing.expectEqual(Problem.unknown_input_matcher, unknown_matcher.diagnostic.problem);
    const invalid_matcher = try parse(std.testing.allocator, "[input type=mouse]\n");
    try std.testing.expectEqual(Problem.invalid_input_matcher, invalid_matcher.diagnostic.problem);
    const duplicate_setting = try parse(std.testing.allocator, "[input]\ntap=enabled\ntap=disabled\n");
    try std.testing.expectEqual(Problem.duplicate_input_setting, duplicate_setting.diagnostic.problem);
    const unknown_setting = try parse(std.testing.allocator, "[input]\nsensitivity=1\n");
    try std.testing.expectEqual(Problem.unknown_input_setting, unknown_setting.diagnostic.problem);
    const invalid_setting = try parse(std.testing.allocator, "[input]\naccel-speed=2\n");
    try std.testing.expectEqual(Problem.invalid_input_setting, invalid_setting.diagnostic.problem);
}

test "configuration rejects the complete snapshot at the failing line" {
    var result = try parse(std.testing.allocator,
        \\[bindings]
        \\bind=super+h focus left
        \\bind=super+x run ./relative-command
    );
    const diagnostic = switch (result) {
        .snapshot => |*snapshot| {
            snapshot.deinit();
            return error.ExpectedDiagnostic;
        },
        .diagnostic => |diagnostic| diagnostic,
    };
    try std.testing.expectEqual(@as(usize, 3), diagnostic.line);
    try std.testing.expectEqual(Problem.invalid_executable, diagnostic.problem);
}

test "configuration rejects malformed syntax and unknown sections" {
    const quoted = try parse(std.testing.allocator, "[bindings]\nbind=super+x run foot \\");
    try std.testing.expectEqual(Problem.dangling_escape, quoted.diagnostic.problem);
    const section = try parse(std.testing.allocator, "[outputs]\n");
    try std.testing.expectEqual(Problem.unknown_section, section.diagnostic.problem);
    const modifier = try parse(std.testing.allocator, "[bindings]\nbind=super+super+x focus left\n");
    try std.testing.expectEqual(Problem.duplicate_modifier, modifier.diagnostic.problem);
    const window_target = try parse(std.testing.allocator, "[bindings]\nbind=super+q close all\n");
    try std.testing.expectEqual(Problem.invalid_window_target, window_target.diagnostic.problem);
}

test "configuration rejects unreachable duplicate binding triggers" {
    const result = try parse(std.testing.allocator,
        \\[bindings]
        \\bind=super+q close focused
        \\bind=super+q toggle-fullscreen focused
    );
    try std.testing.expectEqual(@as(usize, 3), result.diagnostic.line);
    try std.testing.expectEqual(Problem.duplicate_binding, result.diagnostic.problem);
}
