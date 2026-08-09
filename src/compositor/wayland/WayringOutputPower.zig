//! Restricted scanner-backed output power management over canonical outputs.

const WayringOutputPower = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayring = @import("wayring");
const OutputLayout = @import("../output_layout.zig");

const server = wayring.server;
const wire = wayring.wire;

pub const Listener = struct {
    context: *anyopaque,
    reserve: *const fn (*anyopaque, OutputLayout.Id) bool,
    release: *const fn (*anyopaque, OutputLayout.Id) void,
    powered: *const fn (*anyopaque, OutputLayout.Id) ?bool,
    set_powered: *const fn (*anyopaque, OutputLayout.Id, bool) bool,
};

pub const Resolver = struct {
    context: *anyopaque,
    output_id: *const fn (*anyopaque, *server.Client, u32) ?OutputLayout.Id,
};

const Manager = struct {
    owner: *WayringOutputPower,
    client: *server.Client,
    resource: protocol.zwlr_output_power_manager_v1.Resource,
};

const Control = struct {
    owner: *WayringOutputPower,
    client: *server.Client,
    resource: protocol.zwlr_output_power_v1.Resource,
    output: ?OutputLayout.Id,
    failed: bool = false,
};

allocator: std.mem.Allocator,
protocol_server: *server.Server,
resolver: Resolver,
authorized_uid: std.os.linux.uid_t,
listener: Listener,
global: ?*const server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
controls: std.ArrayList(*Control) = .empty,

pub fn init(self: *WayringOutputPower, allocator: std.mem.Allocator, protocol_server: *server.Server, resolver: Resolver, authorized_uid: std.os.linux.uid_t, listener: Listener) void {
    self.* = .{ .allocator = allocator, .protocol_server = protocol_server, .resolver = resolver, .authorized_uid = authorized_uid, .listener = listener };
}

pub fn publish(self: *WayringOutputPower) !void {
    std.debug.assert(self.global == null);
    self.global = try self.protocol_server.addGlobalWithOptions(protocol.zwlr_output_power_manager_v1, 1, WayringOutputPower, self, bind, .{ .visibility = .restricted });
}

pub fn unpublish(self: *WayringOutputPower) void {
    self.protocol_server.removeGlobal(self.global orelse unreachable) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}

pub fn globalFilter(self: *WayringOutputPower, client: *const server.Client, global: *const server.Server.Global) bool {
    return global.visibility() != .restricted or client.isAuthorizedDirectPeer(self.authorized_uid);
}

pub fn removeOutput(self: *WayringOutputPower, output: OutputLayout.Id) void {
    for (self.controls.items) |control| {
        const current = control.output orelse continue;
        if (!std.meta.eql(current, output)) continue;
        fail(control);
    }
}

fn bind(client: *server.Client, id: u32, version: u32, self: *WayringOutputPower) !void {
    try self.managers.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Manager);
    errdefer self.allocator.destroy(value);
    value.* = .{ .owner = self, .client = client, .resource = .init(self.allocator, id, version, .client, client.ownerHooks()) };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Manager, value, managerRequest, null);
    try client.materialize(&value.resource.runtime);
    self.managers.appendAssumeCapacity(value);
}

fn managerRequest(_: *protocol.zwlr_output_power_manager_v1.Resource, request: protocol.zwlr_output_power_manager_v1.Request, manager: *Manager) !void {
    switch (request) {
        .destroy => manager.owner.destroyManager(manager),
        .get_output_power => |args| try manager.owner.createControl(manager, args.id, args.output),
    }
}

fn createControl(self: *WayringOutputPower, manager: *Manager, id: u32, output_object: u32) !void {
    try self.controls.ensureUnusedCapacity(self.allocator, 1);
    const control = try self.allocator.create(Control);
    errdefer self.allocator.destroy(control);
    var output = self.resolver.output_id(self.resolver.context, manager.client, output_object);
    if (output) |candidate| for (self.controls.items) |existing| {
        if (existing.output) |active| if (std.meta.eql(active, candidate)) {
            output = null;
            break;
        };
    };
    if (output) |candidate| {
        if (!self.listener.reserve(self.listener.context, candidate)) output = null;
    }
    errdefer if (output) |candidate| self.listener.release(self.listener.context, candidate);
    control.* = .{
        .owner = self,
        .client = manager.client,
        .resource = .init(self.allocator, id, manager.resource.version(), .client, manager.client.ownerHooks()),
        .output = output,
    };
    errdefer {
        control.resource.destroy();
        control.resource.deinit();
    }
    try control.resource.setHandler(Control, control, controlRequest, null);
    try manager.client.materialize(&control.resource.runtime);
    self.controls.appendAssumeCapacity(control);
    const canonical = output orelse return fail(control);
    const powered = self.listener.powered(self.listener.context, canonical) orelse return fail(control);
    sendMode(control, powered);
}

fn controlRequest(_: *protocol.zwlr_output_power_v1.Resource, request: protocol.zwlr_output_power_v1.Request, control: *Control) !void {
    switch (request) {
        .destroy => control.owner.destroyControl(control),
        .set_mode => |args| {
            const powered = switch (args.mode) {
                protocol.zwlr_output_power_v1.mode.off => false,
                protocol.zwlr_output_power_v1.mode.on => true,
                else => {
                    control.client.postProtocolError(&control.resource.runtime, @intCast(protocol.zwlr_output_power_v1.@"error".invalid_mode), "invalid output power mode");
                    return;
                },
            };
            const output = control.output orelse return;
            const current = control.owner.listener.powered(control.owner.listener.context, output) orelse return fail(control);
            if (current == powered) return;
            if (!control.owner.listener.set_powered(control.owner.listener.context, output, powered)) return fail(control);
            sendMode(control, powered);
        },
    }
}

fn sendMode(control: *Control, powered: bool) void {
    protocol.zwlr_output_power_v1.@"send:mode"(&control.resource, if (powered) @intCast(protocol.zwlr_output_power_v1.mode.on) else @intCast(protocol.zwlr_output_power_v1.mode.off)) catch |err| eventFailed(control, err);
}

fn fail(control: *Control) void {
    if (control.failed) return;
    control.failed = true;
    if (control.output) |output|
        control.owner.listener.release(control.owner.listener.context, output);
    control.output = null;
    protocol.zwlr_output_power_v1.@"send:failed"(&control.resource) catch |err| eventFailed(control, err);
}

fn eventFailed(control: *Control, _: anyerror) void {
    control.client.postOutOfMemory(&control.resource.runtime, "queueing output power event");
}

pub fn destroyClientResources(self: *WayringOutputPower, client: *server.Client) void {
    var i = self.controls.items.len;
    while (i > 0) : (i -= 1) if (self.controls.items[i - 1].client == client) self.destroyControl(self.controls.items[i - 1]);
    i = self.managers.items.len;
    while (i > 0) : (i -= 1) if (self.managers.items[i - 1].client == client) self.destroyManager(self.managers.items[i - 1]);
}

fn destroyControl(self: *WayringOutputPower, value: *Control) void {
    if (value.output) |output|
        self.listener.release(self.listener.context, output);
    _ = self.controls.swapRemove(std.mem.indexOfScalar(*Control, self.controls.items, value).?);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}

fn destroyManager(self: *WayringOutputPower, value: *Manager) void {
    _ = self.managers.swapRemove(std.mem.indexOfScalar(*Manager, self.managers.items, value).?);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}

pub fn deinit(self: *WayringOutputPower) void {
    std.debug.assert(self.global == null and self.managers.items.len == 0 and self.controls.items.len == 0);
    self.managers.deinit(self.allocator);
    self.controls.deinit(self.allocator);
    self.* = undefined;
}

test "generated output power requests carry typed objects and mode validation" {
    try std.testing.expect(protocol.zwlr_output_power_manager_v1.request_0_arguments[0].kind == .new_id);
    try std.testing.expectEqualStrings("wl_output", protocol.zwlr_output_power_manager_v1.request_0_arguments[1].kind.object.interface.?.name);
    try std.testing.expectEqual(@as(i64, 1), protocol.zwlr_output_power_v1.@"error".invalid_mode);
}

const TestBackend = struct {
    powered_value: ?bool = false,
    set_succeeds: bool = true,
    reserved: bool = false,
    query_calls: usize = 0,
    set_calls: usize = 0,

    fn reserve(context: *anyopaque, _: OutputLayout.Id) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.reserved) return false;
        self.reserved = true;
        return true;
    }

    fn release(context: *anyopaque, _: OutputLayout.Id) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        std.debug.assert(self.reserved);
        self.reserved = false;
    }

    fn powered(context: *anyopaque, _: OutputLayout.Id) ?bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.query_calls += 1;
        return self.powered_value;
    }

    fn setPowered(context: *anyopaque, _: OutputLayout.Id, value: bool) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.set_calls += 1;
        if (self.set_succeeds) self.powered_value = value;
        return self.set_succeeds;
    }
};

const OutputPowerHarness = struct {
    const output_id: OutputLayout.Id = .{ .index = 7, .generation = 3 };

    host: server.Server,
    backend: TestBackend,
    adapter: WayringOutputPower,
    managed: *server.CoreClient,
    output_resource: protocol.wl_output.Resource,
    unresolved_resource: protocol.wl_output.Resource,

    fn init(self: *@This()) !void {
        self.host = .init(std.testing.allocator);
        self.backend = .{};
        self.managed = try server.CoreClient.create(std.testing.allocator, &self.host, .{});
        self.output_resource = .init(std.testing.allocator, 2, 1, .client, self.client().ownerHooks());
        try self.client().installClientInitial(2, &self.output_resource.runtime);
        self.unresolved_resource = .init(std.testing.allocator, 3, 1, .client, self.client().ownerHooks());
        try self.client().installClientInitial(3, &self.unresolved_resource.runtime);
        self.adapter.init(std.testing.allocator, &self.host, .{ .context = self, .output_id = resolve }, 0, .{
            .context = &self.backend,
            .reserve = TestBackend.reserve,
            .release = TestBackend.release,
            .powered = TestBackend.powered,
            .set_powered = TestBackend.setPowered,
        });
    }

    fn deinit(self: *@This()) void {
        self.adapter.destroyClientResources(self.client());
        self.output_resource.destroy();
        self.output_resource.deinit();
        self.unresolved_resource.destroy();
        self.unresolved_resource.deinit();
        self.managed.destroy();
        self.adapter.deinit();
        self.host.deinit();
    }

    fn client(self: *@This()) *server.Client {
        return self.managed.client();
    }

    fn resolve(context: *anyopaque, candidate_client: *server.Client, object_id: u32) ?OutputLayout.Id {
        const self: *@This() = @ptrCast(@alignCast(context));
        return if (candidate_client == self.client() and object_id == 2) output_id else null;
    }

    fn bindManager(self: *@This()) !void {
        const value = try std.testing.allocator.create(Manager);
        errdefer std.testing.allocator.destroy(value);
        value.* = .{ .owner = &self.adapter, .client = self.client(), .resource = .init(std.testing.allocator, 4, 1, .client, self.client().ownerHooks()) };
        errdefer value.resource.deinit();
        try value.resource.setHandler(Manager, value, managerRequest, null);
        try self.client().installClientInitial(4, &value.resource.runtime);
        try self.adapter.managers.append(std.testing.allocator, value);
    }

    fn send(self: *@This(), object_id: u32, opcode: u16, descriptor: *const wire.MessageDescriptor, values: []const wire.Value) !void {
        var output: wire.Output = .init(std.testing.allocator);
        defer output.deinit();
        try output.enqueue(object_id, opcode, descriptor, values);
        const batch = (try output.beginSend()).?;
        try self.client().receive(batch.bytes, &.{});
        try output.completeSend(batch.token, batch.bytes.len);
        try self.client().dispatch();
    }

    fn getControl(self: *@This(), id: u32, output_object: u32) !void {
        try self.send(4, 0, &protocol.zwlr_output_power_manager_v1.request_messages[0], &.{
            .{ .new_id = .{ .typed = id } },
            .{ .object = output_object },
        });
    }

    fn setMode(self: *@This(), id: u32, mode: u32) !void {
        try self.send(id, 0, &protocol.zwlr_output_power_v1.request_messages[0], &.{.{ .uint = mode }});
    }

    fn drain(self: *@This()) !usize {
        var bytes: usize = 0;
        while (try self.client().beginSend()) |batch| {
            bytes += batch.bytes.len;
            try self.client().completeSend(batch.token, batch.bytes.len);
        }
        return bytes;
    }
};

test "output power dispatch initializes transitions and ignores no-op mode" {
    var harness: OutputPowerHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bindManager();
    try harness.getControl(5, 2);
    try std.testing.expect((try harness.drain()) > 0);
    try std.testing.expectEqual(@as(usize, 1), harness.backend.query_calls);

    try harness.setMode(5, @intCast(protocol.zwlr_output_power_v1.mode.on));
    try std.testing.expectEqual(@as(usize, 1), harness.backend.set_calls);
    try std.testing.expect((try harness.drain()) > 0);
    try harness.setMode(5, @intCast(protocol.zwlr_output_power_v1.mode.on));
    try std.testing.expectEqual(@as(usize, 1), harness.backend.set_calls);
    try std.testing.expectEqual(@as(usize, 0), try harness.drain());
}

test "duplicate and unresolved output power controls fail without replacing original" {
    var harness: OutputPowerHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bindManager();
    try harness.getControl(5, 2);
    _ = try harness.drain();
    try harness.getControl(6, 2);
    try std.testing.expect((try harness.drain()) > 0);
    try harness.getControl(7, 3);
    try std.testing.expect((try harness.drain()) > 0);
    try std.testing.expect(harness.adapter.controls.items[0].output != null);
    try std.testing.expect(harness.adapter.controls.items[1].output == null);
    try std.testing.expect(harness.adapter.controls.items[2].output == null);
}

test "output removal fails exactly once and manager and control lists destroy independently" {
    var harness: OutputPowerHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bindManager();
    try harness.getControl(5, 2);
    _ = try harness.drain();
    harness.adapter.removeOutput(OutputPowerHarness.output_id);
    try std.testing.expect((try harness.drain()) > 0);
    harness.adapter.removeOutput(OutputPowerHarness.output_id);
    try std.testing.expectEqual(@as(usize, 0), try harness.drain());
    try harness.setMode(5, @intCast(protocol.zwlr_output_power_v1.mode.on));
    try std.testing.expectEqual(@as(usize, 0), harness.backend.set_calls);
    try harness.send(4, 1, &protocol.zwlr_output_power_manager_v1.request_messages[1], &.{});
    try std.testing.expectEqual(@as(usize, 0), harness.adapter.managers.items.len);
    try std.testing.expectEqual(@as(usize, 1), harness.adapter.controls.items.len);
    try harness.send(5, 1, &protocol.zwlr_output_power_v1.request_messages[1], &.{});
    try std.testing.expectEqual(@as(usize, 0), harness.adapter.controls.items.len);
}

test "invalid output power mode posts generated protocol error" {
    var harness: OutputPowerHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bindManager();
    try harness.getControl(5, 2);
    _ = try harness.drain();
    try harness.setMode(5, 27);
    const fatal = harness.client().fatal().?;
    try std.testing.expectEqual(server.Fatal.Kind.protocol, fatal.kind);
    try std.testing.expectEqual(@as(?u32, @intCast(protocol.zwlr_output_power_v1.@"error".invalid_mode)), fatal.protocol_code);
    try std.testing.expectEqual(@as(usize, 0), harness.backend.set_calls);
}

test "output power disconnect cleanup empties all adapter resources" {
    var harness: OutputPowerHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bindManager();
    try harness.getControl(5, 2);
    try std.testing.expect(harness.backend.reserved);
    try std.testing.expect(!TestBackend.reserve(&harness.backend, OutputPowerHarness.output_id));
    harness.adapter.destroyClientResources(harness.client());
    try std.testing.expectEqual(@as(usize, 0), harness.adapter.managers.items.len);
    try std.testing.expectEqual(@as(usize, 0), harness.adapter.controls.items.len);
    try std.testing.expect(!harness.backend.reserved);
}
