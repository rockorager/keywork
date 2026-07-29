//! X11 and Wayland drag-and-drop interoperability.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const DataDevice = @import("../wayland/data_device.zig");
const XSelection = @import("selection.zig");
const c = @import("xcb.zig").c;

const wl = wayland.server.wl;
const log = std.log.scoped(.xwayland_dnd);

const protocol_version: u32 = 5;

allocator: std.mem.Allocator,
connection: *c.xcb_connection_t,
screen: *c.xcb_screen_t,
data_device: *DataDevice,
selection: *XSelection,
atoms: Atoms,
target: ?Target,
last_unaware: ?c.xcb_window_t,
dropped: bool,
incoming_owner: c.xcb_window_t,
incoming_source: c.xcb_window_t,
incoming_generation: ?u64,
incoming_version: u32,
incoming_timestamp: c.xcb_timestamp_t,
incoming_actions: wl.DataDeviceManager.DndAction,
incoming_selected_action: wl.DataDeviceManager.DndAction,
incoming_target_accepted: bool,
incoming_mime_types: std.ArrayList([:0]u8),
incoming_target_atoms: std.ArrayList(c.xcb_atom_t),
incoming_x_dropped: bool,
incoming_wl_cancelled: bool,
incoming_wl_finished: bool,
proxy_mapped: bool,
external_source: DataDevice.ExternalDragSource,

pub const Atoms = struct {
    aware: c.xcb_atom_t,
    enter: c.xcb_atom_t,
    position: c.xcb_atom_t,
    status: c.xcb_atom_t,
    leave: c.xcb_atom_t,
    drop: c.xcb_atom_t,
    finished: c.xcb_atom_t,
    proxy: c.xcb_atom_t,
    type_list: c.xcb_atom_t,
    action_copy: c.xcb_atom_t,
    action_move: c.xcb_atom_t,
    action_ask: c.xcb_atom_t,
    action_private: c.xcb_atom_t,
};

const Target = struct {
    surface_window: c.xcb_window_t,
    destination: c.xcb_window_t,
    version: u32,
    generation: u64,
    accepted: bool = false,
    action: wl.DataDeviceManager.DndAction = .{},
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    connection: *c.xcb_connection_t,
    screen: *c.xcb_screen_t,
    data_device: *DataDevice,
    selection: *XSelection,
    atoms: Atoms,
) !void {
    self.* = .{
        .allocator = allocator,
        .connection = connection,
        .screen = screen,
        .data_device = data_device,
        .selection = selection,
        .atoms = atoms,
        .target = null,
        .last_unaware = null,
        .dropped = false,
        .incoming_owner = c.XCB_WINDOW_NONE,
        .incoming_source = c.XCB_WINDOW_NONE,
        .incoming_generation = null,
        .incoming_version = 0,
        .incoming_timestamp = c.XCB_CURRENT_TIME,
        .incoming_actions = copyAction(),
        .incoming_selected_action = .{},
        .incoming_target_accepted = false,
        .incoming_mime_types = .empty,
        .incoming_target_atoms = .empty,
        .incoming_x_dropped = false,
        .incoming_wl_cancelled = false,
        .incoming_wl_finished = false,
        .proxy_mapped = false,
        .external_source = .{
            .context = self,
            .mime_types = externalMimeTypes,
            .actions = externalActions,
            .send = externalSend,
            .target = externalTarget,
            .action = externalAction,
            .drop_performed = externalDropPerformed,
            .finished = externalFinished,
            .cancel = externalCancelled,
        },
    };
    errdefer self.incoming_mime_types.deinit(allocator);
    errdefer self.incoming_target_atoms.deinit(allocator);
    const version = protocol_version;
    try checkRequest(connection, c.xcb_change_property_checked(
        connection,
        c.XCB_PROP_MODE_REPLACE,
        selection.ownerWindow(),
        atoms.aware,
        c.XCB_ATOM_ATOM,
        32,
        1,
        &version,
    ));
}

pub fn deinit(self: *Self) void {
    self.clearIncoming(true);
    if (self.target) |target| {
        if (self.dropped) {
            self.data_device.finishExternalDrag(target.generation, false);
        } else {
            self.sendLeave(target);
            self.data_device.externalDragStatus(target.generation, false, .{});
        }
    }
    self.incoming_mime_types.deinit(self.allocator);
    self.incoming_target_atoms.deinit(self.allocator);
    self.* = undefined;
}

pub fn dragStarted(self: *Self) void {
    self.last_unaware = null;
    if (self.target) |target| {
        if (!self.dropped) self.sendLeave(target);
        self.target = null;
        self.dropped = false;
    }
    if (self.data_device.dragIsExternal()) self.setProxyMapped(true);
}

pub fn dragMotion(
    self: *Self,
    window: c.xcb_window_t,
    time: u32,
    x: f64,
    y: f64,
) void {
    if (self.dropped) return;
    const source = self.data_device.dragSourceInfo() orelse {
        self.dragLeft();
        return;
    };
    if (self.last_unaware == window) return;
    if (self.target) |target| {
        if (target.surface_window == window and target.generation == source.generation) {
            self.sendPosition(target, source.actions, time, x, y);
            return;
        }
        self.dragLeft();
    }
    const destination, const version = self.resolveTarget(window) orelse {
        self.last_unaware = window;
        return;
    };
    const target: Target = .{
        .surface_window = window,
        .destination = destination,
        .version = version,
        .generation = source.generation,
    };
    if (!self.sendEnter(target, source.mime_types)) return;
    self.target = target;
    self.sendPosition(target, source.actions, time, x, y);
}

pub fn dragLeft(self: *Self) void {
    self.last_unaware = null;
    const target = self.target orelse return;
    if (self.dropped) return;
    self.sendLeave(target);
    self.data_device.externalDragStatus(target.generation, false, .{});
    self.target = null;
}

pub fn drop(self: *Self, time: u32) bool {
    const target = self.target orelse return false;
    if (self.dropped) return true;
    const accepted = target.accepted and actionBits(target.action) != 0;
    if (accepted) {
        self.dropped = true;
        self.sendDrop(target, time);
    } else {
        self.sendLeave(target);
        self.data_device.externalDragStatus(target.generation, false, .{});
        self.target = null;
    }
    if (!self.data_device.dropOnExternalTarget(target.generation, accepted)) {
        self.target = null;
        self.dropped = false;
    }
    return true;
}

pub fn physicalDragEnded(self: *Self) void {
    if (self.incoming_generation != null) return;
    if (self.dropped) return;
    self.dragLeft();
}

pub fn sourceDestroyed(self: *Self, generation: u64) void {
    const target = self.target orelse return;
    if (target.generation != generation) return;
    self.target = null;
    self.dropped = false;
}

pub fn windowDestroyed(self: *Self, window: c.xcb_window_t) void {
    if (window == self.incoming_owner or window == self.incoming_source) {
        self.clearIncoming(true);
    }
    if (self.last_unaware == window) self.last_unaware = null;
    const target = self.target orelse return;
    if (target.surface_window != window and target.destination != window) return;
    if (self.dropped) {
        self.data_device.finishExternalDrag(target.generation, false);
    } else {
        self.data_device.externalDragStatus(target.generation, false, .{});
    }
    self.target = null;
    self.dropped = false;
}

pub fn handleXfixesNotify(
    self: *Self,
    event: *const c.xcb_xfixes_selection_notify_event_t,
) void {
    if (!self.selection.handlesSelection(event.selection) or
        event.window != self.selection.ownerWindow()) return;
    if (event.owner == self.selection.ownerWindow()) {
        self.clearIncoming(true);
        return;
    }
    if (event.owner == c.XCB_WINDOW_NONE) {
        self.clearIncoming(true);
        return;
    }
    if (self.incoming_owner == event.owner and self.incoming_generation != null) return;
    self.clearIncoming(true);
    if (self.data_device.isDragging()) {
        if (!self.data_device.dragIsExternal()) self.selection.reclaimWaylandSelection();
        return;
    }
    self.incoming_owner = event.owner;
    self.setProxyMapped(true);
    self.incoming_generation = self.data_device.startExternalDrag(&self.external_source) orelse {
        self.clearIncoming(false);
        return;
    };
    log.debug("started X11 drag from selection owner {d}", .{event.owner});
}

pub fn routeExternalDragOverXwayland(self: *Self, over_xwayland: bool) void {
    if (!self.data_device.dragIsExternal() or self.incoming_x_dropped) return;
    self.setProxyMapped(!over_xwayland);
}

pub fn handleClientMessage(self: *Self, event: *const c.xcb_client_message_event_t) bool {
    if (event.format != 32 or event.window != self.selection.ownerWindow()) return false;
    if (event.type == self.atoms.enter) {
        self.handleEnter(event);
        return true;
    }
    if (event.type == self.atoms.position) {
        self.handlePosition(event);
        return true;
    }
    if (event.type == self.atoms.leave) {
        self.handleIncomingLeave(event);
        return true;
    }
    if (event.type == self.atoms.drop) {
        self.handleIncomingDrop(event);
        return true;
    }
    if (event.type == self.atoms.status) {
        self.handleStatus(event);
        return true;
    }
    if (event.type == self.atoms.finished) {
        self.handleFinished(event);
        return true;
    }
    return false;
}

fn handleEnter(self: *Self, event: *const c.xcb_client_message_event_t) void {
    if (self.incoming_generation == null or self.incoming_x_dropped or
        event.data.data32[0] == c.XCB_WINDOW_NONE) return;
    if (self.incoming_source != c.XCB_WINDOW_NONE and
        self.incoming_source != event.data.data32[0]) return;
    const version = event.data.data32[1] >> 24;
    if (version < 3 or version > protocol_version) return;
    self.incoming_source = event.data.data32[0];
    self.incoming_version = version;
    self.incoming_actions = copyAction();
    self.incoming_selected_action = .{};
    self.incoming_target_accepted = false;
    self.clearIncomingMimeTypes();
    if (event.data.data32[1] & 1 != 0) {
        self.readIncomingTypeList();
    } else {
        for (event.data.data32[2..5]) |target_atom| self.offerIncomingTarget(target_atom);
    }
}

fn handlePosition(self: *Self, event: *const c.xcb_client_message_event_t) void {
    if (!self.incomingMessageMatches(event)) return;
    self.incoming_timestamp = event.data.data32[3];
    var actions = copyAction();
    if (event.data.data32[4] == self.atoms.action_move) {
        actions.move = true;
    } else if (event.data.data32[4] == self.atoms.action_ask) {
        actions.ask = true;
    }
    if (actionBits(actions) != actionBits(self.incoming_actions)) {
        self.incoming_actions = actions;
        self.data_device.externalDragActionsChanged(&self.external_source);
    }
    self.sendIncomingStatus();
}

fn handleIncomingLeave(self: *Self, event: *const c.xcb_client_message_event_t) void {
    if (!self.incomingMessageMatches(event) or self.incoming_x_dropped) return;
    self.incoming_source = c.XCB_WINDOW_NONE;
    self.incoming_version = 0;
    self.incoming_timestamp = c.XCB_CURRENT_TIME;
    self.incoming_actions = copyAction();
    self.incoming_selected_action = .{};
    self.incoming_target_accepted = false;
    self.clearIncomingMimeTypes();
    if (self.incoming_wl_cancelled or self.incoming_wl_finished) self.clearIncoming(false);
}

fn handleIncomingDrop(self: *Self, event: *const c.xcb_client_message_event_t) void {
    if (!self.incomingMessageMatches(event) or self.incoming_x_dropped) return;
    if (self.incoming_version >= 1 and event.data.data32[2] != 0) {
        self.incoming_timestamp = event.data.data32[2];
    }
    self.incoming_x_dropped = true;
    self.setProxyMapped(false);
    if (self.incoming_wl_finished) {
        self.finishIncoming(true);
    } else if (self.incoming_wl_cancelled) {
        self.finishIncoming(false);
    }
}

fn incomingMessageMatches(
    self: *const Self,
    event: *const c.xcb_client_message_event_t,
) bool {
    return self.incoming_generation != null and
        self.incoming_source != c.XCB_WINDOW_NONE and
        self.incoming_source == event.data.data32[0];
}

fn readIncomingTypeList(self: *Self) void {
    const reply = c.xcb_get_property_reply(
        self.connection,
        c.xcb_get_property(
            self.connection,
            0,
            self.incoming_source,
            self.atoms.type_list,
            c.XCB_ATOM_ATOM,
            0,
            4096,
        ),
        null,
    ) orelse return;
    defer std.c.free(reply);
    if (reply.*.type != c.XCB_ATOM_ATOM or reply.*.format != 32 or
        reply.*.bytes_after != 0) return;
    const value = c.xcb_get_property_value(reply) orelse return;
    const target_atoms: [*]const c.xcb_atom_t = @ptrCast(@alignCast(value));
    for (target_atoms[0..@intCast(reply.*.value_len)]) |target_atom| {
        self.offerIncomingTarget(target_atom);
    }
}

fn offerIncomingTarget(self: *Self, target_atom: c.xcb_atom_t) void {
    if (target_atom == c.XCB_ATOM_NONE or
        std.mem.indexOfScalar(c.xcb_atom_t, self.incoming_target_atoms.items, target_atom) != null) return;
    const mime_type = self.selection.mimeForTargetAtom(target_atom) orelse return;
    for (self.incoming_mime_types.items) |offered| {
        if (!std.mem.eql(u8, offered, mime_type)) continue;
        self.allocator.free(mime_type);
        return;
    }
    self.incoming_mime_types.append(self.allocator, mime_type) catch {
        self.allocator.free(mime_type);
        return;
    };
    self.incoming_target_atoms.append(self.allocator, target_atom) catch {
        self.allocator.free(self.incoming_mime_types.pop().?);
        return;
    };
    self.data_device.externalDragMimeOffered(&self.external_source, mime_type.ptr);
}

fn handleStatus(self: *Self, event: *const c.xcb_client_message_event_t) void {
    const target = if (self.target) |*value| value else return;
    if (self.dropped or !targetMatches(target.*, event.data.data32[0])) return;
    const requested_action = self.actionForAtom(event.data.data32[4]);
    const source = self.data_device.dragSourceInfo() orelse return;
    if (source.generation != target.generation) return;
    const accepted = event.data.data32[1] & 1 != 0 and
        actionBits(requested_action) & actionBits(source.actions) != 0;
    const selected: wl.DataDeviceManager.DndAction = if (accepted) requested_action else .{};
    if (target.accepted == accepted and actionBits(target.action) == actionBits(selected)) return;
    target.accepted = accepted;
    target.action = selected;
    self.data_device.externalDragStatus(target.generation, accepted, target.action);
}

fn handleFinished(self: *Self, event: *const c.xcb_client_message_event_t) void {
    const target = self.target orelse return;
    if (!self.dropped or !targetMatches(target, event.data.data32[0])) return;
    const performed = target.version < 5 or event.data.data32[1] & 1 != 0;
    self.data_device.finishExternalDrag(target.generation, performed);
    self.target = null;
    self.dropped = false;
}

fn sendIncomingStatus(self: *Self) void {
    if (self.incoming_source == c.XCB_WINDOW_NONE or self.incoming_x_dropped) return;
    const accepted = !self.incoming_wl_cancelled and self.incoming_target_accepted and
        actionBits(self.incoming_selected_action) != 0;
    self.sendEvent(self.incoming_source, self.atoms.status, .{
        self.selection.ownerWindow(),
        2 | @as(u32, @intFromBool(accepted)),
        0,
        0,
        if (accepted) self.atomForActions(self.incoming_selected_action) else c.XCB_ATOM_NONE,
    });
}

fn finishIncoming(self: *Self, success: bool) void {
    if (self.incoming_source != c.XCB_WINDOW_NONE and self.incoming_x_dropped) {
        self.sendEvent(self.incoming_source, self.atoms.finished, .{
            self.selection.ownerWindow(),
            @intFromBool(success),
            if (success) self.atomForActions(self.incoming_selected_action) else c.XCB_ATOM_NONE,
            0,
            0,
        });
    }
    self.clearIncoming(false);
}

fn clearIncoming(self: *Self, notify_data_device: bool) void {
    if (notify_data_device and self.incoming_generation != null) {
        self.data_device.externalDragSourceDestroyed(&self.external_source);
    }
    self.setProxyMapped(false);
    self.clearIncomingMimeTypes();
    self.incoming_owner = c.XCB_WINDOW_NONE;
    self.incoming_source = c.XCB_WINDOW_NONE;
    self.incoming_generation = null;
    self.incoming_version = 0;
    self.incoming_timestamp = c.XCB_CURRENT_TIME;
    self.incoming_actions = copyAction();
    self.incoming_selected_action = .{};
    self.incoming_target_accepted = false;
    self.incoming_x_dropped = false;
    self.incoming_wl_cancelled = false;
    self.incoming_wl_finished = false;
}

fn clearIncomingMimeTypes(self: *Self) void {
    for (self.incoming_mime_types.items) |mime_type| self.allocator.free(mime_type);
    self.incoming_mime_types.clearRetainingCapacity();
    self.incoming_target_atoms.clearRetainingCapacity();
}

fn setProxyMapped(self: *Self, mapped: bool) void {
    if (self.proxy_mapped == mapped) return;
    self.proxy_mapped = mapped;
    const window = self.selection.ownerWindow();
    if (mapped) {
        const override_redirect: u32 = 1;
        _ = c.xcb_change_window_attributes(
            self.connection,
            window,
            c.XCB_CW_OVERRIDE_REDIRECT,
            &override_redirect,
        );
        const width, const height = self.rootSize();
        const values = [_]u32{
            0,
            0,
            width,
            height,
            c.XCB_STACK_MODE_ABOVE,
        };
        _ = c.xcb_configure_window(
            self.connection,
            window,
            c.XCB_CONFIG_WINDOW_X |
                c.XCB_CONFIG_WINDOW_Y |
                c.XCB_CONFIG_WINDOW_WIDTH |
                c.XCB_CONFIG_WINDOW_HEIGHT |
                c.XCB_CONFIG_WINDOW_STACK_MODE,
            &values,
        );
        _ = c.xcb_map_window(self.connection, window);
    } else {
        _ = c.xcb_unmap_window(self.connection, window);
    }
    _ = c.xcb_flush(self.connection);
}

fn rootSize(self: *Self) struct { u16, u16 } {
    const reply = c.xcb_get_geometry_reply(
        self.connection,
        c.xcb_get_geometry(self.connection, self.screen.root),
        null,
    ) orelse return .{ self.screen.width_in_pixels, self.screen.height_in_pixels };
    defer std.c.free(reply);
    return .{ reply.*.width, reply.*.height };
}

fn externalMimeTypes(context: *anyopaque) []const [:0]const u8 {
    const self: *Self = @ptrCast(@alignCast(context));
    return @ptrCast(self.incoming_mime_types.items);
}

fn externalActions(context: *anyopaque) wl.DataDeviceManager.DndAction {
    const self: *Self = @ptrCast(@alignCast(context));
    return self.incoming_actions;
}

fn externalSend(context: *anyopaque, mime_type: [*:0]const u8, fd: std.posix.fd_t) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const requested = std.mem.span(mime_type);
    const target = for (self.incoming_mime_types.items, self.incoming_target_atoms.items) |offered, atom| {
        if (std.mem.eql(u8, offered, requested)) break atom;
    } else return;
    self.selection.receiveExternalData(target, self.incoming_timestamp, fd);
}

fn externalTarget(context: *anyopaque, mime_type: ?[*:0]const u8) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const accepted = mime_type != null;
    if (self.incoming_target_accepted == accepted) return;
    self.incoming_target_accepted = accepted;
    self.sendIncomingStatus();
}

fn externalAction(context: *anyopaque, selected: wl.DataDeviceManager.DndAction) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (actionBits(self.incoming_selected_action) == actionBits(selected)) return;
    self.incoming_selected_action = selected;
    self.sendIncomingStatus();
}

fn externalDropPerformed(_: *anyopaque) void {}

fn externalFinished(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.incoming_wl_finished = true;
    if (self.incoming_x_dropped) self.finishIncoming(true);
}

fn externalCancelled(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.incoming_wl_cancelled = true;
    if (self.incoming_x_dropped) {
        self.finishIncoming(false);
    } else {
        self.setProxyMapped(false);
    }
}

fn resolveTarget(self: *Self, window: c.xcb_window_t) ?struct { c.xcb_window_t, u32 } {
    var destination = window;
    if (self.readWindowProperty(window, self.atoms.proxy)) |proxy| {
        if (proxy != c.XCB_WINDOW_NONE and
            self.readWindowProperty(proxy, self.atoms.proxy) == proxy)
        {
            destination = proxy;
        }
    }
    const advertised = self.readVersion(destination) orelse return null;
    if (advertised < 3) {
        log.warn("ignored Xdnd target {d} with unsupported version {d}", .{
            destination,
            advertised,
        });
        return null;
    }
    return .{ destination, @min(advertised, protocol_version) };
}

fn readWindowProperty(
    self: *Self,
    window: c.xcb_window_t,
    property: c.xcb_atom_t,
) ?c.xcb_window_t {
    return self.readScalarProperty(window, property, c.XCB_ATOM_WINDOW);
}

fn readVersion(self: *Self, window: c.xcb_window_t) ?u32 {
    return self.readScalarProperty(window, self.atoms.aware, c.XCB_ATOM_ATOM);
}

fn readScalarProperty(
    self: *Self,
    window: c.xcb_window_t,
    property: c.xcb_atom_t,
    property_type: c.xcb_atom_t,
) ?u32 {
    const reply = c.xcb_get_property_reply(
        self.connection,
        c.xcb_get_property(
            self.connection,
            0,
            window,
            property,
            property_type,
            0,
            1,
        ),
        null,
    ) orelse return null;
    defer std.c.free(reply);
    if (reply.*.type != property_type or reply.*.format != 32 or
        reply.*.value_len != 1 or reply.*.bytes_after != 0) return null;
    const value = c.xcb_get_property_value(reply) orelse return null;
    return @as(*const u32, @ptrCast(@alignCast(value))).*;
}

fn sendEnter(
    self: *Self,
    target: Target,
    mime_types: []const [:0]const u8,
) bool {
    var target_atoms: std.ArrayList(c.xcb_atom_t) = .empty;
    defer target_atoms.deinit(self.allocator);
    for (mime_types) |mime_type| {
        const atom = self.selection.targetAtomForMime(mime_type) orelse continue;
        if (std.mem.indexOfScalar(c.xcb_atom_t, target_atoms.items, atom) != null) continue;
        target_atoms.append(self.allocator, atom) catch return false;
    }

    var data = [_]u32{ self.selection.ownerWindow(), target.version << 24, 0, 0, 0 };
    if (target_atoms.items.len > 3) {
        data[1] |= 1;
        _ = c.xcb_change_property(
            self.connection,
            c.XCB_PROP_MODE_REPLACE,
            self.selection.ownerWindow(),
            self.atoms.type_list,
            c.XCB_ATOM_ATOM,
            32,
            @intCast(target_atoms.items.len),
            target_atoms.items.ptr,
        );
    } else {
        _ = c.xcb_delete_property(
            self.connection,
            self.selection.ownerWindow(),
            self.atoms.type_list,
        );
        for (target_atoms.items, 0..) |atom, index| data[index + 2] = atom;
    }
    self.sendEvent(target.destination, self.atoms.enter, data);
    return true;
}

fn sendPosition(
    self: *Self,
    target: Target,
    source_actions: wl.DataDeviceManager.DndAction,
    time: u32,
    x: f64,
    y: f64,
) void {
    const packed_position = @as(u32, packedCoordinate(x)) << 16 | packedCoordinate(y);
    self.sendEvent(target.destination, self.atoms.position, .{
        self.selection.ownerWindow(),
        0,
        packed_position,
        time,
        self.atomForActions(source_actions),
    });
}

fn sendLeave(self: *Self, target: Target) void {
    self.sendEvent(target.destination, self.atoms.leave, .{
        self.selection.ownerWindow(),
        0,
        0,
        0,
        0,
    });
}

fn sendDrop(self: *Self, target: Target, time: u32) void {
    self.sendEvent(target.destination, self.atoms.drop, .{
        self.selection.ownerWindow(),
        0,
        time,
        0,
        0,
    });
}

fn sendEvent(
    self: *Self,
    destination: c.xcb_window_t,
    message_type: c.xcb_atom_t,
    data: [5]u32,
) void {
    var event = std.mem.zeroes(c.xcb_client_message_event_t);
    event.response_type = c.XCB_CLIENT_MESSAGE;
    event.format = 32;
    event.window = destination;
    event.type = message_type;
    event.data.data32 = data;
    _ = c.xcb_send_event(
        self.connection,
        0,
        destination,
        c.XCB_EVENT_MASK_NO_EVENT,
        @ptrCast(&event),
    );
    _ = c.xcb_flush(self.connection);
}

fn atomForActions(
    self: *const Self,
    actions: wl.DataDeviceManager.DndAction,
) c.xcb_atom_t {
    if (actions.copy) return self.atoms.action_copy;
    if (actions.move) return self.atoms.action_move;
    if (actions.ask) return self.atoms.action_ask;
    return c.XCB_ATOM_NONE;
}

fn actionForAtom(
    self: *const Self,
    atom: c.xcb_atom_t,
) wl.DataDeviceManager.DndAction {
    var action: wl.DataDeviceManager.DndAction = .{};
    if (atom == self.atoms.action_copy or atom == self.atoms.action_private) {
        action.copy = true;
    } else if (atom == self.atoms.action_move) {
        action.move = true;
    } else if (atom == self.atoms.action_ask) {
        action.ask = true;
    }
    return action;
}

fn actionBits(actions: wl.DataDeviceManager.DndAction) u32 {
    return @bitCast(actions);
}

fn copyAction() wl.DataDeviceManager.DndAction {
    var action: wl.DataDeviceManager.DndAction = .{};
    action.copy = true;
    return action;
}

fn targetMatches(target: Target, window: c.xcb_window_t) bool {
    return window == target.destination or window == target.surface_window;
}

fn packedCoordinate(value: f64) u16 {
    const bounded = std.math.clamp(
        @floor(value),
        @as(f64, @floatFromInt(std.math.minInt(i16))),
        @as(f64, @floatFromInt(std.math.maxInt(i16))),
    );
    return @bitCast(@as(i16, @intFromFloat(bounded)));
}

fn checkRequest(connection: *c.xcb_connection_t, cookie: c.xcb_void_cookie_t) !void {
    const x_error = c.xcb_request_check(connection, cookie) orelse return;
    defer std.c.free(x_error);
    return error.X11RequestFailed;
}
