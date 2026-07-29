//! Imports client DMA-BUFs as DRM framebuffers and owns the resulting cache.
//! Imported GEM handles are transient; framebuffer IDs remain owned until `clear`.

const ScanoutFramebufferCache = @This();

const std = @import("std");
const render = @import("../render/types.zig");

const c = @cImport({
    @cInclude("libdrm/drm_fourcc.h");
    @cInclude("xf86drm.h");
    @cInclude("xf86drmMode.h");
});
const log = std.log.scoped(.drm);
const drm_format_mod_linear: u64 = 0;
const maximum_framebuffers = 8;

allocator: std.mem.Allocator,
framebuffers: std.AutoHashMapUnmanaged(Key, Framebuffer) = .empty,
frame_number: u64 = 0,

pub const Key = struct {
    cache_id: u64,
    format: u32,
};

pub const Input = struct {
    fd: std.posix.fd_t,
    buffer: render.PixelBuffer,
    formats: []const render.DmabufFormatModifier,
    implicit_scanout: bool,
    pinned_keys: []const ?Key,
};

pub const Result = struct {
    key: Key,
    framebuffer_id: u32,
};

const Framebuffer = struct {
    framebuffer_id: u32,
    size: render.Size,
    format: u32,
    modifier: u64,
    plane_count: u8,
    strides: [render.max_dmabuf_planes]u32,
    offsets: [render.max_dmabuf_planes]u32,
    last_used: u64,

    fn matchesLayout(
        framebuffer: Framebuffer,
        size: render.Size,
        source: render.DmabufSource,
    ) bool {
        if (!std.meta.eql(framebuffer.size, size) or
            framebuffer.format != source.format or
            framebuffer.modifier != source.modifier or
            framebuffer.plane_count != source.plane_count)
        {
            return false;
        }
        for (source.planeSlice(), 0..) |plane, index| {
            if (framebuffer.strides[index] != plane.stride or
                framebuffer.offsets[index] != plane.offset) return false;
        }
        return true;
    }
};

pub fn init(allocator: std.mem.Allocator) ScanoutFramebufferCache {
    return .{ .allocator = allocator };
}

/// Requires `clear` while the DRM device is still available.
pub fn deinit(self: *ScanoutFramebufferCache) void {
    std.debug.assert(self.framebuffers.count() == 0);
    self.framebuffers.deinit(self.allocator);
    self.* = undefined;
}

/// Borrows all input data for this call. The returned framebuffer ID remains
/// cache-owned; include its key in later calls while KMS may still reference it.
pub fn getOrImport(
    self: *ScanoutFramebufferCache,
    input: Input,
) !Result {
    const source = input.buffer.dmabuf orelse return error.InvalidBuffer;
    const source_cache = input.buffer.source_cache orelse return error.InvalidBuffer;
    if (source.plane_count == 0 or source.plane_count > render.max_dmabuf_planes) {
        return error.InvalidBuffer;
    }
    const framebuffer_format = framebufferFormat(
        input.formats,
        source.format,
        source.modifier,
    ) orelse return error.UnsupportedModifier;
    const modifier_supported = render.DmabufFormatModifier.contains(
        input.formats,
        framebuffer_format,
        source.modifier,
    );
    if (!modifier_supported and !(input.implicit_scanout and
        source.modifier == drm_format_mod_linear)) return error.UnsupportedModifier;
    const key: Key = .{
        .cache_id = source_cache.id,
        .format = framebuffer_format,
    };
    self.frame_number +%= 1;
    if (self.frame_number == 0) self.frame_number = 1;
    if (self.framebuffers.getPtr(key)) |framebuffer| {
        if (!framebuffer.matchesLayout(input.buffer.size, source)) {
            return error.CacheIdentityMismatch;
        }
        framebuffer.last_used = self.frame_number;
        return .{ .key = key, .framebuffer_id = framebuffer.framebuffer_id };
    }
    try self.makeRoom(input.fd, input.pinned_keys);

    var handles: [render.max_dmabuf_planes]u32 = @splat(0);
    defer closeImportedBufferHandles(input.fd, handles);
    var pitches: [render.max_dmabuf_planes]u32 = @splat(0);
    var offsets: [render.max_dmabuf_planes]u32 = @splat(0);
    for (source.planeSlice(), 0..) |plane, index| {
        if (c.drmPrimeFDToHandle(input.fd, plane.fd, &handles[index]) != 0) {
            return error.ImportHandleFailed;
        }
        pitches[index] = plane.stride;
        offsets[index] = plane.offset;
    }
    var framebuffer_id: u32 = 0;
    var add_result: c_int = -1;
    if (modifier_supported) {
        var modifiers: [render.max_dmabuf_planes]u64 = @splat(0);
        for (modifiers[0..source.plane_count]) |*modifier| modifier.* = source.modifier;
        add_result = c.drmModeAddFB2WithModifiers(
            input.fd,
            input.buffer.size.width,
            input.buffer.size.height,
            framebuffer_format,
            &handles,
            &pitches,
            &offsets,
            &modifiers,
            &framebuffer_id,
            c.DRM_MODE_FB_MODIFIERS,
        );
    }
    if (add_result != 0 and source.modifier == drm_format_mod_linear and input.implicit_scanout) {
        add_result = c.drmModeAddFB2(
            input.fd,
            input.buffer.size.width,
            input.buffer.size.height,
            framebuffer_format,
            &handles,
            &pitches,
            &offsets,
            &framebuffer_id,
            0,
        );
    }
    if (add_result != 0) return error.AddFramebufferFailed;
    errdefer _ = c.drmModeRmFB(input.fd, framebuffer_id);

    try self.framebuffers.put(self.allocator, key, .{
        .framebuffer_id = framebuffer_id,
        .size = input.buffer.size,
        .format = source.format,
        .modifier = source.modifier,
        .plane_count = source.plane_count,
        .strides = pitches,
        .offsets = offsets,
        .last_used = self.frame_number,
    });
    return .{ .key = key, .framebuffer_id = framebuffer_id };
}

pub fn matchesLayout(
    self: *const ScanoutFramebufferCache,
    key: Key,
    size: render.Size,
    source: render.DmabufSource,
) bool {
    const framebuffer = self.framebuffers.get(key) orelse return false;
    return framebuffer.matchesLayout(size, source);
}

pub fn clear(self: *ScanoutFramebufferCache, fd: std.posix.fd_t) void {
    while (self.framebuffers.count() > 0) {
        var iterator = self.framebuffers.iterator();
        const key = iterator.next().?.key_ptr.*;
        self.remove(fd, key);
    }
}

fn makeRoom(
    self: *ScanoutFramebufferCache,
    fd: std.posix.fd_t,
    pinned_keys: []const ?Key,
) !void {
    if (self.framebuffers.count() < maximum_framebuffers) return;
    var oldest_key: ?Key = null;
    var oldest_frame: u64 = std.math.maxInt(u64);
    var iterator = self.framebuffers.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        if (isPinned(key, pinned_keys) or entry.value_ptr.last_used >= oldest_frame) continue;
        oldest_key = key;
        oldest_frame = entry.value_ptr.last_used;
    }
    self.remove(fd, oldest_key orelse return error.CacheFull);
}

fn remove(self: *ScanoutFramebufferCache, fd: std.posix.fd_t, key: Key) void {
    const framebuffer = self.framebuffers.fetchRemove(key).?.value;
    if (c.drmModeRmFB(fd, framebuffer.framebuffer_id) != 0) {
        log.err("failed to remove scanout framebuffer {d}", .{framebuffer.framebuffer_id});
    }
}

fn isPinned(key: Key, pinned_keys: []const ?Key) bool {
    for (pinned_keys) |pinned| {
        if (pinned) |candidate| if (std.meta.eql(candidate, key)) return true;
    }
    return false;
}

fn framebufferFormat(
    formats: []const render.DmabufFormatModifier,
    source_format: u32,
    modifier: u64,
) ?u32 {
    const format = render.DmabufFormat.fromFourcc(source_format) orelse return null;
    const opaque_format = @intFromEnum(format.opaqueFormat());
    if (render.DmabufFormatModifier.contains(formats, opaque_format, modifier)) {
        return opaque_format;
    }
    if (render.DmabufFormatModifier.contains(formats, source_format, modifier)) {
        return source_format;
    }
    return null;
}

fn closeImportedBufferHandles(
    fd: std.posix.fd_t,
    handles: [render.max_dmabuf_planes]u32,
) void {
    handle_loop: for (handles, 0..) |handle, index| {
        if (handle == 0) continue;
        for (handles[0..index]) |previous| if (previous == handle) continue :handle_loop;
        if (c.drmCloseBufferHandle(fd, handle) != 0) {
            log.err("failed to close imported DRM buffer handle {d}", .{handle});
        }
    }
}

test "scanout framebuffer prefers an opaque format with the same memory layout" {
    const formats = [_]render.DmabufFormatModifier{
        .{ .format = c.DRM_FORMAT_ARGB8888, .modifier = 7 },
        .{ .format = c.DRM_FORMAT_XRGB8888, .modifier = 7 },
        .{ .format = c.DRM_FORMAT_ABGR8888, .modifier = 9 },
    };
    try std.testing.expectEqual(
        c.DRM_FORMAT_XRGB8888,
        framebufferFormat(&formats, c.DRM_FORMAT_ARGB8888, 7).?,
    );
    try std.testing.expectEqual(
        c.DRM_FORMAT_ABGR8888,
        framebufferFormat(&formats, c.DRM_FORMAT_ABGR8888, 9).?,
    );
    try std.testing.expect(framebufferFormat(&formats, c.DRM_FORMAT_XBGR8888, 9) == null);
}

test "scanout framebuffer cache validates every DMA-BUF plane" {
    const NoopSource = struct {
        fn retain(_: *anyopaque) void {}
        fn release(_: *anyopaque) void {}
        fn begin(_: *anyopaque) bool {
            return true;
        }
        fn end(_: *anyopaque) bool {
            return true;
        }
        fn exportFence(_: *anyopaque, _: u8) ?std.posix.fd_t {
            return null;
        }
    };

    var context: u8 = 0;
    var source: render.DmabufSource = .{
        .context = &context,
        .format = @intFromEnum(render.DmabufFormat.nv12),
        .modifier = 7,
        .planes = .{
            .{ .stride = 128, .offset = 0 },
            .{ .stride = 64, .offset = 8192 },
            .{},
            .{},
        },
        .plane_count = 2,
        .y_inverted = false,
        .force_opaque = true,
        .retain = NoopSource.retain,
        .release = NoopSource.release,
        .begin_cpu_read = NoopSource.begin,
        .end_cpu_read = NoopSource.end,
        .export_read_fence = NoopSource.exportFence,
    };
    const framebuffer: Framebuffer = .{
        .framebuffer_id = 1,
        .size = .{ .width = 64, .height = 64 },
        .format = source.format,
        .modifier = source.modifier,
        .plane_count = source.plane_count,
        .strides = .{ 128, 64, 0, 0 },
        .offsets = .{ 0, 8192, 0, 0 },
        .last_used = 1,
    };
    try std.testing.expect(framebuffer.matchesLayout(framebuffer.size, source));
    source.planes[1].offset += 64;
    try std.testing.expect(!framebuffer.matchesLayout(framebuffer.size, source));
}
