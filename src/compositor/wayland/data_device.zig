//! Core data-device objects tied to the compositor seat.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Seat = @import("seat.zig");
const SelectionSource = @import("SelectionSource.zig");
const Surface = @import("surface.zig");
const MatureSerials = @import("mature_serials.zig");
const SeatAuthority = @import("../SeatAuthority.zig");
const slot_map = @import("../slot_map.zig");

const wl = wayland.server.wl;

allocator: std.mem.Allocator,
global: *wl.Global,
display: *wl.Server,
seat: *Seat,
surface_store: *Surface.Store,
listener: Listener,
sources: SourceStore,
source_adapters: std.AutoHashMapUnmanaged(SourceId, *SourceResource),
devices: DeviceStore,
device_adapters: std.AutoHashMapUnmanaged(DeviceId, *DeviceResource),
offers: OfferStore,
offer_adapters: std.AutoHashMapUnmanaged(OfferId, *OfferResource),
selection: ?Selection,
selection_order: SeatAuthority.Order,
selection_generation: u64,
selection_listeners: std.ArrayList(SelectionListener),
drag_selection_listeners: std.ArrayList(SelectionListener),
focused_client: ?*wl.Client,
drag: ?DragState,
retained_external_drag: ?RetainedExternalDrag,
next_drag_generation: u64,
drag_icon: ?*DragIcon,

pub const Listener = struct {
    context: *anyopaque,
    started: *const fn (*anyopaque) void,
    ended: *const fn (*anyopaque) void,
    external_source_destroyed: *const fn (*anyopaque, u64) void,
    repaint: *const fn (*anyopaque) void,
};

pub const ToplevelDragHandler = struct {
    context: *anyopaque,
    started: *const fn (*anyopaque) void,
    ended: *const fn (*anyopaque) void,
    source_destroyed: *const fn (*anyopaque) void,
};

pub const SelectionListener = struct {
    context: *anyopaque,
    changed: *const fn (*anyopaque) void,
    offered: *const fn (*anyopaque, [*:0]const u8) void,
};

pub const IconInfo = struct {
    surface_id: Surface.Id,
    x: i32,
    y: i32,
};

const SourceStore = slot_map.SlotMap(SourceState, enum { data_source });
const SourceId = SourceStore.Id;
const Selection = union(enum) {
    local: SourceId,
    external: *const SelectionSource,
};
const SourceState = struct {
    resource: *wl.DataSource,
    mime_types: std.ArrayList([:0]u8) = .empty,
    used: bool = false,
    actions_set: bool = false,
    dnd_actions: wl.DataDeviceManager.DndAction = .{},
    toplevel_drag_handler: ?ToplevelDragHandler = null,

    fn deinit(self: *SourceState, allocator: std.mem.Allocator) void {
        for (self.mime_types.items) |mime_type| allocator.free(mime_type);
        self.mime_types.deinit(allocator);
        self.* = undefined;
    }
};

const DeviceStore = slot_map.SlotMap(DeviceState, enum { data_device });
const DeviceId = DeviceStore.Id;
const DeviceState = struct {
    resource: *wl.DataDevice,
};

const OfferStore = slot_map.SlotMap(OfferState, enum { data_offer });
const OfferId = OfferStore.Id;
const OfferState = struct {
    resource: *wl.DataOffer,
    device: DeviceId,
    source: ?SourceId,
    external_source: ?*const SelectionSource = null,
    external_drag_source: ?*const ExternalDragSource = null,
    kind: Kind,
    drag_generation: u64 = 0,
    enter_serial: u32 = 0,
    active: bool = false,
    accepted: bool = false,
    destination_actions: wl.DataDeviceManager.DndAction = .{},
    preferred_action: wl.DataDeviceManager.DndAction = .{},
    selected_action: wl.DataDeviceManager.DndAction = .{},
    dropped: bool = false,
    finished: bool = false,

    const Kind = enum {
        selection,
        drag,
    };
};

const DragState = struct {
    generation: u64,
    source: ?DragSource,
    source_client: ?*wl.Client,
    origin: ?Surface.Id,
    external_pointer_delivery: ?ExternalPointerDelivery = null,
    target: ?Target = null,

    const Target = struct {
        surface_id: Surface.Id,
        client: *wl.Client,
        enter_serial: u32,
        x: f64,
        y: f64,
    };

    const ExternalPointerDelivery = struct {
        surface_id: Surface.Id,
        start_global_x: f64,
        start_global_y: f64,
        start_surface_x: f64,
        start_surface_y: f64,
    };
};

const DragSource = union(enum) {
    local: SourceId,
    external: *const ExternalDragSource,
};

/// Caller-owned callbacks borrowed by `startExternalDrag` for the drag lifetime.
pub const ExternalDragSource = struct {
    context: *anyopaque,
    mime_types: *const fn (*anyopaque) []const [:0]const u8,
    actions: *const fn (*anyopaque) wl.DataDeviceManager.DndAction,
    send: *const fn (*anyopaque, [*:0]const u8, std.posix.fd_t) void,
    target: *const fn (*anyopaque, ?[*:0]const u8) void,
    action: *const fn (*anyopaque, wl.DataDeviceManager.DndAction) void,
    drop_performed: *const fn (*anyopaque) void,
    finished: *const fn (*anyopaque) void,
    cancel: *const fn (*anyopaque) void,

    fn hasMime(self: *const ExternalDragSource, mime_type: [*:0]const u8) bool {
        const requested = std.mem.span(mime_type);
        for (self.mime_types(self.context)) |offered| {
            if (std.mem.eql(u8, offered, requested)) return true;
        }
        return false;
    }
};

const RetainedExternalDrag = struct {
    generation: u64,
    source: SourceId,
};

pub const DragSourceInfo = struct {
    generation: u64,
    /// Borrowed from the current source and invalidated by source mutation.
    mime_types: []const [:0]const u8,
    actions: wl.DataDeviceManager.DndAction,
};

const DragIcon = struct {
    manager: *Self,
    surface: *Surface,
    surface_id: Surface.Id,
    offset_x: i32 = 0,
    offset_y: i32 = 0,

    fn create(manager: *Self, surface: *Surface) error{ OutOfMemory, InvalidRole }!*DragIcon {
        const self = manager.allocator.create(DragIcon) catch return error.OutOfMemory;
        errdefer manager.allocator.destroy(self);
        self.* = .{
            .manager = manager,
            .surface = surface,
            .surface_id = surface.handle(),
        };
        surface.reserveRole(.drag_icon, .{
            .context = self,
            .before_commit = beforeCommit,
            .after_commit = afterCommit,
            .surface_destroyed = surfaceDestroyed,
        }) catch return error.InvalidRole;
        errdefer surface.releaseRole(self);
        surface.assignReservedRole(.drag_icon, self) catch unreachable;
        return self;
    }

    fn destroy(self: *DragIcon) void {
        self.surface.releaseRole(self);
        self.manager.allocator.destroy(self);
    }

    fn beforeCommit(_: *anyopaque, _: Surface.CommitInfo) Surface.CommitAction {
        return .apply;
    }

    fn afterCommit(context: *anyopaque, info: Surface.CommitInfo) void {
        const self: *DragIcon = @ptrCast(@alignCast(context));
        self.offset_x +|= info.offset_x;
        self.offset_y +|= info.offset_y;
        self.manager.listener.repaint(self.manager.listener.context);
    }

    fn surfaceDestroyed(context: *anyopaque) void {
        const self: *DragIcon = @ptrCast(@alignCast(context));
        const manager = self.manager;
        std.debug.assert(manager.drag_icon == self);
        manager.drag_icon = null;
        manager.allocator.destroy(self);
        manager.listener.repaint(manager.listener.context);
    }
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    seat: *Seat,
    surface_store: *Surface.Store,
    listener: Listener,
) !void {
    self.* = .{
        .allocator = allocator,
        .global = undefined,
        .display = display,
        .seat = seat,
        .surface_store = surface_store,
        .listener = listener,
        .sources = .{},
        .source_adapters = .empty,
        .devices = .{},
        .device_adapters = .empty,
        .offers = .{},
        .offer_adapters = .empty,
        .selection = null,
        .selection_order = 0,
        .selection_generation = 0,
        .selection_listeners = .empty,
        .drag_selection_listeners = .empty,
        .focused_client = null,
        .drag = null,
        .retained_external_drag = null,
        .next_drag_generation = 0,
        .drag_icon = null,
    };
    errdefer self.sources.deinit(allocator);
    errdefer self.source_adapters.deinit(allocator);
    errdefer self.devices.deinit(allocator);
    errdefer self.device_adapters.deinit(allocator);
    errdefer self.offers.deinit(allocator);
    errdefer self.offer_adapters.deinit(allocator);
    errdefer self.selection_listeners.deinit(allocator);
    errdefer self.drag_selection_listeners.deinit(allocator);
    self.global = try wl.Global.create(display, wl.DataDeviceManager, 4, *Self, self, bind);
    errdefer self.global.destroy();
    try seat.addKeyboardFocusListener(.{
        .context = self,
        .changed = keyboardFocusChanged,
    });
}

pub fn deinit(self: *Self) void {
    self.cancelDrag(false);
    std.debug.assert(self.selection_listeners.items.len == 0);
    std.debug.assert(self.drag_selection_listeners.items.len == 0);
    self.seat.removeKeyboardFocusListener(self);
    self.global.destroy();
    std.debug.assert(self.sources.len() == 0);
    std.debug.assert(self.source_adapters.count() == 0);
    std.debug.assert(self.devices.len() == 0);
    std.debug.assert(self.device_adapters.count() == 0);
    std.debug.assert(self.offers.len() == 0);
    std.debug.assert(self.offer_adapters.count() == 0);
    self.offer_adapters.deinit(self.allocator);
    self.offers.deinit(self.allocator);
    self.source_adapters.deinit(self.allocator);
    self.sources.deinit(self.allocator);
    self.device_adapters.deinit(self.allocator);
    self.devices.deinit(self.allocator);
    self.selection_listeners.deinit(self.allocator);
    self.drag_selection_listeners.deinit(self.allocator);
    self.* = undefined;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = wl.DataDeviceManager.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleRequest, null, self);
}

fn handleRequest(
    resource: *wl.DataDeviceManager,
    request: wl.DataDeviceManager.Request,
    self: *Self,
) void {
    switch (request) {
        .release => resource.destroy(),
        .create_data_source => |create| SourceResource.create(
            self,
            resource.getClient(),
            resource.getVersion(),
            create.id,
        ) catch resource.postNoMemory(),
        .get_data_device => |get| {
            if (!self.seat.ownsResource(get.seat)) {
                createInertDevice(
                    resource.getClient(),
                    resource.getVersion(),
                    get.id,
                ) catch resource.postNoMemory();
                return;
            }
            DeviceResource.create(
                self,
                resource.getClient(),
                resource.getVersion(),
                get.id,
            ) catch resource.postNoMemory();
        },
    }
}

fn createInertDevice(client: *wl.Client, version: u32, id: u32) !void {
    const resource = try wl.DataDevice.create(client, version, id);
    resource.setHandler(?*anyopaque, inertDeviceRequest, null, null);
}

fn inertDeviceRequest(
    resource: *wl.DataDevice,
    request: wl.DataDevice.Request,
    _: ?*anyopaque,
) void {
    switch (request) {
        .release => resource.destroy(),
        .start_drag, .set_selection => {},
    }
}

const SourceResource = struct {
    allocator: std.mem.Allocator,
    manager: *Self,
    id: SourceId,

    fn create(
        manager: *Self,
        client: *wl.Client,
        version: u32,
        protocol_id: u32,
    ) error{ OutOfMemory, ResourceCreateFailed }!void {
        const resource = try wl.DataSource.create(client, version, protocol_id);
        errdefer resource.destroy();
        const self = manager.allocator.create(SourceResource) catch return error.OutOfMemory;
        errdefer manager.allocator.destroy(self);
        const id = manager.sources.insert(manager.allocator, .{
            .resource = resource,
        }) catch return error.OutOfMemory;
        errdefer _ = manager.sources.remove(id);

        self.* = .{
            .allocator = manager.allocator,
            .manager = manager,
            .id = id,
        };
        manager.source_adapters.put(manager.allocator, id, self) catch
            return error.OutOfMemory;
        resource.setHandler(
            *SourceResource,
            SourceResource.handleRequest,
            SourceResource.handleDestroy,
            self,
        );
    }

    fn handleRequest(
        resource: *wl.DataSource,
        request: wl.DataSource.Request,
        self: *SourceResource,
    ) void {
        switch (request) {
            .offer => |request_offer| self.offer(resource, request_offer.mime_type),
            .destroy => resource.destroy(),
            .set_actions => |set| {
                const state = self.manager.sources.get(self.id) orelse return;
                const action_bits: u32 = @bitCast(set.dnd_actions);
                if (action_bits & ~@as(u32, 7) != 0) {
                    resource.postError(.invalid_action_mask, "invalid drag-and-drop action mask");
                    return;
                }
                if (state.actions_set) {
                    resource.postError(.invalid_source, "drag-and-drop actions were already set");
                    return;
                }
                if (state.used) {
                    resource.postError(.invalid_source, "data source is already in use");
                    return;
                }
                state.actions_set = true;
                state.dnd_actions = set.dnd_actions;
            },
        }
    }

    fn offer(self: *SourceResource, resource: *wl.DataSource, mime_type: [*:0]const u8) void {
        const state = self.manager.sources.get(self.id) orelse return;
        const value = std.mem.span(mime_type);
        for (state.mime_types.items) |existing| {
            if (std.mem.eql(u8, existing, value)) return;
        }
        const copy = self.allocator.dupeZ(u8, value) catch {
            resource.postNoMemory();
            return;
        };
        state.mime_types.append(self.allocator, copy) catch {
            self.allocator.free(copy);
            resource.postNoMemory();
            return;
        };
        var offers = self.manager.offers.iterator();
        while (offers.next()) |entry| {
            if (entry.value.source) |source_id| {
                if (std.meta.eql(source_id, self.id)) entry.value.resource.sendOffer(copy.ptr);
            }
        }
        if (self.manager.selection) |selection| switch (selection) {
            .local => |source_id| if (std.meta.eql(source_id, self.id)) {
                for (self.manager.selection_listeners.items) |listener| {
                    listener.offered(listener.context, copy.ptr);
                }
            },
            .external => {},
        };
    }

    fn handleDestroy(_: *wl.DataSource, self: *SourceResource) void {
        self.manager.sourceDestroyed(self.id);
        _ = self.manager.source_adapters.remove(self.id);
        var state = self.manager.sources.remove(self.id) orelse {
            self.allocator.destroy(self);
            return;
        };
        state.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

const DeviceResource = struct {
    allocator: std.mem.Allocator,
    manager: *Self,
    id: DeviceId,

    fn create(
        manager: *Self,
        client: *wl.Client,
        version: u32,
        protocol_id: u32,
    ) error{ OutOfMemory, ResourceCreateFailed }!void {
        const resource = try wl.DataDevice.create(client, version, protocol_id);
        errdefer resource.destroy();
        const self = manager.allocator.create(DeviceResource) catch return error.OutOfMemory;
        errdefer manager.allocator.destroy(self);
        const id = manager.devices.insert(manager.allocator, .{
            .resource = resource,
        }) catch return error.OutOfMemory;
        errdefer _ = manager.devices.remove(id);

        self.* = .{
            .allocator = manager.allocator,
            .manager = manager,
            .id = id,
        };
        manager.device_adapters.put(manager.allocator, id, self) catch
            return error.OutOfMemory;
        resource.setHandler(
            *DeviceResource,
            DeviceResource.handleRequest,
            DeviceResource.handleDestroy,
            self,
        );
        if (manager.focused_client == client) {
            manager.sendSelectionToDevice(id) catch resource.postNoMemory();
        }
        _ = manager.sendCurrentDragToDevice(id) catch {
            resource.postNoMemory();
            return;
        };
    }

    fn handleRequest(
        resource: *wl.DataDevice,
        request: wl.DataDevice.Request,
        self: *DeviceResource,
    ) void {
        switch (request) {
            .release => resource.destroy(),
            .start_drag => |start| self.manager.startDrag(
                self.id,
                resource,
                start.source,
                start.origin,
                start.icon,
                start.serial,
            ),
            .set_selection => |set| self.setSelection(resource, set.source, set.serial),
        }
    }

    fn setSelection(
        self: *DeviceResource,
        resource: *wl.DataDevice,
        source_resource: ?*wl.DataSource,
        serial: u32,
    ) void {
        const order = self.manager.seat.selectionOrder(
            resource.getClient(),
            serial,
        ) orelse return;
        const source_id = if (source_resource) |source| source: {
            const data = source.getUserData() orelse return;
            const adapter: *SourceResource = @ptrCast(@alignCast(data));
            if (adapter.manager != self.manager or source.getClient() != resource.getClient()) return;
            const state = self.manager.sources.get(adapter.id) orelse return;
            if (state.toplevel_drag_handler != null) {
                source.postError(.invalid_source, "toplevel drag source used for selection");
                return;
            }
            if (state.actions_set) {
                source.postError(.invalid_source, "drag-and-drop source used for selection");
                return;
            }
            if (state.used) {
                resource.postError(.used_source, "data source was already used");
                return;
            }
            state.used = true;
            break :source adapter.id;
        } else null;

        self.manager.setSelection(source_id, order);
    }

    fn handleDestroy(_: *wl.DataDevice, self: *DeviceResource) void {
        self.manager.deviceDestroyed(self.id);
        _ = self.manager.device_adapters.remove(self.id);
        _ = self.manager.devices.remove(self.id);
        self.allocator.destroy(self);
    }
};

fn startDrag(
    self: *Self,
    device_id: DeviceId,
    device_resource: *wl.DataDevice,
    source_resource: ?*wl.DataSource,
    origin_resource: *wl.Surface,
    icon_resource: ?*wl.Surface,
    serial: u32,
) void {
    if (self.drag != null) return;
    const client = device_resource.getClient();
    const device = self.devices.get(device_id) orelse return;
    if (device.resource != device_resource or origin_resource.getClient() != client) return;

    const origin = Surface.fromResource(origin_resource);
    if (!self.seat.acceptsPointerGrabSerial(client, origin.handle(), serial)) return;

    const source_id: ?SourceId = if (source_resource) |resource| source: {
        if (resource.getClient() != client) return;
        const data = resource.getUserData() orelse return;
        const adapter: *SourceResource = @ptrCast(@alignCast(data));
        if (adapter.manager != self) return;
        const source = self.sources.get(adapter.id) orelse return;
        if (resource.getVersion() >= 3 and !source.actions_set) {
            resource.postError(.invalid_source, "drag-and-drop actions were not set");
            return;
        }
        if (source.used) {
            device_resource.postError(.used_source, "data source was already used");
            return;
        }
        break :source adapter.id;
    } else null;

    const icon = if (icon_resource) |resource| icon: {
        if (resource.getClient() != client) return;
        break :icon DragIcon.create(self, Surface.fromResource(resource)) catch |err| {
            switch (err) {
                error.OutOfMemory => device_resource.postNoMemory(),
                error.InvalidRole => device_resource.postError(
                    .role,
                    "drag icon surface already has another role",
                ),
            }
            return;
        };
    } else null;

    self.cancelRetainedExternalDrag();
    self.next_drag_generation = std.math.add(u64, self.next_drag_generation, 1) catch 1;
    if (source_id) |id| self.sources.get(id).?.used = true;
    self.drag_icon = icon;
    self.drag = .{
        .generation = self.next_drag_generation,
        .source = if (source_id) |id| .{ .local = id } else null,
        .source_client = client,
        .origin = origin.handle(),
    };
    if (source_id) |id| if (self.sources.get(id).?.toplevel_drag_handler) |handler| {
        handler.started(handler.context);
    };
    self.seat.setDragCursorController(client);
    self.notifyDragSelectionChanged();
    self.listener.started(self.listener.context);
    self.listener.repaint(self.listener.context);
}

pub fn isDragging(self: *const Self) bool {
    return self.drag != null;
}

pub fn setToplevelDragHandler(
    self: *Self,
    source_resource: *wl.DataSource,
    handler: ToplevelDragHandler,
) error{InvalidSource}!void {
    const data = source_resource.getUserData() orelse return error.InvalidSource;
    const adapter: *SourceResource = @ptrCast(@alignCast(data));
    if (adapter.manager != self) return error.InvalidSource;
    const source = self.sources.get(adapter.id) orelse return error.InvalidSource;
    if (source.used or source.toplevel_drag_handler != null) return error.InvalidSource;
    source.toplevel_drag_handler = handler;
}

pub fn clearToplevelDragHandler(
    self: *Self,
    source_resource: *wl.DataSource,
    context: *anyopaque,
) void {
    const data = source_resource.getUserData() orelse unreachable;
    const adapter: *SourceResource = @ptrCast(@alignCast(data));
    std.debug.assert(adapter.manager == self);
    const source = self.sources.get(adapter.id) orelse unreachable;
    const handler = source.toplevel_drag_handler orelse unreachable;
    std.debug.assert(handler.context == context);
    source.toplevel_drag_handler = null;
}

pub fn pointerEntered(self: *Self, focus: ?Seat.PointerFocus) void {
    self.updateDragTarget(focus);
}

pub fn pointerMotion(self: *Self, time: u32, focus: ?Seat.PointerFocus) void {
    self.updateDragTarget(focus);
    const drag = self.drag orelse return;
    const target = drag.target orelse return;
    const position = focus orelse return;
    if (!std.meta.eql(position.surface_id, target.surface_id)) return;

    var iterator = self.devices.iterator();
    while (iterator.next()) |entry| {
        if (entry.value.resource.getClient() == target.client) {
            entry.value.resource.sendMotion(time, fixed(position.x), fixed(position.y));
        }
    }
    self.listener.repaint(self.listener.context);
}

pub fn pointerLeft(self: *Self) void {
    self.updateDragTarget(null);
}

pub fn drop(self: *Self) void {
    const drag = self.drag orelse return;
    const target = drag.target orelse {
        self.cancelDrag(true);
        return;
    };
    const drag_source = drag.source orelse {
        self.sendDrop(target.client);
        self.sendLeave(target.client);
        self.finishPhysicalDrag();
        return;
    };
    if (!self.dragSourceAvailable(drag_source)) {
        self.finishPhysicalDrag();
        return;
    }

    self.dragSourceDropPerformed(drag_source);
    const accepted = self.generationAcceptsDrop(drag.generation);
    var needs_finish = false;
    var iterator = self.offers.iterator();
    while (iterator.next()) |entry| {
        const offer = entry.value;
        if (offer.kind != .drag or offer.drag_generation != drag.generation or !offer.active) continue;
        offer.active = false;
        offer.dropped = accepted;
        if (accepted and offer.accepted and (offer.resource.getVersion() < 3 or
            actionBits(offer.selected_action) != 0)) needs_finish = true;
    }

    if (!accepted) {
        self.sendLeave(target.client);
        self.cancelDndSource(drag_source);
        self.invalidateDragGeneration(drag.generation);
    } else {
        self.sendDrop(target.client);
        self.sendLeave(target.client);
        if (!needs_finish) {
            self.finishDndSource(drag_source);
            self.invalidateDragGeneration(drag.generation);
        }
    }
    self.finishPhysicalDrag();
}

pub fn cancel(self: *Self) void {
    self.cancelDrag(true);
}

/// Borrows `source` until this drag ends. The owner must call
/// `externalDragSourceDestroyed` before destroying a source still in use.
pub fn startExternalDrag(self: *Self, source: *const ExternalDragSource) ?u64 {
    if (self.drag != null or !self.seat.hasPressedPointerButton(0x110)) return null;
    const pointer_focus = self.seat.pointerFocus() orelse return null;
    const pointer_position = self.seat.pointerPosition() orelse return null;
    self.cancelRetainedExternalDrag();
    self.next_drag_generation = std.math.add(u64, self.next_drag_generation, 1) catch 1;
    self.drag = .{
        .generation = self.next_drag_generation,
        .source = .{ .external = source },
        .source_client = null,
        .origin = null,
        .external_pointer_delivery = .{
            .surface_id = pointer_focus.surface_id,
            .start_global_x = pointer_position.x,
            .start_global_y = pointer_position.y,
            .start_surface_x = pointer_focus.x,
            .start_surface_y = pointer_focus.y,
        },
    };
    self.notifyDragSelectionChanged();
    self.listener.started(self.listener.context);
    self.listener.repaint(self.listener.context);
    return self.next_drag_generation;
}

pub fn dragIsExternal(self: *const Self) bool {
    const drag = self.drag orelse return false;
    const source = drag.source orelse return false;
    return source == .external;
}

pub fn externalDragPointerFocus(self: *const Self, x: f64, y: f64) ?Seat.PointerFocus {
    const drag = self.drag orelse return null;
    if (drag.source == null or drag.source.? != .external) return null;
    const delivery = drag.external_pointer_delivery orelse return null;
    return .{
        .surface_id = delivery.surface_id,
        .x = delivery.start_surface_x + x - delivery.start_global_x,
        .y = delivery.start_surface_y + y - delivery.start_global_y,
    };
}

pub fn externalDragMimeOffered(self: *Self, source: *const ExternalDragSource, mime_type: [*:0]const u8) void {
    const drag = self.drag orelse return;
    if (!dragSourceIsExternal(drag.source, source)) return;
    var offers = self.offers.iterator();
    while (offers.next()) |entry| {
        const offer = entry.value;
        if (offer.kind == .drag and offer.drag_generation == drag.generation and
            offer.active and offer.external_drag_source == source)
        {
            offer.resource.sendOffer(mime_type);
        }
    }
}

pub fn externalDragActionsChanged(self: *Self, source: *const ExternalDragSource) void {
    const drag = self.drag orelse return;
    if (!dragSourceIsExternal(drag.source, source)) return;
    const source_actions = source.actions(source.context);
    var offers = self.offers.iterator();
    while (offers.next()) |entry| {
        const offer = entry.value;
        if (offer.kind != .drag or offer.drag_generation != drag.generation or
            !offer.active or offer.external_drag_source != source) continue;
        if (offer.resource.getVersion() >= 3) offer.resource.sendSourceActions(source_actions);
        const selected = selectedAction(
            source_actions,
            destinationActions(offer),
            offer.preferred_action,
        );
        if (actionBits(selected) == actionBits(offer.selected_action)) continue;
        offer.selected_action = selected;
        if (offer.resource.getVersion() >= 3) offer.resource.sendAction(selected);
        source.action(source.context, selected);
    }
}

pub fn externalDragSourceDestroyed(self: *Self, source: *const ExternalDragSource) void {
    if (self.drag) |drag| {
        if (dragSourceIsExternal(drag.source, source)) self.cancelDrag(false);
    }
    var offers = self.offers.iterator();
    while (offers.next()) |entry| {
        const offer = entry.value;
        if (offer.external_drag_source != source) continue;
        offer.external_drag_source = null;
        offer.active = false;
        offer.dropped = false;
    }
}

/// Returns a snapshot containing a MIME slice borrowed from the current source.
pub fn dragSourceInfo(self: *Self) ?DragSourceInfo {
    const generation, const source = self.currentDragSource() orelse return null;
    return .{
        .generation = generation,
        .mime_types = @ptrCast(source.mime_types.items),
        .actions = sourceActions(source),
    };
}

pub fn sendDragSelection(self: *Self, mime_type: [*:0]const u8, fd: std.posix.fd_t) void {
    const current = self.currentDragSource() orelse return;
    const source = current[1];
    if (!sourceHasMime(source, mime_type)) return;
    source.resource.sendTarget(mime_type);
    source.resource.sendSend(mime_type, fd);
}

pub fn externalDragStatus(
    self: *Self,
    generation: u64,
    accepted: bool,
    selected: wl.DataDeviceManager.DndAction,
) void {
    const drag = self.drag orelse return;
    if (drag.generation != generation) return;
    const source_id = switch (drag.source orelse return) {
        .local => |id| id,
        .external => return,
    };
    const source = self.sources.get(source_id) orelse return;
    if (!accepted) source.resource.sendTarget(null);
    if (source.resource.getVersion() >= 3) source.resource.sendAction(if (accepted) selected else .{});
}

pub fn dropOnExternalTarget(
    self: *Self,
    generation: u64,
    accepted: bool,
) bool {
    const drag = self.drag orelse return false;
    if (drag.generation != generation) return false;
    const source_id = switch (drag.source orelse {
        self.finishPhysicalDrag();
        return false;
    }) {
        .local => |id| id,
        .external => return false,
    };
    const source = self.sources.get(source_id) orelse {
        self.finishPhysicalDrag();
        return false;
    };
    if (accepted) {
        if (source.resource.getVersion() >= 3) source.resource.sendDndDropPerformed();
        self.retained_external_drag = .{
            .generation = generation,
            .source = source_id,
        };
    } else {
        self.cancelDndSource(.{ .local = source_id });
    }
    self.invalidateDragGeneration(generation);
    self.finishPhysicalDrag();
    return accepted;
}

pub fn finishExternalDrag(self: *Self, generation: u64, performed: bool) void {
    const retained = self.retained_external_drag orelse return;
    if (retained.generation != generation) return;
    if (self.sources.get(retained.source)) |source| {
        if (source.resource.getVersion() >= 3) {
            if (performed) {
                source.resource.sendDndFinished();
            } else {
                source.resource.sendCancelled();
            }
        }
    }
    self.retained_external_drag = null;
    self.notifyDragSelectionChanged();
}

/// Copies the listener and retains its context until removeDragSelectionListener.
pub fn addDragSelectionListener(self: *Self, listener: SelectionListener) error{OutOfMemory}!void {
    for (self.drag_selection_listeners.items) |existing| {
        std.debug.assert(existing.context != listener.context);
    }
    try self.drag_selection_listeners.append(self.allocator, listener);
}

pub fn removeDragSelectionListener(self: *Self, context: *anyopaque) void {
    for (self.drag_selection_listeners.items, 0..) |listener, index| {
        if (listener.context != context) continue;
        _ = self.drag_selection_listeners.orderedRemove(index);
        return;
    }
    unreachable;
}

pub fn iconInfo(self: *const Self) ?IconInfo {
    const icon = self.drag_icon orelse return null;
    const position = self.seat.pointerPosition() orelse return null;
    return .{
        .surface_id = icon.surface_id,
        .x = dragIconCoordinate(position.x, icon.offset_x),
        .y = dragIconCoordinate(position.y, icon.offset_y),
    };
}

fn updateDragTarget(self: *Self, focus: ?Seat.PointerFocus) void {
    const drag = self.drag orelse return;
    if (drag.origin) |origin| if (Surface.resourceFor(self.surface_store, origin) == null) {
        self.cancelDrag(true);
        return;
    };

    if (drag.target) |target| {
        const unchanged = if (focus) |next|
            std.meta.eql(target.surface_id, next.surface_id)
        else
            false;
        if (unchanged) {
            self.drag.?.target.?.x = focus.?.x;
            self.drag.?.target.?.y = focus.?.y;
            return;
        }
        self.leaveDragTarget(true);
    }
    const next = focus orelse return;
    const surface = Surface.resourceFor(self.surface_store, next.surface_id) orelse return;
    const client = surface.getClient();
    if (drag.source == null and client != drag.source_client.?) return;

    const serial = MatureSerials.issueWire(self.display);
    self.drag.?.target = .{
        .surface_id = next.surface_id,
        .client = client,
        .enter_serial = serial,
        .x = next.x,
        .y = next.y,
    };
    var sent = false;
    var iterator = self.devices.iterator();
    while (iterator.next()) |entry| {
        if (entry.value.resource.getClient() != client) continue;
        sent = self.sendCurrentDragToDevice(entry.id) catch {
            entry.value.resource.postNoMemory();
            continue;
        } or sent;
    }
    if (!sent) {
        self.drag.?.target = null;
        return;
    }
    if (drag.source) |source| self.notifySourceTarget(
        source,
        null,
        self.currentDragAction(drag.generation),
    );
}

fn sendCurrentDragToDevice(
    self: *Self,
    device_id: DeviceId,
) error{ OutOfMemory, ResourceCreateFailed }!bool {
    const drag = self.drag orelse return false;
    const target = drag.target orelse return false;
    const device = self.devices.get(device_id) orelse return false;
    if (device.resource.getClient() != target.client) return false;
    const surface = Surface.resourceFor(self.surface_store, target.surface_id) orelse return false;

    const offer_resource: ?*wl.DataOffer = if (drag.source) |drag_source| offer: {
        if (!self.dragSourceAvailable(drag_source)) return false;
        const source_id: ?SourceId, const external_source: ?*const ExternalDragSource = switch (drag_source) {
            .local => |id| .{ id, null },
            .external => |source| .{ null, source },
        };
        const resource = try OfferResource.create(
            self,
            target.client,
            device.resource.getVersion(),
            device_id,
            source_id,
            null,
            external_source,
            .drag,
            drag.generation,
            target.enter_serial,
        );
        const adapter: *OfferResource = @ptrCast(@alignCast(resource.getUserData().?));
        const state = self.offers.get(adapter.id).?;
        state.active = true;
        state.selected_action = selectedAction(
            self.dragSourceActions(drag_source),
            destinationActions(state),
            state.preferred_action,
        );
        device.resource.sendDataOffer(resource);
        for (self.dragSourceMimeTypes(drag_source)) |mime_type| resource.sendOffer(mime_type.ptr);
        if (resource.getVersion() >= 3) {
            resource.sendSourceActions(self.dragSourceActions(drag_source));
            resource.sendAction(state.selected_action);
        }
        break :offer resource;
    } else null;
    device.resource.sendEnter(
        target.enter_serial,
        surface,
        fixed(target.x),
        fixed(target.y),
        offer_resource,
    );
    return true;
}

fn leaveDragTarget(self: *Self, notify_source: bool) void {
    const drag = self.drag orelse return;
    const target = drag.target orelse return;
    var devices = self.devices.iterator();
    while (devices.next()) |entry| {
        if (entry.value.resource.getClient() == target.client) entry.value.resource.sendLeave();
    }
    var offers = self.offers.iterator();
    while (offers.next()) |entry| {
        const offer = entry.value;
        if (offer.kind != .drag or offer.drag_generation != drag.generation or !offer.active) continue;
        offer.active = false;
        offer.source = null;
        offer.external_drag_source = null;
    }
    if (notify_source) if (drag.source) |source| self.notifySourceTarget(source, null, .{});
    self.drag.?.target = null;
}

fn sendDrop(self: *Self, client: *wl.Client) void {
    var iterator = self.devices.iterator();
    while (iterator.next()) |entry| {
        if (entry.value.resource.getClient() == client) entry.value.resource.sendDrop();
    }
}

fn sendLeave(self: *Self, client: *wl.Client) void {
    var iterator = self.devices.iterator();
    while (iterator.next()) |entry| {
        if (entry.value.resource.getClient() == client) entry.value.resource.sendLeave();
    }
}

fn finishPhysicalDrag(self: *Self) void {
    const drag = self.drag orelse unreachable;
    if (drag.source) |source| switch (source) {
        .local => |id| if (self.sources.get(id)) |local| {
            if (local.toplevel_drag_handler) |handler| handler.ended(handler.context);
        },
        .external => {},
    };
    self.drag = null;
    self.notifyDragSelectionChanged();
    self.clearDragIcon();
    self.seat.setDragCursorController(null);
    self.listener.ended(self.listener.context);
    self.listener.repaint(self.listener.context);
}

fn cancelDrag(self: *Self, notify_source: bool) void {
    const drag = self.drag orelse return;
    if (drag.target != null) self.leaveDragTarget(notify_source);
    if (notify_source) if (drag.source) |source| self.cancelDndSource(source);
    self.invalidateDragGeneration(drag.generation);
    self.finishPhysicalDrag();
}

fn clearDragIcon(self: *Self) void {
    const icon = self.drag_icon orelse return;
    self.drag_icon = null;
    icon.destroy();
}

const OfferResource = struct {
    allocator: std.mem.Allocator,
    manager: *Self,
    id: OfferId,

    fn create(
        manager: *Self,
        client: *wl.Client,
        version: u32,
        device_id: DeviceId,
        source_id: ?SourceId,
        external_source: ?*const SelectionSource,
        external_drag_source: ?*const ExternalDragSource,
        kind: OfferState.Kind,
        drag_generation: u64,
        enter_serial: u32,
    ) error{ OutOfMemory, ResourceCreateFailed }!*wl.DataOffer {
        const resource = try wl.DataOffer.create(client, version, 0);
        errdefer resource.destroy();
        const self = manager.allocator.create(OfferResource) catch return error.OutOfMemory;
        errdefer manager.allocator.destroy(self);
        const id = manager.offers.insert(manager.allocator, .{
            .resource = resource,
            .device = device_id,
            .source = source_id,
            .external_source = external_source,
            .external_drag_source = external_drag_source,
            .kind = kind,
            .drag_generation = drag_generation,
            .enter_serial = enter_serial,
        }) catch return error.OutOfMemory;
        errdefer _ = manager.offers.remove(id);

        self.* = .{
            .allocator = manager.allocator,
            .manager = manager,
            .id = id,
        };
        manager.offer_adapters.put(manager.allocator, id, self) catch
            return error.OutOfMemory;
        resource.setHandler(
            *OfferResource,
            OfferResource.handleRequest,
            OfferResource.handleDestroy,
            self,
        );
        return resource;
    }

    fn handleRequest(
        resource: *wl.DataOffer,
        request: wl.DataOffer.Request,
        self: *OfferResource,
    ) void {
        const state = self.manager.offers.get(self.id) orelse return;
        if (state.finished) {
            switch (request) {
                .destroy => resource.destroy(),
                else => resource.postError(.invalid_finish, "drag-and-drop offer was already finished"),
            }
            return;
        }
        switch (request) {
            .accept => |accept| self.manager.acceptOffer(self.id, accept.serial, accept.mime_type),
            .receive => |receive| {
                defer (std.Io.File{
                    .handle = receive.fd,
                    .flags = .{ .nonblocking = false },
                }).close(self.manager.seat.io);
                const offer = self.manager.offers.get(self.id) orelse return;
                if (offer.source) |source_id| {
                    const source = self.manager.sources.get(source_id) orelse return;
                    if (!sourceHasMime(source, receive.mime_type)) return;
                    source.resource.sendSend(receive.mime_type, receive.fd);
                } else if (offer.external_source) |source| {
                    if (!source.hasMime(receive.mime_type)) return;
                    source.send(source.context, receive.mime_type, receive.fd);
                } else if (offer.external_drag_source) |source| {
                    if (!source.hasMime(receive.mime_type)) return;
                    source.send(source.context, receive.mime_type, receive.fd);
                }
            },
            .destroy => resource.destroy(),
            .finish => self.manager.finishOffer(self.id),
            .set_actions => |set| self.manager.setOfferActions(
                self.id,
                set.dnd_actions,
                set.preferred_action,
            ),
        }
    }

    fn handleDestroy(_: *wl.DataOffer, self: *OfferResource) void {
        self.manager.offerDestroyed(self.id);
        _ = self.manager.offer_adapters.remove(self.id);
        _ = self.manager.offers.remove(self.id);
        self.allocator.destroy(self);
    }
};

fn acceptOffer(
    self: *Self,
    offer_id: OfferId,
    serial: u32,
    mime_type: ?[*:0]const u8,
) void {
    const offer = self.offers.get(offer_id) orelse return;
    if (offer.kind != .drag or (!offer.active and !offer.dropped)) return;
    if (offer.active and serial != offer.enter_serial) return;
    const source = offerDragSource(offer) orelse return;
    if (!self.dragSourceAvailable(source)) return;
    const accepted = if (mime_type) |value| self.dragSourceHasMime(source, value) else false;
    offer.accepted = accepted;
    self.notifySourceMime(source, if (accepted) mime_type else null);
}

fn setOfferActions(
    self: *Self,
    offer_id: OfferId,
    actions: wl.DataDeviceManager.DndAction,
    preferred: wl.DataDeviceManager.DndAction,
) void {
    const offer = self.offers.get(offer_id) orelse return;
    if (offer.kind != .drag) {
        offer.resource.postError(
            .invalid_offer,
            "drag-and-drop actions are invalid for a selection offer",
        );
        return;
    }
    const action_bits = actionBits(actions);
    if (action_bits & ~@as(u32, 7) != 0) {
        offer.resource.postError(.invalid_action_mask, "invalid drag-and-drop action mask");
        return;
    }
    const preferred_bits = actionBits(preferred);
    if ((preferred_bits != 0 and preferred_bits & (preferred_bits - 1) != 0) or
        preferred_bits & ~action_bits != 0)
    {
        offer.resource.postError(.invalid_action, "invalid preferred drag-and-drop action");
        return;
    }
    const source = offerDragSource(offer) orelse return;
    if (!self.dragSourceAvailable(source)) return;
    const source_actions = self.dragSourceActions(source);
    if (offer.dropped and actionBits(offer.selected_action) != actionBits(action(.ask))) return;
    if (offer.dropped and preferred_bits != 0 and
        preferred_bits & actionBits(source_actions) == 0)
    {
        offer.resource.postError(.invalid_action, "preferred action was not offered by the source");
        return;
    }

    offer.destination_actions = actions;
    offer.preferred_action = preferred;
    const selected = selectedAction(source_actions, actions, preferred);
    if (actionBits(selected) == actionBits(offer.selected_action)) return;
    offer.selected_action = selected;
    offer.resource.sendAction(selected);
    self.notifySourceAction(source, selected);
}

fn finishOffer(self: *Self, offer_id: OfferId) void {
    const offer = self.offers.get(offer_id) orelse return;
    if (offer.kind != .drag or !offer.dropped or !offer.accepted or
        actionBits(offer.selected_action) == 0 or
        actionBits(offer.selected_action) == actionBits(action(.ask)))
    {
        offer.resource.postError(.invalid_finish, "drag-and-drop offer cannot be finished");
        return;
    }
    const source = offerDragSource(offer) orelse {
        offer.resource.postError(.invalid_finish, "drag-and-drop source is no longer available");
        return;
    };
    if (!self.dragSourceAvailable(source)) {
        offer.resource.postError(.invalid_finish, "drag-and-drop source is no longer available");
        return;
    }
    offer.finished = true;
    self.finishDndSource(source);
    self.invalidateDragGeneration(offer.drag_generation);
}

fn offerDestroyed(self: *Self, offer_id: OfferId) void {
    const offer = self.offers.get(offer_id) orelse return;
    const source = offerDragSource(offer) orelse return;
    if (offer.kind != .drag or !offer.dropped or offer.finished or
        !self.dragSourceAvailable(source)) return;
    var iterator = self.offers.iterator();
    while (iterator.next()) |entry| {
        if (std.meta.eql(entry.id, offer_id)) continue;
        const candidate = entry.value;
        if (candidate.kind == .drag and candidate.drag_generation == offer.drag_generation and
            candidate.dropped and !candidate.finished and offerDragSource(candidate) != null) return;
    }
    if (offer.resource.getVersion() < 3) {
        self.finishDndSource(source);
    } else {
        self.cancelDndSource(source);
    }
    self.invalidateDragGeneration(offer.drag_generation);
}

fn generationAcceptsDrop(self: *Self, generation: u64) bool {
    var iterator = self.offers.iterator();
    while (iterator.next()) |entry| {
        const offer = entry.value;
        if (offer.kind != .drag or offer.drag_generation != generation or !offer.active) continue;
        if (offer.accepted and actionBits(offer.selected_action) != 0) return true;
    }
    return false;
}

fn currentDragAction(self: *Self, generation: u64) wl.DataDeviceManager.DndAction {
    var iterator = self.offers.iterator();
    while (iterator.next()) |entry| {
        const offer = entry.value;
        if (offer.kind == .drag and offer.drag_generation == generation and offer.active and
            actionBits(offer.selected_action) != 0) return offer.selected_action;
    }
    return .{};
}

fn invalidateDragGeneration(self: *Self, generation: u64) void {
    var iterator = self.offers.iterator();
    while (iterator.next()) |entry| {
        const offer = entry.value;
        if (offer.kind != .drag or offer.drag_generation != generation) continue;
        offer.source = null;
        offer.external_drag_source = null;
        offer.active = false;
        offer.dropped = false;
    }
}

fn cancelDndSource(self: *Self, source: DragSource) void {
    switch (source) {
        .local => |id| if (self.sources.get(id)) |local| {
            if (local.resource.getVersion() >= 3) local.resource.sendCancelled();
        },
        .external => |external| external.cancel(external.context),
    }
}

fn notifySourceTarget(
    self: *Self,
    source: DragSource,
    mime_type: ?[*:0]const u8,
    selected: wl.DataDeviceManager.DndAction,
) void {
    switch (source) {
        .local => |id| if (self.sources.get(id)) |local| {
            local.resource.sendTarget(mime_type);
            if (local.resource.getVersion() >= 3) local.resource.sendAction(selected);
        },
        .external => |external| {
            external.target(external.context, mime_type);
            external.action(external.context, selected);
        },
    }
}

fn notifySourceMime(self: *Self, source: DragSource, mime_type: ?[*:0]const u8) void {
    switch (source) {
        .local => |id| if (self.sources.get(id)) |local| local.resource.sendTarget(mime_type),
        .external => |external| external.target(external.context, mime_type),
    }
}

fn notifySourceAction(
    self: *Self,
    source: DragSource,
    selected: wl.DataDeviceManager.DndAction,
) void {
    switch (source) {
        .local => |id| if (self.sources.get(id)) |local| {
            if (local.resource.getVersion() >= 3) local.resource.sendAction(selected);
        },
        .external => |external| external.action(external.context, selected),
    }
}

fn finishDndSource(self: *Self, source: DragSource) void {
    switch (source) {
        .local => |id| if (self.sources.get(id)) |local| {
            if (local.resource.getVersion() >= 3) local.resource.sendDndFinished();
        },
        .external => |external| external.finished(external.context),
    }
}

fn dragSourceDropPerformed(self: *Self, source: DragSource) void {
    switch (source) {
        .local => |id| if (self.sources.get(id)) |local| {
            if (local.resource.getVersion() >= 3) local.resource.sendDndDropPerformed();
        },
        .external => |external| external.drop_performed(external.context),
    }
}

fn keyboardFocusChanged(context: *anyopaque, client: ?*wl.Client) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.focused_client == client) return;
    self.invalidateOffers();
    self.focused_client = client;
    if (client) |focused| self.sendSelectionToClient(focused);
}

fn setSelection(self: *Self, source_id: ?SourceId, order: SeatAuthority.Order) void {
    if (self.selection != null and order < self.selection_order) return;
    const selection: ?Selection = if (source_id) |id| .{ .local = id } else null;
    if (std.meta.eql(self.selection, selection)) {
        self.selection_order = order;
        return;
    }
    self.replaceSelection(selection, order, true);
}

fn replaceSelection(
    self: *Self,
    selection: ?Selection,
    order: SeatAuthority.Order,
    cancel_old: bool,
) void {
    const old_source = self.selection;
    std.debug.assert(!std.meta.eql(old_source, selection));
    self.selection = selection;
    self.selection_order = order;
    self.selection_generation +%= 1;
    self.invalidateOffers();
    if (self.focused_client) |client| self.sendSelectionToClient(client);
    for (self.selection_listeners.items) |listener| listener.changed(listener.context);
    if (cancel_old) if (old_source) |old| switch (old) {
        .local => |id| if (self.sources.get(id)) |source| source.resource.sendCancelled(),
        .external => |source| source.cancel(source.context),
    };
}

fn sourceDestroyed(self: *Self, id: SourceId) void {
    if (self.drag) |drag| {
        if (drag.source) |source| switch (source) {
            .local => |source_id| if (std.meta.eql(source_id, id)) self.cancelDrag(false),
            .external => {},
        };
    }
    var iterator = self.offers.iterator();
    while (iterator.next()) |entry| {
        if (entry.value.source) |source_id| {
            if (std.meta.eql(source_id, id)) entry.value.source = null;
        }
    }
    if (self.selection) |selection| {
        switch (selection) {
            .local => |selection_id| if (std.meta.eql(selection_id, id)) {
                self.replaceSelection(null, self.seat.nextSelectionOrder(), false);
            },
            .external => {},
        }
    }
    if (self.retained_external_drag) |retained| {
        if (std.meta.eql(retained.source, id)) {
            self.retained_external_drag = null;
            self.notifyDragSelectionChanged();
            self.listener.external_source_destroyed(
                self.listener.context,
                retained.generation,
            );
        }
    }
    if (self.sources.get(id)) |source| {
        if (source.toplevel_drag_handler) |handler| handler.source_destroyed(handler.context);
    }
}

fn currentDragSource(self: *Self) ?struct { u64, *SourceState } {
    if (self.drag) |drag| if (drag.source) |drag_source| {
        switch (drag_source) {
            .local => |source_id| {
                const source = self.sources.get(source_id) orelse return null;
                return .{ drag.generation, source };
            },
            .external => return null,
        }
    };
    if (self.retained_external_drag) |retained| {
        const source = self.sources.get(retained.source) orelse return null;
        return .{ retained.generation, source };
    }
    return null;
}

fn cancelRetainedExternalDrag(self: *Self) void {
    const retained = self.retained_external_drag orelse return;
    if (self.sources.get(retained.source)) |source| {
        if (source.resource.getVersion() >= 3) source.resource.sendCancelled();
    }
    self.retained_external_drag = null;
    self.notifyDragSelectionChanged();
}

fn notifyDragSelectionChanged(self: *Self) void {
    for (self.drag_selection_listeners.items) |listener| listener.changed(listener.context);
}

fn deviceDestroyed(self: *Self, id: DeviceId) void {
    _ = self;
    _ = id;
}

fn invalidateOffers(self: *Self) void {
    var iterator = self.offers.iterator();
    while (iterator.next()) |entry| {
        if (entry.value.kind == .selection) {
            entry.value.source = null;
            entry.value.external_source = null;
        }
    }
}

fn sendSelectionToClient(self: *Self, client: *wl.Client) void {
    var iterator = self.devices.iterator();
    while (iterator.next()) |entry| {
        if (entry.value.resource.getClient() != client) continue;
        self.sendSelectionToDevice(entry.id) catch entry.value.resource.postNoMemory();
    }
}

fn sendSelectionToDevice(
    self: *Self,
    device_id: DeviceId,
) error{ OutOfMemory, ResourceCreateFailed }!void {
    const device = self.devices.get(device_id) orelse return;
    const selection = self.selection orelse {
        device.resource.sendSelection(null);
        return;
    };
    const source_id: ?SourceId, const external_source: ?*const SelectionSource = switch (selection) {
        .local => |source_id| .{ source_id, null },
        .external => |source| .{ null, source },
    };
    const offer = try OfferResource.create(
        self,
        device.resource.getClient(),
        device.resource.getVersion(),
        device_id,
        source_id,
        external_source,
        null,
        .selection,
        0,
        0,
    );
    device.resource.sendDataOffer(offer);
    for (self.selectionMimeTypes()) |mime_type| offer.sendOffer(mime_type.ptr);
    device.resource.sendSelection(offer);
}

/// Copies the listener and retains its context until removeSelectionListener.
pub fn addSelectionListener(self: *Self, listener: SelectionListener) error{OutOfMemory}!void {
    for (self.selection_listeners.items) |existing| {
        std.debug.assert(existing.context != listener.context);
    }
    try self.selection_listeners.append(self.allocator, listener);
}

pub fn removeSelectionListener(self: *Self, context: *anyopaque) void {
    for (self.selection_listeners.items, 0..) |listener, index| {
        if (listener.context != context) continue;
        _ = self.selection_listeners.orderedRemove(index);
        return;
    }
    unreachable;
}

pub fn selectionGeneration(self: *const Self) u64 {
    return self.selection_generation;
}

pub fn hasSelection(self: *const Self) bool {
    return self.selection != null;
}

/// Returns a slice borrowed from the current source and invalidated by source mutation.
pub fn selectionMimeTypes(self: *Self) []const [:0]const u8 {
    const selection = self.selection orelse return &.{};
    return switch (selection) {
        .local => |id| if (self.sources.get(id)) |source|
            @ptrCast(source.mime_types.items)
        else
            &.{},
        .external => |source| source.mime_types(source.context),
    };
}

pub fn sendSelection(self: *Self, mime_type: [*:0]const u8, fd: std.posix.fd_t) void {
    const selection = self.selection orelse return;
    switch (selection) {
        .local => |id| {
            const source = self.sources.get(id) orelse return;
            if (sourceHasMime(source, mime_type)) source.resource.sendSend(mime_type, fd);
        },
        .external => |source| {
            if (source.hasMime(mime_type)) source.send(source.context, mime_type, fd);
        },
    }
}

/// Borrows `source` and its callback-returned MIME slices until replacement or
/// `externalSourceDestroyed`.
pub fn setExternalSelection(self: *Self, source: ?*const SelectionSource) void {
    const selection: ?Selection = if (source) |value| .{ .external = value } else null;
    if (std.meta.eql(self.selection, selection)) return;
    const order = self.seat.nextSelectionOrder();
    self.replaceSelection(selection, order, true);
}

pub fn externalSelectionIs(self: *const Self, source: *const SelectionSource) bool {
    const selection = self.selection orelse return false;
    return switch (selection) {
        .local => false,
        .external => |current| current == source,
    };
}

pub fn externalSourceDestroyed(self: *Self, source: *const SelectionSource) void {
    const selection = self.selection orelse return;
    switch (selection) {
        .local => {},
        .external => |current| if (current == source) {
            self.replaceSelection(null, self.seat.nextSelectionOrder(), false);
        },
    }
}

const DndActionKind = enum {
    copy,
    move,
    ask,
};

fn action(kind: DndActionKind) wl.DataDeviceManager.DndAction {
    var result: wl.DataDeviceManager.DndAction = .{};
    switch (kind) {
        .copy => result.copy = true,
        .move => result.move = true,
        .ask => result.ask = true,
    }
    return result;
}

fn actionBits(value: wl.DataDeviceManager.DndAction) u32 {
    return @bitCast(value);
}

fn sourceActions(source: *const SourceState) wl.DataDeviceManager.DndAction {
    return if (source.resource.getVersion() < 3) action(.copy) else source.dnd_actions;
}

fn dragSourceIsExternal(source: ?DragSource, external: *const ExternalDragSource) bool {
    const value = source orelse return false;
    return switch (value) {
        .local => false,
        .external => |current| current == external,
    };
}

fn offerDragSource(offer: *const OfferState) ?DragSource {
    if (offer.source) |source| return .{ .local = source };
    if (offer.external_drag_source) |source| return .{ .external = source };
    return null;
}

fn dragSourceAvailable(self: *Self, source: DragSource) bool {
    return switch (source) {
        .local => |id| self.sources.get(id) != null,
        .external => true,
    };
}

fn dragSourceMimeTypes(self: *Self, source: DragSource) []const [:0]const u8 {
    return switch (source) {
        .local => |id| if (self.sources.get(id)) |local|
            @ptrCast(local.mime_types.items)
        else
            &.{},
        .external => |external| external.mime_types(external.context),
    };
}

fn dragSourceActions(self: *Self, source: DragSource) wl.DataDeviceManager.DndAction {
    return switch (source) {
        .local => |id| if (self.sources.get(id)) |local| sourceActions(local) else .{},
        .external => |external| external.actions(external.context),
    };
}

fn dragSourceHasMime(self: *Self, source: DragSource, mime_type: [*:0]const u8) bool {
    return switch (source) {
        .local => |id| if (self.sources.get(id)) |local| sourceHasMime(local, mime_type) else false,
        .external => |external| external.hasMime(mime_type),
    };
}

fn destinationActions(offer: *const OfferState) wl.DataDeviceManager.DndAction {
    return if (offer.resource.getVersion() < 3) action(.copy) else offer.destination_actions;
}

fn selectedAction(
    source: wl.DataDeviceManager.DndAction,
    destination: wl.DataDeviceManager.DndAction,
    preferred: wl.DataDeviceManager.DndAction,
) wl.DataDeviceManager.DndAction {
    const available = actionBits(source) & actionBits(destination);
    const preferred_bits = actionBits(preferred);
    if (preferred_bits != 0 and available & preferred_bits != 0) return preferred;
    inline for (.{ DndActionKind.copy, DndActionKind.move, DndActionKind.ask }) |kind| {
        const candidate = action(kind);
        if (available & actionBits(candidate) != 0) return candidate;
    }
    return .{};
}

fn sourceHasMime(source: *const SourceState, mime_type: [*:0]const u8) bool {
    const requested = std.mem.span(mime_type);
    for (source.mime_types.items) |offered| {
        if (std.mem.eql(u8, offered, requested)) return true;
    }
    return false;
}

fn dragIconCoordinate(position: f64, offset: i32) i32 {
    const minimum = @as(f64, @floatFromInt(std.math.minInt(i32))) -
        @as(f64, @floatFromInt(offset));
    const maximum = @as(f64, @floatFromInt(std.math.maxInt(i32))) -
        @as(f64, @floatFromInt(offset));
    const integral: i64 = @intFromFloat(@floor(std.math.clamp(position, minimum, maximum)));
    return @intCast(std.math.clamp(
        integral + @as(i64, offset),
        std.math.minInt(i32),
        std.math.maxInt(i32),
    ));
}

fn fixed(value: f64) wl.Fixed {
    const minimum = @as(f64, @floatFromInt(std.math.minInt(i32))) / 256.0;
    const maximum = @as(f64, @floatFromInt(std.math.maxInt(i32))) / 256.0;
    return wl.Fixed.fromDouble(std.math.clamp(value, minimum, maximum));
}

test "drag action negotiation honors a common preference then bit order" {
    const source: wl.DataDeviceManager.DndAction = .{ .copy = true, .move = true };
    const destination: wl.DataDeviceManager.DndAction = .{ .copy = true, .move = true };

    try std.testing.expectEqual(action(.move), selectedAction(source, destination, action(.move)));
    try std.testing.expectEqual(action(.copy), selectedAction(source, destination, .{}));
    try std.testing.expectEqual(
        @as(u32, 0),
        actionBits(selectedAction(source, action(.ask), action(.ask))),
    );
}

test "drag icon position applies committed surface offsets" {
    try std.testing.expectEqual(@as(i32, 15), dragIconCoordinate(12.75, 3));
    try std.testing.expectEqual(std.math.maxInt(i32), dragIconCoordinate(1.0e20, 4));
}

const TestSelectionSource = struct {
    cancelled: usize = 0,

    fn mimeTypes(_: *anyopaque) []const [:0]const u8 {
        return &.{};
    }

    fn send(_: *anyopaque, _: [*:0]const u8, _: std.posix.fd_t) void {}

    fn cancel(context: *anyopaque) void {
        const self: *TestSelectionSource = @ptrCast(@alignCast(context));
        self.cancelled += 1;
    }

    fn source(self: *TestSelectionSource) SelectionSource {
        return .{
            .context = self,
            .mime_types = TestSelectionSource.mimeTypes,
            .send = TestSelectionSource.send,
            .cancel = TestSelectionSource.cancel,
        };
    }
};

test "older selection grant installs a used source after a newer clear" {
    var seat: Seat = undefined;
    var fixture: TestSelectionSource = .{};
    const external = fixture.source();
    var manager = testSelectionManager(&seat, .{ .external = &external }, 1);
    const source_id = try manager.sources.insert(std.testing.allocator, .{
        .resource = undefined,
    });
    defer {
        var source = manager.sources.remove(source_id).?;
        source.deinit(std.testing.allocator);
        manager.sources.deinit(std.testing.allocator);
    }

    const older_order: SeatAuthority.Order = 2;
    const newer_order: SeatAuthority.Order = 3;
    manager.setSelection(null, newer_order);
    try std.testing.expect(manager.selection == null);
    try std.testing.expectEqual(@as(usize, 1), fixture.cancelled);

    // DeviceResource marks a validated source used before selection arbitration.
    manager.sources.get(source_id).?.used = true;
    manager.setSelection(source_id, older_order);

    const expected: ?Selection = .{ .local = source_id };
    try std.testing.expect(std.meta.eql(expected, manager.selection));
    try std.testing.expect(manager.sources.get(source_id).?.used);
    try std.testing.expectEqual(older_order, manager.selection_order);
}

test "unchanged external selection preserves a prior client grant" {
    var seat: Seat = undefined;
    seat.authority = SeatAuthority.init(std.testing.allocator, undefined, undefined);
    defer seat.authority.deinit();
    const external_order = seat.nextSelectionOrder();
    const client_order = seat.nextSelectionOrder();

    var fixture: TestSelectionSource = .{};
    const external = fixture.source();
    var manager = testSelectionManager(&seat, .{ .external = &external }, external_order);
    const source_id = try manager.sources.insert(std.testing.allocator, .{
        .resource = undefined,
        .used = true,
    });
    defer {
        var source = manager.sources.remove(source_id).?;
        source.deinit(std.testing.allocator);
        manager.sources.deinit(std.testing.allocator);
    }

    manager.setExternalSelection(&external);
    try std.testing.expectEqual(external_order, manager.selection_order);
    manager.setSelection(source_id, client_order);

    const expected: ?Selection = .{ .local = source_id };
    try std.testing.expect(std.meta.eql(expected, manager.selection));
    try std.testing.expectEqual(client_order, manager.selection_order);
    try std.testing.expectEqual(@as(usize, 1), fixture.cancelled);
    try std.testing.expectEqual(client_order + 1, seat.nextSelectionOrder());
}

test "drag destination serial state remains protocol-local u32" {
    try std.testing.expect(@FieldType(OfferState, "enter_serial") == u32);
    try std.testing.expect(@FieldType(DragState.Target, "enter_serial") == u32);
    const create_info = @typeInfo(@TypeOf(OfferResource.create)).@"fn";
    try std.testing.expect(create_info.params[9].type.? == u32);
}

fn testSelectionManager(
    seat: *Seat,
    selection: ?Selection,
    selection_order: SeatAuthority.Order,
) Self {
    return .{
        .allocator = std.testing.allocator,
        .global = undefined,
        .display = undefined,
        .seat = seat,
        .surface_store = undefined,
        .listener = undefined,
        .sources = .{},
        .source_adapters = .empty,
        .devices = .{},
        .device_adapters = .empty,
        .offers = .{},
        .offer_adapters = .empty,
        .selection = selection,
        .selection_order = selection_order,
        .selection_generation = 0,
        .selection_listeners = .empty,
        .drag_selection_listeners = .empty,
        .focused_client = null,
        .drag = null,
        .retained_external_drag = null,
        .next_drag_generation = 0,
        .drag_icon = null,
    };
}
