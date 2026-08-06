//! Scanner-backed stable viewporter resources and request translation.

const WayringViewporter = @This();

const std = @import("std");
const core = @import("wayring-protocol");
const wayring = @import("wayring");
const SurfaceRegistry = @import("../SurfaceRegistry.zig");
const WayringCompositor = @import("WayringCompositor.zig");

const server = wayring.server;
const wire = wayring.wire;

const Manager = struct {
    owner: *WayringViewporter,
    client: *server.Client,
    resource: core.wp_viewporter.Resource,
};

const Viewport = struct {
    owner: *WayringViewporter,
    client: *server.Client,
    resource: core.wp_viewport.Resource,
    surface: ?WayringCompositor.SurfaceId,
};

allocator: std.mem.Allocator,
protocol_server: *server.Server,
compositor: *WayringCompositor,
global: ?*const server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
viewports: std.ArrayList(*Viewport) = .empty,

pub fn init(self: *WayringViewporter, allocator: std.mem.Allocator, protocol_server: *server.Server, compositor: *WayringCompositor) void {
    self.* = .{ .allocator = allocator, .protocol_server = protocol_server, .compositor = compositor };
}

pub fn publish(self: *WayringViewporter) !void {
    std.debug.assert(self.global == null);
    self.global = try self.protocol_server.addGlobal(
        core.wp_viewporter,
        core.wp_viewporter.interface.version,
        WayringViewporter,
        self,
        bind,
    );
}

pub fn unpublish(self: *WayringViewporter) void {
    self.protocol_server.removeGlobal(self.global.?) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}

pub fn destroyClientResources(self: *WayringViewporter, client: *server.Client) void {
    var i = self.viewports.items.len;
    while (i > 0) {
        i -= 1;
        if (self.viewports.items[i].client == client) self.destroyViewport(self.viewports.items[i]);
    }
    i = self.managers.items.len;
    while (i > 0) {
        i -= 1;
        if (self.managers.items[i].client == client) self.destroyManager(self.managers.items[i]);
    }
}

pub fn deinit(self: *WayringViewporter) void {
    std.debug.assert(self.global == null and self.viewports.items.len == 0 and self.managers.items.len == 0);
    self.viewports.deinit(self.allocator);
    self.managers.deinit(self.allocator);
    self.* = undefined;
}

fn bind(client: *server.Client, id: u32, version: u32, self: *WayringViewporter) !void {
    try self.managers.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Manager);
    errdefer self.allocator.destroy(value);
    value.* = .{ .owner = self, .client = client, .resource = .init(self.allocator, id, version, .client, client.ownerHooks()) };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Manager, value, handleManager, null);
    try client.materialize(&value.resource.runtime);
    self.managers.appendAssumeCapacity(value);
}

fn handleManager(resource: *core.wp_viewporter.Resource, request: core.wp_viewporter.Request, value: *Manager) !void {
    switch (request) {
        .destroy => value.owner.destroyManager(value),
        .get_viewport => |args| try value.owner.getViewport(value, args.id, args.surface),
    }
    _ = resource;
}

fn getViewport(self: *WayringViewporter, manager: *Manager, id: u32, surface_object: u32) !void {
    try self.viewports.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Viewport);
    errdefer self.allocator.destroy(value);
    value.* = .{
        .owner = self,
        .client = manager.client,
        .resource = .init(
            self.allocator,
            id,
            core.wp_viewport.interface.version,
            .client,
            manager.client.ownerHooks(),
        ),
        .surface = null,
    };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    const result = self.compositor.attachViewport(manager.client, surface_object, .{
        .context = value,
        .post_error = postCommitError,
        .surface_destroyed = surfaceDestroyed,
    });
    switch (result) {
        .attached => |surface| value.surface = surface,
        .viewport_exists => {
            self.allocator.destroy(value);
            manager.client.postProtocolError(&manager.resource.runtime, @intCast(core.wp_viewporter.@"error".viewport_exists), "wl_surface already has a viewport");
            return;
        },
        .not_live, .wrong_client => {
            self.allocator.destroy(value);
            manager.client.postImplementationError(&manager.resource.runtime, "surface is not an exact live same-client Wayring wl_surface");
            return;
        },
    }
    errdefer self.compositor.detachViewport(value.surface.?, value);
    try value.resource.setHandler(Viewport, value, handleViewport, null);
    try manager.client.materialize(&value.resource.runtime);
    self.viewports.appendAssumeCapacity(value);
}

fn handleViewport(_: *core.wp_viewport.Resource, request: core.wp_viewport.Request, value: *Viewport) !void {
    switch (request) {
        .destroy => return value.owner.destroyViewport(value),
        else => {},
    }
    const surface = value.surface orelse return value.client.postProtocolError(&value.resource.runtime, @intCast(core.wp_viewport.@"error".no_surface), "viewport surface no longer exists");
    switch (request) {
        .destroy => unreachable,
        .set_source => |args| {
            const source = parseSource(args.x, args.y, args.width, args.height) catch
                return value.client.postProtocolError(&value.resource.runtime, @intCast(core.wp_viewport.@"error".bad_value), "invalid source rectangle");
            if (!value.owner.compositor.setViewportSource(surface, value, source)) {
                surfaceDestroyed(value);
                return value.client.postProtocolError(&value.resource.runtime, @intCast(core.wp_viewport.@"error".no_surface), "viewport surface no longer exists");
            }
        },
        .set_destination => |args| {
            const destination = parseDestination(args.width, args.height) catch
                return value.client.postProtocolError(&value.resource.runtime, @intCast(core.wp_viewport.@"error".bad_value), "invalid destination size");
            if (!value.owner.compositor.setViewportDestination(surface, value, destination)) {
                surfaceDestroyed(value);
                return value.client.postProtocolError(&value.resource.runtime, @intCast(core.wp_viewport.@"error".no_surface), "viewport surface no longer exists");
            }
        },
    }
}

const ParseError = error{BadValue};

fn parseSource(x: i32, y: i32, width: i32, height: i32) ParseError!?WayringCompositor.ViewportSource {
    const fixed_negative_one = -256;
    if (x == fixed_negative_one and y == fixed_negative_one and
        width == fixed_negative_one and height == fixed_negative_one) return null;
    if (x < 0 or y < 0 or width <= 0 or height <= 0) return error.BadValue;
    return .{ .x = x, .y = y, .width = width, .height = height };
}

fn parseDestination(width: i32, height: i32) ParseError!?WayringCompositor.ViewportDestination {
    if (width == -1 and height == -1) return null;
    if (width <= 0 or height <= 0) return error.BadValue;
    return .{ .width = @intCast(width), .height = @intCast(height) };
}

fn postCommitError(context: *anyopaque, err: WayringCompositor.ViewportError) void {
    const value: *Viewport = @ptrCast(@alignCast(context));
    value.client.postProtocolError(&value.resource.runtime, @intCast(switch (err) {
        .bad_size => core.wp_viewport.@"error".bad_size,
        .out_of_buffer => core.wp_viewport.@"error".out_of_buffer,
    }), "viewport state is incompatible with the committed buffer");
}

fn surfaceDestroyed(context: *anyopaque) void {
    const value: *Viewport = @ptrCast(@alignCast(context));
    value.surface = null;
}

fn destroyViewport(self: *WayringViewporter, value: *Viewport) void {
    if (value.surface) |surface| self.compositor.detachViewport(surface, value);
    remove(Viewport, &self.viewports, value);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}

fn destroyManager(self: *WayringViewporter, value: *Manager) void {
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

test "viewport request parsing distinguishes complete unset sentinels from invalid mixed values" {
    try std.testing.expectEqual(null, try parseSource(-256, -256, -256, -256));
    try std.testing.expectError(error.BadValue, parseSource(-256, 0, 256, 256));
    try std.testing.expectError(error.BadValue, parseSource(0, -256, 256, 256));
    try std.testing.expectError(error.BadValue, parseSource(0, 0, -256, 256));
    try std.testing.expectError(error.BadValue, parseSource(0, 0, 256, -256));
    try std.testing.expectError(error.BadValue, parseSource(0, 0, 0, 256));
    try std.testing.expectError(error.BadValue, parseSource(0, 0, -2, 256));
    try std.testing.expectEqual(
        WayringCompositor.ViewportSource{ .x = 0, .y = 256, .width = 512, .height = 768 },
        (try parseSource(0, 256, 512, 768)).?,
    );

    try std.testing.expectEqual(null, try parseDestination(-1, -1));
    try std.testing.expectError(error.BadValue, parseDestination(-1, 10));
    try std.testing.expectError(error.BadValue, parseDestination(0, 10));
    try std.testing.expectError(error.BadValue, parseDestination(10, -2));
    try std.testing.expectEqual(@as(u32, 10), (try parseDestination(10, 20)).?.width);
}

test "generated viewporter versions and request descriptors are authoritative" {
    try std.testing.expectEqual(@as(u32, 1), core.wp_viewporter.interface.version);
    try std.testing.expectEqual(core.wp_viewporter.interface.version, core.wp_viewport.interface.version);
    try std.testing.expectEqualStrings("get_viewport", core.wp_viewporter.request_messages[1].name);
    try std.testing.expectEqualStrings("set_source", core.wp_viewport.request_messages[1].name);
    try std.testing.expectEqualStrings("set_destination", core.wp_viewport.request_messages[2].name);
}

fn testSend(
    client: *server.Client,
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

fn testDrain(client: *server.Client) !void {
    while (try client.beginSend()) |batch|
        try client.completeSend(batch.token, batch.bytes.len);
}

fn bindTestGlobals(
    host: *server.Server,
    client: *server.Client,
    compositor_id: u32,
    viewporter_id: u32,
) !void {
    try testSend(client, 1, 1, &core.wl_display.request_messages[1], &.{.{ .new_id = .{ .typed = 2 } }});
    try testDrain(client);
    var compositor_name: ?u32 = null;
    var viewporter_name: ?u32 = null;
    var globals = host.iterator();
    while (globals.next()) |global| {
        if (std.mem.eql(u8, global.interface().name, core.wl_compositor.interface.name))
            compositor_name = global.name();
        if (std.mem.eql(u8, global.interface().name, core.wp_viewporter.interface.name))
            viewporter_name = global.name();
    }
    try testSend(client, 2, 0, &core.wl_registry.request_messages[0], &.{
        .{ .uint = compositor_name.? },
        .{ .new_id = .{ .generic = .{
            .interface = core.wl_compositor.interface.name,
            .version = 1,
            .id = compositor_id,
        } } },
    });
    try testSend(client, 2, 0, &core.wl_registry.request_messages[0], &.{
        .{ .uint = viewporter_name.? },
        .{ .new_id = .{ .generic = .{
            .interface = core.wp_viewporter.interface.name,
            .version = core.wp_viewporter.interface.version,
            .id = viewporter_id,
        } } },
    });
}

test "production resources accept raw fixed unset and surface destruction reports no_surface" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var registry = SurfaceRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &registry, null);
    defer compositor.deinit();
    var viewporter: WayringViewporter = undefined;
    viewporter.init(std.testing.allocator, &host, &compositor);
    defer viewporter.deinit();
    try viewporter.publish();
    defer viewporter.unpublish();

    var names: [4][]const u8 = undefined;
    var count: usize = 0;
    var globals = host.iterator();
    while (globals.next()) |global| : (count += 1) names[count] = global.interface().name;
    try std.testing.expectEqual(@as(usize, 4), count);
    try std.testing.expectEqualStrings(core.wp_viewporter.interface.name, names[3]);
    try std.testing.expectEqual(@as(u32, 1), viewporter.global.?.version());

    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        viewporter.destroyClientResources(client);
        compositor.destroyClientResources(client);
        managed.destroy();
    }
    try bindTestGlobals(&host, client, 3, 4);
    try testSend(client, 3, 0, &core.wl_compositor.request_messages[0], &.{.{ .new_id = .{ .typed = 5 } }});
    try testSend(client, 4, 1, &core.wp_viewporter.request_messages[1], &.{
        .{ .new_id = .{ .typed = 6 } }, .{ .object = 5 },
    });
    try std.testing.expectEqual(@as(usize, 1), viewporter.managers.items.len);
    try std.testing.expectEqual(@as(usize, 1), viewporter.viewports.items.len);

    try testSend(client, 6, 1, &core.wp_viewport.request_messages[1], &.{
        .{ .fixed = -256 }, .{ .fixed = -256 }, .{ .fixed = -256 }, .{ .fixed = -256 },
    });
    try std.testing.expect(client.fatal() == null);
    try testSend(client, 5, 0, &core.wl_surface.request_messages[0], &.{});
    try std.testing.expect(viewporter.viewports.items[0].surface == null);
    try testSend(client, 6, 2, &core.wp_viewport.request_messages[2], &.{
        .{ .int = 4 }, .{ .int = 4 },
    });
    const fatal = client.fatal().?;
    try std.testing.expectEqual(server.Fatal.Kind.protocol, fatal.kind);
    try std.testing.expectEqual(@as(u32, 6), fatal.object_id);
    try std.testing.expectEqual(
        @as(?u32, @intCast(core.wp_viewport.@"error".no_surface)),
        fatal.protocol_code,
    );
}

test "duplicate viewport terminalizes only its client and manager may die before child" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var registry = SurfaceRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &registry, null);
    defer compositor.deinit();
    var viewporter: WayringViewporter = undefined;
    viewporter.init(std.testing.allocator, &host, &compositor);
    defer viewporter.deinit();
    try viewporter.publish();
    defer viewporter.unpublish();

    const first = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const first_client = first.client();
    defer {
        viewporter.destroyClientResources(first_client);
        compositor.destroyClientResources(first_client);
        first.destroy();
    }
    try bindTestGlobals(&host, first_client, 3, 4);
    try testSend(first_client, 3, 0, &core.wl_compositor.request_messages[0], &.{.{ .new_id = .{ .typed = 5 } }});
    try testSend(first_client, 4, 1, &core.wp_viewporter.request_messages[1], &.{
        .{ .new_id = .{ .typed = 6 } }, .{ .object = 5 },
    });
    try testSend(first_client, 4, 1, &core.wp_viewporter.request_messages[1], &.{
        .{ .new_id = .{ .typed = 7 } }, .{ .object = 5 },
    });
    try std.testing.expectEqual(server.Fatal.Kind.protocol, first_client.fatal().?.kind);
    try std.testing.expectEqual(@as(u32, 4), first_client.fatal().?.object_id);
    try std.testing.expectEqual(
        @as(?u32, @intCast(core.wp_viewporter.@"error".viewport_exists)),
        first_client.fatal().?.protocol_code,
    );

    const second = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const second_client = second.client();
    defer {
        viewporter.destroyClientResources(second_client);
        compositor.destroyClientResources(second_client);
        second.destroy();
    }
    try bindTestGlobals(&host, second_client, 3, 4);
    try testSend(second_client, 3, 0, &core.wl_compositor.request_messages[0], &.{.{ .new_id = .{ .typed = 5 } }});
    try testSend(second_client, 4, 1, &core.wp_viewporter.request_messages[1], &.{
        .{ .new_id = .{ .typed = 6 } }, .{ .object = 5 },
    });
    try testSend(second_client, 4, 0, &core.wp_viewporter.request_messages[0], &.{});
    try std.testing.expectEqual(@as(usize, 2), viewporter.viewports.items.len);
    try testSend(second_client, 6, 0, &core.wp_viewport.request_messages[0], &.{});
    try std.testing.expectEqual(@as(usize, 1), viewporter.viewports.items.len);
    try std.testing.expect(second_client.fatal() == null);
}
