//! Scanner adapter for complete output-management transactions.

const Self = @This();
const std = @import("std");
const protocol = @import("wayring-protocol");
const wayring = @import("wayring");
const Neutral = @import("../OutputManagement.zig");

const server = wayring.server;

pub const ModeSnapshot = struct { width: u32, height: u32, refresh_millihertz: i32, preferred: bool = false };
pub const Position = Neutral.Position;
pub const HeadSnapshot = struct {
    id: Neutral.Head,
    target: ?Neutral.Target = null,
    name: []const u8,
    description: []const u8 = "",
    make: []const u8 = "",
    model: []const u8 = "",
    serial_number: []const u8 = "",
    physical_width: i32 = 0,
    physical_height: i32 = 0,
    enabled: bool = true,
    x: i32 = 0,
    y: i32 = 0,
    scale_fixed: i32 = 256,
    modes: []const ModeSnapshot,
    current_mode: usize = 0,
};
pub const Listener = Neutral.Listener;

const Manager = struct { owner: *Self, client: *server.Client, resource: protocol.zwlr_output_manager_v1.Resource, generation: u64, stopped: bool = false };
const Head = struct { owner: *Self, snapshot: HeadSnapshot, reference: Neutral.HeadRef, name: []u8, description: []u8, make: []u8, model: []u8, serial_number: []u8, modes: []ModeSnapshot };
const HeadResource = struct { manager: *Manager, head: *Head, resource: protocol.zwlr_output_head_v1.Resource, modes: std.ArrayList(*ModeResource) = .empty, finished: bool = false };
const ModeResource = struct { head_resource: *HeadResource, index: usize, resource: protocol.zwlr_output_mode_v1.Resource, finished: bool = false };
const Configuration = struct { manager: *Manager, resource: protocol.zwlr_output_configuration_v1.Resource, transaction: Neutral.Transaction, heads: std.ArrayList(*ConfiguredHead) = .empty };
const Publication = struct {
    client: *server.Client,
    encoded: std.ArrayList(u8) = .empty,
    reservation: wayring.wire.PreparedBatch,
    reserved: bool = false,
};
const ConfiguredHead = struct {
    configuration: *Configuration,
    reference: Neutral.HeadRef,
    resource: ?protocol.zwlr_output_configuration_head_v1.Resource,
    position: ?Position = null,
    scale_fixed: ?i32 = null,
    mode: ?usize = null,
    custom_mode: ?Neutral.CustomMode = null,
    transform_set: bool = false,
    adaptive_sync_set: bool = false,
};

allocator: std.mem.Allocator,
protocol_server: *server.Server,
authority: *Neutral,
authorized_uid: std.os.linux.uid_t,
listener: Listener,
global: ?*const server.Server.Global = null,
heads: std.ArrayList(*Head) = .empty,
managers: std.ArrayList(*Manager) = .empty,
head_resources: std.ArrayList(*HeadResource) = .empty,
mode_resources: std.ArrayList(*ModeResource) = .empty,
configurations: std.ArrayList(*Configuration) = .empty,
next_generation: u64 = 1,
applying_configuration: bool = false,

pub fn init(self: *Self, allocator: std.mem.Allocator, protocol_server: *server.Server, authority: *Neutral, authorized_uid: std.os.linux.uid_t, listener: Listener) void {
    self.* = .{ .allocator = allocator, .protocol_server = protocol_server, .authority = authority, .authorized_uid = authorized_uid, .listener = listener };
}
pub fn publish(self: *Self) !void {
    std.debug.assert(self.global == null);
    self.global = try self.protocol_server.addGlobalWithOptions(protocol.zwlr_output_manager_v1, 4, Self, self, bind, .{ .visibility = .restricted });
}
pub fn unpublish(self: *Self) void {
    self.protocol_server.removeGlobal(self.global orelse unreachable) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}
pub fn globalFilter(self: *const Self, client: *const server.Client, global: *const server.Server.Global) bool {
    return global.visibility() != .restricted or client.isAuthorizedDirectPeer(self.authorized_uid);
}
pub fn deinit(self: *Self) void {
    std.debug.assert(self.global == null and self.managers.items.len == 0 and self.head_resources.items.len == 0 and self.mode_resources.items.len == 0 and self.configurations.items.len == 0);
    while (self.heads.items.len > 0) self.destroyHead(self.heads.pop().?);
    self.configurations.deinit(self.allocator);
    self.mode_resources.deinit(self.allocator);
    self.head_resources.deinit(self.allocator);
    self.managers.deinit(self.allocator);
    self.heads.deinit(self.allocator);
    self.* = undefined;
}

pub fn addOutput(self: *Self, snapshot: HeadSnapshot) !void {
    if (self.findHead(snapshot.id) != null or snapshot.modes.len == 0 or snapshot.current_mode >= snapshot.modes.len) return error.InvalidSnapshot;
    for (snapshot.modes) |mode| {
        if (mode.width == 0 or mode.width > std.math.maxInt(i32) or
            mode.height == 0 or mode.height > std.math.maxInt(i32) or
            mode.refresh_millihertz < 0)
            return error.InvalidSnapshot;
    }
    const value = try self.allocator.create(Head);
    errdefer self.allocator.destroy(value);
    const name = try self.allocator.dupe(u8, snapshot.name);
    errdefer self.allocator.free(name);
    const description = try self.allocator.dupe(u8, snapshot.description);
    errdefer self.allocator.free(description);
    const make = try self.allocator.dupe(u8, snapshot.make);
    errdefer self.allocator.free(make);
    const model = try self.allocator.dupe(u8, snapshot.model);
    errdefer self.allocator.free(model);
    const serial_number = try self.allocator.dupe(u8, snapshot.serial_number);
    errdefer self.allocator.free(serial_number);
    const modes = try self.allocator.dupe(ModeSnapshot, snapshot.modes);
    errdefer self.allocator.free(modes);
    value.* = .{ .owner = self, .snapshot = snapshot, .reference = try self.authority.generation(snapshot.id), .name = name, .description = description, .make = make, .model = model, .serial_number = serial_number, .modes = modes };
    value.snapshot.name = name;
    value.snapshot.description = description;
    value.snapshot.make = make;
    value.snapshot.model = model;
    value.snapshot.serial_number = serial_number;
    value.snapshot.modes = modes;
    try self.heads.append(self.allocator, value);
    for (self.managers.items) |manager| if (!manager.stopped) self.createHeadResource(manager, value) catch manager.client.postOutOfMemory(&manager.resource.runtime, "advertising output head");
    // The canonical topology owner advances the shared epoch. Attaching this
    // unpublished frontend to an already-known output must not advance it a
    // second time and invalidate mature clients.
    self.sendDone();
}
pub fn syncOutput(self: *Self, snapshot: HeadSnapshot) !void {
    // A generated apply already has one prepared atomic publication against
    // the current head resources. Canonical output observers may run during
    // that mutation; commitSnapshots updates those same resources afterward.
    if (self.applying_configuration) return;
    const old = self.findHead(snapshot.id) orelse return error.UnknownHead;
    // Replacing storage also deliberately creates a fresh generation.
    self.removeOutput(snapshot.id);
    try self.addOutput(snapshot);
    _ = old;
}
pub fn removeOutput(self: *Self, id: Neutral.Head) void {
    const head = self.findHead(id) orelse return;
    for (self.mode_resources.items) |mode| if (mode.head_resource.head == head and !mode.finished) {
        protocol.zwlr_output_mode_v1.@"send:finished"(&mode.resource) catch {};
        mode.finished = true;
    };
    for (self.head_resources.items) |resource| if (resource.head == head and !resource.finished) {
        protocol.zwlr_output_head_v1.@"send:finished"(&resource.resource) catch {};
        resource.finished = true;
    };
    self.sendDone();
    for (self.heads.items, 0..) |candidate, index| if (candidate == head) {
        _ = self.heads.swapRemove(index);
        break;
    };
    // Storage remains referenced by independently surviving resources and is
    // reclaimed when the last such resource is released.
    self.reclaimHead(head);
}

fn bind(client: *server.Client, id: u32, version: u32, self: *Self) !void {
    if (version == 0 or version > 4) return error.InvalidVersion;
    if (!client.isAuthorizedDirectPeer(self.authorized_uid)) return error.Unauthorized;
    try self.managers.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Manager);
    var storage_owned = true;
    errdefer if (storage_owned) self.allocator.destroy(value);
    value.* = .{ .owner = self, .client = client, .resource = .init(self.allocator, id, version, .client, client.ownerHooks()), .generation = self.next_generation };
    self.next_generation +%= 1;
    if (self.next_generation == 0) return error.GenerationExhausted;
    var resource_owned = true;
    errdefer if (resource_owned) {
        value.resource.destroy();
        value.resource.deinit();
    };
    try value.resource.setHandler(Manager, value, managerRequest, null);
    try client.materialize(&value.resource.runtime);
    self.managers.appendAssumeCapacity(value);
    storage_owned = false;
    resource_owned = false;
    var linked = true;
    errdefer if (linked) {
        var i = self.head_resources.items.len;
        while (i > 0) : (i -= 1) if (self.head_resources.items[i - 1].manager == value)
            self.destroyHeadResource(self.head_resources.items[i - 1]);
        self.destroyManager(value);
    };
    for (self.heads.items) |head| try self.createHeadResource(value, head);
    try protocol.zwlr_output_manager_v1.@"send:done"(&value.resource, self.authority.serial);
    linked = false;
}
fn managerRequest(resource: *protocol.zwlr_output_manager_v1.Resource, request: protocol.zwlr_output_manager_v1.Request, value: *Manager) !void {
    if (!value.client.isAuthorizedDirectPeer(value.owner.authorized_uid)) return error.Unauthorized;
    if (value.stopped) return;
    switch (request) {
        .create_configuration => |args| try value.owner.createConfiguration(value, args.id, args.serial),
        .stop => {
            try protocol.zwlr_output_manager_v1.@"send:finished"(resource);
            value.stopped = true;
        },
    }
}

fn createHeadResource(self: *Self, manager: *Manager, head: *Head) !void {
    try self.head_resources.ensureUnusedCapacity(self.allocator, 1);
    try self.mode_resources.ensureUnusedCapacity(self.allocator, head.modes.len);
    const hr = try self.allocator.create(HeadResource);
    var storage_owned = true;
    errdefer if (storage_owned) self.allocator.destroy(hr);
    const id = try manager.client.reserveServerId();
    var id_reserved = true;
    errdefer if (id_reserved) manager.client.rollbackServerId(id);
    hr.* = .{ .manager = manager, .head = head, .resource = .init(self.allocator, id, manager.resource.version(), .server, manager.client.ownerHooks()) };
    var owned = true;
    errdefer if (owned) {
        hr.resource.destroy();
        hr.resource.deinit();
        hr.modes.deinit(self.allocator);
    };
    try hr.resource.setHandler(HeadResource, hr, headRequest, null);
    try manager.client.materializeServer(&hr.resource.runtime);
    id_reserved = false;
    self.head_resources.appendAssumeCapacity(hr);
    owned = false;
    storage_owned = false;
    errdefer self.destroyHeadResource(hr);
    try protocol.zwlr_output_manager_v1.@"send:head"(&manager.resource, hr.resource.id());
    try protocol.zwlr_output_head_v1.@"send:name"(&hr.resource, head.name);
    try protocol.zwlr_output_head_v1.@"send:description"(&hr.resource, head.description);
    try protocol.zwlr_output_head_v1.@"send:physical_size"(&hr.resource, head.snapshot.physical_width, head.snapshot.physical_height);
    for (head.modes, 0..) |mode, index| try self.createModeResource(hr, mode, index);
    try protocol.zwlr_output_head_v1.@"send:enabled"(&hr.resource, @intFromBool(head.snapshot.enabled));
    if (head.snapshot.enabled) {
        try protocol.zwlr_output_head_v1.@"send:current_mode"(&hr.resource, hr.modes.items[head.snapshot.current_mode].resource.id());
        try protocol.zwlr_output_head_v1.@"send:position"(&hr.resource, head.snapshot.x, head.snapshot.y);
        try protocol.zwlr_output_head_v1.@"send:transform"(&hr.resource, 0);
        try protocol.zwlr_output_head_v1.@"send:scale"(&hr.resource, head.snapshot.scale_fixed);
    }
    if (manager.resource.version() >= 2) {
        try protocol.zwlr_output_head_v1.@"send:make"(&hr.resource, head.make);
        try protocol.zwlr_output_head_v1.@"send:model"(&hr.resource, head.model);
        if (head.serial_number.len > 0) try protocol.zwlr_output_head_v1.@"send:serial_number"(&hr.resource, head.serial_number);
    }
    if (manager.resource.version() >= 4) try protocol.zwlr_output_head_v1.@"send:adaptive_sync"(&hr.resource, 0);
}
fn createModeResource(self: *Self, hr: *HeadResource, mode: ModeSnapshot, index: usize) !void {
    const mr = try self.allocator.create(ModeResource);
    var storage_owned = true;
    errdefer if (storage_owned) self.allocator.destroy(mr);
    const id = try hr.manager.client.reserveServerId();
    var id_reserved = true;
    errdefer if (id_reserved) hr.manager.client.rollbackServerId(id);
    mr.* = .{ .head_resource = hr, .index = index, .resource = .init(self.allocator, id, @min(hr.manager.resource.version(), 3), .server, hr.manager.client.ownerHooks()) };
    var owned = true;
    errdefer if (owned) {
        mr.resource.destroy();
        mr.resource.deinit();
    };
    try mr.resource.setHandler(ModeResource, mr, modeRequest, null);
    try hr.manager.client.materializeServer(&mr.resource.runtime);
    id_reserved = false;
    try hr.modes.append(self.allocator, mr);
    var in_head = true;
    errdefer if (in_head) {
        _ = hr.modes.pop();
    };
    self.mode_resources.appendAssumeCapacity(mr);
    owned = false;
    storage_owned = false;
    in_head = false;
    errdefer self.destroyModeResource(mr);
    try protocol.zwlr_output_head_v1.@"send:mode"(&hr.resource, mr.resource.id());
    try protocol.zwlr_output_mode_v1.@"send:size"(&mr.resource, @intCast(mode.width), @intCast(mode.height));
    if (mode.refresh_millihertz > 0) try protocol.zwlr_output_mode_v1.@"send:refresh"(&mr.resource, mode.refresh_millihertz);
    if (mode.preferred) try protocol.zwlr_output_mode_v1.@"send:preferred"(&mr.resource);
}
fn headRequest(_: *protocol.zwlr_output_head_v1.Resource, request: protocol.zwlr_output_head_v1.Request, value: *HeadResource) !void {
    if (!value.manager.client.isAuthorizedDirectPeer(value.manager.owner.authorized_uid)) return error.Unauthorized;
    switch (request) {
        .release => value.manager.owner.destroyHeadResource(value),
    }
}
fn modeRequest(_: *protocol.zwlr_output_mode_v1.Resource, request: protocol.zwlr_output_mode_v1.Request, value: *ModeResource) !void {
    if (!value.head_resource.manager.client.isAuthorizedDirectPeer(value.head_resource.manager.owner.authorized_uid)) return error.Unauthorized;
    switch (request) {
        .release => value.head_resource.manager.owner.destroyModeResource(value),
    }
}

fn createConfiguration(self: *Self, manager: *Manager, id: u32, serial: u32) !void {
    try self.configurations.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Configuration);
    errdefer self.allocator.destroy(value);
    value.* = .{ .manager = manager, .resource = .init(self.allocator, id, manager.resource.version(), .client, manager.client.ownerHooks()), .transaction = self.authority.transaction(self.allocator, @intFromPtr(manager.client), manager.generation) };
    value.transaction.serial = serial;
    errdefer {
        value.transaction.deinit();
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Configuration, value, configurationRequest, null);
    try manager.client.materialize(&value.resource.runtime);
    self.configurations.appendAssumeCapacity(value);
}
fn configurationRequest(_: *protocol.zwlr_output_configuration_v1.Resource, request: protocol.zwlr_output_configuration_v1.Request, value: *Configuration) !void {
    const self = value.manager.owner;
    if (!value.manager.client.isAuthorizedDirectPeer(self.authorized_uid)) return error.Unauthorized;
    switch (request) {
        .enable_head => |a| try self.configureHead(value, a.id, a.head, true),
        .disable_head => |a| try self.configureHead(value, null, a.head, false),
        .apply => try self.execute(value, true),
        .@"test" => try self.execute(value, false),
        .destroy => self.destroyConfiguration(value),
    }
}
fn configureHead(self: *Self, config: *Configuration, id: ?u32, object: u32, enabled: bool) !void {
    const hr = self.headIdentity(config.manager, object) orelse return config.manager.client.postImplementationError(&config.resource.runtime, "configuration requires exact live adapter-owned head");
    try config.transaction.heads.ensureUnusedCapacity(config.transaction.allocator, 1);
    if (id != null) try config.heads.ensureUnusedCapacity(self.allocator, 1);
    self.authorityConfigure(config, hr.head.reference, enabled) catch |err| switch (err) {
        error.AlreadyConfigured => return config.manager.client.postProtocolError(&config.resource.runtime, @intCast(protocol.zwlr_output_configuration_v1.@"error".already_configured_head), "head configured twice"),
        else => return err,
    };
    errdefer _ = config.transaction.heads.pop();
    if (id) |new_id| try self.createConfiguredHead(config, hr.head.reference, new_id);
}
fn authorityConfigure(_: *Self, config: *Configuration, reference: Neutral.HeadRef, enabled: bool) !void {
    try config.transaction.configure(.{ .reference = reference, .enabled = enabled });
}
fn createConfiguredHead(self: *Self, config: *Configuration, reference: Neutral.HeadRef, id: u32) !void {
    const h = try self.allocator.create(ConfiguredHead);
    errdefer self.allocator.destroy(h);
    h.* = .{ .configuration = config, .reference = reference, .resource = .init(self.allocator, id, config.resource.version(), .client, config.manager.client.ownerHooks()) };
    errdefer {
        h.resource.?.destroy();
        h.resource.?.deinit();
    }
    try h.resource.?.setHandler(ConfiguredHead, h, configuredHeadRequest, null);
    try config.manager.client.materialize(&h.resource.?.runtime);
    config.heads.appendAssumeCapacity(h);
}
fn configuredHeadRequest(resource: *protocol.zwlr_output_configuration_head_v1.Resource, request: protocol.zwlr_output_configuration_head_v1.Request, value: *ConfiguredHead) !void {
    const self = value.configuration.manager.owner;
    if (!value.configuration.manager.client.isAuthorizedDirectPeer(self.authorized_uid)) return error.Unauthorized;
    switch (request) {
        .set_mode => |a| {
            const m = self.modeIdentity(value.configuration.manager, a.mode) orelse return invalid(resource, value, protocol.zwlr_output_configuration_head_v1.@"error".invalid_mode);
            if (!std.meta.eql(m.head_resource.head.reference, value.reference)) return invalid(resource, value, protocol.zwlr_output_configuration_head_v1.@"error".invalid_mode);
            if (value.mode != null or value.custom_mode != null) return invalid(resource, value, protocol.zwlr_output_configuration_head_v1.@"error".already_set);
            value.mode = m.index;
            transactionHead(value).mode_index = m.index;
        },
        .set_custom_mode => |a| {
            if (value.mode != null or value.custom_mode != null) return invalid(resource, value, protocol.zwlr_output_configuration_head_v1.@"error".already_set);
            if (a.width <= 0 or a.height <= 0 or a.refresh < 0) return invalid(resource, value, protocol.zwlr_output_configuration_head_v1.@"error".invalid_custom_mode);
            value.custom_mode = .{ .width = @intCast(a.width), .height = @intCast(a.height), .refresh_millihertz = a.refresh };
            transactionHead(value).custom_mode = value.custom_mode;
        },
        .set_position => |a| {
            if (value.position != null) return invalid(resource, value, protocol.zwlr_output_configuration_head_v1.@"error".already_set);
            value.position = .{ .x = a.x, .y = a.y };
            transactionHead(value).position = .{ .x = a.x, .y = a.y };
        },
        .set_scale => |a| {
            if (value.scale_fixed != null) return invalid(resource, value, protocol.zwlr_output_configuration_head_v1.@"error".already_set);
            if (a.scale <= 0) return invalid(resource, value, protocol.zwlr_output_configuration_head_v1.@"error".invalid_scale);
            value.scale_fixed = a.scale;
            transactionHead(value).scale = Neutral.scaleFromFixed(a.scale) catch return invalid(resource, value, protocol.zwlr_output_configuration_head_v1.@"error".invalid_scale);
        },
        .set_transform => |a| {
            if (value.transform_set) return invalid(resource, value, protocol.zwlr_output_configuration_head_v1.@"error".already_set);
            value.transform_set = true;
            if (a.transform != 0) transactionHead(value).transform_supported = false;
        },
        .set_adaptive_sync => |a| {
            if (value.adaptive_sync_set) return invalid(resource, value, protocol.zwlr_output_configuration_head_v1.@"error".already_set);
            value.adaptive_sync_set = true;
            if (a.state != 0) transactionHead(value).adaptive_sync_supported = false;
        },
    }
}
fn transactionHead(value: *ConfiguredHead) *Neutral.ConfiguredHead {
    for (value.configuration.transaction.heads.items) |*head| {
        if (std.meta.eql(head.reference, value.reference)) return head;
    }
    unreachable;
}
fn invalid(resource: *protocol.zwlr_output_configuration_head_v1.Resource, value: *ConfiguredHead, code: i64) void {
    value.configuration.manager.client.postProtocolError(&resource.runtime, @intCast(code), "invalid output configuration head");
}
fn execute(self: *Self, config: *Configuration, apply: bool) !void {
    var states: std.ArrayList(Neutral.HeadState) = .empty;
    defer states.deinit(self.allocator);
    for (self.heads.items) |head| {
        try states.append(self.allocator, .{
            .reference = head.reference,
            .target = head.snapshot.target,
            .enabled = head.snapshot.enabled,
            .x = head.snapshot.x,
            .y = head.snapshot.y,
            .scale = Neutral.scaleFromFixed(head.snapshot.scale_fixed) catch return error.InvalidScale,
            .mode_count = head.modes.len,
            .current_mode_index = head.snapshot.current_mode,
        });
    }
    var prepared = config.transaction.prepare(
        self.authority,
        @intFromPtr(config.manager.client),
        config.manager.generation,
        states.items,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidConfiguration => {
            try protocol.zwlr_output_configuration_v1.@"send:failed"(&config.resource);
            return;
        },
        else => {
            try protocol.zwlr_output_configuration_v1.@"send:cancelled"(&config.resource);
            return;
        },
    };
    defer prepared.deinit();
    if (!self.listener.test_configuration(self.listener.context, prepared.changes)) {
        try protocol.zwlr_output_configuration_v1.@"send:failed"(&config.resource);
        return;
    }
    if (!apply) {
        try protocol.zwlr_output_configuration_v1.@"send:succeeded"(&config.resource);
        return;
    }

    const expected_serial = self.authority.nextSerial();
    var publications: std.ArrayList(Publication) = .empty;
    defer {
        for (publications.items) |*publication| {
            if (publication.reserved) publication.client.cancelEventBatch(publication.reservation);
            publication.encoded.deinit(self.allocator);
        }
        publications.deinit(self.allocator);
    }
    try publications.ensureUnusedCapacity(self.allocator, self.managers.items.len);
    for (self.managers.items) |manager| {
        if (manager.stopped and manager != config.manager) continue;
        var publication: ?*Publication = null;
        for (publications.items) |*candidate| if (candidate.client == manager.client) {
            publication = candidate;
            break;
        };
        if (publication == null) {
            publications.appendAssumeCapacity(.{
                .client = manager.client,
                .reservation = undefined,
            });
            publication = &publications.items[publications.items.len - 1];
        }
        try self.encodeCommittedEvents(config, manager, prepared.changes, expected_serial, &publication.?.encoded);
    }
    for (publications.items) |*publication| {
        publication.reservation = try publication.client.prepareEventBatch(publication.encoded.items.len);
        publication.reserved = true;
    }

    const applied = blk: {
        std.debug.assert(!self.applying_configuration);
        self.applying_configuration = true;
        defer self.applying_configuration = false;
        break :blk self.listener.apply(self.listener.context, prepared.changes);
    };
    if (!applied) {
        for (publications.items) |*publication| {
            publication.client.cancelEventBatch(publication.reservation);
            publication.reserved = false;
        }
        try protocol.zwlr_output_configuration_v1.@"send:failed"(&config.resource);
        return;
    }
    if (self.authority.serial != expected_serial) _ = self.authority.changed();
    std.debug.assert(self.authority.serial == expected_serial);
    self.commitSnapshots(config, prepared.changes);
    for (publications.items) |*publication| {
        const storage = try publication.client.preparedEventStorage(publication.reservation);
        @memcpy(storage[0..publication.encoded.items.len], publication.encoded.items);
        try publication.client.publishEventBatch(publication.reservation, publication.encoded.items.len);
        publication.reserved = false;
    }
}

fn encodeCommittedEvents(self: *Self, config: *Configuration, manager: *Manager, changes: []const Neutral.Change, serial: u32, encoded: *std.ArrayList(u8)) !void {
    for (changes) |change| {
        const head = self.findTarget(change.target) orelse continue;
        for (self.head_resources.items) |advertised| {
            if (advertised.manager != manager or advertised.head != head or advertised.manager.stopped or advertised.finished) continue;
            if (change.custom_mode) |custom| {
                const mode = advertised.modes.items[change.mode_index];
                try appendEvent(self.allocator, encoded, mode.resource.id(), 0, &.{ custom.width, custom.height });
                if (custom.refresh_millihertz > 0) try appendEvent(self.allocator, encoded, mode.resource.id(), 1, &.{wireInt(custom.refresh_millihertz)});
                try appendEvent(self.allocator, encoded, advertised.resource.id(), 5, &.{mode.resource.id()});
            }
            if (change.scale.numerator != change.old_scale.numerator) {
                const fixed = configuredScale(config, head.reference) orelse return error.InvalidScale;
                try appendEvent(self.allocator, encoded, advertised.resource.id(), 8, &.{wireInt(fixed)});
            }
        }
    }
    if (!manager.stopped)
        try appendEvent(self.allocator, encoded, manager.resource.id(), 1, &.{serial});
    if (manager == config.manager)
        try appendEvent(self.allocator, encoded, config.resource.id(), 0, &.{});
}

fn wireInt(value: i32) u32 {
    return @bitCast(value);
}

fn appendEvent(allocator: std.mem.Allocator, encoded: *std.ArrayList(u8), object_id: u32, opcode: u16, arguments: []const u32) !void {
    const size: u32 = @intCast(8 + arguments.len * 4);
    try encoded.ensureUnusedCapacity(allocator, size);
    const start = encoded.items.len;
    encoded.items.len += size;
    std.mem.writeInt(u32, encoded.items[start..][0..4], object_id, .native);
    std.mem.writeInt(u32, encoded.items[start + 4 ..][0..4], (size << 16) | opcode, .native);
    for (arguments, 0..) |argument, index|
        std.mem.writeInt(u32, encoded.items[start + 8 + index * 4 ..][0..4], argument, .native);
}

fn configuredScale(config: *const Configuration, reference: Neutral.HeadRef) ?i32 {
    for (config.heads.items) |configured| {
        if (std.meta.eql(configured.reference, reference)) return configured.scale_fixed;
    }
    return null;
}

fn commitSnapshots(self: *Self, config: *const Configuration, changes: []const Neutral.Change) void {
    for (changes) |change| {
        const head = self.findTarget(change.target) orelse continue;
        head.snapshot.enabled = change.enabled;
        head.snapshot.x = change.x;
        head.snapshot.y = change.y;
        head.snapshot.current_mode = change.mode_index;
        if (configuredScale(config, head.reference)) |fixed| head.snapshot.scale_fixed = fixed;
        if (change.custom_mode) |custom| {
            head.modes[change.mode_index].width = custom.width;
            head.modes[change.mode_index].height = custom.height;
            head.modes[change.mode_index].refresh_millihertz = custom.refresh_millihertz;
        }
    }
}

pub fn destroyClientResources(self: *Self, client: *server.Client) void {
    var i = self.configurations.items.len;
    while (i > 0) : (i -= 1) if (self.configurations.items[i - 1].manager.client == client) self.destroyConfiguration(self.configurations.items[i - 1]);
    i = self.mode_resources.items.len;
    while (i > 0) : (i -= 1) if (self.mode_resources.items[i - 1].head_resource.manager.client == client) self.destroyModeResource(self.mode_resources.items[i - 1]);
    i = self.head_resources.items.len;
    while (i > 0) : (i -= 1) if (self.head_resources.items[i - 1].manager.client == client) self.destroyHeadResource(self.head_resources.items[i - 1]);
    i = self.managers.items.len;
    while (i > 0) : (i -= 1) if (self.managers.items[i - 1].client == client) self.destroyManager(self.managers.items[i - 1]);
}
fn destroyConfiguration(self: *Self, value: *Configuration) void {
    while (value.heads.items.len > 0) {
        const h = value.heads.pop().?;
        if (h.resource) |*r| {
            r.destroy();
            r.deinit();
        }
        self.allocator.destroy(h);
    }
    value.heads.deinit(self.allocator);
    value.transaction.deinit();
    removePtr(Configuration, &self.configurations, value);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}
fn destroyModeResource(self: *Self, value: *ModeResource) void {
    removePtr(ModeResource, &self.mode_resources, value);
    removePtr(ModeResource, &value.head_resource.modes, value);
    value.resource.destroy();
    value.resource.deinit();
    const head = value.head_resource.head;
    self.allocator.destroy(value);
    self.reclaimHead(head);
}
fn destroyHeadResource(self: *Self, value: *HeadResource) void {
    while (value.modes.items.len > 0) self.destroyModeResource(value.modes.items[value.modes.items.len - 1]);
    removePtr(HeadResource, &self.head_resources, value);
    value.modes.deinit(self.allocator);
    const head = value.head;
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
    self.reclaimHead(head);
}
fn destroyManager(self: *Self, value: *Manager) void {
    removePtr(Manager, &self.managers, value);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}
fn reclaimHead(self: *Self, head: *Head) void {
    if (self.findHead(head.snapshot.id) == head) return;
    for (self.head_resources.items) |r| if (r.head == head) return;
    self.destroyHead(head);
}
fn destroyHead(self: *Self, h: *Head) void {
    self.allocator.free(h.name);
    self.allocator.free(h.description);
    self.allocator.free(h.make);
    self.allocator.free(h.model);
    self.allocator.free(h.serial_number);
    self.allocator.free(h.modes);
    self.allocator.destroy(h);
}
fn findHead(self: *Self, id: Neutral.Head) ?*Head {
    for (self.heads.items) |h| if (h.snapshot.id == id) return h;
    return null;
}
fn findTarget(self: *Self, target: Neutral.Target) ?*Head {
    for (self.heads.items) |head| if (head.snapshot.target) |candidate| {
        const matches = switch (candidate) {
            .drm => |output| switch (target) {
                .drm => |other| output == other,
                .virtual => false,
            },
            .virtual => |output| switch (target) {
                .drm => false,
                .virtual => |other| output == other,
            },
        };
        if (matches) return head;
    };
    return null;
}
fn headIdentity(self: *Self, manager: *Manager, id: u32) ?*HeadResource {
    const runtime = manager.client.lookup(id) orelse return null;
    for (self.head_resources.items) |h| if (h.manager == manager and h.resource.id() == id and runtime == &h.resource.runtime and h.resource.runtime.state() == .live and !h.finished) return h;
    return null;
}
fn modeIdentity(self: *Self, manager: *Manager, id: u32) ?*ModeResource {
    const runtime = manager.client.lookup(id) orelse return null;
    for (self.mode_resources.items) |m| if (m.head_resource.manager == manager and m.resource.id() == id and runtime == &m.resource.runtime and m.resource.runtime.state() == .live and !m.finished) return m;
    return null;
}
fn removePtr(comptime T: type, list: *std.ArrayList(*T), value: *T) void {
    for (list.items, 0..) |item, i| if (item == value) {
        _ = list.swapRemove(i);
        return;
    };
}
fn sendDone(self: *Self) void {
    for (self.managers.items) |m| if (!m.stopped) protocol.zwlr_output_manager_v1.@"send:done"(&m.resource, self.authority.serial) catch m.client.postOutOfMemory(&m.resource.runtime, "sending output epoch");
}

fn expectMessages(actual: []const wayring.wire.MessageDescriptor, expected: []const struct { []const u8, u32, bool }) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (actual, expected) |message, wanted| {
        try std.testing.expectEqualStrings(wanted[0], message.name);
        try std.testing.expectEqual(wanted[1], message.since);
        try std.testing.expectEqual(wanted[2], message.destructor);
    }
}

test "renderer conformance: wlr output management descriptors are exact" {
    const interfaces = .{ protocol.zwlr_output_manager_v1, protocol.zwlr_output_head_v1, protocol.zwlr_output_mode_v1, protocol.zwlr_output_configuration_v1, protocol.zwlr_output_configuration_head_v1 };
    const names = .{ "zwlr_output_manager_v1", "zwlr_output_head_v1", "zwlr_output_mode_v1", "zwlr_output_configuration_v1", "zwlr_output_configuration_head_v1" };
    const versions = .{ 4, 4, 3, 4, 4 };
    inline for (interfaces, names, versions) |intf, name, version| {
        try std.testing.expectEqualStrings(name, intf.interface.name);
        try std.testing.expectEqual(@as(u32, version), intf.interface.version);
    }
    try expectMessages(&protocol.zwlr_output_manager_v1.request_messages, &.{
        .{ "create_configuration", 1, false }, .{ "stop", 1, false },
    });
    try expectMessages(&protocol.zwlr_output_manager_v1.event_messages, &.{
        .{ "head", 1, false }, .{ "done", 1, false }, .{ "finished", 1, true },
    });
    try expectMessages(&protocol.zwlr_output_head_v1.request_messages, &.{.{ "release", 3, true }});
    try expectMessages(&protocol.zwlr_output_head_v1.event_messages, &.{
        .{ "name", 1, false },          .{ "description", 1, false },
        .{ "physical_size", 1, false }, .{ "mode", 1, false },
        .{ "enabled", 1, false },       .{ "current_mode", 1, false },
        .{ "position", 1, false },      .{ "transform", 1, false },
        .{ "scale", 1, false },         .{ "finished", 1, false },
        .{ "make", 2, false },          .{ "model", 2, false },
        .{ "serial_number", 2, false }, .{ "adaptive_sync", 4, false },
    });
    try expectMessages(&protocol.zwlr_output_mode_v1.request_messages, &.{.{ "release", 3, true }});
    try expectMessages(&protocol.zwlr_output_mode_v1.event_messages, &.{
        .{ "size", 1, false }, .{ "refresh", 1, false }, .{ "preferred", 1, false }, .{ "finished", 1, false },
    });
    try expectMessages(&protocol.zwlr_output_configuration_v1.request_messages, &.{
        .{ "enable_head", 1, false }, .{ "disable_head", 1, false }, .{ "apply", 1, false },
        .{ "test", 1, false },        .{ "destroy", 1, true },
    });
    try expectMessages(&protocol.zwlr_output_configuration_v1.event_messages, &.{
        .{ "succeeded", 1, false }, .{ "failed", 1, false }, .{ "cancelled", 1, false },
    });
    try expectMessages(&protocol.zwlr_output_configuration_head_v1.request_messages, &.{
        .{ "set_mode", 1, false },      .{ "set_custom_mode", 1, false }, .{ "set_position", 1, false },
        .{ "set_transform", 1, false }, .{ "set_scale", 1, false },       .{ "set_adaptive_sync", 4, false },
    });
    try expectMessages(&protocol.zwlr_output_configuration_head_v1.event_messages, &.{});
    try std.testing.expectEqual(@as(i64, 1), protocol.zwlr_output_configuration_v1.@"error".already_configured_head);
    try std.testing.expectEqual(@as(i64, 2), protocol.zwlr_output_configuration_v1.@"error".unconfigured_head);
    try std.testing.expectEqual(@as(i64, 3), protocol.zwlr_output_configuration_v1.@"error".already_used);
    try std.testing.expectEqual(@as(i64, 1), protocol.zwlr_output_configuration_head_v1.@"error".already_set);
    try std.testing.expectEqual(@as(i64, 2), protocol.zwlr_output_configuration_head_v1.@"error".invalid_mode);
    try std.testing.expectEqual(@as(i64, 3), protocol.zwlr_output_configuration_head_v1.@"error".invalid_custom_mode);
    try std.testing.expectEqual(@as(i64, 4), protocol.zwlr_output_configuration_head_v1.@"error".invalid_transform);
    try std.testing.expectEqual(@as(i64, 5), protocol.zwlr_output_configuration_head_v1.@"error".invalid_scale);
    try std.testing.expectEqual(@as(i64, 6), protocol.zwlr_output_configuration_head_v1.@"error".invalid_adaptive_sync_state);
}

test "renderer conformance: prepared output events preserve unsigned server object ids" {
    var encoded: std.ArrayList(u8) = .empty;
    defer encoded.deinit(std.testing.allocator);

    const head_id = server.ObjectMap.first_server_id;
    const mode_id = std.math.maxInt(u32);
    try appendEvent(std.testing.allocator, &encoded, head_id, 5, &.{mode_id});
    try appendEvent(std.testing.allocator, &encoded, mode_id, 1, &.{wireInt(std.math.maxInt(i32))});
    try appendEvent(std.testing.allocator, &encoded, 7, 1, &.{std.math.maxInt(u32)});

    try std.testing.expectEqual(@as(usize, 36), encoded.items.len);
    try std.testing.expectEqual(head_id, std.mem.readInt(u32, encoded.items[0..4], .native));
    try std.testing.expectEqual((@as(u32, 12) << 16) | 5, std.mem.readInt(u32, encoded.items[4..8], .native));
    try std.testing.expectEqual(mode_id, std.mem.readInt(u32, encoded.items[8..12], .native));
    try std.testing.expectEqual(mode_id, std.mem.readInt(u32, encoded.items[12..16], .native));
    try std.testing.expectEqual(@as(u32, std.math.maxInt(i32)), std.mem.readInt(u32, encoded.items[20..24], .native));
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, encoded.items[24..28], .native));
    try std.testing.expectEqual(std.math.maxInt(u32), std.mem.readInt(u32, encoded.items[32..36], .native));
}

test "renderer conformance: output management stays unpublished until explicitly restricted" {
    const Context = struct {
        fn accept(_: *anyopaque, _: []const Neutral.Change) bool {
            return true;
        }
    };
    var protocol_server: server.Server = .init(std.testing.allocator);
    defer protocol_server.deinit();
    var authority: Neutral = .{};
    var context: u8 = 0;
    var adapter: Self = undefined;
    adapter.init(
        std.testing.allocator,
        &protocol_server,
        &authority,
        42,
        .{
            .context = &context,
            .test_configuration = Context.accept,
            .apply = Context.accept,
        },
    );
    defer adapter.deinit();
    try std.testing.expectError(error.InvalidSnapshot, adapter.addOutput(.{
        .id = 8,
        .name = "INVALID",
        .modes = &.{.{
            .width = @as(u32, std.math.maxInt(i32)) + 1,
            .height = 720,
            .refresh_millihertz = 60_000,
        }},
    }));
    try std.testing.expectEqual(@as(usize, 0), adapter.heads.items.len);
    try adapter.addOutput(.{
        .id = 7,
        .name = "HEADLESS-1",
        .description = "Keywork headless output",
        .make = "keywork",
        .model = "headless",
        .modes = &.{.{ .width = 1280, .height = 720, .refresh_millihertz = 60_000, .preferred = true }},
    });

    var globals = protocol_server.iterator();
    try std.testing.expect(globals.next() == null);
    try adapter.publish();
    globals = protocol_server.iterator();
    const global = globals.next().?;
    try std.testing.expectEqualStrings("zwlr_output_manager_v1", global.interface().name);
    try std.testing.expectEqual(@as(u32, 4), global.version());
    try std.testing.expectEqual(server.Server.GlobalVisibility.restricted, global.visibility());
    adapter.unpublish();
    globals = protocol_server.iterator();
    try std.testing.expect(globals.next() == null);
}

test "change allocation failure cannot invoke listener" {
    var authority: Neutral = .{};
    const reference = try authority.generation(1);
    var transaction = authority.transaction(std.testing.allocator, 2, 3);
    defer transaction.deinit();
    try transaction.configure(.{ .reference = reference, .enabled = true });
    const items = try transaction.consume(&authority, 2, 3, &.{.{ .reference = reference }});
    try std.testing.expectError(error.OutOfMemory, std.testing.failing_allocator.alloc(Neutral.Change, items.len));
}

fn exerciseNeutralPreparation(allocator: std.mem.Allocator) !void {
    var authority: Neutral = .{};
    const reference = try authority.generation(1);
    var transaction = authority.transaction(allocator, 2, 3);
    defer transaction.deinit();
    try transaction.configure(.{
        .reference = reference,
        .enabled = true,
        .custom_mode = .{ .width = 1920, .height = 1080, .refresh_millihertz = 60_000 },
        .scale = .{ .numerator = 150 },
    });
    var prepared = transaction.prepare(&authority, 2, 3, &.{.{
        .reference = reference,
        .target = null,
    }}) catch |err| switch (err) {
        error.InvalidConfiguration => return,
        else => return err,
    };
    prepared.deinit();
}

test "renderer conformance: neutral transaction preparation is allocation-failure atomic" {
    // Invalid target is reached only after every transaction-owned allocation
    // has succeeded; every injected failure before that point is reclaimed.
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseNeutralPreparation, .{});
}

fn exerciseSnapshotMaterialization(allocator: std.mem.Allocator) !void {
    var protocol_server: server.Server = .init(std.testing.allocator);
    defer protocol_server.deinit();
    var authority: Neutral = .{};
    var context: u8 = 0;
    const ListenerContext = struct {
        fn accept(_: *anyopaque, _: []const Neutral.Change) bool {
            return true;
        }
    };
    var adapter: Self = undefined;
    adapter.init(allocator, &protocol_server, &authority, 42, .{
        .context = &context,
        .test_configuration = ListenerContext.accept,
        .apply = ListenerContext.accept,
    });
    defer adapter.deinit();
    try adapter.addOutput(.{
        .id = 1,
        .name = "HEADLESS-1",
        .description = "Keywork headless output",
        .make = "keywork",
        .model = "headless",
        .serial_number = "virtual-1",
        .modes = &.{.{ .width = 1920, .height = 1080, .refresh_millihertz = 60_000, .preferred = true }},
    });
}

test "renderer conformance: adapter snapshot allocation failures leave no half-live head" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseSnapshotMaterialization, .{});
}

const test_display_get_registry: wayring.wire.MessageDescriptor = .{
    .name = "get_registry",
    .arguments = &.{.{ .name = "registry", .kind = .{ .new_id = &.{ .name = "wl_registry", .version = 1 } } }},
};
const test_registry_bind: wayring.wire.MessageDescriptor = .{ .name = "bind", .arguments = &.{
    .{ .name = "name", .kind = .uint },
    .{ .name = "id", .kind = .{ .new_id = null } },
} };

fn testSend(client: *server.Client, object_id: u32, opcode: u16, descriptor: *const wayring.wire.MessageDescriptor, values: []const wayring.wire.Value) !void {
    var output: wayring.wire.Output = .init(std.testing.allocator);
    defer output.deinit();
    try output.enqueue(object_id, opcode, descriptor, values);
    const batch = (try output.beginSend()).?;
    try client.receive(batch.bytes, &.{});
    try output.completeSend(batch.token, batch.bytes.len);
    try client.dispatch();
}

fn drainClient(client: *server.Client) !void {
    while (try client.beginSend()) |batch| try client.completeSend(batch.token, batch.bytes.len);
}

test "renderer conformance: canonical apply encodes high server ids as exact wire objects" {
    const Context = struct {
        adapter: ?*Self = null,
        self_sync_observed: bool = false,

        fn accept(_: *anyopaque, _: []const Neutral.Change) bool {
            return true;
        }

        fn apply(erased: *anyopaque, _: []const Neutral.Change) bool {
            const self: *@This() = @ptrCast(@alignCast(erased));
            const adapter = self.adapter.?;
            self.self_sync_observed = adapter.applying_configuration;
            adapter.syncOutput(adapter.heads.items[0].snapshot) catch return false;
            return true;
        }
    };
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var authority: Neutral = .{};
    var context: Context = .{};
    var adapter: Self = undefined;
    adapter.init(std.testing.allocator, &host, &authority, 42, .{
        .context = &context,
        .test_configuration = Context.accept,
        .apply = Context.apply,
    });
    context.adapter = &adapter;
    defer adapter.deinit();
    try adapter.addOutput(.{
        .id = 1,
        .target = .{ .virtual = @ptrFromInt(0x1000) },
        .name = "HEADLESS-1",
        .modes = &.{.{ .width = 1280, .height = 720, .refresh_millihertz = 60_000, .preferred = true }},
    });
    try adapter.publish();
    defer adapter.unpublish();
    host.setGlobalFilter(Self, &adapter, globalFilter);
    defer host.clearGlobalFilter();
    const client = try server.CoreClient.create(std.testing.allocator, &host, .{
        .credentials = .{ .pid = 1, .uid = 42, .gid = 1 },
        .transport_provenance = .direct,
    });
    defer client.destroy();
    try testSend(client.client(), 1, 1, &test_display_get_registry, &.{.{ .new_id = .{ .typed = 2 } }});
    try drainClient(client.client());
    try testSend(client.client(), 2, 0, &test_registry_bind, &.{
        .{ .uint = adapter.global.?.name() },
        .{ .new_id = .{ .generic = .{ .interface = protocol.zwlr_output_manager_v1.interface.name, .version = 4, .id = 3 } } },
    });
    try drainClient(client.client());

    const head = adapter.head_resources.items[0];
    const canonical_head = adapter.heads.items[0];
    const mode = head.modes.items[0];
    try std.testing.expect(head.resource.id() >= server.ObjectMap.first_server_id);
    try std.testing.expect(mode.resource.id() >= server.ObjectMap.first_server_id);
    try testSend(client.client(), 3, 0, &protocol.zwlr_output_manager_v1.request_messages[0], &.{
        .{ .new_id = .{ .typed = 4 } },
        .{ .uint = authority.serial },
    });
    try testSend(client.client(), 4, 0, &protocol.zwlr_output_configuration_v1.request_messages[0], &.{
        .{ .new_id = .{ .typed = 5 } },
        .{ .object = head.resource.id() },
    });
    try testSend(client.client(), 5, 1, &protocol.zwlr_output_configuration_head_v1.request_messages[1], &.{
        .{ .int = 1920 }, .{ .int = 1080 }, .{ .int = 60_000 },
    });
    try testSend(client.client(), 5, 4, &protocol.zwlr_output_configuration_head_v1.request_messages[4], &.{.{ .fixed = 384 }});
    try testSend(client.client(), 4, 2, &protocol.zwlr_output_configuration_v1.request_messages[2], &.{});

    const batch = (try client.client().beginSend()).?;
    var cursor: usize = 0;
    var current_mode_seen = false;
    var scale_seen = false;
    while (cursor < batch.bytes.len) {
        const object_id = std.mem.readInt(u32, batch.bytes[cursor..][0..4], .native);
        const size_opcode = std.mem.readInt(u32, batch.bytes[cursor + 4 ..][0..4], .native);
        const size: usize = @intCast(size_opcode >> 16);
        const opcode: u16 = @truncate(size_opcode);
        if (object_id == head.resource.id() and opcode == 5) {
            try std.testing.expectEqual(mode.resource.id(), std.mem.readInt(u32, batch.bytes[cursor + 8 ..][0..4], .native));
            current_mode_seen = true;
        }
        if (object_id == head.resource.id() and opcode == 8) {
            try std.testing.expectEqual(@as(i32, 384), std.mem.readInt(i32, batch.bytes[cursor + 8 ..][0..4], .native));
            scale_seen = true;
        }
        cursor += size;
    }
    try std.testing.expect(current_mode_seen and scale_seen);
    try client.client().completeSend(batch.token, batch.bytes.len);
    try std.testing.expect(context.self_sync_observed);
    try std.testing.expect(adapter.heads.items[0] == canonical_head);
    try std.testing.expect(adapter.head_resources.items[0] == head);
    try std.testing.expect(!head.finished and !mode.finished);
    try std.testing.expectEqual(@as(u32, 1920), adapter.heads.items[0].modes[0].width);
    try std.testing.expectEqual(@as(i32, 384), adapter.heads.items[0].snapshot.scale_fixed);

    adapter.destroyClientResources(client.client());
}

test "renderer conformance: restricted output management isolates forged bind and preserves direct sibling" {
    const Context = struct {
        fn accept(_: *anyopaque, _: []const Neutral.Change) bool {
            return true;
        }
    };
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var authority: Neutral = .{};
    var context: u8 = 0;
    var adapter: Self = undefined;
    adapter.init(std.testing.allocator, &host, &authority, 42, .{
        .context = &context,
        .test_configuration = Context.accept,
        .apply = Context.accept,
    });
    defer adapter.deinit();
    try adapter.addOutput(.{
        .id = 1,
        .name = "HEADLESS-1",
        .description = "Keywork headless output",
        .make = "keywork",
        .model = "headless",
        .modes = &.{.{ .width = 1280, .height = 720, .refresh_millihertz = 60_000, .preferred = true }},
    });
    try adapter.publish();
    defer adapter.unpublish();
    host.setGlobalFilter(Self, &adapter, globalFilter);
    defer host.clearGlobalFilter();

    const direct = try server.CoreClient.create(std.testing.allocator, &host, .{
        .credentials = .{ .pid = 1, .uid = 42, .gid = 1 },
        .transport_provenance = .direct,
    });
    defer direct.destroy();
    const wrong = try server.CoreClient.create(std.testing.allocator, &host, .{
        .credentials = .{ .pid = 2, .uid = 41, .gid = 1 },
        .transport_provenance = .direct,
    });
    defer wrong.destroy();
    const derived = try server.CoreClient.create(std.testing.allocator, &host, .{
        .credentials = .{ .pid = 3, .uid = 42, .gid = 1 },
        .transport_provenance = .security_context,
    });
    defer derived.destroy();
    const unknown = try server.CoreClient.create(std.testing.allocator, &host, .{
        .credentials = .{ .pid = 4, .uid = 42, .gid = 1 },
        .transport_provenance = .unknown,
    });
    defer unknown.destroy();
    const missing = try server.CoreClient.create(std.testing.allocator, &host, .{
        .transport_provenance = .direct,
    });
    defer missing.destroy();

    for ([_]*server.CoreClient{ direct, wrong, derived, unknown, missing }) |managed|
        try testSend(managed.client(), 1, 1, &test_display_get_registry, &.{.{ .new_id = .{ .typed = 2 } }});
    const direct_registry = (try direct.client().beginSend()).?;
    try std.testing.expectEqual(adapter.global.?.name(), std.mem.readInt(u32, direct_registry.bytes[8..12], .native));
    try direct.client().completeSend(direct_registry.token, direct_registry.bytes.len);
    for ([_]*server.CoreClient{ wrong, derived, unknown, missing }) |managed|
        try std.testing.expect((try managed.client().beginSend()) == null);

    try testSend(direct.client(), 2, 0, &test_registry_bind, &.{
        .{ .uint = adapter.global.?.name() },
        .{ .new_id = .{ .generic = .{ .interface = protocol.zwlr_output_manager_v1.interface.name, .version = 4, .id = 3 } } },
    });
    try std.testing.expectEqual(@as(usize, 1), adapter.managers.items.len);
    try drainClient(direct.client());

    try testSend(wrong.client(), 2, 0, &test_registry_bind, &.{
        .{ .uint = adapter.global.?.name() },
        .{ .new_id = .{ .generic = .{ .interface = protocol.zwlr_output_manager_v1.interface.name, .version = 4, .id = 3 } } },
    });
    try std.testing.expectEqual(server.Fatal.Kind.protocol, wrong.client().fatal().?.kind);
    try std.testing.expectEqualStrings("invalid wl_registry.bind", wrong.client().fatal().?.detail());
    try std.testing.expectEqual(@as(usize, 1), adapter.managers.items.len);
    try std.testing.expect(direct.client().fatal() == null);
    try std.testing.expectError(error.Unauthorized, bind(derived.client(), 3, 4, &adapter));

    adapter.destroyClientResources(direct.client());
    try std.testing.expectEqual(@as(usize, 0), adapter.managers.items.len);
    try std.testing.expectEqual(@as(usize, 0), adapter.head_resources.items.len);
    try std.testing.expectEqual(@as(usize, 0), adapter.mode_resources.items.len);
}

test "renderer conformance: output replacement cancels stale children and reverse teardown is allocation free" {
    const Context = struct {
        fn accept(_: *anyopaque, _: []const Neutral.Change) bool {
            return true;
        }
    };
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var authority: Neutral = .{};
    authority.next_generation = std.math.maxInt(u64) - 1;
    var context: u8 = 0;
    var adapter: Self = undefined;
    adapter.init(std.testing.allocator, &host, &authority, 42, .{
        .context = &context,
        .test_configuration = Context.accept,
        .apply = Context.accept,
    });
    defer adapter.deinit();
    adapter.next_generation = std.math.maxInt(u64) - 1;
    const snapshot: HeadSnapshot = .{
        .id = 1,
        .name = "HEADLESS-1",
        .modes = &.{.{ .width = 1280, .height = 720, .refresh_millihertz = 60_000, .preferred = true }},
    };
    try adapter.addOutput(snapshot);
    try adapter.publish();
    defer adapter.unpublish();
    host.setGlobalFilter(Self, &adapter, globalFilter);
    defer host.clearGlobalFilter();
    const client = try server.CoreClient.create(std.testing.allocator, &host, .{
        .credentials = .{ .pid = 1, .uid = 42, .gid = 1 },
        .transport_provenance = .direct,
    });
    defer client.destroy();
    try testSend(client.client(), 1, 1, &test_display_get_registry, &.{.{ .new_id = .{ .typed = 2 } }});
    try drainClient(client.client());
    try testSend(client.client(), 2, 0, &test_registry_bind, &.{
        .{ .uint = adapter.global.?.name() },
        .{ .new_id = .{ .generic = .{ .interface = protocol.zwlr_output_manager_v1.interface.name, .version = 4, .id = 3 } } },
    });
    try drainClient(client.client());
    const manager = adapter.managers.items[0];
    const old_head = adapter.heads.items[0];
    const old_generation = old_head.reference.generation;
    const old_resource = adapter.head_resources.items[0];
    try std.testing.expectEqual(std.math.maxInt(u64) - 1, old_generation);
    try std.testing.expectEqual(std.math.maxInt(u64) - 1, manager.generation);
    try std.testing.expect(old_resource.resource.id() >= server.ObjectMap.first_server_id);
    try std.testing.expect(old_resource.modes.items[0].resource.id() >= server.ObjectMap.first_server_id);
    try testSend(client.client(), manager.resource.id(), 0, &protocol.zwlr_output_manager_v1.request_messages[0], &.{
        .{ .new_id = .{ .typed = 4 } },
        .{ .uint = authority.serial },
    });
    const configuration = adapter.configurations.items[0];
    try testSend(client.client(), configuration.resource.id(), 0, &protocol.zwlr_output_configuration_v1.request_messages[0], &.{
        .{ .new_id = .{ .typed = 5 } },
        .{ .object = old_resource.resource.id() },
    });

    adapter.removeOutput(1);
    try adapter.addOutput(snapshot);
    try std.testing.expectEqual(std.math.maxInt(u64), adapter.heads.items[0].reference.generation);
    try std.testing.expect(old_resource.finished);
    try std.testing.expect(old_resource.modes.items[0].finished);
    const fresh_resource = adapter.head_resources.items[adapter.head_resources.items.len - 1];
    try std.testing.expect(fresh_resource.resource.id() != old_resource.resource.id());
    try std.testing.expect(adapter.headIdentity(manager, old_resource.resource.id()) == null);
    try std.testing.expect(adapter.headIdentity(manager, fresh_resource.resource.id()) == fresh_resource);
    try execute(&adapter, configuration, false);
    try std.testing.expect(configuration.transaction.used);

    try managerRequest(&manager.resource, .stop, manager);
    try std.testing.expect(manager.stopped);
    // Configuration, head, and mode children remain valid after stop and are
    // reclaimed in reverse dependency order on abrupt disconnect.
    try std.testing.expect(adapter.configurations.items.len > 0);
    try std.testing.expect(adapter.head_resources.items.len > 0);
    try std.testing.expect(adapter.mode_resources.items.len > 0);
    adapter.destroyClientResources(client.client());
    try std.testing.expectEqual(@as(usize, 0), adapter.configurations.items.len);
    try std.testing.expectEqual(@as(usize, 0), adapter.mode_resources.items.len);
    try std.testing.expectEqual(@as(usize, 0), adapter.head_resources.items.len);
    try std.testing.expectEqual(@as(usize, 0), adapter.managers.items.len);
}
