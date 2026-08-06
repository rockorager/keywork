//! Protocol-free clipboard and drag-and-drop state for one compositor seat.
//!
//! Frontends own protocol objects and translate these synchronous callbacks.
//! Callback arguments (including transfer file descriptors) are borrowed only
//! for the duration of the call. This type never closes a descriptor.

const DataDevice = @This();

const std = @import("std");
const ClientRegistry = @import("ClientRegistry.zig");
const SeatAuthority = @import("SeatAuthority.zig");
const SurfaceRegistry = @import("SurfaceRegistry.zig");
const slot_map = @import("slot_map.zig");

pub const Actions = packed struct(u32) {
    copy: bool = false,
    move: bool = false,
    ask: bool = false,
    _reserved: u29 = 0,

    pub fn valid(self: Actions) bool {
        return self._reserved == 0;
    }

    pub fn empty(self: Actions) bool {
        return @as(u32, @bitCast(self)) == 0;
    }
};

pub const SourceEndpoint = struct {
    context: *anyopaque,
    send: *const fn (*anyopaque, []const u8, std.posix.fd_t) void,
    target: *const fn (*anyopaque, ?[]const u8) void,
    action: *const fn (*anyopaque, Actions) void,
    cancelled: *const fn (*anyopaque) void,
    selection_cancelled: ?*const fn (*anyopaque) void = null,
    drop_performed: *const fn (*anyopaque) void,
    finished: *const fn (*anyopaque) void,
};

pub const ToplevelDragHandler = struct {
    context: *anyopaque,
    started: *const fn (*anyopaque) void,
    ended: *const fn (*anyopaque) void,
    source_destroyed: *const fn (*anyopaque) void,
};

pub const DeviceEndpoint = struct {
    context: *anyopaque,
    selection: *const fn (*anyopaque, ?OfferId) void,
    drag_enter: *const fn (*anyopaque, SurfaceRegistry.Id, f64, f64, ?OfferId) void,
    drag_motion: *const fn (*anyopaque, u32, f64, f64) void,
    drag_leave: *const fn (*anyopaque) void,
    drag_drop: *const fn (*anyopaque) void,
};

pub const Listener = struct {
    context: *anyopaque,
    selection_changed: *const fn (*anyopaque) void,
    drag_changed: *const fn (*anyopaque) void,
    mime_offered: ?*const fn (*anyopaque, SourceId, []const u8) void = null,
    offer_mime_offered: ?*const fn (*anyopaque, OfferId, []const u8) void = null,
    offer_source_actions_changed: ?*const fn (*anyopaque, OfferId, Actions) void = null,
    offer_action_changed: ?*const fn (*anyopaque, OfferId, Actions) void = null,
    external_drag_start: ?*const fn (*anyopaque) ?ExternalDragStart = null,
    retained_source_destroyed: ?*const fn (*anyopaque, u64) void = null,
};

const SourceStore = slot_map.SlotMap(Source, enum { data_source });
const DeviceStore = slot_map.SlotMap(Device, enum { data_device });
const OfferStore = slot_map.SlotMap(Offer, enum { data_offer });
pub const SourceId = SourceStore.Id;
pub const DeviceId = DeviceStore.Id;
pub const OfferId = OfferStore.Id;

pub const SourceOptions = struct {
    actions: Actions = .{},
    actions_declared: bool = false,
};

const Source = struct {
    owner: ?ClientRegistry.Id,
    endpoint: SourceEndpoint,
    mime_types: std.ArrayList([:0]u8) = .empty,
    actions: Actions,
    actions_declared: bool,
    used: bool = false,
    toplevel_drag_handler: ?ToplevelDragHandler = null,

    fn deinit(self: *Source, allocator: std.mem.Allocator) void {
        for (self.mime_types.items) |mime| allocator.free(mime);
        self.mime_types.deinit(allocator);
    }
};

const Device = struct { owner: ClientRegistry.Id, endpoint: DeviceEndpoint };
pub const OfferKind = enum { selection, drag };
const Offer = struct {
    device: DeviceId,
    source: ?SourceId,
    kind: OfferKind,
    drag_generation: u64 = 0,
    active: bool = false,
    accepted: bool = false,
    destination_actions: Actions = .{},
    preferred_action: Actions = .{},
    selected_action: Actions = .{},
    dropped: bool = false,
    finished: bool = false,
};

pub const Target = struct { surface: SurfaceRegistry.Id, client: ClientRegistry.Id, x: f64, y: f64 };
pub const ExternalDragStart = struct { target: Target, global_x: f64, global_y: f64 };
pub const DragIcon = struct { surface: SurfaceRegistry.Id, offset_x: i32 = 0, offset_y: i32 = 0 };
pub const DragSourceInfo = struct {
    generation: u64,
    source: SourceId,
    mime_types: []const []u8,
    actions: Actions,
};
const Drag = struct {
    generation: u64,
    source: ?SourceId,
    owner: ?ClientRegistry.Id,
    origin: ?SurfaceRegistry.Id,
    target: ?Target = null,
    icon: ?DragIcon = null,
    external_pointer_delivery: ?ExternalPointerDelivery = null,
};
const ExternalPointerDelivery = struct {
    target: Target,
    global_x: f64,
    global_y: f64,
};
const Retained = struct { generation: u64, source: SourceId };

pub const Error = error{
    OutOfMemory,
    InvalidClient,
    InvalidSurface,
    InvalidSource,
    InvalidDevice,
    InvalidOffer,
    InvalidActionMask,
    InvalidPreferredAction,
    SourceAlreadyUsed,
    ActionsAlreadySet,
    MissingActions,
    Unauthorized,
    WrongClient,
    DragActive,
    NoDrag,
    InvalidFinish,
    InvalidMime,
};

allocator: std.mem.Allocator,
clients: *const ClientRegistry,
surfaces: *const SurfaceRegistry,
authority: *SeatAuthority,
listener: Listener,
sources: SourceStore = .{},
devices: DeviceStore = .{},
offers: OfferStore = .{},
selection: ?SourceId = null,
selection_order: SeatAuthority.Order = 0,
selection_generation: u64 = 0,
focused_client: ?ClientRegistry.Id = null,
drag: ?Drag = null,
retained: ?Retained = null,
next_drag_generation: u64 = 0,

pub fn init(allocator: std.mem.Allocator, clients: *const ClientRegistry, surfaces: *const SurfaceRegistry, authority: *SeatAuthority, listener: Listener) DataDevice {
    return .{ .allocator = allocator, .clients = clients, .surfaces = surfaces, .authority = authority, .listener = listener };
}

pub fn deinit(self: *DataDevice) void {
    self.cancelDrag();
    self.cancelRetained();
    self.clearSelection(self.authority.nextOrder());
    var offers = self.offers.iterator();
    while (offers.next()) |entry| _ = self.offers.remove(entry.id);
    var devices = self.devices.iterator();
    while (devices.next()) |entry| _ = self.devices.remove(entry.id);
    var sources = self.sources.iterator();
    while (sources.next()) |entry| {
        var source = self.sources.remove(entry.id).?;
        source.deinit(self.allocator);
    }
    self.offers.deinit(self.allocator);
    self.devices.deinit(self.allocator);
    self.sources.deinit(self.allocator);
    self.* = undefined;
}

pub fn createSource(self: *DataDevice, owner: ?ClientRegistry.Id, endpoint: SourceEndpoint, options: SourceOptions) Error!SourceId {
    if (owner) |id| if (!self.clients.contains(id)) return error.InvalidClient;
    if (!options.actions.valid()) return error.InvalidActionMask;
    return self.sources.insert(self.allocator, .{ .owner = owner, .endpoint = endpoint, .actions = options.actions, .actions_declared = options.actions_declared }) catch error.OutOfMemory;
}

pub fn destroySource(self: *DataDevice, id: SourceId) void {
    if (self.selection) |selected| if (std.meta.eql(selected, id)) self.replaceSelection(null, self.authority.nextOrder(), false);
    if (self.drag) |drag| if (drag.source != null and std.meta.eql(drag.source.?, id)) self.cancelDragWithoutSource();
    if (self.retained) |retained| if (std.meta.eql(retained.source, id)) {
        self.retained = null;
        self.listener.drag_changed(self.listener.context);
        if (self.listener.retained_source_destroyed) |notify| notify(self.listener.context, retained.generation);
    };
    var offers = self.offers.iterator();
    while (offers.next()) |entry| {
        if (entry.value.source != null and std.meta.eql(entry.value.source.?, id)) {
            entry.value.source = null;
        }
    }
    if (self.sources.get(id)) |source| if (source.toplevel_drag_handler) |handler| handler.source_destroyed(handler.context);
    var source = self.sources.remove(id) orelse return;
    source.deinit(self.allocator);
}

pub fn offerMime(self: *DataDevice, id: SourceId, mime: []const u8) Error!void {
    const source = self.sources.get(id) orelse return error.InvalidSource;
    for (source.mime_types.items) |existing| if (std.mem.eql(u8, existing, mime)) return;
    // Frontends may pass this owned value back to protocols whose wire string
    // API requires a sentinel; its public type remains a neutral plain slice.
    const copy = self.allocator.dupeZ(u8, mime) catch return error.OutOfMemory;
    errdefer self.allocator.free(copy);
    try source.mime_types.append(self.allocator, copy);
    if (self.listener.mime_offered) |offered| offered(self.listener.context, id, copy);
    var offers = self.offers.iterator();
    while (offers.next()) |entry| if (entry.value.source != null and std.meta.eql(entry.value.source.?, id)) {
        if (self.listener.offer_mime_offered) |offered| offered(self.listener.context, entry.id, copy);
    };
}

pub fn setSourceActions(self: *DataDevice, id: SourceId, actions: Actions) Error!void {
    if (!actions.valid()) return error.InvalidActionMask;
    const source = self.sources.get(id) orelse return error.InvalidSource;
    if (source.actions_declared) return error.ActionsAlreadySet;
    if (source.used) return error.SourceAlreadyUsed;
    source.actions = actions;
    source.actions_declared = true;
    self.notifySourceActions(id, actions);
}

pub fn setToplevelDragHandler(self: *DataDevice, id: SourceId, handler: ToplevelDragHandler) Error!void {
    const source = self.sources.get(id) orelse return error.InvalidSource;
    if (source.used or source.toplevel_drag_handler != null) return error.InvalidSource;
    source.toplevel_drag_handler = handler;
}

pub fn clearToplevelDragHandler(self: *DataDevice, id: SourceId, context: *anyopaque) void {
    const source = self.sources.get(id) orelse return;
    const handler = source.toplevel_drag_handler orelse return;
    if (handler.context == context) source.toplevel_drag_handler = null;
}

pub fn createDevice(self: *DataDevice, owner: ClientRegistry.Id, endpoint: DeviceEndpoint) Error!DeviceId {
    if (!self.clients.contains(owner)) return error.InvalidClient;
    const id = self.devices.insert(self.allocator, .{ .owner = owner, .endpoint = endpoint }) catch return error.OutOfMemory;
    if (self.focused_client != null and std.meta.eql(self.focused_client.?, owner)) self.publishSelection(id) catch {
        _ = self.devices.remove(id);
        return error.OutOfMemory;
    };
    if (self.drag) |drag| if (drag.target) |target| if (std.meta.eql(target.client, owner)) {
        const offer = if (drag.source) |source| self.offers.insert(self.allocator, .{
            .device = id,
            .source = source,
            .kind = .drag,
            .drag_generation = drag.generation,
            .active = true,
        }) catch {
            _ = self.devices.remove(id);
            return error.OutOfMemory;
        } else null;
        endpoint.drag_enter(endpoint.context, target.surface, target.x, target.y, offer);
    };
    return id;
}

pub fn destroyDevice(self: *DataDevice, id: DeviceId) void {
    var offers = self.offers.iterator();
    while (offers.next()) |entry| if (std.meta.eql(entry.value.device, id)) self.destroyOffer(entry.id);
    _ = self.devices.remove(id);
}

/// Retires every endpoint owned by an already-unregistered client. The caller
/// invokes this from its ClientRegistry disconnect listener.
pub fn clientDisconnected(self: *DataDevice, client: ClientRegistry.Id) void {
    if (self.focused_client != null and std.meta.eql(self.focused_client.?, client)) {
        self.focused_client = null;
        self.invalidateSelectionOffers();
    }
    if (self.drag) |drag| {
        if (drag.owner != null and std.meta.eql(drag.owner.?, client)) {
            // The frontend endpoint is already retired; never call back into it.
            if (drag.target) |target| {
                if (std.meta.eql(target.client, client)) self.leaveRetiredClient(client);
            }
            self.cancelDragWithoutSource();
        } else if (drag.target) |target| {
            if (std.meta.eql(target.client, client)) self.leaveRetiredClient(client);
        }
    }
    var devices = self.devices.iterator();
    while (devices.next()) |entry| if (std.meta.eql(entry.value.owner, client)) self.destroyDevice(entry.id);
    var sources = self.sources.iterator();
    while (sources.next()) |entry| if (entry.value.owner != null and std.meta.eql(entry.value.owner.?, client)) self.destroySource(entry.id);
}

fn leaveRetiredClient(self: *DataDevice, client: ClientRegistry.Id) void {
    const drag = self.drag orelse return;
    const target = drag.target orelse return;
    if (!std.meta.eql(target.client, client)) return;
    var offers = self.offers.iterator();
    while (offers.next()) |entry| {
        const offer = entry.value;
        if (offer.kind == .drag and offer.drag_generation == drag.generation and offer.active) {
            offer.active = false;
            offer.source = null;
        }
    }
    self.drag.?.target = null;
}

pub fn setFocus(self: *DataDevice, client: ?ClientRegistry.Id) Error!void {
    if (client) |id| if (!self.clients.contains(id)) return error.InvalidClient;
    self.invalidateSelectionOffers();
    self.focused_client = client;
    var devices = self.devices.iterator();
    while (devices.next()) |entry| if (client != null and std.meta.eql(entry.value.owner, client.?)) try self.publishSelection(entry.id);
}

pub fn setSelection(self: *DataDevice, device_id: DeviceId, source_id: ?SourceId, serial: ClientRegistry.Serial) Error!void {
    const device = self.devices.get(device_id) orelse return error.InvalidDevice;
    const order = self.authority.selectionOrder(device.owner, serial) orelse return error.Unauthorized;
    if (source_id) |id| {
        const source = self.sources.get(id) orelse return error.InvalidSource;
        if (source.owner == null or !std.meta.eql(source.owner.?, device.owner)) return error.WrongClient;
        if (source.actions_declared or source.toplevel_drag_handler != null) return error.InvalidSource;
        if (source.used) return error.SourceAlreadyUsed;
        source.used = true;
    }
    self.replaceSelection(source_id, order, true);
}

pub fn setExternalSelection(self: *DataDevice, source: ?SourceId) Error!void {
    if (source) |id| if (self.sources.get(id) == null) return error.InvalidSource;
    self.replaceSelection(source, self.authority.nextOrder(), true);
}

pub fn clearSelection(self: *DataDevice, order: SeatAuthority.Order) void {
    self.replaceSelection(null, order, true);
}

fn replaceSelection(self: *DataDevice, source: ?SourceId, order: SeatAuthority.Order, cancel_old: bool) void {
    if (self.selection != null and order < self.selection_order) return;
    if (std.meta.eql(self.selection, source)) {
        self.selection_order = order;
        return;
    }
    const old = self.selection;
    self.selection = source;
    self.selection_order = order;
    self.selection_generation +%= 1;
    self.invalidateSelectionOffers();
    var devices = self.devices.iterator();
    while (devices.next()) |entry| if (self.focused_client != null and std.meta.eql(entry.value.owner, self.focused_client.?)) self.publishSelection(entry.id) catch {};
    self.listener.selection_changed(self.listener.context);
    if (cancel_old and old != null) if (self.sources.get(old.?)) |state| {
        const callback = state.endpoint.selection_cancelled orelse state.endpoint.cancelled;
        callback(state.endpoint.context);
    };
}

fn publishSelection(self: *DataDevice, device_id: DeviceId) error{OutOfMemory}!void {
    const device = self.devices.get(device_id) orelse return;
    const source = self.selection orelse {
        device.endpoint.selection(device.endpoint.context, null);
        return;
    };
    const offer = try self.offers.insert(self.allocator, .{ .device = device_id, .source = source, .kind = .selection });
    device.endpoint.selection(device.endpoint.context, offer);
}

pub fn selectionGeneration(self: *const DataDevice) u64 {
    return self.selection_generation;
}
pub fn hasSelection(self: *const DataDevice) bool {
    return self.selection != null;
}
pub fn selectionMimeTypes(self: *const DataDevice) []const []u8 {
    const id = self.selection orelse return &.{};
    const source = self.sources.getConst(id) orelse return &.{};
    return @ptrCast(source.mime_types.items);
}

/// Requests a transfer from the current selection source. The descriptor is
/// borrowed synchronously; this owner neither closes nor retains it.
pub fn sendSelection(self: *DataDevice, mime: []const u8, fd: std.posix.fd_t) Error!void {
    const id = self.selection orelse return error.InvalidSource;
    try self.sendSource(id, mime, fd);
}

/// Requests a transfer from a specific live source. The descriptor remains
/// owned by the caller and is borrowed only through the synchronous callback.
pub fn sendSource(self: *DataDevice, id: SourceId, mime: []const u8, fd: std.posix.fd_t) Error!void {
    const source = self.sources.get(id) orelse return error.InvalidSource;
    if (!hasMime(source, mime)) return error.InvalidMime;
    source.endpoint.send(source.endpoint.context, mime, fd);
}

pub fn sourceMimeTypes(self: *const DataDevice, id: SourceId) Error![]const []u8 {
    const source = self.sources.getConst(id) orelse return error.InvalidSource;
    return @ptrCast(source.mime_types.items);
}

pub fn sourceActions(self: *const DataDevice, id: SourceId) Error!Actions {
    const source = self.sources.getConst(id) orelse return error.InvalidSource;
    return source.actions;
}

pub const OfferInfo = struct {
    device: DeviceId,
    source: ?SourceId,
    kind: OfferKind,
    drag_generation: u64,
    active: bool,
    accepted: bool,
    selected_action: Actions,
    dropped: bool,
    finished: bool,
};

pub fn offerInfo(self: *const DataDevice, id: OfferId) ?OfferInfo {
    const offer = self.offers.getConst(id) orelse return null;
    return .{
        .device = offer.device,
        .source = offer.source,
        .kind = offer.kind,
        .drag_generation = offer.drag_generation,
        .active = offer.active,
        .accepted = offer.accepted,
        .selected_action = offer.selected_action,
        .dropped = offer.dropped,
        .finished = offer.finished,
    };
}

pub fn startDrag(self: *DataDevice, device_id: DeviceId, source_id: ?SourceId, origin: SurfaceRegistry.Id, icon: ?DragIcon, serial: ClientRegistry.Serial, require_actions: bool) Error!u64 {
    if (self.drag != null) return error.DragActive;
    const device = self.devices.get(device_id) orelse return error.InvalidDevice;
    if (!self.surfaces.contains(origin)) return error.InvalidSurface;
    if (!self.authority.acceptsPointerGrab(device.owner, serial, origin)) return error.Unauthorized;
    if (icon) |value| if (!self.surfaces.contains(value.surface)) return error.InvalidSurface;
    if (source_id) |id| {
        const source = self.sources.get(id) orelse return error.InvalidSource;
        if (source.owner == null or !std.meta.eql(source.owner.?, device.owner)) return error.WrongClient;
        if (source.used) return error.SourceAlreadyUsed;
        if (require_actions and !source.actions_declared) return error.MissingActions;
        source.used = true;
    }
    self.cancelRetained();
    self.next_drag_generation +%= 1;
    if (self.next_drag_generation == 0) self.next_drag_generation = 1;
    self.drag = .{ .generation = self.next_drag_generation, .source = source_id, .owner = device.owner, .origin = origin, .icon = icon };
    if (source_id) |id| if (self.sources.get(id).?.toplevel_drag_handler) |handler| handler.started(handler.context);
    self.listener.drag_changed(self.listener.context);
    return self.next_drag_generation;
}

/// Starts a drag from a trusted non-client frontend such as Xwayland.
pub fn externalDragStart(self: *DataDevice) ?ExternalDragStart {
    const callback = self.listener.external_drag_start orelse return null;
    return callback(self.listener.context);
}

pub fn startExternalDrag(self: *DataDevice, source_id: SourceId, initial: ExternalDragStart) Error!u64 {
    if (self.drag != null) return error.DragActive;
    const source = self.sources.get(source_id) orelse return error.InvalidSource;
    if (source.owner != null or source.used) return error.InvalidSource;
    if (!self.authority.hasPointerButtons() or !self.clients.contains(initial.target.client) or
        !self.surfaces.contains(initial.target.surface)) return error.Unauthorized;
    source.used = true;
    self.cancelRetained();
    self.next_drag_generation +%= 1;
    if (self.next_drag_generation == 0) self.next_drag_generation = 1;
    self.drag = .{
        .generation = self.next_drag_generation,
        .source = source_id,
        .owner = null,
        .origin = null,
        .external_pointer_delivery = .{
            .target = initial.target,
            .global_x = initial.global_x,
            .global_y = initial.global_y,
        },
    };
    self.listener.drag_changed(self.listener.context);
    return self.next_drag_generation;
}

pub fn dragIsExternal(self: *const DataDevice) bool {
    const drag = self.drag orelse return false;
    const source = drag.source orelse return false;
    const state = self.sources.getConst(source) orelse return false;
    return state.owner == null;
}

pub fn setExternalPointerDelivery(self: *DataDevice, target: Target, global_x: f64, global_y: f64) void {
    const drag = if (self.drag) |*value| value else return;
    if (!self.dragIsExternal()) return;
    drag.external_pointer_delivery = .{ .target = target, .global_x = global_x, .global_y = global_y };
}

pub fn externalDragPointerFocus(self: *const DataDevice, global_x: f64, global_y: f64) ?Target {
    const drag = self.drag orelse return null;
    const delivery = drag.external_pointer_delivery orelse return null;
    var target = delivery.target;
    target.x += global_x - delivery.global_x;
    target.y += global_y - delivery.global_y;
    return target;
}

pub fn dragSourceInfo(self: *const DataDevice) ?DragSourceInfo {
    const generation, const source_id = if (self.drag) |drag|
        .{ drag.generation, drag.source orelse return null }
    else if (self.retained) |retained|
        .{ retained.generation, retained.source }
    else
        return null;
    const source = self.sources.getConst(source_id) orelse return null;
    return .{
        .generation = generation,
        .source = source_id,
        .mime_types = @ptrCast(source.mime_types.items),
        .actions = source.actions,
    };
}

pub fn updateExternalSourceActions(self: *DataDevice, source_id: SourceId, actions: Actions) Error!void {
    if (!actions.valid()) return error.InvalidActionMask;
    const source = self.sources.get(source_id) orelse return error.InvalidSource;
    if (source.owner != null) return error.InvalidSource;
    source.actions = actions;
    source.actions_declared = true;
    self.notifySourceActions(source_id, actions);
    var offers = self.offers.iterator();
    while (offers.next()) |entry| {
        const offer = entry.value;
        if (offer.source == null or !std.meta.eql(offer.source.?, source_id) or
            offer.kind != .drag or !offer.active) continue;
        const selected = selectAction(actions, offer.destination_actions, offer.preferred_action);
        if (@as(u32, @bitCast(selected)) == @as(u32, @bitCast(offer.selected_action))) continue;
        offer.selected_action = selected;
        self.notifyOfferAction(entry.id, selected);
        source.endpoint.action(source.endpoint.context, selected);
    }
}

pub fn externalTargetStatus(self: *DataDevice, generation: u64, accepted: bool, selected: Actions) void {
    const drag = self.drag orelse return;
    if (drag.generation != generation) return;
    const source = self.sources.get(drag.source orelse return) orelse return;
    if (!accepted) source.endpoint.target(source.endpoint.context, null);
    source.endpoint.action(source.endpoint.context, if (accepted) selected else .{});
}

pub fn dropOnExternalTarget(self: *DataDevice, generation: u64, accepted: bool) bool {
    const drag = self.drag orelse return false;
    if (drag.generation != generation) return false;
    const source_id = drag.source orelse {
        self.drag = null;
        self.listener.drag_changed(self.listener.context);
        return false;
    };
    const source = self.sources.get(source_id) orelse return false;
    if (accepted) {
        source.endpoint.drop_performed(source.endpoint.context);
        self.retained = .{ .generation = generation, .source = source_id };
    } else {
        source.endpoint.cancelled(source.endpoint.context);
    }
    self.endToplevel(source_id);
    invalidateGeneration(self, generation);
    self.drag = null;
    self.listener.drag_changed(self.listener.context);
    return accepted;
}

pub fn isDragging(self: *const DataDevice) bool {
    return self.drag != null;
}
pub fn dragIcon(self: *const DataDevice) ?DragIcon {
    return if (self.drag) |drag| drag.icon else null;
}

pub fn offsetDragIcon(self: *DataDevice, x: i32, y: i32) void {
    if (self.drag == null or self.drag.?.icon == null) return;
    self.drag.?.icon.?.offset_x +|= x;
    self.drag.?.icon.?.offset_y +|= y;
    self.listener.drag_changed(self.listener.context);
}

pub fn enter(self: *DataDevice, target: Target) Error!void {
    if (!self.clients.contains(target.client)) return error.InvalidClient;
    if (!self.surfaces.contains(target.surface)) return error.InvalidSurface;
    if (self.drag == null) return error.NoDrag;
    if (self.drag.?.target) |current| if (std.meta.eql(current.surface, target.surface) and
        std.meta.eql(current.client, target.client))
    {
        self.drag.?.target = target;
        return;
    };
    if (self.drag.?.source == null and !std.meta.eql(self.drag.?.owner.?, target.client)) return error.WrongClient;
    const generation = self.drag.?.generation;
    if (self.drag.?.source) |source| {
        var devices = self.devices.iterator();
        while (devices.next()) |entry| {
            if (!std.meta.eql(entry.value.owner, target.client)) continue;
            _ = self.offers.insert(self.allocator, .{
                .device = entry.id,
                .source = source,
                .kind = .drag,
                .drag_generation = generation,
            }) catch {
                self.removeStagedOffers(generation);
                return error.OutOfMemory;
            };
        }
    }
    self.leave();
    self.drag.?.target = target;
    var devices = self.devices.iterator();
    while (devices.next()) |entry| if (std.meta.eql(entry.value.owner, target.client)) {
        const offer: ?OfferId = if (self.drag.?.source != null) self.activateStagedOffer(entry.id, generation) else null;
        entry.value.endpoint.drag_enter(entry.value.endpoint.context, target.surface, target.x, target.y, offer);
    };
}

fn removeStagedOffers(self: *DataDevice, generation: u64) void {
    var offers = self.offers.iterator();
    while (offers.next()) |entry| {
        if (entry.value.kind == .drag and entry.value.drag_generation == generation and
            !entry.value.active and !entry.value.dropped)
        {
            _ = self.offers.remove(entry.id);
        }
    }
}

fn activateStagedOffer(self: *DataDevice, device: DeviceId, generation: u64) ?OfferId {
    var offers = self.offers.iterator();
    while (offers.next()) |entry| {
        if (entry.value.kind == .drag and entry.value.drag_generation == generation and
            std.meta.eql(entry.value.device, device) and !entry.value.active and
            !entry.value.dropped and entry.value.source != null)
        {
            entry.value.active = true;
            return entry.id;
        }
    }
    unreachable;
}

pub fn motion(self: *DataDevice, time: u32, x: f64, y: f64) void {
    if (self.drag == null or self.drag.?.target == null) return;
    self.drag.?.target.?.x = x;
    self.drag.?.target.?.y = y;
    const client = self.drag.?.target.?.client;
    var devices = self.devices.iterator();
    while (devices.next()) |entry| if (std.meta.eql(entry.value.owner, client)) entry.value.endpoint.drag_motion(entry.value.endpoint.context, time, x, y);
}

pub fn currentTarget(self: *const DataDevice) ?Target {
    return if (self.drag) |drag| drag.target else null;
}

pub fn updateTargetCoordinates(self: *DataDevice, x: f64, y: f64) void {
    if (self.drag == null or self.drag.?.target == null) return;
    self.drag.?.target.?.x = x;
    self.drag.?.target.?.y = y;
}

pub fn leave(self: *DataDevice) void {
    if (self.drag == null or self.drag.?.target == null) return;
    const client = self.drag.?.target.?.client;
    if (self.drag.?.source) |id| if (self.sources.get(id)) |source| {
        source.endpoint.target(source.endpoint.context, null);
        source.endpoint.action(source.endpoint.context, .{});
    };
    var devices = self.devices.iterator();
    while (devices.next()) |entry| if (std.meta.eql(entry.value.owner, client)) entry.value.endpoint.drag_leave(entry.value.endpoint.context);
    var offers = self.offers.iterator();
    while (offers.next()) |entry| if (entry.value.kind == .drag and entry.value.drag_generation == self.drag.?.generation and entry.value.active) {
        entry.value.active = false;
        entry.value.source = null;
    };
    self.drag.?.target = null;
}

pub fn accept(self: *DataDevice, offer_id: OfferId, mime: ?[]const u8) Error!void {
    const offer = self.offers.get(offer_id) orelse return error.InvalidOffer;
    if (offer.kind != .drag or (!offer.active and !offer.dropped)) return error.InvalidOffer;
    const source = self.sources.get(offer.source orelse return error.InvalidSource) orelse return error.InvalidSource;
    offer.accepted = if (mime) |value| hasMime(source, value) else false;
    source.endpoint.target(source.endpoint.context, if (offer.accepted) mime else null);
}

pub fn setOfferActions(self: *DataDevice, offer_id: OfferId, actions: Actions, preferred: Actions) Error!void {
    if (!actions.valid()) return error.InvalidActionMask;
    if (!preferred.valid() or (!preferred.empty() and (!single(preferred) or (@as(u32, @bitCast(preferred)) & @as(u32, @bitCast(actions))) == 0))) return error.InvalidPreferredAction;
    const offer = self.offers.get(offer_id) orelse return error.InvalidOffer;
    if (offer.kind != .drag) return error.InvalidOffer;
    const source = self.sources.get(offer.source orelse return error.InvalidSource) orelse return error.InvalidSource;
    if (offer.dropped and !offer.selected_action.ask) return;
    if (offer.dropped and !preferred.empty() and
        (@as(u32, @bitCast(preferred)) & @as(u32, @bitCast(source.actions))) == 0)
    {
        return error.InvalidPreferredAction;
    }
    offer.destination_actions = actions;
    offer.preferred_action = preferred;
    const selected = selectAction(source.actions, actions, preferred);
    if (@as(u32, @bitCast(selected)) != @as(u32, @bitCast(offer.selected_action))) {
        offer.selected_action = selected;
        self.notifyOfferAction(offer_id, selected);
        source.endpoint.action(source.endpoint.context, selected);
    }
}

pub fn receive(self: *DataDevice, offer_id: OfferId, mime: []const u8, fd: std.posix.fd_t) Error!void {
    const offer = self.offers.get(offer_id) orelse return error.InvalidOffer;
    if (offer.kind == .drag and !offer.active and !offer.dropped) return error.InvalidOffer;
    const source = self.sources.get(offer.source orelse return error.InvalidSource) orelse return error.InvalidSource;
    if (!hasMime(source, mime)) return error.InvalidSource;
    source.endpoint.send(source.endpoint.context, mime, fd);
}

pub fn drop(self: *DataDevice) void {
    const drag = self.drag orelse return;
    const target = drag.target orelse {
        self.cancelDrag();
        return;
    };
    var accepted = drag.source == null;
    if (drag.source) |id| if (self.sources.get(id)) |source| source.endpoint.drop_performed(source.endpoint.context);
    var offers = self.offers.iterator();
    while (offers.next()) |entry| if (entry.value.kind == .drag and entry.value.drag_generation == drag.generation and entry.value.active) {
        entry.value.active = false;
        accepted = accepted or (entry.value.accepted and !entry.value.selected_action.empty());
    };
    offers = self.offers.iterator();
    while (offers.next()) |entry| {
        if (entry.value.kind == .drag and entry.value.drag_generation == drag.generation)
            entry.value.dropped = accepted;
    }
    if (drag.source) |id| if (self.sources.get(id)) |source| {
        if (!accepted) source.endpoint.cancelled(source.endpoint.context);
        self.endToplevel(id);
    };
    var devices = self.devices.iterator();
    while (devices.next()) |entry| if (std.meta.eql(entry.value.owner, target.client)) {
        if (accepted) entry.value.endpoint.drag_drop(entry.value.endpoint.context);
        entry.value.endpoint.drag_leave(entry.value.endpoint.context);
    };
    self.drag = null;
    if (!accepted) invalidateGeneration(self, drag.generation);
    self.listener.drag_changed(self.listener.context);
}

pub fn finish(self: *DataDevice, offer_id: OfferId) Error!void {
    const offer = self.offers.get(offer_id) orelse return error.InvalidOffer;
    if (offer.kind != .drag or !offer.dropped or !offer.accepted or offer.selected_action.empty() or offer.selected_action.ask or offer.finished) return error.InvalidFinish;
    const source = self.sources.get(offer.source orelse return error.InvalidFinish) orelse return error.InvalidFinish;
    offer.finished = true;
    source.endpoint.finished(source.endpoint.context);
    invalidateGeneration(self, offer.drag_generation);
}

pub fn destroyOffer(self: *DataDevice, id: OfferId) void {
    self.retireOffer(id, false);
}

/// `legacy_finish` preserves pre-v3 completion when the adapter retires the
/// last dropped offer without an explicit finish request.
pub fn retireOffer(self: *DataDevice, id: OfferId, legacy_finish: bool) void {
    const offer = self.offers.remove(id) orelse return;
    if (offer.kind != .drag or !offer.dropped or offer.finished or offer.source == null) return;
    var offers = self.offers.iterator();
    while (offers.next()) |candidate| {
        if (candidate.value.kind == .drag and
            candidate.value.drag_generation == offer.drag_generation and
            candidate.value.dropped and !candidate.value.finished and
            candidate.value.source != null) return;
    }
    if (self.sources.get(offer.source.?)) |source| {
        if (legacy_finish) {
            source.endpoint.finished(source.endpoint.context);
        } else {
            source.endpoint.cancelled(source.endpoint.context);
        }
    }
    invalidateGeneration(self, offer.drag_generation);
}

pub fn cancelDrag(self: *DataDevice) void {
    self.cancelDragImpl(true);
}

pub fn cancel(self: *DataDevice) void {
    self.cancelDrag();
}
fn cancelDragWithoutSource(self: *DataDevice) void {
    self.cancelDragImpl(false);
}
fn cancelDragImpl(self: *DataDevice, notify: bool) void {
    const drag = self.drag orelse return;
    if (drag.source) |id| self.endToplevel(id);
    self.leave();
    if (notify and drag.source != null) if (self.sources.get(drag.source.?)) |source| source.endpoint.cancelled(source.endpoint.context);
    invalidateGeneration(self, drag.generation);
    self.drag = null;
    self.listener.drag_changed(self.listener.context);
}

fn endToplevel(self: *DataDevice, source_id: SourceId) void {
    const source = self.sources.get(source_id) orelse return;
    const handler = source.toplevel_drag_handler orelse return;
    source.toplevel_drag_handler = null;
    handler.ended(handler.context);
}

fn notifySourceActions(self: *DataDevice, source_id: SourceId, actions: Actions) void {
    const callback = self.listener.offer_source_actions_changed orelse return;
    var offers = self.offers.iterator();
    while (offers.next()) |entry| if (entry.value.source != null and std.meta.eql(entry.value.source.?, source_id))
        callback(self.listener.context, entry.id, actions);
}

fn notifyOfferAction(self: *DataDevice, offer_id: OfferId, actions: Actions) void {
    if (self.listener.offer_action_changed) |callback| callback(self.listener.context, offer_id, actions);
}

pub fn retainForExternalTarget(self: *DataDevice, generation: u64) Error!void {
    const drag = self.drag orelse return error.NoDrag;
    if (drag.generation != generation or drag.source == null) return error.NoDrag;
    self.retained = .{ .generation = generation, .source = drag.source.? };
    self.drag = null;
    self.listener.drag_changed(self.listener.context);
}

pub fn finishRetained(self: *DataDevice, generation: u64, performed: bool) void {
    const retained = self.retained orelse return;
    if (retained.generation != generation) return;
    if (self.sources.get(retained.source)) |source| if (performed) source.endpoint.finished(source.endpoint.context) else source.endpoint.cancelled(source.endpoint.context);
    self.retained = null;
    self.listener.drag_changed(self.listener.context);
}

fn cancelRetained(self: *DataDevice) void {
    if (self.retained) |value| self.finishRetained(value.generation, false);
}
fn invalidateSelectionOffers(self: *DataDevice) void {
    var it = self.offers.iterator();
    while (it.next()) |entry| {
        if (entry.value.kind == .selection) entry.value.source = null;
    }
}
fn invalidateGeneration(self: *DataDevice, generation: u64) void {
    var it = self.offers.iterator();
    while (it.next()) |entry| if (entry.value.kind == .drag and entry.value.drag_generation == generation) {
        entry.value.source = null;
        entry.value.active = false;
        entry.value.dropped = false;
    };
}
fn hasMime(source: *const Source, mime: []const u8) bool {
    for (source.mime_types.items) |value| if (std.mem.eql(u8, value, mime)) return true;
    return false;
}
fn single(actions: Actions) bool {
    const bits: u32 = @bitCast(actions);
    return bits != 0 and bits & (bits - 1) == 0;
}
pub fn selectAction(source: Actions, destination: Actions, preferred: Actions) Actions {
    const available: u32 = @as(u32, @bitCast(source)) & @as(u32, @bitCast(destination));
    const preferred_bits: u32 = @bitCast(preferred);
    if (preferred_bits != 0 and available & preferred_bits != 0) return preferred;
    if (available & 1 != 0) return .{ .copy = true };
    if (available & 2 != 0) return .{ .move = true };
    if (available & 4 != 0) return .{ .ask = true };
    return .{};
}

test "neutral action negotiation and nominal generations" {
    try std.testing.expectEqual(Actions{ .move = true }, selectAction(.{ .copy = true, .move = true }, .{ .copy = true, .move = true }, .{ .move = true }));
    try std.testing.expectEqual(Actions{ .copy = true }, selectAction(.{ .copy = true, .move = true }, .{ .copy = true }, .{}));
    try std.testing.expect(SourceId != DeviceId and DeviceId != OfferId);
}

test "selection authorization, publication, transfer, and replacement are canonical" {
    const Observer = struct {
        selection_offer: ?OfferId = null,
        sends: usize = 0,
        cancellations: usize = 0,
        selection_changes: usize = 0,
        expected_fd: std.posix.fd_t = -1,

        fn send(context: *anyopaque, mime: []const u8, fd: std.posix.fd_t) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            std.debug.assert(std.mem.eql(u8, mime, "text/plain"));
            std.debug.assert(fd == self.expected_fd);
            const payload = "canonical transfer";
            std.debug.assert(std.c.write(fd, payload.ptr, payload.len) == payload.len);
            self.sends += 1;
        }
        fn target(_: *anyopaque, _: ?[]const u8) void {}
        fn actionChanged(_: *anyopaque, _: Actions) void {}
        fn cancelled(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.cancellations += 1;
        }
        fn ignored(_: *anyopaque) void {}
        fn selection(context: *anyopaque, offer: ?OfferId) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.selection_offer = offer;
        }
        fn enter(_: *anyopaque, _: SurfaceRegistry.Id, _: f64, _: f64, _: ?OfferId) void {}
        fn motion(_: *anyopaque, _: u32, _: f64, _: f64) void {}
        fn changed(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.selection_changes += 1;
        }
    };

    var clients = ClientRegistry.init(std.testing.allocator);
    defer clients.deinit();
    var surfaces = SurfaceRegistry.init(std.testing.allocator);
    defer surfaces.deinit();
    var authority = SeatAuthority.init(std.testing.allocator, &clients, &surfaces);
    defer authority.deinit();
    var observer: Observer = .{};
    var data_device = DataDevice.init(std.testing.allocator, &clients, &surfaces, &authority, .{
        .context = &observer,
        .selection_changed = Observer.changed,
        .drag_changed = Observer.ignored,
    });
    defer data_device.deinit();

    const client = try clients.register(.mature_display);
    defer clients.unregister(client);
    const serial: ClientRegistry.Serial = .{ .domain = .mature_display, .value = 41 };
    try std.testing.expect(authority.recordSelection(client, serial));
    const source = try data_device.createSource(client, .{
        .context = &observer,
        .send = Observer.send,
        .target = Observer.target,
        .action = Observer.actionChanged,
        .cancelled = Observer.cancelled,
        .drop_performed = Observer.ignored,
        .finished = Observer.ignored,
    }, .{});
    defer data_device.destroySource(source);
    try data_device.offerMime(source, "text/plain");
    const device = try data_device.createDevice(client, .{
        .context = &observer,
        .selection = Observer.selection,
        .drag_enter = Observer.enter,
        .drag_motion = Observer.motion,
        .drag_leave = Observer.ignored,
        .drag_drop = Observer.ignored,
    });
    defer data_device.destroyDevice(device);

    try data_device.setFocus(client);
    const reserved = try data_device.createSource(client, .{
        .context = &observer,
        .send = Observer.send,
        .target = Observer.target,
        .action = Observer.actionChanged,
        .cancelled = Observer.cancelled,
        .drop_performed = Observer.ignored,
        .finished = Observer.ignored,
    }, .{});
    try data_device.setToplevelDragHandler(reserved, .{
        .context = &observer,
        .started = Observer.ignored,
        .ended = Observer.ignored,
        .source_destroyed = Observer.ignored,
    });
    try std.testing.expectError(error.InvalidSource, data_device.setSelection(device, reserved, serial));
    data_device.clearToplevelDragHandler(reserved, &observer);
    data_device.destroySource(reserved);
    try data_device.setSelection(device, source, serial);
    const offer = observer.selection_offer orelse return error.TestExpectedEqual;
    var pipe: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe2(&pipe, .{ .CLOEXEC = true }));
    defer _ = std.c.close(pipe[0]);
    observer.expected_fd = pipe[1];
    try data_device.receive(offer, "text/plain", pipe[1]);
    try std.testing.expectEqual(@as(c_int, 0), std.c.close(pipe[1]));
    var transfer: [32]u8 = undefined;
    const transferred = std.c.read(pipe[0], &transfer, transfer.len);
    try std.testing.expectEqualStrings("canonical transfer", transfer[0..@intCast(transferred)]);
    try std.testing.expectEqual(@as(usize, 1), observer.sends);
    try std.testing.expectEqual(@as(usize, 1), observer.selection_changes);
    try data_device.setSelection(device, null, serial);
    try std.testing.expectEqual(@as(usize, 1), observer.cancellations);
    authority.discardGrants();
}

test "drag lifecycle rejects cross-client and stale IDs and finishes negotiated offers" {
    const Provider = struct {
        fn renderState(_: *anyopaque) ?SurfaceRegistry.RenderState {
            return null;
        }
    };
    const Observer = struct {
        offer: ?OfferId = null,
        targets: usize = 0,
        actions: usize = 0,
        drops: usize = 0,
        finishes: usize = 0,
        cancellations: usize = 0,
        enters: usize = 0,
        leaves: usize = 0,
        device_drops: usize = 0,

        fn send(_: *anyopaque, _: []const u8, _: std.posix.fd_t) void {}
        fn target(context: *anyopaque, _: ?[]const u8) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.targets += 1;
        }
        fn action(context: *anyopaque, _: Actions) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.actions += 1;
        }
        fn cancelled(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.cancellations += 1;
        }
        fn dropped(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.drops += 1;
        }
        fn finished(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.finishes += 1;
        }
        fn selection(_: *anyopaque, _: ?OfferId) void {}
        fn enter(context: *anyopaque, _: SurfaceRegistry.Id, _: f64, _: f64, offer: ?OfferId) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.offer = offer;
            self.enters += 1;
        }
        fn motion(_: *anyopaque, _: u32, _: f64, _: f64) void {}
        fn leave(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.leaves += 1;
        }
        fn deviceDrop(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.device_drops += 1;
        }
        fn changed(_: *anyopaque) void {}
    };

    var clients = ClientRegistry.init(std.testing.allocator);
    var surfaces = SurfaceRegistry.init(std.testing.allocator);
    var authority = SeatAuthority.init(std.testing.allocator, &clients, &surfaces);
    var observer: Observer = .{};
    var data_device = DataDevice.init(std.testing.allocator, &clients, &surfaces, &authority, .{
        .context = &observer,
        .selection_changed = Observer.changed,
        .drag_changed = Observer.changed,
    });
    const source_client = try clients.register(.mature_display);
    const target_client = try clients.register(.mature_display);
    var provider: Provider = .{};
    const origin = try surfaces.add(.{ .context = &provider, .render_state = Provider.renderState });
    const target = try surfaces.add(.{ .context = &provider, .render_state = Provider.renderState });
    const source_endpoint: SourceEndpoint = .{
        .context = &observer,
        .send = Observer.send,
        .target = Observer.target,
        .action = Observer.action,
        .cancelled = Observer.cancelled,
        .drop_performed = Observer.dropped,
        .finished = Observer.finished,
    };
    const device_endpoint: DeviceEndpoint = .{
        .context = &observer,
        .selection = Observer.selection,
        .drag_enter = Observer.enter,
        .drag_motion = Observer.motion,
        .drag_leave = Observer.leave,
        .drag_drop = Observer.deviceDrop,
    };
    const source_device = try data_device.createDevice(source_client, device_endpoint);
    const target_device = try data_device.createDevice(target_client, device_endpoint);
    const source = try data_device.createSource(source_client, source_endpoint, .{});
    try data_device.offerMime(source, "text/plain");
    try data_device.setSourceActions(source, .{ .copy = true, .move = true });
    const serial: ClientRegistry.Serial = .{ .domain = .mature_display, .value = 77 };
    try std.testing.expect(try authority.addPointerPress(source_client, serial, 0x110, origin));
    try std.testing.expect(authority.recordSelection(target_client, serial));

    try std.testing.expectError(error.WrongClient, data_device.setSelection(target_device, source, serial));
    const generation = try data_device.startDrag(source_device, source, origin, .{ .surface = origin }, serial, true);
    try data_device.enter(.{ .surface = target, .client = target_client, .x = 4, .y = 5 });
    const offer = observer.offer.?;
    try data_device.accept(offer, "text/plain");
    try data_device.setOfferActions(offer, .{ .copy = true, .move = true }, .{ .move = true });
    try std.testing.expectEqual(Actions{ .move = true }, data_device.offerInfo(offer).?.selected_action);
    data_device.drop();
    try std.testing.expectEqual(@as(usize, 1), observer.drops);
    try std.testing.expectEqual(@as(usize, 1), observer.device_drops);
    try data_device.finish(offer);
    try std.testing.expectEqual(@as(usize, 1), observer.finishes);
    try std.testing.expect(data_device.offerInfo(offer).?.finished);
    try std.testing.expectError(error.NoDrag, data_device.retainForExternalTarget(generation));

    data_device.destroyOffer(offer);
    try std.testing.expect(data_device.offerInfo(offer) == null);
    const reused_source = try data_device.createSource(source_client, source_endpoint, .{});
    data_device.destroySource(reused_source);
    const current_source = try data_device.createSource(source_client, source_endpoint, .{});
    try std.testing.expectEqual(reused_source.index, current_source.index);
    try std.testing.expect(reused_source.generation != current_source.generation);
    try std.testing.expectError(error.InvalidSource, data_device.offerMime(reused_source, "stale"));

    data_device.destroySource(current_source);
    data_device.destroySource(source);
    data_device.destroyDevice(target_device);
    data_device.destroyDevice(source_device);
    authority.clearPointerPresses();
    authority.discardGrants();
    surfaces.remove(target);
    surfaces.remove(origin);
    clients.unregister(target_client);
    clients.unregister(source_client);
    data_device.deinit();
    authority.deinit();
    surfaces.deinit();
    clients.deinit();
}

test "allocation failure rolls source and MIME creation back" {
    const Endpoint = struct {
        fn send(_: *anyopaque, _: []const u8, _: std.posix.fd_t) void {}
        fn target(_: *anyopaque, _: ?[]const u8) void {}
        fn action(_: *anyopaque, _: Actions) void {}
        fn notify(_: *anyopaque) void {}
        fn changed(_: *anyopaque) void {}
    };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var clients = ClientRegistry.init(std.testing.allocator);
    var surfaces = SurfaceRegistry.init(std.testing.allocator);
    var authority = SeatAuthority.init(std.testing.allocator, &clients, &surfaces);
    var context: u8 = 0;
    var data_device = DataDevice.init(failing.allocator(), &clients, &surfaces, &authority, .{
        .context = &context,
        .selection_changed = Endpoint.changed,
        .drag_changed = Endpoint.changed,
    });
    const client = try clients.register(.mature_display);
    const endpoint: SourceEndpoint = .{
        .context = &context,
        .send = Endpoint.send,
        .target = Endpoint.target,
        .action = Endpoint.action,
        .cancelled = Endpoint.notify,
        .drop_performed = Endpoint.notify,
        .finished = Endpoint.notify,
    };
    try std.testing.expectError(error.OutOfMemory, data_device.createSource(client, endpoint, .{}));
    failing.fail_index = std.math.maxInt(usize);
    const source = try data_device.createSource(client, endpoint, .{});
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, data_device.offerMime(source, "text/plain"));
    try std.testing.expectEqual(@as(usize, 0), (try data_device.sourceMimeTypes(source)).len);
    failing.fail_index = std.math.maxInt(usize);
    data_device.destroySource(source);
    clients.unregister(client);
    data_device.deinit();
    authority.deinit();
    surfaces.deinit();
    clients.deinit();
}

test "disconnect retires endpoints without callbacks" {
    const Observer = struct {
        callbacks: usize = 0,
        fn send(_: *anyopaque, _: []const u8, _: std.posix.fd_t) void {}
        fn target(_: *anyopaque, _: ?[]const u8) void {}
        fn action(_: *anyopaque, _: Actions) void {}
        fn notify(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.callbacks += 1;
        }
        fn selection(_: *anyopaque, _: ?OfferId) void {}
        fn enter(_: *anyopaque, _: SurfaceRegistry.Id, _: f64, _: f64, _: ?OfferId) void {}
        fn motion(_: *anyopaque, _: u32, _: f64, _: f64) void {}
        fn changed(_: *anyopaque) void {}
    };
    var clients = ClientRegistry.init(std.testing.allocator);
    var surfaces = SurfaceRegistry.init(std.testing.allocator);
    var authority = SeatAuthority.init(std.testing.allocator, &clients, &surfaces);
    var observer: Observer = .{};
    var data_device = DataDevice.init(std.testing.allocator, &clients, &surfaces, &authority, .{
        .context = &observer,
        .selection_changed = Observer.changed,
        .drag_changed = Observer.changed,
    });
    const client = try clients.register(.mature_display);
    const source = try data_device.createSource(client, .{
        .context = &observer,
        .send = Observer.send,
        .target = Observer.target,
        .action = Observer.action,
        .cancelled = Observer.notify,
        .drop_performed = Observer.notify,
        .finished = Observer.notify,
    }, .{});
    _ = try data_device.createDevice(client, .{
        .context = &observer,
        .selection = Observer.selection,
        .drag_enter = Observer.enter,
        .drag_motion = Observer.motion,
        .drag_leave = Observer.notify,
        .drag_drop = Observer.notify,
    });
    clients.unregister(client);
    data_device.clientDisconnected(client);
    try std.testing.expectEqual(@as(usize, 0), observer.callbacks);
    try std.testing.expectError(error.InvalidSource, data_device.offerMime(source, "stale"));
    _ = authority.clientDisconnected(client);
    data_device.deinit();
    authority.deinit();
    surfaces.deinit();
    clients.deinit();
}
