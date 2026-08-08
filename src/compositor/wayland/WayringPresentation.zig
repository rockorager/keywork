//! Scanner-backed presentation-time feedback for generated surfaces.

const WayringPresentation = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayring = @import("wayring");
const presentation = @import("../presentation.zig");
const OutputLayout = @import("../output_layout.zig");
const WayringCompositor = @import("WayringCompositor.zig");
const WayringOutput = @import("WayringOutput.zig");

const server = wayring.server;

const Manager = struct {
    owner: *WayringPresentation,
    client: *server.Client,
    resource: protocol.wp_presentation.Resource,
};

const Feedback = struct {
    owner: *WayringPresentation,
    client: *server.Client,
    resource: protocol.wp_presentation_feedback.Resource,
    surface: WayringCompositor.SurfaceId,
    output: ?OutputLayout.Id = null,
    handler: WayringCompositor.PresentationFeedbackHandler,
};

allocator: std.mem.Allocator,
protocol_server: *server.Server,
compositor: *WayringCompositor,
outputs: *WayringOutput,
global: ?*const server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
feedbacks: std.ArrayList(*Feedback) = .empty,

pub fn init(self: *WayringPresentation, allocator: std.mem.Allocator, protocol_server: *server.Server, compositor: *WayringCompositor, outputs: *WayringOutput) void {
    self.* = .{ .allocator = allocator, .protocol_server = protocol_server, .compositor = compositor, .outputs = outputs };
}

pub fn publish(self: *WayringPresentation) !void {
    self.global = try self.protocol_server.addGlobal(protocol.wp_presentation, 2, WayringPresentation, self, bind);
}

pub fn unpublish(self: *WayringPresentation) void {
    self.protocol_server.removeGlobal(self.global.?) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}

pub fn destroyClientResources(self: *WayringPresentation, client: *server.Client) void {
    var index = self.feedbacks.items.len;
    while (index > 0) : (index -= 1) if (self.feedbacks.items[index - 1].client == client) self.destroyFeedback(self.feedbacks.items[index - 1]);
    index = self.managers.items.len;
    while (index > 0) : (index -= 1) if (self.managers.items[index - 1].client == client) self.destroyManager(self.managers.items[index - 1]);
}

pub fn deinit(self: *WayringPresentation) void {
    std.debug.assert(self.global == null and self.feedbacks.items.len == 0 and self.managers.items.len == 0);
    self.feedbacks.deinit(self.allocator);
    self.managers.deinit(self.allocator);
    self.* = undefined;
}

fn bind(client: *server.Client, id: u32, version: u32, self: *WayringPresentation) !void {
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
    protocol.wp_presentation.@"send:clock_id"(&value.resource, presentation.monotonic_clock_id) catch eventFailure(client, &value.resource.runtime, "sending presentation clock");
}

fn handleManager(_: *protocol.wp_presentation.Resource, request: protocol.wp_presentation.Request, value: *Manager) !void {
    switch (request) {
        .destroy => value.owner.destroyManager(value),
        .feedback => |args| try value.owner.createFeedback(value, args.callback, args.surface),
    }
}

fn createFeedback(self: *WayringPresentation, manager: *Manager, id: u32, surface_object: u32) !void {
    try self.feedbacks.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Feedback);
    errdefer self.allocator.destroy(value);
    value.* = .{
        .owner = self,
        .client = manager.client,
        .resource = .init(self.allocator, id, manager.resource.version(), .client, manager.client.ownerHooks()),
        .surface = undefined,
        .handler = .{ .context = value, .sampled = sampled, .presented = presented, .discarded = discarded },
    };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    const result = try self.compositor.addPresentationFeedback(manager.client, surface_object, &value.handler);
    value.surface = switch (result) {
        .attached => |surface| surface,
        .not_live, .wrong_client => {
            value.resource.destroy();
            value.resource.deinit();
            self.allocator.destroy(value);
            manager.client.postImplementationError(&manager.resource.runtime, "presentation feedback references an invalid surface");
            return;
        },
    };
    errdefer self.compositor.removePresentationFeedback(value.surface, &value.handler);
    try manager.client.materialize(&value.resource.runtime);
    self.feedbacks.appendAssumeCapacity(value);
}

fn sampled(context: *anyopaque, output: OutputLayout.Id) void {
    const self: *Feedback = @ptrCast(@alignCast(context));
    self.output = output;
}

fn sendSyncOutput(context: *anyopaque, resource: *protocol.wl_output.Resource) void {
    const self: *Feedback = @ptrCast(@alignCast(context));
    protocol.wp_presentation_feedback.@"send:sync_output"(&self.resource, resource.id()) catch
        eventFailure(self.client, &self.resource.runtime, "sending presentation output");
}

fn presented(context: *anyopaque, info: presentation.Info) void {
    const self: *Feedback = @ptrCast(@alignCast(context));
    if (self.output) |output| self.owner.outputs.forEachClientResource(output, self.client, self, sendSyncOutput);
    protocol.wp_presentation_feedback.@"send:presented"(&self.resource, info.timestamp.highSeconds(), info.timestamp.lowSeconds(), info.timestamp.nanoseconds, info.refresh_nanoseconds, info.highSequence(), info.lowSequence(), @bitCast(info.flags)) catch
        eventFailure(self.client, &self.resource.runtime, "sending presentation result");
    self.owner.destroyFeedback(self);
}

fn discarded(context: *anyopaque) void {
    const self: *Feedback = @ptrCast(@alignCast(context));
    protocol.wp_presentation_feedback.@"send:discarded"(&self.resource) catch
        eventFailure(self.client, &self.resource.runtime, "sending discarded presentation");
    self.owner.destroyFeedback(self);
}

fn eventFailure(client: *server.Client, resource: *server.Resource, message: []const u8) void {
    client.postOutOfMemory(resource, message);
}

fn destroyFeedback(self: *WayringPresentation, value: *Feedback) void {
    remove(Feedback, &self.feedbacks, value);
    self.compositor.removePresentationFeedback(value.surface, &value.handler);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}

fn destroyManager(self: *WayringPresentation, value: *Manager) void {
    remove(Manager, &self.managers, value);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}

fn remove(comptime T: type, list: *std.ArrayList(*T), value: *T) void {
    for (list.items, 0..) |item, index| if (item == value) {
        _ = list.swapRemove(index);
        return;
    };
    unreachable;
}

test "presentation descriptors pin stable version two and terminal events" {
    try std.testing.expectEqual(@as(u32, 2), protocol.wp_presentation.interface.version);
    try std.testing.expectEqualStrings("clock_id", protocol.wp_presentation.event_messages[0].name);
    try std.testing.expect(protocol.wp_presentation_feedback.event_messages[1].destructor);
    try std.testing.expect(protocol.wp_presentation_feedback.event_messages[2].destructor);
}
