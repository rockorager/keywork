//! Display-refresh FIFO constraints for surface commits.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Surface = @import("surface.zig");

const wl = wayland.server.wl;
const wp = wayland.server.wp;

allocator: std.mem.Allocator,
global: *wl.Global,
fifo_count: usize,

pub fn init(self: *Self, allocator: std.mem.Allocator, display: *wl.Server) !void {
    self.* = .{
        .allocator = allocator,
        .global = try wl.Global.create(display, wp.FifoManagerV1, 1, *Self, self, bind),
        .fifo_count = 0,
    };
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.fifo_count == 0);
    self.global.destroy();
    self.* = undefined;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = wp.FifoManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleRequest, null, self);
}

fn handleRequest(
    resource: *wp.FifoManagerV1,
    request: wp.FifoManagerV1.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .get_fifo => |get| Fifo.create(
            self,
            resource,
            get.id,
            Surface.fromResource(get.surface),
        ),
    }
}

const Fifo = struct {
    manager: *Self,
    surface: ?*Surface,

    fn create(
        manager: *Self,
        manager_resource: *wp.FifoManagerV1,
        id: u32,
        surface: *Surface,
    ) void {
        const resource = wp.FifoV1.create(
            manager_resource.getClient(),
            manager_resource.getVersion(),
            id,
        ) catch {
            manager_resource.postNoMemory();
            return;
        };
        const self = manager.allocator.create(Fifo) catch {
            resource.postNoMemory();
            resource.destroy();
            return;
        };
        self.* = .{ .manager = manager, .surface = surface };
        surface.setFifoHandler(.{
            .context = self,
            .surface_destroyed = handleSurfaceDestroyed,
        }) catch {
            manager.allocator.destroy(self);
            resource.destroy();
            manager_resource.postError(.already_exists, "wl_surface already has a FIFO object");
            return;
        };
        manager.fifo_count += 1;
        resource.setHandler(*Fifo, Fifo.handleRequest, Fifo.handleDestroy, self);
    }

    fn handleRequest(resource: *wp.FifoV1, request: wp.FifoV1.Request, self: *Fifo) void {
        switch (request) {
            .set_barrier => {
                const surface = self.surface orelse return postSurfaceDestroyed(resource);
                surface.setPendingFifoBarrier();
            },
            .wait_barrier => {
                const surface = self.surface orelse return postSurfaceDestroyed(resource);
                surface.setPendingFifoWait();
            },
            .destroy => resource.destroy(),
        }
    }

    fn handleDestroy(_: *wp.FifoV1, self: *Fifo) void {
        if (self.surface) |surface| surface.clearFifoHandler(self);
        self.manager.fifo_count -= 1;
        self.manager.allocator.destroy(self);
    }

    fn handleSurfaceDestroyed(context: *anyopaque) void {
        const self: *Fifo = @ptrCast(@alignCast(context));
        self.surface = null;
    }
};

fn postSurfaceDestroyed(resource: *wp.FifoV1) void {
    resource.postError(.surface_destroyed, "wl_surface no longer exists");
}
