//! Sans-I/O stable tablet-v2 policy for one native seat.

const TabletGlobal = @This();

const std = @import("std");
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const CompositorGlobal = @import("CompositorGlobal.zig");
const SeatGlobal = @import("SeatGlobal.zig");
const NativeInput = @import("../backend/native_input.zig");
const render = @import("../render/types.zig");

const advertised_version: u32 = 2;

allocator: std.mem.Allocator,
server: *Server,
seat: *SeatGlobal,
listener: Listener,
global_name: u32,
bindings: std.ArrayList(*Binding) = .empty,
tablets: std.ArrayList(*Tablet) = .empty,
pads: std.ArrayList(*Pad) = .empty,
tools: std.ArrayList(*Tool) = .empty,
tablet_resources: std.ArrayList(*TabletResource) = .empty,
tool_resources: std.ArrayList(*ToolResource) = .empty,
cursor_roles: std.ArrayList(*CursorRole) = .empty,
pad_resources: std.ArrayList(*PadResource) = .empty,
pad_group_resources: std.ArrayList(*PadGroupResource) = .empty,
pad_ring_resources: std.ArrayList(*PadRingResource) = .empty,
pad_strip_resources: std.ArrayList(*PadStripResource) = .empty,
pad_dial_resources: std.ArrayList(*PadDialResource) = .empty,
next_focus_generation: u64 = 1,
next_tool_owner_id: u64 = 1,

pub const Listener = struct {
    context: *anyopaque,
    surface_coordinates: *const fn (*anyopaque, *CompositorGlobal.Surface, f64, f64) ?Point,
    repaint: *const fn (*anyopaque) void,
};

pub const Point = struct { x: f64, y: f64 };

pub const Focus = struct {
    surface: *CompositorGlobal.Surface,
    x: f64,
    y: f64,
};

pub const Cursor = union(enum) {
    surface: struct {
        surface: *CompositorGlobal.Surface,
        root: *CompositorGlobal.Surface,
        x: i32,
        y: i32,
    },
    shape: struct {
        buffer: render.PixelBuffer,
        x: i32,
        y: i32,
    },
};

pub const CursorIterator = struct {
    owner: *TabletGlobal,
    index: usize = 0,

    pub fn next(self: *CursorIterator) ?Cursor {
        while (self.index < self.owner.tools.items.len) {
            const tool = self.owner.tools.items[self.index];
            self.index += 1;
            const cursor = tool.cursor orelse continue;
            const focus = tool.focus orelse continue;
            const position = tool.position orelse continue;
            if (!tool.in_proximity or !focus.surface.resource_alive) continue;
            return switch (cursor) {
                .surface => |surface| if (surface.surface.resource_alive) .{ .surface = .{
                    .surface = surface.surface,
                    .root = surface.surface,
                    .x = cursorCoordinate(position.x, surface.hotspot_x),
                    .y = cursorCoordinate(position.y, surface.hotspot_y),
                } } else continue,
                .shape => |shape| .{ .shape = .{
                    .buffer = shape.buffer,
                    .x = cursorCoordinate(position.x, shape.hotspot_x),
                    .y = cursorCoordinate(position.y, shape.hotspot_y),
                } },
            };
        }
        return null;
    }
};

const Binding = struct {
    owner: *TabletGlobal,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    active: bool,
    references: usize = 1,
};

const TabletResource = struct {
    binding: *Binding,
    resource: wayring.ObjectHandle,
    tablet: ?*Tablet,
};

const ToolResource = struct {
    binding: *Binding,
    resource: wayring.ObjectHandle,
    tool: ?*Tool,
    active: bool = false,
    proximity_serial: ?u32 = null,
};

const PadResource = struct { binding: *Binding, resource: wayring.ObjectHandle, pad: ?*Pad, active: bool = false };
const PadGroupResource = struct { binding: *Binding, resource: wayring.ObjectHandle, pad: ?*Pad, group_index: u32 };
const PadRingResource = struct { binding: *Binding, resource: wayring.ObjectHandle, pad: ?*Pad, index: u32 };
const PadStripResource = struct { binding: *Binding, resource: wayring.ObjectHandle, pad: ?*Pad, index: u32 };
const PadDialResource = struct { binding: *Binding, resource: wayring.ObjectHandle, pad: ?*Pad, index: u32 };

const Tablet = struct {
    owner: *TabletGlobal,
    id: NativeInput.DeviceId,
    physical_id: NativeInput.PhysicalDeviceId,
    name: [:0]u8,
    path: ?[:0]u8,
    vendor: u32,
    product: u32,
    bustype: u32,
};

const Group = struct {
    buttons: []u32,
    rings: []u32,
    strips: []u32,
    dials: []u32,
    mode_count: u32,
    mode: u32,
};

const Pad = struct {
    owner: *TabletGlobal,
    id: NativeInput.DeviceId,
    physical_id: NativeInput.PhysicalDeviceId,
    path: ?[:0]u8,
    button_count: u32,
    groups: []Group,
    focus: ?PadFocus = null,
};

const PadFocus = struct {
    surface: *CompositorGlobal.Surface,
    tablet_id: NativeInput.DeviceId,
};

const CursorRole = struct {
    owner: *TabletGlobal,
    tool_owner_id: u64,
    surface: *CompositorGlobal.Surface,
    hotspot_x: i32 = 0,
    hotspot_y: i32 = 0,
};

const SelectedCursor = union(enum) {
    surface: struct {
        surface: *CompositorGlobal.Surface,
        hotspot_x: i32,
        hotspot_y: i32,
    },
    shape: struct {
        buffer: render.PixelBuffer,
        hotspot_x: i32,
        hotspot_y: i32,
    },
};

const Tool = struct {
    owner: *TabletGlobal,
    owner_id: u64,
    device_id: NativeInput.DeviceId,
    info: NativeInput.TabletToolInfo,
    focus: ?Focus = null,
    position: ?Point = null,
    proximity_serial: u32 = 0,
    tip_down: bool = false,
    buttons: std.ArrayList(u32) = .empty,
    cursor: ?SelectedCursor = null,
    in_proximity: bool = false,
    focus_generation: u64 = 0,
};

pub fn init(self: *TabletGlobal, allocator: std.mem.Allocator, server: *Server, seat: *SeatGlobal, listener: Listener) !void {
    self.* = .{ .allocator = allocator, .server = server, .seat = seat, .listener = listener, .global_name = undefined };
    self.global_name = try server.createGlobal(&generated.zwp_tablet_manager_v2, advertised_version, .{ .context = self, .bind = bind });
}

pub fn deinit(self: *TabletGlobal) void {
    std.debug.assert(self.bindings.items.len == 0);
    std.debug.assert(self.tablet_resources.items.len == 0);
    std.debug.assert(self.tool_resources.items.len == 0);
    std.debug.assert(self.pad_resources.items.len == 0);
    std.debug.assert(self.pad_group_resources.items.len == 0);
    std.debug.assert(self.pad_ring_resources.items.len == 0);
    std.debug.assert(self.pad_strip_resources.items.len == 0);
    std.debug.assert(self.pad_dial_resources.items.len == 0);
    // Surface resources own cursor role contexts and must have drained first.
    std.debug.assert(self.cursor_roles.items.len == 0);
    for (self.tools.items) |tool| {
        std.debug.assert(tool.cursor == null);
        clearToolFocus(tool);
        tool.buttons.deinit(self.allocator);
        self.allocator.destroy(tool);
    }
    for (self.pads.items) |pad| {
        leavePadFocus(pad) catch {};
        destroyPad(self, pad);
    }
    for (self.tablets.items) |tablet| destroyTablet(self, tablet);
    self.tools.deinit(self.allocator);
    self.pads.deinit(self.allocator);
    self.tablets.deinit(self.allocator);
    self.bindings.deinit(self.allocator);
    self.tablet_resources.deinit(self.allocator);
    self.tool_resources.deinit(self.allocator);
    self.cursor_roles.deinit(self.allocator);
    self.pad_resources.deinit(self.allocator);
    self.pad_group_resources.deinit(self.allocator);
    self.pad_ring_resources.deinit(self.allocator);
    self.pad_strip_resources.deinit(self.allocator);
    self.pad_dial_resources.deinit(self.allocator);
    self.server.removeGlobal(self.global_name) catch unreachable;
    self.* = undefined;
}

pub fn addTablet(self: *TabletGlobal, device: NativeInput.DeviceInfo, info: NativeInput.TabletInfo) !void {
    if (self.findTablet(device.id) != null) return error.AlreadyExists;
    const tablet = try self.allocator.create(Tablet);
    var registered = false;
    errdefer if (!registered) self.allocator.destroy(tablet);
    const name = try self.allocator.dupeZ(u8, device.name);
    errdefer if (!registered) self.allocator.free(name);
    const path = if (info.path) |value| try self.allocator.dupeZ(u8, value) else null;
    errdefer if (!registered) if (path) |value| self.allocator.free(value);
    tablet.* = .{ .owner = self, .id = device.id, .physical_id = device.physical_id, .name = name, .path = path, .vendor = info.vendor, .product = info.product, .bustype = info.bustype };
    try self.tablets.append(self.allocator, tablet);
    registered = true;
    // Existing bindings are deliberately retained even if advertising fails;
    // the transport error is returned to the input owner.
    for (self.bindings.items) |binding| if (binding.active) try advertiseTablet(binding, tablet);
    try self.refreshPads(0, null);
}

pub fn removeTablet(self: *TabletGlobal, id: NativeInput.DeviceId) !void {
    const tablet = self.findTablet(id) orelse return;
    for (self.tools.items) |tool| if (tool.device_id == id) try leaveTool(tool, 0);
    var tool_index = self.tools.items.len;
    while (tool_index > 0) {
        tool_index -= 1;
        const tool = self.tools.items[tool_index];
        if (tool.device_id != id) continue;
        for (self.tool_resources.items) |adapter| if (adapter.tool == tool) {
            try generated.zwp_tablet_tool_v2_types.events.removed(&adapter.binding.client.connection, adapter.resource);
            adapter.tool = null;
            adapter.active = false;
            adapter.proximity_serial = null;
        };
        _ = self.tools.orderedRemove(tool_index);
        clearToolCursor(tool);
        tool.buttons.deinit(self.allocator);
        self.allocator.destroy(tool);
    }
    for (self.tablet_resources.items) |adapter| if (adapter.tablet == tablet) {
        try generated.zwp_tablet_v2_types.events.removed(&adapter.binding.client.connection, adapter.resource);
        adapter.tablet = null;
    };
    for (self.tablets.items, 0..) |candidate, index| if (candidate == tablet) {
        _ = self.tablets.orderedRemove(index);
        destroyTablet(self, tablet);
        try self.refreshPads(0, null);
        return;
    };
}

pub fn addPad(self: *TabletGlobal, device: NativeInput.DeviceInfo, info: NativeInput.TabletPadInfo) !void {
    if (self.findPad(device.id) != null) return error.AlreadyExists;
    const pad = try self.allocator.create(Pad);
    var registered = false;
    errdefer if (!registered) self.allocator.destroy(pad);
    const path = if (info.path) |value| try self.allocator.dupeZ(u8, value) else null;
    errdefer if (!registered) if (path) |value| self.allocator.free(value);
    const groups = try self.allocator.alloc(Group, info.groups.len);
    var initialized: usize = 0;
    errdefer if (!registered) {
        for (groups[0..initialized]) |group| freeGroup(self, group);
        self.allocator.free(groups);
    };
    while (initialized < groups.len) : (initialized += 1) {
        const source = info.groups[initialized];
        groups[initialized] = try copyGroup(self, source);
    }
    pad.* = .{ .owner = self, .id = device.id, .physical_id = device.physical_id, .path = path, .button_count = info.button_count, .groups = groups };
    try self.pads.append(self.allocator, pad);
    registered = true;
    // Topology resources are created by advertisePad and inherit the binding version.
    for (self.bindings.items) |binding| if (binding.active) try advertisePad(binding, pad);
    try refreshPadFocus(pad, 0, null);
}

pub fn removePad(self: *TabletGlobal, id: NativeInput.DeviceId) !void {
    const pad = self.findPad(id) orelse return;
    try leavePadFocus(pad);
    for (self.pad_resources.items) |adapter| if (adapter.pad == pad) {
        try generated.zwp_tablet_pad_v2_types.events.removed(&adapter.binding.client.connection, adapter.resource);
        adapter.pad = null;
        adapter.active = false;
    };
    for (self.pad_group_resources.items) |adapter| {
        if (adapter.pad == pad) adapter.pad = null;
    }
    for (self.pad_ring_resources.items) |adapter| {
        if (adapter.pad == pad) adapter.pad = null;
    }
    for (self.pad_strip_resources.items) |adapter| {
        if (adapter.pad == pad) adapter.pad = null;
    }
    for (self.pad_dial_resources.items) |adapter| {
        if (adapter.pad == pad) adapter.pad = null;
    }
    for (self.pads.items, 0..) |candidate, index| if (candidate == pad) {
        _ = self.pads.orderedRemove(index);
        destroyPad(self, pad);
        return;
    };
}

pub fn proximity(self: *TabletGlobal, device_id: NativeInput.DeviceId, info: NativeInput.TabletToolInfo, time: u32, focus: ?Focus, in_proximity: bool, axes: NativeInput.TabletToolAxes) !void {
    const tool = try self.ensureTool(device_id, info);
    if (!in_proximity) {
        tool.in_proximity = false;
        return leaveTool(tool, time);
    }
    tool.in_proximity = true;
    if (focus) |target| if (!target.surface.resource_alive) return;
    if (!tool.tip_down and tool.buttons.items.len == 0) try setToolFocus(tool, focus, time);
    const motion = applyAxes(tool, axes);
    if (tool.focus != null and tool.proximity_serial == 0) tool.proximity_serial = self.server.nextSerial();
    try sendFrame(tool, time, axes, motion, null, null);
}

pub fn axis(self: *TabletGlobal, device_id: NativeInput.DeviceId, tool_id: NativeInput.TabletToolId, time: u32, focus: ?Focus, axes: NativeInput.TabletToolAxes) !void {
    const tool = self.findTool(device_id, tool_id) orelse return;
    if (!tool.in_proximity) return;
    if (axes.position != null and !tool.tip_down and tool.buttons.items.len == 0)
        try setToolFocus(tool, focus, time);
    const motion = applyAxes(tool, axes);
    try sendFrame(tool, time, axes, motion, null, null);
}

pub fn tip(self: *TabletGlobal, device_id: NativeInput.DeviceId, tool_id: NativeInput.TabletToolId, time: u32, focus: ?Focus, axes: NativeInput.TabletToolAxes, down: bool) !void {
    const tool = self.findTool(device_id, tool_id) orelse return;
    if (!tool.in_proximity) return;
    if (axes.position != null and !tool.tip_down and tool.buttons.items.len == 0)
        try setToolFocus(tool, focus, time);
    const motion = applyAxes(tool, axes);
    const changed = tool.tip_down != down;
    tool.tip_down = down;
    try sendFrame(tool, time, axes, motion, if (changed) down else null, null);
}

pub fn button(self: *TabletGlobal, device_id: NativeInput.DeviceId, tool_id: NativeInput.TabletToolId, time: u32, focus: ?Focus, axes: NativeInput.TabletToolAxes, code: u32, pressed: bool) !void {
    const tool = self.findTool(device_id, tool_id) orelse return;
    if (!tool.in_proximity) return;
    if (axes.position != null and !tool.tip_down and tool.buttons.items.len == 0)
        try setToolFocus(tool, focus, time);
    const motion = applyAxes(tool, axes);
    var changed = false;
    if (pressed) {
        if (std.mem.indexOfScalar(u32, tool.buttons.items, code) == null) {
            try tool.buttons.append(self.allocator, code);
            changed = true;
        }
    } else if (std.mem.indexOfScalar(u32, tool.buttons.items, code)) |index| {
        _ = tool.buttons.orderedRemove(index);
        changed = true;
    }
    try sendFrame(tool, time, axes, motion, null, if (changed) .{ code, @intFromBool(pressed) } else null);
}

pub fn padButton(self: *TabletGlobal, id: NativeInput.DeviceId, time: u32, index: u32, pressed: bool, group: u32, mode: u32) !void {
    const pad = self.findPad(id) orelse return;
    try updatePadMode(pad, time, group, mode);
    if (index >= pad.button_count) return;
    for (self.pad_resources.items) |adapter| if (adapter.pad == pad and adapter.active)
        try generated.zwp_tablet_pad_v2_types.events.button(&adapter.binding.client.connection, adapter.resource, time, index, @intFromBool(pressed));
}
pub fn padRing(self: *TabletGlobal, id: NativeInput.DeviceId, time: u32, index: u32, position: f64, finger: bool, group: u32, mode: u32) !void {
    const pad = self.findPad(id) orelse return;
    try updatePadMode(pad, time, group, mode);
    for (self.pad_ring_resources.items) |adapter| {
        if (adapter.pad != pad or adapter.index != index or !self.padBindingActive(adapter.binding, pad)) continue;
        if (finger) try generated.zwp_tablet_pad_ring_v2_types.events.source(&adapter.binding.client.connection, adapter.resource, @intFromEnum(generated.zwp_tablet_pad_ring_v2_types.source.finger));
        if (position < 0) try generated.zwp_tablet_pad_ring_v2_types.events.stop(&adapter.binding.client.connection, adapter.resource) else try generated.zwp_tablet_pad_ring_v2_types.events.angle(&adapter.binding.client.connection, adapter.resource, fixed(position));
        try generated.zwp_tablet_pad_ring_v2_types.events.frame(&adapter.binding.client.connection, adapter.resource, time);
    }
}
pub fn padStrip(self: *TabletGlobal, id: NativeInput.DeviceId, time: u32, index: u32, position: f64, finger: bool, group: u32, mode: u32) !void {
    const pad = self.findPad(id) orelse return;
    try updatePadMode(pad, time, group, mode);
    for (self.pad_strip_resources.items) |adapter| {
        if (adapter.pad != pad or adapter.index != index or !self.padBindingActive(adapter.binding, pad)) continue;
        if (finger) try generated.zwp_tablet_pad_strip_v2_types.events.source(&adapter.binding.client.connection, adapter.resource, @intFromEnum(generated.zwp_tablet_pad_strip_v2_types.source.finger));
        if (position < 0) try generated.zwp_tablet_pad_strip_v2_types.events.stop(&adapter.binding.client.connection, adapter.resource) else try generated.zwp_tablet_pad_strip_v2_types.events.position(&adapter.binding.client.connection, adapter.resource, normalized(position));
        try generated.zwp_tablet_pad_strip_v2_types.events.frame(&adapter.binding.client.connection, adapter.resource, time);
    }
}
pub fn padDial(self: *TabletGlobal, id: NativeInput.DeviceId, time: u32, index: u32, value120: i32, group: u32, mode: u32) !void {
    std.debug.assert(value120 != 0);
    const pad = self.findPad(id) orelse return;
    try updatePadMode(pad, time, group, mode);
    for (self.pad_dial_resources.items) |adapter| {
        if (adapter.pad != pad or adapter.index != index or !self.padBindingActive(adapter.binding, pad)) continue;
        try generated.zwp_tablet_pad_dial_v2_types.events.delta(&adapter.binding.client.connection, adapter.resource, value120);
        try generated.zwp_tablet_pad_dial_v2_types.events.frame(&adapter.binding.client.connection, adapter.resource, time);
    }
}

pub fn pruneDeadFocus(self: *TabletGlobal) !void {
    var dead: ?*CompositorGlobal.Surface = null;
    for (self.tools.items) |tool| if (tool.focus) |focus| if (!focus.surface.resource_alive) {
        dead = focus.surface;
        try leaveTool(tool, 0);
    };
    try self.refreshPads(0, dead);
}

pub fn isCursorSurface(self: *const TabletGlobal, surface: *const CompositorGlobal.Surface) bool {
    for (self.cursor_roles.items) |role| if (role.surface == surface) return true;
    return false;
}

pub fn cursorIterator(self: *TabletGlobal) CursorIterator {
    return .{ .owner = self };
}

/// Captures one native tablet-tool resource without retaining its adapter.
pub fn toolHandle(
    self: *const TabletGlobal,
    client: *const Server.Client,
    resource_id: u32,
) ?wayring.ObjectHandle {
    for (self.tool_resources.items) |adapter| {
        if (adapter.binding.client == client and adapter.resource.id == resource_id)
            return adapter.resource;
    }
    return null;
}

pub fn setCursorShape(
    self: *TabletGlobal,
    client: *Server.Client,
    handle: wayring.ObjectHandle,
    serial: u32,
    buffer: render.PixelBuffer,
    hotspot_x: i32,
    hotspot_y: i32,
) void {
    for (self.tool_resources.items) |adapter| {
        if (adapter.resource.id != handle.id or
            adapter.resource.generation != handle.generation) continue;
        const tool = activeToolResource(adapter, client, serial) orelse return;
        tool.cursor = .{ .shape = .{
            .buffer = buffer,
            .hotspot_x = hotspot_x,
            .hotspot_y = hotspot_y,
        } };
        self.listener.repaint(self.listener.context);
        return;
    }
}

pub fn clearCursorShapes(self: *TabletGlobal) void {
    var changed = false;
    for (self.tools.items) |tool| if (tool.cursor) |cursor| switch (cursor) {
        .surface => {},
        .shape => {
            tool.cursor = null;
            changed = true;
        },
    };
    if (changed) self.listener.repaint(self.listener.context);
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *TabletGlobal = @ptrCast(@alignCast(context));
    _ = client.createResource(id, &generated.zwp_tablet_manager_v2, version, .{ .context = self, .dispatch = dispatchManager }) catch return client.postNoMemory();
}

fn dispatchManager(context: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    const self: *TabletGlobal = @ptrCast(@alignCast(context));
    switch (try generated.zwp_tablet_manager_v2_types.decodeRequest(&client.connection, resource, message)) {
        .destroy => {},
        .get_tablet_seat => |request| {
            self.bindings.ensureUnusedCapacity(self.allocator, 1) catch
                return client.postNoMemory();
            const binding = self.allocator.create(Binding) catch return client.postNoMemory();
            var registered = false;
            errdefer if (!registered) self.allocator.destroy(binding);
            const version = try client.resourceVersion(resource, &generated.zwp_tablet_manager_v2);
            const handle = client.createResource(request.tablet_seat, &generated.zwp_tablet_seat_v2, version, .{ .context = binding, .dispatch = dispatchSeat, .destroy = destroyBinding }) catch return client.postNoMemory();
            binding.* = .{ .owner = self, .client = client, .resource = handle, .active = self.seat.ownsResource(client, request.seat) };
            self.bindings.appendAssumeCapacity(binding);
            registered = true;
            if (binding.active) {
                for (self.tablets.items) |tablet| try advertiseTablet(binding, tablet);
                for (self.tools.items) |tool| try advertiseTool(binding, tool);
                for (self.pads.items) |pad| try advertisePad(binding, pad);
            }
        },
    }
}

fn dispatchSeat(context: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    _ = context;
    _ = try generated.zwp_tablet_seat_v2_types.decodeRequest(&client.connection, resource, message);
}

fn destroyBinding(context: *anyopaque, _: *Server.Client, _: wayring.ObjectHandle) void {
    const binding: *Binding = @ptrCast(@alignCast(context));
    binding.active = false;
    releaseBinding(binding);
}

fn advertiseTablet(binding: *Binding, tablet: *Tablet) !void {
    const owner = binding.owner;
    try owner.tablet_resources.ensureUnusedCapacity(owner.allocator, 1);
    const adapter = try owner.allocator.create(TabletResource);
    var registered = false;
    errdefer if (!registered) owner.allocator.destroy(adapter);
    const version = @min(
        try binding.client.resourceVersion(binding.resource, &generated.zwp_tablet_seat_v2),
        generated.zwp_tablet_v2.version,
    );
    const resource = try binding.client.createServerResource(&generated.zwp_tablet_v2, version, .{
        .context = adapter,
        .dispatch = dispatchTablet,
        .destroy = destroyTabletResource,
    });
    errdefer if (!registered) binding.client.destroyResource(resource) catch {};
    adapter.* = .{ .binding = binding, .resource = resource, .tablet = tablet };
    owner.tablet_resources.appendAssumeCapacity(adapter);
    retainBinding(binding);
    registered = true;
    try generated.zwp_tablet_seat_v2_types.events.tablet_added(&binding.client.connection, binding.resource, resource);
    try generated.zwp_tablet_v2_types.events.name(&binding.client.connection, resource, tablet.name);
    if (tablet.vendor != 0 or tablet.product != 0)
        try generated.zwp_tablet_v2_types.events.id(&binding.client.connection, resource, tablet.vendor, tablet.product);
    if (tablet.path) |path| try generated.zwp_tablet_v2_types.events.path(&binding.client.connection, resource, path);
    if (protocolBustype(tablet.bustype)) |value|
        try generated.zwp_tablet_v2_types.events.bustype(&binding.client.connection, resource, @intFromEnum(value));
    try generated.zwp_tablet_v2_types.events.done(&binding.client.connection, resource);
}

fn advertiseTool(binding: *Binding, tool: *Tool) !void {
    const owner = binding.owner;
    try owner.tool_resources.ensureUnusedCapacity(owner.allocator, 1);
    const adapter = try owner.allocator.create(ToolResource);
    var registered = false;
    errdefer if (!registered) owner.allocator.destroy(adapter);
    const version = @min(
        try binding.client.resourceVersion(binding.resource, &generated.zwp_tablet_seat_v2),
        generated.zwp_tablet_tool_v2.version,
    );
    const resource = try binding.client.createServerResource(&generated.zwp_tablet_tool_v2, version, .{
        .context = adapter,
        .dispatch = dispatchTool,
        .destroy = destroyToolResource,
    });
    errdefer if (!registered) binding.client.destroyResource(resource) catch {};
    adapter.* = .{ .binding = binding, .resource = resource, .tool = tool };
    owner.tool_resources.appendAssumeCapacity(adapter);
    retainBinding(binding);
    registered = true;
    try generated.zwp_tablet_seat_v2_types.events.tool_added(&binding.client.connection, binding.resource, resource);
    const tool_type: generated.zwp_tablet_tool_v2_types.type = switch (tool.info.tool_type) {
        .pen => .pen,
        .eraser => .eraser,
        .brush => .brush,
        .pencil => .pencil,
        .airbrush => .airbrush,
        .mouse => .mouse,
        .lens => .lens,
    };
    try generated.zwp_tablet_tool_v2_types.events.type(&binding.client.connection, resource, @intFromEnum(tool_type));
    if (tool.info.serial) |value| try generated.zwp_tablet_tool_v2_types.events.hardware_serial(&binding.client.connection, resource, high(value), low(value));
    if (tool.info.hardware_id) |value| try generated.zwp_tablet_tool_v2_types.events.hardware_id_wacom(&binding.client.connection, resource, high(value), low(value));
    const capabilities = tool.info.capabilities;
    if (capabilities.tilt) try sendToolCapability(binding, resource, .tilt);
    if (capabilities.pressure) try sendToolCapability(binding, resource, .pressure);
    if (capabilities.distance) try sendToolCapability(binding, resource, .distance);
    if (capabilities.rotation) try sendToolCapability(binding, resource, .rotation);
    if (capabilities.slider) try sendToolCapability(binding, resource, .slider);
    if (capabilities.wheel) try sendToolCapability(binding, resource, .wheel);
    try generated.zwp_tablet_tool_v2_types.events.done(&binding.client.connection, resource);
    if (tool.in_proximity) if (tool.focus) |focus| {
        if (focus.surface.resource_alive and binding.client == focus.surface.client) {
            const serial = owner.server.nextSerial();
            try enterToolResource(adapter, tool, focus, serial, 0);
        }
    };
}

fn sendToolCapability(
    binding: *Binding,
    resource: wayring.ObjectHandle,
    capability: generated.zwp_tablet_tool_v2_types.capability,
) !void {
    try generated.zwp_tablet_tool_v2_types.events.capability(
        &binding.client.connection,
        resource,
        @intFromEnum(capability),
    );
}

fn advertisePad(binding: *Binding, pad: *Pad) !void {
    const owner = binding.owner;
    const version = @min(try binding.client.resourceVersion(binding.resource, &generated.zwp_tablet_seat_v2), generated.zwp_tablet_pad_v2.version);
    const adapter = try createPadAdapter(PadResource, owner, binding, &generated.zwp_tablet_pad_v2, version, dispatchPad, destroyPadResource);
    adapter.* = .{ .binding = binding, .resource = adapter.resource, .pad = pad };
    try generated.zwp_tablet_seat_v2_types.events.pad_added(&binding.client.connection, binding.resource, adapter.resource);
    if (pad.path) |path| try generated.zwp_tablet_pad_v2_types.events.path(&binding.client.connection, adapter.resource, path);
    if (pad.button_count != 0) try generated.zwp_tablet_pad_v2_types.events.buttons(&binding.client.connection, adapter.resource, pad.button_count);
    for (pad.groups, 0..) |group, group_index| try advertisePadGroup(adapter, @intCast(group_index), group, version);
    try generated.zwp_tablet_pad_v2_types.events.done(&binding.client.connection, adapter.resource);
    if (pad.focus) |focus| try enterPadResource(adapter, pad, focus, 0);
}

fn advertisePadGroup(pad_adapter: *PadResource, group_index: u32, group: Group, version: u32) !void {
    const owner = pad_adapter.binding.owner;
    const binding = pad_adapter.binding;
    const child_version = @min(version, generated.zwp_tablet_pad_group_v2.version);
    const adapter = try createPadAdapter(PadGroupResource, owner, binding, &generated.zwp_tablet_pad_group_v2, child_version, dispatchPadGroup, destroyPadGroupResource);
    adapter.* = .{ .binding = binding, .resource = adapter.resource, .pad = pad_adapter.pad, .group_index = group_index };
    const connection = &binding.client.connection;
    try generated.zwp_tablet_pad_v2_types.events.group(connection, pad_adapter.resource, adapter.resource);
    try generated.zwp_tablet_pad_group_v2_types.events.buttons(connection, adapter.resource, std.mem.sliceAsBytes(group.buttons));
    for (group.rings) |index| {
        const child = try createIndexedPadAdapter(PadRingResource, owner, binding, pad_adapter.pad.?, index, &generated.zwp_tablet_pad_ring_v2, @min(version, generated.zwp_tablet_pad_ring_v2.version), dispatchPadRing, destroyPadRingResource);
        try generated.zwp_tablet_pad_group_v2_types.events.ring(connection, adapter.resource, child.resource);
    }
    for (group.strips) |index| {
        const child = try createIndexedPadAdapter(PadStripResource, owner, binding, pad_adapter.pad.?, index, &generated.zwp_tablet_pad_strip_v2, @min(version, generated.zwp_tablet_pad_strip_v2.version), dispatchPadStrip, destroyPadStripResource);
        try generated.zwp_tablet_pad_group_v2_types.events.strip(connection, adapter.resource, child.resource);
    }
    if (child_version >= 2) for (group.dials) |index| {
        const child = try createIndexedPadAdapter(PadDialResource, owner, binding, pad_adapter.pad.?, index, &generated.zwp_tablet_pad_dial_v2, @min(version, generated.zwp_tablet_pad_dial_v2.version), dispatchPadDial, destroyPadDialResource);
        try generated.zwp_tablet_pad_group_v2_types.events.dial(connection, adapter.resource, child.resource);
    };
    if (group.mode_count > 1) try generated.zwp_tablet_pad_group_v2_types.events.modes(connection, adapter.resource, group.mode_count);
    try generated.zwp_tablet_pad_group_v2_types.events.done(connection, adapter.resource);
}

fn createPadAdapter(comptime T: type, owner: *TabletGlobal, binding: *Binding, interface: *const wayring.Interface, version: u32, dispatch: Server.RequestDispatch, destroy: Server.ResourceDestroy) !*T {
    const list = padAdapterList(T, owner);
    try list.ensureUnusedCapacity(owner.allocator, 1);
    const adapter = try owner.allocator.create(T);
    errdefer owner.allocator.destroy(adapter);
    const resource = try binding.client.createServerResource(interface, version, .{ .context = adapter, .dispatch = dispatch, .destroy = destroy });
    errdefer binding.client.destroyResource(resource) catch {};
    adapter.resource = resource;
    list.appendAssumeCapacity(adapter);
    retainBinding(binding);
    return adapter;
}

fn createIndexedPadAdapter(comptime T: type, owner: *TabletGlobal, binding: *Binding, pad: *Pad, index: u32, interface: *const wayring.Interface, version: u32, dispatch: Server.RequestDispatch, destroy: Server.ResourceDestroy) !*T {
    const adapter = try createPadAdapter(T, owner, binding, interface, version, dispatch, destroy);
    adapter.* = .{ .binding = binding, .resource = adapter.resource, .pad = pad, .index = index };
    return adapter;
}

fn padAdapterList(comptime T: type, owner: *TabletGlobal) *std.ArrayList(*T) {
    if (T == PadResource) return &owner.pad_resources;
    if (T == PadGroupResource) return &owner.pad_group_resources;
    if (T == PadRingResource) return &owner.pad_ring_resources;
    if (T == PadStripResource) return &owner.pad_strip_resources;
    if (T == PadDialResource) return &owner.pad_dial_resources;
    @compileError("unsupported pad adapter");
}
fn sendFrame(
    tool: *Tool,
    time: u32,
    axes: NativeInput.TabletToolAxes,
    motion: ?Point,
    tip_state: ?bool,
    button_state: ?struct { u32, u32 },
) !void {
    const down_serial = if (tip_state == true) tool.owner.server.nextSerial() else 0;
    const button_serial = if (button_state != null) tool.owner.server.nextSerial() else 0;
    for (tool.owner.tool_resources.items) |adapter| {
        if (adapter.tool != tool or !adapter.active) continue;
        const connection = &adapter.binding.client.connection;
        if (motion) |position| try generated.zwp_tablet_tool_v2_types.events.motion(
            connection,
            adapter.resource,
            fixed(position.x),
            fixed(position.y),
        );
        if (axes.pressure) |value| try generated.zwp_tablet_tool_v2_types.events.pressure(connection, adapter.resource, normalized(value));
        if (axes.distance) |value| try generated.zwp_tablet_tool_v2_types.events.distance(connection, adapter.resource, normalized(value));
        if (axes.tilt) |value| try generated.zwp_tablet_tool_v2_types.events.tilt(connection, adapter.resource, fixed(value.x), fixed(value.y));
        if (axes.rotation) |value| try generated.zwp_tablet_tool_v2_types.events.rotation(connection, adapter.resource, fixed(value));
        if (axes.slider) |value| try generated.zwp_tablet_tool_v2_types.events.slider(connection, adapter.resource, slider(value));
        if (axes.wheel) |value| try generated.zwp_tablet_tool_v2_types.events.wheel(connection, adapter.resource, fixed(value.degrees), value.clicks);
        if (tip_state) |down| if (down)
            try generated.zwp_tablet_tool_v2_types.events.down(connection, adapter.resource, down_serial)
        else
            try generated.zwp_tablet_tool_v2_types.events.up(connection, adapter.resource);
        if (button_state) |button_event| try generated.zwp_tablet_tool_v2_types.events.button(connection, adapter.resource, button_serial, button_event[0], button_event[1]);
        try generated.zwp_tablet_tool_v2_types.events.frame(connection, adapter.resource, time);
    }
}

fn dispatchTablet(_: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    _ = try generated.zwp_tablet_v2_types.decodeRequest(&client.connection, resource, message);
}

fn dispatchTool(context: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    const adapter: *ToolResource = @ptrCast(@alignCast(context));
    switch (try generated.zwp_tablet_tool_v2_types.decodeRequest(&client.connection, resource, message)) {
        .destroy => {},
        .set_cursor => |request| {
            const tool = activeToolResource(adapter, client, request.serial) orelse return;
            const surface = if (request.surface) |id| blk: {
                // The decoder established the interface; re-resolve the live generation.
                const object = client.connection.object(id) orelse return;
                break :blk CompositorGlobal.surfaceFor(client, .{ .id = id, .generation = object.generation }) catch return;
            } else null;

            if (surface) |cursor_surface| {
                const role = if (findCursorRole(adapter.binding.owner, cursor_surface)) |existing| blk: {
                    if (existing.tool_owner_id != tool.owner_id) return client.postError(
                        resource,
                        @intFromEnum(generated.zwp_tablet_tool_v2_types.@"error".role),
                        "wl_surface is unavailable for this tablet tool cursor",
                    );
                    break :blk existing;
                } else blk: {
                    assignCursorRole(adapter, tool, cursor_surface) catch |err| switch (err) {
                        error.RequestHandled => return,
                        else => return err,
                    };
                    break :blk findCursorRole(adapter.binding.owner, cursor_surface).?;
                };
                role.hotspot_x = request.hotspot_x;
                role.hotspot_y = request.hotspot_y;
                tool.cursor = .{ .surface = .{
                    .surface = cursor_surface,
                    .hotspot_x = request.hotspot_x,
                    .hotspot_y = request.hotspot_y,
                } };
            } else tool.cursor = null;
            tool.owner.listener.repaint(tool.owner.listener.context);
        },
    }
}

fn dispatchPad(_: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    _ = try generated.zwp_tablet_pad_v2_types.decodeRequest(&client.connection, resource, message);
}
fn dispatchPadGroup(_: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    _ = try generated.zwp_tablet_pad_group_v2_types.decodeRequest(&client.connection, resource, message);
}
fn dispatchPadRing(_: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    _ = try generated.zwp_tablet_pad_ring_v2_types.decodeRequest(&client.connection, resource, message);
}
fn dispatchPadStrip(_: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    _ = try generated.zwp_tablet_pad_strip_v2_types.decodeRequest(&client.connection, resource, message);
}
fn dispatchPadDial(_: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    _ = try generated.zwp_tablet_pad_dial_v2_types.decodeRequest(&client.connection, resource, message);
}

fn destroyTabletResource(context: *anyopaque, _: *Server.Client, _: wayring.ObjectHandle) void {
    const adapter: *TabletResource = @ptrCast(@alignCast(context));
    const owner = adapter.binding.owner;
    const binding = adapter.binding;
    removeAdapter(TabletResource, owner.allocator, &owner.tablet_resources, adapter);
    releaseBinding(binding);
}

fn destroyToolResource(context: *anyopaque, _: *Server.Client, _: wayring.ObjectHandle) void {
    const adapter: *ToolResource = @ptrCast(@alignCast(context));
    const owner = adapter.binding.owner;
    const binding = adapter.binding;
    const tool = adapter.tool;
    const clear_cursor = if (tool) |active_tool|
        adapter.active and !hasOtherActiveResource(owner, active_tool, binding.client, adapter)
    else
        false;
    removeAdapter(ToolResource, owner.allocator, &owner.tool_resources, adapter);
    if (clear_cursor) clearToolCursor(tool.?);
    releaseBinding(binding);
}

fn destroyPadResource(context: *anyopaque, _: *Server.Client, _: wayring.ObjectHandle) void {
    destroyPadAdapter(PadResource, context);
}
fn destroyPadGroupResource(context: *anyopaque, _: *Server.Client, _: wayring.ObjectHandle) void {
    destroyPadAdapter(PadGroupResource, context);
}
fn destroyPadRingResource(context: *anyopaque, _: *Server.Client, _: wayring.ObjectHandle) void {
    destroyPadAdapter(PadRingResource, context);
}
fn destroyPadStripResource(context: *anyopaque, _: *Server.Client, _: wayring.ObjectHandle) void {
    destroyPadAdapter(PadStripResource, context);
}
fn destroyPadDialResource(context: *anyopaque, _: *Server.Client, _: wayring.ObjectHandle) void {
    destroyPadAdapter(PadDialResource, context);
}

fn destroyPadAdapter(comptime T: type, context: *anyopaque) void {
    const adapter: *T = @ptrCast(@alignCast(context));
    const owner = adapter.binding.owner;
    const binding = adapter.binding;
    removeAdapter(T, owner.allocator, padAdapterList(T, owner), adapter);
    releaseBinding(binding);
}

fn activeToolResource(adapter: *ToolResource, client: *Server.Client, serial: u32) ?*Tool {
    if (!adapter.active or adapter.binding.client != client or adapter.proximity_serial != serial) return null;
    const tool = adapter.tool orelse return null;
    const focus = tool.focus orelse return null;
    if (!tool.in_proximity or !focus.surface.resource_alive or focus.surface.client != client) return null;
    return tool;
}

fn hasOtherActiveResource(owner: *TabletGlobal, tool: *Tool, client: *Server.Client, excluded: *ToolResource) bool {
    for (owner.tool_resources.items) |adapter|
        if (adapter != excluded and adapter.tool == tool and adapter.binding.client == client and adapter.active) return true;
    return false;
}

fn findCursorRole(owner: *const TabletGlobal, surface: *const CompositorGlobal.Surface) ?*CursorRole {
    for (owner.cursor_roles.items) |role| if (role.surface == surface) return role;
    return null;
}

fn assignCursorRole(adapter: *ToolResource, tool: *Tool, surface: *CompositorGlobal.Surface) !void {
    const owner = tool.owner;
    const role = owner.allocator.create(CursorRole) catch {
        try adapter.binding.client.postNoMemory();
        return error.RequestHandled;
    };
    errdefer owner.allocator.destroy(role);
    role.* = .{ .owner = owner, .tool_owner_id = tool.owner_id, .surface = surface };
    owner.cursor_roles.append(owner.allocator, role) catch {
        try adapter.binding.client.postNoMemory();
        return error.RequestHandled;
    };
    errdefer _ = owner.cursor_roles.pop();
    surface.setRole(owner, role, cursorSurfaceDestroyed) catch {
        try adapter.binding.client.postError(
            adapter.resource,
            @intFromEnum(generated.zwp_tablet_tool_v2_types.@"error".role),
            "wl_surface is unavailable for this tablet tool cursor",
        );
        return error.RequestHandled;
    };
}

fn cursorSurfaceDestroyed(context: *anyopaque) void {
    const role: *CursorRole = @ptrCast(@alignCast(context));
    const owner = role.owner;
    for (owner.tools.items) |tool| {
        if (tool.owner_id != role.tool_owner_id) continue;
        if (tool.cursor) |cursor| switch (cursor) {
            .surface => |surface| if (surface.surface == role.surface) {
                clearToolCursor(tool);
                break;
            },
            .shape => {},
        };
        break;
    }
    for (owner.cursor_roles.items, 0..) |candidate, index| if (candidate == role) {
        _ = owner.cursor_roles.orderedRemove(index);
        owner.allocator.destroy(role);
        return;
    };
    unreachable;
}

fn setToolFocus(tool: *Tool, focus: ?Focus, time: u32) !void {
    if (focus) |value| {
        if (!value.surface.resource_alive) return;
        if (tool.focus) |old| if (old.surface == value.surface) {
            tool.focus = value;
            return;
        };
    }
    if (tool.focus != null) try leaveToolFocus(tool, time, false);
    if (focus) |value| try value.surface.reference();
    tool.focus = focus;
    const target = focus orelse {
        try tool.owner.refreshPads(0, null);
        return;
    };
    tool.focus_generation = tool.owner.next_focus_generation;
    tool.owner.next_focus_generation = std.math.add(u64, tool.owner.next_focus_generation, 1) catch unreachable;
    const serial = tool.owner.server.nextSerial();
    tool.proximity_serial = serial;
    for (tool.owner.tool_resources.items) |adapter| {
        if (adapter.tool == tool and adapter.binding.client == target.surface.client)
            try enterToolResource(adapter, tool, target, serial, null);
    }
    try tool.owner.refreshPads(time, null);
}

fn enterToolResource(
    adapter: *ToolResource,
    tool: *Tool,
    focus: Focus,
    serial: u32,
    frame_time: ?u32,
) !void {
    const tablet = tool.owner.findTablet(tool.device_id) orelse return;
    const tablet_adapter = tool.owner.tabletResource(adapter.binding, tablet) orelse return;
    adapter.active = true;
    adapter.proximity_serial = serial;
    const connection = &adapter.binding.client.connection;
    try generated.zwp_tablet_tool_v2_types.events.proximity_in(
        connection,
        adapter.resource,
        serial,
        tablet_adapter.resource,
        focus.surface.resource,
    );
    for (tool.buttons.items) |code| try generated.zwp_tablet_tool_v2_types.events.button(
        connection,
        adapter.resource,
        serial,
        code,
        @intFromEnum(generated.zwp_tablet_tool_v2_types.button_state.pressed),
    );
    if (tool.tip_down)
        try generated.zwp_tablet_tool_v2_types.events.down(connection, adapter.resource, serial);
    if (frame_time) |value|
        try generated.zwp_tablet_tool_v2_types.events.frame(connection, adapter.resource, value);
}

fn clearToolFocus(tool: *Tool) void {
    if (tool.focus) |focus| focus.surface.unreference();
    tool.focus = null;
    tool.position = null;
    tool.proximity_serial = 0;
    tool.focus_generation = 0;
}

fn clearToolCursor(tool: *Tool) void {
    if (tool.cursor == null) return;
    tool.cursor = null;
    tool.owner.listener.repaint(tool.owner.listener.context);
}

fn leaveTool(tool: *Tool, time: u32) !void {
    try leaveToolFocus(tool, time, true);
}

fn leaveToolFocus(tool: *Tool, time: u32, release_state: bool) !void {
    const serial = tool.owner.server.nextSerial();
    for (tool.owner.tool_resources.items) |adapter| {
        if (adapter.tool != tool or !adapter.active) continue;
        if (release_state) {
            for (tool.buttons.items) |code| try generated.zwp_tablet_tool_v2_types.events.button(
                &adapter.binding.client.connection,
                adapter.resource,
                serial,
                code,
                @intFromEnum(generated.zwp_tablet_tool_v2_types.button_state.released),
            );
            if (tool.tip_down) try generated.zwp_tablet_tool_v2_types.events.up(&adapter.binding.client.connection, adapter.resource);
        }
        try generated.zwp_tablet_tool_v2_types.events.proximity_out(&adapter.binding.client.connection, adapter.resource);
        try generated.zwp_tablet_tool_v2_types.events.frame(&adapter.binding.client.connection, adapter.resource, time);
        adapter.active = false;
        adapter.proximity_serial = null;
    }
    if (release_state) {
        tool.tip_down = false;
        tool.buttons.clearRetainingCapacity();
    }
    clearToolCursor(tool);
    clearToolFocus(tool);
    try tool.owner.refreshPads(time, null);
}

fn refreshPads(self: *TabletGlobal, time: u32, excluded: ?*CompositorGlobal.Surface) !void {
    for (self.pads.items) |pad| try refreshPadFocus(pad, time, excluded);
}

fn refreshPadFocus(pad: *Pad, time: u32, excluded: ?*CompositorGlobal.Surface) !void {
    const owner = pad.owner;
    var linked = false;
    for (owner.tablets.items) |tablet| if (tablet.physical_id == pad.physical_id) {
        linked = true;
        break;
    };
    var candidate: ?*Tool = null;
    for (owner.tools.items) |tool| {
        const focus = tool.focus orelse continue;
        if (!tool.in_proximity or !focus.surface.resource_alive or focus.surface == excluded) continue;
        const tablet = owner.findTablet(tool.device_id) orelse continue;
        if (linked and tablet.physical_id != pad.physical_id) continue;
        if (candidate == null or tool.focus_generation > candidate.?.focus_generation) candidate = tool;
    }
    if (candidate) |tool| {
        const focus = tool.focus.?;
        if (pad.focus) |current| if (current.tablet_id == tool.device_id and current.surface == focus.surface) return;
        try leavePadFocus(pad);
        try focus.surface.reference();
        pad.focus = .{ .surface = focus.surface, .tablet_id = tool.device_id };
        for (owner.pad_resources.items) |adapter| try enterPadResource(adapter, pad, pad.focus.?, time);
    } else try leavePadFocus(pad);
}

fn enterPadResource(adapter: *PadResource, pad: *Pad, focus: PadFocus, time: u32) !void {
    if (adapter.pad != pad or adapter.binding.client != focus.surface.client) return;
    const tablet = pad.owner.findTablet(focus.tablet_id) orelse return;
    const tablet_adapter = pad.owner.tabletResource(adapter.binding, tablet) orelse return;
    const serial = pad.owner.server.nextSerial();
    adapter.active = true;
    try generated.zwp_tablet_pad_v2_types.events.enter(&adapter.binding.client.connection, adapter.resource, serial, tablet_adapter.resource, focus.surface.resource);
    for (pad.owner.pad_group_resources.items) |group_adapter| {
        if (group_adapter.pad != pad or group_adapter.binding != adapter.binding or group_adapter.group_index >= pad.groups.len) continue;
        try generated.zwp_tablet_pad_group_v2_types.events.mode_switch(&adapter.binding.client.connection, group_adapter.resource, time, serial, pad.groups[group_adapter.group_index].mode);
    }
}

fn leavePadFocus(pad: *Pad) !void {
    const focus = pad.focus orelse return;
    const serial = pad.owner.server.nextSerial();
    for (pad.owner.pad_resources.items) |adapter| if (adapter.pad == pad and adapter.active) {
        if (focus.surface.resource_alive) try generated.zwp_tablet_pad_v2_types.events.leave(&adapter.binding.client.connection, adapter.resource, serial, focus.surface.resource);
        adapter.active = false;
    };
    focus.surface.unreference();
    pad.focus = null;
}

fn updatePadMode(pad: *Pad, time: u32, group_index: u32, mode: u32) !void {
    if (group_index >= pad.groups.len) return;
    const group = &pad.groups[group_index];
    if (mode >= group.mode_count or mode == group.mode) return;
    group.mode = mode;
    if (pad.focus == null) return;
    const serial = pad.owner.server.nextSerial();
    for (pad.owner.pad_group_resources.items) |adapter| if (adapter.pad == pad and adapter.group_index == group_index and pad.owner.padBindingActive(adapter.binding, pad))
        try generated.zwp_tablet_pad_group_v2_types.events.mode_switch(&adapter.binding.client.connection, adapter.resource, time, serial, mode);
}

fn padBindingActive(self: *TabletGlobal, binding: *Binding, pad: *Pad) bool {
    for (self.pad_resources.items) |adapter| if (adapter.binding == binding and adapter.pad == pad) return adapter.active;
    return false;
}

fn applyAxes(tool: *Tool, axes: NativeInput.TabletToolAxes) ?Point {
    if (axes.position) |position| {
        tool.position = .{ .x = position.x, .y = position.y };
        if (tool.focus) |*focus| if (tool.owner.listener.surface_coordinates(
            tool.owner.listener.context,
            focus.surface,
            position.x,
            position.y,
        )) |local| {
            focus.x = local.x;
            focus.y = local.y;
            if (tool.cursor != null) tool.owner.listener.repaint(tool.owner.listener.context);
            return local;
        };
        if (tool.cursor != null) tool.owner.listener.repaint(tool.owner.listener.context);
    }
    return null;
}

fn ensureTool(self: *TabletGlobal, device_id: NativeInput.DeviceId, info: NativeInput.TabletToolInfo) !*Tool {
    if (self.findTool(device_id, info.id)) |tool| return tool;
    const tool = try self.allocator.create(Tool);
    var registered = false;
    errdefer if (!registered) self.allocator.destroy(tool);
    const owner_id = self.next_tool_owner_id;
    self.next_tool_owner_id = std.math.add(u64, owner_id, 1) catch return error.OutOfMemory;
    tool.* = .{ .owner = self, .owner_id = owner_id, .device_id = device_id, .info = info };
    try self.tools.append(self.allocator, tool);
    registered = true;
    for (self.bindings.items) |binding| if (binding.active) try advertiseTool(binding, tool);
    return tool;
}

fn findTablet(self: *TabletGlobal, id: NativeInput.DeviceId) ?*Tablet {
    for (self.tablets.items) |item| if (item.id == id) return item;
    return null;
}
fn tabletResource(self: *TabletGlobal, binding: *Binding, tablet: *Tablet) ?*TabletResource {
    for (self.tablet_resources.items) |adapter|
        if (adapter.binding == binding and adapter.tablet == tablet) return adapter;
    return null;
}
fn findPad(self: *TabletGlobal, id: NativeInput.DeviceId) ?*Pad {
    for (self.pads.items) |item| if (item.id == id) return item;
    return null;
}
fn findTool(self: *TabletGlobal, device_id: NativeInput.DeviceId, id: NativeInput.TabletToolId) ?*Tool {
    for (self.tools.items) |item| if (item.device_id == device_id and item.info.id == id) return item;
    return null;
}

fn destroyTablet(self: *TabletGlobal, tablet: *Tablet) void {
    self.allocator.free(tablet.name);
    if (tablet.path) |path| self.allocator.free(path);
    self.allocator.destroy(tablet);
}
fn destroyPad(self: *TabletGlobal, pad: *Pad) void {
    std.debug.assert(pad.focus == null);
    for (pad.groups) |group| freeGroup(self, group);
    self.allocator.free(pad.groups);
    if (pad.path) |path| self.allocator.free(path);
    self.allocator.destroy(pad);
}
fn freeGroup(self: *TabletGlobal, group: Group) void {
    self.allocator.free(group.buttons);
    self.allocator.free(group.rings);
    self.allocator.free(group.strips);
    self.allocator.free(group.dials);
}

fn copyGroup(self: *TabletGlobal, source: NativeInput.TabletPadGroupInfo) !Group {
    const buttons = try self.allocator.dupe(u32, source.buttons);
    errdefer self.allocator.free(buttons);
    const rings = try self.allocator.dupe(u32, source.rings);
    errdefer self.allocator.free(rings);
    const strips = try self.allocator.dupe(u32, source.strips);
    errdefer self.allocator.free(strips);
    const dials = try self.allocator.dupe(u32, source.dials);
    errdefer self.allocator.free(dials);
    return .{ .buttons = buttons, .rings = rings, .strips = strips, .dials = dials, .mode_count = source.mode_count, .mode = source.current_mode };
}

fn retainBinding(binding: *Binding) void {
    binding.references = std.math.add(usize, binding.references, 1) catch unreachable;
}

fn releaseBinding(binding: *Binding) void {
    std.debug.assert(binding.references > 0);
    binding.references -= 1;
    if (binding.references != 0) return;
    const owner = binding.owner;
    for (owner.bindings.items, 0..) |candidate, index| if (candidate == binding) {
        _ = owner.bindings.orderedRemove(index);
        owner.allocator.destroy(binding);
        return;
    };
    unreachable;
}

fn removeAdapter(comptime T: type, allocator: std.mem.Allocator, list: *std.ArrayList(*T), adapter: *T) void {
    for (list.items, 0..) |candidate, index| if (candidate == adapter) {
        _ = list.orderedRemove(index);
        allocator.destroy(adapter);
        return;
    };
    unreachable;
}

fn high(value: u64) u32 {
    return @truncate(value >> 32);
}

fn low(value: u64) u32 {
    return @truncate(value);
}

fn protocolBustype(value: u32) ?generated.zwp_tablet_v2_types.bustype {
    return switch (value) {
        3 => .usb,
        5 => .bluetooth,
        6 => .virtual,
        17 => .serial,
        24 => .i2c,
        else => null,
    };
}

fn normalized(value: f64) u32 {
    if (!std.math.isFinite(value)) return 0;
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * 65535));
}

fn slider(value: f64) i32 {
    if (!std.math.isFinite(value)) return 0;
    return @intFromFloat(@round(std.math.clamp(value, -1, 1) * 65535));
}

fn fixed(value: f64) i32 {
    if (!std.math.isFinite(value)) return 0;
    return clampI32(@round(value * 256));
}

fn clampI32(value: f64) i32 {
    if (!std.math.isFinite(value)) return 0;
    return @intFromFloat(std.math.clamp(value, @as(f64, @floatFromInt(std.math.minInt(i32))), @as(f64, @floatFromInt(std.math.maxInt(i32)))));
}

fn cursorCoordinate(position: f64, hotspot: i32) i32 {
    return clampI32(@floor(position)) -| hotspot;
}

test "tablet numeric protocol clamps are finite and inclusive" {
    try std.testing.expectEqual(@as(u32, 0), normalized(-1));
    try std.testing.expectEqual(@as(u32, 32768), normalized(0.5));
    try std.testing.expectEqual(@as(u32, 65535), normalized(2));
    try std.testing.expectEqual(@as(u32, 0), normalized(std.math.nan(f64)));
    try std.testing.expectEqual(@as(i32, -65535), slider(-2));
    try std.testing.expectEqual(@as(i32, 65535), slider(2));
    try std.testing.expectEqual(@as(i32, 384), fixed(1.5));
    try std.testing.expectEqual(@as(i32, 0), clampI32(std.math.inf(f64)));
}

test "tablet cursor coordinates floor, translate, and saturate" {
    try std.testing.expectEqual(@as(i32, 7), cursorCoordinate(10.9, 3));
    try std.testing.expectEqual(std.math.minInt(i32), cursorCoordinate(@floatFromInt(std.math.minInt(i32)), 1));
    try std.testing.expectEqual(std.math.maxInt(i32), cursorCoordinate(@floatFromInt(std.math.maxInt(i32)), -1));
}

fn testSurfaceCoordinates(_: *anyopaque, _: *CompositorGlobal.Surface, x: f64, y: f64) ?Point {
    return .{ .x = x + 1, .y = y + 2 };
}

fn testRepaint(_: *anyopaque) void {}

test "tablet v2 advertises topology and routes tool, cursor, pad, and removal wire state" {
    const core = @import("wayring-core");
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var compositor: CompositorGlobal = undefined;
    try compositor.init(std.testing.allocator, &server);
    defer compositor.deinit();
    var seat: SeatGlobal = undefined;
    try seat.init(std.testing.allocator, &server, "tablet-test", 0, .{
        .context = undefined,
        .handle = struct {
            fn handle(_: *anyopaque, _: SeatGlobal.CursorIntent) !void {}
        }.handle,
    });
    defer seat.deinit();
    var tablet_global: TabletGlobal = undefined;
    try tablet_global.init(std.testing.allocator, &server, &seat, .{
        .context = undefined,
        .surface_coordinates = testSurfaceCoordinates,
        .repaint = testRepaint,
    });
    defer tablet_global.deinit();

    const tablet_id: NativeInput.DeviceId = 41;
    const pad_id: NativeInput.DeviceId = 42;
    const physical_id: NativeInput.PhysicalDeviceId = 9;
    try tablet_global.addTablet(.{
        .id = tablet_id,
        .physical_id = physical_id,
        .device_type = .tablet,
        .name = "Wire Tablet",
        .vendor = 0x1234,
        .product = 0x5678,
    }, .{ .vendor = 0x1234, .product = 0x5678, .bustype = 3, .path = "/dev/input/tablet-test" });
    const groups = [_]NativeInput.TabletPadGroupInfo{.{
        .buttons = &.{ 1, 3 },
        .rings = &.{0},
        .strips = &.{0},
        .dials = &.{0},
        .mode_count = 3,
        .current_mode = 0,
    }};
    try tablet_global.addPad(.{
        .id = pad_id,
        .physical_id = physical_id,
        .device_type = .tablet_pad,
        .name = "Wire Pad",
        .vendor = 0x1234,
        .product = 0x5678,
    }, .{ .path = "/dev/input/pad-test", .button_count = 4, .groups = &groups });

    const client = try server.createClient();
    var client_alive = true;
    defer if (client_alive) server.destroyClient(client) catch unreachable;
    var peer = wayring.Connection.init(std.testing.allocator, .client, wayring.default_max_frame_size);
    defer peer.deinit();
    _ = try core.bootstrapDisplay(&peer);
    const registry: wayring.ObjectHandle = .{ .id = 2, .generation = try core.getRegistry(&peer, 2) };
    try tabletTransferToServer(&peer, client);
    try tabletTransferFromServer(&peer, client);
    var compositor_name: u32 = 0;
    var seat_name: u32 = 0;
    var manager_name: u32 = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const event = try core.decodeRegistryEvent(&message, registry.id);
        if (event != .global) continue;
        if (std.mem.eql(u8, event.global.interface, generated.wl_compositor.name)) compositor_name = event.global.name;
        if (std.mem.eql(u8, event.global.interface, generated.wl_seat.name)) seat_name = event.global.name;
        if (std.mem.eql(u8, event.global.interface, generated.zwp_tablet_manager_v2.name)) manager_name = event.global.name;
    }
    try std.testing.expect(compositor_name != 0 and seat_name != 0 and manager_name != 0);
    const compositor_resource: wayring.ObjectHandle = .{ .id = 3, .generation = try core.bind(&peer, registry.id, compositor_name, generated.wl_compositor.name, 6, 3, &generated.wl_compositor) };
    const seat_resource: wayring.ObjectHandle = .{ .id = 4, .generation = try core.bind(&peer, registry.id, seat_name, generated.wl_seat.name, 7, 4, &generated.wl_seat) };
    const manager_resource: wayring.ObjectHandle = .{ .id = 5, .generation = try core.bind(&peer, registry.id, manager_name, generated.zwp_tablet_manager_v2.name, 2, 5, &generated.zwp_tablet_manager_v2) };
    try tabletTransferToServer(&peer, client);
    try tabletTransferFromServer(&peer, client);
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == seat_resource.id) _ = try generated.wl_seat_types.decodeEvent(&peer, seat_resource, &message);
    }

    const tablet_seat = try generated.zwp_tablet_manager_v2_types.requests.get_tablet_seat(&peer, manager_resource, seat_resource);
    try tabletTransferToServer(&peer, client);
    try std.testing.expectEqual(Server.ClientState.active, client.state);
    try std.testing.expectEqual(@as(usize, 1), tablet_global.tablet_resources.items.len);
    try std.testing.expectEqual(@as(usize, 1), tablet_global.pad_resources.items.len);
    try tabletTransferFromServer(&peer, client);
    var tablet_resource: wayring.ObjectHandle = undefined;
    var pad_resource: wayring.ObjectHandle = undefined;
    var group_resource: wayring.ObjectHandle = undefined;
    var ring_resource: wayring.ObjectHandle = undefined;
    var strip_resource: wayring.ObjectHandle = undefined;
    var dial_resource: wayring.ObjectHandle = undefined;
    var tablet_metadata: usize = 0;
    var pad_metadata: usize = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == tablet_seat.id) switch (try generated.zwp_tablet_seat_v2_types.decodeEvent(&peer, tablet_seat, &message)) {
            .tablet_added => |event| tablet_resource = try tabletRegisterServerObject(&peer, event.id, &generated.zwp_tablet_v2, 2),
            .pad_added => |event| pad_resource = try tabletRegisterServerObject(&peer, event.id, &generated.zwp_tablet_pad_v2, 2),
            else => return error.UnexpectedTabletSeatEvent,
        } else if (message.object_id == tablet_resource.id) {
            switch (try generated.zwp_tablet_v2_types.decodeEvent(&peer, tablet_resource, &message)) {
                .name => |event| try std.testing.expectEqualStrings("Wire Tablet", event.name),
                .id => |event| {
                    try std.testing.expectEqual(@as(u32, 0x1234), event.vid);
                    try std.testing.expectEqual(@as(u32, 0x5678), event.pid);
                },
                .path => |event| try std.testing.expectEqualStrings("/dev/input/tablet-test", event.path),
                .bustype => |event| try std.testing.expectEqual(@intFromEnum(generated.zwp_tablet_v2_types.bustype.usb), event.bustype),
                .done => {},
                else => return error.UnexpectedTabletMetadata,
            }
            tablet_metadata += 1;
        } else if (message.object_id == pad_resource.id) switch (try generated.zwp_tablet_pad_v2_types.decodeEvent(&peer, pad_resource, &message)) {
            .path => |event| try std.testing.expectEqualStrings("/dev/input/pad-test", event.path),
            .buttons => |event| try std.testing.expectEqual(@as(u32, 4), event.buttons),
            .group => |event| group_resource = try tabletRegisterServerObject(&peer, event.pad_group, &generated.zwp_tablet_pad_group_v2, 2),
            .done => {},
            else => return error.UnexpectedPadMetadata,
        } else if (message.object_id == group_resource.id) switch (try generated.zwp_tablet_pad_group_v2_types.decodeEvent(&peer, group_resource, &message)) {
            .buttons => |event| try std.testing.expectEqual(@as(usize, 2 * @sizeOf(u32)), event.buttons.len),
            .ring => |event| ring_resource = try tabletRegisterServerObject(&peer, event.ring, &generated.zwp_tablet_pad_ring_v2, 2),
            .strip => |event| strip_resource = try tabletRegisterServerObject(&peer, event.strip, &generated.zwp_tablet_pad_strip_v2, 2),
            .dial => |event| dial_resource = try tabletRegisterServerObject(&peer, event.dial, &generated.zwp_tablet_pad_dial_v2, 2),
            .modes => |event| try std.testing.expectEqual(@as(u32, 3), event.modes),
            .done => {},
            else => return error.UnexpectedPadGroupMetadata,
        } else return error.UnexpectedTabletMetadataObject;
        pad_metadata += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), tablet_metadata);
    try std.testing.expect(pad_metadata >= 10);
    try std.testing.expect(ring_resource.id != 0 and strip_resource.id != 0 and dial_resource.id != 0);

    const surface_handle = try generated.wl_compositor_types.requests.create_surface(&peer, compositor_resource);
    const cursor_handle = try generated.wl_compositor_types.requests.create_surface(&peer, compositor_resource);
    try tabletTransferToServer(&peer, client);
    const surface = try CompositorGlobal.surfaceFor(client, .{ .id = surface_handle.id, .generation = client.connection.object(surface_handle.id).?.generation });
    const info: NativeInput.TabletToolInfo = .{
        .id = 77,
        .tool_type = .pen,
        .serial = 0x1122334455667788,
        .hardware_id = 0x99aabbccddeeff00,
        .capabilities = .{ .pressure = true, .distance = true, .tilt = true, .rotation = true, .slider = true, .wheel = true },
    };
    const axes: NativeInput.TabletToolAxes = .{
        .position = .{ .x = 10.5, .y = 20.25 },
        .pressure = 0.5,
        .distance = 0.25,
        .tilt = .{ .x = 1.5, .y = -2.5 },
        .rotation = 45,
        .slider = -0.5,
        .wheel = .{ .degrees = 15, .clicks = 1 },
    };
    try tablet_global.proximity(tablet_id, info, 100, .{ .surface = surface, .x = 0, .y = 0 }, true, axes);
    try tabletTransferFromServer(&peer, client);
    var tool_resource: wayring.ObjectHandle = undefined;
    var proximity_serial: u32 = 0;
    var tool_events: usize = 0;
    var pad_focus_events: usize = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == tablet_seat.id) {
            const event = try generated.zwp_tablet_seat_v2_types.decodeEvent(&peer, tablet_seat, &message);
            tool_resource = try tabletRegisterServerObject(&peer, event.tool_added.id, &generated.zwp_tablet_tool_v2, 2);
            continue;
        }
        if (message.object_id == pad_resource.id) {
            const event = try generated.zwp_tablet_pad_v2_types.decodeEvent(&peer, pad_resource, &message);
            switch (event) {
                .enter => |enter| {
                    try std.testing.expectEqual(tablet_resource.id, enter.tablet);
                    try std.testing.expectEqual(surface_handle.id, enter.surface);
                },
                else => return error.UnexpectedPadFocusEvent,
            }
            pad_focus_events += 1;
            continue;
        }
        if (message.object_id == group_resource.id) {
            const event = try generated.zwp_tablet_pad_group_v2_types.decodeEvent(&peer, group_resource, &message);
            switch (event) {
                .mode_switch => |mode| try std.testing.expectEqual(@as(u32, 0), mode.mode),
                else => return error.UnexpectedPadFocusEvent,
            }
            pad_focus_events += 1;
            continue;
        }
        switch (try generated.zwp_tablet_tool_v2_types.decodeEvent(&peer, tool_resource, &message)) {
            .hardware_serial => |event| {
                try std.testing.expectEqual(@as(u32, 0x11223344), event.hardware_serial_hi);
                try std.testing.expectEqual(@as(u32, 0x55667788), event.hardware_serial_lo);
            },
            .hardware_id_wacom => |event| {
                try std.testing.expectEqual(@as(u32, 0x99aabbcc), event.hardware_id_hi);
                try std.testing.expectEqual(@as(u32, 0xddeeff00), event.hardware_id_lo);
            },
            .proximity_in => |event| proximity_serial = event.serial,
            else => {},
        }
        tool_events += 1;
    }
    try std.testing.expect(tool_events >= 15);
    try std.testing.expectEqual(@as(usize, 2), pad_focus_events);
    try std.testing.expect(proximity_serial != 0);

    try generated.zwp_tablet_tool_v2_types.requests.set_cursor(&peer, tool_resource, proximity_serial, cursor_handle, 3, 4);
    try tabletTransferToServer(&peer, client);
    const cursor_surface = try CompositorGlobal.surfaceFor(client, .{ .id = cursor_handle.id, .generation = client.connection.object(cursor_handle.id).?.generation });
    try std.testing.expect(tablet_global.isCursorSurface(cursor_surface));
    var iterator = tablet_global.cursorIterator();
    const cursor = iterator.next().?.surface;
    try std.testing.expectEqual(@as(i32, 7), cursor.x);
    try std.testing.expectEqual(@as(i32, 16), cursor.y);
    try generated.zwp_tablet_tool_v2_types.requests.set_cursor(&peer, tool_resource, proximity_serial - 1, null, 0, 0);
    try tabletTransferToServer(&peer, client);
    try std.testing.expect(tablet_global.isCursorSurface(cursor_surface));
    try generated.wl_surface_types.requests.destroy(&peer, cursor_handle);
    try tabletTransferToServer(&peer, client);
    try std.testing.expect(!tablet_global.isCursorSurface(cursor_surface));
    var empty_iterator = tablet_global.cursorIterator();
    try std.testing.expect(empty_iterator.next() == null);
    try tabletTransferFromServer(&peer, client);
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        try std.testing.expectEqual(@as(u32, 1), message.object_id);
        _ = try core.decodeDisplayEvent(&message);
    }

    const tool_handle = tablet_global.toolHandle(client, tool_resource.id).?;
    var shape_pixels = [_]u32{0xffffffff} ** 4;
    const shape_buffer: render.PixelBuffer = .{
        .size = .{ .width = 2, .height = 2 },
        .stride_pixels = 2,
        .pixels = &shape_pixels,
    };
    tablet_global.setCursorShape(client, tool_handle, proximity_serial, shape_buffer, 1, 2);
    var shape_iterator = tablet_global.cursorIterator();
    const shape = shape_iterator.next().?.shape;
    try std.testing.expectEqual(@as(i32, 9), shape.x);
    try std.testing.expectEqual(@as(i32, 18), shape.y);
    try std.testing.expectEqual(shape_buffer.size, shape.buffer.size);
    tablet_global.setCursorShape(client, tool_handle, proximity_serial - 1, shape_buffer, 4, 4);
    var unchanged_iterator = tablet_global.cursorIterator();
    const unchanged = unchanged_iterator.next().?.shape;
    try std.testing.expectEqual(@as(i32, 9), unchanged.x);
    try std.testing.expectEqual(@as(i32, 18), unchanged.y);
    tablet_global.clearCursorShapes();
    var cleared_iterator = tablet_global.cursorIterator();
    try std.testing.expect(cleared_iterator.next() == null);

    try tablet_global.padButton(pad_id, 110, 1, true, 0, 1);
    try tablet_global.padRing(pad_id, 111, 0, 30, true, 0, 1);
    try tablet_global.padStrip(pad_id, 112, 0, 0.75, true, 0, 1);
    try tablet_global.padDial(pad_id, 113, 0, 120, 0, 1);
    try tabletTransferFromServer(&peer, client);
    var control_events: usize = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == pad_resource.id) {
            _ = try generated.zwp_tablet_pad_v2_types.decodeEvent(&peer, pad_resource, &message);
        } else if (message.object_id == group_resource.id) {
            _ = try generated.zwp_tablet_pad_group_v2_types.decodeEvent(&peer, group_resource, &message);
        } else if (message.object_id == ring_resource.id) {
            _ = try generated.zwp_tablet_pad_ring_v2_types.decodeEvent(&peer, ring_resource, &message);
        } else if (message.object_id == strip_resource.id) {
            _ = try generated.zwp_tablet_pad_strip_v2_types.decodeEvent(&peer, strip_resource, &message);
        } else if (message.object_id == dial_resource.id) {
            _ = try generated.zwp_tablet_pad_dial_v2_types.decodeEvent(&peer, dial_resource, &message);
        } else return error.UnexpectedPadControlObject;
        control_events += 1;
    }
    try std.testing.expect(control_events >= 10);

    try tablet_global.tip(tablet_id, info.id, 120, null, .{}, true);
    try tablet_global.button(tablet_id, info.id, 121, null, .{}, 0x14b, true);
    try tablet_global.proximity(tablet_id, info, 122, null, false, .{});
    try std.testing.expect(tablet_global.tools.items[0].position == null);
    try tabletTransferFromServer(&peer, client);
    const expected_release_events = [_][]const u8{
        "down",
        "frame",
        "button",
        "frame",
        "button",
        "up",
        "proximity_out",
        "frame",
    };
    var release_events: usize = 0;
    var pad_leave_events: usize = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == pad_resource.id) {
            const event = try generated.zwp_tablet_pad_v2_types.decodeEvent(&peer, pad_resource, &message);
            switch (event) {
                .leave => |leave| try std.testing.expectEqual(surface_handle.id, leave.surface),
                else => return error.UnexpectedPadLeaveEvent,
            }
            pad_leave_events += 1;
            continue;
        }
        const event = try generated.zwp_tablet_tool_v2_types.decodeEvent(&peer, tool_resource, &message);
        try std.testing.expect(release_events < expected_release_events.len);
        try std.testing.expectEqualStrings(expected_release_events[release_events], @tagName(event));
        release_events += 1;
    }
    try std.testing.expectEqual(expected_release_events.len, release_events);
    try std.testing.expectEqual(@as(usize, 1), pad_leave_events);

    try tablet_global.removePad(pad_id);
    try tablet_global.removeTablet(tablet_id);
    try tabletTransferFromServer(&peer, client);
    var removed: usize = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == pad_resource.id) {
            _ = try generated.zwp_tablet_pad_v2_types.decodeEvent(&peer, pad_resource, &message);
        } else if (message.object_id == tablet_resource.id) {
            _ = try generated.zwp_tablet_v2_types.decodeEvent(&peer, tablet_resource, &message);
        } else if (message.object_id == tool_resource.id) {
            _ = try generated.zwp_tablet_tool_v2_types.decodeEvent(&peer, tool_resource, &message);
        } else return error.UnexpectedRemovedObject;
        removed += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), removed);
    try tablet_global.axis(tablet_id, info.id, 130, null, axes);
    try tablet_global.padRing(pad_id, 130, 0, 10, true, 0, 0);
    try tabletTransferFromServer(&peer, client);
    try std.testing.expect(peer.popMessage() == null);

    server.destroyClient(client) catch unreachable;
    client_alive = false;
}

fn tabletTransferToServer(connection: *wayring.Connection, client: *Server.Client) !void {
    while (connection.nextBatch()) |batch| {
        try client.receive(batch.bytes, batch.fds);
        try connection.acknowledge(batch.token, batch.bytes.len);
    }
}

fn tabletRegisterServerObject(connection: *wayring.Connection, id: u32, interface: *const wayring.Interface, version: u32) !wayring.ObjectHandle {
    const handle: wayring.ObjectHandle = .{
        .id = id,
        .generation = try connection.registerObject(id, interface, version),
    };
    try connection.resumeParsing();
    return handle;
}

fn tabletTransferFromServer(connection: *wayring.Connection, client: *Server.Client) !void {
    while (client.connection.nextBatch()) |batch| {
        try connection.feed(batch.bytes, batch.fds);
        try client.connection.acknowledge(batch.token, batch.bytes.len);
    }
    try client.outputDrained();
}
