//! Privileged discovery and activation of compositor-owned workspaces.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Output = @import("output.zig");
const OutputLayout = @import("output_layout.zig");
const SecurityContext = @import("security_context.zig");

const wl = wayland.server.wl;
const ext = wayland.server.ext;
const workspace_count: u8 = 10;
const workspace_names = [_][*:0]const u8{ "1", "2", "3", "4", "5", "6", "7", "8", "9", "10" };

allocator: std.mem.Allocator,
global: *wl.Global,
security_context: *SecurityContext,
outputs: *OutputLayout,
output_states: std.ArrayList(OutputState),
bindings: std.ArrayList(*Binding),
activation_listener: ?ActivationListener,

pub const ActivationListener = struct {
    context: *anyopaque,
    activate: *const fn (*anyopaque, OutputLayout.Id, u8) bool,
};

const OutputState = struct {
    output: OutputLayout.Id,
    active: u8 = 1,
    occupied: [workspace_count]bool = @splat(false),
    urgent: [workspace_count]bool = @splat(false),

    fn isAdvertised(self: OutputState, number: u8) bool {
        std.debug.assert(number >= 1 and number <= workspace_count);
        return self.active == number or self.occupied[number - 1] or self.urgent[number - 1];
    }
};

const PendingActivation = struct {
    output: OutputLayout.Id,
    number: u8,
};

const Binding = struct {
    owner: *Self,
    manager: ?*ext.WorkspaceManagerV1,
    groups: std.ArrayList(*GroupResource) = .empty,
    workspaces: std.ArrayList(*WorkspaceResource) = .empty,
    pending_activations: std.ArrayList(PendingActivation) = .empty,

    fn create(owner: *Self, client: *wl.Client, version: u32, id: u32) !void {
        const manager = try ext.WorkspaceManagerV1.create(client, version, id);
        errdefer manager.destroy();
        const self = try owner.allocator.create(Binding);
        errdefer owner.allocator.destroy(self);
        self.* = .{ .owner = owner, .manager = manager };
        errdefer {
            self.groups.deinit(owner.allocator);
            self.workspaces.deinit(owner.allocator);
            self.pending_activations.deinit(owner.allocator);
        }
        try owner.bindings.append(owner.allocator, self);
        manager.setHandler(*Binding, handleManagerRequest, handleManagerDestroy, self);
        for (owner.output_states.items) |state| {
            self.addOutput(state) catch {
                manager.postNoMemory();
                return;
            };
        }
        manager.sendDone();
    }

    fn addOutput(self: *Binding, state: OutputState) !void {
        const manager = self.manager orelse return;
        _ = try GroupResource.create(self, manager, state.output);
        for (1..workspace_count + 1) |number| {
            const workspace_number: u8 = @intCast(number);
            if (!state.isAdvertised(workspace_number)) continue;
            try WorkspaceResource.create(
                self,
                manager,
                state.output,
                workspace_number,
                state.active == number,
                state.urgent[number - 1],
            );
        }
    }

    fn workspaceFor(self: *Binding, output: OutputLayout.Id, number: u8) ?*WorkspaceResource {
        for (self.workspaces.items) |workspace| {
            if (!workspace.removed and workspace.number == number and std.meta.eql(workspace.output, output)) {
                return workspace;
            }
        }
        return null;
    }

    fn removeWorkspace(self: *Binding, output: OutputLayout.Id, number: u8) void {
        const workspace = self.workspaceFor(output, number) orelse return;
        if (self.groupFor(output)) |group| {
            if (group.resource) |group_resource| group_resource.sendWorkspaceLeave(workspace.resource);
        }
        workspace.resource.sendRemoved();
        workspace.removed = true;
    }

    fn removeOutput(self: *Binding, output_id: OutputLayout.Id, output: *Output) void {
        const manager = self.manager orelse return;
        const group = self.groupFor(output_id);
        for (self.workspaces.items) |workspace| {
            if (workspace.removed or !std.meta.eql(workspace.output, output_id)) continue;
            if (group) |group_resource| {
                if (group_resource.resource) |group_handle| {
                    group_handle.sendWorkspaceLeave(workspace.resource);
                }
            }
            workspace.resource.sendRemoved();
            workspace.removed = true;
        }
        if (group) |group_resource| {
            if (group_resource.resource) |group_handle| {
                for (output.boundResources()) |output_resource| {
                    if (output_resource.getClient() == manager.getClient()) {
                        group_handle.sendOutputLeave(output_resource);
                    }
                }
                group_handle.sendRemoved();
            }
            group_resource.removed = true;
        }
        manager.sendDone();
    }

    fn groupFor(self: *Binding, output_id: OutputLayout.Id) ?*GroupResource {
        for (self.groups.items) |group| {
            if (!group.removed and std.meta.eql(group.output, output_id)) return group;
        }
        return null;
    }

    fn queueActivation(self: *Binding, output: OutputLayout.Id, number: u8) !void {
        for (self.pending_activations.items) |*pending| {
            if (!std.meta.eql(pending.output, output)) continue;
            pending.number = number;
            return;
        }
        try self.pending_activations.append(self.owner.allocator, .{
            .output = output,
            .number = number,
        });
    }

    fn commit(self: *Binding) void {
        var changed = false;
        for (self.pending_activations.items) |pending| {
            const listener = self.owner.activation_listener orelse continue;
            if (!listener.activate(listener.context, pending.output, pending.number)) continue;
            changed = self.owner.updateActive(pending.output, pending.number) or changed;
        }
        self.pending_activations.clearRetainingCapacity();
        if (changed) self.owner.sendDone();
    }

    fn handleManagerRequest(
        resource: *ext.WorkspaceManagerV1,
        request: ext.WorkspaceManagerV1.Request,
        self: *Binding,
    ) void {
        switch (request) {
            .commit => self.commit(),
            .stop => resource.destroySendFinished(),
        }
    }

    fn handleManagerDestroy(_: *ext.WorkspaceManagerV1, self: *Binding) void {
        self.manager = null;
        self.pending_activations.clearRetainingCapacity();
        self.maybeDestroy();
    }

    fn maybeDestroy(self: *Binding) void {
        if (self.manager != null or self.groups.items.len != 0 or self.workspaces.items.len != 0) return;
        for (self.owner.bindings.items, 0..) |binding, index| {
            if (binding != self) continue;
            _ = self.owner.bindings.swapRemove(index);
            break;
        }
        self.groups.deinit(self.owner.allocator);
        self.workspaces.deinit(self.owner.allocator);
        self.pending_activations.deinit(self.owner.allocator);
        self.owner.allocator.destroy(self);
    }
};

const GroupResource = struct {
    binding: *Binding,
    output: OutputLayout.Id,
    resource: ?*ext.WorkspaceGroupHandleV1,
    removed: bool = false,

    fn create(binding: *Binding, manager: *ext.WorkspaceManagerV1, output_id: OutputLayout.Id) !*GroupResource {
        const self = try binding.owner.allocator.create(GroupResource);
        errdefer binding.owner.allocator.destroy(self);
        const resource = try ext.WorkspaceGroupHandleV1.create(manager.getClient(), manager.getVersion(), 0);
        errdefer resource.destroy();
        self.* = .{ .binding = binding, .output = output_id, .resource = resource };
        try binding.groups.append(binding.owner.allocator, self);
        resource.setHandler(*GroupResource, handleRequest, handleDestroy, self);
        manager.sendWorkspaceGroup(resource);
        resource.sendCapabilities(.{});
        if (binding.owner.outputs.get(output_id)) |output| {
            for (output.boundResources()) |output_resource| {
                if (output_resource.getClient() == manager.getClient()) {
                    resource.sendOutputEnter(output_resource);
                }
            }
        }
        return self;
    }

    fn handleRequest(
        resource: *ext.WorkspaceGroupHandleV1,
        request: ext.WorkspaceGroupHandleV1.Request,
        _: *GroupResource,
    ) void {
        switch (request) {
            .destroy => resource.destroy(),
            .create_workspace => {},
        }
    }

    fn handleDestroy(_: *ext.WorkspaceGroupHandleV1, self: *GroupResource) void {
        const binding = self.binding;
        for (binding.groups.items, 0..) |group, index| {
            if (group != self) continue;
            _ = binding.groups.swapRemove(index);
            break;
        }
        binding.owner.allocator.destroy(self);
        binding.maybeDestroy();
    }
};

const WorkspaceResource = struct {
    binding: *Binding,
    output: OutputLayout.Id,
    number: u8,
    resource: *ext.WorkspaceHandleV1,
    removed: bool = false,

    fn create(
        binding: *Binding,
        manager: *ext.WorkspaceManagerV1,
        output_id: OutputLayout.Id,
        number: u8,
        active: bool,
        urgent: bool,
    ) !void {
        std.debug.assert(number >= 1 and number <= workspace_count);
        const self = try binding.owner.allocator.create(WorkspaceResource);
        errdefer binding.owner.allocator.destroy(self);
        const resource = try ext.WorkspaceHandleV1.create(manager.getClient(), manager.getVersion(), 0);
        errdefer resource.destroy();
        self.* = .{
            .binding = binding,
            .output = output_id,
            .number = number,
            .resource = resource,
        };
        try binding.workspaces.append(binding.owner.allocator, self);
        resource.setHandler(*WorkspaceResource, handleRequest, handleDestroy, self);
        manager.sendWorkspace(resource);
        resource.sendName(workspace_names[number - 1]);
        var coordinate: u32 = number - 1;
        var coordinates: wl.Array = .{
            .size = @sizeOf(u32),
            .alloc = @sizeOf(u32),
            .data = @ptrCast(&coordinate),
        };
        resource.sendCoordinates(&coordinates);
        resource.sendState(.{ .active = active, .urgent = urgent });
        resource.sendCapabilities(.{ .activate = true });
        if (binding.groupFor(output_id)) |group| {
            if (group.resource) |group_resource| group_resource.sendWorkspaceEnter(resource);
        }
    }

    fn handleRequest(
        resource: *ext.WorkspaceHandleV1,
        request: ext.WorkspaceHandleV1.Request,
        self: *WorkspaceResource,
    ) void {
        switch (request) {
            .destroy => resource.destroy(),
            .activate => {
                if (self.removed or self.binding.manager == null) return;
                self.binding.queueActivation(self.output, self.number) catch resource.postNoMemory();
            },
            .deactivate, .assign, .remove => {},
        }
    }

    fn handleDestroy(_: *ext.WorkspaceHandleV1, self: *WorkspaceResource) void {
        const binding = self.binding;
        for (binding.workspaces.items, 0..) |workspace, index| {
            if (workspace != self) continue;
            _ = binding.workspaces.swapRemove(index);
            break;
        }
        binding.owner.allocator.destroy(self);
        binding.maybeDestroy();
    }
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    security_context: *SecurityContext,
    outputs: *OutputLayout,
) !void {
    self.* = .{
        .allocator = allocator,
        .global = undefined,
        .security_context = security_context,
        .outputs = outputs,
        .output_states = .empty,
        .bindings = .empty,
        .activation_listener = null,
    };
    errdefer self.output_states.deinit(allocator);
    errdefer self.bindings.deinit(allocator);
    var iterator = outputs.iterator();
    while (iterator.next()) |entry| {
        try self.output_states.append(allocator, .{ .output = entry.id });
    }
    self.global = try wl.Global.create(display, ext.WorkspaceManagerV1, 1, *Self, self, bind);
    errdefer self.global.destroy();
    try security_context.restrictGlobal(self.global);
    errdefer security_context.unrestrictGlobal(self.global);
    iterator = outputs.iterator();
    while (iterator.next()) |entry| entry.output.setBindListener(.{
        .context = self,
        .bound = outputBound,
    });
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.activation_listener == null);
    var iterator = self.outputs.iterator();
    while (iterator.next()) |entry| entry.output.clearBindListener();
    self.security_context.unrestrictGlobal(self.global);
    self.global.destroy();
    std.debug.assert(self.bindings.items.len == 0);
    self.output_states.deinit(self.allocator);
    self.bindings.deinit(self.allocator);
    self.* = undefined;
}

/// Copies the listener and retains its context until clearActivationListener.
pub fn setActivationListener(self: *Self, listener: ActivationListener) void {
    std.debug.assert(self.activation_listener == null);
    self.activation_listener = listener;
}

pub fn clearActivationListener(self: *Self) void {
    std.debug.assert(self.activation_listener != null);
    self.activation_listener = null;
}

pub fn addOutput(self: *Self, output_id: OutputLayout.Id) error{OutOfMemory}!void {
    std.debug.assert(self.outputState(output_id) == null);
    const output = self.outputs.get(output_id) orelse return;
    try self.output_states.append(self.allocator, .{ .output = output_id });
    output.setBindListener(.{ .context = self, .bound = outputBound });
    for (self.bindings.items) |binding| {
        const manager = binding.manager orelse continue;
        binding.addOutput(.{ .output = output_id }) catch {
            manager.postNoMemory();
            continue;
        };
        manager.sendDone();
    }
}

pub fn removeOutput(self: *Self, output_id: OutputLayout.Id) void {
    const output = self.outputs.get(output_id) orelse return;
    for (self.bindings.items) |binding| binding.removeOutput(output_id, output);
    output.clearBindListener();
    for (self.output_states.items, 0..) |state, index| {
        if (!std.meta.eql(state.output, output_id)) continue;
        _ = self.output_states.orderedRemove(index);
        return;
    }
}

pub fn setActive(self: *Self, output: OutputLayout.Id, number: u8) void {
    if (self.updateActive(output, number)) self.sendDone();
}

pub fn setOccupied(self: *Self, output: OutputLayout.Id, number: u8, occupied: bool) void {
    if (number == 0 or number > workspace_count) return;
    const state = self.outputState(output) orelse return;
    const was_advertised = state.isAdvertised(number);
    if (!self.updateOccupied(output, number, occupied)) return;
    const is_advertised = state.isAdvertised(number);
    if (was_advertised == is_advertised) return;
    for (self.bindings.items) |binding| {
        const manager = binding.manager orelse continue;
        if (is_advertised) {
            WorkspaceResource.create(
                binding,
                manager,
                output,
                number,
                state.active == number,
                state.urgent[number - 1],
            ) catch {
                manager.postNoMemory();
                continue;
            };
        } else {
            binding.removeWorkspace(output, number);
        }
        manager.sendDone();
    }
}

pub fn setUrgent(self: *Self, output: OutputLayout.Id, number: u8, urgent: bool) void {
    if (number == 0 or number > workspace_count) return;
    const state = self.outputState(output) orelse return;
    const was_advertised = state.isAdvertised(number);
    if (!self.updateUrgent(output, number, urgent)) return;
    const is_advertised = state.isAdvertised(number);
    for (self.bindings.items) |binding| {
        const manager = binding.manager orelse continue;
        if (binding.workspaceFor(output, number)) |workspace| {
            workspace.resource.sendState(.{
                .active = state.active == number,
                .urgent = urgent,
            });
            if (!is_advertised) binding.removeWorkspace(output, number);
        } else if (is_advertised) {
            WorkspaceResource.create(
                binding,
                manager,
                output,
                number,
                state.active == number,
                urgent,
            ) catch manager.postNoMemory();
        }
        if (was_advertised != is_advertised or binding.workspaceFor(output, number) != null) {
            manager.sendDone();
        }
    }
}

fn updateActive(self: *Self, output: OutputLayout.Id, number: u8) bool {
    if (number == 0 or number > workspace_count) return false;
    const state = self.outputState(output) orelse return false;
    if (state.active == number) return false;
    const previous = state.active;
    state.active = number;
    for (self.bindings.items) |binding| {
        const manager = binding.manager orelse continue;
        if (binding.workspaceFor(output, number)) |workspace| {
            workspace.resource.sendState(.{
                .active = true,
                .urgent = state.urgent[number - 1],
            });
        } else {
            WorkspaceResource.create(
                binding,
                manager,
                output,
                number,
                true,
                state.urgent[number - 1],
            ) catch manager.postNoMemory();
        }
        if (binding.workspaceFor(output, previous)) |workspace| {
            workspace.resource.sendState(.{
                .active = false,
                .urgent = state.urgent[previous - 1],
            });
            if (!state.isAdvertised(previous)) binding.removeWorkspace(output, previous);
        }
    }
    return true;
}

fn updateOccupied(self: *Self, output: OutputLayout.Id, number: u8, occupied: bool) bool {
    if (number == 0 or number > workspace_count) return false;
    const state = self.outputState(output) orelse return false;
    if (state.occupied[number - 1] == occupied) return false;
    state.occupied[number - 1] = occupied;
    return true;
}

fn updateUrgent(self: *Self, output: OutputLayout.Id, number: u8, urgent: bool) bool {
    if (number == 0 or number > workspace_count) return false;
    const state = self.outputState(output) orelse return false;
    if (state.urgent[number - 1] == urgent) return false;
    state.urgent[number - 1] = urgent;
    return true;
}

fn sendDone(self: *Self) void {
    for (self.bindings.items) |binding| {
        if (binding.manager) |manager| manager.sendDone();
    }
}

fn outputState(self: *Self, output: OutputLayout.Id) ?*OutputState {
    for (self.output_states.items) |*state| {
        if (std.meta.eql(state.output, output)) return state;
    }
    return null;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    Binding.create(self, client, version, id) catch client.postNoMemory();
}

fn outputBound(context: *anyopaque, _: *Output, output_resource: *wl.Output) void {
    const self: *Self = @ptrCast(@alignCast(context));
    for (self.bindings.items) |binding| {
        const manager = binding.manager orelse continue;
        if (output_resource.getClient() != manager.getClient()) continue;
        const group = binding.groupFor(self.outputs.findResource(output_resource).?.id) orelse continue;
        const resource = group.resource orelse continue;
        resource.sendOutputEnter(output_resource);
        manager.sendDone();
    }
}

test "workspace model tracks one active numbered workspace per output" {
    var workspace: Self = undefined;
    workspace.output_states = .empty;
    workspace.bindings = .empty;
    defer workspace.output_states.deinit(std.testing.allocator);
    defer workspace.bindings.deinit(std.testing.allocator);

    const first: OutputLayout.Id = .{ .index = 1, .generation = 1 };
    const second: OutputLayout.Id = .{ .index = 2, .generation = 1 };
    try workspace.output_states.append(std.testing.allocator, .{ .output = first });
    try workspace.output_states.append(std.testing.allocator, .{ .output = second });

    try std.testing.expect(workspace.updateActive(first, 10));
    try std.testing.expectEqual(@as(u8, 10), workspace.outputState(first).?.active);
    try std.testing.expectEqual(@as(u8, 1), workspace.outputState(second).?.active);
    try std.testing.expect(!workspace.updateActive(first, 10));
    try std.testing.expect(!workspace.updateActive(first, 0));
    try std.testing.expect(workspace.outputState(first).?.isAdvertised(10));
    try std.testing.expect(!workspace.outputState(first).?.isAdvertised(1));
}

test "workspace model tracks occupied workspaces per output" {
    var workspace: Self = undefined;
    workspace.output_states = .empty;
    defer workspace.output_states.deinit(std.testing.allocator);

    const first: OutputLayout.Id = .{ .index = 1, .generation = 1 };
    const second: OutputLayout.Id = .{ .index = 2, .generation = 1 };
    try workspace.output_states.append(std.testing.allocator, .{ .output = first });
    try workspace.output_states.append(std.testing.allocator, .{ .output = second });

    try std.testing.expect(workspace.updateOccupied(first, 10, true));
    try std.testing.expect(workspace.outputState(first).?.occupied[9]);
    try std.testing.expect(workspace.outputState(first).?.isAdvertised(10));
    try std.testing.expect(!workspace.outputState(second).?.occupied[9]);
    try std.testing.expect(!workspace.updateOccupied(first, 10, true));
    try std.testing.expect(workspace.updateOccupied(first, 10, false));
    try std.testing.expect(!workspace.updateOccupied(first, 0, true));
}

test "workspace urgency is independent per output and keeps a workspace advertised" {
    var workspace: Self = undefined;
    workspace.output_states = .empty;
    workspace.bindings = .empty;
    defer workspace.output_states.deinit(std.testing.allocator);
    defer workspace.bindings.deinit(std.testing.allocator);

    const first: OutputLayout.Id = .{ .index = 1, .generation = 1 };
    const second: OutputLayout.Id = .{ .index = 2, .generation = 1 };
    try workspace.output_states.append(std.testing.allocator, .{ .output = first });
    try workspace.output_states.append(std.testing.allocator, .{ .output = second });

    try std.testing.expect(workspace.updateUrgent(first, 10, true));
    try std.testing.expect(workspace.outputState(first).?.urgent[9]);
    try std.testing.expect(workspace.outputState(first).?.isAdvertised(10));
    try std.testing.expect(!workspace.outputState(second).?.urgent[9]);
    try std.testing.expect(!workspace.updateUrgent(first, 10, true));
    try std.testing.expect(workspace.updateUrgent(first, 10, false));
    try std.testing.expect(!workspace.outputState(first).?.isAdvertised(10));
    try std.testing.expect(!workspace.updateUrgent(first, 0, true));
}

test "workspace names match their numbers" {
    try std.testing.expectEqualStrings("1", std.mem.span(workspace_names[0]));
    try std.testing.expectEqualStrings("10", std.mem.span(workspace_names[9]));
}
