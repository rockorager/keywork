//! Unpublished scanner-resource adapter for stable xdg-shell.
//!
//! The adapter owns generated resources, wire serials, configure snapshots,
//! and double-buffered requests. XdgShell remains the only semantic role
//! owner, while WayringCompositor remains the only generated wl_surface and
//! content owner. No global is registered here; Wave 7 owns publication.

const WayringXdgShell = @This();

const std = @import("std");
const core = @import("wayring-protocol");
const wayring = @import("wayring");
const ClientRegistry = @import("../ClientRegistry.zig");
const OutputLayout = @import("output_layout.zig");
const Scene = @import("../scene.zig");
const SurfaceRegistry = @import("../SurfaceRegistry.zig");
const XdgShell = @import("../XdgShell.zig");
const WayringClients = @import("WayringClients.zig");
const WayringCompositor = @import("WayringCompositor.zig");
const WayringOutput = @import("WayringOutput.zig");

const server = wayring.server;
const wire = wayring.wire;

const prepared_configure_bytes = 128;

allocator: std.mem.Allocator,
protocol_server: *server.Server,
core_shell: *XdgShell,
clients: *WayringClients,
compositor: *WayringCompositor,
outputs: ?*WayringOutput,
managers: std.ArrayList(*Manager) = .empty,
positioners: std.ArrayList(*Positioner) = .empty,
surfaces: std.ArrayList(*Surface) = .empty,
toplevels: std.ArrayList(*Toplevel) = .empty,
popups: std.ArrayList(*Popup) = .empty,
next_resource_generation: ?u64 = 1,

const Manager = struct {
    adapter: *WayringXdgShell,
    client: *server.Client,
    generation: u64,
    resource: core.xdg_wm_base.Resource,
    surface_count: usize = 0,
};

const Positioner = struct {
    adapter: *WayringXdgShell,
    client: *server.Client,
    generation: u64,
    resource: core.xdg_positioner.Resource,
    rules: XdgShell.Rules = .{},
    parent_configure_serial: ?u32 = null,
};

const PositionerSnapshot = struct {
    rules: XdgShell.Rules,
    parent_configure: ?XdgShell.ConfigureToken,
};

const Configure = struct {
    serial: u32,
    accepted: XdgShell.AcceptedConfigure,
};

const ActiveRole = union(enum) {
    toplevel: *Toplevel,
    popup: *Popup,
};

const Surface = struct {
    adapter: *WayringXdgShell,
    manager: *Manager,
    client: *server.Client,
    generation: u64,
    resource: core.xdg_surface.Resource,
    surface_id: WayringCompositor.SurfaceId,
    reservation: WayringCompositor.XdgReservation,
    core_id: XdgShell.XdgSurfaceId,
    active_role: ?ActiveRole = null,
    pending_geometry: ?XdgShell.Geometry = null,
    pending_geometry_changed: bool = false,
    configures: std.ArrayList(Configure) = .empty,
    accepted_configure: ?Configure = null,
    initial_configure_sent: bool = false,
    prepared_events: ?wire.PreparedBatch = null,
    prepared_commit: ?WayringCompositor.XdgDirectCommit = null,
};

const Toplevel = struct {
    adapter: *WayringXdgShell,
    surface: *Surface,
    generation: u64,
    resource: core.xdg_toplevel.Resource,
    core_id: XdgShell.WindowId,
};

const Popup = struct {
    adapter: *WayringXdgShell,
    surface: *Surface,
    generation: u64,
    resource: core.xdg_popup.Resource,
    core_id: XdgShell.PopupId,
    parent_core_id: ?XdgShell.XdgSurfaceId,
    positioner: PositionerSnapshot,
    reposition: ?struct {
        positioner: PositionerSnapshot,
        token: u32,
    } = null,
};

pub fn init(
    self: *WayringXdgShell,
    allocator: std.mem.Allocator,
    protocol_server: *server.Server,
    core_shell: *XdgShell,
    clients: *WayringClients,
    compositor: *WayringCompositor,
    outputs: ?*WayringOutput,
) void {
    self.* = .{
        .allocator = allocator,
        .protocol_server = protocol_server,
        .core_shell = core_shell,
        .clients = clients,
        .compositor = compositor,
        .outputs = outputs,
    };
}

pub fn deinit(self: *WayringXdgShell) void {
    std.debug.assert(self.popups.items.len == 0);
    std.debug.assert(self.toplevels.items.len == 0);
    std.debug.assert(self.surfaces.items.len == 0);
    std.debug.assert(self.positioners.items.len == 0);
    std.debug.assert(self.managers.items.len == 0);
    self.popups.deinit(self.allocator);
    self.toplevels.deinit(self.allocator);
    self.surfaces.deinit(self.allocator);
    self.positioners.deinit(self.allocator);
    self.managers.deinit(self.allocator);
    self.* = undefined;
}

/// Installs an xdg_wm_base resource without registering a global. This is the
/// only Wave-2 bootstrap seam and is intentionally suitable for tests rather
/// than production assembly.
pub fn installUnpublishedForTest(
    self: *WayringXdgShell,
    client: *server.Client,
    object_id: u32,
    version: u32,
) !void {
    if (version == 0 or version > core.xdg_wm_base.interface.version) {
        return error.InvalidVersion;
    }
    try self.managers.ensureUnusedCapacity(self.allocator, 1);
    const generation = try self.issueGeneration();
    const manager = try self.allocator.create(Manager);
    errdefer self.allocator.destroy(manager);
    manager.* = .{
        .adapter = self,
        .client = client,
        .generation = generation,
        .resource = .init(self.allocator, object_id, version, .client, client.ownerHooks()),
    };
    manager.resource.setHandler(Manager, manager, handleManager, null) catch unreachable;
    try client.installClientInitial(object_id, &manager.resource.runtime);
    self.managers.appendAssumeCapacity(manager);
}

pub fn destroyClientResources(self: *WayringXdgShell, client: *server.Client) void {
    var index = self.popups.items.len;
    while (index > 0) {
        index -= 1;
        const popup = self.popups.items[index];
        if (popup.surface.client == client) self.destroyPopup(popup, false);
    }
    index = self.toplevels.items.len;
    while (index > 0) {
        index -= 1;
        const toplevel = self.toplevels.items[index];
        if (toplevel.surface.client == client) self.destroyToplevel(toplevel, false);
    }
    index = self.surfaces.items.len;
    while (index > 0) {
        index -= 1;
        const surface = self.surfaces.items[index];
        if (surface.client == client) self.destroySurface(surface, false);
    }
    index = self.positioners.items.len;
    while (index > 0) {
        index -= 1;
        const positioner = self.positioners.items[index];
        if (positioner.client == client) self.destroyPositioner(positioner);
    }
    index = self.managers.items.len;
    while (index > 0) {
        index -= 1;
        const manager = self.managers.items[index];
        if (manager.client == client) self.destroyManager(manager);
    }
}

fn issueGeneration(self: *WayringXdgShell) error{GenerationExhausted}!u64 {
    const generation = self.next_resource_generation orelse return error.GenerationExhausted;
    self.next_resource_generation = if (generation == std.math.maxInt(u64)) null else generation + 1;
    return generation;
}

fn handleManager(
    resource: *core.xdg_wm_base.Resource,
    request: core.xdg_wm_base.Request,
    manager: *Manager,
) !void {
    switch (request) {
        .destroy => {
            if (manager.surface_count != 0) {
                manager.client.postProtocolError(
                    &resource.runtime,
                    @intCast(core.xdg_wm_base.@"error".defunct_surfaces),
                    "xdg_wm_base still owns xdg_surface objects",
                );
                return;
            }
            manager.adapter.destroyManager(manager);
        },
        .create_positioner => |create| try manager.adapter.createPositioner(manager, create.id),
        .get_xdg_surface => |get| try manager.adapter.createSurface(manager, get.id, get.surface),
        .pong => {},
    }
}

fn createPositioner(
    self: *WayringXdgShell,
    manager: *Manager,
    object_id: u32,
) !void {
    try self.positioners.ensureUnusedCapacity(self.allocator, 1);
    const generation = try self.issueGeneration();
    const positioner = try self.allocator.create(Positioner);
    errdefer self.allocator.destroy(positioner);
    positioner.* = .{
        .adapter = self,
        .client = manager.client,
        .generation = generation,
        .resource = .init(
            self.allocator,
            object_id,
            @min(manager.resource.version(), core.xdg_positioner.interface.version),
            .client,
            manager.client.ownerHooks(),
        ),
    };
    positioner.resource.setHandler(Positioner, positioner, handlePositioner, null) catch unreachable;
    manager.client.materialize(&positioner.resource.runtime) catch unreachable;
    self.positioners.appendAssumeCapacity(positioner);
}

fn handlePositioner(
    resource: *core.xdg_positioner.Resource,
    request: core.xdg_positioner.Request,
    positioner: *Positioner,
) !void {
    switch (request) {
        .destroy => positioner.adapter.destroyPositioner(positioner),
        .set_size => |set| {
            if (set.width <= 0 or set.height <= 0) {
                positioner.client.postProtocolError(
                    &resource.runtime,
                    @intCast(core.xdg_positioner.@"error".invalid_input),
                    "positioner size must be positive",
                );
                return;
            }
            positioner.rules.size = .{ .width = set.width, .height = set.height };
        },
        .set_anchor_rect => |set| {
            if (set.width < 0 or set.height < 0) {
                positioner.client.postProtocolError(
                    &resource.runtime,
                    @intCast(core.xdg_positioner.@"error".invalid_input),
                    "anchor rectangle size must not be negative",
                );
                return;
            }
            positioner.rules.anchor_rect = .{
                .x = set.x,
                .y = set.y,
                .width = set.width,
                .height = set.height,
            };
        },
        .set_anchor => |set| {
            const anchor = decodeAnchor(set.anchor) orelse {
                positioner.client.postProtocolError(
                    &resource.runtime,
                    @intCast(core.xdg_positioner.@"error".invalid_input),
                    "invalid positioner anchor",
                );
                return;
            };
            positioner.rules.anchor = anchor;
        },
        .set_gravity => |set| {
            const gravity = decodeAnchor(set.gravity) orelse {
                positioner.client.postProtocolError(
                    &resource.runtime,
                    @intCast(core.xdg_positioner.@"error".invalid_input),
                    "invalid positioner gravity",
                );
                return;
            };
            positioner.rules.gravity = gravity;
        },
        .set_constraint_adjustment => |set| {
            if (set.constraint_adjustment & ~@as(u32, 0x3f) != 0) {
                positioner.client.postProtocolError(
                    &resource.runtime,
                    @intCast(core.xdg_positioner.@"error".invalid_input),
                    "invalid constraint adjustment",
                );
                return;
            }
            positioner.rules.adjustment = @bitCast(set.constraint_adjustment);
        },
        .set_offset => |set| positioner.rules.offset = .{ .x = set.x, .y = set.y },
        .set_reactive => positioner.rules.reactive = true,
        .set_parent_size => |set| {
            if (set.parent_width <= 0 or set.parent_height <= 0) {
                positioner.client.postProtocolError(
                    &resource.runtime,
                    @intCast(core.xdg_positioner.@"error".invalid_input),
                    "parent size must be positive",
                );
                return;
            }
            positioner.rules.parent_size = .{
                .width = set.parent_width,
                .height = set.parent_height,
            };
        },
        .set_parent_configure => |set| positioner.parent_configure_serial = set.serial,
    }
}

fn createSurface(
    self: *WayringXdgShell,
    manager: *Manager,
    object_id: u32,
    wl_surface_object_id: u32,
) !void {
    const surface_id = self.compositor.surfaceId(manager.client, wl_surface_object_id) orelse {
        manager.client.postProtocolError(
            &manager.resource.runtime,
            @intCast(core.xdg_wm_base.@"error".role),
            "invalid wl_surface for xdg role",
        );
        return;
    };
    const reservation = self.compositor.reserveXdgRoot(manager.client, surface_id) catch |err| switch (err) {
        error.GenerationExhausted => return error.GenerationExhausted,
        else => {
            manager.client.postProtocolError(
                &manager.resource.runtime,
                @intCast(core.xdg_wm_base.@"error".role),
                "wl_surface is not available for an xdg role",
            );
            return;
        },
    };
    var reservation_owned = true;
    errdefer if (reservation_owned) self.compositor.releaseXdgRoot(reservation) catch {};

    const content = self.compositor.xdgContentState(surface_id) orelse {
        self.compositor.releaseXdgRoot(reservation) catch {};
        reservation_owned = false;
        manager.client.postProtocolError(
            &manager.resource.runtime,
            @intCast(core.xdg_wm_base.@"error".role),
            "wl_surface ceased to be available for an xdg role",
        );
        return;
    };
    const has_permanent_xdg_role = self.compositor.permanentXdgRole(surface_id) != null;
    if (content.has_pending_attachment or
        (!has_permanent_xdg_role and content.has_committed_buffer))
    {
        self.compositor.releaseXdgRoot(reservation) catch unreachable;
        reservation_owned = false;
        manager.client.postProtocolError(
            &manager.resource.runtime,
            @intCast(core.xdg_wm_base.@"error".invalid_surface_state),
            "wl_surface already has a buffer attached or committed",
        );
        return;
    }

    try self.surfaces.ensureUnusedCapacity(self.allocator, 1);
    const generation = try self.issueGeneration();
    const surface = try self.allocator.create(Surface);
    errdefer self.allocator.destroy(surface);
    surface.* = .{
        .adapter = self,
        .manager = manager,
        .client = manager.client,
        .generation = generation,
        .resource = .init(
            self.allocator,
            object_id,
            @min(manager.resource.version(), core.xdg_surface.interface.version),
            .client,
            manager.client.ownerHooks(),
        ),
        .surface_id = surface_id,
        .reservation = reservation,
        .core_id = undefined,
    };
    surface.resource.setHandler(Surface, surface, handleSurface, null) catch unreachable;
    manager.client.materialize(&surface.resource.runtime) catch unreachable;
    var resource_owned = true;
    errdefer if (resource_owned) {
        surface.resource.destroy();
        surface.resource.deinit();
    };

    const client_id = self.clients.id(manager.client) orelse return error.UnregisteredClient;
    surface.core_id = try self.core_shell.createSurface(surface_id, client_id, surfaceEndpoint(surface));
    var core_owned = true;
    errdefer if (core_owned) self.core_shell.removeSurface(surface.core_id);
    try self.compositor.attachXdgCommitHandler(reservation, commitHandler(surface));

    manager.surface_count += 1;
    self.surfaces.appendAssumeCapacity(surface);
    core_owned = false;
    resource_owned = false;
    reservation_owned = false;
}

fn handleSurface(
    resource: *core.xdg_surface.Resource,
    request: core.xdg_surface.Request,
    surface: *Surface,
) !void {
    switch (request) {
        .destroy => {
            if (surface.active_role != null) {
                surface.client.postProtocolError(
                    &resource.runtime,
                    @intCast(core.xdg_surface.@"error".defunct_role_object),
                    "destroy the xdg role object before xdg_surface",
                );
                return;
            }
            surface.adapter.destroySurface(surface, false);
        },
        .get_toplevel => |get| try surface.adapter.createToplevel(surface, get.id),
        .get_popup => |get| try surface.adapter.createPopup(
            surface,
            get.id,
            get.parent,
            get.positioner,
        ),
        .set_window_geometry => |set| {
            if (!requireRole(surface)) return;
            if (set.width <= 0 or set.height <= 0) {
                surface.client.postProtocolError(
                    &resource.runtime,
                    @intCast(core.xdg_surface.@"error".invalid_size),
                    "window geometry size must be positive",
                );
                return;
            }
            surface.pending_geometry = .{
                .x = set.x,
                .y = set.y,
                .width = set.width,
                .height = set.height,
            };
            surface.pending_geometry_changed = true;
        },
        .ack_configure => |ack| {
            if (!requireRole(surface)) return;
            surface.adapter.ackConfigure(surface, ack.serial);
        },
    }
}

fn createToplevel(
    self: *WayringXdgShell,
    surface: *Surface,
    object_id: u32,
) !void {
    if (surface.active_role != null) {
        surface.client.postProtocolError(
            &surface.resource.runtime,
            @intCast(core.xdg_surface.@"error".already_constructed),
            "xdg_surface already has a role",
        );
        return;
    }
    if (self.compositor.permanentXdgRole(surface.surface_id)) |role| if (role != .toplevel) {
        surface.client.postProtocolError(
            &surface.resource.runtime,
            @intCast(core.xdg_surface.@"error".already_constructed),
            "wl_surface has a different permanent XDG role",
        );
        return;
    };

    try self.toplevels.ensureUnusedCapacity(self.allocator, 1);
    const generation = try self.issueGeneration();
    const toplevel = try self.allocator.create(Toplevel);
    errdefer self.allocator.destroy(toplevel);
    toplevel.* = .{
        .adapter = self,
        .surface = surface,
        .generation = generation,
        .resource = .init(
            self.allocator,
            object_id,
            @min(surface.resource.version(), core.xdg_toplevel.interface.version),
            .client,
            surface.client.ownerHooks(),
        ),
        .core_id = undefined,
    };
    toplevel.resource.setHandler(Toplevel, toplevel, handleToplevel, null) catch unreachable;
    surface.client.materialize(&toplevel.resource.runtime) catch unreachable;
    var resource_owned = true;
    errdefer if (resource_owned) {
        toplevel.resource.destroy();
        toplevel.resource.deinit();
    };

    const pid = if (surface.client.credentials()) |credentials| credentials.pid else -1;
    toplevel.core_id = self.core_shell.createToplevel(surface.core_id, pid) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSurface, error.RoleAssigned => return error.InvalidNeutralSurface,
    };
    var core_owned = true;
    errdefer if (core_owned) self.core_shell.destroyToplevel(toplevel.core_id);
    // Generated toplevels begin private and non-interactive. The first
    // configured non-null-buffer commit atomically hands presentation to the
    // Scene after Wayring content publication; Wave 5 owns interaction.
    try self.core_shell.setWindowScenePresentationEnabled(toplevel.core_id, false);
    self.core_shell.setWindowInteractionEnabled(toplevel.core_id, false);
    _ = self.compositor.assignXdgRole(surface.reservation, .toplevel) catch unreachable;

    surface.active_role = .{ .toplevel = toplevel };
    self.toplevels.appendAssumeCapacity(toplevel);
    core_owned = false;
    resource_owned = false;
}

fn handleToplevel(
    resource: *core.xdg_toplevel.Resource,
    request: core.xdg_toplevel.Request,
    toplevel: *Toplevel,
) !void {
    const shell = toplevel.adapter.core_shell;
    switch (request) {
        .destroy => toplevel.adapter.destroyToplevel(toplevel, false),
        .set_parent => |set| {
            const parent_id: ?XdgShell.WindowId = if (set.parent) |object_id| parent: {
                const parent = toplevel.adapter.findToplevel(toplevel.surface.client, object_id) orelse {
                    toplevel.surface.client.postProtocolError(
                        &resource.runtime,
                        @intCast(core.xdg_toplevel.@"error".invalid_parent),
                        "invalid xdg_toplevel parent",
                    );
                    return;
                };
                break :parent parent.core_id;
            } else null;
            shell.setParent(toplevel.core_id, parent_id) catch {
                toplevel.surface.client.postProtocolError(
                    &resource.runtime,
                    @intCast(core.xdg_toplevel.@"error".invalid_parent),
                    "invalid xdg_toplevel parent",
                );
            };
        },
        .set_title => |set| shell.setTitle(toplevel.core_id, set.title) catch {
            toplevel.surface.client.postOutOfMemory(&resource.runtime, "storing xdg_toplevel title");
        },
        .set_app_id => |set| shell.setAppId(toplevel.core_id, set.app_id) catch {
            toplevel.surface.client.postOutOfMemory(&resource.runtime, "storing xdg_toplevel app_id");
        },
        .set_max_size => |set| shell.setPendingMaxSize(toplevel.core_id, .{
            .width = set.width,
            .height = set.height,
        }),
        .set_min_size => |set| shell.setPendingMinSize(toplevel.core_id, .{
            .width = set.width,
            .height = set.height,
        }),
        .resize => |set| if (!validResizeEdge(set.edges)) {
            toplevel.surface.client.postProtocolError(
                &resource.runtime,
                @intCast(core.xdg_toplevel.@"error".invalid_resize_edge),
                "invalid xdg_toplevel resize edge",
            );
        },
        .show_window_menu,
        .move,
        => {},
        .set_maximized => forwardStateRequest(toplevel, .maximize),
        .unset_maximized => forwardStateRequest(toplevel, .unmaximize),
        .set_fullscreen => |set| {
            const output: ?OutputLayout.Id = if (set.output) |object_id|
                (toplevel.adapter.outputs orelse return).outputIdForResource(
                    toplevel.surface.client,
                    object_id,
                ) orelse return
            else
                null;
            shell.requestFullscreen(toplevel.core_id, true, output);
            if ((shell.windowInfo(toplevel.core_id) orelse return).ready)
                shell.requestWindow(toplevel.core_id, .{ .fullscreen = output });
        },
        .unset_fullscreen => forwardStateRequest(toplevel, .exit_fullscreen),
        .set_minimized => forwardStateRequest(toplevel, .minimize),
    }
}

fn forwardStateRequest(toplevel: *Toplevel, request: XdgShell.WindowRequest) void {
    const shell = toplevel.adapter.core_shell;
    switch (request) {
        .maximize => shell.requestMaximized(toplevel.core_id, true),
        .unmaximize => shell.requestMaximized(toplevel.core_id, false),
        .exit_fullscreen => shell.requestFullscreen(toplevel.core_id, false, null),
        .minimize => shell.requestMinimized(toplevel.core_id, true),
        else => unreachable,
    }
    if ((shell.windowInfo(toplevel.core_id) orelse return).ready)
        shell.requestWindow(toplevel.core_id, request);
}

fn createPopup(
    self: *WayringXdgShell,
    surface: *Surface,
    object_id: u32,
    parent_object_id: ?u32,
    positioner_object_id: u32,
) !void {
    if (surface.active_role != null) {
        surface.client.postProtocolError(
            &surface.resource.runtime,
            @intCast(core.xdg_surface.@"error".already_constructed),
            "xdg_surface already has a role",
        );
        return;
    }
    if (self.compositor.permanentXdgRole(surface.surface_id)) |role| if (role != .popup) {
        surface.client.postProtocolError(
            &surface.resource.runtime,
            @intCast(core.xdg_surface.@"error".already_constructed),
            "wl_surface has a different permanent XDG role",
        );
        return;
    };
    const parent: ?*Surface = if (parent_object_id) |id| self.findSurface(surface.client, id) orelse {
        self.postManagerError(surface.manager, .invalid_popup_parent, "invalid xdg_popup parent");
        return;
    } else null;
    if (parent == surface) {
        self.postManagerError(surface.manager, .invalid_popup_parent, "invalid xdg_popup parent");
        return;
    }
    const positioner = self.findPositioner(surface.client, positioner_object_id) orelse {
        self.postManagerError(surface.manager, .invalid_positioner, "invalid xdg_positioner");
        return;
    };
    const snapshot = self.copyPositioner(positioner, parent);
    if (!snapshot.rules.complete()) {
        self.postManagerError(surface.manager, .invalid_positioner, "incomplete xdg_positioner");
        return;
    }
    self.core_shell.validatePopupParent(
        surface.core_id,
        if (parent) |value| value.core_id else null,
    ) catch |err| {
        self.postPopupValidationError(surface.manager, err);
        return;
    };

    try self.popups.ensureUnusedCapacity(self.allocator, 1);
    const generation = try self.issueGeneration();
    const popup = try self.allocator.create(Popup);
    errdefer self.allocator.destroy(popup);
    popup.* = .{
        .adapter = self,
        .surface = surface,
        .generation = generation,
        .resource = .init(
            self.allocator,
            object_id,
            @min(surface.resource.version(), core.xdg_popup.interface.version),
            .client,
            surface.client.ownerHooks(),
        ),
        .core_id = undefined,
        .parent_core_id = if (parent) |value| value.core_id else null,
        .positioner = snapshot,
    };
    popup.resource.setHandler(Popup, popup, handlePopup, null) catch unreachable;
    surface.client.materialize(&popup.resource.runtime) catch unreachable;
    var resource_owned = true;
    errdefer if (resource_owned) {
        popup.resource.destroy();
        popup.resource.deinit();
    };

    popup.core_id = self.core_shell.createPopup(
        surface.core_id,
        if (parent) |value| value.core_id else null,
        snapshot.rules,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.PopupOrderExhausted => return error.PopupOrderExhausted,
        else => {
            // Validation above makes this defensive branch unreachable, but a
            // future neutral validation rule must not strand a materialized
            // generated resource outside the adapter's owned list.
            popup.resource.destroy();
            popup.resource.deinit();
            self.allocator.destroy(popup);
            self.postPopupValidationError(surface.manager, @errorCast(err));
            return;
        },
    };
    var core_owned = true;
    errdefer if (core_owned) self.core_shell.destroyPopup(popup.core_id);
    _ = self.compositor.assignXdgRole(surface.reservation, .popup) catch unreachable;

    surface.active_role = .{ .popup = popup };
    self.popups.appendAssumeCapacity(popup);
    core_owned = false;
    resource_owned = false;
}

fn handlePopup(
    _: *core.xdg_popup.Resource,
    request: core.xdg_popup.Request,
    popup: *Popup,
) !void {
    switch (request) {
        .destroy => popup.adapter.destroyPopup(popup, false),
        .grab => {},
        .reposition => |set| {
            const positioner = popup.adapter.findPositioner(
                popup.surface.client,
                set.positioner,
            ) orelse {
                popup.adapter.postManagerError(
                    popup.surface.manager,
                    .invalid_positioner,
                    "invalid xdg_positioner",
                );
                return;
            };
            const parent = popup.adapter.popupParentSurface(popup);
            const snapshot = popup.adapter.copyPositioner(positioner, parent);
            if (!snapshot.rules.complete()) {
                popup.adapter.postManagerError(
                    popup.surface.manager,
                    .invalid_positioner,
                    "incomplete xdg_positioner",
                );
                return;
            }
            // Wave 6 owns popup placement/reposition policy. Retain only the
            // copied wire intent and opaque client token here.
            popup.reposition = .{ .positioner = snapshot, .token = set.token };
        },
    }
}

fn surfaceEndpoint(surface: *Surface) XdgShell.SurfaceEndpoint {
    return .{
        .context = surface,
        .configure_toplevel = configureToplevel,
        .configure_popup = configurePopup,
        .close = closeToplevel,
        .popup_done = popupDone,
        .report_failure = reportFailure,
    };
}

fn commitHandler(surface: *Surface) WayringCompositor.XdgCommitHandler {
    return .{
        .context = surface,
        .prepare = prepareCommit,
        .abort_prepare = abortPreparedCommit,
        .validate = validateCommit,
        .pre_unmap = preUnmap,
        .post_apply = postApply,
        .surface_destroyed = underlyingSurfaceDestroyed,
    };
}

fn prepareCommit(
    context: *anyopaque,
    commit: WayringCompositor.XdgDirectCommit,
) WayringCompositor.XdgCommitDecision {
    const surface: *Surface = @ptrCast(@alignCast(context));
    if (surface.prepared_commit != null or surface.prepared_events != null) {
        surface.client.postImplementationError(&surface.resource.runtime, "nested XDG commit preparation");
        return .reject;
    }
    surface.prepared_commit = commit;
    if (surface.active_role == null or commit.next_size != null or surface.initial_configure_sent) {
        return .accept;
    }
    surface.configures.ensureUnusedCapacity(surface.adapter.allocator, 1) catch {
        surface.prepared_commit = null;
        surface.client.postOutOfMemory(&surface.resource.runtime, "reserving XDG configure snapshot");
        return .reject;
    };
    surface.prepared_events = surface.client.prepareEvents(prepared_configure_bytes) catch |err| {
        surface.prepared_commit = null;
        eventFailure(surface.client, &surface.resource.runtime, err, "reserving XDG configure events");
        return .reject;
    };
    return .accept;
}

fn abortPreparedCommit(context: *anyopaque, _: WayringCompositor.SurfaceId) void {
    const surface: *Surface = @ptrCast(@alignCast(context));
    if (surface.prepared_events) |prepared| surface.client.cancelPreparedEvents(prepared);
    surface.prepared_events = null;
    surface.prepared_commit = null;
}

fn validateCommit(
    context: *anyopaque,
    commit: WayringCompositor.XdgDirectCommit,
) WayringCompositor.XdgCommitDecision {
    const surface: *Surface = @ptrCast(@alignCast(context));
    std.debug.assert(surface.prepared_commit != null);
    const role = surface.adapter.core_shell.validateCommit(surface.core_id) catch |err| switch (err) {
        error.InvalidSurface => {
            surface.client.postImplementationError(
                &surface.resource.runtime,
                "neutral XDG surface disappeared during commit validation",
            );
            return .reject;
        },
        error.RoleMissing => {
            surface.client.postProtocolError(
                &surface.resource.runtime,
                @intCast(core.xdg_surface.@"error".not_constructed),
                "xdg_surface committed before role creation",
            );
            return .reject;
        },
        error.InvalidSizeHints => {
            const toplevel = switch (surface.active_role orelse return .reject) {
                .toplevel => |value| value,
                .popup => return .reject,
            };
            surface.client.postProtocolError(
                &toplevel.resource.runtime,
                @intCast(core.xdg_toplevel.@"error".invalid_size),
                "invalid minimum or maximum window size",
            );
            return .reject;
        },
        error.PopupUnattached => {
            surface.adapter.postManagerError(
                surface.manager,
                .invalid_popup_parent,
                "unattached xdg_popup committed before parent attachment",
            );
            return .reject;
        },
    };
    if (commit.next_size != null and !surface.adapter.core_shell.surfaceConfigured(surface.core_id) and
        surface.accepted_configure == null)
    {
        surface.client.postProtocolError(
            &surface.resource.runtime,
            @intCast(core.xdg_surface.@"error".unconfigured_buffer),
            "buffer committed before the initial configure was acknowledged",
        );
        return .reject;
    }
    _ = role;
    return .accept;
}

fn preUnmap(context: *anyopaque, _: WayringCompositor.SurfaceId) void {
    const surface: *Surface = @ptrCast(@alignCast(context));
    const commit = surface.prepared_commit orelse unreachable;
    surface.adapter.core_shell.beforeAppliedCommit(
        surface.core_id,
        commit.current_size != null,
        commit.next_size != null,
    );
}

fn postApply(context: *anyopaque, _: WayringCompositor.SurfaceId) void {
    const surface: *Surface = @ptrCast(@alignCast(context));
    const commit = surface.prepared_commit orelse unreachable;
    if (surface.pending_geometry_changed) {
        surface.adapter.core_shell.commitGeometry(
            surface.core_id,
            surface.pending_geometry orelse unreachable,
        );
        surface.pending_geometry_changed = false;
    }
    const applies_buffer = commit.attachment_changed and commit.next_size != null;
    const accepted: ?XdgShell.AcceptedConfigure = if (applies_buffer)
        if (surface.accepted_configure) |configure| configure.accepted else null
    else
        null;
    const dismissed_popup = switch (surface.active_role orelse {
        finishPreparedCommit(surface);
        return;
    }) {
        .toplevel => false,
        .popup => |popup| surface.adapter.core_shell.popupDismissed(popup.core_id),
    };
    if (commit.next_size != null) switch (surface.active_role.?) {
        .toplevel => |toplevel| {
            const info = surface.adapter.core_shell.windowInfo(toplevel.core_id) orelse {
                finishPreparedCommit(surface);
                return;
            };
            const mapping_configured = accepted != null or
                surface.adapter.core_shell.surfaceConfigured(surface.core_id);
            if (mapping_configured and !info.scene_presentation_enabled) {
                surface.adapter.core_shell.setWindowScenePresentationEnabled(
                    toplevel.core_id,
                    true,
                ) catch {
                    surface.client.postOutOfMemory(
                        &surface.resource.runtime,
                        "enabling generated XDG toplevel presentation",
                    );
                    finishPreparedCommit(surface);
                    return;
                };
            }
        },
        .popup => {},
    };
    surface.adapter.core_shell.afterAppliedCommit(
        surface.core_id,
        commit.current_size != null,
        commit.next_size != null,
        accepted,
    ) catch |err| {
        surface.adapter.postManagerError(surface.manager, .invalid_popup_parent, switch (err) {
            error.PopupParentNotMapped => "xdg_popup parent is not mapped",
            error.InvalidPopupParent => "invalid xdg_popup parent",
        });
        finishPreparedCommit(surface);
        return;
    };
    if (applies_buffer and !dismissed_popup) surface.accepted_configure = null;
    if (commit.current_size != null and commit.next_size == null and !dismissed_popup) {
        resetWireState(surface);
    }
    finishPreparedCommit(surface);
}

fn finishPreparedCommit(surface: *Surface) void {
    if (surface.prepared_events) |prepared| surface.client.cancelPreparedEvents(prepared);
    surface.prepared_events = null;
    surface.prepared_commit = null;
}

fn underlyingSurfaceDestroyed(context: *anyopaque, _: WayringCompositor.SurfaceId) void {
    const surface: *Surface = @ptrCast(@alignCast(context));
    surface.adapter.core_shell.surfaceDestroyed(surface.core_id);
    surface.adapter.destroySurface(surface, true);
}

fn configureToplevel(
    context: *anyopaque,
    dimensions: XdgShell.Dimensions,
    configuration: XdgShell.ToplevelConfigure,
    token: XdgShell.ConfigureToken,
) error{OutOfMemory}!void {
    const surface: *Surface = @ptrCast(@alignCast(context));
    const toplevel = switch (surface.active_role orelse return error.OutOfMemory) {
        .toplevel => |value| value,
        .popup => return error.OutOfMemory,
    };
    try prepareEndpointConfigure(surface);
    const serial = surface.adapter.protocol_server.nextSerial() catch {
        failPreparedConfigure(surface, "generated XDG wire serial exhausted");
        return error.OutOfMemory;
    };

    var state_values: [13]u32 = undefined;
    const states = toplevelStates(configuration, toplevel.resource.version(), &state_values);
    const role_values = [_]wire.Value{
        .{ .int = dimensions.width },
        .{ .int = dimensions.height },
        .{ .array = std.mem.sliceAsBytes(states) },
    };
    const surface_values = [_]wire.Value{.{ .uint = serial }};
    const events = [_]server.Client.PreparedEvent{
        .{
            .resource = &toplevel.resource.runtime,
            .opcode = 0,
            .descriptor = &core.xdg_toplevel.event_messages[0],
            .values = &role_values,
        },
        .{
            .resource = &surface.resource.runtime,
            .opcode = 0,
            .descriptor = &core.xdg_surface.event_messages[0],
            .values = &surface_values,
        },
    };
    emitConfigure(surface, &events, .{
        .serial = serial,
        .accepted = .{ .token = token },
    }) catch return error.OutOfMemory;
}

fn configurePopup(
    context: *anyopaque,
    configure: XdgShell.PopupConfigure,
    token: XdgShell.ConfigureToken,
) error{OutOfMemory}!void {
    const surface: *Surface = @ptrCast(@alignCast(context));
    const popup = switch (surface.active_role orelse return error.OutOfMemory) {
        .popup => |value| value,
        .toplevel => return error.OutOfMemory,
    };
    try prepareEndpointConfigure(surface);
    const serial = surface.adapter.protocol_server.nextSerial() catch {
        failPreparedConfigure(surface, "generated XDG wire serial exhausted");
        return error.OutOfMemory;
    };

    const reposition_values = [_]wire.Value{.{ .uint = if (popup.reposition) |value| value.token else 0 }};
    const role_values = [_]wire.Value{
        .{ .int = configure.placement.position.x },
        .{ .int = configure.placement.position.y },
        .{ .int = configure.placement.dimensions.width },
        .{ .int = configure.placement.dimensions.height },
    };
    const surface_values = [_]wire.Value{.{ .uint = serial }};
    var events: [3]server.Client.PreparedEvent = undefined;
    var event_count: usize = 0;
    if (popup.reposition != null and popup.resource.version() >= 3) {
        events[event_count] = .{
            .resource = &popup.resource.runtime,
            .opcode = 2,
            .descriptor = &core.xdg_popup.event_messages[2],
            .values = &reposition_values,
        };
        event_count += 1;
    }
    events[event_count] = .{
        .resource = &popup.resource.runtime,
        .opcode = 0,
        .descriptor = &core.xdg_popup.event_messages[0],
        .values = &role_values,
    };
    event_count += 1;
    events[event_count] = .{
        .resource = &surface.resource.runtime,
        .opcode = 0,
        .descriptor = &core.xdg_surface.event_messages[0],
        .values = &surface_values,
    };
    event_count += 1;
    emitConfigure(surface, events[0..event_count], .{
        .serial = serial,
        .accepted = .{ .token = token, .popup = configure },
    }) catch return error.OutOfMemory;
    popup.reposition = null;
}

fn prepareEndpointConfigure(surface: *Surface) error{OutOfMemory}!void {
    if (surface.prepared_events != null) {
        std.debug.assert(surface.configures.capacity - surface.configures.items.len >= 1);
        return;
    }
    surface.configures.ensureUnusedCapacity(surface.adapter.allocator, 1) catch {
        surface.client.postOutOfMemory(&surface.resource.runtime, "reserving XDG configure snapshot");
        return error.OutOfMemory;
    };
    surface.prepared_events = surface.client.prepareEvents(prepared_configure_bytes) catch |err| {
        eventFailure(surface.client, &surface.resource.runtime, err, "reserving XDG configure events");
        return error.OutOfMemory;
    };
}

fn emitConfigure(
    surface: *Surface,
    events: []const server.Client.PreparedEvent,
    configure: Configure,
) error{OutOfMemory}!void {
    const prepared = surface.prepared_events.?;
    surface.client.emitPreparedEvents(prepared, events) catch |err| {
        surface.client.cancelPreparedEvents(prepared);
        surface.prepared_events = null;
        eventFailure(surface.client, &surface.resource.runtime, err, "publishing atomic XDG configure");
        return error.OutOfMemory;
    };
    surface.prepared_events = null;
    surface.configures.appendAssumeCapacity(configure);
    surface.initial_configure_sent = true;
}

fn failPreparedConfigure(surface: *Surface, detail: []const u8) void {
    if (surface.prepared_events) |prepared| surface.client.cancelPreparedEvents(prepared);
    surface.prepared_events = null;
    surface.client.postImplementationError(&surface.resource.runtime, detail);
}

fn closeToplevel(context: *anyopaque) void {
    const surface: *Surface = @ptrCast(@alignCast(context));
    const toplevel = switch (surface.active_role orelse return) {
        .toplevel => |value| value,
        .popup => return,
    };
    core.xdg_toplevel.@"send:close"(&toplevel.resource) catch |err|
        eventFailure(surface.client, &toplevel.resource.runtime, err, "queueing xdg_toplevel.close");
}

fn popupDone(context: *anyopaque) void {
    const surface: *Surface = @ptrCast(@alignCast(context));
    const popup = switch (surface.active_role orelse return) {
        .popup => |value| value,
        .toplevel => return,
    };
    core.xdg_popup.@"send:popup_done"(&popup.resource) catch |err|
        eventFailure(surface.client, &popup.resource.runtime, err, "queueing xdg_popup.popup_done");
}

fn reportFailure(context: *anyopaque, failure: XdgShell.EndpointFailure) void {
    const surface: *Surface = @ptrCast(@alignCast(context));
    switch (failure) {
        .no_memory => surface.client.postOutOfMemory(&surface.resource.runtime, "XDG semantic configure failed"),
        .invalid_positioner => surface.adapter.postManagerError(
            surface.manager,
            .invalid_positioner,
            "invalid xdg_popup positioner",
        ),
    }
}

fn ackConfigure(self: *WayringXdgShell, surface: *Surface, serial: u32) void {
    const index = for (surface.configures.items, 0..) |configure, configure_index| {
        if (configure.serial == serial) break configure_index;
    } else {
        surface.client.postProtocolError(
            &surface.resource.runtime,
            @intCast(core.xdg_surface.@"error".invalid_serial),
            "unknown xdg_surface configure serial",
        );
        return;
    };
    const accepted = surface.configures.items[index];
    const consumed = index + 1;
    std.mem.copyForwards(
        Configure,
        surface.configures.items[0 .. surface.configures.items.len - consumed],
        surface.configures.items[consumed..],
    );
    surface.configures.items.len -= consumed;
    surface.accepted_configure = accepted;
    _ = self;
}

fn resetWireState(surface: *Surface) void {
    surface.initial_configure_sent = false;
    surface.accepted_configure = null;
    surface.configures.clearRetainingCapacity();
    surface.pending_geometry = null;
    surface.pending_geometry_changed = false;
}

fn destroyPopup(self: *WayringXdgShell, popup: *Popup, surface_gone: bool) void {
    const surface = popup.surface;
    std.debug.assert(surface.active_role != null and surface.active_role.? == .popup and
        surface.active_role.?.popup == popup);
    surface.active_role = null;
    self.core_shell.destroyPopup(popup.core_id);
    if (!surface_gone) self.compositor.detachXdgRole(surface.reservation, .popup) catch unreachable;
    removePointer(Popup, &self.popups, popup);
    popup.resource.destroy();
    popup.resource.deinit();
    self.allocator.destroy(popup);
    resetWireState(surface);
}

fn destroyToplevel(self: *WayringXdgShell, toplevel: *Toplevel, surface_gone: bool) void {
    const surface = toplevel.surface;
    std.debug.assert(surface.active_role != null and surface.active_role.? == .toplevel and
        surface.active_role.?.toplevel == toplevel);
    surface.active_role = null;
    self.core_shell.destroyToplevel(toplevel.core_id);
    if (!surface_gone) self.compositor.detachXdgRole(surface.reservation, .toplevel) catch unreachable;
    removePointer(Toplevel, &self.toplevels, toplevel);
    toplevel.resource.destroy();
    toplevel.resource.deinit();
    self.allocator.destroy(toplevel);
    resetWireState(surface);
}

fn destroySurface(self: *WayringXdgShell, surface: *Surface, surface_gone: bool) void {
    if (surface.prepared_events) |prepared| surface.client.cancelPreparedEvents(prepared);
    surface.prepared_events = null;
    surface.prepared_commit = null;
    if (surface.active_role) |role| switch (role) {
        .popup => |popup| self.destroyPopup(popup, surface_gone),
        .toplevel => |toplevel| self.destroyToplevel(toplevel, surface_gone),
    };
    self.core_shell.removeSurface(surface.core_id);
    if (!surface_gone) self.compositor.releaseXdgRoot(surface.reservation) catch unreachable;
    std.debug.assert(surface.manager.surface_count > 0);
    surface.manager.surface_count -= 1;
    removePointer(Surface, &self.surfaces, surface);
    surface.configures.deinit(self.allocator);
    surface.resource.destroy();
    surface.resource.deinit();
    self.allocator.destroy(surface);
}

fn destroyPositioner(self: *WayringXdgShell, positioner: *Positioner) void {
    removePointer(Positioner, &self.positioners, positioner);
    positioner.resource.destroy();
    positioner.resource.deinit();
    self.allocator.destroy(positioner);
}

fn destroyManager(self: *WayringXdgShell, manager: *Manager) void {
    std.debug.assert(manager.surface_count == 0);
    removePointer(Manager, &self.managers, manager);
    manager.resource.destroy();
    manager.resource.deinit();
    self.allocator.destroy(manager);
}

fn requireRole(surface: *Surface) bool {
    if (surface.active_role != null) return true;
    surface.client.postProtocolError(
        &surface.resource.runtime,
        @intCast(core.xdg_surface.@"error".not_constructed),
        "xdg_surface has no role",
    );
    return false;
}

fn findSurface(self: *WayringXdgShell, client: *server.Client, object_id: u32) ?*Surface {
    const resource = client.lookup(object_id) orelse return null;
    for (self.surfaces.items) |surface| if (surface.client == client and
        &surface.resource.runtime == resource and surface.resource.state() == .live) return surface;
    return null;
}

fn findToplevel(self: *WayringXdgShell, client: *server.Client, object_id: u32) ?*Toplevel {
    const resource = client.lookup(object_id) orelse return null;
    for (self.toplevels.items) |toplevel| if (toplevel.surface.client == client and
        &toplevel.resource.runtime == resource and toplevel.resource.state() == .live) return toplevel;
    return null;
}

fn findPositioner(self: *WayringXdgShell, client: *server.Client, object_id: u32) ?*Positioner {
    const resource = client.lookup(object_id) orelse return null;
    for (self.positioners.items) |positioner| if (positioner.client == client and
        &positioner.resource.runtime == resource and positioner.resource.state() == .live) return positioner;
    return null;
}

fn popupParentSurface(self: *WayringXdgShell, popup: *Popup) ?*Surface {
    const parent_id = popup.parent_core_id orelse return null;
    for (self.surfaces.items) |candidate| {
        if (std.meta.eql(candidate.core_id, parent_id)) return candidate;
    }
    return null;
}

fn copyPositioner(
    self: *WayringXdgShell,
    positioner: *const Positioner,
    parent: ?*Surface,
) PositionerSnapshot {
    return .{
        .rules = positioner.rules,
        .parent_configure = if (parent) |parent_surface|
            self.resolveConfigureToken(parent_surface, positioner.parent_configure_serial)
        else
            null,
    };
}

fn resolveConfigureToken(
    self: *WayringXdgShell,
    surface: *const Surface,
    wire_serial: ?u32,
) ?XdgShell.ConfigureToken {
    const serial = wire_serial orelse return null;
    if (surface.accepted_configure) |configure| if (configure.serial == serial) {
        return configure.accepted.token;
    };
    for (surface.configures.items) |configure| if (configure.serial == serial) {
        return configure.accepted.token;
    };
    _ = self;
    return null;
}

const ManagerError = enum { invalid_popup_parent, invalid_positioner };

fn postManagerError(
    self: *WayringXdgShell,
    manager: *Manager,
    code: ManagerError,
    detail: []const u8,
) void {
    manager.client.postProtocolError(&manager.resource.runtime, switch (code) {
        .invalid_popup_parent => @intCast(core.xdg_wm_base.@"error".invalid_popup_parent),
        .invalid_positioner => @intCast(core.xdg_wm_base.@"error".invalid_positioner),
    }, detail);
    _ = self;
}

fn postPopupValidationError(
    self: *WayringXdgShell,
    manager: *Manager,
    err: XdgShell.PopupValidationError,
) void {
    switch (err) {
        error.InvalidPositioner => self.postManagerError(manager, .invalid_positioner, "invalid xdg_positioner"),
        error.ParentMissingRole => self.postManagerError(manager, .invalid_popup_parent, "xdg_popup parent has no role"),
        error.ParentUnattached => self.postManagerError(manager, .invalid_popup_parent, "xdg_popup parent is not attached"),
        error.InvalidParent, error.InvalidSurface, error.RoleAssigned => self.postManagerError(manager, .invalid_popup_parent, "invalid xdg_popup parent"),
    }
}

fn decodeAnchor(value: u32) ?XdgShell.Anchor {
    return switch (value) {
        0 => .none,
        1 => .top,
        2 => .bottom,
        3 => .left,
        4 => .right,
        5 => .top_left,
        6 => .bottom_left,
        7 => .top_right,
        8 => .bottom_right,
        else => null,
    };
}

fn validResizeEdge(value: u32) bool {
    return switch (value) {
        0, 1, 2, 4, 5, 6, 8, 9, 10 => true,
        else => false,
    };
}

fn toplevelStates(
    configuration: XdgShell.ToplevelConfigure,
    version: u32,
    values: *[13]u32,
) []const u32 {
    var count: usize = 0;
    if (configuration.maximized) appendState(values, &count, core.xdg_toplevel.state.maximized);
    if (configuration.fullscreen) appendState(values, &count, core.xdg_toplevel.state.fullscreen);
    if (configuration.resizing) appendState(values, &count, core.xdg_toplevel.state.resizing);
    if (configuration.activated) appendState(values, &count, core.xdg_toplevel.state.activated);
    if (version >= 2) {
        if (configuration.tiled.left) appendState(values, &count, core.xdg_toplevel.state.tiled_left);
        if (configuration.tiled.right) appendState(values, &count, core.xdg_toplevel.state.tiled_right);
        if (configuration.tiled.top) appendState(values, &count, core.xdg_toplevel.state.tiled_top);
        if (configuration.tiled.bottom) appendState(values, &count, core.xdg_toplevel.state.tiled_bottom);
    }
    if (version >= 6 and configuration.suspended)
        appendState(values, &count, core.xdg_toplevel.state.suspended);
    if (version >= 7) {
        if (configuration.constrained.left) appendState(values, &count, core.xdg_toplevel.state.constrained_left);
        if (configuration.constrained.right) appendState(values, &count, core.xdg_toplevel.state.constrained_right);
        if (configuration.constrained.top) appendState(values, &count, core.xdg_toplevel.state.constrained_top);
        if (configuration.constrained.bottom) appendState(values, &count, core.xdg_toplevel.state.constrained_bottom);
    }
    return values[0..count];
}

fn appendState(values: *[13]u32, count: *usize, value: i64) void {
    values[count.*] = @intCast(value);
    count.* += 1;
}

fn eventFailure(
    client: *server.Client,
    resource: *server.Resource,
    err: anyerror,
    detail: []const u8,
) void {
    switch (err) {
        error.OutOfMemory => client.postOutOfMemory(resource, detail),
        error.ClientFatal, error.OutputSealed => {},
        else => client.postImplementationError(resource, detail),
    }
}

fn removePointer(comptime T: type, items: *std.ArrayList(*T), value: *T) void {
    for (items.items, 0..) |candidate, index| {
        if (candidate != value) continue;
        _ = items.orderedRemove(index);
        return;
    }
    unreachable;
}

const TestHarness = struct {
    host: server.Server,
    surface_registry: SurfaceRegistry,
    scene: Scene,
    client_registry: ClientRegistry,
    generated_clients: WayringClients,
    core_shell: XdgShell,
    compositor: WayringCompositor,
    adapter: WayringXdgShell,
    managed: *server.CoreClient,

    fn init(self: *@This()) !void {
        self.host = .init(std.testing.allocator);
        self.surface_registry = .init(std.testing.allocator);
        self.scene.init(std.testing.allocator);
        self.client_registry = .init(std.testing.allocator);
        self.generated_clients.init(std.testing.allocator, &self.client_registry);
        self.core_shell = XdgShell.init(
            std.testing.allocator,
            &self.scene,
            .{
                .context = self,
                .subtree_geometry = subtreeGeometry,
                .surface_size = surfaceSize,
                .popup_output_bounds = popupOutputBounds,
            },
            .{ .index = 0, .generation = 1 },
        );
        try self.compositor.init(
            std.testing.allocator,
            &self.host,
            &self.surface_registry,
            null,
        );
        self.managed = try server.CoreClient.create(std.testing.allocator, &self.host, .{});
        _ = try self.generated_clients.register(self.client());
        self.adapter.init(
            std.testing.allocator,
            &self.host,
            &self.core_shell,
            &self.generated_clients,
            &self.compositor,
            null,
        );
    }

    fn deinit(self: *@This()) void {
        self.adapter.destroyClientResources(self.client());
        self.compositor.destroyClientResources(self.client());
        self.generated_clients.unregister(self.client());
        self.managed.destroy();
        self.adapter.deinit();
        self.compositor.deinit();
        self.core_shell.deinit();
        self.generated_clients.deinit();
        self.client_registry.deinit();
        self.scene.deinit();
        self.surface_registry.deinit();
        self.host.deinit();
    }

    fn client(self: *@This()) *server.Client {
        return self.managed.client();
    }

    fn createSurface(self: *@This()) !void {
        try sendTest(
            self.client(),
            1,
            1,
            &core.wl_display.request_messages[1],
            &.{.{ .new_id = .{ .typed = 2 } }},
        );
        const globals = try drainTest(self.client());
        std.testing.allocator.free(globals);
        const compositor_name = globalName(&self.host, "wl_compositor") orelse
            return error.MissingCompositor;
        try sendTest(self.client(), 2, 0, &core.wl_registry.request_messages[0], &.{
            .{ .uint = compositor_name },
            .{ .new_id = .{ .generic = .{
                .interface = "wl_compositor",
                .version = 1,
                .id = 3,
            } } },
        });
        try sendTest(
            self.client(),
            3,
            0,
            &core.wl_compositor.request_messages[0],
            &.{.{ .new_id = .{ .typed = 4 } }},
        );
    }

    fn installManager(self: *@This(), version: u32) !void {
        try self.adapter.installUnpublishedForTest(self.client(), 5, version);
    }

    fn createToplevel(self: *@This()) !void {
        try sendTest(self.client(), 5, 2, &core.xdg_wm_base.request_messages[2], &.{
            .{ .new_id = .{ .typed = 6 } }, .{ .object = 4 },
        });
        try sendTest(
            self.client(),
            6,
            1,
            &core.xdg_surface.request_messages[1],
            &.{.{ .new_id = .{ .typed = 7 } }},
        );
    }

    fn bindShm(self: *@This(), object_id: u32) !void {
        const shm_name = globalName(&self.host, "wl_shm") orelse return error.MissingShm;
        try sendTest(self.client(), 2, 0, &core.wl_registry.request_messages[0], &.{
            .{ .uint = shm_name },
            .{ .new_id = .{ .generic = .{
                .interface = "wl_shm",
                .version = 1,
                .id = object_id,
            } } },
        });
        const formats = try drainTest(self.client());
        std.testing.allocator.free(formats);
    }

    fn subtreeGeometry(context: *anyopaque, id: SurfaceRegistry.Id) ?XdgShell.Geometry {
        const self: *TestHarness = @ptrCast(@alignCast(context));
        const state = self.surface_registry.renderState(id) orelse return null;
        return .{
            .x = 0,
            .y = 0,
            .width = @intCast(state.logical_size.width),
            .height = @intCast(state.logical_size.height),
        };
    }

    fn surfaceSize(context: *anyopaque, id: SurfaceRegistry.Id) ?@import("../render/types.zig").Size {
        const self: *TestHarness = @ptrCast(@alignCast(context));
        return (self.surface_registry.renderState(id) orelse return null).logical_size;
    }

    fn popupOutputBounds(
        _: *anyopaque,
        _: Scene.Position,
        _: @import("../render/types.zig").Size,
        _: OutputLayout.Id,
    ) ?@import("../render/types.zig").Rect {
        return .{ .x = 0, .y = 0, .width = 1024, .height = 768 };
    }
};

fn globalCount(host: *const server.Server) usize {
    var count: usize = 0;
    var iterator = host.iterator();
    while (iterator.next() != null) count += 1;
    return count;
}

fn globalName(host: *const server.Server, name: []const u8) ?u32 {
    var iterator = host.iterator();
    while (iterator.next()) |global| {
        if (std.mem.eql(u8, global.interface().name, name)) return global.name();
    }
    return null;
}

fn encodeTest(
    object_id: u32,
    opcode: u16,
    descriptor: *const wire.MessageDescriptor,
    values: []const wire.Value,
) ![]u8 {
    var output: wire.Output = .init(std.testing.allocator);
    defer output.deinit();
    try output.enqueue(object_id, opcode, descriptor, values);
    const batch = (try output.beginSend()).?;
    const bytes = try std.testing.allocator.dupe(u8, batch.bytes);
    try output.completeSend(batch.token, batch.bytes.len);
    return bytes;
}

fn sendTest(
    client: *server.Client,
    object_id: u32,
    opcode: u16,
    descriptor: *const wire.MessageDescriptor,
    values: []const wire.Value,
) !void {
    const bytes = try encodeTest(object_id, opcode, descriptor, values);
    defer std.testing.allocator.free(bytes);
    try client.receive(bytes, &.{});
    try client.dispatch();
}

fn sendTestWithFds(
    client: *server.Client,
    object_id: u32,
    opcode: u16,
    descriptor: *const wire.MessageDescriptor,
    values: []const wire.Value,
) !void {
    var output: wire.Output = .init(std.testing.allocator);
    defer output.deinit();
    try output.enqueue(object_id, opcode, descriptor, values);
    const batch = (try output.beginSend()).?;
    var receiver_fds: std.ArrayList(wire.FileDescriptor) = .empty;
    defer receiver_fds.deinit(std.testing.allocator);
    errdefer {
        for (receiver_fds.items) |fd| _ = std.c.close(fd);
    }
    try receiver_fds.ensureUnusedCapacity(std.testing.allocator, batch.fds.len);
    for (batch.fds) |fd| {
        const duplicate = std.c.fcntl(fd, std.c.F.DUPFD_CLOEXEC, @as(c_int, 0));
        if (duplicate < 0) return error.Unexpected;
        receiver_fds.appendAssumeCapacity(duplicate);
    }
    try client.receive(batch.bytes, receiver_fds.items);
    receiver_fds.clearRetainingCapacity();
    try output.completeSend(batch.token, batch.bytes.len);
    try client.dispatch();
}

fn drainTest(client: *server.Client) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(std.testing.allocator);
    while (try client.beginSend()) |batch| {
        try bytes.appendSlice(std.testing.allocator, batch.bytes);
        try client.completeSend(batch.token, batch.bytes.len);
    }
    return bytes.toOwnedSlice(std.testing.allocator);
}

fn testWord(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .native);
}

fn createTestBuffer(harness: *TestHarness) !void {
    try createTestBufferAt(harness, 8, 9, 10);
}

fn createTestBufferAt(
    harness: *TestHarness,
    shm_id: u32,
    pool_id: u32,
    buffer_id: u32,
) !void {
    try harness.bindShm(shm_id);
    const pixels = [_]u32{0xff11_2233};
    const bytes = std.mem.sliceAsBytes(&pixels);
    const fd = try std.posix.memfd_create("keywork-xdg-wave2", std.os.linux.MFD.CLOEXEC);
    defer _ = std.c.close(fd);
    if (std.os.linux.errno(std.os.linux.ftruncate(fd, @intCast(bytes.len))) != .SUCCESS) {
        return error.Unexpected;
    }
    if (std.c.write(fd, bytes.ptr, bytes.len) != bytes.len) return error.Unexpected;
    try sendTestWithFds(harness.client(), shm_id, 0, &core.wl_shm.request_messages[0], &.{
        .{ .new_id = .{ .typed = pool_id } }, .{ .fd = fd }, .{ .int = @intCast(bytes.len) },
    });
    try sendTest(harness.client(), pool_id, 0, &core.wl_shm_pool.request_messages[0], &.{
        .{ .new_id = .{ .typed = buffer_id } },
        .{ .int = 0 },
        .{ .int = 1 },
        .{ .int = 1 },
        .{ .int = @sizeOf(u32) },
        .{ .uint = @intFromEnum(server.shm.Format.argb8888) },
    });
}

fn attachTestBuffer(client: *server.Client, buffer: ?u32) !void {
    try sendTest(client, 4, 1, &core.wl_surface.request_messages[1], &.{
        .{ .object = buffer }, .{ .int = 0 }, .{ .int = 0 },
    });
}

fn commitTestSurface(client: *server.Client) !void {
    try sendTest(client, 4, 6, &core.wl_surface.request_messages[6], &.{});
}

test "unpublished manager preserves globals and roleless wrappers roll back cleanly" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.createSurface();
    const global_count = globalCount(&harness.host);
    try std.testing.expect(globalName(&harness.host, "xdg_wm_base") == null);

    try harness.installManager(7);
    try std.testing.expectEqual(global_count, globalCount(&harness.host));
    try sendTest(harness.client(), 5, 2, &core.xdg_wm_base.request_messages[2], &.{
        .{ .new_id = .{ .typed = 6 } }, .{ .object = 4 },
    });
    try std.testing.expectEqual(@as(usize, 1), harness.adapter.surfaces.items.len);
    const reservation = harness.adapter.surfaces.items[0].reservation;
    try std.testing.expect(harness.compositor.hasXdgReservation(reservation));
    try std.testing.expect(harness.compositor.permanentXdgRole(reservation.surface) == null);

    try sendTest(harness.client(), 6, 0, &core.xdg_surface.request_messages[0], &.{});
    try std.testing.expectEqual(@as(usize, 0), harness.adapter.surfaces.items.len);
    try std.testing.expect(!harness.compositor.hasXdgReservation(reservation));
    try std.testing.expect(harness.compositor.permanentXdgRole(reservation.surface) == null);
    try sendTest(harness.client(), 5, 0, &core.xdg_wm_base.request_messages[0], &.{});
    try std.testing.expectEqual(@as(usize, 0), harness.adapter.managers.items.len);
    try std.testing.expect(harness.client().fatal() == null);
}

test "manager child guard is exact and forced teardown is child first" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.createSurface();
    try harness.installManager(7);
    try sendTest(harness.client(), 5, 2, &core.xdg_wm_base.request_messages[2], &.{
        .{ .new_id = .{ .typed = 6 } }, .{ .object = 4 },
    });

    try sendTest(harness.client(), 5, 0, &core.xdg_wm_base.request_messages[0], &.{});
    try std.testing.expectEqual(server.Fatal.Kind.protocol, harness.client().fatal().?.kind);
    try std.testing.expectEqual(
        @as(?u32, @intCast(core.xdg_wm_base.@"error".defunct_surfaces)),
        harness.client().fatal().?.protocol_code,
    );
    try std.testing.expectEqual(@as(usize, 1), harness.adapter.managers.items.len);
    try std.testing.expectEqual(@as(usize, 1), harness.adapter.surfaces.items.len);

    harness.adapter.destroyClientResources(harness.client());
    try std.testing.expectEqual(@as(usize, 0), harness.adapter.surfaces.items.len);
    try std.testing.expectEqual(@as(usize, 0), harness.adapter.managers.items.len);
}

test "commit before role construction is rejected without configure publication" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.createSurface();
    try harness.installManager(7);
    try sendTest(harness.client(), 5, 2, &core.xdg_wm_base.request_messages[2], &.{
        .{ .new_id = .{ .typed = 6 } }, .{ .object = 4 },
    });
    const surface = harness.adapter.surfaces.items[0];

    try commitTestSurface(harness.client());
    try std.testing.expectEqual(server.Fatal.Kind.protocol, harness.client().fatal().?.kind);
    try std.testing.expectEqual(
        @as(?u32, @intCast(core.xdg_surface.@"error".not_constructed)),
        harness.client().fatal().?.protocol_code,
    );
    try std.testing.expect(surface.prepared_commit == null);
    try std.testing.expect(surface.prepared_events == null);
    try std.testing.expectEqual(@as(usize, 0), surface.configures.items.len);
}

test "pending and committed roleless buffers both reject XDG reservation" {
    const Case = struct {
        fn run(committed: bool) !void {
            var harness: TestHarness = undefined;
            try harness.init();
            defer harness.deinit();
            try harness.createSurface();
            try createTestBufferAt(&harness, 5, 6, 7);
            try attachTestBuffer(harness.client(), 7);
            if (committed) {
                try commitTestSurface(harness.client());
                const release = try drainTest(harness.client());
                std.testing.allocator.free(release);
            }
            try harness.adapter.installUnpublishedForTest(harness.client(), 8, 7);
            const surface_id = harness.compositor.surfaceId(harness.client(), 4).?;
            try sendTest(harness.client(), 8, 2, &core.xdg_wm_base.request_messages[2], &.{
                .{ .new_id = .{ .typed = 9 } }, .{ .object = 4 },
            });
            try std.testing.expectEqual(server.Fatal.Kind.protocol, harness.client().fatal().?.kind);
            try std.testing.expectEqual(
                @as(?u32, @intCast(core.xdg_wm_base.@"error".invalid_surface_state)),
                harness.client().fatal().?.protocol_code,
            );
            try std.testing.expectEqual(@as(usize, 0), harness.adapter.surfaces.items.len);
            try std.testing.expect(harness.compositor.permanentXdgRole(surface_id) == null);
            try std.testing.expect(!harness.compositor.xdgContentState(surface_id).?.has_pending_attachment == committed);
            try std.testing.expectEqual(committed, harness.compositor.xdgContentState(surface_id).?.has_committed_buffer);
        }
    };

    try Case.run(false);
    try Case.run(true);
}

test "toplevel configure ack map unmap and remap retain exact snapshots" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.createSurface();
    try harness.installManager(7);
    try harness.createToplevel();
    const adapter_surface = harness.adapter.surfaces.items[0];
    const toplevel = harness.adapter.toplevels.items[0];
    try std.testing.expectEqual(WayringCompositor.XdgRole.toplevel, harness.compositor.permanentXdgRole(adapter_surface.surface_id).?);

    _ = try harness.host.nextSerial();
    try commitTestSurface(harness.client());
    const initial = try drainTest(harness.client());
    defer std.testing.allocator.free(initial);
    try std.testing.expectEqual(@as(usize, 32), initial.len);
    try std.testing.expectEqual(@as(u32, 7), testWord(initial, 0));
    try std.testing.expectEqual(@as(u32, 6), testWord(initial, 20));
    const first_serial = testWord(initial, 28);
    try std.testing.expectEqual(@as(u32, 2), first_serial);
    try std.testing.expectEqual(@as(u64, 1), adapter_surface.configures.items[0].accepted.token.sequence);
    try sendTest(harness.client(), 6, 4, &core.xdg_surface.request_messages[4], &.{.{ .uint = first_serial }});
    try std.testing.expect(adapter_surface.accepted_configure != null);

    // A successful commit with no buffer application retains the accepted ack.
    try commitTestSurface(harness.client());
    try std.testing.expect(adapter_surface.accepted_configure != null);
    try createTestBuffer(&harness);
    try attachTestBuffer(harness.client(), 10);
    try commitTestSurface(harness.client());
    try std.testing.expect(adapter_surface.accepted_configure == null);
    try std.testing.expect(harness.core_shell.surfaceConfigured(adapter_surface.core_id));
    try std.testing.expect(harness.core_shell.windowInfo(toplevel.core_id).?.mapped);
    var scene_windows = harness.scene.iterator();
    try std.testing.expect(scene_windows.next().?.window.mapped);
    try std.testing.expect(!harness.core_shell.windowInfo(toplevel.core_id).?.interaction_enabled);
    const first_release = try drainTest(harness.client());
    std.testing.allocator.free(first_release);

    // A later accepted configure also survives a retained-buffer commit and is
    // consumed only when a new attachment is successfully applied.
    _ = try harness.core_shell.configureWindow(toplevel.core_id, .{ .width = 1, .height = 1 });
    const second = try drainTest(harness.client());
    defer std.testing.allocator.free(second);
    const second_serial = testWord(second, second.len - 4);
    try sendTest(harness.client(), 6, 4, &core.xdg_surface.request_messages[4], &.{.{ .uint = second_serial }});
    try commitTestSurface(harness.client());
    try std.testing.expect(adapter_surface.accepted_configure != null);
    try attachTestBuffer(harness.client(), 10);
    try commitTestSurface(harness.client());
    try std.testing.expect(adapter_surface.accepted_configure == null);
    const second_release = try drainTest(harness.client());
    std.testing.allocator.free(second_release);

    try attachTestBuffer(harness.client(), null);
    try commitTestSurface(harness.client());
    try std.testing.expect(!adapter_surface.initial_configure_sent);
    try std.testing.expectEqual(@as(usize, 0), adapter_surface.configures.items.len);
    try std.testing.expect(adapter_surface.accepted_configure == null);
    try std.testing.expect(!harness.core_shell.surfaceConfigured(adapter_surface.core_id));
    try std.testing.expect(!harness.core_shell.windowInfo(toplevel.core_id).?.mapped);

    try commitTestSurface(harness.client());
    const remap = try drainTest(harness.client());
    defer std.testing.allocator.free(remap);
    const remap_serial = testWord(remap, remap.len - 4);
    try std.testing.expectEqual(@as(u64, 3), adapter_surface.configures.items[0].accepted.token.sequence);
    try sendTest(harness.client(), 6, 4, &core.xdg_surface.request_messages[4], &.{.{ .uint = remap_serial }});
    try attachTestBuffer(harness.client(), 10);
    try commitTestSurface(harness.client());
    try std.testing.expect(harness.core_shell.surfaceConfigured(adapter_surface.core_id));
    try std.testing.expect(adapter_surface.accepted_configure == null);
    scene_windows = harness.scene.iterator();
    try std.testing.expect(scene_windows.next().?.window.mapped);
}

test "first-map presentation OOM leaves published Wayring content private" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.createSurface();
    try harness.installManager(7);
    try harness.createToplevel();
    const adapter_surface = harness.adapter.surfaces.items[0];
    const toplevel = harness.adapter.toplevels.items[0];

    try commitTestSurface(harness.client());
    const configure = try drainTest(harness.client());
    defer std.testing.allocator.free(configure);
    const serial = testWord(configure, configure.len - 4);
    try sendTest(harness.client(), 6, 4, &core.xdg_surface.request_messages[4], &.{.{ .uint = serial }});

    const Listener = struct {
        fn ready(_: *anyopaque, _: XdgShell.WindowId) bool {
            return true;
        }
        fn committed(_: *anyopaque, _: XdgShell.WindowId, _: ?XdgShell.ConfigureToken) bool {
            return true;
        }
        fn ignored(_: *anyopaque, _: XdgShell.WindowId) void {}
        fn metadata(_: *anyopaque, _: XdgShell.WindowId) bool {
            return true;
        }
        fn presentation(
            _: *anyopaque,
            _: XdgShell.WindowId,
            enabled: bool,
        ) error{OutOfMemory}!void {
            if (enabled) return error.OutOfMemory;
        }
        fn interaction(_: *anyopaque, _: XdgShell.WindowId, _: bool) void {}
        fn request(_: *anyopaque, _: XdgShell.WindowId, _: XdgShell.WindowRequest) void {}
    };
    var listener_context: u8 = 0;
    harness.core_shell.setWindowListener(.{
        .context = &listener_context,
        .ready = Listener.ready,
        .committed = Listener.committed,
        .unmapping = Listener.ignored,
        .unmapped = Listener.ignored,
        .destroyed = Listener.ignored,
        .metadata_changed = Listener.metadata,
        .presentation_changed = Listener.presentation,
        .interaction_changed = Listener.interaction,
        .request = Listener.request,
    });
    defer harness.core_shell.clearWindowListener();

    try createTestBuffer(&harness);
    try attachTestBuffer(harness.client(), 10);
    try commitTestSurface(harness.client());
    try std.testing.expectEqual(server.Fatal.Kind.out_of_memory, harness.client().fatal().?.kind);
    try std.testing.expect(harness.compositor.xdgContentState(adapter_surface.surface_id).?.has_committed_buffer);
    const info = harness.core_shell.windowInfo(toplevel.core_id).?;
    try std.testing.expect(!info.mapped);
    try std.testing.expect(!info.scene_presentation_enabled);
    try std.testing.expect(!info.interaction_enabled);
    try std.testing.expect(adapter_surface.prepared_commit == null);
    var scene_windows = harness.scene.iterator();
    try std.testing.expect(!scene_windows.next().?.window.mapped);
}

test "pre-ready non-input state requests are retained without policy" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.createSurface();
    try harness.installManager(7);
    try harness.createToplevel();
    const toplevel = harness.adapter.toplevels.items[0];

    try sendTest(harness.client(), 7, 9, &core.xdg_toplevel.request_messages[9], &.{});
    try sendTest(harness.client(), 7, 11, &core.xdg_toplevel.request_messages[11], &.{.{ .object = null }});
    try sendTest(harness.client(), 7, 13, &core.xdg_toplevel.request_messages[13], &.{});
    var info = harness.core_shell.windowInfo(toplevel.core_id).?;
    try std.testing.expect(!info.ready);
    try std.testing.expect(info.requested_state.maximized);
    try std.testing.expect(info.requested_state.fullscreen);
    try std.testing.expect(info.requested_state.fullscreen_output == null);
    try std.testing.expect(info.requested_state.minimized);

    try sendTest(harness.client(), 7, 10, &core.xdg_toplevel.request_messages[10], &.{});
    try sendTest(harness.client(), 7, 12, &core.xdg_toplevel.request_messages[12], &.{});
    info = harness.core_shell.windowInfo(toplevel.core_id).?;
    try std.testing.expect(!info.requested_state.maximized);
    try std.testing.expect(!info.requested_state.fullscreen);
    try std.testing.expect(info.requested_state.minimized);
}

test "initial buffer commit before configure ack is rejected without content publication" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.createSurface();
    try harness.installManager(7);
    try harness.createToplevel();
    const surface = harness.adapter.surfaces.items[0];

    try commitTestSurface(harness.client());
    const configure = try drainTest(harness.client());
    defer std.testing.allocator.free(configure);
    try std.testing.expectEqual(@as(usize, 1), surface.configures.items.len);
    try createTestBuffer(&harness);
    try attachTestBuffer(harness.client(), 10);
    try commitTestSurface(harness.client());

    try std.testing.expectEqual(server.Fatal.Kind.protocol, harness.client().fatal().?.kind);
    try std.testing.expectEqual(
        @as(?u32, @intCast(core.xdg_surface.@"error".unconfigured_buffer)),
        harness.client().fatal().?.protocol_code,
    );
    try std.testing.expect(!harness.compositor.xdgContentState(surface.surface_id).?.has_committed_buffer);
    try std.testing.expect(surface.accepted_configure == null);
    try std.testing.expectEqual(@as(usize, 1), surface.configures.items.len);
    try std.testing.expect(!harness.core_shell.surfaceConfigured(surface.core_id));
}

test "role destruction reconstructs only the permanent concrete role" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.createSurface();
    try harness.installManager(7);
    try harness.createToplevel();
    const surface_id = harness.adapter.surfaces.items[0].surface_id;

    try sendTest(harness.client(), 7, 0, &core.xdg_toplevel.request_messages[0], &.{});
    try sendTest(harness.client(), 6, 0, &core.xdg_surface.request_messages[0], &.{});
    const retired = try drainTest(harness.client());
    std.testing.allocator.free(retired);
    try std.testing.expectEqual(WayringCompositor.XdgRole.toplevel, harness.compositor.permanentXdgRole(surface_id).?);

    try sendTest(harness.client(), 5, 2, &core.xdg_wm_base.request_messages[2], &.{
        .{ .new_id = .{ .typed = 6 } }, .{ .object = 4 },
    });
    try sendTest(harness.client(), 6, 1, &core.xdg_surface.request_messages[1], &.{.{ .new_id = .{ .typed = 7 } }});
    try std.testing.expectEqual(WayringCompositor.XdgRole.toplevel, harness.compositor.permanentXdgRole(surface_id).?);
    try sendTest(harness.client(), 7, 0, &core.xdg_toplevel.request_messages[0], &.{});
    const toplevel_retired = try drainTest(harness.client());
    std.testing.allocator.free(toplevel_retired);

    try sendTest(harness.client(), 5, 1, &core.xdg_wm_base.request_messages[1], &.{.{ .new_id = .{ .typed = 7 } }});
    try sendTest(harness.client(), 7, 1, &core.xdg_positioner.request_messages[1], &.{ .{ .int = 1 }, .{ .int = 1 } });
    try sendTest(harness.client(), 7, 2, &core.xdg_positioner.request_messages[2], &.{
        .{ .int = 0 }, .{ .int = 0 }, .{ .int = 1 }, .{ .int = 1 },
    });
    try sendTest(harness.client(), 6, 2, &core.xdg_surface.request_messages[2], &.{
        .{ .new_id = .{ .typed = 8 } }, .{ .object = null }, .{ .object = 7 },
    });
    try std.testing.expectEqual(server.Fatal.Kind.protocol, harness.client().fatal().?.kind);
    try std.testing.expectEqual(
        @as(?u32, @intCast(core.xdg_surface.@"error".already_constructed)),
        harness.client().fatal().?.protocol_code,
    );
    try std.testing.expectEqual(@as(usize, 0), harness.adapter.popups.items.len);
}

test "same role reconstruction accepts existing committed content" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.createSurface();
    try harness.installManager(7);
    try harness.createToplevel();
    const surface_id = harness.adapter.surfaces.items[0].surface_id;

    try commitTestSurface(harness.client());
    const configure = try drainTest(harness.client());
    defer std.testing.allocator.free(configure);
    const serial = testWord(configure, configure.len - 4);
    try sendTest(harness.client(), 6, 4, &core.xdg_surface.request_messages[4], &.{.{ .uint = serial }});
    try createTestBuffer(&harness);
    try attachTestBuffer(harness.client(), 10);
    try commitTestSurface(harness.client());
    const release = try drainTest(harness.client());
    std.testing.allocator.free(release);
    try std.testing.expect(harness.compositor.xdgContentState(surface_id).?.has_committed_buffer);

    try sendTest(harness.client(), 7, 0, &core.xdg_toplevel.request_messages[0], &.{});
    try sendTest(harness.client(), 6, 0, &core.xdg_surface.request_messages[0], &.{});
    const retired = try drainTest(harness.client());
    std.testing.allocator.free(retired);
    try std.testing.expect(harness.compositor.xdgContentState(surface_id).?.has_committed_buffer);

    try sendTest(harness.client(), 5, 2, &core.xdg_wm_base.request_messages[2], &.{
        .{ .new_id = .{ .typed = 6 } }, .{ .object = 4 },
    });
    try sendTest(harness.client(), 6, 1, &core.xdg_surface.request_messages[1], &.{.{ .new_id = .{ .typed = 7 } }});
    try std.testing.expect(harness.client().fatal() == null);
    try std.testing.expectEqual(@as(usize, 1), harness.adapter.surfaces.items.len);
    try std.testing.expectEqual(@as(usize, 1), harness.adapter.toplevels.items.len);
    try std.testing.expectEqual(WayringCompositor.XdgRole.toplevel, harness.compositor.permanentXdgRole(surface_id).?);
    try std.testing.expect(harness.compositor.xdgContentState(surface_id).?.has_committed_buffer);
}

test "role resources are mutually exclusive and wrapper destruction is ordered" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.createSurface();
    try harness.installManager(7);
    try harness.createToplevel();

    try sendTest(harness.client(), 6, 0, &core.xdg_surface.request_messages[0], &.{});
    try std.testing.expectEqual(server.Fatal.Kind.protocol, harness.client().fatal().?.kind);
    try std.testing.expectEqual(
        @as(?u32, @intCast(core.xdg_surface.@"error".defunct_role_object)),
        harness.client().fatal().?.protocol_code,
    );
    try std.testing.expectEqual(@as(usize, 1), harness.adapter.toplevels.items.len);
    try std.testing.expectEqual(@as(usize, 1), harness.adapter.surfaces.items.len);
}

test "configure ack discards older snapshots and stale serials are rejected" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.createSurface();
    try harness.installManager(7);
    try harness.createToplevel();
    const surface = harness.adapter.surfaces.items[0];
    const toplevel = harness.adapter.toplevels.items[0];

    try commitTestSurface(harness.client());
    const first_events = try drainTest(harness.client());
    defer std.testing.allocator.free(first_events);
    const first_serial = testWord(first_events, first_events.len - 4);
    _ = try harness.core_shell.configureWindow(toplevel.core_id, .{ .width = 3, .height = 2 });
    const second_events = try drainTest(harness.client());
    defer std.testing.allocator.free(second_events);
    const second_serial = testWord(second_events, second_events.len - 4);
    try std.testing.expect(first_serial != second_serial);
    try std.testing.expectEqual(@as(usize, 2), surface.configures.items.len);

    try sendTest(harness.client(), 6, 4, &core.xdg_surface.request_messages[4], &.{.{ .uint = second_serial }});
    try std.testing.expectEqual(@as(usize, 0), surface.configures.items.len);
    try std.testing.expectEqual(@as(u64, 2), surface.accepted_configure.?.accepted.token.sequence);
    try sendTest(harness.client(), 6, 4, &core.xdg_surface.request_messages[4], &.{.{ .uint = first_serial }});
    try std.testing.expectEqual(server.Fatal.Kind.protocol, harness.client().fatal().?.kind);
    try std.testing.expectEqual(
        @as(?u32, @intCast(core.xdg_surface.@"error".invalid_serial)),
        harness.client().fatal().?.protocol_code,
    );
}

test "invalid size hints reject after preparation and publish no configure" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.createSurface();
    try harness.installManager(7);
    try harness.createToplevel();
    const surface = harness.adapter.surfaces.items[0];
    try sendTest(harness.client(), 7, 8, &core.xdg_toplevel.request_messages[8], &.{
        .{ .int = -1 }, .{ .int = 0 },
    });

    try commitTestSurface(harness.client());
    try std.testing.expectEqual(server.Fatal.Kind.protocol, harness.client().fatal().?.kind);
    try std.testing.expectEqual(
        @as(?u32, @intCast(core.xdg_toplevel.@"error".invalid_size)),
        harness.client().fatal().?.protocol_code,
    );
    try std.testing.expect(surface.prepared_events == null);
    try std.testing.expect(surface.prepared_commit == null);
    try std.testing.expectEqual(@as(usize, 0), surface.configures.items.len);
}

test "positioner validates mutable wire state and snapshots copies" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.createSurface();
    try harness.installManager(7);
    try sendTest(harness.client(), 5, 1, &core.xdg_wm_base.request_messages[1], &.{.{ .new_id = .{ .typed = 6 } }});
    const positioner = harness.adapter.positioners.items[0];
    try std.testing.expect(!positioner.rules.complete());
    try std.testing.expect(!positioner.rules.reactive);
    try std.testing.expect(positioner.rules.parent_size == null);

    try sendTest(harness.client(), 6, 1, &core.xdg_positioner.request_messages[1], &.{ .{ .int = 4 }, .{ .int = 5 } });
    try sendTest(harness.client(), 6, 2, &core.xdg_positioner.request_messages[2], &.{
        .{ .int = 1 }, .{ .int = 2 }, .{ .int = 3 }, .{ .int = 4 },
    });
    try sendTest(harness.client(), 6, 3, &core.xdg_positioner.request_messages[3], &.{.{ .uint = 5 }});
    try sendTest(harness.client(), 6, 4, &core.xdg_positioner.request_messages[4], &.{.{ .uint = 8 }});
    try sendTest(harness.client(), 6, 5, &core.xdg_positioner.request_messages[5], &.{.{ .uint = 0x3f }});
    try sendTest(harness.client(), 6, 7, &core.xdg_positioner.request_messages[7], &.{});
    try sendTest(harness.client(), 6, 8, &core.xdg_positioner.request_messages[8], &.{ .{ .int = 20 }, .{ .int = 10 } });
    const snapshot = harness.adapter.copyPositioner(positioner, null);
    try std.testing.expect(snapshot.rules.complete());
    try std.testing.expect(snapshot.rules.reactive);
    try std.testing.expectEqual(XdgShell.Anchor.top_left, snapshot.rules.anchor);
    try std.testing.expectEqual(XdgShell.Gravity.bottom_right, snapshot.rules.gravity);

    try sendTest(harness.client(), 6, 1, &core.xdg_positioner.request_messages[1], &.{ .{ .int = 9 }, .{ .int = 9 } });
    try std.testing.expectEqual(@as(i32, 4), snapshot.rules.size.?.width);
    try std.testing.expectEqual(@as(i32, 9), positioner.rules.size.?.width);
    try sendTest(harness.client(), 6, 0, &core.xdg_positioner.request_messages[0], &.{});
    try std.testing.expectEqual(@as(i32, 4), snapshot.rules.size.?.width);
}

test "positioner resolves selected parent wire serial to a neutral token" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.createSurface();
    try harness.installManager(7);
    try harness.createToplevel();
    const parent = harness.adapter.surfaces.items[0];

    try commitTestSurface(harness.client());
    const events = try drainTest(harness.client());
    defer std.testing.allocator.free(events);
    const serial = testWord(events, events.len - 4);
    const token = parent.configures.items[0].accepted.token;
    try sendTest(harness.client(), 5, 1, &core.xdg_wm_base.request_messages[1], &.{.{ .new_id = .{ .typed = 8 } }});
    const positioner = harness.adapter.positioners.items[0];
    try sendTest(harness.client(), 8, 9, &core.xdg_positioner.request_messages[9], &.{.{ .uint = serial }});
    try std.testing.expectEqual(token, harness.adapter.copyPositioner(positioner, parent).parent_configure.?);

    try sendTest(harness.client(), 6, 4, &core.xdg_surface.request_messages[4], &.{.{ .uint = serial }});
    try std.testing.expectEqual(token, harness.adapter.copyPositioner(positioner, parent).parent_configure.?);
    try sendTest(harness.client(), 8, 9, &core.xdg_positioner.request_messages[9], &.{.{ .uint = serial + 1 }});
    try std.testing.expect(harness.adapter.copyPositioner(positioner, parent).parent_configure == null);
}

test "positioner version gate terminalizes only that client" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.createSurface();
    try harness.installManager(2);
    try sendTest(harness.client(), 5, 1, &core.xdg_wm_base.request_messages[1], &.{.{ .new_id = .{ .typed = 6 } }});
    try sendTest(harness.client(), 6, 7, &core.xdg_positioner.request_messages[7], &.{});
    try std.testing.expectEqual(server.Fatal.Kind.protocol, harness.client().fatal().?.kind);
    try std.testing.expectEqual(@as(usize, 1), harness.adapter.positioners.items.len);
}

test "positioner rejects invalid dimensions enums and adjustment masks" {
    const Case = struct {
        fn run(opcode: u16, values: []const wire.Value) !void {
            var harness: TestHarness = undefined;
            try harness.init();
            defer harness.deinit();
            try harness.createSurface();
            try harness.installManager(7);
            try sendTest(harness.client(), 5, 1, &core.xdg_wm_base.request_messages[1], &.{.{ .new_id = .{ .typed = 6 } }});
            try sendTest(
                harness.client(),
                6,
                opcode,
                &core.xdg_positioner.request_messages[opcode],
                values,
            );
            try std.testing.expectEqual(server.Fatal.Kind.protocol, harness.client().fatal().?.kind);
            try std.testing.expectEqual(
                @as(?u32, @intCast(core.xdg_positioner.@"error".invalid_input)),
                harness.client().fatal().?.protocol_code,
            );
            try std.testing.expectEqual(@as(usize, 1), harness.adapter.positioners.items.len);
        }
    };

    try Case.run(1, &.{ .{ .int = 0 }, .{ .int = 1 } });
    try Case.run(2, &.{ .{ .int = 0 }, .{ .int = 0 }, .{ .int = -1 }, .{ .int = 1 } });
    try Case.run(3, &.{.{ .uint = 9 }});
    try Case.run(4, &.{.{ .uint = 9 }});
    try Case.run(5, &.{.{ .uint = 0x40 }});
    try Case.run(8, &.{ .{ .int = 1 }, .{ .int = 0 } });
}

test "positioner outlives its manager and remains independently mutable" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.createSurface();
    try harness.installManager(7);
    try sendTest(harness.client(), 5, 1, &core.xdg_wm_base.request_messages[1], &.{.{ .new_id = .{ .typed = 6 } }});
    try sendTest(harness.client(), 5, 0, &core.xdg_wm_base.request_messages[0], &.{});
    try std.testing.expectEqual(@as(usize, 0), harness.adapter.managers.items.len);
    try std.testing.expectEqual(@as(usize, 1), harness.adapter.positioners.items.len);
    try sendTest(harness.client(), 6, 1, &core.xdg_positioner.request_messages[1], &.{ .{ .int = 2 }, .{ .int = 3 } });
    try std.testing.expectEqual(@as(i32, 2), harness.adapter.positioners.items[0].rules.size.?.width);
    try sendTest(harness.client(), 6, 0, &core.xdg_positioner.request_messages[0], &.{});
    try std.testing.expectEqual(@as(usize, 0), harness.adapter.positioners.items.len);
    try std.testing.expect(harness.client().fatal() == null);
}

test "resource generation exhaustion never wraps or aliases" {
    var adapter: WayringXdgShell = undefined;
    adapter.next_resource_generation = std.math.maxInt(u64);
    try std.testing.expectEqual(std.math.maxInt(u64), try adapter.issueGeneration());
    try std.testing.expectError(error.GenerationExhausted, adapter.issueGeneration());
    try std.testing.expectError(error.GenerationExhausted, adapter.issueGeneration());
}
