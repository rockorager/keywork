//! Tracks scene damage not yet applied to each double-buffered scanout target.

const BufferDamageTracker = @This();

const std = @import("std");
const Logging = @import("../logging.zig");
const Region = @import("../region.zig");
const render = @import("../render/types.zig");

const log = std.log.scoped(.drm);

pub const buffer_count = 2;

backlogs: [buffer_count]Region,
frame_damage: Region,
active_index: ?usize,

pub fn init() BufferDamageTracker {
    return .{
        .backlogs = .{ Region.init(), Region.init() },
        .frame_damage = Region.init(),
        .active_index = null,
    };
}

pub fn deinit(self: *BufferDamageTracker) void {
    std.debug.assert(self.active_index == null);
    for (&self.backlogs) |*damage| damage.deinit();
    self.frame_damage.deinit();
    self.* = undefined;
}

pub fn isIdle(self: *const BufferDamageTracker) bool {
    return self.active_index == null;
}

/// Marks every buffer stale across the complete output after allocation or
/// direct scanout replaces the composited image.
pub noinline fn reset(self: *BufferDamageTracker, size: render.Size) void {
    std.debug.assert(self.isIdle());
    log.debug("resetting full buffer damage from 0x{x}", .{@returnAddress()});
    for (&self.backlogs) |*damage| {
        damage.setRectangle(0, 0, size.width, size.height);
    }
}

/// Retains the scene damage before repair so finishing this frame propagates
/// only new changes, never the acquired buffer's stale backlog.
pub fn beginFrame(
    self: *BufferDamageTracker,
    index: usize,
    damage: *Region,
) Region.Error!void {
    std.debug.assert(index < self.backlogs.len);
    std.debug.assert(self.isIdle());
    try self.frame_damage.copyFrom(damage);
    self.active_index = index;
}

/// Adds the acquired persistent target's stale contents to the frame redraw.
pub fn addBacklog(
    self: *BufferDamageTracker,
    damage: *Region,
    size: render.Size,
) Region.Error!void {
    const index = self.active_index orelse unreachable;
    if (Logging.enabled(.debug)) {
        const full_damage = damage.coversRectangle(0, 0, size.width, size.height);
        const full_repair = self.backlogs[index].coversRectangle(
            0,
            0,
            size.width,
            size.height,
        );
        if (full_damage) {
            log.debug("new scene damage is full-output before buffer {d} repair", .{index});
        } else if (full_repair) {
            log.debug("buffer {d} repair adds a full-output backlog", .{index});
        }
    }
    try damage.unionWith(&self.backlogs[index]);
}

/// Returns tracker-owned storage valid until the next tracker mutation.
pub fn shadowCopyDamage(
    self: *BufferDamageTracker,
) Region.Error!*const Region {
    const index = self.active_index orelse unreachable;
    try self.backlogs[index].unionWith(&self.frame_damage);
    return &self.backlogs[index];
}

pub fn finishFrame(self: *BufferDamageTracker) Region.Error!void {
    const index = self.active_index orelse unreachable;
    for (&self.backlogs, 0..) |*damage, backlog_index| {
        if (backlog_index != index) try damage.unionWith(&self.frame_damage);
    }
    self.backlogs[index].clear();
    self.frame_damage.clear();
    self.active_index = null;
}

pub fn cancel(self: *BufferDamageTracker) void {
    self.frame_damage.clear();
    self.active_index = null;
}

pub fn clear(self: *BufferDamageTracker) void {
    self.cancel();
    for (&self.backlogs) |*damage| damage.clear();
}

test "empty frame remains active until canceled" {
    var tracker = BufferDamageTracker.init();
    defer tracker.deinit();
    var damage = Region.init();
    defer damage.deinit();

    try std.testing.expect(tracker.isIdle());
    try tracker.beginFrame(0, &damage);
    try std.testing.expect(!tracker.isIdle());
    tracker.cancel();
    try std.testing.expect(tracker.isIdle());
}

test "buffer repair does not propagate an acquired buffer's backlog" {
    var tracker = BufferDamageTracker.init();
    defer tracker.deinit();
    const size: render.Size = .{ .width = 100, .height = 100 };
    tracker.reset(size);

    var first_damage = Region.init();
    defer first_damage.deinit();
    first_damage.setRectangle(10, 10, 2, 2);
    try tracker.beginFrame(0, &first_damage);
    try tracker.addBacklog(&first_damage, size);
    try std.testing.expect(first_damage.coversRectangle(0, 0, 100, 100));
    try tracker.finishFrame();
    try std.testing.expect(tracker.backlogs[0].isEmpty());
    try std.testing.expect(tracker.backlogs[1].coversRectangle(0, 0, 100, 100));

    var second_damage = Region.init();
    defer second_damage.deinit();
    second_damage.setRectangle(20, 20, 2, 2);
    try tracker.beginFrame(1, &second_damage);
    try tracker.addBacklog(&second_damage, size);
    try std.testing.expect(second_damage.coversRectangle(0, 0, 100, 100));
    try tracker.finishFrame();
    try std.testing.expect(tracker.backlogs[0].coversRectangle(20, 20, 2, 2));
    try std.testing.expect(tracker.backlogs[1].isEmpty());

    var third_damage = Region.init();
    defer third_damage.deinit();
    third_damage.setRectangle(30, 30, 2, 2);
    try tracker.beginFrame(0, &third_damage);
    try tracker.addBacklog(&third_damage, size);
    try std.testing.expect(!third_damage.coversRectangle(0, 0, 100, 100));
    try std.testing.expect(third_damage.coversRectangle(20, 20, 2, 2));
    try std.testing.expect(third_damage.coversRectangle(30, 30, 2, 2));
    try tracker.finishFrame();
}
