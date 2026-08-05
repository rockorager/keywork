//! Native cursor-shape protocol policy and themed image ownership.

const CursorShapeGlobal = @This();

const std = @import("std");
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const CompositorGlobal = @import("CompositorGlobal.zig");
const PointerCursor = @import("PointerCursor.zig");
const SeatGlobal = @import("SeatGlobal.zig");
const TabletGlobal = @import("TabletGlobal.zig");
const render = @import("../render/types.zig");

const xcursor = @cImport({
    @cInclude("X11/Xcursor/Xcursor.h");
});

const log = std.log.scoped(.cursor_shape);
const advertised_version: u32 = 2;
const Shape = generated.wp_cursor_shape_device_v1_types.shape;
const shape_count = @intFromEnum(Shape.all_resize);
const default_cursor_size = 24;

allocator: std.mem.Allocator,
server: *Server,
seat: *SeatGlobal,
pointer_cursor: *PointerCursor,
tablet: *TabletGlobal,
global_name: u32,
devices: std.ArrayList(*Device) = .empty,
images: [shape_count]?*xcursor.XcursorImage = @splat(null),
source_cache_ids: [shape_count]u64 = @splat(0),
theme: ?[*:0]u8,
size: c_int,

const Target = union(enum) {
    pointer: wayring.ObjectHandle,
    tablet_tool: wayring.ObjectHandle,
};

const Device = struct {
    owner: *CursorShapeGlobal,
    target: ?Target,
};

const CursorImage = struct {
    buffer: render.PixelBuffer,
    hotspot_x: i32,
    hotspot_y: i32,
};

pub fn init(
    self: *CursorShapeGlobal,
    allocator: std.mem.Allocator,
    server: *Server,
    seat: *SeatGlobal,
    pointer_cursor: *PointerCursor,
    tablet: *TabletGlobal,
) !void {
    self.* = .{
        .allocator = allocator,
        .server = server,
        .seat = seat,
        .pointer_cursor = pointer_cursor,
        .tablet = tablet,
        .global_name = undefined,
        .theme = std.c.getenv("XCURSOR_THEME"),
        .size = configuredSize(),
    };
    self.global_name = try server.createGlobal(
        &generated.wp_cursor_shape_manager_v1,
        advertised_version,
        .{ .context = self, .bind = bind },
    );
}

pub fn deinit(self: *CursorShapeGlobal) void {
    std.debug.assert(self.devices.items.len == 0);
    self.pointer_cursor.clearShapes();
    self.tablet.clearCursorShapes();
    self.server.removeGlobal(self.global_name) catch unreachable;
    for (self.images) |image| if (image) |loaded|
        xcursor.XcursorImageDestroy(loaded);
    self.devices.deinit(self.allocator);
    self.* = undefined;
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *CursorShapeGlobal = @ptrCast(@alignCast(context));
    _ = client.createResource(id, &generated.wp_cursor_shape_manager_v1, version, .{
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
    const self: *CursorShapeGlobal = @ptrCast(@alignCast(context));
    switch (try generated.wp_cursor_shape_manager_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .get_pointer => |request| try self.createDevice(
            client,
            resource,
            request.cursor_shape_device,
            if (self.seat.pointerHandle(client, request.pointer)) |handle|
                .{ .pointer = handle }
            else
                null,
        ),
        .get_tablet_tool_v2 => |request| try self.createDevice(
            client,
            resource,
            request.cursor_shape_device,
            if (self.tablet.toolHandle(client, request.tablet_tool)) |handle|
                .{ .tablet_tool = handle }
            else
                null,
        ),
    }
}

fn createDevice(
    self: *CursorShapeGlobal,
    client: *Server.Client,
    manager: wayring.ObjectHandle,
    id: u32,
    target: ?Target,
) !void {
    self.devices.ensureUnusedCapacity(self.allocator, 1) catch
        return client.postNoMemory();
    const device = self.allocator.create(Device) catch return client.postNoMemory();
    errdefer self.allocator.destroy(device);
    const version = try client.resourceVersion(
        manager,
        &generated.wp_cursor_shape_manager_v1,
    );
    device.* = .{
        .owner = self,
        .target = target,
    };
    _ = client.createResource(
        id,
        &generated.wp_cursor_shape_device_v1,
        version,
        .{
            .context = device,
            .dispatch = dispatchDevice,
            .destroy = destroyDevice,
        },
    ) catch return client.postNoMemory();
    self.devices.appendAssumeCapacity(device);
}

fn dispatchDevice(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const device: *Device = @ptrCast(@alignCast(context));
    switch (try generated.wp_cursor_shape_device_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .set_shape => |request| {
            const version = try client.resourceVersion(
                resource,
                &generated.wp_cursor_shape_device_v1,
            );
            if (request.shape < @intFromEnum(Shape.default) or
                request.shape > maximumShape(version))
            {
                return client.postError(
                    resource,
                    @intFromEnum(generated.wp_cursor_shape_device_v1_types.@"error".invalid_shape),
                    "shape is unavailable at this cursor-shape version",
                );
            }
            const target = device.target orelse return;
            const image = device.owner.cursorImage(@enumFromInt(request.shape)) orelse return;
            switch (target) {
                .pointer => |pointer| {
                    if (!device.owner.seat.acceptsPointerCursorSerial(
                        client,
                        pointer,
                        request.serial,
                    )) return;
                    device.owner.pointer_cursor.setShape(
                        image.buffer,
                        image.hotspot_x,
                        image.hotspot_y,
                    );
                },
                .tablet_tool => |tool| device.owner.tablet.setCursorShape(
                    client,
                    tool,
                    request.serial,
                    image.buffer,
                    image.hotspot_x,
                    image.hotspot_y,
                ),
            }
        },
    }
}

fn destroyDevice(
    context: *anyopaque,
    _: *Server.Client,
    _: wayring.ObjectHandle,
) void {
    const device: *Device = @ptrCast(@alignCast(context));
    const self = device.owner;
    for (self.devices.items, 0..) |candidate, index| {
        if (candidate != device) continue;
        _ = self.devices.orderedRemove(index);
        self.allocator.destroy(device);
        return;
    }
    unreachable;
}

fn cursorImage(self: *CursorShapeGlobal, shape: Shape) ?CursorImage {
    const index = shapeIndex(shape);
    const image = self.images[index] orelse loaded: {
        const loaded_image = self.loadImage(shape) orelse return null;
        self.images[index] = loaded_image;
        self.source_cache_ids[index] = render.allocateSourceCacheId();
        break :loaded loaded_image;
    };
    return .{
        .buffer = pixelBuffer(image, self.source_cache_ids[index]) orelse return null,
        .hotspot_x = @intCast(image.xhot),
        .hotspot_y = @intCast(image.yhot),
    };
}

fn loadImage(self: *CursorShapeGlobal, shape: Shape) ?*xcursor.XcursorImage {
    const name = shapeName(shape);
    const image = xcursor.XcursorLibraryLoadImage(
        name,
        if (self.theme) |theme| theme else null,
        self.size,
    ) orelse xcursor.XcursorLibraryLoadImage(
        if (shape == .default) "left_ptr" else "default",
        if (self.theme) |theme| theme else null,
        self.size,
    ) orelse {
        log.warn("Xcursor theme has no image for {s} at size {d}", .{ name, self.size });
        return null;
    };
    return @ptrCast(image);
}

fn pixelBuffer(image: *xcursor.XcursorImage, source_cache_id: u64) ?render.PixelBuffer {
    const pixel_count = std.math.mul(usize, image.width, image.height) catch return null;
    const pixels: [*]u32 = @ptrCast(image.pixels);
    return .{
        .size = .{ .width = image.width, .height = image.height },
        .stride_pixels = image.width,
        .pixels = pixels[0..pixel_count],
        .source_cache = .{ .id = source_cache_id, .version = 1 },
    };
}

fn configuredSize() c_int {
    const value_z = std.c.getenv("XCURSOR_SIZE") orelse return default_cursor_size;
    const value = std.fmt.parseInt(u15, std.mem.span(value_z), 10) catch
        return default_cursor_size;
    return if (value > 0) value else default_cursor_size;
}

fn maximumShape(version: u32) u32 {
    return if (version >= 2)
        @intFromEnum(Shape.all_resize)
    else
        @intFromEnum(Shape.zoom_out);
}

fn shapeIndex(shape: Shape) usize {
    return @intCast(@intFromEnum(shape) - 1);
}

fn shapeName(shape: Shape) [:0]const u8 {
    return switch (shape) {
        .default => "default",
        .context_menu => "context-menu",
        .help => "help",
        .pointer => "pointer",
        .progress => "progress",
        .wait => "wait",
        .cell => "cell",
        .crosshair => "crosshair",
        .text => "text",
        .vertical_text => "vertical-text",
        .alias => "alias",
        .copy => "copy",
        .move => "move",
        .no_drop => "no-drop",
        .not_allowed => "not-allowed",
        .grab => "grab",
        .grabbing => "grabbing",
        .e_resize => "e-resize",
        .n_resize => "n-resize",
        .ne_resize => "ne-resize",
        .nw_resize => "nw-resize",
        .s_resize => "s-resize",
        .se_resize => "se-resize",
        .sw_resize => "sw-resize",
        .w_resize => "w-resize",
        .ew_resize => "ew-resize",
        .ns_resize => "ns-resize",
        .nesw_resize => "nesw-resize",
        .nwse_resize => "nwse-resize",
        .col_resize => "col-resize",
        .row_resize => "row-resize",
        .all_scroll => "all-scroll",
        .zoom_in => "zoom-in",
        .zoom_out => "zoom-out",
        .dnd_ask => "dnd-ask",
        .all_resize => "all-resize",
        _ => unreachable,
    };
}

const TestListener = struct {
    fn surfaceCoordinates(
        _: *anyopaque,
        _: *CompositorGlobal.Surface,
        x: f64,
        y: f64,
    ) ?TabletGlobal.Point {
        return .{ .x = x, .y = y };
    }

    fn repaint(_: *anyopaque) void {}
};

test "cursor-shape pointer device survives manager and rejects a destroyed pointer" {
    const core = @import("wayring-core");
    try std.testing.expectEqualStrings("context-menu", shapeName(.context_menu));
    try std.testing.expectEqualStrings("nw-resize", shapeName(.nw_resize));
    try std.testing.expectEqualStrings("nwse-resize", shapeName(.nwse_resize));
    try std.testing.expectEqualStrings("dnd-ask", shapeName(.dnd_ask));
    try std.testing.expectEqual(@intFromEnum(Shape.zoom_out), maximumShape(1));
    try std.testing.expectEqual(@intFromEnum(Shape.all_resize), maximumShape(2));

    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var compositor: CompositorGlobal = undefined;
    try compositor.init(std.testing.allocator, &server);
    defer compositor.deinit();
    var pointer_cursor: PointerCursor = undefined;
    pointer_cursor.init(std.testing.allocator, .{
        .context = undefined,
        .repaint = TestListener.repaint,
    });
    defer pointer_cursor.deinit();
    var seat: SeatGlobal = undefined;
    try seat.init(
        std.testing.allocator,
        &server,
        "cursor-shape-test",
        SeatGlobal.Capability.pointer,
        pointer_cursor.handler(),
    );
    defer seat.deinit();
    var tablet: TabletGlobal = undefined;
    try tablet.init(std.testing.allocator, &server, &seat, .{
        .context = undefined,
        .surface_coordinates = TestListener.surfaceCoordinates,
        .repaint = TestListener.repaint,
    });
    defer tablet.deinit();
    var cursor_shape: CursorShapeGlobal = undefined;
    try cursor_shape.init(
        std.testing.allocator,
        &server,
        &seat,
        &pointer_cursor,
        &tablet,
    );
    defer cursor_shape.deinit();
    const image_c = xcursor.XcursorImageCreate(2, 2) orelse return error.OutOfMemory;
    const image: *xcursor.XcursorImage = @ptrCast(image_c);
    image.xhot = 1;
    image.yhot = 1;
    const pixels: [*]u32 = @ptrCast(image.pixels);
    @memset(pixels[0..4], 0xffffffff);
    cursor_shape.images[shapeIndex(.default)] = image;
    cursor_shape.source_cache_ids[shapeIndex(.default)] = render.allocateSourceCacheId();

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
        if (std.mem.eql(u8, event.global.interface, generated.wp_cursor_shape_manager_v1.name)) {
            manager_name = event.global.name;
            try std.testing.expectEqual(advertised_version, event.global.version);
        }
    }
    try std.testing.expect(compositor_name != 0 and seat_name != 0 and manager_name != 0);

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
    const manager: wayring.ObjectHandle = .{
        .id = 5,
        .generation = try core.bind(
            &peer,
            registry.id,
            manager_name,
            generated.wp_cursor_shape_manager_v1.name,
            2,
            5,
            &generated.wp_cursor_shape_manager_v1,
        ),
    };
    const surface_handle = try generated.wl_compositor_types.requests.create_surface(
        &peer,
        compositor_resource,
    );
    const pointer = try generated.wl_seat_types.requests.get_pointer(&peer, seat_resource);
    const device = try generated.wp_cursor_shape_manager_v1_types.requests.get_pointer(
        &peer,
        manager,
        pointer,
    );
    try generated.wp_cursor_shape_manager_v1_types.requests.destroy(&peer, manager);
    try transferToServer(&peer, client);
    const surface = try CompositorGlobal.surfaceFor(client, .{
        .id = surface_handle.id,
        .generation = client.connection.object(surface_handle.id).?.generation,
    });
    pointer_cursor.setPosition(10.9, 20.9);
    const serial = try seat.pointerEnter(surface, 10 * 256, 20 * 256);
    try generated.wp_cursor_shape_device_v1_types.requests.set_shape(
        &peer,
        device,
        serial,
        @intFromEnum(Shape.default),
    );
    try transferToServer(&peer, client);
    const selected = pointer_cursor.current().?.shape;
    try std.testing.expectEqual(@as(i32, 9), selected.x);
    try std.testing.expectEqual(@as(i32, 19), selected.y);
    try std.testing.expectEqual(render.Size{ .width = 2, .height = 2 }, selected.buffer.size);
    try transferFromServer(&peer, client);
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == seat_resource.id) {
            _ = try generated.wl_seat_types.decodeEvent(&peer, seat_resource, &message);
        } else if (message.object_id == pointer.id) {
            _ = try generated.wl_pointer_types.decodeEvent(&peer, pointer, &message);
        } else if (message.object_id == 1) {
            _ = try core.decodeDisplayEvent(&message);
        } else return error.UnexpectedCursorShapeEvent;
    }

    try generated.wl_pointer_types.requests.release(&peer, pointer);
    const replacement = try generated.wl_seat_types.requests.get_pointer(&peer, seat_resource);
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    var replacement_serial: u32 = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == replacement.id) {
            switch (try generated.wl_pointer_types.decodeEvent(&peer, replacement, &message)) {
                .enter => |event| replacement_serial = event.serial,
                .frame => {},
                else => return error.UnexpectedPointerEvent,
            }
        } else if (message.object_id == 1) {
            _ = try core.decodeDisplayEvent(&message);
        } else return error.UnexpectedCursorShapeEvent;
    }
    try std.testing.expect(replacement_serial != 0);
    try generated.wl_pointer_types.requests.set_cursor(
        &peer,
        replacement,
        replacement_serial,
        null,
        0,
        0,
    );
    try generated.wp_cursor_shape_device_v1_types.requests.set_shape(
        &peer,
        device,
        serial,
        @intFromEnum(Shape.default),
    );
    try transferToServer(&peer, client);
    try std.testing.expect(pointer_cursor.current() == null);
    try generated.wp_cursor_shape_device_v1_types.requests.destroy(&peer, device);
    try transferToServer(&peer, client);
    try std.testing.expectEqual(@as(usize, 0), cursor_shape.devices.items.len);
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
