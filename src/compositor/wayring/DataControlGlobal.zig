//! Focus-independent ext-data-control-v1 policy and FD relay.

const DataControlGlobal = @This();
const std = @import("std");
const linux = std.os.linux;
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const SeatGlobal = @import("SeatGlobal.zig");
const DataDeviceGlobal = @import("DataDeviceGlobal.zig");
const PrimarySelectionGlobal = @import("PrimarySelectionGlobal.zig");
const SecurityContextGlobal = @import("SecurityContextGlobal.zig");
const SelectionSource = @import("SelectionSource.zig");

const Kind = enum { regular, primary };

allocator: std.mem.Allocator,
server: *Server,
seat: *SeatGlobal,
regular: *DataDeviceGlobal,
primary: *PrimarySelectionGlobal,
global_name: u32,
sources: std.ArrayList(*Source) = .empty,
devices: std.ArrayList(*Device) = .empty,
offers: std.ArrayList(*Offer) = .empty,

const Source = struct {
    owner: *DataControlGlobal,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    mimes: std.ArrayList([]u8) = .empty,
    used: bool = false,
    cancelled: bool = false,
    callbacks: SelectionSource,

    fn hasMime(self: *Source, mime: []const u8) bool {
        for (self.mimes.items) |item| if (std.mem.eql(u8, item, mime)) return true;
        return false;
    }
};

const Device = struct {
    owner: *DataControlGlobal,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    inert: bool,
};

const Offer = struct {
    owner: *DataControlGlobal,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    device: ?*Device,
    kind: Kind,
    generation: u64,
};

pub fn init(
    self: *DataControlGlobal,
    allocator: std.mem.Allocator,
    server: *Server,
    seat: *SeatGlobal,
    regular: *DataDeviceGlobal,
    primary: *PrimarySelectionGlobal,
    security_context: *SecurityContextGlobal,
) !void {
    self.* = .{ .allocator = allocator, .server = server, .seat = seat, .regular = regular, .primary = primary, .global_name = undefined };
    try regular.addSelectionListener(.{ .context = self, .changed = regularChanged, .offered = regularOffered });
    errdefer regular.removeSelectionListener(self);
    try primary.addSelectionListener(.{ .context = self, .changed = primaryChanged, .offered = primaryOffered });
    errdefer primary.removeSelectionListener(self);
    self.global_name = try server.createGlobal(
        &generated.ext_data_control_manager_v1,
        1,
        .{
            .context = self,
            .bind = bind,
            .filter_context = security_context,
            .filter = SecurityContextGlobal.allowUnconfined,
        },
    );
}

pub fn deinit(self: *DataControlGlobal) void {
    self.regular.removeSelectionListener(self);
    self.primary.removeSelectionListener(self);
    self.server.removeGlobal(self.global_name) catch unreachable;
    std.debug.assert(self.sources.items.len == 0 and self.devices.items.len == 0 and self.offers.items.len == 0);
    self.sources.deinit(self.allocator);
    self.devices.deinit(self.allocator);
    self.offers.deinit(self.allocator);
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *DataControlGlobal = @ptrCast(@alignCast(context));
    _ = client.createResource(id, &generated.ext_data_control_manager_v1, version, .{ .context = self, .dispatch = dispatchManager }) catch return client.postNoMemory();
}

fn dispatchManager(context: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    const self: *DataControlGlobal = @ptrCast(@alignCast(context));
    switch (try generated.ext_data_control_manager_v1_types.decodeRequest(&client.connection, resource, message)) {
        .create_data_source => |request| try self.createSource(client, request.id),
        .get_data_device => |request| try self.createDevice(client, request.id, !self.seat.ownsResource(client, request.seat)),
        .destroy => {},
    }
}

fn createSource(self: *DataControlGlobal, client: *Server.Client, id: u32) !void {
    const source = self.allocator.create(Source) catch return client.postNoMemory();
    var registered = false;
    errdefer if (!registered) self.allocator.destroy(source);
    self.sources.ensureUnusedCapacity(self.allocator, 1) catch return client.postNoMemory();
    source.* = .{ .owner = self, .client = client, .resource = undefined, .callbacks = .{ .context = source, .mime_types = sourceMimes, .send = sourceSend, .cancel = sourceCancel } };
    source.resource = client.createResource(id, &generated.ext_data_control_source_v1, 1, .{ .context = source, .dispatch = dispatchSource, .destroy = destroySource }) catch return client.postNoMemory();
    self.sources.appendAssumeCapacity(source);
    registered = true;
}

fn createDevice(self: *DataControlGlobal, client: *Server.Client, id: u32, inert: bool) !void {
    const device = self.allocator.create(Device) catch return client.postNoMemory();
    var registered = false;
    errdefer if (!registered) self.allocator.destroy(device);
    self.devices.ensureUnusedCapacity(self.allocator, 1) catch return client.postNoMemory();
    device.* = .{ .owner = self, .client = client, .resource = undefined, .inert = inert };
    device.resource = client.createResource(id, &generated.ext_data_control_device_v1, 1, .{ .context = device, .dispatch = dispatchDevice, .destroy = destroyDevice }) catch return client.postNoMemory();
    self.devices.appendAssumeCapacity(device);
    registered = true;
    if (inert) generated.ext_data_control_device_v1_types.events.finished(&client.connection, device.resource) catch return client.postNoMemory();
    if (!inert) {
        self.sendSelection(device, .regular) catch return client.postNoMemory();
        self.sendSelection(device, .primary) catch return client.postNoMemory();
    }
}

fn dispatchSource(context: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    const source: *Source = @ptrCast(@alignCast(context));
    switch (try generated.ext_data_control_source_v1_types.decodeRequest(&client.connection, resource, message)) {
        .offer => |request| {
            if (source.used) return client.postError(resource, @intFromEnum(generated.ext_data_control_source_v1_types.@"error".invalid_offer), "cannot offer after source use");
            if (source.hasMime(request.mime_type)) return;
            const copy = source.owner.allocator.dupe(u8, request.mime_type) catch return client.postNoMemory();
            source.mimes.append(source.owner.allocator, copy) catch {
                source.owner.allocator.free(copy);
                return client.postNoMemory();
            };
        },
        .destroy => {},
    }
}

fn dispatchDevice(context: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    const device: *Device = @ptrCast(@alignCast(context));
    switch (try generated.ext_data_control_device_v1_types.decodeRequest(&client.connection, resource, message)) {
        .set_selection => |request| try device.owner.set(device, .regular, request.source),
        .set_primary_selection => |request| try device.owner.set(device, .primary, request.source),
        .destroy => {},
    }
}

fn set(self: *DataControlGlobal, device: *Device, kind: Kind, id: ?u32) !void {
    if (device.inert) return;
    const source: ?*Source = if (id) |value| source: {
        const object = device.client.connection.object(value) orelse return;
        const context = try device.client.resourceContext(.{ .id = value, .generation = object.generation }, &generated.ext_data_control_source_v1);
        const candidate: *Source = @ptrCast(@alignCast(context));
        if (candidate.owner != self or candidate.client != device.client) return;
        if (candidate.used) return device.client.postError(device.resource, @intFromEnum(generated.ext_data_control_device_v1_types.@"error".used_source), "data-control source was already used");
        candidate.used = true;
        break :source candidate;
    } else null;
    switch (kind) {
        .regular => self.regular.setExternalSelection(if (source) |item| &item.callbacks else null),
        .primary => self.primary.setExternalSelection(if (source) |item| &item.callbacks else null),
    }
}

fn dispatchOffer(context: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    const offer: *Offer = @ptrCast(@alignCast(context));
    switch (try generated.ext_data_control_offer_v1_types.decodeRequest(&client.connection, resource, message)) {
        .receive => |request| {
            const fd = try message.takeFd(request.fd);
            var owned = true;
            defer if (owned) {
                _ = linux.close(fd);
            };
            const device = offer.device orelse return;
            if (device.inert or device.client.state != .active or offer.generation != offer.owner.generation(offer.kind) or !offer.owner.hasMime(offer.kind, request.mime_type)) return;
            offer.owner.send(offer.kind, request.mime_type, fd) catch return;
            owned = false;
        },
        .destroy => {},
    }
}

fn sendSelection(self: *DataControlGlobal, device: *Device, kind: Kind) !void {
    if (!self.has(kind)) return self.selectionEvent(device, kind, null);
    const offer = try self.allocator.create(Offer);
    var registered = false;
    errdefer if (!registered) self.allocator.destroy(offer);
    try self.offers.ensureUnusedCapacity(self.allocator, 1);
    offer.* = .{ .owner = self, .client = device.client, .resource = undefined, .device = device, .kind = kind, .generation = self.generation(kind) };
    offer.resource = try device.client.createServerResource(&generated.ext_data_control_offer_v1, 1, .{ .context = offer, .dispatch = dispatchOffer, .destroy = destroyOffer });
    self.offers.appendAssumeCapacity(offer);
    registered = true;
    try generated.ext_data_control_device_v1_types.events.data_offer(&device.client.connection, device.resource, offer.resource);
    for (self.mimes(kind)) |mime| try generated.ext_data_control_offer_v1_types.events.offer(&device.client.connection, offer.resource, mime);
    try self.selectionEvent(device, kind, offer.resource);
}

fn selectionEvent(_: *DataControlGlobal, device: *Device, kind: Kind, offer: ?wayring.ObjectHandle) !void {
    switch (kind) {
        .regular => try generated.ext_data_control_device_v1_types.events.selection(&device.client.connection, device.resource, offer),
        .primary => try generated.ext_data_control_device_v1_types.events.primary_selection(&device.client.connection, device.resource, offer),
    }
}
fn has(self: *DataControlGlobal, kind: Kind) bool {
    return switch (kind) {
        .regular => self.regular.hasSelection(),
        .primary => self.primary.hasSelection(),
    };
}
fn generation(self: *DataControlGlobal, kind: Kind) u64 {
    return switch (kind) {
        .regular => self.regular.selectionGeneration(),
        .primary => self.primary.selectionGeneration(),
    };
}
fn mimes(self: *DataControlGlobal, kind: Kind) []const []const u8 {
    return switch (kind) {
        .regular => self.regular.selectionMimeTypes(),
        .primary => self.primary.selectionMimeTypes(),
    };
}
fn hasMime(self: *DataControlGlobal, kind: Kind, mime: []const u8) bool {
    for (self.mimes(kind)) |item| if (std.mem.eql(u8, item, mime)) return true;
    return false;
}
fn send(self: *DataControlGlobal, kind: Kind, mime: []const u8, fd: std.posix.fd_t) !void {
    return switch (kind) {
        .regular => self.regular.sendSelection(mime, fd),
        .primary => self.primary.sendSelection(mime, fd),
    };
}

fn changed(self: *DataControlGlobal, kind: Kind) void {
    for (self.devices.items) |device| if (!device.inert and device.client.state == .active) self.sendSelection(device, kind) catch {
        device.client.postNoMemory() catch {};
    };
}
fn offered(self: *DataControlGlobal, kind: Kind, mime: []const u8) void {
    const current = self.generation(kind);
    for (self.offers.items) |offer| if (offer.device != null and offer.kind == kind and offer.generation == current and offer.client.state == .active) generated.ext_data_control_offer_v1_types.events.offer(&offer.client.connection, offer.resource, mime) catch {
        offer.client.postNoMemory() catch {};
    };
}
fn regularChanged(context: *anyopaque) void {
    const self: *DataControlGlobal = @ptrCast(@alignCast(context));
    self.changed(.regular);
}
fn primaryChanged(context: *anyopaque) void {
    const self: *DataControlGlobal = @ptrCast(@alignCast(context));
    self.changed(.primary);
}
fn regularOffered(context: *anyopaque, mime: []const u8) void {
    const self: *DataControlGlobal = @ptrCast(@alignCast(context));
    self.offered(.regular, mime);
}
fn primaryOffered(context: *anyopaque, mime: []const u8) void {
    const self: *DataControlGlobal = @ptrCast(@alignCast(context));
    self.offered(.primary, mime);
}

fn sourceMimes(context: *anyopaque) []const []const u8 {
    const source: *Source = @ptrCast(@alignCast(context));
    return source.mimes.items;
}
fn sourceSend(context: *anyopaque, mime: []const u8, fd: std.posix.fd_t) !void {
    const source: *Source = @ptrCast(@alignCast(context));
    if (source.client.state != .active or !source.hasMime(mime)) return error.InactiveSource;
    generated.ext_data_control_source_v1_types.events.send(&source.client.connection, source.resource, mime, fd) catch return source.client.postNoMemory();
}
fn sourceCancel(context: *anyopaque) !void {
    const source: *Source = @ptrCast(@alignCast(context));
    if (source.cancelled or source.client.state != .active) return;
    source.cancelled = true;
    generated.ext_data_control_source_v1_types.events.cancelled(&source.client.connection, source.resource) catch return source.client.postNoMemory();
}

fn destroySource(context: *anyopaque, _: *Server.Client, _: wayring.ObjectHandle) void {
    const source: *Source = @ptrCast(@alignCast(context));
    source.owner.regular.externalSourceDestroyed(&source.callbacks);
    source.owner.primary.externalSourceDestroyed(&source.callbacks);
    remove(Source, &source.owner.sources, source);
    for (source.mimes.items) |mime| source.owner.allocator.free(mime);
    source.mimes.deinit(source.owner.allocator);
    source.owner.allocator.destroy(source);
}
fn destroyDevice(context: *anyopaque, _: *Server.Client, _: wayring.ObjectHandle) void {
    const device: *Device = @ptrCast(@alignCast(context));
    for (device.owner.offers.items) |offer| {
        if (offer.device == device) offer.device = null;
    }
    remove(Device, &device.owner.devices, device);
    device.owner.allocator.destroy(device);
}
fn destroyOffer(context: *anyopaque, _: *Server.Client, _: wayring.ObjectHandle) void {
    const offer: *Offer = @ptrCast(@alignCast(context));
    remove(Offer, &offer.owner.offers, offer);
    offer.owner.allocator.destroy(offer);
}
fn remove(comptime T: type, list: *std.ArrayList(*T), item: *T) void {
    for (list.items, 0..) |candidate, index| if (candidate == item) {
        _ = list.swapRemove(index);
        return;
    };
    unreachable;
}

test "ext data control advertises v1 and children outlive their manager" {
    const core = @import("wayring-core");
    const allocator = std.testing.allocator;
    var server = Server.init(allocator);
    defer server.deinit();
    var transport: @import("wayring-server-uring") = undefined;
    var security_context: SecurityContextGlobal = undefined;
    try security_context.init(allocator, &server, &transport);
    defer security_context.deinit();
    var seat: SeatGlobal = undefined;
    try seat.init(allocator, &server, "default", SeatGlobal.Capability.keyboard, null);
    defer seat.deinit();
    var regular: DataDeviceGlobal = undefined;
    try regular.init(allocator, &server, &seat);
    defer regular.deinit();
    var primary: PrimarySelectionGlobal = undefined;
    try primary.init(allocator, &server, &seat);
    defer primary.deinit();
    var control: DataControlGlobal = undefined;
    try control.init(
        allocator,
        &server,
        &seat,
        &regular,
        &primary,
        &security_context,
    );
    defer control.deinit();

    const client = try server.createClient();
    defer server.destroyClient(client) catch unreachable;
    var peer = wayring.Connection.init(allocator, .client, wayring.default_max_frame_size);
    defer peer.deinit();
    _ = try core.bootstrapDisplay(&peer);
    const registry: wayring.ObjectHandle = .{ .id = 2, .generation = try core.getRegistry(&peer, 2) };
    try transferTest(&peer, &client.connection, client);
    try transferTest(&client.connection, &peer, null);
    try client.outputDrained();

    var manager_name: u32 = 0;
    var seat_name: u32 = 0;
    var regular_name: u32 = 0;
    var regular_version: u32 = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const event = try core.decodeRegistryEvent(&message, registry.id);
        if (event != .global) continue;
        if (std.mem.eql(u8, event.global.interface, generated.ext_data_control_manager_v1.name)) {
            manager_name = event.global.name;
            try std.testing.expectEqual(@as(u32, 1), event.global.version);
        } else if (std.mem.eql(u8, event.global.interface, generated.wl_seat.name)) {
            seat_name = event.global.name;
        } else if (std.mem.eql(u8, event.global.interface, generated.wl_data_device_manager.name)) {
            regular_name = event.global.name;
            regular_version = event.global.version;
        }
    }
    try std.testing.expect(manager_name != 0 and seat_name != 0 and regular_name != 0);
    const seat_handle: wayring.ObjectHandle = .{ .id = 3, .generation = try core.bind(&peer, registry.id, seat_name, generated.wl_seat.name, 1, 3, &generated.wl_seat) };
    const manager: wayring.ObjectHandle = .{ .id = 4, .generation = try core.bind(&peer, registry.id, manager_name, generated.ext_data_control_manager_v1.name, 1, 4, &generated.ext_data_control_manager_v1) };
    const regular_manager: wayring.ObjectHandle = .{ .id = 5, .generation = try core.bind(&peer, registry.id, regular_name, generated.wl_data_device_manager.name, regular_version, 5, &generated.wl_data_device_manager) };
    const source = try generated.ext_data_control_manager_v1_types.requests.create_data_source(&peer, manager);
    const device = try generated.ext_data_control_manager_v1_types.requests.get_data_device(&peer, manager, seat_handle);
    const regular_device = try generated.wl_data_device_manager_types.requests.get_data_device(&peer, regular_manager, seat_handle);
    const foreign_seat = try peer.allocateObject(&generated.wl_seat, 1);
    _ = try client.createResource(foreign_seat.id, &generated.wl_seat, 1, .{ .context = &control });
    const finished_device = try generated.ext_data_control_manager_v1_types.requests.get_data_device(&peer, manager, foreign_seat);
    try generated.ext_data_control_manager_v1_types.requests.destroy(&peer, manager);
    try transferTest(&peer, &client.connection, client);
    try transferTest(&client.connection, &peer, null);
    try client.outputDrained();

    var null_events: usize = 0;
    var got_finished = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == 1) {
            _ = try core.decodeDisplayEvent(&message);
            continue;
        }
        if (message.object_id == seat_handle.id) {
            _ = try generated.wl_seat_types.decodeEvent(&peer, seat_handle, &message);
            continue;
        }
        const target = if (message.object_id == device.id)
            device
        else if (message.object_id == finished_device.id)
            finished_device
        else
            return error.UnexpectedDataControlSetupEvent;
        switch (try generated.ext_data_control_device_v1_types.decodeEvent(&peer, target, &message)) {
            .selection => |event| {
                try std.testing.expectEqual(device.id, target.id);
                try std.testing.expect(event.id == null);
                null_events += 1;
            },
            .primary_selection => |event| {
                try std.testing.expectEqual(device.id, target.id);
                try std.testing.expect(event.id == null);
                null_events += 1;
            },
            .finished => {
                try std.testing.expectEqual(finished_device.id, target.id);
                got_finished = true;
            },
            .data_offer => return error.UnexpectedDataControlEvent,
        }
    }
    try std.testing.expectEqual(@as(usize, 2), null_events);
    try std.testing.expect(got_finished);

    // Child requests still dispatch after the manager resource is gone, and
    // data-control observes selections without keyboard focus.
    try generated.ext_data_control_source_v1_types.requests.offer(&peer, source, "text/plain");
    try generated.ext_data_control_device_v1_types.requests.set_selection(&peer, device, source);
    try transferTest(&peer, &client.connection, client);
    try std.testing.expectEqual(@as(usize, 1), control.sources.items.len);
    try std.testing.expectEqual(@as(usize, 2), control.devices.items.len);
    try transferTest(&client.connection, &peer, null);
    try client.outputDrained();

    var control_offer: ?wayring.ObjectHandle = null;
    var got_control_mime = false;
    var got_control_selection = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == device.id) {
            switch (try generated.ext_data_control_device_v1_types.decodeEvent(&peer, device, &message)) {
                .data_offer => |event| {
                    const offer: wayring.ObjectHandle = .{
                        .id = event.id,
                        .generation = try peer.registerObject(event.id, &generated.ext_data_control_offer_v1, 1),
                    };
                    control_offer = offer;
                    try peer.resumeParsing();
                },
                .selection => |event| {
                    try std.testing.expectEqual(control_offer.?.id, event.id.?);
                    got_control_selection = true;
                },
                else => return error.UnexpectedDataControlEvent,
            }
        } else if (control_offer) |offer| {
            if (message.object_id != offer.id) return error.UnexpectedDataControlEvent;
            switch (try generated.ext_data_control_offer_v1_types.decodeEvent(&peer, offer, &message)) {
                .offer => |event| {
                    try std.testing.expectEqualStrings("text/plain", event.mime_type);
                    got_control_mime = true;
                },
            }
        } else return error.UnexpectedDataControlEvent;
    }
    try std.testing.expect(got_control_mime and got_control_selection);

    // Focusing the ordinary clipboard later creates an interoperable wl offer.
    try regular.setKeyboardFocus(client);
    try transferTest(&client.connection, &peer, null);
    try client.outputDrained();
    var regular_offer: ?wayring.ObjectHandle = null;
    var got_regular_mime = false;
    var got_regular_selection = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == regular_device.id) {
            switch (try generated.wl_data_device_types.decodeEvent(&peer, regular_device, &message)) {
                .data_offer => |event| {
                    const offer: wayring.ObjectHandle = .{
                        .id = event.id,
                        .generation = try peer.registerObject(event.id, &generated.wl_data_offer, regular_version),
                    };
                    regular_offer = offer;
                    try peer.resumeParsing();
                },
                .selection => |event| {
                    try std.testing.expectEqual(regular_offer.?.id, event.id.?);
                    got_regular_selection = true;
                },
                else => return error.UnexpectedRegularSelectionEvent,
            }
        } else if (regular_offer) |offer| {
            if (message.object_id != offer.id) return error.UnexpectedRegularSelectionEvent;
            switch (try generated.wl_data_offer_types.decodeEvent(&peer, offer, &message)) {
                .offer => |event| {
                    try std.testing.expectEqualStrings("text/plain", event.mime_type);
                    got_regular_mime = true;
                },
                else => return error.UnexpectedRegularSelectionEvent,
            }
        } else return error.UnexpectedRegularSelectionEvent;
    }
    try std.testing.expect(got_regular_mime and got_regular_selection);

    var pipe: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) != .SUCCESS)
        return error.PipeFailed;
    defer _ = linux.close(pipe[0]);
    var write_owned = true;
    defer if (write_owned) {
        _ = linux.close(pipe[1]);
    };
    try generated.wl_data_offer_types.requests.receive(&peer, regular_offer.?, "text/plain", pipe[1]);
    write_owned = false;
    try transferTest(&peer, &client.connection, client);
    try transferTest(&client.connection, &peer, null);
    try client.outputDrained();
    var send_message = peer.popMessage() orelse return error.MissingDataControlSend;
    defer send_message.deinit();
    const send_event = try generated.ext_data_control_source_v1_types.decodeEvent(&peer, source, &send_message);
    const transfer_fd = switch (send_event) {
        .send => |event| transfer: {
            try std.testing.expectEqualStrings("text/plain", event.mime_type);
            break :transfer try send_message.takeFd(event.fd);
        },
        else => return error.UnexpectedDataControlSourceEvent,
    };
    const payload = "native data control";
    const written = linux.write(transfer_fd, payload.ptr, payload.len);
    if (linux.errno(written) != .SUCCESS) return error.WriteFailed;
    try std.testing.expectEqual(payload.len, written);
    _ = linux.close(transfer_fd);
    var received: [32]u8 = undefined;
    const received_len = linux.read(pipe[0], &received, received.len);
    if (linux.errno(received_len) != .SUCCESS) return error.ReadFailed;
    try std.testing.expectEqualStrings(payload, received[0..received_len]);

    // Clearing cancels once and makes the old ordinary offer inert.
    try generated.ext_data_control_device_v1_types.requests.set_selection(&peer, device, null);
    try transferTest(&peer, &client.connection, client);
    try transferTest(&client.connection, &peer, null);
    try client.outputDrained();
    var cancellation_count: usize = 0;
    var got_regular_clear = false;
    var got_control_clear = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == source.id) {
            if ((try generated.ext_data_control_source_v1_types.decodeEvent(&peer, source, &message)) != .cancelled)
                return error.UnexpectedDataControlSourceEvent;
            cancellation_count += 1;
        } else if (message.object_id == regular_device.id) {
            switch (try generated.wl_data_device_types.decodeEvent(&peer, regular_device, &message)) {
                .selection => |event| {
                    try std.testing.expect(event.id == null);
                    got_regular_clear = true;
                },
                else => return error.UnexpectedRegularSelectionEvent,
            }
        } else if (message.object_id == device.id) {
            switch (try generated.ext_data_control_device_v1_types.decodeEvent(&peer, device, &message)) {
                .selection => |event| {
                    try std.testing.expect(event.id == null);
                    got_control_clear = true;
                },
                else => return error.UnexpectedDataControlEvent,
            }
        } else return error.UnexpectedDataControlEvent;
    }
    try std.testing.expectEqual(@as(usize, 1), cancellation_count);
    try std.testing.expect(got_regular_clear and got_control_clear);

    var stale_pipe: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&stale_pipe, .{ .CLOEXEC = true })) != .SUCCESS)
        return error.PipeFailed;
    defer _ = linux.close(stale_pipe[0]);
    var stale_write_owned = true;
    defer if (stale_write_owned) {
        _ = linux.close(stale_pipe[1]);
    };
    try generated.wl_data_offer_types.requests.receive(&peer, regular_offer.?, "text/plain", stale_pipe[1]);
    stale_write_owned = false;
    try transferTest(&peer, &client.connection, client);
    try transferTest(&client.connection, &peer, null);
    try client.outputDrained();
    try std.testing.expect(peer.popMessage() == null);
    const stale_len = linux.read(stale_pipe[0], &received, received.len);
    if (linux.errno(stale_len) != .SUCCESS) return error.ReadFailed;
    try std.testing.expectEqual(@as(usize, 0), stale_len);

    // The source's one use is shared by regular and primary selection.
    try generated.ext_data_control_device_v1_types.requests.set_primary_selection(&peer, device, source);
    try std.testing.expectError(error.ProtocolError, transferTest(&peer, &client.connection, client));
    try std.testing.expectEqual(Server.ClientState.protocol_error, client.state);
    try transferTest(&client.connection, &peer, null);
    try client.outputDrained();
    var got_used_source = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id != 1) continue;
        switch (try core.decodeDisplayEvent(&message)) {
            .error_event => |event| if (event.object_id == device.id and event.code == @intFromEnum(generated.ext_data_control_device_v1_types.@"error".used_source)) {
                got_used_source = true;
            },
            .delete_id => {},
        }
    }
    try std.testing.expect(got_used_source);
}

fn transferTest(sender: *wayring.Connection, receiver: *wayring.Connection, server_client: ?*Server.Client) !void {
    while (sender.nextBatch()) |batch| {
        var duplicated: [wayring.max_fds_per_batch]i32 = undefined;
        var count: usize = 0;
        errdefer {
            for (duplicated[0..count]) |fd| _ = linux.close(fd);
        }
        for (batch.fds) |fd| {
            const result = linux.dup(fd);
            if (linux.errno(result) != .SUCCESS) return error.DuplicateFdFailed;
            duplicated[count] = @intCast(result);
            count += 1;
        }
        const transferred = duplicated[0..count];
        count = 0;
        if (server_client) |client| try client.receive(batch.bytes, transferred) else try receiver.feed(batch.bytes, transferred);
        try sender.acknowledge(batch.token, batch.bytes.len);
    }
}
