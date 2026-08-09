//! Protocol-neutral Linux DMA-BUF descriptor validation and retained ownership.
//!
//! Protocol adapters own their resources and wire errors. This namespace owns
//! transferred plane descriptors, validation, CPU synchronization, renderer
//! source retention, and the final-close invariant shared by those adapters.

const std = @import("std");
const render = @import("../render/types.zig");

const linux = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("fcntl.h");
    @cInclude("libdrm/drm_fourcc.h");
    @cInclude("linux/dma-buf.h");
    @cInclude("linux/memfd.h");
    @cInclude("linux/sync_file.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/types.h");
});

pub const max_planes = render.max_dmabuf_planes;
pub const invalid_modifier: u64 = 0x00ff_ffff_ffff_ffff;
pub const linear_modifier: u64 = 0;
pub const Device = linux.dev_t;

pub const FormatTableEntry = extern struct {
    format: u32,
    padding: u32 = 0,
    modifier: u64,
};

/// Protocol-free immutable feedback storage. The table descriptor remains
/// owned here; protocol event queues duplicate it when publishing feedback.
pub const Feedback = struct {
    device: Device,
    pairs: []render.DmabufFormatModifier,
    indices: []align(4) u16,
    scanout_indices: []align(4) u16,
    fd: std.posix.fd_t,

    pub fn init(
        allocator: std.mem.Allocator,
        device: Device,
        supported_pairs: []const render.DmabufFormatModifier,
    ) !Feedback {
        return initWithScanout(allocator, device, supported_pairs, &.{});
    }

    pub fn initWithScanout(
        allocator: std.mem.Allocator,
        device: Device,
        supported_pairs: []const render.DmabufFormatModifier,
        scanout_pairs: []const render.DmabufFormatModifier,
    ) !Feedback {
        if (supported_pairs.len == 0 or supported_pairs.len > std.math.maxInt(u16) + 1 or
            supported_pairs.len > std.math.maxInt(u32) / @sizeOf(FormatTableEntry))
            return error.InvalidFormatTable;
        comptime std.debug.assert(@sizeOf(FormatTableEntry) == 16);
        const pairs = try allocator.dupe(render.DmabufFormatModifier, supported_pairs);
        errdefer allocator.free(pairs);
        const indices = try allocator.alignedAlloc(u16, .fromByteUnits(4), pairs.len);
        errdefer allocator.free(indices);
        var scanout_count: usize = 0;
        for (pairs) |pair| if (render.DmabufFormatModifier.contains(
            scanout_pairs,
            pair.format,
            pair.modifier,
        )) {
            scanout_count += 1;
        };
        const scanout_indices = try allocator.alignedAlloc(u16, .fromByteUnits(4), scanout_count);
        errdefer allocator.free(scanout_indices);
        const entries = try allocator.alloc(FormatTableEntry, pairs.len);
        defer allocator.free(entries);
        var scanout_index: usize = 0;
        for (pairs, entries, 0..) |pair, *entry, index| {
            entry.* = .{ .format = pair.format, .modifier = pair.modifier };
            indices[index] = @intCast(index);
            if (render.DmabufFormatModifier.contains(scanout_pairs, pair.format, pair.modifier)) {
                scanout_indices[scanout_index] = @intCast(index);
                scanout_index += 1;
            }
        }

        const fd = try std.posix.memfd_create(
            "keywork-dmabuf-formats",
            linux.MFD_CLOEXEC | linux.MFD_ALLOW_SEALING,
        );
        errdefer _ = std.c.close(fd);
        const bytes = std.mem.sliceAsBytes(entries);
        if (std.c.ftruncate(fd, @intCast(bytes.len)) < 0) return error.WriteFailed;
        var written: usize = 0;
        while (written < bytes.len) {
            const result = std.c.pwrite(fd, bytes[written..].ptr, bytes.len - written, @intCast(written));
            if (result < 0) switch (std.posix.errno(result)) {
                .INTR => continue,
                else => return error.WriteFailed,
            };
            if (result == 0) return error.WriteFailed;
            written += @intCast(result);
        }
        const seals = linux.F_SEAL_SHRINK | linux.F_SEAL_GROW | linux.F_SEAL_WRITE | linux.F_SEAL_SEAL;
        if (std.c.fcntl(fd, linux.F_ADD_SEALS, seals) < 0) return error.SealFailed;
        return .{
            .device = device,
            .pairs = pairs,
            .indices = indices,
            .scanout_indices = scanout_indices,
            .fd = fd,
        };
    }

    pub fn deinit(self: *Feedback, allocator: std.mem.Allocator) void {
        _ = std.c.close(self.fd);
        allocator.free(self.pairs);
        allocator.free(self.indices);
        allocator.free(self.scanout_indices);
        self.* = undefined;
    }

    pub fn deviceBytes(self: *const Feedback) []const u8 {
        return std.mem.asBytes(&self.device);
    }

    pub fn indexBytes(self: *const Feedback) []const u8 {
        return std.mem.sliceAsBytes(self.indices);
    }

    pub fn scanoutIndexBytes(self: *const Feedback) []const u8 {
        return std.mem.sliceAsBytes(self.scanout_indices);
    }
};

pub const Plane = struct {
    fd: std.posix.fd_t,
    offset: u32,
    stride: u32,
    modifier: u64,

    pub fn close(self: Plane) void {
        _ = std.c.close(self.fd);
    }
};

pub const DescriptorPlane = struct {
    plane: Plane,
    required_bytes: usize,
};

pub const Descriptor = struct {
    planes: [max_planes]DescriptorPlane,
    plane_count: u8,
    size: render.Size,
    format: u32,
    modifier: u64,
    implicit_modifier: bool,
    y_inverted: bool,

    pub fn renderPlanes(self: Descriptor) [max_planes]render.DmabufPlane {
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

pub const DescriptorError = error{
    Incomplete,
    InvalidFormat,
    InvalidDimensions,
    OutOfBounds,
    ImportFailed,
};

pub const Parameters = struct {
    planes: [max_planes]?Plane = @splat(null),
    used: bool = false,

    pub const AddError = error{ AlreadyUsed, PlaneIndex, PlaneSet };

    /// Takes ownership of `plane` on success and closes it on every rejection.
    pub fn add(self: *Parameters, plane: Plane, index: u32) AddError!void {
        if (self.used) {
            plane.close();
            return error.AlreadyUsed;
        }
        if (index >= max_planes) {
            plane.close();
            return error.PlaneIndex;
        }
        if (self.planes[index] != null) {
            plane.close();
            return error.PlaneSet;
        }
        self.planes[index] = plane;
    }

    /// Marks the parameters used before validation, as required by the wire
    /// protocol. The returned descriptor still borrows the planes until
    /// `transfer` is called after adapter materialization succeeds.
    pub fn validate(
        self: *Parameters,
        width: i32,
        height: i32,
        format: u32,
        flag_bits: u32,
        allow_implicit_modifier: bool,
        supported_pairs: []const render.DmabufFormatModifier,
    ) (DescriptorError || error{AlreadyUsed})!Descriptor {
        if (self.used) return error.AlreadyUsed;
        self.used = true;
        return validateDescriptor(
            self.planes,
            width,
            height,
            format,
            flag_bits,
            allow_implicit_modifier,
            supported_pairs,
        );
    }

    pub fn transfer(self: *Parameters, plane_count: u8) void {
        for (self.planes[0..plane_count]) |*plane| {
            std.debug.assert(plane.* != null);
            plane.* = null;
        }
    }

    pub fn deinit(self: *Parameters) void {
        for (self.planes) |plane| if (plane) |value| value.close();
        self.* = undefined;
    }
};

pub fn validateDescriptor(
    planes: [max_planes]?Plane,
    width: i32,
    height: i32,
    format: u32,
    flag_bits: u32,
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
    const effective_modifier = if (implicit_modifier) linear_modifier else first_plane.modifier;
    if (!render.DmabufFormatModifier.contains(supported_pairs, format, effective_modifier)) {
        return error.InvalidFormat;
    }
    // Y_INVERT is bit 0. INTERLACED/BOTTOM_FIRST and unknown bits cannot be
    // represented by the renderer contract.
    if (flag_bits & ~@as(u32, 1) != 0) return error.ImportFailed;

    const size: render.Size = .{ .width = @intCast(width), .height = @intCast(height) };
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
            if (required_end == 0 or required_end > std.math.maxInt(usize)) return error.OutOfBounds;
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
            if (@as(u64, @intCast(fd_size)) > std.math.maxInt(usize)) return error.OutOfBounds;
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
        .y_inverted = flag_bits & 1 != 0,
    };
}

pub const Buffer = struct {
    descriptor: Descriptor,
    reference_count: usize = 1,
    snapshot_count: usize = 0,
    source_cache_id: u64,
    next_source_version: u64 = 1,
    render_target: ?ImportedRenderTarget = null,
    context: *anyopaque,
    release: *const fn (*anyopaque) void,
    finalize: *const fn (*anyopaque) void,

    const ImportedRenderTarget = struct {
        renderer: render.DmabufRenderer,
        target: render.DmabufTarget,
    };

    pub fn init(
        descriptor: Descriptor,
        context: *anyopaque,
        release: *const fn (*anyopaque) void,
        finalize: *const fn (*anyopaque) void,
    ) Buffer {
        return .{
            .descriptor = descriptor,
            .source_cache_id = render.allocateSourceCacheId(),
            .context = context,
            .release = release,
            .finalize = finalize,
        };
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
            imported.renderer.release_target(imported.renderer.context, imported.target.id);
        }
        for (self.descriptor.planes[0..self.descriptor.plane_count]) |plane| plane.plane.close();
        const context = self.context;
        const finalize = self.finalize;
        self.* = undefined;
        finalize(context);
    }

    pub fn retainSnapshot(self: *Buffer) void {
        self.reference();
        self.snapshot_count += 1;
    }

    pub fn releaseSnapshot(self: *Buffer) void {
        std.debug.assert(self.snapshot_count > 0);
        self.snapshot_count -= 1;
        if (self.snapshot_count == 0) self.release(self.context);
        self.unreference();
    }

    pub fn acquireSourceCache(self: *Buffer) render.SourceCache {
        const result: render.SourceCache = .{ .id = self.source_cache_id, .version = self.next_source_version };
        self.next_source_version +%= 1;
        return result;
    }

    pub fn renderSource(self: *Buffer) render.DmabufSource {
        const format_info = render.DmabufFormat.fromFourcc(self.descriptor.format).?;
        return .{
            .context = self,
            .format = self.descriptor.format,
            .modifier = self.descriptor.modifier,
            .planes = self.descriptor.renderPlanes(),
            .plane_count = self.descriptor.plane_count,
            .y_inverted = self.descriptor.y_inverted,
            .force_opaque = !format_info.hasAlpha(),
            .retain = retainSource,
            .release = releaseSource,
            .begin_cpu_read = beginCpuRead,
            .end_cpu_read = endCpuRead,
            .export_read_fence = exportReadFence,
        };
    }

    pub fn importWriteFence(self: *const Buffer, sync_file_fd: std.posix.fd_t) bool {
        for (self.descriptor.planes[0..self.descriptor.plane_count]) |plane| {
            var value: linux.dma_buf_import_sync_file = .{
                .flags = linux.DMA_BUF_SYNC_WRITE,
                .fd = sync_file_fd,
            };
            while (true) {
                const result = linux.ioctl(plane.plane.fd, linux.DMA_BUF_IOCTL_IMPORT_SYNC_FILE, &value);
                if (result >= 0) break;
                switch (std.posix.errno(result)) {
                    .INTR, .AGAIN => continue,
                    else => return false,
                }
            }
        }
        return true;
    }

    /// Exports one sync file which waits for every reader and writer of every
    /// plane. The caller owns the returned descriptor.
    pub fn exportCompletionFence(self: *const Buffer) ?std.posix.fd_t {
        var merged: ?std.posix.fd_t = null;
        defer {
            if (merged) |fd| _ = std.c.close(fd);
        }
        for (self.descriptor.planes[0..self.descriptor.plane_count]) |plane| {
            const fd = exportFence(plane.plane.fd, linux.DMA_BUF_SYNC_WRITE) orelse return null;
            if (merged == null) {
                merged = fd;
                continue;
            }
            var merge: linux.sync_merge_data = std.mem.zeroes(linux.sync_merge_data);
            merge.fd2 = fd;
            const result = while (true) {
                const value = linux.ioctl(merged.?, linux.SYNC_IOC_MERGE, &merge);
                if (value >= 0 or std.posix.errno(value) != .INTR) break value;
            };
            _ = std.c.close(fd);
            if (result < 0) return null;
            _ = std.c.close(merged.?);
            merged = merge.fence;
        }
        const result = merged;
        merged = null;
        return result;
    }

    pub fn captureTarget(
        self: *Buffer,
        renderer: render.DmabufRenderer,
    ) error{ImportFailed}!render.DmabufTarget {
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

    fn retainSource(context: *anyopaque) void {
        const self: *Buffer = @ptrCast(@alignCast(context));
        self.reference();
    }

    fn releaseSource(context: *anyopaque) void {
        const self: *Buffer = @ptrCast(@alignCast(context));
        self.unreference();
    }

    fn beginCpuRead(context: *anyopaque) bool {
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

    fn endCpuRead(context: *anyopaque) bool {
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

    fn exportReadFence(context: *anyopaque, plane_index: u8) ?std.posix.fd_t {
        const self: *Buffer = @ptrCast(@alignCast(context));
        if (plane_index >= self.descriptor.plane_count) return null;
        return exportFence(self.descriptor.planes[plane_index].plane.fd, linux.DMA_BUF_SYNC_READ);
    }

    fn exportFence(fd: std.posix.fd_t, flags: u32) ?std.posix.fd_t {
        var value: linux.dma_buf_export_sync_file = .{
            .flags = flags,
            .fd = -1,
        };
        while (true) {
            const result = linux.ioctl(
                fd,
                linux.DMA_BUF_IOCTL_EXPORT_SYNC_FILE,
                &value,
            );
            if (result >= 0) return value.fd;
            switch (std.posix.errno(result)) {
                .INTR, .AGAIN => continue,
                else => return null,
            }
        }
    }
};

pub fn syncDmaBuf(fd: std.posix.fd_t, flags: u64) bool {
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

fn testMemfd(size: usize) !std.posix.fd_t {
    const fd = try std.posix.memfd_create("neutral-dmabuf-test", std.os.linux.MFD.CLOEXEC);
    errdefer _ = std.c.close(fd);
    if (std.c.ftruncate(fd, @intCast(size)) != 0) return error.Unexpected;
    return fd;
}

test "neutral parameters close exactly the descriptors they retain or reject" {
    var parameters: Parameters = .{};
    const retained = try testMemfd(64);
    try parameters.add(.{ .fd = retained, .offset = 0, .stride = 8, .modifier = 42 }, 0);

    const duplicate = try testMemfd(64);
    try std.testing.expectError(
        error.PlaneSet,
        parameters.add(.{ .fd = duplicate, .offset = 0, .stride = 8, .modifier = 42 }, 0),
    );
    try std.testing.expect(std.c.fcntl(duplicate, std.c.F.GETFD) < 0);

    const out_of_range = try testMemfd(64);
    try std.testing.expectError(
        error.PlaneIndex,
        parameters.add(.{ .fd = out_of_range, .offset = 0, .stride = 8, .modifier = 42 }, max_planes),
    );
    try std.testing.expect(std.c.fcntl(out_of_range, std.c.F.GETFD) < 0);

    const supported = [_]render.DmabufFormatModifier{.{
        .format = @intFromEnum(render.DmabufFormat.argb8888),
        .modifier = 42,
    }};
    const descriptor = try parameters.validate(2, 2, supported[0].format, 0, false, &supported);
    try std.testing.expectEqual(retained, descriptor.planes[0].plane.fd);
    try std.testing.expectError(
        error.AlreadyUsed,
        parameters.validate(2, 2, supported[0].format, 0, false, &supported),
    );
    const after_use = try testMemfd(64);
    try std.testing.expectError(
        error.AlreadyUsed,
        parameters.add(.{ .fd = after_use, .offset = 0, .stride = 8, .modifier = 42 }, 1),
    );
    try std.testing.expect(std.c.fcntl(after_use, std.c.F.GETFD) < 0);
    parameters.deinit();
    try std.testing.expect(std.c.fcntl(retained, std.c.F.GETFD) < 0);
}

test "neutral feedback allocator failures reclaim every allocation and descriptor" {
    const pairs = [_]render.DmabufFormatModifier{
        .{ .format = @intFromEnum(render.DmabufFormat.argb8888), .modifier = 0 },
        .{ .format = @intFromEnum(render.DmabufFormat.xrgb8888), .modifier = 42 },
    };
    var measuring = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var feedback = try Feedback.initWithScanout(measuring.allocator(), 0x1234, &pairs, pairs[1..]);
    const allocation_count = measuring.alloc_index;
    try std.testing.expectEqualSlices(u16, &.{ 0, 1 }, feedback.indices);
    try std.testing.expectEqualSlices(u16, &.{1}, feedback.scanout_indices);
    feedback.deinit(measuring.allocator());
    try std.testing.expectEqual(measuring.allocated_bytes, measuring.freed_bytes);

    for (0..allocation_count) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        failing.fail_index = fail_index;
        try std.testing.expectError(
            error.OutOfMemory,
            Feedback.initWithScanout(failing.allocator(), 0x1234, &pairs, pairs[1..]),
        );
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}
