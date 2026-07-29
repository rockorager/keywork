//! XDG system bell requests.

const Self = @This();

const wayland = @import("wayland");

const wl = wayland.server.wl;
const xdg = wayland.server.xdg;

global: *wl.Global,

pub fn init(self: *Self, display: *wl.Server) !void {
    self.* = .{
        .global = try wl.Global.create(display, xdg.SystemBellV1, 1, *Self, self, bind),
    };
}

pub fn deinit(self: *Self) void {
    self.global.destroy();
    self.* = undefined;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = xdg.SystemBellV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleRequest, null, self);
}

fn handleRequest(
    resource: *xdg.SystemBellV1,
    request: xdg.SystemBellV1.Request,
    _: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .ring => {},
    }
}
