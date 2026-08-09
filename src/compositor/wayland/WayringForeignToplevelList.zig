//! Scanner-backed EXT foreign-toplevel-list resources.
//!
//! XdgShell owns window semantics; this adapter owns only wire mappings.

const WayringForeignToplevelList = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayring = @import("wayring");
const XdgShell = @import("../XdgShell.zig");
const SurfaceRegistry = @import("../SurfaceRegistry.zig");
const OutputLayout = @import("output_layout.zig");
const WayringCompositor = @import("WayringCompositor.zig");
const WayringOutput = @import("WayringOutput.zig");
const WayringSeatAdapter = @import("WayringSeatAdapter.zig");
const WayringProfile = @import("WayringProfile.zig");

const List = struct {
    owner: *WayringForeignToplevelList,
    client: *wayring.server.Client,
    resource: protocol.ext_foreign_toplevel_list_v1.Resource,
    stopped: bool = false,
};
const Mapping = struct { window: XdgShell.WindowId, surface: SurfaceRegistry.Id, identifier: []u8 };
const Handle = struct {
    owner: *WayringForeignToplevelList,
    client: *wayring.server.Client,
    resource: protocol.ext_foreign_toplevel_handle_v1.Resource,
    list: ?*List,
    mapping: ?*Mapping,
    closed: bool = false,
};
const WlrManager = struct {
    owner: *WayringForeignToplevelList,
    client: *wayring.server.Client,
    resource: protocol.zwlr_foreign_toplevel_manager_v1.Resource,
    generation: u64,
    initializing: bool = true,
};
const WlrHandle = struct {
    owner: *WayringForeignToplevelList,
    client: *wayring.server.Client,
    resource: protocol.zwlr_foreign_toplevel_handle_v1.Resource,
    generation: u64,
    mapping: ?*Mapping,
    outputs: std.ArrayList(OutputLayout.Id) = .empty,
    initialized: bool = false,
    closed: bool = false,
};

allocator: std.mem.Allocator,
protocol_server: *wayring.server.Server,
xdg_shell: *XdgShell,
seat: *WayringSeatAdapter,
outputs: ?*WayringOutput,
output_layout: ?*OutputLayout,
compositor: ?*WayringCompositor,
authorized_uid: std.os.linux.uid_t,
global: ?*const wayring.server.Server.Global = null,
wlr_global: ?*const wayring.server.Server.Global = null,
lists: std.ArrayList(*List) = .empty,
mappings: std.ArrayList(*Mapping) = .empty,
handles: std.ArrayList(*Handle) = .empty,
wlr_managers: std.ArrayList(*WlrManager) = .empty,
wlr_handles: std.ArrayList(*WlrHandle) = .empty,
next_identifier: u64 = 0,
next_generation: u64 = 0,
observing: bool = false,

pub fn init(self: *WayringForeignToplevelList, allocator: std.mem.Allocator, protocol_server: *wayring.server.Server, xdg_shell: *XdgShell, seat: *WayringSeatAdapter, outputs: ?*WayringOutput, output_layout: ?*OutputLayout, compositor: ?*WayringCompositor, authorized_uid: std.os.linux.uid_t) !void {
    std.debug.assert((outputs == null) == (output_layout == null));
    self.* = .{ .allocator = allocator, .protocol_server = protocol_server, .xdg_shell = xdg_shell, .seat = seat, .outputs = outputs, .output_layout = output_layout, .compositor = compositor, .authorized_uid = authorized_uid };
    if (outputs) |value| try value.addBindListener(.{ .context = self, .bound = outputBound });
    errdefer if (outputs) |value| value.removeBindListener(self);
    try xdg_shell.addWindowObserver(.{ .context = self, .committed = committed, .unmapped = removed, .destroyed = removed, .metadata_changed = metadataChanged, .state_changed = stateChanged });
    self.observing = true;
    self.syncWindows();
}

pub fn deinit(self: *WayringForeignToplevelList) void {
    std.debug.assert(self.global == null and self.wlr_global == null and self.lists.items.len == 0 and self.handles.items.len == 0 and self.wlr_managers.items.len == 0 and self.wlr_handles.items.len == 0);
    if (self.observing) self.xdg_shell.removeWindowObserver(self);
    if (self.outputs) |outputs| outputs.removeBindListener(self);
    for (self.mappings.items) |mapping| {
        self.allocator.free(mapping.identifier);
        self.allocator.destroy(mapping);
    }
    self.handles.deinit(self.allocator);
    self.wlr_handles.deinit(self.allocator);
    self.wlr_managers.deinit(self.allocator);
    self.lists.deinit(self.allocator);
    self.mappings.deinit(self.allocator);
    self.* = undefined;
}

pub fn publish(self: *WayringForeignToplevelList) !void {
    std.debug.assert(self.observing and self.global == null and self.wlr_global == null);
    self.global = try self.protocol_server.addGlobalWithOptions(protocol.ext_foreign_toplevel_list_v1, 1, WayringForeignToplevelList, self, bind, .{ .visibility = .restricted });
    errdefer {
        self.protocol_server.removeGlobal(self.global.?) catch {};
        self.global = null;
    }
    self.wlr_global = try self.protocol_server.addGlobalWithOptions(protocol.zwlr_foreign_toplevel_manager_v1, 3, WayringForeignToplevelList, self, bindWlr, .{ .visibility = .restricted });
}

pub fn unpublish(self: *WayringForeignToplevelList) void {
    const wlr_global = self.wlr_global orelse unreachable;
    self.protocol_server.removeGlobal(wlr_global) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.wlr_global = null;
    const global = self.global orelse unreachable;
    self.protocol_server.removeGlobal(global) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}

fn bindWlr(client: *wayring.server.Client, id: u32, version: u32, self: *WayringForeignToplevelList) !void {
    if (version == 0 or version > 3) return error.InvalidVersion;
    if (!client.isAuthorizedDirectPeer(self.authorized_uid)) return error.Unauthorized;
    try self.wlr_managers.ensureUnusedCapacity(self.allocator, 1);
    const manager = try self.allocator.create(WlrManager);
    errdefer self.allocator.destroy(manager);
    const generation = try std.math.add(u64, self.next_generation, 1);
    manager.* = .{ .owner = self, .client = client, .resource = .init(self.allocator, id, version, .client, client.ownerHooks()), .generation = generation };
    errdefer {
        manager.resource.destroy();
        manager.resource.deinit();
    }
    try manager.resource.setHandler(WlrManager, manager, wlrManagerRequest, null);
    try client.materialize(&manager.resource.runtime);
    self.wlr_managers.appendAssumeCapacity(manager);
    self.next_generation = generation;
    self.syncWindows();
    // Materialize the complete binding first, so version-3 parent references
    // never depend on catalog iteration order.
    for (self.mappings.items) |mapping| {
        if (self.wlrHandleFor(generation, mapping) != null) continue;
        self.createWlrHandle(manager, mapping) catch |err| {
            self.eventFailure(client, &manager.resource.runtime, err);
            return;
        };
    }
    manager.initializing = false;
    for (self.wlr_handles.items) |handle| if (handle.generation == generation) self.sendWlrInitial(handle);
}

fn wlrManagerRequest(_: *protocol.zwlr_foreign_toplevel_manager_v1.Resource, request: protocol.zwlr_foreign_toplevel_manager_v1.Request, manager: *WlrManager) !void {
    switch (request) {
        .stop => {
            try protocol.zwlr_foreign_toplevel_manager_v1.@"send:finished"(&manager.resource);
            manager.owner.destroyWlrManager(manager);
        },
    }
}

fn createWlrHandle(self: *WayringForeignToplevelList, manager: *WlrManager, mapping: *Mapping) !void {
    try self.wlr_handles.ensureUnusedCapacity(self.allocator, 1);
    const id = try manager.client.reserveServerId();
    errdefer manager.client.rollbackServerId(id);
    const handle = try self.allocator.create(WlrHandle);
    errdefer self.allocator.destroy(handle);
    handle.* = .{ .owner = self, .client = manager.client, .resource = .init(self.allocator, id, manager.resource.version(), .server, manager.client.ownerHooks()), .generation = manager.generation, .mapping = mapping };
    errdefer {
        handle.resource.destroy();
        handle.resource.deinit();
    }
    try handle.resource.setHandler(WlrHandle, handle, wlrHandleRequest, null);
    try manager.client.materializeServer(&handle.resource.runtime);
    self.wlr_handles.appendAssumeCapacity(handle);
    // Output has no transactional rewind. Once the server ID is materialized,
    // retain it for normal client teardown even when event enqueue fails.
    protocol.zwlr_foreign_toplevel_manager_v1.@"send:toplevel"(&manager.resource, id) catch |err|
        self.eventFailure(manager.client, &manager.resource.runtime, err);
}

fn sendWlrInitial(self: *WayringForeignToplevelList, handle: *WlrHandle) void {
    if (handle.initialized or handle.closed) return;
    for (self.wlr_managers.items) |manager|
        if (manager.generation == handle.generation and manager.initializing) return;
    const mapping = handle.mapping orelse return;
    const info = self.xdg_shell.windowInfo(mapping.window) orelse return;
    if (info.title) |v| protocol.zwlr_foreign_toplevel_handle_v1.@"send:title"(&handle.resource, v) catch |err| {
        self.eventFailure(handle.client, &handle.resource.runtime, err);
        return;
    };
    if (info.app_id) |v| protocol.zwlr_foreign_toplevel_handle_v1.@"send:app_id"(&handle.resource, v) catch |err| {
        self.eventFailure(handle.client, &handle.resource.runtime, err);
        return;
    };
    if (self.output_layout) |layout| {
        var iterator = layout.iterator();
        while (iterator.next()) |entry| if (entry.output.containsSurface(mapping.surface)) {
            handle.outputs.append(self.allocator, entry.id) catch return self.eventFailure(handle.client, &handle.resource.runtime, error.OutOfMemory);
            self.sendWlrOutput(handle, entry.id, true);
        };
    }
    if (!self.sendWlrState(handle, info.configuration)) return;
    if (!self.sendWlrParent(handle, info.parent)) return;
    protocol.zwlr_foreign_toplevel_handle_v1.@"send:done"(&handle.resource) catch |err| {
        self.eventFailure(handle.client, &handle.resource.runtime, err);
        return;
    };
    handle.initialized = true;
}

fn sendWlrState(self: *WayringForeignToplevelList, handle: *WlrHandle, state: XdgShell.ToplevelConfigure) bool {
    var values: [4]u32 = undefined;
    var n: usize = 0;
    if (state.maximized) {
        values[n] = 0;
        n += 1;
    }
    if (state.suspended) {
        values[n] = 1;
        n += 1;
    }
    if (state.activated) {
        values[n] = 2;
        n += 1;
    }
    if (state.fullscreen and handle.resource.version() >= 2) {
        values[n] = 3;
        n += 1;
    }
    protocol.zwlr_foreign_toplevel_handle_v1.@"send:state"(&handle.resource, std.mem.sliceAsBytes(values[0..n])) catch |err| {
        self.eventFailure(handle.client, &handle.resource.runtime, err);
        return false;
    };
    return true;
}

fn sendWlrParent(self: *WayringForeignToplevelList, handle: *WlrHandle, parent_window: ?XdgShell.WindowId) bool {
    if (handle.resource.version() < 3) return true;
    const parent_id: ?u32 = if (parent_window) |window| parent: {
        const mapping = self.mappingFor(window) orelse break :parent null;
        const parent_handle = self.wlrHandleFor(handle.generation, mapping) orelse return true;
        break :parent parent_handle.resource.id();
    } else null;
    protocol.zwlr_foreign_toplevel_handle_v1.@"send:parent"(&handle.resource, parent_id) catch |err| {
        self.eventFailure(handle.client, &handle.resource.runtime, err);
        return false;
    };
    return true;
}

fn outputIndex(handle: *const WlrHandle, id: OutputLayout.Id) ?usize {
    for (handle.outputs.items, 0..) |candidate, index| if (std.meta.eql(candidate, id)) return index;
    return null;
}

const OutputEvent = struct { handle: *WlrHandle, enter: bool };
fn sendOutputResource(context: *anyopaque, resource: *protocol.wl_output.Resource) void {
    const event: *OutputEvent = @ptrCast(@alignCast(context));
    if (event.enter) {
        protocol.zwlr_foreign_toplevel_handle_v1.@"send:output_enter"(&event.handle.resource, resource.id()) catch |err| event.handle.owner.eventFailure(event.handle.client, &event.handle.resource.runtime, err);
    } else {
        protocol.zwlr_foreign_toplevel_handle_v1.@"send:output_leave"(&event.handle.resource, resource.id()) catch |err| event.handle.owner.eventFailure(event.handle.client, &event.handle.resource.runtime, err);
    }
}
fn sendWlrOutput(self: *WayringForeignToplevelList, handle: *WlrHandle, id: OutputLayout.Id, enter: bool) void {
    const outputs = self.outputs orelse return;
    var event: OutputEvent = .{ .handle = handle, .enter = enter };
    outputs.forEachClientResource(id, handle.client, &event, sendOutputResource);
}

pub fn syncOutput(self: *WayringForeignToplevelList, id: OutputLayout.Id) void {
    const output = (self.output_layout orelse return).get(id) orelse return;
    for (self.wlr_handles.items) |handle| {
        if (!handle.initialized or handle.closed) continue;
        const mapping = handle.mapping orelse continue;
        const index = outputIndex(handle, id);
        const visible = output.containsSurface(mapping.surface);
        if (visible == (index != null)) continue;
        if (visible) {
            handle.outputs.append(self.allocator, id) catch {
                self.eventFailure(handle.client, &handle.resource.runtime, error.OutOfMemory);
                continue;
            };
            self.sendWlrOutput(handle, id, true);
        } else {
            self.sendWlrOutput(handle, id, false);
            _ = handle.outputs.orderedRemove(index.?);
        }
        protocol.zwlr_foreign_toplevel_handle_v1.@"send:done"(&handle.resource) catch |err| self.eventFailure(handle.client, &handle.resource.runtime, err);
    }
}

pub fn removeOutput(self: *WayringForeignToplevelList, id: OutputLayout.Id) void {
    for (self.wlr_handles.items) |handle| {
        if (!handle.initialized or handle.closed) continue;
        const index = outputIndex(handle, id) orelse continue;
        self.sendWlrOutput(handle, id, false);
        _ = handle.outputs.orderedRemove(index);
        protocol.zwlr_foreign_toplevel_handle_v1.@"send:done"(&handle.resource) catch |err| self.eventFailure(handle.client, &handle.resource.runtime, err);
    }
}

fn outputBound(context: *anyopaque, id: OutputLayout.Id, client: *wayring.server.Client, resource: *protocol.wl_output.Resource) void {
    const self: *WayringForeignToplevelList = @ptrCast(@alignCast(context));
    for (self.wlr_handles.items) |handle| {
        if (handle.client != client or !handle.initialized or handle.closed or outputIndex(handle, id) == null) continue;
        protocol.zwlr_foreign_toplevel_handle_v1.@"send:output_enter"(&handle.resource, resource.id()) catch |err| self.eventFailure(client, &handle.resource.runtime, err);
        protocol.zwlr_foreign_toplevel_handle_v1.@"send:done"(&handle.resource) catch |err| self.eventFailure(client, &handle.resource.runtime, err);
    }
}

fn wlrHandleRequest(_: *protocol.zwlr_foreign_toplevel_handle_v1.Resource, request: protocol.zwlr_foreign_toplevel_handle_v1.Request, handle: *WlrHandle) !void {
    if (request == .destroy) return handle.owner.destroyWlrHandle(handle);
    const mapping = handle.mapping orelse return;
    switch (request) {
        .destroy => unreachable,
        .set_maximized => handle.owner.xdg_shell.requestWindow(mapping.window, .maximize),
        .unset_maximized => handle.owner.xdg_shell.requestWindow(mapping.window, .unmaximize),
        .set_minimized => handle.owner.xdg_shell.requestWindow(mapping.window, .minimize),
        .unset_minimized => handle.owner.xdg_shell.requestWindow(mapping.window, .unminimize),
        .close => handle.owner.xdg_shell.closeWindow(mapping.window),
        .set_rectangle => |v| if (v.width < 0 or v.height < 0) handle.client.postProtocolError(&handle.resource.runtime, 0, "rectangle dimensions must not be negative") else if (handle.owner.compositor) |compositor| {
            if (compositor.surfaceId(handle.client, v.surface) == null) return;
        },
        .set_fullscreen => |v| handle.owner.xdg_shell.requestWindow(mapping.window, .{ .fullscreen = if (v.output) |id|
            if (handle.owner.outputs) |outputs| outputs.outputIdForResource(handle.client, id) else null
        else
            null }),
        .unset_fullscreen => handle.owner.xdg_shell.requestWindow(mapping.window, .exit_fullscreen),
        .activate => |v| {
            const canonical_client = handle.owner.seat.seatClientIdentity(handle.client, v.seat) orelse return;
            handle.owner.xdg_shell.requestWindow(mapping.window, .{ .activate = .{ .client = canonical_client, .serial = null, .granted = true } });
        },
    }
}

/// Resolves an exact live same-client EXT handle without exposing adapter
/// storage to protocols which retain only the canonical window identity.
pub fn windowForExtHandle(
    self: *WayringForeignToplevelList,
    client: *wayring.server.Client,
    object_id: u32,
) ?XdgShell.WindowId {
    const installed = client.lookup(object_id) orelse return null;
    for (self.handles.items) |handle| {
        if (handle.client != client or handle.closed or handle.mapping == null or
            handle.resource.state() != .live or &handle.resource.runtime != installed) continue;
        return handle.mapping.?.window;
    }
    return null;
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
    const surface = self.xdg_shell.windowSurface(window) orelse {
        _ = self.mappings.pop();
        self.allocator.destroy(mapping);
        self.allocator.free(identifier);
        return;
    };
    mapping.* = .{ .window = window, .surface = surface, .identifier = identifier };
    self.next_identifier = next;
    for (self.lists.items) |list| self.createHandle(list, mapping) catch |err| self.eventFailure(list.client, &list.resource.runtime, err);
    for (self.wlr_managers.items) |manager| self.createWlrHandle(manager, mapping) catch |err| self.eventFailure(manager.client, &manager.resource.runtime, err);
    for (self.wlr_handles.items) |handle| if (handle.mapping == mapping) self.sendWlrInitial(handle);
    for (self.wlr_handles.items) |handle| if (handle.initialized and !handle.closed and handle.mapping != mapping) {
        const child = handle.mapping orelse continue;
        const child_info = self.xdg_shell.windowInfo(child.window) orelse continue;
        if (child_info.parent == null or !std.meta.eql(child_info.parent.?, window) or handle.resource.version() < 3) continue;
        const parent = self.wlrHandleFor(handle.generation, mapping) orelse continue;
        protocol.zwlr_foreign_toplevel_handle_v1.@"send:parent"(&handle.resource, parent.resource.id()) catch |err| self.eventFailure(handle.client, &handle.resource.runtime, err);
        protocol.zwlr_foreign_toplevel_handle_v1.@"send:done"(&handle.resource) catch |err| self.eventFailure(handle.client, &handle.resource.runtime, err);
    };
}
fn committed(context: *anyopaque, window: XdgShell.WindowId) void {
    const self: *WayringForeignToplevelList = @ptrCast(@alignCast(context));
    self.syncWindow(window);
}
fn stateChanged(context: *anyopaque, window: XdgShell.WindowId) void {
    const self: *WayringForeignToplevelList = @ptrCast(@alignCast(context));
    self.syncWindow(window);
    const mapping = self.mappingFor(window) orelse return;
    const info = self.xdg_shell.windowInfo(window) orelse return;
    for (self.wlr_handles.items) |handle| if (handle.mapping == mapping and !handle.closed and handle.initialized) {
        if (!self.sendWlrState(handle, info.configuration)) continue;
        protocol.zwlr_foreign_toplevel_handle_v1.@"send:done"(&handle.resource) catch |err| self.eventFailure(handle.client, &handle.resource.runtime, err);
    };
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
    for (self.wlr_handles.items) |handle| if (handle.mapping == mapping and !handle.closed) {
        protocol.zwlr_foreign_toplevel_handle_v1.@"send:title"(&handle.resource, info.title orelse "") catch |err| self.eventFailure(handle.client, &handle.resource.runtime, err);
        protocol.zwlr_foreign_toplevel_handle_v1.@"send:app_id"(&handle.resource, info.app_id orelse "") catch |err| self.eventFailure(handle.client, &handle.resource.runtime, err);
        if (!self.sendWlrParent(handle, info.parent)) continue;
        protocol.zwlr_foreign_toplevel_handle_v1.@"send:done"(&handle.resource) catch |err| self.eventFailure(handle.client, &handle.resource.runtime, err);
    };
}

fn removeWindow(self: *WayringForeignToplevelList, window: XdgShell.WindowId) void {
    const mapping = self.mappingFor(window) orelse return;
    for (self.wlr_handles.items) |handle| if (handle.initialized and !handle.closed and handle.mapping != mapping and handle.resource.version() >= 3) {
        const child = handle.mapping orelse continue;
        const info = self.xdg_shell.windowInfo(child.window) orelse continue;
        if (info.parent == null or !std.meta.eql(info.parent.?, window)) continue;
        protocol.zwlr_foreign_toplevel_handle_v1.@"send:parent"(&handle.resource, null) catch |err| self.eventFailure(handle.client, &handle.resource.runtime, err);
        protocol.zwlr_foreign_toplevel_handle_v1.@"send:done"(&handle.resource) catch |err| self.eventFailure(handle.client, &handle.resource.runtime, err);
    };
    for (self.handles.items) |handle| if (handle.mapping == mapping and !handle.closed) {
        handle.closed = true;
        handle.mapping = null;
        protocol.ext_foreign_toplevel_handle_v1.@"send:closed"(&handle.resource) catch |err| self.eventFailure(handle.client, &handle.resource.runtime, err);
    };
    for (self.wlr_handles.items) |handle| if (handle.mapping == mapping and !handle.closed) {
        handle.closed = true;
        handle.mapping = null;
        handle.outputs.clearRetainingCapacity();
        protocol.zwlr_foreign_toplevel_handle_v1.@"send:closed"(&handle.resource) catch |err| self.eventFailure(handle.client, &handle.resource.runtime, err);
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
fn wlrHandleFor(self: *WayringForeignToplevelList, generation: u64, mapping: *Mapping) ?*WlrHandle {
    for (self.wlr_handles.items) |handle| if (handle.generation == generation and handle.mapping == mapping and !handle.closed) return handle;
    return null;
}
fn destroyWlrManager(self: *WayringForeignToplevelList, manager: *WlrManager) void {
    for (self.wlr_managers.items, 0..) |value, i| if (value == manager) {
        _ = self.wlr_managers.swapRemove(i);
        break;
    };
    manager.resource.destroy();
    manager.resource.deinit();
    self.allocator.destroy(manager);
}
fn destroyWlrHandle(self: *WayringForeignToplevelList, handle: *WlrHandle) void {
    for (self.wlr_handles.items, 0..) |value, i| if (value == handle) {
        _ = self.wlr_handles.swapRemove(i);
        break;
    };
    handle.resource.destroy();
    handle.resource.deinit();
    handle.outputs.deinit(self.allocator);
    self.allocator.destroy(handle);
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
    var i = self.wlr_handles.items.len;
    while (i > 0) {
        i -= 1;
        if (self.wlr_handles.items[i].client == client) self.destroyWlrHandle(self.wlr_handles.items[i]);
    }
    i = self.wlr_managers.items.len;
    while (i > 0) {
        i -= 1;
        if (self.wlr_managers.items[i].client == client) self.destroyWlrManager(self.wlr_managers.items[i]);
    }
    i = self.handles.items.len;
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
    for (self.wlr_managers.items) |manager| manager.client.postOutOfMemory(&manager.resource.runtime, "tracking foreign toplevel");
}
fn eventFailure(_: *WayringForeignToplevelList, client: *wayring.server.Client, resource: *wayring.server.Resource, _: anyerror) void {
    client.postOutOfMemory(resource, "queueing foreign toplevel event");
}

test "EXT and WLR foreign toplevel descriptors are exact" {
    try std.testing.expectEqual(@as(u32, 1), protocol.ext_foreign_toplevel_list_v1.interface.version);
    try std.testing.expectEqualStrings("toplevel", protocol.ext_foreign_toplevel_list_v1.event_messages[0].name);
    try std.testing.expectEqualStrings("identifier", protocol.ext_foreign_toplevel_handle_v1.event_messages[4].name);

    const manager = protocol.zwlr_foreign_toplevel_manager_v1;
    const handle = protocol.zwlr_foreign_toplevel_handle_v1;
    try std.testing.expectEqual(@as(u32, 3), manager.interface.version);
    try expectNames(&manager.request_messages, &.{"stop"});
    try expectNames(&manager.event_messages, &.{ "toplevel", "finished" });
    try expectNames(&handle.request_messages, &.{
        "set_maximized",  "unset_maximized",  "set_minimized", "unset_minimized",
        "activate",       "close",            "set_rectangle", "destroy",
        "set_fullscreen", "unset_fullscreen",
    });
    try expectNames(&handle.event_messages, &.{
        "title", "app_id", "output_enter", "output_leave", "state", "done", "closed", "parent",
    });
    try std.testing.expectEqual(@as(u32, 2), handle.request_messages[8].since);
    try std.testing.expectEqual(@as(u32, 2), handle.request_messages[9].since);
    try std.testing.expectEqual(@as(u32, 3), handle.event_messages[7].since);
    try std.testing.expectEqual(@as(i64, 0), handle.@"error".invalid_rectangle);
}

fn expectNames(messages: anytype, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, messages.len);
    for (messages, expected) |message, name| try std.testing.expectEqualStrings(name, message.name);
}
