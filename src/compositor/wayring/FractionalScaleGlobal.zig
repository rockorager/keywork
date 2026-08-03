//! Native preferred fractional-scale advertisement for Wayring surfaces.

const FractionalScaleGlobal = @This();

const std = @import("std");
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const CompositorGlobal = @import("CompositorGlobal.zig");

allocator: std.mem.Allocator,
server: *Server,
global_name: u32,
preferred_scale: u32,
resources: std.ArrayList(*FractionalScale) = .empty,

const FractionalScale = struct {
    owner: *FractionalScaleGlobal,
    surface: *CompositorGlobal.Surface,
    resource: wayring.ObjectHandle,
};

pub fn init(
    self: *FractionalScaleGlobal,
    allocator: std.mem.Allocator,
    server: *Server,
    preferred_scale: u32,
) !void {
    if (preferred_scale == 0) return error.InvalidScale;
    self.* = .{
        .allocator = allocator,
        .server = server,
        .global_name = undefined,
        .preferred_scale = preferred_scale,
    };
    self.global_name = try server.createGlobal(
        &generated.wp_fractional_scale_manager_v1,
        1,
        .{ .context = self, .bind = bind },
    );
}

pub fn deinit(self: *FractionalScaleGlobal) void {
    std.debug.assert(self.resources.items.len == 0);
    self.server.removeGlobal(self.global_name) catch unreachable;
    self.resources.deinit(self.allocator);
    self.* = undefined;
}

pub fn setPreferredScale(self: *FractionalScaleGlobal, preferred_scale: u32) !void {
    if (preferred_scale == 0) return error.InvalidScale;
    if (self.preferred_scale == preferred_scale) return;
    self.preferred_scale = preferred_scale;
    for (self.resources.items) |resource| generated.wp_fractional_scale_v1_types.events.preferred_scale(
        &resource.surface.client.connection,
        resource.resource,
        preferred_scale,
    ) catch resource.surface.client.postNoMemory() catch {};
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *FractionalScaleGlobal = @ptrCast(@alignCast(context));
    _ = client.createResource(id, &generated.wp_fractional_scale_manager_v1, version, .{
        .context = self,
        .dispatch = dispatchManager,
    }) catch return client.postNoMemory();
}

fn dispatchManager(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const self: *FractionalScaleGlobal = @ptrCast(@alignCast(context));
    switch (try generated.wp_fractional_scale_manager_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .get_fractional_scale => |request| {
            const object = client.connection.object(request.surface) orelse
                return error.UnknownSurface;
            const surface = try CompositorGlobal.surfaceFor(client, .{
                .id = request.surface,
                .generation = object.generation,
            });
            for (self.resources.items) |candidate| {
                if (candidate.surface != surface) continue;
                return client.postError(
                    resource,
                    @intFromEnum(generated.wp_fractional_scale_manager_v1_types.@"error".fractional_scale_exists),
                    "wl_surface already has a fractional-scale object",
                );
            }
            const fractional_scale = self.allocator.create(FractionalScale) catch
                return client.postNoMemory();
            errdefer self.allocator.destroy(fractional_scale);
            self.resources.ensureUnusedCapacity(self.allocator, 1) catch
                return client.postNoMemory();
            surface.reference() catch return client.postNoMemory();
            errdefer surface.unreference();
            fractional_scale.* = .{
                .owner = self,
                .surface = surface,
                .resource = undefined,
            };
            fractional_scale.resource = client.createResource(
                request.id,
                &generated.wp_fractional_scale_v1,
                1,
                .{
                    .context = fractional_scale,
                    .dispatch = dispatchFractionalScale,
                    .destroy = destroyFractionalScale,
                },
            ) catch return client.postNoMemory();
            self.resources.appendAssumeCapacity(fractional_scale);
            try generated.wp_fractional_scale_v1_types.events.preferred_scale(
                &client.connection,
                fractional_scale.resource,
                self.preferred_scale,
            );
        },
    }
}

fn dispatchFractionalScale(
    _: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    _ = try generated.wp_fractional_scale_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    );
}

fn destroyFractionalScale(
    context: *anyopaque,
    _: *Server.Client,
    _: wayring.ObjectHandle,
) void {
    const fractional_scale: *FractionalScale = @ptrCast(@alignCast(context));
    const owner = fractional_scale.owner;
    for (owner.resources.items, 0..) |candidate, index| {
        if (candidate != fractional_scale) continue;
        _ = owner.resources.orderedRemove(index);
        fractional_scale.surface.unreference();
        owner.allocator.destroy(fractional_scale);
        return;
    }
    unreachable;
}
