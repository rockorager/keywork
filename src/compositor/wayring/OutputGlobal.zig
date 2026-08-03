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
bind_observer: ?BindObserver = null,

pub const BindObserver = struct {
    context: *anyopaque,
    bound: *const fn (*anyopaque, *Server.Client, wayring.ObjectHandle) anyerror!void,
};

pub const Config = struct {
    position: render.Position = .{},
    mode_size: render.Size,
    logical_size: render.Size,
    physical_size: render.Size,
    refresh_millihertz: i32,
    scale: u32,
    name: []const u8,
    description: []const u8,
    make: []const u8 = "keywork",
    model: []const u8,
};

pub const Geometry = struct {
    position: render.Position,
    mode_size: render.Size,
    logical_size: render.Size,
    physical_size: render.Size,
    refresh_millihertz: i32,
    scale: u32,
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
    if (!validSize(config.mode_size) or !validSize(config.logical_size) or
        !validSize(config.physical_size) or
        config.refresh_millihertz <= 0 or config.scale == 0 or
        config.scale > std.math.maxInt(i32))
    {
        return error.InvalidOutput;
    }
    const name = try allocator.dupe(u8, config.name);
    errdefer allocator.free(name);
    const description = try allocator.dupe(u8, config.description);
    errdefer allocator.free(description);
    const make = try allocator.dupe(u8, config.make);
    errdefer allocator.free(make);
    const model = try allocator.dupe(u8, config.model);
    errdefer allocator.free(model);
    self.* = .{
        .allocator = allocator,
        .server = server,
        .global_name = undefined,
        .config = .{
            .position = config.position,
            .mode_size = config.mode_size,
            .logical_size = config.logical_size,
            .physical_size = config.physical_size,
            .refresh_millihertz = config.refresh_millihertz,
            .scale = config.scale,
            .name = name,
            .description = description,
            .make = make,
            .model = model,
        },
    };
    self.global_name = try server.createGlobal(
        &generated.wl_output,
        advertised_version,
        .{ .context = self, .bind = bind },
    );
}

pub fn deinit(self: *OutputGlobal) void {
    std.debug.assert(self.bind_observer == null);
    std.debug.assert(self.resources.items.len == 0);
    self.server.removeGlobal(self.global_name) catch unreachable;
    for (self.memberships.items) |surface| surface.unreference();
    self.memberships.deinit(self.allocator);
    self.resources.deinit(self.allocator);
    self.deinitConfig();
    self.* = undefined;
}

/// Retains the observer context until clearBindObserver or deinit.
pub fn setBindObserver(self: *OutputGlobal, observer: BindObserver) void {
    std.debug.assert(self.bind_observer == null);
    self.bind_observer = observer;
}

pub fn clearBindObserver(self: *OutputGlobal) void {
    std.debug.assert(self.bind_observer != null);
    self.bind_observer = null;
}

fn deinitConfig(self: *OutputGlobal) void {
    self.allocator.free(self.config.model);
    self.allocator.free(self.config.make);
    self.allocator.free(self.config.description);
    self.allocator.free(self.config.name);
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

pub fn sendPresentationSync(
    self: *const OutputGlobal,
    client: *Server.Client,
    feedback: wayring.ObjectHandle,
) !void {
    for (self.resources.items) |binding| {
        if (binding.client != client) continue;
        try generated.wp_presentation_feedback_types.events.sync_output(
            &client.connection,
            feedback,
            binding.resource,
        );
    }
}

/// Captures a live binding belonging to this output and client.
pub fn bindingHandle(
    self: *const OutputGlobal,
    client: *const Server.Client,
    resource_id: u32,
) ?wayring.ObjectHandle {
    for (self.resources.items) |binding| {
        if (binding.client == client and binding.resource.id == resource_id)
            return binding.resource;
    }
    return null;
}

pub fn bindingIsLive(
    self: *const OutputGlobal,
    client: *const Server.Client,
    resource: wayring.ObjectHandle,
) bool {
    for (self.resources.items) |binding| {
        if (binding.client == client and binding.resource.id == resource.id and
            binding.resource.generation == resource.generation) return true;
    }
    return false;
}

/// Visits each live wl_output resource for one client without exposing binding
/// ownership outside this global.
pub fn forEachBinding(
    self: *const OutputGlobal,
    client: *const Server.Client,
    context: *anyopaque,
    visitor: *const fn (*anyopaque, wayring.ObjectHandle) anyerror!void,
) !void {
    for (self.resources.items) |binding| {
        if (binding.client == client) try visitor(context, binding.resource);
    }
}

pub fn logicalPosition(self: *const OutputGlobal) render.Position {
    return self.config.position;
}

pub fn logicalSize(self: *const OutputGlobal) render.Size {
    return self.config.logical_size;
}

pub fn currentMode(self: *const OutputGlobal) render.Size {
    return self.config.mode_size;
}

pub fn currentRefreshMillihertz(self: *const OutputGlobal) i32 {
    return self.config.refresh_millihertz;
}

pub fn currentScale(self: *const OutputGlobal) u32 {
    return self.config.scale;
}

pub fn outputName(self: *const OutputGlobal) []const u8 {
    return self.config.name;
}
pub fn outputDescription(self: *const OutputGlobal) []const u8 {
    return self.config.description;
}
pub fn outputMake(self: *const OutputGlobal) []const u8 {
    return self.config.make;
}
pub fn outputModel(self: *const OutputGlobal) []const u8 {
    return self.config.model;
}
pub fn physicalSize(self: *const OutputGlobal) render.Size {
    return self.config.physical_size;
}

pub fn validateGeometry(geometry: Geometry) !void {
    if (!validSize(geometry.mode_size) or !validSize(geometry.logical_size) or
        !validSize(geometry.physical_size) or geometry.refresh_millihertz <= 0 or
        geometry.scale == 0 or geometry.scale > std.math.maxInt(i32))
        return error.InvalidOutput;
}

/// Applies already validated scalar geometry without allocating or publishing.
pub fn applyGeometry(self: *OutputGlobal, geometry: Geometry) void {
    validateGeometry(geometry) catch unreachable;
    self.config.position = geometry.position;
    self.config.mode_size = geometry.mode_size;
    self.config.logical_size = geometry.logical_size;
    self.config.physical_size = geometry.physical_size;
    self.config.refresh_millihertz = geometry.refresh_millihertz;
    self.config.scale = geometry.scale;
}

/// Publishes changed wl_output properties, deliberately excluding done.
pub fn publishGeometry(self: *OutputGlobal, previous: Geometry) void {
    for (self.resources.items) |binding| self.publishGeometryTo(binding, previous) catch {
        binding.client.postNoMemory() catch {};
    };
}

pub fn publishDone(self: *OutputGlobal) void {
    for (self.resources.items) |binding| {
        const version = binding.client.resourceVersion(binding.resource, &generated.wl_output) catch continue;
        if (version >= 2) generated.wl_output_types.events.done(
            &binding.client.connection,
            binding.resource,
        ) catch binding.client.postNoMemory() catch {};
    }
}

pub fn publishPreferredBufferScale(self: *OutputGlobal) void {
    for (self.memberships.items) |surface| {
        if (!surface.resource_alive) continue;
        const version = surface.client.resourceVersion(surface.resource, &generated.wl_surface) catch continue;
        if (version >= 6) generated.wl_surface_types.events.preferred_buffer_scale(
            &surface.client.connection,
            surface.resource,
            @intCast(self.config.scale),
        ) catch surface.client.postNoMemory() catch {};
    }
}

fn publishGeometryTo(self: *const OutputGlobal, binding: *const Binding, previous: Geometry) !void {
    const connection = &binding.client.connection;
    const resource = binding.resource;
    if (!std.meta.eql(previous.position, self.config.position) or
        !std.meta.eql(previous.physical_size, self.config.physical_size))
        try generated.wl_output_types.events.geometry(connection, resource, self.config.position.x, self.config.position.y, @intCast(self.config.physical_size.width), @intCast(self.config.physical_size.height), @intFromEnum(generated.wl_output_types.subpixel.unknown), self.config.make, self.config.model, @intFromEnum(generated.wl_output_types.transform.normal));
    if (!std.meta.eql(previous.mode_size, self.config.mode_size) or
        previous.refresh_millihertz != self.config.refresh_millihertz)
        try generated.wl_output_types.events.mode(connection, resource, generated.wl_output_types.mode.current | generated.wl_output_types.mode.preferred, @intCast(self.config.mode_size.width), @intCast(self.config.mode_size.height), self.config.refresh_millihertz);
    const version = try binding.client.resourceVersion(resource, &generated.wl_output);
    if (version >= 2 and previous.scale != self.config.scale)
        try generated.wl_output_types.events.scale(connection, resource, @intCast(self.config.scale));
}

fn validSize(size: render.Size) bool {
    return size.width > 0 and size.height > 0 and
        size.width <= std.math.maxInt(i32) and size.height <= std.math.maxInt(i32);
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *OutputGlobal = @ptrCast(@alignCast(context));
    const binding = self.allocator.create(Binding) catch return client.postNoMemory();
    var binding_owned = true;
    errdefer if (binding_owned) self.allocator.destroy(binding);
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
    binding_owned = false;
    errdefer client.destroyResource(binding.resource) catch {};
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
    if (self.bind_observer) |observer| {
        observer.bound(observer.context, client, binding.resource) catch
            return client.postNoMemory();
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

test "native output owns advertised identity" {
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var name = [_]u8{ 'D', 'P', '-', '1' };
    var output: OutputGlobal = undefined;
    try output.init(std.testing.allocator, &server, .{
        .mode_size = .{ .width = 1920, .height = 1080 },
        .logical_size = .{ .width = 1920, .height = 1080 },
        .physical_size = .{ .width = 300, .height = 170 },
        .refresh_millihertz = 60_000,
        .scale = 1,
        .name = &name,
        .description = "Display",
        .make = "Keywork",
        .model = "native",
    });
    defer output.deinit();
    name[0] = 'X';
    try std.testing.expectEqualStrings("DP-1", output.config.name);
}

test "native output advertises complete version four state" {
    const core = @import("wayring-core");
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var output: OutputGlobal = undefined;
    try output.init(std.testing.allocator, &server, .{
        .mode_size = .{ .width = 1280, .height = 720 },
        .logical_size = .{ .width = 640, .height = 360 },
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
