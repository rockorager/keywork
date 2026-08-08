//! Scanner-backed xdg-output metadata over canonical generated outputs.

const WayringXdgOutput = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayring = @import("wayring");
const Output = @import("output.zig");
const OutputLayout = @import("output_layout.zig");
const WayringOutput = @import("WayringOutput.zig");

const server = wayring.server;

const Manager = struct { owner: *WayringXdgOutput, client: *server.Client, resource: protocol.zxdg_output_manager_v1.Resource };
const Managed = struct {
    owner: *WayringXdgOutput,
    client: *server.Client,
    resource: protocol.zxdg_output_v1.Resource,
    output: ?OutputLayout.Id,
    wl_output_id: u32,
};

allocator: std.mem.Allocator,
protocol_server: *server.Server,
outputs: *WayringOutput,
layout: *OutputLayout,
global: ?*const server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
managed: std.ArrayList(*Managed) = .empty,

pub fn init(self: *WayringXdgOutput, allocator: std.mem.Allocator, protocol_server: *server.Server, outputs: *WayringOutput, layout: *OutputLayout) void {
    self.* = .{ .allocator = allocator, .protocol_server = protocol_server, .outputs = outputs, .layout = layout };
    outputs.setMetadataListener(.{
        .context = self,
        .configured = outputConfigured,
        .removing = outputRemoving,
    });
}

pub fn publish(self: *WayringXdgOutput) !void {
    self.global = try self.protocol_server.addGlobal(protocol.zxdg_output_manager_v1, 3, WayringXdgOutput, self, bind);
}

pub fn unpublish(self: *WayringXdgOutput) void {
    self.protocol_server.removeGlobal(self.global.?) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}

pub fn destroyClientResources(self: *WayringXdgOutput, client: *server.Client) void {
    var i = self.managed.items.len;
    while (i > 0) : (i -= 1) if (self.managed.items[i - 1].client == client) self.destroyManaged(self.managed.items[i - 1]);
    i = self.managers.items.len;
    while (i > 0) : (i -= 1) if (self.managers.items[i - 1].client == client) self.destroyManager(self.managers.items[i - 1]);
}

pub fn deinit(self: *WayringXdgOutput) void {
    std.debug.assert(self.global == null and self.managers.items.len == 0 and self.managed.items.len == 0);
    self.outputs.clearMetadataListener(self);
    self.managed.deinit(self.allocator);
    self.managers.deinit(self.allocator);
    self.* = undefined;
}

fn bind(client: *server.Client, id: u32, version: u32, self: *WayringXdgOutput) !void {
    try self.managers.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Manager);
    errdefer self.allocator.destroy(value);
    value.* = .{ .owner = self, .client = client, .resource = .init(self.allocator, id, version, .client, client.ownerHooks()) };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Manager, value, handleManager, null);
    try client.materialize(&value.resource.runtime);
    self.managers.appendAssumeCapacity(value);
}

fn handleManager(_: *protocol.zxdg_output_manager_v1.Resource, request: protocol.zxdg_output_manager_v1.Request, value: *Manager) !void {
    switch (request) {
        .destroy => value.owner.destroyManager(value),
        .get_xdg_output => |args| try value.owner.createManaged(value, args.id, args.output),
    }
}

fn createManaged(self: *WayringXdgOutput, manager: *Manager, id: u32, output_object: u32) !void {
    try self.managed.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Managed);
    errdefer self.allocator.destroy(value);
    value.* = .{
        .owner = self,
        .client = manager.client,
        .resource = .init(self.allocator, id, manager.resource.version(), .client, manager.client.ownerHooks()),
        .output = self.outputs.outputIdForResource(manager.client, output_object),
        .wl_output_id = output_object,
    };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Managed, value, handleManaged, null);
    try manager.client.materialize(&value.resource.runtime);
    self.managed.appendAssumeCapacity(value);
    self.sendInitial(value);
}

fn sendInitial(self: *WayringXdgOutput, value: *Managed) void {
    const id = value.output orelse return;
    const output = self.layout.get(id) orelse {
        value.output = null;
        return;
    };
    const position = output.logicalPosition();
    const size = output.logicalSize();
    protocol.zxdg_output_v1.@"send:logical_position"(&value.resource, position.x, position.y) catch return eventFailure(value);
    protocol.zxdg_output_v1.@"send:logical_size"(&value.resource, @intCast(size.width), @intCast(size.height)) catch return eventFailure(value);
    if (value.resource.version() >= 2) {
        protocol.zxdg_output_v1.@"send:name"(&value.resource, output.name()) catch return eventFailure(value);
        protocol.zxdg_output_v1.@"send:description"(&value.resource, output.description()) catch return eventFailure(value);
    }
    if (value.resource.version() < 3) {
        protocol.zxdg_output_v1.@"send:done"(&value.resource) catch return eventFailure(value);
    } else if (value.client.lookup(value.wl_output_id)) |runtime| {
        // Since v3 wl_output.done terminates the xdg-output update batch.
        const wl_resource: *protocol.wl_output.Resource = @fieldParentPtr("runtime", runtime);
        if (wl_resource.version() >= 2) protocol.wl_output.@"send:done"(wl_resource) catch return eventFailure(value);
    }
}

fn outputConfigured(context: *anyopaque, id: OutputLayout.Id, changes: Output.Changes) void {
    const self: *WayringXdgOutput = @ptrCast(@alignCast(context));
    if (!changes.geometry and !changes.logical_size) return;
    for (self.managed.items) |value| {
        if (value.output == null or !std.meta.eql(value.output.?, id)) continue;
        const output = self.layout.get(id) orelse {
            value.output = null;
            continue;
        };
        if (changes.geometry) {
            const position = output.logicalPosition();
            protocol.zxdg_output_v1.@"send:logical_position"(&value.resource, position.x, position.y) catch {
                eventFailure(value);
                continue;
            };
        }
        if (changes.logical_size) {
            const size = output.logicalSize();
            protocol.zxdg_output_v1.@"send:logical_size"(&value.resource, @intCast(size.width), @intCast(size.height)) catch {
                eventFailure(value);
                continue;
            };
        }
        if (value.resource.version() < 3)
            protocol.zxdg_output_v1.@"send:done"(&value.resource) catch eventFailure(value);
    }
}

fn outputRemoving(context: *anyopaque, id: OutputLayout.Id) void {
    const self: *WayringXdgOutput = @ptrCast(@alignCast(context));
    for (self.managed.items) |value| {
        if (value.output != null and std.meta.eql(value.output.?, id)) value.output = null;
    }
}

fn handleManaged(_: *protocol.zxdg_output_v1.Resource, request: protocol.zxdg_output_v1.Request, value: *Managed) !void {
    switch (request) {
        .destroy => value.owner.destroyManaged(value),
    }
}
fn eventFailure(value: *Managed) void {
    value.client.postOutOfMemory(&value.resource.runtime, "sending xdg-output metadata");
}
fn destroyManaged(self: *WayringXdgOutput, value: *Managed) void {
    remove(Managed, &self.managed, value);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}
fn destroyManager(self: *WayringXdgOutput, value: *Manager) void {
    remove(Manager, &self.managers, value);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}
fn remove(comptime T: type, list: *std.ArrayList(*T), value: *T) void {
    for (list.items, 0..) |item, i| if (item == value) {
        _ = list.swapRemove(i);
        return;
    };
    unreachable;
}

test "generated xdg-output descriptors pin unstable v1 version 3" {
    try std.testing.expectEqual(@as(u32, 3), protocol.zxdg_output_manager_v1.interface.version);
    try std.testing.expectEqual(@as(u32, 3), protocol.zxdg_output_v1.interface.version);
    try std.testing.expectEqualStrings("get_xdg_output", protocol.zxdg_output_manager_v1.request_messages[1].name);
    try std.testing.expectEqual(@as(u32, 2), protocol.zxdg_output_v1.event_messages[3].since);
}
