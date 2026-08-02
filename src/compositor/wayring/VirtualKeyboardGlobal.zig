//! Privileged virtual keyboard producer for default and transient seats.

const VirtualKeyboardGlobal = @This();

const std = @import("std");
const linux = std.os.linux;
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const SecurityContextGlobal = @import("SecurityContextGlobal.zig");
const SeatGlobal = @import("SeatGlobal.zig");
const TransientSeatGlobal = @import("TransientSeatGlobal.zig");

const maximum_keymap_size = 16 * 1024 * 1024;
const keymap_seals = linux.F.SEAL_SHRINK |
    linux.F.SEAL_GROW |
    linux.F.SEAL_WRITE |
    linux.F.SEAL_SEAL;

allocator: std.mem.Allocator,
io: std.Io,
server: *Server,
seat: *SeatGlobal,
transient_seat: *TransientSeatGlobal,
listener: Listener,
global_name: u32,
devices: std.ArrayList(*Device) = .empty,

pub const Listener = struct {
    context: *anyopaque,
    capability_changed: *const fn (*anyopaque, *SeatGlobal) void,
    activity: *const fn (*anyopaque) void,
    failed: *const fn (*anyopaque) void,
};

const Device = struct {
    owner: *VirtualKeyboardGlobal,
    resource: wayring.ObjectHandle,
    seat: ?*SeatGlobal,
    retained_transient_seat: bool,
    has_keymap: bool = false,
    registered: bool = false,
    pressed_keys: std.ArrayList(u32) = .empty,
};

pub fn init(
    self: *VirtualKeyboardGlobal,
    allocator: std.mem.Allocator,
    io: std.Io,
    server: *Server,
    seat: *SeatGlobal,
    transient_seat: *TransientSeatGlobal,
    security: *SecurityContextGlobal,
    listener: Listener,
) !void {
    self.* = .{
        .allocator = allocator,
        .io = io,
        .server = server,
        .seat = seat,
        .transient_seat = transient_seat,
        .listener = listener,
        .global_name = undefined,
    };
    self.global_name = try server.createGlobal(
        &generated.zwp_virtual_keyboard_manager_v1,
        1,
        .{
            .context = self,
            .bind = bind,
            .filter_context = security,
            .filter = SecurityContextGlobal.allowUnconfined,
        },
    );
    errdefer server.removeGlobal(self.global_name) catch unreachable;
    try transient_seat.addSeatListener(.{
        .context = self,
        .removed = transientSeatRemoved,
    });
}

pub fn deinit(self: *VirtualKeyboardGlobal) void {
    std.debug.assert(self.devices.items.len == 0);
    self.transient_seat.removeSeatListener(self);
    self.server.removeGlobal(self.global_name) catch unreachable;
    self.devices.deinit(self.allocator);
    self.* = undefined;
}

fn transientSeatRemoved(context: *anyopaque, seat: *SeatGlobal) void {
    const self: *VirtualKeyboardGlobal = @ptrCast(@alignCast(context));
    for (self.devices.items) |device| {
        if (device.seat == seat) deactivate(device);
    }
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *VirtualKeyboardGlobal = @ptrCast(@alignCast(context));
    _ = client.createResource(
        id,
        &generated.zwp_virtual_keyboard_manager_v1,
        version,
        .{ .context = self, .dispatch = dispatchManager },
    ) catch return client.postNoMemory();
}

fn dispatchManager(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const self: *VirtualKeyboardGlobal = @ptrCast(@alignCast(context));
    switch (try generated.zwp_virtual_keyboard_manager_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .create_virtual_keyboard => |request| try self.createDevice(
            client,
            request.id,
            if (self.seat.ownsResource(client, request.seat))
                self.seat
            else
                self.transient_seat.seatForResource(client, request.seat),
        ),
    }
}

fn createDevice(
    self: *VirtualKeyboardGlobal,
    client: *Server.Client,
    id: u32,
    seat: ?*SeatGlobal,
) !void {
    self.devices.ensureUnusedCapacity(self.allocator, 1) catch
        return client.postNoMemory();
    const device = self.allocator.create(Device) catch return client.postNoMemory();
    errdefer self.allocator.destroy(device);
    const retained_transient_seat = if (seat) |target|
        target != self.seat and self.transient_seat.retainSeat(target)
    else
        false;
    errdefer if (retained_transient_seat) self.transient_seat.releaseSeat(seat.?);
    if (seat) |target|
        std.debug.assert(target == self.seat or retained_transient_seat);
    device.* = .{
        .owner = self,
        .resource = undefined,
        .seat = seat,
        .retained_transient_seat = retained_transient_seat,
    };
    device.resource = client.createResource(
        id,
        &generated.zwp_virtual_keyboard_v1,
        1,
        .{
            .context = device,
            .dispatch = dispatchDevice,
            .destroy = destroyDevice,
        },
    ) catch return client.postNoMemory();
    self.devices.appendAssumeCapacity(device);
}

fn dispatchDevice(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const device: *Device = @ptrCast(@alignCast(context));
    switch (try generated.zwp_virtual_keyboard_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .keymap => |request| {
            const fd = try message.takeFd(request.fd);
            if (device.seat == null) {
                _ = linux.close(fd);
                return;
            }
            try setKeymap(device, client, resource, request.format, fd, request.size);
        },
        .key => |request| {
            if (device.seat == null) return;
            try key(device, client, resource, request.time, request.key, request.state);
        },
        .modifiers => |request| {
            const seat = device.seat orelse return;
            if (!try requireKeymap(device, client, resource)) return;
            device.owner.listener.activity(device.owner.listener.context);
            seat.setVirtualModifiers(
                device,
                request.mods_depressed,
                request.mods_latched,
                request.mods_locked,
                request.group,
            ) catch device.owner.listener.failed(device.owner.listener.context);
        },
    }
}

fn setKeymap(
    self: *Device,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    format: u32,
    fd: std.posix.fd_t,
    size: u32,
) !void {
    defer {
        _ = linux.close(fd);
    }
    if (format != @intFromEnum(generated.wl_keyboard_types.keymap_format.xkb_v1))
        return client.postError(
            resource,
            @intFromEnum(generated.zwp_virtual_keyboard_v1_types.@"error".invalid_keymap_format),
            "unsupported virtual keyboard keymap format",
        );
    const keymap_fd = copyKeymap(self.owner.io, fd, size) catch |err| {
        if (err == error.InvalidKeymap)
            return client.postImplementationError("invalid virtual keyboard keymap");
        self.owner.listener.failed(self.owner.listener.context);
        return;
    };
    var keymap_owned = true;
    defer if (keymap_owned) {
        _ = linux.close(keymap_fd);
    };
    keymap_owned = false;
    const seat = self.seat orelse unreachable;
    seat.keyboardKeymap(format, keymap_fd, size) catch {
        self.owner.listener.failed(self.owner.listener.context);
        return;
    };
    self.has_keymap = true;
    if (self.registered) return;
    self.registered = true;
    seat.addVirtualKeyboard() catch
        self.owner.listener.failed(self.owner.listener.context);
    self.owner.listener.capability_changed(self.owner.listener.context, seat);
}

fn key(
    self: *Device,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    time: u32,
    key_code: u32,
    state: u32,
) !void {
    const seat = self.seat orelse return;
    if (!try requireKeymap(self, client, resource)) return;
    self.owner.listener.activity(self.owner.listener.context);
    switch (state) {
        @intFromEnum(generated.wl_keyboard_types.key_state.pressed) => {
            if (std.mem.indexOfScalar(u32, self.pressed_keys.items, key_code) != null) return;
            self.pressed_keys.append(self.owner.allocator, key_code) catch
                return client.postNoMemory();
            _ = seat.virtualKey(time, key_code, state) catch {
                _ = self.pressed_keys.pop();
                return client.postNoMemory();
            };
        },
        @intFromEnum(generated.wl_keyboard_types.key_state.released) => {
            const index = std.mem.indexOfScalar(u32, self.pressed_keys.items, key_code) orelse
                return;
            _ = self.pressed_keys.orderedRemove(index);
            _ = seat.virtualKey(time, key_code, state) catch
                self.owner.listener.failed(self.owner.listener.context);
        },
        else => return client.postImplementationError("invalid virtual keyboard key state"),
    }
}

fn requireKeymap(
    self: *const Device,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
) !bool {
    if (self.has_keymap) return true;
    client.postError(
        resource,
        @intFromEnum(generated.zwp_virtual_keyboard_v1_types.@"error".no_keymap),
        "virtual keyboard has no keymap",
    ) catch |err| switch (err) {
        error.ProtocolError, error.ProtocolErrorWithoutEvent => return false,
        else => return err,
    };
    unreachable;
}

fn deactivate(self: *Device) void {
    const seat = self.seat orelse return;
    while (self.pressed_keys.pop()) |key_code| {
        _ = seat.virtualKey(
            0,
            key_code,
            @intFromEnum(generated.wl_keyboard_types.key_state.released),
        ) catch self.owner.listener.failed(self.owner.listener.context);
    }
    seat.clearVirtualModifiers(self) catch
        self.owner.listener.failed(self.owner.listener.context);
    if (self.registered) {
        seat.removeVirtualKeyboard() catch
            self.owner.listener.failed(self.owner.listener.context);
        self.registered = false;
        self.owner.listener.capability_changed(self.owner.listener.context, seat);
    }
    self.seat = null;
    if (self.retained_transient_seat) {
        self.retained_transient_seat = false;
        self.owner.transient_seat.releaseSeat(seat);
    }
}

fn destroyDevice(context: *anyopaque, _: *Server.Client, _: wayring.ObjectHandle) void {
    const device: *Device = @ptrCast(@alignCast(context));
    const owner = device.owner;
    deactivate(device);
    for (owner.devices.items, 0..) |candidate, index| {
        if (candidate != device) continue;
        _ = owner.devices.orderedRemove(index);
        device.pressed_keys.deinit(owner.allocator);
        owner.allocator.destroy(device);
        return;
    }
    unreachable;
}

fn copyKeymap(io: std.Io, fd: std.posix.fd_t, size: u32) !std.posix.fd_t {
    if (size == 0 or size > maximum_keymap_size) return error.InvalidKeymap;
    const source: std.Io.File = .{
        .handle = fd,
        .flags = .{ .nonblocking = false },
    };
    const stat = source.stat(io) catch return error.InvalidKeymap;
    if (stat.size < size) return error.InvalidKeymap;

    const copy_fd = try std.posix.memfd_create(
        "keywork-virtual-keymap",
        linux.MFD.CLOEXEC | linux.MFD.ALLOW_SEALING,
    );
    var copy_owned = true;
    defer if (copy_owned) {
        _ = linux.close(copy_fd);
    };
    const copy: std.Io.File = .{
        .handle = copy_fd,
        .flags = .{ .nonblocking = false },
    };
    try copy.setLength(io, size);
    var buffer: [16 * 1024]u8 = undefined;
    var offset: u64 = 0;
    var last_byte: u8 = undefined;
    while (offset < size) {
        const chunk_length: usize = @intCast(@min(buffer.len, size - offset));
        const chunk = buffer[0..chunk_length];
        const read = source.readPositionalAll(io, chunk, offset) catch
            return error.InvalidKeymap;
        if (read != chunk.len) return error.InvalidKeymap;
        last_byte = chunk[chunk.len - 1];
        try copy.writePositionalAll(io, chunk, offset);
        offset += read;
    }
    if (last_byte != 0) return error.InvalidKeymap;
    if (std.c.fcntl(copy_fd, linux.F.ADD_SEALS, @as(c_int, keymap_seals)) < 0)
        return error.SealKeymapFailed;
    copy_owned = false;
    return copy_fd;
}

const TestListener = struct {
    capability_changes: usize = 0,
    last_capability_seat: ?*SeatGlobal = null,
    activities: usize = 0,
    failures: usize = 0,

    fn capabilityChanged(context: *anyopaque, seat: *SeatGlobal) void {
        const self: *TestListener = @ptrCast(@alignCast(context));
        self.capability_changes += 1;
        self.last_capability_seat = seat;
    }

    fn activity(context: *anyopaque) void {
        const self: *TestListener = @ptrCast(@alignCast(context));
        self.activities += 1;
    }

    fn failed(context: *anyopaque) void {
        const self: *TestListener = @ptrCast(@alignCast(context));
        self.failures += 1;
    }

    fn listener(self: *TestListener) Listener {
        return .{
            .context = self,
            .capability_changed = capabilityChanged,
            .activity = activity,
            .failed = failed,
        };
    }
};

test "virtual keyboard copies validates and seals keymaps" {
    const valid_fd = try std.posix.memfd_create("keywork-virtual-keymap-valid", linux.MFD.CLOEXEC);
    defer _ = linux.close(valid_fd);
    const valid_file: std.Io.File = .{
        .handle = valid_fd,
        .flags = .{ .nonblocking = false },
    };
    try valid_file.writePositionalAll(std.testing.io, "x\x00", 0);
    const copied_fd = try copyKeymap(std.testing.io, valid_fd, 2);
    defer _ = linux.close(copied_fd);
    const copied_file: std.Io.File = .{
        .handle = copied_fd,
        .flags = .{ .nonblocking = false },
    };
    try valid_file.writePositionalAll(std.testing.io, "y\x00", 0);
    var copied_bytes: [2]u8 = undefined;
    try std.testing.expectEqual(
        copied_bytes.len,
        try copied_file.readPositionalAll(std.testing.io, &copied_bytes, 0),
    );
    try std.testing.expectEqualStrings("x\x00", &copied_bytes);
    try std.testing.expectEqual(
        @as(usize, keymap_seals),
        linux.fcntl(copied_fd, linux.F.GET_SEALS, 0),
    );
    try std.testing.expectEqual(
        linux.E.PERM,
        linux.errno(linux.ftruncate(copied_fd, 1)),
    );

    try std.testing.expectError(error.InvalidKeymap, copyKeymap(std.testing.io, valid_fd, 0));
    try std.testing.expectError(error.InvalidKeymap, copyKeymap(std.testing.io, valid_fd, 3));
    try std.testing.expectError(error.InvalidKeymap, copyKeymap(
        std.testing.io,
        valid_fd,
        maximum_keymap_size + 1,
    ));

    const invalid_fd = try std.posix.memfd_create("keywork-virtual-keymap-invalid", linux.MFD.CLOEXEC);
    defer _ = linux.close(invalid_fd);
    const invalid_file: std.Io.File = .{
        .handle = invalid_fd,
        .flags = .{ .nonblocking = false },
    };
    try invalid_file.writePositionalAll(std.testing.io, "xx", 0);
    try std.testing.expectError(
        error.InvalidKeymap,
        copyKeymap(std.testing.io, invalid_fd, 2),
    );
}

test "virtual keyboard owns aggregate state and closes rejected keymaps" {
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var seat: SeatGlobal = undefined;
    try seat.init(std.testing.allocator, &server, "default", 0, null);
    defer seat.deinit();
    var security: SecurityContextGlobal = undefined;
    var transient_seats: TransientSeatGlobal = undefined;
    try transient_seats.init(std.testing.allocator, &server, &security);
    defer transient_seats.deinit();
    var capture: TestListener = .{};
    var keyboards: VirtualKeyboardGlobal = undefined;
    try keyboards.init(
        std.testing.allocator,
        std.testing.io,
        &server,
        &seat,
        &transient_seats,
        &security,
        capture.listener(),
    );
    defer keyboards.deinit();
    const client = try server.createClient();
    defer server.destroyClient(client) catch {};

    try keyboards.createDevice(client, 2, &seat);
    const device = keyboards.devices.items[0];
    const keymap_fd = try std.posix.memfd_create("keywork-virtual-keymap", linux.MFD.CLOEXEC);
    const keymap_file: std.Io.File = .{
        .handle = keymap_fd,
        .flags = .{ .nonblocking = false },
    };
    try keymap_file.writePositionalAll(std.testing.io, "x\x00", 0);
    try setKeymap(
        device,
        client,
        device.resource,
        @intFromEnum(generated.wl_keyboard_types.keymap_format.xkb_v1),
        keymap_fd,
        2,
    );
    try std.testing.expect(seat.hasCapability(SeatGlobal.Capability.keyboard));
    try key(
        device,
        client,
        device.resource,
        1,
        30,
        @intFromEnum(generated.wl_keyboard_types.key_state.pressed),
    );
    try key(
        device,
        client,
        device.resource,
        2,
        30,
        @intFromEnum(generated.wl_keyboard_types.key_state.pressed),
    );
    try std.testing.expectEqual(@as(usize, 1), device.pressed_keys.items.len);
    try std.testing.expectEqual(@as(usize, 1), seat.keyboard_keys.items.len);
    try seat.setVirtualModifiers(device, 1, 2, 3, 4);
    try client.destroyResource(device.resource);
    try std.testing.expectEqual(@as(usize, 0), keyboards.devices.items.len);
    try std.testing.expectEqual(@as(usize, 0), seat.keyboard_keys.items.len);
    try std.testing.expect(!seat.hasCapability(SeatGlobal.Capability.keyboard));
    try std.testing.expectEqual(@as(usize, 2), capture.capability_changes);
    try std.testing.expectEqual(&seat, capture.last_capability_seat.?);
    try std.testing.expectEqual(@as(usize, 2), capture.activities);
    try std.testing.expectEqual(@as(usize, 0), capture.failures);

    try keyboards.createDevice(client, 3, null);
    const inert = keyboards.devices.items[0];
    const rejected_fd = try std.posix.memfd_create("keywork-virtual-keymap-rejected", linux.MFD.CLOEXEC);
    try std.testing.expectError(error.ProtocolError, setKeymap(
        inert,
        client,
        inert.resource,
        @intFromEnum(generated.wl_keyboard_types.keymap_format.no_keymap),
        rejected_fd,
        1,
    ));
    try std.testing.expectEqual(
        linux.E.BADF,
        linux.errno(linux.fcntl(rejected_fd, linux.F.GETFD, 0)),
    );
}

test "virtual keyboard resolves transient seats and deactivates on retirement" {
    const core = @import("wayring-core");
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var default_seat: SeatGlobal = undefined;
    try default_seat.init(std.testing.allocator, &server, "default", 0, null);
    defer default_seat.deinit();
    var other_seat: SeatGlobal = undefined;
    try other_seat.init(std.testing.allocator, &server, "other", 0, null);
    defer other_seat.deinit();
    var security: SecurityContextGlobal = undefined;
    var transient_seats: TransientSeatGlobal = undefined;
    try transient_seats.init(std.testing.allocator, &server, &security);
    defer transient_seats.deinit();
    var capture: TestListener = .{};
    var keyboards: VirtualKeyboardGlobal = undefined;
    try keyboards.init(
        std.testing.allocator,
        std.testing.io,
        &server,
        &default_seat,
        &transient_seats,
        &security,
        capture.listener(),
    );
    defer keyboards.deinit();
    const client = try server.createClient();
    defer server.destroyClient(client) catch {};
    var peer = wayring.Connection.init(
        std.testing.allocator,
        .client,
        wayring.default_max_frame_size,
    );
    defer peer.deinit();
    _ = try core.bootstrapDisplay(&peer);
    const registry: wayring.ObjectHandle = .{
        .id = 2,
        .generation = try core.getRegistry(&peer, 2),
    };
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    var default_name: u32 = 0;
    var other_name: u32 = 0;
    var manager_name: u32 = 0;
    var transient_manager_name: u32 = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const event = try core.decodeRegistryEvent(&message, registry.id);
        if (event != .global) continue;
        if (event.global.name == default_seat.globalName()) default_name = event.global.name;
        if (event.global.name == other_seat.globalName()) other_name = event.global.name;
        if (std.mem.eql(
            u8,
            event.global.interface,
            generated.zwp_virtual_keyboard_manager_v1.name,
        )) manager_name = event.global.name;
        if (std.mem.eql(
            u8,
            event.global.interface,
            generated.ext_transient_seat_manager_v1.name,
        )) transient_manager_name = event.global.name;
    }
    try std.testing.expect(transient_manager_name != 0);
    const default_resource: wayring.ObjectHandle = .{
        .id = 3,
        .generation = try core.bind(
            &peer,
            registry.id,
            default_name,
            generated.wl_seat.name,
            10,
            3,
            &generated.wl_seat,
        ),
    };
    const other_resource: wayring.ObjectHandle = .{
        .id = 4,
        .generation = try core.bind(
            &peer,
            registry.id,
            other_name,
            generated.wl_seat.name,
            10,
            4,
            &generated.wl_seat,
        ),
    };
    const manager_resource: wayring.ObjectHandle = .{
        .id = 5,
        .generation = try core.bind(
            &peer,
            registry.id,
            manager_name,
            generated.zwp_virtual_keyboard_manager_v1.name,
            1,
            5,
            &generated.zwp_virtual_keyboard_manager_v1,
        ),
    };
    const transient_manager_resource: wayring.ObjectHandle = .{
        .id = 6,
        .generation = try core.bind(
            &peer,
            registry.id,
            transient_manager_name,
            generated.ext_transient_seat_manager_v1.name,
            1,
            6,
            &generated.ext_transient_seat_manager_v1,
        ),
    };
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    while (peer.popMessage()) |popped| {
        var message = popped;
        message.deinit();
    }

    const transient_resource = try generated.ext_transient_seat_manager_v1_types.requests.create(
        &peer,
        transient_manager_resource,
    );
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    var transient_name: u32 = 0;
    var saw_ready = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == registry.id) {
            const event = try core.decodeRegistryEvent(&message, registry.id);
            if (event == .global and
                std.mem.eql(u8, event.global.interface, generated.wl_seat.name) and
                event.global.name != default_name and
                event.global.name != other_name)
                transient_name = event.global.name;
            continue;
        }
        if (message.object_id != transient_resource.id) continue;
        const event = try generated.ext_transient_seat_v1_types.decodeEvent(
            &peer,
            transient_resource,
            &message,
        );
        switch (event) {
            .ready => saw_ready = true,
            .denied => return error.UnexpectedSeatDenial,
        }
    }
    try std.testing.expect(saw_ready and transient_name != 0);
    const transient_seat_resource: wayring.ObjectHandle = .{
        .id = 20,
        .generation = try core.bind(
            &peer,
            registry.id,
            transient_name,
            generated.wl_seat.name,
            10,
            20,
            &generated.wl_seat,
        ),
    };
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    while (peer.popMessage()) |popped| {
        var message = popped;
        message.deinit();
    }

    const active = try generated.zwp_virtual_keyboard_manager_v1_types.requests.create_virtual_keyboard(
        &peer,
        manager_resource,
        default_resource,
    );
    const transient = try generated.zwp_virtual_keyboard_manager_v1_types.requests.create_virtual_keyboard(
        &peer,
        manager_resource,
        transient_seat_resource,
    );
    const inert = try generated.zwp_virtual_keyboard_manager_v1_types.requests.create_virtual_keyboard(
        &peer,
        manager_resource,
        other_resource,
    );
    try transferToServer(&peer, client);
    try std.testing.expectEqual(@as(usize, 3), keyboards.devices.items.len);
    try std.testing.expectEqual(&default_seat, keyboards.devices.items[0].seat.?);
    const transient_seat = keyboards.devices.items[1].seat.?;
    try std.testing.expect(transient_seat != &default_seat);
    try std.testing.expect(keyboards.devices.items[1].retained_transient_seat);
    try std.testing.expect(keyboards.devices.items[2].seat == null);

    const inert_fd = try std.posix.memfd_create("keywork-inert-virtual-keymap", linux.MFD.CLOEXEC);
    try generated.zwp_virtual_keyboard_v1_types.requests.keymap(
        &peer,
        inert,
        @intFromEnum(generated.wl_keyboard_types.keymap_format.xkb_v1),
        inert_fd,
        1,
    );
    try transferToServer(&peer, client);
    try std.testing.expectEqual(
        linux.E.BADF,
        linux.errno(linux.fcntl(inert_fd, linux.F.GETFD, 0)),
    );
    try std.testing.expect(!default_seat.hasCapability(SeatGlobal.Capability.keyboard));

    const transient_fd = try std.posix.memfd_create(
        "keywork-transient-virtual-keymap",
        linux.MFD.CLOEXEC,
    );
    const transient_file: std.Io.File = .{
        .handle = transient_fd,
        .flags = .{ .nonblocking = false },
    };
    try transient_file.writePositionalAll(std.testing.io, "t\x00", 0);
    try generated.zwp_virtual_keyboard_v1_types.requests.keymap(
        &peer,
        transient,
        @intFromEnum(generated.wl_keyboard_types.keymap_format.xkb_v1),
        transient_fd,
        2,
    );
    try generated.zwp_virtual_keyboard_v1_types.requests.key(
        &peer,
        transient,
        2,
        31,
        @intFromEnum(generated.wl_keyboard_types.key_state.pressed),
    );
    try generated.zwp_virtual_keyboard_v1_types.requests.modifiers(
        &peer,
        transient,
        1,
        2,
        3,
        4,
    );
    try transferToServer(&peer, client);
    try std.testing.expect(transient_seat.hasCapability(SeatGlobal.Capability.keyboard));
    try std.testing.expectEqual(@as(usize, 1), transient_seat.keyboard_keys.items.len);

    try generated.ext_transient_seat_v1_types.requests.destroy(&peer, transient_resource);
    try transferToServer(&peer, client);
    try std.testing.expect(keyboards.devices.items[1].seat == null);
    try std.testing.expect(!keyboards.devices.items[1].retained_transient_seat);
    try std.testing.expect(!transient_seat.hasCapability(SeatGlobal.Capability.keyboard));
    try std.testing.expectEqual(@as(usize, 0), transient_seat.keyboard_keys.items.len);
    const retired_fd = try std.posix.memfd_create(
        "keywork-retired-virtual-keymap",
        linux.MFD.CLOEXEC,
    );
    try generated.zwp_virtual_keyboard_v1_types.requests.keymap(
        &peer,
        transient,
        @intFromEnum(generated.wl_keyboard_types.keymap_format.xkb_v1),
        retired_fd,
        1,
    );
    try transferToServer(&peer, client);
    try std.testing.expectEqual(
        linux.E.BADF,
        linux.errno(linux.fcntl(retired_fd, linux.F.GETFD, 0)),
    );

    const active_fd = try std.posix.memfd_create("keywork-active-virtual-keymap", linux.MFD.CLOEXEC);
    const active_file: std.Io.File = .{
        .handle = active_fd,
        .flags = .{ .nonblocking = false },
    };
    try active_file.writePositionalAll(std.testing.io, "x\x00", 0);
    try generated.zwp_virtual_keyboard_v1_types.requests.keymap(
        &peer,
        active,
        @intFromEnum(generated.wl_keyboard_types.keymap_format.xkb_v1),
        active_fd,
        2,
    );
    try generated.zwp_virtual_keyboard_v1_types.requests.key(
        &peer,
        active,
        1,
        30,
        @intFromEnum(generated.wl_keyboard_types.key_state.pressed),
    );
    try transferToServer(&peer, client);
    try std.testing.expect(default_seat.hasCapability(SeatGlobal.Capability.keyboard));
    try std.testing.expectEqual(@as(usize, 1), default_seat.keyboard_keys.items.len);

    try generated.zwp_virtual_keyboard_v1_types.requests.destroy(&peer, inert);
    try generated.zwp_virtual_keyboard_v1_types.requests.destroy(&peer, transient);
    try generated.zwp_virtual_keyboard_v1_types.requests.destroy(&peer, active);
    try transferToServer(&peer, client);
    try std.testing.expectEqual(@as(usize, 0), keyboards.devices.items.len);
    try std.testing.expectEqual(@as(usize, 0), default_seat.keyboard_keys.items.len);
    try std.testing.expect(!default_seat.hasCapability(SeatGlobal.Capability.keyboard));
}

fn transferToServer(connection: *wayring.Connection, client: *Server.Client) !void {
    while (connection.nextBatch()) |batch| {
        try client.receive(batch.bytes, batch.fds);
        try connection.acknowledge(batch.token, batch.bytes.len);
    }
}

fn transferFromServer(connection: *wayring.Connection, client: *Server.Client) !void {
    while (client.connection.nextBatch()) |batch| {
        try connection.feed(batch.bytes, batch.fds);
        try client.connection.acknowledge(batch.token, batch.bytes.len);
    }
    try client.outputDrained();
}
