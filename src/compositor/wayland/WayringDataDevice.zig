//! Generated wl_data_device clipboard and drag-and-drop adapter.
//!
//! This owns wire resources only. DataDevice remains the sole clipboard and
//! drag semantic owner.

const WayringDataDevice = @This();

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

const manager_version = 4;

const Manager = struct { owner: *WayringDataDevice, client: *wayring.server.Client, resource: protocol.wl_data_device_manager.Resource };
const Source = struct { owner: *WayringDataDevice, client: *wayring.server.Client, resource: protocol.wl_data_source.Resource, id: DataDevice.SourceId };
const Device = struct {
    owner: *WayringDataDevice,
    client: *wayring.server.Client,
    resource: protocol.wl_data_device.Resource,
    id: DataDevice.DeviceId,
    enter_serial: u32 = 0,
};
const StagedEvents = struct {
    client: *wayring.server.Client,
    events: []wayring.server.Client.PreparedEvent,
    values: []wire.Value,
    offers: []const *Offer,
    maximum_bytes: usize,
};
const PreparedClient = struct { client: *wayring.server.Client, batch: wire.PreparedBatch, events: []wayring.server.Client.PreparedEvent };
const Offer = struct { owner: *WayringDataDevice, client: *wayring.server.Client, resource: protocol.wl_data_offer.Resource, id: DataDevice.OfferId, device: ?*Device, enter_serial: u32 = 0, published: bool = false };

allocator: std.mem.Allocator,
protocol_server: *wayring.server.Server,
clients: *WayringClients,
seat: *WayringSeatAdapter,
canonical: *DataDevice,
compositor: ?*WayringCompositor,
global: ?*const wayring.server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
sources: std.ArrayList(*Source) = .empty,
devices: std.ArrayList(*Device) = .empty,
offers: std.ArrayList(*Offer) = .empty,
staged_events: std.ArrayList(StagedEvents) = .empty,
prepared_clients: std.ArrayList(PreparedClient) = .empty,
stage_failure_after: if (builtin.is_test) ?usize else void = if (builtin.is_test) null else {},
finalize_failure: if (builtin.is_test) bool else void = if (builtin.is_test) false else {},

pub fn init(
    self: *WayringDataDevice,
    allocator: std.mem.Allocator,
    protocol_server: *wayring.server.Server,
    clients: *WayringClients,
    seat: *WayringSeatAdapter,
    canonical: *DataDevice,
    compositor: ?*WayringCompositor,
) void {
    self.* = .{
        .allocator = allocator,
        .protocol_server = protocol_server,
        .clients = clients,
        .seat = seat,
        .canonical = canonical,
        .compositor = compositor,
    };
    if (compositor) |value| value.setDragIconListener(.{
        .context = self,
        .committed = dragIconCommitted,
        .removed = dragIconRemoved,
    });
}

pub fn deinit(self: *WayringDataDevice) void {
    std.debug.assert(self.global == null and self.managers.items.len == 0 and self.sources.items.len == 0 and self.devices.items.len == 0 and self.offers.items.len == 0);
    self.managers.deinit(self.allocator);
    self.sources.deinit(self.allocator);
    self.devices.deinit(self.allocator);
    self.offers.deinit(self.allocator);
    self.staged_events.deinit(self.allocator);
    self.prepared_clients.deinit(self.allocator);
    if (self.compositor) |compositor| compositor.setDragIconListener(null);
    self.* = undefined;
}

fn dragIconCommitted(context: *anyopaque, id: SurfaceRegistry.Id, x: i32, y: i32) void {
    const self: *WayringDataDevice = @ptrCast(@alignCast(context));
    const icon = self.canonical.dragIcon() orelse return;
    if (std.meta.eql(icon.surface, id)) self.canonical.offsetDragIcon(x, y);
}

fn dragIconRemoved(context: *anyopaque, id: SurfaceRegistry.Id) void {
    const self: *WayringDataDevice = @ptrCast(@alignCast(context));
    self.canonical.surfaceDestroyed(id);
}

pub fn publish(self: *WayringDataDevice) !void {
    std.debug.assert(self.global == null);
    self.global = try self.protocol_server.addGlobal(
        protocol.wl_data_device_manager,
        manager_version,
        WayringDataDevice,
        self,
        bindManager,
    );
}

pub fn unpublish(self: *WayringDataDevice) void {
    const global = self.global orelse unreachable;
    self.protocol_server.removeGlobal(global) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}

fn bindManager(client: *wayring.server.Client, id: u32, version: u32, self: *WayringDataDevice) !void {
    try self.createManager(client, id, version, .registry_bind);
}

const ManagerInstall = enum { registry_bind, client_initial };

fn createManager(
    self: *WayringDataDevice,
    client: *wayring.server.Client,
    id: u32,
    version: u32,
    install: ManagerInstall,
) !void {
    if (version == 0 or version > protocol.wl_data_device_manager.interface.version) return error.InvalidVersion;
    try self.managers.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Manager);
    errdefer self.allocator.destroy(value);
    value.* = .{
        .owner = self,
        .client = client,
        .resource = .init(self.allocator, id, version, .client, client.ownerHooks()),
    };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Manager, value, managerRequest, null);
    switch (install) {
        .registry_bind => try client.materialize(&value.resource.runtime),
        .client_initial => try client.installClientInitial(id, &value.resource.runtime),
    }
    self.managers.appendAssumeCapacity(value);
}

pub fn destroyClientResources(self: *WayringDataDevice, client: *wayring.server.Client) void {
    var i = self.offers.items.len;
    while (i > 0) : (i -= 1) if (self.offers.items[i - 1].client == client) self.destroyOffer(self.offers.items[i - 1]);
    i = self.devices.items.len;
    while (i > 0) : (i -= 1) if (self.devices.items[i - 1].client == client) self.destroyDevice(self.devices.items[i - 1]);
    i = self.sources.items.len;
    while (i > 0) : (i -= 1) if (self.sources.items[i - 1].client == client) self.destroySource(self.sources.items[i - 1]);
    i = self.managers.items.len;
    while (i > 0) : (i -= 1) if (self.managers.items[i - 1].client == client) self.destroyManager(self.managers.items[i - 1]);
}

fn managerRequest(_: *protocol.wl_data_device_manager.Resource, request: protocol.wl_data_device_manager.Request, value: *Manager) !void {
    switch (request) {
        .create_data_source => |args| try value.owner.createSource(value, args.id),
        .get_data_device => |args| {
            if (value.owner.seat.seatClientIdentity(value.client, args.seat) == null)
                return value.client.postImplementationError(&value.resource.runtime, "data device requires the exact live same-client wl_seat");
            try value.owner.createDevice(value, args.id);
        },
        .release => value.owner.destroyManager(value),
    }
}

fn createSource(self: *WayringDataDevice, manager: *Manager, id: u32) !void {
    try self.sources.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Source);
    errdefer self.allocator.destroy(value);
    value.* = undefined;
    const canonical_id = try self.canonical.createSource(self.clients.id(manager.client) orelse return error.InvalidClient, .{
        .context = value,
        .send = sourceSend,
        .target_preflight = sourceTargetPreflight,
        .target = sourceTarget,
        .action_preflight = sourceActionPreflight,
        .action = sourceAction,
        .cancelled_preflight = sourceCancelledPreflight,
        .cancelled = sourceCancelled,
        .selection_cancelled = sourceSelectionCancelled,
        .drop_performed_preflight = sourceDropPreflight,
        .drop_performed = sourceDrop,
        .finished_preflight = sourceFinishedPreflight,
        .finished = sourceFinished,
    }, .{ .actions = if (manager.resource.version() < 3) .{ .copy = true } else .{} });
    errdefer self.canonical.destroySource(canonical_id);
    value.* = .{ .owner = self, .client = manager.client, .resource = .init(self.allocator, id, manager.resource.version(), .client, manager.client.ownerHooks()), .id = canonical_id };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Source, value, sourceRequest, null);
    try manager.client.materialize(&value.resource.runtime);
    self.sources.appendAssumeCapacity(value);
}

fn sourceRequest(_: *protocol.wl_data_source.Resource, request: protocol.wl_data_source.Request, value: *Source) !void {
    switch (request) {
        .offer => |args| value.owner.canonical.offerMime(value.id, args.mime_type) catch |err| if (err == error.OutOfMemory) return error.OutOfMemory,
        .destroy => value.owner.destroySource(value),
        .set_actions => |args| value.owner.canonical.setSourceActions(value.id, fromWireActions(args.dnd_actions)) catch |err| switch (err) {
            error.InvalidActionMask => value.client.postProtocolError(&value.resource.runtime, @intCast(protocol.wl_data_source.@"error".invalid_action_mask), "invalid drag-and-drop action mask"),
            error.ActionsAlreadySet, error.SourceAlreadyUsed => value.client.postProtocolError(&value.resource.runtime, @intCast(protocol.wl_data_source.@"error".invalid_source), "data source is already in use or actions were already set"),
            error.OutOfMemory => value.client.postOutOfMemory(&value.resource.runtime, "preparing generated source actions"),
            else => {},
        },
    }
}

fn createDevice(self: *WayringDataDevice, manager: *Manager, id: u32) !void {
    try self.devices.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Device);
    errdefer self.allocator.destroy(value);
    value.* = .{
        .owner = self,
        .client = manager.client,
        .resource = .init(self.allocator, id, manager.resource.version(), .client, manager.client.ownerHooks()),
        .id = undefined,
    };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Device, value, deviceRequest, null);
    try manager.client.materialize(&value.resource.runtime);
    // Canonical registration can synchronously publish the current selection.
    // The generated endpoint must therefore be fully materialized first.
    value.id = try self.canonical.createDevice(self.clients.id(manager.client) orelse return error.InvalidClient, .{
        .context = value,
        .selection = deviceSelection,
        .drag_enter_prepare = deviceDragPrepare,
        .drag_enter_abort = deviceDragAbort,
        .drag_enter = deviceDragEnter,
        .drag_motion_preflight = deviceDragMotionPreflight,
        .drag_motion = deviceDragMotion,
        .drag_leave_preflight = deviceDragLeavePreflight,
        .drag_leave = deviceDragLeave,
        .drag_drop_preflight = deviceDragDropPreflight,
        .drag_drop = deviceDragDrop,
    });
    errdefer self.canonical.destroyDevice(value.id);
    self.devices.appendAssumeCapacity(value);
}

fn deviceRequest(_: *protocol.wl_data_device.Resource, request: protocol.wl_data_device.Request, value: *Device) !void {
    switch (request) {
        .set_selection => |args| {
            const source_id = if (args.source) |object_id| (value.owner.sourceIdentity(value.client, object_id) orelse return value.client.postImplementationError(&value.resource.runtime, "selection source is not exact and live")) else null;
            value.owner.canonical.setSelection(value.id, source_id, .{ .domain = .wayring_server, .value = args.serial }) catch |err| switch (err) {
                error.OutOfMemory => value.client.postOutOfMemory(&value.resource.runtime, "publishing generated selection"),
                error.SourceAlreadyUsed => value.client.postProtocolError(
                    &value.resource.runtime,
                    @intCast(protocol.wl_data_device.@"error".used_source),
                    "data source was already used",
                ),
                error.InvalidSource => if (args.source) |object_id| {
                    const source = value.client.lookup(object_id) orelse return;
                    value.client.postProtocolError(
                        source,
                        @intCast(protocol.wl_data_source.@"error".invalid_source),
                        "drag-and-drop source used for selection",
                    );
                },
                // Serial provenance and ordering are canonical policy. As on
                // the mature frontend, stale or foreign serials are ignored.
                error.Unauthorized => {},
                else => value.client.postImplementationError(&value.resource.runtime, "invalid selection request"),
            };
        },
        .release => value.owner.destroyDevice(value),
        .start_drag => |args| try value.owner.startDrag(value, args.source, args.origin, args.icon, args.serial),
    }
}

fn startDrag(self: *WayringDataDevice, device: *Device, source_object: ?u32, origin_object: u32, icon_object: ?u32, serial: u32) !void {
    const source_resource = if (source_object) |id| (self.sourceForObject(device.client, id) orelse return) else null;
    const source_id = if (source_resource) |source| source.id else null;
    const compositor = self.compositor orelse return;
    const origin = compositor.surfaceId(device.client, origin_object) orelse return;
    const icon_surface = if (icon_object) |id| (compositor.surfaceId(device.client, id) orelse return) else null;
    const icon: ?DataDevice.DragIcon = if (icon_surface) |surface| .{ .surface = surface } else null;
    const require_actions = if (source_resource) |source| source.resource.version() >= 3 else false;
    self.canonical.validateDragStart(device.id, source_id, origin, icon, .{ .domain = .wayring_server, .value = serial }, require_actions) catch |err| return handleStartError(device, source_object, err);
    if (icon_surface) |surface| switch (compositor.assignDragIconRole(device.client, surface)) {
        .assigned, .already_drag_icon => {},
        .role_conflict => return device.client.postProtocolError(&device.resource.runtime, @intCast(protocol.wl_data_device.@"error".role), "drag icon surface already has another role"),
        .not_live, .wrong_client => return,
    };
    _ = self.canonical.startDrag(device.id, source_id, origin, icon, .{ .domain = .wayring_server, .value = serial }, require_actions) catch |err| handleStartError(device, source_object, err);
}

fn handleStartError(device: *Device, source_object: ?u32, err: DataDevice.Error) void {
    switch (err) {
        error.MissingActions, error.InvalidSource => if (source_object) |id| if (device.client.lookup(id)) |source| device.client.postProtocolError(source, @intCast(protocol.wl_data_source.@"error".invalid_source), "drag-and-drop actions were not set"),
        error.SourceAlreadyUsed => device.client.postProtocolError(&device.resource.runtime, @intCast(protocol.wl_data_device.@"error".used_source), "data source was already used"),
        else => {},
    }
}

fn createOffer(self: *WayringDataDevice, device: *Device, canonical_id: DataDevice.OfferId) !*Offer {
    try self.offers.ensureUnusedCapacity(self.allocator, 1);
    const id = try device.client.reserveServerId();
    var published = false;
    errdefer if (!published) device.client.rollbackServerId(id);
    const value = try self.allocator.create(Offer);
    errdefer if (!published) self.allocator.destroy(value);
    value.* = .{ .owner = self, .client = device.client, .resource = .init(self.allocator, id, device.resource.version(), .server, device.client.ownerHooks()), .id = canonical_id, .device = device };
    errdefer if (!published) {
        value.resource.destroy();
        value.resource.deinit();
    };
    try value.resource.setHandler(Offer, value, offerRequest, null);
    try device.client.materializeServer(&value.resource.runtime);
    self.offers.appendAssumeCapacity(value);
    published = true;
    return value;
}

fn offerRequest(_: *protocol.wl_data_offer.Resource, request: protocol.wl_data_offer.Request, value: *Offer) !void {
    const info = value.owner.canonical.offerInfo(value.id);
    if (info != null and info.?.finished) switch (request) {
        .destroy => {},
        .finish => return value.client.postProtocolError(&value.resource.runtime, @intCast(protocol.wl_data_offer.@"error".invalid_finish), "drag-and-drop offer was already finished"),
        else => return value.client.postProtocolError(&value.resource.runtime, @intCast(protocol.wl_data_offer.@"error".invalid_offer), "finished drag-and-drop offer accepts only destroy"),
    };
    switch (request) {
        .accept => |args| {
            if (info) |offer| if (offer.active and args.serial != value.enter_serial) return;
            value.owner.canonical.accept(value.id, args.mime_type) catch |err| switch (err) {
                // The exact generated endpoint whose preparation failed has
                // already terminalized its own client.
                error.OutOfMemory => {},
                else => {},
            };
        },
        .receive => |args| {
            defer _ = std.c.close(args.fd);
            value.owner.canonical.receive(value.id, args.mime_type, args.fd) catch {};
        },
        .destroy => value.owner.destroyOffer(value),
        .finish => value.owner.canonical.finish(value.id) catch |err| switch (err) {
            error.OutOfMemory => {},
            else => value.client.postProtocolError(&value.resource.runtime, @intCast(protocol.wl_data_offer.@"error".invalid_finish), "drag-and-drop offer cannot be finished"),
        },
        .set_actions => |args| value.owner.canonical.setOfferActions(value.id, fromWireActions(args.dnd_actions), fromWireActions(args.preferred_action)) catch |err| switch (err) {
            error.InvalidActionMask => value.client.postProtocolError(&value.resource.runtime, @intCast(protocol.wl_data_offer.@"error".invalid_action_mask), "invalid drag-and-drop action mask"),
            error.InvalidPreferredAction => value.client.postProtocolError(&value.resource.runtime, @intCast(protocol.wl_data_offer.@"error".invalid_action), "invalid preferred drag-and-drop action"),
            error.InvalidOffer => value.client.postProtocolError(&value.resource.runtime, @intCast(protocol.wl_data_offer.@"error".invalid_offer), "actions are invalid for this offer"),
            error.OutOfMemory => {},
            else => {},
        },
    }
}

fn sourceIdentity(self: *WayringDataDevice, client: *wayring.server.Client, object_id: u32) ?DataDevice.SourceId {
    return if (self.sourceForObject(client, object_id)) |source| source.id else null;
}

fn sourceForObject(self: *WayringDataDevice, client: *wayring.server.Client, object_id: u32) ?*Source {
    const installed = client.lookup(object_id) orelse return null;
    for (self.sources.items) |value| if (value.client == client and value.resource.id() == object_id and installed == &value.resource.runtime and value.resource.runtime.state() == .live) return value;
    return null;
}

fn deviceSelection(context: *anyopaque, offer_id: ?DataDevice.OfferId) error{OutOfMemory}!void {
    const device: *Device = @ptrCast(@alignCast(context));
    const canonical_id = offer_id orelse {
        protocol.wl_data_device.@"send:selection"(&device.resource, null) catch return error.OutOfMemory;
        return;
    };
    const offer = device.owner.createOffer(device, canonical_id) catch return error.OutOfMemory;
    errdefer device.owner.destroyOffer(offer);
    const info = device.owner.canonical.offerInfo(canonical_id) orelse return error.OutOfMemory;
    const mime_types = if (info.source) |source|
        device.owner.canonical.sourceMimeTypes(source) catch return error.OutOfMemory
    else
        &.{};
    const event_count = std.math.add(usize, mime_types.len, 2) catch return error.OutOfMemory;
    const events = device.owner.allocator.alloc(wayring.server.Client.PreparedEvent, event_count) catch return error.OutOfMemory;
    defer device.owner.allocator.free(events);
    const values = device.owner.allocator.alloc(wire.Value, event_count) catch return error.OutOfMemory;
    defer device.owner.allocator.free(values);
    var maximum_bytes: usize = 24;
    for (mime_types) |mime| {
        const terminated = std.math.add(usize, mime.len, 1) catch return error.OutOfMemory;
        const padded = std.mem.alignForward(usize, terminated, 4);
        const message_bytes = std.math.add(usize, 12, padded) catch return error.OutOfMemory;
        if (message_bytes > wire.max_message_size) return error.OutOfMemory;
        maximum_bytes = std.math.add(usize, maximum_bytes, message_bytes) catch return error.OutOfMemory;
    }
    const prepared = device.client.prepareEvents(maximum_bytes) catch return error.OutOfMemory;
    var prepared_live = true;
    defer if (prepared_live) device.client.cancelPreparedEvents(prepared);

    values[0] = .{ .new_id = .{ .typed = offer.resource.id() } };
    events[0] = .{
        .resource = &device.resource.runtime,
        .opcode = 0,
        .descriptor = &protocol.wl_data_device.event_messages[0],
        .values = values[0..1],
    };
    for (mime_types, 0..) |mime, index| {
        values[index + 1] = .{ .string = mime };
        events[index + 1] = .{
            .resource = &offer.resource.runtime,
            .opcode = 0,
            .descriptor = &protocol.wl_data_offer.event_messages[0],
            .values = values[index + 1 .. index + 2],
        };
    }
    values[event_count - 1] = .{ .object = offer.resource.id() };
    events[event_count - 1] = .{
        .resource = &device.resource.runtime,
        .opcode = 5,
        .descriptor = &protocol.wl_data_device.event_messages[5],
        .values = values[event_count - 1 .. event_count],
    };
    device.client.emitPreparedEvents(prepared, events) catch return error.OutOfMemory;
    prepared_live = false;
}

/// Listener callbacks supplied when constructing the canonical owner. They
/// provide rollback and late-MIME delivery without moving semantics here.
pub fn offerRolledBack(context: *anyopaque, id: DataDevice.OfferId) void {
    const self: *WayringDataDevice = @ptrCast(@alignCast(context));
    for (self.offers.items) |value| if (std.meta.eql(value.id, id)) return self.destroyOfferResource(value, false);
}
pub fn offerMimeOffered(context: *anyopaque, id: DataDevice.OfferId, mime: []const u8) void {
    const self: *WayringDataDevice = @ptrCast(@alignCast(context));
    for (self.offers.items) |value| if (std.meta.eql(value.id, id)) {
        protocol.wl_data_offer.@"send:offer"(&value.resource, mime) catch {
            value.client.postOutOfMemory(&value.resource.runtime, "queueing generated late MIME offer");
        };
        return;
    };
}
pub fn offerSourceActionsChanged(context: *anyopaque, id: DataDevice.OfferId, actions: DataDevice.Actions) void {
    _ = context;
    _ = id;
    _ = actions;
}
pub fn offerSourceActionsPreflight(context: *anyopaque, id: DataDevice.OfferId, actions: DataDevice.Actions) error{OutOfMemory}!void {
    const self: *WayringDataDevice = @ptrCast(@alignCast(context));
    const value = findOffer(self, id) orelse return;
    if (value.published and value.resource.version() >= 3)
        try self.stageEvent(value.client, &value.resource.runtime, 1, &protocol.wl_data_offer.event_messages[1], &.{.{ .uint = toWireActions(actions) }}, 12, &.{});
}
pub fn offerActionChanged(context: *anyopaque, id: DataDevice.OfferId, actions: DataDevice.Actions) void {
    _ = context;
    _ = id;
    _ = actions;
}
pub fn offerActionPreflight(context: *anyopaque, id: DataDevice.OfferId, actions: DataDevice.Actions) error{OutOfMemory}!void {
    const self: *WayringDataDevice = @ptrCast(@alignCast(context));
    const value = findOffer(self, id) orelse return;
    if (value.published and value.resource.version() >= 3)
        try self.stageEvent(value.client, &value.resource.runtime, 2, &protocol.wl_data_offer.event_messages[2], &.{.{ .uint = toWireActions(actions) }}, 12, &.{});
}

fn sourceSend(context: *anyopaque, mime: []const u8, fd: std.posix.fd_t) void {
    const value: *Source = @ptrCast(@alignCast(context));
    protocol.wl_data_source.@"send:send"(&value.resource, mime, fd) catch
        value.client.postOutOfMemory(&value.resource.runtime, "queueing generated source send");
}
fn sourceTarget(context: *anyopaque, mime: ?[]const u8) void {
    _ = context;
    _ = mime;
}
fn sourceTargetPreflight(context: *anyopaque, mime: ?[]const u8) error{OutOfMemory}!void {
    const value: *Source = @ptrCast(@alignCast(context));
    try value.owner.stageEvent(value.client, &value.resource.runtime, 0, &protocol.wl_data_source.event_messages[0], &.{.{ .string = mime }}, 12 + if (mime) |text| std.mem.alignForward(usize, text.len + 1, 4) else 0, &.{});
}
fn sourceCancelled(context: *anyopaque) void {
    _ = context;
}
fn sourceSelectionCancelled(context: *anyopaque) void {
    const value: *Source = @ptrCast(@alignCast(context));
    protocol.wl_data_source.@"send:cancelled"(&value.resource) catch
        value.client.postOutOfMemory(&value.resource.runtime, "queueing generated selection cancellation");
}
fn sourceCancelledPreflight(context: *anyopaque) error{OutOfMemory}!void {
    const value: *Source = @ptrCast(@alignCast(context));
    try value.owner.stageEvent(value.client, &value.resource.runtime, 1, &protocol.wl_data_source.event_messages[1], &.{}, 8, &.{});
}
fn sourceAction(context: *anyopaque, actions: DataDevice.Actions) void {
    _ = context;
    _ = actions;
}
fn sourceActionPreflight(context: *anyopaque, actions: DataDevice.Actions) error{OutOfMemory}!void {
    const value: *Source = @ptrCast(@alignCast(context));
    if (value.resource.version() >= 3) try value.owner.stageEvent(value.client, &value.resource.runtime, 5, &protocol.wl_data_source.event_messages[5], &.{.{ .uint = toWireActions(actions) }}, 12, &.{});
}
fn sourceDrop(context: *anyopaque) void {
    _ = context;
}
fn sourceDropPreflight(context: *anyopaque) error{OutOfMemory}!void {
    const value: *Source = @ptrCast(@alignCast(context));
    if (value.resource.version() >= 3) try value.owner.stageEvent(value.client, &value.resource.runtime, 3, &protocol.wl_data_source.event_messages[3], &.{}, 8, &.{});
}
fn sourceFinished(context: *anyopaque) void {
    _ = context;
}
fn sourceFinishedPreflight(context: *anyopaque) error{OutOfMemory}!void {
    const value: *Source = @ptrCast(@alignCast(context));
    if (value.resource.version() >= 3) try value.owner.stageEvent(value.client, &value.resource.runtime, 4, &protocol.wl_data_source.event_messages[4], &.{}, 8, &.{});
}
fn deviceDragPrepare(context: *anyopaque, surface_id: SurfaceRegistry.Id, x: f64, y: f64, id: ?DataDevice.OfferId) error{OutOfMemory}!DataDevice.DragPreparation {
    const device: *Device = @ptrCast(@alignCast(context));
    const serial = device.owner.protocol_server.nextSerial() catch {
        device.client.postImplementationError(&device.resource.runtime, "generated data-device serial exhausted");
        return error.OutOfMemory;
    };
    device.enter_serial = serial;
    const endpoint = (device.owner.compositor orelse return error.OutOfMemory).surfaceEndpoint(surface_id) orelse return error.OutOfMemory;
    const offer = if (id) |offer_id| device.owner.createOffer(device, offer_id) catch return error.OutOfMemory else null;
    errdefer if (offer) |value| device.owner.destroyOfferResource(value, false);
    if (offer) |value| value.enter_serial = serial;
    const info = if (id) |offer_id| device.owner.canonical.offerInfo(offer_id) orelse return error.OutOfMemory else null;
    const mime_types = if (info) |value| if (value.source) |source| device.owner.canonical.sourceMimeTypes(source) catch return error.OutOfMemory else &.{} else &.{};
    const modern = offer != null and device.resource.version() >= 3;
    const event_count = 1 + (if (offer != null) @as(usize, 1) + mime_types.len + (if (modern) @as(usize, 2) else 0) else 0);
    const value_count = 5 + (event_count - 1);
    const events = device.owner.allocator.alloc(wayring.server.Client.PreparedEvent, event_count) catch return error.OutOfMemory;
    errdefer device.owner.allocator.free(events);
    const values = device.owner.allocator.alloc(wire.Value, value_count) catch return error.OutOfMemory;
    errdefer device.owner.allocator.free(values);
    var maximum_bytes: usize = 32;
    if (offer != null) maximum_bytes += 12;
    for (mime_types) |mime| maximum_bytes = std.math.add(usize, maximum_bytes, 12 + std.mem.alignForward(usize, mime.len + 1, 4)) catch return error.OutOfMemory;
    if (modern) maximum_bytes += 24;
    var event_index: usize = 0;
    var value_index: usize = 0;
    if (offer) |value| {
        values[value_index] = .{ .new_id = .{ .typed = value.resource.id() } };
        events[event_index] = .{ .resource = &device.resource.runtime, .opcode = 0, .descriptor = &protocol.wl_data_device.event_messages[0], .values = values[value_index .. value_index + 1] };
        event_index += 1;
        value_index += 1;
        for (mime_types) |mime| {
            values[value_index] = .{ .string = mime };
            events[event_index] = .{ .resource = &value.resource.runtime, .opcode = 0, .descriptor = &protocol.wl_data_offer.event_messages[0], .values = values[value_index .. value_index + 1] };
            event_index += 1;
            value_index += 1;
        }
        if (modern) {
            values[value_index] = .{ .uint = toWireActions(device.owner.canonical.sourceActions(info.?.source.?) catch return error.OutOfMemory) };
            events[event_index] = .{ .resource = &value.resource.runtime, .opcode = 1, .descriptor = &protocol.wl_data_offer.event_messages[1], .values = values[value_index .. value_index + 1] };
            event_index += 1;
            value_index += 1;
            values[value_index] = .{ .uint = toWireActions(info.?.selected_action) };
            events[event_index] = .{ .resource = &value.resource.runtime, .opcode = 2, .descriptor = &protocol.wl_data_offer.event_messages[2], .values = values[value_index .. value_index + 1] };
            event_index += 1;
            value_index += 1;
        }
    }
    values[value_index + 0] = .{ .uint = serial };
    values[value_index + 1] = .{ .object = endpoint.resource.id() };
    values[value_index + 2] = .{ .fixed = fixed(x) };
    values[value_index + 3] = .{ .fixed = fixed(y) };
    values[value_index + 4] = .{ .object = if (offer) |value| value.resource.id() else null };
    events[event_index] = .{ .resource = &device.resource.runtime, .opcode = 1, .descriptor = &protocol.wl_data_device.event_messages[1], .values = values[value_index .. value_index + 5] };
    const offers = device.owner.allocator.alloc(*Offer, if (offer == null) 0 else 1) catch return error.OutOfMemory;
    errdefer device.owner.allocator.free(offers);
    if (offer) |value| offers[0] = value;
    device.owner.staged_events.append(device.owner.allocator, .{
        .client = device.client,
        .events = events,
        .values = values,
        .offers = offers,
        .maximum_bytes = maximum_bytes,
    }) catch return error.OutOfMemory;
    return .{ .legacy_copy = id != null and device.resource.version() < 3 };
}
fn deviceDragAbort(context: *anyopaque) void {
    const device: *Device = @ptrCast(@alignCast(context));
    _ = device;
}
fn deviceDragEnter(context: *anyopaque, surface_id: SurfaceRegistry.Id, x: f64, y: f64, id: ?DataDevice.OfferId) void {
    _ = context;
    _ = surface_id;
    _ = x;
    _ = y;
    _ = id;
}

pub fn transactionFinalize(context: *anyopaque) error{OutOfMemory}!void {
    const self: *WayringDataDevice = @ptrCast(@alignCast(context));
    std.debug.assert(self.prepared_clients.items.len == 0);
    if (comptime builtin.is_test) if (self.finalize_failure) {
        self.finalize_failure = false;
        const staged = self.staged_events.items[0];
        return transactionOutOfMemory(staged.client, staged.events[0].resource);
    };
    var index: usize = 0;
    while (index < self.staged_events.items.len) {
        const client = self.staged_events.items[index].client;
        var already_prepared = false;
        for (self.prepared_clients.items) |prepared| if (prepared.client == client) {
            already_prepared = true;
            break;
        };
        if (already_prepared) {
            index += 1;
            continue;
        }
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
        index += 1;
    }
}

fn stageEvent(
    self: *WayringDataDevice,
    client: *wayring.server.Client,
    resource: *wayring.server.Resource,
    opcode: u16,
    descriptor: *const wire.MessageDescriptor,
    source_values: []const wire.Value,
    maximum_bytes: usize,
    offers: []const *Offer,
) error{OutOfMemory}!void {
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

fn failStageAfterForTest(self: *WayringDataDevice, successful_stages: usize) void {
    if (comptime !builtin.is_test) unreachable;
    self.stage_failure_after = successful_stages;
}

fn failFinalizeForTest(self: *WayringDataDevice) void {
    if (comptime !builtin.is_test) unreachable;
    self.finalize_failure = true;
}

fn transactionOutOfMemory(client: *wayring.server.Client, resource: *wayring.server.Resource) error{OutOfMemory} {
    client.postOutOfMemory(resource, "preparing generated data-device transaction");
    return error.OutOfMemory;
}

pub fn transactionCommit(context: *anyopaque) void {
    const self: *WayringDataDevice = @ptrCast(@alignCast(context));
    for (self.prepared_clients.items) |prepared| for (prepared.events) |event| {
        if (event.values.len != event.descriptor.arguments.len)
            std.debug.panic("prepared event opcode {d}: {d} values for {d} arguments", .{ event.opcode, event.values.len, event.descriptor.arguments.len });
    };
    for (self.prepared_clients.items) |prepared| prepared.client.emitPreparedEvents(prepared.batch, prepared.events) catch unreachable;
    for (self.staged_events.items) |staged| {
        for (staged.offers) |offer| offer.published = true;
    }
    self.clearTransaction(false);
}

pub fn transactionAbort(context: *anyopaque) void {
    const self: *WayringDataDevice = @ptrCast(@alignCast(context));
    self.clearTransaction(true);
}

fn clearTransaction(self: *WayringDataDevice, cancel: bool) void {
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
fn deviceDragMotion(context: *anyopaque, time: u32, x: f64, y: f64) void {
    _ = context;
    _ = time;
    _ = x;
    _ = y;
}
fn deviceDragMotionPreflight(context: *anyopaque, time: u32, x: f64, y: f64) error{OutOfMemory}!void {
    const device: *Device = @ptrCast(@alignCast(context));
    try device.owner.stageEvent(device.client, &device.resource.runtime, 3, &protocol.wl_data_device.event_messages[3], &.{ .{ .uint = time }, .{ .fixed = fixed(x) }, .{ .fixed = fixed(y) } }, 20, &.{});
}
fn deviceDragLeave(context: *anyopaque) void {
    _ = context;
}
fn deviceDragLeavePreflight(context: *anyopaque) error{OutOfMemory}!void {
    const device: *Device = @ptrCast(@alignCast(context));
    try device.owner.stageEvent(device.client, &device.resource.runtime, 2, &protocol.wl_data_device.event_messages[2], &.{}, 8, &.{});
}
fn deviceDragDrop(context: *anyopaque) void {
    _ = context;
}
fn deviceDragDropPreflight(context: *anyopaque) error{OutOfMemory}!void {
    const device: *Device = @ptrCast(@alignCast(context));
    try device.owner.stageEvent(device.client, &device.resource.runtime, 4, &protocol.wl_data_device.event_messages[4], &.{}, 8, &.{});
}

fn findOffer(self: *WayringDataDevice, id: DataDevice.OfferId) ?*Offer {
    for (self.offers.items) |offer| if (std.meta.eql(offer.id, id)) return offer;
    return null;
}
fn publishOffer(offer: *Offer, device: *Device) !void {
    if (offer.published) return;
    const info = offer.owner.canonical.offerInfo(offer.id) orelse return;
    try protocol.wl_data_device.@"send:data_offer"(&device.resource, offer.resource.id());
    if (info.source) |source| {
        for (try offer.owner.canonical.sourceMimeTypes(source)) |mime| try protocol.wl_data_offer.@"send:offer"(&offer.resource, mime);
        if (offer.resource.version() >= 3 and info.kind == .drag) {
            try protocol.wl_data_offer.@"send:source_actions"(&offer.resource, toWireActions(try offer.owner.canonical.sourceActions(source)));
            try protocol.wl_data_offer.@"send:action"(&offer.resource, toWireActions(info.selected_action));
        }
    }
    offer.published = true;
}
fn fromWireActions(value: anytype) DataDevice.Actions {
    return @bitCast(@as(u32, @intCast(value)));
}
fn toWireActions(value: DataDevice.Actions) u32 {
    return @bitCast(value);
}
fn fixed(value: f64) i32 {
    const minimum = @as(f64, @floatFromInt(std.math.minInt(i32))) / 256.0;
    const maximum = @as(f64, @floatFromInt(std.math.maxInt(i32))) / 256.0;
    return @intFromFloat(std.math.clamp(value, minimum, maximum) * 256.0);
}

fn destroyOffer(self: *WayringDataDevice, value: *Offer) void {
    self.destroyOfferResource(value, true);
}

fn destroyOfferResource(self: *WayringDataDevice, value: *Offer, retire_canonical: bool) void {
    if (retire_canonical) {
        _ = self.canonical.retireOfferFinal(value.id, value.resource.version() < 3);
        std.debug.assert(self.canonical.offerInfo(value.id) == null);
    }
    for (self.offers.items, 0..) |item, i| if (item == value) {
        _ = self.offers.swapRemove(i);
        break;
    };
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}
fn destroyDevice(self: *WayringDataDevice, value: *Device) void {
    for (self.offers.items) |offer| {
        if (offer.device == value) offer.device = null;
    }
    for (self.devices.items, 0..) |item, i| if (item == value) {
        _ = self.devices.swapRemove(i);
        break;
    };
    self.canonical.destroyDevice(value.id);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}
fn destroySource(self: *WayringDataDevice, value: *Source) void {
    _ = self.canonical.destroySourceFinal(value.id);
    if (self.canonical.sourceActions(value.id)) |_| unreachable else |err| std.debug.assert(err == error.InvalidSource);
    for (self.sources.items, 0..) |item, i| if (item == value) {
        _ = self.sources.swapRemove(i);
        break;
    };
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}
fn destroyManager(self: *WayringDataDevice, value: *Manager) void {
    for (self.managers.items, 0..) |item, i| if (item == value) {
        _ = self.managers.swapRemove(i);
        break;
    };
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}

test "generated descriptor and publication cover v4" {
    const ExpectedMessage = struct { name: []const u8, since: u32, destructor: bool = false };
    const manager_requests = [_]ExpectedMessage{
        .{ .name = "create_data_source", .since = 1 },
        .{ .name = "get_data_device", .since = 1 },
        .{ .name = "release", .since = 4, .destructor = true },
    };
    const source_requests = [_]ExpectedMessage{
        .{ .name = "offer", .since = 1 },
        .{ .name = "destroy", .since = 1, .destructor = true },
        .{ .name = "set_actions", .since = 3 },
    };
    const source_events = [_]ExpectedMessage{
        .{ .name = "target", .since = 1 },
        .{ .name = "send", .since = 1 },
        .{ .name = "cancelled", .since = 1 },
        .{ .name = "dnd_drop_performed", .since = 3 },
        .{ .name = "dnd_finished", .since = 3 },
        .{ .name = "action", .since = 3 },
    };
    const device_requests = [_]ExpectedMessage{
        .{ .name = "start_drag", .since = 1 },
        .{ .name = "set_selection", .since = 1 },
        .{ .name = "release", .since = 2, .destructor = true },
    };
    const device_events = [_]ExpectedMessage{
        .{ .name = "data_offer", .since = 1 },
        .{ .name = "enter", .since = 1 },
        .{ .name = "leave", .since = 1 },
        .{ .name = "motion", .since = 1 },
        .{ .name = "drop", .since = 1 },
        .{ .name = "selection", .since = 1 },
    };
    const offer_requests = [_]ExpectedMessage{
        .{ .name = "accept", .since = 1 },
        .{ .name = "receive", .since = 1 },
        .{ .name = "destroy", .since = 1, .destructor = true },
        .{ .name = "finish", .since = 3 },
        .{ .name = "set_actions", .since = 3 },
    };
    const offer_events = [_]ExpectedMessage{
        .{ .name = "offer", .since = 1 },
        .{ .name = "source_actions", .since = 3 },
        .{ .name = "action", .since = 3 },
    };
    inline for (.{
        .{ protocol.wl_data_device_manager.request_messages, &manager_requests },
        .{ protocol.wl_data_source.request_messages, &source_requests },
        .{ protocol.wl_data_source.event_messages, &source_events },
        .{ protocol.wl_data_device.request_messages, &device_requests },
        .{ protocol.wl_data_device.event_messages, &device_events },
        .{ protocol.wl_data_offer.request_messages, &offer_requests },
        .{ protocol.wl_data_offer.event_messages, &offer_events },
    }) |pair| {
        try std.testing.expectEqual(pair[1].len, pair[0].len);
        for (pair[0], pair[1]) |actual, expected| {
            try std.testing.expectEqualStrings(expected.name, actual.name);
            try std.testing.expectEqual(expected.since, actual.since);
            try std.testing.expectEqual(expected.destructor, actual.destructor);
        }
    }
    try std.testing.expectEqual(@as(u32, 4), protocol.wl_data_device_manager.interface.version);
    try std.testing.expectEqual(@as(u32, 4), manager_version);
    try std.testing.expectEqual(@as(i64, 0), protocol.wl_data_source.@"error".invalid_action_mask);
    try std.testing.expectEqual(@as(i64, 1), protocol.wl_data_source.@"error".invalid_source);
    try std.testing.expectEqual(@as(i64, 0), protocol.wl_data_device.@"error".role);
    try std.testing.expectEqual(@as(i64, 1), protocol.wl_data_device.@"error".used_source);
    try std.testing.expectEqual(@as(i64, 0), protocol.wl_data_offer.@"error".invalid_finish);
    try std.testing.expectEqual(@as(i64, 1), protocol.wl_data_offer.@"error".invalid_action_mask);
    try std.testing.expectEqual(@as(i64, 2), protocol.wl_data_offer.@"error".invalid_action);
    try std.testing.expectEqual(@as(i64, 3), protocol.wl_data_offer.@"error".invalid_offer);
}

test "manager publication is singular v4 and rolls back allocation failure" {
    var host: wayring.server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var adapter: WayringDataDevice = undefined;
    adapter.init(std.testing.allocator, &host, undefined, undefined, undefined, null);
    defer {
        if (adapter.global != null) adapter.unpublish();
        adapter.deinit();
    }

    var before: usize = 0;
    var globals = host.iterator();
    while (globals.next()) |_| before += 1;
    try adapter.publish();
    var managers: usize = 0;
    var total: usize = 0;
    globals = host.iterator();
    while (globals.next()) |global| {
        total += 1;
        if (std.mem.eql(u8, global.interface().name, "wl_data_device_manager")) {
            managers += 1;
            try std.testing.expectEqual(@as(u32, 4), global.version());
        }
    }
    try std.testing.expectEqual(before + 1, total);
    try std.testing.expectEqual(@as(usize, 1), managers);
    adapter.unpublish();

    globals = host.iterator();
    total = 0;
    managers = 0;
    while (globals.next()) |global| {
        total += 1;
        if (std.mem.eql(u8, global.interface().name, "wl_data_device_manager")) managers += 1;
    }
    try std.testing.expectEqual(before, total);
    try std.testing.expectEqual(@as(usize, 0), managers);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    failing.fail_index = 0;
    var failing_host: wayring.server.Server = .init(failing.allocator());
    defer failing_host.deinit();
    var failing_adapter: WayringDataDevice = undefined;
    failing_adapter.init(std.testing.allocator, &failing_host, undefined, undefined, undefined, null);
    defer failing_adapter.deinit();
    try std.testing.expectError(error.OutOfMemory, failing_adapter.publish());
    try std.testing.expect(failing_adapter.global == null);
    try std.testing.expect(failing.has_induced_failure);
}

fn testSend(client: *wayring.server.Client, object: u32, opcode: u16, descriptor: *const wire.MessageDescriptor, values: []const wire.Value) !void {
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

fn discardEvents(client: *wayring.server.Client) !void {
    while (try client.beginSend()) |batch| try client.completeSend(batch.token, batch.bytes.len);
}

const DataDeviceFixture = struct {
    host: wayring.server.Server,
    clients: ClientRegistry,
    surfaces: SurfaceRegistry,
    authority: SeatAuthority,
    mapped: WayringClients,
    compositor: WayringCompositor,
    seat: WayringSeatAdapter,
    canonical: DataDevice,
    adapter: WayringDataDevice,
    managed: *wayring.server.CoreClient,
    client_id: ClientRegistry.Id,

    fn init(self: *@This()) !void {
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
            .offer_rolled_back = offerRolledBack,
            .offer_mime_offered = offerMimeOffered,
            .offer_source_actions_preflight = offerSourceActionsPreflight,
            .offer_source_actions_changed = offerSourceActionsChanged,
            .offer_action_preflight = offerActionPreflight,
            .offer_action_changed = offerActionChanged,
        });
        self.adapter.init(std.testing.allocator, &self.host, &self.mapped, &self.seat, &self.canonical, &self.compositor);
        try self.adapter.publish();
        self.managed = try wayring.server.CoreClient.create(std.testing.allocator, &self.host, .{});
        self.client_id = try self.mapped.register(self.client());
        try testSend(self.client(), 1, 1, &protocol.wl_display.request_messages[1], &.{.{ .new_id = .{ .typed = 2 } }});
        try discardEvents(self.client());
        try self.bind("wl_seat", 3, protocol.wl_seat.interface.version);
        try self.bind("wl_data_device_manager", 4, 3);
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
        while (iterator.next()) |global| if (std.mem.eql(u8, global.interface().name, name)) return testSend(self.client(), 2, 0, &protocol.wl_registry.request_messages[0], &.{
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

test "WayringDataDevice generated wire selection lifecycle and retained offer transfer" {
    var fixture: DataDeviceFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const client = fixture.client();

    try testSend(client, 4, 0, &protocol.wl_data_device_manager.request_messages[0], &.{.{ .new_id = .{ .typed = 5 } }});
    try testSend(client, 4, 1, &protocol.wl_data_device_manager.request_messages[1], &.{ .{ .new_id = .{ .typed = 6 } }, .{ .object = 3 } });
    try testSend(client, 5, 0, &protocol.wl_data_source.request_messages[0], &.{.{ .string = "text/plain" }});
    try fixture.canonical.setFocus(fixture.client_id);
    const serial: ClientRegistry.Serial = .{ .domain = .wayring_server, .value = 71 };
    try std.testing.expect(fixture.authority.recordSelection(fixture.client_id, serial));
    try testSend(client, 6, 1, &protocol.wl_data_device.request_messages[1], &.{ .{ .object = 5 }, .{ .uint = serial.value } });
    try std.testing.expect(fixture.canonical.selectionIs(fixture.adapter.sources.items[0].id));
    try std.testing.expectEqual(@as(usize, 1), fixture.adapter.offers.items.len);

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    while (try client.beginSend()) |batch| {
        try bytes.appendSlice(std.testing.allocator, batch.bytes);
        try client.completeSend(batch.token, batch.bytes.len);
    }
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, "text/plain") != null);
    const late = "text/html";
    try fixture.canonical.offerMime(fixture.adapter.sources.items[0].id, late);
    bytes.clearRetainingCapacity();
    while (try client.beginSend()) |batch| {
        try bytes.appendSlice(std.testing.allocator, batch.bytes);
        try client.completeSend(batch.token, batch.bytes.len);
    }
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, late) != null);

    const generation = fixture.canonical.selectionGeneration();
    try testSend(client, 6, 1, &protocol.wl_data_device.request_messages[1], &.{ .{ .object = null }, .{ .uint = 999 } });
    try std.testing.expectEqual(generation, fixture.canonical.selectionGeneration());
    const offer_object = fixture.adapter.offers.items[0].resource.id();
    try testSend(client, 6, 2, &protocol.wl_data_device.request_messages[2], &.{});
    try std.testing.expectEqual(@as(usize, 0), fixture.adapter.devices.items.len);
    var pipe: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&pipe));
    defer _ = std.c.close(pipe[0]);
    defer _ = std.c.close(pipe[1]);
    try testSend(client, offer_object, 1, &protocol.wl_data_offer.request_messages[1], &.{ .{ .string = "text/plain" }, .{ .fd = pipe[1] } });
    var sent_fds: usize = 0;
    while (try client.beginSend()) |event| {
        sent_fds += event.fds.len;
        try client.completeSend(event.token, event.bytes.len);
    }
    try std.testing.expectEqual(@as(usize, 1), sent_fds);

    // Device release leaves the offer independently live and explicitly destroyable.
    try testSend(client, offer_object, 2, &protocol.wl_data_offer.request_messages[2], &.{});
    try std.testing.expectEqual(@as(usize, 0), fixture.adapter.offers.items.len);
    try std.testing.expectEqual(@as(usize, 1), fixture.adapter.sources.items.len);
}

test "focused late device materializes before synchronous selection publication" {
    var fixture: DataDeviceFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const client = fixture.client();

    try fixture.canonical.setFocus(fixture.client_id);
    try testSend(client, 4, 0, &protocol.wl_data_device_manager.request_messages[0], &.{.{ .new_id = .{ .typed = 5 } }});
    try testSend(client, 5, 0, &protocol.wl_data_source.request_messages[0], &.{.{ .string = "text/plain" }});
    try fixture.canonical.setExternalSelection(fixture.adapter.sources.items[0].id);
    try discardEvents(client);

    try testSend(client, 4, 1, &protocol.wl_data_device_manager.request_messages[1], &.{ .{ .new_id = .{ .typed = 6 } }, .{ .object = 3 } });
    try std.testing.expect(client.fatal() == null);
    try std.testing.expectEqual(@as(usize, 1), fixture.adapter.devices.items.len);
    try std.testing.expectEqual(@as(usize, 1), fixture.adapter.offers.items.len);
    const counts = fixture.canonical.resourceCounts();
    try std.testing.expectEqual(@as(usize, 1), counts.devices);
    try std.testing.expectEqual(@as(usize, 1), counts.offers);
}

test "prepared generated action stays invisible until atomic commit and abort leaves no wire" {
    var fixture: DataDeviceFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const client = fixture.client();

    try testSend(client, 4, 0, &protocol.wl_data_device_manager.request_messages[0], &.{.{ .new_id = .{ .typed = 5 } }});
    try discardEvents(client);
    const source = fixture.adapter.sources.items[0];

    try sourceActionPreflight(source, .{ .copy = true });
    try std.testing.expect((try client.beginSend()) == null);
    transactionAbort(&fixture.adapter);
    try std.testing.expect((try client.beginSend()) == null);

    try sourceActionPreflight(source, .{ .move = true });
    try transactionFinalize(&fixture.adapter);
    try std.testing.expect((try client.beginSend()) == null);
    transactionCommit(&fixture.adapter);
    const batch = (try client.beginSend()).?;
    try std.testing.expectEqual(@as(usize, 12), batch.bytes.len);
    try client.completeSend(batch.token, batch.bytes.len);
    try std.testing.expect((try client.beginSend()) == null);
}

test "generated source destruction aborts failed teardown bytes but always retires canonical drag" {
    const Failure = enum { target, action, leave, finalize };
    inline for (std.meta.tags(Failure)) |failure| {
        var fixture: DataDeviceFixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        const client = fixture.client();

        try fixture.bind("wl_compositor", 5, 6);
        try testSend(client, 5, 0, &protocol.wl_compositor.request_messages[0], &.{.{ .new_id = .{ .typed = 6 } }});
        try testSend(client, 4, 1, &protocol.wl_data_device_manager.request_messages[1], &.{ .{ .new_id = .{ .typed = 7 } }, .{ .object = 3 } });
        try testSend(client, 5, 0, &protocol.wl_compositor.request_messages[0], &.{.{ .new_id = .{ .typed = 8 } }});
        try testSend(client, 4, 0, &protocol.wl_data_device_manager.request_messages[0], &.{.{ .new_id = .{ .typed = 9 } }});
        try testSend(client, 9, 0, &protocol.wl_data_source.request_messages[0], &.{.{ .string = "text/plain" }});
        try testSend(client, 9, 2, &protocol.wl_data_source.request_messages[2], &.{.{ .uint = 1 }});
        const origin = fixture.compositor.surfaceId(client, 6).?;
        const target = fixture.compositor.surfaceId(client, 8).?;
        const serial: ClientRegistry.Serial = .{ .domain = .wayring_server, .value = 1 };
        try std.testing.expect(try fixture.authority.addPointerPress(fixture.client_id, serial, 0x110, origin));
        try testSend(client, 7, 0, &protocol.wl_data_device.request_messages[0], &.{
            .{ .object = 9 },
            .{ .object = 6 },
            .{ .object = null },
            .{ .uint = 1 },
        });
        try fixture.canonical.enter(.{ .surface = target, .client = fixture.client_id, .x = 2, .y = 3 });
        const source_id = fixture.adapter.sources.items[0].id;
        try discardEvents(client);
        switch (failure) {
            .target => fixture.adapter.failStageAfterForTest(0),
            .action => fixture.adapter.failStageAfterForTest(1),
            .leave => fixture.adapter.failStageAfterForTest(2),
            .finalize => fixture.adapter.failFinalizeForTest(),
        }

        try testSend(client, 9, 1, &protocol.wl_data_source.request_messages[1], &.{});
        try std.testing.expectEqual(@as(usize, 0), fixture.adapter.sources.items.len);
        try std.testing.expectError(error.InvalidSource, fixture.canonical.sourceActions(source_id));
        try std.testing.expect(!fixture.canonical.isDragging());
        try std.testing.expect(fixture.canonical.currentTarget() == null);
        try std.testing.expect(fixture.canonical.dragIcon() == null);
        try std.testing.expectEqual(@as(usize, 0), fixture.adapter.staged_events.items.len);
        try std.testing.expectEqual(@as(usize, 0), fixture.adapter.prepared_clients.items.len);
        try std.testing.expectEqual(fixture.adapter.offers.items.len, fixture.canonical.resourceCounts().offers);
        for (fixture.adapter.offers.items) |offer|
            try std.testing.expect(fixture.canonical.offerInfo(offer.id).?.source == null);

        var output_bytes: usize = 0;
        while (try client.beginSend()) |batch| {
            var offset: usize = 0;
            while (offset < batch.bytes.len) {
                const object_id = std.mem.readInt(u32, batch.bytes[offset..][0..4], .little);
                const size_opcode = std.mem.readInt(u32, batch.bytes[offset + 4 ..][0..4], .little);
                const message_size: usize = @intCast(size_opcode >> 16);
                try std.testing.expect(object_id != 9);
                try std.testing.expect(object_id != 7);
                output_bytes += message_size;
                offset += message_size;
            }
            try client.completeSend(batch.token, batch.bytes.len);
        }
        try std.testing.expect(output_bytes != 0);
    }
}

test "generated dropped offer and whole-client destruction are final after cancellation preparation failure" {
    const Failure = enum { cancelled, finalize };
    const Teardown = enum { offer_request, whole_client };
    inline for (std.meta.tags(Teardown)) |teardown| inline for (std.meta.tags(Failure)) |failure| {
        var fixture: DataDeviceFixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        const client = fixture.client();

        try fixture.bind("wl_compositor", 5, 6);
        try testSend(client, 5, 0, &protocol.wl_compositor.request_messages[0], &.{.{ .new_id = .{ .typed = 6 } }});
        try testSend(client, 4, 1, &protocol.wl_data_device_manager.request_messages[1], &.{ .{ .new_id = .{ .typed = 7 } }, .{ .object = 3 } });
        try testSend(client, 5, 0, &protocol.wl_compositor.request_messages[0], &.{.{ .new_id = .{ .typed = 8 } }});
        try testSend(client, 4, 0, &protocol.wl_data_device_manager.request_messages[0], &.{.{ .new_id = .{ .typed = 9 } }});
        try testSend(client, 9, 0, &protocol.wl_data_source.request_messages[0], &.{.{ .string = "text/plain" }});
        try testSend(client, 9, 2, &protocol.wl_data_source.request_messages[2], &.{.{ .uint = 1 }});
        const origin = fixture.compositor.surfaceId(client, 6).?;
        const target = fixture.compositor.surfaceId(client, 8).?;
        const serial: ClientRegistry.Serial = .{ .domain = .wayring_server, .value = 1 };
        try std.testing.expect(try fixture.authority.addPointerPress(fixture.client_id, serial, 0x110, origin));
        try testSend(client, 7, 0, &protocol.wl_data_device.request_messages[0], &.{
            .{ .object = 9 },
            .{ .object = 6 },
            .{ .object = null },
            .{ .uint = 1 },
        });
        try fixture.canonical.enter(.{ .surface = target, .client = fixture.client_id, .x = 2, .y = 3 });
        const offer = fixture.adapter.offers.items[0];
        try testSend(client, offer.resource.id(), 0, &protocol.wl_data_offer.request_messages[0], &.{ .{ .uint = offer.enter_serial }, .{ .string = "text/plain" } });
        try testSend(client, offer.resource.id(), 4, &protocol.wl_data_offer.request_messages[4], &.{ .{ .uint = 1 }, .{ .uint = 1 } });
        fixture.canonical.drop();
        try std.testing.expect(fixture.canonical.offerInfo(offer.id).?.dropped);
        try discardEvents(client);
        switch (failure) {
            .cancelled => fixture.adapter.failStageAfterForTest(0),
            .finalize => fixture.adapter.failFinalizeForTest(),
        }

        switch (teardown) {
            .offer_request => try testSend(client, offer.resource.id(), 2, &protocol.wl_data_offer.request_messages[2], &.{}),
            .whole_client => fixture.adapter.destroyClientResources(client),
        }
        try std.testing.expectEqual(@as(usize, 0), fixture.adapter.offers.items.len);
        try std.testing.expectEqual(@as(usize, 0), fixture.canonical.resourceCounts().offers);
        try std.testing.expectEqual(@as(usize, 0), fixture.adapter.staged_events.items.len);
        try std.testing.expectEqual(@as(usize, 0), fixture.adapter.prepared_clients.items.len);
        if (teardown == .whole_client) {
            try std.testing.expectEqual(@as(usize, 0), fixture.adapter.sources.items.len);
            try std.testing.expectEqual(@as(usize, 0), fixture.adapter.devices.items.len);
            try std.testing.expectEqual(@as(usize, 0), fixture.canonical.resourceCounts().sources);
            try std.testing.expectEqual(@as(usize, 0), fixture.canonical.resourceCounts().devices);
        }

        while (try client.beginSend()) |batch| {
            var offset: usize = 0;
            while (offset < batch.bytes.len) {
                const object_id = std.mem.readInt(u32, batch.bytes[offset..][0..4], .little);
                const size_opcode = std.mem.readInt(u32, batch.bytes[offset + 4 ..][0..4], .little);
                try std.testing.expect(object_id != 9);
                offset += @intCast(size_opcode >> 16);
            }
            try client.completeSend(batch.token, batch.bytes.len);
        }
    };
}

test "generated start_drag assigns a permanent icon role and follows surface lifecycle" {
    var fixture: DataDeviceFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const client = fixture.client();

    try fixture.bind("wl_compositor", 5, 6);
    try testSend(client, 5, 0, &protocol.wl_compositor.request_messages[0], &.{.{ .new_id = .{ .typed = 6 } }});
    try testSend(client, 4, 1, &protocol.wl_data_device_manager.request_messages[1], &.{ .{ .new_id = .{ .typed = 7 } }, .{ .object = 3 } });
    try testSend(client, 5, 0, &protocol.wl_compositor.request_messages[0], &.{.{ .new_id = .{ .typed = 8 } }});
    const origin = fixture.compositor.surfaceId(client, 6).?;
    const icon = fixture.compositor.surfaceId(client, 8).?;
    const serial: ClientRegistry.Serial = .{ .domain = .wayring_server, .value = 1 };
    try std.testing.expect(try fixture.authority.addPointerPress(fixture.client_id, serial, 0x110, origin));
    const selection_generation = fixture.canonical.selectionGeneration();
    try std.testing.expect(!fixture.canonical.isDragging());
    try std.testing.expect(fixture.canonical.dragIcon() == null);
    try testSend(client, 7, 0, &protocol.wl_data_device.request_messages[0], &.{
        .{ .object = null },
        .{ .object = 6 },
        .{ .object = 8 },
        .{ .uint = 1 },
    });
    try std.testing.expect(client.fatal() == null);
    try std.testing.expect(fixture.canonical.isDragging());
    try std.testing.expectEqual(icon, fixture.canonical.dragIcon().?.surface);
    try std.testing.expect(fixture.compositor.isDragIconRole(icon));
    try std.testing.expectEqual(selection_generation, fixture.canonical.selectionGeneration());
    try testSend(client, 8, 0, &protocol.wl_surface.request_messages[0], &.{});
    try std.testing.expect(fixture.canonical.isDragging());
    try std.testing.expect(fixture.canonical.dragIcon() == null);
    try testSend(client, 6, 0, &protocol.wl_surface.request_messages[0], &.{});
    fixture.canonical.surfaceDestroyed(origin);
    try std.testing.expect(!fixture.canonical.isDragging());
}
