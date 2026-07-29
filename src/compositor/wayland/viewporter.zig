//! Server-side surface cropping and scaling protocol.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const render = @import("../render/types.zig");
const Surface = @import("surface.zig");

const wl = wayland.server.wl;
const wp = wayland.server.wp;

allocator: std.mem.Allocator,
global: *wl.Global,
viewport_count: usize,

pub fn init(self: *Self, allocator: std.mem.Allocator, display: *wl.Server) !void {
    self.* = .{
        .allocator = allocator,
        .global = try wl.Global.create(display, wp.Viewporter, 1, *Self, self, bind),
        .viewport_count = 0,
    };
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.viewport_count == 0);
    self.global.destroy();
    self.* = undefined;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = wp.Viewporter.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleRequest, null, self);
}

fn handleRequest(resource: *wp.Viewporter, request: wp.Viewporter.Request, self: *Self) void {
    switch (request) {
        .destroy => resource.destroy(),
        .get_viewport => |get| Viewport.create(
            self,
            resource,
            get.id,
            Surface.fromResource(get.surface),
        ),
    }
}

const Viewport = struct {
    server: *Self,
    surface: ?*Surface,

    fn create(server: *Self, manager: *wp.Viewporter, id: u32, surface: *Surface) void {
        const resource = wp.Viewport.create(manager.getClient(), manager.getVersion(), id) catch {
            manager.postNoMemory();
            return;
        };
        const self = server.allocator.create(Viewport) catch {
            resource.postNoMemory();
            resource.destroy();
            return;
        };
        self.* = .{ .server = server, .surface = surface };
        surface.setViewportHandler(.{
            .context = self,
            .resource = resource,
            .surface_destroyed = handleSurfaceDestroyed,
        }) catch {
            server.allocator.destroy(self);
            resource.destroy();
            manager.postError(.viewport_exists, "wl_surface already has a viewport");
            return;
        };
        server.viewport_count += 1;
        resource.setHandler(*Viewport, Viewport.handleRequest, Viewport.handleDestroy, self);
    }

    fn handleRequest(resource: *wp.Viewport, request: wp.Viewport.Request, self: *Viewport) void {
        switch (request) {
            .destroy => resource.destroy(),
            .set_source => |set| {
                const surface = self.surface orelse {
                    resource.postError(.no_surface, "wl_surface no longer exists");
                    return;
                };
                const x: i32 = @intFromEnum(set.x);
                const y: i32 = @intFromEnum(set.y);
                const width: i32 = @intFromEnum(set.width);
                const height: i32 = @intFromEnum(set.height);
                if (x == -256 and y == -256 and width == -256 and height == -256) {
                    surface.setViewportSource(null);
                } else if (x < 0 or y < 0 or width <= 0 or height <= 0) {
                    resource.postError(.bad_value, "invalid viewport source rectangle");
                } else {
                    surface.setViewportSource(.{
                        .x = x,
                        .y = y,
                        .width = width,
                        .height = height,
                    });
                }
            },
            .set_destination => |set| {
                const surface = self.surface orelse {
                    resource.postError(.no_surface, "wl_surface no longer exists");
                    return;
                };
                if (set.width == -1 and set.height == -1) {
                    surface.setViewportDestination(null);
                } else if (set.width <= 0 or set.height <= 0) {
                    resource.postError(.bad_value, "invalid viewport destination size");
                } else {
                    const destination: render.Size = .{
                        .width = @intCast(set.width),
                        .height = @intCast(set.height),
                    };
                    surface.setViewportDestination(destination);
                }
            },
        }
    }

    fn handleDestroy(_: *wp.Viewport, self: *Viewport) void {
        if (self.surface) |surface| surface.clearViewportHandler();
        self.server.viewport_count -= 1;
        self.server.allocator.destroy(self);
    }

    fn handleSurfaceDestroyed(context: *anyopaque) void {
        const self: *Viewport = @ptrCast(@alignCast(context));
        self.surface = null;
    }
};
