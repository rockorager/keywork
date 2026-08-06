//! libwayland adapter for the protocol-neutral seat data device.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const NeutralDataDevice = @import("../DataDevice.zig");
const ClientRegistry = @import("../ClientRegistry.zig");
const SurfaceRegistry = @import("../SurfaceRegistry.zig");
const Seat = @import("seat.zig");
const Surface = @import("surface.zig");
const MatureSerials = @import("mature_serials.zig");

const wl = wayland.server.wl;

pub const SourceId = NeutralDataDevice.SourceId;
pub const DeviceId = NeutralDataDevice.DeviceId;
pub const OfferId = NeutralDataDevice.OfferId;

allocator: std.mem.Allocator,
display: *wl.Server,
global: *wl.Global,
seat: *Seat,
surface_store: *Surface.Store,
listener: Listener,
owner: *NeutralDataDevice,
sources: std.AutoHashMapUnmanaged(SourceId, *SourceResource) = .empty,
devices: std.AutoHashMapUnmanaged(DeviceId, *DeviceResource) = .empty,
offers: std.AutoHashMapUnmanaged(OfferId, *OfferResource) = .empty,
drag_icon: ?*DragIcon = null,
drag_origin: ?*DragOrigin = null,
drag_was_active: bool = false,
enter_serial: u32 = 0,

pub const Listener = struct {
    context: *anyopaque,
    started: *const fn (*anyopaque) void,
    ended: *const fn (*anyopaque) void,
    external_source_destroyed: *const fn (*anyopaque, u64) void,
    repaint: *const fn (*anyopaque) void,
};

pub const ToplevelDragHandler = NeutralDataDevice.ToplevelDragHandler;

pub const IconInfo = struct { surface_id: Surface.Id, x: i32, y: i32 };

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
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    seat: *Seat,
    surface_store: *Surface.Store,
    owner: *NeutralDataDevice,
    listener: Listener,
) !void {
    self.* = .{
        .allocator = allocator,
        .display = display,
        .global = undefined,
        .seat = seat,
        .surface_store = surface_store,
        .listener = listener,
        .owner = owner,
    };
    self.global = try wl.Global.create(display, wl.DataDeviceManager, 4, *Self, self, bind);
    errdefer self.global.destroy();
    try seat.addKeyboardFocusListener(.{ .context = self, .changed = keyboardFocusChanged });
}

pub fn deinit(self: *Self) void {
    self.seat.removeKeyboardFocusListener(self);
    self.global.destroy();
    self.clearDragOrigin();
    self.clearDragIcon();
    std.debug.assert(self.sources.count() == 0);
    std.debug.assert(self.devices.count() == 0);
    std.debug.assert(self.offers.count() == 0);
    self.sources.deinit(self.allocator);
    self.devices.deinit(self.allocator);
    self.offers.deinit(self.allocator);
    self.* = undefined;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = wl.DataDeviceManager.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, managerRequest, null, self);
}

fn managerRequest(resource: *wl.DataDeviceManager, request: wl.DataDeviceManager.Request, self: *Self) void {
    switch (request) {
        .release => resource.destroy(),
        .create_data_source => |create| SourceResource.create(self, resource.getClient(), resource.getVersion(), create.id) catch resource.postNoMemory(),
        .get_data_device => |get| {
            if (!self.seat.ownsResource(get.seat)) {
                createInertDevice(resource.getClient(), resource.getVersion(), get.id) catch resource.postNoMemory();
                return;
            }
            DeviceResource.create(self, resource.getClient(), resource.getVersion(), get.id) catch |err| switch (err) {
                error.NoMemoryPosted => {},
                else => resource.postNoMemory(),
            };
        },
    }
}

fn createInertDevice(client: *wl.Client, version: u32, id: u32) !void {
    const resource = try wl.DataDevice.create(client, version, id);
    resource.setHandler(?*anyopaque, inertDeviceRequest, null, null);
}

fn inertDeviceRequest(resource: *wl.DataDevice, request: wl.DataDevice.Request, _: ?*anyopaque) void {
    switch (request) {
        .release => resource.destroy(),
        .start_drag, .set_selection => {},
    }
}

const SourceResource = struct {
    manager: *Self,
    resource: *wl.DataSource,
    id: SourceId = undefined,

    fn create(manager: *Self, client: *wl.Client, version: u32, protocol_id: u32) !void {
        const resource = try wl.DataSource.create(client, version, protocol_id);
        errdefer resource.destroy();
        const self = manager.allocator.create(SourceResource) catch return error.OutOfMemory;
        errdefer manager.allocator.destroy(self);
        self.* = .{ .manager = manager, .resource = resource };
        const owner_id = manager.seat.matureClientId(client) orelse return error.OutOfMemory;
        self.id = try manager.owner.createSource(owner_id, .{
            .context = self,
            .send = sourceSend,
            .target = sourceTarget,
            .action = sourceAction,
            .cancelled = sourceCancelled,
            .selection_cancelled = sourceSelectionCancelled,
            .drop_performed = sourceDropPerformed,
            .finished = sourceFinished,
        }, .{ .actions = if (version < 3) .{ .copy = true } else .{} });
        errdefer manager.owner.destroySource(self.id);
        try manager.sources.put(manager.allocator, self.id, self);
        resource.setHandler(*SourceResource, request, destroyed, self);
    }

    fn request(resource: *wl.DataSource, value: wl.DataSource.Request, self: *SourceResource) void {
        switch (value) {
            .destroy => resource.destroy(),
            .offer => |offer| self.manager.owner.offerMime(self.id, std.mem.span(offer.mime_type)) catch |err| switch (err) {
                error.OutOfMemory => resource.postNoMemory(),
                else => {},
            },
            .set_actions => |set| self.manager.owner.setSourceActions(self.id, fromWireActions(set.dnd_actions)) catch |err| switch (err) {
                error.InvalidActionMask => resource.postError(.invalid_action_mask, "invalid drag-and-drop action mask"),
                error.ActionsAlreadySet, error.SourceAlreadyUsed => resource.postError(.invalid_source, "data source is already in use or actions were already set"),
                else => {},
            },
        }
    }

    fn destroyed(_: *wl.DataSource, self: *SourceResource) void {
        _ = self.manager.sources.remove(self.id);
        self.manager.owner.destroySource(self.id);
        self.manager.allocator.destroy(self);
    }
};

const DeviceResource = struct {
    manager: *Self,
    resource: *wl.DataDevice,
    id: DeviceId = undefined,

    fn create(manager: *Self, client: *wl.Client, version: u32, protocol_id: u32) !void {
        const resource = try wl.DataDevice.create(client, version, protocol_id);
        errdefer resource.destroy();
        const self = manager.allocator.create(DeviceResource) catch return error.OutOfMemory;
        errdefer manager.allocator.destroy(self);
        self.* = .{ .manager = manager, .resource = resource };
        const client_id = manager.seat.matureClientId(client) orelse return error.OutOfMemory;
        self.id = manager.owner.createDevice(client_id, .{
            .context = self,
            .selection = deviceSelection,
            .drag_enter = deviceEnter,
            .drag_motion = deviceMotion,
            .drag_leave = deviceLeave,
            .drag_drop = deviceDrop,
        }) catch {
            resource.postNoMemory();
            return error.NoMemoryPosted;
        };
        errdefer manager.rollbackDeviceCreation(self.id);
        try manager.devices.put(manager.allocator, self.id, self);
        resource.setHandler(*DeviceResource, request, destroyed, self);
    }

    fn request(resource: *wl.DataDevice, value: wl.DataDevice.Request, self: *DeviceResource) void {
        switch (value) {
            .release => resource.destroy(),
            .set_selection => |set| self.setSelection(set.source, set.serial),
            .start_drag => |start| self.startDrag(start.source, start.origin, start.icon, start.serial),
        }
    }

    fn setSelection(self: *DeviceResource, source_resource: ?*wl.DataSource, serial: u32) void {
        const source_id = self.manager.sourceId(source_resource) orelse if (source_resource != null) return else null;
        self.manager.owner.setSelection(self.id, source_id, matureSerial(serial)) catch |err| switch (err) {
            error.OutOfMemory => self.resource.postNoMemory(),
            error.SourceAlreadyUsed => self.resource.postError(.used_source, "data source was already used"),
            error.InvalidSource => if (source_resource) |source| source.postError(.invalid_source, "drag-and-drop source used for selection"),
            else => {},
        };
    }

    fn startDrag(self: *DeviceResource, source_resource: ?*wl.DataSource, origin_resource: *wl.Surface, icon_resource: ?*wl.Surface, serial: u32) void {
        const manager = self.manager;
        if (origin_resource.getClient() != self.resource.getClient()) return;
        const source_id = manager.sourceId(source_resource) orelse if (source_resource != null) return else null;
        const origin_surface = Surface.fromResource(origin_resource);
        const origin = origin_surface.handle();
        const icon_surface = if (icon_resource) |wire_icon| blk: {
            if (wire_icon.getClient() != self.resource.getClient()) return;
            break :blk Surface.fromResource(wire_icon);
        } else null;
        const icon: ?NeutralDataDevice.DragIcon = if (icon_surface) |surface| .{ .surface = surface.handle() } else null;
        manager.owner.validateDragStart(
            self.id,
            source_id,
            origin,
            icon,
            matureSerial(serial),
            source_resource != null and source_resource.?.getVersion() >= 3,
        ) catch |err| {
            self.handleStartError(source_resource, err);
            return;
        };
        var adapter_icon: ?*DragIcon = null;
        if (icon_surface) |surface| {
            adapter_icon = DragIcon.create(manager, surface) catch |err| {
                if (err == error.OutOfMemory) self.resource.postNoMemory() else self.resource.postError(.role, "drag icon surface already has another role");
                return;
            };
        }
        const adapter_origin = DragOrigin.create(manager, origin_surface) catch {
            if (adapter_icon) |value| value.destroy();
            self.resource.postNoMemory();
            return;
        };
        manager.drag_icon = adapter_icon;
        manager.drag_origin = adapter_origin;
        manager.seat.setDragCursorController(self.resource.getClient());
        _ = manager.owner.startDrag(self.id, source_id, origin, icon, matureSerial(serial), source_resource != null and source_resource.?.getVersion() >= 3) catch |err| {
            manager.drag_icon = null;
            manager.drag_origin = null;
            manager.seat.setDragCursorController(null);
            adapter_origin.destroy();
            if (adapter_icon) |value| value.destroy();
            self.handleStartError(source_resource, err);
            return;
        };
    }

    fn handleStartError(self: *DeviceResource, source_resource: ?*wl.DataSource, err: NeutralDataDevice.Error) void {
        switch (err) {
            error.MissingActions, error.InvalidSource => if (source_resource) |source| source.postError(.invalid_source, "drag-and-drop actions were not set"),
            error.SourceAlreadyUsed => self.resource.postError(.used_source, "data source was already used"),
            else => {},
        }
    }

    fn destroyed(_: *wl.DataDevice, self: *DeviceResource) void {
        self.manager.detachOffersFromDevice(self);
        _ = self.manager.devices.remove(self.id);
        self.manager.owner.destroyDevice(self.id);
        self.manager.allocator.destroy(self);
    }
};

const OfferResource = struct {
    manager: *Self,
    resource: *wl.DataOffer,
    id: OfferId,
    device: ?*DeviceResource,
    enter_serial: u32,

    fn materialize(manager: *Self, id: OfferId, device: *DeviceResource) !*OfferResource {
        if (manager.offers.get(id)) |existing| return existing;
        var info = manager.owner.offerInfo(id) orelse return error.InvalidOffer;
        if (info.kind == .drag and device.resource.getVersion() < 3) {
            try manager.owner.setOfferActions(id, .{ .copy = true }, .{ .copy = true });
            info = manager.owner.offerInfo(id) orelse return error.InvalidOffer;
        }
        const mime_types = if (info.source) |source| try manager.owner.sourceMimeTypes(source) else &.{};
        const source_actions: NeutralDataDevice.Actions = if (info.source) |source| try manager.owner.sourceActions(source) else .{};
        const resource = try wl.DataOffer.create(device.resource.getClient(), device.resource.getVersion(), 0);
        errdefer resource.destroy();
        const self = manager.allocator.create(OfferResource) catch return error.OutOfMemory;
        errdefer manager.allocator.destroy(self);
        self.* = .{ .manager = manager, .resource = resource, .id = id, .device = device, .enter_serial = manager.enter_serial };
        try manager.offers.put(manager.allocator, id, self);
        resource.setHandler(*OfferResource, request, destroyed, self);
        device.resource.sendDataOffer(resource);
        if (info.source != null) {
            for (mime_types) |mime| resource.sendOffer(@ptrCast(mime.ptr));
            if (resource.getVersion() >= 3 and info.kind == .drag) {
                resource.sendSourceActions(toWireActions(source_actions));
                resource.sendAction(toWireActions(info.selected_action));
            }
        }
        return self;
    }

    fn request(resource: *wl.DataOffer, value: wl.DataOffer.Request, self: *OfferResource) void {
        var receive_fd: ?std.posix.fd_t = null;
        defer if (receive_fd) |fd| (std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } }).close(self.manager.seat.io);
        if (value == .receive) receive_fd = value.receive.fd;
        const info = self.manager.owner.offerInfo(self.id);
        if (info != null and info.?.finished) switch (value) {
            .destroy => {},
            else => {
                resource.postError(.invalid_finish, "drag-and-drop offer was already finished");
                return;
            },
        };
        switch (value) {
            .destroy => resource.destroy(),
            .accept => |accept| {
                if (info) |offer| if (offer.active and accept.serial != self.enter_serial) return;
                self.manager.owner.accept(self.id, if (accept.mime_type) |mime| std.mem.span(mime) else null) catch {};
            },
            .receive => |receive| {
                self.manager.owner.receive(self.id, std.mem.span(receive.mime_type), receive.fd) catch {};
            },
            .set_actions => |set| self.manager.owner.setOfferActions(self.id, fromWireActions(set.dnd_actions), fromWireActions(set.preferred_action)) catch |err| switch (err) {
                error.InvalidActionMask => resource.postError(.invalid_action_mask, "invalid drag-and-drop action mask"),
                error.InvalidPreferredAction => resource.postError(.invalid_action, "invalid preferred drag-and-drop action"),
                error.InvalidOffer => resource.postError(.invalid_offer, "actions are invalid for this offer"),
                else => {},
            },
            .finish => self.manager.owner.finish(self.id) catch resource.postError(.invalid_finish, "drag-and-drop offer cannot be finished"),
        }
    }

    fn destroyed(_: *wl.DataOffer, self: *OfferResource) void {
        _ = self.manager.offers.remove(self.id);
        self.manager.owner.retireOffer(self.id, self.resource.getVersion() < 3);
        self.manager.allocator.destroy(self);
    }
};

fn deviceSelection(context: *anyopaque, offer_id: ?OfferId) error{OutOfMemory}!void {
    const device: *DeviceResource = @ptrCast(@alignCast(context));
    const offer_id_value = offer_id orelse {
        device.resource.sendSelection(null);
        return;
    };
    const offer = OfferResource.materialize(device.manager, offer_id_value, device) catch return error.OutOfMemory;
    device.resource.sendSelection(offer.resource);
}

fn deviceEnter(context: *anyopaque, surface_id: SurfaceRegistry.Id, x: f64, y: f64, offer_id: ?OfferId) error{OutOfMemory}!void {
    const device: *DeviceResource = @ptrCast(@alignCast(context));
    const surface = Surface.resourceFor(device.manager.surface_store, surface_id) orelse return;
    const offer = if (offer_id) |id| OfferResource.materialize(device.manager, id, device) catch {
        device.manager.rollbackEndpointMaterialization(device);
        return error.OutOfMemory;
    } else null;
    device.resource.sendEnter(device.manager.enter_serial, surface, fixed(x), fixed(y), if (offer) |value| value.resource else null);
}

fn deviceMotion(context: *anyopaque, time: u32, x: f64, y: f64) void {
    const device: *DeviceResource = @ptrCast(@alignCast(context));
    device.resource.sendMotion(time, fixed(x), fixed(y));
}
fn deviceLeave(context: *anyopaque) void {
    const device: *DeviceResource = @ptrCast(@alignCast(context));
    device.resource.sendLeave();
}
fn deviceDrop(context: *anyopaque) void {
    const device: *DeviceResource = @ptrCast(@alignCast(context));
    device.resource.sendDrop();
}

fn sourceSend(context: *anyopaque, mime: []const u8, fd: std.posix.fd_t) void {
    const source: *SourceResource = @ptrCast(@alignCast(context));
    source.resource.sendSend(@ptrCast(mime.ptr), fd);
}
fn sourceTarget(context: *anyopaque, mime: ?[]const u8) void {
    const source: *SourceResource = @ptrCast(@alignCast(context));
    if (mime) |value| source.resource.sendTarget(@ptrCast(value.ptr)) else source.resource.sendTarget(null);
}
fn sourceAction(context: *anyopaque, actions: NeutralDataDevice.Actions) void {
    const source: *SourceResource = @ptrCast(@alignCast(context));
    if (source.resource.getVersion() >= 3) source.resource.sendAction(toWireActions(actions));
}
fn sourceCancelled(context: *anyopaque) void {
    const source: *SourceResource = @ptrCast(@alignCast(context));
    if (source.resource.getVersion() >= 3) source.resource.sendCancelled();
}
fn sourceSelectionCancelled(context: *anyopaque) void {
    const source: *SourceResource = @ptrCast(@alignCast(context));
    source.resource.sendCancelled();
}
fn sourceDropPerformed(context: *anyopaque) void {
    const source: *SourceResource = @ptrCast(@alignCast(context));
    if (source.resource.getVersion() >= 3) source.resource.sendDndDropPerformed();
}
fn sourceFinished(context: *anyopaque) void {
    const source: *SourceResource = @ptrCast(@alignCast(context));
    if (source.resource.getVersion() >= 3) source.resource.sendDndFinished();
}

fn keyboardFocusChanged(context: *anyopaque, client: ?*wl.Client) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.owner.setFocus(if (client) |value| self.seat.matureClientId(value) else null) catch |err| switch (err) {
        error.OutOfMemory => if (client) |value| value.postNoMemory(),
        else => {},
    };
}
pub fn neutralDragChanged(self: *Self) void {
    const active = self.owner.isDragging();
    if (active and !self.drag_was_active) self.listener.started(self.listener.context);
    if (!active and self.drag_was_active) {
        self.clearDragOrigin();
        self.clearDragIcon();
        self.seat.setDragCursorController(null);
        self.listener.ended(self.listener.context);
    }
    self.drag_was_active = active;
    self.listener.repaint(self.listener.context);
}

pub fn pointerEntered(self: *Self, focus: ?Seat.PointerFocus) void {
    self.updateTarget(focus);
}
pub fn pointerMotion(self: *Self, time: u32, focus: ?Seat.PointerFocus) void {
    self.updateTarget(focus);
    if (focus) |value| self.owner.motion(time, value.x, value.y);
}
pub fn pointerLeft(self: *Self) void {
    self.owner.leave();
}
fn updateTarget(self: *Self, focus: ?Seat.PointerFocus) void {
    const target = focus orelse {
        self.owner.leave();
        return;
    };
    const client = self.seat.matureSurfaceOwner(target.surface_id) orelse {
        self.owner.leave();
        return;
    };
    if (self.owner.currentTarget()) |current| if (std.meta.eql(current.surface, target.surface_id) and
        std.meta.eql(current.client, client))
    {
        self.owner.updateTargetCoordinates(target.x, target.y);
        return;
    };
    self.enter_serial = MatureSerials.issueWire(self.display);
    self.owner.enter(.{ .surface = target.surface_id, .client = client, .x = target.x, .y = target.y }) catch |err| switch (err) {
        error.OutOfMemory => if (Surface.resourceFor(self.surface_store, target.surface_id)) |surface| surface.getClient().postNoMemory(),
        else => {},
    };
}

pub fn neutralOfferMime(self: *Self, id: OfferId, mime: []const u8) void {
    const offer = self.offers.get(id) orelse return;
    offer.resource.sendOffer(@ptrCast(mime.ptr));
}
pub fn neutralOfferRolledBack(self: *Self, id: OfferId) void {
    const offer = self.offers.get(id) orelse return;
    offer.resource.destroy();
}
pub fn neutralOfferSourceActions(self: *Self, id: OfferId, actions: NeutralDataDevice.Actions) void {
    const offer = self.offers.get(id) orelse return;
    if (offer.resource.getVersion() >= 3) offer.resource.sendSourceActions(toWireActions(actions));
}
pub fn neutralOfferAction(self: *Self, id: OfferId, actions: NeutralDataDevice.Actions) void {
    const offer = self.offers.get(id) orelse return;
    if (offer.resource.getVersion() >= 3) offer.resource.sendAction(toWireActions(actions));
}

pub fn drop(self: *Self) void {
    self.owner.drop();
}
pub fn cancel(self: *Self) void {
    self.owner.cancelDrag();
}
pub fn isDragging(self: *const Self) bool {
    return self.owner.isDragging();
}
pub fn dragIsExternal(self: *const Self) bool {
    return self.owner.dragIsExternal();
}

pub const ResourceCounts = struct {
    sources: usize,
    devices: usize,
    offers: usize,
};
pub fn resourceCounts(self: *const Self) ResourceCounts {
    return .{
        .sources = self.sources.count(),
        .devices = self.devices.count(),
        .offers = self.offers.count(),
    };
}

pub fn sourceId(self: *Self, resource: ?*wl.DataSource) ?SourceId {
    const value = resource orelse return null;
    const data = value.getUserData() orelse return null;
    const adapter: *SourceResource = @ptrCast(@alignCast(data));
    if (adapter.manager != self or adapter.resource != value) return null;
    return adapter.id;
}

pub const ProtocolSourceIdentity = struct {
    client: *wl.Client,
    object_id: u32,
};

pub fn uniqueUnboundProtocolSourceIdentity(self: *const Self, object_id: u32) ?ProtocolSourceIdentity {
    var found: ?ProtocolSourceIdentity = null;
    var sources = self.sources.valueIterator();
    while (sources.next()) |entry| {
        const source = entry.*;
        if (source.resource.getId() != object_id) continue;
        var has_device = false;
        var devices = self.devices.valueIterator();
        while (devices.next()) |device| if (device.*.resource.getClient() == source.resource.getClient()) {
            has_device = true;
            break;
        };
        if (has_device) continue;
        if (found != null) return null;
        found = .{ .client = source.resource.getClient(), .object_id = object_id };
    }
    return found;
}

pub fn setToplevelDragHandler(self: *Self, resource: *wl.DataSource, handler: ToplevelDragHandler) error{InvalidSource}!void {
    const id = self.sourceId(resource) orelse return error.InvalidSource;
    self.owner.setToplevelDragHandler(id, handler) catch return error.InvalidSource;
}
pub fn clearToplevelDragHandler(self: *Self, resource: *wl.DataSource, context: *anyopaque) void {
    self.owner.clearToplevelDragHandler(self.sourceId(resource) orelse return, context);
}

pub fn iconInfo(self: *const Self) ?IconInfo {
    const icon = self.drag_icon orelse return null;
    const position = self.seat.pointerPosition() orelse return null;
    const neutral = self.owner.dragIcon() orelse return null;
    return .{ .surface_id = icon.surface_id, .x = iconCoordinate(position.x, neutral.offset_x), .y = iconCoordinate(position.y, neutral.offset_y) };
}

const DragIcon = struct {
    manager: *Self,
    surface: *Surface,
    surface_id: Surface.Id,
    fn create(manager: *Self, surface: *Surface) !*DragIcon {
        const self = manager.allocator.create(DragIcon) catch return error.OutOfMemory;
        errdefer manager.allocator.destroy(self);
        self.* = .{ .manager = manager, .surface = surface, .surface_id = surface.handle() };
        surface.reserveRole(.drag_icon, .{ .context = self, .before_commit = beforeCommit, .after_commit = afterCommit, .surface_destroyed = surfaceDestroyed }) catch return error.InvalidRole;
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
        self.manager.owner.offsetDragIcon(info.offset_x, info.offset_y);
    }
    fn surfaceDestroyed(context: *anyopaque) void {
        const self: *DragIcon = @ptrCast(@alignCast(context));
        self.manager.owner.surfaceDestroyed(self.surface_id);
        self.manager.drag_icon = null;
        self.manager.allocator.destroy(self);
    }
};
fn clearDragIcon(self: *Self) void {
    const icon = self.drag_icon orelse return;
    self.drag_icon = null;
    icon.destroy();
}

const DragOrigin = struct {
    manager: *Self,
    surface: *Surface,
    surface_id: Surface.Id,
    listener: Surface.CommitListener,

    fn create(manager: *Self, surface: *Surface) !*DragOrigin {
        const self = manager.allocator.create(DragOrigin) catch return error.OutOfMemory;
        errdefer manager.allocator.destroy(self);
        self.* = .{
            .manager = manager,
            .surface = surface,
            .surface_id = surface.handle(),
            .listener = .{
                .context = self,
                .applied = applied,
                .surface_destroyed = surfaceDestroyed,
            },
        };
        try surface.addCommitListener(&self.listener);
        return self;
    }

    fn destroy(self: *DragOrigin) void {
        self.surface.removeCommitListener(&self.listener);
        self.manager.allocator.destroy(self);
    }

    fn applied(_: *anyopaque) void {}

    fn surfaceDestroyed(context: *anyopaque) void {
        const self: *DragOrigin = @ptrCast(@alignCast(context));
        const manager = self.manager;
        const surface_id = self.surface_id;
        self.surface.removeCommitListener(&self.listener);
        manager.drag_origin = null;
        manager.allocator.destroy(self);
        manager.owner.surfaceDestroyed(surface_id);
    }
};

fn clearDragOrigin(self: *Self) void {
    const origin = self.drag_origin orelse return;
    self.drag_origin = null;
    origin.destroy();
}

fn rollbackDeviceCreation(self: *Self, id: DeviceId) void {
    while (true) {
        var doomed: ?*OfferResource = null;
        var offers = self.offers.valueIterator();
        while (offers.next()) |entry| {
            const offer = entry.*;
            const info = self.owner.offerInfo(offer.id) orelse continue;
            if (info.device != null and std.meta.eql(info.device.?, id)) {
                doomed = offer;
                break;
            }
        }
        const offer = doomed orelse break;
        offer.resource.destroy();
    }
    self.owner.destroyDevice(id);
}

fn detachOffersFromDevice(self: *Self, device: *DeviceResource) void {
    var offers = self.offers.valueIterator();
    while (offers.next()) |entry| {
        if (entry.*.device == device) entry.*.device = null;
    }
}

fn rollbackEndpointMaterialization(self: *Self, device: *DeviceResource) void {
    while (true) {
        var doomed: ?*OfferResource = null;
        var offers = self.offers.valueIterator();
        while (offers.next()) |entry| if (entry.*.device == device) {
            doomed = entry.*;
            break;
        };
        const offer = doomed orelse return;
        offer.resource.destroy();
    }
}

fn matureSerial(value: u32) ClientRegistry.Serial {
    return .{ .domain = .mature_display, .value = value };
}
fn fromWireActions(value: wl.DataDeviceManager.DndAction) NeutralDataDevice.Actions {
    return @bitCast(@as(u32, @bitCast(value)));
}
fn toWireActions(value: NeutralDataDevice.Actions) wl.DataDeviceManager.DndAction {
    return @bitCast(@as(u32, @bitCast(value)));
}
fn fixed(value: f64) wl.Fixed {
    return wl.Fixed.fromDouble(std.math.clamp(value, @as(f64, @floatFromInt(std.math.minInt(i32))) / 256.0, @as(f64, @floatFromInt(std.math.maxInt(i32))) / 256.0));
}
fn iconCoordinate(position: f64, offset: i32) i32 {
    const value: i64 = @intFromFloat(@floor(std.math.clamp(position, @as(f64, @floatFromInt(std.math.minInt(i32))), @as(f64, @floatFromInt(std.math.maxInt(i32))))));
    return @intCast(std.math.clamp(value + @as(i64, offset), std.math.minInt(i32), std.math.maxInt(i32)));
}

test "wire actions round trip through neutral actions" {
    const wire: wl.DataDeviceManager.DndAction = .{ .copy = true, .ask = true };
    try std.testing.expectEqual(@as(u32, @bitCast(wire)), @as(u32, @bitCast(toWireActions(fromWireActions(wire)))));
}
