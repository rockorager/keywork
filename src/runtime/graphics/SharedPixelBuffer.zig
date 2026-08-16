//! Ref-counted memfd-backed CPU canvas exposed as a retained render object.

const SharedPixelBuffer = @This();

const std = @import("std");
const keywork = @import("keywork-ui");

const history_capacity = 16;
var next_id: std.atomic.Value(u64) = .init(1);

allocator: std.mem.Allocator,
ref_count: std.atomic.Value(usize) = .init(1),
fd: std.posix.fd_t,
mapping: []align(std.heap.page_size_min) u8,
width: u32,
height: u32,
stride: u32,
format: keywork.PixelFormat,
id: u64,
revision: u64 = 0,
writing: bool = false,
history: [history_capacity]HistoryEntry = undefined,
history_len: u8 = 0,

const HistoryEntry = struct {
    revision: u64,
    damage: keywork.DamageRegion,
};

pub const Write = struct {
    pointer: [*]u8,
    byte_len: usize,
    stride: u32,
};

pub fn create(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    format: keywork.PixelFormat,
) !*SharedPixelBuffer {
    if (width == 0 or height == 0) return error.InvalidPixelBuffer;
    const pixel_count = try std.math.mul(usize, width, height);
    const byte_count = try std.math.mul(usize, pixel_count, @sizeOf(u32));
    const fd = try std.posix.memfd_create("keywork-pixel-buffer", std.os.linux.MFD.CLOEXEC);
    errdefer _ = std.os.linux.close(fd);
    if (std.os.linux.errno(std.os.linux.ftruncate(fd, @intCast(byte_count))) != .SUCCESS) return error.ShmFailed;
    const mapping = try std.posix.mmap(
        null,
        byte_count,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    errdefer std.posix.munmap(mapping);

    const self = try allocator.create(SharedPixelBuffer);
    self.* = .{
        .allocator = allocator,
        .fd = fd,
        .mapping = mapping,
        .width = width,
        .height = height,
        .stride = width,
        .format = format,
        .id = next_id.fetchAdd(1, .monotonic),
    };
    return self;
}

pub fn retain(self: *SharedPixelBuffer) void {
    _ = self.ref_count.fetchAdd(1, .monotonic);
}

pub fn release(self: *SharedPixelBuffer) void {
    const previous = self.ref_count.fetchSub(1, .acq_rel);
    std.debug.assert(previous > 0);
    if (previous != 1) return;
    std.debug.assert(!self.writing);
    const allocator = self.allocator;
    std.posix.munmap(self.mapping);
    _ = std.os.linux.close(self.fd);
    allocator.destroy(self);
}

/// Opens a synchronous write interval. The returned pointer remains stable
/// for the buffer lifetime, but callers must not retain or mutate it after
/// `commit`; Keywork may read the mapping while presenting that revision.
pub fn beginWrite(self: *SharedPixelBuffer) !Write {
    if (self.writing) return error.WriteAlreadyBegun;
    self.writing = true;
    return .{
        .pointer = self.mapping.ptr,
        .byte_len = self.mapping.len,
        .stride = self.stride * @sizeOf(u32),
    };
}

/// Abandons an unpublished write interval. Intended for owner teardown after
/// a producer drops the userdata without committing.
pub fn cancelWrite(self: *SharedPixelBuffer) void {
    self.writing = false;
}

/// Publishes one immutable revision and its source-pixel damage. Multiple
/// commits may occur before a consumer rebuilds; retained history lets the
/// widget union every skipped revision or conservatively repaint in full.
pub fn commit(self: *SharedPixelBuffer, rects: []const keywork.Rect) !u64 {
    if (!self.writing) return error.WriteNotBegun;

    var damage: keywork.DamageRegion = .{};
    damage.addSlice(rects);
    damage.intersect(.{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(self.width),
        .height = @floatFromInt(self.height),
    });
    if (damage.isEmpty()) return error.EmptyDamage;

    self.writing = false;
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

pub fn fullRect(self: *const SharedPixelBuffer) keywork.Rect {
    return .{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(self.width),
        .height = @floatFromInt(self.height),
    };
}

/// Creates a borrowed build-arena view. Retaining the widget clones this
/// view and takes a strong reference to the mapping.
pub fn widget(self: *SharedPixelBuffer, allocator: std.mem.Allocator, logical_size: ?keywork.Size) !keywork.Widget {
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

fn damageSince(self: *const SharedPixelBuffer, old_revision: u64, new_revision: u64, result: *keywork.DamageRegion) bool {
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

const View = struct {
    buffer: *SharedPixelBuffer,
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
        const pixels: [*]const keywork.Color = @ptrCast(self.buffer.mapping.ptr);
        try context.display_list.colorImageStrided(
            context.allocator,
            context.rect,
            self.buffer.width,
            self.buffer.height,
            pixels[0 .. self.buffer.mapping.len / @sizeOf(u32)],
            self.buffer.stride,
            self.buffer.format,
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

test "shared pixel buffer retains disjoint damage across skipped revisions" {
    const buffer = try SharedPixelBuffer.create(std.testing.allocator, 100, 50, .xrgb8888);
    defer buffer.release();
    var old_widget = try buffer.widget(std.testing.allocator, .{ .width = 200, .height = 100 });
    defer old_widget.render_object.destroy(std.testing.allocator);
    _ = try buffer.beginWrite();
    _ = try buffer.commit(&.{.{ .x = 1, .y = 2, .width = 3, .height = 4 }});
    _ = try buffer.beginWrite();
    _ = try buffer.commit(&.{.{ .x = 80, .y = 30, .width = 5, .height = 6 }});

    var damage: keywork.DamageRegion = .{};
    try std.testing.expect(buffer.damageSince(0, 2, &damage));
    try std.testing.expectEqual(@as(usize, 2), damage.slice().len);

    var new_widget = try buffer.widget(std.testing.allocator, .{ .width = 200, .height = 100 });
    defer new_widget.render_object.destroy(std.testing.allocator);
    var widget_damage: keywork.DamageRegion = .{};
    new_widget.render_object.vtable.damage.?(
        old_widget.render_object.ptr,
        new_widget.render_object.ptr,
        .{ .x = 10, .y = 20, .width = 200, .height = 100 },
        &widget_damage,
    );
    try std.testing.expectEqual(@as(usize, 2), widget_damage.slice().len);
    try std.testing.expectEqual(keywork.Rect{ .x = 12, .y = 24, .width = 6, .height = 8 }, widget_damage.slice()[0]);
}

test "invalid pixel buffer damage keeps the write unpublished and retryable" {
    const buffer = try SharedPixelBuffer.create(std.testing.allocator, 10, 10, .xrgb8888);
    defer buffer.release();
    _ = try buffer.beginWrite();

    try std.testing.expectError(error.EmptyDamage, buffer.commit(&.{.{
        .x = 20,
        .y = 20,
        .width = 1,
        .height = 1,
    }}));
    try std.testing.expect(buffer.writing);
    try std.testing.expectEqual(@as(u64, 0), buffer.revision);

    try std.testing.expectEqual(@as(u64, 1), try buffer.commit(&.{buffer.fullRect()}));
    try std.testing.expect(!buffer.writing);
}
