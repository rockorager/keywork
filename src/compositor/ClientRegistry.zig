//! Frontend-neutral identity and serial-domain registry for connected clients.

const ClientRegistry = @This();

const std = @import("std");
const slot_map = @import("slot_map.zig");

pub const SerialDomain = enum {
    mature_display,
    wayring_server,
};

pub const Serial = struct {
    domain: SerialDomain,
    value: u32,
};

const Store = slot_map.SlotMap(SerialDomain, enum { compositor_client });
pub const Id = Store.Id;

pub const DisconnectListener = struct {
    context: *anyopaque,
    notify: *const fn (*anyopaque, Id) void,
};

allocator: std.mem.Allocator,
clients: Store = .{},
listeners: std.ArrayList(DisconnectListener) = .empty,

pub fn init(allocator: std.mem.Allocator) ClientRegistry {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *ClientRegistry) void {
    std.debug.assert(self.clients.len() == 0);
    std.debug.assert(self.listeners.items.len == 0);
    self.clients.deinit(self.allocator);
    self.listeners.deinit(self.allocator);
    self.* = undefined;
}

pub fn register(self: *ClientRegistry, domain: SerialDomain) error{OutOfMemory}!Id {
    return self.clients.insert(self.allocator, domain);
}

/// Removes liveness before synchronously notifying listeners with the copied ID.
/// Listeners must not add or remove registry listeners during notification.
pub fn unregister(self: *ClientRegistry, id: Id) void {
    std.debug.assert(self.clients.remove(id) != null);
    for (self.listeners.items) |listener| listener.notify(listener.context, id);
}

pub fn contains(self: *const ClientRegistry, id: Id) bool {
    return self.clients.getConst(id) != null;
}

pub fn domainOf(self: *const ClientRegistry, id: Id) ?SerialDomain {
    const domain = self.clients.getConst(id) orelse return null;
    return domain.*;
}

pub fn len(self: *const ClientRegistry) usize {
    return self.clients.len();
}

pub fn addDisconnectListener(
    self: *ClientRegistry,
    listener: DisconnectListener,
) error{OutOfMemory}!void {
    for (self.listeners.items) |existing| {
        std.debug.assert(existing.context != listener.context);
    }
    try self.listeners.append(self.allocator, listener);
}

pub fn removeDisconnectListener(self: *ClientRegistry, context: *anyopaque) void {
    for (self.listeners.items, 0..) |listener, index| {
        if (listener.context == context) {
            _ = self.listeners.swapRemove(index);
            return;
        }
    }
    unreachable;
}

test "typed identities preserve domains and reject stale slot reuse" {
    var registry = ClientRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const mature = try registry.register(.mature_display);
    const wayring = try registry.register(.wayring_server);
    try std.testing.expect(!std.meta.eql(mature, wayring));
    try std.testing.expectEqual(SerialDomain.mature_display, registry.domainOf(mature).?);
    try std.testing.expectEqual(SerialDomain.wayring_server, registry.domainOf(wayring).?);
    registry.unregister(mature);
    const reused = try registry.register(.wayring_server);
    try std.testing.expectEqual(mature.index, reused.index);
    try std.testing.expect(mature.generation != reused.generation);
    try std.testing.expect(!registry.contains(mature));
    registry.unregister(reused);
    registry.unregister(wayring);
}

test "disconnect listeners receive a copied already-dead identity once" {
    const Observer = struct {
        registry: *ClientRegistry,
        calls: usize = 0,
        dead: bool = false,
        received: ?Id = null,

        fn notify(context: *anyopaque, id: Id) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            self.dead = !self.registry.contains(id);
            self.received = id;
        }
    };
    var registry = ClientRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var observer: Observer = .{ .registry = &registry };
    try registry.addDisconnectListener(.{ .context = &observer, .notify = Observer.notify });
    const id = try registry.register(.mature_display);
    registry.unregister(id);
    try std.testing.expectEqual(@as(usize, 1), observer.calls);
    try std.testing.expect(observer.dead);
    try std.testing.expect(std.meta.eql(id, observer.received.?));
    registry.removeDisconnectListener(&observer);
}

test "serial representation is explicit and client IDs are nominal" {
    const serial: Serial = .{ .domain = .wayring_server, .value = 42 };
    try std.testing.expectEqual(SerialDomain.wayring_server, serial.domain);
    try std.testing.expectEqual(@as(u32, 42), serial.value);
    try std.testing.expect(Id != @import("SurfaceRegistry.zig").Id);
}
