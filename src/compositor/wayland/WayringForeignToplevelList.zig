//! Scanner-backed EXT foreign-toplevel-list resources.
//!
//! XdgShell owns window semantics; this adapter owns only wire mappings.

const WayringForeignToplevelList = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayring = @import("wayring");
const XdgShell = @import("../XdgShell.zig");
const WayringProfile = @import("WayringProfile.zig");

const List = struct {
    owner: *WayringForeignToplevelList,
    client: *wayring.server.Client,
    resource: protocol.ext_foreign_toplevel_list_v1.Resource,
    stopped: bool = false,
};
const Mapping = struct { window: XdgShell.WindowId, identifier: []u8 };
const Handle = struct {
    owner: *WayringForeignToplevelList,
    client: *wayring.server.Client,
    resource: protocol.ext_foreign_toplevel_handle_v1.Resource,
    list: ?*List,
    mapping: ?*Mapping,
    closed: bool = false,
};

allocator: std.mem.Allocator,
protocol_server: *wayring.server.Server,
xdg_shell: *XdgShell,
authorized_uid: std.os.linux.uid_t,
global: ?*const wayring.server.Server.Global = null,
lists: std.ArrayList(*List) = .empty,
mappings: std.ArrayList(*Mapping) = .empty,
handles: std.ArrayList(*Handle) = .empty,
next_identifier: u64 = 0,
observing: bool = false,

pub fn init(self: *WayringForeignToplevelList, allocator: std.mem.Allocator, protocol_server: *wayring.server.Server, xdg_shell: *XdgShell, authorized_uid: std.os.linux.uid_t) !void {
    self.* = .{ .allocator = allocator, .protocol_server = protocol_server, .xdg_shell = xdg_shell, .authorized_uid = authorized_uid };
    try xdg_shell.addWindowObserver(.{ .context = self, .committed = committed, .unmapped = removed, .destroyed = removed, .metadata_changed = metadataChanged, .state_changed = stateChanged });
    self.observing = true;
    self.syncWindows();
}

pub fn deinit(self: *WayringForeignToplevelList) void {
    std.debug.assert(self.global == null and self.lists.items.len == 0 and self.handles.items.len == 0);
    if (self.observing) self.xdg_shell.removeWindowObserver(self);
    for (self.mappings.items) |mapping| {
        self.allocator.free(mapping.identifier);
        self.allocator.destroy(mapping);
    }
    self.handles.deinit(self.allocator);
    self.lists.deinit(self.allocator);
    self.mappings.deinit(self.allocator);
    self.* = undefined;
}

pub fn publish(self: *WayringForeignToplevelList) !void {
    std.debug.assert(self.observing and self.global == null);
    self.global = try self.protocol_server.addGlobalWithOptions(protocol.ext_foreign_toplevel_list_v1, 1, WayringForeignToplevelList, self, bind, .{ .visibility = .restricted });
}

pub fn unpublish(self: *WayringForeignToplevelList) void {
    const global = self.global orelse unreachable;
    self.protocol_server.removeGlobal(global) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}

pub fn globalFilter(self: *WayringForeignToplevelList, client: *const wayring.server.Client, global: *const wayring.server.Server.Global) bool {
    return WayringProfile.securityVisible(self.authorized_uid, client, global);
}

fn bind(client: *wayring.server.Client, id: u32, version: u32, self: *WayringForeignToplevelList) !void {
    if (version != 1) return error.InvalidVersion;
    if (!client.isAuthorizedDirectPeer(self.authorized_uid)) return error.Unauthorized;
    try self.lists.ensureUnusedCapacity(self.allocator, 1);
    const list = try self.allocator.create(List);
    errdefer self.allocator.destroy(list);
    list.* = .{ .owner = self, .client = client, .resource = .init(self.allocator, id, version, .client, client.ownerHooks()) };
    errdefer {
        list.resource.destroy();
        list.resource.deinit();
    }
    try list.resource.setHandler(List, list, listRequest, null);
    try client.materialize(&list.resource.runtime);
    self.lists.appendAssumeCapacity(list);
    self.syncWindows();
    for (self.mappings.items) |mapping| if (self.handleFor(list, mapping) == null)
        self.createHandle(list, mapping) catch |err| self.eventFailure(client, &list.resource.runtime, err);
}

fn listRequest(_: *protocol.ext_foreign_toplevel_list_v1.Resource, request: protocol.ext_foreign_toplevel_list_v1.Request, list: *List) !void {
    switch (request) {
        .stop => if (!list.stopped) {
            list.stopped = true;
            try protocol.ext_foreign_toplevel_list_v1.@"send:finished"(&list.resource);
        },
        .destroy => list.owner.destroyList(list),
    }
}

fn createHandle(self: *WayringForeignToplevelList, list: *List, mapping: *Mapping) !void {
    if (list.stopped) return;
    try self.handles.ensureUnusedCapacity(self.allocator, 1);
    const id = try list.client.reserveServerId();
    errdefer list.client.rollbackServerId(id);
    const handle = try self.allocator.create(Handle);
    errdefer self.allocator.destroy(handle);
    handle.* = .{ .owner = self, .client = list.client, .resource = .init(self.allocator, id, 1, .server, list.client.ownerHooks()), .list = list, .mapping = mapping };
    errdefer {
        handle.resource.destroy();
        handle.resource.deinit();
    }
    try handle.resource.setHandler(Handle, handle, handleRequest, null);
    try list.client.materializeServer(&handle.resource.runtime);
    self.handles.appendAssumeCapacity(handle);
    // Output has no transactional rewind: after the first event queues the
    // server ID must remain materialized. Terminalize the client on any
    // enqueue failure and retain this valid handle for ordinary teardown.
    protocol.ext_foreign_toplevel_list_v1.@"send:toplevel"(&list.resource, id) catch |err| {
        self.eventFailure(list.client, &list.resource.runtime, err);
        return;
    };
    protocol.ext_foreign_toplevel_handle_v1.@"send:identifier"(&handle.resource, mapping.identifier) catch |err| {
        self.eventFailure(list.client, &handle.resource.runtime, err);
        return;
    };
    if (self.xdg_shell.windowInfo(mapping.window)) |info| {
        if (info.title) |title| protocol.ext_foreign_toplevel_handle_v1.@"send:title"(&handle.resource, title) catch |err| {
            self.eventFailure(list.client, &handle.resource.runtime, err);
            return;
        };
        if (info.app_id) |app_id| protocol.ext_foreign_toplevel_handle_v1.@"send:app_id"(&handle.resource, app_id) catch |err| {
            self.eventFailure(list.client, &handle.resource.runtime, err);
            return;
        };
    }
    protocol.ext_foreign_toplevel_handle_v1.@"send:done"(&handle.resource) catch |err|
        self.eventFailure(list.client, &handle.resource.runtime, err);
}

fn handleRequest(_: *protocol.ext_foreign_toplevel_handle_v1.Resource, _: protocol.ext_foreign_toplevel_handle_v1.Request, handle: *Handle) !void {
    handle.owner.destroyHandle(handle);
}

fn syncWindows(self: *WayringForeignToplevelList) void {
    var iterator = self.xdg_shell.windowIterator();
    while (iterator.next()) |window| self.syncWindow(window);
}
fn syncWindow(self: *WayringForeignToplevelList, window: XdgShell.WindowId) void {
    const info = self.xdg_shell.windowInfo(window) orelse return self.removeWindow(window);
    if (!info.mapped or !info.scene_presentation_enabled) return self.removeWindow(window);
    if (self.mappingFor(window) != null) return;
    const next = std.math.add(u64, self.next_identifier, 1) catch return self.postNoMemory();
    const identifier = std.fmt.allocPrint(self.allocator, "keywork-{x}", .{next}) catch return self.postNoMemory();
    const mapping = self.allocator.create(Mapping) catch {
        self.allocator.free(identifier);
        return self.postNoMemory();
    };
    self.mappings.append(self.allocator, mapping) catch {
        self.allocator.destroy(mapping);
        self.allocator.free(identifier);
        return self.postNoMemory();
    };
    mapping.* = .{ .window = window, .identifier = identifier };
    self.next_identifier = next;
    for (self.lists.items) |list| self.createHandle(list, mapping) catch |err| self.eventFailure(list.client, &list.resource.runtime, err);
}
fn committed(context: *anyopaque, window: XdgShell.WindowId) void {
    const self: *WayringForeignToplevelList = @ptrCast(@alignCast(context));
    self.syncWindow(window);
}
fn stateChanged(context: *anyopaque, window: XdgShell.WindowId) void {
    committed(context, window);
}
fn removed(context: *anyopaque, window: XdgShell.WindowId) void {
    const self: *WayringForeignToplevelList = @ptrCast(@alignCast(context));
    self.removeWindow(window);
}
fn metadataChanged(context: *anyopaque, window: XdgShell.WindowId) void {
    const self: *WayringForeignToplevelList = @ptrCast(@alignCast(context));
    const info = self.xdg_shell.windowInfo(window) orelse return;
    if (!info.mapped or !info.scene_presentation_enabled) {
        self.removeWindow(window);
        return;
    }
    const mapping = self.mappingFor(window) orelse return self.syncWindow(window);
    for (self.handles.items) |handle| if (handle.mapping == mapping and !handle.closed) {
        protocol.ext_foreign_toplevel_handle_v1.@"send:title"(&handle.resource, info.title orelse "") catch |err| self.eventFailure(handle.client, &handle.resource.runtime, err);
        protocol.ext_foreign_toplevel_handle_v1.@"send:app_id"(&handle.resource, info.app_id orelse "") catch |err| self.eventFailure(handle.client, &handle.resource.runtime, err);
        protocol.ext_foreign_toplevel_handle_v1.@"send:done"(&handle.resource) catch |err| self.eventFailure(handle.client, &handle.resource.runtime, err);
    };
}

fn removeWindow(self: *WayringForeignToplevelList, window: XdgShell.WindowId) void {
    const mapping = self.mappingFor(window) orelse return;
    for (self.handles.items) |handle| if (handle.mapping == mapping and !handle.closed) {
        handle.closed = true;
        handle.mapping = null;
        protocol.ext_foreign_toplevel_handle_v1.@"send:closed"(&handle.resource) catch |err| self.eventFailure(handle.client, &handle.resource.runtime, err);
    };
    for (self.mappings.items, 0..) |item, i| if (item == mapping) {
        _ = self.mappings.swapRemove(i);
        break;
    };
    self.allocator.free(mapping.identifier);
    self.allocator.destroy(mapping);
}
fn mappingFor(self: *WayringForeignToplevelList, window: XdgShell.WindowId) ?*Mapping {
    for (self.mappings.items) |mapping| if (std.meta.eql(mapping.window, window)) return mapping;
    return null;
}
fn handleFor(self: *WayringForeignToplevelList, list: *List, mapping: *Mapping) ?*Handle {
    for (self.handles.items) |handle| if (handle.list == list and handle.mapping == mapping) return handle;
    return null;
}
fn destroyList(self: *WayringForeignToplevelList, list: *List) void {
    for (self.handles.items) |handle| {
        if (handle.list == list) handle.list = null;
    }
    for (self.lists.items, 0..) |v, i| if (v == list) {
        _ = self.lists.swapRemove(i);
        break;
    };
    list.resource.destroy();
    list.resource.deinit();
    self.allocator.destroy(list);
}
fn destroyHandle(self: *WayringForeignToplevelList, handle: *Handle) void {
    for (self.handles.items, 0..) |v, i| if (v == handle) {
        _ = self.handles.swapRemove(i);
        break;
    };
    handle.resource.destroy();
    handle.resource.deinit();
    self.allocator.destroy(handle);
}
pub fn destroyClientResources(self: *WayringForeignToplevelList, client: *wayring.server.Client) void {
    var i = self.handles.items.len;
    while (i > 0) {
        i -= 1;
        if (self.handles.items[i].client == client) self.destroyHandle(self.handles.items[i]);
    }
    i = self.lists.items.len;
    while (i > 0) {
        i -= 1;
        if (self.lists.items[i].client == client) self.destroyList(self.lists.items[i]);
    }
}
fn postNoMemory(self: *WayringForeignToplevelList) void {
    for (self.lists.items) |list| list.client.postOutOfMemory(&list.resource.runtime, "tracking foreign toplevel");
}
fn eventFailure(_: *WayringForeignToplevelList, client: *wayring.server.Client, resource: *wayring.server.Resource, _: anyerror) void {
    client.postOutOfMemory(resource, "queueing foreign toplevel event");
}

test "EXT foreign toplevel descriptors are exact v1" {
    try std.testing.expectEqual(@as(u32, 1), protocol.ext_foreign_toplevel_list_v1.interface.version);
    try std.testing.expectEqualStrings("toplevel", protocol.ext_foreign_toplevel_list_v1.event_messages[0].name);
    try std.testing.expectEqualStrings("identifier", protocol.ext_foreign_toplevel_handle_v1.event_messages[4].name);
}
