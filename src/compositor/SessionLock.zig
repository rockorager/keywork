//! Protocol-resource-free session-lock and per-output surface state.
//!
//! This owner arbitrates unlock authority and records presented output coverage.
//! It intentionally owns no focus, rendering, placement, or security policy.

const SessionLock = @This();

const std = @import("std");
const slot_map = @import("slot_map.zig");
const ClientRegistry = @import("ClientRegistry.zig");
const SurfaceRegistry = @import("SurfaceRegistry.zig");
const OutputLayout = @import("output_layout.zig");

const LockStore = slot_map.SlotMap(Lock, enum { session_lock });
const SurfaceStore = slot_map.SlotMap(LockSurface, enum { session_lock_surface });
pub const LockId = LockStore.Id;
pub const LockSurfaceId = SurfaceStore.Id;
pub const ConfigureToken = struct { surface: LockSurfaceId, sequence: u64 };

pub const LockEndpoint = struct {
    context: *anyopaque,
    acquired: *const fn (*anyopaque) void,
    finished: *const fn (*anyopaque) void,
};
pub const SurfaceEndpoint = struct {
    context: *anyopaque,
    configure: *const fn (*anyopaque, u32, u32, ConfigureToken) error{OutOfMemory}!void,
};
pub const Observer = struct {
    context: *anyopaque,
    state_changed: *const fn (*anyopaque, bool) void,
    output_secure_without_frame: *const fn (*anyopaque, OutputLayout.Id) bool,
    repaint: *const fn (*anyopaque) void,
};
pub const SurfaceSnapshot = struct {
    lock: LockId,
    client: ClientRegistry.Id,
    surface: SurfaceRegistry.Id,
    output: OutputLayout.Id,
    configured_size: ?[2]u32,
    mapped: bool,
};

const Outcome = enum { pending, acquired, finished };
const Lock = struct {
    client: ClientRegistry.Id,
    endpoint: LockEndpoint,
    outcome: Outcome,
    was_locked: bool,
    endpoint_live: bool = true,
};
const Configuration = struct { token: ConfigureToken, size: [2]u32 };
const LockSurface = struct {
    lock: LockId,
    client: ClientRegistry.Id,
    surface: SurfaceRegistry.Id,
    output: OutputLayout.Id,
    endpoint: SurfaceEndpoint,
    configurations: std.ArrayList(Configuration) = .empty,
    next_sequence: u64 = 1,
    acked_size: ?[2]u32 = null,
    configured_size: ?[2]u32 = null,
    mapped: bool = false,
};

allocator: std.mem.Allocator,
clients: *const ClientRegistry,
surfaces_registry: *const SurfaceRegistry,
observer: Observer,
locks: LockStore = .{},
surfaces: SurfaceStore = .{},
outputs: std.AutoHashMapUnmanaged(OutputLayout.Id, void) = .empty,
secured_outputs: std.AutoHashMapUnmanaged(OutputLayout.Id, void) = .empty,
active: ?LockId = null,
locked: bool = false,

pub fn init(allocator: std.mem.Allocator, clients: *const ClientRegistry, surfaces: *const SurfaceRegistry, observer: Observer) SessionLock {
    return .{ .allocator = allocator, .clients = clients, .surfaces_registry = surfaces, .observer = observer };
}

pub fn deinit(self: *SessionLock) void {
    std.debug.assert(self.locks.len() == 0 and self.surfaces.len() == 0);
    self.locks.deinit(self.allocator);
    self.surfaces.deinit(self.allocator);
    self.outputs.deinit(self.allocator);
    self.secured_outputs.deinit(self.allocator);
    self.* = undefined;
}

pub fn isLocked(self: *const SessionLock) bool {
    return self.locked;
}
pub fn activeLock(self: *const SessionLock) ?LockId {
    return self.active;
}

/// Endpoint callbacks happen only after the fallible insertion has completed.
pub fn createLock(self: *SessionLock, client: ClientRegistry.Id, endpoint: LockEndpoint) error{ OutOfMemory, InvalidClient }!LockId {
    if (!self.clients.contains(client)) return error.InvalidClient;
    const id = try self.locks.insert(self.allocator, .{ .client = client, .endpoint = endpoint, .outcome = if (self.active == null) .pending else .finished, .was_locked = self.locked });
    if (self.active != null) {
        endpoint.finished(endpoint.context);
        return id;
    }
    self.active = id;
    self.secured_outputs.clearRetainingCapacity();
    if (!self.locked) {
        self.locked = true;
        self.observer.state_changed(self.observer.context, true);
    }
    self.observer.repaint(self.observer.context);
    self.finishIfSecure();
    return id;
}

pub fn destroyLock(self: *SessionLock, id: LockId) void {
    const lock = self.locks.get(id) orelse return;
    if (!lock.endpoint_live) return;
    lock.endpoint_live = false;
    const was_active = self.active != null and std.meta.eql(self.active.?, id);
    const abandon_unlocks = was_active and lock.outcome == .pending and !lock.was_locked;
    if (was_active) {
        self.active = null;
        self.secured_outputs.clearRetainingCapacity();
        if (abandon_unlocks) {
            self.locked = false;
            self.observer.state_changed(self.observer.context, false);
        }
        self.observer.repaint(self.observer.context);
    }
    self.removeLockIfUnused(id);
}

fn removeLockIfUnused(self: *SessionLock, id: LockId) void {
    const lock = self.locks.getConst(id) orelse return;
    if (lock.endpoint_live or self.findSurfaceByLock(id) != null) return;
    _ = self.locks.remove(id);
}

fn findSurfaceByLock(self: *SessionLock, lock: LockId) ?LockSurfaceId {
    var iterator = self.surfaces.iterator();
    while (iterator.next()) |entry| {
        if (std.meta.eql(entry.value.lock, lock)) return entry.id;
    }
    return null;
}

fn findSurfaceByOutput(self: *SessionLock, output: OutputLayout.Id) ?LockSurfaceId {
    var iterator = self.surfaces.iterator();
    while (iterator.next()) |entry| {
        if (std.meta.eql(entry.value.output, output)) return entry.id;
    }
    return null;
}

fn findLockByClient(self: *SessionLock, client: ClientRegistry.Id) ?LockId {
    var iterator = self.locks.iterator();
    while (iterator.next()) |entry| {
        if (std.meta.eql(entry.value.client, client)) return entry.id;
    }
    return null;
}

fn findSurfaceByRegistryId(self: *SessionLock, surface: SurfaceRegistry.Id) ?LockSurfaceId {
    var iterator = self.surfaces.iterator();
    while (iterator.next()) |entry| {
        if (std.meta.eql(entry.value.surface, surface)) return entry.id;
    }
    return null;
}

pub fn unlockAndDestroy(self: *SessionLock, id: LockId) error{InvalidUnlock}!void {
    const lock = self.locks.get(id) orelse return error.InvalidUnlock;
    if (lock.outcome != .acquired or self.active == null or !std.meta.eql(self.active.?, id)) return error.InvalidUnlock;
    self.active = null;
    self.locked = false;
    lock.outcome = .finished;
    self.secured_outputs.clearRetainingCapacity();
    self.observer.state_changed(self.observer.context, false);
    self.observer.repaint(self.observer.context);
}

pub fn mayDestroyLock(self: *const SessionLock, id: LockId) bool {
    const lock = self.locks.getConst(id) orelse return true;
    return lock.outcome != .acquired;
}

pub fn createSurface(self: *SessionLock, lock_id: LockId, client: ClientRegistry.Id, surface: SurfaceRegistry.Id, surface_owner: ClientRegistry.Id, output: OutputLayout.Id, endpoint: SurfaceEndpoint) error{ OutOfMemory, InvalidLock, InvalidClient, InvalidSurface, ForeignSurface, InvalidOutput, DuplicateOutput }!LockSurfaceId {
    const lock = self.locks.getConst(lock_id) orelse return error.InvalidLock;
    if (!self.clients.contains(client) or !std.meta.eql(lock.client, client)) return error.InvalidClient;
    if (!self.surfaces_registry.contains(surface)) return error.InvalidSurface;
    if (!std.meta.eql(client, surface_owner)) return error.ForeignSurface;
    if (!self.outputs.contains(output)) return error.InvalidOutput;
    var iterator = self.surfaces.iterator();
    while (iterator.next()) |entry| if (std.meta.eql(entry.value.lock, lock_id) and std.meta.eql(entry.value.output, output)) return error.DuplicateOutput;
    return self.surfaces.insert(self.allocator, .{ .lock = lock_id, .client = client, .surface = surface, .output = output, .endpoint = endpoint });
}

pub fn destroySurface(self: *SessionLock, id: LockSurfaceId) void {
    var state = self.surfaces.remove(id) orelse return;
    const lock = state.lock;
    state.configurations.deinit(self.allocator);
    self.observer.repaint(self.observer.context);
    self.removeLockIfUnused(lock);
}

pub fn configure(self: *SessionLock, id: LockSurfaceId, width: u32, height: u32) error{ OutOfMemory, InvalidSurface, SequenceExhausted }!ConfigureToken {
    const state = self.surfaces.get(id) orelse return error.InvalidSurface;
    if (state.next_sequence == 0) return error.SequenceExhausted;
    const token: ConfigureToken = .{ .surface = id, .sequence = state.next_sequence };
    try state.configurations.append(self.allocator, .{ .token = token, .size = .{ width, height } });
    errdefer _ = state.configurations.pop();
    try state.endpoint.configure(state.endpoint.context, width, height, token);
    state.next_sequence +%= 1;
    state.configured_size = .{ width, height };
    return token;
}

pub fn ackConfigure(self: *SessionLock, id: LockSurfaceId, token: ConfigureToken) error{ InvalidSurface, ForeignConfigure, StaleConfigure }!void {
    const state = self.surfaces.get(id) orelse return error.InvalidSurface;
    if (!std.meta.eql(token.surface, id)) return error.ForeignConfigure;
    for (state.configurations.items, 0..) |configuration, index| {
        if (!std.meta.eql(configuration.token, token)) continue;
        state.acked_size = configuration.size;
        state.configurations.replaceRangeAssumeCapacity(0, index + 1, &.{});
        return;
    }
    return error.StaleConfigure;
}

pub fn map(self: *SessionLock, id: LockSurfaceId, width: u32, height: u32) error{ InvalidSurface, CommitBeforeAck, DimensionsMismatch }!void {
    const state = self.surfaces.get(id) orelse return error.InvalidSurface;
    const size = state.acked_size orelse return error.CommitBeforeAck;
    if (size[0] != width or size[1] != height) {
        state.mapped = false;
        self.observer.repaint(self.observer.context);
        return error.DimensionsMismatch;
    }
    state.mapped = true;
    self.observer.repaint(self.observer.context);
}
pub fn unmap(self: *SessionLock, id: LockSurfaceId) void {
    const state = self.surfaces.get(id) orelse return;
    state.mapped = false;
    self.observer.repaint(self.observer.context);
}
pub fn validateCommit(self: *const SessionLock, id: LockSurfaceId, has_buffer: bool) error{ InvalidSurface, NullBuffer, CommitBeforeAck }!void {
    const state = self.surfaces.getConst(id) orelse return error.InvalidSurface;
    if (!has_buffer) return error.NullBuffer;
    if (state.acked_size == null) return error.CommitBeforeAck;
}
pub fn snapshot(self: *const SessionLock, id: LockSurfaceId) ?SurfaceSnapshot {
    const state = self.surfaces.getConst(id) orelse return null;
    return .{ .lock = state.lock, .client = state.client, .surface = state.surface, .output = state.output, .configured_size = state.configured_size, .mapped = state.mapped };
}

pub fn surfaceForOutput(self: *const SessionLock, output: OutputLayout.Id) ?SurfaceSnapshot {
    if (!self.locked) return null;
    if (!self.outputs.contains(output)) return null;
    const active = self.active orelse return null;
    var iterator = @constCast(&self.surfaces).iterator();
    while (iterator.next()) |entry| {
        if (std.meta.eql(entry.value.lock, active) and std.meta.eql(entry.value.output, output) and entry.value.mapped)
            return .{ .lock = entry.value.lock, .client = entry.value.client, .surface = entry.value.surface, .output = entry.value.output, .configured_size = entry.value.configured_size, .mapped = true };
    }
    return null;
}

pub fn ownsMappedSurface(self: *const SessionLock, surface: SurfaceRegistry.Id) bool {
    if (!self.locked) return false;
    const active = self.active orelse return false;
    var iterator = @constCast(&self.surfaces).iterator();
    while (iterator.next()) |entry| {
        if (entry.value.mapped and self.outputs.contains(entry.value.output) and
            std.meta.eql(entry.value.lock, active) and std.meta.eql(entry.value.surface, surface)) return true;
    }
    return false;
}

pub fn firstMappedSurface(self: *const SessionLock) ?SurfaceRegistry.Id {
    if (!self.locked) return null;
    const active = self.active orelse return null;
    var iterator = @constCast(&self.surfaces).iterator();
    while (iterator.next()) |entry| {
        if (entry.value.mapped and self.outputs.contains(entry.value.output) and
            std.meta.eql(entry.value.lock, active)) return entry.value.surface;
    }
    return null;
}

pub fn outputAdded(self: *SessionLock, output: OutputLayout.Id) error{OutOfMemory}!void {
    try self.outputs.put(self.allocator, output, {});
    self.finishIfSecure();
}
pub fn outputPresented(self: *SessionLock, output: OutputLayout.Id) error{OutOfMemory}!void {
    const active = self.active orelse return;
    const lock = self.locks.getConst(active) orelse return;
    if (!self.locked or lock.outcome != .pending) return;
    if (!self.outputs.contains(output)) return;
    try self.secured_outputs.put(self.allocator, output, {});
    self.finishIfSecure();
}
pub fn outputRemoved(self: *SessionLock, output: OutputLayout.Id) void {
    _ = self.outputs.remove(output);
    _ = self.secured_outputs.remove(output);
    self.finishIfSecure();
}
pub fn refreshSecurity(self: *SessionLock) void {
    self.finishIfSecure();
}

fn finishIfSecure(self: *SessionLock) void {
    const id = self.active orelse return;
    const lock = self.locks.get(id) orelse return;
    if (!self.locked or lock.outcome != .pending) return;
    var outputs = self.outputs.iterator();
    while (outputs.next()) |entry| if (!self.secured_outputs.contains(entry.key_ptr.*) and !self.observer.output_secure_without_frame(self.observer.context, entry.key_ptr.*)) return;
    lock.outcome = .acquired;
    lock.endpoint.acquired(lock.endpoint.context);
}

pub fn clientDisconnected(self: *SessionLock, client: ClientRegistry.Id) void {
    while (self.findLockByClient(client)) |lock_id| {
        self.destroyLock(lock_id);
        while (self.findSurfaceByLock(lock_id)) |surface_id| self.destroySurface(surface_id);
        self.removeLockIfUnused(lock_id);
    }
}
pub fn surfaceDestroyed(self: *SessionLock, surface: SurfaceRegistry.Id) void {
    while (self.findSurfaceByRegistryId(surface)) |surface_id| self.destroySurface(surface_id);
}

const TestProbe = struct {
    locked: bool = false,
    secure_output: ?OutputLayout.Id = null,
    acquired_count: usize = 0,
    finished_count: usize = 0,
    configure_count: usize = 0,
    repaint_count: usize = 0,
    configure_fails: bool = false,
    events: [64]u8 = undefined,
    events_len: usize = 0,

    fn event(self: *@This(), value: u8) void {
        self.events[self.events_len] = value;
        self.events_len += 1;
    }
    fn changed(context: *anyopaque, value: bool) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.locked = value;
        self.event(if (value) 'L' else 'U');
    }
    fn secure(context: *anyopaque, output: OutputLayout.Id) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        return if (self.secure_output) |secure_output| std.meta.eql(output, secure_output) else false;
    }
    fn paint(context: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.repaint_count += 1;
        self.event('P');
    }
    fn acquired(context: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.acquired_count += 1;
        self.event('A');
    }
    fn finished(context: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.finished_count += 1;
        self.event('F');
    }
    fn configure(context: *anyopaque, _: u32, _: u32, _: ConfigureToken) error{OutOfMemory}!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.configure_fails) return error.OutOfMemory;
        self.configure_count += 1;
        self.event('C');
    }
    fn render(_: *anyopaque) ?SurfaceRegistry.RenderState {
        return null;
    }
    fn lockEndpoint(self: *@This()) LockEndpoint {
        return .{ .context = self, .acquired = acquired, .finished = finished };
    }
    fn surfaceEndpoint(self: *@This()) SurfaceEndpoint {
        return .{ .context = self, .configure = TestProbe.configure };
    }
    fn clearEvents(self: *@This()) void {
        self.events_len = 0;
    }
};

const TestFixture = struct {
    clients: ClientRegistry,
    registry: SurfaceRegistry,
    probe: TestProbe = .{},
    owner: SessionLock,
    clients_ids: [2]ClientRegistry.Id,
    surface_ids: [2]SurfaceRegistry.Id,

    fn init(allocator: std.mem.Allocator) !@This() {
        var clients = ClientRegistry.init(std.testing.allocator);
        errdefer clients.deinit();
        var registry = SurfaceRegistry.init(std.testing.allocator);
        errdefer registry.deinit();
        const first_client = try clients.register(.mature_display);
        errdefer clients.unregister(first_client);
        const second_client = try clients.register(.wayring_server);
        errdefer clients.unregister(second_client);
        // The fixture is moved once on return; endpoint contexts are installed afterwards.
        var result: @This() = undefined;
        result.clients = clients;
        result.registry = registry;
        result.probe = .{};
        result.clients_ids = .{ first_client, second_client };
        result.surface_ids[0] = try result.registry.add(.{ .context = &result.probe, .render_state = TestProbe.render });
        errdefer result.registry.remove(result.surface_ids[0]);
        result.surface_ids[1] = try result.registry.add(.{ .context = &result.probe, .render_state = TestProbe.render });
        result.owner = SessionLock.init(allocator, &result.clients, &result.registry, .{
            .context = &result.probe,
            .state_changed = TestProbe.changed,
            .output_secure_without_frame = TestProbe.secure,
            .repaint = TestProbe.paint,
        });
        return result;
    }
    fn rebind(self: *@This()) void {
        self.owner.clients = &self.clients;
        self.owner.surfaces_registry = &self.registry;
        self.owner.observer.context = &self.probe;
    }
    fn deinit(self: *@This()) void {
        for (self.clients_ids) |client| self.owner.clientDisconnected(client);
        self.owner.deinit();
        for (self.surface_ids) |surface| if (self.registry.contains(surface)) self.registry.remove(surface);
        for (self.clients_ids) |client| if (self.clients.contains(client)) self.clients.unregister(client);
        self.registry.deinit();
        self.clients.deinit();
    }
};

fn testOutput(index: u32, generation: u32) OutputLayout.Id {
    return .{ .index = index, .generation = generation };
}

test "single active lock is exclusive and lock IDs reject stale generations" {
    var fixture = try TestFixture.init(std.testing.allocator);
    fixture.rebind();
    defer fixture.deinit();
    const first = try fixture.owner.createLock(fixture.clients_ids[0], fixture.probe.lockEndpoint());
    const rejected = try fixture.owner.createLock(fixture.clients_ids[1], fixture.probe.lockEndpoint());
    try std.testing.expectEqual(@as(usize, 1), fixture.probe.finished_count);
    try std.testing.expect(std.meta.eql(first, fixture.owner.activeLock().?));
    fixture.owner.destroyLock(rejected);
    fixture.owner.destroyLock(first);
    const reused = try fixture.owner.createLock(fixture.clients_ids[0], fixture.probe.lockEndpoint());
    try std.testing.expectEqual(first.index, reused.index);
    try std.testing.expect(first.generation != reused.generation);
    try std.testing.expectError(error.InvalidUnlock, fixture.owner.unlockAndDestroy(first));
}

test "surface creation validates clients surfaces outputs ownership and duplicates" {
    var fixture = try TestFixture.init(std.testing.allocator);
    fixture.rebind();
    defer fixture.deinit();
    const out = testOutput(1, 1);
    try fixture.owner.outputAdded(out);
    const lock = try fixture.owner.createLock(fixture.clients_ids[0], fixture.probe.lockEndpoint());
    const dead_client = fixture.clients_ids[1];
    fixture.clients.unregister(dead_client);
    try std.testing.expectError(error.InvalidClient, fixture.owner.createLock(dead_client, fixture.probe.lockEndpoint()));
    try std.testing.expectError(error.InvalidClient, fixture.owner.createSurface(lock, fixture.clients_ids[1], fixture.surface_ids[0], fixture.clients_ids[1], out, fixture.probe.surfaceEndpoint()));
    try std.testing.expectError(error.ForeignSurface, fixture.owner.createSurface(lock, fixture.clients_ids[0], fixture.surface_ids[0], fixture.clients_ids[1], out, fixture.probe.surfaceEndpoint()));
    const dead_surface = fixture.surface_ids[1];
    fixture.registry.remove(dead_surface);
    try std.testing.expectError(error.InvalidSurface, fixture.owner.createSurface(lock, fixture.clients_ids[0], dead_surface, fixture.clients_ids[0], out, fixture.probe.surfaceEndpoint()));
    try std.testing.expectError(error.InvalidOutput, fixture.owner.createSurface(lock, fixture.clients_ids[0], fixture.surface_ids[0], fixture.clients_ids[0], testOutput(1, 2), fixture.probe.surfaceEndpoint()));
    _ = try fixture.owner.createSurface(lock, fixture.clients_ids[0], fixture.surface_ids[0], fixture.clients_ids[0], out, fixture.probe.surfaceEndpoint());
    try std.testing.expectError(error.DuplicateOutput, fixture.owner.createSurface(lock, fixture.clients_ids[0], fixture.surface_ids[0], fixture.clients_ids[0], out, fixture.probe.surfaceEndpoint()));
    const other = try fixture.owner.createLock(fixture.clients_ids[0], fixture.probe.lockEndpoint());
    _ = try fixture.owner.createSurface(other, fixture.clients_ids[0], fixture.surface_ids[0], fixture.clients_ids[0], out, fixture.probe.surfaceEndpoint());
}

test "configure tokens bind to surface generations and commits enforce acknowledged dimensions" {
    var fixture = try TestFixture.init(std.testing.allocator);
    fixture.rebind();
    defer fixture.deinit();
    const out = testOutput(2, 1);
    try fixture.owner.outputAdded(out);
    const lock = try fixture.owner.createLock(fixture.clients_ids[0], fixture.probe.lockEndpoint());
    const role = try fixture.owner.createSurface(lock, fixture.clients_ids[0], fixture.surface_ids[0], fixture.clients_ids[0], out, fixture.probe.surfaceEndpoint());
    try std.testing.expectError(error.NullBuffer, fixture.owner.validateCommit(role, false));
    try std.testing.expectError(error.CommitBeforeAck, fixture.owner.validateCommit(role, true));
    const first = try fixture.owner.configure(role, 10, 20);
    const second = try fixture.owner.configure(role, 30, 40);
    try fixture.owner.ackConfigure(role, second);
    try std.testing.expectError(error.StaleConfigure, fixture.owner.ackConfigure(role, first));
    try fixture.owner.validateCommit(role, true);
    try fixture.owner.map(role, 30, 40);
    try std.testing.expect(fixture.owner.snapshot(role).?.mapped);
    try std.testing.expectError(error.DimensionsMismatch, fixture.owner.map(role, 30, 41));
    try std.testing.expect(!fixture.owner.snapshot(role).?.mapped);
    fixture.owner.destroySurface(role);
    const reused = try fixture.owner.createSurface(lock, fixture.clients_ids[0], fixture.surface_ids[0], fixture.clients_ids[0], out, fixture.probe.surfaceEndpoint());
    try std.testing.expectEqual(role.index, reused.index);
    try std.testing.expectError(error.ForeignConfigure, fixture.owner.ackConfigure(reused, second));
    try std.testing.expectError(error.InvalidSurface, fixture.owner.ackConfigure(role, second));
}

test "configure endpoint failure rolls back queue sequence size and callback ordering" {
    var fixture = try TestFixture.init(std.testing.allocator);
    fixture.rebind();
    defer fixture.deinit();
    const out = testOutput(3, 1);
    try fixture.owner.outputAdded(out);
    const lock = try fixture.owner.createLock(fixture.clients_ids[0], fixture.probe.lockEndpoint());
    const role = try fixture.owner.createSurface(lock, fixture.clients_ids[0], fixture.surface_ids[0], fixture.clients_ids[0], out, fixture.probe.surfaceEndpoint());
    fixture.probe.configure_fails = true;
    try std.testing.expectError(error.OutOfMemory, fixture.owner.configure(role, 7, 8));
    try std.testing.expectEqual(@as(?[2]u32, null), fixture.owner.snapshot(role).?.configured_size);
    fixture.probe.configure_fails = false;
    fixture.probe.clearEvents();
    const token = try fixture.owner.configure(role, 7, 8);
    try std.testing.expectEqual(@as(u64, 1), token.sequence);
    try std.testing.expectEqualStrings("C", fixture.probe.events[0..fixture.probe.events_len]);
    try std.testing.expectError(error.StaleConfigure, fixture.owner.ackConfigure(role, .{ .surface = role, .sequence = 2 }));
}

test "acquisition covers every output hotplug removal and secure outputs exactly once" {
    var fixture = try TestFixture.init(std.testing.allocator);
    fixture.rebind();
    defer fixture.deinit();
    const first = testOutput(4, 1);
    const second = testOutput(5, 1);
    try fixture.owner.outputAdded(first);
    const lock = try fixture.owner.createLock(fixture.clients_ids[0], fixture.probe.lockEndpoint());
    _ = lock;
    try fixture.owner.outputPresented(testOutput(99, 1));
    try fixture.owner.outputAdded(second);
    try fixture.owner.outputPresented(first);
    try std.testing.expectEqual(@as(usize, 0), fixture.probe.acquired_count);
    fixture.owner.outputRemoved(second);
    try std.testing.expectEqual(@as(usize, 1), fixture.probe.acquired_count);
    try fixture.owner.outputPresented(first);
    fixture.owner.refreshSecurity();
    try std.testing.expectEqual(@as(usize, 1), fixture.probe.acquired_count);

    fixture.owner.clientDisconnected(fixture.clients_ids[0]);
    fixture.probe.secure_output = first;
    _ = try fixture.owner.createLock(fixture.clients_ids[1], fixture.probe.lockEndpoint());
    try std.testing.expectEqual(@as(usize, 2), fixture.probe.acquired_count);
}

test "resource abandonment and unlock authorization preserve fail closed semantics" {
    var fixture = try TestFixture.init(std.testing.allocator);
    fixture.rebind();
    defer fixture.deinit();
    const out = testOutput(6, 1);
    try fixture.owner.outputAdded(out);
    const pending = try fixture.owner.createLock(fixture.clients_ids[0], fixture.probe.lockEndpoint());
    fixture.owner.destroyLock(pending);
    try std.testing.expect(!fixture.owner.isLocked());
    const acquired = try fixture.owner.createLock(fixture.clients_ids[0], fixture.probe.lockEndpoint());
    try fixture.owner.outputPresented(out);
    try std.testing.expectError(error.InvalidUnlock, fixture.owner.unlockAndDestroy(pending));
    fixture.owner.destroyLock(acquired);
    try std.testing.expect(fixture.owner.isLocked());
    const fail_closed_pending = try fixture.owner.createLock(fixture.clients_ids[1], fixture.probe.lockEndpoint());
    fixture.owner.destroyLock(fail_closed_pending);
    try std.testing.expect(fixture.owner.isLocked());
}

test "lock and surface lifetimes retire independently and callbacks stop after endpoint death" {
    var fixture = try TestFixture.init(std.testing.allocator);
    fixture.rebind();
    defer fixture.deinit();
    const out = testOutput(7, 1);
    try fixture.owner.outputAdded(out);
    const lock = try fixture.owner.createLock(fixture.clients_ids[0], fixture.probe.lockEndpoint());
    const role = try fixture.owner.createSurface(lock, fixture.clients_ids[0], fixture.surface_ids[0], fixture.clients_ids[0], out, fixture.probe.surfaceEndpoint());
    fixture.owner.destroyLock(lock);
    try std.testing.expect(fixture.owner.snapshot(role) != null);
    try fixture.owner.outputPresented(out);
    try std.testing.expectEqual(@as(usize, 0), fixture.probe.acquired_count);
    fixture.owner.destroySurface(role);
    try std.testing.expectError(error.InvalidUnlock, fixture.owner.unlockAndDestroy(lock));

    const next = try fixture.owner.createLock(fixture.clients_ids[1], fixture.probe.lockEndpoint());
    const next_role = try fixture.owner.createSurface(next, fixture.clients_ids[1], fixture.surface_ids[1], fixture.clients_ids[1], out, fixture.probe.surfaceEndpoint());
    const next_token = try fixture.owner.configure(next_role, 4, 5);
    try fixture.owner.ackConfigure(next_role, next_token);
    try fixture.owner.map(next_role, 4, 5);
    try std.testing.expect(fixture.owner.ownsMappedSurface(fixture.surface_ids[1]));
    try std.testing.expectEqual(fixture.surface_ids[1], fixture.owner.firstMappedSurface().?);
    fixture.owner.outputRemoved(out);
    try std.testing.expect(fixture.owner.snapshot(next_role) != null);
    try std.testing.expect(!fixture.owner.ownsMappedSurface(fixture.surface_ids[1]));
    try std.testing.expectEqual(@as(?SurfaceRegistry.Id, null), fixture.owner.firstMappedSurface());
    fixture.owner.surfaceDestroyed(fixture.surface_ids[1]);
    try std.testing.expect(fixture.owner.snapshot(next_role) == null);
    fixture.owner.clientDisconnected(fixture.clients_ids[1]);
    try std.testing.expect(fixture.owner.activeLock() == null);
}

test "observer repaint and state chronology follows lock map mismatch and unlock" {
    var fixture = try TestFixture.init(std.testing.allocator);
    fixture.rebind();
    defer fixture.deinit();
    const out = testOutput(8, 1);
    try fixture.owner.outputAdded(out);
    fixture.probe.clearEvents();
    const lock = try fixture.owner.createLock(fixture.clients_ids[0], fixture.probe.lockEndpoint());
    const role = try fixture.owner.createSurface(lock, fixture.clients_ids[0], fixture.surface_ids[0], fixture.clients_ids[0], out, fixture.probe.surfaceEndpoint());
    const token = try fixture.owner.configure(role, 2, 3);
    try fixture.owner.ackConfigure(role, token);
    try std.testing.expectError(error.DimensionsMismatch, fixture.owner.map(role, 3, 2));
    try fixture.owner.outputPresented(out);
    try fixture.owner.unlockAndDestroy(lock);
    try std.testing.expectEqualStrings("LPCPAUP", fixture.probe.events[0..fixture.probe.events_len]);
}

test "allocation failures leave no lock surface output or configure half state" {
    var fixture = try TestFixture.init(std.testing.allocator);
    fixture.rebind();
    defer fixture.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    fixture.owner.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, fixture.owner.createLock(fixture.clients_ids[0], fixture.probe.lockEndpoint()));
    try std.testing.expect(!fixture.owner.isLocked());
    try std.testing.expectEqual(@as(usize, 0), fixture.probe.events_len);
    try std.testing.expectError(error.OutOfMemory, fixture.owner.outputAdded(testOutput(9, 1)));

    fixture.owner.allocator = std.testing.allocator;
    const out = testOutput(9, 1);
    try fixture.owner.outputAdded(out);
    const lock = try fixture.owner.createLock(fixture.clients_ids[0], fixture.probe.lockEndpoint());
    failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    fixture.owner.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, fixture.owner.createSurface(lock, fixture.clients_ids[0], fixture.surface_ids[0], fixture.clients_ids[0], out, fixture.probe.surfaceEndpoint()));
    try std.testing.expectEqual(@as(?SurfaceSnapshot, null), fixture.owner.surfaceForOutput(out));

    fixture.owner.allocator = std.testing.allocator;
    const role = try fixture.owner.createSurface(lock, fixture.clients_ids[0], fixture.surface_ids[0], fixture.clients_ids[0], out, fixture.probe.surfaceEndpoint());
    failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    fixture.owner.allocator = failing.allocator();
    const callbacks = fixture.probe.configure_count;
    try std.testing.expectError(error.OutOfMemory, fixture.owner.configure(role, 1, 1));
    try std.testing.expectEqual(callbacks, fixture.probe.configure_count);
    try std.testing.expectEqual(@as(?[2]u32, null), fixture.owner.snapshot(role).?.configured_size);
    fixture.owner.allocator = std.testing.allocator;
}
