//! Scanner-backed wp_single_pixel_buffer_manager_v1 adapter.

const WayringSinglePixelBuffer = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const server = @import("wayring").server;
const WayringCompositor = @import("WayringCompositor.zig");

const Manager = struct {
    owner: *WayringSinglePixelBuffer,
    client: *server.Client,
    resource: protocol.wp_single_pixel_buffer_manager_v1.Resource,
};

const Buffer = struct {
    owner: *WayringSinglePixelBuffer,
    client: *server.Client,
    resource: protocol.wl_buffer.Resource,
    pixel: u32,
};

allocator: std.mem.Allocator,
protocol_server: *server.Server,
compositor: *WayringCompositor,
global: ?*const server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
buffers: std.ArrayList(*Buffer) = .empty,

pub fn init(
    self: *WayringSinglePixelBuffer,
    allocator: std.mem.Allocator,
    protocol_server: *server.Server,
    compositor: *WayringCompositor,
) void {
    self.* = .{
        .allocator = allocator,
        .protocol_server = protocol_server,
        .compositor = compositor,
    };
    compositor.setSinglePixelResolver(.{
        .context = self,
        .resolve = resolveThunk,
    });
}

pub fn deinit(self: *WayringSinglePixelBuffer) void {
    std.debug.assert(self.managers.items.len == 0);
    std.debug.assert(self.buffers.items.len == 0);
    self.unpublish();
    self.compositor.clearSinglePixelResolver(self);
    self.buffers.deinit(self.allocator);
    self.managers.deinit(self.allocator);
    self.* = undefined;
}

pub fn publish(self: *WayringSinglePixelBuffer) !void {
    std.debug.assert(self.global == null);
    self.global = try self.protocol_server.addGlobal(
        protocol.wp_single_pixel_buffer_manager_v1,
        1,
        WayringSinglePixelBuffer,
        self,
        bind,
    );
}

pub fn unpublish(self: *WayringSinglePixelBuffer) void {
    const global = self.global orelse return;
    self.protocol_server.removeGlobal(global) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}

pub fn destroyClientResources(self: *WayringSinglePixelBuffer, client: *server.Client) void {
    var buffer_index = self.buffers.items.len;
    while (buffer_index > 0) {
        buffer_index -= 1;
        const buffer = self.buffers.items[buffer_index];
        if (buffer.client == client) self.destroyBuffer(buffer);
    }
    var manager_index = self.managers.items.len;
    while (manager_index > 0) {
        manager_index -= 1;
        const manager = self.managers.items[manager_index];
        if (manager.client == client) self.destroyManager(manager);
    }
}

fn bind(client: *server.Client, id: u32, version: u32, self: *WayringSinglePixelBuffer) !void {
    try self.managers.ensureUnusedCapacity(self.allocator, 1);
    const manager = try self.allocator.create(Manager);
    errdefer self.allocator.destroy(manager);
    manager.* = .{
        .owner = self,
        .client = client,
        .resource = .init(self.allocator, id, version, .client, client.ownerHooks()),
    };
    errdefer {
        manager.resource.destroy();
        manager.resource.deinit();
    }
    try manager.resource.setHandler(Manager, manager, handleManager, null);
    try client.materialize(&manager.resource.runtime);
    self.managers.appendAssumeCapacity(manager);
}

fn handleManager(
    resource: *protocol.wp_single_pixel_buffer_manager_v1.Resource,
    request: protocol.wp_single_pixel_buffer_manager_v1.Request,
    manager: *Manager,
) !void {
    _ = resource;
    switch (request) {
        .destroy => manager.owner.destroyManager(manager),
        .create_u32_rgba_buffer => |create| try manager.owner.createBuffer(
            manager,
            create.id,
            create.r,
            create.g,
            create.b,
            create.a,
        ),
    }
}

fn createBuffer(
    self: *WayringSinglePixelBuffer,
    manager: *Manager,
    id: u32,
    r: u32,
    g: u32,
    b: u32,
    a: u32,
) !void {
    try self.buffers.ensureUnusedCapacity(self.allocator, 1);
    const buffer = try self.allocator.create(Buffer);
    errdefer self.allocator.destroy(buffer);
    buffer.* = .{
        .owner = self,
        .client = manager.client,
        .resource = .init(self.allocator, id, 1, .client, manager.client.ownerHooks()),
        .pixel = packArgb(r, g, b, a),
    };
    errdefer {
        buffer.resource.destroy();
        buffer.resource.deinit();
    }
    try buffer.resource.setHandler(Buffer, buffer, handleBuffer, null);
    try manager.client.materialize(&buffer.resource.runtime);
    self.buffers.appendAssumeCapacity(buffer);
}

fn handleBuffer(resource: *protocol.wl_buffer.Resource, request: protocol.wl_buffer.Request, buffer: *Buffer) !void {
    _ = resource;
    switch (request) {
        .destroy => buffer.owner.destroyBuffer(buffer),
    }
}

fn destroyManager(self: *WayringSinglePixelBuffer, manager: *Manager) void {
    for (self.managers.items, 0..) |candidate, index| {
        if (candidate != manager) continue;
        _ = self.managers.swapRemove(index);
        manager.resource.destroy();
        manager.resource.deinit();
        self.allocator.destroy(manager);
        return;
    }
}

fn destroyBuffer(self: *WayringSinglePixelBuffer, buffer: *Buffer) void {
    for (self.buffers.items, 0..) |candidate, index| {
        if (candidate != buffer) continue;
        _ = self.buffers.swapRemove(index);
        buffer.resource.destroy();
        buffer.resource.deinit();
        self.allocator.destroy(buffer);
        return;
    }
}

fn resolveThunk(context: *anyopaque, resource: *server.Resource) ?u32 {
    const self: *WayringSinglePixelBuffer = @ptrCast(@alignCast(context));
    for (self.buffers.items) |buffer| {
        if (&buffer.resource.runtime == resource and resource.state() == .live)
            return buffer.pixel;
    }
    return null;
}

fn channel8(value: u32) u32 {
    return @intCast((@as(u64, value) * 255 + std.math.maxInt(u32) / 2) / std.math.maxInt(u32));
}

fn packArgb(r: u32, g: u32, b: u32, a: u32) u32 {
    return channel8(a) << 24 | channel8(r) << 16 | channel8(g) << 8 | channel8(b);
}

test "single-pixel protocol descriptor and full-range channel conversion" {
    try std.testing.expectEqualStrings("wp_single_pixel_buffer_manager_v1", protocol.wp_single_pixel_buffer_manager_v1.interface.name);
    try std.testing.expectEqual(@as(u32, 1), protocol.wp_single_pixel_buffer_manager_v1.interface.version);

    try std.testing.expectEqual(@as(u32, 0), channel8(0));
    try std.testing.expectEqual(@as(u32, 128), channel8(0x80808080));
    try std.testing.expectEqual(@as(u32, 255), channel8(std.math.maxInt(u32)));
    try std.testing.expectEqual(@as(u32, 0xff00_8000), packArgb(0, 0x80808080, 0, std.math.maxInt(u32)));
}
