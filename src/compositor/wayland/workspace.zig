//! Mature libwayland adapter for the neutral workspace projection.

const Self = @This();
const std = @import("std");
const wayland = @import("wayland");
const Neutral = @import("../Workspace.zig");
const MatureClients = @import("MatureClients.zig");
const Output = @import("output.zig");
const OutputLayout = @import("output_layout.zig");
const SecurityContext = @import("security_context.zig");
const wl = wayland.server.wl;
const ext = wayland.server.ext;

allocator: std.mem.Allocator,
global: *wl.Global,
security_context: *SecurityContext,
outputs: *OutputLayout,
clients: *MatureClients,
model: *Neutral,
bindings: std.ArrayList(*Binding),
activation_listener: ?ActivationListener,

pub const ActivationListener = struct {
    context: *anyopaque,
    prepare: *const fn (*anyopaque, []const Neutral.Intent) ?bool,
    finish: *const fn (*anyopaque) void,
};

const Binding = struct {
    owner: *Self,
    manager: ?*ext.WorkspaceManagerV1,
    client: Neutral.ClientId,
    groups: std.ArrayList(*GroupResource) = .empty,
    workspaces: std.ArrayList(*WorkspaceResource) = .empty,

    const Prepared = struct {
        binding: *Binding,
        neutral: Neutral.Prepared,

        fn abort(self: *Prepared) void {
            if (!self.neutral.isPending()) return;
            self.binding.discardPreparedResources(&self.neutral);
            self.binding.owner.model.rollbackPrepared(&self.neutral);
        }

        fn deinit(self: *Prepared) void {
            self.neutral.deinit();
        }
    };

    fn create(owner: *Self, raw_client: *wl.Client, version: u32, id: u32) !void {
        const manager = try ext.WorkspaceManagerV1.create(raw_client, version, id);
        errdefer manager.destroy();
        const identity = owner.clients.id(raw_client) orelse return error.InvalidClient;
        const neutral_client = try owner.model.attachClient(identity);
        errdefer owner.model.detachClient(neutral_client);
        const self = try owner.allocator.create(Binding);
        errdefer owner.allocator.destroy(self);
        self.* = .{ .owner = owner, .manager = manager, .client = neutral_client };
        errdefer self.deinitLists();
        try owner.bindings.append(owner.allocator, self);
        errdefer _ = owner.bindings.pop();
        var prepared = try self.prepareInitial();
        defer prepared.deinit();
        defer prepared.abort();
        self.finalize(&prepared);
        // Install the manager callback only after initial publication succeeds.
        // Before this point the errdefers may reclaim `self` before destroying
        // the manager resource, so a callback would retain a dead context.
        manager.setHandler(*Binding, handleManagerRequest, handleManagerDestroy, self);
    }

    fn reconcile(self: *Binding) !void {
        var prepared = try self.prepare(self.owner.model.snapshotSlice());
        defer prepared.deinit();
        defer prepared.abort();
        self.finalize(&prepared);
    }

    fn prepare(self: *Binding, snapshots: []const Neutral.Snapshot) !Prepared {
        const manager = self.manager orelse return error.InvalidClient;
        var neutral = try self.owner.model.prepareUpdateAgainst(self.client, snapshots);
        errdefer neutral.deinit();
        errdefer self.owner.model.rollbackPrepared(&neutral);
        errdefer self.discardPreparedResources(&neutral);

        // Allocate every wl_resource and adapter node before emitting any event.
        for (neutral.groups.items) |id| try self.allocateGroup(manager, id);
        for (neutral.handles.items) |id| try self.allocateWorkspace(manager, id);
        return .{ .binding = self, .neutral = neutral };
    }

    fn prepareInitial(self: *Binding) !Prepared {
        const manager = self.manager orelse return error.InvalidClient;
        var neutral = try self.owner.model.prepareInitial(self.client);
        errdefer neutral.deinit();
        errdefer self.owner.model.rollbackPrepared(&neutral);
        errdefer self.discardPreparedResources(&neutral);
        for (neutral.groups.items) |id| try self.allocateGroup(manager, id);
        for (neutral.handles.items) |id| try self.allocateWorkspace(manager, id);
        return .{ .binding = self, .neutral = neutral };
    }

    /// Emits and commits a fully prepared transaction without allocating.
    fn finalize(self: *Binding, prepared: *Prepared) void {
        const manager = self.manager orelse {
            prepared.abort();
            return;
        };
        for (prepared.neutral.events.items) |event| switch (event) {
            .group => |id| {
                const node = self.group(id) orelse continue;
                const resource = node.resource orelse continue;
                manager.sendWorkspaceGroup(resource);
                resource.sendCapabilities(.{});
            },
            .output_enter => |value| if (self.group(value.group)) |group_node| {
                const group_resource = group_node.resource orelse continue;
                if (self.owner.outputs.get(value.output)) |output| for (output.boundResources()) |resource| {
                    if (resource.getClient() == manager.getClient()) group_resource.sendOutputEnter(resource);
                };
            },
            .workspace => |id| if (self.workspace(id)) |node| manager.sendWorkspace(node.resource),
            .name => |id| {
                const metadata = self.owner.model.metadata(self.client, id) orelse continue;
                const node = self.workspace(id) orelse continue;
                node.resource.sendName(@ptrCast(&metadata.name));
            },
            .coordinates => |id| {
                var coordinate = (self.owner.model.metadata(self.client, id) orelse continue).coordinate;
                var array: wl.Array = .{ .size = @sizeOf(u32), .alloc = @sizeOf(u32), .data = @ptrCast(&coordinate) };
                const node = self.workspace(id) orelse continue;
                node.resource.sendCoordinates(&array);
            },
            .state => |value| if (self.workspace(value.workspace)) |node| node.resource.sendState(.{ .active = value.value.active, .urgent = value.value.urgent }),
            .capabilities => |id| if (self.workspace(id)) |node| node.resource.sendCapabilities(.{ .activate = true }),
            .workspace_enter => |value| if (self.group(value.group)) |group_node| if (group_node.resource) |group_resource| if (self.workspace(value.workspace)) |workspace_node| group_resource.sendWorkspaceEnter(workspace_node.resource),
            .workspace_leave => |value| if (self.group(value.group)) |group_node| if (group_node.resource) |resource| if (self.workspace(value.workspace)) |workspace_node| resource.sendWorkspaceLeave(workspace_node.resource),
            .workspace_removed => |id| if (self.workspace(id)) |workspace_node| {
                workspace_node.resource.sendRemoved();
                workspace_node.removed = true;
            },
            .output_leave => |value| if (self.group(value.group)) |group_node| if (group_node.resource) |resource| {
                if (self.owner.outputs.get(value.output)) |output| for (output.boundResources()) |output_resource| {
                    if (output_resource.getClient() == manager.getClient()) resource.sendOutputLeave(output_resource);
                };
            },
            .group_removed => |id| if (self.group(id)) |group_node| {
                if (group_node.resource) |resource| resource.sendRemoved();
                group_node.removed = true;
            },
            .done => manager.sendDone(),
        };
        self.owner.model.commitPrepared(&prepared.neutral) catch unreachable;
    }

    fn allocateGroup(self: *Binding, manager: *ext.WorkspaceManagerV1, id: Neutral.GroupId) !void {
        const node = try self.owner.allocator.create(GroupResource);
        errdefer self.owner.allocator.destroy(node);
        const resource = try ext.WorkspaceGroupHandleV1.create(manager.getClient(), manager.getVersion(), 0);
        errdefer resource.destroy();
        node.* = .{ .binding = self, .id = id, .resource = resource };
        try self.groups.append(self.owner.allocator, node);
        resource.setHandler(*GroupResource, GroupResource.handleRequest, GroupResource.handleDestroy, node);
    }

    fn allocateWorkspace(self: *Binding, manager: *ext.WorkspaceManagerV1, id: Neutral.HandleId) !void {
        const node = try self.owner.allocator.create(WorkspaceResource);
        errdefer self.owner.allocator.destroy(node);
        const resource = try ext.WorkspaceHandleV1.create(manager.getClient(), manager.getVersion(), 0);
        errdefer resource.destroy();
        node.* = .{ .binding = self, .id = id, .resource = resource };
        try self.workspaces.append(self.owner.allocator, node);
        resource.setHandler(*WorkspaceResource, WorkspaceResource.handleRequest, WorkspaceResource.handleDestroy, node);
    }

    fn discardPreparedResources(self: *Binding, prepared: *const Neutral.Prepared) void {
        for (prepared.handles.items) |id| if (self.workspace(id)) |node| node.resource.destroy();
        for (prepared.groups.items) |id| if (self.group(id)) |node| node.resource.?.destroy();
    }

    fn group(self: *Binding, id: Neutral.GroupId) ?*GroupResource {
        for (self.groups.items) |node| if (std.meta.eql(node.id, id)) return node;
        return null;
    }
    fn workspace(self: *Binding, id: Neutral.HandleId) ?*WorkspaceResource {
        for (self.workspaces.items) |node| if (std.meta.eql(node.id, id)) return node;
        return null;
    }

    fn commit(self: *Binding) void {
        const intents = self.owner.model.takeIntents(self.client) catch return;
        defer self.owner.model.clearIntents(self.client);
        if (intents.len == 0) return;
        const listener = self.owner.activation_listener orelse return;
        self.owner.activatePrepared(self, intents, listener);
    }

    fn handleManagerRequest(resource: *ext.WorkspaceManagerV1, request: ext.WorkspaceManagerV1.Request, self: *Binding) void {
        switch (request) {
            .commit => self.commit(),
            .stop => resource.destroySendFinished(),
        }
    }
    fn handleManagerDestroy(_: *ext.WorkspaceManagerV1, self: *Binding) void {
        self.manager = null;
        self.owner.model.clearIntents(self.client);
        self.maybeDestroy();
    }
    fn maybeDestroy(self: *Binding) void {
        if (self.manager != null or self.groups.items.len != 0 or self.workspaces.items.len != 0) return;
        for (self.owner.bindings.items, 0..) |binding, index| if (binding == self) {
            _ = self.owner.bindings.swapRemove(index);
            break;
        };
        self.owner.model.detachClient(self.client);
        self.deinitLists();
        self.owner.allocator.destroy(self);
    }
    fn deinitLists(self: *Binding) void {
        self.groups.deinit(self.owner.allocator);
        self.workspaces.deinit(self.owner.allocator);
    }
};

const GroupResource = struct {
    binding: *Binding,
    id: Neutral.GroupId,
    resource: ?*ext.WorkspaceGroupHandleV1,
    removed: bool = false,
    fn handleRequest(resource: *ext.WorkspaceGroupHandleV1, request: ext.WorkspaceGroupHandleV1.Request, _: *GroupResource) void {
        switch (request) {
            .destroy => resource.destroy(),
            .create_workspace => {},
        }
    }
    fn handleDestroy(_: *ext.WorkspaceGroupHandleV1, self: *GroupResource) void {
        const binding = self.binding;
        for (binding.groups.items, 0..) |node, index| if (node == self) {
            _ = binding.groups.swapRemove(index);
            break;
        };
        binding.owner.allocator.destroy(self);
        binding.maybeDestroy();
    }
};

const WorkspaceResource = struct {
    binding: *Binding,
    id: Neutral.HandleId,
    resource: *ext.WorkspaceHandleV1,
    removed: bool = false,
    fn handleRequest(resource: *ext.WorkspaceHandleV1, request: ext.WorkspaceHandleV1.Request, self: *WorkspaceResource) void {
        switch (request) {
            .destroy => resource.destroy(),
            .activate => if (!self.removed and self.binding.manager != null) self.binding.owner.model.queueActivate(self.binding.client, self.id) catch resource.postNoMemory(),
            .deactivate, .assign, .remove => {},
        }
    }
    fn handleDestroy(_: *ext.WorkspaceHandleV1, self: *WorkspaceResource) void {
        const binding = self.binding;
        binding.owner.model.releaseHandle(binding.client, self.id);
        for (binding.workspaces.items, 0..) |node, index| if (node == self) {
            _ = binding.workspaces.swapRemove(index);
            break;
        };
        binding.owner.allocator.destroy(self);
        binding.maybeDestroy();
    }
};

pub fn init(self: *Self, allocator: std.mem.Allocator, display: *wl.Server, security_context: *SecurityContext, outputs: *OutputLayout, clients: *MatureClients, model: *Neutral) !void {
    self.* = .{ .allocator = allocator, .global = undefined, .security_context = security_context, .outputs = outputs, .clients = clients, .model = model, .bindings = .empty, .activation_listener = null };
    errdefer self.bindings.deinit(allocator);
    self.global = try wl.Global.create(display, ext.WorkspaceManagerV1, 1, *Self, self, bind);
    errdefer self.global.destroy();
    try security_context.restrictGlobal(self.global);
    errdefer security_context.unrestrictGlobal(self.global);
    var iterator = outputs.iterator();
    while (iterator.next()) |entry| entry.output.setBindListener(.{ .context = self, .bound = outputBound });
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.activation_listener == null);
    var iterator = self.outputs.iterator();
    while (iterator.next()) |entry| entry.output.clearBindListener();
    self.security_context.unrestrictGlobal(self.global);
    self.global.destroy();
    std.debug.assert(self.bindings.items.len == 0);
    self.bindings.deinit(self.allocator);
    self.* = undefined;
}
pub fn setActivationListener(self: *Self, listener: ActivationListener) void {
    std.debug.assert(self.activation_listener == null);
    self.activation_listener = listener;
}
pub fn clearActivationListener(self: *Self) void {
    std.debug.assert(self.activation_listener != null);
    self.activation_listener = null;
}

fn activatePrepared(self: *Self, requester: *Binding, intents: []const Neutral.Intent, listener: ActivationListener) void {
    var proposed: std.ArrayList(Neutral.Snapshot) = .empty;
    defer proposed.deinit(self.allocator);
    proposed.appendSlice(self.allocator, self.model.snapshotSlice()) catch {
        if (requester.manager) |manager| manager.postNoMemory();
        return;
    };
    for (intents) |intent| {
        var found = false;
        for (proposed.items) |*snapshot| {
            if (!std.meta.eql(snapshot.output, intent.output)) continue;
            if (intent.number == 0 or intent.number > Neutral.workspace_count) return;
            snapshot.active = intent.number;
            found = true;
            break;
        }
        if (!found) return;
    }

    var prepared: std.ArrayList(Binding.Prepared) = .empty;
    defer {
        for (prepared.items) |*transaction| {
            transaction.abort();
            transaction.deinit();
        }
        prepared.deinit(self.allocator);
    }
    prepared.ensureTotalCapacity(self.allocator, self.bindings.items.len) catch {
        if (requester.manager) |manager| manager.postNoMemory();
        return;
    };
    for (self.bindings.items) |binding| {
        if (binding.manager == null) continue;
        const transaction = binding.prepare(proposed.items) catch |err| {
            if (err == error.OutOfMemory) if (binding.manager) |manager| manager.postNoMemory();
            // The requester must observe preparation success before its intent
            // can mutate canonical policy. Unrelated failed clients are isolated.
            if (binding == requester) return;
            continue;
        };
        prepared.appendAssumeCapacity(transaction);
    }
    const needs_finish = listener.prepare(listener.context, intents) orelse return;
    for (proposed.items) |snapshot| self.model.setSnapshot(snapshot) catch unreachable;
    for (prepared.items) |*transaction| transaction.binding.finalize(transaction);
    if (needs_finish) listener.finish(listener.context);
}

/// Publishes a canonical WM snapshot. A failing binding is isolated; other
/// clients still receive their complete atomic reconciliation.
pub fn publishSnapshot(self: *Self, snapshot: Neutral.Snapshot) error{OutOfMemory}!void {
    try self.model.setSnapshot(snapshot);
    for (self.bindings.items) |binding| binding.reconcile() catch |err| {
        switch (err) {
            error.OutOfMemory => if (binding.manager) |manager| manager.postNoMemory(),
            error.InvalidClient => {}, // The raw client is already retiring.
            else => unreachable,
        }
    };
}
pub fn addOutput(self: *Self, output: OutputLayout.Id) error{OutOfMemory}!void {
    const value = self.outputs.get(output) orelse return;
    value.setBindListener(.{ .context = self, .bound = outputBound });
}
pub fn removeOutput(self: *Self, output: OutputLayout.Id) void {
    if (self.outputs.get(output)) |value| value.clearBindListener();
    self.model.removeOutput(output);
    for (self.bindings.items) |binding| binding.reconcile() catch {
        if (binding.manager) |manager| manager.postNoMemory();
    };
}

/// Rolls back canonical initialization before any output state was published.
pub fn rollbackOutputSnapshot(self: *Self, output: OutputLayout.Id) void {
    self.model.removeOutput(output);
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    Binding.create(self, client, version, id) catch client.postNoMemory();
}
fn outputBound(context: *anyopaque, _: *Output, output_resource: *wl.Output) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const output = self.outputs.findResource(output_resource) orelse return;
    for (self.bindings.items) |binding| {
        const manager = binding.manager orelse continue;
        if (manager.getClient() != output_resource.getClient()) continue;
        for (binding.groups.items) |group_node| if (!group_node.removed) {
            // A group receives this wl_output only when its canonical output matches.
            // Resolve that relation through the pending/committed workspace snapshot.
            const group_output = self.model.groupOutput(binding.client, group_node.id) orelse continue;
            if (!std.meta.eql(group_output, output.id)) continue;
            group_node.resource.?.sendOutputEnter(output_resource);
            manager.sendDone();
        };
    }
}
