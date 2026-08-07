//! Generated primary-selection protocol adapter.
//!
//! This type owns only generated wire resources. A dedicated DataDevice
//! channel remains the sole owner of primary-selection semantics and state.

const WayringPrimarySelection = @This();

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
const WayringSeatAdapter = @import("WayringSeatAdapter.zig");
const wire = wayring.wire;

const Manager = struct { owner: *WayringPrimarySelection, client: *wayring.server.Client, resource: protocol.zwp_primary_selection_device_manager_v1.Resource };
const Source = struct { owner: *WayringPrimarySelection, client: *wayring.server.Client, resource: protocol.zwp_primary_selection_source_v1.Resource, id: DataDevice.PrimarySourceId };
const Device = struct { owner: *WayringPrimarySelection, client: *wayring.server.Client, resource: protocol.zwp_primary_selection_device_v1.Resource, id: DataDevice.PrimaryDeviceId };
const StagedEvents = struct {
    client: *wayring.server.Client,
    events: []wayring.server.Client.PreparedEvent,
    values: []wire.Value,
    offers: []const *Offer,
    maximum_bytes: usize,
};
const PreparedClient = struct { client: *wayring.server.Client, batch: wire.PreparedBatch, events: []wayring.server.Client.PreparedEvent };
const Offer = struct { owner: *WayringPrimarySelection, client: *wayring.server.Client, resource: protocol.zwp_primary_selection_offer_v1.Resource, id: DataDevice.PrimaryOfferId, device: ?*Device, published: bool = false };

allocator: std.mem.Allocator,
protocol_server: *wayring.server.Server,
clients: *WayringClients,
seat: *WayringSeatAdapter,
canonical: *DataDevice,
global: ?*const wayring.server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
sources: std.ArrayList(*Source) = .empty,
devices: std.ArrayList(*Device) = .empty,
offers: std.ArrayList(*Offer) = .empty,
staged_events: std.ArrayList(StagedEvents) = .empty,
prepared_clients: std.ArrayList(PreparedClient) = .empty,
stage_failure_after: if (builtin.is_test) ?usize else void = if (builtin.is_test) null else {},
finalize_failure: if (builtin.is_test) bool else void = if (builtin.is_test) false else {},

pub fn init(self: *WayringPrimarySelection, allocator: std.mem.Allocator, protocol_server: *wayring.server.Server, clients: *WayringClients, seat: *WayringSeatAdapter, canonical: *DataDevice) void {
    self.* = .{ .allocator = allocator, .protocol_server = protocol_server, .clients = clients, .seat = seat, .canonical = canonical };
}

pub fn deinit(self: *WayringPrimarySelection) void {
    std.debug.assert(self.global == null and self.managers.items.len == 0 and self.sources.items.len == 0 and self.devices.items.len == 0 and self.offers.items.len == 0 and self.staged_events.items.len == 0 and self.prepared_clients.items.len == 0);
    self.managers.deinit(self.allocator);
    self.sources.deinit(self.allocator);
    self.devices.deinit(self.allocator);
    self.offers.deinit(self.allocator);
    self.staged_events.deinit(self.allocator);
    self.prepared_clients.deinit(self.allocator);
    self.* = undefined;
}

pub fn publish(self: *WayringPrimarySelection) !void {
    std.debug.assert(self.global == null);
    self.global = try self.protocol_server.addGlobal(protocol.zwp_primary_selection_device_manager_v1, 1, WayringPrimarySelection, self, bindManager);
}

pub fn unpublish(self: *WayringPrimarySelection) void {
    const global = self.global orelse unreachable;
    self.protocol_server.removeGlobal(global) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}

fn bindManager(client: *wayring.server.Client, id: u32, version: u32, self: *WayringPrimarySelection) !void {
    if (version != 1) return error.InvalidVersion;
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

fn managerRequest(_: *protocol.zwp_primary_selection_device_manager_v1.Resource, request: protocol.zwp_primary_selection_device_manager_v1.Request, value: *Manager) !void {
    switch (request) {
        .create_source => |args| try value.owner.createSource(value, args.id),
        .get_device => |args| {
            if (value.owner.seat.seatClientIdentity(value.client, args.seat) == null)
                return value.client.postImplementationError(&value.resource.runtime, "primary device requires the exact live same-client wl_seat");
            try value.owner.createDevice(value, args.id);
        },
        .destroy => value.owner.destroyManager(value),
    }
}

fn createSource(self: *WayringPrimarySelection, manager: *Manager, id: u32) !void {
    try self.sources.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Source);
    errdefer self.allocator.destroy(value);
    value.* = undefined;
    const canonical_id = try self.canonical.createPrimarySource(self.clients.id(manager.client) orelse return error.InvalidClient, .{ .context = value, .send = sourceSend, .target = ignoredTarget, .action = ignoredAction, .cancelled = sourceCancelled, .selection_cancelled = sourceCancelled, .drop_performed = ignored, .finished = ignored });
    errdefer self.canonical.destroyPrimarySource(canonical_id);
    value.* = .{ .owner = self, .client = manager.client, .resource = .init(self.allocator, id, 1, .client, manager.client.ownerHooks()), .id = canonical_id };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Source, value, sourceRequest, null);
    try manager.client.materialize(&value.resource.runtime);
    self.sources.appendAssumeCapacity(value);
}

fn sourceRequest(_: *protocol.zwp_primary_selection_source_v1.Resource, request: protocol.zwp_primary_selection_source_v1.Request, value: *Source) !void {
    switch (request) {
        .offer => |args| try value.owner.canonical.offerPrimaryMime(value.id, args.mime_type),
        .destroy => value.owner.destroySource(value),
    }
}

fn createDevice(self: *WayringPrimarySelection, manager: *Manager, id: u32) !void {
    try self.devices.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Device);
    errdefer self.allocator.destroy(value);
    value.* = .{ .owner = self, .client = manager.client, .resource = .init(self.allocator, id, 1, .client, manager.client.ownerHooks()), .id = undefined };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Device, value, deviceRequest, null);
    try manager.client.materialize(&value.resource.runtime);
    value.id = try self.canonical.createPrimaryDevice(self.clients.id(manager.client) orelse return error.InvalidClient, .{ .context = value, .selection_prepare = deviceSelectionPrepare, .selection = deviceSelection });
    errdefer self.canonical.destroyPrimaryDevice(value.id);
    self.devices.appendAssumeCapacity(value);
}

fn deviceRequest(_: *protocol.zwp_primary_selection_device_v1.Resource, request: protocol.zwp_primary_selection_device_v1.Request, value: *Device) !void {
    switch (request) {
        .set_selection => |args| {
            const source = if (args.source) |object_id| value.owner.sourceIdentity(value.client, object_id) orelse return value.client.postImplementationError(&value.resource.runtime, "primary source is not exact and live") else null;
            value.owner.canonical.setPrimarySelection(value.id, source, .{ .domain = .wayring_server, .value = args.serial }) catch |err| switch (err) {
                error.OutOfMemory => value.client.postOutOfMemory(&value.resource.runtime, "publishing primary selection"),
                error.Unauthorized, error.SourceAlreadyUsed => {},
                else => value.client.postImplementationError(&value.resource.runtime, "invalid primary selection request"),
            };
        },
        .destroy => value.owner.destroyDevice(value),
    }
}

fn sourceIdentity(self: *WayringPrimarySelection, client: *wayring.server.Client, object_id: u32) ?DataDevice.PrimarySourceId {
    const installed = client.lookup(object_id) orelse return null;
    for (self.sources.items) |value| if (value.client == client and value.resource.id() == object_id and installed == &value.resource.runtime and value.resource.runtime.state() == .live) return value.id;
    return null;
}

fn createOffer(self: *WayringPrimarySelection, device: *Device, canonical_id: DataDevice.PrimaryOfferId) !*Offer {
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

fn deviceSelectionPrepare(context: *anyopaque, canonical_id: ?DataDevice.PrimaryOfferId) error{OutOfMemory}!void {
    const device: *Device = @ptrCast(@alignCast(context));
    const id = canonical_id orelse {
        try device.owner.stageEvent(device.client, &device.resource.runtime, 1, &protocol.zwp_primary_selection_device_v1.event_messages[1], &.{.{ .object = null }}, 12, &.{});
        return;
    };
    const offer = device.owner.createOffer(device, id) catch return transactionOutOfMemory(device.client, &device.resource.runtime);
    const source = device.owner.canonical.primaryOfferSource(id) orelse return transactionOutOfMemory(device.client, &device.resource.runtime);
    const mimes = device.owner.canonical.primarySourceMimeTypes(source) catch return transactionOutOfMemory(device.client, &device.resource.runtime);
    try device.owner.stageEvent(device.client, &device.resource.runtime, 0, &protocol.zwp_primary_selection_device_v1.event_messages[0], &.{.{ .new_id = .{ .typed = offer.resource.id() } }}, 12, &.{offer});
    for (mimes) |mime| {
        const terminated = std.math.add(usize, mime.len, 1) catch return transactionOutOfMemory(device.client, &device.resource.runtime);
        const message_bytes = std.math.add(usize, 12, std.mem.alignForward(usize, terminated, 4)) catch return transactionOutOfMemory(device.client, &device.resource.runtime);
        if (message_bytes > wire.max_message_size) return transactionOutOfMemory(device.client, &device.resource.runtime);
        try device.owner.stageEvent(device.client, &offer.resource.runtime, 0, &protocol.zwp_primary_selection_offer_v1.event_messages[0], &.{.{ .string = mime }}, message_bytes, &.{});
    }
    try device.owner.stageEvent(device.client, &device.resource.runtime, 1, &protocol.zwp_primary_selection_device_v1.event_messages[1], &.{.{ .object = offer.resource.id() }}, 12, &.{});
}

fn deviceSelection(_: *anyopaque, _: ?DataDevice.PrimaryOfferId) error{OutOfMemory}!void {
    // transactionCommit publishes the complete per-client batch.
}

fn offerRequest(_: *protocol.zwp_primary_selection_offer_v1.Resource, request: protocol.zwp_primary_selection_offer_v1.Request, value: *Offer) !void {
    switch (request) {
        .receive => |args| {
            defer _ = std.c.close(args.fd);
            value.owner.canonical.receivePrimary(value.id, args.mime_type, args.fd) catch {};
        },
        .destroy => value.owner.destroyOffer(value),
    }
}

pub fn offerRolledBack(context: *anyopaque, id: DataDevice.PrimaryOfferId) void {
    const self: *WayringPrimarySelection = @ptrCast(@alignCast(context));
    for (self.offers.items) |value| {
        if (std.meta.eql(value.id, id)) return self.destroyOffer(value);
    }
}
pub fn selectionChanged(_: *anyopaque) void {}
pub fn mimeOffered(_: *anyopaque, _: DataDevice.PrimarySourceId, _: []const u8) void {}

pub fn transactionFinalize(context: *anyopaque) error{OutOfMemory}!void {
    const self: *WayringPrimarySelection = @ptrCast(@alignCast(context));
    std.debug.assert(self.prepared_clients.items.len == 0);
    if (self.staged_events.items.len == 0) return;
    if (comptime builtin.is_test) if (self.finalize_failure) {
        self.finalize_failure = false;
        const staged = self.staged_events.items[0];
        return transactionOutOfMemory(staged.client, staged.events[0].resource);
    };
    var index: usize = 0;
    while (index < self.staged_events.items.len) : (index += 1) {
        const client = self.staged_events.items[index].client;
        var already_prepared = false;
        for (self.prepared_clients.items) |prepared| if (prepared.client == client) {
            already_prepared = true;
            break;
        };
        if (already_prepared) continue;
        var event_count: usize = 0;
        var maximum_bytes: usize = 0;
        for (self.staged_events.items) |staged| if (staged.client == client) {
            event_count = std.math.add(usize, event_count, staged.events.len) catch return error.OutOfMemory;
            maximum_bytes = std.math.add(usize, maximum_bytes, staged.maximum_bytes) catch return error.OutOfMemory;
        };
        const error_resource = self.staged_events.items[index].events[0].resource;
        const events = self.allocator.alloc(wayring.server.Client.PreparedEvent, event_count) catch return transactionOutOfMemory(client, error_resource);
        var next: usize = 0;
        for (self.staged_events.items) |staged| if (staged.client == client) {
            @memcpy(events[next .. next + staged.events.len], staged.events);
            next += staged.events.len;
        };
        const batch = client.prepareEvents(maximum_bytes) catch {
            self.allocator.free(events);
            return transactionOutOfMemory(client, error_resource);
        };
        self.prepared_clients.append(self.allocator, .{ .client = client, .batch = batch, .events = events }) catch {
            client.cancelPreparedEvents(batch);
            self.allocator.free(events);
            return transactionOutOfMemory(client, error_resource);
        };
    }
}

pub fn transactionCommit(context: *anyopaque) void {
    const self: *WayringPrimarySelection = @ptrCast(@alignCast(context));
    for (self.prepared_clients.items) |prepared| prepared.client.emitPreparedEvents(prepared.batch, prepared.events) catch unreachable;
    for (self.staged_events.items) |staged| for (staged.offers) |offer| {
        offer.published = true;
    };
    self.clearTransaction(false);
}

pub fn transactionAbort(context: *anyopaque) void {
    const self: *WayringPrimarySelection = @ptrCast(@alignCast(context));
    self.clearTransaction(true);
}

fn stageEvent(self: *WayringPrimarySelection, client: *wayring.server.Client, resource: *wayring.server.Resource, opcode: u16, descriptor: *const wire.MessageDescriptor, source_values: []const wire.Value, maximum_bytes: usize, offers: []const *Offer) error{OutOfMemory}!void {
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
    self.staged_events.append(self.allocator, .{ .client = client, .events = events, .values = values, .offers = offer_copy, .maximum_bytes = maximum_bytes }) catch return transactionOutOfMemory(client, resource);
}

fn transactionOutOfMemory(client: *wayring.server.Client, resource: *wayring.server.Resource) error{OutOfMemory} {
    client.postOutOfMemory(resource, "preparing generated primary-selection transaction");
    return error.OutOfMemory;
}

fn failStageAfterForTest(self: *WayringPrimarySelection, successful_stages: usize) void {
    if (comptime !builtin.is_test) unreachable;
    self.stage_failure_after = successful_stages;
}

fn failFinalizeForTest(self: *WayringPrimarySelection) void {
    if (comptime !builtin.is_test) unreachable;
    self.finalize_failure = true;
}

fn clearTransaction(self: *WayringPrimarySelection, cancel: bool) void {
    for (self.prepared_clients.items) |prepared| {
        if (cancel) prepared.client.cancelPreparedEvents(prepared.batch);
        self.allocator.free(prepared.events);
    }
    self.prepared_clients.clearRetainingCapacity();
    for (self.staged_events.items) |staged| {
        self.allocator.free(staged.events);
        self.allocator.free(staged.values);
        self.allocator.free(staged.offers);
    }
    self.staged_events.clearRetainingCapacity();
}

pub fn offerMimeOffered(context: *anyopaque, id: DataDevice.PrimaryOfferId, mime: []const u8) void {
    const self: *WayringPrimarySelection = @ptrCast(@alignCast(context));
    for (self.offers.items) |value| {
        if (!std.meta.eql(value.id, id)) continue;
        if (!value.published) return;
        protocol.zwp_primary_selection_offer_v1.@"send:offer"(&value.resource, mime) catch {
            value.client.postOutOfMemory(&value.resource.runtime, "queueing primary MIME");
        };
        return;
    }
}
fn sourceSend(context: *anyopaque, mime: []const u8, fd: std.posix.fd_t) void {
    const value: *Source = @ptrCast(@alignCast(context));
    protocol.zwp_primary_selection_source_v1.@"send:send"(&value.resource, mime, fd) catch {
        value.client.postOutOfMemory(&value.resource.runtime, "queueing primary transfer");
    };
}
fn sourceCancelled(context: *anyopaque) void {
    const value: *Source = @ptrCast(@alignCast(context));
    protocol.zwp_primary_selection_source_v1.@"send:cancelled"(&value.resource) catch {
        value.client.postOutOfMemory(&value.resource.runtime, "queueing primary cancellation");
    };
}
fn ignored(_: *anyopaque) void {}
fn ignoredTarget(_: *anyopaque, _: ?[]const u8) void {}
fn ignoredAction(_: *anyopaque, _: DataDevice.Actions) void {}
fn ignoredPrepare(_: *anyopaque, _: ?DataDevice.OfferId) error{OutOfMemory}!DataDevice.DragPreparation {
    return .{};
}
fn ignoredEnter(_: *anyopaque, _: @import("../SurfaceRegistry.zig").Id, _: f64, _: f64, _: ?DataDevice.OfferId) void {}
fn ignoredMotion(_: *anyopaque, _: u32, _: f64, _: f64) void {}

pub fn destroyClientResources(self: *WayringPrimarySelection, client: *wayring.server.Client) void {
    var i = self.offers.items.len;
    while (i > 0) : (i -= 1) if (self.offers.items[i - 1].client == client) self.destroyOffer(self.offers.items[i - 1]);
    i = self.devices.items.len;
    while (i > 0) : (i -= 1) if (self.devices.items[i - 1].client == client) self.destroyDevice(self.devices.items[i - 1]);
    i = self.sources.items.len;
    while (i > 0) : (i -= 1) if (self.sources.items[i - 1].client == client) self.destroySource(self.sources.items[i - 1]);
    i = self.managers.items.len;
    while (i > 0) : (i -= 1) if (self.managers.items[i - 1].client == client) self.destroyManager(self.managers.items[i - 1]);
}
fn destroyOffer(self: *WayringPrimarySelection, value: *Offer) void {
    for (self.offers.items, 0..) |item, i| if (item == value) {
        _ = self.offers.swapRemove(i);
        break;
    };
    self.canonical.destroyPrimaryOffer(value.id);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}
fn destroyDevice(self: *WayringPrimarySelection, value: *Device) void {
    for (self.offers.items) |offer| if (offer.device == value) {
        offer.device = null;
    };
    for (self.devices.items, 0..) |item, i| if (item == value) {
        _ = self.devices.swapRemove(i);
        break;
    };
    self.canonical.destroyPrimaryDevice(value.id);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}
fn destroySource(self: *WayringPrimarySelection, value: *Source) void {
    for (self.sources.items, 0..) |item, i| if (item == value) {
        _ = self.sources.swapRemove(i);
        break;
    };
    self.canonical.destroyPrimarySource(value.id);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}
fn destroyManager(self: *WayringPrimarySelection, value: *Manager) void {
    for (self.managers.items, 0..) |item, i| if (item == value) {
        _ = self.managers.swapRemove(i);
        break;
    };
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}

test "generated primary selection implements protocol v1" {
    try std.testing.expect(@hasDecl(WayringPrimarySelection, "publish"));
    try std.testing.expectEqual(@as(u32, 1), protocol.zwp_primary_selection_device_manager_v1.interface.version);
    const manager = protocol.zwp_primary_selection_device_manager_v1;
    const device = protocol.zwp_primary_selection_device_v1;
    const offer = protocol.zwp_primary_selection_offer_v1;
    const source = protocol.zwp_primary_selection_source_v1;
    try expectMessageNames(&manager.request_messages, &.{ "create_source", "get_device", "destroy" });
    try expectMessageNames(&manager.event_messages, &.{});
    try expectMessageNames(&device.request_messages, &.{ "set_selection", "destroy" });
    try expectMessageNames(&device.event_messages, &.{ "data_offer", "selection" });
    try expectMessageNames(&offer.request_messages, &.{ "receive", "destroy" });
    try expectMessageNames(&offer.event_messages, &.{"offer"});
    try expectMessageNames(&source.request_messages, &.{ "offer", "destroy" });
    try expectMessageNames(&source.event_messages, &.{ "send", "cancelled" });
    try std.testing.expect(!@hasDecl(manager, "Error") and !@hasDecl(device, "Error") and
        !@hasDecl(offer, "Error") and !@hasDecl(source, "Error"));
}

fn expectMessageNames(messages: anytype, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, messages.len);
    for (messages, expected) |message, name| try std.testing.expectEqualStrings(name, message.name);
}

test "primary manager publication is singular and allocation failure is atomic" {
    var host: wayring.server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var adapter: WayringPrimarySelection = undefined;
    adapter.init(std.testing.allocator, &host, undefined, undefined, undefined);
    defer adapter.deinit();
    try adapter.publish();
    var count: usize = 0;
    var globals = host.iterator();
    while (globals.next()) |global| if (std.mem.eql(u8, global.interface().name, "zwp_primary_selection_device_manager_v1")) {
        count += 1;
        try std.testing.expectEqual(@as(u32, 1), global.version());
    };
    try std.testing.expectEqual(@as(usize, 1), count);
    adapter.unpublish();

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    failing.fail_index = 0;
    var failing_host: wayring.server.Server = .init(failing.allocator());
    defer failing_host.deinit();
    var failing_adapter: WayringPrimarySelection = undefined;
    failing_adapter.init(std.testing.allocator, &failing_host, undefined, undefined, undefined);
    defer failing_adapter.deinit();
    try std.testing.expectError(error.OutOfMemory, failing_adapter.publish());
    try std.testing.expect(failing_adapter.global == null);
}

fn testSend(client: *wayring.server.Client, object: u32, opcode: u16, descriptor: *const wire.MessageDescriptor, values: []const wire.Value) !void {
    var output: wire.Output = .init(std.testing.allocator);
    defer output.deinit();
    try output.enqueue(object, opcode, descriptor, values);
    const batch = (try output.beginSend()).?;
    var fds: std.ArrayList(wire.FileDescriptor) = .empty;
    defer fds.deinit(std.testing.allocator);
    try fds.ensureUnusedCapacity(std.testing.allocator, batch.fds.len);
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

fn discardEvents(client: *wayring.server.Client) !void {
    while (try client.beginSend()) |batch| try client.completeSend(batch.token, batch.bytes.len);
}

const PrimaryFixture = struct {
    host: wayring.server.Server,
    clients: ClientRegistry,
    surfaces: SurfaceRegistry,
    authority: SeatAuthority,
    mapped: WayringClients,
    compositor: WayringCompositor,
    seat: WayringSeatAdapter,
    canonical: DataDevice,
    adapter: WayringPrimarySelection,
    managed: *wayring.server.CoreClient,
    client_id: ClientRegistry.Id,

    fn init(self: *@This()) !void {
        self.host = .init(std.testing.allocator);
        self.clients = .init(std.testing.allocator);
        self.surfaces = .init(std.testing.allocator);
        self.authority = .init(std.testing.allocator, &self.clients, &self.surfaces);
        self.mapped.init(std.testing.allocator, &self.clients);
        try self.compositor.init(std.testing.allocator, &self.host, &self.surfaces, null);
        self.seat = .init(std.testing.allocator, &self.host, &self.mapped, &self.compositor, .{ .context = self, .set_cursor = noopCursor, .cursor_committed = noopCommitted, .cursor_removed = noopRemoved, .client_retiring = noopRetiring }, "test-seat");
        try self.seat.publish();
        self.canonical = .init(std.testing.allocator, &self.clients, &self.surfaces, &self.authority, .{
            .context = &self.adapter,
            .transaction_finalize = transactionFinalize,
            .transaction_commit = transactionCommit,
            .transaction_abort = transactionAbort,
            .selection_changed = noopChanged,
            .drag_changed = noopChanged,
            .primary_offer_rolled_back = offerRolledBack,
            .primary_offer_mime_offered = offerMimeOffered,
        });
        self.adapter.init(std.testing.allocator, &self.host, &self.mapped, &self.seat, &self.canonical);
        try self.adapter.publish();
        self.managed = try wayring.server.CoreClient.create(std.testing.allocator, &self.host, .{});
        self.client_id = try self.mapped.register(self.client());
        try testSend(self.client(), 1, 1, &protocol.wl_display.request_messages[1], &.{.{ .new_id = .{ .typed = 2 } }});
        try discardEvents(self.client());
        try self.bind("wl_seat", 3, protocol.wl_seat.interface.version);
        try self.bind("zwp_primary_selection_device_manager_v1", 4, 1);
        try discardEvents(self.client());
    }
    fn deinit(self: *@This()) void {
        self.adapter.destroyClientResources(self.client());
        self.seat.destroyClientResources(self.client());
        self.compositor.destroyClientResources(self.client());
        _ = self.authority.clientDisconnected(self.client_id);
        self.mapped.unregister(self.client());
        self.managed.destroy();
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
        var iterator = self.host.iterator();
        while (iterator.next()) |global| if (std.mem.eql(u8, global.interface().name, name)) return testSend(self.client(), 2, 0, &protocol.wl_registry.request_messages[0], &.{ .{ .uint = global.name() }, .{ .new_id = .{ .generic = .{ .interface = name, .version = version, .id = id } } } });
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

test "generated primary wire lifecycle, late MIME, multiple devices, and retained transfer" {
    var fixture: PrimaryFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const client = fixture.client();
    try testSend(client, 4, 0, &protocol.zwp_primary_selection_device_manager_v1.request_messages[0], &.{.{ .new_id = .{ .typed = 5 } }});
    try testSend(client, 4, 1, &protocol.zwp_primary_selection_device_manager_v1.request_messages[1], &.{ .{ .new_id = .{ .typed = 6 } }, .{ .object = 3 } });
    try testSend(client, 4, 1, &protocol.zwp_primary_selection_device_manager_v1.request_messages[1], &.{ .{ .new_id = .{ .typed = 7 } }, .{ .object = 3 } });
    try testSend(client, 5, 0, &protocol.zwp_primary_selection_source_v1.request_messages[0], &.{.{ .string = "text/plain" }});
    try fixture.canonical.setPrimaryFocus(fixture.client_id);
    const serial: ClientRegistry.Serial = .{ .domain = .wayring_server, .value = 71 };
    try std.testing.expect(fixture.authority.recordSelection(fixture.client_id, serial));
    try testSend(client, 6, 0, &protocol.zwp_primary_selection_device_v1.request_messages[0], &.{ .{ .object = 5 }, .{ .uint = serial.value } });
    try std.testing.expect(fixture.canonical.primarySelectionIs(fixture.adapter.sources.items[0].id));
    try std.testing.expectEqual(@as(usize, 2), fixture.adapter.offers.items.len);
    try fixture.canonical.offerPrimaryMime(fixture.adapter.sources.items[0].id, "text/html");
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    while (try client.beginSend()) |batch| {
        try bytes.appendSlice(std.testing.allocator, batch.bytes);
        try client.completeSend(batch.token, batch.bytes.len);
    }
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, "text/plain") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, "text/html") != null);
    const generation = fixture.canonical.primarySelectionGeneration();
    try testSend(client, 6, 0, &protocol.zwp_primary_selection_device_v1.request_messages[0], &.{ .{ .object = null }, .{ .uint = 999 } });
    try std.testing.expectEqual(generation, fixture.canonical.primarySelectionGeneration());
    const offer_object = fixture.adapter.offers.items[0].resource.id();
    try testSend(client, 6, 1, &protocol.zwp_primary_selection_device_v1.request_messages[1], &.{});
    var pipe: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&pipe));
    defer _ = std.c.close(pipe[0]);
    defer _ = std.c.close(pipe[1]);
    try testSend(client, offer_object, 0, &protocol.zwp_primary_selection_offer_v1.request_messages[0], &.{ .{ .string = "text/plain" }, .{ .fd = pipe[1] } });
    var sent_fds: usize = 0;
    while (try client.beginSend()) |event| {
        sent_fds += event.fds.len;
        try client.completeSend(event.token, event.bytes.len);
    }
    try std.testing.expectEqual(@as(usize, 1), sent_fds);
    try testSend(client, offer_object, 1, &protocol.zwp_primary_selection_offer_v1.request_messages[1], &.{});
    try testSend(client, 5, 1, &protocol.zwp_primary_selection_source_v1.request_messages[1], &.{});
    try testSend(client, 4, 2, &protocol.zwp_primary_selection_device_manager_v1.request_messages[2], &.{});
}

fn expectAtomicPrimaryPublicationFailure(finalize: bool) !void {
    var fixture: PrimaryFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const client = fixture.client();
    try testSend(client, 4, 0, &protocol.zwp_primary_selection_device_manager_v1.request_messages[0], &.{.{ .new_id = .{ .typed = 5 } }});
    try testSend(client, 4, 1, &protocol.zwp_primary_selection_device_manager_v1.request_messages[1], &.{ .{ .new_id = .{ .typed = 6 } }, .{ .object = 3 } });
    try testSend(client, 5, 0, &protocol.zwp_primary_selection_source_v1.request_messages[0], &.{.{ .string = "text/plain" }});
    try fixture.canonical.setPrimaryFocus(fixture.client_id);
    try discardEvents(client);
    const serial: ClientRegistry.Serial = .{ .domain = .wayring_server, .value = 72 };
    try std.testing.expect(fixture.authority.recordSelection(fixture.client_id, serial));
    if (finalize)
        fixture.adapter.failFinalizeForTest()
    else
        fixture.adapter.failStageAfterForTest(1);
    try std.testing.expectError(
        error.OutOfMemory,
        fixture.canonical.setPrimarySelection(fixture.adapter.devices.items[0].id, fixture.adapter.sources.items[0].id, serial),
    );
    try std.testing.expectEqual(@as(u64, 0), fixture.canonical.primarySelectionGeneration());
    try std.testing.expect(!fixture.canonical.hasPrimarySelection());
    try std.testing.expectEqual(DataDevice.ResourceCounts{ .sources = 1, .devices = 1, .offers = 0 }, fixture.canonical.primaryResourceCounts());
    try std.testing.expectEqual(@as(usize, 0), fixture.adapter.offers.items.len);
    try std.testing.expectEqual(@as(usize, 0), fixture.adapter.staged_events.items.len);
    try std.testing.expectEqual(@as(usize, 0), fixture.adapter.prepared_clients.items.len);
}

test "generated primary publication is atomic across staging and finalization OOM" {
    try expectAtomicPrimaryPublicationFailure(false);
    try expectAtomicPrimaryPublicationFailure(true);
}
