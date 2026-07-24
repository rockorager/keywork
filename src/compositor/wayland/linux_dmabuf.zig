//! Linux DMA-BUF wl_buffer import and format-modifier feedback.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const render = @import("../render/types.zig");

const wl = wayland.server.wl;
const zwp = wayland.server.zwp;
const log = std.log.scoped(.linux_dmabuf);

const linux = @cImport({
    @cInclude("libdrm/drm_fourcc.h");
    @cInclude("linux/dma-buf.h");
    @cInclude("linux/memfd.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/sysmacros.h");
});

const max_planes = render.max_dmabuf_planes;
const invalid_modifier: u64 = 0x00ff_ffff_ffff_ffff;
const linear_modifier: u64 = 0;
const argb8888: u32 = linux.DRM_FORMAT_ARGB8888;
const xrgb8888: u32 = linux.DRM_FORMAT_XRGB8888;
const abgr8888: u32 = linux.DRM_FORMAT_ABGR8888;
const xbgr8888: u32 = linux.DRM_FORMAT_XBGR8888;
const nv12: u32 = linux.DRM_FORMAT_NV12;
const p010: u32 = linux.DRM_FORMAT_P010;
const fallback_formats = [_]render.DmabufFormatModifier{
    .{ .format = argb8888, .modifier = linear_modifier },
    .{ .format = xrgb8888, .modifier = linear_modifier },
    .{ .format = abgr8888, .modifier = linear_modifier },
    .{ .format = xbgr8888, .modifier = linear_modifier },
};

comptime {
    std.debug.assert(argb8888 == @intFromEnum(render.DmabufFormat.argb8888));
    std.debug.assert(xrgb8888 == @intFromEnum(render.DmabufFormat.xrgb8888));
    std.debug.assert(abgr8888 == @intFromEnum(render.DmabufFormat.abgr8888));
    std.debug.assert(xbgr8888 == @intFromEnum(render.DmabufFormat.xbgr8888));
    std.debug.assert(nv12 == @intFromEnum(render.DmabufFormat.nv12));
    std.debug.assert(p010 == @intFromEnum(render.DmabufFormat.p010));
}

pub const Device = linux.dev_t;

pub const CaptureFormat = struct {
    format: u32,
    modifier: u64,
};

pub const capture_formats = [_]CaptureFormat{
    .{ .format = argb8888, .modifier = linear_modifier },
    .{ .format = xrgb8888, .modifier = linear_modifier },
};

allocator: std.mem.Allocator,
io: std.Io,
global: *wl.Global,
feedback_state: ?FeedbackState,
params_count: usize,
buffer_count: usize,
feedback_count: usize,
supported_pairs: []const render.DmabufFormatModifier,
source_validator: ?render.DmabufSourceValidator,

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    io: std.Io,
    display: *wl.Server,
    renderer_device_id: ?render.DrmDeviceId,
    scanout_device_id: ?render.DrmDeviceId,
    sampled_pairs: []const render.DmabufFormatModifier,
    scanout_pairs: []const render.DmabufFormatModifier,
    source_validator: ?render.DmabufSourceValidator,
) !void {
    const supported_pairs = if (sampled_pairs.len != 0) sampled_pairs else &fallback_formats;
    var feedback_state = FeedbackState.init(
        io,
        renderer_device_id,
        scanout_device_id,
        allocator,
        supported_pairs,
        scanout_pairs,
    ) catch |err| unavailable: {
        log.info("DMA-BUF feedback unavailable: {t}", .{err});
        break :unavailable null;
    };
    errdefer if (feedback_state) |*state| state.deinit(allocator, io);
    self.* = .{
        .allocator = allocator,
        .io = io,
        .global = try wl.Global.create(
            display,
            zwp.LinuxDmabufV1,
            if (feedback_state == null) 3 else 6,
            *Self,
            self,
            bind,
        ),
        .feedback_state = feedback_state,
        .params_count = 0,
        .buffer_count = 0,
        .feedback_count = 0,
        .supported_pairs = supported_pairs,
        .source_validator = source_validator,
    };
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.params_count == 0);
    std.debug.assert(self.buffer_count == 0);
    std.debug.assert(self.feedback_count == 0);
    self.global.destroy();
    if (self.feedback_state) |*state| state.deinit(self.allocator, self.io);
    self.* = undefined;
}

pub fn allocationDevice(self: *const Self) ?Device {
    return if (self.feedback_state) |state| state.device else null;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = zwp.LinuxDmabufV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleRequest, null, self);
    if (version >= zwp.LinuxDmabufV1.Request.get_default_feedback_since_version) {
        return;
    } else if (version >= zwp.LinuxDmabufV1.modifier_since_version) {
        for (self.supported_pairs) |pair| {
            resource.sendModifier(pair.format, @intCast(pair.modifier >> 32), @truncate(pair.modifier));
        }
    } else {
        for (self.supported_pairs, 0..) |pair, index| {
            if (pair.modifier != linear_modifier) continue;
            for (self.supported_pairs[0..index]) |previous| {
                if (previous.modifier == linear_modifier and previous.format == pair.format) break;
            } else resource.sendFormat(pair.format);
        }
    }
}

fn handleRequest(
    resource: *zwp.LinuxDmabufV1,
    request: zwp.LinuxDmabufV1.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .create_params => |create| Params.create(
            self,
            resource.getClient(),
            resource.getVersion(),
            create.params_id,
        ) catch resource.postNoMemory(),
        .get_default_feedback => |get| Feedback.create(self, resource, get.id),
        .get_surface_feedback => |get| Feedback.create(self, resource, get.id),
    }
}

const FormatTableEntry = extern struct {
    format: u32,
    padding: u32,
    modifier: u64,
};

const FeedbackState = struct {
    device: linux.dev_t,
    scanout_device: ?linux.dev_t,
    file: std.Io.File,
    pairs: []render.DmabufFormatModifier,
    sampling_indices: []align(4) u16,
    scanout_indices: []align(4) u16,

    fn init(
        io: std.Io,
        renderer_device_id: ?render.DrmDeviceId,
        scanout_device_id: ?render.DrmDeviceId,
        allocator: std.mem.Allocator,
        sampled_pairs: []const render.DmabufFormatModifier,
        scanout_pairs: []const render.DmabufFormatModifier,
    ) !FeedbackState {
        if (sampled_pairs.len == 0 or sampled_pairs.len > std.math.maxInt(u16) + 1 or
            sampled_pairs.len > std.math.maxInt(u32) / @sizeOf(FormatTableEntry))
            return error.InvalidFormatTable;
        const device = if (renderer_device_id) |id|
            linux.makedev(id.major, id.minor)
        else
            findRenderDevice() orelse return error.NoRenderDevice;
        const scanout_device = if (scanout_device_id) |id|
            linux.makedev(id.major, id.minor)
        else
            null;
        comptime std.debug.assert(@sizeOf(FormatTableEntry) == 16);
        const pairs = try allocator.dupe(render.DmabufFormatModifier, sampled_pairs);
        errdefer allocator.free(pairs);
        const sampling_indices = try allocator.alignedAlloc(u16, .fromByteUnits(4), pairs.len);
        errdefer allocator.free(sampling_indices);
        var scanout_count: usize = 0;
        for (pairs, 0..) |pair, index| {
            sampling_indices[index] = @intCast(index);
            if (render.DmabufFormatModifier.contains(scanout_pairs, pair.format, pair.modifier)) scanout_count += 1;
        }
        const scanout_indices = try allocator.alignedAlloc(u16, .fromByteUnits(4), scanout_count);
        errdefer allocator.free(scanout_indices);
        var scanout_index: usize = 0;
        for (pairs, 0..) |pair, index| if (render.DmabufFormatModifier.contains(
            scanout_pairs,
            pair.format,
            pair.modifier,
        )) {
            scanout_indices[scanout_index] = @intCast(index);
            scanout_index += 1;
        };
        const entries = try allocator.alloc(FormatTableEntry, pairs.len);
        defer allocator.free(entries);
        for (pairs, entries) |pair, *entry| entry.* = .{
            .format = pair.format,
            .padding = 0,
            .modifier = pair.modifier,
        };

        const fd = try std.posix.memfd_create(
            "keywork-dmabuf-formats",
            linux.MFD_CLOEXEC | linux.MFD_ALLOW_SEALING,
        );
        const file: std.Io.File = .{
            .handle = fd,
            .flags = .{ .nonblocking = false },
        };
        errdefer file.close(io);
        const bytes = std.mem.sliceAsBytes(entries);
        try file.setLength(io, bytes.len);
        try file.writePositionalAll(io, bytes, 0);
        const seals = std.os.linux.F.SEAL_SHRINK | std.os.linux.F.SEAL_GROW |
            std.os.linux.F.SEAL_WRITE | std.os.linux.F.SEAL_SEAL;
        const seal_result = std.os.linux.fcntl(fd, std.os.linux.F.ADD_SEALS, seals);
        if (std.posix.errno(seal_result) != .SUCCESS) return error.SealFailed;
        return .{
            .device = device,
            .scanout_device = scanout_device,
            .file = file,
            .pairs = pairs,
            .sampling_indices = sampling_indices,
            .scanout_indices = scanout_indices,
        };
    }

    fn deinit(self: *FeedbackState, allocator: std.mem.Allocator, io: std.Io) void {
        self.file.close(io);
        allocator.free(self.pairs);
        allocator.free(self.sampling_indices);
        allocator.free(self.scanout_indices);
    }
};

fn findRenderDevice() ?linux.dev_t {
    for (128..192) |minor| {
        var path_buffer: [64]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(
            &path_buffer,
            "/dev/dri/renderD{d}",
            .{minor},
            0,
        ) catch unreachable;
        var stat: linux.struct_stat = undefined;
        if (linux.stat(path.ptr, &stat) < 0) continue;
        if (stat.st_mode & linux.S_IFMT != linux.S_IFCHR) continue;
        return stat.st_rdev;
    }
    return null;
}

const Feedback = struct {
    manager: *Self,

    fn create(manager: *Self, factory: *zwp.LinuxDmabufV1, id: u32) void {
        const state = manager.feedback_state orelse unreachable;
        const resource = zwp.LinuxDmabufFeedbackV1.create(
            factory.getClient(),
            factory.getVersion(),
            id,
        ) catch {
            factory.postNoMemory();
            return;
        };
        const self = manager.allocator.create(Feedback) catch {
            resource.postNoMemory();
            resource.destroy();
            return;
        };
        self.* = .{ .manager = manager };
        manager.feedback_count += 1;
        resource.setHandler(*Feedback, Feedback.handleRequest, Feedback.handleDestroy, self);

        var device = state.device;
        var device_array: wl.Array = .{
            .size = @sizeOf(linux.dev_t),
            .alloc = @sizeOf(linux.dev_t),
            .data = @ptrCast(&device),
        };
        var scanout_indices_array: wl.Array = .{
            .size = state.scanout_indices.len * @sizeOf(u16),
            .alloc = state.scanout_indices.len * @sizeOf(u16),
            .data = state.scanout_indices.ptr,
        };
        var indices_array: wl.Array = .{
            .size = state.sampling_indices.len * @sizeOf(u16),
            .alloc = state.sampling_indices.len * @sizeOf(u16),
            .data = state.sampling_indices.ptr,
        };
        resource.sendFormatTable(
            state.file.handle,
            @intCast(state.pairs.len * @sizeOf(FormatTableEntry)),
        );
        if (resource.getVersion() < 6) resource.sendMainDevice(&device_array);
        if (state.scanout_device) |scanout_device| if (state.scanout_indices.len != 0) {
            var scanout_device_value = scanout_device;
            var scanout_device_array: wl.Array = .{
                .size = @sizeOf(linux.dev_t),
                .alloc = @sizeOf(linux.dev_t),
                .data = @ptrCast(&scanout_device_value),
            };
            resource.sendTrancheTargetDevice(&scanout_device_array);
            resource.sendTrancheFlags(.{ .scanout = true });
            resource.sendTrancheFormats(&scanout_indices_array);
            resource.sendTrancheDone();
        };
        resource.sendTrancheTargetDevice(&device_array);
        resource.sendTrancheFlags(if (resource.getVersion() >= 6)
            .{ .sampling = true }
        else
            .{});
        resource.sendTrancheFormats(&indices_array);
        resource.sendTrancheDone();
        resource.sendDone();
    }

    fn handleRequest(
        resource: *zwp.LinuxDmabufFeedbackV1,
        request: zwp.LinuxDmabufFeedbackV1.Request,
        _: *Feedback,
    ) void {
        switch (request) {
            .destroy => resource.destroy(),
        }
    }

    fn handleDestroy(_: *zwp.LinuxDmabufFeedbackV1, self: *Feedback) void {
        self.manager.feedback_count -= 1;
        self.manager.allocator.destroy(self);
    }
};

const Plane = struct {
    fd: std.posix.fd_t,
    offset: u32,
    stride: u32,
    modifier: u64,

    fn close(self: Plane) void {
        _ = std.c.close(self.fd);
    }
};

const Params = struct {
    manager: *Self,
    resource: *zwp.LinuxBufferParamsV1,
    planes: [max_planes]?Plane,
    sampling_device: ?linux.dev_t,
    used: bool,

    fn create(
        manager: *Self,
        client: *wl.Client,
        version: u32,
        id: u32,
    ) error{ OutOfMemory, ResourceCreateFailed }!void {
        const resource = try zwp.LinuxBufferParamsV1.create(client, version, id);
        errdefer resource.destroy();
        const self = manager.allocator.create(Params) catch return error.OutOfMemory;
        self.* = .{
            .manager = manager,
            .resource = resource,
            .planes = @splat(null),
            .sampling_device = null,
            .used = false,
        };
        manager.params_count += 1;
        resource.setHandler(*Params, Params.handleRequest, Params.handleDestroy, self);
    }

    fn handleRequest(
        resource: *zwp.LinuxBufferParamsV1,
        request: zwp.LinuxBufferParamsV1.Request,
        self: *Params,
    ) void {
        switch (request) {
            .destroy => resource.destroy(),
            .add => |add| self.addPlane(resource, .{
                .fd = add.fd,
                .offset = add.offset,
                .stride = add.stride,
                .modifier = @as(u64, add.modifier_hi) << 32 | add.modifier_lo,
            }, add.plane_idx),
            .create => |create_request| self.createBuffer(
                create_request.width,
                create_request.height,
                create_request.format,
                create_request.flags,
                null,
            ),
            .create_immed => |create_request| self.createBuffer(
                create_request.width,
                create_request.height,
                create_request.format,
                create_request.flags,
                create_request.buffer_id,
            ),
            .set_sampling_device => |set| self.setSamplingDevice(resource, set.device),
        }
    }

    fn setSamplingDevice(
        self: *Params,
        resource: *zwp.LinuxBufferParamsV1,
        array: *wl.Array,
    ) void {
        if (self.used) {
            resource.postError(.already_used, "buffer parameters were already used");
            return;
        }
        self.sampling_device = deviceFromArray(array) catch {
            resource.postError(.invalid_dev_t_size, "sampling device has invalid size");
            return;
        };
    }

    fn addPlane(
        self: *Params,
        resource: *zwp.LinuxBufferParamsV1,
        plane: Plane,
        index: u32,
    ) void {
        if (self.used) {
            plane.close();
            resource.postError(.already_used, "buffer parameters were already used");
            return;
        }
        if (index >= max_planes) {
            plane.close();
            resource.postError(.plane_idx, "DMA-BUF plane index is out of bounds");
            return;
        }
        if (self.planes[index] != null) {
            plane.close();
            resource.postError(.plane_set, "DMA-BUF plane was already set");
            return;
        }
        self.planes[index] = plane;
    }

    fn createBuffer(
        self: *Params,
        width: i32,
        height: i32,
        format: u32,
        flags: zwp.LinuxBufferParamsV1.Flags,
        immediate_id: ?u32,
    ) void {
        if (self.used) {
            self.resource.postError(.already_used, "buffer parameters were already used");
            return;
        }
        self.used = true;

        const descriptor = validateDescriptor(
            self.planes,
            width,
            height,
            format,
            flags,
            self.resource.getVersion() < 3,
            self.manager.supported_pairs,
        ) catch |err| {
            switch (err) {
                error.Incomplete => self.resource.postError(
                    .incomplete,
                    "DMA-BUF does not have the planes required by its format",
                ),
                error.InvalidFormat => self.resource.postError(
                    .invalid_format,
                    "unsupported DMA-BUF format or modifier",
                ),
                error.InvalidDimensions => self.resource.postError(
                    .invalid_dimensions,
                    "DMA-BUF dimensions are invalid",
                ),
                error.OutOfBounds => self.resource.postError(
                    .out_of_bounds,
                    "DMA-BUF plane does not contain the requested image",
                ),
                error.ImportFailed => self.importFailed(immediate_id),
            }
            return;
        };
        if (self.sampling_device) |device| {
            const feedback = self.manager.feedback_state.?;
            if (device != feedback.device and
                (feedback.scanout_device == null or device != feedback.scanout_device.?))
            {
                self.importFailed(immediate_id);
                return;
            }
        }
        const format_info = render.DmabufFormat.fromFourcc(descriptor.format).?;
        if (descriptor.modifier != linear_modifier or !format_info.isPackedRgb()) {
            const validator = self.manager.source_validator orelse {
                self.importFailed(immediate_id);
                return;
            };
            validator.validate(validator.context, .{
                .size = descriptor.size,
                .format = descriptor.format,
                .modifier = descriptor.modifier,
                .planes = descriptor.renderPlanes(),
                .plane_count = descriptor.plane_count,
                .force_opaque = !format_info.hasAlpha(),
            }) catch {
                self.importFailed(immediate_id);
                return;
            };
        }
        if (descriptor.implicit_modifier) {
            log.warn("assuming a legacy implicit DMA-BUF has linear layout", .{});
        }

        const buffer = Buffer.create(
            self.manager,
            self.resource.getClient(),
            immediate_id orelse 0,
            descriptor,
        ) catch {
            self.resource.postNoMemory();
            return;
        };
        for (self.planes[0..descriptor.plane_count]) |*plane| plane.* = null;
        if (immediate_id == null) self.resource.sendCreated(buffer.resource.?);
    }

    fn importFailed(self: *Params, immediate_id: ?u32) void {
        if (immediate_id == null) {
            self.resource.sendFailed();
        } else {
            self.resource.postError(.invalid_wl_buffer, "DMA-BUF import failed");
        }
    }

    fn handleDestroy(_: *zwp.LinuxBufferParamsV1, self: *Params) void {
        for (self.planes) |plane| if (plane) |value| value.close();
        self.manager.params_count -= 1;
        self.manager.allocator.destroy(self);
    }
};

fn deviceFromArray(array: *const wl.Array) error{InvalidSize}!linux.dev_t {
    if (array.size != @sizeOf(linux.dev_t)) return error.InvalidSize;
    const data = array.data orelse return error.InvalidSize;
    const bytes: [*]const u8 = @ptrCast(data);
    var device: linux.dev_t = undefined;
    @memcpy(std.mem.asBytes(&device), bytes[0..@sizeOf(linux.dev_t)]);
    return device;
}

const DescriptorPlane = struct {
    plane: Plane,
    required_bytes: usize,
};

const Descriptor = struct {
    planes: [max_planes]DescriptorPlane,
    plane_count: u8,
    size: render.Size,
    format: u32,
    modifier: u64,
    implicit_modifier: bool,
    y_inverted: bool,

    fn renderPlanes(self: Descriptor) [max_planes]render.DmabufPlane {
        var planes: [max_planes]render.DmabufPlane = @splat(.{
            .fd = -1,
            .stride = 0,
            .offset = 0,
            .required_bytes = 0,
        });
        for (self.planes[0..self.plane_count], planes[0..self.plane_count]) |source, *destination| {
            destination.* = .{
                .fd = source.plane.fd,
                .stride = source.plane.stride,
                .offset = source.plane.offset,
                .required_bytes = source.required_bytes,
            };
        }
        return planes;
    }
};

const DescriptorError = error{
    Incomplete,
    InvalidFormat,
    InvalidDimensions,
    OutOfBounds,
    ImportFailed,
};

fn validateDescriptor(
    planes: [max_planes]?Plane,
    width: i32,
    height: i32,
    format: u32,
    flags: zwp.LinuxBufferParamsV1.Flags,
    allow_implicit_modifier: bool,
    supported_pairs: []const render.DmabufFormatModifier,
) DescriptorError!Descriptor {
    if (width <= 0 or height <= 0) return error.InvalidDimensions;
    const format_info = render.DmabufFormat.fromFourcc(format) orelse return error.InvalidFormat;
    if (!format_info.isPackedRgb() and (@rem(width, 2) != 0 or @rem(height, 2) != 0)) {
        return error.InvalidDimensions;
    }
    const plane_count = format_info.planeCount();
    for (planes[0..plane_count]) |plane| if (plane == null) return error.Incomplete;
    for (planes[plane_count..]) |plane| if (plane != null) return error.Incomplete;

    const first_plane = planes[0].?;
    for (planes[1..plane_count]) |plane| {
        if (plane.?.modifier != first_plane.modifier) return error.InvalidFormat;
    }
    const implicit_modifier = allow_implicit_modifier and first_plane.modifier == invalid_modifier;
    const effective_modifier = if (implicit_modifier)
        linear_modifier
    else
        first_plane.modifier;
    if (!render.DmabufFormatModifier.contains(supported_pairs, format, effective_modifier)) return error.InvalidFormat;
    const flag_bits: u32 = @bitCast(flags);
    if (flag_bits & ~@as(u32, 7) != 0 or flags.interlaced or flags.bottom_first) {
        return error.ImportFailed;
    }

    const size: render.Size = .{
        .width = @intCast(width),
        .height = @intCast(height),
    };
    var validated_planes: [max_planes]DescriptorPlane = @splat(.{
        .plane = .{ .fd = -1, .offset = 0, .stride = 0, .modifier = 0 },
        .required_bytes = 0,
    });
    for (planes[0..plane_count], 0..) |optional_plane, index| {
        const plane = optional_plane.?;
        const required_bytes = if (effective_modifier == linear_modifier) required: {
            const plane_index: u8 = @intCast(index);
            const row_bytes = format_info.planeRowBytes(plane_index, size.width).?;
            const plane_height = format_info.planeHeight(plane_index, size.height).?;
            const alignment = format_info.planeAlignment();
            if (plane.stride < row_bytes or plane.stride % alignment != 0 or
                plane.offset % alignment != 0) return error.OutOfBounds;
            const row_offset = std.math.mul(u64, plane_height - 1, plane.stride) catch
                return error.OutOfBounds;
            const required_offset = std.math.add(u64, plane.offset, row_offset) catch
                return error.OutOfBounds;
            const required_end = std.math.add(u64, required_offset, row_bytes) catch
                return error.OutOfBounds;
            if (required_end == 0 or required_end > std.math.maxInt(usize)) {
                return error.OutOfBounds;
            }
            const fd_size = std.c.lseek(plane.fd, 0, std.c.SEEK.END);
            if (fd_size < 0) return error.ImportFailed;
            if (required_end > @as(u64, @intCast(fd_size))) return error.OutOfBounds;

            if (!syncDmaBuf(plane.fd, linux.DMA_BUF_SYNC_READ)) return error.ImportFailed;
            const mapping = std.posix.mmap(
                null,
                @intCast(required_end),
                .{ .READ = true },
                .{ .TYPE = .SHARED },
                plane.fd,
                0,
            ) catch {
                _ = syncDmaBuf(plane.fd, linux.DMA_BUF_SYNC_READ | linux.DMA_BUF_SYNC_END);
                return error.ImportFailed;
            };
            std.posix.munmap(mapping);
            if (!syncDmaBuf(plane.fd, linux.DMA_BUF_SYNC_READ | linux.DMA_BUF_SYNC_END)) {
                return error.ImportFailed;
            }
            break :required @as(usize, @intCast(required_end));
        } else non_linear: {
            const fd_size = std.c.lseek(plane.fd, 0, std.c.SEEK.END);
            if (fd_size <= 0) return error.ImportFailed;
            if (@as(u64, @intCast(fd_size)) > std.math.maxInt(usize)) {
                return error.OutOfBounds;
            }
            break :non_linear @as(usize, @intCast(fd_size));
        };
        validated_planes[index] = .{ .plane = plane, .required_bytes = required_bytes };
    }

    return .{
        .planes = validated_planes,
        .plane_count = plane_count,
        .size = size,
        .format = format,
        .modifier = effective_modifier,
        .implicit_modifier = implicit_modifier,
        .y_inverted = flags.y_invert,
    };
}

pub const Buffer = struct {
    manager: *Self,
    resource: ?*wl.Buffer,
    descriptor: Descriptor,
    reference_count: usize,
    snapshot_count: usize,
    source_cache_id: u64,
    next_source_version: u64,
    render_target: ?ImportedRenderTarget,

    const ImportedRenderTarget = struct {
        renderer: render.DmabufRenderer,
        target: render.DmabufTarget,
    };

    // Optimized builds may merge identical wl_buffer request handlers, so the
    // implementation address cannot also serve as the resource type identity.
    var implementation_token: u8 = undefined;

    pub const CopyError = error{
        OutOfMemory,
        ImportFailed,
    };

    fn create(
        manager: *Self,
        client: *wl.Client,
        id: u32,
        descriptor: Descriptor,
    ) error{ OutOfMemory, ResourceCreateFailed }!*Buffer {
        const resource = try wl.Buffer.create(client, 1, id);
        errdefer resource.destroy();
        const self = manager.allocator.create(Buffer) catch return error.OutOfMemory;
        self.* = .{
            .manager = manager,
            .resource = resource,
            .descriptor = descriptor,
            .reference_count = 1,
            .snapshot_count = 0,
            .source_cache_id = render.allocateSourceCacheId(),
            .next_source_version = 1,
            .render_target = null,
        };
        manager.buffer_count += 1;
        const raw_resource: *wl.Resource = @ptrCast(resource);
        raw_resource.setDispatcher(
            dispatchRequest,
            &implementation_token,
            self,
            handleDestroy,
        );
        return self;
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

    pub fn size(self: *const Buffer) render.Size {
        return self.descriptor.size;
    }

    pub fn format(self: *const Buffer) u32 {
        return self.descriptor.format;
    }

    pub fn isCaptureCompatible(self: *const Buffer) bool {
        for (capture_formats) |candidate| {
            if (candidate.format == self.descriptor.format and
                candidate.modifier == self.descriptor.modifier) return true;
        }
        return false;
    }

    pub fn yInverted(self: *const Buffer) bool {
        return self.descriptor.y_inverted;
    }

    pub fn reference(self: *Buffer) void {
        std.debug.assert(self.reference_count > 0);
        self.reference_count += 1;
    }

    pub fn unreference(self: *Buffer) void {
        std.debug.assert(self.reference_count > 0);
        self.reference_count -= 1;
        if (self.reference_count != 0) return;
        if (self.render_target) |imported| {
            imported.renderer.release_target(
                imported.renderer.context,
                imported.target.id,
            );
        }
        for (self.descriptor.planes[0..self.descriptor.plane_count]) |plane| plane.plane.close();
        self.manager.buffer_count -= 1;
        self.manager.allocator.destroy(self);
    }

    pub fn sendRelease(self: *Buffer) void {
        if (self.resource) |resource| resource.sendRelease();
    }

    pub fn retainSnapshot(self: *Buffer) void {
        self.reference();
        self.snapshot_count += 1;
    }

    pub fn releaseSnapshot(self: *Buffer) void {
        std.debug.assert(self.snapshot_count > 0);
        self.snapshot_count -= 1;
        if (self.snapshot_count == 0) self.sendRelease();
        self.unreference();
    }

    pub fn acquireSourceCache(self: *Buffer) render.SourceCache {
        const source_cache: render.SourceCache = .{
            .id = self.source_cache_id,
            .version = self.next_source_version,
        };
        self.next_source_version +%= 1;
        return source_cache;
    }

    pub fn renderSource(self: *Buffer) render.DmabufSource {
        const descriptor = self.descriptor;
        const format_info = render.DmabufFormat.fromFourcc(descriptor.format).?;
        return .{
            .context = self,
            .format = descriptor.format,
            .modifier = descriptor.modifier,
            .planes = descriptor.renderPlanes(),
            .plane_count = descriptor.plane_count,
            .y_inverted = descriptor.y_inverted,
            .force_opaque = !format_info.hasAlpha(),
            .retain = retainSourceCallback,
            .release = releaseSourceCallback,
            .begin_cpu_read = beginCpuReadCallback,
            .end_cpu_read = endCpuReadCallback,
            .export_read_fence = exportReadFenceCallback,
        };
    }

    pub fn captureTarget(
        self: *Buffer,
        renderer: render.DmabufRenderer,
    ) CopyError!render.DmabufTarget {
        if (self.render_target) |imported| {
            if (imported.renderer.context != renderer.context) return error.ImportFailed;
            return imported.target;
        }
        const descriptor = self.descriptor;
        if (descriptor.y_inverted or descriptor.plane_count != 1 or
            !renderer.supports_target(
                renderer.context,
                descriptor.size,
                descriptor.format,
                descriptor.modifier,
            )) return error.ImportFailed;
        const plane = descriptor.planes[0].plane;
        const target: render.DmabufTarget = .{
            .id = render.allocateRenderTargetId(),
            .size = descriptor.size,
        };
        renderer.import_target(renderer.context, .{
            .id = target.id,
            .size = target.size,
            .fd = plane.fd,
            .format = descriptor.format,
            .modifier = descriptor.modifier,
            .stride = plane.stride,
            .offset = plane.offset,
        }) catch return error.ImportFailed;
        self.render_target = .{ .renderer = renderer, .target = target };
        return target;
    }

    pub fn importWriteFence(self: *const Buffer, sync_file_fd: std.posix.fd_t) bool {
        for (self.descriptor.planes[0..self.descriptor.plane_count]) |plane| {
            var import_sync_file: linux.dma_buf_import_sync_file = .{
                .flags = linux.DMA_BUF_SYNC_WRITE,
                .fd = sync_file_fd,
            };
            while (true) {
                const result = linux.ioctl(
                    plane.plane.fd,
                    linux.DMA_BUF_IOCTL_IMPORT_SYNC_FILE,
                    &import_sync_file,
                );
                if (result >= 0) break;
                switch (std.posix.errno(result)) {
                    .INTR, .AGAIN => continue,
                    else => return false,
                }
            }
        }
        return true;
    }

    pub fn copyPixels(
        self: *const Buffer,
        allocator: std.mem.Allocator,
    ) CopyError![]u32 {
        const descriptor = self.descriptor;
        const format_info = render.DmabufFormat.fromFourcc(descriptor.format).?;
        if (descriptor.modifier != linear_modifier or !format_info.isPackedRgb() or
            descriptor.plane_count != 1) return error.ImportFailed;
        const plane = descriptor.planes[0];
        const pixels = allocator.alloc(
            u32,
            descriptor.size.pixelCount() catch return error.ImportFailed,
        ) catch return error.OutOfMemory;
        errdefer allocator.free(pixels);

        const mapping = std.posix.mmap(
            null,
            plane.required_bytes,
            .{ .READ = true },
            .{ .TYPE = .SHARED },
            plane.plane.fd,
            0,
        ) catch return error.ImportFailed;
        defer std.posix.munmap(mapping);

        if (!syncDmaBuf(plane.plane.fd, linux.DMA_BUF_SYNC_READ)) {
            return error.ImportFailed;
        }
        defer {
            _ = syncDmaBuf(
                plane.plane.fd,
                linux.DMA_BUF_SYNC_READ | linux.DMA_BUF_SYNC_END,
            );
        }

        const destination = std.mem.sliceAsBytes(pixels);
        const row_bytes = @as(usize, descriptor.size.width) * @sizeOf(u32);
        for (0..descriptor.size.height) |destination_y| {
            const source_y = if (descriptor.y_inverted)
                descriptor.size.height - destination_y - 1
            else
                destination_y;
            const source_offset = @as(usize, plane.plane.offset) +
                source_y * plane.plane.stride;
            const destination_offset = destination_y * row_bytes;
            @memcpy(
                destination[destination_offset..][0..row_bytes],
                mapping[source_offset..][0..row_bytes],
            );
        }
        if (format_info.redBlueSwapped() or !format_info.hasAlpha()) {
            for (pixels) |*pixel| pixel.* = format_info.toArgb8888(pixel.*);
        }
        return pixels;
    }

    pub fn copyFromPixels(
        self: *const Buffer,
        source: render.PixelBuffer,
    ) CopyError!void {
        const descriptor = self.descriptor;
        const format_info = render.DmabufFormat.fromFourcc(descriptor.format).?;
        if (descriptor.modifier != linear_modifier or !format_info.isPackedRgb() or
            descriptor.plane_count != 1) return error.ImportFailed;
        const plane = descriptor.planes[0];
        if (!std.meta.eql(source.size, descriptor.size) or
            source.stride_pixels < source.size.width) return error.ImportFailed;
        const source_row_offset = std.math.mul(
            usize,
            source.size.height - 1,
            source.stride_pixels,
        ) catch return error.ImportFailed;
        const required_pixels = std.math.add(
            usize,
            source_row_offset,
            source.size.width,
        ) catch return error.ImportFailed;
        if (source.pixels.len < required_pixels) return error.ImportFailed;

        const mapping = std.posix.mmap(
            null,
            plane.required_bytes,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            plane.plane.fd,
            0,
        ) catch return error.ImportFailed;
        defer std.posix.munmap(mapping);

        if (!syncDmaBuf(plane.plane.fd, linux.DMA_BUF_SYNC_WRITE)) {
            return error.ImportFailed;
        }
        const row_bytes = @as(usize, descriptor.size.width) * @sizeOf(u32);
        for (0..descriptor.size.height) |source_y| {
            const destination_y = if (descriptor.y_inverted)
                descriptor.size.height - source_y - 1
            else
                source_y;
            const source_offset = source_y * source.stride_pixels * @sizeOf(u32);
            const destination_offset = @as(usize, plane.plane.offset) +
                destination_y * plane.plane.stride;
            if (!format_info.redBlueSwapped()) {
                const source_bytes = std.mem.sliceAsBytes(source.pixels);
                @memcpy(
                    mapping[destination_offset..][0..row_bytes],
                    source_bytes[source_offset..][0..row_bytes],
                );
            } else {
                const destination_bytes = mapping[destination_offset..][0..row_bytes];
                const destination_pixels: []u32 = @alignCast(std.mem.bytesAsSlice(
                    u32,
                    destination_bytes,
                ));
                const source_pixel_offset = source_y * source.stride_pixels;
                for (
                    destination_pixels,
                    source.pixels[source_pixel_offset..][0..descriptor.size.width],
                ) |*destination, pixel| {
                    destination.* = format_info.fromArgb8888(pixel);
                }
            }
        }
        if (!syncDmaBuf(
            plane.plane.fd,
            linux.DMA_BUF_SYNC_WRITE | linux.DMA_BUF_SYNC_END,
        )) return error.ImportFailed;
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
        self.resource = null;
        self.unreference();
    }

    fn beginCpuReadCallback(context: *anyopaque) bool {
        const self: *Buffer = @ptrCast(@alignCast(context));
        for (self.descriptor.planes[0..self.descriptor.plane_count], 0..) |plane, index| {
            if (syncDmaBuf(plane.plane.fd, linux.DMA_BUF_SYNC_READ)) continue;
            for (self.descriptor.planes[0..index]) |started| {
                _ = syncDmaBuf(started.plane.fd, linux.DMA_BUF_SYNC_READ | linux.DMA_BUF_SYNC_END);
            }
            return false;
        }
        return true;
    }

    fn retainSourceCallback(context: *anyopaque) void {
        const self: *Buffer = @ptrCast(@alignCast(context));
        self.reference();
    }

    fn releaseSourceCallback(context: *anyopaque) void {
        const self: *Buffer = @ptrCast(@alignCast(context));
        self.unreference();
    }

    fn endCpuReadCallback(context: *anyopaque) bool {
        const self: *Buffer = @ptrCast(@alignCast(context));
        var succeeded = true;
        for (self.descriptor.planes[0..self.descriptor.plane_count]) |plane| {
            succeeded = syncDmaBuf(
                plane.plane.fd,
                linux.DMA_BUF_SYNC_READ | linux.DMA_BUF_SYNC_END,
            ) and succeeded;
        }
        return succeeded;
    }

    fn exportReadFenceCallback(context: *anyopaque, plane_index: u8) ?std.posix.fd_t {
        const self: *Buffer = @ptrCast(@alignCast(context));
        if (plane_index >= self.descriptor.plane_count) return null;
        var export_sync_file: linux.dma_buf_export_sync_file = .{
            .flags = linux.DMA_BUF_SYNC_READ,
            .fd = -1,
        };
        while (true) {
            const result = linux.ioctl(
                self.descriptor.planes[plane_index].plane.fd,
                linux.DMA_BUF_IOCTL_EXPORT_SYNC_FILE,
                &export_sync_file,
            );
            if (result >= 0) return export_sync_file.fd;
            switch (std.posix.errno(result)) {
                .INTR, .AGAIN => continue,
                else => return null,
            }
        }
    }
};

fn syncDmaBuf(fd: std.posix.fd_t, flags: u64) bool {
    while (true) {
        var sync: linux.dma_buf_sync = .{ .flags = flags };
        const result = linux.ioctl(fd, linux.DMA_BUF_IOCTL_SYNC, &sync);
        if (result >= 0) return true;
        switch (std.posix.errno(result)) {
            .INTR, .AGAIN => continue,
            else => return false,
        }
    }
}

extern fn wl_resource_instance_of(
    resource: *wl.Resource,
    interface: *const anyopaque,
    implementation: *const anyopaque,
) c_int;

test "DMA-BUF descriptor rejects malformed and unsupported layouts before import" {
    const no_flags: zwp.LinuxBufferParamsV1.Flags = @bitCast(@as(u32, 0));
    const linear_plane: Plane = .{
        .fd = -1,
        .offset = 0,
        .stride = 8,
        .modifier = linear_modifier,
    };
    var planes: [max_planes]?Plane = @splat(null);

    try std.testing.expectError(
        error.Incomplete,
        validateDescriptor(planes, 2, 2, argb8888, no_flags, false, &fallback_formats),
    );
    planes[0] = linear_plane;
    try std.testing.expectError(
        error.InvalidDimensions,
        validateDescriptor(planes, 0, 2, argb8888, no_flags, false, &fallback_formats),
    );

    planes[0].?.stride = 4;
    try std.testing.expectError(
        error.OutOfBounds,
        validateDescriptor(planes, 2, 2, argb8888, no_flags, false, &fallback_formats),
    );
    planes[0].?.stride = 8;
    planes[0].?.modifier = 1;
    try std.testing.expectError(
        error.InvalidFormat,
        validateDescriptor(planes, 2, 2, argb8888, no_flags, false, &fallback_formats),
    );

    planes[0].?.modifier = linear_modifier;
    const interlaced: zwp.LinuxBufferParamsV1.Flags = @bitCast(@as(u32, 2));
    try std.testing.expectError(
        error.ImportFailed,
        validateDescriptor(planes, 2, 2, argb8888, interlaced, false, &fallback_formats),
    );
}

test "DMA-BUF sampling device arrays use native dev_t representation" {
    var device: linux.dev_t = 0x1234;
    var array: wl.Array = .{
        .size = @sizeOf(linux.dev_t),
        .alloc = @sizeOf(linux.dev_t),
        .data = @ptrCast(&device),
    };
    try std.testing.expectEqual(device, try deviceFromArray(&array));

    array.size -= 1;
    try std.testing.expectError(error.InvalidSize, deviceFromArray(&array));
}

test "DMA-BUF descriptor accepts only advertised non-linear pairs without mapping" {
    const no_flags: zwp.LinuxBufferParamsV1.Flags = @bitCast(@as(u32, 0));
    const fd = try std.posix.memfd_create("keywork-dmabuf-test", 0);
    defer _ = std.c.close(fd);
    if (std.c.ftruncate(fd, 16) != 0) return error.Unexpected;
    var planes: [max_planes]?Plane = @splat(null);
    // Modifier-specific plane layout values are opaque to the compositor; only
    // Vulkan may interpret them.
    planes[0] = .{ .fd = fd, .offset = 3, .stride = 1, .modifier = 42 };
    const supported = [_]render.DmabufFormatModifier{
        .{ .format = argb8888, .modifier = 42 },
    };
    const descriptor = try validateDescriptor(
        planes,
        2,
        2,
        argb8888,
        no_flags,
        false,
        &supported,
    );
    try std.testing.expectEqual(@as(u64, 42), descriptor.modifier);
    try std.testing.expectError(
        error.InvalidFormat,
        validateDescriptor(planes, 2, 2, xrgb8888, no_flags, false, &supported),
    );
}

test "DMA-BUF descriptor retains every plane required by video formats" {
    const no_flags: zwp.LinuxBufferParamsV1.Flags = @bitCast(@as(u32, 0));
    const luma_fd = try std.posix.memfd_create("keywork-nv12-luma-test", 0);
    defer _ = std.c.close(luma_fd);
    const chroma_fd = try std.posix.memfd_create("keywork-nv12-chroma-test", 0);
    defer _ = std.c.close(chroma_fd);
    if (std.c.ftruncate(luma_fd, 64) != 0 or std.c.ftruncate(chroma_fd, 64) != 0) {
        return error.Unexpected;
    }

    const supported = [_]render.DmabufFormatModifier{
        .{ .format = nv12, .modifier = 42 },
    };
    var planes: [max_planes]?Plane = @splat(null);
    planes[0] = .{ .fd = luma_fd, .offset = 3, .stride = 5, .modifier = 42 };
    try std.testing.expectError(
        error.Incomplete,
        validateDescriptor(planes, 6, 4, nv12, no_flags, false, &supported),
    );

    planes[1] = .{ .fd = chroma_fd, .offset = 7, .stride = 6, .modifier = 42 };
    const descriptor = try validateDescriptor(
        planes,
        6,
        4,
        nv12,
        no_flags,
        false,
        &supported,
    );
    try std.testing.expectEqual(@as(u8, 2), descriptor.plane_count);
    try std.testing.expectEqual(luma_fd, descriptor.planes[0].plane.fd);
    try std.testing.expectEqual(chroma_fd, descriptor.planes[1].plane.fd);
    try std.testing.expectEqual(@as(usize, 64), descriptor.planes[0].required_bytes);
    try std.testing.expectEqual(@as(usize, 64), descriptor.planes[1].required_bytes);

    planes[1].?.modifier = 43;
    try std.testing.expectError(
        error.InvalidFormat,
        validateDescriptor(planes, 6, 4, nv12, no_flags, false, &supported),
    );
    planes[1].?.modifier = 42;
    planes[2] = planes[1];
    try std.testing.expectError(
        error.Incomplete,
        validateDescriptor(planes, 6, 4, nv12, no_flags, false, &supported),
    );
    planes[2] = null;
    try std.testing.expectError(
        error.InvalidDimensions,
        validateDescriptor(planes, 5, 4, nv12, no_flags, false, &supported),
    );
    try std.testing.expectError(
        error.InvalidDimensions,
        validateDescriptor(planes, 6, 3, nv12, no_flags, false, &supported),
    );
}
