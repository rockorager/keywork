//! Tracks bounded serial authorization for client-initiated actions.

const UserActionSerials = @This();

const std = @import("std");
const wayland = @import("wayland");

const wl = wayland.server.wl;

last_action: ?Action = null,
recent_actions: [history_capacity]Action = undefined,
recent_count: usize = 0,
next_action: usize = 0,

const history_capacity = 32;

const Action = struct {
    client: *wl.Client,
    serial: u32,
};

pub fn recordAction(self: *UserActionSerials, client: *wl.Client, serial: u32) void {
    self.last_action = .{ .client = client, .serial = serial };
    self.recordSelection(client, serial);
}

pub fn recordSelection(self: *UserActionSerials, client: *wl.Client, serial: u32) void {
    self.recent_actions[self.next_action] = .{ .client = client, .serial = serial };
    self.next_action = (self.next_action + 1) % history_capacity;
    self.recent_count = @min(self.recent_count + 1, history_capacity);
}

pub fn acceptsAction(self: *const UserActionSerials, client: *wl.Client, serial: u32) bool {
    const action = self.last_action orelse return false;
    return action.client == client and action.serial == serial;
}

pub fn acceptsSelection(self: *const UserActionSerials, client: *wl.Client, serial: u32) bool {
    for (self.recent_actions[0..self.recent_count]) |action| {
        if (action.client == client and action.serial == serial) return true;
    }
    return false;
}

test "latest action and selection serials have distinct authorization lifetimes" {
    const client_a: *wl.Client = @ptrFromInt(0x1000);
    const client_b: *wl.Client = @ptrFromInt(0x2000);
    var serials: UserActionSerials = .{};

    serials.recordSelection(client_a, 10);
    try std.testing.expect(!serials.acceptsAction(client_a, 10));
    try std.testing.expect(serials.acceptsSelection(client_a, 10));

    serials.recordAction(client_a, 11);
    try std.testing.expect(serials.acceptsAction(client_a, 11));
    try std.testing.expect(serials.acceptsSelection(client_a, 11));
    try std.testing.expect(!serials.acceptsAction(client_b, 11));
    try std.testing.expect(!serials.acceptsSelection(client_b, 11));

    serials.recordAction(client_b, 12);
    try std.testing.expect(!serials.acceptsAction(client_a, 11));
    try std.testing.expect(serials.acceptsAction(client_b, 12));
    try std.testing.expect(serials.acceptsSelection(client_a, 11));
}

test "selection serial history evicts the oldest entry at capacity" {
    const client: *wl.Client = @ptrFromInt(0x1000);
    var serials: UserActionSerials = .{};

    for (1..history_capacity + 2) |serial| {
        serials.recordSelection(client, @intCast(serial));
    }
    try std.testing.expect(!serials.acceptsSelection(client, 1));
    try std.testing.expect(serials.acceptsSelection(client, 2));
    try std.testing.expect(serials.acceptsSelection(client, history_capacity + 1));
}
