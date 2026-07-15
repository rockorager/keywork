//! Policy-neutral boundary between River protocol transactions and application hosts.

const std = @import("std");

pub const Dimensions = struct {
    width: i32,
    height: i32,
};

pub const DimensionsHint = struct {
    min_width: i32,
    min_height: i32,
    max_width: i32,
    max_height: i32,
};

pub const Point = struct {
    x: i32,
    y: i32,
};

pub const DecorationHint = enum {
    only_supports_csd,
    prefers_csd,
    prefers_ssd,
    no_preference,
};

pub const PresentationMode = enum {
    vsync,
    async,
};

pub const Window = struct {
    id: u32,
    title: ?[]const u8 = null,
    app_id: ?[]const u8 = null,
    identifier: ?[]const u8 = null,
    parent: ?u32 = null,
    dimensions: ?Dimensions = null,
    dimensions_hint: ?DimensionsHint = null,
    decoration_hint: ?DecorationHint = null,
    unreliable_pid: ?i32 = null,
    presentation_hint: ?PresentationMode = null,
};

pub const Output = struct {
    id: u32,
    wl_output: ?u32 = null,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const Seat = struct {
    id: u32,
    wl_seat: ?u32 = null,
    pointer_position: ?Point = null,
    modifiers: ?u32 = null,
};

pub const SeatWindowEvent = struct {
    seat: u32,
    window: u32,
};

pub const Event = union(enum) {
    session_locked,
    session_unlocked,
    window_added: u32,
    window_closed: u32,
    output_added: u32,
    output_removed: u32,
    seat_added: u32,
    seat_removed: u32,
    pointer_move_requested: SeatWindowEvent,
    pointer_resize_requested: struct { window: u32, seat: u32, edges: u32 },
    show_window_menu_requested: struct { window: u32, x: i32, y: i32 },
    maximize_requested: u32,
    unmaximize_requested: u32,
    fullscreen_requested: struct { window: u32, output: ?u32 },
    exit_fullscreen_requested: u32,
    minimize_requested: u32,
    pointer_enter: SeatWindowEvent,
    pointer_leave: u32,
    window_interaction: SeatWindowEvent,
    op_delta: struct { seat: u32, dx: i32, dy: i32 },
    op_release: u32,
    ate_unbound_key: u32,
    modifiers_update: struct { seat: u32, old: u32, new: u32 },
};

pub const Context = struct {
    windows: []const Window,
    outputs: []const Output,
    seats: []const Seat,
    events: []const Event,
    session_locked: bool,
    window_management_version: u32,
    xkb_bindings_version: u32,
};

pub const Edges = struct {
    top: bool = false,
    bottom: bool = false,
    left: bool = false,
    right: bool = false,
};

pub const Capabilities = struct {
    window_menu: bool = false,
    maximize: bool = false,
    fullscreen: bool = false,
    minimize: bool = false,
};

pub const WindowTarget = struct { window: u32 };
pub const SeatTarget = struct { seat: u32 };
pub const StackTarget = struct { window: u32, other: u32 };

pub const ManageCommand = union(enum) {
    close: WindowTarget,
    propose_dimensions: struct { window: u32, width: i32, height: i32 },
    use_csd: WindowTarget,
    use_ssd: WindowTarget,
    set_tiled: struct { window: u32, edges: Edges },
    inform_resize_start: WindowTarget,
    inform_resize_end: WindowTarget,
    set_capabilities: struct { window: u32, capabilities: Capabilities },
    inform_maximized: WindowTarget,
    inform_unmaximized: WindowTarget,
    inform_fullscreen: WindowTarget,
    inform_not_fullscreen: WindowTarget,
    fullscreen: struct { window: u32, output: u32 },
    exit_fullscreen: WindowTarget,
    set_dimension_bounds: struct { window: u32, max_width: i32, max_height: i32 },
    focus_window: struct { seat: u32, window: u32 },
    clear_focus: SeatTarget,
    op_start_pointer: SeatTarget,
    op_end: SeatTarget,
    pointer_warp: struct { seat: u32, x: i32, y: i32 },
    set_xcursor_theme: struct { seat: u32, name: [:0]const u8, size: u32 },
    ensure_next_key_eaten: SeatTarget,
    cancel_ensure_next_key_eaten: SeatTarget,
    modifiers_watch: struct { seat: u32, modifiers: u32 },
    exit_session,
};

pub const Color = struct {
    r: u32,
    g: u32,
    b: u32,
    a: u32,
};

pub const RenderCommand = union(enum) {
    hide: WindowTarget,
    show: WindowTarget,
    set_borders: struct { window: u32, edges: Edges, width: i32, color: Color },
    set_position: struct { window: u32, x: i32, y: i32 },
    place_top: WindowTarget,
    place_bottom: WindowTarget,
    place_above: StackTarget,
    place_below: StackTarget,
    set_clip_box: struct { window: u32, x: i32, y: i32, width: i32, height: i32 },
    set_content_clip_box: struct { window: u32, x: i32, y: i32, width: i32, height: i32 },
    set_presentation_mode: struct { output: u32, mode: PresentationMode },
};

pub const Binding = struct {
    id: []const u8,
    keysym: u32,
    modifiers: u32,
    layout: ?u32 = null,
};

pub const PointerBinding = struct {
    id: []const u8,
    button: u32,
    modifiers: u32,
};

pub const BindingEvent = enum {
    pressed,
    released,
    stop_repeat,
};

pub const Host = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        refresh: *const fn (ptr: *anyopaque) anyerror!void,
        bindings: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]Binding,
        pointer_bindings: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]PointerBinding,
        manage: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, context: Context) anyerror![]ManageCommand,
        render: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, context: Context) anyerror![]RenderCommand,
        invoke_binding: *const fn (ptr: *anyopaque, id: []const u8, event: BindingEvent, seat: u32) anyerror!void,
        invoke_pointer_binding: *const fn (ptr: *anyopaque, id: []const u8, event: BindingEvent, seat: u32) anyerror!void,
        bind_invalidator: *const fn (
            ptr: *anyopaque,
            invalidator_ptr: *anyopaque,
            invalidate: *const fn (ptr: *anyopaque) anyerror!void,
        ) anyerror!void,
        unbind_invalidator: *const fn (ptr: *anyopaque) void,
    };

    pub fn refresh(self: Host) !void {
        try self.vtable.refresh(self.ptr);
    }

    pub fn bindings(self: Host, allocator: std.mem.Allocator) ![]Binding {
        return self.vtable.bindings(self.ptr, allocator);
    }

    pub fn pointerBindings(self: Host, allocator: std.mem.Allocator) ![]PointerBinding {
        return self.vtable.pointer_bindings(self.ptr, allocator);
    }

    pub fn manage(self: Host, allocator: std.mem.Allocator, context: Context) ![]ManageCommand {
        return self.vtable.manage(self.ptr, allocator, context);
    }

    pub fn render(self: Host, allocator: std.mem.Allocator, context: Context) ![]RenderCommand {
        return self.vtable.render(self.ptr, allocator, context);
    }

    pub fn invokeBinding(self: Host, id: []const u8, event: BindingEvent, seat: u32) !void {
        try self.vtable.invoke_binding(self.ptr, id, event, seat);
    }

    pub fn invokePointerBinding(self: Host, id: []const u8, event: BindingEvent, seat: u32) !void {
        try self.vtable.invoke_pointer_binding(self.ptr, id, event, seat);
    }

    pub fn bindInvalidator(
        self: Host,
        invalidator_ptr: *anyopaque,
        invalidate: *const fn (ptr: *anyopaque) anyerror!void,
    ) !void {
        try self.vtable.bind_invalidator(self.ptr, invalidator_ptr, invalidate);
    }

    pub fn unbindInvalidator(self: Host) void {
        self.vtable.unbind_invalidator(self.ptr);
    }
};

pub fn freeBindings(allocator: std.mem.Allocator, bindings: []Binding) void {
    for (bindings) |binding| allocator.free(binding.id);
    allocator.free(bindings);
}

pub fn freePointerBindings(allocator: std.mem.Allocator, bindings: []PointerBinding) void {
    for (bindings) |binding| allocator.free(binding.id);
    allocator.free(bindings);
}
