//! Typed generational handles and slot storage.

const std = @import("std");

pub fn SlotMap(comptime Value: type, comptime Tag: type) type {
    return struct {
        const Self = @This();

        pub const Id = struct {
            index: u32,
            generation: u32,
            _tag: Tag = @enumFromInt(0),
        };

        const Slot = struct {
            generation: u32 = 1,
            value: ?Value = null,
            next_free: ?u32 = null,
        };

        slots: std.ArrayList(Slot) = .empty,
        free_head: ?u32 = null,
        count: usize = 0,

        /// Requires all values to have been removed; this does not deinitialize them.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            std.debug.assert(self.count == 0);
            self.slots.deinit(allocator);
            self.* = undefined;
        }

        pub fn insert(
            self: *Self,
            allocator: std.mem.Allocator,
            value: Value,
        ) error{OutOfMemory}!Id {
            const index = if (self.free_head) |free_index| index: {
                const slot = &self.slots.items[free_index];
                std.debug.assert(slot.value == null);
                self.free_head = slot.next_free;
                slot.next_free = null;
                break :index free_index;
            } else index: {
                if (self.slots.items.len >= std.math.maxInt(u32)) return error.OutOfMemory;
                self.slots.append(allocator, .{}) catch return error.OutOfMemory;
                break :index @as(u32, @intCast(self.slots.items.len - 1));
            };

            const slot = &self.slots.items[index];
            slot.value = value;
            self.count += 1;
            return .{ .index = index, .generation = slot.generation };
        }

        /// The returned pointer is invalidated by an insert that reallocates this map.
        /// Resolve handles near their point of use rather than retaining this pointer.
        pub fn get(self: *Self, id: Id) ?*Value {
            const slot = self.getSlot(id) orelse return null;
            return if (slot.value) |*value| value else null;
        }

        /// The returned pointer is invalidated by an insert that reallocates this map.
        pub fn getConst(self: *const Self, id: Id) ?*const Value {
            const slot = self.getSlotConst(id) orelse return null;
            return if (slot.value) |*value| value else null;
        }

        pub fn remove(self: *Self, id: Id) ?Value {
            const slot = self.getSlot(id) orelse return null;
            const value = slot.value orelse return null;

            slot.value = null;
            if (slot.generation == std.math.maxInt(u32)) {
                // Retire exhausted slots rather than allowing a stale handle to revive.
                slot.generation = 0;
            } else {
                slot.generation += 1;
                slot.next_free = self.free_head;
                self.free_head = id.index;
            }
            self.count -= 1;
            return value;
        }

        pub fn len(self: *const Self) usize {
            return self.count;
        }

        pub const Entry = struct {
            id: Id,
            value: *Value,
        };

        pub const Iterator = struct {
            map: *Self,
            index: usize = 0,

            /// The returned value pointer follows the same invalidation rules as get().
            pub fn next(self: *Iterator) ?Entry {
                while (self.index < self.map.slots.items.len) {
                    const index = self.index;
                    self.index += 1;
                    const slot = &self.map.slots.items[index];
                    if (slot.value) |*value| return .{
                        .id = .{
                            .index = @intCast(index),
                            .generation = slot.generation,
                        },
                        .value = value,
                    };
                }
                return null;
            }
        };

        pub fn iterator(self: *Self) Iterator {
            return .{ .map = self };
        }

        fn getSlot(self: *Self, id: Id) ?*Slot {
            if (id.index >= self.slots.items.len) return null;
            const slot = &self.slots.items[id.index];
            if (slot.generation != id.generation) return null;
            return slot;
        }

        fn getSlotConst(self: *const Self, id: Id) ?*const Slot {
            if (id.index >= self.slots.items.len) return null;
            const slot = &self.slots.items[id.index];
            if (slot.generation != id.generation) return null;
            return slot;
        }
    };
}

test "removed handles remain stale after slot reuse" {
    const Store = SlotMap(u32, enum { test_value });
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);

    const first = try store.insert(std.testing.allocator, 10);
    try std.testing.expectEqual(@as(u32, 10), store.get(first).?.*);
    try std.testing.expectEqual(@as(u32, 10), store.remove(first).?);
    try std.testing.expectEqual(@as(?*u32, null), store.get(first));

    const second = try store.insert(std.testing.allocator, 20);
    try std.testing.expectEqual(first.index, second.index);
    try std.testing.expect(first.generation != second.generation);
    try std.testing.expectEqual(@as(?*u32, null), store.get(first));
    try std.testing.expectEqual(@as(u32, 20), store.remove(second).?);
}

test "generation exhaustion retires a slot instead of reviving stale handles" {
    const Store = SlotMap(u32, enum { test_value });
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);

    var exhausted = try store.insert(std.testing.allocator, 10);
    store.slots.items[exhausted.index].generation = std.math.maxInt(u32);
    exhausted.generation = std.math.maxInt(u32);
    try std.testing.expectEqual(@as(u32, 10), store.remove(exhausted).?);
    try std.testing.expectEqual(@as(?u32, null), store.free_head);

    const current = try store.insert(std.testing.allocator, 20);
    try std.testing.expect(current.index != exhausted.index);
    try std.testing.expectEqual(@as(?*const u32, null), store.getConst(exhausted));
    try std.testing.expectEqual(@as(u32, 20), store.remove(current).?);
}

test "handle types are distinct between stores" {
    const SurfaceStore = SlotMap(u8, enum { surface });
    const WindowStore = SlotMap(u8, enum { window });

    try std.testing.expect(SurfaceStore.Id != WindowStore.Id);
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(SurfaceStore.Id));
}

test "iterator skips vacant slots and preserves handles" {
    const Store = SlotMap(u32, enum { value });
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);

    const first = try store.insert(std.testing.allocator, 10);
    const removed = try store.insert(std.testing.allocator, 20);
    const third = try store.insert(std.testing.allocator, 30);
    try std.testing.expectEqual(@as(u32, 20), store.remove(removed).?);

    var iterator_value = store.iterator();
    const first_entry = iterator_value.next().?;
    try std.testing.expect(std.meta.eql(first, first_entry.id));
    try std.testing.expectEqual(@as(u32, 10), first_entry.value.*);
    const third_entry = iterator_value.next().?;
    try std.testing.expect(std.meta.eql(third, third_entry.id));
    try std.testing.expectEqual(@as(u32, 30), third_entry.value.*);
    try std.testing.expectEqual(@as(?Store.Entry, null), iterator_value.next());

    try std.testing.expectEqual(@as(u32, 10), store.remove(first).?);
    try std.testing.expectEqual(@as(u32, 30), store.remove(third).?);
}
