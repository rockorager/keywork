//! XDG dialog and modal toplevel hints.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const XdgShell = @import("xdg_shell.zig");

const wl = wayland.server.wl;
const xdg = wayland.server.xdg;

allocator: std.mem.Allocator,
global: *wl.Global,
xdg_shell: *XdgShell,
dialogs: std.ArrayList(*Dialog),

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    xdg_shell: *XdgShell,
) !void {
    self.* = .{
        .allocator = allocator,
        .global = undefined,
        .xdg_shell = xdg_shell,
        .dialogs = .empty,
    };
    errdefer self.dialogs.deinit(allocator);
    self.global = try wl.Global.create(display, xdg.WmDialogV1, 1, *Self, self, bind);
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
    std.debug.assert(self.dialogs.items.len == 0);
    self.xdg_shell.removeWindowObserver(self);
    self.global.destroy();
    self.dialogs.deinit(self.allocator);
    self.* = undefined;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = xdg.WmDialogV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleManagerRequest, null, self);
}

fn handleManagerRequest(
    resource: *xdg.WmDialogV1,
    request: xdg.WmDialogV1.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .get_xdg_dialog => |get| Dialog.create(self, resource, get.toplevel, get.id),
    }
}

const Dialog = struct {
    manager: *Self,
    window_id: ?XdgShell.WindowId,
    resource_alive: bool,

    fn create(
        manager: *Self,
        manager_resource: *xdg.WmDialogV1,
        toplevel_resource: *xdg.Toplevel,
        id: u32,
    ) void {
        const resource = xdg.DialogV1.create(
            manager_resource.getClient(),
            manager_resource.getVersion(),
            id,
        ) catch {
            manager_resource.postNoMemory();
            return;
        };
        if (toplevel_resource.getClient() != manager_resource.getClient()) {
            resource.destroy();
            manager_resource.getClient().postImplementationError(
                "xdg_toplevel belongs to another client",
            );
            return;
        }
        const toplevel = manager.xdg_shell.toplevelFromResource(toplevel_resource) orelse {
            resource.destroy();
            manager_resource.getClient().postImplementationError("invalid xdg_toplevel resource");
            return;
        };
        for (manager.dialogs.items) |dialog| {
            const existing = dialog.window_id orelse continue;
            if (!std.meta.eql(existing, toplevel.window_id)) continue;
            resource.destroy();
            manager_resource.postError(
                .already_used,
                "xdg_toplevel already has an xdg_dialog_v1 object",
            );
            return;
        }
        const self = manager.allocator.create(Dialog) catch {
            resource.destroy();
            manager_resource.postNoMemory();
            return;
        };
        self.* = .{
            .manager = manager,
            .window_id = toplevel.window_id,
            .resource_alive = true,
        };
        manager.dialogs.append(manager.allocator, self) catch {
            manager.allocator.destroy(self);
            resource.destroy();
            manager_resource.postNoMemory();
            return;
        };
        manager.xdg_shell.setDialogState(toplevel.window_id, true, false);
        resource.setHandler(*Dialog, handleRequest, handleDestroy, self);
    }

    fn handleRequest(
        resource: *xdg.DialogV1,
        request: xdg.DialogV1.Request,
        self: *Dialog,
    ) void {
        switch (request) {
            .destroy => resource.destroy(),
            .set_modal => self.setModal(true),
            .unset_modal => self.setModal(false),
        }
    }

    fn setModal(self: *Dialog, modal: bool) void {
        const window_id = self.window_id orelse return;
        self.manager.xdg_shell.setDialogState(window_id, true, modal);
    }

    fn handleDestroy(_: *xdg.DialogV1, self: *Dialog) void {
        if (self.window_id) |window_id| {
            self.manager.xdg_shell.setDialogState(window_id, false, false);
            self.resource_alive = false;
            return;
        }
        self.destroy();
    }

    fn destroy(self: *Dialog) void {
        for (self.manager.dialogs.items, 0..) |dialog, index| {
            if (dialog != self) continue;
            _ = self.manager.dialogs.orderedRemove(index);
            self.manager.allocator.destroy(self);
            return;
        }
        unreachable;
    }
};

fn windowCommitted(_: *anyopaque, _: XdgShell.WindowId) void {}

fn windowUnmapped(_: *anyopaque, _: XdgShell.WindowId) void {}

fn windowDestroyed(context: *anyopaque, window_id: XdgShell.WindowId) void {
    const self: *Self = @ptrCast(@alignCast(context));
    for (self.dialogs.items) |dialog| {
        const candidate = dialog.window_id orelse continue;
        if (!std.meta.eql(candidate, window_id)) continue;
        dialog.window_id = null;
        if (!dialog.resource_alive) dialog.destroy();
        return;
    }
}

fn windowMetadataChanged(_: *anyopaque, _: XdgShell.WindowId) void {}

fn windowStateChanged(_: *anyopaque, _: XdgShell.WindowId) void {}
