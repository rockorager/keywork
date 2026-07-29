//! Client-requested background blur regions for compositor surfaces.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const WaylandRegion = @import("region.zig");
const Surface = @import("surface.zig");

const ext = wayland.server.ext;
const wl = wayland.server.wl;

allocator: std.mem.Allocator,
global: *wl.Global,
effect_count: usize,

pub fn init(self: *Self, allocator: std.mem.Allocator, display: *wl.Server) !void {
    self.* = .{
        .allocator = allocator,
        .global = try wl.Global.create(
            display,
            ext.BackgroundEffectManagerV1,
            1,
            *Self,
            self,
            bind,
        ),
        .effect_count = 0,
    };
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.effect_count == 0);
    self.global.destroy();
    self.* = undefined;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = ext.BackgroundEffectManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleManagerRequest, null, self);
    resource.sendCapabilities(.{ .blur = true });
}

fn handleManagerRequest(
    resource: *ext.BackgroundEffectManagerV1,
    request: ext.BackgroundEffectManagerV1.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .get_background_effect => |get| BackgroundEffect.create(
            self,
            resource,
            get.id,
            Surface.fromResource(get.surface),
        ),
    }
}

const BackgroundEffect = struct {
    manager: *Self,
    surface: ?*Surface,

    fn create(
        manager: *Self,
        manager_resource: *ext.BackgroundEffectManagerV1,
        id: u32,
        surface: *Surface,
    ) void {
        const resource = ext.BackgroundEffectSurfaceV1.create(
            manager_resource.getClient(),
            manager_resource.getVersion(),
            id,
        ) catch {
            manager_resource.postNoMemory();
            return;
        };
        const self = manager.allocator.create(BackgroundEffect) catch {
            resource.postNoMemory();
            resource.destroy();
            return;
        };
        self.* = .{ .manager = manager, .surface = surface };
        surface.setBackgroundEffectHandler(.{
            .context = self,
            .surface_destroyed = handleSurfaceDestroyed,
        }) catch {
            manager.allocator.destroy(self);
            resource.destroy();
            manager_resource.postError(
                .background_effect_exists,
                "wl_surface already has a background effect object",
            );
            return;
        };
        manager.effect_count += 1;
        resource.setHandler(*BackgroundEffect, handleRequest, handleDestroy, self);
    }

    fn handleRequest(
        resource: *ext.BackgroundEffectSurfaceV1,
        request: ext.BackgroundEffectSurfaceV1.Request,
        self: *BackgroundEffect,
    ) void {
        switch (request) {
            .destroy => resource.destroy(),
            .set_blur_region => |set| {
                const surface = self.surface orelse {
                    resource.postError(.surface_destroyed, "wl_surface no longer exists");
                    return;
                };
                const region = if (set.region) |region_resource|
                    &WaylandRegion.fromResource(region_resource).value
                else
                    null;
                surface.setPendingBlurRegion(region) catch resource.postNoMemory();
            },
        }
    }

    fn handleDestroy(_: *ext.BackgroundEffectSurfaceV1, self: *BackgroundEffect) void {
        if (self.surface) |surface| surface.clearBackgroundEffectHandler();
        self.manager.effect_count -= 1;
        self.manager.allocator.destroy(self);
    }

    fn handleSurfaceDestroyed(context: *anyopaque) void {
        const self: *BackgroundEffect = @ptrCast(@alignCast(context));
        self.surface = null;
    }
};
