//! Privileged, single-head implementation of wlr output management v1.

const OutputManagementGlobal = @This();
const std = @import("std");
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const OutputGlobal = @import("OutputGlobal.zig");
const SecurityContextGlobal = @import("SecurityContextGlobal.zig");
const render = @import("../render/types.zig");

allocator: std.mem.Allocator,
server: *Server,
output: *OutputGlobal,
listener: Listener,
global_name: u32,
serial: u32 = 1,
scale: render.Scale,
managers: std.ArrayList(*Manager) = .empty,
heads: std.ArrayList(*Head) = .empty,
modes: std.ArrayList(*Mode) = .empty,
configs: std.ArrayList(*Config) = .empty,

pub const Listener = struct {
    context: *anyopaque,
    validate: *const fn (*anyopaque, render.Size, render.Scale) anyerror!void,
    resize: *const fn (*anyopaque, render.Size, render.Scale) anyerror!bool,
};
const Manager = struct { owner: *OutputManagementGlobal, client: *Server.Client, resource: wayring.ObjectHandle, stopped: bool = false };
const Head = struct { owner: *OutputManagementGlobal, client: *Server.Client, resource: wayring.ObjectHandle, mode: ?*Mode = null };
const Mode = struct { owner: *OutputManagementGlobal, client: *Server.Client, resource: wayring.ObjectHandle, head: ?*Head = null };
const Config = struct {
    owner: *OutputManagementGlobal,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    serial: u32,
    used: bool = false,
    configured: bool = false,
    disabled: bool = false,
    child: ?*ConfigHead = null,
};
const ConfigHead = struct {
    owner: *OutputManagementGlobal,
    config: ?*Config,
    resource: wayring.ObjectHandle,
    mode_set: bool = false,
    size: ?render.Size = null,
    refresh: i32 = 0,
    position_set: bool = false,
    position_valid: bool = true,
    transform_set: bool = false,
    transform_valid: bool = true,
    scale_set: bool = false,
    scale: ?render.Scale = null,
    adaptive_set: bool = false,
    adaptive_valid: bool = true,
};

pub fn init(self: *OutputManagementGlobal, allocator: std.mem.Allocator, server: *Server, output: *OutputGlobal, scale: render.Scale, security: *SecurityContextGlobal, listener: Listener) !void {
    if (scale.numerator == 0) return error.InvalidScale;
    _ = fixedScale(scale) catch return error.InvalidScale;
    self.* = .{ .allocator = allocator, .server = server, .output = output, .scale = scale, .listener = listener, .global_name = undefined };
    self.global_name = try server.createGlobal(&generated.zwlr_output_manager_v1, 4, .{
        .context = self,
        .bind = bind,
        .filter_context = security,
        .filter = SecurityContextGlobal.allowUnconfined,
    });
}

pub fn deinit(self: *OutputManagementGlobal) void {
    self.server.removeGlobal(self.global_name) catch unreachable;
    std.debug.assert(self.managers.items.len == 0 and self.heads.items.len == 0 and self.modes.items.len == 0 and self.configs.items.len == 0);
    self.configs.deinit(self.allocator);
    self.modes.deinit(self.allocator);
    self.heads.deinit(self.allocator);
    self.managers.deinit(self.allocator);
}

fn bind(ctx: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *OutputManagementGlobal = @ptrCast(@alignCast(ctx));
    const manager = self.allocator.create(Manager) catch return client.postNoMemory();
    var manager_owned = true;
    errdefer if (manager_owned) self.allocator.destroy(manager);
    self.managers.ensureUnusedCapacity(self.allocator, 1) catch return client.postNoMemory();
    manager.* = .{ .owner = self, .client = client, .resource = undefined };
    manager.resource = client.createResource(id, &generated.zwlr_output_manager_v1, version, .{ .context = manager, .dispatch = dispatchManager, .destroy = destroyManager }) catch return client.postNoMemory();
    self.managers.appendAssumeCapacity(manager);
    manager_owned = false;
    errdefer client.destroyResource(manager.resource) catch {};
    createHead(manager) catch return client.postNoMemory();
    generated.zwlr_output_manager_v1_types.events.done(&client.connection, manager.resource, self.serial) catch return client.postNoMemory();
}

fn createHead(manager: *Manager) !void {
    const self = manager.owner;
    const head = try self.allocator.create(Head);
    var head_owned = true;
    errdefer if (head_owned) self.allocator.destroy(head);
    const mode = try self.allocator.create(Mode);
    var mode_owned = true;
    errdefer if (mode_owned) self.allocator.destroy(mode);
    try self.heads.ensureUnusedCapacity(self.allocator, 1);
    try self.modes.ensureUnusedCapacity(self.allocator, 1);
    const version = try manager.client.resourceVersion(manager.resource, &generated.zwlr_output_manager_v1);
    head.* = .{ .owner = self, .client = manager.client, .resource = undefined };
    head.resource = try manager.client.createServerResource(&generated.zwlr_output_head_v1, version, .{ .context = head, .dispatch = dispatchHead, .destroy = destroyHead });
    self.heads.appendAssumeCapacity(head);
    head_owned = false;
    mode.* = .{ .owner = self, .client = manager.client, .resource = undefined };
    mode.resource = manager.client.createServerResource(&generated.zwlr_output_mode_v1, @min(version, 3), .{ .context = mode, .dispatch = dispatchMode, .destroy = destroyMode }) catch |err| {
        manager.client.destroyResource(head.resource) catch {};
        return err;
    };
    self.modes.appendAssumeCapacity(mode);
    mode_owned = false;
    head.mode = mode;
    mode.head = head;
    errdefer {
        manager.client.destroyResource(mode.resource) catch {};
        manager.client.destroyResource(head.resource) catch {};
    }
    const connection = &manager.client.connection;
    try generated.zwlr_output_manager_v1_types.events.head(connection, manager.resource, head.resource);
    try generated.zwlr_output_head_v1_types.events.name(connection, head.resource, self.output.outputName());
    try generated.zwlr_output_head_v1_types.events.description(connection, head.resource, self.output.outputDescription());
    const physical = self.output.physicalSize();
    try generated.zwlr_output_head_v1_types.events.physical_size(connection, head.resource, @intCast(physical.width), @intCast(physical.height));
    try generated.zwlr_output_head_v1_types.events.mode(connection, head.resource, mode.resource);
    try sendMode(mode);
    try generated.zwlr_output_head_v1_types.events.enabled(connection, head.resource, 1);
    try generated.zwlr_output_head_v1_types.events.current_mode(connection, head.resource, mode.resource);
    try generated.zwlr_output_head_v1_types.events.position(connection, head.resource, 0, 0);
    try generated.zwlr_output_head_v1_types.events.transform(connection, head.resource, 0);
    try generated.zwlr_output_head_v1_types.events.scale(connection, head.resource, try fixedScale(self.scale));
    if (version >= 2) {
        try generated.zwlr_output_head_v1_types.events.make(connection, head.resource, self.output.outputMake());
        try generated.zwlr_output_head_v1_types.events.model(connection, head.resource, self.output.outputModel());
    }
    if (version >= 4) try generated.zwlr_output_head_v1_types.events.adaptive_sync(connection, head.resource, 0);
}

fn sendMode(mode: *Mode) !void {
    const o = mode.owner.output;
    const c = &mode.client.connection;
    const size = o.currentMode();
    try generated.zwlr_output_mode_v1_types.events.size(c, mode.resource, @intCast(size.width), @intCast(size.height));
    try generated.zwlr_output_mode_v1_types.events.refresh(c, mode.resource, o.currentRefreshMillihertz());
    try generated.zwlr_output_mode_v1_types.events.preferred(c, mode.resource);
}
fn dispatchManager(ctx: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, msg: *wayring.Message) !void {
    const m: *Manager = @ptrCast(@alignCast(ctx));
    switch (try generated.zwlr_output_manager_v1_types.decodeRequest(&client.connection, resource, msg)) {
        .create_configuration => |r| try createConfig(m, r.id, r.serial),
        .stop => {
            m.stopped = true;
            try generated.zwlr_output_manager_v1_types.events.finished(&client.connection, resource);
            try client.destroyResource(resource);
        },
    }
}
fn createConfig(manager: *Manager, id: u32, serial: u32) !void {
    const self = manager.owner;
    const c = self.allocator.create(Config) catch return manager.client.postNoMemory();
    errdefer self.allocator.destroy(c);
    self.configs.ensureUnusedCapacity(self.allocator, 1) catch return manager.client.postNoMemory();
    c.* = .{ .owner = self, .client = manager.client, .resource = undefined, .serial = serial };
    const version = try manager.client.resourceVersion(manager.resource, &generated.zwlr_output_manager_v1);
    c.resource = manager.client.createResource(id, &generated.zwlr_output_configuration_v1, version, .{ .context = c, .dispatch = dispatchConfig, .destroy = destroyConfig }) catch return manager.client.postNoMemory();
    self.configs.appendAssumeCapacity(c);
}
fn dispatchConfig(ctx: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, msg: *wayring.Message) !void {
    const c: *Config = @ptrCast(@alignCast(ctx));
    const E = generated.zwlr_output_configuration_v1_types.@"error";
    switch (try generated.zwlr_output_configuration_v1_types.decodeRequest(&client.connection, resource, msg)) {
        .enable_head => |r| {
            if (c.used) return client.postError(resource, @intFromEnum(E.already_used), "configuration already used");
            if (c.configured) return client.postError(resource, @intFromEnum(E.already_configured_head), "head already configured");
            const h = findHead(c.owner, client, r.head) orelse return client.postError(resource, @intFromEnum(E.already_configured_head), "invalid head");
            try createConfigHead(c, r.id);
            c.configured = true;
            _ = h;
        },
        .disable_head => |r| {
            if (c.used) return client.postError(resource, @intFromEnum(E.already_used), "configuration already used");
            _ = findHead(c.owner, client, r.head) orelse return client.postError(resource, @intFromEnum(E.already_configured_head), "invalid head");
            if (c.configured) return client.postError(resource, @intFromEnum(E.already_configured_head), "head already configured");
            c.configured = true;
            c.disabled = true;
        },
        .apply => try finishConfig(c, true),
        .@"test" => try finishConfig(c, false),
        .destroy => {},
    }
}
fn createConfigHead(c: *Config, id: u32) !void {
    const h = c.owner.allocator.create(ConfigHead) catch return c.client.postNoMemory();
    errdefer c.owner.allocator.destroy(h);
    h.* = .{ .owner = c.owner, .config = c, .resource = undefined };
    const version = try c.client.resourceVersion(c.resource, &generated.zwlr_output_configuration_v1);
    h.resource = c.client.createResource(id, &generated.zwlr_output_configuration_head_v1, version, .{ .context = h, .dispatch = dispatchConfigHead, .destroy = destroyConfigHead }) catch return c.client.postNoMemory();
    c.child = h;
}
fn dispatchConfigHead(ctx: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, msg: *wayring.Message) !void {
    const h: *ConfigHead = @ptrCast(@alignCast(ctx));
    const config = h.config orelse return;
    const E = generated.zwlr_output_configuration_head_v1_types.@"error";
    switch (try generated.zwlr_output_configuration_head_v1_types.decodeRequest(&client.connection, resource, msg)) {
        .set_mode => |r| {
            if (config.used) return client.postError(config.resource, @intFromEnum(generated.zwlr_output_configuration_v1_types.@"error".already_used), "configuration already used");
            if (h.mode_set) return client.postError(resource, @intFromEnum(E.already_set), "mode already set");
            const m = findMode(config.owner, client, r.mode) orelse return client.postError(resource, @intFromEnum(E.invalid_mode), "invalid mode");
            h.mode_set = true;
            h.size = m.owner.output.currentMode();
        },
        .set_custom_mode => |r| {
            if (config.used) return client.postError(config.resource, @intFromEnum(generated.zwlr_output_configuration_v1_types.@"error".already_used), "configuration already used");
            if (h.mode_set) return client.postError(resource, @intFromEnum(E.already_set), "mode already set");
            if (r.width <= 0 or r.height <= 0 or r.refresh < 0) return client.postError(resource, @intFromEnum(E.invalid_custom_mode), "invalid custom mode");
            h.mode_set = true;
            h.size = .{ .width = @intCast(r.width), .height = @intCast(r.height) };
            h.refresh = r.refresh;
        },
        .set_position => |r| {
            if (config.used) return client.postError(config.resource, @intFromEnum(generated.zwlr_output_configuration_v1_types.@"error".already_used), "configuration already used");
            if (h.position_set) return client.postError(resource, @intFromEnum(E.already_set), "position already set");
            h.position_set = true;
            h.position_valid = r.x == 0 and r.y == 0;
        },
        .set_transform => |r| {
            if (config.used) return client.postError(config.resource, @intFromEnum(generated.zwlr_output_configuration_v1_types.@"error".already_used), "configuration already used");
            if (h.transform_set) return client.postError(resource, @intFromEnum(E.already_set), "transform already set");
            if (r.transform < 0 or r.transform > 7) return client.postError(resource, @intFromEnum(E.invalid_transform), "invalid transform");
            h.transform_set = true;
            h.transform_valid = r.transform == 0;
        },
        .set_scale => |r| {
            if (config.used) return client.postError(config.resource, @intFromEnum(generated.zwlr_output_configuration_v1_types.@"error".already_used), "configuration already used");
            if (h.scale_set) return client.postError(resource, @intFromEnum(E.already_set), "scale already set");
            if (r.scale <= 0) return client.postError(resource, @intFromEnum(E.invalid_scale), "invalid scale");
            h.scale_set = true;
            h.scale = scaleFromFixed(r.scale) catch return client.postError(resource, @intFromEnum(E.invalid_scale), "invalid scale");
        },
        .set_adaptive_sync => |r| {
            if (config.used) return client.postError(config.resource, @intFromEnum(generated.zwlr_output_configuration_v1_types.@"error".already_used), "configuration already used");
            if (h.adaptive_set) return client.postError(resource, @intFromEnum(E.already_set), "adaptive sync already set");
            if (r.state > 1) return client.postError(resource, @intFromEnum(E.invalid_adaptive_sync_state), "invalid adaptive sync");
            h.adaptive_set = true;
            h.adaptive_valid = r.state == 0;
        },
    }
}
fn finishConfig(c: *Config, apply: bool) !void {
    const E = generated.zwlr_output_configuration_v1_types.@"error";
    if (c.used) return c.client.postError(c.resource, @intFromEnum(E.already_used), "configuration already used");
    c.used = true;
    if (!c.configured) return c.client.postError(c.resource, @intFromEnum(E.unconfigured_head), "head not configured");
    if (c.serial != c.owner.serial) return generated.zwlr_output_configuration_v1_types.events.cancelled(&c.client.connection, c.resource);
    const h = c.child;
    if (c.disabled or h == null or !valid(h.?)) return generated.zwlr_output_configuration_v1_types.events.failed(&c.client.connection, c.resource);
    const size = h.?.size orelse c.owner.output.currentMode();
    const scale: render.Scale = h.?.scale orelse c.owner.scale;
    c.owner.listener.validate(c.owner.listener.context, size, scale) catch return generated.zwlr_output_configuration_v1_types.events.failed(&c.client.connection, c.resource);
    if (!apply) return generated.zwlr_output_configuration_v1_types.events.succeeded(&c.client.connection, c.resource);
    const changed = c.owner.listener.resize(c.owner.listener.context, size, scale) catch return generated.zwlr_output_configuration_v1_types.events.failed(&c.client.connection, c.resource);
    if (changed) {
        c.owner.scale = scale;
        c.owner.serial +%= 1;
        if (c.owner.serial == 0) c.owner.serial = 1;
        for (c.owner.modes.items) |m| sendMode(m) catch m.client.postNoMemory() catch {};
        for (c.owner.heads.items) |head| {
            const fixed_scale = fixedScale(c.owner.scale) catch unreachable;
            generated.zwlr_output_head_v1_types.events.scale(&head.client.connection, head.resource, fixed_scale) catch head.client.postNoMemory() catch {};
            const mode = head.mode orelse continue;
            generated.zwlr_output_head_v1_types.events.current_mode(&head.client.connection, head.resource, mode.resource) catch head.client.postNoMemory() catch {};
        }
        for (c.owner.managers.items) |m| if (!m.stopped) generated.zwlr_output_manager_v1_types.events.done(&m.client.connection, m.resource, c.owner.serial) catch {
            m.client.postNoMemory() catch {};
        };
    }
    generated.zwlr_output_configuration_v1_types.events.succeeded(&c.client.connection, c.resource) catch c.client.postNoMemory() catch {};
}
fn valid(h: *ConfigHead) bool {
    const c = h.config orelse return false;
    return h.position_valid and h.transform_valid and h.adaptive_valid and (h.refresh == 0 or h.refresh == c.owner.output.currentRefreshMillihertz());
}
fn findHead(self: *OutputManagementGlobal, client: *Server.Client, id: u32) ?*Head {
    for (self.heads.items) |h| if (h.client == client and h.resource.id == id) return h;
    return null;
}
fn findMode(self: *OutputManagementGlobal, client: *Server.Client, id: u32) ?*Mode {
    for (self.modes.items) |m| if (m.client == client and m.resource.id == id) return m;
    return null;
}
fn scaleFromFixed(raw: i32) error{InvalidScale}!render.Scale {
    if (raw <= 0) return error.InvalidScale;
    const numerator = (@as(u64, @intCast(raw)) * render.Scale.denominator + 128) / 256;
    if (numerator > std.math.maxInt(u32)) return error.InvalidScale;
    return .{ .numerator = @intCast(@max(numerator, 1)) };
}
fn fixedScale(scale: render.Scale) error{InvalidScale}!i32 {
    if (scale.numerator == 0) return error.InvalidScale;
    const raw = (@as(u64, scale.numerator) * 256 + render.Scale.denominator / 2) / render.Scale.denominator;
    if (raw > std.math.maxInt(i32)) return error.InvalidScale;
    return @intCast(@max(raw, 1));
}
fn remove(comptime T: type, list: *std.ArrayList(*T), item: *T, allocator: std.mem.Allocator) void {
    for (list.items, 0..) |v, i| {
        if (v == item) {
            _ = list.orderedRemove(i);
            allocator.destroy(item);
            return;
        }
    }
    unreachable;
}
fn destroyManager(ctx: *anyopaque, _: *Server.Client, _: wayring.ObjectHandle) void {
    const m: *Manager = @ptrCast(@alignCast(ctx));
    remove(Manager, &m.owner.managers, m, m.owner.allocator);
}
fn dispatchHead(_: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, msg: *wayring.Message) !void {
    _ = try generated.zwlr_output_head_v1_types.decodeRequest(&client.connection, resource, msg);
}
fn destroyHead(ctx: *anyopaque, _: *Server.Client, _: wayring.ObjectHandle) void {
    const h: *Head = @ptrCast(@alignCast(ctx));
    if (h.mode) |m| m.head = null;
    remove(Head, &h.owner.heads, h, h.owner.allocator);
}
fn dispatchMode(_: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, msg: *wayring.Message) !void {
    _ = try generated.zwlr_output_mode_v1_types.decodeRequest(&client.connection, resource, msg);
}
fn destroyMode(ctx: *anyopaque, _: *Server.Client, _: wayring.ObjectHandle) void {
    const m: *Mode = @ptrCast(@alignCast(ctx));
    if (m.head) |h| h.mode = null;
    remove(Mode, &m.owner.modes, m, m.owner.allocator);
}
fn destroyConfig(ctx: *anyopaque, client: *Server.Client, _: wayring.ObjectHandle) void {
    const c: *Config = @ptrCast(@alignCast(ctx));
    if (c.child) |h| {
        c.child = null;
        h.config = null;
        client.destroyResource(h.resource) catch {};
    }
    remove(Config, &c.owner.configs, c, c.owner.allocator);
}
fn destroyConfigHead(ctx: *anyopaque, _: *Server.Client, _: wayring.ObjectHandle) void {
    const h: *ConfigHead = @ptrCast(@alignCast(ctx));
    if (h.config) |c| c.child = null;
    h.owner.allocator.destroy(h);
}

test "output management fixed scale preserves fractional render scale" {
    try std.testing.expectEqual(@as(i32, 256), try fixedScale(.{ .numerator = 120 }));
    try std.testing.expectEqual(@as(i32, 320), try fixedScale(.{ .numerator = 150 }));
    try std.testing.expectEqual(@as(i32, 384), try fixedScale(.{ .numerator = 180 }));
    try std.testing.expectEqual(@as(u32, 150), (try scaleFromFixed(320)).numerator);
    try std.testing.expectEqual(@as(u32, 180), (try scaleFromFixed(384)).numerator);
}

test "output management rejects non-positive fixed scale" {
    try std.testing.expectEqual(@as(u32, 1), (try scaleFromFixed(1)).numerator);
    try std.testing.expectError(error.InvalidScale, scaleFromFixed(0));
    try std.testing.expectError(error.InvalidScale, scaleFromFixed(-1));
    try std.testing.expectEqual(@as(i32, 2), try fixedScale(.{ .numerator = 1 }));
    try std.testing.expectError(error.InvalidScale, fixedScale(.{ .numerator = std.math.maxInt(u32) }));
}

const TestResize = struct {
    calls: usize = 0,
    size: render.Size = .{ .width = 0, .height = 0 },
    scale: render.Scale = .{ .numerator = render.Scale.denominator },

    fn validate(_: *anyopaque, _: render.Size, _: render.Scale) !void {}

    fn resize(context: *anyopaque, size: render.Size, scale: render.Scale) !bool {
        const self: *TestResize = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.size = size;
        self.scale = scale;
        return true;
    }

    fn listener(self: *TestResize) Listener {
        return .{ .context = self, .validate = validate, .resize = resize };
    }
};

const TestGlobals = struct {
    transport: @import("wayring-server-uring") = undefined,
    security: SecurityContextGlobal = undefined,
    output: OutputGlobal = undefined,
    management: OutputManagementGlobal = undefined,
    resize: TestResize = .{},

    fn init(self: *TestGlobals, server: *Server) !void {
        try self.security.init(std.testing.allocator, server, &self.transport);
        errdefer self.security.deinit();
        try self.output.init(std.testing.allocator, server, .{
            .mode_size = .{ .width = 1280, .height = 720 },
            .logical_size = .{ .width = 1024, .height = 576 },
            .physical_size = .{ .width = 300, .height = 170 },
            .refresh_millihertz = 60_000,
            .scale = 1,
            .name = "TEST-1",
            .description = "Test output",
            .make = "Keywork",
            .model = "Test Panel",
        });
        errdefer self.output.deinit();
        try self.management.init(std.testing.allocator, server, &self.output, .{ .numerator = 150 }, &self.security, self.resize.listener());
    }

    fn deinit(self: *TestGlobals) void {
        self.management.deinit();
        self.output.deinit();
        self.security.deinit();
    }
};

fn transferToServer(peer: *wayring.Connection, client: *Server.Client) !void {
    while (peer.nextBatch()) |batch| {
        try client.receive(batch.bytes, batch.fds);
        try peer.acknowledge(batch.token, batch.bytes.len);
    }
}

fn transferFromServer(peer: *wayring.Connection, client: *Server.Client) !void {
    while (client.connection.nextBatch()) |batch| {
        try peer.feed(batch.bytes, batch.fds);
        try client.connection.acknowledge(batch.token, batch.bytes.len);
    }
    try client.outputDrained();
}

fn expectDisplayError(peer: *wayring.Connection, object_id: u32, code: u32) !void {
    const core = @import("wayring-core");
    var found = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id != 1) continue;
        switch (try core.decodeDisplayEvent(&message)) {
            .error_event => |event| {
                try std.testing.expectEqual(object_id, event.object_id);
                try std.testing.expectEqual(code, event.code);
                found = true;
            },
            .delete_id => {},
        }
    }
    try std.testing.expect(found);
}

const TestBound = struct {
    registry: wayring.ObjectHandle,
    manager: wayring.ObjectHandle,
    head: wayring.ObjectHandle,
    mode: wayring.ObjectHandle,
};

fn registerServerId(peer: *wayring.Connection, id: u32, interface: *const wayring.Interface, version: u32) !wayring.ObjectHandle {
    const handle: wayring.ObjectHandle = .{ .id = id, .generation = try peer.registerObject(id, interface, version) };
    try peer.resumeParsing();
    return handle;
}

fn bindAndCheckSnapshot(peer: *wayring.Connection, client: *Server.Client, globals: *TestGlobals, first_id: u32) !TestBound {
    const core = @import("wayring-core");
    _ = try core.bootstrapDisplay(peer);
    const registry: wayring.ObjectHandle = .{ .id = first_id, .generation = try core.getRegistry(peer, first_id) };
    try transferToServer(peer, client);
    try transferFromServer(peer, client);
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        _ = try core.decodeRegistryEvent(&message, registry.id);
    }
    return bindAndCheckSnapshotOnRegistry(peer, client, globals, registry, first_id + 1);
}

fn bindAndCheckSnapshotOnRegistry(peer: *wayring.Connection, client: *Server.Client, globals: *TestGlobals, registry: wayring.ObjectHandle, manager_id: u32) !TestBound {
    const core = @import("wayring-core");
    const manager: wayring.ObjectHandle = .{ .id = manager_id, .generation = try core.bind(peer, registry.id, globals.management.global_name, generated.zwlr_output_manager_v1.name, 4, manager_id, &generated.zwlr_output_manager_v1) };
    try transferToServer(peer, client);
    try transferFromServer(peer, client);
    var head: wayring.ObjectHandle = undefined;
    var mode: wayring.ObjectHandle = undefined;
    var index: usize = 0;
    while (peer.popMessage()) |popped| : (index += 1) {
        var message = popped;
        defer message.deinit();
        switch (index) {
            0 => head = try registerServerId(peer, (try generated.zwlr_output_manager_v1_types.decodeEvent(peer, manager, &message)).head.head, &generated.zwlr_output_head_v1, 4),
            1 => try std.testing.expectEqualStrings(globals.output.outputName(), (try generated.zwlr_output_head_v1_types.decodeEvent(peer, head, &message)).name.name),
            2 => try std.testing.expectEqualStrings(globals.output.outputDescription(), (try generated.zwlr_output_head_v1_types.decodeEvent(peer, head, &message)).description.description),
            3 => {
                const event = (try generated.zwlr_output_head_v1_types.decodeEvent(peer, head, &message)).physical_size;
                try std.testing.expectEqual(@as(i32, 300), event.width);
                try std.testing.expectEqual(@as(i32, 170), event.height);
            },
            4 => mode = try registerServerId(peer, (try generated.zwlr_output_head_v1_types.decodeEvent(peer, head, &message)).mode.mode, &generated.zwlr_output_mode_v1, 3),
            5 => {
                const event = (try generated.zwlr_output_mode_v1_types.decodeEvent(peer, mode, &message)).size;
                try std.testing.expectEqual(@as(i32, 1280), event.width);
                try std.testing.expectEqual(@as(i32, 720), event.height);
            },
            6 => try std.testing.expectEqual(@as(i32, 60_000), (try generated.zwlr_output_mode_v1_types.decodeEvent(peer, mode, &message)).refresh.refresh),
            7 => try std.testing.expect((try generated.zwlr_output_mode_v1_types.decodeEvent(peer, mode, &message)) == .preferred),
            8 => try std.testing.expectEqual(@as(i32, 1), (try generated.zwlr_output_head_v1_types.decodeEvent(peer, head, &message)).enabled.enabled),
            9 => try std.testing.expectEqual(mode.id, (try generated.zwlr_output_head_v1_types.decodeEvent(peer, head, &message)).current_mode.mode),
            10 => {
                const event = (try generated.zwlr_output_head_v1_types.decodeEvent(peer, head, &message)).position;
                try std.testing.expectEqual(@as(i32, 0), event.x);
                try std.testing.expectEqual(@as(i32, 0), event.y);
            },
            11 => try std.testing.expectEqual(@as(i32, 0), (try generated.zwlr_output_head_v1_types.decodeEvent(peer, head, &message)).transform.transform),
            12 => try std.testing.expectEqual(@as(i32, 320), (try generated.zwlr_output_head_v1_types.decodeEvent(peer, head, &message)).scale.scale),
            13 => try std.testing.expectEqualStrings("Keywork", (try generated.zwlr_output_head_v1_types.decodeEvent(peer, head, &message)).make.make),
            14 => try std.testing.expectEqualStrings("Test Panel", (try generated.zwlr_output_head_v1_types.decodeEvent(peer, head, &message)).model.model),
            15 => try std.testing.expectEqual(@as(u32, 0), (try generated.zwlr_output_head_v1_types.decodeEvent(peer, head, &message)).adaptive_sync.state),
            16 => try std.testing.expectEqual(@as(u32, 1), (try generated.zwlr_output_manager_v1_types.decodeEvent(peer, manager, &message)).done.serial),
            else => return error.UnexpectedOutputManagementEvent,
        }
    }
    try std.testing.expectEqual(@as(usize, 17), index);
    return .{ .registry = registry, .manager = manager, .head = head, .mode = mode };
}

test "output management v4 wire snapshot has exact sequence and values" {
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var globals: TestGlobals = .{};
    try globals.init(&server);
    defer globals.deinit();
    const client = try server.createClient();
    defer server.destroyClient(client) catch {};
    var peer = wayring.Connection.init(std.testing.allocator, .client, wayring.default_max_frame_size);
    defer peer.deinit();
    _ = try bindAndCheckSnapshot(&peer, client, &globals, 2);
}

test "output management wire apply stale and test transactions" {
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var globals: TestGlobals = .{};
    try globals.init(&server);
    defer globals.deinit();
    const client = try server.createClient();
    defer server.destroyClient(client) catch {};
    var peer = wayring.Connection.init(std.testing.allocator, .client, wayring.default_max_frame_size);
    defer peer.deinit();
    const bound = try bindAndCheckSnapshot(&peer, client, &globals, 2);

    const config = try generated.zwlr_output_manager_v1_types.requests.create_configuration(&peer, bound.manager, 1);
    const config_head = try generated.zwlr_output_configuration_v1_types.requests.enable_head(&peer, config, bound.head);
    try generated.zwlr_output_configuration_head_v1_types.requests.set_custom_mode(&peer, config_head, 640, 360, 0);
    try generated.zwlr_output_configuration_head_v1_types.requests.set_scale(&peer, config_head, 256);
    try generated.zwlr_output_configuration_v1_types.requests.apply(&peer, config);
    try transferToServer(&peer, client);
    try std.testing.expectEqual(@as(usize, 1), globals.resize.calls);
    try std.testing.expectEqual(@as(u32, 640), globals.resize.size.width);
    try std.testing.expectEqual(@as(u32, 360), globals.resize.size.height);
    try std.testing.expectEqual(render.Scale.denominator, globals.resize.scale.numerator);
    try transferFromServer(&peer, client);
    var event_index: usize = 0;
    while (peer.popMessage()) |popped| : (event_index += 1) {
        var message = popped;
        defer message.deinit();
        switch (event_index) {
            0, 1, 2 => _ = try generated.zwlr_output_mode_v1_types.decodeEvent(&peer, bound.mode, &message),
            3, 4 => _ = try generated.zwlr_output_head_v1_types.decodeEvent(&peer, bound.head, &message),
            5 => try std.testing.expectEqual(@as(u32, 2), (try generated.zwlr_output_manager_v1_types.decodeEvent(&peer, bound.manager, &message)).done.serial),
            6 => try std.testing.expect((try generated.zwlr_output_configuration_v1_types.decodeEvent(&peer, config, &message)) == .succeeded),
            else => return error.UnexpectedOutputManagementEvent,
        }
    }
    try std.testing.expectEqual(@as(usize, 7), event_index);

    const stale = try generated.zwlr_output_manager_v1_types.requests.create_configuration(&peer, bound.manager, 1);
    _ = try generated.zwlr_output_configuration_v1_types.requests.enable_head(&peer, stale, bound.head);
    try generated.zwlr_output_configuration_v1_types.requests.apply(&peer, stale);
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    var stale_message = (peer.popMessage() orelse return error.MissingCancelledEvent);
    defer stale_message.deinit();
    try std.testing.expect((try generated.zwlr_output_configuration_v1_types.decodeEvent(&peer, stale, &stale_message)) == .cancelled);

    const tested = try generated.zwlr_output_manager_v1_types.requests.create_configuration(&peer, bound.manager, 2);
    _ = try generated.zwlr_output_configuration_v1_types.requests.enable_head(&peer, tested, bound.head);
    try generated.zwlr_output_configuration_v1_types.requests.@"test"(&peer, tested);
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    try std.testing.expectEqual(@as(usize, 1), globals.resize.calls);
    try std.testing.expectEqual(@as(u32, 2), globals.management.serial);
}

test "output management changed state preserves each bound head mode pair" {
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var globals: TestGlobals = .{};
    try globals.init(&server);
    defer globals.deinit();
    const client = try server.createClient();
    defer server.destroyClient(client) catch {};
    var peer = wayring.Connection.init(std.testing.allocator, .client, wayring.default_max_frame_size);
    defer peer.deinit();
    const first = try bindAndCheckSnapshot(&peer, client, &globals, 2);
    const second = try bindAndCheckSnapshotOnRegistry(&peer, client, &globals, first.registry, 20);

    const config = try generated.zwlr_output_manager_v1_types.requests.create_configuration(&peer, first.manager, 1);
    const config_head = try generated.zwlr_output_configuration_v1_types.requests.enable_head(&peer, config, first.head);
    try generated.zwlr_output_configuration_head_v1_types.requests.set_custom_mode(&peer, config_head, 640, 360, 0);
    try generated.zwlr_output_configuration_v1_types.requests.apply(&peer, config);
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);

    var first_current: ?u32 = null;
    var second_current: ?u32 = null;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == first.head.id) {
            const event = try generated.zwlr_output_head_v1_types.decodeEvent(&peer, first.head, &message);
            if (event == .current_mode) first_current = event.current_mode.mode;
        } else if (message.object_id == second.head.id) {
            const event = try generated.zwlr_output_head_v1_types.decodeEvent(&peer, second.head, &message);
            if (event == .current_mode) second_current = event.current_mode.mode;
        }
    }
    try std.testing.expectEqual(first.mode.id, first_current orelse return error.MissingFirstCurrentMode);
    try std.testing.expectEqual(second.mode.id, second_current orelse return error.MissingSecondCurrentMode);

    try generated.zwlr_output_head_v1_types.requests.release(&peer, first.head);
    try generated.zwlr_output_mode_v1_types.requests.release(&peer, second.mode);
    try transferToServer(&peer, client);
    try std.testing.expectEqual(@as(usize, 1), globals.management.heads.items.len);
    try std.testing.expectEqual(@as(usize, 1), globals.management.modes.items.len);
    try std.testing.expect(globals.management.heads.items[0].mode == null);
    try std.testing.expect(globals.management.modes.items[0].head == null);
}

test "output management wire reports parent already-used and head invalid-transform errors" {
    const ConfigError = generated.zwlr_output_configuration_v1_types.@"error";
    const HeadError = generated.zwlr_output_configuration_head_v1_types.@"error";

    for ([_]bool{ false, true }) |separate_batch| {
        var server = Server.init(std.testing.allocator);
        defer server.deinit();
        var globals: TestGlobals = .{};
        try globals.init(&server);
        defer globals.deinit();
        const client = try server.createClient();
        defer server.destroyClient(client) catch {};
        var peer = wayring.Connection.init(std.testing.allocator, .client, wayring.default_max_frame_size);
        defer peer.deinit();
        const bound = try bindAndCheckSnapshot(&peer, client, &globals, 2);
        const config = try generated.zwlr_output_manager_v1_types.requests.create_configuration(&peer, bound.manager, 1);
        const head = try generated.zwlr_output_configuration_v1_types.requests.enable_head(&peer, config, bound.head);
        try generated.zwlr_output_configuration_head_v1_types.requests.set_mode(&peer, head, bound.mode);
        try generated.zwlr_output_configuration_head_v1_types.requests.set_position(&peer, head, 0, 0);
        try generated.zwlr_output_configuration_head_v1_types.requests.set_transform(&peer, head, 0);
        try generated.zwlr_output_configuration_head_v1_types.requests.set_scale(&peer, head, 320);
        try generated.zwlr_output_configuration_head_v1_types.requests.set_adaptive_sync(&peer, head, 0);
        try generated.zwlr_output_configuration_v1_types.requests.@"test"(&peer, config);
        if (separate_batch) try transferToServer(&peer, client);
        try generated.zwlr_output_configuration_head_v1_types.requests.set_custom_mode(&peer, head, 640, 360, 0);
        try std.testing.expectError(error.ProtocolError, transferToServer(&peer, client));
        try transferFromServer(&peer, client);
        try expectDisplayError(&peer, config.id, @intFromEnum(ConfigError.already_used));
    }

    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var globals: TestGlobals = .{};
    try globals.init(&server);
    defer globals.deinit();
    const client = try server.createClient();
    defer server.destroyClient(client) catch {};
    var peer = wayring.Connection.init(std.testing.allocator, .client, wayring.default_max_frame_size);
    defer peer.deinit();
    const bound = try bindAndCheckSnapshot(&peer, client, &globals, 20);
    const config = try generated.zwlr_output_manager_v1_types.requests.create_configuration(&peer, bound.manager, 1);
    const head = try generated.zwlr_output_configuration_v1_types.requests.enable_head(&peer, config, bound.head);
    try generated.zwlr_output_configuration_head_v1_types.requests.set_transform(&peer, head, 8);
    try std.testing.expectError(error.ProtocolError, transferToServer(&peer, client));
    try transferFromServer(&peer, client);
    try expectDisplayError(&peer, head.id, @intFromEnum(HeadError.invalid_transform));
}

test "output management resources have independent wire lifetimes" {
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var globals: TestGlobals = .{};
    try globals.init(&server);
    defer globals.deinit();
    const client = try server.createClient();
    var alive = true;
    defer if (alive) server.destroyClient(client) catch {};
    var peer = wayring.Connection.init(std.testing.allocator, .client, wayring.default_max_frame_size);
    defer peer.deinit();
    const bound = try bindAndCheckSnapshot(&peer, client, &globals, 2);
    const config = try generated.zwlr_output_manager_v1_types.requests.create_configuration(&peer, bound.manager, 1);
    const config_head = try generated.zwlr_output_configuration_v1_types.requests.enable_head(&peer, config, bound.head);
    try generated.zwlr_output_configuration_head_v1_types.requests.set_scale(&peer, config_head, 256);
    try generated.zwlr_output_configuration_v1_types.requests.destroy(&peer, config);
    try generated.zwlr_output_manager_v1_types.requests.stop(&peer, bound.manager);
    try generated.zwlr_output_head_v1_types.requests.release(&peer, bound.head);
    try generated.zwlr_output_mode_v1_types.requests.release(&peer, bound.mode);
    try transferToServer(&peer, client);
    try std.testing.expectEqual(@as(usize, 0), globals.management.configs.items.len);
    try std.testing.expectEqual(@as(usize, 0), globals.management.managers.items.len);
    try std.testing.expectEqual(@as(usize, 0), globals.management.heads.items.len);
    try std.testing.expectEqual(@as(usize, 0), globals.management.modes.items.len);
    try server.destroyClient(client);
    alive = false;
}

test "output management configuration survives released snapshot resources" {
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var globals: TestGlobals = .{};
    try globals.init(&server);
    defer globals.deinit();
    const client = try server.createClient();
    defer server.destroyClient(client) catch {};
    var peer = wayring.Connection.init(std.testing.allocator, .client, wayring.default_max_frame_size);
    defer peer.deinit();
    const bound = try bindAndCheckSnapshot(&peer, client, &globals, 2);

    const config = try generated.zwlr_output_manager_v1_types.requests.create_configuration(&peer, bound.manager, 1);
    const config_head = try generated.zwlr_output_configuration_v1_types.requests.enable_head(&peer, config, bound.head);
    try generated.zwlr_output_configuration_head_v1_types.requests.set_custom_mode(&peer, config_head, 800, 450, 0);
    try generated.zwlr_output_mode_v1_types.requests.release(&peer, bound.mode);
    try generated.zwlr_output_head_v1_types.requests.release(&peer, bound.head);
    try generated.zwlr_output_configuration_v1_types.requests.apply(&peer, config);
    try transferToServer(&peer, client);

    try std.testing.expectEqual(@as(usize, 1), globals.resize.calls);
    try std.testing.expectEqual(@as(u32, 800), globals.resize.size.width);
    try std.testing.expectEqual(@as(u32, 450), globals.resize.size.height);
    try std.testing.expectEqual(@as(usize, 0), globals.management.heads.items.len);
    try std.testing.expectEqual(@as(usize, 0), globals.management.modes.items.len);
    try transferFromServer(&peer, client);
    var succeeded = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == config.id)
            succeeded = (try generated.zwlr_output_configuration_v1_types.decodeEvent(&peer, config, &message)) == .succeeded;
    }
    try std.testing.expect(succeeded);
}

test "output management changed apply publishes with either snapshot child released" {
    for ([_]bool{ false, true }) |release_head| {
        var server = Server.init(std.testing.allocator);
        defer server.deinit();
        var globals: TestGlobals = .{};
        try globals.init(&server);
        defer globals.deinit();
        const client = try server.createClient();
        defer server.destroyClient(client) catch {};
        var peer = wayring.Connection.init(std.testing.allocator, .client, wayring.default_max_frame_size);
        defer peer.deinit();
        const bound = try bindAndCheckSnapshot(&peer, client, &globals, 40);
        const config = try generated.zwlr_output_manager_v1_types.requests.create_configuration(&peer, bound.manager, 1);
        const config_head = try generated.zwlr_output_configuration_v1_types.requests.enable_head(&peer, config, bound.head);
        try generated.zwlr_output_configuration_head_v1_types.requests.set_custom_mode(&peer, config_head, 800, 450, 0);
        try generated.zwlr_output_configuration_head_v1_types.requests.set_scale(&peer, config_head, 256);
        if (release_head)
            try generated.zwlr_output_head_v1_types.requests.release(&peer, bound.head)
        else
            try generated.zwlr_output_mode_v1_types.requests.release(&peer, bound.mode);
        try generated.zwlr_output_configuration_v1_types.requests.apply(&peer, config);
        try transferToServer(&peer, client);
        try transferFromServer(&peer, client);
        var saw_scale = false;
        var saw_mode_size = false;
        var saw_done = false;
        var saw_success = false;
        while (peer.popMessage()) |popped| {
            var message = popped;
            defer message.deinit();
            if (!release_head and message.object_id == bound.head.id) {
                const event = try generated.zwlr_output_head_v1_types.decodeEvent(&peer, bound.head, &message);
                if (event == .scale) saw_scale = true;
            } else if (release_head and message.object_id == bound.mode.id) {
                const event = try generated.zwlr_output_mode_v1_types.decodeEvent(&peer, bound.mode, &message);
                if (event == .size) saw_mode_size = true;
            } else if (message.object_id == bound.manager.id) {
                saw_done = (try generated.zwlr_output_manager_v1_types.decodeEvent(&peer, bound.manager, &message)) == .done;
            } else if (message.object_id == config.id) {
                saw_success = (try generated.zwlr_output_configuration_v1_types.decodeEvent(&peer, config, &message)) == .succeeded;
            }
        }
        try std.testing.expect(if (release_head) saw_mode_size else saw_scale);
        try std.testing.expect(saw_done and saw_success);
    }
}

test "output management global rejects confined and guessed binds" {
    const core = @import("wayring-core");
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var globals: TestGlobals = .{};
    try globals.init(&server);
    defer globals.deinit();
    const client = try server.createClientWithProvenance(try SecurityContextGlobal.Testing.confinedProvenance(std.testing.allocator));
    defer server.destroyClient(client) catch {};
    var peer = wayring.Connection.init(std.testing.allocator, .client, wayring.default_max_frame_size);
    defer peer.deinit();
    _ = try core.bootstrapDisplay(&peer);
    const registry: wayring.ObjectHandle = .{ .id = 2, .generation = try core.getRegistry(&peer, 2) };
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const event = try core.decodeRegistryEvent(&message, registry.id);
        if (event == .global) try std.testing.expect(!std.mem.eql(u8, event.global.interface, generated.zwlr_output_manager_v1.name));
    }
    _ = try core.bind(&peer, registry.id, globals.management.global_name, generated.zwlr_output_manager_v1.name, 4, 3, &generated.zwlr_output_manager_v1);
    try std.testing.expectError(error.ProtocolError, transferToServer(&peer, client));
}
