//! Native `wp_commit_timing_manager_v1` surface deadlines.

const CommitTimingGlobal = @This();

const std = @import("std");
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const CompositorGlobal = @import("CompositorGlobal.zig");

const advertised_version: u32 = 1;

allocator: std.mem.Allocator,
server: *Server,
compositor: *CompositorGlobal,
global_name: u32,
timer_count: usize = 0,

const Timer = struct {
    owner: *CommitTimingGlobal,
    surface: ?*CompositorGlobal.Surface,

    fn surfaceDestroyed(context: *anyopaque) void {
        const self: *Timer = @ptrCast(@alignCast(context));
        self.surface = null;
    }
};

pub fn init(
    self: *CommitTimingGlobal,
    allocator: std.mem.Allocator,
    server: *Server,
    compositor: *CompositorGlobal,
) !void {
    self.* = .{
        .allocator = allocator,
        .server = server,
        .compositor = compositor,
        .global_name = undefined,
    };
    self.global_name = try server.createGlobal(
        &generated.wp_commit_timing_manager_v1,
        advertised_version,
        .{ .context = self, .bind = bind },
    );
}

pub fn deinit(self: *CommitTimingGlobal) void {
    std.debug.assert(self.timer_count == 0);
    self.server.removeGlobal(self.global_name) catch unreachable;
    self.* = undefined;
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *CommitTimingGlobal = @ptrCast(@alignCast(context));
    _ = client.createResource(id, &generated.wp_commit_timing_manager_v1, version, .{
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
    const self: *CommitTimingGlobal = @ptrCast(@alignCast(context));
    switch (try generated.wp_commit_timing_manager_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .get_timer => |request| {
            const object = client.connection.object(request.surface) orelse
                return error.UnknownSurface;
            const surface = try CompositorGlobal.surfaceFor(client, .{
                .id = request.surface,
                .generation = object.generation,
            });
            if (surface.owner != self.compositor) return error.WrongSurface;
            if (surface.commit_timer_handler != null) return client.postError(
                resource,
                @intFromEnum(
                    generated.wp_commit_timing_manager_v1_types.@"error".commit_timer_exists,
                ),
                "wl_surface already has a commit timer object",
            );
            const timer = self.allocator.create(Timer) catch
                return client.postNoMemory();
            errdefer self.allocator.destroy(timer);
            const version = try client.resourceVersion(
                resource,
                &generated.wp_commit_timing_manager_v1,
            );
            _ = client.createResource(
                request.id,
                &generated.wp_commit_timer_v1,
                version,
                .{
                    .context = timer,
                    .dispatch = dispatchTimer,
                    .destroy = destroyTimer,
                },
            ) catch return client.postNoMemory();
            timer.* = .{ .owner = self, .surface = surface };
            surface.setCommitTimerHandler(.{
                .context = timer,
                .surface_destroyed = Timer.surfaceDestroyed,
            }) catch unreachable;
            self.timer_count += 1;
        },
    }
}

fn dispatchTimer(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const self: *Timer = @ptrCast(@alignCast(context));
    switch (try generated.wp_commit_timer_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .set_timestamp => |request| {
            const surface = self.surface orelse
                return postSurfaceDestroyed(client, resource);
            const target = timestampNanoseconds(
                request.tv_sec_hi,
                request.tv_sec_lo,
                request.tv_nsec,
            ) catch return client.postError(
                resource,
                @intFromEnum(generated.wp_commit_timer_v1_types.@"error".invalid_timestamp),
                "tv_nsec must be less than one second",
            );
            surface.setPendingCommitTimestamp(target) catch return client.postError(
                resource,
                @intFromEnum(generated.wp_commit_timer_v1_types.@"error".timestamp_exists),
                "wl_surface already has a commit timestamp",
            );
        },
    }
}

fn destroyTimer(
    context: *anyopaque,
    _: *Server.Client,
    _: wayring.ObjectHandle,
) void {
    const self: *Timer = @ptrCast(@alignCast(context));
    if (self.surface) |surface| surface.clearCommitTimerHandler(self);
    const owner = self.owner;
    owner.timer_count -= 1;
    owner.allocator.destroy(self);
}

fn postSurfaceDestroyed(
    client: *Server.Client,
    resource: wayring.ObjectHandle,
) !void {
    return client.postError(
        resource,
        @intFromEnum(generated.wp_commit_timer_v1_types.@"error".surface_destroyed),
        "wl_surface has been destroyed",
    );
}

fn timestampNanoseconds(
    high: u32,
    low: u32,
    nanoseconds: u32,
) error{InvalidTimestamp}!i96 {
    if (nanoseconds >= std.time.ns_per_s) return error.InvalidTimestamp;
    const seconds = @as(u64, high) << 32 | low;
    return @as(i96, seconds) * std.time.ns_per_s + nanoseconds;
}

test "native commit timestamps are one-shot and object scoped" {
    try std.testing.expectEqual(
        @as(i96, 0x1234_5678_9abc_def0) * std.time.ns_per_s + 999_999_999,
        try timestampNanoseconds(0x1234_5678, 0x9abc_def0, 999_999_999),
    );
    try std.testing.expectError(
        error.InvalidTimestamp,
        timestampNanoseconds(0, 0, std.time.ns_per_s),
    );

    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var compositor: CompositorGlobal = undefined;
    try compositor.init(std.testing.allocator, &server);
    defer compositor.deinit();
    var timing: CommitTimingGlobal = undefined;
    try timing.init(std.testing.allocator, &server, &compositor);
    defer timing.deinit();

    {
        const client = try server.createClient();
        defer server.destroyClient(client) catch unreachable;
        var peer = wayring.Connection.init(
            std.testing.allocator,
            .client,
            wayring.default_max_frame_size,
        );
        defer peer.deinit();
        const globals = try bindGlobals(&peer, client);
        const surface = try generated.wl_compositor_types.requests.create_surface(
            &peer,
            globals.compositor,
        );
        const timer = try generated.wp_commit_timing_manager_v1_types.requests.get_timer(
            &peer,
            globals.manager,
            surface,
        );
        try generated.wp_commit_timer_v1_types.requests.set_timestamp(
            &peer,
            timer,
            0x1234_5678,
            0x9abc_def0,
            999_999_999,
        );
        try generated.wp_commit_timer_v1_types.requests.destroy(&peer, timer);
        try generated.wl_surface_types.requests.commit(&peer, surface);
        try generated.wl_surface_types.requests.commit(&peer, surface);
        try transferToServer(&peer, client);

        var first = compositor.popTransaction() orelse return error.MissingCommit;
        defer first.deinit();
        var second = compositor.popTransaction() orelse return error.MissingCommit;
        defer second.deinit();
        try std.testing.expectEqual(
            @as(?i96, @as(i96, 0x1234_5678_9abc_def0) * std.time.ns_per_s + 999_999_999),
            first.entries[0].target_timestamp,
        );
        try std.testing.expectEqual(@as(?i96, null), second.entries[0].target_timestamp);

        const surviving = try generated.wp_commit_timing_manager_v1_types.requests.get_timer(
            &peer,
            globals.manager,
            surface,
        );
        try generated.wp_commit_timing_manager_v1_types.requests.destroy(&peer, globals.manager);
        try generated.wp_commit_timer_v1_types.requests.set_timestamp(
            &peer,
            surviving,
            0,
            1,
            0,
        );
        try generated.wl_surface_types.requests.destroy(&peer, surface);
        try generated.wp_commit_timer_v1_types.requests.set_timestamp(
            &peer,
            surviving,
            0,
            2,
            0,
        );
        try std.testing.expectError(error.ProtocolError, transferToServer(&peer, client));
    }

    {
        const client = try server.createClient();
        defer server.destroyClient(client) catch unreachable;
        var peer = wayring.Connection.init(
            std.testing.allocator,
            .client,
            wayring.default_max_frame_size,
        );
        defer peer.deinit();
        const globals = try bindGlobals(&peer, client);
        const surface = try generated.wl_compositor_types.requests.create_surface(
            &peer,
            globals.compositor,
        );
        const timer = try generated.wp_commit_timing_manager_v1_types.requests.get_timer(
            &peer,
            globals.manager,
            surface,
        );
        try generated.wp_commit_timer_v1_types.requests.set_timestamp(&peer, timer, 0, 1, 0);
        try generated.wp_commit_timer_v1_types.requests.set_timestamp(&peer, timer, 0, 2, 0);
        try std.testing.expectError(error.ProtocolError, transferToServer(&peer, client));
    }

    {
        const client = try server.createClient();
        defer server.destroyClient(client) catch unreachable;
        var peer = wayring.Connection.init(
            std.testing.allocator,
            .client,
            wayring.default_max_frame_size,
        );
        defer peer.deinit();
        const globals = try bindGlobals(&peer, client);
        const surface = try generated.wl_compositor_types.requests.create_surface(
            &peer,
            globals.compositor,
        );
        _ = try generated.wp_commit_timing_manager_v1_types.requests.get_timer(
            &peer,
            globals.manager,
            surface,
        );
        _ = try generated.wp_commit_timing_manager_v1_types.requests.get_timer(
            &peer,
            globals.manager,
            surface,
        );
        try std.testing.expectError(error.ProtocolError, transferToServer(&peer, client));
    }

    {
        const client = try server.createClient();
        defer server.destroyClient(client) catch unreachable;
        var peer = wayring.Connection.init(
            std.testing.allocator,
            .client,
            wayring.default_max_frame_size,
        );
        defer peer.deinit();
        const globals = try bindGlobals(&peer, client);
        const surface = try generated.wl_compositor_types.requests.create_surface(
            &peer,
            globals.compositor,
        );
        const timer = try generated.wp_commit_timing_manager_v1_types.requests.get_timer(
            &peer,
            globals.manager,
            surface,
        );
        try generated.wp_commit_timer_v1_types.requests.set_timestamp(
            &peer,
            timer,
            0,
            0,
            std.time.ns_per_s,
        );
        try std.testing.expectError(error.ProtocolError, transferToServer(&peer, client));
    }
}

const BoundGlobals = struct {
    compositor: wayring.ObjectHandle,
    manager: wayring.ObjectHandle,
};

fn bindGlobals(connection: *wayring.Connection, client: *Server.Client) !BoundGlobals {
    const core = @import("wayring-core");
    _ = try core.bootstrapDisplay(connection);
    const registry: wayring.ObjectHandle = .{
        .id = 2,
        .generation = try core.getRegistry(connection, 2),
    };
    try transferToServer(connection, client);
    try transferFromServer(connection, client);
    var compositor_name: u32 = 0;
    var manager_name: u32 = 0;
    while (connection.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const global = (try core.decodeRegistryEvent(&message, registry.id)).global;
        if (std.mem.eql(u8, global.interface, generated.wl_compositor.name))
            compositor_name = global.name;
        if (std.mem.eql(u8, global.interface, generated.wp_commit_timing_manager_v1.name))
            manager_name = global.name;
    }
    const compositor: wayring.ObjectHandle = .{
        .id = 3,
        .generation = try core.bind(
            connection,
            registry.id,
            compositor_name,
            generated.wl_compositor.name,
            6,
            3,
            &generated.wl_compositor,
        ),
    };
    const manager: wayring.ObjectHandle = .{
        .id = 4,
        .generation = try core.bind(
            connection,
            registry.id,
            manager_name,
            generated.wp_commit_timing_manager_v1.name,
            advertised_version,
            4,
            &generated.wp_commit_timing_manager_v1,
        ),
    };
    try transferToServer(connection, client);
    return .{ .compositor = compositor, .manager = manager };
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
