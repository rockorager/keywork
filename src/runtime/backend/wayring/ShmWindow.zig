//! CPU rasterizer and `wl_shm` presentation state for one Wayring surface.
//!
//! Buffers remain mapped until the compositor releases them. Closing retires
//! released buffers immediately and waits for every busy buffer before the
//! surrounding window destroys its surface.

const ShmWindow = @This();

const std = @import("std");
const keywork = @import("keywork-ui");
const wayring = @import("wayring");
const protocol = @import("wayring-protocols");
const raster = @import("../../graphics/raster.zig");
const ShmFrameHistory = @import("../../graphics/ShmFrameHistory.zig");
const TextRenderer = @import("../../graphics/text.zig");

const linux = std.os.linux;
const posix = std.posix;

const Buffer = struct {
    handle: wayring.ObjectHandle,
    data: []align(std.heap.page_size_min) u8,
    width: u31,
    height: u31,
    busy: bool = false,
    retiring: bool = false,
    /// ShmWindow.frame_counter value when this buffer was last committed;
    /// zero means the buffer has never held a complete frame.
    frame: u64 = 0,

    fn create(
        allocator: std.mem.Allocator,
        connection: *wayring.Connection,
        shm: wayring.ObjectHandle,
        width: u31,
        height: u31,
    ) !*Buffer {
        const dimensions = try bufferDimensions(width, height);
        const fd = try posix.memfd_create("keywork-wayring-shm", linux.MFD.CLOEXEC);
        var fd_owned = true;
        defer if (fd_owned) {
            _ = linux.close(fd);
        };
        if (linux.errno(linux.ftruncate(fd, @intCast(dimensions.size))) != .SUCCESS)
            return error.ShmFailed;

        const data = try posix.mmap(
            null,
            dimensions.size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        errdefer posix.munmap(data);
        const self = try allocator.create(Buffer);
        errdefer allocator.destroy(self);

        const pool = try protocol.wl_shm_types.requests.create_pool(
            connection,
            shm,
            fd,
            @intCast(dimensions.size),
        );
        fd_owned = false;
        errdefer protocol.wl_shm_pool_types.requests.destroy(connection, pool) catch {};
        const handle = try protocol.wl_shm_pool_types.requests.create_buffer(
            connection,
            pool,
            0,
            @intCast(width),
            @intCast(height),
            dimensions.stride,
            @intFromEnum(protocol.wl_shm_types.format.argb8888),
        );
        errdefer protocol.wl_buffer_types.requests.destroy(connection, handle) catch {};
        try protocol.wl_shm_pool_types.requests.destroy(connection, pool);

        self.* = .{
            .handle = handle,
            .data = data,
            .width = width,
            .height = height,
        };
        return self;
    }

    fn pixels(self: *Buffer) []u32 {
        const count = @as(usize, self.width) * @as(usize, self.height);
        return @alignCast(std.mem.bytesAsSlice(u32, self.data)[0..count]);
    }

    fn deinit(self: *Buffer, allocator: std.mem.Allocator) void {
        posix.munmap(self.data);
        allocator.destroy(self);
    }
};

const BufferDimensions = struct {
    stride: i32,
    size: usize,
};

allocator: std.mem.Allocator,
connection: *wayring.Connection,
surface: wayring.ObjectHandle,
shm: wayring.ObjectHandle,
renderer: TextRenderer,
buffers: std.ArrayList(*Buffer) = .empty,
width: u31 = 0,
height: u31 = 0,
last_rendered: ?*Buffer = null,
last_rendered_scale: f32 = 0,
frame_counter: u64 = 0,
history: ShmFrameHistory = .{},

pub fn init(
    allocator: std.mem.Allocator,
    connection: *wayring.Connection,
    surface: wayring.ObjectHandle,
    shm: wayring.ObjectHandle,
) !ShmWindow {
    return .{
        .allocator = allocator,
        .connection = connection,
        .surface = surface,
        .shm = shm,
        .renderer = try TextRenderer.init(allocator),
    };
}

/// Call only after normal retirement completes or the connection can no
/// longer deliver buffer releases.
pub fn deinit(self: *ShmWindow) void {
    for (self.buffers.items) |buffer| {
        self.connection.retireObject(buffer.handle) catch {};
        buffer.deinit(self.allocator);
    }
    self.buffers.deinit(self.allocator);
    self.renderer.deinit();
    self.* = undefined;
}

pub fn configure(self: *ShmWindow, width: u32, height: u32) !void {
    if (width == 0 or height == 0) return error.EmptyTarget;
    const next_width = std.math.cast(u31, width) orelse return error.ShmBufferTooLarge;
    const next_height = std.math.cast(u31, height) orelse return error.ShmBufferTooLarge;
    _ = try bufferDimensions(next_width, next_height);
    self.width = next_width;
    self.height = next_height;
}

pub fn ownsObject(self: *const ShmWindow, id: u32) bool {
    for (self.buffers.items) |buffer| if (buffer.handle.id == id) return true;
    return false;
}

pub fn handleMessage(self: *ShmWindow, message: *const wayring.Message) !void {
    for (self.buffers.items, 0..) |buffer, index| {
        if (buffer.handle.id != message.object_id) continue;
        _ = try protocol.wl_buffer_types.decodeEvent(
            self.connection,
            buffer.handle,
            message,
        );
        buffer.busy = false;
        if (buffer.retiring) try self.destroyBuffer(index);
        return;
    }
    return error.UnknownShmBuffer;
}

pub fn presentWithFrame(self: *ShmWindow, frame: keywork.RenderBackend.Frame) !?wayring.ObjectHandle {
    if (self.width == 0 or self.height == 0) return error.EmptyTarget;
    const buffer = try self.acquireBuffer();
    const damage_region = self.partialDamageRegion(frame, buffer);
    if (frame.partial_display_list and damage_region == null) return error.PartialPaintUnavailable;
    if (damage_region) |region| {
        for (region.slice()) |clip| {
            try raster.rasterize(
                &self.renderer,
                buffer.pixels(),
                self.width,
                self.height,
                frame.scale,
                frame.display_list,
                clip,
            );
        }
    } else {
        try raster.rasterize(
            &self.renderer,
            buffer.pixels(),
            self.width,
            self.height,
            frame.scale,
            frame.display_list,
            null,
        );
    }

    const callback = try protocol.wl_surface_types.requests.frame(self.connection, self.surface);
    errdefer self.connection.retireObject(callback) catch {};
    try protocol.wl_surface_types.requests.attach(
        self.connection,
        self.surface,
        buffer.handle,
        0,
        0,
    );
    if (damage_region) |region| {
        for (region.slice()) |clip| {
            const x0: i32 = @max(0, clip.x0);
            const y0: i32 = @max(0, clip.y0);
            const x1: i32 = @min(@as(i32, self.width), clip.x1);
            const y1: i32 = @min(@as(i32, self.height), clip.y1);
            try protocol.wl_surface_types.requests.damage_buffer(
                self.connection,
                self.surface,
                x0,
                y0,
                @max(0, x1 - x0),
                @max(0, y1 - y0),
            );
        }
    } else {
        try protocol.wl_surface_types.requests.damage_buffer(
            self.connection,
            self.surface,
            0,
            0,
            @intCast(self.width),
            @intCast(self.height),
        );
    }
    try protocol.wl_surface_types.requests.commit(self.connection, self.surface);
    buffer.busy = true;
    self.last_rendered = buffer;
    self.last_rendered_scale = frame.scale;
    self.frame_counter += 1;
    buffer.frame = self.frame_counter;
    var committed_region: ShmFrameHistory.PixelRegion = .{};
    if (damage_region) |region| {
        committed_region = region;
    } else {
        committed_region.add(.{
            .x0 = 0,
            .y0 = 0,
            .x1 = self.width,
            .y1 = self.height,
        });
    }
    self.history.record(self.frame_counter, self.width, self.height, committed_region);
    return callback;
}

pub fn partialPaintBounds(
    self: *const ShmWindow,
    scale: f32,
    damage: []const keywork.Rect,
) ?keywork.Rect {
    if (scale != self.last_rendered_scale or damage.len == 0) return null;
    const last = self.last_rendered orelse return null;
    if (last.width != self.width or last.height != self.height) return null;

    var region: ShmFrameHistory.PixelRegion = .{};
    for (damage) |rect| region.add(TextRenderer.PixelClip.fromRect(rect, scale));
    const clip = region.bounds() orelse return null;
    if (clip.x0 >= clip.x1 or clip.y0 >= clip.y1) return null;
    if (clip.x0 <= 0 and clip.y0 <= 0 and clip.x1 >= self.width and clip.y1 >= self.height) return null;

    const x0: f32 = @floatFromInt(@max(0, clip.x0));
    const y0: f32 = @floatFromInt(@max(0, clip.y0));
    const x1: f32 = @floatFromInt(@min(@as(i32, self.width), clip.x1));
    const y1: f32 = @floatFromInt(@min(@as(i32, self.height), clip.y1));
    return .{
        .x = x0 / scale,
        .y = y0 / scale,
        .width = (x1 - x0) / scale,
        .height = (y1 - y0) / scale,
    };
}

pub fn retireAll(self: *ShmWindow) !bool {
    var index = self.buffers.items.len;
    while (index > 0) {
        index -= 1;
        const buffer = self.buffers.items[index];
        buffer.retiring = true;
        if (!buffer.busy) try self.destroyBuffer(index);
    }
    return self.buffers.items.len == 0;
}

pub fn measureText(
    self: *ShmWindow,
    scale: f32,
    value: []const u8,
    style: keywork.ResolvedTextStyle,
) !keywork.Size {
    return self.renderer.measure(scale, value, style);
}

pub fn textMetrics(self: *ShmWindow, scale: f32, font_size: f32) !keywork.TextMetrics {
    return self.renderer.metrics(scale, font_size);
}

fn acquireBuffer(self: *ShmWindow) !*Buffer {
    var index: usize = 0;
    while (index < self.buffers.items.len) {
        const buffer = self.buffers.items[index];
        if (buffer.busy) {
            index += 1;
            continue;
        }
        if (buffer.width == self.width and buffer.height == self.height) return buffer;
        try self.destroyBuffer(index);
    }

    try self.buffers.ensureUnusedCapacity(self.allocator, 1);
    const buffer = try Buffer.create(
        self.allocator,
        self.connection,
        self.shm,
        self.width,
        self.height,
    );
    self.buffers.appendAssumeCapacity(buffer);
    return buffer;
}

fn partialDamageRegion(
    self: *ShmWindow,
    frame: keywork.RenderBackend.Frame,
    buffer: *Buffer,
) ?ShmFrameHistory.PixelRegion {
    if (frame.damage.len == 0) return null;
    var region: ShmFrameHistory.PixelRegion = .{};
    for (frame.damage) |rect| region.add(TextRenderer.PixelClip.fromRect(rect, frame.scale));
    const bounds = region.bounds() orelse return null;
    if (region.len == 1 and bounds.x0 <= 0 and bounds.y0 <= 0 and
        bounds.x1 >= self.width and bounds.y1 >= self.height)
    {
        return null;
    }

    const last = self.last_rendered orelse return null;
    if (self.last_rendered_scale != frame.scale) return null;
    if (last == buffer) return region;
    if (last.width != self.width or last.height != self.height or
        buffer.width != self.width or buffer.height != self.height)
    {
        return null;
    }
    if (self.history.canRepair(buffer.frame, self.width, self.height)) {
        ShmFrameHistory.repairRegions(
            buffer.pixels(),
            last.pixels(),
            self.width,
            self.height,
            self.history.entries[0..self.history.len],
            buffer.frame,
            region,
        );
    } else {
        ShmFrameHistory.copyPixels(buffer.pixels(), last.pixels());
    }
    return region;
}

fn destroyBuffer(self: *ShmWindow, index: usize) !void {
    const buffer = self.buffers.items[index];
    std.debug.assert(!buffer.busy);
    try protocol.wl_buffer_types.requests.destroy(self.connection, buffer.handle);
    _ = self.buffers.orderedRemove(index);
    if (self.last_rendered == buffer) self.last_rendered = null;
    buffer.deinit(self.allocator);
}

fn bufferDimensions(width: u31, height: u31) !BufferDimensions {
    if (width == 0 or height == 0) return error.EmptyTarget;
    const stride = @as(usize, width) * @sizeOf(u32);
    const size = stride * @as(usize, height);
    if (stride > std.math.maxInt(i32) or size > std.math.maxInt(i32))
        return error.ShmBufferTooLarge;
    return .{ .stride = @intCast(stride), .size = size };
}

test "SHM buffer dimensions reject empty and overflowing targets" {
    try std.testing.expectEqual(
        BufferDimensions{ .stride = 256, .size = 16_384 },
        try bufferDimensions(64, 64),
    );
    try std.testing.expectError(error.EmptyTarget, bufferDimensions(0, 64));
    try std.testing.expectError(
        error.ShmBufferTooLarge,
        bufferDimensions(std.math.maxInt(u31), 2),
    );
}

test "SHM buffer transfers one pool descriptor and keeps its mapping" {
    var connection = wayring.Connection.init(
        std.testing.allocator,
        .client,
        wayring.default_max_frame_size,
    );
    defer connection.deinit();
    const shm: wayring.ObjectHandle = .{
        .id = 2,
        .generation = try connection.registerObject(2, &protocol.wl_shm, 1),
    };
    const buffer = try Buffer.create(std.testing.allocator, &connection, shm, 8, 4);
    defer {
        connection.retireObject(buffer.handle) catch {};
        buffer.deinit(std.testing.allocator);
    }

    buffer.pixels()[0] = 0xff112233;
    try std.testing.expectEqual(@as(u32, 0xff112233), buffer.pixels()[0]);
    var fd_count: usize = 0;
    while (connection.nextBatch()) |batch| {
        fd_count += batch.fds.len;
        try connection.acknowledge(batch.token, batch.bytes.len);
    }
    try std.testing.expectEqual(@as(usize, 1), fd_count);
}

test {
    std.testing.refAllDecls(ShmWindow);
}
