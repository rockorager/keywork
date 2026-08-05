//! Client-authorized pointer warping without synthetic motion events.

const PointerWarpGlobal = @This();

const std = @import("std");
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const CompositorGlobal = @import("CompositorGlobal.zig");
const SeatGlobal = @import("SeatGlobal.zig");
const render = @import("../render/types.zig");

const advertised_version: u32 = 1;

server: *Server,
seat: *SeatGlobal,
listener: Listener,
global_name: u32,

pub const Listener = struct {
    context: *anyopaque,
    surface_size: *const fn (*anyopaque, *const CompositorGlobal.Surface) ?render.Size,
    warp: *const fn (*anyopaque, *const CompositorGlobal.Surface, f64, f64) void,
};

pub fn init(
    self: *PointerWarpGlobal,
    server: *Server,
    seat: *SeatGlobal,
    listener: Listener,
) !void {
    self.* = .{
        .server = server,
        .seat = seat,
        .listener = listener,
        .global_name = undefined,
    };
    self.global_name = try server.createGlobal(
        &generated.wp_pointer_warp_v1,
        advertised_version,
        .{ .context = self, .bind = bind },
    );
}

pub fn deinit(self: *PointerWarpGlobal) void {
    self.server.removeGlobal(self.global_name) catch unreachable;
    self.* = undefined;
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *PointerWarpGlobal = @ptrCast(@alignCast(context));
    _ = client.createResource(id, &generated.wp_pointer_warp_v1, version, .{
        .context = self,
        .dispatch = dispatch,
    }) catch return client.postNoMemory();
}

fn dispatch(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const self: *PointerWarpGlobal = @ptrCast(@alignCast(context));
    switch (try generated.wp_pointer_warp_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .warp_pointer => |request| {
            const pointer = self.seat.pointerHandle(client, request.pointer) orelse return;
            const object = client.connection.object(request.surface) orelse return;
            const surface = CompositorGlobal.surfaceFor(client, .{
                .id = request.surface,
                .generation = object.generation,
            }) catch return;
            if (!self.seat.acceptsPointerEnterSerial(
                client,
                pointer,
                surface,
                request.serial,
            )) return;
            const size = self.listener.surface_size(self.listener.context, surface) orelse return;
            const x = fixedToDouble(request.x);
            const y = fixedToDouble(request.y);
            if (!pointWithinSurface(x, y, size)) return;
            self.listener.warp(self.listener.context, surface, x, y);
        },
    }
}

fn fixedToDouble(value: i32) f64 {
    return @as(f64, @floatFromInt(value)) / 256.0;
}

fn pointWithinSurface(x: f64, y: f64, size: render.Size) bool {
    return x >= 0 and y >= 0 and
        x < @as(f64, @floatFromInt(size.width)) and
        y < @as(f64, @floatFromInt(size.height));
}

const TestListener = struct {
    seat: *SeatGlobal,
    expected_surface: *CompositorGlobal.Surface,
    count: usize = 0,
    x: f64 = 0,
    y: f64 = 0,

    fn surfaceSize(
        context: *anyopaque,
        surface: *const CompositorGlobal.Surface,
    ) ?render.Size {
        const self: *@This() = @ptrCast(@alignCast(context));
        return if (surface == self.expected_surface)
            .{ .width = 20, .height = 15 }
        else
            .{ .width = 10, .height = 10 };
    }

    fn warp(
        context: *anyopaque,
        surface: *const CompositorGlobal.Surface,
        x: f64,
        y: f64,
    ) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (!self.seat.warpPointer(surface, fixedFromDouble(x), fixedFromDouble(y))) return;
        self.count += 1;
        self.x = x;
        self.y = y;
    }
};

test "pointer warp requires focused surface bounds and exact enter serial" {
    const core = @import("wayring-core");
    try std.testing.expect(pointWithinSurface(0, 0, .{ .width = 20, .height = 15 }));
    try std.testing.expect(pointWithinSurface(19.99, 14.99, .{ .width = 20, .height = 15 }));
    try std.testing.expect(!pointWithinSurface(-0.01, 1, .{ .width = 20, .height = 15 }));
    try std.testing.expect(!pointWithinSurface(20, 1, .{ .width = 20, .height = 15 }));

    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var compositor: CompositorGlobal = undefined;
    try compositor.init(std.testing.allocator, &server);
    defer compositor.deinit();
    var seat: SeatGlobal = undefined;
    try seat.init(
        std.testing.allocator,
        &server,
        "pointer-warp-test",
        SeatGlobal.Capability.pointer,
        null,
    );
    defer seat.deinit();
    var listener: TestListener = .{
        .seat = &seat,
        .expected_surface = undefined,
    };
    var pointer_warp: PointerWarpGlobal = undefined;
    try pointer_warp.init(&server, &seat, .{
        .context = &listener,
        .surface_size = TestListener.surfaceSize,
        .warp = TestListener.warp,
    });
    defer pointer_warp.deinit();

    const client = try server.createClient();
    defer server.destroyClient(client) catch unreachable;
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
    var compositor_name: u32 = 0;
    var seat_name: u32 = 0;
    var warp_name: u32 = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const event = try core.decodeRegistryEvent(&message, registry.id);
        if (event != .global) continue;
        if (std.mem.eql(u8, event.global.interface, generated.wl_compositor.name))
            compositor_name = event.global.name;
        if (std.mem.eql(u8, event.global.interface, generated.wl_seat.name))
            seat_name = event.global.name;
        if (std.mem.eql(u8, event.global.interface, generated.wp_pointer_warp_v1.name)) {
            warp_name = event.global.name;
            try std.testing.expectEqual(advertised_version, event.global.version);
        }
    }
    try std.testing.expect(compositor_name != 0 and seat_name != 0 and warp_name != 0);

    const compositor_resource: wayring.ObjectHandle = .{
        .id = 3,
        .generation = try core.bind(
            &peer,
            registry.id,
            compositor_name,
            generated.wl_compositor.name,
            6,
            3,
            &generated.wl_compositor,
        ),
    };
    const seat_resource: wayring.ObjectHandle = .{
        .id = 4,
        .generation = try core.bind(
            &peer,
            registry.id,
            seat_name,
            generated.wl_seat.name,
            10,
            4,
            &generated.wl_seat,
        ),
    };
    const warp_resource: wayring.ObjectHandle = .{
        .id = 5,
        .generation = try core.bind(
            &peer,
            registry.id,
            warp_name,
            generated.wp_pointer_warp_v1.name,
            1,
            5,
            &generated.wp_pointer_warp_v1,
        ),
    };
    const focus_handle = try generated.wl_compositor_types.requests.create_surface(
        &peer,
        compositor_resource,
    );
    const other_handle = try generated.wl_compositor_types.requests.create_surface(
        &peer,
        compositor_resource,
    );
    const pointer = try generated.wl_seat_types.requests.get_pointer(&peer, seat_resource);
    try transferToServer(&peer, client);
    const focus = try CompositorGlobal.surfaceFor(client, .{
        .id = focus_handle.id,
        .generation = client.connection.object(focus_handle.id).?.generation,
    });
    listener.expected_surface = focus;

    const serial = try seat.pointerEnter(focus, fixedFromDouble(2), fixedFromDouble(3));
    try transferFromServer(&peer, client);
    while (peer.popMessage()) |popped| {
        var message = popped;
        message.deinit();
    }
    try generated.wp_pointer_warp_v1_types.requests.warp_pointer(
        &peer,
        warp_resource,
        focus_handle,
        pointer,
        fixedFromDouble(10.5),
        fixedFromDouble(11.25),
        serial,
    );
    try transferToServer(&peer, client);
    try std.testing.expectEqual(@as(usize, 1), listener.count);
    try std.testing.expectEqual(@as(f64, 10.5), listener.x);
    try std.testing.expectEqual(@as(f64, 11.25), listener.y);
    try std.testing.expect(!try seat.pointerMotion(
        0,
        fixedFromDouble(10.5),
        fixedFromDouble(11.25),
    ));
    try transferFromServer(&peer, client);
    try std.testing.expect(peer.popMessage() == null);

    const ignored = [_]struct {
        surface: wayring.ObjectHandle,
        x: f64,
        y: f64,
        serial: u32,
    }{
        .{ .surface = focus_handle, .x = 1, .y = 1, .serial = serial +% 1 },
        .{ .surface = focus_handle, .x = 20, .y = 1, .serial = serial },
        .{ .surface = focus_handle, .x = -0.25, .y = 1, .serial = serial },
        .{ .surface = other_handle, .x = 1, .y = 1, .serial = serial },
    };
    for (ignored) |request| try generated.wp_pointer_warp_v1_types.requests.warp_pointer(
        &peer,
        warp_resource,
        request.surface,
        pointer,
        fixedFromDouble(request.x),
        fixedFromDouble(request.y),
        request.serial,
    );
    try transferToServer(&peer, client);
    try std.testing.expectEqual(@as(usize, 1), listener.count);
    try generated.wp_pointer_warp_v1_types.requests.destroy(&peer, warp_resource);
    try transferToServer(&peer, client);
    try std.testing.expectEqual(Server.ClientState.active, client.state);
}

fn fixedFromDouble(value: f64) i32 {
    return @intFromFloat(value * 256.0);
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
