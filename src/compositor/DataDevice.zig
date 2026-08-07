//! Protocol-free clipboard and drag-and-drop state for one compositor seat.
//!
//! Frontends own protocol objects and translate these synchronous callbacks.
//! Callback arguments (including transfer file descriptors) are borrowed only
//! for the duration of the call. This type never closes a descriptor.

const DataDevice = @This();

const std = @import("std");
const builtin = @import("builtin");
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
    target_preflight: ?*const fn (*anyopaque, ?[]const u8) error{OutOfMemory}!void = null,
    target: *const fn (*anyopaque, ?[]const u8) void,
    action_preflight: ?*const fn (*anyopaque, Actions) error{OutOfMemory}!void = null,
    action: *const fn (*anyopaque, Actions) void,
    cancelled_preflight: ?*const fn (*anyopaque) error{OutOfMemory}!void = null,
    cancelled: *const fn (*anyopaque) void,
    selection_cancelled: ?*const fn (*anyopaque) void = null,
    drop_performed_preflight: ?*const fn (*anyopaque) error{OutOfMemory}!void = null,
    drop_performed: *const fn (*anyopaque) void,
    finished_preflight: ?*const fn (*anyopaque) error{OutOfMemory}!void = null,
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
    selection: *const fn (*anyopaque, ?OfferId) error{OutOfMemory}!void,
    drag_enter_prepare: *const fn (*anyopaque, SurfaceRegistry.Id, f64, f64, ?OfferId) error{OutOfMemory}!DragPreparation,
    drag_enter_abort: ?*const fn (*anyopaque) void = null,
    drag_enter: *const fn (*anyopaque, SurfaceRegistry.Id, f64, f64, ?OfferId) void,
    drag_motion_preflight: ?*const fn (*anyopaque, u32, f64, f64) error{OutOfMemory}!void = null,
    drag_motion: *const fn (*anyopaque, u32, f64, f64) void,
    drag_leave_preflight: ?*const fn (*anyopaque) error{OutOfMemory}!void = null,
    drag_leave: *const fn (*anyopaque) void,
    drag_drop_preflight: ?*const fn (*anyopaque) error{OutOfMemory}!void = null,
    drag_drop: *const fn (*anyopaque) void,
};

pub const DragPreparation = struct {
    legacy_copy: bool = false,
};

pub const Listener = struct {
    context: *anyopaque,
    transaction_finalize: ?*const fn (*anyopaque) error{OutOfMemory}!void = null,
    transaction_commit: ?*const fn (*anyopaque) void = null,
    transaction_abort: ?*const fn (*anyopaque) void = null,
    selection_changed: *const fn (*anyopaque) void,
    drag_changed: *const fn (*anyopaque) void,
    mime_offered: ?*const fn (*anyopaque, SourceId, []const u8) void = null,
    offer_rolled_back: ?*const fn (*anyopaque, OfferId) void = null,
    offer_mime_offered: ?*const fn (*anyopaque, OfferId, []const u8) void = null,
    offer_source_actions_preflight: ?*const fn (*anyopaque, OfferId, Actions) error{OutOfMemory}!void = null,
    offer_source_actions_changed: ?*const fn (*anyopaque, OfferId, Actions) void = null,
    offer_action_preflight: ?*const fn (*anyopaque, OfferId, Actions) error{OutOfMemory}!void = null,
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
    device: ?DeviceId,
    source: ?SourceId,
    kind: OfferKind,
    publication: u64 = 0,
    drag_generation: u64 = 0,
    active: bool = false,
    accepted: bool = false,
    implicit_copy: bool = false,
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
next_publication: u64 = 0,
enter_stage_failure: if (builtin.is_test) ?usize else void = if (builtin.is_test) null else {},

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
    if (self.selection) |selected| if (std.meta.eql(selected, id)) self.replaceSelection(null, self.authority.nextOrder(), false) catch unreachable;
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
    var offers = self.offers.iterator();
    while (offers.next()) |entry| if (entry.value.source != null and std.meta.eql(entry.value.source.?, id))
        if (self.listener.offer_source_actions_preflight) |prepare| prepare(self.listener.context, entry.id, actions) catch {
            self.abortTransaction();
            return error.OutOfMemory;
        };
    self.finalizeTransaction() catch {
        self.abortTransaction();
        return error.OutOfMemory;
    };
    source.actions = actions;
    source.actions_declared = true;
    self.notifySourceActions(id, actions);
    self.commitTransaction();
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
    errdefer {
        self.removeOffersForDevice(id);
        _ = self.devices.remove(id);
    }
    const selection_offer: ?OfferId = if (self.focused_client != null and
        std.meta.eql(self.focused_client.?, owner) and self.selection != null)
        self.offers.insert(self.allocator, .{
            .device = id,
            .source = self.selection,
            .kind = .selection,
            .publication = self.issuePublication(),
        }) catch return error.OutOfMemory
    else
        null;
    const drag_offer: ?OfferId = if (self.drag) |drag| if (drag.target) |target| if (std.meta.eql(target.client, owner) and drag.source != null)
        self.offers.insert(self.allocator, .{
            .device = id,
            .source = drag.source,
            .kind = .drag,
            .drag_generation = drag.generation,
            .active = true,
        }) catch return error.OutOfMemory
    else
        null else null else null;
    if (self.focused_client != null and std.meta.eql(self.focused_client.?, owner))
        try endpoint.selection(endpoint.context, selection_offer);
    if (self.drag) |drag| if (drag.target) |target| if (std.meta.eql(target.client, owner)) {
        const prepared = endpoint.drag_enter_prepare(endpoint.context, target.surface, target.x, target.y, drag_offer) catch {
            self.abortTransaction();
            return error.OutOfMemory;
        };
        self.finalizeTransaction() catch {
            if (endpoint.drag_enter_abort) |abort| abort(endpoint.context);
            self.abortTransaction();
            return error.OutOfMemory;
        };
        if (prepared.legacy_copy) self.commitLegacyOffer(drag_offer.?);
        endpoint.drag_enter(endpoint.context, target.surface, target.x, target.y, drag_offer);
        self.commitTransaction();
    };
    return id;
}

pub fn destroyDevice(self: *DataDevice, id: DeviceId) void {
    var offers = self.offers.iterator();
    while (offers.next()) |entry| {
        if (entry.value.device != null and std.meta.eql(entry.value.device.?, id))
            entry.value.device = null;
    }
    _ = self.devices.remove(id);
}

fn removeOffersForDevice(self: *DataDevice, id: DeviceId) void {
    var offers = self.offers.iterator();
    while (offers.next()) |entry| {
        if (entry.value.device != null and std.meta.eql(entry.value.device.?, id)) {
            const offer_id = entry.id;
            if (self.listener.offer_rolled_back) |rolled_back| rolled_back(self.listener.context, offer_id);
            _ = self.offers.remove(offer_id);
        }
    }
}

/// Retires every endpoint owned by an already-unregistered client. The caller
/// invokes this from its ClientRegistry disconnect listener.
pub fn clientDisconnected(self: *DataDevice, client: ClientRegistry.Id) void {
    if (self.focused_client != null and std.meta.eql(self.focused_client.?, client)) {
        self.focused_client = null;
        self.invalidateSelectionOffers(null);
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
    const publication = self.issuePublication();
    errdefer self.removePublication(publication);
    if (client != null and self.selection != null)
        try self.stageSelectionOffers(client.?, self.selection.?, publication);
    try self.publishSelectionBatch(client, publication);
    self.invalidateSelectionOffers(publication);
    self.focused_client = client;
}

pub fn setSelection(self: *DataDevice, device_id: DeviceId, source_id: ?SourceId, serial: ClientRegistry.Serial) Error!void {
    const device = self.devices.get(device_id) orelse return error.InvalidDevice;
    const order = self.authority.selectionOrder(device.owner, serial) orelse return error.Unauthorized;
    if (source_id) |id| {
        const source = self.sources.get(id) orelse return error.InvalidSource;
        if (source.owner == null or !std.meta.eql(source.owner.?, device.owner)) return error.WrongClient;
        if (source.actions_declared or source.toplevel_drag_handler != null) return error.InvalidSource;
        if (source.used) return error.SourceAlreadyUsed;
    }
    try self.replaceSelection(source_id, order, true);
    if (source_id) |id| self.sources.get(id).?.used = true;
}

pub fn setExternalSelection(self: *DataDevice, source: ?SourceId) Error!void {
    if (source) |id| if (self.sources.get(id) == null) return error.InvalidSource;
    try self.replaceSelection(source, self.authority.nextOrder(), true);
}

pub fn clearSelection(self: *DataDevice, order: SeatAuthority.Order) void {
    self.replaceSelection(null, order, true) catch unreachable;
}

fn replaceSelection(self: *DataDevice, source: ?SourceId, order: SeatAuthority.Order, cancel_old: bool) Error!void {
    if (self.selection != null and order < self.selection_order) return;
    if (std.meta.eql(self.selection, source)) {
        self.selection_order = order;
        return;
    }
    const publication = self.issuePublication();
    errdefer self.removePublication(publication);
    if (self.focused_client != null and source != null)
        try self.stageSelectionOffers(self.focused_client.?, source.?, publication);
    try self.publishSelectionBatch(self.focused_client, publication);
    const old = self.selection;
    self.selection = source;
    self.selection_order = order;
    self.selection_generation +%= 1;
    self.invalidateSelectionOffers(publication);
    self.listener.selection_changed(self.listener.context);
    if (cancel_old and old != null) if (self.sources.get(old.?)) |state| {
        const callback = state.endpoint.selection_cancelled orelse state.endpoint.cancelled;
        callback(state.endpoint.context);
    };
}

fn stageSelectionOffers(self: *DataDevice, client: ClientRegistry.Id, source: SourceId, publication: u64) error{OutOfMemory}!void {
    var devices = self.devices.iterator();
    while (devices.next()) |entry| if (std.meta.eql(entry.value.owner, client)) {
        _ = self.offers.insert(self.allocator, .{
            .device = entry.id,
            .source = source,
            .kind = .selection,
            .publication = publication,
        }) catch return error.OutOfMemory;
    };
}

fn publishSelectionBatch(self: *DataDevice, client: ?ClientRegistry.Id, publication: u64) error{OutOfMemory}!void {
    var devices = self.devices.iterator();
    while (devices.next()) |entry| if (client != null and std.meta.eql(entry.value.owner, client.?)) {
        var offer: ?OfferId = null;
        var offers = self.offers.iterator();
        while (offers.next()) |candidate| if (candidate.value.kind == .selection and
            candidate.value.publication == publication and candidate.value.device != null and
            std.meta.eql(candidate.value.device.?, entry.id))
        {
            offer = candidate.id;
            break;
        };
        try entry.value.endpoint.selection(entry.value.endpoint.context, offer);
    };
}

fn removePublication(self: *DataDevice, publication: u64) void {
    var offers = self.offers.iterator();
    while (offers.next()) |entry| {
        if (entry.value.kind == .selection and entry.value.publication == publication) {
            const id = entry.id;
            if (self.listener.offer_rolled_back) |rolled_back| rolled_back(self.listener.context, id);
            _ = self.offers.remove(id);
        }
    }
}

fn issuePublication(self: *DataDevice) u64 {
    self.next_publication +%= 1;
    if (self.next_publication == 0) self.next_publication = 1;
    return self.next_publication;
}

pub fn selectionGeneration(self: *const DataDevice) u64 {
    return self.selection_generation;
}
pub fn hasSelection(self: *const DataDevice) bool {
    return self.selection != null;
}
pub fn selectionIs(self: *const DataDevice, source: SourceId) bool {
    return self.selection != null and std.meta.eql(self.selection.?, source);
}
pub const ResourceCounts = struct {
    sources: usize,
    devices: usize,
    offers: usize,
};
pub fn resourceCounts(self: *const DataDevice) ResourceCounts {
    return .{
        .sources = self.sources.len(),
        .devices = self.devices.len(),
        .offers = self.offers.len(),
    };
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
    device: ?DeviceId,
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
    try self.validateDragStart(device_id, source_id, origin, icon, serial, require_actions);
    const device = self.devices.get(device_id).?;
    if (source_id) |id| self.sources.get(id).?.used = true;
    self.cancelRetained();
    self.next_drag_generation +%= 1;
    if (self.next_drag_generation == 0) self.next_drag_generation = 1;
    self.drag = .{ .generation = self.next_drag_generation, .source = source_id, .owner = device.owner, .origin = origin, .icon = icon };
    if (source_id) |id| if (self.sources.get(id).?.toplevel_drag_handler) |handler| handler.started(handler.context);
    self.listener.drag_changed(self.listener.context);
    return self.next_drag_generation;
}

pub fn validateDragStart(self: *const DataDevice, device_id: DeviceId, source_id: ?SourceId, origin: SurfaceRegistry.Id, icon: ?DragIcon, serial: ClientRegistry.Serial, require_actions: bool) Error!void {
    if (self.drag != null) return error.DragActive;
    const device = self.devices.getConst(device_id) orelse return error.InvalidDevice;
    if (!self.surfaces.contains(origin)) return error.InvalidSurface;
    if (!self.authority.acceptsPointerGrab(device.owner, serial, origin)) return error.Unauthorized;
    if (icon) |value| if (!self.surfaces.contains(value.surface)) return error.InvalidSurface;
    if (source_id) |id| {
        const source = self.sources.getConst(id) orelse return error.InvalidSource;
        if (source.owner == null or !std.meta.eql(source.owner.?, device.owner)) return error.WrongClient;
        if (source.used) return error.SourceAlreadyUsed;
        if (require_actions and !source.actions_declared) return error.MissingActions;
    }
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
    var offers = self.offers.iterator();
    while (offers.next()) |entry| if (entry.value.source != null and std.meta.eql(entry.value.source.?, source_id)) {
        if (self.listener.offer_source_actions_preflight) |prepare| prepare(self.listener.context, entry.id, actions) catch {
            self.abortTransaction();
            return error.OutOfMemory;
        };
        const offer = entry.value;
        if (offer.kind != .drag or !offer.active) continue;
        const selected = selectAction(actions, offer.destination_actions, offer.preferred_action);
        if (@as(u32, @bitCast(selected)) == @as(u32, @bitCast(offer.selected_action))) continue;
        if (self.listener.offer_action_preflight) |prepare| prepare(self.listener.context, entry.id, selected) catch {
            self.abortTransaction();
            return error.OutOfMemory;
        };
        if (source.endpoint.action_preflight) |prepare| prepare(source.endpoint.context, selected) catch {
            self.abortTransaction();
            return error.OutOfMemory;
        };
    };
    self.finalizeTransaction() catch {
        self.abortTransaction();
        return error.OutOfMemory;
    };
    source.actions = actions;
    source.actions_declared = true;
    self.notifySourceActions(source_id, actions);
    offers = self.offers.iterator();
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
    self.commitTransaction();
}

pub fn externalTargetStatus(self: *DataDevice, generation: u64, accepted: bool, selected: Actions) void {
    const drag = self.drag orelse return;
    if (drag.generation != generation) return;
    const source = self.sources.get(drag.source orelse return) orelse return;
    if (!accepted) if (source.endpoint.target_preflight) |prepare| prepare(source.endpoint.context, null) catch {
        self.abortTransaction();
        return;
    };
    if (source.endpoint.action_preflight) |prepare| prepare(source.endpoint.context, if (accepted) selected else .{}) catch {
        self.abortTransaction();
        return;
    };
    self.finalizeTransaction() catch {
        self.abortTransaction();
        return;
    };
    if (!accepted) source.endpoint.target(source.endpoint.context, null);
    source.endpoint.action(source.endpoint.context, if (accepted) selected else .{});
    self.commitTransaction();
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
        if (source.endpoint.drop_performed_preflight) |prepare| prepare(source.endpoint.context) catch {
            self.abortTransaction();
            return false;
        };
    } else if (source.endpoint.cancelled_preflight) |prepare| prepare(source.endpoint.context) catch {
        self.abortTransaction();
        return false;
    };
    self.finalizeTransaction() catch {
        self.abortTransaction();
        return false;
    };
    if (accepted) {
        source.endpoint.drop_performed(source.endpoint.context);
        self.retained = .{ .generation = generation, .source = source_id };
    } else {
        source.endpoint.cancelled(source.endpoint.context);
    }
    self.endToplevel(source_id);
    invalidateGeneration(self, generation);
    self.drag = null;
    self.commitTransaction();
    self.listener.drag_changed(self.listener.context);
    return accepted;
}

pub fn isDragging(self: *const DataDevice) bool {
    return self.drag != null;
}
pub fn dragIcon(self: *const DataDevice) ?DragIcon {
    return if (self.drag) |drag| drag.icon else null;
}

pub fn surfaceDestroyed(self: *DataDevice, surface: SurfaceRegistry.Id) void {
    const drag = self.drag orelse return;
    if (drag.origin != null and std.meta.eql(drag.origin.?, surface)) {
        self.cancelDrag();
        return;
    }
    if (drag.icon != null and std.meta.eql(drag.icon.?.surface, surface)) {
        self.drag.?.icon = null;
        self.listener.drag_changed(self.listener.context);
    }
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
    const BatchItem = struct {
        device: DeviceId,
        offer: OfferId,
        preparation: DragPreparation = .{},
    };
    var batch: std.ArrayList(BatchItem) = .empty;
    defer batch.deinit(self.allocator);
    var device_count: usize = 0;
    var devices = self.devices.iterator();
    while (devices.next()) |entry| if (std.meta.eql(entry.value.owner, target.client)) {
        device_count += 1;
    };
    try batch.ensureTotalCapacity(self.allocator, device_count);
    if (self.drag.?.source) |source| {
        devices = self.devices.iterator();
        while (devices.next()) |entry| {
            if (!std.meta.eql(entry.value.owner, target.client)) continue;
            if (self.failEnterStageAllocationForTest()) {
                self.rollbackEnterBatch(batch.items);
                return error.OutOfMemory;
            }
            const offer = self.offers.insert(self.allocator, .{
                .device = entry.id,
                .source = source,
                .kind = .drag,
                .drag_generation = generation,
            }) catch {
                self.rollbackEnterBatch(batch.items);
                return error.OutOfMemory;
            };
            batch.appendAssumeCapacity(.{ .device = entry.id, .offer = offer });
        }
    }
    // A target switch is one publication transaction. Stage the old target's
    // reset/leave first so its wire order precedes the new target's offer and
    // enter sequence, while still committing both sides atomically.
    if (self.drag.?.target) |old| {
        if (self.drag.?.source) |id| if (self.sources.get(id)) |source| {
            if (source.endpoint.target_preflight) |prepare| prepare(source.endpoint.context, null) catch return self.abortEnter(target.client, batch.items);
            if (source.endpoint.action_preflight) |prepare| prepare(source.endpoint.context, .{}) catch return self.abortEnter(target.client, batch.items);
        };
        devices = self.devices.iterator();
        while (devices.next()) |entry| if (std.meta.eql(entry.value.owner, old.client))
            if (entry.value.endpoint.drag_leave_preflight) |prepare| prepare(entry.value.endpoint.context) catch return self.abortEnter(target.client, batch.items);
    }
    if (self.drag.?.source != null) {
        for (batch.items) |*item| {
            const device = self.devices.get(item.device) orelse unreachable;
            item.preparation = device.endpoint.drag_enter_prepare(device.endpoint.context, target.surface, target.x, target.y, item.offer) catch {
                self.abortEnterPreparations(batch.items);
                if (self.listener.transaction_abort) |abort| abort(self.listener.context);
                self.rollbackEnterBatch(batch.items);
                return error.OutOfMemory;
            };
        }
    } else {
        devices = self.devices.iterator();
        while (devices.next()) |entry| if (std.meta.eql(entry.value.owner, target.client)) {
            _ = entry.value.endpoint.drag_enter_prepare(entry.value.endpoint.context, target.surface, target.x, target.y, null) catch {
                self.abortClientEnterPreparations(target.client);
                if (self.listener.transaction_abort) |abort| abort(self.listener.context);
                return error.OutOfMemory;
            };
        };
    }
    if (self.drag.?.source) |source_id| {
        const source = self.sources.get(source_id) orelse unreachable;
        for (batch.items) |item| if (item.preparation.legacy_copy) {
            const selected = selectAction(source.actions, .{ .copy = true }, .{ .copy = true });
            if (self.listener.offer_action_preflight) |prepare| prepare(self.listener.context, item.offer, selected) catch return self.abortEnter(target.client, batch.items);
            if (source.endpoint.action_preflight) |prepare| prepare(source.endpoint.context, selected) catch return self.abortEnter(target.client, batch.items);
        };
    }
    if (self.listener.transaction_finalize) |finalize| finalize(self.listener.context) catch {
        if (self.listener.transaction_abort) |abort| abort(self.listener.context);
        self.rollbackEnterBatch(batch.items);
        return error.OutOfMemory;
    };
    self.leaveCommitted();
    self.drag.?.target = target;
    if (self.drag.?.source != null) {
        for (batch.items) |item| {
            const offer = self.offers.get(item.offer) orelse unreachable;
            offer.active = true;
            if (item.preparation.legacy_copy) self.commitLegacyOffer(item.offer);
            const device = self.devices.get(item.device) orelse unreachable;
            device.endpoint.drag_enter(device.endpoint.context, target.surface, target.x, target.y, item.offer);
        }
    } else {
        devices = self.devices.iterator();
        while (devices.next()) |entry| if (std.meta.eql(entry.value.owner, target.client)) {
            entry.value.endpoint.drag_enter(entry.value.endpoint.context, target.surface, target.x, target.y, null);
        };
    }
    if (self.listener.transaction_commit) |commit| commit(self.listener.context);
}

fn abortEnter(self: *DataDevice, client: ClientRegistry.Id, batch: anytype) error{OutOfMemory} {
    self.abortClientEnterPreparations(client);
    self.abortTransaction();
    self.rollbackEnterBatch(batch);
    return error.OutOfMemory;
}

fn abortEnterPreparations(self: *DataDevice, batch: anytype) void {
    for (batch) |item| if (self.devices.get(item.device)) |device|
        if (device.endpoint.drag_enter_abort) |abort| abort(device.endpoint.context);
}

fn abortClientEnterPreparations(self: *DataDevice, client: ClientRegistry.Id) void {
    var devices = self.devices.iterator();
    while (devices.next()) |entry| if (std.meta.eql(entry.value.owner, client))
        if (entry.value.endpoint.drag_enter_abort) |abort| abort(entry.value.endpoint.context);
}

fn rollbackEnterBatch(self: *DataDevice, batch: anytype) void {
    for (batch) |item| {
        if (self.listener.offer_rolled_back) |rolled_back| rolled_back(self.listener.context, item.offer);
        _ = self.offers.remove(item.offer);
    }
}

pub fn failEnterStageAllocationAfterForTest(self: *DataDevice, successful_stages: usize) void {
    if (comptime !builtin.is_test) unreachable;
    self.enter_stage_failure = successful_stages;
}

fn failEnterStageAllocationForTest(self: *DataDevice) bool {
    if (comptime !builtin.is_test) return false;
    const remaining = self.enter_stage_failure orelse return false;
    if (remaining != 0) {
        self.enter_stage_failure = remaining - 1;
        return false;
    }
    self.enter_stage_failure = null;
    return true;
}

fn commitLegacyOffer(self: *DataDevice, id: OfferId) void {
    const offer = self.offers.get(id) orelse unreachable;
    const source = self.sources.get(offer.source orelse unreachable) orelse unreachable;
    offer.destination_actions = .{ .copy = true };
    offer.preferred_action = .{ .copy = true };
    // Before wl_data_offer v3, accept is source feedback rather than drop
    // eligibility. The protocol's implicit copy action is sufficient.
    offer.implicit_copy = true;
    offer.accepted = true;
    offer.selected_action = selectAction(source.actions, offer.destination_actions, offer.preferred_action);
    self.notifyOfferAction(id, offer.selected_action);
    source.endpoint.action(source.endpoint.context, offer.selected_action);
}

pub fn motion(self: *DataDevice, time: u32, x: f64, y: f64) void {
    if (self.drag == null or self.drag.?.target == null) return;
    const client = self.drag.?.target.?.client;
    var devices = self.devices.iterator();
    while (devices.next()) |entry| if (std.meta.eql(entry.value.owner, client))
        if (entry.value.endpoint.drag_motion_preflight) |prepare| prepare(entry.value.endpoint.context, time, x, y) catch {
            self.abortTransaction();
            return;
        };
    self.finalizeTransaction() catch {
        self.abortTransaction();
        return;
    };
    self.drag.?.target.?.x = x;
    self.drag.?.target.?.y = y;
    devices = self.devices.iterator();
    while (devices.next()) |entry| if (std.meta.eql(entry.value.owner, client)) entry.value.endpoint.drag_motion(entry.value.endpoint.context, time, x, y);
    self.commitTransaction();
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
        if (source.endpoint.target_preflight) |prepare| prepare(source.endpoint.context, null) catch {
            self.abortTransaction();
            return;
        };
        if (source.endpoint.action_preflight) |prepare| prepare(source.endpoint.context, .{}) catch {
            self.abortTransaction();
            return;
        };
    };
    var devices = self.devices.iterator();
    while (devices.next()) |entry| if (std.meta.eql(entry.value.owner, client))
        if (entry.value.endpoint.drag_leave_preflight) |prepare| prepare(entry.value.endpoint.context) catch {
            self.abortTransaction();
            return;
        };
    self.finalizeTransaction() catch {
        self.abortTransaction();
        return;
    };
    self.leaveCommitted();
    self.commitTransaction();
}

fn leaveCommitted(self: *DataDevice) void {
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

fn finalizeTransaction(self: *DataDevice) error{OutOfMemory}!void {
    if (self.listener.transaction_finalize) |finalize| try finalize(self.listener.context);
}
fn commitTransaction(self: *DataDevice) void {
    if (self.listener.transaction_commit) |commit| commit(self.listener.context);
}
fn abortTransaction(self: *DataDevice) void {
    if (self.listener.transaction_abort) |abort| abort(self.listener.context);
}

pub fn accept(self: *DataDevice, offer_id: OfferId, mime: ?[]const u8) Error!void {
    const offer = self.offers.get(offer_id) orelse return error.InvalidOffer;
    if (offer.kind != .drag or (!offer.active and !offer.dropped)) return error.InvalidOffer;
    const source = self.sources.get(offer.source orelse return error.InvalidSource) orelse return error.InvalidSource;
    const accepted_mime = if (mime) |value| hasMime(source, value) else false;
    if (source.endpoint.target_preflight) |prepare| prepare(source.endpoint.context, if (accepted_mime) mime else null) catch {
        self.abortTransaction();
        return error.OutOfMemory;
    };
    self.finalizeTransaction() catch {
        self.abortTransaction();
        return error.OutOfMemory;
    };
    if (!offer.implicit_copy) offer.accepted = accepted_mime;
    source.endpoint.target(source.endpoint.context, if (accepted_mime) mime else null);
    self.commitTransaction();
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
    const selected = selectAction(source.actions, actions, preferred);
    const changed = @as(u32, @bitCast(selected)) != @as(u32, @bitCast(offer.selected_action));
    if (changed) {
        if (!offer.dropped) if (self.listener.offer_action_preflight) |prepare| prepare(self.listener.context, offer_id, selected) catch {
            self.abortTransaction();
            return error.OutOfMemory;
        };
        if (source.endpoint.action_preflight) |prepare| prepare(source.endpoint.context, selected) catch {
            self.abortTransaction();
            return error.OutOfMemory;
        };
    }
    self.finalizeTransaction() catch {
        self.abortTransaction();
        return error.OutOfMemory;
    };
    offer.destination_actions = actions;
    offer.preferred_action = preferred;
    if (changed) {
        offer.selected_action = selected;
        // Ask may be resolved after drop. At that point only the source gets
        // the final action; the destination must not receive another action.
        if (!offer.dropped) self.notifyOfferAction(offer_id, selected);
        source.endpoint.action(source.endpoint.context, selected);
    }
    self.commitTransaction();
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
    var offers = self.offers.iterator();
    while (offers.next()) |entry| if (entry.value.kind == .drag and entry.value.drag_generation == drag.generation and entry.value.active) {
        accepted = accepted or (entry.value.accepted and !entry.value.selected_action.empty());
    };
    if (drag.source) |id| if (self.sources.get(id)) |source| {
        if (source.endpoint.drop_performed_preflight) |prepare| prepare(source.endpoint.context) catch {
            self.abortTransaction();
            return;
        };
        if (!accepted) if (source.endpoint.cancelled_preflight) |prepare| prepare(source.endpoint.context) catch {
            self.abortTransaction();
            return;
        };
    };
    var devices = self.devices.iterator();
    while (devices.next()) |entry| if (std.meta.eql(entry.value.owner, target.client)) {
        if (accepted) if (entry.value.endpoint.drag_drop_preflight) |prepare| prepare(entry.value.endpoint.context) catch {
            self.abortTransaction();
            return;
        };
        if (entry.value.endpoint.drag_leave_preflight) |prepare| prepare(entry.value.endpoint.context) catch {
            self.abortTransaction();
            return;
        };
    };
    self.finalizeTransaction() catch {
        self.abortTransaction();
        return;
    };
    offers = self.offers.iterator();
    while (offers.next()) |entry| {
        if (entry.value.kind == .drag and entry.value.drag_generation == drag.generation and entry.value.active)
            entry.value.active = false;
    }
    offers = self.offers.iterator();
    while (offers.next()) |entry| {
        if (entry.value.kind == .drag and entry.value.drag_generation == drag.generation)
            entry.value.dropped = accepted;
    }
    if (drag.source) |id| if (self.sources.get(id)) |source| {
        source.endpoint.drop_performed(source.endpoint.context);
        if (!accepted) source.endpoint.cancelled(source.endpoint.context);
        self.endToplevel(id);
    };
    devices = self.devices.iterator();
    while (devices.next()) |entry| if (std.meta.eql(entry.value.owner, target.client)) {
        if (accepted) entry.value.endpoint.drag_drop(entry.value.endpoint.context);
        entry.value.endpoint.drag_leave(entry.value.endpoint.context);
    };
    self.drag = null;
    if (!accepted) invalidateGeneration(self, drag.generation);
    self.commitTransaction();
    self.listener.drag_changed(self.listener.context);
}

pub fn finish(self: *DataDevice, offer_id: OfferId) Error!void {
    const offer = self.offers.get(offer_id) orelse return error.InvalidOffer;
    if (offer.kind != .drag or !offer.dropped or !offer.accepted or offer.selected_action.empty() or offer.selected_action.ask or offer.finished) return error.InvalidFinish;
    const source = self.sources.get(offer.source orelse return error.InvalidFinish) orelse return error.InvalidFinish;
    if (source.endpoint.finished_preflight) |prepare| prepare(source.endpoint.context) catch {
        self.abortTransaction();
        return error.OutOfMemory;
    };
    self.finalizeTransaction() catch {
        self.abortTransaction();
        return error.OutOfMemory;
    };
    offer.finished = true;
    source.endpoint.finished(source.endpoint.context);
    invalidateGeneration(self, offer.drag_generation);
    self.commitTransaction();
}

pub fn destroyOffer(self: *DataDevice, id: OfferId) void {
    self.retireOffer(id, false);
}

/// `legacy_finish` preserves pre-v3 completion when the adapter retires the
/// last dropped offer without an explicit finish request.
pub fn retireOffer(self: *DataDevice, id: OfferId, legacy_finish: bool) void {
    const offer = self.offers.get(id) orelse return;
    if (offer.kind != .drag or !offer.dropped or offer.finished or offer.source == null) {
        _ = self.offers.remove(id);
        return;
    }
    var offers = self.offers.iterator();
    while (offers.next()) |candidate| {
        if (candidate.value.kind == .drag and
            candidate.value.drag_generation == offer.drag_generation and
            candidate.value.dropped and !candidate.value.finished and
            candidate.value.source != null and !std.meta.eql(candidate.id, id))
        {
            _ = self.offers.remove(id);
            return;
        }
    }
    const source = self.sources.get(offer.source.?);
    if (source) |value| {
        if (legacy_finish) {
            if (value.endpoint.finished_preflight) |prepare| prepare(value.endpoint.context) catch {
                self.abortTransaction();
                return;
            };
        } else if (value.endpoint.cancelled_preflight) |prepare| prepare(value.endpoint.context) catch {
            self.abortTransaction();
            return;
        };
    }
    self.finalizeTransaction() catch {
        self.abortTransaction();
        return;
    };
    const removed = self.offers.remove(id) orelse unreachable;
    if (source) |value| if (legacy_finish) {
        value.endpoint.finished(value.endpoint.context);
    } else {
        value.endpoint.cancelled(value.endpoint.context);
    };
    invalidateGeneration(self, removed.drag_generation);
    self.commitTransaction();
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
    if (drag.target) |target| {
        if (drag.source) |id| if (self.sources.get(id)) |source| {
            if (source.endpoint.target_preflight) |prepare| prepare(source.endpoint.context, null) catch {
                self.abortTransaction();
                return;
            };
            if (source.endpoint.action_preflight) |prepare| prepare(source.endpoint.context, .{}) catch {
                self.abortTransaction();
                return;
            };
        };
        var devices = self.devices.iterator();
        while (devices.next()) |entry| if (std.meta.eql(entry.value.owner, target.client))
            if (entry.value.endpoint.drag_leave_preflight) |prepare| prepare(entry.value.endpoint.context) catch {
                self.abortTransaction();
                return;
            };
    }
    if (notify and drag.source != null) if (self.sources.get(drag.source.?)) |source|
        if (source.endpoint.cancelled_preflight) |prepare| prepare(source.endpoint.context) catch {
            self.abortTransaction();
            return;
        };
    self.finalizeTransaction() catch {
        self.abortTransaction();
        return;
    };
    if (drag.source) |id| self.endToplevel(id);
    self.leaveCommitted();
    if (notify and drag.source != null) if (self.sources.get(drag.source.?)) |source| source.endpoint.cancelled(source.endpoint.context);
    invalidateGeneration(self, drag.generation);
    self.drag = null;
    self.commitTransaction();
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
    if (self.sources.get(retained.source)) |source| {
        if (performed) {
            if (source.endpoint.finished_preflight) |prepare| prepare(source.endpoint.context) catch {
                self.abortTransaction();
                return;
            };
        } else if (source.endpoint.cancelled_preflight) |prepare| prepare(source.endpoint.context) catch {
            self.abortTransaction();
            return;
        };
        self.finalizeTransaction() catch {
            self.abortTransaction();
            return;
        };
        if (performed) source.endpoint.finished(source.endpoint.context) else source.endpoint.cancelled(source.endpoint.context);
    }
    self.retained = null;
    self.commitTransaction();
    self.listener.drag_changed(self.listener.context);
}

fn cancelRetained(self: *DataDevice) void {
    if (self.retained) |value| self.finishRetained(value.generation, false);
}
fn invalidateSelectionOffers(self: *DataDevice, preserve_publication: ?u64) void {
    var it = self.offers.iterator();
    while (it.next()) |entry| {
        if (entry.value.kind == .selection and
            (preserve_publication == null or entry.value.publication != preserve_publication.?))
            entry.value.source = null;
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
        fn selection(context: *anyopaque, offer: ?OfferId) error{OutOfMemory}!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.selection_offer = offer;
        }
        fn prepareEnter(_: *anyopaque, _: SurfaceRegistry.Id, _: f64, _: f64, _: ?OfferId) error{OutOfMemory}!DragPreparation {
            return .{};
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
        .drag_enter_prepare = Observer.prepareEnter,
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
        fail_action_preflight: bool = false,

        fn send(_: *anyopaque, _: []const u8, _: std.posix.fd_t) void {}
        fn target(context: *anyopaque, _: ?[]const u8) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.targets += 1;
        }
        fn action(context: *anyopaque, _: Actions) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.actions += 1;
        }
        fn actionPreflight(context: *anyopaque, _: Actions) error{OutOfMemory}!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.fail_action_preflight) return error.OutOfMemory;
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
        fn selection(_: *anyopaque, _: ?OfferId) error{OutOfMemory}!void {}
        fn prepareEnter(_: *anyopaque, _: SurfaceRegistry.Id, _: f64, _: f64, _: ?OfferId) error{OutOfMemory}!DragPreparation {
            return .{};
        }
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
        .action_preflight = Observer.actionPreflight,
        .action = Observer.action,
        .cancelled = Observer.cancelled,
        .drop_performed = Observer.dropped,
        .finished = Observer.finished,
    };
    const device_endpoint: DeviceEndpoint = .{
        .context = &observer,
        .selection = Observer.selection,
        .drag_enter_prepare = Observer.prepareEnter,
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
    observer.fail_action_preflight = true;
    const actions_before_failure = observer.actions;
    try std.testing.expectError(error.OutOfMemory, data_device.setOfferActions(offer, .{ .copy = true, .move = true }, .{ .move = true }));
    try std.testing.expectEqual(Actions{}, data_device.offerInfo(offer).?.selected_action);
    try std.testing.expectEqual(actions_before_failure, observer.actions);
    observer.fail_action_preflight = false;
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
        fn selection(_: *anyopaque, _: ?OfferId) error{OutOfMemory}!void {}
        fn prepareEnter(_: *anyopaque, _: SurfaceRegistry.Id, _: f64, _: f64, _: ?OfferId) error{OutOfMemory}!DragPreparation {
            return .{};
        }
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
        .drag_enter_prepare = Observer.prepareEnter,
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

const RegressionFixture = struct {
    const Provider = struct {
        fn renderState(_: *anyopaque) ?SurfaceRegistry.RenderState {
            return null;
        }
    };
    const Events = struct {
        selection_offer: ?OfferId = null,
        drag_offer: ?OfferId = null,
        sends: usize = 0,
        drops: usize = 0,
        finishes: usize = 0,
        cancellations: usize = 0,
        device_drops: usize = 0,
        drag_changes: usize = 0,
        selections: usize = 0,
        enter_prepares: usize = 0,
        enters: usize = 0,
        actions: usize = 0,
        copy_actions: usize = 0,
        fail_selection: bool = false,
        fail_enter: bool = false,
        legacy_copy: bool = false,

        fn send(context: *anyopaque, _: []const u8, _: std.posix.fd_t) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.sends += 1;
        }
        fn target(_: *anyopaque, _: ?[]const u8) void {}
        fn action(context: *anyopaque, actions: Actions) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.actions += 1;
            if (actions.copy) self.copy_actions += 1;
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
        fn selection(context: *anyopaque, offer: ?OfferId) error{OutOfMemory}!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.fail_selection) return error.OutOfMemory;
            self.selection_offer = offer;
            self.selections += 1;
        }
        fn prepareEnter(context: *anyopaque, _: SurfaceRegistry.Id, _: f64, _: f64, offer: ?OfferId) error{OutOfMemory}!DragPreparation {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.drag_offer = offer;
            self.enter_prepares += 1;
            if (self.fail_enter) return error.OutOfMemory;
            return .{ .legacy_copy = self.legacy_copy };
        }
        fn enter(context: *anyopaque, _: SurfaceRegistry.Id, _: f64, _: f64, offer: ?OfferId) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.drag_offer = offer;
            self.enters += 1;
        }
        fn motion(_: *anyopaque, _: u32, _: f64, _: f64) void {}
        fn ignored(_: *anyopaque) void {}
        fn deviceDrop(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.device_drops += 1;
        }
        fn dragChanged(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.drag_changes += 1;
        }
    };

    fn sourceEndpoint(events: *Events) SourceEndpoint {
        return .{ .context = events, .send = Events.send, .target = Events.target, .action = Events.action, .cancelled = Events.cancelled, .drop_performed = Events.dropped, .finished = Events.finished };
    }
    fn deviceEndpoint(events: *Events) DeviceEndpoint {
        return .{ .context = events, .selection = Events.selection, .drag_enter_prepare = Events.prepareEnter, .drag_enter = Events.enter, .drag_motion = Events.motion, .drag_leave = Events.ignored, .drag_drop = Events.deviceDrop };
    }
};

test "drag enter rolls every prepared device back before retrying the batch" {
    const Rollbacks = struct {
        ids: [4]OfferId = undefined,
        count: usize = 0,

        fn offer(context: *anyopaque, id: OfferId) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.ids[self.count] = id;
            self.count += 1;
        }
    };
    var clients = ClientRegistry.init(std.testing.allocator);
    defer clients.deinit();
    var surfaces = SurfaceRegistry.init(std.testing.allocator);
    defer surfaces.deinit();
    var authority = SeatAuthority.init(std.testing.allocator, &clients, &surfaces);
    defer authority.deinit();
    var rollbacks: Rollbacks = .{};
    var data_device = DataDevice.init(std.testing.allocator, &clients, &surfaces, &authority, .{
        .context = &rollbacks,
        .selection_changed = RegressionFixture.Events.ignored,
        .drag_changed = RegressionFixture.Events.ignored,
        .offer_rolled_back = Rollbacks.offer,
    });
    defer data_device.deinit();
    const source_client = try clients.register(.mature_display);
    const target_client = try clients.register(.mature_display);
    var provider: RegressionFixture.Provider = .{};
    const origin = try surfaces.add(.{ .context = &provider, .render_state = RegressionFixture.Provider.renderState });
    const target_a = try surfaces.add(.{ .context = &provider, .render_state = RegressionFixture.Provider.renderState });
    const target_b = try surfaces.add(.{ .context = &provider, .render_state = RegressionFixture.Provider.renderState });
    const target_c = try surfaces.add(.{ .context = &provider, .render_state = RegressionFixture.Provider.renderState });
    var source_events: RegressionFixture.Events = .{};
    var first: RegressionFixture.Events = .{};
    var second: RegressionFixture.Events = .{};
    const source_device = try data_device.createDevice(source_client, RegressionFixture.deviceEndpoint(&source_events));
    _ = try data_device.createDevice(target_client, RegressionFixture.deviceEndpoint(&first));
    _ = try data_device.createDevice(target_client, RegressionFixture.deviceEndpoint(&second));
    const source = try data_device.createSource(source_client, RegressionFixture.sourceEndpoint(&source_events), .{ .actions = .{ .copy = true }, .actions_declared = true });
    const serial: ClientRegistry.Serial = .{ .domain = .mature_display, .value = 92 };
    try std.testing.expect(try authority.addPointerPress(source_client, serial, 1, origin));
    const generation = try data_device.startDrag(source_device, source, origin, null, serial, true);
    try data_device.enter(.{ .surface = target_a, .client = target_client, .x = 1, .y = 2 });
    try data_device.enter(.{ .surface = target_b, .client = target_client, .x = 3, .y = 4 });
    const baseline = data_device.resourceCounts();
    var old_offers: [4]OfferId = undefined;
    var old_count: usize = 0;
    var offers = data_device.offers.iterator();
    while (offers.next()) |entry| {
        old_offers[old_count] = entry.id;
        old_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), old_count);
    const baseline_actions = source_events.actions;
    const baseline_copy_actions = source_events.copy_actions;
    const baseline_first_prepares = first.enter_prepares;
    const baseline_second_prepares = second.enter_prepares;
    const baseline_first_enters = first.enters;
    const baseline_second_enters = second.enters;
    first.legacy_copy = true;
    second.fail_enter = true;

    data_device.failEnterStageAllocationAfterForTest(1);
    try std.testing.expectError(error.OutOfMemory, data_device.enter(.{ .surface = target_c, .client = target_client, .x = 5, .y = 6 }));
    try std.testing.expectEqual(@as(usize, 1), rollbacks.count);
    try std.testing.expect(data_device.offerInfo(rollbacks.ids[0]) == null);
    try std.testing.expectEqual(baseline, data_device.resourceCounts());
    for (old_offers) |id| try std.testing.expect(data_device.offerInfo(id) != null);
    try std.testing.expectEqual(target_b, data_device.currentTarget().?.surface);
    try std.testing.expectError(error.OutOfMemory, data_device.enter(.{ .surface = target_c, .client = target_client, .x = 5, .y = 6 }));
    try std.testing.expectEqual(baseline_first_prepares + 1, first.enter_prepares);
    try std.testing.expectEqual(baseline_second_prepares + 1, second.enter_prepares);
    try std.testing.expectEqual(baseline_first_enters, first.enters);
    try std.testing.expectEqual(baseline_second_enters, second.enters);
    try std.testing.expectEqual(baseline_actions, source_events.actions);
    try std.testing.expectEqual(baseline_copy_actions, source_events.copy_actions);
    try std.testing.expectEqual(@as(usize, 3), rollbacks.count);
    try std.testing.expect(data_device.offerInfo(rollbacks.ids[1]) == null);
    try std.testing.expect(data_device.offerInfo(rollbacks.ids[2]) == null);
    try std.testing.expectEqual(baseline, data_device.resourceCounts());
    for (old_offers) |id| try std.testing.expect(data_device.offerInfo(id) != null);
    try std.testing.expectEqual(target_b, data_device.currentTarget().?.surface);
    try std.testing.expectEqual(generation, data_device.dragSourceInfo().?.generation);

    second.fail_enter = false;
    try data_device.enter(.{ .surface = target_c, .client = target_client, .x = 7, .y = 8 });
    try std.testing.expectEqual(baseline_first_prepares + 2, first.enter_prepares);
    try std.testing.expectEqual(baseline_second_prepares + 2, second.enter_prepares);
    try std.testing.expectEqual(baseline_first_enters + 1, first.enters);
    try std.testing.expectEqual(baseline_second_enters + 1, second.enters);
    try std.testing.expectEqual(baseline_actions + 2, source_events.actions);
    try std.testing.expectEqual(baseline_copy_actions + 1, source_events.copy_actions);
    try std.testing.expectEqual(@as(usize, 6), data_device.resourceCounts().offers);
    try std.testing.expectEqual(target_c, data_device.currentTarget().?.surface);

    data_device.cancelDrag();
    authority.clearPointerPresses();
    surfaces.remove(target_c);
    surfaces.remove(target_b);
    surfaces.remove(target_a);
    surfaces.remove(origin);
    data_device.clientDisconnected(target_client);
    data_device.clientDisconnected(source_client);
    _ = authority.clientDisconnected(target_client);
    _ = authority.clientDisconnected(source_client);
    clients.unregister(target_client);
    clients.unregister(source_client);
}

test "offers outlive devices until explicit retirement" {
    var clients = ClientRegistry.init(std.testing.allocator);
    defer clients.deinit();
    var surfaces = SurfaceRegistry.init(std.testing.allocator);
    defer surfaces.deinit();
    var authority = SeatAuthority.init(std.testing.allocator, &clients, &surfaces);
    defer authority.deinit();
    var events: RegressionFixture.Events = .{};
    var data_device = DataDevice.init(std.testing.allocator, &clients, &surfaces, &authority, .{ .context = &events, .selection_changed = RegressionFixture.Events.ignored, .drag_changed = RegressionFixture.Events.dragChanged });
    defer data_device.deinit();
    const source_client = try clients.register(.mature_display);
    const target_client = try clients.register(.mature_display);
    var provider: RegressionFixture.Provider = .{};
    const origin = try surfaces.add(.{ .context = &provider, .render_state = RegressionFixture.Provider.renderState });
    const target = try surfaces.add(.{ .context = &provider, .render_state = RegressionFixture.Provider.renderState });
    const source_device = try data_device.createDevice(source_client, RegressionFixture.deviceEndpoint(&events));
    const target_device = try data_device.createDevice(target_client, RegressionFixture.deviceEndpoint(&events));
    const source = try data_device.createSource(source_client, RegressionFixture.sourceEndpoint(&events), .{});
    try data_device.offerMime(source, "text/plain");
    const selection_serial: ClientRegistry.Serial = .{ .domain = .mature_display, .value = 1 };
    try std.testing.expect(authority.recordSelection(source_client, selection_serial));
    try data_device.setFocus(source_client);
    try data_device.setSelection(source_device, source, selection_serial);
    const selection_offer = events.selection_offer.?;
    data_device.destroyDevice(source_device);
    try data_device.receive(selection_offer, "text/plain", -1);
    try std.testing.expectEqual(@as(usize, 1), events.sends);

    const drag_source = try data_device.createSource(source_client, RegressionFixture.sourceEndpoint(&events), .{ .actions = .{ .copy = true }, .actions_declared = true });
    try data_device.offerMime(drag_source, "text/plain");
    const drag_source_device = try data_device.createDevice(source_client, RegressionFixture.deviceEndpoint(&events));
    const drag_serial: ClientRegistry.Serial = .{ .domain = .mature_display, .value = 2 };
    try std.testing.expect(try authority.addPointerPress(source_client, drag_serial, 1, origin));
    _ = try data_device.startDrag(drag_source_device, drag_source, origin, null, drag_serial, true);
    try data_device.enter(.{ .surface = target, .client = target_client, .x = 0, .y = 0 });
    const drag_offer = events.drag_offer.?;
    try data_device.accept(drag_offer, "text/plain");
    try data_device.setOfferActions(drag_offer, .{ .copy = true }, .{ .copy = true });
    data_device.drop();
    data_device.destroyDevice(target_device);
    try data_device.finish(drag_offer);
    try std.testing.expectEqual(@as(usize, 1), events.finishes);
    try std.testing.expectError(error.InvalidFinish, data_device.finish(drag_offer));
    data_device.retireOffer(drag_offer, false);
    data_device.retireOffer(drag_offer, false);
    try std.testing.expect(data_device.offerInfo(drag_offer) == null);
    authority.clearPointerPresses();
    authority.discardGrants();
    surfaces.remove(target);
    surfaces.remove(origin);
    data_device.clientDisconnected(target_client);
    data_device.clientDisconnected(source_client);
    _ = authority.clientDisconnected(target_client);
    _ = authority.clientDisconnected(source_client);
    clients.unregister(target_client);
    clients.unregister(source_client);
}

test "surface destruction distinguishes drag origin and icon" {
    var clients = ClientRegistry.init(std.testing.allocator);
    defer clients.deinit();
    var surfaces = SurfaceRegistry.init(std.testing.allocator);
    defer surfaces.deinit();
    var authority = SeatAuthority.init(std.testing.allocator, &clients, &surfaces);
    defer authority.deinit();
    var events: RegressionFixture.Events = .{};
    var data_device = DataDevice.init(std.testing.allocator, &clients, &surfaces, &authority, .{ .context = &events, .selection_changed = RegressionFixture.Events.ignored, .drag_changed = RegressionFixture.Events.dragChanged });
    defer data_device.deinit();
    const source_client = try clients.register(.mature_display);
    const target_client = try clients.register(.mature_display);
    var provider: RegressionFixture.Provider = .{};
    const origin = try surfaces.add(.{ .context = &provider, .render_state = RegressionFixture.Provider.renderState });
    const target = try surfaces.add(.{ .context = &provider, .render_state = RegressionFixture.Provider.renderState });
    const icon = try surfaces.add(.{ .context = &provider, .render_state = RegressionFixture.Provider.renderState });
    const source_device = try data_device.createDevice(source_client, RegressionFixture.deviceEndpoint(&events));
    _ = try data_device.createDevice(target_client, RegressionFixture.deviceEndpoint(&events));
    const source = try data_device.createSource(source_client, RegressionFixture.sourceEndpoint(&events), .{ .actions = .{ .copy = true }, .actions_declared = true });
    try data_device.offerMime(source, "text/plain");
    const serial: ClientRegistry.Serial = .{ .domain = .mature_display, .value = 3 };
    try std.testing.expect(try authority.addPointerPress(source_client, serial, 1, origin));
    _ = try data_device.startDrag(source_device, source, origin, .{ .surface = icon }, serial, true);
    data_device.surfaceDestroyed(icon);
    try std.testing.expect(data_device.isDragging());
    try std.testing.expect(data_device.dragIcon() == null);
    try data_device.enter(.{ .surface = target, .client = target_client, .x = 0, .y = 0 });
    const offer = events.drag_offer.?;
    try data_device.accept(offer, "text/plain");
    try data_device.setOfferActions(offer, .{ .copy = true }, .{ .copy = true });
    data_device.drop();
    try data_device.finish(offer);
    try std.testing.expectEqual(@as(usize, 1), events.finishes);

    const source2 = try data_device.createSource(source_client, RegressionFixture.sourceEndpoint(&events), .{ .actions = .{ .copy = true }, .actions_declared = true });
    const serial2: ClientRegistry.Serial = .{ .domain = .mature_display, .value = 4 };
    try std.testing.expect(try authority.addPointerPress(source_client, serial2, 1, origin));
    _ = try data_device.startDrag(source_device, source2, origin, null, serial2, true);
    try data_device.enter(.{ .surface = target, .client = target_client, .x = 0, .y = 0 });
    data_device.surfaceDestroyed(origin);
    try std.testing.expect(!data_device.isDragging());
    try std.testing.expect(data_device.currentTarget() == null);
    try std.testing.expect(data_device.dragIcon() == null);
    const drops = events.device_drops;
    data_device.drop();
    try std.testing.expectEqual(drops, events.device_drops);

    const source3 = try data_device.createSource(source_client, RegressionFixture.sourceEndpoint(&events), .{ .actions = .{ .copy = true }, .actions_declared = true });
    const serial3: ClientRegistry.Serial = .{ .domain = .mature_display, .value = 5 };
    try std.testing.expect(try authority.addPointerPress(source_client, serial3, 1, origin));
    _ = try data_device.startDrag(source_device, source3, origin, null, serial3, true);
    const cancellations = events.cancellations;
    data_device.surfaceDestroyed(origin);
    try std.testing.expect(!data_device.isDragging());
    try std.testing.expectEqual(cancellations + 1, events.cancellations);
    data_device.drop();
    try std.testing.expectEqual(drops, events.device_drops);
    authority.clearPointerPresses();
    surfaces.remove(icon);
    surfaces.remove(target);
    surfaces.remove(origin);
    data_device.clientDisconnected(target_client);
    data_device.clientDisconnected(source_client);
    clients.unregister(target_client);
    clients.unregister(source_client);
}

test "validateDragStart is side effect free for rejected and valid starts" {
    var clients = ClientRegistry.init(std.testing.allocator);
    defer clients.deinit();
    var surfaces = SurfaceRegistry.init(std.testing.allocator);
    defer surfaces.deinit();
    var authority = SeatAuthority.init(std.testing.allocator, &clients, &surfaces);
    defer authority.deinit();
    var events: RegressionFixture.Events = .{};
    var data_device = DataDevice.init(std.testing.allocator, &clients, &surfaces, &authority, .{ .context = &events, .selection_changed = RegressionFixture.Events.ignored, .drag_changed = RegressionFixture.Events.dragChanged });
    defer data_device.deinit();
    const client = try clients.register(.mature_display);
    const other = try clients.register(.mature_display);
    var provider: RegressionFixture.Provider = .{};
    const origin = try surfaces.add(.{ .context = &provider, .render_state = RegressionFixture.Provider.renderState });
    const device = try data_device.createDevice(client, RegressionFixture.deviceEndpoint(&events));
    const source = try data_device.createSource(client, RegressionFixture.sourceEndpoint(&events), .{ .actions = .{ .copy = true }, .actions_declared = true });
    const wrong_source = try data_device.createSource(other, RegressionFixture.sourceEndpoint(&events), .{ .actions = .{ .copy = true }, .actions_declared = true });
    const stale: ClientRegistry.Serial = .{ .domain = .mature_display, .value = 5 };
    try std.testing.expectError(error.Unauthorized, data_device.validateDragStart(device, source, origin, null, stale, true));
    try std.testing.expect(!data_device.sources.get(source).?.used and !data_device.isDragging());
    try std.testing.expect(try authority.addPointerPress(client, stale, 1, origin));
    try std.testing.expectError(error.WrongClient, data_device.validateDragStart(device, wrong_source, origin, null, stale, true));
    try data_device.validateDragStart(device, source, origin, null, stale, true);
    try std.testing.expect(!data_device.sources.get(source).?.used and !data_device.isDragging());
    _ = try data_device.startDrag(device, source, origin, null, stale, true);
    try std.testing.expectError(error.DragActive, data_device.validateDragStart(device, wrong_source, origin, null, stale, true));
    try std.testing.expect(data_device.sources.get(source).?.used and data_device.isDragging());
    authority.clearPointerPresses();
    surfaces.remove(origin);
    data_device.clientDisconnected(other);
    data_device.clientDisconnected(client);
    clients.unregister(other);
    clients.unregister(client);
}

test "device publication failure rolls IDs offers and selection back" {
    var clients = ClientRegistry.init(std.testing.allocator);
    defer clients.deinit();
    var surfaces = SurfaceRegistry.init(std.testing.allocator);
    defer surfaces.deinit();
    var authority = SeatAuthority.init(std.testing.allocator, &clients, &surfaces);
    defer authority.deinit();
    var events: RegressionFixture.Events = .{};
    var data_device = DataDevice.init(std.testing.allocator, &clients, &surfaces, &authority, .{ .context = &events, .selection_changed = RegressionFixture.Events.ignored, .drag_changed = RegressionFixture.Events.dragChanged });
    defer data_device.deinit();
    const source_client = try clients.register(.mature_display);
    const target_client = try clients.register(.mature_display);
    const source = try data_device.createSource(source_client, RegressionFixture.sourceEndpoint(&events), .{});
    try data_device.offerMime(source, "text/plain");
    try data_device.setExternalSelection(source);
    try data_device.setFocus(target_client);
    const selection_baseline = data_device.resourceCounts();
    const generation_baseline = data_device.selectionGeneration();
    events.fail_selection = true;
    try std.testing.expectError(error.OutOfMemory, data_device.createDevice(target_client, RegressionFixture.deviceEndpoint(&events)));
    try std.testing.expectEqual(selection_baseline, data_device.resourceCounts());
    try std.testing.expectEqual(generation_baseline, data_device.selectionGeneration());
    try std.testing.expect(data_device.selectionIs(source));
    events.fail_selection = false;
    const target_device = try data_device.createDevice(target_client, RegressionFixture.deviceEndpoint(&events));
    const replacement = try data_device.createSource(target_client, RegressionFixture.sourceEndpoint(&events), .{});
    const replacement_serial: ClientRegistry.Serial = .{ .domain = .mature_display, .value = 90 };
    try std.testing.expect(authority.recordSelection(target_client, replacement_serial));
    const replacement_baseline = data_device.resourceCounts();
    events.fail_selection = true;
    try std.testing.expectError(error.OutOfMemory, data_device.setSelection(target_device, replacement, replacement_serial));
    try std.testing.expectEqual(replacement_baseline, data_device.resourceCounts());
    try std.testing.expectEqual(generation_baseline, data_device.selectionGeneration());
    try std.testing.expect(data_device.selectionIs(source));
    try std.testing.expect(!data_device.sources.get(replacement).?.used);
    events.fail_selection = false;
    data_device.destroyDevice(target_device);

    var provider: RegressionFixture.Provider = .{};
    const origin = try surfaces.add(.{ .context = &provider, .render_state = RegressionFixture.Provider.renderState });
    const target = try surfaces.add(.{ .context = &provider, .render_state = RegressionFixture.Provider.renderState });
    const source_device = try data_device.createDevice(source_client, RegressionFixture.deviceEndpoint(&events));
    const drag_source = try data_device.createSource(source_client, RegressionFixture.sourceEndpoint(&events), .{ .actions = .{ .copy = true }, .actions_declared = true });
    const serial: ClientRegistry.Serial = .{ .domain = .mature_display, .value = 91 };
    try std.testing.expect(try authority.addPointerPress(source_client, serial, 1, origin));
    _ = try data_device.startDrag(source_device, drag_source, origin, null, serial, true);
    try data_device.enter(.{ .surface = target, .client = target_client, .x = 1, .y = 2 });
    const drag_baseline = data_device.resourceCounts();
    events.fail_enter = true;
    try std.testing.expectError(error.OutOfMemory, data_device.createDevice(target_client, RegressionFixture.deviceEndpoint(&events)));
    try std.testing.expectEqual(drag_baseline, data_device.resourceCounts());
    try std.testing.expect(data_device.isDragging());
    try std.testing.expect(data_device.currentTarget() != null);
    events.fail_enter = false;

    data_device.cancelDrag();
    authority.clearPointerPresses();
    surfaces.remove(target);
    surfaces.remove(origin);
    data_device.clientDisconnected(target_client);
    data_device.clientDisconnected(source_client);
    _ = authority.clientDisconnected(target_client);
    _ = authority.clientDisconnected(source_client);
    clients.unregister(target_client);
    clients.unregister(source_client);
}

test "device ID registration allocation failure leaves no canonical state" {
    const Endpoint = struct {
        fn selection(_: *anyopaque, _: ?OfferId) error{OutOfMemory}!void {}
        fn prepareEnter(_: *anyopaque, _: SurfaceRegistry.Id, _: f64, _: f64, _: ?OfferId) error{OutOfMemory}!DragPreparation {
            return .{};
        }
        fn enter(_: *anyopaque, _: SurfaceRegistry.Id, _: f64, _: f64, _: ?OfferId) void {}
        fn motion(_: *anyopaque, _: u32, _: f64, _: f64) void {}
        fn notify(_: *anyopaque) void {}
        fn changed(_: *anyopaque) void {}
    };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var clients = ClientRegistry.init(std.testing.allocator);
    defer clients.deinit();
    var surfaces = SurfaceRegistry.init(std.testing.allocator);
    defer surfaces.deinit();
    var authority = SeatAuthority.init(std.testing.allocator, &clients, &surfaces);
    defer authority.deinit();
    var context: u8 = 0;
    var data_device = DataDevice.init(failing.allocator(), &clients, &surfaces, &authority, .{ .context = &context, .selection_changed = Endpoint.changed, .drag_changed = Endpoint.changed });
    defer data_device.deinit();
    const client = try clients.register(.mature_display);
    defer clients.unregister(client);
    try std.testing.expectError(error.OutOfMemory, data_device.createDevice(client, .{
        .context = &context,
        .selection = Endpoint.selection,
        .drag_enter_prepare = Endpoint.prepareEnter,
        .drag_enter = Endpoint.enter,
        .drag_motion = Endpoint.motion,
        .drag_leave = Endpoint.notify,
        .drag_drop = Endpoint.notify,
    }));
    try std.testing.expectEqual(ResourceCounts{ .sources = 0, .devices = 0, .offers = 0 }, data_device.resourceCounts());
}
