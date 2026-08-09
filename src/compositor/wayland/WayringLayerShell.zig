//! Scanner-resource frontend for the canonical layer-shell policy.
//!
//! This owns protocol resources and wire serial mappings only. Geometry,
//! placement, focus, and layer state remain in the neutral and policy owners.

const WayringLayerShell = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayring = @import("wayring");
const LayerShell = @import("../LayerShell.zig");
const WayringClients = @import("WayringClients.zig");
const WayringCompositor = @import("WayringCompositor.zig");
const WayringOutput = @import("WayringOutput.zig");
const WayringXdgShell = @import("WayringXdgShell.zig");
const Policy = @import("layer_shell.zig");

const server = wayring.server;

allocator: std.mem.Allocator,
protocol_server: *server.Server,
clients: *WayringClients,
compositor: *WayringCompositor,
outputs: *WayringOutput,
xdg: *WayringXdgShell,
policy: *Policy,
core: *LayerShell,
global: ?*const server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
children: std.ArrayList(*Child) = .empty,
next_generation: ?u64 = 1,

const Manager = struct {
    owner: *WayringLayerShell,
    client: *server.Client,
    generation: u64,
    resource: protocol.zwlr_layer_shell_v1.Resource,
};

const ConfigureBridge = struct {
    const Mapping = struct { serial: u32, token: LayerShell.ConfigureToken };

    mappings: std.ArrayList(Mapping) = .empty,

    fn prepare(self: *ConfigureBridge, allocator: std.mem.Allocator) error{OutOfMemory}!void {
        try self.mappings.ensureUnusedCapacity(allocator, 1);
    }

    fn commit(self: *ConfigureBridge, serial: u32, token: LayerShell.ConfigureToken) void {
        self.mappings.appendAssumeCapacity(.{ .serial = serial, .token = token });
    }

    fn indexOf(self: *const ConfigureBridge, serial: u32) ?usize {
        for (self.mappings.items, 0..) |mapping, index|
            if (mapping.serial == serial) return index;
        return null;
    }

    fn acknowledge(self: *ConfigureBridge, index: usize) void {
        var count = index + 1;
        while (count > 0) : (count -= 1) _ = self.mappings.orderedRemove(0);
    }

    fn deinit(self: *ConfigureBridge, allocator: std.mem.Allocator) void {
        self.mappings.deinit(allocator);
    }
};

const Child = struct {
    owner: *WayringLayerShell,
    client: *server.Client,
    generation: u64,
    resource: protocol.zwlr_layer_surface_v1.Resource,
    surface: WayringCompositor.SurfaceId,
    reservation: WayringCompositor.LayerReservation,
    policy_id: Policy.Id,
    core_id: LayerShell.LayerSurfaceId,
    configure_bridge: ConfigureBridge = .{},
    role_live: bool = true,
    policy_live: bool = true,
    published: bool = false,
    closed: bool = false,
};

pub fn init(self: *WayringLayerShell, allocator: std.mem.Allocator, protocol_server: *server.Server, clients: *WayringClients, compositor: *WayringCompositor, outputs: *WayringOutput, xdg: *WayringXdgShell, policy: *Policy, core: *LayerShell) void {
    self.* = .{ .allocator = allocator, .protocol_server = protocol_server, .clients = clients, .compositor = compositor, .outputs = outputs, .xdg = xdg, .policy = policy, .core = core };
}

pub fn publish(self: *WayringLayerShell) !void {
    std.debug.assert(self.global == null);
    self.global = try self.protocol_server.addGlobal(protocol.zwlr_layer_shell_v1, 5, WayringLayerShell, self, bind);
}

pub fn unpublish(self: *WayringLayerShell) void {
    self.protocol_server.removeGlobal(self.global.?) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}

pub fn deinit(self: *WayringLayerShell) void {
    std.debug.assert(self.global == null and self.children.items.len == 0 and self.managers.items.len == 0);
    self.children.deinit(self.allocator);
    self.managers.deinit(self.allocator);
    self.* = undefined;
}

fn generation(self: *WayringLayerShell) !u64 {
    const value = self.next_generation orelse return error.GenerationExhausted;
    self.next_generation = if (value == std.math.maxInt(u64)) null else value + 1;
    return value;
}

fn bind(client: *server.Client, id: u32, version: u32, self: *WayringLayerShell) !void {
    if (version == 0 or version > 5) return error.InvalidVersion;
    try self.managers.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Manager);
    errdefer self.allocator.destroy(value);
    value.* = .{ .owner = self, .client = client, .generation = try self.generation(), .resource = .init(self.allocator, id, version, .client, client.ownerHooks()) };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Manager, value, managerRequest, null);
    try client.materialize(&value.resource.runtime);
    self.managers.appendAssumeCapacity(value);
}

fn managerRequest(resource: *protocol.zwlr_layer_shell_v1.Resource, request: protocol.zwlr_layer_shell_v1.Request, manager: *Manager) !void {
    switch (request) {
        .destroy => manager.owner.destroyManager(manager),
        .get_layer_surface => |args| manager.owner.create(manager, args.id, args.surface, args.output, args.layer, args.namespace) catch |err| switch (err) {
            error.InvalidLayer => manager.client.postProtocolError(&resource.runtime, @intCast(protocol.zwlr_layer_shell_v1.@"error".invalid_layer), "invalid layer"),
            error.Role => manager.client.postProtocolError(&resource.runtime, @intCast(protocol.zwlr_layer_shell_v1.@"error".role), "wl_surface has another role"),
            error.AlreadyConstructed => manager.client.postProtocolError(&resource.runtime, @intCast(protocol.zwlr_layer_shell_v1.@"error".already_constructed), "wl_surface already has content"),
            error.InvalidSurface, error.InvalidOutput, error.InvalidNamespace => manager.client.postImplementationError(&resource.runtime, @errorName(err)),
            error.OutOfMemory => manager.client.postOutOfMemory(&resource.runtime, "creating layer surface"),
        },
    }
}

const CreateError = error{ OutOfMemory, InvalidLayer, Role, AlreadyConstructed, InvalidSurface, InvalidOutput, InvalidNamespace };
fn create(self: *WayringLayerShell, manager: *Manager, object_id: u32, surface_object: u32, output_object: ?u32, layer_raw: u32, namespace: []const u8) CreateError!void {
    if (layer_raw > 3) return error.InvalidLayer;
    const output = if (output_object) |id| self.outputs.outputIdForResource(manager.client, id) orelse return error.InvalidOutput else self.policy.resolveDefaultOutput();
    if (!std.unicode.utf8ValidateSlice(namespace)) return error.InvalidNamespace;
    const surface = self.compositor.surfaceId(manager.client, surface_object) orelse return error.InvalidSurface;
    const client_id = self.clients.id(manager.client) orelse return error.InvalidSurface;
    const reservation = self.compositor.reserveLayerRoot(manager.client, surface) catch |err| return switch (err) {
        error.RoleConflict, error.AlreadyReserved, error.NotRoot => error.Role,
        error.AlreadyConstructed => error.AlreadyConstructed,
        error.NotLive, error.WrongClient, error.StaleReservation, error.HandlerAlreadyAttached, error.HandlerMismatch => error.InvalidSurface,
        error.GenerationExhausted => error.OutOfMemory,
    };
    errdefer self.compositor.abortLayerRoot(reservation) catch {};

    try self.children.ensureUnusedCapacity(self.allocator, 1);
    const child = try self.allocator.create(Child);
    errdefer self.allocator.destroy(child);
    child.* = .{ .owner = self, .client = manager.client, .generation = self.generation() catch return error.OutOfMemory, .resource = .init(self.allocator, object_id, manager.resource.version(), .client, manager.client.ownerHooks()), .surface = surface, .reservation = reservation, .policy_id = undefined, .core_id = undefined };
    errdefer {
        child.resource.destroy();
        child.resource.deinit();
        child.configure_bridge.deinit(self.allocator);
    }
    const registration = self.policy.registerPreparedSurface(client_id, output, namespace, @enumFromInt(layer_raw), .{ .context = child, .configure = configure, .close = close }, .{ .context = child, .surface = surface, .has_committed = hasCommitted, .out_of_memory = outOfMemory, .release_role = releaseRole }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidLayer => error.InvalidLayer,
        error.InvalidNamespace => error.InvalidNamespace,
        error.InvalidOutput => error.InvalidOutput,
        error.InvalidClient, error.InvalidSurface => error.InvalidSurface,
    };
    child.policy_id = registration.policy_id;
    child.core_id = registration.core_id;
    errdefer self.policy.destroyPreparedSurface(child.policy_id);
    self.compositor.attachLayerCommitHandler(reservation, commitHandler(child)) catch return error.Role;
    errdefer self.compositor.detachLayerCommitHandler(reservation, child) catch {};
    child.resource.setHandler(Child, child, childRequest, null) catch unreachable;
    manager.client.materialize(&child.resource.runtime) catch unreachable;
    self.compositor.publishLayerRoot(reservation) catch unreachable;
    self.children.appendAssumeCapacity(child);
    child.published = true;
}

fn childRequest(resource: *protocol.zwlr_layer_surface_v1.Resource, request: protocol.zwlr_layer_surface_v1.Request, child: *Child) !void {
    switch (request) {
        .destroy => {
            child.owner.destroyChild(child, false);
            return;
        },
        else => {},
    }
    // Output removal closes the role and destroys canonical state while the
    // protocol object remains client-owned, matching the mature frontend.
    if (!child.policy_live) return;
    const core = child.owner.core;
    switch (request) {
        .set_size => |v| try core.setSize(child.core_id, v.width, v.height),
        .set_anchor => |v| try core.setAnchorRaw(child.core_id, v.anchor),
        .set_exclusive_zone => |v| try core.setExclusiveZone(child.core_id, v.zone),
        .set_margin => |v| try core.setMargins(child.core_id, .{ .top = v.top, .right = v.right, .bottom = v.bottom, .left = v.left }),
        .set_keyboard_interactivity => |v| try core.setKeyboardRaw(child.core_id, if (resource.version() < 4 and v.keyboard_interactivity != 0) 1 else v.keyboard_interactivity),
        .set_layer => |v| try core.setLayerRaw(child.core_id, v.layer),
        .set_exclusive_edge => |v| try core.setExclusiveEdgeRaw(child.core_id, v.edge),
        .get_popup => |v| {
            const popup = child.owner.xdg.popupIdForResource(child.client, v.popup) orelse return invalidState(child, "invalid xdg_popup");
            child.owner.policy.attachPopup(child.policy_id, popup) catch return invalidState(child, "cannot attach xdg_popup");
        },
        .ack_configure => |v| ack(child, v.serial),
        .destroy => unreachable,
    }
}

fn invalidState(child: *Child, detail: []const u8) void {
    child.client.postProtocolError(&child.resource.runtime, @intCast(protocol.zwlr_layer_surface_v1.@"error".invalid_surface_state), detail);
}

fn configure(context: *anyopaque, width: u32, height: u32, token: LayerShell.ConfigureToken) error{ OutOfMemory, ConfigureSerialExhausted }!void {
    const child: *Child = @ptrCast(@alignCast(context));
    try child.configure_bridge.prepare(child.owner.allocator);
    const serial = child.owner.protocol_server.nextSerial() catch {
        child.client.postImplementationError(&child.resource.runtime, "layer configure serial exhausted");
        return error.ConfigureSerialExhausted;
    };
    protocol.zwlr_layer_surface_v1.@"send:configure"(&child.resource, serial, width, height) catch return error.OutOfMemory;
    child.configure_bridge.commit(serial, token);
}

fn ack(child: *Child, serial: u32) void {
    const index = child.configure_bridge.indexOf(serial) orelse
        return invalidState(child, "configure serial was not issued by this layer surface");
    const token = child.configure_bridge.mappings.items[index].token;
    child.owner.core.ackConfigure(child.core_id, token) catch return invalidState(child, "stale configure");
    child.configure_bridge.acknowledge(index);
    return;
}

fn close(context: *anyopaque) void {
    const child: *Child = @ptrCast(@alignCast(context));
    if (child.closed or child.resource.state() != .live) return;
    child.closed = true;
    protocol.zwlr_layer_surface_v1.@"send:closed"(&child.resource) catch child.client.postOutOfMemory(&child.resource.runtime, "queueing layer close");
}
fn hasCommitted(context: *anyopaque) bool {
    const child: *Child = @ptrCast(@alignCast(context));
    return if (child.owner.compositor.xdgContentState(child.surface)) |s| s.has_committed else false;
}
fn outOfMemory(context: *anyopaque) void {
    const child: *Child = @ptrCast(@alignCast(context));
    if (child.resource.state() == .live) child.client.postOutOfMemory(&child.resource.runtime, "preparing layer commit");
}
fn releaseRole(context: *anyopaque) void {
    const child: *Child = @ptrCast(@alignCast(context));
    child.policy_live = false;
    if (!child.role_live) return;
    child.owner.compositor.detachLayerCommitHandler(child.reservation, child) catch {};
    if (child.published)
        child.owner.compositor.releaseLayerRoot(child.reservation) catch {}
    else
        child.owner.compositor.abortLayerRoot(child.reservation) catch {};
    child.role_live = false;
}

fn commitHandler(child: *Child) WayringCompositor.LayerCommitHandler {
    return .{ .context = child, .prepare = prepareCommit, .abort_prepare = abortCommit, .validate = validateCommit, .commit_prepared = commitPrepared, .pre_unmap = preUnmap, .post_apply = finishCommit, .surface_destroyed = surfaceDestroyed };
}
fn prepareCommit(context: *anyopaque, commit: WayringCompositor.LayerDirectCommit) WayringCompositor.XdgCommitDecision {
    const child: *Child = @ptrCast(@alignCast(context));
    if (!validate(child, commit.next_size != null)) return .reject;
    return if (child.owner.policy.prepareDirectCommit(child.policy_id, commit.token, commit.next_size != null)) .accept else .reject;
}
fn abortCommit(context: *anyopaque, token: WayringCompositor.UpdateToken) void {
    const child: *Child = @ptrCast(@alignCast(context));
    child.owner.policy.abortDirectCommit(child.policy_id, token);
}
fn validateCommit(context: *anyopaque, commit: WayringCompositor.LayerDirectCommit) WayringCompositor.XdgCommitDecision {
    const child: *Child = @ptrCast(@alignCast(context));
    return if (validate(child, commit.next_size != null)) .accept else .reject;
}
fn commitPrepared(_: *anyopaque, _: WayringCompositor.UpdateToken) void {}
fn validate(child: *Child, has_buffer: bool) bool {
    child.owner.policy.validateDirectCommit(child.policy_id, has_buffer) catch |err| {
        const code: u32 = switch (err) {
            error.InvalidSize => @intCast(protocol.zwlr_layer_surface_v1.@"error".invalid_size),
            error.InvalidAnchor => @intCast(protocol.zwlr_layer_surface_v1.@"error".invalid_anchor),
            error.InvalidKeyboardInteractivity => @intCast(protocol.zwlr_layer_surface_v1.@"error".invalid_keyboard_interactivity),
            error.InvalidExclusiveEdge => @intCast(protocol.zwlr_layer_surface_v1.@"error".invalid_exclusive_edge),
            else => @intCast(protocol.zwlr_layer_surface_v1.@"error".invalid_surface_state),
        };
        child.client.postProtocolError(&child.resource.runtime, code, @errorName(err));
        return false;
    };
    return true;
}
fn preUnmap(_: *anyopaque, _: WayringCompositor.UpdateToken) void {}
fn finishCommit(context: *anyopaque, token: WayringCompositor.UpdateToken) void {
    const child: *Child = @ptrCast(@alignCast(context));
    child.owner.policy.finishDirectCommit(child.policy_id, token);
}
fn surfaceDestroyed(context: *anyopaque, _: WayringCompositor.SurfaceId) void {
    const child: *Child = @ptrCast(@alignCast(context));
    child.role_live = false;
    child.owner.destroyChild(child, true);
}

fn destroyChild(self: *WayringLayerShell, child: *Child, surface_gone: bool) void {
    if (child.role_live and !surface_gone) releaseRole(child);
    if (child.policy_live) self.policy.destroyPreparedSurface(child.policy_id);
    if (child.role_live and surface_gone) child.role_live = false;
    remove(Child, &self.children, child);
    child.configure_bridge.deinit(self.allocator);
    child.resource.destroy();
    child.resource.deinit();
    self.allocator.destroy(child);
}
fn destroyManager(self: *WayringLayerShell, manager: *Manager) void {
    remove(Manager, &self.managers, manager);
    manager.resource.destroy();
    manager.resource.deinit();
    self.allocator.destroy(manager);
}
pub fn destroyClientResources(self: *WayringLayerShell, client: *server.Client) void {
    var i = self.children.items.len;
    while (i > 0) {
        i -= 1;
        if (self.children.items[i].client == client) self.destroyChild(self.children.items[i], false);
    }
    i = self.managers.items.len;
    while (i > 0) {
        i -= 1;
        if (self.managers.items[i].client == client) self.destroyManager(self.managers.items[i]);
    }
}
fn remove(comptime T: type, list: *std.ArrayList(*T), value: *T) void {
    for (list.items, 0..) |item, i| if (item == value) {
        _ = list.swapRemove(i);
        return;
    };
    unreachable;
}

test "scanner layer-shell v5 descriptors pin protocol gates" {
    try std.testing.expectEqual(@as(u32, 5), protocol.zwlr_layer_shell_v1.interface.version);
    try std.testing.expectEqual(@as(u32, 3), protocol.zwlr_layer_shell_v1.request_messages[1].since);
    try std.testing.expectEqual(@as(u32, 2), protocol.zwlr_layer_surface_v1.request_messages[8].since);
    try std.testing.expectEqual(@as(u32, 5), protocol.zwlr_layer_surface_v1.request_messages[9].since);
    try std.testing.expectEqual(@as(i64, 2), protocol.zwlr_layer_surface_v1.keyboard_interactivity.on_demand);
}

test "configure bridge rolls back preparation and exhausts monotonically" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var bridge: ConfigureBridge = .{};
    defer bridge.deinit(std.testing.allocator);
    try std.testing.expectError(error.OutOfMemory, bridge.prepare(failing.allocator()));
    try std.testing.expectEqual(@as(usize, 0), bridge.mappings.items.len);

    try bridge.prepare(std.testing.allocator);
    const serial = std.math.maxInt(u32);
    const token: LayerShell.ConfigureToken = .{ .surface = .{ .index = 1, .generation = 2 }, .sequence = 3 };
    bridge.commit(serial, token);
    try std.testing.expectEqual(@as(?usize, 0), bridge.indexOf(serial));
    bridge.acknowledge(0);
    try std.testing.expectEqual(@as(usize, 0), bridge.mappings.items.len);
}
