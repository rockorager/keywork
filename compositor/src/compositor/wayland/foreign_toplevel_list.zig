//! Privileged mapped-toplevel discovery and compatibility controls.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Output = @import("output.zig");
const OutputLayout = @import("output_layout.zig");
const SecurityContext = @import("security_context.zig");
const Seat = @import("seat.zig");
const Surface = @import("surface.zig");
const XdgShell = @import("xdg_shell.zig");
const Xwm = @import("../xwayland/xwm.zig");

const wl = wayland.server.wl;
const ext = wayland.server.ext;
const zwlr = wayland.server.zwlr;

allocator: std.mem.Allocator,
ext_global: *wl.Global,
wlr_global: *wl.Global,
security_context: *SecurityContext,
xdg_shell: *XdgShell,
xwayland: XwaylandController,
outputs: *OutputLayout,
lists: std.ArrayList(*List),
mappings: std.ArrayList(*Mapping),
handles: std.ArrayList(*Handle),
wlr_managers: std.ArrayList(*WlrManager),
wlr_handles: std.ArrayList(*WlrHandle),
next_identifier: u64,
next_wlr_manager_generation: u64,

const Mapping = struct {
    backend: Backend,
    surface_id: Surface.Id,
    identifier: [:0]u8,

    const Backend = union(enum) {
        xdg: XdgShell.WindowId,
        xwayland: Xwm.WindowId,
    };

    fn xdgId(self: *const Mapping) ?XdgShell.WindowId {
        return switch (self.backend) {
            .xdg => |id| id,
            .xwayland => null,
        };
    }
};

pub const XwaylandController = struct {
    context: *anyopaque,
    window_info: *const fn (*anyopaque, Xwm.WindowId) ?Xwm.WindowInfo,
    close: *const fn (*anyopaque, Xwm.WindowId) void,
    request_activation: *const fn (*anyopaque, Xwm.WindowId, *Seat) void,
    request_fullscreen: *const fn (*anyopaque, Xwm.WindowId, bool, ?OutputLayout.Id) void,
    request_maximized: *const fn (*anyopaque, Xwm.WindowId, bool) void,
    request_minimized: *const fn (*anyopaque, Xwm.WindowId, bool) void,
};

const List = struct {
    manager: *Self,
    resource: *ext.ForeignToplevelListV1,
    stopped: bool = false,

    fn create(manager: *Self, client: *wl.Client, version: u32, id: u32) !void {
        const resource = try ext.ForeignToplevelListV1.create(client, version, id);
        errdefer resource.destroy();
        const self = try manager.allocator.create(List);
        errdefer manager.allocator.destroy(self);
        self.* = .{ .manager = manager, .resource = resource };
        try manager.lists.append(manager.allocator, self);
        resource.setHandler(*List, handleRequest, handleDestroy, self);
        manager.syncMappedWindows();
        for (manager.mappings.items) |mapping| {
            if (manager.handleFor(self, mapping) != null) continue;
            Handle.create(self, mapping) catch {
                resource.postNoMemory();
                return;
            };
        }
    }

    fn handleRequest(
        resource: *ext.ForeignToplevelListV1,
        request: ext.ForeignToplevelListV1.Request,
        self: *List,
    ) void {
        switch (request) {
            .stop => {
                if (self.stopped) return;
                self.stopped = true;
                resource.sendFinished();
            },
            .destroy => resource.destroy(),
        }
    }

    fn handleDestroy(_: *ext.ForeignToplevelListV1, self: *List) void {
        for (self.manager.handles.items) |handle| {
            if (handle.list == self) handle.list = null;
        }
        for (self.manager.lists.items, 0..) |list, index| {
            if (list != self) continue;
            _ = self.manager.lists.swapRemove(index);
            break;
        }
        self.manager.allocator.destroy(self);
    }
};

const Handle = struct {
    manager: *Self,
    list: ?*List,
    mapping: ?*Mapping,
    resource: *ext.ForeignToplevelHandleV1,
    closed: bool = false,

    fn create(list: *List, mapping: *Mapping) !void {
        const resource = try ext.ForeignToplevelHandleV1.create(
            list.resource.getClient(),
            list.resource.getVersion(),
            0,
        );
        errdefer resource.destroy();
        const self = try list.manager.allocator.create(Handle);
        errdefer list.manager.allocator.destroy(self);
        self.* = .{
            .manager = list.manager,
            .list = list,
            .mapping = mapping,
            .resource = resource,
        };
        try list.manager.handles.append(list.manager.allocator, self);
        resource.setHandler(*Handle, handleRequest, handleDestroy, self);
        list.resource.sendToplevel(resource);
        resource.sendIdentifier(mapping.identifier.ptr);
        if (list.manager.mappingMetadata(mapping)) |metadata| {
            if (metadata.title) |title| resource.sendTitle(title.ptr);
            if (metadata.app_id) |app_id| resource.sendAppId(app_id.ptr);
        }
        resource.sendDone();
    }

    fn handleRequest(
        resource: *ext.ForeignToplevelHandleV1,
        request: ext.ForeignToplevelHandleV1.Request,
        _: *Handle,
    ) void {
        if (request == .destroy) resource.destroy();
    }

    fn handleDestroy(_: *ext.ForeignToplevelHandleV1, self: *Handle) void {
        for (self.manager.handles.items, 0..) |handle, index| {
            if (handle != self) continue;
            _ = self.manager.handles.swapRemove(index);
            break;
        }
        self.manager.allocator.destroy(self);
    }

    fn close(self: *Handle) void {
        if (self.closed) return;
        self.closed = true;
        self.mapping = null;
        self.resource.sendClosed();
    }
};

const WlrManager = struct {
    owner: *Self,
    resource: *zwlr.ForeignToplevelManagerV1,
    generation: u64,

    fn create(owner: *Self, client: *wl.Client, version: u32, id: u32) !void {
        const resource = try zwlr.ForeignToplevelManagerV1.create(client, version, id);
        errdefer resource.destroy();
        const self = try owner.allocator.create(WlrManager);
        errdefer owner.allocator.destroy(self);
        const generation = std.math.add(u64, owner.next_wlr_manager_generation, 1) catch
            return error.OutOfMemory;
        self.* = .{ .owner = owner, .resource = resource, .generation = generation };
        try owner.wlr_managers.append(owner.allocator, self);
        owner.next_wlr_manager_generation = generation;
        resource.setHandler(*WlrManager, handleRequest, handleDestroy, self);

        owner.syncMappedWindows();
        for (owner.mappings.items) |mapping| {
            if (owner.wlrHandleFor(generation, mapping) != null) continue;
            WlrHandle.create(self, mapping) catch {
                resource.postNoMemory();
                return;
            };
        }
        for (owner.wlr_handles.items) |handle| {
            if (handle.binding_generation != generation or handle.initialized) continue;
            handle.sendInitialDetails() catch {
                resource.postNoMemory();
                return;
            };
        }
    }

    fn handleRequest(
        resource: *zwlr.ForeignToplevelManagerV1,
        request: zwlr.ForeignToplevelManagerV1.Request,
        _: *WlrManager,
    ) void {
        if (request == .stop) resource.destroySendFinished();
    }

    fn handleDestroy(_: *zwlr.ForeignToplevelManagerV1, self: *WlrManager) void {
        for (self.owner.wlr_managers.items, 0..) |manager, index| {
            if (manager != self) continue;
            _ = self.owner.wlr_managers.swapRemove(index);
            break;
        }
        self.owner.allocator.destroy(self);
    }
};

const WlrHandle = struct {
    owner: *Self,
    binding_generation: u64,
    mapping: ?*Mapping,
    resource: *zwlr.ForeignToplevelHandleV1,
    outputs: std.ArrayList(OutputLayout.Id) = .empty,
    initialized: bool = false,
    closed: bool = false,

    fn create(manager: *WlrManager, mapping: *Mapping) !void {
        const resource = try zwlr.ForeignToplevelHandleV1.create(
            manager.resource.getClient(),
            manager.resource.getVersion(),
            0,
        );
        errdefer resource.destroy();
        const self = try manager.owner.allocator.create(WlrHandle);
        errdefer manager.owner.allocator.destroy(self);
        self.* = .{
            .owner = manager.owner,
            .binding_generation = manager.generation,
            .mapping = mapping,
            .resource = resource,
        };
        try manager.owner.wlr_handles.append(manager.owner.allocator, self);
        resource.setHandler(*WlrHandle, handleRequest, handleDestroy, self);
        manager.resource.sendToplevel(resource);
    }

    fn sendInitialDetails(self: *WlrHandle) !void {
        std.debug.assert(!self.initialized and !self.closed);
        const mapping = self.mapping orelse return;
        const metadata = self.owner.mappingMetadata(mapping) orelse return;
        if (metadata.title) |title| self.resource.sendTitle(title.ptr);
        if (metadata.app_id) |app_id| self.resource.sendAppId(app_id.ptr);
        var outputs = self.owner.outputs.iterator();
        while (outputs.next()) |entry| {
            if (!entry.output.containsSurface(mapping.surface_id)) continue;
            try self.outputs.append(self.owner.allocator, entry.id);
            self.sendOutput(entry.output, true);
        }
        self.sendState(self.owner.mappingConfiguration(mapping));
        self.sendParent(self.owner.mappingParent(mapping));
        self.resource.sendDone();
        self.initialized = true;
    }

    fn handleRequest(
        resource: *zwlr.ForeignToplevelHandleV1,
        request: zwlr.ForeignToplevelHandleV1.Request,
        self: *WlrHandle,
    ) void {
        if (request == .destroy) {
            resource.destroy();
            return;
        }
        const mapping = self.mapping orelse return;
        switch (mapping.backend) {
            .xdg => |window_id| switch (request) {
                .destroy => unreachable,
                .set_maximized => self.owner.xdg_shell.requestWindow(window_id, .maximize),
                .unset_maximized => self.owner.xdg_shell.requestWindow(window_id, .unmaximize),
                .set_minimized => self.owner.xdg_shell.requestWindow(window_id, .minimize),
                .unset_minimized => self.owner.xdg_shell.requestWindow(window_id, .unminimize),
                .activate => |activate| self.owner.xdg_shell.requestWindow(
                    window_id,
                    .{ .activate = Seat.fromResource(activate.seat) },
                ),
                .close => self.owner.xdg_shell.closeWindow(window_id),
                .set_rectangle => |rectangle| validateRectangle(resource, rectangle.width, rectangle.height),
                .set_fullscreen => |fullscreen| self.owner.xdg_shell.requestWindow(
                    window_id,
                    .{ .fullscreen = fullscreen.output },
                ),
                .unset_fullscreen => self.owner.xdg_shell.requestWindow(window_id, .exit_fullscreen),
            },
            .xwayland => |window_id| switch (request) {
                .destroy => unreachable,
                .close => self.owner.xwayland.close(self.owner.xwayland.context, window_id),
                .set_rectangle => |rectangle| validateRectangle(resource, rectangle.width, rectangle.height),
                .activate => |activate| self.owner.xwayland.request_activation(
                    self.owner.xwayland.context,
                    window_id,
                    Seat.fromResource(activate.seat),
                ),
                .set_maximized => self.owner.xwayland.request_maximized(
                    self.owner.xwayland.context,
                    window_id,
                    true,
                ),
                .unset_maximized => self.owner.xwayland.request_maximized(
                    self.owner.xwayland.context,
                    window_id,
                    false,
                ),
                .set_minimized => self.owner.xwayland.request_minimized(
                    self.owner.xwayland.context,
                    window_id,
                    true,
                ),
                .unset_minimized => self.owner.xwayland.request_minimized(
                    self.owner.xwayland.context,
                    window_id,
                    false,
                ),
                .set_fullscreen => |fullscreen| self.owner.xwayland.request_fullscreen(
                    self.owner.xwayland.context,
                    window_id,
                    true,
                    if (fullscreen.output) |output_resource|
                        if (self.owner.outputs.findResource(output_resource)) |output|
                            output.id
                        else
                            null
                    else
                        null,
                ),
                .unset_fullscreen => self.owner.xwayland.request_fullscreen(
                    self.owner.xwayland.context,
                    window_id,
                    false,
                    null,
                ),
            },
        }
    }

    fn handleDestroy(_: *zwlr.ForeignToplevelHandleV1, self: *WlrHandle) void {
        for (self.owner.wlr_handles.items, 0..) |handle, index| {
            if (handle != self) continue;
            _ = self.owner.wlr_handles.swapRemove(index);
            break;
        }
        self.outputs.deinit(self.owner.allocator);
        self.owner.allocator.destroy(self);
    }

    fn sendOutput(self: *WlrHandle, output: *Output, enter: bool) void {
        for (output.boundResources()) |output_resource| {
            if (output_resource.getClient() != self.resource.getClient()) continue;
            if (enter) {
                self.resource.sendOutputEnter(output_resource);
            } else {
                self.resource.sendOutputLeave(output_resource);
            }
        }
    }

    fn sendState(self: *WlrHandle, configuration: XdgShell.ToplevelConfigure) void {
        var values: [4]u32 = undefined;
        var count: usize = 0;
        if (configuration.maximized) appendWlrState(&values, &count, .maximized);
        if (configuration.suspended) appendWlrState(&values, &count, .minimized);
        if (configuration.activated) appendWlrState(&values, &count, .activated);
        if (self.resource.getVersion() >= 2 and configuration.fullscreen) {
            appendWlrState(&values, &count, .fullscreen);
        }
        var array: wl.Array = .{
            .size = count * @sizeOf(u32),
            .alloc = count * @sizeOf(u32),
            .data = if (count == 0) null else @ptrCast(&values),
        };
        self.resource.sendState(&array);
    }

    fn sendParent(self: *WlrHandle, parent_mapping: ?*Mapping) void {
        if (self.resource.getVersion() < 3) return;
        if (parent_mapping) |mapping| {
            const parent = self.owner.wlrHandleFor(self.binding_generation, mapping) orelse return;
            self.resource.sendParent(parent.resource);
        } else {
            self.resource.sendParent(null);
        }
    }

    fn outputIndex(self: *const WlrHandle, output_id: OutputLayout.Id) ?usize {
        for (self.outputs.items, 0..) |candidate, index| {
            if (std.meta.eql(candidate, output_id)) return index;
        }
        return null;
    }

    fn close(self: *WlrHandle) void {
        if (self.closed) return;
        self.closed = true;
        self.mapping = null;
        self.outputs.clearRetainingCapacity();
        self.resource.sendClosed();
    }
};

fn appendWlrState(
    values: *[4]u32,
    count: *usize,
    state: zwlr.ForeignToplevelHandleV1.State,
) void {
    values[count.*] = @intCast(@intFromEnum(state));
    count.* += 1;
}

fn validateRectangle(
    resource: *zwlr.ForeignToplevelHandleV1,
    width: i32,
    height: i32,
) void {
    if (width < 0 or height < 0) {
        resource.postError(.invalid_rectangle, "rectangle dimensions must not be negative");
    }
}

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    security_context: *SecurityContext,
    xdg_shell: *XdgShell,
    xwayland: XwaylandController,
    outputs: *OutputLayout,
) !void {
    self.* = .{
        .allocator = allocator,
        .ext_global = undefined,
        .wlr_global = undefined,
        .security_context = security_context,
        .xdg_shell = xdg_shell,
        .xwayland = xwayland,
        .outputs = outputs,
        .lists = .empty,
        .mappings = .empty,
        .handles = .empty,
        .wlr_managers = .empty,
        .wlr_handles = .empty,
        .next_identifier = 0,
        .next_wlr_manager_generation = 0,
    };
    errdefer self.lists.deinit(allocator);
    errdefer self.mappings.deinit(allocator);
    errdefer self.handles.deinit(allocator);
    errdefer self.wlr_managers.deinit(allocator);
    errdefer self.wlr_handles.deinit(allocator);
    self.ext_global = try wl.Global.create(
        display,
        ext.ForeignToplevelListV1,
        1,
        *Self,
        self,
        bind,
    );
    errdefer self.ext_global.destroy();
    try security_context.restrictGlobal(self.ext_global);
    errdefer security_context.unrestrictGlobal(self.ext_global);
    self.wlr_global = try wl.Global.create(
        display,
        zwlr.ForeignToplevelManagerV1,
        3,
        *Self,
        self,
        bindWlr,
    );
    errdefer self.wlr_global.destroy();
    try security_context.restrictGlobal(self.wlr_global);
    errdefer security_context.unrestrictGlobal(self.wlr_global);
    try xdg_shell.addWindowObserver(.{
        .context = self,
        .committed = windowCommitted,
        .unmapped = windowUnmapped,
        .destroyed = windowDestroyed,
        .metadata_changed = windowMetadataChanged,
        .state_changed = windowStateChanged,
    });
    errdefer xdg_shell.removeWindowObserver(self);
    self.syncMappedWindows();
}

pub fn deinit(self: *Self) void {
    self.xdg_shell.removeWindowObserver(self);
    self.security_context.unrestrictGlobal(self.wlr_global);
    self.wlr_global.destroy();
    self.security_context.unrestrictGlobal(self.ext_global);
    self.ext_global.destroy();
    std.debug.assert(self.lists.items.len == 0);
    std.debug.assert(self.handles.items.len == 0);
    std.debug.assert(self.wlr_managers.items.len == 0);
    std.debug.assert(self.wlr_handles.items.len == 0);
    for (self.mappings.items) |mapping| self.destroyMapping(mapping);
    self.wlr_handles.deinit(self.allocator);
    self.wlr_managers.deinit(self.allocator);
    self.handles.deinit(self.allocator);
    self.mappings.deinit(self.allocator);
    self.lists.deinit(self.allocator);
    self.* = undefined;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    List.create(self, client, version, id) catch client.postNoMemory();
}

fn bindWlr(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    WlrManager.create(self, client, version, id) catch client.postNoMemory();
}

fn syncMappedWindows(self: *Self) void {
    var windows = self.xdg_shell.windowIterator();
    while (windows.next()) |window_id| {
        const info = self.xdg_shell.windowInfo(window_id) orelse continue;
        if (!info.mapped or self.mappingForXdg(window_id) != null) continue;
        const surface_id = self.xdg_shell.windowSurface(window_id) orelse continue;
        self.addMapping(.{ .xdg = window_id }, surface_id) catch self.postNoMemory();
    }
}

fn addMapping(self: *Self, backend: Mapping.Backend, surface_id: Surface.Id) !void {
    self.next_identifier = std.math.add(u64, self.next_identifier, 1) catch
        return error.OutOfMemory;
    const identifier = try identifierFor(self.allocator, self.next_identifier);
    errdefer self.allocator.free(identifier);
    const mapping = try self.allocator.create(Mapping);
    errdefer self.allocator.destroy(mapping);
    mapping.* = .{
        .backend = backend,
        .surface_id = surface_id,
        .identifier = identifier,
    };
    try self.mappings.append(self.allocator, mapping);
    for (self.lists.items) |list| {
        if (list.stopped) continue;
        Handle.create(list, mapping) catch list.resource.postNoMemory();
    }
    for (self.wlr_managers.items) |manager| {
        WlrHandle.create(manager, mapping) catch manager.resource.postNoMemory();
    }
    for (self.wlr_handles.items) |handle| {
        if (handle.mapping != mapping or handle.initialized) continue;
        handle.sendInitialDetails() catch handle.resource.postNoMemory();
    }
    self.syncWlrChildParents(mapping);
}

fn removeMapping(self: *Self, target: *Mapping) void {
    for (self.mappings.items, 0..) |mapping, index| {
        if (mapping != target) continue;
        for (self.handles.items) |handle| {
            if (handle.mapping == mapping) handle.close();
        }
        for (self.wlr_handles.items) |handle| {
            if (handle.mapping == mapping) handle.close();
        }
        self.clearWlrChildParents(mapping);
        _ = self.mappings.swapRemove(index);
        self.destroyMapping(mapping);
        return;
    }
}

fn destroyMapping(self: *Self, mapping: *Mapping) void {
    self.allocator.free(mapping.identifier);
    self.allocator.destroy(mapping);
}

fn mappingForXdg(self: *Self, window_id: XdgShell.WindowId) ?*Mapping {
    for (self.mappings.items) |mapping| {
        const candidate = mapping.xdgId() orelse continue;
        if (std.meta.eql(candidate, window_id)) return mapping;
    }
    return null;
}

fn mappingForXwayland(self: *Self, window_id: Xwm.WindowId) ?*Mapping {
    for (self.mappings.items) |mapping| switch (mapping.backend) {
        .xdg => {},
        .xwayland => |candidate| if (candidate == window_id) return mapping,
    };
    return null;
}

const MappingMetadata = struct {
    title: ?[:0]const u8,
    app_id: ?[:0]const u8,
};

fn mappingMetadata(self: *Self, mapping: *const Mapping) ?MappingMetadata {
    return switch (mapping.backend) {
        .xdg => |window_id| metadata: {
            const info = self.xdg_shell.windowInfo(window_id) orelse return null;
            break :metadata .{ .title = info.title, .app_id = info.app_id };
        },
        .xwayland => |window_id| metadata: {
            const info = self.xwayland.window_info(self.xwayland.context, window_id) orelse
                return null;
            break :metadata .{ .title = info.title, .app_id = info.app_id };
        },
    };
}

fn mappingConfiguration(self: *Self, mapping: *const Mapping) XdgShell.ToplevelConfigure {
    return switch (mapping.backend) {
        .xdg => |window_id| (self.xdg_shell.windowInfo(window_id) orelse return .{}).configuration,
        .xwayland => |window_id| configuration: {
            const info = self.xwayland.window_info(
                self.xwayland.context,
                window_id,
            ) orelse return .{};
            break :configuration .{
                .fullscreen = info.fullscreen,
                .maximized = info.maximized,
                .suspended = info.minimized,
                .activated = info.activated,
            };
        },
    };
}

fn mappingParent(self: *Self, mapping: *const Mapping) ?*Mapping {
    return switch (mapping.backend) {
        .xdg => |window_id| parent: {
            const info = self.xdg_shell.windowInfo(window_id) orelse return null;
            break :parent self.mappingForXdg(info.parent orelse return null);
        },
        .xwayland => |window_id| parent: {
            const info = self.xwayland.window_info(self.xwayland.context, window_id) orelse
                return null;
            break :parent self.mappingForXwayland(info.parent orelse return null);
        },
    };
}

fn handleFor(self: *Self, list: *List, mapping: *Mapping) ?*Handle {
    for (self.handles.items) |handle| {
        if (handle.list == list and handle.mapping == mapping) return handle;
    }
    return null;
}

fn wlrHandleFor(self: *Self, generation: u64, mapping: *Mapping) ?*WlrHandle {
    for (self.wlr_handles.items) |handle| {
        if (handle.binding_generation == generation and handle.mapping == mapping) return handle;
    }
    return null;
}

fn postNoMemory(self: *Self) void {
    for (self.lists.items) |list| list.resource.postNoMemory();
    for (self.wlr_managers.items) |manager| manager.resource.postNoMemory();
}

pub fn syncOutput(self: *Self, output_id: OutputLayout.Id) void {
    const output = self.outputs.get(output_id) orelse return;
    for (self.wlr_handles.items) |handle| {
        if (!handle.initialized or handle.closed) continue;
        const mapping = handle.mapping orelse continue;
        const current_index = handle.outputIndex(output_id);
        const visible = output.containsSurface(mapping.surface_id);
        if (visible == (current_index != null)) continue;
        if (visible) {
            handle.outputs.append(self.allocator, output_id) catch {
                handle.resource.postNoMemory();
                continue;
            };
            handle.sendOutput(output, true);
        } else {
            handle.sendOutput(output, false);
            _ = handle.outputs.orderedRemove(current_index.?);
        }
        handle.resource.sendDone();
    }
}

pub fn removeOutput(self: *Self, output_id: OutputLayout.Id) void {
    const output = self.outputs.get(output_id) orelse return;
    for (self.wlr_handles.items) |handle| {
        if (!handle.initialized or handle.closed) continue;
        const index = handle.outputIndex(output_id) orelse continue;
        handle.sendOutput(output, false);
        _ = handle.outputs.orderedRemove(index);
        handle.resource.sendDone();
    }
}

pub fn windowForExtHandle(
    self: *Self,
    resource: *ext.ForeignToplevelHandleV1,
) ?XdgShell.WindowId {
    for (self.handles.items) |handle| {
        if (handle.resource != resource or handle.closed) continue;
        return (handle.mapping orelse return null).xdgId();
    }
    return null;
}

fn syncWlrChildParents(self: *Self, parent_mapping: *Mapping) void {
    for (self.wlr_handles.items) |handle| {
        if (!handle.initialized or handle.closed) continue;
        const mapping = handle.mapping orelse continue;
        if (self.mappingParent(mapping) != parent_mapping) continue;
        handle.sendParent(parent_mapping);
        handle.resource.sendDone();
    }
}

fn clearWlrChildParents(self: *Self, parent_mapping: *Mapping) void {
    for (self.wlr_handles.items) |handle| {
        if (!handle.initialized or handle.closed or handle.resource.getVersion() < 3) continue;
        const mapping = handle.mapping orelse continue;
        if (self.mappingParent(mapping) != parent_mapping) continue;
        handle.resource.sendParent(null);
        handle.resource.sendDone();
    }
}

fn windowCommitted(context: *anyopaque, window_id: XdgShell.WindowId) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const info = self.xdg_shell.windowInfo(window_id) orelse return;
    if (!info.mapped or self.mappingForXdg(window_id) != null) return;
    const surface_id = self.xdg_shell.windowSurface(window_id) orelse return;
    self.addMapping(.{ .xdg = window_id }, surface_id) catch self.postNoMemory();
}

fn windowUnmapped(context: *anyopaque, window_id: XdgShell.WindowId) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.removeMapping(self.mappingForXdg(window_id) orelse return);
}

fn windowDestroyed(context: *anyopaque, window_id: XdgShell.WindowId) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.removeMapping(self.mappingForXdg(window_id) orelse return);
}

fn windowMetadataChanged(context: *anyopaque, window_id: XdgShell.WindowId) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const mapping = self.mappingForXdg(window_id) orelse return;
    self.sendMetadata(mapping);
}

fn sendMetadata(self: *Self, mapping: *Mapping) void {
    const metadata = self.mappingMetadata(mapping) orelse return;
    for (self.handles.items) |handle| {
        if (handle.mapping != mapping or handle.closed) continue;
        handle.resource.sendTitle(if (metadata.title) |title| title.ptr else "");
        handle.resource.sendAppId(if (metadata.app_id) |app_id| app_id.ptr else "");
        handle.resource.sendDone();
    }
    for (self.wlr_handles.items) |handle| {
        if (handle.mapping != mapping or !handle.initialized or handle.closed) continue;
        handle.resource.sendTitle(if (metadata.title) |title| title.ptr else "");
        handle.resource.sendAppId(if (metadata.app_id) |app_id| app_id.ptr else "");
        handle.sendParent(self.mappingParent(mapping));
        handle.resource.sendDone();
    }
}

fn windowStateChanged(context: *anyopaque, window_id: XdgShell.WindowId) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const mapping = self.mappingForXdg(window_id) orelse return;
    const info = self.xdg_shell.windowInfo(window_id) orelse return;
    for (self.wlr_handles.items) |handle| {
        if (handle.mapping != mapping or !handle.initialized or handle.closed) continue;
        handle.sendState(info.configuration);
        handle.resource.sendDone();
    }
}

pub fn xwaylandWindowAssociated(
    self: *Self,
    window_id: Xwm.WindowId,
    surface_id: Surface.Id,
) error{OutOfMemory}!void {
    const info = self.xwayland.window_info(self.xwayland.context, window_id) orelse return;
    if (!info.appearsInForeignToplevelList() or self.mappingForXwayland(window_id) != null) return;
    try self.addMapping(.{ .xwayland = window_id }, surface_id);
}

pub fn xwaylandWindowDissociated(self: *Self, window_id: Xwm.WindowId) void {
    self.removeMapping(self.mappingForXwayland(window_id) orelse return);
}

pub fn xwaylandWindowMapped(
    self: *Self,
    window_id: Xwm.WindowId,
    mapped: bool,
    surface_id: ?Surface.Id,
) error{OutOfMemory}!void {
    if (!mapped) {
        self.xwaylandWindowDissociated(window_id);
        return;
    }
    if (self.mappingForXwayland(window_id) != null) return;
    const info = self.xwayland.window_info(self.xwayland.context, window_id) orelse return;
    if (!info.appearsInForeignToplevelList()) return;
    try self.addMapping(.{ .xwayland = window_id }, surface_id orelse return);
}

pub fn xwaylandWindowConfigured(
    self: *Self,
    window_id: Xwm.WindowId,
    override_redirect: bool,
    surface_id: ?Surface.Id,
) error{OutOfMemory}!void {
    if (override_redirect) {
        self.xwaylandWindowDissociated(window_id);
        return;
    }
    const info = self.xwayland.window_info(self.xwayland.context, window_id) orelse return;
    if (!info.appearsInForeignToplevelList() or self.mappingForXwayland(window_id) != null) return;
    try self.addMapping(.{ .xwayland = window_id }, surface_id orelse return);
}

pub fn xwaylandWindowMetadataChanged(
    self: *Self,
    window_id: Xwm.WindowId,
) error{OutOfMemory}!void {
    const info = self.xwayland.window_info(self.xwayland.context, window_id) orelse return;
    const mapping = self.mappingForXwayland(window_id);
    if (!info.appearsInForeignToplevelList()) {
        self.removeMapping(mapping orelse return);
        return;
    }
    if (mapping) |id| {
        self.sendMetadata(id);
    } else {
        try self.addMapping(.{ .xwayland = window_id }, info.surface_id orelse return);
    }
}

pub fn xwaylandWindowStateChanged(self: *Self, window_id: Xwm.WindowId) void {
    const mapping = self.mappingForXwayland(window_id) orelse return;
    const configuration = self.mappingConfiguration(mapping);
    for (self.wlr_handles.items) |handle| {
        if (handle.mapping != mapping or !handle.initialized or handle.closed) continue;
        handle.sendState(configuration);
        handle.resource.sendDone();
    }
}

fn identifierFor(allocator: std.mem.Allocator, generation: u64) ![:0]u8 {
    return std.fmt.allocPrintSentinel(allocator, "keywork-{x}", .{generation}, 0);
}

test "foreign toplevel identifiers are printable and bounded" {
    const identifier = try identifierFor(std.testing.allocator, std.math.maxInt(u64));
    defer std.testing.allocator.free(identifier);
    try std.testing.expect(identifier.len > 0 and identifier.len <= 32);
    for (identifier) |byte| try std.testing.expect(byte >= 0x20 and byte <= 0x7e);
}
