//! Wayland seat global, input resources, and capability boundary.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const render = @import("../render/types.zig");
const PressedKeyState = @import("PressedKeyState.zig");
const Surface = @import("surface.zig");
const UserActionSerials = @import("UserActionSerials.zig");

const wl = wayland.server.wl;

allocator: std.mem.Allocator,
io: std.Io,
display: *wl.Server,
global: *wl.Global,
global_removed: bool,
name_value: [:0]const u8,
surface_store: *Surface.Store,
seat_resources: std.ArrayList(*wl.Seat),
seat_resource_listener: ?SeatResourceListener,
keyboard_resources: std.ArrayList(KeyboardResource),
pointer_resources: std.ArrayList(PointerResource),
touch_resources: std.ArrayList(TouchResource),
next_pointer_resource_generation: u64,
next_touch_resource_generation: u64,
// Input objects created before a capability is re-added must remain inert.
keyboard_capability_generation: u64,
pointer_capability_generation: u64,
touch_capability_generation: u64,
keyboard_ever_available: bool,
pointer_ever_available: bool,
touch_ever_available: bool,
keyboard_available: bool,
virtual_keyboard_count: usize,
pointer_available: bool,
virtual_pointer_count: usize,
touch_available: bool,
keymap: ?Keymap,
repeat_info: RepeatInfo,
keyboard_grab: ?KeyboardGrab,
repaint_listener: ?RepaintListener,
keyboard_focus_listeners: std.ArrayList(KeyboardFocusListener),
parent_focused: bool,
focus: ?Surface.Id,
pointer_focus: ?PointerFocus,
pointer_position: ?PointerPosition,
touch_points: std.ArrayList(TouchPoint),
touch_frame_resources: std.ArrayList(*wl.Touch),
latest_pointer_enter: ?UserAction,
active_cursor: ?ActiveCursor,
// Distinguishes a pending cursor choice after enter from explicit set_cursor(null).
pointer_cursor_configured: bool,
compositor_cursor: ?CursorImage,
default_cursor: ?CursorImage,
cursor_controller: ?CursorController,
drag_cursor_client: ?*wl.Client,
cursor_surface_count: usize,
pointer_grab: ?PointerGrab,
pressed_pointer_buttons: std.ArrayList(PressedPointerButton),
pressed_keys: PressedKeyState,
grabbed_keys: std.ArrayList(GrabbedKey),
modifier_state: ModifierState,
user_action_serials: UserActionSerials,

const Keymap = struct {
    format: wl.Keyboard.KeymapFormat,
    file: std.Io.File,
    size: u32,
};

const RepeatInfo = struct {
    rate: i32 = 0,
    delay: i32 = 0,
};

const Modifiers = struct {
    depressed: u32 = 0,
    latched: u32 = 0,
    locked: u32 = 0,
    group: u32 = 0,
};

const ModifierState = struct {
    current: Modifiers = .{},
    physical: Modifiers = .{},
    virtual_owner: ?*anyopaque = null,

    fn setPhysical(self: *ModifierState, modifiers: Modifiers) void {
        self.current = modifiers;
        self.physical = modifiers;
        self.virtual_owner = null;
    }

    fn setVirtual(self: *ModifierState, owner: *anyopaque, modifiers: Modifiers) void {
        self.current = modifiers;
        self.virtual_owner = owner;
    }

    fn clearVirtual(self: *ModifierState, owner: *anyopaque) bool {
        if (self.virtual_owner != owner) return false;
        self.current = self.physical;
        self.virtual_owner = null;
        return true;
    }
};

const GrabbedKey = struct {
    key: u32,
    token: u64,
};

const UserAction = struct {
    client: *wl.Client,
    serial: u32,
};

const PointerPosition = struct {
    x: f64,
    y: f64,
};

const TouchPoint = struct {
    id: i32,
    target: ?Target,

    const Target = struct {
        surface_id: Surface.Id,
        client: *wl.Client,
        offset_x: f64,
        offset_y: f64,
        max_resource_generation: u64,
    };
};

const TouchCancellation = struct {
    client: *wl.Client,
    max_resource_generation: u64,
};

const TouchResource = struct {
    resource: *wl.Touch,
    generation: u64,
    capability_generation: u64,
};

const KeyboardResource = struct {
    resource: *wl.Keyboard,
    capability_generation: u64,
};

const PointerResource = struct {
    resource: *wl.Pointer,
    generation: u64,
    capability_generation: u64,
    enter_serial: ?u32,
};

const PressedPointerButton = struct {
    button: u32,
    client: *wl.Client,
    surface_id: Surface.Id,
    serial: u32,
};

const PointerGrab = struct {
    surface_id: Surface.Id,
    suppressed: bool = false,
};

const SurfaceCursor = struct {
    surface_id: Surface.Id,
    hotspot_x: i32,
    hotspot_y: i32,
};

const ActiveCursor = union(enum) {
    surface: SurfaceCursor,
    shape: ShapeCursor,
};

const CursorController = struct {
    client: *wl.Client,
    cursor: ?ActiveCursor,
    configured: bool,
};

pub const PointerFocus = struct {
    surface_id: Surface.Id,
    x: f64,
    y: f64,
};

pub const PointerHandle = struct {
    resource: *wl.Pointer,
    generation: u64,
};

pub const PointerBinding = struct {
    seat: *Self,
    generation: u64,

    pub fn isActive(self: PointerBinding) bool {
        for (self.seat.pointer_resources.items) |entry| {
            if (entry.generation == self.generation) {
                return self.seat.pointerResourceActive(entry);
            }
        }
        return false;
    }
};

pub const ShapeCursor = struct {
    client: *wl.Client,
    buffer: render.PixelBuffer,
    hotspot_x: i32,
    hotspot_y: i32,
};

pub const CursorImage = struct {
    buffer: render.PixelBuffer,
    hotspot_x: i32,
    hotspot_y: i32,
};

pub const CursorInfo = union(enum) {
    surface: struct {
        surface_id: Surface.Id,
        x: i32,
        y: i32,
    },
    shape: struct {
        buffer: render.PixelBuffer,
        x: i32,
        y: i32,
    },
};

pub const RepaintListener = struct {
    context: *anyopaque,
    request: *const fn (*anyopaque) void,
    cursor_changed: *const fn (*anyopaque, ?CursorInfo, ?CursorInfo) void,
};

pub const KeyboardFocusListener = struct {
    context: *anyopaque,
    changed: *const fn (*anyopaque, ?*wl.Client) void,
};

pub const SeatResourceListener = struct {
    context: *anyopaque,
    changed: *const fn (*anyopaque, usize) void,
};

pub const KeyboardGrab = struct {
    context: *anyopaque,
    token: u64,
    surface: ?Surface.Id = null,
    cancel: *const fn (*anyopaque) void,
    keymap: *const fn (*anyopaque, wl.Keyboard.KeymapFormat, std.posix.fd_t, u32) void,
    key: *const fn (*anyopaque, u32, u32, u32, wl.Keyboard.KeyState) void,
    modifiers: *const fn (*anyopaque, u32, u32, u32, u32) void,
    repeat_info: *const fn (*anyopaque, i32, i32) void,
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    io: std.Io,
    display: *wl.Server,
    seat_name: [:0]const u8,
    surface_store: *Surface.Store,
) !void {
    self.* = .{
        .allocator = allocator,
        .io = io,
        .display = display,
        .global = undefined,
        .global_removed = false,
        .name_value = seat_name,
        .surface_store = surface_store,
        .seat_resources = .empty,
        .seat_resource_listener = null,
        .keyboard_resources = .empty,
        .pointer_resources = .empty,
        .touch_resources = .empty,
        .next_pointer_resource_generation = 0,
        .next_touch_resource_generation = 0,
        .keyboard_capability_generation = 0,
        .pointer_capability_generation = 0,
        .touch_capability_generation = 0,
        .keyboard_ever_available = false,
        .pointer_ever_available = false,
        .touch_ever_available = false,
        .keyboard_available = false,
        .virtual_keyboard_count = 0,
        .pointer_available = false,
        .virtual_pointer_count = 0,
        .touch_available = false,
        .keymap = null,
        .repeat_info = .{},
        .keyboard_grab = null,
        .repaint_listener = null,
        .keyboard_focus_listeners = .empty,
        .parent_focused = false,
        .focus = null,
        .pointer_focus = null,
        .pointer_position = null,
        .touch_points = .empty,
        .touch_frame_resources = .empty,
        .latest_pointer_enter = null,
        .active_cursor = null,
        .pointer_cursor_configured = false,
        .compositor_cursor = null,
        .default_cursor = null,
        .cursor_controller = null,
        .drag_cursor_client = null,
        .cursor_surface_count = 0,
        .pointer_grab = null,
        .pressed_pointer_buttons = .empty,
        .pressed_keys = .init(allocator),
        .grabbed_keys = .empty,
        .modifier_state = .{},
        .user_action_serials = .{},
    };
    errdefer self.seat_resources.deinit(allocator);
    errdefer self.keyboard_resources.deinit(allocator);
    errdefer self.pointer_resources.deinit(allocator);
    errdefer self.touch_resources.deinit(allocator);
    errdefer self.touch_points.deinit(allocator);
    errdefer self.touch_frame_resources.deinit(allocator);
    errdefer self.pressed_pointer_buttons.deinit(allocator);
    errdefer self.pressed_keys.deinit();
    errdefer self.grabbed_keys.deinit(allocator);
    errdefer self.keyboard_focus_listeners.deinit(allocator);
    self.global = try wl.Global.create(display, wl.Seat, 10, *Self, self, bind);
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.seat_resources.items.len == 0);
    std.debug.assert(self.keyboard_resources.items.len == 0);
    std.debug.assert(self.pointer_resources.items.len == 0);
    std.debug.assert(self.touch_resources.items.len == 0);
    std.debug.assert(self.cursor_surface_count == 0);
    std.debug.assert(self.virtual_keyboard_count == 0);
    std.debug.assert(self.virtual_pointer_count == 0);
    std.debug.assert(self.keyboard_grab == null);
    std.debug.assert(self.repaint_listener == null);
    std.debug.assert(self.keyboard_focus_listeners.items.len == 0);
    std.debug.assert(self.seat_resource_listener == null);
    self.global.destroy();
    if (self.keymap) |keymap| keymap.file.close(self.io);
    self.keyboard_focus_listeners.deinit(self.allocator);
    self.grabbed_keys.deinit(self.allocator);
    self.pressed_keys.deinit();
    self.pressed_pointer_buttons.deinit(self.allocator);
    self.touch_frame_resources.deinit(self.allocator);
    self.touch_points.deinit(self.allocator);
    self.touch_resources.deinit(self.allocator);
    self.pointer_resources.deinit(self.allocator);
    self.keyboard_resources.deinit(self.allocator);
    self.seat_resources.deinit(self.allocator);
    self.* = undefined;
}

pub fn globalName(self: *const Self, client: *const wl.Client) u32 {
    std.debug.assert(!self.global_removed);
    return self.global.getName(client);
}

/// Stop advertising this seat while keeping existing client resources alive.
pub fn removeGlobal(self: *Self) void {
    std.debug.assert(!self.global_removed);
    self.global.remove();
    self.global_removed = true;
}

pub fn name(self: *const Self) [:0]const u8 {
    return self.name_value;
}

pub fn ownsResource(self: *Self, resource: *wl.Seat) bool {
    return resource.getUserData() == @as(?*anyopaque, @ptrCast(self));
}

pub fn fromResource(resource: *wl.Seat) *Self {
    const data = resource.getUserData() orelse unreachable;
    return @ptrCast(@alignCast(data));
}

/// Copies the listener and retains its context until clearSeatResourceListener.
pub fn setSeatResourceListener(self: *Self, listener: SeatResourceListener) void {
    std.debug.assert(self.seat_resource_listener == null);
    self.seat_resource_listener = listener;
}

pub fn clearSeatResourceListener(self: *Self) void {
    std.debug.assert(self.seat_resource_listener != null);
    self.seat_resource_listener = null;
}

pub fn pointerBinding(resource: *wl.Pointer) ?PointerBinding {
    const data = resource.getUserData() orelse return null;
    const self: *Self = @ptrCast(@alignCast(data));
    const handle = self.pointerHandle(resource) orelse return null;
    if (!self.pointerHandleIsActive(handle)) return null;
    return .{ .seat = self, .generation = handle.generation };
}

pub fn pointerHandle(self: *const Self, resource: *wl.Pointer) ?PointerHandle {
    for (self.pointer_resources.items) |entry| {
        if (entry.resource == resource) return .{
            .resource = resource,
            .generation = entry.generation,
        };
    }
    return null;
}

pub fn pointerHandleIsActive(self: *const Self, handle: PointerHandle) bool {
    for (self.pointer_resources.items) |entry| {
        if (entry.resource == handle.resource and entry.generation == handle.generation) {
            return self.pointerResourceActive(entry);
        }
    }
    return false;
}

pub fn acceptsPointerEnterSerial(
    self: *const Self,
    handle: PointerHandle,
    surface_id: Surface.Id,
    serial: u32,
) bool {
    const focus = self.pointer_focus orelse return false;
    if (!std.meta.eql(focus.surface_id, surface_id)) return false;
    const surface = Surface.resourceFor(self.surface_store, surface_id) orelse return false;
    for (self.pointer_resources.items) |entry| {
        if (entry.resource != handle.resource or entry.generation != handle.generation) continue;
        if (!self.pointerResourceActive(entry)) return false;
        if (entry.resource.getClient() != surface.getClient()) return false;
        return entry.enter_serial == serial;
    }
    return false;
}

/// Copies the listener and retains its context until clearRepaintListener.
pub fn setRepaintListener(self: *Self, listener: RepaintListener) void {
    std.debug.assert(self.repaint_listener == null);
    self.repaint_listener = listener;
}

pub fn clearRepaintListener(self: *Self) void {
    std.debug.assert(self.repaint_listener != null);
    self.repaint_listener = null;
}

/// Copies the listener and retains its context until removeKeyboardFocusListener.
pub fn addKeyboardFocusListener(
    self: *Self,
    listener: KeyboardFocusListener,
) error{OutOfMemory}!void {
    for (self.keyboard_focus_listeners.items) |existing| {
        std.debug.assert(existing.context != listener.context);
    }
    try self.keyboard_focus_listeners.append(self.allocator, listener);
}

pub fn removeKeyboardFocusListener(self: *Self, context: *anyopaque) void {
    for (self.keyboard_focus_listeners.items, 0..) |listener, index| {
        if (listener.context != context) continue;
        _ = self.keyboard_focus_listeners.orderedRemove(index);
        return;
    }
    unreachable;
}

pub fn setKeyboardGrab(self: *Self, grab: KeyboardGrab) void {
    if (self.keyboard_grab) |active| {
        active.cancel(active.context);
    }
    std.debug.assert(self.installKeyboardGrab(grab));
}

pub fn trySetKeyboardGrab(self: *Self, grab: KeyboardGrab) bool {
    if (self.keyboard_grab != null) return false;
    return self.installKeyboardGrab(grab);
}

fn installKeyboardGrab(self: *Self, grab: KeyboardGrab) bool {
    std.debug.assert(self.keyboard_grab == null);
    if (grab.surface) |surface_id| {
        if (Surface.resourceFor(self.surface_store, surface_id) == null) return false;
        if (self.parent_focused) self.sendLeave();
    }
    self.keyboard_grab = grab;
    if (grab.surface != null) {
        if (self.parent_focused and self.keymap != null) self.sendEnter();
        self.notifyKeyboardFocus();
    } else {
        if (self.keymap) |keymap| {
            grab.keymap(grab.context, keymap.format, keymap.file.handle, keymap.size);
        }
        grab.repeat_info(grab.context, self.repeat_info.rate, self.repeat_info.delay);
        grab.modifiers(
            grab.context,
            self.modifier_state.current.depressed,
            self.modifier_state.current.latched,
            self.modifier_state.current.locked,
            self.modifier_state.current.group,
        );
    }
    return true;
}

pub fn clearKeyboardGrab(self: *Self, context: *anyopaque, restore_focus: bool) void {
    const grab = self.keyboard_grab orelse unreachable;
    std.debug.assert(grab.context == context);
    if (grab.surface != null and self.parent_focused) self.sendLeave();
    self.keyboard_grab = null;
    if (!restore_focus) return;
    if (grab.surface != null) {
        self.notifyKeyboardFocus();
        if (self.parent_focused and self.keymap != null) self.sendEnter();
        return;
    }
    const surface = self.focusedSurface() orelse return;
    if (!self.parent_focused or self.keymap == null) return;
    const serial = self.display.nextSerial();
    for (self.keyboard_resources.items) |entry| {
        if (!self.keyboardResourceActive(entry)) continue;
        if (entry.resource.getClient() == surface.getClient()) {
            self.sendModifiers(entry.resource, serial);
        }
    }
}

pub fn acceptsUserActionSerial(
    self: *Self,
    resource: *wl.Seat,
    client: *wl.Client,
    serial: u32,
) bool {
    if (!self.ownsResource(resource)) return false;
    return self.acceptsClientUserActionSerial(client, serial);
}

pub fn acceptsSelectionSerial(self: *Self, client: *wl.Client, serial: u32) bool {
    return self.user_action_serials.acceptsSelection(client, serial);
}

pub fn acceptsActivationSerial(
    self: *Self,
    resource: *wl.Seat,
    client: *wl.Client,
    serial: u32,
) bool {
    if (!self.ownsResource(resource)) return false;
    if (self.acceptsSelectionSerial(client, serial)) return true;
    const pointer_enter = self.latest_pointer_enter orelse return false;
    return pointer_enter.client == client and pointer_enter.serial == serial;
}

pub fn activationSurfaceFocused(self: *const Self, surface_id: Surface.Id) bool {
    if (self.focus) |focus| {
        if (std.meta.eql(focus, surface_id)) return true;
    }
    if (self.pointer_focus) |focus| {
        if (std.meta.eql(focus.surface_id, surface_id)) return true;
    }
    for (self.touch_points.items) |point| {
        const target = point.target orelse continue;
        if (std.meta.eql(target.surface_id, surface_id)) return true;
    }
    return false;
}

pub fn acceptsClientUserActionSerial(self: *const Self, client: *wl.Client, serial: u32) bool {
    return self.user_action_serials.acceptsAction(client, serial);
}

pub fn acceptsPointerGrabSerial(
    self: *const Self,
    client: *wl.Client,
    surface_id: Surface.Id,
    serial: u32,
) bool {
    for (self.pressed_pointer_buttons.items) |press| {
        if (press.client == client and press.serial == serial and
            std.meta.eql(press.surface_id, surface_id)) return true;
    }
    return false;
}

pub fn hasPressedPointerButton(self: *const Self, button: u32) bool {
    for (self.pressed_pointer_buttons.items) |press| {
        if (press.button == button) return true;
    }
    return false;
}

pub fn hasPressedPointerButtons(self: *const Self) bool {
    return self.pressed_pointer_buttons.items.len != 0;
}

pub fn implicitPointerGrabActive(self: *const Self) bool {
    return self.pointer_grab != null;
}

pub fn hasPressedPointerButtonForSurface(
    self: *const Self,
    button: u32,
    surface_id: Surface.Id,
) bool {
    for (self.pressed_pointer_buttons.items) |press| {
        if (press.button == button and std.meta.eql(press.surface_id, surface_id)) return true;
    }
    return false;
}

pub fn forgetPressedPointerButton(self: *Self, button: u32) void {
    for (self.pressed_pointer_buttons.items, 0..) |press, index| {
        if (press.button != button) continue;
        _ = self.pressed_pointer_buttons.orderedRemove(index);
        if (self.pressed_pointer_buttons.items.len == 0) self.pointer_grab = null;
        return;
    }
}

pub fn serialIsOlder(candidate: u32, current: u32) bool {
    return candidate -% current > std.math.maxInt(u32) / 2;
}

pub fn pointerFocusedSurface(self: *const Self) ?Surface.Id {
    const focus = self.pointer_focus orelse return null;
    return focus.surface_id;
}

pub fn pointerFocus(self: *const Self) ?PointerFocus {
    return self.pointer_focus;
}

pub fn pointerFocusedClient(self: *const Self) ?*wl.Client {
    const focus = self.pointer_focus orelse return null;
    const resource = Surface.resourceFor(self.surface_store, focus.surface_id) orelse return null;
    return resource.getClient();
}

pub fn pointerFocusedResource(self: *Self) ?*wl.Surface {
    return self.pointerSurface();
}

pub fn pointerPosition(self: *const Self) ?struct { x: f64, y: f64 } {
    const position = self.pointer_position orelse return null;
    return .{ .x = position.x, .y = position.y };
}

pub fn effectiveModifiers(self: *const Self) u32 {
    const modifiers = self.modifier_state.current;
    return (modifiers.depressed | modifiers.latched) & 0xed;
}

/// Set the client allowed to own the cursor while pointer focus is absent.
/// This is also the generic ownership query point for cursor-shape protocols.
pub fn setUnfocusedCursorController(self: *Self, client: ?*wl.Client) void {
    if (client == null) {
        self.cursor_controller = null;
    } else if (self.cursor_controller == null or self.cursor_controller.?.client != client.?) {
        self.cursor_controller = .{ .client = client.?, .cursor = null, .configured = false };
    }
    if (self.pointer_focus == null) self.restoreControllerCursor();
}

pub fn isUnfocusedCursorController(self: *const Self, client: *wl.Client) bool {
    return if (self.cursor_controller) |controller| controller.client == client else false;
}

pub fn setDragCursorController(self: *Self, client: ?*wl.Client) void {
    if (self.drag_cursor_client == client) return;
    if (client) |value| {
        self.drag_cursor_client = value;
        return;
    }
    const old_cursor = self.cursorInfo();
    self.drag_cursor_client = client;
    self.pointer_cursor_configured = false;
    self.active_cursor = if (self.pointer_focus == null)
        if (self.cursor_controller) |controller| controller.cursor else null
    else
        null;
    self.notifyCursorChanged(old_cursor);
}

pub fn suppressPointerFocus(self: *Self, suppress: bool) void {
    if (!suppress) return;
    if (self.pointer_grab) |*grab| grab.suppressed = true;
    self.updatePointerFocus(null, null);
}

/// End implicit pointer routing while preserving button bookkeeping for a drag.
pub fn dissolvePointerGrab(self: *Self) void {
    self.pointer_grab = null;
}

pub fn restoreUnfocusedCursor(self: *Self) void {
    self.restoreControllerCursor();
}

pub fn keyboardFocusedClient(self: *Self) ?*wl.Client {
    if (!self.hasKeyboardCapability()) return null;
    if (!self.parent_focused or self.keymap == null) return null;
    const surface = self.keyboardDeliverySurface() orelse return null;
    return surface.getClient();
}

pub fn keyboardFocusedSurface(self: *const Self) ?Surface.Id {
    if (!self.hasKeyboardCapability()) return null;
    if (!self.parent_focused or self.keymap == null) return null;
    const focus = self.keyboardDeliverySurfaceId() orelse return null;
    if (Surface.resourceFor(self.surface_store, focus) == null) return null;
    return focus;
}

pub fn cursorInfo(self: *const Self) ?CursorInfo {
    const position = self.pointer_position orelse return null;
    if (self.compositor_cursor) |cursor| return .{ .shape = .{
        .buffer = cursor.buffer,
        .x = cursorCoordinate(position.x, cursor.hotspot_x),
        .y = cursorCoordinate(position.y, cursor.hotspot_y),
    } };
    const cursor = self.active_cursor orelse {
        if (!defaultCursorVisible(
            self.pointer_focus != null,
            self.pointer_cursor_configured,
            self.drag_cursor_client != null,
            if (self.cursor_controller) |controller| controller.configured else false,
        )) return null;
        const fallback = self.default_cursor orelse return null;
        return .{ .shape = .{
            .buffer = fallback.buffer,
            .x = cursorCoordinate(position.x, fallback.hotspot_x),
            .y = cursorCoordinate(position.y, fallback.hotspot_y),
        } };
    };
    return switch (cursor) {
        .surface => |surface| .{ .surface = .{
            .surface_id = surface.surface_id,
            .x = cursorCoordinate(position.x, surface.hotspot_x),
            .y = cursorCoordinate(position.y, surface.hotspot_y),
        } },
        .shape => |shape| .{ .shape = .{
            .buffer = shape.buffer,
            .x = cursorCoordinate(position.x, shape.hotspot_x),
            .y = cursorCoordinate(position.y, shape.hotspot_y),
        } },
    };
}

fn defaultCursorVisible(
    pointer_focused: bool,
    pointer_cursor_configured: bool,
    drag_cursor_active: bool,
    controller_configured: bool,
) bool {
    if (pointer_focused) return !pointer_cursor_configured;
    return !drag_cursor_active and !controller_configured;
}

/// Overrides client and fallback cursors while the compositor owns the pointer.
/// The image's pixel storage must remain valid until this override is replaced.
pub fn setCompositorCursor(self: *Self, cursor: ?CursorImage) void {
    if (std.meta.eql(self.compositor_cursor, cursor)) return;
    const old_cursor = self.cursorInfo();
    self.compositor_cursor = cursor;
    self.notifyCursorChanged(old_cursor);
}

pub fn setDefaultCursor(self: *Self, cursor: ?CursorImage) void {
    const old_cursor = self.cursorInfo();
    self.default_cursor = cursor;
    self.notifyCursorChanged(old_cursor);
}

pub fn setKeyboardAvailable(self: *Self, available: bool) void {
    if (self.keyboard_available == available) return;
    const old_capability = self.hasKeyboardCapability();
    if (!available and self.virtual_keyboard_count == 0) self.parentKeyboardLeave();
    self.keyboard_available = available;
    const new_capability = self.hasKeyboardCapability();
    if (!old_capability and new_capability) {
        beginCapabilityGeneration(
            &self.keyboard_capability_generation,
            &self.keyboard_ever_available,
        );
    }
    if (old_capability != new_capability) self.broadcastCapabilities();
}

pub fn addVirtualKeyboard(self: *Self) void {
    const old_capability = self.hasKeyboardCapability();
    self.virtual_keyboard_count = std.math.add(usize, self.virtual_keyboard_count, 1) catch
        unreachable;
    const new_capability = self.hasKeyboardCapability();
    if (!old_capability and new_capability) {
        beginCapabilityGeneration(
            &self.keyboard_capability_generation,
            &self.keyboard_ever_available,
        );
    }
    if (old_capability == new_capability) return;
    self.broadcastCapabilities();
    if (self.parent_focused) {
        self.notifyKeyboardFocus();
        self.sendEnter();
    }
}

pub fn removeVirtualKeyboard(self: *Self) void {
    std.debug.assert(self.virtual_keyboard_count > 0);
    const old_capability = self.hasKeyboardCapability();
    if (old_capability and !self.keyboard_available and
        self.virtual_keyboard_count == 1 and self.parent_focused) self.sendLeave();
    self.virtual_keyboard_count -= 1;
    const new_capability = self.hasKeyboardCapability();
    if (old_capability == new_capability) return;
    self.broadcastCapabilities();
    self.notifyKeyboardFocus();
}

pub fn setPointerAvailable(self: *Self, available: bool) void {
    if (self.pointer_available == available) return;
    const old_capability = self.hasPointerCapability();
    self.pointer_available = available;
    const new_capability = self.hasPointerCapability();
    if (old_capability and !new_capability) {
        self.pointerLeave();
        self.pressed_pointer_buttons.clearRetainingCapacity();
    }
    if (!old_capability and new_capability) {
        beginCapabilityGeneration(
            &self.pointer_capability_generation,
            &self.pointer_ever_available,
        );
    }
    if (old_capability != new_capability) self.broadcastCapabilities();
}

pub fn addVirtualPointer(self: *Self) void {
    const old_capability = self.hasPointerCapability();
    self.virtual_pointer_count = std.math.add(usize, self.virtual_pointer_count, 1) catch
        unreachable;
    if (old_capability) return;
    beginCapabilityGeneration(
        &self.pointer_capability_generation,
        &self.pointer_ever_available,
    );
    self.broadcastCapabilities();
}

pub fn removeVirtualPointer(self: *Self) void {
    std.debug.assert(self.virtual_pointer_count > 0);
    const old_capability = self.hasPointerCapability();
    self.virtual_pointer_count -= 1;
    if (old_capability == self.hasPointerCapability()) return;
    self.pointerLeave();
    self.pressed_pointer_buttons.clearRetainingCapacity();
    self.broadcastCapabilities();
}

pub fn hasVirtualPointers(self: *const Self) bool {
    return self.virtual_pointer_count != 0;
}

pub fn setTouchAvailable(self: *Self, available: bool) void {
    if (self.touch_available == available) return;
    if (!available) self.touchCancel();
    self.touch_available = available;
    if (available) {
        beginCapabilityGeneration(
            &self.touch_capability_generation,
            &self.touch_ever_available,
        );
    }
    self.broadcastCapabilities();
}

pub fn setKeymap(
    self: *Self,
    format: wl.Keyboard.KeymapFormat,
    fd: std.posix.fd_t,
    size: u32,
) void {
    const old_focus = self.keyboardFocusedClient();
    const old_capability = self.hasKeyboardCapability();
    if (self.keymap) |keymap| keymap.file.close(self.io);
    self.keymap = .{
        .format = format,
        .file = .{ .handle = fd, .flags = .{ .nonblocking = false } },
        .size = size,
    };
    const new_capability = self.hasKeyboardCapability();
    if (!old_capability and new_capability) {
        beginCapabilityGeneration(
            &self.keyboard_capability_generation,
            &self.keyboard_ever_available,
        );
    }
    if (old_capability != new_capability) self.broadcastCapabilities();
    for (self.keyboard_resources.items) |entry| {
        if (!self.keyboardResourceActive(entry)) continue;
        self.sendKeymap(entry.resource);
        self.sendRepeatInfo(entry.resource);
    }
    if (self.keyboard_grab) |grab| {
        if (grab.surface == null) grab.keymap(grab.context, format, fd, size);
    }
    if (old_focus == null and self.keyboardFocusedClient() != null) {
        self.notifyKeyboardFocus();
        self.sendEnter();
    }
}

pub fn setRepeatInfo(self: *Self, rate: i32, delay: i32) void {
    std.debug.assert(rate >= 0 and delay >= 0);
    self.repeat_info = .{ .rate = rate, .delay = delay };
    for (self.keyboard_resources.items) |entry| {
        if (self.keyboardResourceActive(entry)) self.sendRepeatInfo(entry.resource);
    }
    if (self.keyboard_grab) |grab| {
        if (grab.surface == null) grab.repeat_info(grab.context, rate, delay);
    }
}

pub fn setKeyboardFocus(self: *Self, focus: ?Surface.Id) void {
    if (std.meta.eql(self.focus, focus)) return;
    if (self.keyboard_grab) |grab| if (grab.surface != null) {
        self.focus = focus;
        return;
    };
    if (self.parent_focused) self.sendLeave();
    self.focus = focus;
    if (self.parent_focused) {
        self.notifyKeyboardFocus();
        self.sendEnter();
    }
}

pub fn parentKeyboardEnter(self: *Self, pressed_keys: []const u32) error{OutOfMemory}!void {
    try self.pressed_keys.replacePhysical(pressed_keys);
    self.removeStaleGrabbedKeys();
    if (self.parent_focused) return;
    self.parent_focused = true;
    self.notifyKeyboardFocus();
    self.sendEnter();
}

pub fn ensureParentKeyboardEnter(self: *Self) void {
    if (self.parent_focused) return;
    self.parent_focused = true;
    self.notifyKeyboardFocus();
    self.sendEnter();
}

pub fn parentKeyboardLeave(self: *Self) void {
    if (self.parent_focused) self.sendLeave();
    self.parent_focused = false;
    self.notifyKeyboardFocus();
    self.pressed_keys.clearPhysical();
    self.removeStaleGrabbedKeys();
}

/// Updates the primary keyboard stream, already aggregated across physical devices.
pub fn key(
    self: *Self,
    time: u32,
    key_code: u32,
    state: wl.Keyboard.KeyState,
) error{OutOfMemory}!void {
    try self.keyWithGrab(time, key_code, state, true);
}

/// Updates one independently deduplicated virtual-keyboard stream.
/// Releasing a key accepted from this stream does not allocate.
pub fn virtualKey(
    self: *Self,
    time: u32,
    key_code: u32,
    state: wl.Keyboard.KeyState,
) error{OutOfMemory}!void {
    try self.keyWithGrab(time, key_code, state, false);
}

fn keyWithGrab(
    self: *Self,
    time: u32,
    key_code: u32,
    state: wl.Keyboard.KeyState,
    allow_grab: bool,
) error{OutOfMemory}!void {
    const source: PressedKeyState.Source = if (allow_grab) .physical else .virtual;
    if (!try self.pressed_keys.update(key_code, state, source)) return;
    errdefer if (state == .pressed) {
        std.debug.assert(self.pressed_keys.update(
            key_code,
            .released,
            source,
        ) catch unreachable);
    };

    var route_to_grab: ?u64 = null;
    switch (state) {
        .pressed => {
            if (allow_grab) {
                if (self.keyboard_grab) |grab| {
                    try self.grabbed_keys.append(self.allocator, .{
                        .key = key_code,
                        .token = grab.token,
                    });
                    route_to_grab = grab.token;
                }
            }
        },
        .released => {
            for (self.grabbed_keys.items, 0..) |grabbed, index| {
                if (grabbed.key != key_code) continue;
                route_to_grab = grabbed.token;
                _ = self.grabbed_keys.orderedRemove(index);
                break;
            }
        },
        .repeated => for (self.grabbed_keys.items) |grabbed| {
            if (grabbed.key == key_code) {
                route_to_grab = grabbed.token;
                break;
            }
        },
        else => return,
    }

    if (!self.parent_focused or self.keymap == null) return;
    if (route_to_grab) |token| {
        const grab = self.keyboard_grab orelse return;
        if (grab.token != token) return;
        if (grab.surface) |surface_id| {
            const surface = Surface.resourceFor(self.surface_store, surface_id) orelse return;
            const serial = self.display.nextSerial();
            if (state == .pressed)
                self.user_action_serials.recordAction(surface.getClient(), serial)
            else
                self.user_action_serials.recordSelection(surface.getClient(), serial);
            for (self.keyboard_resources.items) |entry| {
                if (!self.keyboardResourceActive(entry)) continue;
                const resource = entry.resource;
                if (resource.getClient() != surface.getClient()) continue;
                if (state == .repeated and resource.getVersion() < 10) continue;
                resource.sendKey(serial, time, key_code, state);
            }
            return;
        }
        if (state == .repeated) return;
        grab.key(grab.context, self.display.nextSerial(), time, key_code, state);
        return;
    }
    const surface = self.focusedSurface() orelse return;
    const serial = self.display.nextSerial();
    if (state == .pressed)
        self.user_action_serials.recordAction(surface.getClient(), serial)
    else
        self.user_action_serials.recordSelection(surface.getClient(), serial);
    for (self.keyboard_resources.items) |entry| {
        if (!self.keyboardResourceActive(entry)) continue;
        const resource = entry.resource;
        if (resource.getClient() != surface.getClient()) continue;
        if (state == .repeated and resource.getVersion() < 10) continue;
        resource.sendKey(serial, time, key_code, state);
    }
}

fn removeStaleGrabbedKeys(self: *Self) void {
    var index: usize = 0;
    while (index < self.grabbed_keys.items.len) {
        if (self.pressed_keys.contains(self.grabbed_keys.items[index].key)) {
            index += 1;
        } else {
            _ = self.grabbed_keys.orderedRemove(index);
        }
    }
}

pub fn setModifiers(
    self: *Self,
    depressed: u32,
    latched: u32,
    locked: u32,
    group: u32,
) void {
    self.modifier_state.setPhysical(.{
        .depressed = depressed,
        .latched = latched,
        .locked = locked,
        .group = group,
    });
    self.sendCurrentModifiers(true);
}

pub fn setVirtualModifiers(
    self: *Self,
    owner: *anyopaque,
    depressed: u32,
    latched: u32,
    locked: u32,
    group: u32,
) void {
    self.modifier_state.setVirtual(owner, .{
        .depressed = depressed,
        .latched = latched,
        .locked = locked,
        .group = group,
    });
    self.sendCurrentModifiers(false);
}

pub fn clearVirtualModifiers(self: *Self, owner: *anyopaque) void {
    if (!self.modifier_state.clearVirtual(owner)) return;
    self.sendCurrentModifiers(false);
}

fn sendCurrentModifiers(self: *Self, allow_grab: bool) void {
    const modifiers = self.modifier_state.current;
    if (allow_grab) {
        if (self.keyboard_grab) |grab| {
            if (grab.surface) |surface_id| {
                const surface = Surface.resourceFor(self.surface_store, surface_id) orelse return;
                const serial = self.display.nextSerial();
                for (self.keyboard_resources.items) |entry| {
                    if (!self.keyboardResourceActive(entry)) continue;
                    if (entry.resource.getClient() == surface.getClient()) {
                        self.sendModifiers(entry.resource, serial);
                    }
                }
                return;
            }
            grab.modifiers(
                grab.context,
                modifiers.depressed,
                modifiers.latched,
                modifiers.locked,
                modifiers.group,
            );
            return;
        }
    }
    const surface = self.focusedSurface() orelse return;
    if (!self.parent_focused or self.keymap == null) return;
    const serial = self.display.nextSerial();
    for (self.keyboard_resources.items) |entry| {
        if (!self.keyboardResourceActive(entry)) continue;
        if (entry.resource.getClient() == surface.getClient()) {
            self.sendModifiers(entry.resource, serial);
        }
    }
}

pub fn pointerEnter(self: *Self, x: f64, y: f64, focus: ?PointerFocus) void {
    const adjusted_focus = adjustedPointerGrabFocus(
        self.pointer_grab,
        self.pointer_focus,
        self.pointer_position,
        focus,
        x,
        y,
    );
    self.setPointerPosition(x, y);
    self.updatePointerFocus(adjusted_focus, null);
}

pub fn pointerMotion(self: *Self, time: u32, x: f64, y: f64, focus: ?PointerFocus) void {
    const adjusted_focus = adjustedPointerGrabFocus(
        self.pointer_grab,
        self.pointer_focus,
        self.pointer_position,
        focus,
        x,
        y,
    );
    self.setPointerPosition(x, y);
    self.updatePointerFocus(adjusted_focus, time);
}

pub fn warpPointer(
    self: *Self,
    surface_id: Surface.Id,
    surface_x: f64,
    surface_y: f64,
) ?struct { x: f64, y: f64 } {
    const focus = self.pointer_focus orelse return null;
    if (!std.meta.eql(focus.surface_id, surface_id)) return null;
    const position = self.pointer_position orelse return null;
    const warped = PointerPosition{
        .x = position.x + surface_x - focus.x,
        .y = position.y + surface_y - focus.y,
    };
    self.setPointerPosition(warped.x, warped.y);
    self.pointer_focus.?.x = surface_x;
    self.pointer_focus.?.y = surface_y;
    return .{ .x = warped.x, .y = warped.y };
}

pub fn pointerLeave(self: *Self) void {
    const old_cursor = self.cursorInfo();
    self.sendPointerLeave();
    self.active_cursor = null;
    self.pointer_cursor_configured = false;
    self.compositor_cursor = null;
    self.pointer_focus = null;
    self.pointer_position = null;
    self.latest_pointer_enter = null;
    self.pointer_grab = null;
    self.pressed_pointer_buttons.clearRetainingCapacity();
    self.notifyCursorChanged(old_cursor);
}

pub fn pointerButton(
    self: *Self,
    time: u32,
    button: u32,
    state: wl.Pointer.ButtonState,
) error{OutOfMemory}!bool {
    switch (state) {
        .pressed => {
            for (self.pressed_pointer_buttons.items) |press| {
                if (press.button == button) return false;
            }
            const surface = self.pointerSurface() orelse return false;
            const serial = self.display.nextSerial();
            const starts_grab = self.pressed_pointer_buttons.items.len == 0;
            try self.pressed_pointer_buttons.append(self.allocator, .{
                .button = button,
                .client = surface.getClient(),
                .surface_id = self.pointer_focus.?.surface_id,
                .serial = serial,
            });
            if (starts_grab) {
                self.pointer_grab = .{ .surface_id = self.pointer_focus.?.surface_id };
            }
            self.user_action_serials.recordAction(surface.getClient(), serial);
            for (self.pointer_resources.items) |entry| {
                if (!self.pointerResourceActive(entry)) continue;
                const resource = entry.resource;
                if (resource.getClient() == surface.getClient()) {
                    resource.sendButton(serial, time, button, state);
                }
            }
            return false;
        },
        .released => {
            for (self.pressed_pointer_buttons.items, 0..) |press, index| {
                if (press.button != button) continue;
                _ = self.pressed_pointer_buttons.orderedRemove(index);
                break;
            } else return false;
        },
        else => return false,
    }

    const grab_ended = self.pressed_pointer_buttons.items.len == 0;
    if (grab_ended) self.pointer_grab = null;
    const surface = self.pointerSurface() orelse return grab_ended;
    const serial = self.display.nextSerial();
    self.user_action_serials.recordSelection(surface.getClient(), serial);
    for (self.pointer_resources.items) |entry| {
        if (!self.pointerResourceActive(entry)) continue;
        const resource = entry.resource;
        if (resource.getClient() == surface.getClient()) {
            resource.sendButton(serial, time, button, state);
        }
    }
    return grab_ended;
}

pub fn pointerAxis(self: *Self, time: u32, axis: wl.Pointer.Axis, value: wl.Fixed) void {
    const surface = self.pointerSurface() orelse return;
    for (self.pointer_resources.items) |entry| {
        if (!self.pointerResourceActive(entry)) continue;
        const resource = entry.resource;
        if (resource.getClient() == surface.getClient()) resource.sendAxis(time, axis, value);
    }
}

pub fn pointerFrame(self: *Self) void {
    const surface = self.pointerSurface() orelse return;
    for (self.pointer_resources.items) |entry| {
        if (!self.pointerResourceActive(entry)) continue;
        const resource = entry.resource;
        if (resource.getClient() == surface.getClient() and
            resource.getVersion() >= wl.Pointer.frame_since_version)
        {
            resource.sendFrame();
        }
    }
}

pub fn pointerAxisSource(self: *Self, source: wl.Pointer.AxisSource) void {
    const surface = self.pointerSurface() orelse return;
    for (self.pointer_resources.items) |entry| {
        if (!self.pointerResourceActive(entry)) continue;
        const resource = entry.resource;
        if (resource.getClient() == surface.getClient() and
            resource.getVersion() >= wl.Pointer.axis_source_since_version)
        {
            resource.sendAxisSource(source);
        }
    }
}

pub fn pointerAxisStop(self: *Self, time: u32, axis: wl.Pointer.Axis) void {
    const surface = self.pointerSurface() orelse return;
    for (self.pointer_resources.items) |entry| {
        if (!self.pointerResourceActive(entry)) continue;
        const resource = entry.resource;
        if (resource.getClient() == surface.getClient() and
            resource.getVersion() >= wl.Pointer.axis_stop_since_version)
        {
            resource.sendAxisStop(time, axis);
        }
    }
}

pub fn pointerAxisDiscrete(self: *Self, axis: wl.Pointer.Axis, discrete: i32) void {
    const surface = self.pointerSurface() orelse return;
    for (self.pointer_resources.items) |entry| {
        if (!self.pointerResourceActive(entry)) continue;
        const resource = entry.resource;
        if (resource.getClient() == surface.getClient() and
            resource.getVersion() >= wl.Pointer.axis_discrete_since_version and
            resource.getVersion() < wl.Pointer.axis_value120_since_version)
        {
            resource.sendAxisDiscrete(axis, discrete);
        }
    }
}

pub fn pointerAxisValue120(self: *Self, axis: wl.Pointer.Axis, value120: i32) void {
    const surface = self.pointerSurface() orelse return;
    for (self.pointer_resources.items) |entry| {
        if (!self.pointerResourceActive(entry)) continue;
        const resource = entry.resource;
        if (resource.getClient() == surface.getClient() and
            resource.getVersion() >= wl.Pointer.axis_value120_since_version)
        {
            resource.sendAxisValue120(axis, value120);
        }
    }
}

pub fn pointerAxisRelativeDirection(
    self: *Self,
    axis: wl.Pointer.Axis,
    direction: wl.Pointer.AxisRelativeDirection,
) void {
    const surface = self.pointerSurface() orelse return;
    for (self.pointer_resources.items) |entry| {
        if (!self.pointerResourceActive(entry)) continue;
        const resource = entry.resource;
        if (resource.getClient() == surface.getClient() and
            resource.getVersion() >= wl.Pointer.axis_relative_direction_since_version)
        {
            resource.sendAxisRelativeDirection(axis, direction);
        }
    }
}

pub fn touchDown(
    self: *Self,
    time: u32,
    id: i32,
    x: f64,
    y: f64,
    focus: ?PointerFocus,
) error{OutOfMemory}!void {
    if (!self.touch_available or self.findTouchPoint(id) != null) return;
    try self.touch_points.ensureUnusedCapacity(self.allocator, 1);

    const target: ?TouchPoint.Target = if (focus) |candidate| target: {
        const surface = Surface.resourceFor(self.surface_store, candidate.surface_id) orelse
            break :target null;
        const max_resource_generation = self.latestTouchResourceGeneration(
            surface.getClient(),
        ) orelse break :target null;
        break :target .{
            .surface_id = candidate.surface_id,
            .client = surface.getClient(),
            .offset_x = x - candidate.x,
            .offset_y = y - candidate.y,
            .max_resource_generation = max_resource_generation,
        };
    } else null;
    self.touch_points.appendAssumeCapacity(.{ .id = id, .target = target });

    const destination = target orelse return;
    const surface = Surface.resourceFor(self.surface_store, destination.surface_id) orelse return;
    const serial = self.display.nextSerial();
    self.user_action_serials.recordAction(destination.client, serial);
    for (self.touch_resources.items) |entry| {
        if (!self.touchResourceActive(entry)) continue;
        const resource = entry.resource;
        if (touchResourceInSequence(entry.generation, destination.max_resource_generation) and
            resource.getClient() == destination.client)
        {
            try self.markTouchFrame(resource);
            resource.sendDown(
                serial,
                time,
                surface,
                id,
                fixed(x - destination.offset_x),
                fixed(y - destination.offset_y),
            );
        }
    }
}

pub fn touchUp(self: *Self, time: u32, id: i32) error{OutOfMemory}!void {
    if (!self.touch_available) return;
    const index = self.findTouchPoint(id) orelse return;
    const point = self.touch_points.items[index];
    if (point.target) |target| {
        const serial = self.display.nextSerial();
        self.user_action_serials.recordSelection(target.client, serial);
        for (self.touch_resources.items) |entry| {
            if (!self.touchResourceActive(entry)) continue;
            const resource = entry.resource;
            if (touchResourceInSequence(entry.generation, target.max_resource_generation) and
                resource.getClient() == target.client)
            {
                try self.markTouchFrame(resource);
                resource.sendUp(serial, time, id);
            }
        }
    }
    _ = self.touch_points.orderedRemove(index);
}

pub fn touchMotion(
    self: *Self,
    time: u32,
    id: i32,
    x: f64,
    y: f64,
) error{OutOfMemory}!void {
    if (!self.touch_available) return;
    const point = self.touchPoint(id) orelse return;
    const target = point.target orelse return;
    for (self.touch_resources.items) |entry| {
        if (!self.touchResourceActive(entry)) continue;
        const resource = entry.resource;
        if (touchResourceInSequence(entry.generation, target.max_resource_generation) and
            resource.getClient() == target.client)
        {
            try self.markTouchFrame(resource);
            resource.sendMotion(
                time,
                id,
                fixed(x - target.offset_x),
                fixed(y - target.offset_y),
            );
        }
    }
}

pub fn touchFrame(self: *Self) void {
    for (self.touch_frame_resources.items) |resource| resource.sendFrame();
    self.touch_frame_resources.clearRetainingCapacity();
}

pub fn touchCancel(self: *Self) void {
    for (self.touch_resources.items) |entry| {
        if (!self.touchResourceActive(entry)) continue;
        for (self.touch_points.items) |point| {
            const target = point.target orelse continue;
            if (!touchResourceInSequence(entry.generation, target.max_resource_generation)) continue;
            if (entry.resource.getClient() != target.client) continue;
            entry.resource.sendCancel();
            break;
        }
    }
    self.touch_points.clearRetainingCapacity();
    self.touch_frame_resources.clearRetainingCapacity();
}

/// Cancels the client-visible stream containing `id` and forgets that point.
/// Other points in the stream remain tracked without a target until their
/// physical device reports up or cancel.
pub fn touchCancelPoint(self: *Self, id: i32) void {
    const cancellation = cancelTouchPointState(&self.touch_points, id) orelse return;
    for (self.touch_resources.items) |entry| {
        if (!self.touchResourceActive(entry) or
            entry.generation > cancellation.max_resource_generation or
            entry.resource.getClient() != cancellation.client) continue;
        entry.resource.sendCancel();
    }
    var index: usize = 0;
    while (index < self.touch_frame_resources.items.len) {
        if (self.touch_frame_resources.items[index].getClient() == cancellation.client) {
            _ = self.touch_frame_resources.orderedRemove(index);
        } else {
            index += 1;
        }
    }
}

pub fn touchShape(self: *Self, id: i32, major: f64, minor: f64) error{OutOfMemory}!void {
    if (!self.touch_available) return;
    const point = self.touchPoint(id) orelse return;
    const target = point.target orelse return;
    if (!self.hasTouchResourceVersion(
        target.client,
        wl.Touch.shape_since_version,
        target.max_resource_generation,
    )) return;
    for (self.touch_resources.items) |entry| {
        if (!self.touchResourceActive(entry)) continue;
        const resource = entry.resource;
        if (touchResourceInSequence(entry.generation, target.max_resource_generation) and
            resource.getClient() == target.client and
            resource.getVersion() >= wl.Touch.shape_since_version)
        {
            try self.markTouchFrame(resource);
            resource.sendShape(id, fixed(major), fixed(minor));
        }
    }
}

pub fn touchOrientation(self: *Self, id: i32, orientation: f64) error{OutOfMemory}!void {
    if (!self.touch_available) return;
    const point = self.touchPoint(id) orelse return;
    const target = point.target orelse return;
    if (!self.hasTouchResourceVersion(
        target.client,
        wl.Touch.orientation_since_version,
        target.max_resource_generation,
    )) return;
    for (self.touch_resources.items) |entry| {
        if (!self.touchResourceActive(entry)) continue;
        const resource = entry.resource;
        if (touchResourceInSequence(entry.generation, target.max_resource_generation) and
            resource.getClient() == target.client and
            resource.getVersion() >= wl.Touch.orientation_since_version)
        {
            try self.markTouchFrame(resource);
            resource.sendOrientation(id, fixed(orientation));
        }
    }
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = wl.Seat.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    self.seat_resources.append(self.allocator, resource) catch {
        resource.postNoMemory();
        resource.destroy();
        return;
    };
    resource.setHandler(*Self, handleRequest, handleSeatDestroy, self);
    self.notifySeatResourceCount();
    if (version >= wl.Seat.name_since_version) resource.sendName(self.name_value);
    resource.sendCapabilities(self.capabilities());
}

fn handleRequest(resource: *wl.Seat, request: wl.Seat.Request, self: *Self) void {
    switch (request) {
        .release => resource.destroy(),
        .get_keyboard => |get| if (self.keyboard_ever_available)
            self.createKeyboard(resource, get.id)
        else
            resource.postError(.missing_capability, "seat has never had a keyboard capability"),
        .get_pointer => |get| if (self.pointer_ever_available)
            self.createPointer(resource, get.id)
        else
            resource.postError(.missing_capability, "seat has never had a pointer capability"),
        .get_touch => |get| if (self.touch_ever_available)
            self.createTouch(resource, get.id)
        else
            resource.postError(.missing_capability, "seat has never had a touch capability"),
    }
}

fn handleSeatDestroy(resource: *wl.Seat, self: *Self) void {
    for (self.seat_resources.items, 0..) |candidate, index| {
        if (candidate != resource) continue;
        _ = self.seat_resources.orderedRemove(index);
        self.notifySeatResourceCount();
        return;
    }
    unreachable;
}

fn notifySeatResourceCount(self: *Self) void {
    const listener = self.seat_resource_listener orelse return;
    // The listener may deinitialize this seat once the count reaches zero, so
    // destruction handlers must not access self after notifying it.
    listener.changed(
        listener.context,
        self.seat_resources.items.len +
            self.keyboard_resources.items.len +
            self.pointer_resources.items.len +
            self.touch_resources.items.len,
    );
}

fn createKeyboard(self: *Self, seat: *wl.Seat, id: u32) void {
    const resource = wl.Keyboard.create(seat.getClient(), seat.getVersion(), id) catch {
        seat.postNoMemory();
        return;
    };
    const entry: KeyboardResource = .{
        .resource = resource,
        .capability_generation = self.keyboard_capability_generation,
    };
    self.keyboard_resources.append(self.allocator, entry) catch {
        resource.postNoMemory();
        resource.destroy();
        return;
    };
    resource.setHandler(*Self, handleKeyboardRequest, handleKeyboardDestroy, self);
    self.notifySeatResourceCount();
    if (!self.keyboardResourceActive(entry)) return;
    if (self.keymap == null) return;
    self.sendKeymap(resource);
    self.sendRepeatInfo(resource);
    const surface = self.keyboardDeliverySurface() orelse return;
    if (self.parent_focused and resource.getClient() == surface.getClient()) {
        const serial = self.display.nextSerial();
        self.user_action_serials.recordSelection(surface.getClient(), serial);
        self.sendEnterTo(resource, surface, serial);
    }
}

fn createPointer(self: *Self, seat: *wl.Seat, id: u32) void {
    const resource = wl.Pointer.create(seat.getClient(), seat.getVersion(), id) catch {
        seat.postNoMemory();
        return;
    };
    const generation = self.next_pointer_resource_generation;
    const entry: PointerResource = .{
        .resource = resource,
        .generation = generation,
        .capability_generation = self.pointer_capability_generation,
        .enter_serial = null,
    };
    self.pointer_resources.append(self.allocator, entry) catch {
        resource.postNoMemory();
        resource.destroy();
        return;
    };
    self.next_pointer_resource_generation = std.math.add(u64, generation, 1) catch unreachable;
    resource.setHandler(*Self, handlePointerRequest, handlePointerDestroy, self);
    self.notifySeatResourceCount();
    const stored = &self.pointer_resources.items[self.pointer_resources.items.len - 1];
    if (!self.pointerResourceActive(stored.*)) return;
    const surface = self.pointerSurface() orelse return;
    if (resource.getClient() == surface.getClient()) {
        const serial = self.display.nextSerial();
        self.latest_pointer_enter = .{
            .client = surface.getClient(),
            .serial = serial,
        };
        self.sendPointerEnterTo(stored, surface, serial);
        if (resource.getVersion() >= wl.Pointer.frame_since_version) resource.sendFrame();
    }
}

fn createTouch(self: *Self, seat: *wl.Seat, id: u32) void {
    const resource = wl.Touch.create(seat.getClient(), seat.getVersion(), id) catch {
        seat.postNoMemory();
        return;
    };
    const generation = self.next_touch_resource_generation;
    self.touch_resources.append(self.allocator, .{
        .resource = resource,
        .generation = generation,
        .capability_generation = self.touch_capability_generation,
    }) catch {
        resource.postNoMemory();
        resource.destroy();
        return;
    };
    self.next_touch_resource_generation = std.math.add(u64, generation, 1) catch unreachable;
    resource.setHandler(*Self, handleTouchRequest, handleTouchDestroy, self);
    self.notifySeatResourceCount();
}

fn handleKeyboardRequest(resource: *wl.Keyboard, request: wl.Keyboard.Request, _: *Self) void {
    switch (request) {
        .release => resource.destroy(),
    }
}

fn handleKeyboardDestroy(resource: *wl.Keyboard, self: *Self) void {
    for (self.keyboard_resources.items, 0..) |candidate, index| {
        if (candidate.resource != resource) continue;
        _ = self.keyboard_resources.orderedRemove(index);
        self.notifySeatResourceCount();
        return;
    }
    unreachable;
}

fn handlePointerRequest(resource: *wl.Pointer, request: wl.Pointer.Request, self: *Self) void {
    switch (request) {
        .set_cursor => |set| if (self.pointerResourceIsActive(resource)) self.setCursor(
            resource,
            set.serial,
            set.surface,
            set.hotspot_x,
            set.hotspot_y,
        ),
        .release => resource.destroy(),
    }
}

fn handlePointerDestroy(resource: *wl.Pointer, self: *Self) void {
    for (self.pointer_resources.items, 0..) |candidate, index| {
        if (candidate.resource != resource) continue;
        _ = self.pointer_resources.orderedRemove(index);
        self.notifySeatResourceCount();
        return;
    }
    unreachable;
}

fn handleTouchRequest(resource: *wl.Touch, request: wl.Touch.Request, _: *Self) void {
    switch (request) {
        .release => resource.destroy(),
    }
}

fn handleTouchDestroy(resource: *wl.Touch, self: *Self) void {
    const client = resource.getClient();
    for (self.touch_frame_resources.items, 0..) |candidate, index| {
        if (candidate != resource) continue;
        _ = self.touch_frame_resources.orderedRemove(index);
        break;
    }
    for (self.touch_resources.items, 0..) |candidate, index| {
        if (candidate.resource != resource) continue;
        _ = self.touch_resources.orderedRemove(index);
        var client_has_resource = false;
        for (self.touch_resources.items) |remaining| {
            if (remaining.resource.getClient() == client) {
                client_has_resource = true;
                break;
            }
        }
        if (!client_has_resource) {
            for (self.touch_points.items) |*point| {
                const target = point.target orelse continue;
                if (target.client == client) point.target = null;
            }
        }
        self.notifySeatResourceCount();
        return;
    }
    unreachable;
}

fn focusedSurface(self: *Self) ?*wl.Surface {
    return Surface.resourceFor(self.surface_store, self.focus orelse return null);
}

fn keyboardDeliverySurfaceId(self: *const Self) ?Surface.Id {
    if (self.keyboard_grab) |grab| if (grab.surface) |surface_id| return surface_id;
    return self.focus;
}

fn keyboardDeliverySurface(self: *Self) ?*wl.Surface {
    return Surface.resourceFor(
        self.surface_store,
        self.keyboardDeliverySurfaceId() orelse return null,
    );
}

fn hasKeyboardCapability(self: *const Self) bool {
    return (self.keyboard_available or self.virtual_keyboard_count > 0) and self.keymap != null;
}

fn hasPointerCapability(self: *const Self) bool {
    return self.pointer_available or self.virtual_pointer_count > 0;
}

fn keyboardResourceActive(self: *const Self, entry: KeyboardResource) bool {
    return capabilityResourceActive(
        self.hasKeyboardCapability(),
        self.keyboard_capability_generation,
        entry.capability_generation,
    );
}

fn pointerResourceActive(self: *const Self, entry: PointerResource) bool {
    return capabilityResourceActive(
        self.hasPointerCapability(),
        self.pointer_capability_generation,
        entry.capability_generation,
    );
}

fn pointerResourceIsActive(self: *const Self, resource: *wl.Pointer) bool {
    const handle = self.pointerHandle(resource) orelse return false;
    return self.pointerHandleIsActive(handle);
}

fn touchResourceActive(self: *const Self, entry: TouchResource) bool {
    return capabilityResourceActive(
        self.touch_available,
        self.touch_capability_generation,
        entry.capability_generation,
    );
}

fn beginCapabilityGeneration(generation: *u64, ever_available: *bool) void {
    generation.* = std.math.add(u64, generation.*, 1) catch unreachable;
    ever_available.* = true;
}

fn capabilityResourceActive(available: bool, current: u64, resource: u64) bool {
    return available and resource == current;
}

fn findTouchPoint(self: *const Self, id: i32) ?usize {
    for (self.touch_points.items, 0..) |point, index| {
        if (point.id == id) return index;
    }
    return null;
}

fn touchPoint(self: *const Self, id: i32) ?*const TouchPoint {
    return &self.touch_points.items[self.findTouchPoint(id) orelse return null];
}

fn cancelTouchPointState(
    points: *std.ArrayList(TouchPoint),
    id: i32,
) ?TouchCancellation {
    const cancelled_index = for (points.items, 0..) |point, index| {
        if (point.id == id) break index;
    } else return null;
    const cancelled = points.orderedRemove(cancelled_index);
    const client = if (cancelled.target) |target| target.client else return null;
    var max_resource_generation = cancelled.target.?.max_resource_generation;
    for (points.items) |*point| {
        const target = point.target orelse continue;
        if (target.client != client) continue;
        max_resource_generation = @max(max_resource_generation, target.max_resource_generation);
        point.target = null;
    }
    return .{
        .client = client,
        .max_resource_generation = max_resource_generation,
    };
}

fn latestTouchResourceGeneration(self: *const Self, client: *wl.Client) ?u64 {
    var latest: ?u64 = null;
    for (self.touch_resources.items) |entry| {
        if (!self.touchResourceActive(entry)) continue;
        if (entry.resource.getClient() == client) latest = entry.generation;
    }
    return latest;
}

fn hasTouchResourceVersion(
    self: *const Self,
    client: *wl.Client,
    version: u32,
    max_generation: u64,
) bool {
    for (self.touch_resources.items) |entry| {
        if (self.touchResourceActive(entry) and
            touchResourceInSequence(entry.generation, max_generation) and
            entry.resource.getClient() == client and
            entry.resource.getVersion() >= version) return true;
    }
    return false;
}

fn markTouchFrame(self: *Self, resource: *wl.Touch) error{OutOfMemory}!void {
    for (self.touch_frame_resources.items) |pending| {
        if (pending == resource) return;
    }
    try self.touch_frame_resources.append(self.allocator, resource);
}

fn touchResourceInSequence(generation: u64, max_generation: u64) bool {
    return generation <= max_generation;
}

fn capabilities(self: *const Self) wl.Seat.Capability {
    return .{
        .keyboard = self.hasKeyboardCapability(),
        .pointer = self.hasPointerCapability(),
        .touch = self.touch_available,
    };
}

fn broadcastCapabilities(self: *Self) void {
    for (self.seat_resources.items) |resource| resource.sendCapabilities(self.capabilities());
}

fn sendKeymap(self: *Self, resource: *wl.Keyboard) void {
    const keymap = self.keymap orelse return;
    resource.sendKeymap(keymap.format, keymap.file.handle, keymap.size);
}

fn sendRepeatInfo(self: *const Self, resource: *wl.Keyboard) void {
    if (resource.getVersion() >= wl.Keyboard.repeat_info_since_version) {
        resource.sendRepeatInfo(self.repeat_info.rate, self.repeat_info.delay);
    }
}

fn sendEnter(self: *Self) void {
    if (self.keymap == null) return;
    const surface = self.keyboardDeliverySurface() orelse return;
    const serial = self.display.nextSerial();
    self.user_action_serials.recordSelection(surface.getClient(), serial);
    for (self.keyboard_resources.items) |entry| {
        if (!self.keyboardResourceActive(entry)) continue;
        const resource = entry.resource;
        if (resource.getClient() == surface.getClient()) {
            self.sendEnterTo(resource, surface, serial);
        }
    }
}

fn sendEnterTo(self: *Self, resource: *wl.Keyboard, surface: *wl.Surface, serial: u32) void {
    var keys = self.pressed_keys.asWaylandArray();
    resource.sendEnter(serial, surface, &keys);
    self.sendModifiers(resource, serial);
}

fn sendLeave(self: *Self) void {
    const surface = self.keyboardDeliverySurface() orelse return;
    const serial = self.display.nextSerial();
    for (self.keyboard_resources.items) |entry| {
        if (!self.keyboardResourceActive(entry)) continue;
        const resource = entry.resource;
        if (resource.getClient() == surface.getClient()) resource.sendLeave(serial, surface);
    }
}

fn sendModifiers(self: *const Self, resource: *wl.Keyboard, serial: u32) void {
    const modifiers = self.modifier_state.current;
    resource.sendModifiers(
        serial,
        modifiers.depressed,
        modifiers.latched,
        modifiers.locked,
        modifiers.group,
    );
}

fn updatePointerFocus(self: *Self, focus: ?PointerFocus, motion_time: ?u32) void {
    const changed = if (self.pointer_focus) |current|
        if (focus) |next| !std.meta.eql(current.surface_id, next.surface_id) else true
    else
        focus != null;
    if (changed) {
        const old_cursor = self.cursorInfo();
        const drag_cursor = if (self.drag_cursor_client) |client|
            if (self.activeCursorOwnedBy(client)) self.active_cursor else null
        else
            null;
        self.active_cursor = drag_cursor;
        self.sendPointerLeave();
        self.pointer_focus = focus;
        if (self.drag_cursor_client == null) self.pointer_cursor_configured = false;
        self.latest_pointer_enter = null;
        self.sendPointerEnter();
        if (focus == null and self.drag_cursor_client == null) {
            self.active_cursor = if (self.cursor_controller) |controller| controller.cursor else null;
        }
        self.notifyCursorChanged(old_cursor);
        return;
    }
    self.pointer_focus = focus;
    const time = motion_time orelse return;
    const surface = self.pointerSurface() orelse return;
    const position = self.pointer_focus orelse return;
    for (self.pointer_resources.items) |entry| {
        if (!self.pointerResourceActive(entry)) continue;
        const resource = entry.resource;
        if (resource.getClient() == surface.getClient()) {
            resource.sendMotion(time, fixed(position.x), fixed(position.y));
        }
    }
}

fn pointerSurface(self: *Self) ?*wl.Surface {
    const focus = self.pointer_focus orelse return null;
    return Surface.resourceFor(self.surface_store, focus.surface_id);
}

fn sendPointerEnter(self: *Self) void {
    const surface = self.pointerSurface() orelse return;
    const serial = self.display.nextSerial();
    self.latest_pointer_enter = .{
        .client = surface.getClient(),
        .serial = serial,
    };
    for (self.pointer_resources.items) |*entry| {
        if (!self.pointerResourceActive(entry.*)) continue;
        const resource = entry.resource;
        if (resource.getClient() == surface.getClient()) {
            self.sendPointerEnterTo(entry, surface, serial);
        }
    }
}

fn sendPointerEnterTo(
    self: *const Self,
    entry: *PointerResource,
    surface: *wl.Surface,
    serial: u32,
) void {
    const position = self.pointer_focus orelse return;
    entry.enter_serial = serial;
    const resource = entry.resource;
    resource.sendEnter(serial, surface, fixed(position.x), fixed(position.y));
}

fn sendPointerLeave(self: *Self) void {
    const surface = self.pointerSurface() orelse return;
    const serial = self.display.nextSerial();
    for (self.pointer_resources.items) |*entry| {
        if (!self.pointerResourceActive(entry.*)) continue;
        const resource = entry.resource;
        if (resource.getClient() != surface.getClient()) continue;
        entry.enter_serial = null;
        resource.sendLeave(serial, surface);
        if (resource.getVersion() >= wl.Pointer.frame_since_version) resource.sendFrame();
    }
}

fn setPointerPosition(self: *Self, x: f64, y: f64) void {
    std.debug.assert(std.math.isFinite(x) and std.math.isFinite(y));
    const old_cursor = self.cursorInfo();
    self.pointer_position = .{ .x = x, .y = y };
    self.notifyCursorChanged(old_cursor);
}

fn setCursor(
    self: *Self,
    pointer: *wl.Pointer,
    serial: u32,
    surface_resource: ?*wl.Surface,
    hotspot_x: i32,
    hotspot_y: i32,
) void {
    const manager_controller = self.isUnfocusedCursorController(pointer.getClient());
    const drag_controller = if (self.drag_cursor_client) |client|
        client == pointer.getClient()
    else
        false;
    const controller = manager_controller or drag_controller;
    const enter = self.latest_pointer_enter;
    if (!controller and (enter == null or enter.?.client != pointer.getClient() or enter.?.serial != serial)) return;
    const focused_client = if (self.pointerSurface()) |surface|
        surface.getClient() == pointer.getClient()
    else
        false;
    if (!controller and !focused_client and !self.activeCursorOwnedBy(pointer.getClient())) return;

    const cursor_surface = if (surface_resource) |resource| cursor: {
        const surface = Surface.fromResource(resource);
        if (surface.assignedRole()) |role| {
            if (role != .cursor or !CursorSurface.ownedBy(surface, self)) {
                pointer.postError(.role, "wl_surface already has another role");
                return;
            }
        } else {
            CursorSurface.create(self, surface) catch |err| switch (err) {
                error.OutOfMemory => {
                    pointer.postNoMemory();
                    return;
                },
                error.RoleUnavailable => {
                    pointer.postError(.role, "wl_surface is unavailable for the cursor role");
                    return;
                },
            };
        }
        break :cursor surface;
    } else null;

    const requested: ?ActiveCursor = if (cursor_surface) |surface| .{ .surface = .{
        .surface_id = surface.handle(),
        .hotspot_x = hotspot_x,
        .hotspot_y = hotspot_y,
    } } else null;
    const old_cursor = self.cursorInfo();
    if (manager_controller and !drag_controller) {
        self.cursor_controller.?.cursor = requested;
        self.cursor_controller.?.configured = true;
        if (self.pointer_focus) |focus| {
            const focused_surface = self.surface_store.get(focus.surface_id);
            if (focused_surface == null or focused_surface.?.resource.getClient() != pointer.getClient()) return;
        }
    }
    self.pointer_cursor_configured = true;
    self.active_cursor = requested;
    self.notifyCursorChanged(old_cursor);
}

pub fn setCursorShape(
    self: *Self,
    client: *wl.Client,
    serial: u32,
    shape: ShapeCursor,
) void {
    std.debug.assert(shape.client == client);
    const manager_controller = self.isUnfocusedCursorController(client);
    const drag_controller = if (self.drag_cursor_client) |drag_client|
        drag_client == client
    else
        false;
    const controller = manager_controller or drag_controller;
    const enter = self.latest_pointer_enter;
    if (!controller and (enter == null or enter.?.client != client or enter.?.serial != serial)) return;
    const focused_client = if (self.pointerSurface()) |surface|
        surface.getClient() == client
    else
        false;
    if (!controller and !focused_client and !self.activeCursorOwnedBy(client)) return;

    const requested: ActiveCursor = .{ .shape = shape };
    const old_cursor = self.cursorInfo();
    if (manager_controller and !drag_controller) {
        self.cursor_controller.?.cursor = requested;
        self.cursor_controller.?.configured = true;
        if (self.pointer_focus) |focus| {
            const focused_surface = self.surface_store.get(focus.surface_id);
            if (focused_surface == null or focused_surface.?.resource.getClient() != client) return;
        }
    }
    self.pointer_cursor_configured = true;
    self.active_cursor = requested;
    self.notifyCursorChanged(old_cursor);
}

pub fn clearCursorShapes(self: *Self) void {
    const old_cursor = self.cursorInfo();
    self.compositor_cursor = null;
    self.default_cursor = null;
    if (self.active_cursor) |cursor| switch (cursor) {
        .surface => {},
        .shape => self.active_cursor = null,
    };
    if (self.cursor_controller) |*controller| if (controller.cursor) |cursor| switch (cursor) {
        .surface => {},
        .shape => controller.cursor = null,
    };
    self.notifyCursorChanged(old_cursor);
}

fn activeCursorOwnedBy(self: *Self, client: *wl.Client) bool {
    const cursor = self.active_cursor orelse return false;
    return switch (cursor) {
        .surface => |surface| if (Surface.resourceFor(self.surface_store, surface.surface_id)) |resource|
            resource.getClient() == client
        else
            false,
        .shape => |shape| shape.client == client,
    };
}

fn restoreControllerCursor(self: *Self) void {
    const old_cursor = self.cursorInfo();
    self.active_cursor = if (self.cursor_controller) |controller| controller.cursor else null;
    self.notifyCursorChanged(old_cursor);
}

fn clearCursor(self: *Self) void {
    if (self.active_cursor == null) return;
    const old_cursor = self.cursorInfo();
    self.active_cursor = null;
    self.notifyCursorChanged(old_cursor);
}

fn cursorSurfaceCommitted(self: *Self, id: Surface.Id, info: Surface.CommitInfo) void {
    var repaint = false;
    if (self.active_cursor) |*cursor| switch (cursor.*) {
        .shape => {},
        .surface => |*surface| if (std.meta.eql(surface.surface_id, id)) {
            surface.hotspot_x -|= info.offset_x;
            surface.hotspot_y -|= info.offset_y;
            repaint = true;
        },
    };
    if (self.cursor_controller) |*controller| if (controller.cursor) |*remembered| switch (remembered.*) {
        .shape => {},
        .surface => |*surface| if (std.meta.eql(surface.surface_id, id)) {
            surface.hotspot_x -|= info.offset_x;
            surface.hotspot_y -|= info.offset_y;
        },
    };
    if (repaint) self.requestRepaint();
}

fn cursorSurfaceDestroyed(self: *Self, id: Surface.Id) void {
    if (self.active_cursor) |cursor| {
        switch (cursor) {
            .shape => {},
            .surface => |surface| {
                if (std.meta.eql(surface.surface_id, id)) self.clearCursor();
            },
        }
    }
    if (self.cursor_controller) |*controller| if (controller.cursor) |cursor| {
        switch (cursor) {
            .shape => {},
            .surface => |surface| {
                if (std.meta.eql(surface.surface_id, id)) controller.cursor = null;
            },
        }
    };
}

fn requestRepaint(self: *Self) void {
    if (self.repaint_listener) |listener| listener.request(listener.context);
}

fn notifyCursorChanged(self: *Self, old_cursor: ?CursorInfo) void {
    const listener = self.repaint_listener orelse return;
    listener.cursor_changed(listener.context, old_cursor, self.cursorInfo());
}

fn notifyKeyboardFocus(self: *Self) void {
    for (self.keyboard_focus_listeners.items) |listener| {
        listener.changed(listener.context, self.keyboardFocusedClient());
    }
}

const CursorSurface = struct {
    seat: *Self,
    surface_id: Surface.Id,

    fn create(seat: *Self, surface: *Surface) error{ OutOfMemory, RoleUnavailable }!void {
        const self = seat.allocator.create(CursorSurface) catch return error.OutOfMemory;
        errdefer seat.allocator.destroy(self);
        self.* = .{
            .seat = seat,
            .surface_id = surface.handle(),
        };
        surface.reserveRole(.cursor, .{
            .context = self,
            .before_commit = beforeCommit,
            .after_commit = afterCommit,
            .surface_destroyed = surfaceDestroyed,
            .role_tag = .pointer_cursor,
        }) catch return error.RoleUnavailable;
        errdefer surface.releaseRole(self);
        surface.assignReservedRole(.cursor, self) catch return error.RoleUnavailable;
        seat.cursor_surface_count += 1;
    }

    fn ownedBy(surface: *Surface, seat: *Self) bool {
        const identity = surface.roleIdentity(.cursor) orelse return false;
        if (identity.tag != .pointer_cursor) return false;
        const cursor_surface: *CursorSurface = @ptrCast(@alignCast(identity.context));
        return cursor_surface.seat == seat;
    }

    fn beforeCommit(_: *anyopaque, _: Surface.CommitInfo) Surface.CommitAction {
        return .apply;
    }

    fn afterCommit(context: *anyopaque, info: Surface.CommitInfo) void {
        const self: *CursorSurface = @ptrCast(@alignCast(context));
        self.seat.cursorSurfaceCommitted(self.surface_id, info);
    }

    fn surfaceDestroyed(context: *anyopaque) void {
        const self: *CursorSurface = @ptrCast(@alignCast(context));
        const seat = self.seat;
        seat.cursorSurfaceDestroyed(self.surface_id);
        std.debug.assert(seat.cursor_surface_count > 0);
        seat.cursor_surface_count -= 1;
        seat.allocator.destroy(self);
    }
};

pub fn cursorCoordinate(value: f64, hotspot: i32) i32 {
    const coordinate: i64 = @intFromFloat(@floor(value));
    return @intCast(std.math.clamp(
        coordinate - @as(i64, hotspot),
        std.math.minInt(i32),
        std.math.maxInt(i32),
    ));
}

fn fixed(value: f64) wl.Fixed {
    const minimum = @as(f64, @floatFromInt(std.math.minInt(i32))) / 256.0;
    const maximum = @as(f64, @floatFromInt(std.math.maxInt(i32))) / 256.0;
    return wl.Fixed.fromDouble(std.math.clamp(value, minimum, maximum));
}

fn adjustedPointerGrabFocus(
    grab: ?PointerGrab,
    current: ?PointerFocus,
    old_position: ?PointerPosition,
    candidate: ?PointerFocus,
    x: f64,
    y: f64,
) ?PointerFocus {
    const active = grab orelse return candidate;
    if (active.suppressed) return null;
    if (candidate) |focus| {
        if (std.meta.eql(focus.surface_id, active.surface_id)) return focus;
    }
    const focus = current orelse return null;
    std.debug.assert(std.meta.eql(focus.surface_id, active.surface_id));
    const position = old_position orelse return focus;
    return .{
        .surface_id = active.surface_id,
        .x = focus.x + x - position.x,
        .y = focus.y + y - position.y,
    };
}

test "cursor position accounts for hotspot and fractional motion" {
    try std.testing.expectEqual(@as(i32, 8), cursorCoordinate(12.75, 4));
    try std.testing.expectEqual(@as(i32, -5), cursorCoordinate(0.25, 5));
    try std.testing.expectEqual(
        std.math.minInt(i32),
        cursorCoordinate(-0.25, std.math.maxInt(i32)),
    );
}

test "default cursor only bridges a pending focused cursor choice" {
    try std.testing.expect(defaultCursorVisible(true, false, false, false));
    try std.testing.expect(!defaultCursorVisible(true, true, false, false));
    try std.testing.expect(defaultCursorVisible(false, false, false, false));
    try std.testing.expect(!defaultCursorVisible(false, false, true, false));
    try std.testing.expect(!defaultCursorVisible(false, false, false, true));
}

test "protocol serial ordering handles wraparound" {
    try std.testing.expect(!serialIsOlder(10, 10));
    try std.testing.expect(!serialIsOlder(11, 10));
    try std.testing.expect(serialIsOlder(9, 10));
    try std.testing.expect(!serialIsOlder(1, std.math.maxInt(u32)));
    try std.testing.expect(serialIsOlder(std.math.maxInt(u32), 1));
}

test "virtual modifier teardown restores only the superseded physical state" {
    const physical: Modifiers = .{ .depressed = 1, .locked = 2 };
    const virtual_a: Modifiers = .{ .depressed = 4, .latched = 8 };
    const virtual_b: Modifiers = .{ .depressed = 16, .group = 1 };
    var owner_a: u8 = 0;
    var owner_b: u8 = 0;
    var state: ModifierState = .{};

    state.setPhysical(physical);
    state.setVirtual(&owner_a, virtual_a);
    try std.testing.expect(state.clearVirtual(&owner_a));
    try std.testing.expectEqual(physical, state.current);
    try std.testing.expect(!state.clearVirtual(&owner_a));

    state.setVirtual(&owner_a, virtual_a);
    state.setPhysical(physical);
    try std.testing.expect(!state.clearVirtual(&owner_a));
    try std.testing.expectEqual(physical, state.current);

    state.setVirtual(&owner_a, virtual_a);
    state.setVirtual(&owner_b, virtual_b);
    try std.testing.expect(!state.clearVirtual(&owner_a));
    try std.testing.expectEqual(virtual_b, state.current);
    try std.testing.expect(state.clearVirtual(&owner_b));
    try std.testing.expectEqual(physical, state.current);
}

test "seat capability generations invalidate existing input resources" {
    var generation: u64 = 0;
    var ever_available = false;

    beginCapabilityGeneration(&generation, &ever_available);
    try std.testing.expect(ever_available);
    try std.testing.expect(capabilityResourceActive(true, generation, generation));
    try std.testing.expect(!capabilityResourceActive(false, generation, generation));

    const previous = generation;
    beginCapabilityGeneration(&generation, &ever_available);
    try std.testing.expect(!capabilityResourceActive(true, generation, previous));
    try std.testing.expect(capabilityResourceActive(true, generation, generation));
}

test "touch resources bound after down do not join the contact sequence" {
    try std.testing.expect(touchResourceInSequence(4, 4));
    try std.testing.expect(!touchResourceInSequence(5, 4));
}

test "touch point cancellation preserves unrelated client streams" {
    const client_a: *wl.Client = @ptrFromInt(0x1000);
    const client_b: *wl.Client = @ptrFromInt(0x2000);
    var points: std.ArrayList(TouchPoint) = .empty;
    defer points.deinit(std.testing.allocator);
    try points.appendSlice(std.testing.allocator, &.{
        .{ .id = 1, .target = .{ .surface_id = .{ .index = 1, .generation = 1 }, .client = client_a, .offset_x = 0, .offset_y = 0, .max_resource_generation = 2 } },
        .{ .id = 2, .target = .{ .surface_id = .{ .index = 2, .generation = 1 }, .client = client_a, .offset_x = 0, .offset_y = 0, .max_resource_generation = 4 } },
        .{ .id = 3, .target = .{ .surface_id = .{ .index = 3, .generation = 1 }, .client = client_b, .offset_x = 0, .offset_y = 0, .max_resource_generation = 3 } },
        .{ .id = 4, .target = null },
    });

    const cancellation = cancelTouchPointState(&points, 1).?;
    try std.testing.expectEqual(client_a, cancellation.client);
    try std.testing.expectEqual(@as(u64, 4), cancellation.max_resource_generation);
    try std.testing.expectEqual(@as(usize, 3), points.items.len);
    try std.testing.expectEqual(@as(i32, 2), points.items[0].id);
    try std.testing.expect(points.items[0].target == null);
    try std.testing.expectEqual(client_b, points.items[1].target.?.client);
    try std.testing.expect(points.items[2].target == null);

    try std.testing.expect(cancelTouchPointState(&points, 4) == null);
    try std.testing.expectEqual(@as(usize, 2), points.items.len);
    try std.testing.expect(cancelTouchPointState(&points, 99) == null);
    try std.testing.expectEqual(@as(usize, 2), points.items.len);
}

test "implicit pointer grab freezes focus to the pressed surface" {
    const grabbed_surface: Surface.Id = .{ .index = 1, .generation = 2 };
    const other_surface: Surface.Id = .{ .index = 3, .generation = 4 };
    const adjusted = adjustedPointerGrabFocus(
        .{ .surface_id = grabbed_surface },
        .{ .surface_id = grabbed_surface, .x = 10, .y = 20 },
        .{ .x = 100, .y = 200 },
        .{ .surface_id = other_surface, .x = 1, .y = 2 },
        103,
        196,
    ).?;
    try std.testing.expect(std.meta.eql(grabbed_surface, adjusted.surface_id));
    try std.testing.expectEqual(@as(f64, 13), adjusted.x);
    try std.testing.expectEqual(@as(f64, 16), adjusted.y);
}

test "implicit pointer grab uses current coordinates for its surface" {
    const surface_id: Surface.Id = .{ .index = 1, .generation = 2 };
    const candidate: PointerFocus = .{ .surface_id = surface_id, .x = 4, .y = 5 };
    try std.testing.expectEqual(
        candidate,
        adjustedPointerGrabFocus(
            .{ .surface_id = surface_id },
            .{ .surface_id = surface_id, .x = 10, .y = 20 },
            .{ .x = 100, .y = 200 },
            candidate,
            103,
            196,
        ).?,
    );
}

test "suppressed pointer grab cannot retarget focus" {
    const grabbed_surface: Surface.Id = .{ .index = 1, .generation = 2 };
    const other_surface: Surface.Id = .{ .index = 3, .generation = 4 };
    try std.testing.expectEqual(
        @as(?PointerFocus, null),
        adjustedPointerGrabFocus(
            .{ .surface_id = grabbed_surface, .suppressed = true },
            null,
            .{ .x = 100, .y = 200 },
            .{ .surface_id = other_surface, .x = 1, .y = 2 },
            103,
            196,
        ),
    );
}

test "pointer focus passes through without a grab" {
    const surface_id: Surface.Id = .{ .index = 1, .generation = 2 };
    const candidate: PointerFocus = .{ .surface_id = surface_id, .x = 4, .y = 5 };
    try std.testing.expectEqual(
        candidate,
        adjustedPointerGrabFocus(null, null, null, candidate, 10, 20).?,
    );
}
