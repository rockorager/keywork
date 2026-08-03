//! Privileged, exclusive output power controls for the native output.

const OutputPowerGlobal = @This();

const std = @import("std");
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const OutputGlobal = @import("OutputGlobal.zig");
const SecurityContextGlobal = @import("SecurityContextGlobal.zig");

allocator: std.mem.Allocator,
server: *Server,
output: *OutputGlobal,
listener: Listener,
global_name: u32,
controls: std.ArrayList(*Control) = .empty,
active: ?*Control = null,

pub const Listener = struct {
    context: *anyopaque,
    /// Null means that the output has no physical power control.
    mode: *const fn (*anyopaque) ?bool,
    set_mode: *const fn (*anyopaque, bool) anyerror!void,
};

const Control = struct {
    owner: *OutputPowerGlobal,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    valid: bool,
};

pub fn init(
    self: *OutputPowerGlobal,
    allocator: std.mem.Allocator,
    server: *Server,
    output: *OutputGlobal,
    security_context: *SecurityContextGlobal,
    listener: Listener,
) !void {
    self.* = .{
        .allocator = allocator,
        .server = server,
        .output = output,
        .listener = listener,
        .global_name = undefined,
    };
    self.global_name = try server.createGlobal(
        &generated.zwlr_output_power_manager_v1,
        1,
        .{
            .context = self,
            .bind = bind,
            .filter_context = security_context,
            .filter = SecurityContextGlobal.allowUnconfined,
        },
    );
}

pub fn deinit(self: *OutputPowerGlobal) void {
    std.debug.assert(self.controls.items.len == 0 and self.active == null);
    self.server.removeGlobal(self.global_name) catch unreachable;
    self.controls.deinit(self.allocator);
    self.* = undefined;
}

/// Invalidates the physical output's control while leaving it destroyable.
pub fn outputRemoved(self: *OutputPowerGlobal) void {
    if (self.active) |control| fail(control);
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *OutputPowerGlobal = @ptrCast(@alignCast(context));
    _ = client.createResource(id, &generated.zwlr_output_power_manager_v1, version, .{
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
    const self: *OutputPowerGlobal = @ptrCast(@alignCast(context));
    switch (try generated.zwlr_output_power_manager_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .get_output_power => |request| try createControl(self, client, request.id, request.output),
    }
}

fn createControl(self: *OutputPowerGlobal, client: *Server.Client, id: u32, output_id: u32) !void {
    const control = self.allocator.create(Control) catch return client.postNoMemory();
    errdefer self.allocator.destroy(control);
    self.controls.ensureUnusedCapacity(self.allocator, 1) catch return client.postNoMemory();
    const mode = self.listener.mode(self.listener.context);
    control.* = .{
        .owner = self,
        .client = client,
        .resource = undefined,
        .valid = self.output.bindingHandle(client, output_id) != null and
            self.active == null and mode != null,
    };
    control.resource = client.createResource(id, &generated.zwlr_output_power_v1, 1, .{
        .context = control,
        .dispatch = dispatchControl,
        .destroy = destroyControl,
    }) catch return client.postNoMemory();
    self.controls.appendAssumeCapacity(control);
    if (control.valid) {
        self.active = control;
        try sendMode(control, mode.?);
    } else {
        try generated.zwlr_output_power_v1_types.events.failed(&client.connection, control.resource);
    }
}

fn dispatchControl(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const control: *Control = @ptrCast(@alignCast(context));
    switch (try generated.zwlr_output_power_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .set_mode => |request| {
            if (request.mode > 1) return client.postError(
                resource,
                @intFromEnum(generated.zwlr_output_power_v1_types.@"error".invalid_mode),
                "invalid output power mode",
            );
            if (!control.valid) return;
            const powered = request.mode == 1;
            const current = control.owner.listener.mode(control.owner.listener.context) orelse {
                fail(control);
                return;
            };
            if (current == powered) return;
            control.owner.listener.set_mode(control.owner.listener.context, powered) catch {
                fail(control);
                return;
            };
            try sendMode(control, powered);
        },
    }
}

fn sendMode(control: *Control, powered: bool) !void {
    try generated.zwlr_output_power_v1_types.events.mode(
        &control.client.connection,
        control.resource,
        @intFromBool(powered),
    );
}

fn fail(control: *Control) void {
    if (!control.valid) return;
    control.valid = false;
    if (control.owner.active == control) control.owner.active = null;
    generated.zwlr_output_power_v1_types.events.failed(
        &control.client.connection,
        control.resource,
    ) catch control.client.postNoMemory() catch {};
}

fn destroyControl(context: *anyopaque, _: *Server.Client, _: wayring.ObjectHandle) void {
    const control: *Control = @ptrCast(@alignCast(context));
    const owner = control.owner;
    if (owner.active == control) owner.active = null;
    for (owner.controls.items, 0..) |candidate, index| {
        if (candidate != control) continue;
        _ = owner.controls.orderedRemove(index);
        owner.allocator.destroy(control);
        return;
    }
    unreachable;
}

const TestListener = struct {
    mode_value: ?bool = true,
    set_count: usize = 0,
    fail_set: bool = false,

    fn mode(context: *anyopaque) ?bool {
        const self: *TestListener = @ptrCast(@alignCast(context));
        return self.mode_value;
    }

    fn setMode(context: *anyopaque, powered: bool) !void {
        const self: *TestListener = @ptrCast(@alignCast(context));
        self.set_count += 1;
        if (self.fail_set) return error.TestSetFailed;
        self.mode_value = powered;
    }

    fn listener(self: *TestListener) Listener {
        return .{ .context = self, .mode = mode, .set_mode = setMode };
    }
};

fn initTestOutput(output: *OutputGlobal, server: *Server) !void {
    try output.init(std.testing.allocator, server, .{
        .mode_size = .{ .width = 1280, .height = 720 },
        .logical_size = .{ .width = 1280, .height = 720 },
        .physical_size = .{ .width = 300, .height = 170 },
        .refresh_millihertz = 60_000,
        .scale = 1,
        .name = "TEST-1",
        .description = "Test output",
        .model = "test",
    });
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

const BoundTestGlobals = struct {
    registry: wayring.ObjectHandle,
    output: wayring.ObjectHandle,
    manager: wayring.ObjectHandle,
};

fn bindTestGlobals(
    peer: *wayring.Connection,
    client: *Server.Client,
    output_name: u32,
    manager_name: u32,
    first_id: u32,
) !BoundTestGlobals {
    const core = @import("wayring-core");
    _ = try core.bootstrapDisplay(peer);
    const registry: wayring.ObjectHandle = .{
        .id = first_id,
        .generation = try core.getRegistry(peer, first_id),
    };
    try transferToServer(peer, client);
    try transferFromServer(peer, client);
    var found_output = false;
    var found_manager = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const event = try core.decodeRegistryEvent(&message, registry.id);
        if (event == .global) {
            found_output = found_output or event.global.name == output_name;
            found_manager = found_manager or event.global.name == manager_name;
        }
    }
    try std.testing.expect(found_output);
    try std.testing.expect(found_manager);
    const output: wayring.ObjectHandle = .{
        .id = first_id + 1,
        .generation = try core.bind(peer, registry.id, output_name, generated.wl_output.name, 4, first_id + 1, &generated.wl_output),
    };
    const manager: wayring.ObjectHandle = .{
        .id = first_id + 2,
        .generation = try core.bind(peer, registry.id, manager_name, generated.zwlr_output_power_manager_v1.name, 1, first_id + 2, &generated.zwlr_output_power_manager_v1),
    };
    try transferToServer(peer, client);
    try transferFromServer(peer, client);
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        _ = try generated.wl_output_types.decodeEvent(peer, output, &message);
    }
    return .{ .registry = registry, .output = output, .manager = manager };
}

fn expectPowerEvent(
    peer: *wayring.Connection,
    child: wayring.ObjectHandle,
    expected: enum { on, off, failed },
) !void {
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id != child.id) continue;
        const event = try generated.zwlr_output_power_v1_types.decodeEvent(peer, child, &message);
        switch (expected) {
            .on => try std.testing.expect(event == .mode and event.mode.mode == 1),
            .off => try std.testing.expect(event == .mode and event.mode.mode == 0),
            .failed => try std.testing.expect(event == .failed),
        }
        return;
    }
    return error.MissingPowerEvent;
}

test "output power global filters confined clients" {
    const core = @import("wayring-core");
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var transport: @import("wayring-server-uring") = undefined;
    var security: SecurityContextGlobal = undefined;
    try security.init(std.testing.allocator, &server, &transport);
    defer security.deinit();
    var output: OutputGlobal = undefined;
    try initTestOutput(&output, &server);
    defer output.deinit();
    var listener: TestListener = .{};
    var power: OutputPowerGlobal = undefined;
    try power.init(std.testing.allocator, &server, &output, &security, listener.listener());
    defer power.deinit();

    const confined = try server.createClientWithProvenance(
        try SecurityContextGlobal.Testing.confinedProvenance(std.testing.allocator),
    );
    defer server.destroyClient(confined) catch {};
    var peer = wayring.Connection.init(std.testing.allocator, .client, wayring.default_max_frame_size);
    defer peer.deinit();
    _ = try core.bootstrapDisplay(&peer);
    const registry: wayring.ObjectHandle = .{ .id = 2, .generation = try core.getRegistry(&peer, 2) };
    try transferToServer(&peer, confined);
    try transferFromServer(&peer, confined);
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const event = try core.decodeRegistryEvent(&message, registry.id);
        if (event == .global) try std.testing.expect(!std.mem.eql(
            u8,
            event.global.interface,
            generated.zwlr_output_power_manager_v1.name,
        ));
    }
    _ = try core.bind(&peer, registry.id, power.global_name, generated.zwlr_output_power_manager_v1.name, 1, 3, &generated.zwlr_output_power_manager_v1);
    try std.testing.expectError(error.ProtocolError, transferToServer(&peer, confined));
}

test "output power controls are exclusive and survive manager destruction" {
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var transport: @import("wayring-server-uring") = undefined;
    var security: SecurityContextGlobal = undefined;
    try security.init(std.testing.allocator, &server, &transport);
    defer security.deinit();
    var output: OutputGlobal = undefined;
    try initTestOutput(&output, &server);
    defer output.deinit();
    var listener: TestListener = .{};
    var power: OutputPowerGlobal = undefined;
    try power.init(std.testing.allocator, &server, &output, &security, listener.listener());
    defer power.deinit();
    const client = try server.createClient();
    defer server.destroyClient(client) catch unreachable;
    var peer = wayring.Connection.init(std.testing.allocator, .client, wayring.default_max_frame_size);
    defer peer.deinit();
    const bound = try bindTestGlobals(&peer, client, output.global_name, power.global_name, 2);

    const first = try generated.zwlr_output_power_manager_v1_types.requests.get_output_power(&peer, bound.manager, bound.output);
    try generated.zwlr_output_power_manager_v1_types.requests.destroy(&peer, bound.manager);
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    try expectPowerEvent(&peer, first, .on);
    while (peer.popMessage()) |popped| {
        var message = popped;
        message.deinit();
    }
    try generated.zwlr_output_power_v1_types.requests.set_mode(&peer, first, 1);
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    try std.testing.expectEqual(@as(usize, 0), listener.set_count);
    try std.testing.expect(peer.popMessage() == null);
    try generated.zwlr_output_power_v1_types.requests.set_mode(&peer, first, 0);
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    try std.testing.expectEqual(@as(usize, 1), listener.set_count);
    try expectPowerEvent(&peer, first, .off);

    const core = @import("wayring-core");
    const manager_two: wayring.ObjectHandle = .{ .id = 6, .generation = try core.bind(&peer, bound.registry.id, power.global_name, generated.zwlr_output_power_manager_v1.name, 1, 6, &generated.zwlr_output_power_manager_v1) };
    const duplicate = try generated.zwlr_output_power_manager_v1_types.requests.get_output_power(&peer, manager_two, bound.output);
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    try expectPowerEvent(&peer, duplicate, .failed);
    try generated.zwlr_output_power_v1_types.requests.set_mode(&peer, duplicate, 1);
    try generated.zwlr_output_power_v1_types.requests.destroy(&peer, duplicate);
    try generated.zwlr_output_power_v1_types.requests.destroy(&peer, first);
    try transferToServer(&peer, client);
    try std.testing.expectEqual(@as(usize, 0), power.controls.items.len);

    const replacement = try generated.zwlr_output_power_manager_v1_types.requests.get_output_power(&peer, manager_two, bound.output);
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    try expectPowerEvent(&peer, replacement, .off);
    power.outputRemoved();
    try transferFromServer(&peer, client);
    try expectPowerEvent(&peer, replacement, .failed);
    try generated.zwlr_output_power_v1_types.requests.set_mode(&peer, replacement, 1);
    try generated.zwlr_output_power_v1_types.requests.destroy(&peer, replacement);
    try generated.zwlr_output_power_manager_v1_types.requests.destroy(&peer, manager_two);
    try transferToServer(&peer, client);
}

test "output power rejects invalid modes and reports setter failure" {
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var transport: @import("wayring-server-uring") = undefined;
    var security: SecurityContextGlobal = undefined;
    try security.init(std.testing.allocator, &server, &transport);
    defer security.deinit();
    var output: OutputGlobal = undefined;
    try initTestOutput(&output, &server);
    defer output.deinit();
    var listener: TestListener = .{};
    var power: OutputPowerGlobal = undefined;
    try power.init(std.testing.allocator, &server, &output, &security, listener.listener());
    defer power.deinit();
    const first_client = try server.createClient();
    var first_client_alive = true;
    defer if (first_client_alive) server.destroyClient(first_client) catch unreachable;
    const second_client = try server.createClient();
    defer server.destroyClient(second_client) catch unreachable;
    var first_peer = wayring.Connection.init(std.testing.allocator, .client, wayring.default_max_frame_size);
    defer first_peer.deinit();
    var second_peer = wayring.Connection.init(std.testing.allocator, .client, wayring.default_max_frame_size);
    defer second_peer.deinit();
    const first = try bindTestGlobals(&first_peer, first_client, output.global_name, power.global_name, 2);
    const second = try bindTestGlobals(&second_peer, second_client, output.global_name, power.global_name, 10);

    const child = try generated.zwlr_output_power_manager_v1_types.requests.get_output_power(&first_peer, first.manager, first.output);
    try transferToServer(&first_peer, first_client);
    try transferFromServer(&first_peer, first_client);
    try expectPowerEvent(&first_peer, child, .on);
    try generated.zwlr_output_power_v1_types.requests.set_mode(&first_peer, child, 2);
    try std.testing.expectError(error.ProtocolError, transferToServer(&first_peer, first_client));
    try std.testing.expectEqual(Server.ClientState.protocol_error, first_client.state);

    try server.destroyClient(first_client);
    first_client_alive = false;
    listener.fail_set = true;
    const replacement = try generated.zwlr_output_power_manager_v1_types.requests.get_output_power(&second_peer, second.manager, second.output);
    try transferToServer(&second_peer, second_client);
    try transferFromServer(&second_peer, second_client);
    try expectPowerEvent(&second_peer, replacement, .on);
    try generated.zwlr_output_power_v1_types.requests.set_mode(&second_peer, replacement, 0);
    try transferToServer(&second_peer, second_client);
    try transferFromServer(&second_peer, second_client);
    try std.testing.expectEqual(@as(usize, 1), listener.set_count);
    try expectPowerEvent(&second_peer, replacement, .failed);
    try generated.zwlr_output_power_v1_types.requests.destroy(&second_peer, replacement);
    try generated.zwlr_output_power_manager_v1_types.requests.destroy(&second_peer, second.manager);
    try transferToServer(&second_peer, second_client);
}
