//! Scanner-backed ext-idle-notify-v1 resource adapter.

const WayringIdleNotification = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayring = @import("wayring");
const IdleNotification = @import("../IdleNotification.zig");
const WayringClients = @import("WayringClients.zig");
const WayringSeatAdapter = @import("WayringSeatAdapter.zig");

pub const Failure = struct {
    context: *anyopaque,
    failed: *const fn (*anyopaque) void,
};

const Manager = struct {
    owner: *WayringIdleNotification,
    client: *wayring.server.Client,
    resource: protocol.ext_idle_notifier_v1.Resource,
    generation: u64,
};

const Notification = struct {
    owner: *WayringIdleNotification,
    client: *wayring.server.Client,
    resource: protocol.ext_idle_notification_v1.Resource,
    generation: u64,
    core_id: ?IdleNotification.Id = null,
};

allocator: std.mem.Allocator,
protocol_server: *wayring.server.Server,
clients: *WayringClients,
seat: *WayringSeatAdapter,
seat_ref: IdleNotification.SeatRef,
core: *IdleNotification,
failure: Failure,
global: ?*const wayring.server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
notifications: std.ArrayList(*Notification) = .empty,
next_generation: u64 = 1,

pub fn init(self: *WayringIdleNotification, allocator: std.mem.Allocator, protocol_server: *wayring.server.Server, clients: *WayringClients, seat: *WayringSeatAdapter, seat_ref: IdleNotification.SeatRef, core: *IdleNotification, failure: Failure) void {
    self.* = .{ .allocator = allocator, .protocol_server = protocol_server, .clients = clients, .seat = seat, .seat_ref = seat_ref, .core = core, .failure = failure };
}

pub fn deinit(self: *WayringIdleNotification) void {
    std.debug.assert(self.global == null and self.managers.items.len == 0 and self.notifications.items.len == 0);
    self.notifications.deinit(self.allocator);
    self.managers.deinit(self.allocator);
    self.* = undefined;
}

pub fn publish(self: *WayringIdleNotification) !void {
    std.debug.assert(self.global == null);
    self.global = try self.protocol_server.addGlobal(protocol.ext_idle_notifier_v1, 2, WayringIdleNotification, self, bindManager);
}

pub fn unpublish(self: *WayringIdleNotification) void {
    self.protocol_server.removeGlobal(self.global orelse unreachable) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}

fn generation(self: *WayringIdleNotification) !u64 {
    const result = self.next_generation;
    self.next_generation +%= 1;
    if (result == 0 or self.next_generation == 0) return error.GenerationExhausted;
    return result;
}

fn bindManager(client: *wayring.server.Client, id: u32, version: u32, self: *WayringIdleNotification) !void {
    if (version == 0 or version > 2) return error.InvalidVersion;
    try self.managers.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Manager);
    errdefer self.allocator.destroy(value);
    value.* = .{ .owner = self, .client = client, .resource = .init(self.allocator, id, version, .client, client.ownerHooks()), .generation = try self.generation() };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Manager, value, managerRequest, null);
    try client.materialize(&value.resource.runtime);
    self.managers.appendAssumeCapacity(value);
}

fn managerRequest(_: *protocol.ext_idle_notifier_v1.Resource, request: protocol.ext_idle_notifier_v1.Request, value: *Manager) !void {
    switch (request) {
        .destroy => value.owner.destroyManager(value),
        .get_idle_notification => |args| try value.owner.createNotification(value, args.id, args.timeout, args.seat, true),
        .get_input_idle_notification => |args| try value.owner.createNotification(value, args.id, args.timeout, args.seat, false),
    }
}

fn createNotification(self: *WayringIdleNotification, manager: *Manager, id: u32, timeout_ms: u32, seat_object: u32, obey_inhibitors: bool) !void {
    const client_id = self.seat.seatClientIdentity(manager.client, seat_object) orelse {
        manager.client.postImplementationError(&manager.resource.runtime, "idle notification requires the exact live same-client wl_seat");
        return;
    };
    if (self.clients.id(manager.client)) |registered| {
        if (!std.meta.eql(registered, client_id)) {
            manager.client.postImplementationError(&manager.resource.runtime, "idle notification seat has a stale client identity");
            return;
        }
    } else {
        manager.client.postImplementationError(&manager.resource.runtime, "idle notification client is stale");
        return;
    }

    try self.notifications.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Notification);
    errdefer self.allocator.destroy(value);
    value.* = .{ .owner = self, .client = manager.client, .resource = .init(self.allocator, id, manager.resource.version(), .client, manager.client.ownerHooks()), .generation = try self.generation() };
    var materialized = false;
    errdefer {
        if (!materialized) {
            value.resource.destroy();
            value.resource.deinit();
        }
    }
    try value.resource.setHandler(Notification, value, notificationRequest, null);
    try manager.client.materialize(&value.resource.runtime);
    materialized = true;
    errdefer self.destroyNotification(value);
    value.core_id = self.core.create(client_id, self.seat_ref, timeout_ms, obey_inhibitors, endpoint(value)) catch |err| switch (err) {
        error.ScheduleFailed, error.TimerGenerationExhausted => {
            // Keep the already materialized child valid until orderly server
            // teardown. Transport failure is compositor-fatal, not a client
            // protocol or implementation error.
            self.notifications.appendAssumeCapacity(value);
            self.failure.failed(self.failure.context);
            return;
        },
        else => return err,
    };
    self.notifications.appendAssumeCapacity(value);
}

fn notificationRequest(_: *protocol.ext_idle_notification_v1.Resource, request: protocol.ext_idle_notification_v1.Request, value: *Notification) !void {
    switch (request) {
        .destroy => value.owner.destroyNotification(value),
    }
}

pub fn destroyClientResources(self: *WayringIdleNotification, client: *wayring.server.Client) void {
    var index = self.notifications.items.len;
    while (index > 0) : (index -= 1) if (self.notifications.items[index - 1].client == client) self.destroyNotification(self.notifications.items[index - 1]);
    index = self.managers.items.len;
    while (index > 0) : (index -= 1) if (self.managers.items[index - 1].client == client) self.destroyManager(self.managers.items[index - 1]);
}

fn destroyNotification(self: *WayringIdleNotification, value: *Notification) void {
    if (value.core_id) |id| {
        value.core_id = null;
        self.core.destroy(id);
    }
    for (self.notifications.items, 0..) |candidate, index| if (candidate == value) {
        _ = self.notifications.swapRemove(index);
        break;
    };
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}

fn destroyManager(self: *WayringIdleNotification, value: *Manager) void {
    for (self.managers.items, 0..) |candidate, index| if (candidate == value) {
        _ = self.managers.swapRemove(index);
        break;
    };
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}

fn endpoint(value: *Notification) IdleNotification.Endpoint {
    return .{ .context = value, .idled = sendIdled, .resumed = sendResumed, .close = closeNotification };
}

fn sendIdled(context: *anyopaque) void {
    const value: *Notification = @ptrCast(@alignCast(context));
    protocol.ext_idle_notification_v1.@"send:idled"(&value.resource) catch |err| value.owner.eventFailure(value, err);
}

fn sendResumed(context: *anyopaque) void {
    const value: *Notification = @ptrCast(@alignCast(context));
    protocol.ext_idle_notification_v1.@"send:resumed"(&value.resource) catch |err| value.owner.eventFailure(value, err);
}

fn closeNotification(context: *anyopaque) void {
    const value: *Notification = @ptrCast(@alignCast(context));
    value.core_id = null;
    value.owner.destroyNotification(value);
}

fn eventFailure(self: *WayringIdleNotification, value: *Notification, err: anyerror) void {
    _ = self;
    const client = value.client;
    if (client.fatal() == null) switch (err) {
        error.OutOfMemory, error.WriteFailed => client.postOutOfMemory(&value.resource.runtime, "queueing idle notification event"),
        error.OutputSealed, error.ClientFatal => {},
        else => client.postImplementationError(&value.resource.runtime, "queueing idle notification event"),
    };
}

test "ext-idle-notify descriptors are v2 and exact" {
    const manager = protocol.ext_idle_notifier_v1;
    const notification = protocol.ext_idle_notification_v1;
    try std.testing.expectEqualStrings("ext_idle_notifier_v1", manager.interface.name);
    try std.testing.expectEqual(@as(u32, 2), manager.interface.version);
    try std.testing.expectEqual(@as(usize, 3), manager.request_messages.len);
    try std.testing.expectEqualStrings("destroy", manager.request_messages[0].name);
    try std.testing.expect(manager.request_messages[0].destructor);
    try std.testing.expectEqualStrings("get_idle_notification", manager.request_messages[1].name);
    try std.testing.expectEqual(@as(u32, 1), manager.request_messages[1].since);
    try std.testing.expectEqualStrings("get_input_idle_notification", manager.request_messages[2].name);
    try std.testing.expectEqual(@as(u32, 2), manager.request_messages[2].since);
    try std.testing.expectEqual(@as(usize, 0), manager.event_messages.len);

    for (manager.request_messages[1..]) |request| {
        try std.testing.expectEqual(@as(usize, 3), request.arguments.len);
        try std.testing.expect(request.arguments[0].kind == .new_id);
        try std.testing.expect(request.arguments[1].kind == .uint);
        const seat = request.arguments[2].kind.object;
        try std.testing.expectEqualStrings("wl_seat", seat.interface.?.name);
        try std.testing.expectEqual(.required, seat.nullability);
    }

    try std.testing.expectEqualStrings("ext_idle_notification_v1", notification.interface.name);
    try std.testing.expectEqual(@as(u32, 2), notification.interface.version);
    try std.testing.expectEqual(@as(usize, 1), notification.request_messages.len);
    try std.testing.expect(notification.request_messages[0].destructor);
    try std.testing.expectEqual(@as(usize, 2), notification.event_messages.len);
    try std.testing.expectEqualStrings("idled", notification.event_messages[0].name);
    try std.testing.expectEqualStrings("resumed", notification.event_messages[1].name);
    try std.testing.expectEqual(@as(u32, 1), notification.event_messages[0].since);
    try std.testing.expectEqual(@as(u32, 1), notification.event_messages[1].since);
}
