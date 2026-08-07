//! Resource-free projection of canonical workspace snapshots for frontends.
//!
//! WindowManager remains the topology and policy authority. This type owns only
//! frontend identities, copied snapshot metadata, and validated request intents.

const Workspace = @This();

const std = @import("std");
const slot_map = @import("slot_map.zig");
const ClientRegistry = @import("ClientRegistry.zig");
const OutputLayout = @import("output_layout.zig");

pub const workspace_count: u8 = 10;
const ClientStore = slot_map.SlotMap(Client, enum { workspace_client });
const GroupStore = slot_map.SlotMap(Group, enum { workspace_group });
const HandleStore = slot_map.SlotMap(Handle, enum { workspace_handle });
pub const ClientId = ClientStore.Id;
pub const GroupId = GroupStore.Id;
pub const HandleId = HandleStore.Id;

pub const State = struct { active: bool = false, urgent: bool = false };
pub const Snapshot = struct {
    output: OutputLayout.Id,
    active: u8 = 1,
    occupied: [workspace_count]bool = @splat(false),
    urgent: [workspace_count]bool = @splat(false),

    pub fn advertised(self: Snapshot, number: u8) bool {
        return number >= 1 and number <= workspace_count and
            (self.active == number or self.occupied[number - 1] or self.urgent[number - 1]);
    }
};
pub const Event = union(enum) {
    group: GroupId,
    output_enter: struct { group: GroupId, output: OutputLayout.Id },
    workspace: HandleId,
    name: HandleId,
    coordinates: HandleId,
    state: struct { workspace: HandleId, value: State },
    capabilities: HandleId,
    workspace_enter: struct { group: GroupId, workspace: HandleId },
    workspace_leave: struct { group: GroupId, workspace: HandleId },
    workspace_removed: HandleId,
    output_leave: struct { group: GroupId, output: OutputLayout.Id },
    group_removed: GroupId,
    done,
};
pub const Intent = struct { output: OutputLayout.Id, number: u8, source: HandleId };
pub const Prepared = struct {
    allocator: std.mem.Allocator,
    client: ClientId,
    events: std.ArrayList(Event) = .empty,
    groups: std.ArrayList(GroupId) = .empty,
    handles: std.ArrayList(HandleId) = .empty,
    removed_groups: std.ArrayList(GroupId) = .empty,
    removed_handles: std.ArrayList(HandleId) = .empty,
    updates: std.ArrayList(Update) = .empty,
    lifecycle: enum { prepared, committed, aborted } = .prepared,
    deinitialized: bool = false,

    pub fn isPending(self: *const Prepared) bool {
        return self.lifecycle == .prepared;
    }

    pub fn deinit(self: *Prepared) void {
        if (self.deinitialized) return;
        self.events.deinit(self.allocator);
        self.groups.deinit(self.allocator);
        self.handles.deinit(self.allocator);
        self.removed_groups.deinit(self.allocator);
        self.removed_handles.deinit(self.allocator);
        self.updates.deinit(self.allocator);
        self.deinitialized = true;
    }
};

const Update = struct { handle: HandleId, state: State };
pub const Metadata = struct { number: u8, name: [3:0]u8, coordinate: u32, state: State };

const Client = struct { owner: ClientRegistry.Id, groups: std.ArrayList(GroupId) = .empty, handles: std.ArrayList(HandleId) = .empty, intents: std.ArrayList(Intent) = .empty };
const Group = struct { client: ClientId, output: OutputLayout.Id };
const Handle = struct { client: ClientId, group: GroupId, output: OutputLayout.Id, metadata: Metadata };

allocator: std.mem.Allocator,
clients_registry: *const ClientRegistry,
clients: ClientStore = .{},
groups: GroupStore = .{},
handles: HandleStore = .{},
snapshots: std.ArrayList(Snapshot) = .empty,

pub fn init(allocator: std.mem.Allocator, clients: *const ClientRegistry) Workspace {
    return .{ .allocator = allocator, .clients_registry = clients };
}

pub fn deinit(self: *Workspace) void {
    std.debug.assert(self.clients.len() == 0 and self.groups.len() == 0 and self.handles.len() == 0);
    self.clients.deinit(self.allocator);
    self.groups.deinit(self.allocator);
    self.handles.deinit(self.allocator);
    self.snapshots.deinit(self.allocator);
    self.* = undefined;
}

pub fn setSnapshot(self: *Workspace, snapshot_value: Snapshot) error{OutOfMemory}!void {
    if (snapshot_value.active == 0 or snapshot_value.active > workspace_count) return;
    for (self.snapshots.items) |*existing| if (std.meta.eql(existing.output, snapshot_value.output)) {
        existing.* = snapshot_value;
        return;
    };
    try self.snapshots.append(self.allocator, snapshot_value);
}

pub fn snapshot(self: *const Workspace, output: OutputLayout.Id) ?Snapshot {
    for (self.snapshots.items) |value| if (std.meta.eql(value.output, output)) return value;
    return null;
}

pub fn snapshotSlice(self: *const Workspace) []const Snapshot {
    return self.snapshots.items;
}

pub fn removeOutput(self: *Workspace, output: OutputLayout.Id) void {
    for (self.snapshots.items, 0..) |value, index| if (std.meta.eql(value.output, output)) {
        _ = self.snapshots.orderedRemove(index);
        return;
    };
}

pub fn attachClient(self: *Workspace, owner: ClientRegistry.Id) error{ OutOfMemory, InvalidClient }!ClientId {
    if (!self.clients_registry.contains(owner)) return error.InvalidClient;
    return self.clients.insert(self.allocator, .{ .owner = owner });
}

pub fn detachClient(self: *Workspace, id: ClientId) void {
    var client = self.clients.remove(id) orelse return;
    for (client.handles.items) |handle_id| _ = self.handles.remove(handle_id);
    for (client.groups.items) |group_id| _ = self.groups.remove(group_id);
    client.groups.deinit(self.allocator);
    client.handles.deinit(self.allocator);
    client.intents.deinit(self.allocator);
}

/// Builds a complete initial transaction without changing the visible projection.
pub fn prepareInitial(self: *Workspace, client_id: ClientId) error{ OutOfMemory, InvalidClient }!Prepared {
    return self.prepareAgainst(client_id, self.snapshots.items, true);
}

/// Reconciles one client against the canonical snapshots. No committed state is
/// changed until commitPrepared; every allocation needed by commit is reserved.
pub fn prepareUpdate(self: *Workspace, client_id: ClientId) error{ OutOfMemory, InvalidClient }!Prepared {
    return self.prepareUpdateAgainst(client_id, self.snapshots.items);
}

/// Prepares a client against a proposed canonical view without publishing it.
/// This is used to make protocol-requested canonical mutations allocation-safe.
pub fn prepareUpdateAgainst(self: *Workspace, client_id: ClientId, snapshots: []const Snapshot) error{ OutOfMemory, InvalidClient }!Prepared {
    return self.prepareAgainst(client_id, snapshots, false);
}

fn prepareAgainst(self: *Workspace, client_id: ClientId, snapshots: []const Snapshot, initial: bool) error{ OutOfMemory, InvalidClient }!Prepared {
    const client = self.clients.get(client_id) orelse return error.InvalidClient;
    if (!self.clients_registry.contains(client.owner)) return error.InvalidClient;
    var prepared: Prepared = .{ .allocator = self.allocator, .client = client_id };
    errdefer prepared.deinit();
    errdefer self.rollbackPrepared(&prepared);
    const maximum_handles = snapshots.len * workspace_count;
    try prepared.groups.ensureTotalCapacity(self.allocator, snapshots.len);
    try prepared.handles.ensureTotalCapacity(self.allocator, maximum_handles);
    try prepared.removed_groups.ensureTotalCapacity(self.allocator, client.groups.items.len);
    try prepared.removed_handles.ensureTotalCapacity(self.allocator, client.handles.items.len);
    try prepared.updates.ensureTotalCapacity(self.allocator, client.handles.items.len);
    try prepared.events.ensureTotalCapacity(self.allocator, snapshots.len * 2 + maximum_handles * 6 + 1);
    try client.groups.ensureUnusedCapacity(self.allocator, snapshots.len);
    try client.handles.ensureUnusedCapacity(self.allocator, maximum_handles);
    for (snapshots) |value| {
        const group = self.groupFor(client, value.output) orelse group: {
            const id = try self.groups.insert(self.allocator, .{ .client = client_id, .output = value.output });
            try prepared.groups.append(self.allocator, id);
            try prepared.events.append(self.allocator, .{ .group = id });
            try prepared.events.append(self.allocator, .{ .output_enter = .{ .group = id, .output = value.output } });
            break :group id;
        };
        for (1..workspace_count + 1) |raw| {
            const number: u8 = @intCast(raw);
            if (!value.advertised(number)) continue;
            const state: State = .{ .active = value.active == number, .urgent = value.urgent[number - 1] };
            if (self.handleFor(client, value.output, number)) |handle| {
                if (!std.meta.eql(self.handles.getConst(handle).?.metadata.state, state)) {
                    try prepared.updates.append(self.allocator, .{ .handle = handle, .state = state });
                    try prepared.events.append(self.allocator, .{ .state = .{ .workspace = handle, .value = state } });
                }
                continue;
            }
            var name: [3:0]u8 = .{ 0, 0, 0 };
            const text = std.fmt.bufPrint(name[0..2], "{d}", .{number}) catch unreachable;
            name[text.len] = 0;
            const handle = try self.handles.insert(self.allocator, .{ .client = client_id, .group = group, .output = value.output, .metadata = .{ .number = number, .name = name, .coordinate = number - 1, .state = state } });
            try prepared.handles.append(self.allocator, handle);
            try prepared.events.append(self.allocator, .{ .workspace = handle });
            try prepared.events.append(self.allocator, .{ .name = handle });
            try prepared.events.append(self.allocator, .{ .coordinates = handle });
            try prepared.events.append(self.allocator, .{ .state = .{ .workspace = handle, .value = state } });
            try prepared.events.append(self.allocator, .{ .capabilities = handle });
            try prepared.events.append(self.allocator, .{ .workspace_enter = .{ .group = group, .workspace = handle } });
        }
    }
    // Removal is deliberately workspace-leave, workspace-removed, output-leave,
    // group-removed, with one manager done after the complete reconciliation.
    for (client.handles.items) |handle_id| {
        const handle = self.handles.getConst(handle_id) orelse continue;
        const snapshot_value = snapshotIn(snapshots, handle.output);
        if (snapshot_value != null and snapshot_value.?.advertised(handle.metadata.number)) continue;
        try prepared.removed_handles.append(self.allocator, handle_id);
        try prepared.events.append(self.allocator, .{ .workspace_leave = .{ .group = handle.group, .workspace = handle_id } });
        try prepared.events.append(self.allocator, .{ .workspace_removed = handle_id });
    }
    for (client.groups.items) |group_id| {
        const group = self.groups.getConst(group_id) orelse continue;
        if (snapshotIn(snapshots, group.output) != null) continue;
        try prepared.removed_groups.append(self.allocator, group_id);
        try prepared.events.append(self.allocator, .{ .output_leave = .{ .group = group_id, .output = group.output } });
        try prepared.events.append(self.allocator, .{ .group_removed = group_id });
    }
    // Initial state always has a done boundary, including an empty topology.
    // Updates with no wire-visible difference do not open an empty transaction.
    if (initial or prepared.events.items.len != 0) try prepared.events.append(self.allocator, .done);
    return prepared;
}

fn snapshotIn(snapshots: []const Snapshot, output: OutputLayout.Id) ?Snapshot {
    for (snapshots) |value| if (std.meta.eql(value.output, output)) return value;
    return null;
}

pub fn commitPrepared(self: *Workspace, prepared: *Prepared) error{InvalidClient}!void {
    if (prepared.lifecycle != .prepared) return;
    const client = self.clients.get(prepared.client) orelse return error.InvalidClient;
    client.groups.appendSlice(self.allocator, prepared.groups.items) catch unreachable;
    client.handles.appendSlice(self.allocator, prepared.handles.items) catch unreachable;
    for (prepared.updates.items) |update| self.handles.get(update.handle).?.metadata.state = update.state;
    for (prepared.removed_handles.items) |id| {
        _ = removeId(HandleId, &client.handles, id);
        _ = self.handles.remove(id);
        removeIntentsForHandle(client, id);
    }
    for (prepared.removed_groups.items) |id| {
        _ = removeId(GroupId, &client.groups, id);
        _ = self.groups.remove(id);
    }
    prepared.lifecycle = .committed;
}

pub fn rollbackPrepared(self: *Workspace, prepared: *Prepared) void {
    if (prepared.lifecycle != .prepared) return;
    for (prepared.handles.items) |id| _ = self.handles.remove(id);
    for (prepared.groups.items) |id| _ = self.groups.remove(id);
    prepared.lifecycle = .aborted;
}

pub fn queueActivate(self: *Workspace, client_id: ClientId, handle_id: HandleId) error{ OutOfMemory, InvalidClient, InvalidWorkspace, ForeignWorkspace }!void {
    const client = self.clients.get(client_id) orelse return error.InvalidClient;
    const handle = self.handles.getConst(handle_id) orelse return error.InvalidWorkspace;
    if (!std.meta.eql(handle.client, client_id)) return error.ForeignWorkspace;
    for (client.intents.items) |*intent| if (std.meta.eql(intent.output, handle.output)) {
        intent.number = handle.metadata.number;
        intent.source = handle_id;
        return;
    };
    try client.intents.append(self.allocator, .{ .output = handle.output, .number = handle.metadata.number, .source = handle_id });
}

/// Releases a client-destroyed protocol handle and any request queued through it.
/// A later snapshot may allocate a fresh handle for the same canonical workspace.
pub fn releaseHandle(self: *Workspace, client_id: ClientId, handle_id: HandleId) void {
    const client = self.clients.get(client_id) orelse return;
    const handle = self.handles.getConst(handle_id) orelse return;
    if (!std.meta.eql(handle.client, client_id)) return;
    // A resource allocated for an uncommitted transaction can be destroyed by
    // rollback. It must not retire committed state or cancel an older intent.
    if (!removeId(HandleId, &client.handles, handle_id)) return;
    _ = self.handles.remove(handle_id);
    removeIntentsForHandle(client, handle_id);
}

fn removeIntentsForHandle(client: *Client, handle_id: HandleId) void {
    var index: usize = 0;
    while (index < client.intents.items.len) {
        if (std.meta.eql(client.intents.items[index].source, handle_id)) {
            _ = client.intents.swapRemove(index);
        } else index += 1;
    }
}

pub fn metadata(self: *const Workspace, client: ClientId, id: HandleId) ?Metadata {
    const handle = self.handles.getConst(id) orelse return null;
    if (!std.meta.eql(handle.client, client)) return null;
    return handle.metadata;
}

pub fn groupOutput(self: *const Workspace, client: ClientId, id: GroupId) ?OutputLayout.Id {
    const group = self.groups.getConst(id) orelse return null;
    if (!std.meta.eql(group.client, client)) return null;
    return group.output;
}

fn groupFor(self: *const Workspace, client: *const Client, output: OutputLayout.Id) ?GroupId {
    for (client.groups.items) |id| if (self.groups.getConst(id)) |group| {
        if (std.meta.eql(group.output, output)) return id;
    };
    return null;
}

fn handleFor(self: *const Workspace, client: *const Client, output: OutputLayout.Id, number: u8) ?HandleId {
    for (client.handles.items) |id| if (self.handles.getConst(id)) |handle| {
        if (std.meta.eql(handle.output, output) and handle.metadata.number == number) return id;
    };
    return null;
}

fn removeId(comptime Id: type, list: *std.ArrayList(Id), id: Id) bool {
    for (list.items, 0..) |value, index| if (std.meta.eql(value, id)) {
        _ = list.swapRemove(index);
        return true;
    };
    return false;
}

pub fn takeIntents(self: *Workspace, client_id: ClientId) error{InvalidClient}![]const Intent {
    const client = self.clients.get(client_id) orelse return error.InvalidClient;
    return client.intents.items;
}

pub fn clearIntents(self: *Workspace, client_id: ClientId) void {
    if (self.clients.get(client_id)) |client| client.intents.clearRetainingCapacity();
}

test "initial transaction has deterministic ordering, owned metadata, and one done" {
    var registry = ClientRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const owner = try registry.register(.mature_display);
    defer registry.unregister(owner);
    var model = Workspace.init(std.testing.allocator, &registry);
    defer model.deinit();
    const output: OutputLayout.Id = .{ .index = 4, .generation = 2 };
    var state: Snapshot = .{ .output = output };
    state.occupied[2] = true;
    try model.setSnapshot(state);
    const client = try model.attachClient(owner);
    defer model.detachClient(client);
    var prepared = try model.prepareInitial(client);
    defer prepared.deinit();
    defer model.rollbackPrepared(&prepared);
    try std.testing.expect(prepared.events.items[0] == .group);
    try std.testing.expect(prepared.events.items[1] == .output_enter);
    try std.testing.expect(prepared.events.items[2] == .workspace);
    try std.testing.expect(prepared.events.items[prepared.events.items.len - 1] == .done);
    var done: usize = 0;
    for (prepared.events.items) |event| if (event == .done) {
        done += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), done);
    const name = model.metadata(client, prepared.events.items[3].name).?.name;
    try std.testing.expectEqualStrings("1", std.mem.sliceTo(&name, 0));
    try model.commitPrepared(&prepared);
}

test "empty initial snapshot has one done while a no-op update has no transaction" {
    var registry = ClientRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const owner = try registry.register(.mature_display);
    defer registry.unregister(owner);
    var model = Workspace.init(std.testing.allocator, &registry);
    defer model.deinit();
    const client = try model.attachClient(owner);
    defer model.detachClient(client);
    var initial = try model.prepareInitial(client);
    defer initial.deinit();
    try std.testing.expectEqualSlices(Event, &.{.done}, initial.events.items);
    try model.commitPrepared(&initial);
    var update = try model.prepareUpdate(client);
    defer update.deinit();
    defer model.rollbackPrepared(&update);
    try std.testing.expectEqual(@as(usize, 0), update.events.items.len);
}

test "generations reject stale and foreign workspace intents and coalesce per output" {
    var registry = ClientRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const a = try registry.register(.mature_display);
    defer registry.unregister(a);
    const b = try registry.register(.wayring_server);
    defer registry.unregister(b);
    var model = Workspace.init(std.testing.allocator, &registry);
    defer model.deinit();
    try model.setSnapshot(.{ .output = .{ .index = 1, .generation = 1 }, .occupied = @splat(true) });
    const ca = try model.attachClient(a);
    defer model.detachClient(ca);
    const cb = try model.attachClient(b);
    defer model.detachClient(cb);
    var pa = try model.prepareInitial(ca);
    defer pa.deinit();
    try model.commitPrepared(&pa);
    const stale = pa.handles.items[0];
    try std.testing.expectError(error.ForeignWorkspace, model.queueActivate(cb, stale));
    try model.queueActivate(ca, pa.handles.items[1]);
    try model.queueActivate(ca, pa.handles.items[2]);
    try std.testing.expectEqual(@as(usize, 1), (try model.takeIntents(ca)).len);
    try std.testing.expectEqual(@as(u8, 3), (try model.takeIntents(ca))[0].number);
    model.detachClient(ca);
    try std.testing.expectError(error.InvalidWorkspace, model.queueActivate(cb, stale));
}

test "update orders state and removals before one done" {
    var registry = ClientRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const owner = try registry.register(.mature_display);
    defer registry.unregister(owner);
    var model = Workspace.init(std.testing.allocator, &registry);
    defer model.deinit();
    const output: OutputLayout.Id = .{ .index = 1, .generation = 1 };
    var initial: Snapshot = .{ .output = output };
    initial.occupied[1] = true;
    try model.setSnapshot(initial);
    const client = try model.attachClient(owner);
    defer model.detachClient(client);
    var first = try model.prepareInitial(client);
    try model.commitPrepared(&first);
    first.deinit();

    var next: Snapshot = .{ .output = output, .active = 2 };
    next.occupied[1] = true;
    try model.setSnapshot(next);
    var update = try model.prepareUpdate(client);
    defer update.deinit();
    defer model.rollbackPrepared(&update);
    try std.testing.expect(update.events.items[0] == .state);
    try std.testing.expect(update.events.items[update.events.items.len - 1] == .done);
    try model.commitPrepared(&update);

    model.removeOutput(output);
    var removal = try model.prepareUpdate(client);
    defer removal.deinit();
    defer model.rollbackPrepared(&removal);
    try std.testing.expect(removal.events.items[0] == .workspace_leave);
    try std.testing.expect(removal.events.items[1] == .workspace_removed);
    try std.testing.expect(removal.events.items[removal.events.items.len - 3] == .output_leave);
    try std.testing.expect(removal.events.items[removal.events.items.len - 2] == .group_removed);
    try std.testing.expect(removal.events.items[removal.events.items.len - 1] == .done);
    try model.commitPrepared(&removal);
}

fn exercisePreparationRollback(allocator: std.mem.Allocator) !void {
    var registry = ClientRegistry.init(allocator);
    defer registry.deinit();
    const owner = try registry.register(.mature_display);
    defer registry.unregister(owner);
    var model = Workspace.init(allocator, &registry);
    defer model.deinit();
    try model.setSnapshot(.{ .output = .{ .index = 1, .generation = 1 } });
    const client = try model.attachClient(owner);
    defer model.detachClient(client);
    var prepared = model.prepareInitial(client) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), model.groups.len());
        try std.testing.expectEqual(@as(usize, 0), model.handles.len());
        return err;
    };
    model.rollbackPrepared(&prepared);
    prepared.deinit();
}

test "preparation OOM rolls back and isolates clients" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exercisePreparationRollback,
        .{},
    );
}

test "proposed activation preparation does not publish and lifecycle is idempotent" {
    var registry = ClientRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const owner = try registry.register(.mature_display);
    defer registry.unregister(owner);
    var model = Workspace.init(std.testing.allocator, &registry);
    defer model.deinit();
    const output: OutputLayout.Id = .{ .index = 8, .generation = 3 };
    try model.setSnapshot(.{ .output = output, .occupied = @splat(true) });
    const client = try model.attachClient(owner);
    defer model.detachClient(client);
    var initial = try model.prepareInitial(client);
    try model.commitPrepared(&initial);
    initial.deinit();

    var proposed = [_]Snapshot{model.snapshot(output).?};
    proposed[0].active = 4;
    var prepared = try model.prepareUpdateAgainst(client, &proposed);
    try std.testing.expectEqual(@as(u8, 1), model.snapshot(output).?.active);
    model.rollbackPrepared(&prepared);
    model.rollbackPrepared(&prepared);
    try model.commitPrepared(&prepared);
    try std.testing.expectEqual(@as(u8, 1), model.snapshot(output).?.active);
    prepared.deinit();
    prepared.deinit();
}

test "early child retirement tolerates updates and later readvertises fresh handles" {
    var registry = ClientRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const owner = try registry.register(.mature_display);
    defer registry.unregister(owner);
    var model = Workspace.init(std.testing.allocator, &registry);
    defer model.deinit();
    const output: OutputLayout.Id = .{ .index = 2, .generation = 9 };
    try model.setSnapshot(.{ .output = output });
    const client = try model.attachClient(owner);
    defer model.detachClient(client);
    var initial = try model.prepareInitial(client);
    const old_group = initial.groups.items[0];
    const old_handle = initial.handles.items[0];
    try model.commitPrepared(&initial);
    initial.deinit();

    model.removeOutput(output);
    var removal = try model.prepareUpdate(client);
    try model.commitPrepared(&removal);
    removal.deinit();
    try std.testing.expect(model.metadata(client, old_handle) == null);
    try std.testing.expect(model.groupOutput(client, old_group) == null);

    var readvertised: Snapshot = .{ .output = output, .active = 3 };
    readvertised.urgent[2] = true;
    try model.setSnapshot(readvertised);
    var update = try model.prepareUpdate(client);
    defer update.deinit();
    defer model.rollbackPrepared(&update);
    try std.testing.expect(!std.meta.eql(old_group, update.groups.items[0]));
    try std.testing.expect(!std.meta.eql(old_handle, update.handles.items[0]));
    try model.commitPrepared(&update);
}

test "released handles reject stale intents and are recreated with a fresh generation" {
    var registry = ClientRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const owner = try registry.register(.mature_display);
    defer registry.unregister(owner);
    var model = Workspace.init(std.testing.allocator, &registry);
    defer model.deinit();
    const output: OutputLayout.Id = .{ .index = 4, .generation = 7 };
    try model.setSnapshot(.{ .output = output });
    const client = try model.attachClient(owner);
    defer model.detachClient(client);
    var initial = try model.prepareInitial(client);
    const old_handle = initial.handles.items[0];
    try model.commitPrepared(&initial);
    initial.deinit();

    try model.queueActivate(client, old_handle);
    model.releaseHandle(client, old_handle);
    try std.testing.expectError(error.InvalidWorkspace, model.queueActivate(client, old_handle));
    try std.testing.expectEqual(@as(usize, 0), (try model.takeIntents(client)).len);

    var update = try model.prepareUpdate(client);
    defer update.deinit();
    defer model.rollbackPrepared(&update);
    try std.testing.expectEqual(@as(usize, 1), update.handles.items.len);
    try std.testing.expect(!std.meta.eql(old_handle, update.handles.items[0]));
    try model.commitPrepared(&update);
}

test "canonical removal cancels an intent queued through the removed handle" {
    var registry = ClientRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const owner = try registry.register(.mature_display);
    defer registry.unregister(owner);
    var model = Workspace.init(std.testing.allocator, &registry);
    defer model.deinit();
    const output: OutputLayout.Id = .{ .index = 7, .generation = 4 };
    var snapshot_value: Snapshot = .{ .output = output };
    snapshot_value.occupied[1] = true;
    try model.setSnapshot(snapshot_value);
    const client = try model.attachClient(owner);
    defer model.detachClient(client);
    var initial = try model.prepareInitial(client);
    const second = initial.handles.items[1];
    try model.commitPrepared(&initial);
    initial.deinit();
    try model.queueActivate(client, second);

    snapshot_value.occupied[1] = false;
    try model.setSnapshot(snapshot_value);
    var update = try model.prepareUpdate(client);
    try model.commitPrepared(&update);
    update.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try model.takeIntents(client)).len);
}

test "releasing another handle preserves the latest intent for its output" {
    var registry = ClientRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const owner = try registry.register(.mature_display);
    defer registry.unregister(owner);
    var model = Workspace.init(std.testing.allocator, &registry);
    defer model.deinit();
    const output: OutputLayout.Id = .{ .index = 6, .generation = 2 };
    try model.setSnapshot(.{ .output = output, .occupied = @splat(true) });
    const client = try model.attachClient(owner);
    defer model.detachClient(client);
    var initial = try model.prepareInitial(client);
    const first = initial.handles.items[0];
    const second = initial.handles.items[1];
    try model.commitPrepared(&initial);
    initial.deinit();

    try model.queueActivate(client, second);
    model.releaseHandle(client, first);
    const intents = try model.takeIntents(client);
    try std.testing.expectEqual(@as(usize, 1), intents.len);
    try std.testing.expectEqual(@as(u8, 2), intents[0].number);
    try std.testing.expect(std.meta.eql(second, intents[0].source));
}

test "rolling back an uncommitted handle preserves an older intent" {
    var registry = ClientRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const owner = try registry.register(.mature_display);
    defer registry.unregister(owner);
    var model = Workspace.init(std.testing.allocator, &registry);
    defer model.deinit();
    const output: OutputLayout.Id = .{ .index = 3, .generation = 8 };
    var snapshot_value: Snapshot = .{ .output = output };
    snapshot_value.occupied[1] = true;
    try model.setSnapshot(snapshot_value);
    const client = try model.attachClient(owner);
    defer model.detachClient(client);
    var initial = try model.prepareInitial(client);
    const second = initial.handles.items[1];
    try model.commitPrepared(&initial);
    initial.deinit();
    try model.queueActivate(client, second);

    var proposed = [_]Snapshot{model.snapshot(output).?};
    proposed[0].urgent[2] = true;
    var prepared = try model.prepareUpdateAgainst(client, &proposed);
    try std.testing.expectEqual(@as(usize, 1), prepared.handles.items.len);
    const uncommitted = prepared.handles.items[0];
    model.releaseHandle(client, uncommitted);
    model.rollbackPrepared(&prepared);
    prepared.deinit();

    const intents = try model.takeIntents(client);
    try std.testing.expectEqual(@as(usize, 1), intents.len);
    try std.testing.expect(std.meta.eql(second, intents[0].source));
}

test "one client can abort proposed update while another commits" {
    var registry = ClientRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const first_owner = try registry.register(.mature_display);
    defer registry.unregister(first_owner);
    const second_owner = try registry.register(.mature_display);
    defer registry.unregister(second_owner);
    var model = Workspace.init(std.testing.allocator, &registry);
    defer model.deinit();
    const output: OutputLayout.Id = .{ .index = 5, .generation = 1 };
    try model.setSnapshot(.{ .output = output, .occupied = @splat(true) });
    const first = try model.attachClient(first_owner);
    defer model.detachClient(first);
    const second = try model.attachClient(second_owner);
    defer model.detachClient(second);
    var first_initial = try model.prepareInitial(first);
    try model.commitPrepared(&first_initial);
    first_initial.deinit();
    var second_initial = try model.prepareInitial(second);
    try model.commitPrepared(&second_initial);
    second_initial.deinit();

    var proposed = [_]Snapshot{model.snapshot(output).?};
    proposed[0].active = 7;
    var first_update = try model.prepareUpdateAgainst(first, &proposed);
    defer first_update.deinit();
    var second_update = try model.prepareUpdateAgainst(second, &proposed);
    defer second_update.deinit();
    model.rollbackPrepared(&first_update);
    try model.commitPrepared(&second_update);
    try std.testing.expectEqual(@as(u8, 1), model.snapshot(output).?.active);
}
