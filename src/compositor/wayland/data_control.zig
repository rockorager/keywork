//! Privileged ext-data-control-v1 clipboard management.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const DataDevice = @import("../DataDevice.zig");
const PrimarySelection = @import("primary_selection.zig");
const Seat = @import("seat.zig");
const SecurityContext = @import("security_context.zig");
const SelectionSource = @import("SelectionSource.zig");

const wl = wayland.server.wl;
const ext = wayland.server.ext;
const zwlr = wayland.server.zwlr;

allocator: std.mem.Allocator,
ext_global: *wl.Global,
wlr_global: *wl.Global,
security_context: *SecurityContext,
seats: std.ArrayList(*SeatState),
sources: std.ArrayList(*Source),

const Kind = enum { regular, primary };

const Channel = struct {
    source: ?*Source = null,
    generation: u64 = 0,
};

const SeatState = struct {
    manager: *Self,
    seat: *Seat,
    data_device: ?*DataDevice = null,
    primary_selection: ?*PrimarySelection = null,
    removed: bool = false,
    regular: Channel = .{},
    primary: Channel = .{},
    devices: std.ArrayList(*Device) = .empty,

    fn channel(self: *SeatState, kind: Kind) *Channel {
        return switch (kind) {
            .regular => &self.regular,
            .primary => &self.primary,
        };
    }

    fn replace(self: *SeatState, kind: Kind, source: ?*Source, cancel_old: bool) void {
        if (self.data_device) |data_device| {
            switch (kind) {
                .regular => {
                    self.regular.source = source;
                    data_device.setExternalSelection(if (source) |value| value.source_id else null) catch unreachable;
                },
                .primary => self.primary_selection.?.setExternalSelection(
                    if (source) |value| &value.callbacks else null,
                ),
            }
            return;
        }
        const selection = self.channel(kind);
        if (selection.source == source) return;
        const old = selection.source;
        selection.source = source;
        selection.generation +%= 1;
        if (!self.removed) self.broadcast(kind);
        if (cancel_old) if (old) |value| value.callbacks.cancel(value.callbacks.context);
    }

    fn broadcast(self: *SeatState, kind: Kind) void {
        for (self.devices.items) |device| device.sendSelection(kind) catch device.postNoMemory();
    }

    fn hasSelection(self: *SeatState, kind: Kind) bool {
        if (self.data_device) |data_device| return switch (kind) {
            .regular => data_device.hasSelection(),
            .primary => self.primary_selection.?.hasSelection(),
        };
        return self.channel(kind).source != null;
    }

    fn generation(self: *SeatState, kind: Kind) u64 {
        if (self.data_device) |data_device| return switch (kind) {
            .regular => data_device.selectionGeneration(),
            .primary => self.primary_selection.?.selectionGeneration(),
        };
        return self.channel(kind).generation;
    }

    fn mimeTypes(self: *SeatState, kind: Kind) []const []const u8 {
        if (self.data_device) |data_device| return switch (kind) {
            .regular => data_device.selectionMimeTypes(),
            .primary => @ptrCast(self.primary_selection.?.selectionMimeTypes()),
        };
        const source = self.channel(kind).source orelse return &.{};
        return @ptrCast(source.callbacks.mime_types(source.callbacks.context));
    }

    fn send(self: *SeatState, kind: Kind, mime_type: [*:0]const u8, fd: std.posix.fd_t) void {
        if (self.data_device) |data_device| {
            switch (kind) {
                .regular => data_device.sendSelection(std.mem.span(mime_type), fd) catch {},
                .primary => self.primary_selection.?.sendSelection(mime_type, fd),
            }
            return;
        }
        const source = self.channel(kind).source orelse return;
        if (source.callbacks.hasMime(mime_type)) {
            source.callbacks.send(source.callbacks.context, mime_type, fd);
        }
    }

    fn offered(self: *SeatState, kind: Kind, mime_type: [*:0]const u8) void {
        const current_generation = self.generation(kind);
        for (self.devices.items) |device| {
            for (device.offers.items) |offer| {
                if (offer.kind == kind and offer.generation == current_generation) {
                    offer.sendOffer(mime_type);
                }
            }
        }
    }
};

const Source = struct {
    manager: *Self,
    resource: Resource,
    mime_types: std.ArrayList([:0]u8) = .empty,
    used: bool = false,
    cancelled: bool = false,
    source_id: ?DataDevice.SourceId = null,
    callbacks: SelectionSource,

    fn endpoint(self: *Source) DataDevice.SourceEndpoint {
        return .{
            .context = self,
            .send = neutralSend,
            .target = neutralTarget,
            .action = neutralAction,
            .cancelled = callbackCancel,
            .drop_performed = neutralDropPerformed,
            .finished = neutralFinished,
        };
    }

    fn register(self: *Source, data_device: *DataDevice) DataDevice.Error!DataDevice.SourceId {
        if (self.source_id) |id| return id;
        const id = try data_device.createSource(null, self.endpoint(), .{});
        errdefer data_device.destroySource(id);
        for (self.mime_types.items) |mime_type| try data_device.offerMime(id, mime_type);
        self.source_id = id;
        return id;
    }

    const Resource = union(enum) {
        ext: *ext.DataControlSourceV1,
        wlr: *zwlr.DataControlSourceV1,
    };

    fn createExt(manager: *Self, client: *wl.Client, version: u32, id: u32) !void {
        const resource = try ext.DataControlSourceV1.create(client, version, id);
        errdefer resource.destroy();
        const self = try create(manager, .{ .ext = resource });
        resource.setHandler(*Source, handleExtRequest, handleExtDestroy, self);
    }

    fn createWlr(manager: *Self, client: *wl.Client, version: u32, id: u32) !void {
        const resource = try zwlr.DataControlSourceV1.create(client, @min(version, 1), id);
        errdefer resource.destroy();
        const self = try create(manager, .{ .wlr = resource });
        resource.setHandler(*Source, handleWlrRequest, handleWlrDestroy, self);
    }

    fn create(manager: *Self, resource: Resource) !*Source {
        const self = try manager.allocator.create(Source);
        errdefer manager.allocator.destroy(self);
        self.* = .{
            .manager = manager,
            .resource = resource,
            .callbacks = .{ .context = self, .mime_types = callbackMimes, .send = callbackSend, .cancel = callbackCancel },
        };
        try manager.sources.append(manager.allocator, self);
        return self;
    }

    fn callbackMimes(context: *anyopaque) []const [:0]const u8 {
        const self: *Source = @ptrCast(@alignCast(context));
        return @ptrCast(self.mime_types.items);
    }

    fn callbackSend(context: *anyopaque, mime_type: [*:0]const u8, fd: std.posix.fd_t) void {
        const self: *Source = @ptrCast(@alignCast(context));
        switch (self.resource) {
            .ext => |resource| resource.sendSend(mime_type, fd),
            .wlr => |resource| resource.sendSend(mime_type, fd),
        }
    }

    fn neutralSend(context: *anyopaque, mime_type: []const u8, fd: std.posix.fd_t) void {
        const self: *Source = @ptrCast(@alignCast(context));
        switch (self.resource) {
            .ext => |resource| resource.sendSend(@ptrCast(mime_type.ptr), fd),
            .wlr => |resource| resource.sendSend(@ptrCast(mime_type.ptr), fd),
        }
    }

    fn neutralTarget(_: *anyopaque, _: ?[]const u8) void {}
    fn neutralAction(_: *anyopaque, _: DataDevice.Actions) void {}
    fn neutralDropPerformed(_: *anyopaque) void {}
    fn neutralFinished(_: *anyopaque) void {}

    fn callbackCancel(context: *anyopaque) void {
        const self: *Source = @ptrCast(@alignCast(context));
        if (self.cancelled) return;
        self.cancelled = true;
        switch (self.resource) {
            .ext => |resource| resource.sendCancelled(),
            .wlr => |resource| resource.sendCancelled(),
        }
    }

    fn handleExtRequest(
        resource: *ext.DataControlSourceV1,
        request: ext.DataControlSourceV1.Request,
        self: *Source,
    ) void {
        switch (request) {
            .offer => |request_offer| self.offer(request_offer.mime_type),
            .destroy => resource.destroy(),
        }
    }

    fn handleWlrRequest(
        resource: *zwlr.DataControlSourceV1,
        request: zwlr.DataControlSourceV1.Request,
        self: *Source,
    ) void {
        switch (request) {
            .offer => |request_offer| self.offer(request_offer.mime_type),
            .destroy => resource.destroy(),
        }
    }

    fn offer(self: *Source, mime_type: [*:0]const u8) void {
        if (self.used) {
            switch (self.resource) {
                .ext => |resource| resource.postError(
                    .invalid_offer,
                    "cannot add a MIME type after using the source",
                ),
                .wlr => |resource| resource.postError(
                    .invalid_offer,
                    "cannot add a MIME type after using the source",
                ),
            }
            return;
        }
        const value = std.mem.span(mime_type);
        for (self.mime_types.items) |existing| if (std.mem.eql(u8, existing, value)) return;
        const copy = self.manager.allocator.dupeZ(u8, value) catch {
            self.postNoMemory();
            return;
        };
        self.mime_types.append(self.manager.allocator, copy) catch {
            self.manager.allocator.free(copy);
            self.postNoMemory();
            return;
        };
        if (self.source_id) |id| for (self.manager.seats.items) |seat| {
            if (seat.data_device) |data_device| {
                data_device.offerMime(id, copy) catch self.postNoMemory();
                break;
            }
        };
    }

    fn postNoMemory(self: *Source) void {
        switch (self.resource) {
            .ext => |resource| resource.postNoMemory(),
            .wlr => |resource| resource.postNoMemory(),
        }
    }

    fn handleExtDestroy(_: *ext.DataControlSourceV1, self: *Source) void {
        self.destroy();
    }

    fn handleWlrDestroy(_: *zwlr.DataControlSourceV1, self: *Source) void {
        self.destroy();
    }

    fn destroy(self: *Source) void {
        for (self.manager.seats.items) |seat| {
            if (seat.data_device) |data_device| {
                if (seat.regular.source == self) seat.regular.source = null;
                if (self.source_id) |id| data_device.destroySource(id);
                seat.primary_selection.?.externalSourceDestroyed(&self.callbacks);
            } else {
                if (seat.regular.source == self) seat.replace(.regular, null, false);
                if (seat.primary.source == self) seat.replace(.primary, null, false);
            }
        }
        for (self.manager.sources.items, 0..) |source, index| if (source == self) {
            _ = self.manager.sources.swapRemove(index);
            break;
        };
        for (self.mime_types.items) |mime_type| self.manager.allocator.free(mime_type);
        self.mime_types.deinit(self.manager.allocator);
        self.manager.allocator.destroy(self);
    }
};

const Device = struct {
    state: *SeatState,
    resource: Resource,
    offers: std.ArrayList(*Offer) = .empty,

    const Resource = union(enum) {
        ext: *ext.DataControlDeviceV1,
        wlr: *zwlr.DataControlDeviceV1,
    };

    fn createExt(state: *SeatState, wayland_client: *wl.Client, bound_version: u32, id: u32) !void {
        const resource = try ext.DataControlDeviceV1.create(wayland_client, bound_version, id);
        errdefer resource.destroy();
        const self = try create(state, .{ .ext = resource });
        resource.setHandler(*Device, handleExtRequest, handleExtDestroy, self);
        self.sendInitial();
    }

    fn createWlr(state: *SeatState, wayland_client: *wl.Client, bound_version: u32, id: u32) !void {
        const resource = try zwlr.DataControlDeviceV1.create(wayland_client, bound_version, id);
        errdefer resource.destroy();
        const self = try create(state, .{ .wlr = resource });
        resource.setHandler(*Device, handleWlrRequest, handleWlrDestroy, self);
        self.sendInitial();
    }

    fn create(state: *SeatState, resource: Resource) !*Device {
        const self = try state.manager.allocator.create(Device);
        errdefer state.manager.allocator.destroy(self);
        self.* = .{ .state = state, .resource = resource };
        try state.devices.append(state.manager.allocator, self);
        return self;
    }

    fn sendInitial(self: *Device) void {
        self.sendSelection(.regular) catch {
            self.postNoMemory();
            return;
        };
        if (self.supportsPrimary()) self.sendSelection(.primary) catch self.postNoMemory();
    }

    fn set(self: *Device, kind: Kind, source: ?*Source) void {
        if (self.state.removed) return;
        if (source) |value| {
            if (value.used) {
                self.postUsedSource();
                return;
            }
            value.used = true;
        }
        if (kind == .regular) {
            const source_id = if (source) |value| value.register(self.state.data_device.?) catch {
                value.postNoMemory();
                return;
            } else null;
            self.state.regular.source = source;
            self.state.data_device.?.setExternalSelection(source_id) catch unreachable;
        } else {
            self.state.replace(kind, source, true);
        }
    }

    fn handleExtRequest(
        resource: *ext.DataControlDeviceV1,
        request: ext.DataControlDeviceV1.Request,
        self: *Device,
    ) void {
        switch (request) {
            .set_selection => |request_set| self.set(.regular, extSource(request_set.source)),
            .set_primary_selection => |request_set| self.set(
                .primary,
                extSource(request_set.source),
            ),
            .destroy => resource.destroy(),
        }
    }

    fn handleWlrRequest(
        resource: *zwlr.DataControlDeviceV1,
        request: zwlr.DataControlDeviceV1.Request,
        self: *Device,
    ) void {
        switch (request) {
            .set_selection => |request_set| self.set(.regular, wlrSource(request_set.source)),
            .set_primary_selection => |request_set| self.set(
                .primary,
                wlrSource(request_set.source),
            ),
            .destroy => resource.destroy(),
        }
    }

    fn sendSelection(self: *Device, kind: Kind) !void {
        if (kind == .primary and !self.supportsPrimary()) return;
        if (!self.state.hasSelection(kind)) {
            self.sendSelectionEvent(kind, null);
            return;
        }
        const offer = try Offer.create(self, kind, self.state.generation(kind));
        self.sendDataOffer(offer);
        for (self.state.mimeTypes(kind)) |mime_type| offer.sendOffer(@ptrCast(mime_type.ptr));
        self.sendSelectionEvent(kind, offer);
    }

    fn supportsPrimary(self: *const Device) bool {
        return switch (self.resource) {
            .ext => true,
            .wlr => |resource| resource.getVersion() >= 2,
        };
    }

    fn postNoMemory(self: *Device) void {
        switch (self.resource) {
            .ext => |resource| resource.postNoMemory(),
            .wlr => |resource| resource.postNoMemory(),
        }
    }

    fn postUsedSource(self: *Device) void {
        switch (self.resource) {
            .ext => |resource| resource.postError(
                .used_source,
                "data-control source was already used",
            ),
            .wlr => |resource| resource.postError(
                .used_source,
                "data-control source was already used",
            ),
        }
    }

    fn sendDataOffer(self: *Device, offer: *Offer) void {
        switch (self.resource) {
            .ext => |resource| resource.sendDataOffer(offer.resource.ext),
            .wlr => |resource| resource.sendDataOffer(offer.resource.wlr),
        }
    }

    fn sendSelectionEvent(self: *Device, kind: Kind, offer: ?*Offer) void {
        switch (self.resource) {
            .ext => |resource| switch (kind) {
                .regular => resource.sendSelection(if (offer) |value| value.resource.ext else null),
                .primary => resource.sendPrimarySelection(if (offer) |value| value.resource.ext else null),
            },
            .wlr => |resource| switch (kind) {
                .regular => resource.sendSelection(if (offer) |value| value.resource.wlr else null),
                .primary => resource.sendPrimarySelection(if (offer) |value| value.resource.wlr else null),
            },
        }
    }

    fn sendFinished(self: *Device) void {
        switch (self.resource) {
            .ext => |resource| resource.sendFinished(),
            .wlr => |resource| resource.sendFinished(),
        }
    }

    fn client(self: *const Device) *wl.Client {
        return switch (self.resource) {
            .ext => |resource| resource.getClient(),
            .wlr => |resource| resource.getClient(),
        };
    }

    fn version(self: *const Device) u32 {
        return switch (self.resource) {
            .ext => |resource| resource.getVersion(),
            .wlr => |resource| resource.getVersion(),
        };
    }

    fn handleExtDestroy(_: *ext.DataControlDeviceV1, self: *Device) void {
        self.destroy();
    }

    fn handleWlrDestroy(_: *zwlr.DataControlDeviceV1, self: *Device) void {
        self.destroy();
    }

    fn destroy(self: *Device) void {
        for (self.state.devices.items, 0..) |device, index| if (device == self) {
            _ = self.state.devices.swapRemove(index);
            break;
        };
        for (self.offers.items) |offer| offer.device = null;
        self.offers.deinit(self.state.manager.allocator);
        self.state.manager.allocator.destroy(self);
    }

    fn extSource(resource: ?*ext.DataControlSourceV1) ?*Source {
        const source_resource = resource orelse return null;
        const data = source_resource.getUserData() orelse return null;
        const source: *Source = @ptrCast(@alignCast(data));
        return switch (source.resource) {
            .ext => |candidate| if (candidate == source_resource) source else null,
            .wlr => null,
        };
    }

    fn wlrSource(resource: ?*zwlr.DataControlSourceV1) ?*Source {
        const source_resource = resource orelse return null;
        const data = source_resource.getUserData() orelse return null;
        const source: *Source = @ptrCast(@alignCast(data));
        return switch (source.resource) {
            .ext => null,
            .wlr => |candidate| if (candidate == source_resource) source else null,
        };
    }
};

const Offer = struct {
    manager: *Self,
    device: ?*Device,
    io: std.Io,
    resource: Resource,
    kind: Kind,
    generation: u64,

    const Resource = union(enum) {
        ext: *ext.DataControlOfferV1,
        wlr: *zwlr.DataControlOfferV1,
    };

    fn create(device: *Device, kind: Kind, generation: u64) !*Offer {
        const resource: Resource = switch (device.resource) {
            .ext => .{ .ext = try ext.DataControlOfferV1.create(device.client(), device.version(), 0) },
            .wlr => .{ .wlr = try zwlr.DataControlOfferV1.create(device.client(), 1, 0) },
        };
        errdefer switch (resource) {
            .ext => |value| value.destroy(),
            .wlr => |value| value.destroy(),
        };
        const self = try device.state.manager.allocator.create(Offer);
        errdefer device.state.manager.allocator.destroy(self);
        self.* = .{
            .manager = device.state.manager,
            .device = device,
            .io = device.state.seat.io,
            .resource = resource,
            .kind = kind,
            .generation = generation,
        };
        try device.offers.append(device.state.manager.allocator, self);
        switch (resource) {
            .ext => |value| value.setHandler(*Offer, handleExtRequest, handleExtDestroy, self),
            .wlr => |value| value.setHandler(*Offer, handleWlrRequest, handleWlrDestroy, self),
        }
        return self;
    }

    fn handleExtRequest(
        resource: *ext.DataControlOfferV1,
        request: ext.DataControlOfferV1.Request,
        self: *Offer,
    ) void {
        switch (request) {
            .receive => |request_receive| self.receive(request_receive.mime_type, request_receive.fd),
            .destroy => resource.destroy(),
        }
    }

    fn handleWlrRequest(
        resource: *zwlr.DataControlOfferV1,
        request: zwlr.DataControlOfferV1.Request,
        self: *Offer,
    ) void {
        switch (request) {
            .receive => |request_receive| self.receive(request_receive.mime_type, request_receive.fd),
            .destroy => resource.destroy(),
        }
    }

    fn receive(self: *Offer, mime_type: [*:0]const u8, fd: std.posix.fd_t) void {
        defer (std.Io.File{
            .handle = fd,
            .flags = .{ .nonblocking = false },
        }).close(self.io);
        const device = self.device orelse return;
        if (device.state.removed or device.state.generation(self.kind) != self.generation) return;
        if (!hasMime(device.state.mimeTypes(self.kind), mime_type)) return;
        device.state.send(self.kind, mime_type, fd);
    }

    fn sendOffer(self: *Offer, mime_type: [*:0]const u8) void {
        switch (self.resource) {
            .ext => |resource| resource.sendOffer(mime_type),
            .wlr => |resource| resource.sendOffer(mime_type),
        }
    }

    fn handleExtDestroy(_: *ext.DataControlOfferV1, self: *Offer) void {
        self.destroy();
    }

    fn handleWlrDestroy(_: *zwlr.DataControlOfferV1, self: *Offer) void {
        self.destroy();
    }

    fn destroy(self: *Offer) void {
        if (self.device) |device| for (device.offers.items, 0..) |offer, index| if (offer == self) {
            _ = device.offers.swapRemove(index);
            break;
        };
        self.manager.allocator.destroy(self);
    }
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    security_context: *SecurityContext,
    default_seat: *Seat,
    data_device: *DataDevice,
    primary_selection: *PrimarySelection,
) !void {
    self.* = .{
        .allocator = allocator,
        .ext_global = undefined,
        .wlr_global = undefined,
        .security_context = security_context,
        .seats = .empty,
        .sources = .empty,
    };
    errdefer self.seats.deinit(allocator);
    errdefer self.sources.deinit(allocator);
    self.ext_global = try wl.Global.create(display, ext.DataControlManagerV1, 1, *Self, self, bindExt);
    errdefer self.ext_global.destroy();
    try security_context.restrictGlobal(self.ext_global);
    errdefer security_context.unrestrictGlobal(self.ext_global);
    self.wlr_global = try wl.Global.create(
        display,
        zwlr.DataControlManagerV1,
        2,
        *Self,
        self,
        bindWlr,
    );
    errdefer self.wlr_global.destroy();
    try security_context.restrictGlobal(self.wlr_global);
    errdefer security_context.unrestrictGlobal(self.wlr_global);
    const state = try self.addSeatState(default_seat);
    state.data_device = data_device;
    state.primary_selection = primary_selection;
    try primary_selection.addSelectionListener(.{
        .context = state,
        .changed = primarySelectionChanged,
        .offered = primaryMimeOffered,
    });
    errdefer primary_selection.removeSelectionListener(state);
}

pub fn deinit(self: *Self) void {
    for (self.seats.items) |state| {
        if (state.data_device != null) {
            state.primary_selection.?.removeSelectionListener(state);
        }
    }
    self.security_context.unrestrictGlobal(self.wlr_global);
    self.wlr_global.destroy();
    self.security_context.unrestrictGlobal(self.ext_global);
    self.ext_global.destroy();
    std.debug.assert(self.sources.items.len == 0);
    for (self.seats.items) |state| {
        std.debug.assert(state.devices.items.len == 0);
        state.devices.deinit(self.allocator);
        self.allocator.destroy(state);
    }
    self.sources.deinit(self.allocator);
    self.seats.deinit(self.allocator);
    self.* = undefined;
}

pub fn addSeat(self: *Self, seat: *Seat) !void {
    _ = try self.addSeatState(seat);
}

fn addSeatState(self: *Self, seat: *Seat) !*SeatState {
    const state = try self.allocator.create(SeatState);
    errdefer self.allocator.destroy(state);
    state.* = .{ .manager = self, .seat = seat };
    try self.seats.append(self.allocator, state);
    return state;
}

pub fn removeSeat(self: *Self, seat: *Seat) void {
    for (self.seats.items) |state| if (state.seat == seat and !state.removed) {
        state.removed = true;
        state.replace(.regular, null, true);
        state.replace(.primary, null, true);
        for (state.devices.items) |device| device.sendFinished();
        return;
    };
}

fn bindExt(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = ext.DataControlManagerV1.create(client, version, id) catch return client.postNoMemory();
    resource.setHandler(*Self, handleExtManagerRequest, null, self);
}

fn handleExtManagerRequest(
    resource: *ext.DataControlManagerV1,
    request: ext.DataControlManagerV1.Request,
    self: *Self,
) void {
    switch (request) {
        .create_data_source => |create| Source.createExt(
            self,
            resource.getClient(),
            resource.getVersion(),
            create.id,
        ) catch resource.postNoMemory(),
        .get_data_device => |get| {
            for (self.seats.items) |state| if (!state.removed and state.seat.ownsResource(get.seat)) {
                Device.createExt(
                    state,
                    resource.getClient(),
                    resource.getVersion(),
                    get.id,
                ) catch resource.postNoMemory();
                return;
            };
            const inert = ext.DataControlDeviceV1.create(resource.getClient(), resource.getVersion(), get.id) catch return resource.postNoMemory();
            inert.sendFinished();
            inert.setHandler(?*anyopaque, inertExtRequest, null, null);
        },
        .destroy => resource.destroy(),
    }
}

fn bindWlr(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = zwlr.DataControlManagerV1.create(client, version, id) catch
        return client.postNoMemory();
    resource.setHandler(*Self, handleWlrManagerRequest, null, self);
}

fn handleWlrManagerRequest(
    resource: *zwlr.DataControlManagerV1,
    request: zwlr.DataControlManagerV1.Request,
    self: *Self,
) void {
    switch (request) {
        .create_data_source => |create| Source.createWlr(
            self,
            resource.getClient(),
            resource.getVersion(),
            create.id,
        ) catch resource.postNoMemory(),
        .get_data_device => |get| {
            for (self.seats.items) |state| if (!state.removed and state.seat.ownsResource(get.seat)) {
                Device.createWlr(
                    state,
                    resource.getClient(),
                    resource.getVersion(),
                    get.id,
                ) catch resource.postNoMemory();
                return;
            };
            const inert = zwlr.DataControlDeviceV1.create(
                resource.getClient(),
                resource.getVersion(),
                get.id,
            ) catch return resource.postNoMemory();
            inert.sendFinished();
            inert.setHandler(?*anyopaque, inertWlrRequest, null, null);
        },
        .destroy => resource.destroy(),
    }
}

fn inertExtRequest(
    resource: *ext.DataControlDeviceV1,
    request: ext.DataControlDeviceV1.Request,
    _: ?*anyopaque,
) void {
    if (request == .destroy) resource.destroy();
}

fn inertWlrRequest(
    resource: *zwlr.DataControlDeviceV1,
    request: zwlr.DataControlDeviceV1.Request,
    _: ?*anyopaque,
) void {
    if (request == .destroy) resource.destroy();
}

pub fn neutralSelectionChanged(self: *Self) void {
    for (self.seats.items) |state| if (state.data_device != null) state.broadcast(.regular);
}

fn primarySelectionChanged(context: *anyopaque) void {
    const state: *SeatState = @ptrCast(@alignCast(context));
    state.broadcast(.primary);
}

pub fn neutralMimeOffered(self: *Self, source_id: DataDevice.SourceId, mime_type: []const u8) void {
    for (self.seats.items) |state| if (state.data_device != null) {
        const source = state.regular.source orelse continue;
        if (source.source_id != null and std.meta.eql(source.source_id.?, source_id)) {
            state.offered(.regular, @ptrCast(mime_type.ptr));
        }
    };
}

fn primaryMimeOffered(context: *anyopaque, mime_type: [*:0]const u8) void {
    const state: *SeatState = @ptrCast(@alignCast(context));
    state.offered(.primary, mime_type);
}

fn hasMime(mime_types: []const []const u8, mime_type: [*:0]const u8) bool {
    const requested = std.mem.span(mime_type);
    for (mime_types) |offered| {
        if (std.mem.eql(u8, offered, requested)) return true;
    }
    return false;
}
