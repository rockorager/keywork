//! Primary-selection transfer tied to keyboard focus.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Seat = @import("seat.zig");
const SelectionSource = @import("SelectionSource.zig");
const SeatAuthority = @import("../SeatAuthority.zig");
const slot_map = @import("../slot_map.zig");

const wl = wayland.server.wl;
const zwp = wayland.server.zwp;

allocator: std.mem.Allocator,
global: *wl.Global,
display: *wl.Server,
seat: *Seat,
sources: SourceStore,
devices: DeviceStore,
offers: OfferStore,
selection: ?Selection,
selection_order: SeatAuthority.Order,
selection_generation: u64,
selection_listeners: std.ArrayList(SelectionListener),
focused_client: ?*wl.Client,

pub const SelectionListener = struct {
    context: *anyopaque,
    changed: *const fn (*anyopaque) void,
    offered: *const fn (*anyopaque, [*:0]const u8) void,
};

const SourceStore = slot_map.SlotMap(SourceState, enum { primary_selection_source });
const SourceId = SourceStore.Id;
const Selection = union(enum) {
    local: SourceId,
    external: *const SelectionSource,
};
const SourceState = struct {
    resource: *zwp.PrimarySelectionSourceV1,
    mime_types: std.ArrayList([:0]u8) = .empty,
    cancelled: bool = false,

    fn deinit(self: *SourceState, allocator: std.mem.Allocator) void {
        for (self.mime_types.items) |mime_type| allocator.free(mime_type);
        self.mime_types.deinit(allocator);
        self.* = undefined;
    }
};

const DeviceStore = slot_map.SlotMap(DeviceState, enum { primary_selection_device });
const DeviceId = DeviceStore.Id;
const DeviceState = struct {
    resource: *zwp.PrimarySelectionDeviceV1,
};

const OfferStore = slot_map.SlotMap(OfferState, enum { primary_selection_offer });
const OfferId = OfferStore.Id;
const OfferState = struct {
    resource: *zwp.PrimarySelectionOfferV1,
    device: DeviceId,
    source: ?SourceId,
    external_source: ?*const SelectionSource = null,
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    seat: *Seat,
) !void {
    self.* = .{
        .allocator = allocator,
        .global = undefined,
        .display = display,
        .seat = seat,
        .sources = .{},
        .devices = .{},
        .offers = .{},
        .selection = null,
        .selection_order = 0,
        .selection_generation = 0,
        .selection_listeners = .empty,
        .focused_client = null,
    };
    errdefer self.sources.deinit(allocator);
    errdefer self.devices.deinit(allocator);
    errdefer self.offers.deinit(allocator);
    errdefer self.selection_listeners.deinit(allocator);
    self.global = try wl.Global.create(
        display,
        zwp.PrimarySelectionDeviceManagerV1,
        1,
        *Self,
        self,
        bind,
    );
    errdefer self.global.destroy();
    try seat.addKeyboardFocusListener(.{
        .context = self,
        .changed = keyboardFocusChanged,
    });
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.selection_listeners.items.len == 0);
    self.seat.removeKeyboardFocusListener(self);
    self.global.destroy();
    std.debug.assert(self.sources.len() == 0);
    std.debug.assert(self.devices.len() == 0);
    std.debug.assert(self.offers.len() == 0);
    self.offers.deinit(self.allocator);
    self.devices.deinit(self.allocator);
    self.sources.deinit(self.allocator);
    self.selection_listeners.deinit(self.allocator);
    self.* = undefined;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = zwp.PrimarySelectionDeviceManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleRequest, null, self);
}

fn handleRequest(
    resource: *zwp.PrimarySelectionDeviceManagerV1,
    request: zwp.PrimarySelectionDeviceManagerV1.Request,
    self: *Self,
) void {
    switch (request) {
        .create_source => |create| SourceResource.create(
            self,
            resource.getClient(),
            resource.getVersion(),
            create.id,
        ) catch resource.postNoMemory(),
        .get_device => |get| {
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
        .destroy => resource.destroy(),
    }
}

fn createInertDevice(client: *wl.Client, version: u32, id: u32) !void {
    const resource = try zwp.PrimarySelectionDeviceV1.create(client, version, id);
    resource.setHandler(?*anyopaque, inertDeviceRequest, null, null);
}

fn inertDeviceRequest(
    resource: *zwp.PrimarySelectionDeviceV1,
    request: zwp.PrimarySelectionDeviceV1.Request,
    _: ?*anyopaque,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .set_selection => {},
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
        const resource = try zwp.PrimarySelectionSourceV1.create(client, version, protocol_id);
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
        resource.setHandler(
            *SourceResource,
            SourceResource.handleRequest,
            SourceResource.handleDestroy,
            self,
        );
    }

    fn handleRequest(
        resource: *zwp.PrimarySelectionSourceV1,
        request: zwp.PrimarySelectionSourceV1.Request,
        self: *SourceResource,
    ) void {
        switch (request) {
            .offer => |request_offer| self.offer(resource, request_offer.mime_type),
            .destroy => resource.destroy(),
        }
    }

    fn offer(
        self: *SourceResource,
        resource: *zwp.PrimarySelectionSourceV1,
        mime_type: [*:0]const u8,
    ) void {
        const state = self.manager.sources.get(self.id) orelse return;
        if (state.cancelled) return;
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
                if (std.meta.eql(source_id, self.id)) {
                    entry.value.resource.sendOffer(copy.ptr);
                }
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

    fn handleDestroy(_: *zwp.PrimarySelectionSourceV1, self: *SourceResource) void {
        self.manager.sourceDestroyed(self.id);
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
        const resource = try zwp.PrimarySelectionDeviceV1.create(client, version, protocol_id);
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
        resource.setHandler(
            *DeviceResource,
            DeviceResource.handleRequest,
            DeviceResource.handleDestroy,
            self,
        );
        if (manager.focused_client == client) {
            manager.sendSelectionToDevice(id) catch resource.postNoMemory();
        }
    }

    fn handleRequest(
        resource: *zwp.PrimarySelectionDeviceV1,
        request: zwp.PrimarySelectionDeviceV1.Request,
        self: *DeviceResource,
    ) void {
        switch (request) {
            .set_selection => |set| self.setSelection(resource, set.source, set.serial),
            .destroy => resource.destroy(),
        }
    }

    fn setSelection(
        self: *DeviceResource,
        resource: *zwp.PrimarySelectionDeviceV1,
        source_resource: ?*zwp.PrimarySelectionSourceV1,
        serial: u32,
    ) void {
        const source_id = if (source_resource) |source| source: {
            const data = source.getUserData() orelse return;
            const adapter: *SourceResource = @ptrCast(@alignCast(data));
            if (adapter.manager != self.manager or source.getClient() != resource.getClient()) return;
            const state = self.manager.sources.get(adapter.id) orelse return;
            if (state.cancelled) return;
            break :source adapter.id;
        } else null;

        const order = self.manager.seat.selectionOrder(
            resource.getClient(),
            serial,
        ) orelse return;
        self.manager.setSelection(source_id, order);
    }

    fn handleDestroy(_: *zwp.PrimarySelectionDeviceV1, self: *DeviceResource) void {
        self.manager.deviceDestroyed(self.id);
        _ = self.manager.devices.remove(self.id);
        self.allocator.destroy(self);
    }
};

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
    ) error{ OutOfMemory, ResourceCreateFailed }!*zwp.PrimarySelectionOfferV1 {
        const resource = try zwp.PrimarySelectionOfferV1.create(client, version, 0);
        errdefer resource.destroy();
        const self = manager.allocator.create(OfferResource) catch return error.OutOfMemory;
        errdefer manager.allocator.destroy(self);
        const id = manager.offers.insert(manager.allocator, .{
            .resource = resource,
            .device = device_id,
            .source = source_id,
            .external_source = external_source,
        }) catch return error.OutOfMemory;
        errdefer _ = manager.offers.remove(id);

        self.* = .{
            .allocator = manager.allocator,
            .manager = manager,
            .id = id,
        };
        resource.setHandler(
            *OfferResource,
            OfferResource.handleRequest,
            OfferResource.handleDestroy,
            self,
        );
        return resource;
    }

    fn handleRequest(
        resource: *zwp.PrimarySelectionOfferV1,
        request: zwp.PrimarySelectionOfferV1.Request,
        self: *OfferResource,
    ) void {
        switch (request) {
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
                }
            },
            .destroy => resource.destroy(),
        }
    }

    fn handleDestroy(_: *zwp.PrimarySelectionOfferV1, self: *OfferResource) void {
        _ = self.manager.offers.remove(self.id);
        self.allocator.destroy(self);
    }
};

fn keyboardFocusChanged(context: *anyopaque, client: ?*wl.Client) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.focused_client == client) return;
    const old_client = self.focused_client;
    self.invalidateOffers();
    self.focused_client = client;
    if (old_client) |old| self.sendNullSelectionToClient(old);
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
        .local => |id| if (self.sources.get(id)) |source| {
            source.cancelled = true;
            source.resource.sendCancelled();
        },
        .external => |source| source.cancel(source.context),
    };
}

fn sourceDestroyed(self: *Self, id: SourceId) void {
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
}

fn deviceDestroyed(self: *Self, id: DeviceId) void {
    var iterator = self.offers.iterator();
    while (iterator.next()) |entry| {
        if (std.meta.eql(entry.value.device, id)) {
            entry.value.source = null;
            entry.value.external_source = null;
        }
    }
}

fn invalidateOffers(self: *Self) void {
    var iterator = self.offers.iterator();
    while (iterator.next()) |entry| {
        entry.value.source = null;
        entry.value.external_source = null;
    }
}

fn sendSelectionToClient(self: *Self, client: *wl.Client) void {
    var iterator = self.devices.iterator();
    while (iterator.next()) |entry| {
        if (entry.value.resource.getClient() != client) continue;
        self.sendSelectionToDevice(entry.id) catch entry.value.resource.postNoMemory();
    }
}

fn sendNullSelectionToClient(self: *Self, client: *wl.Client) void {
    var iterator = self.devices.iterator();
    while (iterator.next()) |entry| {
        if (entry.value.resource.getClient() == client) entry.value.resource.sendSelection(null);
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

fn sourceHasMime(source: *const SourceState, mime_type: [*:0]const u8) bool {
    const requested = std.mem.span(mime_type);
    for (source.mime_types.items) |offered| {
        if (std.mem.eql(u8, offered, requested)) return true;
    }
    return false;
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

test "older selection grant installs a primary source after a newer clear" {
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
    manager.setSelection(source_id, older_order);

    const expected: ?Selection = .{ .local = source_id };
    try std.testing.expect(std.meta.eql(expected, manager.selection));
    try std.testing.expectEqual(older_order, manager.selection_order);
}

test "unchanged external primary selection preserves a prior client grant" {
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
        .sources = .{},
        .devices = .{},
        .offers = .{},
        .selection = selection,
        .selection_order = selection_order,
        .selection_generation = 0,
        .selection_listeners = .empty,
        .focused_client = null,
    };
}
