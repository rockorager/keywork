//! Native xdg-output logical metadata for one output.

const XdgOutputGlobal = @This();

const std = @import("std");
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const OutputGlobal = @import("OutputGlobal.zig");

const advertised_version: u32 = 3;

allocator: std.mem.Allocator,
server: *Server,
output: *OutputGlobal,
global_name: u32,
resources: std.ArrayList(*OutputResource) = .empty,

const OutputResource = struct {
    owner: *XdgOutputGlobal,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    output: ?wayring.ObjectHandle,

    fn sendInitialState(self: *OutputResource) !void {
        const output_resource = self.output orelse return;
        const position = self.owner.output.logicalPosition();
        const size = self.owner.output.logicalSize();
        try generated.zxdg_output_v1_types.events.logical_position(
            &self.client.connection,
            self.resource,
            position.x,
            position.y,
        );
        try generated.zxdg_output_v1_types.events.logical_size(
            &self.client.connection,
            self.resource,
            @intCast(size.width),
            @intCast(size.height),
        );
        const version = try self.client.resourceVersion(
            self.resource,
            &generated.zxdg_output_v1,
        );
        if (version >= 2) {
            try generated.zxdg_output_v1_types.events.name(
                &self.client.connection,
                self.resource,
                self.owner.output.outputName(),
            );
            try generated.zxdg_output_v1_types.events.description(
                &self.client.connection,
                self.resource,
                self.owner.output.outputDescription(),
            );
        }
        if (version < 3) {
            try generated.zxdg_output_v1_types.events.done(
                &self.client.connection,
                self.resource,
            );
        } else if (try self.client.resourceVersion(output_resource, &generated.wl_output) >= 2) {
            try generated.wl_output_types.events.done(&self.client.connection, output_resource);
        }
    }
};

pub fn init(
    self: *XdgOutputGlobal,
    allocator: std.mem.Allocator,
    server: *Server,
    output: *OutputGlobal,
) !void {
    self.* = .{
        .allocator = allocator,
        .server = server,
        .output = output,
        .global_name = undefined,
    };
    self.global_name = try server.createGlobal(
        &generated.zxdg_output_manager_v1,
        advertised_version,
        .{ .context = self, .bind = bind },
    );
}

pub fn deinit(self: *XdgOutputGlobal) void {
    std.debug.assert(self.resources.items.len == 0);
    self.server.removeGlobal(self.global_name) catch unreachable;
    self.resources.deinit(self.allocator);
    self.* = undefined;
}

/// Publishes logical metadata and xdg-output done for protocol v1/v2 only.
/// NativeServer publishes the transaction's wl_output.done separately.
pub fn publishLogicalUpdate(self: *XdgOutputGlobal) void {
    for (self.resources.items) |resource| sendLogicalUpdate(resource) catch {
        resource.client.postNoMemory() catch {};
    };
}

fn sendLogicalUpdate(self: *OutputResource) !void {
    if (self.output == null) return;
    const position = self.owner.output.logicalPosition();
    const size = self.owner.output.logicalSize();
    try generated.zxdg_output_v1_types.events.logical_position(
        &self.client.connection,
        self.resource,
        position.x,
        position.y,
    );
    try generated.zxdg_output_v1_types.events.logical_size(
        &self.client.connection,
        self.resource,
        @intCast(size.width),
        @intCast(size.height),
    );
    const version = try self.client.resourceVersion(self.resource, &generated.zxdg_output_v1);
    if (version < 3) try generated.zxdg_output_v1_types.events.done(
        &self.client.connection,
        self.resource,
    );
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *XdgOutputGlobal = @ptrCast(@alignCast(context));
    _ = client.createResource(id, &generated.zxdg_output_manager_v1, version, .{
        .context = self,
        .dispatch = dispatchManager,
    }) catch return client.postNoMemory();
}

fn dispatchManager(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const self: *XdgOutputGlobal = @ptrCast(@alignCast(context));
    switch (try generated.zxdg_output_manager_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .get_xdg_output => |request| {
            const managed = self.allocator.create(OutputResource) catch
                return client.postNoMemory();
            errdefer self.allocator.destroy(managed);
            self.resources.ensureUnusedCapacity(self.allocator, 1) catch
                return client.postNoMemory();
            const version = try client.resourceVersion(
                resource,
                &generated.zxdg_output_manager_v1,
            );
            managed.* = .{
                .owner = self,
                .client = client,
                .resource = undefined,
                .output = self.output.bindingHandle(client, request.output),
            };
            managed.resource = client.createResource(
                request.id,
                &generated.zxdg_output_v1,
                version,
                .{
                    .context = managed,
                    .dispatch = dispatchOutput,
                    .destroy = destroyOutput,
                },
            ) catch return client.postNoMemory();
            self.resources.appendAssumeCapacity(managed);
            managed.sendInitialState() catch return client.postNoMemory();
        },
    }
}

fn dispatchOutput(
    _: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    _ = try generated.zxdg_output_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    );
}

fn destroyOutput(
    context: *anyopaque,
    _: *Server.Client,
    _: wayring.ObjectHandle,
) void {
    const managed: *OutputResource = @ptrCast(@alignCast(context));
    for (managed.owner.resources.items, 0..) |candidate, index| {
        if (candidate != managed) continue;
        const owner = managed.owner;
        _ = owner.resources.orderedRemove(index);
        owner.allocator.destroy(managed);
        return;
    }
    unreachable;
}

test "native xdg output versions send logical metadata and matching done events" {
    const core = @import("wayring-core");
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var output: OutputGlobal = undefined;
    try output.init(std.testing.allocator, &server, .{
        .position = .{ .x = -10, .y = 20 },
        .mode_size = .{ .width = 1200, .height = 900 },
        .logical_size = .{ .width = 800, .height = 600 },
        .physical_size = .{ .width = 300, .height = 200 },
        .refresh_millihertz = 60_000,
        .scale = 2,
        .name = "DP-1",
        .description = "Keywork display",
        .model = "native",
    });
    defer output.deinit();
    var xdg_output: XdgOutputGlobal = undefined;
    try xdg_output.init(std.testing.allocator, &server, &output);
    defer xdg_output.deinit();
    const client = try server.createClient();
    defer server.destroyClient(client) catch unreachable;

    var peer = wayring.Connection.init(
        std.testing.allocator,
        .client,
        wayring.default_max_frame_size,
    );
    defer peer.deinit();
    _ = try core.bootstrapDisplay(&peer);
    const registry: wayring.ObjectHandle = .{
        .id = 2,
        .generation = try core.getRegistry(&peer, 2),
    };
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    var output_name: u32 = 0;
    var manager_name: u32 = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const event = try core.decodeRegistryEvent(&message, registry.id);
        if (event != .global) continue;
        if (std.mem.eql(u8, event.global.interface, generated.wl_output.name))
            output_name = event.global.name;
        if (std.mem.eql(u8, event.global.interface, generated.zxdg_output_manager_v1.name)) {
            manager_name = event.global.name;
            try std.testing.expectEqual(advertised_version, event.global.version);
        }
    }
    try std.testing.expect(output_name != 0);
    try std.testing.expect(manager_name != 0);

    const output_resource: wayring.ObjectHandle = .{
        .id = 3,
        .generation = try core.bind(
            &peer,
            registry.id,
            output_name,
            generated.wl_output.name,
            4,
            3,
            &generated.wl_output,
        ),
    };
    var managers: [3]wayring.ObjectHandle = undefined;
    for (&managers, 0..) |*manager, index| {
        const id: u32 = @intCast(4 + index);
        manager.* = .{
            .id = id,
            .generation = try core.bind(
                &peer,
                registry.id,
                manager_name,
                generated.zxdg_output_manager_v1.name,
                @intCast(index + 1),
                id,
                &generated.zxdg_output_manager_v1,
            ),
        };
    }
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    while (peer.popMessage()) |popped| {
        var message = popped;
        message.deinit();
    }

    var children: [3]wayring.ObjectHandle = undefined;
    for (managers, 0..) |manager, index| {
        children[index] = try generated.zxdg_output_manager_v1_types.requests.get_xdg_output(
            &peer,
            manager,
            output_resource,
        );
        try generated.zxdg_output_manager_v1_types.requests.destroy(&peer, manager);
    }
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);

    var stages: [3]usize = .{ 0, 0, 0 };
    var output_done_count: usize = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == 1) {
            _ = try core.decodeDisplayEvent(&message);
            continue;
        }
        if (message.object_id == output_resource.id) {
            const event = try generated.wl_output_types.decodeEvent(
                &peer,
                output_resource,
                &message,
            );
            if (event != .done) return error.UnexpectedOutputEvent;
            output_done_count += 1;
            continue;
        }
        const child_index = for (children, 0..) |child, index| {
            if (message.object_id == child.id) break index;
        } else return error.UnexpectedXdgOutputEvent;
        const version = child_index + 1;
        switch (try generated.zxdg_output_v1_types.decodeEvent(
            &peer,
            children[child_index],
            &message,
        )) {
            .logical_position => |event| {
                try std.testing.expectEqual(@as(usize, 0), stages[child_index]);
                try std.testing.expectEqual(@as(i32, -10), event.x);
                try std.testing.expectEqual(@as(i32, 20), event.y);
            },
            .logical_size => |event| {
                try std.testing.expectEqual(@as(usize, 1), stages[child_index]);
                try std.testing.expectEqual(@as(i32, 800), event.width);
                try std.testing.expectEqual(@as(i32, 600), event.height);
            },
            .name => |event| {
                try std.testing.expect(version >= 2);
                try std.testing.expectEqual(@as(usize, 2), stages[child_index]);
                try std.testing.expectEqualStrings("DP-1", event.name);
            },
            .description => |event| {
                try std.testing.expect(version >= 2);
                try std.testing.expectEqual(@as(usize, 3), stages[child_index]);
                try std.testing.expectEqualStrings("Keywork display", event.description);
            },
            .done => {
                try std.testing.expect(version < 3);
                try std.testing.expectEqual(
                    if (version == 1) @as(usize, 2) else 4,
                    stages[child_index],
                );
            },
        }
        stages[child_index] += 1;
    }
    try std.testing.expectEqualSlices(usize, &.{ 3, 5, 4 }, &stages);
    // Initial v3 state is committed by wl_output.done.
    try std.testing.expectEqual(@as(usize, 1), output_done_count);

    for (children) |child| try generated.zxdg_output_v1_types.requests.destroy(
        &peer,
        child,
    );
    try transferToServer(&peer, client);
    try std.testing.expectEqual(@as(usize, 0), xdg_output.resources.items.len);
}

fn transferToServer(connection: *wayring.Connection, client: *Server.Client) !void {
    while (connection.nextBatch()) |batch| {
        try client.receive(batch.bytes, batch.fds);
        try connection.acknowledge(batch.token, batch.bytes.len);
    }
}

fn transferFromServer(connection: *wayring.Connection, client: *Server.Client) !void {
    while (client.connection.nextBatch()) |batch| {
        try connection.feed(batch.bytes, batch.fds);
        try client.connection.acknowledge(batch.token, batch.bytes.len);
    }
    try client.outputDrained();
}
