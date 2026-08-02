//! Native `wp_presentation` policy and one-shot feedback resources.

const PresentationGlobal = @This();

const std = @import("std");
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const CompositorGlobal = @import("CompositorGlobal.zig");
const OutputGlobal = @import("OutputGlobal.zig");
const presentation = @import("../presentation.zig");

const advertised_version: u32 = 2;

allocator: std.mem.Allocator,
server: *Server,
compositor: *CompositorGlobal,
global_name: u32,
clock_id: u32,

const Feedback = struct {
    allocator: std.mem.Allocator,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    resource_alive: bool = true,
    // The protocol resource and the commit-feedback owner each hold one ref.
    references: u2 = 2,
    commit_feedback: CompositorGlobal.PresentationFeedback,

    fn unreference(self: *Feedback) void {
        std.debug.assert(self.references > 0);
        self.references -= 1;
        if (self.references != 0) return;
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    fn finishResource(self: *Feedback) void {
        if (!self.resource_alive) return;
        self.client.destroyResource(self.resource) catch {
            self.client.postNoMemory() catch {};
        };
    }

    fn presented(
        context: *anyopaque,
        output_context: *anyopaque,
        info: presentation.Info,
    ) void {
        const self: *Feedback = @ptrCast(@alignCast(context));
        if (self.resource_alive and self.client.state == .active) {
            const output: *OutputGlobal = @ptrCast(@alignCast(output_context));
            output.sendPresentationSync(self.client, self.resource) catch {
                self.client.postNoMemory() catch {};
                self.finishResource();
                self.unreference();
                return;
            };
            generated.wp_presentation_feedback_types.events.presented(
                &self.client.connection,
                self.resource,
                info.timestamp.highSeconds(),
                info.timestamp.lowSeconds(),
                info.timestamp.nanoseconds,
                info.refresh_nanoseconds,
                info.highSequence(),
                info.lowSequence(),
                @bitCast(info.flags),
            ) catch self.client.postNoMemory() catch {};
            self.finishResource();
        }
        self.unreference();
    }

    fn discarded(context: *anyopaque) void {
        const self: *Feedback = @ptrCast(@alignCast(context));
        if (self.resource_alive and self.client.state == .active) {
            generated.wp_presentation_feedback_types.events.discarded(
                &self.client.connection,
                self.resource,
            ) catch self.client.postNoMemory() catch {};
            self.finishResource();
        }
        self.unreference();
    }
};

pub fn init(
    self: *PresentationGlobal,
    allocator: std.mem.Allocator,
    server: *Server,
    compositor: *CompositorGlobal,
    clock_id: u32,
) !void {
    self.* = .{
        .allocator = allocator,
        .server = server,
        .compositor = compositor,
        .global_name = undefined,
        .clock_id = clock_id,
    };
    self.global_name = try server.createGlobal(
        &generated.wp_presentation,
        advertised_version,
        .{ .context = self, .bind = bind },
    );
}

pub fn deinit(self: *PresentationGlobal) void {
    self.server.removeGlobal(self.global_name) catch unreachable;
    self.* = undefined;
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *PresentationGlobal = @ptrCast(@alignCast(context));
    const resource = client.createResource(id, &generated.wp_presentation, version, .{
        .context = self,
        .dispatch = dispatchPresentation,
    }) catch return client.postNoMemory();
    try generated.wp_presentation_types.events.clock_id(
        &client.connection,
        resource,
        self.clock_id,
    );
}

fn dispatchPresentation(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const self: *PresentationGlobal = @ptrCast(@alignCast(context));
    switch (try generated.wp_presentation_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .feedback => |request| {
            const object = client.connection.object(request.surface) orelse
                return error.UnknownSurface;
            const surface = try CompositorGlobal.surfaceFor(client, .{
                .id = request.surface,
                .generation = object.generation,
            });
            if (surface.owner != self.compositor) return error.WrongSurface;
            const feedback = self.allocator.create(Feedback) catch
                return client.postNoMemory();
            errdefer self.allocator.destroy(feedback);
            surface.pending_presentation_feedbacks.ensureUnusedCapacity(
                surface.allocator,
                1,
            ) catch return client.postNoMemory();
            const version = try client.resourceVersion(resource, &generated.wp_presentation);
            const feedback_resource = client.createResource(
                request.callback,
                &generated.wp_presentation_feedback,
                version,
                .{
                    .context = feedback,
                    .destroy = destroyFeedbackResource,
                },
            ) catch return client.postNoMemory();
            feedback.* = .{
                .allocator = self.allocator,
                .client = client,
                .resource = feedback_resource,
                .commit_feedback = .{
                    .context = feedback,
                    .presented = Feedback.presented,
                    .discarded = Feedback.discarded,
                },
            };
            surface.pending_presentation_feedbacks.appendAssumeCapacity(
                &feedback.commit_feedback,
            );
        },
    }
}

fn destroyFeedbackResource(
    context: *anyopaque,
    _: *Server.Client,
    _: wayring.ObjectHandle,
) void {
    const feedback: *Feedback = @ptrCast(@alignCast(context));
    std.debug.assert(feedback.resource_alive);
    feedback.resource_alive = false;
    feedback.unreference();
}

test "native presentation feedback snapshots commits and reports output timing" {
    const core = @import("wayring-core");
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var compositor: CompositorGlobal = undefined;
    try compositor.init(std.testing.allocator, &server);
    defer compositor.deinit();
    var output: OutputGlobal = undefined;
    try output.init(std.testing.allocator, &server, .{
        .mode_size = .{ .width = 1280, .height = 720 },
        .logical_size = .{ .width = 1280, .height = 720 },
        .physical_size = .{ .width = 1280, .height = 720 },
        .refresh_millihertz = 60_000,
        .scale = 1,
        .name = "HEADLESS-1",
        .description = "Keywork headless output",
        .model = "headless",
    });
    defer output.deinit();
    var presentation_global: PresentationGlobal = undefined;
    try presentation_global.init(
        std.testing.allocator,
        &server,
        &compositor,
        presentation.monotonic_clock_id,
    );
    defer presentation_global.deinit();
    const client = try server.createClient();
    defer server.destroyClient(client) catch unreachable;

    var peer = wayring.Connection.init(
        std.testing.allocator,
        .client,
        wayring.default_max_frame_size,
    );
    defer peer.deinit();
    _ = try core.bootstrapDisplay(&peer);
    const registry: wayring.ObjectHandle = .{
        .id = 2,
        .generation = try core.getRegistry(&peer, 2),
    };
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    var compositor_name: u32 = 0;
    var output_name: u32 = 0;
    var presentation_name: u32 = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const global = (try core.decodeRegistryEvent(&message, registry.id)).global;
        if (std.mem.eql(u8, global.interface, generated.wl_compositor.name))
            compositor_name = global.name;
        if (std.mem.eql(u8, global.interface, generated.wl_output.name))
            output_name = global.name;
        if (std.mem.eql(u8, global.interface, generated.wp_presentation.name))
            presentation_name = global.name;
    }
    const compositor_resource: wayring.ObjectHandle = .{
        .id = 3,
        .generation = try core.bind(
            &peer,
            registry.id,
            compositor_name,
            generated.wl_compositor.name,
            6,
            3,
            &generated.wl_compositor,
        ),
    };
    const output_resource: wayring.ObjectHandle = .{
        .id = 4,
        .generation = try core.bind(
            &peer,
            registry.id,
            output_name,
            generated.wl_output.name,
            4,
            4,
            &generated.wl_output,
        ),
    };
    const presentation_resource: wayring.ObjectHandle = .{
        .id = 5,
        .generation = try core.bind(
            &peer,
            registry.id,
            presentation_name,
            generated.wp_presentation.name,
            2,
            5,
            &generated.wp_presentation,
        ),
    };
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    var got_clock = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == presentation_resource.id) {
            const event = try generated.wp_presentation_types.decodeEvent(
                &peer,
                presentation_resource,
                &message,
            );
            got_clock = event.clock_id.clk_id == presentation.monotonic_clock_id;
        } else if (message.object_id == output_resource.id) {
            _ = try generated.wl_output_types.decodeEvent(&peer, output_resource, &message);
        } else {
            _ = try core.decodeDisplayEvent(&message);
        }
    }
    try std.testing.expect(got_clock);

    const surface = try generated.wl_compositor_types.requests.create_surface(
        &peer,
        compositor_resource,
    );
    const feedback = try generated.wp_presentation_types.requests.feedback(
        &peer,
        presentation_resource,
        surface,
    );
    try generated.wl_surface_types.requests.commit(&peer, surface);
    try generated.wl_surface_types.requests.commit(&peer, surface);
    try transferToServer(&peer, client);
    var first = compositor.popTransaction() orelse return error.MissingCommit;
    defer first.deinit();
    var second = compositor.popTransaction() orelse return error.MissingCommit;
    defer second.deinit();
    var feedbacks = first.entries[0].takePresentationFeedbacks() orelse
        return error.MissingFeedback;
    defer feedbacks.deinit();
    try std.testing.expect(second.entries[0].takePresentationFeedbacks() == null);
    const info: presentation.Info = .{
        .timestamp = .{
            .seconds = 0x1234_5678_9abc_def0,
            .nanoseconds = 345_678_901,
        },
        .refresh_nanoseconds = 16_666_667,
        .sequence = 0xfedc_ba98_7654_3210,
        .flags = .{
            .vsync = true,
            .hardware_clock = true,
            .zero_copy = true,
        },
    };
    feedbacks.presented(&output, info);
    try transferFromServer(&peer, client);
    var event_index: usize = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id != feedback.id) {
            _ = try core.decodeDisplayEvent(&message);
            continue;
        }
        const event = try generated.wp_presentation_feedback_types.decodeEvent(
            &peer,
            feedback,
            &message,
        );
        switch (event_index) {
            0 => try std.testing.expectEqual(output_resource.id, event.sync_output.output),
            1 => {
                try std.testing.expectEqual(info.timestamp.highSeconds(), event.presented.tv_sec_hi);
                try std.testing.expectEqual(info.timestamp.lowSeconds(), event.presented.tv_sec_lo);
                try std.testing.expectEqual(info.timestamp.nanoseconds, event.presented.tv_nsec);
                try std.testing.expectEqual(info.refresh_nanoseconds, event.presented.refresh);
                try std.testing.expectEqual(info.highSequence(), event.presented.seq_hi);
                try std.testing.expectEqual(info.lowSequence(), event.presented.seq_lo);
                try std.testing.expectEqual(@as(u32, @bitCast(info.flags)), event.presented.flags);
            },
            else => return error.UnexpectedFeedbackEvent,
        }
        event_index += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), event_index);

    const discarded = try generated.wp_presentation_types.requests.feedback(
        &peer,
        presentation_resource,
        surface,
    );
    try generated.wl_surface_types.requests.commit(&peer, surface);
    try transferToServer(&peer, client);
    var third = compositor.popTransaction() orelse return error.MissingCommit;
    defer third.deinit();
    var discarded_feedbacks = third.entries[0].takePresentationFeedbacks() orelse
        return error.MissingFeedback;
    discarded_feedbacks.deinit();
    try transferFromServer(&peer, client);
    var got_discarded = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == discarded.id) {
            _ = try generated.wp_presentation_feedback_types.decodeEvent(
                &peer,
                discarded,
                &message,
            );
            got_discarded = true;
        } else {
            _ = try core.decodeDisplayEvent(&message);
        }
    }
    try std.testing.expect(got_discarded);
}

fn transferToServer(connection: *wayring.Connection, client: *Server.Client) !void {
    while (connection.nextBatch()) |batch| {
        try client.receive(batch.bytes, batch.fds);
        try connection.acknowledge(batch.token, batch.bytes.len);
    }
}

fn transferFromServer(connection: *wayring.Connection, client: *Server.Client) !void {
    while (client.connection.nextBatch()) |batch| {
        try connection.feed(batch.bytes, batch.fds);
        try client.connection.acknowledge(batch.token, batch.bytes.len);
    }
    try client.outputDrained();
}
