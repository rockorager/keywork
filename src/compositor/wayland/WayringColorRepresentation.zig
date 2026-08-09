//! Scanner-backed buffer color-model and quantization metadata.

const WayringColorRepresentation = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayring = @import("wayring");
const WayringCompositor = @import("WayringCompositor.zig");
const render = @import("../render/types.zig");

const server = wayring.server;
const SurfaceProtocol = protocol.wp_color_representation_surface_v1;
const State = WayringCompositor.ColorRepresentationState;

const Manager = struct {
    owner: *WayringColorRepresentation,
    client: *server.Client,
    resource: protocol.wp_color_representation_manager_v1.Resource,
};

const Representation = struct {
    owner: *WayringColorRepresentation,
    client: *server.Client,
    resource: SurfaceProtocol.Resource,
    surface: ?WayringCompositor.SurfaceId,
    state: State,
};

allocator: std.mem.Allocator,
protocol_server: *server.Server,
compositor: *WayringCompositor,
global: ?*const server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
representations: std.ArrayList(*Representation) = .empty,

pub fn init(self: *WayringColorRepresentation, allocator: std.mem.Allocator, protocol_server: *server.Server, compositor: *WayringCompositor) void {
    self.* = .{ .allocator = allocator, .protocol_server = protocol_server, .compositor = compositor };
}

pub fn publish(self: *WayringColorRepresentation) !void {
    self.global = try self.protocol_server.addGlobal(protocol.wp_color_representation_manager_v1, 1, WayringColorRepresentation, self, bind);
}

pub fn unpublish(self: *WayringColorRepresentation) void {
    self.protocol_server.removeGlobal(self.global.?) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}

pub fn destroyClientResources(self: *WayringColorRepresentation, client: *server.Client) void {
    var i = self.representations.items.len;
    while (i > 0) {
        i -= 1;
        if (self.representations.items[i].client == client) self.destroyRepresentation(self.representations.items[i]);
    }
    i = self.managers.items.len;
    while (i > 0) {
        i -= 1;
        if (self.managers.items[i].client == client) self.destroyManager(self.managers.items[i]);
    }
}

pub fn deinit(self: *WayringColorRepresentation) void {
    std.debug.assert(self.global == null and self.representations.items.len == 0 and self.managers.items.len == 0);
    self.representations.deinit(self.allocator);
    self.managers.deinit(self.allocator);
    self.* = undefined;
}

fn bind(client: *server.Client, id: u32, version: u32, self: *WayringColorRepresentation) !void {
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
    try manager.resource.setHandler(Manager, manager, handleManager, null);
    try client.materialize(&manager.resource.runtime);
    self.managers.appendAssumeCapacity(manager);
    // Output cannot be rewound after the manager is materialized. Retain the
    // resource for ordinary teardown and terminalize the client on failure.
    sendCapabilities(manager) catch {
        client.postOutOfMemory(&manager.resource.runtime, "queueing color representation capabilities");
        return;
    };
}

fn sendCapabilities(manager: *Manager) !void {
    try protocol.wp_color_representation_manager_v1.@"send:supported_alpha_mode"(&manager.resource, @intCast(SurfaceProtocol.alpha_mode.premultiplied_electrical));
    inline for (.{
        .{ SurfaceProtocol.coefficients.identity, SurfaceProtocol.range.full },
        .{ SurfaceProtocol.coefficients.bt601, SurfaceProtocol.range.full },
        .{ SurfaceProtocol.coefficients.bt601, SurfaceProtocol.range.limited },
        .{ SurfaceProtocol.coefficients.bt709, SurfaceProtocol.range.full },
        .{ SurfaceProtocol.coefficients.bt709, SurfaceProtocol.range.limited },
        .{ SurfaceProtocol.coefficients.bt2020, SurfaceProtocol.range.full },
        .{ SurfaceProtocol.coefficients.bt2020, SurfaceProtocol.range.limited },
    }) |pair| try protocol.wp_color_representation_manager_v1.@"send:supported_coefficients_and_ranges"(
        &manager.resource,
        @intCast(pair[0]),
        @intCast(pair[1]),
    );
    try protocol.wp_color_representation_manager_v1.@"send:done"(&manager.resource);
}

fn handleManager(_: *protocol.wp_color_representation_manager_v1.Resource, request: protocol.wp_color_representation_manager_v1.Request, manager: *Manager) !void {
    switch (request) {
        .destroy => manager.owner.destroyManager(manager),
        .get_surface => |args| try manager.owner.createRepresentation(manager, args.id, args.surface),
    }
}

fn createRepresentation(self: *WayringColorRepresentation, manager: *Manager, id: u32, surface_object: u32) !void {
    try self.representations.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Representation);
    errdefer self.allocator.destroy(value);
    value.* = .{ .owner = self, .client = manager.client, .resource = undefined, .surface = null, .state = .{} };
    switch (self.compositor.attachColorRepresentation(manager.client, surface_object, .{
        .context = value,
        .surface_destroyed = surfaceDestroyed,
        .validate_commit = validateCommit,
    })) {
        .attached => |surface| {
            value.surface = surface;
            value.state = self.compositor.pendingColorRepresentation(surface).?;
        },
        .surface_exists => {
            self.allocator.destroy(value);
            manager.client.postProtocolError(&manager.resource.runtime, @intCast(protocol.wp_color_representation_manager_v1.@"error".surface_exists), "wl_surface already has a color representation object");
            return;
        },
        .not_live, .wrong_client => {
            self.allocator.destroy(value);
            manager.client.postImplementationError(&manager.resource.runtime, "surface is not an exact live same-client Wayring wl_surface");
            return;
        },
    }
    errdefer self.compositor.detachColorRepresentation(value.surface.?, value);
    value.resource = .init(self.allocator, id, 1, .client, manager.client.ownerHooks());
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Representation, value, handleRepresentation, null);
    try manager.client.materialize(&value.resource.runtime);
    self.representations.appendAssumeCapacity(value);
}

fn handleRepresentation(_: *SurfaceProtocol.Resource, request: SurfaceProtocol.Request, value: *Representation) !void {
    if (request == .destroy) return value.owner.destroyRepresentation(value);
    const surface = value.surface orelse {
        value.client.postProtocolError(&value.resource.runtime, @intCast(SurfaceProtocol.@"error".inert), "wl_surface has been destroyed");
        return;
    };
    switch (request) {
        .destroy => unreachable,
        .set_alpha_mode => |args| {
            const mode: State.AlphaMode = @enumFromInt(args.alpha_mode);
            if (!supportedAlpha(mode)) return value.client.postProtocolError(&value.resource.runtime, @intCast(SurfaceProtocol.@"error".alpha_mode), "unsupported alpha mode");
            value.state.alpha_mode = mode;
        },
        .set_coefficients_and_range => |args| {
            const coefficients: State.Coefficients = @enumFromInt(args.coefficients);
            const range: State.Range = @enumFromInt(args.range);
            if (!supportedCoefficients(coefficients, range)) return value.client.postProtocolError(&value.resource.runtime, @intCast(SurfaceProtocol.@"error".coefficients), "unsupported coefficients and range");
            value.state.coefficients = coefficients;
            value.state.range = range;
        },
        .set_chroma_location => |args| {
            const chroma: State.ChromaLocation = @enumFromInt(args.chroma_location);
            if (!validChroma(chroma)) return value.client.postProtocolError(&value.resource.runtime, @intCast(SurfaceProtocol.@"error".chroma_location), "invalid chroma location");
            value.state.chroma_location = chroma;
        },
    }
    _ = value.owner.compositor.setPendingColorRepresentation(surface, value, value.state);
}

fn supportedAlpha(mode: State.AlphaMode) bool {
    return mode == .premultiplied_electrical;
}

fn supportedCoefficients(coefficients: State.Coefficients, range: State.Range) bool {
    return switch (coefficients) {
        .identity => range == .full,
        .bt601, .bt709, .bt2020 => range == .full or range == .limited,
        else => false,
    };
}

fn validChroma(chroma: State.ChromaLocation) bool {
    return switch (chroma) {
        .type_0, .type_1, .type_2, .type_3, .type_4, .type_5 => true,
        else => false,
    };
}

fn commitCompatible(state: State, format: ?render.DmabufFormat) bool {
    const buffer_format = format orelse return true;
    if ((state.coefficients == null) != (state.range == null)) return false;
    if (buffer_format.isPackedRgb()) {
        return state.chroma_location == null and
            (state.coefficients == null or (state.coefficients == .identity and state.range == .full));
    }
    return state.coefficients == null or
        (state.coefficients != .identity and supportedCoefficients(state.coefficients.?, state.range.?));
}

fn validateCommit(context: *anyopaque, state: State, format: ?render.DmabufFormat) bool {
    const value: *Representation = @ptrCast(@alignCast(context));
    if (commitCompatible(state, format)) return true;
    value.client.postProtocolError(&value.resource.runtime, @intCast(SurfaceProtocol.@"error".pixel_format), "color representation is incompatible with the buffer format");
    return false;
}

fn surfaceDestroyed(context: *anyopaque) void {
    const value: *Representation = @ptrCast(@alignCast(context));
    value.surface = null;
}

fn destroyRepresentation(self: *WayringColorRepresentation, value: *Representation) void {
    if (value.surface) |surface| self.compositor.detachColorRepresentation(surface, value);
    remove(Representation, &self.representations, value);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}

fn destroyManager(self: *WayringColorRepresentation, manager: *Manager) void {
    remove(Manager, &self.managers, manager);
    manager.resource.destroy();
    manager.resource.deinit();
    self.allocator.destroy(manager);
}

fn remove(comptime T: type, list: *std.ArrayList(*T), value: *T) void {
    for (list.items, 0..) |item, i| if (item == value) {
        _ = list.swapRemove(i);
        return;
    };
    unreachable;
}

test "capabilities and compatibility match the protocol contract" {
    try std.testing.expectEqual(@as(u32, 1), protocol.wp_color_representation_manager_v1.interface.version);
    try std.testing.expectEqualStrings("get_surface", protocol.wp_color_representation_manager_v1.request_messages[1].name);
    try std.testing.expectEqualStrings("set_coefficients_and_range", SurfaceProtocol.request_messages[2].name);
    try std.testing.expectEqual(@as(i64, 1), protocol.wp_color_representation_manager_v1.@"error".surface_exists);
    try std.testing.expectEqual(@as(i64, 1), SurfaceProtocol.@"error".alpha_mode);
    try std.testing.expectEqual(@as(i64, 2), SurfaceProtocol.@"error".coefficients);
    try std.testing.expectEqual(@as(i64, 3), SurfaceProtocol.@"error".pixel_format);
    try std.testing.expectEqual(@as(i64, 4), SurfaceProtocol.@"error".inert);
    try std.testing.expectEqual(@as(i64, 5), SurfaceProtocol.@"error".chroma_location);
    try std.testing.expect(supportedAlpha(.premultiplied_electrical));
    try std.testing.expect(!supportedAlpha(.straight));
    try std.testing.expect(supportedCoefficients(.bt2020, .limited));
    try std.testing.expect(!supportedCoefficients(.identity, .limited));
    try std.testing.expect(commitCompatible(.{ .coefficients = .identity, .range = .full }, .argb8888));
    try std.testing.expect(!commitCompatible(.{ .coefficients = .bt709, .range = .limited }, .argb8888));
    try std.testing.expect(commitCompatible(.{ .coefficients = .bt709, .range = .limited }, .nv12));
    const video = (WayringCompositor.ColorRepresentationState{}).toRender(.nv12);
    try std.testing.expectEqual(render.ColorCoefficients.bt709, video.coefficients);
    try std.testing.expectEqual(render.ColorRange.limited, video.range);
    try std.testing.expectEqual(render.ChromaLocation.type_0, video.chroma_location.?);
}
