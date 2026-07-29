//! Server-side wl_region state.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Region = @import("../region.zig");

const wl = wayland.server.wl;

allocator: std.mem.Allocator,
value: Region,

pub fn create(
    allocator: std.mem.Allocator,
    client: *wl.Client,
    version: u32,
    id: u32,
) error{ OutOfMemory, ResourceCreateFailed }!void {
    const resource = try wl.Region.create(client, version, id);
    errdefer resource.destroy();

    const self = allocator.create(Self) catch return error.OutOfMemory;
    self.* = .{
        .allocator = allocator,
        .value = Region.init(),
    };

    resource.setHandler(*Self, handleRequest, handleDestroy, self);
}

pub fn fromResource(resource: *wl.Region) *Self {
    return @ptrCast(@alignCast(resource.getUserData().?));
}

fn handleRequest(resource: *wl.Region, request: wl.Region.Request, self: *Self) void {
    switch (request) {
        .destroy => resource.destroy(),
        .add => |add| self.value.add(add.x, add.y, add.width, add.height) catch
            resource.postNoMemory(),
        .subtract => |subtract| self.value.subtract(
            subtract.x,
            subtract.y,
            subtract.width,
            subtract.height,
        ) catch resource.postNoMemory(),
    }
}

fn handleDestroy(_: *wl.Region, self: *Self) void {
    self.value.deinit();
    self.allocator.destroy(self);
}
