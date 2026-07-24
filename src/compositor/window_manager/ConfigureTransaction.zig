//! Coalesces layout changes behind a bounded configure/commit barrier.

const ConfigureTransaction = @This();

const std = @import("std");

state: State = .idle,
remaining: u32 = 0,
dirty: bool = false,

const State = enum { idle, inflight, timed_out };

pub fn begin(self: *ConfigureTransaction, count: u32) void {
    std.debug.assert(self.state == .idle);
    self.remaining = count;
    self.state = if (count == 0) .idle else .inflight;
}

/// Returns false and remembers the change while a transaction is in flight.
pub fn change(self: *ConfigureTransaction) bool {
    if (self.state == .inflight) {
        self.dirty = true;
        return false;
    }
    return true;
}

/// Returns true when the final expected participant commits.
pub fn configured(self: *ConfigureTransaction) bool {
    if (self.state != .inflight) return false;
    std.debug.assert(self.remaining > 0);
    self.remaining -= 1;
    if (self.remaining != 0) return false;
    self.state = .idle;
    return true;
}

/// Removing an expected participant completes its place in the barrier.
pub fn removed(self: *ConfigureTransaction, was_pending: bool) bool {
    return if (was_pending) self.configured() else false;
}

pub fn timeout(self: *ConfigureTransaction) bool {
    if (self.state != .inflight) return false;
    self.state = .timed_out;
    self.remaining = 0;
    return true;
}

pub fn isInflight(self: *const ConfigureTransaction) bool {
    return self.state == .inflight;
}

/// Clears the coalesced-change flag and returns a timed-out transaction to idle.
pub fn consumeDirty(self: *ConfigureTransaction) bool {
    const value = self.dirty;
    self.dirty = false;
    if (self.state == .timed_out) self.state = .idle;
    return value;
}

test "configure transaction coalesces changes until every participant completes" {
    var transaction: ConfigureTransaction = .{};
    transaction.begin(2);
    try std.testing.expect(transaction.isInflight());
    try std.testing.expect(!transaction.change());
    try std.testing.expect(!transaction.change());
    try std.testing.expect(!transaction.removed(false));
    try std.testing.expect(!transaction.configured());
    try std.testing.expect(transaction.removed(true));
    try std.testing.expect(!transaction.isInflight());
    try std.testing.expect(transaction.consumeDirty());
    try std.testing.expect(!transaction.consumeDirty());
}

test "configure transaction timeout ignores late completions and resets after publication" {
    var transaction: ConfigureTransaction = .{};
    transaction.begin(1);
    try std.testing.expect(transaction.timeout());
    try std.testing.expect(!transaction.timeout());
    try std.testing.expect(!transaction.configured());
    try std.testing.expect(!transaction.removed(true));
    _ = transaction.consumeDirty();

    transaction.begin(0);
    try std.testing.expect(!transaction.isInflight());
}
