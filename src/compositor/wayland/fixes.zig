//! Core protocol fixes that cannot be added to existing interfaces.

const Self = @This();

const wayland = @import("wayland");

const wl = wayland.server.wl;

global: *wl.Global,

pub fn init(self: *Self, display: *wl.Server) !void {
    self.* = .{
        .global = try wl.Global.create(display, wl.Fixes, 1, *Self, self, bind),
    };
}

pub fn deinit(self: *Self) void {
    self.global.destroy();
    self.* = undefined;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = wl.Fixes.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleRequest, null, self);
}

fn handleRequest(resource: *wl.Fixes, request: wl.Fixes.Request, _: *Self) void {
    switch (request) {
        .destroy => resource.destroy(),
        .destroy_registry => |destroy| destroy.registry.destroy(),
    }
}
