//! Typed, retained native wl_buffer content shared by protocol producers.

const BufferResource = @This();

const std = @import("std");
const render = @import("../render/types.zig");
const shm = @import("shm.zig");

allocator: std.mem.Allocator,
references: usize = 1,
content: Content,
destroy_listeners: std.ArrayList(DestroyListener) = .empty,

pub const Content = union(enum) {
    shm: shm.Buffer,
    dmabuf: Dmabuf,
    single_pixel: u32,
};

pub const Dmabuf = struct {
    size: render.Size,
    source: render.DmabufSource,
    source_cache_id: u64,
    next_source_version: u64 = 1,

    pub fn acquireSourceCache(self: *Dmabuf) render.SourceCache {
        const source_cache: render.SourceCache = .{
            .id = self.source_cache_id,
            .version = self.next_source_version,
        };
        self.next_source_version +%= 1;
        if (self.next_source_version == 0) self.next_source_version = 1;
        return source_cache;
    }
};

pub const DestroyListener = struct {
    context: *anyopaque,
    destroyed: *const fn (*anyopaque) void,
};

/// Copies the listener and retains its context until removal or resource
/// destruction. Callbacks must not mutate this resource's listener list.
pub fn addDestroyListener(
    self: *BufferResource,
    listener: DestroyListener,
) error{OutOfMemory}!void {
    for (self.destroy_listeners.items) |existing|
        std.debug.assert(existing.context != listener.context);
    try self.destroy_listeners.append(self.allocator, listener);
}

pub fn removeDestroyListener(self: *BufferResource, context: *anyopaque) void {
    for (self.destroy_listeners.items, 0..) |listener, index| {
        if (listener.context != context) continue;
        _ = self.destroy_listeners.orderedRemove(index);
        return;
    }
    unreachable;
}

/// Marks the wl_buffer object dead before releasing its resource reference.
pub fn resourceDestroyed(self: *BufferResource) void {
    for (self.destroy_listeners.items) |listener|
        listener.destroyed(listener.context);
    self.destroy_listeners.clearRetainingCapacity();
    self.unreference();
}

pub fn reference(self: *BufferResource) !void {
    if (self.references == std.math.maxInt(usize)) return error.ReferenceOverflow;
    self.references += 1;
}

/// Returns true when the caller owns the final compositor use. The one other
/// possible reference belongs to the live wl_buffer resource itself.
pub fn isLastUse(self: *const BufferResource) bool {
    std.debug.assert(self.references > 0);
    return self.references <= 2;
}

pub fn unreference(self: *BufferResource) void {
    std.debug.assert(self.references > 0);
    self.references -= 1;
    if (self.references != 0) return;
    std.debug.assert(self.destroy_listeners.items.len == 0);
    self.destroy_listeners.deinit(self.allocator);
    switch (self.content) {
        .shm => |*buffer| buffer.deinit(),
        .dmabuf => |dmabuf| dmabuf.source.release(dmabuf.source.context),
        .single_pixel => {},
    }
    self.allocator.destroy(self);
}
