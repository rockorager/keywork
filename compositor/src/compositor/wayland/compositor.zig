//! wl_compositor global and object factories.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Surface = @import("surface.zig");
const WaylandRegion = @import("region.zig");

const wl = wayland.server.wl;

allocator: std.mem.Allocator,
global: *wl.Global,
surfaces: Surface.Store,

pub fn init(self: *Self, allocator: std.mem.Allocator, display: *wl.Server) !void {
    self.* = .{
        .allocator = allocator,
        .global = undefined,
        .surfaces = .{},
    };
    errdefer self.surfaces.deinit(allocator);
    self.global = try wl.Global.create(display, wl.Compositor, 7, *Self, self, bind);
}

pub fn deinit(self: *Self) void {
    self.global.destroy();
    self.surfaces.deinit(self.allocator);
    self.* = undefined;
}

pub fn surfaceStore(self: *Self) *Surface.Store {
    return &self.surfaces;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = wl.Compositor.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleRequest, null, self);
}

fn handleRequest(resource: *wl.Compositor, request: wl.Compositor.Request, self: *Self) void {
    switch (request) {
        .create_surface => |create| self.createSurface(resource, create.id),
        .create_region => |create| WaylandRegion.create(
            self.allocator,
            resource.getClient(),
            resource.getVersion(),
            create.id,
        ) catch resource.postNoMemory(),
        .release => resource.destroy(),
    }
}

fn createSurface(self: *Self, compositor: *wl.Compositor, id: u32) void {
    _ = Surface.create(
        self.allocator,
        &self.surfaces,
        compositor.getClient(),
        compositor.getVersion(),
        id,
    ) catch {
        compositor.postNoMemory();
        return;
    };
}
