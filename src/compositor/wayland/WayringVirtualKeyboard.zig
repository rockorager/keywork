//! Generated privileged virtual-keyboard protocol adapter.
//!
//! This owns wire resources and identities only. Seat owns keymap validation,
//! per-device pressed state, modifiers, focus, serials, and lock inhibition.

const WayringVirtualKeyboard = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayland = @import("wayland");
const wayring = @import("wayring");
const Seat = @import("seat.zig");
const WayringSeatAdapter = @import("WayringSeatAdapter.zig");

const wl = wayland.server.wl;

const Manager = struct {
    owner: *WayringVirtualKeyboard,
    client: *wayring.server.Client,
    resource: protocol.zwp_virtual_keyboard_manager_v1.Resource,
};

const Device = struct {
    owner: *WayringVirtualKeyboard,
    client: *wayring.server.Client,
    resource: protocol.zwp_virtual_keyboard_v1.Resource,
};

allocator: std.mem.Allocator,
protocol_server: *wayring.server.Server,
seat_adapter: *WayringSeatAdapter,
seat: *Seat,
authorized_uid: std.os.linux.uid_t,
global: ?*const wayring.server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
devices: std.ArrayList(*Device) = .empty,

pub fn init(
    self: *WayringVirtualKeyboard,
    allocator: std.mem.Allocator,
    protocol_server: *wayring.server.Server,
    seat_adapter: *WayringSeatAdapter,
    seat: *Seat,
    authorized_uid: std.os.linux.uid_t,
) void {
    self.* = .{
        .allocator = allocator,
        .protocol_server = protocol_server,
        .seat_adapter = seat_adapter,
        .seat = seat,
        .authorized_uid = authorized_uid,
    };
}

pub fn deinit(self: *WayringVirtualKeyboard) void {
    std.debug.assert(self.global == null and self.managers.items.len == 0 and self.devices.items.len == 0);
    self.devices.deinit(self.allocator);
    self.managers.deinit(self.allocator);
    self.* = undefined;
}

pub fn publish(self: *WayringVirtualKeyboard) !void {
    std.debug.assert(self.global == null);
    self.global = try self.protocol_server.addGlobalWithOptions(
        protocol.zwp_virtual_keyboard_manager_v1,
        1,
        WayringVirtualKeyboard,
        self,
        bindManager,
        .{ .visibility = .restricted },
    );
}

pub fn unpublish(self: *WayringVirtualKeyboard) void {
    const global = self.global orelse unreachable;
    self.protocol_server.removeGlobal(global) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}

fn bindManager(
    client: *wayring.server.Client,
    id: u32,
    version: u32,
    self: *WayringVirtualKeyboard,
) !void {
    if (version != 1) return error.InvalidVersion;
    if (!client.isAuthorizedDirectPeer(self.authorized_uid)) return error.AccessDenied;
    try self.managers.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Manager);
    errdefer self.allocator.destroy(value);
    value.* = .{
        .owner = self,
        .client = client,
        .resource = .init(self.allocator, id, version, .client, client.ownerHooks()),
    };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Manager, value, managerRequest, null);
    try client.materialize(&value.resource.runtime);
    self.managers.appendAssumeCapacity(value);
}

fn managerRequest(
    _: *protocol.zwp_virtual_keyboard_manager_v1.Resource,
    request: protocol.zwp_virtual_keyboard_manager_v1.Request,
    value: *Manager,
) !void {
    switch (request) {
        .create_virtual_keyboard => |args| {
            if (!value.client.isAuthorizedDirectPeer(value.owner.authorized_uid)) {
                value.client.postProtocolError(
                    &value.resource.runtime,
                    @intCast(protocol.zwp_virtual_keyboard_manager_v1.@"error".unauthorized),
                    "virtual keyboard requires a direct same-UID transport",
                );
                return;
            }
            if (value.owner.seat_adapter.seatClientIdentity(value.client, args.seat) == null) {
                value.client.postImplementationError(
                    &value.resource.runtime,
                    "virtual keyboard requires the exact live same-client wl_seat",
                );
                return;
            }
            try value.owner.createDevice(value, args.id);
        },
    }
}

fn createDevice(self: *WayringVirtualKeyboard, manager: *Manager, id: u32) !void {
    try self.devices.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Device);
    errdefer self.allocator.destroy(value);
    value.* = .{
        .owner = self,
        .client = manager.client,
        .resource = .init(self.allocator, id, 1, .client, manager.client.ownerHooks()),
    };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Device, value, deviceRequest, null);
    try self.seat.createVirtualKeyboard(value);
    errdefer self.seat.destroyVirtualKeyboard(value);
    try manager.client.materialize(&value.resource.runtime);
    self.devices.appendAssumeCapacity(value);
}

fn deviceRequest(
    _: *protocol.zwp_virtual_keyboard_v1.Resource,
    request: protocol.zwp_virtual_keyboard_v1.Request,
    value: *Device,
) !void {
    switch (request) {
        .keymap => |args| value.owner.setKeymap(value, args.format, args.fd, args.size),
        .key => |args| value.owner.sendKey(value, args.time, args.key, args.state),
        .modifiers => |args| {
            if (!value.owner.requireKeymap(value)) return;
            value.owner.seat.setVirtualModifiers(
                value,
                args.mods_depressed,
                args.mods_latched,
                args.mods_locked,
                args.group,
            );
        },
        .destroy => value.owner.destroyDevice(value),
    }
}

fn setKeymap(
    self: *WayringVirtualKeyboard,
    value: *Device,
    format: u32,
    fd: std.posix.fd_t,
    size: u32,
) void {
    if (format != @intFromEnum(wl.Keyboard.KeymapFormat.xkb_v1)) {
        _ = std.c.close(fd);
        value.client.postProtocolError(
            &value.resource.runtime,
            @intCast(protocol.zwp_virtual_keyboard_v1.@"error".invalid_keymap_format),
            "unsupported virtual keyboard keymap format",
        );
        return;
    }
    self.seat.setVirtualKeyboardKeymap(value, fd, size) catch {
        value.client.postImplementationError(&value.resource.runtime, "invalid virtual keyboard keymap");
    };
}

fn sendKey(
    self: *WayringVirtualKeyboard,
    value: *Device,
    time: u32,
    key: u32,
    state_value: u32,
) void {
    if (!self.requireKeymap(value)) return;
    const state: wl.Keyboard.KeyState = switch (state_value) {
        @intFromEnum(wl.Keyboard.KeyState.released) => .released,
        @intFromEnum(wl.Keyboard.KeyState.pressed) => .pressed,
        else => {
            value.client.postImplementationError(&value.resource.runtime, "invalid virtual keyboard key state");
            return;
        },
    };
    self.seat.virtualKey(value, time, key, state) catch
        value.client.postOutOfMemory(&value.resource.runtime, "recording virtual keyboard key");
}

fn requireKeymap(self: *WayringVirtualKeyboard, value: *Device) bool {
    if (self.seat.virtualKeyboardHasKeymap(value)) return true;
    value.client.postProtocolError(
        &value.resource.runtime,
        @intCast(protocol.zwp_virtual_keyboard_v1.@"error".no_keymap),
        "virtual keyboard has no keymap",
    );
    return false;
}

pub fn destroyClientResources(self: *WayringVirtualKeyboard, client: *wayring.server.Client) void {
    var i = self.devices.items.len;
    while (i > 0) : (i -= 1) if (self.devices.items[i - 1].client == client)
        self.destroyDevice(self.devices.items[i - 1]);
    i = self.managers.items.len;
    while (i > 0) : (i -= 1) if (self.managers.items[i - 1].client == client)
        self.destroyManager(self.managers.items[i - 1]);
}

fn destroyDevice(self: *WayringVirtualKeyboard, value: *Device) void {
    for (self.devices.items, 0..) |candidate, index| if (candidate == value) {
        _ = self.devices.swapRemove(index);
        break;
    };
    self.seat.destroyVirtualKeyboard(value);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}

fn destroyManager(self: *WayringVirtualKeyboard, value: *Manager) void {
    for (self.managers.items, 0..) |candidate, index| if (candidate == value) {
        _ = self.managers.swapRemove(index);
        break;
    };
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}

test "virtual-keyboard v1 descriptors and errors are exact" {
    const manager = protocol.zwp_virtual_keyboard_manager_v1;
    const device = protocol.zwp_virtual_keyboard_v1;
    try std.testing.expectEqual(@as(u32, 1), manager.interface.version);
    try std.testing.expectEqual(@as(u32, 1), device.interface.version);
    try expectNames(&manager.request_messages, &.{"create_virtual_keyboard"});
    try expectNames(&manager.event_messages, &.{});
    try expectNames(&device.request_messages, &.{ "keymap", "key", "modifiers", "destroy" });
    try expectNames(&device.event_messages, &.{});
    try std.testing.expectEqual(@as(i64, 0), manager.@"error".unauthorized);
    try std.testing.expectEqual(@as(i64, 0), device.@"error".no_keymap);
    try std.testing.expectEqual(@as(i64, 1), device.@"error".invalid_keymap_format);
}

fn expectNames(messages: anytype, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, messages.len);
    for (messages, expected) |message, name| try std.testing.expectEqualStrings(name, message.name);
}
