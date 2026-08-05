//! Mature libwayland display serial issuance and domain typing.

const std = @import("std");
const wayland = @import("wayland");
const ClientRegistry = @import("../ClientRegistry.zig");

const wl = wayland.server.wl;

pub fn issue(display: *wl.Server) ClientRegistry.Serial {
    return fromWire(issueWire(display));
}

pub fn issueWire(display: *wl.Server) u32 {
    const current = display.getSerial();
    const expected = claim(current) orelse std.debug.panic(
        "mature Wayland display serial exhausted at {d}; refusing to emit zero or reuse a serial",
        .{current},
    );
    const serial = display.nextSerial();
    if (serial != expected) std.debug.panic(
        "mature Wayland display serial changed while issuing: expected {d}, got {d}",
        .{ expected, serial },
    );
    return serial;
}

pub fn fromWire(value: u32) ClientRegistry.Serial {
    return .{ .domain = .mature_display, .value = value };
}

fn claim(current: u32) ?u32 {
    if (current == std.math.maxInt(u32)) return null;
    return current + 1;
}

test "claims are nonzero and unique through the exhaustion edge" {
    const max = std.math.maxInt(u32);
    try std.testing.expectEqual(@as(u32, 1), claim(0).?);

    const penultimate = claim(max - 2).?;
    const last = claim(penultimate).?;
    try std.testing.expectEqual(max - 1, penultimate);
    try std.testing.expectEqual(max, last);
    try std.testing.expect(penultimate != 0);
    try std.testing.expect(last != 0);
    try std.testing.expect(penultimate != last);
    try std.testing.expect(claim(last) == null);
}

test "typed serials use the mature display domain" {
    const serial = fromWire(std.math.maxInt(u32));
    try std.testing.expectEqual(ClientRegistry.SerialDomain.mature_display, serial.domain);
    try std.testing.expectEqual(std.math.maxInt(u32), serial.value);
}
