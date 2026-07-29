//! Focus-scoped inhibition of compositor keyboard shortcuts.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Seat = @import("seat.zig");
const Surface = @import("surface.zig");

const wl = wayland.server.wl;
const zwp = wayland.server.zwp;

allocator: std.mem.Allocator,
global: *wl.Global,
inhibitors: std.ArrayList(*Inhibitor),

pub fn init(self: *Self, allocator: std.mem.Allocator, display: *wl.Server) !void {
    self.* = .{
        .allocator = allocator,
        .global = try wl.Global.create(
            display,
            zwp.KeyboardShortcutsInhibitManagerV1,
            1,
            *Self,
            self,
            bind,
        ),
        .inhibitors = .empty,
    };
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.inhibitors.items.len == 0);
    self.global.destroy();
    self.inhibitors.deinit(self.allocator);
    self.* = undefined;
}

pub fn inhibitsSeatNamed(self: *const Self, name: []const u8) bool {
    for (self.inhibitors.items) |inhibitor| {
        if (inhibitor.active and std.mem.eql(u8, inhibitor.seat.name(), name)) return true;
    }
    return false;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = zwp.KeyboardShortcutsInhibitManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleManagerRequest, null, self);
}

fn handleManagerRequest(
    resource: *zwp.KeyboardShortcutsInhibitManagerV1,
    request: zwp.KeyboardShortcutsInhibitManagerV1.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .inhibit_shortcuts => |inhibit| self.createInhibitor(
            resource,
            inhibit.id,
            inhibit.surface,
            inhibit.seat,
        ) catch resource.postNoMemory(),
    }
}

fn createInhibitor(
    self: *Self,
    manager_resource: *zwp.KeyboardShortcutsInhibitManagerV1,
    id: u32,
    surface_resource: *wl.Surface,
    seat_resource: *wl.Seat,
) !void {
    const surface_id = Surface.fromResource(surface_resource).handle();
    const seat = Seat.fromResource(seat_resource);
    for (self.inhibitors.items) |inhibitor| {
        if (inhibitor.surface_resource != null and inhibitor.seat == seat and
            std.meta.eql(inhibitor.surface_id, surface_id))
        {
            manager_resource.postError(
                .already_inhibited,
                "keyboard shortcuts are already inhibited for this surface and seat",
            );
            return;
        }
    }

    const resource = try zwp.KeyboardShortcutsInhibitorV1.create(
        manager_resource.getClient(),
        manager_resource.getVersion(),
        id,
    );
    errdefer resource.destroy();
    const inhibitor = try self.allocator.create(Inhibitor);
    errdefer self.allocator.destroy(inhibitor);
    inhibitor.* = .{
        .manager = self,
        .resource = resource,
        .surface_resource = surface_resource,
        .surface_id = surface_id,
        .seat = seat,
        .surface_destroy_listener = wl.Listener(*wl.Resource).init(handleSurfaceDestroyed),
    };
    @as(*wl.Resource, @ptrCast(surface_resource)).addDestroyListener(
        &inhibitor.surface_destroy_listener,
    );
    errdefer inhibitor.surface_destroy_listener.link.remove();
    try seat.addKeyboardFocusListener(.{
        .context = inhibitor,
        .changed = keyboardFocusChanged,
    });
    errdefer seat.removeKeyboardFocusListener(inhibitor);
    try self.inhibitors.append(self.allocator, inhibitor);
    resource.setHandler(*Inhibitor, handleInhibitorRequest, handleInhibitorDestroy, inhibitor);
    inhibitor.syncFocus();
}

const Inhibitor = struct {
    manager: *Self,
    resource: *zwp.KeyboardShortcutsInhibitorV1,
    surface_resource: ?*wl.Surface,
    surface_id: Surface.Id,
    seat: *Seat,
    surface_destroy_listener: wl.Listener(*wl.Resource),
    active: bool = false,

    fn syncFocus(self: *Inhibitor) void {
        const active = self.surface_resource != null and
            std.meta.eql(self.seat.keyboardFocusedSurface(), self.surface_id);
        if (active == self.active) return;
        self.active = active;
        if (active) self.resource.sendActive();
        // Focus loss, unmapping, and surface destruction make an inhibitor
        // irrelevant and intentionally do not produce an inactive event.
    }
};

fn handleInhibitorRequest(
    resource: *zwp.KeyboardShortcutsInhibitorV1,
    request: zwp.KeyboardShortcutsInhibitorV1.Request,
    _: *Inhibitor,
) void {
    switch (request) {
        .destroy => resource.destroy(),
    }
}

fn handleInhibitorDestroy(_: *zwp.KeyboardShortcutsInhibitorV1, inhibitor: *Inhibitor) void {
    if (inhibitor.surface_resource != null) {
        inhibitor.seat.removeKeyboardFocusListener(inhibitor);
        inhibitor.surface_destroy_listener.link.remove();
    }
    for (inhibitor.manager.inhibitors.items, 0..) |candidate, index| {
        if (candidate != inhibitor) continue;
        _ = inhibitor.manager.inhibitors.orderedRemove(index);
        inhibitor.manager.allocator.destroy(inhibitor);
        return;
    }
    unreachable;
}

fn keyboardFocusChanged(context: *anyopaque, _: ?*wl.Client) void {
    const inhibitor: *Inhibitor = @ptrCast(@alignCast(context));
    inhibitor.syncFocus();
}

fn handleSurfaceDestroyed(listener: *wl.Listener(*wl.Resource), _: *wl.Resource) void {
    const inhibitor: *Inhibitor = @fieldParentPtr("surface_destroy_listener", listener);
    listener.link.remove();
    inhibitor.seat.removeKeyboardFocusListener(inhibitor);
    inhibitor.surface_resource = null;
    inhibitor.active = false;
}

test {
    std.testing.refAllDecls(Self);
}
