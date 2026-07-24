//! Server-side xdg_positioner state and request validation.

const XdgPositioner = @This();

const std = @import("std");
const wayland = @import("wayland");
const popup_placement = @import("xdg_popup_placement.zig");

const wl = wayland.server.wl;
const xdg = wayland.server.xdg;

allocator: std.mem.Allocator,
rules: popup_placement.Rules,

pub fn create(
    allocator: std.mem.Allocator,
    client: *wl.Client,
    version: u32,
    id: u32,
) error{ OutOfMemory, ResourceCreateFailed }!void {
    const resource = try xdg.Positioner.create(client, version, id);
    errdefer resource.destroy();

    const positioner = allocator.create(XdgPositioner) catch return error.OutOfMemory;
    positioner.* = .{ .allocator = allocator, .rules = .{} };
    resource.setHandler(*XdgPositioner, handleRequest, handleDestroy, positioner);
}

pub fn fromResource(resource: *xdg.Positioner) *XdgPositioner {
    return @ptrCast(@alignCast(resource.getUserData().?));
}

fn handleRequest(
    resource: *xdg.Positioner,
    request: xdg.Positioner.Request,
    positioner: *XdgPositioner,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .set_size => |set| {
            if (set.width <= 0 or set.height <= 0) {
                resource.postError(.invalid_input, "positioner size must be positive");
                return;
            }
            positioner.rules.size = .{ .width = set.width, .height = set.height };
        },
        .set_anchor_rect => |set| {
            if (set.width < 0 or set.height < 0) {
                resource.postError(.invalid_input, "anchor rectangle size must not be negative");
                return;
            }
            positioner.rules.anchor_rect = .{
                .x = set.x,
                .y = set.y,
                .width = set.width,
                .height = set.height,
            };
        },
        .set_anchor => |set| {
            if (!validAnchor(set.anchor)) {
                resource.postError(.invalid_input, "invalid positioner anchor");
                return;
            }
            positioner.rules.anchor = set.anchor;
        },
        .set_gravity => |set| {
            if (!validGravity(set.gravity)) {
                resource.postError(.invalid_input, "invalid positioner gravity");
                return;
            }
            positioner.rules.gravity = set.gravity;
        },
        .set_constraint_adjustment => |set| {
            const adjustment: u32 = @bitCast(set.constraint_adjustment);
            if (adjustment & ~@as(u32, 0x3f) != 0) {
                resource.postError(.invalid_input, "invalid constraint adjustment");
                return;
            }
            positioner.rules.adjustment = set.constraint_adjustment;
        },
        .set_offset => |set| positioner.rules.offset = .{ .x = set.x, .y = set.y },
        .set_reactive => positioner.rules.reactive = true,
        .set_parent_configure => |set| positioner.rules.parent_configure = set.serial,
        .set_parent_size => |set| {
            if (set.parent_width <= 0 or set.parent_height <= 0) {
                resource.postError(.invalid_input, "parent size must be positive");
                return;
            }
            positioner.rules.parent_size = .{
                .width = set.parent_width,
                .height = set.parent_height,
            };
        },
    }
}

fn handleDestroy(_: *xdg.Positioner, positioner: *XdgPositioner) void {
    positioner.allocator.destroy(positioner);
}

fn validAnchor(anchor: xdg.Positioner.Anchor) bool {
    return switch (anchor) {
        .none,
        .top,
        .bottom,
        .left,
        .right,
        .top_left,
        .bottom_left,
        .top_right,
        .bottom_right,
        => true,
        else => false,
    };
}

fn validGravity(gravity: xdg.Positioner.Gravity) bool {
    return switch (gravity) {
        .none,
        .top,
        .bottom,
        .left,
        .right,
        .top_left,
        .bottom_left,
        .top_right,
        .bottom_right,
        => true,
        else => false,
    };
}
