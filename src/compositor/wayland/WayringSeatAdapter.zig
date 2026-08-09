//! Generated wl_seat/wl_keyboard/wl_pointer/wl_touch adapter.
//!
//! Production publication is explicit so assembly can place the global after
//! the core globals and before optional outputs. Canonical seat policy calls
//! the resource-free sink; this type owns only its global, protocol resources,
//! and per-resource generations.

const WayringSeatAdapter = @This();

const std = @import("std");
const core = @import("wayring-protocol");
const ClientRegistry = @import("../ClientRegistry.zig");
const SeatDelivery = @import("../SeatDelivery.zig");
const SurfaceRegistry = @import("../SurfaceRegistry.zig");
const WayringClients = @import("WayringClients.zig");
const WayringCompositor = @import("WayringCompositor.zig");
const wayring = @import("wayring");
const wire = wayring.wire;

protocol_server: *wayring.server.Server,
allocator: std.mem.Allocator,
clients: *WayringClients,
compositor: *WayringCompositor,
request_sink: SeatDelivery.RequestSink,
seat_name: [:0]const u8,
global: ?*const wayring.server.Server.Global = null,
snapshot: SeatDelivery.CapabilitySnapshot = .{},
seats: std.ArrayList(*SeatResource) = .empty,
keyboards: std.ArrayList(*KeyboardResource) = .empty,
pointers: std.ArrayList(*PointerResource) = .empty,
touches: std.ArrayList(*TouchResource) = .empty,
terminal_clients: std.ArrayList(TerminalClient) = .empty,
next_keyboard_resource_generation: ?SeatDelivery.ResourceGeneration = 1,
next_pointer_resource_generation: ?SeatDelivery.ResourceGeneration = 1,
next_touch_resource_generation: ?SeatDelivery.ResourceGeneration = 1,
pointer_resource_listener: ?PointerResourceListener = null,

pub const PointerResourceListener = struct {
    context: *anyopaque,
    changed: *const fn (*anyopaque) void,
};

const TerminalClient = struct {
    client: *wayring.server.Client,
    observer: *wayring.server.Client.TerminalObserver,
};

const SeatResource = struct {
    resource: core.wl_seat.Resource,
    client: *wayring.server.Client,
    adapter: *WayringSeatAdapter,
};

const KeyboardResource = struct {
    resource: core.wl_keyboard.Resource,
    client: *wayring.server.Client,
    adapter: *WayringSeatAdapter,
    generation: SeatDelivery.ResourceGeneration,
    resource_generation: SeatDelivery.ResourceGeneration,
    focused_surface: ?SurfaceRegistry.Id = null,
};

const PointerResource = struct {
    resource: core.wl_pointer.Resource,
    client: *wayring.server.Client,
    adapter: *WayringSeatAdapter,
    generation: SeatDelivery.ResourceGeneration,
    resource_generation: SeatDelivery.ResourceGeneration,
    last_enter_serial: ?u32 = null,
    frame_pending: bool = false,
};

const TouchResource = struct {
    resource: core.wl_touch.Resource,
    client: *wayring.server.Client,
    adapter: *WayringSeatAdapter,
    generation: SeatDelivery.ResourceGeneration,
    resource_generation: SeatDelivery.ResourceGeneration,
    frame_pending: bool = false,
};

/// Resource-free identity for an exact live generated wl_pointer. Consumers
/// must pass the same raw client that supplied the protocol object id; object
/// ids are client-local and are never accepted by numeric coincidence alone.
pub const PointerIdentity = struct {
    client: ClientRegistry.Id,
    resource_generation: SeatDelivery.ResourceGeneration,
    capability_generation: SeatDelivery.ResourceGeneration,
};

/// Resolves an exact live generated wl_seat to its neutral client. This is
/// deliberately narrower than exposing the generated resource: consumers can
/// validate same-client seat arguments without retaining protocol pointers.
pub fn seatClientIdentity(
    self: *const WayringSeatAdapter,
    client: *wayring.server.Client,
    object_id: u32,
) ?ClientRegistry.Id {
    if (client.fatal() != null) return null;
    const installed = client.lookup(object_id) orelse return null;
    for (self.seats.items) |seat_resource| {
        if (seat_resource.client == client and seat_resource.resource.id() == object_id and
            installed == &seat_resource.resource.runtime and seat_resource.resource.runtime.state() == .live)
            return self.clients.id(client);
    }
    return null;
}

pub fn init(
    allocator: std.mem.Allocator,
    protocol_server: *wayring.server.Server,
    clients: *WayringClients,
    compositor: *WayringCompositor,
    request_sink: SeatDelivery.RequestSink,
    seat_name: [:0]const u8,
) WayringSeatAdapter {
    return .{
        .allocator = allocator,
        .protocol_server = protocol_server,
        .clients = clients,
        .compositor = compositor,
        .request_sink = request_sink,
        .seat_name = seat_name,
    };
}

pub fn deinit(self: *WayringSeatAdapter) void {
    std.debug.assert(self.global == null);
    std.debug.assert(self.seats.items.len == 0 and self.keyboards.items.len == 0 and
        self.pointers.items.len == 0 and self.touches.items.len == 0 and
        self.terminal_clients.items.len == 0);
    self.seats.deinit(self.allocator);
    self.keyboards.deinit(self.allocator);
    self.pointers.deinit(self.allocator);
    self.touches.deinit(self.allocator);
    self.terminal_clients.deinit(self.allocator);
    self.* = undefined;
}

/// Publishes exactly one generated seat at the scanner interface version.
/// The canonical sink must already be installed so a client can never bind an
/// adapter with a stale default capability snapshot.
pub fn publish(self: *WayringSeatAdapter) !void {
    std.debug.assert(self.global == null);
    self.global = try self.protocol_server.addGlobal(
        core.wl_seat,
        core.wl_seat.interface.version,
        WayringSeatAdapter,
        self,
        bindGlobal,
    );
}

/// Removes publication before adapter teardown. Existing client resources
/// must already have been retired by the host lifecycle.
pub fn unpublish(self: *WayringSeatAdapter) void {
    const global = self.global orelse unreachable;
    self.protocol_server.removeGlobal(global) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}

fn bindGlobal(
    client: *wayring.server.Client,
    id: u32,
    version: u32,
    self: *WayringSeatAdapter,
) !void {
    try self.bind(client, id, version);
}

/// Registers the canonical pre-fatal retirement hook for one accepted raw
/// generated client. Lifecycle code must call this immediately after mapping.
pub fn trackClient(self: *WayringSeatAdapter, client: *wayring.server.Client) !void {
    for (self.terminal_clients.items) |entry| if (entry.client == client) return error.AlreadyTracked;
    try self.terminal_clients.ensureUnusedCapacity(self.allocator, 1);
    const observer = try client.addTerminalObserver(WayringSeatAdapter, self, clientTerminal);
    self.terminal_clients.appendAssumeCapacity(.{ .client = client, .observer = observer });
}

fn clientTerminal(self: *WayringSeatAdapter, client: *wayring.server.Client, _: *wayring.server.Client.TerminalObserver) void {
    self.retireClient(client);
}

fn untrackClient(self: *WayringSeatAdapter, client: *wayring.server.Client) void {
    for (self.terminal_clients.items, 0..) |entry, index| if (entry.client == client) {
        wayring.server.Client.removeTerminalObserver(entry.observer);
        _ = self.terminal_clients.swapRemove(index);
        return;
    };
}

pub fn installCursorListener(self: *WayringSeatAdapter) void {
    self.compositor.setCursorListener(.{ .context = self, .committed = cursorCommitted, .removed = cursorRemoved });
}

pub fn clearCursorListener(self: *WayringSeatAdapter) void {
    self.compositor.clearCursorListener(self);
}

pub fn setPointerResourceListener(self: *WayringSeatAdapter, listener: PointerResourceListener) void {
    std.debug.assert(self.pointer_resource_listener == null);
    self.pointer_resource_listener = listener;
}

pub fn clearPointerResourceListener(self: *WayringSeatAdapter, context: *anyopaque) void {
    std.debug.assert(self.pointer_resource_listener != null and
        self.pointer_resource_listener.?.context == context);
    self.pointer_resource_listener = null;
}

/// Direct typed bind seam shared by production publication and fault fixtures.
pub fn bind(self: *WayringSeatAdapter, client: *wayring.server.Client, id: u32, version: u32) !void {
    if (version == 0 or version > core.wl_seat.interface.version) return error.InvalidVersion;
    errdefer self.retireClient(client);
    try self.seats.ensureUnusedCapacity(self.allocator, 1);
    const seat = try self.allocator.create(SeatResource);
    errdefer self.allocator.destroy(seat);
    seat.* = .{ .resource = .init(self.allocator, id, version, .client, client.ownerHooks()), .client = client, .adapter = self };
    errdefer {
        seat.resource.destroy();
        seat.resource.deinit();
    }
    try seat.resource.setHandler(SeatResource, seat, seatRequest, null);
    try client.materialize(&seat.resource.runtime);
    self.seats.appendAssumeCapacity(seat);
    if (version >= 2) core.wl_seat.@"send:name"(&seat.resource, self.seat_name) catch |err| self.eventFailure(client, &seat.resource.runtime, err);
    sendCapabilities(seat) catch |err| self.eventFailure(client, &seat.resource.runtime, err);
}

pub fn destroyClientResources(self: *WayringSeatAdapter, client: *wayring.server.Client) void {
    self.retireClient(client);
    self.untrackClient(client);
    var i = self.keyboards.items.len;
    while (i > 0) {
        i -= 1;
        if (self.keyboards.items[i].client == client) destroyKeyboard(self.keyboards.items[i]);
    }
    i = self.pointers.items.len;
    while (i > 0) {
        i -= 1;
        if (self.pointers.items[i].client == client) destroyPointer(self.pointers.items[i]);
    }
    i = self.touches.items.len;
    while (i > 0) {
        i -= 1;
        if (self.touches.items[i].client == client) destroyTouch(self.touches.items[i]);
    }
    i = self.seats.items.len;
    while (i > 0) {
        i -= 1;
        if (self.seats.items[i].client == client) destroySeat(self.seats.items[i]);
    }
}

/// Resolves an exact materialized wl_pointer without exposing its generated
/// resource. The returned generations are the canonical request credentials.
pub fn pointerIdentity(
    self: *const WayringSeatAdapter,
    client: *wayring.server.Client,
    object_id: u32,
) ?PointerIdentity {
    const identity = self.pointerIdentityIncludingInactive(client, object_id) orelse return null;
    if (!self.snapshot.pointer.resourceActive(identity.capability_generation)) return null;
    return identity;
}

/// Resolves exact live identity even while this pointer's capability
/// generation is inactive. Extension objects may outlive capability loss, but
/// must use pointerIdentity before delivering events so stale resources never
/// revive under a later generation.
pub fn pointerIdentityIncludingInactive(
    self: *const WayringSeatAdapter,
    client: *wayring.server.Client,
    object_id: u32,
) ?PointerIdentity {
    if (client.fatal() != null) return null;
    const installed = client.lookup(object_id) orelse return null;
    for (self.pointers.items) |pointer_resource| {
        if (pointer_resource.client != client or pointer_resource.resource.id() != object_id or
            installed != &pointer_resource.resource.runtime or pointer_resource.resource.runtime.state() != .live) continue;
        return .{
            .client = self.clients.id(client) orelse return null,
            .resource_generation = pointer_resource.resource_generation,
            .capability_generation = pointer_resource.generation,
        };
    }
    return null;
}

/// Re-resolves a cursor device's target and proves that this exact pointer
/// resource received the supplied enter serial.
pub fn acceptsCursorShape(
    self: *const WayringSeatAdapter,
    client: *wayring.server.Client,
    object_id: u32,
    expected: PointerIdentity,
    serial: u32,
) bool {
    const current = self.pointerIdentity(client, object_id) orelse return false;
    if (!std.meta.eql(current, expected)) return false;
    return self.acceptsPointerEnterSerial(client, object_id, serial);
}

/// Proves that an exact live generated pointer received the supplied current
/// enter serial. The serial remains valid for any focused surface of its client.
pub fn acceptsPointerEnterSerial(
    self: *const WayringSeatAdapter,
    client: *wayring.server.Client,
    object_id: u32,
    serial: u32,
) bool {
    _ = self.pointerIdentity(client, object_id) orelse return false;
    for (self.pointers.items) |pointer_resource| {
        if (pointer_resource.client == client and pointer_resource.resource.id() == object_id)
            return pointer_resource.last_enter_serial != null and pointer_resource.last_enter_serial.? == serial;
    }
    return false;
}

/// Validates an XDG direct-manipulation request against this adapter's exact
/// live wl_seat resource and the canonical live pointer-press authority.
pub fn acceptsXdgPointerGrab(
    self: *WayringSeatAdapter,
    client: *wayring.server.Client,
    seat_object_id: u32,
    serial: u32,
    surface: SurfaceRegistry.Id,
) ?ClientRegistry.Id {
    if (client.fatal() != null) return null;
    const installed = client.lookup(seat_object_id) orelse return null;
    var owns_seat = false;
    for (self.seats.items) |seat| {
        if (seat.client == client and seat.resource.id() == seat_object_id and
            installed == &seat.resource.runtime and seat.resource.runtime.state() == .live)
        {
            owns_seat = true;
            break;
        }
    }
    if (!owns_seat) return null;
    const client_id = self.clients.id(client) orelse return null;
    const typed_serial: ClientRegistry.Serial = .{
        .domain = .wayring_server,
        .value = serial,
    };
    if (!self.request_sink.accepts_pointer_grab(
        self.request_sink.context,
        client_id,
        typed_serial,
        surface,
    )) return null;
    return client_id;
}

/// Validates an XDG user action against the exact live generated wl_seat and
/// the canonical serial authority, without imposing pointer-grab purpose.
pub fn acceptsXdgUserAction(
    self: *WayringSeatAdapter,
    client: *wayring.server.Client,
    seat_object_id: u32,
    serial: u32,
) ?ClientRegistry.Id {
    if (client.fatal() != null) return null;
    const installed = client.lookup(seat_object_id) orelse return null;
    for (self.seats.items) |seat| {
        if (seat.client != client or seat.resource.id() != seat_object_id or
            installed != &seat.resource.runtime or seat.resource.runtime.state() != .live) continue;
        const client_id = self.clients.id(client) orelse return null;
        const typed_serial: ClientRegistry.Serial = .{ .domain = .wayring_server, .value = serial };
        if (!self.request_sink.accepts_action(self.request_sink.context, client_id, typed_serial)) return null;
        return client_id;
    }
    return null;
}

/// Validates an activation serial against an exact live generated wl_seat and
/// the canonical Seat activation domain (input actions and focus events).
pub fn acceptsXdgActivation(
    self: *WayringSeatAdapter,
    client: *wayring.server.Client,
    seat_object_id: u32,
    serial: u32,
) ?ClientRegistry.Id {
    if (client.fatal() != null) return null;
    const installed = client.lookup(seat_object_id) orelse return null;
    for (self.seats.items) |seat| {
        if (seat.client != client or seat.resource.id() != seat_object_id or
            installed != &seat.resource.runtime or seat.resource.runtime.state() != .live) continue;
        const client_id = self.clients.id(client) orelse return null;
        const typed_serial: ClientRegistry.Serial = .{ .domain = .wayring_server, .value = serial };
        if (!self.request_sink.accepts_activation(self.request_sink.context, client_id, typed_serial)) return null;
        return client_id;
    }
    return null;
}

pub fn activationSurfaceFocused(self: *const WayringSeatAdapter, surface: SurfaceRegistry.Id) bool {
    return self.request_sink.activation_surface_focused(self.request_sink.context, surface);
}

fn seatRequest(_: *core.wl_seat.Resource, request: core.wl_seat.Request, seat: *SeatResource) !void {
    switch (request) {
        .get_pointer => |args| {
            if (!seat.adapter.snapshot.pointer.ever_available) {
                missingCapability(seat, "seat has never had a pointer capability");
                return;
            }
            createPointer(seat, args.id) catch |err| {
                seat.adapter.retireClient(seat.client);
                if (err == error.OutOfMemory)
                    seat.client.postOutOfMemory(&seat.resource.runtime, "creating generated pointer")
                else
                    seat.client.postImplementationError(&seat.resource.runtime, "creating generated pointer");
            };
        },
        .get_keyboard => |args| {
            if (!seat.adapter.snapshot.keyboard.ever_available) {
                missingCapability(seat, "seat has never had a keyboard capability");
                return;
            }
            createKeyboard(seat, args.id) catch |err| {
                seat.adapter.retireClient(seat.client);
                if (err == error.OutOfMemory)
                    seat.client.postOutOfMemory(&seat.resource.runtime, "creating generated keyboard")
                else
                    seat.client.postImplementationError(&seat.resource.runtime, "creating generated keyboard");
            };
        },
        .release => destroySeat(seat),
        .get_touch => |args| {
            if (!seat.adapter.snapshot.touch.ever_available) {
                missingCapability(seat, "seat has never had a touch capability");
                return;
            }
            createTouch(seat, args.id) catch |err| {
                seat.adapter.retireClient(seat.client);
                if (err == error.OutOfMemory)
                    seat.client.postOutOfMemory(&seat.resource.runtime, "creating generated touch")
                else
                    seat.client.postImplementationError(&seat.resource.runtime, "creating generated touch");
            };
        },
    }
}

fn missingCapability(seat: *SeatResource, detail: []const u8) void {
    seat.adapter.retireClient(seat.client);
    seat.client.postProtocolError(
        &seat.resource.runtime,
        @intCast(core.wl_seat.@"error".missing_capability),
        detail,
    );
}

fn createKeyboard(seat: *SeatResource, id: u32) !void {
    const self = seat.adapter;
    const resource_generation = self.next_keyboard_resource_generation orelse {
        self.retireClient(seat.client);
        seat.client.postImplementationError(&seat.resource.runtime, "generated keyboard resource generation exhausted");
        return;
    };
    self.next_keyboard_resource_generation = std.math.add(
        SeatDelivery.ResourceGeneration,
        resource_generation,
        1,
    ) catch null;
    try self.keyboards.ensureUnusedCapacity(self.allocator, 1);
    const keyboard_resource = try self.allocator.create(KeyboardResource);
    errdefer self.allocator.destroy(keyboard_resource);
    keyboard_resource.* = .{
        .resource = .init(self.allocator, id, seat.resource.version(), .client, seat.client.ownerHooks()),
        .client = seat.client,
        .adapter = self,
        .generation = self.snapshot.keyboard.generation,
        .resource_generation = resource_generation,
    };
    errdefer {
        keyboard_resource.resource.destroy();
        keyboard_resource.resource.deinit();
    }
    try keyboard_resource.resource.setHandler(KeyboardResource, keyboard_resource, keyboardRequest, null);
    try seat.client.materialize(&keyboard_resource.resource.runtime);
    self.keyboards.appendAssumeCapacity(keyboard_resource);
    if (!self.snapshot.keyboard.resourceActive(keyboard_resource.generation)) return;
    const client_id = self.clients.id(seat.client) orelse {
        self.retireClient(seat.client);
        seat.client.postImplementationError(&keyboard_resource.resource.runtime, "generated keyboard client mapping is unavailable");
        return;
    };
    const snapshot = self.request_sink.keyboard_resource_snapshot(
        self.request_sink.context,
        client_id,
        keyboard_resource.generation,
    ) orelse {
        self.retireClient(seat.client);
        seat.client.postImplementationError(&keyboard_resource.resource.runtime, "generated keyboard canonical snapshot is unavailable");
        return;
    };
    sendKeyboardInitial(keyboard_resource, snapshot) catch |err|
        self.eventFailure(seat.client, &keyboard_resource.resource.runtime, err);
}

fn keyboardRequest(_: *core.wl_keyboard.Resource, request: core.wl_keyboard.Request, keyboard_resource: *KeyboardResource) !void {
    switch (request) {
        .release => destroyKeyboard(keyboard_resource),
    }
}

fn createPointer(seat: *SeatResource, id: u32) !void {
    const self = seat.adapter;
    const resource_generation = self.next_pointer_resource_generation orelse {
        self.retireClient(seat.client);
        seat.client.postImplementationError(&seat.resource.runtime, "generated pointer resource generation exhausted");
        return;
    };
    self.next_pointer_resource_generation = std.math.add(
        SeatDelivery.ResourceGeneration,
        resource_generation,
        1,
    ) catch null;
    try self.pointers.ensureUnusedCapacity(self.allocator, 1);
    const pointer_resource = try self.allocator.create(PointerResource);
    errdefer self.allocator.destroy(pointer_resource);
    pointer_resource.* = .{
        .resource = .init(self.allocator, id, seat.resource.version(), .client, seat.client.ownerHooks()),
        .client = seat.client,
        .adapter = self,
        .generation = self.snapshot.pointer.generation,
        .resource_generation = resource_generation,
    };
    errdefer {
        pointer_resource.resource.destroy();
        pointer_resource.resource.deinit();
    }
    try pointer_resource.resource.setHandler(PointerResource, pointer_resource, pointerRequest, null);
    try seat.client.materialize(&pointer_resource.resource.runtime);
    self.pointers.appendAssumeCapacity(pointer_resource);
    const client_id = self.clients.id(seat.client) orelse return;
    const snapshot = self.request_sink.pointer_enter_snapshot(
        self.request_sink.context,
        client_id,
        pointer_resource.generation,
    ) orelse return;
    const endpoint = self.compositor.surfaceEndpoint(snapshot.surface) orelse return;
    if (endpoint.client != seat.client) return;
    sendEnter(pointer_resource, endpoint.resource.id(), .{
        .serial = snapshot.serial,
        .x = snapshot.x,
        .y = snapshot.y,
    }) catch |err| {
        self.eventFailure(seat.client, &pointer_resource.resource.runtime, err);
        return;
    };
    if (pointer_resource.resource.version() >= 5)
        core.wl_pointer.@"send:frame"(&pointer_resource.resource) catch |err|
            self.eventFailure(seat.client, &pointer_resource.resource.runtime, err);
}

fn pointerRequest(_: *core.wl_pointer.Resource, request: core.wl_pointer.Request, pointer_resource: *PointerResource) !void {
    switch (request) {
        .release => destroyPointer(pointer_resource),
        .set_cursor => |set| {
            const self = pointer_resource.adapter;
            if (!self.snapshot.pointer.resourceActive(pointer_resource.generation) or
                pointer_resource.last_enter_serial == null or pointer_resource.last_enter_serial.? != set.serial) return;
            const client_id = self.clients.id(pointer_resource.client) orelse return;
            const surface = if (set.surface) |surface_id|
                self.compositor.surfaceId(pointer_resource.client, surface_id) orelse return
            else
                null;
            const result = self.request_sink.set_cursor(self.request_sink.context, .{
                .client = client_id,
                .resource_generation = pointer_resource.resource_generation,
                .capability_generation = pointer_resource.generation,
                .serial = .{ .domain = .wayring_server, .value = set.serial },
                .surface = surface,
                .hotspot_x = set.hotspot_x,
                .hotspot_y = set.hotspot_y,
            });
            if (result == .role_conflict) {
                self.retireClient(pointer_resource.client);
                pointer_resource.client.postProtocolError(&pointer_resource.resource.runtime, @intCast(core.wl_pointer.@"error".role), "wl_surface already has another role");
            }
        },
    }
}

fn createTouch(seat: *SeatResource, id: u32) !void {
    const self = seat.adapter;
    const resource_generation = self.next_touch_resource_generation orelse {
        self.retireClient(seat.client);
        seat.client.postImplementationError(&seat.resource.runtime, "generated touch resource generation exhausted");
        return;
    };
    self.next_touch_resource_generation = std.math.add(
        SeatDelivery.ResourceGeneration,
        resource_generation,
        1,
    ) catch null;
    try self.touches.ensureUnusedCapacity(self.allocator, 1);
    const touch_resource = try self.allocator.create(TouchResource);
    errdefer self.allocator.destroy(touch_resource);
    touch_resource.* = .{
        .resource = .init(self.allocator, id, seat.resource.version(), .client, seat.client.ownerHooks()),
        .client = seat.client,
        .adapter = self,
        .generation = self.snapshot.touch.generation,
        .resource_generation = resource_generation,
    };
    errdefer {
        touch_resource.resource.destroy();
        touch_resource.resource.deinit();
    }
    try touch_resource.resource.setHandler(TouchResource, touch_resource, touchRequest, null);
    try seat.client.materialize(&touch_resource.resource.runtime);
    self.touches.appendAssumeCapacity(touch_resource);
}

fn touchRequest(_: *core.wl_touch.Resource, request: core.wl_touch.Request, touch_resource: *TouchResource) !void {
    switch (request) {
        .release => destroyTouch(touch_resource),
    }
}

fn destroySeat(seat: *SeatResource) void {
    const self = seat.adapter;
    for (self.seats.items, 0..) |item, i| if (item == seat) {
        _ = self.seats.orderedRemove(i);
        seat.resource.destroy();
        seat.resource.deinit();
        self.allocator.destroy(seat);
        return;
    };
}
fn destroyKeyboard(keyboard_resource: *KeyboardResource) void {
    const self = keyboard_resource.adapter;
    for (self.keyboards.items, 0..) |item, i| if (item == keyboard_resource) {
        _ = self.keyboards.orderedRemove(i);
        keyboard_resource.resource.destroy();
        keyboard_resource.resource.deinit();
        self.allocator.destroy(keyboard_resource);
        return;
    };
}
fn destroyPointer(pointer_resource: *PointerResource) void {
    const self = pointer_resource.adapter;
    for (self.pointers.items, 0..) |item, i| if (item == pointer_resource) {
        _ = self.pointers.orderedRemove(i);
        pointer_resource.resource.destroy();
        pointer_resource.resource.deinit();
        self.allocator.destroy(pointer_resource);
        if (self.pointer_resource_listener) |listener| listener.changed(listener.context);
        return;
    };
}
fn destroyTouch(touch_resource: *TouchResource) void {
    const self = touch_resource.adapter;
    for (self.touches.items, 0..) |item, i| if (item == touch_resource) {
        _ = self.touches.orderedRemove(i);
        touch_resource.resource.destroy();
        touch_resource.resource.deinit();
        self.allocator.destroy(touch_resource);
        return;
    };
}

fn capabilityBits(snapshot: SeatDelivery.CapabilitySnapshot) u32 {
    var bits: u32 = 0;
    if (snapshot.pointer.available) bits |= @intCast(core.wl_seat.capability.pointer);
    if (snapshot.keyboard.available) bits |= @intCast(core.wl_seat.capability.keyboard);
    if (snapshot.touch.available) bits |= @intCast(core.wl_seat.capability.touch);
    return bits;
}
fn sendCapabilities(seat: *SeatResource) !void {
    try core.wl_seat.@"send:capabilities"(&seat.resource, capabilityBits(seat.adapter.snapshot));
}
fn eventFailure(self: *WayringSeatAdapter, client: *wayring.server.Client, resource: *wayring.server.Resource, err: anyerror) void {
    self.retireClient(client);
    if (client.fatal() != null) return;
    switch (err) {
        error.OutOfMemory, error.WriteFailed => client.postOutOfMemory(resource, "queueing generated seat event"),
        error.OutputSealed, error.ClientFatal => {},
        else => client.postImplementationError(resource, "queueing generated seat event"),
    }
}

pub fn sink(self: *WayringSeatAdapter) SeatDelivery.Sink {
    return .{
        .context = self,
        .owner_for_surface = ownerForSurface,
        .surface_accepts_input = surfaceAcceptsInput,
        .issue_serial = issueSerial,
        .terminalize = terminalize,
        .touch_target = touchTarget,
        .assign_cursor_role = assignCursorRole,
        .capabilities = capabilities,
        .keyboard_state = keyboardState,
        .keyboard = keyboard,
        .pointer = pointer,
        .touch = touch,
        .touch_frame = touchFrame,
    };
}

fn assignCursorRole(context: *anyopaque, client_id: ClientRegistry.Id, surface: SurfaceRegistry.Id) SeatDelivery.CursorRoleResult {
    const self: *WayringSeatAdapter = @ptrCast(@alignCast(context));
    const client = self.clients.rawClient(client_id) orelse return .not_live;
    if (client.fatal() != null) return .not_live;
    return switch (self.compositor.assignCursorRole(client, surface)) {
        .assigned => .assigned,
        .already_cursor => .already_cursor,
        .role_conflict => .role_conflict,
        .not_live => .not_live,
        .wrong_client => .wrong_client,
    };
}

fn cursorCommitted(context: *anyopaque, id: SurfaceRegistry.Id, x: i32, y: i32) void {
    const self: *WayringSeatAdapter = @ptrCast(@alignCast(context));
    self.request_sink.cursor_committed(self.request_sink.context, id, x, y);
}
fn cursorRemoved(context: *anyopaque, id: SurfaceRegistry.Id) void {
    const self: *WayringSeatAdapter = @ptrCast(@alignCast(context));
    self.request_sink.cursor_removed(self.request_sink.context, id);
}

fn terminalize(context: *anyopaque, client_id: ClientRegistry.Id, _: SeatDelivery.TerminalReason) void {
    const self: *WayringSeatAdapter = @ptrCast(@alignCast(context));
    const client = self.clients.rawClient(client_id) orelse return;
    for (self.keyboards.items) |keyboard_resource| {
        if (keyboard_resource.client != client) continue;
        self.retireClient(client);
        client.postOutOfMemory(&keyboard_resource.resource.runtime, "storing generated seat state");
        return;
    }
    for (self.pointers.items) |pointer_resource| {
        if (pointer_resource.client != client) continue;
        self.retireClient(client);
        client.postOutOfMemory(&pointer_resource.resource.runtime, "storing generated pointer state");
        return;
    }
    for (self.touches.items) |touch_resource| {
        if (touch_resource.client != client) continue;
        self.retireClient(client);
        client.postOutOfMemory(&touch_resource.resource.runtime, "storing generated touch state");
        return;
    }
    for (self.seats.items) |seat| {
        if (seat.client != client) continue;
        self.retireClient(client);
        client.postOutOfMemory(&seat.resource.runtime, "storing generated seat state");
        return;
    }
}

fn ownerForSurface(
    context: *anyopaque,
    surface: SurfaceRegistry.Id,
) ?ClientRegistry.Id {
    const self: *WayringSeatAdapter = @ptrCast(@alignCast(context));
    const endpoint = self.compositor.surfaceEndpoint(surface) orelse return null;
    if (endpoint.client.fatal() != null) return null;
    return self.compositor.ownerForSurface(self.clients, surface);
}

fn surfaceAcceptsInput(
    context: *anyopaque,
    surface: SurfaceRegistry.Id,
    x: f64,
    y: f64,
) bool {
    const self: *WayringSeatAdapter = @ptrCast(@alignCast(context));
    const endpoint = self.compositor.surfaceEndpoint(surface) orelse return false;
    if (endpoint.client.fatal() != null) return false;
    return self.compositor.surfaceAcceptsInput(surface, x, y);
}

fn issueSerial(
    context: *anyopaque,
    client: ClientRegistry.Id,
) ?ClientRegistry.Serial {
    const self: *WayringSeatAdapter = @ptrCast(@alignCast(context));
    const raw_client = self.clients.rawClient(client) orelse return null;
    if (raw_client.fatal() != null) {
        self.retireClient(raw_client);
        return null;
    }
    const value = self.protocol_server.nextSerial() catch {
        self.terminalizeSerialExhaustion(raw_client);
        return null;
    };
    return .{ .domain = .wayring_server, .value = value };
}

fn terminalizeSerialExhaustion(self: *WayringSeatAdapter, client: *wayring.server.Client) void {
    self.retireClient(client);
    for (self.keyboards.items) |keyboard_resource| {
        if (keyboard_resource.client != client) continue;
        client.postImplementationError(&keyboard_resource.resource.runtime, "generated seat serial exhausted");
        return;
    }
    for (self.pointers.items) |pointer_resource| {
        if (pointer_resource.client != client) continue;
        client.postImplementationError(&pointer_resource.resource.runtime, "generated seat serial exhausted");
        return;
    }
    for (self.touches.items) |touch_resource| {
        if (touch_resource.client != client) continue;
        client.postImplementationError(&touch_resource.resource.runtime, "generated seat serial exhausted");
        return;
    }
    for (self.seats.items) |seat| {
        if (seat.client != client) continue;
        client.postImplementationError(&seat.resource.runtime, "generated seat serial exhausted");
        return;
    }
    // A live generated client cannot receive seat events without having had a
    // seat child resource. If teardown raced the lookup, there is nothing
    // left to deliver or terminalize through this adapter.
}

fn touchTarget(context: *anyopaque, surface: SurfaceRegistry.Id) ?SeatDelivery.TouchTarget {
    const self: *WayringSeatAdapter = @ptrCast(@alignCast(context));
    if (!self.snapshot.touch.available) return null;
    const endpoint = self.compositor.surfaceEndpoint(surface) orelse return null;
    if (endpoint.client.fatal() != null) return null;
    const client = self.clients.id(endpoint.client) orelse return null;
    var max_resource_generation: ?SeatDelivery.ResourceGeneration = null;
    for (self.touches.items) |touch_resource| {
        if (touch_resource.client != endpoint.client or
            !self.snapshot.touch.resourceActive(touch_resource.generation)) continue;
        max_resource_generation = if (max_resource_generation) |current|
            @max(current, touch_resource.resource_generation)
        else
            touch_resource.resource_generation;
    }
    return .{
        .client = client,
        .max_resource_generation = max_resource_generation orelse return null,
    };
}

fn capabilities(context: *anyopaque, snapshot: SeatDelivery.CapabilitySnapshot) void {
    const self: *WayringSeatAdapter = @ptrCast(@alignCast(context));
    const pointer_changed = !std.meta.eql(self.snapshot.pointer, snapshot.pointer);
    if (self.snapshot.touch.available and !snapshot.touch.available)
        self.flushPendingTouchFrames(null);
    self.snapshot = snapshot;
    if (!snapshot.keyboard.available) {
        for (self.keyboards.items) |keyboard_resource| keyboard_resource.focused_surface = null;
    }
    if (!snapshot.pointer.available) {
        for (self.pointers.items) |pointer_resource| {
            pointer_resource.last_enter_serial = null;
            pointer_resource.frame_pending = false;
        }
    }
    for (self.seats.items) |seat| sendCapabilities(seat) catch |err| self.eventFailure(seat.client, &seat.resource.runtime, err);
    if (pointer_changed) if (self.pointer_resource_listener) |listener|
        listener.changed(listener.context);
}
fn keyboardState(context: *anyopaque, event: SeatDelivery.KeyboardStateEvent) void {
    const self: *WayringSeatAdapter = @ptrCast(@alignCast(context));
    if (!self.snapshot.keyboard.available) return;
    for (self.keyboards.items) |keyboard_resource| {
        if (keyboard_resource.client.fatal() != null or
            !self.snapshot.keyboard.resourceActive(keyboard_resource.generation)) continue;
        const result: anyerror!void = switch (event) {
            .keymap => |keymap| if (keymap) |value|
                sendKeymap(keyboard_resource, value)
            else {},
            .repeat_info => |repeat_info| sendRepeatInfo(keyboard_resource, repeat_info),
        };
        result catch |err| self.eventFailure(
            keyboard_resource.client,
            &keyboard_resource.resource.runtime,
            err,
        );
    }
}
fn keyboard(
    context: *anyopaque,
    client_id: ClientRegistry.Id,
    surface: SurfaceRegistry.Id,
    event: SeatDelivery.KeyboardEvent,
) void {
    const self: *WayringSeatAdapter = @ptrCast(@alignCast(context));
    if (!self.snapshot.keyboard.available) return;
    const endpoint = self.compositor.surfaceEndpoint(surface) orelse return;
    if (endpoint.client.fatal() != null) return;
    if (!std.meta.eql(self.clients.id(endpoint.client) orelse return, client_id)) return;
    for (self.keyboards.items) |keyboard_resource| {
        if (keyboard_resource.client != endpoint.client or
            !self.snapshot.keyboard.resourceActive(keyboard_resource.generation)) continue;
        const result: anyerror!void = switch (event) {
            .enter => |enter| sendKeyboardEnter(keyboard_resource, endpoint.resource.id(), surface, enter),
            .leave => |leave| if (keyboardFocusedOn(keyboard_resource, surface))
                sendKeyboardLeave(keyboard_resource, endpoint.resource.id(), leave.serial)
            else {},
            .key => |key| if (keyboardFocusedOn(keyboard_resource, surface) and
                (key.state != .repeated or keyboard_resource.resource.version() >= 10))
                core.wl_keyboard.@"send:key"(
                    &keyboard_resource.resource,
                    key.serial.value,
                    key.time,
                    key.key,
                    @intFromEnum(key.state),
                )
            else {},
            .modifiers => |modifiers| if (keyboardFocusedOn(keyboard_resource, surface))
                sendModifiers(keyboard_resource, modifiers.serial, modifiers.state)
            else {},
        };
        result catch |err| self.eventFailure(
            keyboard_resource.client,
            &keyboard_resource.resource.runtime,
            err,
        );
    }
}

fn sendKeyboardInitial(
    keyboard_resource: *KeyboardResource,
    snapshot: SeatDelivery.KeyboardResourceSnapshot,
) !void {
    try sendKeymap(keyboard_resource, snapshot.keymap);
    try sendRepeatInfo(keyboard_resource, snapshot.repeat_info);
    if (snapshot.focus) |focus| {
        const self = keyboard_resource.adapter;
        const endpoint = self.compositor.surfaceEndpoint(focus.surface) orelse return;
        if (endpoint.client != keyboard_resource.client or endpoint.client.fatal() != null) return;
        try sendKeyboardEnter(keyboard_resource, endpoint.resource.id(), focus.surface, .{
            .serial = focus.serial,
            .pressed_keys = focus.pressed_keys,
            .modifiers = focus.modifiers,
        });
    }
}

fn sendKeymap(keyboard_resource: *KeyboardResource, keymap: SeatDelivery.KeymapSnapshot) !void {
    // Output.enqueue transactionally duplicates this borrowed canonical FD for
    // every resource before exposing its event to the transport.
    try core.wl_keyboard.@"send:keymap"(
        &keyboard_resource.resource,
        keymap.format,
        keymap.fd,
        keymap.size,
    );
}

fn sendRepeatInfo(keyboard_resource: *KeyboardResource, repeat_info: SeatDelivery.RepeatInfo) !void {
    if (keyboard_resource.resource.version() >= 4) {
        try core.wl_keyboard.@"send:repeat_info"(
            &keyboard_resource.resource,
            repeat_info.rate,
            repeat_info.delay,
        );
    }
}

fn sendKeyboardEnter(
    keyboard_resource: *KeyboardResource,
    surface_id: u32,
    surface: SurfaceRegistry.Id,
    enter: @FieldType(SeatDelivery.KeyboardEvent, "enter"),
) !void {
    std.debug.assert(enter.serial.domain == .wayring_server);
    try core.wl_keyboard.@"send:enter"(
        &keyboard_resource.resource,
        enter.serial.value,
        surface_id,
        std.mem.sliceAsBytes(enter.pressed_keys),
    );
    try sendModifiers(keyboard_resource, enter.serial.value, enter.modifiers);
    keyboard_resource.focused_surface = surface;
}

fn sendKeyboardLeave(keyboard_resource: *KeyboardResource, surface_id: u32, serial: u32) !void {
    try core.wl_keyboard.@"send:leave"(&keyboard_resource.resource, serial, surface_id);
    keyboard_resource.focused_surface = null;
}

fn sendModifiers(
    keyboard_resource: *KeyboardResource,
    serial: u32,
    modifiers: SeatDelivery.Modifiers,
) !void {
    try core.wl_keyboard.@"send:modifiers"(
        &keyboard_resource.resource,
        serial,
        modifiers.depressed,
        modifiers.latched,
        modifiers.locked,
        modifiers.group,
    );
}

fn keyboardFocusedOn(keyboard_resource: *const KeyboardResource, surface: SurfaceRegistry.Id) bool {
    return if (keyboard_resource.focused_surface) |focused|
        std.meta.eql(focused, surface)
    else
        false;
}
fn pointer(context: *anyopaque, client_id: ClientRegistry.Id, surface: SurfaceRegistry.Id, event: SeatDelivery.PointerEvent) void {
    const self: *WayringSeatAdapter = @ptrCast(@alignCast(context));
    if (!self.snapshot.pointer.available) return;
    const endpoint = self.compositor.surfaceEndpoint(surface) orelse return;
    if (endpoint.client.fatal() != null) return;
    if (!std.meta.eql(self.clients.id(endpoint.client) orelse return, client_id)) return;
    for (self.pointers.items) |p| {
        if (p.client != endpoint.client or p.generation != self.snapshot.pointer.generation) continue;
        const tag = std.meta.activeTag(event);
        if (tag == .frame) {
            if (p.last_enter_serial == null and !p.frame_pending) continue;
        } else if (tag != .enter and p.last_enter_serial == null) continue;
        const result: anyerror!void = switch (event) {
            .enter => |v| sendEnter(p, endpoint.resource.id(), v),
            .leave => |v| sendLeave(p, endpoint.resource.id(), v.serial),
            .motion => |v| core.wl_pointer.@"send:motion"(&p.resource, v.time, v.x, v.y),
            .button => |v| core.wl_pointer.@"send:button"(&p.resource, v.serial.value, v.time, v.button, @intFromEnum(v.state)),
            .axis => |v| core.wl_pointer.@"send:axis"(&p.resource, v.time, v.axis, v.value),
            .frame => sendFrame(p),
            .axis_source => |v| if (p.resource.version() >= 5) core.wl_pointer.@"send:axis_source"(&p.resource, v) else {},
            .axis_stop => |v| if (p.resource.version() >= 5) core.wl_pointer.@"send:axis_stop"(&p.resource, v.time, v.axis) else {},
            .axis_discrete => |v| if (p.resource.version() >= 5 and p.resource.version() <= 7) core.wl_pointer.@"send:axis_discrete"(&p.resource, v.axis, v.discrete) else {},
            .axis_value120 => |v| if (p.resource.version() >= 8) core.wl_pointer.@"send:axis_value120"(&p.resource, v.axis, v.value120) else {},
            .axis_relative_direction => |v| if (p.resource.version() >= 9) core.wl_pointer.@"send:axis_relative_direction"(&p.resource, v.axis, v.direction) else {},
        };
        result catch |err| self.eventFailure(p.client, &p.resource.runtime, err);
    }
}

fn sendEnter(pointer_resource: *PointerResource, surface_id: u32, event: @FieldType(SeatDelivery.PointerEvent, "enter")) !void {
    try core.wl_pointer.@"send:enter"(
        &pointer_resource.resource,
        event.serial.value,
        surface_id,
        event.x,
        event.y,
    );
    pointer_resource.last_enter_serial = event.serial.value;
    pointer_resource.frame_pending = false;
}

fn sendLeave(pointer_resource: *PointerResource, surface_id: u32, serial: u32) !void {
    try core.wl_pointer.@"send:leave"(&pointer_resource.resource, serial, surface_id);
    pointer_resource.last_enter_serial = null;
    pointer_resource.frame_pending = true;
}

fn sendFrame(pointer_resource: *PointerResource) !void {
    if (pointer_resource.resource.version() >= 5)
        try core.wl_pointer.@"send:frame"(&pointer_resource.resource);
    pointer_resource.frame_pending = false;
}

fn touch(context: *anyopaque, client_id: ClientRegistry.Id, event: SeatDelivery.TouchEvent) void {
    const self: *WayringSeatAdapter = @ptrCast(@alignCast(context));
    if (!self.snapshot.touch.available) return;
    const client = self.clients.rawClient(client_id) orelse return;
    if (client.fatal() != null) return;
    const surface_id: ?u32 = switch (event) {
        .down => |down| surface: {
            const endpoint = self.compositor.surfaceEndpoint(down.surface) orelse return;
            if (endpoint.client != client or endpoint.client.fatal() != null) return;
            break :surface endpoint.resource.id();
        },
        else => null,
    };
    const max_resource_generation: ?SeatDelivery.ResourceGeneration = switch (event) {
        .down => |value| value.max_resource_generation,
        .up => |value| value.max_resource_generation,
        .motion => |value| value.max_resource_generation,
        .frame => null,
        .cancel => |value| value.max_resource_generation,
        .shape => |value| value.max_resource_generation,
        .orientation => |value| value.max_resource_generation,
    };
    for (self.touches.items) |touch_resource| {
        if (touch_resource.client != client or touch_resource.client.fatal() != null or
            !self.snapshot.touch.resourceActive(touch_resource.generation)) continue;
        if (max_resource_generation) |cutoff| {
            if (!SeatDelivery.resourceInSequence(touch_resource.resource_generation, cutoff)) continue;
        } else if (!touch_resource.frame_pending) continue;
        const result: anyerror!void = switch (event) {
            .down => |value| sendTouchDown(touch_resource, surface_id.?, value),
            .up => |value| sendTouchUp(touch_resource, value),
            .motion => |value| sendTouchMotion(touch_resource, value),
            .frame => sendTouchFrame(touch_resource),
            .cancel => sendTouchCancel(touch_resource),
            .shape => |value| sendTouchShape(touch_resource, value),
            .orientation => |value| sendTouchOrientation(touch_resource, value),
        };
        result catch |err| self.eventFailure(client, &touch_resource.resource.runtime, err);
    }
    if (event == .cancel) self.flushPendingTouchFrames(client);
}

fn touchFrame(context: *anyopaque) void {
    const self: *WayringSeatAdapter = @ptrCast(@alignCast(context));
    if (!self.snapshot.touch.available) return;
    self.flushPendingTouchFrames(null);
}

fn flushPendingTouchFrames(
    self: *WayringSeatAdapter,
    client: ?*wayring.server.Client,
) void {
    for (self.touches.items) |touch_resource| {
        if (client) |expected| {
            if (touch_resource.client != expected) continue;
        }
        if (touch_resource.client.fatal() != null or
            !self.snapshot.touch.resourceActive(touch_resource.generation) or
            !touch_resource.frame_pending) continue;
        sendTouchFrame(touch_resource) catch |err|
            self.eventFailure(touch_resource.client, &touch_resource.resource.runtime, err);
    }
}

fn sendTouchDown(
    touch_resource: *TouchResource,
    surface_id: u32,
    event: @FieldType(SeatDelivery.TouchEvent, "down"),
) !void {
    std.debug.assert(event.serial.domain == .wayring_server);
    try core.wl_touch.@"send:down"(
        &touch_resource.resource,
        event.serial.value,
        event.time,
        surface_id,
        event.id,
        event.x,
        event.y,
    );
    touch_resource.frame_pending = true;
}

fn sendTouchUp(
    touch_resource: *TouchResource,
    event: @FieldType(SeatDelivery.TouchEvent, "up"),
) !void {
    std.debug.assert(event.serial.domain == .wayring_server);
    try core.wl_touch.@"send:up"(
        &touch_resource.resource,
        event.serial.value,
        event.time,
        event.id,
    );
    touch_resource.frame_pending = true;
}

fn sendTouchMotion(
    touch_resource: *TouchResource,
    event: @FieldType(SeatDelivery.TouchEvent, "motion"),
) !void {
    try core.wl_touch.@"send:motion"(
        &touch_resource.resource,
        event.time,
        event.id,
        event.x,
        event.y,
    );
    touch_resource.frame_pending = true;
}

fn sendTouchFrame(touch_resource: *TouchResource) !void {
    try core.wl_touch.@"send:frame"(&touch_resource.resource);
    touch_resource.frame_pending = false;
}

fn sendTouchCancel(touch_resource: *TouchResource) !void {
    defer touch_resource.frame_pending = false;
    try core.wl_touch.@"send:cancel"(&touch_resource.resource);
}

fn sendTouchShape(
    touch_resource: *TouchResource,
    event: @FieldType(SeatDelivery.TouchEvent, "shape"),
) !void {
    if (touch_resource.resource.version() < 6) return;
    try core.wl_touch.@"send:shape"(
        &touch_resource.resource,
        event.id,
        event.major,
        event.minor,
    );
    touch_resource.frame_pending = true;
}

fn sendTouchOrientation(
    touch_resource: *TouchResource,
    event: @FieldType(SeatDelivery.TouchEvent, "orientation"),
) !void {
    if (touch_resource.resource.version() < 6) return;
    try core.wl_touch.@"send:orientation"(
        &touch_resource.resource,
        event.id,
        event.orientation,
    );
    touch_resource.frame_pending = true;
}

fn retireClient(self: *WayringSeatAdapter, client: *wayring.server.Client) void {
    const client_id = self.clients.id(client) orelse return;
    self.request_sink.client_retiring(self.request_sink.context, client_id);
}

test "capability bits and generations gate generated seat child resources" {
    var snapshot: SeatDelivery.CapabilitySnapshot = .{};
    try std.testing.expectEqual(@as(u32, 0), capabilityBits(snapshot));
    try std.testing.expect(snapshot.pointer.setAvailable(true));
    const first_pointer = snapshot.pointer.generation;
    try std.testing.expectEqual(@as(u32, 1), capabilityBits(snapshot));
    try std.testing.expect(snapshot.pointer.resourceActive(first_pointer));
    try std.testing.expect(snapshot.keyboard.setAvailable(true));
    const first_keyboard = snapshot.keyboard.generation;
    try std.testing.expectEqual(@as(u32, 3), capabilityBits(snapshot));
    try std.testing.expect(snapshot.keyboard.resourceActive(first_keyboard));
    try std.testing.expect(snapshot.pointer.setAvailable(false));
    try std.testing.expect(!snapshot.pointer.resourceActive(first_pointer));
    try std.testing.expect(snapshot.pointer.setAvailable(true));
    try std.testing.expect(snapshot.pointer.generation > first_pointer);
    try std.testing.expect(!snapshot.pointer.resourceActive(first_pointer));

    try std.testing.expect(snapshot.keyboard.setAvailable(false));
    try std.testing.expect(!snapshot.keyboard.resourceActive(first_keyboard));
    try std.testing.expect(snapshot.keyboard.setAvailable(true));
    try std.testing.expect(snapshot.keyboard.generation > first_keyboard);
    try std.testing.expect(!snapshot.keyboard.resourceActive(first_keyboard));

    try std.testing.expect(snapshot.touch.setAvailable(true));
    const first_touch = snapshot.touch.generation;
    try std.testing.expectEqual(@as(u32, 7), capabilityBits(snapshot));
    try std.testing.expect(snapshot.touch.resourceActive(first_touch));
    try std.testing.expect(snapshot.touch.setAvailable(false));
    try std.testing.expectEqual(@as(u32, 3), capabilityBits(snapshot));
    try std.testing.expect(snapshot.touch.setAvailable(true));
    try std.testing.expect(snapshot.touch.generation > first_touch);
    try std.testing.expect(!snapshot.touch.resourceActive(first_touch));
}

const TestRequestProbe = struct {
    pointer_grab_client: ?ClientRegistry.Id = null,
    pointer_grab_serial: ?ClientRegistry.Serial = null,
    pointer_grab_surface: ?SurfaceRegistry.Id = null,
    pointer_enter_snapshot: ?SeatDelivery.PointerEnterSnapshot = null,
    pointer_enter_client: ?ClientRegistry.Id = null,
    pointer_enter_generation: SeatDelivery.ResourceGeneration = 0,
    keyboard_resource_snapshot: ?SeatDelivery.KeyboardResourceSnapshot = null,
    keyboard_resource_client: ?ClientRegistry.Id = null,
    keyboard_resource_generation: SeatDelivery.ResourceGeneration = 0,
    set_cursor_result: SeatDelivery.CursorRequestResult = .accepted,
    last_cursor_request: ?SeatDelivery.CursorRequest = null,
    set_cursor_count: usize = 0,
    committed_count: usize = 0,
    removed_count: usize = 0,
    retiring_count: usize = 0,
    last_retiring: ?ClientRegistry.Id = null,
    watched_terminal_client: ?*wayring.server.Client = null,
    retiring_before_fatal: bool = false,

    fn sink(self: *TestRequestProbe) SeatDelivery.RequestSink {
        return .{
            .context = self,
            .pointer_enter_snapshot = pointerEnterSnapshot,
            .keyboard_resource_snapshot = keyboardResourceSnapshot,
            .accepts_pointer_grab = acceptsPointerGrab,
            .accepts_action = acceptsAction,
            .set_cursor = setCursor,
            .cursor_committed = recordCursorCommitted,
            .cursor_removed = recordCursorRemoved,
            .client_retiring = recordClientRetiring,
        };
    }

    fn acceptsPointerGrab(
        context: *anyopaque,
        client: ClientRegistry.Id,
        serial: ClientRegistry.Serial,
        surface: SurfaceRegistry.Id,
    ) bool {
        const self: *TestRequestProbe = @ptrCast(@alignCast(context));
        return self.pointer_grab_client != null and self.pointer_grab_serial != null and
            self.pointer_grab_surface != null and std.meta.eql(self.pointer_grab_client.?, client) and
            std.meta.eql(self.pointer_grab_serial.?, serial) and
            std.meta.eql(self.pointer_grab_surface.?, surface);
    }

    fn acceptsAction(context: *anyopaque, client: ClientRegistry.Id, serial: ClientRegistry.Serial) bool {
        const self: *TestRequestProbe = @ptrCast(@alignCast(context));
        return self.pointer_grab_client != null and self.pointer_grab_serial != null and
            std.meta.eql(self.pointer_grab_client.?, client) and
            std.meta.eql(self.pointer_grab_serial.?, serial);
    }

    fn pointerEnterSnapshot(
        context: *anyopaque,
        client: ClientRegistry.Id,
        generation: SeatDelivery.ResourceGeneration,
    ) ?SeatDelivery.PointerEnterSnapshot {
        const self: *TestRequestProbe = @ptrCast(@alignCast(context));
        if (self.pointer_enter_client == null or
            !std.meta.eql(self.pointer_enter_client.?, client) or
            self.pointer_enter_generation != generation) return null;
        return self.pointer_enter_snapshot;
    }

    fn keyboardResourceSnapshot(
        context: *anyopaque,
        client: ClientRegistry.Id,
        generation: SeatDelivery.ResourceGeneration,
    ) ?SeatDelivery.KeyboardResourceSnapshot {
        const self: *TestRequestProbe = @ptrCast(@alignCast(context));
        if (self.keyboard_resource_client == null or
            !std.meta.eql(self.keyboard_resource_client.?, client) or
            self.keyboard_resource_generation != generation) return null;
        return self.keyboard_resource_snapshot;
    }

    fn setCursor(context: *anyopaque, request: SeatDelivery.CursorRequest) SeatDelivery.CursorRequestResult {
        const self: *TestRequestProbe = @ptrCast(@alignCast(context));
        self.last_cursor_request = request;
        self.set_cursor_count += 1;
        return self.set_cursor_result;
    }

    fn recordCursorCommitted(_: *anyopaque, _: SurfaceRegistry.Id, _: i32, _: i32) void {}

    fn recordCursorRemoved(context: *anyopaque, _: SurfaceRegistry.Id) void {
        const self: *TestRequestProbe = @ptrCast(@alignCast(context));
        self.removed_count += 1;
    }

    fn recordClientRetiring(context: *anyopaque, client: ClientRegistry.Id) void {
        const self: *TestRequestProbe = @ptrCast(@alignCast(context));
        self.retiring_count += 1;
        self.last_retiring = client;
        if (self.watched_terminal_client) |raw|
            self.retiring_before_fatal = raw.fatal() == null;
    }
};

const TestEventLog = struct {
    const Entry = struct {
        client: *wayring.server.Client,
        object_id: u32,
        name: []const u8,
    };

    entries: std.ArrayList(Entry) = .empty,

    fn observe(self: *TestEventLog, client: *wayring.server.Client, message: wayring.server.Client.ProtocolMessage) void {
        if (message.direction != .event) return;
        self.entries.append(std.testing.allocator, .{
            .client = client,
            .object_id = message.resource.id(),
            .name = message.descriptor.name,
        }) catch unreachable;
    }

    fn deinit(self: *TestEventLog) void {
        self.entries.deinit(std.testing.allocator);
    }

    fn clear(self: *TestEventLog) void {
        self.entries.clearRetainingCapacity();
    }

    fn namesFor(
        self: *const TestEventLog,
        client: *wayring.server.Client,
        object_id: u32,
        buffer: [][]const u8,
    ) []const []const u8 {
        var count: usize = 0;
        for (self.entries.items) |entry| {
            if (entry.client != client or entry.object_id != object_id) continue;
            buffer[count] = entry.name;
            count += 1;
        }
        return buffer[0..count];
    }
};

const TestKeyboardLog = struct {
    const Entry = struct {
        client: *wayring.server.Client,
        object_id: u32,
        name: []const u8,
        serial: ?u32 = null,
        format: ?u32 = null,
        size: ?u32 = null,
        state: ?u32 = null,
        keys: [8]u32 = @splat(0),
        key_count: usize = 0,
    };

    entries: std.ArrayList(Entry) = .empty,

    fn observe(self: *TestKeyboardLog, client: *wayring.server.Client, message: wayring.server.Client.ProtocolMessage) void {
        if (message.direction != .event or
            !std.mem.eql(u8, message.resource.interface().name, "wl_keyboard")) return;
        var entry: Entry = .{
            .client = client,
            .object_id = message.resource.id(),
            .name = message.descriptor.name,
        };
        if (std.mem.eql(u8, message.descriptor.name, "keymap")) {
            entry.format = message.values[0].uint;
            entry.size = message.values[2].uint;
        } else if (std.mem.eql(u8, message.descriptor.name, "enter")) {
            entry.serial = message.values[0].uint;
            const bytes = message.values[2].array;
            std.debug.assert(bytes.len % @sizeOf(u32) == 0);
            entry.key_count = @min(bytes.len / @sizeOf(u32), entry.keys.len);
            for (0..entry.key_count) |index| {
                entry.keys[index] = std.mem.readInt(
                    u32,
                    bytes[index * @sizeOf(u32) ..][0..@sizeOf(u32)],
                    .native,
                );
            }
        } else if (std.mem.eql(u8, message.descriptor.name, "leave") or
            std.mem.eql(u8, message.descriptor.name, "key") or
            std.mem.eql(u8, message.descriptor.name, "modifiers"))
        {
            entry.serial = message.values[0].uint;
            if (std.mem.eql(u8, message.descriptor.name, "key"))
                entry.state = message.values[3].uint;
        }
        self.entries.append(std.testing.allocator, entry) catch unreachable;
    }

    fn deinit(self: *TestKeyboardLog) void {
        self.entries.deinit(std.testing.allocator);
    }

    fn clear(self: *TestKeyboardLog) void {
        self.entries.clearRetainingCapacity();
    }

    fn namesFor(
        self: *const TestKeyboardLog,
        client: *wayring.server.Client,
        object_id: u32,
        buffer: [][]const u8,
    ) []const []const u8 {
        var count: usize = 0;
        for (self.entries.items) |entry| {
            if (entry.client != client or entry.object_id != object_id) continue;
            buffer[count] = entry.name;
            count += 1;
        }
        return buffer[0..count];
    }

    fn find(self: *const TestKeyboardLog, client: *wayring.server.Client, object_id: u32, name: []const u8) ?Entry {
        for (self.entries.items) |entry| {
            if (entry.client == client and entry.object_id == object_id and
                std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }
};

const TestTouchLog = struct {
    const Entry = struct {
        client: *wayring.server.Client,
        object_id: u32,
        name: []const u8,
        serial: ?u32 = null,
        time: ?u32 = null,
        surface: ?u32 = null,
        id: ?i32 = null,
        x: ?i32 = null,
        y: ?i32 = null,
    };

    entries: std.ArrayList(Entry) = .empty,

    fn observe(self: *TestTouchLog, client: *wayring.server.Client, message: wayring.server.Client.ProtocolMessage) void {
        if (message.direction != .event or
            !std.mem.eql(u8, message.resource.interface().name, "wl_touch")) return;
        var entry: Entry = .{
            .client = client,
            .object_id = message.resource.id(),
            .name = message.descriptor.name,
        };
        if (std.mem.eql(u8, entry.name, "down")) {
            entry.serial = message.values[0].uint;
            entry.time = message.values[1].uint;
            entry.surface = message.values[2].object;
            entry.id = message.values[3].int;
            entry.x = message.values[4].fixed;
            entry.y = message.values[5].fixed;
        } else if (std.mem.eql(u8, entry.name, "up")) {
            entry.serial = message.values[0].uint;
            entry.time = message.values[1].uint;
            entry.id = message.values[2].int;
        } else if (std.mem.eql(u8, entry.name, "motion")) {
            entry.time = message.values[0].uint;
            entry.id = message.values[1].int;
            entry.x = message.values[2].fixed;
            entry.y = message.values[3].fixed;
        } else if (std.mem.eql(u8, entry.name, "shape")) {
            entry.id = message.values[0].int;
            entry.x = message.values[1].fixed;
            entry.y = message.values[2].fixed;
        } else if (std.mem.eql(u8, entry.name, "orientation")) {
            entry.id = message.values[0].int;
            entry.x = message.values[1].fixed;
        }
        self.entries.append(std.testing.allocator, entry) catch unreachable;
    }

    fn deinit(self: *TestTouchLog) void {
        self.entries.deinit(std.testing.allocator);
    }

    fn clear(self: *TestTouchLog) void {
        self.entries.clearRetainingCapacity();
    }

    fn namesFor(
        self: *const TestTouchLog,
        client: *wayring.server.Client,
        object_id: u32,
        buffer: [][]const u8,
    ) []const []const u8 {
        var count: usize = 0;
        for (self.entries.items) |entry| {
            if (entry.client != client or entry.object_id != object_id) continue;
            buffer[count] = entry.name;
            count += 1;
        }
        return buffer[0..count];
    }

    fn find(self: *const TestTouchLog, client: *wayring.server.Client, object_id: u32, name: []const u8) ?Entry {
        for (self.entries.items) |entry| {
            if (entry.client == client and entry.object_id == object_id and
                std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }
};

const AdapterTestSetup = struct {
    client_registry: ClientRegistry,
    surface_registry: SurfaceRegistry,
    protocol_server: wayring.server.Server,
    clients: WayringClients,
    compositor: WayringCompositor,
    probe: TestRequestProbe,
    adapter: WayringSeatAdapter,

    fn init(self: *AdapterTestSetup) !void {
        try self.initWithAdapterAllocator(std.testing.allocator);
    }

    fn initWithAdapterAllocator(self: *AdapterTestSetup, adapter_allocator: std.mem.Allocator) !void {
        self.client_registry = ClientRegistry.init(std.testing.allocator);
        self.surface_registry = SurfaceRegistry.init(std.testing.allocator);
        self.protocol_server = .init(std.testing.allocator);
        self.clients.init(std.testing.allocator, &self.client_registry);
        try self.compositor.init(
            std.testing.allocator,
            &self.protocol_server,
            &self.surface_registry,
            null,
        );
        self.probe = .{};
        self.adapter = .init(
            adapter_allocator,
            &self.protocol_server,
            &self.clients,
            &self.compositor,
            self.probe.sink(),
            "test-seat",
        );
        self.adapter.installCursorListener();
    }

    fn deinit(self: *AdapterTestSetup) void {
        self.adapter.clearCursorListener();
        self.adapter.deinit();
        self.compositor.deinit();
        self.clients.deinit();
        self.protocol_server.deinit();
        self.surface_registry.deinit();
        self.client_registry.deinit();
    }

    fn registerClient(self: *AdapterTestSetup, client: *wayring.server.Client) !ClientRegistry.Id {
        const id = try self.clients.register(client);
        errdefer self.clients.unregister(client);
        try self.adapter.trackClient(client);
        return id;
    }

    fn destroyClient(self: *AdapterTestSetup, managed: *wayring.server.CoreClient) void {
        const client = managed.client();
        self.adapter.destroyClientResources(client);
        self.compositor.destroyClientResources(client);
        if (self.clients.id(client) != null) self.clients.unregister(client);
        managed.destroy();
    }
};

fn testSeatBind(
    client: *wayring.server.Client,
    id: u32,
    version: u32,
    adapter: *WayringSeatAdapter,
) !void {
    try adapter.bind(client, id, version);
}

fn testSend(
    client: *wayring.server.Client,
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

fn testDrain(client: *wayring.server.Client) !void {
    while (try client.beginSend()) |batch|
        try client.completeSend(batch.token, batch.bytes.len);
}

fn testGlobal(server: *const wayring.server.Server, name: []const u8) *const wayring.server.Server.Global {
    var globals = server.iterator();
    while (globals.next()) |global| {
        if (std.mem.eql(u8, global.interface().name, name)) return global;
    }
    unreachable;
}

fn testPrepareRegistry(client: *wayring.server.Client) !void {
    try testSend(client, 1, 1, &core.wl_display.request_messages[1], &.{
        .{ .new_id = .{ .typed = 2 } },
    });
    try testDrain(client);
}

fn testBindGlobal(
    client: *wayring.server.Client,
    global: *const wayring.server.Server.Global,
    version: u32,
    id: u32,
) !void {
    try testSend(client, 2, 0, &core.wl_registry.request_messages[0], &.{
        .{ .uint = global.name() },
        .{ .new_id = .{ .generic = .{
            .interface = global.interface().name,
            .version = version,
            .id = id,
        } } },
    });
}

fn testCreateSurface(client: *wayring.server.Client, compositor_id: u32, surface_id: u32) !void {
    try testSend(client, compositor_id, 0, &core.wl_compositor.request_messages[0], &.{
        .{ .new_id = .{ .typed = surface_id } },
    });
}

fn testGetPointer(client: *wayring.server.Client, seat_id: u32, pointer_id: u32) !void {
    try testSend(client, seat_id, 0, &core.wl_seat.request_messages[0], &.{
        .{ .new_id = .{ .typed = pointer_id } },
    });
}

fn testGetKeyboard(client: *wayring.server.Client, seat_id: u32, keyboard_id: u32) !void {
    try testSend(client, seat_id, 1, &core.wl_seat.request_messages[1], &.{
        .{ .new_id = .{ .typed = keyboard_id } },
    });
}

fn testGetTouch(client: *wayring.server.Client, seat_id: u32, touch_id: u32) !void {
    try testSend(client, seat_id, 2, &core.wl_seat.request_messages[2], &.{
        .{ .new_id = .{ .typed = touch_id } },
    });
}

fn expectEventNames(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_name, actual_name|
        try std.testing.expectEqualStrings(expected_name, actual_name);
}

fn countPublished(server: *const wayring.server.Server, name: []const u8) usize {
    var count: usize = 0;
    var globals = server.iterator();
    while (globals.next()) |global| {
        if (std.mem.eql(u8, global.interface().name, name)) count += 1;
    }
    return count;
}

test "production seat publication follows core globals and negotiates and releases exactly" {
    var setup: AdapterTestSetup = undefined;
    try setup.init();
    defer setup.deinit();
    try std.testing.expectEqual(@as(usize, 0), countPublished(&setup.protocol_server, "wl_seat"));

    var snapshot: SeatDelivery.CapabilitySnapshot = .{};
    _ = snapshot.pointer.setAvailable(true);
    _ = snapshot.keyboard.setAvailable(true);
    _ = snapshot.touch.setAvailable(true);
    capabilities(&setup.adapter, snapshot);
    try setup.adapter.publish();
    var published = true;
    defer if (published) setup.adapter.unpublish();
    const seat_global = setup.adapter.global.?;
    try std.testing.expectEqual(@as(usize, 1), countPublished(&setup.protocol_server, "wl_seat"));
    const expected_globals = [_]struct { name: []const u8, version: u32 }{
        .{ .name = "wl_compositor", .version = 6 },
        .{ .name = "wl_shm", .version = 1 },
        .{ .name = "wl_subcompositor", .version = 1 },
        .{ .name = "wl_seat", .version = core.wl_seat.interface.version },
    };
    var globals = setup.protocol_server.iterator();
    for (expected_globals) |expected| {
        const global = globals.next().?;
        try std.testing.expectEqualStrings(expected.name, global.interface().name);
        try std.testing.expectEqual(expected.version, global.version());
    }
    try std.testing.expect(globals.next() == null);

    const managed = try wayring.server.CoreClient.create(std.testing.allocator, &setup.protocol_server, .{});
    const client = managed.client();
    const client_id = try setup.registerClient(client);
    var client_live = true;
    defer if (client_live) setup.destroyClient(managed);
    var pipe_fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.Unexpected;
    defer _ = std.c.close(pipe_fds[0]);
    defer _ = std.c.close(pipe_fds[1]);
    setup.probe.keyboard_resource_client = client_id;
    setup.probe.keyboard_resource_generation = snapshot.keyboard.generation;
    setup.probe.keyboard_resource_snapshot = .{
        .keymap = .{ .format = 1, .fd = pipe_fds[0], .size = 8 },
        .repeat_info = .{ .rate = 25, .delay = 600 },
        .focus = null,
    };

    var log: TestEventLog = .{};
    defer log.deinit();
    const logger = try setup.protocol_server.addProtocolLogger(TestEventLog, &log, TestEventLog.observe);
    defer setup.protocol_server.removeProtocolLogger(logger);
    try testPrepareRegistry(client);
    log.clear();
    try testBindGlobal(client, seat_global, 11, 3);
    var names_buffer: [8][]const u8 = undefined;
    try expectEventNames(&.{ "name", "capabilities" }, log.namesFor(client, 3, &names_buffer));
    try std.testing.expectEqual(@as(u32, 11), setup.adapter.seats.items[0].resource.version());

    try testGetPointer(client, 3, 4);
    try std.testing.expectEqual(@as(u32, 11), setup.adapter.pointers.items[0].resource.version());
    try testGetKeyboard(client, 3, 5);
    try std.testing.expectEqual(@as(u32, 11), setup.adapter.keyboards.items[0].resource.version());
    try testGetTouch(client, 3, 6);
    try std.testing.expectEqual(@as(u32, 11), setup.adapter.touches.items[0].resource.version());
    try testSend(client, 6, 0, &core.wl_touch.request_messages[0], &.{});
    try std.testing.expectEqual(@as(usize, 0), setup.adapter.touches.items.len);
    try std.testing.expect(client.lookup(6) == null);
    try testSend(client, 5, 0, &core.wl_keyboard.request_messages[0], &.{});
    try std.testing.expectEqual(@as(usize, 0), setup.adapter.keyboards.items.len);
    try std.testing.expect(client.lookup(5) == null);
    try testSend(client, 4, 1, &core.wl_pointer.request_messages[1], &.{});
    try std.testing.expectEqual(@as(usize, 0), setup.adapter.pointers.items.len);
    try std.testing.expect(client.lookup(4) == null);
    try testSend(client, 3, 3, &core.wl_seat.request_messages[3], &.{});
    try std.testing.expectEqual(@as(usize, 0), setup.adapter.seats.items.len);
    try std.testing.expect(client.lookup(3) == null);

    setup.adapter.unpublish();
    published = false;
    try std.testing.expectEqual(@as(usize, 0), countPublished(&setup.protocol_server, "wl_seat"));
    setup.destroyClient(managed);
    client_live = false;
}

test "XDG pointer grabs require the exact live generated seat client and serial" {
    var setup: AdapterTestSetup = undefined;
    try setup.init();
    defer setup.deinit();

    const managed = try wayring.server.CoreClient.create(std.testing.allocator, &setup.protocol_server, .{});
    const client = managed.client();
    var client_live = true;
    defer if (client_live) setup.destroyClient(managed);
    const client_id = try setup.registerClient(client);
    try setup.adapter.publish();
    var published = true;
    defer if (published) setup.adapter.unpublish();
    try testPrepareRegistry(client);
    try testBindGlobal(client, setup.adapter.global.?, 7, 3);

    const surface: SurfaceRegistry.Id = .{ .index = 4, .generation = 2 };
    setup.probe.pointer_grab_client = client_id;
    setup.probe.pointer_grab_serial = .{ .domain = .wayring_server, .value = 17 };
    setup.probe.pointer_grab_surface = surface;
    try std.testing.expectEqual(client_id, setup.adapter.acceptsXdgPointerGrab(client, 3, 17, surface).?);

    const other_managed = try wayring.server.CoreClient.create(std.testing.allocator, &setup.protocol_server, .{});
    const other_client = other_managed.client();
    var other_live = true;
    defer if (other_live) setup.destroyClient(other_managed);
    _ = try setup.registerClient(other_client);
    try std.testing.expect(setup.adapter.acceptsXdgPointerGrab(other_client, 3, 17, surface) == null);
    try std.testing.expect(setup.adapter.acceptsXdgPointerGrab(client, 2, 17, surface) == null);
    try std.testing.expect(setup.adapter.acceptsXdgPointerGrab(client, 3, 18, surface) == null);
    try std.testing.expect(setup.adapter.acceptsXdgPointerGrab(client, 3, 17, .{ .index = 5, .generation = 2 }) == null);

    try testSend(client, 3, 3, &core.wl_seat.request_messages[3], &.{});
    try std.testing.expect(setup.adapter.acceptsXdgPointerGrab(client, 3, 17, surface) == null);
    setup.adapter.unpublish();
    published = false;
    setup.destroyClient(other_managed);
    other_live = false;
    setup.destroyClient(managed);
    client_live = false;
}

test "XDG user actions require the exact live generated seat client and serial" {
    var setup: AdapterTestSetup = undefined;
    try setup.init();
    defer setup.deinit();
    const managed = try wayring.server.CoreClient.create(std.testing.allocator, &setup.protocol_server, .{});
    const client = managed.client();
    defer setup.destroyClient(managed);
    const client_id = try setup.registerClient(client);
    try setup.adapter.publish();
    defer setup.adapter.unpublish();
    try testPrepareRegistry(client);
    try testBindGlobal(client, setup.adapter.global.?, 7, 3);
    setup.probe.pointer_grab_client = client_id;
    setup.probe.pointer_grab_serial = .{ .domain = .wayring_server, .value = 19 };
    try std.testing.expectEqual(client_id, setup.adapter.acceptsXdgUserAction(client, 3, 19).?);
    try std.testing.expect(setup.adapter.acceptsXdgUserAction(client, 2, 19) == null);
    try std.testing.expect(setup.adapter.acceptsXdgUserAction(client, 3, 20) == null);
    try testSend(client, 3, 3, &core.wl_seat.request_messages[3], &.{});
    try std.testing.expect(setup.adapter.acceptsXdgUserAction(client, 3, 19) == null);
}

test "seat publication failure leaves no seat or stale bind context and outer rollback is exact" {
    var protocol_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var client_registry = ClientRegistry.init(std.testing.allocator);
    defer client_registry.deinit();
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var protocol_server: wayring.server.Server = .init(protocol_allocator.allocator());
    var protocol_server_live = true;
    defer if (protocol_server_live) protocol_server.deinit();
    var clients: WayringClients = undefined;
    clients.init(std.testing.allocator, &client_registry);
    defer clients.deinit();
    var compositor: WayringCompositor = undefined;
    try compositor.init(
        std.testing.allocator,
        &protocol_server,
        &surface_registry,
        null,
    );
    var compositor_live = true;
    defer if (compositor_live) compositor.deinit();
    var probe: TestRequestProbe = .{};
    var adapter: WayringSeatAdapter = .init(
        std.testing.allocator,
        &protocol_server,
        &clients,
        &compositor,
        probe.sink(),
        "test-seat",
    );
    var adapter_live = true;
    defer if (adapter_live) adapter.deinit();

    protocol_allocator.fail_index = protocol_allocator.alloc_index;
    try std.testing.expectError(error.OutOfMemory, adapter.publish());
    try std.testing.expect(protocol_allocator.has_induced_failure);
    try std.testing.expect(adapter.global == null);
    try std.testing.expectEqual(@as(usize, 0), countPublished(&protocol_server, "wl_seat"));

    compositor.deinit();
    compositor_live = false;
    var globals = protocol_server.iterator();
    try std.testing.expect(globals.next() == null);
    adapter.deinit();
    adapter_live = false;
    protocol_server.deinit();
    protocol_server_live = false;
    try std.testing.expectEqual(protocol_allocator.allocated_bytes, protocol_allocator.freed_bytes);
}

test "scanner keyboard repeat_info begins at protocol version four" {
    var setup: AdapterTestSetup = undefined;
    try setup.init();
    defer setup.deinit();
    var capability_snapshot: SeatDelivery.CapabilitySnapshot = .{};
    _ = capability_snapshot.keyboard.setAvailable(true);
    capabilities(&setup.adapter, capability_snapshot);
    const seat_global = try setup.protocol_server.addGlobal(
        core.wl_seat,
        core.wl_seat.interface.version,
        WayringSeatAdapter,
        &setup.adapter,
        testSeatBind,
    );
    defer setup.protocol_server.removeGlobal(seat_global) catch {};
    var pipe_fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.Unexpected;
    defer _ = std.c.close(pipe_fds[0]);
    defer _ = std.c.close(pipe_fds[1]);
    var log: TestKeyboardLog = .{};
    defer log.deinit();
    const logger = try setup.protocol_server.addProtocolLogger(TestKeyboardLog, &log, TestKeyboardLog.observe);
    defer setup.protocol_server.removeProtocolLogger(logger);

    const Case = struct {
        version: u32,
        expected: []const []const u8,
    };
    for ([_]Case{
        .{ .version = 3, .expected = &.{"keymap"} },
        .{ .version = 4, .expected = &.{ "keymap", "repeat_info" } },
    }) |case| {
        const managed = try wayring.server.CoreClient.create(std.testing.allocator, &setup.protocol_server, .{});
        const client = managed.client();
        const client_id = try setup.registerClient(client);
        var client_live = true;
        defer if (client_live) setup.destroyClient(managed);
        setup.probe.keyboard_resource_client = client_id;
        setup.probe.keyboard_resource_generation = capability_snapshot.keyboard.generation;
        setup.probe.keyboard_resource_snapshot = .{
            .keymap = .{ .format = 1, .fd = pipe_fds[0], .size = 8 },
            .repeat_info = .{ .rate = 25, .delay = 600 },
            .focus = null,
        };
        try testPrepareRegistry(client);
        try testBindGlobal(client, seat_global, case.version, 3);
        log.clear();
        try testGetKeyboard(client, 3, 4);
        var names_buffer: [4][]const u8 = undefined;
        try expectEventNames(case.expected, log.namesFor(client, 4, &names_buffer));
        try testSend(client, 4, 0, &core.wl_keyboard.request_messages[0], &.{});
        setup.destroyClient(managed);
        client_live = false;
    }
    setup.protocol_server.removeGlobal(seat_global) catch unreachable;
    try std.testing.expectEqual(@as(usize, 0), countPublished(&setup.protocol_server, "wl_seat"));
}

test "scanner keyboards preserve initial late-bind ordering fanout version gates and FD ownership" {
    var setup: AdapterTestSetup = undefined;
    try setup.init();
    defer setup.deinit();
    try std.testing.expectEqual(@as(usize, 0), countPublished(&setup.protocol_server, "wl_seat"));

    var capability_snapshot: SeatDelivery.CapabilitySnapshot = .{};
    _ = capability_snapshot.keyboard.setAvailable(true);
    capabilities(&setup.adapter, capability_snapshot);
    const seat_global = try setup.protocol_server.addGlobal(
        core.wl_seat,
        core.wl_seat.interface.version,
        WayringSeatAdapter,
        &setup.adapter,
        testSeatBind,
    );
    defer setup.protocol_server.removeGlobal(seat_global) catch {};

    const managed = try wayring.server.CoreClient.create(std.testing.allocator, &setup.protocol_server, .{});
    const client = managed.client();
    const client_id = try setup.registerClient(client);
    var client_live = true;
    defer if (client_live) setup.destroyClient(managed);
    var pipe_fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.Unexpected;
    defer _ = std.c.close(pipe_fds[0]);
    defer _ = std.c.close(pipe_fds[1]);

    setup.probe.keyboard_resource_client = client_id;
    setup.probe.keyboard_resource_generation = capability_snapshot.keyboard.generation;
    setup.probe.keyboard_resource_snapshot = .{
        .keymap = .{ .format = 1, .fd = pipe_fds[0], .size = 4096 },
        .repeat_info = .{ .rate = 0, .delay = 500 },
        .focus = null,
    };
    var log: TestKeyboardLog = .{};
    defer log.deinit();
    const logger = try setup.protocol_server.addProtocolLogger(TestKeyboardLog, &log, TestKeyboardLog.observe);
    defer setup.protocol_server.removeProtocolLogger(logger);

    try testPrepareRegistry(client);
    try testBindGlobal(client, testGlobal(&setup.protocol_server, "wl_compositor"), 6, 3);
    try testCreateSurface(client, 3, 4);
    const surface = setup.compositor.surfaceId(client, 4).?;
    try testBindGlobal(client, seat_global, 9, 5);
    log.clear();
    try testGetKeyboard(client, 5, 6);
    var names_buffer: [16][]const u8 = undefined;
    try expectEventNames(
        &.{ "keymap", "repeat_info" },
        log.namesFor(client, 6, &names_buffer),
    );
    const keymap_entry = log.find(client, 6, "keymap").?;
    try std.testing.expectEqual(@as(?u32, 1), keymap_entry.format);
    try std.testing.expectEqual(@as(?u32, 4096), keymap_entry.size);

    log.clear();
    keyboard(&setup.adapter, client_id, surface, .{ .enter = .{
        .serial = .{ .domain = .wayring_server, .value = 77 },
        .pressed_keys = &.{ 30, 31 },
        .modifiers = .{ .depressed = 1, .latched = 2, .locked = 4, .group = 3 },
    } });
    try expectEventNames(&.{ "enter", "modifiers" }, log.namesFor(client, 6, &names_buffer));
    const enter = log.find(client, 6, "enter").?;
    try std.testing.expectEqual(@as(?u32, 77), enter.serial);
    try std.testing.expectEqualSlices(u32, &.{ 30, 31 }, enter.keys[0..enter.key_count]);

    setup.probe.keyboard_resource_snapshot.?.focus = .{
        .surface = surface,
        .serial = .{ .domain = .wayring_server, .value = 77 },
        .pressed_keys = &.{ 30, 31 },
        .modifiers = .{ .depressed = 1, .latched = 2, .locked = 4, .group = 3 },
    };
    try testBindGlobal(client, seat_global, 10, 7);
    log.clear();
    try testGetKeyboard(client, 7, 8);
    try expectEventNames(
        &.{ "keymap", "repeat_info", "enter", "modifiers" },
        log.namesFor(client, 8, &names_buffer),
    );
    try std.testing.expectEqual(@as(usize, 0), log.namesFor(client, 6, &names_buffer).len);
    try std.testing.expectEqual(@as(?u32, 77), log.find(client, 8, "enter").?.serial);

    log.clear();
    keyboard(&setup.adapter, client_id, surface, .{ .key = .{
        .serial = .{ .domain = .wayring_server, .value = 78 },
        .time = 1,
        .key = 30,
        .state = .pressed,
    } });
    keyboard(&setup.adapter, client_id, surface, .{ .key = .{
        .serial = .{ .domain = .wayring_server, .value = 79 },
        .time = 2,
        .key = 30,
        .state = .repeated,
    } });
    keyboard(&setup.adapter, client_id, surface, .{ .modifiers = .{
        .serial = 80,
        .state = .{ .depressed = 8 },
    } });
    keyboard(&setup.adapter, client_id, surface, .{ .leave = .{ .serial = 81 } });
    try expectEventNames(
        &.{ "key", "modifiers", "leave" },
        log.namesFor(client, 6, &names_buffer),
    );
    try expectEventNames(
        &.{ "key", "key", "modifiers", "leave" },
        log.namesFor(client, 8, &names_buffer),
    );
    var repeated_count: usize = 0;
    for (log.entries.items) |entry| {
        if (entry.client == client and std.mem.eql(u8, entry.name, "key") and
            entry.state == @intFromEnum(SeatDelivery.KeyState.repeated))
        {
            repeated_count += 1;
            try std.testing.expectEqual(@as(u32, 8), entry.object_id);
            try std.testing.expectEqual(@as(?u32, 79), entry.serial);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), repeated_count);

    try testDrain(client);
    keyboardState(&setup.adapter, .{ .keymap = .{
        .format = 1,
        .fd = pipe_fds[0],
        .size = 4096,
    } });
    const first_batch = (try client.beginSend()).?;
    try std.testing.expectEqual(@as(usize, 1), first_batch.fds.len);
    const first_duplicate = first_batch.fds[0];
    try std.testing.expect(first_duplicate != pipe_fds[0]);
    try client.completeSend(first_batch.token, first_batch.bytes.len);
    try std.testing.expect(std.c.fcntl(first_duplicate, std.c.F.GETFD) < 0);
    const second_batch = (try client.beginSend()).?;
    try std.testing.expectEqual(@as(usize, 1), second_batch.fds.len);
    const second_duplicate = second_batch.fds[0];
    try std.testing.expect(second_duplicate != pipe_fds[0]);
    try std.testing.expect(second_duplicate != first_duplicate);
    try client.completeSend(second_batch.token, second_batch.bytes.len);
    try std.testing.expect(std.c.fcntl(second_duplicate, std.c.F.GETFD) < 0);
    try std.testing.expect(std.c.fcntl(pipe_fds[0], std.c.F.GETFD) >= 0);

    capability_snapshot.keyboard.available = false;
    capabilities(&setup.adapter, capability_snapshot);
    capability_snapshot.keyboard.available = true;
    capability_snapshot.keyboard.generation += 1;
    capabilities(&setup.adapter, capability_snapshot);
    log.clear();
    keyboard(&setup.adapter, client_id, surface, .{ .enter = .{
        .serial = .{ .domain = .wayring_server, .value = 82 },
        .pressed_keys = &.{},
        .modifiers = .{},
    } });
    try std.testing.expectEqual(@as(usize, 0), log.entries.items.len);

    // A queued duplicate remains transport-owned and is closed by client
    // teardown even when no send completion occurs; the canonical FD survives.
    setup.probe.keyboard_resource_generation = capability_snapshot.keyboard.generation;
    setup.probe.keyboard_resource_snapshot.?.focus = null;
    try testBindGlobal(client, seat_global, 10, 9);
    try testGetKeyboard(client, 9, 10);
    try testDrain(client);
    keyboardState(&setup.adapter, .{ .keymap = .{
        .format = 1,
        .fd = pipe_fds[0],
        .size = 4096,
    } });
    const pending = (try client.beginSend()).?;
    const pending_duplicate = pending.fds[0];
    setup.destroyClient(managed);
    client_live = false;
    try std.testing.expect(std.c.fcntl(pending_duplicate, std.c.F.GETFD) < 0);
    try std.testing.expect(std.c.fcntl(pipe_fds[0], std.c.F.GETFD) >= 0);
    setup.protocol_server.removeGlobal(seat_global) catch unreachable;
    try std.testing.expectEqual(@as(usize, 0), countPublished(&setup.protocol_server, "wl_seat"));
}

test "scanner pointer events preserve exact order version gates isolation and stale generations" {
    var setup: AdapterTestSetup = undefined;
    try setup.init();
    defer setup.deinit();
    var snapshot: SeatDelivery.CapabilitySnapshot = .{};
    _ = snapshot.pointer.setAvailable(true);
    capabilities(&setup.adapter, snapshot);
    const seat_global = try setup.protocol_server.addGlobal(
        core.wl_seat,
        core.wl_seat.interface.version,
        WayringSeatAdapter,
        &setup.adapter,
        testSeatBind,
    );
    defer setup.protocol_server.removeGlobal(seat_global) catch {};

    var log: TestEventLog = .{};
    defer log.deinit();
    const logger = try setup.protocol_server.addProtocolLogger(TestEventLog, &log, TestEventLog.observe);
    defer setup.protocol_server.removeProtocolLogger(logger);
    const Case = struct {
        version: u32,
        expected: []const []const u8,
    };
    const cases = [_]Case{
        .{ .version = 4, .expected = &.{ "enter", "motion", "button", "axis", "leave" } },
        .{ .version = 5, .expected = &.{ "enter", "motion", "button", "axis", "axis_source", "axis_stop", "axis_discrete", "frame", "leave" } },
        .{ .version = 7, .expected = &.{ "enter", "motion", "button", "axis", "axis_source", "axis_stop", "axis_discrete", "frame", "leave" } },
        .{ .version = 8, .expected = &.{ "enter", "motion", "button", "axis", "axis_source", "axis_stop", "axis_value120", "frame", "leave" } },
        .{ .version = 9, .expected = &.{ "enter", "motion", "button", "axis", "axis_source", "axis_stop", "axis_value120", "axis_relative_direction", "frame", "leave" } },
    };
    for (cases, 0..) |case, index| {
        const managed = try wayring.server.CoreClient.create(std.testing.allocator, &setup.protocol_server, .{});
        const client = managed.client();
        const client_id = try setup.registerClient(client);
        var client_live = true;
        defer if (client_live) setup.destroyClient(managed);
        try testPrepareRegistry(client);
        try testBindGlobal(client, testGlobal(&setup.protocol_server, "wl_compositor"), 6, 3);
        try testCreateSurface(client, 3, 4);
        try testBindGlobal(client, seat_global, case.version, 5);
        try testGetPointer(client, 5, 6);
        try testDrain(client);
        log.clear();
        const surface = setup.compositor.surfaceId(client, 4).?;
        pointer(&setup.adapter, client_id, surface, .{ .enter = .{
            .serial = .{ .domain = .wayring_server, .value = 41 },
            .x = 256,
            .y = 512,
        } });
        pointer(&setup.adapter, client_id, surface, .{ .motion = .{ .time = 1, .x = 384, .y = 640 } });
        pointer(&setup.adapter, client_id, surface, .{ .button = .{
            .serial = .{ .domain = .wayring_server, .value = 42 },
            .time = 2,
            .button = 272,
            .state = .pressed,
        } });
        pointer(&setup.adapter, client_id, surface, .{ .axis = .{ .time = 3, .axis = 0, .value = 256 } });
        pointer(&setup.adapter, client_id, surface, .{ .axis_source = 0 });
        pointer(&setup.adapter, client_id, surface, .{ .axis_stop = .{ .time = 4, .axis = 0 } });
        pointer(&setup.adapter, client_id, surface, .{ .axis_discrete = .{ .axis = 0, .discrete = 1 } });
        pointer(&setup.adapter, client_id, surface, .{ .axis_value120 = .{ .axis = 0, .value120 = 120 } });
        pointer(&setup.adapter, client_id, surface, .{ .axis_relative_direction = .{ .axis = 0, .direction = 1 } });
        pointer(&setup.adapter, client_id, surface, .frame);
        pointer(&setup.adapter, client_id, surface, .{ .leave = .{ .serial = 43 } });
        var names_buffer: [16][]const u8 = undefined;
        try expectEventNames(case.expected, log.namesFor(client, 6, &names_buffer));
        try std.testing.expectEqual(@as(?u32, null), setup.adapter.pointers.items[0].last_enter_serial);

        const generation = setup.adapter.pointers.items[0].generation;
        snapshot.pointer.available = false;
        capabilities(&setup.adapter, snapshot);
        log.clear();
        pointer(&setup.adapter, client_id, surface, .{ .motion = .{ .time = 5, .x = 1, .y = 2 } });
        try std.testing.expectEqual(@as(usize, 0), log.namesFor(client, 6, &names_buffer).len);
        snapshot.pointer.available = true;
        snapshot.pointer.generation += 1;
        capabilities(&setup.adapter, snapshot);
        try std.testing.expect(!snapshot.pointer.resourceActive(generation));
        log.clear();
        pointer(&setup.adapter, client_id, surface, .{ .motion = .{ .time = 6, .x = 3, .y = 4 } });
        try std.testing.expectEqual(@as(usize, 0), log.namesFor(client, 6, &names_buffer).len);

        setup.destroyClient(managed);
        client_live = false;
        snapshot.pointer.generation += 1;
        capabilities(&setup.adapter, snapshot);
        _ = index;
    }
}

test "scanner touch preserves cutoff ordering version gates batching and cancellation" {
    var setup: AdapterTestSetup = undefined;
    try setup.init();
    defer setup.deinit();
    var snapshot: SeatDelivery.CapabilitySnapshot = .{};
    _ = snapshot.touch.setAvailable(true);
    capabilities(&setup.adapter, snapshot);
    const seat_global = try setup.protocol_server.addGlobal(
        core.wl_seat,
        core.wl_seat.interface.version,
        WayringSeatAdapter,
        &setup.adapter,
        testSeatBind,
    );
    defer setup.protocol_server.removeGlobal(seat_global) catch {};

    const managed = try wayring.server.CoreClient.create(std.testing.allocator, &setup.protocol_server, .{});
    const client = managed.client();
    const client_id = try setup.registerClient(client);
    var client_live = true;
    defer if (client_live) setup.destroyClient(managed);
    var log: TestTouchLog = .{};
    defer log.deinit();
    const logger = try setup.protocol_server.addProtocolLogger(TestTouchLog, &log, TestTouchLog.observe);
    defer setup.protocol_server.removeProtocolLogger(logger);

    try testPrepareRegistry(client);
    try testBindGlobal(client, testGlobal(&setup.protocol_server, "wl_compositor"), 6, 3);
    try testCreateSurface(client, 3, 4);
    const surface = setup.compositor.surfaceId(client, 4).?;
    try testBindGlobal(client, seat_global, 5, 5);
    try testGetTouch(client, 5, 6);
    try testBindGlobal(client, seat_global, 6, 7);
    try testGetTouch(client, 7, 8);
    try std.testing.expectEqual(@as(u32, 5), setup.adapter.touches.items[0].resource.version());
    try std.testing.expectEqual(@as(u32, 6), setup.adapter.touches.items[1].resource.version());
    const down_target = touchTarget(&setup.adapter, surface).?;
    try std.testing.expectEqual(client_id, down_target.client);
    try std.testing.expectEqual(@as(SeatDelivery.ResourceGeneration, 2), down_target.max_resource_generation);

    try testDrain(client);
    log.clear();
    touch(&setup.adapter, client_id, .{ .down = .{
        .serial = .{ .domain = .wayring_server, .value = 41 },
        .time = 10,
        .surface = surface,
        .id = 3,
        .x = 320,
        .y = -128,
        .max_resource_generation = down_target.max_resource_generation,
    } });

    // This resource was materialized after down and cannot join contact 3.
    try testGetTouch(client, 7, 9);
    try std.testing.expectEqual(@as(SeatDelivery.ResourceGeneration, 3), touchTarget(&setup.adapter, surface).?.max_resource_generation);
    touch(&setup.adapter, client_id, .{ .shape = .{
        .id = 3,
        .major = 512,
        .minor = 256,
        .max_resource_generation = down_target.max_resource_generation,
    } });
    touch(&setup.adapter, client_id, .{ .orientation = .{
        .id = 3,
        .orientation = -64,
        .max_resource_generation = down_target.max_resource_generation,
    } });
    touch(&setup.adapter, client_id, .{ .motion = .{
        .time = 11,
        .id = 3,
        .x = 384,
        .y = -64,
        .max_resource_generation = down_target.max_resource_generation,
    } });
    touchFrame(&setup.adapter);
    touch(&setup.adapter, client_id, .{ .up = .{
        .serial = .{ .domain = .wayring_server, .value = 42 },
        .time = 12,
        .id = 3,
        .max_resource_generation = down_target.max_resource_generation,
    } });
    touchFrame(&setup.adapter);

    var names_buffer: [16][]const u8 = undefined;
    try expectEventNames(
        &.{ "down", "motion", "frame", "up", "frame" },
        log.namesFor(client, 6, &names_buffer),
    );
    try expectEventNames(
        &.{ "down", "shape", "orientation", "motion", "frame", "up", "frame" },
        log.namesFor(client, 8, &names_buffer),
    );
    try std.testing.expectEqual(@as(usize, 0), log.namesFor(client, 9, &names_buffer).len);
    const down = log.find(client, 8, "down").?;
    try std.testing.expectEqual(@as(?u32, 41), down.serial);
    try std.testing.expectEqual(@as(?u32, 10), down.time);
    try std.testing.expectEqual(@as(?u32, 4), down.surface);
    try std.testing.expectEqual(@as(?i32, 3), down.id);
    try std.testing.expectEqual(@as(?i32, 320), down.x);
    try std.testing.expectEqual(@as(?i32, -128), down.y);
    const motion = log.find(client, 8, "motion").?;
    try std.testing.expectEqual(@as(?u32, 11), motion.time);
    try std.testing.expectEqual(@as(?i32, 384), motion.x);
    try std.testing.expectEqual(@as(?i32, -64), motion.y);
    const shape = log.find(client, 8, "shape").?;
    try std.testing.expectEqual(@as(?i32, 512), shape.x);
    try std.testing.expectEqual(@as(?i32, 256), shape.y);
    try std.testing.expectEqual(@as(?i32, -64), log.find(client, 8, "orientation").?.x);

    log.clear();
    const cancel_target = touchTarget(&setup.adapter, surface).?;
    touch(&setup.adapter, client_id, .{ .down = .{
        .serial = .{ .domain = .wayring_server, .value = 43 },
        .time = 13,
        .surface = surface,
        .id = 4,
        .x = 0,
        .y = 0,
        .max_resource_generation = cancel_target.max_resource_generation,
    } });
    touch(&setup.adapter, client_id, .{ .cancel = .{
        .max_resource_generation = cancel_target.max_resource_generation,
    } });
    touchFrame(&setup.adapter);
    inline for (.{ 6, 8, 9 }) |object_id| {
        try expectEventNames(
            &.{ "down", "cancel" },
            log.namesFor(client, object_id, &names_buffer),
        );
    }
    for (setup.adapter.touches.items) |touch_resource|
        try std.testing.expect(!touch_resource.frame_pending);

    const stale_client: ClientRegistry.Id = .{
        .index = client_id.index,
        .generation = client_id.generation + 1,
    };
    log.clear();
    touch(&setup.adapter, stale_client, .{ .down = .{
        .serial = .{ .domain = .wayring_server, .value = 44 },
        .time = 14,
        .surface = surface,
        .id = 5,
        .x = 0,
        .y = 0,
        .max_resource_generation = cancel_target.max_resource_generation,
    } });
    try std.testing.expectEqual(@as(usize, 0), log.entries.items.len);

    snapshot.touch.available = false;
    capabilities(&setup.adapter, snapshot);
    try std.testing.expect(touchTarget(&setup.adapter, surface) == null);
    snapshot.touch.available = true;
    snapshot.touch.generation += 1;
    capabilities(&setup.adapter, snapshot);
    try std.testing.expect(touchTarget(&setup.adapter, surface) == null);

    setup.destroyClient(managed);
    client_live = false;
    setup.protocol_server.removeGlobal(seat_global) catch unreachable;
    try std.testing.expectEqual(@as(usize, 0), countPublished(&setup.protocol_server, "wl_seat"));
}

test "scanner touch cancel frames excluded completed events without crossing clients" {
    var setup: AdapterTestSetup = undefined;
    try setup.init();
    defer setup.deinit();
    var snapshot: SeatDelivery.CapabilitySnapshot = .{};
    _ = snapshot.touch.setAvailable(true);
    capabilities(&setup.adapter, snapshot);
    const seat_global = try setup.protocol_server.addGlobal(
        core.wl_seat,
        core.wl_seat.interface.version,
        WayringSeatAdapter,
        &setup.adapter,
        testSeatBind,
    );
    defer setup.protocol_server.removeGlobal(seat_global) catch {};

    const managed_a = try wayring.server.CoreClient.create(std.testing.allocator, &setup.protocol_server, .{});
    const client_a = managed_a.client();
    const client_id_a = try setup.registerClient(client_a);
    var live_a = true;
    defer if (live_a) setup.destroyClient(managed_a);
    const managed_b = try wayring.server.CoreClient.create(std.testing.allocator, &setup.protocol_server, .{});
    const client_b = managed_b.client();
    const client_id_b = try setup.registerClient(client_b);
    var live_b = true;
    defer if (live_b) setup.destroyClient(managed_b);
    var log: TestTouchLog = .{};
    defer log.deinit();
    const logger = try setup.protocol_server.addProtocolLogger(TestTouchLog, &log, TestTouchLog.observe);
    defer setup.protocol_server.removeProtocolLogger(logger);

    inline for (.{ client_a, client_b }) |client| {
        try testPrepareRegistry(client);
        try testBindGlobal(client, testGlobal(&setup.protocol_server, "wl_compositor"), 6, 3);
        try testCreateSurface(client, 3, 4);
        try testBindGlobal(client, seat_global, 6, 5);
    }
    try testGetTouch(client_a, 5, 6);
    try testGetTouch(client_b, 5, 6);
    const surface_a = setup.compositor.surfaceId(client_a, 4).?;
    const surface_b = setup.compositor.surfaceId(client_b, 4).?;
    const contact_a_target = touchTarget(&setup.adapter, surface_a).?;
    try std.testing.expectEqual(
        @as(SeatDelivery.ResourceGeneration, 1),
        contact_a_target.max_resource_generation,
    );
    const client_b_target = touchTarget(&setup.adapter, surface_b).?;
    try std.testing.expectEqual(
        @as(SeatDelivery.ResourceGeneration, 2),
        client_b_target.max_resource_generation,
    );

    try testDrain(client_a);
    try testDrain(client_b);
    log.clear();
    touch(&setup.adapter, client_id_a, .{ .down = .{
        .serial = .{ .domain = .wayring_server, .value = 51 },
        .time = 20,
        .surface = surface_a,
        .id = 1,
        .x = 0,
        .y = 0,
        .max_resource_generation = contact_a_target.max_resource_generation,
    } });

    // This second resource is too new for contact 1, but it participates in
    // the completed contact 2 batch that is still awaiting a physical frame.
    try testGetTouch(client_a, 5, 7);
    const contact_b_target = touchTarget(&setup.adapter, surface_a).?;
    try std.testing.expectEqual(
        @as(SeatDelivery.ResourceGeneration, 3),
        contact_b_target.max_resource_generation,
    );
    touch(&setup.adapter, client_id_a, .{ .down = .{
        .serial = .{ .domain = .wayring_server, .value = 52 },
        .time = 21,
        .surface = surface_a,
        .id = 2,
        .x = 64,
        .y = 128,
        .max_resource_generation = contact_b_target.max_resource_generation,
    } });
    touch(&setup.adapter, client_id_a, .{ .up = .{
        .serial = .{ .domain = .wayring_server, .value = 53 },
        .time = 22,
        .id = 2,
        .max_resource_generation = contact_b_target.max_resource_generation,
    } });
    touch(&setup.adapter, client_id_b, .{ .down = .{
        .serial = .{ .domain = .wayring_server, .value = 54 },
        .time = 23,
        .surface = surface_b,
        .id = 3,
        .x = 0,
        .y = 0,
        .max_resource_generation = client_b_target.max_resource_generation,
    } });
    touch(&setup.adapter, client_id_b, .{ .up = .{
        .serial = .{ .domain = .wayring_server, .value = 55 },
        .time = 24,
        .id = 3,
        .max_resource_generation = client_b_target.max_resource_generation,
    } });

    touch(&setup.adapter, client_id_a, .{ .cancel = .{
        .max_resource_generation = contact_a_target.max_resource_generation,
    } });

    var names_buffer: [16][]const u8 = undefined;
    try expectEventNames(
        &.{ "down", "down", "up", "cancel" },
        log.namesFor(client_a, 6, &names_buffer),
    );
    try expectEventNames(
        &.{ "down", "up", "frame" },
        log.namesFor(client_a, 7, &names_buffer),
    );
    try expectEventNames(
        &.{ "down", "up" },
        log.namesFor(client_b, 6, &names_buffer),
    );

    // The later physical frame closes only the unrelated pending client; the
    // excluded resource framed during cancel must not receive a duplicate.
    touchFrame(&setup.adapter);
    try expectEventNames(
        &.{ "down", "up", "frame" },
        log.namesFor(client_a, 7, &names_buffer),
    );
    try expectEventNames(
        &.{ "down", "up", "frame" },
        log.namesFor(client_b, 6, &names_buffer),
    );

    setup.destroyClient(managed_b);
    live_b = false;
    setup.destroyClient(managed_a);
    live_a = false;
}

test "scanner touch capability removal closes pending final up exactly once" {
    var setup: AdapterTestSetup = undefined;
    try setup.init();
    defer setup.deinit();
    var snapshot: SeatDelivery.CapabilitySnapshot = .{};
    _ = snapshot.touch.setAvailable(true);
    capabilities(&setup.adapter, snapshot);
    const seat_global = try setup.protocol_server.addGlobal(
        core.wl_seat,
        core.wl_seat.interface.version,
        WayringSeatAdapter,
        &setup.adapter,
        testSeatBind,
    );
    defer setup.protocol_server.removeGlobal(seat_global) catch {};

    const managed = try wayring.server.CoreClient.create(std.testing.allocator, &setup.protocol_server, .{});
    const client = managed.client();
    const client_id = try setup.registerClient(client);
    var client_live = true;
    defer if (client_live) setup.destroyClient(managed);
    var log: TestTouchLog = .{};
    defer log.deinit();
    const logger = try setup.protocol_server.addProtocolLogger(TestTouchLog, &log, TestTouchLog.observe);
    defer setup.protocol_server.removeProtocolLogger(logger);

    try testPrepareRegistry(client);
    try testBindGlobal(client, testGlobal(&setup.protocol_server, "wl_compositor"), 6, 3);
    try testCreateSurface(client, 3, 4);
    try testBindGlobal(client, seat_global, 6, 5);
    try testGetTouch(client, 5, 6);
    const surface = setup.compositor.surfaceId(client, 4).?;
    const target = touchTarget(&setup.adapter, surface).?;
    try testDrain(client);
    log.clear();

    touch(&setup.adapter, client_id, .{ .down = .{
        .serial = .{ .domain = .wayring_server, .value = 61 },
        .time = 30,
        .surface = surface,
        .id = 1,
        .x = 0,
        .y = 0,
        .max_resource_generation = target.max_resource_generation,
    } });
    touch(&setup.adapter, client_id, .{ .up = .{
        .serial = .{ .domain = .wayring_server, .value = 62 },
        .time = 31,
        .id = 1,
        .max_resource_generation = target.max_resource_generation,
    } });

    try std.testing.expect(snapshot.touch.setAvailable(false));
    capabilities(&setup.adapter, snapshot);
    var names_buffer: [8][]const u8 = undefined;
    try expectEventNames(
        &.{ "down", "up", "frame" },
        log.namesFor(client, 6, &names_buffer),
    );

    touchFrame(&setup.adapter);
    try std.testing.expect(snapshot.touch.setAvailable(true));
    capabilities(&setup.adapter, snapshot);
    touchFrame(&setup.adapter);
    try expectEventNames(
        &.{ "down", "up", "frame" },
        log.namesFor(client, 6, &names_buffer),
    );

    setup.destroyClient(managed);
    client_live = false;
}

test "late pointer bind joins canonical focus with enter before later delivery" {
    var setup: AdapterTestSetup = undefined;
    try setup.init();
    defer setup.deinit();
    var snapshot: SeatDelivery.CapabilitySnapshot = .{};
    _ = snapshot.pointer.setAvailable(true);
    capabilities(&setup.adapter, snapshot);
    const seat_global = try setup.protocol_server.addGlobal(
        core.wl_seat,
        core.wl_seat.interface.version,
        WayringSeatAdapter,
        &setup.adapter,
        testSeatBind,
    );
    defer setup.protocol_server.removeGlobal(seat_global) catch {};
    var log: TestEventLog = .{};
    defer log.deinit();
    const logger = try setup.protocol_server.addProtocolLogger(TestEventLog, &log, TestEventLog.observe);
    defer setup.protocol_server.removeProtocolLogger(logger);

    for ([_]u32{ 4, 5 }, 0..) |version, index| {
        const managed = try wayring.server.CoreClient.create(std.testing.allocator, &setup.protocol_server, .{});
        const client = managed.client();
        const client_id = try setup.registerClient(client);
        var client_live = true;
        defer if (client_live) setup.destroyClient(managed);
        try testPrepareRegistry(client);
        try testBindGlobal(client, testGlobal(&setup.protocol_server, "wl_compositor"), 6, 3);
        try testCreateSurface(client, 3, 4);
        try testBindGlobal(client, seat_global, version, 5);
        try testGetPointer(client, 5, 6);
        const surface = setup.compositor.surfaceId(client, 4).?;
        pointer(&setup.adapter, client_id, surface, .{ .enter = .{
            .serial = .{ .domain = .wayring_server, .value = 77 },
            .x = 256,
            .y = 512,
        } });
        setup.probe.pointer_enter_client = client_id;
        setup.probe.pointer_enter_generation = snapshot.pointer.generation;
        setup.probe.pointer_enter_snapshot = .{
            .surface = surface,
            .serial = .{ .domain = .wayring_server, .value = 77 },
            .x = 256,
            .y = 512,
        };

        log.clear();
        try testGetPointer(client, 5, 7);
        var names_buffer: [8][]const u8 = undefined;
        try std.testing.expectEqual(@as(usize, 0), log.namesFor(client, 6, &names_buffer).len);
        const expected: []const []const u8 = if (version >= 5) &.{ "enter", "frame" } else &.{"enter"};
        try expectEventNames(expected, log.namesFor(client, 7, &names_buffer));
        try std.testing.expectEqual(@as(?u32, 77), setup.adapter.pointers.items[1].last_enter_serial);

        try testSend(client, 7, 0, &core.wl_pointer.request_messages[0], &.{
            .{ .uint = 77 }, .{ .object = null }, .{ .int = 0 }, .{ .int = 0 },
        });
        try std.testing.expectEqual(index + 1, setup.probe.set_cursor_count);
        log.clear();
        pointer(&setup.adapter, client_id, surface, .{ .motion = .{ .time = 9, .x = 384, .y = 640 } });
        try expectEventNames(&.{"motion"}, log.namesFor(client, 6, &names_buffer));
        try expectEventNames(&.{"motion"}, log.namesFor(client, 7, &names_buffer));

        setup.probe.pointer_enter_snapshot = null;
        setup.probe.pointer_enter_client = null;
        setup.destroyClient(managed);
        client_live = false;
    }
}

test "set_cursor accepts only the entering resource and terminalizes role conflict locally" {
    var setup: AdapterTestSetup = undefined;
    try setup.init();
    defer setup.deinit();
    var snapshot: SeatDelivery.CapabilitySnapshot = .{};
    _ = snapshot.pointer.setAvailable(true);
    capabilities(&setup.adapter, snapshot);
    const seat_global = try setup.protocol_server.addGlobal(
        core.wl_seat,
        core.wl_seat.interface.version,
        WayringSeatAdapter,
        &setup.adapter,
        testSeatBind,
    );
    defer setup.protocol_server.removeGlobal(seat_global) catch {};
    const managed = try wayring.server.CoreClient.create(std.testing.allocator, &setup.protocol_server, .{});
    const client = managed.client();
    const client_id = try setup.registerClient(client);
    var client_live = true;
    defer if (client_live) setup.destroyClient(managed);
    try testPrepareRegistry(client);
    try testBindGlobal(client, testGlobal(&setup.protocol_server, "wl_compositor"), 6, 3);
    try testCreateSurface(client, 3, 4);
    try testBindGlobal(client, seat_global, 11, 5);
    try testGetPointer(client, 5, 6);
    try testDrain(client);
    const surface = setup.compositor.surfaceId(client, 4).?;
    pointer(&setup.adapter, client_id, surface, .{ .enter = .{
        .serial = .{ .domain = .wayring_server, .value = 71 },
        .x = 0,
        .y = 0,
    } });

    try testSend(client, 6, 0, &core.wl_pointer.request_messages[0], &.{
        .{ .uint = 70 }, .{ .object = 4 }, .{ .int = 1 }, .{ .int = 2 },
    });
    try std.testing.expectEqual(@as(usize, 0), setup.probe.set_cursor_count);
    try testSend(client, 6, 0, &core.wl_pointer.request_messages[0], &.{
        .{ .uint = 71 }, .{ .object = 4 }, .{ .int = 3 }, .{ .int = 4 },
    });
    try std.testing.expectEqual(@as(usize, 1), setup.probe.set_cursor_count);
    const request = setup.probe.last_cursor_request.?;
    try std.testing.expectEqual(client_id, request.client);
    try std.testing.expectEqual(ClientRegistry.SerialDomain.wayring_server, request.serial.domain);
    try std.testing.expectEqual(@as(u32, 71), request.serial.value);
    try std.testing.expectEqual(surface, request.surface.?);
    try std.testing.expectEqual(@as(i32, 3), request.hotspot_x);
    try std.testing.expectEqual(@as(i32, 4), request.hotspot_y);

    // With no canonical snapshot in this focused fixture, a late pointer
    // cannot borrow another resource's serial even for the same client.
    try testGetPointer(client, 5, 7);
    try testSend(client, 7, 0, &core.wl_pointer.request_messages[0], &.{
        .{ .uint = 71 }, .{ .object = 4 }, .{ .int = 0 }, .{ .int = 0 },
    });
    try std.testing.expectEqual(@as(usize, 1), setup.probe.set_cursor_count);
    try testSend(client, 6, 0, &core.wl_pointer.request_messages[0], &.{
        .{ .uint = 71 }, .{ .object = null }, .{ .int = 0 }, .{ .int = 0 },
    });
    try std.testing.expectEqual(@as(usize, 2), setup.probe.set_cursor_count);
    try std.testing.expect(setup.probe.last_cursor_request.?.surface == null);

    snapshot.pointer.available = false;
    capabilities(&setup.adapter, snapshot);
    snapshot.pointer.available = true;
    snapshot.pointer.generation += 1;
    capabilities(&setup.adapter, snapshot);
    try testSend(client, 6, 0, &core.wl_pointer.request_messages[0], &.{
        .{ .uint = 71 }, .{ .object = 4 }, .{ .int = 0 }, .{ .int = 0 },
    });
    try std.testing.expectEqual(@as(usize, 2), setup.probe.set_cursor_count);

    try testGetPointer(client, 5, 8);
    pointer(&setup.adapter, client_id, surface, .{ .enter = .{
        .serial = .{ .domain = .wayring_server, .value = 72 },
        .x = 0,
        .y = 0,
    } });
    setup.probe.set_cursor_result = .role_conflict;
    try testSend(client, 8, 0, &core.wl_pointer.request_messages[0], &.{
        .{ .uint = 72 }, .{ .object = 4 }, .{ .int = 0 }, .{ .int = 0 },
    });
    try std.testing.expectEqual(wayring.server.Fatal.Kind.protocol, client.fatal().?.kind);
    try std.testing.expect(setup.probe.retiring_count > 0);
    try std.testing.expectEqual(client_id, setup.probe.last_retiring.?);

    setup.destroyClient(managed);
    client_live = false;
}

test "touch materialization OOM and generation exhaustion isolate generated clients" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var setup: AdapterTestSetup = undefined;
    try setup.initWithAdapterAllocator(failing.allocator());
    defer setup.deinit();
    var snapshot: SeatDelivery.CapabilitySnapshot = .{};
    _ = snapshot.touch.setAvailable(true);
    capabilities(&setup.adapter, snapshot);
    const seat_global = try setup.protocol_server.addGlobal(
        core.wl_seat,
        core.wl_seat.interface.version,
        WayringSeatAdapter,
        &setup.adapter,
        testSeatBind,
    );
    defer setup.protocol_server.removeGlobal(seat_global) catch {};

    const managed_a = try wayring.server.CoreClient.create(std.testing.allocator, &setup.protocol_server, .{});
    const client_a = managed_a.client();
    const id_a = try setup.registerClient(client_a);
    var live_a = true;
    defer if (live_a) setup.destroyClient(managed_a);
    const managed_b = try wayring.server.CoreClient.create(std.testing.allocator, &setup.protocol_server, .{});
    const client_b = managed_b.client();
    const id_b = try setup.registerClient(client_b);
    var live_b = true;
    defer if (live_b) setup.destroyClient(managed_b);
    const managed_c = try wayring.server.CoreClient.create(std.testing.allocator, &setup.protocol_server, .{});
    const client_c = managed_c.client();
    const id_c = try setup.registerClient(client_c);
    var live_c = true;
    defer if (live_c) setup.destroyClient(managed_c);
    inline for (.{ client_a, client_b, client_c }) |client| {
        try testPrepareRegistry(client);
        try testBindGlobal(client, seat_global, 10, 3);
    }

    setup.probe.watched_terminal_client = client_a;
    failing.fail_index = failing.alloc_index;
    try testGetTouch(client_a, 3, 4);
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(wayring.server.Fatal.Kind.out_of_memory, client_a.fatal().?.kind);
    try std.testing.expect(setup.probe.retiring_before_fatal);
    try std.testing.expectEqual(id_a, setup.probe.last_retiring.?);
    try std.testing.expectEqual(@as(usize, 0), setup.adapter.touches.items.len);
    failing.fail_index = std.math.maxInt(usize);

    setup.adapter.next_touch_resource_generation = std.math.maxInt(SeatDelivery.ResourceGeneration);
    try testGetTouch(client_b, 3, 4);
    try std.testing.expect(client_b.fatal() == null);
    try std.testing.expectEqual(
        std.math.maxInt(SeatDelivery.ResourceGeneration),
        setup.adapter.touches.items[0].resource_generation,
    );
    try std.testing.expect(setup.adapter.next_touch_resource_generation == null);

    setup.probe.watched_terminal_client = client_c;
    setup.probe.retiring_before_fatal = false;
    try testGetTouch(client_c, 3, 4);
    try std.testing.expectEqual(wayring.server.Fatal.Kind.implementation, client_c.fatal().?.kind);
    try std.testing.expect(setup.probe.retiring_before_fatal);
    try std.testing.expectEqual(id_c, setup.probe.last_retiring.?);
    try std.testing.expectEqual(@as(usize, 1), setup.adapter.touches.items.len);
    try std.testing.expectEqual(client_b, setup.adapter.touches.items[0].client);
    try std.testing.expect(client_b.fatal() == null);
    _ = id_b;

    setup.destroyClient(managed_c);
    live_c = false;
    setup.destroyClient(managed_b);
    live_b = false;
    setup.destroyClient(managed_a);
    live_a = false;
}

test "touch event OOM and serial exhaustion retire only affected generated clients" {
    var setup: AdapterTestSetup = undefined;
    try setup.init();
    defer setup.deinit();
    var snapshot: SeatDelivery.CapabilitySnapshot = .{};
    _ = snapshot.touch.setAvailable(true);
    capabilities(&setup.adapter, snapshot);
    const seat_global = try setup.protocol_server.addGlobal(
        core.wl_seat,
        core.wl_seat.interface.version,
        WayringSeatAdapter,
        &setup.adapter,
        testSeatBind,
    );
    defer setup.protocol_server.removeGlobal(seat_global) catch {};

    var client_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const managed_a = try wayring.server.CoreClient.create(client_allocator.allocator(), &setup.protocol_server, .{});
    const client_a = managed_a.client();
    const id_a = try setup.registerClient(client_a);
    var live_a = true;
    defer if (live_a) setup.destroyClient(managed_a);
    const managed_b = try wayring.server.CoreClient.create(std.testing.allocator, &setup.protocol_server, .{});
    const client_b = managed_b.client();
    const id_b = try setup.registerClient(client_b);
    var live_b = true;
    defer if (live_b) setup.destroyClient(managed_b);
    const managed_c = try wayring.server.CoreClient.create(std.testing.allocator, &setup.protocol_server, .{});
    const client_c = managed_c.client();
    const id_c = try setup.registerClient(client_c);
    var live_c = true;
    defer if (live_c) setup.destroyClient(managed_c);

    var surfaces: [3]SurfaceRegistry.Id = undefined;
    inline for (.{
        .{ client_a, id_a },
        .{ client_b, id_b },
        .{ client_c, id_c },
    }, 0..) |entry, index| {
        try testPrepareRegistry(entry[0]);
        try testBindGlobal(entry[0], testGlobal(&setup.protocol_server, "wl_compositor"), 6, 3);
        try testCreateSurface(entry[0], 3, 4);
        surfaces[index] = setup.compositor.surfaceId(entry[0], 4).?;
        try testBindGlobal(entry[0], seat_global, 10, 5);
        try testGetTouch(entry[0], 5, 6);
        try testDrain(entry[0]);
    }

    setup.probe.watched_terminal_client = client_a;
    client_allocator.fail_index = client_allocator.alloc_index;
    touch(&setup.adapter, id_a, .{ .down = .{
        .serial = .{ .domain = .wayring_server, .value = 51 },
        .time = 1,
        .surface = surfaces[0],
        .id = 1,
        .x = 0,
        .y = 0,
        .max_resource_generation = setup.adapter.touches.items[0].resource_generation,
    } });
    var motion_count: u32 = 0;
    while (!client_allocator.has_induced_failure and motion_count < 4096) : (motion_count += 1) {
        touch(&setup.adapter, id_a, .{ .motion = .{
            .time = motion_count + 2,
            .id = 1,
            .x = @intCast(motion_count),
            .y = 0,
            .max_resource_generation = setup.adapter.touches.items[0].resource_generation,
        } });
    }
    try std.testing.expect(client_allocator.has_induced_failure);
    try std.testing.expectEqual(wayring.server.Fatal.Kind.out_of_memory, client_a.fatal().?.kind);
    try std.testing.expect(setup.probe.retiring_before_fatal);
    try std.testing.expectEqual(id_a, setup.probe.last_retiring.?);
    try std.testing.expect(client_b.fatal() == null);
    try std.testing.expect(client_c.fatal() == null);

    const target_b = touchTarget(&setup.adapter, surfaces[1]).?;
    touch(&setup.adapter, id_b, .{ .down = .{
        .serial = .{ .domain = .wayring_server, .value = 52 },
        .time = 2,
        .surface = surfaces[1],
        .id = 2,
        .x = 0,
        .y = 0,
        .max_resource_generation = target_b.max_resource_generation,
    } });
    try std.testing.expect((try client_b.beginSend()) != null);
    try std.testing.expect(client_b.fatal() == null);

    setup.probe.watched_terminal_client = client_c;
    setup.probe.retiring_before_fatal = false;
    setup.protocol_server.next_serial = null;
    try std.testing.expect(issueSerial(&setup.adapter, id_c) == null);
    try std.testing.expectEqual(wayring.server.Fatal.Kind.implementation, client_c.fatal().?.kind);
    try std.testing.expect(setup.probe.retiring_before_fatal);
    try std.testing.expectEqual(id_c, setup.probe.last_retiring.?);
    try std.testing.expect(client_b.fatal() == null);

    setup.destroyClient(managed_c);
    live_c = false;
    setup.destroyClient(managed_b);
    live_b = false;
    setup.destroyClient(managed_a);
    live_a = false;
}

test "keyboard resource materialization OOM retires only its generated client" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var setup: AdapterTestSetup = undefined;
    try setup.initWithAdapterAllocator(failing.allocator());
    defer setup.deinit();
    var capability_snapshot: SeatDelivery.CapabilitySnapshot = .{};
    _ = capability_snapshot.keyboard.setAvailable(true);
    capabilities(&setup.adapter, capability_snapshot);
    const seat_global = try setup.protocol_server.addGlobal(
        core.wl_seat,
        core.wl_seat.interface.version,
        WayringSeatAdapter,
        &setup.adapter,
        testSeatBind,
    );
    defer setup.protocol_server.removeGlobal(seat_global) catch {};

    const managed_a = try wayring.server.CoreClient.create(std.testing.allocator, &setup.protocol_server, .{});
    const client_a = managed_a.client();
    const id_a = try setup.registerClient(client_a);
    var live_a = true;
    defer if (live_a) setup.destroyClient(managed_a);
    const managed_b = try wayring.server.CoreClient.create(std.testing.allocator, &setup.protocol_server, .{});
    const client_b = managed_b.client();
    const id_b = try setup.registerClient(client_b);
    var live_b = true;
    defer if (live_b) setup.destroyClient(managed_b);
    inline for (.{ client_a, client_b }) |client| {
        try testPrepareRegistry(client);
        try testBindGlobal(client, seat_global, 10, 3);
    }

    setup.probe.watched_terminal_client = client_a;
    failing.fail_index = failing.alloc_index;
    try testGetKeyboard(client_a, 3, 4);
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(wayring.server.Fatal.Kind.out_of_memory, client_a.fatal().?.kind);
    try std.testing.expect(setup.probe.retiring_before_fatal);
    try std.testing.expectEqual(id_a, setup.probe.last_retiring.?);
    try std.testing.expectEqual(@as(usize, 0), setup.adapter.keyboards.items.len);
    failing.fail_index = std.math.maxInt(usize);

    var pipe_fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.Unexpected;
    defer _ = std.c.close(pipe_fds[0]);
    defer _ = std.c.close(pipe_fds[1]);
    setup.probe.keyboard_resource_client = id_b;
    setup.probe.keyboard_resource_generation = capability_snapshot.keyboard.generation;
    setup.probe.keyboard_resource_snapshot = .{
        .keymap = .{ .format = 1, .fd = pipe_fds[0], .size = 8 },
        .repeat_info = .{},
        .focus = null,
    };
    try testGetKeyboard(client_b, 3, 4);
    try std.testing.expect(client_b.fatal() == null);
    try std.testing.expectEqual(@as(usize, 1), setup.adapter.keyboards.items.len);
    try std.testing.expectEqual(client_b, setup.adapter.keyboards.items[0].client);

    setup.destroyClient(managed_b);
    live_b = false;
    setup.destroyClient(managed_a);
    live_a = false;
}

test "keyboard resource generation exhaustion never aliases and isolates the next client" {
    var setup: AdapterTestSetup = undefined;
    try setup.init();
    defer setup.deinit();
    var capability_snapshot: SeatDelivery.CapabilitySnapshot = .{};
    _ = capability_snapshot.keyboard.setAvailable(true);
    capabilities(&setup.adapter, capability_snapshot);
    const seat_global = try setup.protocol_server.addGlobal(
        core.wl_seat,
        core.wl_seat.interface.version,
        WayringSeatAdapter,
        &setup.adapter,
        testSeatBind,
    );
    defer setup.protocol_server.removeGlobal(seat_global) catch {};
    var pipe_fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.Unexpected;
    defer _ = std.c.close(pipe_fds[0]);
    defer _ = std.c.close(pipe_fds[1]);

    const managed_a = try wayring.server.CoreClient.create(std.testing.allocator, &setup.protocol_server, .{});
    const client_a = managed_a.client();
    const id_a = try setup.registerClient(client_a);
    var live_a = true;
    defer if (live_a) setup.destroyClient(managed_a);
    const managed_b = try wayring.server.CoreClient.create(std.testing.allocator, &setup.protocol_server, .{});
    const client_b = managed_b.client();
    const id_b = try setup.registerClient(client_b);
    var live_b = true;
    defer if (live_b) setup.destroyClient(managed_b);
    inline for (.{ client_a, client_b }) |client| {
        try testPrepareRegistry(client);
        try testBindGlobal(client, seat_global, 10, 3);
    }

    setup.adapter.next_keyboard_resource_generation = std.math.maxInt(SeatDelivery.ResourceGeneration);
    setup.probe.keyboard_resource_client = id_a;
    setup.probe.keyboard_resource_generation = capability_snapshot.keyboard.generation;
    setup.probe.keyboard_resource_snapshot = .{
        .keymap = .{ .format = 1, .fd = pipe_fds[0], .size = 8 },
        .repeat_info = .{},
        .focus = null,
    };
    try testGetKeyboard(client_a, 3, 4);
    try std.testing.expect(client_a.fatal() == null);
    try std.testing.expectEqual(
        std.math.maxInt(SeatDelivery.ResourceGeneration),
        setup.adapter.keyboards.items[0].resource_generation,
    );
    try std.testing.expect(setup.adapter.next_keyboard_resource_generation == null);

    setup.probe.watched_terminal_client = client_b;
    setup.probe.keyboard_resource_client = id_b;
    try testGetKeyboard(client_b, 3, 4);
    try std.testing.expectEqual(wayring.server.Fatal.Kind.implementation, client_b.fatal().?.kind);
    try std.testing.expect(setup.probe.retiring_before_fatal);
    try std.testing.expectEqual(id_b, setup.probe.last_retiring.?);
    try std.testing.expectEqual(@as(usize, 1), setup.adapter.keyboards.items.len);
    try std.testing.expectEqual(client_a, setup.adapter.keyboards.items[0].client);
    try std.testing.expect(client_a.fatal() == null);

    setup.destroyClient(managed_b);
    live_b = false;
    setup.destroyClient(managed_a);
    live_a = false;
}

test "keyboard keymap enqueue OOM retires one client before fatal and preserves other clients and FD" {
    var setup: AdapterTestSetup = undefined;
    try setup.init();
    defer setup.deinit();
    var capability_snapshot: SeatDelivery.CapabilitySnapshot = .{};
    _ = capability_snapshot.keyboard.setAvailable(true);
    capabilities(&setup.adapter, capability_snapshot);
    const seat_global = try setup.protocol_server.addGlobal(
        core.wl_seat,
        core.wl_seat.interface.version,
        WayringSeatAdapter,
        &setup.adapter,
        testSeatBind,
    );
    defer setup.protocol_server.removeGlobal(seat_global) catch {};
    var pipe_fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.Unexpected;
    defer _ = std.c.close(pipe_fds[0]);
    defer _ = std.c.close(pipe_fds[1]);

    var client_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const managed_a = try wayring.server.CoreClient.create(client_allocator.allocator(), &setup.protocol_server, .{});
    const client_a = managed_a.client();
    const id_a = try setup.registerClient(client_a);
    var live_a = true;
    defer if (live_a) setup.destroyClient(managed_a);
    const managed_b = try wayring.server.CoreClient.create(std.testing.allocator, &setup.protocol_server, .{});
    const client_b = managed_b.client();
    const id_b = try setup.registerClient(client_b);
    var live_b = true;
    defer if (live_b) setup.destroyClient(managed_b);

    inline for (.{
        .{ client_a, id_a },
        .{ client_b, id_b },
    }) |entry| {
        setup.probe.keyboard_resource_client = entry[1];
        setup.probe.keyboard_resource_generation = capability_snapshot.keyboard.generation;
        setup.probe.keyboard_resource_snapshot = .{
            .keymap = .{ .format = 1, .fd = pipe_fds[0], .size = 8 },
            .repeat_info = .{},
            .focus = null,
        };
        try testPrepareRegistry(entry[0]);
        try testBindGlobal(entry[0], seat_global, 10, 3);
        try testGetKeyboard(entry[0], 3, 4);
        try testDrain(entry[0]);
    }
    setup.probe.watched_terminal_client = client_a;
    client_allocator.fail_index = client_allocator.alloc_index;
    keyboardState(&setup.adapter, .{ .keymap = .{
        .format = 1,
        .fd = pipe_fds[0],
        .size = 8,
    } });

    try std.testing.expect(client_allocator.has_induced_failure);
    try std.testing.expectEqual(wayring.server.Fatal.Kind.out_of_memory, client_a.fatal().?.kind);
    try std.testing.expect(setup.probe.retiring_before_fatal);
    try std.testing.expectEqual(id_a, setup.probe.last_retiring.?);
    try std.testing.expect(client_b.fatal() == null);
    const healthy_batch = (try client_b.beginSend()).?;
    try std.testing.expectEqual(@as(usize, 1), healthy_batch.fds.len);
    const healthy_duplicate = healthy_batch.fds[0];
    try std.testing.expect(healthy_duplicate != pipe_fds[0]);
    try client_b.completeSend(healthy_batch.token, healthy_batch.bytes.len);
    try std.testing.expect(std.c.fcntl(healthy_duplicate, std.c.F.GETFD) < 0);
    try std.testing.expect(std.c.fcntl(pipe_fds[0], std.c.F.GETFD) >= 0);

    setup.destroyClient(managed_b);
    live_b = false;
    setup.destroyClient(managed_a);
    live_a = false;
}

test "event OOM and serial exhaustion terminalize only the affected generated client" {
    var setup: AdapterTestSetup = undefined;
    try setup.init();
    defer setup.deinit();
    var snapshot: SeatDelivery.CapabilitySnapshot = .{};
    _ = snapshot.pointer.setAvailable(true);
    _ = snapshot.keyboard.setAvailable(true);
    capabilities(&setup.adapter, snapshot);
    const seat_global = try setup.protocol_server.addGlobal(
        core.wl_seat,
        core.wl_seat.interface.version,
        WayringSeatAdapter,
        &setup.adapter,
        testSeatBind,
    );
    defer setup.protocol_server.removeGlobal(seat_global) catch {};

    const managed_a = try wayring.server.CoreClient.create(std.testing.allocator, &setup.protocol_server, .{});
    const client_a = managed_a.client();
    const id_a = try setup.registerClient(client_a);
    var live_a = true;
    defer if (live_a) setup.destroyClient(managed_a);
    const managed_b = try wayring.server.CoreClient.create(std.testing.allocator, &setup.protocol_server, .{});
    const client_b = managed_b.client();
    const id_b = try setup.registerClient(client_b);
    var live_b = true;
    defer if (live_b) setup.destroyClient(managed_b);
    const managed_c = try wayring.server.CoreClient.create(std.testing.allocator, &setup.protocol_server, .{});
    const client_c = managed_c.client();
    const id_c = try setup.registerClient(client_c);
    var live_c = true;
    defer if (live_c) setup.destroyClient(managed_c);

    inline for (.{ client_a, client_b, client_c }) |client| {
        try testPrepareRegistry(client);
        try testBindGlobal(client, seat_global, 11, 3);
    }
    try testGetPointer(client_a, 3, 4);
    try testGetPointer(client_b, 3, 4);
    var pipe_fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.Unexpected;
    defer _ = std.c.close(pipe_fds[0]);
    defer _ = std.c.close(pipe_fds[1]);
    setup.probe.keyboard_resource_client = id_b;
    setup.probe.keyboard_resource_generation = snapshot.keyboard.generation;
    setup.probe.keyboard_resource_snapshot = .{
        .keymap = .{ .format = 1, .fd = pipe_fds[0], .size = 8 },
        .repeat_info = .{},
        .focus = null,
    };
    try testGetKeyboard(client_b, 3, 5);
    var pointer_a: ?*PointerResource = null;
    for (setup.adapter.pointers.items) |pointer_resource| {
        if (pointer_resource.client == client_a) pointer_a = pointer_resource;
    }
    try std.testing.expect(pointer_a != null);

    eventFailure(&setup.adapter, client_a, &pointer_a.?.resource.runtime, error.OutOfMemory);
    try std.testing.expectEqual(wayring.server.Fatal.Kind.out_of_memory, client_a.fatal().?.kind);
    try std.testing.expectEqual(id_a, setup.probe.last_retiring.?);
    try std.testing.expect(client_b.fatal() == null);
    try std.testing.expect(client_c.fatal() == null);

    setup.protocol_server.next_serial = null;
    try std.testing.expect(issueSerial(&setup.adapter, id_b) == null);
    try std.testing.expectEqual(wayring.server.Fatal.Kind.implementation, client_b.fatal().?.kind);
    try std.testing.expectEqual(id_b, setup.probe.last_retiring.?);
    try std.testing.expect(client_c.fatal() == null);
    terminalize(&setup.adapter, id_c, .pointer_state_out_of_memory);
    try std.testing.expectEqual(wayring.server.Fatal.Kind.out_of_memory, client_c.fatal().?.kind);
    try std.testing.expectEqual(id_c, setup.probe.last_retiring.?);
    try std.testing.expectEqual(@as(usize, 2), setup.adapter.pointers.items.len);
    try std.testing.expectEqual(@as(usize, 1), setup.adapter.keyboards.items.len);

    setup.destroyClient(managed_c);
    live_c = false;
    setup.destroyClient(managed_b);
    live_b = false;
    setup.destroyClient(managed_a);
    live_a = false;
}

test "frame callback enqueue fatal retires canonical client before fatal becomes visible" {
    var setup: AdapterTestSetup = undefined;
    try setup.init();
    defer setup.deinit();
    var client_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const managed = try wayring.server.CoreClient.create(client_allocator.allocator(), &setup.protocol_server, .{});
    const client = managed.client();
    _ = try setup.registerClient(client);
    var client_live = true;
    defer if (client_live) setup.destroyClient(managed);
    setup.probe.watched_terminal_client = client;

    try testPrepareRegistry(client);
    try testBindGlobal(client, testGlobal(&setup.protocol_server, "wl_compositor"), 6, 3);
    try testCreateSurface(client, 3, 4);
    try testSend(client, 4, 3, &core.wl_surface.request_messages[3], &.{
        .{ .new_id = .{ .typed = 5 } },
    });
    try testSend(client, 4, 6, &core.wl_surface.request_messages[6], &.{});
    try testDrain(client);
    const surface = setup.compositor.surfaceId(client, 4).?;

    client_allocator.fail_index = client_allocator.alloc_index;
    setup.compositor.completeFrame(surface, 55);

    try std.testing.expect(client_allocator.has_induced_failure);
    try std.testing.expectEqual(wayring.server.Fatal.Kind.out_of_memory, client.fatal().?.kind);
    try std.testing.expect(setup.probe.retiring_before_fatal);
    try std.testing.expectEqual(@as(usize, 1), setup.probe.retiring_count);
    try std.testing.expect(client.lookup(5) == null);

    setup.destroyClient(managed);
    client_live = false;
}
