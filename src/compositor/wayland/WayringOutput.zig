//! Compositor-owned Wayring adapter for the canonical output layout.
//!
//! Globals and resources deliberately have different lifetimes: unplugging an
//! output retires its global and makes existing bindings release-only, while
//! the client continues to own those resources until release or disconnect.

const WayringOutput = @This();

const std = @import("std");
const core = @import("wayring-core-protocol");
const wayland = @import("wayland");
const wayring = @import("wayring");
const SurfaceRegistry = @import("../SurfaceRegistry.zig");
const Output = @import("output.zig");
const OutputLayout = @import("output_layout.zig");
const Surface = @import("surface.zig");
const WayringCompositor = @import("WayringCompositor.zig");

const server = wayring.server;
const wire = wayring.wire;
const wl = wayland.server.wl;

allocator: std.mem.Allocator,
protocol_server: *server.Server,
layout: *OutputLayout,
compositor: *WayringCompositor,
adapters: std.ArrayList(*Adapter) = .empty,

const Binding = struct {
    resource: core.wl_output.Resource,
    client: *server.Client,
    adapter: *Adapter,
};

const Adapter = struct {
    manager: *WayringOutput,
    id: OutputLayout.Id,
    output: *Output,
    global: *const server.Server.Global,
    bindings: std.ArrayList(*Binding) = .empty,
    retired: bool = false,
};

pub fn init(
    self: *WayringOutput,
    allocator: std.mem.Allocator,
    protocol_server: *server.Server,
    layout: *OutputLayout,
    compositor: *WayringCompositor,
) !void {
    self.* = .{
        .allocator = allocator,
        .protocol_server = protocol_server,
        .layout = layout,
        .compositor = compositor,
    };
    errdefer self.rollbackInit();

    var outputs = layout.iterator();
    while (outputs.next()) |entry| try self.publish(entry.id, entry.output);
    layout.setListener(.{
        .context = self,
        .added = layoutAdded,
        .removing = layoutRemoving,
    });
}

fn rollbackInit(self: *WayringOutput) void {
    while (self.adapters.items.len > 0) {
        const adapter = self.adapters.pop().?;
        adapter.output.clearDeliveryListener();
        self.protocol_server.removeGlobal(adapter.global) catch {};
        adapter.bindings.deinit(self.allocator);
        self.allocator.destroy(adapter);
    }
    self.adapters.deinit(self.allocator);
}

pub fn deinit(self: *WayringOutput) void {
    self.layout.clearListener();
    for (self.adapters.items) |adapter| {
        std.debug.assert(adapter.bindings.items.len == 0);
        if (!adapter.retired) {
            adapter.output.clearDeliveryListener();
            self.protocol_server.removeGlobal(adapter.global) catch |err| switch (err) {
                error.AlreadyRemoved => {},
                error.ForeignGlobal => unreachable,
            };
        }
        adapter.bindings.deinit(self.allocator);
        self.allocator.destroy(adapter);
    }
    self.adapters.deinit(self.allocator);
    self.* = undefined;
}

pub fn destroyClientResources(self: *WayringOutput, client: *server.Client) void {
    for (self.adapters.items) |adapter| {
        var index = adapter.bindings.items.len;
        while (index > 0) {
            index -= 1;
            const binding = adapter.bindings.items[index];
            if (binding.client == client) destroyBinding(binding);
        }
    }
}

fn publish(self: *WayringOutput, id: OutputLayout.Id, output: *Output) !void {
    // Nothing may fail after addGlobal publishes to existing registries.
    try self.adapters.ensureUnusedCapacity(self.allocator, 1);
    const adapter = try self.allocator.create(Adapter);
    errdefer self.allocator.destroy(adapter);
    adapter.* = .{
        .manager = self,
        .id = id,
        .output = output,
        .global = undefined,
    };
    adapter.global = try self.protocol_server.addGlobal(core.wl_output, 4, Adapter, adapter, bind);
    self.adapters.appendAssumeCapacity(adapter);
    output.setDeliveryListener(.{
        .context = adapter,
        .configured = configured,
        .entered = entered,
        .left = left,
    });
}

fn layoutAdded(context: *anyopaque, id: OutputLayout.Id) error{OutOfMemory}!void {
    const self: *WayringOutput = @ptrCast(@alignCast(context));
    self.publish(id, self.layout.get(id).?) catch return error.OutOfMemory;
}

fn layoutRemoving(context: *anyopaque, id: OutputLayout.Id) void {
    const self: *WayringOutput = @ptrCast(@alignCast(context));
    const adapter = self.findAdapter(id) orelse unreachable;
    self.protocol_server.removeGlobal(adapter.global) catch unreachable;
    var memberships = adapter.output.membershipIterator();
    while (memberships.next()) |surface_id| membershipEvent(adapter, surface_id, false);
    adapter.output.clearDeliveryListener();
    adapter.retired = true;
}

fn findAdapter(self: *WayringOutput, id: OutputLayout.Id) ?*Adapter {
    for (self.adapters.items) |adapter| if (std.meta.eql(adapter.id, id)) return adapter;
    return null;
}

fn bind(client: *server.Client, id: u32, version: u32, adapter: *Adapter) !void {
    std.debug.assert(!adapter.retired);
    try adapter.bindings.ensureUnusedCapacity(adapter.manager.allocator, 1);
    const binding = try adapter.manager.allocator.create(Binding);
    errdefer adapter.manager.allocator.destroy(binding);
    binding.* = .{
        .resource = .init(adapter.manager.allocator, id, version, .client, client.ownerHooks()),
        .client = client,
        .adapter = adapter,
    };
    errdefer {
        binding.resource.destroy();
        binding.resource.deinit();
    }
    try binding.resource.setHandler(Binding, binding, handleRequest, null);
    try client.materialize(&binding.resource.runtime);
    adapter.bindings.appendAssumeCapacity(binding);
    sendInitial(binding);
}

fn sendInitial(binding: *Binding) void {
    const snapshot = binding.adapter.output.snapshot();
    sendGeometry(binding, snapshot) catch |err| return eventFailure(binding, err, "queueing initial wl_output geometry");
    sendMode(binding, snapshot) catch |err| return eventFailure(binding, err, "queueing initial wl_output mode");
    if (binding.resource.version() >= 2)
        core.wl_output.@"send:scale"(&binding.resource, snapshot.scale) catch |err| return eventFailure(binding, err, "queueing initial wl_output scale");
    if (binding.resource.version() >= 4) {
        core.wl_output.@"send:name"(&binding.resource, snapshot.name) catch |err| return eventFailure(binding, err, "queueing initial wl_output name");
        core.wl_output.@"send:description"(&binding.resource, snapshot.description) catch |err| return eventFailure(binding, err, "queueing initial wl_output description");
    }
    if (binding.resource.version() >= 2)
        core.wl_output.@"send:done"(&binding.resource) catch |err| return eventFailure(binding, err, "queueing initial wl_output done");
    var memberships = binding.adapter.output.membershipIterator();
    while (memberships.next()) |surface_id| membershipEventToBinding(binding, surface_id, true);
}

fn configured(context: *anyopaque, snapshot: Output.Snapshot, changes: Output.Changes) void {
    const adapter: *Adapter = @ptrCast(@alignCast(context));
    for (adapter.bindings.items) |binding| {
        if (changes.geometry) sendGeometry(binding, snapshot) catch |err| {
            eventFailure(binding, err, "queueing wl_output geometry");
            continue;
        };
        if (changes.mode) sendMode(binding, snapshot) catch |err| {
            eventFailure(binding, err, "queueing wl_output mode");
            continue;
        };
        if (changes.scale and binding.resource.version() >= 2)
            core.wl_output.@"send:scale"(&binding.resource, snapshot.scale) catch |err| {
                eventFailure(binding, err, "queueing wl_output scale");
                continue;
            };
        if (binding.resource.version() >= 2)
            core.wl_output.@"send:done"(&binding.resource) catch |err| eventFailure(binding, err, "queueing wl_output done");
    }
}

fn entered(context: *anyopaque, id: WayringCompositor.SurfaceId) void {
    membershipEvent(@ptrCast(@alignCast(context)), id, true);
}

fn left(context: *anyopaque, id: WayringCompositor.SurfaceId) void {
    membershipEvent(@ptrCast(@alignCast(context)), id, false);
}

fn membershipEvent(adapter: *Adapter, id: WayringCompositor.SurfaceId, is_enter: bool) void {
    const endpoint = adapter.manager.compositor.surfaceEndpoint(id) orelse return;
    for (adapter.bindings.items) |binding| {
        if (binding.client == endpoint.client) sendMembership(binding, endpoint.resource, is_enter);
    }
}

fn membershipEventToBinding(binding: *Binding, id: WayringCompositor.SurfaceId, is_enter: bool) void {
    const endpoint = binding.adapter.manager.compositor.surfaceEndpoint(id) orelse return;
    if (binding.client == endpoint.client) sendMembership(binding, endpoint.resource, is_enter);
}

fn sendMembership(binding: *Binding, surface: *core.wl_surface.Resource, is_enter: bool) void {
    if (is_enter)
        core.wl_surface.@"send:enter"(surface, binding.resource.id()) catch |err| eventFailure(binding, err, "queueing wl_surface.enter")
    else
        core.wl_surface.@"send:leave"(surface, binding.resource.id()) catch |err| eventFailure(binding, err, "queueing wl_surface.leave");
}

fn sendGeometry(binding: *Binding, snapshot: Output.Snapshot) !void {
    try core.wl_output.@"send:geometry"(
        &binding.resource,
        snapshot.position.x,
        snapshot.position.y,
        @intCast(snapshot.physical_size.width),
        @intCast(snapshot.physical_size.height),
        @intCast(core.wl_output.subpixel.unknown),
        snapshot.make,
        snapshot.model,
        @intCast(core.wl_output.transform.normal),
    );
}

fn sendMode(binding: *Binding, snapshot: Output.Snapshot) !void {
    var flags: u32 = @intCast(core.wl_output.mode.current);
    if (snapshot.mode_preferred) flags |= @intCast(core.wl_output.mode.preferred);
    try core.wl_output.@"send:mode"(
        &binding.resource,
        flags,
        @intCast(snapshot.mode_size.width),
        @intCast(snapshot.mode_size.height),
        snapshot.refresh_millihertz,
    );
}

fn eventFailure(binding: *Binding, err: anyerror, message: []const u8) void {
    switch (err) {
        error.OutOfMemory, error.WriteFailed => binding.client.postOutOfMemory(&binding.resource.runtime, message),
        error.OutputSealed, error.ClientFatal => {},
        else => binding.client.postImplementationError(&binding.resource.runtime, message),
    }
}

fn handleRequest(_: *core.wl_output.Resource, request: core.wl_output.Request, binding: *Binding) !void {
    switch (request) {
        .release => destroyBinding(binding),
    }
}

fn destroyBinding(binding: *Binding) void {
    const adapter = binding.adapter;
    for (adapter.bindings.items, 0..) |candidate, index| {
        if (candidate != binding) continue;
        _ = adapter.bindings.orderedRemove(index);
        binding.resource.destroy();
        binding.resource.deinit();
        adapter.manager.allocator.destroy(binding);
        return;
    }
    unreachable;
}

test "generated wl_output gates and mode flags match the advertised contract" {
    try std.testing.expectEqual(@as(u32, 4), core.wl_output.interface.version);
    try std.testing.expectEqual(@as(u32, 3), core.wl_output.request_messages[0].since);
    try std.testing.expectEqual(@as(u32, 2), core.wl_output.event_messages[2].since);
    try std.testing.expectEqual(@as(u32, 2), core.wl_output.event_messages[3].since);
    try std.testing.expectEqual(@as(u32, 4), core.wl_output.event_messages[4].since);
    try std.testing.expectEqual(@as(i64, 3), core.wl_output.mode.current | core.wl_output.mode.preferred);
}

fn testSend(
    client: *server.Client,
    object_id: u32,
    opcode: u16,
    descriptor: *const wire.MessageDescriptor,
    values: []const wire.Value,
) !void {
    var output: wire.Output = .init(std.testing.allocator);
    defer output.deinit();
    try output.enqueue(object_id, opcode, descriptor, values);
    const batch = (try output.beginSend()).?;
    try client.receive(batch.bytes, &.{});
    try output.completeSend(batch.token, batch.bytes.len);
    try client.dispatch();
}

fn testDrain(client: *server.Client) !void {
    while (try client.beginSend()) |batch|
        try client.completeSend(batch.token, batch.bytes.len);
}

fn testGlobal(host: *const server.Server, interface: []const u8) *const server.Server.Global {
    var globals = host.iterator();
    while (globals.next()) |global|
        if (std.mem.eql(u8, global.interface().name, interface)) return global;
    unreachable;
}

const TestLog = struct {
    const Entry = struct {
        client: *server.Client,
        object_id: u32,
        name: []const u8,
        object_argument: ?u32,
    };

    entries: std.ArrayList(Entry) = .empty,

    fn observe(self: *TestLog, client: *server.Client, message: server.Client.ProtocolMessage) void {
        if (message.direction != .event) return;
        self.entries.append(std.testing.allocator, .{
            .client = client,
            .object_id = message.resource.id(),
            .name = message.descriptor.name,
            .object_argument = if (message.values.len == 1) switch (message.values[0]) {
                .object => |value| value,
                else => null,
            } else null,
        }) catch unreachable;
    }

    fn deinit(self: *TestLog) void {
        self.entries.deinit(std.testing.allocator);
    }

    fn clear(self: *TestLog) void {
        self.entries.clearRetainingCapacity();
    }

    fn namesFor(self: *const TestLog, client: *server.Client, object_id: u32, buffer: [][]const u8) []const []const u8 {
        var count: usize = 0;
        for (self.entries.items) |entry| {
            if (entry.client != client or entry.object_id != object_id) continue;
            buffer[count] = entry.name;
            count += 1;
        }
        return buffer[0..count];
    }
};

fn expectNames(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_name, actual_name|
        try std.testing.expectEqualStrings(expected_name, actual_name);
}

const TestSetup = struct {
    display: *wl.Server,
    registry: SurfaceRegistry,
    surfaces: Surface.Store,
    layout: OutputLayout,
    output_id: OutputLayout.Id,
    protocol_server: server.Server,
    compositor: WayringCompositor,
    outputs: WayringOutput,

    fn init(self: *TestSetup) !void {
        try self.initAllocators(std.testing.allocator, std.testing.allocator);
    }

    fn initAllocators(
        self: *TestSetup,
        output_allocator: std.mem.Allocator,
        protocol_allocator: std.mem.Allocator,
    ) !void {
        self.display = try wl.Server.create();
        self.registry = SurfaceRegistry.init(std.testing.allocator);
        self.surfaces = .{};
        self.layout.init(std.testing.allocator, self.display, &self.registry, &self.surfaces);
        self.output_id = try self.layout.add(.{
            .position = .{ .x = 11, .y = 22 },
            .size = .{ .width = 1280, .height = 720 },
            .mode_size = .{ .width = 2560, .height = 1440 },
            .physical_size = .{ .width = 600, .height = 340 },
            .refresh_millihertz = 60_000,
            .scale = 2,
            .name = "HEADLESS-1",
            .description = "Keywork headless output",
            .make = "keywork",
            .model = "headless",
        });
        self.protocol_server = .init(protocol_allocator);
        try self.compositor.init(
            std.testing.allocator,
            &self.protocol_server,
            &self.registry,
            null,
        );
        try self.outputs.init(
            output_allocator,
            &self.protocol_server,
            &self.layout,
            &self.compositor,
        );
    }

    fn deinit(self: *TestSetup) void {
        self.outputs.deinit();
        self.compositor.deinit();
        self.protocol_server.deinit();
        std.debug.assert(self.layout.remove(self.output_id));
        self.layout.deinit();
        self.surfaces.deinit(std.testing.allocator);
        self.registry.deinit();
        self.display.destroy();
        self.* = undefined;
    }

    fn prepareClient(self: *TestSetup, client: *server.Client, output_id: u32, version: u32) !void {
        try self.prepareRegistry(client);
        try self.bindOutput(client, output_id, version);
    }

    fn prepareRegistry(_: *TestSetup, client: *server.Client) !void {
        try testSend(client, 1, 1, &core.wl_display.request_messages[1], &.{.{ .new_id = .{ .typed = 2 } }});
        try testDrain(client);
    }

    fn bindOutput(self: *TestSetup, client: *server.Client, output_id: u32, version: u32) !void {
        try testSend(client, 2, 0, &core.wl_registry.request_messages[0], &.{
            .{ .uint = self.outputs.findAdapter(self.output_id).?.global.name() },
            .{ .new_id = .{ .generic = .{
                .interface = "wl_output",
                .version = version,
                .id = output_id,
            } } },
        });
    }
};

test "wl_output globals and negotiated bind bursts are exact from v1 through v4" {
    var setup: TestSetup = undefined;
    try setup.init();
    defer setup.deinit();

    const expected_globals = [_]struct { name: []const u8, version: u32 }{
        .{ .name = "wl_compositor", .version = 6 },
        .{ .name = "wl_shm", .version = 1 },
        .{ .name = "wl_subcompositor", .version = 1 },
        .{ .name = "wl_output", .version = 4 },
    };
    var globals = setup.protocol_server.iterator();
    for (expected_globals) |expected| {
        const global = globals.next().?;
        try std.testing.expectEqualStrings(expected.name, global.interface().name);
        try std.testing.expectEqual(expected.version, global.version());
    }
    try std.testing.expect(globals.next() == null);

    var log: TestLog = .{};
    defer log.deinit();
    const logger = try setup.protocol_server.addProtocolLogger(TestLog, &log, TestLog.observe);
    defer setup.protocol_server.removeProtocolLogger(logger);
    const expected = [_][]const []const u8{
        &.{ "geometry", "mode" },
        &.{ "geometry", "mode", "scale", "done" },
        &.{ "geometry", "mode", "scale", "done" },
        &.{ "geometry", "mode", "scale", "name", "description", "done" },
    };
    for (1..5) |version| {
        const managed = try server.CoreClient.create(std.testing.allocator, &setup.protocol_server, .{});
        const client = managed.client();
        try setup.prepareClient(client, 3, @intCast(version));
        var names_buffer: [8][]const u8 = undefined;
        try expectNames(
            expected[version - 1],
            log.namesFor(client, 3, &names_buffer),
        );
        if (version >= 3) {
            try testSend(client, 3, 0, &core.wl_output.request_messages[0], &.{});
            try std.testing.expect(client.lookup(3) == null);
        } else {
            try testSend(client, 3, 0, &core.wl_output.request_messages[0], &.{});
            try std.testing.expectEqual(server.Fatal.Kind.protocol, client.fatal().?.kind);
            try std.testing.expect(client.lookup(3) != null);
            setup.outputs.destroyClientResources(client);
        }
        setup.compositor.destroyClientResources(client);
        managed.destroy();
        log.clear();
    }
}

test "hotplug publication failures roll back without exposing an output" {
    for (0..2) |failure_kind| {
        var manager_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var protocol_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var setup: TestSetup = undefined;
        try setup.initAllocators(manager_allocator.allocator(), protocol_allocator.allocator());

        if (failure_kind == 0)
            manager_allocator.fail_index = manager_allocator.alloc_index
        else
            protocol_allocator.fail_index = protocol_allocator.alloc_index;
        try std.testing.expectError(error.OutOfMemory, setup.layout.add(.{
            .position = .{ .x = 1280 },
            .size = .{ .width = 800, .height = 600 },
            .physical_size = .{ .width = 400, .height = 300 },
            .scale = 1,
            .name = "HEADLESS-ROLLBACK",
            .description = "rollback fixture",
            .model = "headless",
        }));
        try std.testing.expect(if (failure_kind == 0)
            manager_allocator.has_induced_failure
        else
            protocol_allocator.has_induced_failure);
        var layout_entries = setup.layout.iterator();
        var layout_count: usize = 0;
        while (layout_entries.next()) |_| layout_count += 1;
        try std.testing.expectEqual(@as(usize, 1), layout_count);
        try std.testing.expectEqual(@as(usize, 1), setup.outputs.adapters.items.len);
        var globals = setup.protocol_server.iterator();
        var output_globals: usize = 0;
        while (globals.next()) |global| {
            if (std.mem.eql(u8, global.interface().name, "wl_output")) output_globals += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), output_globals);

        setup.deinit();
        try std.testing.expectEqual(manager_allocator.allocated_bytes, manager_allocator.freed_bytes);
        try std.testing.expectEqual(protocol_allocator.allocated_bytes, protocol_allocator.freed_bytes);
    }
}

test "live hotplug publishes v4 and removal retires the same global" {
    var setup: TestSetup = undefined;
    try setup.init();
    defer setup.deinit();
    const client = try server.CoreClient.create(std.testing.allocator, &setup.protocol_server, .{});
    defer client.destroy();
    try setup.prepareRegistry(client.client());
    try testDrain(client.client());

    var log: TestLog = .{};
    defer log.deinit();
    const logger = try setup.protocol_server.addProtocolLogger(TestLog, &log, TestLog.observe);
    defer setup.protocol_server.removeProtocolLogger(logger);
    const id = try setup.layout.add(.{
        .position = .{ .x = 1280 },
        .size = .{ .width = 800, .height = 600 },
        .physical_size = .{ .width = 400, .height = 300 },
        .scale = 1,
        .name = "HEADLESS-HOTPLUG",
        .description = "hotplug fixture",
        .model = "headless",
    });
    const adapter = setup.outputs.findAdapter(id).?;
    try std.testing.expectEqual(@as(u32, 4), adapter.global.version());
    try std.testing.expectEqual(@as(usize, 2), setup.outputs.adapters.items.len);
    try std.testing.expectEqualStrings("global", log.entries.items[0].name);

    log.clear();
    try std.testing.expect(setup.layout.remove(id));
    try std.testing.expect(adapter.retired);
    try std.testing.expect(!adapter.global.published());
    try std.testing.expectEqualStrings("global_remove", log.entries.items[0].name);
}

test "binding storage failures terminalize one client without a half-live resource" {
    for (0..2) |failure_kind| {
        var manager_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var setup: TestSetup = undefined;
        try setup.initAllocators(manager_allocator.allocator(), std.testing.allocator);
        const adapter = setup.outputs.findAdapter(setup.output_id).?;
        if (failure_kind == 1)
            try adapter.bindings.ensureUnusedCapacity(manager_allocator.allocator(), 1);
        manager_allocator.fail_index = manager_allocator.alloc_index;

        const affected = try server.CoreClient.create(std.testing.allocator, &setup.protocol_server, .{});
        try setup.prepareClient(affected.client(), 3, 4);
        try std.testing.expect(manager_allocator.has_induced_failure);
        try std.testing.expectEqual(server.Fatal.Kind.out_of_memory, affected.client().fatal().?.kind);
        try std.testing.expect(affected.client().lookup(3) == null);
        try std.testing.expectEqual(@as(usize, 0), adapter.bindings.items.len);

        manager_allocator.fail_index = std.math.maxInt(usize);
        const healthy = try server.CoreClient.create(std.testing.allocator, &setup.protocol_server, .{});
        try setup.prepareClient(healthy.client(), 3, 4);
        try std.testing.expect(healthy.client().fatal() == null);
        try std.testing.expectEqual(@as(usize, 1), adapter.bindings.items.len);

        setup.outputs.destroyClientResources(healthy.client());
        setup.compositor.destroyClientResources(healthy.client());
        healthy.destroy();
        setup.outputs.destroyClientResources(affected.client());
        setup.compositor.destroyClientResources(affected.client());
        affected.destroy();
        setup.deinit();
        try std.testing.expectEqual(manager_allocator.allocated_bytes, manager_allocator.freed_bytes);
    }
}

test "every initial bind allocation failure is client-local and drains safely" {
    var setup: TestSetup = undefined;
    try setup.init();
    defer setup.deinit();
    const adapter = setup.outputs.findAdapter(setup.output_id).?;

    var measuring_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const measuring = try server.CoreClient.create(measuring_allocator.allocator(), &setup.protocol_server, .{});
    try setup.prepareRegistry(measuring.client());
    const bind_allocation_start = measuring_allocator.alloc_index;
    try setup.bindOutput(measuring.client(), 3, 4);
    const bind_allocation_end = measuring_allocator.alloc_index;
    try std.testing.expect(bind_allocation_end > bind_allocation_start);
    setup.outputs.destroyClientResources(measuring.client());
    setup.compositor.destroyClientResources(measuring.client());
    measuring.destroy();
    try std.testing.expectEqual(measuring_allocator.allocated_bytes, measuring_allocator.freed_bytes);

    for (bind_allocation_start..bind_allocation_end) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const affected = try server.CoreClient.create(failing.allocator(), &setup.protocol_server, .{});
        try setup.prepareRegistry(affected.client());
        try std.testing.expectEqual(bind_allocation_start, failing.alloc_index);
        failing.fail_index = fail_index;
        setup.bindOutput(affected.client(), 3, 4) catch |err|
            try std.testing.expectEqual(error.OutOfMemory, err);
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(server.Fatal.Kind.out_of_memory, affected.client().fatal().?.kind);
        setup.outputs.destroyClientResources(affected.client());
        setup.compositor.destroyClientResources(affected.client());
        affected.destroy();
        try std.testing.expectEqual(@as(usize, 0), adapter.bindings.items.len);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }

    const healthy = try server.CoreClient.create(std.testing.allocator, &setup.protocol_server, .{});
    try setup.prepareClient(healthy.client(), 3, 4);
    try std.testing.expect(healthy.client().fatal() == null);
    try std.testing.expectEqual(@as(usize, 1), adapter.bindings.items.len);
    setup.outputs.destroyClientResources(healthy.client());
    setup.compositor.destroyClientResources(healthy.client());
    healthy.destroy();
}

test "configuration membership routing bind replay and output retirement preserve ownership" {
    var setup: TestSetup = undefined;
    try setup.init();
    var setup_live = true;
    defer if (setup_live) setup.deinit();

    var log: TestLog = .{};
    defer log.deinit();
    const logger = try setup.protocol_server.addProtocolLogger(TestLog, &log, TestLog.observe);
    const first = try server.CoreClient.create(std.testing.allocator, &setup.protocol_server, .{});
    var first_live = true;
    defer if (first_live) {
        setup.outputs.destroyClientResources(first.client());
        setup.compositor.destroyClientResources(first.client());
        first.destroy();
    };
    const second = try server.CoreClient.create(std.testing.allocator, &setup.protocol_server, .{});
    var second_live = true;
    defer if (second_live) {
        setup.outputs.destroyClientResources(second.client());
        setup.compositor.destroyClientResources(second.client());
        second.destroy();
    };
    try setup.prepareClient(first.client(), 3, 4);
    try setup.prepareClient(second.client(), 3, 4);
    const compositor_global = testGlobal(&setup.protocol_server, "wl_compositor");
    inline for (.{ first.client(), second.client() }) |client| {
        try testSend(client, 2, 0, &core.wl_registry.request_messages[0], &.{
            .{ .uint = compositor_global.name() },
            .{ .new_id = .{ .generic = .{
                .interface = "wl_compositor",
                .version = 1,
                .id = 4,
            } } },
        });
        try testSend(client, 4, 0, &core.wl_compositor.request_messages[0], &.{.{ .new_id = .{ .typed = 5 } }});
    }
    try testDrain(first.client());
    try testDrain(second.client());
    log.clear();

    const output = setup.layout.get(setup.output_id).?;
    _ = output.configure(
        .{ .x = 30, .y = 40 },
        .{ .width = 960, .height = 540 },
        .{ .width = 1920, .height = 1080 },
        75_000,
        false,
        1,
        .{},
    );
    var names_buffer: [8][]const u8 = undefined;
    try expectNames(
        &.{ "geometry", "mode", "scale", "done" },
        log.namesFor(first.client(), 3, &names_buffer),
    );
    log.clear();
    output.setRefresh(.{
        .timestamp = .{ .seconds = 0, .nanoseconds = 0 },
        .refresh_nanoseconds = 20_000_000,
    });
    try expectNames(
        &.{ "mode", "done" },
        log.namesFor(first.client(), 3, &names_buffer),
    );
    log.clear();

    const first_surface = setup.compositor.surfaceId(first.client(), 5).?;
    output.beginFrame();
    try output.markSurfaceVisible(first_surface);
    try std.testing.expectEqual(@as(usize, 0), log.entries.items.len);
    output.endFrame();
    try std.testing.expectEqual(@as(usize, 1), log.entries.items.len);
    try std.testing.expectEqual(first.client(), log.entries.items[0].client);
    try std.testing.expectEqualStrings("enter", log.entries.items[0].name);
    try std.testing.expectEqual(@as(?u32, 3), log.entries.items[0].object_argument);

    log.clear();
    output.beginFrame();
    try output.markSurfaceVisible(first_surface);
    output.endFrame();
    try std.testing.expectEqual(@as(usize, 0), log.entries.items.len);

    try testSend(first.client(), 2, 0, &core.wl_registry.request_messages[0], &.{
        .{ .uint = setup.outputs.findAdapter(setup.output_id).?.global.name() },
        .{ .new_id = .{ .generic = .{
            .interface = "wl_output",
            .version = 4,
            .id = 6,
        } } },
    });
    var surface_events: usize = 0;
    for (log.entries.items) |entry| {
        if (entry.client == first.client() and entry.object_id == 5 and
            std.mem.eql(u8, entry.name, "enter"))
        {
            surface_events += 1;
            try std.testing.expectEqual(@as(?u32, 6), entry.object_argument);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), surface_events);

    log.clear();
    output.beginFrame();
    output.endFrame();
    var leaves: usize = 0;
    for (log.entries.items) |entry| if (entry.client == first.client() and
        entry.object_id == 5 and std.mem.eql(u8, entry.name, "leave"))
    {
        leaves += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), leaves);

    output.beginFrame();
    try output.markSurfaceVisible(first_surface);
    output.endFrame();
    try testDrain(first.client());
    try testDrain(second.client());
    log.clear();
    try std.testing.expect(setup.layout.remove(setup.output_id));
    var saw_remove = false;
    leaves = 0;
    for (log.entries.items) |entry| {
        if (entry.client != first.client()) continue;
        if (std.mem.eql(u8, entry.name, "global_remove")) {
            try std.testing.expectEqual(@as(usize, 0), leaves);
            saw_remove = true;
        } else if (std.mem.eql(u8, entry.name, "leave")) {
            try std.testing.expect(saw_remove);
            leaves += 1;
        }
    }
    try std.testing.expect(saw_remove);
    try std.testing.expectEqual(@as(usize, 2), leaves);
    try std.testing.expect(first.client().lookup(3) != null);
    try std.testing.expect(first.client().lookup(6) != null);
    try testSend(first.client(), 3, 0, &core.wl_output.request_messages[0], &.{});
    try testSend(first.client(), 6, 0, &core.wl_output.request_messages[0], &.{});
    try testSend(second.client(), 3, 0, &core.wl_output.request_messages[0], &.{});

    setup.outputs.destroyClientResources(first.client());
    setup.compositor.destroyClientResources(first.client());
    first.destroy();
    first_live = false;
    setup.outputs.destroyClientResources(second.client());
    setup.compositor.destroyClientResources(second.client());
    second.destroy();
    second_live = false;
    setup.protocol_server.removeProtocolLogger(logger);
    setup.outputs.deinit();
    setup.compositor.deinit();
    setup.protocol_server.deinit();
    setup.layout.deinit();
    setup.surfaces.deinit(std.testing.allocator);
    setup.registry.deinit();
    setup.display.destroy();
    setup_live = false;
}
