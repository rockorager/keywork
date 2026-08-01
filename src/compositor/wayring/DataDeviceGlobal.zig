//! Compositor-owned regular clipboard policy for native Wayring clients.
//!
//! The compositor retains selection metadata and relays transfer file
//! descriptors between clients. It never reads or writes clipboard payloads.

const DataDeviceGlobal = @This();

const std = @import("std");
const linux = std.os.linux;
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const SeatGlobal = @import("SeatGlobal.zig");

const advertised_version: u32 = 4;

allocator: std.mem.Allocator,
server: *Server,
seat: *SeatGlobal,
global_name: u32,
sources: std.ArrayList(*Source) = .empty,
devices: std.ArrayList(*Device) = .empty,
offers: std.ArrayList(*Offer) = .empty,
selection: ?*Source = null,
selection_serial: u32 = 0,
focused_client: ?*Server.Client = null,

const Source = struct {
    owner: *DataDeviceGlobal,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    mime_types: std.ArrayList([]u8) = .empty,
    used: bool = false,
    actions_set: bool = false,

    fn deinit(self: *Source) void {
        for (self.mime_types.items) |mime_type| self.owner.allocator.free(mime_type);
        self.mime_types.deinit(self.owner.allocator);
        self.owner.allocator.destroy(self);
    }

    fn hasMime(self: *const Source, mime_type: []const u8) bool {
        for (self.mime_types.items) |offered| {
            if (std.mem.eql(u8, offered, mime_type)) return true;
        }
        return false;
    }
};

const Device = struct {
    owner: *DataDeviceGlobal,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    inert: bool,
};

const Offer = struct {
    owner: *DataDeviceGlobal,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    source: ?*Source,
};

pub fn init(
    self: *DataDeviceGlobal,
    allocator: std.mem.Allocator,
    server: *Server,
    seat: *SeatGlobal,
) !void {
    self.* = .{
        .allocator = allocator,
        .server = server,
        .seat = seat,
        .global_name = undefined,
    };
    self.global_name = try server.createGlobal(
        &generated.wl_data_device_manager,
        advertised_version,
        .{ .context = self, .bind = bind },
    );
}

pub fn deinit(self: *DataDeviceGlobal) void {
    std.debug.assert(self.sources.items.len == 0);
    std.debug.assert(self.devices.items.len == 0);
    std.debug.assert(self.offers.items.len == 0);
    std.debug.assert(self.selection == null);
    self.server.removeGlobal(self.global_name) catch unreachable;
    if (self.focused_client) |client| client.unreference();
    self.offers.deinit(self.allocator);
    self.devices.deinit(self.allocator);
    self.sources.deinit(self.allocator);
    self.* = undefined;
}

/// Updates the keyboard-focused client and reoffers the current selection.
/// The retained client reference permits focus teardown to trail transport
/// shutdown without leaving a dangling pointer.
pub fn setKeyboardFocus(
    self: *DataDeviceGlobal,
    client: ?*Server.Client,
) !void {
    if (self.focused_client == client) return;
    if (client) |focused| try focused.reference();
    self.invalidateOffers();
    const old_client = self.focused_client;
    self.focused_client = client;
    if (old_client) |old| old.unreference();
    if (client) |focused| self.sendSelectionToClient(focused) catch {};
}

fn bind(
    context: *anyopaque,
    client: *Server.Client,
    id: u32,
    version: u32,
) !void {
    const self: *DataDeviceGlobal = @ptrCast(@alignCast(context));
    _ = client.createResource(id, &generated.wl_data_device_manager, version, .{
        .context = self,
        .dispatch = dispatchManager,
    }) catch return client.postNoMemory();
}

fn dispatchManager(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const self: *DataDeviceGlobal = @ptrCast(@alignCast(context));
    switch (try generated.wl_data_device_manager_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .create_data_source => |request| try self.createSource(
            client,
            resource,
            request.id,
        ),
        .get_data_device => |request| try self.createDevice(
            client,
            resource,
            request.id,
            !self.seat.ownsResource(client, request.seat),
        ),
        .release => {},
    }
}

fn createSource(
    self: *DataDeviceGlobal,
    client: *Server.Client,
    manager_resource: wayring.ObjectHandle,
    id: u32,
) !void {
    const source = self.allocator.create(Source) catch
        return client.postNoMemory();
    errdefer self.allocator.destroy(source);
    self.sources.ensureUnusedCapacity(self.allocator, 1) catch
        return client.postNoMemory();
    source.* = .{
        .owner = self,
        .client = client,
        .resource = undefined,
    };
    const version = @min(
        try client.resourceVersion(
            manager_resource,
            &generated.wl_data_device_manager,
        ),
        generated.wl_data_source.version,
    );
    source.resource = client.createResource(id, &generated.wl_data_source, version, .{
        .context = source,
        .dispatch = dispatchSource,
        .destroy = destroySource,
    }) catch return client.postNoMemory();
    self.sources.appendAssumeCapacity(source);
}

fn createDevice(
    self: *DataDeviceGlobal,
    client: *Server.Client,
    manager_resource: wayring.ObjectHandle,
    id: u32,
    inert: bool,
) !void {
    const device = self.allocator.create(Device) catch
        return client.postNoMemory();
    var registered = false;
    errdefer if (!registered) self.allocator.destroy(device);
    self.devices.ensureUnusedCapacity(self.allocator, 1) catch
        return client.postNoMemory();
    device.* = .{
        .owner = self,
        .client = client,
        .resource = undefined,
        .inert = inert,
    };
    const version = @min(
        try client.resourceVersion(
            manager_resource,
            &generated.wl_data_device_manager,
        ),
        generated.wl_data_device.version,
    );
    device.resource = client.createResource(id, &generated.wl_data_device, version, .{
        .context = device,
        .dispatch = dispatchDevice,
        .destroy = destroyDevice,
    }) catch return client.postNoMemory();
    self.devices.appendAssumeCapacity(device);
    registered = true;
    if (!inert and self.focused_client == client)
        try self.sendSelectionToDevice(device);
}

fn dispatchSource(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const source: *Source = @ptrCast(@alignCast(context));
    switch (try generated.wl_data_source_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .offer => |request| try source.owner.offerMime(
            source,
            request.mime_type,
        ),
        .destroy => {},
        .set_actions => |request| try source.owner.setSourceActions(
            source,
            request.dnd_actions,
        ),
    }
}

fn offerMime(
    self: *DataDeviceGlobal,
    source: *Source,
    mime_type: []const u8,
) !void {
    if (source.hasMime(mime_type)) return;
    const copy = self.allocator.dupe(u8, mime_type) catch
        return source.client.postNoMemory();
    source.mime_types.append(self.allocator, copy) catch {
        self.allocator.free(copy);
        return source.client.postNoMemory();
    };
    for (self.offers.items) |offer| {
        if (offer.source != source) continue;
        if (offer.client.state != .active) continue;
        generated.wl_data_offer_types.events.offer(
            &offer.client.connection,
            offer.resource,
            copy,
        ) catch {
            if (offer.client == source.client)
                return offer.client.postNoMemory();
            offer.client.postNoMemory() catch {};
        };
    }
}

fn setSourceActions(
    _: *DataDeviceGlobal,
    source: *Source,
    actions: u32,
) !void {
    if (actions & ~@as(u32, 7) != 0) return source.client.postError(
        source.resource,
        @intFromEnum(generated.wl_data_source_types.@"error".invalid_action_mask),
        "invalid drag-and-drop action mask",
    );
    if (source.actions_set or source.used) return source.client.postError(
        source.resource,
        @intFromEnum(generated.wl_data_source_types.@"error".invalid_source),
        "data source actions were already fixed",
    );
    source.actions_set = true;
}

fn dispatchDevice(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const device: *Device = @ptrCast(@alignCast(context));
    switch (try generated.wl_data_device_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        // Drag-and-drop is deliberately outside this regular clipboard slice.
        .start_drag => {},
        .set_selection => |request| {
            if (!device.inert) try device.owner.claimSelection(
                device,
                request.source,
                request.serial,
            );
        },
        .release => {},
    }
}

fn claimSelection(
    self: *DataDeviceGlobal,
    device: *Device,
    source_id: ?u32,
    serial: u32,
) !void {
    if (!self.seat.acceptsSelectionSerial(device.client, serial)) return;
    const source: ?*Source = if (source_id) |id| source: {
        const object = device.client.connection.object(id) orelse return;
        const context = try device.client.resourceContext(
            .{ .id = id, .generation = object.generation },
            &generated.wl_data_source,
        );
        const candidate: *Source = @ptrCast(@alignCast(context));
        if (candidate.owner != self or candidate.client != device.client) return;
        if (candidate.actions_set) return device.client.postError(
            candidate.resource,
            @intFromEnum(generated.wl_data_source_types.@"error".invalid_source),
            "drag-and-drop source used for a selection",
        );
        if (candidate.used) return device.client.postError(
            device.resource,
            @intFromEnum(generated.wl_data_device_types.@"error".used_source),
            "data source was already used",
        );
        candidate.used = true;
        break :source candidate;
    } else null;
    try self.setSelection(source, serial, device.client);
}

fn setSelection(
    self: *DataDeviceGlobal,
    source: ?*Source,
    serial: u32,
    requester: *Server.Client,
) !void {
    if (self.selection != null and serialIsOlder(serial, self.selection_serial))
        return;
    if (self.selection == source) {
        self.selection_serial = serial;
        return;
    }
    try self.replaceSelection(source, serial, true, requester);
}

fn replaceSelection(
    self: *DataDeviceGlobal,
    source: ?*Source,
    serial: u32,
    cancel_old: bool,
    requester: ?*Server.Client,
) !void {
    const old_source = self.selection;
    self.selection = source;
    self.selection_serial = serial;
    self.invalidateOffers();
    if (self.focused_client) |client| self.sendSelectionToClient(client) catch |err| {
        if (client == requester) {
            if (cancel_old) if (old_source) |old| self.cancelSource(old) catch {};
            return err;
        }
    };
    if (cancel_old) if (old_source) |old| self.cancelSource(old) catch |err| {
        if (old.client == requester) return err;
    };
}

fn cancelSource(_: *DataDeviceGlobal, source: *Source) !void {
    generated.wl_data_source_types.events.cancelled(
        &source.client.connection,
        source.resource,
    ) catch return source.client.postNoMemory();
}

fn dispatchOffer(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const offer: *Offer = @ptrCast(@alignCast(context));
    switch (try generated.wl_data_offer_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .accept => {},
        .receive => |request| try offer.owner.receiveOffer(
            offer,
            message,
            request.mime_type,
            request.fd,
        ),
        .destroy => {},
        .finish => return client.postError(
            resource,
            @intFromEnum(generated.wl_data_offer_types.@"error".invalid_finish),
            "selection offers cannot be finished",
        ),
        .set_actions => return client.postError(
            resource,
            @intFromEnum(generated.wl_data_offer_types.@"error".invalid_offer),
            "drag-and-drop actions are invalid for a selection offer",
        ),
    }
}

fn receiveOffer(
    _: *DataDeviceGlobal,
    offer: *Offer,
    message: *wayring.Message,
    mime_type: []const u8,
    fd_index: usize,
) !void {
    const fd = try message.takeFd(fd_index);
    var fd_owned = true;
    defer if (fd_owned) {
        _ = linux.close(fd);
    };
    const source = offer.source orelse return;
    if (!source.hasMime(mime_type)) return;
    try generated.wl_data_source_types.events.send(
        &source.client.connection,
        source.resource,
        mime_type,
        fd,
    );
    fd_owned = false;
}

fn sendSelectionToClient(
    self: *DataDeviceGlobal,
    client: *Server.Client,
) !void {
    for (self.devices.items) |device| {
        if (!device.inert and device.client == client)
            try self.sendSelectionToDevice(device);
    }
}

fn sendSelectionToDevice(
    self: *DataDeviceGlobal,
    device: *Device,
) !void {
    self.queueSelectionToDevice(device) catch return device.client.postNoMemory();
}

fn queueSelectionToDevice(
    self: *DataDeviceGlobal,
    device: *Device,
) !void {
    const source = self.selection orelse return generated.wl_data_device_types.events.selection(
        &device.client.connection,
        device.resource,
        null,
    );
    const offer = try self.allocator.create(Offer);
    var registered = false;
    errdefer if (!registered) self.allocator.destroy(offer);
    try self.offers.ensureUnusedCapacity(self.allocator, 1);
    offer.* = .{
        .owner = self,
        .client = device.client,
        .resource = undefined,
        .source = source,
    };
    const version = @min(
        try device.client.resourceVersion(
            device.resource,
            &generated.wl_data_device,
        ),
        generated.wl_data_offer.version,
    );
    offer.resource = try device.client.createServerResource(
        &generated.wl_data_offer,
        version,
        .{
            .context = offer,
            .dispatch = dispatchOffer,
            .destroy = destroyOffer,
        },
    );
    self.offers.appendAssumeCapacity(offer);
    registered = true;
    try generated.wl_data_device_types.events.data_offer(
        &device.client.connection,
        device.resource,
        offer.resource,
    );
    for (source.mime_types.items) |mime_type| try generated.wl_data_offer_types.events.offer(
        &device.client.connection,
        offer.resource,
        mime_type,
    );
    try generated.wl_data_device_types.events.selection(
        &device.client.connection,
        device.resource,
        offer.resource,
    );
}

fn sourceDestroyed(self: *DataDeviceGlobal, source: *Source) void {
    for (self.offers.items) |offer| {
        if (offer.source == source) offer.source = null;
    }
    if (self.selection == source) self.replaceSelection(
        null,
        self.server.nextSerial(),
        false,
        null,
    ) catch {};
}

fn invalidateOffers(self: *DataDeviceGlobal) void {
    for (self.offers.items) |offer| offer.source = null;
}

fn destroySource(
    context: *anyopaque,
    _: *Server.Client,
    _: wayring.ObjectHandle,
) void {
    const source: *Source = @ptrCast(@alignCast(context));
    source.owner.sourceDestroyed(source);
    removeOwned(Source, &source.owner.sources, source);
    source.deinit();
}

fn destroyDevice(
    context: *anyopaque,
    _: *Server.Client,
    _: wayring.ObjectHandle,
) void {
    const device: *Device = @ptrCast(@alignCast(context));
    removeOwned(Device, &device.owner.devices, device);
    device.owner.allocator.destroy(device);
}

fn destroyOffer(
    context: *anyopaque,
    _: *Server.Client,
    _: wayring.ObjectHandle,
) void {
    const offer: *Offer = @ptrCast(@alignCast(context));
    removeOwned(Offer, &offer.owner.offers, offer);
    offer.owner.allocator.destroy(offer);
}

fn removeOwned(
    comptime T: type,
    list: *std.ArrayList(*T),
    item: *T,
) void {
    for (list.items, 0..) |candidate, index| {
        if (candidate != item) continue;
        _ = list.orderedRemove(index);
        return;
    }
    unreachable;
}

fn serialIsOlder(candidate: u32, current: u32) bool {
    return candidate -% current > std.math.maxInt(u32) / 2;
}

test "selection serial ordering handles wraparound" {
    try std.testing.expect(!serialIsOlder(10, 10));
    try std.testing.expect(!serialIsOlder(11, 10));
    try std.testing.expect(serialIsOlder(9, 10));
    try std.testing.expect(!serialIsOlder(1, std.math.maxInt(u32)));
    try std.testing.expect(serialIsOlder(std.math.maxInt(u32), 1));
}

const TestPeer = struct {
    connection: wayring.Connection,
    registry: wayring.ObjectHandle,

    const Globals = struct {
        compositor: wayring.ObjectHandle,
        seat: wayring.ObjectHandle,
        manager: wayring.ObjectHandle,
    };

    fn init(allocator: std.mem.Allocator) !TestPeer {
        const core = @import("wayring-core");
        var connection = wayring.Connection.init(
            allocator,
            .client,
            wayring.default_max_frame_size,
        );
        errdefer connection.deinit();
        _ = try core.bootstrapDisplay(&connection);
        const registry_generation = try core.getRegistry(&connection, 2);
        return .{
            .connection = connection,
            .registry = .{
                .id = 2,
                .generation = registry_generation,
            },
        };
    }

    fn deinit(self: *TestPeer) void {
        self.connection.deinit();
    }

    fn toServer(self: *TestPeer, client: *Server.Client) !void {
        try transfer(&self.connection, &client.connection, client);
    }

    fn fromServer(self: *TestPeer, client: *Server.Client) !void {
        try transfer(&client.connection, &self.connection, null);
        try client.outputDrained();
    }

    fn bindGlobals(self: *TestPeer, client: *Server.Client) !Globals {
        const core = @import("wayring-core");
        try self.toServer(client);
        try self.fromServer(client);
        var compositor_name: u32 = 0;
        var compositor_version: u32 = 0;
        var seat_name: u32 = 0;
        var seat_version: u32 = 0;
        var manager_name: u32 = 0;
        var manager_version: u32 = 0;
        while (self.connection.popMessage()) |popped| {
            var message = popped;
            defer message.deinit();
            const event = try core.decodeRegistryEvent(&message, self.registry.id);
            if (event != .global) continue;
            if (std.mem.eql(u8, event.global.interface, generated.wl_compositor.name)) {
                compositor_name = event.global.name;
                compositor_version = event.global.version;
            } else if (std.mem.eql(u8, event.global.interface, generated.wl_seat.name)) {
                seat_name = event.global.name;
                seat_version = event.global.version;
            } else if (std.mem.eql(
                u8,
                event.global.interface,
                generated.wl_data_device_manager.name,
            )) {
                manager_name = event.global.name;
                manager_version = event.global.version;
            }
        }
        try std.testing.expect(compositor_name != 0);
        try std.testing.expect(seat_name != 0);
        try std.testing.expect(manager_name != 0);
        const globals: Globals = .{
            .compositor = .{
                .id = 3,
                .generation = try core.bind(
                    &self.connection,
                    self.registry.id,
                    compositor_name,
                    generated.wl_compositor.name,
                    compositor_version,
                    3,
                    &generated.wl_compositor,
                ),
            },
            .seat = .{
                .id = 4,
                .generation = try core.bind(
                    &self.connection,
                    self.registry.id,
                    seat_name,
                    generated.wl_seat.name,
                    seat_version,
                    4,
                    &generated.wl_seat,
                ),
            },
            .manager = .{
                .id = 5,
                .generation = try core.bind(
                    &self.connection,
                    self.registry.id,
                    manager_name,
                    generated.wl_data_device_manager.name,
                    manager_version,
                    5,
                    &generated.wl_data_device_manager,
                ),
            },
        };
        try self.toServer(client);
        try self.fromServer(client);
        while (self.connection.popMessage()) |popped| {
            var message = popped;
            message.deinit();
        }
        return globals;
    }
};

fn transfer(
    sender: *wayring.Connection,
    receiver: *wayring.Connection,
    server_client: ?*Server.Client,
) !void {
    while (sender.nextBatch()) |batch| {
        var duplicated: [wayring.max_fds_per_batch]i32 = undefined;
        var duplicate_count: usize = 0;
        errdefer {
            for (duplicated[0..duplicate_count]) |fd| _ = linux.close(fd);
        }
        for (batch.fds) |fd| {
            const result = linux.dup(fd);
            if (linux.errno(result) != .SUCCESS) return error.DuplicateFdFailed;
            duplicated[duplicate_count] = @intCast(result);
            duplicate_count += 1;
        }
        const transferred = duplicated[0..duplicate_count];
        duplicate_count = 0;
        if (server_client) |client| {
            try client.receive(batch.bytes, transferred);
        } else {
            try receiver.feed(batch.bytes, transferred);
        }
        try sender.acknowledge(batch.token, batch.bytes.len);
    }
}

fn serverSurface(
    client: *Server.Client,
    handle: wayring.ObjectHandle,
) !*@import("CompositorGlobal.zig").Surface {
    const object = client.connection.object(handle.id) orelse
        return error.MissingSurface;
    return @import("CompositorGlobal.zig").surfaceFor(client, .{
        .id = handle.id,
        .generation = object.generation,
    });
}

fn receiveSelectionOffer(
    peer: *TestPeer,
    device: wayring.ObjectHandle,
    expected_mimes: []const []const u8,
) !wayring.ObjectHandle {
    var data_offer_message = peer.connection.popMessage() orelse
        return error.MissingDataOffer;
    defer data_offer_message.deinit();
    const data_offer_event = try generated.wl_data_device_types.decodeEvent(
        &peer.connection,
        device,
        &data_offer_message,
    );
    const id = switch (data_offer_event) {
        .data_offer => |event| event.id,
        else => return error.UnexpectedDataDeviceEvent,
    };
    const offer: wayring.ObjectHandle = .{
        .id = id,
        .generation = try peer.connection.registerObject(
            id,
            &generated.wl_data_offer,
            4,
        ),
    };
    try peer.connection.resumeParsing();
    for (expected_mimes) |expected| {
        var offer_message = peer.connection.popMessage() orelse
            return error.MissingMimeOffer;
        defer offer_message.deinit();
        if (offer_message.object_id != offer.id)
            return error.UnexpectedClipboardObject;
        const event = try generated.wl_data_offer_types.decodeEvent(
            &peer.connection,
            offer,
            &offer_message,
        );
        switch (event) {
            .offer => |mime| try std.testing.expectEqualStrings(
                expected,
                mime.mime_type,
            ),
            else => return error.UnexpectedDataOfferEvent,
        }
    }
    var selection_message = peer.connection.popMessage() orelse
        return error.MissingSelection;
    defer selection_message.deinit();
    const selection_event = try generated.wl_data_device_types.decodeEvent(
        &peer.connection,
        device,
        &selection_message,
    );
    switch (selection_event) {
        .selection => |selection| try std.testing.expectEqual(
            offer.id,
            selection.id.?,
        ),
        else => return error.UnexpectedDataDeviceEvent,
    }
    return offer;
}

fn expectCancelled(
    peer: *TestPeer,
    source: wayring.ObjectHandle,
) !void {
    var message = peer.connection.popMessage() orelse
        return error.MissingCancellation;
    defer message.deinit();
    if (message.object_id != source.id) return error.UnexpectedClipboardObject;
    const event = try generated.wl_data_source_types.decodeEvent(
        &peer.connection,
        source,
        &message,
    );
    if (event != .cancelled) return error.UnexpectedDataSourceEvent;
}

test "native data device relays focused selections and transfer FDs" {
    const CompositorGlobal = @import("CompositorGlobal.zig");
    const allocator = std.testing.allocator;
    var server = Server.init(allocator);
    defer server.deinit();
    var compositor: CompositorGlobal = undefined;
    try compositor.init(allocator, &server);
    defer compositor.deinit();
    var seat: SeatGlobal = undefined;
    try seat.init(
        allocator,
        &server,
        "default",
        SeatGlobal.Capability.keyboard,
        null,
    );
    defer seat.deinit();
    var data_device: DataDeviceGlobal = undefined;
    try data_device.init(allocator, &server, &seat);
    defer data_device.deinit();

    const sender_client = try server.createClient();
    defer server.destroyClient(sender_client) catch unreachable;
    const receiver_client = try server.createClient();
    defer server.destroyClient(receiver_client) catch unreachable;
    var sender = try TestPeer.init(allocator);
    defer sender.deinit();
    var receiver = try TestPeer.init(allocator);
    defer receiver.deinit();
    const sender_globals = try sender.bindGlobals(sender_client);
    const receiver_globals = try receiver.bindGlobals(receiver_client);

    const sender_surface_handle = try generated.wl_compositor_types.requests.create_surface(
        &sender.connection,
        sender_globals.compositor,
    );
    const receiver_surface_handle = try generated.wl_compositor_types.requests.create_surface(
        &receiver.connection,
        receiver_globals.compositor,
    );
    const foreign_seat = try sender.connection.allocateObject(
        &generated.wl_seat,
        4,
    );
    _ = try sender_client.createResource(
        foreign_seat.id,
        &generated.wl_seat,
        4,
        .{ .context = &data_device },
    );
    const inert_device = try generated.wl_data_device_manager_types.requests.get_data_device(
        &sender.connection,
        sender_globals.manager,
        foreign_seat,
    );
    const sender_device = try generated.wl_data_device_manager_types.requests.get_data_device(
        &sender.connection,
        sender_globals.manager,
        sender_globals.seat,
    );
    const receiver_device = try generated.wl_data_device_manager_types.requests.get_data_device(
        &receiver.connection,
        receiver_globals.manager,
        receiver_globals.seat,
    );
    try sender.toServer(sender_client);
    try receiver.toServer(receiver_client);
    const sender_surface = try serverSurface(
        sender_client,
        sender_surface_handle,
    );
    const receiver_surface = try serverSurface(
        receiver_client,
        receiver_surface_handle,
    );

    const source_one = try generated.wl_data_device_manager_types.requests.create_data_source(
        &sender.connection,
        sender_globals.manager,
    );
    try generated.wl_data_source_types.requests.offer(
        &sender.connection,
        source_one,
        "text/plain",
    );
    try generated.wl_data_source_types.requests.offer(
        &sender.connection,
        source_one,
        "text/plain",
    );
    const first_serial = try seat.keyboardEnter(sender_surface, &.{});
    try generated.wl_data_device_types.requests.set_selection(
        &sender.connection,
        inert_device,
        source_one,
        first_serial,
    );
    try generated.wl_data_device_types.requests.start_drag(
        &sender.connection,
        sender_device,
        source_one,
        sender_surface_handle,
        null,
        first_serial,
    );
    try generated.wl_data_device_types.requests.set_selection(
        &sender.connection,
        sender_device,
        source_one,
        first_serial,
    );
    try sender.toServer(sender_client);
    try data_device.setKeyboardFocus(receiver_client);
    try receiver.fromServer(receiver_client);
    const first_offer = try receiveSelectionOffer(
        &receiver,
        receiver_device,
        &.{"text/plain"},
    );
    try std.testing.expect(receiver.connection.popMessage() == null);

    try generated.wl_data_source_types.requests.offer(
        &sender.connection,
        source_one,
        "text/html",
    );
    try sender.toServer(sender_client);
    try receiver.fromServer(receiver_client);
    var late_mime_message = receiver.connection.popMessage() orelse
        return error.MissingMimeOffer;
    defer late_mime_message.deinit();
    const late_mime = try generated.wl_data_offer_types.decodeEvent(
        &receiver.connection,
        first_offer,
        &late_mime_message,
    );
    switch (late_mime) {
        .offer => |event| try std.testing.expectEqualStrings(
            "text/html",
            event.mime_type,
        ),
        else => return error.UnexpectedDataOfferEvent,
    }

    var pipe: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) != .SUCCESS)
        return error.PipeFailed;
    defer _ = linux.close(pipe[0]);
    var write_owned = true;
    defer if (write_owned) {
        _ = linux.close(pipe[1]);
    };
    try generated.wl_data_offer_types.requests.receive(
        &receiver.connection,
        first_offer,
        "text/plain",
        pipe[1],
    );
    write_owned = false;
    try receiver.toServer(receiver_client);
    try sender.fromServer(sender_client);
    var send_message = sender.connection.popMessage() orelse
        return error.MissingDataSend;
    defer send_message.deinit();
    const send_event = try generated.wl_data_source_types.decodeEvent(
        &sender.connection,
        source_one,
        &send_message,
    );
    const transfer_fd = switch (send_event) {
        .send => |event| transfer: {
            try std.testing.expectEqualStrings("text/plain", event.mime_type);
            break :transfer try send_message.takeFd(event.fd);
        },
        else => return error.UnexpectedDataSourceEvent,
    };
    const payload = "native clipboard";
    const written = linux.write(transfer_fd, payload.ptr, payload.len);
    if (linux.errno(written) != .SUCCESS) return error.WriteFailed;
    try std.testing.expectEqual(payload.len, written);
    _ = linux.close(transfer_fd);
    var received: [32]u8 = undefined;
    const received_len = linux.read(pipe[0], &received, received.len);
    if (linux.errno(received_len) != .SUCCESS) return error.ReadFailed;
    try std.testing.expectEqualStrings(payload, received[0..received_len]);

    var unsupported_pipe: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(
        &unsupported_pipe,
        .{ .CLOEXEC = true },
    )) != .SUCCESS) return error.PipeFailed;
    defer _ = linux.close(unsupported_pipe[0]);
    var unsupported_write_owned = true;
    defer if (unsupported_write_owned) {
        _ = linux.close(unsupported_pipe[1]);
    };
    try generated.wl_data_offer_types.requests.receive(
        &receiver.connection,
        first_offer,
        "application/not-offered",
        unsupported_pipe[1],
    );
    unsupported_write_owned = false;
    try receiver.toServer(receiver_client);
    try sender.fromServer(sender_client);
    try std.testing.expect(sender.connection.popMessage() == null);
    const unsupported_len = linux.read(
        unsupported_pipe[0],
        &received,
        received.len,
    );
    if (linux.errno(unsupported_len) != .SUCCESS) return error.ReadFailed;
    try std.testing.expectEqual(@as(usize, 0), unsupported_len);

    const source_two = try generated.wl_data_device_manager_types.requests.create_data_source(
        &sender.connection,
        sender_globals.manager,
    );
    try generated.wl_data_source_types.requests.offer(
        &sender.connection,
        source_two,
        "text/plain;charset=utf-8",
    );
    const second_serial = try seat.keyboardEnter(sender_surface, &.{});
    try generated.wl_data_device_types.requests.set_selection(
        &sender.connection,
        sender_device,
        source_two,
        second_serial,
    );
    try sender.toServer(sender_client);
    try sender.fromServer(sender_client);
    try expectCancelled(&sender, source_one);
    try receiver.fromServer(receiver_client);
    _ = try receiveSelectionOffer(
        &receiver,
        receiver_device,
        &.{"text/plain;charset=utf-8"},
    );

    try data_device.setKeyboardFocus(sender_client);
    try sender.fromServer(sender_client);
    _ = try receiveSelectionOffer(
        &sender,
        sender_device,
        &.{"text/plain;charset=utf-8"},
    );
    try data_device.setKeyboardFocus(receiver_client);
    try receiver.fromServer(receiver_client);
    _ = try receiveSelectionOffer(
        &receiver,
        receiver_device,
        &.{"text/plain;charset=utf-8"},
    );

    const source_three = try generated.wl_data_device_manager_types.requests.create_data_source(
        &sender.connection,
        sender_globals.manager,
    );
    try generated.wl_data_source_types.requests.offer(
        &sender.connection,
        source_three,
        "UTF8_STRING",
    );
    const foreign_serial = try seat.keyboardEnter(receiver_surface, &.{});
    try generated.wl_data_device_types.requests.set_selection(
        &sender.connection,
        sender_device,
        source_three,
        foreign_serial,
    );
    try sender.toServer(sender_client);
    try std.testing.expectEqual(
        source_two.id,
        data_device.selection.?.resource.id,
    );
    const third_serial = try seat.keyboardEnter(sender_surface, &.{});
    try generated.wl_data_device_types.requests.set_selection(
        &sender.connection,
        sender_device,
        source_three,
        third_serial,
    );
    try sender.toServer(sender_client);
    try sender.fromServer(sender_client);
    try expectCancelled(&sender, source_two);
    try receiver.fromServer(receiver_client);
    _ = try receiveSelectionOffer(
        &receiver,
        receiver_device,
        &.{"UTF8_STRING"},
    );

    try generated.wl_data_source_types.requests.destroy(
        &sender.connection,
        source_three,
    );
    try sender.toServer(sender_client);
    try receiver.fromServer(receiver_client);
    var cleared_message = receiver.connection.popMessage() orelse
        return error.MissingSelection;
    defer cleared_message.deinit();
    const cleared = try generated.wl_data_device_types.decodeEvent(
        &receiver.connection,
        receiver_device,
        &cleared_message,
    );
    switch (cleared) {
        .selection => |event| try std.testing.expect(event.id == null),
        else => return error.UnexpectedDataDeviceEvent,
    }
    try std.testing.expect(data_device.selection == null);
    try data_device.setKeyboardFocus(null);
}
