//! GTK-specific surface metadata and configure-state compatibility.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Seat = @import("seat.zig");
const Surface = @import("surface.zig");

const gtk = wayland.server.gtk;
const wl = wayland.server.wl;

allocator: std.mem.Allocator,
global: *wl.Global,
seat: *Seat,
bindings: usize,
surfaces: std.ArrayList(*GtkSurface),

pub const TiledEdges = packed struct(u4) {
    top: bool = false,
    right: bool = false,
    bottom: bool = false,
    left: bool = false,
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    seat: *Seat,
) !void {
    self.* = .{
        .allocator = allocator,
        .global = try wl.Global.create(display, gtk.Shell1, 5, *Self, self, bind),
        .seat = seat,
        .bindings = 0,
        .surfaces = .empty,
    };
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.bindings == 0);
    std.debug.assert(self.surfaces.items.len == 0);
    self.global.destroy();
    self.surfaces.deinit(self.allocator);
    self.* = undefined;
}

pub fn configureSurface(self: *Self, surface_id: Surface.Id, tiled: TiledEdges) void {
    for (self.surfaces.items) |surface| {
        if (surface.surface_resource != null and std.meta.eql(surface.surface_id, surface_id)) {
            surface.configure(tiled);
        }
    }
}

pub fn isModal(self: *const Self, surface_id: Surface.Id) bool {
    for (self.surfaces.items) |surface| {
        if (surface.surface_resource != null and surface.modal and
            std.meta.eql(surface.surface_id, surface_id)) return true;
    }
    return false;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    Binding.create(self, client, version, id) catch client.postNoMemory();
}

const Binding = struct {
    manager: *Self,
    startup_id: ?[:0]u8,

    fn create(
        manager: *Self,
        client: *wl.Client,
        version: u32,
        id: u32,
    ) error{ OutOfMemory, ResourceCreateFailed }!void {
        const resource = try gtk.Shell1.create(client, version, id);
        errdefer resource.destroy();
        const self = manager.allocator.create(Binding) catch return error.OutOfMemory;
        self.* = .{ .manager = manager, .startup_id = null };
        manager.bindings += 1;
        resource.setHandler(*Binding, handleRequest, handleDestroy, self);
        resource.sendCapabilities(0);
    }

    fn handleRequest(
        resource: *gtk.Shell1,
        request: gtk.Shell1.Request,
        self: *Binding,
    ) void {
        switch (request) {
            .get_gtk_surface => |get| GtkSurface.create(
                self.manager,
                resource,
                get.gtk_surface,
                get.surface,
            ) catch resource.postNoMemory(),
            .set_startup_id => |set| self.setStartupId(resource, set.startup_id),
            .system_bell => {},
            .notify_launch => |notify| {
                if (!validText(notify.startup_id)) {
                    resource.getClient().postImplementationError(
                        "gtk_shell1 startup ID is not valid UTF-8",
                    );
                }
            },
        }
    }

    fn setStartupId(
        self: *Binding,
        resource: *gtk.Shell1,
        startup_id: ?[*:0]const u8,
    ) void {
        const replacement = copyOptionalText(self.manager.allocator, startup_id) catch |err| {
            switch (err) {
                error.OutOfMemory => resource.postNoMemory(),
                error.InvalidUtf8 => resource.getClient().postImplementationError(
                    "gtk_shell1 startup ID is not valid UTF-8",
                ),
            }
            return;
        };
        freeOptionalText(self.manager.allocator, self.startup_id);
        self.startup_id = replacement;
    }

    fn handleDestroy(_: *gtk.Shell1, self: *Binding) void {
        freeOptionalText(self.manager.allocator, self.startup_id);
        std.debug.assert(self.manager.bindings > 0);
        self.manager.bindings -= 1;
        self.manager.allocator.destroy(self);
    }
};

const DbusProperties = struct {
    application_id: ?[:0]u8 = null,
    app_menu_path: ?[:0]u8 = null,
    menubar_path: ?[:0]u8 = null,
    window_object_path: ?[:0]u8 = null,
    application_object_path: ?[:0]u8 = null,
    unique_bus_name: ?[:0]u8 = null,

    fn init(
        allocator: std.mem.Allocator,
        application_id: ?[*:0]const u8,
        app_menu_path: ?[*:0]const u8,
        menubar_path: ?[*:0]const u8,
        window_object_path: ?[*:0]const u8,
        application_object_path: ?[*:0]const u8,
        unique_bus_name: ?[*:0]const u8,
    ) error{ OutOfMemory, InvalidUtf8 }!DbusProperties {
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
    manager: *Self,
    resource: *gtk.Surface1,
    surface_resource: ?*wl.Surface,
    surface_id: Surface.Id,
    surface_destroy_listener: wl.Listener(*wl.Resource),
    properties: DbusProperties,
    modal: bool,

    fn create(
        manager: *Self,
        shell_resource: *gtk.Shell1,
        id: u32,
        surface_resource: *wl.Surface,
    ) error{ OutOfMemory, ResourceCreateFailed }!void {
        const resource = try gtk.Surface1.create(
            shell_resource.getClient(),
            shell_resource.getVersion(),
            id,
        );
        errdefer resource.destroy();
        const self = manager.allocator.create(GtkSurface) catch return error.OutOfMemory;
        errdefer manager.allocator.destroy(self);
        self.* = .{
            .manager = manager,
            .resource = resource,
            .surface_resource = surface_resource,
            .surface_id = Surface.fromResource(surface_resource).handle(),
            .surface_destroy_listener = wl.Listener(*wl.Resource).init(handleSurfaceDestroyed),
            .properties = .{},
            .modal = false,
        };
        @as(*wl.Resource, @ptrCast(surface_resource)).addDestroyListener(
            &self.surface_destroy_listener,
        );
        errdefer self.surface_destroy_listener.link.remove();
        try manager.surfaces.append(manager.allocator, self);
        resource.setHandler(*GtkSurface, handleRequest, handleDestroy, self);
    }

    fn handleRequest(
        resource: *gtk.Surface1,
        request: gtk.Surface1.Request,
        self: *GtkSurface,
    ) void {
        switch (request) {
            .set_dbus_properties => |set| {
                const replacement = DbusProperties.init(
                    self.manager.allocator,
                    set.application_id,
                    set.app_menu_path,
                    set.menubar_path,
                    set.window_object_path,
                    set.application_object_path,
                    set.unique_bus_name,
                ) catch |err| {
                    switch (err) {
                        error.OutOfMemory => resource.postNoMemory(),
                        error.InvalidUtf8 => resource.getClient().postImplementationError(
                            "gtk_surface1 D-Bus property is not valid UTF-8",
                        ),
                    }
                    return;
                };
                self.properties.deinit(self.manager.allocator);
                self.properties = replacement;
            },
            .set_modal => self.modal = true,
            .unset_modal => self.modal = false,
            .present => {},
            .request_focus => |focus| {
                if (focus.startup_id) |startup_id| {
                    if (!validText(startup_id)) {
                        resource.getClient().postImplementationError(
                            "gtk_surface1 startup ID is not valid UTF-8",
                        );
                    }
                }
            },
            .release => resource.destroy(),
            .titlebar_gesture => |titlebar| {
                if (!validGesture(titlebar.gesture)) {
                    resource.postError(.invalid_gesture, "invalid GTK titlebar gesture");
                    return;
                }
                if (self.surface_resource == null or
                    !self.manager.seat.ownsResource(titlebar.seat) or
                    !self.manager.seat.acceptsPointerGrabSerial(
                        resource.getClient(),
                        self.surface_id,
                        titlebar.serial,
                    )) return;

                // GTK titlebar gestures are advisory. Keywork has no titlebar
                // action policy, so authenticated gestures are accepted.
            },
        }
    }

    fn configure(self: *GtkSurface, tiled: TiledEdges) void {
        var state_values: [5]u32 = undefined;
        const states = configureStates(tiled, self.resource.getVersion(), &state_values);
        var states_array = protocolArray(states);
        self.resource.sendConfigure(&states_array);
        if (self.resource.getVersion() < 2) return;

        var constraint_values: [4]u32 = undefined;
        const constraints = edgeConstraints(tiled, &constraint_values);
        var constraints_array = protocolArray(constraints);
        self.resource.sendConfigureEdges(&constraints_array);
    }

    fn handleDestroy(_: *gtk.Surface1, self: *GtkSurface) void {
        if (self.surface_resource != null) self.surface_destroy_listener.link.remove();
        self.properties.deinit(self.manager.allocator);
        for (self.manager.surfaces.items, 0..) |surface, index| {
            if (surface != self) continue;
            _ = self.manager.surfaces.orderedRemove(index);
            self.manager.allocator.destroy(self);
            return;
        }
        unreachable;
    }

    fn handleSurfaceDestroyed(listener: *wl.Listener(*wl.Resource), _: *wl.Resource) void {
        const self: *GtkSurface = @fieldParentPtr("surface_destroy_listener", listener);
        listener.link.remove();
        self.surface_resource = null;
    }
};

fn configureStates(tiled: TiledEdges, version: u32, values: *[5]u32) []u32 {
    var count: usize = 0;
    if (hasTiledEdge(tiled)) appendEnum(values, &count, gtk.Surface1.State.tiled);
    if (version >= 2) {
        if (tiled.top) appendEnum(values, &count, gtk.Surface1.State.tiled_top);
        if (tiled.right) appendEnum(values, &count, gtk.Surface1.State.tiled_right);
        if (tiled.bottom) appendEnum(values, &count, gtk.Surface1.State.tiled_bottom);
        if (tiled.left) appendEnum(values, &count, gtk.Surface1.State.tiled_left);
    }
    return values[0..count];
}

fn edgeConstraints(tiled: TiledEdges, values: *[4]u32) []u32 {
    if (hasTiledEdge(tiled)) return values[0..0];
    values.* = .{
        @intCast(@intFromEnum(gtk.Surface1.EdgeConstraint.resizable_top)),
        @intCast(@intFromEnum(gtk.Surface1.EdgeConstraint.resizable_right)),
        @intCast(@intFromEnum(gtk.Surface1.EdgeConstraint.resizable_bottom)),
        @intCast(@intFromEnum(gtk.Surface1.EdgeConstraint.resizable_left)),
    };
    return values;
}

fn protocolArray(values: []u32) wl.Array {
    return .{
        .size = values.len * @sizeOf(u32),
        .alloc = values.len * @sizeOf(u32),
        .data = if (values.len == 0) null else @ptrCast(values.ptr),
    };
}

fn appendEnum(values: anytype, count: *usize, value: anytype) void {
    std.debug.assert(count.* < values.len);
    values[count.*] = @intCast(@intFromEnum(value));
    count.* += 1;
}

fn hasTiledEdge(tiled: TiledEdges) bool {
    return @as(u4, @bitCast(tiled)) != 0;
}

fn validGesture(gesture: gtk.Surface1.Gesture) bool {
    return switch (gesture) {
        .double_click, .right_click, .middle_click => true,
        else => false,
    };
}

fn validText(text: [*:0]const u8) bool {
    return std.unicode.utf8ValidateSlice(std.mem.span(text));
}

fn copyOptionalText(
    allocator: std.mem.Allocator,
    text: ?[*:0]const u8,
) error{ OutOfMemory, InvalidUtf8 }!?[:0]u8 {
    const value = text orelse return null;
    const slice = std.mem.span(value);
    if (!std.unicode.utf8ValidateSlice(slice)) return error.InvalidUtf8;
    return @as(?[:0]u8, try allocator.dupeSentinel(u8, slice, 0));
}

fn freeOptionalText(allocator: std.mem.Allocator, text: ?[:0]u8) void {
    if (text) |value| allocator.free(value);
}

test "GTK configure states preserve legacy and per-edge tiling" {
    var values: [5]u32 = undefined;
    try std.testing.expectEqualSlices(u32, &.{}, configureStates(.{}, 5, &values));
    try std.testing.expectEqualSlices(
        u32,
        &.{@intFromEnum(gtk.Surface1.State.tiled)},
        configureStates(.{ .top = true, .left = true }, 1, &values),
    );
    try std.testing.expectEqualSlices(
        u32,
        &.{
            @intFromEnum(gtk.Surface1.State.tiled),
            @intFromEnum(gtk.Surface1.State.tiled_top),
            @intFromEnum(gtk.Surface1.State.tiled_left),
        },
        configureStates(.{ .top = true, .left = true }, 2, &values),
    );
}

test "GTK floating surfaces advertise every resizable edge" {
    var values: [4]u32 = undefined;
    try std.testing.expectEqualSlices(
        u32,
        &.{
            @intFromEnum(gtk.Surface1.EdgeConstraint.resizable_top),
            @intFromEnum(gtk.Surface1.EdgeConstraint.resizable_right),
            @intFromEnum(gtk.Surface1.EdgeConstraint.resizable_bottom),
            @intFromEnum(gtk.Surface1.EdgeConstraint.resizable_left),
        },
        edgeConstraints(.{}, &values),
    );
    try std.testing.expectEqualSlices(
        u32,
        &.{},
        edgeConstraints(.{ .bottom = true }, &values),
    );
}

test "GTK titlebar gestures reject unknown enum values" {
    try std.testing.expect(validGesture(.double_click));
    try std.testing.expect(validGesture(.right_click));
    try std.testing.expect(validGesture(.middle_click));
    try std.testing.expect(!validGesture(@enumFromInt(99)));
}
