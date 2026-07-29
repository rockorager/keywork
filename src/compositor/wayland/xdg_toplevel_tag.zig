//! Persistent client-provided XDG toplevel identity metadata.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const XdgShell = @import("xdg_shell.zig");

const wl = wayland.server.wl;
const xdg = wayland.server.xdg;

global: *wl.Global,
xdg_shell: *XdgShell,

pub fn init(self: *Self, display: *wl.Server, xdg_shell: *XdgShell) !void {
    self.* = .{
        .global = undefined,
        .xdg_shell = xdg_shell,
    };
    self.global = try wl.Global.create(
        display,
        xdg.ToplevelTagManagerV1,
        1,
        *Self,
        self,
        bind,
    );
}

pub fn deinit(self: *Self) void {
    self.global.destroy();
    self.* = undefined;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = xdg.ToplevelTagManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleRequest, null, self);
}

fn handleRequest(
    resource: *xdg.ToplevelTagManagerV1,
    request: xdg.ToplevelTagManagerV1.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .set_toplevel_tag => |set| self.setMetadata(
            resource,
            set.toplevel,
            .tag,
            set.tag,
        ),
        .set_toplevel_description => |set| self.setMetadata(
            resource,
            set.toplevel,
            .description,
            set.description,
        ),
    }
}

fn setMetadata(
    self: *Self,
    manager_resource: *xdg.ToplevelTagManagerV1,
    toplevel_resource: *xdg.Toplevel,
    field: XdgShell.ToplevelTagField,
    value_z: [*:0]const u8,
) void {
    const client = manager_resource.getClient();
    if (toplevel_resource.getClient() != client) {
        client.postImplementationError("xdg_toplevel belongs to another client");
        return;
    }
    const toplevel = self.xdg_shell.toplevelFromResource(toplevel_resource) orelse {
        client.postImplementationError("invalid xdg_toplevel resource");
        return;
    };
    const value = std.mem.span(value_z);
    if (!std.unicode.utf8ValidateSlice(value)) {
        client.postImplementationError("toplevel tag metadata is not valid UTF-8");
        return;
    }
    self.xdg_shell.setToplevelTag(toplevel.window_id, field, value) catch
        manager_resource.postNoMemory();
}
