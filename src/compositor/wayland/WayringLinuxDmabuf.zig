//! Fixture-only scanner-backed linux-dmabuf adapter.
//!
//! Publication is explicit and no production profile constructs this type.

const WayringLinuxDmabuf = @This();

const std = @import("std");
const core = @import("wayring-protocol");
const wayring = @import("wayring");
const neutral = @import("linux_dmabuf_buffer.zig");
const render = @import("../render/types.zig");
const WayringCompositor = @import("WayringCompositor.zig");

const server = wayring.server;
const wire = wayring.wire;

const Manager = struct {
    owner: *WayringLinuxDmabuf,
    client: *server.Client,
    resource: core.zwp_linux_dmabuf_v1.Resource,
};

const Params = struct {
    owner: *WayringLinuxDmabuf,
    client: *server.Client,
    resource: core.zwp_linux_buffer_params_v1.Resource,
    parameters: neutral.Parameters = .{},
    sampling_device: ?neutral.Device = null,
};

const FeedbackResource = struct {
    owner: *WayringLinuxDmabuf,
    client: *server.Client,
    resource: core.zwp_linux_dmabuf_feedback_v1.Resource,
};

const Buffer = struct {
    owner: *WayringLinuxDmabuf,
    client: *server.Client,
    resource: core.wl_buffer.Resource,
    resource_live: bool = true,
    value: neutral.Buffer,
};

pub const Capabilities = struct {
    device: neutral.Device,
    supported_pairs: []const render.DmabufFormatModifier,
    source_validator: ?render.DmabufSourceValidator = null,
};

allocator: std.mem.Allocator,
protocol_server: *server.Server,
compositor: *WayringCompositor,
feedback: neutral.Feedback,
source_validator: ?render.DmabufSourceValidator,
global: ?*const server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
params: std.ArrayList(*Params) = .empty,
feedback_resources: std.ArrayList(*FeedbackResource) = .empty,
buffers: std.ArrayList(*Buffer) = .empty,

pub fn init(
    self: *WayringLinuxDmabuf,
    allocator: std.mem.Allocator,
    protocol_server: *server.Server,
    compositor: *WayringCompositor,
    capabilities: Capabilities,
) !void {
    const feedback = try neutral.Feedback.init(allocator, capabilities.device, capabilities.supported_pairs);
    self.* = .{
        .allocator = allocator,
        .protocol_server = protocol_server,
        .compositor = compositor,
        .feedback = feedback,
        .source_validator = capabilities.source_validator,
    };
    compositor.setDmabufResolver(.{ .context = self, .resolve = resolveBuffer });
}

/// Fixture publication is deliberately separate from initialization.
pub fn publish(self: *WayringLinuxDmabuf) !void {
    std.debug.assert(self.global == null);
    self.global = try self.protocol_server.addGlobal(
        core.zwp_linux_dmabuf_v1,
        6,
        WayringLinuxDmabuf,
        self,
        bind,
    );
}

pub fn unpublish(self: *WayringLinuxDmabuf) void {
    self.protocol_server.removeGlobal(self.global.?) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}

pub fn destroyClientResources(self: *WayringLinuxDmabuf, client: *server.Client) void {
    var index = self.feedback_resources.items.len;
    while (index > 0) {
        index -= 1;
        if (self.feedback_resources.items[index].client == client)
            self.destroyFeedback(self.feedback_resources.items[index]);
    }
    index = self.params.items.len;
    while (index > 0) {
        index -= 1;
        if (self.params.items[index].client == client) self.destroyParams(self.params.items[index]);
    }
    index = self.managers.items.len;
    while (index > 0) {
        index -= 1;
        if (self.managers.items[index].client == client) self.destroyManager(self.managers.items[index]);
    }
    index = self.buffers.items.len;
    while (index > 0) {
        index -= 1;
        const buffer = self.buffers.items[index];
        if (buffer.client == client and buffer.resource_live) self.destroyBufferResource(buffer);
    }
}

/// Retains only an exact live same-client generated wl_buffer. The caller
/// owns one neutral reference and must release it after capture completion.
pub fn captureBuffer(
    self: *WayringLinuxDmabuf,
    client: *server.Client,
    object_id: u32,
) ?*neutral.Buffer {
    const resource = client.lookup(object_id) orelse return null;
    for (self.buffers.items) |buffer| {
        if (buffer.client == client and buffer.resource_live and
            buffer.resource.id() == object_id and &buffer.resource.runtime == resource and
            resource.state() == .live)
        {
            buffer.value.reference();
            return &buffer.value;
        }
    }
    return null;
}

pub fn deinit(self: *WayringLinuxDmabuf) void {
    std.debug.assert(self.global == null and self.managers.items.len == 0 and
        self.params.items.len == 0 and self.feedback_resources.items.len == 0 and
        self.buffers.items.len == 0);
    self.compositor.clearDmabufResolver(self);
    self.buffers.deinit(self.allocator);
    self.feedback_resources.deinit(self.allocator);
    self.params.deinit(self.allocator);
    self.managers.deinit(self.allocator);
    self.feedback.deinit(self.allocator);
    self.* = undefined;
}

fn bind(client: *server.Client, id: u32, version: u32, self: *WayringLinuxDmabuf) !void {
    try self.managers.ensureUnusedCapacity(self.allocator, 1);
    const manager = try self.allocator.create(Manager);
    errdefer self.allocator.destroy(manager);
    manager.* = .{
        .owner = self,
        .client = client,
        .resource = .init(self.allocator, id, version, .client, client.ownerHooks()),
    };
    errdefer {
        manager.resource.runtime.destroy();
        manager.resource.runtime.deinit();
    }
    try manager.resource.setHandler(Manager, manager, handleManager, null);
    try client.materialize(&manager.resource.runtime);
    self.managers.appendAssumeCapacity(manager);
    self.sendLegacyFormats(manager);
}

fn sendLegacyFormats(self: *WayringLinuxDmabuf, manager: *Manager) void {
    if (manager.resource.version() >= 4) return;
    for (self.feedback.pairs, 0..) |pair, index| {
        if (manager.resource.version() >= 3) {
            core.zwp_linux_dmabuf_v1.@"send:modifier"(
                &manager.resource,
                pair.format,
                @truncate(pair.modifier >> 32),
                @truncate(pair.modifier),
            ) catch |err| return eventFailed(manager.client, &manager.resource.runtime, err, "queueing DMA-BUF modifier");
        } else {
            if (pair.modifier != neutral.linear_modifier) continue;
            for (self.feedback.pairs[0..index]) |previous| {
                if (previous.modifier == neutral.linear_modifier and previous.format == pair.format) break;
            } else core.zwp_linux_dmabuf_v1.@"send:format"(&manager.resource, pair.format) catch |err|
                return eventFailed(manager.client, &manager.resource.runtime, err, "queueing DMA-BUF format");
        }
    }
}

fn handleManager(_: *core.zwp_linux_dmabuf_v1.Resource, request: core.zwp_linux_dmabuf_v1.Request, manager: *Manager) !void {
    switch (request) {
        .destroy => manager.owner.destroyManager(manager),
        .create_params => |args| try manager.owner.createParams(manager, args.params_id),
        .get_default_feedback => |args| try manager.owner.createFeedback(manager, args.id),
        .get_surface_feedback => |args| {
            if (manager.owner.compositor.surfaceId(manager.client, args.surface) == null) {
                manager.client.postImplementationError(&manager.resource.runtime, "surface is not an exact live same-client Wayring wl_surface");
                return;
            }
            try manager.owner.createFeedback(manager, args.id);
        },
    }
}

fn createParams(self: *WayringLinuxDmabuf, manager: *Manager, id: u32) !void {
    try self.params.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Params);
    errdefer self.allocator.destroy(value);
    value.* = .{
        .owner = self,
        .client = manager.client,
        .resource = .init(self.allocator, id, manager.resource.version(), .client, manager.client.ownerHooks()),
    };
    errdefer {
        value.parameters.deinit();
        value.resource.runtime.destroy();
        value.resource.runtime.deinit();
    }
    try value.resource.setHandler(Params, value, handleParams, null);
    try manager.client.materialize(&value.resource.runtime);
    self.params.appendAssumeCapacity(value);
}

fn handleParams(_: *core.zwp_linux_buffer_params_v1.Resource, request: core.zwp_linux_buffer_params_v1.Request, value: *Params) !void {
    switch (request) {
        .destroy => value.owner.destroyParams(value),
        .add => |args| add(value, args),
        .create => |args| createBuffer(value, args.width, args.height, args.format, args.flags, null),
        .create_immed => |args| createBuffer(value, args.width, args.height, args.format, args.flags, args.buffer_id),
        .set_sampling_device => |args| setSamplingDevice(value, args.device),
    }
}

fn add(value: *Params, args: anytype) void {
    value.parameters.add(.{
        .fd = args.fd,
        .offset = args.offset,
        .stride = args.stride,
        .modifier = @as(u64, args.modifier_hi) << 32 | args.modifier_lo,
    }, args.plane_idx) catch |err| switch (err) {
        error.AlreadyUsed => protocolError(value, .already_used, "buffer parameters were already used"),
        error.PlaneIndex => protocolError(value, .plane_idx, "DMA-BUF plane index is out of bounds"),
        error.PlaneSet => protocolError(value, .plane_set, "DMA-BUF plane was already set"),
    };
}

fn setSamplingDevice(value: *Params, bytes: []const u8) void {
    if (value.parameters.used) return protocolError(value, .already_used, "buffer parameters were already used");
    if (bytes.len != @sizeOf(neutral.Device)) return protocolError(value, .invalid_dev_t_size, "sampling device has invalid size");
    value.sampling_device = std.mem.bytesToValue(neutral.Device, bytes[0..@sizeOf(neutral.Device)]);
}

fn createBuffer(value: *Params, width: i32, height: i32, format: u32, flags: u32, immediate_id: ?u32) void {
    const descriptor = value.parameters.validate(
        width,
        height,
        format,
        flags,
        value.resource.version() < 3,
        value.owner.feedback.pairs,
    ) catch |err| {
        switch (err) {
            error.AlreadyUsed => protocolError(value, .already_used, "buffer parameters were already used"),
            error.Incomplete => protocolError(value, .incomplete, "DMA-BUF does not have the planes required by its format"),
            error.InvalidFormat => protocolError(value, .invalid_format, "unsupported DMA-BUF format or modifier"),
            error.InvalidDimensions => protocolError(value, .invalid_dimensions, "DMA-BUF dimensions are invalid"),
            error.OutOfBounds => protocolError(value, .out_of_bounds, "DMA-BUF plane does not contain the requested image"),
            error.ImportFailed => importFailed(value, immediate_id),
        }
        return;
    };
    if (value.sampling_device) |device| if (device != value.owner.feedback.device) {
        importFailed(value, immediate_id);
        return;
    };
    const format_info = render.DmabufFormat.fromFourcc(descriptor.format).?;
    if (descriptor.modifier != neutral.linear_modifier or !format_info.isPackedRgb()) {
        const validator = value.owner.source_validator orelse {
            importFailed(value, immediate_id);
            return;
        };
        validator.validate(validator.context, .{
            .size = descriptor.size,
            .format = descriptor.format,
            .modifier = descriptor.modifier,
            .planes = descriptor.renderPlanes(),
            .plane_count = descriptor.plane_count,
            .force_opaque = !format_info.hasAlpha(),
        }) catch {
            importFailed(value, immediate_id);
            return;
        };
    }

    const buffer = value.owner.materializeBuffer(value, immediate_id, descriptor) catch |err| {
        if (err == error.OutOfMemory) value.client.postOutOfMemory(&value.resource.runtime, "materializing DMA-BUF wl_buffer") else value.client.postImplementationError(&value.resource.runtime, "materializing DMA-BUF wl_buffer");
        return;
    };
    value.parameters.transfer(descriptor.plane_count);
    if (immediate_id == null) core.zwp_linux_buffer_params_v1.@"send:created"(
        &value.resource,
        buffer.resource.id(),
    ) catch |err| {
        eventFailed(value.client, &value.resource.runtime, err, "queueing DMA-BUF created");
        value.owner.destroyBufferResource(buffer);
    };
}

fn materializeBuffer(
    self: *WayringLinuxDmabuf,
    params_value: *Params,
    immediate_id: ?u32,
    descriptor: neutral.Descriptor,
) !*Buffer {
    try self.buffers.ensureUnusedCapacity(self.allocator, 1);
    const server_id = if (immediate_id == null) try params_value.client.reserveServerId() else null;
    errdefer if (server_id) |id| params_value.client.rollbackServerId(id);
    const value = try self.allocator.create(Buffer);
    errdefer self.allocator.destroy(value);
    value.* = .{
        .owner = self,
        .client = params_value.client,
        .resource = .init(
            self.allocator,
            immediate_id orelse server_id.?,
            1,
            if (immediate_id == null) .server else .client,
            params_value.client.ownerHooks(),
        ),
        .value = undefined,
    };
    errdefer {
        value.resource.runtime.destroy();
        value.resource.runtime.deinit();
    }
    value.value = .init(descriptor, value, sendRelease, finalizeBuffer);
    try value.resource.setHandler(Buffer, value, handleBuffer, null);
    if (immediate_id == null)
        try params_value.client.materializeServer(&value.resource.runtime)
    else
        try params_value.client.materialize(&value.resource.runtime);
    self.buffers.appendAssumeCapacity(value);
    return value;
}

fn importFailed(value: *Params, immediate_id: ?u32) void {
    if (immediate_id != null) return protocolError(value, .invalid_wl_buffer, "DMA-BUF import failed");
    core.zwp_linux_buffer_params_v1.@"send:failed"(&value.resource) catch |err|
        eventFailed(value.client, &value.resource.runtime, err, "queueing DMA-BUF failed");
}

fn protocolError(value: *Params, comptime name: @TypeOf(.enum_literal), detail: []const u8) void {
    value.client.postProtocolError(
        &value.resource.runtime,
        @intCast(@field(core.zwp_linux_buffer_params_v1.@"error", @tagName(name))),
        detail,
    );
}

fn createFeedback(self: *WayringLinuxDmabuf, manager: *Manager, id: u32) !void {
    try self.feedback_resources.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(FeedbackResource);
    errdefer self.allocator.destroy(value);
    value.* = .{
        .owner = self,
        .client = manager.client,
        .resource = .init(self.allocator, id, manager.resource.version(), .client, manager.client.ownerHooks()),
    };
    errdefer {
        value.resource.runtime.destroy();
        value.resource.runtime.deinit();
    }
    try value.resource.setHandler(FeedbackResource, value, handleFeedback, null);
    try manager.client.materialize(&value.resource.runtime);
    self.feedback_resources.appendAssumeCapacity(value);
    self.sendFeedback(value);
}

fn sendFeedback(self: *WayringLinuxDmabuf, value: *FeedbackResource) void {
    const protocol = core.zwp_linux_dmabuf_feedback_v1;
    protocol.@"send:format_table"(&value.resource, self.feedback.fd, @intCast(self.feedback.pairs.len * @sizeOf(neutral.FormatTableEntry))) catch |err|
        return eventFailed(value.client, &value.resource.runtime, err, "queueing DMA-BUF format table");
    if (value.resource.version() < 6) protocol.@"send:main_device"(&value.resource, self.feedback.deviceBytes()) catch |err|
        return eventFailed(value.client, &value.resource.runtime, err, "queueing DMA-BUF main device");
    protocol.@"send:tranche_target_device"(&value.resource, self.feedback.deviceBytes()) catch |err|
        return eventFailed(value.client, &value.resource.runtime, err, "queueing DMA-BUF tranche device");
    protocol.@"send:tranche_flags"(&value.resource, if (value.resource.version() >= 6) 2 else 0) catch |err|
        return eventFailed(value.client, &value.resource.runtime, err, "queueing DMA-BUF tranche flags");
    protocol.@"send:tranche_formats"(&value.resource, self.feedback.indexBytes()) catch |err|
        return eventFailed(value.client, &value.resource.runtime, err, "queueing DMA-BUF tranche formats");
    protocol.@"send:tranche_done"(&value.resource) catch |err|
        return eventFailed(value.client, &value.resource.runtime, err, "queueing DMA-BUF tranche completion");
    protocol.@"send:done"(&value.resource) catch |err|
        eventFailed(value.client, &value.resource.runtime, err, "queueing DMA-BUF feedback completion");
}

fn handleFeedback(_: *core.zwp_linux_dmabuf_feedback_v1.Resource, _: core.zwp_linux_dmabuf_feedback_v1.Request, value: *FeedbackResource) !void {
    value.owner.destroyFeedback(value);
}

fn handleBuffer(_: *core.wl_buffer.Resource, _: core.wl_buffer.Request, value: *Buffer) !void {
    value.owner.destroyBufferResource(value);
}

fn resolveBuffer(context: *anyopaque, resource: *server.Resource) ?*neutral.Buffer {
    const self: *WayringLinuxDmabuf = @ptrCast(@alignCast(context));
    for (self.buffers.items) |buffer| {
        if (buffer.resource_live and &buffer.resource.runtime == resource and resource.state() == .live) {
            buffer.value.reference();
            return &buffer.value;
        }
    }
    return null;
}

fn destroyManager(self: *WayringLinuxDmabuf, value: *Manager) void {
    remove(Manager, &self.managers, value);
    value.resource.runtime.destroy();
    value.resource.runtime.deinit();
    self.allocator.destroy(value);
}

fn destroyParams(self: *WayringLinuxDmabuf, value: *Params) void {
    remove(Params, &self.params, value);
    value.parameters.deinit();
    value.resource.runtime.destroy();
    value.resource.runtime.deinit();
    self.allocator.destroy(value);
}

fn destroyFeedback(self: *WayringLinuxDmabuf, value: *FeedbackResource) void {
    remove(FeedbackResource, &self.feedback_resources, value);
    value.resource.runtime.destroy();
    value.resource.runtime.deinit();
    self.allocator.destroy(value);
}

fn destroyBufferResource(self: *WayringLinuxDmabuf, value: *Buffer) void {
    _ = self;
    if (!value.resource_live) return;
    value.resource_live = false;
    value.resource.runtime.destroy();
    value.resource.runtime.deinit();
    value.value.unreference();
}

fn sendRelease(context: *anyopaque) void {
    const value: *Buffer = @ptrCast(@alignCast(context));
    if (!value.resource_live) return;
    core.wl_buffer.@"send:release"(&value.resource) catch |err|
        eventFailed(value.client, &value.resource.runtime, err, "queueing DMA-BUF wl_buffer.release");
}

fn finalizeBuffer(context: *anyopaque) void {
    const value: *Buffer = @ptrCast(@alignCast(context));
    remove(Buffer, &value.owner.buffers, value);
    value.owner.allocator.destroy(value);
}

fn eventFailed(client: *server.Client, resource: *server.Resource, err: anyerror, detail: []const u8) void {
    switch (err) {
        error.OutOfMemory, error.WriteFailed, error.DuplicateFileDescriptor => client.postOutOfMemory(resource, detail),
        error.OutputSealed, error.ClientFatal, error.ResourceNotLive => {},
        else => client.postImplementationError(resource, detail),
    }
}

fn remove(comptime T: type, list: *std.ArrayList(*T), value: *T) void {
    for (list.items, 0..) |item, index| if (item == value) {
        _ = list.swapRemove(index);
        return;
    };
    unreachable;
}

test "scanner exposes exact linux-dmabuf v6 request and event gates" {
    try std.testing.expectEqual(@as(u32, 6), core.zwp_linux_dmabuf_v1.interface.version);
    try std.testing.expectEqual(@as(usize, 4), core.zwp_linux_dmabuf_v1.request_messages.len);
    try std.testing.expectEqual(@as(usize, 2), core.zwp_linux_dmabuf_v1.event_messages.len);
    const manager_requests = [_][]const u8{ "destroy", "create_params", "get_default_feedback", "get_surface_feedback" };
    for (manager_requests, 0..) |name, index| {
        try std.testing.expectEqualStrings(name, core.zwp_linux_dmabuf_v1.request_messages[index].name);
        try std.testing.expectEqual(@as(u32, if (index < 2) 1 else 4), core.zwp_linux_dmabuf_v1.request_messages[index].since);
        try std.testing.expectEqual(index == 0, core.zwp_linux_dmabuf_v1.request_messages[index].destructor);
    }
    const params_requests = [_][]const u8{ "destroy", "add", "create", "create_immed", "set_sampling_device" };
    try std.testing.expectEqual(params_requests.len, core.zwp_linux_buffer_params_v1.request_messages.len);
    for (params_requests, 0..) |name, index| {
        try std.testing.expectEqualStrings(name, core.zwp_linux_buffer_params_v1.request_messages[index].name);
        try std.testing.expectEqual(@as(u32, if (index == 3) 2 else if (index == 4) 6 else 1), core.zwp_linux_buffer_params_v1.request_messages[index].since);
        try std.testing.expectEqual(index == 0, core.zwp_linux_buffer_params_v1.request_messages[index].destructor);
    }
    try std.testing.expectEqualStrings("create_immed", core.zwp_linux_buffer_params_v1.request_messages[3].name);
    try std.testing.expectEqual(@as(u32, 2), core.zwp_linux_buffer_params_v1.request_messages[3].since);
    try std.testing.expectEqualStrings("set_sampling_device", core.zwp_linux_buffer_params_v1.request_messages[4].name);
    try std.testing.expectEqual(@as(u32, 6), core.zwp_linux_buffer_params_v1.request_messages[4].since);
    try std.testing.expectEqual(@as(usize, 9), @typeInfo(core.zwp_linux_buffer_params_v1.@"error").@"struct".decls.len - 1);
    inline for (.{
        .{ "already_used", 0 },  .{ "plane_idx", 1 },         .{ "plane_set", 2 },
        .{ "incomplete", 3 },    .{ "invalid_format", 4 },    .{ "invalid_dimensions", 5 },
        .{ "out_of_bounds", 6 }, .{ "invalid_wl_buffer", 7 }, .{ "invalid_dev_t_size", 8 },
    }) |entry| try std.testing.expectEqual(@as(i64, entry[1]), @field(core.zwp_linux_buffer_params_v1.@"error", entry[0]));
    const feedback_events = [_][]const u8{
        "done", "format_table", "main_device", "tranche_done", "tranche_target_device", "tranche_formats", "tranche_flags",
    };
    try std.testing.expectEqual(feedback_events.len, core.zwp_linux_dmabuf_feedback_v1.event_messages.len);
    for (feedback_events, 0..) |name, index| {
        try std.testing.expectEqualStrings(name, core.zwp_linux_dmabuf_feedback_v1.event_messages[index].name);
        try std.testing.expectEqual(@as(u32, 1), core.zwp_linux_dmabuf_feedback_v1.event_messages[index].since);
    }
    try std.testing.expectEqualStrings("format_table", core.zwp_linux_dmabuf_feedback_v1.event_messages[1].name);
    try std.testing.expect(core.zwp_linux_dmabuf_v1.request_messages[0].destructor);
    try std.testing.expect(core.zwp_linux_buffer_params_v1.request_messages[0].destructor);
    try std.testing.expect(core.zwp_linux_dmabuf_feedback_v1.request_messages[0].destructor);
}

fn testEncode(object_id: u32, opcode: u16, descriptor: *const wire.MessageDescriptor, values: []const wire.Value) ![]u8 {
    var output: wire.Output = .init(std.testing.allocator);
    defer output.deinit();
    try output.enqueue(object_id, opcode, descriptor, values);
    const batch = (try output.beginSend()).?;
    const bytes = try std.testing.allocator.dupe(u8, batch.bytes);
    try output.completeSend(batch.token, batch.bytes.len);
    return bytes;
}

fn testSend(client: *server.Client, object_id: u32, opcode: u16, descriptor: *const wire.MessageDescriptor, values: []const wire.Value) !void {
    const bytes = try testEncode(object_id, opcode, descriptor, values);
    defer std.testing.allocator.free(bytes);
    try client.receive(bytes, &.{});
    try client.dispatch();
}

fn testSendWithFds(client: *server.Client, object_id: u32, opcode: u16, descriptor: *const wire.MessageDescriptor, values: []const wire.Value) !void {
    var output: wire.Output = .init(std.testing.allocator);
    defer output.deinit();
    try output.enqueue(object_id, opcode, descriptor, values);
    const batch = (try output.beginSend()).?;
    var fds: std.ArrayList(wire.FileDescriptor) = .empty;
    defer fds.deinit(std.testing.allocator);
    try fds.ensureUnusedCapacity(std.testing.allocator, batch.fds.len);
    errdefer {
        for (fds.items) |fd| _ = std.c.close(fd);
    }
    for (batch.fds) |fd| {
        const duplicate = std.c.fcntl(fd, std.c.F.DUPFD_CLOEXEC, @as(c_int, 0));
        if (duplicate < 0) return error.Unexpected;
        fds.appendAssumeCapacity(duplicate);
    }
    try client.receive(batch.bytes, fds.items);
    fds.clearRetainingCapacity();
    try output.completeSend(batch.token, batch.bytes.len);
    try client.dispatch();
}

fn testDrain(client: *server.Client) !void {
    while (try client.beginSend()) |batch| try client.completeSend(batch.token, batch.bytes.len);
}

test "fixture DMA-BUF survives params and wl_buffer destruction through current retirement" {
    const format = @intFromEnum(render.DmabufFormat.argb8888);
    const modifier: u64 = 42;
    const Validator = struct {
        fn validate(_: *anyopaque, source: render.DmabufSourceDescriptor) anyerror!void {
            try std.testing.expectEqual(format, source.format);
            try std.testing.expectEqual(modifier, source.modifier);
        }
    };
    var validator_context: u8 = 0;
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var registry = @import("../SurfaceRegistry.zig").init(std.testing.allocator);
    defer registry.deinit();
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &registry, null);
    defer compositor.deinit();
    const pairs = [_]render.DmabufFormatModifier{.{ .format = format, .modifier = modifier }};
    var adapter: WayringLinuxDmabuf = undefined;
    try adapter.init(std.testing.allocator, &host, &compositor, .{
        .device = 0x1234,
        .supported_pairs = &pairs,
        .source_validator = .{ .context = &validator_context, .validate = Validator.validate },
    });
    defer adapter.deinit();
    try adapter.publish();
    defer adapter.unpublish();
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        adapter.destroyClientResources(client);
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    try testSend(client, 1, 1, &core.wl_display.request_messages[1], &.{.{ .new_id = .{ .typed = 2 } }});
    try testSend(client, 2, 0, &core.wl_registry.request_messages[0], &.{
        .{ .uint = compositor.global.name() },
        .{ .new_id = .{ .generic = .{ .interface = "wl_compositor", .version = 6, .id = 3 } } },
    });
    try testSend(client, 2, 0, &core.wl_registry.request_messages[0], &.{
        .{ .uint = adapter.global.?.name() },
        .{ .new_id = .{ .generic = .{ .interface = "zwp_linux_dmabuf_v1", .version = 6, .id = 4 } } },
    });
    try testSend(client, 3, 0, &core.wl_compositor.request_messages[0], &.{.{ .new_id = .{ .typed = 5 } }});
    try std.testing.expectEqual(@as(usize, 1), adapter.managers.items.len);
    try std.testing.expectEqual(@as(u32, 6), adapter.managers.items[0].resource.version());
    try testDrain(client);

    try testSend(client, 4, 2, &core.zwp_linux_dmabuf_v1.request_messages[2], &.{.{ .new_id = .{ .typed = 6 } }});
    try std.testing.expectEqual(@as(usize, 1), adapter.feedback_resources.items.len);
    try std.testing.expectEqual(@as(u32, 6), adapter.feedback_resources.items[0].resource.version());
    var feedback_bytes: std.ArrayList(u8) = .empty;
    defer feedback_bytes.deinit(std.testing.allocator);
    var feedback_fd_count: usize = 0;
    while (try client.beginSend()) |batch| {
        feedback_fd_count += batch.fds.len;
        try feedback_bytes.appendSlice(std.testing.allocator, batch.bytes);
        try client.completeSend(batch.token, batch.bytes.len);
    }
    try std.testing.expectEqual(@as(usize, 1), feedback_fd_count);
    var offset: usize = 0;
    var feedback_event_count: usize = 0;
    const expected_opcodes = [_]u16{ 1, 4, 6, 5, 3, 0 };
    while (offset < feedback_bytes.items.len) {
        const object_id = std.mem.readInt(u32, feedback_bytes.items[offset..][0..4], .native);
        const header = std.mem.readInt(u32, feedback_bytes.items[offset + 4 ..][0..4], .native);
        const message_size: usize = header >> 16;
        try std.testing.expect(message_size >= 8 and offset + message_size <= feedback_bytes.items.len);
        if (object_id == 6) {
            try std.testing.expectEqual(expected_opcodes[feedback_event_count], @as(u16, @truncate(header)));
            feedback_event_count += 1;
        }
        offset += message_size;
    }
    try std.testing.expectEqual(expected_opcodes.len, feedback_event_count);
    try testSend(client, 6, 0, &core.zwp_linux_dmabuf_feedback_v1.request_messages[0], &.{});
    try testDrain(client);
    try testSend(client, 4, 1, &core.zwp_linux_dmabuf_v1.request_messages[1], &.{.{ .new_id = .{ .typed = 6 } }});

    const fd = try std.posix.memfd_create("wayring-dmabuf-fixture", std.os.linux.MFD.CLOEXEC);
    defer _ = std.c.close(fd);
    if (std.c.ftruncate(fd, 16) != 0) return error.Unexpected;
    try testSendWithFds(client, 6, 1, &core.zwp_linux_buffer_params_v1.request_messages[1], &.{
        .{ .fd = fd },                          .{ .uint = 0 },                   .{ .uint = 0 }, .{ .uint = 8 },
        .{ .uint = @truncate(modifier >> 32) }, .{ .uint = @truncate(modifier) },
    });
    try testSend(client, 6, 3, &core.zwp_linux_buffer_params_v1.request_messages[3], &.{
        .{ .new_id = .{ .typed = 7 } }, .{ .int = 2 },  .{ .int = 2 },
        .{ .uint = format },            .{ .uint = 0 },
    });
    try std.testing.expectEqual(@as(usize, 1), adapter.buffers.items.len);
    const owned_fd = adapter.buffers.items[0].value.descriptor.planes[0].plane.fd;
    try std.testing.expect(owned_fd != fd);
    try testSend(client, 6, 0, &core.zwp_linux_buffer_params_v1.request_messages[0], &.{});
    try std.testing.expectEqual(@as(usize, 0), adapter.params.items.len);

    try testSend(client, 5, 1, &core.wl_surface.request_messages[1], &.{
        .{ .object = 7 }, .{ .int = 0 }, .{ .int = 0 },
    });
    try testSend(client, 7, 0, &core.wl_buffer.request_messages[0], &.{});
    try std.testing.expectEqual(@as(usize, 1), adapter.buffers.items.len);
    try std.testing.expect(!adapter.buffers.items[0].resource_live);
    try testSend(client, 5, 6, &core.wl_surface.request_messages[6], &.{});
    const surface_id = compositor.surfaceId(client, 5).?;
    try std.testing.expect(registry.renderState(surface_id).?.buffer.dmabuf != null);
    try std.testing.expectEqual(@as(usize, 1), adapter.buffers.items.len);

    try testSend(client, 5, 1, &core.wl_surface.request_messages[1], &.{
        .{ .object = null }, .{ .int = 0 }, .{ .int = 0 },
    });
    try testSend(client, 5, 6, &core.wl_surface.request_messages[6], &.{});
    try std.testing.expect(registry.renderState(surface_id) == null);
    try std.testing.expectEqual(@as(usize, 0), adapter.buffers.items.len);
    try std.testing.expect(std.c.fcntl(owned_fd, std.c.F.GETFD) < 0);
    try std.testing.expectEqual(std.posix.E.BADF, std.posix.errno(-1));
    try testDrain(client);
}
