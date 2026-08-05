//! Frontend-neutral authorization state derived from seat input serials.

const SeatAuthority = @This();

const std = @import("std");
const ClientRegistry = @import("ClientRegistry.zig");
const SurfaceRegistry = @import("SurfaceRegistry.zig");

pub const Order = u64;
pub const selection_capacity = 32;

const Grant = struct {
    client: ClientRegistry.Id,
    serial: ClientRegistry.Serial,
    order: Order,
};

const Press = struct {
    grant: Grant,
    button: u32,
    surface: SurfaceRegistry.Id,
};

allocator: std.mem.Allocator,
clients: *const ClientRegistry,
surfaces: *const SurfaceRegistry,
latest_action: ?Grant = null,
selections: [selection_capacity]?Grant = [_]?Grant{null} ** selection_capacity,
selection_next: usize = 0,
latest_enter: ?Grant = null,
presses: std.ArrayList(Press) = .empty,
order: Order = 0,

pub fn init(
    allocator: std.mem.Allocator,
    clients: *const ClientRegistry,
    surfaces: *const SurfaceRegistry,
) SeatAuthority {
    return .{ .allocator = allocator, .clients = clients, .surfaces = surfaces };
}

pub fn deinit(self: *SeatAuthority) void {
    std.debug.assert(self.latest_action == null);
    for (self.selections) |grant| std.debug.assert(grant == null);
    std.debug.assert(self.latest_enter == null);
    std.debug.assert(self.presses.items.len == 0);
    self.presses.deinit(self.allocator);
    self.* = undefined;
}

pub fn nextOrder(self: *SeatAuthority) Order {
    if (self.order == std.math.maxInt(Order)) unreachable;
    self.order += 1;
    return self.order;
}

fn valid(self: *const SeatAuthority, client: ClientRegistry.Id, serial: ClientRegistry.Serial) bool {
    const domain = self.clients.domainOf(client) orelse return false;
    return domain == serial.domain;
}

fn issue(self: *SeatAuthority, client: ClientRegistry.Id, serial: ClientRegistry.Serial) ?Grant {
    if (!self.valid(client, serial)) return null;
    return .{ .client = client, .serial = serial, .order = self.nextOrder() };
}

pub fn recordAction(self: *SeatAuthority, client: ClientRegistry.Id, serial: ClientRegistry.Serial) bool {
    const grant = self.issue(client, serial) orelse return false;
    self.latest_action = grant;
    self.pushSelection(grant);
    return true;
}

pub fn recordSelection(self: *SeatAuthority, client: ClientRegistry.Id, serial: ClientRegistry.Serial) bool {
    const grant = self.issue(client, serial) orelse return false;
    self.pushSelection(grant);
    return true;
}

fn pushSelection(self: *SeatAuthority, grant: Grant) void {
    self.selections[self.selection_next] = grant;
    self.selection_next = (self.selection_next + 1) % selection_capacity;
}

pub fn recordPointerEnter(self: *SeatAuthority, client: ClientRegistry.Id, serial: ClientRegistry.Serial) bool {
    self.latest_enter = self.issue(client, serial) orelse return false;
    return true;
}

pub fn clearPointerEnter(self: *SeatAuthority) void {
    self.latest_enter = null;
}

/// Returns the retained enter serial only to its exact client. This is a
/// read-only resource-materialization seam, not a new authority grant.
pub fn latestPointerEnterSerial(self: *const SeatAuthority, client: ClientRegistry.Id) ?ClientRegistry.Serial {
    const grant = self.latest_enter orelse return null;
    if (!std.meta.eql(grant.client, client) or !self.valid(client, grant.serial)) return null;
    return grant.serial;
}

/// Discards weak grants when their owning seat is permanently retired.
/// Live presses must already have ended through normal seat capability teardown.
pub fn discardGrants(self: *SeatAuthority) void {
    std.debug.assert(self.presses.items.len == 0);
    self.latest_action = null;
    for (&self.selections) |*entry| entry.* = null;
    self.latest_enter = null;
}

pub fn addPointerPress(self: *SeatAuthority, client: ClientRegistry.Id, serial: ClientRegistry.Serial, button: u32, surface: SurfaceRegistry.Id) error{OutOfMemory}!bool {
    if (!self.surfaces.contains(surface)) return false;
    const grant = self.issue(client, serial) orelse return false;
    try self.presses.append(self.allocator, .{ .grant = grant, .button = button, .surface = surface });
    return true;
}

pub fn releasePointerPress(self: *SeatAuthority, client: ClientRegistry.Id, serial: ClientRegistry.Serial, button: u32) bool {
    for (self.presses.items, 0..) |press, index| {
        if (same(press.grant, client, serial) and press.button == button) {
            _ = self.presses.swapRemove(index);
            return true;
        }
    }
    return false;
}

pub fn forgetPointerPress(self: *SeatAuthority, button: u32) bool {
    for (self.presses.items, 0..) |press, index| if (press.button == button) {
        _ = self.presses.swapRemove(index);
        return true;
    };
    return false;
}

pub fn hasPointerButton(self: *const SeatAuthority, button: u32) bool {
    for (self.presses.items) |press| if (press.button == button) return true;
    return false;
}

pub fn hasPointerButtons(self: *const SeatAuthority) bool {
    return self.presses.items.len != 0;
}

/// Drops all live pointer presses without releasing retained capacity.
pub fn clearPointerPresses(self: *SeatAuthority) void {
    self.presses.clearRetainingCapacity();
}

/// Cancels currently live presses and every weak grant issued from those
/// exact serials, preserving unrelated keyboard, touch, and selection grants.
pub fn cancelPointerPressesAndGrants(self: *SeatAuthority) void {
    for (self.presses.items) |press| {
        if (self.latest_action) |grant| {
            if (same(grant, press.grant.client, press.grant.serial)) self.latest_action = null;
        }
        for (&self.selections) |*entry| if (entry.*) |grant| {
            if (same(grant, press.grant.client, press.grant.serial)) entry.* = null;
        };
    }
    self.presses.clearRetainingCapacity();
}

pub fn hasPointerButtonForSurface(self: *const SeatAuthority, button: u32, surface: SurfaceRegistry.Id) bool {
    if (!self.surfaces.contains(surface)) return false;
    for (self.presses.items) |press| if (press.button == button and std.meta.eql(press.surface, surface)) return true;
    return false;
}

pub fn acceptsAction(self: *const SeatAuthority, client: ClientRegistry.Id, serial: ClientRegistry.Serial) bool {
    if (!self.valid(client, serial)) return false;
    return if (self.latest_action) |grant| same(grant, client, serial) else false;
}

pub fn selectionOrder(self: *const SeatAuthority, client: ClientRegistry.Id, serial: ClientRegistry.Serial) ?Order {
    if (!self.valid(client, serial)) return null;
    var newest: ?Order = null;
    for (self.selections) |entry| if (entry) |grant| {
        if (same(grant, client, serial) and (newest == null or grant.order > newest.?)) newest = grant.order;
    };
    return newest;
}

pub fn acceptsActivation(self: *const SeatAuthority, client: ClientRegistry.Id, serial: ClientRegistry.Serial) bool {
    if (self.selectionOrder(client, serial) != null) return true;
    return if (self.latest_enter) |grant| self.valid(client, serial) and same(grant, client, serial) else false;
}

pub fn acceptsPointerEnter(self: *const SeatAuthority, client: ClientRegistry.Id, serial: ClientRegistry.Serial) bool {
    if (!self.valid(client, serial)) return false;
    return if (self.latest_enter) |grant| same(grant, client, serial) else false;
}

pub fn acceptsPointerGrab(self: *const SeatAuthority, client: ClientRegistry.Id, serial: ClientRegistry.Serial, surface: SurfaceRegistry.Id) bool {
    if (!self.valid(client, serial) or !self.surfaces.contains(surface)) return false;
    for (self.presses.items) |press| {
        if (same(press.grant, client, serial) and std.meta.eql(press.surface, surface)) return true;
    }
    return false;
}

/// Purges all weak records. Returns true when a final retained press was removed.
pub fn clientDisconnected(self: *SeatAuthority, client: ClientRegistry.Id) bool {
    if (self.latest_action) |grant| {
        if (std.meta.eql(grant.client, client)) self.latest_action = null;
    }
    for (&self.selections) |*entry| {
        if (entry.*) |grant| {
            if (std.meta.eql(grant.client, client)) entry.* = null;
        }
    }
    if (self.latest_enter) |grant| {
        if (std.meta.eql(grant.client, client)) self.latest_enter = null;
    }
    const had_presses = self.presses.items.len != 0;
    var index: usize = 0;
    while (index < self.presses.items.len) {
        if (std.meta.eql(self.presses.items[index].grant.client, client)) _ = self.presses.swapRemove(index) else index += 1;
    }
    return had_presses and self.presses.items.len == 0;
}

fn same(grant: Grant, client: ClientRegistry.Id, serial: ClientRegistry.Serial) bool {
    return std.meta.eql(grant.client, client) and grant.serial.domain == serial.domain and grant.serial.value == serial.value;
}

const TestProvider = struct {
    fn renderState(_: *anyopaque) ?SurfaceRegistry.RenderState {
        return null;
    }

    fn provider(self: *TestProvider) SurfaceRegistry.Provider {
        return .{ .context = self, .render_state = renderState };
    }
};

test "selection, action, domain, capacity, and issuance order are independent" {
    var clients = ClientRegistry.init(std.testing.allocator);
    defer clients.deinit();
    var surfaces = SurfaceRegistry.init(std.testing.allocator);
    defer surfaces.deinit();
    var authority = SeatAuthority.init(std.testing.allocator, &clients, &surfaces);
    defer authority.deinit();
    const mature = try clients.register(.mature_display);
    const wayring = try clients.register(.wayring_server);
    const selection: ClientRegistry.Serial = .{ .domain = .mature_display, .value = 1 };
    const action: ClientRegistry.Serial = .{ .domain = .mature_display, .value = 2 };

    try std.testing.expect(authority.recordSelection(mature, selection));
    try std.testing.expect(!authority.acceptsAction(mature, selection));
    const selection_order = authority.selectionOrder(mature, selection).?;
    try std.testing.expect(authority.recordAction(mature, action));
    try std.testing.expect(authority.acceptsAction(mature, action));
    try std.testing.expect(authority.selectionOrder(mature, action).? > selection_order);
    try std.testing.expect(authority.selectionOrder(mature, selection) != null);
    const external_order = authority.nextOrder();
    try std.testing.expect(external_order > authority.selectionOrder(mature, action).?);
    try std.testing.expect(authority.recordSelection(mature, selection));
    try std.testing.expect(authority.selectionOrder(mature, selection).? > external_order);
    try std.testing.expect(!authority.recordAction(mature, .{ .domain = .wayring_server, .value = 2 }));
    try std.testing.expect(authority.recordSelection(wayring, .{ .domain = .wayring_server, .value = 42 }));
    try std.testing.expect(authority.recordSelection(mature, .{ .domain = .mature_display, .value = 42 }));
    try std.testing.expect(authority.selectionOrder(wayring, .{ .domain = .wayring_server, .value = 42 }).? < authority.selectionOrder(mature, .{ .domain = .mature_display, .value = 42 }).?);
    try std.testing.expect(authority.selectionOrder(mature, .{ .domain = .wayring_server, .value = 42 }) == null);

    for (100..100 + selection_capacity) |value| {
        try std.testing.expect(authority.recordSelection(mature, .{ .domain = .mature_display, .value = @intCast(value) }));
    }
    try std.testing.expect(authority.selectionOrder(mature, selection) == null);
    try std.testing.expect(authority.selectionOrder(mature, .{ .domain = .mature_display, .value = 100 }) != null);
    clients.unregister(mature);
    _ = authority.clientDisconnected(mature);
    clients.unregister(wayring);
    _ = authority.clientDisconnected(wayring);
}

test "activation accepts selection or latest enter and disconnect purges stale reuse" {
    var clients = ClientRegistry.init(std.testing.allocator);
    defer clients.deinit();
    var surfaces = SurfaceRegistry.init(std.testing.allocator);
    defer surfaces.deinit();
    var authority = SeatAuthority.init(std.testing.allocator, &clients, &surfaces);
    defer authority.deinit();
    const client = try clients.register(.mature_display);
    const selected: ClientRegistry.Serial = .{ .domain = .mature_display, .value = 7 };
    const entered: ClientRegistry.Serial = .{ .domain = .mature_display, .value = 8 };
    try std.testing.expect(authority.recordSelection(client, selected));
    try std.testing.expect(authority.recordPointerEnter(client, entered));
    try std.testing.expect(authority.acceptsActivation(client, selected));
    try std.testing.expect(authority.acceptsActivation(client, entered));
    authority.clearPointerEnter();
    try std.testing.expect(!authority.acceptsActivation(client, entered));
    try std.testing.expect(authority.recordAction(client, entered));
    clients.unregister(client);
    _ = authority.clientDisconnected(client);
    const replacement = try clients.register(.mature_display);
    try std.testing.expect(!authority.acceptsAction(replacement, entered));
    try std.testing.expect(authority.selectionOrder(replacement, selected) == null);
    clients.unregister(replacement);
}

test "retiring an authority discards weak grants for a still-live client" {
    var clients = ClientRegistry.init(std.testing.allocator);
    defer clients.deinit();
    var surfaces = SurfaceRegistry.init(std.testing.allocator);
    defer surfaces.deinit();
    var authority = SeatAuthority.init(std.testing.allocator, &clients, &surfaces);

    const client = try clients.register(.mature_display);
    const serial: ClientRegistry.Serial = .{ .domain = .mature_display, .value = 7 };
    try std.testing.expect(authority.recordAction(client, serial));
    try std.testing.expect(authority.recordPointerEnter(client, serial));
    authority.discardGrants();
    try std.testing.expect(!authority.acceptsAction(client, serial));
    try std.testing.expect(authority.selectionOrder(client, serial) == null);
    try std.testing.expect(!authority.acceptsActivation(client, serial));
    authority.deinit();
    clients.unregister(client);
}

test "pointer grants require exact live client serial button and canonical surface" {
    var clients = ClientRegistry.init(std.testing.allocator);
    defer clients.deinit();
    var surfaces = SurfaceRegistry.init(std.testing.allocator);
    defer surfaces.deinit();
    var authority = SeatAuthority.init(std.testing.allocator, &clients, &surfaces);
    defer authority.deinit();
    const client = try clients.register(.wayring_server);
    const other = try clients.register(.wayring_server);
    var first_provider: TestProvider = .{};
    var second_provider: TestProvider = .{};
    const first = try surfaces.add(first_provider.provider());
    const removed = try surfaces.add(second_provider.provider());
    surfaces.remove(removed);
    const current = try surfaces.add(second_provider.provider());
    const serial: ClientRegistry.Serial = .{ .domain = .wayring_server, .value = 42 };

    try std.testing.expect(try authority.addPointerPress(client, serial, 1, first));
    try std.testing.expect(try authority.addPointerPress(client, serial, 2, current));
    try std.testing.expect(authority.hasPointerButtons());
    try std.testing.expect(authority.hasPointerButtonForSurface(1, first));
    try std.testing.expect(!authority.hasPointerButtonForSurface(2, removed));
    try std.testing.expect(authority.acceptsPointerGrab(client, serial, first));
    try std.testing.expect(!authority.acceptsPointerGrab(other, serial, first));
    try std.testing.expect(authority.acceptsPointerGrab(client, serial, current));
    try std.testing.expect(!authority.acceptsPointerGrab(
        client,
        .{ .domain = .mature_display, .value = serial.value },
        current,
    ));
    try std.testing.expect(authority.releasePointerPress(client, serial, 1));
    try std.testing.expect(!authority.hasPointerButton(1));
    try std.testing.expect(authority.forgetPointerPress(2));
    try std.testing.expect(!authority.hasPointerButtons());
    try std.testing.expect(try authority.addPointerPress(client, serial, 3, first));
    const unrelated: ClientRegistry.Serial = .{ .domain = .wayring_server, .value = 43 };
    try std.testing.expect(authority.recordSelection(client, unrelated));
    try std.testing.expect(authority.recordAction(client, serial));
    authority.cancelPointerPressesAndGrants();
    try std.testing.expect(!authority.hasPointerButtons());
    try std.testing.expect(!authority.acceptsAction(client, serial));
    try std.testing.expect(authority.selectionOrder(client, serial) == null);
    try std.testing.expect(authority.selectionOrder(client, unrelated) != null);
    clients.unregister(client);
    try std.testing.expect(!authority.clientDisconnected(client));
    clients.unregister(other);
    surfaces.remove(first);
    surfaces.remove(current);
}
