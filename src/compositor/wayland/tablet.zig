//! Graphics tablet devices and tool input.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const NativeInput = @import("../backend/native_input.zig");
const ClientRegistry = @import("../ClientRegistry.zig");
const Seat = @import("seat.zig");
const Surface = @import("surface.zig");

const wl = wayland.server.wl;
const zwp = wayland.server.zwp;

allocator: std.mem.Allocator,
display: *wl.Server,
surface_store: *Surface.Store,
global: *wl.Global,
listener: Listener,
seat_bindings: std.ArrayList(*SeatBinding),
devices: std.ArrayList(*Device),
tools: std.ArrayList(*Tool),
pad_devices: std.ArrayList(*Pad),
tablet_resources: std.ArrayList(*TabletResource),
tool_resources: std.ArrayList(*ToolResource),
pad_resources: std.ArrayList(*PadResource),
pad_group_resources: std.ArrayList(*PadGroupResource),
pad_ring_resources: std.ArrayList(*PadRingResource),
pad_strip_resources: std.ArrayList(*PadStripResource),
pad_dial_resources: std.ArrayList(*PadDialResource),
next_tool_cursor_owner_id: u64,
next_tool_resource_generation: u64,
next_tool_focus_generation: u64,
cursor_surface_count: usize,

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    surface_store: *Surface.Store,
    listener: Listener,
) !void {
    self.* = .{
        .allocator = allocator,
        .display = display,
        .surface_store = surface_store,
        .global = try wl.Global.create(display, zwp.TabletManagerV2, 2, *Self, self, bind),
        .listener = listener,
        .seat_bindings = .empty,
        .devices = .empty,
        .tools = .empty,
        .pad_devices = .empty,
        .tablet_resources = .empty,
        .tool_resources = .empty,
        .pad_resources = .empty,
        .pad_group_resources = .empty,
        .pad_ring_resources = .empty,
        .pad_strip_resources = .empty,
        .pad_dial_resources = .empty,
        .next_tool_cursor_owner_id = 1,
        .next_tool_resource_generation = 1,
        .next_tool_focus_generation = 1,
        .cursor_surface_count = 0,
    };
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.seat_bindings.items.len == 0);
    std.debug.assert(self.tablet_resources.items.len == 0);
    std.debug.assert(self.tool_resources.items.len == 0);
    std.debug.assert(self.pad_resources.items.len == 0);
    std.debug.assert(self.pad_group_resources.items.len == 0);
    std.debug.assert(self.pad_ring_resources.items.len == 0);
    std.debug.assert(self.pad_strip_resources.items.len == 0);
    std.debug.assert(self.pad_dial_resources.items.len == 0);
    std.debug.assert(self.cursor_surface_count == 0);
    while (self.tools.pop()) |tool| self.destroyTool(tool);
    while (self.pad_devices.pop()) |pad| self.destroyPad(pad);
    while (self.devices.pop()) |device| self.destroyDevice(device);
    self.global.destroy();
    self.tool_resources.deinit(self.allocator);
    self.tablet_resources.deinit(self.allocator);
    self.pad_dial_resources.deinit(self.allocator);
    self.pad_strip_resources.deinit(self.allocator);
    self.pad_ring_resources.deinit(self.allocator);
    self.pad_group_resources.deinit(self.allocator);
    self.pad_resources.deinit(self.allocator);
    self.tools.deinit(self.allocator);
    self.pad_devices.deinit(self.allocator);
    self.devices.deinit(self.allocator);
    self.seat_bindings.deinit(self.allocator);
    self.* = undefined;
}

pub fn addTablet(
    self: *Self,
    id: NativeInput.DeviceId,
    physical_id: NativeInput.PhysicalDeviceId,
    seat: *Seat,
    name: [:0]const u8,
    info: NativeInput.TabletInfo,
) !void {
    std.debug.assert(self.findDevice(id) == null);
    const device = try self.allocator.create(Device);
    errdefer self.allocator.destroy(device);
    const name_copy = try self.allocator.dupeSentinel(u8, name, 0);
    errdefer self.allocator.free(name_copy);
    const path_copy = if (info.path) |path|
        try self.allocator.dupeSentinel(u8, path, 0)
    else
        null;
    errdefer if (path_copy) |path| self.allocator.free(path);
    device.* = .{
        .manager = self,
        .id = id,
        .physical_id = physical_id,
        .seat = seat,
        .name = name_copy,
        .vendor = info.vendor,
        .product = info.product,
        .bustype = info.bustype,
        .path = path_copy,
    };
    try self.devices.append(self.allocator, device);
    for (self.seat_bindings.items) |binding| {
        if (binding.resource != null and binding.seat == seat) {
            self.createTabletResource(binding, device) catch binding.resource.?.postNoMemory();
        }
    }
}

pub fn removeTablet(self: *Self, id: NativeInput.DeviceId) void {
    const device = self.findDevice(id) orelse return;
    self.unadvertiseDevice(device, true);
    for (self.devices.items, 0..) |candidate, index| {
        if (candidate != device) continue;
        _ = self.devices.orderedRemove(index);
        self.destroyDevice(device);
        return;
    }
    unreachable;
}

pub fn moveTablet(self: *Self, id: NativeInput.DeviceId, seat: *Seat) !void {
    const device = self.findDevice(id) orelse return;
    if (device.seat == seat) return;
    self.unadvertiseDevice(device, false);
    device.seat = seat;
    for (self.seat_bindings.items) |binding| {
        if (binding.resource == null or binding.seat != seat) continue;
        self.createTabletResource(binding, device) catch binding.resource.?.postNoMemory();
        for (self.tools.items) |tool| {
            if (tool.device == device) {
                self.createToolResource(binding, tool) catch binding.resource.?.postNoMemory();
            }
        }
    }
}

pub fn addPad(
    self: *Self,
    id: NativeInput.DeviceId,
    physical_id: NativeInput.PhysicalDeviceId,
    seat: *Seat,
    info: NativeInput.TabletPadInfo,
) !void {
    std.debug.assert(self.findPad(id) == null);
    const pad = try self.allocator.create(Pad);
    errdefer self.allocator.destroy(pad);
    const path = if (info.path) |value|
        try self.allocator.dupeSentinel(u8, value, 0)
    else
        null;
    errdefer if (path) |value| self.allocator.free(value);
    const groups = try self.allocator.alloc(PadGroup, info.groups.len);
    var initialized: usize = 0;
    errdefer {
        for (groups[0..initialized]) |group| self.deinitPadGroup(group);
        self.allocator.free(groups);
    }
    while (initialized < groups.len) : (initialized += 1) {
        groups[initialized] = try self.copyPadGroup(info.groups[initialized]);
    }
    pad.* = .{
        .manager = self,
        .id = id,
        .physical_id = physical_id,
        .seat = seat,
        .path = path,
        .button_count = info.button_count,
        .groups = groups,
        .focus = null,
        .focus_destroy_listener = wl.Listener(*wl.Resource).init(handlePadFocusDestroyed),
    };
    try self.pad_devices.append(self.allocator, pad);
    for (self.seat_bindings.items) |binding| {
        if (binding.resource != null and binding.seat == seat) {
            self.createPadResource(binding, pad) catch binding.resource.?.postNoMemory();
        }
    }
    self.refreshPadFocus(pad, 0);
}

pub fn removePad(self: *Self, id: NativeInput.DeviceId) void {
    const pad = self.findPad(id) orelse return;
    self.unadvertisePad(pad);
    for (self.pad_devices.items, 0..) |candidate, index| {
        if (candidate != pad) continue;
        _ = self.pad_devices.orderedRemove(index);
        self.destroyPad(pad);
        return;
    }
    unreachable;
}

pub fn movePad(self: *Self, id: NativeInput.DeviceId, seat: *Seat) !void {
    const pad = self.findPad(id) orelse return;
    if (pad.seat == seat) return;
    self.unadvertisePad(pad);
    pad.seat = seat;
    for (self.seat_bindings.items) |binding| {
        if (binding.resource != null and binding.seat == seat) {
            self.createPadResource(binding, pad) catch binding.resource.?.postNoMemory();
        }
    }
    self.refreshPadFocus(pad, 0);
}

pub fn padButton(
    self: *Self,
    id: NativeInput.DeviceId,
    time: u32,
    button_index: u32,
    pressed: bool,
    group_index: u32,
    mode: u32,
) void {
    const pad = self.findPad(id) orelse return;
    self.updatePadMode(pad, time, group_index, mode);
    if (button_index >= pad.button_count) return;
    for (self.pad_resources.items) |adapter| {
        if (adapter.pad == pad and adapter.active) adapter.resource.sendButton(
            time,
            button_index,
            if (pressed) .pressed else .released,
        );
    }
}

pub fn padRing(
    self: *Self,
    id: NativeInput.DeviceId,
    time: u32,
    ring_index: u32,
    position: f64,
    finger: bool,
    group_index: u32,
    mode: u32,
) void {
    const pad = self.findPad(id) orelse return;
    self.updatePadMode(pad, time, group_index, mode);
    for (self.pad_ring_resources.items) |adapter| {
        if (adapter.pad != pad or adapter.index != ring_index or
            !self.padBindingActive(adapter.binding, pad)) continue;
        if (finger) adapter.resource.sendSource(.finger);
        if (position < 0) adapter.resource.sendStop() else adapter.resource.sendAngle(fixed(position));
        adapter.resource.sendFrame(time);
    }
}

pub fn padStrip(
    self: *Self,
    id: NativeInput.DeviceId,
    time: u32,
    strip_index: u32,
    position: f64,
    finger: bool,
    group_index: u32,
    mode: u32,
) void {
    const pad = self.findPad(id) orelse return;
    self.updatePadMode(pad, time, group_index, mode);
    for (self.pad_strip_resources.items) |adapter| {
        if (adapter.pad != pad or adapter.index != strip_index or
            !self.padBindingActive(adapter.binding, pad)) continue;
        if (finger) adapter.resource.sendSource(.finger);
        if (position < 0) adapter.resource.sendStop() else adapter.resource.sendPosition(normalizedUnsigned(position));
        adapter.resource.sendFrame(time);
    }
}

pub fn padDial(
    self: *Self,
    id: NativeInput.DeviceId,
    time: u32,
    dial_index: u32,
    value120: i32,
    group_index: u32,
    mode: u32,
) void {
    std.debug.assert(value120 != 0);
    const pad = self.findPad(id) orelse return;
    self.updatePadMode(pad, time, group_index, mode);
    for (self.pad_dial_resources.items) |adapter| {
        if (adapter.pad != pad or adapter.index != dial_index or
            !self.padBindingActive(adapter.binding, pad)) continue;
        adapter.resource.sendDelta(value120);
        adapter.resource.sendFrame(time);
    }
}

pub fn proximity(
    self: *Self,
    device_id: NativeInput.DeviceId,
    info: NativeInput.TabletToolInfo,
    time: u32,
    target: ?Seat.PointerFocus,
    in_proximity: bool,
    axes: NativeInput.TabletToolAxes,
) !void {
    const device = self.findDevice(device_id) orelse return;
    const tool = try self.ensureTool(device, info);
    if (!in_proximity) {
        tool.in_proximity = false;
        self.leaveFocus(tool, time, true);
        return;
    }
    tool.in_proximity = true;
    self.updateFocus(tool, target, time);
    self.sendAxes(tool, target, axes);
    self.sendFrame(tool, time);
}

pub fn axis(
    self: *Self,
    device_id: NativeInput.DeviceId,
    tool_id: NativeInput.TabletToolId,
    time: u32,
    target: ?Seat.PointerFocus,
    axes: NativeInput.TabletToolAxes,
) void {
    const tool = self.findTool(device_id, tool_id) orelse return;
    if (!tool.in_proximity) return;
    if (axes.position != null) self.updateFocus(tool, target, time);
    self.sendAxes(tool, target, axes);
    self.sendFrame(tool, time);
}

pub fn tip(
    self: *Self,
    device_id: NativeInput.DeviceId,
    tool_id: NativeInput.TabletToolId,
    time: u32,
    target: ?Seat.PointerFocus,
    axes: NativeInput.TabletToolAxes,
    down: bool,
) void {
    const tool = self.findTool(device_id, tool_id) orelse return;
    if (!tool.in_proximity) return;
    if (axes.position != null) self.updateFocus(tool, target, time);
    self.sendAxes(tool, target, axes);
    if (tool.tip_down != down) {
        tool.tip_down = down;
        const serial = if (down) self.display.nextSerial() else 0;
        for (self.tool_resources.items) |adapter| {
            if (adapter.tool != tool or !adapter.active) continue;
            if (down) {
                adapter.resource.sendDown(serial);
            } else {
                adapter.resource.sendUp();
            }
        }
    }
    self.sendFrame(tool, time);
}

pub fn button(
    self: *Self,
    device_id: NativeInput.DeviceId,
    tool_id: NativeInput.TabletToolId,
    time: u32,
    target: ?Seat.PointerFocus,
    axes: NativeInput.TabletToolAxes,
    button_code: u32,
    pressed: bool,
) !void {
    const tool = self.findTool(device_id, tool_id) orelse return;
    if (!tool.in_proximity) return;
    const had_focus = tool.focus != null;
    var state_changed = false;
    var release_index: ?usize = null;
    if (pressed) {
        for (tool.pressed_buttons.items) |pressed_button| {
            if (pressed_button == button_code) break;
        } else {
            try tool.pressed_buttons.append(self.allocator, button_code);
            state_changed = true;
        }
    } else {
        for (tool.pressed_buttons.items, 0..) |pressed_button, index| {
            if (pressed_button != button_code) continue;
            state_changed = true;
            release_index = index;
            break;
        }
    }
    if (axes.position != null) self.updateFocus(tool, target, time);
    self.sendAxes(tool, target, axes);
    if (state_changed and had_focus) {
        const serial = self.display.nextSerial();
        for (self.tool_resources.items) |adapter| {
            if (adapter.tool == tool and adapter.active) {
                adapter.resource.sendButton(
                    serial,
                    button_code,
                    if (pressed) .pressed else .released,
                );
            }
        }
    }
    if (release_index) |index| _ = tool.pressed_buttons.orderedRemove(index);
    self.sendFrame(tool, time);
}

const Device = struct {
    manager: *Self,
    id: NativeInput.DeviceId,
    physical_id: NativeInput.PhysicalDeviceId,
    seat: *Seat,
    name: [:0]u8,
    vendor: u32,
    product: u32,
    bustype: u32,
    path: ?[:0]u8,
};

pub const Point = struct { x: f64, y: f64 };

pub const Listener = struct {
    context: *anyopaque,
    surface_coordinates: *const fn (*anyopaque, Surface.Id, f64, f64) ?Point,
    repaint: *const fn (*anyopaque) void,
};

const SurfaceCursor = struct {
    surface_id: Surface.Id,
    hotspot_x: i32,
    hotspot_y: i32,
};

const Cursor = union(enum) {
    surface: SurfaceCursor,
    shape: Seat.ShapeCursor,
};

pub const CursorInfo = struct {
    focus_surface: Surface.Id,
    cursor: Seat.CursorInfo,
};

pub const CursorIterator = struct {
    manager: *const Self,
    index: usize = 0,

    pub fn next(self: *CursorIterator) ?CursorInfo {
        while (self.index < self.manager.tools.items.len) {
            const tool = self.manager.tools.items[self.index];
            self.index += 1;
            const focus_surface = tool.focus orelse continue;
            const position = tool.position orelse continue;
            const cursor = tool.cursor orelse continue;
            return .{
                .focus_surface = focus_surface,
                .cursor = switch (cursor) {
                    .surface => |surface| .{ .surface = .{
                        .surface_id = surface.surface_id,
                        .x = Seat.cursorCoordinate(position.x, surface.hotspot_x),
                        .y = Seat.cursorCoordinate(position.y, surface.hotspot_y),
                    } },
                    .shape => |shape| .{ .shape = .{
                        .buffer = shape.buffer,
                        .x = Seat.cursorCoordinate(position.x, shape.hotspot_x),
                        .y = Seat.cursorCoordinate(position.y, shape.hotspot_y),
                    } },
                },
            };
        }
        return null;
    }
};

pub fn cursorIterator(self: *const Self) CursorIterator {
    return .{ .manager = self };
}

pub const ToolBinding = struct {
    manager: *Self,
    generation: u64,

    pub fn setCursorShape(
        self: ToolBinding,
        client: *wl.Client,
        serial: u32,
        shape: Seat.ShapeCursor,
    ) void {
        self.manager.setToolCursorShape(self.generation, client, serial, shape);
    }
};

pub fn toolBinding(self: *Self, resource: *zwp.TabletToolV2) ?ToolBinding {
    for (self.tool_resources.items) |adapter| {
        if (adapter.resource == resource and adapter.tool != null) return .{
            .manager = self,
            .generation = adapter.generation,
        };
    }
    return null;
}

pub fn clearCursorShapes(self: *Self) void {
    var repaint = false;
    for (self.tools.items) |tool| {
        const cursor = tool.cursor orelse continue;
        switch (cursor) {
            .surface => {},
            .shape => {
                tool.cursor = null;
                repaint = true;
            },
        }
    }
    if (repaint) self.requestRepaint();
}

pub fn cancelFocus(self: *Self) void {
    for (self.tools.items) |tool| self.leaveFocus(tool, 0, true);
}

const Tool = struct {
    manager: *Self,
    cursor_owner_id: u64,
    focus_generation: u64,
    info: NativeInput.TabletToolInfo,
    device: *Device,
    in_proximity: bool,
    focus: ?Surface.Id,
    focus_resource: ?*wl.Surface,
    focus_destroy_listener: wl.Listener(*wl.Resource),
    tip_down: bool,
    pressed_buttons: std.ArrayList(u32),
    position: ?Point,
    cursor: ?Cursor,
};

const PadGroup = struct {
    buttons: []u32,
    rings: []u32,
    strips: []u32,
    dials: []u32,
    mode_count: u32,
    current_mode: u32,
};

const PadFocus = struct {
    tablet_id: NativeInput.DeviceId,
    surface_id: Surface.Id,
    resource: *wl.Surface,
};

const Pad = struct {
    manager: *Self,
    id: NativeInput.DeviceId,
    physical_id: NativeInput.PhysicalDeviceId,
    seat: *Seat,
    path: ?[:0]u8,
    button_count: u32,
    groups: []PadGroup,
    focus: ?PadFocus,
    focus_destroy_listener: wl.Listener(*wl.Resource),
};

const SeatBinding = struct {
    manager: *Self,
    resource: ?*zwp.TabletSeatV2,
    client: *wl.Client,
    seat: *Seat,
    references: usize,
};

const TabletResource = struct {
    binding: *SeatBinding,
    resource: *zwp.TabletV2,
    device: ?*Device,
};

const ToolResource = struct {
    binding: *SeatBinding,
    resource: *zwp.TabletToolV2,
    generation: u64,
    tool: ?*Tool,
    active: bool,
    proximity_serial: ?ClientRegistry.Serial,
};

const PadResource = struct {
    binding: *SeatBinding,
    resource: *zwp.TabletPadV2,
    pad: ?*Pad,
    active: bool,
};

const PadGroupResource = struct {
    binding: *SeatBinding,
    resource: *zwp.TabletPadGroupV2,
    pad: ?*Pad,
    group_index: u32,
};

const PadRingResource = struct {
    binding: *SeatBinding,
    resource: *zwp.TabletPadRingV2,
    pad: ?*Pad,
    index: u32,
};

const PadStripResource = struct {
    binding: *SeatBinding,
    resource: *zwp.TabletPadStripV2,
    pad: ?*Pad,
    index: u32,
};

const PadDialResource = struct {
    binding: *SeatBinding,
    resource: *zwp.TabletPadDialV2,
    pad: ?*Pad,
    index: u32,
};

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = zwp.TabletManagerV2.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleManagerRequest, null, self);
}

fn handleManagerRequest(
    resource: *zwp.TabletManagerV2,
    request: zwp.TabletManagerV2.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .get_tablet_seat => |get| self.createSeatBinding(
            resource,
            get.tablet_seat,
            Seat.fromResource(get.seat),
        ) catch resource.postNoMemory(),
    }
}

fn createSeatBinding(
    self: *Self,
    manager_resource: *zwp.TabletManagerV2,
    id: u32,
    seat: *Seat,
) !void {
    const resource = try zwp.TabletSeatV2.create(
        manager_resource.getClient(),
        manager_resource.getVersion(),
        id,
    );
    errdefer resource.destroy();
    const binding = try self.allocator.create(SeatBinding);
    errdefer self.allocator.destroy(binding);
    binding.* = .{
        .manager = self,
        .resource = resource,
        .client = manager_resource.getClient(),
        .seat = seat,
        .references = 1,
    };
    try self.seat_bindings.append(self.allocator, binding);
    resource.setHandler(*SeatBinding, handleSeatRequest, handleSeatDestroy, binding);
    for (self.devices.items) |device| {
        if (device.seat == seat) self.createTabletResource(binding, device) catch
            resource.postNoMemory();
    }
    for (self.tools.items) |tool| {
        if (tool.device.seat == seat) self.createToolResource(binding, tool) catch
            resource.postNoMemory();
    }
    for (self.pad_devices.items) |pad| {
        if (pad.seat == seat) self.createPadResource(binding, pad) catch
            resource.postNoMemory();
    }
}

fn handleSeatRequest(
    resource: *zwp.TabletSeatV2,
    request: zwp.TabletSeatV2.Request,
    _: *SeatBinding,
) void {
    switch (request) {
        .destroy => resource.destroy(),
    }
}

fn handleSeatDestroy(_: *zwp.TabletSeatV2, binding: *SeatBinding) void {
    binding.resource = null;
    releaseBinding(binding);
}

fn createTabletResource(self: *Self, binding: *SeatBinding, device: *Device) !void {
    const seat_resource = binding.resource orelse return;
    const resource = try zwp.TabletV2.create(
        binding.client,
        seat_resource.getVersion(),
        0,
    );
    errdefer resource.destroy();
    const adapter = try self.allocator.create(TabletResource);
    errdefer self.allocator.destroy(adapter);
    adapter.* = .{ .binding = binding, .resource = resource, .device = device };
    try self.tablet_resources.append(self.allocator, adapter);
    retainBinding(binding);
    resource.setHandler(*TabletResource, handleTabletRequest, handleTabletDestroy, adapter);
    seat_resource.sendTabletAdded(resource);
    resource.sendName(device.name);
    if (device.vendor != 0 or device.product != 0) {
        resource.sendId(device.vendor, device.product);
    }
    if (device.path) |path| resource.sendPath(path);
    if (resource.getVersion() >= zwp.TabletV2.bustype_since_version) {
        if (protocolBustype(device.bustype)) |bustype| resource.sendBustype(bustype);
    }
    resource.sendDone();
}

fn handleTabletRequest(
    resource: *zwp.TabletV2,
    request: zwp.TabletV2.Request,
    _: *TabletResource,
) void {
    switch (request) {
        .destroy => resource.destroy(),
    }
}

fn handleTabletDestroy(_: *zwp.TabletV2, adapter: *TabletResource) void {
    const manager = adapter.binding.manager;
    const binding = adapter.binding;
    removeAdapter(TabletResource, manager.allocator, &manager.tablet_resources, adapter);
    releaseBinding(binding);
}

fn createToolResource(self: *Self, binding: *SeatBinding, tool: *Tool) !void {
    const seat_resource = binding.resource orelse return;
    const resource = try zwp.TabletToolV2.create(
        binding.client,
        seat_resource.getVersion(),
        0,
    );
    errdefer resource.destroy();
    const adapter = try self.allocator.create(ToolResource);
    errdefer self.allocator.destroy(adapter);
    adapter.* = .{
        .binding = binding,
        .resource = resource,
        .generation = self.next_tool_resource_generation,
        .tool = tool,
        .active = false,
        .proximity_serial = null,
    };
    self.next_tool_resource_generation = std.math.add(
        u64,
        self.next_tool_resource_generation,
        1,
    ) catch unreachable;
    try self.tool_resources.append(self.allocator, adapter);
    retainBinding(binding);
    resource.setHandler(*ToolResource, handleToolRequest, handleToolDestroy, adapter);
    seat_resource.sendToolAdded(resource);
    resource.sendType(switch (tool.info.tool_type) {
        .pen => .pen,
        .eraser => .eraser,
        .brush => .brush,
        .pencil => .pencil,
        .airbrush => .airbrush,
        .mouse => .mouse,
        .lens => .lens,
    });
    if (tool.info.serial) |serial| {
        resource.sendHardwareSerial(high(serial), low(serial));
    }
    if (tool.info.hardware_id) |hardware_id| {
        resource.sendHardwareIdWacom(high(hardware_id), low(hardware_id));
    }
    const capabilities = tool.info.capabilities;
    if (capabilities.tilt) resource.sendCapability(.tilt);
    if (capabilities.pressure) resource.sendCapability(.pressure);
    if (capabilities.distance) resource.sendCapability(.distance);
    if (capabilities.rotation) resource.sendCapability(.rotation);
    if (capabilities.slider) resource.sendCapability(.slider);
    if (capabilities.wheel) resource.sendCapability(.wheel);
    resource.sendDone();
    const surface = tool.focus_resource orelse return;
    if (!tool.in_proximity or binding.client != surface.getClient()) return;
    const tablet = self.tabletResource(binding, tool.device) orelse return;
    const serial = matureSerial(self.display.nextSerial());
    adapter.active = true;
    adapter.proximity_serial = serial;
    resource.sendProximityIn(serial.value, tablet.resource, surface);
    for (tool.pressed_buttons.items) |button_code| {
        resource.sendButton(serial.value, button_code, .pressed);
    }
    if (tool.tip_down) resource.sendDown(serial.value);
    resource.sendFrame(0);
}

fn handleToolRequest(
    resource: *zwp.TabletToolV2,
    request: zwp.TabletToolV2.Request,
    adapter: *ToolResource,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .set_cursor => |set| adapter.binding.manager.setToolCursor(
            adapter,
            set.serial,
            set.surface,
            set.hotspot_x,
            set.hotspot_y,
        ),
    }
}

fn handleToolDestroy(_: *zwp.TabletToolV2, adapter: *ToolResource) void {
    const manager = adapter.binding.manager;
    const binding = adapter.binding;
    const tool = adapter.tool;
    const clear_cursor = if (tool) |active_tool| adapter.active and !manager.hasOtherActiveResource(
        active_tool,
        adapter.binding.client,
        adapter,
    ) else false;
    removeAdapter(ToolResource, manager.allocator, &manager.tool_resources, adapter);
    if (clear_cursor) manager.clearToolCursor(tool.?);
    releaseBinding(binding);
}

fn createPadResource(self: *Self, binding: *SeatBinding, pad: *Pad) !void {
    const seat_resource = binding.resource orelse return;
    const resource = try zwp.TabletPadV2.create(
        binding.client,
        seat_resource.getVersion(),
        0,
    );
    errdefer resource.destroy();
    const adapter = try self.allocator.create(PadResource);
    errdefer self.allocator.destroy(adapter);
    adapter.* = .{
        .binding = binding,
        .resource = resource,
        .pad = pad,
        .active = false,
    };
    try self.pad_resources.append(self.allocator, adapter);
    retainBinding(binding);
    resource.setHandler(*PadResource, handlePadRequest, handlePadDestroy, adapter);
    seat_resource.sendPadAdded(resource);
    if (pad.path) |path| resource.sendPath(path);
    if (pad.button_count != 0) resource.sendButtons(pad.button_count);
    for (pad.groups, 0..) |group, group_index| {
        self.createPadGroupResource(adapter, @intCast(group_index), group) catch {
            resource.postNoMemory();
            return;
        };
    }
    resource.sendDone();
    if (pad.focus) |focus| self.enterPadResource(adapter, pad, focus, 0);
}

fn createPadGroupResource(
    self: *Self,
    pad_adapter: *PadResource,
    group_index: u32,
    group: PadGroup,
) !void {
    const binding = pad_adapter.binding;
    const pad = pad_adapter.pad.?;
    const resource = try zwp.TabletPadGroupV2.create(
        binding.client,
        pad_adapter.resource.getVersion(),
        0,
    );
    errdefer resource.destroy();
    const adapter = try self.allocator.create(PadGroupResource);
    errdefer self.allocator.destroy(adapter);
    adapter.* = .{
        .binding = binding,
        .resource = resource,
        .pad = pad,
        .group_index = group_index,
    };
    try self.pad_group_resources.append(self.allocator, adapter);
    retainBinding(binding);
    resource.setHandler(*PadGroupResource, handlePadGroupRequest, handlePadGroupDestroy, adapter);
    pad_adapter.resource.sendGroup(resource);
    var button_array = arrayFromU32s(group.buttons);
    resource.sendButtons(&button_array);
    for (group.rings) |index| {
        const ring = self.createPadRingResource(
            binding,
            pad,
            index,
            pad_adapter.resource.getVersion(),
        ) catch {
            resource.postNoMemory();
            return;
        };
        resource.sendRing(ring);
    }
    for (group.strips) |index| {
        const strip = self.createPadStripResource(
            binding,
            pad,
            index,
            pad_adapter.resource.getVersion(),
        ) catch {
            resource.postNoMemory();
            return;
        };
        resource.sendStrip(strip);
    }
    if (resource.getVersion() >= zwp.TabletPadGroupV2.dial_since_version) {
        for (group.dials) |index| {
            const dial = self.createPadDialResource(
                binding,
                pad,
                index,
                pad_adapter.resource.getVersion(),
            ) catch {
                resource.postNoMemory();
                return;
            };
            resource.sendDial(dial);
        }
    }
    if (group.mode_count > 1) resource.sendModes(group.mode_count);
    resource.sendDone();
}

fn createPadRingResource(
    self: *Self,
    binding: *SeatBinding,
    pad: *Pad,
    index: u32,
    version: u32,
) !*zwp.TabletPadRingV2 {
    const resource = try zwp.TabletPadRingV2.create(binding.client, version, 0);
    errdefer resource.destroy();
    const adapter = try self.allocator.create(PadRingResource);
    errdefer self.allocator.destroy(adapter);
    adapter.* = .{ .binding = binding, .resource = resource, .pad = pad, .index = index };
    try self.pad_ring_resources.append(self.allocator, adapter);
    retainBinding(binding);
    resource.setHandler(*PadRingResource, handlePadRingRequest, handlePadRingDestroy, adapter);
    return resource;
}

fn createPadStripResource(
    self: *Self,
    binding: *SeatBinding,
    pad: *Pad,
    index: u32,
    version: u32,
) !*zwp.TabletPadStripV2 {
    const resource = try zwp.TabletPadStripV2.create(binding.client, version, 0);
    errdefer resource.destroy();
    const adapter = try self.allocator.create(PadStripResource);
    errdefer self.allocator.destroy(adapter);
    adapter.* = .{ .binding = binding, .resource = resource, .pad = pad, .index = index };
    try self.pad_strip_resources.append(self.allocator, adapter);
    retainBinding(binding);
    resource.setHandler(*PadStripResource, handlePadStripRequest, handlePadStripDestroy, adapter);
    return resource;
}

fn createPadDialResource(
    self: *Self,
    binding: *SeatBinding,
    pad: *Pad,
    index: u32,
    version: u32,
) !*zwp.TabletPadDialV2 {
    const resource = try zwp.TabletPadDialV2.create(binding.client, version, 0);
    errdefer resource.destroy();
    const adapter = try self.allocator.create(PadDialResource);
    errdefer self.allocator.destroy(adapter);
    adapter.* = .{ .binding = binding, .resource = resource, .pad = pad, .index = index };
    try self.pad_dial_resources.append(self.allocator, adapter);
    retainBinding(binding);
    resource.setHandler(*PadDialResource, handlePadDialRequest, handlePadDialDestroy, adapter);
    return resource;
}

fn handlePadRequest(
    resource: *zwp.TabletPadV2,
    request: zwp.TabletPadV2.Request,
    _: *PadResource,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .set_feedback => {},
    }
}

fn handlePadDestroy(_: *zwp.TabletPadV2, adapter: *PadResource) void {
    const manager = adapter.binding.manager;
    const binding = adapter.binding;
    removeAdapter(PadResource, manager.allocator, &manager.pad_resources, adapter);
    releaseBinding(binding);
}

fn handlePadGroupRequest(
    resource: *zwp.TabletPadGroupV2,
    request: zwp.TabletPadGroupV2.Request,
    _: *PadGroupResource,
) void {
    if (request == .destroy) resource.destroy();
}

fn handlePadGroupDestroy(_: *zwp.TabletPadGroupV2, adapter: *PadGroupResource) void {
    const manager = adapter.binding.manager;
    const binding = adapter.binding;
    removeAdapter(PadGroupResource, manager.allocator, &manager.pad_group_resources, adapter);
    releaseBinding(binding);
}

fn handlePadRingRequest(
    resource: *zwp.TabletPadRingV2,
    request: zwp.TabletPadRingV2.Request,
    _: *PadRingResource,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .set_feedback => {},
    }
}

fn handlePadRingDestroy(_: *zwp.TabletPadRingV2, adapter: *PadRingResource) void {
    const manager = adapter.binding.manager;
    const binding = adapter.binding;
    removeAdapter(PadRingResource, manager.allocator, &manager.pad_ring_resources, adapter);
    releaseBinding(binding);
}

fn handlePadStripRequest(
    resource: *zwp.TabletPadStripV2,
    request: zwp.TabletPadStripV2.Request,
    _: *PadStripResource,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .set_feedback => {},
    }
}

fn handlePadStripDestroy(_: *zwp.TabletPadStripV2, adapter: *PadStripResource) void {
    const manager = adapter.binding.manager;
    const binding = adapter.binding;
    removeAdapter(PadStripResource, manager.allocator, &manager.pad_strip_resources, adapter);
    releaseBinding(binding);
}

fn handlePadDialRequest(
    resource: *zwp.TabletPadDialV2,
    request: zwp.TabletPadDialV2.Request,
    _: *PadDialResource,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .set_feedback => {},
    }
}

fn handlePadDialDestroy(_: *zwp.TabletPadDialV2, adapter: *PadDialResource) void {
    const manager = adapter.binding.manager;
    const binding = adapter.binding;
    removeAdapter(PadDialResource, manager.allocator, &manager.pad_dial_resources, adapter);
    releaseBinding(binding);
}

fn setToolCursor(
    self: *Self,
    adapter: *ToolResource,
    serial: u32,
    surface_resource: ?*wl.Surface,
    hotspot_x: i32,
    hotspot_y: i32,
) void {
    const tool = activeToolResource(adapter, serial, adapter.binding.client) orelse return;
    const cursor_surface = if (surface_resource) |resource| cursor: {
        const surface = Surface.fromResource(resource);
        if (surface.assignedRole()) |role| {
            if (role != .cursor or !ToolCursorSurface.ownedBy(surface, self, tool.cursor_owner_id)) {
                adapter.resource.postError(.role, "wl_surface is unavailable for this tablet tool cursor");
                return;
            }
        } else {
            ToolCursorSurface.create(self, surface, tool.cursor_owner_id) catch |err| switch (err) {
                error.OutOfMemory => {
                    adapter.resource.postNoMemory();
                    return;
                },
                error.RoleUnavailable => {
                    adapter.resource.postError(.role, "wl_surface is unavailable for this tablet tool cursor");
                    return;
                },
            };
        }
        break :cursor surface;
    } else null;

    tool.cursor = if (cursor_surface) |surface| .{ .surface = .{
        .surface_id = surface.handle(),
        .hotspot_x = hotspot_x,
        .hotspot_y = hotspot_y,
    } } else null;
    self.requestRepaint();
}

fn setToolCursorShape(
    self: *Self,
    generation: u64,
    client: *wl.Client,
    serial: u32,
    shape: Seat.ShapeCursor,
) void {
    std.debug.assert(shape.client == client);
    for (self.tool_resources.items) |adapter| {
        if (adapter.generation != generation) continue;
        const tool = activeToolResource(adapter, serial, client) orelse return;
        tool.cursor = .{ .shape = shape };
        self.requestRepaint();
        return;
    }
}

fn activeToolResource(
    adapter: *ToolResource,
    serial: u32,
    client: *wl.Client,
) ?*Tool {
    if (!adapter.active or adapter.binding.client != client or
        adapter.proximity_serial == null or
        !std.meta.eql(adapter.proximity_serial.?, matureSerial(serial))) return null;
    const tool = adapter.tool orelse return null;
    const surface = tool.focus_resource orelse return null;
    if (!tool.in_proximity or surface.getClient() != client) return null;
    return tool;
}

fn copyPadGroup(self: *Self, info: NativeInput.TabletPadGroupInfo) !PadGroup {
    const buttons = try self.allocator.dupe(u32, info.buttons);
    errdefer self.allocator.free(buttons);
    const rings = try self.allocator.dupe(u32, info.rings);
    errdefer self.allocator.free(rings);
    const strips = try self.allocator.dupe(u32, info.strips);
    errdefer self.allocator.free(strips);
    const dials = try self.allocator.dupe(u32, info.dials);
    errdefer self.allocator.free(dials);
    return .{
        .buttons = buttons,
        .rings = rings,
        .strips = strips,
        .dials = dials,
        .mode_count = info.mode_count,
        .current_mode = info.current_mode,
    };
}

fn deinitPadGroup(self: *Self, group: PadGroup) void {
    self.allocator.free(group.dials);
    self.allocator.free(group.strips);
    self.allocator.free(group.rings);
    self.allocator.free(group.buttons);
}

fn refreshPadsForSeat(self: *Self, seat: *Seat, time: u32) void {
    for (self.pad_devices.items) |pad| {
        if (pad.seat == seat) self.refreshPadFocus(pad, time);
    }
}

fn refreshPadFocus(self: *Self, pad: *Pad, time: u32) void {
    self.refreshPadFocusExcluding(pad, time, null);
}

fn refreshPadFocusExcluding(
    self: *Self,
    pad: *Pad,
    time: u32,
    excluded_surface: ?Surface.Id,
) void {
    const linked = self.hasLinkedTablet(pad);
    var candidate: ?*Tool = null;
    for (self.tools.items) |tool| {
        if (!tool.in_proximity or tool.focus_resource == null or tool.device.seat != pad.seat) continue;
        if (excluded_surface) |surface_id| {
            if (std.meta.eql(tool.focus.?, surface_id)) continue;
        }
        if (linked and tool.device.physical_id != pad.physical_id) continue;
        if (candidate == null or tool.focus_generation > candidate.?.focus_generation) candidate = tool;
    }
    if (candidate) |tool| {
        const surface_id = tool.focus.?;
        if (pad.focus) |focus| {
            if (focus.tablet_id == tool.device.id and std.meta.eql(focus.surface_id, surface_id)) return;
            self.leavePadFocus(pad);
        }
        self.enterPadFocus(pad, tool.device, tool.focus_resource.?, time);
    } else if (pad.focus != null) {
        self.leavePadFocus(pad);
    }
}

fn hasLinkedTablet(self: *const Self, pad: *const Pad) bool {
    for (self.devices.items) |device| {
        if (device.seat == pad.seat and device.physical_id == pad.physical_id) return true;
    }
    return false;
}

fn enterPadFocus(self: *Self, pad: *Pad, tablet: *Device, surface: *wl.Surface, time: u32) void {
    std.debug.assert(pad.focus == null);
    pad.focus = .{
        .tablet_id = tablet.id,
        .surface_id = Surface.fromResource(surface).handle(),
        .resource = surface,
    };
    @as(*wl.Resource, @ptrCast(surface)).addDestroyListener(&pad.focus_destroy_listener);
    const focus = pad.focus.?;
    for (self.pad_resources.items) |adapter| self.enterPadResource(adapter, pad, focus, time);
}

fn enterPadResource(
    self: *Self,
    adapter: *PadResource,
    pad: *Pad,
    focus: PadFocus,
    time: u32,
) void {
    if (adapter.pad != pad or adapter.binding.client != focus.resource.getClient()) return;
    const tablet = self.findDevice(focus.tablet_id) orelse return;
    const tablet_adapter = self.tabletResource(adapter.binding, tablet) orelse return;
    const serial = self.display.nextSerial();
    adapter.active = true;
    adapter.resource.sendEnter(serial, tablet_adapter.resource, focus.resource);
    for (self.pad_group_resources.items) |group_adapter| {
        if (group_adapter.pad != pad or group_adapter.binding != adapter.binding) continue;
        const group_index: usize = @intCast(group_adapter.group_index);
        if (group_index >= pad.groups.len) continue;
        group_adapter.resource.sendModeSwitch(
            time,
            serial,
            pad.groups[group_index].current_mode,
        );
    }
}

fn leavePadFocus(self: *Self, pad: *Pad) void {
    const focus = pad.focus orelse return;
    const serial = self.display.nextSerial();
    for (self.pad_resources.items) |adapter| {
        if (adapter.pad != pad or !adapter.active) continue;
        adapter.resource.sendLeave(serial, focus.resource);
        adapter.active = false;
    }
    pad.focus_destroy_listener.link.remove();
    pad.focus = null;
}

fn handlePadFocusDestroyed(listener: *wl.Listener(*wl.Resource), _: *wl.Resource) void {
    const pad: *Pad = @fieldParentPtr("focus_destroy_listener", listener);
    const surface_id = pad.focus.?.surface_id;
    listener.link.remove();
    pad.focus = null;
    for (pad.manager.pad_resources.items) |adapter| {
        if (adapter.pad == pad) adapter.active = false;
    }
    pad.manager.refreshPadFocusExcluding(pad, 0, surface_id);
}

fn updatePadMode(self: *Self, pad: *Pad, time: u32, group_index: u32, mode: u32) void {
    if (group_index >= pad.groups.len) return;
    const group = &pad.groups[group_index];
    if (mode >= group.mode_count or mode == group.current_mode) return;
    group.current_mode = mode;
    if (pad.focus == null) return;
    const serial = self.display.nextSerial();
    for (self.pad_group_resources.items) |adapter| {
        if (adapter.pad == pad and adapter.group_index == group_index and
            self.padBindingActive(adapter.binding, pad))
        {
            adapter.resource.sendModeSwitch(time, serial, mode);
        }
    }
}

fn padBindingActive(self: *const Self, binding: *SeatBinding, pad: *Pad) bool {
    for (self.pad_resources.items) |adapter| {
        if (adapter.binding == binding and adapter.pad == pad) return adapter.active;
    }
    return false;
}

fn hasOtherActiveResource(
    self: *const Self,
    tool: *Tool,
    client: *wl.Client,
    ignored: *ToolResource,
) bool {
    for (self.tool_resources.items) |adapter| {
        if (adapter != ignored and adapter.tool == tool and adapter.active and
            adapter.binding.client == client) return true;
    }
    return false;
}

fn ensureTool(
    self: *Self,
    device: *Device,
    info: NativeInput.TabletToolInfo,
) !*Tool {
    if (self.findTool(device.id, info.id)) |tool| return tool;
    const tool = try self.allocator.create(Tool);
    errdefer self.allocator.destroy(tool);
    tool.* = .{
        .manager = self,
        .cursor_owner_id = self.next_tool_cursor_owner_id,
        .focus_generation = 0,
        .info = info,
        .device = device,
        .in_proximity = false,
        .focus = null,
        .focus_resource = null,
        .focus_destroy_listener = wl.Listener(*wl.Resource).init(handleFocusDestroyed),
        .tip_down = false,
        .pressed_buttons = .empty,
        .position = null,
        .cursor = null,
    };
    self.next_tool_cursor_owner_id = std.math.add(
        u64,
        self.next_tool_cursor_owner_id,
        1,
    ) catch unreachable;
    errdefer tool.pressed_buttons.deinit(self.allocator);
    try self.tools.append(self.allocator, tool);
    for (self.seat_bindings.items) |binding| {
        if (binding.resource != null and binding.seat == device.seat) {
            self.createToolResource(binding, tool) catch binding.resource.?.postNoMemory();
        }
    }
    return tool;
}

fn updateFocus(self: *Self, tool: *Tool, target: ?Seat.PointerFocus, time: u32) void {
    const next = if (target) |focus| focus.surface_id else null;
    if (tool.focus) |current| {
        if (next != null and std.meta.eql(current, next.?)) return;
        if (tool.tip_down or tool.pressed_buttons.items.len != 0) return;
        self.leaveFocus(tool, time, false);
    } else if (next == null) return;
    const focus = target orelse return;
    const surface = Surface.resourceFor(self.surface_store, focus.surface_id) orelse return;
    tool.focus = focus.surface_id;
    tool.focus_resource = surface;
    tool.focus_generation = self.next_tool_focus_generation;
    self.next_tool_focus_generation = std.math.add(
        u64,
        self.next_tool_focus_generation,
        1,
    ) catch unreachable;
    @as(*wl.Resource, @ptrCast(surface)).addDestroyListener(&tool.focus_destroy_listener);
    const serial = matureSerial(self.display.nextSerial());
    for (self.tool_resources.items) |adapter| {
        if (adapter.tool != tool or adapter.binding.client != surface.getClient()) continue;
        const tablet = self.tabletResource(adapter.binding, tool.device) orelse continue;
        adapter.active = true;
        adapter.proximity_serial = serial;
        adapter.resource.sendProximityIn(serial.value, tablet.resource, surface);
        for (tool.pressed_buttons.items) |button_code| {
            adapter.resource.sendButton(serial.value, button_code, .pressed);
        }
        if (tool.tip_down) adapter.resource.sendDown(serial.value);
    }
    self.refreshPadsForSeat(tool.device.seat, time);
}

fn leaveFocus(self: *Self, tool: *Tool, time: u32, release_state: bool) void {
    if (tool.focus == null) {
        tool.position = null;
        self.clearToolCursor(tool);
        tool.focus_generation = 0;
        self.refreshPadsForSeat(tool.device.seat, time);
        if (release_state) self.clearToolState(tool);
        return;
    }
    if (release_state) {
        const serial = self.display.nextSerial();
        for (self.tool_resources.items) |adapter| {
            if (adapter.tool != tool or !adapter.active) continue;
            for (tool.pressed_buttons.items) |button_code| {
                adapter.resource.sendButton(serial, button_code, .released);
            }
            if (tool.tip_down) adapter.resource.sendUp();
        }
    }
    for (self.tool_resources.items) |adapter| {
        if (adapter.tool != tool or !adapter.active) continue;
        adapter.resource.sendProximityOut();
        adapter.resource.sendFrame(time);
        adapter.active = false;
        adapter.proximity_serial = null;
    }
    tool.focus_destroy_listener.link.remove();
    tool.focus = null;
    tool.focus_resource = null;
    tool.focus_generation = 0;
    tool.position = null;
    self.clearToolCursor(tool);
    self.refreshPadsForSeat(tool.device.seat, time);
    if (release_state) self.clearToolState(tool);
}

fn clearToolState(self: *Self, tool: *Tool) void {
    tool.tip_down = false;
    tool.pressed_buttons.clearRetainingCapacity();
    _ = self;
}

fn clearToolCursor(self: *Self, tool: *Tool) void {
    if (tool.cursor == null) return;
    tool.cursor = null;
    self.requestRepaint();
}

fn requestRepaint(self: *Self) void {
    self.listener.repaint(self.listener.context);
}

fn sendAxes(
    self: *Self,
    tool: *Tool,
    target: ?Seat.PointerFocus,
    axes: NativeInput.TabletToolAxes,
) void {
    if (axes.position) |position| {
        tool.position = .{ .x = position.x, .y = position.y };
        if (tool.cursor != null) self.requestRepaint();
    }
    const motion = if (axes.position) |position| blk: {
        const focus = tool.focus orelse break :blk null;
        if (target) |candidate| {
            if (std.meta.eql(candidate.surface_id, focus)) {
                break :blk Point{ .x = candidate.x, .y = candidate.y };
            }
        }
        break :blk self.listener.surface_coordinates(
            self.listener.context,
            focus,
            position.x,
            position.y,
        );
    } else null;
    for (self.tool_resources.items) |adapter| {
        if (adapter.tool != tool or !adapter.active) continue;
        if (motion) |position| {
            adapter.resource.sendMotion(fixed(position.x), fixed(position.y));
        }
        if (axes.pressure) |value| adapter.resource.sendPressure(normalizedUnsigned(value));
        if (axes.distance) |value| adapter.resource.sendDistance(normalizedUnsigned(value));
        if (axes.tilt) |value| adapter.resource.sendTilt(fixed(value.x), fixed(value.y));
        if (axes.rotation) |value| adapter.resource.sendRotation(fixed(value));
        if (axes.slider) |value| adapter.resource.sendSlider(normalizedSigned(value));
        if (axes.wheel) |value| adapter.resource.sendWheel(fixed(value.degrees), value.clicks);
    }
}

fn sendFrame(self: *Self, tool: *Tool, time: u32) void {
    for (self.tool_resources.items) |adapter| {
        if (adapter.tool == tool and adapter.active) adapter.resource.sendFrame(time);
    }
}

fn unadvertiseDevice(self: *Self, device: *Device, destroy_tools: bool) void {
    var tool_index = self.tools.items.len;
    while (tool_index > 0) {
        tool_index -= 1;
        const tool = self.tools.items[tool_index];
        if (tool.device != device) continue;
        self.unadvertiseTool(tool, destroy_tools);
        if (destroy_tools) {
            _ = self.tools.orderedRemove(tool_index);
            self.destroyTool(tool);
        }
    }
    for (self.tablet_resources.items) |adapter| {
        if (adapter.device != device) continue;
        adapter.resource.sendRemoved();
        adapter.device = null;
    }
}

fn unadvertiseTool(self: *Self, tool: *Tool, removed: bool) void {
    if (removed) tool.in_proximity = false;
    self.leaveFocus(tool, 0, true);
    for (self.tool_resources.items) |adapter| {
        if (adapter.tool != tool) continue;
        adapter.resource.sendRemoved();
        adapter.tool = null;
        adapter.active = false;
        adapter.proximity_serial = null;
    }
}

fn unadvertisePad(self: *Self, pad: *Pad) void {
    self.leavePadFocus(pad);
    for (self.pad_resources.items) |adapter| {
        if (adapter.pad != pad) continue;
        adapter.resource.sendRemoved();
        adapter.pad = null;
        adapter.active = false;
    }
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
}

fn handleFocusDestroyed(listener: *wl.Listener(*wl.Resource), _: *wl.Resource) void {
    const tool: *Tool = @fieldParentPtr("focus_destroy_listener", listener);
    listener.link.remove();
    tool.focus = null;
    tool.focus_resource = null;
    tool.focus_generation = 0;
    const serial = tool.manager.display.nextSerial();
    for (tool.manager.tool_resources.items) |adapter| {
        if (adapter.tool != tool or !adapter.active) continue;
        for (tool.pressed_buttons.items) |button_code| {
            adapter.resource.sendButton(serial, button_code, .released);
        }
        if (tool.tip_down) adapter.resource.sendUp();
        adapter.resource.sendProximityOut();
        adapter.resource.sendFrame(0);
        adapter.active = false;
        adapter.proximity_serial = null;
    }
    tool.position = null;
    tool.manager.clearToolCursor(tool);
    tool.manager.clearToolState(tool);
}

fn tabletResource(self: *Self, binding: *SeatBinding, device: *Device) ?*TabletResource {
    for (self.tablet_resources.items) |adapter| {
        if (adapter.binding == binding and adapter.device == device) return adapter;
    }
    return null;
}

fn findDevice(self: *Self, id: NativeInput.DeviceId) ?*Device {
    for (self.devices.items) |device| if (device.id == id) return device;
    return null;
}

fn findPad(self: *const Self, id: NativeInput.DeviceId) ?*Pad {
    for (self.pad_devices.items) |pad| {
        if (pad.id == id) return pad;
    }
    return null;
}

fn findTool(
    self: *const Self,
    device_id: NativeInput.DeviceId,
    tool_id: NativeInput.TabletToolId,
) ?*Tool {
    for (self.tools.items) |tool| {
        if (tool.device.id == device_id and tool.info.id == tool_id) return tool;
    }
    return null;
}

fn findToolByCursorOwner(self: *const Self, owner_id: u64) ?*Tool {
    for (self.tools.items) |tool| {
        if (tool.cursor_owner_id == owner_id) return tool;
    }
    return null;
}

fn destroyTool(self: *Self, tool: *Tool) void {
    self.clearToolCursor(tool);
    if (tool.focus_resource != null) tool.focus_destroy_listener.link.remove();
    tool.pressed_buttons.deinit(self.allocator);
    self.allocator.destroy(tool);
}

fn destroyPad(self: *Self, pad: *Pad) void {
    if (pad.focus != null) pad.focus_destroy_listener.link.remove();
    for (pad.groups) |group| self.deinitPadGroup(group);
    self.allocator.free(pad.groups);
    if (pad.path) |path| self.allocator.free(path);
    self.allocator.destroy(pad);
}

fn destroyDevice(self: *Self, device: *Device) void {
    if (device.path) |path| self.allocator.free(path);
    self.allocator.free(device.name);
    self.allocator.destroy(device);
}

const ToolCursorSurface = struct {
    manager: *Self,
    surface_id: Surface.Id,
    owner_id: u64,

    fn create(
        manager: *Self,
        surface: *Surface,
        owner_id: u64,
    ) error{ OutOfMemory, RoleUnavailable }!void {
        const self = manager.allocator.create(ToolCursorSurface) catch return error.OutOfMemory;
        errdefer manager.allocator.destroy(self);
        self.* = .{
            .manager = manager,
            .surface_id = surface.handle(),
            .owner_id = owner_id,
        };
        surface.reserveRole(.cursor, .{
            .context = self,
            .before_commit = beforeCommit,
            .after_commit = afterCommit,
            .surface_destroyed = surfaceDestroyed,
            .role_tag = .tablet_tool_cursor,
        }) catch return error.RoleUnavailable;
        errdefer surface.releaseRole(self);
        surface.assignReservedRole(.cursor, self) catch return error.RoleUnavailable;
        manager.cursor_surface_count += 1;
    }

    fn ownedBy(surface: *Surface, manager: *Self, owner_id: u64) bool {
        const identity = surface.roleIdentity(.cursor) orelse return false;
        if (identity.tag != .tablet_tool_cursor) return false;
        const cursor_surface: *ToolCursorSurface = @ptrCast(@alignCast(identity.context));
        return cursor_surface.manager == manager and cursor_surface.owner_id == owner_id;
    }

    fn beforeCommit(_: *anyopaque, _: Surface.CommitInfo) Surface.CommitAction {
        return .apply;
    }

    fn afterCommit(context: *anyopaque, info: Surface.CommitInfo) void {
        const self: *ToolCursorSurface = @ptrCast(@alignCast(context));
        const tool = self.manager.findToolByCursorOwner(self.owner_id) orelse return;
        if (tool.cursor) |*cursor| switch (cursor.*) {
            .shape => {},
            .surface => |*surface| if (std.meta.eql(surface.surface_id, self.surface_id)) {
                surface.hotspot_x -|= info.offset_x;
                surface.hotspot_y -|= info.offset_y;
                self.manager.requestRepaint();
            },
        };
    }

    fn surfaceDestroyed(context: *anyopaque) void {
        const self: *ToolCursorSurface = @ptrCast(@alignCast(context));
        const manager = self.manager;
        if (manager.findToolByCursorOwner(self.owner_id)) |tool| {
            const cursor = tool.cursor;
            if (cursor != null) switch (cursor.?) {
                .shape => {},
                .surface => |surface| if (std.meta.eql(surface.surface_id, self.surface_id)) {
                    manager.clearToolCursor(tool);
                },
            };
        }
        std.debug.assert(manager.cursor_surface_count > 0);
        manager.cursor_surface_count -= 1;
        manager.allocator.destroy(self);
    }
};

fn retainBinding(binding: *SeatBinding) void {
    binding.references = std.math.add(usize, binding.references, 1) catch unreachable;
}

fn releaseBinding(binding: *SeatBinding) void {
    std.debug.assert(binding.references > 0);
    binding.references -= 1;
    if (binding.references != 0) return;
    const manager = binding.manager;
    std.debug.assert(binding.resource == null);
    for (manager.seat_bindings.items, 0..) |candidate, index| {
        if (candidate != binding) continue;
        _ = manager.seat_bindings.orderedRemove(index);
        manager.allocator.destroy(binding);
        return;
    }
    unreachable;
}

fn removeAdapter(
    comptime Adapter: type,
    allocator: std.mem.Allocator,
    adapters: *std.ArrayList(*Adapter),
    adapter: *Adapter,
) void {
    for (adapters.items, 0..) |candidate, index| {
        if (candidate != adapter) continue;
        _ = adapters.orderedRemove(index);
        allocator.destroy(adapter);
        return;
    }
    unreachable;
}

fn high(value: u64) u32 {
    return @truncate(value >> 32);
}

fn low(value: u64) u32 {
    return @truncate(value);
}

fn matureSerial(value: u32) ClientRegistry.Serial {
    return .{ .domain = .mature_display, .value = value };
}

fn normalizedUnsigned(value: f64) u32 {
    if (!std.math.isFinite(value)) return 0;
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * 65535));
}

fn normalizedSigned(value: f64) i32 {
    if (!std.math.isFinite(value)) return 0;
    return @intFromFloat(@round(std.math.clamp(value, -1, 1) * 65535));
}

fn protocolBustype(value: u32) ?zwp.TabletV2.Bustype {
    return switch (value) {
        3 => .usb,
        5 => .bluetooth,
        6 => .virtual,
        17 => .serial,
        24 => .i2c,
        else => null,
    };
}

fn fixed(value: f64) wl.Fixed {
    if (!std.math.isFinite(value)) return wl.Fixed.fromInt(0);
    const minimum = @as(f64, @floatFromInt(std.math.minInt(i32))) / 256.0;
    const maximum = @as(f64, @floatFromInt(std.math.maxInt(i32))) / 256.0;
    return wl.Fixed.fromDouble(std.math.clamp(value, minimum, maximum));
}

fn arrayFromU32s(values: []const u32) wl.Array {
    return .{
        .size = values.len * @sizeOf(u32),
        .alloc = values.len * @sizeOf(u32),
        .data = if (values.len == 0) null else @ptrCast(@constCast(values.ptr)),
    };
}

test "tablet axes normalize protocol values" {
    try std.testing.expectEqual(0, normalizedUnsigned(-1));
    try std.testing.expectEqual(65535, normalizedUnsigned(2));
    try std.testing.expectEqual(-65535, normalizedSigned(-2));
    try std.testing.expectEqual(65535, normalizedSigned(2));
}
