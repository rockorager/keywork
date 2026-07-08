//! Context-owned image and alpha-mask resources.

const std = @import("std");
const core = @import("core.zig");
const ui = @import("ui.zig");

pub const Kind = enum { rgba8, a8 };

pub const Entry = struct {
    id: ui.ResourceId,
    kind: Kind,
    width: u32,
    height: u32,
    pixels: []u8,
    host_ref: bool = true,
    document_refs: usize = 0,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    next_id: ui.ResourceId = 1,
    entries: std.AutoHashMapUnmanaged(ui.ResourceId, Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Store) void {
        var it = self.entries.valueIterator();
        while (it.next()) |entry| self.allocator.free(entry.pixels);
        self.entries.deinit(self.allocator);
    }

    pub fn createRgba8(self: *Store, width: u32, height: u32, stride: usize, pixels: []const u8) !ui.ResourceId {
        return self.create(.rgba8, width, height, stride, 4, pixels);
    }
    pub fn createA8(self: *Store, width: u32, height: u32, stride: usize, pixels: []const u8) !ui.ResourceId {
        return self.create(.a8, width, height, stride, 1, pixels);
    }
    fn create(self: *Store, kind: Kind, width: u32, height: u32, stride: usize, bpp: usize, pixels: []const u8) !ui.ResourceId {
        if (width == 0 or height == 0 or width > std.math.maxInt(c_int) or height > std.math.maxInt(c_int)) return error.InvalidResource;
        const row = std.math.mul(usize, width, bpp) catch return error.InvalidResource;
        if (stride < row) return error.InvalidResource;
        const needed = std.math.add(usize, std.math.mul(usize, stride, height - 1) catch return error.InvalidResource, row) catch return error.InvalidResource;
        if (pixels.len < needed) return error.InvalidResource;
        const len = std.math.mul(usize, row, height) catch return error.InvalidResource;
        const copy = try self.allocator.alloc(u8, len);
        errdefer self.allocator.free(copy);
        var y: usize = 0;
        while (y < height) : (y += 1) @memcpy(copy[y * row ..][0..row], pixels[y * stride ..][0..row]);
        const id = self.next_id;
        self.next_id = std.math.add(ui.ResourceId, id, 1) catch return error.ResourceIdExhausted;
        try self.entries.put(self.allocator, id, .{ .id = id, .kind = kind, .width = width, .height = height, .pixels = copy });
        return id;
    }

    pub fn releaseHost(self: *Store, id: ui.ResourceId) void {
        if (self.entries.getPtr(id)) |entry| {
            entry.host_ref = false;
            self.collect(id, entry);
        }
    }
    pub fn retainDocument(self: *Store, id: ui.ResourceId, kind: ?Kind) !void {
        const entry = self.entries.getPtr(id) orelse return error.InvalidResource;
        if (kind) |k| if (entry.kind != k) return error.InvalidResource;
        entry.document_refs = std.math.add(usize, entry.document_refs, 1) catch return error.ResourceReferenceOverflow;
    }
    pub fn releaseDocument(self: *Store, id: ui.ResourceId) void {
        if (self.entries.getPtr(id)) |entry| {
            std.debug.assert(entry.document_refs > 0);
            entry.document_refs -= 1;
            self.collect(id, entry);
        }
    }
    fn collect(self: *Store, id: ui.ResourceId, entry: *Entry) void {
        if (!entry.host_ref and entry.document_refs == 0) {
            self.allocator.free(entry.pixels);
            _ = self.entries.remove(id);
        }
    }
    pub fn get(self: *Store, id: ui.ResourceId) ?*const Entry {
        return self.entries.getPtr(id);
    }
};

test "resource uploads copy strided pixels" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    var source = [_]u8{
        1, 2,  3,  4,  5,  6,  7,  8,  99,
        9, 10, 11, 12, 13, 14, 15, 16, 99,
    };
    const id = try store.createRgba8(2, 2, 9, &source);
    source[0] = 42;
    const entry = store.get(id).?;
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }, entry.pixels);
}

test "released resources live while documents retain them" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const id = try store.createA8(1, 1, 1, &.{255});
    try store.retainDocument(id, .a8);
    store.releaseHost(id);
    try std.testing.expect(store.get(id) != null);
    store.releaseDocument(id);
    try std.testing.expect(store.get(id) == null);
}
