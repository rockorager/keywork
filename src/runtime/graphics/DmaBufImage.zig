//! Retained linear DMA-BUF image for embedded native rendering.
//!
//! Retain and release are thread-safe. Mutation, publication, widget creation,
//! and source access belong to the application runtime thread.

const DmaBufImage = @This();

const std = @import("std");
const keywork = @import("keywork-ui");

const c = @cImport({
    // Zig cannot translate glibc's optimized variadic open wrappers.
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("fcntl.h");
    @cInclude("linux/dma-buf.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
});

const history_capacity = 16;
pub const linear_modifier: u64 = 0;
var next_id: std.atomic.Value(u64) = .init(1);

allocator: std.mem.Allocator,
ref_count: std.atomic.Value(usize) = .init(1),
fd: std.posix.fd_t,
mapping: []align(std.heap.page_size_min) u8,
required_bytes: usize,
width: u32,
height: u32,
stride_bytes: u32,
offset: u32,
format: Format,
modifier: u64,
synchronization: Synchronization,
writable: bool,
id: u64,
revision: u64 = 0,
writing: bool = false,
readers: u32 = 0,
history: [history_capacity]HistoryEntry = undefined,
history_len: u8 = 0,

const HistoryEntry = struct {
    revision: u64,
    damage: keywork.DamageRegion,
};

pub const Format = enum(u32) {
    /// DRM_FORMAT_ARGB8888 containing premultiplied-alpha pixels.
    argb8888_premultiplied = 0x34325241,
    /// DRM_FORMAT_XRGB8888; the high byte is ignored.
    xrgb8888 = 0x34325258,

    pub fn pixelFormat(self: Format) keywork.PixelFormat {
        return switch (self) {
            .argb8888_premultiplied => .argb8888_premultiplied,
            .xrgb8888 => .xrgb8888,
        };
    }
};

pub const Synchronization = enum {
    /// Bracket CPU access with DMA_BUF_IOCTL_SYNC.
    implicit,
    /// The application guarantees access ordering itself. This is also useful
    /// for memfd-backed tests of descriptor and rendering behavior.
    none,
};

pub const Descriptor = struct {
    /// Borrowed by import; Keywork duplicates it and never closes this fd.
    /// Device producers must return the image to foreign ownership in GENERAL
    /// layout before publishing it for Keywork's Vulkan backend.
    fd: std.posix.fd_t,
    width: u32,
    height: u32,
    stride_bytes: u32,
    offset: u32 = 0,
    format: Format,
    modifier: u64 = linear_modifier,
    synchronization: Synchronization = .implicit,
    writable: bool = false,
};

pub const Write = struct {
    pointer: [*]u8,
    byte_len: usize,
    stride_bytes: u32,
};

pub const NativeDescriptor = struct {
    fd: std.posix.fd_t,
    width: u32,
    height: u32,
    stride_bytes: u32,
    offset: u32,
    format: Format,
    modifier: u64,
};

pub fn import(allocator: std.mem.Allocator, descriptor: Descriptor) !*DmaBufImage {
    const required_bytes = try validateDescriptor(descriptor);
    const duplicate_fd = c.fcntl(descriptor.fd, c.F_DUPFD_CLOEXEC, @as(c_int, 0));
    if (duplicate_fd < 0) return error.DuplicateFdFailed;
    errdefer _ = c.close(duplicate_fd);

    var status: c.struct_stat = undefined;
    if (c.fstat(duplicate_fd, &status) != 0 or status.st_size <= 0) return error.InvalidDmaBuf;
    const mapping_len = std.math.cast(usize, status.st_size) orelse return error.InvalidDmaBuf;
    if (mapping_len < required_bytes) return error.InvalidDmaBuf;
    const protection: std.posix.PROT = if (descriptor.writable)
        .{ .READ = true, .WRITE = true }
    else
        .{ .READ = true };
    const mapping = try std.posix.mmap(
        null,
        mapping_len,
        protection,
        .{ .TYPE = .SHARED },
        duplicate_fd,
        0,
    );
    errdefer std.posix.munmap(mapping);

    const self = try allocator.create(DmaBufImage);
    self.* = .{
        .allocator = allocator,
        .fd = duplicate_fd,
        .mapping = mapping,
        .required_bytes = required_bytes,
        .width = descriptor.width,
        .height = descriptor.height,
        .stride_bytes = descriptor.stride_bytes,
        .offset = descriptor.offset,
        .format = descriptor.format,
        .modifier = descriptor.modifier,
        .synchronization = descriptor.synchronization,
        .writable = descriptor.writable,
        .id = next_id.fetchAdd(1, .monotonic),
    };
    return self;
}

fn validateDescriptor(descriptor: Descriptor) !usize {
    if (descriptor.fd < 0 or descriptor.width == 0 or descriptor.height == 0 or
        descriptor.modifier != linear_modifier or descriptor.offset % @alignOf(u32) != 0 or
        descriptor.stride_bytes % @sizeOf(u32) != 0)
    {
        return error.InvalidDmaBuf;
    }
    const row_bytes = try std.math.mul(usize, descriptor.width, @sizeOf(u32));
    if (descriptor.stride_bytes < row_bytes) return error.InvalidDmaBuf;
    const prior_rows = try std.math.mul(usize, descriptor.height - 1, descriptor.stride_bytes);
    const last_row = try std.math.add(usize, prior_rows, row_bytes);
    return std.math.add(usize, descriptor.offset, last_row);
}

pub fn retain(self: *DmaBufImage) void {
    _ = self.ref_count.fetchAdd(1, .monotonic);
}

pub fn release(self: *DmaBufImage) void {
    const previous = self.ref_count.fetchSub(1, .acq_rel);
    std.debug.assert(previous > 0);
    if (previous != 1) return;
    std.debug.assert(!self.writing and self.readers == 0);
    const allocator = self.allocator;
    std.posix.munmap(self.mapping);
    _ = c.close(self.fd);
    allocator.destroy(self);
}

pub fn nativeDescriptor(self: *const DmaBufImage) NativeDescriptor {
    return .{
        .fd = self.fd,
        .width = self.width,
        .height = self.height,
        .stride_bytes = self.stride_bytes,
        .offset = self.offset,
        .format = self.format,
        .modifier = self.modifier,
    };
}

pub fn isBusy(self: *const DmaBufImage) bool {
    return self.writing or self.readers != 0;
}

/// Starts a CPU write interval. A source concurrently being submitted reports
/// `BufferBusy`; after submission, the implicit write sync waits on Keywork's
/// GPU read-completion fence rather than requiring a fixed producer ring size.
pub fn beginWrite(self: *DmaBufImage) !Write {
    if (!self.writable) return error.ReadOnly;
    if (self.writing) return error.WriteAlreadyBegun;
    if (self.readers != 0) return error.BufferBusy;
    try self.sync(c.DMA_BUF_SYNC_WRITE);
    self.writing = true;
    return .{
        .pointer = self.mapping[self.offset..].ptr,
        .byte_len = self.required_bytes - self.offset,
        .stride_bytes = self.stride_bytes,
    };
}

pub fn cancelWrite(self: *DmaBufImage) void {
    if (!self.writing) return;
    self.writing = false;
    self.sync(c.DMA_BUF_SYNC_WRITE | c.DMA_BUF_SYNC_END) catch {};
}

/// Ends a CPU write interval and publishes its changed source rectangles.
pub fn commit(self: *DmaBufImage, rects: []const keywork.Rect) !u64 {
    if (!self.writing) return error.WriteNotBegun;
    self.writing = false;
    try self.sync(c.DMA_BUF_SYNC_WRITE | c.DMA_BUF_SYNC_END);
    return self.publishRevision(rects);
}

/// Publishes content written by an external device. Import an acquire fence
/// first when that producer is explicitly synchronized.
pub fn publish(self: *DmaBufImage, rects: []const keywork.Rect) !u64 {
    if (self.isBusy()) return error.BufferBusy;
    return self.publishRevision(rects);
}

/// Adds a producer-owned sync-file as a write fence to this DMA-BUF's
/// reservation object. The sync-file descriptor remains caller-owned.
pub fn importWriteFence(self: *DmaBufImage, sync_file_fd: std.posix.fd_t) !void {
    return self.importFence(sync_file_fd, c.DMA_BUF_SYNC_WRITE);
}

/// Adds a consumer read-completion sync-file to this DMA-BUF's reservation
/// object so its next implicit writer waits for Keywork's GPU access.
pub fn importReadFence(self: *DmaBufImage, sync_file_fd: std.posix.fd_t) !void {
    return self.importFence(sync_file_fd, c.DMA_BUF_SYNC_READ);
}

fn importFence(self: *DmaBufImage, sync_file_fd: std.posix.fd_t, flags: u32) !void {
    if (self.synchronization == .none) return;
    var import_sync_file: c.dma_buf_import_sync_file = .{
        .flags = flags,
        .fd = sync_file_fd,
    };
    while (true) {
        const result = c.ioctl(self.fd, c.DMA_BUF_IOCTL_IMPORT_SYNC_FILE, &import_sync_file);
        if (result >= 0) return;
        switch (std.posix.errno(result)) {
            .INTR, .AGAIN => continue,
            else => return error.SyncFailed,
        }
    }
}

fn publishRevision(self: *DmaBufImage, rects: []const keywork.Rect) !u64 {
    var damage: keywork.DamageRegion = .{};
    damage.addSlice(rects);
    damage.intersect(self.fullRect());
    if (damage.isEmpty()) return error.EmptyDamage;

    self.revision +%= 1;
    if (self.revision == 0) self.revision = 1;
    if (self.history_len == history_capacity) {
        for (0..history_capacity - 1) |index| self.history[index] = self.history[index + 1];
        self.history_len -= 1;
    }
    self.history[self.history_len] = .{ .revision = self.revision, .damage = damage };
    self.history_len += 1;
    return self.revision;
}

pub fn fullRect(self: *const DmaBufImage) keywork.Rect {
    return .{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(self.width),
        .height = @floatFromInt(self.height),
    };
}

pub fn widget(self: *DmaBufImage, allocator: std.mem.Allocator, logical_size: ?keywork.Size) !keywork.Widget {
    const view = try allocator.create(View);
    view.* = .{
        .buffer = self,
        .logical_size = logical_size orelse .{
            .width = @floatFromInt(self.width),
            .height = @floatFromInt(self.height),
        },
        .revision = self.revision,
    };
    return view.widget();
}

pub fn externalSource(self: *DmaBufImage) keywork.ExternalImageSource {
    return .{ .context = self, .vtable = &source_vtable };
}

/// Identifies Keywork's concrete DMA-BUF source without exposing DRM details
/// through the platform-neutral UI command contract.
pub fn fromExternalSource(source: keywork.ExternalImageSource) ?*DmaBufImage {
    if (source.vtable != &source_vtable) return null;
    return @ptrCast(@alignCast(source.context));
}

fn beginRead(self: *DmaBufImage) !keywork.ExternalImageSource.MappedPixels {
    if (self.writing) return error.WriteInProgress;
    try self.sync(c.DMA_BUF_SYNC_READ);
    self.readers += 1;
    const bytes = self.mapping[self.offset..self.required_bytes];
    const pixels: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, bytes));
    return .{
        .pixels = @ptrCast(pixels),
        .stride = self.stride_bytes / @sizeOf(u32),
        .format = self.format.pixelFormat(),
    };
}

fn endRead(self: *DmaBufImage) void {
    std.debug.assert(self.readers > 0);
    self.readers -= 1;
    self.sync(c.DMA_BUF_SYNC_READ | c.DMA_BUF_SYNC_END) catch {};
}

fn sync(self: *const DmaBufImage, flags: u64) !void {
    if (self.synchronization == .none) return;
    while (true) {
        var state: c.dma_buf_sync = .{ .flags = flags };
        const result = c.ioctl(self.fd, c.DMA_BUF_IOCTL_SYNC, &state);
        if (result >= 0) return;
        switch (std.posix.errno(result)) {
            .INTR, .AGAIN => continue,
            else => return error.SyncFailed,
        }
    }
}

fn damageSince(self: *const DmaBufImage, old_revision: u64, new_revision: u64, result: *keywork.DamageRegion) bool {
    if (old_revision == new_revision) return true;
    if (old_revision > new_revision) return false;
    var expected = old_revision + 1;
    for (self.history[0..self.history_len]) |entry| {
        if (entry.revision < expected) continue;
        if (entry.revision != expected) return false;
        result.addRegion(&entry.damage);
        if (entry.revision == new_revision) return true;
        expected += 1;
    }
    return false;
}

const source_vtable: keywork.ExternalImageSource.VTable = .{
    .retain = retainSource,
    .release = releaseSource,
    .begin_read = beginReadSource,
    .end_read = endReadSource,
    .damage_since = damageSinceSource,
};

fn retainSource(context: *anyopaque) void {
    const self: *DmaBufImage = @ptrCast(@alignCast(context));
    self.retain();
}

fn releaseSource(context: *anyopaque) void {
    const self: *DmaBufImage = @ptrCast(@alignCast(context));
    self.release();
}

fn beginReadSource(context: *anyopaque) !keywork.ExternalImageSource.MappedPixels {
    const self: *DmaBufImage = @ptrCast(@alignCast(context));
    return self.beginRead();
}

fn endReadSource(context: *anyopaque) void {
    const self: *DmaBufImage = @ptrCast(@alignCast(context));
    self.endRead();
}

fn damageSinceSource(context: *anyopaque, old_revision: u64, new_revision: u64, result: *keywork.DamageRegion) bool {
    const self: *DmaBufImage = @ptrCast(@alignCast(context));
    return self.damageSince(old_revision, new_revision, result);
}

const View = struct {
    buffer: *DmaBufImage,
    logical_size: keywork.Size,
    revision: u64,
    owns_ref: bool = false,

    fn widget(self: *const View) keywork.Widget {
        return .{ .render_object = .{
            .ptr = self,
            .vtable = &vtable,
            .clone_fn = clone,
            .destroy_fn = destroy,
        } };
    }

    const vtable: keywork.Widget.RenderObject.VTable = .{
        .layout = layout,
        .paint = paint,
        .damage = damage,
    };

    fn layout(ptr: *const anyopaque, context: keywork.Widget.RenderObject.LayoutContext) !keywork.Size {
        const self: *const View = @ptrCast(@alignCast(ptr));
        return context.constraints.clamp(self.logical_size);
    }

    fn paint(ptr: *const anyopaque, context: keywork.Widget.RenderObject.PaintContext) !void {
        const self: *const View = @ptrCast(@alignCast(ptr));
        if (self.buffer.writing) return error.WriteInProgress;
        try context.display_list.externalImage(
            context.allocator,
            context.rect,
            self.buffer.width,
            self.buffer.height,
            self.buffer.externalSource(),
            self.buffer.id,
            self.revision,
        );
    }

    fn damage(old_ptr: *const anyopaque, new_ptr: *const anyopaque, rect: keywork.Rect, result: *keywork.DamageRegion) void {
        const old: *const View = @ptrCast(@alignCast(old_ptr));
        const new: *const View = @ptrCast(@alignCast(new_ptr));
        if (old.buffer != new.buffer or !std.meta.eql(old.logical_size, new.logical_size)) {
            result.add(rect);
            return;
        }
        var source_damage: keywork.DamageRegion = .{};
        if (!new.buffer.damageSince(old.revision, new.revision, &source_damage)) {
            result.add(rect);
            return;
        }
        for (source_damage.slice()) |source| {
            result.add(.{
                .x = rect.x + source.x / @as(f32, @floatFromInt(new.buffer.width)) * rect.width,
                .y = rect.y + source.y / @as(f32, @floatFromInt(new.buffer.height)) * rect.height,
                .width = source.width / @as(f32, @floatFromInt(new.buffer.width)) * rect.width,
                .height = source.height / @as(f32, @floatFromInt(new.buffer.height)) * rect.height,
            });
        }
    }

    fn clone(allocator: std.mem.Allocator, ptr: *const anyopaque) !*const anyopaque {
        const self: *const View = @ptrCast(@alignCast(ptr));
        const result = try allocator.create(View);
        result.* = self.*;
        result.buffer.retain();
        result.owns_ref = true;
        return result;
    }

    fn destroy(allocator: std.mem.Allocator, ptr: *const anyopaque) void {
        const self: *View = @ptrCast(@alignCast(@constCast(ptr)));
        if (self.owns_ref) self.buffer.release();
        allocator.destroy(self);
    }
};

fn createTestImage(width: u32, height: u32) !*DmaBufImage {
    const byte_count = try std.math.mul(usize, try std.math.mul(usize, width, height), @sizeOf(u32));
    const fd = try std.posix.memfd_create("keywork-dmabuf-test", std.os.linux.MFD.CLOEXEC);
    defer _ = std.os.linux.close(fd);
    if (std.os.linux.errno(std.os.linux.ftruncate(fd, @intCast(byte_count))) != .SUCCESS) {
        return error.TestUnexpectedResult;
    }
    return import(std.testing.allocator, .{
        .fd = fd,
        .width = width,
        .height = height,
        .stride_bytes = width * @sizeOf(u32),
        .format = .argb8888_premultiplied,
        .synchronization = .none,
        .writable = true,
    });
}

test "DMA-BUF import duplicates ownership and brackets mapped access" {
    const image = try createTestImage(8, 4);
    defer image.release();
    try image.importReadFence(-1);
    const write = try image.beginWrite();
    try std.testing.expectEqual(@as(usize, 8 * 4 * 4), write.byte_len);
    const pixels: []u32 = @alignCast(std.mem.bytesAsSlice(u32, write.pointer[0..write.byte_len]));
    pixels[0] = 0xff12_3456;
    _ = try image.commit(&.{.{ .x = 0, .y = 0, .width = 1, .height = 1 }});

    const source = image.externalSource();
    const mapped = try source.beginRead();
    defer source.endRead();
    try std.testing.expectEqual(@as(u32, 0xff12_3456), @as(u32, @bitCast(mapped.pixels[0])));
    try std.testing.expectError(error.BufferBusy, image.beginWrite());
}

test "DMA-BUF descriptor rejects unsupported layout and short storage" {
    const fd = try std.posix.memfd_create("keywork-dmabuf-invalid", std.os.linux.MFD.CLOEXEC);
    defer _ = std.os.linux.close(fd);
    if (std.os.linux.errno(std.os.linux.ftruncate(fd, 16)) != .SUCCESS) return error.TestUnexpectedResult;
    try std.testing.expectError(error.InvalidDmaBuf, import(std.testing.allocator, .{
        .fd = fd,
        .width = 4,
        .height = 4,
        .stride_bytes = 16,
        .format = .xrgb8888,
        .modifier = 1,
    }));
    try std.testing.expectError(error.InvalidDmaBuf, import(std.testing.allocator, .{
        .fd = fd,
        .width = 4,
        .height = 4,
        .stride_bytes = 16,
        .format = .xrgb8888,
        .synchronization = .none,
    }));
}

test "DMA-BUF widget preserves disjoint damage across revisions" {
    const image = try createTestImage(100, 50);
    defer image.release();
    var old_widget = try image.widget(std.testing.allocator, .{ .width = 200, .height = 100 });
    defer old_widget.render_object.destroy(std.testing.allocator);
    _ = try image.beginWrite();
    _ = try image.commit(&.{.{ .x = 1, .y = 2, .width = 3, .height = 4 }});
    _ = try image.beginWrite();
    _ = try image.commit(&.{.{ .x = 80, .y = 30, .width = 5, .height = 6 }});

    var new_widget = try image.widget(std.testing.allocator, .{ .width = 200, .height = 100 });
    defer new_widget.render_object.destroy(std.testing.allocator);
    var damage: keywork.DamageRegion = .{};
    new_widget.render_object.vtable.damage.?(
        old_widget.render_object.ptr,
        new_widget.render_object.ptr,
        .{ .x = 10, .y = 20, .width = 200, .height = 100 },
        &damage,
    );
    try std.testing.expectEqual(@as(usize, 2), damage.slice().len);
    try std.testing.expectEqual(keywork.Rect{ .x = 12, .y = 24, .width = 6, .height = 8 }, damage.slice()[0]);
}
