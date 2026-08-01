//! Native `wl_output` advertisement and surface membership for one output.

const OutputGlobal = @This();

const std = @import("std");
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const CompositorGlobal = @import("CompositorGlobal.zig");
const render = @import("../render/types.zig");

const advertised_version: u32 = 4;

allocator: std.mem.Allocator,
server: *Server,
global_name: u32,
config: Config,
resources: std.ArrayList(*Binding) = .empty,
memberships: std.ArrayList(*CompositorGlobal.Surface) = .empty,

pub const Config = struct {
    position: render.Position = .{},
    mode_size: render.Size,
    physical_size: render.Size,
    refresh_millihertz: i32,
    scale: u32,
    name: []const u8,
    description: []const u8,
    make: []const u8 = "keywork",
    model: []const u8,
};

const Binding = struct {
    owner: *OutputGlobal,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
};

pub fn init(
    self: *OutputGlobal,
    allocator: std.mem.Allocator,
    server: *Server,
    config: Config,
) !void {
    if (!validSize(config.mode_size) or !validSize(config.physical_size) or
        config.refresh_millihertz <= 0 or config.scale == 0 or
        config.scale > std.math.maxInt(i32))
    {
        return error.InvalidOutput;
    }
    self.* = .{
        .allocator = allocator,
        .server = server,
        .global_name = undefined,
        .config = config,
    };
    self.global_name = try server.createGlobal(
        &generated.wl_output,
        advertised_version,
        .{ .context = self, .bind = bind },
    );
}

pub fn deinit(self: *OutputGlobal) void {
    std.debug.assert(self.resources.items.len == 0);
    self.server.removeGlobal(self.global_name) catch unreachable;
    for (self.memberships.items) |surface| surface.unreference();
    self.memberships.deinit(self.allocator);
    self.resources.deinit(self.allocator);
    self.* = undefined;
}

/// Updates membership in this output. A membership owns one surface reference
/// and is retained so clients which bind `wl_output` later still receive enter.
pub fn setSurfaceVisible(
    self: *OutputGlobal,
    surface: *CompositorGlobal.Surface,
    visible: bool,
) !void {
    const index = for (self.memberships.items, 0..) |candidate, candidate_index| {
        if (candidate == surface) break candidate_index;
    } else null;
    if (visible) {
        if (index != null) return;
        try surface.reference();
        errdefer surface.unreference();
        try self.memberships.append(self.allocator, surface);
        if (surface.resource_alive) {
            try self.sendMembership(surface, true);
            const version = try surface.client.resourceVersion(
                surface.resource,
                &generated.wl_surface,
            );
            if (version >= 6) {
                try generated.wl_surface_types.events.preferred_buffer_scale(
                    &surface.client.connection,
                    surface.resource,
                    @intCast(self.config.scale),
                );
                try generated.wl_surface_types.events.preferred_buffer_transform(
                    &surface.client.connection,
                    surface.resource,
                    @intFromEnum(generated.wl_output_types.transform.normal),
                );
            }
        }
        return;
    }
    const membership_index = index orelse return;
    if (surface.resource_alive) try self.sendMembership(surface, false);
    _ = self.memberships.orderedRemove(membership_index);
    surface.unreference();
}

fn validSize(size: render.Size) bool {
    return size.width > 0 and size.height > 0 and
        size.width <= std.math.maxInt(i32) and size.height <= std.math.maxInt(i32);
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *OutputGlobal = @ptrCast(@alignCast(context));
    const binding = self.allocator.create(Binding) catch return client.postNoMemory();
    errdefer self.allocator.destroy(binding);
    self.resources.ensureUnusedCapacity(self.allocator, 1) catch
        return client.postNoMemory();
    binding.* = .{
        .owner = self,
        .client = client,
        .resource = undefined,
    };
    binding.resource = client.createResource(id, &generated.wl_output, version, .{
        .context = binding,
        .dispatch = dispatchOutput,
        .destroy = destroyBinding,
    }) catch return client.postNoMemory();
    self.resources.appendAssumeCapacity(binding);
    try self.sendState(binding);
    for (self.memberships.items) |surface| {
        if (surface.resource_alive and surface.client == client) {
            try generated.wl_surface_types.events.enter(
                &client.connection,
                surface.resource,
                binding.resource,
            );
        }
    }
}

fn sendState(self: *const OutputGlobal, binding: *const Binding) !void {
    const connection = &binding.client.connection;
    const resource = binding.resource;
    try generated.wl_output_types.events.geometry(
        connection,
        resource,
        self.config.position.x,
        self.config.position.y,
        @intCast(self.config.physical_size.width),
        @intCast(self.config.physical_size.height),
        @intFromEnum(generated.wl_output_types.subpixel.unknown),
        self.config.make,
        self.config.model,
        @intFromEnum(generated.wl_output_types.transform.normal),
    );
    try generated.wl_output_types.events.mode(
        connection,
        resource,
        generated.wl_output_types.mode.current | generated.wl_output_types.mode.preferred,
        @intCast(self.config.mode_size.width),
        @intCast(self.config.mode_size.height),
        self.config.refresh_millihertz,
    );
    const version = try binding.client.resourceVersion(resource, &generated.wl_output);
    if (version >= 2) {
        try generated.wl_output_types.events.scale(connection, resource, @intCast(self.config.scale));
    }
    if (version >= 4) {
        try generated.wl_output_types.events.name(connection, resource, self.config.name);
        try generated.wl_output_types.events.description(
            connection,
            resource,
            self.config.description,
        );
    }
    if (version >= 2) try generated.wl_output_types.events.done(connection, resource);
}

fn sendMembership(
    self: *OutputGlobal,
    surface: *CompositorGlobal.Surface,
    entered: bool,
) !void {
    for (self.resources.items) |binding| {
        if (binding.client != surface.client) continue;
        if (entered) {
            try generated.wl_surface_types.events.enter(
                &surface.client.connection,
                surface.resource,
                binding.resource,
            );
        } else {
            try generated.wl_surface_types.events.leave(
                &surface.client.connection,
                surface.resource,
                binding.resource,
            );
        }
    }
}

fn dispatchOutput(
    _: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    _ = try generated.wl_output_types.decodeRequest(&client.connection, resource, message);
}

fn destroyBinding(
    context: *anyopaque,
    _: *Server.Client,
    _: wayring.ObjectHandle,
) void {
    const binding: *Binding = @ptrCast(@alignCast(context));
    const owner = binding.owner;
    for (owner.resources.items, 0..) |candidate, index| {
        if (candidate != binding) continue;
        _ = owner.resources.orderedRemove(index);
        owner.allocator.destroy(binding);
        return;
    }
    unreachable;
}

test "native output advertises complete version four state" {
    const core = @import("wayring-core");
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var output: OutputGlobal = undefined;
    try output.init(std.testing.allocator, &server, .{
        .mode_size = .{ .width = 1280, .height = 720 },
        .physical_size = .{ .width = 1280, .height = 720 },
        .refresh_millihertz = 60_000,
        .scale = 2,
        .name = "HEADLESS-1",
        .description = "Keywork headless output",
        .model = "headless",
    });
    defer output.deinit();
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
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const event = try core.decodeRegistryEvent(&message, registry.id);
        if (event == .global and
            std.mem.eql(u8, event.global.interface, generated.wl_output.name))
        {
            output_name = event.global.name;
        }
    }
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
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);

    var event_count: usize = 0;
    var got_scale = false;
    var got_name = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const event = try generated.wl_output_types.decodeEvent(
            &peer,
            output_resource,
            &message,
        );
        event_count += 1;
        switch (event) {
            .scale => |scale| got_scale = scale.factor == 2,
            .name => |name| got_name = std.mem.eql(u8, name.name, "HEADLESS-1"),
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 6), event_count);
    try std.testing.expect(got_scale);
    try std.testing.expect(got_name);
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
