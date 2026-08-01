//! Xcursor-backed `wl_shm` cursors for compositors without cursor-shape-v1.

const LegacyCursor = @This();

const std = @import("std");
const keywork = @import("keywork-ui");
const wayring = @import("wayring");
const protocol = @import("wayring-protocols");

const xcursor = @cImport({
    @cInclude("X11/Xcursor/Xcursor.h");
});

const linux = std.os.linux;
const posix = std.posix;
const log = std.log.scoped(.keywork_wayring_cursor);

const default_cursor_size = 24;

const Buffer = struct {
    shape: keywork.CursorShape,
    scale: u32,
    handle: wayring.ObjectHandle,
    width: i32,
    height: i32,
    hotspot_x: i32,
    hotspot_y: i32,
};

allocator: std.mem.Allocator,
connection: *wayring.Connection,
compositor: wayring.ObjectHandle,
shm: wayring.ObjectHandle,
surface: ?wayring.ObjectHandle = null,
buffers: std.ArrayList(Buffer) = .empty,

pub fn init(
    allocator: std.mem.Allocator,
    connection: *wayring.Connection,
    compositor: wayring.ObjectHandle,
    shm: wayring.ObjectHandle,
) !LegacyCursor {
    _ = try connection.objectForHandle(compositor, &protocol.wl_compositor);
    _ = try connection.objectForHandle(shm, &protocol.wl_shm);
    return .{
        .allocator = allocator,
        .connection = connection,
        .compositor = compositor,
        .shm = shm,
    };
}

/// The Wayland connection is already stopped when this runs, so protocol
/// objects are released by connection teardown rather than queued requests.
pub fn deinit(self: *LegacyCursor) void {
    self.buffers.deinit(self.allocator);
    self.* = undefined;
}

pub fn ownsObject(self: *const LegacyCursor, id: u32) bool {
    if (self.surface) |surface| if (surface.id == id) return true;
    for (self.buffers.items) |buffer| if (buffer.handle.id == id) return true;
    return false;
}

pub fn handleMessage(self: *LegacyCursor, message: *const wayring.Message) !void {
    if (self.surface) |surface| {
        if (surface.id == message.object_id) {
            _ = try protocol.wl_surface_types.decodeEvent(self.connection, surface, message);
            return;
        }
    }
    for (self.buffers.items) |buffer| {
        if (buffer.handle.id != message.object_id) continue;
        _ = try protocol.wl_buffer_types.decodeEvent(self.connection, buffer.handle, message);
        return;
    }
    return error.UnknownLegacyCursorObject;
}

/// Applies an immutable themed cursor buffer. Returning false means no theme
/// image was available; callers may retain their previous cursor.
pub fn apply(
    self: *LegacyCursor,
    pointer: wayring.ObjectHandle,
    serial: u32,
    shape: keywork.CursorShape,
    requested_scale: u32,
) !bool {
    if (requested_scale == 0 or requested_scale > std.math.maxInt(i32))
        return error.InvalidCursorScale;
    const surface = self.surface orelse created: {
        const created = try protocol.wl_compositor_types.requests.create_surface(
            self.connection,
            self.compositor,
        );
        self.surface = created;
        break :created created;
    };
    const registered_surface = try self.connection.objectForHandle(surface, &protocol.wl_surface);
    const scale = if (registered_surface.version >= 3) requested_scale else 1;
    const buffer = self.findBuffer(shape, scale) orelse
        (try self.createBuffer(shape, scale) orelse return false);

    if (registered_surface.version >= 3) {
        try protocol.wl_surface_types.requests.set_buffer_scale(
            self.connection,
            surface,
            @intCast(scale),
        );
    }
    try protocol.wl_pointer_types.requests.set_cursor(
        self.connection,
        pointer,
        serial,
        surface,
        @divTrunc(buffer.hotspot_x, @as(i32, @intCast(scale))),
        @divTrunc(buffer.hotspot_y, @as(i32, @intCast(scale))),
    );
    try protocol.wl_surface_types.requests.attach(
        self.connection,
        surface,
        buffer.handle,
        0,
        0,
    );
    if (registered_surface.version >= 4) {
        try protocol.wl_surface_types.requests.damage_buffer(
            self.connection,
            surface,
            0,
            0,
            buffer.width,
            buffer.height,
        );
    } else {
        try protocol.wl_surface_types.requests.damage(
            self.connection,
            surface,
            0,
            0,
            buffer.width,
            buffer.height,
        );
    }
    try protocol.wl_surface_types.requests.commit(self.connection, surface);
    return true;
}

fn findBuffer(self: *LegacyCursor, shape: keywork.CursorShape, scale: u32) ?Buffer {
    for (self.buffers.items) |buffer| {
        if (buffer.shape == shape and buffer.scale == scale) return buffer;
    }
    return null;
}

fn createBuffer(self: *LegacyCursor, shape: keywork.CursorShape, scale: u32) !?Buffer {
    const requested_size = std.math.mul(u32, default_cursor_size, scale) catch
        return error.CursorSizeOverflow;
    if (requested_size > std.math.maxInt(c_int)) return error.CursorSizeOverflow;
    const image = loadImage(shape, @intCast(requested_size)) orelse return null;
    defer xcursor.XcursorImageDestroy(image);

    if (image.pixels == null or image.width == 0 or image.height == 0 or
        image.xhot >= image.width or image.yhot >= image.height)
    {
        log.warn("Xcursor theme returned an invalid {t} image", .{shape});
        return null;
    }
    const stride = std.math.mul(u32, image.width, @sizeOf(u32)) catch
        return error.CursorSizeOverflow;
    const byte_count = std.math.mul(u32, stride, image.height) catch
        return error.CursorSizeOverflow;
    if (stride > std.math.maxInt(i32) or byte_count > std.math.maxInt(i32) or
        image.width > std.math.maxInt(i32) or image.height > std.math.maxInt(i32))
    {
        return error.CursorSizeOverflow;
    }

    try self.buffers.ensureUnusedCapacity(self.allocator, 1);
    const fd = try posix.memfd_create("keywork-wayring-cursor", linux.MFD.CLOEXEC);
    var fd_owned = true;
    defer if (fd_owned) {
        _ = linux.close(fd);
    };
    if (linux.errno(linux.ftruncate(fd, @intCast(byte_count))) != .SUCCESS)
        return error.CursorShmFailed;
    const mapping = try posix.mmap(
        null,
        byte_count,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    defer posix.munmap(mapping);
    const pixels: [*]const u8 = @ptrCast(image.pixels);
    @memcpy(mapping, pixels[0..byte_count]);

    const pool = try protocol.wl_shm_types.requests.create_pool(
        self.connection,
        self.shm,
        fd,
        @intCast(byte_count),
    );
    fd_owned = false;
    errdefer protocol.wl_shm_pool_types.requests.destroy(self.connection, pool) catch {};
    const handle = try protocol.wl_shm_pool_types.requests.create_buffer(
        self.connection,
        pool,
        0,
        @intCast(image.width),
        @intCast(image.height),
        @intCast(stride),
        @intFromEnum(protocol.wl_shm_types.format.argb8888),
    );
    errdefer protocol.wl_buffer_types.requests.destroy(self.connection, handle) catch {};
    try protocol.wl_shm_pool_types.requests.destroy(self.connection, pool);

    const buffer: Buffer = .{
        .shape = shape,
        .scale = scale,
        .handle = handle,
        .width = @intCast(image.width),
        .height = @intCast(image.height),
        .hotspot_x = @intCast(image.xhot),
        .hotspot_y = @intCast(image.yhot),
    };
    self.buffers.appendAssumeCapacity(buffer);
    return buffer;
}

fn loadImage(shape: keywork.CursorShape, size: c_int) ?*xcursor.XcursorImage {
    const theme = std.c.getenv("XCURSOR_THEME");
    const names: [2][*:0]const u8 = switch (shape) {
        .default => .{ "default", "left_ptr" },
        .pointer => .{ "pointer", "hand2" },
        .text => .{ "text", "xterm" },
    };
    for (names) |name| {
        const image = xcursor.XcursorLibraryLoadImage(
            name,
            if (theme) |value| value else null,
            size,
        ) orelse continue;
        return @ptrCast(image);
    }
    log.warn("Xcursor theme has no {t} image at size {d}", .{ shape, size });
    return null;
}

test "legacy cursor queues one immutable shm buffer per shape and scale" {
    var connection = wayring.Connection.init(
        std.testing.allocator,
        .client,
        wayring.default_max_frame_size,
    );
    defer connection.deinit();
    const compositor: wayring.ObjectHandle = .{
        .id = 2,
        .generation = try connection.registerObject(2, &protocol.wl_compositor, 6),
    };
    const shm: wayring.ObjectHandle = .{
        .id = 3,
        .generation = try connection.registerObject(3, &protocol.wl_shm, 1),
    };
    const pointer: wayring.ObjectHandle = .{
        .id = 4,
        .generation = try connection.registerObject(4, &protocol.wl_pointer, 8),
    };
    var cursor = try LegacyCursor.init(std.testing.allocator, &connection, compositor, shm);
    defer cursor.deinit();

    if (!try cursor.apply(pointer, 1, .default, 1)) return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, 1), cursor.buffers.items.len);
    var fd_count: usize = 0;
    while (connection.nextBatch()) |batch| {
        fd_count += batch.fds.len;
        try connection.acknowledge(batch.token, batch.bytes.len);
    }
    try std.testing.expectEqual(@as(usize, 1), fd_count);

    try std.testing.expect(try cursor.apply(pointer, 2, .default, 1));
    while (connection.nextBatch()) |batch| {
        try std.testing.expectEqual(@as(usize, 0), batch.fds.len);
        try connection.acknowledge(batch.token, batch.bytes.len);
    }
    try std.testing.expectEqual(@as(usize, 1), cursor.buffers.items.len);
}

test {
    std.testing.refAllDecls(LegacyCursor);
}
