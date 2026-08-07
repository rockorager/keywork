//! Resource-only libwayland adapter for canonical primary selection.

const Self = @This();
const std = @import("std");
const wayland = @import("wayland");
const DataDevice = @import("../DataDevice.zig");
const Seat = @import("seat.zig");
const SelectionSource = @import("SelectionSource.zig");
const MatureSerials = @import("mature_serials.zig");
const wl = wayland.server.wl;
const zwp = wayland.server.zwp;

allocator: std.mem.Allocator,
global: *wl.Global,
seat: *Seat,
canonical: *DataDevice,
sources: std.AutoHashMapUnmanaged(DataDevice.PrimarySourceId, *SourceResource) = .empty,
devices: std.AutoHashMapUnmanaged(DataDevice.PrimaryDeviceId, *DeviceResource) = .empty,
offers: std.AutoHashMapUnmanaged(DataDevice.PrimaryOfferId, *OfferResource) = .empty,
selection_listeners: std.ArrayList(SelectionListener) = .empty,
external_source: ?*const SelectionSource = null,
external_id: ?DataDevice.PrimarySourceId = null,

pub const SelectionListener = struct { context: *anyopaque, changed: *const fn (*anyopaque) void, offered: *const fn (*anyopaque, [*:0]const u8) void };

pub fn init(self: *Self, allocator: std.mem.Allocator, display: *wl.Server, seat: *Seat, canonical: *DataDevice) !void {
    self.* = .{ .allocator = allocator, .global = undefined, .seat = seat, .canonical = canonical };
    self.global = try wl.Global.create(display, zwp.PrimarySelectionDeviceManagerV1, 1, *Self, self, bind);
}
pub fn deinit(self: *Self) void {
    std.debug.assert(self.selection_listeners.items.len == 0 and self.sources.count() == 0 and self.devices.count() == 0 and self.offers.count() == 0);
    if (self.external_id) |id| self.canonical.destroyPrimarySource(id);
    self.global.destroy();
    self.sources.deinit(self.allocator);
    self.devices.deinit(self.allocator);
    self.offers.deinit(self.allocator);
    self.selection_listeners.deinit(self.allocator);
    self.* = undefined;
}
fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = zwp.PrimarySelectionDeviceManagerV1.create(client, version, id) catch return client.postNoMemory();
    resource.setHandler(*Self, managerRequest, null, self);
}
fn managerRequest(resource: *zwp.PrimarySelectionDeviceManagerV1, request: zwp.PrimarySelectionDeviceManagerV1.Request, self: *Self) void {
    switch (request) {
        .create_source => |r| SourceResource.create(self, resource.getClient(), resource.getVersion(), r.id) catch resource.postNoMemory(),
        .get_device => |r| if (self.seat.ownsResource(r.seat)) DeviceResource.create(self, resource.getClient(), resource.getVersion(), r.id) catch resource.postNoMemory() else createInert(resource.getClient(), resource.getVersion(), r.id) catch resource.postNoMemory(),
        .destroy => resource.destroy(),
    }
}
fn createInert(client: *wl.Client, version: u32, id: u32) !void {
    const r = try zwp.PrimarySelectionDeviceV1.create(client, version, id);
    r.setHandler(?*anyopaque, inertRequest, null, null);
}
fn inertRequest(resource: *zwp.PrimarySelectionDeviceV1, request: zwp.PrimarySelectionDeviceV1.Request, _: ?*anyopaque) void {
    if (request == .destroy) resource.destroy();
}

const SourceResource = struct {
    manager: *Self,
    resource: *zwp.PrimarySelectionSourceV1,
    id: DataDevice.PrimarySourceId,
    fn create(manager: *Self, client: *wl.Client, version: u32, protocol_id: u32) !void {
        const resource = try zwp.PrimarySelectionSourceV1.create(client, version, protocol_id);
        errdefer resource.destroy();
        const self = try manager.allocator.create(SourceResource);
        errdefer manager.allocator.destroy(self);
        self.* = .{ .manager = manager, .resource = resource, .id = undefined };
        self.id = try manager.canonical.createPrimarySource(manager.seat.matureClientId(client) orelse return error.OutOfMemory, endpoint(self));
        errdefer manager.canonical.destroyPrimarySource(self.id);
        try manager.sources.put(manager.allocator, self.id, self);
        resource.setHandler(*SourceResource, request, destroyed, self);
    }
    fn endpoint(self: *SourceResource) DataDevice.SourceEndpoint {
        return .{ .context = self, .send = send, .target = noTarget, .action = noAction, .cancelled = cancelled, .selection_cancelled = cancelled, .drop_performed = noop, .finished = noop };
    }
    fn request(resource: *zwp.PrimarySelectionSourceV1, value: zwp.PrimarySelectionSourceV1.Request, self: *SourceResource) void {
        switch (value) {
            .offer => |r| self.manager.canonical.offerPrimaryMime(self.id, std.mem.span(r.mime_type)) catch resource.postNoMemory(),
            .destroy => resource.destroy(),
        }
    }
    fn destroyed(_: *zwp.PrimarySelectionSourceV1, self: *SourceResource) void {
        _ = self.manager.sources.remove(self.id);
        self.manager.canonical.destroyPrimarySource(self.id);
        self.manager.allocator.destroy(self);
    }
    fn send(context: *anyopaque, mime: []const u8, fd: std.posix.fd_t) void {
        const self: *SourceResource = @ptrCast(@alignCast(context));
        self.resource.sendSend(@ptrCast(mime.ptr), fd);
    }
    fn cancelled(context: *anyopaque) void {
        const self: *SourceResource = @ptrCast(@alignCast(context));
        self.resource.sendCancelled();
    }
};

const DeviceResource = struct {
    const PreparedSelection = struct {
        id: ?DataDevice.PrimaryOfferId,
        offer: ?*OfferResource,
    };

    manager: *Self,
    resource: *zwp.PrimarySelectionDeviceV1,
    id: DataDevice.PrimaryDeviceId,
    prepared: ?PreparedSelection = null,
    fn create(manager: *Self, client: *wl.Client, version: u32, protocol_id: u32) !void {
        const resource = try zwp.PrimarySelectionDeviceV1.create(client, version, protocol_id);
        errdefer resource.destroy();
        const self = try manager.allocator.create(DeviceResource);
        errdefer manager.allocator.destroy(self);
        self.* = .{ .manager = manager, .resource = resource, .id = undefined };
        self.id = try manager.canonical.createPrimaryDevice(manager.seat.matureClientId(client) orelse return error.OutOfMemory, .{ .context = self, .selection_prepare = selectionPrepare, .selection = selection });
        errdefer manager.canonical.destroyPrimaryDevice(self.id);
        try manager.devices.put(manager.allocator, self.id, self);
        resource.setHandler(*DeviceResource, request, destroyed, self);
    }
    fn request(resource: *zwp.PrimarySelectionDeviceV1, value: zwp.PrimarySelectionDeviceV1.Request, self: *DeviceResource) void {
        switch (value) {
            .set_selection => |r| {
                const id = if (r.source) |raw|
                    sourceIdentity(self.manager, resource.getClient(), raw) orelse return
                else
                    null;
                self.manager.canonical.setPrimarySelection(self.id, id, MatureSerials.fromWire(r.serial)) catch {};
            },
            .destroy => resource.destroy(),
        }
    }
    fn selectionPrepare(context: *anyopaque, id: ?DataDevice.PrimaryOfferId) error{OutOfMemory}!void {
        const self: *DeviceResource = @ptrCast(@alignCast(context));
        std.debug.assert(self.prepared == null);
        self.prepared = .{
            .id = id,
            .offer = if (id) |offer_id| OfferResource.create(self.manager, self, offer_id) catch return error.OutOfMemory else null,
        };
    }
    fn selection(context: *anyopaque, id: ?DataDevice.PrimaryOfferId) error{OutOfMemory}!void {
        const self: *DeviceResource = @ptrCast(@alignCast(context));
        const prepared = self.prepared orelse unreachable;
        std.debug.assert(std.meta.eql(prepared.id, id));
        self.prepared = null;
        if (id == null) return self.resource.sendSelection(null);
        const offer = prepared.offer orelse unreachable;
        self.resource.sendDataOffer(offer.resource);
        const source = self.manager.canonical.primaryOfferSource(id.?) orelse return;
        const mimes = self.manager.canonical.primarySourceMimeTypes(source) catch return;
        for (mimes) |mime| offer.resource.sendOffer(@ptrCast(mime.ptr));
        self.resource.sendSelection(offer.resource);
    }
    fn destroyed(_: *zwp.PrimarySelectionDeviceV1, self: *DeviceResource) void {
        _ = self.manager.devices.remove(self.id);
        self.manager.canonical.destroyPrimaryDevice(self.id);
        self.manager.allocator.destroy(self);
    }
};

const OfferResource = struct {
    manager: *Self,
    resource: *zwp.PrimarySelectionOfferV1,
    id: DataDevice.PrimaryOfferId,
    fn create(manager: *Self, device: *DeviceResource, id: DataDevice.PrimaryOfferId) !*OfferResource {
        const resource = try zwp.PrimarySelectionOfferV1.create(device.resource.getClient(), device.resource.getVersion(), 0);
        errdefer resource.destroy();
        const self = try manager.allocator.create(OfferResource);
        errdefer manager.allocator.destroy(self);
        self.* = .{ .manager = manager, .resource = resource, .id = id };
        try manager.offers.put(manager.allocator, id, self);
        resource.setHandler(*OfferResource, request, destroyed, self);
        return self;
    }
    fn request(_: *zwp.PrimarySelectionOfferV1, value: zwp.PrimarySelectionOfferV1.Request, self: *OfferResource) void {
        switch (value) {
            .receive => |r| {
                defer (std.Io.File{ .handle = r.fd, .flags = .{ .nonblocking = false } }).close(self.manager.seat.io);
                self.manager.canonical.receivePrimary(self.id, std.mem.span(r.mime_type), r.fd) catch {};
            },
            .destroy => self.resource.destroy(),
        }
    }
    fn destroyed(_: *zwp.PrimarySelectionOfferV1, self: *OfferResource) void {
        _ = self.manager.offers.remove(self.id);
        self.manager.canonical.destroyPrimaryOffer(self.id);
        self.manager.allocator.destroy(self);
    }
};

fn sourceIdentity(self: *Self, client: *wl.Client, resource: *zwp.PrimarySelectionSourceV1) ?DataDevice.PrimarySourceId {
    const data = resource.getUserData() orelse return null;
    const source: *SourceResource = @ptrCast(@alignCast(data));
    if (source.manager != self or resource.getClient() != client or self.sources.get(source.id) != source) return null;
    return source.id;
}
pub fn neutralSelectionChanged(self: *Self) void {
    for (self.selection_listeners.items) |listener| listener.changed(listener.context);
}
pub fn neutralMimeOffered(self: *Self, source: DataDevice.PrimarySourceId, mime: []const u8) void {
    if (!self.canonical.primarySelectionIs(source)) return;
    for (self.selection_listeners.items) |listener| listener.offered(listener.context, @ptrCast(mime.ptr));
}
pub fn neutralOfferRolledBack(self: *Self, id: DataDevice.PrimaryOfferId) void {
    var devices = self.devices.valueIterator();
    while (devices.next()) |device| if (device.*.prepared) |prepared| {
        if (prepared.id != null and std.meta.eql(prepared.id.?, id)) device.*.prepared = null;
    };
    if (self.offers.get(id)) |offer| offer.resource.destroy();
}
pub fn transactionAbort(self: *Self) void {
    var devices = self.devices.valueIterator();
    while (devices.next()) |device| device.*.prepared = null;
}
pub fn neutralOfferMime(self: *Self, id: DataDevice.PrimaryOfferId, mime: []const u8) void {
    if (self.offers.get(id)) |offer| offer.resource.sendOffer(@ptrCast(mime.ptr));
}
pub fn addSelectionListener(self: *Self, listener: SelectionListener) error{OutOfMemory}!void {
    try self.selection_listeners.append(self.allocator, listener);
}
pub fn removeSelectionListener(self: *Self, context: *anyopaque) void {
    for (self.selection_listeners.items, 0..) |listener, i| if (listener.context == context) {
        _ = self.selection_listeners.orderedRemove(i);
        return;
    };
    unreachable;
}
pub fn selectionGeneration(self: *const Self) u64 {
    return self.canonical.primarySelectionGeneration();
}
pub fn hasSelection(self: *const Self) bool {
    return self.canonical.hasPrimarySelection();
}
pub fn selectionMimeTypes(self: *Self) []const [:0]const u8 {
    return @ptrCast(self.canonical.primarySelectionMimeTypes());
}
pub fn sendSelection(self: *Self, mime: [*:0]const u8, fd: std.posix.fd_t) void {
    self.canonical.sendPrimarySelection(std.mem.span(mime), fd) catch {};
}
pub fn setExternalSelection(self: *Self, source: ?*const SelectionSource) void {
    if (source == self.external_source) {
        if (source == null) return;
        if (self.external_id) |id| if (self.canonical.primarySelectionIs(id)) return;
    }
    const old_id = self.external_id;
    if (source) |value| {
        const id = self.canonical.createPrimarySource(null, externalEndpoint(value)) catch return;
        for (value.mime_types(value.context)) |mime| self.canonical.offerPrimaryMime(id, mime) catch {
            self.canonical.destroyPrimarySource(id);
            return;
        };
        self.canonical.setExternalPrimarySelection(id) catch {
            self.canonical.destroyPrimarySource(id);
            return;
        };
        self.external_source = value;
        self.external_id = id;
    } else {
        self.canonical.clearExternalPrimarySelection();
        self.external_source = null;
        self.external_id = null;
    }
    if (old_id) |id| self.canonical.destroyPrimarySource(id);
}
pub fn externalSelectionIs(self: *const Self, source: *const SelectionSource) bool {
    return self.external_source == source and self.external_id != null and self.canonical.primarySelectionIs(self.external_id.?);
}
pub fn externalSourceDestroyed(self: *Self, source: *const SelectionSource) void {
    if (self.external_source != source) return;
    const id = self.external_id.?;
    self.external_id = null;
    self.external_source = null;
    self.canonical.destroyPrimarySource(id);
}
fn externalEndpoint(source: *const SelectionSource) DataDevice.SourceEndpoint {
    return .{ .context = @constCast(source), .send = externalSend, .target = noTarget, .action = noAction, .cancelled = externalCancel, .selection_cancelled = externalCancel, .drop_performed = noop, .finished = noop };
}
fn externalSend(context: *anyopaque, mime: []const u8, fd: std.posix.fd_t) void {
    const source: *SelectionSource = @ptrCast(@alignCast(context));
    source.send(source.context, @ptrCast(mime.ptr), fd);
}
fn externalCancel(context: *anyopaque) void {
    const source: *SelectionSource = @ptrCast(@alignCast(context));
    source.cancel(source.context);
}
fn noTarget(_: *anyopaque, _: ?[]const u8) void {}
fn noAction(_: *anyopaque, _: DataDevice.Actions) void {}
fn noop(_: *anyopaque) void {}
