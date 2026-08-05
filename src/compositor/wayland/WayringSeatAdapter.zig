//! Unpublished generated wl_seat/wl_pointer adapter.
//!
//! The seat is deliberately available only through `bind`: production does
//! not install a global. Canonical seat policy calls the resource-free sink;
//! this type owns only protocol resources and per-resource generations.

const WayringSeatAdapter = @This();

const std = @import("std");
const core = @import("wayring-core-protocol");
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
snapshot: SeatDelivery.CapabilitySnapshot = .{},
seats: std.ArrayList(*SeatResource) = .empty,
pointers: std.ArrayList(*PointerResource) = .empty,
terminal_clients: std.ArrayList(TerminalClient) = .empty,
next_pointer_resource_generation: ?SeatDelivery.ResourceGeneration = 1,

const TerminalClient = struct {
    client: *wayring.server.Client,
    observer: *wayring.server.Client.TerminalObserver,
};

const SeatResource = struct {
    resource: core.wl_seat.Resource,
    client: *wayring.server.Client,
    adapter: *WayringSeatAdapter,
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
    std.debug.assert(self.seats.items.len == 0 and self.pointers.items.len == 0 and self.terminal_clients.items.len == 0);
    self.seats.deinit(self.allocator);
    self.pointers.deinit(self.allocator);
    self.terminal_clients.deinit(self.allocator);
    self.* = undefined;
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

/// Direct typed bind seam. This intentionally is not registered as a global.
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
    var i = self.pointers.items.len;
    while (i > 0) {
        i -= 1;
        if (self.pointers.items[i].client == client) destroyPointer(self.pointers.items[i]);
    }
    i = self.seats.items.len;
    while (i > 0) {
        i -= 1;
        if (self.seats.items[i].client == client) destroySeat(self.seats.items[i]);
    }
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
        .release => destroySeat(seat),
        // Wave 3 deliberately does not claim either implementation. A typed
        // new_id must never be left as a successful, unmaterialized request.
        .get_keyboard => missingCapability(seat, "generated keyboard is unavailable"),
        .get_touch => missingCapability(seat, "generated touch is unavailable"),
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
fn destroyPointer(pointer_resource: *PointerResource) void {
    const self = pointer_resource.adapter;
    for (self.pointers.items, 0..) |item, i| if (item == pointer_resource) {
        _ = self.pointers.orderedRemove(i);
        pointer_resource.resource.destroy();
        pointer_resource.resource.deinit();
        self.allocator.destroy(pointer_resource);
        return;
    };
}

fn capabilityBits(snapshot: SeatDelivery.CapabilitySnapshot) u32 {
    // Keyboard and touch resources are deliberately deferred to later waves;
    // advertising them here would make their missing-capability errors false.
    return if (snapshot.pointer.available) 1 else 0;
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
    for (self.pointers.items) |pointer_resource| {
        if (pointer_resource.client != client) continue;
        self.retireClient(client);
        client.postOutOfMemory(&pointer_resource.resource.runtime, "storing generated pointer state");
        return;
    }
    for (self.seats.items) |seat| {
        if (seat.client != client) continue;
        self.retireClient(client);
        client.postOutOfMemory(&seat.resource.runtime, "storing generated pointer state");
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
    for (self.pointers.items) |pointer_resource| {
        if (pointer_resource.client != client) continue;
        client.postImplementationError(&pointer_resource.resource.runtime, "generated seat serial exhausted");
        return;
    }
    for (self.seats.items) |seat| {
        if (seat.client != client) continue;
        client.postImplementationError(&seat.resource.runtime, "generated seat serial exhausted");
        return;
    }
    // A live generated client cannot receive seat events without having had a
    // seat/pointer resource. If teardown raced the lookup, there is nothing
    // left to deliver or terminalize through this adapter.
}

fn touchTarget(_: *anyopaque, _: SurfaceRegistry.Id) ?SeatDelivery.TouchTarget {
    return null;
}

fn capabilities(context: *anyopaque, snapshot: SeatDelivery.CapabilitySnapshot) void {
    const self: *WayringSeatAdapter = @ptrCast(@alignCast(context));
    self.snapshot = snapshot;
    if (!snapshot.pointer.available) {
        for (self.pointers.items) |pointer_resource| {
            pointer_resource.last_enter_serial = null;
            pointer_resource.frame_pending = false;
        }
    }
    for (self.seats.items) |seat| sendCapabilities(seat) catch |err| self.eventFailure(seat.client, &seat.resource.runtime, err);
}
fn keyboardState(_: *anyopaque, _: SeatDelivery.KeyboardStateEvent) void {}
fn keyboard(
    _: *anyopaque,
    _: ClientRegistry.Id,
    _: SurfaceRegistry.Id,
    _: SeatDelivery.KeyboardEvent,
) void {}
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

fn touch(_: *anyopaque, _: ClientRegistry.Id, _: SeatDelivery.TouchEvent) void {}

fn retireClient(self: *WayringSeatAdapter, client: *wayring.server.Client) void {
    const client_id = self.clients.id(client) orelse return;
    self.request_sink.client_retiring(self.request_sink.context, client_id);
}

test "capability bits and generations gate generated pointers" {
    var snapshot: SeatDelivery.CapabilitySnapshot = .{};
    try std.testing.expectEqual(@as(u32, 0), capabilityBits(snapshot));
    try std.testing.expect(snapshot.pointer.setAvailable(true));
    const first = snapshot.pointer.generation;
    try std.testing.expectEqual(@as(u32, 1), capabilityBits(snapshot));
    try std.testing.expect(snapshot.pointer.resourceActive(first));
    try std.testing.expect(snapshot.pointer.setAvailable(false));
    try std.testing.expect(!snapshot.pointer.resourceActive(first));
    try std.testing.expect(snapshot.pointer.setAvailable(true));
    try std.testing.expect(snapshot.pointer.generation > first);
    try std.testing.expect(!snapshot.pointer.resourceActive(first));

    _ = snapshot.keyboard.setAvailable(true);
    _ = snapshot.touch.setAvailable(true);
    try std.testing.expectEqual(@as(u32, 1), capabilityBits(snapshot));
}

const TestRequestProbe = struct {
    pointer_enter_snapshot: ?SeatDelivery.PointerEnterSnapshot = null,
    pointer_enter_client: ?ClientRegistry.Id = null,
    pointer_enter_generation: SeatDelivery.ResourceGeneration = 0,
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
            .set_cursor = setCursor,
            .cursor_committed = recordCursorCommitted,
            .cursor_removed = recordCursorRemoved,
            .client_retiring = recordClientRetiring,
        };
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

const AdapterTestSetup = struct {
    client_registry: ClientRegistry,
    surface_registry: SurfaceRegistry,
    protocol_server: wayring.server.Server,
    clients: WayringClients,
    compositor: WayringCompositor,
    probe: TestRequestProbe,
    adapter: WayringSeatAdapter,

    fn init(self: *AdapterTestSetup) !void {
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
            std.testing.allocator,
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

test "scanner seat bind negotiates exactly stays unpublished and releases resources" {
    var setup: AdapterTestSetup = undefined;
    try setup.init();
    defer setup.deinit();
    try std.testing.expectEqual(@as(usize, 0), countPublished(&setup.protocol_server, "wl_seat"));

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
    _ = try setup.registerClient(client);
    var client_live = true;
    defer if (client_live) setup.destroyClient(managed);

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
    try testSend(client, 4, 1, &core.wl_pointer.request_messages[1], &.{});
    try std.testing.expectEqual(@as(usize, 0), setup.adapter.pointers.items.len);
    try std.testing.expect(client.lookup(4) == null);
    try testSend(client, 3, 3, &core.wl_seat.request_messages[3], &.{});
    try std.testing.expectEqual(@as(usize, 0), setup.adapter.seats.items.len);
    try std.testing.expect(client.lookup(3) == null);

    setup.protocol_server.removeGlobal(seat_global) catch unreachable;
    try std.testing.expectEqual(@as(usize, 0), countPublished(&setup.protocol_server, "wl_seat"));
    setup.destroyClient(managed);
    client_live = false;
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

test "event OOM and serial exhaustion terminalize only the affected generated client" {
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
