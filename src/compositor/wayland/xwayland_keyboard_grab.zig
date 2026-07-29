//! Private Xwayland keyboard grabs.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Seat = @import("seat.zig");
const SecurityContext = @import("security_context.zig");
const Surface = @import("surface.zig");

const wl = wayland.server.wl;
const zwp = wayland.server.zwp;

allocator: std.mem.Allocator,
global: *wl.Global,
security_context: *SecurityContext,
authorized_client: ?*wl.Client,
authorized_client_destroy: wl.Listener(*wl.Client),
grabs: std.ArrayList(*Grab),
next_token: u64,

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    security_context: *SecurityContext,
) !void {
    const global = try wl.Global.create(
        display,
        zwp.XwaylandKeyboardGrabManagerV1,
        1,
        *Self,
        self,
        bind,
    );
    errdefer global.destroy();
    try security_context.privatizeGlobal(global);
    self.* = .{
        .allocator = allocator,
        .global = global,
        .security_context = security_context,
        .authorized_client = null,
        .authorized_client_destroy = wl.Listener(*wl.Client).init(handleAuthorizedClientDestroy),
        .grabs = .empty,
        .next_token = 1,
    };
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.authorized_client == null);
    std.debug.assert(self.grabs.items.len == 0);
    self.grabs.deinit(self.allocator);
    self.security_context.unprivatizeGlobal(self.global);
    self.global.destroy();
}

pub fn authorizeClient(self: *Self, client: *wl.Client) void {
    std.debug.assert(self.authorized_client == null);
    self.authorized_client = client;
    client.addDestroyListener(&self.authorized_client_destroy);
    self.security_context.authorizePrivateGlobal(self.global, client);
}

pub fn cancelAll(self: *Self) void {
    for (self.grabs.items) |grab| grab.deactivate(true);
}

fn handleAuthorizedClientDestroy(listener: *wl.Listener(*wl.Client), client: *wl.Client) void {
    const self: *Self = @fieldParentPtr("authorized_client_destroy", listener);
    std.debug.assert(self.authorized_client == client);
    listener.link.remove();
    self.security_context.clearPrivateGlobalClient(self.global);
    self.authorized_client = null;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    if (self.authorized_client != client) {
        client.postImplementationError("Xwayland keyboard grabs are restricted to Xwayland");
        return;
    }
    const resource = zwp.XwaylandKeyboardGrabManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleManagerRequest, null, self);
}

fn handleManagerRequest(
    resource: *zwp.XwaylandKeyboardGrabManagerV1,
    request: zwp.XwaylandKeyboardGrabManagerV1.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .grab_keyboard => |grab| Grab.create(
            self,
            resource,
            grab.id,
            grab.surface,
            grab.seat,
        ) catch resource.postNoMemory(),
    }
}

const Grab = struct {
    manager: *Self,
    resource: *zwp.XwaylandKeyboardGrabV1,
    seat: *Seat,
    surface_resource: ?*wl.Surface,
    surface_destroy: wl.Listener(*wl.Resource),
    token: u64,
    active: bool,

    fn create(
        manager: *Self,
        manager_resource: *zwp.XwaylandKeyboardGrabManagerV1,
        id: u32,
        surface_resource: *wl.Surface,
        seat_resource: *wl.Seat,
    ) !void {
        const resource = try zwp.XwaylandKeyboardGrabV1.create(
            manager_resource.getClient(),
            manager_resource.getVersion(),
            id,
        );
        errdefer resource.destroy();
        const grab = try manager.allocator.create(Grab);
        errdefer manager.allocator.destroy(grab);
        const surface = Surface.fromResource(surface_resource);
        const seat = Seat.fromResource(seat_resource);
        grab.* = .{
            .manager = manager,
            .resource = resource,
            .seat = seat,
            .surface_resource = surface_resource,
            .surface_destroy = wl.Listener(*wl.Resource).init(handleSurfaceDestroy),
            .token = manager.next_token,
            .active = false,
        };
        manager.next_token +%= 1;
        if (manager.next_token == 0) manager.next_token = 1;
        try manager.grabs.append(manager.allocator, grab);
        errdefer _ = manager.grabs.pop();
        @as(*wl.Resource, @ptrCast(surface_resource)).addDestroyListener(&grab.surface_destroy);
        resource.setHandler(*Grab, handleRequest, handleDestroy, grab);

        if (surface.assignedRole() == .xwayland) {
            grab.active = seat.trySetKeyboardGrab(.{
                .context = grab,
                .token = grab.token,
                .surface = surface.handle(),
                .keymap = unusedSendKeymap,
                .repeat_info = unusedSendRepeatInfo,
                .key = unusedSendKey,
                .modifiers = unusedSendModifiers,
                .cancel = cancel,
            });
        }
    }

    fn handleRequest(
        resource: *zwp.XwaylandKeyboardGrabV1,
        request: zwp.XwaylandKeyboardGrabV1.Request,
        _: *Grab,
    ) void {
        switch (request) {
            .destroy => resource.destroy(),
        }
    }

    fn handleDestroy(_: *zwp.XwaylandKeyboardGrabV1, grab: *Grab) void {
        if (grab.surface_resource != null) grab.surface_destroy.link.remove();
        grab.deactivate(true);
        for (grab.manager.grabs.items, 0..) |candidate, i| {
            if (candidate != grab) continue;
            _ = grab.manager.grabs.swapRemove(i);
            break;
        }
        grab.manager.allocator.destroy(grab);
    }

    fn handleSurfaceDestroy(listener: *wl.Listener(*wl.Resource), _: *wl.Resource) void {
        const grab: *Grab = @fieldParentPtr("surface_destroy", listener);
        listener.link.remove();
        grab.surface_resource = null;
        grab.deactivate(true);
    }

    fn deactivate(grab: *Grab, restore_focus: bool) void {
        if (!grab.active) return;
        grab.active = false;
        grab.seat.clearKeyboardGrab(grab, restore_focus);
    }

    fn cancel(context: *anyopaque) void {
        const grab: *Grab = @ptrCast(@alignCast(context));
        grab.deactivate(true);
    }

    fn unusedSendKeymap(_: *anyopaque, _: wl.Keyboard.KeymapFormat, _: std.posix.fd_t, _: u32) void {
        unreachable;
    }

    fn unusedSendRepeatInfo(_: *anyopaque, _: i32, _: i32) void {
        unreachable;
    }

    fn unusedSendKey(_: *anyopaque, _: u32, _: u32, _: u32, _: wl.Keyboard.KeyState) void {
        unreachable;
    }

    fn unusedSendModifiers(_: *anyopaque, _: u32, _: u32, _: u32, _: u32) void {
        unreachable;
    }
};
