//! Pure ranking and z-position policy for DRM overlay-plane assignment.

const std = @import("std");

pub const Zpos = struct {
    property_id: u32,
    current: u64,
    maximum: u64,
    immutable: bool,
};

pub const AssignmentZpos = struct {
    property_id: ?u32,
    value: u64,
};

pub const Rank = struct {
    attachment: u8,
    possible_crtc_count: u8,
    plane_id: u32,

    pub fn betterThan(self: Rank, other: Rank) bool {
        if (self.attachment != other.attachment) return self.attachment > other.attachment;
        if (self.possible_crtc_count != other.possible_crtc_count) {
            return self.possible_crtc_count < other.possible_crtc_count;
        }
        return self.plane_id < other.plane_id;
    }
};

pub fn rank(
    plane_id: u32,
    plane_crtc_id: u32,
    possible_crtcs: u32,
    crtc_id: u32,
    preferred_plane_id: ?u32,
) Rank {
    const attachment: u8 = if (preferred_plane_id == plane_id and
        (plane_crtc_id == 0 or plane_crtc_id == crtc_id))
        3
    else if (plane_crtc_id == crtc_id)
        2
    else if (plane_crtc_id == 0)
        1
    else
        0;
    return .{
        .attachment = attachment,
        .possible_crtc_count = @intCast(@popCount(possible_crtcs)),
        .plane_id = plane_id,
    };
}

pub fn overlayZpos(zpos: Zpos, primary_zpos: u64) ?AssignmentZpos {
    const value = if (zpos.current > primary_zpos)
        zpos.current
    else if (zpos.immutable or zpos.maximum <= primary_zpos)
        return null
    else
        primary_zpos + 1;
    return .{
        .property_id = if (zpos.immutable) null else zpos.property_id,
        .value = value,
    };
}

test "ranking preserves assignments and constrained planes" {
    const preferred = rank(7, 0, 0b111, 10, 7);
    const attached = rank(8, 10, 0b001, 10, 7);
    const free = rank(9, 0, 0b001, 10, 7);
    const flexible = rank(10, 0, 0b111, 10, 7);
    const unavailable = rank(11, 20, 0b001, 10, 7);
    try std.testing.expect(preferred.betterThan(attached));
    try std.testing.expect(attached.betterThan(free));
    try std.testing.expect(free.betterThan(flexible));
    try std.testing.expectEqual(@as(u8, 0), unavailable.attachment);
}

test "overlay z-position remains above the primary plane" {
    const immutable: Zpos = .{
        .property_id = 1,
        .current = 2,
        .maximum = 2,
        .immutable = true,
    };
    const mutable: Zpos = .{
        .property_id = 1,
        .current = 0,
        .maximum = 3,
        .immutable = false,
    };
    try std.testing.expectEqual(
        AssignmentZpos{ .property_id = null, .value = 2 },
        overlayZpos(immutable, 0).?,
    );
    try std.testing.expectEqual(
        AssignmentZpos{ .property_id = 1, .value = 1 },
        overlayZpos(mutable, 0).?,
    );
    try std.testing.expect(overlayZpos(.{
        .property_id = 1,
        .current = 0,
        .maximum = 0,
        .immutable = true,
    }, 0) == null);
}
