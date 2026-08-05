//! Privileged lifecycle owner for inputless transient `wl_seat` globals.

const TransientSeatGlobal = @This();

const std = @import("std");
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const SecurityContextGlobal = @import("SecurityContextGlobal.zig");
const SeatGlobal = @import("SeatGlobal.zig");

const maximum_seats = 128;
const maximum_active_seats_per_client = 32;

allocator: std.mem.Allocator,
server: *Server,
global_name: u32,
global_finalized: bool,
seats: std.ArrayList(*TransientSeat) = .empty,
listeners: std.ArrayList(SeatListener) = .empty,
next_name: u64 = 1,

pub const SeatListener = struct {
    context: *anyopaque,
    removed: *const fn (*anyopaque, *SeatGlobal) void,
};

pub const SeatIterator = struct {
    owner: *TransientSeatGlobal,
    index: usize = 0,

    pub fn next(self: *SeatIterator) ?*SeatGlobal {
        while (self.index < self.owner.seats.items.len) {
            const transient = self.owner.seats.items[self.index];
            self.index += 1;
            if (transient.active) return &transient.seat;
        }
        return null;
    }
};

const TransientSeat = struct {
    owner: *TransientSeatGlobal,
    resource: ?wayring.ObjectHandle,
    creator_identity: u64,
    name: []u8,
    seat: SeatGlobal,
    active: bool = true,
    resource_count: usize = 0,
    virtual_retains: usize = 0,
};

pub fn init(
    self: *TransientSeatGlobal,
    allocator: std.mem.Allocator,
    server: *Server,
    security: *SecurityContextGlobal,
) !void {
    self.* = .{
        .allocator = allocator,
        .server = server,
        .global_name = undefined,
        .global_finalized = false,
    };
    self.global_name = try server.createGlobal(
        &generated.ext_transient_seat_manager_v1,
        1,
        .{
            .context = self,
            .bind = bind,
            .filter_context = security,
            .filter = SecurityContextGlobal.allowUnconfined,
            .finalized = managerGlobalFinalized,
        },
    );
}

pub fn deinit(self: *TransientSeatGlobal) void {
    std.debug.assert(self.seats.items.len == 0);
    std.debug.assert(self.listeners.items.len == 0);
    self.server.removeGlobal(self.global_name) catch unreachable;
    std.debug.assert(self.global_finalized);
    self.listeners.deinit(self.allocator);
    self.seats.deinit(self.allocator);
    self.* = undefined;
}

/// Copies the listener and retains its context until removeSeatListener.
pub fn addSeatListener(
    self: *TransientSeatGlobal,
    listener: SeatListener,
) error{OutOfMemory}!void {
    for (self.listeners.items) |existing|
        std.debug.assert(existing.context != listener.context);
    try self.listeners.append(self.allocator, listener);
}

pub fn removeSeatListener(self: *TransientSeatGlobal, context: *anyopaque) void {
    for (self.listeners.items, 0..) |listener, index| {
        if (listener.context != context) continue;
        _ = self.listeners.orderedRemove(index);
        return;
    }
    unreachable;
}

/// Resolves one exact active transient seat binding owned by client.
pub fn seatForResource(
    self: *TransientSeatGlobal,
    client: *const Server.Client,
    resource_id: u32,
) ?*SeatGlobal {
    for (self.seats.items) |transient| {
        if (transient.active and transient.seat.ownsResource(client, resource_id))
            return &transient.seat;
    }
    return null;
}

/// Retains an active transient seat across virtual-device lifetime.
pub fn retainSeat(self: *TransientSeatGlobal, seat: *SeatGlobal) bool {
    for (self.seats.items) |transient| {
        if (!transient.active or &transient.seat != seat) continue;
        transient.virtual_retains = std.math.add(
            usize,
            transient.virtual_retains,
            1,
        ) catch unreachable;
        return true;
    }
    return false;
}

pub fn releaseSeat(self: *TransientSeatGlobal, seat: *SeatGlobal) void {
    for (self.seats.items) |transient| {
        if (&transient.seat != seat) continue;
        std.debug.assert(transient.virtual_retains != 0);
        transient.virtual_retains -= 1;
        destroyIfUnused(transient);
        return;
    }
    unreachable;
}

pub fn seatIterator(self: *TransientSeatGlobal) SeatIterator {
    return .{ .owner = self };
}

fn managerGlobalFinalized(context: *anyopaque) void {
    const self: *TransientSeatGlobal = @ptrCast(@alignCast(context));
    std.debug.assert(!self.global_finalized);
    self.global_finalized = true;
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *TransientSeatGlobal = @ptrCast(@alignCast(context));
    _ = client.createResource(id, &generated.ext_transient_seat_manager_v1, version, .{
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
    const self: *TransientSeatGlobal = @ptrCast(@alignCast(context));
    switch (try generated.ext_transient_seat_manager_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .create => |request| {
            const transient_resource = client.createResource(
                request.seat,
                &generated.ext_transient_seat_v1,
                1,
                .{
                    .context = self,
                    .dispatch = dispatchTransient,
                    .destroy = destroyTransient,
                },
            ) catch return client.postNoMemory();
            if (self.quotaReached(client)) {
                generated.ext_transient_seat_v1_types.events.denied(
                    &client.connection,
                    transient_resource,
                ) catch client.postNoMemory() catch {};
                return;
            }
            self.createSeat(client, transient_resource) catch |err| {
                switch (err) {
                    error.NameExhausted => client.postImplementationError(
                        "transient seat name space exhausted",
                    ) catch {},
                    else => client.postNoMemory() catch {},
                }
            };
        },
    }
}

fn createSeat(
    self: *TransientSeatGlobal,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
) !void {
    try self.seats.ensureUnusedCapacity(self.allocator, 1);
    const transient = try self.allocator.create(TransientSeat);
    errdefer self.allocator.destroy(transient);
    const generation = self.next_name;
    self.next_name = std.math.add(u64, generation, 1) catch
        return error.NameExhausted;
    const name = try std.fmt.allocPrint(self.allocator, "transient-{d}", .{generation});
    errdefer self.allocator.free(name);
    transient.* = .{
        .owner = self,
        .resource = resource,
        .creator_identity = client.identity(),
        .name = name,
        .seat = undefined,
    };
    try transient.seat.init(self.allocator, self.server, name, 0, null);
    transient.seat.setLifecycleListener(.{
        .context = transient,
        .resource_count_changed = seatResourceCountChanged,
        .global_finalized = seatGlobalFinalized,
    });
    self.seats.appendAssumeCapacity(transient);
    generated.ext_transient_seat_v1_types.events.ready(
        &client.connection,
        resource,
        transient.seat.globalName(),
    ) catch client.postNoMemory() catch {};
}

fn quotaReached(self: *const TransientSeatGlobal, client: *const Server.Client) bool {
    // Retiring globals count toward the hard total to bound clients that do
    // not acknowledge removal. Per-client policy limits only live seats.
    if (self.seats.items.len >= maximum_seats) return true;
    var client_count: usize = 0;
    for (self.seats.items) |transient| {
        if (!transient.active or transient.creator_identity != client.identity()) continue;
        client_count += 1;
        if (client_count >= maximum_active_seats_per_client) return true;
    }
    return false;
}

fn dispatchTransient(
    _: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    _ = try generated.ext_transient_seat_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    );
}

fn destroyTransient(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
) void {
    const self: *TransientSeatGlobal = @ptrCast(@alignCast(context));
    const transient = self.findByResource(client, resource) orelse return;
    transient.resource = null;
    transient.active = false;
    // Devices must relinquish capabilities while SeatGlobal is still active.
    // Their release callbacks also drain every seat-scoped input route before
    // the final virtual retain can be dropped.
    for (self.listeners.items) |listener|
        listener.removed(listener.context, &transient.seat);
    // Finalization may synchronously free transient, so this remains the final
    // access through it.
    transient.seat.removeGlobal() catch unreachable;
}

fn findByResource(
    self: *TransientSeatGlobal,
    client: *const Server.Client,
    resource: wayring.ObjectHandle,
) ?*TransientSeat {
    for (self.seats.items) |transient| if (transient.resource) |candidate| {
        if (transient.creator_identity == client.identity() and
            candidate.id == resource.id and
            candidate.generation == resource.generation)
            return transient;
    };
    return null;
}

fn seatResourceCountChanged(context: *anyopaque, count: usize) void {
    const transient: *TransientSeat = @ptrCast(@alignCast(context));
    transient.resource_count = count;
    destroyIfUnused(transient);
}

fn seatGlobalFinalized(context: *anyopaque) void {
    const transient: *TransientSeat = @ptrCast(@alignCast(context));
    destroyIfUnused(transient);
}

fn destroyIfUnused(self: *TransientSeat) void {
    if (self.resource != null or
        self.resource_count != 0 or
        self.virtual_retains != 0 or
        !self.seat.globalFinalized()) return;
    std.debug.assert(!self.active);
    const owner = self.owner;
    self.seat.clearLifecycleListener();
    self.seat.deinit();
    const index = std.mem.indexOfScalar(*TransientSeat, owner.seats.items, self) orelse
        unreachable;
    _ = owner.seats.orderedRemove(index);
    owner.allocator.free(self.name);
    owner.allocator.destroy(self);
}

test "transient resource lookup includes client identity" {
    const allocator = std.testing.allocator;
    var server = Server.init(allocator);
    defer server.deinit();
    var transport: @import("wayring-server-uring") = undefined;
    var security: SecurityContextGlobal = undefined;
    try security.init(allocator, &server, &transport);
    defer security.deinit();
    var manager: TransientSeatGlobal = undefined;
    try manager.init(allocator, &server, &security);
    defer manager.deinit();
    const first_client = try server.createClient();
    defer server.destroyClient(first_client) catch unreachable;
    const second_client = try server.createClient();
    defer server.destroyClient(second_client) catch unreachable;

    const first_resource = try first_client.createResource(
        2,
        &generated.ext_transient_seat_v1,
        1,
        .{
            .context = &manager,
            .dispatch = dispatchTransient,
            .destroy = destroyTransient,
        },
    );
    const second_resource = try second_client.createResource(
        2,
        &generated.ext_transient_seat_v1,
        1,
        .{
            .context = &manager,
            .dispatch = dispatchTransient,
            .destroy = destroyTransient,
        },
    );
    try std.testing.expectEqual(first_resource.id, second_resource.id);
    try std.testing.expectEqual(first_resource.generation, second_resource.generation);
    try manager.createSeat(first_client, first_resource);
    try manager.createSeat(second_client, second_resource);
    try std.testing.expectEqual(@as(usize, 2), manager.seats.items.len);

    try second_client.destroyResource(second_resource);
    try std.testing.expectEqual(@as(usize, 1), manager.seats.items.len);
    try std.testing.expectEqual(first_client.identity(), manager.seats.items[0].creator_identity);
    try std.testing.expect(manager.seats.items[0].active);
    try first_client.destroyResource(first_resource);
    try std.testing.expectEqual(@as(usize, 0), manager.seats.items.len);
}

test "client teardown drains transient seat resources in arbitrary order" {
    const core = @import("wayring-core");
    const allocator = std.testing.allocator;
    var server = Server.init(allocator);
    defer server.deinit();
    var transport: @import("wayring-server-uring") = undefined;
    var security: SecurityContextGlobal = undefined;
    try security.init(allocator, &server, &transport);
    defer security.deinit();
    var manager: TransientSeatGlobal = undefined;
    try manager.init(allocator, &server, &security);
    defer manager.deinit();
    const client = try server.createClient();
    var client_owned = true;
    defer if (client_owned) server.destroyClient(client) catch unreachable;

    var peer = wayring.Connection.init(allocator, .client, wayring.default_max_frame_size);
    defer peer.deinit();
    _ = try core.bootstrapDisplay(&peer);
    const registry: wayring.ObjectHandle = .{
        .id = 2,
        .generation = try core.getRegistry(&peer, 2),
    };
    try transferToServer(&peer, client);

    const peer_transient: wayring.ObjectHandle = .{
        .id = 3,
        .generation = try peer.registerObject(3, &generated.ext_transient_seat_v1, 1),
    };
    const server_transient = try client.createResource(
        peer_transient.id,
        &generated.ext_transient_seat_v1,
        1,
        .{
            .context = &manager,
            .dispatch = dispatchTransient,
            .destroy = destroyTransient,
        },
    );
    try manager.createSeat(client, server_transient);
    try transferFromServer(&peer, client);
    var seat_name: u32 = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id != registry.id) continue;
        const event = try core.decodeRegistryEvent(&message, registry.id);
        if (event == .global and std.mem.eql(u8, event.global.interface, generated.wl_seat.name))
            seat_name = event.global.name;
    }
    try std.testing.expect(seat_name != 0);
    _ = try core.bind(
        &peer,
        registry.id,
        seat_name,
        generated.wl_seat.name,
        10,
        4,
        &generated.wl_seat,
    );
    try transferToServer(&peer, client);
    try std.testing.expectEqual(@as(usize, 1), manager.seats.items.len);
    try std.testing.expectEqual(@as(usize, 1), manager.seats.items[0].resource_count);
    const transient_seat = manager.seatForResource(client, 4) orelse
        return error.ExpectedActiveTransientSeat;
    try std.testing.expectEqual(&manager.seats.items[0].seat, transient_seat);
    var active_seats = manager.seatIterator();
    try std.testing.expectEqual(transient_seat, active_seats.next().?);
    try std.testing.expect(active_seats.next() == null);
    try std.testing.expect(manager.retainSeat(transient_seat));
    try std.testing.expectEqual(@as(usize, 1), manager.seats.items[0].virtual_retains);

    try server.destroyClient(client);
    client_owned = false;
    try std.testing.expectEqual(@as(usize, 1), manager.seats.items.len);
    active_seats = manager.seatIterator();
    try std.testing.expect(active_seats.next() == null);
    manager.releaseSeat(transient_seat);
    try std.testing.expectEqual(@as(usize, 0), manager.seats.items.len);
}

test "transient seat advertises before ready and retires after ack and resources" {
    const core = @import("wayring-core");
    const FixesGlobal = @import("FixesGlobal.zig");
    const allocator = std.testing.allocator;
    var server = Server.init(allocator);
    defer server.deinit();
    var transport: @import("wayring-server-uring") = undefined;
    var security: SecurityContextGlobal = undefined;
    try security.init(allocator, &server, &transport);
    defer security.deinit();
    var fixes: FixesGlobal = undefined;
    try fixes.init(&server);
    defer fixes.deinit();
    var manager: TransientSeatGlobal = undefined;
    try manager.init(allocator, &server, &security);
    defer manager.deinit();
    const client = try server.createClient();
    defer server.destroyClient(client) catch unreachable;

    var peer = wayring.Connection.init(allocator, .client, wayring.default_max_frame_size);
    defer peer.deinit();
    _ = try core.bootstrapDisplay(&peer);
    const registry: wayring.ObjectHandle = .{
        .id = 2,
        .generation = try core.getRegistry(&peer, 2),
    };
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    var manager_name: u32 = 0;
    var fixes_name: u32 = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const event = try core.decodeRegistryEvent(&message, registry.id);
        if (event != .global) continue;
        if (std.mem.eql(u8, event.global.interface, generated.ext_transient_seat_manager_v1.name))
            manager_name = event.global.name;
        if (std.mem.eql(u8, event.global.interface, generated.wl_fixes.name)) {
            fixes_name = event.global.name;
            try std.testing.expectEqual(@as(u32, 2), event.global.version);
        }
    }
    try std.testing.expect(manager_name != 0 and fixes_name != 0);

    const manager_resource: wayring.ObjectHandle = .{
        .id = 3,
        .generation = try core.bind(
            &peer,
            registry.id,
            manager_name,
            generated.ext_transient_seat_manager_v1.name,
            1,
            3,
            &generated.ext_transient_seat_manager_v1,
        ),
    };
    const fixes_resource: wayring.ObjectHandle = .{
        .id = 4,
        .generation = try core.bind(
            &peer,
            registry.id,
            fixes_name,
            generated.wl_fixes.name,
            2,
            4,
            &generated.wl_fixes,
        ),
    };
    try transferToServer(&peer, client);
    const transient = try generated.ext_transient_seat_manager_v1_types.requests.create(
        &peer,
        manager_resource,
    );
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);

    var seat_name: u32 = 0;
    var saw_ready = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (!saw_ready) {
            try std.testing.expectEqual(registry.id, message.object_id);
            const registry_event = try core.decodeRegistryEvent(&message, registry.id);
            if (registry_event != .global) return error.ExpectedSeatAdvertisement;
            try std.testing.expectEqualStrings(
                generated.wl_seat.name,
                registry_event.global.interface,
            );
            seat_name = registry_event.global.name;
            saw_ready = true;
        } else {
            try std.testing.expectEqual(transient.id, message.object_id);
            const event = try generated.ext_transient_seat_v1_types.decodeEvent(
                &peer,
                transient,
                &message,
            );
            switch (event) {
                .ready => |ready| try std.testing.expectEqual(seat_name, ready.global_name),
                .denied => return error.UnexpectedSeatDenial,
            }
        }
    }
    try std.testing.expect(saw_ready and seat_name != 0);

    try generated.ext_transient_seat_manager_v1_types.requests.destroy(
        &peer,
        manager_resource,
    );
    const first_seat: wayring.ObjectHandle = .{
        .id = 6,
        .generation = try core.bind(
            &peer,
            registry.id,
            seat_name,
            generated.wl_seat.name,
            10,
            6,
            &generated.wl_seat,
        ),
    };
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == 1) {
            _ = try core.decodeDisplayEvent(&message);
            continue;
        }
        const event = try generated.wl_seat_types.decodeEvent(&peer, first_seat, &message);
        if (event == .capabilities)
            try std.testing.expectEqual(@as(u32, 0), event.capabilities.capabilities);
    }

    try generated.ext_transient_seat_v1_types.requests.destroy(&peer, transient);
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    var saw_remove = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == 1) {
            _ = try core.decodeDisplayEvent(&message);
            continue;
        }
        saw_remove = (try core.decodeRegistryEvent(&message, registry.id)).global_remove ==
            seat_name;
    }
    try std.testing.expect(saw_remove);

    const late_seat: wayring.ObjectHandle = .{
        .id = 7,
        .generation = try core.bind(
            &peer,
            registry.id,
            seat_name,
            generated.wl_seat.name,
            10,
            7,
            &generated.wl_seat,
        ),
    };
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    var late_capabilities = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == 1) {
            _ = try core.decodeDisplayEvent(&message);
            continue;
        }
        const event = try generated.wl_seat_types.decodeEvent(&peer, late_seat, &message);
        if (event == .capabilities)
            late_capabilities = event.capabilities.capabilities == 0;
    }
    try std.testing.expect(late_capabilities);

    // wl_registry is bootstrapped by wayring-core rather than the generated
    // protocol module, so queue this cross-module object request by wire ID.
    try peer.queueObject(
        fixes_resource,
        &generated.wl_fixes,
        2,
        &.{ .{ .object = registry.id }, .{ .uint = seat_name } },
    );
    try transferToServer(&peer, client);
    try std.testing.expectEqual(@as(usize, 1), manager.seats.items.len);
    try generated.wl_seat_types.requests.release(&peer, first_seat);
    try generated.wl_seat_types.requests.release(&peer, late_seat);
    try transferToServer(&peer, client);
    try std.testing.expectEqual(@as(usize, 0), manager.seats.items.len);
}

fn transferToServer(connection: *wayring.Connection, client: *Server.Client) !void {
    while (connection.nextBatch()) |batch| {
        try client.receive(batch.bytes, batch.fds);
        try connection.acknowledge(batch.token, batch.bytes.len);
    }
}

fn transferFromServer(connection: *wayring.Connection, client: *Server.Client) !void {
    while (client.connection.nextBatch()) |batch| {
        try connection.feed(batch.bytes, batch.fds);
        try client.connection.acknowledge(batch.token, batch.bytes.len);
    }
    try client.outputDrained();
}
