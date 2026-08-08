//! Unpublished generated privileged virtual-pointer protocol adapter.
//!
//! This type owns only authenticated wire resources and exact object
//! identities. `VirtualPointer` owns all input state and canonical routing.

const WayringVirtualPointer = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayland = @import("wayland");
const wayring = @import("wayring");
const VirtualPointer = @import("../VirtualPointer.zig");
const Seat = @import("seat.zig");
const WayringOutput = @import("WayringOutput.zig");
const WayringSeatAdapter = @import("WayringSeatAdapter.zig");

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
    neutral: *VirtualPointer.Device,
};

allocator: std.mem.Allocator,
protocol_server: *wayring.server.Server,
seat_adapter: *WayringSeatAdapter,
outputs: *WayringOutput,
neutral: *VirtualPointer,
provider: *VirtualPointer.Provider,
default_seat: *Seat,
authorized_uid: std.os.linux.uid_t,
global: ?*const wayring.server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
devices: std.ArrayList(*Device) = .empty,

pub fn init(
    self: *WayringVirtualPointer,
    allocator: std.mem.Allocator,
    protocol_server: *wayring.server.Server,
    seat_adapter: *WayringSeatAdapter,
    outputs: *WayringOutput,
    neutral: *VirtualPointer,
    default_seat: *Seat,
    authorized_uid: std.os.linux.uid_t,
) !void {
    self.* = .{
        .allocator = allocator,
        .protocol_server = protocol_server,
        .seat_adapter = seat_adapter,
        .outputs = outputs,
        .neutral = neutral,
        .provider = try neutral.createProvider(),
        .default_seat = default_seat,
        .authorized_uid = authorized_uid,
    };
}

pub fn deinit(self: *WayringVirtualPointer) void {
    std.debug.assert(self.global == null and self.managers.items.len == 0 and self.devices.items.len == 0);
    self.devices.deinit(self.allocator);
    self.managers.deinit(self.allocator);
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
        .create_virtual_pointer => |args| manager.owner.createDevice(manager, args.seat, null, args.id),
        .create_virtual_pointer_with_output => |args| manager.owner.createDevice(manager, args.seat, args.output, args.id),
        .destroy => manager.owner.destroyManager(manager),
    }
}

fn createDevice(self: *WayringVirtualPointer, manager: *Manager, seat_object: ?u32, output_object: ?u32, id: u32) !void {
    if (!self.authorized(manager.client, &manager.resource.runtime)) return;
    if (seat_object) |seat_id| if (self.seat_adapter.seatClientIdentity(manager.client, seat_id) == null) {
        manager.client.postImplementationError(&manager.resource.runtime, "virtual pointer requires the exact live same-client wl_seat");
        return;
    };
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
    const neutral = try self.neutral.createDevice(self.provider, .{ .seat = self.default_seat, .output = output });
    errdefer self.neutral.destroyDevice(neutral);
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
    switch (request) {
        .motion => |args| device.neutral.motion(args.time, fixedDouble(args.dx), fixedDouble(args.dy)),
        .motion_absolute => |args| device.neutral.motionAbsolute(args.time, args.x, args.y, args.x_extent, args.y_extent),
        .button => |args| device.neutral.button(args.time, args.button, args.state) catch |err| switch (err) {
            error.OutOfMemory => device.client.postOutOfMemory(&device.resource.runtime, "recording virtual pointer button"),
            error.InvalidButtonState => device.client.postImplementationError(&device.resource.runtime, "invalid virtual pointer button state"),
        },
        .axis => |args| device.neutral.axis(args.time, args.axis, fixed(args.value)) catch device.invalidAxis(),
        .frame => device.neutral.frame(),
        .axis_source => |args| device.neutral.axisSource(args.axis_source) catch device.invalidAxisSource(),
        .axis_stop => |args| device.neutral.axisStop(args.time, args.axis) catch device.invalidAxis(),
        .axis_discrete => |args| device.neutral.axisDiscrete(args.time, args.axis, fixed(args.value), args.discrete) catch device.invalidAxis(),
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
    self.neutral.destroyDevice(value.neutral);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
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
    const Context = struct {
        fn event(_: *anyopaque, _: *Seat, _: ?@import("output_layout.zig").Id, _: u64, _: VirtualPointer.Event) void {}
    };
    var protocol_server: wayring.server.Server = .init(std.testing.allocator);
    defer protocol_server.deinit();
    var output_layout: @import("output_layout.zig") = undefined;
    var context: u8 = 0;
    var neutral = VirtualPointer.init(std.testing.allocator, &output_layout, .{ .context = &context, .event = Context.event });
    defer neutral.deinit();
    var seat_adapter: WayringSeatAdapter = undefined;
    var outputs: WayringOutput = undefined;
    var seat: Seat = undefined;
    var adapter: WayringVirtualPointer = undefined;
    try adapter.init(
        std.testing.allocator,
        &protocol_server,
        &seat_adapter,
        &outputs,
        &neutral,
        &seat,
        42,
    );
    defer adapter.deinit();

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
    try adapter.bind(&direct, 2, 1);
    try adapter.bind(&direct, 3, 2);
    try std.testing.expectEqual(@as(usize, 2), adapter.managers.items.len);
    try std.testing.expectEqual(@as(usize, 1), neutral.providers.items.len);
    adapter.destroyClientResources(&direct);
    try std.testing.expectEqual(@as(usize, 0), adapter.managers.items.len);
    try std.testing.expectEqual(@as(usize, 0), adapter.devices.items.len);
}

fn expectNames(messages: anytype, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, messages.len);
    for (messages, expected) |message, name| try std.testing.expectEqualStrings(name, message.name);
}
