//! GBM allocation for DRM scanout buffers shared with a GPU renderer.

const Self = @This();

const std = @import("std");
const render = @import("../render/types.zig");

const c = @cImport({
    @cInclude("gbm.h");
});

device: *c.gbm_device,

pub const Plane = struct {
    fd: std.posix.fd_t = -1,
    handle: u32 = 0,
    stride: u32 = 0,
    offset: u32 = 0,
};

/// Owns the GBM buffer object and every exported plane descriptor.
/// Call deinit exactly once.
pub const Buffer = struct {
    bo: *c.gbm_bo,
    fd: std.posix.fd_t,
    format: u32,
    handle: u32,
    stride: u32,
    offset: u32,
    modifier: u64,
    planes: [render.max_dmabuf_planes]Plane,
    plane_count: u8,

    pub fn planeSlice(self: *const Buffer) []const Plane {
        return self.planes[0..self.plane_count];
    }

    pub fn deinit(self: *Buffer) void {
        for (self.planeSlice()) |plane| _ = std.c.close(plane.fd);
        c.gbm_bo_destroy(self.bo);
        self.* = undefined;
    }
};

pub fn init(fd: std.posix.fd_t) !Self {
    return .{ .device = c.gbm_create_device(fd) orelse return error.CreateDeviceFailed };
}

pub fn deinit(self: *Self) void {
    c.gbm_device_destroy(self.device);
    self.* = undefined;
}

pub fn createBuffer(
    self: *Self,
    size: render.Size,
    format: u32,
    modifiers: []const u64,
) !Buffer {
    std.debug.assert(modifiers.len > 0);
    const flags = c.GBM_BO_USE_SCANOUT | c.GBM_BO_USE_RENDERING;
    const bo = c.gbm_bo_create_with_modifiers2(
        self.device,
        size.width,
        size.height,
        format,
        modifiers.ptr,
        @intCast(modifiers.len),
        flags,
    ) orelse return error.CreateBufferFailed;
    return exportBuffer(bo);
}

pub fn createImplicitBuffer(self: *Self, size: render.Size, format: u32) !Buffer {
    const bo = c.gbm_bo_create(
        self.device,
        size.width,
        size.height,
        format,
        c.GBM_BO_USE_SCANOUT | c.GBM_BO_USE_RENDERING,
    ) orelse return error.CreateBufferFailed;
    return exportBuffer(bo);
}

fn exportBuffer(bo: *c.gbm_bo) !Buffer {
    errdefer c.gbm_bo_destroy(bo);
    const plane_count = c.gbm_bo_get_plane_count(bo);
    if (plane_count <= 0 or plane_count > render.max_dmabuf_planes) {
        return error.UnsupportedPlaneCount;
    }
    var planes: [render.max_dmabuf_planes]Plane = @splat(.{});
    var exported_count: usize = 0;
    errdefer {
        for (planes[0..exported_count]) |plane| _ = std.c.close(plane.fd);
    }
    for (planes[0..@intCast(plane_count)], 0..) |*plane, index| {
        const fd = c.gbm_bo_get_fd_for_plane(bo, @intCast(index));
        if (fd < 0) return error.ExportBufferFailed;
        plane.* = .{
            .fd = fd,
            .handle = c.gbm_bo_get_handle_for_plane(bo, @intCast(index)).u32,
            .stride = c.gbm_bo_get_stride_for_plane(bo, @intCast(index)),
            .offset = c.gbm_bo_get_offset(bo, @intCast(index)),
        };
        exported_count += 1;
    }
    return .{
        .bo = bo,
        .fd = planes[0].fd,
        .format = c.gbm_bo_get_format(bo),
        .handle = planes[0].handle,
        .stride = planes[0].stride,
        .offset = planes[0].offset,
        .modifier = c.gbm_bo_get_modifier(bo),
        .planes = planes,
        .plane_count = @intCast(plane_count),
    };
}
