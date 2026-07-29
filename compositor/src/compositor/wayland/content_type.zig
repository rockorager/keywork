//! Double-buffered content hints for compositor surfaces.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Surface = @import("surface.zig");

const wl = wayland.server.wl;
const wp = wayland.server.wp;

allocator: std.mem.Allocator,
global: *wl.Global,
content_type_count: usize,

pub fn init(self: *Self, allocator: std.mem.Allocator, display: *wl.Server) !void {
    self.* = .{
        .allocator = allocator,
        .global = try wl.Global.create(display, wp.ContentTypeManagerV1, 1, *Self, self, bind),
        .content_type_count = 0,
    };
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.content_type_count == 0);
    self.global.destroy();
    self.* = undefined;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = wp.ContentTypeManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleManagerRequest, null, self);
}

fn handleManagerRequest(
    resource: *wp.ContentTypeManagerV1,
    request: wp.ContentTypeManagerV1.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .get_surface_content_type => |get| ContentType.create(
            self,
            resource,
            get.id,
            Surface.fromResource(get.surface),
        ),
    }
}

const ContentType = struct {
    manager: *Self,
    surface: ?*Surface,

    fn create(
        manager: *Self,
        manager_resource: *wp.ContentTypeManagerV1,
        id: u32,
        surface: *Surface,
    ) void {
        const resource = wp.ContentTypeV1.create(
            manager_resource.getClient(),
            manager_resource.getVersion(),
            id,
        ) catch {
            manager_resource.postNoMemory();
            return;
        };
        const self = manager.allocator.create(ContentType) catch {
            resource.postNoMemory();
            resource.destroy();
            return;
        };
        self.* = .{ .manager = manager, .surface = surface };
        surface.setContentTypeHandler(.{
            .context = self,
            .surface_destroyed = handleSurfaceDestroyed,
        }) catch {
            manager.allocator.destroy(self);
            resource.destroy();
            manager_resource.postError(
                .already_constructed,
                "wl_surface already has a content type object",
            );
            return;
        };
        manager.content_type_count += 1;
        resource.setHandler(*ContentType, handleRequest, handleDestroy, self);
    }

    fn handleRequest(
        resource: *wp.ContentTypeV1,
        request: wp.ContentTypeV1.Request,
        self: *ContentType,
    ) void {
        switch (request) {
            .destroy => resource.destroy(),
            .set_content_type => |set| {
                const surface = self.surface orelse return;
                surface.setPendingContentType(set.content_type);
            },
        }
    }

    fn handleDestroy(_: *wp.ContentTypeV1, self: *ContentType) void {
        if (self.surface) |surface| surface.clearContentTypeHandler();
        self.manager.content_type_count -= 1;
        self.manager.allocator.destroy(self);
    }

    fn handleSurfaceDestroyed(context: *anyopaque) void {
        const self: *ContentType = @ptrCast(@alignCast(context));
        self.surface = null;
    }
};
