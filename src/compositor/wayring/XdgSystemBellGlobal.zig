//! Native `xdg_system_bell_v1` requests.

const XdgSystemBellGlobal = @This();

const std = @import("std");
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");

const advertised_version: u32 = 1;

server: *Server,
global_name: u32,

pub fn init(self: *XdgSystemBellGlobal, server: *Server) !void {
    self.* = .{ .server = server, .global_name = undefined };
    self.global_name = try server.createGlobal(
        &generated.xdg_system_bell_v1,
        advertised_version,
        .{ .context = self, .bind = bind },
    );
}

pub fn deinit(self: *XdgSystemBellGlobal) void {
    self.server.removeGlobal(self.global_name) catch unreachable;
    self.* = undefined;
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *XdgSystemBellGlobal = @ptrCast(@alignCast(context));
    _ = client.createResource(id, &generated.xdg_system_bell_v1, version, .{
        .context = self,
        .dispatch = dispatchBell,
    }) catch return client.postNoMemory();
}

fn dispatchBell(
    _: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    switch (try generated.xdg_system_bell_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .ring => |request| if (request.surface) |surface_id| {
            const object = client.connection.object(surface_id) orelse
                return error.UnknownSurface;
            if (object.interface != &generated.wl_surface) return error.WrongSurface;
        },
    }
}

test "native XDG system bell binds and accepts ring requests" {
    const core = @import("wayring-core");
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var bell: XdgSystemBellGlobal = undefined;
    try bell.init(&server);
    defer bell.deinit();
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
    var global_name: u32 = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const global = (try core.decodeRegistryEvent(&message, registry.id)).global;
        if (std.mem.eql(u8, global.interface, generated.xdg_system_bell_v1.name)) {
            global_name = global.name;
            try std.testing.expectEqual(advertised_version, global.version);
        }
    }
    try std.testing.expect(global_name != 0);

    const resource: wayring.ObjectHandle = .{
        .id = 3,
        .generation = try core.bind(
            &peer,
            registry.id,
            global_name,
            generated.xdg_system_bell_v1.name,
            advertised_version,
            3,
            &generated.xdg_system_bell_v1,
        ),
    };
    try transferToServer(&peer, client);
    try generated.xdg_system_bell_v1_types.requests.ring(&peer, resource, null);
    try generated.xdg_system_bell_v1_types.requests.destroy(&peer, resource);
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
