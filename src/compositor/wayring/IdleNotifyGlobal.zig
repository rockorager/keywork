//! Native seat-scoped user idle notifications.

const IdleNotifyGlobal = @This();

const std = @import("std");
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const SeatGlobal = @import("SeatGlobal.zig");

const advertised_version: u32 = 2;

allocator: std.mem.Allocator,
server: *Server,
seat: *SeatGlobal,
listener: Listener,
global_name: u32,
notifications: std.ArrayList(*Notification) = .empty,
inhibited: bool = false,

pub const Listener = struct {
    context: *anyopaque,
    now: *const fn (*anyopaque) i96,
    schedule: *const fn (*anyopaque, ?u64) void,
};

const Notification = struct {
    owner: *IdleNotifyGlobal,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    timeout_milliseconds: u32,
    deadline_nanoseconds: i96,
    obey_inhibitors: bool,
    idle: bool = false,

    fn restart(self: *Notification, timestamp: i96) void {
        self.deadline_nanoseconds = deadline(timestamp, self.timeout_milliseconds);
    }

    fn setIdle(self: *Notification, idle: bool) void {
        if (self.idle == idle or self.client.state != .active) return;
        if (idle) {
            generated.ext_idle_notification_v1_types.events.idled(
                &self.client.connection,
                self.resource,
            ) catch {
                self.client.postNoMemory() catch {};
                return;
            };
        } else {
            generated.ext_idle_notification_v1_types.events.resumed(
                &self.client.connection,
                self.resource,
            ) catch {
                self.client.postNoMemory() catch {};
                return;
            };
        }
        self.idle = idle;
    }

    fn deinit(self: *Notification) void {
        const owner = self.owner;
        for (owner.notifications.items, 0..) |candidate, index| {
            if (candidate != self) continue;
            _ = owner.notifications.orderedRemove(index);
            owner.allocator.destroy(self);
            owner.reschedule();
            return;
        }
        unreachable;
    }
};

pub fn init(
    self: *IdleNotifyGlobal,
    allocator: std.mem.Allocator,
    server: *Server,
    seat: *SeatGlobal,
    listener: Listener,
) !void {
    self.* = .{
        .allocator = allocator,
        .server = server,
        .seat = seat,
        .listener = listener,
        .global_name = undefined,
    };
    self.global_name = try server.createGlobal(
        &generated.ext_idle_notifier_v1,
        advertised_version,
        .{ .context = self, .bind = bind },
    );
}

pub fn deinit(self: *IdleNotifyGlobal) void {
    std.debug.assert(self.notifications.items.len == 0);
    self.listener.schedule(self.listener.context, null);
    self.server.removeGlobal(self.global_name) catch unreachable;
    self.notifications.deinit(self.allocator);
    self.* = undefined;
}

pub fn notifyActivity(self: *IdleNotifyGlobal) void {
    const timestamp = self.listener.now(self.listener.context);
    for (self.notifications.items) |notification| {
        notification.setIdle(false);
        notification.restart(timestamp);
    }
    self.reschedule();
}

pub fn setInhibited(self: *IdleNotifyGlobal, inhibited: bool) void {
    if (self.inhibited == inhibited) return;
    self.inhibited = inhibited;
    for (self.notifications.items) |notification| {
        if (notification.obey_inhibitors) notification.setIdle(false);
    }
    self.reschedule();
}

pub fn handleTimer(self: *IdleNotifyGlobal) void {
    self.reschedule();
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *IdleNotifyGlobal = @ptrCast(@alignCast(context));
    _ = client.createResource(id, &generated.ext_idle_notifier_v1, version, .{
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
    const self: *IdleNotifyGlobal = @ptrCast(@alignCast(context));
    switch (try generated.ext_idle_notifier_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .get_idle_notification => |request| try self.createNotification(
            client,
            resource,
            request.id,
            request.timeout,
            request.seat,
            true,
        ),
        .get_input_idle_notification => |request| try self.createNotification(
            client,
            resource,
            request.id,
            request.timeout,
            request.seat,
            false,
        ),
    }
}

fn createNotification(
    self: *IdleNotifyGlobal,
    client: *Server.Client,
    manager_resource: wayring.ObjectHandle,
    id: u32,
    timeout_milliseconds: u32,
    seat_resource_id: u32,
    obey_inhibitors: bool,
) !void {
    if (!self.seat.ownsResource(client, seat_resource_id)) return error.WrongSeat;
    const notification = self.allocator.create(Notification) catch
        return client.postNoMemory();
    errdefer self.allocator.destroy(notification);
    self.notifications.ensureUnusedCapacity(self.allocator, 1) catch
        return client.postNoMemory();
    const version = try client.resourceVersion(
        manager_resource,
        &generated.ext_idle_notifier_v1,
    );
    notification.* = .{
        .owner = self,
        .client = client,
        .resource = undefined,
        .timeout_milliseconds = timeout_milliseconds,
        .deadline_nanoseconds = deadline(
            self.listener.now(self.listener.context),
            timeout_milliseconds,
        ),
        .obey_inhibitors = obey_inhibitors,
    };
    notification.resource = client.createResource(
        id,
        &generated.ext_idle_notification_v1,
        version,
        .{
            .context = notification,
            .dispatch = dispatchNotification,
            .destroy = destroyNotification,
        },
    ) catch return client.postNoMemory();
    self.notifications.appendAssumeCapacity(notification);
    self.reschedule();
}

fn dispatchNotification(
    _: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    switch (try generated.ext_idle_notification_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
    }
}

fn destroyNotification(
    context: *anyopaque,
    _: *Server.Client,
    _: wayring.ObjectHandle,
) void {
    const notification: *Notification = @ptrCast(@alignCast(context));
    notification.deinit();
}

fn reschedule(self: *IdleNotifyGlobal) void {
    const timestamp = self.listener.now(self.listener.context);
    var earliest: ?i96 = null;
    for (self.notifications.items) |notification| {
        if (notification.idle or
            (self.inhibited and notification.obey_inhibitors)) continue;
        if (notification.deadline_nanoseconds <= timestamp) {
            notification.setIdle(true);
            continue;
        }
        earliest = if (earliest) |current|
            @min(current, notification.deadline_nanoseconds)
        else
            notification.deadline_nanoseconds;
    }
    self.listener.schedule(
        self.listener.context,
        if (earliest) |target| delayMilliseconds(timestamp, target) else null,
    );
}

fn deadline(timestamp: i96, timeout_milliseconds: u32) i96 {
    // Zero means as soon as the seat is inactive, not synchronously within an
    // activity callback. One timer tick coalesces activity in the current turn.
    const effective_timeout = @max(timeout_milliseconds, 1);
    return timestamp + @as(i96, effective_timeout) * std.time.ns_per_ms;
}

fn delayMilliseconds(timestamp: i96, target: i96) u64 {
    std.debug.assert(target > timestamp);
    const nanoseconds = target - timestamp;
    return @intCast(@divFloor(
        nanoseconds + std.time.ns_per_ms - 1,
        std.time.ns_per_ms,
    ));
}

test "idle notification delays round up" {
    try std.testing.expectEqual(@as(i96, 1_000_000), deadline(0, 0));
    try std.testing.expectEqual(@as(i96, 100_000_000), deadline(0, 100));
    try std.testing.expectEqual(@as(u64, 1), delayMilliseconds(10, 11));
    try std.testing.expectEqual(@as(u64, 1), delayMilliseconds(10, 1_000_010));
    try std.testing.expectEqual(@as(u64, 2), delayMilliseconds(10, 1_000_011));
}

test "idle notifications track activity and inhibitors after manager destruction" {
    const core = @import("wayring-core");

    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var seat: SeatGlobal = undefined;
    try seat.init(
        std.testing.allocator,
        &server,
        "default",
        SeatGlobal.Capability.keyboard,
        null,
    );
    defer seat.deinit();
    var clock: FakeClock = .{};
    var idle: IdleNotifyGlobal = undefined;
    try idle.init(std.testing.allocator, &server, &seat, clock.listener());
    defer idle.deinit();

    const client = try server.createClient();
    defer server.destroyClient(client) catch unreachable;
    var peer = wayring.Connection.init(
        std.testing.allocator,
        .client,
        wayring.default_max_frame_size,
    );
    defer peer.deinit();
    _ = try core.bootstrapDisplay(&peer);
    const registry: wayring.ObjectHandle = .{
        .id = 2,
        .generation = try core.getRegistry(&peer, 2),
    };
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);

    var seat_name: u32 = 0;
    var idle_name: u32 = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const global = (try core.decodeRegistryEvent(&message, registry.id)).global;
        if (std.mem.eql(u8, global.interface, generated.wl_seat.name))
            seat_name = global.name;
        if (std.mem.eql(u8, global.interface, generated.ext_idle_notifier_v1.name)) {
            try std.testing.expectEqual(advertised_version, global.version);
            idle_name = global.name;
        }
    }
    try std.testing.expect(seat_name != 0);
    try std.testing.expect(idle_name != 0);

    const seat_resource: wayring.ObjectHandle = .{
        .id = 3,
        .generation = try core.bind(
            &peer,
            registry.id,
            seat_name,
            generated.wl_seat.name,
            10,
            3,
            &generated.wl_seat,
        ),
    };
    const manager: wayring.ObjectHandle = .{
        .id = 4,
        .generation = try core.bind(
            &peer,
            registry.id,
            idle_name,
            generated.ext_idle_notifier_v1.name,
            advertised_version,
            4,
            &generated.ext_idle_notifier_v1,
        ),
    };
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == seat_resource.id) {
            _ = try generated.wl_seat_types.decodeEvent(&peer, seat_resource, &message);
        } else if (message.object_id == 1) {
            _ = try core.decodeDisplayEvent(&message);
        } else return error.UnexpectedIdleSetupEvent;
    }

    const ordinary = try generated.ext_idle_notifier_v1_types.requests.get_idle_notification(
        &peer,
        manager,
        100,
        seat_resource,
    );
    const input = try generated.ext_idle_notifier_v1_types.requests.get_input_idle_notification(
        &peer,
        manager,
        200,
        seat_resource,
    );
    const zero = try generated.ext_idle_notifier_v1_types.requests.get_idle_notification(
        &peer,
        manager,
        0,
        seat_resource,
    );
    try generated.ext_idle_notifier_v1_types.requests.destroy(&peer, manager);
    try transferToServer(&peer, client);
    try std.testing.expectEqual(Server.ClientState.active, client.state);
    try std.testing.expectEqual(@as(usize, 3), idle.notifications.items.len);
    try std.testing.expectEqual(@as(?u64, 1), clock.scheduled_milliseconds);
    try expectNotificationEvents(&peer, client, zero, &.{});

    clock.now_nanoseconds = std.time.ns_per_ms;
    idle.handleTimer();
    try std.testing.expectEqual(@as(?u64, 99), clock.scheduled_milliseconds);
    try expectNotificationEvents(&peer, client, zero, &.{.idled});
    idle.notifyActivity();
    try std.testing.expectEqual(@as(?u64, 1), clock.scheduled_milliseconds);
    try expectNotificationEvents(&peer, client, zero, &.{.resumed});
    idle.notifyActivity();
    try std.testing.expectEqual(@as(?u64, 1), clock.scheduled_milliseconds);
    try expectNotificationEvents(&peer, client, zero, &.{});
    try generated.ext_idle_notification_v1_types.requests.destroy(&peer, zero);
    try transferToServer(&peer, client);
    try std.testing.expectEqual(@as(usize, 2), idle.notifications.items.len);
    try std.testing.expectEqual(@as(?u64, 100), clock.scheduled_milliseconds);
    try expectIdleEvents(&peer, client, ordinary, input, &.{});

    clock.now_nanoseconds = 101 * std.time.ns_per_ms;
    idle.handleTimer();
    try std.testing.expectEqual(@as(?u64, 100), clock.scheduled_milliseconds);
    try expectIdleEvents(&peer, client, ordinary, input, &.{.ordinary_idled});

    idle.notifyActivity();
    try std.testing.expectEqual(@as(?u64, 100), clock.scheduled_milliseconds);
    try expectIdleEvents(&peer, client, ordinary, input, &.{.ordinary_resumed});

    idle.setInhibited(true);
    try std.testing.expectEqual(@as(?u64, 200), clock.scheduled_milliseconds);
    try expectIdleEvents(&peer, client, ordinary, input, &.{});

    clock.now_nanoseconds = 201 * std.time.ns_per_ms;
    idle.handleTimer();
    try std.testing.expectEqual(@as(?u64, 100), clock.scheduled_milliseconds);
    try expectIdleEvents(&peer, client, ordinary, input, &.{});

    clock.now_nanoseconds = 301 * std.time.ns_per_ms;
    idle.handleTimer();
    try std.testing.expectEqual(@as(?u64, null), clock.scheduled_milliseconds);
    try expectIdleEvents(&peer, client, ordinary, input, &.{.input_idled});

    idle.setInhibited(false);
    try std.testing.expectEqual(@as(?u64, null), clock.scheduled_milliseconds);
    try expectIdleEvents(&peer, client, ordinary, input, &.{.ordinary_idled});

    idle.notifyActivity();
    try std.testing.expectEqual(@as(?u64, 100), clock.scheduled_milliseconds);
    try expectIdleEvents(
        &peer,
        client,
        ordinary,
        input,
        &.{ .ordinary_resumed, .input_resumed },
    );
    idle.notifyActivity();
    try expectIdleEvents(&peer, client, ordinary, input, &.{});

    try generated.ext_idle_notification_v1_types.requests.destroy(&peer, ordinary);
    try generated.ext_idle_notification_v1_types.requests.destroy(&peer, input);
    try transferToServer(&peer, client);
    try std.testing.expectEqual(Server.ClientState.active, client.state);
    try std.testing.expectEqual(@as(usize, 0), idle.notifications.items.len);
    try std.testing.expectEqual(@as(?u64, null), clock.scheduled_milliseconds);
}

const FakeClock = struct {
    now_nanoseconds: i96 = 0,
    scheduled_milliseconds: ?u64 = null,

    fn listener(self: *FakeClock) Listener {
        return .{
            .context = self,
            .now = now,
            .schedule = schedule,
        };
    }

    fn now(context: *anyopaque) i96 {
        const self: *FakeClock = @ptrCast(@alignCast(context));
        return self.now_nanoseconds;
    }

    fn schedule(context: *anyopaque, delay_milliseconds: ?u64) void {
        const self: *FakeClock = @ptrCast(@alignCast(context));
        self.scheduled_milliseconds = delay_milliseconds;
    }
};

const ExpectedIdleEvent = enum {
    ordinary_idled,
    ordinary_resumed,
    input_idled,
    input_resumed,
};

const ExpectedNotificationEvent = enum { idled, resumed };

fn expectNotificationEvents(
    peer: *wayring.Connection,
    client: *Server.Client,
    notification: wayring.ObjectHandle,
    expected: []const ExpectedNotificationEvent,
) !void {
    const core = @import("wayring-core");
    try transferFromServer(peer, client);
    var event_index: usize = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == 1) {
            _ = try core.decodeDisplayEvent(&message);
            continue;
        }
        if (message.object_id != notification.id) return error.UnexpectedIdleEvent;
        const actual: ExpectedNotificationEvent = switch (try generated.ext_idle_notification_v1_types.decodeEvent(
            peer,
            notification,
            &message,
        )) {
            .idled => .idled,
            .resumed => .resumed,
        };
        if (event_index >= expected.len) return error.TooManyIdleEvents;
        try std.testing.expectEqual(expected[event_index], actual);
        event_index += 1;
    }
    try std.testing.expectEqual(expected.len, event_index);
}

fn expectIdleEvents(
    peer: *wayring.Connection,
    client: *Server.Client,
    ordinary: wayring.ObjectHandle,
    input: wayring.ObjectHandle,
    expected: []const ExpectedIdleEvent,
) !void {
    const core = @import("wayring-core");
    try transferFromServer(peer, client);
    var event_index: usize = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const actual: ExpectedIdleEvent = if (message.object_id == ordinary.id)
            switch (try generated.ext_idle_notification_v1_types.decodeEvent(
                peer,
                ordinary,
                &message,
            )) {
                .idled => .ordinary_idled,
                .resumed => .ordinary_resumed,
            }
        else if (message.object_id == input.id)
            switch (try generated.ext_idle_notification_v1_types.decodeEvent(
                peer,
                input,
                &message,
            )) {
                .idled => .input_idled,
                .resumed => .input_resumed,
            }
        else if (message.object_id == 1) {
            _ = try core.decodeDisplayEvent(&message);
            continue;
        } else return error.UnexpectedIdleEvent;
        if (event_index >= expected.len) return error.TooManyIdleEvents;
        try std.testing.expectEqual(expected[event_index], actual);
        event_index += 1;
    }
    try std.testing.expectEqual(expected.len, event_index);
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
