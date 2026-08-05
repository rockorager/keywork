//! Native pointer-gestures-v1 policy for the focused pointer client.

const PointerGesturesGlobal = @This();

const std = @import("std");
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const CompositorGlobal = @import("CompositorGlobal.zig");
const SeatGlobal = @import("SeatGlobal.zig");

const advertised_version: u32 = 3;

allocator: std.mem.Allocator,
server: *Server,
seat: *SeatGlobal,
global_name: u32,
gestures: std.ArrayList(*Gesture) = .empty,

const Kind = enum { swipe, pinch, hold };

const Gesture = struct {
    owner: *PointerGesturesGlobal,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    pointer: ?wayring.ObjectHandle,
    kind: Kind,
    active: bool = false,
};

pub fn init(
    self: *PointerGesturesGlobal,
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
        &generated.zwp_pointer_gestures_v1,
        advertised_version,
        .{ .context = self, .bind = bind },
    );
}

pub fn deinit(self: *PointerGesturesGlobal) void {
    std.debug.assert(self.gestures.items.len == 0);
    self.server.removeGlobal(self.global_name) catch unreachable;
    self.gestures.deinit(self.allocator);
    self.* = undefined;
}

pub fn beginSwipe(self: *PointerGesturesGlobal, time: u32, fingers: u32) !void {
    try self.begin(.swipe, time, fingers);
}

pub fn updateSwipe(self: *PointerGesturesGlobal, time: u32, dx: f64, dy: f64) !void {
    std.debug.assert(std.math.isFinite(dx));
    std.debug.assert(std.math.isFinite(dy));
    for (self.gestures.items) |gesture| {
        if (gesture.kind != .swipe or !self.matches(gesture) or !gesture.active)
            continue;
        try generated.zwp_pointer_gesture_swipe_v1_types.events.update(
            &gesture.client.connection,
            gesture.resource,
            time,
            fixed(dx),
            fixed(dy),
        );
    }
}

pub fn endSwipe(self: *PointerGesturesGlobal, time: u32, cancelled: bool) !void {
    try self.end(.swipe, time, cancelled);
}

pub fn beginPinch(self: *PointerGesturesGlobal, time: u32, fingers: u32) !void {
    try self.begin(.pinch, time, fingers);
}

pub fn updatePinch(
    self: *PointerGesturesGlobal,
    time: u32,
    dx: f64,
    dy: f64,
    scale: f64,
    rotation: f64,
) !void {
    std.debug.assert(std.math.isFinite(dx));
    std.debug.assert(std.math.isFinite(dy));
    std.debug.assert(std.math.isFinite(scale));
    std.debug.assert(std.math.isFinite(rotation));
    for (self.gestures.items) |gesture| {
        if (gesture.kind != .pinch or !self.matches(gesture) or !gesture.active)
            continue;
        try generated.zwp_pointer_gesture_pinch_v1_types.events.update(
            &gesture.client.connection,
            gesture.resource,
            time,
            fixed(dx),
            fixed(dy),
            fixed(scale),
            fixed(rotation),
        );
    }
}

pub fn endPinch(self: *PointerGesturesGlobal, time: u32, cancelled: bool) !void {
    try self.end(.pinch, time, cancelled);
}

pub fn beginHold(self: *PointerGesturesGlobal, time: u32, fingers: u32) !void {
    try self.begin(.hold, time, fingers);
}

pub fn endHold(self: *PointerGesturesGlobal, time: u32, cancelled: bool) !void {
    try self.end(.hold, time, cancelled);
}

fn begin(self: *PointerGesturesGlobal, kind: Kind, time: u32, fingers: u32) !void {
    const focus = self.seat.pointerFocus() orelse return;
    if (!focus.resource_alive) return;
    const serial = self.server.nextSerial();
    for (self.gestures.items) |gesture| {
        if (gesture.kind != kind or
            gesture.client != focus.client or
            !self.matches(gesture)) continue;
        if (gesture.active) try sendEnd(gesture, serial, time, true);
        gesture.active = true;
        switch (kind) {
            .swipe => try generated.zwp_pointer_gesture_swipe_v1_types.events.begin(
                &gesture.client.connection,
                gesture.resource,
                serial,
                time,
                focus.resource,
                fingers,
            ),
            .pinch => try generated.zwp_pointer_gesture_pinch_v1_types.events.begin(
                &gesture.client.connection,
                gesture.resource,
                serial,
                time,
                focus.resource,
                fingers,
            ),
            .hold => try generated.zwp_pointer_gesture_hold_v1_types.events.begin(
                &gesture.client.connection,
                gesture.resource,
                serial,
                time,
                focus.resource,
                fingers,
            ),
        }
    }
}

fn end(
    self: *PointerGesturesGlobal,
    kind: Kind,
    time: u32,
    cancelled: bool,
) !void {
    const serial = self.server.nextSerial();
    for (self.gestures.items) |gesture| {
        if (gesture.kind != kind or !self.matches(gesture) or !gesture.active)
            continue;
        gesture.active = false;
        try sendEnd(gesture, serial, time, cancelled);
    }
}

fn sendEnd(gesture: *Gesture, serial: u32, time: u32, cancelled: bool) !void {
    const cancelled_value: i32 = @intFromBool(cancelled);
    switch (gesture.kind) {
        .swipe => try generated.zwp_pointer_gesture_swipe_v1_types.events.end(
            &gesture.client.connection,
            gesture.resource,
            serial,
            time,
            cancelled_value,
        ),
        .pinch => try generated.zwp_pointer_gesture_pinch_v1_types.events.end(
            &gesture.client.connection,
            gesture.resource,
            serial,
            time,
            cancelled_value,
        ),
        .hold => try generated.zwp_pointer_gesture_hold_v1_types.events.end(
            &gesture.client.connection,
            gesture.resource,
            serial,
            time,
            cancelled_value,
        ),
    }
}

fn matches(self: *const PointerGesturesGlobal, gesture: *const Gesture) bool {
    const pointer = gesture.pointer orelse return false;
    return self.seat.pointerHandleIsActive(gesture.client, pointer);
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *PointerGesturesGlobal = @ptrCast(@alignCast(context));
    _ = client.createResource(id, &generated.zwp_pointer_gestures_v1, version, .{
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
    const self: *PointerGesturesGlobal = @ptrCast(@alignCast(context));
    switch (try generated.zwp_pointer_gestures_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .release => {},
        .get_swipe_gesture => |request| try self.createGesture(
            client,
            resource,
            request.id,
            request.pointer,
            .swipe,
        ),
        .get_pinch_gesture => |request| try self.createGesture(
            client,
            resource,
            request.id,
            request.pointer,
            .pinch,
        ),
        .get_hold_gesture => |request| try self.createGesture(
            client,
            resource,
            request.id,
            request.pointer,
            .hold,
        ),
    }
}

fn createGesture(
    self: *PointerGesturesGlobal,
    client: *Server.Client,
    manager: wayring.ObjectHandle,
    id: u32,
    pointer_id: u32,
    kind: Kind,
) !void {
    const gesture = self.allocator.create(Gesture) catch
        return client.postNoMemory();
    errdefer self.allocator.destroy(gesture);
    self.gestures.ensureUnusedCapacity(self.allocator, 1) catch
        return client.postNoMemory();
    const version = try client.resourceVersion(
        manager,
        &generated.zwp_pointer_gestures_v1,
    );
    const pointer = self.seat.pointerHandle(client, pointer_id);
    gesture.* = .{
        .owner = self,
        .client = client,
        .resource = undefined,
        .pointer = if (pointer != null and
            self.seat.pointerHandleIsActive(client, pointer.?)) pointer else null,
        .kind = kind,
    };
    gesture.resource = client.createResource(
        id,
        gestureInterface(kind),
        version,
        .{
            .context = gesture,
            .dispatch = dispatchGesture,
            .destroy = destroyGesture,
        },
    ) catch return client.postNoMemory();
    self.gestures.appendAssumeCapacity(gesture);
}

fn gestureInterface(kind: Kind) *const wayring.Interface {
    return switch (kind) {
        .swipe => &generated.zwp_pointer_gesture_swipe_v1,
        .pinch => &generated.zwp_pointer_gesture_pinch_v1,
        .hold => &generated.zwp_pointer_gesture_hold_v1,
    };
}

fn dispatchGesture(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const gesture: *Gesture = @ptrCast(@alignCast(context));
    switch (gesture.kind) {
        .swipe => _ = try generated.zwp_pointer_gesture_swipe_v1_types.decodeRequest(
            &client.connection,
            resource,
            message,
        ),
        .pinch => _ = try generated.zwp_pointer_gesture_pinch_v1_types.decodeRequest(
            &client.connection,
            resource,
            message,
        ),
        .hold => _ = try generated.zwp_pointer_gesture_hold_v1_types.decodeRequest(
            &client.connection,
            resource,
            message,
        ),
    }
}

fn destroyGesture(
    context: *anyopaque,
    _: *Server.Client,
    _: wayring.ObjectHandle,
) void {
    const gesture: *Gesture = @ptrCast(@alignCast(context));
    for (gesture.owner.gestures.items, 0..) |candidate, index| {
        if (candidate != gesture) continue;
        const owner = gesture.owner;
        _ = owner.gestures.orderedRemove(index);
        owner.allocator.destroy(gesture);
        return;
    }
    unreachable;
}

fn fixed(value: f64) i32 {
    const minimum = @as(f64, @floatFromInt(std.math.minInt(i32))) / 256.0;
    const maximum = @as(f64, @floatFromInt(std.math.maxInt(i32))) / 256.0;
    return @intFromFloat(std.math.clamp(value, minimum, maximum) * 256.0);
}

const BoundGlobals = struct {
    compositor: wayring.ObjectHandle,
    seat: wayring.ObjectHandle,
    gestures: wayring.ObjectHandle,
};

fn bindGlobals(peer: *wayring.Connection, client: *Server.Client) !BoundGlobals {
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
    var gestures_name: u32 = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const event = try core.decodeRegistryEvent(&message, registry.id);
        if (event != .global) continue;
        if (std.mem.eql(u8, event.global.interface, generated.wl_compositor.name))
            compositor_name = event.global.name;
        if (std.mem.eql(u8, event.global.interface, generated.wl_seat.name))
            seat_name = event.global.name;
        if (std.mem.eql(u8, event.global.interface, generated.zwp_pointer_gestures_v1.name)) {
            gestures_name = event.global.name;
            try std.testing.expectEqual(advertised_version, event.global.version);
        }
    }
    try std.testing.expect(compositor_name != 0);
    try std.testing.expect(seat_name != 0);
    try std.testing.expect(gestures_name != 0);
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
        .gestures = .{
            .id = 5,
            .generation = try core.bind(
                peer,
                registry.id,
                gestures_name,
                generated.zwp_pointer_gestures_v1.name,
                advertised_version,
                5,
                &generated.zwp_pointer_gestures_v1,
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

test "native pointer gestures route active sequences to the focused client" {
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
    var gestures: PointerGesturesGlobal = undefined;
    try gestures.init(std.testing.allocator, &server, &seat);
    defer gestures.deinit();

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
        const swipe = try generated.zwp_pointer_gestures_v1_types.requests.get_swipe_gesture(
            &focused_peer,
            focused_globals.gestures,
            focused_pointer,
        );
        const pinch = try generated.zwp_pointer_gestures_v1_types.requests.get_pinch_gesture(
            &focused_peer,
            focused_globals.gestures,
            focused_pointer,
        );
        const hold = try generated.zwp_pointer_gestures_v1_types.requests.get_hold_gesture(
            &focused_peer,
            focused_globals.gestures,
            focused_pointer,
        );
        try generated.zwp_pointer_gestures_v1_types.requests.release(
            &focused_peer,
            focused_globals.gestures,
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
        const unfocused_swipe = try generated.zwp_pointer_gestures_v1_types.requests.get_swipe_gesture(
            &unfocused_peer,
            unfocused_globals.gestures,
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

        try gestures.updateSwipe(9, 1, 1);
        try gestures.beginSwipe(10, 3);
        try gestures.updateSwipe(11, 1.5, -2.25);
        try gestures.beginSwipe(12, 4);
        try gestures.endSwipe(13, false);
        try transferFromServer(&focused_peer, focused_client);
        try transferFromServer(&unfocused_peer, unfocused_client);
        const SwipeEventKind = enum { begin, update, cancel, begin_again, end };
        var swipe_order: std.ArrayList(SwipeEventKind) = .empty;
        defer swipe_order.deinit(std.testing.allocator);
        while (focused_peer.popMessage()) |popped| {
            var message = popped;
            defer message.deinit();
            switch (try generated.zwp_pointer_gesture_swipe_v1_types.decodeEvent(
                &focused_peer,
                swipe,
                &message,
            )) {
                .begin => |event| {
                    try std.testing.expectEqual(focused_surface.id, event.surface);
                    try std.testing.expect(event.fingers == 3 or event.fingers == 4);
                    try swipe_order.append(
                        std.testing.allocator,
                        if (event.fingers == 3) .begin else .begin_again,
                    );
                },
                .update => |event| {
                    try std.testing.expectEqual(@as(u32, 11), event.time);
                    try std.testing.expectEqual(@as(i32, 384), event.dx);
                    try std.testing.expectEqual(@as(i32, -576), event.dy);
                    try swipe_order.append(std.testing.allocator, .update);
                },
                .end => |event| try swipe_order.append(
                    std.testing.allocator,
                    if (event.cancelled == 1) .cancel else .end,
                ),
            }
        }
        try std.testing.expectEqualSlices(
            SwipeEventKind,
            &.{ .begin, .update, .cancel, .begin_again, .end },
            swipe_order.items,
        );
        try std.testing.expect(unfocused_peer.popMessage() == null);

        try gestures.beginPinch(20, 2);
        try gestures.updatePinch(21, 1.25, -1.25, 2, -45);
        try gestures.endPinch(22, true);
        try gestures.beginHold(30, 1);
        try gestures.endHold(31, false);
        try transferFromServer(&focused_peer, focused_client);
        var pinch_events: usize = 0;
        var hold_events: usize = 0;
        while (focused_peer.popMessage()) |popped| {
            var message = popped;
            defer message.deinit();
            if (message.object_id == pinch.id) {
                switch (try generated.zwp_pointer_gesture_pinch_v1_types.decodeEvent(
                    &focused_peer,
                    pinch,
                    &message,
                )) {
                    .begin => |event| try std.testing.expectEqual(@as(u32, 2), event.fingers),
                    .update => |event| {
                        try std.testing.expectEqual(@as(i32, 320), event.dx);
                        try std.testing.expectEqual(@as(i32, -320), event.dy);
                        try std.testing.expectEqual(@as(i32, 512), event.scale);
                        try std.testing.expectEqual(@as(i32, -11_520), event.rotation);
                    },
                    .end => |event| try std.testing.expectEqual(@as(i32, 1), event.cancelled),
                }
                pinch_events += 1;
            } else if (message.object_id == hold.id) {
                switch (try generated.zwp_pointer_gesture_hold_v1_types.decodeEvent(
                    &focused_peer,
                    hold,
                    &message,
                )) {
                    .begin => |event| try std.testing.expectEqual(@as(u32, 1), event.fingers),
                    .end => |event| try std.testing.expectEqual(@as(i32, 0), event.cancelled),
                }
                hold_events += 1;
            } else return error.UnexpectedGestureEvent;
        }
        try std.testing.expectEqual(@as(usize, 3), pinch_events);
        try std.testing.expectEqual(@as(usize, 2), hold_events);

        try generated.wl_pointer_types.requests.release(&focused_peer, focused_pointer);
        try transferToServer(&focused_peer, focused_client);
        try gestures.beginSwipe(40, 3);
        try gestures.beginPinch(40, 3);
        try gestures.beginHold(40, 3);
        try transferFromServer(&focused_peer, focused_client);
        while (focused_peer.popMessage()) |popped| {
            var message = popped;
            defer message.deinit();
            if (message.object_id == swipe.id or
                message.object_id == pinch.id or
                message.object_id == hold.id)
                return error.DestroyedPointerReceivedGesture;
        }

        try generated.zwp_pointer_gesture_swipe_v1_types.requests.destroy(
            &focused_peer,
            swipe,
        );
        try generated.zwp_pointer_gesture_pinch_v1_types.requests.destroy(
            &focused_peer,
            pinch,
        );
        try generated.zwp_pointer_gesture_hold_v1_types.requests.destroy(
            &focused_peer,
            hold,
        );
        try generated.zwp_pointer_gesture_swipe_v1_types.requests.destroy(
            &unfocused_peer,
            unfocused_swipe,
        );
        try generated.zwp_pointer_gestures_v1_types.requests.release(
            &unfocused_peer,
            unfocused_globals.gestures,
        );
        try transferToServer(&focused_peer, focused_client);
        try transferToServer(&unfocused_peer, unfocused_client);
        try std.testing.expectEqual(@as(usize, 0), gestures.gestures.items.len);
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
