//! Scanner-backed opaque image-capture source identities.

const Self = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayring = @import("wayring");
const XdgShell = @import("../XdgShell.zig");
const OutputLayout = @import("output_layout.zig");
const WayringForeignToplevelList = @import("WayringForeignToplevelList.zig");
const WayringOutput = @import("WayringOutput.zig");

const server = wayring.server;

pub const Target = union(enum) {
    output: OutputLayout.Id,
    toplevel: XdgShell.WindowId,
};

pub const InvalidationListener = struct {
    context: *anyopaque,
    invalidated: *const fn (*anyopaque, Target) void,
};

const OutputManager = struct {
    owner: *Self,
    client: *server.Client,
    resource: protocol.ext_output_image_capture_source_manager_v1.Resource,
};

const ToplevelManager = struct {
    owner: *Self,
    client: *server.Client,
    resource: protocol.ext_foreign_toplevel_image_capture_source_manager_v1.Resource,
};

const Source = struct {
    owner: *Self,
    client: *server.Client,
    resource: protocol.ext_image_capture_source_v1.Resource,
    target: ?Target,
};

allocator: std.mem.Allocator,
protocol_server: *server.Server,
outputs: *WayringOutput,
foreign_toplevels: *WayringForeignToplevelList,
xdg_shell: *XdgShell,
authorized_uid: std.os.linux.uid_t,
output_global: ?*const server.Server.Global = null,
toplevel_global: ?*const server.Server.Global = null,
output_managers: std.ArrayList(*OutputManager) = .empty,
toplevel_managers: std.ArrayList(*ToplevelManager) = .empty,
sources: std.ArrayList(*Source) = .empty,
listener: ?InvalidationListener = null,

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    protocol_server: *server.Server,
    outputs: *WayringOutput,
    foreign_toplevels: *WayringForeignToplevelList,
    xdg_shell: *XdgShell,
    authorized_uid: std.os.linux.uid_t,
) !void {
    self.* = .{
        .allocator = allocator,
        .protocol_server = protocol_server,
        .outputs = outputs,
        .foreign_toplevels = foreign_toplevels,
        .xdg_shell = xdg_shell,
        .authorized_uid = authorized_uid,
    };
    errdefer self.sources.deinit(allocator);
    errdefer self.toplevel_managers.deinit(allocator);
    errdefer self.output_managers.deinit(allocator);
    try xdg_shell.addWindowObserver(.{
        .context = self,
        .committed = windowIgnored,
        .unmapped = windowRemoved,
        .destroyed = windowRemoved,
        .metadata_changed = windowIgnored,
        .state_changed = windowIgnored,
    });
}

pub fn publish(self: *Self) !void {
    std.debug.assert(self.output_global == null and self.toplevel_global == null);
    self.output_global = try self.protocol_server.addGlobalWithOptions(
        protocol.ext_output_image_capture_source_manager_v1,
        1,
        Self,
        self,
        bindOutputManager,
        .{ .visibility = .restricted },
    );
    errdefer {
        self.protocol_server.removeGlobal(self.output_global.?) catch {};
        self.output_global = null;
    }
    self.toplevel_global = try self.protocol_server.addGlobalWithOptions(
        protocol.ext_foreign_toplevel_image_capture_source_manager_v1,
        1,
        Self,
        self,
        bindToplevelManager,
        .{ .visibility = .restricted },
    );
}

pub fn unpublish(self: *Self) void {
    self.protocol_server.removeGlobal(self.toplevel_global orelse unreachable) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.toplevel_global = null;
    self.protocol_server.removeGlobal(self.output_global orelse unreachable) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.output_global = null;
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.output_global == null and self.toplevel_global == null);
    std.debug.assert(self.output_managers.items.len == 0 and
        self.toplevel_managers.items.len == 0 and self.sources.items.len == 0);
    std.debug.assert(self.listener == null);
    self.xdg_shell.removeWindowObserver(self);
    self.sources.deinit(self.allocator);
    self.toplevel_managers.deinit(self.allocator);
    self.output_managers.deinit(self.allocator);
    self.* = undefined;
}

pub fn setInvalidationListener(self: *Self, listener: InvalidationListener) void {
    std.debug.assert(self.listener == null);
    self.listener = listener;
}

pub fn clearInvalidationListener(self: *Self) void {
    std.debug.assert(self.listener != null);
    self.listener = null;
}

pub fn targetForResource(
    self: *Self,
    client: *server.Client,
    object_id: u32,
) ?Target {
    const installed = client.lookup(object_id) orelse return null;
    for (self.sources.items) |source| {
        if (source.client == client and source.resource.state() == .live and
            &source.resource.runtime == installed) return source.target;
    }
    return null;
}

pub fn removeOutput(self: *Self, output: OutputLayout.Id) void {
    self.invalidate(.{ .output = output });
}

pub fn destroyClientResources(self: *Self, client: *server.Client) void {
    var index = self.sources.items.len;
    while (index > 0) {
        index -= 1;
        if (self.sources.items[index].client == client) self.destroySource(self.sources.items[index]);
    }
    index = self.toplevel_managers.items.len;
    while (index > 0) {
        index -= 1;
        if (self.toplevel_managers.items[index].client == client)
            self.destroyToplevelManager(self.toplevel_managers.items[index]);
    }
    index = self.output_managers.items.len;
    while (index > 0) {
        index -= 1;
        if (self.output_managers.items[index].client == client)
            self.destroyOutputManager(self.output_managers.items[index]);
    }
}

fn bindOutputManager(client: *server.Client, id: u32, version: u32, self: *Self) !void {
    if (version != 1) return error.InvalidVersion;
    if (!client.isAuthorizedDirectPeer(self.authorized_uid)) return error.Unauthorized;
    try self.output_managers.ensureUnusedCapacity(self.allocator, 1);
    const manager = try self.allocator.create(OutputManager);
    errdefer self.allocator.destroy(manager);
    manager.* = .{
        .owner = self,
        .client = client,
        .resource = .init(self.allocator, id, version, .client, client.ownerHooks()),
    };
    errdefer {
        manager.resource.destroy();
        manager.resource.deinit();
    }
    try manager.resource.setHandler(OutputManager, manager, outputManagerRequest, null);
    try client.materialize(&manager.resource.runtime);
    self.output_managers.appendAssumeCapacity(manager);
}

fn outputManagerRequest(
    _: *protocol.ext_output_image_capture_source_manager_v1.Resource,
    request: protocol.ext_output_image_capture_source_manager_v1.Request,
    manager: *OutputManager,
) !void {
    switch (request) {
        .destroy => manager.owner.destroyOutputManager(manager),
        .create_source => |args| {
            const target: ?Target = switch (manager.owner.outputs.identifyResource(
                manager.client,
                args.output,
            )) {
                .live => |identity| .{ .output = identity.output },
                .retired, .invalid => null,
            };
            try manager.owner.createSource(manager.client, args.source, target);
        },
    }
}

fn bindToplevelManager(client: *server.Client, id: u32, version: u32, self: *Self) !void {
    if (version != 1) return error.InvalidVersion;
    if (!client.isAuthorizedDirectPeer(self.authorized_uid)) return error.Unauthorized;
    try self.toplevel_managers.ensureUnusedCapacity(self.allocator, 1);
    const manager = try self.allocator.create(ToplevelManager);
    errdefer self.allocator.destroy(manager);
    manager.* = .{
        .owner = self,
        .client = client,
        .resource = .init(self.allocator, id, version, .client, client.ownerHooks()),
    };
    errdefer {
        manager.resource.destroy();
        manager.resource.deinit();
    }
    try manager.resource.setHandler(ToplevelManager, manager, toplevelManagerRequest, null);
    try client.materialize(&manager.resource.runtime);
    self.toplevel_managers.appendAssumeCapacity(manager);
}

fn toplevelManagerRequest(
    _: *protocol.ext_foreign_toplevel_image_capture_source_manager_v1.Resource,
    request: protocol.ext_foreign_toplevel_image_capture_source_manager_v1.Request,
    manager: *ToplevelManager,
) !void {
    switch (request) {
        .destroy => manager.owner.destroyToplevelManager(manager),
        .create_source => |args| {
            const window = manager.owner.foreign_toplevels.windowForExtHandle(
                manager.client,
                args.toplevel_handle,
            );
            try manager.owner.createSource(
                manager.client,
                args.source,
                if (window) |id| .{ .toplevel = id } else null,
            );
        },
    }
}

fn createSource(self: *Self, client: *server.Client, id: u32, target: ?Target) !void {
    try self.sources.ensureUnusedCapacity(self.allocator, 1);
    const source = try self.allocator.create(Source);
    errdefer self.allocator.destroy(source);
    source.* = .{
        .owner = self,
        .client = client,
        .resource = .init(self.allocator, id, 1, .client, client.ownerHooks()),
        .target = target,
    };
    errdefer {
        source.resource.destroy();
        source.resource.deinit();
    }
    try source.resource.setHandler(Source, source, sourceRequest, null);
    try client.materialize(&source.resource.runtime);
    self.sources.appendAssumeCapacity(source);
}

fn sourceRequest(
    _: *protocol.ext_image_capture_source_v1.Resource,
    request: protocol.ext_image_capture_source_v1.Request,
    source: *Source,
) !void {
    switch (request) {
        .destroy => source.owner.destroySource(source),
    }
}

fn invalidate(self: *Self, target: Target) void {
    for (self.sources.items) |source| {
        const current = source.target orelse continue;
        if (std.meta.eql(current, target)) source.target = null;
    }
    if (self.listener) |listener| listener.invalidated(listener.context, target);
}

fn windowRemoved(context: *anyopaque, window: XdgShell.WindowId) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.invalidate(.{ .toplevel = window });
}

fn windowIgnored(_: *anyopaque, _: XdgShell.WindowId) void {}

fn destroySource(self: *Self, source: *Source) void {
    removePointer(Source, &self.sources, source);
    source.resource.destroy();
    source.resource.deinit();
    self.allocator.destroy(source);
}

fn destroyToplevelManager(self: *Self, manager: *ToplevelManager) void {
    removePointer(ToplevelManager, &self.toplevel_managers, manager);
    manager.resource.destroy();
    manager.resource.deinit();
    self.allocator.destroy(manager);
}

fn destroyOutputManager(self: *Self, manager: *OutputManager) void {
    removePointer(OutputManager, &self.output_managers, manager);
    manager.resource.destroy();
    manager.resource.deinit();
    self.allocator.destroy(manager);
}

fn removePointer(comptime T: type, list: *std.ArrayList(*T), value: *T) void {
    for (list.items, 0..) |candidate, index| if (candidate == value) {
        _ = list.swapRemove(index);
        return;
    };
    unreachable;
}

test "image capture source descriptors match scanner contract" {
    try std.testing.expectEqual(@as(u32, 1), protocol.ext_image_capture_source_v1.interface.version);
    try std.testing.expectEqualStrings(
        "create_source",
        protocol.ext_output_image_capture_source_manager_v1.request_messages[0].name,
    );
    try std.testing.expectEqualStrings(
        "create_source",
        protocol.ext_foreign_toplevel_image_capture_source_manager_v1.request_messages[0].name,
    );
}
