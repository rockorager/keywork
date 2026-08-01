//! Native surface cropping and scaling protocol policy.

const ViewporterGlobal = @This();

const std = @import("std");
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const CompositorGlobal = @import("CompositorGlobal.zig");
const surface_geometry = @import("../surface_geometry.zig");

allocator: std.mem.Allocator,
server: *Server,
global_name: u32,
viewports: std.ArrayList(*Viewport) = .empty,

const Viewport = struct {
    owner: *ViewporterGlobal,
    surface: *CompositorGlobal.Surface,
    resource: wayring.ObjectHandle,
};

pub fn init(self: *ViewporterGlobal, allocator: std.mem.Allocator, server: *Server) !void {
    self.* = .{
        .allocator = allocator,
        .server = server,
        .global_name = undefined,
    };
    self.global_name = try server.createGlobal(
        &generated.wp_viewporter,
        1,
        .{ .context = self, .bind = bind },
    );
}

pub fn deinit(self: *ViewporterGlobal) void {
    std.debug.assert(self.viewports.items.len == 0);
    self.server.removeGlobal(self.global_name) catch unreachable;
    self.viewports.deinit(self.allocator);
    self.* = undefined;
}

pub fn postGeometryError(
    self: *ViewporterGlobal,
    surface: *CompositorGlobal.Surface,
    err: surface_geometry.Error,
) !void {
    const viewport = self.viewportFor(surface);
    switch (err) {
        error.BadViewportSize => if (viewport) |resource| return surface.client.postError(
            resource,
            @intFromEnum(generated.wp_viewport_types.@"error".bad_size),
            "viewport source size must be integral without a destination",
        ),
        error.ViewportOutOfBuffer => if (viewport) |resource| return surface.client.postError(
            resource,
            @intFromEnum(generated.wp_viewport_types.@"error".out_of_buffer),
            "viewport source exceeds the attached buffer",
        ),
        error.InvalidSize => {},
    }
    return surface.client.postError(
        surface.resource,
        @intFromEnum(generated.wl_surface_types.@"error".invalid_size),
        "buffer dimensions are incompatible with surface state",
    );
}

fn viewportFor(self: *const ViewporterGlobal, surface: *const CompositorGlobal.Surface) ?wayring.ObjectHandle {
    for (self.viewports.items) |viewport| {
        if (viewport.surface == surface) return viewport.resource;
    }
    return null;
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *ViewporterGlobal = @ptrCast(@alignCast(context));
    _ = client.createResource(id, &generated.wp_viewporter, version, .{
        .context = self,
        .dispatch = dispatchViewporter,
    }) catch return client.postNoMemory();
}

fn dispatchViewporter(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const self: *ViewporterGlobal = @ptrCast(@alignCast(context));
    switch (try generated.wp_viewporter_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .get_viewport => |request| {
            const object = client.connection.object(request.surface) orelse
                return error.UnknownSurface;
            const surface = try CompositorGlobal.surfaceFor(client, .{
                .id = request.surface,
                .generation = object.generation,
            });
            if (self.viewportFor(surface) != null) return client.postError(
                resource,
                @intFromEnum(generated.wp_viewporter_types.@"error".viewport_exists),
                "wl_surface already has a viewport",
            );
            const viewport = self.allocator.create(Viewport) catch return client.postNoMemory();
            errdefer self.allocator.destroy(viewport);
            self.viewports.ensureUnusedCapacity(self.allocator, 1) catch
                return client.postNoMemory();
            surface.reference() catch return client.postNoMemory();
            errdefer surface.unreference();
            viewport.* = .{ .owner = self, .surface = surface, .resource = undefined };
            viewport.resource = client.createResource(
                request.id,
                &generated.wp_viewport,
                1,
                .{
                    .context = viewport,
                    .dispatch = dispatchViewport,
                    .destroy = destroyViewport,
                },
            ) catch return client.postNoMemory();
            self.viewports.appendAssumeCapacity(viewport);
        },
    }
}

fn dispatchViewport(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const viewport: *Viewport = @ptrCast(@alignCast(context));
    switch (try generated.wp_viewport_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .set_source => |request| {
            if (!viewport.surface.resource_alive) return client.postError(
                resource,
                @intFromEnum(generated.wp_viewport_types.@"error".no_surface),
                "wl_surface no longer exists",
            );
            if (request.x == -256 and request.y == -256 and
                request.width == -256 and request.height == -256)
            {
                viewport.surface.pending_viewport.source = null;
            } else if (request.x < 0 or request.y < 0 or
                request.width <= 0 or request.height <= 0)
            {
                return client.postError(
                    resource,
                    @intFromEnum(generated.wp_viewport_types.@"error".bad_value),
                    "invalid viewport source rectangle",
                );
            } else {
                viewport.surface.pending_viewport.source = .{
                    .x = request.x,
                    .y = request.y,
                    .width = request.width,
                    .height = request.height,
                };
            }
        },
        .set_destination => |request| {
            if (!viewport.surface.resource_alive) return client.postError(
                resource,
                @intFromEnum(generated.wp_viewport_types.@"error".no_surface),
                "wl_surface no longer exists",
            );
            if (request.width == -1 and request.height == -1) {
                viewport.surface.pending_viewport.destination = null;
            } else if (request.width <= 0 or request.height <= 0) {
                return client.postError(
                    resource,
                    @intFromEnum(generated.wp_viewport_types.@"error".bad_value),
                    "invalid viewport destination size",
                );
            } else {
                viewport.surface.pending_viewport.destination = .{
                    .width = @intCast(request.width),
                    .height = @intCast(request.height),
                };
            }
        },
    }
}

fn destroyViewport(
    context: *anyopaque,
    _: *Server.Client,
    _: wayring.ObjectHandle,
) void {
    const viewport: *Viewport = @ptrCast(@alignCast(context));
    const owner = viewport.owner;
    for (owner.viewports.items, 0..) |candidate, index| {
        if (candidate != viewport) continue;
        _ = owner.viewports.orderedRemove(index);
        viewport.surface.pending_viewport = .{};
        viewport.surface.unreference();
        owner.allocator.destroy(viewport);
        return;
    }
    unreachable;
}
