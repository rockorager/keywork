//! Native focus-scoped keyboard-shortcuts-inhibit-v1 policy.

const KeyboardShortcutsInhibitGlobal = @This();

const std = @import("std");
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const CompositorGlobal = @import("CompositorGlobal.zig");
const SeatGlobal = @import("SeatGlobal.zig");

const advertised_version: u32 = 1;

allocator: std.mem.Allocator,
server: *Server,
compositor: *CompositorGlobal,
seat: *SeatGlobal,
global_name: u32,
inhibitors: std.ArrayList(*Inhibitor) = .empty,

const Inhibitor = struct {
    owner: *KeyboardShortcutsInhibitGlobal,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    surface: *CompositorGlobal.Surface,
    active: bool = false,

    fn syncFocus(
        self: *Inhibitor,
        focus: ?*CompositorGlobal.Surface,
    ) !void {
        const active = self.surface.resource_alive and focus == self.surface;
        if (active == self.active) return;
        self.active = active;
        if (active) try generated.zwp_keyboard_shortcuts_inhibitor_v1_types.events.active(
            &self.client.connection,
            self.resource,
        );
        // Focus loss, unmapping, and surface destruction make an inhibitor
        // irrelevant and intentionally do not produce an inactive event.
    }
};

pub fn init(
    self: *KeyboardShortcutsInhibitGlobal,
    allocator: std.mem.Allocator,
    server: *Server,
    compositor: *CompositorGlobal,
    seat: *SeatGlobal,
) !void {
    self.* = .{
        .allocator = allocator,
        .server = server,
        .compositor = compositor,
        .seat = seat,
        .global_name = undefined,
    };
    self.global_name = try server.createGlobal(
        &generated.zwp_keyboard_shortcuts_inhibit_manager_v1,
        advertised_version,
        .{ .context = self, .bind = bind },
    );
}

pub fn deinit(self: *KeyboardShortcutsInhibitGlobal) void {
    std.debug.assert(self.inhibitors.items.len == 0);
    self.server.removeGlobal(self.global_name) catch unreachable;
    self.inhibitors.deinit(self.allocator);
    self.* = undefined;
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *KeyboardShortcutsInhibitGlobal = @ptrCast(@alignCast(context));
    _ = client.createResource(
        id,
        &generated.zwp_keyboard_shortcuts_inhibit_manager_v1,
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
    const self: *KeyboardShortcutsInhibitGlobal = @ptrCast(@alignCast(context));
    switch (try generated.zwp_keyboard_shortcuts_inhibit_manager_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .inhibit_shortcuts => |request| try self.createInhibitor(
            client,
            resource,
            request.id,
            request.surface,
            request.seat,
        ),
    }
}

fn createInhibitor(
    self: *KeyboardShortcutsInhibitGlobal,
    client: *Server.Client,
    manager_resource: wayring.ObjectHandle,
    id: u32,
    surface_id: u32,
    seat_id: u32,
) !void {
    const object = client.connection.object(surface_id) orelse
        return error.UnknownSurface;
    const surface = try CompositorGlobal.surfaceFor(client, .{
        .id = surface_id,
        .generation = object.generation,
    });
    if (surface.owner != self.compositor) return error.WrongSurface;
    if (!self.seat.ownsResource(client, seat_id)) return error.WrongSeat;
    for (self.inhibitors.items) |inhibitor| {
        if (inhibitor.surface != surface) continue;
        return client.postError(
            manager_resource,
            @intFromEnum(
                generated.zwp_keyboard_shortcuts_inhibit_manager_v1_types
                    .@"error".already_inhibited,
            ),
            "keyboard shortcuts are already inhibited for this surface and seat",
        );
    }

    const inhibitor = self.allocator.create(Inhibitor) catch
        return client.postNoMemory();
    var registered = false;
    errdefer if (!registered) self.allocator.destroy(inhibitor);
    self.inhibitors.ensureUnusedCapacity(self.allocator, 1) catch
        return client.postNoMemory();
    surface.reference() catch return client.postNoMemory();
    var surface_referenced = true;
    errdefer if (surface_referenced) surface.unreference();
    inhibitor.* = .{
        .owner = self,
        .client = client,
        .resource = undefined,
        .surface = surface,
    };
    self.seat.addKeyboardFocusListener(.{
        .context = inhibitor,
        .changed = keyboardFocusChanged,
    }) catch return client.postNoMemory();
    var listener_registered = true;
    errdefer if (listener_registered)
        self.seat.removeKeyboardFocusListener(inhibitor);
    const version = try client.resourceVersion(
        manager_resource,
        &generated.zwp_keyboard_shortcuts_inhibit_manager_v1,
    );
    inhibitor.resource = client.createResource(
        id,
        &generated.zwp_keyboard_shortcuts_inhibitor_v1,
        version,
        .{
            .context = inhibitor,
            .dispatch = dispatchInhibitor,
            .destroy = destroyInhibitor,
        },
    ) catch return client.postNoMemory();
    self.inhibitors.appendAssumeCapacity(inhibitor);
    registered = true;
    surface_referenced = false;
    listener_registered = false;
    try inhibitor.syncFocus(self.seat.keyboardFocus());
}

fn dispatchInhibitor(
    _: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    _ = try generated.zwp_keyboard_shortcuts_inhibitor_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    );
}

fn destroyInhibitor(
    context: *anyopaque,
    _: *Server.Client,
    _: wayring.ObjectHandle,
) void {
    const inhibitor: *Inhibitor = @ptrCast(@alignCast(context));
    const owner = inhibitor.owner;
    owner.seat.removeKeyboardFocusListener(inhibitor);
    inhibitor.surface.unreference();
    for (owner.inhibitors.items, 0..) |candidate, index| {
        if (candidate != inhibitor) continue;
        _ = owner.inhibitors.orderedRemove(index);
        owner.allocator.destroy(inhibitor);
        return;
    }
    unreachable;
}

fn keyboardFocusChanged(
    context: *anyopaque,
    focus: ?*CompositorGlobal.Surface,
) !void {
    const inhibitor: *Inhibitor = @ptrCast(@alignCast(context));
    try inhibitor.syncFocus(focus);
}

test "keyboard shortcuts inhibition follows focus and survives manager destruction" {
    const core = @import("wayring-core");

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
        SeatGlobal.Capability.keyboard,
        null,
    );
    defer seat.deinit();
    var shortcuts: KeyboardShortcutsInhibitGlobal = undefined;
    try shortcuts.init(std.testing.allocator, &server, &compositor, &seat);
    defer shortcuts.deinit();
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
    var shortcuts_name: u32 = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const global = (try core.decodeRegistryEvent(&message, registry.id)).global;
        if (std.mem.eql(u8, global.interface, generated.wl_compositor.name))
            compositor_name = global.name;
        if (std.mem.eql(u8, global.interface, generated.wl_seat.name))
            seat_name = global.name;
        if (std.mem.eql(
            u8,
            global.interface,
            generated.zwp_keyboard_shortcuts_inhibit_manager_v1.name,
        )) {
            try std.testing.expectEqual(advertised_version, global.version);
            shortcuts_name = global.name;
        }
    }
    try std.testing.expect(compositor_name != 0);
    try std.testing.expect(seat_name != 0);
    try std.testing.expect(shortcuts_name != 0);

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
            shortcuts_name,
            generated.zwp_keyboard_shortcuts_inhibit_manager_v1.name,
            advertised_version,
            5,
            &generated.zwp_keyboard_shortcuts_inhibit_manager_v1,
        ),
    };
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    while (peer.popMessage()) |popped| {
        var message = popped;
        message.deinit();
    }

    const first_surface_handle = try generated.wl_compositor_types.requests.create_surface(
        &peer,
        compositor_resource,
    );
    const second_surface_handle = try generated.wl_compositor_types.requests.create_surface(
        &peer,
        compositor_resource,
    );
    const first_inhibitor = try generated.zwp_keyboard_shortcuts_inhibit_manager_v1_types.requests.inhibit_shortcuts(
        &peer,
        manager,
        first_surface_handle,
        seat_resource,
    );
    const second_inhibitor = try generated.zwp_keyboard_shortcuts_inhibit_manager_v1_types.requests.inhibit_shortcuts(
        &peer,
        manager,
        second_surface_handle,
        seat_resource,
    );
    try generated.zwp_keyboard_shortcuts_inhibit_manager_v1_types.requests.destroy(
        &peer,
        manager,
    );
    try transferToServer(&peer, client);
    try std.testing.expectEqual(Server.ClientState.active, client.state);
    const first_surface = try CompositorGlobal.surfaceFor(client, .{
        .id = first_surface_handle.id,
        .generation = client.connection.object(first_surface_handle.id).?.generation,
    });
    const second_surface = try CompositorGlobal.surfaceFor(client, .{
        .id = second_surface_handle.id,
        .generation = client.connection.object(second_surface_handle.id).?.generation,
    });

    _ = try seat.keyboardEnter(first_surface, &.{});
    try transferFromServer(&peer, client);
    var first_active: usize = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == first_inhibitor.id) {
            switch (try generated.zwp_keyboard_shortcuts_inhibitor_v1_types.decodeEvent(
                &peer,
                first_inhibitor,
                &message,
            )) {
                .active => first_active += 1,
                .inactive => return error.UnexpectedInactive,
            }
        } else if (message.object_id == 1) {
            _ = try core.decodeDisplayEvent(&message);
        } else return error.UnexpectedShortcutEvent;
    }
    try std.testing.expectEqual(@as(usize, 1), first_active);

    _ = try seat.keyboardLeave();
    _ = try seat.keyboardEnter(second_surface, &.{});
    try transferFromServer(&peer, client);
    var second_active: usize = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == second_inhibitor.id) {
            switch (try generated.zwp_keyboard_shortcuts_inhibitor_v1_types.decodeEvent(
                &peer,
                second_inhibitor,
                &message,
            )) {
                .active => second_active += 1,
                .inactive => return error.UnexpectedInactive,
            }
        } else return error.UnexpectedShortcutEvent;
    }
    try std.testing.expectEqual(@as(usize, 1), second_active);

    try generated.wl_surface_types.requests.destroy(&peer, second_surface_handle);
    try transferToServer(&peer, client);
    _ = try seat.keyboardLeave();
    _ = try seat.keyboardEnter(first_surface, &.{});
    try transferFromServer(&peer, client);
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == first_inhibitor.id) {
            switch (try generated.zwp_keyboard_shortcuts_inhibitor_v1_types.decodeEvent(
                &peer,
                first_inhibitor,
                &message,
            )) {
                .active => first_active += 1,
                .inactive => return error.UnexpectedInactive,
            }
        } else if (message.object_id == 1) {
            _ = try core.decodeDisplayEvent(&message);
        } else return error.UnexpectedShortcutEvent;
    }
    try std.testing.expectEqual(@as(usize, 2), first_active);

    const replacement_manager: wayring.ObjectHandle = .{
        .id = 20,
        .generation = try core.bind(
            &peer,
            registry.id,
            shortcuts_name,
            generated.zwp_keyboard_shortcuts_inhibit_manager_v1.name,
            advertised_version,
            20,
            &generated.zwp_keyboard_shortcuts_inhibit_manager_v1,
        ),
    };
    try transferToServer(&peer, client);
    _ = try generated.zwp_keyboard_shortcuts_inhibit_manager_v1_types.requests.inhibit_shortcuts(
        &peer,
        replacement_manager,
        first_surface_handle,
        seat_resource,
    );
    try std.testing.expectError(
        error.ProtocolError,
        transferToServer(&peer, client),
    );
    try std.testing.expectEqual(Server.ClientState.protocol_error, client.state);
    try std.testing.expectEqual(@as(usize, 2), shortcuts.inhibitors.items.len);
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
