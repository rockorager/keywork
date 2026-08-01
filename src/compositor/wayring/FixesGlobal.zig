//! Native `wl_fixes` registry lifecycle requests.

const FixesGlobal = @This();

const std = @import("std");
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");

// Version 2 acknowledgement bookkeeping is not needed while globals remain
// process-lifetime objects, matching the legacy compositor advertisement.
const advertised_version: u32 = 1;

server: *Server,
global_name: u32,

pub fn init(self: *FixesGlobal, server: *Server) !void {
    self.* = .{ .server = server, .global_name = undefined };
    self.global_name = try server.createGlobal(
        &generated.wl_fixes,
        advertised_version,
        .{ .context = self, .bind = bind },
    );
}

pub fn deinit(self: *FixesGlobal) void {
    self.server.removeGlobal(self.global_name) catch unreachable;
    self.* = undefined;
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *FixesGlobal = @ptrCast(@alignCast(context));
    _ = client.createResource(id, &generated.wl_fixes, version, .{
        .context = self,
        .dispatch = dispatchFixes,
    }) catch return client.postNoMemory();
}

fn dispatchFixes(
    _: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    switch (try generated.wl_fixes_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .destroy_registry => |request| {
            const object = client.connection.object(request.registry) orelse
                return error.UnknownRegistry;
            try client.destroyResource(.{
                .id = request.registry,
                .generation = object.generation,
            });
        },
        .ack_global_remove => unreachable,
    }
}

test "native fixes destroys registries without disturbing other subscriptions" {
    const core = @import("wayring-core");
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var fixes: FixesGlobal = undefined;
    try fixes.init(&server);
    defer fixes.deinit();
    const client = try server.createClient();
    defer server.destroyClient(client) catch unreachable;

    var peer = wayring.Connection.init(
        std.testing.allocator,
        .client,
        wayring.default_max_frame_size,
    );
    defer peer.deinit();
    _ = try core.bootstrapDisplay(&peer);
    const first_registry: wayring.ObjectHandle = .{
        .id = 2,
        .generation = try core.getRegistry(&peer, 2),
    };
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    var fixes_name: u32 = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const event = try core.decodeRegistryEvent(&message, first_registry.id);
        if (event == .global and
            std.mem.eql(u8, event.global.interface, generated.wl_fixes.name))
        {
            fixes_name = event.global.name;
            try std.testing.expectEqual(advertised_version, event.global.version);
        }
    }
    try std.testing.expect(fixes_name != 0);

    const fixes_resource: wayring.ObjectHandle = .{
        .id = 3,
        .generation = try core.bind(
            &peer,
            first_registry.id,
            fixes_name,
            generated.wl_fixes.name,
            advertised_version,
            3,
            &generated.wl_fixes,
        ),
    };
    const second_registry: wayring.ObjectHandle = .{
        .id = 4,
        .generation = try core.getRegistry(&peer, 4),
    };
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    while (peer.popMessage()) |popped| {
        var message = popped;
        message.deinit();
    }

    // wl_registry is bootstrapped by wayring-core rather than the generated
    // protocol module, so queue this cross-module object request by wire ID.
    try peer.queueObject(fixes_resource, &generated.wl_fixes, 1, &.{
        .{ .object = first_registry.id },
    });
    try transferToServer(&peer, client);
    const late_global = try server.createGlobal(
        &generated.wl_fixes,
        advertised_version,
        .{ .context = &fixes, .bind = bind },
    );
    defer server.removeGlobal(late_global) catch unreachable;
    try transferFromServer(&peer, client);

    var deleted_first = false;
    var late_on_second = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == 1) {
            switch (try core.decodeDisplayEvent(&message)) {
                .delete_id => |id| if (id == first_registry.id) {
                    deleted_first = true;
                    try peer.removeObject(first_registry.id, first_registry.generation);
                },
                else => return error.UnexpectedDisplayEvent,
            }
        } else if (message.object_id == second_registry.id) {
            const event = try core.decodeRegistryEvent(&message, second_registry.id);
            if (event == .global and event.global.name == late_global)
                late_on_second = true;
        } else if (message.object_id == first_registry.id) {
            return error.DestroyedRegistryReceivedGlobal;
        } else return error.UnexpectedFixesEvent;
    }
    try std.testing.expect(deleted_first);
    try std.testing.expect(late_on_second);

    try generated.wl_fixes_types.requests.destroy(&peer, fixes_resource);
    try transferToServer(&peer, client);
    try std.testing.expectEqual(Server.ClientState.active, client.state);
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
