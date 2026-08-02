//! Native GTK shell metadata and floating-window configure compatibility.

const GtkShellGlobal = @This();

const std = @import("std");
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const CompositorGlobal = @import("CompositorGlobal.zig");
const XdgShell = @import("XdgShell.zig");

// Version 5 adds authenticated titlebar gestures. Native policy does not yet
// retain the pointer-button state needed to authenticate those requests.
const advertised_version: u32 = 4;

const floating_states: [0]u32 = .{};
const floating_edge_constraints = [_]u32{
    @intFromEnum(generated.gtk_surface1_types.edge_constraint.resizable_top),
    @intFromEnum(generated.gtk_surface1_types.edge_constraint.resizable_right),
    @intFromEnum(generated.gtk_surface1_types.edge_constraint.resizable_bottom),
    @intFromEnum(generated.gtk_surface1_types.edge_constraint.resizable_left),
};

allocator: std.mem.Allocator,
server: *Server,
compositor: *CompositorGlobal,
shell: *XdgShell,
global_name: u32,
binding_count: usize = 0,
surfaces: std.ArrayList(*GtkSurface) = .empty,

const Binding = struct {
    owner: *GtkShellGlobal,
    startup_id: ?[]u8 = null,

    fn setStartupId(self: *Binding, client: *Server.Client, startup_id: ?[]const u8) !void {
        const replacement = copyOptionalText(self.owner.allocator, startup_id) catch |err| switch (err) {
            error.OutOfMemory => return client.postNoMemory(),
            error.InvalidUtf8 => return err,
        };
        freeOptionalText(self.owner.allocator, self.startup_id);
        self.startup_id = replacement;
    }

    fn deinit(self: *Binding) void {
        const owner = self.owner;
        freeOptionalText(owner.allocator, self.startup_id);
        std.debug.assert(owner.binding_count > 0);
        owner.binding_count -= 1;
        owner.allocator.destroy(self);
    }
};

const DbusProperties = struct {
    application_id: ?[]u8 = null,
    app_menu_path: ?[]u8 = null,
    menubar_path: ?[]u8 = null,
    window_object_path: ?[]u8 = null,
    application_object_path: ?[]u8 = null,
    unique_bus_name: ?[]u8 = null,

    fn init(
        allocator: std.mem.Allocator,
        application_id: ?[]const u8,
        app_menu_path: ?[]const u8,
        menubar_path: ?[]const u8,
        window_object_path: ?[]const u8,
        application_object_path: ?[]const u8,
        unique_bus_name: ?[]const u8,
    ) !DbusProperties {
        var properties: DbusProperties = .{};
        errdefer properties.deinit(allocator);
        properties.application_id = try copyOptionalText(allocator, application_id);
        properties.app_menu_path = try copyOptionalText(allocator, app_menu_path);
        properties.menubar_path = try copyOptionalText(allocator, menubar_path);
        properties.window_object_path = try copyOptionalText(allocator, window_object_path);
        properties.application_object_path = try copyOptionalText(
            allocator,
            application_object_path,
        );
        properties.unique_bus_name = try copyOptionalText(allocator, unique_bus_name);
        return properties;
    }

    fn deinit(self: *DbusProperties, allocator: std.mem.Allocator) void {
        freeOptionalText(allocator, self.application_id);
        freeOptionalText(allocator, self.app_menu_path);
        freeOptionalText(allocator, self.menubar_path);
        freeOptionalText(allocator, self.window_object_path);
        freeOptionalText(allocator, self.application_object_path);
        freeOptionalText(allocator, self.unique_bus_name);
        self.* = .{};
    }
};

const GtkSurface = struct {
    owner: *GtkShellGlobal,
    resource: wayring.ObjectHandle,
    surface: *CompositorGlobal.Surface,
    properties: DbusProperties = .{},
    modal: bool = false,

    fn replaceProperties(
        self: *GtkSurface,
        client: *Server.Client,
        request: anytype,
    ) !void {
        const replacement = DbusProperties.init(
            self.owner.allocator,
            request.application_id,
            request.app_menu_path,
            request.menubar_path,
            request.window_object_path,
            request.application_object_path,
            request.unique_bus_name,
        ) catch |err| switch (err) {
            error.OutOfMemory => return client.postNoMemory(),
            error.InvalidUtf8 => return err,
        };
        self.properties.deinit(self.owner.allocator);
        self.properties = replacement;
    }

    fn deinit(self: *GtkSurface) void {
        const owner = self.owner;
        self.properties.deinit(owner.allocator);
        self.surface.unreference();
        for (owner.surfaces.items, 0..) |candidate, index| {
            if (candidate != self) continue;
            _ = owner.surfaces.orderedRemove(index);
            owner.allocator.destroy(self);
            return;
        }
        unreachable;
    }
};

pub fn init(
    self: *GtkShellGlobal,
    allocator: std.mem.Allocator,
    server: *Server,
    compositor: *CompositorGlobal,
    shell: *XdgShell,
) !void {
    self.* = .{
        .allocator = allocator,
        .server = server,
        .compositor = compositor,
        .shell = shell,
        .global_name = undefined,
    };
    self.global_name = try server.createGlobal(
        &generated.gtk_shell1,
        advertised_version,
        .{ .context = self, .bind = bind },
    );
    shell.setToplevelConfigureHandler(.{
        .context = self,
        .configure = configureToplevel,
    });
}

pub fn deinit(self: *GtkShellGlobal) void {
    std.debug.assert(self.binding_count == 0);
    std.debug.assert(self.surfaces.items.len == 0);
    self.shell.clearToplevelConfigureHandler(self);
    self.server.removeGlobal(self.global_name) catch unreachable;
    self.surfaces.deinit(self.allocator);
    self.* = undefined;
}

pub fn isModal(
    self: *const GtkShellGlobal,
    surface: *const CompositorGlobal.Surface,
) bool {
    if (!surface.resource_alive) return false;
    for (self.surfaces.items) |gtk_surface| {
        if (gtk_surface.surface == surface and gtk_surface.modal) return true;
    }
    return false;
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *GtkShellGlobal = @ptrCast(@alignCast(context));
    const binding = self.allocator.create(Binding) catch return client.postNoMemory();
    binding.* = .{ .owner = self };
    const resource = client.createResource(id, &generated.gtk_shell1, version, .{
        .context = binding,
        .dispatch = dispatchShell,
        .destroy = destroyBinding,
    }) catch {
        self.allocator.destroy(binding);
        return client.postNoMemory();
    };
    self.binding_count += 1;
    generated.gtk_shell1_types.events.capabilities(
        &client.connection,
        resource,
        0,
    ) catch return client.postNoMemory();
}

fn dispatchShell(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const binding: *Binding = @ptrCast(@alignCast(context));
    switch (try generated.gtk_shell1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .get_gtk_surface => |request| try binding.owner.createSurface(
            client,
            resource,
            request.surface,
            request.gtk_surface,
        ),
        .set_startup_id => |request| try binding.setStartupId(client, request.startup_id),
        .system_bell => {},
        .notify_launch => |request| if (!std.unicode.utf8ValidateSlice(request.startup_id))
            return error.InvalidUtf8,
    }
}

fn destroyBinding(
    context: *anyopaque,
    _: *Server.Client,
    _: wayring.ObjectHandle,
) void {
    const binding: *Binding = @ptrCast(@alignCast(context));
    binding.deinit();
}

fn createSurface(
    self: *GtkShellGlobal,
    client: *Server.Client,
    shell_resource: wayring.ObjectHandle,
    surface_id: u32,
    id: u32,
) !void {
    const object = client.connection.object(surface_id) orelse return error.UnknownSurface;
    const surface = try CompositorGlobal.surfaceFor(client, .{
        .id = surface_id,
        .generation = object.generation,
    });
    if (surface.owner != self.compositor) return error.WrongSurface;
    const gtk_surface = self.allocator.create(GtkSurface) catch
        return client.postNoMemory();
    errdefer self.allocator.destroy(gtk_surface);
    self.surfaces.ensureUnusedCapacity(self.allocator, 1) catch
        return client.postNoMemory();
    surface.reference() catch return client.postNoMemory();
    errdefer surface.unreference();
    const version = @min(
        try client.resourceVersion(shell_resource, &generated.gtk_shell1),
        generated.gtk_surface1.version,
    );
    gtk_surface.* = .{
        .owner = self,
        .resource = undefined,
        .surface = surface,
    };
    gtk_surface.resource = client.createResource(
        id,
        &generated.gtk_surface1,
        version,
        .{
            .context = gtk_surface,
            .dispatch = dispatchSurface,
            .destroy = destroySurface,
        },
    ) catch return client.postNoMemory();
    self.surfaces.appendAssumeCapacity(gtk_surface);
}

fn dispatchSurface(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const surface: *GtkSurface = @ptrCast(@alignCast(context));
    switch (try generated.gtk_surface1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .set_dbus_properties => |request| try surface.replaceProperties(client, request),
        .set_modal => surface.modal = true,
        .unset_modal => surface.modal = false,
        .present => {},
        .request_focus => |request| if (request.startup_id) |startup_id| {
            if (!std.unicode.utf8ValidateSlice(startup_id)) return error.InvalidUtf8;
        },
        .release => {},
        .titlebar_gesture => unreachable,
    }
}

fn destroySurface(
    context: *anyopaque,
    _: *Server.Client,
    _: wayring.ObjectHandle,
) void {
    const surface: *GtkSurface = @ptrCast(@alignCast(context));
    surface.deinit();
}

fn configureToplevel(context: *anyopaque, surface: *CompositorGlobal.Surface) !void {
    const self: *GtkShellGlobal = @ptrCast(@alignCast(context));
    if (!surface.resource_alive) return;
    for (self.surfaces.items) |gtk_surface| {
        if (gtk_surface.surface != surface) continue;
        generated.gtk_surface1_types.events.configure(
            &surface.client.connection,
            gtk_surface.resource,
            std.mem.sliceAsBytes(configureStates()),
        ) catch return surface.client.postNoMemory();
        const version = try surface.client.resourceVersion(
            gtk_surface.resource,
            &generated.gtk_surface1,
        );
        if (version < 2) continue;
        generated.gtk_surface1_types.events.configure_edges(
            &surface.client.connection,
            gtk_surface.resource,
            std.mem.sliceAsBytes(edgeConstraints()),
        ) catch return surface.client.postNoMemory();
    }
}

fn configureStates() []const u32 {
    return &floating_states;
}

fn edgeConstraints() []const u32 {
    return &floating_edge_constraints;
}

fn copyOptionalText(
    allocator: std.mem.Allocator,
    text: ?[]const u8,
) error{ OutOfMemory, InvalidUtf8 }!?[]u8 {
    const value = text orelse return null;
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
    return try allocator.dupe(u8, value);
}

fn freeOptionalText(allocator: std.mem.Allocator, text: ?[]u8) void {
    if (text) |value| allocator.free(value);
}

test "native GTK floating configure state is empty" {
    try std.testing.expectEqualSlices(u32, &.{}, configureStates());
}

test "native GTK floating surfaces advertise every resizable edge" {
    try std.testing.expectEqualSlices(
        u32,
        &.{
            @intFromEnum(generated.gtk_surface1_types.edge_constraint.resizable_top),
            @intFromEnum(generated.gtk_surface1_types.edge_constraint.resizable_right),
            @intFromEnum(generated.gtk_surface1_types.edge_constraint.resizable_bottom),
            @intFromEnum(generated.gtk_surface1_types.edge_constraint.resizable_left),
        },
        edgeConstraints(),
    );
}

test "native GTK shell configures XDG surfaces and owns child lifetimes" {
    const core = @import("wayring-core");
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
    var gtk_shell: GtkShellGlobal = undefined;
    try gtk_shell.init(
        std.testing.allocator,
        &server,
        &compositor,
        &shell,
    );
    defer gtk_shell.deinit();
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
    var gtk_shell_name: u32 = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const global = (try core.decodeRegistryEvent(&message, registry.id)).global;
        if (std.mem.eql(u8, global.interface, generated.wl_compositor.name))
            compositor_name = global.name;
        if (std.mem.eql(u8, global.interface, generated.xdg_wm_base.name))
            shell_name = global.name;
        if (std.mem.eql(u8, global.interface, generated.gtk_shell1.name)) {
            try std.testing.expectEqual(advertised_version, global.version);
            gtk_shell_name = global.name;
        }
    }
    try std.testing.expect(compositor_name != 0);
    try std.testing.expect(shell_name != 0);
    try std.testing.expect(gtk_shell_name != 0);

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
    const gtk_shell_resource: wayring.ObjectHandle = .{
        .id = 5,
        .generation = try core.bind(
            &peer,
            registry.id,
            gtk_shell_name,
            generated.gtk_shell1.name,
            advertised_version,
            5,
            &generated.gtk_shell1,
        ),
    };
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    var found_capabilities = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id != gtk_shell_resource.id) continue;
        const event = try generated.gtk_shell1_types.decodeEvent(
            &peer,
            gtk_shell_resource,
            &message,
        );
        try std.testing.expectEqual(@as(u32, 0), event.capabilities.capabilities);
        found_capabilities = true;
    }
    try std.testing.expect(found_capabilities);

    try generated.gtk_shell1_types.requests.set_startup_id(
        &peer,
        gtk_shell_resource,
        "keywork-startup",
    );
    try generated.gtk_shell1_types.requests.notify_launch(
        &peer,
        gtk_shell_resource,
        "keywork-launch",
    );
    const surface_resource = try generated.wl_compositor_types.requests.create_surface(
        &peer,
        compositor_resource,
    );
    const xdg_surface = try generated.xdg_wm_base_types.requests.get_xdg_surface(
        &peer,
        wm_base,
        surface_resource,
    );
    const toplevel = try generated.xdg_surface_types.requests.get_toplevel(
        &peer,
        xdg_surface,
    );
    const gtk_surface = try generated.gtk_shell1_types.requests.get_gtk_surface(
        &peer,
        gtk_shell_resource,
        surface_resource,
    );
    try generated.gtk_surface1_types.requests.set_dbus_properties(
        &peer,
        gtk_surface,
        "org.keywork.Test",
        "/org/keywork/Test/Menu",
        null,
        "/org/keywork/Test/Window",
        "/org/keywork/Test",
        ":1.42",
    );
    try generated.gtk_surface1_types.requests.set_modal(&peer, gtk_surface);
    try generated.gtk_surface1_types.requests.present(&peer, gtk_surface, 42);
    try generated.gtk_surface1_types.requests.request_focus(
        &peer,
        gtk_surface,
        "keywork-focus",
    );
    try generated.wl_surface_types.requests.commit(&peer, surface_resource);
    try transferToServer(&peer, client);

    const server_surface = try CompositorGlobal.surfaceFor(client, .{
        .id = surface_resource.id,
        .generation = client.connection.object(surface_resource.id).?.generation,
    });
    try std.testing.expect(gtk_shell.isModal(server_surface));
    var initial = compositor.popTransaction() orelse return error.MissingCommit;
    defer initial.deinit();
    try std.testing.expectEqual(
        .configure_only,
        (try shell.handleCommit(&initial.entries[0])).disposition,
    );
    try transferFromServer(&peer, client);
    _ = try expectConfigureSequence(&peer, gtk_surface, toplevel, xdg_surface);

    try generated.gtk_surface1_types.requests.release(&peer, gtk_surface);
    try transferToServer(&peer, client);
    try std.testing.expect(!gtk_shell.isModal(server_surface));
    const replacement = try generated.gtk_shell1_types.requests.get_gtk_surface(
        &peer,
        gtk_shell_resource,
        surface_resource,
    );
    try generated.gtk_surface1_types.requests.set_modal(&peer, replacement);
    try transferToServer(&peer, client);
    try std.testing.expect(gtk_shell.isModal(server_surface));

    const server_binding: wayring.ObjectHandle = .{
        .id = gtk_shell_resource.id,
        .generation = client.connection.object(gtk_shell_resource.id).?.generation,
    };
    try client.destroyResource(server_binding);
    try generated.gtk_surface1_types.requests.unset_modal(&peer, replacement);
    try generated.gtk_surface1_types.requests.set_modal(&peer, replacement);
    try transferToServer(&peer, client);
    try std.testing.expect(gtk_shell.isModal(server_surface));

    try generated.xdg_toplevel_types.requests.destroy(&peer, toplevel);
    try generated.xdg_surface_types.requests.destroy(&peer, xdg_surface);
    try generated.wl_surface_types.requests.destroy(&peer, surface_resource);
    try generated.gtk_surface1_types.requests.unset_modal(&peer, replacement);
    try transferToServer(&peer, client);
    try std.testing.expect(!gtk_shell.isModal(server_surface));
    try std.testing.expectEqual(Server.ClientState.active, client.state);
    try generated.gtk_surface1_types.requests.release(&peer, replacement);
    try transferToServer(&peer, client);
}

fn expectConfigureSequence(
    peer: *wayring.Connection,
    gtk_surface: wayring.ObjectHandle,
    toplevel: wayring.ObjectHandle,
    xdg_surface: wayring.ObjectHandle,
) !u32 {
    const core = @import("wayring-core");
    var stage: u8 = 0;
    var serial: ?u32 = null;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == gtk_surface.id) {
            switch (try generated.gtk_surface1_types.decodeEvent(
                peer,
                gtk_surface,
                &message,
            )) {
                .configure => |event| {
                    try std.testing.expectEqual(@as(u8, 0), stage);
                    try std.testing.expectEqualSlices(u8, &.{}, event.states);
                    stage = 1;
                },
                .configure_edges => |event| {
                    try std.testing.expectEqual(@as(u8, 1), stage);
                    try std.testing.expectEqualSlices(
                        u8,
                        std.mem.sliceAsBytes(edgeConstraints()),
                        event.constraints,
                    );
                    stage = 2;
                },
            }
        } else if (message.object_id == toplevel.id) {
            switch (try generated.xdg_toplevel_types.decodeEvent(
                peer,
                toplevel,
                &message,
            )) {
                .configure => {
                    try std.testing.expectEqual(@as(u8, 2), stage);
                    stage = 3;
                },
                else => {},
            }
        } else if (message.object_id == xdg_surface.id) {
            const event = try generated.xdg_surface_types.decodeEvent(
                peer,
                xdg_surface,
                &message,
            );
            try std.testing.expectEqual(@as(u8, 3), stage);
            stage = 4;
            serial = event.configure.serial;
        } else if (message.object_id == 1) {
            _ = try core.decodeDisplayEvent(&message);
        }
    }
    try std.testing.expectEqual(@as(u8, 4), stage);
    return serial orelse error.MissingConfigure;
}

fn testSurfaceSize(
    _: *anyopaque,
    _: *const CompositorGlobal.Surface,
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
