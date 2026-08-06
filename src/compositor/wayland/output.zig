//! wl_output advertisement for a compositor output.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const presentation = @import("../presentation.zig");
const render = @import("../render/types.zig");
const SurfaceRegistry = @import("../SurfaceRegistry.zig");
const Surface = @import("surface.zig");

const wl = wayland.server.wl;

allocator: std.mem.Allocator,
global: *wl.Global,
position: Position,
size: render.Size,
mode_size: render.Size,
physical_size: render.Size,
mode_preferred: bool,
scale: i32,
preferred_scale: render.Scale,
color_description: render.ColorDescription,
color_identity: u64,
refresh_millihertz: i32,
name_value: [:0]u8,
description_value: [:0]u8,
make: [:0]u8,
model: [:0]u8,
resources: std.ArrayList(*wl.Output),
surface_registry: *SurfaceRegistry,
surfaces: *Surface.Store,
memberships: std.ArrayList(Membership),
frame_active: bool,
bind_listener: ?BindListener,
delivery_listener: ?DeliveryListener,
notifying_delivery: bool,

pub const Position = struct {
    x: i32 = 0,
    y: i32 = 0,
};

/// Returns whether the positive-area logical bounds, including their
/// exclusive right and bottom edges, are representable as i32 coordinates.
pub fn logicalGeometryValid(position: Position, size: render.Size) bool {
    return size.width > 0 and size.height > 0 and
        size.width <= std.math.maxInt(i32) and size.height <= std.math.maxInt(i32) and
        @as(i64, position.x) + size.width <= std.math.maxInt(i32) and
        @as(i64, position.y) + size.height <= std.math.maxInt(i32);
}

pub const Config = struct {
    position: Position = .{},
    size: render.Size,
    mode_size: ?render.Size = null,
    physical_size: render.Size,
    mode_preferred: bool = true,
    refresh_millihertz: i32 = 60_000,
    scale: u32,
    preferred_scale: render.Scale = .{},
    color_description: render.ColorDescription = .{},
    color_identity: u64 = 1,
    name: []const u8,
    description: []const u8,
    make: []const u8 = "keywork",
    model: []const u8,
};

pub const BindListener = struct {
    context: *anyopaque,
    bound: *const fn (*anyopaque, *Self, *wl.Output) void,
};

/// Resource-free output state borrowed only for a synchronous delivery
/// callback. String slices remain owned by Output.
pub const Snapshot = struct {
    position: Position,
    size: render.Size,
    mode_size: render.Size,
    physical_size: render.Size,
    mode_preferred: bool,
    scale: i32,
    preferred_scale: render.Scale,
    color_description: render.ColorDescription,
    color_identity: u64,
    refresh_millihertz: i32,
    name: []const u8,
    description: []const u8,
    make: []const u8,
    model: []const u8,
};

pub const Changes = packed struct {
    geometry: bool = false,
    mode: bool = false,
    scale: bool = false,
    preferred_scale: bool = false,
};

/// Synchronous frontend fanout seam. Callbacks receive canonical surface IDs
/// and immutable output state, never Wayland resources. They must not reenter
/// output configuration or membership mutation.
pub const DeliveryListener = struct {
    context: *anyopaque,
    configured: *const fn (*anyopaque, Snapshot, Changes) void,
    entered: *const fn (*anyopaque, SurfaceRegistry.Id) void,
    left: *const fn (*anyopaque, SurfaceRegistry.Id) void,
};

const Membership = struct {
    surface_id: SurfaceRegistry.Id,
    visible: bool,
    announced: bool,
};

pub const MembershipIterator = struct {
    memberships: []const Membership,
    index: usize = 0,

    pub fn next(self: *MembershipIterator) ?SurfaceRegistry.Id {
        if (self.index >= self.memberships.len) return null;
        defer self.index += 1;
        return self.memberships[self.index].surface_id;
    }
};

pub const Error = error{
    OutOfMemory,
    InvalidDimensions,
    GlobalCreateFailed,
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    config: Config,
    surface_registry: *SurfaceRegistry,
    surfaces: *Surface.Store,
) Error!void {
    const mode_size = config.mode_size orelse config.size;
    if (!logicalGeometryValid(config.position, config.size) or
        mode_size.width == 0 or mode_size.height == 0 or
        mode_size.width > std.math.maxInt(i32) or mode_size.height > std.math.maxInt(i32) or
        config.scale == 0 or config.scale > std.math.maxInt(i32) or
        config.preferred_scale.numerator == 0 or
        config.physical_size.width == 0 or config.physical_size.height == 0 or
        config.physical_size.width > std.math.maxInt(i32) or
        config.physical_size.height > std.math.maxInt(i32))
    {
        return error.InvalidDimensions;
    }

    const name_value = try allocator.dupeSentinel(u8, config.name, 0);
    errdefer allocator.free(name_value);
    const description_value = try allocator.dupeSentinel(u8, config.description, 0);
    errdefer allocator.free(description_value);
    const make = try allocator.dupeSentinel(u8, config.make, 0);
    errdefer allocator.free(make);
    const model = try allocator.dupeSentinel(u8, config.model, 0);
    errdefer allocator.free(model);

    self.* = .{
        .allocator = allocator,
        .global = try wl.Global.create(display, wl.Output, 4, *Self, self, bind),
        .position = config.position,
        .size = config.size,
        .mode_size = mode_size,
        .physical_size = config.physical_size,
        .mode_preferred = config.mode_preferred,
        .scale = @intCast(config.scale),
        .preferred_scale = config.preferred_scale,
        .color_description = config.color_description,
        .color_identity = config.color_identity,
        .refresh_millihertz = config.refresh_millihertz,
        .name_value = name_value,
        .description_value = description_value,
        .make = make,
        .model = model,
        .resources = .empty,
        .surface_registry = surface_registry,
        .surfaces = surfaces,
        .memberships = .empty,
        .frame_active = false,
        .bind_listener = null,
        .delivery_listener = null,
        .notifying_delivery = false,
    };
}

pub fn deinit(self: *Self) void {
    std.debug.assert(!self.frame_active);
    std.debug.assert(self.bind_listener == null);
    std.debug.assert(self.delivery_listener == null);
    std.debug.assert(!self.notifying_delivery);
    while (self.resources.items.len > 0) self.resources.items[0].destroy();
    self.global.destroy();
    self.resources.deinit(self.allocator);
    self.memberships.deinit(self.allocator);
    self.allocator.free(self.model);
    self.allocator.free(self.make);
    self.allocator.free(self.description_value);
    self.allocator.free(self.name_value);
    self.* = undefined;
}

pub fn retire(self: *Self) void {
    std.debug.assert(!self.frame_active);
    std.debug.assert(self.bind_listener == null);
    self.global.remove();
    for (self.memberships.items) |membership| {
        const surface = Surface.resourceFor(self.surfaces, membership.surface_id) orelse continue;
        for (self.resources.items) |resource| {
            if (resource.getClient() == surface.getClient()) surface.sendLeave(resource);
        }
    }
    self.memberships.clearRetainingCapacity();
    for (self.resources.items) |resource| makeResourceInert(resource);
    self.resources.clearRetainingCapacity();
}

pub fn globalName(self: *const Self, client: *const wl.Client) u32 {
    return self.global.getName(client);
}

pub fn logicalSize(self: *const Self) render.Size {
    return self.size;
}

pub fn logicalPosition(self: *const Self) Position {
    return self.position;
}

pub fn snapshot(self: *const Self) Snapshot {
    return .{
        .position = self.position,
        .size = self.size,
        .mode_size = self.mode_size,
        .physical_size = self.physical_size,
        .mode_preferred = self.mode_preferred,
        .scale = self.scale,
        .preferred_scale = self.preferred_scale,
        .color_description = self.color_description,
        .color_identity = self.color_identity,
        .refresh_millihertz = self.refresh_millihertz,
        .name = self.name_value,
        .description = self.description_value,
        .make = self.make,
        .model = self.model,
    };
}

/// Replaces output geometry and mode state and advertises changed properties.
/// The caller must finish related extension updates with sendDone().
pub fn configure(
    self: *Self,
    position: Position,
    size: render.Size,
    mode_size: render.Size,
    refresh_millihertz: i32,
    preferred: bool,
    scale: u32,
    preferred_scale: render.Scale,
) bool {
    std.debug.assert(!self.notifying_delivery);
    std.debug.assert(logicalGeometryValid(position, size));
    std.debug.assert(mode_size.width > 0 and mode_size.height > 0);
    std.debug.assert(scale > 0 and scale <= std.math.maxInt(i32));
    std.debug.assert(preferred_scale.numerator > 0);
    const position_changed = !std.meta.eql(self.position, position);
    const mode_changed = !std.meta.eql(self.mode_size, mode_size) or
        self.refresh_millihertz != refresh_millihertz or
        self.mode_preferred != preferred;
    const client_scale_changed = self.scale != scale;
    const preferred_scale_changed = self.preferred_scale.numerator != preferred_scale.numerator;
    self.position = position;
    self.size = size;
    self.mode_size = mode_size;
    self.refresh_millihertz = refresh_millihertz;
    self.mode_preferred = preferred;
    self.scale = @intCast(scale);
    self.preferred_scale = preferred_scale;
    if (!position_changed and !mode_changed and !client_scale_changed and !preferred_scale_changed) return false;
    for (self.resources.items) |resource| {
        if (position_changed) self.sendGeometry(resource);
        if (mode_changed) self.sendMode(resource);
        if (client_scale_changed and resource.getVersion() >= wl.Output.scale_since_version) {
            resource.sendScale(self.scale);
        }
    }
    self.notifyConfigured(.{
        .geometry = position_changed,
        .mode = mode_changed,
        .scale = client_scale_changed,
        .preferred_scale = preferred_scale_changed,
    });
    return mode_changed;
}

pub fn preferredScale(self: *const Self) render.Scale {
    return self.preferred_scale;
}

pub fn colorDescription(self: *const Self) render.ColorDescription {
    return self.color_description;
}

pub fn colorIdentity(self: *const Self) u64 {
    return self.color_identity;
}

pub fn setColorDescription(
    self: *Self,
    color_description: render.ColorDescription,
    identity: u64,
) bool {
    std.debug.assert(identity != 0);
    if (std.meta.eql(self.color_description, color_description) and
        self.color_identity == identity) return false;
    self.color_description = color_description;
    self.color_identity = identity;
    return true;
}

pub fn sendDone(self: *Self) void {
    for (self.resources.items) |resource| {
        if (resource.getVersion() >= wl.Output.done_since_version) resource.sendDone();
    }
}

pub fn clientScale(self: *const Self) u32 {
    return @intCast(self.scale);
}

pub fn logicalRect(self: *const Self) render.Rect {
    return .{
        .x = self.position.x,
        .y = self.position.y,
        .width = self.size.width,
        .height = self.size.height,
    };
}

pub fn name(self: *const Self) [:0]const u8 {
    return self.name_value;
}

pub fn description(self: *const Self) [:0]const u8 {
    return self.description_value;
}

pub fn ownsResource(self: *Self, resource: *wl.Output) bool {
    return resource.getUserData() == @as(?*anyopaque, @ptrCast(self));
}

pub fn boundResources(self: *const Self) []const *wl.Output {
    return self.resources.items;
}

/// Copies the listener and retains its context until clearBindListener or deinit.
pub fn setBindListener(self: *Self, listener: BindListener) void {
    std.debug.assert(self.bind_listener == null);
    self.bind_listener = listener;
}

pub fn clearBindListener(self: *Self) void {
    std.debug.assert(self.bind_listener != null);
    self.bind_listener = null;
}

/// Installs one resource-free frontend delivery listener. The listener must be
/// cleared before Output retirement or deinitialization.
pub fn setDeliveryListener(self: *Self, listener: DeliveryListener) void {
    std.debug.assert(self.delivery_listener == null);
    std.debug.assert(!self.notifying_delivery);
    self.delivery_listener = listener;
}

pub fn clearDeliveryListener(self: *Self) void {
    std.debug.assert(self.delivery_listener != null);
    std.debug.assert(!self.notifying_delivery);
    self.delivery_listener = null;
}

pub fn setRefresh(self: *Self, info: presentation.Info) void {
    std.debug.assert(!self.notifying_delivery);
    const refresh_millihertz: i32 = @intCast(@min(
        info.refreshMillihertz(),
        std.math.maxInt(i32),
    ));
    if (self.refresh_millihertz == refresh_millihertz) return;
    self.refresh_millihertz = refresh_millihertz;
    for (self.resources.items) |resource| {
        self.sendMode(resource);
        if (resource.getVersion() >= wl.Output.done_since_version) resource.sendDone();
    }
    self.notifyConfigured(.{ .mode = true });
}

pub fn beginFrame(self: *Self) void {
    std.debug.assert(!self.notifying_delivery);
    std.debug.assert(!self.frame_active);
    for (self.memberships.items) |*membership| membership.visible = false;
    self.frame_active = true;
}

pub fn markSurfaceVisible(self: *Self, surface_id: SurfaceRegistry.Id) error{OutOfMemory}!void {
    std.debug.assert(!self.notifying_delivery);
    std.debug.assert(self.frame_active);
    std.debug.assert(self.surface_registry.contains(surface_id));
    for (self.memberships.items) |*membership| {
        if (!std.meta.eql(membership.surface_id, surface_id)) continue;
        membership.visible = true;
        return;
    }

    try self.memberships.append(self.allocator, .{
        .surface_id = surface_id,
        .visible = true,
        .announced = false,
    });
}

pub fn endFrame(self: *Self) void {
    std.debug.assert(!self.notifying_delivery);
    std.debug.assert(self.frame_active);
    var index = self.memberships.items.len;
    while (index > 0) {
        index -= 1;
        const membership = &self.memberships.items[index];
        if (membership.visible and self.surface_registry.contains(membership.surface_id)) {
            if (!membership.announced) {
                if (Surface.resourceFor(self.surfaces, membership.surface_id)) |surface| {
                    for (self.resources.items) |resource| {
                        if (resource.getClient() == surface.getClient()) surface.sendEnter(resource);
                    }
                }
                self.notifyMembership(membership.surface_id, true);
                membership.announced = true;
            }
            continue;
        }
        if (membership.announced) {
            if (Surface.resourceFor(self.surfaces, membership.surface_id)) |surface| {
                for (self.resources.items) |resource| {
                    if (resource.getClient() == surface.getClient()) surface.sendLeave(resource);
                }
            }
        }
        const removed = self.memberships.orderedRemove(index);
        if (removed.announced) self.notifyMembership(removed.surface_id, false);
    }
    self.frame_active = false;
    for (self.memberships.items, 0..) |membership, membership_index| {
        std.debug.assert(membership.announced);
        std.debug.assert(self.surface_registry.contains(membership.surface_id));
        for (self.memberships.items[membership_index + 1 ..]) |candidate|
            std.debug.assert(!std.meta.eql(membership.surface_id, candidate.surface_id));
    }
}

pub fn cancelFrame(self: *Self) void {
    std.debug.assert(!self.notifying_delivery);
    std.debug.assert(self.frame_active);
    var index = self.memberships.items.len;
    while (index > 0) {
        index -= 1;
        if (!self.memberships.items[index].announced) {
            _ = self.memberships.orderedRemove(index);
        } else self.memberships.items[index].visible = true;
    }
    self.frame_active = false;
}

pub fn containsSurface(self: *const Self, surface_id: SurfaceRegistry.Id) bool {
    for (self.memberships.items) |membership| {
        if (std.meta.eql(membership.surface_id, surface_id)) return true;
    }
    return false;
}

pub fn membershipIterator(self: *const Self) MembershipIterator {
    std.debug.assert(!self.frame_active);
    return .{ .memberships = self.memberships.items };
}

pub fn hasCallbackOnlyFrameCallbacks(self: *const Self) bool {
    for (self.memberships.items) |membership| {
        if (Surface.hasCallbackOnlyFrameCallback(self.surfaces, membership.surface_id)) {
            return true;
        }
    }
    return false;
}

pub fn sendCallbackOnlyFrameCallbacks(self: *Self, time_milliseconds: u32) bool {
    std.debug.assert(!self.frame_active);
    var sent = false;
    for (self.memberships.items) |membership| {
        sent = Surface.sendCallbackOnlyFrameDoneFor(
            self.surfaces,
            membership.surface_id,
            time_milliseconds,
        ) or sent;
    }
    return sent;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = wl.Output.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    self.resources.append(self.allocator, resource) catch {
        resource.postNoMemory();
        resource.destroy();
        return;
    };
    resource.setHandler(*Self, handleRequest, handleDestroy, self);
    self.sendGeometry(resource);
    self.sendMode(resource);
    if (version >= wl.Output.scale_since_version) resource.sendScale(self.scale);
    if (version >= wl.Output.name_since_version) {
        resource.sendName(self.name_value);
        resource.sendDescription(self.description_value);
    }
    if (version >= wl.Output.done_since_version) resource.sendDone();
    for (self.memberships.items) |membership| {
        const surface = Surface.resourceFor(self.surfaces, membership.surface_id) orelse continue;
        if (surface.getClient() == client) surface.sendEnter(resource);
    }
    if (self.bind_listener) |listener| listener.bound(listener.context, self, resource);
}

fn sendGeometry(self: *const Self, resource: *wl.Output) void {
    resource.sendGeometry(
        self.position.x,
        self.position.y,
        @intCast(self.physical_size.width),
        @intCast(self.physical_size.height),
        .unknown,
        self.make,
        self.model,
        .normal,
    );
}

fn sendMode(self: *const Self, resource: *wl.Output) void {
    resource.sendMode(
        .{ .current = true, .preferred = self.mode_preferred },
        @intCast(self.mode_size.width),
        @intCast(self.mode_size.height),
        self.refresh_millihertz,
    );
}

fn notifyConfigured(self: *Self, changes: Changes) void {
    const listener = self.delivery_listener orelse return;
    std.debug.assert(!self.notifying_delivery);
    self.notifying_delivery = true;
    defer self.notifying_delivery = false;
    listener.configured(listener.context, self.snapshot(), changes);
}

fn notifyMembership(self: *Self, surface_id: SurfaceRegistry.Id, entered: bool) void {
    const listener = self.delivery_listener orelse return;
    std.debug.assert(!self.notifying_delivery);
    self.notifying_delivery = true;
    defer self.notifying_delivery = false;
    if (entered) listener.entered(listener.context, surface_id) else listener.left(listener.context, surface_id);
}

fn handleRequest(resource: *wl.Output, request: wl.Output.Request, _: *Self) void {
    switch (request) {
        .release => resource.destroy(),
    }
}

fn handleDestroy(resource: *wl.Output, self: *Self) void {
    for (self.resources.items, 0..) |candidate, index| {
        if (candidate != resource) continue;
        _ = self.resources.orderedRemove(index);
        return;
    }
    unreachable;
}

fn makeResourceInert(resource: *wl.Output) void {
    resource.setHandler(?*anyopaque, inertRequest, null, null);
}

fn inertRequest(resource: *wl.Output, request: wl.Output.Request, _: ?*anyopaque) void {
    switch (request) {
        .release => resource.destroy(),
    }
}

test "logical output geometry requires representable exclusive edges" {
    try std.testing.expect(logicalGeometryValid(
        .{ .x = std.math.maxInt(i32) - 1, .y = std.math.minInt(i32) },
        .{ .width = 1, .height = std.math.maxInt(i32) },
    ));
    try std.testing.expect(!logicalGeometryValid(
        .{ .x = std.math.maxInt(i32) },
        .{ .width = 1, .height = 1 },
    ));
    try std.testing.expect(!logicalGeometryValid(
        .{ .y = std.math.maxInt(i32) - 10 },
        .{ .width = 1, .height = 11 },
    ));
    try std.testing.expect(!logicalGeometryValid(.{}, .{ .width = 0, .height = 1 }));
}

test "retiring an output leaves client-owned resources alive" {
    const display = try wl.Server.create();
    defer display.destroy();

    var sockets: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM | std.c.SOCK.CLOEXEC, 0, &sockets),
    );
    defer _ = std.c.close(sockets[1]);
    const client = wl.Client.create(display, sockets[0]) orelse return error.OutOfMemory;
    defer client.destroy();

    var surfaces: Surface.Store = .{};
    defer surfaces.deinit(std.testing.allocator);
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();

    var output: Self = undefined;
    try output.init(
        std.testing.allocator,
        display,
        .{
            .size = .{ .width = 1280, .height = 720 },
            .physical_size = .{ .width = 1280, .height = 720 },
            .scale = 1,
            .name = "HEADLESS-1",
            .description = "Keywork headless output",
            .model = "headless",
        },
        &surface_registry,
        &surfaces,
    );
    defer output.deinit();

    const resource = try wl.Output.create(client, 4, 0);
    try output.resources.append(std.testing.allocator, resource);
    resource.setHandler(*Self, handleRequest, handleDestroy, &output);
    const resource_id = resource.getId();
    try std.testing.expect(client.getObject(resource_id) != null);

    output.retire();
    try std.testing.expect(client.getObject(resource_id) != null);
    inertRequest(resource, .release, null);
    try std.testing.expect(client.getObject(resource_id) == null);
}

test "frame membership removes surfaces which are no longer visible" {
    const display = try wl.Server.create();
    defer display.destroy();

    var surfaces: Surface.Store = .{};
    defer surfaces.deinit(std.testing.allocator);
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();

    var output: Self = undefined;
    try output.init(
        std.testing.allocator,
        display,
        .{
            .size = .{ .width = 1280, .height = 720 },
            .physical_size = .{ .width = 1280, .height = 720 },
            .scale = 1,
            .name = "HEADLESS-1",
            .description = "Keywork headless output",
            .model = "headless",
        },
        &surface_registry,
        &surfaces,
    );
    defer output.deinit();

    try output.memberships.append(std.testing.allocator, .{
        .surface_id = .{ .index = 0, .generation = 1 },
        .visible = true,
        .announced = true,
    });
    output.beginFrame();
    output.endFrame();
    try std.testing.expectEqual(@as(usize, 0), output.memberships.items.len);
}

test "cancelled frame preserves existing membership" {
    const display = try wl.Server.create();
    defer display.destroy();

    var surfaces: Surface.Store = .{};
    defer surfaces.deinit(std.testing.allocator);
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();

    var output: Self = undefined;
    try output.init(
        std.testing.allocator,
        display,
        .{
            .size = .{ .width = 1280, .height = 720 },
            .physical_size = .{ .width = 1280, .height = 720 },
            .scale = 1,
            .name = "HEADLESS-1",
            .description = "Keywork headless output",
            .model = "headless",
        },
        &surface_registry,
        &surfaces,
    );
    defer output.deinit();

    try output.memberships.append(std.testing.allocator, .{
        .surface_id = .{ .index = 0, .generation = 1 },
        .visible = true,
        .announced = true,
    });
    output.beginFrame();
    output.cancelFrame();
    try std.testing.expectEqual(@as(usize, 1), output.memberships.items.len);
    try std.testing.expect(output.memberships.items[0].visible);
}

test "canonical membership and delivery are independent of mature resources" {
    const Provider = struct {
        fn renderState(_: *anyopaque) ?SurfaceRegistry.RenderState {
            return null;
        }
    };
    const Probe = struct {
        entered_ids: [4]SurfaceRegistry.Id = undefined,
        entered_count: usize = 0,
        left_ids: [4]SurfaceRegistry.Id = undefined,
        left_count: usize = 0,
        changes: [4]Changes = undefined,
        change_count: usize = 0,

        fn configured(context: *anyopaque, _: Snapshot, changes: Changes) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.changes[self.change_count] = changes;
            self.change_count += 1;
        }

        fn entered(context: *anyopaque, id: SurfaceRegistry.Id) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.entered_ids[self.entered_count] = id;
            self.entered_count += 1;
        }

        fn left(context: *anyopaque, id: SurfaceRegistry.Id) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.left_ids[self.left_count] = id;
            self.left_count += 1;
        }
    };

    const display = try wl.Server.create();
    defer display.destroy();
    var surfaces: Surface.Store = .{};
    defer surfaces.deinit(std.testing.allocator);
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var provider_context: u8 = 0;
    const first = try surface_registry.add(.{
        .context = &provider_context,
        .render_state = Provider.renderState,
    });

    var output: Self = undefined;
    try output.init(
        std.testing.allocator,
        display,
        .{
            .size = .{ .width = 1280, .height = 720 },
            .physical_size = .{ .width = 600, .height = 340 },
            .scale = 1,
            .name = "HEADLESS-1",
            .description = "Keywork headless output",
            .model = "headless",
        },
        &surface_registry,
        &surfaces,
    );
    defer output.deinit();
    var probe: Probe = .{};
    output.setDeliveryListener(.{
        .context = &probe,
        .configured = Probe.configured,
        .entered = Probe.entered,
        .left = Probe.left,
    });
    defer output.clearDeliveryListener();

    output.beginFrame();
    try output.markSurfaceVisible(first);
    try output.markSurfaceVisible(first);
    try std.testing.expectEqual(@as(usize, 1), output.memberships.items.len);
    try std.testing.expectEqual(@as(usize, 0), probe.entered_count);
    output.cancelFrame();
    try std.testing.expectEqual(@as(usize, 0), output.memberships.items.len);

    output.beginFrame();
    try output.markSurfaceVisible(first);
    output.endFrame();
    try std.testing.expect(output.containsSurface(first));
    try std.testing.expectEqual(@as(usize, 1), probe.entered_count);
    try std.testing.expectEqual(first, probe.entered_ids[0]);

    output.beginFrame();
    try output.markSurfaceVisible(first);
    output.endFrame();
    try std.testing.expectEqual(@as(usize, 1), probe.entered_count);
    try std.testing.expectEqual(@as(usize, 0), probe.left_count);

    surface_registry.remove(first);
    const second = try surface_registry.add(.{
        .context = &provider_context,
        .render_state = Provider.renderState,
    });
    try std.testing.expectEqual(first.index, second.index);
    try std.testing.expect(first.generation != second.generation);
    output.beginFrame();
    try output.markSurfaceVisible(second);
    output.endFrame();
    try std.testing.expect(!output.containsSurface(first));
    try std.testing.expect(output.containsSurface(second));
    try std.testing.expectEqual(@as(usize, 2), probe.entered_count);
    try std.testing.expectEqual(second, probe.entered_ids[1]);
    try std.testing.expectEqual(@as(usize, 1), probe.left_count);
    try std.testing.expectEqual(first, probe.left_ids[0]);

    _ = output.configure(
        .{ .x = 10, .y = 20 },
        .{ .width = 640, .height = 360 },
        .{ .width = 1920, .height = 1080 },
        75_000,
        false,
        2,
        .{ .numerator = 180 },
    );
    output.setRefresh(.{
        .timestamp = .{ .seconds = 0, .nanoseconds = 0 },
        .refresh_nanoseconds = 20_000_000,
    });
    try std.testing.expectEqual(@as(usize, 2), probe.change_count);
    try std.testing.expectEqual(Changes{ .geometry = true, .mode = true, .scale = true, .preferred_scale = true }, probe.changes[0]);
    try std.testing.expectEqual(Changes{ .mode = true }, probe.changes[1]);

    output.beginFrame();
    output.endFrame();
    try std.testing.expectEqual(@as(usize, 0), output.memberships.items.len);
    try std.testing.expectEqual(@as(usize, 2), probe.left_count);
    try std.testing.expectEqual(second, probe.left_ids[1]);
    surface_registry.remove(second);
}
