//! Desktop-oriented logical output metadata.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Output = @import("output.zig");
const OutputLayout = @import("output_layout.zig");
const Surface = @import("surface.zig");

const wl = wayland.server.wl;
const zxdg = wayland.server.zxdg;

allocator: std.mem.Allocator,
global: *wl.Global,
outputs: *OutputLayout,
resources: std.ArrayList(*OutputResource),

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    outputs: *OutputLayout,
) !void {
    self.* = .{
        .allocator = allocator,
        .global = try wl.Global.create(display, zxdg.OutputManagerV1, 3, *Self, self, bind),
        .outputs = outputs,
        .resources = .empty,
    };
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.resources.items.len == 0);
    self.global.destroy();
    self.resources.deinit(self.allocator);
    self.* = undefined;
}

pub fn refresh(self: *Self, output: *Output) void {
    for (self.resources.items) |managed| {
        if (managed.output != output) continue;
        managed.sendUpdate();
    }
}

pub fn removeOutput(self: *Self, output: *Output) void {
    var index = self.resources.items.len;
    while (index > 0) {
        index -= 1;
        const managed = self.resources.items[index];
        if (managed.output != output) continue;
        managed.output = null;
        managed.wl_output = null;
    }
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = zxdg.OutputManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, managerRequest, null, self);
}

fn managerRequest(
    resource: *zxdg.OutputManagerV1,
    request: zxdg.OutputManagerV1.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .get_xdg_output => |get| {
            const output = self.outputs.findResource(get.output);
            self.createOutput(
                resource,
                get.id,
                if (output == null) null else get.output,
                if (output) |entry| entry.output else null,
            );
        },
    }
}

fn createOutput(
    self: *Self,
    manager: *zxdg.OutputManagerV1,
    id: u32,
    output_resource: ?*wl.Output,
    output: ?*Output,
) void {
    const resource = zxdg.OutputV1.create(
        manager.getClient(),
        manager.getVersion(),
        id,
    ) catch {
        manager.postNoMemory();
        return;
    };
    const managed = self.allocator.create(OutputResource) catch {
        resource.postNoMemory();
        resource.destroy();
        return;
    };
    managed.* = .{
        .manager = self,
        .resource = resource,
        .wl_output = output_resource,
        .output = output,
    };
    self.resources.append(self.allocator, managed) catch {
        self.allocator.destroy(managed);
        resource.postNoMemory();
        resource.destroy();
        return;
    };
    resource.setHandler(*OutputResource, outputRequest, outputDestroyed, managed);
    managed.sendInitialState();
}

const OutputResource = struct {
    manager: *Self,
    resource: *zxdg.OutputV1,
    wl_output: ?*wl.Output,
    output: ?*Output,

    fn sendInitialState(self: *OutputResource) void {
        self.sendUpdate();
        if (self.resource.getVersion() < 3) return;
        const wl_output = self.wl_output orelse return;
        if (wl_output.getVersion() >= wl.Output.done_since_version) wl_output.sendDone();
    }

    fn sendUpdate(self: *OutputResource) void {
        const output = self.output orelse return;
        const position = output.logicalPosition();
        const size = output.logicalSize();
        self.resource.sendLogicalPosition(position.x, position.y);
        self.resource.sendLogicalSize(@intCast(size.width), @intCast(size.height));
        if (self.resource.getVersion() >= zxdg.OutputV1.name_since_version) {
            self.resource.sendName(output.name());
            self.resource.sendDescription(output.description());
        }
        if (self.resource.getVersion() < 3) self.resource.sendDone();
    }
};

fn outputRequest(
    resource: *zxdg.OutputV1,
    request: zxdg.OutputV1.Request,
    _: *OutputResource,
) void {
    switch (request) {
        .destroy => resource.destroy(),
    }
}

fn outputDestroyed(_: *zxdg.OutputV1, managed: *OutputResource) void {
    const self = managed.manager;
    for (self.resources.items, 0..) |candidate, index| {
        if (candidate != managed) continue;
        _ = self.resources.orderedRemove(index);
        self.allocator.destroy(managed);
        return;
    }
    unreachable;
}

test "removing an output leaves xdg-output resources alive and inert" {
    const display = try wl.Server.create();
    defer display.destroy();

    var sockets: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM | std.c.SOCK.CLOEXEC, 0, &sockets),
    );
    defer _ = std.c.close(sockets[1]);
    const client = wl.Client.create(display, sockets[0]) orelse return error.OutOfMemory;
    defer client.destroy();

    var surfaces: Surface.Store = .{};
    defer surfaces.deinit(std.testing.allocator);
    var outputs: OutputLayout = undefined;
    outputs.init(std.testing.allocator, display, &surfaces);
    defer outputs.deinit();

    var output: Output = undefined;
    try output.init(
        std.testing.allocator,
        display,
        .{
            .size = .{ .width = 1280, .height = 720 },
            .physical_size = .{ .width = 1280, .height = 720 },
            .scale = 1,
            .name = "HEADLESS-1",
            .description = "Keywork headless output",
            .model = "headless",
        },
        &surfaces,
    );
    defer output.deinit();

    var manager: Self = undefined;
    try manager.init(std.testing.allocator, display, &outputs);
    defer manager.deinit();

    const wl_output = try wl.Output.create(client, 4, 0);
    defer wl_output.destroy();
    const manager_resource = try zxdg.OutputManagerV1.create(client, 3, 0);
    defer manager_resource.destroy();
    manager.createOutput(manager_resource, 0, wl_output, &output);
    try std.testing.expectEqual(@as(usize, 1), manager.resources.items.len);
    const resource = manager.resources.items[0].resource;
    const resource_id = resource.getId();

    manager.removeOutput(&output);
    try std.testing.expect(manager.resources.items[0].output == null);
    try std.testing.expect(manager.resources.items[0].wl_output == null);
    try std.testing.expect(client.getObject(resource_id) != null);

    resource.destroy();
    try std.testing.expectEqual(@as(usize, 0), manager.resources.items.len);
}
