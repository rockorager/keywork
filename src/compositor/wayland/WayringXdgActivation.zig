//! Resource-only xdg-activation adapter for generated clients.

const WayringXdgActivation = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayring = @import("wayring");
const SurfaceRegistry = @import("../SurfaceRegistry.zig");
const XdgActivation = @import("xdg_activation.zig");
const WayringSeatAdapter = @import("WayringSeatAdapter.zig");
const WayringXdgShell = @import("WayringXdgShell.zig");

const Manager = struct {
    owner: *WayringXdgActivation,
    client: *wayring.server.Client,
    resource: protocol.xdg_activation_v1.Resource,
};

const TokenResource = struct {
    owner: *WayringXdgActivation,
    client: *wayring.server.Client,
    resource: protocol.xdg_activation_token_v1.Resource,
    source_object_id: ?u32 = null,
    source_surface: ?SurfaceRegistry.Id = null,
    serial_set: bool = false,
    serial_valid: bool = false,
    committed: bool = false,
};

allocator: std.mem.Allocator,
protocol_server: *wayring.server.Server,
seat: *WayringSeatAdapter,
xdg: *WayringXdgShell,
activation: *XdgActivation,
global: ?*const wayring.server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
tokens: std.ArrayList(*TokenResource) = .empty,

pub fn init(
    self: *WayringXdgActivation,
    allocator: std.mem.Allocator,
    protocol_server: *wayring.server.Server,
    seat: *WayringSeatAdapter,
    xdg: *WayringXdgShell,
    activation: *XdgActivation,
) void {
    self.* = .{
        .allocator = allocator,
        .protocol_server = protocol_server,
        .seat = seat,
        .xdg = xdg,
        .activation = activation,
    };
}

pub fn publish(self: *WayringXdgActivation) !void {
    std.debug.assert(self.global == null);
    self.global = try self.protocol_server.addGlobal(
        protocol.xdg_activation_v1,
        protocol.xdg_activation_v1.interface.version,
        WayringXdgActivation,
        self,
        bind,
    );
}

pub fn unpublish(self: *WayringXdgActivation) void {
    self.protocol_server.removeGlobal(self.global.?) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}

pub fn destroyClientResources(self: *WayringXdgActivation, client: *wayring.server.Client) void {
    var i = self.tokens.items.len;
    while (i > 0) : (i -= 1) if (self.tokens.items[i - 1].client == client)
        self.destroyToken(self.tokens.items[i - 1]);
    i = self.managers.items.len;
    while (i > 0) : (i -= 1) if (self.managers.items[i - 1].client == client)
        self.destroyManager(self.managers.items[i - 1]);
}

pub fn deinit(self: *WayringXdgActivation) void {
    std.debug.assert(self.global == null and self.tokens.items.len == 0 and self.managers.items.len == 0);
    self.tokens.deinit(self.allocator);
    self.managers.deinit(self.allocator);
    self.* = undefined;
}

fn bind(client: *wayring.server.Client, id: u32, version: u32, self: *WayringXdgActivation) !void {
    try self.managers.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Manager);
    errdefer self.allocator.destroy(value);
    value.* = .{
        .owner = self,
        .client = client,
        .resource = .init(self.allocator, id, version, .client, client.ownerHooks()),
    };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Manager, value, handleManager, null);
    try client.materialize(&value.resource.runtime);
    self.managers.appendAssumeCapacity(value);
}

fn handleManager(
    _: *protocol.xdg_activation_v1.Resource,
    request: protocol.xdg_activation_v1.Request,
    value: *Manager,
) !void {
    switch (request) {
        .destroy => value.owner.destroyManager(value),
        .get_activation_token => |args| try value.owner.createToken(value, args.id),
        .activate => |args| {
            const surface = value.owner.xdg.surfaceIdentity(value.client, args.surface) orelse return;
            value.owner.activation.activateToken(args.token, surface);
        },
    }
}

fn createToken(self: *WayringXdgActivation, manager: *Manager, id: u32) !void {
    try self.tokens.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(TokenResource);
    errdefer self.allocator.destroy(value);
    value.* = .{
        .owner = self,
        .client = manager.client,
        .resource = .init(self.allocator, id, manager.resource.version(), .client, manager.client.ownerHooks()),
    };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(TokenResource, value, handleToken, null);
    try manager.client.materialize(&value.resource.runtime);
    self.tokens.appendAssumeCapacity(value);
}

fn handleToken(
    _: *protocol.xdg_activation_token_v1.Resource,
    request: protocol.xdg_activation_token_v1.Request,
    value: *TokenResource,
) !void {
    if (request == .destroy) {
        value.owner.destroyToken(value);
        return;
    }
    if (value.committed) {
        value.client.postProtocolError(
            &value.resource.runtime,
            @intCast(protocol.xdg_activation_token_v1.@"error".already_used),
            "activation token was already committed",
        );
        return;
    }
    switch (request) {
        .destroy => unreachable,
        .set_serial => |args| {
            value.serial_set = true;
            value.serial_valid = value.owner.seat.acceptsXdgActivation(
                value.client,
                args.seat,
                args.serial,
            ) != null;
        },
        .set_app_id => |args| if (!std.unicode.utf8ValidateSlice(args.app_id)) {
            value.client.postImplementationError(
                &value.resource.runtime,
                "xdg_activation_token_v1 app ID is not valid UTF-8",
            );
        },
        .set_surface => |args| {
            value.source_object_id = args.surface;
            value.source_surface = value.owner.xdg.surfaceIdentity(value.client, args.surface);
        },
        .commit => {
            value.committed = true;
            const source_valid = if (value.source_object_id) |object_id|
                value.source_surface != null and
                    std.meta.eql(
                        value.source_surface.?,
                        value.owner.xdg.surfaceIdentity(value.client, object_id) orelse return issue(value, false, false),
                    ) and value.owner.seat.activationSurfaceFocused(value.source_surface.?)
            else
                true;
            const proven = value.serial_set and value.serial_valid and source_valid;
            try issue(value, !value.serial_set or proven, proven);
        },
    }
}

fn issue(value: *TokenResource, valid: bool, proven: bool) !void {
    const token = value.owner.activation.issue(valid, proven) catch |err| {
        value.client.postImplementationError(&value.resource.runtime, @errorName(err));
        return;
    };
    protocol.xdg_activation_token_v1.@"send:done"(&value.resource, &token) catch |err| {
        value.owner.activation.revokeToken(&token);
        return err;
    };
}

fn destroyToken(self: *WayringXdgActivation, value: *TokenResource) void {
    remove(TokenResource, &self.tokens, value);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}

fn destroyManager(self: *WayringXdgActivation, value: *Manager) void {
    remove(Manager, &self.managers, value);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}

fn remove(comptime T: type, list: *std.ArrayList(*T), value: *T) void {
    for (list.items, 0..) |item, i| if (item == value) {
        _ = list.swapRemove(i);
        return;
    };
    unreachable;
}

test "generated activation descriptors preserve pinned version and error" {
    try std.testing.expectEqual(@as(u32, 1), protocol.xdg_activation_v1.interface.version);
    try std.testing.expectEqual(@as(u32, 1), protocol.xdg_activation_token_v1.interface.version);
    try std.testing.expectEqual(@as(i64, 0), protocol.xdg_activation_token_v1.@"error".already_used);
    try std.testing.expectEqualStrings("done", protocol.xdg_activation_token_v1.event_messages[0].name);
}

test "activation publication allocation failure installs no global" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    failing.fail_index = 0;
    var host: wayring.server.Server = .init(failing.allocator());
    defer host.deinit();
    var adapter: WayringXdgActivation = .{
        .allocator = std.testing.allocator,
        .protocol_server = &host,
        .seat = undefined,
        .xdg = undefined,
        .activation = undefined,
    };
    defer {
        adapter.tokens.deinit(adapter.allocator);
        adapter.managers.deinit(adapter.allocator);
    }
    try std.testing.expectError(error.OutOfMemory, adapter.publish());
    try std.testing.expect(adapter.global == null);
    try std.testing.expect(failing.has_induced_failure);
}

test "activation publishes after decoration at pinned version" {
    const WayringXdgDecoration = @import("WayringXdgDecoration.zig");

    var harness: WayringXdgShell.TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    var decoration: WayringXdgDecoration = undefined;
    decoration.init(std.testing.allocator, &harness.host, &harness.adapter, &harness.core_shell);
    try decoration.publish();
    defer {
        decoration.unpublish();
        decoration.deinit();
    }
    var adapter: WayringXdgActivation = undefined;
    adapter.init(std.testing.allocator, &harness.host, undefined, &harness.adapter, undefined);
    try adapter.publish();
    defer {
        adapter.unpublish();
        adapter.deinit();
    }

    var globals = harness.host.iterator();
    var previous: ?*const wayring.server.Server.Global = null;
    while (globals.next()) |global| {
        if (std.mem.eql(u8, global.interface().name, "xdg_activation_v1")) {
            try std.testing.expect(previous != null);
            try std.testing.expectEqualStrings("zxdg_decoration_manager_v1", previous.?.interface().name);
            try std.testing.expectEqual(protocol.xdg_activation_v1.interface.version, global.version());
            return;
        }
        previous = global;
    }
    return error.MissingActivationGlobal;
}
