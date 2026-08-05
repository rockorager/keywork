//! Native relative-pointer-v1 policy for the focused pointer client.

const RelativePointerGlobal = @This();

const std = @import("std");
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const CompositorGlobal = @import("CompositorGlobal.zig");
const SeatGlobal = @import("SeatGlobal.zig");

const advertised_version: u32 = 1;

allocator: std.mem.Allocator,
server: *Server,
seat: *SeatGlobal,
global_name: u32,
devices: std.ArrayList(*Device) = .empty,

const Device = struct {
    owner: *RelativePointerGlobal,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    pointer: ?wayring.ObjectHandle,
};

pub fn init(
    self: *RelativePointerGlobal,
    allocator: std.mem.Allocator,
    server: *Server,
    seat: *SeatGlobal,
) !void {
    self.* = .{
        .allocator = allocator,
        .server = server,
        .seat = seat,
        .global_name = undefined,
    };
    self.global_name = try server.createGlobal(
        &generated.zwp_relative_pointer_manager_v1,
        advertised_version,
        .{ .context = self, .bind = bind },
    );
}

pub fn deinit(self: *RelativePointerGlobal) void {
    std.debug.assert(self.devices.items.len == 0);
    self.server.removeGlobal(self.global_name) catch unreachable;
    self.devices.deinit(self.allocator);
    self.* = undefined;
}

pub fn motion(
    self: *RelativePointerGlobal,
    time_microseconds: u64,
    dx: f64,
    dy: f64,
    dx_unaccelerated: f64,
    dy_unaccelerated: f64,
) !void {
    std.debug.assert(std.math.isFinite(dx));
    std.debug.assert(std.math.isFinite(dy));
    std.debug.assert(std.math.isFinite(dx_unaccelerated));
    std.debug.assert(std.math.isFinite(dy_unaccelerated));
    const focus = self.seat.pointerFocus() orelse return;
    if (!focus.resource_alive) return;
    const time = timestampParts(time_microseconds);
    for (self.devices.items) |device| {
        if (device.client != focus.client) continue;
        const pointer = device.pointer orelse continue;
        if (!self.seat.pointerHandleIsActive(device.client, pointer)) continue;
        try generated.zwp_relative_pointer_v1_types.events.relative_motion(
            &device.client.connection,
            device.resource,
            time.high,
            time.low,
            fixed(dx),
            fixed(dy),
            fixed(dx_unaccelerated),
            fixed(dy_unaccelerated),
        );
    }
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *RelativePointerGlobal = @ptrCast(@alignCast(context));
    _ = client.createResource(id, &generated.zwp_relative_pointer_manager_v1, version, .{
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
    const self: *RelativePointerGlobal = @ptrCast(@alignCast(context));
    switch (try generated.zwp_relative_pointer_manager_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .get_relative_pointer => |request| {
            const device = self.allocator.create(Device) catch
                return client.postNoMemory();
            errdefer self.allocator.destroy(device);
            self.devices.ensureUnusedCapacity(self.allocator, 1) catch
                return client.postNoMemory();
            const version = try client.resourceVersion(
                resource,
                &generated.zwp_relative_pointer_manager_v1,
            );
            device.* = .{
                .owner = self,
                .client = client,
                .resource = undefined,
                .pointer = self.seat.pointerHandle(client, request.pointer),
            };
            device.resource = client.createResource(
                request.id,
                &generated.zwp_relative_pointer_v1,
                version,
                .{
                    .context = device,
                    .dispatch = dispatchDevice,
                    .destroy = destroyDevice,
                },
            ) catch return client.postNoMemory();
            self.devices.appendAssumeCapacity(device);
        },
    }
}

fn dispatchDevice(
    _: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    _ = try generated.zwp_relative_pointer_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    );
}

fn destroyDevice(
    context: *anyopaque,
    _: *Server.Client,
    _: wayring.ObjectHandle,
) void {
    const device: *Device = @ptrCast(@alignCast(context));
    for (device.owner.devices.items, 0..) |candidate, index| {
        if (candidate != device) continue;
        const owner = device.owner;
        _ = owner.devices.orderedRemove(index);
        owner.allocator.destroy(device);
        return;
    }
    unreachable;
}

fn timestampParts(time_microseconds: u64) struct { high: u32, low: u32 } {
    return .{
        .high = @truncate(time_microseconds >> 32),
        .low = @truncate(time_microseconds),
    };
}

fn fixed(value: f64) i32 {
    const minimum = @as(f64, @floatFromInt(std.math.minInt(i32))) / 256.0;
    const maximum = @as(f64, @floatFromInt(std.math.maxInt(i32))) / 256.0;
    return @intFromFloat(std.math.clamp(value, minimum, maximum) * 256.0);
}

const BoundGlobals = struct {
    compositor: wayring.ObjectHandle,
    seat: wayring.ObjectHandle,
    manager: wayring.ObjectHandle,
};

fn bindGlobals(
    peer: *wayring.Connection,
    client: *Server.Client,
) !BoundGlobals {
    const core = @import("wayring-core");
    _ = try core.bootstrapDisplay(peer);
    const registry: wayring.ObjectHandle = .{
        .id = 2,
        .generation = try core.getRegistry(peer, 2),
    };
    try transferToServer(peer, client);
    try transferFromServer(peer, client);
    var compositor_name: u32 = 0;
    var seat_name: u32 = 0;
    var manager_name: u32 = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const event = try core.decodeRegistryEvent(&message, registry.id);
        if (event != .global) continue;
        if (std.mem.eql(u8, event.global.interface, generated.wl_compositor.name))
            compositor_name = event.global.name;
        if (std.mem.eql(u8, event.global.interface, generated.wl_seat.name))
            seat_name = event.global.name;
        if (std.mem.eql(
            u8,
            event.global.interface,
            generated.zwp_relative_pointer_manager_v1.name,
        )) {
            manager_name = event.global.name;
            try std.testing.expectEqual(advertised_version, event.global.version);
        }
    }
    try std.testing.expect(compositor_name != 0);
    try std.testing.expect(seat_name != 0);
    try std.testing.expect(manager_name != 0);
    const globals: BoundGlobals = .{
        .compositor = .{
            .id = 3,
            .generation = try core.bind(
                peer,
                registry.id,
                compositor_name,
                generated.wl_compositor.name,
                6,
                3,
                &generated.wl_compositor,
            ),
        },
        .seat = .{
            .id = 4,
            .generation = try core.bind(
                peer,
                registry.id,
                seat_name,
                generated.wl_seat.name,
                10,
                4,
                &generated.wl_seat,
            ),
        },
        .manager = .{
            .id = 5,
            .generation = try core.bind(
                peer,
                registry.id,
                manager_name,
                generated.zwp_relative_pointer_manager_v1.name,
                advertised_version,
                5,
                &generated.zwp_relative_pointer_manager_v1,
            ),
        },
    };
    try transferToServer(peer, client);
    try transferFromServer(peer, client);
    while (peer.popMessage()) |popped| {
        var message = popped;
        message.deinit();
    }
    return globals;
}

test "native relative pointers follow focus and survive manager destruction" {
    const time_microseconds: u64 = 0x0123_4567_89ab_cdef;
    const parts = timestampParts(time_microseconds);
    try std.testing.expectEqual(@as(u32, 0x0123_4567), parts.high);
    try std.testing.expectEqual(@as(u32, 0x89ab_cdef), parts.low);
    try std.testing.expectEqual(@as(i32, 384), fixed(1.5));
    try std.testing.expectEqual(std.math.maxInt(i32), fixed(1.0e30));
    try std.testing.expectEqual(std.math.minInt(i32), fixed(-1.0e30));

    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var compositor: CompositorGlobal = undefined;
    try compositor.init(std.testing.allocator, &server);
    defer compositor.deinit();
    var seat: SeatGlobal = undefined;
    try seat.init(
        std.testing.allocator,
        &server,
        "default",
        SeatGlobal.Capability.pointer,
        null,
    );
    defer seat.deinit();
    var relative: RelativePointerGlobal = undefined;
    try relative.init(std.testing.allocator, &server, &seat);
    defer relative.deinit();

    {
        const focused_client = try server.createClient();
        defer server.destroyClient(focused_client) catch unreachable;
        var focused_peer = wayring.Connection.init(
            std.testing.allocator,
            .client,
            wayring.default_max_frame_size,
        );
        defer focused_peer.deinit();
        const focused_globals = try bindGlobals(&focused_peer, focused_client);
        const focused_surface = try generated.wl_compositor_types.requests.create_surface(
            &focused_peer,
            focused_globals.compositor,
        );
        const focused_pointer = try generated.wl_seat_types.requests.get_pointer(
            &focused_peer,
            focused_globals.seat,
        );
        const focused_relative = try generated.zwp_relative_pointer_manager_v1_types.requests.get_relative_pointer(
            &focused_peer,
            focused_globals.manager,
            focused_pointer,
        );
        try generated.zwp_relative_pointer_manager_v1_types.requests.destroy(
            &focused_peer,
            focused_globals.manager,
        );
        try transferToServer(&focused_peer, focused_client);

        const unfocused_client = try server.createClient();
        defer server.destroyClient(unfocused_client) catch unreachable;
        var unfocused_peer = wayring.Connection.init(
            std.testing.allocator,
            .client,
            wayring.default_max_frame_size,
        );
        defer unfocused_peer.deinit();
        const unfocused_globals = try bindGlobals(&unfocused_peer, unfocused_client);
        const unfocused_pointer = try generated.wl_seat_types.requests.get_pointer(
            &unfocused_peer,
            unfocused_globals.seat,
        );
        const unfocused_relative = try generated.zwp_relative_pointer_manager_v1_types.requests.get_relative_pointer(
            &unfocused_peer,
            unfocused_globals.manager,
            unfocused_pointer,
        );
        try transferToServer(&unfocused_peer, unfocused_client);

        const surface = try CompositorGlobal.surfaceFor(focused_client, .{
            .id = focused_surface.id,
            .generation = focused_client.connection.object(focused_surface.id).?.generation,
        });
        _ = try seat.pointerEnter(surface, 0, 0);
        try transferFromServer(&focused_peer, focused_client);
        while (focused_peer.popMessage()) |popped| {
            var message = popped;
            message.deinit();
        }

        try relative.motion(
            time_microseconds,
            1.5,
            -2.25,
            1.0e30,
            -1.0e30,
        );
        try transferFromServer(&focused_peer, focused_client);
        try transferFromServer(&unfocused_peer, unfocused_client);
        var motion_count: usize = 0;
        while (focused_peer.popMessage()) |popped| {
            var message = popped;
            defer message.deinit();
            switch (try generated.zwp_relative_pointer_v1_types.decodeEvent(
                &focused_peer,
                focused_relative,
                &message,
            )) {
                .relative_motion => |event| {
                    motion_count += 1;
                    try std.testing.expectEqual(parts.high, event.utime_hi);
                    try std.testing.expectEqual(parts.low, event.utime_lo);
                    try std.testing.expectEqual(@as(i32, 384), event.dx);
                    try std.testing.expectEqual(@as(i32, -576), event.dy);
                    try std.testing.expectEqual(std.math.maxInt(i32), event.dx_unaccel);
                    try std.testing.expectEqual(std.math.minInt(i32), event.dy_unaccel);
                },
            }
        }
        try std.testing.expectEqual(@as(usize, 1), motion_count);
        try std.testing.expect(unfocused_peer.popMessage() == null);

        try generated.wl_pointer_types.requests.release(
            &focused_peer,
            focused_pointer,
        );
        try transferToServer(&focused_peer, focused_client);
        try relative.motion(1, 1, 1, 1, 1);
        try transferFromServer(&focused_peer, focused_client);
        while (focused_peer.popMessage()) |popped| {
            var message = popped;
            defer message.deinit();
            if (message.object_id == focused_relative.id)
                return error.DestroyedPointerReceivedMotion;
        }

        try generated.zwp_relative_pointer_v1_types.requests.destroy(
            &focused_peer,
            focused_relative,
        );
        try generated.zwp_relative_pointer_v1_types.requests.destroy(
            &unfocused_peer,
            unfocused_relative,
        );
        try generated.zwp_relative_pointer_manager_v1_types.requests.destroy(
            &unfocused_peer,
            unfocused_globals.manager,
        );
        try transferToServer(&focused_peer, focused_client);
        try transferToServer(&unfocused_peer, unfocused_client);
        try std.testing.expectEqual(@as(usize, 0), relative.devices.items.len);
    }
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
