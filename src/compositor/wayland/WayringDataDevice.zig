//! Unpublished generated wl_data_device selection adapter.
//!
//! This owns wire resources only. DataDevice remains the sole clipboard and
//! drag semantic owner; drag-only requests are rejected until the DnD wave.

const WayringDataDevice = @This();

const builtin = @import("builtin");
const std = @import("std");
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

const test_manager_version = 3;

const Manager = struct { owner: *WayringDataDevice, client: *wayring.server.Client, resource: protocol.wl_data_device_manager.Resource };
const Source = struct { owner: *WayringDataDevice, client: *wayring.server.Client, resource: protocol.wl_data_source.Resource, id: DataDevice.SourceId };
const Device = struct { owner: *WayringDataDevice, client: *wayring.server.Client, resource: protocol.wl_data_device.Resource, id: DataDevice.DeviceId };
const Offer = struct { owner: *WayringDataDevice, client: *wayring.server.Client, resource: protocol.wl_data_offer.Resource, id: DataDevice.OfferId, device: ?*Device };

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

pub fn init(
    self: *WayringDataDevice,
    allocator: std.mem.Allocator,
    protocol_server: *wayring.server.Server,
    clients: *WayringClients,
    seat: *WayringSeatAdapter,
    canonical: *DataDevice,
) void {
    self.* = .{
        .allocator = allocator,
        .protocol_server = protocol_server,
        .clients = clients,
        .seat = seat,
        .canonical = canonical,
    };
}

pub fn deinit(self: *WayringDataDevice) void {
    std.debug.assert(self.global == null and self.managers.items.len == 0 and self.sources.items.len == 0 and self.devices.items.len == 0 and self.offers.items.len == 0);
    self.managers.deinit(self.allocator);
    self.sources.deinit(self.allocator);
    self.devices.deinit(self.allocator);
    self.offers.deinit(self.allocator);
    self.* = undefined;
}

/// Adds the generated manager only to a test server's registry. Production
/// assembly neither constructs this adapter nor has a callable publication
/// path, so the incomplete v3 DnD surface cannot be advertised accidentally.
pub fn installUnpublishedForTest(self: *WayringDataDevice) !void {
    if (comptime !builtin.is_test) @compileError("generated data-device installation is test-only");
    std.debug.assert(self.global == null);
    self.global = try self.protocol_server.addGlobal(
        protocol.wl_data_device_manager,
        test_manager_version,
        WayringDataDevice,
        self,
        bindManager,
    );
}

pub fn uninstallUnpublishedForTest(self: *WayringDataDevice) void {
    if (comptime !builtin.is_test) @compileError("generated data-device installation is test-only");
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
        .target = sourceTarget,
        .action = sourceAction,
        .cancelled = sourceCancelled,
        .selection_cancelled = sourceCancelled,
        .drop_performed = sourceDrop,
        .finished = sourceFinished,
    }, .{});
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
        .set_actions => value.client.postImplementationError(&value.resource.runtime, "drag-and-drop source actions are not implemented"),
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
        .drag_enter = deviceDragEnter,
        .drag_motion = deviceDragMotion,
        .drag_leave = deviceDragLeave,
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
        .start_drag => value.client.postImplementationError(&value.resource.runtime, "drag-and-drop is not implemented"),
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
    switch (request) {
        .accept => |args| value.owner.canonical.accept(value.id, args.mime_type) catch {},
        .receive => |args| {
            defer _ = std.c.close(args.fd);
            value.owner.canonical.receive(value.id, args.mime_type, args.fd) catch {};
        },
        .destroy => value.owner.destroyOffer(value),
        .finish, .set_actions => value.client.postImplementationError(&value.resource.runtime, "drag-and-drop offer requests are not implemented"),
    }
}

fn sourceIdentity(self: *WayringDataDevice, client: *wayring.server.Client, object_id: u32) ?DataDevice.SourceId {
    const installed = client.lookup(object_id) orelse return null;
    for (self.sources.items) |value| if (value.client == client and value.resource.id() == object_id and installed == &value.resource.runtime and value.resource.runtime.state() == .live) return value.id;
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
    for (self.offers.items) |value| if (std.meta.eql(value.id, id)) return self.destroyOffer(value);
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

fn sourceSend(context: *anyopaque, mime: []const u8, fd: std.posix.fd_t) void {
    const value: *Source = @ptrCast(@alignCast(context));
    protocol.wl_data_source.@"send:send"(&value.resource, mime, fd) catch
        value.client.postOutOfMemory(&value.resource.runtime, "queueing generated source send");
}
fn sourceTarget(context: *anyopaque, mime: ?[]const u8) void {
    const value: *Source = @ptrCast(@alignCast(context));
    protocol.wl_data_source.@"send:target"(&value.resource, mime) catch
        value.client.postOutOfMemory(&value.resource.runtime, "queueing generated source target");
}
fn sourceCancelled(context: *anyopaque) void {
    const value: *Source = @ptrCast(@alignCast(context));
    protocol.wl_data_source.@"send:cancelled"(&value.resource) catch
        value.client.postOutOfMemory(&value.resource.runtime, "queueing generated source cancellation");
}
fn sourceAction(_: *anyopaque, _: DataDevice.Actions) void {}
fn sourceDrop(_: *anyopaque) void {}
fn sourceFinished(_: *anyopaque) void {}
fn deviceDragPrepare(_: *anyopaque, _: ?DataDevice.OfferId) error{OutOfMemory}!DataDevice.DragPreparation {
    return .{};
}
fn deviceDragEnter(_: *anyopaque, _: @import("../SurfaceRegistry.zig").Id, _: f64, _: f64, _: ?DataDevice.OfferId) void {}
fn deviceDragMotion(_: *anyopaque, _: u32, _: f64, _: f64) void {}
fn deviceDragLeave(_: *anyopaque) void {}
fn deviceDragDrop(_: *anyopaque) void {}

fn destroyOffer(self: *WayringDataDevice, value: *Offer) void {
    for (self.offers.items, 0..) |item, i| if (item == value) {
        _ = self.offers.swapRemove(i);
        break;
    };
    self.canonical.destroyOffer(value.id);
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
    for (self.sources.items, 0..) |item, i| if (item == value) {
        _ = self.sources.swapRemove(i);
        break;
    };
    self.canonical.destroySource(value.id);
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

test "generated descriptor covers v4 while unpublished selection hook is capped at v3" {
    try std.testing.expectEqual(@as(u32, 4), protocol.wl_data_device_manager.interface.version);
    try std.testing.expectEqual(@as(u32, 3), test_manager_version);
    try std.testing.expect(!@hasDecl(WayringDataDevice, "publish"));
    try std.testing.expectEqualStrings("create_data_source", protocol.wl_data_device_manager.request_messages[0].name);
    try std.testing.expectEqualStrings("get_data_device", protocol.wl_data_device_manager.request_messages[1].name);
    try std.testing.expectEqualStrings("start_drag", protocol.wl_data_device.request_messages[0].name);
    try std.testing.expectEqualStrings("set_selection", protocol.wl_data_device.request_messages[1].name);
    try std.testing.expectEqualStrings("receive", protocol.wl_data_offer.request_messages[1].name);
}

test "test-only manager install is singular v3 and rolls back allocation failure" {
    var host: wayring.server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var adapter: WayringDataDevice = undefined;
    adapter.init(std.testing.allocator, &host, undefined, undefined, undefined);
    defer {
        if (adapter.global != null) adapter.uninstallUnpublishedForTest();
        adapter.deinit();
    }

    var before: usize = 0;
    var globals = host.iterator();
    while (globals.next()) |_| before += 1;
    try adapter.installUnpublishedForTest();
    var managers: usize = 0;
    var total: usize = 0;
    globals = host.iterator();
    while (globals.next()) |global| {
        total += 1;
        if (std.mem.eql(u8, global.interface().name, "wl_data_device_manager")) {
            managers += 1;
            try std.testing.expectEqual(@as(u32, 3), global.version());
        }
    }
    try std.testing.expectEqual(before + 1, total);
    try std.testing.expectEqual(@as(usize, 1), managers);
    adapter.uninstallUnpublishedForTest();

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
    failing_adapter.init(std.testing.allocator, &failing_host, undefined, undefined, undefined);
    defer failing_adapter.deinit();
    try std.testing.expectError(error.OutOfMemory, failing_adapter.installUnpublishedForTest());
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
            .selection_changed = noopChanged,
            .drag_changed = noopChanged,
            .offer_rolled_back = offerRolledBack,
            .offer_mime_offered = offerMimeOffered,
        });
        self.adapter.init(std.testing.allocator, &self.host, &self.mapped, &self.seat, &self.canonical);
        try self.adapter.installUnpublishedForTest();
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
        self.adapter.uninstallUnpublishedForTest();
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

test "deferred generated start_drag terminalizes offender without canonical drag mutation" {
    var fixture: DataDeviceFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const client = fixture.client();

    try fixture.bind("wl_compositor", 5, 6);
    try testSend(client, 5, 0, &protocol.wl_compositor.request_messages[0], &.{.{ .new_id = .{ .typed = 6 } }});
    try testSend(client, 4, 1, &protocol.wl_data_device_manager.request_messages[1], &.{ .{ .new_id = .{ .typed = 7 } }, .{ .object = 3 } });
    const selection_generation = fixture.canonical.selectionGeneration();
    try std.testing.expect(!fixture.canonical.isDragging());
    try std.testing.expect(fixture.canonical.dragIcon() == null);
    try testSend(client, 7, 0, &protocol.wl_data_device.request_messages[0], &.{
        .{ .object = null },
        .{ .object = 6 },
        .{ .object = null },
        .{ .uint = 1 },
    });
    const fatal = client.fatal().?;
    try std.testing.expectEqual(wayring.server.Fatal.Kind.implementation, fatal.kind);
    try std.testing.expectEqual(@as(u32, 7), fatal.object_id);
    try std.testing.expect(fatal.opcode == null);
    try std.testing.expect(fatal.protocol_code == null);
    try std.testing.expect(fatal.interface == &protocol.wl_data_device.interface);
    try std.testing.expect(fatal.message == null);
    try std.testing.expectEqualStrings("wl_data_device", fatal.interface.?.name);
    try std.testing.expectEqualStrings("drag-and-drop is not implemented", fatal.detail());
    try std.testing.expect(!fixture.canonical.isDragging());
    try std.testing.expect(fixture.canonical.dragIcon() == null);
    try std.testing.expectEqual(selection_generation, fixture.canonical.selectionGeneration());
}
