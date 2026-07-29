//! Privileged virtual keyboard input for input methods and automation clients.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const SecurityContext = @import("security_context.zig");
const Seat = @import("seat.zig");
const TransientSeat = @import("transient_seat.zig");

const wl = wayland.server.wl;
const zwp = wayland.server.zwp;

const maximum_keymap_size = 16 * 1024 * 1024;

allocator: std.mem.Allocator,
io: std.Io,
global: *wl.Global,
security_context: *SecurityContext,
seat: *Seat,
transient_seat: *TransientSeat,
devices: std.ArrayList(*Device),
inhibited: bool,

const DeferredKeymap = struct {
    fd: std.posix.fd_t,
    size: u32,
};

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
    if (!inhibited) {
        for (self.devices.items) |device| device.applyDeferredKeymap();
        return;
    }
    for (self.devices.items) |device| {
        device.releasePressedKeys();
        device.clearModifiers();
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
    has_keymap: bool,
    registered: bool,
    deferred_keymap: ?DeferredKeymap,
    pressed_keys: std.ArrayList(u32),

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
            .has_keymap = false,
            .registered = false,
            .deferred_keymap = null,
            .pressed_keys = .empty,
        };
        errdefer self.pressed_keys.deinit(manager.allocator);
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
                if (self.manager.inhibited) return;
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
        if (!validKeymap(self.manager.io, file, size)) {
            file.close(self.manager.io);
            resource.getClient().postImplementationError("invalid virtual keyboard keymap");
            return;
        }
        if (self.manager.inhibited) {
            self.closeDeferredKeymap();
            self.deferred_keymap = .{ .fd = fd, .size = size };
        } else {
            self.seat.?.setKeymap(.xkb_v1, fd, size);
        }
        self.has_keymap = true;
        if (!self.registered) {
            self.registered = true;
            self.seat.?.addVirtualKeyboard();
        }
    }

    fn sendKey(
        self: *Device,
        resource: *zwp.VirtualKeyboardV1,
        time: u32,
        key_code: u32,
        state_value: u32,
    ) void {
        if (!self.requireKeymap(resource)) return;
        if (self.manager.inhibited) return;
        const state: wl.Keyboard.KeyState = switch (state_value) {
            @intFromEnum(wl.Keyboard.KeyState.released) => .released,
            @intFromEnum(wl.Keyboard.KeyState.pressed) => .pressed,
            else => {
                resource.getClient().postImplementationError("invalid virtual keyboard key state");
                return;
            },
        };
        switch (state) {
            .pressed => {
                for (self.pressed_keys.items) |pressed| if (pressed == key_code) return;
                self.pressed_keys.append(self.manager.allocator, key_code) catch {
                    resource.postNoMemory();
                    return;
                };
                self.seat.?.virtualKey(time, key_code, state) catch {
                    _ = self.pressed_keys.pop();
                    resource.postNoMemory();
                };
            },
            .released => {
                for (self.pressed_keys.items, 0..) |pressed, index| {
                    if (pressed != key_code) continue;
                    _ = self.pressed_keys.orderedRemove(index);
                    self.seat.?.virtualKey(time, key_code, state) catch unreachable;
                    return;
                }
            },
            else => unreachable,
        }
    }

    fn requireKeymap(self: *const Device, resource: *zwp.VirtualKeyboardV1) bool {
        if (self.has_keymap) return true;
        resource.postError(.no_keymap, "virtual keyboard has no keymap");
        return false;
    }

    fn applyDeferredKeymap(self: *Device) void {
        const keymap = self.deferred_keymap orelse return;
        self.deferred_keymap = null;
        if (self.active) {
            self.seat.?.setKeymap(.xkb_v1, keymap.fd, keymap.size);
        } else {
            closeKeymap(self.manager.io, keymap);
        }
    }

    fn closeDeferredKeymap(self: *Device) void {
        const keymap = self.deferred_keymap orelse return;
        self.deferred_keymap = null;
        closeKeymap(self.manager.io, keymap);
    }

    fn releasePressedKeys(self: *Device) void {
        const seat = self.seat orelse {
            self.pressed_keys.clearRetainingCapacity();
            return;
        };
        while (self.pressed_keys.pop()) |key_code| {
            seat.virtualKey(0, key_code, .released) catch unreachable;
        }
    }

    fn clearModifiers(self: *Device) void {
        const seat = self.seat orelse return;
        seat.clearVirtualModifiers(self);
    }

    fn deactivate(self: *Device) void {
        if (!self.active) return;
        const seat = self.seat orelse unreachable;
        self.releasePressedKeys();
        self.clearModifiers();
        if (self.registered) {
            seat.removeVirtualKeyboard();
            self.registered = false;
        }
        self.closeDeferredKeymap();
        self.active = false;
        self.seat = null;
        if (self.retained_transient_seat) {
            self.retained_transient_seat = false;
            self.manager.transient_seat.releaseSeat(seat);
        }
    }

    fn handleDestroy(_: *zwp.VirtualKeyboardV1, self: *Device) void {
        self.deactivate();
        self.closeDeferredKeymap();
        for (self.manager.devices.items, 0..) |device, index| {
            if (device != self) continue;
            _ = self.manager.devices.orderedRemove(index);
            self.pressed_keys.deinit(self.manager.allocator);
            self.manager.allocator.destroy(self);
            return;
        }
        unreachable;
    }
};

fn closeKeymap(io: std.Io, keymap: DeferredKeymap) void {
    const file: std.Io.File = .{ .handle = keymap.fd, .flags = .{ .nonblocking = false } };
    file.close(io);
}

fn validKeymap(io: std.Io, file: std.Io.File, size: u32) bool {
    if (size == 0 or size > maximum_keymap_size) return false;
    const stat = file.stat(io) catch return false;
    if (stat.size < size) return false;
    var terminator: [1]u8 = undefined;
    const read = file.readPositionalAll(io, &terminator, size - 1) catch return false;
    return read == 1 and terminator[0] == 0;
}
