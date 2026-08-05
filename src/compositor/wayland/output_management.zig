//! Connected output-head discovery and complete configuration transactions.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const DrmOutput = @import("../backend/drm.zig");
const SurfaceRegistry = @import("../SurfaceRegistry.zig");
const render = @import("../render/types.zig");
const Output = @import("output.zig");
const SecurityContext = @import("security_context.zig");

const wl = wayland.server.wl;
const zwlr = wayland.server.zwlr;

allocator: std.mem.Allocator,
global: *wl.Global,
security_context: *SecurityContext,
serial: u32,
heads: std.ArrayList(*Head),
managers: std.ArrayList(*ManagerResource),
head_resources: std.ArrayList(*HeadResource),
mode_resources: std.ArrayList(*ModeResource),
configurations: std.ArrayList(*Configuration),
listener: Listener,

pub const Change = struct {
    target: Target,
    was_enabled: bool,
    enabled: bool,
    old_x: i32,
    old_y: i32,
    old_scale: render.Scale,
    old_mode_index: usize,
    x: i32,
    y: i32,
    scale: render.Scale,
    mode_index: usize,
    custom_mode: ?CustomMode,
};

pub const Target = union(enum) {
    drm: *DrmOutput,
    virtual: *Output,
};

pub const CustomMode = struct {
    width: u32,
    height: u32,
    refresh_millihertz: i32,
};

pub const VirtualHeadConfig = struct {
    output: *Output,
    mode_size: render.Size,
    refresh_millihertz: i32,
    physical_size: render.Size,
    make: []const u8,
    model: []const u8,
    serial: []const u8 = "",
};

pub const Listener = struct {
    context: *anyopaque,
    test_configuration: *const fn (*anyopaque, []const Change) bool,
    apply: *const fn (*anyopaque, []const Change) bool,
};

const Head = struct {
    target: ?Target,
    connected: bool,
    name: [:0]u8,
    description: [:0]u8,
    make: [:0]u8,
    model: [:0]u8,
    serial: [:0]u8,
    enabled: bool,
    x: i32,
    y: i32,
    scale: render.Scale,
    modes: []Mode,
    current_mode_index: usize,
    physical_size: struct { width: u32, height: u32 },
};

const Mode = struct {
    size: render.Size,
    refresh_millihertz: i32,
    preferred: bool,
};

const ManagerResource = struct {
    manager: *Self,
    resource: ?*zwlr.OutputManagerV1,
    stopped: bool,
};

const HeadResource = struct {
    manager: *Self,
    head: *Head,
    resource: ?*zwlr.OutputHeadV1,
    finished: bool,
};

const ModeResource = struct {
    owner: *HeadResource,
    mode_index: usize,
    resource: ?*zwlr.OutputModeV1,
    finished: bool,
};

const Configuration = struct {
    manager: *Self,
    resource: *zwlr.OutputConfigurationV1,
    serial: u32,
    used: bool,
    heads: std.ArrayList(*ConfiguredHead),
};

const ConfiguredHead = struct {
    configuration: *Configuration,
    head: *Head,
    enabled: bool,
    resource: ?*zwlr.OutputConfigurationHeadV1,
    mode_set: bool = false,
    mode_index: ?usize = null,
    custom_mode: ?CustomMode = null,
    position: ?struct { x: i32, y: i32 } = null,
    transform: ?wl.Output.Transform = null,
    scale: ?wl.Fixed = null,
    adaptive_sync: ?zwlr.OutputHeadV1.AdaptiveSyncState = null,
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    outputs: []const *DrmOutput,
    security_context: *SecurityContext,
    listener: Listener,
) !void {
    self.* = .{
        .allocator = allocator,
        .global = undefined,
        .security_context = security_context,
        .serial = 1,
        .heads = .empty,
        .managers = .empty,
        .head_resources = .empty,
        .mode_resources = .empty,
        .configurations = .empty,
        .listener = listener,
    };
    errdefer self.deinitStorage();
    for (outputs) |output| _ = try self.addDrmHeadStorage(output);
    self.global = try wl.Global.create(
        display,
        zwlr.OutputManagerV1,
        4,
        *Self,
        self,
        bind,
    );
    errdefer self.global.destroy();
    try security_context.restrictGlobal(self.global);
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.configurations.items.len == 0);
    std.debug.assert(self.managers.items.len == 0);
    std.debug.assert(self.head_resources.items.len == 0);
    std.debug.assert(self.mode_resources.items.len == 0);
    for (self.heads.items) |head| std.debug.assert(head.connected);
    self.security_context.unrestrictGlobal(self.global);
    self.global.destroy();
    self.deinitStorage();
    self.* = undefined;
}

fn deinitStorage(self: *Self) void {
    while (self.configurations.items.len > 0) {
        self.destroyConfiguration(self.configurations.items[0]);
    }
    self.configurations.deinit(self.allocator);
    self.mode_resources.deinit(self.allocator);
    self.head_resources.deinit(self.allocator);
    self.managers.deinit(self.allocator);
    for (self.heads.items) |head| self.deinitHeadStorage(head);
    self.heads.deinit(self.allocator);
}

pub fn addHead(self: *Self, output: *DrmOutput) !void {
    std.debug.assert(self.findHead(.{ .drm = output }) == null);
    const head = try self.addDrmHeadStorage(output);
    try self.advertiseAddedHead(head);
}

pub fn addVirtualHead(self: *Self, config: VirtualHeadConfig) !void {
    std.debug.assert(self.findHead(.{ .virtual = config.output }) == null);
    const head = try self.addVirtualHeadStorage(config);
    try self.advertiseAddedHead(head);
}

fn advertiseAddedHead(self: *Self, head: *Head) !void {
    for (self.managers.items) |manager| {
        if (manager.resource == null or manager.stopped) continue;
        self.createHeadResource(manager, head) catch {
            manager.resource.?.postNoMemory();
            continue;
        };
    }
    self.changed();
}

fn addDrmHeadStorage(self: *Self, output: *DrmOutput) !*Head {
    const drm_modes = output.availableModes();
    const modes = try self.allocator.alloc(Mode, drm_modes.len);
    for (drm_modes, modes) |drm_mode, *mode| {
        mode.* = .{
            .size = drm_mode.size(),
            .refresh_millihertz = drm_mode.refreshMillihertz(),
            .preferred = drm_mode.preferred,
        };
    }
    return self.addHeadStorage(.{
        .target = .{ .drm = output },
        .name = output.name(),
        .description = output.description(),
        .make = output.make() orelse "Unknown",
        .model = output.model() orelse output.name(),
        .serial = output.serial() orelse "",
        .enabled = output.enabled,
        .x = output.logical_x,
        .y = output.logical_y,
        .scale = output.scale,
        .modes = modes,
        .current_mode_index = output.currentModeIndex(),
        .physical_size = output.physical_size,
    });
}

fn addVirtualHeadStorage(self: *Self, config: VirtualHeadConfig) !*Head {
    const modes = try self.allocator.alloc(Mode, 1);
    modes[0] = .{
        .size = config.mode_size,
        .refresh_millihertz = config.refresh_millihertz,
        .preferred = true,
    };
    const position = config.output.logicalPosition();
    return self.addHeadStorage(.{
        .target = .{ .virtual = config.output },
        .name = config.output.name(),
        .description = config.output.description(),
        .make = config.make,
        .model = config.model,
        .serial = config.serial,
        .enabled = true,
        .x = position.x,
        .y = position.y,
        .scale = config.output.preferredScale(),
        .modes = modes,
        .current_mode_index = 0,
        .physical_size = config.physical_size,
    });
}

const HeadStorageConfig = struct {
    target: Target,
    name: []const u8,
    description: []const u8,
    make: []const u8,
    model: []const u8,
    serial: []const u8,
    enabled: bool,
    x: i32,
    y: i32,
    scale: render.Scale,
    modes: []Mode,
    current_mode_index: usize,
    physical_size: render.Size,
};

fn addHeadStorage(self: *Self, config: HeadStorageConfig) !*Head {
    const modes = config.modes;
    errdefer self.allocator.free(modes);
    std.debug.assert(modes.len > 0);
    std.debug.assert(config.current_mode_index < modes.len);
    const name = try self.allocator.dupeSentinel(u8, config.name, 0);
    errdefer self.allocator.free(name);
    const description = try self.allocator.dupeSentinel(u8, config.description, 0);
    errdefer self.allocator.free(description);
    const make = try self.allocator.dupeSentinel(u8, config.make, 0);
    errdefer self.allocator.free(make);
    const model = try self.allocator.dupeSentinel(u8, config.model, 0);
    errdefer self.allocator.free(model);
    const serial = try self.allocator.dupeSentinel(u8, config.serial, 0);
    errdefer self.allocator.free(serial);
    const head = try self.allocator.create(Head);
    errdefer self.allocator.destroy(head);
    head.* = .{
        .target = config.target,
        .connected = true,
        .name = name,
        .description = description,
        .make = make,
        .model = model,
        .serial = serial,
        .enabled = config.enabled,
        .x = config.x,
        .y = config.y,
        .scale = config.scale,
        .modes = modes,
        .current_mode_index = config.current_mode_index,
        .physical_size = .{
            .width = config.physical_size.width,
            .height = config.physical_size.height,
        },
    };
    try self.heads.append(self.allocator, head);
    return head;
}

pub fn removeHead(self: *Self, output: *DrmOutput) void {
    const head = self.findHead(.{ .drm = output }) orelse return;
    head.target = null;
    head.connected = false;
    for (self.mode_resources.items) |mode| {
        if (mode.owner.head != head or mode.resource == null or mode.finished) continue;
        mode.resource.?.sendFinished();
        mode.finished = true;
    }
    for (self.head_resources.items) |resource| {
        if (resource.head != head or resource.resource == null or resource.finished) continue;
        resource.resource.?.sendFinished();
        resource.finished = true;
    }
    self.changed();
    self.reclaimHead(head);
}

pub fn syncHead(self: *Self, output: *DrmOutput) void {
    const head = self.findHead(.{ .drm = output }) orelse return;
    const enabled_changed = head.enabled != output.enabled;
    const position_changed = head.x != output.logical_x or head.y != output.logical_y;
    const scale_changed = head.scale.numerator != output.scale.numerator;
    const mode_changed = head.current_mode_index != output.currentModeIndex();
    if (!enabled_changed and !position_changed and !scale_changed and !mode_changed) return;
    head.enabled = output.enabled;
    head.x = output.logical_x;
    head.y = output.logical_y;
    head.scale = output.scale;
    head.current_mode_index = output.currentModeIndex();
    for (self.head_resources.items) |advertised| {
        if (advertised.head != head or advertised.resource == null or advertised.finished) continue;
        const resource = advertised.resource.?;
        if (enabled_changed) {
            resource.sendEnabled(@intFromBool(head.enabled));
            if (head.enabled) {
                if (self.modeResource(advertised, head.current_mode_index)) |mode| {
                    resource.sendCurrentMode(mode);
                }
                resource.sendTransform(.normal);
                resource.sendScale(scaleToFixed(head.scale));
            }
        } else if (head.enabled and mode_changed) {
            if (self.modeResource(advertised, head.current_mode_index)) |mode| {
                resource.sendCurrentMode(mode);
            }
        }
        if (head.enabled and (enabled_changed or position_changed)) {
            resource.sendPosition(head.x, head.y);
        }
        if (head.enabled and !enabled_changed and scale_changed) {
            resource.sendScale(scaleToFixed(head.scale));
        }
    }
    self.changed();
}

pub fn syncVirtualHead(
    self: *Self,
    output: *Output,
    mode_size: render.Size,
    refresh_millihertz: i32,
    scale: render.Scale,
) void {
    const head = self.findHead(.{ .virtual = output }) orelse return;
    std.debug.assert(head.modes.len == 1);
    const mode = &head.modes[0];
    const mode_changed = !std.meta.eql(mode.size, mode_size) or
        mode.refresh_millihertz != refresh_millihertz;
    const scale_changed = head.scale.numerator != scale.numerator;
    if (!mode_changed and !scale_changed) return;
    mode.size = mode_size;
    mode.refresh_millihertz = refresh_millihertz;
    head.scale = scale;
    for (self.head_resources.items) |advertised| {
        if (advertised.head != head or advertised.resource == null or advertised.finished) continue;
        const resource = advertised.resource.?;
        if (mode_changed) {
            if (self.modeResource(advertised, 0)) |mode_resource| {
                mode_resource.sendSize(@intCast(mode_size.width), @intCast(mode_size.height));
                if (refresh_millihertz > 0) mode_resource.sendRefresh(refresh_millihertz);
                resource.sendCurrentMode(mode_resource);
            }
        }
        if (scale_changed) resource.sendScale(scaleToFixed(scale));
    }
    self.changed();
}

fn findHead(self: *Self, target: Target) ?*Head {
    for (self.heads.items) |head| {
        if (head.connected and head.target != null and targetsEqual(head.target.?, target)) return head;
    }
    return null;
}

fn targetsEqual(a: Target, b: Target) bool {
    return switch (a) {
        .drm => |output| switch (b) {
            .drm => |candidate| output == candidate,
            .virtual => false,
        },
        .virtual => |output| switch (b) {
            .drm => false,
            .virtual => |candidate| output == candidate,
        },
    };
}

fn changed(self: *Self) void {
    self.serial +%= 1;
    if (self.serial == 0) self.serial = 1;
    for (self.managers.items) |manager| {
        if (manager.resource) |resource| if (!manager.stopped) resource.sendDone(self.serial);
    }
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = zwlr.OutputManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    const manager = self.allocator.create(ManagerResource) catch {
        resource.postNoMemory();
        resource.destroy();
        return;
    };
    manager.* = .{ .manager = self, .resource = resource, .stopped = false };
    self.managers.append(self.allocator, manager) catch {
        self.allocator.destroy(manager);
        resource.postNoMemory();
        resource.destroy();
        return;
    };
    resource.setHandler(*ManagerResource, managerRequest, managerDestroyed, manager);
    for (self.heads.items) |head| {
        if (!head.connected) continue;
        self.createHeadResource(manager, head) catch {
            resource.postNoMemory();
            return;
        };
    }
    resource.sendDone(self.serial);
}

fn managerRequest(
    resource: *zwlr.OutputManagerV1,
    request: zwlr.OutputManagerV1.Request,
    manager: *ManagerResource,
) void {
    switch (request) {
        .create_configuration => |create| manager.manager.createConfiguration(
            manager,
            create.id,
            create.serial,
        ),
        .stop => {
            manager.stopped = true;
            resource.destroySendFinished();
        },
    }
}

fn managerDestroyed(_: *zwlr.OutputManagerV1, manager: *ManagerResource) void {
    const self = manager.manager;
    for (self.managers.items, 0..) |candidate, index| {
        if (candidate != manager) continue;
        _ = self.managers.orderedRemove(index);
        self.allocator.destroy(manager);
        return;
    }
    unreachable;
}

fn createHeadResource(self: *Self, manager: *ManagerResource, head: *Head) !void {
    const manager_resource = manager.resource.?;
    try self.head_resources.ensureUnusedCapacity(self.allocator, 1);
    try self.mode_resources.ensureUnusedCapacity(self.allocator, head.modes.len);
    const head_resource = try zwlr.OutputHeadV1.create(
        manager_resource.getClient(),
        manager_resource.getVersion(),
        0,
    );
    errdefer head_resource.destroy();
    const managed = try self.allocator.create(HeadResource);
    errdefer self.allocator.destroy(managed);
    managed.* = .{
        .manager = self,
        .head = head,
        .resource = head_resource,
        .finished = false,
    };

    const modes = try self.allocator.alloc(*ModeResource, head.modes.len);
    defer self.allocator.free(modes);
    var created_modes: usize = 0;
    errdefer for (modes[0..created_modes]) |mode| {
        mode.resource.?.destroy();
        self.allocator.destroy(mode);
    };
    for (head.modes, 0..) |_, mode_index| {
        const resource = try zwlr.OutputModeV1.create(
            manager_resource.getClient(),
            @min(manager_resource.getVersion(), zwlr.OutputModeV1.generated_version),
            0,
        );
        const mode = self.allocator.create(ModeResource) catch |err| {
            resource.destroy();
            return err;
        };
        mode.* = .{
            .owner = managed,
            .mode_index = mode_index,
            .resource = resource,
            .finished = false,
        };
        modes[mode_index] = mode;
        created_modes += 1;
    }

    self.head_resources.appendAssumeCapacity(managed);
    for (modes) |mode| self.mode_resources.appendAssumeCapacity(mode);

    head_resource.setHandler(*HeadResource, headRequest, headDestroyed, managed);
    for (modes) |mode| {
        mode.resource.?.setHandler(*ModeResource, modeRequest, modeDestroyed, mode);
    }
    manager_resource.sendHead(head_resource);
    head_resource.sendName(head.name);
    head_resource.sendDescription(head.description);
    head_resource.sendPhysicalSize(
        @intCast(head.physical_size.width),
        @intCast(head.physical_size.height),
    );
    for (head.modes, modes) |mode, advertised| {
        const resource = advertised.resource.?;
        head_resource.sendMode(resource);
        resource.sendSize(@intCast(mode.size.width), @intCast(mode.size.height));
        if (mode.refresh_millihertz > 0) resource.sendRefresh(mode.refresh_millihertz);
        if (mode.preferred) resource.sendPreferred();
    }
    head_resource.sendEnabled(@intFromBool(head.enabled));
    if (head.enabled) {
        head_resource.sendCurrentMode(modes[head.current_mode_index].resource.?);
        head_resource.sendPosition(head.x, head.y);
        head_resource.sendTransform(.normal);
        head_resource.sendScale(scaleToFixed(head.scale));
    }
    if (head_resource.getVersion() >= 2) {
        head_resource.sendMake(head.make);
        head_resource.sendModel(head.model);
        if (head.serial.len > 0) head_resource.sendSerialNumber(head.serial);
    }
    if (head_resource.getVersion() >= 4) head_resource.sendAdaptiveSync(.disabled);
}

fn headRequest(
    resource: *zwlr.OutputHeadV1,
    request: zwlr.OutputHeadV1.Request,
    _: *HeadResource,
) void {
    switch (request) {
        .release => resource.destroy(),
    }
}

fn headDestroyed(_: *zwlr.OutputHeadV1, managed: *HeadResource) void {
    managed.resource = null;
    managed.manager.reclaimHeadResource(managed);
}

fn modeRequest(
    resource: *zwlr.OutputModeV1,
    request: zwlr.OutputModeV1.Request,
    _: *ModeResource,
) void {
    switch (request) {
        .release => resource.destroy(),
    }
}

fn modeDestroyed(_: *zwlr.OutputModeV1, managed: *ModeResource) void {
    const owner = managed.owner;
    const self = owner.manager;
    for (self.mode_resources.items, 0..) |candidate, index| {
        if (candidate != managed) continue;
        _ = self.mode_resources.orderedRemove(index);
        self.allocator.destroy(managed);
        self.reclaimHeadResource(owner);
        return;
    }
    unreachable;
}

fn reclaimHeadResource(self: *Self, resource: *HeadResource) void {
    if (resource.resource != null) return;
    for (self.mode_resources.items) |mode| {
        if (mode.owner == resource) return;
    }
    const head = resource.head;
    for (self.head_resources.items, 0..) |candidate, index| {
        if (candidate != resource) continue;
        _ = self.head_resources.orderedRemove(index);
        self.allocator.destroy(resource);
        self.reclaimHead(head);
        return;
    }
    unreachable;
}

fn reclaimHead(self: *Self, head: *Head) void {
    if (head.connected) return;
    for (self.head_resources.items) |resource| {
        if (resource.head == head) return;
    }
    for (self.configurations.items) |configuration| {
        for (configuration.heads.items) |configured| {
            if (configured.head == head) return;
        }
    }
    for (self.heads.items, 0..) |candidate, index| {
        if (candidate != head) continue;
        _ = self.heads.orderedRemove(index);
        self.deinitHeadStorage(head);
        return;
    }
    unreachable;
}

fn deinitHeadStorage(self: *Self, head: *Head) void {
    self.allocator.free(head.modes);
    self.allocator.free(head.serial);
    self.allocator.free(head.model);
    self.allocator.free(head.make);
    self.allocator.free(head.description);
    self.allocator.free(head.name);
    self.allocator.destroy(head);
}

fn modeResource(
    self: *Self,
    owner: *HeadResource,
    mode_index: usize,
) ?*zwlr.OutputModeV1 {
    for (self.mode_resources.items) |mode| {
        if (mode.owner != owner or mode.mode_index != mode_index or mode.finished) continue;
        return mode.resource;
    }
    return null;
}

fn createConfiguration(
    self: *Self,
    owner: *ManagerResource,
    id: u32,
    serial: u32,
) void {
    const manager = owner.resource.?;
    const resource = zwlr.OutputConfigurationV1.create(
        manager.getClient(),
        manager.getVersion(),
        id,
    ) catch {
        manager.postNoMemory();
        return;
    };
    const configuration = self.allocator.create(Configuration) catch {
        resource.postNoMemory();
        resource.destroy();
        return;
    };
    configuration.* = .{
        .manager = self,
        .resource = resource,
        .serial = serial,
        .used = false,
        .heads = .empty,
    };
    self.configurations.append(self.allocator, configuration) catch {
        self.allocator.destroy(configuration);
        resource.postNoMemory();
        resource.destroy();
        return;
    };
    resource.setHandler(
        *Configuration,
        configurationRequest,
        configurationDestroyed,
        configuration,
    );
}

fn configurationRequest(
    resource: *zwlr.OutputConfigurationV1,
    request: zwlr.OutputConfigurationV1.Request,
    configuration: *Configuration,
) void {
    if (configuration.used and request != .destroy) {
        resource.postError(.already_used, "output configuration has already been used");
        return;
    }
    switch (request) {
        .enable_head => |enable| configureHead(configuration, resource, enable.head, enable.id, true),
        .disable_head => |disable| configureHead(configuration, resource, disable.head, null, false),
        .apply => finish(configuration, true),
        .@"test" => finish(configuration, false),
        .destroy => resource.destroy(),
    }
}

fn configurationDestroyed(_: *zwlr.OutputConfigurationV1, configuration: *Configuration) void {
    configuration.manager.destroyConfiguration(configuration);
}

fn destroyConfiguration(self: *Self, configuration: *Configuration) void {
    for (self.configurations.items, 0..) |candidate, index| {
        if (candidate != configuration) continue;
        _ = self.configurations.orderedRemove(index);
        break;
    } else unreachable;
    while (configuration.heads.items.len > 0) {
        const configured = configuration.heads.orderedRemove(configuration.heads.items.len - 1);
        const head = configured.head;
        if (configured.resource) |resource| resource.destroy();
        self.allocator.destroy(configured);
        self.reclaimHead(head);
    }
    configuration.heads.deinit(self.allocator);
    self.allocator.destroy(configuration);
}

fn configureHead(
    self: *Configuration,
    resource: *zwlr.OutputConfigurationV1,
    head_resource: *zwlr.OutputHeadV1,
    id: ?u32,
    enabled: bool,
) void {
    const advertised: *HeadResource = @ptrCast(@alignCast(head_resource.getUserData() orelse {
        resource.postError(.already_configured_head, "invalid output head");
        return;
    }));
    for (self.heads.items) |configured| if (configured.head == advertised.head) {
        resource.postError(.already_configured_head, "output head configured twice");
        return;
    };
    const configured = self.manager.allocator.create(ConfiguredHead) catch {
        resource.postNoMemory();
        return;
    };
    configured.* = .{
        .configuration = self,
        .head = advertised.head,
        .enabled = enabled,
        .resource = null,
    };
    if (id) |new_id| {
        const head_configuration = zwlr.OutputConfigurationHeadV1.create(
            resource.getClient(),
            resource.getVersion(),
            new_id,
        ) catch {
            self.manager.allocator.destroy(configured);
            resource.postNoMemory();
            return;
        };
        configured.resource = head_configuration;
        head_configuration.setHandler(
            *ConfiguredHead,
            configuredHeadRequest,
            configuredHeadDestroyed,
            configured,
        );
    }
    self.heads.append(self.manager.allocator, configured) catch {
        if (configured.resource) |head_configuration| head_configuration.destroy();
        self.manager.allocator.destroy(configured);
        resource.postNoMemory();
    };
}

fn configuredHeadRequest(
    resource: *zwlr.OutputConfigurationHeadV1,
    request: zwlr.OutputConfigurationHeadV1.Request,
    configured: *ConfiguredHead,
) void {
    if (configured.configuration.used) {
        configured.configuration.resource.postError(
            .already_used,
            "output configuration has already been used",
        );
        return;
    }
    switch (request) {
        .set_mode => |set| {
            if (configured.mode_set or configured.custom_mode != null) {
                resource.postError(.already_set, "output mode has already been set");
                return;
            }
            const mode: *ModeResource = @ptrCast(@alignCast(set.mode.getUserData() orelse {
                resource.postError(.invalid_mode, "invalid output mode");
                return;
            }));
            if (mode.owner.head != configured.head or mode.finished) {
                resource.postError(.invalid_mode, "mode does not belong to output head");
                return;
            }
            configured.mode_set = true;
            configured.mode_index = mode.mode_index;
        },
        .set_custom_mode => |set| {
            if (configured.mode_set or configured.custom_mode != null) {
                resource.postError(.already_set, "output mode has already been set");
                return;
            }
            if (set.width <= 0 or set.height <= 0 or set.refresh < 0) {
                resource.postError(.invalid_custom_mode, "invalid custom output mode");
                return;
            }
            configured.custom_mode = .{
                .width = @intCast(set.width),
                .height = @intCast(set.height),
                .refresh_millihertz = set.refresh,
            };
        },
        .set_position => |set| {
            if (configured.position != null) {
                resource.postError(.already_set, "output position has already been set");
                return;
            }
            configured.position = .{ .x = set.x, .y = set.y };
        },
        .set_transform => |set| {
            if (configured.transform != null) {
                resource.postError(.already_set, "output transform has already been set");
                return;
            }
            if (@intFromEnum(set.transform) < 0 or @intFromEnum(set.transform) > 7) {
                resource.postError(.invalid_transform, "invalid output transform");
                return;
            }
            configured.transform = set.transform;
        },
        .set_scale => |set| {
            if (configured.scale != null) {
                resource.postError(.already_set, "output scale has already been set");
                return;
            }
            _ = scaleFromFixed(set.scale) catch {
                resource.postError(.invalid_scale, "output scale is not supported");
                return;
            };
            configured.scale = set.scale;
        },
        .set_adaptive_sync => |set| {
            if (configured.adaptive_sync != null) {
                resource.postError(.already_set, "adaptive sync has already been set");
                return;
            }
            if (set.state != .disabled and set.state != .enabled) {
                resource.postError(.invalid_adaptive_sync_state, "invalid adaptive sync state");
                return;
            }
            configured.adaptive_sync = set.state;
        },
    }
}

fn configuredHeadDestroyed(
    _: *zwlr.OutputConfigurationHeadV1,
    configured: *ConfiguredHead,
) void {
    configured.resource = null;
}

fn finish(configuration: *Configuration, apply: bool) void {
    configuration.used = true;
    for (configuration.heads.items) |configured| {
        if (configured.resource) |resource| resource.destroy();
    }
    const manager = configuration.manager;
    if (configuration.serial != manager.serial) {
        configuration.resource.sendCancelled();
        return;
    }
    var connected_count: usize = 0;
    for (manager.heads.items) |head| {
        if (!head.connected) continue;
        connected_count += 1;
        var found = false;
        for (configuration.heads.items) |configured| {
            if (configured.head == head) {
                found = true;
                break;
            }
        }
        if (!found) {
            configuration.resource.postError(.unconfigured_head, "output head was omitted");
            return;
        }
    }
    if (configuration.heads.items.len != connected_count) {
        configuration.resource.sendCancelled();
        return;
    }

    var enabled_count: usize = 0;
    for (configuration.heads.items) |configured| {
        if (!configured.head.connected) {
            configuration.resource.sendCancelled();
            return;
        }
        if (!configured.enabled) continue;
        enabled_count += 1;
        if ((configured.transform != null and configured.transform.? != .normal) or
            (configured.adaptive_sync != null and configured.adaptive_sync.? != .disabled))
        {
            configuration.resource.sendFailed();
            return;
        }
        const mode_index = configured.mode_index orelse configured.head.current_mode_index;
        const scale = if (configured.scale) |value|
            scaleFromFixed(value) catch unreachable
        else
            configured.head.scale;
        const x = if (configured.position) |position| position.x else configured.head.x;
        const y = if (configured.position) |position| position.y else configured.head.y;
        const mode_size = if (configured.custom_mode) |custom|
            render.Size{ .width = custom.width, .height = custom.height }
        else
            configured.head.modes[mode_index].size;
        if (!modeGeometryValid(mode_size, scale, x, y)) {
            configuration.resource.sendFailed();
            return;
        }
    }
    if (enabled_count == 0) {
        configuration.resource.sendFailed();
        return;
    }

    var changes: std.ArrayList(Change) = .empty;
    defer changes.deinit(manager.allocator);
    for (configuration.heads.items) |configured| {
        const head = configured.head;
        const x = if (configured.position) |position| position.x else head.x;
        const y = if (configured.position) |position| position.y else head.y;
        const scale = if (configured.scale) |value| scaleFromFixed(value) catch unreachable else head.scale;
        const mode_index = configured.mode_index orelse head.current_mode_index;
        changes.append(manager.allocator, .{
            .target = head.target.?,
            .was_enabled = head.enabled,
            .enabled = configured.enabled,
            .old_x = head.x,
            .old_y = head.y,
            .old_scale = head.scale,
            .old_mode_index = head.current_mode_index,
            .x = x,
            .y = y,
            .scale = scale,
            .mode_index = mode_index,
            .custom_mode = configured.custom_mode,
        }) catch {
            configuration.resource.postNoMemory();
            return;
        };
    }
    if (!apply) {
        if (manager.listener.test_configuration(manager.listener.context, changes.items)) {
            configuration.resource.sendSucceeded();
        } else {
            configuration.resource.sendFailed();
        }
        return;
    }
    if (!manager.listener.apply(manager.listener.context, changes.items)) {
        configuration.resource.sendFailed();
        return;
    }

    var state_changed = false;
    for (changes.items) |change| {
        const head = manager.findHead(change.target) orelse continue;
        const enabled_changed = head.enabled != change.enabled;
        const position_changed = head.x != change.x or head.y != change.y;
        const scale_changed = head.scale.numerator != change.scale.numerator;
        const mode_changed = head.current_mode_index != change.mode_index;
        if (enabled_changed) {
            head.enabled = change.enabled;
            state_changed = true;
            for (manager.head_resources.items) |advertised| {
                if (advertised.head != head or advertised.resource == null or advertised.finished) continue;
                const resource = advertised.resource.?;
                resource.sendEnabled(@intFromBool(head.enabled));
                if (head.enabled) {
                    if (manager.modeResource(advertised, change.mode_index)) |mode| {
                        resource.sendCurrentMode(mode);
                    }
                    resource.sendPosition(change.x, change.y);
                    resource.sendTransform(.normal);
                    resource.sendScale(scaleToFixed(change.scale));
                }
            }
        } else if (position_changed or scale_changed or mode_changed) {
            state_changed = true;
            if (head.enabled) {
                for (manager.head_resources.items) |advertised| {
                    if (advertised.head != head or advertised.resource == null or advertised.finished) continue;
                    if (position_changed) advertised.resource.?.sendPosition(change.x, change.y);
                    if (scale_changed) advertised.resource.?.sendScale(scaleToFixed(change.scale));
                    if (mode_changed) {
                        if (manager.modeResource(advertised, change.mode_index)) |mode| {
                            advertised.resource.?.sendCurrentMode(mode);
                        }
                    }
                }
            }
        }
        head.x = change.x;
        head.y = change.y;
        head.scale = change.scale;
        head.current_mode_index = change.mode_index;
    }
    if (state_changed) manager.changed();
    configuration.resource.sendSucceeded();
}

fn scaleFromFixed(value: wl.Fixed) error{InvalidScale}!render.Scale {
    const raw = @intFromEnum(value);
    if (raw <= 0) return error.InvalidScale;
    const numerator = (@as(u64, @intCast(raw)) * render.Scale.denominator + 128) / 256;
    if (numerator == 0 or numerator > std.math.maxInt(u32)) return error.InvalidScale;
    return .{ .numerator = @intCast(numerator) };
}

fn scaleToFixed(scale: render.Scale) wl.Fixed {
    std.debug.assert(scale.numerator > 0);
    const raw = (@as(u64, scale.numerator) * 256 + render.Scale.denominator / 2) /
        render.Scale.denominator;
    std.debug.assert(raw <= std.math.maxInt(i32));
    return @enumFromInt(@as(i32, @intCast(raw)));
}

fn modeGeometryValid(mode_size: render.Size, scale: render.Scale, x: i32, y: i32) bool {
    const logical_size = scale.logicalSize(mode_size) catch return false;
    return Output.logicalGeometryValid(.{ .x = x, .y = y }, logical_size);
}

fn testDeviceFd(_: *anyopaque) ?std.posix.fd_t {
    return null;
}

fn testDeviceActive(_: *anyopaque) bool {
    return false;
}

fn testDeviceFail(_: *anyopaque, _: anyerror) void {
    unreachable;
}

fn testApply(_: *anyopaque, _: []const Change) bool {
    return true;
}

test "output scales round-trip between fixed and v120 units" {
    const scale = try scaleFromFixed(wl.Fixed.fromDouble(1.25));
    try std.testing.expectEqual(@as(u32, 150), scale.numerator);
    try std.testing.expectApproxEqAbs(
        @as(f64, 1.25),
        scaleToFixed(scale).toDouble(),
        1.0 / 256.0,
    );
    try std.testing.expectError(error.InvalidScale, scaleFromFixed(wl.Fixed.fromInt(0)));
}

test "output geometry validation uses the selected mode and scale" {
    var current = std.mem.zeroes(DrmOutput.Mode);
    current.value.hdisplay = 3840;
    current.value.vdisplay = 2160;
    var selected = std.mem.zeroes(DrmOutput.Mode);
    selected.value.hdisplay = 720;
    selected.value.vdisplay = 480;
    const scale: render.Scale = .{ .numerator = 120_000 };

    try std.testing.expect(modeGeometryValid(current.size(), scale, 0, 0));
    try std.testing.expect(!modeGeometryValid(selected.size(), scale, 0, 0));
    try std.testing.expect(!modeGeometryValid(
        current.size(),
        .{},
        std.math.maxInt(i32) - 3839,
        0,
    ));
}

test "virtual head mode and scale stay synchronized" {
    const display = try wl.Server.create();
    defer display.destroy();

    var surfaces: @import("surface.zig").Store = .{};
    defer surfaces.deinit(std.testing.allocator);
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var output: Output = undefined;
    try output.init(
        std.testing.allocator,
        display,
        .{
            .size = .{ .width = 1280, .height = 720 },
            .physical_size = .{ .width = 1280, .height = 720 },
            .scale = 1,
            .name = "HEADLESS-1",
            .description = "Keywork headless output",
            .model = "headless",
        },
        &surface_registry,
        &surfaces,
    );
    defer output.deinit();

    var security_context: SecurityContext = undefined;
    try security_context.init(std.testing.allocator, display);
    defer security_context.deinit();

    var context: u8 = 0;
    var manager: Self = undefined;
    try manager.init(
        std.testing.allocator,
        display,
        &.{},
        &security_context,
        .{ .context = &context, .test_configuration = testApply, .apply = testApply },
    );
    defer manager.deinit();
    try manager.addVirtualHead(.{
        .output = &output,
        .mode_size = .{ .width = 1280, .height = 720 },
        .refresh_millihertz = 60_000,
        .physical_size = .{ .width = 1280, .height = 720 },
        .make = "keywork",
        .model = "headless",
    });

    const initial_serial = manager.serial;
    manager.syncVirtualHead(
        &output,
        .{ .width = 1920, .height = 1080 },
        30_000,
        .{ .numerator = 180 },
    );
    try std.testing.expect(manager.serial != initial_serial);
    try std.testing.expectEqual(render.Size{ .width = 1920, .height = 1080 }, manager.heads.items[0].modes[0].size);
    try std.testing.expectEqual(@as(i32, 30_000), manager.heads.items[0].modes[0].refresh_millihertz);
    try std.testing.expectEqual(@as(u32, 180), manager.heads.items[0].scale.numerator);
}

test "disconnected head storage is reclaimed across reconnects" {
    const display = try wl.Server.create();
    defer display.destroy();

    var context: u8 = 0;
    var output: DrmOutput = undefined;
    output.init(std.testing.allocator, std.testing.io, .{
        .context = &context,
        .fd = testDeviceFd,
        .active = testDeviceActive,
        .fail = testDeviceFail,
    });
    defer output.deinit();
    const name = "eDP-1";
    @memcpy(output.connector_name[0..name.len], name);
    output.connector_name_length = name.len;
    output.size = .{ .width = 1920, .height = 1080 };
    output.physical_size = .{ .width = 300, .height = 170 };
    output.mode.vrefresh = 60;
    output.modes = try std.testing.allocator.alloc(DrmOutput.Mode, 2);
    output.modes[0] = .{ .value = output.mode, .preferred = true };
    output.modes[1] = .{ .value = output.mode, .preferred = false };
    output.modes[1].value.hdisplay = 1280;
    output.modes[1].value.vdisplay = 720;
    output.mode_index = 0;

    var security_context: SecurityContext = undefined;
    try security_context.init(std.testing.allocator, display);
    defer security_context.deinit();

    var manager: Self = undefined;
    try manager.init(
        std.testing.allocator,
        display,
        &.{&output},
        &security_context,
        .{ .context = &context, .test_configuration = testApply, .apply = testApply },
    );
    defer manager.deinit();

    try std.testing.expectEqual(@as(usize, 1), manager.heads.items.len);
    try std.testing.expect(manager.heads.items[0].connected);
    try std.testing.expectEqual(@as(usize, 2), manager.heads.items[0].modes.len);
    try std.testing.expectEqual(@as(usize, 0), manager.heads.items[0].current_mode_index);
    for (0..3) |_| {
        manager.removeHead(&output);
        try std.testing.expectEqual(@as(usize, 0), manager.heads.items.len);
        try manager.addHead(&output);
        try std.testing.expectEqual(@as(usize, 1), manager.heads.items.len);
        try std.testing.expect(manager.heads.items[0].connected);
    }
}

test "configuration retains disconnected head storage" {
    const display = try wl.Server.create();
    defer display.destroy();

    var context: u8 = 0;
    var output: DrmOutput = undefined;
    output.init(std.testing.allocator, std.testing.io, .{
        .context = &context,
        .fd = testDeviceFd,
        .active = testDeviceActive,
        .fail = testDeviceFail,
    });
    defer output.deinit();
    const name = "eDP-1";
    @memcpy(output.connector_name[0..name.len], name);
    output.connector_name_length = name.len;
    output.size = .{ .width = 1920, .height = 1080 };
    output.physical_size = .{ .width = 300, .height = 170 };
    output.mode.vrefresh = 60;
    output.modes = try std.testing.allocator.alloc(DrmOutput.Mode, 1);
    output.modes[0] = .{ .value = output.mode, .preferred = true };
    output.mode_index = 0;

    var security_context: SecurityContext = undefined;
    try security_context.init(std.testing.allocator, display);
    defer security_context.deinit();

    var manager: Self = undefined;
    try manager.init(
        std.testing.allocator,
        display,
        &.{&output},
        &security_context,
        .{ .context = &context, .test_configuration = testApply, .apply = testApply },
    );
    defer manager.deinit();

    const configuration = try std.testing.allocator.create(Configuration);
    configuration.* = .{
        .manager = &manager,
        .resource = undefined,
        .serial = manager.serial,
        .used = false,
        .heads = .empty,
    };
    try manager.configurations.append(std.testing.allocator, configuration);
    const configured = try std.testing.allocator.create(ConfiguredHead);
    configured.* = .{
        .configuration = configuration,
        .head = manager.heads.items[0],
        .enabled = false,
        .resource = null,
    };
    try configuration.heads.append(std.testing.allocator, configured);

    manager.removeHead(&output);
    try std.testing.expectEqual(@as(usize, 1), manager.heads.items.len);
    try std.testing.expect(!manager.heads.items[0].connected);
    manager.destroyConfiguration(configuration);
    try std.testing.expectEqual(@as(usize, 0), manager.heads.items.len);
}
