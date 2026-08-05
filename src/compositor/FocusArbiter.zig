//! Canonical cross-frontend keyboard-focus ownership.
//!
//! The arbiter stores only generational compositor identities. Frontends keep
//! protocol resources and resolve endpoints synchronously when later delivery
//! is implemented. Mature seat focus is a delivery mirror of this selection,
//! not a second canonical owner.

const FocusArbiter = @This();

const std = @import("std");
const ClientRegistry = @import("ClientRegistry.zig");
const SurfaceRegistry = @import("SurfaceRegistry.zig");

pub const Frontend = enum {
    mature,
    generated,
};

pub const Target = struct {
    frontend: Frontend,
    root: SurfaceRegistry.Id,
    client: ClientRegistry.Id,
};

clients: *ClientRegistry,
surfaces: *SurfaceRegistry,
target_value: ?Target = null,
generated_mature_fallback: ?SurfaceRegistry.Id = null,

pub fn init(
    self: *FocusArbiter,
    clients: *ClientRegistry,
    surfaces: *SurfaceRegistry,
) error{OutOfMemory}!void {
    self.* = .{
        .clients = clients,
        .surfaces = surfaces,
    };
    try clients.addDisconnectListener(.{
        .context = self,
        .notify = clientDisconnected,
    });
}

pub fn deinit(self: *FocusArbiter) void {
    self.clients.removeDisconnectListener(self);
    self.* = undefined;
}

pub fn target(self: *const FocusArbiter) ?Target {
    const value = self.target_value orelse return null;
    return if (self.targetLive(value)) value else null;
}

/// Replaces any generated owner with the mature canonical target. Null clears
/// canonical focus. The supplied client must own the endpoint synchronously;
/// the arbiter validates only neutral liveness and frontend domain.
pub fn focusMature(
    self: *FocusArbiter,
    root: ?SurfaceRegistry.Id,
    client: ?ClientRegistry.Id,
) bool {
    std.debug.assert((root == null) == (client == null));
    const next: ?Target = if (root) |surface| .{
        .frontend = .mature,
        .root = surface,
        .client = client.?,
    } else null;
    if (next) |value| {
        if (!self.targetLive(value)) return false;
    }
    const changed = !std.meta.eql(self.target_value, next);
    self.target_value = next;
    self.generated_mature_fallback = null;
    return changed;
}

/// Selects one generated compound root while remembering the mature policy
/// target it displaced. A later mature policy change invalidates this
/// selection even if no pointer or touch callback observed that change.
pub fn focusGenerated(
    self: *FocusArbiter,
    root: SurfaceRegistry.Id,
    client: ClientRegistry.Id,
    mature_fallback: ?SurfaceRegistry.Id,
) bool {
    const next: Target = .{
        .frontend = .generated,
        .root = root,
        .client = client,
    };
    if (!self.targetLive(next)) return false;
    const changed = !std.meta.eql(self.target_value, next);
    self.target_value = next;
    self.generated_mature_fallback = mature_fallback;
    return changed;
}

/// Returns a still-authoritative generated target. A changed mature fallback,
/// stale generation, or dead endpoint synchronously releases it.
pub fn retainGenerated(
    self: *FocusArbiter,
    mature_fallback: ?SurfaceRegistry.Id,
) ?Target {
    const value = self.target_value orelse return null;
    if (value.frontend != .generated) return null;
    if (!self.targetLive(value) or
        !optionalIdEqual(self.generated_mature_fallback, mature_fallback))
    {
        self.clear();
        return null;
    }
    return value;
}

/// Repairs a generated root after one applied topology mutation. The expected
/// old generation prevents an unrelated or reused target from being changed.
pub fn repairGenerated(
    self: *FocusArbiter,
    expected: SurfaceRegistry.Id,
    root: SurfaceRegistry.Id,
    client: ClientRegistry.Id,
) bool {
    const current = self.target_value orelse return false;
    if (current.frontend != .generated or !idEqual(current.root, expected)) return false;
    const next: Target = .{
        .frontend = .generated,
        .root = root,
        .client = client,
    };
    if (!self.targetLive(next)) {
        self.clear();
        return true;
    }
    if (std.meta.eql(current, next)) return false;
    self.target_value = next;
    return true;
}

pub fn clearGenerated(self: *FocusArbiter) bool {
    const current = self.target_value orelse return false;
    if (current.frontend != .generated) return false;
    self.clear();
    return true;
}

pub fn surfaceUnavailable(self: *FocusArbiter, surface: SurfaceRegistry.Id) bool {
    const current = self.target_value orelse return false;
    if (!idEqual(current.root, surface)) return false;
    self.clear();
    return true;
}

/// Synchronously clears a target whose frontend client has terminalized but
/// has not yet reached registry destruction.
pub fn clientUnavailable(self: *FocusArbiter, client: ClientRegistry.Id) bool {
    const current = self.target_value orelse return false;
    if (!std.meta.eql(current.client, client)) return false;
    self.clear();
    return true;
}

fn clear(self: *FocusArbiter) void {
    self.target_value = null;
    self.generated_mature_fallback = null;
}

fn targetLive(self: *const FocusArbiter, value: Target) bool {
    if (!self.surfaces.contains(value.root)) return false;
    const expected_domain: ClientRegistry.SerialDomain = switch (value.frontend) {
        .mature => .mature_display,
        .generated => .wayring_server,
    };
    return self.clients.domainOf(value.client) == expected_domain;
}

fn clientDisconnected(context: *anyopaque, client: ClientRegistry.Id) void {
    const self: *FocusArbiter = @ptrCast(@alignCast(context));
    _ = self.clientUnavailable(client);
}

fn idEqual(first: SurfaceRegistry.Id, second: SurfaceRegistry.Id) bool {
    return first.index == second.index and first.generation == second.generation;
}

fn optionalIdEqual(first: ?SurfaceRegistry.Id, second: ?SurfaceRegistry.Id) bool {
    if (first == null or second == null) return first == null and second == null;
    return idEqual(first.?, second.?);
}

const TestProvider = struct {
    pixel: u32 = 0,

    fn provider(self: *TestProvider) SurfaceRegistry.Provider {
        return .{ .context = self, .render_state = renderState };
    }

    fn renderState(context: *anyopaque) ?SurfaceRegistry.RenderState {
        const self: *TestProvider = @ptrCast(@alignCast(context));
        return .{
            .buffer = .{
                .size = .{ .width = 1, .height = 1 },
                .stride_pixels = 1,
                .pixels = @as([*]u32, @ptrCast(&self.pixel))[0..1],
            },
            .logical_size = .{ .width = 1, .height = 1 },
        };
    }
};

test "mature generated mature transitions keep one canonical owner" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var clients = ClientRegistry.init(failing.allocator());
    defer clients.deinit();
    var surfaces = SurfaceRegistry.init(failing.allocator());
    defer surfaces.deinit();
    var first_provider: TestProvider = .{};
    var generated_provider: TestProvider = .{};
    var second_provider: TestProvider = .{};
    const first = try surfaces.add(first_provider.provider());
    defer surfaces.remove(first);
    const generated = try surfaces.add(generated_provider.provider());
    defer surfaces.remove(generated);
    const second = try surfaces.add(second_provider.provider());
    defer surfaces.remove(second);
    const first_client = try clients.register(.mature_display);
    defer clients.unregister(first_client);
    const generated_client = try clients.register(.wayring_server);
    defer clients.unregister(generated_client);
    const second_client = try clients.register(.mature_display);
    defer clients.unregister(second_client);
    var arbiter: FocusArbiter = undefined;
    try arbiter.init(&clients, &surfaces);
    defer arbiter.deinit();

    try std.testing.expect(arbiter.focusMature(first, first_client));
    try std.testing.expectEqual(Frontend.mature, arbiter.target().?.frontend);
    try std.testing.expect(arbiter.focusGenerated(generated, generated_client, first));
    try std.testing.expectEqual(Frontend.generated, arbiter.retainGenerated(first).?.frontend);
    try std.testing.expect(arbiter.retainGenerated(second) == null);
    try std.testing.expect(arbiter.focusMature(second, second_client));
    try std.testing.expectEqual(second, arbiter.target().?.root);

    // Every steady-state transition above remains valid when the next backing
    // allocation is forced to fail: arbitration performs no allocation.
    failing.fail_index = failing.alloc_index;
    try std.testing.expect(arbiter.focusGenerated(generated, generated_client, second));
    try std.testing.expect(arbiter.clearGenerated());
    try std.testing.expect(!failing.has_induced_failure);
}

test "surface and client generations synchronously retire generated focus" {
    var clients = ClientRegistry.init(std.testing.allocator);
    defer clients.deinit();
    var surfaces = SurfaceRegistry.init(std.testing.allocator);
    defer surfaces.deinit();
    var stale_provider: TestProvider = .{};
    var current_provider: TestProvider = .{};
    const stale_surface = try surfaces.add(stale_provider.provider());
    const stale_client = try clients.register(.wayring_server);
    var arbiter: FocusArbiter = undefined;
    try arbiter.init(&clients, &surfaces);
    defer arbiter.deinit();

    try std.testing.expect(arbiter.focusGenerated(stale_surface, stale_client, null));
    clients.unregister(stale_client);
    try std.testing.expect(arbiter.target() == null);
    const current_client = try clients.register(.wayring_server);
    try std.testing.expectEqual(stale_client.index, current_client.index);
    try std.testing.expect(stale_client.generation != current_client.generation);
    try std.testing.expect(!arbiter.focusGenerated(stale_surface, stale_client, null));

    surfaces.remove(stale_surface);
    const current_surface = try surfaces.add(current_provider.provider());
    try std.testing.expectEqual(stale_surface.index, current_surface.index);
    try std.testing.expect(stale_surface.generation != current_surface.generation);
    try std.testing.expect(!arbiter.focusGenerated(stale_surface, current_client, null));
    try std.testing.expect(arbiter.focusGenerated(current_surface, current_client, null));
    try std.testing.expect(arbiter.clientUnavailable(current_client));
    try std.testing.expect(arbiter.target() == null);
    try std.testing.expect(arbiter.focusGenerated(current_surface, current_client, null));
    try std.testing.expect(arbiter.surfaceUnavailable(current_surface));
    try std.testing.expect(arbiter.target() == null);

    surfaces.remove(current_surface);
    clients.unregister(current_client);
}
