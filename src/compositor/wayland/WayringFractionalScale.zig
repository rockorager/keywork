//! Scanner-backed fractional-scale resources over canonical output state.

const WayringFractionalScale = @This();

const std = @import("std");
const core = @import("wayring-protocol");
const wayland = @import("wayland");
const wayring = @import("wayring");
const SurfaceRegistry = @import("../SurfaceRegistry.zig");
const Output = @import("output.zig");
const OutputLayout = @import("output_layout.zig");
const Surface = @import("surface.zig");
const WayringCompositor = @import("WayringCompositor.zig");
const WayringOutput = @import("WayringOutput.zig");

const server = wayring.server;
const wire = wayring.wire;
const wl = wayland.server.wl;

const Manager = struct {
    owner: *WayringFractionalScale,
    client: *server.Client,
    resource: core.wp_fractional_scale_manager_v1.Resource,
};

const FractionalScale = struct {
    owner: *WayringFractionalScale,
    client: *server.Client,
    resource: core.wp_fractional_scale_v1.Resource,
    surface: ?WayringCompositor.SurfaceId,
    preferred_scale: u32,
};

allocator: std.mem.Allocator,
protocol_server: *server.Server,
compositor: *WayringCompositor,
outputs: *WayringOutput,
layout: *OutputLayout,
default_output: OutputLayout.Id,
global: ?*const server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
fractional_scales: std.ArrayList(*FractionalScale) = .empty,

pub fn init(
    self: *WayringFractionalScale,
    allocator: std.mem.Allocator,
    protocol_server: *server.Server,
    compositor: *WayringCompositor,
    outputs: *WayringOutput,
    layout: *OutputLayout,
    default_output: OutputLayout.Id,
) !void {
    if (layout.get(default_output) == null) return error.InvalidOutput;
    self.* = .{
        .allocator = allocator,
        .protocol_server = protocol_server,
        .compositor = compositor,
        .outputs = outputs,
        .layout = layout,
        .default_output = default_output,
    };
    outputs.setScaleListener(.{
        .context = self,
        .configured = outputConfigured,
        .membership_changed = membershipChanged,
    });
}

pub fn publish(self: *WayringFractionalScale) !void {
    std.debug.assert(self.global == null);
    self.global = try self.protocol_server.addGlobal(
        core.wp_fractional_scale_manager_v1,
        core.wp_fractional_scale_manager_v1.interface.version,
        WayringFractionalScale,
        self,
        bind,
    );
}

pub fn unpublish(self: *WayringFractionalScale) void {
    self.protocol_server.removeGlobal(self.global.?) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}

pub fn destroyClientResources(self: *WayringFractionalScale, client: *server.Client) void {
    var i = self.fractional_scales.items.len;
    while (i > 0) {
        i -= 1;
        if (self.fractional_scales.items[i].client == client)
            self.destroyFractionalScale(self.fractional_scales.items[i]);
    }
    i = self.managers.items.len;
    while (i > 0) {
        i -= 1;
        if (self.managers.items[i].client == client) self.destroyManager(self.managers.items[i]);
    }
}

pub fn deinit(self: *WayringFractionalScale) void {
    std.debug.assert(self.global == null and self.fractional_scales.items.len == 0 and self.managers.items.len == 0);
    self.outputs.clearScaleListener(self);
    self.fractional_scales.deinit(self.allocator);
    self.managers.deinit(self.allocator);
    self.* = undefined;
}

pub fn setDefaultOutput(self: *WayringFractionalScale, id: OutputLayout.Id) void {
    std.debug.assert(self.layout.get(id) != null);
    self.default_output = id;
    self.refresh(null);
}

pub fn defaultOutputChanged(context: *anyopaque, id: OutputLayout.Id) void {
    const self: *WayringFractionalScale = @ptrCast(@alignCast(context));
    self.setDefaultOutput(id);
}

fn bind(client: *server.Client, id: u32, version: u32, self: *WayringFractionalScale) !void {
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
    _: *core.wp_fractional_scale_manager_v1.Resource,
    request: core.wp_fractional_scale_manager_v1.Request,
    value: *Manager,
) !void {
    switch (request) {
        .destroy => value.owner.destroyManager(value),
        .get_fractional_scale => |args| try value.owner.getFractionalScale(value, args.id, args.surface),
    }
}

fn getFractionalScale(self: *WayringFractionalScale, manager: *Manager, id: u32, surface_object: u32) !void {
    try self.fractional_scales.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(FractionalScale);
    errdefer self.allocator.destroy(value);
    value.* = .{
        .owner = self,
        .client = manager.client,
        .resource = undefined,
        .surface = null,
        .preferred_scale = 0,
    };
    switch (self.compositor.attachFractionalScale(manager.client, surface_object, .{
        .context = value,
        .surface_destroyed = surfaceDestroyed,
    })) {
        .attached => |surface| value.surface = surface,
        .fractional_scale_exists => {
            self.allocator.destroy(value);
            manager.client.postProtocolError(
                &manager.resource.runtime,
                @intCast(core.wp_fractional_scale_manager_v1.@"error".fractional_scale_exists),
                "wl_surface already has a fractional scale object",
            );
            return;
        },
        .not_live, .wrong_client => {
            self.allocator.destroy(value);
            manager.client.postImplementationError(
                &manager.resource.runtime,
                "surface is not an exact live same-client Wayring wl_surface",
            );
            return;
        },
    }
    errdefer self.compositor.detachFractionalScale(value.surface.?, value);
    const preferred = self.preferredScale(value.surface.?, null) orelse
        if (self.layout.get(self.default_output)) |output|
            output.preferredScale().numerator
        else {
            self.compositor.detachFractionalScale(value.surface.?, value);
            self.allocator.destroy(value);
            manager.client.postImplementationError(&manager.resource.runtime, "canonical default output is no longer live");
            return;
        };
    value.resource = .init(
        self.allocator,
        id,
        core.wp_fractional_scale_v1.interface.version,
        .client,
        manager.client.ownerHooks(),
    );
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(FractionalScale, value, handleFractionalScale, null);
    try manager.client.materialize(&value.resource.runtime);
    self.fractional_scales.appendAssumeCapacity(value);
    value.preferred_scale = preferred;
    core.wp_fractional_scale_v1.@"send:preferred_scale"(&value.resource, preferred) catch |err|
        eventFailure(value, err, "queueing initial fractional preferred scale");
}

fn handleFractionalScale(
    _: *core.wp_fractional_scale_v1.Resource,
    request: core.wp_fractional_scale_v1.Request,
    value: *FractionalScale,
) !void {
    switch (request) {
        .destroy => value.owner.destroyFractionalScale(value),
    }
}

fn surfaceDestroyed(context: *anyopaque) void {
    const value: *FractionalScale = @ptrCast(@alignCast(context));
    value.surface = null;
}

fn destroyFractionalScale(self: *WayringFractionalScale, value: *FractionalScale) void {
    if (value.surface) |surface| self.compositor.detachFractionalScale(surface, value);
    remove(FractionalScale, &self.fractional_scales, value);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}

fn destroyManager(self: *WayringFractionalScale, value: *Manager) void {
    remove(Manager, &self.managers, value);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}

fn outputConfigured(context: *anyopaque, _: OutputLayout.Id, changes: Output.Changes) void {
    const self: *WayringFractionalScale = @ptrCast(@alignCast(context));
    if (changes.preferred_scale) self.refresh(null);
}

fn membershipChanged(context: *anyopaque, surface: WayringCompositor.SurfaceId, excluded: ?OutputLayout.Id) void {
    const self: *WayringFractionalScale = @ptrCast(@alignCast(context));
    self.refreshSurface(surface, excluded);
}

fn refresh(self: *WayringFractionalScale, excluded: ?OutputLayout.Id) void {
    for (self.fractional_scales.items) |value| {
        const surface = value.surface orelse continue;
        self.update(value, self.preferredScale(surface, excluded) orelse continue);
    }
}

fn refreshSurface(self: *WayringFractionalScale, surface: WayringCompositor.SurfaceId, excluded: ?OutputLayout.Id) void {
    for (self.fractional_scales.items) |value| {
        if (value.surface == null or !std.meta.eql(value.surface.?, surface)) continue;
        self.update(value, self.preferredScale(surface, excluded) orelse return);
        return;
    }
}

fn preferredScale(
    self: *WayringFractionalScale,
    surface: WayringCompositor.SurfaceId,
    excluded: ?OutputLayout.Id,
) ?u32 {
    var preferred: ?u32 = null;
    var outputs = self.layout.iterator();
    while (outputs.next()) |entry| {
        if (excluded) |id| if (std.meta.eql(id, entry.id)) continue;
        if (!entry.output.containsSurface(surface)) continue;
        const candidate = entry.output.preferredScale().numerator;
        if (preferred == null or candidate > preferred.?) preferred = candidate;
    }
    return preferred;
}

fn update(self: *WayringFractionalScale, value: *FractionalScale, preferred: u32) void {
    _ = self;
    if (value.preferred_scale == preferred) return;
    value.preferred_scale = preferred;
    core.wp_fractional_scale_v1.@"send:preferred_scale"(&value.resource, preferred) catch |err|
        eventFailure(value, err, "queueing fractional preferred scale");
}

fn eventFailure(value: *FractionalScale, err: anyerror, message: []const u8) void {
    switch (err) {
        error.OutOfMemory, error.WriteFailed => value.client.postOutOfMemory(&value.resource.runtime, message),
        error.DeadObject, error.InvalidObject => {},
        else => value.client.postImplementationError(&value.resource.runtime, message),
    }
}

fn remove(comptime T: type, list: *std.ArrayList(*T), value: *T) void {
    for (list.items, 0..) |item, i| if (item == value) {
        _ = list.swapRemove(i);
        return;
    };
    unreachable;
}

test "generated fractional scale protocol is pinned to version one and 120ths" {
    try std.testing.expectEqual(@as(u32, 1), core.wp_fractional_scale_manager_v1.interface.version);
    try std.testing.expectEqual(@as(u32, 1), core.wp_fractional_scale_v1.interface.version);
    try std.testing.expectEqualStrings("get_fractional_scale", core.wp_fractional_scale_manager_v1.request_messages[1].name);
    try std.testing.expectEqualStrings("preferred_scale", core.wp_fractional_scale_v1.event_messages[0].name);
    try std.testing.expectEqual(@as(i64, 0), core.wp_fractional_scale_manager_v1.@"error".fractional_scale_exists);
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

fn testDrainBytes(client: *server.Client) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(std.testing.allocator);
    while (try client.beginSend()) |batch| {
        try bytes.appendSlice(std.testing.allocator, batch.bytes);
        try client.completeSend(batch.token, batch.bytes.len);
    }
    return bytes.toOwnedSlice(std.testing.allocator);
}

fn expectSinglePreferredScaleEvent(bytes: []const u8, object_id: u32, scale: u32) !void {
    var offset: usize = 0;
    var count: usize = 0;
    while (offset + 8 <= bytes.len) {
        const id = std.mem.readInt(u32, bytes[offset..][0..4], .native);
        const size_opcode = std.mem.readInt(u32, bytes[offset + 4 ..][0..4], .native);
        const size: usize = @intCast(size_opcode >> 16);
        try std.testing.expect(size >= 8 and offset + size <= bytes.len);
        if (id == object_id and @as(u16, @truncate(size_opcode)) == 0) {
            try std.testing.expectEqual(@as(usize, 12), size);
            try std.testing.expectEqual(scale, std.mem.readInt(u32, bytes[offset + 8 ..][0..4], .native));
            count += 1;
        }
        offset += size;
    }
    try std.testing.expectEqual(bytes.len, offset);
    try std.testing.expectEqual(@as(usize, 1), count);
}

fn bindTestGlobals(host: *server.Server, client: *server.Client, compositor_id: u32, manager_id: u32) !void {
    try testSend(client, 1, 1, &core.wl_display.request_messages[1], &.{.{ .new_id = .{ .typed = 2 } }});
    try testDrain(client);
    var compositor_name: ?u32 = null;
    var manager_name: ?u32 = null;
    var globals = host.iterator();
    while (globals.next()) |global| {
        if (std.mem.eql(u8, global.interface().name, core.wl_compositor.interface.name))
            compositor_name = global.name();
        if (std.mem.eql(u8, global.interface().name, core.wp_fractional_scale_manager_v1.interface.name))
            manager_name = global.name();
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
        .{ .uint = manager_name.? },
        .{ .new_id = .{ .generic = .{
            .interface = core.wp_fractional_scale_manager_v1.interface.name,
            .version = 1,
            .id = manager_id,
        } } },
    });
}

test "fractional resources follow canonical membership and survive either parent destruction order" {
    const display = try wl.Server.create();
    defer display.destroy();
    var registry = SurfaceRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var mature_surfaces: Surface.Store = .{};
    defer mature_surfaces.deinit(std.testing.allocator);
    var layout: OutputLayout = undefined;
    layout.init(std.testing.allocator, display, &registry, &mature_surfaces);
    defer layout.deinit();
    const output_id = try layout.add(.{
        .size = .{ .width = 4, .height = 2 },
        .physical_size = .{ .width = 4, .height = 2 },
        .scale = 1,
        .preferred_scale = .{ .numerator = 120 },
        .name = "HEADLESS-1",
        .description = "Keywork headless output",
        .model = "headless",
    });
    defer std.debug.assert(layout.remove(output_id));
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &registry, null);
    defer compositor.deinit();
    var outputs: WayringOutput = undefined;
    try outputs.init(std.testing.allocator, &host, &layout, &compositor);
    defer outputs.deinit();
    var fractional: WayringFractionalScale = undefined;
    try fractional.init(std.testing.allocator, &host, &compositor, &outputs, &layout, output_id);
    defer fractional.deinit();
    try fractional.publish();
    defer fractional.unpublish();

    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        fractional.destroyClientResources(client);
        compositor.destroyClientResources(client);
        managed.destroy();
    }
    try bindTestGlobals(&host, client, 3, 4);
    try testSend(client, 3, 0, &core.wl_compositor.request_messages[0], &.{.{ .new_id = .{ .typed = 5 } }});
    try testSend(client, 4, 1, &core.wp_fractional_scale_manager_v1.request_messages[1], &.{
        .{ .new_id = .{ .typed = 6 } }, .{ .object = 5 },
    });
    try std.testing.expectEqual(@as(usize, 1), fractional.managers.items.len);
    try std.testing.expectEqual(@as(usize, 1), fractional.fractional_scales.items.len);
    try std.testing.expectEqual(@as(u32, 120), fractional.fractional_scales.items[0].preferred_scale);

    const surface_id = compositor.surfaceId(client, 5).?;
    const output = layout.get(output_id).?;
    const snapshot = output.snapshot();
    _ = output.configure(
        snapshot.position,
        snapshot.size,
        snapshot.mode_size,
        snapshot.refresh_millihertz,
        snapshot.mode_preferred,
        @intCast(snapshot.scale),
        .{ .numerator = 180 },
    );
    try std.testing.expectEqual(@as(u32, 120), fractional.fractional_scales.items[0].preferred_scale);
    output.beginFrame();
    try output.markSurfaceVisible(surface_id);
    output.endFrame();
    try std.testing.expectEqual(@as(u32, 180), fractional.fractional_scales.items[0].preferred_scale);
    output.beginFrame();
    output.endFrame();
    try std.testing.expectEqual(@as(u32, 180), fractional.fractional_scales.items[0].preferred_scale);

    const second_output_id = try layout.add(.{
        .position = .{ .x = 4, .y = 0 },
        .size = .{ .width = 4, .height = 2 },
        .physical_size = .{ .width = 4, .height = 2 },
        .scale = 2,
        .preferred_scale = .{ .numerator = 240 },
        .name = "HEADLESS-2",
        .description = "Second Keywork headless output",
        .model = "headless",
    });
    const second_output = layout.get(second_output_id).?;
    output.beginFrame();
    try output.markSurfaceVisible(surface_id);
    output.endFrame();
    second_output.beginFrame();
    try second_output.markSurfaceVisible(surface_id);
    second_output.endFrame();
    try std.testing.expectEqual(@as(u32, 240), fractional.fractional_scales.items[0].preferred_scale);

    fractional.setDefaultOutput(second_output_id);
    try testSend(client, 3, 0, &core.wl_compositor.request_messages[0], &.{.{ .new_id = .{ .typed = 7 } }});
    try testSend(client, 4, 1, &core.wp_fractional_scale_manager_v1.request_messages[1], &.{
        .{ .new_id = .{ .typed = 8 } }, .{ .object = 7 },
    });
    try std.testing.expectEqual(@as(u32, 240), fractional.fractional_scales.items[1].preferred_scale);
    try testSend(client, 8, 0, &core.wp_fractional_scale_v1.request_messages[0], &.{});
    try testSend(client, 7, 0, &core.wl_surface.request_messages[0], &.{});
    fractional.setDefaultOutput(output_id);
    try testDrain(client);
    try std.testing.expect(layout.remove(second_output_id));
    const removal_events = try testDrainBytes(client);
    defer std.testing.allocator.free(removal_events);
    try expectSinglePreferredScaleEvent(removal_events, 6, 180);
    try std.testing.expectEqual(@as(u32, 180), fractional.fractional_scales.items[0].preferred_scale);
    try std.testing.expect((try client.beginSend()) == null);

    try testSend(client, 4, 0, &core.wp_fractional_scale_manager_v1.request_messages[0], &.{});
    try std.testing.expectEqual(@as(usize, 0), fractional.managers.items.len);
    try std.testing.expectEqual(@as(usize, 1), fractional.fractional_scales.items.len);
    try testSend(client, 5, 0, &core.wl_surface.request_messages[0], &.{});
    try std.testing.expect(fractional.fractional_scales.items[0].surface == null);
    try testSend(client, 6, 0, &core.wp_fractional_scale_v1.request_messages[0], &.{});
    try std.testing.expectEqual(@as(usize, 0), fractional.fractional_scales.items.len);

    const duplicate = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const duplicate_client = duplicate.client();
    try bindTestGlobals(&host, duplicate_client, 3, 4);
    try testSend(duplicate_client, 3, 0, &core.wl_compositor.request_messages[0], &.{.{ .new_id = .{ .typed = 5 } }});
    try testSend(duplicate_client, 4, 1, &core.wp_fractional_scale_manager_v1.request_messages[1], &.{
        .{ .new_id = .{ .typed = 6 } }, .{ .object = 5 },
    });
    try testSend(duplicate_client, 4, 1, &core.wp_fractional_scale_manager_v1.request_messages[1], &.{
        .{ .new_id = .{ .typed = 7 } }, .{ .object = 5 },
    });
    try std.testing.expectEqual(server.Fatal.Kind.protocol, duplicate_client.fatal().?.kind);
    try std.testing.expectEqual(
        @as(?u32, @intCast(core.wp_fractional_scale_manager_v1.@"error".fractional_scale_exists)),
        duplicate_client.fatal().?.protocol_code,
    );
    fractional.destroyClientResources(duplicate_client);
    compositor.destroyClientResources(duplicate_client);
    duplicate.destroy();
    try std.testing.expect(client.fatal() == null);
}
