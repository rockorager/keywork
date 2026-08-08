//! Protocol-resource-free seat-scoped idle notification semantics.
//!
//! The compositor supplies the monotonic clock and timer transport. This
//! owner stores only canonical client/seat references, deadlines, semantic
//! state, and protocol-neutral endpoints.

const IdleNotification = @This();

const std = @import("std");
const slot_map = @import("slot_map.zig");
const ClientRegistry = @import("ClientRegistry.zig");

pub const Timestamp = i96;
pub const SeatRef = struct {
    canonical: *const anyopaque,

    pub fn fromPointer(pointer: anytype) SeatRef {
        return .{ .canonical = @ptrCast(pointer) };
    }
};
pub const State = enum { active, idle };
pub const TimerGeneration = u64;
pub const TimerDelay = ?Timestamp;

const Store = slot_map.SlotMap(Notification, enum { idle_notification });
pub const Id = Store.Id;

pub const Clock = struct {
    context: *anyopaque,
    now: *const fn (*anyopaque) Timestamp,
};

pub const Scheduler = struct {
    context: *anyopaque,
    /// A null delay disarms the transport. Positive delays may be rounded up
    /// by the adapter; callbacks must return the supplied generation.
    arm: *const fn (*anyopaque, TimerDelay, TimerGeneration) error{ScheduleFailed}!void,
};

pub const Endpoint = struct {
    context: *anyopaque,
    idled: *const fn (*anyopaque) void,
    resumed: *const fn (*anyopaque) void,
    close: *const fn (*anyopaque) void,
};

pub const Snapshot = struct {
    client: ClientRegistry.Id,
    seat: SeatRef,
    timeout_ms: u32,
    deadline: Timestamp,
    obey_inhibitors: bool,
    state: State,
};

pub const CreateError = error{ OutOfMemory, InvalidClient, ScheduleFailed, TimerGenerationExhausted };
pub const UpdateError = error{ ScheduleFailed, TimerGenerationExhausted };

const Notification = struct {
    client: ClientRegistry.Id,
    seat: SeatRef,
    timeout_ms: u32,
    deadline: Timestamp,
    obey_inhibitors: bool,
    state: State = .active,
    endpoint: Endpoint,
};

const Proposal = union(enum) {
    current,
    activity: struct { seat: SeatRef, timestamp: Timestamp },
    inhibition: bool,
};

allocator: std.mem.Allocator,
clients: *const ClientRegistry,
clock: Clock,
scheduler: Scheduler,
notifications: Store = .{},
inhibited: bool = false,
next_timer_generation: TimerGeneration = 1,
armed_generation: ?TimerGeneration = null,

pub fn init(
    allocator: std.mem.Allocator,
    clients: *const ClientRegistry,
    clock: Clock,
    scheduler: Scheduler,
) IdleNotification {
    return .{
        .allocator = allocator,
        .clients = clients,
        .clock = clock,
        .scheduler = scheduler,
    };
}

pub fn deinit(self: *IdleNotification) void {
    std.debug.assert(self.notifications.len() == 0);
    self.notifications.deinit(self.allocator);
    self.* = undefined;
}

pub fn create(
    self: *IdleNotification,
    client: ClientRegistry.Id,
    seat: SeatRef,
    timeout_ms: u32,
    obey_inhibitors: bool,
    endpoint: Endpoint,
) CreateError!Id {
    if (!self.clients.contains(client)) return error.InvalidClient;
    const timestamp = self.clock.now(self.clock.context);
    const id = try self.notifications.insert(self.allocator, .{
        .client = client,
        .seat = seat,
        .timeout_ms = timeout_ms,
        .deadline = deadline(timestamp, timeout_ms),
        .obey_inhibitors = obey_inhibitors,
        .endpoint = endpoint,
    });
    errdefer _ = self.notifications.remove(id);
    try self.armFor(timestamp, .current);
    self.applyProposal(timestamp, .current);
    return id;
}

/// Teardown is allocation- and scheduling-free. An already armed early timer
/// is harmless: its generation remains valid and re-evaluates remaining work.
pub fn destroy(self: *IdleNotification, id: Id) void {
    _ = self.notifications.remove(id);
}

pub fn snapshot(self: *const IdleNotification, id: Id) ?Snapshot {
    const notification = self.notifications.getConst(id) orelse return null;
    return snapshotOf(notification);
}

pub fn len(self: *const IdleNotification) usize {
    return self.notifications.len();
}

pub fn observeActivity(self: *IdleNotification, seat: SeatRef) UpdateError!void {
    const timestamp = self.clock.now(self.clock.context);
    const proposal: Proposal = .{ .activity = .{ .seat = seat, .timestamp = timestamp } };
    try self.armFor(timestamp, proposal);
    self.applyProposal(timestamp, proposal);
}

pub fn setInhibited(self: *IdleNotification, inhibited: bool) UpdateError!void {
    if (self.inhibited == inhibited) return;
    const timestamp = self.clock.now(self.clock.context);
    const proposal: Proposal = .{ .inhibition = inhibited };
    try self.armFor(timestamp, proposal);
    self.applyProposal(timestamp, proposal);
}

/// Invalidates any callback issued by the previous transport and recreates
/// the one canonical alarm on the scheduler's current route.
pub fn rearm(self: *IdleNotification) UpdateError!void {
    const timestamp = self.clock.now(self.clock.context);
    try self.armFor(timestamp, .current);
    self.applyProposal(timestamp, .current);
}

/// Returns false for stale callbacks without touching state or the scheduler.
pub fn timerFired(self: *IdleNotification, generation: TimerGeneration) UpdateError!bool {
    if (self.armed_generation == null or self.armed_generation.? != generation) return false;
    const timestamp = self.clock.now(self.clock.context);
    try self.armFor(timestamp, .current);
    self.applyProposal(timestamp, .current);
    return true;
}

/// Client retirement does not call endpoints: frontend resources are already
/// being destroyed and their contexts may no longer be live.
pub fn clientDisconnected(self: *IdleNotification, client: ClientRegistry.Id) void {
    self.removeMatching(.client, client, false);
}

/// Canonical seat retirement removes state before asking live endpoints to
/// close, so synchronous resource destruction observes a stale neutral ID.
pub fn seatDestroyed(self: *IdleNotification, seat: SeatRef) void {
    self.removeMatching(.seat, seat, true);
}

fn removeMatching(
    self: *IdleNotification,
    comptime field: enum { client, seat },
    value: anytype,
    close: bool,
) void {
    while (true) {
        var found: ?Id = null;
        var iterator = self.notifications.iterator();
        while (iterator.next()) |entry| {
            if (std.meta.eql(@field(entry.value, @tagName(field)), value)) {
                found = entry.id;
                break;
            }
        }
        const removed = self.notifications.remove(found orelse return).?;
        if (close) removed.endpoint.close(removed.endpoint.context);
    }
}

fn armFor(self: *IdleNotification, timestamp: Timestamp, proposal: Proposal) UpdateError!void {
    const generation = self.next_timer_generation;
    if (generation == 0) return error.TimerGenerationExhausted;

    var earliest: ?Timestamp = null;
    var iterator = self.notifications.iterator();
    while (iterator.next()) |entry| {
        const effective = effectiveState(entry.value, proposal, self.inhibited);
        if (effective.state == .idle or
            (effective.inhibited and entry.value.obey_inhibitors) or
            effective.deadline <= timestamp)
        {
            continue;
        }
        earliest = if (earliest) |current| @min(current, effective.deadline) else effective.deadline;
    }
    const delay = if (earliest) |target| target - timestamp else null;
    try self.scheduler.arm(self.scheduler.context, delay, generation);
    self.armed_generation = generation;
    self.next_timer_generation +%= 1;
}

fn applyProposal(self: *IdleNotification, timestamp: Timestamp, proposal: Proposal) void {
    switch (proposal) {
        .current => {},
        .activity => |activity| {
            var iterator = self.notifications.iterator();
            while (iterator.next()) |entry| {
                if (!std.meta.eql(entry.value.seat, activity.seat)) continue;
                entry.value.deadline = deadline(activity.timestamp, entry.value.timeout_ms);
                setState(entry.value, .active);
            }
        },
        .inhibition => |inhibited| {
            self.inhibited = inhibited;
            var iterator = self.notifications.iterator();
            while (iterator.next()) |entry| {
                if (entry.value.obey_inhibitors) setState(entry.value, .active);
            }
        },
    }

    var iterator = self.notifications.iterator();
    while (iterator.next()) |entry| {
        if (entry.value.state == .idle or
            (self.inhibited and entry.value.obey_inhibitors) or
            entry.value.deadline > timestamp)
        {
            continue;
        }
        setState(entry.value, .idle);
    }
}

fn effectiveState(
    notification: *const Notification,
    proposal: Proposal,
    current_inhibited: bool,
) struct { state: State, deadline: Timestamp, inhibited: bool } {
    var state = notification.state;
    var notification_deadline = notification.deadline;
    var inhibited = current_inhibited;
    switch (proposal) {
        .current => {},
        .activity => |activity| if (std.meta.eql(notification.seat, activity.seat)) {
            state = .active;
            notification_deadline = deadline(activity.timestamp, notification.timeout_ms);
        },
        .inhibition => |value| {
            inhibited = value;
            if (notification.obey_inhibitors) state = .active;
        },
    }
    return .{ .state = state, .deadline = notification_deadline, .inhibited = inhibited };
}

fn setState(notification: *Notification, state: State) void {
    if (notification.state == state) return;
    notification.state = state;
    switch (state) {
        .active => notification.endpoint.resumed(notification.endpoint.context),
        .idle => notification.endpoint.idled(notification.endpoint.context),
    }
}

fn snapshotOf(notification: *const Notification) Snapshot {
    return .{
        .client = notification.client,
        .seat = notification.seat,
        .timeout_ms = notification.timeout_ms,
        .deadline = notification.deadline,
        .obey_inhibitors = notification.obey_inhibitors,
        .state = notification.state,
    };
}

fn deadline(timestamp: Timestamp, timeout_ms: u32) Timestamp {
    const timeout_ns: Timestamp = @as(Timestamp, timeout_ms) * std.time.ns_per_ms;
    return std.math.add(Timestamp, timestamp, timeout_ns) catch std.math.maxInt(Timestamp);
}

const TestClock = struct {
    now_value: Timestamp = 0,

    fn now(context: *anyopaque) Timestamp {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.now_value;
    }

    fn clock(self: *@This()) Clock {
        return .{ .context = self, .now = now };
    }
};

const TestScheduler = struct {
    delay: TimerDelay = null,
    generation: TimerGeneration = 0,
    calls: usize = 0,
    fail_next: bool = false,

    fn arm(context: *anyopaque, delay: TimerDelay, generation: TimerGeneration) error{ScheduleFailed}!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (self.fail_next) {
            self.fail_next = false;
            return error.ScheduleFailed;
        }
        self.delay = delay;
        self.generation = generation;
    }

    fn scheduler(self: *@This()) Scheduler {
        return .{ .context = self, .arm = arm };
    }
};

const TestEndpoint = struct {
    events: std.ArrayList(u8) = .empty,
    close_count: usize = 0,

    fn deinit(self: *@This()) void {
        self.events.deinit(std.testing.allocator);
    }

    fn idled(context: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.events.append(std.testing.allocator, 'i') catch unreachable;
    }

    fn resumed(context: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.events.append(std.testing.allocator, 'r') catch unreachable;
    }

    fn close(context: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.close_count += 1;
    }

    fn endpoint(self: *@This()) Endpoint {
        return .{ .context = self, .idled = idled, .resumed = resumed, .close = close };
    }
};

test "timeout boundaries activity and inhibition preserve mature chronology" {
    var clients = ClientRegistry.init(std.testing.allocator);
    defer clients.deinit();
    const client = try clients.register(.mature_display);
    defer clients.unregister(client);
    var clock: TestClock = .{};
    var scheduler: TestScheduler = .{};
    var notifications = IdleNotification.init(std.testing.allocator, &clients, clock.clock(), scheduler.scheduler());
    defer notifications.deinit();
    var seat_token: u8 = 0;
    const seat = SeatRef.fromPointer(&seat_token);
    var normal: TestEndpoint = .{};
    defer normal.deinit();
    var input_only: TestEndpoint = .{};
    defer input_only.deinit();
    const normal_id = try notifications.create(client, seat, 10, true, normal.endpoint());
    defer notifications.destroy(normal_id);
    const input_id = try notifications.create(client, seat, 20, false, input_only.endpoint());
    defer notifications.destroy(input_id);
    try std.testing.expectEqual(@as(TimerDelay, 10 * std.time.ns_per_ms), scheduler.delay);

    clock.now_value = 10 * std.time.ns_per_ms - 1;
    try std.testing.expect(try notifications.timerFired(scheduler.generation));
    try std.testing.expectEqualStrings("", normal.events.items);
    try std.testing.expectEqual(@as(TimerDelay, 1), scheduler.delay);
    clock.now_value += 1;
    try std.testing.expect(try notifications.timerFired(scheduler.generation));
    try std.testing.expectEqualStrings("i", normal.events.items);
    try std.testing.expectEqual(State.idle, notifications.snapshot(normal_id).?.state);

    try notifications.observeActivity(seat);
    try std.testing.expectEqualStrings("ir", normal.events.items);
    clock.now_value += 10 * std.time.ns_per_ms;
    try std.testing.expect(try notifications.timerFired(scheduler.generation));
    try std.testing.expectEqualStrings("iri", normal.events.items);
    try std.testing.expectEqualStrings("", input_only.events.items);

    try notifications.setInhibited(true);
    try std.testing.expectEqualStrings("irir", normal.events.items);
    try std.testing.expectEqualStrings("", input_only.events.items);
    clock.now_value += 100 * std.time.ns_per_ms;
    try notifications.setInhibited(false);
    try std.testing.expectEqualStrings("iriri", normal.events.items);
}

test "zero maximum overflow multiple seats and stale timer generations are deterministic" {
    var clients = ClientRegistry.init(std.testing.allocator);
    defer clients.deinit();
    const first_client = try clients.register(.mature_display);
    defer clients.unregister(first_client);
    const second_client = try clients.register(.wayring_server);
    defer clients.unregister(second_client);
    var clock: TestClock = .{};
    var scheduler: TestScheduler = .{};
    var notifications = IdleNotification.init(std.testing.allocator, &clients, clock.clock(), scheduler.scheduler());
    defer notifications.deinit();
    var first_seat_token: u8 = 0;
    var second_seat_token: u8 = 0;
    const first_seat = SeatRef.fromPointer(&first_seat_token);
    const second_seat = SeatRef.fromPointer(&second_seat_token);
    var zero: TestEndpoint = .{};
    defer zero.deinit();
    var maximum: TestEndpoint = .{};
    defer maximum.deinit();
    var other: TestEndpoint = .{};
    defer other.deinit();
    const zero_id = try notifications.create(first_client, first_seat, 0, true, zero.endpoint());
    defer notifications.destroy(zero_id);
    try std.testing.expectEqualStrings("i", zero.events.items);
    const stale_generation = scheduler.generation;
    const maximum_id = try notifications.create(first_client, first_seat, std.math.maxInt(u32), true, maximum.endpoint());
    defer notifications.destroy(maximum_id);
    const other_id = try notifications.create(second_client, second_seat, 1, false, other.endpoint());
    defer notifications.destroy(other_id);
    try std.testing.expect(!(try notifications.timerFired(stale_generation)));
    try std.testing.expectEqualStrings("", other.events.items);

    clock.now_value = std.math.maxInt(Timestamp) - 1;
    try notifications.observeActivity(first_seat);
    try std.testing.expectEqual(std.math.maxInt(Timestamp), notifications.snapshot(maximum_id).?.deadline);
    try std.testing.expectEqualStrings("iri", zero.events.items);
    try std.testing.expectEqualStrings("", maximum.events.items);
    try std.testing.expectEqualStrings("i", other.events.items);
}

test "creation scheduling failure OOM and teardown never publish dead endpoints" {
    var clients = ClientRegistry.init(std.testing.allocator);
    defer clients.deinit();
    const client = try clients.register(.mature_display);
    var clock: TestClock = .{};
    var scheduler: TestScheduler = .{ .fail_next = true };
    var notifications = IdleNotification.init(std.testing.allocator, &clients, clock.clock(), scheduler.scheduler());
    defer notifications.deinit();
    var seat_token: u8 = 0;
    const seat = SeatRef.fromPointer(&seat_token);
    var endpoint: TestEndpoint = .{};
    defer endpoint.deinit();
    try std.testing.expectError(error.ScheduleFailed, notifications.create(client, seat, 1, true, endpoint.endpoint()));
    try std.testing.expectEqual(@as(usize, 0), notifications.len());
    try std.testing.expectEqualStrings("", endpoint.events.items);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var oom_notifications = IdleNotification.init(failing.allocator(), &clients, clock.clock(), scheduler.scheduler());
    try std.testing.expectError(error.OutOfMemory, oom_notifications.create(client, seat, 1, true, endpoint.endpoint()));
    oom_notifications.deinit();

    const first = try notifications.create(client, seat, 1, true, endpoint.endpoint());
    notifications.destroy(first);
    const replacement = try notifications.create(client, seat, 1, true, endpoint.endpoint());
    try std.testing.expectEqual(first.index, replacement.index);
    try std.testing.expect(first.generation != replacement.generation);
    notifications.destroy(first);
    try std.testing.expect(notifications.snapshot(replacement) != null);
    notifications.seatDestroyed(seat);
    try std.testing.expectEqual(@as(usize, 1), endpoint.close_count);
    try std.testing.expectEqual(@as(usize, 0), notifications.len());

    clients.unregister(client);
    notifications.clientDisconnected(client);
    try std.testing.expectEqual(@as(usize, 1), endpoint.close_count);
}

test "failed updates preserve deadlines state and published timer generation" {
    var clients = ClientRegistry.init(std.testing.allocator);
    defer clients.deinit();
    const client = try clients.register(.mature_display);
    defer clients.unregister(client);
    var clock: TestClock = .{};
    var scheduler: TestScheduler = .{};
    var notifications = IdleNotification.init(std.testing.allocator, &clients, clock.clock(), scheduler.scheduler());
    defer notifications.deinit();
    var seat_token: u8 = 0;
    const seat = SeatRef.fromPointer(&seat_token);
    var endpoint: TestEndpoint = .{};
    defer endpoint.deinit();
    const id = try notifications.create(client, seat, 10, true, endpoint.endpoint());
    defer notifications.destroy(id);
    const initial = notifications.snapshot(id).?;
    const generation = scheduler.generation;

    clock.now_value = 5 * std.time.ns_per_ms;
    scheduler.fail_next = true;
    try std.testing.expectError(error.ScheduleFailed, notifications.observeActivity(seat));
    try std.testing.expectEqual(initial.deadline, notifications.snapshot(id).?.deadline);
    try std.testing.expectEqual(initial.state, notifications.snapshot(id).?.state);
    try std.testing.expectEqual(generation, notifications.armed_generation.?);
    try std.testing.expectEqualStrings("", endpoint.events.items);

    scheduler.fail_next = true;
    try std.testing.expectError(error.ScheduleFailed, notifications.setInhibited(true));
    try std.testing.expect(!notifications.inhibited);
    try std.testing.expectEqual(generation, notifications.armed_generation.?);
}

test "creation uses current clock and client retirement silently removes every observer" {
    var clients = ClientRegistry.init(std.testing.allocator);
    defer clients.deinit();
    const client = try clients.register(.mature_display);
    var clock: TestClock = .{ .now_value = 100 * std.time.ns_per_ms };
    var scheduler: TestScheduler = .{};
    var notifications = IdleNotification.init(std.testing.allocator, &clients, clock.clock(), scheduler.scheduler());
    defer notifications.deinit();
    var seat_token: u8 = 0;
    const seat = SeatRef.fromPointer(&seat_token);
    var first: TestEndpoint = .{};
    defer first.deinit();
    var second: TestEndpoint = .{};
    defer second.deinit();
    const first_id = try notifications.create(client, seat, 7, true, first.endpoint());
    _ = try notifications.create(client, seat, 9, false, second.endpoint());
    try std.testing.expectEqual(
        @as(Timestamp, 107 * std.time.ns_per_ms),
        notifications.snapshot(first_id).?.deadline,
    );
    try std.testing.expectEqual(State.active, notifications.snapshot(first_id).?.state);
    try std.testing.expectEqualStrings("", first.events.items);

    notifications.clientDisconnected(client);
    try std.testing.expectEqual(@as(usize, 0), notifications.len());
    try std.testing.expectEqual(@as(usize, 0), first.close_count);
    try std.testing.expectEqual(@as(usize, 0), second.close_count);
    clients.unregister(client);
}

test "timer generation exhaustion rejects publication without wrapping stale tokens" {
    var clients = ClientRegistry.init(std.testing.allocator);
    defer clients.deinit();
    const client = try clients.register(.mature_display);
    defer clients.unregister(client);
    var clock: TestClock = .{};
    var scheduler: TestScheduler = .{};
    var notifications = IdleNotification.init(std.testing.allocator, &clients, clock.clock(), scheduler.scheduler());
    defer notifications.deinit();
    notifications.next_timer_generation = 0;
    var seat_token: u8 = 0;
    var endpoint: TestEndpoint = .{};
    defer endpoint.deinit();
    try std.testing.expectError(error.TimerGenerationExhausted, notifications.create(
        client,
        SeatRef.fromPointer(&seat_token),
        0,
        true,
        endpoint.endpoint(),
    ));
    try std.testing.expectEqual(@as(usize, 0), notifications.len());
    try std.testing.expectEqualStrings("", endpoint.events.items);
}
