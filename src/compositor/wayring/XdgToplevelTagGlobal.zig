//! Native `xdg_toplevel_tag_manager_v1` identity metadata.

const XdgToplevelTagGlobal = @This();

const std = @import("std");
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const XdgShell = @import("XdgShell.zig");

const advertised_version: u32 = 1;

server: *Server,
shell: *XdgShell,
global_name: u32,

pub fn init(self: *XdgToplevelTagGlobal, server: *Server, shell: *XdgShell) !void {
    self.* = .{
        .server = server,
        .shell = shell,
        .global_name = undefined,
    };
    self.global_name = try server.createGlobal(
        &generated.xdg_toplevel_tag_manager_v1,
        advertised_version,
        .{ .context = self, .bind = bind },
    );
}

pub fn deinit(self: *XdgToplevelTagGlobal) void {
    self.server.removeGlobal(self.global_name) catch unreachable;
    self.* = undefined;
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *XdgToplevelTagGlobal = @ptrCast(@alignCast(context));
    _ = client.createResource(
        id,
        &generated.xdg_toplevel_tag_manager_v1,
        version,
        .{ .context = self, .dispatch = dispatch },
    ) catch return client.postNoMemory();
}

fn dispatch(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const self: *XdgToplevelTagGlobal = @ptrCast(@alignCast(context));
    switch (try generated.xdg_toplevel_tag_manager_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .set_toplevel_tag => |request| try setMetadata(
            self,
            client,
            request.toplevel,
            .tag,
            request.tag,
        ),
        .set_toplevel_description => |request| try setMetadata(
            self,
            client,
            request.toplevel,
            .description,
            request.description,
        ),
    }
}

fn setMetadata(
    self: *XdgToplevelTagGlobal,
    client: *Server.Client,
    resource_id: u32,
    field: XdgShell.ToplevelTagField,
    value: []const u8,
) !void {
    const object = client.connection.object(resource_id) orelse return error.UnknownToplevel;
    self.shell.setToplevelMetadata(
        client,
        .{ .id = resource_id, .generation = object.generation },
        field,
        value,
    ) catch |err| switch (err) {
        error.OutOfMemory => return client.postNoMemory(),
        else => return err,
    };
}

test "native xdg toplevel tags replace and outlive their manager" {
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
    var tags: XdgToplevelTagGlobal = undefined;
    try tags.init(&server, &shell);
    defer tags.deinit();
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
    var tag_name: u32 = 0;
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
            generated.xdg_toplevel_tag_manager_v1.name,
        )) {
            try std.testing.expectEqual(advertised_version, global.version);
            tag_name = global.name;
        }
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
    const manager: wayring.ObjectHandle = .{
        .id = 5,
        .generation = try core.bind(
            &peer,
            registry.id,
            tag_name,
            generated.xdg_toplevel_tag_manager_v1.name,
            advertised_version,
            5,
            &generated.xdg_toplevel_tag_manager_v1,
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
    try generated.xdg_toplevel_tag_manager_v1_types.requests.set_toplevel_tag(
        &peer,
        manager,
        toplevel,
        "main window",
    );
    try generated.xdg_toplevel_tag_manager_v1_types.requests.set_toplevel_tag(
        &peer,
        manager,
        toplevel,
        "settings",
    );
    try generated.xdg_toplevel_tag_manager_v1_types.requests.set_toplevel_description(
        &peer,
        manager,
        toplevel,
        "Settings window",
    );
    try generated.xdg_toplevel_tag_manager_v1_types.requests.destroy(&peer, manager);
    try generated.xdg_toplevel_types.requests.set_title(&peer, toplevel, "Settings");
    try transferToServer(&peer, client);

    const metadata = try shell.toplevelMetadata(client, toplevel);
    try std.testing.expectEqualStrings("settings", metadata.tag.?);
    try std.testing.expectEqualStrings("Settings window", metadata.description.?);

    try generated.xdg_toplevel_types.requests.destroy(&peer, toplevel);
    try transferToServer(&peer, client);
    try std.testing.expectError(
        error.UnknownResource,
        shell.toplevelMetadata(client, toplevel),
    );
    try generated.xdg_surface_types.requests.destroy(&peer, xdg_surface);
    try generated.wl_surface_types.requests.destroy(&peer, surface);
    try generated.xdg_wm_base_types.requests.destroy(&peer, wm_base);
    try transferToServer(&peer, client);
}

fn testSurfaceSize(_: *anyopaque, _: *const @import("CompositorGlobal.zig").Surface) ?@import("../render/types.zig").Size {
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
