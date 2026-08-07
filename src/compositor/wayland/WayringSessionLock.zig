//! Scanner-resource frontend for the neutral ext-session-lock-v1 owner.

const WayringSessionLock = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayring = @import("wayring");
const SessionLock = @import("../SessionLock.zig");
const WayringClients = @import("WayringClients.zig");
const WayringCompositor = @import("WayringCompositor.zig");
const WayringOutput = @import("WayringOutput.zig");

const server = wayring.server;

const Manager = struct {
    owner: *WayringSessionLock,
    client: *server.Client,
    generation: u64,
    resource: protocol.ext_session_lock_manager_v1.Resource,
};
const Lock = struct {
    owner: *WayringSessionLock,
    client: *server.Client,
    generation: u64,
    resource: protocol.ext_session_lock_v1.Resource,
    neutral_id: SessionLock.LockId,
    resource_live: bool = true,
    surfaces: std.ArrayList(*Surface) = .empty,
};
const ConfigureBridge = struct {
    const Mapping = struct { serial: u32, token: SessionLock.ConfigureToken };
    mappings: std.ArrayList(Mapping) = .empty,

    fn prepare(self: *ConfigureBridge, allocator: std.mem.Allocator) !void {
        try self.mappings.ensureUnusedCapacity(allocator, 1);
    }
    fn commit(self: *ConfigureBridge, serial: u32, token: SessionLock.ConfigureToken) void {
        self.mappings.appendAssumeCapacity(.{ .serial = serial, .token = token });
    }
    fn indexOf(self: *const ConfigureBridge, serial: u32) ?usize {
        for (self.mappings.items, 0..) |mapping, index| if (mapping.serial == serial) return index;
        return null;
    }
    fn acknowledge(self: *ConfigureBridge, index: usize) void {
        self.mappings.replaceRangeAssumeCapacity(0, index + 1, &.{});
    }
};
const Surface = struct {
    lock: *Lock,
    generation: u64,
    resource: protocol.ext_session_lock_surface_v1.Resource,
    surface_id: WayringCompositor.SurfaceId,
    reservation: WayringCompositor.SessionLockReservation,
    output_identity: WayringOutput.StableIdentity,
    neutral_id: ?SessionLock.LockSurfaceId,
    bridge: ConfigureBridge = .{},
    association_live: bool = true,
};

allocator: std.mem.Allocator,
protocol_server: *server.Server,
clients: *WayringClients,
compositor: *WayringCompositor,
outputs: *WayringOutput,
core: *SessionLock,
authorized_uid: std.os.linux.uid_t,
global: ?*const server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
locks: std.ArrayList(*Lock) = .empty,
surfaces: std.ArrayList(*Surface) = .empty,
next_generation: ?u64 = 1,

pub fn init(self: *WayringSessionLock, allocator: std.mem.Allocator, protocol_server: *server.Server, clients: *WayringClients, compositor: *WayringCompositor, outputs: *WayringOutput, core: *SessionLock, authorized_uid: std.os.linux.uid_t) void {
    self.* = .{ .allocator = allocator, .protocol_server = protocol_server, .clients = clients, .compositor = compositor, .outputs = outputs, .core = core, .authorized_uid = authorized_uid };
}
pub fn publish(self: *WayringSessionLock) !void {
    std.debug.assert(self.global == null);
    self.global = try self.protocol_server.addGlobalWithOptions(protocol.ext_session_lock_manager_v1, 1, WayringSessionLock, self, bind, .{ .visibility = .restricted });
}
pub fn unpublish(self: *WayringSessionLock) void {
    self.protocol_server.removeGlobal(self.global.?) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}
pub fn deinit(self: *WayringSessionLock) void {
    std.debug.assert(self.global == null and self.surfaces.items.len == 0 and self.locks.items.len == 0 and self.managers.items.len == 0);
    self.surfaces.deinit(self.allocator);
    self.locks.deinit(self.allocator);
    self.managers.deinit(self.allocator);
    self.* = undefined;
}
/// Suitable for the server-wide restricted-global filter.
pub fn globalFilter(self: *const WayringSessionLock, client: *const server.Client, global: *const server.Server.Global) bool {
    return global.visibility() != .restricted or client.isAuthorizedDirectPeer(self.authorized_uid);
}
fn generation(self: *WayringSessionLock) !u64 {
    const result = self.next_generation orelse return error.GenerationExhausted;
    self.next_generation = if (result == std.math.maxInt(u64)) null else result + 1;
    return result;
}
fn bind(client: *server.Client, id: u32, version: u32, self: *WayringSessionLock) !void {
    if (version != 1) return error.InvalidVersion;
    if (!client.isAuthorizedDirectPeer(self.authorized_uid)) return error.Unauthorized;
    try self.managers.ensureUnusedCapacity(self.allocator, 1);
    const manager = try self.allocator.create(Manager);
    errdefer self.allocator.destroy(manager);
    manager.* = .{ .owner = self, .client = client, .generation = try self.generation(), .resource = .init(self.allocator, id, 1, .client, client.ownerHooks()) };
    errdefer {
        manager.resource.destroy();
        manager.resource.deinit();
    }
    try manager.resource.setHandler(Manager, manager, managerRequest, null);
    try client.materialize(&manager.resource.runtime);
    self.managers.appendAssumeCapacity(manager);
}
fn managerRequest(_: *protocol.ext_session_lock_manager_v1.Resource, request: protocol.ext_session_lock_manager_v1.Request, manager: *Manager) !void {
    switch (request) {
        .destroy => manager.owner.destroyManager(manager),
        .lock => |args| try manager.owner.createLock(manager, args.id),
    }
}
fn createLock(self: *WayringSessionLock, manager: *Manager, id: u32) !void {
    if (!manager.client.isAuthorizedDirectPeer(self.authorized_uid)) return error.Unauthorized;
    try self.locks.ensureUnusedCapacity(self.allocator, 1);
    const lock = try self.allocator.create(Lock);
    errdefer self.allocator.destroy(lock);
    lock.* = .{ .owner = self, .client = manager.client, .generation = try self.generation(), .resource = .init(self.allocator, id, 1, .client, manager.client.ownerHooks()), .neutral_id = undefined };
    errdefer {
        lock.resource.destroy();
        lock.resource.deinit();
        lock.surfaces.deinit(self.allocator);
    }
    const client_id = self.clients.id(manager.client) orelse return error.InvalidClient;
    try lock.resource.setHandler(Lock, lock, lockRequest, null);
    try manager.client.materialize(&lock.resource.runtime);
    lock.neutral_id = try self.core.createLock(client_id, .{ .context = lock, .acquired = acquired, .finished = finished });
    errdefer self.core.destroyLock(lock.neutral_id);
    self.locks.appendAssumeCapacity(lock);
}
fn acquired(context: *anyopaque) void {
    const lock: *Lock = @ptrCast(@alignCast(context));
    if (lock.resource_live and lock.resource.state() == .live) protocol.ext_session_lock_v1.@"send:locked"(&lock.resource) catch lock.client.postOutOfMemory(&lock.resource.runtime, "queueing locked event");
}
fn finished(context: *anyopaque) void {
    const lock: *Lock = @ptrCast(@alignCast(context));
    if (lock.resource_live and lock.resource.state() == .live) protocol.ext_session_lock_v1.@"send:finished"(&lock.resource) catch lock.client.postOutOfMemory(&lock.resource.runtime, "queueing finished event");
}
fn lockRequest(resource: *protocol.ext_session_lock_v1.Resource, request: protocol.ext_session_lock_v1.Request, lock: *Lock) !void {
    switch (request) {
        .destroy => if (!lock.owner.core.mayDestroyLock(lock.neutral_id)) lock.client.postProtocolError(&resource.runtime, @intCast(protocol.ext_session_lock_v1.@"error".invalid_destroy), "locked session must be explicitly unlocked") else lock.owner.destroyLockResource(lock),
        .unlock_and_destroy => {
            lock.owner.core.unlockAndDestroy(lock.neutral_id) catch {
                lock.client.postProtocolError(&resource.runtime, @intCast(protocol.ext_session_lock_v1.@"error".invalid_unlock), "session lock was not acquired");
                return;
            };
            lock.owner.destroyLockResource(lock);
        },
        .get_lock_surface => |args| lock.owner.createSurface(lock, args.id, args.surface, args.output) catch |err| switch (err) {
            error.Role => lock.client.postProtocolError(&resource.runtime, @intCast(protocol.ext_session_lock_v1.@"error".role), "wl_surface already has a role"),
            error.DuplicateOutput => lock.client.postProtocolError(&resource.runtime, @intCast(protocol.ext_session_lock_v1.@"error".duplicate_output), "output already has a lock surface"),
            error.AlreadyConstructed => lock.client.postProtocolError(&resource.runtime, @intCast(protocol.ext_session_lock_v1.@"error".already_constructed), "wl_surface already has content"),
            error.OutOfMemory => lock.client.postOutOfMemory(&resource.runtime, "creating lock surface"),
            else => lock.client.postImplementationError(&resource.runtime, "session lock requires exact live same-client resources"),
        },
    }
}

const CreateSurfaceError = error{ OutOfMemory, Role, DuplicateOutput, AlreadyConstructed, InvalidResource };
fn createSurface(self: *WayringSessionLock, lock: *Lock, id: u32, surface_object: u32, output_object: u32) CreateSurfaceError!void {
    const surface_id = self.compositor.surfaceId(lock.client, surface_object) orelse return error.InvalidResource;
    const output = self.outputs.identifyResource(lock.client, output_object);
    if (output == .invalid) return error.InvalidResource;
    const reservation = self.compositor.reserveSessionLockRoot(lock.client, surface_id) catch |err| return switch (err) {
        error.RoleConflict, error.NotRoot => error.Role,
        error.AlreadyConstructed => error.AlreadyConstructed,
        error.GenerationExhausted => error.OutOfMemory,
        else => error.InvalidResource,
    };
    errdefer self.compositor.abortSessionLockRoot(reservation) catch {};
    const output_identity = switch (output) {
        .live => |live| live.identity,
        .retired => |identity| identity,
        .invalid => unreachable,
    };
    for (lock.surfaces.items) |existing|
        if (existing.output_identity == output_identity) return error.DuplicateOutput;
    try self.surfaces.ensureUnusedCapacity(self.allocator, 1);
    try lock.surfaces.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Surface);
    errdefer self.allocator.destroy(value);
    value.* = .{ .lock = lock, .generation = self.generation() catch return error.OutOfMemory, .resource = undefined, .surface_id = surface_id, .reservation = reservation, .output_identity = output_identity, .neutral_id = null };
    errdefer value.bridge.mappings.deinit(self.allocator);
    if (output == .live) {
        const client_id = self.clients.id(lock.client) orelse return error.InvalidResource;
        value.neutral_id = self.core.createSurface(lock.neutral_id, client_id, surface_id, client_id, output.live.output, .{ .context = value, .configure = configure }) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.DuplicateOutput => error.DuplicateOutput,
            else => error.InvalidResource,
        };
        errdefer self.core.destroySurface(value.neutral_id.?);
    }
    self.compositor.attachSessionLockCommitHandler(reservation, commitHandler(value)) catch return error.Role;
    errdefer self.compositor.detachSessionLockCommitHandler(reservation, value) catch {};
    value.resource = .init(self.allocator, id, 1, .client, lock.client.ownerHooks());
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    value.resource.setHandler(Surface, value, surfaceRequest, null) catch unreachable;
    lock.client.materialize(&value.resource.runtime) catch unreachable;
    if (output == .live) {
        const size = self.outputs.logicalSize(output.live.output) orelse return error.InvalidResource;
        _ = self.core.configure(value.neutral_id.?, size.width, size.height) catch |err| return switch (err) {
            error.OutOfMemory, error.SequenceExhausted => error.OutOfMemory,
            error.InvalidSurface => error.InvalidResource,
        };
    }
    self.compositor.publishSessionLockRoot(reservation) catch unreachable;
    self.surfaces.appendAssumeCapacity(value);
    lock.surfaces.appendAssumeCapacity(value);
}
fn configure(context: *anyopaque, width: u32, height: u32, token: SessionLock.ConfigureToken) error{OutOfMemory}!void {
    const value: *Surface = @ptrCast(@alignCast(context));
    try value.bridge.prepare(value.lock.owner.allocator);
    const serial = value.lock.owner.protocol_server.nextSerial() catch {
        clientFatal(value, "configure serial exhausted");
        return error.OutOfMemory;
    };
    protocol.ext_session_lock_surface_v1.@"send:configure"(&value.resource, serial, width, height) catch return error.OutOfMemory;
    value.bridge.commit(serial, token);
}
fn clientFatal(value: *Surface, message: []const u8) void {
    value.lock.client.postImplementationError(&value.resource.runtime, message);
}
fn surfaceRequest(resource: *protocol.ext_session_lock_surface_v1.Resource, request: protocol.ext_session_lock_surface_v1.Request, value: *Surface) !void {
    switch (request) {
        .destroy => value.lock.owner.destroySurface(value, false),
        .ack_configure => |args| ack(value, resource, args.serial),
    }
}
fn ack(value: *Surface, resource: *protocol.ext_session_lock_surface_v1.Resource, serial: u32) void {
    const neutral_id = value.neutral_id orelse return invalidSerial(value, resource);
    const index = value.bridge.indexOf(serial) orelse return invalidSerial(value, resource);
    value.lock.owner.core.ackConfigure(neutral_id, value.bridge.mappings.items[index].token) catch return invalidSerial(value, resource);
    value.bridge.acknowledge(index);
}
fn invalidSerial(value: *Surface, resource: *protocol.ext_session_lock_surface_v1.Resource) void {
    value.lock.client.postProtocolError(&resource.runtime, @intCast(protocol.ext_session_lock_surface_v1.@"error".invalid_serial), "invalid, stale, or foreign configure serial");
}
fn commitHandler(value: *Surface) WayringCompositor.SessionLockCommitHandler {
    return .{ .context = value, .prepare = prepareCommit, .abort_prepare = abortCommit, .validate = validateCommit, .pre_unmap = preUnmap, .post_apply = postApply, .surface_destroyed = compositorSurfaceDestroyed };
}
fn prepareCommit(_: *anyopaque, _: WayringCompositor.SessionLockDirectCommit) WayringCompositor.XdgCommitDecision {
    return .accept;
}
fn abortCommit(_: *anyopaque, _: WayringCompositor.SurfaceId) void {}
fn validateCommit(context: *anyopaque, commit: WayringCompositor.SessionLockDirectCommit) WayringCompositor.XdgCommitDecision {
    return validateDirect(@ptrCast(@alignCast(context)), commit);
}
fn validateDirect(value: *Surface, commit: WayringCompositor.SessionLockDirectCommit) WayringCompositor.XdgCommitDecision {
    const id = value.neutral_id orelse {
        if (commit.next_size == null)
            protocolError(value, protocol.ext_session_lock_surface_v1.@"error".null_buffer, "session lock surface requires a buffer")
        else
            protocolError(value, protocol.ext_session_lock_surface_v1.@"error".commit_before_first_ack, "retired output cannot be configured");
        return .reject;
    };
    value.lock.owner.core.validateCommit(id, commit.next_size != null) catch |err| {
        protocolError(value, switch (err) {
            error.NullBuffer => protocol.ext_session_lock_surface_v1.@"error".null_buffer,
            error.CommitBeforeAck, error.InvalidSurface => protocol.ext_session_lock_surface_v1.@"error".commit_before_first_ack,
        }, @errorName(err));
        return .reject;
    };
    return .accept;
}
fn preUnmap(_: *anyopaque, _: WayringCompositor.SurfaceId) void {}
fn postApply(context: *anyopaque, _: WayringCompositor.SurfaceId) void {
    const value: *Surface = @ptrCast(@alignCast(context));
    const id = value.neutral_id orelse return;
    const size = value.lock.owner.compositor.currentLogicalSize(value.surface_id) orelse {
        protocolError(value, protocol.ext_session_lock_surface_v1.@"error".null_buffer, "session lock surface requires a buffer");
        return;
    };
    value.lock.owner.core.map(id, size.width, size.height) catch |err| if (err == error.DimensionsMismatch) protocolError(value, protocol.ext_session_lock_surface_v1.@"error".dimensions_mismatch, "buffer dimensions differ from acknowledged configure");
}
fn protocolError(value: *Surface, code: i64, message: []const u8) void {
    if (value.resource.state() == .live) value.lock.client.postProtocolError(&value.resource.runtime, @intCast(code), message);
}
fn compositorSurfaceDestroyed(context: *anyopaque, surface_id: WayringCompositor.SurfaceId) void {
    const value: *Surface = @ptrCast(@alignCast(context));
    value.association_live = false;
    if (value.neutral_id != null) value.lock.owner.core.surfaceDestroyed(surface_id);
    value.neutral_id = null;
    value.lock.owner.destroySurface(value, true);
}
fn destroySurface(self: *WayringSessionLock, value: *Surface, surface_gone: bool) void {
    if (value.neutral_id) |id| self.core.destroySurface(id);
    value.neutral_id = null;
    if (value.association_live and !surface_gone) {
        self.compositor.detachSessionLockCommitHandler(value.reservation, value) catch {};
        self.compositor.releaseSessionLockRoot(value.reservation) catch {};
    }
    value.association_live = false;
    remove(Surface, &value.lock.surfaces, value);
    remove(Surface, &self.surfaces, value);
    value.bridge.mappings.deinit(self.allocator);
    value.resource.destroy();
    value.resource.deinit();
    const lock = value.lock;
    self.allocator.destroy(value);
    self.destroyLockIfUnused(lock);
}
fn destroyLockResource(self: *WayringSessionLock, lock: *Lock) void {
    if (!lock.resource_live) return;
    lock.resource_live = false;
    self.core.destroyLock(lock.neutral_id);
    lock.resource.destroy();
    lock.resource.deinit();
    self.destroyLockIfUnused(lock);
}
fn destroyLockIfUnused(self: *WayringSessionLock, lock: *Lock) void {
    if (lock.resource_live or lock.surfaces.items.len != 0) return;
    remove(Lock, &self.locks, lock);
    lock.surfaces.deinit(self.allocator);
    self.allocator.destroy(lock);
}
fn destroyManager(self: *WayringSessionLock, manager: *Manager) void {
    remove(Manager, &self.managers, manager);
    manager.resource.destroy();
    manager.resource.deinit();
    self.allocator.destroy(manager);
}
pub fn destroyClientResources(self: *WayringSessionLock, client: *server.Client) void {
    var i = self.surfaces.items.len;
    while (i > 0) {
        i -= 1;
        if (self.surfaces.items[i].lock.client == client) self.destroySurface(self.surfaces.items[i], false);
    }
    i = self.locks.items.len;
    while (i > 0) {
        i -= 1;
        if (self.locks.items[i].client == client) self.destroyLockResource(self.locks.items[i]);
    }
    i = self.managers.items.len;
    while (i > 0) {
        i -= 1;
        if (self.managers.items[i].client == client) self.destroyManager(self.managers.items[i]);
    }
}
fn remove(comptime T: type, list: *std.ArrayList(*T), value: *T) void {
    for (list.items, 0..) |candidate, i| if (candidate == value) {
        _ = list.swapRemove(i);
        return;
    };
    unreachable;
}

test "scanner session-lock v1 descriptors and errors are pinned" {
    try std.testing.expectEqual(@as(u32, 1), protocol.ext_session_lock_manager_v1.interface.version);
    try std.testing.expectEqual(@as(i64, 0), protocol.ext_session_lock_v1.@"error".invalid_destroy);
    try std.testing.expectEqual(@as(i64, 3), protocol.ext_session_lock_surface_v1.@"error".invalid_serial);
}
test "configure bridge preserves exact serial identity after failed reservation" {
    var bridge: ConfigureBridge = .{};
    defer bridge.mappings.deinit(std.testing.allocator);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, bridge.prepare(failing.allocator()));
    try bridge.prepare(std.testing.allocator);
    const token: SessionLock.ConfigureToken = .{ .surface = .{ .index = 2, .generation = 3 }, .sequence = 4 };
    bridge.commit(9, token);
    try std.testing.expectEqual(@as(?usize, 0), bridge.indexOf(9));
    try std.testing.expectEqual(token, bridge.mappings.items[0].token);
}
