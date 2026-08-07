//! Privileged virtual keyboard input for input methods and automation clients.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const SecurityContext = @import("security_context.zig");
const Seat = @import("seat.zig");
const TransientSeat = @import("transient_seat.zig");

const wl = wayland.server.wl;
const zwp = wayland.server.zwp;

allocator: std.mem.Allocator,
io: std.Io,
global: *wl.Global,
security_context: *SecurityContext,
seat: *Seat,
transient_seat: *TransientSeat,
devices: std.ArrayList(*Device),
inhibited: bool,

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    io: std.Io,
    display: *wl.Server,
    security_context: *SecurityContext,
    seat: *Seat,
    transient_seat: *TransientSeat,
) !void {
    self.* = .{
        .allocator = allocator,
        .io = io,
        .global = try wl.Global.create(
            display,
            zwp.VirtualKeyboardManagerV1,
            1,
            *Self,
            self,
            bind,
        ),
        .security_context = security_context,
        .seat = seat,
        .transient_seat = transient_seat,
        .devices = .empty,
        .inhibited = false,
    };
    errdefer self.global.destroy();
    try security_context.restrictGlobal(self.global);
    errdefer security_context.unrestrictGlobal(self.global);
    try transient_seat.addSeatListener(.{
        .context = self,
        .removed = transientSeatRemoved,
    });
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.devices.items.len == 0);
    self.transient_seat.removeSeatListener(self);
    self.security_context.unrestrictGlobal(self.global);
    self.global.destroy();
    self.devices.deinit(self.allocator);
    self.* = undefined;
}

pub fn setInhibited(self: *Self, inhibited: bool) void {
    if (self.inhibited == inhibited) return;
    self.inhibited = inhibited;
    self.seat.setVirtualKeyboardsInhibited(inhibited);
    for (self.devices.items) |device| {
        const target = device.seat orelse continue;
        if (target != self.seat) target.setVirtualKeyboardsInhibited(inhibited);
    }
}

fn transientSeatRemoved(context: *anyopaque, seat: *Seat) void {
    const self: *Self = @ptrCast(@alignCast(context));
    for (self.devices.items) |device| {
        if (device.seat == seat) device.deactivate();
    }
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = zwp.VirtualKeyboardManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleManagerRequest, null, self);
}

fn handleManagerRequest(
    resource: *zwp.VirtualKeyboardManagerV1,
    request: zwp.VirtualKeyboardManagerV1.Request,
    self: *Self,
) void {
    switch (request) {
        .create_virtual_keyboard => |create| {
            const seat = if (self.seat.ownsResource(create.seat))
                self.seat
            else
                self.transient_seat.seatForResource(create.seat);
            Device.create(
                self,
                resource,
                create.id,
                seat,
            ) catch resource.postNoMemory();
        },
    }
}

const Device = struct {
    manager: *Self,
    resource: *zwp.VirtualKeyboardV1,
    active: bool,
    seat: ?*Seat,
    retained_transient_seat: bool,

    fn create(
        manager: *Self,
        manager_resource: *zwp.VirtualKeyboardManagerV1,
        id: u32,
        seat: ?*Seat,
    ) !void {
        const resource = try zwp.VirtualKeyboardV1.create(
            manager_resource.getClient(),
            manager_resource.getVersion(),
            id,
        );
        errdefer resource.destroy();
        const self = try manager.allocator.create(Device);
        errdefer manager.allocator.destroy(self);
        const retained_transient_seat = if (seat) |target|
            target != manager.seat and manager.transient_seat.retainSeat(target)
        else
            false;
        errdefer if (retained_transient_seat) manager.transient_seat.releaseSeat(seat.?);
        if (seat) |target| {
            std.debug.assert(target == manager.seat or retained_transient_seat);
        }
        self.* = .{
            .manager = manager,
            .resource = resource,
            .active = seat != null,
            .seat = seat,
            .retained_transient_seat = retained_transient_seat,
        };
        if (seat) |target| {
            try target.createVirtualKeyboard(self);
            target.setVirtualKeyboardsInhibited(manager.inhibited);
        }
        errdefer if (seat) |target| target.destroyVirtualKeyboard(self);
        try manager.devices.append(manager.allocator, self);
        resource.setHandler(*Device, handleRequest, handleDestroy, self);
    }

    fn handleRequest(
        resource: *zwp.VirtualKeyboardV1,
        request: zwp.VirtualKeyboardV1.Request,
        self: *Device,
    ) void {
        if (!self.active) {
            switch (request) {
                .destroy => resource.destroy(),
                .keymap => |keymap| {
                    const file: std.Io.File = .{
                        .handle = keymap.fd,
                        .flags = .{ .nonblocking = false },
                    };
                    file.close(self.manager.io);
                },
                .key, .modifiers => {},
            }
            return;
        }
        switch (request) {
            .destroy => resource.destroy(),
            .keymap => |keymap| self.setKeymap(resource, keymap.format, keymap.fd, keymap.size),
            .key => |key| self.sendKey(resource, key.time, key.key, key.state),
            .modifiers => |modifiers| {
                if (!self.requireKeymap(resource)) return;
                self.seat.?.setVirtualModifiers(
                    self,
                    modifiers.mods_depressed,
                    modifiers.mods_latched,
                    modifiers.mods_locked,
                    modifiers.group,
                );
            },
        }
    }

    fn setKeymap(
        self: *Device,
        resource: *zwp.VirtualKeyboardV1,
        format: wl.Keyboard.KeymapFormat,
        fd: std.posix.fd_t,
        size: u32,
    ) void {
        const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
        if (format != .xkb_v1) {
            file.close(self.manager.io);
            resource.postError(.invalid_keymap_format, "unsupported virtual keyboard keymap format");
            return;
        }
        self.seat.?.setVirtualKeyboardKeymap(self, fd, size) catch {
            resource.getClient().postImplementationError("invalid virtual keyboard keymap");
            return;
        };
    }

    fn sendKey(
        self: *Device,
        resource: *zwp.VirtualKeyboardV1,
        time: u32,
        key_code: u32,
        state_value: u32,
    ) void {
        if (!self.requireKeymap(resource)) return;
        const state: wl.Keyboard.KeyState = switch (state_value) {
            @intFromEnum(wl.Keyboard.KeyState.released) => .released,
            @intFromEnum(wl.Keyboard.KeyState.pressed) => .pressed,
            else => {
                resource.getClient().postImplementationError("invalid virtual keyboard key state");
                return;
            },
        };
        self.seat.?.virtualKey(self, time, key_code, state) catch resource.postNoMemory();
    }

    fn requireKeymap(self: *const Device, resource: *zwp.VirtualKeyboardV1) bool {
        if (self.seat.?.virtualKeyboardHasKeymap(@constCast(self))) return true;
        resource.postError(.no_keymap, "virtual keyboard has no keymap");
        return false;
    }

    fn deactivate(self: *Device) void {
        if (!self.active) return;
        const seat = self.seat orelse unreachable;
        seat.destroyVirtualKeyboard(self);
        self.active = false;
        self.seat = null;
        if (self.retained_transient_seat) {
            self.retained_transient_seat = false;
            self.manager.transient_seat.releaseSeat(seat);
        }
    }

    fn handleDestroy(_: *zwp.VirtualKeyboardV1, self: *Device) void {
        self.deactivate();
        for (self.manager.devices.items, 0..) |device, index| {
            if (device != self) continue;
            _ = self.manager.devices.orderedRemove(index);
            self.manager.allocator.destroy(self);
            return;
        }
        unreachable;
    }
};
