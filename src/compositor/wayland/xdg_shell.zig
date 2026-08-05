//! xdg-shell globals and toplevel protocol state.

const Self = @This();

const std = @import("std");
const NeutralXdgShell = @import("../XdgShell.zig");
const wayland = @import("wayland");
const Scene = @import("../scene.zig");
const Seat = @import("seat.zig");
const slot_map = @import("../slot_map.zig");
const Surface = @import("surface.zig");
const OutputLayout = @import("output_layout.zig");
const GtkShell = @import("gtk_shell.zig");
const XdgPositioner = @import("XdgPositioner.zig");
const MatureClients = @import("MatureClients.zig");
const MatureSerials = @import("mature_serials.zig");

const wl = wayland.server.wl;
const xdg = wayland.server.xdg;
const zxdg = wayland.server.zxdg;

allocator: std.mem.Allocator,
display: *wl.Server,
core: *NeutralXdgShell,
mature_clients: *MatureClients,
surface_store: *Surface.Store,
seat: *Seat,
outputs: *OutputLayout,
gtk_shell: *GtkShell,
global: *wl.Global,
decoration_global: *wl.Global,
bindings: BindingStore,
surface_resources: std.ArrayList(*XdgSurfaceResource),

const BindingStore = slot_map.SlotMap(BindingState, enum { xdg_binding });
const BindingId = BindingStore.Id;

const BindingState = struct {
    surface_count: usize = 0,
};

// GTK and Chromium retain wl_surface objects while rebuilding their xdg role
// objects. Preserve the permanent role and only allow the same xdg role to be
// assigned again when the replacement xdg_surface chooses its role.
fn xdgReservationRole(existing: ?Surface.Role) ?Surface.Role {
    const role = existing orelse return .xdg_toplevel;
    return switch (role) {
        .xdg_toplevel => .xdg_toplevel,
        .xdg_popup => .xdg_popup,
        else => null,
    };
}

const Configure = struct {
    serial: u32,
    token: NeutralXdgShell.ConfigureToken,
    popup: ?NeutralXdgShell.PopupConfigure = null,
};

fn acknowledgeConfigure(
    configures: *std.ArrayList(Configure),
    accepted: *?Configure,
    serial: u32,
) bool {
    const index = for (configures.items, 0..) |configure, i| {
        if (configure.serial == serial) break i;
    } else return false;
    const configure = configures.items[index];
    const consumed = index + 1;
    std.mem.copyForwards(
        Configure,
        configures.items[0 .. configures.items.len - consumed],
        configures.items[consumed..],
    );
    configures.items.len -= consumed;
    accepted.* = configure;
    return true;
}

pub const ToplevelInfo = struct {
    window_id: NeutralXdgShell.WindowId,
    surface_resource: *wl.Surface,
    xdg_surface_resource: *xdg.Surface,
    resource: *xdg.Toplevel,
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    core: *NeutralXdgShell,
    mature_clients: *MatureClients,
    surface_store: *Surface.Store,
    seat: *Seat,
    outputs: *OutputLayout,
    gtk_shell: *GtkShell,
) !void {
    self.* = .{
        .allocator = allocator,
        .display = display,
        .core = core,
        .mature_clients = mature_clients,
        .surface_store = surface_store,
        .seat = seat,
        .outputs = outputs,
        .gtk_shell = gtk_shell,
        .global = undefined,
        .decoration_global = undefined,
        .bindings = .{},
        .surface_resources = .empty,
    };
    errdefer self.bindings.deinit(allocator);
    errdefer self.surface_resources.deinit(allocator);
    self.global = try wl.Global.create(display, xdg.WmBase, 7, *Self, self, bind);
    errdefer self.global.destroy();
    self.decoration_global = try wl.Global.create(
        display,
        zxdg.DecorationManagerV1,
        2,
        *Self,
        self,
        bindDecorationManager,
    );
}

pub fn deinit(self: *Self) void {
    self.decoration_global.destroy();
    self.global.destroy();
    self.bindings.deinit(self.allocator);
    std.debug.assert(self.surface_resources.items.len == 0);
    self.surface_resources.deinit(self.allocator);
    self.* = undefined;
}

pub const AttachPopupError = error{
    ForeignResource,
    AlreadyAttached,
    InvalidLayerSurface,
    OutOfMemory,
};

/// The layer-surface owner must dismiss these popups before unmapping or
/// removing their parent.
pub fn attachPopup(
    self: *Self,
    resource: *xdg.Popup,
    layer_surface_id: Scene.LayerSurfaceId,
) AttachPopupError!void {
    const data = resource.getUserData() orelse return error.ForeignResource;
    const adapter: *PopupResource = @ptrCast(@alignCast(data));
    if (adapter.shell != self) return error.ForeignResource;
    self.core.attachPopup(adapter.id, layer_surface_id) catch |err| switch (err) {
        error.AlreadyAttached => return error.AlreadyAttached,
        error.InvalidLayerSurface => return error.InvalidLayerSurface,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

fn appendEnum(values: anytype, count: *usize, value: anytype) void {
    std.debug.assert(count.* < values.len);
    values[count.*] = @intCast(@intFromEnum(value));
    count.* += 1;
}

fn toplevelStates(
    configuration: NeutralXdgShell.ToplevelConfigure,
    version: u32,
    values: *[13]u32,
) []u32 {
    var count: usize = 0;
    if (configuration.maximized) appendEnum(values, &count, xdg.Toplevel.State.maximized);
    if (configuration.fullscreen) appendEnum(values, &count, xdg.Toplevel.State.fullscreen);
    if (configuration.resizing) appendEnum(values, &count, xdg.Toplevel.State.resizing);
    if (configuration.activated) appendEnum(values, &count, xdg.Toplevel.State.activated);
    if (version >= 2) {
        if (configuration.tiled.left) appendEnum(values, &count, xdg.Toplevel.State.tiled_left);
        if (configuration.tiled.right) appendEnum(values, &count, xdg.Toplevel.State.tiled_right);
        if (configuration.tiled.top) appendEnum(values, &count, xdg.Toplevel.State.tiled_top);
        if (configuration.tiled.bottom) appendEnum(values, &count, xdg.Toplevel.State.tiled_bottom);
    }
    if (version >= 6 and configuration.suspended) {
        appendEnum(values, &count, xdg.Toplevel.State.suspended);
    }
    if (version >= 7) {
        if (configuration.constrained.left) appendEnum(values, &count, xdg.Toplevel.State.constrained_left);
        if (configuration.constrained.right) appendEnum(values, &count, xdg.Toplevel.State.constrained_right);
        if (configuration.constrained.top) appendEnum(values, &count, xdg.Toplevel.State.constrained_top);
        if (configuration.constrained.bottom) appendEnum(values, &count, xdg.Toplevel.State.constrained_bottom);
    }
    return values[0..count];
}

pub fn toplevelForSurface(self: *Self, surface_id: Surface.Id) ?ToplevelInfo {
    const window_id = self.core.toplevelForSurface(surface_id) orelse return null;
    for (self.surface_resources.items) |adapter| {
        const surface = adapter.surface orelse continue;
        if (!std.meta.eql(surface.handle(), surface_id)) continue;
        const resource = adapter.toplevel_resource orelse return null;
        return .{
            .window_id = window_id,
            .surface_resource = Surface.resourceFor(self.surface_store, surface_id) orelse return null,
            .xdg_surface_resource = adapter.resource,
            .resource = resource,
        };
    }
    return null;
}

pub fn toplevelFromResource(self: *Self, resource: *xdg.Toplevel) ?ToplevelInfo {
    const data = resource.getUserData() orelse return null;
    const toplevel: *ToplevelResource = @ptrCast(@alignCast(data));
    if (toplevel.shell != self) return null;
    if (self.core.windowInfo(toplevel.id) == null or
        toplevel.xdg_surface_resource.toplevel_resource != resource) return null;
    const surface = toplevel.xdg_surface_resource.surface orelse return null;
    return .{
        .window_id = toplevel.id,
        .surface_resource = Surface.resourceFor(self.surface_store, surface.handle()) orelse return null,
        .xdg_surface_resource = toplevel.xdg_surface_resource.resource,
        .resource = resource,
    };
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    WmBaseResource.create(self, client, version, id) catch client.postNoMemory();
}

fn bindDecorationManager(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = zxdg.DecorationManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleDecorationManagerRequest, null, self);
}

fn handleDecorationManagerRequest(
    resource: *zxdg.DecorationManagerV1,
    request: zxdg.DecorationManagerV1.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .get_toplevel_decoration => |get| ToplevelDecorationResource.create(
            self,
            resource,
            get.toplevel,
            get.id,
        ) catch resource.postNoMemory(),
    }
}

const WmBaseResource = struct {
    allocator: std.mem.Allocator,
    shell: *Self,
    id: BindingId,

    fn create(
        shell: *Self,
        client: *wl.Client,
        version: u32,
        id: u32,
    ) error{ OutOfMemory, ResourceCreateFailed }!void {
        const resource = try xdg.WmBase.create(client, version, id);
        errdefer resource.destroy();

        const self = shell.allocator.create(WmBaseResource) catch return error.OutOfMemory;
        errdefer shell.allocator.destroy(self);

        const binding_id = shell.bindings.insert(shell.allocator, .{}) catch
            return error.OutOfMemory;
        self.* = .{
            .allocator = shell.allocator,
            .shell = shell,
            .id = binding_id,
        };
        resource.setHandler(*WmBaseResource, handleRequest, handleDestroy, self);
    }

    fn handleRequest(
        resource: *xdg.WmBase,
        request: xdg.WmBase.Request,
        self: *WmBaseResource,
    ) void {
        switch (request) {
            .destroy => {
                const binding = self.shell.bindings.get(self.id) orelse unreachable;
                if (binding.surface_count != 0) {
                    resource.postError(
                        .defunct_surfaces,
                        "xdg_wm_base still owns xdg_surface objects",
                    );
                    return;
                }
                resource.destroy();
            },
            .create_positioner => |positioner| XdgPositioner.create(
                self.allocator,
                resource.getClient(),
                resource.getVersion(),
                positioner.id,
            ) catch resource.postNoMemory(),
            .get_xdg_surface => |get| XdgSurfaceResource.create(
                self.shell,
                self.id,
                resource,
                get.surface,
                get.id,
            ) catch resource.postNoMemory(),
            .pong => {},
        }
    }

    fn handleDestroy(_: *xdg.WmBase, self: *WmBaseResource) void {
        _ = self.shell.bindings.remove(self.id);
        self.allocator.destroy(self);
    }
};

const XdgSurfaceResource = struct {
    allocator: std.mem.Allocator,
    shell: *Self,
    id: NeutralXdgShell.XdgSurfaceId,
    binding_id: BindingId,
    wm_base_resource: *xdg.WmBase,
    resource: *xdg.Surface,
    surface: ?*Surface,
    toplevel_resource: ?*xdg.Toplevel,
    popup_resource: ?*xdg.Popup,
    pending_geometry: ?NeutralXdgShell.Geometry = null,
    pending_geometry_changed: bool = false,
    configures: std.ArrayList(Configure) = .empty,
    accepted_configure: ?Configure = null,
    initial_configure_sent: bool = false,
    sent_capabilities: ?NeutralXdgShell.WindowCapabilities = null,
    sent_bounds: ?NeutralXdgShell.Dimensions = null,

    fn create(
        shell: *Self,
        binding_id: BindingId,
        wm_base_resource: *xdg.WmBase,
        wl_surface_resource: *wl.Surface,
        id: u32,
    ) error{ OutOfMemory, ResourceCreateFailed }!void {
        try shell.surface_resources.ensureUnusedCapacity(shell.allocator, 1);
        const resource = try xdg.Surface.create(
            wm_base_resource.getClient(),
            wm_base_resource.getVersion(),
            id,
        );
        errdefer resource.destroy();

        const self = shell.allocator.create(XdgSurfaceResource) catch return error.OutOfMemory;
        errdefer shell.allocator.destroy(self);

        const surface = Surface.fromResource(wl_surface_resource);
        self.* = .{
            .allocator = shell.allocator,
            .shell = shell,
            .id = undefined,
            .binding_id = binding_id,
            .wm_base_resource = wm_base_resource,
            .resource = resource,
            .surface = surface,
            .toplevel_resource = null,
            .popup_resource = null,
        };

        const existing_role = surface.assignedRole();
        const reservation_role = xdgReservationRole(existing_role) orelse {
            wm_base_resource.postError(.role, "wl_surface already has a role");
            shell.allocator.destroy(self);
            resource.destroy();
            return;
        };
        const invalid_buffer_state = if (existing_role == null)
            surface.hasBufferAttachedOrCommitted()
        else
            surface.hasBufferAttached();
        if (invalid_buffer_state) {
            wm_base_resource.postError(
                .invalid_surface_state,
                "wl_surface already has a buffer attached or committed",
            );
            shell.allocator.destroy(self);
            resource.destroy();
            return;
        }
        const client_id = shell.mature_clients.id(resource.getClient()) orelse {
            shell.allocator.destroy(self);
            resource.destroy();
            return;
        };
        self.id = shell.core.createSurface(surface.handle(), client_id, .{
            .context = self,
            .configure_toplevel = configureToplevel,
            .configure_popup = configurePopup,
            .close = close,
            .popup_done = popupDone,
            .report_failure = reportFailure,
        }) catch return error.OutOfMemory;
        errdefer shell.core.removeSurface(self.id);
        surface.reserveRole(reservation_role, .{
            .context = self,
            .before_commit = beforeSurfaceCommit,
            .after_commit = afterSurfaceStateCommit,
            .tree_applied = afterSurfaceCommit,
            .surface_destroyed = surfaceDestroyed,
        }) catch {
            wm_base_resource.postError(.role, "wl_surface is not available for an xdg role");
            shell.core.removeSurface(self.id);
            shell.allocator.destroy(self);
            resource.destroy();
            return;
        };

        if (shell.bindings.get(binding_id)) |binding| binding.surface_count += 1;
        shell.surface_resources.appendAssumeCapacity(self);
        resource.setHandler(*XdgSurfaceResource, handleRequest, handleDestroy, self);
    }

    fn handleRequest(
        resource: *xdg.Surface,
        request: xdg.Surface.Request,
        self: *XdgSurfaceResource,
    ) void {
        switch (request) {
            .destroy => {
                if (self.shell.core.surfaceRole(self.id) != null) {
                    resource.postError(
                        .defunct_role_object,
                        "destroy the xdg role object before xdg_surface",
                    );
                    return;
                }
                resource.destroy();
            },
            .get_toplevel => |get| {
                if (self.shell.core.surfaceRole(self.id) != null) {
                    resource.postError(.already_constructed, "xdg_surface already has a role");
                    return;
                }
                ToplevelResource.create(self, get.id) catch resource.postNoMemory();
            },
            .get_popup => |get| {
                if (self.shell.core.surfaceRole(self.id) != null) {
                    resource.postError(.already_constructed, "xdg_surface already has a role");
                    return;
                }
                PopupResource.create(self, get.id, get.parent, get.positioner) catch |err| switch (err) {
                    error.OutOfMemory => resource.postNoMemory(),
                    error.ResourceCreateFailed => {},
                };
            },
            .set_window_geometry => |set| {
                if (!self.requireRole()) return;
                if (set.width <= 0 or set.height <= 0) {
                    resource.postError(.invalid_size, "window geometry size must be positive");
                    return;
                }
                self.pending_geometry = .{
                    .x = set.x,
                    .y = set.y,
                    .width = set.width,
                    .height = set.height,
                };
                self.pending_geometry_changed = true;
            },
            .ack_configure => |ack| {
                if (!self.requireRole()) return;
                self.ackConfigure(ack.serial);
            },
        }
    }

    fn handleDestroy(_: *xdg.Surface, self: *XdgSurfaceResource) void {
        if (self.surface) |surface| surface.releaseRole(self);

        if (self.shell.bindings.get(self.binding_id)) |binding| {
            std.debug.assert(binding.surface_count > 0);
            binding.surface_count -= 1;
        }

        if (self.shell.core.surfaceRole(self.id)) |role| switch (role) {
            .toplevel => |window_id| self.shell.core.destroyToplevel(window_id),
            .popup => |popup_id| self.shell.core.destroyPopup(popup_id),
        };
        self.shell.core.removeSurface(self.id);
        for (self.shell.surface_resources.items, 0..) |candidate, index| {
            if (candidate != self) continue;
            _ = self.shell.surface_resources.swapRemove(index);
            break;
        } else unreachable;
        self.configures.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn requireRole(self: *XdgSurfaceResource) bool {
        if (self.shell.core.surfaceRole(self.id) == null) {
            self.resource.postError(.not_constructed, "xdg_surface has no role");
            return false;
        }
        return true;
    }

    fn ackConfigure(self: *XdgSurfaceResource, serial: u32) void {
        if (!acknowledgeConfigure(&self.configures, &self.accepted_configure, serial)) {
            self.resource.postError(.invalid_serial, "unknown xdg_surface configure serial");
        }
    }

    fn beforeSurfaceCommit(context: *anyopaque, info: Surface.CommitInfo) Surface.CommitAction {
        const self: *XdgSurfaceResource = @ptrCast(@alignCast(context));
        const role = self.shell.core.validateCommit(self.id) catch |err| switch (err) {
            error.InvalidSurface => return .reject,
            error.RoleMissing => {
                self.resource.postError(.not_constructed, "xdg_surface committed before role creation");
                return .reject;
            },
            error.InvalidSizeHints => {
                self.toplevel_resource.?.postError(
                    .invalid_size,
                    "invalid minimum or maximum window size",
                );
                return .reject;
            },
            error.PopupUnattached => {
                self.wm_base_resource.postError(
                    .invalid_popup_parent,
                    "unattached xdg_popup committed before external parent attachment",
                );
                return .reject;
            },
        };
        if (info.has_buffer and role == .toplevel) {
            const toplevel: *ToplevelResource = @ptrCast(@alignCast(
                self.toplevel_resource.?.getUserData().?,
            ));
            if (toplevel.decoration) |decoration| {
                if (decoration.resource.getVersion() == 1 and !decoration.configure_sent) {
                    decoration.resource.postError(
                        .unconfigured_buffer,
                        "buffer committed before the initial decoration configure",
                    );
                    return .reject;
                }
            }
        }
        if (info.has_buffer and !self.shell.core.surfaceConfigured(self.id) and
            self.accepted_configure == null)
        {
            self.resource.postError(
                .unconfigured_buffer,
                "buffer committed before the initial configure was acknowledged",
            );
            return .reject;
        }
        self.shell.core.beforeAppliedCommit(self.id, info.had_buffer, info.has_buffer);
        return .apply;
    }

    fn afterSurfaceStateCommit(_: *anyopaque, _: Surface.CommitInfo) void {}

    fn afterSurfaceCommit(context: *anyopaque, info: Surface.CommitInfo) void {
        const self: *XdgSurfaceResource = @ptrCast(@alignCast(context));
        if (self.pending_geometry_changed) {
            self.shell.core.commitGeometry(self.id, self.pending_geometry orelse unreachable);
            self.pending_geometry_changed = false;
        }
        const accepted: ?NeutralXdgShell.AcceptedConfigure = if (self.accepted_configure) |configure| .{
            .token = configure.token,
            .popup = configure.popup,
        } else null;
        const dismissed_popup = switch (self.shell.core.surfaceRole(self.id) orelse return) {
            .toplevel => false,
            .popup => |popup_id| self.shell.core.popupDismissed(popup_id),
        };
        self.shell.core.afterAppliedCommit(
            self.id,
            info.had_buffer,
            info.has_buffer,
            accepted,
        ) catch |err| {
            self.wm_base_resource.postError(.invalid_popup_parent, switch (err) {
                error.PopupParentNotMapped => "xdg_popup parent is not mapped",
                error.InvalidPopupParent => "invalid xdg_popup parent",
            });
            return;
        };
        if (info.has_buffer and !dismissed_popup) self.accepted_configure = null;
        if (info.had_buffer and !info.has_buffer and !dismissed_popup) self.resetWireState();
    }

    fn surfaceDestroyed(context: *anyopaque) void {
        const self: *XdgSurfaceResource = @ptrCast(@alignCast(context));
        self.surface = null;
        self.shell.core.surfaceDestroyed(self.id);
    }

    fn resetWireState(self: *XdgSurfaceResource) void {
        self.initial_configure_sent = false;
        self.sent_capabilities = null;
        self.sent_bounds = null;
        self.accepted_configure = null;
        self.configures.clearRetainingCapacity();
        if (self.toplevel_resource) |resource| {
            const toplevel: *ToplevelResource = @ptrCast(@alignCast(resource.getUserData().?));
            if (toplevel.decoration) |decoration| decoration.configure_sent = false;
        }
    }

    fn configureToplevel(
        context: *anyopaque,
        dimensions: NeutralXdgShell.Dimensions,
        configuration: NeutralXdgShell.ToplevelConfigure,
        token: NeutralXdgShell.ConfigureToken,
    ) error{OutOfMemory}!void {
        const self: *XdgSurfaceResource = @ptrCast(@alignCast(context));
        const toplevel = self.toplevel_resource orelse return;
        const serial = MatureSerials.issueWire(self.shell.display);
        try self.configures.append(self.allocator, .{ .serial = serial, .token = token });

        var state_values: [13]u32 = undefined;
        const states = toplevelStates(configuration, toplevel.getVersion(), &state_values);
        var states_array: wl.Array = .{
            .size = states.len * @sizeOf(u32),
            .alloc = states.len * @sizeOf(u32),
            .data = if (states.len == 0) null else @ptrCast(states.ptr),
        };
        if (toplevel.getVersion() >= 5 and
            (self.sent_capabilities == null or
                !std.meta.eql(self.sent_capabilities.?, configuration.capabilities)))
        {
            var values: [4]u32 = undefined;
            var count: usize = 0;
            if (configuration.capabilities.window_menu) appendEnum(&values, &count, xdg.Toplevel.WmCapabilities.window_menu);
            if (configuration.capabilities.maximize) appendEnum(&values, &count, xdg.Toplevel.WmCapabilities.maximize);
            if (configuration.capabilities.fullscreen) appendEnum(&values, &count, xdg.Toplevel.WmCapabilities.fullscreen);
            if (configuration.capabilities.minimize) appendEnum(&values, &count, xdg.Toplevel.WmCapabilities.minimize);
            var array: wl.Array = .{
                .size = count * @sizeOf(u32),
                .alloc = count * @sizeOf(u32),
                .data = if (count == 0) null else @ptrCast(&values),
            };
            toplevel.sendWmCapabilities(&array);
            self.sent_capabilities = configuration.capabilities;
        }
        if (toplevel.getVersion() >= 4 and
            (self.sent_bounds == null or !std.meta.eql(self.sent_bounds.?, configuration.bounds)))
        {
            toplevel.sendConfigureBounds(configuration.bounds.width, configuration.bounds.height);
            self.sent_bounds = configuration.bounds;
        }
        const adapter: *ToplevelResource = @ptrCast(@alignCast(toplevel.getUserData().?));
        if (adapter.decoration) |decoration| {
            decoration.resource.sendConfigure(switch (configuration.decoration_mode) {
                .client_side => .client_side,
                .server_side => .server_side,
            });
            decoration.configure_sent = true;
            self.shell.core.decorationConfigured(adapter.id);
        }
        if (self.surface) |surface| self.shell.gtk_shell.configureSurface(surface.handle(), .{
            .top = configuration.tiled.top,
            .right = configuration.tiled.right,
            .bottom = configuration.tiled.bottom,
            .left = configuration.tiled.left,
        });
        toplevel.sendConfigure(dimensions.width, dimensions.height, &states_array);
        self.resource.sendConfigure(serial);
        self.initial_configure_sent = true;
    }

    fn configurePopup(
        context: *anyopaque,
        configure: NeutralXdgShell.PopupConfigure,
        token: NeutralXdgShell.ConfigureToken,
    ) error{OutOfMemory}!void {
        const self: *XdgSurfaceResource = @ptrCast(@alignCast(context));
        const popup = self.popup_resource orelse return;
        const serial = MatureSerials.issueWire(self.shell.display);
        try self.configures.append(self.allocator, .{
            .serial = serial,
            .token = token,
            .popup = configure,
        });
        const adapter: *PopupResource = @ptrCast(@alignCast(popup.getUserData().?));
        if (adapter.reposition_token) |wire_token| popup.sendRepositioned(wire_token);
        popup.sendConfigure(
            configure.placement.position.x,
            configure.placement.position.y,
            configure.placement.dimensions.width,
            configure.placement.dimensions.height,
        );
        self.resource.sendConfigure(serial);
        self.initial_configure_sent = true;
    }

    fn close(context: *anyopaque) void {
        const self: *XdgSurfaceResource = @ptrCast(@alignCast(context));
        if (self.toplevel_resource) |resource| resource.sendClose();
    }

    fn popupDone(context: *anyopaque) void {
        const self: *XdgSurfaceResource = @ptrCast(@alignCast(context));
        if (self.popup_resource) |resource| resource.sendPopupDone();
    }

    fn reportFailure(context: *anyopaque, failure: NeutralXdgShell.EndpointFailure) void {
        const self: *XdgSurfaceResource = @ptrCast(@alignCast(context));
        switch (failure) {
            .no_memory => self.resource.postNoMemory(),
            .invalid_positioner => self.wm_base_resource.postError(.invalid_positioner, "invalid xdg_popup positioner"),
        }
    }
};

const PopupResource = struct {
    allocator: std.mem.Allocator,
    shell: *Self,
    id: NeutralXdgShell.PopupId,
    xdg_surface_id: NeutralXdgShell.XdgSurfaceId,
    xdg_surface_resource: *XdgSurfaceResource,
    reposition_token: ?u32 = null,

    fn create(
        xdg_surface: *XdgSurfaceResource,
        id: u32,
        parent_resource: ?*xdg.Surface,
        positioner_resource: *xdg.Positioner,
    ) error{ OutOfMemory, ResourceCreateFailed }!void {
        const surface = xdg_surface.surface orelse return error.ResourceCreateFailed;
        if (parent_resource) |parent_xdg_resource| if (parent_xdg_resource.getClient() != xdg_surface.resource.getClient()) {
            xdg_surface.wm_base_resource.postError(
                .invalid_popup_parent,
                "xdg_popup parent belongs to another client",
            );
            return error.ResourceCreateFailed;
        };
        const parent_adapter: ?*XdgSurfaceResource = if (parent_resource) |parent_xdg_resource|
            @ptrCast(@alignCast(parent_xdg_resource.getUserData() orelse return error.ResourceCreateFailed))
        else
            null;
        if (parent_adapter) |adapter| if (adapter.shell != xdg_surface.shell or
            std.meta.eql(adapter.id, xdg_surface.id))
        {
            xdg_surface.wm_base_resource.postError(
                .invalid_popup_parent,
                "invalid xdg_popup parent",
            );
            return error.ResourceCreateFailed;
        };
        xdg_surface.shell.core.validatePopupParent(
            xdg_surface.id,
            if (parent_adapter) |adapter| adapter.id else null,
        ) catch |err| {
            postPopupValidationError(xdg_surface, err);
            return error.ResourceCreateFailed;
        };
        const rules = XdgPositioner.fromResource(positioner_resource).rules;
        if (!rules.complete()) {
            xdg_surface.wm_base_resource.postError(
                .invalid_positioner,
                "incomplete xdg_positioner",
            );
            return error.ResourceCreateFailed;
        }
        if (surface.assignedRole()) |role| if (role != .xdg_popup) {
            xdg_surface.resource.postError(.already_constructed, "wl_surface already has a role");
            return error.ResourceCreateFailed;
        };

        const resource = try xdg.Popup.create(
            xdg_surface.resource.getClient(),
            xdg_surface.resource.getVersion(),
            id,
        );
        errdefer resource.destroy();
        const self = xdg_surface.allocator.create(PopupResource) catch
            return error.OutOfMemory;
        errdefer xdg_surface.allocator.destroy(self);
        const popup_id = xdg_surface.shell.core.createPopup(
            xdg_surface.id,
            if (parent_adapter) |adapter| adapter.id else null,
            rules,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.PopupOrderExhausted => {
                resource.getClient().postImplementationError("xdg popup order exhausted");
                return error.ResourceCreateFailed;
            },
            else => {
                postPopupValidationError(xdg_surface, @errorCast(err));
                return error.ResourceCreateFailed;
            },
        };
        errdefer xdg_surface.shell.core.destroyPopup(popup_id);

        self.* = .{
            .allocator = xdg_surface.allocator,
            .shell = xdg_surface.shell,
            .id = popup_id,
            .xdg_surface_id = xdg_surface.id,
            .xdg_surface_resource = xdg_surface,
        };
        surface.assignReservedRole(.xdg_popup, xdg_surface) catch unreachable;
        xdg_surface.popup_resource = resource;
        resource.setHandler(*PopupResource, handleRequest, handleDestroy, self);
    }

    fn postPopupValidationError(
        xdg_surface: *XdgSurfaceResource,
        err: NeutralXdgShell.PopupValidationError,
    ) void {
        switch (err) {
            error.InvalidPositioner => xdg_surface.wm_base_resource.postError(
                .invalid_positioner,
                "incomplete xdg_positioner",
            ),
            error.ParentMissingRole => xdg_surface.wm_base_resource.postError(
                .invalid_popup_parent,
                "xdg_popup parent has no role",
            ),
            error.ParentUnattached => xdg_surface.wm_base_resource.postError(
                .invalid_popup_parent,
                "xdg_popup parent is not attached",
            ),
            error.InvalidParent, error.InvalidSurface, error.RoleAssigned => xdg_surface.wm_base_resource.postError(
                .invalid_popup_parent,
                "invalid xdg_popup parent",
            ),
        }
    }

    fn handleRequest(
        resource: *xdg.Popup,
        request: xdg.Popup.Request,
        self: *PopupResource,
    ) void {
        switch (request) {
            .destroy => {
                if (!self.shell.core.popupIsTopmost(self.id)) {
                    self.xdg_surface_resource.wm_base_resource.postError(
                        .not_the_topmost_popup,
                        "destroy the topmost xdg_popup first",
                    );
                    return;
                }
                resource.destroy();
            },
            .grab => |grab| {
                const client = self.shell.mature_clients.id(resource.getClient()) orelse return;
                const granted = self.shell.seat.acceptsUserActionSerial(
                    grab.seat,
                    resource.getClient(),
                    grab.serial,
                );
                _ = self.shell.core.grabPopup(self.id, .{
                    .client = client,
                    .serial = MatureSerials.fromWire(grab.serial),
                    .granted = granted,
                }) catch |err| {
                    if (err == error.InvalidPopup) return;
                    resource.postError(.invalid_grab, switch (err) {
                        error.AlreadyMapped => "cannot grab a mapped xdg_popup",
                        error.Unattached => "xdg_popup is not attached",
                        error.InvalidLayerParent => "layer surface parent no longer exists",
                        error.InvalidParent => "xdg_popup parent no longer exists",
                        error.ParentRoleMissing => "xdg_popup parent has no role",
                        error.AnotherGrab => "another xdg_popup owns the grab",
                        error.ParentDoesNotOwnGrab => "parent xdg_popup does not own a grab",
                        error.InvalidPopup => unreachable,
                    });
                    return;
                };
            },
            .reposition => |reposition| {
                if (self.shell.core.popupDismissed(self.id)) return;
                const rules = XdgPositioner.fromResource(reposition.positioner).rules;
                if (!rules.complete()) {
                    self.xdg_surface_resource.wm_base_resource.postError(
                        .invalid_positioner,
                        "incomplete xdg_positioner",
                    );
                    return;
                }
                std.debug.assert(self.reposition_token == null);
                self.reposition_token = reposition.token;
                defer self.reposition_token = null;
                _ = self.shell.core.sendPopupConfigure(self.id, rules) catch |err| switch (err) {
                    error.OutOfMemory => resource.postNoMemory(),
                    error.InvalidParent => self.xdg_surface_resource.wm_base_resource.postError(
                        .invalid_popup_parent,
                        "invalid xdg_popup parent",
                    ),
                    error.InvalidPositioner => self.xdg_surface_resource.wm_base_resource.postError(
                        .invalid_positioner,
                        "invalid xdg_popup positioner",
                    ),
                    error.ConfigureSequenceExhausted => resource.getClient().postImplementationError(
                        "xdg configure sequence exhausted",
                    ),
                };
            },
        }
    }

    fn handleDestroy(_: *xdg.Popup, self: *PopupResource) void {
        if (self.shell.core.surfaceRole(self.xdg_surface_id)) |role| switch (role) {
            .popup => |id| if (std.meta.eql(id, self.id)) {
                self.xdg_surface_resource.popup_resource = null;
                self.xdg_surface_resource.resetWireState();
                self.shell.core.destroyPopup(self.id);
            },
            .toplevel => {},
        };
        self.allocator.destroy(self);
    }
};

const ToplevelDecorationResource = struct {
    allocator: std.mem.Allocator,
    shell: *Self,
    resource: *zxdg.ToplevelDecorationV1,
    toplevel: ?*ToplevelResource,
    configure_sent: bool = false,

    fn create(
        shell: *Self,
        manager: *zxdg.DecorationManagerV1,
        toplevel_resource: *xdg.Toplevel,
        id: u32,
    ) error{ OutOfMemory, ResourceCreateFailed }!void {
        const resource = try zxdg.ToplevelDecorationV1.create(
            manager.getClient(),
            manager.getVersion(),
            id,
        );
        errdefer resource.destroy();

        const data = toplevel_resource.getUserData() orelse {
            resource.postError(.orphaned, "xdg_toplevel no longer exists");
            return;
        };
        const toplevel: *ToplevelResource = @ptrCast(@alignCast(data));
        if (toplevel.shell != shell or toplevel_resource.getClient() != manager.getClient()) {
            resource.postError(.orphaned, "xdg_toplevel belongs to another client");
            return;
        }
        if (toplevel.decoration != null) {
            resource.postError(.already_constructed, "xdg_toplevel already has a decoration object");
            return;
        }
        if (resource.getVersion() == 1) {
            const surface = toplevel.xdg_surface_resource.surface;
            if (surface == null or surface.?.hasBufferAttached()) {
                resource.postError(
                    .unconfigured_buffer,
                    "version 1 decoration created after a buffer was attached",
                );
                return;
            }
        }

        const self = shell.allocator.create(ToplevelDecorationResource) catch
            return error.OutOfMemory;
        self.* = .{
            .allocator = shell.allocator,
            .shell = shell,
            .resource = resource,
            .toplevel = toplevel,
        };
        toplevel.decoration = self;
        const externally_managed = shell.core.createDecoration(toplevel.id);
        if (!externally_managed) self.configureStandalone();
        resource.setHandler(
            *ToplevelDecorationResource,
            handleRequest,
            handleDestroy,
            self,
        );
    }

    fn handleRequest(
        resource: *zxdg.ToplevelDecorationV1,
        request: zxdg.ToplevelDecorationV1.Request,
        self: *ToplevelDecorationResource,
    ) void {
        if (self.toplevel == null and request != .destroy) {
            resource.postError(.orphaned, "xdg_toplevel was destroyed");
            return;
        }
        switch (request) {
            .destroy => resource.destroy(),
            .set_mode => |set| self.setPreference(switch (set.mode) {
                .client_side => .prefers_csd,
                .server_side => .prefers_ssd,
                else => {
                    resource.postError(.invalid_mode, "invalid decoration mode");
                    return;
                },
            }),
            .unset_mode => self.setPreference(.no_preference),
        }
    }

    fn setPreference(
        self: *ToplevelDecorationResource,
        preference: NeutralXdgShell.DecorationPreference,
    ) void {
        const toplevel = self.toplevel orelse return;
        const externally_managed = self.shell.core.setDecorationPreference(toplevel.id, preference);
        if (!externally_managed) self.configureStandalone();
    }

    fn configureStandalone(self: *ToplevelDecorationResource) void {
        const toplevel = self.toplevel orelse return;
        const info = self.shell.core.windowInfo(toplevel.id) orelse return;
        if (!info.ready or !toplevel.xdg_surface_resource.initial_configure_sent) return;
        _ = self.shell.core.configureWindowState(
            toplevel.id,
            info.dimensions orelse .{ .width = 0, .height = 0 },
            .{},
        ) catch |err| switch (err) {
            error.OutOfMemory => self.resource.postNoMemory(),
            error.InvalidWindow, error.ConfigureSequenceExhausted => {},
        };
    }

    fn handleDestroy(_: *zxdg.ToplevelDecorationV1, self: *ToplevelDecorationResource) void {
        if (self.toplevel) |toplevel| {
            toplevel.decoration = null;
            self.shell.core.destroyDecoration(toplevel.id);
        }
        self.allocator.destroy(self);
    }
};

const ToplevelResource = struct {
    allocator: std.mem.Allocator,
    shell: *Self,
    id: NeutralXdgShell.WindowId,
    xdg_surface_id: NeutralXdgShell.XdgSurfaceId,
    xdg_surface_resource: *XdgSurfaceResource,
    decoration: ?*ToplevelDecorationResource,

    fn create(
        xdg_surface: *XdgSurfaceResource,
        id: u32,
    ) error{ OutOfMemory, ResourceCreateFailed }!void {
        const surface = xdg_surface.surface orelse return error.ResourceCreateFailed;
        if (surface.assignedRole()) |role| if (role != .xdg_toplevel) {
            xdg_surface.resource.postError(.already_constructed, "wl_surface already has a role");
            return;
        };

        const resource = try xdg.Toplevel.create(
            xdg_surface.resource.getClient(),
            xdg_surface.resource.getVersion(),
            id,
        );
        errdefer resource.destroy();

        const self = xdg_surface.allocator.create(ToplevelResource) catch
            return error.OutOfMemory;
        errdefer xdg_surface.allocator.destroy(self);

        const window_id = xdg_surface.shell.core.createToplevel(
            xdg_surface.id,
            @intCast(resource.getClient().getCredentials().pid),
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidSurface, error.RoleAssigned => return error.ResourceCreateFailed,
        };
        errdefer xdg_surface.shell.core.destroyToplevel(window_id);

        self.* = .{
            .allocator = xdg_surface.allocator,
            .shell = xdg_surface.shell,
            .id = window_id,
            .xdg_surface_id = xdg_surface.id,
            .xdg_surface_resource = xdg_surface,
            .decoration = null,
        };
        surface.assignReservedRole(.xdg_toplevel, xdg_surface) catch unreachable;
        xdg_surface.toplevel_resource = resource;
        resource.setHandler(*ToplevelResource, handleRequest, handleDestroy, self);
    }

    fn handleRequest(
        resource: *xdg.Toplevel,
        request: xdg.Toplevel.Request,
        self: *ToplevelResource,
    ) void {
        switch (request) {
            .destroy => resource.destroy(),
            .set_parent => |set| self.setParent(resource, set.parent),
            .set_title => |set| self.setText(resource, .title, set.title),
            .set_app_id => |set| self.setText(resource, .app_id, set.app_id),
            .set_max_size => |set| self.shell.core.setPendingMaxSize(self.id, .{
                .width = set.width,
                .height = set.height,
            }),
            .set_min_size => |set| self.shell.core.setPendingMinSize(self.id, .{
                .width = set.width,
                .height = set.height,
            }),
            .show_window_menu => |menu| {
                const action = self.userAction(resource, menu.seat, menu.serial) orelse return;
                self.forwardRequest(.{ .show_window_menu = .{
                    .action = action,
                    .x = menu.x,
                    .y = menu.y,
                } });
            },
            .move => |move| {
                const action = self.userAction(resource, move.seat, move.serial) orelse return;
                self.forwardRequest(.{ .pointer_move = action });
            },
            .resize => |resize| {
                if (!validResizeEdge(resize.edges)) {
                    resource.postError(.invalid_resize_edge, "invalid resize edge");
                    return;
                }
                const edges = resizeEdges(resize.edges);
                if (@as(u4, @bitCast(edges)) == 0) return;
                const action = self.userAction(resource, resize.seat, resize.serial) orelse return;
                self.forwardRequest(.{ .pointer_resize = .{ .action = action, .edges = edges } });
            },
            .set_maximized => {
                self.shell.core.requestMaximized(self.id, true);
                self.forwardRequest(.maximize);
            },
            .unset_maximized => {
                self.shell.core.requestMaximized(self.id, false);
                self.forwardRequest(.unmaximize);
            },
            .set_fullscreen => |fullscreen| {
                const output_id = if (fullscreen.output) |output|
                    if (self.shell.outputs.findResource(output)) |entry| entry.id else null
                else
                    null;
                self.shell.core.requestFullscreen(self.id, true, output_id);
                self.forwardRequest(.{ .fullscreen = output_id });
            },
            .unset_fullscreen => {
                self.shell.core.requestFullscreen(self.id, false, null);
                self.forwardRequest(.exit_fullscreen);
            },
            .set_minimized => {
                self.shell.core.requestMinimized(self.id, true);
                self.forwardRequest(.minimize);
            },
        }
    }

    fn forwardRequest(self: *ToplevelResource, request: NeutralXdgShell.WindowRequest) void {
        const info = self.shell.core.windowInfo(self.id) orelse return;
        if (!info.ready) return;
        self.shell.core.requestWindow(self.id, request);
    }

    fn userAction(
        self: *ToplevelResource,
        resource: *xdg.Toplevel,
        seat: *wl.Seat,
        serial: u32,
    ) ?NeutralXdgShell.UserAction {
        const client = self.shell.mature_clients.id(resource.getClient()) orelse return null;
        return .{
            .client = client,
            .serial = MatureSerials.fromWire(serial),
            .granted = self.shell.seat.acceptsUserActionSerial(seat, resource.getClient(), serial),
        };
    }

    fn handleDestroy(_: *xdg.Toplevel, self: *ToplevelResource) void {
        if (self.decoration) |decoration| {
            decoration.toplevel = null;
            decoration.resource.postError(
                .orphaned,
                "destroy xdg_toplevel_decoration before xdg_toplevel",
            );
        }
        if (self.shell.core.surfaceRole(self.xdg_surface_id)) |role| switch (role) {
            .toplevel => |id| if (std.meta.eql(id, self.id)) {
                self.xdg_surface_resource.toplevel_resource = null;
                self.xdg_surface_resource.resetWireState();
                self.shell.core.destroyToplevel(self.id);
            },
            .popup => {},
        };
        self.allocator.destroy(self);
    }

    fn setText(
        self: *ToplevelResource,
        resource: *xdg.Toplevel,
        field: enum { title, app_id },
        source_z: [*:0]const u8,
    ) void {
        const source = std.mem.span(source_z);
        if (!std.unicode.utf8ValidateSlice(source)) {
            resource.getClient().postImplementationError("xdg_toplevel string is not valid UTF-8");
            return;
        }
        const result = switch (field) {
            .title => self.shell.core.setTitle(self.id, source),
            .app_id => self.shell.core.setAppId(self.id, source),
        };
        result catch {
            resource.postNoMemory();
            return;
        };
    }

    fn setParent(
        self: *ToplevelResource,
        resource: *xdg.Toplevel,
        parent_resource: ?*xdg.Toplevel,
    ) void {
        const parent_id = if (parent_resource) |parent| parent: {
            const adapter: *ToplevelResource = @ptrCast(@alignCast(parent.getUserData().?));
            break :parent adapter.id;
        } else null;
        self.shell.core.setParent(self.id, parent_id) catch
            resource.postError(.invalid_parent, "xdg_toplevel parent cycle");
    }

    fn validResizeEdge(edge: xdg.Toplevel.ResizeEdge) bool {
        return switch (edge) {
            .none,
            .top,
            .bottom,
            .left,
            .top_left,
            .bottom_left,
            .right,
            .top_right,
            .bottom_right,
            => true,
            else => false,
        };
    }

    fn resizeEdges(edge: xdg.Toplevel.ResizeEdge) NeutralXdgShell.ResizeEdges {
        return switch (edge) {
            .none => .{},
            .top => .{ .top = true },
            .bottom => .{ .bottom = true },
            .left => .{ .left = true },
            .top_left => .{ .top = true, .left = true },
            .bottom_left => .{ .bottom = true, .left = true },
            .right => .{ .right = true },
            .top_right => .{ .top = true, .right = true },
            .bottom_right => .{ .bottom = true, .right = true },
            else => unreachable,
        };
    }
};

test "xdg wrapper recreation reserves only compatible permanent roles" {
    try std.testing.expectEqual(
        Surface.Role.xdg_toplevel,
        xdgReservationRole(null).?,
    );
    try std.testing.expectEqual(
        Surface.Role.xdg_toplevel,
        xdgReservationRole(.xdg_toplevel).?,
    );
    try std.testing.expectEqual(
        Surface.Role.xdg_popup,
        xdgReservationRole(.xdg_popup).?,
    );
    try std.testing.expect(xdgReservationRole(.subsurface) == null);
    try std.testing.expect(xdgReservationRole(.cursor) == null);
}

test "popup configure acknowledgements retain the matched placement" {
    var configures: std.ArrayList(Configure) = .empty;
    defer configures.deinit(std.testing.allocator);
    var accepted: ?Configure = null;
    try configures.append(std.testing.allocator, .{
        .serial = 11,
        .token = .{ .surface = undefined, .sequence = 1 },
        .popup = .{
            .rules = .{ .offset = .{ .x = 1, .y = 2 } },
            .placement = .{
                .position = .{ .x = 10, .y = 20 },
                .dimensions = .{ .width = 100, .height = 50 },
            },
        },
    });
    try configures.append(std.testing.allocator, .{
        .serial = 12,
        .token = .{ .surface = undefined, .sequence = 2 },
        .popup = .{
            .rules = .{ .offset = .{ .x = 3, .y = 4 } },
            .placement = .{
                .position = .{ .x = 30, .y = 40 },
                .dimensions = .{ .width = 200, .height = 80 },
            },
        },
    });

    try std.testing.expect(acknowledgeConfigure(&configures, &accepted, 11));
    try std.testing.expectEqual(@as(u32, 11), accepted.?.serial);
    try std.testing.expectEqual(Scene.Position{ .x = 10, .y = 20 }, accepted.?.popup.?.placement.position);
    try std.testing.expectEqual(@as(usize, 1), configures.items.len);
    try std.testing.expectEqual(@as(u32, 12), configures.items[0].serial);
    try std.testing.expect(acknowledgeConfigure(&configures, &accepted, 12));
    try std.testing.expectEqual(@as(u64, 2), accepted.?.token.sequence);
    try std.testing.expectEqual(Scene.Position{ .x = 30, .y = 40 }, accepted.?.popup.?.placement.position);
    try std.testing.expectEqual(@as(usize, 0), configures.items.len);
    try std.testing.expect(!acknowledgeConfigure(&configures, &accepted, 13));
}

test "xdg toplevel states are gated by protocol version" {
    const configuration: NeutralXdgShell.ToplevelConfigure = .{
        .suspended = true,
        .constrained = .{
            .top = true,
            .bottom = true,
            .left = true,
            .right = true,
        },
    };
    var values: [13]u32 = undefined;

    try std.testing.expectEqualSlices(u32, &.{}, toplevelStates(configuration, 5, &values));
    try std.testing.expectEqualSlices(u32, &.{
        @intFromEnum(xdg.Toplevel.State.suspended),
    }, toplevelStates(configuration, 6, &values));
    try std.testing.expectEqualSlices(u32, &.{
        @intFromEnum(xdg.Toplevel.State.suspended),
        @intFromEnum(xdg.Toplevel.State.constrained_left),
        @intFromEnum(xdg.Toplevel.State.constrained_right),
        @intFromEnum(xdg.Toplevel.State.constrained_top),
        @intFromEnum(xdg.Toplevel.State.constrained_bottom),
    }, toplevelStates(configuration, 7, &values));
}

test "xdg size hints validate committed bounds" {
    try std.testing.expect(NeutralXdgShell.validSizeHints(
        .{ .width = 50, .height = 50 },
        .{ .width = 100, .height = 100 },
    ));
    try std.testing.expect(!NeutralXdgShell.validSizeHints(
        .{ .width = 50, .height = 50 },
        .{ .width = 40, .height = 100 },
    ));
    try std.testing.expect(!NeutralXdgShell.validSizeHints(
        .{ .width = -1, .height = 0 },
        .{},
    ));
    try std.testing.expect(!NeutralXdgShell.validSizeHints(
        .{},
        .{ .width = 0, .height = -1 },
    ));
}

test "xdg resize edges translate to independent policy edge flags" {
    try std.testing.expectEqual(
        NeutralXdgShell.ResizeEdges{ .top = true, .left = true },
        ToplevelResource.resizeEdges(.top_left),
    );
    try std.testing.expectEqual(
        NeutralXdgShell.ResizeEdges{ .bottom = true, .right = true },
        ToplevelResource.resizeEdges(.bottom_right),
    );
    try std.testing.expectEqual(NeutralXdgShell.ResizeEdges{}, ToplevelResource.resizeEdges(.none));
}
