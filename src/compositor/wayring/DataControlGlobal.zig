//! Focus-independent ext and wlr data-control policy and FD relay.

const DataControlGlobal = @This();
const std = @import("std");
const linux = std.os.linux;
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const SeatGlobal = @import("SeatGlobal.zig");
const DataDeviceGlobal = @import("DataDeviceGlobal.zig");
const PrimarySelectionGlobal = @import("PrimarySelectionGlobal.zig");
const SecurityContextGlobal = @import("SecurityContextGlobal.zig");
const SelectionSource = @import("SelectionSource.zig");

const Kind = enum { regular, primary };
const Protocol = enum { ext, wlr };

allocator: std.mem.Allocator,
server: *Server,
seat: *SeatGlobal,
regular: *DataDeviceGlobal,
primary: *PrimarySelectionGlobal,
ext_global_name: u32,
wlr_global_name: u32,
sources: std.ArrayList(*Source) = .empty,
devices: std.ArrayList(*Device) = .empty,
offers: std.ArrayList(*Offer) = .empty,

const Source = struct {
    owner: *DataControlGlobal,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    protocol: Protocol,
    mimes: std.ArrayList([]u8) = .empty,
    used: bool = false,
    cancelled: bool = false,
    callbacks: SelectionSource,

    fn hasMime(self: *Source, mime: []const u8) bool {
        for (self.mimes.items) |item| if (std.mem.eql(u8, item, mime)) return true;
        return false;
    }
};

const Device = struct {
    owner: *DataControlGlobal,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    protocol: Protocol,
    version: u32,
    inert: bool,

    fn supportsPrimary(self: *const Device) bool {
        return self.protocol == .ext or self.version >= 2;
    }
};

const Offer = struct {
    owner: *DataControlGlobal,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    protocol: Protocol,
    device: ?*Device,
    kind: Kind,
    generation: u64,
};

pub fn init(
    self: *DataControlGlobal,
    allocator: std.mem.Allocator,
    server: *Server,
    seat: *SeatGlobal,
    regular: *DataDeviceGlobal,
    primary: *PrimarySelectionGlobal,
    security_context: *SecurityContextGlobal,
) !void {
    self.* = .{
        .allocator = allocator,
        .server = server,
        .seat = seat,
        .regular = regular,
        .primary = primary,
        .ext_global_name = undefined,
        .wlr_global_name = undefined,
    };
    try regular.addSelectionListener(.{ .context = self, .changed = regularChanged, .offered = regularOffered });
    errdefer regular.removeSelectionListener(self);
    try primary.addSelectionListener(.{ .context = self, .changed = primaryChanged, .offered = primaryOffered });
    errdefer primary.removeSelectionListener(self);
    self.ext_global_name = try server.createGlobal(
        &generated.ext_data_control_manager_v1,
        1,
        .{
            .context = self,
            .bind = bindExt,
            .filter_context = security_context,
            .filter = SecurityContextGlobal.allowUnconfined,
        },
    );
    errdefer server.removeGlobal(self.ext_global_name) catch unreachable;
    self.wlr_global_name = try server.createGlobal(
        &generated.zwlr_data_control_manager_v1,
        2,
        .{
            .context = self,
            .bind = bindWlr,
            .filter_context = security_context,
            .filter = SecurityContextGlobal.allowUnconfined,
        },
    );
}

pub fn deinit(self: *DataControlGlobal) void {
    self.regular.removeSelectionListener(self);
    self.primary.removeSelectionListener(self);
    self.server.removeGlobal(self.wlr_global_name) catch unreachable;
    self.server.removeGlobal(self.ext_global_name) catch unreachable;
    std.debug.assert(self.sources.items.len == 0 and self.devices.items.len == 0 and self.offers.items.len == 0);
    self.sources.deinit(self.allocator);
    self.devices.deinit(self.allocator);
    self.offers.deinit(self.allocator);
}

fn bindExt(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *DataControlGlobal = @ptrCast(@alignCast(context));
    _ = client.createResource(id, &generated.ext_data_control_manager_v1, version, .{ .context = self, .dispatch = dispatchExtManager }) catch return client.postNoMemory();
}

fn bindWlr(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *DataControlGlobal = @ptrCast(@alignCast(context));
    _ = client.createResource(id, &generated.zwlr_data_control_manager_v1, version, .{ .context = self, .dispatch = dispatchWlrManager }) catch return client.postNoMemory();
}

fn dispatchExtManager(context: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    const self: *DataControlGlobal = @ptrCast(@alignCast(context));
    switch (try generated.ext_data_control_manager_v1_types.decodeRequest(&client.connection, resource, message)) {
        .create_data_source => |request| try self.createSource(client, request.id, .ext),
        .get_data_device => |request| try self.createDevice(client, request.id, .ext, 1, !self.seat.ownsResource(client, request.seat)),
        .destroy => {},
    }
}

fn dispatchWlrManager(context: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    const self: *DataControlGlobal = @ptrCast(@alignCast(context));
    const version = (try client.connection.objectForHandle(resource, &generated.zwlr_data_control_manager_v1)).version;
    switch (try generated.zwlr_data_control_manager_v1_types.decodeRequest(&client.connection, resource, message)) {
        .create_data_source => |request| try self.createSource(client, request.id, .wlr),
        .get_data_device => |request| try self.createDevice(client, request.id, .wlr, version, !self.seat.ownsResource(client, request.seat)),
        .destroy => {},
    }
}

fn createSource(self: *DataControlGlobal, client: *Server.Client, id: u32, protocol: Protocol) !void {
    const source = self.allocator.create(Source) catch return client.postNoMemory();
    var registered = false;
    errdefer if (!registered) self.allocator.destroy(source);
    self.sources.ensureUnusedCapacity(self.allocator, 1) catch return client.postNoMemory();
    source.* = .{
        .owner = self,
        .client = client,
        .resource = undefined,
        .protocol = protocol,
        .callbacks = .{ .context = source, .mime_types = sourceMimes, .send = sourceSend, .cancel = sourceCancel },
    };
    source.resource = switch (protocol) {
        .ext => client.createResource(id, &generated.ext_data_control_source_v1, 1, .{ .context = source, .dispatch = dispatchExtSource, .destroy = destroySource }),
        .wlr => client.createResource(id, &generated.zwlr_data_control_source_v1, 1, .{ .context = source, .dispatch = dispatchWlrSource, .destroy = destroySource }),
    } catch return client.postNoMemory();
    self.sources.appendAssumeCapacity(source);
    registered = true;
}

fn createDevice(self: *DataControlGlobal, client: *Server.Client, id: u32, protocol: Protocol, version: u32, inert: bool) !void {
    const device = self.allocator.create(Device) catch return client.postNoMemory();
    var registered = false;
    errdefer if (!registered) self.allocator.destroy(device);
    self.devices.ensureUnusedCapacity(self.allocator, 1) catch return client.postNoMemory();
    device.* = .{ .owner = self, .client = client, .resource = undefined, .protocol = protocol, .version = version, .inert = inert };
    device.resource = switch (protocol) {
        .ext => client.createResource(id, &generated.ext_data_control_device_v1, 1, .{ .context = device, .dispatch = dispatchExtDevice, .destroy = destroyDevice }),
        .wlr => client.createResource(id, &generated.zwlr_data_control_device_v1, version, .{ .context = device, .dispatch = dispatchWlrDevice, .destroy = destroyDevice }),
    } catch return client.postNoMemory();
    self.devices.appendAssumeCapacity(device);
    registered = true;
    if (inert) (switch (protocol) {
        .ext => generated.ext_data_control_device_v1_types.events.finished(&client.connection, device.resource),
        .wlr => generated.zwlr_data_control_device_v1_types.events.finished(&client.connection, device.resource),
    }) catch return client.postNoMemory();
    if (!inert) {
        self.sendSelection(device, .regular) catch return client.postNoMemory();
        if (device.supportsPrimary()) self.sendSelection(device, .primary) catch return client.postNoMemory();
    }
}

fn dispatchExtSource(context: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    const source: *Source = @ptrCast(@alignCast(context));
    switch (try generated.ext_data_control_source_v1_types.decodeRequest(&client.connection, resource, message)) {
        .offer => |request| try offerMime(source, client, resource, request.mime_type),
        .destroy => {},
    }
}

fn dispatchWlrSource(context: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    const source: *Source = @ptrCast(@alignCast(context));
    switch (try generated.zwlr_data_control_source_v1_types.decodeRequest(&client.connection, resource, message)) {
        .offer => |request| try offerMime(source, client, resource, request.mime_type),
        .destroy => {},
    }
}

fn offerMime(source: *Source, client: *Server.Client, resource: wayring.ObjectHandle, mime: []const u8) !void {
    if (source.used) return client.postError(resource, switch (source.protocol) {
        .ext => @intFromEnum(generated.ext_data_control_source_v1_types.@"error".invalid_offer),
        .wlr => @intFromEnum(generated.zwlr_data_control_source_v1_types.@"error".invalid_offer),
    }, "cannot offer after source use");
    if (source.hasMime(mime)) return;
    const copy = source.owner.allocator.dupe(u8, mime) catch return client.postNoMemory();
    source.mimes.append(source.owner.allocator, copy) catch {
        source.owner.allocator.free(copy);
        return client.postNoMemory();
    };
}

fn dispatchExtDevice(context: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    const device: *Device = @ptrCast(@alignCast(context));
    switch (try generated.ext_data_control_device_v1_types.decodeRequest(&client.connection, resource, message)) {
        .set_selection => |request| try device.owner.set(device, .regular, request.source),
        .set_primary_selection => |request| try device.owner.set(device, .primary, request.source),
        .destroy => {},
    }
}

fn dispatchWlrDevice(context: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    const device: *Device = @ptrCast(@alignCast(context));
    switch (try generated.zwlr_data_control_device_v1_types.decodeRequest(&client.connection, resource, message)) {
        .set_selection => |request| try device.owner.set(device, .regular, request.source),
        .set_primary_selection => |request| try device.owner.set(device, .primary, request.source),
        .destroy => {},
    }
}

fn set(self: *DataControlGlobal, device: *Device, kind: Kind, id: ?u32) !void {
    if (device.inert) return;
    const source: ?*Source = if (id) |value| source: {
        const object = device.client.connection.object(value) orelse return;
        const context = switch (device.protocol) {
            .ext => try device.client.resourceContext(.{ .id = value, .generation = object.generation }, &generated.ext_data_control_source_v1),
            .wlr => try device.client.resourceContext(.{ .id = value, .generation = object.generation }, &generated.zwlr_data_control_source_v1),
        };
        const candidate: *Source = @ptrCast(@alignCast(context));
        if (candidate.owner != self or candidate.client != device.client or candidate.protocol != device.protocol) return;
        if (candidate.used) return device.client.postError(device.resource, switch (device.protocol) {
            .ext => @intFromEnum(generated.ext_data_control_device_v1_types.@"error".used_source),
            .wlr => @intFromEnum(generated.zwlr_data_control_device_v1_types.@"error".used_source),
        }, "data-control source was already used");
        candidate.used = true;
        break :source candidate;
    } else null;
    switch (kind) {
        .regular => self.regular.setExternalSelection(if (source) |item| &item.callbacks else null),
        .primary => self.primary.setExternalSelection(if (source) |item| &item.callbacks else null),
    }
}

fn dispatchExtOffer(context: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    const offer: *Offer = @ptrCast(@alignCast(context));
    switch (try generated.ext_data_control_offer_v1_types.decodeRequest(&client.connection, resource, message)) {
        .receive => |request| try receiveOffer(offer, message, request.fd, request.mime_type),
        .destroy => {},
    }
}

fn dispatchWlrOffer(context: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    const offer: *Offer = @ptrCast(@alignCast(context));
    switch (try generated.zwlr_data_control_offer_v1_types.decodeRequest(&client.connection, resource, message)) {
        .receive => |request| try receiveOffer(offer, message, request.fd, request.mime_type),
        .destroy => {},
    }
}

fn receiveOffer(offer: *Offer, message: *wayring.Message, fd_index: usize, mime: []const u8) !void {
    const fd = try message.takeFd(fd_index);
    var owned = true;
    defer if (owned) {
        _ = linux.close(fd);
    };
    const device = offer.device orelse return;
    if (device.inert or device.client.state != .active or offer.generation != offer.owner.generation(offer.kind) or !offer.owner.hasMime(offer.kind, mime)) return;
    offer.owner.send(offer.kind, mime, fd) catch return;
    owned = false;
}

fn sendSelection(self: *DataControlGlobal, device: *Device, kind: Kind) !void {
    if (!self.has(kind)) return self.selectionEvent(device, kind, null);
    const offer = try self.allocator.create(Offer);
    var registered = false;
    errdefer if (!registered) self.allocator.destroy(offer);
    try self.offers.ensureUnusedCapacity(self.allocator, 1);
    offer.* = .{ .owner = self, .client = device.client, .resource = undefined, .protocol = device.protocol, .device = device, .kind = kind, .generation = self.generation(kind) };
    offer.resource = switch (device.protocol) {
        .ext => try device.client.createServerResource(&generated.ext_data_control_offer_v1, 1, .{ .context = offer, .dispatch = dispatchExtOffer, .destroy = destroyOffer }),
        .wlr => try device.client.createServerResource(&generated.zwlr_data_control_offer_v1, 1, .{ .context = offer, .dispatch = dispatchWlrOffer, .destroy = destroyOffer }),
    };
    self.offers.appendAssumeCapacity(offer);
    registered = true;
    switch (device.protocol) {
        .ext => try generated.ext_data_control_device_v1_types.events.data_offer(&device.client.connection, device.resource, offer.resource),
        .wlr => try generated.zwlr_data_control_device_v1_types.events.data_offer(&device.client.connection, device.resource, offer.resource),
    }
    for (self.mimes(kind)) |mime| switch (device.protocol) {
        .ext => try generated.ext_data_control_offer_v1_types.events.offer(&device.client.connection, offer.resource, mime),
        .wlr => try generated.zwlr_data_control_offer_v1_types.events.offer(&device.client.connection, offer.resource, mime),
    };
    try self.selectionEvent(device, kind, offer.resource);
}

fn selectionEvent(_: *DataControlGlobal, device: *Device, kind: Kind, offer: ?wayring.ObjectHandle) !void {
    switch (device.protocol) {
        .ext => switch (kind) {
            .regular => try generated.ext_data_control_device_v1_types.events.selection(&device.client.connection, device.resource, offer),
            .primary => try generated.ext_data_control_device_v1_types.events.primary_selection(&device.client.connection, device.resource, offer),
        },
        .wlr => switch (kind) {
            .regular => try generated.zwlr_data_control_device_v1_types.events.selection(&device.client.connection, device.resource, offer),
            .primary => try generated.zwlr_data_control_device_v1_types.events.primary_selection(&device.client.connection, device.resource, offer),
        },
    }
}
fn has(self: *DataControlGlobal, kind: Kind) bool {
    return switch (kind) {
        .regular => self.regular.hasSelection(),
        .primary => self.primary.hasSelection(),
    };
}
fn generation(self: *DataControlGlobal, kind: Kind) u64 {
    return switch (kind) {
        .regular => self.regular.selectionGeneration(),
        .primary => self.primary.selectionGeneration(),
    };
}
fn mimes(self: *DataControlGlobal, kind: Kind) []const []const u8 {
    return switch (kind) {
        .regular => self.regular.selectionMimeTypes(),
        .primary => self.primary.selectionMimeTypes(),
    };
}
fn hasMime(self: *DataControlGlobal, kind: Kind, mime: []const u8) bool {
    for (self.mimes(kind)) |item| if (std.mem.eql(u8, item, mime)) return true;
    return false;
}
fn send(self: *DataControlGlobal, kind: Kind, mime: []const u8, fd: std.posix.fd_t) !void {
    return switch (kind) {
        .regular => self.regular.sendSelection(mime, fd),
        .primary => self.primary.sendSelection(mime, fd),
    };
}

fn changed(self: *DataControlGlobal, kind: Kind) void {
    for (self.devices.items) |device| if (!device.inert and device.client.state == .active and (kind != .primary or device.supportsPrimary())) self.sendSelection(device, kind) catch {
        device.client.postNoMemory() catch {};
    };
}
fn offered(self: *DataControlGlobal, kind: Kind, mime: []const u8) void {
    const current = self.generation(kind);
    for (self.offers.items) |offer| if (offer.device != null and offer.kind == kind and offer.generation == current and offer.client.state == .active) (switch (offer.protocol) {
        .ext => generated.ext_data_control_offer_v1_types.events.offer(&offer.client.connection, offer.resource, mime),
        .wlr => generated.zwlr_data_control_offer_v1_types.events.offer(&offer.client.connection, offer.resource, mime),
    }) catch offer.client.postNoMemory() catch {};
}
fn regularChanged(context: *anyopaque) void {
    const self: *DataControlGlobal = @ptrCast(@alignCast(context));
    self.changed(.regular);
}
fn primaryChanged(context: *anyopaque) void {
    const self: *DataControlGlobal = @ptrCast(@alignCast(context));
    self.changed(.primary);
}
fn regularOffered(context: *anyopaque, mime: []const u8) void {
    const self: *DataControlGlobal = @ptrCast(@alignCast(context));
    self.offered(.regular, mime);
}
fn primaryOffered(context: *anyopaque, mime: []const u8) void {
    const self: *DataControlGlobal = @ptrCast(@alignCast(context));
    self.offered(.primary, mime);
}

fn sourceMimes(context: *anyopaque) []const []const u8 {
    const source: *Source = @ptrCast(@alignCast(context));
    return source.mimes.items;
}
fn sourceSend(context: *anyopaque, mime: []const u8, fd: std.posix.fd_t) !void {
    const source: *Source = @ptrCast(@alignCast(context));
    if (source.client.state != .active or !source.hasMime(mime)) return error.InactiveSource;
    (switch (source.protocol) {
        .ext => generated.ext_data_control_source_v1_types.events.send(&source.client.connection, source.resource, mime, fd),
        .wlr => generated.zwlr_data_control_source_v1_types.events.send(&source.client.connection, source.resource, mime, fd),
    }) catch return source.client.postNoMemory();
}
fn sourceCancel(context: *anyopaque) !void {
    const source: *Source = @ptrCast(@alignCast(context));
    if (source.cancelled or source.client.state != .active) return;
    source.cancelled = true;
    (switch (source.protocol) {
        .ext => generated.ext_data_control_source_v1_types.events.cancelled(&source.client.connection, source.resource),
        .wlr => generated.zwlr_data_control_source_v1_types.events.cancelled(&source.client.connection, source.resource),
    }) catch return source.client.postNoMemory();
}

fn destroySource(context: *anyopaque, _: *Server.Client, _: wayring.ObjectHandle) void {
    const source: *Source = @ptrCast(@alignCast(context));
    source.owner.regular.externalSourceDestroyed(&source.callbacks);
    source.owner.primary.externalSourceDestroyed(&source.callbacks);
    remove(Source, &source.owner.sources, source);
    for (source.mimes.items) |mime| source.owner.allocator.free(mime);
    source.mimes.deinit(source.owner.allocator);
    source.owner.allocator.destroy(source);
}
fn destroyDevice(context: *anyopaque, _: *Server.Client, _: wayring.ObjectHandle) void {
    const device: *Device = @ptrCast(@alignCast(context));
    for (device.owner.offers.items) |offer| {
        if (offer.device == device) offer.device = null;
    }
    remove(Device, &device.owner.devices, device);
    device.owner.allocator.destroy(device);
}
fn destroyOffer(context: *anyopaque, _: *Server.Client, _: wayring.ObjectHandle) void {
    const offer: *Offer = @ptrCast(@alignCast(context));
    remove(Offer, &offer.owner.offers, offer);
    offer.owner.allocator.destroy(offer);
}
fn remove(comptime T: type, list: *std.ArrayList(*T), item: *T) void {
    for (list.items, 0..) |candidate, index| if (candidate == item) {
        _ = list.swapRemove(index);
        return;
    };
    unreachable;
}

test "ext data control advertises v1 and children outlive their manager" {
    const core = @import("wayring-core");
    const allocator = std.testing.allocator;
    var server = Server.init(allocator);
    defer server.deinit();
    var transport: @import("wayring-server-uring") = undefined;
    var security_context: SecurityContextGlobal = undefined;
    try security_context.init(allocator, &server, &transport);
    defer security_context.deinit();
    var seat: SeatGlobal = undefined;
    try seat.init(allocator, &server, "default", SeatGlobal.Capability.keyboard, null);
    defer seat.deinit();
    var regular: DataDeviceGlobal = undefined;
    try regular.init(allocator, &server, &seat);
    defer regular.deinit();
    var primary: PrimarySelectionGlobal = undefined;
    try primary.init(allocator, &server, &seat);
    defer primary.deinit();
    var control: DataControlGlobal = undefined;
    try control.init(
        allocator,
        &server,
        &seat,
        &regular,
        &primary,
        &security_context,
    );
    defer control.deinit();

    const client = try server.createClient();
    defer server.destroyClient(client) catch unreachable;
    var peer = wayring.Connection.init(allocator, .client, wayring.default_max_frame_size);
    defer peer.deinit();
    _ = try core.bootstrapDisplay(&peer);
    const registry: wayring.ObjectHandle = .{ .id = 2, .generation = try core.getRegistry(&peer, 2) };
    try transferTest(&peer, &client.connection, client);
    try transferTest(&client.connection, &peer, null);
    try client.outputDrained();

    var manager_name: u32 = 0;
    var seat_name: u32 = 0;
    var regular_name: u32 = 0;
    var regular_version: u32 = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const event = try core.decodeRegistryEvent(&message, registry.id);
        if (event != .global) continue;
        if (std.mem.eql(u8, event.global.interface, generated.ext_data_control_manager_v1.name)) {
            manager_name = event.global.name;
            try std.testing.expectEqual(@as(u32, 1), event.global.version);
        } else if (std.mem.eql(u8, event.global.interface, generated.wl_seat.name)) {
            seat_name = event.global.name;
        } else if (std.mem.eql(u8, event.global.interface, generated.wl_data_device_manager.name)) {
            regular_name = event.global.name;
            regular_version = event.global.version;
        }
    }
    try std.testing.expect(manager_name != 0 and seat_name != 0 and regular_name != 0);
    const seat_handle: wayring.ObjectHandle = .{ .id = 3, .generation = try core.bind(&peer, registry.id, seat_name, generated.wl_seat.name, 1, 3, &generated.wl_seat) };
    const manager: wayring.ObjectHandle = .{ .id = 4, .generation = try core.bind(&peer, registry.id, manager_name, generated.ext_data_control_manager_v1.name, 1, 4, &generated.ext_data_control_manager_v1) };
    const regular_manager: wayring.ObjectHandle = .{ .id = 5, .generation = try core.bind(&peer, registry.id, regular_name, generated.wl_data_device_manager.name, regular_version, 5, &generated.wl_data_device_manager) };
    const source = try generated.ext_data_control_manager_v1_types.requests.create_data_source(&peer, manager);
    const device = try generated.ext_data_control_manager_v1_types.requests.get_data_device(&peer, manager, seat_handle);
    const regular_device = try generated.wl_data_device_manager_types.requests.get_data_device(&peer, regular_manager, seat_handle);
    const foreign_seat = try peer.allocateObject(&generated.wl_seat, 1);
    _ = try client.createResource(foreign_seat.id, &generated.wl_seat, 1, .{ .context = &control });
    const finished_device = try generated.ext_data_control_manager_v1_types.requests.get_data_device(&peer, manager, foreign_seat);
    try generated.ext_data_control_manager_v1_types.requests.destroy(&peer, manager);
    try transferTest(&peer, &client.connection, client);
    try transferTest(&client.connection, &peer, null);
    try client.outputDrained();

    var null_events: usize = 0;
    var got_finished = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == 1) {
            _ = try core.decodeDisplayEvent(&message);
            continue;
        }
        if (message.object_id == seat_handle.id) {
            _ = try generated.wl_seat_types.decodeEvent(&peer, seat_handle, &message);
            continue;
        }
        const target = if (message.object_id == device.id)
            device
        else if (message.object_id == finished_device.id)
            finished_device
        else
            return error.UnexpectedDataControlSetupEvent;
        switch (try generated.ext_data_control_device_v1_types.decodeEvent(&peer, target, &message)) {
            .selection => |event| {
                try std.testing.expectEqual(device.id, target.id);
                try std.testing.expect(event.id == null);
                null_events += 1;
            },
            .primary_selection => |event| {
                try std.testing.expectEqual(device.id, target.id);
                try std.testing.expect(event.id == null);
                null_events += 1;
            },
            .finished => {
                try std.testing.expectEqual(finished_device.id, target.id);
                got_finished = true;
            },
            .data_offer => return error.UnexpectedDataControlEvent,
        }
    }
    try std.testing.expectEqual(@as(usize, 2), null_events);
    try std.testing.expect(got_finished);

    // Child requests still dispatch after the manager resource is gone, and
    // data-control observes selections without keyboard focus.
    try generated.ext_data_control_source_v1_types.requests.offer(&peer, source, "text/plain");
    try generated.ext_data_control_device_v1_types.requests.set_selection(&peer, device, source);
    try transferTest(&peer, &client.connection, client);
    try std.testing.expectEqual(@as(usize, 1), control.sources.items.len);
    try std.testing.expectEqual(@as(usize, 2), control.devices.items.len);
    try transferTest(&client.connection, &peer, null);
    try client.outputDrained();

    var control_offer: ?wayring.ObjectHandle = null;
    var got_control_mime = false;
    var got_control_selection = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == device.id) {
            switch (try generated.ext_data_control_device_v1_types.decodeEvent(&peer, device, &message)) {
                .data_offer => |event| {
                    const offer: wayring.ObjectHandle = .{
                        .id = event.id,
                        .generation = try peer.registerObject(event.id, &generated.ext_data_control_offer_v1, 1),
                    };
                    control_offer = offer;
                    try peer.resumeParsing();
                },
                .selection => |event| {
                    try std.testing.expectEqual(control_offer.?.id, event.id.?);
                    got_control_selection = true;
                },
                else => return error.UnexpectedDataControlEvent,
            }
        } else if (control_offer) |offer| {
            if (message.object_id != offer.id) return error.UnexpectedDataControlEvent;
            switch (try generated.ext_data_control_offer_v1_types.decodeEvent(&peer, offer, &message)) {
                .offer => |event| {
                    try std.testing.expectEqualStrings("text/plain", event.mime_type);
                    got_control_mime = true;
                },
            }
        } else return error.UnexpectedDataControlEvent;
    }
    try std.testing.expect(got_control_mime and got_control_selection);

    // Focusing the ordinary clipboard later creates an interoperable wl offer.
    try regular.setKeyboardFocus(client);
    try transferTest(&client.connection, &peer, null);
    try client.outputDrained();
    var regular_offer: ?wayring.ObjectHandle = null;
    var got_regular_mime = false;
    var got_regular_selection = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == regular_device.id) {
            switch (try generated.wl_data_device_types.decodeEvent(&peer, regular_device, &message)) {
                .data_offer => |event| {
                    const offer: wayring.ObjectHandle = .{
                        .id = event.id,
                        .generation = try peer.registerObject(event.id, &generated.wl_data_offer, regular_version),
                    };
                    regular_offer = offer;
                    try peer.resumeParsing();
                },
                .selection => |event| {
                    try std.testing.expectEqual(regular_offer.?.id, event.id.?);
                    got_regular_selection = true;
                },
                else => return error.UnexpectedRegularSelectionEvent,
            }
        } else if (regular_offer) |offer| {
            if (message.object_id != offer.id) return error.UnexpectedRegularSelectionEvent;
            switch (try generated.wl_data_offer_types.decodeEvent(&peer, offer, &message)) {
                .offer => |event| {
                    try std.testing.expectEqualStrings("text/plain", event.mime_type);
                    got_regular_mime = true;
                },
                else => return error.UnexpectedRegularSelectionEvent,
            }
        } else return error.UnexpectedRegularSelectionEvent;
    }
    try std.testing.expect(got_regular_mime and got_regular_selection);

    var pipe: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) != .SUCCESS)
        return error.PipeFailed;
    defer _ = linux.close(pipe[0]);
    var write_owned = true;
    defer if (write_owned) {
        _ = linux.close(pipe[1]);
    };
    try generated.wl_data_offer_types.requests.receive(&peer, regular_offer.?, "text/plain", pipe[1]);
    write_owned = false;
    try transferTest(&peer, &client.connection, client);
    try transferTest(&client.connection, &peer, null);
    try client.outputDrained();
    var send_message = peer.popMessage() orelse return error.MissingDataControlSend;
    defer send_message.deinit();
    const send_event = try generated.ext_data_control_source_v1_types.decodeEvent(&peer, source, &send_message);
    const transfer_fd = switch (send_event) {
        .send => |event| transfer: {
            try std.testing.expectEqualStrings("text/plain", event.mime_type);
            break :transfer try send_message.takeFd(event.fd);
        },
        else => return error.UnexpectedDataControlSourceEvent,
    };
    const payload = "native data control";
    const written = linux.write(transfer_fd, payload.ptr, payload.len);
    if (linux.errno(written) != .SUCCESS) return error.WriteFailed;
    try std.testing.expectEqual(payload.len, written);
    _ = linux.close(transfer_fd);
    var received: [32]u8 = undefined;
    const received_len = linux.read(pipe[0], &received, received.len);
    if (linux.errno(received_len) != .SUCCESS) return error.ReadFailed;
    try std.testing.expectEqualStrings(payload, received[0..received_len]);

    // Clearing cancels once and makes the old ordinary offer inert.
    try generated.ext_data_control_device_v1_types.requests.set_selection(&peer, device, null);
    try transferTest(&peer, &client.connection, client);
    try transferTest(&client.connection, &peer, null);
    try client.outputDrained();
    var cancellation_count: usize = 0;
    var got_regular_clear = false;
    var got_control_clear = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == source.id) {
            if ((try generated.ext_data_control_source_v1_types.decodeEvent(&peer, source, &message)) != .cancelled)
                return error.UnexpectedDataControlSourceEvent;
            cancellation_count += 1;
        } else if (message.object_id == regular_device.id) {
            switch (try generated.wl_data_device_types.decodeEvent(&peer, regular_device, &message)) {
                .selection => |event| {
                    try std.testing.expect(event.id == null);
                    got_regular_clear = true;
                },
                else => return error.UnexpectedRegularSelectionEvent,
            }
        } else if (message.object_id == device.id) {
            switch (try generated.ext_data_control_device_v1_types.decodeEvent(&peer, device, &message)) {
                .selection => |event| {
                    try std.testing.expect(event.id == null);
                    got_control_clear = true;
                },
                else => return error.UnexpectedDataControlEvent,
            }
        } else return error.UnexpectedDataControlEvent;
    }
    try std.testing.expectEqual(@as(usize, 1), cancellation_count);
    try std.testing.expect(got_regular_clear and got_control_clear);

    var stale_pipe: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&stale_pipe, .{ .CLOEXEC = true })) != .SUCCESS)
        return error.PipeFailed;
    defer _ = linux.close(stale_pipe[0]);
    var stale_write_owned = true;
    defer if (stale_write_owned) {
        _ = linux.close(stale_pipe[1]);
    };
    try generated.wl_data_offer_types.requests.receive(&peer, regular_offer.?, "text/plain", stale_pipe[1]);
    stale_write_owned = false;
    try transferTest(&peer, &client.connection, client);
    try transferTest(&client.connection, &peer, null);
    try client.outputDrained();
    try std.testing.expect(peer.popMessage() == null);
    const stale_len = linux.read(stale_pipe[0], &received, received.len);
    if (linux.errno(stale_len) != .SUCCESS) return error.ReadFailed;
    try std.testing.expectEqual(@as(usize, 0), stale_len);

    // The source's one use is shared by regular and primary selection.
    try generated.ext_data_control_device_v1_types.requests.set_primary_selection(&peer, device, source);
    try std.testing.expectError(error.ProtocolError, transferTest(&peer, &client.connection, client));
    try std.testing.expectEqual(Server.ClientState.protocol_error, client.state);
    try transferTest(&client.connection, &peer, null);
    try client.outputDrained();
    var got_used_source = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id != 1) continue;
        switch (try core.decodeDisplayEvent(&message)) {
            .error_event => |event| if (event.object_id == device.id and event.code == @intFromEnum(generated.ext_data_control_device_v1_types.@"error".used_source)) {
                got_used_source = true;
            },
            .delete_id => {},
        }
    }
    try std.testing.expect(got_used_source);
}

test "wlr data control gates primary selection at v2 and relays data" {
    const core = @import("wayring-core");
    const allocator = std.testing.allocator;
    var server = Server.init(allocator);
    defer server.deinit();
    var transport: @import("wayring-server-uring") = undefined;
    var security_context: SecurityContextGlobal = undefined;
    try security_context.init(allocator, &server, &transport);
    defer security_context.deinit();
    var seat: SeatGlobal = undefined;
    try seat.init(allocator, &server, "default", SeatGlobal.Capability.keyboard, null);
    defer seat.deinit();
    var regular: DataDeviceGlobal = undefined;
    try regular.init(allocator, &server, &seat);
    defer regular.deinit();
    var primary: PrimarySelectionGlobal = undefined;
    try primary.init(allocator, &server, &seat);
    defer primary.deinit();
    var control: DataControlGlobal = undefined;
    try control.init(
        allocator,
        &server,
        &seat,
        &regular,
        &primary,
        &security_context,
    );
    defer control.deinit();

    const client = try server.createClient();
    defer server.destroyClient(client) catch unreachable;
    var peer = wayring.Connection.init(allocator, .client, wayring.default_max_frame_size);
    defer peer.deinit();
    _ = try core.bootstrapDisplay(&peer);
    const registry: wayring.ObjectHandle = .{ .id = 2, .generation = try core.getRegistry(&peer, 2) };
    try transferTest(&peer, &client.connection, client);
    try transferTest(&client.connection, &peer, null);
    try client.outputDrained();

    var manager_name: u32 = 0;
    var seat_name: u32 = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const event = try core.decodeRegistryEvent(&message, registry.id);
        if (event != .global) continue;
        if (std.mem.eql(u8, event.global.interface, generated.zwlr_data_control_manager_v1.name)) {
            manager_name = event.global.name;
            try std.testing.expectEqual(@as(u32, 2), event.global.version);
        } else if (std.mem.eql(u8, event.global.interface, generated.wl_seat.name)) {
            seat_name = event.global.name;
        }
    }
    try std.testing.expect(manager_name != 0 and seat_name != 0);

    const seat_handle: wayring.ObjectHandle = .{ .id = 3, .generation = try core.bind(&peer, registry.id, seat_name, generated.wl_seat.name, 1, 3, &generated.wl_seat) };
    const manager_v1: wayring.ObjectHandle = .{ .id = 4, .generation = try core.bind(&peer, registry.id, manager_name, generated.zwlr_data_control_manager_v1.name, 1, 4, &generated.zwlr_data_control_manager_v1) };
    const manager_v2: wayring.ObjectHandle = .{ .id = 5, .generation = try core.bind(&peer, registry.id, manager_name, generated.zwlr_data_control_manager_v1.name, 2, 5, &generated.zwlr_data_control_manager_v1) };
    const device_v1 = try generated.zwlr_data_control_manager_v1_types.requests.get_data_device(&peer, manager_v1, seat_handle);
    const device_v2 = try generated.zwlr_data_control_manager_v1_types.requests.get_data_device(&peer, manager_v2, seat_handle);
    const source = try generated.zwlr_data_control_manager_v1_types.requests.create_data_source(&peer, manager_v2);
    try generated.zwlr_data_control_manager_v1_types.requests.destroy(&peer, manager_v1);
    try generated.zwlr_data_control_manager_v1_types.requests.destroy(&peer, manager_v2);
    try transferTest(&peer, &client.connection, client);
    try transferTest(&client.connection, &peer, null);
    try client.outputDrained();

    var v1_null_events: usize = 0;
    var v2_null_events: usize = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == 1) {
            _ = try core.decodeDisplayEvent(&message);
        } else if (message.object_id == seat_handle.id) {
            _ = try generated.wl_seat_types.decodeEvent(&peer, seat_handle, &message);
        } else {
            const device = if (message.object_id == device_v1.id)
                device_v1
            else if (message.object_id == device_v2.id)
                device_v2
            else
                return error.UnexpectedWlrDataControlSetupEvent;
            switch (try generated.zwlr_data_control_device_v1_types.decodeEvent(&peer, device, &message)) {
                .selection => |event| {
                    try std.testing.expect(event.id == null);
                    if (device.id == device_v1.id) v1_null_events += 1 else v2_null_events += 1;
                },
                .primary_selection => |event| {
                    try std.testing.expectEqual(device_v2.id, device.id);
                    try std.testing.expect(event.id == null);
                    v2_null_events += 1;
                },
                else => return error.UnexpectedWlrDataControlSetupEvent,
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 1), v1_null_events);
    try std.testing.expectEqual(@as(usize, 2), v2_null_events);

    // Children remain functional after both managers are destroyed. A v2
    // source updates the same authoritative primary-selection state used by
    // the stable protocol, while the v1 device receives no primary events.
    try generated.zwlr_data_control_source_v1_types.requests.offer(&peer, source, "text/plain");
    try generated.zwlr_data_control_device_v1_types.requests.set_primary_selection(&peer, device_v2, source);
    try transferTest(&peer, &client.connection, client);
    try std.testing.expect(primary.hasSelection());
    try std.testing.expectEqual(@as(usize, 1), primary.selectionMimeTypes().len);
    try std.testing.expectEqualStrings("text/plain", primary.selectionMimeTypes()[0]);
    try transferTest(&client.connection, &peer, null);
    try client.outputDrained();

    var offer: ?wayring.ObjectHandle = null;
    var got_mime = false;
    var got_primary = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == device_v1.id) return error.UnexpectedV1PrimaryEvent;
        if (message.object_id == device_v2.id) {
            switch (try generated.zwlr_data_control_device_v1_types.decodeEvent(&peer, device_v2, &message)) {
                .data_offer => |event| {
                    offer = .{
                        .id = event.id,
                        .generation = try peer.registerObject(event.id, &generated.zwlr_data_control_offer_v1, 1),
                    };
                    try peer.resumeParsing();
                },
                .primary_selection => |event| {
                    try std.testing.expectEqual(offer.?.id, event.id.?);
                    got_primary = true;
                },
                else => return error.UnexpectedWlrDataControlEvent,
            }
        } else if (offer) |value| {
            if (message.object_id != value.id) return error.UnexpectedWlrDataControlEvent;
            switch (try generated.zwlr_data_control_offer_v1_types.decodeEvent(&peer, value, &message)) {
                .offer => |event| {
                    try std.testing.expectEqualStrings("text/plain", event.mime_type);
                    got_mime = true;
                },
            }
        } else return error.UnexpectedWlrDataControlEvent;
    }
    try std.testing.expect(got_mime and got_primary);

    var pipe: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) != .SUCCESS)
        return error.PipeFailed;
    defer _ = linux.close(pipe[0]);
    var write_owned = true;
    defer if (write_owned) {
        _ = linux.close(pipe[1]);
    };
    try generated.zwlr_data_control_offer_v1_types.requests.receive(&peer, offer.?, "text/plain", pipe[1]);
    write_owned = false;
    try transferTest(&peer, &client.connection, client);
    try transferTest(&client.connection, &peer, null);
    try client.outputDrained();
    var send_message = peer.popMessage() orelse return error.MissingWlrDataControlSend;
    defer send_message.deinit();
    const send_event = try generated.zwlr_data_control_source_v1_types.decodeEvent(&peer, source, &send_message);
    const transfer_fd = switch (send_event) {
        .send => |event| transfer: {
            try std.testing.expectEqualStrings("text/plain", event.mime_type);
            break :transfer try send_message.takeFd(event.fd);
        },
        else => return error.UnexpectedWlrDataControlSourceEvent,
    };
    const payload = "wlr data control";
    const written = linux.write(transfer_fd, payload.ptr, payload.len);
    if (linux.errno(written) != .SUCCESS) return error.WriteFailed;
    try std.testing.expectEqual(payload.len, written);
    _ = linux.close(transfer_fd);
    var received: [32]u8 = undefined;
    const received_len = linux.read(pipe[0], &received, received.len);
    if (linux.errno(received_len) != .SUCCESS) return error.ReadFailed;
    try std.testing.expectEqualStrings(payload, received[0..received_len]);
}

fn transferTest(sender: *wayring.Connection, receiver: *wayring.Connection, server_client: ?*Server.Client) !void {
    while (sender.nextBatch()) |batch| {
        var duplicated: [wayring.max_fds_per_batch]i32 = undefined;
        var count: usize = 0;
        errdefer {
            for (duplicated[0..count]) |fd| _ = linux.close(fd);
        }
        for (batch.fds) |fd| {
            const result = linux.dup(fd);
            if (linux.errno(result) != .SUCCESS) return error.DuplicateFdFailed;
            duplicated[count] = @intCast(result);
            count += 1;
        }
        const transferred = duplicated[0..count];
        count = 0;
        if (server_client) |client| try client.receive(batch.bytes, transferred) else try receiver.feed(batch.bytes, transferred);
        try sender.acknowledge(batch.token, batch.bytes.len);
    }
}
