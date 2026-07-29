//! Immutable one-pixel wl_buffer resources.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");

const wl = wayland.server.wl;
const wp = wayland.server.wp;

allocator: std.mem.Allocator,
global: *wl.Global,
buffer_count: usize = 0,

pub fn init(self: *Self, allocator: std.mem.Allocator, display: *wl.Server) !void {
    self.* = .{
        .allocator = allocator,
        .global = try wl.Global.create(
            display,
            wp.SinglePixelBufferManagerV1,
            1,
            *Self,
            self,
            bind,
        ),
    };
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.buffer_count == 0);
    self.global.destroy();
    self.* = undefined;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = wp.SinglePixelBufferManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, managerRequest, null, self);
}

fn managerRequest(
    resource: *wp.SinglePixelBufferManagerV1,
    request: wp.SinglePixelBufferManagerV1.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .create_u32_rgba_buffer => |create| Buffer.create(
            self,
            resource.getClient(),
            create.id,
            pixelFromComponents(create.r, create.g, create.b, create.a),
        ) catch resource.postNoMemory(),
    }
}

pub const Buffer = struct {
    manager: *Self,
    pixel: u32,

    // Optimized builds may merge identical wl_buffer request handlers, so the
    // implementation address cannot also serve as the resource type identity.
    var implementation_token: u8 = undefined;

    fn create(
        manager: *Self,
        client: *wl.Client,
        id: u32,
        pixel: u32,
    ) !void {
        const resource = try wl.Buffer.create(client, 1, id);
        errdefer resource.destroy();
        const self = try manager.allocator.create(Buffer);
        self.* = .{ .manager = manager, .pixel = pixel };
        manager.buffer_count += 1;
        const raw_resource: *wl.Resource = @ptrCast(resource);
        raw_resource.setDispatcher(
            dispatchRequest,
            &implementation_token,
            self,
            handleDestroy,
        );
    }

    pub fn fromResource(resource: *wl.Buffer) ?*Buffer {
        const raw_resource: *wl.Resource = @ptrCast(resource);
        if (wl_resource_instance_of(
            raw_resource,
            @ptrCast(wl.Buffer.interface),
            &implementation_token,
        ) == 0) return null;
        return @ptrCast(@alignCast(resource.getUserData().?));
    }

    fn dispatchRequest(
        _: ?*const anyopaque,
        resource: *wl.Resource,
        opcode: u32,
        _: *const wl.Message,
        _: [*]wl.Argument,
    ) callconv(.c) c_int {
        switch (opcode) {
            0 => resource.destroy(),
            else => unreachable,
        }
        return 0;
    }

    fn handleDestroy(resource: *wl.Resource) callconv(.c) void {
        const self: *Buffer = @ptrCast(@alignCast(resource.getUserData().?));
        self.manager.buffer_count -= 1;
        self.manager.allocator.destroy(self);
    }
};

fn pixelFromComponents(red: u32, green: u32, blue: u32, alpha: u32) u32 {
    return @as(u32, component(alpha)) << 24 |
        @as(u32, component(red)) << 16 |
        @as(u32, component(green)) << 8 |
        component(blue);
}

fn component(value: u32) u8 {
    const maximum = std.math.maxInt(u32);
    return @intCast((@as(u64, value) * 255 + maximum / 2) / maximum);
}

extern fn wl_resource_instance_of(
    resource: *wl.Resource,
    interface: *const anyopaque,
    implementation: *const anyopaque,
) c_int;

test "protocol components preserve premultiplied channel values" {
    try std.testing.expectEqual(
        @as(u32, 0x8080_8000),
        pixelFromComponents(0x8000_0000, 0x8000_0000, 0, 0x8000_0000),
    );
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), pixelFromComponents(
        std.math.maxInt(u32),
        std.math.maxInt(u32),
        std.math.maxInt(u32),
        std.math.maxInt(u32),
    ));
}
