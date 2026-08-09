//! Scanner-backed XDG toplevel drag wire adapter.

const Self = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayring = @import("wayring");
const DataDevice = @import("../DataDevice.zig");
const Scene = @import("../scene.zig");
const XdgShell = @import("../XdgShell.zig");
const WayringDataDevice = @import("WayringDataDevice.zig");
const WayringXdgShell = @import("WayringXdgShell.zig");

const server = wayring.server;

pub const Listener = struct {
    context: *anyopaque,
    pointer_position: *const fn (*anyopaque) ?Point,
    begin: *const fn (*anyopaque, XdgShell.WindowId, f64, f64, i32, i32, bool) bool,
    motion: *const fn (*anyopaque, f64, f64) void,
    end: *const fn (*anyopaque) void,
};
pub const Point = struct { x: f64, y: f64 };

const Manager = struct { owner: *Self, client: *server.Client, resource: protocol.xdg_toplevel_drag_manager_v1.Resource };
const Drag = struct {
    owner: *Self,
    client: *server.Client,
    resource: protocol.xdg_toplevel_drag_v1.Resource,
    source: ?DataDevice.SourceId = null,
    attached_window: ?XdgShell.WindowId = null,
    x_offset: i32 = 0,
    y_offset: i32 = 0,
    use_offset_hint: bool = false,
    active: bool = false,
    ended: bool = false,
    moving: bool = false,
};

allocator: std.mem.Allocator,
protocol_server: *server.Server,
data_device: *WayringDataDevice,
xdg_shell: *WayringXdgShell,
core: *XdgShell,
listener: Listener,
global: ?*const server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
drags: std.ArrayList(*Drag) = .empty,

pub fn init(self: *Self, allocator: std.mem.Allocator, protocol_server: *server.Server, data_device: *WayringDataDevice, xdg_shell: *WayringXdgShell, core: *XdgShell, listener: Listener) !void {
    self.* = .{ .allocator = allocator, .protocol_server = protocol_server, .data_device = data_device, .xdg_shell = xdg_shell, .core = core, .listener = listener };
    errdefer self.drags.deinit(allocator);
    errdefer self.managers.deinit(allocator);
    try core.addWindowObserver(.{ .context = self, .committed = windowCommitted, .unmapped = windowUnmapped, .destroyed = windowDestroyed, .metadata_changed = windowIgnored, .state_changed = windowIgnored });
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.global == null and self.managers.items.len == 0 and self.drags.items.len == 0);
    self.core.removeWindowObserver(self);
    self.drags.deinit(self.allocator);
    self.managers.deinit(self.allocator);
    self.* = undefined;
}

pub fn publish(self: *Self) !void {
    self.global = try self.protocol_server.addGlobal(protocol.xdg_toplevel_drag_manager_v1, 1, Self, self, bind);
}

pub fn unpublish(self: *Self) void {
    const global = self.global orelse return;
    self.protocol_server.removeGlobal(global) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}

pub fn destroyClientResources(self: *Self, client: *server.Client) void {
    var i = self.drags.items.len;
    while (i > 0) : (i -= 1) if (self.drags.items[i - 1].client == client) self.destroyDrag(self.drags.items[i - 1]);
    i = self.managers.items.len;
    while (i > 0) : (i -= 1) if (self.managers.items[i - 1].client == client) self.destroyManager(self.managers.items[i - 1]);
}

pub fn pointerMotion(self: *Self, x: f64, y: f64) void {
    for (self.drags.items) |drag| if (drag.active) {
        self.tryBeginAt(drag, x, y);
        if (drag.moving) self.listener.motion(self.listener.context, x, y);
    };
}

pub fn attachedScene(self: *Self) ?Scene.Id {
    for (self.drags.items) |drag| if (drag.active) {
        const info = self.core.windowInfo(drag.attached_window orelse continue) orelse continue;
        if (info.mapped and info.scene_presentation_enabled and info.interaction_enabled) return info.scene_id;
    };
    return null;
}

fn bind(client: *server.Client, id: u32, version: u32, self: *Self) !void {
    try self.managers.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Manager);
    errdefer self.allocator.destroy(value);
    value.* = .{ .owner = self, .client = client, .resource = .init(self.allocator, id, version, .client, client.ownerHooks()) };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Manager, value, managerRequest, null);
    try client.materialize(&value.resource.runtime);
    self.managers.appendAssumeCapacity(value);
}

fn managerRequest(_: *protocol.xdg_toplevel_drag_manager_v1.Resource, request: protocol.xdg_toplevel_drag_manager_v1.Request, manager: *Manager) !void {
    switch (request) {
        .destroy => manager.owner.destroyManager(manager),
        .get_xdg_toplevel_drag => |args| try manager.owner.createDrag(manager, args.id, args.data_source),
    }
}

fn createDrag(self: *Self, manager: *Manager, id: u32, source_object: u32) !void {
    try self.drags.ensureUnusedCapacity(self.allocator, 1);
    const drag = try self.allocator.create(Drag);
    errdefer self.allocator.destroy(drag);
    drag.* = .{ .owner = self, .client = manager.client, .resource = .init(self.allocator, id, manager.resource.version(), .client, manager.client.ownerHooks()) };
    errdefer {
        drag.resource.destroy();
        drag.resource.deinit();
    }
    try drag.resource.setHandler(Drag, drag, dragRequest, null);
    try manager.client.materialize(&drag.resource.runtime);
    drag.source = self.data_device.reserveToplevelDragSource(manager.client, source_object, .{ .context = drag, .started = dragStarted, .ended = dragEnded, .source_destroyed = sourceDestroyed }) catch {
        drag.resource.destroy();
        drag.resource.deinit();
        self.allocator.destroy(drag);
        manager.client.postProtocolError(&manager.resource.runtime, @intCast(protocol.xdg_toplevel_drag_manager_v1.@"error".invalid_source), "wl_data_source is invalid, used, or reserved");
        return;
    };
    self.drags.appendAssumeCapacity(drag);
}

fn dragRequest(_: *protocol.xdg_toplevel_drag_v1.Resource, request: protocol.xdg_toplevel_drag_v1.Request, drag: *Drag) !void {
    switch (request) {
        .destroy => if (!drag.ended)
            drag.client.postProtocolError(&drag.resource.runtime, @intCast(protocol.xdg_toplevel_drag_v1.@"error".ongoing_drag), "data source drag has not ended")
        else
            drag.owner.destroyDrag(drag),
        .attach => |args| drag.owner.attach(drag, args.toplevel, args.x_offset, args.y_offset),
    }
}

fn attach(self: *Self, drag: *Drag, toplevel_object: u32, x_offset: i32, y_offset: i32) void {
    if (drag.attached_window != null) {
        drag.client.postProtocolError(&drag.resource.runtime, @intCast(protocol.xdg_toplevel_drag_v1.@"error".toplevel_attached), "a valid xdg_toplevel is already attached");
        return;
    }
    const identity = self.xdg_shell.toplevelIdentity(drag.client, toplevel_object) orelse return;
    const info = self.core.windowInfo(identity.core_id) orelse return;
    drag.attached_window = identity.core_id;
    drag.x_offset = x_offset;
    drag.y_offset = y_offset;
    drag.use_offset_hint = !info.mapped;
    self.tryBegin(drag);
}

fn tryBegin(self: *Self, drag: *Drag) void {
    const point = self.listener.pointer_position(self.listener.context) orelse return;
    self.tryBeginAt(drag, point.x, point.y);
}

fn tryBeginAt(self: *Self, drag: *Drag, x: f64, y: f64) void {
    if (!drag.active or drag.moving) return;
    const window = drag.attached_window orelse return;
    const info = self.core.windowInfo(window) orelse return;
    if (!info.mapped or !info.scene_presentation_enabled or !info.interaction_enabled) return;
    drag.moving = self.listener.begin(self.listener.context, window, x, y, drag.x_offset, drag.y_offset, drag.use_offset_hint);
}

fn detach(self: *Self, drag: *Drag) void {
    if (drag.moving) self.listener.end(self.listener.context);
    drag.moving = false;
    drag.attached_window = null;
    drag.use_offset_hint = false;
}

fn dragStarted(context: *anyopaque) void {
    const drag: *Drag = @ptrCast(@alignCast(context));
    drag.active = true;
    drag.owner.tryBegin(drag);
}
fn dragEnded(context: *anyopaque) void {
    const drag: *Drag = @ptrCast(@alignCast(context));
    if (drag.moving) drag.owner.listener.end(drag.owner.listener.context);
    drag.moving = false;
    drag.active = false;
    drag.ended = true;
}
fn sourceDestroyed(context: *anyopaque) void {
    const drag: *Drag = @ptrCast(@alignCast(context));
    drag.source = null;
    drag.active = false;
    drag.ended = true;
    drag.owner.detach(drag);
}

fn destroyDrag(self: *Self, drag: *Drag) void {
    if (drag.source) |source| self.data_device.releaseToplevelDragSource(source, drag);
    self.detach(drag);
    for (self.drags.items, 0..) |candidate, i| if (candidate == drag) {
        _ = self.drags.swapRemove(i);
        break;
    };
    drag.resource.destroy();
    drag.resource.deinit();
    self.allocator.destroy(drag);
}
fn destroyManager(self: *Self, manager: *Manager) void {
    for (self.managers.items, 0..) |candidate, i| if (candidate == manager) {
        _ = self.managers.swapRemove(i);
        break;
    };
    manager.resource.destroy();
    manager.resource.deinit();
    self.allocator.destroy(manager);
}
fn windowCommitted(context: *anyopaque, id: XdgShell.WindowId) void {
    const self: *Self = @ptrCast(@alignCast(context));
    for (self.drags.items) |drag| if (drag.attached_window) |attached| if (std.meta.eql(attached, id)) self.tryBegin(drag);
}
fn windowUnmapped(context: *anyopaque, id: XdgShell.WindowId) void {
    detachWindow(@ptrCast(@alignCast(context)), id);
}
fn windowDestroyed(context: *anyopaque, id: XdgShell.WindowId) void {
    detachWindow(@ptrCast(@alignCast(context)), id);
}
fn detachWindow(self: *Self, id: XdgShell.WindowId) void {
    for (self.drags.items) |drag| if (drag.attached_window) |attached| if (std.meta.eql(attached, id)) self.detach(drag);
}
fn windowIgnored(_: *anyopaque, _: XdgShell.WindowId) void {}

test "toplevel drag descriptors match scanner contract" {
    try std.testing.expectEqual(@as(u32, 1), protocol.xdg_toplevel_drag_manager_v1.interface.version);
    try std.testing.expectEqualStrings("get_xdg_toplevel_drag", protocol.xdg_toplevel_drag_manager_v1.request_messages[1].name);
    try std.testing.expectEqual(@as(i64, 1), protocol.xdg_toplevel_drag_v1.@"error".ongoing_drag);
}
