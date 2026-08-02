//! Privileged default-seat virtual pointer producer.

const VirtualPointerGlobal = @This();

const std = @import("std");
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const SecurityContextGlobal = @import("SecurityContextGlobal.zig");
const SeatGlobal = @import("SeatGlobal.zig");
const OutputGlobal = @import("OutputGlobal.zig");

allocator: std.mem.Allocator,
server: *Server,
seat: *SeatGlobal,
output: *OutputGlobal,
listener: Listener,
global_name: u32,
devices: std.ArrayList(*Device) = .empty,
next_source: u64 = 1,

pub const Event = union(enum) {
    motion: struct { time: u32, dx: f64, dy: f64 },
    motion_absolute: struct {
        time: u32,
        x: u32,
        y: u32,
        x_extent: u32,
        y_extent: u32,
    },
    button: struct { time: u32, button: u32, state: u32 },
    axis: struct { time: u32, axis: u32, value: i32 },
    frame,
    axis_source: u32,
    axis_stop: struct { time: u32, axis: u32 },
    axis_discrete: struct { time: u32, axis: u32, value: i32, discrete: i32 },
};

pub const Listener = struct {
    context: *anyopaque,
    event: *const fn (*anyopaque, ?*OutputGlobal, u64, Event) void,
    capability_changed: *const fn (*anyopaque) void,
    failed: *const fn (*anyopaque) void,
};

const Device = struct {
    owner: *VirtualPointerGlobal,
    resource: wayring.ObjectHandle,
    mapped_output: ?*OutputGlobal,
    source: u64,
    active: bool,
    registered: bool = false,
    pressed_buttons: std.ArrayList(u32) = .empty,
};

pub fn init(
    self: *VirtualPointerGlobal,
    allocator: std.mem.Allocator,
    server: *Server,
    seat: *SeatGlobal,
    output: *OutputGlobal,
    security: *SecurityContextGlobal,
    listener: Listener,
) !void {
    self.* = .{
        .allocator = allocator,
        .server = server,
        .seat = seat,
        .output = output,
        .listener = listener,
        .global_name = undefined,
    };
    self.global_name = try server.createGlobal(
        &generated.zwlr_virtual_pointer_manager_v1,
        2,
        .{
            .context = self,
            .bind = bind,
            .filter_context = security,
            .filter = SecurityContextGlobal.allowUnconfined,
        },
    );
}

pub fn deinit(self: *VirtualPointerGlobal) void {
    std.debug.assert(self.devices.items.len == 0);
    self.server.removeGlobal(self.global_name) catch unreachable;
    self.devices.deinit(self.allocator);
    self.* = undefined;
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *VirtualPointerGlobal = @ptrCast(@alignCast(context));
    _ = client.createResource(
        id,
        &generated.zwlr_virtual_pointer_manager_v1,
        version,
        .{ .context = self, .dispatch = dispatchManager },
    ) catch return client.postNoMemory();
}

fn dispatchManager(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const self: *VirtualPointerGlobal = @ptrCast(@alignCast(context));
    const version = try client.resourceVersion(
        resource,
        &generated.zwlr_virtual_pointer_manager_v1,
    );
    switch (try generated.zwlr_virtual_pointer_manager_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .create_virtual_pointer => |request| try self.createDevice(
            client,
            request.id,
            version,
            self.resolveSeat(client, request.seat),
            null,
        ),
        .create_virtual_pointer_with_output => |request| try self.createDevice(
            client,
            request.id,
            version,
            self.resolveSeat(client, request.seat),
            self.resolveOutput(client, request.output),
        ),
    }
}

fn resolveSeat(
    self: *const VirtualPointerGlobal,
    client: *const Server.Client,
    resource_id: ?u32,
) bool {
    const id = resource_id orelse return true;
    return self.seat.ownsResource(client, id);
}

fn resolveOutput(
    self: *const VirtualPointerGlobal,
    client: *const Server.Client,
    resource_id: ?u32,
) ?*OutputGlobal {
    const id = resource_id orelse return null;
    return if (self.output.bindingHandle(client, id) != null) self.output else null;
}

fn createDevice(
    self: *VirtualPointerGlobal,
    client: *Server.Client,
    id: u32,
    version: u32,
    active: bool,
    mapped_output: ?*OutputGlobal,
) !void {
    self.devices.ensureUnusedCapacity(self.allocator, 1) catch
        return client.postNoMemory();
    const device = self.allocator.create(Device) catch return client.postNoMemory();
    errdefer self.allocator.destroy(device);
    const source = self.next_source;
    self.next_source = std.math.add(u64, source, 1) catch unreachable;
    device.* = .{
        .owner = self,
        .resource = undefined,
        .mapped_output = mapped_output,
        .source = source,
        .active = active,
    };
    device.resource = client.createResource(
        id,
        &generated.zwlr_virtual_pointer_v1,
        @min(version, generated.zwlr_virtual_pointer_v1.version),
        .{
            .context = device,
            .dispatch = dispatchDevice,
            .destroy = destroyDevice,
        },
    ) catch return client.postNoMemory();
    self.devices.appendAssumeCapacity(device);
    if (!active) return;
    device.registered = true;
    self.seat.addVirtualPointer() catch self.listener.failed(self.listener.context);
    self.listener.capability_changed(self.listener.context);
}

fn dispatchDevice(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const device: *Device = @ptrCast(@alignCast(context));
    const request = try generated.zwlr_virtual_pointer_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    );
    if (!device.active) return;
    switch (request) {
        .destroy => {},
        .motion => |event| emit(device, .{ .motion = .{
            .time = event.time,
            .dx = fixedToDouble(event.dx),
            .dy = fixedToDouble(event.dy),
        } }),
        .motion_absolute => |event| emit(device, .{ .motion_absolute = .{
            .time = event.time,
            .x = event.x,
            .y = event.y,
            .x_extent = event.x_extent,
            .y_extent = event.y_extent,
        } }),
        .button => |event| try button(
            device,
            client,
            event.time,
            event.button,
            event.state,
        ),
        .axis => |event| {
            try validateAxis(client, resource, event.axis);
            emit(device, .{ .axis = .{
                .time = event.time,
                .axis = event.axis,
                .value = event.value,
            } });
        },
        .frame => emit(device, .frame),
        .axis_source => |event| {
            try validateAxisSource(client, resource, event.axis_source);
            emit(device, .{ .axis_source = event.axis_source });
        },
        .axis_stop => |event| {
            try validateAxis(client, resource, event.axis);
            emit(device, .{ .axis_stop = .{ .time = event.time, .axis = event.axis } });
        },
        .axis_discrete => |event| {
            try validateAxis(client, resource, event.axis);
            emit(device, .{ .axis_discrete = .{
                .time = event.time,
                .axis = event.axis,
                .value = event.value,
                .discrete = event.discrete,
            } });
        },
    }
}

fn button(
    self: *Device,
    client: *Server.Client,
    time: u32,
    button_code: u32,
    state: u32,
) !void {
    switch (state) {
        @intFromEnum(generated.wl_pointer_types.button_state.pressed) => {
            if (std.mem.indexOfScalar(u32, self.pressed_buttons.items, button_code) != null)
                return;
            self.pressed_buttons.append(self.owner.allocator, button_code) catch
                return client.postNoMemory();
        },
        @intFromEnum(generated.wl_pointer_types.button_state.released) => {
            const index = std.mem.indexOfScalar(
                u32,
                self.pressed_buttons.items,
                button_code,
            ) orelse return;
            _ = self.pressed_buttons.orderedRemove(index);
        },
        else => return client.postImplementationError("invalid virtual pointer button state"),
    }
    emit(self, .{ .button = .{ .time = time, .button = button_code, .state = state } });
}

fn emit(self: *Device, event: Event) void {
    self.owner.listener.event(
        self.owner.listener.context,
        self.mapped_output,
        self.source,
        event,
    );
}

fn deactivate(self: *Device) void {
    if (!self.active) return;
    const had_buttons = self.pressed_buttons.items.len != 0;
    while (self.pressed_buttons.pop()) |button_code| emit(self, .{ .button = .{
        .time = 0,
        .button = button_code,
        .state = @intFromEnum(generated.wl_pointer_types.button_state.released),
    } });
    if (had_buttons) emit(self, .frame);
    if (self.registered) {
        self.owner.seat.removeVirtualPointer() catch
            self.owner.listener.failed(self.owner.listener.context);
        self.registered = false;
        self.owner.listener.capability_changed(self.owner.listener.context);
    }
    self.active = false;
}

fn destroyDevice(context: *anyopaque, _: *Server.Client, _: wayring.ObjectHandle) void {
    const device: *Device = @ptrCast(@alignCast(context));
    const owner = device.owner;
    deactivate(device);
    for (owner.devices.items, 0..) |candidate, index| {
        if (candidate != device) continue;
        _ = owner.devices.orderedRemove(index);
        device.pressed_buttons.deinit(owner.allocator);
        owner.allocator.destroy(device);
        return;
    }
    unreachable;
}

fn validateAxis(
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    axis: u32,
) !void {
    if (axis == @intFromEnum(generated.wl_pointer_types.axis.vertical_scroll) or
        axis == @intFromEnum(generated.wl_pointer_types.axis.horizontal_scroll)) return;
    return client.postError(
        resource,
        @intFromEnum(generated.zwlr_virtual_pointer_v1_types.@"error".invalid_axis),
        "invalid virtual pointer axis",
    );
}

fn validateAxisSource(
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    source: u32,
) !void {
    if (source == @intFromEnum(generated.wl_pointer_types.axis_source.wheel) or
        source == @intFromEnum(generated.wl_pointer_types.axis_source.finger) or
        source == @intFromEnum(generated.wl_pointer_types.axis_source.continuous) or
        source == @intFromEnum(generated.wl_pointer_types.axis_source.wheel_tilt)) return;
    return client.postError(
        resource,
        @intFromEnum(generated.zwlr_virtual_pointer_v1_types.@"error".invalid_axis_source),
        "invalid virtual pointer axis source",
    );
}

fn fixedToDouble(value: i32) f64 {
    return @as(f64, @floatFromInt(value)) / 256.0;
}

const TestListener = struct {
    events: [8]Event = undefined,
    outputs: [8]?*OutputGlobal = undefined,
    sources: [8]u64 = undefined,
    event_count: usize = 0,
    capability_changes: usize = 0,
    failures: usize = 0,

    fn event(
        context: *anyopaque,
        output: ?*OutputGlobal,
        source: u64,
        value: Event,
    ) void {
        const self: *TestListener = @ptrCast(@alignCast(context));
        self.events[self.event_count] = value;
        self.outputs[self.event_count] = output;
        self.sources[self.event_count] = source;
        self.event_count += 1;
    }

    fn capabilityChanged(context: *anyopaque) void {
        const self: *TestListener = @ptrCast(@alignCast(context));
        self.capability_changes += 1;
    }

    fn failed(context: *anyopaque) void {
        const self: *TestListener = @ptrCast(@alignCast(context));
        self.failures += 1;
    }

    fn listener(self: *TestListener) Listener {
        return .{
            .context = self,
            .event = event,
            .capability_changed = capabilityChanged,
            .failed = failed,
        };
    }
};

test "virtual pointer deduplicates buttons and releases before teardown frame" {
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var seat: SeatGlobal = undefined;
    try seat.init(std.testing.allocator, &server, "default", 0, null);
    defer seat.deinit();
    var output: OutputGlobal = undefined;
    var security: SecurityContextGlobal = undefined;
    var capture: TestListener = .{};
    var pointers: VirtualPointerGlobal = undefined;
    try pointers.init(
        std.testing.allocator,
        &server,
        &seat,
        &output,
        &security,
        capture.listener(),
    );
    defer pointers.deinit();
    const client = try server.createClient();
    defer server.destroyClient(client) catch {};

    try pointers.createDevice(client, 2, 2, true, null);
    const device = pointers.devices.items[0];
    const pressed = @intFromEnum(generated.wl_pointer_types.button_state.pressed);
    const released = @intFromEnum(generated.wl_pointer_types.button_state.released);
    try button(device, client, 1, 0x110, pressed);
    try button(device, client, 2, 0x110, pressed);
    try button(device, client, 3, 0x110, released);
    try button(device, client, 4, 0x110, released);
    try button(device, client, 5, 0x111, pressed);
    try std.testing.expectEqual(@as(usize, 3), capture.event_count);
    try client.destroyResource(device.resource);
    try std.testing.expectEqual(@as(usize, 5), capture.event_count);
    try std.testing.expect(capture.events[3] == .button);
    try std.testing.expectEqual(released, capture.events[3].button.state);
    try std.testing.expect(capture.events[4] == .frame);
    try std.testing.expectEqual(@as(usize, 0), pointers.devices.items.len);
    try std.testing.expect(!seat.hasCapability(SeatGlobal.Capability.pointer));
    try std.testing.expectEqual(@as(usize, 2), capture.capability_changes);
    try std.testing.expectEqual(@as(usize, 0), capture.failures);
    try std.testing.expect(pointers.resolveSeat(client, null));
    try std.testing.expect(!pointers.resolveSeat(client, 99));
}

test "virtual pointer fixed conversion preserves protocol units" {
    try std.testing.expectEqual(@as(f64, 1.5), fixedToDouble(384));
    try std.testing.expectEqual(@as(f64, -0.5), fixedToDouble(-128));
}

test "virtual pointer manager resolves default seat and exact mapped output" {
    const core = @import("wayring-core");
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var default_seat: SeatGlobal = undefined;
    try default_seat.init(std.testing.allocator, &server, "default", 0, null);
    defer default_seat.deinit();
    var other_seat: SeatGlobal = undefined;
    try other_seat.init(std.testing.allocator, &server, "other", 0, null);
    defer other_seat.deinit();
    var output: OutputGlobal = undefined;
    try output.init(std.testing.allocator, &server, .{
        .mode_size = .{ .width = 100, .height = 50 },
        .logical_size = .{ .width = 100, .height = 50 },
        .physical_size = .{ .width = 100, .height = 50 },
        .refresh_millihertz = 60_000,
        .scale = 1,
        .name = "default",
        .description = "Default output",
        .model = "test",
    });
    defer output.deinit();
    var other_output: OutputGlobal = undefined;
    try other_output.init(std.testing.allocator, &server, .{
        .mode_size = .{ .width = 10, .height = 10 },
        .logical_size = .{ .width = 10, .height = 10 },
        .physical_size = .{ .width = 10, .height = 10 },
        .refresh_millihertz = 60_000,
        .scale = 1,
        .name = "other",
        .description = "Other output",
        .model = "test",
    });
    defer other_output.deinit();
    var security: SecurityContextGlobal = undefined;
    var capture: TestListener = .{};
    var pointers: VirtualPointerGlobal = undefined;
    try pointers.init(
        std.testing.allocator,
        &server,
        &default_seat,
        &output,
        &security,
        capture.listener(),
    );
    defer pointers.deinit();
    const client = try server.createClient();
    defer server.destroyClient(client) catch {};
    var peer = wayring.Connection.init(
        std.testing.allocator,
        .client,
        wayring.default_max_frame_size,
    );
    defer peer.deinit();
    _ = try core.bootstrapDisplay(&peer);
    const registry: wayring.ObjectHandle = .{
        .id = 2,
        .generation = try core.getRegistry(&peer, 2),
    };
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    var default_seat_name: u32 = 0;
    var other_seat_name: u32 = 0;
    var output_names: [2]u32 = .{ 0, 0 };
    var output_count: usize = 0;
    var manager_name: u32 = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const event = try core.decodeRegistryEvent(&message, registry.id);
        if (event != .global) continue;
        if (event.global.name == default_seat.globalName())
            default_seat_name = event.global.name;
        if (event.global.name == other_seat.globalName())
            other_seat_name = event.global.name;
        if (std.mem.eql(u8, event.global.interface, generated.wl_output.name)) {
            output_names[output_count] = event.global.name;
            output_count += 1;
        }
        if (std.mem.eql(
            u8,
            event.global.interface,
            generated.zwlr_virtual_pointer_manager_v1.name,
        )) manager_name = event.global.name;
    }
    const default_seat_resource: wayring.ObjectHandle = .{
        .id = 3,
        .generation = try core.bind(
            &peer,
            registry.id,
            default_seat_name,
            generated.wl_seat.name,
            10,
            3,
            &generated.wl_seat,
        ),
    };
    const other_seat_resource: wayring.ObjectHandle = .{
        .id = 4,
        .generation = try core.bind(
            &peer,
            registry.id,
            other_seat_name,
            generated.wl_seat.name,
            10,
            4,
            &generated.wl_seat,
        ),
    };
    const output_resource: wayring.ObjectHandle = .{
        .id = 5,
        .generation = try core.bind(
            &peer,
            registry.id,
            output_names[0],
            generated.wl_output.name,
            4,
            5,
            &generated.wl_output,
        ),
    };
    const other_output_resource: wayring.ObjectHandle = .{
        .id = 6,
        .generation = try core.bind(
            &peer,
            registry.id,
            output_names[1],
            generated.wl_output.name,
            4,
            6,
            &generated.wl_output,
        ),
    };
    const manager_resource: wayring.ObjectHandle = .{
        .id = 7,
        .generation = try core.bind(
            &peer,
            registry.id,
            manager_name,
            generated.zwlr_virtual_pointer_manager_v1.name,
            2,
            7,
            &generated.zwlr_virtual_pointer_manager_v1,
        ),
    };
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    while (peer.popMessage()) |popped| {
        var message = popped;
        message.deinit();
    }

    const mapped = try generated.zwlr_virtual_pointer_manager_v1_types.requests.create_virtual_pointer_with_output(
        &peer,
        manager_resource,
        default_seat_resource,
        output_resource,
    );
    const inert = try generated.zwlr_virtual_pointer_manager_v1_types.requests.create_virtual_pointer(
        &peer,
        manager_resource,
        other_seat_resource,
    );
    const fallback = try generated.zwlr_virtual_pointer_manager_v1_types.requests.create_virtual_pointer_with_output(
        &peer,
        manager_resource,
        default_seat_resource,
        other_output_resource,
    );
    try transferToServer(&peer, client);
    try std.testing.expectEqual(@as(usize, 3), pointers.devices.items.len);
    try std.testing.expect(pointers.devices.items[0].active);
    try std.testing.expectEqual(&output, pointers.devices.items[0].mapped_output.?);
    try std.testing.expect(!pointers.devices.items[1].active);
    try std.testing.expect(pointers.devices.items[2].active);
    try std.testing.expect(pointers.devices.items[2].mapped_output == null);
    try std.testing.expect(default_seat.hasCapability(SeatGlobal.Capability.pointer));

    try generated.zwlr_virtual_pointer_v1_types.requests.motion(&peer, inert, 1, 256, 256);
    try generated.zwlr_virtual_pointer_v1_types.requests.motion_absolute(
        &peer,
        mapped,
        2,
        200,
        50,
        100,
        100,
    );
    try generated.zwlr_virtual_pointer_v1_types.requests.motion(
        &peer,
        fallback,
        3,
        -128,
        384,
    );
    try transferToServer(&peer, client);
    try std.testing.expectEqual(@as(usize, 2), capture.event_count);
    try std.testing.expect(capture.events[0] == .motion_absolute);
    try std.testing.expectEqual(&output, capture.outputs[0].?);
    try std.testing.expect(capture.events[1] == .motion);
    try std.testing.expectEqual(@as(f64, -0.5), capture.events[1].motion.dx);
    try std.testing.expectEqual(@as(f64, 1.5), capture.events[1].motion.dy);
    try std.testing.expect(capture.outputs[1] == null);
    try std.testing.expect(capture.sources[0] != capture.sources[1]);

    try generated.zwlr_virtual_pointer_v1_types.requests.destroy(&peer, mapped);
    try generated.zwlr_virtual_pointer_v1_types.requests.destroy(&peer, inert);
    try generated.zwlr_virtual_pointer_v1_types.requests.destroy(&peer, fallback);
    try transferToServer(&peer, client);
    try std.testing.expectEqual(@as(usize, 0), pointers.devices.items.len);
    try std.testing.expect(!default_seat.hasCapability(SeatGlobal.Capability.pointer));
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
