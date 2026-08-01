//! Native xdg-shell toplevel policy layered on Wayring surfaces.

const XdgShell = @This();

const std = @import("std");
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const CompositorGlobal = @import("CompositorGlobal.zig");

const advertised_version: u32 = 6;

allocator: std.mem.Allocator,
server: *Server,
global_name: u32,

pub const CommitDisposition = enum { configure_only, render };

const Binding = struct {
    allocator: std.mem.Allocator,
    owner: *XdgShell,
    resource: wayring.ObjectHandle,
    references: usize = 1,
    surface_count: usize = 0,

    fn reference(self: *Binding) !void {
        if (self.references == std.math.maxInt(usize)) return error.ReferenceOverflow;
        self.references += 1;
        self.surface_count += 1;
    }

    fn unreferenceSurface(self: *Binding) void {
        std.debug.assert(self.surface_count > 0);
        self.surface_count -= 1;
        self.unreference();
    }

    fn unreference(self: *Binding) void {
        std.debug.assert(self.references > 0);
        self.references -= 1;
        if (self.references != 0) return;
        self.allocator.destroy(self);
    }
};

const XdgSurface = struct {
    allocator: std.mem.Allocator,
    binding: *Binding,
    surface: *CompositorGlobal.Surface,
    resource: wayring.ObjectHandle,
    references: usize = 1,
    resource_alive: bool = true,
    surface_alive: bool = true,
    toplevel: ?*Toplevel = null,
    configures: std.ArrayList(u32) = .empty,
    initial_configure_sent: bool = false,
    configured: bool = false,
    pending_geometry: ?Geometry = null,

    fn reference(self: *XdgSurface) !void {
        if (self.references == std.math.maxInt(usize)) return error.ReferenceOverflow;
        self.references += 1;
    }

    fn unreference(self: *XdgSurface) void {
        std.debug.assert(self.references > 0);
        self.references -= 1;
        if (self.references != 0) return;
        if (self.surface.role_context == @as(*anyopaque, @ptrCast(self)))
            self.surface.clearRole(self);
        self.surface.unreference();
        self.configures.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

const Toplevel = struct {
    allocator: std.mem.Allocator,
    xdg_surface: *XdgSurface,
    resource: wayring.ObjectHandle,
    title: ?[]u8 = null,
    app_id: ?[]u8 = null,
    minimum_width: i32 = 0,
    minimum_height: i32 = 0,
    maximum_width: i32 = 0,
    maximum_height: i32 = 0,

    fn deinit(self: *Toplevel) void {
        if (self.title) |title| self.allocator.free(title);
        if (self.app_id) |app_id| self.allocator.free(app_id);
        self.xdg_surface.unreference();
        self.allocator.destroy(self);
    }
};

const Positioner = struct {
    allocator: std.mem.Allocator,
};

const Geometry = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub fn init(self: *XdgShell, allocator: std.mem.Allocator, server: *Server) !void {
    self.* = .{
        .allocator = allocator,
        .server = server,
        .global_name = undefined,
    };
    self.global_name = try server.createGlobal(
        &generated.xdg_wm_base,
        advertised_version,
        .{ .context = self, .bind = bind },
    );
}

pub fn deinit(self: *XdgShell) void {
    self.server.removeGlobal(self.global_name) catch unreachable;
    self.* = undefined;
}

/// Applies xdg-shell's configure barrier to one atomic surface commit. This
/// is called after request dispatch and before any buffer I/O is submitted.
pub fn handleCommit(self: *XdgShell, commit: *CompositorGlobal.Commit) !CommitDisposition {
    if (commit.surface.role_owner != @as(*const anyopaque, @ptrCast(self))) return .render;
    const context = commit.surface.role_context orelse return .render;
    const xdg_surface: *XdgSurface = @ptrCast(@alignCast(context));
    if (!xdg_surface.resource_alive) return .render;
    if (xdg_surface.toplevel == null) {
        try xdg_surface.surface.client.postError(
            xdg_surface.resource,
            @intFromEnum(generated.xdg_surface_types.@"error".not_constructed),
            "xdg_surface has no role object",
        );
        return .render;
    }
    if (!xdg_surface.initial_configure_sent) {
        if (commit.attachment == .buffer) {
            try xdg_surface.surface.client.postError(
                xdg_surface.resource,
                @intFromEnum(generated.xdg_surface_types.@"error".unconfigured_buffer),
                "buffer committed before initial xdg configure",
            );
            return .render;
        }
        try sendInitialConfigure(xdg_surface);
        return .configure_only;
    }
    if (commit.attachment == .buffer and !xdg_surface.configured) {
        try xdg_surface.surface.client.postError(
            xdg_surface.resource,
            @intFromEnum(generated.xdg_surface_types.@"error".unconfigured_buffer),
            "buffer committed before acknowledging xdg configure",
        );
        return .render;
    }
    return .render;
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *XdgShell = @ptrCast(@alignCast(context));
    const binding = self.allocator.create(Binding) catch return client.postNoMemory();
    errdefer self.allocator.destroy(binding);
    binding.* = .{
        .allocator = self.allocator,
        .owner = self,
        .resource = undefined,
    };
    binding.resource = client.createResource(id, &generated.xdg_wm_base, version, .{
        .context = binding,
        .dispatch = dispatchWmBase,
        .destroy = destroyBinding,
    }) catch return client.postNoMemory();
}

fn dispatchWmBase(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const binding: *Binding = @ptrCast(@alignCast(context));
    switch (try generated.xdg_wm_base_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => if (binding.surface_count != 0) return client.postError(
            resource,
            @intFromEnum(generated.xdg_wm_base_types.@"error".defunct_surfaces),
            "xdg_wm_base destroyed before its surfaces",
        ),
        .create_positioner => |request| {
            const positioner = binding.allocator.create(Positioner) catch
                return client.postNoMemory();
            errdefer binding.allocator.destroy(positioner);
            positioner.* = .{ .allocator = binding.allocator };
            const version = @min(
                try client.resourceVersion(resource, &generated.xdg_wm_base),
                generated.xdg_positioner.version,
            );
            _ = client.createResource(request.id, &generated.xdg_positioner, version, .{
                .context = positioner,
                .dispatch = dispatchPositioner,
                .destroy = destroyPositioner,
            }) catch return client.postNoMemory();
        },
        .get_xdg_surface => |request| {
            const object = client.connection.object(request.surface) orelse
                return error.UnknownSurface;
            const surface_handle: wayring.ObjectHandle = .{
                .id = request.surface,
                .generation = object.generation,
            };
            const surface = try CompositorGlobal.surfaceFor(client, surface_handle);
            const xdg_surface = binding.allocator.create(XdgSurface) catch
                return client.postNoMemory();
            errdefer binding.allocator.destroy(xdg_surface);
            xdg_surface.* = .{
                .allocator = binding.allocator,
                .binding = binding,
                .surface = surface,
                .resource = undefined,
            };
            surface.reference() catch return client.postNoMemory();
            errdefer surface.unreference();
            surface.setRole(binding.owner, xdg_surface, surfaceDestroyed) catch return client.postError(
                resource,
                @intFromEnum(generated.xdg_wm_base_types.@"error".role),
                "wl_surface already has a role",
            );
            errdefer surface.clearRole(xdg_surface);
            binding.reference() catch return client.postNoMemory();
            errdefer binding.unreferenceSurface();
            const version = @min(
                try client.resourceVersion(resource, &generated.xdg_wm_base),
                generated.xdg_surface.version,
            );
            xdg_surface.resource = client.createResource(
                request.id,
                &generated.xdg_surface,
                version,
                .{
                    .context = xdg_surface,
                    .dispatch = dispatchXdgSurface,
                    .destroy = destroyXdgSurface,
                },
            ) catch return client.postNoMemory();
        },
        .pong => {},
    }
}

fn destroyBinding(
    context: *anyopaque,
    _: *Server.Client,
    _: wayring.ObjectHandle,
) void {
    const binding: *Binding = @ptrCast(@alignCast(context));
    binding.unreference();
}

fn dispatchPositioner(
    _: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    _ = try generated.xdg_positioner_types.decodeRequest(
        &client.connection,
        resource,
        message,
    );
}

fn destroyPositioner(
    context: *anyopaque,
    _: *Server.Client,
    _: wayring.ObjectHandle,
) void {
    const positioner: *Positioner = @ptrCast(@alignCast(context));
    positioner.allocator.destroy(positioner);
}

fn dispatchXdgSurface(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const xdg_surface: *XdgSurface = @ptrCast(@alignCast(context));
    switch (try generated.xdg_surface_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => if (xdg_surface.toplevel != null) return client.postError(
            resource,
            @intFromEnum(generated.xdg_surface_types.@"error".defunct_role_object),
            "xdg_surface destroyed before its toplevel",
        ),
        .get_toplevel => |request| {
            if (xdg_surface.toplevel != null) return client.postError(
                resource,
                @intFromEnum(generated.xdg_surface_types.@"error".already_constructed),
                "xdg_surface already has a role object",
            );
            const toplevel = xdg_surface.allocator.create(Toplevel) catch
                return client.postNoMemory();
            errdefer xdg_surface.allocator.destroy(toplevel);
            xdg_surface.reference() catch return client.postNoMemory();
            errdefer xdg_surface.unreference();
            toplevel.* = .{
                .allocator = xdg_surface.allocator,
                .xdg_surface = xdg_surface,
                .resource = undefined,
            };
            const version = @min(
                try client.resourceVersion(resource, &generated.xdg_surface),
                generated.xdg_toplevel.version,
            );
            toplevel.resource = client.createResource(
                request.id,
                &generated.xdg_toplevel,
                version,
                .{
                    .context = toplevel,
                    .dispatch = dispatchToplevel,
                    .destroy = destroyToplevel,
                },
            ) catch return client.postNoMemory();
            xdg_surface.toplevel = toplevel;
        },
        .get_popup => return client.postError(
            resource,
            @intFromEnum(generated.xdg_wm_base_types.@"error".invalid_surface_state),
            "native popup policy is not installed",
        ),
        .set_window_geometry => |request| {
            if (request.width <= 0 or request.height <= 0) return client.postError(
                resource,
                @intFromEnum(generated.xdg_surface_types.@"error".invalid_size),
                "xdg window geometry must have positive dimensions",
            );
            xdg_surface.pending_geometry = .{
                .x = request.x,
                .y = request.y,
                .width = request.width,
                .height = request.height,
            };
        },
        .ack_configure => |request| {
            const index = std.mem.indexOfScalar(u32, xdg_surface.configures.items, request.serial) orelse
                return client.postError(
                    resource,
                    @intFromEnum(generated.xdg_surface_types.@"error".invalid_serial),
                    "unknown xdg configure serial",
                );
            xdg_surface.configures.replaceRangeAssumeCapacity(0, index + 1, &.{});
            xdg_surface.configured = true;
        },
    }
}

fn destroyXdgSurface(
    context: *anyopaque,
    _: *Server.Client,
    _: wayring.ObjectHandle,
) void {
    const xdg_surface: *XdgSurface = @ptrCast(@alignCast(context));
    xdg_surface.resource_alive = false;
    xdg_surface.binding.unreferenceSurface();
    xdg_surface.unreference();
}

fn surfaceDestroyed(context: *anyopaque) void {
    const xdg_surface: *XdgSurface = @ptrCast(@alignCast(context));
    xdg_surface.surface_alive = false;
    if (!xdg_surface.resource_alive) return;
    xdg_surface.surface.client.postError(
        xdg_surface.resource,
        @intFromEnum(generated.xdg_surface_types.@"error".defunct_role_object),
        "wl_surface destroyed before its xdg_surface",
    ) catch {};
}

fn dispatchToplevel(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const toplevel: *Toplevel = @ptrCast(@alignCast(context));
    switch (try generated.xdg_toplevel_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .set_title => |request| try replaceText(
            toplevel,
            &toplevel.title,
            request.title,
            client,
        ),
        .set_app_id => |request| try replaceText(
            toplevel,
            &toplevel.app_id,
            request.app_id,
            client,
        ),
        .set_max_size => |request| {
            if (request.width < 0 or request.height < 0) return client.postError(
                resource,
                @intFromEnum(generated.xdg_toplevel_types.@"error".invalid_size),
                "negative maximum toplevel size",
            );
            toplevel.maximum_width = request.width;
            toplevel.maximum_height = request.height;
        },
        .set_min_size => |request| {
            if (request.width < 0 or request.height < 0) return client.postError(
                resource,
                @intFromEnum(generated.xdg_toplevel_types.@"error".invalid_size),
                "negative minimum toplevel size",
            );
            toplevel.minimum_width = request.width;
            toplevel.minimum_height = request.height;
        },
        .set_parent,
        .show_window_menu,
        .move,
        .resize,
        .set_maximized,
        .unset_maximized,
        .set_fullscreen,
        .unset_fullscreen,
        .set_minimized,
        => {},
    }
}

fn replaceText(
    toplevel: *Toplevel,
    destination: *?[]u8,
    source: []const u8,
    client: *Server.Client,
) !void {
    const copy = toplevel.allocator.dupe(u8, source) catch return client.postNoMemory();
    if (destination.*) |previous| toplevel.allocator.free(previous);
    destination.* = copy;
}

fn destroyToplevel(
    context: *anyopaque,
    _: *Server.Client,
    _: wayring.ObjectHandle,
) void {
    const toplevel: *Toplevel = @ptrCast(@alignCast(context));
    if (toplevel.xdg_surface.toplevel == toplevel)
        toplevel.xdg_surface.toplevel = null;
    toplevel.deinit();
}

fn sendInitialConfigure(xdg_surface: *XdgSurface) !void {
    const toplevel = xdg_surface.toplevel.?;
    const client = xdg_surface.surface.client;
    xdg_surface.configures.ensureUnusedCapacity(xdg_surface.allocator, 1) catch
        return client.postNoMemory();
    const version = try client.resourceVersion(toplevel.resource, &generated.xdg_toplevel);
    if (version >= 5) generated.xdg_toplevel_types.events.wm_capabilities(
        &client.connection,
        toplevel.resource,
        &.{},
    ) catch return client.postNoMemory();
    generated.xdg_toplevel_types.events.configure(
        &client.connection,
        toplevel.resource,
        0,
        0,
        &.{},
    ) catch return client.postNoMemory();
    const serial = xdg_surface.surface.owner.server.nextSerial();
    generated.xdg_surface_types.events.configure(
        &client.connection,
        xdg_surface.resource,
        serial,
    ) catch return client.postNoMemory();
    xdg_surface.configures.appendAssumeCapacity(serial);
    xdg_surface.initial_configure_sent = true;
}

test "native xdg toplevel enforces the initial configure barrier" {
    const core = @import("wayring-core");
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var compositor: CompositorGlobal = undefined;
    try compositor.init(std.testing.allocator, &server);
    defer compositor.deinit();
    var shell: XdgShell = undefined;
    try shell.init(std.testing.allocator, &server);
    defer shell.deinit();
    const client = try server.createClient();

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
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const global = (try core.decodeRegistryEvent(&message, registry.id)).global;
        if (std.mem.eql(u8, global.interface, generated.wl_compositor.name))
            compositor_name = global.name;
        if (std.mem.eql(u8, global.interface, generated.xdg_wm_base.name))
            shell_name = global.name;
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
    try generated.wl_surface_types.requests.commit(&peer, surface);
    try transferToServer(&peer, client);

    var initial_transaction = compositor.popTransaction() orelse return error.MissingCommit;
    defer initial_transaction.deinit();
    const initial = &initial_transaction.entries[0];
    try std.testing.expectEqual(
        CommitDisposition.configure_only,
        try shell.handleCommit(initial),
    );
    try transferFromServer(&peer, client);
    var configure_serial: ?u32 = null;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == toplevel.id) {
            _ = try generated.xdg_toplevel_types.decodeEvent(&peer, toplevel, &message);
        } else if (message.object_id == xdg_surface.id) {
            configure_serial = (try generated.xdg_surface_types.decodeEvent(
                &peer,
                xdg_surface,
                &message,
            )).configure.serial;
        }
    }
    try generated.xdg_surface_types.requests.ack_configure(
        &peer,
        xdg_surface,
        configure_serial orelse return error.MissingConfigure,
    );
    try generated.wl_surface_types.requests.commit(&peer, surface);
    try transferToServer(&peer, client);
    var configured_transaction = compositor.popTransaction() orelse return error.MissingCommit;
    defer configured_transaction.deinit();
    try std.testing.expectEqual(
        CommitDisposition.render,
        try shell.handleCommit(&configured_transaction.entries[0]),
    );
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
