//! Aggregates physical and virtual keyboard ownership into protocol key state.
//! Key codes and ownership records remain parallel so focus events can borrow a
//! contiguous `u32` array without allocating.

const PressedKeyState = @This();

const std = @import("std");
const wayland = @import("wayland");

const wl = wayland.server.wl;

allocator: std.mem.Allocator,
key_codes: std.ArrayList(u32) = .empty,
owners: std.ArrayList(Owners) = .empty,

pub const Source = enum { physical, virtual };

const Owners = struct {
    physical: bool = false,
    virtual: usize = 0,

    fn any(self: Owners) bool {
        return self.physical or self.virtual != 0;
    }
};

pub fn init(allocator: std.mem.Allocator) PressedKeyState {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *PressedKeyState) void {
    self.assertValid();
    self.owners.deinit(self.allocator);
    self.key_codes.deinit(self.allocator);
    self.* = undefined;
}

/// Returns true when the aggregate protocol state changes.
pub fn update(
    self: *PressedKeyState,
    key_code: u32,
    state: wl.Keyboard.KeyState,
    source: Source,
) error{OutOfMemory}!bool {
    self.assertValid();
    switch (state) {
        .pressed => {
            if (self.find(key_code)) |index| {
                const owner = &self.owners.items[index];
                switch (source) {
                    .physical => {
                        if (owner.physical) return false;
                        owner.physical = true;
                    },
                    .virtual => owner.virtual = std.math.add(usize, owner.virtual, 1) catch
                        unreachable,
                }
                return false;
            }
            try self.key_codes.ensureUnusedCapacity(self.allocator, 1);
            try self.owners.ensureUnusedCapacity(self.allocator, 1);
            self.key_codes.appendAssumeCapacity(key_code);
            self.owners.appendAssumeCapacity(switch (source) {
                .physical => .{ .physical = true },
                .virtual => .{ .virtual = 1 },
            });
            return true;
        },
        .released => {
            const index = self.find(key_code) orelse return false;
            const owner = &self.owners.items[index];
            switch (source) {
                .physical => {
                    if (!owner.physical) return false;
                    owner.physical = false;
                },
                .virtual => {
                    if (owner.virtual == 0) return false;
                    owner.virtual -= 1;
                },
            }
            if (owner.any()) return false;
            self.remove(index);
            return true;
        },
        .repeated => return self.contains(key_code),
        else => return false,
    }
}

pub fn replacePhysical(
    self: *PressedKeyState,
    key_codes: []const u32,
) error{OutOfMemory}!void {
    self.assertValid();
    try self.key_codes.ensureUnusedCapacity(self.allocator, key_codes.len);
    try self.owners.ensureUnusedCapacity(self.allocator, key_codes.len);
    for (self.owners.items) |*owner| owner.physical = false;
    for (key_codes) |key_code| {
        if (self.find(key_code)) |index| {
            self.owners.items[index].physical = true;
            continue;
        }
        self.key_codes.appendAssumeCapacity(key_code);
        self.owners.appendAssumeCapacity(.{ .physical = true });
    }
    self.removeUnowned();
}

pub fn clearPhysical(self: *PressedKeyState) void {
    self.assertValid();
    for (self.owners.items) |*owner| owner.physical = false;
    self.removeUnowned();
}

pub fn contains(self: *const PressedKeyState, key_code: u32) bool {
    return self.find(key_code) != null;
}

/// Returns a non-owning view invalidated by the next mutation or `deinit`.
pub fn keys(self: *const PressedKeyState) []const u32 {
    self.assertValid();
    return self.key_codes.items;
}

/// Returns a non-owning view invalidated by the next mutation or `deinit`.
pub fn asWaylandArray(self: *const PressedKeyState) wl.Array {
    self.assertValid();
    return wl.Array.fromArrayList(u32, self.key_codes);
}

fn find(self: *const PressedKeyState, key_code: u32) ?usize {
    self.assertValid();
    for (self.key_codes.items, 0..) |candidate, index| {
        if (candidate == key_code) return index;
    }
    return null;
}

fn removeUnowned(self: *PressedKeyState) void {
    var index: usize = 0;
    while (index < self.owners.items.len) {
        if (self.owners.items[index].any()) {
            index += 1;
        } else {
            self.remove(index);
        }
    }
}

fn remove(self: *PressedKeyState, index: usize) void {
    _ = self.key_codes.orderedRemove(index);
    _ = self.owners.orderedRemove(index);
}

fn assertValid(self: *const PressedKeyState) void {
    std.debug.assert(self.key_codes.items.len == self.owners.items.len);
}

test "pressed key transitions aggregate physical and virtual sources" {
    var state: PressedKeyState = .init(std.testing.allocator);
    defer state.deinit();

    try std.testing.expect(try state.update(30, .pressed, .physical));
    try std.testing.expect(!try state.update(30, .pressed, .virtual));
    try std.testing.expect(!try state.update(30, .released, .physical));
    try std.testing.expect(try state.update(30, .released, .virtual));

    try std.testing.expect(try state.update(31, .pressed, .virtual));
    try std.testing.expect(!try state.update(31, .pressed, .physical));
    try std.testing.expect(!try state.update(31, .released, .virtual));
    try std.testing.expect(try state.update(31, .released, .physical));

    try std.testing.expectEqual(@as(usize, 0), state.key_codes.items.len);
}

test "repeat requires a logically pressed key and does not mutate ownership" {
    var state: PressedKeyState = .init(std.testing.allocator);
    defer state.deinit();

    try std.testing.expect(!try state.update(30, .repeated, .physical));
    try std.testing.expect(try state.update(30, .pressed, .virtual));
    try std.testing.expect(try state.update(30, .repeated, .physical));
    try std.testing.expect(try state.update(30, .released, .virtual));
    try std.testing.expect(!try state.update(30, .repeated, .virtual));
}

test "physical key replacement preserves virtual ownership" {
    var state: PressedKeyState = .init(std.testing.allocator);
    defer state.deinit();

    try std.testing.expect(try state.update(40, .pressed, .virtual));
    try state.replacePhysical(&.{ 40, 41 });
    try std.testing.expectEqualSlices(u32, &.{ 40, 41 }, state.key_codes.items);

    state.clearPhysical();
    try std.testing.expectEqualSlices(u32, &.{40}, state.key_codes.items);
    try std.testing.expect(try state.update(40, .released, .virtual));
    try std.testing.expectEqual(@as(usize, 0), state.key_codes.items.len);
}

test "borrowed pressed-key view preserves aggregate order without allocation" {
    var state: PressedKeyState = .init(std.testing.allocator);
    defer state.deinit();

    try std.testing.expect(try state.update(40, .pressed, .physical));
    try std.testing.expect(try state.update(41, .pressed, .virtual));
    const borrowed = state.keys();
    try std.testing.expectEqualSlices(u32, &.{ 40, 41 }, borrowed);
    try std.testing.expectEqual(@intFromPtr(state.key_codes.items.ptr), @intFromPtr(borrowed.ptr));

    try std.testing.expect(!try state.update(40, .pressed, .virtual));
    try std.testing.expectEqualSlices(u32, &.{ 40, 41 }, state.keys());
}
