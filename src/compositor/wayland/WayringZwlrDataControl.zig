//! Generated privileged WLR data-control protocol adapter.
//!
//! This owns wire resources only; DataDevice owns all selection semantics.

const WayringZwlrDataControl = @This();

const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("wayring-protocol");
const wayring = @import("wayring");
const ClientRegistry = @import("../ClientRegistry.zig");
const DataDevice = @import("../DataDevice.zig");
const SeatAuthority = @import("../SeatAuthority.zig");
const SeatDelivery = @import("../SeatDelivery.zig");
const SurfaceRegistry = @import("../SurfaceRegistry.zig");
const WayringClients = @import("WayringClients.zig");
const WayringCompositor = @import("WayringCompositor.zig");
const WayringProfile = @import("WayringProfile.zig");
const WayringSeatAdapter = @import("WayringSeatAdapter.zig");
const wire = wayring.wire;

const Manager = struct { owner: *WayringZwlrDataControl, client: *wayring.server.Client, resource: protocol.zwlr_data_control_manager_v1.Resource };
const Source = struct { owner: *WayringZwlrDataControl, client: *wayring.server.Client, resource: protocol.zwlr_data_control_source_v1.Resource, id: DataDevice.ControlSourceId };
const Device = struct { owner: *WayringZwlrDataControl, client: *wayring.server.Client, resource: protocol.zwlr_data_control_device_v1.Resource, id: DataDevice.ControlDeviceId };
const Offer = struct { owner: *WayringZwlrDataControl, client: *wayring.server.Client, resource: protocol.zwlr_data_control_offer_v1.Resource, id: DataDevice.ControlOfferId, device: ?*Device, published: bool = false };
const Staged = struct { client: *wayring.server.Client, events: []wayring.server.Client.PreparedEvent, values: []wire.Value, offers: []const *Offer, maximum_bytes: usize };
const Prepared = struct { client: *wayring.server.Client, batch: wire.PreparedBatch, events: []wayring.server.Client.PreparedEvent };

allocator: std.mem.Allocator,
protocol_server: *wayring.server.Server,
clients: *WayringClients,
seat: *WayringSeatAdapter,
canonical: *DataDevice,
authorized_uid: std.os.linux.uid_t,
global: ?*const wayring.server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
sources: std.ArrayList(*Source) = .empty,
devices: std.ArrayList(*Device) = .empty,
offers: std.ArrayList(*Offer) = .empty,
staged: std.ArrayList(Staged) = .empty,
prepared: std.ArrayList(Prepared) = .empty,
stage_failure_after: if (builtin.is_test) ?usize else void = if (builtin.is_test) null else {},
finalize_failure: if (builtin.is_test) bool else void = if (builtin.is_test) false else {},

pub fn init(self: *WayringZwlrDataControl, allocator: std.mem.Allocator, protocol_server: *wayring.server.Server, clients: *WayringClients, seat: *WayringSeatAdapter, canonical: *DataDevice, authorized_uid: std.os.linux.uid_t) void {
    self.* = .{ .allocator = allocator, .protocol_server = protocol_server, .clients = clients, .seat = seat, .canonical = canonical, .authorized_uid = authorized_uid };
}

pub fn deinit(self: *WayringZwlrDataControl) void {
    std.debug.assert(self.global == null and self.managers.items.len == 0 and self.sources.items.len == 0 and self.devices.items.len == 0 and self.offers.items.len == 0 and self.staged.items.len == 0 and self.prepared.items.len == 0);
    self.managers.deinit(self.allocator);
    self.sources.deinit(self.allocator);
    self.devices.deinit(self.allocator);
    self.offers.deinit(self.allocator);
    self.staged.deinit(self.allocator);
    self.prepared.deinit(self.allocator);
    self.* = undefined;
}

pub fn publish(self: *WayringZwlrDataControl) !void {
    std.debug.assert(self.global == null);
    self.global = try self.protocol_server.addGlobalWithOptions(protocol.zwlr_data_control_manager_v1, 2, WayringZwlrDataControl, self, bindManager, .{
        .visibility = .restricted,
    });
}

pub fn unpublish(self: *WayringZwlrDataControl) void {
    const global = self.global orelse unreachable;
    self.protocol_server.removeGlobal(global) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}

/// Suitable for Server.setGlobalFilter. The integration owns filter lifetime.
pub fn globalFilter(self: *WayringZwlrDataControl, client: *const wayring.server.Client, global: *const wayring.server.Server.Global) bool {
    return WayringProfile.securityVisible(self.authorized_uid, client, global);
}

fn bindManager(client: *wayring.server.Client, id: u32, version: u32, self: *WayringZwlrDataControl) !void {
    if (version < 1 or version > 2) return error.InvalidVersion;
    if (!client.isAuthorizedDirectPeer(self.authorized_uid)) return error.Unauthorized;
    try self.managers.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Manager);
    errdefer self.allocator.destroy(value);
    value.* = .{ .owner = self, .client = client, .resource = .init(self.allocator, id, version, .client, client.ownerHooks()) };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Manager, value, managerRequest, null);
    try client.materialize(&value.resource.runtime);
    self.managers.appendAssumeCapacity(value);
}

fn managerRequest(_: *protocol.zwlr_data_control_manager_v1.Resource, request: protocol.zwlr_data_control_manager_v1.Request, value: *Manager) !void {
    switch (request) {
        .create_data_source => |args| try value.owner.createSource(value, args.id),
        .get_data_device => |args| {
            if (value.owner.seat.seatClientIdentity(value.client, args.seat) == null)
                return value.client.postImplementationError(&value.resource.runtime, "data control requires the exact live same-client wl_seat");
            try value.owner.createDevice(value, args.id);
        },
        .destroy => value.owner.destroyManager(value),
    }
}

fn createSource(self: *WayringZwlrDataControl, manager: *Manager, id: u32) !void {
    try self.sources.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Source);
    errdefer self.allocator.destroy(value);
    value.* = undefined;
    const canonical_id = try self.canonical.createControlSource(self.clients.id(manager.client) orelse return error.InvalidClient, .{ .context = value, .send = sourceSend, .target = ignoredTarget, .action = ignoredAction, .cancelled = sourceCancelled, .selection_cancelled = sourceCancelled, .drop_performed = ignored, .finished = ignored });
    errdefer self.canonical.destroyControlSource(canonical_id);
    value.* = .{ .owner = self, .client = manager.client, .resource = .init(self.allocator, id, 1, .client, manager.client.ownerHooks()), .id = canonical_id };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Source, value, sourceRequest, null);
    try manager.client.materialize(&value.resource.runtime);
    self.sources.appendAssumeCapacity(value);
}

fn sourceRequest(_: *protocol.zwlr_data_control_source_v1.Resource, request: protocol.zwlr_data_control_source_v1.Request, value: *Source) !void {
    switch (request) {
        .offer => |args| value.owner.canonical.offerControlMime(value.id, args.mime_type) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SourceAlreadyUsed => value.client.postProtocolError(&value.resource.runtime, @intCast(protocol.zwlr_data_control_source_v1.@"error".invalid_offer), "offer sent after source use"),
            else => {},
        },
        .destroy => value.owner.destroySource(value),
    }
}

fn createDevice(self: *WayringZwlrDataControl, manager: *Manager, id: u32) !void {
    try self.devices.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Device);
    errdefer self.allocator.destroy(value);
    value.* = .{ .owner = self, .client = manager.client, .resource = .init(self.allocator, id, manager.resource.version(), .client, manager.client.ownerHooks()), .id = undefined };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Device, value, deviceRequest, null);
    try manager.client.materialize(&value.resource.runtime);
    value.id = try self.canonical.createControlDevice(
        self.clients.id(manager.client) orelse return error.InvalidClient,
        if (manager.resource.version() >= 2) .{
            .context = value,
            .regular_prepare = regularPrepare,
            .regular = channelCommit,
            .primary_prepare = primaryPrepare,
            .primary = channelCommit,
        } else .{
            .context = value,
            .regular_prepare = regularPrepare,
            .regular = channelCommit,
        },
    );
    errdefer self.canonical.destroyControlDevice(value.id);
    self.devices.appendAssumeCapacity(value);
}

fn deviceRequest(_: *protocol.zwlr_data_control_device_v1.Resource, request: protocol.zwlr_data_control_device_v1.Request, value: *Device) !void {
    switch (request) {
        .set_selection => |args| try value.owner.setSelection(value, args.source, false),
        .destroy => value.owner.destroyDevice(value),
        .set_primary_selection => |args| try value.owner.setSelection(value, args.source, true),
    }
}

fn setSelection(self: *WayringZwlrDataControl, device: *Device, object: ?u32, primary: bool) !void {
    const source = if (object) |id| self.sourceIdentity(device.client, id) orelse return device.client.postImplementationError(&device.resource.runtime, "data-control source is not exact and live") else null;
    const result = if (primary) self.canonical.setControlPrimarySelection(device.id, source) else self.canonical.setControlRegularSelection(device.id, source);
    result catch |err| switch (err) {
        error.OutOfMemory => device.client.postOutOfMemory(&device.resource.runtime, "publishing data-control selection"),
        error.SourceAlreadyUsed => device.client.postProtocolError(&device.resource.runtime, @intCast(protocol.zwlr_data_control_device_v1.@"error".used_source), "data-control source was already used"),
        else => device.client.postImplementationError(&device.resource.runtime, "invalid data-control selection"),
    };
}

fn sourceIdentity(self: *WayringZwlrDataControl, client: *wayring.server.Client, object_id: u32) ?DataDevice.ControlSourceId {
    const installed = client.lookup(object_id) orelse return null;
    for (self.sources.items) |value| if (value.client == client and value.resource.id() == object_id and installed == &value.resource.runtime and value.resource.runtime.state() == .live) return value.id;
    return null;
}

fn createOffer(self: *WayringZwlrDataControl, device: *Device, canonical_id: DataDevice.ControlOfferId) !*Offer {
    try self.offers.ensureUnusedCapacity(self.allocator, 1);
    const id = try device.client.reserveServerId();
    errdefer device.client.rollbackServerId(id);
    const value = try self.allocator.create(Offer);
    errdefer self.allocator.destroy(value);
    value.* = .{ .owner = self, .client = device.client, .resource = .init(self.allocator, id, 1, .server, device.client.ownerHooks()), .id = canonical_id, .device = device };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Offer, value, offerRequest, null);
    try device.client.materializeServer(&value.resource.runtime);
    self.offers.appendAssumeCapacity(value);
    return value;
}

fn regularPrepare(context: *anyopaque, id: ?DataDevice.ControlOfferId) error{OutOfMemory}!void {
    return prepareChannel(context, id, 1);
}
fn primaryPrepare(context: *anyopaque, id: ?DataDevice.ControlOfferId) error{OutOfMemory}!void {
    return prepareChannel(context, id, 3);
}
fn channelCommit(_: *anyopaque, _: ?DataDevice.ControlOfferId) error{OutOfMemory}!void {}

fn prepareChannel(context: *anyopaque, canonical_id: ?DataDevice.ControlOfferId, event_opcode: u16) error{OutOfMemory}!void {
    const device: *Device = @ptrCast(@alignCast(context));
    const id = canonical_id orelse return device.owner.stageEvent(device.client, &device.resource.runtime, event_opcode, &protocol.zwlr_data_control_device_v1.event_messages[event_opcode], &.{.{ .object = null }}, 12, &.{});
    const offer = device.owner.createOffer(device, id) catch return transactionOutOfMemory(device.client, &device.resource.runtime);
    const mimes = device.owner.canonical.controlOfferMimeTypes(id) catch return transactionOutOfMemory(device.client, &device.resource.runtime);
    try device.owner.stageEvent(device.client, &device.resource.runtime, 0, &protocol.zwlr_data_control_device_v1.event_messages[0], &.{.{ .new_id = .{ .typed = offer.resource.id() } }}, 12, &.{offer});
    for (mimes) |mime| {
        const terminated = std.math.add(usize, mime.len, 1) catch return transactionOutOfMemory(device.client, &device.resource.runtime);
        const bytes = std.math.add(usize, 12, std.mem.alignForward(usize, terminated, 4)) catch return transactionOutOfMemory(device.client, &device.resource.runtime);
        if (bytes > wire.max_message_size) return transactionOutOfMemory(device.client, &device.resource.runtime);
        try device.owner.stageEvent(device.client, &offer.resource.runtime, 0, &protocol.zwlr_data_control_offer_v1.event_messages[0], &.{.{ .string = mime }}, bytes, &.{});
    }
    try device.owner.stageEvent(device.client, &device.resource.runtime, event_opcode, &protocol.zwlr_data_control_device_v1.event_messages[event_opcode], &.{.{ .object = offer.resource.id() }}, 12, &.{});
}

fn offerRequest(_: *protocol.zwlr_data_control_offer_v1.Resource, request: protocol.zwlr_data_control_offer_v1.Request, value: *Offer) !void {
    switch (request) {
        .receive => |args| {
            defer _ = std.c.close(args.fd);
            value.owner.canonical.receiveControl(value.id, args.mime_type, args.fd) catch {};
        },
        .destroy => value.owner.destroyOffer(value),
    }
}

pub fn offerRolledBack(context: *anyopaque, id: DataDevice.ControlOfferId) void {
    const self: *WayringZwlrDataControl = @ptrCast(@alignCast(context));
    for (self.offers.items) |offer| if (std.meta.eql(offer.id, id)) return self.destroyOfferResource(offer, false);
}

pub fn offerMimeOffered(context: *anyopaque, id: DataDevice.ControlOfferId, mime: []const u8) void {
    const self: *WayringZwlrDataControl = @ptrCast(@alignCast(context));
    for (self.offers.items) |offer| if (std.meta.eql(offer.id, id)) {
        if (!offer.published) return;
        protocol.zwlr_data_control_offer_v1.@"send:offer"(&offer.resource, mime) catch offer.client.postOutOfMemory(&offer.resource.runtime, "queueing data-control MIME");
        return;
    };
}

pub fn transactionFinalize(context: *anyopaque) error{OutOfMemory}!void {
    const self: *WayringZwlrDataControl = @ptrCast(@alignCast(context));
    std.debug.assert(self.prepared.items.len == 0);
    if (self.staged.items.len == 0) return;
    if (comptime builtin.is_test) if (self.finalize_failure) {
        self.finalize_failure = false;
        return transactionOutOfMemory(self.staged.items[0].client, self.staged.items[0].events[0].resource);
    };
    for (self.staged.items, 0..) |candidate, index| {
        var found = false;
        for (self.prepared.items) |entry| if (entry.client == candidate.client) {
            found = true;
            break;
        };
        if (found) continue;
        var count: usize = 0;
        var bytes: usize = 0;
        for (self.staged.items) |entry| if (entry.client == candidate.client) {
            count = std.math.add(usize, count, entry.events.len) catch return error.OutOfMemory;
            bytes = std.math.add(usize, bytes, entry.maximum_bytes) catch return error.OutOfMemory;
        };
        const events = self.allocator.alloc(wayring.server.Client.PreparedEvent, count) catch return transactionOutOfMemory(candidate.client, candidate.events[0].resource);
        var next: usize = 0;
        for (self.staged.items) |entry| if (entry.client == candidate.client) {
            @memcpy(events[next .. next + entry.events.len], entry.events);
            next += entry.events.len;
        };
        const batch = candidate.client.prepareEvents(bytes) catch {
            self.allocator.free(events);
            return transactionOutOfMemory(candidate.client, self.staged.items[index].events[0].resource);
        };
        self.prepared.append(self.allocator, .{ .client = candidate.client, .batch = batch, .events = events }) catch {
            candidate.client.cancelPreparedEvents(batch);
            self.allocator.free(events);
            return transactionOutOfMemory(candidate.client, candidate.events[0].resource);
        };
    }
}

pub fn transactionCommit(context: *anyopaque) void {
    const self: *WayringZwlrDataControl = @ptrCast(@alignCast(context));
    for (self.prepared.items) |entry| entry.client.emitPreparedEvents(entry.batch, entry.events) catch unreachable;
    for (self.staged.items) |entry| for (entry.offers) |offer| {
        offer.published = true;
    };
    self.clearTransaction(false);
}

pub fn transactionAbort(context: *anyopaque) void {
    const self: *WayringZwlrDataControl = @ptrCast(@alignCast(context));
    self.clearTransaction(true);
}

fn stageEvent(self: *WayringZwlrDataControl, client: *wayring.server.Client, resource: *wayring.server.Resource, opcode: u16, descriptor: *const wire.MessageDescriptor, source_values: []const wire.Value, maximum_bytes: usize, offers: []const *Offer) error{OutOfMemory}!void {
    if (comptime builtin.is_test) if (self.stage_failure_after) |remaining| {
        if (remaining == 0) {
            self.stage_failure_after = null;
            return transactionOutOfMemory(client, resource);
        }
        self.stage_failure_after = remaining - 1;
    };
    const events = self.allocator.alloc(wayring.server.Client.PreparedEvent, 1) catch return transactionOutOfMemory(client, resource);
    errdefer self.allocator.free(events);
    const values = self.allocator.dupe(wire.Value, source_values) catch return transactionOutOfMemory(client, resource);
    errdefer self.allocator.free(values);
    const offer_copy = self.allocator.dupe(*Offer, offers) catch return transactionOutOfMemory(client, resource);
    errdefer self.allocator.free(offer_copy);
    events[0] = .{ .resource = resource, .opcode = opcode, .descriptor = descriptor, .values = values };
    self.staged.append(self.allocator, .{ .client = client, .events = events, .values = values, .offers = offer_copy, .maximum_bytes = maximum_bytes }) catch return transactionOutOfMemory(client, resource);
}

fn clearTransaction(self: *WayringZwlrDataControl, cancel: bool) void {
    for (self.prepared.items) |entry| {
        if (cancel) entry.client.cancelPreparedEvents(entry.batch);
        self.allocator.free(entry.events);
    }
    self.prepared.clearRetainingCapacity();
    for (self.staged.items) |entry| {
        self.allocator.free(entry.events);
        self.allocator.free(entry.values);
        self.allocator.free(entry.offers);
    }
    self.staged.clearRetainingCapacity();
}

fn transactionOutOfMemory(client: *wayring.server.Client, resource: *wayring.server.Resource) error{OutOfMemory} {
    client.postOutOfMemory(resource, "preparing data-control transaction");
    return error.OutOfMemory;
}
fn sourceSend(context: *anyopaque, mime: []const u8, fd: std.posix.fd_t) void {
    const value: *Source = @ptrCast(@alignCast(context));
    protocol.zwlr_data_control_source_v1.@"send:send"(&value.resource, mime, fd) catch value.client.postOutOfMemory(&value.resource.runtime, "queueing data-control transfer");
}
fn sourceCancelled(context: *anyopaque) void {
    const value: *Source = @ptrCast(@alignCast(context));
    protocol.zwlr_data_control_source_v1.@"send:cancelled"(&value.resource) catch value.client.postOutOfMemory(&value.resource.runtime, "queueing data-control cancellation");
}
fn ignored(_: *anyopaque) void {}
fn ignoredTarget(_: *anyopaque, _: ?[]const u8) void {}
fn ignoredAction(_: *anyopaque, _: DataDevice.Actions) void {}

pub fn destroyClientResources(self: *WayringZwlrDataControl, client: *wayring.server.Client) void {
    var i = self.offers.items.len;
    while (i > 0) : (i -= 1) if (self.offers.items[i - 1].client == client) self.destroyOffer(self.offers.items[i - 1]);
    i = self.devices.items.len;
    while (i > 0) : (i -= 1) if (self.devices.items[i - 1].client == client) self.destroyDevice(self.devices.items[i - 1]);
    i = self.sources.items.len;
    while (i > 0) : (i -= 1) if (self.sources.items[i - 1].client == client) self.destroySource(self.sources.items[i - 1]);
    i = self.managers.items.len;
    while (i > 0) : (i -= 1) if (self.managers.items[i - 1].client == client) self.destroyManager(self.managers.items[i - 1]);
}

fn destroyOffer(self: *WayringZwlrDataControl, value: *Offer) void {
    self.destroyOfferResource(value, true);
}
fn destroyOfferResource(self: *WayringZwlrDataControl, value: *Offer, canonical: bool) void {
    for (self.offers.items, 0..) |item, i| if (item == value) {
        _ = self.offers.swapRemove(i);
        break;
    };
    if (canonical) self.canonical.destroyControlOffer(value.id);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}
fn destroyDevice(self: *WayringZwlrDataControl, value: *Device) void {
    for (self.offers.items) |offer| if (offer.device == value) {
        offer.device = null;
    };
    for (self.devices.items, 0..) |item, i| if (item == value) {
        _ = self.devices.swapRemove(i);
        break;
    };
    self.canonical.destroyControlDevice(value.id);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}
fn destroySource(self: *WayringZwlrDataControl, value: *Source) void {
    for (self.sources.items, 0..) |item, i| if (item == value) {
        _ = self.sources.swapRemove(i);
        break;
    };
    self.canonical.destroyControlSource(value.id);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}
fn destroyManager(self: *WayringZwlrDataControl, value: *Manager) void {
    for (self.managers.items, 0..) |item, i| if (item == value) {
        _ = self.managers.swapRemove(i);
        break;
    };
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}

test "WLR data-control v1/v2 descriptors and errors are exact" {
    const manager = protocol.zwlr_data_control_manager_v1;
    const device = protocol.zwlr_data_control_device_v1;
    const source = protocol.zwlr_data_control_source_v1;
    const offer = protocol.zwlr_data_control_offer_v1;
    try std.testing.expectEqual(@as(u32, 2), manager.interface.version);
    try expectNames(&manager.request_messages, &.{ "create_data_source", "get_data_device", "destroy" });
    try expectNames(&manager.event_messages, &.{});
    try expectNames(&device.request_messages, &.{ "set_selection", "destroy", "set_primary_selection" });
    try expectNames(&device.event_messages, &.{ "data_offer", "selection", "finished", "primary_selection" });
    try expectNames(&source.request_messages, &.{ "offer", "destroy" });
    try expectNames(&source.event_messages, &.{ "send", "cancelled" });
    try expectNames(&offer.request_messages, &.{ "receive", "destroy" });
    try expectNames(&offer.event_messages, &.{"offer"});
    try std.testing.expectEqual(@as(i64, 1), device.@"error".used_source);
    try std.testing.expectEqual(@as(i64, 1), source.@"error".invalid_offer);
}

fn expectNames(messages: anytype, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, messages.len);
    for (messages, expected) |message, name| try std.testing.expectEqualStrings(name, message.name);
}

const ControlFixture = struct {
    host: wayring.server.Server,
    clients: ClientRegistry,
    surfaces: SurfaceRegistry,
    authority: SeatAuthority,
    mapped: WayringClients,
    compositor: WayringCompositor,
    seat: WayringSeatAdapter,
    canonical: DataDevice,
    adapter: WayringZwlrDataControl,
    managed: *wayring.server.CoreClient,
    client_id: ClientRegistry.Id,

    fn init(self: *@This()) !void {
        return self.initVersion(2);
    }

    fn initVersion(self: *@This(), manager_version: u32) !void {
        self.host = .init(std.testing.allocator);
        self.clients = .init(std.testing.allocator);
        self.surfaces = .init(std.testing.allocator);
        self.authority = .init(std.testing.allocator, &self.clients, &self.surfaces);
        self.mapped.init(std.testing.allocator, &self.clients);
        try self.compositor.init(std.testing.allocator, &self.host, &self.surfaces, null);
        self.seat = .init(std.testing.allocator, &self.host, &self.mapped, &self.compositor, .{
            .context = self,
            .set_cursor = noopCursor,
            .cursor_committed = noopCommitted,
            .cursor_removed = noopRemoved,
            .client_retiring = noopRetiring,
        }, "test-seat");
        try self.seat.publish();
        self.canonical = .init(std.testing.allocator, &self.clients, &self.surfaces, &self.authority, .{
            .context = &self.adapter,
            .transaction_finalize = transactionFinalize,
            .transaction_commit = transactionCommit,
            .transaction_abort = transactionAbort,
            .selection_changed = noopChanged,
            .drag_changed = noopChanged,
            .control_offer_rolled_back = offerRolledBack,
            .control_offer_mime_offered = offerMimeOffered,
        });
        self.adapter.init(std.testing.allocator, &self.host, &self.mapped, &self.seat, &self.canonical, 42);
        try self.adapter.publish();
        self.host.setGlobalFilter(WayringZwlrDataControl, &self.adapter, WayringZwlrDataControl.globalFilter);
        self.managed = try wayring.server.CoreClient.create(std.testing.allocator, &self.host, .{
            .credentials = .{ .pid = 1, .uid = 42, .gid = 1 },
            .transport_provenance = .direct,
        });
        self.client_id = try self.mapped.register(self.client());
        try requestRegistry(self.client(), 2);
        try discardTestEvents(self.client());
        try self.bind("wl_seat", 3, protocol.wl_seat.interface.version);
        try self.bind("zwlr_data_control_manager_v1", 4, manager_version);
        try discardTestEvents(self.client());
    }

    fn deinit(self: *@This()) void {
        self.adapter.destroyClientResources(self.client());
        self.seat.destroyClientResources(self.client());
        self.compositor.destroyClientResources(self.client());
        _ = self.authority.clientDisconnected(self.client_id);
        self.mapped.unregister(self.client());
        self.managed.destroy();
        self.host.clearGlobalFilter();
        self.adapter.unpublish();
        self.seat.unpublish();
        self.adapter.deinit();
        self.canonical.deinit();
        self.seat.deinit();
        self.compositor.deinit();
        self.mapped.deinit();
        self.authority.deinit();
        self.surfaces.deinit();
        self.clients.deinit();
        self.host.deinit();
    }

    fn client(self: *@This()) *wayring.server.Client {
        return self.managed.client();
    }
    fn bind(self: *@This(), name: []const u8, id: u32, version: u32) !void {
        var globals = self.host.iterator();
        while (globals.next()) |global| if (std.mem.eql(u8, global.interface().name, name)) return sendTestRequest(self.client(), 2, 0, &protocol.wl_registry.request_messages[0], &.{
            .{ .uint = global.name() },
            .{ .new_id = .{ .generic = .{ .interface = name, .version = version, .id = id } } },
        });
        return error.MissingGlobal;
    }
    fn noopChanged(_: *anyopaque) void {}
    fn noopCursor(_: *anyopaque, _: SeatDelivery.CursorRequest) SeatDelivery.CursorRequestResult {
        return .ignored;
    }
    fn noopCommitted(_: *anyopaque, _: SurfaceRegistry.Id, _: i32, _: i32) void {}
    fn noopRemoved(_: *anyopaque, _: SurfaceRegistry.Id) void {}
    fn noopRetiring(_: *anyopaque, _: ClientRegistry.Id) void {}
};

test "generated data-control wire owns both channels and one-closes receive descriptors" {
    var fixture: ControlFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const client = fixture.client();
    try sendTestRequest(client, 4, 0, &protocol.zwlr_data_control_manager_v1.request_messages[0], &.{.{ .new_id = .{ .typed = 5 } }});
    try sendTestRequest(client, 4, 1, &protocol.zwlr_data_control_manager_v1.request_messages[1], &.{ .{ .new_id = .{ .typed = 6 } }, .{ .object = 3 } });
    try sendTestRequest(client, 4, 1, &protocol.zwlr_data_control_manager_v1.request_messages[1], &.{ .{ .new_id = .{ .typed = 7 } }, .{ .object = 3 } });
    try discardTestEvents(client);
    try sendTestRequest(client, 5, 0, &protocol.zwlr_data_control_source_v1.request_messages[0], &.{.{ .string = "text/plain" }});
    try sendTestRequest(client, 6, 0, &protocol.zwlr_data_control_device_v1.request_messages[0], &.{.{ .object = 5 }});
    try std.testing.expect(fixture.canonical.hasSelection());
    try std.testing.expectEqual(@as(usize, 2), fixture.adapter.offers.items.len);
    try std.testing.expectEqual(DataDevice.ControlChannel.regular, fixture.canonical.controlOfferInfo(fixture.adapter.offers.items[0].id).?.channel);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    while (try client.beginSend()) |batch| {
        try bytes.appendSlice(std.testing.allocator, batch.bytes);
        try client.completeSend(batch.token, batch.bytes.len);
    }
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, "text/plain") != null);

    try sendTestRequest(client, 4, 0, &protocol.zwlr_data_control_manager_v1.request_messages[0], &.{.{ .new_id = .{ .typed = 8 } }});
    try sendTestRequest(client, 8, 0, &protocol.zwlr_data_control_source_v1.request_messages[0], &.{.{ .string = "text/plain" }});
    try sendTestRequest(client, 7, 2, &protocol.zwlr_data_control_device_v1.request_messages[2], &.{.{ .object = 8 }});
    try std.testing.expect(fixture.canonical.hasPrimarySelection());
    try std.testing.expectEqual(@as(usize, 4), fixture.adapter.offers.items.len);
    var primary_offers: usize = 0;
    for (fixture.adapter.offers.items) |offer| if (fixture.canonical.controlOfferInfo(offer.id).?.channel == .primary) {
        primary_offers += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), primary_offers);

    var pipe: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe2(&pipe, .{ .CLOEXEC = true }));
    defer _ = std.c.close(pipe[0]);
    defer _ = std.c.close(pipe[1]);
    const regular_offer = for (fixture.adapter.offers.items) |offer| {
        if (fixture.canonical.controlOfferInfo(offer.id).?.channel == .regular) break offer;
    } else return error.MissingOffer;
    try sendTestRequest(client, regular_offer.resource.id(), 0, &protocol.zwlr_data_control_offer_v1.request_messages[0], &.{ .{ .string = "text/plain" }, .{ .fd = pipe[1] } });
    var sent_fds: usize = 0;
    while (try client.beginSend()) |event| {
        sent_fds += event.fds.len;
        try client.completeSend(event.token, event.bytes.len);
    }
    try std.testing.expectEqual(@as(usize, 1), sent_fds);
    try std.testing.expect(std.c.fcntl(pipe[1], std.c.F.GETFD) >= 0);

    try sendTestRequest(client, 5, 0, &protocol.zwlr_data_control_source_v1.request_messages[0], &.{.{ .string = "text/html" }});
    try std.testing.expect(client.fatal() != null);
}

test "WLR data-control v1 device ignores existing and repeated primary selections" {
    var fixture: ControlFixture = undefined;
    try fixture.initVersion(1);
    defer fixture.deinit();
    const Endpoint = struct {
        fn send(_: *anyopaque, _: []const u8, _: std.posix.fd_t) void {}
        fn target(_: *anyopaque, _: ?[]const u8) void {}
        fn action(_: *anyopaque, _: DataDevice.Actions) void {}
        fn ignored(_: *anyopaque) void {}
    };
    var context: u8 = 0;
    const endpoint: DataDevice.SourceEndpoint = .{ .context = &context, .send = Endpoint.send, .target = Endpoint.target, .action = Endpoint.action, .cancelled = Endpoint.ignored, .drop_performed = Endpoint.ignored, .finished = Endpoint.ignored };
    const first = try fixture.canonical.createPrimarySource(null, endpoint);
    try fixture.canonical.setExternalPrimarySelection(first);
    try sendTestRequest(fixture.client(), 4, 1, &protocol.zwlr_data_control_manager_v1.request_messages[1], &.{ .{ .new_id = .{ .typed = 6 } }, .{ .object = 3 } });
    try std.testing.expectEqual(@as(usize, 0), fixture.adapter.offers.items.len);
    // A v1 device still receives its required initial regular selection(NULL).
    // Only primary publication is omitted.
    try discardTestEvents(fixture.client());
    const second = try fixture.canonical.createPrimarySource(null, endpoint);
    try fixture.canonical.setExternalPrimarySelection(second);
    fixture.canonical.clearExternalPrimarySelection();
    try fixture.canonical.setExternalPrimarySelection(first);
    try std.testing.expectEqual(@as(usize, 0), fixture.adapter.offers.items.len);
    try std.testing.expect((try fixture.client().beginSend()) == null);
    fixture.adapter.destroyClientResources(fixture.client());
    try std.testing.expectEqual(@as(usize, 0), fixture.canonical.controlResourceCounts().offers);
    fixture.canonical.clearExternalPrimarySelection();
    fixture.canonical.destroyPrimarySource(second);
    fixture.canonical.destroyPrimarySource(first);
}

test "generated data-control publication aborts atomically on stage and finalize OOM" {
    inline for (.{ false, true }) |finalize| {
        var fixture: ControlFixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        const client = fixture.client();
        try sendTestRequest(client, 4, 0, &protocol.zwlr_data_control_manager_v1.request_messages[0], &.{.{ .new_id = .{ .typed = 5 } }});
        try sendTestRequest(client, 4, 1, &protocol.zwlr_data_control_manager_v1.request_messages[1], &.{ .{ .new_id = .{ .typed = 6 } }, .{ .object = 3 } });
        try sendTestRequest(client, 5, 0, &protocol.zwlr_data_control_source_v1.request_messages[0], &.{.{ .string = "text/plain" }});
        try discardTestEvents(client);
        if (finalize)
            fixture.adapter.finalize_failure = true
        else
            fixture.adapter.stage_failure_after = 1;
        try std.testing.expectError(
            error.OutOfMemory,
            fixture.canonical.setControlRegularSelection(fixture.adapter.devices.items[0].id, fixture.adapter.sources.items[0].id),
        );
        try std.testing.expect(!fixture.canonical.hasSelection());
        try std.testing.expectEqual(@as(u64, 0), fixture.canonical.selectionGeneration());
        try std.testing.expectEqual(@as(usize, 0), fixture.adapter.offers.items.len);
        try std.testing.expectEqual(@as(usize, 0), fixture.adapter.staged.items.len);
        try std.testing.expectEqual(@as(usize, 0), fixture.adapter.prepared.items.len);
    }
}

test "data-control publication is singular, atomic, and filter is restricted" {
    const Public = struct {
        pub const interface: wire.Interface = .{ .name = "wl_public_fixture", .version = 1 };
        fn bind(_: *wayring.server.Client, _: u32, _: u32, _: *@This()) !void {}
    };
    var host: wayring.server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var public: Public = .{};
    const public_global = try host.addGlobal(Public, 1, Public, &public, Public.bind);
    var adapter: WayringZwlrDataControl = undefined;
    adapter.init(std.testing.allocator, &host, undefined, undefined, undefined, 42);
    defer adapter.deinit();
    host.setGlobalFilter(WayringZwlrDataControl, &adapter, WayringZwlrDataControl.globalFilter);
    defer host.clearGlobalFilter();
    const preexisting = try wayring.server.CoreClient.create(std.testing.allocator, &host, .{ .credentials = .{ .pid = 4, .uid = 43, .gid = 1 }, .transport_provenance = .direct });
    defer preexisting.destroy();
    try requestRegistry(preexisting.client(), 2);
    const preexisting_public = (try preexisting.client().beginSend()).?;
    try std.testing.expectEqual(public_global.name(), std.mem.readInt(u32, preexisting_public.bytes[8..12], .native));
    try preexisting.client().completeSend(preexisting_public.token, preexisting_public.bytes.len);
    try adapter.publish();
    try std.testing.expect((try preexisting.client().beginSend()) == null);
    try requestBind(preexisting.client(), 2, adapter.global.?.name(), 3);
    try std.testing.expect(preexisting.client().fatal() != null);
    try std.testing.expectEqual(@as(usize, 0), adapter.managers.items.len);
    var count: usize = 0;
    var globals = host.iterator();
    while (globals.next()) |global| if (std.mem.eql(u8, global.interface().name, "zwlr_data_control_manager_v1")) {
        count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), count);
    const matching = try wayring.server.CoreClient.create(std.testing.allocator, &host, .{ .credentials = .{ .pid = 1, .uid = 42, .gid = 1 }, .transport_provenance = .direct });
    defer matching.destroy();
    const foreign = try wayring.server.CoreClient.create(std.testing.allocator, &host, .{ .credentials = .{ .pid = 2, .uid = 43, .gid = 1 }, .transport_provenance = .direct });
    defer foreign.destroy();
    const unknown = try wayring.server.CoreClient.create(std.testing.allocator, &host, .{});
    defer unknown.destroy();
    const derived = try wayring.server.CoreClient.create(std.testing.allocator, &host, .{ .credentials = .{ .pid = 3, .uid = 42, .gid = 1 }, .transport_provenance = .security_context });
    defer derived.destroy();
    try std.testing.expect(adapter.globalFilter(matching.client(), adapter.global.?));
    try std.testing.expect(!adapter.globalFilter(foreign.client(), adapter.global.?));
    try std.testing.expect(!adapter.globalFilter(unknown.client(), adapter.global.?));
    try std.testing.expect(!adapter.globalFilter(derived.client(), adapter.global.?));

    try requestRegistry(matching.client(), 2);
    try requestRegistry(foreign.client(), 2);
    try requestRegistry(unknown.client(), 2);
    const matching_snapshot = (try matching.client().beginSend()).?;
    try std.testing.expectEqual(public_global.name(), std.mem.readInt(u32, matching_snapshot.bytes[8..12], .native));
    const second_offset: usize = @intCast(std.mem.readInt(u32, matching_snapshot.bytes[4..8], .native) >> 16);
    try std.testing.expect(second_offset < matching_snapshot.bytes.len);
    try std.testing.expectEqual(adapter.global.?.name(), std.mem.readInt(u32, matching_snapshot.bytes[second_offset + 8 ..][0..4], .native));
    try matching.client().completeSend(matching_snapshot.token, matching_snapshot.bytes.len);
    for ([_]*wayring.server.Client{ foreign.client(), unknown.client() }) |restricted| {
        const snapshot = (try restricted.beginSend()).?;
        try std.testing.expectEqual(public_global.name(), std.mem.readInt(u32, snapshot.bytes[8..12], .native));
        try restricted.completeSend(snapshot.token, snapshot.bytes.len);
        try std.testing.expect((try restricted.beginSend()) == null);
        try requestBind(restricted, 2, adapter.global.?.name(), 3);
        try std.testing.expect(restricted.fatal() != null);
    }
    try std.testing.expectEqual(@as(usize, 0), adapter.managers.items.len);
    adapter.unpublish();
    const removal = (try matching.client().beginSend()).?;
    try std.testing.expectEqual(@as(u16, 1), @as(u16, @truncate(std.mem.readInt(u32, removal.bytes[4..8], .native))));
    try std.testing.expect(adapter.global == null);
    try matching.client().completeSend(removal.token, removal.bytes.len);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    failing.fail_index = 0;
    var failing_host: wayring.server.Server = .init(failing.allocator());
    defer failing_host.deinit();
    var failed: WayringZwlrDataControl = undefined;
    failed.init(std.testing.allocator, &failing_host, undefined, undefined, undefined, 42);
    defer failed.deinit();
    try std.testing.expectError(error.OutOfMemory, failed.publish());
    try std.testing.expect(failed.global == null);
}

const test_registry_interface: wire.Interface = .{ .name = "wl_registry", .version = 1 };
const test_display_get_registry: wire.MessageDescriptor = .{
    .name = "get_registry",
    .arguments = &.{.{ .name = "registry", .kind = .{ .new_id = &test_registry_interface } }},
};
const test_registry_bind: wire.MessageDescriptor = .{
    .name = "bind",
    .arguments = &.{
        .{ .name = "name", .kind = .uint },
        .{ .name = "id", .kind = .{ .new_id = null } },
    },
};

fn requestRegistry(client: *wayring.server.Client, id: u32) !void {
    try sendTestRequest(client, 1, 1, &test_display_get_registry, &.{.{ .new_id = .{ .typed = id } }});
}

fn requestBind(client: *wayring.server.Client, registry: u32, global: u32, id: u32) !void {
    try sendTestRequest(client, registry, 0, &test_registry_bind, &.{
        .{ .uint = global },
        .{ .new_id = .{ .generic = .{ .interface = "zwlr_data_control_manager_v1", .version = 1, .id = id } } },
    });
}

fn sendTestRequest(client: *wayring.server.Client, object: u32, opcode: u16, descriptor: *const wire.MessageDescriptor, values: []const wire.Value) !void {
    var output: wire.Output = .init(std.testing.allocator);
    defer output.deinit();
    try output.enqueue(object, opcode, descriptor, values);
    const batch = (try output.beginSend()).?;
    var fds: std.ArrayList(wire.FileDescriptor) = .empty;
    defer fds.deinit(std.testing.allocator);
    try fds.ensureUnusedCapacity(std.testing.allocator, batch.fds.len);
    errdefer {
        for (fds.items) |fd| _ = std.c.close(fd);
    }
    for (batch.fds) |fd| {
        const duplicate = std.c.fcntl(fd, std.c.F.DUPFD_CLOEXEC, @as(c_int, 0));
        if (duplicate < 0) return error.Unexpected;
        fds.appendAssumeCapacity(duplicate);
    }
    try client.receive(batch.bytes, fds.items);
    fds.clearRetainingCapacity();
    try output.completeSend(batch.token, batch.bytes.len);
    try client.dispatch();
}

fn discardTestEvents(client: *wayring.server.Client) !void {
    while (try client.beginSend()) |batch| try client.completeSend(batch.token, batch.bytes.len);
}
