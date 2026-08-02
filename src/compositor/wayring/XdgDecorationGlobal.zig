//! Native xdg-decoration negotiation for client-decorated toplevels.

const XdgDecorationGlobal = @This();

const std = @import("std");
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const XdgShell = @import("XdgShell.zig");

const advertised_version: u32 = 2;

allocator: std.mem.Allocator,
server: *Server,
shell: *XdgShell,
global_name: u32,
decorations: std.ArrayList(*Decoration) = .empty,

const Decoration = struct {
    owner: *XdgDecorationGlobal,
    resource: wayring.ObjectHandle,
    toplevel: ?wayring.ObjectHandle = null,

    fn orphaned(self: *Decoration, client: *Server.Client) !void {
        return client.postError(
            self.resource,
            @intFromEnum(generated.zxdg_toplevel_decoration_v1_types.@"error".orphaned),
            "xdg_toplevel was destroyed before its decoration object",
        );
    }

    fn setPreference(
        self: *Decoration,
        client: *Server.Client,
        preference: XdgShell.DecorationPreference,
    ) !void {
        const toplevel = self.toplevel orelse return self.orphaned(client);
        self.owner.shell.setToplevelDecorationPreference(
            client,
            toplevel,
            self,
            preference,
        ) catch |err| switch (err) {
            error.UnknownResource, error.StaleObject => {
                self.toplevel = null;
                return self.orphaned(client);
            },
            else => return err,
        };
    }

    fn toplevelDestroyed(context: *anyopaque) void {
        const self: *Decoration = @ptrCast(@alignCast(context));
        self.toplevel = null;
    }

    fn deinit(self: *Decoration, client: *Server.Client) void {
        if (self.toplevel) |toplevel| {
            self.owner.shell.detachToplevelDecoration(
                client,
                toplevel,
                self,
            ) catch |err| switch (err) {
                error.UnknownResource, error.StaleObject => {},
                else => unreachable,
            };
        }
        const owner = self.owner;
        for (owner.decorations.items, 0..) |decoration, index| {
            if (decoration != self) continue;
            _ = owner.decorations.orderedRemove(index);
            owner.allocator.destroy(self);
            return;
        }
        unreachable;
    }
};

pub fn init(
    self: *XdgDecorationGlobal,
    allocator: std.mem.Allocator,
    server: *Server,
    shell: *XdgShell,
) !void {
    self.* = .{
        .allocator = allocator,
        .server = server,
        .shell = shell,
        .global_name = undefined,
    };
    self.global_name = try server.createGlobal(
        &generated.zxdg_decoration_manager_v1,
        advertised_version,
        .{ .context = self, .bind = bind },
    );
}

pub fn deinit(self: *XdgDecorationGlobal) void {
    std.debug.assert(self.decorations.items.len == 0);
    self.server.removeGlobal(self.global_name) catch unreachable;
    self.decorations.deinit(self.allocator);
    self.* = undefined;
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *XdgDecorationGlobal = @ptrCast(@alignCast(context));
    _ = client.createResource(
        id,
        &generated.zxdg_decoration_manager_v1,
        version,
        .{ .context = self, .dispatch = dispatchManager },
    ) catch return client.postNoMemory();
}

fn dispatchManager(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const self: *XdgDecorationGlobal = @ptrCast(@alignCast(context));
    switch (try generated.zxdg_decoration_manager_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .get_toplevel_decoration => |request| try self.createDecoration(
            client,
            resource,
            request.toplevel,
            request.id,
        ),
    }
}

fn createDecoration(
    self: *XdgDecorationGlobal,
    client: *Server.Client,
    manager_resource: wayring.ObjectHandle,
    toplevel_id: u32,
    id: u32,
) !void {
    const object = client.connection.object(toplevel_id) orelse
        return error.UnknownToplevel;
    const toplevel: wayring.ObjectHandle = .{
        .id = toplevel_id,
        .generation = object.generation,
    };
    const decoration = self.allocator.create(Decoration) catch
        return client.postNoMemory();
    var decoration_owned = true;
    errdefer if (decoration_owned) self.allocator.destroy(decoration);
    self.decorations.ensureUnusedCapacity(self.allocator, 1) catch
        return client.postNoMemory();
    decoration.* = .{ .owner = self, .resource = undefined };
    const version = try client.resourceVersion(
        manager_resource,
        &generated.zxdg_decoration_manager_v1,
    );
    decoration.resource = client.createResource(
        id,
        &generated.zxdg_toplevel_decoration_v1,
        version,
        .{
            .context = decoration,
            .dispatch = dispatchDecoration,
            .destroy = destroyDecoration,
        },
    ) catch return client.postNoMemory();
    self.decorations.appendAssumeCapacity(decoration);
    decoration_owned = false;
    self.shell.attachToplevelDecoration(client, toplevel, .{
        .context = decoration,
        .resource = decoration.resource,
        .version = version,
        .toplevel_destroyed = Decoration.toplevelDestroyed,
    }) catch |err| switch (err) {
        error.AlreadyExists => return client.postError(
            decoration.resource,
            @intFromEnum(
                generated.zxdg_toplevel_decoration_v1_types.@"error".already_constructed,
            ),
            "xdg_toplevel already has a decoration object",
        ),
        error.BufferAttached => return client.postError(
            decoration.resource,
            @intFromEnum(
                generated.zxdg_toplevel_decoration_v1_types.@"error".unconfigured_buffer,
            ),
            "version 1 decoration created after a buffer was attached",
        ),
        else => return err,
    };
    decoration.toplevel = toplevel;
    try self.shell.configureToplevelDecoration(client, toplevel, decoration);
}

fn dispatchDecoration(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const decoration: *Decoration = @ptrCast(@alignCast(context));
    switch (try generated.zxdg_toplevel_decoration_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .set_mode => |request| try decoration.setPreference(
            client,
            switch (request.mode) {
                @intFromEnum(
                    generated.zxdg_toplevel_decoration_v1_types.mode.client_side,
                ) => .prefers_csd,
                @intFromEnum(
                    generated.zxdg_toplevel_decoration_v1_types.mode.server_side,
                ) => .prefers_ssd,
                else => return client.postError(
                    resource,
                    @intFromEnum(
                        generated.zxdg_toplevel_decoration_v1_types.@"error".invalid_mode,
                    ),
                    "invalid decoration mode",
                ),
            },
        ),
        .unset_mode => try decoration.setPreference(client, .no_preference),
    }
}

fn destroyDecoration(
    context: *anyopaque,
    client: *Server.Client,
    _: wayring.ObjectHandle,
) void {
    const decoration: *Decoration = @ptrCast(@alignCast(context));
    decoration.deinit(client);
}

test "decorations configure client side and survive manager and toplevel lifetimes" {
    const core = @import("wayring-core");
    const CompositorGlobal = @import("CompositorGlobal.zig");
    const SurfaceTree = @import("SurfaceTree.zig");

    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var compositor: CompositorGlobal = undefined;
    try compositor.init(std.testing.allocator, &server);
    defer compositor.deinit();
    var tree = SurfaceTree.init(std.testing.allocator);
    defer tree.deinit();
    var shell: XdgShell = undefined;
    try shell.init(std.testing.allocator, &server, &tree, .{
        .context = &tree,
        .surface_size = testSurfaceSize,
        .output_bounds = testOutputBounds,
    });
    defer shell.deinit();
    var decorations: XdgDecorationGlobal = undefined;
    try decorations.init(std.testing.allocator, &server, &shell);
    defer decorations.deinit();
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
    var compositor_name: u32 = 0;
    var shell_name: u32 = 0;
    var decoration_name: u32 = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const global = (try core.decodeRegistryEvent(&message, registry.id)).global;
        if (std.mem.eql(u8, global.interface, generated.wl_compositor.name))
            compositor_name = global.name;
        if (std.mem.eql(u8, global.interface, generated.xdg_wm_base.name))
            shell_name = global.name;
        if (std.mem.eql(
            u8,
            global.interface,
            generated.zxdg_decoration_manager_v1.name,
        )) {
            try std.testing.expectEqual(advertised_version, global.version);
            decoration_name = global.name;
        }
    }
    try std.testing.expect(compositor_name != 0);
    try std.testing.expect(shell_name != 0);
    try std.testing.expect(decoration_name != 0);

    const compositor_resource: wayring.ObjectHandle = .{
        .id = 3,
        .generation = try core.bind(
            &peer,
            registry.id,
            compositor_name,
            generated.wl_compositor.name,
            6,
            3,
            &generated.wl_compositor,
        ),
    };
    const wm_base: wayring.ObjectHandle = .{
        .id = 4,
        .generation = try core.bind(
            &peer,
            registry.id,
            shell_name,
            generated.xdg_wm_base.name,
            6,
            4,
            &generated.xdg_wm_base,
        ),
    };
    const manager: wayring.ObjectHandle = .{
        .id = 5,
        .generation = try core.bind(
            &peer,
            registry.id,
            decoration_name,
            generated.zxdg_decoration_manager_v1.name,
            advertised_version,
            5,
            &generated.zxdg_decoration_manager_v1,
        ),
    };
    try transferToServer(&peer, client);
    const surface = try generated.wl_compositor_types.requests.create_surface(
        &peer,
        compositor_resource,
    );
    const xdg_surface = try generated.xdg_wm_base_types.requests.get_xdg_surface(
        &peer,
        wm_base,
        surface,
    );
    const toplevel = try generated.xdg_surface_types.requests.get_toplevel(
        &peer,
        xdg_surface,
    );
    const decoration = try generated.zxdg_decoration_manager_v1_types.requests
        .get_toplevel_decoration(&peer, manager, toplevel);
    try generated.zxdg_decoration_manager_v1_types.requests.destroy(&peer, manager);
    try generated.zxdg_toplevel_decoration_v1_types.requests.set_mode(
        &peer,
        decoration,
        @intFromEnum(generated.zxdg_toplevel_decoration_v1_types.mode.server_side),
    );
    try generated.wl_surface_types.requests.commit(&peer, surface);
    try transferToServer(&peer, client);

    var initial = compositor.popTransaction() orelse return error.MissingCommit;
    defer initial.deinit();
    try std.testing.expectEqual(
        .configure_only,
        (try shell.handleCommit(&initial.entries[0])).disposition,
    );
    const toplevel_handle: wayring.ObjectHandle = .{
        .id = toplevel.id,
        .generation = client.connection.object(toplevel.id).?.generation,
    };
    try std.testing.expectEqual(
        XdgShell.ToplevelDecorationState{
            .preference = .prefers_ssd,
            .configure_sent = true,
        },
        try shell.toplevelDecorationState(client, toplevel_handle),
    );
    try transferFromServer(&peer, client);
    const initial_serial = try expectConfigureSequence(
        &peer,
        decoration,
        toplevel,
        xdg_surface,
    );

    try generated.xdg_surface_types.requests.ack_configure(
        &peer,
        xdg_surface,
        initial_serial,
    );
    try generated.zxdg_toplevel_decoration_v1_types.requests.unset_mode(
        &peer,
        decoration,
    );
    try transferToServer(&peer, client);
    try std.testing.expectEqual(
        XdgShell.ToplevelDecorationState{
            .preference = .no_preference,
            .configure_sent = true,
        },
        try shell.toplevelDecorationState(client, toplevel_handle),
    );
    try transferFromServer(&peer, client);
    const updated_serial = try expectConfigureSequence(
        &peer,
        decoration,
        toplevel,
        xdg_surface,
    );
    try std.testing.expect(updated_serial != initial_serial);
    try generated.xdg_surface_types.requests.ack_configure(
        &peer,
        xdg_surface,
        updated_serial,
    );
    try generated.wl_surface_types.requests.attach(&peer, surface, null, 0, 0);
    try generated.wl_surface_types.requests.commit(&peer, surface);
    try transferToServer(&peer, client);
    var unmap = compositor.popTransaction() orelse return error.MissingCommit;
    defer unmap.deinit();
    _ = try shell.handleCommit(&unmap.entries[0]);
    try std.testing.expectEqual(
        XdgShell.ToplevelDecorationState{
            .preference = .no_preference,
            .configure_sent = false,
        },
        try shell.toplevelDecorationState(client, toplevel_handle),
    );

    try generated.wl_surface_types.requests.commit(&peer, surface);
    try transferToServer(&peer, client);
    var remap = compositor.popTransaction() orelse return error.MissingCommit;
    defer remap.deinit();
    try std.testing.expectEqual(
        .configure_only,
        (try shell.handleCommit(&remap.entries[0])).disposition,
    );
    try transferFromServer(&peer, client);
    const remap_serial = try expectConfigureSequence(
        &peer,
        decoration,
        toplevel,
        xdg_surface,
    );
    try generated.xdg_surface_types.requests.ack_configure(
        &peer,
        xdg_surface,
        remap_serial,
    );

    const replacement_manager: wayring.ObjectHandle = .{
        .id = 20,
        .generation = try core.bind(
            &peer,
            registry.id,
            decoration_name,
            generated.zxdg_decoration_manager_v1.name,
            advertised_version,
            20,
            &generated.zxdg_decoration_manager_v1,
        ),
    };
    try generated.zxdg_toplevel_decoration_v1_types.requests.destroy(
        &peer,
        decoration,
    );
    const replacement = try generated.zxdg_decoration_manager_v1_types.requests
        .get_toplevel_decoration(&peer, replacement_manager, toplevel);
    try transferToServer(&peer, client);
    try std.testing.expectEqual(
        XdgShell.ToplevelDecorationState{
            .preference = .no_preference,
            .configure_sent = true,
        },
        try shell.toplevelDecorationState(client, toplevel_handle),
    );
    try transferFromServer(&peer, client);
    const replacement_serial = try expectConfigureSequence(
        &peer,
        replacement,
        toplevel,
        xdg_surface,
    );
    try generated.xdg_surface_types.requests.ack_configure(
        &peer,
        xdg_surface,
        replacement_serial,
    );
    try generated.xdg_toplevel_types.requests.destroy(&peer, toplevel);
    try generated.zxdg_toplevel_decoration_v1_types.requests.destroy(
        &peer,
        replacement,
    );
    try transferToServer(&peer, client);
    try std.testing.expectEqual(Server.ClientState.active, client.state);
    try std.testing.expectEqual(@as(usize, 0), decorations.decorations.items.len);

    const orphaned_toplevel = try generated.xdg_surface_types.requests.get_toplevel(
        &peer,
        xdg_surface,
    );
    const orphaned_decoration = try generated.zxdg_decoration_manager_v1_types.requests
        .get_toplevel_decoration(&peer, replacement_manager, orphaned_toplevel);
    try generated.xdg_toplevel_types.requests.destroy(&peer, orphaned_toplevel);
    try generated.zxdg_toplevel_decoration_v1_types.requests.set_mode(
        &peer,
        orphaned_decoration,
        @intFromEnum(generated.zxdg_toplevel_decoration_v1_types.mode.client_side),
    );
    try std.testing.expectError(error.ProtocolError, transferToServer(&peer, client));
    try std.testing.expectEqual(Server.ClientState.protocol_error, client.state);
    try transferFromServer(&peer, client);
    try expectDisplayError(
        &peer,
        orphaned_decoration.id,
        @intFromEnum(generated.zxdg_toplevel_decoration_v1_types.@"error".orphaned),
    );
}

test "version 1 decoration rejects creation after a buffer attachment" {
    const core = @import("wayring-core");
    const CompositorGlobal = @import("CompositorGlobal.zig");
    const SinglePixelBufferGlobal = @import("SinglePixelBufferGlobal.zig");
    const SurfaceTree = @import("SurfaceTree.zig");

    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var compositor: CompositorGlobal = undefined;
    try compositor.init(std.testing.allocator, &server);
    defer compositor.deinit();
    var buffers: SinglePixelBufferGlobal = undefined;
    try buffers.init(std.testing.allocator, &server);
    defer buffers.deinit();
    var tree = SurfaceTree.init(std.testing.allocator);
    defer tree.deinit();
    var shell: XdgShell = undefined;
    try shell.init(std.testing.allocator, &server, &tree, .{
        .context = &tree,
        .surface_size = testSurfaceSize,
        .output_bounds = testOutputBounds,
    });
    defer shell.deinit();
    var decorations: XdgDecorationGlobal = undefined;
    try decorations.init(std.testing.allocator, &server, &shell);
    defer decorations.deinit();
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
    var compositor_name: u32 = 0;
    var shell_name: u32 = 0;
    var buffer_name: u32 = 0;
    var decoration_name: u32 = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const global = (try core.decodeRegistryEvent(&message, registry.id)).global;
        if (std.mem.eql(u8, global.interface, generated.wl_compositor.name))
            compositor_name = global.name;
        if (std.mem.eql(u8, global.interface, generated.xdg_wm_base.name))
            shell_name = global.name;
        if (std.mem.eql(
            u8,
            global.interface,
            generated.wp_single_pixel_buffer_manager_v1.name,
        )) buffer_name = global.name;
        if (std.mem.eql(
            u8,
            global.interface,
            generated.zxdg_decoration_manager_v1.name,
        )) decoration_name = global.name;
    }

    const compositor_resource: wayring.ObjectHandle = .{
        .id = 3,
        .generation = try core.bind(
            &peer,
            registry.id,
            compositor_name,
            generated.wl_compositor.name,
            6,
            3,
            &generated.wl_compositor,
        ),
    };
    const wm_base: wayring.ObjectHandle = .{
        .id = 4,
        .generation = try core.bind(
            &peer,
            registry.id,
            shell_name,
            generated.xdg_wm_base.name,
            6,
            4,
            &generated.xdg_wm_base,
        ),
    };
    const buffer_manager: wayring.ObjectHandle = .{
        .id = 5,
        .generation = try core.bind(
            &peer,
            registry.id,
            buffer_name,
            generated.wp_single_pixel_buffer_manager_v1.name,
            1,
            5,
            &generated.wp_single_pixel_buffer_manager_v1,
        ),
    };
    const manager: wayring.ObjectHandle = .{
        .id = 6,
        .generation = try core.bind(
            &peer,
            registry.id,
            decoration_name,
            generated.zxdg_decoration_manager_v1.name,
            1,
            6,
            &generated.zxdg_decoration_manager_v1,
        ),
    };
    try transferToServer(&peer, client);
    const surface = try generated.wl_compositor_types.requests.create_surface(
        &peer,
        compositor_resource,
    );
    const xdg_surface = try generated.xdg_wm_base_types.requests.get_xdg_surface(
        &peer,
        wm_base,
        surface,
    );
    const toplevel = try generated.xdg_surface_types.requests.get_toplevel(
        &peer,
        xdg_surface,
    );
    const buffer = try generated.wp_single_pixel_buffer_manager_v1_types.requests
        .create_u32_rgba_buffer(
        &peer,
        buffer_manager,
        std.math.maxInt(u32),
        std.math.maxInt(u32),
        std.math.maxInt(u32),
        std.math.maxInt(u32),
    );
    try generated.wl_surface_types.requests.attach(&peer, surface, buffer, 0, 0);
    const decoration = try generated.zxdg_decoration_manager_v1_types.requests
        .get_toplevel_decoration(&peer, manager, toplevel);
    try std.testing.expectError(error.ProtocolError, transferToServer(&peer, client));
    try std.testing.expectEqual(Server.ClientState.protocol_error, client.state);
    try transferFromServer(&peer, client);
    try expectDisplayError(
        &peer,
        decoration.id,
        @intFromEnum(
            generated.zxdg_toplevel_decoration_v1_types.@"error".unconfigured_buffer,
        ),
    );
}

fn expectConfigureSequence(
    peer: *wayring.Connection,
    decoration: wayring.ObjectHandle,
    toplevel: wayring.ObjectHandle,
    xdg_surface: wayring.ObjectHandle,
) !u32 {
    const core = @import("wayring-core");
    var stage: u8 = 0;
    var serial: ?u32 = null;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == decoration.id) {
            const event = try generated.zxdg_toplevel_decoration_v1_types.decodeEvent(
                peer,
                decoration,
                &message,
            );
            try std.testing.expectEqual(
                @intFromEnum(
                    generated.zxdg_toplevel_decoration_v1_types.mode.client_side,
                ),
                event.configure.mode,
            );
            try std.testing.expectEqual(@as(u8, 0), stage);
            stage = 1;
        } else if (message.object_id == toplevel.id) {
            switch (try generated.xdg_toplevel_types.decodeEvent(
                peer,
                toplevel,
                &message,
            )) {
                .configure => {
                    try std.testing.expectEqual(@as(u8, 1), stage);
                    stage = 2;
                },
                else => {},
            }
        } else if (message.object_id == xdg_surface.id) {
            const event = try generated.xdg_surface_types.decodeEvent(
                peer,
                xdg_surface,
                &message,
            );
            try std.testing.expectEqual(@as(u8, 2), stage);
            stage = 3;
            serial = event.configure.serial;
        } else if (message.object_id == 1) {
            _ = try core.decodeDisplayEvent(&message);
        }
    }
    try std.testing.expectEqual(@as(u8, 3), stage);
    return serial orelse error.MissingConfigure;
}

fn expectDisplayError(peer: *wayring.Connection, object_id: u32, code: u32) !void {
    const core = @import("wayring-core");
    var found = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id != 1) continue;
        switch (try core.decodeDisplayEvent(&message)) {
            .error_event => |event| if (event.object_id == object_id and event.code == code) {
                found = true;
            },
            .delete_id => {},
        }
    }
    try std.testing.expect(found);
}

fn testSurfaceSize(
    _: *anyopaque,
    _: *const @import("CompositorGlobal.zig").Surface,
) ?@import("../render/types.zig").Size {
    return .{ .width = 1280, .height = 720 };
}

fn testOutputBounds(_: *anyopaque) @import("../render/types.zig").Rect {
    return .{ .x = 0, .y = 0, .width = 1280, .height = 720 };
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
