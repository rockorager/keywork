//! Scanner-backed transient seat creation and lifetime management.

const WayringTransientSeat = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayring = @import("wayring");
const ClientRegistry = @import("../ClientRegistry.zig");
const SeatDelivery = @import("../SeatDelivery.zig");
const SurfaceRegistry = @import("../SurfaceRegistry.zig");
const Seat = @import("seat.zig");
const WayringClients = @import("WayringClients.zig");
const WayringCompositor = @import("WayringCompositor.zig");
const WayringSeatAdapter = @import("WayringSeatAdapter.zig");

pub const Host = struct {
    context: *anyopaque,
    init_seat: *const fn (*anyopaque, *Seat, std.mem.Allocator, [:0]const u8) anyerror!void,
};

pub const SeatListener = struct {
    context: *anyopaque,
    removed: *const fn (*anyopaque, *Seat) void,
};

pub const Selection = struct {
    seat: *Seat,
    client: ClientRegistry.Id,
    entry: ?*Entry,
};

const Manager = struct {
    owner: *WayringTransientSeat,
    client: *wayring.server.Client,
    resource: protocol.ext_transient_seat_manager_v1.Resource,
};

pub const Entry = struct {
    owner: *WayringTransientSeat,
    client: *wayring.server.Client,
    resource: ?protocol.ext_transient_seat_v1.Resource,
    seat: Seat,
    adapter: WayringSeatAdapter,
    name: [:0]u8,
    active: bool,
    references: usize,
};

const TrackedClient = struct {
    client: *wayring.server.Client,
    observer: *wayring.server.Client.TerminalObserver,
};

allocator: std.mem.Allocator,
protocol_server: *wayring.server.Server,
clients: *WayringClients,
compositor: *WayringCompositor,
canonical_seat: *Seat,
canonical_adapter: *WayringSeatAdapter,
host: Host,
authorized_uid: std.os.linux.uid_t,
global: ?*const wayring.server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
entries: std.ArrayList(*Entry) = .empty,
listeners: std.ArrayList(SeatListener) = .empty,
tracked_clients: std.ArrayList(TrackedClient) = .empty,
next_name: u64 = 0,
sweeping: bool = false,

pub fn init(
    self: *WayringTransientSeat,
    allocator: std.mem.Allocator,
    protocol_server: *wayring.server.Server,
    clients: *WayringClients,
    compositor: *WayringCompositor,
    canonical_seat: *Seat,
    canonical_adapter: *WayringSeatAdapter,
    host: Host,
    authorized_uid: std.os.linux.uid_t,
) void {
    self.* = .{
        .allocator = allocator,
        .protocol_server = protocol_server,
        .clients = clients,
        .compositor = compositor,
        .canonical_seat = canonical_seat,
        .canonical_adapter = canonical_adapter,
        .host = host,
        .authorized_uid = authorized_uid,
    };
    compositor.setCursorListener(.{ .context = self, .committed = cursorCommittedFanout, .removed = cursorRemovedFanout });
}

pub fn deinit(self: *WayringTransientSeat) void {
    std.debug.assert(self.global == null and self.managers.items.len == 0 and self.entries.items.len == 0);
    std.debug.assert(self.listeners.items.len == 0 and self.tracked_clients.items.len == 0);
    self.compositor.clearCursorListener(self);
    self.tracked_clients.deinit(self.allocator);
    self.listeners.deinit(self.allocator);
    self.entries.deinit(self.allocator);
    self.managers.deinit(self.allocator);
    self.* = undefined;
}

pub fn publish(self: *WayringTransientSeat) !void {
    std.debug.assert(self.global == null);
    self.global = try self.protocol_server.addGlobalWithOptions(
        protocol.ext_transient_seat_manager_v1,
        1,
        WayringTransientSeat,
        self,
        bindManager,
        .{ .visibility = .restricted },
    );
}

pub fn unpublish(self: *WayringTransientSeat) void {
    self.protocol_server.removeGlobal(self.global orelse unreachable) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}

pub fn addSeatListener(self: *WayringTransientSeat, listener: SeatListener) !void {
    for (self.listeners.items) |existing| std.debug.assert(existing.context != listener.context);
    try self.listeners.append(self.allocator, listener);
}

pub fn removeSeatListener(self: *WayringTransientSeat, context: *anyopaque) void {
    for (self.listeners.items, 0..) |listener, index| if (listener.context == context) {
        _ = self.listeners.orderedRemove(index);
        return;
    };
    unreachable;
}

pub fn trackClient(self: *WayringTransientSeat, client: *wayring.server.Client) !void {
    for (self.tracked_clients.items) |entry| if (entry.client == client) return error.AlreadyTracked;
    try self.tracked_clients.ensureUnusedCapacity(self.allocator, 1);
    const observer = try client.addTerminalObserver(WayringTransientSeat, self, clientTerminal);
    self.tracked_clients.appendAssumeCapacity(.{ .client = client, .observer = observer });
}

fn clientTerminal(self: *WayringTransientSeat, client: *wayring.server.Client, _: *wayring.server.Client.TerminalObserver) void {
    // Terminal observers run before lifecycle teardown and registry removal.
    // Retire through each adapter using raw identity so this remains correct
    // regardless of observer ordering with WayringClients.
    for (self.entries.items) |entry| entry.adapter.retireClient(client);
}

fn untrackClient(self: *WayringTransientSeat, client: *wayring.server.Client) void {
    for (self.tracked_clients.items, 0..) |tracked, index| if (tracked.client == client) {
        wayring.server.Client.removeTerminalObserver(tracked.observer);
        _ = self.tracked_clients.swapRemove(index);
        return;
    };
}

pub fn resolveSeat(self: *WayringTransientSeat, client: *wayring.server.Client, object_id: u32) ?Selection {
    if (self.canonical_adapter.seatClientIdentity(client, object_id)) |identity|
        return .{ .seat = self.canonical_seat, .client = identity, .entry = null };
    for (self.entries.items) |entry| {
        if (!entry.active) continue;
        if (entry.adapter.seatClientIdentity(client, object_id)) |identity|
            return .{ .seat = &entry.seat, .client = identity, .entry = entry };
    }
    return null;
}

pub fn acquireSeat(self: *WayringTransientSeat, client: *wayring.server.Client, object_id: u32) ?Selection {
    const selection = self.resolveSeat(client, object_id) orelse return null;
    if (selection.entry) |entry| entry.references = std.math.add(usize, entry.references, 1) catch unreachable;
    return selection;
}

pub fn canonicalSelection(self: *WayringTransientSeat, client: *wayring.server.Client) ?Selection {
    return .{ .seat = self.canonical_seat, .client = self.clients.id(client) orelse return null, .entry = null };
}

pub fn releaseSeat(self: *WayringTransientSeat, selection: Selection) void {
    const entry = selection.entry orelse return;
    self.releaseEntry(entry);
}

pub fn releaseEntry(self: *WayringTransientSeat, entry: *Entry) void {
    std.debug.assert(entry.references > 0);
    entry.references -= 1;
    self.destroyIfUnused(entry);
}

pub fn destroyClientResources(self: *WayringTransientSeat, client: *wayring.server.Client) void {
    self.sweeping = true;
    defer {
        self.sweeping = false;
        self.collectUnused();
    }
    var index = self.entries.items.len;
    while (index > 0) {
        index -= 1;
        const entry = self.entries.items[index];
        if (entry.client == client and entry.resource != null) self.destroyEntryResource(entry);
        entry.adapter.destroyClientResources(client);
    }
    index = self.managers.items.len;
    while (index > 0) : (index -= 1) if (self.managers.items[index - 1].client == client)
        self.destroyManager(self.managers.items[index - 1]);
    self.untrackClient(client);
}

fn bindManager(client: *wayring.server.Client, id: u32, version: u32, self: *WayringTransientSeat) !void {
    if (version != 1) return error.InvalidVersion;
    if (!client.isAuthorizedDirectPeer(self.authorized_uid)) return error.AccessDenied;
    try self.managers.ensureUnusedCapacity(self.allocator, 1);
    const manager = try self.allocator.create(Manager);
    errdefer self.allocator.destroy(manager);
    manager.* = .{
        .owner = self,
        .client = client,
        .resource = .init(self.allocator, id, version, .client, client.ownerHooks()),
    };
    errdefer {
        manager.resource.destroy();
        manager.resource.deinit();
    }
    try manager.resource.setHandler(Manager, manager, managerRequest, null);
    try client.materialize(&manager.resource.runtime);
    self.managers.appendAssumeCapacity(manager);
}

fn managerRequest(_: *protocol.ext_transient_seat_manager_v1.Resource, request: protocol.ext_transient_seat_manager_v1.Request, manager: *Manager) !void {
    switch (request) {
        .create => |args| try manager.owner.createEntry(manager, args.seat),
        .destroy => manager.owner.destroyManager(manager),
    }
}

fn createEntry(self: *WayringTransientSeat, manager: *Manager, id: u32) !void {
    try self.entries.ensureUnusedCapacity(self.allocator, 1);
    const entry = try self.allocator.create(Entry);
    errdefer self.allocator.destroy(entry);
    const generation = self.next_name;
    self.next_name = std.math.add(u64, generation, 1) catch unreachable;
    const name = try std.fmt.allocPrintSentinel(self.allocator, "transient-{d}", .{generation}, 0);
    errdefer self.allocator.free(name);
    entry.* = .{
        .owner = self,
        .client = manager.client,
        .resource = null,
        .seat = undefined,
        .adapter = undefined,
        .name = name,
        .active = true,
        .references = 0,
    };
    try self.host.init_seat(self.host.context, &entry.seat, self.allocator, name);
    errdefer entry.seat.deinit();
    entry.adapter = .init(self.allocator, self.protocol_server, self.clients, self.compositor, requestSink(entry), name);
    errdefer entry.adapter.deinit();
    entry.adapter.setResourceCountListener(.{ .context = entry, .changed = resourceCountChanged });
    errdefer entry.adapter.clearResourceCountListener(entry);
    entry.seat.setDeliverySink(entry.adapter.sink());
    errdefer entry.seat.clearDeliverySink(&entry.adapter);
    try entry.adapter.publish();
    errdefer entry.adapter.unpublish();
    entry.resource = .init(self.allocator, id, manager.resource.version(), .client, manager.client.ownerHooks());
    errdefer {
        entry.resource.?.destroy();
        entry.resource.?.deinit();
        entry.resource = null;
    }
    try entry.resource.?.setHandler(Entry, entry, entryRequest, null);
    try manager.client.materialize(&entry.resource.?.runtime);
    self.entries.appendAssumeCapacity(entry);
    protocol.ext_transient_seat_v1.@"send:ready"(&entry.resource.?, entry.adapter.globalName()) catch |err|
        self.eventFailure(manager.client, &entry.resource.?.runtime, err);
}

fn entryRequest(_: *protocol.ext_transient_seat_v1.Resource, request: protocol.ext_transient_seat_v1.Request, entry: *Entry) !void {
    switch (request) {
        .destroy => entry.owner.destroyEntryResource(entry),
    }
}

fn destroyEntryResource(self: *WayringTransientSeat, entry: *Entry) void {
    if (entry.resource) |*resource| {
        entry.active = false;
        entry.adapter.unpublish();
        for (self.listeners.items) |listener| listener.removed(listener.context, &entry.seat);
        resource.destroy();
        resource.deinit();
        entry.resource = null;
        self.destroyIfUnused(entry);
    }
}

fn resourceCountChanged(context: *anyopaque, _: usize) void {
    const entry: *Entry = @ptrCast(@alignCast(context));
    entry.owner.destroyIfUnused(entry);
}

fn destroyIfUnused(self: *WayringTransientSeat, entry: *Entry) void {
    if (self.sweeping or entry.resource != null or entry.adapter.resourceCount() != 0 or entry.references != 0) return;
    entry.adapter.clearResourceCountListener(entry);
    entry.seat.clearDeliverySink(&entry.adapter);
    entry.seat.discardAuthorityGrants();
    entry.adapter.deinit();
    entry.seat.deinit();
    for (self.entries.items, 0..) |candidate, index| if (candidate == entry) {
        _ = self.entries.orderedRemove(index);
        self.allocator.free(entry.name);
        self.allocator.destroy(entry);
        return;
    };
    unreachable;
}

fn collectUnused(self: *WayringTransientSeat) void {
    var index = self.entries.items.len;
    while (index > 0) {
        index -= 1;
        self.destroyIfUnused(self.entries.items[index]);
    }
}

fn destroyManager(self: *WayringTransientSeat, manager: *Manager) void {
    for (self.managers.items, 0..) |candidate, index| if (candidate == manager) {
        _ = self.managers.swapRemove(index);
        break;
    };
    manager.resource.destroy();
    manager.resource.deinit();
    self.allocator.destroy(manager);
}

fn requestSink(entry: *Entry) SeatDelivery.RequestSink {
    return .{
        .context = entry,
        .pointer_enter_snapshot = pointerEnterSnapshot,
        .keyboard_resource_snapshot = keyboardResourceSnapshot,
        .accepts_action = acceptsAction,
        .accepts_activation = acceptsActivation,
        .activation_surface_focused = activationSurfaceFocused,
        .set_cursor = setCursor,
        .set_shape = setShape,
        .cursor_committed = cursorCommitted,
        .cursor_removed = cursorRemoved,
        .client_retiring = clientRetiring,
    };
}

fn pointerEnterSnapshot(context: *anyopaque, client: ClientRegistry.Id, generation: SeatDelivery.ResourceGeneration) ?SeatDelivery.PointerEnterSnapshot {
    const entry: *Entry = @ptrCast(@alignCast(context));
    return entry.seat.generatedPointerEnterSnapshot(client, generation);
}

fn keyboardResourceSnapshot(context: *anyopaque, client: ClientRegistry.Id, generation: SeatDelivery.ResourceGeneration) ?SeatDelivery.KeyboardResourceSnapshot {
    const entry: *Entry = @ptrCast(@alignCast(context));
    return entry.seat.generatedKeyboardResourceSnapshot(client, generation);
}

fn acceptsAction(context: *anyopaque, client: ClientRegistry.Id, serial: ClientRegistry.Serial) bool {
    const entry: *Entry = @ptrCast(@alignCast(context));
    return entry.seat.authority.acceptsAction(client, serial);
}

fn acceptsActivation(context: *anyopaque, client: ClientRegistry.Id, serial: ClientRegistry.Serial) bool {
    const entry: *Entry = @ptrCast(@alignCast(context));
    return entry.seat.authority.acceptsActivation(client, serial);
}

fn activationSurfaceFocused(context: *anyopaque, surface: SurfaceRegistry.Id) bool {
    const entry: *Entry = @ptrCast(@alignCast(context));
    return entry.seat.generatedActivationSurfaceFocused(surface);
}

fn setCursor(context: *anyopaque, request: SeatDelivery.CursorRequest) SeatDelivery.CursorRequestResult {
    const entry: *Entry = @ptrCast(@alignCast(context));
    return entry.seat.setGeneratedCursor(request);
}

fn setShape(context: *anyopaque, request: SeatDelivery.ShapeRequest) bool {
    const entry: *Entry = @ptrCast(@alignCast(context));
    return entry.seat.setGeneratedCursorShape(request);
}

fn cursorCommitted(context: *anyopaque, id: SurfaceRegistry.Id, x: i32, y: i32) void {
    const entry: *Entry = @ptrCast(@alignCast(context));
    entry.seat.generatedCursorCommitted(id, x, y);
}

fn cursorRemoved(context: *anyopaque, id: SurfaceRegistry.Id) void {
    const entry: *Entry = @ptrCast(@alignCast(context));
    entry.seat.generatedCursorRemoved(id);
}

fn cursorCommittedFanout(context: *anyopaque, id: SurfaceRegistry.Id, x: i32, y: i32) void {
    const self: *WayringTransientSeat = @ptrCast(@alignCast(context));
    self.canonical_adapter.processCursorCommitted(id, x, y);
    for (self.entries.items) |entry| entry.adapter.processCursorCommitted(id, x, y);
}

fn cursorRemovedFanout(context: *anyopaque, id: SurfaceRegistry.Id) void {
    const self: *WayringTransientSeat = @ptrCast(@alignCast(context));
    self.canonical_adapter.processCursorRemoved(id);
    for (self.entries.items) |entry| entry.adapter.processCursorRemoved(id);
}

fn clientRetiring(context: *anyopaque, client: ClientRegistry.Id) void {
    const entry: *Entry = @ptrCast(@alignCast(context));
    _ = entry.seat.retireGeneratedClient(client);
}

fn eventFailure(self: *WayringTransientSeat, client: *wayring.server.Client, resource: *wayring.server.Resource, err: anyerror) void {
    _ = self;
    if (client.fatal() != null) return;
    switch (err) {
        error.OutOfMemory, error.WriteFailed => client.postOutOfMemory(resource, "queueing transient seat event"),
        error.OutputSealed, error.ClientFatal => {},
        else => client.postImplementationError(resource, "queueing transient seat event"),
    }
}

test "transient seat descriptors and names are exact" {
    try std.testing.expectEqual(@as(u32, 1), protocol.ext_transient_seat_manager_v1.interface.version);
    try std.testing.expectEqual(@as(u32, 1), protocol.ext_transient_seat_v1.interface.version);
    try std.testing.expectEqualStrings("create", protocol.ext_transient_seat_manager_v1.request_messages[0].name);
    try std.testing.expectEqualStrings("destroy", protocol.ext_transient_seat_manager_v1.request_messages[1].name);
    try std.testing.expect(protocol.ext_transient_seat_manager_v1.request_messages[1].destructor);
    try std.testing.expectEqualStrings("ready", protocol.ext_transient_seat_v1.event_messages[0].name);
    try std.testing.expectEqualStrings("denied", protocol.ext_transient_seat_v1.event_messages[1].name);
    const first = try std.fmt.allocPrintSentinel(std.testing.allocator, "transient-{d}", .{@as(u64, 0)}, 0);
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("transient-0", first);
}
