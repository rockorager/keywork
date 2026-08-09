//! Backend-neutral scanner-backed DRM lease protocol adapter.
//!
//! Connector generations belong to this adapter.  In particular, an object
//! advertised before a connector is removed can never designate a later
//! connector which happens to have the same backend identity.

const WayringDrmLease = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayring = @import("wayring");

const server = wayring.server;
const wire = wayring.wire;

pub const Connector = struct {
    identity: u64,
    connector_id: u32,
    name: []const u8,
    description: []const u8,
};

pub const Grant = struct { identity: u64, fd: std.posix.fd_t };

/// All descriptors returned by this contract transfer to the adapter.  A
/// successful grant identity remains owned by the authority until revoke.
pub const Authority = struct {
    context: *anyopaque,
    openFd: *const fn (*anyopaque) anyerror!std.posix.fd_t,
    grant: *const fn (*anyopaque, []const u64) anyerror!Grant,
    revoke: *const fn (*anyopaque, u64) void,
};

const Generation = struct {
    snapshot: Connector,
    generation: u64,
    present: bool = true,
};
const Device = struct {
    owner: *WayringDrmLease,
    client: *server.Client,
    resource: protocol.wp_drm_lease_device_v1.Resource,
    initialized: bool = false,
    released: bool = false,
};
const Offer = struct { owner: *WayringDrmLease, device: *Device, resource: protocol.wp_drm_lease_connector_v1.Resource, identity: u64, generation: u64, current: bool = true };
const Requested = struct { identity: u64, generation: u64 };
const Request = struct { owner: *WayringDrmLease, device: *Device, resource: protocol.wp_drm_lease_request_v1.Resource, connectors: std.ArrayList(Requested) = .empty };
const Lease = struct {
    owner: *WayringDrmLease,
    device: *Device,
    resource: protocol.wp_drm_lease_v1.Resource,
    connectors: []Requested,
    grant_identity: ?u64 = null,
    finished: bool = false,
};

allocator: std.mem.Allocator,
protocol_server: *server.Server,
authority: Authority,
authorized_uid: std.os.linux.uid_t,
global: ?*const server.Server.Global = null,
generation: u64 = 0,
suspended: bool = false,
connectors: std.ArrayList(Generation) = .empty,
devices: std.ArrayList(*Device) = .empty,
offers: std.ArrayList(*Offer) = .empty,
requests: std.ArrayList(*Request) = .empty,
leases: std.ArrayList(*Lease) = .empty,

pub fn init(self: *WayringDrmLease, allocator: std.mem.Allocator, protocol_server: *server.Server, authorized_uid: std.os.linux.uid_t, authority: Authority) void {
    self.* = .{ .allocator = allocator, .protocol_server = protocol_server, .authorized_uid = authorized_uid, .authority = authority };
}

pub fn publish(self: *WayringDrmLease) !void {
    std.debug.assert(self.global == null);
    self.global = try self.protocol_server.addGlobalWithOptions(protocol.wp_drm_lease_device_v1, 1, WayringDrmLease, self, bind, .{ .visibility = .restricted });
}

pub fn unpublish(self: *WayringDrmLease) void {
    self.protocol_server.removeGlobal(self.global orelse unreachable) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}

pub fn globalFilter(self: *WayringDrmLease, client: *const server.Client, global: *const server.Server.Global) bool {
    return global.visibility() != .restricted or client.isAuthorizedDirectPeer(self.authorized_uid);
}

/// Adds a fresh generation. Names and descriptions are copied.
pub fn addConnector(self: *WayringDrmLease, value: Connector) !void {
    for (self.connectors.items) |item| if (item.present and item.snapshot.identity == value.identity) return error.AlreadyPresent;
    const name = try self.allocator.dupe(u8, value.name);
    errdefer self.allocator.free(name);
    const description = try self.allocator.dupe(u8, value.description);
    errdefer self.allocator.free(description);
    self.generation +%= 1;
    if (self.generation == 0) self.generation = 1;
    try self.connectors.append(self.allocator, .{ .snapshot = .{ .identity = value.identity, .connector_id = value.connector_id, .name = name, .description = description }, .generation = self.generation });
    if (!self.suspended) for (self.devices.items) |device| if (!device.released and device.initialized) {
        try self.advertise(device, &self.connectors.items[self.connectors.items.len - 1]);
        protocol.wp_drm_lease_device_v1.@"send:done"(&device.resource) catch eventFailed(device.client, &device.resource.runtime, "advertising connector");
    };
}

pub fn removeConnector(self: *WayringDrmLease, identity: u64) void {
    for (self.connectors.items) |*item| if (item.present and item.snapshot.identity == identity) {
        item.present = false;
        for (self.leases.items) |lease| for (lease.connectors) |requested| {
            if (requested.identity == identity) {
                self.finishLease(lease);
                break;
            }
        };
        for (self.offers.items) |offer| if (offer.identity == identity and offer.generation == item.generation and offer.current) {
            offer.current = false;
            protocol.wp_drm_lease_connector_v1.@"send:withdrawn"(&offer.resource) catch eventFailed(offer.device.client, &offer.resource.runtime, "withdrawing connector");
        };
        for (self.devices.items) |device| if (!device.released and device.initialized) protocol.wp_drm_lease_device_v1.@"send:done"(&device.resource) catch eventFailed(device.client, &device.resource.runtime, "finishing connector withdrawal");
        return;
    };
}

pub fn suspendLeasing(self: *WayringDrmLease) void {
    if (self.suspended) return;
    self.suspended = true;
    for (self.leases.items) |lease| self.finishLease(lease);
    for (self.offers.items) |offer| if (offer.current) {
        offer.current = false;
        protocol.wp_drm_lease_connector_v1.@"send:withdrawn"(&offer.resource) catch eventFailed(offer.device.client, &offer.resource.runtime, "suspending connector");
    };
    for (self.devices.items) |device| if (!device.released and device.initialized) protocol.wp_drm_lease_device_v1.@"send:done"(&device.resource) catch eventFailed(device.client, &device.resource.runtime, "suspending lease device");
}

pub fn resumeLeasing(self: *WayringDrmLease) !void {
    if (!self.suspended) return;
    self.suspended = false;
    // A resume is a new offer generation even when backend identities persist.
    for (self.connectors.items) |*item| if (item.present) {
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        item.generation = self.generation;
        for (self.devices.items) |device| if (!device.released and device.initialized) try self.advertise(device, item);
    };
    for (self.devices.items) |device| if (!device.released) {
        if (!device.initialized) {
            _ = try self.initializeDevice(device);
        } else {
            protocol.wp_drm_lease_device_v1.@"send:done"(&device.resource) catch eventFailed(device.client, &device.resource.runtime, "resuming lease device");
        }
    };
}

fn bind(client: *server.Client, id: u32, version: u32, self: *WayringDrmLease) !void {
    if (version != 1) return error.InvalidVersion;
    if (!client.isAuthorizedDirectPeer(self.authorized_uid)) return error.Unauthorized;
    try self.devices.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Device);
    errdefer self.allocator.destroy(value);
    value.* = .{ .owner = self, .client = client, .resource = .init(self.allocator, id, 1, .client, client.ownerHooks()) };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Device, value, deviceRequest, null);
    try client.materialize(&value.resource.runtime);
    self.devices.appendAssumeCapacity(value);
    if (!self.suspended) _ = self.initializeDevice(value) catch {
        client.postOutOfMemory(&value.resource.runtime, "initializing DRM lease device");
        return;
    };
}

fn initializeDevice(self: *WayringDrmLease, value: *Device) !bool {
    if (value.released or value.initialized or self.suspended) return false;
    const fd = self.authority.openFd(self.authority.context) catch return false;
    defer _ = std.c.close(fd);
    protocol.wp_drm_lease_device_v1.@"send:drm_fd"(&value.resource, fd) catch {
        eventFailed(value.client, &value.resource.runtime, "queueing DRM lease device fd");
        return error.EventFailed;
    };
    value.initialized = true;
    if (!self.suspended) for (self.connectors.items) |*item| if (item.present) try self.advertise(value, item);
    protocol.wp_drm_lease_device_v1.@"send:done"(&value.resource) catch eventFailed(value.client, &value.resource.runtime, "finishing lease device snapshot");
    return true;
}

fn advertise(self: *WayringDrmLease, device: *Device, item: *const Generation) !void {
    try self.offers.ensureUnusedCapacity(self.allocator, 1);
    const id = try device.client.reserveServerId();
    errdefer device.client.rollbackServerId(id);
    const offer = try self.allocator.create(Offer);
    errdefer self.allocator.destroy(offer);
    offer.* = .{ .owner = self, .device = device, .resource = .init(self.allocator, id, 1, .server, device.client.ownerHooks()), .identity = item.snapshot.identity, .generation = item.generation };
    errdefer {
        offer.resource.destroy();
        offer.resource.deinit();
    }
    try offer.resource.setHandler(Offer, offer, offerRequest, null);
    try device.client.materializeServer(&offer.resource.runtime);
    self.offers.appendAssumeCapacity(offer);
    protocol.wp_drm_lease_device_v1.@"send:connector"(&device.resource, id) catch return eventFailed(device.client, &device.resource.runtime, "queueing lease connector");
    protocol.wp_drm_lease_connector_v1.@"send:name"(&offer.resource, item.snapshot.name) catch return eventFailed(device.client, &offer.resource.runtime, "queueing connector name");
    protocol.wp_drm_lease_connector_v1.@"send:description"(&offer.resource, item.snapshot.description) catch return eventFailed(device.client, &offer.resource.runtime, "queueing connector description");
    protocol.wp_drm_lease_connector_v1.@"send:connector_id"(&offer.resource, item.snapshot.connector_id) catch return eventFailed(device.client, &offer.resource.runtime, "queueing connector id");
    protocol.wp_drm_lease_connector_v1.@"send:done"(&offer.resource) catch eventFailed(device.client, &offer.resource.runtime, "finishing connector snapshot");
}

fn deviceRequest(_: *protocol.wp_drm_lease_device_v1.Resource, request: protocol.wp_drm_lease_device_v1.Request, value: *Device) !void {
    if (!value.client.isAuthorizedDirectPeer(value.owner.authorized_uid)) return error.Unauthorized;
    switch (request) {
        .create_lease_request => |args| try value.owner.createRequest(value, args.id),
        .release => value.owner.releaseDevice(value),
    }
}

fn createRequest(self: *WayringDrmLease, device: *Device, id: u32) !void {
    try self.requests.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Request);
    errdefer self.allocator.destroy(value);
    value.* = .{ .owner = self, .device = device, .resource = .init(self.allocator, id, 1, .client, device.client.ownerHooks()) };
    errdefer {
        value.connectors.deinit(self.allocator);
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Request, value, requestRequest, null);
    try device.client.materialize(&value.resource.runtime);
    self.requests.appendAssumeCapacity(value);
}

fn requestRequest(_: *protocol.wp_drm_lease_request_v1.Resource, request: protocol.wp_drm_lease_request_v1.Request, value: *Request) !void {
    switch (request) {
        .request_connector => |args| value.owner.requestConnector(value, args.connector),
        .submit => |args| try value.owner.submit(value, args.id),
    }
}

fn requestConnector(self: *WayringDrmLease, request: *Request, object_id: u32) void {
    const installed = request.device.client.lookup(object_id) orelse return requestError(request, protocol.wp_drm_lease_request_v1.@"error".wrong_device, "connector is not a live offer from this device");
    const offer = blk: {
        for (self.offers.items) |candidate| {
            if (candidate.device == request.device and candidate.resource.id() == object_id and installed == &candidate.resource.runtime and candidate.resource.runtime.state() == .live) break :blk candidate;
        }
        return requestError(request, protocol.wp_drm_lease_request_v1.@"error".wrong_device, "connector is not a live offer from this device");
    };
    for (request.connectors.items) |requested| if (requested.identity == offer.identity) return requestError(request, protocol.wp_drm_lease_request_v1.@"error".duplicate_connector, "connector was requested twice");
    request.connectors.append(self.allocator, .{ .identity = offer.identity, .generation = offer.generation }) catch request.device.client.postOutOfMemory(&request.resource.runtime, "recording lease connector");
}

fn submit(self: *WayringDrmLease, request: *Request, id: u32) !void {
    if (request.connectors.items.len == 0) return requestError(request, protocol.wp_drm_lease_request_v1.@"error".empty_lease, "lease has no connectors");
    try self.leases.ensureUnusedCapacity(self.allocator, 1);
    const lease = try self.allocator.create(Lease);
    errdefer self.allocator.destroy(lease);
    const connectors = try self.allocator.dupe(Requested, request.connectors.items);
    errdefer self.allocator.free(connectors);
    lease.* = .{ .owner = self, .device = request.device, .resource = .init(self.allocator, id, 1, .client, request.device.client.ownerHooks()), .connectors = connectors };
    errdefer {
        lease.resource.destroy();
        lease.resource.deinit();
    }
    try lease.resource.setHandler(Lease, lease, leaseRequest, null);
    try request.device.client.materialize(&lease.resource.runtime);
    self.leases.appendAssumeCapacity(lease);
    var identities: std.ArrayList(u64) = .empty;
    defer identities.deinit(self.allocator);
    try identities.ensureTotalCapacity(self.allocator, connectors.len);
    var valid = !self.suspended;
    for (connectors) |requested| {
        valid = valid and self.generationCurrent(requested.identity, requested.generation);
        identities.appendAssumeCapacity(requested.identity);
    }
    if (!valid) {
        self.destroyRequest(request);
        return self.denyLease(lease);
    }
    const result = self.authority.grant(self.authority.context, identities.items) catch {
        self.destroyRequest(request);
        return self.denyLease(lease);
    };
    self.destroyRequest(request);
    lease.grant_identity = result.identity;
    var changed = false;
    for (connectors) |requested| for (self.offers.items) |offer| {
        if (offer.identity == requested.identity and offer.current) {
            offer.current = false;
            changed = true;
            protocol.wp_drm_lease_connector_v1.@"send:withdrawn"(&offer.resource) catch eventFailed(offer.device.client, &offer.resource.runtime, "withdrawing leased connector");
        }
    };
    if (changed) self.sendDone();
    defer _ = std.c.close(result.fd);
    protocol.wp_drm_lease_v1.@"send:lease_fd"(&lease.resource, result.fd) catch {
        self.finishLease(lease);
        return eventFailed(lease.device.client, &lease.resource.runtime, "queueing granted lease fd");
    };
}

fn generationCurrent(self: *WayringDrmLease, identity: u64, generation: u64) bool {
    for (self.connectors.items) |item| if (item.present and item.snapshot.identity == identity and item.generation == generation) return true;
    return false;
}

fn leaseRequest(_: *protocol.wp_drm_lease_v1.Resource, _: protocol.wp_drm_lease_v1.Request, value: *Lease) !void {
    value.owner.destroyLease(value);
}
fn offerRequest(_: *protocol.wp_drm_lease_connector_v1.Resource, _: protocol.wp_drm_lease_connector_v1.Request, value: *Offer) !void {
    value.owner.destroyOffer(value);
}

pub fn revoke(self: *WayringDrmLease, grant_identity: u64) void {
    for (self.leases.items) |lease| if (lease.grant_identity == grant_identity) return self.finishLease(lease);
}

fn denyLease(_: *WayringDrmLease, lease: *Lease) void {
    if (lease.finished) return;
    std.debug.assert(lease.grant_identity == null);
    lease.finished = true;
    if (lease.resource.runtime.state() == .live) protocol.wp_drm_lease_v1.@"send:finished"(&lease.resource) catch eventFailed(lease.device.client, &lease.resource.runtime, "denying lease");
}

fn finishLease(self: *WayringDrmLease, lease: *Lease) void {
    if (lease.finished) return;
    lease.finished = true;
    if (lease.grant_identity) |identity| {
        self.authority.revoke(self.authority.context, identity);
        lease.grant_identity = null;
    }
    if (lease.resource.runtime.state() == .live) protocol.wp_drm_lease_v1.@"send:finished"(&lease.resource) catch eventFailed(lease.device.client, &lease.resource.runtime, "finishing lease");
    if (!self.suspended) {
        var changed = false;
        for (lease.connectors) |requested| for (self.connectors.items) |*item| {
            if (item.present and item.snapshot.identity == requested.identity) {
                self.generation +%= 1;
                if (self.generation == 0) self.generation = 1;
                item.generation = self.generation;
                for (self.devices.items) |device| if (!device.released and device.initialized) self.advertise(device, item) catch {
                    device.client.postOutOfMemory(&device.resource.runtime, "readvertising released DRM connector");
                    continue;
                };
                changed = true;
            }
        };
        if (changed) self.sendDone();
    }
}

fn releaseDevice(self: *WayringDrmLease, device: *Device) void {
    if (device.released) return;
    device.released = true;
    protocol.wp_drm_lease_device_v1.@"send:released"(&device.resource) catch eventFailed(device.client, &device.resource.runtime, "releasing lease device");
    device.resource.destroy();
    device.resource.deinit();
    self.maybeDestroyReleasedDevice(device);
}

fn sendDone(self: *WayringDrmLease) void {
    for (self.devices.items) |device| if (!device.released and device.initialized)
        protocol.wp_drm_lease_device_v1.@"send:done"(&device.resource) catch eventFailed(device.client, &device.resource.runtime, "finishing connector update");
}

pub fn destroyClientResources(self: *WayringDrmLease, client: *server.Client) void {
    var i = self.requests.items.len;
    while (i > 0) {
        i -= 1;
        if (self.requests.items[i].device.client == client) self.destroyRequest(self.requests.items[i]);
    }
    i = self.leases.items.len;
    while (i > 0) {
        i -= 1;
        if (self.leases.items[i].device.client == client) self.destroyLease(self.leases.items[i]);
    }
    i = self.offers.items.len;
    while (i > 0) {
        i -= 1;
        if (self.offers.items[i].device.client == client) self.destroyOffer(self.offers.items[i]);
    }
    i = self.devices.items.len;
    while (i > 0) {
        i -= 1;
        if (self.devices.items[i].client == client) self.destroyDevice(self.devices.items[i]);
    }
}

fn destroyRequest(self: *WayringDrmLease, value: *Request) void {
    const device = value.device;
    _ = self.requests.swapRemove(std.mem.indexOfScalar(*Request, self.requests.items, value).?);
    value.connectors.deinit(self.allocator);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
    self.maybeDestroyReleasedDevice(device);
}
fn destroyOffer(self: *WayringDrmLease, value: *Offer) void {
    const device = value.device;
    _ = self.offers.swapRemove(std.mem.indexOfScalar(*Offer, self.offers.items, value).?);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
    self.maybeDestroyReleasedDevice(device);
}
fn destroyLease(self: *WayringDrmLease, value: *Lease) void {
    const device = value.device;
    self.finishLease(value);
    _ = self.leases.swapRemove(std.mem.indexOfScalar(*Lease, self.leases.items, value).?);
    self.allocator.free(value.connectors);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
    self.maybeDestroyReleasedDevice(device);
}
fn maybeDestroyReleasedDevice(self: *WayringDrmLease, device: *Device) void {
    if (!device.released) return;
    for (self.requests.items) |value| if (value.device == device) return;
    for (self.offers.items) |value| if (value.device == device) return;
    for (self.leases.items) |value| if (value.device == device) return;
    self.destroyDevice(device);
}
fn destroyDevice(self: *WayringDrmLease, value: *Device) void {
    _ = self.devices.swapRemove(std.mem.indexOfScalar(*Device, self.devices.items, value).?);
    if (!value.released) {
        value.resource.destroy();
        value.resource.deinit();
    }
    self.allocator.destroy(value);
}

pub fn deinit(self: *WayringDrmLease) void {
    std.debug.assert(self.global == null and self.devices.items.len == 0 and self.offers.items.len == 0 and self.requests.items.len == 0 and self.leases.items.len == 0);
    for (self.connectors.items) |item| {
        self.allocator.free(item.snapshot.name);
        self.allocator.free(item.snapshot.description);
    }
    self.connectors.deinit(self.allocator);
    self.devices.deinit(self.allocator);
    self.offers.deinit(self.allocator);
    self.requests.deinit(self.allocator);
    self.leases.deinit(self.allocator);
    self.* = undefined;
}

fn requestError(value: *Request, code: i64, message: []const u8) void {
    value.device.client.postProtocolError(&value.resource.runtime, @intCast(code), message);
}
fn eventFailed(client: *server.Client, resource: *server.Resource, _: []const u8) void {
    client.postOutOfMemory(resource, "queueing DRM lease event");
}

test "generated DRM lease descriptor and connector generations are stable" {
    try std.testing.expectEqualStrings("wp_drm_lease_device_v1", protocol.wp_drm_lease_device_v1.interface.name);
    try std.testing.expectEqualStrings("lease_fd", protocol.wp_drm_lease_v1.event_messages[0].name);
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    const Fake = struct {
        fn open(_: *anyopaque) !std.posix.fd_t {
            return error.NoDevice;
        }
        fn grant(_: *anyopaque, _: []const u64) !Grant {
            return error.Denied;
        }
        fn revoke(_: *anyopaque, _: u64) void {}
    };
    var context: u8 = 0;
    var adapter: WayringDrmLease = undefined;
    adapter.init(std.testing.allocator, &host, 42, .{ .context = &context, .openFd = Fake.open, .grant = Fake.grant, .revoke = Fake.revoke });
    defer adapter.deinit();
    try adapter.addConnector(.{ .identity = 7, .connector_id = 11, .name = "DP-1", .description = "display" });
    const first = adapter.connectors.items[0].generation;
    adapter.removeConnector(7);
    try adapter.addConnector(.{ .identity = 7, .connector_id = 11, .name = "DP-1", .description = "display" });
    try std.testing.expect(adapter.connectors.items[1].generation != first);
    try std.testing.expect(!adapter.generationCurrent(7, first));
    try std.testing.expect(adapter.generationCurrent(7, adapter.connectors.items[1].generation));
}

const TestAuthority = struct {
    open_fails: bool = false,
    grant_fails: bool = false,
    grant_calls: usize = 0,
    revoke_calls: usize = 0,

    fn open(context: *anyopaque) !std.posix.fd_t {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.open_fails) return error.NoDevice;
        return duplicateStdout();
    }

    fn grant(context: *anyopaque, identities: []const u64) !Grant {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.grant_calls += 1;
        if (self.grant_fails) return error.Denied;
        try std.testing.expectEqualSlices(u64, &.{7}, identities);
        return .{ .identity = 91, .fd = try duplicateStdout() };
    }

    fn revoke(context: *anyopaque, identity: u64) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        std.testing.expectEqual(@as(u64, 91), identity) catch unreachable;
        self.revoke_calls += 1;
    }

    fn duplicateStdout() !std.posix.fd_t {
        const fd = std.c.dup(1);
        if (fd < 0) return error.DuplicateFailed;
        return fd;
    }
};

const TestHarness = struct {
    host: server.Server,
    authority: TestAuthority,
    adapter: WayringDrmLease,
    managed: *server.CoreClient,

    fn init(self: *@This(), authority: TestAuthority) !void {
        self.host = .init(std.testing.allocator);
        self.authority = authority;
        self.adapter.init(std.testing.allocator, &self.host, 42, .{
            .context = &self.authority,
            .openFd = TestAuthority.open,
            .grant = TestAuthority.grant,
            .revoke = TestAuthority.revoke,
        });
        self.managed = try server.CoreClient.create(std.testing.allocator, &self.host, .{
            .credentials = .{ .pid = 1, .uid = 42, .gid = 1 },
            .transport_provenance = .direct,
        });
    }

    fn deinit(self: *@This()) void {
        self.adapter.destroyClientResources(self.client());
        self.managed.destroy();
        self.adapter.deinit();
        self.host.deinit();
    }

    fn client(self: *@This()) *server.Client {
        return self.managed.client();
    }

    fn bindDevice(self: *@This()) !void {
        const value = try std.testing.allocator.create(Device);
        errdefer std.testing.allocator.destroy(value);
        value.* = .{ .owner = &self.adapter, .client = self.client(), .resource = .init(std.testing.allocator, 2, 1, .client, self.client().ownerHooks()) };
        errdefer value.resource.deinit();
        try value.resource.setHandler(Device, value, deviceRequest, null);
        try self.client().installClientInitial(2, &value.resource.runtime);
        try self.adapter.devices.append(std.testing.allocator, value);
        if (!self.adapter.suspended) _ = try self.adapter.initializeDevice(value);
    }

    fn send(self: *@This(), object_id: u32, opcode: u16, descriptor: *const wire.MessageDescriptor, values: []const wire.Value) !void {
        var output: wire.Output = .init(std.testing.allocator);
        defer output.deinit();
        try output.enqueue(object_id, opcode, descriptor, values);
        const batch = (try output.beginSend()).?;
        try self.client().receive(batch.bytes, &.{});
        try output.completeSend(batch.token, batch.bytes.len);
        try self.client().dispatch();
    }

    fn discardEvents(self: *@This()) !void {
        while (try self.client().beginSend()) |batch|
            try self.client().completeSend(batch.token, batch.bytes.len);
    }

    fn createGrantedLease(self: *@This()) !void {
        try self.adapter.addConnector(.{ .identity = 7, .connector_id = 11, .name = "DP-1", .description = "display" });
        try self.bindDevice();
        const offer_id = self.adapter.offers.items[0].resource.id();
        try self.send(2, 0, &protocol.wp_drm_lease_device_v1.request_messages[0], &.{.{ .new_id = .{ .typed = 3 } }});
        try self.send(3, 0, &protocol.wp_drm_lease_request_v1.request_messages[0], &.{.{ .object = offer_id }});
        try self.send(3, 1, &protocol.wp_drm_lease_request_v1.request_messages[1], &.{.{ .new_id = .{ .typed = 4 } }});
    }
};

test "inactive open failure retains pending DRM lease device" {
    var harness: TestHarness = undefined;
    try harness.init(.{ .open_fails = true });
    defer harness.deinit();

    try harness.bindDevice();
    try std.testing.expectEqual(@as(usize, 1), harness.adapter.devices.items.len);
    try std.testing.expect(!harness.adapter.devices.items[0].initialized);
    try std.testing.expect(harness.client().lookup(2) != null);
    harness.adapter.suspendLeasing();
    try harness.adapter.resumeLeasing();
    try std.testing.expectEqual(@as(usize, 1), harness.adapter.devices.items.len);
    try std.testing.expect(!harness.adapter.devices.items[0].initialized);
}

test "released DRM lease device without children is reclaimed immediately" {
    var harness: TestHarness = undefined;
    try harness.init(.{ .open_fails = true });
    defer harness.deinit();

    try harness.bindDevice();
    try harness.send(2, 1, &protocol.wp_drm_lease_device_v1.request_messages[1], &.{});
    try std.testing.expectEqual(@as(usize, 0), harness.adapter.devices.items.len);
}

test "stale DRM lease submission neither changes current generation nor revokes" {
    var harness: TestHarness = undefined;
    try harness.init(.{});
    defer harness.deinit();
    try harness.adapter.addConnector(.{ .identity = 7, .connector_id = 11, .name = "DP-1", .description = "display" });
    try harness.bindDevice();
    const stale_offer = harness.adapter.offers.items[0];
    try harness.send(2, 0, &protocol.wp_drm_lease_device_v1.request_messages[0], &.{.{ .new_id = .{ .typed = 3 } }});
    try harness.send(3, 0, &protocol.wp_drm_lease_request_v1.request_messages[0], &.{.{ .object = stale_offer.resource.id() }});
    harness.adapter.removeConnector(7);
    try harness.adapter.addConnector(.{ .identity = 7, .connector_id = 12, .name = "DP-2", .description = "replacement" });
    const current_generation = harness.adapter.connectors.items[1].generation;

    try harness.send(3, 1, &protocol.wp_drm_lease_request_v1.request_messages[1], &.{.{ .new_id = .{ .typed = 4 } }});
    try std.testing.expectEqual(@as(usize, 0), harness.authority.grant_calls);
    try std.testing.expectEqual(@as(usize, 0), harness.authority.revoke_calls);
    try std.testing.expectEqual(current_generation, harness.adapter.connectors.items[1].generation);
    try std.testing.expect(harness.adapter.leases.items[0].finished);
}

test "device release preserves child lease and revoke finish is exact once" {
    var harness: TestHarness = undefined;
    try harness.init(.{});
    defer harness.deinit();
    try harness.createGrantedLease();
    try harness.discardEvents();

    try harness.send(2, 1, &protocol.wp_drm_lease_device_v1.request_messages[1], &.{});
    try std.testing.expectEqual(@as(usize, 1), harness.adapter.leases.items.len);
    try std.testing.expect(!harness.adapter.leases.items[0].finished);
    try std.testing.expectEqual(@as(usize, 0), harness.authority.revoke_calls);

    harness.adapter.revoke(91);
    harness.adapter.revoke(91);
    try std.testing.expect(harness.adapter.leases.items[0].finished);
    try std.testing.expectEqual(@as(usize, 1), harness.authority.revoke_calls);
    try harness.send(4, 0, &protocol.wp_drm_lease_v1.request_messages[0], &.{});
    try std.testing.expectEqual(@as(usize, 0), harness.adapter.leases.items.len);
    try std.testing.expectEqual(@as(usize, 1), harness.authority.revoke_calls);
}
