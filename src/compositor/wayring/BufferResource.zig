//! Typed, retained native wl_buffer content shared by protocol producers.

const BufferResource = @This();

const std = @import("std");
const render = @import("../render/types.zig");
const shm = @import("shm.zig");

allocator: std.mem.Allocator,
references: usize = 1,
content: Content,

pub const Content = union(enum) {
    shm: shm.Buffer,
    dmabuf: Dmabuf,
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
    switch (self.content) {
        .shm => |*buffer| buffer.deinit(),
        .dmabuf => |dmabuf| dmabuf.source.release(dmabuf.source.context),
    }
    self.allocator.destroy(self);
}
