//! Scanner-resource adapter for xdg-toplevel icon metadata.

const Self = @This();
const std = @import("std");
const protocol = @import("wayring-protocol");
const wayring = @import("wayring");
const XdgShell = @import("../XdgShell.zig");
const WayringCompositor = @import("WayringCompositor.zig");
const WayringXdgShell = @import("WayringXdgShell.zig");

const server = wayring.server;

const Manager = struct { owner: *Self, client: *server.Client, resource: protocol.xdg_toplevel_icon_manager_v1.Resource };
const Icon = struct {
    owner: *Self,
    client: *server.Client,
    resource: protocol.xdg_toplevel_icon_v1.Resource,
    name: ?[:0]u8 = null,
    buffers: std.ArrayList(*Buffer) = .empty,
    immutable: bool = false,
};
const Buffer = struct {
    icon: *Icon,
    resource: ?*server.Resource,
    observer: ?*server.Resource.Observer,
    pin: server.shm.Buffer.Pin,
    geometry: server.shm.Geometry,
    scale: i32,
};

allocator: std.mem.Allocator,
protocol_server: *server.Server,
xdg: *WayringXdgShell,
compositor: *WayringCompositor,
global: ?*const server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
icons: std.ArrayList(*Icon) = .empty,

pub fn init(self: *Self, allocator: std.mem.Allocator, protocol_server: *server.Server, xdg: *WayringXdgShell, compositor: *WayringCompositor) void {
    self.* = .{ .allocator = allocator, .protocol_server = protocol_server, .xdg = xdg, .compositor = compositor };
}
pub fn publish(self: *Self) !void {
    self.global = try self.protocol_server.addGlobal(protocol.xdg_toplevel_icon_manager_v1, 1, Self, self, bind);
}
pub fn unpublish(self: *Self) void {
    self.protocol_server.removeGlobal(self.global.?) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}
pub fn destroyClientResources(self: *Self, client: *server.Client) void {
    var i = self.icons.items.len;
    while (i > 0) : (i -= 1) if (self.icons.items[i - 1].client == client) self.destroyIcon(self.icons.items[i - 1]);
    i = self.managers.items.len;
    while (i > 0) : (i -= 1) if (self.managers.items[i - 1].client == client) self.destroyManager(self.managers.items[i - 1]);
}
pub fn deinit(self: *Self) void {
    std.debug.assert(self.global == null and self.icons.items.len == 0 and self.managers.items.len == 0);
    self.icons.deinit(self.allocator);
    self.managers.deinit(self.allocator);
    self.* = undefined;
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
    try value.resource.setHandler(Manager, value, handleManager, null);
    try client.materialize(&value.resource.runtime);
    self.managers.appendAssumeCapacity(value);
    protocol.xdg_toplevel_icon_manager_v1.@"send:done"(&value.resource) catch |err| eventFailure(client, &value.resource.runtime, err, "sending icon manager done");
}
fn handleManager(_: *protocol.xdg_toplevel_icon_manager_v1.Resource, request: protocol.xdg_toplevel_icon_manager_v1.Request, value: *Manager) !void {
    switch (request) {
        .destroy => value.owner.destroyManager(value),
        .create_icon => |args| try value.owner.createIcon(value, args.id),
        .set_icon => |args| value.owner.setIcon(value, args.toplevel, args.icon),
    }
}
fn createIcon(self: *Self, manager: *Manager, id: u32) !void {
    try self.icons.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Icon);
    errdefer self.allocator.destroy(value);
    value.* = .{ .owner = self, .client = manager.client, .resource = .init(self.allocator, id, manager.resource.version(), .client, manager.client.ownerHooks()) };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Icon, value, handleIcon, null);
    try manager.client.materialize(&value.resource.runtime);
    self.icons.appendAssumeCapacity(value);
}
fn setIcon(self: *Self, manager: *Manager, toplevel_id: u32, icon_id: ?u32) void {
    const identity = self.xdg.toplevelIdentity(manager.client, toplevel_id) orelse return manager.client.postImplementationError(&manager.resource.runtime, "xdg_toplevel is not an exact live same-client generated object");
    var icon_snapshot: ?XdgShell.ToplevelIcon = null;
    if (icon_id) |id| {
        const icon = self.findIcon(manager.client, id) orelse return manager.client.postImplementationError(&manager.resource.runtime, "xdg_toplevel_icon_v1 is not an exact live same-client generated object");
        icon_snapshot = snapshotForAssignment(icon) catch |err| switch (err) {
            error.OutOfMemory => return manager.client.postOutOfMemory(&manager.resource.runtime, "snapshotting toplevel icon"),
            error.InvalidBuffer => return icon.client.postProtocolError(&icon.resource.runtime, @intCast(protocol.xdg_toplevel_icon_v1.@"error".invalid_buffer), "icon buffer is no longer readable"),
            error.BufferAccess => return manager.client.postImplementationError(&manager.resource.runtime, "accessing toplevel icon buffer"),
        };
    }
    self.xdg.setPendingToplevelIcon(identity, icon_snapshot);
}
fn handleIcon(_: *protocol.xdg_toplevel_icon_v1.Resource, request: protocol.xdg_toplevel_icon_v1.Request, icon: *Icon) !void {
    switch (request) {
        .destroy => icon.owner.destroyIcon(icon),
        .set_name => |args| setName(icon, args.icon_name),
        .add_buffer => |args| addBuffer(icon, args.buffer, args.scale),
    }
}
fn rejectMutation(icon: *Icon) bool {
    if (!icon.immutable) return false;
    protocolError(icon, protocol.xdg_toplevel_icon_v1.@"error".immutable, "icon was already assigned to a toplevel");
    return true;
}
fn setName(icon: *Icon, name: []const u8) void {
    if (rejectMutation(icon)) return;
    if (!std.unicode.utf8ValidateSlice(name)) return icon.client.postImplementationError(&icon.resource.runtime, "icon name is not valid UTF-8");
    const copy = icon.owner.allocator.dupeSentinel(u8, name, 0) catch return icon.client.postOutOfMemory(&icon.resource.runtime, "copying icon name");
    if (icon.name) |old| icon.owner.allocator.free(old);
    icon.name = copy;
}
fn addBuffer(icon: *Icon, object_id: u32, scale: i32) void {
    if (rejectMutation(icon)) return;
    const resource = icon.client.lookup(object_id) orelse return protocolError(icon, protocol.xdg_toplevel_icon_v1.@"error".invalid_buffer, "icon buffer is not live");
    var pin = icon.owner.compositor.shmAdapter().pin(resource) orelse return protocolError(icon, protocol.xdg_toplevel_icon_v1.@"error".invalid_buffer, "icon buffer is not backed by generated wl_shm");
    var access = pin.access() catch |err| {
        pin.deinit();
        return bufferAccessFailure(icon, err, "reading icon buffer geometry");
    };
    const geometry = access.geometry;
    access.end() catch {
        pin.deinit();
        return protocolError(icon, protocol.xdg_toplevel_icon_v1.@"error".invalid_buffer, "icon buffer is not readable");
    };
    if (geometry.width == 0 or geometry.height != geometry.width or geometry.stride == 0) {
        pin.deinit();
        return protocolError(icon, protocol.xdg_toplevel_icon_v1.@"error".invalid_buffer, "icon buffer must be a valid square");
    }
    const value = icon.owner.allocator.create(Buffer) catch {
        pin.deinit();
        return icon.client.postOutOfMemory(&icon.resource.runtime, "retaining icon buffer");
    };
    value.* = .{ .icon = icon, .resource = resource, .observer = null, .pin = pin, .geometry = geometry, .scale = scale };
    value.observer = resource.addDestroyObserver(Buffer, value, bufferDestroyed) catch {
        value.pin.deinit();
        icon.owner.allocator.destroy(value);
        return icon.client.postOutOfMemory(&icon.resource.runtime, "observing icon buffer");
    };
    for (icon.buffers.items, 0..) |old, i| if (old.geometry.width == geometry.width and old.scale == scale) {
        destroyBuffer(old);
        icon.buffers.items[i] = value;
        return;
    };
    icon.buffers.append(icon.owner.allocator, value) catch {
        destroyBuffer(value);
        icon.client.postOutOfMemory(&icon.resource.runtime, "retaining icon buffer");
    };
}
fn bufferDestroyed(value: *Buffer, _: *server.Resource, _: *server.Resource.Observer) void {
    value.observer = null;
    value.resource = null;
    protocolError(value.icon, protocol.xdg_toplevel_icon_v1.@"error".no_buffer, "icon buffer was destroyed before the icon");
}
const SnapshotError = error{ OutOfMemory, InvalidBuffer, BufferAccess };
fn snapshotForAssignment(icon: *Icon) SnapshotError!?XdgShell.ToplevelIcon {
    const result = try snapshot(icon);
    icon.immutable = true;
    return result;
}
fn snapshot(icon: *Icon) SnapshotError!?XdgShell.ToplevelIcon {
    if (icon.name == null and icon.buffers.items.len == 0) return null;
    const allocator = icon.owner.allocator;
    const name = if (icon.name) |v| try allocator.dupeSentinel(u8, v, 0) else null;
    errdefer if (name) |v| allocator.free(v);
    const buffers = try allocator.alloc(XdgShell.ToplevelIconBuffer, icon.buffers.items.len);
    var initialized: usize = 0;
    errdefer {
        for (buffers[0..initialized]) |v| allocator.free(v.data);
        allocator.free(buffers);
    }
    for (icon.buffers.items, buffers) |source, *destination| {
        if (source.resource == null) return error.InvalidBuffer;
        var access = source.pin.access() catch |err| switch (err) {
            error.InvalidBacking => return error.InvalidBuffer,
            else => return error.BufferAccess,
        };
        const byte_count = std.math.mul(usize, access.geometry.stride, access.geometry.height) catch {
            access.end() catch {};
            return error.InvalidBuffer;
        };
        const data = allocator.alloc(u8, byte_count) catch {
            access.end() catch {};
            return error.OutOfMemory;
        };
        @memset(data, 0);
        @memcpy(data[0..access.bytes.len], access.bytes);
        access.end() catch {
            allocator.free(data);
            return error.InvalidBuffer;
        };
        destination.* = .{ .size = @intCast(source.geometry.width), .scale = source.scale, .format = @intFromEnum(source.geometry.format), .stride = @intCast(source.geometry.stride), .data = data };
        initialized += 1;
    }
    return .{ .name = name, .buffers = buffers };
}
fn protocolError(icon: *Icon, code: i64, message: []const u8) void {
    icon.client.postProtocolError(&icon.resource.runtime, @intCast(code), message);
}
fn bufferAccessFailure(icon: *Icon, err: anyerror, detail: []const u8) void {
    switch (err) {
        error.InvalidBacking => protocolError(icon, protocol.xdg_toplevel_icon_v1.@"error".invalid_buffer, detail),
        else => icon.client.postImplementationError(&icon.resource.runtime, detail),
    }
}
fn eventFailure(client: *server.Client, resource: *server.Resource, err: anyerror, detail: []const u8) void {
    if (client.fatal() != null) return;
    switch (err) {
        error.OutOfMemory, error.WriteFailed => client.postOutOfMemory(resource, detail),
        error.OutputSealed, error.ClientFatal => {},
        else => client.postImplementationError(resource, detail),
    }
}
fn findIcon(self: *Self, client: *server.Client, id: u32) ?*Icon {
    for (self.icons.items) |v| if (v.client == client and v.resource.runtime.id() == id) return v;
    return null;
}
fn destroyBuffer(value: *Buffer) void {
    if (value.observer) |observer| server.Resource.removeDestroyObserver(observer);
    value.pin.deinit();
    value.icon.owner.allocator.destroy(value);
}
fn destroyIcon(self: *Self, value: *Icon) void {
    remove(Icon, &self.icons, value);
    if (value.name) |name| self.allocator.free(name);
    for (value.buffers.items) |buffer| destroyBuffer(buffer);
    value.buffers.deinit(self.allocator);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}
fn destroyManager(self: *Self, value: *Manager) void {
    remove(Manager, &self.managers, value);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}
fn remove(comptime T: type, list: *std.ArrayList(*T), value: *T) void {
    for (list.items, 0..) |item, i| if (item == value) {
        _ = list.swapRemove(i);
        return;
    };
    unreachable;
}

test "generated icon descriptors preserve pinned version and errors" {
    try std.testing.expectEqual(@as(u32, 1), protocol.xdg_toplevel_icon_manager_v1.interface.version);
    try std.testing.expectEqual(@as(i64, 1), protocol.xdg_toplevel_icon_v1.@"error".invalid_buffer);
    try std.testing.expectEqual(@as(i64, 2), protocol.xdg_toplevel_icon_v1.@"error".immutable);
    try std.testing.expectEqual(@as(i64, 3), protocol.xdg_toplevel_icon_v1.@"error".no_buffer);
}

test "icon becomes immutable only after assignment snapshot succeeds" {
    const name = try std.testing.allocator.dupeSentinel(u8, "terminal", 0);
    defer std.testing.allocator.free(name);
    var owner: Self = undefined;
    var icon: Icon = .{
        .owner = &owner,
        .client = undefined,
        .resource = undefined,
        .name = name,
    };

    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    owner.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, snapshotForAssignment(&icon));
    try std.testing.expect(!icon.immutable);

    owner.allocator = std.testing.allocator;
    var icon_snapshot = (try snapshotForAssignment(&icon)).?;
    defer icon_snapshot.deinit(std.testing.allocator);
    try std.testing.expect(icon.immutable);
}
