//! Minimal `wl_shm` render backend for Keywork display lists.

const std = @import("std");
const builtin = @import("builtin");
const keywork = @import("../../ui.zig");
const raster = @import("../../graphics/raster.zig");
const TextRenderer = @import("../../graphics/text.zig");
const SharedBackend = @import("backend.zig").Backend;
const window = @import("window.zig");
const wayland = @import("wayland");

const linux = std.os.linux;
const posix = std.posix;
const wl = wayland.client.wl;

const RendererAdapter = struct {
    pub const BackendResources = TextRenderer;
    pub const WindowResources = struct {
        buffers: std.ArrayList(*Buffer) = .empty,
        last_rendered: ?*Buffer = null,
        last_rendered_scale: f32 = 0,
        /// Monotonic per-window frame number; `Buffer.frame` refers to it.
        frame_counter: u64 = 0,
        history: DamageHistory = .{},
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
        const damage_clip = partialDamageClip(win, frame, buffer, width, height);
        if (frame.partial_display_list and damage_clip == null) return error.PartialPaintUnavailable;
        try raster.rasterize(&win.backend.renderer, buffer.pixels(), width, height, protocol.scale, frame.display_list, damage_clip);
        win.renderer.last_rendered = buffer;
        win.renderer.last_rendered_scale = protocol.scale;

        try protocol.armFrameCallback();
        protocol.surface.attach(buffer.wl_buffer, 0, 0);
        if (damage_clip) |clip| {
            const x0: i32 = @max(0, clip.x0);
            const y0: i32 = @max(0, clip.y0);
            const x1: i32 = @min(@as(i32, width), clip.x1);
            const y1: i32 = @min(@as(i32, height), clip.y1);
            protocol.damagePixels(x0, y0, @max(0, x1 - x0), @max(0, y1 - y0));
        } else {
            protocol.damagePixels(0, 0, width, height);
        }
        protocol.configureBuffer(logical_width, logical_height);
        protocol.surface.commit();
        buffer.busy = true;
        win.renderer.frame_counter += 1;
        buffer.frame = win.renderer.frame_counter;
        win.renderer.history.record(
            win.renderer.frame_counter,
            width,
            height,
            damage_clip orelse .{ .x0 = 0, .y0 = 0, .x1 = width, .y1 = height },
        );
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
        if (!win.protocol.configured or scale != win.protocol.scale or damage.len != 1) return null;

        const logical_width = try window.frameLogicalDimension(size.width, win.protocol.width);
        const logical_height = try window.frameLogicalDimension(size.height, win.protocol.height);
        const width = try window.scaledFrameDimension(logical_width, scale);
        const height = try window.scaledFrameDimension(logical_height, scale);
        const last = win.renderer.last_rendered orelse return null;
        if (win.renderer.last_rendered_scale != scale or last.width != width or last.height != height) return null;

        const clip = TextRenderer.PixelClip.fromRect(damage[0], scale);
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
    fn partialDamageClip(win: anytype, frame: keywork.RenderBackend.Frame, buffer: *Buffer, width: u31, height: u31) ?TextRenderer.PixelClip {
        if (frame.damage.len != 1) return null;
        const clip = TextRenderer.PixelClip.fromRect(frame.damage[0], win.protocol.scale);
        if (clip.x0 <= 0 and clip.y0 <= 0 and clip.x1 >= width and clip.y1 >= height) return null;

        const last = win.renderer.last_rendered orelse return null;
        if (win.renderer.last_rendered_scale != win.protocol.scale) return null;
        if (last == buffer) return clip;
        if (last.width != width or last.height != height) return null;
        if (win.renderer.history.canRepair(buffer.frame, width, height)) {
            repairRegions(buffer.pixels(), last.pixels(), width, height, win.renderer.history.entries[0..win.renderer.history.len], buffer.frame, clip);
        } else {
            copyPixels(buffer.pixels(), last.pixels());
        }
        return clip;
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

/// Damage records for recently committed primary frames, newest first.
/// A reused buffer the compositor held for several frames is repaired by
/// copying only the regions that changed in the interim, instead of the
/// whole frame.
const DamageHistory = struct {
    entries: [capacity]Entry = undefined,
    len: usize = 0,
    width: u31 = 0,
    height: u31 = 0,

    /// More frames than the compositor plausibly holds buffers for;
    /// wl_shm double/triple buffering stays well under this.
    const capacity = 8;

    const Entry = struct {
        frame: u64,
        clip: TextRenderer.PixelClip,
    };

    fn record(self: *DamageHistory, frame: u64, width: u31, height: u31, clip: TextRenderer.PixelClip) void {
        if (self.width != width or self.height != height) {
            self.len = 0;
            self.width = width;
            self.height = height;
        }
        std.debug.assert(self.len == 0 or frame == self.entries[0].frame + 1);
        const count = @min(self.len + 1, capacity);
        var index = count - 1;
        while (index > 0) : (index -= 1) self.entries[index] = self.entries[index - 1];
        self.entries[0] = .{ .frame = frame, .clip = clip };
        self.len = count;
    }

    /// Whether the history covers every frame committed after
    /// `buffer_frame`, i.e. a stale buffer can be repaired from damage
    /// records alone.
    fn canRepair(self: *const DamageHistory, buffer_frame: u64, width: u31, height: u31) bool {
        if (buffer_frame == 0) return false;
        if (self.len == 0 or self.width != width or self.height != height) return false;
        return self.entries[self.len - 1].frame <= buffer_frame + 1;
    }
};

/// Copy the regions damaged after `buffer_frame` from `src` into `dst`,
/// skipping regions the current frame repaints anyway. Entries must be
/// ordered newest first.
fn repairRegions(
    dst: []u32,
    src: []const u32,
    width: u31,
    height: u31,
    entries: []const DamageHistory.Entry,
    buffer_frame: u64,
    repaint: TextRenderer.PixelClip,
) void {
    for (entries) |entry| {
        if (entry.frame <= buffer_frame) break;
        if (clipContains(repaint, entry.clip)) continue;
        copyRegion(dst, src, width, height, entry.clip);
    }
}

fn clipContains(outer: TextRenderer.PixelClip, inner: TextRenderer.PixelClip) bool {
    return outer.x0 <= inner.x0 and outer.y0 <= inner.y0 and
        outer.x1 >= inner.x1 and outer.y1 >= inner.y1;
}

/// Copy one clip region between equally sized frames. Full-width regions
/// collapse into a single contiguous copy so large repairs can use the
/// non-temporal path.
fn copyRegion(noalias dst: []u32, noalias src: []const u32, width: u31, height: u31, clip: TextRenderer.PixelClip) void {
    const x0 = clampClip(clip.x0, width);
    const x1 = clampClip(clip.x1, width);
    const y0 = clampClip(clip.y0, height);
    const y1 = clampClip(clip.y1, height);
    if (x0 >= x1 or y0 >= y1) return;
    if (x0 == 0 and x1 == width) {
        copyPixels(dst[y0 * width .. y1 * width], src[y0 * width .. y1 * width]);
        return;
    }
    var y = y0;
    while (y < y1) : (y += 1) {
        @memcpy(dst[y * width ..][x0..x1], src[y * width ..][x0..x1]);
    }
}

fn clampClip(value: i32, max_value: u31) usize {
    if (value <= 0) return 0;
    return @min(@as(usize, @intCast(value)), max_value);
}

/// Copy pixels into a buffer the CPU will not read back (a wl_shm
/// buffer). Large copies use non-temporal stores on x86_64: they skip
/// the read-for-ownership of every destination cache line (about a
/// third of the bus traffic) and keep the copy from evicting the render
/// working set.
fn copyPixels(noalias dst: []u32, noalias src: []const u32) void {
    std.debug.assert(dst.len == src.len);
    // Below this size the fence and alignment fixup outweigh the saved
    // traffic, and freshly written destination lines may still be hot.
    const nt_threshold = 256 * 1024 / @sizeOf(u32);
    // The self-hosted backend's assembler can't parse the SSE memory
    // operands, so the non-temporal path is LLVM-only.
    if (comptime builtin.cpu.arch == .x86_64 and builtin.zig_backend == .stage2_llvm) {
        if (dst.len >= nt_threshold) return copyNonTemporal(dst, src);
    }
    @memcpy(dst, src);
}

fn copyNonTemporal(noalias dst: []u32, noalias src: []const u32) void {
    var d: [*]u8 = @ptrCast(dst.ptr);
    var s: [*]const u8 = @ptrCast(src.ptr);
    var n: usize = dst.len * @sizeOf(u32);

    // movntdq requires a 16-byte-aligned destination.
    const misalign = @intFromPtr(d) & 15;
    if (misalign != 0) {
        const head = @min(16 - misalign, n);
        @memcpy(d[0..head], s[0..head]);
        d += head;
        s += head;
        n -= head;
    }
    while (n >= 64) {
        asm volatile (
            \\movdqu  (%%rsi), %%xmm0
            \\movdqu 16(%%rsi), %%xmm1
            \\movdqu 32(%%rsi), %%xmm2
            \\movdqu 48(%%rsi), %%xmm3
            \\movntdq %%xmm0,  (%%rdi)
            \\movntdq %%xmm1, 16(%%rdi)
            \\movntdq %%xmm2, 32(%%rdi)
            \\movntdq %%xmm3, 48(%%rdi)
            :
            : [s] "{rsi}" (s),
              [d] "{rdi}" (d),
            : .{ .xmm0 = true, .xmm1 = true, .xmm2 = true, .xmm3 = true, .memory = true });
        d += 64;
        s += 64;
        n -= 64;
    }
    if (n != 0) @memcpy(d[0..n], s[0..n]);
    // Non-temporal stores are weakly ordered; publish them before the
    // buffer is handed to the compositor.
    asm volatile ("sfence" ::: .{ .memory = true });
}

test "damage history covers only retained consecutive frames" {
    var history: DamageHistory = .{};
    try std.testing.expect(!history.canRepair(1, 4, 4));

    var frame: u64 = 1;
    while (frame <= 10) : (frame += 1) {
        history.record(frame, 4, 4, .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1 });
    }
    // Capacity 8: frames 3..10 retained, so buffers as old as frame 2
    // are repairable (their first missing frame is 3).
    try std.testing.expectEqual(@as(usize, DamageHistory.capacity), history.len);
    try std.testing.expect(history.canRepair(9, 4, 4));
    try std.testing.expect(history.canRepair(2, 4, 4));
    try std.testing.expect(!history.canRepair(1, 4, 4));
    // Never-committed buffers and size mismatches are unrecoverable.
    try std.testing.expect(!history.canRepair(0, 4, 4));
    try std.testing.expect(!history.canRepair(9, 8, 4));
}

test "damage history resets when the frame size changes" {
    var history: DamageHistory = .{};
    history.record(1, 4, 4, .{ .x0 = 0, .y0 = 0, .x1 = 4, .y1 = 4 });
    history.record(2, 8, 8, .{ .x0 = 0, .y0 = 0, .x1 = 8, .y1 = 8 });
    try std.testing.expectEqual(@as(usize, 1), history.len);
    try std.testing.expect(!history.canRepair(2, 4, 4));
    try std.testing.expect(history.canRepair(2, 8, 8));
}

test "stale buffer repair copies only interim damage" {
    const width: u31 = 4;
    const height: u31 = 4;
    var src: [width * height]u32 = undefined;
    for (&src, 0..) |*pixel, index| pixel.* = @intCast(index + 100);
    var dst: [width * height]u32 = @splat(0);

    const entries = [_]DamageHistory.Entry{
        .{ .frame = 5, .clip = .{ .x0 = 0, .y0 = 3, .x1 = 4, .y1 = 4 } },
        .{ .frame = 4, .clip = .{ .x0 = 1, .y0 = 1, .x1 = 3, .y1 = 2 } },
        .{ .frame = 3, .clip = .{ .x0 = 0, .y0 = 0, .x1 = 4, .y1 = 1 } },
    };
    // Buffer last held frame 3, so frames 4 and 5 are missing. The
    // current repaint covers frame 5's clip, leaving only frame 4's.
    repairRegions(&dst, &src, width, height, &entries, 3, .{ .x0 = 0, .y0 = 3, .x1 = 4, .y1 = 4 });

    const expected = [width * height]u32{
        0, 0,   0,   0,
        0, 105, 106, 0,
        0, 0,   0,   0,
        0, 0,   0,   0,
    };
    try std.testing.expectEqualSlices(u32, &expected, &dst);
}

test "copyRegion clamps out-of-bounds clips" {
    const width: u31 = 2;
    const height: u31 = 2;
    const src = [width * height]u32{ 1, 2, 3, 4 };
    var dst: [width * height]u32 = @splat(0);
    copyRegion(&dst, &src, width, height, .{ .x0 = -5, .y0 = -5, .x1 = 10, .y1 = 10 });
    try std.testing.expectEqualSlices(u32, &src, &dst);

    var untouched: [width * height]u32 = @splat(0);
    copyRegion(&untouched, &src, width, height, .{ .x0 = 2, .y0 = 0, .x1 = 2, .y1 = 2 });
    try std.testing.expectEqualSlices(u32, &[_]u32{ 0, 0, 0, 0 }, &untouched);
}

test "copyPixels matches the source above the non-temporal threshold" {
    const allocator = std.testing.allocator;
    // Odd length above the threshold with offset slices exercises the
    // misaligned head and short tail of the non-temporal path.
    const len = 256 * 1024 / @sizeOf(u32) + 13;
    const src_storage = try allocator.alloc(u32, len + 1);
    defer allocator.free(src_storage);
    const dst_storage = try allocator.alloc(u32, len + 1);
    defer allocator.free(dst_storage);

    var prng: std.Random.DefaultPrng = .init(0x6b657977);
    const random = prng.random();
    for (src_storage) |*pixel| pixel.* = random.int(u32);

    const src = src_storage[1..];
    const dst = dst_storage[1..];
    copyPixels(dst, src);
    try std.testing.expectEqualSlices(u32, src, dst);
}
