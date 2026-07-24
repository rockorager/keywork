//! Connected output-head discovery and complete configuration transactions.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const DrmOutput = @import("../backend/drm.zig");
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
    output: *DrmOutput,
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
};

pub const Listener = struct {
    context: *anyopaque,
    apply: *const fn (*anyopaque, []const Change) bool,
};

const Head = struct {
    output: ?*DrmOutput,
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
    modes: []DrmOutput.Mode,
    current_mode_index: usize,
    physical_size: struct { width: u32, height: u32 },
};

const ManagerResource = struct {
    manager: *Self,
    resource: ?*zwlr.OutputManagerV1,
    stopped: bool,
};

const HeadResource = struct {
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
    custom_mode_set: bool = false,
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
    for (outputs) |output| _ = try self.addHeadStorage(output);
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
    for (self.managers.items) |manager| std.debug.assert(manager.resource == null);
    for (self.head_resources.items) |resource| std.debug.assert(resource.resource == null);
    for (self.mode_resources.items) |resource| std.debug.assert(resource.resource == null);
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
    for (self.mode_resources.items) |resource| self.allocator.destroy(resource);
    self.mode_resources.deinit(self.allocator);
    for (self.head_resources.items) |resource| self.allocator.destroy(resource);
    self.head_resources.deinit(self.allocator);
    for (self.managers.items) |manager| self.allocator.destroy(manager);
    self.managers.deinit(self.allocator);
    for (self.heads.items) |head| {
        self.allocator.free(head.modes);
        self.allocator.free(head.serial);
        self.allocator.free(head.model);
        self.allocator.free(head.make);
        self.allocator.free(head.description);
        self.allocator.free(head.name);
        self.allocator.destroy(head);
    }
    self.heads.deinit(self.allocator);
}

pub fn addHead(self: *Self, output: *DrmOutput) !void {
    std.debug.assert(self.findHead(output) == null);
    const head = try self.addHeadStorage(output);
    for (self.managers.items) |manager| {
        if (manager.resource == null or manager.stopped) continue;
        self.createHeadResource(manager, head) catch {
            manager.resource.?.postNoMemory();
            continue;
        };
    }
    self.changed();
}

fn addHeadStorage(self: *Self, output: *DrmOutput) !*Head {
    const name = try self.allocator.dupeSentinel(u8, output.name(), 0);
    errdefer self.allocator.free(name);
    const description = try self.allocator.dupeSentinel(u8, output.description(), 0);
    errdefer self.allocator.free(description);
    const make = try self.allocator.dupeSentinel(u8, output.make() orelse "Unknown", 0);
    errdefer self.allocator.free(make);
    const model = try self.allocator.dupeSentinel(u8, output.model() orelse output.name(), 0);
    errdefer self.allocator.free(model);
    const serial = try self.allocator.dupeSentinel(u8, output.serial() orelse "", 0);
    errdefer self.allocator.free(serial);
    const modes = try self.allocator.dupe(DrmOutput.Mode, output.availableModes());
    errdefer self.allocator.free(modes);
    std.debug.assert(modes.len > 0);
    const current_mode_index = output.currentModeIndex();
    std.debug.assert(current_mode_index < modes.len);
    const head = try self.allocator.create(Head);
    errdefer self.allocator.destroy(head);
    head.* = .{
        .output = output,
        .connected = true,
        .name = name,
        .description = description,
        .make = make,
        .model = model,
        .serial = serial,
        .enabled = output.enabled,
        .x = output.logical_x,
        .y = output.logical_y,
        .scale = output.scale,
        .modes = modes,
        .current_mode_index = current_mode_index,
        .physical_size = .{
            .width = output.physical_size.width,
            .height = output.physical_size.height,
        },
    };
    try self.heads.append(self.allocator, head);
    return head;
}

pub fn removeHead(self: *Self, output: *DrmOutput) void {
    const head = self.findHead(output) orelse return;
    head.output = null;
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
}

pub fn syncHead(self: *Self, output: *DrmOutput) void {
    const head = self.findHead(output) orelse return;
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

fn findHead(self: *Self, output: *DrmOutput) ?*Head {
    for (self.heads.items) |head| {
        if (head.connected and head.output == output) return head;
    }
    return null;
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
    manager.resource = null;
    manager.stopped = true;
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
        const size = mode.size();
        resource.sendSize(@intCast(size.width), @intCast(size.height));
        const refresh = mode.refreshMillihertz();
        if (refresh > 0) resource.sendRefresh(refresh);
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
    managed.resource = null;
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
    for (configuration.heads.items) |configured| {
        if (configured.resource) |resource| resource.destroy();
        self.allocator.destroy(configured);
    }
    configuration.heads.deinit(self.allocator);
    for (self.configurations.items, 0..) |candidate, index| {
        if (candidate != configuration) continue;
        _ = self.configurations.orderedRemove(index);
        self.allocator.destroy(configuration);
        return;
    }
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
            if (configured.mode_set or configured.custom_mode_set) {
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
            if (configured.mode_set or configured.custom_mode_set) {
                resource.postError(.already_set, "output mode has already been set");
                return;
            }
            configured.custom_mode_set = true;
            if (set.width <= 0 or set.height <= 0 or set.refresh < 0) {
                resource.postError(.invalid_custom_mode, "invalid custom output mode");
            }
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
        if (configured.custom_mode_set or
            (configured.transform != null and configured.transform.? != .normal) or
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
        if (!modeGeometryValid(configured.head.modes[mode_index], scale, x, y)) {
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
            .output = head.output.?,
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
        }) catch {
            configuration.resource.postNoMemory();
            return;
        };
    }
    if (!apply) {
        configuration.resource.sendSucceeded();
        return;
    }
    if (!manager.listener.apply(manager.listener.context, changes.items)) {
        configuration.resource.sendFailed();
        return;
    }

    var state_changed = false;
    for (changes.items) |change| {
        const head = manager.findHead(change.output) orelse continue;
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

fn modeGeometryValid(mode: DrmOutput.Mode, scale: render.Scale, x: i32, y: i32) bool {
    const size = scale.logicalSize(mode.size()) catch return false;
    return Output.logicalGeometryValid(.{ .x = x, .y = y }, size);
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

    try std.testing.expect(modeGeometryValid(current, scale, 0, 0));
    try std.testing.expect(!modeGeometryValid(selected, scale, 0, 0));
    try std.testing.expect(!modeGeometryValid(
        current,
        .{},
        std.math.maxInt(i32) - 3839,
        0,
    ));
}

test "connected head storage survives disable and reconnect lifetimes" {
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
        .{ .context = &context, .apply = testApply },
    );
    defer manager.deinit();

    try std.testing.expectEqual(@as(usize, 1), manager.heads.items.len);
    try std.testing.expect(manager.heads.items[0].connected);
    try std.testing.expectEqual(@as(usize, 2), manager.heads.items[0].modes.len);
    try std.testing.expectEqual(@as(usize, 0), manager.heads.items[0].current_mode_index);
    manager.removeHead(&output);
    try std.testing.expect(!manager.heads.items[0].connected);
    try manager.addHead(&output);
    try std.testing.expectEqual(@as(usize, 2), manager.heads.items.len);
    try std.testing.expect(manager.heads.items[1].connected);
}
