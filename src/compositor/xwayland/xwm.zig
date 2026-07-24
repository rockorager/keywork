//! X11 window-manager bootstrap and event-loop integration.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const DataDevice = @import("../wayland/data_device.zig");
const PrimarySelection = @import("../wayland/primary_selection.zig");
const Surface = @import("../wayland/surface.zig");
const Xdnd = @import("dnd.zig");
const XSelection = @import("selection.zig");

const c = @import("xcb.zig").c;
const wl = wayland.server.wl;
const log = std.log.scoped(.xwm);

const XfixesInfo = struct {
    event_base: u8,
    client_disconnect_mode: bool,
};

allocator: std.mem.Allocator,
connection: *c.xcb_connection_t,
screen: *c.xcb_screen_t,
event_source: *wl.EventSource,
wm_window: c.xcb_window_t,
atoms: [atom_count]c.xcb_atom_t,
windows: std.AutoHashMapUnmanaged(WindowId, Window),
serial_windows: std.AutoHashMapUnmanaged(u64, WindowId),
client_list: std.ArrayList(WindowId),
client_stacking: std.ArrayList(WindowId),
focused_window: ?WindowId,
xfixes_event_base: u8,
xres_available: bool,
clipboard_selection: XSelection,
primary_selection: XSelection,
dnd_selection: XSelection,
dnd: Xdnd,
listener: Listener,

pub const WindowId = u32;

pub const Geometry = struct {
    x: i16,
    y: i16,
    width: u16,
    height: u16,
};

pub const Size = struct {
    width: i32 = 0,
    height: i32 = 0,
};

pub const MoveResizeRequest = union(enum) {
    move,
    resize: Edges,
    cancel,

    pub const Edges = packed struct(u4) {
        top: bool = false,
        bottom: bool = false,
        left: bool = false,
        right: bool = false,
    };
};

pub const WindowType = enum {
    desktop,
    dock,
    toolbar,
    menu,
    utility,
    splash,
    dialog,
    dropdown_menu,
    popup_menu,
    tooltip,
    notification,
    combo,
    dnd,
    normal,

    pub fn participatesInWindowManagement(self: WindowType) bool {
        return switch (self) {
            .normal, .dialog, .utility, .toolbar, .menu => true,
            .desktop,
            .dock,
            .splash,
            .dropdown_menu,
            .popup_menu,
            .tooltip,
            .notification,
            .combo,
            .dnd,
            => false,
        };
    }
};

pub const WindowInfo = struct {
    id: WindowId,
    geometry: Geometry,
    override_redirect: bool,
    override_redirect_wants_focus: bool,
    mapped: bool,
    activated: bool,
    surface_id: ?Surface.Id,
    title: ?[:0]const u8,
    app_id: ?[:0]const u8,
    instance: ?[:0]const u8,
    parent: ?WindowId,
    window_type: WindowType,
    min_size: Size,
    max_size: Size,
    can_close: bool,
    unreliable_pid: ?i32,
    modal: bool,
    fullscreen: bool,
    maximized: bool,
    minimized: bool,
    skip_taskbar: bool,
    prefers_server_decorations: bool,

    pub fn participatesInWindowManagement(self: WindowInfo) bool {
        return self.mapped and !self.override_redirect and
            self.window_type.participatesInWindowManagement();
    }

    pub fn appearsInForeignToplevelList(self: WindowInfo) bool {
        return self.participatesInWindowManagement() and !self.skip_taskbar;
    }
};

const Window = struct {
    geometry: Geometry,
    override_redirect: bool,
    override_redirect_wants_focus: bool = true,
    mapped: bool = false,
    serial: ?u64 = null,
    surface_id: ?Surface.Id = null,
    title: ?[:0]u8 = null,
    app_id: ?[:0]u8 = null,
    instance: ?[:0]u8 = null,
    parent: ?WindowId = null,
    window_type: WindowType = .normal,
    min_size: Size = .{},
    max_size: Size = .{},
    accepts_input: bool = true,
    take_focus: bool = false,
    delete_window: bool = false,
    net_wm_state: []c.xcb_atom_t = &.{},
    unreliable_pid: ?i32 = null,
    modal: bool = false,
    fullscreen: bool = false,
    maximized_horz: bool = false,
    maximized_vert: bool = false,
    minimized: bool = false,
    skip_taskbar: bool = false,
    prefers_server_decorations: bool = true,

    fn clientControlsGeometry(self: Window) bool {
        return !self.mapped or self.override_redirect or
            !self.window_type.participatesInWindowManagement();
    }

    fn deinit(self: *Window, allocator: std.mem.Allocator) void {
        if (self.title) |value| allocator.free(value);
        if (self.app_id) |value| allocator.free(value);
        if (self.instance) |value| allocator.free(value);
        allocator.free(self.net_wm_state);
        self.* = undefined;
    }
};

const Atom = enum {
    wm_s0,
    net_wm_cm_s0,
    net_supported,
    net_supporting_wm_check,
    net_client_list,
    net_client_list_stacking,
    net_wm_name,
    net_active_window,
    net_close_window,
    net_wm_moveresize,
    net_wm_state,
    net_wm_state_modal,
    net_wm_state_fullscreen,
    net_wm_state_maximized_horz,
    net_wm_state_maximized_vert,
    net_wm_state_hidden,
    net_wm_state_skip_taskbar,
    net_wm_state_focused,
    net_wm_window_type,
    net_wm_window_type_desktop,
    net_wm_window_type_dock,
    net_wm_window_type_toolbar,
    net_wm_window_type_menu,
    net_wm_window_type_utility,
    net_wm_window_type_splash,
    net_wm_window_type_dialog,
    net_wm_window_type_dropdown_menu,
    net_wm_window_type_popup_menu,
    net_wm_window_type_tooltip,
    net_wm_window_type_notification,
    net_wm_window_type_combo,
    net_wm_window_type_dnd,
    net_wm_window_type_normal,
    motif_wm_hints,
    utf8_string,
    wm_protocols,
    wm_take_focus,
    wm_delete_window,
    wm_state,
    wm_change_state,
    wl_surface_serial,
    clipboard,
    targets,
    selection_data,
    incr,
    text,
    xdnd_selection,
    xdnd_aware,
    xdnd_status,
    xdnd_position,
    xdnd_enter,
    xdnd_leave,
    xdnd_drop,
    xdnd_finished,
    xdnd_proxy,
    xdnd_type_list,
    xdnd_action_move,
    xdnd_action_copy,
    xdnd_action_ask,
    xdnd_action_private,
};

const atom_count = std.meta.fields(Atom).len;
const atom_names: [atom_count][]const u8 = .{
    "WM_S0",
    "_NET_WM_CM_S0",
    "_NET_SUPPORTED",
    "_NET_SUPPORTING_WM_CHECK",
    "_NET_CLIENT_LIST",
    "_NET_CLIENT_LIST_STACKING",
    "_NET_WM_NAME",
    "_NET_ACTIVE_WINDOW",
    "_NET_CLOSE_WINDOW",
    "_NET_WM_MOVERESIZE",
    "_NET_WM_STATE",
    "_NET_WM_STATE_MODAL",
    "_NET_WM_STATE_FULLSCREEN",
    "_NET_WM_STATE_MAXIMIZED_HORZ",
    "_NET_WM_STATE_MAXIMIZED_VERT",
    "_NET_WM_STATE_HIDDEN",
    "_NET_WM_STATE_SKIP_TASKBAR",
    "_NET_WM_STATE_FOCUSED",
    "_NET_WM_WINDOW_TYPE",
    "_NET_WM_WINDOW_TYPE_DESKTOP",
    "_NET_WM_WINDOW_TYPE_DOCK",
    "_NET_WM_WINDOW_TYPE_TOOLBAR",
    "_NET_WM_WINDOW_TYPE_MENU",
    "_NET_WM_WINDOW_TYPE_UTILITY",
    "_NET_WM_WINDOW_TYPE_SPLASH",
    "_NET_WM_WINDOW_TYPE_DIALOG",
    "_NET_WM_WINDOW_TYPE_DROPDOWN_MENU",
    "_NET_WM_WINDOW_TYPE_POPUP_MENU",
    "_NET_WM_WINDOW_TYPE_TOOLTIP",
    "_NET_WM_WINDOW_TYPE_NOTIFICATION",
    "_NET_WM_WINDOW_TYPE_COMBO",
    "_NET_WM_WINDOW_TYPE_DND",
    "_NET_WM_WINDOW_TYPE_NORMAL",
    "_MOTIF_WM_HINTS",
    "UTF8_STRING",
    "WM_PROTOCOLS",
    "WM_TAKE_FOCUS",
    "WM_DELETE_WINDOW",
    "WM_STATE",
    "WM_CHANGE_STATE",
    "WL_SURFACE_SERIAL",
    "CLIPBOARD",
    "TARGETS",
    "_KEYWORK_SELECTION",
    "INCR",
    "TEXT",
    "XdndSelection",
    "XdndAware",
    "XdndStatus",
    "XdndPosition",
    "XdndEnter",
    "XdndLeave",
    "XdndDrop",
    "XdndFinished",
    "XdndProxy",
    "XdndTypeList",
    "XdndActionMove",
    "XdndActionCopy",
    "XdndActionAsk",
    "XdndActionPrivate",
};

pub const Listener = struct {
    context: *anyopaque,
    failed: *const fn (*anyopaque) void,
    created: *const fn (*anyopaque, WindowInfo) void,
    /// Runs before `dissociated` on window destruction so consumers can
    /// inspect association-owned presentation state before removing it.
    destroyed: *const fn (*anyopaque, WindowId) void,
    mapped: *const fn (*anyopaque, WindowId, bool) void,
    configured: *const fn (*anyopaque, WindowId, Geometry, bool) void,
    metadata_changed: *const fn (*anyopaque, WindowId) void,
    fullscreen_requested: *const fn (*anyopaque, WindowId, bool) void,
    maximize_requested: *const fn (*anyopaque, WindowId, bool) void,
    minimize_requested: *const fn (*anyopaque, WindowId, bool) void,
    activation_requested: *const fn (*anyopaque, WindowId) void,
    activation_changed: *const fn (*anyopaque, WindowId) void,
    move_resize_requested: *const fn (*anyopaque, WindowId, MoveResizeRequest, u32) void,
    serial: *const fn (*anyopaque, WindowId, u64) void,
    associated: *const fn (*anyopaque, WindowId, Surface.Id) void,
    dissociated: *const fn (*anyopaque, WindowId, Surface.Id) void,
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    event_loop: *wl.EventLoop,
    fd: std.posix.fd_t,
    data_device: *DataDevice,
    primary_selection: *PrimarySelection,
    listener: Listener,
) !void {
    const connection = c.xcb_connect_to_fd(fd, null) orelse {
        _ = std.c.close(fd);
        return error.XcbConnectFailed;
    };
    errdefer c.xcb_disconnect(connection);
    if (c.xcb_connection_has_error(connection) != 0)
        return error.XcbConnectFailed;

    const setup = c.xcb_get_setup(connection) orelse return error.XcbSetupFailed;
    const screen: *c.xcb_screen_t = @ptrCast(
        c.xcb_setup_roots_iterator(setup).data orelse
            return error.XcbSetupFailed,
    );
    self.* = .{
        .allocator = allocator,
        .connection = connection,
        .screen = screen,
        .event_source = undefined,
        .wm_window = c.XCB_WINDOW_NONE,
        .atoms = undefined,
        .windows = .empty,
        .serial_windows = .empty,
        .client_list = .empty,
        .client_stacking = .empty,
        .focused_window = null,
        .xfixes_event_base = 0,
        .xres_available = false,
        .clipboard_selection = undefined,
        .primary_selection = undefined,
        .dnd_selection = undefined,
        .dnd = undefined,
        .listener = listener,
    };

    try self.resolveAtoms();
    try self.checkComposite();
    const xfixes = try self.checkXfixes();
    self.xfixes_event_base = xfixes.event_base;
    self.xres_available = self.checkXres();
    self.wm_window = c.xcb_generate_id(connection);
    if (self.wm_window == c.XCB_WINDOW_NONE) return error.XidAllocationFailed;
    try checkRequest(connection, c.xcb_create_window_checked(
        connection,
        c.XCB_COPY_FROM_PARENT,
        self.wm_window,
        screen.root,
        0,
        0,
        10,
        10,
        0,
        c.XCB_WINDOW_CLASS_INPUT_OUTPUT,
        screen.root_visual,
        0,
        null,
    ));

    const root_event_mask: u32 = c.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY |
        c.XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT |
        c.XCB_EVENT_MASK_PROPERTY_CHANGE;
    try checkRequest(connection, c.xcb_change_window_attributes_checked(
        connection,
        screen.root,
        c.XCB_CW_EVENT_MASK,
        &root_event_mask,
    ));
    try checkRequest(connection, c.xcb_composite_redirect_subwindows_checked(
        connection,
        screen.root,
        c.XCB_COMPOSITE_REDIRECT_MANUAL,
    ));
    try self.publishWmIdentity();
    try self.claimSelection(.wm_s0);
    try self.claimSelection(.net_wm_cm_s0);
    try self.clipboard_selection.init(
        allocator,
        event_loop,
        connection,
        screen,
        .{
            .selection = self.atomValue(.clipboard),
            .targets = self.atomValue(.targets),
            .selection_data = self.atomValue(.selection_data),
            .incr = self.atomValue(.incr),
            .utf8_string = self.atomValue(.utf8_string),
            .text = self.atomValue(.text),
        },
        .{ .clipboard = data_device },
    );
    errdefer self.clipboard_selection.deinit();
    try self.primary_selection.init(
        allocator,
        event_loop,
        connection,
        screen,
        .{
            .selection = c.XCB_ATOM_PRIMARY,
            .targets = self.atomValue(.targets),
            .selection_data = self.atomValue(.selection_data),
            .incr = self.atomValue(.incr),
            .utf8_string = self.atomValue(.utf8_string),
            .text = self.atomValue(.text),
        },
        .{ .primary = primary_selection },
    );
    errdefer self.primary_selection.deinit();
    try self.dnd_selection.init(
        allocator,
        event_loop,
        connection,
        screen,
        .{
            .selection = self.atomValue(.xdnd_selection),
            .targets = self.atomValue(.targets),
            .selection_data = self.atomValue(.selection_data),
            .incr = self.atomValue(.incr),
            .utf8_string = self.atomValue(.utf8_string),
            .text = self.atomValue(.text),
        },
        .{ .drag = data_device },
    );
    errdefer self.dnd_selection.deinit();
    try self.dnd.init(
        allocator,
        connection,
        screen,
        data_device,
        &self.dnd_selection,
        .{
            .aware = self.atomValue(.xdnd_aware),
            .enter = self.atomValue(.xdnd_enter),
            .position = self.atomValue(.xdnd_position),
            .status = self.atomValue(.xdnd_status),
            .leave = self.atomValue(.xdnd_leave),
            .drop = self.atomValue(.xdnd_drop),
            .finished = self.atomValue(.xdnd_finished),
            .proxy = self.atomValue(.xdnd_proxy),
            .type_list = self.atomValue(.xdnd_type_list),
            .action_copy = self.atomValue(.xdnd_action_copy),
            .action_move = self.atomValue(.xdnd_action_move),
            .action_ask = self.atomValue(.xdnd_action_ask),
            .action_private = self.atomValue(.xdnd_action_private),
        },
    );
    errdefer self.dnd.deinit();
    if (xfixes.client_disconnect_mode) {
        // Mark the XWM only after claiming WM_S0 releases the public sockets,
        // otherwise a fast first client can race Xwayland's startup barrier.
        try checkRequest(connection, c.xcb_xfixes_set_client_disconnect_mode_checked(
            connection,
            c.XCB_XFIXES_CLIENT_DISCONNECT_FLAGS_TERMINATE,
        ));
    } else {
        log.warn("XFixes 6 is unavailable; Xwayland cannot stop when idle", .{});
    }
    if (c.xcb_flush(connection) <= 0) return error.XcbFlushFailed;

    const event_fd = c.xcb_get_file_descriptor(connection);
    if (event_fd < 0) return error.XcbConnectionFailed;
    self.event_source = try event_loop.addFd(
        *Self,
        event_fd,
        .{ .readable = true, .hangup = true, .@"error" = true },
        handleEvents,
        self,
    );
    self.event_source.check();
}

pub fn deinit(self: *Self) void {
    self.event_source.remove();
    self.dnd.deinit();
    self.dnd_selection.deinit();
    self.primary_selection.deinit();
    self.clipboard_selection.deinit();
    while (self.windows.count() > 0) {
        var iterator = self.windows.iterator();
        const entry = iterator.next().?;
        self.removeWindow(entry.key_ptr.*);
    }
    std.debug.assert(self.serial_windows.count() == 0);
    std.debug.assert(self.client_list.items.len == 0);
    std.debug.assert(self.client_stacking.items.len == 0);
    self.serial_windows.deinit(self.allocator);
    self.windows.deinit(self.allocator);
    self.client_list.deinit(self.allocator);
    self.client_stacking.deinit(self.allocator);
    c.xcb_disconnect(self.connection);
    self.* = undefined;
}

pub fn associateSurface(self: *Self, serial: u64, surface_id: Surface.Id) bool {
    const window_id = self.serial_windows.get(serial) orelse return false;
    const window = self.windows.getPtr(window_id) orelse return false;
    if (window.surface_id) |current| return std.meta.eql(current, surface_id);
    if (self.xres_available) window.unreliable_pid = self.readClientPid(window_id);
    window.surface_id = surface_id;
    log.debug("associated X11 window {d} with surface serial {d} and client pid {?d}", .{
        window_id,
        serial,
        window.unreliable_pid,
    });
    self.listener.associated(self.listener.context, window_id, surface_id);
    return true;
}

pub fn removeSurfaceAssociation(
    self: *Self,
    serial: u64,
    surface_id: Surface.Id,
) void {
    const window_id = self.serial_windows.get(serial) orelse return;
    const window = self.windows.getPtr(window_id) orelse return;
    if (window.surface_id) |current| {
        if (!std.meta.eql(current, surface_id)) return;
        if (self.focused_window == window_id) {
            self.focusWindow(null) catch log.err("failed to clear X11 input focus", .{});
        }
        self.listener.dissociated(self.listener.context, window_id, current);
    }
    std.debug.assert(self.serial_windows.remove(serial));
    window.serial = null;
    window.surface_id = null;
    log.debug("removed surface association from X11 window {d}", .{window_id});
}

pub fn windowInfo(self: *const Self, window_id: WindowId) ?WindowInfo {
    const window = self.windows.get(window_id) orelse return null;
    return self.info(window_id, window);
}

pub fn windowForSerial(self: *const Self, serial: u64) ?WindowId {
    return self.serial_windows.get(serial);
}

pub fn setClientStacking(self: *Self, window_ids: []const WindowId) error{XcbFlushFailed}!void {
    var ordered_index: usize = 0;
    for (self.client_stacking.items) |window_id| {
        if (ordered_index == window_ids.len) break;
        if (window_id == window_ids[ordered_index]) ordered_index += 1;
    }
    if (ordered_index == window_ids.len) return;

    for (window_ids) |window_id| {
        for (self.client_stacking.items, 0..) |candidate, index| {
            if (candidate != window_id) continue;
            const moved = self.client_stacking.orderedRemove(index);
            self.client_stacking.appendAssumeCapacity(moved);
            break;
        }
    }
    self.publishClientStacking();
    if (c.xcb_flush(self.connection) <= 0) return error.XcbFlushFailed;
}

pub fn dragStarted(self: *Self) void {
    self.dnd.dragStarted();
}

pub fn dragMotion(self: *Self, window_id: WindowId, time: u32, x: f64, y: f64) void {
    const window = self.windows.get(window_id) orelse return self.dnd.dragLeft();
    if (!window.mapped) return self.dnd.dragLeft();
    self.dnd.dragMotion(window_id, time, x, y);
}

pub fn dragLeft(self: *Self) void {
    self.dnd.dragLeft();
}

pub fn dropDrag(self: *Self, time: u32) bool {
    return self.dnd.drop(time);
}

pub fn physicalDragEnded(self: *Self) void {
    self.dnd.physicalDragEnded();
}

pub fn routeExternalDragOverXwayland(self: *Self, over_xwayland: bool) void {
    self.dnd.routeExternalDragOverXwayland(over_xwayland);
}

pub fn dragSourceDestroyed(self: *Self, generation: u64) void {
    self.dnd.sourceDestroyed(generation);
}

pub fn focusWindow(
    self: *Self,
    requested_window: ?WindowId,
) error{ OutOfMemory, XcbFlushFailed }!void {
    const window_id = if (requested_window) |id| focus: {
        const window = self.windows.get(id) orelse break :focus null;
        if (!window.mapped or
            (window.override_redirect and !window.override_redirect_wants_focus)) break :focus null;
        break :focus id;
    } else null;
    const previous_window = self.focused_window;
    if (previous_window == window_id) return;

    const focused_atom = self.atomValue(.net_wm_state_focused);
    var previous_state: ?[]c.xcb_atom_t = null;
    errdefer if (previous_state) |atoms| self.allocator.free(atoms);
    if (previous_window) |id| {
        const window = self.windows.get(id) orelse unreachable;
        previous_state = try replacedAtomList(
            self.allocator,
            window.net_wm_state,
            &.{focused_atom},
            &.{},
        );
    }
    var focused_state: ?[]c.xcb_atom_t = null;
    errdefer if (focused_state) |atoms| self.allocator.free(atoms);
    if (window_id) |id| {
        const window = self.windows.get(id) orelse unreachable;
        focused_state = try replacedAtomList(
            self.allocator,
            window.net_wm_state,
            &.{focused_atom},
            &.{focused_atom},
        );
    }

    if (previous_window) |id| {
        const window = self.windows.getPtr(id) orelse unreachable;
        self.setNetWmStateAtoms(id, window, previous_state.?);
        previous_state = null;
    }
    if (window_id) |id| {
        const window = self.windows.getPtr(id) orelse unreachable;
        self.setNetWmStateAtoms(id, window, focused_state.?);
        focused_state = null;
    }
    self.focused_window = window_id;
    const active_window = window_id orelse c.XCB_WINDOW_NONE;
    _ = c.xcb_change_property(
        self.connection,
        c.XCB_PROP_MODE_REPLACE,
        self.screen.root,
        self.atomValue(.net_active_window),
        c.XCB_ATOM_WINDOW,
        32,
        1,
        &active_window,
    );

    if (window_id) |id| {
        const window = self.windows.get(id) orelse unreachable;
        if (window.take_focus) self.sendWmMessage(id, .wm_take_focus);
        if (window.accepts_input) {
            _ = c.xcb_set_input_focus(
                self.connection,
                c.XCB_INPUT_FOCUS_POINTER_ROOT,
                id,
                c.XCB_CURRENT_TIME,
            );
        }
    } else {
        _ = c.xcb_set_input_focus(
            self.connection,
            c.XCB_INPUT_FOCUS_POINTER_ROOT,
            c.XCB_NONE,
            c.XCB_CURRENT_TIME,
        );
    }
    if (c.xcb_flush(self.connection) <= 0) return error.XcbFlushFailed;
    if (previous_window) |id| self.listener.activation_changed(self.listener.context, id);
    if (window_id) |id| self.listener.activation_changed(self.listener.context, id);
}

pub fn closeWindow(self: *Self, window_id: WindowId) void {
    const window = self.windows.get(window_id) orelse return;
    if (window.delete_window) {
        self.sendWmMessage(window_id, .wm_delete_window);
    } else {
        _ = c.xcb_kill_client(self.connection, window_id);
    }
    _ = c.xcb_flush(self.connection);
}

pub fn setFullscreen(
    self: *Self,
    window_id: WindowId,
    fullscreen: bool,
) error{ InvalidWindow, OutOfMemory, XcbFlushFailed }!bool {
    const window = self.windows.getPtr(window_id) orelse return error.InvalidWindow;
    if (window.override_redirect) return error.InvalidWindow;
    if (window.fullscreen == fullscreen) return false;

    const fullscreen_atom = self.atomValue(.net_wm_state_fullscreen);
    try self.replaceNetWmStateAtoms(
        window_id,
        window,
        &.{fullscreen_atom},
        if (fullscreen) &.{fullscreen_atom} else &.{},
    );
    window.fullscreen = fullscreen;
    if (c.xcb_flush(self.connection) <= 0) return error.XcbFlushFailed;
    return true;
}

pub fn setMaximized(
    self: *Self,
    window_id: WindowId,
    maximized: bool,
) error{ InvalidWindow, OutOfMemory, XcbFlushFailed }!bool {
    const window = self.windows.getPtr(window_id) orelse return error.InvalidWindow;
    if (window.override_redirect) return error.InvalidWindow;
    if (window.maximized_horz == maximized and window.maximized_vert == maximized) return false;

    const maximized_atoms = [_]c.xcb_atom_t{
        self.atomValue(.net_wm_state_maximized_horz),
        self.atomValue(.net_wm_state_maximized_vert),
    };
    try self.replaceNetWmStateAtoms(
        window_id,
        window,
        &maximized_atoms,
        if (maximized) &maximized_atoms else &.{},
    );
    window.maximized_horz = maximized;
    window.maximized_vert = maximized;
    if (c.xcb_flush(self.connection) <= 0) return error.XcbFlushFailed;
    return true;
}

pub fn setMinimized(
    self: *Self,
    window_id: WindowId,
    minimized: bool,
) error{ InvalidWindow, OutOfMemory, XcbFlushFailed }!bool {
    const window = self.windows.getPtr(window_id) orelse return error.InvalidWindow;
    if (window.override_redirect) return error.InvalidWindow;
    if (window.minimized == minimized) return false;

    const hidden_atom = self.atomValue(.net_wm_state_hidden);
    try self.replaceNetWmStateAtoms(
        window_id,
        window,
        &.{hidden_atom},
        if (minimized) &.{hidden_atom} else &.{},
    );
    window.minimized = minimized;
    if (window.mapped) self.setWmState(
        window_id,
        if (minimized)
            c.XCB_ICCCM_WM_STATE_ICONIC
        else
            c.XCB_ICCCM_WM_STATE_NORMAL,
    );
    if (c.xcb_flush(self.connection) <= 0) return error.XcbFlushFailed;
    return true;
}

fn replaceNetWmStateAtoms(
    self: *Self,
    window_id: WindowId,
    window: *Window,
    removed_atoms: []const c.xcb_atom_t,
    added_atoms: []const c.xcb_atom_t,
) error{OutOfMemory}!void {
    const atoms = try replacedAtomList(
        self.allocator,
        window.net_wm_state,
        removed_atoms,
        added_atoms,
    );
    self.setNetWmStateAtoms(window_id, window, atoms);
}

fn replacedAtomList(
    allocator: std.mem.Allocator,
    current_atoms: []const c.xcb_atom_t,
    removed_atoms: []const c.xcb_atom_t,
    added_atoms: []const c.xcb_atom_t,
) error{OutOfMemory}![]c.xcb_atom_t {
    var retained_count: usize = 0;
    for (current_atoms) |atom| {
        if (std.mem.indexOfScalar(c.xcb_atom_t, removed_atoms, atom) == null) retained_count += 1;
    }
    const state_atom_count = retained_count + added_atoms.len;
    const atoms = try allocator.alloc(c.xcb_atom_t, state_atom_count);
    var index: usize = 0;
    for (current_atoms) |atom| {
        if (std.mem.indexOfScalar(c.xcb_atom_t, removed_atoms, atom) != null) continue;
        atoms[index] = atom;
        index += 1;
    }
    @memcpy(atoms[index..], added_atoms);
    return atoms;
}

fn setNetWmStateAtoms(
    self: *Self,
    window_id: WindowId,
    window: *Window,
    atoms: []c.xcb_atom_t,
) void {
    self.allocator.free(window.net_wm_state);
    window.net_wm_state = atoms;
    self.publishNetWmStateAtoms(window_id, atoms);
}

fn publishNetWmStateAtoms(
    self: *Self,
    window_id: WindowId,
    atoms: []const c.xcb_atom_t,
) void {
    _ = c.xcb_change_property(
        self.connection,
        c.XCB_PROP_MODE_REPLACE,
        window_id,
        self.atomValue(.net_wm_state),
        c.XCB_ATOM_ATOM,
        32,
        @intCast(atoms.len),
        if (atoms.len == 0) null else atoms.ptr,
    );
}

pub fn resizeWindow(
    self: *Self,
    window_id: WindowId,
    width: u16,
    height: u16,
) error{ InvalidWindow, XcbFlushFailed }!void {
    std.debug.assert(width > 0 and height > 0);
    const window = self.windows.get(window_id) orelse return error.InvalidWindow;
    if (window.override_redirect) return error.InvalidWindow;
    const values = [_]u32{ width, height };
    _ = c.xcb_configure_window(
        self.connection,
        window_id,
        c.XCB_CONFIG_WINDOW_WIDTH | c.XCB_CONFIG_WINDOW_HEIGHT,
        &values,
    );
    if (c.xcb_flush(self.connection) <= 0) return error.XcbFlushFailed;
}

pub fn moveWindow(
    self: *Self,
    window_id: WindowId,
    x: i16,
    y: i16,
) error{ InvalidWindow, XcbFlushFailed }!void {
    const window = self.windows.get(window_id) orelse return error.InvalidWindow;
    if (window.override_redirect) return error.InvalidWindow;
    const values = [_]u32{ signedValue(x), signedValue(y) };
    _ = c.xcb_configure_window(
        self.connection,
        window_id,
        c.XCB_CONFIG_WINDOW_X | c.XCB_CONFIG_WINDOW_Y,
        &values,
    );
    if (c.xcb_flush(self.connection) <= 0) return error.XcbFlushFailed;
}

fn resolveAtoms(self: *Self) !void {
    var cookies: [atom_count]c.xcb_intern_atom_cookie_t = undefined;
    for (atom_names, &cookies) |name, *cookie| {
        cookie.* = c.xcb_intern_atom(
            self.connection,
            0,
            @intCast(name.len),
            name.ptr,
        );
    }
    for (atom_names, cookies, &self.atoms) |name, cookie, *resolved_atom| {
        var x_error: ?*c.xcb_generic_error_t = null;
        const reply = c.xcb_intern_atom_reply(
            self.connection,
            cookie,
            &x_error,
        ) orelse {
            if (x_error) |err| {
                logX11Error("intern atom", err);
                std.c.free(err);
            }
            log.err("failed to resolve X11 atom {s}", .{name});
            return error.AtomResolutionFailed;
        };
        defer std.c.free(reply);
        if (x_error) |err| {
            logX11Error("intern atom", err);
            std.c.free(err);
            return error.AtomResolutionFailed;
        }
        resolved_atom.* = reply.*.atom;
    }
}

fn checkComposite(self: *Self) !void {
    var x_error: ?*c.xcb_generic_error_t = null;
    const reply = c.xcb_composite_query_version_reply(
        self.connection,
        c.xcb_composite_query_version(self.connection, 0, 4),
        &x_error,
    ) orelse {
        if (x_error) |err| {
            logX11Error("query Composite", err);
            std.c.free(err);
        }
        return error.CompositeUnavailable;
    };
    defer std.c.free(reply);
    if (x_error) |err| {
        logX11Error("query Composite", err);
        std.c.free(err);
        return error.CompositeUnavailable;
    }
}

fn checkXfixes(self: *Self) !XfixesInfo {
    const extension_name = "XFIXES";
    const extension = c.xcb_query_extension_reply(
        self.connection,
        c.xcb_query_extension(
            self.connection,
            extension_name.len,
            extension_name.ptr,
        ),
        null,
    ) orelse return error.XfixesUnavailable;
    defer std.c.free(extension);
    if (extension.*.present == 0) return error.XfixesUnavailable;
    var x_error: ?*c.xcb_generic_error_t = null;
    const reply = c.xcb_xfixes_query_version_reply(
        self.connection,
        c.xcb_xfixes_query_version(
            self.connection,
            c.XCB_XFIXES_MAJOR_VERSION,
            c.XCB_XFIXES_MINOR_VERSION,
        ),
        &x_error,
    ) orelse {
        if (x_error) |err| {
            logX11Error("query XFixes", err);
            std.c.free(err);
        }
        return error.XfixesUnavailable;
    };
    defer std.c.free(reply);
    if (x_error) |err| {
        logX11Error("query XFixes", err);
        std.c.free(err);
        return error.XfixesUnavailable;
    }
    return .{
        .event_base = extension.*.first_event,
        .client_disconnect_mode = reply.*.major_version >= 6,
    };
}

fn checkXres(self: *Self) bool {
    const extension_name = "X-Resource";
    const extension = c.xcb_query_extension_reply(
        self.connection,
        c.xcb_query_extension(
            self.connection,
            extension_name.len,
            extension_name.ptr,
        ),
        null,
    ) orelse return false;
    defer std.c.free(extension);
    if (extension.*.present == 0) return false;
    const reply = c.xcb_res_query_version_reply(
        self.connection,
        c.xcb_res_query_version(
            self.connection,
            c.XCB_RES_MAJOR_VERSION,
            c.XCB_RES_MINOR_VERSION,
        ),
        null,
    ) orelse return false;
    defer std.c.free(reply);
    return reply.*.server_major > 1 or
        (reply.*.server_major == 1 and reply.*.server_minor >= 2);
}

fn readClientPid(self: *Self, window_id: WindowId) ?i32 {
    const spec: c.xcb_res_client_id_spec_t = .{
        .client = window_id,
        .mask = c.XCB_RES_CLIENT_ID_MASK_LOCAL_CLIENT_PID,
    };
    const reply = c.xcb_res_query_client_ids_reply(
        self.connection,
        c.xcb_res_query_client_ids(self.connection, 1, &spec),
        null,
    ) orelse return null;
    defer std.c.free(reply);
    var values = c.xcb_res_query_client_ids_ids_iterator(reply);
    while (values.rem > 0) : (c.xcb_res_client_id_value_next(&values)) {
        const value = values.data orelse return null;
        if (value.*.spec.mask & c.XCB_RES_CLIENT_ID_MASK_LOCAL_CLIENT_PID == 0 or
            c.xcb_res_client_id_value_value_length(value) == 0) continue;
        const pid_values = c.xcb_res_client_id_value_value(value) orelse return null;
        const pid = pid_values[0];
        if (pid == 0 or pid > std.math.maxInt(i32)) return null;
        return @intCast(pid);
    }
    return null;
}

fn publishWmIdentity(self: *Self) !void {
    const wm_name = "Keywork";
    try checkRequest(self.connection, c.xcb_change_property_checked(
        self.connection,
        c.XCB_PROP_MODE_REPLACE,
        self.wm_window,
        self.atomValue(.net_wm_name),
        self.atomValue(.utf8_string),
        8,
        wm_name.len,
        wm_name.ptr,
    ));
    try self.setWindowProperty(
        self.screen.root,
        .net_supporting_wm_check,
        self.wm_window,
    );
    try self.setWindowProperty(
        self.wm_window,
        .net_supporting_wm_check,
        self.wm_window,
    );
    const supported = [_]c.xcb_atom_t{
        self.atomValue(.net_supporting_wm_check),
        self.atomValue(.net_client_list),
        self.atomValue(.net_client_list_stacking),
        self.atomValue(.net_wm_name),
        self.atomValue(.net_active_window),
        self.atomValue(.net_close_window),
        self.atomValue(.net_wm_moveresize),
        self.atomValue(.net_wm_state),
        self.atomValue(.net_wm_state_modal),
        self.atomValue(.net_wm_state_fullscreen),
        self.atomValue(.net_wm_state_maximized_horz),
        self.atomValue(.net_wm_state_maximized_vert),
        self.atomValue(.net_wm_state_hidden),
        self.atomValue(.net_wm_state_skip_taskbar),
        self.atomValue(.net_wm_state_focused),
        self.atomValue(.net_wm_window_type),
        self.atomValue(.net_wm_window_type_desktop),
        self.atomValue(.net_wm_window_type_dock),
        self.atomValue(.net_wm_window_type_toolbar),
        self.atomValue(.net_wm_window_type_menu),
        self.atomValue(.net_wm_window_type_utility),
        self.atomValue(.net_wm_window_type_splash),
        self.atomValue(.net_wm_window_type_dialog),
        self.atomValue(.net_wm_window_type_dropdown_menu),
        self.atomValue(.net_wm_window_type_popup_menu),
        self.atomValue(.net_wm_window_type_tooltip),
        self.atomValue(.net_wm_window_type_notification),
        self.atomValue(.net_wm_window_type_combo),
        self.atomValue(.net_wm_window_type_dnd),
        self.atomValue(.net_wm_window_type_normal),
    };
    try checkRequest(self.connection, c.xcb_change_property_checked(
        self.connection,
        c.XCB_PROP_MODE_REPLACE,
        self.screen.root,
        self.atomValue(.net_supported),
        c.XCB_ATOM_ATOM,
        32,
        supported.len,
        &supported,
    ));
    const active_window = c.XCB_WINDOW_NONE;
    try checkRequest(self.connection, c.xcb_change_property_checked(
        self.connection,
        c.XCB_PROP_MODE_REPLACE,
        self.screen.root,
        self.atomValue(.net_active_window),
        c.XCB_ATOM_WINDOW,
        32,
        1,
        &active_window,
    ));
    self.publishClientList();
    self.publishClientStacking();
}

fn publishClientList(self: *Self) void {
    _ = c.xcb_change_property(
        self.connection,
        c.XCB_PROP_MODE_REPLACE,
        self.screen.root,
        self.atomValue(.net_client_list),
        c.XCB_ATOM_WINDOW,
        32,
        @intCast(self.client_list.items.len),
        if (self.client_list.items.len == 0) null else self.client_list.items.ptr,
    );
}

fn publishClientStacking(self: *Self) void {
    _ = c.xcb_change_property(
        self.connection,
        c.XCB_PROP_MODE_REPLACE,
        self.screen.root,
        self.atomValue(.net_client_list_stacking),
        c.XCB_ATOM_WINDOW,
        32,
        @intCast(self.client_stacking.items.len),
        if (self.client_stacking.items.len == 0) null else self.client_stacking.items.ptr,
    );
}

fn updateClientListMembership(self: *Self, window_id: WindowId, listed: bool) !void {
    for (self.client_list.items, 0..) |candidate, index| {
        if (candidate != window_id) continue;
        if (!listed) {
            _ = self.client_list.orderedRemove(index);
            for (self.client_stacking.items, 0..) |stacked, stack_index| {
                if (stacked != window_id) continue;
                _ = self.client_stacking.orderedRemove(stack_index);
                break;
            }
            self.publishClientList();
            self.publishClientStacking();
        }
        return;
    }
    if (!listed) return;
    try self.client_list.ensureUnusedCapacity(self.allocator, 1);
    try self.client_stacking.ensureUnusedCapacity(self.allocator, 1);
    self.client_list.appendAssumeCapacity(window_id);
    self.client_stacking.appendAssumeCapacity(window_id);
    self.publishClientList();
    self.publishClientStacking();
}

fn refreshInputModel(self: *Self, window_id: WindowId, window: *Window) void {
    window.accepts_input = true;
    var hints = std.mem.zeroes(c.xcb_icccm_wm_hints_t);
    if (c.xcb_icccm_get_wm_hints_reply(
        self.connection,
        c.xcb_icccm_get_wm_hints(self.connection, window_id),
        &hints,
        null,
    ) != 0 and hints.flags & c.XCB_ICCCM_WM_HINT_INPUT != 0) {
        window.accepts_input = hints.input != 0;
    }
}

fn refreshProtocols(self: *Self, window_id: WindowId, window: *Window) void {
    window.take_focus = false;
    window.delete_window = false;
    var protocols = std.mem.zeroes(c.xcb_icccm_get_wm_protocols_reply_t);
    if (c.xcb_icccm_get_wm_protocols_reply(
        self.connection,
        c.xcb_icccm_get_wm_protocols(
            self.connection,
            window_id,
            self.atomValue(.wm_protocols),
        ),
        &protocols,
        null,
    ) != 0) {
        defer c.xcb_icccm_get_wm_protocols_reply_wipe(&protocols);
        for (protocols.atoms[0..protocols.atoms_len]) |protocol| {
            if (protocol == self.atomValue(.wm_take_focus)) {
                window.take_focus = true;
            } else if (protocol == self.atomValue(.wm_delete_window)) {
                window.delete_window = true;
            }
        }
    }
}

const NetWmStateChanges = struct {
    modal: bool = false,
    fullscreen: bool = false,
    maximized: bool = false,
    minimized: bool = false,
    skip_taskbar: bool = false,
};

fn refreshNetWmState(self: *Self, window_id: WindowId, window: *Window) !NetWmStateChanges {
    var replacement = (try self.readAtomList(window_id, .net_wm_state)) orelse return .{};
    errdefer self.allocator.free(replacement);
    const focused_atom = self.atomValue(.net_wm_state_focused);
    const property_focused = std.mem.indexOfScalar(
        c.xcb_atom_t,
        replacement,
        focused_atom,
    ) != null;
    const actually_focused = self.focused_window == window_id;
    if (property_focused != actually_focused) {
        const normalized = try replacedAtomList(
            self.allocator,
            replacement,
            &.{focused_atom},
            if (actually_focused) &.{focused_atom} else &.{},
        );
        self.allocator.free(replacement);
        replacement = normalized;
        self.publishNetWmStateAtoms(window_id, replacement);
    }
    if (std.mem.eql(c.xcb_atom_t, window.net_wm_state, replacement)) {
        self.allocator.free(replacement);
        return .{};
    }
    const previous_modal = window.modal;
    const previous_fullscreen = window.fullscreen;
    const previous_maximized = window.maximized_horz and window.maximized_vert;
    const previous_minimized = window.minimized;
    const previous_skip_taskbar = window.skip_taskbar;
    self.allocator.free(window.net_wm_state);
    window.net_wm_state = replacement;
    window.modal = std.mem.indexOfScalar(
        c.xcb_atom_t,
        replacement,
        self.atomValue(.net_wm_state_modal),
    ) != null;
    window.fullscreen = std.mem.indexOfScalar(
        c.xcb_atom_t,
        replacement,
        self.atomValue(.net_wm_state_fullscreen),
    ) != null;
    window.maximized_horz = std.mem.indexOfScalar(
        c.xcb_atom_t,
        replacement,
        self.atomValue(.net_wm_state_maximized_horz),
    ) != null;
    window.maximized_vert = std.mem.indexOfScalar(
        c.xcb_atom_t,
        replacement,
        self.atomValue(.net_wm_state_maximized_vert),
    ) != null;
    window.minimized = std.mem.indexOfScalar(
        c.xcb_atom_t,
        replacement,
        self.atomValue(.net_wm_state_hidden),
    ) != null;
    window.skip_taskbar = std.mem.indexOfScalar(
        c.xcb_atom_t,
        replacement,
        self.atomValue(.net_wm_state_skip_taskbar),
    ) != null;
    return .{
        .modal = previous_modal != window.modal,
        .fullscreen = previous_fullscreen != window.fullscreen,
        .maximized = previous_maximized != (window.maximized_horz and window.maximized_vert),
        .minimized = previous_minimized != window.minimized,
        .skip_taskbar = previous_skip_taskbar != window.skip_taskbar,
    };
}

fn readAtomList(self: *Self, window_id: WindowId, property: Atom) !?[]c.xcb_atom_t {
    const max_atoms = 1024;
    var x_error: ?*c.xcb_generic_error_t = null;
    const reply = c.xcb_get_property_reply(
        self.connection,
        c.xcb_get_property(
            self.connection,
            0,
            window_id,
            self.atomValue(property),
            c.XCB_ATOM_ATOM,
            0,
            max_atoms,
        ),
        &x_error,
    ) orelse {
        if (x_error) |err| {
            logX11Error("read atom property", err);
            std.c.free(err);
        }
        return null;
    };
    defer std.c.free(reply);
    if (x_error) |err| {
        logX11Error("read atom property", err);
        std.c.free(err);
        return null;
    }
    if (reply.*.type == c.XCB_ATOM_NONE or reply.*.value_len == 0) return &.{};
    if (reply.*.type != c.XCB_ATOM_ATOM or reply.*.format != 32 or reply.*.bytes_after != 0) {
        log.warn("ignored invalid atom property on X11 window {d}", .{window_id});
        return null;
    }
    const count: usize = @intCast(reply.*.value_len);
    const data = c.xcb_get_property_value(reply) orelse return null;
    const source: [*]const c.xcb_atom_t = @ptrCast(@alignCast(data));
    const atoms = try self.allocator.alloc(c.xcb_atom_t, count);
    @memcpy(atoms, source[0..count]);
    return atoms;
}

fn sendWmMessage(self: *Self, window_id: WindowId, message: Atom) void {
    var event = std.mem.zeroes(c.xcb_client_message_event_t);
    event.response_type = c.XCB_CLIENT_MESSAGE;
    event.format = 32;
    event.window = window_id;
    event.type = self.atomValue(.wm_protocols);
    event.data.data32[0] = self.atomValue(message);
    event.data.data32[1] = c.XCB_CURRENT_TIME;
    _ = c.xcb_send_event(
        self.connection,
        0,
        window_id,
        c.XCB_EVENT_MASK_NO_EVENT,
        @ptrCast(&event),
    );
}

fn refreshMetadata(self: *Self, window_id: WindowId, window: *Window) !bool {
    const title_changed = replaceOwnedString(
        self.allocator,
        &window.title,
        try self.readTitle(window_id),
    );
    const class_changed = try self.refreshClass(window_id, window);
    const parent_changed = self.refreshTransientFor(window_id, window);
    const window_type_changed = try self.refreshWindowType(window_id, window);
    const decorations_changed = self.refreshMotifHints(window_id, window);
    const size_hints_changed = self.refreshNormalHints(window_id, window);
    return title_changed or class_changed or parent_changed or window_type_changed or
        decorations_changed or size_hints_changed;
}

fn refreshTransientFor(self: *Self, window_id: WindowId, window: *Window) bool {
    var requested_parent: c.xcb_window_t = 0;
    const found = c.xcb_icccm_get_wm_transient_for_reply(
        self.connection,
        c.xcb_icccm_get_wm_transient_for(self.connection, window_id),
        &requested_parent,
        null,
    ) != 0;
    const parent: ?WindowId = if (!found or
        requested_parent == 0 or
        requested_parent == self.screen.root or
        requested_parent == window_id or
        self.wouldCreateParentLoop(window_id, requested_parent))
        null
    else
        requested_parent;
    if (window.parent == parent) return false;
    window.parent = parent;
    return true;
}

fn wouldCreateParentLoop(self: *const Self, window_id: WindowId, requested_parent: WindowId) bool {
    var ancestor = requested_parent;
    var remaining = self.windows.count() + 1;
    while (remaining > 0) : (remaining -= 1) {
        if (ancestor == window_id) return true;
        const parent = (self.windows.get(ancestor) orelse return false).parent orelse return false;
        ancestor = parent;
    }
    return true;
}

fn refreshWindowType(self: *Self, window_id: WindowId, window: *Window) !bool {
    const type_atoms = (try self.readAtomList(window_id, .net_wm_window_type)) orelse return false;
    defer self.allocator.free(type_atoms);
    var override_redirect_wants_focus = true;
    const window_type = for (type_atoms) |type_atom| {
        if (self.windowTypeForAtom(type_atom)) |value| break value;
    } else defaultWindowType(window.override_redirect, window.parent != null);
    for (type_atoms) |type_atom| {
        const value = self.windowTypeForAtom(type_atom) orelse continue;
        if (windowTypePreventsOverrideRedirectFocus(value)) {
            override_redirect_wants_focus = false;
        }
    }
    if (window.window_type == window_type and
        window.override_redirect_wants_focus == override_redirect_wants_focus) return false;
    window.window_type = window_type;
    window.override_redirect_wants_focus = override_redirect_wants_focus;
    return true;
}

fn windowTypeForAtom(self: *const Self, atom: c.xcb_atom_t) ?WindowType {
    inline for (.{
        .{ Atom.net_wm_window_type_desktop, WindowType.desktop },
        .{ Atom.net_wm_window_type_dock, WindowType.dock },
        .{ Atom.net_wm_window_type_toolbar, WindowType.toolbar },
        .{ Atom.net_wm_window_type_menu, WindowType.menu },
        .{ Atom.net_wm_window_type_utility, WindowType.utility },
        .{ Atom.net_wm_window_type_splash, WindowType.splash },
        .{ Atom.net_wm_window_type_dialog, WindowType.dialog },
        .{ Atom.net_wm_window_type_dropdown_menu, WindowType.dropdown_menu },
        .{ Atom.net_wm_window_type_popup_menu, WindowType.popup_menu },
        .{ Atom.net_wm_window_type_tooltip, WindowType.tooltip },
        .{ Atom.net_wm_window_type_notification, WindowType.notification },
        .{ Atom.net_wm_window_type_combo, WindowType.combo },
        .{ Atom.net_wm_window_type_dnd, WindowType.dnd },
        .{ Atom.net_wm_window_type_normal, WindowType.normal },
    }) |entry| {
        if (atom == self.atomValue(entry[0])) return entry[1];
    }
    return null;
}

fn defaultWindowType(override_redirect: bool, transient: bool) WindowType {
    return if (!override_redirect and transient) .dialog else .normal;
}

fn windowTypePreventsOverrideRedirectFocus(window_type: WindowType) bool {
    return switch (window_type) {
        .menu,
        .utility,
        .splash,
        .dropdown_menu,
        .popup_menu,
        .tooltip,
        .notification,
        .combo,
        .dnd,
        => true,
        .desktop, .dock, .toolbar, .dialog, .normal => false,
    };
}

fn refreshMotifHints(self: *Self, window_id: WindowId, window: *Window) bool {
    const reply = c.xcb_get_property_reply(
        self.connection,
        c.xcb_get_property(
            self.connection,
            0,
            window_id,
            self.atomValue(.motif_wm_hints),
            c.XCB_GET_PROPERTY_TYPE_ANY,
            0,
            5,
        ),
        null,
    ) orelse return false;
    defer std.c.free(reply);
    if (reply.*.format != 32 or reply.*.value_len < 5) return false;
    const value = c.xcb_get_property_value(reply) orelse return false;
    const hints: [*]const u32 = @ptrCast(@alignCast(value));
    const prefers_server_decorations = motifPrefersServerDecorations(hints[0..5]) orelse
        return false;
    if (window.prefers_server_decorations == prefers_server_decorations) return false;
    window.prefers_server_decorations = prefers_server_decorations;
    return true;
}

fn motifPrefersServerDecorations(hints: []const u32) ?bool {
    std.debug.assert(hints.len >= 5);
    const decorations_valid = hints[0] & (1 << 1) != 0;
    if (!decorations_valid) return null;
    const decorations = hints[2];
    if (decorations & (1 << 0) != 0) return true;
    return decorations & (1 << 1) != 0 and decorations & (1 << 3) != 0;
}

fn refreshNormalHints(self: *Self, window_id: WindowId, window: *Window) bool {
    var hints = std.mem.zeroes(c.xcb_size_hints_t);
    const found = c.xcb_icccm_get_wm_normal_hints_reply(
        self.connection,
        c.xcb_icccm_get_wm_normal_hints(self.connection, window_id),
        &hints,
        null,
    ) != 0;
    var min_size: Size = .{};
    var max_size: Size = .{};
    if (found and hints.flags & c.XCB_ICCCM_SIZE_HINT_P_MIN_SIZE != 0) {
        min_size = validSizeHint(hints.min_width, hints.min_height);
    }
    if (found and hints.flags & c.XCB_ICCCM_SIZE_HINT_P_MAX_SIZE != 0) {
        max_size = validSizeHint(hints.max_width, hints.max_height);
    }
    if (max_size.width > 0 and min_size.width > max_size.width) {
        max_size.width = min_size.width;
    }
    if (max_size.height > 0 and min_size.height > max_size.height) {
        max_size.height = min_size.height;
    }
    if (std.meta.eql(window.min_size, min_size) and std.meta.eql(window.max_size, max_size)) {
        return false;
    }
    window.min_size = min_size;
    window.max_size = max_size;
    return true;
}

fn validSizeHint(width: i32, height: i32) Size {
    return .{
        .width = if (width > 0) width else 0,
        .height = if (height > 0) height else 0,
    };
}

fn readTitle(self: *Self, window_id: WindowId) !?[:0]u8 {
    return try self.readTextProperty(window_id, self.atomValue(.net_wm_name)) orelse
        try self.readTextProperty(window_id, c.XCB_ATOM_WM_NAME);
}

fn readTextProperty(self: *Self, window_id: WindowId, property: c.xcb_atom_t) !?[:0]u8 {
    var value = std.mem.zeroes(c.xcb_icccm_get_text_property_reply_t);
    if (c.xcb_icccm_get_text_property_reply(
        self.connection,
        c.xcb_icccm_get_text_property(self.connection, window_id, property),
        &value,
        null,
    ) == 0) return null;
    defer c.xcb_icccm_get_text_property_reply_wipe(&value);
    if (value.format != 8 or value.name == null or value.name_len == 0) return null;
    const bytes = @as([*]const u8, @ptrCast(value.name))[0..value.name_len];
    const text = bytes[0 .. std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len];
    if (text.len == 0 or !std.unicode.utf8ValidateSlice(text)) return null;
    return @as(?[:0]u8, try self.allocator.dupeSentinel(u8, text, 0));
}

fn refreshClass(self: *Self, window_id: WindowId, window: *Window) !bool {
    var value = std.mem.zeroes(c.xcb_icccm_get_wm_class_reply_t);
    if (c.xcb_icccm_get_wm_class_reply(
        self.connection,
        c.xcb_icccm_get_wm_class(self.connection, window_id),
        &value,
        null,
    ) == 0) {
        const instance_changed = replaceOwnedString(self.allocator, &window.instance, null);
        const app_id_changed = replaceOwnedString(self.allocator, &window.app_id, null);
        return instance_changed or app_id_changed;
    }
    defer c.xcb_icccm_get_wm_class_reply_wipe(&value);
    const instance = try duplicateCString(self.allocator, value.instance_name);
    errdefer if (instance) |text| self.allocator.free(text);
    const app_id = try duplicateCString(self.allocator, value.class_name);
    const instance_changed = replaceOwnedString(self.allocator, &window.instance, instance);
    const app_id_changed = replaceOwnedString(self.allocator, &window.app_id, app_id);
    return instance_changed or app_id_changed;
}

fn duplicateCString(
    allocator: std.mem.Allocator,
    value: [*c]const u8,
) !?[:0]u8 {
    if (value == null) return null;
    const text = std.mem.span(value);
    if (text.len == 0 or !std.unicode.utf8ValidateSlice(text)) return null;
    return @as(?[:0]u8, try allocator.dupeSentinel(u8, text, 0));
}

fn replaceOwnedString(
    allocator: std.mem.Allocator,
    target: *?[:0]u8,
    replacement: ?[:0]u8,
) bool {
    if (target.*) |current| {
        if (replacement) |next| {
            if (std.mem.eql(u8, current, next)) {
                allocator.free(next);
                return false;
            }
        }
        allocator.free(current);
    } else if (replacement == null) {
        return false;
    }
    target.* = replacement;
    return true;
}

fn setWmState(self: *Self, window_id: WindowId, state: c_int) void {
    const values = [_]u32{ @bitCast(state), c.XCB_WINDOW_NONE };
    _ = c.xcb_change_property(
        self.connection,
        c.XCB_PROP_MODE_REPLACE,
        window_id,
        self.atomValue(.wm_state),
        self.atomValue(.wm_state),
        32,
        values.len,
        &values,
    );
}

fn setWindowProperty(
    self: *Self,
    window: c.xcb_window_t,
    property: Atom,
    value: c.xcb_window_t,
) !void {
    try checkRequest(self.connection, c.xcb_change_property_checked(
        self.connection,
        c.XCB_PROP_MODE_REPLACE,
        window,
        self.atomValue(property),
        c.XCB_ATOM_WINDOW,
        32,
        1,
        &value,
    ));
}

fn claimSelection(self: *Self, selection: Atom) !void {
    const selection_atom = self.atomValue(selection);
    try checkRequest(self.connection, c.xcb_set_selection_owner_checked(
        self.connection,
        self.wm_window,
        selection_atom,
        c.XCB_CURRENT_TIME,
    ));
    var x_error: ?*c.xcb_generic_error_t = null;
    const reply = c.xcb_get_selection_owner_reply(
        self.connection,
        c.xcb_get_selection_owner(self.connection, selection_atom),
        &x_error,
    ) orelse {
        if (x_error) |err| {
            logX11Error("get selection owner", err);
            std.c.free(err);
        }
        return error.SelectionClaimFailed;
    };
    defer std.c.free(reply);
    if (x_error) |err| {
        logX11Error("get selection owner", err);
        std.c.free(err);
        return error.SelectionClaimFailed;
    }
    if (reply.*.owner != self.wm_window) return error.SelectionClaimFailed;
}

fn atomValue(self: *const Self, name: Atom) c.xcb_atom_t {
    return self.atoms[@intFromEnum(name)];
}

fn checkRequest(
    connection: *c.xcb_connection_t,
    cookie: c.xcb_void_cookie_t,
) !void {
    const x_error = c.xcb_request_check(connection, cookie) orelse return;
    defer std.c.free(x_error);
    logX11Error("checked request", x_error);
    return error.X11RequestFailed;
}

fn handleEvents(_: std.posix.fd_t, mask: wl.EventMask, self: *Self) c_int {
    if (mask.hangup or mask.@"error") {
        self.listener.failed(self.listener.context);
        return 0;
    }
    var processed = false;
    while (c.xcb_poll_for_event(self.connection)) |event| {
        processed = true;
        if (event.*.response_type & 0x7f == 0) {
            const x_error: *const c.xcb_generic_error_t = @ptrCast(event);
            if (expectedDestroyedWindowError(x_error)) {
                log.debug("ignored X11 request racing window destruction", .{});
            } else {
                logX11Error("event", x_error);
            }
        } else {
            self.dispatchEvent(event) catch |err| {
                log.err("failed to process X11 event: {t}", .{err});
                std.c.free(event);
                self.listener.failed(self.listener.context);
                return 0;
            };
        }
        std.c.free(event);
    }
    if (processed) {
        if (c.xcb_flush(self.connection) <= 0) {
            self.listener.failed(self.listener.context);
            return 0;
        }
    }
    if (c.xcb_connection_has_error(self.connection) != 0) {
        self.listener.failed(self.listener.context);
        return 0;
    }
    return @intFromBool(processed);
}

fn dispatchEvent(self: *Self, event: [*c]c.xcb_generic_event_t) !void {
    const response_type = event.*.response_type & 0x7f;
    if (event.*.response_type & 0x80 != 0) {
        const protocol_root = switch (response_type) {
            c.XCB_UNMAP_NOTIFY => @as(*const c.xcb_unmap_notify_event_t, @ptrCast(event)).event,
            c.XCB_CONFIGURE_REQUEST => @as(*const c.xcb_configure_request_event_t, @ptrCast(event)).parent,
            else => null,
        };
        if (!acceptsSyntheticEvent(response_type, protocol_root, self.screen.root)) return;
    }
    if (response_type == self.xfixes_event_base + c.XCB_XFIXES_SELECTION_NOTIFY) {
        self.clipboard_selection.handleXfixesNotify(@ptrCast(event));
        self.primary_selection.handleXfixesNotify(@ptrCast(event));
        self.dnd_selection.handleXfixesNotify(@ptrCast(event));
        self.dnd.handleXfixesNotify(@ptrCast(event));
        return;
    }
    switch (response_type) {
        c.XCB_CREATE_NOTIFY => try self.handleCreate(@ptrCast(event)),
        c.XCB_DESTROY_NOTIFY => self.handleDestroy(@ptrCast(event)),
        c.XCB_MAP_REQUEST => try self.handleMapRequest(@ptrCast(event)),
        c.XCB_MAP_NOTIFY => try self.handleMapNotify(@ptrCast(event)),
        c.XCB_UNMAP_NOTIFY => self.handleUnmapNotify(@ptrCast(event)),
        c.XCB_CONFIGURE_REQUEST => self.handleConfigureRequest(@ptrCast(event)),
        c.XCB_CONFIGURE_NOTIFY => try self.handleConfigureNotify(@ptrCast(event)),
        c.XCB_PROPERTY_NOTIFY => try self.handlePropertyNotify(@ptrCast(event)),
        c.XCB_CLIENT_MESSAGE => try self.handleClientMessage(@ptrCast(event)),
        c.XCB_SELECTION_REQUEST => self.handleSelectionRequest(@ptrCast(event)),
        c.XCB_SELECTION_NOTIFY => {
            self.clipboard_selection.handleNotify(@ptrCast(event));
            self.primary_selection.handleNotify(@ptrCast(event));
            self.dnd_selection.handleNotify(@ptrCast(event));
        },
        else => {},
    }
}

fn acceptsSyntheticEvent(
    response_type: u8,
    protocol_root: ?c.xcb_window_t,
    root: c.xcb_window_t,
) bool {
    return switch (response_type) {
        // Client messages and selection replies are defined as sent events.
        c.XCB_CLIENT_MESSAGE, c.XCB_SELECTION_NOTIFY => true,
        // ICCCM withdrawal and reconfiguration fallbacks are sent to the root.
        c.XCB_UNMAP_NOTIFY, c.XCB_CONFIGURE_REQUEST => protocol_root == root,
        else => false,
    };
}

fn handleCreate(self: *Self, event: *const c.xcb_create_notify_event_t) !void {
    if (event.window == self.wm_window or
        self.clipboard_selection.ownsWindow(event.window) or
        self.primary_selection.ownsWindow(event.window) or
        self.dnd_selection.ownsWindow(event.window) or
        self.windows.contains(event.window)) return;
    const window: Window = .{
        .geometry = .{
            .x = event.x,
            .y = event.y,
            .width = event.width,
            .height = event.height,
        },
        .override_redirect = event.override_redirect != 0,
    };
    try self.windows.put(self.allocator, event.window, window);
    const event_mask: u32 = c.XCB_EVENT_MASK_PROPERTY_CHANGE |
        c.XCB_EVENT_MASK_FOCUS_CHANGE;
    _ = c.xcb_change_window_attributes(
        self.connection,
        event.window,
        c.XCB_CW_EVENT_MASK,
        &event_mask,
    );
    self.listener.created(self.listener.context, self.info(event.window, window));
}

fn handleDestroy(self: *Self, event: *const c.xcb_destroy_notify_event_t) void {
    self.clipboard_selection.handleRequestorDestroyed(event.window);
    self.primary_selection.handleRequestorDestroyed(event.window);
    self.dnd_selection.handleRequestorDestroyed(event.window);
    self.dnd.windowDestroyed(event.window);
    self.removeWindow(event.window);
}

fn handleSelectionRequest(self: *Self, event: *const c.xcb_selection_request_event_t) void {
    if (self.clipboard_selection.handlesSelection(event.selection)) {
        self.clipboard_selection.handleRequest(event);
    } else if (self.primary_selection.handlesSelection(event.selection)) {
        self.primary_selection.handleRequest(event);
    } else if (self.dnd_selection.handlesSelection(event.selection)) {
        self.dnd_selection.handleRequest(event);
    }
}

fn removeWindow(self: *Self, window_id: WindowId) void {
    if (self.focused_window == window_id) {
        self.focusWindow(null) catch log.err("failed to clear X11 input focus", .{});
    }
    const removed = self.windows.fetchRemove(window_id) orelse return;
    self.updateClientListMembership(window_id, false) catch unreachable;
    if (removed.value.serial) |serial|
        std.debug.assert(self.serial_windows.remove(serial));
    self.listener.destroyed(self.listener.context, window_id);
    if (removed.value.surface_id) |surface_id|
        self.listener.dissociated(self.listener.context, window_id, surface_id);
    var children = self.windows.iterator();
    while (children.next()) |entry| {
        if (entry.value_ptr.parent != window_id) continue;
        entry.value_ptr.parent = null;
        self.listener.metadata_changed(self.listener.context, entry.key_ptr.*);
    }
    var window = removed.value;
    window.deinit(self.allocator);
}

fn handleMapRequest(self: *Self, event: *const c.xcb_map_request_event_t) !void {
    const window = self.windows.getPtr(event.window) orelse return;
    if (try self.refreshMetadata(event.window, window)) {
        self.listener.metadata_changed(self.listener.context, event.window);
    }
    _ = try self.refreshNetWmState(event.window, window);
    self.refreshInputModel(event.window, window);
    self.refreshProtocols(event.window, window);
    if (!window.override_redirect) {
        self.setWmState(
            event.window,
            if (window.minimized)
                c.XCB_ICCCM_WM_STATE_ICONIC
            else
                c.XCB_ICCCM_WM_STATE_NORMAL,
        );
    }
    _ = c.xcb_map_window(self.connection, event.window);
}

fn handleMapNotify(self: *Self, event: *const c.xcb_map_notify_event_t) !void {
    const window = self.windows.getPtr(event.window) orelse return;
    const override_redirect = event.override_redirect != 0;
    if (window.override_redirect != override_redirect) {
        window.override_redirect = override_redirect;
        if (override_redirect and self.focused_window == event.window) {
            self.focusWindow(null) catch log.err("failed to clear X11 input focus", .{});
        }
        self.listener.configured(
            self.listener.context,
            event.window,
            window.geometry,
            override_redirect,
        );
        if (try self.refreshWindowType(event.window, window)) {
            self.listener.metadata_changed(self.listener.context, event.window);
        }
    }
    if (window.mapped) return;
    if (override_redirect and try self.refreshMetadata(event.window, window)) {
        self.listener.metadata_changed(self.listener.context, event.window);
    }
    window.mapped = true;
    try self.updateClientListMembership(event.window, !override_redirect);
    self.listener.mapped(self.listener.context, event.window, true);
}

fn handleUnmapNotify(self: *Self, event: *const c.xcb_unmap_notify_event_t) void {
    const window = self.windows.getPtr(event.window) orelse return;
    if (self.focused_window == event.window) {
        self.focusWindow(null) catch log.err("failed to clear X11 input focus", .{});
    }
    if (window.surface_id) |surface_id|
        self.listener.dissociated(self.listener.context, event.window, surface_id);
    if (window.serial) |serial|
        std.debug.assert(self.serial_windows.remove(serial));
    self.updateClientListMembership(event.window, false) catch unreachable;
    window.serial = null;
    window.surface_id = null;
    if (!window.mapped) return;
    window.mapped = false;
    if (!window.override_redirect) {
        self.setWmState(event.window, c.XCB_ICCCM_WM_STATE_WITHDRAWN);
    }
    self.listener.mapped(self.listener.context, event.window, false);
}

fn handlePropertyNotify(self: *Self, event: *const c.xcb_property_notify_event_t) !void {
    if (self.clipboard_selection.handlePropertyNotify(event)) return;
    if (self.primary_selection.handlePropertyNotify(event)) return;
    if (self.dnd_selection.handlePropertyNotify(event)) return;
    const window = self.windows.getPtr(event.window) orelse return;
    if (event.atom == self.atomValue(.net_wm_name) or
        event.atom == c.XCB_ATOM_WM_NAME or
        event.atom == c.XCB_ATOM_WM_CLASS or
        event.atom == c.XCB_ATOM_WM_TRANSIENT_FOR or
        event.atom == c.XCB_ATOM_WM_NORMAL_HINTS or
        event.atom == self.atomValue(.net_wm_window_type) or
        event.atom == self.atomValue(.motif_wm_hints))
    {
        if (try self.refreshMetadata(event.window, window)) {
            self.listener.metadata_changed(self.listener.context, event.window);
        }
    } else if (event.atom == c.XCB_ATOM_WM_HINTS) {
        self.refreshInputModel(event.window, window);
    } else if (event.atom == self.atomValue(.wm_protocols)) {
        self.refreshProtocols(event.window, window);
    } else if (event.atom == self.atomValue(.net_wm_state)) {
        const changed = try self.refreshNetWmState(event.window, window);
        if (window.mapped and !window.override_redirect) {
            if (changed.fullscreen) {
                self.listener.fullscreen_requested(
                    self.listener.context,
                    event.window,
                    window.fullscreen,
                );
            }
            if (changed.maximized) {
                self.listener.maximize_requested(
                    self.listener.context,
                    event.window,
                    window.maximized_horz and window.maximized_vert,
                );
            }
            if (changed.minimized) {
                self.setWmState(
                    event.window,
                    if (window.minimized)
                        c.XCB_ICCCM_WM_STATE_ICONIC
                    else
                        c.XCB_ICCCM_WM_STATE_NORMAL,
                );
                self.listener.minimize_requested(
                    self.listener.context,
                    event.window,
                    window.minimized,
                );
            }
            if (changed.skip_taskbar or changed.modal) {
                self.listener.metadata_changed(self.listener.context, event.window);
            }
        }
    }
}

fn handleConfigureRequest(
    self: *Self,
    event: *const c.xcb_configure_request_event_t,
) void {
    const window = self.windows.getPtr(event.window) orelse return;
    if (!window.clientControlsGeometry()) {
        self.sendConfigureNotify(event.window, window.*);
        return;
    }
    var requested = window.geometry;
    if (event.value_mask & c.XCB_CONFIG_WINDOW_X != 0) requested.x = event.x;
    if (event.value_mask & c.XCB_CONFIG_WINDOW_Y != 0) requested.y = event.y;
    if (event.value_mask & c.XCB_CONFIG_WINDOW_WIDTH != 0) requested.width = event.width;
    if (event.value_mask & c.XCB_CONFIG_WINDOW_HEIGHT != 0) requested.height = event.height;
    const values = [_]u32{
        signedValue(requested.x),
        signedValue(requested.y),
        requested.width,
        requested.height,
        0,
    };
    _ = c.xcb_configure_window(
        self.connection,
        event.window,
        c.XCB_CONFIG_WINDOW_X |
            c.XCB_CONFIG_WINDOW_Y |
            c.XCB_CONFIG_WINDOW_WIDTH |
            c.XCB_CONFIG_WINDOW_HEIGHT |
            c.XCB_CONFIG_WINDOW_BORDER_WIDTH,
        &values,
    );
    if (!window.override_redirect and std.meta.eql(window.geometry, requested))
        self.sendConfigureNotify(event.window, window.*);
}

fn handleConfigureNotify(
    self: *Self,
    event: *const c.xcb_configure_notify_event_t,
) !void {
    const window = self.windows.getPtr(event.window) orelse return;
    const geometry: Geometry = .{
        .x = event.x,
        .y = event.y,
        .width = event.width,
        .height = event.height,
    };
    const override_redirect = event.override_redirect != 0;
    if (std.meta.eql(window.geometry, geometry) and
        window.override_redirect == override_redirect) return;
    window.geometry = geometry;
    const override_redirect_changed = window.override_redirect != override_redirect;
    window.override_redirect = override_redirect;
    if (override_redirect_changed and window.mapped) {
        try self.updateClientListMembership(event.window, !override_redirect);
    }
    if (override_redirect and self.focused_window == event.window) {
        self.focusWindow(null) catch log.err("failed to clear X11 input focus", .{});
    }
    self.listener.configured(
        self.listener.context,
        event.window,
        geometry,
        override_redirect,
    );
    if (override_redirect_changed and try self.refreshWindowType(event.window, window)) {
        self.listener.metadata_changed(self.listener.context, event.window);
    }
}

fn sendConfigureNotify(self: *Self, window_id: WindowId, window: Window) void {
    var event: c.xcb_configure_notify_event_t = std.mem.zeroes(c.xcb_configure_notify_event_t);
    event.response_type = c.XCB_CONFIGURE_NOTIFY;
    event.event = window_id;
    event.window = window_id;
    event.above_sibling = c.XCB_WINDOW_NONE;
    event.x = window.geometry.x;
    event.y = window.geometry.y;
    event.width = window.geometry.width;
    event.height = window.geometry.height;
    event.override_redirect = @intFromBool(window.override_redirect);
    _ = c.xcb_send_event(
        self.connection,
        0,
        window_id,
        c.XCB_EVENT_MASK_STRUCTURE_NOTIFY,
        @ptrCast(&event),
    );
}

fn handleClientMessage(
    self: *Self,
    event: *const c.xcb_client_message_event_t,
) !void {
    if (event.format != 32) return;
    if (self.dnd.handleClientMessage(event)) return;
    if (event.type == self.atomValue(.wm_change_state)) {
        self.handleWmChangeStateMessage(event);
        return;
    }
    if (event.type == self.atomValue(.net_wm_state)) {
        try self.handleNetWmStateMessage(event);
        return;
    }
    if (event.type == self.atomValue(.net_active_window)) {
        self.handleNetActiveWindowMessage(event);
        return;
    }
    if (event.type == self.atomValue(.net_close_window)) {
        self.handleNetCloseWindowMessage(event);
        return;
    }
    if (event.type == self.atomValue(.net_wm_moveresize)) {
        self.handleNetWmMoveResizeMessage(event);
        return;
    }
    if (event.type != self.atomValue(.wl_surface_serial)) return;
    const window = self.windows.getPtr(event.window) orelse return;
    const serial = @as(u64, event.data.data32[1]) << 32 | event.data.data32[0];
    if (serial == 0 or window.serial != null or self.serial_windows.contains(serial)) {
        log.warn("ignored invalid surface serial for X11 window {d}", .{event.window});
        return;
    }
    try self.serial_windows.put(self.allocator, serial, event.window);
    window.serial = serial;
    self.listener.serial(self.listener.context, event.window, serial);
}

fn handleNetWmStateMessage(self: *Self, event: *const c.xcb_client_message_event_t) !void {
    const window = self.windows.getPtr(event.window) orelse return;
    if (!window.mapped or window.override_redirect) return;
    var requested_fullscreen = window.fullscreen;
    var requested_maximized_horz = window.maximized_horz;
    var requested_maximized_vert = window.maximized_vert;
    var requested_minimized = window.minimized;
    var requested_skip_taskbar = window.skip_taskbar;
    var requested_modal = window.modal;
    const atoms = [_]c.xcb_atom_t{ event.data.data32[1], event.data.data32[2] };
    for (atoms) |atom| {
        if (atom == self.atomValue(.net_wm_state_modal)) {
            requested_modal = applyStateAction(
                requested_modal,
                event.data.data32[0],
            ) orelse return;
        } else if (atom == self.atomValue(.net_wm_state_fullscreen)) {
            requested_fullscreen = applyStateAction(
                requested_fullscreen,
                event.data.data32[0],
            ) orelse return;
        } else if (atom == self.atomValue(.net_wm_state_maximized_horz)) {
            requested_maximized_horz = applyStateAction(
                requested_maximized_horz,
                event.data.data32[0],
            ) orelse return;
        } else if (atom == self.atomValue(.net_wm_state_maximized_vert)) {
            requested_maximized_vert = applyStateAction(
                requested_maximized_vert,
                event.data.data32[0],
            ) orelse return;
        } else if (atom == self.atomValue(.net_wm_state_hidden)) {
            requested_minimized = applyStateAction(
                requested_minimized,
                event.data.data32[0],
            ) orelse return;
        } else if (atom == self.atomValue(.net_wm_state_skip_taskbar)) {
            requested_skip_taskbar = applyStateAction(
                requested_skip_taskbar,
                event.data.data32[0],
            ) orelse return;
        }
    }
    if (requested_fullscreen != window.fullscreen) {
        self.listener.fullscreen_requested(
            self.listener.context,
            event.window,
            requested_fullscreen,
        );
    }
    const maximized = window.maximized_horz and window.maximized_vert;
    const requested_maximized = requested_maximized_horz and requested_maximized_vert;
    if (requested_maximized != maximized) {
        self.listener.maximize_requested(
            self.listener.context,
            event.window,
            requested_maximized,
        );
    }
    if (requested_minimized != window.minimized) {
        self.listener.minimize_requested(
            self.listener.context,
            event.window,
            requested_minimized,
        );
    }
    const metadata_changed = requested_skip_taskbar != window.skip_taskbar or
        requested_modal != window.modal;
    if (requested_skip_taskbar != window.skip_taskbar) {
        const atom = self.atomValue(.net_wm_state_skip_taskbar);
        try self.replaceNetWmStateAtoms(
            event.window,
            window,
            &.{atom},
            if (requested_skip_taskbar) &.{atom} else &.{},
        );
        window.skip_taskbar = requested_skip_taskbar;
    }
    if (requested_modal != window.modal) {
        const atom = self.atomValue(.net_wm_state_modal);
        try self.replaceNetWmStateAtoms(
            event.window,
            window,
            &.{atom},
            if (requested_modal) &.{atom} else &.{},
        );
        window.modal = requested_modal;
    }
    if (metadata_changed) {
        self.listener.metadata_changed(self.listener.context, event.window);
    }
}

fn handleWmChangeStateMessage(self: *Self, event: *const c.xcb_client_message_event_t) void {
    const window = self.windows.get(event.window) orelse return;
    if (!window.mapped or window.override_redirect or window.minimized or
        event.data.data32[0] != c.XCB_ICCCM_WM_STATE_ICONIC) return;
    self.listener.minimize_requested(self.listener.context, event.window, true);
}

fn handleNetActiveWindowMessage(self: *Self, event: *const c.xcb_client_message_event_t) void {
    const window = self.windows.get(event.window) orelse return;
    if (!window.mapped or window.override_redirect or self.focused_window == event.window) return;
    self.listener.activation_requested(self.listener.context, event.window);
}

fn handleNetCloseWindowMessage(self: *Self, event: *const c.xcb_client_message_event_t) void {
    const window = self.windows.get(event.window) orelse return;
    if (!window.mapped or window.override_redirect) return;
    self.closeWindow(event.window);
}

fn handleNetWmMoveResizeMessage(self: *Self, event: *const c.xcb_client_message_event_t) void {
    const window = self.windows.get(event.window) orelse return;
    if (!window.mapped or window.override_redirect) return;
    const request = moveResizeRequest(event.data.data32[2]) orelse return;
    self.listener.move_resize_requested(
        self.listener.context,
        event.window,
        request,
        event.data.data32[3],
    );
}

fn info(self: *const Self, window_id: WindowId, window: Window) WindowInfo {
    return .{
        .id = window_id,
        .geometry = window.geometry,
        .override_redirect = window.override_redirect,
        .override_redirect_wants_focus = window.override_redirect_wants_focus,
        .mapped = window.mapped,
        .activated = self.focused_window == window_id,
        .surface_id = window.surface_id,
        .title = window.title,
        .app_id = window.app_id,
        .instance = window.instance,
        .parent = window.parent,
        .window_type = window.window_type,
        .min_size = window.min_size,
        .max_size = window.max_size,
        .can_close = window.delete_window,
        .unreliable_pid = window.unreliable_pid,
        .modal = window.modal,
        .fullscreen = window.fullscreen,
        .maximized = window.maximized_horz and window.maximized_vert,
        .minimized = window.minimized,
        .skip_taskbar = window.skip_taskbar,
        .prefers_server_decorations = window.prefers_server_decorations,
    };
}

fn applyStateAction(current: bool, action: u32) ?bool {
    return switch (action) {
        0 => false,
        1 => true,
        2 => !current,
        else => null,
    };
}

fn moveResizeRequest(direction: u32) ?MoveResizeRequest {
    return switch (direction) {
        0 => .{ .resize = .{ .top = true, .left = true } },
        1 => .{ .resize = .{ .top = true } },
        2 => .{ .resize = .{ .top = true, .right = true } },
        3 => .{ .resize = .{ .right = true } },
        4 => .{ .resize = .{ .bottom = true, .right = true } },
        5 => .{ .resize = .{ .bottom = true } },
        6 => .{ .resize = .{ .bottom = true, .left = true } },
        7 => .{ .resize = .{ .left = true } },
        8 => .move,
        11 => .cancel,
        else => null,
    };
}

fn signedValue(value: i16) u32 {
    return @bitCast(@as(i32, value));
}

fn logX11Error(operation: []const u8, x_error: *const c.xcb_generic_error_t) void {
    log.err(
        "X11 {s} failed: error={d} major={d} minor={d} resource={d}",
        .{
            operation,
            x_error.error_code,
            x_error.major_code,
            x_error.minor_code,
            x_error.resource_id,
        },
    );
}

fn expectedDestroyedWindowError(x_error: *const c.xcb_generic_error_t) bool {
    return x_error.error_code == c.XCB_WINDOW and
        x_error.major_code == c.XCB_CHANGE_PROPERTY;
}

test "XWM atom table covers every atom" {
    try std.testing.expectEqual(atom_count, atom_names.len);
}

test "synthetic X11 events admit only protocol-defined client messages" {
    const root: c.xcb_window_t = 42;
    try std.testing.expect(acceptsSyntheticEvent(c.XCB_CLIENT_MESSAGE, null, root));
    try std.testing.expect(acceptsSyntheticEvent(c.XCB_SELECTION_NOTIFY, null, root));
    try std.testing.expect(acceptsSyntheticEvent(c.XCB_UNMAP_NOTIFY, root, root));
    try std.testing.expect(acceptsSyntheticEvent(c.XCB_CONFIGURE_REQUEST, root, root));
    try std.testing.expect(!acceptsSyntheticEvent(c.XCB_UNMAP_NOTIFY, 7, root));
    try std.testing.expect(!acceptsSyntheticEvent(c.XCB_CONFIGURE_REQUEST, 7, root));
    try std.testing.expect(!acceptsSyntheticEvent(c.XCB_DESTROY_NOTIFY, null, root));
    try std.testing.expect(!acceptsSyntheticEvent(c.XCB_CONFIGURE_NOTIFY, null, root));
    try std.testing.expect(!acceptsSyntheticEvent(c.XCB_PROPERTY_NOTIFY, null, root));
}

test "EWMH state actions apply remove add and toggle" {
    try std.testing.expectEqual(false, applyStateAction(true, 0).?);
    try std.testing.expectEqual(true, applyStateAction(false, 1).?);
    try std.testing.expectEqual(false, applyStateAction(true, 2).?);
    try std.testing.expectEqual(true, applyStateAction(false, 2).?);
    try std.testing.expectEqual(null, applyStateAction(false, 3));
}

test "EWMH state replacement removes duplicates before appending" {
    const atoms = try replacedAtomList(
        std.testing.allocator,
        &.{ 1, 2, 3, 2 },
        &.{2},
        &.{4},
    );
    defer std.testing.allocator.free(atoms);
    try std.testing.expectEqualSlices(c.xcb_atom_t, &.{ 1, 3, 4 }, atoms);
}

test "EWMH moveresize directions map to compositor requests" {
    try std.testing.expectEqual(MoveResizeRequest.move, moveResizeRequest(8).?);
    try std.testing.expectEqual(MoveResizeRequest.cancel, moveResizeRequest(11).?);
    try std.testing.expectEqual(
        MoveResizeRequest{ .resize = .{ .top = true, .left = true } },
        moveResizeRequest(0).?,
    );
    try std.testing.expectEqual(
        MoveResizeRequest{ .resize = .{ .bottom = true, .right = true } },
        moveResizeRequest(4).?,
    );
    try std.testing.expectEqual(null, moveResizeRequest(9));
    try std.testing.expectEqual(null, moveResizeRequest(10));
    try std.testing.expectEqual(null, moveResizeRequest(12));
}

test "EWMH window type fallback follows transient and override-redirect rules" {
    try std.testing.expectEqual(WindowType.normal, defaultWindowType(false, false));
    try std.testing.expectEqual(WindowType.dialog, defaultWindowType(false, true));
    try std.testing.expectEqual(WindowType.normal, defaultWindowType(true, false));
    try std.testing.expectEqual(WindowType.normal, defaultWindowType(true, true));
}

test "EWMH auxiliary window types bypass toplevel policy" {
    try std.testing.expect(WindowType.normal.participatesInWindowManagement());
    try std.testing.expect(WindowType.dialog.participatesInWindowManagement());
    try std.testing.expect(WindowType.utility.participatesInWindowManagement());
    try std.testing.expect(!WindowType.desktop.participatesInWindowManagement());
    try std.testing.expect(!WindowType.dock.participatesInWindowManagement());
    try std.testing.expect(!WindowType.splash.participatesInWindowManagement());
    try std.testing.expect(!WindowType.tooltip.participatesInWindowManagement());
    try std.testing.expect(!WindowType.notification.participatesInWindowManagement());
    try std.testing.expect(!WindowType.dnd.participatesInWindowManagement());
}

test "mapped managed windows retain compositor geometry authority" {
    var window: Window = .{
        .geometry = .{ .x = 0, .y = 0, .width = 640, .height = 480 },
        .override_redirect = false,
    };
    try std.testing.expect(window.clientControlsGeometry());
    window.mapped = true;
    try std.testing.expect(!window.clientControlsGeometry());
    window.window_type = .dock;
    try std.testing.expect(window.clientControlsGeometry());
    window.window_type = .normal;
    window.override_redirect = true;
    try std.testing.expect(window.clientControlsGeometry());
}

test "override-redirect input heuristic excludes transient UI types" {
    try std.testing.expect(!windowTypePreventsOverrideRedirectFocus(.normal));
    try std.testing.expect(!windowTypePreventsOverrideRedirectFocus(.dialog));
    try std.testing.expect(windowTypePreventsOverrideRedirectFocus(.menu));
    try std.testing.expect(windowTypePreventsOverrideRedirectFocus(.utility));
    try std.testing.expect(windowTypePreventsOverrideRedirectFocus(.splash));
    try std.testing.expect(windowTypePreventsOverrideRedirectFocus(.dropdown_menu));
    try std.testing.expect(windowTypePreventsOverrideRedirectFocus(.popup_menu));
    try std.testing.expect(windowTypePreventsOverrideRedirectFocus(.tooltip));
    try std.testing.expect(windowTypePreventsOverrideRedirectFocus(.notification));
    try std.testing.expect(windowTypePreventsOverrideRedirectFocus(.combo));
    try std.testing.expect(windowTypePreventsOverrideRedirectFocus(.dnd));
}

test "Motif hints reduce partial decorations to client-side decoration" {
    try std.testing.expectEqual(null, motifPrefersServerDecorations(&.{ 0, 0, 0, 0, 0 }));
    try std.testing.expectEqual(true, motifPrefersServerDecorations(&.{ 2, 0, 1, 0, 0 }));
    try std.testing.expectEqual(true, motifPrefersServerDecorations(&.{ 2, 0, 10, 0, 0 }));
    try std.testing.expectEqual(false, motifPrefersServerDecorations(&.{ 2, 0, 0, 0, 0 }));
    try std.testing.expectEqual(false, motifPrefersServerDecorations(&.{ 2, 0, 2, 0, 0 }));
    try std.testing.expectEqual(false, motifPrefersServerDecorations(&.{ 2, 0, 8, 0, 0 }));
}
