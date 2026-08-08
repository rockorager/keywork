//! Scanner-resource frontend for the neutral ext-workspace-v1 projection.

const WayringWorkspace = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayring = @import("wayring");
const Neutral = @import("../Workspace.zig");
const WayringClients = @import("WayringClients.zig");
const WayringOutput = @import("WayringOutput.zig");

const server = wayring.server;
const wire = wayring.wire;

const Manager = struct {
    binding: *Binding,
    generation: u64,
    resource: protocol.ext_workspace_manager_v1.Resource,
};

const Group = struct {
    binding: *Binding,
    id: Neutral.GroupId,
    generation: u64,
    resource: protocol.ext_workspace_group_handle_v1.Resource,
    removed: bool = false,
};

const Workspace = struct {
    binding: *Binding,
    id: Neutral.HandleId,
    generation: u64,
    resource: protocol.ext_workspace_handle_v1.Resource,
    removed: bool = false,
};

const Binding = struct {
    owner: *WayringWorkspace,
    client: *server.Client,
    neutral_client: Neutral.ClientId,
    manager: ?*Manager,
    groups: std.ArrayList(*Group) = .empty,
    workspaces: std.ArrayList(*Workspace) = .empty,

    fn group(self: *Binding, id: Neutral.GroupId) ?*Group {
        for (self.groups.items) |value| if (std.meta.eql(value.id, id)) return value;
        return null;
    }

    fn workspace(self: *Binding, id: Neutral.HandleId) ?*Workspace {
        for (self.workspaces.items) |value| if (std.meta.eql(value.id, id)) return value;
        return null;
    }
};

const Prepared = struct {
    binding: *Binding,
    neutral: Neutral.Prepared,
    batch: ?wire.PreparedBatch,
    events: []server.Client.PreparedEvent,
    values: []wire.Value,
    coordinates: []u32,
    names: [][3:0]u8,

    fn abort(self: *Prepared) void {
        if (!self.neutral.isPending()) return;
        if (self.batch) |batch| self.binding.client.cancelPreparedEvents(batch);
        self.batch = null;
        self.binding.owner.discardPreparedResources(self.binding, &self.neutral);
        self.binding.owner.core.rollbackPrepared(&self.neutral);
    }

    fn deinit(self: *Prepared) void {
        const allocator = self.binding.owner.allocator;
        allocator.free(self.events);
        allocator.free(self.values);
        allocator.free(self.coordinates);
        allocator.free(self.names);
        self.neutral.deinit();
    }
};

allocator: std.mem.Allocator,
protocol_server: *server.Server,
clients: *WayringClients,
outputs: *WayringOutput,
core: *Neutral,
authorized_uid: std.os.linux.uid_t,
global: ?*const server.Server.Global = null,
bindings: std.ArrayList(*Binding) = .empty,
pending: std.ArrayList(Prepared) = .empty,
next_generation: ?u64 = 1,

pub fn init(
    self: *WayringWorkspace,
    allocator: std.mem.Allocator,
    protocol_server: *server.Server,
    clients: *WayringClients,
    outputs: *WayringOutput,
    core: *Neutral,
    authorized_uid: std.os.linux.uid_t,
) void {
    self.* = .{
        .allocator = allocator,
        .protocol_server = protocol_server,
        .clients = clients,
        .outputs = outputs,
        .core = core,
        .authorized_uid = authorized_uid,
    };
    outputs.setBindListener(.{ .context = self, .bound = outputBound });
    core.registerFrontend(.{
        .context = self,
        .prepare = secondaryPrepare,
        .commit = secondaryCommit,
        .abort = secondaryAbort,
        .reconcile = secondaryReconcile,
    });
}

pub fn publish(self: *WayringWorkspace) !void {
    std.debug.assert(self.global == null);
    self.global = try self.protocol_server.addGlobalWithOptions(
        protocol.ext_workspace_manager_v1,
        1,
        WayringWorkspace,
        self,
        bind,
        .{ .visibility = .restricted },
    );
}

pub fn unpublish(self: *WayringWorkspace) void {
    self.protocol_server.removeGlobal(self.global.?) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}

pub fn deinit(self: *WayringWorkspace) void {
    std.debug.assert(self.global == null and self.bindings.items.len == 0 and self.pending.items.len == 0);
    self.core.unregisterFrontend(self);
    self.outputs.clearBindListener(self);
    self.pending.deinit(self.allocator);
    self.bindings.deinit(self.allocator);
    self.* = undefined;
}

pub fn globalFilter(self: *const WayringWorkspace, client: *const server.Client, global: *const server.Server.Global) bool {
    return global.visibility() != .restricted or client.isAuthorizedDirectPeer(self.authorized_uid);
}

fn generation(self: *WayringWorkspace) !u64 {
    const result = self.next_generation orelse return error.GenerationExhausted;
    self.next_generation = if (result == std.math.maxInt(u64)) null else result + 1;
    return result;
}

fn bind(client: *server.Client, id: u32, version: u32, self: *WayringWorkspace) !void {
    if (version != 1) return error.InvalidVersion;
    if (!client.isAuthorizedDirectPeer(self.authorized_uid)) return error.Unauthorized;
    const owner = self.clients.id(client) orelse return error.InvalidClient;
    try self.bindings.ensureUnusedCapacity(self.allocator, 1);
    try self.pending.ensureTotalCapacity(self.allocator, self.bindings.items.len + 1);
    const binding = try self.allocator.create(Binding);
    errdefer self.allocator.destroy(binding);
    binding.* = .{
        .owner = self,
        .client = client,
        .neutral_client = try self.core.attachClient(owner),
        .manager = null,
    };
    errdefer self.core.detachClient(binding.neutral_client);
    errdefer {
        binding.groups.deinit(self.allocator);
        binding.workspaces.deinit(self.allocator);
    }
    const manager = try self.allocator.create(Manager);
    errdefer self.allocator.destroy(manager);
    var manager_owned = true;
    manager.* = .{
        .binding = binding,
        .generation = try self.generation(),
        .resource = .init(self.allocator, id, 1, .client, client.ownerHooks()),
    };
    errdefer if (manager_owned) {
        manager.resource.destroy();
        manager.resource.deinit();
    };
    try manager.resource.setHandler(Manager, manager, managerRequest, null);
    try client.materialize(&manager.resource.runtime);
    binding.manager = manager;
    self.bindings.appendAssumeCapacity(binding);
    errdefer {
        _ = self.bindings.pop();
        binding.manager = null;
        manager.resource.destroy();
        manager.resource.deinit();
        self.allocator.destroy(manager);
    }
    manager_owned = false;
    var prepared = try prepareBinding(binding, self.core.snapshotSlice(), true);
    defer prepared.deinit();
    defer prepared.abort();
    commitPrepared(&prepared);
}

fn managerRequest(resource: *protocol.ext_workspace_manager_v1.Resource, request: protocol.ext_workspace_manager_v1.Request, manager: *Manager) !void {
    const binding = manager.binding;
    switch (request) {
        .commit => {
            if (!binding.client.isAuthorizedDirectPeer(binding.owner.authorized_uid)) return error.Unauthorized;
            const intents = binding.owner.core.takeIntents(binding.neutral_client) catch return;
            defer binding.owner.core.clearIntents(binding.neutral_client);
            if (intents.len == 0) return;
            binding.owner.core.activate(intents, .{
                .frontend = binding.owner,
                .context = binding,
                .no_memory = requesterNoMemory,
            });
        },
        .stop => {
            if (!binding.client.isAuthorizedDirectPeer(binding.owner.authorized_uid)) return error.Unauthorized;
            protocol.ext_workspace_manager_v1.@"send:finished"(resource) catch |err|
                return eventFailure(binding, err, "queueing workspace finished");
            binding.owner.destroyManager(manager);
        },
    }
}

fn requesterNoMemory(context: *anyopaque) void {
    const binding: *Binding = @ptrCast(@alignCast(context));
    if (binding.manager) |manager|
        binding.client.postOutOfMemory(&manager.resource.runtime, "preparing workspace activation");
}

fn groupRequest(_: *protocol.ext_workspace_group_handle_v1.Resource, request: protocol.ext_workspace_group_handle_v1.Request, group: *Group) !void {
    if (!group.binding.client.isAuthorizedDirectPeer(group.binding.owner.authorized_uid)) return error.Unauthorized;
    switch (request) {
        .create_workspace => {}, // Not advertised; the protocol requires ignore.
        .destroy => group.binding.owner.destroyGroup(group),
    }
}

fn workspaceRequest(_: *protocol.ext_workspace_handle_v1.Resource, request: protocol.ext_workspace_handle_v1.Request, workspace: *Workspace) !void {
    if (!workspace.binding.client.isAuthorizedDirectPeer(workspace.binding.owner.authorized_uid)) return error.Unauthorized;
    switch (request) {
        .destroy => workspace.binding.owner.destroyWorkspace(workspace, true),
        .activate => {
            const binding = workspace.binding;
            if (binding.manager == null or workspace.removed) return;
            binding.owner.core.queueActivate(binding.neutral_client, workspace.id) catch |err| switch (err) {
                error.OutOfMemory => binding.client.postOutOfMemory(&workspace.resource.runtime, "queueing workspace activation"),
                else => binding.client.postImplementationError(&workspace.resource.runtime, "invalid, stale, or foreign workspace activation"),
            };
        },
        .deactivate, .assign, .remove => {}, // Activation is the sole capability.
    }
}

fn prepareBinding(binding: *Binding, snapshots: []const Neutral.Snapshot, initial: bool) !Prepared {
    const self = binding.owner;
    if (binding.manager == null) return error.InvalidClient;
    var neutral = if (initial)
        try self.core.prepareInitial(binding.neutral_client)
    else
        try self.core.prepareUpdateAgainst(binding.neutral_client, snapshots);
    errdefer neutral.deinit();
    errdefer self.core.rollbackPrepared(&neutral);
    try binding.groups.ensureUnusedCapacity(self.allocator, neutral.groups.items.len);
    try binding.workspaces.ensureUnusedCapacity(self.allocator, neutral.handles.items.len);
    errdefer self.discardPreparedResources(binding, &neutral);
    for (neutral.groups.items) |id| try self.allocateGroup(binding, id);
    for (neutral.handles.items) |id| try self.allocateWorkspace(binding, id);

    var event_count: usize = 0;
    var value_count: usize = 0;
    var coordinate_count: usize = 0;
    var name_count: usize = 0;
    for (neutral.events.items) |event| switch (event) {
        .group => {
            event_count += 2;
            value_count += 2;
        },
        .output_enter => |value| {
            const count = self.outputs.clientResourceCount(value.output, binding.client);
            event_count += count;
            value_count += count;
        },
        .output_leave => |value| {
            const count = self.outputs.clientResourceCount(value.output, binding.client);
            event_count += count;
            value_count += count;
        },
        .name => {
            event_count += 1;
            value_count += 1;
            name_count += 1;
        },
        .coordinates => {
            event_count += 1;
            value_count += 1;
            coordinate_count += 1;
        },
        .workspace, .state, .capabilities, .workspace_enter, .workspace_leave => {
            event_count += 1;
            value_count += 1;
        },
        .workspace_removed, .group_removed, .done => event_count += 1,
    };
    const events = try self.allocator.alloc(server.Client.PreparedEvent, event_count);
    errdefer self.allocator.free(events);
    const values = try self.allocator.alloc(wire.Value, value_count);
    errdefer self.allocator.free(values);
    const coordinates = try self.allocator.alloc(u32, coordinate_count);
    errdefer self.allocator.free(coordinates);
    const names = try self.allocator.alloc([3:0]u8, name_count);
    errdefer self.allocator.free(names);
    var builder: EventBuilder = .{
        .binding = binding,
        .events = events,
        .values = values,
        .coordinates = coordinates,
        .names = names,
    };
    for (neutral.events.items) |event| builder.addNeutral(event);
    std.debug.assert(builder.event_index == events.len and builder.value_index == values.len and
        builder.coordinate_index == coordinates.len and builder.name_index == names.len);
    const maximum_bytes = std.math.mul(usize, event_count, 32) catch return error.OutOfMemory;
    const batch = if (event_count == 0) null else try binding.client.prepareEvents(maximum_bytes);
    return .{
        .binding = binding,
        .neutral = neutral,
        .batch = batch,
        .events = events,
        .values = values,
        .coordinates = coordinates,
        .names = names,
    };
}

const EventBuilder = struct {
    binding: *Binding,
    events: []server.Client.PreparedEvent,
    values: []wire.Value,
    coordinates: []u32,
    names: [][3:0]u8,
    event_index: usize = 0,
    value_index: usize = 0,
    coordinate_index: usize = 0,
    name_index: usize = 0,

    fn add(self: *EventBuilder, resource: *server.Resource, opcode: u16, descriptor: *const wire.MessageDescriptor, value: ?wire.Value) void {
        const event_values = if (value) |item| values: {
            self.values[self.value_index] = item;
            const result = self.values[self.value_index .. self.value_index + 1];
            self.value_index += 1;
            break :values result;
        } else &.{};
        self.events[self.event_index] = .{ .resource = resource, .opcode = opcode, .descriptor = descriptor, .values = event_values };
        self.event_index += 1;
    }

    fn addNeutral(self: *EventBuilder, event: Neutral.Event) void {
        const binding = self.binding;
        const manager = binding.manager orelse return;
        switch (event) {
            .group => |id| if (binding.group(id)) |group| {
                self.add(&manager.resource.runtime, 0, &protocol.ext_workspace_manager_v1.event_messages[0], .{ .new_id = .{ .typed = group.resource.id() } });
                self.add(&group.resource.runtime, 0, &protocol.ext_workspace_group_handle_v1.event_messages[0], .{ .uint = 0 });
            },
            .output_enter => |value| if (binding.group(value.group)) |group| {
                var output_builder: OutputBuilder = .{ .builder = self, .group = group, .opcode = 1 };
                binding.owner.outputs.forEachClientResource(value.output, binding.client, &output_builder, OutputBuilder.visit);
            },
            .workspace => |id| if (binding.workspace(id)) |workspace|
                self.add(&manager.resource.runtime, 1, &protocol.ext_workspace_manager_v1.event_messages[1], .{ .new_id = .{ .typed = workspace.resource.id() } }),
            .name => |id| if (binding.workspace(id)) |workspace| if (binding.owner.core.metadata(binding.neutral_client, id)) |metadata| {
                self.names[self.name_index] = metadata.name;
                const name = std.mem.sliceTo(&self.names[self.name_index], 0);
                self.name_index += 1;
                self.add(&workspace.resource.runtime, 1, &protocol.ext_workspace_handle_v1.event_messages[1], .{ .string = name });
            },
            .coordinates => |id| if (binding.workspace(id)) |workspace| if (binding.owner.core.metadata(binding.neutral_client, id)) |metadata| {
                self.coordinates[self.coordinate_index] = metadata.coordinate;
                const bytes = std.mem.asBytes(&self.coordinates[self.coordinate_index]);
                self.coordinate_index += 1;
                self.add(&workspace.resource.runtime, 2, &protocol.ext_workspace_handle_v1.event_messages[2], .{ .array = bytes });
            },
            .state => |value| if (binding.workspace(value.workspace)) |workspace| {
                var state: u32 = 0;
                if (value.value.active) state |= @intCast(protocol.ext_workspace_handle_v1.state.active);
                if (value.value.urgent) state |= @intCast(protocol.ext_workspace_handle_v1.state.urgent);
                self.add(&workspace.resource.runtime, 3, &protocol.ext_workspace_handle_v1.event_messages[3], .{ .uint = state });
            },
            .capabilities => |id| if (binding.workspace(id)) |workspace|
                self.add(&workspace.resource.runtime, 4, &protocol.ext_workspace_handle_v1.event_messages[4], .{ .uint = @intCast(protocol.ext_workspace_handle_v1.workspace_capabilities.activate) }),
            .workspace_enter => |value| if (binding.group(value.group)) |group| if (binding.workspace(value.workspace)) |workspace|
                self.add(&group.resource.runtime, 3, &protocol.ext_workspace_group_handle_v1.event_messages[3], .{ .object = workspace.resource.id() }),
            .workspace_leave => |value| if (binding.group(value.group)) |group| if (binding.workspace(value.workspace)) |workspace|
                self.add(&group.resource.runtime, 4, &protocol.ext_workspace_group_handle_v1.event_messages[4], .{ .object = workspace.resource.id() }),
            .workspace_removed => |id| if (binding.workspace(id)) |workspace| {
                self.add(&workspace.resource.runtime, 5, &protocol.ext_workspace_handle_v1.event_messages[5], null);
            },
            .output_leave => |value| if (binding.group(value.group)) |group| {
                var output_builder: OutputBuilder = .{ .builder = self, .group = group, .opcode = 2 };
                binding.owner.outputs.forEachClientResource(value.output, binding.client, &output_builder, OutputBuilder.visit);
            },
            .group_removed => |id| if (binding.group(id)) |group| {
                self.add(&group.resource.runtime, 5, &protocol.ext_workspace_group_handle_v1.event_messages[5], null);
            },
            .done => self.add(&manager.resource.runtime, 2, &protocol.ext_workspace_manager_v1.event_messages[2], null),
        }
    }
};

const OutputBuilder = struct {
    builder: *EventBuilder,
    group: *Group,
    opcode: u16,

    fn visit(context: *anyopaque, output: *protocol.wl_output.Resource) void {
        const self: *OutputBuilder = @ptrCast(@alignCast(context));
        self.builder.add(
            &self.group.resource.runtime,
            self.opcode,
            &protocol.ext_workspace_group_handle_v1.event_messages[self.opcode],
            .{ .object = output.id() },
        );
    }
};

fn commitPrepared(prepared: *Prepared) void {
    if (prepared.batch) |batch| {
        prepared.binding.client.emitPreparedEvents(batch, prepared.events) catch unreachable;
        prepared.batch = null;
    }
    for (prepared.neutral.removed_handles.items) |id| {
        if (prepared.binding.workspace(id)) |workspace| workspace.removed = true;
    }
    for (prepared.neutral.removed_groups.items) |id| {
        if (prepared.binding.group(id)) |group| group.removed = true;
    }
    prepared.binding.owner.core.commitPrepared(&prepared.neutral) catch unreachable;
}

fn abortPendingClient(self: *WayringWorkspace, client: *server.Client) void {
    var index = self.pending.items.len;
    while (index > 0) {
        index -= 1;
        if (self.pending.items[index].binding.client != client) continue;
        var prepared = self.pending.swapRemove(index);
        prepared.abort();
        prepared.deinit();
    }
}

fn secondaryPrepare(context: *anyopaque, snapshots: []const Neutral.Snapshot, requester: Neutral.Requester) bool {
    const self: *WayringWorkspace = @ptrCast(@alignCast(context));
    return prepareTransactions(self, snapshots, requester);
}

fn prepareTransactions(self: *WayringWorkspace, snapshots: []const Neutral.Snapshot, requester: ?Neutral.Requester) bool {
    std.debug.assert(self.pending.items.len == 0 and self.pending.capacity >= self.bindings.items.len);
    for (self.bindings.items) |binding| {
        if (binding.manager == null or binding.client.fatal() != null) continue;
        const transaction = prepareBinding(binding, snapshots, false) catch |err| {
            if (binding.manager) |manager| switch (err) {
                error.OutOfMemory => binding.client.postOutOfMemory(&manager.resource.runtime, "preparing workspace transaction"),
                error.InvalidClient => {},
                else => binding.client.postImplementationError(&manager.resource.runtime, "preparing workspace transaction"),
            };
            self.abortPendingClient(binding.client);
            if (requester) |origin| if (origin.frontend == @as(*anyopaque, @ptrCast(self)) and
                requesterClient(origin) == binding.client)
            {
                secondaryAbort(self);
                return false;
            };
            continue;
        };
        self.pending.appendAssumeCapacity(transaction);
    }
    return true;
}

fn requesterClient(requester: Neutral.Requester) *server.Client {
    const binding: *Binding = @ptrCast(@alignCast(requester.context));
    return binding.client;
}

fn secondaryCommit(context: *anyopaque) void {
    const self: *WayringWorkspace = @ptrCast(@alignCast(context));
    for (self.pending.items) |*prepared| {
        commitPrepared(prepared);
        prepared.deinit();
    }
    self.pending.clearRetainingCapacity();
}

fn secondaryAbort(context: *anyopaque) void {
    const self: *WayringWorkspace = @ptrCast(@alignCast(context));
    for (self.pending.items) |*prepared| {
        prepared.abort();
        prepared.deinit();
    }
    self.pending.clearRetainingCapacity();
}

fn secondaryReconcile(context: *anyopaque) void {
    const self: *WayringWorkspace = @ptrCast(@alignCast(context));
    if (!prepareTransactions(self, self.core.snapshotSlice(), null)) return;
    secondaryCommit(self);
}

fn allocateGroup(self: *WayringWorkspace, binding: *Binding, id: Neutral.GroupId) !void {
    const object_id = try binding.client.reserveServerId();
    var materialized = false;
    errdefer if (!materialized) binding.client.rollbackServerId(object_id);
    const group = try self.allocator.create(Group);
    errdefer self.allocator.destroy(group);
    group.* = .{
        .binding = binding,
        .id = id,
        .generation = try self.generation(),
        .resource = .init(self.allocator, object_id, 1, .server, binding.client.ownerHooks()),
    };
    errdefer {
        group.resource.destroy();
        group.resource.deinit();
    }
    try group.resource.setHandler(Group, group, groupRequest, null);
    try binding.client.materializeServer(&group.resource.runtime);
    materialized = true;
    binding.groups.appendAssumeCapacity(group);
}

fn allocateWorkspace(self: *WayringWorkspace, binding: *Binding, id: Neutral.HandleId) !void {
    const object_id = try binding.client.reserveServerId();
    var materialized = false;
    errdefer if (!materialized) binding.client.rollbackServerId(object_id);
    const workspace = try self.allocator.create(Workspace);
    errdefer self.allocator.destroy(workspace);
    workspace.* = .{
        .binding = binding,
        .id = id,
        .generation = try self.generation(),
        .resource = .init(self.allocator, object_id, 1, .server, binding.client.ownerHooks()),
    };
    errdefer {
        workspace.resource.destroy();
        workspace.resource.deinit();
    }
    try workspace.resource.setHandler(Workspace, workspace, workspaceRequest, null);
    try binding.client.materializeServer(&workspace.resource.runtime);
    materialized = true;
    binding.workspaces.appendAssumeCapacity(workspace);
}

fn discardPreparedResources(self: *WayringWorkspace, binding: *Binding, prepared: *const Neutral.Prepared) void {
    var index = prepared.handles.items.len;
    while (index > 0) {
        index -= 1;
        if (binding.workspace(prepared.handles.items[index])) |workspace| self.destroyWorkspace(workspace, false);
    }
    index = prepared.groups.items.len;
    while (index > 0) {
        index -= 1;
        if (binding.group(prepared.groups.items[index])) |group| self.destroyGroup(group);
    }
}

fn destroyWorkspace(self: *WayringWorkspace, workspace: *Workspace, release_neutral: bool) void {
    const binding = workspace.binding;
    if (release_neutral) self.core.releaseHandle(binding.neutral_client, workspace.id);
    remove(Workspace, &binding.workspaces, workspace);
    workspace.resource.destroy();
    workspace.resource.deinit();
    self.allocator.destroy(workspace);
    self.destroyBindingIfUnused(binding);
}

fn destroyGroup(self: *WayringWorkspace, group: *Group) void {
    const binding = group.binding;
    remove(Group, &binding.groups, group);
    group.resource.destroy();
    group.resource.deinit();
    self.allocator.destroy(group);
    self.destroyBindingIfUnused(binding);
}

fn destroyManager(self: *WayringWorkspace, manager: *Manager) void {
    const binding = manager.binding;
    if (binding.manager != manager) return;
    binding.manager = null;
    self.core.clearIntents(binding.neutral_client);
    manager.resource.destroy();
    manager.resource.deinit();
    self.allocator.destroy(manager);
    self.destroyBindingIfUnused(binding);
}

fn destroyBindingIfUnused(self: *WayringWorkspace, binding: *Binding) void {
    if (binding.manager != null or binding.groups.items.len != 0 or binding.workspaces.items.len != 0) return;
    remove(Binding, &self.bindings, binding);
    self.core.detachClient(binding.neutral_client);
    binding.groups.deinit(self.allocator);
    binding.workspaces.deinit(self.allocator);
    self.allocator.destroy(binding);
}

pub fn destroyClientResources(self: *WayringWorkspace, client: *server.Client) void {
    self.abortPendingClient(client);
    var binding_index = self.bindings.items.len;
    while (binding_index > 0) {
        binding_index -= 1;
        const binding = self.bindings.items[binding_index];
        if (binding.client != client) continue;
        // A stopped manager leaves its children alive. The final workspace may
        // reclaim a group-less binding, so capture all later teardown state
        // before destroying workspaces. Existing groups otherwise pin it.
        const manager = binding.manager;
        var group_index = binding.groups.items.len;
        var index = binding.workspaces.items.len;
        while (index > 0) {
            index -= 1;
            self.destroyWorkspace(binding.workspaces.items[index], true);
        }
        while (group_index > 0) {
            group_index -= 1;
            self.destroyGroup(binding.groups.items[group_index]);
        }
        if (manager) |value| self.destroyManager(value);
    }
}

fn outputBound(context: *anyopaque, output_id: @import("output_layout.zig").Id, client: *server.Client, output: *protocol.wl_output.Resource) void {
    const self: *WayringWorkspace = @ptrCast(@alignCast(context));
    for (self.bindings.items) |binding| {
        const manager = binding.manager orelse continue;
        if (binding.client != client) continue;
        for (binding.groups.items) |group| {
            const group_output = self.core.groupOutput(binding.neutral_client, group.id) orelse continue;
            if (group.removed or !std.meta.eql(group_output, output_id)) continue;
            const values = [_]wire.Value{.{ .object = output.id() }};
            const events = [_]server.Client.PreparedEvent{
                .{ .resource = &group.resource.runtime, .opcode = 1, .descriptor = &protocol.ext_workspace_group_handle_v1.event_messages[1], .values = &values },
                .{ .resource = &manager.resource.runtime, .opcode = 2, .descriptor = &protocol.ext_workspace_manager_v1.event_messages[2], .values = &.{} },
            };
            const batch = client.prepareEvents(20) catch |err| {
                eventFailure(binding, err, "preparing workspace output identity") catch {};
                return;
            };
            client.emitPreparedEvents(batch, &events) catch |err| {
                client.cancelPreparedEvents(batch);
                eventFailure(binding, err, "publishing workspace output identity") catch {};
                return;
            };
        }
    }
}

fn eventFailure(binding: *Binding, err: anyerror, message: []const u8) error{OutOfMemory} {
    const resource = if (binding.manager) |manager| &manager.resource.runtime else return error.OutOfMemory;
    switch (err) {
        error.OutOfMemory, error.WriteFailed => binding.client.postOutOfMemory(resource, message),
        error.OutputSealed, error.ClientFatal => {},
        else => binding.client.postImplementationError(resource, message),
    }
    return error.OutOfMemory;
}

fn remove(comptime T: type, list: *std.ArrayList(*T), value: *T) void {
    for (list.items, 0..) |candidate, index| if (candidate == value) {
        _ = list.swapRemove(index);
        return;
    };
    unreachable;
}

test "scanner workspace v1 descriptors and activation-only capabilities are pinned" {
    try std.testing.expectEqual(@as(u32, 1), protocol.ext_workspace_manager_v1.interface.version);
    try std.testing.expectEqual(@as(usize, 2), protocol.ext_workspace_manager_v1.request_messages.len);
    try std.testing.expectEqual(@as(usize, 4), protocol.ext_workspace_manager_v1.event_messages.len);
    try std.testing.expectEqual(@as(usize, 2), protocol.ext_workspace_group_handle_v1.request_messages.len);
    try std.testing.expectEqual(@as(usize, 6), protocol.ext_workspace_group_handle_v1.event_messages.len);
    try std.testing.expectEqual(@as(usize, 5), protocol.ext_workspace_handle_v1.request_messages.len);
    try std.testing.expectEqual(@as(usize, 6), protocol.ext_workspace_handle_v1.event_messages.len);
    try std.testing.expect(protocol.ext_workspace_manager_v1.event_messages[3].destructor);
    try std.testing.expect(protocol.ext_workspace_group_handle_v1.request_messages[1].destructor);
    try std.testing.expect(protocol.ext_workspace_handle_v1.request_messages[0].destructor);
    try std.testing.expectEqual(@as(i64, 1), protocol.ext_workspace_group_handle_v1.group_capabilities.create_workspace);
    try std.testing.expectEqual(@as(i64, 1), protocol.ext_workspace_handle_v1.state.active);
    try std.testing.expectEqual(@as(i64, 2), protocol.ext_workspace_handle_v1.state.urgent);
    try std.testing.expectEqual(@as(i64, 4), protocol.ext_workspace_handle_v1.state.hidden);
    try std.testing.expectEqual(@as(i64, 1), protocol.ext_workspace_handle_v1.workspace_capabilities.activate);
    try std.testing.expectEqual(@as(i64, 2), protocol.ext_workspace_handle_v1.workspace_capabilities.deactivate);
    try std.testing.expectEqual(@as(i64, 4), protocol.ext_workspace_handle_v1.workspace_capabilities.remove);
    try std.testing.expectEqual(@as(i64, 8), protocol.ext_workspace_handle_v1.workspace_capabilities.assign);
}

test "resource generations never wrap" {
    var adapter: WayringWorkspace = undefined;
    adapter.next_generation = std.math.maxInt(u64);
    try std.testing.expectEqual(std.math.maxInt(u64), try adapter.generation());
    try std.testing.expectError(error.GenerationExhausted, adapter.generation());
}
