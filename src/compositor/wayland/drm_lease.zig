//! DRM connector discovery and lease lifetime protocol.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const DrmOutput = @import("../backend/drm.zig");
const SecurityContext = @import("security_context.zig");

const wl = wayland.server.wl;
const wp = wayland.server.wp;

allocator: std.mem.Allocator,
global: *wl.Global,
security_context: *SecurityContext,
listener: Listener,
resumed: bool,
connectors: std.ArrayList(*Connector),
devices: std.ArrayList(*Device),
offers: std.ArrayList(*Offer),
requests: std.ArrayList(*Request),
leases: std.ArrayList(*Lease),

pub const Grant = struct { fd: std.posix.fd_t, lessee_id: u32 };

pub const Listener = struct {
    context: *anyopaque,
    open_fd: *const fn (*anyopaque) ?std.posix.fd_t,
    grant: *const fn (*anyopaque, []const *DrmOutput) ?Grant,
    revoke: *const fn (*anyopaque, u32) void,
};

const Connector = struct {
    manager: *Self,
    connector_id: u32,
    output: ?*DrmOutput,
    name: [:0]u8,
    description: [:0]u8,
    generation: u64 = 0,
    lease: ?*Lease = null,

    fn available(self: *const Connector) bool {
        return self.output != null and self.lease == null and self.manager.resumed;
    }
};

const Device = struct {
    manager: *Self,
    resource: *wp.DrmLeaseDeviceV1,
    initialized: bool = false,
};

const Offer = struct {
    manager: *Self,
    resource: *wp.DrmLeaseConnectorV1,
    connector: *Connector,
    generation: u64,
    active: bool = true,
};

const Requested = struct { connector: *Connector, generation: u64 };

const Request = struct {
    manager: *Self,
    resource: *wp.DrmLeaseRequestV1,
    connectors: std.ArrayList(Requested) = .empty,
    valid: bool = true,

    fn create(device: *Device, id: u32) void {
        const manager = device.manager;
        const resource = wp.DrmLeaseRequestV1.create(
            device.resource.getClient(),
            1,
            id,
        ) catch {
            device.resource.postNoMemory();
            return;
        };
        const self = manager.allocator.create(Request) catch {
            resource.destroy();
            device.resource.postNoMemory();
            return;
        };
        self.* = .{ .manager = manager, .resource = resource };
        manager.requests.append(manager.allocator, self) catch {
            manager.allocator.destroy(self);
            resource.destroy();
            device.resource.postNoMemory();
            return;
        };
        resource.setHandler(*Request, handleRequest, handleDestroy, self);
    }

    fn handleRequest(resource: *wp.DrmLeaseRequestV1, request: wp.DrmLeaseRequestV1.Request, self: *Request) void {
        switch (request) {
            .request_connector => |requested| self.add(resource, requested.connector),
            .submit => |submission| self.submit(resource, submission.id),
        }
    }

    fn add(self: *Request, resource: *wp.DrmLeaseRequestV1, connector_resource: *wp.DrmLeaseConnectorV1) void {
        const data = connector_resource.getUserData() orelse {
            resource.postError(.wrong_device, "invalid DRM lease connector");
            return;
        };
        const offer: *Offer = @ptrCast(@alignCast(data));
        if (offer.manager != self.manager or connector_resource.getClient() != resource.getClient()) {
            resource.postError(.wrong_device, "connector belongs to another DRM lease device");
            return;
        }
        for (self.connectors.items) |item| if (item.connector == offer.connector) {
            resource.postError(.duplicate_connector, "connector was requested twice");
            return;
        };
        self.connectors.append(self.manager.allocator, .{
            .connector = offer.connector,
            .generation = offer.generation,
        }) catch {
            resource.postNoMemory();
            return;
        };
        self.valid = self.valid and offer.active;
    }

    fn submit(self: *Request, resource: *wp.DrmLeaseRequestV1, id: u32) void {
        const manager = self.manager;
        if (self.connectors.items.len == 0) {
            resource.postError(.empty_lease, "lease request contains no connectors");
            return;
        }
        const lease_resource = wp.DrmLeaseV1.create(resource.getClient(), 1, id) catch {
            resource.postNoMemory();
            return;
        };
        const lease = manager.allocator.create(Lease) catch {
            lease_resource.destroy();
            resource.postNoMemory();
            return;
        };
        const connectors = manager.allocator.alloc(*Connector, self.connectors.items.len) catch {
            manager.allocator.destroy(lease);
            lease_resource.destroy();
            resource.postNoMemory();
            return;
        };
        const outputs = manager.allocator.alloc(*DrmOutput, self.connectors.items.len) catch {
            manager.allocator.free(connectors);
            manager.allocator.destroy(lease);
            lease_resource.destroy();
            resource.postNoMemory();
            return;
        };
        var valid = self.valid;
        for (self.connectors.items, connectors, outputs) |item, *connector, *output| {
            connector.* = item.connector;
            const requested_output = item.connector.output orelse {
                valid = false;
                output.* = undefined;
                continue;
            };
            output.* = requested_output;
            valid = valid and requestValid(item.generation, item.connector.generation, item.connector.available());
        }
        lease.* = .{ .manager = manager, .resource = lease_resource, .connectors = connectors, .outputs = outputs };
        manager.leases.append(manager.allocator, lease) catch {
            manager.allocator.free(outputs);
            manager.allocator.free(connectors);
            manager.allocator.destroy(lease);
            lease_resource.destroy();
            resource.postNoMemory();
            return;
        };
        lease_resource.setHandler(*Lease, Lease.handleRequest, Lease.handleDestroy, lease);
        resource.destroy();
        if (!valid) {
            lease.finished = true;
            lease_resource.sendFinished();
            return;
        }
        const grant = manager.listener.grant(manager.listener.context, outputs) orelse {
            lease.finished = true;
            lease_resource.sendFinished();
            return;
        };
        lease.lessee_id = grant.lessee_id;
        for (connectors) |connector| connector.lease = lease;
        var changed = false;
        for (connectors) |connector| {
            changed = manager.withdrawWithoutDone(connector) or changed;
        }
        if (changed) manager.sendDone();
        lease_resource.sendLeaseFd(grant.fd);
        _ = std.c.close(grant.fd);
    }

    fn handleDestroy(_: *wp.DrmLeaseRequestV1, self: *Request) void {
        self.connectors.deinit(self.manager.allocator);
        removePtr(Request, &self.manager.requests, self);
        self.manager.allocator.destroy(self);
    }
};

const Lease = struct {
    manager: *Self,
    resource: *wp.DrmLeaseV1,
    connectors: []*Connector,
    outputs: []*DrmOutput,
    lessee_id: ?u32 = null,
    finished: bool = false,

    fn handleRequest(resource: *wp.DrmLeaseV1, request: wp.DrmLeaseV1.Request, _: *Lease) void {
        switch (request) {
            .destroy => resource.destroy(),
        }
    }

    fn handleDestroy(_: *wp.DrmLeaseV1, self: *Lease) void {
        if (!self.finished) self.manager.finishLease(self, true, false);
        removePtr(Lease, &self.manager.leases, self);
        self.manager.allocator.free(self.outputs);
        self.manager.allocator.free(self.connectors);
        self.manager.allocator.destroy(self);
    }
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    security_context: *SecurityContext,
    outputs: []const *DrmOutput,
    listener: Listener,
) !void {
    self.* = .{
        .allocator = allocator,
        .global = undefined,
        .security_context = security_context,
        .listener = listener,
        .resumed = true,
        .connectors = .empty,
        .devices = .empty,
        .offers = .empty,
        .requests = .empty,
        .leases = .empty,
    };
    errdefer self.deinitStorage();
    for (outputs) |output| _ = try self.addConnectorStorage(output);
    self.global = try wl.Global.create(display, wp.DrmLeaseDeviceV1, 1, *Self, self, bind);
    errdefer self.global.destroy();
    try security_context.restrictGlobal(self.global);
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.devices.items.len == 0);
    std.debug.assert(self.offers.items.len == 0);
    std.debug.assert(self.requests.items.len == 0);
    std.debug.assert(self.leases.items.len == 0);
    self.security_context.unrestrictGlobal(self.global);
    self.global.destroy();
    self.deinitStorage();
    self.* = undefined;
}

fn deinitStorage(self: *Self) void {
    for (self.connectors.items) |connector| {
        self.allocator.free(connector.name);
        self.allocator.free(connector.description);
        self.allocator.destroy(connector);
    }
    self.connectors.deinit(self.allocator);
    self.devices.deinit(self.allocator);
    self.offers.deinit(self.allocator);
    self.requests.deinit(self.allocator);
    self.leases.deinit(self.allocator);
}

pub fn addConnector(self: *Self, output: *DrmOutput) !void {
    if (self.findConnector(output.connector_id)) |connector| {
        std.debug.assert(connector.output == null);
        const name = try self.allocator.dupeZ(u8, output.name());
        errdefer self.allocator.free(name);
        const description = try self.allocator.dupeZ(u8, output.description());
        self.allocator.free(connector.name);
        self.allocator.free(connector.description);
        connector.name = name;
        connector.description = description;
        connector.output = output;
        if (connector.available()) self.advertise(connector);
        return;
    }
    const connector = try self.addConnectorStorage(output);
    if (connector.available()) self.advertise(connector);
}

fn addConnectorStorage(self: *Self, output: *DrmOutput) !*Connector {
    std.debug.assert(self.findConnector(output.connector_id) == null);
    const connector = try self.allocator.create(Connector);
    errdefer self.allocator.destroy(connector);
    const name = try self.allocator.dupeZ(u8, output.name());
    errdefer self.allocator.free(name);
    const description = try self.allocator.dupeZ(u8, output.description());
    errdefer self.allocator.free(description);
    connector.* = .{ .manager = self, .connector_id = output.connector_id, .output = output, .name = name, .description = description };
    try self.connectors.append(self.allocator, connector);
    return connector;
}

pub fn removeConnector(self: *Self, output: *DrmOutput) void {
    const connector = self.findConnector(output.connector_id) orelse return;
    if (connector.output != output) return;
    connector.output = null;
    self.finishLeaseFor(connector, true);
    if (self.withdrawWithoutDone(connector)) self.sendDone();
}

pub fn @"suspend"(self: *Self) void {
    if (!self.resumed) return;
    self.resumed = false;
    for (self.leases.items) |lease| self.finishLease(lease, true, true);
    var changed = false;
    for (self.connectors.items) |connector| changed = self.withdrawWithoutDone(connector) or changed;
    if (changed) self.sendDone();
}

pub fn @"resume"(self: *Self) void {
    if (self.resumed) return;
    self.resumed = true;
    var changed = false;
    for (self.connectors.items) |connector| if (connector.available()) {
        self.advertiseWithoutDone(connector);
        changed = true;
    };
    if (changed) self.sendDone();
    for (self.devices.items) |device| if (!device.initialized) self.initializeDevice(device);
}

pub fn leaseRevoked(self: *Self, lessee_id: u32) void {
    for (self.leases.items) |lease| if (lease.lessee_id == lessee_id) {
        self.finishLease(lease, false, true);
        return;
    };
}

pub fn outputLeased(self: *const Self, output: *DrmOutput) bool {
    const connector = self.findConnector(output.connector_id) orelse return false;
    return connector.output == output and connector.lease != null;
}

fn findConnector(self: *const Self, id: u32) ?*Connector {
    for (self.connectors.items) |connector| if (connector.connector_id == id) return connector;
    return null;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = wp.DrmLeaseDeviceV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    const device = self.allocator.create(Device) catch {
        resource.destroy();
        client.postNoMemory();
        return;
    };
    device.* = .{ .manager = self, .resource = resource };
    self.devices.append(self.allocator, device) catch {
        self.allocator.destroy(device);
        resource.destroy();
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Device, handleDeviceRequest, handleDeviceDestroy, device);
    if (self.resumed) self.initializeDevice(device);
}

fn initializeDevice(self: *Self, device: *Device) void {
    if (device.initialized or !self.resumed) return;
    const fd = self.listener.open_fd(self.listener.context) orelse return;
    device.resource.sendDrmFd(fd);
    _ = std.c.close(fd);
    device.initialized = true;
    for (self.connectors.items) |connector| if (connector.available()) self.createOffer(device, connector);
    device.resource.sendDone();
}

fn handleDeviceRequest(resource: *wp.DrmLeaseDeviceV1, request: wp.DrmLeaseDeviceV1.Request, device: *Device) void {
    switch (request) {
        .release => resource.destroySendReleased(),
        .create_lease_request => |create| Request.create(device, create.id),
    }
}

fn handleDeviceDestroy(_: *wp.DrmLeaseDeviceV1, device: *Device) void {
    removePtr(Device, &device.manager.devices, device);
    device.manager.allocator.destroy(device);
}

fn advertise(self: *Self, connector: *Connector) void {
    self.advertiseWithoutDone(connector);
    self.sendDone();
}

fn advertiseWithoutDone(self: *Self, connector: *Connector) void {
    connector.generation +%= 1;
    if (connector.generation == 0) connector.generation = 1;
    for (self.devices.items) |device| if (device.initialized) self.createOffer(device, connector);
}

fn createOffer(self: *Self, device: *Device, connector: *Connector) void {
    const resource = wp.DrmLeaseConnectorV1.create(device.resource.getClient(), 1, 0) catch {
        device.resource.postNoMemory();
        return;
    };
    const offer = self.allocator.create(Offer) catch {
        resource.destroy();
        device.resource.postNoMemory();
        return;
    };
    offer.* = .{ .manager = self, .resource = resource, .connector = connector, .generation = connector.generation };
    self.offers.append(self.allocator, offer) catch {
        self.allocator.destroy(offer);
        resource.destroy();
        device.resource.postNoMemory();
        return;
    };
    resource.setHandler(*Offer, handleOfferRequest, handleOfferDestroy, offer);
    device.resource.sendConnector(resource);
    resource.sendName(connector.name.ptr);
    resource.sendDescription(connector.description.ptr);
    resource.sendConnectorId(connector.connector_id);
    resource.sendDone();
}

fn withdrawWithoutDone(self: *Self, connector: *Connector) bool {
    var changed = false;
    for (self.offers.items) |offer| if (offer.connector == connector and offer.active) {
        offer.active = false;
        offer.resource.sendWithdrawn();
        changed = true;
    };
    return changed;
}

fn sendDone(self: *Self) void {
    for (self.devices.items) |device| {
        if (device.initialized) {
            device.resource.sendDone();
        } else {
            self.initializeDevice(device);
        }
    }
}

fn handleOfferRequest(resource: *wp.DrmLeaseConnectorV1, request: wp.DrmLeaseConnectorV1.Request, _: *Offer) void {
    switch (request) {
        .destroy => resource.destroy(),
    }
}

fn handleOfferDestroy(_: *wp.DrmLeaseConnectorV1, offer: *Offer) void {
    removePtr(Offer, &offer.manager.offers, offer);
    offer.manager.allocator.destroy(offer);
}

fn finishLeaseFor(self: *Self, connector: *Connector, revoke: bool) void {
    if (connector.lease) |lease| self.finishLease(lease, revoke, true);
}

fn finishLease(self: *Self, lease: *Lease, revoke: bool, send_event: bool) void {
    if (lease.finished) return;
    lease.finished = true;
    if (revoke) if (lease.lessee_id) |id| self.listener.revoke(self.listener.context, id);
    if (send_event) lease.resource.sendFinished();
    for (lease.connectors) |connector| connector.lease = null;
    if (self.resumed) {
        var changed = false;
        for (lease.connectors) |connector| if (connector.available()) {
            self.advertiseWithoutDone(connector);
            changed = true;
        };
        if (changed) self.sendDone();
    }
}

fn removePtr(comptime T: type, list: *std.ArrayList(*T), value: *T) void {
    for (list.items, 0..) |item, i| if (item == value) {
        _ = list.swapRemove(i);
        return;
    };
    unreachable;
}

fn requestValid(request_generation: u64, current_generation: u64, available: bool) bool {
    return available and request_generation == current_generation;
}

test "lease request generation does not revive stale offers" {
    try std.testing.expect(requestValid(4, 4, true));
    try std.testing.expect(!requestValid(3, 4, true));
    try std.testing.expect(!requestValid(4, 4, false));
}
