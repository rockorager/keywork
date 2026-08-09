//! Configured key bindings for compositor policy and application launching.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const NativeInput = @import("backend/native_input.zig");
const Config = @import("config.zig");
const Launcher = @import("launcher.zig");
const KeyboardShortcutsInhibit = @import("wayland/keyboard_shortcuts_inhibit.zig");
const InputManager = @import("input_manager.zig");
const WindowManager = @import("window_manager.zig");

const log = std.log.scoped(.keybindings);
const wl = wayland.server.wl;

pub const InhibitionProvider = struct {
    context: *anyopaque,
    inhibits_seat_named: *const fn (*anyopaque, []const u8) bool,
};

allocator: std.mem.Allocator,
manager: *WindowManager,
input_manager: *InputManager,
shortcuts_inhibit: *KeyboardShortcutsInhibit,
inhibition_provider: ?InhibitionProvider,
native_input: ?*NativeInput,
launcher: ?*Launcher = null,
bindings: []const Config.Binding = &.{},
device_listener: InputManager.DeviceListener,
held_keys: std.ArrayList(HeldKey) = .empty,
repeat_timer: *wl.EventSource,
repeat: ?RepeatIdentity = null,

const HeldKey = struct {
    device_id: NativeInput.DeviceId,
    key_code: u32,
    disposition: NativeInput.KeyboardEventDisposition,
};

const RepeatIdentity = struct {
    device_id: NativeInput.DeviceId,
    key_code: u32,
    modifiers: u32,
    keysym: u32,
};

pub fn init(self: *Self, allocator: std.mem.Allocator, display: *wl.Server, manager: *WindowManager, input_manager: *InputManager, shortcuts_inhibit: *KeyboardShortcutsInhibit, inhibition_provider: ?InhibitionProvider, native_input: ?*NativeInput) !void {
    self.* = .{
        .allocator = allocator,
        .manager = manager,
        .input_manager = input_manager,
        .shortcuts_inhibit = shortcuts_inhibit,
        .inhibition_provider = inhibition_provider,
        .native_input = native_input,
        .device_listener = .{ .context = self, .added = deviceAdded, .removed = deviceRemoved },
        .repeat_timer = undefined,
    };
    errdefer self.held_keys.deinit(allocator);
    self.repeat_timer = try display.getEventLoop().addTimer(*Self, repeatTimer, self);
    errdefer self.repeat_timer.remove();
    try input_manager.addDeviceListener(&self.device_listener);
    errdefer input_manager.removeDeviceListener(&self.device_listener);
    if (native_input) |input| input.setKeyboardEventListener(.{ .context = self, .key = keyboardKey, .modifiers = modifiersChanged });
}

pub fn detachNativeInput(self: *Self) void {
    if (self.native_input) |input| input.clearKeyboardEventListener();
    self.native_input = null;
    self.held_keys.clearRetainingCapacity();
    self.cancelRepeat();
}

pub fn setLauncher(self: *Self, launcher: *Launcher) void {
    self.launcher = launcher;
}

pub fn setConfiguredBindings(self: *Self, bindings: []const Config.Binding) void {
    self.cancelRepeat();
    self.bindings = bindings;
}

pub fn deinit(self: *Self) void {
    self.detachNativeInput();
    self.input_manager.removeDeviceListener(&self.device_listener);
    self.repeat_timer.remove();
    self.held_keys.deinit(self.allocator);
    self.* = undefined;
}

fn keyboardKey(context: *anyopaque, event: NativeInput.KeyboardEvent) NativeInput.KeyboardEventDisposition {
    const self: *Self = @ptrCast(@alignCast(context));
    return switch (event.state) {
        .pressed => self.keyPressed(event),
        .released => self.keyReleased(event),
        else => .forwarded,
    };
}

fn keyPressed(self: *Self, event: NativeInput.KeyboardEvent) NativeInput.KeyboardEventDisposition {
    for (self.held_keys.items) |held| if (held.device_id == event.device_id and held.key_code == event.key_code) return held.disposition;
    const device = self.input_manager.findDevice(event.device_id) orelse return .forwarded;
    // libinput reports duplicate physical presses while the seat-level key is
    // already down. They inherit the first press's ownership without running
    // its command again.
    if (!event.seat_level) {
        for (self.held_keys.items) |held| {
            if (held.key_code != event.key_code) continue;
            const held_device = self.input_manager.findDevice(held.device_id) orelse continue;
            if (!std.mem.eql(u8, held_device.seat_name, device.seat_name)) continue;
            self.held_keys.append(self.allocator, .{
                .device_id = event.device_id,
                .key_code = event.key_code,
                .disposition = held.disposition,
            }) catch return .captured;
            return held.disposition;
        }
    }
    self.cancelRepeat();
    const disposition: NativeInput.KeyboardEventDisposition = if (self.inhibitsSeatNamed(device.seat_name))
        .shortcuts_inhibited
    else if (matchBinding(self.bindings, event.modifiers, event.keysyms)) |binding| blk: {
        self.executeAction(binding.action);
        if (bindingRepeats(binding)) self.armRepeat(event, binding.keysym);
        break :blk .captured;
    } else .forwarded;
    self.held_keys.append(self.allocator, .{ .device_id = event.device_id, .key_code = event.key_code, .disposition = disposition }) catch {
        self.cancelRepeat();
        return .captured;
    };
    return disposition;
}

fn keyReleased(self: *Self, event: NativeInput.KeyboardEvent) NativeInput.KeyboardEventDisposition {
    for (self.held_keys.items, 0..) |held, index| {
        if (held.device_id != event.device_id or held.key_code != event.key_code) continue;
        _ = self.held_keys.orderedRemove(index);
        if (repeatMatchesKey(self.repeat, event.device_id, event.key_code)) self.cancelRepeat();
        return held.disposition;
    }
    return .forwarded;
}

fn executeAction(self: *Self, action: Config.Action) void {
    switch (action) {
        .command => |command| self.manager.execute(command),
        .run => |argv| {
            const launcher = self.launcher orelse {
                log.err("cannot launch {s}: launcher is unavailable", .{argv[0]});
                return;
            };
            launcher.launch(argv) catch |err| log.err("failed to launch {s}: {t}", .{ argv[0], err });
        },
    }
}

fn armRepeat(self: *Self, event: NativeInput.KeyboardEvent, keysym: u32) void {
    const input = self.native_input orelse return;
    const info = input.deviceRepeatInfo(event.device_id) orelse return;
    if (repeatInterval(info.rate) == null) return;
    self.repeat = .{
        .device_id = event.device_id,
        .key_code = event.key_code,
        .modifiers = event.modifiers,
        .keysym = keysym,
    };
    self.updateRepeatTimer(@max(info.delay, 1));
}

fn repeatTimer(self: *Self) c_int {
    const identity = self.repeat orelse return 0;
    const input = self.native_input orelse {
        self.cancelRepeat();
        return 0;
    };
    const info = input.deviceRepeatInfo(identity.device_id) orelse {
        self.cancelRepeat();
        return 0;
    };
    const interval = repeatInterval(info.rate) orelse {
        self.cancelRepeat();
        return 0;
    };
    const device = self.input_manager.findDevice(identity.device_id) orelse {
        self.cancelRepeat();
        return 0;
    };
    if (self.inhibitsSeatNamed(device.seat_name)) {
        self.cancelRepeat();
        return 0;
    }
    const binding = matchBinding(self.bindings, identity.modifiers, &.{identity.keysym}) orelse {
        self.cancelRepeat();
        return 0;
    };
    if (!bindingRepeats(binding)) {
        self.cancelRepeat();
        return 0;
    }
    self.executeAction(binding.action);
    self.updateRepeatTimer(interval);
    return 0;
}

fn inhibitsSeatNamed(self: *const Self, name: []const u8) bool {
    if (self.shortcuts_inhibit.inhibitsSeatNamed(name)) return true;
    const provider = self.inhibition_provider orelse return false;
    return provider.inhibits_seat_named(provider.context, name);
}

fn updateRepeatTimer(self: *Self, milliseconds: i32) void {
    self.repeat_timer.timerUpdate(milliseconds) catch |err| {
        log.err("failed to update key binding repeat timer: {t}", .{err});
        self.repeat = null;
    };
}

fn cancelRepeat(self: *Self) void {
    if (self.repeat == null) return;
    self.repeat = null;
    self.repeat_timer.timerUpdate(0) catch |err| log.err("failed to cancel key binding repeat timer: {t}", .{err});
}

fn repeatInterval(rate: i32) ?i32 {
    if (rate <= 0) return null;
    const quotient = @divTrunc(1000, rate);
    const rounded = quotient + @intFromBool(@rem(1000, rate) != 0);
    return @max(rounded, 1);
}

fn repeatMatchesKey(repeat: ?RepeatIdentity, device_id: NativeInput.DeviceId, key_code: u32) bool {
    const identity = repeat orelse return false;
    return identity.device_id == device_id and identity.key_code == key_code;
}

fn bindingRepeats(binding: Config.Binding) bool {
    if (binding.repeat) return true;
    return switch (binding.action) {
        .command => |command| command.repeats(),
        .run => false,
    };
}

fn matchBinding(bindings: []const Config.Binding, modifiers: u32, keysyms: []const u32) ?Config.Binding {
    for (bindings) |binding| {
        if (binding.modifiers != modifiers) continue;
        for (keysyms) |keysym| if (keysym == binding.keysym) return binding;
    }
    return null;
}

fn deviceAdded(_: *anyopaque, _: *InputManager.Device) void {}
fn deviceRemoved(context: *anyopaque, device: *InputManager.Device) void {
    if (device.device_type == .keyboard) releaseDevice(@ptrCast(@alignCast(context)), device.id);
}
fn releaseDevice(self: *Self, id: NativeInput.DeviceId) void {
    if (self.repeat != null and self.repeat.?.device_id == id) self.cancelRepeat();
    var index: usize = 0;
    while (index < self.held_keys.items.len) {
        if (self.held_keys.items[index].device_id == id) _ = self.held_keys.orderedRemove(index) else index += 1;
    }
}
fn modifiersChanged(context: *anyopaque, _: ?NativeInput.DeviceId, old: u32, new: u32) void {
    if (old != new) (@as(*Self, @ptrCast(@alignCast(context)))).cancelRepeat();
}

test "binding matching checks every symbol and exact modifiers" {
    const test_bindings = [_]Config.Binding{
        .{ .modifiers = Config.super, .keysym = 'j', .action = .{ .command = .{ .focus_direction = .down } } },
    };
    try std.testing.expectEqual(.down, matchBinding(&test_bindings, Config.super, &.{ 0, 'j' }).?.action.command.focus_direction);
    try std.testing.expect(matchBinding(&test_bindings, Config.super | Config.shift, &.{'j'}) == null);
    try std.testing.expect(matchBinding(&test_bindings, 0, &.{'j'}) == null);
}

test "held key records press disposition for release" {
    var held: std.ArrayList(HeldKey) = .empty;
    defer held.deinit(std.testing.allocator);
    try held.append(std.testing.allocator, .{ .device_id = 4, .key_code = 12, .disposition = .captured });
    const entry = held.orderedRemove(0);
    try std.testing.expectEqual(NativeInput.KeyboardEventDisposition.captured, entry.disposition);
}

test "repeat interval rounds up and rate zero disables repeat" {
    try std.testing.expectEqual(@as(?i32, null), repeatInterval(0));
    try std.testing.expectEqual(@as(?i32, 34), repeatInterval(30));
    try std.testing.expectEqual(@as(?i32, 1), repeatInterval(2000));
}

test "bindings repeat by command policy or explicit configuration" {
    try std.testing.expect(!bindingRepeats(.{ .modifiers = 0, .keysym = 'x', .action = .{ .run = &.{"example"} } }));
    try std.testing.expect(bindingRepeats(.{ .modifiers = 0, .keysym = 'x', .action = .{ .run = &.{"example"} }, .repeat = true }));
    try std.testing.expect(bindingRepeats(.{ .modifiers = 0, .keysym = 'j', .action = .{ .command = .focus_next } }));
    try std.testing.expect(!bindingRepeats(.{ .modifiers = 0, .keysym = 'q', .action = .{ .command = .{ .close = .focused } } }));
}

test "repeat identity only matches its physical key" {
    const identity: RepeatIdentity = .{ .device_id = 4, .key_code = 12, .modifiers = 3, .keysym = 'j' };
    try std.testing.expect(repeatMatchesKey(identity, 4, 12));
    try std.testing.expect(!repeatMatchesKey(identity, 5, 12));
    try std.testing.expect(!repeatMatchesKey(identity, 4, 13));
    try std.testing.expect(!repeatMatchesKey(null, 4, 12));
}
