//! Generated wlr-screencopy v3 adapter.
//!
//! This type owns only generated manager/frame resources, destination
//! retention, wire validation, and events. `screencopy_session` owns shared
//! scheduling state and the listener remains the sole render/readback owner.

const Self = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayring = @import("wayring");
const presentation = @import("../presentation.zig");
const render = @import("../render/types.zig");
const neutral_dmabuf = @import("linux_dmabuf_buffer.zig");
const Sessions = @import("screencopy_session.zig");
const WayringCompositor = @import("WayringCompositor.zig");
const WayringLinuxDmabuf = @import("WayringLinuxDmabuf.zig");

const server = wayring.server;
const Shm = server.shm.Protocol(protocol);

pub const Target = Sessions.Target;
pub const CaptureError = error{ Stopped, Failed };
pub const OutputResolver = struct {
    context: *anyopaque,
    resolve: *const fn (*anyopaque, *server.Client, u32) ?@import("../output_layout.zig").Id,
    logical_size: *const fn (*anyopaque, @import("../output_layout.zig").Id) ?render.Size,
};
pub const Listener = struct {
    context: *anyopaque,
    constraints: *const fn (*anyopaque, Target) ?render.Size,
    schedule: *const fn (*anyopaque, Target, bool) bool,
    capture_shm: *const fn (*anyopaque, Target, bool, render.PixelBuffer) CaptureError!presentation.Timestamp,
    capture_dmabuf: ?*const fn (*anyopaque, Target, bool, *neutral_dmabuf.Buffer) CaptureError!presentation.Timestamp = null,
    dmabuf_format: ?u32 = null,
};

const Manager = struct {
    owner: *Self,
    client: *server.Client,
    resource: ?protocol.zwlr_screencopy_manager_v1.Resource,
    reference_count: usize = 1,
    session: Sessions.Manager = .{},
};

const Destination = union(enum) {
    shm: server.shm.Buffer.Pin,
    dmabuf: *neutral_dmabuf.Buffer,

    fn release(self: *Destination) void {
        switch (self.*) {
            .shm => |*pin| pin.deinit(),
            .dmabuf => |buffer| buffer.unreference(),
        }
        self.* = undefined;
    }
};

const Frame = struct {
    owner: *Self,
    manager: *Manager,
    client: *server.Client,
    resource: protocol.zwlr_screencopy_frame_v1.Resource,
    transaction: Sessions.Frame,
    destination: ?Destination = null,
};

allocator: std.mem.Allocator,
protocol_server: *server.Server,
outputs: OutputResolver,
shm: *Shm,
dmabuf: ?*WayringLinuxDmabuf,
authorized_uid: std.os.linux.uid_t,
listener: Listener,
sessions: Sessions,
global: ?*const server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
frames: std.ArrayList(*Frame) = .empty,

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    protocol_server: *server.Server,
    outputs: OutputResolver,
    compositor: *WayringCompositor,
    dmabuf: ?*WayringLinuxDmabuf,
    authorized_uid: std.os.linux.uid_t,
    listener: Listener,
) void {
    self.* = .{
        .allocator = allocator,
        .protocol_server = protocol_server,
        .outputs = outputs,
        .shm = compositor.shmAdapter(),
        .dmabuf = dmabuf,
        .authorized_uid = authorized_uid,
        .listener = listener,
        .sessions = .init(allocator),
    };
}

/// Fixture publication is explicit; production assembly never calls this.
pub fn publish(self: *Self) !void {
    std.debug.assert(self.global == null);
    self.global = try self.protocol_server.addGlobalWithOptions(
        protocol.zwlr_screencopy_manager_v1,
        3,
        Self,
        self,
        bind,
        .{ .visibility = .restricted },
    );
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
    std.debug.assert(self.global == null and self.managers.items.len == 0 and self.frames.items.len == 0);
    self.frames.deinit(self.allocator);
    self.managers.deinit(self.allocator);
    self.sessions.deinit();
    self.* = undefined;
}

pub fn destroyClientResources(self: *Self, client: *server.Client) void {
    var index = self.frames.items.len;
    while (index > 0) {
        index -= 1;
        if (self.frames.items[index].client == client) self.destroyFrame(self.frames.items[index]);
    }
    index = self.managers.items.len;
    while (index > 0) {
        index -= 1;
        const manager = self.managers.items[index];
        if (manager.client == client and manager.resource != null) self.destroyManager(manager);
    }
}

pub fn captureOutput(self: *Self, output: @import("../output_layout.zig").Id) void {
    if (self.sessions.generationWillWrap(output)) {
        for (self.managers.items) |manager|
            self.sessions.invalidateManager(&manager.session, output);
        for (self.frames.items) |frame|
            self.sessions.invalidateManager(&frame.manager.session, output);
    }
    const generation = self.sessions.captureOutput(output) orelse return;
    for (self.frames.items) |frame| {
        const target = frame.transaction.target orelse continue;
        if (std.meta.eql(target.output, output)) frameCapture(frame, generation);
    }
}

/// Output removal and atomic resize both invalidate constraints captured by
/// already-created frames. New frames re-read canonical dimensions.
pub fn invalidateOutput(self: *Self, output: @import("../output_layout.zig").Id) void {
    for (self.frames.items) |frame| {
        const target = frame.transaction.target orelse continue;
        if (std.meta.eql(target.output, output)) fail(frame);
    }
    for (self.managers.items) |manager|
        self.sessions.removeManagerOutput(&manager.session, output);
    self.sessions.removeOutput(output);
}

fn bind(client: *server.Client, id: u32, version: u32, self: *Self) !void {
    if (version == 0 or version > 3) return error.InvalidVersion;
    if (!client.isAuthorizedDirectPeer(self.authorized_uid)) return error.Unauthorized;
    try self.managers.ensureUnusedCapacity(self.allocator, 1);
    const manager = try self.allocator.create(Manager);
    errdefer self.allocator.destroy(manager);
    manager.* = .{
        .owner = self,
        .client = client,
        .resource = .init(self.allocator, id, version, .client, client.ownerHooks()),
    };
    errdefer {
        manager.resource.?.destroy();
        manager.resource.?.deinit();
    }
    try manager.resource.?.setHandler(Manager, manager, managerRequest, null);
    try client.materialize(&manager.resource.?.runtime);
    self.managers.appendAssumeCapacity(manager);
}

fn managerRequest(
    _: *protocol.zwlr_screencopy_manager_v1.Resource,
    request: protocol.zwlr_screencopy_manager_v1.Request,
    manager: *Manager,
) !void {
    if (!manager.client.isAuthorizedDirectPeer(manager.owner.authorized_uid)) return error.Unauthorized;
    switch (request) {
        .capture_output => |args| try manager.owner.createFrame(
            manager,
            args.frame,
            manager.owner.outputTarget(manager.client, args.output, null),
            args.overlay_cursor != 0,
        ),
        .capture_output_region => |args| try manager.owner.createFrame(
            manager,
            args.frame,
            manager.owner.outputTarget(manager.client, args.output, .{
                .x = args.x,
                .y = args.y,
                .width = args.width,
                .height = args.height,
            }),
            args.overlay_cursor != 0,
        ),
        .destroy => manager.owner.destroyManager(manager),
    }
}

const RequestedRegion = struct { x: i32, y: i32, width: i32, height: i32 };

fn outputTarget(self: *Self, client: *server.Client, object_id: u32, requested: ?RequestedRegion) ?Target {
    const output = self.outputs.resolve(self.outputs.context, client, object_id) orelse return null;
    if (requested) |region| {
        if (region.width <= 0 or region.height <= 0) return null;
        const size = self.outputs.logical_size(self.outputs.context, output) orelse return null;
        const clipped = (render.Rect{
            .x = region.x,
            .y = region.y,
            .width = @intCast(region.width),
            .height = @intCast(region.height),
        }).intersection(.{ .x = 0, .y = 0, .width = size.width, .height = size.height }) orelse return null;
        return .{ .output = output, .region = clipped };
    }
    return .{ .output = output };
}

fn createFrame(self: *Self, manager: *Manager, id: u32, target: ?Target, overlay_cursor: bool) !void {
    try self.frames.ensureUnusedCapacity(self.allocator, 1);
    const value = try self.allocator.create(Frame);
    errdefer self.allocator.destroy(value);
    const size = if (target) |capture_target|
        self.listener.constraints(self.listener.context, capture_target)
    else
        null;
    const transaction = try self.sessions.createFrame(&manager.session, target, size, overlay_cursor);
    value.* = .{
        .owner = self,
        .manager = manager,
        .client = manager.client,
        .resource = .init(self.allocator, id, manager.resource.?.version(), .client, manager.client.ownerHooks()),
        .transaction = transaction,
    };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Frame, value, frameRequest, null);
    try manager.client.materialize(&value.resource.runtime);
    manager.reference_count += 1;
    self.frames.appendAssumeCapacity(value);

    const capture_size = size orelse return fail(value);
    const stride = std.math.mul(u32, capture_size.width, @sizeOf(u32)) catch return fail(value);
    try protocol.zwlr_screencopy_frame_v1.@"send:buffer"(
        &value.resource,
        0,
        capture_size.width,
        capture_size.height,
        stride,
    );
    if (value.resource.version() >= 3) {
        if (self.dmabuf != null) if (self.listener.dmabuf_format) |format| {
            try protocol.zwlr_screencopy_frame_v1.@"send:linux_dmabuf"(
                &value.resource,
                format,
                capture_size.width,
                capture_size.height,
            );
        };
        try protocol.zwlr_screencopy_frame_v1.@"send:buffer_done"(&value.resource);
    }
}

fn frameRequest(
    _: *protocol.zwlr_screencopy_frame_v1.Resource,
    request: protocol.zwlr_screencopy_frame_v1.Request,
    frame: *Frame,
) !void {
    if (!frame.client.isAuthorizedDirectPeer(frame.owner.authorized_uid)) return error.Unauthorized;
    switch (request) {
        .copy => |args| copy(frame, args.buffer, false),
        .destroy => frame.owner.destroyFrame(frame),
        .copy_with_damage => |args| copy(frame, args.buffer, true),
    }
}

fn copy(frame: *Frame, object_id: u32, with_damage: bool) void {
    if (frame.transaction.finished) return;
    if (frame.transaction.used) return protocolError(frame, .already_used, "screencopy frame was already used");
    const size = frame.transaction.size orelse return fail(frame);
    const resource = frame.client.lookup(object_id) orelse
        return protocolError(frame, .invalid_buffer, "screencopy destination is not live");
    var destination: Destination = if (frame.owner.shm.pin(resource)) |pin|
        .{ .shm = pin }
    else if (frame.owner.dmabuf) |adapter|
        if (adapter.captureBuffer(frame.client, object_id)) |buffer|
            .{ .dmabuf = buffer }
        else
            return protocolError(frame, .invalid_buffer, "screencopy destination is not generated SHM or DMA-BUF")
    else
        return protocolError(frame, .invalid_buffer, "screencopy destination is not generated SHM");
    if (!validDestination(&destination, size, frame.owner.listener.dmabuf_format)) {
        destination.release();
        return protocolError(frame, .invalid_buffer, "buffer does not match screencopy constraints");
    }
    frame.destination = destination;
    const wait_for_damage = frame.transaction.start(&frame.owner.sessions, with_damage) orelse return fail(frame);
    const target = frame.transaction.target orelse return fail(frame);
    if (!frame.owner.listener.schedule(frame.owner.listener.context, target, wait_for_damage)) fail(frame);
}

fn validDestination(destination: *Destination, size: render.Size, dmabuf_format: ?u32) bool {
    return switch (destination.*) {
        .shm => |*pin| valid: {
            var access = pin.access() catch break :valid false;
            defer access.end() catch {};
            break :valid access.geometry.width == size.width and
                access.geometry.height == size.height and
                access.geometry.stride == size.width * @sizeOf(u32) and
                access.geometry.format == .argb8888 and
                @intFromPtr(access.bytes.ptr) % @alignOf(u32) == 0;
        },
        .dmabuf => |buffer| std.meta.eql(buffer.descriptor.size, size) and
            dmabuf_format != null and buffer.descriptor.format == dmabuf_format.?,
    };
}

fn frameCapture(frame: *Frame, generation: u64) void {
    if (!frame.transaction.beginCapture(generation)) return;
    const target = frame.transaction.target orelse return fail(frame);
    const destination = &(frame.destination orelse return fail(frame));
    const timestamp = switch (destination.*) {
        .shm => |*pin| captureShm(frame, pin, target) orelse return,
        .dmabuf => |buffer| capture: {
            const callback = frame.owner.listener.capture_dmabuf orelse return fail(frame);
            break :capture callback(
                frame.owner.listener.context,
                target,
                frame.transaction.overlay_cursor,
                buffer,
            ) catch return fail(frame);
        },
    };
    ready(frame, timestamp);
}

fn ready(frame: *Frame, timestamp: presentation.Timestamp) void {
    if (!frame.transaction.ready()) return fail(frame);
    const destination = &(frame.destination orelse return fail(frame));
    const flags: u32 = switch (destination.*) {
        .shm => 0,
        .dmabuf => |buffer| if (buffer.descriptor.y_inverted) 1 else 0,
    };
    send(frame, protocol.zwlr_screencopy_frame_v1.@"send:flags", .{
        &frame.resource,
        flags,
    }, "queueing screencopy flags") catch return;
    if (frame.transaction.with_damage and frame.resource.version() >= 2) {
        const size = frame.transaction.size.?;
        send(frame, protocol.zwlr_screencopy_frame_v1.@"send:damage", .{
            &frame.resource, 0, 0, size.width, size.height,
        }, "queueing screencopy damage") catch return;
    }
    send(frame, protocol.zwlr_screencopy_frame_v1.@"send:ready", .{
        &frame.resource, timestamp.highSeconds(), timestamp.lowSeconds(), timestamp.nanoseconds,
    }, "queueing screencopy ready") catch return;
    releaseDestination(frame);
}

fn captureShm(
    frame: *Frame,
    pin: *server.shm.Buffer.Pin,
    target: Target,
) ?presentation.Timestamp {
    var access = pin.access() catch {
        fail(frame);
        return null;
    };
    const pixels: []u32 = @alignCast(std.mem.bytesAsSlice(u32, access.bytes));
    const timestamp = frame.owner.listener.capture_shm(
        frame.owner.listener.context,
        target,
        frame.transaction.overlay_cursor,
        .{
            .size = frame.transaction.size.?,
            .stride_pixels = @intCast(access.geometry.stride / @sizeOf(u32)),
            .pixels = pixels,
        },
    ) catch {
        _ = access.end() catch {};
        fail(frame);
        return null;
    };
    access.end() catch {
        fail(frame);
        return null;
    };
    return timestamp;
}

fn fail(frame: *Frame) void {
    if (!frame.transaction.fail()) return;
    protocol.zwlr_screencopy_frame_v1.@"send:failed"(&frame.resource) catch |err|
        eventFailed(frame, err, "queueing screencopy failure");
    releaseDestination(frame);
}

fn send(frame: *Frame, comptime function: anytype, args: anytype, detail: []const u8) !void {
    @call(.auto, function, args) catch |err| {
        eventFailed(frame, err, detail);
        return err;
    };
}

fn eventFailed(frame: *Frame, err: anyerror, detail: []const u8) void {
    switch (err) {
        error.OutOfMemory, error.WriteFailed, error.DuplicateFileDescriptor => frame.client.postOutOfMemory(&frame.resource.runtime, detail),
        error.OutputSealed, error.ClientFatal, error.ResourceNotLive => {},
        else => frame.client.postImplementationError(&frame.resource.runtime, detail),
    }
    releaseDestination(frame);
}

fn protocolError(frame: *Frame, comptime name: @TypeOf(.enum_literal), detail: []const u8) void {
    frame.client.postProtocolError(
        &frame.resource.runtime,
        @intCast(@field(protocol.zwlr_screencopy_frame_v1.@"error", @tagName(name))),
        detail,
    );
}

fn releaseDestination(frame: *Frame) void {
    if (frame.destination) |*destination| destination.release();
    frame.destination = null;
}

fn destroyFrame(self: *Self, value: *Frame) void {
    remove(Frame, &self.frames, value);
    releaseDestination(value);
    value.resource.destroy();
    value.resource.deinit();
    unreferenceManager(value.manager);
    self.allocator.destroy(value);
}

fn destroyManager(self: *Self, value: *Manager) void {
    remove(Manager, &self.managers, value);
    if (value.resource) |*resource| {
        resource.destroy();
        resource.deinit();
        value.resource = null;
    }
    unreferenceManager(value);
}

fn unreferenceManager(value: *Manager) void {
    std.debug.assert(value.reference_count > 0);
    value.reference_count -= 1;
    if (value.reference_count != 0) return;
    value.session.deinit(value.owner.allocator);
    value.owner.allocator.destroy(value);
}

fn remove(comptime T: type, list: *std.ArrayList(*T), value: *T) void {
    for (list.items, 0..) |candidate, index| if (candidate == value) {
        _ = list.swapRemove(index);
        return;
    };
    unreachable;
}

test "generated screencopy v1-v3 descriptors and errors are exact" {
    const manager = protocol.zwlr_screencopy_manager_v1;
    const frame = protocol.zwlr_screencopy_frame_v1;
    try std.testing.expectEqual(@as(u32, 3), manager.interface.version);
    try std.testing.expectEqual(@as(u32, 3), frame.interface.version);
    try expectMessages(&manager.request_messages, &.{
        .{ "capture_output", 1, false }, .{ "capture_output_region", 1, false }, .{ "destroy", 1, true },
    });
    try expectMessages(&frame.request_messages, &.{
        .{ "copy", 1, false }, .{ "destroy", 1, true }, .{ "copy_with_damage", 2, false },
    });
    try expectMessages(&frame.event_messages, &.{
        .{ "buffer", 1, false },      .{ "flags", 1, false },  .{ "ready", 1, false },
        .{ "failed", 1, false },      .{ "damage", 2, false }, .{ "linux_dmabuf", 3, false },
        .{ "buffer_done", 3, false },
    });
    try std.testing.expectEqual(@as(i64, 0), frame.@"error".already_used);
    try std.testing.expectEqual(@as(i64, 1), frame.@"error".invalid_buffer);
}

fn expectMessages(
    actual: []const wayring.wire.MessageDescriptor,
    expected: []const struct { []const u8, u32, bool },
) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (actual, expected) |message, wanted| {
        try std.testing.expectEqualStrings(wanted[0], message.name);
        try std.testing.expectEqual(wanted[1], message.since);
        try std.testing.expectEqual(wanted[2], message.destructor);
    }
}

const TestCapture = struct {
    client: ?*server.Client = null,
    output_object: u32 = 5,
    output: @import("../output_layout.zig").Id = .{ .index = 7, .generation = 3 },
    size: render.Size = .{ .width = 2, .height = 2 },
    scheduled: usize = 0,
    wait_for_damage: bool = false,
    overlay_cursor: bool = false,
    capture_count: usize = 0,

    fn resolve(context: *anyopaque, client: *server.Client, object_id: u32) ?@import("../output_layout.zig").Id {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.client != client or object_id != self.output_object or client.lookup(object_id) == null) return null;
        return self.output;
    }

    fn logicalSize(context: *anyopaque, output: @import("../output_layout.zig").Id) ?render.Size {
        const self: *@This() = @ptrCast(@alignCast(context));
        return if (std.meta.eql(output, self.output)) self.size else null;
    }

    fn constraints(context: *anyopaque, target: Target) ?render.Size {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (!std.meta.eql(target.output, self.output)) return null;
        if (target.region) |region| return .{ .width = region.width, .height = region.height };
        return self.size;
    }

    fn schedule(context: *anyopaque, _: Target, wait_for_damage: bool) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.scheduled += 1;
        self.wait_for_damage = wait_for_damage;
        return true;
    }

    fn capture(context: *anyopaque, _: Target, overlay_cursor: bool, pixels: render.PixelBuffer) CaptureError!presentation.Timestamp {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.overlay_cursor = overlay_cursor;
        self.capture_count += 1;
        for (pixels.pixels, 0..) |*pixel, index|
            pixel.* = 0xff00_0000 | @as(u32, @intCast(self.capture_count * 16 + index));
        return .{ .seconds = self.capture_count, .nanoseconds = 123 };
    }
};

const TestOutput = struct {
    resource: ?protocol.wl_output.Resource = null,

    fn bind(client: *server.Client, id: u32, version: u32, self: *@This()) !void {
        self.resource = .init(std.testing.allocator, id, version, .client, client.ownerHooks());
        errdefer {
            self.resource.?.destroy();
            self.resource.?.deinit();
            self.resource = null;
        }
        try self.resource.?.setHandler(@This(), self, request, null);
        try client.materialize(&self.resource.?.runtime);
    }

    fn request(_: *protocol.wl_output.Resource, _: protocol.wl_output.Request, self: *@This()) !void {
        self.destroy();
    }

    fn destroy(self: *@This()) void {
        if (self.resource) |*resource| {
            resource.destroy();
            resource.deinit();
            self.resource = null;
        }
    }
};

fn testSend(client: *server.Client, object_id: u32, opcode: u16, descriptor: *const wayring.wire.MessageDescriptor, values: []const wayring.wire.Value) !void {
    var output: wayring.wire.Output = .init(std.testing.allocator);
    defer output.deinit();
    try output.enqueue(object_id, opcode, descriptor, values);
    const batch = (try output.beginSend()).?;
    try client.receive(batch.bytes, &.{});
    try output.completeSend(batch.token, batch.bytes.len);
    try client.dispatch();
}

fn testSendWithFds(client: *server.Client, object_id: u32, opcode: u16, descriptor: *const wayring.wire.MessageDescriptor, values: []const wayring.wire.Value) !void {
    var output: wayring.wire.Output = .init(std.testing.allocator);
    defer output.deinit();
    try output.enqueue(object_id, opcode, descriptor, values);
    const batch = (try output.beginSend()).?;
    var fds: std.ArrayList(wayring.wire.FileDescriptor) = .empty;
    defer fds.deinit(std.testing.allocator);
    for (batch.fds) |fd| {
        const duplicate = std.c.fcntl(fd, std.c.F.DUPFD_CLOEXEC, @as(c_int, 0));
        if (duplicate < 0) return error.Unexpected;
        try fds.append(std.testing.allocator, duplicate);
    }
    errdefer {
        for (fds.items) |fd| _ = std.c.close(fd);
    }
    try client.receive(batch.bytes, fds.items);
    fds.clearRetainingCapacity();
    try output.completeSend(batch.token, batch.bytes.len);
    try client.dispatch();
}

fn testDrain(client: *server.Client, allocator: std.mem.Allocator) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    while (try client.beginSend()) |batch| {
        try bytes.appendSlice(allocator, batch.bytes);
        try client.completeSend(batch.token, batch.bytes.len);
    }
    return bytes.toOwnedSlice(allocator);
}

fn testGlobalName(host: *server.Server, name: []const u8) ?u32 {
    var globals = host.iterator();
    while (globals.next()) |global| if (std.mem.eql(u8, global.interface().name, name)) return global.name();
    return null;
}

fn testEventOpcodes(bytes: []const u8, object_id: u32, output: *std.ArrayList(u16)) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        if (bytes.len - offset < 8) return error.InvalidEvent;
        const object = std.mem.readInt(u32, bytes[offset..][0..4], .native);
        const header = std.mem.readInt(u32, bytes[offset + 4 ..][0..4], .native);
        const size: usize = header >> 16;
        if (size < 8 or offset + size > bytes.len) return error.InvalidEvent;
        if (object == object_id) try output.append(std.testing.allocator, @truncate(header));
        offset += size;
    }
}

test "generated screencopy writes exact SHM pixels and orders copy and damage events" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var surfaces = @import("../SurfaceRegistry.zig").init(std.testing.allocator);
    defer surfaces.deinit();
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &surfaces, null);
    defer compositor.deinit();
    var test_output: TestOutput = .{};
    defer test_output.destroy();
    const output_global = try host.addGlobal(protocol.wl_output, 4, TestOutput, &test_output, TestOutput.bind);
    defer host.removeGlobal(output_global) catch {};
    var capture: TestCapture = .{};
    var adapter: Self = undefined;
    adapter.init(
        std.testing.allocator,
        &host,
        .{ .context = &capture, .resolve = TestCapture.resolve, .logical_size = TestCapture.logicalSize },
        &compositor,
        null,
        42,
        .{
            .context = &capture,
            .constraints = TestCapture.constraints,
            .schedule = TestCapture.schedule,
            .capture_shm = TestCapture.capture,
        },
    );
    defer adapter.deinit();
    try adapter.publish();
    defer adapter.unpublish();
    host.setGlobalFilter(Self, &adapter, Self.globalFilter);
    defer host.clearGlobalFilter();
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{
        .credentials = .{ .pid = 1, .uid = 42, .gid = 1 },
        .transport_provenance = .direct,
    });
    const client = managed.client();
    capture.client = client;
    defer {
        adapter.destroyClientResources(client);
        compositor.destroyClientResources(client);
        test_output.destroy();
        managed.destroy();
    }

    try testSend(client, 1, 1, &protocol.wl_display.request_messages[1], &.{.{ .new_id = .{ .typed = 2 } }});
    const registry_events = try testDrain(client, std.testing.allocator);
    std.testing.allocator.free(registry_events);
    try testSend(client, 2, 0, &protocol.wl_registry.request_messages[0], &.{
        .{ .uint = testGlobalName(&host, "wl_compositor").? },
        .{ .new_id = .{ .generic = .{ .interface = "wl_compositor", .version = 6, .id = 3 } } },
    });
    try std.testing.expect(client.fatal() == null);
    try testSend(client, 2, 0, &protocol.wl_registry.request_messages[0], &.{
        .{ .uint = testGlobalName(&host, "wl_shm").? },
        .{ .new_id = .{ .generic = .{ .interface = "wl_shm", .version = 1, .id = 4 } } },
    });
    try std.testing.expect(client.fatal() == null);
    try testSend(client, 2, 0, &protocol.wl_registry.request_messages[0], &.{
        .{ .uint = output_global.name() },
        .{ .new_id = .{ .generic = .{ .interface = "wl_output", .version = 4, .id = 5 } } },
    });
    try testSend(client, 2, 0, &protocol.wl_registry.request_messages[0], &.{
        .{ .uint = adapter.global.?.name() },
        .{ .new_id = .{ .generic = .{ .interface = "zwlr_screencopy_manager_v1", .version = 3, .id = 6 } } },
    });
    try std.testing.expect(client.fatal() == null);
    const fd = try std.posix.memfd_create("screencopy-shm", std.os.linux.MFD.CLOEXEC);
    defer _ = std.c.close(fd);
    if (std.c.ftruncate(fd, 16) != 0) return error.Unexpected;
    try testSendWithFds(client, 4, 0, &protocol.wl_shm.request_messages[0], &.{
        .{ .new_id = .{ .typed = 7 } }, .{ .fd = fd }, .{ .int = 16 },
    });
    try testSend(client, 7, 0, &protocol.wl_shm_pool.request_messages[0], &.{
        .{ .new_id = .{ .typed = 8 } }, .{ .int = 0 }, .{ .int = 2 }, .{ .int = 2 }, .{ .int = 8 }, .{ .uint = 0 },
    });
    const discarded = try testDrain(client, std.testing.allocator);
    std.testing.allocator.free(discarded);

    try testSend(client, 6, 0, &protocol.zwlr_screencopy_manager_v1.request_messages[0], &.{
        .{ .new_id = .{ .typed = 9 } }, .{ .int = 1 }, .{ .object = 5 },
    });
    try std.testing.expect(client.fatal() == null);
    const constraints = try testDrain(client, std.testing.allocator);
    defer std.testing.allocator.free(constraints);
    var constraint_opcodes: std.ArrayList(u16) = .empty;
    defer constraint_opcodes.deinit(std.testing.allocator);
    try testEventOpcodes(constraints, 9, &constraint_opcodes);
    try std.testing.expectEqualSlices(u16, &.{ 0, 6 }, constraint_opcodes.items);
    try testSend(client, 9, 0, &protocol.zwlr_screencopy_frame_v1.request_messages[0], &.{.{ .object = 8 }});
    try std.testing.expectEqual(@as(usize, 1), capture.scheduled);
    try std.testing.expect(!capture.wait_for_damage);
    adapter.captureOutput(capture.output);
    try std.testing.expect(capture.overlay_cursor);
    var pixels: [4]u32 = undefined;
    const read = std.c.pread(fd, @ptrCast(&pixels), @sizeOf(@TypeOf(pixels)), 0);
    try std.testing.expectEqual(@as(isize, @sizeOf(@TypeOf(pixels))), read);
    try std.testing.expectEqualSlices(u32, &.{ 0xff00_0010, 0xff00_0011, 0xff00_0012, 0xff00_0013 }, &pixels);
    const ready_events = try testDrain(client, std.testing.allocator);
    defer std.testing.allocator.free(ready_events);
    var ready_opcodes: std.ArrayList(u16) = .empty;
    defer ready_opcodes.deinit(std.testing.allocator);
    try testEventOpcodes(ready_events, 9, &ready_opcodes);
    try std.testing.expectEqualSlices(u16, &.{ 1, 2 }, ready_opcodes.items);

    try testSend(client, 6, 0, &protocol.zwlr_screencopy_manager_v1.request_messages[0], &.{
        .{ .new_id = .{ .typed = 10 } }, .{ .int = 0 }, .{ .object = 5 },
    });
    const second_constraints = try testDrain(client, std.testing.allocator);
    std.testing.allocator.free(second_constraints);
    try testSend(client, 10, 2, &protocol.zwlr_screencopy_frame_v1.request_messages[2], &.{.{ .object = 8 }});
    try std.testing.expect(capture.wait_for_damage);
    adapter.captureOutput(capture.output);
    const damaged = try testDrain(client, std.testing.allocator);
    defer std.testing.allocator.free(damaged);
    var damaged_opcodes: std.ArrayList(u16) = .empty;
    defer damaged_opcodes.deinit(std.testing.allocator);
    try testEventOpcodes(damaged, 10, &damaged_opcodes);
    try std.testing.expectEqualSlices(u16, &.{ 1, 4, 2 }, damaged_opcodes.items);

    const foreign = try server.CoreClient.create(std.testing.allocator, &host, .{
        .credentials = .{ .pid = 2, .uid = 41, .gid = 1 },
        .transport_provenance = .direct,
    });
    defer foreign.destroy();
    try testSend(foreign.client(), 1, 1, &protocol.wl_display.request_messages[1], &.{.{ .new_id = .{ .typed = 2 } }});
    const foreign_registry = try testDrain(foreign.client(), std.testing.allocator);
    std.testing.allocator.free(foreign_registry);
    try testSend(foreign.client(), 2, 0, &protocol.wl_registry.request_messages[0], &.{
        .{ .uint = adapter.global.?.name() },
        .{ .new_id = .{ .generic = .{ .interface = "zwlr_screencopy_manager_v1", .version = 3, .id = 3 } } },
    });
    try std.testing.expectEqual(server.Fatal.Kind.protocol, foreign.client().fatal().?.kind);
    try std.testing.expectEqualStrings("invalid wl_registry.bind", foreign.client().fatal().?.detail());
    try std.testing.expectEqual(@as(usize, 1), adapter.managers.items.len);
    try std.testing.expect(client.fatal() == null);
}

test "generated screencopy visibility is exact-UID direct-only" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var adapter: Self = undefined;
    adapter.protocol_server = &host;
    adapter.authorized_uid = 42;
    const TestGlobal = struct {
        pub const interface: wayring.wire.Interface = .{ .name = "restricted", .version = 1 };
        fn bind(_: *server.Client, _: u32, _: u32, _: *@This()) !void {}
    };
    var context: TestGlobal = .{};
    const global = try host.addGlobalWithOptions(TestGlobal, 1, TestGlobal, &context, TestGlobal.bind, .{ .visibility = .restricted });
    var direct: server.Client = .init(std.testing.allocator, .{ .credentials = .{ .pid = 1, .uid = 42, .gid = 1 }, .transport_provenance = .direct });
    defer direct.deinit();
    var foreign: server.Client = .init(std.testing.allocator, .{ .credentials = .{ .pid = 2, .uid = 43, .gid = 1 }, .transport_provenance = .direct });
    defer foreign.deinit();
    var derived: server.Client = .init(std.testing.allocator, .{ .credentials = .{ .pid = 3, .uid = 42, .gid = 1 }, .transport_provenance = .security_context });
    defer derived.deinit();
    var unknown: server.Client = .init(std.testing.allocator, .{});
    defer unknown.deinit();
    try std.testing.expect(adapter.globalFilter(&direct, global));
    try std.testing.expect(!adapter.globalFilter(&foreign, global));
    try std.testing.expect(!adapter.globalFilter(&derived, global));
    try std.testing.expect(!adapter.globalFilter(&unknown, global));
}
