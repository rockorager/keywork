//! Generated privileged virtual-pointer protocol adapter.
//!
//! This type owns only authenticated wire resources and exact object
//! identities. `VirtualPointer` owns all input state and canonical routing.

const WayringVirtualPointer = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayland = @import("wayland");
const wayring = @import("wayring");
const VirtualPointer = @import("../VirtualPointer.zig");
const SurfaceRegistry = @import("../SurfaceRegistry.zig");
const Seat = @import("seat.zig");
const WayringClients = @import("WayringClients.zig");
const WayringCompositor = @import("WayringCompositor.zig");
const WayringOutput = @import("WayringOutput.zig");
const WayringSeatAdapter = @import("WayringSeatAdapter.zig");
const WayringTransientSeat = @import("WayringTransientSeat.zig");

const wl = wayland.server.wl;
const ManagerResource = protocol.zwlr_virtual_pointer_manager_v1.Resource;
const DeviceResource = protocol.zwlr_virtual_pointer_v1.Resource;

const Manager = struct {
    owner: *WayringVirtualPointer,
    client: *wayring.server.Client,
    resource: ManagerResource,
};

const Device = struct {
    owner: *WayringVirtualPointer,
    client: *wayring.server.Client,
    resource: DeviceResource,
    neutral: ?*VirtualPointer.Device,
};

allocator: std.mem.Allocator,
protocol_server: *wayring.server.Server,
seats: *WayringTransientSeat,
outputs: *WayringOutput,
neutral: *VirtualPointer,
provider: *VirtualPointer.Provider,
authorized_uid: std.os.linux.uid_t,
global: ?*const wayring.server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
devices: std.ArrayList(*Device) = .empty,

pub fn init(
    self: *WayringVirtualPointer,
    allocator: std.mem.Allocator,
    protocol_server: *wayring.server.Server,
    seats: *WayringTransientSeat,
    outputs: *WayringOutput,
    neutral: *VirtualPointer,
    authorized_uid: std.os.linux.uid_t,
) !void {
    self.* = .{
        .allocator = allocator,
        .protocol_server = protocol_server,
        .seats = seats,
        .outputs = outputs,
        .neutral = neutral,
        .provider = try neutral.createProvider(),
        .authorized_uid = authorized_uid,
    };
    errdefer neutral.destroyProvider(self.provider);
    try seats.addSeatListener(.{ .context = self, .removed = transientSeatRemoved });
}

pub fn deinit(self: *WayringVirtualPointer) void {
    std.debug.assert(self.global == null and self.managers.items.len == 0 and self.devices.items.len == 0);
    self.devices.deinit(self.allocator);
    self.managers.deinit(self.allocator);
    self.seats.removeSeatListener(self);
    self.neutral.destroyProvider(self.provider);
    self.* = undefined;
}

pub fn publish(self: *WayringVirtualPointer) !void {
    std.debug.assert(self.global == null);
    self.global = try self.protocol_server.addGlobalWithOptions(
        protocol.zwlr_virtual_pointer_manager_v1,
        2,
        WayringVirtualPointer,
        self,
        bindManager,
        .{ .visibility = .restricted },
    );
}

pub fn unpublish(self: *WayringVirtualPointer) void {
    const global = self.global orelse unreachable;
    self.protocol_server.removeGlobal(global) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}

pub fn globalFilter(self: *const WayringVirtualPointer, client: *const wayring.server.Client, global: *const wayring.server.Server.Global) bool {
    return global.visibility() != .restricted or client.isAuthorizedDirectPeer(self.authorized_uid);
}

fn bindManager(client: *wayring.server.Client, id: u32, version: u32, self: *WayringVirtualPointer) !void {
    try self.bind(client, id, version);
}

/// Direct typed bind seam shared by publication and fault-injection fixtures.
pub fn bind(self: *WayringVirtualPointer, client: *wayring.server.Client, id: u32, version: u32) !void {
    if (version < 1 or version > 2) return error.InvalidVersion;
    if (!client.isAuthorizedDirectPeer(self.authorized_uid)) return error.AccessDenied;
    try self.managers.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Manager);
    errdefer self.allocator.destroy(value);
    value.* = .{
        .owner = self,
        .client = client,
        .resource = .init(self.allocator, id, version, .client, client.ownerHooks()),
    };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Manager, value, managerRequest, null);
    try client.materialize(&value.resource.runtime);
    self.managers.appendAssumeCapacity(value);
}

fn managerRequest(_: *ManagerResource, request: protocol.zwlr_virtual_pointer_manager_v1.Request, manager: *Manager) !void {
    if (!manager.owner.authorized(manager.client, &manager.resource.runtime)) return;
    switch (request) {
        .create_virtual_pointer => |args| try manager.owner.createDevice(manager, args.seat, null, args.id),
        .create_virtual_pointer_with_output => |args| try manager.owner.createDevice(manager, args.seat, args.output, args.id),
        .destroy => manager.owner.destroyManager(manager),
    }
}

fn createDevice(self: *WayringVirtualPointer, manager: *Manager, seat_object: ?u32, output_object: ?u32, id: u32) !void {
    if (!self.authorized(manager.client, &manager.resource.runtime)) return;
    const output = if (output_object) |output_id| switch (self.outputs.identifyResource(manager.client, output_id)) {
        .live => |identity| identity.output,
        .retired, .invalid => {
            manager.client.postImplementationError(&manager.resource.runtime, "virtual pointer requires an exact live same-client wl_output");
            return;
        },
    } else null;
    try self.devices.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Device);
    errdefer self.allocator.destroy(value);
    const selection = if (seat_object) |seat_id|
        self.seats.acquireSeat(manager.client, seat_id)
    else
        self.seats.canonicalSelection(manager.client);
    const neutral = if (selection) |selected| try self.neutral.createDevice(self.provider, .{
        .seat = selected.seat,
        .output = output,
        .release_context = if (selected.entry) |entry| entry else null,
        .release = if (selected.entry != null) releaseTransientSeat else null,
    }) else null;
    errdefer if (neutral) |device| self.neutral.destroyDevice(device);
    value.* = .{
        .owner = self,
        .client = manager.client,
        .resource = .init(self.allocator, id, manager.resource.version(), .client, manager.client.ownerHooks()),
        .neutral = neutral,
    };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Device, value, deviceRequest, null);
    try manager.client.materialize(&value.resource.runtime);
    self.devices.appendAssumeCapacity(value);
}

fn deviceRequest(_: *DeviceResource, request: protocol.zwlr_virtual_pointer_v1.Request, device: *Device) !void {
    if (!device.owner.authorized(device.client, &device.resource.runtime)) return;
    const neutral = device.neutral orelse {
        if (request == .destroy) device.owner.destroyDevice(device);
        return;
    };
    if (!neutral.active and request != .destroy) return;
    switch (request) {
        .motion => |args| neutral.motion(args.time, fixedDouble(args.dx), fixedDouble(args.dy)),
        .motion_absolute => |args| neutral.motionAbsolute(args.time, args.x, args.y, args.x_extent, args.y_extent),
        .button => |args| neutral.button(args.time, args.button, args.state) catch |err| switch (err) {
            error.OutOfMemory => device.client.postOutOfMemory(&device.resource.runtime, "recording virtual pointer button"),
            error.InvalidButtonState => device.client.postImplementationError(&device.resource.runtime, "invalid virtual pointer button state"),
        },
        .axis => |args| neutral.axis(args.time, args.axis, fixed(args.value)) catch invalidAxis(device),
        .frame => neutral.frame(),
        .axis_source => |args| neutral.axisSource(args.axis_source) catch invalidAxisSource(device),
        .axis_stop => |args| neutral.axisStop(args.time, args.axis) catch invalidAxis(device),
        .axis_discrete => |args| neutral.axisDiscrete(args.time, args.axis, fixed(args.value), args.discrete) catch invalidAxis(device),
        .destroy => device.owner.destroyDevice(device),
    }
}

fn invalidAxis(device: *Device) void {
    device.client.postProtocolError(&device.resource.runtime, 0, "invalid virtual pointer axis");
}

fn invalidAxisSource(device: *Device) void {
    device.client.postProtocolError(&device.resource.runtime, 1, "invalid virtual pointer axis source");
}

fn authorized(self: *WayringVirtualPointer, client: *wayring.server.Client, resource: *wayring.server.Resource) bool {
    if (client.isAuthorizedDirectPeer(self.authorized_uid)) return true;
    client.postImplementationError(resource, "virtual pointer requires a direct same-UID transport");
    return false;
}

fn fixed(value: i32) wl.Fixed {
    return @enumFromInt(value);
}

fn fixedDouble(value: i32) f64 {
    return @as(f64, @floatFromInt(value)) / 256.0;
}

pub fn destroyClientResources(self: *WayringVirtualPointer, client: *wayring.server.Client) void {
    var i = self.devices.items.len;
    while (i > 0) : (i -= 1) if (self.devices.items[i - 1].client == client) self.destroyDevice(self.devices.items[i - 1]);
    i = self.managers.items.len;
    while (i > 0) : (i -= 1) if (self.managers.items[i - 1].client == client) self.destroyManager(self.managers.items[i - 1]);
}

fn destroyDevice(self: *WayringVirtualPointer, value: *Device) void {
    for (self.devices.items, 0..) |candidate, index| if (candidate == value) {
        _ = self.devices.swapRemove(index);
        break;
    };
    if (value.neutral) |neutral| self.neutral.destroyDevice(neutral);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}

fn transientSeatRemoved(context: *anyopaque, seat: *Seat) void {
    const self: *WayringVirtualPointer = @ptrCast(@alignCast(context));
    self.neutral.deactivateSeat(seat);
}

fn releaseTransientSeat(context: *anyopaque, _: *Seat) void {
    const entry: *WayringTransientSeat.Entry = @ptrCast(@alignCast(context));
    entry.owner.releaseEntry(entry);
}

fn destroyManager(self: *WayringVirtualPointer, value: *Manager) void {
    for (self.managers.items, 0..) |candidate, index| if (candidate == value) {
        _ = self.managers.swapRemove(index);
        break;
    };
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}

test "virtual-pointer v2 descriptors versions and errors are exact" {
    const manager = protocol.zwlr_virtual_pointer_manager_v1;
    const device = protocol.zwlr_virtual_pointer_v1;
    try std.testing.expectEqual(@as(u32, 2), manager.interface.version);
    try std.testing.expectEqual(@as(u32, 2), device.interface.version);
    try expectNames(&manager.request_messages, &.{ "create_virtual_pointer", "destroy", "create_virtual_pointer_with_output" });
    try std.testing.expectEqual(@as(u32, 2), manager.request_messages[2].since);
    try expectNames(&device.request_messages, &.{ "motion", "motion_absolute", "button", "axis", "frame", "axis_source", "axis_stop", "axis_discrete", "destroy" });
    try std.testing.expectEqual(@as(i64, 0), device.@"error".invalid_axis);
    try std.testing.expectEqual(@as(i64, 1), device.@"error".invalid_axis_source);
    try std.testing.expectApproxEqAbs(@as(f64, -1.5), fixedDouble(-384), 0.0001);
}

test "typed bind requires direct exact UID and accepts both manager versions" {
    var fixture: BindFixture = undefined;
    try fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const protocol_server = &fixture.protocol_server;
    const adapter = &fixture.adapter;

    const credentials: wayring.server.Client.Credentials = .{ .pid = 1, .uid = 42, .gid = 1 };
    var direct: wayring.server.Client = .init(std.testing.allocator, .{
        .credentials = credentials,
        .transport_provenance = .direct,
    });
    defer direct.deinit();
    var wrong_uid: wayring.server.Client = .init(std.testing.allocator, .{
        .credentials = .{ .pid = 2, .uid = 41, .gid = 1 },
        .transport_provenance = .direct,
    });
    defer wrong_uid.deinit();
    var derived: wayring.server.Client = .init(std.testing.allocator, .{
        .credentials = credentials,
        .transport_provenance = .security_context,
    });
    defer derived.deinit();

    try std.testing.expectError(error.InvalidVersion, adapter.bind(&direct, 2, 0));
    try std.testing.expectError(error.InvalidVersion, adapter.bind(&direct, 2, 3));
    try std.testing.expectError(error.AccessDenied, adapter.bind(&wrong_uid, 2, 1));
    try std.testing.expectError(error.AccessDenied, adapter.bind(&derived, 2, 2));
    const managed = try wayring.server.CoreClient.create(std.testing.allocator, protocol_server, .{
        .credentials = credentials,
        .transport_provenance = .direct,
    });
    defer managed.destroy();
    try prepareRegistry(managed.client());
    try registryBind(adapter, managed.client(), 3, 1);
    try registryBind(adapter, managed.client(), 4, 2);
    try std.testing.expectEqual(@as(usize, 2), adapter.managers.items.len);
    try std.testing.expectEqual(@as(usize, 1), fixture.neutral.providers.items.len);
    adapter.destroyClientResources(managed.client());
    try std.testing.expectEqual(@as(usize, 0), adapter.managers.items.len);
    try std.testing.expectEqual(@as(usize, 0), adapter.devices.items.len);
}

const BindFixture = struct {
    protocol_server: wayring.server.Server,
    surface_registry: SurfaceRegistry = undefined,
    clients: WayringClients = undefined,
    compositor: WayringCompositor = undefined,
    output_layout: @import("output_layout.zig") = undefined,
    context: u8 = 0,
    neutral: VirtualPointer = undefined,
    seat_adapter: WayringSeatAdapter = undefined,
    transient_seat: WayringTransientSeat = undefined,
    outputs: WayringOutput = undefined,
    seat: Seat = undefined,
    adapter: WayringVirtualPointer = undefined,

    fn event(_: *anyopaque, _: *Seat, _: ?@import("output_layout.zig").Id, _: u64, _: VirtualPointer.Event) void {}
    fn initSeat(_: *anyopaque, _: *Seat, _: std.mem.Allocator, _: [:0]const u8) !void {}

    fn init(self: *BindFixture, allocator: std.mem.Allocator) !void {
        self.* = .{ .protocol_server = .init(std.testing.allocator) };
        errdefer self.protocol_server.deinit();
        self.surface_registry = .init(allocator);
        errdefer self.surface_registry.deinit();
        try self.compositor.init(allocator, &self.protocol_server, &self.surface_registry, null);
        errdefer self.compositor.deinit();
        self.clients = undefined;
        self.seat_adapter = .init(allocator, &self.protocol_server, &self.clients, &self.compositor, undefined, "test");
        errdefer self.seat_adapter.deinit();
        self.transient_seat.init(allocator, &self.protocol_server, &self.clients, &self.compositor, &self.seat, &self.seat_adapter, .{ .context = self, .init_seat = initSeat }, 42);
        errdefer self.transient_seat.deinit();
        self.neutral = VirtualPointer.init(allocator, &self.output_layout, .{
            .context = &self.context,
            .event = event,
        });
        errdefer self.neutral.deinit();
        try self.adapter.init(
            allocator,
            &self.protocol_server,
            &self.transient_seat,
            &self.outputs,
            &self.neutral,
            42,
        );
        errdefer self.adapter.deinit();
        try self.adapter.publish();
        self.protocol_server.setGlobalFilter(WayringVirtualPointer, &self.adapter, globalFilter);
    }

    fn deinit(self: *BindFixture) void {
        self.protocol_server.clearGlobalFilter();
        self.adapter.unpublish();
        self.adapter.deinit();
        self.neutral.deinit();
        self.transient_seat.deinit();
        self.seat_adapter.deinit();
        self.compositor.deinit();
        self.surface_registry.deinit();
        self.protocol_server.deinit();
        self.* = undefined;
    }

    fn client(self: *BindFixture, allocator: std.mem.Allocator) !*wayring.server.CoreClient {
        return wayring.server.CoreClient.create(allocator, &self.protocol_server, .{
            .credentials = .{ .pid = 1, .uid = 42, .gid = 1 },
            .transport_provenance = .direct,
        });
    }
};

const test_display_get_registry: wayring.wire.MessageDescriptor = .{
    .name = "get_registry",
    .arguments = &.{.{ .name = "registry", .kind = .{ .new_id = &.{ .name = "wl_registry", .version = 1 } } }},
};
const test_registry_bind: wayring.wire.MessageDescriptor = .{ .name = "bind", .arguments = &.{
    .{ .name = "name", .kind = .uint },
    .{ .name = "id", .kind = .{ .new_id = null } },
} };

fn testSend(client: *wayring.server.Client, object_id: u32, opcode: u16, descriptor: *const wayring.wire.MessageDescriptor, values: []const wayring.wire.Value) !void {
    var output: wayring.wire.Output = .init(std.testing.allocator);
    defer output.deinit();
    try output.enqueue(object_id, opcode, descriptor, values);
    const batch = (try output.beginSend()).?;
    try client.receive(batch.bytes, &.{});
    try output.completeSend(batch.token, batch.bytes.len);
    try client.dispatch();
}

fn prepareRegistry(client: *wayring.server.Client) !void {
    try testSend(client, 1, 1, &test_display_get_registry, &.{.{ .new_id = .{ .typed = 2 } }});
    while (try client.beginSend()) |batch| try client.completeSend(batch.token, batch.bytes.len);
}

fn registryBind(adapter: *WayringVirtualPointer, client: *wayring.server.Client, id: u32, version: u32) !void {
    try testSend(client, 2, 0, &test_registry_bind, &.{
        .{ .uint = adapter.global.?.name() },
        .{ .new_id = .{ .generic = .{
            .interface = protocol.zwlr_virtual_pointer_manager_v1.interface.name,
            .version = version,
            .id = id,
        } } },
    });
}

test "every manager bind allocation failure rolls back without half-live state" {
    var measuring_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocation_range = range: {
        var fixture: BindFixture = undefined;
        try fixture.init(measuring_allocator.allocator());
        defer fixture.deinit();
        const client = try fixture.client(std.testing.allocator);
        defer {
            fixture.adapter.destroyClientResources(client.client());
            client.destroy();
        }
        try prepareRegistry(client.client());
        const allocation_start = measuring_allocator.alloc_index;
        try registryBind(&fixture.adapter, client.client(), 3, 2);
        const allocation_end = measuring_allocator.alloc_index;
        try std.testing.expect(allocation_end > allocation_start);
        break :range .{ allocation_start, allocation_end };
    };
    try std.testing.expectEqual(measuring_allocator.allocated_bytes, measuring_allocator.freed_bytes);

    for (allocation_range[0]..allocation_range[1]) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        {
            var fixture: BindFixture = undefined;
            try fixture.init(failing.allocator());
            defer fixture.deinit();
            const client = try fixture.client(std.testing.allocator);
            defer client.destroy();
            try prepareRegistry(client.client());
            try std.testing.expectEqual(allocation_range[0], failing.alloc_index);
            failing.fail_index = fail_index;
            defer failing.fail_index = std.math.maxInt(usize);
            registryBind(&fixture.adapter, client.client(), 3, 2) catch |err|
                try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(failing.has_induced_failure);
            try std.testing.expectEqual(wayring.server.Fatal.Kind.out_of_memory, client.client().fatal().?.kind);
            try std.testing.expectEqual(@as(usize, 0), fixture.adapter.managers.items.len);
            try std.testing.expect(client.client().lookup(3) == null);
        }
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "every client materialization failure rolls back manager storage" {
    var measuring_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocation_range = range: {
        var fixture: BindFixture = undefined;
        try fixture.init(std.testing.allocator);
        defer fixture.deinit();
        const client = try fixture.client(measuring_allocator.allocator());
        defer {
            fixture.adapter.destroyClientResources(client.client());
            client.destroy();
        }
        try prepareRegistry(client.client());
        const allocation_start = measuring_allocator.alloc_index;
        try registryBind(&fixture.adapter, client.client(), 3, 2);
        const allocation_end = measuring_allocator.alloc_index;
        try std.testing.expect(allocation_end > allocation_start);
        break :range .{ allocation_start, allocation_end };
    };
    try std.testing.expectEqual(measuring_allocator.allocated_bytes, measuring_allocator.freed_bytes);

    for (allocation_range[0]..allocation_range[1]) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        {
            var fixture: BindFixture = undefined;
            try fixture.init(std.testing.allocator);
            defer fixture.deinit();
            const client = try fixture.client(failing.allocator());
            defer client.destroy();
            try prepareRegistry(client.client());
            try std.testing.expectEqual(allocation_range[0], failing.alloc_index);
            failing.fail_index = fail_index;
            defer failing.fail_index = std.math.maxInt(usize);
            registryBind(&fixture.adapter, client.client(), 3, 2) catch |err|
                try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(failing.has_induced_failure);
            try std.testing.expectEqual(wayring.server.Fatal.Kind.out_of_memory, client.client().fatal().?.kind);
            try std.testing.expectEqual(@as(usize, 0), fixture.adapter.managers.items.len);
            try std.testing.expect(client.client().lookup(3) == null);
        }
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

fn expectNames(messages: anytype, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, messages.len);
    for (messages, expected) |message, name| try std.testing.expectEqualStrings(name, message.name);
}
