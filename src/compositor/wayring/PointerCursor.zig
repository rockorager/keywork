//! Client-provided pointer cursor role, selection, and logical placement.

const PointerCursor = @This();

const std = @import("std");
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const CompositorGlobal = @import("CompositorGlobal.zig");
const SeatGlobal = @import("SeatGlobal.zig");
const render = @import("../render/types.zig");

allocator: std.mem.Allocator,
listener: Listener,
roles: std.ArrayList(*Role) = .empty,
selected: ?Selected = null,
position_x: f64 = 0,
position_y: f64 = 0,

pub const Listener = struct {
    context: *anyopaque,
    repaint: *const fn (*anyopaque) void,
};

pub const Cursor = union(enum) {
    surface: struct {
        surface: *CompositorGlobal.Surface,
        root: *CompositorGlobal.Surface,
        x: i32,
        y: i32,
    },
    shape: struct {
        buffer: render.PixelBuffer,
        x: i32,
        y: i32,
    },
};

const Role = struct {
    owner: *PointerCursor,
    surface: *CompositorGlobal.Surface,
};

const SurfaceSelection = struct {
    surface: *CompositorGlobal.Surface,
    hotspot_x: i32,
    hotspot_y: i32,
};

const ShapeSelection = struct {
    buffer: render.PixelBuffer,
    hotspot_x: i32,
    hotspot_y: i32,
};

const Selected = union(enum) {
    surface: SurfaceSelection,
    shape: ShapeSelection,
};

pub fn init(self: *PointerCursor, allocator: std.mem.Allocator, listener: Listener) void {
    self.* = .{
        .allocator = allocator,
        .listener = listener,
    };
}

pub fn deinit(self: *PointerCursor) void {
    std.debug.assert(self.roles.items.len == 0);
    std.debug.assert(self.selected == null);
    self.roles.deinit(self.allocator);
    self.* = undefined;
}

pub fn handler(self: *PointerCursor) SeatGlobal.CursorHandler {
    return .{
        .context = self,
        .handle = handleIntent,
        .clear = clearSelection,
    };
}

pub fn setPosition(self: *PointerCursor, x: f64, y: f64) void {
    std.debug.assert(std.math.isFinite(x) and std.math.isFinite(y));
    if (self.position_x == x and self.position_y == y) return;
    self.position_x = x;
    self.position_y = y;
    if (self.selected != null) self.listener.repaint(self.listener.context);
}

pub fn current(self: *const PointerCursor) ?Cursor {
    const selected = self.selected orelse return null;
    return switch (selected) {
        .surface => |surface| if (surface.surface.resource_alive) .{ .surface = .{
            .surface = surface.surface,
            .root = surface.surface,
            .x = cursorCoordinate(self.position_x, surface.hotspot_x),
            .y = cursorCoordinate(self.position_y, surface.hotspot_y),
        } } else null,
        .shape => |shape| .{ .shape = .{
            .buffer = shape.buffer,
            .x = cursorCoordinate(self.position_x, shape.hotspot_x),
            .y = cursorCoordinate(self.position_y, shape.hotspot_y),
        } },
    };
}

pub fn setShape(
    self: *PointerCursor,
    buffer: render.PixelBuffer,
    hotspot_x: i32,
    hotspot_y: i32,
) void {
    self.select(.{ .shape = .{
        .buffer = buffer,
        .hotspot_x = hotspot_x,
        .hotspot_y = hotspot_y,
    } });
}

pub fn clearShapes(self: *PointerCursor) void {
    if (self.selected) |selected| if (selected == .shape) self.select(null);
}

pub fn isCursorSurface(
    self: *const PointerCursor,
    surface: *const CompositorGlobal.Surface,
) bool {
    return findRole(self, surface) != null;
}

fn handleIntent(context: *anyopaque, intent: SeatGlobal.CursorIntent) !void {
    const self: *PointerCursor = @ptrCast(@alignCast(context));
    const surface = intent.surface orelse {
        self.select(null);
        return;
    };
    if (findRole(self, surface) == null) {
        self.roles.ensureUnusedCapacity(self.allocator, 1) catch
            return intent.client.postNoMemory();
        const role = self.allocator.create(Role) catch return intent.client.postNoMemory();
        role.* = .{ .owner = self, .surface = surface };
        surface.setRole(self, role, cursorSurfaceDestroyed) catch {
            self.allocator.destroy(role);
            return intent.client.postError(
                intent.pointer,
                @intFromEnum(generated.wl_pointer_types.@"error".role),
                "wl_surface is unavailable for the pointer cursor role",
            );
        };
        self.roles.appendAssumeCapacity(role);
    }
    self.select(.{ .surface = .{
        .surface = surface,
        .hotspot_x = intent.hotspot_x,
        .hotspot_y = intent.hotspot_y,
    } });
}

fn clearSelection(context: *anyopaque) void {
    const self: *PointerCursor = @ptrCast(@alignCast(context));
    self.select(null);
}

fn select(self: *PointerCursor, selected: ?Selected) void {
    if (std.meta.eql(self.selected, selected)) return;
    self.selected = selected;
    self.listener.repaint(self.listener.context);
}

fn findRole(
    self: *const PointerCursor,
    surface: *const CompositorGlobal.Surface,
) ?*Role {
    for (self.roles.items) |role| if (role.surface == surface) return role;
    return null;
}

fn cursorSurfaceDestroyed(context: *anyopaque) void {
    const role: *Role = @ptrCast(@alignCast(context));
    const self = role.owner;
    if (self.selected) |selected| {
        switch (selected) {
            .surface => |surface| if (surface.surface == role.surface) self.select(null),
            .shape => {},
        }
    }
    for (self.roles.items, 0..) |candidate, index| {
        if (candidate != role) continue;
        _ = self.roles.orderedRemove(index);
        self.allocator.destroy(role);
        return;
    }
    unreachable;
}

pub fn cursorCoordinate(value: f64, hotspot: i32) i32 {
    const coordinate: i64 = @intFromFloat(@floor(value));
    return @intCast(std.math.clamp(
        coordinate - @as(i64, hotspot),
        std.math.minInt(i32),
        std.math.maxInt(i32),
    ));
}

const RepaintCounter = struct {
    count: usize = 0,

    fn repaint(context: *anyopaque) void {
        const self: *RepaintCounter = @ptrCast(@alignCast(context));
        self.count += 1;
    }
};

test "pointer cursor role follows focus serial, position, and surface lifetime" {
    const core = @import("wayring-core");
    try std.testing.expectEqual(
        std.math.maxInt(i32),
        cursorCoordinate(@floatFromInt(std.math.maxInt(i32)), -1),
    );
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var compositor: CompositorGlobal = undefined;
    try compositor.init(std.testing.allocator, &server);
    defer compositor.deinit();
    var repaint: RepaintCounter = .{};
    var cursor: PointerCursor = undefined;
    cursor.init(std.testing.allocator, .{
        .context = &repaint,
        .repaint = RepaintCounter.repaint,
    });
    defer cursor.deinit();
    var seat: SeatGlobal = undefined;
    try seat.init(
        std.testing.allocator,
        &server,
        "cursor-test",
        SeatGlobal.Capability.pointer,
        cursor.handler(),
    );
    defer seat.deinit();
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
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const event = try core.decodeRegistryEvent(&message, registry.id);
        if (event != .global) continue;
        if (std.mem.eql(u8, event.global.interface, generated.wl_compositor.name))
            compositor_name = event.global.name;
        if (std.mem.eql(u8, event.global.interface, generated.wl_seat.name))
            seat_name = event.global.name;
    }
    try std.testing.expect(compositor_name != 0 and seat_name != 0);

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
    const focus_handle = try generated.wl_compositor_types.requests.create_surface(
        &peer,
        compositor_resource,
    );
    const cursor_handle = try generated.wl_compositor_types.requests.create_surface(
        &peer,
        compositor_resource,
    );
    const pointer = try generated.wl_seat_types.requests.get_pointer(&peer, seat_resource);
    try transferToServer(&peer, client);
    const focus = try CompositorGlobal.surfaceFor(client, .{
        .id = focus_handle.id,
        .generation = client.connection.object(focus_handle.id).?.generation,
    });
    const cursor_surface = try CompositorGlobal.surfaceFor(client, .{
        .id = cursor_handle.id,
        .generation = client.connection.object(cursor_handle.id).?.generation,
    });
    cursor.setPosition(10.9, 20.9);
    const serial = try seat.pointerEnter(focus, 10 * 256, 20 * 256);
    try generated.wl_pointer_types.requests.set_cursor(
        &peer,
        pointer,
        serial +% 1,
        cursor_handle,
        1,
        2,
    );
    try generated.wl_pointer_types.requests.set_cursor(
        &peer,
        pointer,
        serial,
        cursor_handle,
        3,
        4,
    );
    try transferToServer(&peer, client);
    try std.testing.expect(cursor.isCursorSurface(cursor_surface));
    try std.testing.expectEqual(@as(usize, 1), cursor.roles.items.len);
    try std.testing.expectEqual(@as(usize, 1), repaint.count);
    const first = cursor.current().?.surface;
    try std.testing.expect(first.surface == cursor_surface);
    try std.testing.expectEqual(@as(i32, 7), first.x);
    try std.testing.expectEqual(@as(i32, 16), first.y);

    cursor.setPosition(
        @floatFromInt(std.math.minInt(i32)),
        @floatFromInt(std.math.maxInt(i32)),
    );
    const saturated = cursor.current().?.surface;
    try std.testing.expectEqual(std.math.minInt(i32), saturated.x);
    try std.testing.expectEqual(std.math.maxInt(i32) - 4, saturated.y);
    try std.testing.expectEqual(@as(usize, 2), repaint.count);

    _ = try seat.pointerLeave();
    try std.testing.expect(cursor.current() == null);
    try std.testing.expect(cursor.isCursorSurface(cursor_surface));
    try std.testing.expectEqual(@as(usize, 3), repaint.count);

    const second_serial = try seat.pointerEnter(focus, 10 * 256, 20 * 256);
    try generated.wl_pointer_types.requests.set_cursor(
        &peer,
        pointer,
        second_serial,
        cursor_handle,
        0,
        0,
    );
    try transferToServer(&peer, client);
    try std.testing.expect(cursor.current() != null);
    try generated.wl_surface_types.requests.destroy(&peer, cursor_handle);
    try transferToServer(&peer, client);
    try std.testing.expect(cursor.current() == null);
    try std.testing.expect(!cursor.isCursorSurface(cursor_surface));
    try std.testing.expectEqual(@as(usize, 0), cursor.roles.items.len);
    try std.testing.expectEqual(@as(usize, 5), repaint.count);

    var shape_pixels = [_]u32{0xffffffff} ** 4;
    const shape_buffer: render.PixelBuffer = .{
        .size = .{ .width = 2, .height = 2 },
        .stride_pixels = 2,
        .pixels = &shape_pixels,
    };
    cursor.setShape(shape_buffer, 1, 2);
    const shape = cursor.current().?.shape;
    try std.testing.expectEqual(shape_buffer.size, shape.buffer.size);
    try std.testing.expectEqual(std.math.minInt(i32), shape.x);
    try std.testing.expectEqual(std.math.maxInt(i32) - 2, shape.y);
    cursor.clearShapes();
    try std.testing.expect(cursor.current() == null);
    try std.testing.expectEqual(@as(usize, 7), repaint.count);

    var foreign_role: u8 = 0;
    try focus.setRole(&foreign_role, &foreign_role, ignoreRoleDestroyed);
    try generated.wl_pointer_types.requests.set_cursor(
        &peer,
        pointer,
        second_serial,
        focus_handle,
        0,
        0,
    );
    try std.testing.expectError(error.ProtocolError, transferToServer(&peer, client));
    try std.testing.expect(cursor.current() == null);
    try std.testing.expectEqual(@as(usize, 0), cursor.roles.items.len);
}

fn ignoreRoleDestroyed(_: *anyopaque) void {}

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
