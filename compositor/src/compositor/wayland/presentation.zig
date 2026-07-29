//! Presentation-time feedback for committed surface updates.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const presentation = @import("../presentation.zig");
const Output = @import("output.zig");
const Surface = @import("surface.zig");

const wl = wayland.server.wl;
const wp = wayland.server.wp;

allocator: std.mem.Allocator,
global: *wl.Global,
surfaces: *Surface.Store,
clock_id: u32,

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    surfaces: *Surface.Store,
    clock_id: u32,
) !void {
    self.* = .{
        .allocator = allocator,
        .global = try wl.Global.create(display, wp.Presentation, 2, *Self, self, bind),
        .surfaces = surfaces,
        .clock_id = clock_id,
    };
}

pub fn deinit(self: *Self) void {
    self.global.destroy();
    self.* = undefined;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = wp.Presentation.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleRequest, null, self);
    resource.sendClockId(self.clock_id);
}

fn handleRequest(resource: *wp.Presentation, request: wp.Presentation.Request, self: *Self) void {
    switch (request) {
        .destroy => resource.destroy(),
        .feedback => |feedback| {
            const surface = Surface.fromResource(feedback.surface);
            _ = Feedback.create(
                self,
                surface,
                resource.getVersion(),
                feedback.callback,
            ) catch {
                resource.postNoMemory();
            };
        },
    }
}

const Feedback = struct {
    allocator: std.mem.Allocator,
    store: *Surface.Store,
    surface_id: Surface.Id,
    output: ?*Output,
    resource: *wp.PresentationFeedback,
    commit_feedback: Surface.CommitFeedback,

    fn create(
        manager: *Self,
        surface: *Surface,
        version: u32,
        id: u32,
    ) !*Feedback {
        const resource = try wp.PresentationFeedback.create(
            surface.waylandResource().getClient(),
            version,
            id,
        );
        errdefer resource.destroy();

        const self = try manager.allocator.create(Feedback);
        errdefer manager.allocator.destroy(self);
        self.* = .{
            .allocator = manager.allocator,
            .store = manager.surfaces,
            .surface_id = surface.handle(),
            .output = null,
            .resource = resource,
            .commit_feedback = .{
                .context = self,
                .sampled = sampled,
                .presented = presented,
                .discarded = discarded,
            },
        };
        try surface.addCommitFeedback(&self.commit_feedback);
        @as(*wl.Resource, @ptrCast(resource)).setDispatcher(
            null,
            null,
            self,
            handleDestroy,
        );
        return self;
    }

    fn sampled(context: *anyopaque, output_context: *anyopaque) void {
        const self: *Feedback = @ptrCast(@alignCast(context));
        const output: *Output = @ptrCast(@alignCast(output_context));
        self.output = output;
    }

    fn presented(context: *anyopaque, info: presentation.Info) void {
        const self: *Feedback = @ptrCast(@alignCast(context));
        if (self.output) |output| {
            for (output.boundResources()) |output_resource| {
                if (output_resource.getClient() == self.resource.getClient()) {
                    self.resource.sendSyncOutput(output_resource);
                }
            }
        }
        self.resource.destroySendPresented(
            info.timestamp.highSeconds(),
            info.timestamp.lowSeconds(),
            info.timestamp.nanoseconds,
            info.refresh_nanoseconds,
            info.highSequence(),
            info.lowSequence(),
            @bitCast(info.flags),
        );
    }

    fn discarded(context: *anyopaque) void {
        const self: *Feedback = @ptrCast(@alignCast(context));
        self.resource.destroySendDiscarded();
    }

    fn handleDestroy(resource: *wl.Resource) callconv(.c) void {
        const self: *Feedback = @ptrCast(@alignCast(resource.getUserData().?));
        Surface.removeCommitFeedback(self.store, self.surface_id, &self.commit_feedback);
        self.allocator.destroy(self);
    }
};
