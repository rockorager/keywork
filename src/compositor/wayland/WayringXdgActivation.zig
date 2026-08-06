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
    try self.installManager(client, id, version, .registry_bind);
}

/// Narrow direct installer for resource fixtures that do not route through
/// wl_registry. Production and end-to-end acceptance use bind.
pub fn installDirectForTest(
    self: *WayringXdgActivation,
    client: *wayring.server.Client,
    id: u32,
    version: u32,
) !void {
    try self.installManager(client, id, version, .client_initial);
}

const ManagerInstall = enum { registry_bind, client_initial };

fn installManager(
    self: *WayringXdgActivation,
    client: *wayring.server.Client,
    id: u32,
    version: u32,
    install: ManagerInstall,
) !void {
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
    switch (install) {
        .registry_bind => try client.materialize(&value.resource.runtime),
        .client_initial => try client.installClientInitial(id, &value.resource.runtime),
    }
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

fn initTestActivation(activation: *XdgActivation) !void {
    activation.allocator = std.testing.allocator;
    activation.io = std.testing.io;
    activation.tokens = .empty;
    activation.activation_listener = null;

    // Keep issue() off its first-token timer path.  The timer belongs to the
    // mature Wayland server and is deliberately not part of this adapter test.
    const sentinel = try std.testing.allocator.dupe(u8, "sentinel");
    try activation.tokens.put(std.testing.allocator, sentinel, .{
        .expires_at = std.math.maxInt(i96),
        .proven_interaction = false,
    });
}

fn deinitTestActivation(activation: *XdgActivation) void {
    var iterator = activation.tokens.iterator();
    while (iterator.next()) |entry| std.testing.allocator.free(entry.key_ptr.*);
    activation.tokens.deinit(std.testing.allocator);
}

fn drainActivationToken(client: *wayring.server.Client) !?[XdgActivation.token_character_count]u8 {
    const batch = (try client.beginSend()) orelse return null;
    defer client.completeSend(batch.token, batch.bytes.len) catch {};
    if (batch.bytes.len < 12) return error.TruncatedEvent;
    const length = std.mem.readInt(u32, batch.bytes[8..12], .native);
    if (length != XdgActivation.token_character_count + 1 or batch.bytes.len < 12 + length)
        return error.InvalidTokenEvent;
    var token: [XdgActivation.token_character_count]u8 = undefined;
    @memcpy(&token, batch.bytes[12..][0..XdgActivation.token_character_count]);
    return token;
}

test "activation manager and token allocation failures roll back ownership" {
    inline for (.{ false, true }) |fail_token| {
        var harness: WayringXdgShell.TestHarness = undefined;
        try harness.init();
        defer harness.deinit();
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var adapter: WayringXdgActivation = undefined;
        adapter.init(failing.allocator(), &harness.host, undefined, &harness.adapter, undefined);
        try adapter.publish();
        defer {
            adapter.destroyClientResources(harness.client());
            adapter.unpublish();
            adapter.deinit();
        }
        try harness.createSurface();
        if (fail_token) try harness.bindGlobal("xdg_activation_v1", 8, 1);

        failing.fail_index = failing.alloc_index;
        if (fail_token) {
            harness.send(8, 1, &protocol.xdg_activation_v1.request_messages[1], &.{
                .{ .new_id = .{ .typed = 9 } },
            }) catch {};
            try std.testing.expectEqual(@as(usize, 0), adapter.tokens.items.len);
            try std.testing.expect(harness.client().lookup(9) == null);
        } else {
            harness.bindGlobal("xdg_activation_v1", 8, 1) catch {};
            try std.testing.expectEqual(@as(usize, 0), adapter.managers.items.len);
            try std.testing.expect(harness.client().lookup(8) == null);
        }
    }
}

test "token destruction brackets commit without revoking delivered token" {
    var harness: WayringXdgShell.TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    var activation: XdgActivation = undefined;
    try initTestActivation(&activation);
    defer deinitTestActivation(&activation);
    var adapter: WayringXdgActivation = undefined;
    adapter.init(std.testing.allocator, &harness.host, undefined, &harness.adapter, &activation);
    try adapter.publish();
    defer {
        adapter.destroyClientResources(harness.client());
        adapter.unpublish();
        adapter.deinit();
    }
    try harness.createSurface();
    try adapter.installDirectForTest(harness.client(), 5, 1);

    try harness.send(5, 1, &protocol.xdg_activation_v1.request_messages[1], &.{
        .{ .new_id = .{ .typed = 6 } },
    });
    try harness.send(6, 4, &protocol.xdg_activation_token_v1.request_messages[4], &.{});
    try std.testing.expectEqual(@as(usize, 0), adapter.tokens.items.len);
    try std.testing.expectEqual(@as(usize, 1), activation.tokens.count());
    while (try harness.client().beginSend()) |batch|
        try harness.client().completeSend(batch.token, batch.bytes.len);

    try harness.send(5, 1, &protocol.xdg_activation_v1.request_messages[1], &.{
        .{ .new_id = .{ .typed = 7 } },
    });
    try handleToken(&adapter.tokens.items[0].resource, .commit, adapter.tokens.items[0]);
    const token = (try drainActivationToken(harness.client())).?;
    try std.testing.expect(activation.tokens.contains(&token));
    try handleToken(&adapter.tokens.items[0].resource, .destroy, adapter.tokens.items[0]);
    try std.testing.expect(activation.tokens.contains(&token));
}

test "stale and reused source identity cannot prove a token" {
    var harness: WayringXdgShell.TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    var activation: XdgActivation = undefined;
    try initTestActivation(&activation);
    defer deinitTestActivation(&activation);
    var adapter: WayringXdgActivation = undefined;
    adapter.init(std.testing.allocator, &harness.host, undefined, &harness.adapter, &activation);
    try adapter.publish();
    defer {
        adapter.destroyClientResources(harness.client());
        adapter.unpublish();
        adapter.deinit();
    }
    try harness.createSurface();
    try harness.installManager(1);
    try harness.createToplevel();
    try harness.bindGlobal("xdg_activation_v1", 8, 1);
    try harness.send(8, 1, &protocol.xdg_activation_v1.request_messages[1], &.{.{ .new_id = .{ .typed = 9 } }});
    try harness.send(9, 2, &protocol.xdg_activation_token_v1.request_messages[2], &.{.{ .object = 4 }});
    const old = adapter.tokens.items[0].source_surface.?;
    try harness.destroyToplevel();
    try harness.send(6, 0, &protocol.xdg_surface.request_messages[0], &.{});
    try harness.send(4, 0, &protocol.wl_surface.request_messages[0], &.{});
    while (try harness.client().beginSend()) |batch|
        try harness.client().completeSend(batch.token, batch.bytes.len);
    try harness.send(3, 0, &protocol.wl_compositor.request_messages[0], &.{.{ .new_id = .{ .typed = 4 } }});
    const current = harness.adapter.surfaceIdentity(harness.client(), 4).?;
    try std.testing.expectEqual(old.index, current.index);
    try std.testing.expect(old.generation != current.generation);
    try std.testing.expect(!std.meta.eql(old, current));
    try handleToken(&adapter.tokens.items[0].resource, .commit, adapter.tokens.items[0]);
    const token = (try drainActivationToken(harness.client())).?;
    const Capture = struct {
        called: bool = false,
        proven: bool = true,

        fn requested(context: *anyopaque, _: SurfaceRegistry.Id, proven: bool) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.called = true;
            self.proven = proven;
        }
    };
    var capture: Capture = .{};
    activation.activation_listener = .{ .context = &capture, .requested = Capture.requested };
    activation.activateToken(&token, current);
    try std.testing.expect(capture.called);
    try std.testing.expect(!capture.proven);
    try std.testing.expectEqual(@as(usize, 1), activation.tokens.count());
}
