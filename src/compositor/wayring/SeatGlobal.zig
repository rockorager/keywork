//! Native `wl_seat` policy and transport-independent input delivery.

const SeatGlobal = @This();

const std = @import("std");
const linux = std.os.linux;
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const CompositorGlobal = @import("CompositorGlobal.zig");

const advertised_version: u32 = 10;

allocator: std.mem.Allocator,
server: *Server,
global_name: u32,
name: []const u8,
capabilities: u32,
physical_capabilities: u32,
virtual_keyboard_count: usize = 0,
virtual_pointer_count: usize = 0,
lifecycle: Lifecycle = .active,
lifecycle_listener: ?LifecycleListener = null,
capability_generations: [3]u64 = .{ 0, 0, 0 },
ever_available: [3]bool = .{ false, false, false },
bindings: std.ArrayList(*Binding) = .empty,
children: std.ArrayList(*Child) = .empty,
pointer_focus: ?*CompositorGlobal.Surface = null,
keyboard_focus: ?*CompositorGlobal.Surface = null,
keyboard_focus_listeners: std.ArrayList(KeyboardFocusListener) = .empty,
touch_focus: ?*CompositorGlobal.Surface = null,
cursor_handler: ?CursorHandler = null,
logical_pointer_x: f64 = 0,
logical_pointer_y: f64 = 0,
pointer_x: i32 = 0,
pointer_y: i32 = 0,
keyboard_keys: std.ArrayList(KeyboardKey) = .empty,
keyboard_enter_keys: std.ArrayList(u32) = .empty,
keyboard_modifier_state: KeyboardModifierState = .{},
next_touch_generation: u64 = 1,
touch_sequence_generation: ?u64 = null,
touch_finish_pending: bool = false,
keymap_format: u32 = 0,
keymap_fd: std.posix.fd_t = -1,
keymap_size: u32 = 0,
repeat_rate: i32 = 0,
repeat_delay: i32 = 0,
repeat_info_set: bool = false,
selection_serials: [selection_serial_capacity]SelectionSerial = undefined,
selection_serial_count: usize = 0,
next_selection_serial: usize = 0,
latest_pointer_enter: ?SelectionSerial = null,

const selection_serial_capacity = 32;

const SelectionSerial = struct {
    client_identity: u64,
    serial: u32,
};

pub const Capability = generated.wl_seat_types.capability;

const Lifecycle = enum { active, retiring, finalized };

pub const LifecycleListener = struct {
    context: *anyopaque,
    resource_count_changed: *const fn (*anyopaque, usize) void,
    global_finalized: *const fn (*anyopaque) void,
};

pub const CursorIntent = struct {
    client: *Server.Client,
    pointer: wayring.ObjectHandle,
    serial: u32,
    surface: ?*CompositorGlobal.Surface,
    hotspot_x: i32,
    hotspot_y: i32,
};

pub const CursorHandler = struct {
    context: *anyopaque,
    handle: *const fn (*anyopaque, CursorIntent) anyerror!void,
    clear: ?*const fn (*anyopaque) void = null,
};

pub const KeyboardFocusListener = struct {
    context: *anyopaque,
    changed: *const fn (*anyopaque, ?*CompositorGlobal.Surface) anyerror!void,
};

pub const AxisFrame = struct {
    time_milliseconds: u32,
    axis: u32,
    value: ?i32 = null,
    source: ?u32 = null,
    stopped: bool = false,
    discrete: ?i32 = null,
    value120: ?i32 = null,
};

pub const LogicalPointerPosition = struct {
    x: f64,
    y: f64,
};

const Binding = struct {
    owner: *SeatGlobal,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
};

const ChildKind = enum(u2) { pointer, keyboard, touch };

const Child = struct {
    owner: *SeatGlobal,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    kind: ChildKind,
    capability_generation: u64,
    touch_generation: u64 = 0,
    pointer_enter_serial: u32 = 0,
};

const KeyboardModifiers = struct {
    depressed: u32 = 0,
    latched: u32 = 0,
    locked: u32 = 0,
    group: u32 = 0,
};

const KeyboardModifierState = struct {
    current: KeyboardModifiers = .{},
    physical: KeyboardModifiers = .{},
    virtual_owner: ?*anyopaque = null,

    fn setPhysical(self: *KeyboardModifierState, modifiers: KeyboardModifiers) void {
        self.current = modifiers;
        self.physical = modifiers;
        self.virtual_owner = null;
    }

    fn setVirtual(
        self: *KeyboardModifierState,
        owner: *anyopaque,
        modifiers: KeyboardModifiers,
    ) void {
        self.current = modifiers;
        self.virtual_owner = owner;
    }

    fn clearVirtual(self: *KeyboardModifierState, owner: *anyopaque) bool {
        if (self.virtual_owner != owner) return false;
        self.current = self.physical;
        self.virtual_owner = null;
        return true;
    }
};

const KeyboardKey = struct {
    key: u32,
    physical: bool = false,
    virtual_count: u32 = 0,

    fn held(self: KeyboardKey) bool {
        return self.physical or self.virtual_count != 0;
    }
};

const KeyboardKeySource = enum { physical, virtual };

pub fn init(
    self: *SeatGlobal,
    allocator: std.mem.Allocator,
    server: *Server,
    name: []const u8,
    capabilities: u32,
    cursor_handler: ?CursorHandler,
) !void {
    self.* = .{
        .allocator = allocator,
        .server = server,
        .global_name = undefined,
        .name = name,
        .capabilities = capabilities,
        .physical_capabilities = capabilities,
        .cursor_handler = cursor_handler,
    };
    inline for (std.enums.values(ChildKind)) |kind| {
        if (capabilities & capability(kind) != 0)
            beginCapabilityGeneration(self, kind);
    }
    self.global_name = try server.createGlobal(&generated.wl_seat, advertised_version, .{
        .context = self,
        .bind = bind,
        .finalized = globalFinalizedCallback,
    });
}

pub fn deinit(self: *SeatGlobal) void {
    std.debug.assert(self.bindings.items.len == 0);
    std.debug.assert(self.children.items.len == 0);
    std.debug.assert(self.keyboard_focus_listeners.items.len == 0);
    std.debug.assert(self.lifecycle_listener == null);
    std.debug.assert(self.virtual_keyboard_count == 0);
    std.debug.assert(self.virtual_pointer_count == 0);
    if (self.lifecycle == .active) self.removeGlobal() catch unreachable;
    std.debug.assert(self.lifecycle == .finalized);
    clearFocus(&self.pointer_focus);
    clearFocus(&self.keyboard_focus);
    clearFocus(&self.touch_focus);
    self.keyboard_enter_keys.deinit(self.allocator);
    self.keyboard_keys.deinit(self.allocator);
    self.keyboard_focus_listeners.deinit(self.allocator);
    if (self.keymap_fd >= 0) _ = linux.close(self.keymap_fd);
    self.children.deinit(self.allocator);
    self.bindings.deinit(self.allocator);
    self.* = undefined;
}

/// Retires this global once and makes all existing resources inert.
pub fn removeGlobal(self: *SeatGlobal) !void {
    if (self.lifecycle != .active) return;
    try self.setEffectiveCapabilities(0);
    self.lifecycle = .retiring;
    try self.server.removeGlobal(self.global_name);
}

pub fn setLifecycleListener(self: *SeatGlobal, listener: LifecycleListener) void {
    std.debug.assert(self.lifecycle_listener == null);
    self.lifecycle_listener = listener;
}

pub fn clearLifecycleListener(self: *SeatGlobal) void {
    std.debug.assert(self.lifecycle_listener != null);
    self.lifecycle_listener = null;
}

pub fn globalName(self: *const SeatGlobal) u32 {
    return self.global_name;
}

pub fn resourceCount(self: *const SeatGlobal) usize {
    return self.bindings.items.len + self.children.items.len;
}

pub fn isActive(self: *const SeatGlobal) bool {
    return self.lifecycle == .active;
}

pub fn globalFinalized(self: *const SeatGlobal) bool {
    return self.lifecycle == .finalized;
}

/// Replaces the capability contribution owned by physical input backends.
pub fn setCapabilities(self: *SeatGlobal, capabilities: u32) !void {
    try self.setPhysicalCapabilities(capabilities);
}

pub fn setPhysicalCapabilities(self: *SeatGlobal, capabilities: u32) !void {
    std.debug.assert(self.lifecycle == .active or capabilities == 0);
    self.physical_capabilities = capabilities;
    try self.refreshCapabilities();
}

pub fn addVirtualKeyboard(self: *SeatGlobal) !void {
    std.debug.assert(self.lifecycle == .active);
    self.virtual_keyboard_count = std.math.add(
        usize,
        self.virtual_keyboard_count,
        1,
    ) catch unreachable;
    try self.refreshCapabilities();
}

pub fn removeVirtualKeyboard(self: *SeatGlobal) !void {
    std.debug.assert(self.virtual_keyboard_count != 0);
    self.virtual_keyboard_count -= 1;
    try self.refreshCapabilities();
}

pub fn addVirtualPointer(self: *SeatGlobal) !void {
    std.debug.assert(self.lifecycle == .active);
    self.virtual_pointer_count = std.math.add(
        usize,
        self.virtual_pointer_count,
        1,
    ) catch unreachable;
    try self.refreshCapabilities();
}

pub fn removeVirtualPointer(self: *SeatGlobal) !void {
    std.debug.assert(self.virtual_pointer_count != 0);
    self.virtual_pointer_count -= 1;
    try self.refreshCapabilities();
}

pub fn hasCapability(self: *const SeatGlobal, capability_value: u32) bool {
    return self.capabilities & capability_value != 0;
}

fn refreshCapabilities(self: *SeatGlobal) !void {
    var capabilities = self.physical_capabilities;
    if (self.virtual_keyboard_count != 0) capabilities |= Capability.keyboard;
    if (self.virtual_pointer_count != 0) capabilities |= Capability.pointer;
    try self.setEffectiveCapabilities(capabilities);
}

fn setEffectiveCapabilities(self: *SeatGlobal, capabilities: u32) !void {
    std.debug.assert(self.lifecycle == .active or capabilities == 0);
    if (self.capabilities == capabilities) return;
    const removed = self.capabilities & ~capabilities;
    const added = capabilities & ~self.capabilities;
    if (removed & Capability.pointer != 0) _ = try self.pointerLeave();
    if (removed & Capability.keyboard != 0) {
        _ = try self.keyboardLeave();
        self.keyboard_keys.clearRetainingCapacity();
        self.keyboard_enter_keys.clearRetainingCapacity();
        self.keyboard_modifier_state = .{};
    }
    if (removed & Capability.touch != 0) try self.touchCancel();
    self.capabilities = capabilities;
    inline for (std.enums.values(ChildKind)) |kind| {
        if (added & capability(kind) != 0)
            beginCapabilityGeneration(self, kind);
    }
    for (self.bindings.items) |binding| generated.wl_seat_types.events.capabilities(
        &binding.client.connection,
        binding.resource,
        capabilities,
    ) catch poisonNoMemory(binding.client);
}

pub fn pointerEnter(self: *SeatGlobal, surface: *CompositorGlobal.Surface, x: i32, y: i32) !u32 {
    if (self.pointer_focus != null and self.pointer_focus != surface)
        _ = try self.pointerLeave();
    try setFocus(&self.pointer_focus, surface);
    const serial = self.server.nextSerial();
    self.pointer_x = x;
    self.pointer_y = y;
    var delivered = false;
    for (self.children.items) |child| if (matches(child, .pointer, surface)) {
        try self.sendPointerEnter(child, surface, serial);
        if (!delivered) {
            self.latest_pointer_enter = .{
                .client_identity = surface.client.identity(),
                .serial = serial,
            };
            delivered = true;
        }
    };
    try self.pointerFrame();
    return serial;
}

pub fn pointerLeave(self: *SeatGlobal) !?u32 {
    const surface = self.pointer_focus orelse return null;
    if (self.cursor_handler) |handler| if (handler.clear) |clear|
        clear(handler.context);
    const serial = self.server.nextSerial();
    for (self.children.items) |child| if (matches(child, .pointer, surface)) {
        generated.wl_pointer_types.events.leave(
            &child.client.connection,
            child.resource,
            serial,
            surface.resource,
        ) catch poisonNoMemory(child.client);
        child.pointer_enter_serial = 0;
    };
    try self.pointerFrame();
    clearFocus(&self.pointer_focus);
    self.latest_pointer_enter = null;
    return serial;
}

pub fn pointerMotion(self: *SeatGlobal, time: u32, x: i32, y: i32) !bool {
    const surface = self.pointer_focus orelse return false;
    if (self.pointer_x == x and self.pointer_y == y) return false;
    self.pointer_x = x;
    self.pointer_y = y;
    for (self.children.items) |child| if (matches(child, .pointer, surface))
        try generated.wl_pointer_types.events.motion(&child.client.connection, child.resource, time, x, y);
    return true;
}

pub fn pointerButton(self: *SeatGlobal, time: u32, button: u32, state: u32) !?u32 {
    const surface = self.pointer_focus orelse return null;
    const serial = self.server.nextSerial();
    var delivered = false;
    for (self.children.items) |child| if (matches(child, .pointer, surface)) {
        try generated.wl_pointer_types.events.button(&child.client.connection, child.resource, serial, time, button, state);
        if (!delivered) {
            self.recordSelectionSerial(surface.client, serial);
            delivered = true;
        }
    };
    return serial;
}

pub fn pointerFrame(self: *SeatGlobal) !void {
    const surface = self.pointer_focus orelse return;
    for (self.children.items) |child| if (matches(child, .pointer, surface) and
        try child.client.resourceVersion(child.resource, &generated.wl_pointer) >= 5)
        generated.wl_pointer_types.events.frame(
            &child.client.connection,
            child.resource,
        ) catch poisonNoMemory(child.client);
}

/// Delivers one axis in the current logical pointer frame. Fixed-point values
/// use Wayland's 24.8 representation; callers end the group with pointerFrame.
pub fn pointerAxisFrame(self: *SeatGlobal, frame: AxisFrame) !void {
    std.debug.assert((frame.discrete == null and frame.value120 == null) or frame.value != null);
    const surface = self.pointer_focus orelse return;
    for (self.children.items) |child| {
        if (!matches(child, .pointer, surface)) continue;
        const version = try child.client.resourceVersion(child.resource, &generated.wl_pointer);
        if (frame.source) |source| {
            if (pointerSupportsAxisSource(version, source))
                try generated.wl_pointer_types.events.axis_source(
                    &child.client.connection,
                    child.resource,
                    source,
                );
        }
        if (version >= 5 and version < 8) if (frame.discrete) |value|
            try generated.wl_pointer_types.events.axis_discrete(&child.client.connection, child.resource, frame.axis, value);
        if (version >= 8) if (frame.value120) |value| try generated.wl_pointer_types.events.axis_value120(&child.client.connection, child.resource, frame.axis, value);
        if (frame.value) |value| try generated.wl_pointer_types.events.axis(&child.client.connection, child.resource, frame.time_milliseconds, frame.axis, value);
        if (version >= 5 and frame.stopped)
            try generated.wl_pointer_types.events.axis_stop(&child.client.connection, child.resource, frame.time_milliseconds, frame.axis);
    }
}

fn pointerSupportsAxisSource(version: u32, source: u32) bool {
    if (version < 5) return false;
    return source != @intFromEnum(generated.wl_pointer_types.axis_source.wheel_tilt) or
        version >= 6;
}

/// Takes ownership of fd and retains it as the source for current and future
/// keyboard resources. Every queued protocol event receives its own duplicate.
pub fn keyboardKeymap(self: *SeatGlobal, format: u32, fd: std.posix.fd_t, size: u32) !void {
    if (self.keymap_fd >= 0) _ = linux.close(self.keymap_fd);
    self.keymap_format = format;
    self.keymap_fd = fd;
    self.keymap_size = size;
    for (self.children.items) |child| {
        if (child.kind != .keyboard or !self.childActive(child)) continue;
        self.sendKeymap(child) catch poisonNoMemory(child.client);
    }
}

pub fn keyboardEnter(self: *SeatGlobal, surface: *CompositorGlobal.Surface, keys: []const u32) !u32 {
    if (self.keyboard_focus != null and self.keyboard_focus != surface)
        _ = try self.keyboardLeave();
    try self.setPhysicalKeys(keys);
    try self.collectHeldKeys();
    try setFocus(&self.keyboard_focus, surface);
    const serial = self.server.nextSerial();
    try self.notifyKeyboardFocus();
    var delivered = false;
    for (self.children.items) |child| if (matches(child, .keyboard, surface)) {
        try generated.wl_keyboard_types.events.enter(
            &child.client.connection,
            child.resource,
            serial,
            surface.resource,
            std.mem.sliceAsBytes(self.keyboard_enter_keys.items),
        );
        if (!delivered) {
            self.recordSelectionSerial(surface.client, serial);
            delivered = true;
        }
    };
    return serial;
}

pub fn keyboardLeave(self: *SeatGlobal) !?u32 {
    const surface = self.keyboard_focus orelse return null;
    const serial = self.server.nextSerial();
    for (self.children.items) |child| if (matches(child, .keyboard, surface))
        generated.wl_keyboard_types.events.leave(
            &child.client.connection,
            child.resource,
            serial,
            surface.resource,
        ) catch poisonNoMemory(child.client);
    clearFocus(&self.keyboard_focus);
    try self.notifyKeyboardFocus();
    return serial;
}

pub fn keyboardKey(self: *SeatGlobal, time: u32, key: u32, state: u32) !?u32 {
    if (!try self.updateKeyboardKey(key, state, .physical)) return null;
    return self.sendKeyboardKey(time, key, state);
}

/// Updates one independently deduplicated virtual-keyboard stream. Callers
/// retain per-device ownership and release each accepted press on teardown.
pub fn virtualKey(self: *SeatGlobal, time: u32, key: u32, state: u32) !?u32 {
    if (!try self.updateKeyboardKey(key, state, .virtual)) return null;
    return self.sendKeyboardKey(time, key, state);
}

pub fn clearPhysicalKeys(self: *SeatGlobal, time: u32) !void {
    var index: usize = 0;
    while (index < self.keyboard_keys.items.len) {
        const key = &self.keyboard_keys.items[index];
        if (!key.physical) {
            index += 1;
            continue;
        }
        key.physical = false;
        if (key.virtual_count != 0) {
            index += 1;
            continue;
        }
        const key_code = key.key;
        _ = self.keyboard_keys.orderedRemove(index);
        _ = try self.sendKeyboardKey(
            time,
            key_code,
            @intFromEnum(generated.wl_keyboard_types.key_state.released),
        );
    }
}

fn sendKeyboardKey(self: *SeatGlobal, time: u32, key: u32, state: u32) !?u32 {
    const surface = self.keyboard_focus orelse return null;
    const serial = self.server.nextSerial();
    var delivered = false;
    for (self.children.items) |child| if (matches(child, .keyboard, surface)) {
        generated.wl_keyboard_types.events.key(
            &child.client.connection,
            child.resource,
            serial,
            time,
            key,
            state,
        ) catch {
            poisonNoMemory(child.client);
            continue;
        };
        if (!delivered) {
            self.recordSelectionSerial(surface.client, serial);
            delivered = true;
        }
    };
    return serial;
}

pub fn keyboardModifiers(self: *SeatGlobal, serial: u32, depressed: u32, latched: u32, locked: u32, group: u32) !void {
    try self.setPhysicalModifiers(serial, depressed, latched, locked, group);
}

pub fn setPhysicalModifiers(self: *SeatGlobal, serial: u32, depressed: u32, latched: u32, locked: u32, group: u32) !void {
    self.keyboard_modifier_state.setPhysical(.{
        .depressed = depressed,
        .latched = latched,
        .locked = locked,
        .group = group,
    });
    try self.sendCurrentKeyboardModifiers(serial);
}

pub fn setVirtualModifiers(
    self: *SeatGlobal,
    owner: *anyopaque,
    depressed: u32,
    latched: u32,
    locked: u32,
    group: u32,
) !void {
    self.keyboard_modifier_state.setVirtual(owner, .{
        .depressed = depressed,
        .latched = latched,
        .locked = locked,
        .group = group,
    });
    try self.sendCurrentKeyboardModifiers(self.server.nextSerial());
}

pub fn clearVirtualModifiers(self: *SeatGlobal, owner: *anyopaque) !void {
    if (!self.keyboard_modifier_state.clearVirtual(owner)) return;
    try self.sendCurrentKeyboardModifiers(self.server.nextSerial());
}

pub fn sendCurrentKeyboardModifiers(self: *SeatGlobal, serial: u32) !void {
    const modifiers = self.keyboard_modifier_state.current;
    const surface = self.keyboard_focus orelse return;
    for (self.children.items) |child| if (matches(child, .keyboard, surface))
        generated.wl_keyboard_types.events.modifiers(
            &child.client.connection,
            child.resource,
            serial,
            modifiers.depressed,
            modifiers.latched,
            modifiers.locked,
            modifiers.group,
        ) catch poisonNoMemory(child.client);
}

fn updateKeyboardKey(
    self: *SeatGlobal,
    key_code: u32,
    state: u32,
    source: KeyboardKeySource,
) !bool {
    const pressed = state == @intFromEnum(generated.wl_keyboard_types.key_state.pressed);
    const released = state == @intFromEnum(generated.wl_keyboard_types.key_state.released);
    if (!pressed and !released) return false;
    const index = for (self.keyboard_keys.items, 0..) |key, index| {
        if (key.key == key_code) break index;
    } else null;
    if (pressed) {
        if (index) |found| {
            const key = &self.keyboard_keys.items[found];
            const was_held = key.held();
            switch (source) {
                .physical => {
                    if (key.physical) return false;
                    key.physical = true;
                },
                .virtual => key.virtual_count = std.math.add(
                    u32,
                    key.virtual_count,
                    1,
                ) catch unreachable,
            }
            return !was_held;
        }
        try self.keyboard_keys.append(self.allocator, .{
            .key = key_code,
            .physical = source == .physical,
            .virtual_count = if (source == .virtual) 1 else 0,
        });
        return true;
    }
    const found = index orelse return false;
    const key = &self.keyboard_keys.items[found];
    switch (source) {
        .physical => {
            if (!key.physical) return false;
            key.physical = false;
        },
        .virtual => {
            if (key.virtual_count == 0) return false;
            key.virtual_count -= 1;
        },
    }
    if (key.held()) return false;
    _ = self.keyboard_keys.orderedRemove(found);
    return true;
}

fn setPhysicalKeys(self: *SeatGlobal, keys: []const u32) !void {
    try self.keyboard_keys.ensureTotalCapacity(
        self.allocator,
        self.keyboard_keys.items.len + keys.len,
    );
    for (self.keyboard_keys.items) |*key| key.physical = false;
    for (keys) |key_code| {
        for (self.keyboard_keys.items) |*key| {
            if (key.key != key_code) continue;
            key.physical = true;
            break;
        } else self.keyboard_keys.appendAssumeCapacity(.{
            .key = key_code,
            .physical = true,
        });
    }
    var index: usize = 0;
    while (index < self.keyboard_keys.items.len) {
        if (self.keyboard_keys.items[index].held()) {
            index += 1;
        } else {
            _ = self.keyboard_keys.orderedRemove(index);
        }
    }
}

fn collectHeldKeys(self: *SeatGlobal) !void {
    try self.keyboard_enter_keys.ensureTotalCapacity(
        self.allocator,
        self.keyboard_keys.items.len,
    );
    self.keyboard_enter_keys.clearRetainingCapacity();
    for (self.keyboard_keys.items) |key| {
        if (key.held()) self.keyboard_enter_keys.appendAssumeCapacity(key.key);
    }
}

pub fn keyboardRepeatInfo(self: *SeatGlobal, rate: i32, delay: i32) !void {
    self.repeat_rate = rate;
    self.repeat_delay = delay;
    self.repeat_info_set = true;
    for (self.children.items) |child| {
        if (child.kind != .keyboard or !self.childActive(child)) continue;
        if (try child.client.resourceVersion(child.resource, &generated.wl_keyboard) >= 4)
            generated.wl_keyboard_types.events.repeat_info(
                &child.client.connection,
                child.resource,
                rate,
                delay,
            ) catch poisonNoMemory(child.client);
    }
}

pub fn currentKeyboardRepeatInfo(self: *const SeatGlobal) struct { rate: i32, delay: i32 } {
    return .{ .rate = self.repeat_rate, .delay = self.repeat_delay };
}

/// Returns a borrowed focus retained until the next focus or capability change.
pub fn pointerFocus(self: *const SeatGlobal) ?*CompositorGlobal.Surface {
    return self.pointer_focus;
}

/// Stores the compositor-owned output-space position for this seat. Native
/// physical input keeps its authoritative coordinates outside SeatGlobal;
/// transient virtual seats use this independent logical position directly.
pub fn setLogicalPointerPosition(self: *SeatGlobal, x: f64, y: f64) void {
    std.debug.assert(std.math.isFinite(x) and std.math.isFinite(y));
    self.logical_pointer_x = x;
    self.logical_pointer_y = y;
}

pub fn logicalPointerPosition(self: *const SeatGlobal) LogicalPointerPosition {
    return .{ .x = self.logical_pointer_x, .y = self.logical_pointer_y };
}

/// Captures a live pointer resource without retaining its owning seat child.
pub fn pointerHandle(
    self: *const SeatGlobal,
    client: *const Server.Client,
    resource_id: u32,
) ?wayring.ObjectHandle {
    for (self.children.items) |child| {
        if (child.kind == .pointer and
            child.client == client and
            child.resource.id == resource_id)
            return child.resource;
    }
    return null;
}

/// Returns whether a captured pointer still belongs to an active capability.
pub fn pointerHandleIsActive(
    self: *const SeatGlobal,
    client: *const Server.Client,
    handle: wayring.ObjectHandle,
) bool {
    for (self.children.items) |child| {
        if (child.kind == .pointer and
            child.client == client and
            child.resource.id == handle.id and
            child.resource.generation == handle.generation)
            return self.childActive(child);
    }
    return false;
}

/// Validates a cursor-shape serial against one exact live pointer resource.
pub fn acceptsPointerCursorSerial(
    self: *const SeatGlobal,
    client: *const Server.Client,
    handle: wayring.ObjectHandle,
    serial: u32,
) bool {
    const focus = self.pointer_focus orelse return false;
    return self.acceptsPointerEnterSerial(client, handle, focus, serial);
}

/// Validates an enter serial for one pointer and its exact focused surface.
pub fn acceptsPointerEnterSerial(
    self: *const SeatGlobal,
    client: *const Server.Client,
    handle: wayring.ObjectHandle,
    surface: *const CompositorGlobal.Surface,
    serial: u32,
) bool {
    if (self.pointer_focus != surface or
        !surface.resource_alive or
        surface.client != client) return false;
    for (self.children.items) |child| {
        if (child.kind == .pointer and
            child.client == client and
            child.resource.id == handle.id and
            child.resource.generation == handle.generation)
            return self.childActive(child) and child.pointer_enter_serial == serial;
    }
    return false;
}

/// Updates focused pointer coordinates without emitting a motion event.
pub fn warpPointer(
    self: *SeatGlobal,
    surface: *const CompositorGlobal.Surface,
    x: i32,
    y: i32,
) bool {
    if (self.pointer_focus != surface or !surface.resource_alive) return false;
    self.pointer_x = x;
    self.pointer_y = y;
    return true;
}

/// Returns a borrowed focus retained until the next focus or capability change.
pub fn keyboardFocus(self: *const SeatGlobal) ?*CompositorGlobal.Surface {
    return self.keyboard_focus;
}

/// Copies the listener and retains its context until removal.
pub fn addKeyboardFocusListener(
    self: *SeatGlobal,
    listener: KeyboardFocusListener,
) error{OutOfMemory}!void {
    for (self.keyboard_focus_listeners.items) |existing|
        std.debug.assert(existing.context != listener.context);
    try self.keyboard_focus_listeners.append(self.allocator, listener);
}

pub fn removeKeyboardFocusListener(self: *SeatGlobal, context: *anyopaque) void {
    for (self.keyboard_focus_listeners.items, 0..) |listener, index| {
        if (listener.context != context) continue;
        _ = self.keyboard_focus_listeners.orderedRemove(index);
        return;
    }
    unreachable;
}

/// Returns whether resource is a binding of this seat owned by client.
pub fn ownsResource(self: *const SeatGlobal, client: *const Server.Client, resource_id: u32) bool {
    for (self.bindings.items) |binding| {
        if (binding.client == client and binding.resource.id == resource_id) return true;
    }
    return false;
}

/// Selection claims accept a bounded history of input serials delivered to
/// the claiming client rather than only the most recent event.
pub fn acceptsSelectionSerial(self: *const SeatGlobal, client: *const Server.Client, serial: u32) bool {
    for (self.selection_serials[0..self.selection_serial_count]) |entry| {
        if (entry.client_identity == client.identity() and entry.serial == serial) return true;
    }
    return false;
}

/// Activation accepts input serials plus the latest pointer-enter serial sent
/// through this exact seat binding.
pub fn acceptsActivationSerial(
    self: *const SeatGlobal,
    client: *const Server.Client,
    seat_resource_id: u32,
    serial: u32,
) bool {
    if (!self.ownsResource(client, seat_resource_id)) return false;
    if (self.acceptsSelectionSerial(client, serial)) return true;
    const enter = self.latest_pointer_enter orelse return false;
    return enter.client_identity == client.identity() and enter.serial == serial;
}

pub fn activationSurfaceFocused(
    self: *const SeatGlobal,
    surface: *const CompositorGlobal.Surface,
) bool {
    if (!surface.resource_alive) return false;
    return self.keyboard_focus == surface or
        self.pointer_focus == surface or
        (self.touch_focus == surface and !self.touch_finish_pending);
}

pub fn touchDown(self: *SeatGlobal, surface: *CompositorGlobal.Surface, time: u32, id: i32, x: i32, y: i32) !u32 {
    if (self.touch_focus != null and self.touch_focus != surface)
        try self.touchCancel();
    if (self.touch_focus == null) {
        self.touch_sequence_generation = self.next_touch_generation - 1;
    }
    self.touch_finish_pending = false;
    try setFocus(&self.touch_focus, surface);
    const serial = self.server.nextSerial();
    var delivered = false;
    for (self.children.items) |child| if (matchesTouchSequence(self, child, surface)) {
        try generated.wl_touch_types.events.down(&child.client.connection, child.resource, serial, time, surface.resource, id, x, y);
        if (!delivered) {
            self.recordSelectionSerial(surface.client, serial);
            delivered = true;
        }
    };
    return serial;
}

pub fn touchUp(self: *SeatGlobal, time: u32, id: i32) !?u32 {
    const surface = self.touch_focus orelse return null;
    const serial = self.server.nextSerial();
    var delivered = false;
    for (self.children.items) |child| if (matchesTouchSequence(self, child, surface)) {
        try generated.wl_touch_types.events.up(&child.client.connection, child.resource, serial, time, id);
        if (!delivered) {
            self.recordSelectionSerial(surface.client, serial);
            delivered = true;
        }
    };
    return serial;
}

pub fn touchMotion(self: *SeatGlobal, time: u32, id: i32, x: i32, y: i32) !void {
    const surface = self.touch_focus orelse return;
    for (self.children.items) |child| if (matchesTouchSequence(self, child, surface))
        try generated.wl_touch_types.events.motion(&child.client.connection, child.resource, time, id, x, y);
}

pub fn touchFrame(self: *SeatGlobal) !void {
    try touchSimple(self, .frame);
    if (self.touch_finish_pending) self.clearTouchFocus();
}
pub fn touchCancel(self: *SeatGlobal) !void {
    try touchSimple(self, .cancel);
    self.clearTouchFocus();
}

pub fn touchFinish(self: *SeatGlobal) void {
    if (self.touch_focus != null) self.touch_finish_pending = true;
}

pub fn touchShape(self: *SeatGlobal, id: i32, major: i32, minor: i32) !void {
    const surface = self.touch_focus orelse return;
    for (self.children.items) |child| if (matchesTouchSequence(self, child, surface) and
        try child.client.resourceVersion(child.resource, &generated.wl_touch) >= 6)
        try generated.wl_touch_types.events.shape(&child.client.connection, child.resource, id, major, minor);
}

pub fn touchOrientation(self: *SeatGlobal, id: i32, orientation: i32) !void {
    const surface = self.touch_focus orelse return;
    for (self.children.items) |child| if (matchesTouchSequence(self, child, surface) and
        try child.client.resourceVersion(child.resource, &generated.wl_touch) >= 6)
        try generated.wl_touch_types.events.orientation(&child.client.connection, child.resource, id, orientation);
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *SeatGlobal = @ptrCast(@alignCast(context));
    const binding = self.allocator.create(Binding) catch return client.postNoMemory();
    var registered = false;
    errdefer if (!registered) self.allocator.destroy(binding);
    self.bindings.ensureUnusedCapacity(self.allocator, 1) catch return client.postNoMemory();
    binding.* = .{ .owner = self, .client = client, .resource = undefined };
    binding.resource = client.createResource(id, &generated.wl_seat, version, .{
        .context = binding,
        .dispatch = dispatchSeat,
        .destroy = destroyBinding,
    }) catch return client.postNoMemory();
    self.bindings.appendAssumeCapacity(binding);
    registered = true;
    self.notifyResourceCount();
    if (version >= 2) try generated.wl_seat_types.events.name(&client.connection, binding.resource, self.name);
    try generated.wl_seat_types.events.capabilities(
        &client.connection,
        binding.resource,
        if (self.lifecycle == .active) self.capabilities else 0,
    );
}

fn dispatchSeat(context: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    const binding: *Binding = @ptrCast(@alignCast(context));
    switch (try generated.wl_seat_types.decodeRequest(&client.connection, resource, message)) {
        .get_pointer => |r| try binding.owner.createChild(client, resource, r.id, .pointer),
        .get_keyboard => |r| try binding.owner.createChild(client, resource, r.id, .keyboard),
        .get_touch => |r| try binding.owner.createChild(client, resource, r.id, .touch),
        .release => {},
    }
}

fn createChild(self: *SeatGlobal, client: *Server.Client, seat: wayring.ObjectHandle, id: u32, kind: ChildKind) !void {
    const kind_index = childKindIndex(kind);
    if (!self.ever_available[kind_index])
        return client.postError(seat, @intFromEnum(generated.wl_seat_types.@"error".missing_capability), "requested wl_seat capability has never been available");
    const child = self.allocator.create(Child) catch return client.postNoMemory();
    var registered = false;
    errdefer if (!registered) self.allocator.destroy(child);
    self.children.ensureUnusedCapacity(self.allocator, 1) catch return client.postNoMemory();
    const interface = switch (kind) {
        .pointer => &generated.wl_pointer,
        .keyboard => &generated.wl_keyboard,
        .touch => &generated.wl_touch,
    };
    const version = @min(try client.resourceVersion(seat, &generated.wl_seat), interface.version);
    child.* = .{
        .owner = self,
        .client = client,
        .resource = undefined,
        .kind = kind,
        .capability_generation = self.capability_generations[kind_index],
    };
    if (kind == .touch) {
        child.touch_generation = self.next_touch_generation;
        self.next_touch_generation = std.math.add(u64, self.next_touch_generation, 1) catch
            unreachable;
    }
    child.resource = client.createResource(id, interface, version, .{
        .context = child,
        .dispatch = switch (kind) {
            .pointer => dispatchPointer,
            .keyboard => dispatchKeyboard,
            .touch => dispatchTouch,
        },
        .destroy = destroyChild,
    }) catch return client.postNoMemory();
    self.children.appendAssumeCapacity(child);
    registered = true;
    self.notifyResourceCount();
    if (!self.childActive(child)) return;
    switch (kind) {
        .pointer => if (self.pointer_focus) |surface| {
            if (surface.client == client and surface.resource_alive) {
                const serial = self.server.nextSerial();
                try self.sendPointerEnter(child, surface, serial);
                self.latest_pointer_enter = .{
                    .client_identity = client.identity(),
                    .serial = serial,
                };
                if (version >= 5)
                    try generated.wl_pointer_types.events.frame(&client.connection, child.resource);
            }
        },
        .keyboard => {
            if (self.keymap_fd >= 0) {
                self.sendKeymap(child) catch return client.postNoMemory();
                if (self.repeat_info_set and version >= 4) try generated.wl_keyboard_types.events.repeat_info(
                    &client.connection,
                    child.resource,
                    self.repeat_rate,
                    self.repeat_delay,
                );
                if (self.keyboard_focus) |surface| {
                    if (surface.client == client and surface.resource_alive) {
                        try self.collectHeldKeys();
                        const serial = self.server.nextSerial();
                        try generated.wl_keyboard_types.events.enter(
                            &client.connection,
                            child.resource,
                            serial,
                            surface.resource,
                            std.mem.sliceAsBytes(self.keyboard_enter_keys.items),
                        );
                        self.recordSelectionSerial(client, serial);
                        try self.sendKeyboardModifiers(child, serial);
                    }
                }
            }
        },
        .touch => {},
    }
}

fn sendKeymap(self: *SeatGlobal, child: *Child) !void {
    std.debug.assert(child.kind == .keyboard and self.keymap_fd >= 0);
    const duplicate = std.c.fcntl(
        self.keymap_fd,
        linux.F.DUPFD_CLOEXEC,
        @as(c_int, 0),
    );
    if (duplicate < 0) return error.DuplicateKeymapFailed;
    var duplicate_owned = true;
    defer if (duplicate_owned) {
        _ = linux.close(duplicate);
    };
    try generated.wl_keyboard_types.events.keymap(
        &child.client.connection,
        child.resource,
        self.keymap_format,
        duplicate,
        self.keymap_size,
    );
    duplicate_owned = false;
}

fn sendPointerEnter(
    self: *SeatGlobal,
    child: *Child,
    surface: *CompositorGlobal.Surface,
    serial: u32,
) !void {
    try generated.wl_pointer_types.events.enter(
        &child.client.connection,
        child.resource,
        serial,
        surface.resource,
        self.pointer_x,
        self.pointer_y,
    );
    child.pointer_enter_serial = serial;
}

fn sendKeyboardModifiers(self: *SeatGlobal, child: *Child, serial: u32) !void {
    const modifiers = self.keyboard_modifier_state.current;
    try generated.wl_keyboard_types.events.modifiers(
        &child.client.connection,
        child.resource,
        serial,
        modifiers.depressed,
        modifiers.latched,
        modifiers.locked,
        modifiers.group,
    );
}

fn dispatchPointer(context: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    const child: *Child = @ptrCast(@alignCast(context));
    switch (try generated.wl_pointer_types.decodeRequest(&client.connection, resource, message)) {
        .set_cursor => |r| {
            if (!child.owner.childActive(child)) return;
            const focused = child.owner.pointer_focus orelse return;
            if (!focused.resource_alive or
                focused.client != client or
                child.pointer_enter_serial != r.serial) return;
            const surface = if (r.surface) |id| blk: {
                const object = client.connection.object(id) orelse return error.UnknownSurface;
                break :blk try CompositorGlobal.surfaceFor(client, .{ .id = id, .generation = object.generation });
            } else null;
            if (child.owner.cursor_handler) |handler| try handler.handle(handler.context, .{
                .client = client,
                .pointer = resource,
                .serial = r.serial,
                .surface = surface,
                .hotspot_x = r.hotspot_x,
                .hotspot_y = r.hotspot_y,
            });
        },
        .release => {},
    }
}

fn dispatchKeyboard(_: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    _ = try generated.wl_keyboard_types.decodeRequest(&client.connection, resource, message);
}
fn dispatchTouch(_: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    _ = try generated.wl_touch_types.decodeRequest(&client.connection, resource, message);
}

fn destroyBinding(context: *anyopaque, _: *Server.Client, _: wayring.ObjectHandle) void {
    const binding: *Binding = @ptrCast(@alignCast(context));
    const owner = binding.owner;
    removeOwned(Binding, owner.allocator, &owner.bindings, binding);
    owner.notifyResourceCount();
}
fn destroyChild(context: *anyopaque, _: *Server.Client, _: wayring.ObjectHandle) void {
    const child: *Child = @ptrCast(@alignCast(context));
    const owner = child.owner;
    removeOwned(Child, owner.allocator, &owner.children, child);
    owner.notifyResourceCount();
}

fn notifyResourceCount(self: *SeatGlobal) void {
    const listener = self.lifecycle_listener orelse return;
    listener.resource_count_changed(listener.context, self.resourceCount());
}

fn globalFinalizedCallback(context: *anyopaque) void {
    const self: *SeatGlobal = @ptrCast(@alignCast(context));
    std.debug.assert(self.lifecycle == .retiring);
    self.lifecycle = .finalized;
    const listener = self.lifecycle_listener orelse return;
    listener.global_finalized(listener.context);
}

fn removeOwned(comptime T: type, allocator: std.mem.Allocator, list: *std.ArrayList(*T), item: *T) void {
    for (list.items, 0..) |candidate, index| if (candidate == item) {
        _ = list.orderedRemove(index);
        allocator.destroy(item);
        return;
    };
    unreachable;
}

fn poisonNoMemory(client: *Server.Client) void {
    client.postNoMemory() catch {};
}

fn matches(child: *const Child, kind: ChildKind, surface: *const CompositorGlobal.Surface) bool {
    return child.kind == kind and
        child.owner.childActive(child) and
        child.client == surface.client and
        surface.resource_alive;
}

fn matchesTouchSequence(
    self: *const SeatGlobal,
    child: *const Child,
    surface: *const CompositorGlobal.Surface,
) bool {
    return matches(child, .touch, surface) and
        child.touch_generation <= (self.touch_sequence_generation orelse return false);
}

fn childActive(self: *const SeatGlobal, child: *const Child) bool {
    const index = childKindIndex(child.kind);
    return self.capabilities & capability(child.kind) != 0 and
        child.capability_generation == self.capability_generations[index];
}

fn beginCapabilityGeneration(self: *SeatGlobal, kind: ChildKind) void {
    const index = childKindIndex(kind);
    self.capability_generations[index] = std.math.add(
        u64,
        self.capability_generations[index],
        1,
    ) catch unreachable;
    self.ever_available[index] = true;
}

fn recordSelectionSerial(self: *SeatGlobal, client: *Server.Client, serial: u32) void {
    self.selection_serials[self.next_selection_serial] = .{
        .client_identity = client.identity(),
        .serial = serial,
    };
    self.next_selection_serial =
        (self.next_selection_serial + 1) % selection_serial_capacity;
    self.selection_serial_count = @min(
        self.selection_serial_count + 1,
        selection_serial_capacity,
    );
}

fn childKindIndex(kind: ChildKind) usize {
    return @intFromEnum(kind);
}

fn capability(kind: ChildKind) u32 {
    return @as(u32, 1) << @intCast(childKindIndex(kind));
}

fn setFocus(slot: *?*CompositorGlobal.Surface, surface: *CompositorGlobal.Surface) !void {
    if (slot.* == surface) return;
    try surface.reference();
    clearFocus(slot);
    slot.* = surface;
}
fn clearFocus(slot: *?*CompositorGlobal.Surface) void {
    if (slot.*) |surface| surface.unreference();
    slot.* = null;
}

fn notifyKeyboardFocus(self: *SeatGlobal) !void {
    for (self.keyboard_focus_listeners.items) |listener|
        try listener.changed(listener.context, self.keyboard_focus);
}

fn clearTouchFocus(self: *SeatGlobal) void {
    clearFocus(&self.touch_focus);
    self.touch_sequence_generation = null;
    self.touch_finish_pending = false;
}

const TouchSimple = enum { frame, cancel };
fn touchSimple(self: *SeatGlobal, event: TouchSimple) !void {
    const surface = self.touch_focus orelse return;
    for (self.children.items) |child| if (matchesTouchSequence(self, child, surface)) switch (event) {
        .frame => try generated.wl_touch_types.events.frame(&child.client.connection, child.resource),
        .cancel => try generated.wl_touch_types.events.cancel(&child.client.connection, child.resource),
    };
}

test "seat capability constants match core protocol" {
    try std.testing.expectEqual(@as(u32, 1), Capability.pointer);
    try std.testing.expectEqual(@as(u32, 2), Capability.keyboard);
    try std.testing.expectEqual(@as(u32, 4), Capability.touch);
}

test "pointer axis source respects event and enum versions" {
    const wheel = @intFromEnum(generated.wl_pointer_types.axis_source.wheel);
    const wheel_tilt = @intFromEnum(generated.wl_pointer_types.axis_source.wheel_tilt);
    try std.testing.expect(!pointerSupportsAxisSource(4, wheel));
    try std.testing.expect(pointerSupportsAxisSource(5, wheel));
    try std.testing.expect(!pointerSupportsAxisSource(5, wheel_tilt));
    try std.testing.expect(pointerSupportsAxisSource(6, wheel_tilt));
}

test "seat aggregates physical and virtual capabilities keys and modifiers" {
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var seat: SeatGlobal = undefined;
    try seat.init(std.testing.allocator, &server, "default", 0, null);
    defer seat.deinit();

    try seat.setPhysicalCapabilities(Capability.pointer | Capability.keyboard);
    try seat.addVirtualKeyboard();
    try seat.addVirtualPointer();
    try seat.setPhysicalCapabilities(0);
    try std.testing.expect(seat.hasCapability(Capability.pointer));
    try std.testing.expect(seat.hasCapability(Capability.keyboard));

    _ = try seat.keyboardKey(
        1,
        30,
        @intFromEnum(generated.wl_keyboard_types.key_state.pressed),
    );
    _ = try seat.virtualKey(
        2,
        30,
        @intFromEnum(generated.wl_keyboard_types.key_state.pressed),
    );
    _ = try seat.keyboardKey(
        3,
        30,
        @intFromEnum(generated.wl_keyboard_types.key_state.released),
    );
    try std.testing.expectEqual(@as(usize, 1), seat.keyboard_keys.items.len);
    try std.testing.expect(!seat.keyboard_keys.items[0].physical);
    try std.testing.expectEqual(@as(u32, 1), seat.keyboard_keys.items[0].virtual_count);
    _ = try seat.virtualKey(
        4,
        30,
        @intFromEnum(generated.wl_keyboard_types.key_state.released),
    );
    try std.testing.expectEqual(@as(usize, 0), seat.keyboard_keys.items.len);

    var owner_a: u8 = 0;
    var owner_b: u8 = 0;
    try seat.setPhysicalModifiers(1, 1, 2, 3, 4);
    try seat.setVirtualModifiers(&owner_a, 5, 6, 7, 8);
    try seat.setVirtualModifiers(&owner_b, 9, 10, 11, 12);
    try seat.clearVirtualModifiers(&owner_a);
    try std.testing.expectEqual(@as(u32, 9), seat.keyboard_modifier_state.current.depressed);
    try seat.clearVirtualModifiers(&owner_b);
    try std.testing.expectEqual(@as(u32, 1), seat.keyboard_modifier_state.current.depressed);
    try std.testing.expectEqual(@as(u32, 4), seat.keyboard_modifier_state.current.group);

    try seat.removeVirtualPointer();
    try seat.removeVirtualKeyboard();
    try std.testing.expect(!seat.hasCapability(Capability.pointer));
    try std.testing.expect(!seat.hasCapability(Capability.keyboard));
}

const LifecycleTestContext = struct {
    counts: [4]usize = undefined,
    count_len: usize = 0,
    finalizations: usize = 0,

    fn countChanged(context: *anyopaque, count: usize) void {
        const self: *LifecycleTestContext = @ptrCast(@alignCast(context));
        self.counts[self.count_len] = count;
        self.count_len += 1;
    }

    fn finalized(context: *anyopaque) void {
        const self: *LifecycleTestContext = @ptrCast(@alignCast(context));
        self.finalizations += 1;
    }
};

test "inputless seat retirement accepts entitled late binds and tracks resources" {
    const core = @import("wayring-core");
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var seat: SeatGlobal = undefined;
    try seat.init(std.testing.allocator, &server, "transient", 0, null);
    var lifecycle: LifecycleTestContext = .{};
    seat.setLifecycleListener(.{
        .context = &lifecycle,
        .resource_count_changed = LifecycleTestContext.countChanged,
        .global_finalized = LifecycleTestContext.finalized,
    });
    const client = try server.createClient();
    defer server.destroyClient(client) catch unreachable;
    var peer = wayring.Connection.init(std.testing.allocator, .client, wayring.default_max_frame_size);
    defer peer.deinit();
    _ = try core.bootstrapDisplay(&peer);
    const registry: wayring.ObjectHandle = .{ .id = 2, .generation = try core.getRegistry(&peer, 2) };
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    var advertisement = peer.popMessage() orelse return error.MissingSeatAdvertisement;
    defer advertisement.deinit();
    const advertised = (try core.decodeRegistryEvent(&advertisement, registry.id)).global;
    try std.testing.expectEqual(seat.globalName(), advertised.name);
    try std.testing.expectEqualStrings(generated.wl_seat.name, advertised.interface);

    const first: wayring.ObjectHandle = .{
        .id = 3,
        .generation = try core.bind(&peer, registry.id, advertised.name, advertised.interface, 10, 3, &generated.wl_seat),
    };
    try transferToServer(&peer, client);
    try std.testing.expectEqual(@as(usize, 1), seat.resourceCount());
    try seat.removeGlobal();
    try std.testing.expect(!seat.isActive());
    try transferFromServer(&peer, client);

    var saw_remove = false;
    var first_capabilities_zero = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == registry.id) {
            saw_remove = (try core.decodeRegistryEvent(&message, registry.id)).global_remove == advertised.name;
        } else if (message.object_id == first.id) {
            switch (try generated.wl_seat_types.decodeEvent(&peer, first, &message)) {
                .capabilities => |event| first_capabilities_zero = event.capabilities == 0,
                .name => {},
            }
        }
    }
    try std.testing.expect(saw_remove and first_capabilities_zero);

    const late: wayring.ObjectHandle = .{
        .id = 4,
        .generation = try core.bind(&peer, registry.id, advertised.name, advertised.interface, 10, 4, &generated.wl_seat),
    };
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    var late_named = false;
    var late_inert = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        switch (try generated.wl_seat_types.decodeEvent(&peer, late, &message)) {
            .name => |event| late_named = std.mem.eql(u8, event.name, "transient"),
            .capabilities => |event| late_inert = event.capabilities == 0,
        }
    }
    try std.testing.expect(late_named and late_inert);
    try std.testing.expectEqual(@as(usize, 2), seat.resourceCount());
    try server.ackGlobalRemove(client, registry, advertised.name);
    try std.testing.expect(seat.globalFinalized());
    try std.testing.expectEqual(@as(usize, 1), lifecycle.finalizations);
    try client.destroyResource(first);
    try client.destroyResource(late);
    try std.testing.expectEqualSlices(usize, &.{ 1, 2, 1, 0 }, lifecycle.counts[0..lifecycle.count_len]);
    seat.clearLifecycleListener();
    seat.deinit();
}

const CursorTestContext = struct {
    calls: usize = 0,
    serial: u32 = 0,
};

fn captureCursor(context: *anyopaque, intent: CursorIntent) !void {
    const capture: *CursorTestContext = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.serial = intent.serial;
}

test "native seat binds child resources and routes focused input" {
    const core = @import("wayring-core");
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var compositor: CompositorGlobal = undefined;
    try compositor.init(std.testing.allocator, &server);
    defer compositor.deinit();
    var cursor_capture: CursorTestContext = .{};
    var seat: SeatGlobal = undefined;
    try seat.init(
        std.testing.allocator,
        &server,
        "default",
        Capability.pointer | Capability.keyboard | Capability.touch,
        .{ .context = &cursor_capture, .handle = captureCursor },
    );
    defer seat.deinit();
    const client = try server.createClient();
    defer server.destroyClient(client) catch unreachable;

    var peer = wayring.Connection.init(
        std.testing.allocator,
        .client,
        wayring.default_max_frame_size,
    );
    defer peer.deinit();
    _ = try core.bootstrapDisplay(&peer);
    const registry: wayring.ObjectHandle = .{
        .id = 2,
        .generation = try core.getRegistry(&peer, 2),
    };
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    var compositor_name: u32 = 0;
    var seat_name: u32 = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const event = try core.decodeRegistryEvent(&message, registry.id);
        if (event != .global) continue;
        if (std.mem.eql(u8, event.global.interface, generated.wl_compositor.name))
            compositor_name = event.global.name;
        if (std.mem.eql(u8, event.global.interface, generated.wl_seat.name))
            seat_name = event.global.name;
    }
    const compositor_resource: wayring.ObjectHandle = .{
        .id = 3,
        .generation = try core.bind(
            &peer,
            registry.id,
            compositor_name,
            generated.wl_compositor.name,
            6,
            3,
            &generated.wl_compositor,
        ),
    };
    const seat_resource: wayring.ObjectHandle = .{
        .id = 4,
        .generation = try core.bind(
            &peer,
            registry.id,
            seat_name,
            generated.wl_seat.name,
            7,
            4,
            &generated.wl_seat,
        ),
    };
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    var got_capabilities = false;
    var got_name = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        switch (try generated.wl_seat_types.decodeEvent(&peer, seat_resource, &message)) {
            .capabilities => |event| got_capabilities = event.capabilities ==
                Capability.pointer | Capability.keyboard | Capability.touch,
            .name => |event| got_name = std.mem.eql(u8, event.name, "default"),
        }
    }
    try std.testing.expect(got_capabilities);
    try std.testing.expect(got_name);

    const keymap_fd = try std.posix.memfd_create("keywork-native-seat-keymap", linux.MFD.CLOEXEC);
    try seat.keyboardKeymap(
        @intFromEnum(generated.wl_keyboard_types.keymap_format.xkb_v1),
        keymap_fd,
        4,
    );
    try seat.keyboardRepeatInfo(25, 600);
    const surface_handle = try generated.wl_compositor_types.requests.create_surface(
        &peer,
        compositor_resource,
    );
    const cursor_surface = try generated.wl_compositor_types.requests.create_surface(
        &peer,
        compositor_resource,
    );
    const pointer = try generated.wl_seat_types.requests.get_pointer(&peer, seat_resource);
    const keyboard = try generated.wl_seat_types.requests.get_keyboard(&peer, seat_resource);
    const touch = try generated.wl_seat_types.requests.get_touch(&peer, seat_resource);
    try transferToServer(&peer, client);
    try std.testing.expectEqual(
        @as(u32, 7),
        try client.resourceVersion(seat.children.items[0].resource, &generated.wl_pointer),
    );
    const surface = try CompositorGlobal.surfaceFor(client, .{
        .id = surface_handle.id,
        .generation = client.connection.object(surface_handle.id).?.generation,
    });
    const pointer_serial = try seat.pointerEnter(surface, 3 * 256, 4 * 256);
    try std.testing.expect(seat.acceptsActivationSerial(
        client,
        seat_resource.id,
        pointer_serial,
    ));
    try std.testing.expect(!seat.acceptsActivationSerial(
        client,
        seat_resource.id,
        pointer_serial +% 1,
    ));
    try std.testing.expect(seat.activationSurfaceFocused(surface));
    _ = try seat.pointerMotion(11, 5 * 256, 6 * 256);
    _ = try seat.pointerButton(
        12,
        0x110,
        @intFromEnum(generated.wl_pointer_types.button_state.pressed),
    );
    _ = try seat.keyboardEnter(surface, &.{});
    _ = try seat.keyboardKey(
        13,
        30,
        @intFromEnum(generated.wl_keyboard_types.key_state.pressed),
    );
    try generated.wl_pointer_types.requests.set_cursor(
        &peer,
        pointer,
        pointer_serial - 1,
        cursor_surface,
        1,
        2,
    );
    try generated.wl_pointer_types.requests.set_cursor(
        &peer,
        pointer,
        pointer_serial,
        cursor_surface,
        3,
        4,
    );
    try transferToServer(&peer, client);
    try std.testing.expectEqual(@as(usize, 1), cursor_capture.calls);
    try std.testing.expectEqual(pointer_serial, cursor_capture.serial);
    try transferFromServer(&peer, client);

    var pointer_events: usize = 0;
    var keyboard_events: usize = 0;
    var got_keymap = false;
    var got_repeat = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == pointer.id) {
            _ = try generated.wl_pointer_types.decodeEvent(&peer, pointer, &message);
            pointer_events += 1;
        } else if (message.object_id == keyboard.id) {
            switch (try generated.wl_keyboard_types.decodeEvent(&peer, keyboard, &message)) {
                .keymap => |event| {
                    const fd = try message.takeFd(event.fd);
                    defer _ = linux.close(fd);
                    got_keymap = event.format ==
                        @intFromEnum(generated.wl_keyboard_types.keymap_format.xkb_v1) and
                        event.size == 4;
                },
                .repeat_info => |event| got_repeat = event.rate == 25 and event.delay == 600,
                else => {},
            }
            keyboard_events += 1;
        } else return error.UnexpectedSeatEvent;
    }
    try std.testing.expectEqual(@as(usize, 4), pointer_events);
    try std.testing.expectEqual(@as(usize, 4), keyboard_events);
    try std.testing.expect(got_keymap);
    try std.testing.expect(got_repeat);
    try std.testing.expect(!try seat.pointerMotion(19, 5 * 256, 6 * 256));
    try transferFromServer(&peer, client);
    try std.testing.expect(peer.popMessage() == null);

    try seat.pointerAxisFrame(.{
        .time_milliseconds = 20,
        .axis = @intFromEnum(generated.wl_pointer_types.axis.vertical_scroll),
        .value = 256,
        .source = @intFromEnum(generated.wl_pointer_types.axis_source.wheel),
        .stopped = true,
        .discrete = 1,
        .value120 = 120,
    });
    try seat.pointerFrame();
    try transferFromServer(&peer, client);
    const PointerEventKind = enum { source, discrete, axis, stop, frame };
    var pointer_order: std.ArrayList(PointerEventKind) = .empty;
    defer pointer_order.deinit(std.testing.allocator);
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id != pointer.id) return error.UnexpectedSeatEvent;
        const kind: PointerEventKind = switch (try generated.wl_pointer_types.decodeEvent(
            &peer,
            pointer,
            &message,
        )) {
            .axis_source => .source,
            .axis_discrete => .discrete,
            .axis => .axis,
            .axis_stop => .stop,
            .frame => .frame,
            else => return error.UnexpectedPointerEvent,
        };
        try pointer_order.append(std.testing.allocator, kind);
    }
    try std.testing.expectEqualSlices(
        PointerEventKind,
        &.{ .source, .discrete, .axis, .stop, .frame },
        pointer_order.items,
    );

    _ = try seat.touchDown(surface, 21, 1, 7 * 256, 8 * 256);
    const late_touch = try generated.wl_seat_types.requests.get_touch(&peer, seat_resource);
    try transferToServer(&peer, client);
    try seat.touchMotion(22, 1, 9 * 256, 10 * 256);
    _ = try seat.touchUp(23, 1);
    seat.touchFinish();
    _ = try seat.touchDown(surface, 24, 2, 11 * 256, 12 * 256);
    try seat.touchFrame();
    try seat.touchMotion(25, 2, 13 * 256, 14 * 256);
    _ = try seat.touchUp(26, 2);
    seat.touchFinish();
    try seat.touchFrame();
    try transferFromServer(&peer, client);
    var touch_events: usize = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == late_touch.id) return error.LateTouchJoinedSequence;
        if (message.object_id != touch.id) return error.UnexpectedSeatEvent;
        _ = try generated.wl_touch_types.decodeEvent(&peer, touch, &message);
        touch_events += 1;
    }
    try std.testing.expectEqual(@as(usize, 8), touch_events);

    const late_pointer = try generated.wl_seat_types.requests.get_pointer(&peer, seat_resource);
    const late_keyboard = try generated.wl_seat_types.requests.get_keyboard(&peer, seat_resource);
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    var late_pointer_enter = false;
    var late_pointer_frame = false;
    var late_keyboard_keymap = false;
    var late_keyboard_repeat = false;
    var late_keyboard_enter = false;
    var late_keyboard_modifiers = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == late_pointer.id) {
            switch (try generated.wl_pointer_types.decodeEvent(&peer, late_pointer, &message)) {
                .enter => late_pointer_enter = true,
                .frame => late_pointer_frame = true,
                else => return error.UnexpectedPointerEvent,
            }
        } else if (message.object_id == late_keyboard.id) {
            switch (try generated.wl_keyboard_types.decodeEvent(&peer, late_keyboard, &message)) {
                .keymap => |event| {
                    const fd = try message.takeFd(event.fd);
                    defer _ = linux.close(fd);
                    late_keyboard_keymap = true;
                },
                .repeat_info => late_keyboard_repeat = true,
                .enter => |event| {
                    late_keyboard_enter = event.keys.len == @sizeOf(u32) and
                        std.mem.readInt(u32, event.keys[0..@sizeOf(u32)], .native) == 30;
                },
                .modifiers => late_keyboard_modifiers = true,
                else => return error.UnexpectedKeyboardEvent,
            }
        } else return error.UnexpectedSeatEvent;
    }
    try std.testing.expect(late_pointer_enter);
    try std.testing.expect(late_pointer_frame);
    try std.testing.expect(late_keyboard_keymap);
    try std.testing.expect(late_keyboard_repeat);
    try std.testing.expect(late_keyboard_enter);
    try std.testing.expect(late_keyboard_modifiers);

    try seat.setCapabilities(0);
    try transferFromServer(&peer, client);
    while (peer.popMessage()) |popped| {
        var message = popped;
        message.deinit();
    }
    const absent_pointer = try generated.wl_seat_types.requests.get_pointer(&peer, seat_resource);
    const absent_keyboard = try generated.wl_seat_types.requests.get_keyboard(&peer, seat_resource);
    const absent_touch = try generated.wl_seat_types.requests.get_touch(&peer, seat_resource);
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    try std.testing.expect(peer.popMessage() == null);

    try seat.setCapabilities(Capability.pointer | Capability.keyboard | Capability.touch);
    try transferFromServer(&peer, client);
    while (peer.popMessage()) |popped| {
        var message = popped;
        message.deinit();
    }
    const current_pointer = try generated.wl_seat_types.requests.get_pointer(&peer, seat_resource);
    const current_keyboard = try generated.wl_seat_types.requests.get_keyboard(&peer, seat_resource);
    const current_touch = try generated.wl_seat_types.requests.get_touch(&peer, seat_resource);
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id != current_keyboard.id) return error.StaleCapabilityResourceActive;
        switch (try generated.wl_keyboard_types.decodeEvent(&peer, current_keyboard, &message)) {
            .keymap => |event| {
                const fd = try message.takeFd(event.fd);
                defer _ = linux.close(fd);
            },
            .repeat_info => {},
            else => return error.UnexpectedKeyboardEvent,
        }
    }

    _ = try seat.pointerEnter(surface, 2 * 256, 3 * 256);
    _ = try seat.keyboardEnter(surface, &.{44});
    _ = try seat.touchDown(surface, 30, 2, 4 * 256, 5 * 256);
    try seat.touchFrame();
    try transferFromServer(&peer, client);
    var current_pointer_events: usize = 0;
    var current_keyboard_events: usize = 0;
    var current_touch_events: usize = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == current_pointer.id) {
            _ = try generated.wl_pointer_types.decodeEvent(&peer, current_pointer, &message);
            current_pointer_events += 1;
        } else if (message.object_id == current_keyboard.id) {
            _ = try generated.wl_keyboard_types.decodeEvent(&peer, current_keyboard, &message);
            current_keyboard_events += 1;
        } else if (message.object_id == current_touch.id) {
            _ = try generated.wl_touch_types.decodeEvent(&peer, current_touch, &message);
            current_touch_events += 1;
        } else if (message.object_id == pointer.id or
            message.object_id == keyboard.id or
            message.object_id == touch.id or
            message.object_id == late_pointer.id or
            message.object_id == late_keyboard.id or
            message.object_id == late_touch.id or
            message.object_id == absent_pointer.id or
            message.object_id == absent_keyboard.id or
            message.object_id == absent_touch.id)
        {
            return error.StaleCapabilityResourceActive;
        } else return error.UnexpectedSeatEvent;
    }
    try std.testing.expectEqual(@as(usize, 2), current_pointer_events);
    try std.testing.expectEqual(@as(usize, 1), current_keyboard_events);
    try std.testing.expectEqual(@as(usize, 2), current_touch_events);

    _ = try seat.touchUp(31, 2);
    seat.touchFinish();
    try seat.touchFrame();
    try transferFromServer(&peer, client);
    while (peer.popMessage()) |popped| {
        var message = popped;
        message.deinit();
    }
}

fn transferToServer(connection: *wayring.Connection, client: *Server.Client) !void {
    while (connection.nextBatch()) |batch| {
        try client.receive(batch.bytes, batch.fds);
        try connection.acknowledge(batch.token, batch.bytes.len);
    }
}

fn transferFromServer(connection: *wayring.Connection, client: *Server.Client) !void {
    while (client.connection.nextBatch()) |batch| {
        try connection.feed(batch.bytes, batch.fds);
        try client.connection.acknowledge(batch.token, batch.bytes.len);
    }
    try client.outputDrained();
}
