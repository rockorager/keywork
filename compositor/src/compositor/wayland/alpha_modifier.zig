//! Per-surface alpha-modifier-v1 state.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Surface = @import("surface.zig");

const wl = wayland.server.wl;
const wp = wayland.server.wp;

allocator: std.mem.Allocator,
global: *wl.Global,
surface_count: usize,

pub fn init(self: *Self, allocator: std.mem.Allocator, display: *wl.Server) !void {
    self.* = .{
        .allocator = allocator,
        .global = try wl.Global.create(display, wp.AlphaModifierV1, 1, *Self, self, bind),
        .surface_count = 0,
    };
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.surface_count == 0);
    self.global.destroy();
    self.* = undefined;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = wp.AlphaModifierV1.create(client, version, id) catch return client.postNoMemory();
    resource.setHandler(*Self, managerRequest, null, self);
}

fn managerRequest(resource: *wp.AlphaModifierV1, request: wp.AlphaModifierV1.Request, self: *Self) void {
    switch (request) {
        .destroy => resource.destroy(),
        .get_surface => |get| Modifier.create(self, resource, get.id, Surface.fromResource(get.surface)),
    }
}

const Modifier = struct {
    manager: *Self,
    surface: ?*Surface,
    resource: *wp.AlphaModifierSurfaceV1,

    fn create(manager: *Self, parent: *wp.AlphaModifierV1, id: u32, surface: *Surface) void {
        const resource = wp.AlphaModifierSurfaceV1.create(parent.getClient(), parent.getVersion(), id) catch return parent.postNoMemory();
        const self = manager.allocator.create(Modifier) catch {
            resource.postNoMemory();
            resource.destroy();
            return;
        };
        self.* = .{ .manager = manager, .surface = surface, .resource = resource };
        surface.setAlphaModifierHandler(.{ .context = self, .surface_destroyed = surfaceDestroyed }) catch {
            manager.allocator.destroy(self);
            resource.destroy();
            parent.postError(.already_constructed, "wl_surface already has an alpha modifier object");
            return;
        };
        manager.surface_count += 1;
        resource.setHandler(*Modifier, request, destroy, self);
    }

    fn request(resource: *wp.AlphaModifierSurfaceV1, req: wp.AlphaModifierSurfaceV1.Request, self: *Modifier) void {
        switch (req) {
            .destroy => resource.destroy(),
            .set_multiplier => |set| {
                const surface = self.surface orelse {
                    resource.postError(.no_surface, "wl_surface has been destroyed");
                    return;
                };
                surface.setPendingAlphaMultiplier(set.factor);
            },
        }
    }

    fn destroy(_: *wp.AlphaModifierSurfaceV1, self: *Modifier) void {
        if (self.surface) |surface| surface.clearAlphaModifierHandler(self);
        self.manager.surface_count -= 1;
        self.manager.allocator.destroy(self);
    }

    fn surfaceDestroyed(context: *anyopaque) void {
        const self: *Modifier = @ptrCast(@alignCast(context));
        self.surface = null;
    }
};

test "alpha multiplier protocol endpoints are exact" {
    try std.testing.expectEqual(@as(u32, 0), normalizedByte(255, 0));
    try std.testing.expectEqual(@as(u32, 255), normalizedByte(255, std.math.maxInt(u32)));
    try std.testing.expectEqual(@as(u32, 128), normalizedByte(255, 0x8000_0000));
}

fn normalizedByte(value: u8, factor: u32) u32 {
    return @intCast((@as(u64, value) * factor + std.math.maxInt(u32) / 2) / std.math.maxInt(u32));
}
