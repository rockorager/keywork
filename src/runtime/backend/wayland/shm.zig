//! Minimal `wl_shm` render backend for Keywork display lists.

const std = @import("std");
const keywork = @import("keywork-ui");
const raster = @import("../../graphics/raster.zig");
const ShmFrameHistory = @import("../../graphics/ShmFrameHistory.zig");
const TextRenderer = @import("../../graphics/text.zig");
const SharedBackend = @import("backend.zig").Backend;
const window = @import("window.zig");
const wayland = @import("wayland");

const linux = std.os.linux;
const posix = std.posix;
const wl = wayland.client.wl;

const PixelRegion = ShmFrameHistory.PixelRegion;

const RendererAdapter = struct {
    pub const BackendResources = TextRenderer;
    pub const WindowResources = struct {
        buffers: std.ArrayList(*Buffer) = .empty,
        last_rendered: ?*Buffer = null,
        last_rendered_scale: f32 = 0,
        /// Monotonic per-window frame number; `Buffer.frame` refers to it.
        frame_counter: u64 = 0,
        history: ShmFrameHistory = .{},
    };
    pub const default_title = "Keywork";
    pub const connection_options: window.GlobalNeeds = .{ .shm = true, .outputs = true };

    pub fn initBackend(allocator: std.mem.Allocator, _: *window.Connection) !BackendResources {
        return TextRenderer.init(allocator);
    }

    pub fn deinitBackend(renderer: *BackendResources) void {
        renderer.deinit();
    }

    pub fn initWindow(_: anytype, _: *window.Surface) !WindowResources {
        return .{};
    }

    pub fn afterWindowListeners(backend: anytype, win: anytype) void {
        if (win.protocol.isSessionLock()) return;
        win.protocol.surface.commit();
        _ = backend.connection.display.flush();
    }

    pub fn deinitWindow(backend: anytype, renderer: *WindowResources) void {
        for (renderer.buffers.items) |buffer| buffer.destroy(backend.allocator);
        renderer.buffers.deinit(backend.allocator);
    }

    pub fn present(win: anytype, frame: keywork.RenderBackend.Frame) !bool {
        const protocol = &win.protocol;
        const logical_width = try window.frameLogicalDimension(frame.size.width, protocol.width);
        const logical_height = try window.frameLogicalDimension(frame.size.height, protocol.height);
        const width = try window.scaledFrameDimension(logical_width, protocol.scale);
        const height = try window.scaledFrameDimension(logical_height, protocol.scale);
        const buffer = try acquireBuffer(win, width, height);
        const damage_region = partialDamageRegion(win, frame, buffer, width, height);
        if (frame.partial_display_list and damage_region == null) return error.PartialPaintUnavailable;
        if (damage_region) |region| {
            for (region.slice()) |clip| {
                try raster.rasterize(&win.backend.renderer, buffer.pixels(), width, height, protocol.scale, frame.display_list, clip);
            }
        } else {
            try raster.rasterize(&win.backend.renderer, buffer.pixels(), width, height, protocol.scale, frame.display_list, null);
        }
        win.renderer.last_rendered = buffer;
        win.renderer.last_rendered_scale = protocol.scale;

        try protocol.armFrameCallback();
        protocol.surface.attach(buffer.wl_buffer, 0, 0);
        if (damage_region) |region| {
            for (region.slice()) |clip| {
                const x0: i32 = @max(0, clip.x0);
                const y0: i32 = @max(0, clip.y0);
                const x1: i32 = @min(@as(i32, width), clip.x1);
                const y1: i32 = @min(@as(i32, height), clip.y1);
                protocol.damagePixels(x0, y0, @max(0, x1 - x0), @max(0, y1 - y0));
            }
        } else {
            protocol.damagePixels(0, 0, width, height);
        }
        const fully_opaque = frame.fully_opaque and window.frameCoversLogicalDimensions(frame.size, logical_width, logical_height);
        try protocol.configureBuffer(logical_width, logical_height, frame.content_rect, fully_opaque);
        protocol.surface.commit();
        buffer.busy = true;
        win.renderer.frame_counter += 1;
        buffer.frame = win.renderer.frame_counter;
        var committed_region: PixelRegion = .{};
        if (damage_region) |region| {
            committed_region = region;
        } else {
            committed_region.add(.{ .x0 = 0, .y0 = 0, .x1 = width, .y1 = height });
        }
        win.renderer.history.record(win.renderer.frame_counter, width, height, committed_region);
        _ = win.backend.connection.display.flush();
        return true;
    }

    pub fn measureText(win: anytype, value: []const u8, style: keywork.ResolvedTextStyle) !keywork.Size {
        return win.backend.renderer.measure(win.protocol.scale, value, style);
    }

    pub fn textMetrics(win: anytype, font_size: f32) !keywork.TextMetrics {
        return win.backend.renderer.metrics(win.protocol.scale, font_size);
    }

    pub fn partialPaintBounds(win: anytype, size: keywork.Size, scale: f32, damage: []const keywork.Rect) !?keywork.Rect {
        if (!win.protocol.configured or scale != win.protocol.scale or damage.len == 0) return null;

        const logical_width = try window.frameLogicalDimension(size.width, win.protocol.width);
        const logical_height = try window.frameLogicalDimension(size.height, win.protocol.height);
        const width = try window.scaledFrameDimension(logical_width, scale);
        const height = try window.scaledFrameDimension(logical_height, scale);
        const last = win.renderer.last_rendered orelse return null;
        if (win.renderer.last_rendered_scale != scale or last.width != width or last.height != height) return null;

        var region: PixelRegion = .{};
        for (damage) |rect| region.add(TextRenderer.PixelClip.fromRect(rect, scale));
        const clip = region.bounds() orelse return null;
        if (clip.x0 >= clip.x1 or clip.y0 >= clip.y1) return null;
        if (clip.x0 <= 0 and clip.y0 <= 0 and clip.x1 >= width and clip.y1 >= height) return null;

        // Cull against pixel-aligned logical bounds. A neighboring node
        // whose edge shares a rounded damage pixel must still be emitted.
        const x0: f32 = @floatFromInt(@max(0, clip.x0));
        const y0: f32 = @floatFromInt(@max(0, clip.y0));
        const x1: f32 = @floatFromInt(@min(@as(i32, width), clip.x1));
        const y1: f32 = @floatFromInt(@min(@as(i32, height), clip.y1));
        return .{
            .x = x0 / scale,
            .y = y0 / scale,
            .width = (x1 - x0) / scale,
            .height = (y1 - y0) / scale,
        };
    }

    /// Returns the pixel region that must be re-rasterized, or null
    /// when a full redraw is required. Partial redraw needs the
    /// previous frame's content: either the acquired buffer already
    /// holds it, or it is copied over from the buffer that does.
    fn partialDamageRegion(win: anytype, frame: keywork.RenderBackend.Frame, buffer: *Buffer, width: u31, height: u31) ?PixelRegion {
        if (frame.damage.len == 0) return null;
        var region: PixelRegion = .{};
        for (frame.damage) |rect| region.add(TextRenderer.PixelClip.fromRect(rect, win.protocol.scale));
        const bounds = region.bounds() orelse return null;
        if (region.len == 1 and bounds.x0 <= 0 and bounds.y0 <= 0 and bounds.x1 >= width and bounds.y1 >= height) return null;

        const last = win.renderer.last_rendered orelse return null;
        if (win.renderer.last_rendered_scale != win.protocol.scale) return null;
        if (last == buffer) return region;
        if (last.width != width or last.height != height) return null;
        if (win.renderer.history.canRepair(buffer.frame, width, height)) {
            ShmFrameHistory.repairRegions(buffer.pixels(), last.pixels(), width, height, win.renderer.history.entries[0..win.renderer.history.len], buffer.frame, region);
        } else {
            ShmFrameHistory.copyPixels(buffer.pixels(), last.pixels());
        }
        return region;
    }

    fn acquireBuffer(win: anytype, width: u31, height: u31) !*Buffer {
        const allocator = win.backend.allocator;
        var available: ?*Buffer = null;
        for (win.renderer.buffers.items) |buffer| {
            if (buffer.busy) continue;
            if (buffer.width == width and buffer.height == height) return buffer;
            if (available == null) available = buffer;
        }
        if (available) |buffer| {
            if (win.renderer.last_rendered == buffer) win.renderer.last_rendered = null;
            try buffer.reshape(width, height);
            return buffer;
        }

        const buffer = try Buffer.create(allocator, win.backend.connection.shm.?, width, height);
        errdefer buffer.destroy(allocator);
        try win.renderer.buffers.append(allocator, buffer);
        return buffer;
    }
};

pub const Backend = SharedBackend(RendererAdapter);

const Buffer = struct {
    wl_buffer: *wl.Buffer,
    pool: *wl.ShmPool,
    fd: posix.fd_t,
    data: []align(std.heap.page_size_min) u8,
    width: u31,
    height: u31,
    busy: bool,
    /// WindowResources.frame_counter value when this buffer was last committed;
    /// 0 means the buffer has never held a frame.
    frame: u64,

    fn create(allocator: std.mem.Allocator, shm: *wl.Shm, width: u31, height: u31) !*Buffer {
        std.debug.assert(width > 0 and height > 0);
        const dimensions = try bufferDimensions(width, height);
        const capacity = try grownBufferCapacity(0, dimensions.size);

        const fd = try posix.memfd_create("keywork-shm", linux.MFD.CLOEXEC);
        errdefer _ = linux.close(fd);
        if (linux.errno(linux.ftruncate(fd, @intCast(capacity))) != .SUCCESS) return error.ShmFailed;

        const data = try posix.mmap(
            null,
            capacity,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        errdefer posix.munmap(data);

        const pool = try shm.createPool(fd, @intCast(capacity));
        errdefer pool.destroy();
        const wl_buffer = try pool.createBuffer(0, width, height, dimensions.stride, .argb8888);
        errdefer wl_buffer.destroy();

        const self = try allocator.create(Buffer);
        self.* = .{
            .wl_buffer = wl_buffer,
            .pool = pool,
            .fd = fd,
            .data = data,
            .width = width,
            .height = height,
            .busy = false,
            .frame = 0,
        };
        wl_buffer.setListener(*Buffer, bufferListener, self);
        return self;
    }

    fn reshape(self: *Buffer, width: u31, height: u31) !void {
        std.debug.assert(!self.busy);
        std.debug.assert(width > 0 and height > 0);
        const dimensions = try bufferDimensions(width, height);
        if (dimensions.size > self.data.len) {
            const capacity = try grownBufferCapacity(self.data.len, dimensions.size);
            if (linux.errno(linux.ftruncate(self.fd, @intCast(capacity))) != .SUCCESS) return error.ShmFailed;
            const data = try posix.mmap(
                null,
                capacity,
                .{ .READ = true, .WRITE = true },
                .{ .TYPE = .SHARED },
                self.fd,
                0,
            );
            self.pool.resize(@intCast(capacity));
            posix.munmap(self.data);
            self.data = data;
        }

        const wl_buffer = try self.pool.createBuffer(0, width, height, dimensions.stride, .argb8888);
        wl_buffer.setListener(*Buffer, bufferListener, self);
        self.wl_buffer.destroy();
        self.wl_buffer = wl_buffer;
        self.width = width;
        self.height = height;
        self.frame = 0;
    }

    fn destroy(self: *Buffer, allocator: std.mem.Allocator) void {
        self.wl_buffer.destroy();
        self.pool.destroy();
        posix.munmap(self.data);
        _ = linux.close(self.fd);
        allocator.destroy(self);
    }

    fn pixels(self: *Buffer) []u32 {
        const pixel_count = @as(usize, self.width) * @as(usize, self.height);
        return @alignCast(std.mem.bytesAsSlice(u32, self.data)[0..pixel_count]);
    }

    fn bufferListener(_: *wl.Buffer, event: wl.Buffer.Event, self: *Buffer) void {
        switch (event) {
            .release => self.busy = false,
        }
    }
};

const BufferDimensions = struct {
    stride: i32,
    size: usize,
};

fn bufferDimensions(width: u31, height: u31) !BufferDimensions {
    const stride = @as(usize, width) * @sizeOf(u32);
    const size = stride * @as(usize, height);
    if (stride > std.math.maxInt(i32) or size > std.math.maxInt(i32)) return error.ShmBufferTooLarge;
    return .{ .stride = @intCast(stride), .size = size };
}

fn grownBufferCapacity(current: usize, required: usize) !usize {
    const max_capacity: usize = std.math.maxInt(i32);
    if (required > max_capacity) return error.ShmBufferTooLarge;
    const geometric = current +| current / 2;
    const wanted = @max(required, @max(std.heap.page_size_min, geometric));
    const aligned = std.mem.alignForward(usize, wanted, std.heap.page_size_min);
    return if (aligned <= max_capacity) aligned else required;
}

test "SHM buffer capacity grows geometrically and remains page aligned" {
    const initial = try grownBufferCapacity(0, 1000);
    try std.testing.expect(initial >= 1000);
    try std.testing.expectEqual(@as(usize, 0), initial % std.heap.page_size_min);

    const grown = try grownBufferCapacity(initial, initial + 1);
    try std.testing.expect(grown >= initial + initial / 2);
    try std.testing.expectEqual(@as(usize, 0), grown % std.heap.page_size_min);
}
