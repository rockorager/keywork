//! Frontend-neutral seat state and synchronous input-delivery boundary.
//!
//! The mature seat owns this value and all canonical input policy. Frontend
//! adapters may keep resource-local protocol bookkeeping, but callbacks never
//! receive frontend resources or acquire independent focus, grab, or authority
//! state.

const SeatDelivery = @This();

const std = @import("std");
const ClientRegistry = @import("ClientRegistry.zig");
const SurfaceRegistry = @import("SurfaceRegistry.zig");
const render = @import("render/types.zig");

pub const ResourceGeneration = u64;

pub const CursorRoleResult = enum { assigned, already_cursor, role_conflict, not_live, wrong_client };
pub const CursorRequestResult = enum { accepted, ignored, role_conflict, unavailable };
pub const ShapeRequest = struct {
    client: ClientRegistry.Id,
    resource_generation: ResourceGeneration,
    capability_generation: ResourceGeneration,
    serial: ClientRegistry.Serial,
    image: CursorImage,
};
pub const CursorImage = struct {
    buffer: render.PixelBuffer,
    hotspot_x: i32,
    hotspot_y: i32,
};
pub const CursorRequest = struct {
    client: ClientRegistry.Id,
    resource_generation: ResourceGeneration,
    capability_generation: u64,
    serial: ClientRegistry.Serial,
    surface: ?SurfaceRegistry.Id,
    hotspot_x: i32,
    hotspot_y: i32,
};

/// Existing canonical pointer-enter state that a newly materialized generated
/// pointer resource may join without synthesizing a second logical enter.
pub const PointerEnterSnapshot = struct {
    surface: SurfaceRegistry.Id,
    serial: ClientRegistry.Serial,
    x: i32,
    y: i32,
};

/// Existing canonical keyboard state used to initialize one newly
/// materialized generated resource without creating another focus transition
/// or authority grant. Every slice and descriptor is borrowed synchronously.
pub const KeyboardResourceSnapshot = struct {
    keymap: KeymapSnapshot,
    repeat_info: RepeatInfo,
    focus: ?KeyboardFocusSnapshot,
};

pub const KeyboardFocusSnapshot = struct {
    surface: SurfaceRegistry.Id,
    serial: ClientRegistry.Serial,
    pressed_keys: []const u32,
    modifiers: Modifiers,
};

/// Canonical request boundary copied by a generated frontend adapter.
pub const RequestSink = struct {
    context: *anyopaque,
    pointer_enter_snapshot: *const fn (*anyopaque, ClientRegistry.Id, ResourceGeneration) ?PointerEnterSnapshot = unavailablePointerEnterSnapshot,
    keyboard_resource_snapshot: *const fn (*anyopaque, ClientRegistry.Id, ResourceGeneration) ?KeyboardResourceSnapshot = unavailableKeyboardResourceSnapshot,
    accepts_pointer_grab: *const fn (
        *anyopaque,
        ClientRegistry.Id,
        ClientRegistry.Serial,
        SurfaceRegistry.Id,
    ) bool = rejectsPointerGrab,
    accepts_action: *const fn (
        *anyopaque,
        ClientRegistry.Id,
        ClientRegistry.Serial,
    ) bool = rejectsAction,
    accepts_activation: *const fn (
        *anyopaque,
        ClientRegistry.Id,
        ClientRegistry.Serial,
    ) bool = rejectsAction,
    activation_surface_focused: *const fn (*anyopaque, SurfaceRegistry.Id) bool = rejectsFocused,
    set_cursor: *const fn (*anyopaque, CursorRequest) CursorRequestResult,
    set_shape: *const fn (*anyopaque, ShapeRequest) bool = rejectsShape,
    cursor_committed: *const fn (*anyopaque, SurfaceRegistry.Id, i32, i32) void,
    cursor_removed: *const fn (*anyopaque, SurfaceRegistry.Id) void,
    client_retiring: *const fn (*anyopaque, ClientRegistry.Id) void,
};

fn rejectsShape(_: *anyopaque, _: ShapeRequest) bool {
    return false;
}

fn rejectsFocused(_: *anyopaque, _: SurfaceRegistry.Id) bool {
    return false;
}

fn rejectsPointerGrab(
    _: *anyopaque,
    _: ClientRegistry.Id,
    _: ClientRegistry.Serial,
    _: SurfaceRegistry.Id,
) bool {
    return false;
}

fn rejectsAction(_: *anyopaque, _: ClientRegistry.Id, _: ClientRegistry.Serial) bool {
    return false;
}

fn unavailablePointerEnterSnapshot(_: *anyopaque, _: ClientRegistry.Id, _: ResourceGeneration) ?PointerEnterSnapshot {
    return null;
}

fn unavailableKeyboardResourceSnapshot(_: *anyopaque, _: ClientRegistry.Id, _: ResourceGeneration) ?KeyboardResourceSnapshot {
    return null;
}

pub const Capability = struct {
    available: bool = false,
    ever_available: bool = false,
    generation: u64 = 0,

    /// Returns whether the effective capability changed. Every unavailable to
    /// available transition starts a new generation; removal retains it so
    /// resources from an earlier generation can never revive.
    pub fn setAvailable(self: *Capability, available: bool) bool {
        if (self.available == available) return false;
        self.available = available;
        if (available) {
            self.generation = std.math.add(u64, self.generation, 1) catch unreachable;
            self.ever_available = true;
        }
        return true;
    }

    pub fn resourceActive(self: Capability, generation: u64) bool {
        return self.available and generation == self.generation;
    }
};

pub const CapabilityKind = enum {
    keyboard,
    pointer,
    touch,
};

pub const CapabilitySnapshot = struct {
    keyboard: Capability = .{},
    pointer: Capability = .{},
    touch: Capability = .{},

    pub fn get(self: CapabilitySnapshot, kind: CapabilityKind) Capability {
        return switch (kind) {
            .keyboard => self.keyboard,
            .pointer => self.pointer,
            .touch => self.touch,
        };
    }
};

/// The keymap descriptor and pressed-key slice in Snapshot are borrowed until
/// the next canonical seat mutation. The keymap file descriptor is borrowed
/// only for synchronous duplication or event delivery.
pub const Snapshot = struct {
    capabilities: CapabilitySnapshot,
    keymap: ?KeymapSnapshot,
    repeat_info: RepeatInfo,
    modifiers: Modifiers,
    pressed_keys: []const u32,
};

pub const KeymapSnapshot = struct {
    format: u32,
    fd: std.posix.fd_t,
    size: u32,
};

pub const RepeatInfo = struct {
    rate: i32 = 0,
    delay: i32 = 0,
};

pub const Modifiers = struct {
    depressed: u32 = 0,
    latched: u32 = 0,
    locked: u32 = 0,
    group: u32 = 0,
};

pub const KeyState = enum(u32) {
    released = 0,
    pressed = 1,
    repeated = 2,
};

pub const ButtonState = enum(u32) {
    released = 0,
    pressed = 1,
};

pub const TerminalReason = enum {
    pointer_state_out_of_memory,
};

pub const KeyboardStateEvent = union(enum) {
    keymap: ?KeymapSnapshot,
    repeat_info: RepeatInfo,
};

pub const KeyboardEvent = union(enum) {
    enter: struct {
        serial: ClientRegistry.Serial,
        pressed_keys: []const u32,
        modifiers: Modifiers,
    },
    leave: struct { serial: u32 },
    key: struct {
        serial: ClientRegistry.Serial,
        time: u32,
        key: u32,
        state: KeyState,
    },
    modifiers: struct {
        serial: u32,
        state: Modifiers,
    },
};

pub const PointerEvent = union(enum) {
    enter: struct {
        serial: ClientRegistry.Serial,
        x: i32,
        y: i32,
    },
    leave: struct { serial: u32 },
    motion: struct {
        time: u32,
        x: i32,
        y: i32,
    },
    button: struct {
        serial: ClientRegistry.Serial,
        time: u32,
        button: u32,
        state: ButtonState,
    },
    axis: struct {
        time: u32,
        axis: u32,
        value: i32,
    },
    frame,
    axis_source: u32,
    axis_stop: struct {
        time: u32,
        axis: u32,
    },
    axis_discrete: struct {
        axis: u32,
        discrete: i32,
    },
    axis_value120: struct {
        axis: u32,
        value120: i32,
    },
    axis_relative_direction: struct {
        axis: u32,
        direction: u32,
    },
};

/// The generated adapter captures this cutoff synchronously at touch-down.
/// Later resources have larger resource generations and cannot join the
/// existing contact sequence.
pub const TouchTarget = struct {
    client: ClientRegistry.Id,
    max_resource_generation: ResourceGeneration,
};

pub const TouchEvent = union(enum) {
    down: struct {
        serial: ClientRegistry.Serial,
        time: u32,
        surface: SurfaceRegistry.Id,
        id: i32,
        x: i32,
        y: i32,
        max_resource_generation: ResourceGeneration,
    },
    up: struct {
        serial: ClientRegistry.Serial,
        time: u32,
        id: i32,
        max_resource_generation: ResourceGeneration,
    },
    motion: struct {
        time: u32,
        id: i32,
        x: i32,
        y: i32,
        max_resource_generation: ResourceGeneration,
    },
    frame,
    cancel: struct { max_resource_generation: ResourceGeneration },
    shape: struct {
        id: i32,
        major: i32,
        minor: i32,
        max_resource_generation: ResourceGeneration,
    },
    orientation: struct {
        id: i32,
        orientation: i32,
        max_resource_generation: ResourceGeneration,
    },
};

/// Synchronous resource-free frontend adapter. Event callbacks return void:
/// an adapter terminalizes only the generated client whose event queue fails,
/// without rolling canonical input state back or interrupting other clients.
pub const Sink = struct {
    context: *anyopaque,
    owner_for_surface: *const fn (*anyopaque, SurfaceRegistry.Id) ?ClientRegistry.Id,
    surface_accepts_input: *const fn (*anyopaque, SurfaceRegistry.Id, f64, f64) bool,
    issue_serial: *const fn (*anyopaque, ClientRegistry.Id) ?ClientRegistry.Serial,
    terminalize: *const fn (*anyopaque, ClientRegistry.Id, TerminalReason) void,
    touch_target: *const fn (*anyopaque, SurfaceRegistry.Id) ?TouchTarget,
    assign_cursor_role: *const fn (*anyopaque, ClientRegistry.Id, SurfaceRegistry.Id) CursorRoleResult = unavailableCursorRole,
    capabilities: *const fn (*anyopaque, CapabilitySnapshot) void,
    keyboard_state: *const fn (*anyopaque, KeyboardStateEvent) void,
    keyboard: *const fn (*anyopaque, ClientRegistry.Id, SurfaceRegistry.Id, KeyboardEvent) void,
    pointer: *const fn (*anyopaque, ClientRegistry.Id, SurfaceRegistry.Id, PointerEvent) void,
    touch: *const fn (*anyopaque, ClientRegistry.Id, TouchEvent) void,
    touch_frame: *const fn (*anyopaque) void = unavailableTouchFrame,
};

fn unavailableCursorRole(_: *anyopaque, _: ClientRegistry.Id, _: SurfaceRegistry.Id) CursorRoleResult {
    return .not_live;
}

fn unavailableTouchFrame(_: *anyopaque) void {}

capabilities: CapabilitySnapshot = .{},
sink: ?Sink = null,
notifying: bool = false,

pub fn init() SeatDelivery {
    return .{};
}

pub fn deinit(self: *SeatDelivery) void {
    std.debug.assert(self.sink == null);
    std.debug.assert(!self.notifying);
    self.* = undefined;
}

pub fn capabilitySnapshot(self: *const SeatDelivery) CapabilitySnapshot {
    return self.capabilities;
}

pub fn capability(self: *const SeatDelivery, kind: CapabilityKind) Capability {
    return self.capabilities.get(kind);
}

pub fn setCapability(self: *SeatDelivery, kind: CapabilityKind, available: bool) bool {
    std.debug.assert(!self.notifying);
    return switch (kind) {
        .keyboard => self.capabilities.keyboard.setAvailable(available),
        .pointer => self.capabilities.pointer.setAvailable(available),
        .touch => self.capabilities.touch.setAvailable(available),
    };
}

/// Installs one generated-frontend sink and immediately sends the complete
/// canonical capability snapshot. The owner must clear it before teardown.
pub fn setSink(self: *SeatDelivery, sink: Sink) void {
    std.debug.assert(self.sink == null);
    std.debug.assert(!self.notifying);
    self.sink = sink;
    self.notifyCapabilities();
}

pub fn clearSink(self: *SeatDelivery, context: *anyopaque) void {
    std.debug.assert(!self.notifying);
    std.debug.assert(self.sink != null and self.sink.?.context == context);
    self.sink = null;
}

pub fn ownerForSurface(self: *const SeatDelivery, surface: SurfaceRegistry.Id) ?ClientRegistry.Id {
    const sink = self.sink orelse return null;
    return sink.owner_for_surface(sink.context, surface);
}

pub fn surfaceAcceptsInput(
    self: *const SeatDelivery,
    surface: SurfaceRegistry.Id,
    x: f64,
    y: f64,
) bool {
    const sink = self.sink orelse return false;
    return sink.surface_accepts_input(sink.context, surface, x, y);
}

pub fn issueSerial(self: *const SeatDelivery, client: ClientRegistry.Id) ?ClientRegistry.Serial {
    const sink = self.sink orelse return null;
    return sink.issue_serial(sink.context, client);
}

pub fn terminalize(self: *SeatDelivery, client: ClientRegistry.Id, reason: TerminalReason) void {
    const sink = self.sink orelse return;
    self.beginNotify();
    defer self.endNotify();
    sink.terminalize(sink.context, client, reason);
}

pub fn touchTarget(self: *const SeatDelivery, surface: SurfaceRegistry.Id) ?TouchTarget {
    const sink = self.sink orelse return null;
    return sink.touch_target(sink.context, surface);
}

pub fn assignCursorRole(self: *const SeatDelivery, client: ClientRegistry.Id, surface: SurfaceRegistry.Id) CursorRoleResult {
    const sink = self.sink orelse return .not_live;
    return sink.assign_cursor_role(sink.context, client, surface);
}

pub fn notifyCapabilities(self: *SeatDelivery) void {
    const sink = self.sink orelse return;
    self.beginNotify();
    defer self.endNotify();
    sink.capabilities(sink.context, self.capabilities);
}

pub fn notifyKeyboardState(self: *SeatDelivery, event: KeyboardStateEvent) void {
    const sink = self.sink orelse return;
    self.beginNotify();
    defer self.endNotify();
    sink.keyboard_state(sink.context, event);
}

pub fn deliverKeyboard(
    self: *SeatDelivery,
    client: ClientRegistry.Id,
    surface: SurfaceRegistry.Id,
    event: KeyboardEvent,
) void {
    const sink = self.sink orelse return;
    self.beginNotify();
    defer self.endNotify();
    sink.keyboard(sink.context, client, surface, event);
}

pub fn deliverPointer(
    self: *SeatDelivery,
    client: ClientRegistry.Id,
    surface: SurfaceRegistry.Id,
    event: PointerEvent,
) void {
    const sink = self.sink orelse return;
    self.beginNotify();
    defer self.endNotify();
    sink.pointer(sink.context, client, surface, event);
}

pub fn deliverTouch(
    self: *SeatDelivery,
    client: ClientRegistry.Id,
    event: TouchEvent,
) void {
    const sink = self.sink orelse return;
    self.beginNotify();
    defer self.endNotify();
    sink.touch(sink.context, client, event);
}

/// Ends the current canonical touch frame after resource-specific pending
/// state has already been recorded by synchronous touch event delivery.
pub fn deliverTouchFrame(self: *SeatDelivery) void {
    const sink = self.sink orelse return;
    self.beginNotify();
    defer self.endNotify();
    sink.touch_frame(sink.context);
}

pub fn resourceInSequence(generation: ResourceGeneration, max_generation: ResourceGeneration) bool {
    return generation <= max_generation;
}

fn beginNotify(self: *SeatDelivery) void {
    std.debug.assert(!self.notifying);
    self.notifying = true;
}

fn endNotify(self: *SeatDelivery) void {
    std.debug.assert(self.notifying);
    self.notifying = false;
}

test "capability snapshots retain generations and never revive stale resources" {
    var delivery: SeatDelivery = .init();
    defer delivery.deinit();

    try std.testing.expect(delivery.setCapability(.keyboard, true));
    const first = delivery.capability(.keyboard);
    try std.testing.expect(first.available);
    try std.testing.expect(first.ever_available);
    try std.testing.expect(first.resourceActive(first.generation));
    try std.testing.expect(!delivery.setCapability(.keyboard, true));

    try std.testing.expect(delivery.setCapability(.keyboard, false));
    try std.testing.expect(!delivery.capability(.keyboard).resourceActive(first.generation));
    try std.testing.expect(delivery.setCapability(.keyboard, true));
    const second = delivery.capabilitySnapshot().keyboard;
    try std.testing.expect(second.generation > first.generation);
    try std.testing.expect(!second.resourceActive(first.generation));
    try std.testing.expect(second.resourceActive(second.generation));
}

test "sink forwards neutral snapshots identity serial and touch cutoff queries" {
    const Probe = struct {
        client: ClientRegistry.Id,
        surface: SurfaceRegistry.Id,
        serial: ClientRegistry.Serial,
        capability_calls: usize = 0,

        fn owner(context: *anyopaque, surface: SurfaceRegistry.Id) ?ClientRegistry.Id {
            const self: *@This() = @ptrCast(@alignCast(context));
            return if (std.meta.eql(self.surface, surface)) self.client else null;
        }

        fn acceptsInput(
            context: *anyopaque,
            surface: SurfaceRegistry.Id,
            x: f64,
            y: f64,
        ) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            return std.meta.eql(self.surface, surface) and x == 2 and y == 3;
        }

        fn issue(context: *anyopaque, client: ClientRegistry.Id) ?ClientRegistry.Serial {
            const self: *@This() = @ptrCast(@alignCast(context));
            return if (std.meta.eql(self.client, client)) self.serial else null;
        }

        fn terminalize(_: *anyopaque, _: ClientRegistry.Id, _: TerminalReason) void {}

        fn target(context: *anyopaque, surface: SurfaceRegistry.Id) ?TouchTarget {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (!std.meta.eql(self.surface, surface)) return null;
            return .{ .client = self.client, .max_resource_generation = 7 };
        }

        fn capabilities(context: *anyopaque, snapshot: CapabilitySnapshot) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            std.debug.assert(snapshot.touch.available);
            self.capability_calls += 1;
        }

        fn keyboardState(_: *anyopaque, _: KeyboardStateEvent) void {}
        fn keyboard(_: *anyopaque, _: ClientRegistry.Id, _: SurfaceRegistry.Id, _: KeyboardEvent) void {}
        fn pointer(_: *anyopaque, _: ClientRegistry.Id, _: SurfaceRegistry.Id, _: PointerEvent) void {}
        fn touch(_: *anyopaque, _: ClientRegistry.Id, _: TouchEvent) void {}
    };

    const client: ClientRegistry.Id = .{ .index = 1, .generation = 2 };
    const surface: SurfaceRegistry.Id = .{ .index = 3, .generation = 4 };
    const serial: ClientRegistry.Serial = .{ .domain = .wayring_server, .value = 5 };
    var probe: Probe = .{ .client = client, .surface = surface, .serial = serial };
    var delivery: SeatDelivery = .init();
    try std.testing.expect(delivery.setCapability(.touch, true));
    delivery.setSink(.{
        .context = &probe,
        .owner_for_surface = Probe.owner,
        .surface_accepts_input = Probe.acceptsInput,
        .issue_serial = Probe.issue,
        .terminalize = Probe.terminalize,
        .touch_target = Probe.target,
        .capabilities = Probe.capabilities,
        .keyboard_state = Probe.keyboardState,
        .keyboard = Probe.keyboard,
        .pointer = Probe.pointer,
        .touch = Probe.touch,
    });
    defer {
        delivery.clearSink(&probe);
        delivery.deinit();
    }

    try std.testing.expectEqual(@as(usize, 1), probe.capability_calls);
    try std.testing.expect(std.meta.eql(client, delivery.ownerForSurface(surface).?));
    try std.testing.expect(delivery.surfaceAcceptsInput(surface, 2, 3));
    try std.testing.expect(!delivery.surfaceAcceptsInput(surface, 3, 2));
    try std.testing.expect(std.meta.eql(serial, delivery.issueSerial(client).?));
    const target_value = delivery.touchTarget(surface).?;
    try std.testing.expect(std.meta.eql(client, target_value.client));
    try std.testing.expectEqual(@as(ResourceGeneration, 7), target_value.max_resource_generation);
    try std.testing.expect(resourceInSequence(7, target_value.max_resource_generation));
    try std.testing.expect(!resourceInSequence(8, target_value.max_resource_generation));
}
