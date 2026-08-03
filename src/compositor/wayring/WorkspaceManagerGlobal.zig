//! Minimal privileged ext-workspace-v1 snapshot for the native output.

const WorkspaceManagerGlobal = @This();

const std = @import("std");
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const OutputGlobal = @import("OutputGlobal.zig");
const SecurityContextGlobal = @import("SecurityContextGlobal.zig");

allocator: std.mem.Allocator,
server: *Server,
output: *OutputGlobal,
global_name: u32,
bindings: std.ArrayList(*Binding) = .empty,

const Binding = struct {
    owner: *WorkspaceManagerGlobal,
    client: *Server.Client,
    manager: ?wayring.ObjectHandle,
    group: ?wayring.ObjectHandle,
    workspace: ?wayring.ObjectHandle,
    activate_pending: bool = false,
};

pub fn init(self: *WorkspaceManagerGlobal, allocator: std.mem.Allocator, server: *Server, output: *OutputGlobal, security: *SecurityContextGlobal) !void {
    self.* = .{ .allocator = allocator, .server = server, .output = output, .global_name = undefined };
    self.global_name = try server.createGlobal(&generated.ext_workspace_manager_v1, 1, .{
        .context = self,
        .bind = bind,
        .filter_context = security,
        .filter = SecurityContextGlobal.allowUnconfined,
    });
    output.setBindObserver(.{ .context = self, .bound = outputBound });
}

pub fn deinit(self: *WorkspaceManagerGlobal) void {
    self.output.clearBindObserver();
    self.server.removeGlobal(self.global_name) catch unreachable;
    std.debug.assert(self.bindings.items.len == 0);
    self.bindings.deinit(self.allocator);
    self.* = undefined;
}

fn outputBound(context: *anyopaque, client: *Server.Client, output: wayring.ObjectHandle) !void {
    const self: *WorkspaceManagerGlobal = @ptrCast(@alignCast(context));
    for (self.bindings.items) |binding| {
        if (binding.client != client) continue;
        const group = binding.group orelse continue;
        try generated.ext_workspace_group_handle_v1_types.events.output_enter(
            &client.connection,
            group,
            output,
        );
        if (binding.manager) |manager| {
            try generated.ext_workspace_manager_v1_types.events.done(&client.connection, manager);
        }
    }
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *WorkspaceManagerGlobal = @ptrCast(@alignCast(context));
    const binding = self.allocator.create(Binding) catch return client.postNoMemory();
    var binding_owned = true;
    errdefer if (binding_owned) self.allocator.destroy(binding);
    self.bindings.ensureUnusedCapacity(self.allocator, 1) catch return client.postNoMemory();
    binding.* = .{ .owner = self, .client = client, .manager = undefined, .group = null, .workspace = null };
    binding.manager = client.createResource(id, &generated.ext_workspace_manager_v1, version, .{
        .context = binding,
        .dispatch = dispatchManager,
        .destroy = destroyManager,
    }) catch return client.postNoMemory();
    self.bindings.appendAssumeCapacity(binding);
    binding_owned = false;
    createSnapshot(binding) catch return client.postNoMemory();
}

fn createSnapshot(binding: *Binding) !void {
    const manager = binding.manager.?;
    const group = try binding.client.createServerResource(&generated.ext_workspace_group_handle_v1, 1, .{
        .context = binding,
        .dispatch = dispatchGroup,
        .destroy = destroyGroup,
    });
    binding.group = group;
    errdefer binding.client.destroyResource(group) catch {};
    const workspace = try binding.client.createServerResource(&generated.ext_workspace_handle_v1, 1, .{
        .context = binding,
        .dispatch = dispatchWorkspace,
        .destroy = destroyWorkspace,
    });
    binding.workspace = workspace;
    errdefer binding.client.destroyResource(workspace) catch {};

    try generated.ext_workspace_manager_v1_types.events.workspace_group(&binding.client.connection, manager, group);
    try generated.ext_workspace_group_handle_v1_types.events.capabilities(&binding.client.connection, group, 0);
    try binding.owner.output.forEachBinding(binding.client, binding, sendOutputEnter);
    try generated.ext_workspace_manager_v1_types.events.workspace(&binding.client.connection, manager, workspace);
    try generated.ext_workspace_handle_v1_types.events.name(&binding.client.connection, workspace, "1");
    try generated.ext_workspace_handle_v1_types.events.state(&binding.client.connection, workspace, 1);
    try generated.ext_workspace_handle_v1_types.events.capabilities(&binding.client.connection, workspace, 1);
    try generated.ext_workspace_group_handle_v1_types.events.workspace_enter(&binding.client.connection, group, workspace);
    try generated.ext_workspace_manager_v1_types.events.done(&binding.client.connection, manager);
}

fn sendOutputEnter(context: *anyopaque, output: wayring.ObjectHandle) !void {
    const binding: *Binding = @ptrCast(@alignCast(context));
    try generated.ext_workspace_group_handle_v1_types.events.output_enter(&binding.client.connection, binding.group.?, output);
}

fn dispatchManager(context: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    const binding: *Binding = @ptrCast(@alignCast(context));
    switch (try generated.ext_workspace_manager_v1_types.decodeRequest(&client.connection, resource, message)) {
        .commit => binding.activate_pending = false,
        .stop => {
            binding.activate_pending = false;
            try generated.ext_workspace_manager_v1_types.events.finished(&client.connection, resource);
            try client.destroyResource(resource);
        },
    }
}

fn dispatchGroup(_: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    switch (try generated.ext_workspace_group_handle_v1_types.decodeRequest(&client.connection, resource, message)) {
        .destroy => {},
        .create_workspace => {},
    }
}

fn dispatchWorkspace(context: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    const binding: *Binding = @ptrCast(@alignCast(context));
    switch (try generated.ext_workspace_handle_v1_types.decodeRequest(&client.connection, resource, message)) {
        .activate => if (binding.manager != null) {
            binding.activate_pending = true;
        },
        .destroy, .deactivate, .assign, .remove => {},
    }
}

fn destroyManager(context: *anyopaque, _: *Server.Client, _: wayring.ObjectHandle) void {
    const binding: *Binding = @ptrCast(@alignCast(context));
    binding.manager = null;
    binding.activate_pending = false;
    maybeDestroy(binding);
}

fn destroyGroup(context: *anyopaque, _: *Server.Client, _: wayring.ObjectHandle) void {
    const binding: *Binding = @ptrCast(@alignCast(context));
    binding.group = null;
    maybeDestroy(binding);
}

fn destroyWorkspace(context: *anyopaque, _: *Server.Client, _: wayring.ObjectHandle) void {
    const binding: *Binding = @ptrCast(@alignCast(context));
    binding.workspace = null;
    binding.activate_pending = false;
    maybeDestroy(binding);
}

fn maybeDestroy(binding: *Binding) void {
    if (binding.manager != null or binding.group != null or binding.workspace != null) return;
    const owner = binding.owner;
    _ = owner.bindings.swapRemove(std.mem.indexOfScalar(*Binding, owner.bindings.items, binding) orelse unreachable);
    owner.allocator.destroy(binding);
}

const TestGlobals = struct {
    transport: @import("wayring-server-uring") = undefined,
    security: SecurityContextGlobal = undefined,
    output: OutputGlobal = undefined,
    workspaces: WorkspaceManagerGlobal = undefined,

    fn init(self: *TestGlobals, server: *Server) !void {
        try self.security.init(std.testing.allocator, server, &self.transport);
        errdefer self.security.deinit();
        try self.output.init(std.testing.allocator, server, .{
            .mode_size = .{ .width = 1280, .height = 720 },
            .logical_size = .{ .width = 1280, .height = 720 },
            .physical_size = .{ .width = 300, .height = 170 },
            .refresh_millihertz = 60_000,
            .scale = 1,
            .name = "TEST-1",
            .description = "Test output",
            .model = "test",
        });
        errdefer self.output.deinit();
        try self.workspaces.init(std.testing.allocator, server, &self.output, &self.security);
    }

    fn deinit(self: *TestGlobals) void {
        self.workspaces.deinit();
        self.output.deinit();
        self.security.deinit();
    }
};

const TestBound = struct {
    manager: wayring.ObjectHandle,
    output: wayring.ObjectHandle,
};

fn bindTestGlobals(peer: *wayring.Connection, client: *Server.Client, globals: *TestGlobals) !TestBound {
    const core = @import("wayring-core");
    _ = try core.bootstrapDisplay(peer);
    const registry: wayring.ObjectHandle = .{ .id = 2, .generation = try core.getRegistry(peer, 2) };
    try transferToServer(peer, client);
    try transferFromServer(peer, client);
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        _ = try core.decodeRegistryEvent(&message, registry.id);
    }
    const output: wayring.ObjectHandle = .{ .id = 3, .generation = try core.bind(
        peer,
        registry.id,
        globals.output.global_name,
        generated.wl_output.name,
        4,
        3,
        &generated.wl_output,
    ) };
    try transferToServer(peer, client);
    try transferFromServer(peer, client);
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        _ = try generated.wl_output_types.decodeEvent(peer, output, &message);
    }
    const manager: wayring.ObjectHandle = .{ .id = 4, .generation = try core.bind(
        peer,
        registry.id,
        globals.workspaces.global_name,
        generated.ext_workspace_manager_v1.name,
        1,
        4,
        &generated.ext_workspace_manager_v1,
    ) };
    try transferToServer(peer, client);
    try transferFromServer(peer, client);
    return .{ .manager = manager, .output = output };
}

fn testObjectId(value: anytype) u32 {
    return if (@TypeOf(value) == wayring.ObjectHandle) value.id else value;
}

fn testServerHandle(peer: *wayring.Connection, value: anytype, interface: *const wayring.Interface) !wayring.ObjectHandle {
    if (@TypeOf(value) == wayring.ObjectHandle) return value;
    const handle: wayring.ObjectHandle = .{ .id = value, .generation = try peer.registerObject(value, interface, 1) };
    try peer.resumeParsing();
    return handle;
}

test "workspace shell snapshot has exact order and same-client output" {
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var globals: TestGlobals = .{};
    try globals.init(&server);
    defer globals.deinit();
    const client = try server.createClient();
    defer server.destroyClient(client) catch unreachable;
    var peer = wayring.Connection.init(std.testing.allocator, .client, wayring.default_max_frame_size);
    defer peer.deinit();
    const bound = try bindTestGlobals(&peer, client, &globals);

    var group: wayring.ObjectHandle = undefined;
    var workspace: wayring.ObjectHandle = undefined;
    var index: usize = 0;
    while (peer.popMessage()) |popped| : (index += 1) {
        var message = popped;
        defer message.deinit();
        switch (index) {
            0 => {
                const id = (try generated.ext_workspace_manager_v1_types.decodeEvent(&peer, bound.manager, &message)).workspace_group.workspace_group;
                group = try testServerHandle(&peer, id, &generated.ext_workspace_group_handle_v1);
            },
            1 => try std.testing.expectEqual(@as(u32, 0), (try generated.ext_workspace_group_handle_v1_types.decodeEvent(&peer, group, &message)).capabilities.capabilities),
            2 => try std.testing.expectEqual(bound.output.id, testObjectId((try generated.ext_workspace_group_handle_v1_types.decodeEvent(&peer, group, &message)).output_enter.output)),
            3 => {
                const id = (try generated.ext_workspace_manager_v1_types.decodeEvent(&peer, bound.manager, &message)).workspace.workspace;
                workspace = try testServerHandle(&peer, id, &generated.ext_workspace_handle_v1);
            },
            4 => try std.testing.expectEqualStrings("1", (try generated.ext_workspace_handle_v1_types.decodeEvent(&peer, workspace, &message)).name.name),
            5 => try std.testing.expectEqual(@as(u32, 1), (try generated.ext_workspace_handle_v1_types.decodeEvent(&peer, workspace, &message)).state.state),
            6 => try std.testing.expectEqual(@as(u32, 1), (try generated.ext_workspace_handle_v1_types.decodeEvent(&peer, workspace, &message)).capabilities.capabilities),
            7 => try std.testing.expectEqual(workspace.id, testObjectId((try generated.ext_workspace_group_handle_v1_types.decodeEvent(&peer, group, &message)).workspace_enter.workspace)),
            8 => try std.testing.expect((try generated.ext_workspace_manager_v1_types.decodeEvent(&peer, bound.manager, &message)) == .done),
            else => return error.UnexpectedWorkspaceEvent,
        }
    }
    try std.testing.expectEqual(@as(usize, 9), index);
}

test "workspace group observes wl_output bindings after manager bind" {
    const core = @import("wayring-core");
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var globals: TestGlobals = .{};
    try globals.init(&server);
    defer globals.deinit();
    const client = try server.createClient();
    defer server.destroyClient(client) catch {};
    var peer = wayring.Connection.init(std.testing.allocator, .client, wayring.default_max_frame_size);
    defer peer.deinit();

    _ = try core.bootstrapDisplay(&peer);
    const registry: wayring.ObjectHandle = .{ .id = 2, .generation = try core.getRegistry(&peer, 2) };
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        _ = try core.decodeRegistryEvent(&message, registry.id);
    }
    const manager: wayring.ObjectHandle = .{ .id = 3, .generation = try core.bind(
        &peer,
        registry.id,
        globals.workspaces.global_name,
        generated.ext_workspace_manager_v1.name,
        1,
        3,
        &generated.ext_workspace_manager_v1,
    ) };
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);

    var group: wayring.ObjectHandle = undefined;
    var workspace: wayring.ObjectHandle = undefined;
    var index: usize = 0;
    while (peer.popMessage()) |popped| : (index += 1) {
        var message = popped;
        defer message.deinit();
        switch (index) {
            0 => group = try testServerHandle(&peer, (try generated.ext_workspace_manager_v1_types.decodeEvent(&peer, manager, &message)).workspace_group.workspace_group, &generated.ext_workspace_group_handle_v1),
            1 => _ = try generated.ext_workspace_group_handle_v1_types.decodeEvent(&peer, group, &message),
            2 => workspace = try testServerHandle(&peer, (try generated.ext_workspace_manager_v1_types.decodeEvent(&peer, manager, &message)).workspace.workspace, &generated.ext_workspace_handle_v1),
            3, 4, 5 => {
                _ = try generated.ext_workspace_handle_v1_types.decodeEvent(&peer, workspace, &message);
            },
            6 => _ = try generated.ext_workspace_group_handle_v1_types.decodeEvent(&peer, group, &message),
            7 => try std.testing.expect((try generated.ext_workspace_manager_v1_types.decodeEvent(&peer, manager, &message)) == .done),
            else => return error.UnexpectedWorkspaceEvent,
        }
    }
    try std.testing.expectEqual(@as(usize, 8), index);

    try generated.ext_workspace_manager_v1_types.requests.stop(&peer, manager);
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    var finished = false;
    var deleted = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == manager.id) {
            finished = (try generated.ext_workspace_manager_v1_types.decodeEvent(&peer, manager, &message)) == .finished;
        } else if (message.object_id == 1) {
            switch (try core.decodeDisplayEvent(&message)) {
                .delete_id => |id| deleted = id == manager.id,
                else => return error.UnexpectedDisplayEvent,
            }
        } else return error.UnexpectedWorkspaceEvent;
    }
    try std.testing.expect(finished);
    try std.testing.expect(deleted);

    const output: wayring.ObjectHandle = .{ .id = 4, .generation = try core.bind(
        &peer,
        registry.id,
        globals.output.global_name,
        generated.wl_output.name,
        4,
        4,
        &generated.wl_output,
    ) };
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    var entered: usize = 0;
    var manager_done = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == output.id) {
            _ = try generated.wl_output_types.decodeEvent(&peer, output, &message);
        } else if (message.object_id == group.id) {
            try std.testing.expectEqual(output.id, testObjectId((try generated.ext_workspace_group_handle_v1_types.decodeEvent(&peer, group, &message)).output_enter.output));
            entered += 1;
        } else if (message.object_id == manager.id) {
            manager_done = true;
        } else return error.UnexpectedWorkspaceEvent;
    }
    try std.testing.expectEqual(@as(usize, 1), entered);
    try std.testing.expect(!manager_done);
}

test "workspace requests buffer through commit and resources have independent lifetimes" {
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var globals: TestGlobals = .{};
    try globals.init(&server);
    defer globals.deinit();
    const client = try server.createClient();
    defer server.destroyClient(client) catch {};
    var peer = wayring.Connection.init(std.testing.allocator, .client, wayring.default_max_frame_size);
    defer peer.deinit();
    const bound = try bindTestGlobals(&peer, client, &globals);
    var group: wayring.ObjectHandle = undefined;
    var workspace: wayring.ObjectHandle = undefined;
    var snapshot_index: usize = 0;
    while (peer.popMessage()) |popped| : (snapshot_index += 1) {
        var message = popped;
        defer message.deinit();
        switch (snapshot_index) {
            0 => group = try testServerHandle(&peer, (try generated.ext_workspace_manager_v1_types.decodeEvent(&peer, bound.manager, &message)).workspace_group.workspace_group, &generated.ext_workspace_group_handle_v1),
            1, 2, 7 => _ = try generated.ext_workspace_group_handle_v1_types.decodeEvent(&peer, group, &message),
            3 => workspace = try testServerHandle(&peer, (try generated.ext_workspace_manager_v1_types.decodeEvent(&peer, bound.manager, &message)).workspace.workspace, &generated.ext_workspace_handle_v1),
            4, 5, 6 => _ = try generated.ext_workspace_handle_v1_types.decodeEvent(&peer, workspace, &message),
            8 => _ = try generated.ext_workspace_manager_v1_types.decodeEvent(&peer, bound.manager, &message),
            else => return error.UnexpectedWorkspaceEvent,
        }
    }
    try std.testing.expectEqual(@as(usize, 9), snapshot_index);
    const binding = globals.workspaces.bindings.items[0];

    try generated.ext_workspace_handle_v1_types.requests.activate(&peer, workspace);
    try transferToServer(&peer, client);
    try std.testing.expect(binding.activate_pending);
    try generated.ext_workspace_manager_v1_types.requests.commit(&peer, bound.manager);
    try generated.ext_workspace_manager_v1_types.requests.commit(&peer, bound.manager);
    try transferToServer(&peer, client);
    try std.testing.expect(!binding.activate_pending);

    try generated.ext_workspace_group_handle_v1_types.requests.create_workspace(&peer, group, "ignored");
    try generated.ext_workspace_handle_v1_types.requests.deactivate(&peer, workspace);
    try generated.ext_workspace_handle_v1_types.requests.remove(&peer, workspace);
    try transferToServer(&peer, client);
    try generated.ext_workspace_group_handle_v1_types.requests.destroy(&peer, group);
    try transferToServer(&peer, client);
    try std.testing.expect(binding.group == null);
    try generated.ext_workspace_manager_v1_types.requests.stop(&peer, bound.manager);
    try generated.ext_workspace_manager_v1_types.requests.commit(&peer, bound.manager);
    try std.testing.expectError(error.ProtocolError, transferToServer(&peer, client));
    try transferFromServer(&peer, client);
    try std.testing.expect(binding.manager == null);
    var finished = false;
    var deleted = false;
    var protocol_error = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == bound.manager.id) {
            finished = (try generated.ext_workspace_manager_v1_types.decodeEvent(&peer, bound.manager, &message)) == .finished;
        } else if (message.object_id == 1) {
            const core = @import("wayring-core");
            switch (try core.decodeDisplayEvent(&message)) {
                .delete_id => |id| if (id == bound.manager.id) {
                    deleted = true;
                },
                .error_event => |event| if (event.object_id == bound.manager.id) {
                    protocol_error = true;
                },
            }
        } else return error.UnexpectedWorkspaceEvent;
    }
    try std.testing.expect(finished);
    try std.testing.expect(deleted);
    try std.testing.expect(protocol_error);
    try server.destroyClient(client);
    try std.testing.expectEqual(@as(usize, 0), globals.workspaces.bindings.items.len);

    const second = try server.createClient();
    var second_peer = wayring.Connection.init(std.testing.allocator, .client, wayring.default_max_frame_size);
    defer second_peer.deinit();
    _ = try bindTestGlobals(&second_peer, second, &globals);
    try std.testing.expectEqual(@as(usize, 1), globals.workspaces.bindings.items.len);
    try server.destroyClient(second);
    try std.testing.expectEqual(@as(usize, 0), globals.workspaces.bindings.items.len);
}

test "workspace global rejects confined and guessed binds" {
    const core = @import("wayring-core");
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var globals: TestGlobals = .{};
    try globals.init(&server);
    defer globals.deinit();
    const client = try server.createClientWithProvenance(try SecurityContextGlobal.Testing.confinedProvenance(std.testing.allocator));
    defer server.destroyClient(client) catch {};
    var peer = wayring.Connection.init(std.testing.allocator, .client, wayring.default_max_frame_size);
    defer peer.deinit();
    _ = try core.bootstrapDisplay(&peer);
    const registry: wayring.ObjectHandle = .{ .id = 2, .generation = try core.getRegistry(&peer, 2) };
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const event = try core.decodeRegistryEvent(&message, registry.id);
        if (event == .global) try std.testing.expect(!std.mem.eql(u8, event.global.interface, generated.ext_workspace_manager_v1.name));
    }
    _ = try core.bind(&peer, registry.id, globals.workspaces.global_name, generated.ext_workspace_manager_v1.name, 1, 3, &generated.ext_workspace_manager_v1);
    try std.testing.expectError(error.ProtocolError, transferToServer(&peer, client));
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
