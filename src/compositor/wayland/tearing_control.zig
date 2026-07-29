//! Per-surface presentation hints for asynchronous page flips.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Surface = @import("surface.zig");

const wl = wayland.server.wl;
const wp = wayland.server.wp;

allocator: std.mem.Allocator,
global: *wl.Global,
control_count: usize,

pub fn init(self: *Self, allocator: std.mem.Allocator, display: *wl.Server) !void {
    self.* = .{
        .allocator = allocator,
        .global = try wl.Global.create(
            display,
            wp.TearingControlManagerV1,
            1,
            *Self,
            self,
            bind,
        ),
        .control_count = 0,
    };
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.control_count == 0);
    self.global.destroy();
    self.* = undefined;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = wp.TearingControlManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleRequest, null, self);
}

fn handleRequest(
    resource: *wp.TearingControlManagerV1,
    request: wp.TearingControlManagerV1.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .get_tearing_control => |get| Control.create(
            self,
            resource,
            get.id,
            Surface.fromResource(get.surface),
        ),
    }
}

const Control = struct {
    manager: *Self,
    surface: ?*Surface,

    fn create(
        manager: *Self,
        manager_resource: *wp.TearingControlManagerV1,
        id: u32,
        surface: *Surface,
    ) void {
        const resource = wp.TearingControlV1.create(
            manager_resource.getClient(),
            manager_resource.getVersion(),
            id,
        ) catch {
            manager_resource.postNoMemory();
            return;
        };
        const self = manager.allocator.create(Control) catch {
            resource.postNoMemory();
            resource.destroy();
            return;
        };
        self.* = .{ .manager = manager, .surface = surface };
        surface.setTearingControlHandler(.{
            .context = self,
            .surface_destroyed = handleSurfaceDestroyed,
        }) catch {
            manager.allocator.destroy(self);
            resource.destroy();
            manager_resource.postError(
                .tearing_control_exists,
                "wl_surface already has a tearing control object",
            );
            return;
        };
        manager.control_count += 1;
        resource.setHandler(*Control, Control.handleRequest, Control.handleDestroy, self);
    }

    fn handleRequest(
        resource: *wp.TearingControlV1,
        request: wp.TearingControlV1.Request,
        self: *Control,
    ) void {
        switch (request) {
            .set_presentation_hint => |set| {
                const surface = self.surface orelse return;
                surface.setPendingPresentationHint(normalizeHint(set.hint));
            },
            .destroy => resource.destroy(),
        }
    }

    fn handleDestroy(_: *wp.TearingControlV1, self: *Control) void {
        if (self.surface) |surface| surface.clearTearingControlHandler(self);
        self.manager.control_count -= 1;
        self.manager.allocator.destroy(self);
    }

    fn handleSurfaceDestroyed(context: *anyopaque) void {
        const self: *Control = @ptrCast(@alignCast(context));
        self.surface = null;
    }
};

fn normalizeHint(hint: Surface.PresentationHint) Surface.PresentationHint {
    return switch (hint) {
        .async => .async,
        else => .vsync,
    };
}

test "unknown presentation hints remain synchronized" {
    try std.testing.expectEqual(
        Surface.PresentationHint.vsync,
        normalizeHint(@enumFromInt(99)),
    );
    try std.testing.expectEqual(
        Surface.PresentationHint.async,
        normalizeHint(.async),
    );
}
