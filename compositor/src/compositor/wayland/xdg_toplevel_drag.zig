//! XDG toplevel movement attached to data-device drags.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const DataDevice = @import("data_device.zig");
const Scene = @import("../scene.zig");
const Seat = @import("seat.zig");
const XdgShell = @import("xdg_shell.zig");

const wl = wayland.server.wl;
const xdg = wayland.server.xdg;

allocator: std.mem.Allocator,
global: *wl.Global,
data_device: *DataDevice,
xdg_shell: *XdgShell,
seat: *Seat,
listener: Listener,
drags: std.ArrayList(*Drag),

pub const Listener = struct {
    context: *anyopaque,
    begin: *const fn (*anyopaque, XdgShell.WindowId, f64, f64, i32, i32, bool) bool,
    motion: *const fn (*anyopaque, f64, f64) void,
    end: *const fn (*anyopaque) void,
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    data_device: *DataDevice,
    xdg_shell: *XdgShell,
    seat: *Seat,
    listener: Listener,
) !void {
    self.* = .{
        .allocator = allocator,
        .global = undefined,
        .data_device = data_device,
        .xdg_shell = xdg_shell,
        .seat = seat,
        .listener = listener,
        .drags = .empty,
    };
    errdefer self.drags.deinit(allocator);
    self.global = try wl.Global.create(display, xdg.ToplevelDragManagerV1, 1, *Self, self, bind);
    errdefer self.global.destroy();
    try xdg_shell.addWindowObserver(.{
        .context = self,
        .committed = windowCommitted,
        .unmapped = windowUnmapped,
        .destroyed = windowDestroyed,
        .metadata_changed = windowMetadataChanged,
        .state_changed = windowStateChanged,
    });
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.drags.items.len == 0);
    self.xdg_shell.removeWindowObserver(self);
    self.global.destroy();
    self.drags.deinit(self.allocator);
    self.* = undefined;
}

pub fn pointerMotion(self: *Self, x: f64, y: f64) void {
    for (self.drags.items) |drag| {
        if (!drag.active) continue;
        drag.tryBeginAt(x, y);
        if (drag.moving) self.listener.motion(self.listener.context, x, y);
    }
}

pub fn attachedScene(self: *Self) ?Scene.Id {
    for (self.drags.items) |drag| {
        if (!drag.active) continue;
        const window_id = drag.attached_window orelse continue;
        const info = self.xdg_shell.windowInfo(window_id) orelse continue;
        if (info.mapped) return info.scene_id;
    }
    return null;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = xdg.ToplevelDragManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleRequest, null, self);
}

fn handleRequest(
    resource: *xdg.ToplevelDragManagerV1,
    request: xdg.ToplevelDragManagerV1.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .get_xdg_toplevel_drag => |get| Drag.create(
            self,
            resource,
            get.id,
            get.data_source,
        ),
    }
}

const Drag = struct {
    manager: *Self,
    resource: *xdg.ToplevelDragV1,
    source_resource: ?*wl.DataSource,
    attached_window: ?XdgShell.WindowId = null,
    x_offset: i32 = 0,
    y_offset: i32 = 0,
    use_offset_hint: bool = false,
    active: bool = false,
    ended: bool = false,
    moving: bool = false,

    fn create(
        manager: *Self,
        manager_resource: *xdg.ToplevelDragManagerV1,
        id: u32,
        source_resource: *wl.DataSource,
    ) void {
        const resource = xdg.ToplevelDragV1.create(
            manager_resource.getClient(),
            manager_resource.getVersion(),
            id,
        ) catch {
            manager_resource.postNoMemory();
            return;
        };
        if (source_resource.getClient() != manager_resource.getClient()) {
            resource.destroy();
            manager_resource.postError(.invalid_source, "wl_data_source belongs to another client");
            return;
        }
        const self = manager.allocator.create(Drag) catch {
            resource.postNoMemory();
            resource.destroy();
            return;
        };
        self.* = .{
            .manager = manager,
            .resource = resource,
            .source_resource = source_resource,
        };
        manager.data_device.setToplevelDragHandler(source_resource, .{
            .context = self,
            .started = dragStarted,
            .ended = dragEnded,
            .source_destroyed = sourceDestroyed,
        }) catch {
            manager.allocator.destroy(self);
            resource.destroy();
            manager_resource.postError(
                .invalid_source,
                "wl_data_source was already used or reserved",
            );
            return;
        };
        manager.drags.append(manager.allocator, self) catch {
            manager.data_device.clearToplevelDragHandler(source_resource, self);
            manager.allocator.destroy(self);
            resource.postNoMemory();
            resource.destroy();
            return;
        };
        resource.setHandler(*Drag, handleDragRequest, handleDestroy, self);
    }

    fn handleDragRequest(
        resource: *xdg.ToplevelDragV1,
        request: xdg.ToplevelDragV1.Request,
        self: *Drag,
    ) void {
        switch (request) {
            .destroy => {
                if (!self.ended) {
                    resource.postError(.ongoing_drag, "data source drag has not ended");
                    return;
                }
                resource.destroy();
            },
            .attach => |request_attach| self.attach(
                resource,
                request_attach.toplevel,
                request_attach.x_offset,
                request_attach.y_offset,
            ),
        }
    }

    fn attach(
        self: *Drag,
        resource: *xdg.ToplevelDragV1,
        toplevel_resource: *xdg.Toplevel,
        x_offset: i32,
        y_offset: i32,
    ) void {
        if (self.attached_window != null) {
            resource.postError(.toplevel_attached, "a valid xdg_toplevel is already attached");
            return;
        }
        if (toplevel_resource.getClient() != resource.getClient()) return;
        const toplevel = self.manager.xdg_shell.toplevelFromResource(toplevel_resource) orelse return;
        const info = self.manager.xdg_shell.windowInfo(toplevel.window_id) orelse return;
        self.attached_window = toplevel.window_id;
        self.x_offset = x_offset;
        self.y_offset = y_offset;
        self.use_offset_hint = !info.mapped;
        self.tryBegin();
    }

    fn tryBegin(self: *Drag) void {
        const position = self.manager.seat.pointerPosition() orelse return;
        self.tryBeginAt(position.x, position.y);
    }

    fn tryBeginAt(self: *Drag, x: f64, y: f64) void {
        if (!self.active or self.moving) return;
        const window_id = self.attached_window orelse return;
        const info = self.manager.xdg_shell.windowInfo(window_id) orelse return;
        if (!info.mapped) return;
        self.moving = self.manager.listener.begin(
            self.manager.listener.context,
            window_id,
            x,
            y,
            self.x_offset,
            self.y_offset,
            self.use_offset_hint,
        );
    }

    fn detach(self: *Drag) void {
        if (self.moving) self.manager.listener.end(self.manager.listener.context);
        self.moving = false;
        self.attached_window = null;
        self.use_offset_hint = false;
    }

    fn dragStarted(context: *anyopaque) void {
        const self: *Drag = @ptrCast(@alignCast(context));
        self.active = true;
        self.tryBegin();
    }

    fn dragEnded(context: *anyopaque) void {
        const self: *Drag = @ptrCast(@alignCast(context));
        if (self.moving) self.manager.listener.end(self.manager.listener.context);
        self.moving = false;
        self.active = false;
        self.ended = true;
    }

    fn sourceDestroyed(context: *anyopaque) void {
        const self: *Drag = @ptrCast(@alignCast(context));
        self.source_resource = null;
        self.active = false;
        self.ended = true;
        self.detach();
    }

    fn handleDestroy(_: *xdg.ToplevelDragV1, self: *Drag) void {
        if (self.source_resource) |source| {
            self.manager.data_device.clearToplevelDragHandler(source, self);
        }
        self.detach();
        for (self.manager.drags.items, 0..) |drag, index| {
            if (drag != self) continue;
            _ = self.manager.drags.orderedRemove(index);
            self.manager.allocator.destroy(self);
            return;
        }
        unreachable;
    }
};

fn windowCommitted(context: *anyopaque, window_id: XdgShell.WindowId) void {
    const self: *Self = @ptrCast(@alignCast(context));
    for (self.drags.items) |drag| {
        if (drag.attached_window) |attached| {
            if (std.meta.eql(attached, window_id)) drag.tryBegin();
        }
    }
}

fn windowUnmapped(context: *anyopaque, window_id: XdgShell.WindowId) void {
    detachWindow(@ptrCast(@alignCast(context)), window_id);
}

fn windowDestroyed(context: *anyopaque, window_id: XdgShell.WindowId) void {
    detachWindow(@ptrCast(@alignCast(context)), window_id);
}

fn detachWindow(self: *Self, window_id: XdgShell.WindowId) void {
    for (self.drags.items) |drag| {
        if (drag.attached_window) |attached| {
            if (std.meta.eql(attached, window_id)) drag.detach();
        }
    }
}

fn windowMetadataChanged(_: *anyopaque, _: XdgShell.WindowId) void {}

fn windowStateChanged(_: *anyopaque, _: XdgShell.WindowId) void {}
